///|
fn check_raw_telephony(
  encoded : Bytes,
  filename : String,
  format : String,
  codec : String,
  rate : Int32,
  bits : Int32,
  md5 : String,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 128).unwrap()
  let audio = decode_audio_file(data, filename~, g726_bits=bits)
  assert_eq(audio.format_name, format)
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.sample_rate, rate)
  assert_eq(audio.channels, 1)
  assert_eq(audio.read_error, "")
  let count = data.length() * 8 / bits
  assert_eq(audio.duration_seconds, Some(count.to_double() / rate.to_double()))
  let wave = audio.to_wav_s16()
  let wav = av_wav_open(wave).unwrap()
  assert_eq(wav.data_size, count.to_int64() * 2L)
  assert_eq(caf_md5(wave[wav.data_offset.to_int():].to_owned()), md5)
}

///|
test "Raw G.722 matches the start of the FFmpeg FATE sample" {
  check_raw_telephony(
    b"3nr38Pf06qWmqOjp6azs7rCx9PZ6/P6f//6eXJya2tvb3V79/Z/8/b7efp3b353a", "call.722",
    "g722", "adpcm_g722", 16000, 4, "0a817c89ae3d0d3f2590dab89ab3e28a",
  )
}

///|
/// The first 15 bytes of FFmpeg-encoded G.726 surround a whole number
/// of codewords for each width. Compare against FFmpeg's raw decoder.
test "Raw G.726 matches FFmpeg for both bit orders and four code widths" {
  for
    (bits, msb, lsb, expected) in [
      (
        2, b"FSrVKhTv1PsE+wT7BPvQ", b"VKhXqBT7F+8Q7xDvEO8H", "3267747a374e5ef718305f75d7bb966f",
      ),
      (
        3, b"7bMkzb8l6S9t6S9t6S9t", b"3xaS3nayl/S2l/S2l/S2", "618d0db7ac78984844a0ef8aaa36bd96",
      ),
      (
        4, b"93cYiPdy/Lz0U/us9FT7", b"f3eBiH8nz8tPNb/KT0W/", "3a295f0809395e305ad1176146fd328f",
      ),
      (
        5, b"+97xwhD73s9Sl/oSf+LY", b"/703IIT/PeYpvR+l87HF", "c9c39fb54f307a5ad6069deaf3bf8e88",
      ),
    ] {
    check_raw_telephony(
      msb, "call.g726", "g726", "adpcm_g726", 8000, bits, expected,
    )
    check_raw_telephony(
      lsb, "call.G726LE", "g726le", "adpcm_g726le", 8000, bits, expected,
    )
  }
}

///|
test "Raw telephony packet sizes preserve codeword boundaries and sample PTS" {
  let raw = Bytes::make(1027, 0xA8)
  let g726 = MediaFile::open(raw, filename="call.g726", g726_bits=3)
  let first = g726.next_packet().unwrap()
  let last = g726.next_packet().unwrap()
  assert_eq((first.pts, first.data.length()), (0L, 1020))
  assert_eq((last.pts, last.data.length()), (2720L, 7))
  assert_true(g726.next_packet() is None)
  let g722 = MediaFile::open(raw, filename="call.g722")
  assert_eq(g722.next_packet().unwrap().data.length(), 1024)
  assert_eq(g722.next_packet().unwrap().pts, 2048L)
  let budgeted = Ok(
    decode_audio_file(
      raw,
      filename="call.g726le",
      g726_bits=3,
      sample_budget=2737L,
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    budgeted is Err(DecodeError("decoded audio sample budget exceeded")),
  )
  let wav = decode_audio_file(b"\xff", filename="x.g722").to_wav_s16()
  assert_eq(MediaFile::open(wav, filename="x.g722").format_name(), "wav")
}
