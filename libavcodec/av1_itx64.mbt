///|
/// `inv_dct64_1d_c` from dav1d 1.5.1 `src/itx_1d.c`: the TX_64X64 1D core
/// (32-point internal with `tx64` plus the extra 32 butterfly stages).
fn av1_inv_dct64_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  av1_inv_dct32_1d_internal(c, base, stride << 1, min, max, true)
  let inp = FixedArray::make(32, 0)
  for i in 0..<32 {
    inp[i] = c[base + (2 * i + 1) * stride]
  }
  let t32a = (inp[0] * 101 + 2048) >> 12
  let t33a = (inp[15] * -1474 + 2048) >> 12
  let t34a = (inp[8] * 1660 + 2048) >> 12
  let t35a = (inp[7] * -1380 + 2048) >> 12
  let t36a = (inp[4] * 897 + 2048) >> 12
  let t37a = (inp[11] * -2106 + 2048) >> 12
  let t38a = (inp[12] * 2359 + 2048) >> 12
  let t39a = (inp[3] * -700 + 2048) >> 12
  let t40a = (inp[2] * 501 + 2048) >> 12
  let t41a = (inp[13] * -2520 + 2048) >> 12
  let t42a = (inp[10] * 2019 + 2048) >> 12
  let t43a = (inp[5] * -1092 + 2048) >> 12
  let t44a = (inp[6] * 1285 + 2048) >> 12
  let t45a = (inp[9] * -1842 + 2048) >> 12
  let t46a = (inp[14] * 2675 + 2048) >> 12
  let t47a = (inp[1] * -301 + 2048) >> 12
  let t48a = (inp[1] * 4085 + 2048) >> 12
  let t49a = (inp[14] * 3102 + 2048) >> 12
  let t50a = (inp[9] * 3659 + 2048) >> 12
  let t51a = (inp[6] * 3889 + 2048) >> 12
  let t52a = (inp[5] * 3948 + 2048) >> 12
  let t53a = (inp[10] * 3564 + 2048) >> 12
  let t54a = (inp[13] * 3229 + 2048) >> 12
  let t55a = (inp[2] * 4065 + 2048) >> 12
  let t56a = (inp[3] * 4036 + 2048) >> 12
  let t57a = (inp[12] * 3349 + 2048) >> 12
  let t58a = (inp[11] * 3461 + 2048) >> 12
  let t59a = (inp[4] * 3996 + 2048) >> 12
  let t60a = (inp[7] * 3822 + 2048) >> 12
  let t61a = (inp[8] * 3745 + 2048) >> 12
  let t62a = (inp[15] * 2967 + 2048) >> 12
  let t63a = (inp[0] * 4095 + 2048) >> 12
  let t32 = clip_i(t32a + t33a, min, max)
  let t33 = clip_i(t32a - t33a, min, max)
  let t34 = clip_i(t35a - t34a, min, max)
  let t35 = clip_i(t35a + t34a, min, max)
  let t36 = clip_i(t36a + t37a, min, max)
  let t37 = clip_i(t36a - t37a, min, max)
  let t38 = clip_i(t39a - t38a, min, max)
  let t39 = clip_i(t39a + t38a, min, max)
  let t40 = clip_i(t40a + t41a, min, max)
  let t41 = clip_i(t40a - t41a, min, max)
  let t42 = clip_i(t43a - t42a, min, max)
  let t43 = clip_i(t43a + t42a, min, max)
  let t44 = clip_i(t44a + t45a, min, max)
  let t45 = clip_i(t44a - t45a, min, max)
  let t46 = clip_i(t47a - t46a, min, max)
  let t47 = clip_i(t47a + t46a, min, max)
  let t48 = clip_i(t48a + t49a, min, max)
  let t49 = clip_i(t48a - t49a, min, max)
  let t50 = clip_i(t51a - t50a, min, max)
  let t51 = clip_i(t51a + t50a, min, max)
  let t52 = clip_i(t52a + t53a, min, max)
  let t53 = clip_i(t52a - t53a, min, max)
  let t54 = clip_i(t55a - t54a, min, max)
  let t55 = clip_i(t55a + t54a, min, max)
  let t56 = clip_i(t56a + t57a, min, max)
  let t57 = clip_i(t56a - t57a, min, max)
  let t58 = clip_i(t59a - t58a, min, max)
  let t59 = clip_i(t59a + t58a, min, max)
  let t60 = clip_i(t60a + t61a, min, max)
  let t61 = clip_i(t60a - t61a, min, max)
  let t62 = clip_i(t63a - t62a, min, max)
  let t63 = clip_i(t63a + t62a, min, max)
  let t33a2 = ((t33 * (4096 - 4076) + t62 * 401 + 2048) >> 12) - t33
  let t34a2 = ((t34 * -401 + t61 * (4096 - 4076) + 2048) >> 12) - t61
  let t37a2 = (t37 * -1299 + t58 * 1583 + 1024) >> 11
  let t38a2 = (t38 * -1583 + t57 * -1299 + 1024) >> 11
  let t41a2 = ((t41 * (4096 - 3612) + t54 * 1931 + 2048) >> 12) - t41
  let t42a2 = ((t42 * -1931 + t53 * (4096 - 3612) + 2048) >> 12) - t53
  let t45a2 = ((t45 * -1189 + t50 * (3920 - 4096) + 2048) >> 12) + t50
  let t46a2 = ((t46 * (4096 - 3920) + t49 * -1189 + 2048) >> 12) - t46
  let t49a2 = ((t46 * -1189 + t49 * (3920 - 4096) + 2048) >> 12) + t49
  let t50a2 = ((t45 * (3920 - 4096) + t50 * 1189 + 2048) >> 12) + t45
  let t53a2 = ((t42 * (4096 - 3612) + t53 * 1931 + 2048) >> 12) - t42
  let t54a2 = ((t41 * 1931 + t54 * (3612 - 4096) + 2048) >> 12) + t54
  let t57a2 = (t38 * -1299 + t57 * 1583 + 1024) >> 11
  let t58a2 = (t37 * 1583 + t58 * 1299 + 1024) >> 11
  let t61a2 = ((t34 * (4096 - 4076) + t61 * 401 + 2048) >> 12) - t34
  let t62a2 = ((t33 * 401 + t62 * (4076 - 4096) + 2048) >> 12) + t62
  let t32a2 = clip_i(t32 + t35, min, max)
  let t33x = clip_i(t33a2 + t34a2, min, max)
  let t34x = clip_i(t33a2 - t34a2, min, max)
  let t35a2 = clip_i(t32 - t35, min, max)
  let t36a2 = clip_i(t39 - t36, min, max)
  let t37x = clip_i(t38a2 - t37a2, min, max)
  let t38x = clip_i(t38a2 + t37a2, min, max)
  let t39a2 = clip_i(t39 + t36, min, max)
  let t40a2 = clip_i(t40 + t43, min, max)
  let t41x = clip_i(t41a2 + t42a2, min, max)
  let t42x = clip_i(t41a2 - t42a2, min, max)
  let t43a2 = clip_i(t40 - t43, min, max)
  let t44a2 = clip_i(t47 - t44, min, max)
  let t45x = clip_i(t46a2 - t45a2, min, max)
  let t46x = clip_i(t46a2 + t45a2, min, max)
  let t47a2 = clip_i(t47 + t44, min, max)
  let t48a2 = clip_i(t48 + t51, min, max)
  let t49x = clip_i(t49a2 + t50a2, min, max)
  let t50x = clip_i(t49a2 - t50a2, min, max)
  let t51a2 = clip_i(t48 - t51, min, max)
  let t52a2 = clip_i(t55 - t52, min, max)
  let t53x = clip_i(t54a2 - t53a2, min, max)
  let t54x = clip_i(t54a2 + t53a2, min, max)
  let t55a2 = clip_i(t55 + t52, min, max)
  let t56a2 = clip_i(t56 + t59, min, max)
  let t57x = clip_i(t57a2 + t58a2, min, max)
  let t58x = clip_i(t57a2 - t58a2, min, max)
  let t59a2 = clip_i(t56 - t59, min, max)
  let t60a2 = clip_i(t63 - t60, min, max)
  let t61x = clip_i(t62a2 - t61a2, min, max)
  let t62x = clip_i(t62a2 + t61a2, min, max)
  let t63a2 = clip_i(t63 + t60, min, max)
  let t34a3 = ((t34x * (4096 - 4017) + t61x * 799 + 2048) >> 12) - t34x
  let t35x = ((t35a2 * (4096 - 4017) + t60a2 * 799 + 2048) >> 12) - t35a2
  let t36x = ((t36a2 * -799 + t59a2 * (4096 - 4017) + 2048) >> 12) - t59a2
  let t37a3 = ((t37x * -799 + t58x * (4096 - 4017) + 2048) >> 12) - t58x
  let t42a3 = (t42x * -1138 + t53x * 1703 + 1024) >> 11
  let t43x2 = (t43a2 * -1138 + t52a2 * 1703 + 1024) >> 11
  let t44x2 = (t44a2 * -1703 + t51a2 * -1138 + 1024) >> 11
  let t45a3 = (t45x * -1703 + t50x * -1138 + 1024) >> 11
  let t50a3 = (t45x * -1138 + t50x * 1703 + 1024) >> 11
  let t51x2 = (t44a2 * -1138 + t51a2 * 1703 + 1024) >> 11
  let t52x2 = (t43a2 * 1703 + t52a2 * 1138 + 1024) >> 11
  let t53a3 = (t42x * 1703 + t53x * 1138 + 1024) >> 11
  let t58a3 = ((t37x * (4096 - 4017) + t58x * 799 + 2048) >> 12) - t37x
  let t59x2 = ((t36a2 * (4096 - 4017) + t59a2 * 799 + 2048) >> 12) - t36a2
  let t60x2 = ((t35a2 * 799 + t60a2 * (4017 - 4096) + 2048) >> 12) + t60a2
  let t61a3 = ((t34x * 799 + t61x * (4017 - 4096) + 2048) >> 12) + t61x
  let t32x = clip_i(t32a2 + t39a2, min, max)
  let t33a3 = clip_i(t33x + t38x, min, max)
  let t34x3 = clip_i(t34a3 + t37a3, min, max)
  let t35a3 = clip_i(t35x + t36x, min, max)
  let t36a3 = clip_i(t35x - t36x, min, max)
  let t37x2 = clip_i(t34a3 - t37a3, min, max)
  let t38a3 = clip_i(t33x - t38x, min, max)
  let t39x2 = clip_i(t32a2 - t39a2, min, max)
  let t40x2 = clip_i(t47a2 - t40a2, min, max)
  let t41a3 = clip_i(t46x - t41x, min, max)
  let t42x3 = clip_i(t45a3 - t42a3, min, max)
  let t43a3x = clip_i(t44x2 - t43x2, min, max)
  let t44a3 = clip_i(t44x2 + t43x2, min, max)
  let t45x3 = clip_i(t45a3 + t42a3, min, max)
  let t46a3 = clip_i(t46x + t41x, min, max)
  let t47x2 = clip_i(t47a2 + t40a2, min, max)
  let t48x2 = clip_i(t48a2 + t55a2, min, max)
  let t49a3 = clip_i(t49x + t54x, min, max)
  let t50x3 = clip_i(t50a3 + t53a3, min, max)
  let t51a3 = clip_i(t51x2 + t52x2, min, max)
  let t52a3 = clip_i(t51x2 - t52x2, min, max)
  let t53x3 = clip_i(t50a3 - t53a3, min, max)
  let t54a3 = clip_i(t49x - t54x, min, max)
  let t55x2 = clip_i(t48a2 - t55a2, min, max)
  let t56x2 = clip_i(t63a2 - t56a2, min, max)
  let t57a3x = clip_i(t62x - t57x, min, max)
  let t58x3 = clip_i(t61a3 - t58a3, min, max)
  let t59a3 = clip_i(t60x2 - t59x2, min, max)
  let t60a3 = clip_i(t60x2 + t59x2, min, max)
  let t61x3 = clip_i(t61a3 + t58a3, min, max)
  let t62a3 = clip_i(t62x + t57x, min, max)
  let t63x2 = clip_i(t63a2 + t56a2, min, max)
  let t36x3 = ((t36a3 * (4096 - 3784) + t59a3 * 1567 + 2048) >> 12) - t36a3
  let t37a4 = ((t37x2 * (4096 - 3784) + t58x3 * 1567 + 2048) >> 12) - t37x2
  let t38x4 = ((t38a3 * (4096 - 3784) + t57a3x * 1567 + 2048) >> 12) - t38a3
  let t39a4 = ((t39x2 * (4096 - 3784) + t56x2 * 1567 + 2048) >> 12) - t39x2
  let t40a4 = ((t40x2 * -1567 + t55x2 * (4096 - 3784) + 2048) >> 12) - t55x2
  let t41x4 = ((t41a3 * -1567 + t54a3 * (4096 - 3784) + 2048) >> 12) - t54a3
  let t42a4 = ((t42x3 * -1567 + t53x3 * (4096 - 3784) + 2048) >> 12) - t53x3
  let t43x4 = ((t43a3x * -1567 + t52a3 * (4096 - 3784) + 2048) >> 12) - t52a3
  let t52x4 = ((t43a3x * (4096 - 3784) + t52a3 * 1567 + 2048) >> 12) - t43a3x
  let t53a4 = ((t42x3 * (4096 - 3784) + t53x3 * 1567 + 2048) >> 12) - t42x3
  let t54x4 = ((t41a3 * (4096 - 3784) + t54a3 * 1567 + 2048) >> 12) - t41a3
  let t55a4 = ((t40x2 * (4096 - 3784) + t55x2 * 1567 + 2048) >> 12) - t40x2
  let t56a4 = ((t39x2 * 1567 + t56x2 * (3784 - 4096) + 2048) >> 12) + t56x2
  let t57x4 = ((t38a3 * 1567 + t57a3x * (3784 - 4096) + 2048) >> 12) + t57a3x
  let t58a4 = ((t37x2 * 1567 + t58x3 * (3784 - 4096) + 2048) >> 12) + t58x3
  let t59x4 = ((t36a3 * 1567 + t59a3 * (3784 - 4096) + 2048) >> 12) + t59a3
  let t32a3 = clip_i(t32x + t47x2, min, max)
  let t33x4 = clip_i(t33a3 + t46a3, min, max)
  let t34a4x = clip_i(t34x3 + t45x3, min, max)
  let t35x4 = clip_i(t35a3 + t44a3, min, max)
  let t36a4 = clip_i(t36x3 + t43x4, min, max)
  let t37x5 = clip_i(t37a4 + t42a4, min, max)
  let t38a5 = clip_i(t38x4 + t41x4, min, max)
  let t39x5 = clip_i(t39a4 + t40a4, min, max)
  let t40x5 = clip_i(t39a4 - t40a4, min, max)
  let t41a5 = clip_i(t38x4 - t41x4, min, max)
  let t42x5 = clip_i(t37a4 - t42a4, min, max)
  let t43a5 = clip_i(t36x3 - t43x4, min, max)
  let t44x5 = clip_i(t35a3 - t44a3, min, max)
  let t45a5 = clip_i(t34x3 - t45x3, min, max)
  let t46x5 = clip_i(t33a3 - t46a3, min, max)
  let t47a5 = clip_i(t32x - t47x2, min, max)
  let t48a5 = clip_i(t63x2 - t48x2, min, max)
  let t49x5 = clip_i(t62a3 - t49a3, min, max)
  let t50a5 = clip_i(t61x3 - t50x3, min, max)
  let t51x5 = clip_i(t60a3 - t51a3, min, max)
  let t52a5 = clip_i(t59x4 - t52x4, min, max)
  let t53x5 = clip_i(t58a4 - t53a4, min, max)
  let t54a5 = clip_i(t57x4 - t54x4, min, max)
  let t55x5 = clip_i(t56a4 - t55a4, min, max)
  let t56x5 = clip_i(t56a4 + t55a4, min, max)
  let t57a5 = clip_i(t57x4 + t54x4, min, max)
  let t58x5 = clip_i(t58a4 + t53a4, min, max)
  let t59a5 = clip_i(t59x4 + t52x4, min, max)
  let t60x5 = clip_i(t60a3 + t51a3, min, max)
  let t61a5 = clip_i(t61x3 + t50x3, min, max)
  let t62x5 = clip_i(t62a3 + t49a3, min, max)
  let t63a5 = clip_i(t63x2 + t48x2, min, max)
  let t40a5 = ((t55x5 - t40x5) * 181 + 128) >> 8
  let t41x6 = ((t54a5 - t41a5) * 181 + 128) >> 8
  let t42a6 = ((t53x5 - t42x5) * 181 + 128) >> 8
  let t43x6 = ((t52a5 - t43a5) * 181 + 128) >> 8
  let t44a6 = ((t51x5 - t44x5) * 181 + 128) >> 8
  let t45x6 = ((t50a5 - t45a5) * 181 + 128) >> 8
  let t46a6 = ((t49x5 - t46x5) * 181 + 128) >> 8
  let t47x6 = ((t48a5 - t47a5) * 181 + 128) >> 8
  let t48x6 = ((t47a5 + t48a5) * 181 + 128) >> 8
  let t49a6 = ((t46x5 + t49x5) * 181 + 128) >> 8
  let t50x6 = ((t45a5 + t50a5) * 181 + 128) >> 8
  let t51a6 = ((t44x5 + t51x5) * 181 + 128) >> 8
  let t52x6 = ((t43a5 + t52a5) * 181 + 128) >> 8
  let t53a6 = ((t42x5 + t53x5) * 181 + 128) >> 8
  let t54x6 = ((t41a5 + t54a5) * 181 + 128) >> 8
  let t55a6 = ((t40x5 + t55x5) * 181 + 128) >> 8
  let t = FixedArray::make(64, 0)
  for i in 0..<32 {
    t[i] = c[base + 2 * i * stride]
  }
  t[32] = t32a3
  t[33] = t33x4
  t[34] = t34a4x
  t[35] = t35x4
  t[36] = t36a4
  t[37] = t37x5
  t[38] = t38a5
  t[39] = t39x5
  t[40] = t40a5
  t[41] = t41x6
  t[42] = t42a6
  t[43] = t43x6
  t[44] = t44a6
  t[45] = t45x6
  t[46] = t46a6
  t[47] = t47x6
  t[48] = t48x6
  t[49] = t49a6
  t[50] = t50x6
  t[51] = t51a6
  t[52] = t52x6
  t[53] = t53a6
  t[54] = t54x6
  t[55] = t55a6
  t[56] = t56x5
  t[57] = t57a5
  t[58] = t58x5
  t[59] = t59a5
  t[60] = t60x5
  t[61] = t61a5
  t[62] = t62x5
  t[63] = t63a5
  for i in 0..<64 {
    c[base + i * stride] = clip_i(t[i], min, max)
  }
}

///|
/// `dav1d_tx1d_types` from itx_1d.c: [TxfmType][2] → Tx1dType pairs
/// (DCT=0, ADST=1, FLIPADST=2, IDENTITY=3).
let av1_tx1d_types : FixedArray[Byte] = [
  0, 0, // DCT_DCT
  1, 0, // ADST_DCT
  0, 1, // DCT_ADST
  1, 1, // ADST_ADST
  2, 0, // FLIPADST_DCT
  0, 2, // DCT_FLIPADST
  2, 2, // FLIPADST_FLIPADST
  1, 2, // ADST_FLIPADST
  2, 1, // FLIPADST_ADST
  3, 3, // IDTX
  0, 3, // V_DCT
  3, 0, // H_DCT
  1, 3, // V_ADST
  3, 1, // H_ADST
  2, 3, // V_FLIPADST
  3, 2, // H_FLIPADST
  0, 0, // WHT_WHT (unused)
]

///|
/// TxfmInfo field accessor: index into the flat
/// `av1_txfm_dimensions` dump (8 u8 fields per RectTxfmSize).
/// Fields: w, h, lw, lh, min, max, sub, ctx.
fn av1_txfm_info(tx : Int, field : Int) -> Int {
  av1_txfm_dimensions[tx * 8 + field].to_int()
}

///|
/// `dav1d_last_nonzero_col_from_eob[tx][eob]` lookup (tx has its own
/// array in the generated tables).
fn av1_lnz(tx : Int, eob : Int) -> Int {
  match tx {
    0 => av1_lnz_0[eob].to_int()
    1 => av1_lnz_1[eob].to_int()
    2 => av1_lnz_2[eob].to_int()
    3 => av1_lnz_3[eob].to_int()
    4 => av1_lnz_4[eob].to_int()
    5 => av1_lnz_5[eob].to_int()
    6 => av1_lnz_6[eob].to_int()
    7 => av1_lnz_7[eob].to_int()
    8 => av1_lnz_8[eob].to_int()
    9 => av1_lnz_9[eob].to_int()
    10 => av1_lnz_10[eob].to_int()
    11 => av1_lnz_11[eob].to_int()
    12 => av1_lnz_12[eob].to_int()
    13 => av1_lnz_13[eob].to_int()
    14 => av1_lnz_14[eob].to_int()
    15 => av1_lnz_15[eob].to_int()
    16 => av1_lnz_16[eob].to_int()
    17 => av1_lnz_17[eob].to_int()
    _ => av1_lnz_18[eob].to_int()
  }
}

///|
/// `dav1d_scans[tx][i]` lookup into the per-tx generated arrays.
fn av1_scan(tx : Int, i : Int) -> Int {
  match tx {
    0 => av1_scan_0[i].to_int()
    1 => av1_scan_1[i].to_int()
    2 => av1_scan_2[i].to_int()
    3 => av1_scan_3[i].to_int()
    4 => av1_scan_4[i].to_int()
    5 => av1_scan_5[i].to_int()
    6 => av1_scan_6[i].to_int()
    7 => av1_scan_7[i].to_int()
    8 => av1_scan_8[i].to_int()
    9 => av1_scan_9[i].to_int()
    10 => av1_scan_10[i].to_int()
    11 => av1_scan_11[i].to_int()
    12 => av1_scan_12[i].to_int()
    13 => av1_scan_13[i].to_int()
    14 => av1_scan_14[i].to_int()
    15 => av1_scan_15[i].to_int()
    16 => av1_scan_16[i].to_int()
    17 => av1_scan_17[i].to_int()
    _ => av1_scan_18[i].to_int()
  }
}
