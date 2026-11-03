///|
/// Decode a base64 table (ASCII-safe by construction).
fn sbr_extra_b64(s : String, max_len : Int32) -> Bytes {
  let input : Array[Byte] = []
  for i in 0..<s.length() {
    input.push((s[i].to_int() & 0xff).to_byte())
  }
  @libavutil.av_base64_decode(Bytes::from_array(input[:]), max_len).unwrap()
}

///|
fn sbr_extra_s16p(x : Double) -> Int32 {
  let v = x * 32768.0
  if v >= 32767.5 {
    32767
  } else if v <= -32768.5 {
    -32768
  } else {
    v.round().to_int()
  }
}

///|
/// Compare decoded planar frames against interleaved s16 reference PCM.
fn sbr_extra_match(
  name : String,
  outs : Array[Array[@libavcodec.AacPcm]],
  pcm : Bytes,
  nch : Int32,
) -> Unit raise {
  let mut max_diff = 0
  let mut exact = 0
  let mut samples = 0
  for out in outs {
    assert_eq(out.length(), nch)
    for ch in 0..<nch {
      assert_eq(out[ch].samples.length(), 2048)
    }
    for i in 0..<2048 {
      for ch in 0..<nch {
        let idx = (samples + i) * nch + ch
        assert_true(idx * 2 + 1 < pcm.length())
        let value = pcm[idx * 2].to_int() | (pcm[idx * 2 + 1].to_int() << 8)
        let want = if value >= 32768 { value - 65536 } else { value }
        let got = sbr_extra_s16p(out[ch].samples[i])
        let diff = if got > want { got - want } else { want - got }
        if diff > max_diff {
          max_diff = diff
        }
        if diff == 0 {
          exact = exact + 1
        }
      }
    }
    samples = samples + 2048
  }
  assert_true(max_diff <= 1)
  assert_true(exact * 1000 >= samples * nch * 999 / 1000)
  println(
    "\{name}: frames=\{outs.length()} samples=\{samples} ch=\{nch} max_diff=\{max_diff} exact=\{exact.to_double() * 100.0 / (samples * nch).to_double()}%",
  )
}

///|
fn sbr_extra_check(
  name : String,
  adts : Bytes,
  pcm : Bytes,
  nch : Int32,
) -> Unit raise {
  let dec = @libavcodec.new_aac_decoder_from_adts(adts, nch).unwrap()
  let mut pos = 0
  let outs : Array[Array[@libavcodec.AacPcm]] = []
  while pos < adts.length() {
    let hdr = @libavcodec.ff_adts_header_parse_buf(
      adts
      .clamped_view(start=pos, end=pos + @libavcodec.av_aac_adts_header_size)
      .to_owned(),
    ).unwrap()
    let end = pos + hdr.frame_length
    let payload_start = pos +
      @libavcodec.av_aac_adts_header_size +
      (if hdr.crc_absent == 0 { 2 } else { 0 })
    let payload = adts.clamped_view(start=payload_start, end~).to_owned()
    outs.push(dec.decode_frame(payload).unwrap())
    pos = end
  }
  sbr_extra_match(name, outs, pcm, nch)
}

///|
/// Decode raw access units with an explicit ASC channel configuration. Used for
/// layouts that ADTS cannot signal: its 3-bit `channel_configuration` field
/// truncates the 4-bit ASC values 11 (6.1) and 14 (5.1.2).
fn sbr_extra_check_au(
  name : String,
  raw : Bytes,
  sizes : Array[Int32],
  pcm : Bytes,
  nch : Int32,
  chan_config : Int32,
) -> Unit raise {
  let dec = @libavcodec.new_aac_decoder_from_asc_channels(
    chan_config, 6, 24000, nch,
  ).unwrap()
  let mut pos = 0
  let outs : Array[Array[@libavcodec.AacPcm]] = []
  for size in sizes {
    let payload = raw.clamped_view(start=pos, end=pos + size).to_owned()
    outs.push(dec.decode_frame(payload).unwrap())
    pos = pos + size
  }
  sbr_extra_match(name, outs, pcm, nch)
}

///|
test "sbr extra: rate/channel combinations match FFmpeg" {
  let cases : Array[(String, String, String, Int32)] = [
    (
      "he_st32", @aac_sbr_extra_vectors.he_st32_adts_b64, @aac_sbr_extra_vectors.he_st32_pcm_b64,
      2,
    ),
    (
      "he_st44", @aac_sbr_extra_vectors.he_st44_adts_b64, @aac_sbr_extra_vectors.he_st44_pcm_b64,
      2,
    ),
    (
      "he_ps44", @aac_sbr_extra_vectors.he_ps44_adts_b64, @aac_sbr_extra_vectors.he_ps44_pcm_b64,
      2,
    ),
  ]
  for c in cases {
    let (name, adts_b64, pcm_b64, nch) = c
    let adts = sbr_extra_b64(adts_b64, 8192)
    let pcm = sbr_extra_b64(pcm_b64, 1 << 20)
    sbr_extra_check(name, adts, pcm, nch)
  }
}
