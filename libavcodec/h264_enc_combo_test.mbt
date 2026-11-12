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
test "h264 enc combo: default streams remain opt-in byte-identical" {
  let frames = h264_combo_fixture(4)
  let legacy = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail("default CAVLC encode failed: \{e}")
  }
  let explicit = match
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
  if legacy != explicit {
    fail("default CAVLC stream differs from the explicit opt-out stream")
  }
  let legacy_cabac = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail("default CABAC encode failed: \{e}")
  }
  let explicit_cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=false,
      b_parts=false,
      intra_in_b=false,
      intra4x4_in_b=false,
      dct8x8=false,
      cabac_rd=false,
    ) {
    Ok(s) => s
    Err(e) => fail("explicit-off CABAC encode failed: \{e}")
  }
  if legacy_cabac != explicit_cabac {
    fail("default CABAC stream differs from the explicit opt-out stream")
  }
  h264_combo_decode(legacy, "default CAVLC", 4)
  h264_combo_decode(legacy_cabac, "default CABAC", 4)
}
