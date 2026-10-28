///|
/// AV1 film grain synthesis, ported from dav1d 1.5.1 `src/fg_apply_tmpl.c`,
/// `src/filmgrain_tmpl.c` and the Gaussian table in `src/tables.c`
/// (BSD-2-Clause, Copyright (c) 2018, VideoLAN and dav1d authors).
///
/// Grain is applied to the displayed frame only; decoded pictures kept as
/// references retain their un-grained samples, as in the AV1 specification.

///|
let av1_grain_width : Int32 = 82

///|
let av1_grain_height : Int32 = 73

///|
/// The template has one extra row for the overlap sampler.
let av1_grain_lut_rows : Int32 = 74

///|
let av1_sub_grain_width : Int32 = 44

///|
let av1_sub_grain_height : Int32 = 38

///|
let av1_fg_block_size : Int32 = 32

///|
let av1_gaussian_sequence : FixedArray[Int32] = [
  56, 568, -180, 172, 124, -84, 172, -64, -900, 24, 820, 224, 1248, 996, 272, -8,
  -916, -388, -732, -104, -188, 800, 112, -652, -320, -376, 140, -252, 492, -168,
  44, -788, 588, -584, 500, -228, 12, 680, 272, -476, 972, -100, 652, 368, 432, -196,
  -720, -192, 1000, -332, 652, -136, -552, -604, -4, 192, -220, -136, 1000, -52,
  372, -96, -624, 124, -24, 396, 540, -12, -104, 640, 464, 244, -208, -84, 368, -528,
  -740, 248, -968, -848, 608, 376, -60, -292, -40, -156, 252, -292, 248, 224, -280,
  400, -244, 244, -60, 76, -80, 212, 532, 340, 128, -36, 824, -352, -60, -264, -96,
  -612, 416, -704, 220, -204, 640, -160, 1220, -408, 900, 336, 20, -336, -96, -792,
  304, 48, -28, -1232, -1172, -448, 104, -292, -520, 244, 60, -948, 0, -708, 268,
  108, 356, -548, 488, -344, -136, 488, -196, -224, 656, -236, -1128, 60, 4, 140,
  276, -676, -376, 168, -108, 464, 8, 564, 64, 240, 308, -300, -400, -456, -136,
  56, 120, -408, -116, 436, 504, -232, 328, 844, -164, -84, 784, -168, 232, -224,
  348, -376, 128, 568, 96, -1244, -288, 276, 848, 832, -360, 656, 464, -384, -332,
  -356, 728, -388, 160, -192, 468, 296, 224, 140, -776, -100, 280, 4, 196, 44, -36,
  -648, 932, 16, 1428, 28, 528, 808, 772, 20, 268, 88, -332, -284, 124, -384, -448,
  208, -228, -1044, -328, 660, 380, -148, -300, 588, 240, 540, 28, 136, -88, -436,
  256, 296, -1000, 1400, 0, -48, 1056, -136, 264, -528, -1108, 632, -484, -592, -344,
  796, 124, -668, -768, 388, 1296, -232, -188, -200, -288, -4, 308, 100, -168, 256,
  -500, 204, -508, 648, -136, 372, -272, -120, -1004, -552, -548, -384, 548, -296,
  428, -108, -8, -912, -324, -224, -88, -112, -220, -100, 996, -796, 548, 360, -216,
  180, 428, -200, -212, 148, 96, 148, 284, 216, -412, -320, 120, -300, -384, -604,
  -572, -332, -8, -180, -176, 696, 116, -88, 628, 76, 44, -516, 240, -208, -40, 100,
  -592, 344, -308, -452, -228, 20, 916, -1752, -136, -340, -804, 140, 40, 512, 340,
  248, 184, -492, 896, -156, 932, -628, 328, -688, -448, -616, -752, -100, 560, -1020,
  180, -800, -64, 76, 576, 1068, 396, 660, 552, -108, -28, 320, -628, 312, -92, -92,
  -472, 268, 16, 560, 516, -672, -52, 492, -100, 260, 384, 284, 292, 304, -148, 88,
  -152, 1012, 1064, -228, 164, -376, -684, 592, -392, 156, 196, -524, -64, -884,
  160, -176, 636, 648, 404, -396, -436, 864, 424, -728, 988, -604, 904, -592, 296,
  -224, 536, -176, -920, 436, -48, 1176, -884, 416, -776, -824, -884, 524, -548,
  -564, -68, -164, -96, 692, 364, -692, -1012, -68, 260, -480, 876, -1116, 452, -332,
  -352, 892, -1088, 1220, -676, 12, -292, 244, 496, 372, -32, 280, 200, 112, -440,
  -96, 24, -644, -184, 56, -432, 224, -980, 272, -260, 144, -436, 420, 356, 364,
  -528, 76, 172, -744, -368, 404, -752, -416, 684, -688, 72, 540, 416, 92, 444, 480,
  -72, -1416, 164, -1172, -68, 24, 424, 264, 1040, 128, -912, -524, -356, 64, 876,
  -12, 4, -88, 532, 272, -524, 320, 276, -508, 940, 24, -400, -120, 756, 60, 236,
  -412, 100, 376, -484, 400, -100, -740, -108, -260, 328, -268, 224, -200, -416,
  184, -604, -564, -20, 296, 60, 892, -888, 60, 164, 68, -760, 216, -296, 904, -336,
  -28, 404, -356, -568, -208, -1480, -512, 296, 328, -360, -164, -1560, -776, 1156,
  -428, 164, -504, -112, 120, -216, -148, -264, 308, 32, 64, -72, 72, 116, 176, -64,
  -272, 460, -536, -784, -280, 348, 108, -752, -132, 524, -540, -776, 116, -296,
  -1196, -288, -560, 1040, -472, 116, -848, -1116, 116, 636, 696, 284, -176, 1016,
  204, -864, -648, -248, 356, 972, -584, -204, 264, 880, 528, -24, -184, 116, 448,
  -144, 828, 524, 212, -212, 52, 12, 200, 268, -488, -404, -880, 824, -672, -40,
  908, -248, 500, 716, -576, 492, -576, 16, 720, -108, 384, 124, 344, 280, 576, -500,
  252, 104, -308, 196, -188, -8, 1268, 296, 1032, -1196, 436, 316, 372, -432, -200,
  -660, 704, -224, 596, -132, 268, 32, -452, 884, 104, -1008, 424, -1348, -280, 4,
  -1168, 368, 476, 696, 300, -8, 24, 180, -592, -196, 388, 304, 500, 724, -160, 244,
  -84, 272, -256, -420, 320, 208, -144, -156, 156, 364, 452, 28, 540, 316, 220, -644,
  -248, 464, 72, 360, 32, -388, 496, -680, -48, 208, -116, -408, 60, -604, -392,
  548, -840, 784, -460, 656, -544, -388, -264, 908, -800, -628, -612, -568, 572,
  -220, 164, 288, -16, -308, 308, -112, -636, -760, 280, -668, 432, 364, 240, -196,
  604, 340, 384, 196, 592, -44, -500, 432, -580, -132, 636, -76, 392, 4, -412, 540,
  508, 328, -356, -36, 16, -220, -64, -248, -60, 24, -192, 368, 1040, 92, -24, -1044,
  -32, 40, 104, 148, 192, -136, -520, 56, -816, -224, 732, 392, 356, 212, -80, -424,
  -1008, -324, 588, -1496, 576, 460, -816, -848, 56, -580, -92, -1372, -112, -496,
  200, 364, 52, -140, 48, -48, -60, 84, 72, 40, 132, -356, -268, -104, -284, -404,
  732, -520, 164, -304, -540, 120, 328, -76, -460, 756, 388, 588, 236, -436, -72,
  -176, -404, -316, -148, 716, -604, 404, -72, -88, -888, -68, 944, 88, -220, -344,
  960, 472, 460, -232, 704, 120, 832, -228, 692, -508, 132, -476, 844, -748, -364,
  -44, 1116, -1104, -1056, 76, 428, 552, -692, 60, 356, 96, -384, -188, -612, -576,
  736, 508, 892, 352, -1132, 504, -24, -352, 324, 332, -600, -312, 292, 508, -144,
  -8, 484, 48, 284, -260, -240, 256, -100, -292, -204, -44, 472, -204, 908, -188,
  -1000, -256, 92, 1164, -392, 564, 356, 652, -28, -884, 256, 484, -192, 760, -176,
  376, -524, -452, -436, 860, -736, 212, 124, 504, -476, 468, 76, -472, 552, -692,
  -944, -620, 740, -240, 400, 132, 20, 192, -196, 264, -668, -1012, -60, 296, -316,
  -828, 76, -156, 284, -768, -448, -832, 148, 248, 652, 616, 1236, 288, -328, -400,
  -124, 588, 220, 520, -696, 1032, 768, -740, -92, -272, 296, 448, -464, 412, -200,
  392, 440, -200, 264, -152, -260, 320, 1032, 216, 320, -8, -64, 156, -1016, 1084,
  1172, 536, 484, -432, 132, 372, -52, -256, 84, 116, -352, 48, 116, 304, -384, 412,
  924, -300, 528, 628, 180, 648, 44, -980, -220, 1320, 48, 332, 748, 524, -268, -720,
  540, -276, 564, -344, -208, -196, 436, 896, 88, -392, 132, 80, -964, -288, 568,
  56, -48, -456, 888, 8, 552, -156, -292, 948, 288, 128, -716, -292, 1192, -152,
  876, 352, -600, -260, -812, -468, -28, -120, -32, -44, 1284, 496, 192, 464, 312,
  -76, -516, -380, -456, -1012, -48, 308, -156, 36, 492, -156, -808, 188, 1652, 68,
  -120, -116, 316, 160, -140, 352, 808, -416, 592, 316, -480, 56, 528, -204, -568,
  372, -232, 752, -344, 744, -4, 324, -416, -600, 768, 268, -248, -88, -132, -420,
  -432, 80, -288, 404, -316, -1216, -588, 520, -108, 92, -320, 368, -480, -216, -92,
  1688, -300, 180, 1020, -176, 820, -68, -228, -260, 436, -904, 20, 40, -508, 440,
  -736, 312, 332, 204, 760, -372, 728, 96, -20, -632, -520, -560, 336, 1076, -64,
  -532, 776, 584, 192, 396, -728, -520, 276, -188, 80, -52, -612, -252, -48, 648,
  212, -688, 228, -52, -260, 428, -412, -272, -404, 180, 816, -796, 48, 152, 484,
  -88, -216, 988, 696, 188, -528, 648, -116, -180, 316, 476, 12, -564, 96, 476, -252,
  -364, -376, -392, 556, -256, -576, 260, -352, 120, -16, -136, -260, -492, 72, 556,
  660, 580, 616, 772, 436, 424, -32, -324, -1268, 416, -324, -80, 920, 160, 228,
  724, 32, -516, 64, 384, 68, -128, 136, 240, 248, -204, -68, 252, -932, -120, -480,
  -628, -84, 192, 852, -404, -288, -132, 204, 100, 168, -68, -196, -868, 460, 1080,
  380, -80, 244, 0, 484, -888, 64, 184, 352, 600, 460, 164, 604, -196, 320, -64,
  588, -184, 228, 12, 372, 48, -848, -344, 224, 208, -200, 484, 128, -20, 272, -468,
  -840, 384, 256, -720, -520, -464, -580, 112, -120, 644, -356, -208, -608, -528,
  704, 560, -424, 392, 828, 40, 84, 200, -152, 0, -144, 584, 280, -120, 80, -556,
  -972, -196, -472, 724, 80, 168, -32, 88, 160, -688, 0, 160, 356, 372, -776, 740,
  -128, 676, -248, -480, 4, -364, 96, 544, 232, -1032, 956, 236, 356, 20, -40, 300,
  24, -676, -596, 132, 1120, -104, 532, -1096, 568, 648, 444, 508, 380, 188, -376,
  -604, 1488, 424, 24, 756, -220, -192, 716, 120, 920, 688, 168, 44, -460, 568, 284,
  1144, 1160, 600, 424, 888, 656, -356, -320, 220, 316, -176, -724, -188, -816, -628,
  -348, -228, -380, 1012, -452, -660, 736, 928, 404, -696, -72, -268, -892, 128,
  184, -344, -780, 360, 336, 400, 344, 428, 548, -112, 136, -228, -216, -820, -516,
  340, 92, -136, 116, -300, 376, -244, 100, -316, -520, -284, -12, 824, 164, -548,
  -180, -128, 116, -924, -828, 268, -368, -580, 620, 192, 160, 0, -1676, 1068, 424,
  -56, -360, 468, -156, 720, 288, -528, 556, -364, 548, -148, 504, 316, 152, -648,
  -620, -684, -24, -376, -384, -108, -920, -1032, 768, 180, -264, -508, -1268, -260,
  -60, 300, -240, 988, 724, -376, -576, -212, -736, 556, 192, 1092, -620, -880, 376,
  -56, -4, -216, -32, 836, 268, 396, 1332, 864, -600, 100, 56, -412, -92, 356, 180,
  884, -468, -436, 292, -388, -804, -704, -840, 368, -348, 140, -724, 1536, 940,
  372, 112, -372, 436, -480, 1136, 296, -32, -228, 132, -48, -220, 868, -1016, -60,
  -1044, -464, 328, 916, 244, 12, -736, -296, 360, 468, -376, -108, -92, 788, 368,
  -56, 544, 400, -672, -420, 728, 16, 320, 44, -284, -380, -796, 488, 132, 204, -596,
  -372, 88, -152, -908, -636, -572, -624, -116, -692, -200, -56, 276, -88, 484, -324,
  948, 864, 1000, -456, -184, -276, 292, -296, 156, 676, 320, 160, 908, -84, -1236,
  -288, -116, 260, -372, -644, 732, -756, -96, 84, 344, -520, 348, -688, 240, -84,
  216, -1044, -136, -676, -396, -1500, 960, -40, 176, 168, 1516, 420, -504, -344,
  -364, -360, 1216, -940, -380, -212, 252, -660, -708, 484, -444, -152, 928, -120,
  1112, 476, -260, 560, -148, -344, 108, -196, 228, -288, 504, 560, -328, -88, 288,
  -1008, 460, -228, 468, -836, -196, 76, 388, 232, 412, -1168, -716, -644, 756, -172,
  -356, -504, 116, 432, 528, 48, 476, -168, -608, 448, 160, -532, -272, 28, -676,
  -12, 828, 980, 456, 520, 104, -104, 256, -344, -4, -28, -368, -52, -524, -572,
  -556, -200, 768, 1124, -208, -512, 176, 232, 248, -148, -888, 604, -600, -304,
  804, -156, -212, 488, -192, -804, -256, 368, -360, -916, -328, 228, -240, -448,
  -472, 856, -556, -364, 572, -12, -156, -368, -340, 432, 252, -752, -152, 288, 268,
  -580, -848, -592, 108, -76, 244, 312, -716, 592, -80, 436, 360, 4, -248, 160, 516,
  584, 732, 44, -468, -280, -292, -156, -588, 28, 308, 912, 24, 124, 156, 180, -252,
  944, -924, -772, -520, -428, -624, 300, -212, -1144, 32, -724, 800, -1128, -212,
  -1288, -848, 180, -416, 440, 192, -576, -792, -76, -1080, 80, -532, -352, -132,
  380, -820, 148, 1112, 128, 164, 456, 700, -924, 144, -668, -384, 648, -832, 508,
  552, -52, -100, -656, 208, -568, 748, -88, 680, 232, 300, 192, -408, -1012, -152,
  -252, -268, 272, -876, -664, -648, -332, -136, 16, 12, 1152, -28, 332, -536, 320,
  -672, -460, -316, 532, -260, 228, -40, 1052, -816, 180, 88, -496, -556, -672, -368,
  428, 92, 356, 404, -408, 252, 196, -176, -556, 792, 268, 32, 372, 40, 96, -332,
  328, 120, 372, -900, -40, 472, -264, -592, 952, 128, 656, 112, 664, -232, 420,
  4, -344, -464, 556, 244, -416, -32, 252, 0, -412, 188, -696, 508, -476, 324, -1096,
  656, -312, 560, 264, -136, 304, 160, -64, -580, 248, 336, -720, 560, -348, -288,
  -276, -196, -500, 852, -544, -236, -1128, -992, -776, 116, 56, 52, 860, 884, 212,
  -12, 168, 1020, 512, -552, 924, -148, 716, 188, 164, -340, -520, -184, 880, -152,
  -680, -208, -1156, -300, -528, -472, 364, 100, -744, -1056, -32, 540, 280, 144,
  -676, -32, -232, -280, -224, 96, 568, -76, 172, 148, 148, 104, 32, -296, -32, 788,
  -80, 32, -16, 280, 288, 944, 428, -484,
]

///|
fn av1_grain_round2(x : Int32, shift : Int32) -> Int32 {
  (x + (1 << shift >> 1)) >> shift
}

///|
fn av1_grain_iclip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn av1_grain_random(bits : Int32, state : Ref[Int32]) -> Int32 {
  let r = state.val
  let bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
  state.val = (r >> 1) | (bit << 15)
  (state.val >> (16 - bits)) & ((1 << bits) - 1)
}

///|
/// `generate_scaling`: piecewise-linear scaling LUT for one plane.
fn av1_grain_scaling(
  points : Array[Int32],
  num : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let shift_x = if bitdepth > 8 { bitdepth - 8 } else { 0 }
  let size = 1 << bitdepth
  let scaling = FixedArray::make(size, 0)
  if num == 0 {
    return scaling
  }
  let mut i = 0
  while i < points[0] << shift_x {
    scaling[i] = points[1]
    i = i + 1
  }
  for k in 0..<(num - 1) {
    let bx = points[k * 2]
    let by = points[k * 2 + 1]
    let ex = points[k * 2 + 2]
    let ey = points[k * 2 + 3]
    let dx = ex - bx
    let dy = ey - by
    let delta = dy * ((0x10000 + (dx >> 1)) / dx)
    let mut d = 0x8000
    for x in 0..<dx {
      scaling[(bx + x) << shift_x] = by + (d >> 16)
      d = d + delta
    }
  }
  let last = (num - 1) * 2
  let n = points[last] << shift_x
  for k in n..<size {
    scaling[k] = points[last + 1]
  }
  if bitdepth > 8 {
    let pad = 1 << shift_x
    let rnd = pad >> 1
    for k in 0..<(num - 1) {
      let bx = points[k * 2] << shift_x
      let ex = points[k * 2 + 2] << shift_x
      let dx = ex - bx
      let mut x = 0
      while x < dx {
        let range = scaling[bx + x + pad] - scaling[bx + x]
        let mut r = rnd
        for n2 in 1..<pad {
          r = r + range
          scaling[bx + x + n2] = scaling[bx + x] + (r >> shift_x)
        }
        x = x + pad
      }
    }
  }
  scaling
}

///|
fn av1_grain_generate_y(
  hdr : Av1FrameHeader,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let buf = FixedArray::make(av1_grain_lut_rows * av1_grain_width, 0)
  let bd8 = bitdepth - 8
  let seed = Ref(hdr.grain_seed)
  let shift = 4 - bd8 + hdr.grain_scale_shift
  let grain_ctr = 128 << bd8
  let grain_min = -grain_ctr
  let grain_max = grain_ctr - 1
  for y in 0..<av1_grain_height {
    for x in 0..<av1_grain_width {
      let value = av1_grain_random(11, seed)
      buf[y * av1_grain_width + x] = av1_grain_round2(
        av1_gaussian_sequence[value],
        shift,
      )
    }
  }
  let lag = hdr.ar_coeff_lag
  let coeff_shift = hdr.ar_coeff_shift_minus_6 + 6
  for y in 3..<av1_grain_height {
    for x in 3..<(av1_grain_width - 3) {
      let mut c = 0
      let mut sum = 0
      for dyi in 0..<(lag + 1) {
        let dy = dyi - lag
        for dxi in 0..<(2 * lag + 1) {
          let dx = dxi - lag
          if dx == 0 && dy == 0 {
            break
          }
          sum = sum +
            hdr.ar_coeffs_y[c] * buf[(y + dy) * av1_grain_width + x + dx]
          c = c + 1
        }
      }
      let grain = buf[y * av1_grain_width + x] +
        av1_grain_round2(sum, coeff_shift)
      buf[y * av1_grain_width + x] = av1_grain_iclip(
        grain, grain_min, grain_max,
      )
    }
  }
  buf
}

///|
fn av1_grain_generate_uv(
  hdr : Av1FrameHeader,
  buf_y : FixedArray[Int32],
  uv : Int32,
  subx : Int32,
  suby : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let buf = FixedArray::make(av1_grain_lut_rows * av1_grain_width, 0)
  let bd8 = bitdepth - 8
  let seed = Ref(hdr.grain_seed ^ (if uv == 1 { 0x49d8 } else { 0xb524 }))
  let shift = 4 - bd8 + hdr.grain_scale_shift
  let grain_ctr = 128 << bd8
  let grain_min = -grain_ctr
  let grain_max = grain_ctr - 1
  let cw = if subx == 1 { av1_sub_grain_width } else { av1_grain_width }
  let ch = if suby == 1 { av1_sub_grain_height } else { av1_grain_height }
  for y in 0..<ch {
    for x in 0..<cw {
      let value = av1_grain_random(11, seed)
      buf[y * av1_grain_width + x] = av1_grain_round2(
        av1_gaussian_sequence[value],
        shift,
      )
    }
  }
  let lag = hdr.ar_coeff_lag
  let coeff_shift = hdr.ar_coeff_shift_minus_6 + 6
  let coeffs = if uv == 0 { hdr.ar_coeffs_cb } else { hdr.ar_coeffs_cr }
  for y in 3..<ch {
    for x in 3..<(cw - 3) {
      let mut c = 0
      let mut sum = 0
      for dyi in 0..<(lag + 1) {
        let dy = dyi - lag
        for dxi in 0..<(2 * lag + 1) {
          let dx = dxi - lag
          if dx == 0 && dy == 0 {
            if hdr.num_y_points == 0 {
              break
            }
            let mut luma = 0
            let luma_x = ((x - 3) << subx) + 3
            let luma_y = ((y - 3) << suby) + 3
            for i in 0..<(suby + 1) {
              for j in 0..<(subx + 1) {
                luma = luma + buf_y[(luma_y + i) * av1_grain_width + luma_x + j]
              }
            }
            luma = av1_grain_round2(luma, subx + suby)
            sum = sum + luma * coeffs[c]
            break
          }
          sum = sum + coeffs[c] * buf[(y + dy) * av1_grain_width + (x + dx)]
          c = c + 1
        }
      }
      let grain = buf[y * av1_grain_width + x] +
        av1_grain_round2(sum, coeff_shift)
      buf[y * av1_grain_width + x] = av1_grain_iclip(
        grain, grain_min, grain_max,
      )
    }
  }
  buf
}

///|
/// `sample_lut`: one template sample including the overlap block offsets.
fn av1_grain_sample(
  lut : FixedArray[Int32],
  offsets : FixedArray[Int32],
  subx : Int32,
  suby : Int32,
  bx : Int32,
  by : Int32,
  x : Int32,
  y : Int32,
) -> Int32 {
  let randval = offsets[bx * 2 + by]
  let offx = 3 + (2 >> subx) * (3 + (randval >> 4))
  let offy = 3 + (2 >> suby) * (3 + (randval & 0xF))
  lut[(offy + y + (av1_fg_block_size >> suby) * by) * av1_grain_width +
  offx +
  x +
  (av1_fg_block_size >> subx) * bx]
}

///|
fn av1_grain_seed_for_row(seed : Int32, row : Int32) -> Int32 {
  (seed ^ (((row * 37 + 178) & 0xFF) << 8) ^ ((row * 173 + 105) & 0xFF)) &
  0xFFFF
}

///|
fn av1_grain_write_y(
  out_y : FixedArray[Int32],
  src_y : FixedArray[Int32],
  index : Int32,
  grain : Int32,
  scaling : FixedArray[Int32],
  scaling_shift : Int32,
  min_value : Int32,
  max_value : Int32,
) -> Unit {
  let sv = src_y[index]
  let noise = av1_grain_round2(scaling[sv] * grain, scaling_shift)
  out_y[index] = av1_grain_iclip(sv + noise, min_value, max_value)
}

///|
fn av1_grain_apply_y_row(
  out_y : FixedArray[Int32],
  src_y : FixedArray[Int32],
  stride : Int32,
  w : Int32,
  row : Int32,
  bh : Int32,
  hdr : Av1FrameHeader,
  scaling : FixedArray[Int32],
  lut : FixedArray[Int32],
  bitdepth : Int32,
) -> Unit {
  let bd8 = bitdepth - 8
  let grain_ctr = 128 << bd8
  let grain_min = -grain_ctr
  let grain_max = grain_ctr - 1
  let min_value = if hdr.clip_to_restricted_range { 16 << bd8 } else { 0 }
  let max_value = if hdr.clip_to_restricted_range {
    235 << bd8
  } else {
    (1 << bitdepth) - 1
  }
  let scaling_shift = hdr.grain_scaling_minus_8 + 8
  let prev_row = hdr.overlap_flag && row > 0
  let seeds : Array[Ref[Int32]] = [Ref(0), Ref(0)]
  seeds[0].val = av1_grain_seed_for_row(hdr.grain_seed, row)
  if prev_row {
    seeds[1].val = av1_grain_seed_for_row(hdr.grain_seed, row - 1)
  }
  let offsets = FixedArray::make(4, 0)
  let row_y = row * av1_fg_block_size
  let mut bx = 0
  while bx < w {
    let bw = if w - bx < av1_fg_block_size { w - bx } else { av1_fg_block_size }
    if hdr.overlap_flag && bx > 0 {
      offsets[2] = offsets[0]
      offsets[3] = offsets[1]
    }
    offsets[0] = av1_grain_random(8, seeds[0])
    if prev_row {
      offsets[1] = av1_grain_random(8, seeds[1])
    }
    let mut ystart = 0
    if hdr.overlap_flag && row > 0 {
      ystart = if bh < 2 { bh } else { 2 }
    }
    let mut xstart = 0
    if hdr.overlap_flag && bx > 0 {
      xstart = if bw < 2 { bw } else { 2 }
    }
    let mut y = ystart
    while y < bh {
      let mut x = xstart
      while x < bw {
        let grain = av1_grain_sample(lut, offsets, 0, 0, 0, 0, x, y)
        av1_grain_write_y(
          out_y,
          src_y,
          (row_y + y) * stride + bx + x,
          grain,
          scaling,
          scaling_shift,
          min_value,
          max_value,
        )
        x = x + 1
      }
      let mut xl = 0
      while xl < xstart {
        let g0 = av1_grain_sample(lut, offsets, 0, 0, 0, 0, xl, y)
        let old = av1_grain_sample(lut, offsets, 0, 0, 1, 0, xl, y)
        let coef_old = if xl == 0 { 27 } else { 17 }
        let coef_new = if xl == 0 { 17 } else { 27 }
        let mut grain = av1_grain_round2(old * coef_old + g0 * coef_new, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        av1_grain_write_y(
          out_y,
          src_y,
          (row_y + y) * stride + bx + xl,
          grain,
          scaling,
          scaling_shift,
          min_value,
          max_value,
        )
        xl = xl + 1
      }
      y = y + 1
    }
    let mut yl = 0
    while yl < ystart {
      let mut x = xstart
      while x < bw {
        let g0 = av1_grain_sample(lut, offsets, 0, 0, 0, 0, x, yl)
        let old = av1_grain_sample(lut, offsets, 0, 0, 0, 1, x, yl)
        let coef_old = if yl == 0 { 27 } else { 17 }
        let coef_new = if yl == 0 { 17 } else { 27 }
        let mut grain = av1_grain_round2(old * coef_old + g0 * coef_new, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        av1_grain_write_y(
          out_y,
          src_y,
          (row_y + yl) * stride + bx + x,
          grain,
          scaling,
          scaling_shift,
          min_value,
          max_value,
        )
        x = x + 1
      }
      let mut xl = 0
      while xl < xstart {
        let top0 = av1_grain_sample(lut, offsets, 0, 0, 0, 1, xl, yl)
        let top_old = av1_grain_sample(lut, offsets, 0, 0, 1, 1, xl, yl)
        let coef_old = if xl == 0 { 27 } else { 17 }
        let coef_new = if xl == 0 { 17 } else { 27 }
        let mut top = av1_grain_round2(top_old * coef_old + top0 * coef_new, 5)
        top = av1_grain_iclip(top, grain_min, grain_max)
        let g0 = av1_grain_sample(lut, offsets, 0, 0, 0, 0, xl, yl)
        let old = av1_grain_sample(lut, offsets, 0, 0, 1, 0, xl, yl)
        let mut grain = av1_grain_round2(old * coef_old + g0 * coef_new, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        let coef_top = if yl == 0 { 27 } else { 17 }
        let coef_cur = if yl == 0 { 17 } else { 27 }
        grain = av1_grain_round2(top * coef_top + grain * coef_cur, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        av1_grain_write_y(
          out_y,
          src_y,
          (row_y + yl) * stride + bx + xl,
          grain,
          scaling,
          scaling_shift,
          min_value,
          max_value,
        )
        xl = xl + 1
      }
      yl = yl + 1
    }
    bx = bx + av1_fg_block_size
  }
}

///|
fn av1_grain_luma_at(
  src_y : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  x : Int32,
  y : Int32,
) -> Int32 {
  src_y[y * stride + (if x >= width { width - 1 } else { x })]
}

///|
fn av1_grain_write_uv(
  out_uv : FixedArray[Int32],
  src_uv : FixedArray[Int32],
  index : Int32,
  grain : Int32,
  luma_val : Int32,
  hdr : Av1FrameHeader,
  uv : Int32,
  scaling : FixedArray[Int32],
  scaling_shift : Int32,
  min_value : Int32,
  max_value : Int32,
  pixel_max : Int32,
  bitdepth : Int32,
) -> Unit {
  let src_val = src_uv[index]
  let mut val = luma_val
  if !hdr.chroma_scaling_from_luma {
    let mult = if uv == 0 { hdr.cb_mult } else { hdr.cr_mult }
    let luma_mult = if uv == 0 { hdr.cb_luma_mult } else { hdr.cr_luma_mult }
    let offset = if uv == 0 { hdr.cb_offset } else { hdr.cr_offset }
    let combined = luma_val * luma_mult + src_val * mult
    val = av1_grain_iclip(
      (combined >> 6) + (offset << (bitdepth - 8)),
      0,
      pixel_max,
    )
  }
  let noise = av1_grain_round2(scaling[val] * grain, scaling_shift)
  out_uv[index] = av1_grain_iclip(src_val + noise, min_value, max_value)
}

///|
fn av1_grain_apply_uv_row(
  out_uv : FixedArray[Int32],
  src_uv : FixedArray[Int32],
  src_y : FixedArray[Int32],
  stride_uv : Int32,
  stride_y : Int32,
  luma_w : Int32,
  pw : Int32,
  row : Int32,
  bh : Int32,
  hdr : Av1FrameHeader,
  uv : Int32,
  subx : Int32,
  suby : Int32,
  scaling : FixedArray[Int32],
  lut : FixedArray[Int32],
  bitdepth : Int32,
  is_id : Bool,
) -> Unit {
  let bd8 = bitdepth - 8
  let grain_ctr = 128 << bd8
  let grain_min = -grain_ctr
  let grain_max = grain_ctr - 1
  let pixel_max = (1 << bitdepth) - 1
  let min_value = if hdr.clip_to_restricted_range { 16 << bd8 } else { 0 }
  let max_value = if hdr.clip_to_restricted_range {
    (if is_id { 235 } else { 240 }) << bd8
  } else {
    pixel_max
  }
  let scaling_shift = hdr.grain_scaling_minus_8 + 8
  let prev_row = hdr.overlap_flag && row > 0
  let seeds : Array[Ref[Int32]] = [Ref(0), Ref(0)]
  seeds[0].val = av1_grain_seed_for_row(hdr.grain_seed, row)
  if prev_row {
    seeds[1].val = av1_grain_seed_for_row(hdr.grain_seed, row - 1)
  }
  let offsets = FixedArray::make(4, 0)
  let block_y = row * av1_fg_block_size
  let uv_row = block_y >> suby
  let step = av1_fg_block_size >> subx
  let mut bx = 0
  while bx < pw {
    let bw = if pw - bx < step { pw - bx } else { step }
    if hdr.overlap_flag && bx > 0 {
      offsets[2] = offsets[0]
      offsets[3] = offsets[1]
    }
    offsets[0] = av1_grain_random(8, seeds[0])
    if prev_row {
      offsets[1] = av1_grain_random(8, seeds[1])
    }
    let mut ystart = 0
    if hdr.overlap_flag && row > 0 {
      ystart = if bh < 2 >> suby { bh } else { 2 >> suby }
    }
    let mut xstart = 0
    if hdr.overlap_flag && bx > 0 {
      xstart = if bw < 2 >> subx { bw } else { 2 >> subx }
    }
    let coef_old = if subx == 0 { 27 } else { 23 }
    let coef_new = if subx == 0 { 17 } else { 22 }
    let coef_old_y = if suby == 0 { 27 } else { 23 }
    let coef_new_y = if suby == 0 { 17 } else { 22 }
    let mut y = ystart
    while y < bh {
      let ly = block_y + (y << suby)
      let mut x = xstart
      while x < bw {
        let lx = (bx + x) << subx
        let mut avg = av1_grain_luma_at(src_y, stride_y, luma_w, lx, ly)
        if subx == 1 {
          avg = (
              avg + av1_grain_luma_at(src_y, stride_y, luma_w, lx + 1, ly) + 1
            ) >>
            1
        }
        let grain = av1_grain_sample(lut, offsets, subx, suby, 0, 0, x, y)
        av1_grain_write_uv(
          out_uv,
          src_uv,
          (uv_row + y) * stride_uv + bx + x,
          grain,
          avg,
          hdr,
          uv,
          scaling,
          scaling_shift,
          min_value,
          max_value,
          pixel_max,
          bitdepth,
        )
        x = x + 1
      }
      let mut xl = 0
      while xl < xstart {
        let g0 = av1_grain_sample(lut, offsets, subx, suby, 0, 0, xl, y)
        let old = av1_grain_sample(lut, offsets, subx, suby, 1, 0, xl, y)
        let mut grain = av1_grain_round2(old * coef_old + g0 * coef_new, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        let lx = (bx + xl) << subx
        let mut avg = av1_grain_luma_at(src_y, stride_y, luma_w, lx, ly)
        if subx == 1 {
          avg = (
              avg + av1_grain_luma_at(src_y, stride_y, luma_w, lx + 1, ly) + 1
            ) >>
            1
        }
        av1_grain_write_uv(
          out_uv,
          src_uv,
          (uv_row + y) * stride_uv + bx + xl,
          grain,
          avg,
          hdr,
          uv,
          scaling,
          scaling_shift,
          min_value,
          max_value,
          pixel_max,
          bitdepth,
        )
        xl = xl + 1
      }
      y = y + 1
    }
    let mut yl = 0
    while yl < ystart {
      let ly = block_y + (yl << suby)
      let mut x = xstart
      while x < bw {
        let g0 = av1_grain_sample(lut, offsets, subx, suby, 0, 0, x, yl)
        let old = av1_grain_sample(lut, offsets, subx, suby, 0, 1, x, yl)
        let mut grain = av1_grain_round2(old * coef_old_y + g0 * coef_new_y, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        let lx = (bx + x) << subx
        let mut avg = av1_grain_luma_at(src_y, stride_y, luma_w, lx, ly)
        if subx == 1 {
          avg = (
              avg + av1_grain_luma_at(src_y, stride_y, luma_w, lx + 1, ly) + 1
            ) >>
            1
        }
        av1_grain_write_uv(
          out_uv,
          src_uv,
          (uv_row + yl) * stride_uv + bx + x,
          grain,
          avg,
          hdr,
          uv,
          scaling,
          scaling_shift,
          min_value,
          max_value,
          pixel_max,
          bitdepth,
        )
        x = x + 1
      }
      let mut xl = 0
      while xl < xstart {
        let top0 = av1_grain_sample(lut, offsets, subx, suby, 0, 1, xl, yl)
        let top_old = av1_grain_sample(lut, offsets, subx, suby, 1, 1, xl, yl)
        let mut top = av1_grain_round2(top_old * coef_old + top0 * coef_new, 5)
        top = av1_grain_iclip(top, grain_min, grain_max)
        let g0 = av1_grain_sample(lut, offsets, subx, suby, 0, 0, xl, yl)
        let old = av1_grain_sample(lut, offsets, subx, suby, 1, 0, xl, yl)
        let mut grain = av1_grain_round2(old * coef_old + g0 * coef_new, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        grain = av1_grain_round2(top * coef_old_y + grain * coef_new_y, 5)
        grain = av1_grain_iclip(grain, grain_min, grain_max)
        let lx = (bx + xl) << subx
        let mut avg = av1_grain_luma_at(src_y, stride_y, luma_w, lx, ly)
        if subx == 1 {
          avg = (
              avg + av1_grain_luma_at(src_y, stride_y, luma_w, lx + 1, ly) + 1
            ) >>
            1
        }
        av1_grain_write_uv(
          out_uv,
          src_uv,
          (uv_row + yl) * stride_uv + bx + xl,
          grain,
          avg,
          hdr,
          uv,
          scaling,
          scaling_shift,
          min_value,
          max_value,
          pixel_max,
          bitdepth,
        )
        xl = xl + 1
      }
      yl = yl + 1
    }
    bx = bx + step
  }
}

///|
/// Apply the parsed film grain parameters to a decoded frame, returning the
/// grain-blended output. The input picture is left untouched so reference
/// slots keep the pre-grain samples.
pub fn av1_apply_grain(
  frame : Av1FrameOutput,
  hdr : Av1FrameHeader,
  seq : Av1SequenceParameters,
) -> Av1FrameOutput {
  let bitdepth = frame.bitdepth
  let subx = frame.ss_h
  let suby = frame.ss_v
  let lut_y = av1_grain_generate_y(hdr, bitdepth)
  let need_uv_luma_scaling = hdr.chroma_scaling_from_luma
  let lut_cb : FixedArray[Int32] = if frame.mono ||
    (hdr.num_cb_points == 0 && !need_uv_luma_scaling) {
    FixedArray::make(1, 0)
  } else {
    av1_grain_generate_uv(hdr, lut_y, 0, subx, suby, bitdepth)
  }
  let lut_cr : FixedArray[Int32] = if frame.mono ||
    (hdr.num_cr_points == 0 && !need_uv_luma_scaling) {
    FixedArray::make(1, 0)
  } else {
    av1_grain_generate_uv(hdr, lut_y, 1, subx, suby, bitdepth)
  }
  let scaling_y : FixedArray[Int32] = if hdr.num_y_points > 0 ||
    need_uv_luma_scaling {
    av1_grain_scaling(hdr.y_points, hdr.num_y_points, bitdepth)
  } else {
    FixedArray::make(1, 0)
  }
  let scaling_cb : FixedArray[Int32] = if hdr.num_cb_points > 0 {
    av1_grain_scaling(hdr.cb_points, hdr.num_cb_points, bitdepth)
  } else {
    FixedArray::make(1, 0)
  }
  let scaling_cr : FixedArray[Int32] = if hdr.num_cr_points > 0 {
    av1_grain_scaling(hdr.cr_points, hdr.num_cr_points, bitdepth)
  } else {
    FixedArray::make(1, 0)
  }
  let out : Av1FrameOutput = {
    y: frame.y.copy(),
    u: frame.u.copy(),
    v: frame.v.copy(),
    width: frame.width,
    height: frame.height,
    y_stride: frame.y_stride,
    uv_stride: frame.uv_stride,
    ss_h: frame.ss_h,
    ss_v: frame.ss_v,
    mono: frame.mono,
    bitdepth: frame.bitdepth,
  }
  let is_id = seq.matrix_coefficients == 0
  let rows = (frame.height + av1_fg_block_size - 1) / av1_fg_block_size
  let chroma_w = (frame.width + subx) >> subx
  for row in 0..<rows {
    let bh_y = if frame.height - row * av1_fg_block_size < av1_fg_block_size {
      frame.height - row * av1_fg_block_size
    } else {
      av1_fg_block_size
    }
    if hdr.num_y_points > 0 {
      av1_grain_apply_y_row(
        out.y,
        frame.y,
        frame.y_stride,
        frame.width,
        row,
        bh_y,
        hdr,
        scaling_y,
        lut_y,
        bitdepth,
      )
    }
    if frame.mono {
      continue
    }
    let has_uv = hdr.num_cb_points > 0 ||
      hdr.num_cr_points > 0 ||
      hdr.chroma_scaling_from_luma
    if !has_uv {
      continue
    }
    let bh_uv = (bh_y + suby) >> suby
    if hdr.chroma_scaling_from_luma {
      av1_grain_apply_uv_row(
        out.u,
        frame.u,
        frame.y,
        frame.uv_stride,
        frame.y_stride,
        frame.width,
        chroma_w,
        row,
        bh_uv,
        hdr,
        0,
        subx,
        suby,
        scaling_y,
        lut_cb,
        bitdepth,
        is_id,
      )
      av1_grain_apply_uv_row(
        out.v,
        frame.v,
        frame.y,
        frame.uv_stride,
        frame.y_stride,
        frame.width,
        chroma_w,
        row,
        bh_uv,
        hdr,
        1,
        subx,
        suby,
        scaling_y,
        lut_cr,
        bitdepth,
        is_id,
      )
    } else {
      if hdr.num_cb_points > 0 {
        av1_grain_apply_uv_row(
          out.u,
          frame.u,
          frame.y,
          frame.uv_stride,
          frame.y_stride,
          frame.width,
          chroma_w,
          row,
          bh_uv,
          hdr,
          0,
          subx,
          suby,
          scaling_cb,
          lut_cb,
          bitdepth,
          is_id,
        )
      }
      if hdr.num_cr_points > 0 {
        av1_grain_apply_uv_row(
          out.v,
          frame.v,
          frame.y,
          frame.uv_stride,
          frame.y_stride,
          frame.width,
          chroma_w,
          row,
          bh_uv,
          hdr,
          1,
          subx,
          suby,
          scaling_cr,
          lut_cr,
          bitdepth,
          is_id,
        )
      }
    }
  }
  out
}
