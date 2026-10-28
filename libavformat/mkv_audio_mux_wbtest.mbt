///|
/// Audio-only Matroska writers: AAC and FLAC tracks are written, parsed back
/// by `av_matroska_open` and decoded. Fixtures are shared with the container
/// read and Ogg-FLAC tests in this package.

///|
test "mkv muxer: AAC-only track round-trip" {
  let data = @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap()
  let src = av_matroska_open(data).unwrap()
  let audio = src.tracks[1]
  let asc = audio.codec_priv.unwrap()
  let mux = mkv_aac_muxer_new(
    audio.audio.samplerate.to_int(),
    channels=audio.audio.channels.to_int(),
    asc=Some(asc),
    codec_delay_ns=audio.codec_delay,
  ).unwrap()
  let mut count = 0
  let src_packets : Array[Bytes] = []
  for p in src.packets {
    if p.stream_index != 1 {
      continue
    }
    let dur = if p.duration > 0UL { p.duration.to_int() } else { 23 }
    mux.write_packet(p.data, p.pts + 23L, dur).unwrap()
    src_packets.push(p.data)
    count = count + 1
  }
  assert_eq(count, 45)
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "A_AAC")
  assert_eq(track.codec_priv.unwrap(), asc)
  assert_eq(track.audio.channels, 1UL)
  assert_eq(mkv.packets.length(), 45)
  assert_eq(mkv.packets[0].pts, -23L)
  assert_eq(mkv.packets[1].pts, 0L)
  // The remux is byte-transparent: FFmpeg decodes the muxed file to the same
  // PCM as the source track.
  for i, p in mkv.packets {
    assert_eq(p.data, src_packets[i])
  }
  let dec = @libavcodec.new_aac_decoder_from_asc(asc).unwrap()
  for p in mkv.packets {
    match dec.decode_frame(p.data) {
      Ok(_) => ()
      Err(e) => fail("AAC decode failed: \{e}")
    }
  }
}

///|
test "mkv muxer: FLAC-only track round-trip and decode" {
  let ogg = @libavutil.av_base64_decode(ogg_flac_b64, 1000000).unwrap()
  let src = av_ogg_flac_open(ogg).unwrap()
  let mux = mkv_flac_muxer_new(src.streaminfo, headers=src.headers).unwrap()
  for i, frame in src.frames {
    mux.write_packet(frame.data, i.to_int64() * 20L, 20).unwrap()
  }
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "A_FLAC")
  assert_eq(track.audio.channels, 1UL)
  assert_eq(track.audio.bitdepth, 24UL)
  assert_eq(mkv.packets.length(), 9)
  let private = track.codec_priv.unwrap()
  assert_eq(private[0].to_int(), 0x66)
  assert_eq(private[1].to_int(), 0x4C)
  let joined : Array[Byte] = []
  for b in private {
    joined.push(b)
  }
  for p in mkv.packets {
    for b in p.data {
      joined.push(b)
    }
  }
  let audio = match @libavcodec.ff_flac_decode(Bytes::from_array(joined)) {
    Ok(v) => v
    Err(e) => fail("FLAC decode failed: \{e}")
  }
  assert_eq(ogg_flac_md5(audio.pcm_bytes()), ogg_flac_pcm_md5)
}
