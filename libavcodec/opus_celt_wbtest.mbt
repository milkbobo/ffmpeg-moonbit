///|
fn opus_celt_allocation_text(
  alloc : OpusCeltAllocation,
  rc : OpusRangeDecoder,
) -> String {
  let out = StringBuilder()
  let dual = if alloc.dual_stereo { 1 } else { 0 }
  out.write_string(
    " \{alloc.spread} \{alloc.trim} \{alloc.anticollapse_bits} \{alloc.coded_bands} \{alloc.intensity_stereo} \{dual} \{alloc.remaining}",
  )
  out.write_string(
    " \{rc.range} \{rc.value} \{rc.total_bits} \{rc.tell_frac()}",
  )
  for
    array in [alloc.caps, alloc.pvq_bits, alloc.fine_bits, alloc.fine_priority] {
    for value in array {
      out.write_string(" \{value}")
    }
  }
  out.to_string()
}

///|
fn opus_celt_setup_text(setup : OpusCeltSetup, rc : OpusRangeDecoder) -> String {
  let out = StringBuilder()
  out.write_string(opus_celt_allocation_text(setup.allocation, rc))
  let silence = if setup.silence { 1 } else { 0 }
  let transient = if setup.transient { 1 } else { 0 }
  out.write_string(
    " \{silence} \{transient} \{setup.blocks} \{setup.postfilter_period}",
  )
  for gain in setup.postfilter_gains {
    out.write_string(" \{gain.reinterpret_as_uint()}")
  }
  for value in setup.tf_change {
    out.write_string(" \{value}")
  }
  for value in setup.energy {
    out.write_string(" \{value.reinterpret_as_uint()}")
  }
  out.to_string()
}

///|
test "opus CELT: 896 allocations match original C budgets and entropy states" {
  let bands = [(0, 13), (0, 17), (0, 19), (0, 21), (17, 21), (20, 21), (0, 1)]
  let lengths = [1, 2, 4, 8, 16, 64, 256, 1275]
  let mut index = 0
  for channels in 1..<=2 {
    for size in 0..<4 {
      for (start, end) in bands {
        for transient in [false, true] {
          for length in lengths {
            let seed = index % 32
            let data = Bytes::from_array(
              [
                for i in 0..<length => {
                  ((seed * 67 + i * 29 + ((i * i) >> 2)) & 255).to_byte()
                }
              ][:],
            )
            let rc = opus_rc_init(data).unwrap()
            if (index & 1) != 0 {
              let _ = rc.decode_log(1).unwrap()
            }
            let alloc = rc
              .decode_celt_allocation(
                channels,
                size,
                start,
                end,
                length * 8,
                transient,
              )
              .unwrap()
            let state = opus_celt_allocation_text(alloc, rc)
            let probe = rc.get_raw(3).unwrap()
            assert_eq(
              "A \{index}" + state + " \{probe}",
              opus_celt_alloc_reference[index],
            )
            index += 1
          }
        }
      }
    }
  }
  assert_eq(index, 896)
}

///|
test "opus CELT: 896 frame setups match original C through fine energy" {
  let bands = [(0, 13), (0, 17), (0, 19), (0, 21), (17, 21), (20, 21), (0, 1)]
  let lengths = [1, 2, 4, 8, 16, 64, 256, 1275]
  let mut index = 0
  let mut saw_transient = false
  let mut saw_filter = false
  let mut saw_dual_stereo = false
  let mut saw_skipped = false
  let mut saw_positive_tf = false
  let mut saw_negative_tf = false
  for channels in 1..<=2 {
    for size in 0..<4 {
      for (start, end) in bands {
        for _ in 0..<2 {
          for length in lengths {
            let seed = index % 32
            let data = Bytes::from_array(
              [
                for i in 0..<length => {
                  ((seed * 67 + i * 29 + ((i * i) >> 2)) & 255).to_byte()
                }
              ][:],
            )
            let rc = opus_rc_init(data).unwrap()
            if (index & 1) != 0 {
              let _ = rc.decode_log(1).unwrap()
            }
            let history : Array[Float] = [
              for k in 0..<42 => {
                if index % 5 == 0 {
                  0.0
                } else {
                  Float::from_int(
                    (k % 21 * 7 + k / 21 * 11 + index % 5) % 193 - 128,
                  ) /
                  8.0
                }
              }
            ]
            let before = history.copy()
            let setup = rc
              .decode_celt_setup(
                channels,
                120 << size,
                start,
                end,
                previous_energy=history,
              )
              .unwrap()
            saw_transient = saw_transient || setup.transient
            saw_filter = saw_filter || setup.postfilter_period > 0
            saw_dual_stereo = saw_dual_stereo || setup.allocation.dual_stereo
            saw_skipped = saw_skipped || setup.allocation.coded_bands < end
            for change in setup.tf_change {
              saw_positive_tf = saw_positive_tf || change > 0
              saw_negative_tf = saw_negative_tf || change < 0
            }
            assert_eq(history, before)
            assert_eq(
              "E \{index}" + opus_celt_setup_text(setup, rc),
              opus_celt_setup_reference[index],
            )
            index += 1
          }
        }
      }
    }
  }
  assert_eq(index, 896)
  assert_true(saw_transient && saw_filter && saw_dual_stereo && saw_skipped)
  assert_true(saw_positive_tf && saw_negative_tf)
}

///|
test "opus CELT: canonical silence setup matches C for all durations and channels" {
  let mut index = 0
  for channels in 1..<=2 {
    for size in 0..<4 {
      let rc = opus_rc_init(b"\xff\xfe").unwrap()
      let setup = rc.decode_celt_setup(channels, 120 << size, 0, 21).unwrap()
      assert_true(setup.silence)
      assert_true(!setup.transient)
      assert_eq(
        "Z \{channels} \{size}" + opus_celt_setup_text(setup, rc),
        opus_celt_silence_reference[index],
      )
      index += 1
    }
  }
  assert_eq(index, 8)
}

///|
test "opus CELT: real 5.1 multistream frames reach PVQ with exact C state and energy" {
  let head = opus_parse_head(
    @libavutil.av_base64_decode(opus_celt_real_record_0, 10000).unwrap(),
  ).unwrap()
  let packets = [
    opus_celt_real_record_1, opus_celt_real_record_2, opus_celt_real_record_3, opus_celt_real_record_4,
  ]
  let mut count = 0
  for index, encoded in packets {
    let data = @libavutil.av_base64_decode(encoded, 10000).unwrap()
    let streams = head.parse_packet(data).unwrap()
    for i, stream in streams {
      let p = stream.packet
      assert_eq(p.mode, "celt")
      let end = match p.bandwidth {
        "narrowband" => 13
        "mediumband" | "wideband" => 17
        "superwideband" => 19
        _ => 21
      }
      for j in 0..<p.frame_count {
        let start = stream.offset + p.frame_offsets[j]
        let rc = opus_rc_init(data[start:start + p.frame_sizes[j]].to_owned()).unwrap()
        let channels = if p.stereo { 2 } else { 1 }
        let setup = rc
          .decode_celt_setup(channels, p.frame_duration, 0, end)
          .unwrap()
        assert_eq(
          "R \{index} \{i} \{j}" + opus_celt_setup_text(setup, rc),
          opus_celt_real_reference[count],
        )
        assert_eq(setup.start_band, 0)
        assert_eq(setup.end_band, end)
        assert_eq(setup.channels, channels)
        assert_eq(setup.framebits, p.frame_sizes[j] * 8)
        assert_eq(120 << setup.size, p.frame_duration)
        count += 1
      }
    }
  }
  assert_eq(count, 16)
}
