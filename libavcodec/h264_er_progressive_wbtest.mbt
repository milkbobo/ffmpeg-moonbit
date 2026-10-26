///|
/// Build an Annex B variant that drops the NALs at `drop` and truncates the
/// NALs named in `trunc` to a fraction of their bytes (`numerator / 4`).
fn h264_er_damage(
  data : Bytes,
  drop : Array[Int32],
  trunc : Array[(Int32, Int32)],
) -> Bytes {
  let starts : Array[Int32] = []
  for i = 0; i + 3 <= data.length(); i = i + 1 {
    if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
      starts.push(if i > 0 && data[i - 1] == 0 { i - 1 } else { i })
    }
  }
  starts.push(data.length())
  let out : Array[Byte] = []
  for i = 0; i + 1 < starts.length(); i = i + 1 {
    if drop.contains(i) {
      continue
    }
    let mut end = starts[i + 1]
    for entry in trunc {
      if entry.0 == i {
        end = starts[i] + (starts[i + 1] - starts[i]) * entry.1 / 4
      }
    }
    for j = starts[i]; j < end; j = j + 1 {
      out.push(data[j])
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Progressive-stream error concealment cases that reproduce FFmpeg 9.0.2
/// byte-exactly. `h264_slices1.264` is 96x64, six pictures (one IDR, five P),
/// three slices per picture at `first_mb_in_slice` 0, 12 and 18.
///
/// Reference: FFmpeg 9.0.2 `-flags2 +showall -fps_mode passthrough -f framemd5`
/// with the same damaged stream.
let h264_er_progressive_expected : Array[
  (String, Array[Int32], Array[(Int32, Int32)], Array[String]),
] = [
  (
    "head_i",
    [3],
    [],
    [
      "33434e0cebf250af62109490e77d2f00", "a76cf4f780aa267788a64df438378cf0", "f4fff08f13879386578c649cb3fc04c0",
      "2ae547389cc729a5c55c1caa2bdea845", "f4f1cb46f5a52cca5af9908d563b6fd0", "4e4fa982c9ccfef5259302c172ba54e4",
    ],
  ),
  (
    "two_p",
    [9, 10],
    [],
    [
      "b4fb3105bb8ab58dc1205e07761b4c15", "52b6386452e88777133231e07e8aafc7", "929860771069fdaa12ec56cdaecdf3ee",
      "51c68eae999939778df2b0e49ec8666c", "f68515efa5634b1e5477a016839a7d00", "0cbce576e9507f96c60774e4a827da23",
    ],
  ),
  (
    "head_p",
    [6],
    [],
    [
      "b4fb3105bb8ab58dc1205e07761b4c15", "c65693d80955128251c34bd3c8fbf6fb", "5bf2693609b676ce11d49e50979b9e6c",
      "7e04427535b86acf697ec3c5260d3620", "90040779de0c922359e2cd1b2f9889fc", "e7c0fe17aa00e3dfafa312e9b2f835fe",
    ],
  ),
  (
    "trunc_p_last",
    [],
    [(11, 3)],
    [
      "b4fb3105bb8ab58dc1205e07761b4c15", "52b6386452e88777133231e07e8aafc7", "00e7bdea1c6405143faaa0b49d64d11a",
      "44e6106088a9fffbb8fb0f060aacfc74", "2bc7ba48c653b97143c2592e1852bc6d", "f4fe902f80d220d56d696cc9bb91c41a",
    ],
  ),
]

///|
test "h264: progressive damage matrix matches FFmpeg 9.0.2" {
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  for entry in h264_er_progressive_expected {
    let (name, drop, trunc, expected) = entry
    let dec = new_h264_decoder()
    dec.set_error_concealment(true)
    let frames = match
      dec.decode_annexb(h264_er_damage(data, drop, trunc), false) {
      Ok(value) => h264_display_order(value)
      Err(error) => fail("\{name}: \{error}")
    }
    if frames.length() != expected.length() {
      fail("\{name}: \{frames.length()} frames, expected \{expected.length()}")
    }
    for i, frame in frames {
      let got = h264_yuv_md5(frame)
      if got != expected[i] {
        fail("\{name} frame \{i}: got \{got} expected \{expected[i]}")
      }
    }
  }
}

///|
test "h264: Annex B grouping keeps pictures apart when their first slice is lost" {
  // Without a header fingerprint the grouper mistook a picture whose
  // `first_mb_in_slice` never reaches zero for a continuation of the previous
  // picture and rejected the stream as inconsistent.
  let data = @libavutil.av_base64_decode(h264_slices1_b64, 100000).unwrap()
  for target in [3, 6, 9] {
    let dec = new_h264_decoder()
    dec.set_error_concealment(true)
    let frames = dec
      .decode_annexb(h264_er_damage(data, [target], []), false)
      .unwrap()
    assert_eq(frames.length(), 6)
  }
}
