///|
test "h264 c444 B: 16x16 inter schedule reconstructs three planes" {
  let frames = c444_fixture(5)
  for cabac in [false, true] {
    for multi_ref in [1, 3] {
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          chroma_format=3,
          b_slices=true,
          b_parts=false,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          recon~,
          multi_ref~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          chroma_format=3,
          b_slices=true,
          b_parts=false,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          recon~,
          multi_ref~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 5)
      assert_eq(recon.length(), 4)
      for i in 0..<4 {
        assert_eq(recon[i].length(), 96 * 64 * 3)
        assert_true(
          h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()),
          msg="cabac=\{cabac} coded frame=\{i + 1}",
        )
      }
    }
  }
}

///|
/// §422e external arbitration anchor: a 4:4:4 B stream with the DEFAULT
/// tool set (b_parts / intra_in_b / intra4x4_in_b / dct8x8 all on) — the
/// configuration where the B inter 8x8 RD choice is active. The display
/// MD5s pin FFmpeg's deblocked output; the ARBC44B dumps carry the
/// annexb bytes for re-arbitration.
test "h264 c444 B: ffmpeg-arbitrated default-tools streams" {
  let frames = c444_fixture(7)
  for cabac in [false, true] {
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let mut dump = ""
    for i = 0; i < stream.length(); i = i + 1 {
      dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
    }
    println("ARBC44B\{if cabac { "C" } else { "" }}:\{dump}")
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 7)
    let disp = h264p_decode_to_display(7)
    let by_display : Array[@libavcodec.H264Frame] = Array::make(7, dec[0])
    for i, f in dec {
      by_display[disp[i]] = f
    }
    let mut md5s = "C44BMD5 cabac=\{cabac}:"
    for f in by_display {
      md5s = md5s + " " + mr_md5(f.yuvp())
    }
    println(md5s)
    // FFmpeg-arbitrated display MD5s (docker framemd5, zero warnings,
    // identical to the local default decode) — the §422e B inter 8x8
    // RD choice is active in this default-tools configuration.
    let pins = if cabac {
      [
        "e2e0abb9eee6521cf87cf701c2ec8b32", "7e725a715bfd4d3ff33c2cdc1970b216", "1c184054fd67d7bffb20c0736d098833",
        "38506347a2d54a4f255e33f36dc88434", "3703ecc115220fd7abaf5a2d0b9737a5", "d535916c72f66a9364087809901813d0",
        "c7d9a6e6f584c453a901ca826336768c",
      ]
    } else {
      [
        "e2e0abb9eee6521cf87cf701c2ec8b32", "126a9f0b9ba8de3b9f4f99aafc26872c", "1b8e64adaff369ac3a732c92c7d4a18b",
        "d491365b84eb12539a824d9d2f332d71", "b8c1a9fe906f6fb576b284afd701ee38", "5e0fa725e1c13b2e76656df14e6c8a66",
        "2e053e7a73cb0cf40955fbff400b9bca",
      ]
    }
    for i, f in by_display {
      assert_eq(mr_md5(f.yuvp()), pins[i], msg="cabac=\{cabac} frame \{i}")
    }
  }
}
