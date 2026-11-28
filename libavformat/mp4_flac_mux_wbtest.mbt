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

///|
test "MP4 FLAC round-trips high sample rates and the short final frame" {
  let count = 4101
  let channels = 6
  let mask = 0x60fU
  let wav = wav_muxer_new(96000, channels, 32, channel_mask=mask).unwrap()
  wav.write_samples(
    Array::makei(count * channels, i => (i.to_uint64() * 2654435761UL).to_int())[:],
  )
  let audio = decode_audio_file(wav.finish())
  let file = audio.to_mp4_flac(bits=32)
  let movie = av_mov_open(file).unwrap()
  let track = movie.tracks[0]
  assert_eq(track.sample_rate, 96000U)
  assert_eq(track.bits_per_sample, 32U)
  assert_eq(track.channels, 6U)
  assert_eq(track.samples.map(frame => (frame.pts, frame.duration)), [
    (0L, 4096U),
    (4096L, 5U),
  ])
  let media = MediaFile::open(file)
  assert_eq(media.streams()[0].sample_rate, 96000)
  let decoded = decode_audio_file(file)
  assert_eq(decoded.sample_rate(), 96000)
  assert_eq(decoded.channel_mask, mask)
  assert_eq(decoded.samples()[0].length(), count)
  assert_eq(decoded.samples(), audio.samples())
}

///|
test "MP4 FLAC remux retains native frames and STREAMINFO" {
  let flac = @libavcodec.flac_encode(
    Array::makei(117, i => i * 257 - 15000),
    1,
    44100,
    16,
    block_size=32,
  ).unwrap()
  let native = flac.file()
  let file = av_mp4_mux_flac(native).unwrap()
  let track = av_mov_open(file).unwrap().tracks[0]
  assert_eq(track.extradata, Some(flac.streaminfo))
  assert_eq(track.samples.length(), flac.frames.length())
  for i, frame in track.samples {
    let start = frame.offset.to_int()
    assert_eq(
      file[start:start + frame.size.reinterpret_as_int()],
      flac.frames[i],
    )
  }
  assert_true(
    av_mp4_mux_flac(native[:native.length() - 1].to_owned()) is Err(_),
  )
}
