///|
/// PCM sample reconstruction and filter protection, ported from FFmpeg
/// 9.0.2 hevcdec.c hls_pcm_sample/set_deblocking_bypass and dsp_template.c.
/// Original FFmpeg code is LGPL-2.1-or-later.
fn HevcIntraDecoder::pcm_sample(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  log2_size : Int32,
) -> Result[Unit, String] {
  let sps = self.sps
  let size = 1 << log2_size
  let chroma_samples = if sps.chroma_format_idc == 0 {
    0
  } else {
    2 * (size >> sps.hshift[1]) * (size >> sps.vshift[1])
  }
  let bits = size * size * sps.pcm_bit_depth +
    chroma_samples * sps.pcm_bit_depth_chroma
  let data = match self.cabac.cc.skip_bytes((bits + 7) >> 3) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let reader = BitReader::new(data)
  for plane in 0..<(if sps.chroma_format_idc == 0 { 1 } else { 3 }) {
    let hs = sps.hshift[plane]
    let vs = sps.vshift[plane]
    let depth = if plane == 0 {
      sps.pcm_bit_depth
    } else {
      sps.pcm_bit_depth_chroma
    }
    let width = size >> hs
    let height = size >> vs
    let stride = self.pic.plane_stride(plane)
    let dst = if plane == 0 {
      self.pic.y
    } else if plane == 1 {
      self.pic.cb
    } else {
      self.pic.cr
    }
    for y in 0..<height {
      for x in 0..<width {
        dst[((y0 >> vs) + y) * stride + (x0 >> hs) + x] = reader
          .read(depth)
          .reinterpret_as_int() <<
          (sps.bit_depth - depth)
      }
    }
  }
  if sps.pcm_loop_filter_disabled != 0 {
    self.protect_filter_region(x0, y0, size)
  }
  Ok(())
}

///|
fn HevcIntraDecoder::protect_filter_region(
  self : HevcIntraDecoder,
  x0 : Int32,
  y0 : Int32,
  size : Int32,
) -> Unit {
  let sps = self.sps
  let shift = sps.log2_min_pu_size
  for y in (y0 >> shift)..<((y0 + size).min(sps.height) >> shift) {
    for x in (x0 >> shift)..<((x0 + size).min(sps.width) >> shift) {
      self.pcm[y * sps.min_pu_width + x] = 1
    }
  }
}

///|
fn hevc_pcm_at(sps : HevcSps, pcm : Array[Int32], x : Int32, y : Int32) -> Bool {
  if pcm.is_empty() || x < 0 || y < 0 || x >= sps.width || y >= sps.height {
    false
  } else {
    pcm[(y >> sps.log2_min_pu_size) * sps.min_pu_width +
    (x >> sps.log2_min_pu_size)] !=
    0
  }
}

///|
/// Preserve protected sides immediately after each independent four-line
/// group. All edge decisions still see both original sides, as in FFmpeg's
/// no_p/no_q kernels; later edges see the restored PCM samples.
fn hevc_luma_group_protected(
  plane : Array[Int32],
  base : Int32,
  xp : Int32,
  yp : Int32,
  beta : Int32,
  tc : Int32,
  max : Int32,
  no_p : Bool,
  no_q : Bool,
) -> Unit {
  if !no_p && !no_q {
    hevc_luma_group(plane, base, xp, yp, beta, tc, max)
    return
  }
  let saved = FixedArray::make(24, 0)
  for y in 0..<4 {
    for x in 0..<3 {
      saved[y * 6 + x] = plane[base + y * yp - (x + 1) * xp]
      saved[y * 6 + x + 3] = plane[base + y * yp + x * xp]
    }
  }
  hevc_luma_group(plane, base, xp, yp, beta, tc, max)
  for y in 0..<4 {
    for x in 0..<3 {
      if no_p {
        plane[base + y * yp - (x + 1) * xp] = saved[y * 6 + x]
      }
      if no_q {
        plane[base + y * yp + x * xp] = saved[y * 6 + x + 3]
      }
    }
  }
}
