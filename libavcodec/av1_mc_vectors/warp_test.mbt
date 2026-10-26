///|
/// Warp-affine 8x8 kernels verified against dav1d 1.5.1
/// `mc_tmpl.c` `warp_affine_8x8_c`/`warp_affine_8x8t_c` via a
/// standalone C dumper (`scripts/_emit_av1_warp_vectors.py`).
/// Planes are 112x80 (8px margins); the block anchors at (8, 8).

///|
fn av1_warp_test_fnv32(values : FixedArray[Int32]) -> Int32 {
  let mut h : UInt32 = 0x811c9dc5
  for v in values {
    for b in 0..<4 {
      h = (h ^ ((v >> (8 * b)) & 0xff).reinterpret_as_uint()) * 0x01000193
    }
  }
  h.reinterpret_as_int()
}

///|
fn av1_warp_test_lcg(
  seed : UInt32,
  n : Int32,
  maxv : Int32,
) -> FixedArray[Int32] {
  let mut state = seed
  let out = FixedArray::make(n, 0)
  for i in 0..<n {
    state = state * 1664525 + 1013904223
    out[i] = (state >> 8).reinterpret_as_int() % (maxv + 1)
  }
  out
}

///|
test "av1 warp affine matches dav1d C reference" {
  let plane8 = av1_warp_test_lcg(0x13579bdf, 112 * 80, 255)
  let plane10 = av1_warp_test_lcg(0x2468ace0, 112 * 80, 1023)
  let plane12 = av1_warp_test_lcg(0x2468ace0, 112 * 80, 4095)
  let pf8 = av1_warp_test_fnv32(plane8)
  if pf8 != 1600707852 {
    fail("plane8 fnv mismatch")
  }
  let pf10 = av1_warp_test_fnv32(plane10)
  if pf10 != 992236246 {
    fail("plane10 fnv mismatch")
  }
  let pf12 = av1_warp_test_fnv32(plane12)
  if pf12 != -106687334 {
    fail("plane12 fnv mismatch")
  }

  // warp 8b abcd=(0,0,0,0) mx=0 my=0
  let abcd : FixedArray[Int32] = [0, 0, 0, 0]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane8, 112, 112, 80, 8, 8, abcd, 0, 0, 8,
  )
  let expected : FixedArray[Int32] = [
    124, 143, 197, 161, 131, 108, 33, 118, 177, 132, 200, 234, 218, 40, 62, 33, 157,
    156, 159, 245, 45, 72, 113, 203, 64, 213, 76, 199, 111, 202, 180, 123, 144, 57,
    200, 95, 165, 176, 18, 50, 153, 185, 30, 184, 209, 250, 127, 231, 86, 98, 69,
    213, 237, 170, 3, 165, 195, 47, 64, 181, 3, 189, 150, 102,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 8b abcd=(0,0,0,0) mx=0 my=0 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 8b abcd=(1638,205,-410,2458) mx=300 my=-700
  let abcd : FixedArray[Int32] = [1638, 205, -410, 2458]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane8, 112, 112, 80, 8, 8, abcd, 300, -700, 8,
  )
  let expected : FixedArray[Int32] = [
    124, 146, 196, 151, 126, 93, 44, 121, 181, 131, 203, 240, 200, 33, 59, 37, 150,
    161, 160, 235, 29, 86, 126, 221, 64, 200, 88, 192, 121, 210, 158, 106, 155, 63,
    194, 92, 182, 159, 20, 62, 139, 186, 16, 210, 233, 223, 137, 214, 99, 75, 95,
    218, 203, 142, 19, 167, 216, 31, 49, 142, 0, 197, 136, 94,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 8b abcd=(1638,205,-410,2458) mx=300 my=-700 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 8b abcd=(-1229,819,1638,-819) mx=-900 my=1500
  let abcd : FixedArray[Int32] = [-1229, 819, 1638, -819]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane8, 112, 112, 80, 8, 8, abcd, -900, 1500, 8,
  )
  let expected : FixedArray[Int32] = [
    121, 140, 196, 175, 158, 113, 39, 76, 180, 131, 200, 236, 210, 37, 59, 55, 153,
    155, 153, 247, 43, 87, 130, 211, 72, 211, 79, 193, 120, 201, 163, 96, 134, 61,
    200, 94, 166, 184, 27, 67, 163, 177, 29, 190, 215, 249, 120, 239, 86, 99, 73,
    218, 231, 169, 5, 152, 189, 33, 80, 173, 0, 188, 157, 89,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 8b abcd=(-1229,819,1638,-819) mx=-900 my=1500 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warpp 8b abcd=(1638,205,-410,2458) mx=300 my=-700
  let abcd : FixedArray[Int32] = [1638, 205, -410, 2458]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8t(
    plane8, 112, 112, 80, 8, 8, abcd, 300, -700, 8,
  )
  let expected : FixedArray[Int32] = [
    1989, 2335, 3138, 2411, 2009, 1485, 704, 1932, 2899, 2094, 3244, 3838, 3202,
    534, 941, 600, 2405, 2568, 2555, 3762, 461, 1371, 2019, 3529, 1025, 3203, 1406,
    3066, 1932, 3361, 2531, 1698, 2487, 1015, 3109, 1474, 2914, 2547, 317, 988, 2225,
    2973, 259, 3355, 3724, 3566, 2185, 3428, 1580, 1197, 1520, 3491, 3253, 2264,
    300, 2675, 3461, 489, 784, 2267, -155, 3154, 2176, 1499,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warpp 8b abcd=(1638,205,-410,2458) mx=300 my=-700 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 10b abcd=(1638,205,-410,2458) mx=300 my=-700
  let abcd : FixedArray[Int32] = [1638, 205, -410, 2458]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane10, 112, 112, 80, 8, 8, abcd, 300, -700, 10,
  )
  let expected : FixedArray[Int32] = [
    319, 747, 41, 597, 537, 72, 551, 276, 277, 532, 238, 304, 155, 276, 513, 266,
    155, 760, 943, 33, 233, 154, 92, 12, 624, 126, 989, 480, 481, 512, 0, 511, 439,
    473, 1023, 386, 554, 207, 308, 695, 414, 505, 683, 571, 481, 983, 867, 360, 436,
    723, 257, 616, 573, 136, 475, 554, 856, 544, 835, 433, 138, 192, 327, 480,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 10b abcd=(1638,205,-410,2458) mx=300 my=-700 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 10b abcd=(-1229,819,1638,-819) mx=-900 my=1500
  let abcd : FixedArray[Int32] = [-1229, 819, 1638, -819]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane10, 112, 112, 80, 8, 8, abcd, -900, 1500, 10,
  )
  let expected : FixedArray[Int32] = [
    328, 741, 16, 478, 574, 25, 484, 441, 295, 542, 282, 275, 146, 214, 443, 298,
    142, 763, 977, 70, 196, 228, 90, 0, 594, 133, 973, 532, 437, 557, 34, 341, 433,
    473, 1003, 422, 547, 280, 193, 727, 417, 440, 829, 549, 433, 892, 1023, 294,
    391, 807, 170, 656, 675, 213, 427, 604, 803, 420, 836, 385, 159, 136, 332, 369,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 10b abcd=(-1229,819,1638,-819) mx=-900 my=1500 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warpp 10b abcd=(1638,205,-410,2458) mx=300 my=-700
  let abcd : FixedArray[Int32] = [1638, 205, -410, 2458]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8t(
    plane10, 112, 112, 80, 8, 8, abcd, 300, -700, 10,
  )
  let expected : FixedArray[Int32] = [
    -3081, 3756, -7539, 1361, 392, -7038, 630, -3776, -3757, 317, -4383, -3334, -5711,
    -3781, 22, -3934, -5705, 3962, 6895, -7666, -4467, -5734, -6714, -7994, 1796,
    -6173, 7625, -505, -492, -6, -8495, -23, -1172, -618, 8182, -2019, 672, -4886,
    -3257, 2921, -1568, -108, 2735, 946, -503, 7528, 5675, -2430, -1219, 3381, -4081,
    1668, 973, -6019, -588, 679, 5497, 518, 5165, -1263, -5980, -5120, -2958, -510,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warpp 10b abcd=(1638,205,-410,2458) mx=300 my=-700 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 12b abcd=(0,0,0,0) mx=0 my=0
  let abcd : FixedArray[Int32] = [0, 0, 0, 0]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane12, 112, 112, 80, 8, 8, abcd, 0, 0, 12,
  )
  let expected : FixedArray[Int32] = [
    2336, 761, 66, 536, 1625, 2083, 2528, 1415, 1305, 1583, 2263, 1345, 1212, 1258,
    543, 2340, 1190, 3784, 1010, 3121, 3242, 2226, 3146, 1078, 3668, 2188, 4026,
    2542, 1453, 3619, 2088, 2307, 2535, 3491, 3031, 448, 1579, 261, 1153, 2835, 3496,
    2452, 1842, 1585, 1455, 2943, 4062, 3344, 352, 1834, 209, 2663, 2750, 2299, 2502,
    608, 2838, 425, 1855, 460, 3202, 1151, 353, 3437,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 12b abcd=(0,0,0,0) mx=0 my=0 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warp 12b abcd=(1434,-615,1230,1640) mx=-400 my=800
  let abcd : FixedArray[Int32] = [1434, -615, 1230, 1640]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8(
    plane12, 112, 112, 80, 8, 8, abcd, -400, 800, 12,
  )
  let expected : FixedArray[Int32] = [
    2357, 731, 81, 437, 1497, 2101, 2246, 1572, 1272, 1746, 2253, 1542, 1450, 1089,
    862, 2048, 1245, 3768, 1125, 3245, 3127, 2774, 3279, 1129, 3678, 2182, 4095,
    2221, 1345, 3043, 1534, 2411, 2772, 3467, 2909, 343, 1594, 341, 1786, 3433, 3257,
    2351, 1521, 2122, 1546, 3392, 4095, 2455, 414, 1666, 280, 1910, 3142, 1664, 1541,
    1271, 2805, 369, 2253, 1110, 2550, 1567, 641, 3087,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warp 12b abcd=(1434,-615,1230,1640) mx=-400 my=800 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }

  // warpp 12b abcd=(-1229,819,1638,-819) mx=-900 my=1500
  let abcd : FixedArray[Int32] = [-1229, 819, 1638, -819]
  let out = @av1_mc_core.av1_mc_warp_affine_8x8t(
    plane12, 112, 112, 80, 8, 8, abcd, -900, 1500, 12,
  )
  let expected : FixedArray[Int32] = [
    1057, -5476, -7716, -6808, -2821, -280, 602, -1245, -3034, -1487, 873, -2101,
    -2435, -3334, -5614, 429, -2958, 6894, -4017, 4561, 4810, 2179, 5504, -3380,
    6033, 600, 8233, 1426, -2814, 4972, -1153, 1433, 1761, 6112, 3563, -6661, -1764,
    -7132, -2734, 3719, 5411, 1542, -935, -1489, -2281, 4306, 8686, 3458, -5967,
    -1006, -7290, 2820, 2963, 197, 664, -4750, 2104, -6167, -1140, -6061, 4671, -3414,
    -6651, 5237,
  ]
  for i in 0..<expected.length() {
    if out[i] != expected[i] {
      fail(
        "warpp 12b abcd=(-1229,819,1638,-819) mx=-900 my=1500 px \{i}: got \{out[i]}, want \{expected[i]}",
      )
    }
  }
}
