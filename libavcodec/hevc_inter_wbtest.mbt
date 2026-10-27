///|
/// White-box test for the HEVC P/B frame-inter prediction path: real x265
/// Annex B streams (gray I+6P, moving I+6P, I/P/B with bframes=2, and a
/// four-slice 320x240 I/P stream) decoded end-to-end and compared per-frame
/// against FFmpeg 9.0.2's default decode (YUV420P MD5, presentation order).
/// Stream data and reference MD5s live in `hevc_inter_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// YUV420P MD5 of a decoded picture (Y, Cb, Cr planes concatenated). */
fn hevc_yuv_md5(pic : HevcPicture) -> String {
  let out : Array[Byte] = []
  for v in pic.y {
    out.push(v.to_byte())
  }
  for v in pic.cb {
    out.push(v.to_byte())
  }
  for v in pic.cr {
    out.push(v.to_byte())
  }
  let yuv = Bytes::from_array(out)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  h264_hex(digest, 16)
}

///|
/// `ff_hevc_decode_frames` returns pictures in decode order; sort a copy by
/// POC to obtain presentation order for the framemd5 comparison. */
fn hevc_sorted_by_poc(
  frames : Array[HevcDecodedFrame],
) -> Array[HevcDecodedFrame] {
  let arr = frames.copy()
  arr.sort_by((a, b) => a.poc.compare(b.poc))
  arr
}

///|
/// Decode one embedded stream and assert every frame's YUV MD5. */
fn hevc_check_stream_ex(
  b64 : Bytes,
  refs : Array[String],
  apply_filters : Bool,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 65536).unwrap()
  match ff_hevc_decode_frames_ex(data, false, 0, apply_filters) {
    Ok(frames) => {
      let sorted = hevc_sorted_by_poc(frames)
      assert_eq(sorted.length(), refs.length())
      for i in 0..<refs.length() {
        assert_eq(hevc_yuv_md5(sorted[i].pic), refs[i])
      }
    }
    Err(e) => fail("hevc pb decode failed: \{e}")
  }
}

///|
fn hevc_check_stream(b64 : Bytes, refs : Array[String]) -> Unit raise {
  hevc_check_stream_ex(b64, refs, true)
}

///|
test "hevc pb: static gray I+6P stream matches FFmpeg per-frame MD5" {
  hevc_check_stream(hevc_pb_static_b64, hevc_pb_refs[0])
}

///|
test "hevc pb: moving I+6P stream matches FFmpeg per-frame MD5" {
  hevc_check_stream(hevc_pb_mov_b64, hevc_pb_refs[1])
}

///|
test "hevc pb: I/P/B stream (bframes=2) matches FFmpeg per-frame MD5" {
  hevc_check_stream(hevc_pb_movb_b64, hevc_pb_refs[2])
}

///|
test "hevc pb: four-slice pictures match FFmpeg (deblock+SAO)" {
  hevc_check_stream(hevc_pb_slices_b64, hevc_pb_slices_refs)
}

///|
test "hevc pb: four-slice pictures match FFmpeg (unfiltered)" {
  hevc_check_stream_ex(
    hevc_pb_slices_b64, hevc_pb_slices_unfiltered_refs, false,
  )
}

///|
test "hevc pb: PCM-capable SPS still permits ordinary coded blocks" {
  // FFmpeg 9.0.2 -xerror decodes this old SPS-patched fixture to the same
  // seven gray frames; enabling PCM does not require every CU to use it.
  hevc_check_stream(hevc_pb_neg_pcm_b64, hevc_pb_refs[0])
}
