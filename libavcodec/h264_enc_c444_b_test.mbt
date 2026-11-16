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
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
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
        "e2e0abb9eee6521cf87cf701c2ec8b32", "5388a1446ba2675015c7b4116a99ed4c", "25044a70a6a64c6795c507dc9dae0f85",
        "968910968435ba605d40d603457c239c", "e5248b387d9c654a6c271aac7872486a", "58ea280bb8e1dcd08b91321f3d3a11b1",
        "b84b9adf4c591ff70c91ed2a1da646f6",
      ]
    } else {
      [
        "e2e0abb9eee6521cf87cf701c2ec8b32", "a7e5887e21f7d12d25b81fe659f18a6b", "39cc8fbfe3cae1feefdef424db630843",
        "3f54d9143ddb3ed6fb4ceb0ec2a08e49", "a0d4ffdc45048fd1a262fc459e3cfb92", "8cc72ed019130e09dbefa2a7eb8b31fd",
        "4a79ddcdf312ac8f7c57a11097f8a59c",
      ]
    }
    for i, f in by_display {
      assert_eq(mr_md5(f.yuvp()), pins[i], msg="cabac=\{cabac} frame \{i}")
    }
  }
}
