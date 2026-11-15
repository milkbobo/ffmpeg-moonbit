///|
/// §421 4:4:4 fixture: three gradient planes at full resolution.
fn c444_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        y.push(((col * 2 + row * 3 + f * 7) & 0xFF).to_byte())
        u.push(((col + row * 2 + f * 5 + 40) & 0xFF).to_byte())
        v.push(((col * 3 + row + f * 3 + 70) & 0xFF).to_byte())
      }
    }
    frames.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  frames
}

///|
test "h264 c444: single IDR round trip" {
  let frames = c444_fixture(1)
  let (y, u, v) = frames[0]
  let enc = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      chroma_format=3,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let stream = enc.annexb
  let ps = @libavcodec.new_h264_param_sets()
  let mut profile = 0
  for nal in vbv_nals(stream) {
    if nal.0 == 7 {
      profile = vbv_nal_payload(stream, nal)[0].to_int()
      match
        @libavcodec.ff_h264_decode_seq_parameter_set(
          @libavcodec.BitReader::new(vbv_nal_payload(stream, nal)),
          ps,
          false,
        ) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    }
  }
  assert_eq(profile, 244)
  assert_eq(ps.sps_list[0].unwrap().chroma_format_idc, 3)
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 1)
  // Pack the encoder's local reconstruction the way the decoder emits it.
  let recon : Array[Byte] = []
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      recon.push((enc.recon_y[row * enc.ystride + col] & 0xFF).to_byte())
    }
  }
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      recon.push((enc.recon_u[row * enc.cstride + col] & 0xFF).to_byte())
    }
  }
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      recon.push((enc.recon_v[row * enc.cstride + col] & 0xFF).to_byte())
    }
  }
  assert_eq(
    mr_md5(Bytes::from_array(recon[:])),
    mr_md5(dec[0].yuvp()),
    msg="frame 0",
  )
}

///|
/// External arbitration anchor (`§421` I+P): the annexb bytes for the docker
/// ffmpeg framemd5 oracle.
test "h264 c444: ffmpeg-arbitrated I+P stream" {
  let frames = c444_fixture(2)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      chroma_format=3,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBC44P:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 2)
  let mut md5s = "C44PMD5:"
  for f in dec {
    md5s = md5s + " " + mr_md5(f.yuvp())
  }
  println(md5s)
  // Pinned against docker linuxserver/ffmpeg:9.0.2 (zero warnings,
  // byte-identical per-frame hashes).
  assert_eq(mr_md5(dec[0].yuvp()), "843711bf73c3cfb162a019e63ae3ce45")
  assert_eq(
    mr_md5(dec[1].yuvp()),
    "914c05ef21e1dc94f4cbd46c7b2b86eb",
    msg="P frame anchor",
  )
}

///|
/// §421 contract: the inter pictures are still open, so a multi-frame 4:4:4
/// request must fail loudly instead of emitting a drifting stream.
test "h264 c444: B schedule stays rejected" {
  let frames = c444_fixture(3)
  match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, chroma_format=3) {
    Ok(_) => fail("4:4:4 with the B schedule accepted")
    Err(_) => ()
  }
}

///|
/// §421: 4:4:4 P pictures — three-plane luma-geometry MC + the shared 4-bit
/// cbp.
test "h264 c444: I+P round trip" {
  let frames = c444_fixture(2)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      chroma_format=3,
      b_slices=false,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(recon.length(), 1)
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 2)
  assert_eq(mr_md5(recon[0]), mr_md5(dec[1].yuvp()), msg="P frame")
}

///|
/// §421: 4:4:4 in CABAC (single IDR).
test "h264 c444: cabac single IDR round trip" {
  let frames = c444_fixture(1)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      chroma_format=3,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 1)
  let mut dump = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBC44C:\{dump}")
  println("C44CMD5: " + mr_md5(dec[0].yuvp()))
  // Anchored against docker linuxserver/ffmpeg:9.0.2 with
  // `-skip_loop_filter all`: the 4:4:4 loop filter does not run in this port
  // yet (see AGENT_HANDOFF_2026-11-15_H264_C444.md). The entropy layer is
  // exact — with the filter enabled ffmpeg hashes this frame as
  // 38c33e4c86fa0ca08e672e0c524c7906.
  assert_eq(mr_md5(dec[0].yuvp()), "b69044fda520a48a40c014c295cb861c")
}

///|
test "h264 c444: validation rejects bad formats" {
  let frames = c444_fixture(1)
  for bad in [0, 4, -1] {
    match
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        chroma_format=bad,
      ) {
      Ok(_) => fail("chroma_format \{bad} accepted")
      Err(_) => ()
    }
  }
}

///|
/// External arbitration anchor (`§421`): the 4:4:4 IDR annexb bytes for the
/// docker ffmpeg framemd5 oracle.
test "h264 c444: ffmpeg-arbitrated stream" {
  let frames = c444_fixture(1)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      chroma_format=3,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i = 0; i < stream.length(); i = i + 1 {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBC44:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 1)
  let mut md5s = "C44MD5:"
  for f in dec {
    md5s = md5s + " " + mr_md5(f.yuvp())
  }
  println(md5s)
  // Pinned against `docker linuxserver/ffmpeg:9.0.2 -v warning -f framemd5`
  // (zero warnings, byte-identical frame hash; see §421 in PORTING_HISTORY).
  assert_eq(
    mr_md5(dec[0].yuvp()),
    "843711bf73c3cfb162a019e63ae3ce45",
    msg="ffmpeg anchor",
  )
}

///|
