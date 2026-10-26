///|
test "opus CELT: continuous 48 kHz PCM matches original FFmpeg synthesis" {
  let mut count = 0
  let mut max_error = 0.0
  let mut tails = 0
  for corpus_index, corpus in opus_celt_spectrum_corpora {
    let head = opus_parse_head(
      @libavutil.av_base64_decode(corpus.head, 10000).unwrap(),
    ).unwrap()
    let decoders = [
      for phase in 0..<2 => {
        [
          for stream in 0..<head.stream_count => {
            OpusCeltDecoder::new(
              if stream < head.coupled_count {
                2
              } else {
                1
              },
              apply_phase_inv=phase != 0,
            ).unwrap()
          }
        ]
      }
    ]
    let mut index = 0
    for packet, encoded in corpus.packets {
      let data = @libavutil.av_base64_decode(encoded, 10000).unwrap()
      for stream, pkt in head.parse_packet(data).unwrap() {
        let p = pkt.packet
        let begin = pkt.offset + p.frame_offsets[0]
        let end_band = if p.bandwidth == "narrowband" { 13 } else { 21 }
        for phase in 0..<2 {
          let pcm = decoders[phase][stream]
            .decode_frame(
              data[begin:begin + p.frame_sizes[0]].to_owned(),
              p.frame_duration,
              end_band,
            )
            .unwrap()
          let fields = opus_pvq_reference_fields(
            opus_celt_pcm_reference[corpus_index][index],
          )
          let channels = if p.stereo { 2 } else { 1 }
          assert_eq(
            [packet, stream, phase, p.frame_duration, channels],
            [
              for i in 0..<5 => fields[i].to_int()
            ],
          )
          for channel in 0..<channels {
            for i, value in pcm[channel] {
              let expected = Float::reinterpret_from_uint(
                fields[9 + channel * p.frame_duration + i].to_uint(),
              )
              assert_true(!value.is_nan() && !value.is_inf())
              let error = (value.to_double() - expected.to_double()).abs()
              max_error = max_error.max(error)
              if error > 0.000003 {
                fail(
                  corpus.name +
                  " packet \{packet} stream \{stream} phase \{phase} channel \{channel} sample \{i}: \{value} != \{expected} error=\{error}",
                )
              }
            }
          }
          index += 1
          count += 1
        }
      }
    }
    assert_eq(index, opus_celt_pcm_reference[corpus_index].length())
    for line in opus_celt_pcm_tail_reference[corpus_index] {
      let fields = opus_pvq_reference_fields(line)
      let stream = fields[0].to_int()
      let phase = fields[1].to_int()
      let size = fields[3].to_int()
      let channels = fields[4].to_int()
      let pcm = decoders[phase][stream]
        .decode_frame(b"\xff\xfe", size, 13)
        .unwrap()
      for channel in 0..<channels {
        for i, value in pcm[channel] {
          let expected = Float::reinterpret_from_uint(
            fields[9 + channel * size + i].to_uint(),
          )
          assert_true(!value.is_nan() && !value.is_inf())
          let error = (value.to_double() - expected.to_double()).abs()
          max_error = max_error.max(error)
          assert_true(error <= 0.000003)
        }
      }
      tails += 1
    }
  }
  assert_eq(count, 168)
  assert_eq(tails, 144)
  assert_true(max_error <= 0.000003)
}

///|
test "opus CELT: failed frames preserve synthesis state and reset reproduces a fresh decoder" {
  let corpus = opus_celt_spectrum_corpora[2]
  let first = @libavutil.av_base64_decode(corpus.packets[0], 10000).unwrap()
  let packet = opus_parse_packet(first).unwrap()
  let begin = packet.frame_offsets[0]
  let data = first[begin:begin + packet.frame_sizes[0]].to_owned()
  let decoder = OpusCeltDecoder::new(2).unwrap()
  let fresh = decoder.decode_frame(data, 120, 21).unwrap()
  let history = decoder.history
  let buffers = decoder.synthesis.map(fn(channel) { channel.buffer.copy() })
  assert_true(decoder.decode_frame(data, 121, 21) is Err(_))
  assert_true(decoder.decode_frame(data, 120, 22) is Err(_))
  assert_true(decoder.decode_frame(b"", 120, 21) is Err(_))
  assert_eq(decoder.history.energy, history.energy)
  assert_eq(decoder.history.previous, history.previous)
  assert_eq(decoder.history.seed, history.seed)
  for channel in 0..<2 {
    assert_eq(decoder.synthesis[channel].buffer, buffers[channel])
  }
  let reference = OpusCeltDecoder::new(2).unwrap()
  assert_eq(reference.decode_frame(data, 120, 21).unwrap(), fresh)
  assert_eq(
    decoder.decode_frame(data, 120, 21).unwrap(),
    reference.decode_frame(data, 120, 21).unwrap(),
  )
  decoder.reset()
  assert_eq(decoder.decode_frame(data, 120, 21).unwrap(), fresh)
}
