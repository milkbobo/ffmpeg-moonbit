// §403 regression matrix: H.264 B-line x 8x8DCT opt-in combinations.
//
// Before §403, `write_b_mb_i4_syntax` / `write_b_mb_i4_syntax_cabac` omitted
// the mandatory `transform_size_8x8_flag` for I_NxN macroblocks whenever the
// PPS enabled 8x8DCT, and the CABAC B writers did not mirror the decoder's
// per-MB transform bit. Both entropy paths then diverged from the decoder:
// CAVLC reported `invalid coeff_token` / unavailable left samples, CABAC
// reported `missing end_of_slice_flag` / `bytestream overread`.
//
// Every combination below encodes with the pure MoonBit encoder and decodes
// with the pure MoonBit decoder. The C-side independent arbitration lives in
// libavcodec/x264 (`x264_probe_frames`, native-only).

///|
fn h264_combo_fixture(count : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<count {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    // A moving diagonal edge gives the intra / inter / 8x8 decisions signal.
    for row in 0..<h {
      for col in 0..<w {
        let edge = (col + row + f * 3) % 24 < 4
        y.push((if edge { 208 } else { 48 }).to_byte())
      }
    }
    for _row in 0..<(h / 2) {
      for _col in 0..<(w / 2) {
        u.push((128).to_byte())
        v.push((128).to_byte())
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
fn h264_combo_decode(stream : Bytes, label : String, n : Int32) -> Unit raise {
  let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(d) => d
    Err(e) => fail("\{label}: decode failed: \{e}")
  }
  if decoded.length() != n {
    fail("\{label}: decoded \{decoded.length()} frames, expected \{n}")
  }
}

///|
fn h264_combo_cavlc(
  frames : Array[(Bytes, Bytes, Bytes)],
  b_slices : Bool,
  b_parts : Bool,
  intra_in_b : Bool,
  intra4x4_in_b : Bool,
  dct8x8 : Bool,
  label : String,
) -> Unit raise {
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices~,
      b_parts~,
      intra_in_b~,
      intra4x4_in_b~,
      dct8x8~,
    ) {
    Ok(s) => s
    Err(e) => fail("\{label}: encode failed: \{e}")
  }
  h264_combo_decode(stream, label, frames.length())
}

///|
fn h264_combo_cabac(
  frames : Array[(Bytes, Bytes, Bytes)],
  b_slices : Bool,
  b_parts : Bool,
  intra_in_b : Bool,
  intra4x4_in_b : Bool,
  dct8x8 : Bool,
  cabac_rd : Bool,
  label : String,
) -> Unit raise {
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices~,
      b_parts~,
      intra_in_b~,
      intra4x4_in_b~,
      dct8x8~,
      cabac_rd~,
    ) {
    Ok(s) => s
    Err(e) => fail("\{label}: encode failed: \{e}")
  }
  h264_combo_decode(stream, label, frames.length())
}

///|
test "h264 enc combo: CAVLC B x 8x8DCT matrix round-trips" {
  let frames = h264_combo_fixture(6)
  h264_combo_cavlc(frames, false, false, false, false, true, "dct8x8-only")
  h264_combo_cavlc(frames, true, false, false, false, true, "b+dct8x8")
  h264_combo_cavlc(frames, true, true, false, false, true, "b+parts+dct8x8")
  h264_combo_cavlc(frames, true, false, true, false, true, "b+intra16+dct8x8")
  // Regression: used to fail with `invalid coeff_token` (missing flag=0).
  h264_combo_cavlc(frames, true, false, false, true, true, "b+intra4x4+dct8x8")
  h264_combo_cavlc(frames, true, false, true, true, false, "b+intra16+intra4x4")
  // Regression: used to fail with unavailable left samples.
  h264_combo_cavlc(frames, true, true, true, true, true, "all-on")
}

///|
test "h264 enc combo: CABAC B x 8x8DCT matrix round-trips" {
  let frames = h264_combo_fixture(6)
  h264_combo_cabac(
    frames, false, false, false, false, false, false, "plain-cabac",
  )
  // Regression: used to fail with `missing end_of_slice_flag`.
  h264_combo_cabac(frames, true, false, false, false, true, false, "b+dct8x8")
  h264_combo_cabac(frames, true, false, false, false, true, true, "b+dct8x8+rd")
  h264_combo_cabac(
    frames, true, true, false, false, true, false, "b+parts+dct8x8",
  )
  h264_combo_cabac(
    frames, true, false, true, false, true, false, "b+intra16+dct8x8",
  )
  h264_combo_cabac(
    frames, true, false, false, true, true, false, "b+intra4x4+dct8x8",
  )
  // Regression: used to fail with `bytestream overread`.
  h264_combo_cabac(frames, true, true, true, true, true, true, "all-on")
}

///|
test "h264 enc combo: B slice appears only from the third picture" {
  // n=2 is I+P (no B slice); n=3 introduces the first B picture. The
  // ctx-399 neighbour state bug only showed up once a B slice existed.
  let f2 = h264_combo_fixture(2)
  let f3 = h264_combo_fixture(3)
  h264_combo_cabac(f2, true, false, false, false, true, false, "n=2")
  h264_combo_cabac(f3, true, false, false, false, true, false, "n=3")
  h264_combo_cavlc(f3, true, false, false, false, true, "n=3 cavlc")
}

///|
/// The opt-in contract: with no flags the streams must be byte-identical to
/// explicitly passing every B-line / transform flag as false. §403 keeps the
/// defaults off; promoting them is a separate change that must re-pin every
/// stream digest and PSNR gate first.
test "h264 enc combo: defaults are the full B-line and opt-out restores it" {
  let frames = h264_combo_fixture(4)
  // §405: the six flags default on — the default stream must equal the
  // explicit all-on call and differ from the legacy opt-out one.
  let default_ = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail("default CAVLC encode failed: \{e}")
  }
  let all_on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
      intra_in_b=true,
      intra4x4_in_b=true,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail("explicit-on CAVLC encode failed: \{e}")
  }
  if default_ != all_on {
    fail("default CAVLC stream differs from the explicit all-on stream")
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=false,
      b_parts=false,
      intra_in_b=false,
      intra4x4_in_b=false,
      dct8x8=false,
    ) {
    Ok(s) => s
    Err(e) => fail("explicit-off CAVLC encode failed: \{e}")
  }
  if off == default_ {
    fail("the opt-out CAVLC stream equals the default (all-on) one")
  }
  let default_cabac = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail("default CABAC encode failed: \{e}")
  }
  let all_on_cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
      intra_in_b=true,
      intra4x4_in_b=true,
      dct8x8=true,
      cabac_rd=true,
    ) {
    Ok(s) => s
    Err(e) => fail("explicit-on CABAC encode failed: \{e}")
  }
  if default_cabac != all_on_cabac {
    fail("default CABAC stream differs from the explicit all-on stream")
  }
  h264_combo_decode(default_, "default CAVLC", 4)
  h264_combo_decode(default_cabac, "default CABAC", 4)
}

///|
/// §405 regression: `b_slices + b_parts + dct8x8` CABAC used to desync the
/// B slice (the candidate-price trials left intra state on inter MBs'
/// mirror infos; the pre-write clear in `encode_b_frame_cabac` fixes it).
/// The gradient fixture misses it — the intra-leaning bi8 fixture
/// reproduces.
test "h264 enc combo: parts+dct8x8 cabac on the bi8 fixture" {
  let frames = h264bi8_fixture(96, 64, 6)
  h264_combo_cabac(
    frames, true, true, false, false, true, false, "bi8-fixture b+parts+dct8x8",
  )
}
