///|
/// FLAC-in-MP4 writer/demux test: the Ogg-FLAC fixture's STREAMINFO,
/// metadata block and 9 frames are muxed into an MP4 `fLaC`/`dfLa` track,
/// read back by `av_mov_open`, and the reassembled native FLAC stream is
/// decoded against the same FFmpeg PCM reference as the Ogg test.

///|
test "mp4 muxer: FLAC track round-trip and decode" {
  let ogg = @libavutil.av_base64_decode(ogg_flac_b64, 1000000).unwrap()
  let src = av_ogg_flac_open(ogg).unwrap()
  let mux = mp4_flac_muxer_new(src.streaminfo, headers=src.headers).unwrap()
  let mut frame_bytes = 0
  for frame in src.frames {
    mux.write_packet(frame.data, duration=1024).unwrap()
    frame_bytes = frame_bytes + frame.data.length()
  }
  let bytes = mux.finish()
  let movie = match av_mov_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "fLaC")
  assert_eq(mov_codec_name(track.codec, track.codec_id), "flac")
  assert_eq(track.sample_rate, 44100U)
  assert_eq(track.channels, 1U)
  assert_eq(track.samples.length(), 9)
  let streaminfo = track.extradata.unwrap()
  assert_eq(streaminfo, src.streaminfo)
  // Reassemble a native FLAC file from the demuxed STREAMINFO and samples.
  let joined : Array[Byte] = []
  for b in b"fLaC" {
    joined.push(b)
  }
  joined.push(b'\x80')
  joined.push(b'\x00')
  joined.push(b'\x00')
  joined.push(b'\x22')
  for b in streaminfo {
    joined.push(b)
  }
  let mut payload = 0
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in bytes[start:end] {
      joined.push(b)
    }
    payload = payload + sample.size.reinterpret_as_int()
  }
  assert_eq(payload, frame_bytes)
  let audio = match @libavcodec.ff_flac_decode(Bytes::from_array(joined)) {
    Ok(v) => v
    Err(e) => fail("FLAC decode failed: \{e}")
  }
  assert_eq(ogg_flac_md5(audio.pcm_bytes()), ogg_flac_pcm_md5)
}
