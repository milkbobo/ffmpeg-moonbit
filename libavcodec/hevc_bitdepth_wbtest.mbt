///|
/// White-box tests for 10/12-bit HEVC (4:2:0) end-to-end decoding: real x265
/// Main10 I/P/B with weighted prediction and Main12 with 32x32 TUs, decoded
/// both with the in-loop filters (deblock + SAO) and with
/// `-skip_loop_filter all` equivalents, then compared per frame against
/// FFmpeg 9.0.2 in presentation order. Fixtures and references live in
/// `hevc_bitdepth_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// YUV420P 16-bit little-endian MD5 (`yuv420p10le` / `yuv420p12le`). */
fn hevc_yuv16_md5(pic : HevcPicture) -> String {
  let out : Array[Byte] = []
  for v in pic.y {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  for v in pic.cb {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  for v in pic.cr {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  let yuv = Bytes::from_array(out)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  h264_hex(digest, 16)
}

///|
fn hevc_check_bitdepth_stream(
  b64 : Bytes,
  filters : Bool,
  refs : Array[String],
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 8192).unwrap()
  match ff_hevc_decode_frames_ex(data, false, 0, filters) {
    Ok(frames) => {
      let sorted = hevc_sorted_by_poc(frames)
      assert_eq(sorted.length(), refs.length())
      for i in 0..<refs.length() {
        assert_eq(hevc_yuv16_md5(sorted[i].pic), refs[i])
      }
    }
    Err(e) => fail("hevc bitdepth decode failed: \{e}")
  }
}

///|
test "hevc main10: weighted I/P/B stream matches FFmpeg (deblock+SAO)" {
  hevc_check_bitdepth_stream(hevc_m10b_b64, true, hevc_m10b_filtered_refs)
}

///|
test "hevc main10: unfiltered decode matches FFmpeg" {
  hevc_check_bitdepth_stream(hevc_m10b_b64, false, hevc_m10b_unfiltered_refs)
}

///|
test "hevc main12: I/P stream with 32x32 TUs matches FFmpeg (deblock+SAO)" {
  hevc_check_bitdepth_stream(hevc_m12p_b64, true, hevc_m12p_filtered_refs)
}

///|
test "hevc main12: unfiltered decode matches FFmpeg" {
  hevc_check_bitdepth_stream(hevc_m12p_b64, false, hevc_m12p_unfiltered_refs)
}

///|
fn hevc_check_intra_bitdepth(
  b64 : Bytes,
  filters : Bool,
  expected : String,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 8192).unwrap()
  let res = if filters {
    ff_hevc_decode_intra_frame(data, false, 0)
  } else {
    ff_hevc_decode_intra_frame_unfiltered(data, false, 0)
  }
  match res {
    Ok(pic) => assert_eq(hevc_yuv16_md5(pic), expected)
    Err(e) => fail("hevc main10 intra decode failed: \{e}")
  }
}

///|
test "hevc main10: standalone intra IDR matches FFmpeg (deblock+SAO)" {
  hevc_check_intra_bitdepth(hevc_m10b_idr_b64, true, hevc_m10b_filtered_refs[0])
}

///|
test "hevc main10: standalone intra IDR unfiltered matches FFmpeg" {
  hevc_check_intra_bitdepth(
    hevc_m10b_idr_b64,
    false,
    hevc_m10b_unfiltered_refs[0],
  )
}
