///|
fn wav_spdif_test_burst(kind : Int32, period : Int32, coded : Bytes) -> Bytes {
  let burst = b"\x72\xf8\x1f\x4e".to_array()
  wav_mux_u16(burst, kind)
  wav_mux_u16(
    burst,
    if kind == 0x15 {
      coded.length()
    } else {
      coded.length() * 8
    },
  )
  for i in 0..<coded.length() {
    burst.push(coded[i ^ 1])
  }
  while burst.length() < period {
    burst.push(0)
  }
  Bytes::from_array(burst)
}

///|
test "raw IEC 61937, WAV, and Wave64 unwrap compressed payloads for playback" {
  let ac3 = ac3_decode(ac3_mono44_b64)
  let eac3 = eac3_decode(eac3_mono48_b64)
  let dts = playback_audit_dts_fixture()
  for
    (kind, period, size, rate, raw, codec) in [
      (0x01, 6144, av_ac3_open(ac3).unwrap().frames[0].size, 44100, ac3, "ac3"),
      (
        0x15,
        24576,
        av_ac3_open(eac3).unwrap().frames[0].size,
        192000,
        eac3,
        "eac3",
      ),
      (0x0b, 2048, 1008, 48000, dts, "dts"),
    ] {
    let first = raw[:size].to_owned()
    let second_size = if codec == "dts" {
      size
    } else {
      av_ac3_open(raw).unwrap().frames[1].size
    }
    let second = raw[size:size + second_size].to_owned()
    let burst1 = wav_spdif_test_burst(kind, period, first)
    let burst2 = wav_spdif_test_burst(kind, period, second)
    let spdif = burst1 + burst2
    let track = av_spdif_open(spdif).unwrap()
    assert_eq(track.codec, codec)
    assert_eq(track.frames.map(p => p.pos), [8L, period.to_int64() + 8L])
    assert_eq(spdif_packet_data(spdif, track.frames[1]).unwrap(), second)
    let audio = decode_audio_file(spdif)
    let expected = decode_audio_file(first + second)
    assert_eq(audio.format_name, "spdif")
    assert_eq(audio.samples, expected.samples)
    let wav = wav_muxer_new(rate, 2, 16).unwrap()
    let wave64 = w64_muxer_new(rate, 2, 16).unwrap()
    for burst in [burst1, burst2] {
      wav.data.append(burst.to_array())
      wave64.data.append(burst.to_array())
    }
    for
      (file, open, name) in [
        (wav.finish(), av_wav_open, "wav"),
        (wave64.finish(), av_w64_open, "w64"),
      ] {
      let demux = open(file).unwrap()
      assert_eq(demux.format.codec, codec)
      assert_eq(demux.packets.map(p => p.pos - demux.data_offset), [
        8L,
        period.to_int64() + 8L,
      ])
      assert_eq(demux.packet_data(file, demux.packets[0]).unwrap(), first)
      let media = MediaFile::open(file)
      assert_eq(media.format_name(), name)
      assert_eq(media.next_packet().unwrap().data, first)
      let packet = media.next_packet().unwrap()
      assert_eq(packet.data, second)
      assert_eq(packet.pts, if codec == "dts" { 512L } else { 1536L })
      assert_true(media.next_packet() is None)
      assert_eq(decode_audio_file(file).samples, expected.samples)
    }
  }
}

///|
test "raw S/PDIF finds a capture prefix and accepts omitted final padding" {
  let raw = playback_audit_dts_fixture()
  let first = wav_spdif_test_burst(0x0b, 2048, raw[:1008].to_owned())
  let second = wav_spdif_test_burst(0x0b, 2048, raw[1008:].to_owned())
  let prefix = b"\x00\x00\x72\xf8\x1f\x4e\x00\x00\x00\x00"
  let spdif = prefix + first + second[:1016].to_owned()
  let media = MediaFile::open(spdif)
  assert_eq(media.format_name(), "spdif")
  assert_eq(media.streams()[0].codec_id, "dts")
  assert_eq(media.duration_seconds(), Some(1024.0 / 48000.0))
  assert_eq(media.next_packet().unwrap().data, raw[:1008].to_owned())
  let packet = media.next_packet().unwrap()
  assert_eq(packet.pts, 512L)
  assert_eq(packet.data, raw[1008:].to_owned())
  assert_true(media.next_packet() is None)
  assert_eq(MediaFile::open(first[:1016].to_owned()).format_name(), "spdif")
  assert_true(
    av_spdif_open(prefix + first + second[:1014].to_owned())
    is Err("spdif: invalid or truncated burst"),
  )
}

///|
test "IEC 61937 E-AC-3 separates short frames and rejects truncated bursts" {
  let raw = eac3_decode(eac3_hi1blk_b64)
  let frame = av_ac3_open(raw).unwrap().frames[0]
  let coded = raw[:frame.size].to_owned()
  let mut burst_payload = b""
  for _ in 0..<(1536 / frame.duration) {
    burst_payload = burst_payload + coded
  }
  let burst = wav_spdif_test_burst(0x15, 24576, burst_payload)
  let wav = wav_muxer_new(192000, 2, 16).unwrap()
  wav.data.append((burst + burst).to_array())
  let file = wav.finish()
  let demux = av_wav_open(file).unwrap()
  assert_eq(demux.format.codec, "eac3")
  assert_eq(demux.format.sample_rate, 48000)
  assert_eq(demux.sample_count, 3072L)
  assert_eq(demux.packets.length(), 3072 / frame.duration)
  for i, packet in demux.packets {
    assert_eq(packet.pts, i.to_int64() * frame.duration.to_int64())
    assert_eq(demux.packet_data(file, packet).unwrap(), coded)
  }
  for payload in [burst, burst + burst[:16].to_owned()] {
    let pcm = wav_muxer_new(192000, 2, 16).unwrap()
    pcm.data.append(payload.to_array())
    assert_eq(av_wav_open(pcm.finish()).unwrap().format.codec, "pcm_s16le")
  }
}
