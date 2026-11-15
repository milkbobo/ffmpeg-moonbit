// `§412` arbitration for the H.264 High 10 encoder: streams the pure
// MoonBit encoder produced are decoded by the real FFmpeg chain (the
// in-process oracle) and must match this repository's own decoder sample
// for sample, with the oracle reporting the High 10 kinds (6 = 9-bit,
// 7 = 10-bit planar 4:2:0). The P-only chain (`b_slices=false`) keeps
// coding order == display order, so oracle frame i lines up with decoder
// frame i; the B-GOP display-order mapping is covered by the wasm-side
// h264_enc_high10 round-trip family and §411's framemd5 pins.

///|
/// The §412 9/10-bit fixture: an 8-bit moving-box pattern scaled by
/// `2^(bd-8)`, packed as planar little-endian 16-bit samples.
fn ffh10_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
  bd : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let scale = 1 << (bd - 8)
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 3 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f) & 0xFF
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 40
        } else if inbox {
          s = 220
        }
        let s16 = s * scale
        y.push((s16 & 0xFF).to_byte())
        y.push(((s16 >> 8) & 0xFF).to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let cu = (((col + f) & 0x3F) + 96) * scale
        let cv = (((row + f * 2) & 0x3F) + 96) * scale
        u.push((cu & 0xFF).to_byte())
        u.push(((cu >> 8) & 0xFF).to_byte())
        v.push((cv & 0xFF).to_byte())
        v.push(((cv >> 8) & 0xFF).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
/// One arbitration leg: encode `frames_n` pictures at depth `bd` with the
/// named entropy, then diff the oracle's frames against our decoder. The
/// oracle is the full FFmpeg decode with the in-loop deblocking filter
/// applied, so our side decodes with the loop filter on too (`skip_lf =
/// false`); the encoder's local recon is pre-filter and is pinned by the
/// wasm-side skip_lf round-trip family instead. This leg therefore also
/// arbitrates the decoder's 9/10-bit deblocking path against FFmpeg.
fn ffh10_leg(
  bd : Int32,
  cabac : Bool,
  frames_n : Int32,
  weightp~ : Bool = false,
) -> Unit raise {
  let frames = ffh10_fixture(96, 64, frames_n, bd)
  let result = if cabac {
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      weightp~,
      bit_depth=bd,
    )
  } else {
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      weightp~,
      bit_depth=bd,
    )
  }
  let stream = match result {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let oracle = @ffref.ffref_decode_video(stream)
  assert_eq(oracle.bit_depth(), bd)
  assert_eq(oracle.chroma_mode(), if bd == 9 { 6 } else { 7 })
  assert_eq(oracle.width(), 96)
  assert_eq(oracle.height(), 64)
  let ours = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(oracle.frames().length(), ours.length())
  for i = 0; i < ours.length(); i = i + 1 {
    assert_eq(
      oracle.frames()[i],
      ours[i].yuvp(),
      msg="bd=\{bd} cabac=\{cabac} frame \{i} differs from the oracle",
    )
  }
}

///|
test "ffref: High 10 H.264 oracle matches the port decoder" {
  // Both depths, both entropies, I-frame and multi-picture P chains, plus
  // the explicit weighted-prediction P legs (§410 weightp at High 10).
  ffh10_leg(9, false, 1)
  ffh10_leg(9, true, 1)
  ffh10_leg(9, false, 3)
  ffh10_leg(9, true, 3)
  ffh10_leg(10, false, 1)
  ffh10_leg(10, true, 1)
  ffh10_leg(10, false, 3)
  ffh10_leg(10, true, 3)
  ffh10_leg(9, false, 3, weightp=true)
  ffh10_leg(10, false, 3, weightp=true)
  ffh10_leg(10, true, 3, weightp=true)
}

///|
/// B-GOP legs: the default sequence entry codes odd display positions as B
/// pictures (decode order I0,P2,B1,P4,B3,P5), and FFmpeg emits display
/// order, so our decoder slots are compared through the `§411` display
/// mapping (display position d -> decoder slot, e.g. display 1 = slot 2).
fn ffh10_bgop_leg(bd : Int32, cabac : Bool) -> Unit raise {
  let frames = ffh10_fixture(96, 64, 6, bd)
  let result = if cabac {
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      bit_depth=bd,
    )
  } else {
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      bit_depth=bd,
    )
  }
  let stream = match result {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let oracle = @ffref.ffref_decode_video(stream)
  assert_eq(oracle.bit_depth(), bd)
  assert_eq(oracle.frames().length(), 6)
  let ours = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  assert_eq(ours.length(), 6)
  // §411's decode-to-display mapping for the six-picture B-GOP.
  let slot = [0, 2, 1, 4, 3, 5]
  for d = 0; d < 6; d = d + 1 {
    assert_eq(
      oracle.frames()[d],
      ours[slot[d]].yuvp(),
      msg="bd=\{bd} cabac=\{cabac} display frame \{d} differs from the oracle",
    )
  }
}

///|
test "ffref: High 10 B-GOP streams match the oracle in display order" {
  ffh10_bgop_leg(9, false)
  ffh10_bgop_leg(9, true)
  ffh10_bgop_leg(10, false)
  ffh10_bgop_leg(10, true)
}
