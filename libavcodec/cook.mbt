///|
/// Cook / Cooker / Gecko (RealAudio G2) decoder — a port of
/// `libavcodec/cook.c` (FFmpeg n9.0.2).
///
/// Scope: mono, stereo and joint-stereo subpacket streams as described by
/// the codec extradata (MONO / STEREO / JOINT_STEREO cook versions; the
/// MC_COOK channel-mask variant is parsed but only its single- and
/// joint-stereo layouts are exercised). Output is planar `Double` samples
/// clamped to [-1, 1], matching the C decoder's FLTP float path.
///
/// Arithmetic notes:
///   * The C float pipeline (f32 MDCT, f32 tables) is evaluated in f64 here;
///     decoded audio is expected to match the C reference to well under one
///     s16 LSB.
///   * `decode_bytes` de-scrambles every subpacket by XOR with the repeating
///     key `37 c5 11 f2` anchored at the subpacket start. In the C the
///     key rotation table and the pointer misalignment `off` cancel exactly,
///     so the port applies the plain anchored key.
///   * The IMDCT is the naive full inverse (`ff_tx_mdct_naive_inv` scaled by
///     1/32768, TDAC-mirrored to `2N` outputs as `ff_tx_mdct_inv_full` does).
///   * The noise filler uses the shared `Ac3Lfg` port of `av_lfg` seeded
///     with 0, as the C decoder does.

// ---------------------------------------------------------------------------
// tables from cookdata.h
// ---------------------------------------------------------------------------

///|
/// `expbits_tab`.
let cook_expbits_tab : FixedArray[Int32] = [52, 47, 43, 37, 29, 22, 16, 0]

///|
/// `dither_tab`.
let cook_dither_tab : FixedArray[Double] = [
  0.0, 0.0, 0.0, 0.0, 0.0, 0.176777, 0.25, 0.707107, 1.0,
]

///|
/// `av_clip_uintp2(x, p)`: clip to [0, 2^p - 1].
fn cook_clip_uintp2(a : Int32, p : Int32) -> Int32 {
  if (a & (-1 << p)) == 0 {
    a
  } else if a < 0 {
    0
  } else {
    (1 << p) - 1
  }
}

///|
/// `quant_centroid_tab` (7 x 14, rows padded with zeros).
let cook_quant_centroid_tab : Array[FixedArray[Double]] = [
  [
    0.0, 0.392, 0.761, 1.12, 1.477, 1.832, 2.183, 2.541, 2.893, 3.245, 3.598, 3.942,
    4.288, 4.724,
  ],
  [
    0.0, 0.544, 1.06, 1.563, 2.068, 2.571, 3.072, 3.562, 4.07, 4.62, 0.0, 0.0, 0.0,
    0.0,
  ],
  [
    0.0, 0.746, 1.464, 2.18, 2.882, 3.584, 4.316, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
  ],
  [0.0, 1.006, 2.0, 2.993, 3.985, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  [0.0, 1.321, 2.703, 3.983, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  [0.0, 1.657, 3.491, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  [0.0, 1.964, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
]

///|
/// `invradix_tab` * 0x100000 forms (Q20 reciprocals of the radix).
let cook_invradix_tab : FixedArray[Int32] = [
  74899, 104858, 149797, 209716, 262144, 349526, 524288,
]

///|
/// `kmax_tab`.
let cook_kmax_tab : FixedArray[Int32] = [13, 9, 6, 4, 3, 2, 1]

///|
/// `vd_tab`.
let cook_vd_tab : FixedArray[Int32] = [2, 2, 2, 4, 4, 5, 5]

///|
/// `vpr_tab`.
let cook_vpr_tab : FixedArray[Int32] = [10, 10, 10, 5, 5, 4, 4]

///|
/// `envelope_quant_index_huffcounts[13][16]`.
let cook_env_huffcounts : FixedArray[FixedArray[Int32]] = [
  [0, 0, 3, 8, 3, 1, 1, 1, 1, 0, 2, 4, 0, 0, 0, 0],
  [0, 0, 6, 2, 3, 1, 1, 1, 1, 1, 1, 1, 1, 0, 3, 2],
  [0, 0, 3, 8, 3, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0],
  [0, 0, 5, 4, 3, 0, 3, 0, 3, 1, 1, 0, 4, 0, 0, 0],
  [0, 0, 5, 3, 4, 3, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0],
  [0, 0, 5, 4, 3, 0, 2, 3, 1, 1, 1, 1, 1, 2, 0, 0],
  [0, 1, 4, 2, 3, 1, 1, 1, 1, 1, 1, 1, 1, 0, 2, 4],
  [0, 1, 4, 2, 3, 0, 3, 0, 3, 1, 1, 1, 0, 3, 2, 0],
  [0, 0, 6, 2, 2, 2, 2, 2, 3, 1, 1, 1, 2, 0, 0, 0],
  [0, 0, 6, 2, 2, 3, 0, 3, 1, 1, 1, 1, 0, 4, 0, 0],
  [0, 1, 3, 4, 2, 3, 0, 2, 3, 1, 1, 1, 1, 2, 0, 0],
  [0, 1, 3, 4, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 4],
  [0, 1, 4, 2, 3, 0, 3, 1, 1, 1, 1, 0, 1, 6, 0, 0],
]

///|
/// `envelope_quant_index_huffsyms[13][24]`.
let cook_env_huffsyms : FixedArray[FixedArray[Int32]] = [
  [
    10, 11, 12, 0, 4, 5, 6, 7, 8, 9, 13, 2, 3, 14, 1, 15, 16, 17, 18, 19, 20, 21,
    22, 23,
  ],
  [
    6, 7, 8, 9, 10, 11, 5, 12, 3, 4, 13, 2, 14, 1, 15, 0, 16, 17, 18, 19, 20, 21,
    22, 23,
  ],
  [
    11, 12, 13, 5, 6, 7, 8, 9, 10, 14, 15, 4, 16, 17, 3, 18, 2, 19, 1, 20, 0, 21,
    22, 23,
  ],
  [
    9, 10, 11, 12, 13, 8, 14, 15, 16, 6, 7, 17, 4, 5, 18, 2, 3, 19, 1, 20, 0, 21,
    22, 23,
  ],
  [
    10, 11, 12, 13, 14, 8, 9, 15, 6, 7, 16, 17, 4, 5, 18, 19, 3, 20, 2, 21, 0, 1,
    22, 23,
  ],
  [
    9, 10, 11, 12, 13, 7, 8, 14, 15, 6, 16, 17, 5, 18, 3, 4, 19, 2, 20, 1, 0, 21,
    22, 23,
  ],
  [
    12, 9, 10, 11, 13, 8, 14, 7, 15, 16, 6, 17, 5, 18, 4, 19, 3, 20, 0, 2, 1, 21,
    22, 23,
  ],
  [
    12, 10, 11, 13, 14, 9, 15, 7, 8, 16, 5, 6, 17, 4, 18, 19, 3, 2, 20, 0, 1, 21,
    22, 23,
  ],
  [
    8, 9, 10, 11, 12, 13, 7, 14, 6, 15, 5, 16, 4, 17, 3, 18, 0, 1, 2, 19, 20, 21,
    22, 23,
  ],
  [
    8, 9, 10, 11, 12, 13, 7, 14, 6, 15, 4, 5, 16, 3, 17, 18, 19, 2, 20, 1, 0, 21,
    22, 23,
  ],
  [
    12, 10, 11, 13, 7, 8, 9, 14, 6, 15, 4, 5, 16, 3, 17, 2, 18, 19, 1, 20, 21, 0,
    22, 23,
  ],
  [
    12, 11, 13, 14, 8, 9, 10, 15, 6, 7, 16, 5, 17, 18, 4, 19, 3, 2, 1, 20, 0, 21,
    22, 23,
  ],
  [
    12, 10, 11, 13, 14, 9, 15, 8, 16, 17, 6, 7, 18, 5, 19, 4, 20, 0, 1, 2, 3, 21,
    22, 23,
  ],
]

///|
/// `cvh_huffcounts[7][16]`.
let cook_cvh_huffcounts : FixedArray[FixedArray[Int32]] = [
  [1, 0, 0, 2, 2, 5, 8, 15, 31, 33, 28, 17, 15, 8, 8, 8],
  [1, 0, 0, 2, 4, 5, 7, 16, 18, 12, 11, 7, 3, 5, 1, 2],
  [1, 0, 1, 2, 4, 2, 5, 8, 7, 8, 2, 3, 1, 1, 1, 2],
  [0, 1, 0, 2, 5, 12, 7, 27, 22, 41, 32, 41, 55, 23, 32, 220],
  [0, 1, 0, 5, 7, 4, 8, 9, 17, 10, 13, 17, 12, 14, 92, 0],
  [0, 1, 0, 5, 6, 8, 8, 8, 4, 7, 11, 23, 21, 10, 80, 0],
  [1, 0, 0, 5, 0, 9, 1, 7, 4, 3, 2, 0, 0, 0, 0, 0],
]

///|
/// `cvh_huffsyms0[181]`.
let cook_cvh_syms0 : FixedArray[Int32] = [
  0, 1, 14, 15, 28, 2, 3, 16, 29, 42, 4, 5, 17, 18, 30, 43, 56, 57, 6, 7, 8, 19,
  20, 31, 32, 44, 58, 70, 71, 84, 85, 98, 99, 9, 10, 21, 22, 23, 24, 33, 34, 35,
  36, 45, 46, 47, 48, 59, 60, 61, 72, 73, 74, 86, 87, 100, 101, 112, 113, 114, 126,
  127, 140, 141, 11, 25, 37, 38, 39, 49, 50, 51, 52, 62, 63, 64, 65, 75, 76, 77,
  78, 88, 89, 102, 103, 115, 116, 117, 128, 129, 130, 131, 142, 143, 154, 155, 156,
  12, 13, 26, 27, 40, 53, 66, 67, 79, 80, 90, 91, 92, 104, 105, 106, 118, 119, 132,
  144, 145, 157, 158, 168, 169, 170, 182, 183, 41, 54, 68, 81, 93, 94, 107, 108,
  120, 122, 133, 134, 146, 159, 160, 171, 184, 55, 69, 82, 95, 96, 109, 121, 147,
  148, 161, 172, 173, 174, 185, 186, 83, 110, 123, 135, 136, 149, 150, 187, 97, 111,
  124, 151, 162, 163, 175, 188, 125, 137, 138, 164, 176, 177, 189, 190,
]

///|
/// `cvh_huffsyms1[94]`.
let cook_cvh_syms1 : FixedArray[Int32] = [
  0, 1, 10, 2, 11, 20, 21, 3, 12, 22, 30, 31, 4, 13, 14, 23, 32, 40, 41, 5, 6, 15,
  16, 24, 25, 33, 34, 42, 43, 50, 51, 52, 60, 61, 62, 7, 17, 18, 26, 27, 35, 36,
  44, 45, 53, 54, 63, 70, 71, 72, 80, 81, 82, 8, 9, 28, 37, 46, 55, 56, 64, 73, 83,
  90, 91, 19, 29, 38, 47, 48, 57, 65, 66, 74, 84, 92, 39, 58, 67, 75, 76, 85, 93,
  49, 68, 94, 59, 77, 78, 86, 95, 69, 87, 96,
]

///|
/// `cvh_huffsyms2[48]`.
let cook_cvh_syms2 : FixedArray[Int32] = [
  0, 7, 1, 8, 2, 9, 14, 15, 16, 22, 3, 10, 17, 21, 23, 4, 11, 18, 24, 28, 29, 30,
  35, 5, 12, 25, 31, 36, 37, 42, 6, 13, 19, 20, 26, 32, 38, 43, 39, 44, 27, 33, 45,
  46, 34, 40, 41, 47,
]

///|
/// `cvh_huffsyms3[520]` (uint16 symbols).
let cook_cvh_syms3 : FixedArray[Int32] = [
  0, 1, 125, 5, 6, 25, 30, 150, 2, 7, 26, 31, 126, 130, 131, 151, 155, 156, 250,
  275, 10, 35, 36, 50, 55, 175, 180, 3, 8, 11, 12, 27, 32, 37, 56, 127, 132, 136,
  152, 157, 160, 161, 176, 181, 251, 255, 256, 276, 280, 281, 300, 305, 375, 400,
  15, 16, 40, 41, 51, 60, 61, 75, 80, 135, 162, 177, 185, 186, 200, 205, 301, 306,
  405, 425, 500, 525, 4, 9, 13, 17, 20, 28, 33, 38, 42, 52, 57, 81, 85, 128, 133,
  137, 140, 141, 158, 165, 166, 182, 187, 191, 206, 210, 257, 261, 277, 282, 285,
  286, 310, 311, 325, 330, 376, 380, 401, 406, 430, 21, 29, 46, 62, 65, 66, 76, 86,
  100, 105, 142, 153, 163, 190, 201, 211, 225, 230, 252, 260, 262, 287, 302, 307,
  381, 402, 426, 431, 450, 455, 505, 550, 14, 18, 34, 43, 45, 53, 58, 67, 70, 71,
  77, 87, 138, 146, 167, 168, 171, 178, 183, 192, 207, 216, 235, 258, 265, 283, 291,
  312, 315, 316, 326, 331, 332, 335, 336, 350, 407, 410, 411, 530, 555, 22, 39, 47,
  59, 63, 82, 90, 91, 101, 106, 110, 111, 129, 134, 145, 154, 159, 170, 172, 188,
  195, 196, 202, 212, 215, 226, 231, 236, 253, 263, 266, 267, 278, 288, 290, 292,
  303, 317, 337, 355, 356, 377, 382, 385, 386, 432, 436, 451, 456, 460, 501, 506,
  526, 531, 551, 68, 72, 115, 147, 164, 184, 272, 295, 296, 297, 309, 333, 340, 360,
  387, 416, 427, 435, 437, 480, 510, 532, 556, 19, 44, 54, 83, 97, 104, 107, 143,
  173, 193, 208, 237, 268, 313, 320, 327, 341, 351, 352, 378, 403, 412, 441, 442,
  457, 475, 511, 515, 527, 528, 536, 552, 23, 24, 48, 49, 64, 69, 73, 78, 79, 84,
  88, 89, 92, 93, 94, 95, 96, 98, 102, 103, 108, 109, 112, 113, 116, 117, 118, 120,
  121, 139, 144, 148, 149, 169, 174, 179, 189, 194, 197, 198, 203, 204, 209, 213,
  214, 217, 218, 219, 220, 221, 222, 223, 227, 228, 229, 232, 233, 234, 238, 240,
  241, 242, 243, 245, 246, 254, 259, 264, 269, 270, 271, 273, 279, 284, 289, 293,
  294, 298, 304, 308, 314, 318, 319, 321, 322, 323, 328, 329, 334, 338, 339, 342,
  343, 345, 346, 347, 353, 357, 358, 361, 362, 363, 365, 366, 367, 379, 383, 384,
  388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 404, 408, 409, 413, 414,
  415, 417, 418, 419, 420, 421, 422, 423, 428, 429, 433, 434, 438, 439, 440, 443,
  445, 446, 447, 452, 453, 454, 458, 459, 461, 462, 463, 465, 466, 467, 468, 470,
  471, 476, 477, 478, 481, 482, 483, 485, 486, 487, 490, 491, 502, 503, 504, 507,
  508, 509, 512, 513, 516, 517, 518, 520, 521, 529, 533, 534, 535, 537, 538, 540,
  541, 542, 543, 545, 546, 553, 557, 558, 560, 561, 562, 563, 565, 566, 567, 575,
  576, 577, 578, 580, 581, 582, 583, 585, 586, 587, 590, 591, 600, 601, 605, 606,
]

///|
/// `cvh_huffsyms4[209]`.
let cook_cvh_syms4 : FixedArray[Int32] = [
  0, 1, 4, 16, 64, 80, 5, 17, 20, 21, 65, 68, 84, 69, 81, 85, 128, 2, 6, 8, 25, 32,
  96, 100, 144, 9, 22, 24, 36, 37, 89, 101, 132, 148, 18, 33, 66, 70, 72, 73, 82,
  86, 88, 97, 129, 133, 145, 149, 160, 164, 192, 3, 7, 10, 26, 40, 41, 104, 105,
  112, 208, 12, 13, 28, 29, 48, 52, 74, 90, 102, 116, 152, 161, 165, 19, 23, 34,
  38, 83, 93, 98, 113, 134, 136, 137, 150, 153, 193, 196, 209, 212, 42, 49, 53, 67,
  71, 77, 87, 92, 117, 130, 146, 197, 11, 44, 45, 56, 76, 106, 108, 131, 168, 169,
  176, 180, 213, 224, 14, 15, 27, 30, 31, 35, 39, 43, 46, 50, 51, 54, 55, 57, 58,
  60, 61, 75, 78, 79, 91, 94, 95, 99, 103, 107, 109, 110, 114, 115, 118, 119, 120,
  121, 122, 124, 125, 135, 138, 139, 140, 141, 142, 147, 151, 154, 155, 156, 157,
  158, 162, 163, 166, 167, 170, 172, 173, 177, 178, 181, 182, 184, 185, 194, 195,
  198, 199, 200, 201, 202, 204, 205, 210, 211, 214, 215, 216, 217, 218, 220, 221,
  225, 226, 228, 229, 230, 232, 233, 240, 241, 244, 245,
]

///|
/// `cvh_huffsyms5[192]`.
let cook_cvh_syms5 : FixedArray[Int32] = [
  0, 1, 3, 9, 27, 81, 4, 12, 36, 82, 84, 108, 10, 13, 28, 30, 39, 90, 109, 117, 31,
  37, 40, 85, 91, 93, 111, 120, 2, 54, 94, 112, 118, 121, 162, 189, 5, 6, 18, 135,
  7, 15, 21, 45, 63, 163, 171, 11, 16, 19, 48, 57, 83, 87, 99, 144, 165, 198, 14,
  29, 32, 33, 34, 42, 46, 58, 66, 86, 88, 96, 102, 114, 126, 127, 129, 138, 166,
  172, 174, 190, 192, 22, 38, 41, 43, 49, 55, 64, 92, 100, 103, 110, 130, 136, 139,
  145, 147, 148, 175, 193, 199, 201, 8, 24, 95, 97, 115, 119, 123, 153, 180, 216,
  17, 20, 23, 25, 35, 44, 47, 50, 51, 52, 56, 59, 60, 61, 65, 67, 68, 69, 70, 72,
  73, 75, 76, 89, 98, 101, 104, 105, 106, 113, 116, 122, 124, 125, 128, 131, 132,
  133, 137, 140, 141, 142, 146, 149, 150, 151, 154, 156, 157, 164, 167, 168, 169,
  173, 176, 177, 178, 181, 183, 184, 191, 194, 195, 196, 200, 202, 203, 204, 205,
  207, 208, 210, 211, 217, 219, 220, 225, 226, 228, 229,
]

///|
/// `cvh_huffsyms6[32]`.
let cook_cvh_syms6 : FixedArray[Int32] = [
  0, 1, 2, 4, 8, 16, 3, 5, 6, 9, 10, 12, 17, 20, 24, 18, 7, 11, 14, 19, 22, 26, 28,
  13, 21, 25, 30, 15, 27, 29, 23, 31,
]

///|
/// `cvh_huffsyms[7]` assembled (mixed widths).
let cook_cvh_syms : FixedArray[FixedArray[Int32]] = [
  cook_cvh_syms0, cook_cvh_syms1, cook_cvh_syms2, cook_cvh_syms3, cook_cvh_syms4,
  cook_cvh_syms5, cook_cvh_syms6,
]

///|
/// `ccpl_huffcounts[5][16]` for js_vlc_bits 2..6.
let cook_ccpl_huffcounts : FixedArray[FixedArray[Int32]] = [
  [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [1, 0, 2, 2, 2, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0],
  [1, 0, 2, 0, 4, 4, 4, 4, 4, 8, 0, 0, 0, 0, 0, 0],
  [1, 0, 1, 1, 4, 4, 8, 8, 9, 9, 8, 2, 2, 3, 1, 2],
]

///|
/// `ccpl_huffsyms[5]` for js_vlc_bits 2..6.
let cook_ccpl_huffsyms : FixedArray[FixedArray[Int32]] = [
  [1, 0, 2],
  [3, 2, 4, 5, 1, 0, 6],
  [7, 6, 8, 5, 9, 4, 10, 3, 11, 2, 12, 0, 1, 13, 14],
  [
    15, 14, 16, 12, 13, 17, 18, 10, 11, 19, 20, 8, 9, 21, 22, 6, 7, 23, 24, 4, 5,
    25, 26, 0, 1, 2, 3, 27, 28, 29, 30,
  ],
  [
    31, 30, 32, 28, 29, 33, 34, 26, 27, 35, 36, 22, 23, 24, 25, 37, 38, 39, 40, 18,
    19, 20, 21, 41, 42, 43, 44, 13, 14, 15, 16, 17, 45, 46, 47, 48, 9, 10, 11, 12,
    49, 50, 51, 52, 53, 5, 6, 7, 8, 54, 55, 56, 57, 4, 58, 3, 59, 2, 60, 61, 1, 0,
    62,
  ],
]

///|
/// `cplband[51]`: subband -> coupling band.
let cook_cplband : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11, 12, 12, 13, 13, 14, 14, 14, 15, 15, 15,
  15, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 19,
  19, 19, 19, 19, 19, 19, 19, 19,
]

///|
/// `cplscale2[5]`.
let cook_cplscale2 : FixedArray[Double] = [
  1.0, 0.953020632266998, 0.70710676908493, 0.302905440330505, 0.0,
]

///|
/// `cplscale3[9]`.
let cook_cplscale3 : FixedArray[Double] = [
  1.0, 0.981279790401459, 0.936997592449188, 0.875934481620789, 0.70710676908493,
  0.482430040836334, 0.349335819482803, 0.192587479948997, 0.0,
]

///|
/// `cplscale4[17]`.
let cook_cplscale4 : FixedArray[Double] = [
  1.0, 0.991486728191376, 0.973249018192291, 0.953020632266998, 0.930133521556854,
  0.903453230857849, 0.870746195316315, 0.826180458068848, 0.70710676908493, 0.563405573368073,
  0.491732746362686, 0.428686618804932, 0.367221474647522, 0.302905440330505, 0.229752898216248,
  0.130207896232605, 0.0,
]

///|
/// `cplscale5[33]`.
let cook_cplscale5 : FixedArray[Double] = [
  1.0, 0.995926380157471, 0.987517595291138, 0.978726446628571, 0.969505727291107,
  0.95979779958725, 0.949531257152557, 0.938616216182709, 0.926936149597168, 0.914336204528809,
  0.900602877140045, 0.885426938533783, 0.868331849575043, 0.84851086139679, 0.824381768703461,
  0.791833400726318, 0.70710676908493, 0.610737144947052, 0.566034197807312, 0.529177963733673,
  0.495983630418777, 0.464778542518616, 0.434642940759659, 0.404955863952637, 0.375219136476517,
  0.344963222742081, 0.313672333955765, 0.280692428350449, 0.245068684220314, 0.205169528722763,
  0.157508864998817, 0.0901700109243393, 0.0,
]

///|
/// `cplscale6[65]`.
let cook_cplscale6 : FixedArray[Double] = [
  1.0, 0.998005926609039, 0.993956744670868, 0.989822506904602, 0.985598564147949,
  0.981279790401459, 0.976860702037811, 0.972335040569305, 0.967696130275726, 0.962936460971832,
  0.958047747612, 0.953020632266998, 0.947844684123993, 0.942508161067963, 0.936997592449188,
  0.931297719478607, 0.925390899181366, 0.919256627559662, 0.912870943546295, 0.906205296516418,
  0.89922559261322, 0.891890347003937, 0.884148240089417, 0.875934481620789, 0.867165684700012,
  0.857730865478516, 0.847477376461029, 0.836184680461884, 0.823513329029083, 0.808890223503113,
  0.791194140911102, 0.767520070075989, 0.70710676908493, 0.641024887561798, 0.611565053462982,
  0.587959706783295, 0.567296981811523, 0.548448026180267, 0.530831515789032, 0.514098942279816,
  0.498019754886627, 0.482430040836334, 0.467206478118896, 0.452251672744751, 0.437485188245773,
  0.422837972640991, 0.408248275518417, 0.393658757209778, 0.379014074802399, 0.364258885383606,
  0.349335819482803, 0.334183186292648, 0.318732559680939, 0.302905440330505, 0.286608695983887,
  0.269728302955627, 0.252119421958923, 0.233590632677078, 0.213876649737358, 0.192587479948997,
  0.169101938605309, 0.142307326197624, 0.109772264957428, 0.0631198287010193, 0.0,
]

///|
/// `cplscales[5]` for js_vlc_bits 2..6.
let cook_cplscales : FixedArray[FixedArray[Double]] = [
  cook_cplscale2, cook_cplscale3, cook_cplscale4, cook_cplscale5, cook_cplscale6,
]

///|
/// `pow2tab[i] = 2^(i-63)`.
let cook_pow2tab : FixedArray[Double] = FixedArray::makei(127, i => {
  @math.pow(2.0, (i - 63).to_double())
})

///|
/// `rootpow2tab[i] = 2^((i-63)/2)`.
let cook_rootpow2tab : FixedArray[Double] = FixedArray::makei(127, i => {
  @math.pow(2.0, (i - 63).to_double() / 2.0)
})

// ---------------------------------------------------------------------------
// canonical VLC from (counts, symbols) — `build_vlc` + `get_vlc2`
// ---------------------------------------------------------------------------

///|
/// Binary-tree VLC built from code lengths. `nodes` is flat: slots
/// `2*n` / `2*n+1` of node `n` hold `0` for an empty edge, `child + 1` for
/// an internal node and `-(leaf + 1)` for a leaf whose symbol is
/// `syms[leaf]`.
struct CookVlc {
  nodes : Array[Int32]
  syms : Array[Int32]
}

///|
/// `build_vlc` + `ff_vlc_init_from_lengths`: `counts[i]` codes have length
/// `i + 1` and take `syms` in source order (so the length array is already
/// non-decreasing). Codes are canonical, `c[k] = (c[k-1] + 1) << (len_k -
/// len_{k-1})` in source order, which is what the C accumulator
/// `code += 1 << (32 - len)` amounts to. `offset` is added to every symbol.
fn cook_vlc_build(
  counts : FixedArray[Int32],
  syms : FixedArray[Int32],
  offset : Int32,
) -> CookVlc {
  let nodes : Array[Int32] = [0, 0]
  let leaves : Array[Int32] = []
  let mut code : UInt32 = 0U
  let mut prev_len = 0
  let mut sym_idx = 0
  for len = 1; len <= 16; len = len + 1 {
    for _k = 0; _k < counts[len - 1]; _k = _k + 1 {
      let c = code << (len - prev_len)
      let mut node = 0
      for b = 0; b < len - 1; b = b + 1 {
        let bit = ((c >> (len - 1 - b)) & 1U).reinterpret_as_int()
        let slot = 2 * node + bit
        if nodes[slot] == 0 {
          let next = nodes.length() / 2
          nodes.push(0)
          nodes.push(0)
          nodes[slot] = next + 1
        }
        node = nodes[slot] - 1
      }
      let bit = (c & 1U).reinterpret_as_int()
      leaves.push(syms[sym_idx] + offset)
      nodes[2 * node + bit] = -leaves.length()
      code = c + 1U
      prev_len = len
      sym_idx = sym_idx + 1
    }
  }
  { nodes, syms: leaves, }
}

///|
/// `get_vlc2` for a Cook VLC: walk bits until a leaf. Returns 0 on an
/// unparsable code (defensive; the C errors out).
fn CookVlc::read(self : CookVlc, br : BitReader) -> Int32 {
  let nodes = self.nodes
  let mut node = 0
  for i = 0; i < 16; i = i + 1 {
    let bit = br.read1().reinterpret_as_int()
    let slot = node * 2 + bit
    let child = nodes[slot]
    if child < 0 {
      return self.syms[-child - 1]
    }
    if child == 0 {
      return 0
    }
    node = child - 1
  }
  0
}

// ---------------------------------------------------------------------------
// decoder
// ---------------------------------------------------------------------------

///|
/// Cook cook versions.
let cook_mono : Int32 = 0x1000001

///|
let cook_stereo : Int32 = 0x1000002

///|
let cook_joint_stereo : Int32 = 0x1000003

///|
let cook_mc : Int32 = 0x2000000

///|
struct CookSubpacket {
  mut size : Int32
  mut num_channels : Int32
  subbands : Int32
  js_subband_start : Int32
  js_vlc_bits : Int32
  mut samples_per_channel : Int32
  mut log2_numvector_size : Int32
  mut channel_coupling : CookVlc
  mut joint_stereo : Int32
  mut bits_per_subpacket : Int32
  mut bits_per_subpdiv : Int32
  mut total_subbands : Int32
  mut numvector_size : Int32
  mono_previous_buffer1 : FixedArray[Double]
  mono_previous_buffer2 : FixedArray[Double]
  // gains: `now` / `previous` swap like the C FFSWAP
  gains1_now : FixedArray[Int32]
  gains1_prev : FixedArray[Int32]
  gains2_now : FixedArray[Int32]
  gains2_prev : FixedArray[Int32]
}

///|
/// One decoded frame: planar samples in [-1, 1].
pub struct CookFrame {
  samples : Array[FixedArray[Double]]
  channels : Int32
  sample_rate : Int32
}

///|
/// Port of `COOKContext`.
pub struct CookDecoder {
  subpackets : Array[CookSubpacket]
  num_subpackets : Int32
  samples_per_channel : Int32
  channels : Int32
  sample_rate : Int32
  block_align : Int32
  random_state : Ac3Lfg
  mut num_vectors : Int32
  envelope_vlc : Array[CookVlc]
  sqvh : Array[CookVlc]
  gain_size_factor : Int32
  gain_table : FixedArray[Double]
  mlt_window : FixedArray[Double]
  imdct_d : FixedArray[Double]
  imdct_u : FixedArray[Double]
  mono_mdct_output : FixedArray[Double]
  decode_buffer_0 : FixedArray[Double]
  decode_buffer_1 : FixedArray[Double]
  decode_buffer_2 : FixedArray[Double]
  mut discarded_packets : Int32
}

///|
/// `pub fn CookDecoder::new` below keeps the full parse; this helper is the
/// part of it other modules need: the number of samples one frame holds per
/// channel, from the header of the first subpacket (`q->samples_per_channel`
/// of `cook_decode_init`, valid for every subpacket since they must agree).
pub fn cook_samples_per_channel(
  extradata : Bytes,
  channels : Int32,
) -> Result[Int32, String] {
  if extradata.length() < 8 || channels <= 0 {
    return Err("cook: necessary extradata missing")
  }
  let version = (extradata[0].to_int() << 24) |
    (extradata[1].to_int() << 16) |
    (extradata[2].to_int() << 8) |
    extradata[3].to_int()
  let samples_per_frame = (extradata[4].to_int() << 8) | extradata[5].to_int()
  let per_channel = if version == cook_mc {
    // the channel mask follows the 16-byte header
    let mask : UInt32 = if extradata.length() >= 20 {
      (extradata[16].to_int().reinterpret_as_uint() << 24) |
      (extradata[17].to_int().reinterpret_as_uint() << 16) |
      (extradata[18].to_int().reinterpret_as_uint() << 8) |
      extradata[19].to_int().reinterpret_as_uint()
    } else {
      0U
    }
    if cook_popcount64(mask) > 1 {
      samples_per_frame >> 1
    } else {
      samples_per_frame
    }
  } else if version == cook_mono ||
    version == cook_stereo ||
    version == cook_joint_stereo {
    samples_per_frame / channels
  } else {
    return Err("cook: unsupported cook version")
  }
  if per_channel != 256 && per_channel != 512 && per_channel != 1024 {
    return Err("cook: unsupported samples_per_channel")
  }
  Ok(per_channel)
}

///|
/// `cook_decode_init`: parse extradata subpackets and build tables.
pub fn CookDecoder::new(
  extradata : Bytes,
  channels : Int32,
  block_align : Int32,
  sample_rate~ : Int32 = 0,
) -> Result[CookDecoder, String] {
  if extradata.length() < 8 {
    return Err("cook: necessary extradata missing")
  }
  if channels == 0 || block_align <= 0 || block_align >= 0x0FFFFFFF {
    return Err("cook: invalid channels or block_align")
  }
  let subpackets : Array[CookSubpacket] = []
  let mut s = 0
  let mut channel_mask : UInt32 = 0U
  let mut samples_per_frame = 0
  let mut total_channels = 0
  let mut samples_per_channel = 0
  // bytestream2 reads past the end of the extradata as zeros (the mono
  // streams ship only the 8-byte header), so read from a zero-padded copy.
  let padded : Array[Byte] = Array::make(extradata.length() + 24, b'\x00')
  for i = 0; i < extradata.length(); i = i + 1 {
    padded[i] = extradata[i]
  }
  let ext = Bytes::from_array(padded)
  let pos : Ref[Int32] = { val: 0, }
  fn rd32(ext : Bytes, p : Ref[Int32]) -> UInt32 {
    let v = (ext[p.val].to_uint() << 24) |
      (ext[p.val + 1].to_uint() << 16) |
      (ext[p.val + 2].to_uint() << 8) |
      ext[p.val + 3].to_uint()
    p.val = p.val + 4
    v
  }

  fn rd16(ext : Bytes, p : Ref[Int32]) -> UInt32 {
    let v = (ext[p.val].to_uint() << 8) | ext[p.val + 1].to_uint()
    p.val = p.val + 2
    v
  }

  while pos.val < extradata.length() {
    if s >= 5 || s >= block_align {
      return Err("cook: too many subpackets")
    }
    let cookversion = rd32(ext, pos).reinterpret_as_int()
    samples_per_frame = rd16(ext, pos).reinterpret_as_int()
    let subbands = rd16(ext, pos).reinterpret_as_int()
    pos.val = pos.val + 4 // unknown unused
    let js_subband_start = rd16(ext, pos).reinterpret_as_int()
    if js_subband_start >= 51 {
      return Err("cook: js_subband_start too large")
    }
    let js_vlc_bits = rd16(ext, pos).reinterpret_as_int()
    let sp = {
      size: 0,
      num_channels: 1,
      subbands,
      js_subband_start,
      js_vlc_bits,
      samples_per_channel: samples_per_frame / channels,
      log2_numvector_size: 5,
      channel_coupling: cook_vlc_build(
        cook_ccpl_huffcounts[0],
        cook_ccpl_huffsyms[0],
        0,
      ),
      joint_stereo: 0,
      bits_per_subpacket: block_align * 8,
      bits_per_subpdiv: 0,
      total_subbands: subbands,
      numvector_size: 32,
      mono_previous_buffer1: FixedArray::make(1024, 0.0),
      mono_previous_buffer2: FixedArray::make(1024, 0.0),
      gains1_now: FixedArray::make(9, 0),
      gains1_prev: FixedArray::make(9, 0),
      gains2_now: FixedArray::make(9, 0),
      gains2_prev: FixedArray::make(9, 0),
    }
    match cookversion {
      v if v == cook_mono =>
        if channels != 1 {
          return Err("cook: container channels != 1")
        }
      v if v == cook_stereo =>
        if channels != 1 {
          sp.bits_per_subpdiv = 1
          sp.num_channels = 2
        }
      v if v == cook_joint_stereo => {
        if channels != 2 {
          return Err("cook: container channels != 2")
        }
        if extradata.length() >= 16 {
          sp.total_subbands = subbands + js_subband_start
          sp.joint_stereo = 1
          sp.num_channels = 2
        }
        if sp.samples_per_channel > 256 {
          sp.log2_numvector_size = 6
        }
        if sp.samples_per_channel > 512 {
          sp.log2_numvector_size = 7
        }
      }
      v if v == cook_mc => {
        let mask = rd32(ext, pos)
        channel_mask = channel_mask | mask
        let bits = cook_popcount64(mask)
        if bits > 1 {
          sp.total_subbands = subbands + js_subband_start
          sp.joint_stereo = 1
          sp.num_channels = 2
          sp.samples_per_channel = samples_per_frame >> 1
          if sp.samples_per_channel > 256 {
            sp.log2_numvector_size = 6
          }
          if sp.samples_per_channel > 512 {
            sp.log2_numvector_size = 7
          }
        } else {
          sp.samples_per_channel = samples_per_frame
        }
      }
      _ => return Err("cook: unsupported cook version")
    }
    if s > 1 && sp.samples_per_channel != samples_per_channel {
      return Err("cook: different number of samples per channel")
    }
    samples_per_channel = if s == 0 {
      sp.samples_per_channel
    } else {
      samples_per_channel
    }
    sp.numvector_size = 1 << sp.log2_numvector_size
    if sp.total_subbands > 53 {
      return Err("cook: total_subbands > 53")
    }
    if sp.js_vlc_bits > 6 || sp.js_vlc_bits < 2 * sp.joint_stereo {
      return Err("cook: bad js_vlc_bits")
    }
    if sp.subbands > 50 || sp.subbands == 0 {
      return Err("cook: bad subbands")
    }
    if total_channels + sp.num_channels > channels {
      return Err("cook: too many subpacket channels")
    }
    total_channels += sp.num_channels
    subpackets.push(sp)
    s = s + 1
  }
  if channel_mask != 0U && cook_popcount(channel_mask) != total_channels {
    return Err("cook: channel mask does not match subpacket channels")
  }
  if samples_per_channel != 256 &&
    samples_per_channel != 512 &&
    samples_per_channel != 1024 {
    return Err("cook: unsupported samples_per_channel")
  }
  // VLC tables
  let envelope_vlc : Array[CookVlc] = []
  for i = 0; i < 13; i = i + 1 {
    envelope_vlc.push(
      cook_vlc_build(cook_env_huffcounts[i], cook_env_huffsyms[i], -12),
    )
  }
  let sqvh : Array[CookVlc] = []
  for i = 0; i < 7; i = i + 1 {
    sqvh.push(cook_vlc_build(cook_cvh_huffcounts[i], cook_cvh_syms[i], 0))
  }
  for i = 0; i < subpackets.length(); i = i + 1 {
    let sp = subpackets[i]
    if sp.joint_stereo == 1 {
      sp.channel_coupling = cook_vlc_build(
        cook_ccpl_huffcounts[sp.js_vlc_bits - 2],
        cook_ccpl_huffsyms[sp.js_vlc_bits - 2],
        0,
      )
    }
  }
  // gain table
  let gain_size_factor = samples_per_channel / 8
  let gain_table : FixedArray[Double] = FixedArray::make(31, 0.0)
  for i = 0; i < 31; i = i + 1 {
    gain_table[i] = @math.pow(
      cook_pow2tab[i + 48],
      1.0 / gain_size_factor.to_double(),
    )
  }
  // MLT window: `ff_sine_window_init` is a quarter-period sine ramp,
  // sin((j + 1/2) * pi / (2N)), scaled by sqrt(2/N).
  let n = samples_per_channel
  let mlt_window : FixedArray[Double] = FixedArray::make(n, 0.0)
  for j = 0; j < n; j = j + 1 {
    mlt_window[j] = @math.sin(
        (j.to_double() + 0.5) * 3.14159265358979323846 / (2.0 * n.to_double()),
      ) *
      (2.0 / n.to_double()).sqrt()
  }
  // IMDCT cosine tables (ff_tx_mdct_naive_inv, s->len = N)
  let phase = 3.14159265358979323846 / (4.0 * n.to_double())
  let half = n / 2
  let imdct_d : FixedArray[Double] = FixedArray::make(half * n, 0.0)
  let imdct_u : FixedArray[Double] = FixedArray::make(half * n, 0.0)
  for i = 0; i < half; i = i + 1 {
    let i_d = phase * (2 * n - 2 * i - 1).to_double()
    let i_u = phase * (3 * n + 2 * i + 1).to_double()
    for j = 0; j < n; j = j + 1 {
      let a = (2 * j + 1).to_double()
      imdct_d[i * n + j] = @math.cos(a * i_d)
      imdct_u[i * n + j] = @math.cos(a * i_u)
    }
  }
  Ok({
    subpackets,
    num_subpackets: subpackets.length(),
    samples_per_channel: n,
    channels,
    sample_rate,
    block_align,
    random_state: ac3_lfg_new(0U),
    num_vectors: 0,
    envelope_vlc,
    sqvh,
    gain_size_factor,
    gain_table,
    mlt_window,
    imdct_d,
    imdct_u,
    mono_mdct_output: FixedArray::make(2048, 0.0),
    decode_buffer_0: FixedArray::make(1060, 0.0),
    decode_buffer_1: FixedArray::make(1024, 0.0),
    decode_buffer_2: FixedArray::make(1024, 0.0),
    discarded_packets: 0,
  })
}

///|
fn cook_popcount(v : UInt32) -> Int32 {
  let mut x = v
  let mut c = 0
  while x != 0U {
    x = x & (x - 1U)
    c = c + 1
  }
  c
}

///|
fn cook_popcount64(v : UInt32) -> Int32 {
  cook_popcount(v)
}

///|
/// `decode_bytes` + `init_get_bits` + `decode_gain_info` + gains FFSWAP.
/// `base` is the subpacket offset inside the packet (the C XOR key rotation
/// cancels the pointer misalignment, leaving the plain anchored key).
fn cook_decode_bytes_and_gain(
  sp : CookSubpacket,
  pkt : Bytes,
  base : Int32,
  gains_now : FixedArray[Int32],
  gains_prev : FixedArray[Int32],
) -> BitReader {
  let nbits = sp.bits_per_subpacket
  let nbytes = (nbits + 7) / 8
  let buf : FixedArray[Byte] = FixedArray::make(nbytes + 8, b'\x00')
  for t = 0; t < nbytes; t = t + 1 {
    let key : Byte = match t & 3 {
      0 => b'\x37'
      1 => b'\xc5'
      2 => b'\x11'
      _ => b'\xf2'
    }
    buf[t] = pkt[base + t] ^ key
  }
  let br = BitReader::with_size(Bytes::from_array(buf[:]), nbits)
  cook_decode_gain_info(br, gains_now)
  // FFSWAP(now, previous): exchange the arrays' contents (the callers keep
  // using the same two arrays, so swap values instead of references).
  for i = 0; i < 9; i = i + 1 {
    let tmp = gains_now[i]
    gains_now[i] = gains_prev[i]
    gains_prev[i] = tmp
  }
  br
}

///|
/// `decode_gain_info` into a 9-entry array.
fn cook_decode_gain_info(br : BitReader, gaininfo : FixedArray[Int32]) -> Unit {
  // get_unary(gb, 0, left): the bound is sampled once, the 0 bit is consumed.
  let limit = br.bits_left()
  let mut n = 0
  while n < limit && br.read1() == 1U {
    n = n + 1
  }
  let mut i = 0
  while n > 0 {
    let index = br.read(3).reinterpret_as_int()
    let gain = if br.read1() == 1U {
      br.read(4).reinterpret_as_int() - 7
    } else {
      -1
    }
    while i <= index {
      if i < 9 {
        gaininfo[i] = gain
      }
      i = i + 1
    }
    n = n - 1
  }
  while i <= 8 {
    gaininfo[i] = 0
    i = i + 1
  }
}

///|
/// `decode_envelope`.
fn CookDecoder::decode_envelope(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  quant_index_table : FixedArray[Int32],
) -> Bool {
  quant_index_table[0] = br.read(6).reinterpret_as_int() - 6
  for i = 1; i < sp.total_subbands; i = i + 1 {
    let mut vlc_index = i
    if i >= sp.js_subband_start * 2 {
      vlc_index = vlc_index - sp.js_subband_start
    } else {
      vlc_index = vlc_index / 2
      if vlc_index < 1 {
        vlc_index = 1
      }
    }
    if vlc_index > 13 {
      vlc_index = 13
    }
    let j = self.envelope_vlc[vlc_index - 1].read(br)
    quant_index_table[i] = quant_index_table[i - 1] + j
    if quant_index_table[i] > 63 || quant_index_table[i] < -63 {
      return false
    }
  }
  true
}

///|
/// `categorize`.
fn CookDecoder::categorize(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  quant_index_table : FixedArray[Int32],
  category : FixedArray[Int32],
  category_index : FixedArray[Int32],
) -> Unit {
  let exp_index1 : FixedArray[Int32] = FixedArray::make(102, 0)
  let exp_index2 : FixedArray[Int32] = FixedArray::make(102, 0)
  let tmp_categorize_array : FixedArray[Int32] = FixedArray::make(256, 0)
  let mut idx1 = sp.numvector_size
  let mut idx2 = sp.numvector_size
  let mut bits_left = sp.bits_per_subpacket - br.count()
  if bits_left > self.samples_per_channel {
    bits_left = self.samples_per_channel +
      (bits_left - self.samples_per_channel) * 5 / 8
  }
  let mut bias = -32
  // Estimate bias.
  let mut i = 32
  while i > 0 {
    let mut num_bits = 0
    for j = 0; j < sp.total_subbands; j = j + 1 {
      let exp_idx = cook_clip_uintp2((i - quant_index_table[j] + bias) / 2, 3)
      num_bits += cook_expbits_tab[exp_idx]
    }
    if num_bits >= bits_left - 32 {
      bias += i
    }
    i = i / 2
  }
  // Total bits and both watermarks.
  let mut num_bits = 0
  for j = 0; j < sp.total_subbands; j = j + 1 {
    let exp_idx = cook_clip_uintp2((bias - quant_index_table[j]) / 2, 3)
    num_bits += cook_expbits_tab[exp_idx]
    exp_index1[j] = exp_idx
    exp_index2[j] = exp_idx
  }
  let mut tmpbias1 = num_bits
  let mut tmpbias2 = num_bits
  for _j = 1; _j < sp.numvector_size; _j = _j + 1 {
    if tmpbias1 + tmpbias2 > 2 * bits_left {
      // raise a category
      let mut max = -999999
      let mut index = -1
      for k = 0; k < sp.total_subbands; k = k + 1 {
        if exp_index1[k] < 7 {
          let v = -2 * exp_index1[k] - quant_index_table[k] + bias
          if v >= max {
            max = v
            index = k
          }
        }
      }
      if index == -1 {
        break
      }
      tmp_categorize_array[idx1] = index
      idx1 = idx1 + 1
      tmpbias1 = tmpbias1 -
        (
          cook_expbits_tab[exp_index1[index]] -
          cook_expbits_tab[exp_index1[index] + 1]
        )
      exp_index1[index] = exp_index1[index] + 1
    } else {
      // lower a category
      let mut min = 999999
      let mut index = -1
      for k = 0; k < sp.total_subbands; k = k + 1 {
        if exp_index2[k] > 0 {
          let v = -2 * exp_index2[k] - quant_index_table[k] + bias
          if v < min {
            min = v
            index = k
          }
        }
      }
      if index == -1 {
        break
      }
      idx2 = idx2 - 1
      tmp_categorize_array[idx2] = index
      tmpbias2 = tmpbias2 -
        (
          cook_expbits_tab[exp_index2[index]] -
          cook_expbits_tab[exp_index2[index] - 1]
        )
      exp_index2[index] = exp_index2[index] - 1
    }
  }
  for i2 = 0; i2 < sp.total_subbands; i2 = i2 + 1 {
    category[i2] = exp_index2[i2]
  }
  for i2 = 0; i2 < sp.numvector_size - 1; i2 = i2 + 1 {
    category_index[i2] = tmp_categorize_array[idx2]
    idx2 = idx2 + 1
  }
}

///|
/// `expand_category`.
fn CookDecoder::expand_category(
  self : CookDecoder,
  category : FixedArray[Int32],
  category_index : FixedArray[Int32],
) -> Unit {
  for i = 0; i < self.num_vectors; i = i + 1 {
    let idx = category_index[i]
    category[idx] = category[idx] + 1
    if category[idx] >= 9 {
      category[idx] = category[idx] - 1
    }
  }
}

///|
/// `unpack_SQVH`.
fn CookDecoder::unpack_sqvh(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  category : Int32,
  subband_coef_index : FixedArray[Int32],
  subband_coef_sign : FixedArray[Int32],
) -> Bool {
  let vd = cook_vd_tab[category]
  let mut result = false
  for i = 0; i < cook_vpr_tab[category]; i = i + 1 {
    let mut vlc = self.sqvh[category].read(br)
    if sp.bits_per_subpacket < br.count() {
      vlc = 0
      result = true
    }
    let mut v = vlc
    for j = vd - 1; j >= 0; j = j - 1 {
      let tmp = v * cook_invradix_tab[category] / 0x100000
      subband_coef_index[vd * i + j] = v - tmp * (cook_kmax_tab[category] + 1)
      v = tmp
    }
    for j = 0; j < vd; j = j + 1 {
      if subband_coef_index[i * vd + j] != 0 {
        if br.count() < sp.bits_per_subpacket {
          subband_coef_sign[i * vd + j] = br.read1().reinterpret_as_int()
        } else {
          result = true
          subband_coef_sign[i * vd + j] = 0
        }
      } else {
        subband_coef_sign[i * vd + j] = 0
      }
    }
  }
  result
}

///|
/// `scalar_dequant_float`.
fn CookDecoder::scalar_dequant(
  self : CookDecoder,
  index : Int32,
  quant_index : Int32,
  subband_coef_index : FixedArray[Int32],
  subband_coef_sign : FixedArray[Int32],
  mlt : FixedArray[Double],
  mlt_off : Int32,
) -> Unit {
  for i = 0; i < 20; i = i + 1 {
    let mut f1 = 0.0
    if subband_coef_index[i] != 0 {
      f1 = cook_quant_centroid_tab[index][subband_coef_index[i]]
      if subband_coef_sign[i] != 0 {
        f1 = -f1
      }
    } else {
      // noise coding
      let cat = if index > 8 { 8 } else { index }
      f1 = cook_dither_tab[cat]
      if self.random_state.get() < 0x80000000U {
        f1 = -f1
      }
    }
    mlt[mlt_off + i] = f1 * cook_rootpow2tab[quant_index + 63]
  }
}

///|
/// `decode_vectors`.
fn CookDecoder::decode_vectors(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  category : FixedArray[Int32],
  quant_index_table : FixedArray[Int32],
  mlt_buffer : FixedArray[Double],
) -> Unit {
  let subband_coef_index : FixedArray[Int32] = FixedArray::make(20, 0)
  let subband_coef_sign : FixedArray[Int32] = FixedArray::make(20, 0)
  for band = 0; band < sp.total_subbands; band = band + 1 {
    let mut index = category[band]
    if category[band] < 7 {
      if self.unpack_sqvh(
          sp,
          br,
          category[band],
          subband_coef_index,
          subband_coef_sign,
        ) {
        index = 7
        for j = 0; j < sp.total_subbands; j = j + 1 {
          if band + j < 128 {
            category[band + j] = 7
          }
        }
      }
    }
    if index >= 7 {
      for j = 0; j < 20; j = j + 1 {
        subband_coef_index[j] = 0
        subband_coef_sign[j] = 0
      }
    }
    self.scalar_dequant(
      index,
      quant_index_table[band],
      subband_coef_index,
      subband_coef_sign,
      mlt_buffer,
      band * 20,
    )
  }
}

///|
/// `mono_decode`.
fn CookDecoder::mono_decode(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  mlt_buffer : FixedArray[Double],
) -> Bool {
  let category_index : FixedArray[Int32] = FixedArray::make(128, 0)
  let category : FixedArray[Int32] = FixedArray::make(128, 0)
  let quant_index_table : FixedArray[Int32] = FixedArray::make(102, 0)
  if !self.decode_envelope(sp, br, quant_index_table) {
    return false
  }
  self.num_vectors = br.read(sp.log2_numvector_size).reinterpret_as_int()
  self.categorize(sp, br, quant_index_table, category, category_index)
  self.expand_category(category, category_index)
  for i = 0; i < sp.total_subbands; i = i + 1 {
    if category[i] > 7 {
      return false
    }
  }
  self.decode_vectors(sp, br, category, quant_index_table, mlt_buffer)
  true
}

///|
/// `decouple_info`.
fn cook_decouple_info(
  sp : CookSubpacket,
  br : BitReader,
  decouple_tab : FixedArray[Int32],
) -> Bool {
  let vlc = br.read1()
  let start = cook_cplband[sp.js_subband_start]
  let end = cook_cplband[sp.subbands - 1]
  if start > end {
    return true
  }
  let length = end - start + 1
  if vlc == 1U {
    for i = 0; i < length; i = i + 1 {
      decouple_tab[start + i] = sp.channel_coupling.read(br)
    }
  } else {
    for i = 0; i < length; i = i + 1 {
      let v = br.read(sp.js_vlc_bits).reinterpret_as_int()
      if v == (1 << sp.js_vlc_bits) - 1 {
        return false
      }
      decouple_tab[start + i] = v
    }
  }
  true
}

///|
/// `decouple_float`.
fn cook_decouple(
  sp : CookSubpacket,
  subband : Int32,
  f1 : Double,
  f2 : Double,
  decode_buffer : FixedArray[Double],
  mlt1 : FixedArray[Double],
  mlt2 : FixedArray[Double],
) -> Unit {
  for j = 0; j < 20; j = j + 1 {
    let tmp_idx = (sp.js_subband_start + subband) * 20 + j
    mlt1[20 * subband + j] = f1 * decode_buffer[tmp_idx]
    mlt2[20 * subband + j] = f2 * decode_buffer[tmp_idx]
  }
}

///|
/// `joint_decode`.
fn CookDecoder::joint_decode(
  self : CookDecoder,
  sp : CookSubpacket,
  br : BitReader,
  mlt_left : FixedArray[Double],
  mlt_right : FixedArray[Double],
) -> Bool {
  let decouple_tab : FixedArray[Int32] = FixedArray::make(20, 0)
  let decode_buffer = self.decode_buffer_0
  for i = 0; i < 1060; i = i + 1 {
    decode_buffer[i] = 0.0
  }
  for i = 0; i < 1024; i = i + 1 {
    mlt_left[i] = 0.0
    mlt_right[i] = 0.0
  }
  if !cook_decouple_info(sp, br, decouple_tab) {
    return false
  }
  if !self.mono_decode(sp, br, decode_buffer) {
    return false
  }
  // The two channels are stored interleaved below js_subband_start.
  for i = 0; i < sp.js_subband_start; i = i + 1 {
    for j = 0; j < 20; j = j + 1 {
      mlt_left[i * 20 + j] = decode_buffer[i * 40 + j]
      mlt_right[i * 20 + j] = decode_buffer[i * 40 + 20 + j]
    }
  }
  // Coupled higher subbands.
  for i = sp.js_subband_start; i < sp.subbands; i = i + 1 {
    let mut idx = (1 << sp.js_vlc_bits) - 1
    let cpl_tmp = cook_cplband[i]
    idx = idx - decouple_tab[cpl_tmp]
    let cplscale = cook_cplscales[sp.js_vlc_bits - 2]
    let f1 = cplscale[decouple_tab[cpl_tmp] + 1]
    let f2 = cplscale[idx]
    cook_decouple(sp, i, f1, f2, decode_buffer, mlt_left, mlt_right)
  }
  true
}

///|
/// `interpolate_float`.
fn CookDecoder::interpolate(
  self : CookDecoder,
  buffer : FixedArray[Double],
  off : Int32,
  gain_index : Int32,
  gain_index_next : Int32,
) -> Unit {
  let mut fc1 = cook_pow2tab[gain_index + 63]
  if gain_index == gain_index_next {
    for i = 0; i < self.gain_size_factor; i = i + 1 {
      buffer[off + i] = buffer[off + i] * fc1
    }
  } else {
    let fc2 = self.gain_table[15 + (gain_index_next - gain_index)]
    for i = 0; i < self.gain_size_factor; i = i + 1 {
      buffer[off + i] = buffer[off + i] * fc1
      fc1 = fc1 * fc2
    }
  }
}

///|
/// `imlt_window_float` applied in place on `buffer1` (second half of the
/// full IMDCT output living in `mono_mdct_output`).
fn CookDecoder::imlt_window(
  self : CookDecoder,
  out : FixedArray[Double],
  out_off : Int32,
  gains_prev0 : Int32,
  previous_buffer : FixedArray[Double],
) -> Unit {
  let n = self.samples_per_channel
  let fc = cook_pow2tab[gains_prev0 + 63]
  for i = 0; i < n; i = i + 1 {
    out[out_off + i] = out[out_off + i] * fc * self.mlt_window[i] -
      previous_buffer[i] * self.mlt_window[n - 1 - i]
  }
}

///|
/// `imlt_gain` + optional `saturate_output`: full IMDCT of `inbuffer`
/// (N coefficients) into `mono_mdct_output` (2N samples), window the second
/// half, apply the gain profile, then clip to [-1, 1] into `out` when
/// requested.
fn CookDecoder::mlt_compensate_output(
  self : CookDecoder,
  inbuffer : FixedArray[Double],
  gains_now : FixedArray[Int32],
  gains_prev : FixedArray[Int32],
  previous_buffer : FixedArray[Double],
  out : FixedArray[Double],
) -> Unit {
  let n = self.samples_per_channel
  let full = self.mono_mdct_output
  // ff_tx_mdct_naive_inv (scale 1/32768), N coefs -> N samples.
  let half = n / 2
  let scale = 1.0 / 32768.0
  let d = self.imdct_d
  let u = self.imdct_u
  let h : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i = 0; i < half; i = i + 1 {
    let base = i * n
    let mut sum_d = 0.0
    let mut sum_u = 0.0
    for j = 0; j < n; j = j + 1 {
      let v = inbuffer[j]
      if v != 0.0 {
        sum_d = sum_d + d[base + j] * v
        sum_u = sum_u + u[base + j] * v
      }
    }
    h[i] = sum_d * scale
    h[i + half] = -sum_u * scale
  }
  // ff_tx_mdct_inv_full TDAC layout: the half lands at [N/2, 3N/2);
  // buffer0 = full[0..N) (odd antisymmetric mirror), buffer1 = [N..2N)
  // with its second quarter mirroring its first.
  for i = 0; i < half; i = i + 1 {
    full[i] = -h[half - 1 - i]
    full[half + i] = h[i]
    full[n + i] = h[half + i]
    full[2 * n - 1 - i] = full[n + i]
  }
  self.imlt_window(full, n, gains_prev[0], previous_buffer)
  // gain profile
  for i = 0; i < 8; i = i + 1 {
    if gains_now[i] != 0 || gains_now[i + 1] != 0 {
      self.interpolate(
        full,
        n + self.gain_size_factor * i,
        gains_now[i],
        gains_now[i + 1],
      )
    }
  }
  // save away current (first half) as previous block
  for i = 0; i < n; i = i + 1 {
    previous_buffer[i] = full[i]
  }
  // saturate into out
  for i = 0; i < n; i = i + 1 {
    let v = full[n + i]
    out[i] = if v < -1.0 { -1.0 } else if v > 1.0 { 1.0 } else { v }
  }
}

///|
/// `decode_subpacket` for one subpacket at packet offset `base`.
fn CookDecoder::decode_subpacket(
  self : CookDecoder,
  sp : CookSubpacket,
  pkt : Bytes,
  base : Int32,
  out_rows : Array[FixedArray[Double]],
  out_ch : Int32,
) -> Bool {
  for i = 0; i < 1024; i = i + 1 {
    self.decode_buffer_1[i] = 0.0
  }
  let br = cook_decode_bytes_and_gain(
    sp,
    pkt,
    base,
    sp.gains1_now,
    sp.gains1_prev,
  )
  if sp.joint_stereo != 0 {
    if !self.joint_decode(sp, br, self.decode_buffer_1, self.decode_buffer_2) {
      return false
    }
  } else {
    if !self.mono_decode(sp, br, self.decode_buffer_1) {
      return false
    }
    if sp.num_channels == 2 {
      let br2 = cook_decode_bytes_and_gain(
        sp,
        pkt,
        base + sp.size / 2,
        sp.gains2_now,
        sp.gains2_prev,
      )
      if !self.mono_decode(sp, br2, self.decode_buffer_2) {
        return false
      }
    }
  }
  self.mlt_compensate_output(
    self.decode_buffer_1,
    sp.gains1_now,
    sp.gains1_prev,
    sp.mono_previous_buffer1,
    out_rows[out_ch],
  )
  if sp.num_channels == 2 {
    if sp.joint_stereo != 0 {
      self.mlt_compensate_output(
        self.decode_buffer_2,
        sp.gains1_now,
        sp.gains1_prev,
        sp.mono_previous_buffer2,
        out_rows[out_ch + 1],
      )
    } else {
      self.mlt_compensate_output(
        self.decode_buffer_2,
        sp.gains2_now,
        sp.gains2_prev,
        sp.mono_previous_buffer2,
        out_rows[out_ch + 1],
      )
    }
  }
  true
}

///|
/// `cook_decode_frame`: decode one packet (block_align bytes). Returns
/// `None` for the first two frames (discarded by the C decoder as invalid).
pub fn CookDecoder::decode_packet(
  self : CookDecoder,
  pkt : Bytes,
) -> Result[CookFrame?, String] {
  if pkt.length() < self.block_align {
    return Ok(None)
  }
  let out_rows : Array[FixedArray[Double]] = Array::makei(self.channels, _ => {
    FixedArray::make(self.samples_per_channel, 0.0)
  })
  // estimate subpacket sizes
  self.subpackets[0].size = self.block_align
  for i = 1; i < self.num_subpackets; i = i + 1 {
    self.subpackets[i].size = 2 *
      pkt[self.block_align - self.num_subpackets + i].to_int()
    self.subpackets[0].size = self.subpackets[0].size -
      (self.subpackets[i].size + 1)
    if self.subpackets[0].size < 0 {
      return Err("cook: frame subpacket size total > block_align")
    }
  }
  let mut offset = 0
  let mut chidx = 0
  for i = 0; i < self.num_subpackets; i = i + 1 {
    let sp = self.subpackets[i]
    sp.bits_per_subpacket = (sp.size * 8) >> sp.bits_per_subpdiv
    if !self.decode_subpacket(sp, pkt, offset, out_rows, chidx) {
      return Err("cook: invalid subpacket data")
    }
    offset += sp.size
    chidx += sp.num_channels
  }
  if self.discarded_packets < 2 {
    self.discarded_packets += 1
    return Ok(None)
  }
  Ok(
    Some({
      samples: out_rows,
      channels: self.channels,
      sample_rate: self.sample_rate,
    }),
  )
}
