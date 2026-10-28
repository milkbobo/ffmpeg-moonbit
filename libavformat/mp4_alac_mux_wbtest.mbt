///|
/// ALAC-in-MP4 writer round-trip: the real ffmpeg m4a is demuxed, its magic
/// cookie and six packets are remuxed with `Mp4AlacMuxer`, and the output is
/// read back and decoded to the same PCM as the source (FFmpeg reference).

///|
fn mp4_alac_mux_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "mp4 muxer: ALAC track round-trip and decode" {
  let data = @libavutil.av_base64_decode(mp4_alac_real_b64, 200000).unwrap()
  let movie = match av_mov_open(data) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  let track = movie.tracks[0]
  let cookie = track.extradata.unwrap()
  let dec = @libavcodec.alac_decoder_new(cookie).unwrap()
  let mux = mp4_alac_muxer_new(cookie).unwrap()
  let original_pcm : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = data[start:end].to_owned()
    let frame = match dec.decode_frame(packet) {
      Ok(v) => v
      Err(e) => fail("source ALAC decode failed: \{e}")
    }
    mux.write_packet(packet, duration=frame.nb_samples).unwrap()
    for b in frame.pcm_bytes() {
      original_pcm.push(b)
    }
  }
  assert_eq(original_pcm.length(), 88200)
  assert_eq(
    mp4_alac_mux_md5(Bytes::from_array(original_pcm)),
    "38fb308079b63baf40e49bd051d22bc8",
  )
  let out = mux.finish()
  let movie2 = match av_mov_open(out) {
    Ok(v) => v
    Err(e) => fail("remuxed open failed: \{e}")
  }
  assert_eq(movie2.tracks.length(), 1)
  let track2 = movie2.tracks[0]
  assert_eq(track2.codec, "alac")
  assert_eq(mov_codec_name(track2.codec, track2.codec_id), "alac")
  assert_eq(track2.sample_rate, 44100U)
  assert_eq(track2.channels, 2U)
  assert_eq(track2.samples.length(), 6)
  assert_eq(track2.extradata.unwrap(), cookie)
  let dec2 = @libavcodec.alac_decoder_new(track2.extradata.unwrap()).unwrap()
  let remuxed : Array[Byte] = []
  for sample in track2.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let frame = match dec2.decode_frame(out[start:end].to_owned()) {
      Ok(v) => v
      Err(e) => fail("remuxed ALAC decode failed: \{e}")
    }
    for b in frame.pcm_bytes() {
      remuxed.push(b)
    }
  }
  assert_eq(remuxed.length(), original_pcm.length())
  for i = 0; i < remuxed.length(); i = i + 1 {
    assert_eq(remuxed[i], original_pcm[i])
  }
}
