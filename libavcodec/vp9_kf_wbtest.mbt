///|
/// White-box test for the VP9 keyframe decoder against real libvpx-vp9
/// streams (docker `linuxserver/ffmpeg:9.0.2`; payloads and reference MD5s in
/// `vp9_kf_realdata_wbtest.mbt`).

///|
fn vp9_kf_hex(bytes : FixedArray[Byte], n : Int32) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
fn vp9_kf_frame_md5(dec : Vp9Decoder) -> String {
  let yuv = dec.frame_bytes()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  vp9_kf_hex(digest, 16)
}

///|
/// Decode every frame of a stream and compare the per-frame YUV MD5s. */
fn vp9_kf_check(
  name : String,
  frames : Array[Bytes],
  size : (Int32, Int32),
  md5s : Array[String],
) -> Unit raise {
  let dec = vp9_decoder_new()
  for i in 0..<frames.length() {
    match dec.decode_frame(frames[i]) {
      Ok(_) => ()
      Err(e) => fail("\{name} frame \{i}: decode failed: \{e}")
    }
    let got = vp9_kf_frame_md5(dec)
    inspect(
      "\{name} frame \{i} \{size.0}x\{size.1}",
      content="\{name} frame \{i} \{size.0}x\{size.1}",
    )
    inspect(got, content=md5s[i])
  }
}

///|
test "vp9 kf: 160x144 multi-TU stream matches FFmpeg YUV" {
  vp9_kf_check("basic", vp9_kf_basic_frames, vp9_kf_basic_size, vp9_kf_basic_md5)
}

///|
test "vp9 kf: 70x36 (non-SB-aligned width) matches FFmpeg YUV" {
  vp9_kf_check("small", vp9_kf_small_frames, vp9_kf_small_size, vp9_kf_small_md5)
}

///|
test "vp9 kf: 64x48 lowest-quantizer stream matches FFmpeg YUV" {
  vp9_kf_check("qfull", vp9_kf_qfull_frames, vp9_kf_qfull_size, vp9_kf_qfull_md5)
}

///|
test "vp9 kf: lossless (WHT) stream matches FFmpeg YUV" {
  vp9_kf_check(
    "lossless",
    vp9_kf_lossless_frames,
    vp9_kf_lossless_size,
    vp9_kf_lossless_md5,
  )
}

///|
test "vp9 kf: 512x128 2x2 tiles matches FFmpeg YUV" {
  vp9_kf_check("tiles", vp9_kf_tiles_frames, vp9_kf_tiles_size, vp9_kf_tiles_md5)
}

///|
test "vp9 kf: inter frame is rejected with a specific error" {
  let dec = vp9_decoder_new()
  // Real inter packet from the header-parser vectors. Reject it before
  // reference dimensions or compressed-header probabilities are required.
  let data = vp9_test_bytes(vp9_inter_a_b64)
  match dec.decode_frame(data) {
    Ok(_) => fail("inter frame must be rejected")
    Err(e) => inspect(e, content="vp9: inter frame not supported")
  }
}

///|
test "vp9: show_existing_frame requires a populated reference slot" {
  let dec = vp9_decoder_new()
  // marker 10, profile 0, show_existing=1, frame_to_show=0
  let data : Bytes = b"\x88"
  match dec.decode_frame(data) {
    Ok(_) => fail("show_existing must be rejected")
    Err(e) => inspect(e, content="vp9: show_existing_frame references an empty slot")
  }
}

///|
test "vp9 kf: truncated tile data is rejected" {
  let dec = vp9_decoder_new()
  // take a real keyframe and cut the tile payload off
  let full = vp9_kf_qfull_frames[0]
  let cut = full[0:20].to_owned()
  match dec.decode_frame(cut) {
    Ok(_) => fail("truncated tile must be rejected")
    Err(e) => inspect(e, content="vp9: compressed header exceeds packet")
  }
}
