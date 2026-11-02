///|
/// Decode a base64 vector constant (ASCII-safe by construction).
fn opus_hybrid_b64(s : String) -> Bytes {
  let input : Array[Byte] = []
  for i in 0..<s.length() {
    input.push((s[i].to_int() & 0xff).to_byte())
  }
  @libavutil.av_base64_decode(Bytes::from_array(input[:]), 1000000).unwrap()
}

///|
/// Hybrid has both stages active: SILK drives the low band (resampled from
/// 16 kHz to 48 kHz) while CELT fills the high band. This compares the final
/// interleaved f32le output against reference frames from the assembly-free
/// FFmpeg 9.0.2 build. CELT synthesis is bit-exact only to 3e-6 (see
/// opus_celt_pcm_reference.c), so the check is sample tolerance based; the
/// reference framemd5s match the stored hyb_*.md5 bit for bit.
test "Opus hybrid end-to-end PCM matches assembly-free FFmpeg 9.0.2" {
  let tolerance = 0.000003
  for case in @opus_hybrid_pcm_vectors.opus_hybrid_pcm_ref_cases {
    let (name, packets_b64, head_b64, pkt_sizes, sizes, ref_frames) = case
    let head = @libavcodec.opus_parse_head(opus_hybrid_b64(head_b64)).unwrap()
    let packets_data = opus_hybrid_b64(packets_b64)
    let decoder = @libavcodec.OpusDecoder::new(head).unwrap()
    let channels = head.channels
    let acc : Array[Array[Float]] = [ for _ in 0..<channels => [] ]
    let mut pos = 0
    let mut packets = 0
    for pkt_size in pkt_sizes {
      let span = packets_data[pos:pos + pkt_size].to_owned()
      let (pcm, samples) = decoder.decode_packet(Some(span)).unwrap()
      for c in 0..<channels {
        for i in 0..<samples {
          acc[c].push(pcm[c][i])
        }
      }
      pos += pkt_size
      packets += 1
    }
    // Drain the decoder (resampler tail), as the FFmpeg CLI does at EOF.
    let drain_len = match decoder.decode_packet(None) {
      Ok((pcm, samples)) => {
        for c in 0..<channels {
          for i in 0..<samples {
            acc[c].push(pcm[c][i])
          }
        }
        samples
      }
      Err(error) => fail("\{name}: drain failed: \{error}")
    }
    assert_eq(pos, packets_data.length())
    assert_eq(packets, pkt_sizes.length())
    // Ogg granule end trimming: the CLI trims the last packet's output frame
    // via skip_samples side data before draining; replicate that here.
    let pre_drain = acc[0].length() - drain_len
    let ref_raw = head.pre_skip + sizes.fold(init=0, (a, b) => a + b)
    let excess = pre_drain - (ref_raw - drain_len)
    guard excess >= 0 && excess < pre_drain else {
      fail("\{name}: end trim \{excess} out of range for \{pre_drain} samples")
    }
    for c in 0..<channels {
      for i in 0..<drain_len {
        acc[c][pre_drain - excess + i] = acc[c][pre_drain + i]
      }
      acc[c].truncate(pre_drain - excess + drain_len)
    }
    guard acc[0].length() == ref_raw else {
      fail("\{name}: trimmed \{acc[0].length()} samples, want \{ref_raw}")
    }
    // Compare the selected reference frames sample by sample.
    let mut max_error = 0.0
    let mut max_at = ""
    for pair in ref_frames {
      let (frame_index, ref_b64) = pair
      let mut off = head.pre_skip
      for k in 0..<frame_index {
        off += sizes[k]
      }
      let n = sizes[frame_index]
      let reference = opus_hybrid_b64(ref_b64)
      guard reference.length() == 4 * channels * n else {
        fail(
          "\{name}: frame \{frame_index} reference size \{reference.length()} != \{4 * channels * n}",
        )
      }
      for c in 0..<channels {
        for i in 0..<n {
          let at = 4 * (i * channels + c)
          let bits = reference[at].to_uint() |
            (reference[at + 1].to_uint() << 8) |
            (reference[at + 2].to_uint() << 16) |
            (reference[at + 3].to_uint() << 24)
          let expected = Float::reinterpret_from_uint(bits)
          let error = (acc[c][off + i].to_double() - expected.to_double()).abs()
          if error > max_error {
            max_error = error
            max_at = "frame \{frame_index} channel \{c} sample \{i}"
          }
        }
      }
    }
    if max_error > tolerance {
      fail("\{name}: max error \{max_error} at \{max_at} exceeds \{tolerance}")
    }
  }
}
