///|
/// Outputs from a standalone C reference using dav1d 1.5.1
/// `dav1d_obmc_masks`, `blend_v_c`, and `blend_h_c`.
test "av1 OBMC vertical and horizontal match dav1d C reference" {
  let cases : Array[Array[Int32]] = [
    [2, 32, 8, 72990, 930856],
    [4, 16, 10, 627054, 260203],
    [8, 8, 12, 492826, 104501],
    [16, 4, 8, 326778, 293783],
    [32, 2, 10, 881827, 805374],
  ]
  for c in 0..<cases.length() {
    let p = cases[c]
    let w = p[0]
    let h = p[1]
    let depth = p[2]
    let dst = FixedArray::make(w * h, 0)
    let tmp = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let i = y * w + x
        dst[i] = (x * 37 + y * 61 + x * y * 11 + c * 17) & ((1 << depth) - 1)
        tmp[i] = (x * 83 + y * 19 + x * y * 7 + c * 31) & ((1 << depth) - 1)
      }
    }
    let v = @av1_mc_core.av1_mc_obmc_vertical(dst, tmp, w, h)
    let hor = @av1_mc_core.av1_mc_obmc_horizontal(dst, tmp, w, h)
    let mut vd = 0
    let mut hd = 0
    for i in 0..<(w * h) {
      vd = (vd * 257 + v[i]) % 1000003
      hd = (hd * 257 + hor[i]) % 1000003
      assert_eq(
        dst[i],
        (i % w * 37 + i / w * 61 + i % w * (i / w) * 11 + c * 17) &
        ((1 << depth) - 1),
      )
    }
    assert_eq(vd, p[3])
    assert_eq(hd, p[4])
  }
}
