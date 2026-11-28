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
    language="eng",
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
  assert_eq(track.language, "eng")
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
test "Matroska AAC-LC trims priming and partial final blocks" {
  for
    (channels, rate, count) in [
      (1, 48000, 1),
      (1, 44100, 1024),
      (2, 32000, 5203),
    ] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let source = decode_audio_file(wav.finish())
    let encoded = source.to_mkv_aac()
    let mkv = av_matroska_open(encoded).unwrap()
    let rate64 = rate.to_int64()
    let rem = (1024 - count % 1024) % 1024
    assert_eq(
      mkv.tracks[0].codec_delay,
      @libavutil.av_rescale(1024L, 1000000000L, rate64).reinterpret_as_uint64(),
    )
    assert_eq(mkv.packets[1].pts, 0L)
    assert_eq(
      mkv.packets[mkv.packets.length() - 1].discard_padding,
      @libavutil.av_rescale(rem.to_int64(), 1000000000L, rate64),
    )
    let audio = decode_audio_file(encoded)
    assert_eq(audio.codec_id(), "aac")
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), rate)
    for plane in audio.samples() {
      assert_eq(plane.length(), count)
    }
    assert_true(
      audio.samples() == decode_audio_file(source.to_caf_aac()).samples(),
    )
  }
}

///|
test "Matroska AAC-LC negative discard padding trims the block head" {
  let wav = wav_muxer_new(48000, 1, 16).unwrap()
  wav.write_samples(Array::makei(2048, i => (i % 73 - 36) * 400)[:])
  let audio = decode_audio_file(wav.finish())
  let encoded = audio.to_mkv_aac()
  let mkv = av_matroska_open(encoded).unwrap()
  let delay = mkv.tracks[0].codec_delay
  let mux = mkv_aac_muxer_new(48000, channels=1, codec_delay_ns=delay).unwrap()
  for i, packet in mkv.packets {
    mux.write_packet(packet.data, (i * 21).to_int64(), 21).unwrap()
  }
  let trim = @libavutil.av_rescale(17L, 1000000000L, 48000L)
  let original = decode_audio_file(encoded).samples()[0]
  let actual = decode_audio_file(mux.serialize(None, -trim)).samples()[0]
  assert_eq(actual.length(), 2048 - 17)
  assert_true(actual[:1024].to_owned() == original[:1024].to_owned())
  assert_true(actual[1024:].to_owned() == original[1041:].to_owned())
}

///|
test "mkv muxer: FLAC-only track round-trip and decode" {
  let ogg = @libavutil.av_base64_decode(ogg_flac_b64, 1000000).unwrap()
  let src = av_ogg_flac_open(ogg).unwrap()
  let mux = mkv_flac_muxer_new(
    src.streaminfo,
    headers=src.headers,
    language="fra",
  ).unwrap()
  for i, frame in src.frames {
    mux.write_packet(frame.data, i.to_int64() * 20L, 20).unwrap()
  }
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "A_FLAC")
  assert_eq(track.language, "fra")
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

///|
test "Matroska FLAC preserves full PCM depth and a sub-millisecond final frame" {
  let count = 4101
  let wav = wav_muxer_new(96000, 6, 32, channel_mask=0x60fU).unwrap()
  wav.write_samples(
    Array::makei(count * 6, i => (i.to_uint64() * 2654435761UL).to_int())[:],
  )
  let audio = decode_audio_file(wav.finish())
  let file = audio.to_mkv_flac(bits=32)
  let mkv = av_matroska_open(file).unwrap()
  let params = mkv_track_codec_parameters(mkv.tracks[0])
  assert_true(params.extradata_parsed)
  assert_eq(params.bit_depth, 32)
  assert_eq(params.sample_rate, 96000)
  assert_eq(mkv.packets.map(p => p.pts), [0L, 43L])
  let decoded = decode_audio_file(file)
  assert_eq(decoded.channel_mask, 0x60fU)
  assert_eq(decoded.samples()[0].length(), count)
  assert_eq(decoded.samples(), audio.samples())
  assert_true(
    (decoded.duration_seconds().unwrap() - count.to_double() / 96000.0).abs() <
    0.0000000001,
  )
}

///|
test "Matroska audio muxing keeps timestamps across the signed cluster offset boundary" {
  let encoded = @libavcodec.flac_encode(Array::make(32, 0), 1, 48000, 16).unwrap()
  let mux = mkv_flac_muxer_new(encoded.streaminfo).unwrap()
  let times = [0L, 32767L, 32768L, 70000L]
  for time in times {
    mux.write_packet(encoded.frames[0], time, 1).unwrap()
  }
  let mkv = av_matroska_open(mux.finish()).unwrap()
  assert_eq(mkv.packets.map(p => p.pts), times)
  assert_true(mkv.packets.iter().all(p => p.data == encoded.frames[0]))
  let raw = encoded.file()
  let remuxed = av_matroska_open(av_mkv_mux_flac(raw).unwrap()).unwrap()
  assert_eq(remuxed.packets[0].data, encoded.frames[0])
  assert_true(av_mkv_mux_flac(raw[:raw.length() - 1].to_owned()) is Err(_))
}
