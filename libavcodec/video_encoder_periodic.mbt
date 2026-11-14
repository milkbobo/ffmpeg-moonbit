///|
/// Search once over the complete sequence, accounting for repeated headers
/// and all IDR pictures. Probes never touch caller-owned stats/recon.
fn video_encode_periodic_abr(
  frames : Array[(Bytes, Bytes, Bytes)],
  codec~ : VideoCodec,
  config~ : VideoEncConfig,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
) -> Result[Bytes, String] {
  let validator = match
    VideoEncoder::open(codec~, config={ ..config, target_bytes: 0, }) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  for (y, u, v) in frames {
    match validator.h264.check_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let qps = match
    h264_rc_solve(frames.length(), config.qp, config.target_bytes, fn(trial) {
      match
        video_encode_periodic_qps(
          frames,
          config,
          trial,
          [],
          H264EncStats::new(),
        ) {
        Ok((bytes, _)) => Ok(bytes.length())
        Err(e) => Err(e)
      }
    }) {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  match video_encode_periodic_qps(frames, config, qps, recon, stats) {
    Ok((bytes, _)) => {
      // The shared B core already records its segment's display-order QPs.
      if !config.b_slices {
        for qp in qps {
          stats.frame_qps.push(qp)
        }
      }
      Ok(bytes)
    }
    Err(e) => Err(e)
  }
}

///|
/// Each GOP has independent reference history, but its QPs come from one
/// global assignment in display order. P-only PPSs retain the caller's
/// base QP; the existing B core anchors each GOP's PPS at its IDR QP.
fn video_encode_periodic_qps(
  frames : Array[(Bytes, Bytes, Bytes)],
  config : VideoEncConfig,
  qps : Array[Int32],
  recon : Array[Bytes],
  stats : H264EncStats,
  vbv~ : H264Vbv? = None,
) -> Result[(Bytes, Array[Int32]), String] {
  let output : Array[Bytes] = []
  let sizes : Array[Int32] = []
  let mut fullness = match vbv {
    Some(v) => v.init_bits
    None => 0
  }
  let mut start = 0
  while start < frames.length() {
    let end = start + (frames.length() - start).min(config.keyint)
    let segment = frames[start:end].to_owned()
    let segment_qps = qps[start:end].to_owned()
    // Only prediction history resets. Signal the actual pre-removal CPB
    // fullness for random access into this GOP, including preceding filler.
    let segment_vbv = match vbv {
      None => None
      Some(v) =>
        if start == 0 {
          Some(v)
        } else {
          let rate = (v.bit_rate_value_minus1 + 1) << 6
          let delay = (fullness.to_int64() * 90000L / rate.to_int64())
            .to_int()
            .max(1)
          Some({
            ..v,
            init_bits: fullness,
            init_delay: delay,
            init_delay_offset: (v.bufsize.to_int64() * 90000L / rate.to_int64()).to_int() -
            delay,
          })
        }
    }
    // On an IDR, pic_timing is relative to the BP in a *preceding* AU.
    // Following P pictures use the BP in this GOP's IDR instead.
    let idr_cpb_delay = if start == 0 { 0 } else { config.keyint % 32768 * 2 }
    let result = if config.b_slices {
      // Slice QPs are indexed by display position. This core emits the
      // P/B pairs in decode order and promotes an unmatched tail to P.
      h264_encode_frames_b(
        segment,
        width=config.width,
        height=config.height,
        qp=config.qp,
        qps=segment_qps,
        level_idc=30,
        aq=config.aq,
        aq_strength=config.aq_strength,
        aud=config.aud,
        cabac=config.cabac,
        cabac_rd=config.cabac_rd && config.cabac,
        b_parts=config.b_parts,
        intra_in_b=config.intra_in_b,
        intra4x4_in_b=config.intra4x4_in_b,
        dct8x8=config.dct8x8,
        multi_ref=config.multi_ref,
        weightp=config.weightp,
        bit_depth=config.bit_depth,
        vbv=segment_vbv,
        idr_cpb_delay~,
        recon~,
        stats~,
      )
    } else if config.cabac {
      h264_encode_frames_cabac_qps(
        segment,
        width=config.width,
        height=config.height,
        base_qp=config.qp,
        qps=segment_qps,
        level_idc=30,
        intra_in_p=false,
        intra4x4_in_p=false,
        dct8x8=config.dct8x8,
        aq=config.aq,
        aq_strength=config.aq_strength,
        cabac_rd=config.cabac_rd,
        aud=config.aud,
        weightp=config.weightp,
        bit_depth=config.bit_depth,
        multi_ref=config.multi_ref,
        recon~,
        stats~,
        vbv=segment_vbv,
        idr_cpb_delay~,
      )
    } else {
      h264_encode_frames_qps(
        segment,
        width=config.width,
        height=config.height,
        base_qp=config.qp,
        qps=segment_qps,
        level_idc=30,
        pcm_first=false,
        intra_in_p=false,
        intra4x4_in_p=false,
        dct8x8=config.dct8x8,
        aq=config.aq,
        aq_strength=config.aq_strength,
        aud=config.aud,
        weightp=config.weightp,
        bit_depth=config.bit_depth,
        multi_ref=config.multi_ref,
        recon~,
        stats~,
        vbv=segment_vbv,
        idr_cpb_delay~,
      )
    }
    match result {
      Ok((bytes, raw_sizes)) => {
        let mut offset = 0
        for size in raw_sizes {
          output.push(bytes[offset:offset + size].to_owned())
          offset += size
          let filler = match vbv {
            None => 0
            Some(v) =>
              h264_vbv_fillers(1, [size], { ..v, init_bits: fullness, })[0]
          }
          if filler > 0 {
            output.push(h264_enc_filler_nal(filler - 5))
            stats.vbv_fills += 1
            stats.vbv_filler_bytes += filler
          }
          sizes.push(size + filler)
          match vbv {
            None => ()
            Some(v) =>
              fullness = (fullness - (size + filler) * 8).max(0) + v.rate_bits
          }
        }
      }
      Err(e) => return Err(e)
    }
    start = end
  }
  Ok((h264_enc_concat(output), sizes))
}

///|
/// Search and replay one CPB over every GOP. Probes include their exact
/// buffering-period escape bytes and filler, so final emission is identical.
fn video_encode_periodic_vbv(
  frames : Array[(Bytes, Bytes, Bytes)],
  codec~ : VideoCodec,
  config~ : VideoEncConfig,
  recon~ : Array[Bytes],
  stats~ : H264EncStats,
) -> Result[Bytes, String] {
  if config.target_bytes > 0 {
    return Err("h264 enc: target_bytes and vbv are mutually exclusive")
  }
  let v = match
    h264_vbv_new(config.vbv_maxrate, config.vbv_bufsize, config.fps, 90) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // A later BP may describe a fuller CPB than the initial 90 percent.
  let rate = (v.bit_rate_value_minus1 + 1) << 6
  if v.init_delay < 1 {
    return Err("h264 enc: vbv initial delay is below one 90 kHz tick")
  }
  if v.bufsize.to_int64() * 90000L / rate.to_int64() > 0xFFFFFFL {
    return Err("h264 enc: vbv full-buffer delay exceeds 24 bits")
  }
  let validator = match
    VideoEncoder::open(codec~, config={
      ..config,
      vbv_maxrate: 0,
      vbv_bufsize: 0,
      fps: 0,
    }) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  for (y, u, v) in frames {
    match validator.h264.check_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let qps = match
    h264_vbv_solve(
      frames.length(),
      config.qp,
      v,
      fn(trial) {
        match
          video_encode_periodic_qps(
            frames,
            config,
            trial,
            [],
            H264EncStats::new(),
            vbv=Some(v),
          ) {
          Ok((_, sizes)) => Ok(sizes)
          Err(e) => Err(e)
        }
      },
      coding_order=if config.b_slices {
        h264_b_coding_order(frames.length(), gop_size=config.keyint)
      } else {
        []
      },
    ) {
    Ok((qps, _)) => qps
    Err(e) => return Err(e)
  }
  match
    video_encode_periodic_qps(frames, config, qps, recon, stats, vbv=Some(v)) {
    Ok((bytes, _)) => {
      stats.vbv_bits = bytes.length().to_int64() * 8L
      if !config.b_slices {
        for q in qps {
          stats.frame_qps.push(q)
        }
      }
      Ok(bytes)
    }
    Err(e) => Err(e)
  }
}
