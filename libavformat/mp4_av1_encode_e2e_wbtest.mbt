// §453 E2E: the pure-MoonBit AV1 encoder → MP4 (av01/av1C) → demux →
// decode, pixel-for-pixel against the encoder's expected planes. The
// av1C record is cross-checked by the container-side parser.

///|
/// Deterministic smooth source (same shape as the libavcodec suite's).
fn av1enc_e2e_src_plane(
  w : Int32,
  h : Int32,
  salt : Int32,
) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = 96 + (y * 13 + x * 5 + salt * 29) % 64
      let ov = (x * 7 + y * 3 + salt * 11) % 20 - 10
      let v = base + ov
      p[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  p
}

///|
test "mp4: AV1 encoder E2E — mux, demux, decode exact" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  // The av1C record parses back through the container-side reader.
  let av1c = enc.av1c()
  let (profile, level, depth, chroma) = av1c_parse(av1c).unwrap()
  assert_eq(profile, 0)
  assert_eq(level, 0)
  assert_eq(depth, 8)
  assert_eq(chroma, 1)
  assert_eq(av1c.length() > 4, true)
  let mux = mp4_av1_muxer_new(w, h, av1c, timescale=90000).unwrap()
  // Encode three frames; keep the expected reconstructions.
  let expecteds : Array[@libavcodec.Av1EncPlanes] = []
  let samples : Array[Bytes] = []
  for i in [0, 1, 2] {
    let src = @libavcodec.Av1EncPlanes::{
      y: av1enc_e2e_src_plane(w, h, i * 5),
      y_stride: w,
      u: av1enc_e2e_src_plane(cw, ch, i * 5 + 1),
      uv_stride: cw,
      v: av1enc_e2e_src_plane(cw, ch, i * 5 + 2),
    }
    let (pkt, exp) = enc.encode_frame(src, base_q_idx=100).unwrap()
    expecteds.push(exp)
    samples.push(@libavcodec.av1_enc_mp4_sample(pkt).unwrap())
  }
  for i in 0..<3 {
    mux.write_packet(samples[i], duration=3000, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  // ---- Container round-trip.
  let movie = av_mov_open(bytes).unwrap()
  let track = movie.tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.width, w)
  assert_eq(track.height, h)
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 3)
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(
      sample.size,
      samples[i].length().reinterpret_as_uint(),
      msg="sample \{i} size",
    )
    assert_eq(sample.keyframe, i == 0, msg="sample \{i} keyframe")
    assert_eq(sample.dts, (i * 3000).to_int64(), msg="sample \{i} dts")
  }
  // ---- Decode every demuxed sample and compare pixel-for-pixel.
  let dec = @libavcodec.Av1Decoder::new()
  for i in 0..<3 {
    let sample = track.samples[i]
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let payload = bytes[start:end].to_owned()
    assert_eq(payload, samples[i], msg="sample \{i} payload")
    let f = dec.decode_packet(payload).unwrap().unwrap()
    let exp = expecteds[i]
    for y in 0..<h {
      for x in 0..<w {
        assert_eq(
          f.y[y * f.y_stride + x],
          exp.y[y * w + x],
          msg="F\{i} Y(\{y},\{x})",
        )
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        assert_eq(
          f.u[y * f.uv_stride + x],
          exp.u[y * cw + x],
          msg="F\{i} U(\{y},\{x})",
        )
        assert_eq(
          f.v[y * f.uv_stride + x],
          exp.v[y * cw + x],
          msg="F\{i} V(\{y},\{x})",
        )
      }
    }
  }
}

///|
test "mp4: AV1 encoder sample strips the temporal delimiter" {
  // A packet of TD + seq + frame must lose exactly the two TD bytes.
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
  )
  let src = @libavcodec.Av1EncPlanes::{
    y: av1enc_e2e_src_plane(64, 64, 0),
    y_stride: 64,
    u: av1enc_e2e_src_plane(32, 32, 1),
    uv_stride: 32,
    v: av1enc_e2e_src_plane(32, 32, 2),
  }
  let (pkt, _) = enc.encode_frame(src, base_q_idx=100).unwrap()
  let sample = @libavcodec.av1_enc_mp4_sample(pkt).unwrap()
  // TD = header 0x12 + leb128 size 0 (two bytes).
  assert_eq(sample.length(), pkt.length() - 2)
  assert_eq(sample[0], pkt[2])
  // Garbage must be rejected, not silently trimmed.
  assert_eq(@libavcodec.av1_enc_mp4_sample(b"\xFF\x00") is Err(_), true)
}
