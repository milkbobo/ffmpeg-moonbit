///|
/// Real-vector differential test for the AAC-LC spectral decode chain:
/// the docker-generated mono 440 Hz tone of
/// `aac_spectrum_realdata_wbtest.mbt` decoded frame by frame through
/// `AacDecoder::decode_frame` (sections, scalefactors, spectral codebooks,
/// TNS, IMDCT/windowing) and compared against the PCM the FFmpeg 9.0.2
/// native float decoder produced for the same stream.
///
/// FFmpeg's decoder accumulates in float32 while this port works in Double,
/// so the comparison is differential with a small tolerance rather than a
/// bit-exact MD5: every sample must match within 1 LSB of s16 and the vast
/// majority exactly.

///|
test "aac: all 46 FDK frames match FFmpeg PCM within 1 LSB" {
  let data = @libavutil.av_base64_decode(aac_tone441_aac_b64, 16384).unwrap()
  let pcm = @libavutil.av_base64_decode(aac_tone441_pcm_b64, 196608).unwrap()
  let header = ff_adts_header_parse_buf(data).unwrap()
  let config = new_mpeg4_audio_config()
  config.object_type = 2
  config.sampling_index = header.sampling_index
  config.sample_rate = header.sample_rate
  config.chan_config = header.chan_config
  config.channels = 1
  config.frame_length = 1024
  let dec = new_aac_decoder(config, 1)
  let mut pos = 0
  let mut frames = 0
  let mut nonzero = 0
  let mut max_diff = 0
  let mut exact = 0
  let mut compared = 0
  while pos + av_aac_adts_header_size <= data.length() {
    let hdr_bytes = data
      .clamped_view(start=pos, end=pos + av_aac_adts_header_size)
      .to_owned()
    let hdr = ff_adts_header_parse_buf(hdr_bytes).unwrap()
    let len = hdr.frame_length
    assert_true(pos + len <= data.length())
    let mut pl_off = pos + av_aac_adts_header_size
    if hdr.crc_absent == 0 {
      pl_off = pl_off + 2
    }
    let payload = data.clamped_view(start=pl_off, end=pos + len).to_owned()
    match dec.decode_frame(payload) {
      Ok(out) => {
        assert_eq(out.length(), 1)
        assert_eq(out[0].samples.length(), 1024)
        for i = 0; i < out[0].samples.length(); i = i + 1 {
          let v = out[0].samples[i]
          assert_true(v.abs() < 1.0)
          if v != 0.0 {
            nonzero = nonzero + 1
          }
          // Both decoders retain encoder priming; compare the same frame.
          let j = frames * 1024 + i
          assert_true(j * 2 + 1 < pcm.length())
          let want = (pcm[j * 2 + 1].to_int() << 8) | pcm[j * 2].to_int()
          let want = if want >= 32768 { want - 65536 } else { want }
          let got = aac_s16p(v)
          let d = if got > want { got - want } else { want - got }
          if d > max_diff {
            max_diff = d
          }
          if d == 0 {
            exact = exact + 1
          }
          compared = compared + 1
        }
      }
      Err(e) => fail("AAC frame \{frames}: \{e}")
    }
    frames = frames + 1
    pos = pos + len
  }
  assert_eq(pos, data.length())
  assert_eq(frames, 46)
  assert_eq(compared * 2, pcm.length())
  assert_eq(compared, 47104)
  assert_true(max_diff <= 1)
  assert_true(exact * 1000 >= compared * 999)
  assert_true(nonzero * 10 > frames * 1024)
}

///|
/// Quantise one normalized PCM sample to signed 16-bit, with clipping. */
fn aac_s16p(x : Double) -> Int {
  let v = x * 32768.0
  if v >= 32767.5 {
    32767
  } else if v <= -32768.5 {
    -32768
  } else {
    v.round().to_int()
  }
}
