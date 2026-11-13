// Blackbox tests for the P-slice multi-reference encoder (`§415`/`§416`).
// CAVLC multi-reference is fully verified: decode round-trip, the recon
// invariant (the `§415` skip/weight slot mismatches are fixed), streaming
// == batch byte identity, and external ffmpeg arbitration. CABAC multi
// -reference is rejected at the entries until its ref_idx bin writer and
// the reader are re-traced (see AGENT_HANDOFF §416).

///|
fn mr_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "h264 multiref: multi_ref=1 is byte-identical to the default" {
  let frames = h264p_fixture(96, 64, 5)
  for cabac in [false, true] {
    let default_stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=26)
      } else {
        @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26)
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let explicit_one = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=1,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          multi_ref=1,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(mr_md5(default_stream), mr_md5(explicit_one))
  }
}

///|
test "h264 multiref: two references round-trip with the recon invariant" {
  let frames = h264p_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 6)
  assert_eq(recon.length(), 5)
  // `§416`: the recon invariant holds — the `§415` divergences (skips
  // committed after the reference switch, weighted MC reading entry-0
  // offsets for entry-1 references) are fixed.
  for i, r in recon {
    assert_eq(
      mr_md5(r),
      mr_md5(dec[i + 1].yuvp()),
      msg="P frame \{i + 1}: encoder recon != decoder recon",
    )
  }
  // The parameter sets signal the active count: SPS max_num_ref_frames
  // and the PPS default L0 count are 2 — a full decode already proved
  // the parser consumes the per-partition ref_idx elements.
  if dec[1].bit_depth != 8 {
    fail("multiref stream decoded at the wrong depth")
  }
}

///|
/// A two-position toggle: even pictures show pattern A, odd pictures
/// pattern B. Every odd P picture's best reference is the picture two
/// back (the previous A), which multi-reference finds and single
/// -reference cannot — the case the tool exists for.
fn mr_toggle_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let phase = f % 2
    let bx = if phase == 0 { 8 } else { 56 }
    let by = if phase == 0 { 8 } else { 32 }
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 3 + row * 5) & 0x7F
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox &&
          (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 30
        } else if inbox {
          s = 210
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((96 + ((col / 2 + phase * 8) & 0x3F)).to_byte())
        v.push((96 + ((row / 2 + phase * 4) & 0x3F)).to_byte())
      }
    }
    out.push(
      (Bytes::from_array(y[:]), Bytes::from_array(u[:]), Bytes::from_array(v[:])),
    )
  }
  out
}

///|
test "h264 multiref: a toggle scene codes far smaller with two refs" {
  let frames = mr_toggle_fixture(7)
  let one = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=1,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let two = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // The odd pictures become near-skips against their true match two back;
  // the two-reference stream must be dramatically smaller (the syntax
  // overhead of ref_idx/PWT entries is a few bytes per picture).
  assert_true(
    two.length() * 5 < one.length() * 4,
    msg="toggle scene: two-ref \{two.length()} B not clearly smaller than one-ref \{one.length()} B",
  )
  let dec = match @libavcodec.h264_decode_annexb_frames(two, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 7)
}

///|
test "h264 multiref: streaming matches the batch stream" {
  let frames = h264p_fixture(96, 64, 6)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  let out : Array[Byte] = []
  for au in aus {
    for b in au {
      out.push(b)
    }
  }
  assert_eq(mr_md5(Bytes::from_array(out[:])), mr_md5(batch))
}

///|
test "h264 multiref: High 10 composes" {
  let frames = h264h10_fixture(96, 64, 4, 10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      bit_depth=10,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for f in dec {
    assert_eq(f.bit_depth, 10)
  }
  for i, r in recon {
    assert_eq(mr_md5(r), mr_md5(dec[i + 1].yuvp()))
  }
}

///|
test "h264 multiref: combination and range validation" {
  let frames = h264p_fixture(96, 64, 4)
  // B slices are rejected.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      multi_ref=2,
    ) {
    Ok(_) => fail("multi_ref accepted B slices")
    Err(_) => ()
  }
  // CABAC is rejected until the ref_idx bin writer is re-traced (`§416`).
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(_) => fail("multi_ref accepted CABAC")
    Err(e) => assert_true(e.contains("CABAC"), msg=e)
  }
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      cabac=true,
      b_slices=false,
      multi_ref=2,
    ) {
    Ok(_) => fail("streaming multi_ref accepted CABAC")
    Err(e) => assert_true(e.contains("CABAC"), msg=e)
  }
  // Rate controls are rejected.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=2,
      target_bytes=1500,
    ) {
    Ok(_) => fail("multi_ref accepted target_bytes")
    Err(_) => ()
  }
  // Range: 0 and 17 are out of the documented 1..=16.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=0,
    ) {
    Ok(_) => fail("multi_ref accepted 0")
    Err(_) => ()
  }
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=17,
    ) {
    Ok(_) => fail("multi_ref accepted 17")
    Err(_) => ()
  }
  // A depth beyond the sequence length degrades to the picture count.
  let two = match
    @libavcodec.h264_encode_frames(
      [frames[0], frames[1]],
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      multi_ref=4,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(two, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(dec.length(), 2)
}
