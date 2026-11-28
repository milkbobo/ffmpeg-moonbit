///|
test "remuxing AAC-LC ADTS reproduces the FFmpeg LOAS fixtures" {
  for (fixture, channels) in [(loas_mono_b64, 1), (loas_stereo_b64, 2)] {
    let expected = @libavutil.av_base64_decode(fixture, 1024).unwrap()
    let parsed = @libavcodec.latm_parse_stream(expected).unwrap()
    let asc = @libavcodec.aac_parse_audio_specific_config(parsed.asc).unwrap()
    let adts : Array[Byte] = []
    for frame in parsed.frames {
      let header = @libavcodec.aac_adts_header_write(
        asc.config.sample_rate,
        channels,
        2,
        frame.length() + 7,
      ).unwrap()
      for byte in header {
        adts.push(byte)
      }
      for byte in frame {
        adts.push(byte)
      }
    }
    let input = Bytes::from_array(adts)
    assert_eq(av_loas_from_adts(input).unwrap(), expected)
    assert_true(
      av_loas_from_adts(input[:input.length() - 1].to_owned())
      is Err("latm: missing or truncated ADTS payload"),
    )
  }
}

///|
test "LOAS mux repeats its config and handles an exact 255-byte AAC slot" {
  let mux = LoasAacMuxer::new(b"\x12\x10", config_interval=2).unwrap()
  let frame = Bytes::make(255, 0xe0)
  for _ in 0..<3 {
    mux.write_packet(frame[:]).unwrap()
  }
  let data = mux.finish()
  let stream = @libavcodec.latm_parse_stream(data).unwrap()
  assert_eq(stream.frames, [frame, frame, frame])
  assert_eq(stream.frame_ranges.map(pair => data[pair.0 + 3].to_int() >> 7), [
    0, 1, 0,
  ])
}

///|
fn loas_test_otherdata(config : Bool, include_other_data : Bool) -> Bytes {
  let bits = @libavcodec.BitWriter::new()
  bits.put_bit(if config { 0 } else { 1 })
  if config {
    bits.put(1U, 2) // audioMuxVersion=0, allStreamsSameTimeFraming=1
    bits.put(0U, 13)
    bits.put(0x1210U, 16)
    bits.put(0U, 3)
    bits.put(255U, 8)
    bits.put_bit(1) // otherDataPresent
    bits.put(16U, 9) // no escape, 16 bits outside the AAC payload
    bits.put_bit(0) // no config CRC
  }
  bits.put(1U, 8)
  bits.put(0xe0U, 8)
  if include_other_data {
    bits.put(0xbeefU, 16)
  }
  let body = bits.finish()
  Bytes::from_array([0x56, 0xe0, body.length().to_byte()]) + body
}

///|
test "LOAS validates otherData length across repeated mux configurations" {
  let first = loas_test_otherdata(true, true)
  let second = loas_test_otherdata(false, true)
  let ok = @libavcodec.latm_parse_stream(first + second).unwrap()
  assert_eq(ok.frames, [b"\xe0", b"\xe0"])
  let truncated = loas_test_otherdata(false, false)
  assert_true(
    @libavcodec.latm_parse_stream(first + truncated)
    is Err("latm: truncated otherData payload"),
  )
}

///|
test "PCM to LOAS includes AAC priming and preserves the channel configuration" {
  let wav = wav_muxer_new(48000, 2, 16).unwrap()
  let samples = Array::makei(1301 * 2, i => 14000 - i * 499 % 28000)
  wav.write_samples(samples[:])
  let decoded = decode_audio_file(decode_audio_file(wav.finish()).to_loas())
  assert_eq(decoded.codec_id(), "aac_latm")
  assert_eq(decoded.sample_rate(), 48000)
  assert_eq(decoded.channels(), 2)
  assert_eq(decoded.samples()[0].length(), 3072)
}
