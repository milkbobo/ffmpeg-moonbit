///|
test "Opus: real 5.1 WebM header, output maps and all logical packet spans match C" {
  let data = @libavutil.av_base64_decode(opus_51_webm_b64, 100000).unwrap()
  let mkv = av_matroska_open(data).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  assert_eq(mkv.packets.length(), 4)
  let head = @libavcodec.opus_parse_head(mkv.tracks[0].codec_priv.unwrap()).unwrap()
  assert_eq(head.mapping_family, 1)
  assert_eq(head.input_sample_rate, 48000U)
  assert_eq(head.channel_map, [0, 4, 1, 2, 3, 5])
  let params = mkv_track_codec_parameters(mkv.tracks[0])
  assert_eq(params.channels, 6)
  assert_eq(params.sample_rate, 48000)
  assert_eq(params.initial_padding, 312)
  assert_true(params.extradata_parsed)
  let actual : Array[String] = []
  actual.push(
    "H \{head.channels} \{head.pre_skip} \{head.output_gain} \{head.stream_count} \{head.coupled_count}",
  )
  for i, map in head.output_map {
    let silence = if map.silence { 1 } else { 0 }
    let copy = match map.copy_from {
      Some(index) => index
      None => -1
    }
    actual.push(
      "M \{i} \{map.stream_index} \{map.channel_index} \{silence} \{copy}",
    )
  }
  for index, packet in mkv.packets {
    assert_eq(packet.data.length(), 640)
    let streams = head.parse_packet(packet.data).unwrap()
    assert_eq(streams.length(), 4)
    let mut consumed = 0
    for i, stream in streams {
      assert_eq(stream.offset, consumed)
      let p = stream.packet
      let stereo = if p.stereo { 1 } else { 0 }
      assert_eq(p.total_samples, 960)
      actual.push(
        "P \{index} \{i} \{stream.offset} \{p.packet_size} \{p.config} \{stereo} \{p.frame_count} \{p.frame_duration}",
      )
      for j in 0..<p.frame_count {
        actual.push(
          "F \{index} \{i} \{j} \{p.frame_offsets[j]} \{p.frame_sizes[j]}",
        )
        let begin = stream.offset + p.frame_offsets[j]
        assert_true(
          begin + p.frame_sizes[j] <= stream.offset + p.packet_size - p.padding,
        )
      }
      consumed += p.packet_size
    }
    assert_eq(consumed, packet.data.length())
  }
  assert_eq(actual, opus_51_reference)
}

///|
test "Opus: malformed mapping does not override container metadata" {
  let invalid = b"OpusHead\x01\x06\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
  assert_true(opus_head_parse(invalid) is None)
  let params = codec_parameters_from_extradata(
    "opus",
    Some(invalid),
    0,
    0,
    44100,
    2,
  )
  assert_true(!params.extradata_parsed)
  assert_eq(params.channels, 2)
  assert_eq(params.sample_rate, 44100)
}

///|
test "Ogg Opus multistream preserves channel order and trims the closing page" {
  let data = @libavutil.av_base64_decode(opus_51_webm_b64, 100000).unwrap()
  let mkv = av_matroska_open(data).unwrap()
  let header = mkv.tracks[0].codec_priv.unwrap().to_array()
  // OpusHead's source rate is informational. The packet timebase and PCM
  // both remain 48 kHz when it names a different rate.
  header[12] = b'\x44'
  header[13] = b'\xac'
  let header = Bytes::from_array(header)
  let head = @libavcodec.opus_parse_head(header).unwrap()
  let encoded = mkv.packets.map(packet => packet.data)
  let out : Array[Byte] = []
  let serial = 37
  ogg_mux_page(out, serial, 0, 2, 0L, header)
  ogg_mux_page(out, serial, 1, 0, 0L, ogg_mux_opus_tags([]))
  let prefix = Bytes::from_array(out)
  ogg_mux_page_multi(out, serial, 2, 0, 1920L, [encoded[0], encoded[1]])
  ogg_mux_page_multi(out, serial, 3, 4, 3300L, [encoded[2], encoded[3]])
  let file = Bytes::from_array(out)
  let demux = av_ogg_opus_open(file).unwrap()
  assert_eq(demux.input_sample_rate, 44100)
  assert_eq(demux.channel_mask, 0x3FU)
  assert_eq(demux.end_trim, 540)
  assert_eq(demux.packets.map(packet => packet.pts), [-312L, 648L, 1608L, 2568L])
  assert_eq(demux.packets.map(packet => packet.duration), [960, 960, 960, 420])
  assert_eq(MediaFile::open(file).streams()[0].sample_rate, 48000)

  let audio = decode_audio_file(file)
  assert_eq(audio.channels, 6)
  assert_eq(audio.samples[0].length(), 2988)
  let decoder = @libavcodec.OpusDecoder::new(head).unwrap()
  let expected : Array[Array[Float]] = Array::makei(6, _ => [])
  for packet in encoded {
    let (rows, n) = decoder.decode_packet(Some(packet)).unwrap()
    for ch in 0..<6 {
      for i in 0..<n {
        expected[ch].push(rows[ch][i])
      }
    }
  }
  for ch in 0..<6 {
    for i in 0..<2988 {
      assert_eq(
        audio.samples[ch][i],
        expected[ch][i + head.pre_skip].to_double(),
      )
    }
  }
  let wav = av_wav_open(audio.to_wav_s16()).unwrap()
  assert_eq(wav.format.channel_mask, 0x3FU)
  assert_eq(wav.data_size, (2988 * 6 * 2).to_int64())

  let first_span = head.parse_packet(encoded[0]).unwrap()[1].offset
  let bad = prefix.to_array()
  ogg_mux_page(bad, serial, 2, 4, 960L, encoded[0][:first_span].to_owned())
  assert_true(av_ogg_opus_open(Bytes::from_array(bad)) is Err(_))
}

///|
test "Opus: real 5.1 MP4 dOps and multistream packets preserve WebM reference" {
  let bytes = @libavutil.av_base64_decode(opus_51_mp4_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let webm = av_matroska_open(
    @libavutil.av_base64_decode(opus_51_webm_b64, 100000).unwrap(),
  ).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  let head = @libavcodec.opus_parse_head(track.extradata.unwrap()).unwrap()
  assert_eq(track.extradata, webm.tracks[0].codec_priv)
  let params = mp4_track_codec_parameters(track)
  assert_eq(params.channels, 6)
  assert_eq(params.sample_rate, 48000)
  assert_eq(params.initial_padding, 312)
  assert_true(params.extradata_parsed)
  assert_eq(head.stream_count, 4)
  assert_eq(head.coupled_count, 2)
  assert_eq(track.samples.length(), webm.packets.length())
  for i, sample in track.samples {
    let begin = sample.offset.to_int()
    let packet = bytes[begin:begin + sample.size.reinterpret_as_int()].to_owned()
    assert_eq(packet, webm.packets[i].data)
    let streams = head.parse_packet(packet).unwrap()
    assert_eq(streams.length(), 4)
    for stream in streams {
      assert_eq(stream.packet.total_samples, 960)
    }
  }
}
