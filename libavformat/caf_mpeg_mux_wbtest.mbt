///|
test "CAF mp2 export drains the filter delay and preserves the sample count" {
  for (rate, channels, frames) in [(24000, 1, 1152), (44100, 2, 5203)] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    let impulse = frames - 32
    wav.write_samples(
      Array::makei(frames * channels, i => {
        if i / channels == impulse {
          24000
        } else {
          0
        }
      })[:],
    )
    let encoded = decode_audio_file(wav.finish()).to_caf_mp2()
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.format.frames_per_packet, 1152)
    assert_eq(track.priming, 481)
    assert_eq(track.packets[0].pts, -481L)
    assert_eq(track.packets.length(), (frames + 481 + 1151) / 1152)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.codec_id(), "mp2")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), rate)
    for plane in decoded.samples() {
      assert_eq(plane.length(), frames)
      let mut peak = 0
      for i in 1..<frames {
        if plane[i].abs() > plane[peak].abs() {
          peak = i
        }
      }
      assert_eq(peak, impulse)
    }
    let broken = encoded.to_array()
    broken[track.data_offset.to_int()] = 0
    assert_true(
      av_caf_open(Bytes::from_array(broken))
      is Err("caf: MPEG audio frame does not match its packet description"),
    )
  }
}

///|
test "CAF mp3 export preserves sample alignment and drains the last frame" {
  for
    (rate, channels, frames, block) in [
      (44100, 2, 5203, 1152),
      (24000, 1, 1152, 576),
      (8000, 1, 577, 576),
      (8000, 2, 577, 576),
    ] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    let burst = frames - 300
    wav.write_samples(
      Array::makei(frames * channels, i => {
        let n = i / channels - burst + i % channels * 17
        if n >= 0 && n < 256 {
          let phase = n * (n + 140) / 32 % 64
          (16 - (phase - 32).abs()) * n.min(255 - n) * 12
        } else {
          0
        }
      })[:],
    )
    let input = decode_audio_file(wav.finish())
    let encoded = input.to_caf_mp3()
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.format.frames_per_packet, block)
    assert_eq(track.priming, 1057)
    assert_eq(track.packets.length(), (frames + 1057 + block - 1) / block)
    assert_eq(track.sample_count, frames.to_int64())
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.codec_id(), "mp3")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), rate)
    for channel, plane in decoded.samples() {
      assert_eq(plane.length(), frames)
      let reference = input.samples()[channel]
      let mut best = 0.0
      let mut best_lag = 0
      for lag in -160..<=160 {
        let mut score = 0.0
        for i in (burst - 17)..<(burst + 256) {
          let j = i + lag
          if j >= 0 && j < frames {
            score += reference[i] * plane[j]
          }
        }
        if score > best {
          best = score
          best_lag = lag
        }
      }
      let mut reference_energy = 0.0
      for i in (burst - 17)..<(burst + 256) {
        reference_energy += reference[i] * reference[i]
      }
      assert_true(best > 0.5 * reference_energy)
      assert_eq(best_lag, 0)
    }
  }
}

///|
test "CAF mp3 remux preserves coded frames and Xing gapless playback" {
  let native = synth_id3v2() +
    @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()
  let source = av_mp3_open(native).unwrap()
  let encoded = av_caf_mux_mpeg_audio(native).unwrap()
  let track = av_caf_open(encoded).unwrap()
  assert_eq(track.sample_count, 4410L)
  assert_eq(track.priming, 1105)
  assert_eq(track.packets.length(), source.frames.length())
  for i, packet in track.packets {
    let start = source.frames[i].pos.to_int()
    let offset = packet.pos.to_int()
    assert_eq(
      encoded[offset:offset + packet.size],
      native[start:start + packet.size],
    )
  }
  assert_eq(
    decode_audio_file(encoded).samples(),
    decode_audio_file(native).samples(),
  )
  assert_true(
    av_caf_mux_mpeg_audio(native[:native.length() - 1].to_owned()) is Err(_),
  )
}
