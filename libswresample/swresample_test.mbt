///|
test "swresample: float to s16 uses round-half-to-even like lrintf" {
  // 0.5 LSB cases: 0.5 -> 0, 1.5 -> 2, -0.5 -> 0, -1.5 -> -2 (half to even);
  // ordinary cases round to nearest.
  assert_eq(@swr.swr_flt_to_s16(0.5 / 32768.0), 0)
  assert_eq(@swr.swr_flt_to_s16(1.5 / 32768.0), 2)
  assert_eq(@swr.swr_flt_to_s16(-0.5 / 32768.0), 0)
  assert_eq(@swr.swr_flt_to_s16(-1.5 / 32768.0), -2)
  assert_eq(@swr.swr_flt_to_s16(0.7 / 32768.0), 1)
  assert_eq(@swr.swr_flt_to_s16(-0.7 / 32768.0), -1)
  // Full scale and clipping.
  assert_eq(@swr.swr_flt_to_s16(1.0), 32767)
  assert_eq(@swr.swr_flt_to_s16(-1.0), -32768)
  assert_eq(@swr.swr_flt_to_s16(4.0), 32767)
}

///|

///|
/// Read a little-endian s16 sample from packed bytes.
fn rd_s16(b : Bytes, i : Int32) -> Int32 {
  let v = b[i].to_int() | (b[i + 1].to_int() << 8)
  if v >= 0x8000 {
    v - 0x10000
  } else {
    v
  }
}

///|
test "swresample: planar float interleaves into packed s16" {
  let left : Array[Double] = [0.0, 1.0]
  let right : Array[Double] = [-0.5, 0.25]
  let packed = @swr.Swr::new().flt_planar_to_s16_packed([left, right], 2)
  assert_eq(packed.length(), 8)
  // Sample 0: L=0 -> 0x0000, R=-16384 -> 0xC000.
  assert_eq(packed[0].to_int() | (packed[1].to_int() << 8), 0)
  let r0 = rd_s16(packed, 2)
  assert_eq(r0, -16384)
  // Sample 1: L=1 -> 32767 (clipped).
  let l1 = packed[4].to_int() | (packed[5].to_int() << 8)
  assert_eq(l1, 32767)
  // Sample 1 R = round-half-even of 0.25*32768 = 8192.
  let r1 = rd_s16(packed, 6)
  assert_eq(r1, 8192)
}

///|
test "swresample: mono to stereo duplicates into both channels" {
  let mono : Array[Double] = [0.25, -1.5]
  let packed = @swr.Swr::new().mono_to_stereo_s16_packed(mono)
  assert_eq(packed.length(), 8)
  let s0 = rd_s16(packed, 0)
  let s1 = rd_s16(packed, 2)
  assert_eq(s0, 8192)
  assert_eq(s1, 8192)
  let s2 = rd_s16(packed, 4)
  assert_eq(s2, -32768)
  assert_eq(s2, rd_s16(packed, 6))
}
