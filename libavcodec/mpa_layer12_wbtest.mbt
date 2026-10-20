///|
/// White-box tests for the MPEG-1/2/2.5 Layer I and Layer II decoders. Every
/// expected PCM MD5 comes from FFmpeg 9.0.2's fixed decoder (see
/// `mpa_layer12_realdata_wbtest.mbt` for the generator commands).

///| Lowercase hex of a byte buffer.
fn mpa_hex(bytes : FixedArray[Byte], n : Int) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///| S16 little-endian MD5 of an interleaved sample buffer.
fn mpa_pcm_md5(samples : Array[Int]) -> String {
  let bytes = FixedArray::make(samples.length() * 2, b'\x00')
  for i = 0; i < samples.length(); i = i + 1 {
    let v = samples[i]
    bytes[2 * i] = (v & 0xFF).to_byte()
    bytes[2 * i + 1] = ((v >> 8) & 0xFF).to_byte()
  }
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, Bytes::from_array(bytes[:]), bytes.length())
  mpa_hex(digest, 16)
}


test "mp2: Layer II stereo 44.1 kHz 192 kbit/s matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp2_stereo_44_192_b64, 8192).unwrap()
  assert_eq(data.length(), 3761)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.samples.length(), 6 * 1152 * 2)
  assert_eq(mpa_pcm_md5(pcm.samples), "818bac4aa56cc891a5561ec134c28bbb")
}

test "mp2: Layer II mono 44.1 kHz 64 kbit/s matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp2_mono_44_64_b64, 8192).unwrap()
  assert_eq(data.length(), 1253)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 1)
  assert_eq(pcm.samples.length(), 6 * 1152 * 1)
  assert_eq(mpa_pcm_md5(pcm.samples), "5c6c8e4798028f8588b75bfca5a9e749")
}

test "mp2: Layer II joint stereo 32 kHz 64 kbit/s matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp2_jstereo_32_64_b64, 8192).unwrap()
  assert_eq(data.length(), 1728)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 32000)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.samples.length(), 6 * 1152 * 2)
  assert_eq(mpa_pcm_md5(pcm.samples), "941cb1331dd0cadd6f31d248e9ed0fe1")
}

test "mp2: Layer II MPEG-2 LSF stereo 24 kHz 64 kbit/s matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp2_lsf_24_64_b64, 8192).unwrap()
  assert_eq(data.length(), 1920)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 24000)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.samples.length(), 5 * 1152 * 2)
  assert_eq(mpa_pcm_md5(pcm.samples), "f9bf90373e6ac4beadf057212f42a27f")
}

test "mp1: Layer I mono 32 kHz 192 kbit/s (hand-built frames) matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp1_mono_32_192_b64, 4096).unwrap()
  assert_eq(data.length(), 864)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 32000)
  assert_eq(pcm.channels, 1)
  assert_eq(pcm.samples.length(), 3 * 384 * 1)
  assert_eq(mpa_pcm_md5(pcm.samples), "cb2824e3d226eedf3a5f767d6aeeda0e")
}

test "mp1: Layer I joint stereo 44.1 kHz 256 kbit/s (hand-built frames) matches FFmpeg fixed decoder" {
  let data = @libavutil.av_base64_decode(mp1_jstereo_44_256_b64, 4096).unwrap()
  assert_eq(data.length(), 828)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.samples.length(), 3 * 384 * 2)
  assert_eq(mpa_pcm_md5(pcm.samples), "a0ed4a9298f947149e977b1bbccde3b6")
}

test "mpa: reserved layer field is rejected instead of misparsed" {
  // `layer(2) == 0` maps to `4 - 0 == 4` in the header parser, which no layer
  // decoder claims; the entry point must report it rather than decode silence.
  let frame : FixedArray[Byte] = FixedArray::make(288, b'\x00')
  frame[0] = b'\xff'
  frame[1] = b'\xfd' // 1111 1101: sync ok, MPEG-1, layer bits 00 (reserved)
  frame[2] = b'\x00'
  frame[3] = b'\x00'
  let bytes = Bytes::from_array(frame[:])
  match decode_mp3_stream(bytes) {
    Ok(_) => fail("reserved layer decoded")
    Err(_) => ()
  }
}
