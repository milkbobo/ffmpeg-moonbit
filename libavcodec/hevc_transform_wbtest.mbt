///|
/// Tests for the HEVC 8-bit inverse transforms.
///
/// Expected vectors were produced by FFmpeg 9.0.2's own C DSP:
/// `ff_hevc_dsp_init(&ctx, 8)` then `ctx.idct[0/1](coeffs, 4/8)`,
/// `ctx.idct_dc[0/1]` and `ctx.transform_4x4_luma`, compiled standalone from
/// `libavcodec/hevc/dsp.c` with the same deterministic coefficient patterns
/// generated here.

///|
fn hgen4() -> Array[Int32] {
  let c : Array[Int32] = []
  for i in 0..<16 {
    c.push((i * 37 + 11) % 127 - 63)
  }
  c[0] = 100
  c
}

///|
fn hgen8() -> Array[Int32] {
  let c : Array[Int32] = []
  for i in 0..<64 {
    c.push((i * 53 + 7) % 255 - 127)
  }
  c[0] = 200
  c
}

///|
fn hgen_dst4() -> Array[Int32] {
  let c : Array[Int32] = []
  for i in 0..<16 {
    c.push((i * 29 + 3) % 127 - 63)
  }
  c[0] = 80
  c
}

///|
test "hevc transform: idct4 matches FFmpeg C" {
  let c = hgen4()
  hevc_idct(c, 2, 4).unwrap()
  assert_eq(c, [1, 1, 0, 0, 1, -2, 0, 3, 2, 0, 2, 1, 1, 0, 3, 0])
}

///|
test "hevc transform: idct8 matches FFmpeg C" {
  let c = hgen8()
  hevc_idct(c, 3, 8).unwrap()
  assert_eq(c, [
    2, 0, -1, 0, 4, 5, -7, -2, 3, 3, 3, 4, 2, 1, 4, 4, 1, 2, 2, 5, 3, 3, -1, 2, 3,
    3, 3, 3, 2, 3, 3, 3, -1, 1, 4, 16, 2, 2, -6, 5, -7, 1, -16, -8, 11, -7, 2, 8,
    4, 3, -1, -9, 4, 2, 7, 1, 2, 2, 0, -2, 4, 2, 4, 3,
  ])
}

///|
test "hevc transform: DC and 4x4 DST match FFmpeg C" {
  let v4 : Array[Int32] = Array::make(16, 0)
  v4[0] = 512
  hevc_idct_dc(v4, 2).unwrap()
  assert_eq(v4, Array::make(16, 4))
  let v8 : Array[Int32] = Array::make(64, 0)
  v8[0] = 1024
  hevc_idct_dc(v8, 3).unwrap()
  assert_eq(v8, Array::make(64, 8))
  let d = hgen_dst4()
  hevc_transform_4x4_luma(d)
  assert_eq(d, [-1, 1, 3, 2, 0, -1, 1, 2, 1, 1, 1, 0, 0, 0, 1, 1])
}

///|
test "hevc transform: dequant and add residual" {
  let c : Array[Int32] = Array::make(16, 0)
  c[0] = 65
  c[1] = -65
  hevc_dequant(c, 2).unwrap()
  // shift 5, offset 16: (65+16)>>5 = 2, (-65+16)>>5 = -2.
  assert_eq(c, [2, -2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  let dst : Array[Int32] = [250, 0, 10, 0]
  let res : Array[Int32] = [10, -10, -20, 5]
  hevc_add_residual(dst, res, 2, 2)
  assert_eq(dst, [255, 0, 0, 5])
}

///|
test "hevc transform: 16x16/32x32 match FFmpeg C metrics" {
  let c16 : Array[Int32] = []
  for i in 0..<256 {
    c16.push((i * 41 + 5) % 255 - 127)
  }
  c16[0] = 300
  hevc_idct(c16, 4, 16).unwrap()
  let mut sum16 = 0
  for v in c16 {
    sum16 = sum16 + v
  }
  assert_eq(sum16, 598)
  assert_eq(c16[0:16], [3, 1, 4, -9, -4, 11, 4, 5, -5, 5, -5, 8, -2, 3, -1, 6])
  assert_eq(c16[100], 3)
  assert_eq(c16[255], -1)
  let c32 : Array[Int32] = []
  for i in 0..<1024 {
    c32.push((i * 23 + 9) % 255 - 127)
  }
  c32[0] = 500
  hevc_idct(c32, 5, 32).unwrap()
  let mut sum32 = 0
  for v in c32 {
    sum32 = sum32 + v
  }
  assert_eq(sum32, 4010)
  assert_eq(c32[0:16], [
    1, 2, 13, 6, -8, 27, 24, -2, 13, 10, 7, 12, -13, 2, 5, -1,
  ])
  assert_eq(c32[100], 2)
  assert_eq(c32[500], 3)
  assert_eq(c32[1023], 5)
}
