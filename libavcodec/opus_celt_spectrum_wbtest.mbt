///|
priv struct CeltSpectrumCorpus {
  name : String
  head : Bytes
  packets : Array[Bytes]
  normalized : Array[String]
  complete : Array[String]
}

///|
test "opus CELT: real normalized spectrum, masks and entropy match original C" {
  let mut count = 0
  let mut max_error = 0.0
  let mut saw_rng = false
  let mut saw_phase_difference = false
  for corpus in opus_celt_spectrum_corpora {
    let head = opus_parse_head(
      @libavutil.av_base64_decode(corpus.head, 10000).unwrap(),
    ).unwrap()
    let mut ref_index = 0
    for packet, encoded in corpus.packets {
      let data = @libavutil.av_base64_decode(encoded, 10000).unwrap()
      let streams = head.parse_packet(data).unwrap()
      for stream, pkt in streams {
        let p = pkt.packet
        assert_eq(p.frame_count, 1)
        let begin = pkt.offset + p.frame_offsets[0]
        let end = if p.bandwidth == "narrowband" { 13 } else { 21 }
        let mut phase_zero : Array[Array[Float]]? = None
        for phase in [false, true] {
          let rc = opus_rc_init(data[begin:begin + p.frame_sizes[0]].to_owned()).unwrap()
          let channels = if p.stereo { 2 } else { 1 }
          let setup = rc
            .decode_celt_setup(channels, p.frame_duration, 0, end)
            .unwrap()
          let seed = (12345 + packet * 17 + stream * 37).reinterpret_as_uint()
          let decoded = match
            rc.decode_celt_spectrum(setup, seed~, apply_phase_inv=phase) {
            Ok(value) => value
            Err(error) =>
              fail(corpus.name + " packet \{packet} stream \{stream}: " + error)
          }
          let f = opus_pvq_reference_fields(corpus.normalized[ref_index])
          saw_rng = saw_rng || decoded.seed != seed
          if !phase {
            phase_zero = Some(decoded.coefficients)
          } else if phase_zero is Some(first) {
            saw_phase_difference = saw_phase_difference ||
              decoded.coefficients != first
          }
          assert_eq(
            [
              packet,
              stream,
              if phase {
                1
              } else {
                0
              },
              p.frame_duration,
              channels,
            ],
            [
              for i in 0..<5 => f[i].to_int()
            ],
          )
          assert_eq(rc.range, f[5].to_uint())
          assert_eq(rc.value, f[6].to_uint())
          assert_eq(rc.total_bits, f[7].to_uint())
          assert_eq(rc.tell_frac(), f[8].to_int())
          assert_eq(decoded.seed, f[9].to_uint())
          for channel in 0..<channels {
            assert_eq(
              decoded.collapse_masks[channel],
              [
                for i in 0..<21 => f[10 + channel * 21 + i].to_uint()
              ],
            )
            for i, value in decoded.coefficients[channel] {
              let expected = Float::reinterpret_from_uint(
                f[10 + channels * 21 + channel * p.frame_duration + i].to_uint(),
              )
              let error = (value.to_double() - expected.to_double()).abs()
              max_error = max_error.max(error)
              assert_true(error <= 0.000001)
            }
          }
          count += 1
          ref_index += 1
        }
      }
    }
    assert_eq(ref_index, corpus.normalized.length())
  }
  assert_eq(count, 168)
  assert_true(max_error <= 0.000001)
  assert_true(saw_rng && saw_phase_difference)
}

///|
test "opus CELT: continuous complete frequency-domain frames match original C" {
  let mut count = 0
  let mut saw_anti = false
  let mut saw_anti_noise = false
  let mut saw_transient = false
  let mut saw_postfilter = false
  for corpus in opus_celt_spectrum_corpora {
    let head = opus_parse_head(
      @libavutil.av_base64_decode(corpus.head, 10000).unwrap(),
    ).unwrap()
    let histories = [
      for _ in 0..<2 => {
        [
          for _ in 0..<head.stream_count => OpusCeltHistory::new()
        ]
      }
    ]
    let mut ref_index = 0
    for packet, encoded in corpus.packets {
      let data = @libavutil.av_base64_decode(encoded, 10000).unwrap()
      for stream, pkt in head.parse_packet(data).unwrap() {
        let p = pkt.packet
        let begin = pkt.offset + p.frame_offsets[0]
        let end = if p.bandwidth == "narrowband" { 13 } else { 21 }
        for phase in 0..<2 {
          let rc = opus_rc_init(data[begin:begin + p.frame_sizes[0]].to_owned()).unwrap()
          let channels = if p.stereo { 2 } else { 1 }
          let old = histories[phase][stream]
          let energy = old.energy.copy()
          let previous = old.previous.copy()
          let frame = match
            rc.decode_celt_coefficients(
              old,
              channels,
              p.frame_duration,
              0,
              end,
              apply_phase_inv=phase != 0,
            ) {
            Ok(value) => value
            Err(error) =>
              fail(
                corpus.name +
                " complete packet \{packet} stream \{stream}: " +
                error,
              )
          }
          assert_eq(old.energy, energy)
          assert_eq(old.previous, previous)
          histories[phase][stream] = frame.history
          saw_anti = saw_anti || frame.anticollapse
          if frame.anticollapse {
            for row in frame.collapse_masks {
              for band in 0..<end {
                saw_anti_noise = saw_anti_noise ||
                  row[band] != (1U << frame.blocks) - 1U
              }
            }
          }
          saw_transient = saw_transient || frame.transient
          saw_postfilter = saw_postfilter || frame.postfilter_period > 0
          let f = opus_pvq_reference_fields(corpus.complete[ref_index])
          assert_eq(
            [packet, stream, phase, p.frame_duration, channels],
            [
              for i in 0..<5 => f[i].to_int()
            ],
          )
          assert_eq(rc.range, f[5].to_uint())
          assert_eq(rc.value, f[6].to_uint())
          assert_eq(rc.total_bits, f[7].to_uint())
          assert_eq(rc.tell_frac(), f[8].to_int())
          assert_eq(frame.history.seed, f[9].to_uint())
          assert_eq(frame.silence, f[10] == 1UL)
          assert_eq(frame.transient, f[11] == 1UL)
          assert_eq(frame.blocks, f[12].to_int())
          assert_eq(frame.anticollapse, f[13] == 1UL)
          assert_eq(frame.postfilter_period, f[14].to_int())
          for i, gain in frame.postfilter_gains {
            assert_eq(gain.reinterpret_as_uint(), f[15 + i].to_uint())
          }
          for channel in 0..<channels {
            assert_eq(
              frame.collapse_masks[channel],
              [
                for i in 0..<21 => f[18 + channel * 21 + i].to_uint()
              ],
            )
          }
          let base = 18 + channels * 21
          for i, value in frame.history.energy {
            assert_eq(value.reinterpret_as_uint(), f[base + i].to_uint())
          }
          for i, value in frame.history.previous {
            assert_eq(value.reinterpret_as_uint(), f[base + 42 + i].to_uint())
          }
          for channel in 0..<channels {
            for i, value in frame.coefficients[channel] {
              let expected = Float::reinterpret_from_uint(
                f[base + 126 + channel * p.frame_duration + i].to_uint(),
              )
              let error = (value.to_double() - expected.to_double()).abs()
              assert_true(
                error <= 0.00001 + expected.to_double().abs() * 0.000003,
              )
            }
          }
          count += 1
          ref_index += 1
        }
      }
    }
    assert_eq(ref_index, corpus.complete.length())
  }
  assert_eq(count, 168)
  assert_true(saw_anti && saw_anti_noise && saw_transient && saw_postfilter)
}

///|
test "opus CELT: complete silence state matches original C" {
  let mut index = 0
  for channels in 1..<=2 {
    for size in 0..<4 {
      let history = OpusCeltHistory::new()
      let rc = opus_rc_init(b"\xff\xfe").unwrap()
      let frame = rc
        .decode_celt_coefficients(history, channels, 120 << size, 0, 13)
        .unwrap()
      let f = opus_pvq_reference_fields(
        opus_celt_spectrum_silence_reference[index],
      )
      assert_eq([channels, size], [f[0].to_int(), f[1].to_int()])
      assert_eq(rc.range, f[2].to_uint())
      assert_eq(rc.value, f[3].to_uint())
      assert_eq(rc.total_bits, f[4].to_uint())
      assert_eq(rc.tell_frac(), f[5].to_int())
      assert_eq(frame.history.seed, f[6].to_uint())
      assert_eq(frame.silence, f[7] == 1UL)
      assert_eq(frame.transient, f[8] == 1UL)
      assert_eq(frame.blocks, f[9].to_int())
      assert_eq(frame.anticollapse, f[10] == 1UL)
      assert_eq(frame.postfilter_period, f[11].to_int())
      for i, gain in frame.postfilter_gains {
        assert_eq(gain.reinterpret_as_uint(), f[12 + i].to_uint())
      }
      for channel in 0..<channels {
        assert_eq(
          frame.collapse_masks[channel],
          [
            for i in 0..<21 => f[15 + channel * 21 + i].to_uint()
          ],
        )
      }
      let base = 15 + channels * 21
      for i, value in frame.history.energy {
        assert_eq(value.reinterpret_as_uint(), f[base + i].to_uint())
      }
      for i, value in frame.history.previous {
        assert_eq(value.reinterpret_as_uint(), f[base + 42 + i].to_uint())
      }
      for channel in 0..<channels {
        for i, value in frame.coefficients[channel] {
          assert_eq(
            value.reinterpret_as_uint(),
            f[base + 126 + channel * (120 << size) + i].to_uint(),
          )
        }
      }
      index += 1
    }
  }
  assert_eq(index, 8)
}

///|
test "opus CELT: invalid transient TF cannot grow the Hadamard stride beyond its table" {
  let data = @libavutil.av_base64_decode(opus_celt_real_record_1, 10000).unwrap()
  let head = opus_parse_head(
    @libavutil.av_base64_decode(opus_celt_real_record_0, 10000).unwrap(),
  ).unwrap()
  let streams = head.parse_packet(data).unwrap()
  let p = streams[2].packet
  let start = streams[2].offset + p.frame_offsets[0]
  let rc = opus_rc_init(data[start:start + p.frame_sizes[0]].to_owned()).unwrap()
  let setup = rc.decode_celt_setup(1, p.frame_duration, 0, 21).unwrap()
  assert_true(setup.transient && setup.size == 3)
  let mark = rc.tell_frac()
  setup.tf_change[20] = -3
  assert_true(
    rc.decode_celt_spectrum(setup)
    is Err("opus: invalid CELT spectrum band parameters"),
  )
  assert_eq(rc.tell_frac(), mark)
}
