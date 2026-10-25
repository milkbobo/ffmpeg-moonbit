///|
/// `inv_dct64_1d_c` (mechanically transcribed from dav1d itx_1d.c).
fn av1_inv_dct64_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  av1_inv_dct32_1d_internal(c, base, stride << 1, min, max, true)
  let in1_1 = c[base + 1 * stride]
  let in3_1 = c[base + 3 * stride]
  let in5_1 = c[base + 5 * stride]
  let in7_1 = c[base + 7 * stride]
  let in9_1 = c[base + 9 * stride]
  let in11_1 = c[base + 11 * stride]
  let in13_1 = c[base + 13 * stride]
  let in15_1 = c[base + 15 * stride]
  let in17_1 = c[base + 17 * stride]
  let in19_1 = c[base + 19 * stride]
  let in21_1 = c[base + 21 * stride]
  let in23_1 = c[base + 23 * stride]
  let in25_1 = c[base + 25 * stride]
  let in27_1 = c[base + 27 * stride]
  let in29_1 = c[base + 29 * stride]
  let in31_1 = c[base + 31 * stride]
  let t32a_1 = (in1_1  *   101 + 2048) >> 12
  let t33a_1 = (in31_1 * -2824 + 2048) >> 12
  let t34a_1 = (in17_1 *  1660 + 2048) >> 12
  let t35a_1 = (in15_1 * -1474 + 2048) >> 12
  let t36a_1 = (in9_1  *   897 + 2048) >> 12
  let t37a_1 = (in23_1 * -2191 + 2048) >> 12
  let t38a_1 = (in25_1 *  2359 + 2048) >> 12
  let t39a_1 = (in7_1  *  -700 + 2048) >> 12
  let t40a_1 = (in5_1  *   501 + 2048) >> 12
  let t41a_1 = (in27_1 * -2520 + 2048) >> 12
  let t42a_1 = (in21_1 *  2019 + 2048) >> 12
  let t43a_1 = (in11_1 * -1092 + 2048) >> 12
  let t44a_1 = (in13_1 *  1285 + 2048) >> 12
  let t45a_1 = (in19_1 * -1842 + 2048) >> 12
  let t46a_1 = (in29_1 *  2675 + 2048) >> 12
  let t47a_1 = (in3_1  *  -301 + 2048) >> 12
  let t48a_1 = (in3_1  *  4085 + 2048) >> 12
  let t49a_1 = (in29_1 *  3102 + 2048) >> 12
  let t50a_1 = (in19_1 *  3659 + 2048) >> 12
  let t51a_1 = (in13_1 *  3889 + 2048) >> 12
  let t52a_1 = (in11_1 *  3948 + 2048) >> 12
  let t53a_1 = (in21_1 *  3564 + 2048) >> 12
  let t54a_1 = (in27_1 *  3229 + 2048) >> 12
  let t55a_1 = (in5_1  *  4065 + 2048) >> 12
  let t56a_1 = (in7_1  *  4036 + 2048) >> 12
  let t57a_1 = (in25_1 *  3349 + 2048) >> 12
  let t58a_1 = (in23_1 *  3461 + 2048) >> 12
  let t59a_1 = (in9_1  *  3996 + 2048) >> 12
  let t60a_1 = (in15_1 *  3822 + 2048) >> 12
  let t61a_1 = (in17_1 *  3745 + 2048) >> 12
  let t62a_1 = (in31_1 *  2967 + 2048) >> 12
  let t63a_1 = (in1_1  *  4095 + 2048) >> 12
  let t32_1 = clip_i(t32a_1 + t33a_1, min, max)
  let t33_1 = clip_i(t32a_1 - t33a_1, min, max)
  let t34_1 = clip_i(t35a_1 - t34a_1, min, max)
  let t35_1 = clip_i(t35a_1 + t34a_1, min, max)
  let t36_1 = clip_i(t36a_1 + t37a_1, min, max)
  let t37_1 = clip_i(t36a_1 - t37a_1, min, max)
  let t38_1 = clip_i(t39a_1 - t38a_1, min, max)
  let t39_1 = clip_i(t39a_1 + t38a_1, min, max)
  let t40_1 = clip_i(t40a_1 + t41a_1, min, max)
  let t41_1 = clip_i(t40a_1 - t41a_1, min, max)
  let t42_1 = clip_i(t43a_1 - t42a_1, min, max)
  let t43_1 = clip_i(t43a_1 + t42a_1, min, max)
  let t44_1 = clip_i(t44a_1 + t45a_1, min, max)
  let t45_1 = clip_i(t44a_1 - t45a_1, min, max)
  let t46_1 = clip_i(t47a_1 - t46a_1, min, max)
  let t47_1 = clip_i(t47a_1 + t46a_1, min, max)
  let t48_1 = clip_i(t48a_1 + t49a_1, min, max)
  let t49_1 = clip_i(t48a_1 - t49a_1, min, max)
  let t50_1 = clip_i(t51a_1 - t50a_1, min, max)
  let t51_1 = clip_i(t51a_1 + t50a_1, min, max)
  let t52_1 = clip_i(t52a_1 + t53a_1, min, max)
  let t53_1 = clip_i(t52a_1 - t53a_1, min, max)
  let t54_1 = clip_i(t55a_1 - t54a_1, min, max)
  let t55_1 = clip_i(t55a_1 + t54a_1, min, max)
  let t56_1 = clip_i(t56a_1 + t57a_1, min, max)
  let t57_1 = clip_i(t56a_1 - t57a_1, min, max)
  let t58_1 = clip_i(t59a_1 - t58a_1, min, max)
  let t59_1 = clip_i(t59a_1 + t58a_1, min, max)
  let t60_1 = clip_i(t60a_1 + t61a_1, min, max)
  let t61_1 = clip_i(t60a_1 - t61a_1, min, max)
  let t62_1 = clip_i(t63a_1 - t62a_1, min, max)
  let t63_1 = clip_i(t63a_1 + t62a_1, min, max)
  let t33a_2 = ((t33_1 * (4096 - 4076) + t62_1 *   401         + 2048) >> 12) - t33_1
  let t34a_2 = ((t34_1 *  -401         + t61_1 * (4096 - 4076) + 2048) >> 12) - t61_1
  let t37a_2 = (t37_1 * -1299         + t58_1 *  1583         + 1024) >> 11
  let t38a_2 = (t38_1 * -1583         + t57_1 * -1299         + 1024) >> 11
  let t41a_2 = ((t41_1 * (4096 - 3612) + t54_1 *  1931         + 2048) >> 12) - t41_1
  let t42a_2 = ((t42_1 * -1931         + t53_1 * (4096 - 3612) + 2048) >> 12) - t53_1
  let t45a_2 = ((t45_1 * -1189         + t50_1 * (3920 - 4096) + 2048) >> 12) + t50_1
  let t46a_2 = ((t46_1 * (4096 - 3920) + t49_1 * -1189         + 2048) >> 12) - t46_1
  let t49a_2 = ((t46_1 * -1189         + t49_1 * (3920 - 4096) + 2048) >> 12) + t49_1
  let t50a_2 = ((t45_1 * (3920 - 4096) + t50_1 *  1189         + 2048) >> 12) + t45_1
  let t53a_2 = ((t42_1 * (4096 - 3612) + t53_1 *  1931         + 2048) >> 12) - t42_1
  let t54a_2 = ((t41_1 *  1931         + t54_1 * (3612 - 4096) + 2048) >> 12) + t54_1
  let t57a_2 = (t38_1 * -1299         + t57_1 *  1583         + 1024) >> 11
  let t58a_2 = (t37_1 *  1583         + t58_1 *  1299         + 1024) >> 11
  let t61a_2 = ((t34_1 * (4096 - 4076) + t61_1 *   401         + 2048) >> 12) - t34_1
  let t62a_2 = ((t33_1 *   401         + t62_1 * (4076 - 4096) + 2048) >> 12) + t62_1
  let t32a_2 = clip_i(t32_1  + t35_1, min, max)
  let t33_2 = clip_i(t33a_2 + t34a_2, min, max)
  let t34_2 = clip_i(t33a_2 - t34a_2, min, max)
  let t35a_2 = clip_i(t32_1  - t35_1, min, max)
  let t36a_2 = clip_i(t39_1  - t36_1, min, max)
  let t37_2 = clip_i(t38a_2 - t37a_2, min, max)
  let t38_2 = clip_i(t38a_2 + t37a_2, min, max)
  let t39a_2 = clip_i(t39_1  + t36_1, min, max)
  let t40a_2 = clip_i(t40_1  + t43_1, min, max)
  let t41_2 = clip_i(t41a_2 + t42a_2, min, max)
  let t42_2 = clip_i(t41a_2 - t42a_2, min, max)
  let t43a_2 = clip_i(t40_1  - t43_1, min, max)
  let t44a_2 = clip_i(t47_1  - t44_1, min, max)
  let t45_2 = clip_i(t46a_2 - t45a_2, min, max)
  let t46_2 = clip_i(t46a_2 + t45a_2, min, max)
  let t47a_2 = clip_i(t47_1  + t44_1, min, max)
  let t48a_2 = clip_i(t48_1  + t51_1, min, max)
  let t49_2 = clip_i(t49a_2 + t50a_2, min, max)
  let t50_2 = clip_i(t49a_2 - t50a_2, min, max)
  let t51a_2 = clip_i(t48_1  - t51_1, min, max)
  let t52a_2 = clip_i(t55_1  - t52_1, min, max)
  let t53_2 = clip_i(t54a_2 - t53a_2, min, max)
  let t54_2 = clip_i(t54a_2 + t53a_2, min, max)
  let t55a_2 = clip_i(t55_1  + t52_1, min, max)
  let t56a_2 = clip_i(t56_1  + t59_1, min, max)
  let t57_2 = clip_i(t57a_2 + t58a_2, min, max)
  let t58_2 = clip_i(t57a_2 - t58a_2, min, max)
  let t59a_2 = clip_i(t56_1  - t59_1, min, max)
  let t60a_2 = clip_i(t63_1  - t60_1, min, max)
  let t61_2 = clip_i(t62a_2 - t61a_2, min, max)
  let t62_2 = clip_i(t62a_2 + t61a_2, min, max)
  let t63a_2 = clip_i(t63_1  + t60_1, min, max)
  let t34a_3 = ((t34_2  * (4096 - 4017) + t61_2  *   799         + 2048) >> 12) - t34_2
  let t35_2 = ((t35a_2 * (4096 - 4017) + t60a_2 *   799         + 2048) >> 12) - t35a_2
  let t36_2 = ((t36a_2 *  -799         + t59a_2 * (4096 - 4017) + 2048) >> 12) - t59a_2
  let t37a_3 = ((t37_2  *  -799         + t58_2  * (4096 - 4017) + 2048) >> 12) - t58_2
  let t42a_3 = (t42_2  * -1138         + t53_2  *  1703         + 1024) >> 11
  let t43_2 = (t43a_2 * -1138         + t52a_2 *  1703         + 1024) >> 11
  let t44_2 = (t44a_2 * -1703         + t51a_2 * -1138         + 1024) >> 11
  let t45a_3 = (t45_2  * -1703         + t50_2  * -1138         + 1024) >> 11
  let t50a_3 = (t45_2  * -1138         + t50_2  *  1703         + 1024) >> 11
  let t51_2 = (t44a_2 * -1138         + t51a_2 *  1703         + 1024) >> 11
  let t52_2 = (t43a_2 *  1703         + t52a_2 *  1138         + 1024) >> 11
  let t53a_3 = (t42_2  *  1703         + t53_2  *  1138         + 1024) >> 11
  let t58a_3 = ((t37_2  * (4096 - 4017) + t58_2  *   799         + 2048) >> 12) - t37_2
  let t59_2 = ((t36a_2 * (4096 - 4017) + t59a_2 *   799         + 2048) >> 12) - t36a_2
  let t60_2 = ((t35a_2 *   799         + t60a_2 * (4017 - 4096) + 2048) >> 12) + t60a_2
  let t61a_3 = ((t34_2  *   799         + t61_2  * (4017 - 4096) + 2048) >> 12) + t61_2
  let t32_2 = clip_i(t32a_2 + t39a_2, min, max)
  let t33a_3 = clip_i(t33_2  + t38_2, min, max)
  let t34_3 = clip_i(t34a_3 + t37a_3, min, max)
  let t35a_3 = clip_i(t35_2  + t36_2, min, max)
  let t36a_3 = clip_i(t35_2  - t36_2, min, max)
  let t37_3 = clip_i(t34a_3 - t37a_3, min, max)
  let t38a_3 = clip_i(t33_2  - t38_2, min, max)
  let t39_2 = clip_i(t32a_2 - t39a_2, min, max)
  let t40_2 = clip_i(t47a_2 - t40a_2, min, max)
  let t41a_3 = clip_i(t46_2  - t41_2, min, max)
  let t42_3 = clip_i(t45a_3 - t42a_3, min, max)
  let t43a_3 = clip_i(t44_2  - t43_2, min, max)
  let t44a_3 = clip_i(t44_2  + t43_2, min, max)
  let t45_3 = clip_i(t45a_3 + t42a_3, min, max)
  let t46a_3 = clip_i(t46_2  + t41_2, min, max)
  let t47_2 = clip_i(t47a_2 + t40a_2, min, max)
  let t48_2 = clip_i(t48a_2 + t55a_2, min, max)
  let t49a_3 = clip_i(t49_2  + t54_2, min, max)
  let t50_3 = clip_i(t50a_3 + t53a_3, min, max)
  let t51a_3 = clip_i(t51_2  + t52_2, min, max)
  let t52a_3 = clip_i(t51_2  - t52_2, min, max)
  let t53_3 = clip_i(t50a_3 - t53a_3, min, max)
  let t54a_3 = clip_i(t49_2  - t54_2, min, max)
  let t55_2 = clip_i(t48a_2 - t55a_2, min, max)
  let t56_2 = clip_i(t63a_2 - t56a_2, min, max)
  let t57a_3 = clip_i(t62_2  - t57_2, min, max)
  let t58_3 = clip_i(t61a_3 - t58a_3, min, max)
  let t59a_3 = clip_i(t60_2  - t59_2, min, max)
  let t60a_3 = clip_i(t60_2  + t59_2, min, max)
  let t61_3 = clip_i(t61a_3 + t58a_3, min, max)
  let t62a_3 = clip_i(t62_2  + t57_2, min, max)
  let t63_2 = clip_i(t63a_2 + t56a_2, min, max)
  let t36_3 = ((t36a_3 * (4096 - 3784) + t59a_3 *  1567         + 2048) >> 12) - t36a_3
  let t37a_4 = ((t37_3  * (4096 - 3784) + t58_3  *  1567         + 2048) >> 12) - t37_3
  let t38_3 = ((t38a_3 * (4096 - 3784) + t57a_3 *  1567         + 2048) >> 12) - t38a_3
  let t39a_3 = ((t39_2  * (4096 - 3784) + t56_2  *  1567         + 2048) >> 12) - t39_2
  let t40a_3 = ((t40_2  * -1567         + t55_2  * (4096 - 3784) + 2048) >> 12) - t55_2
  let t41_3 = ((t41a_3 * -1567         + t54a_3 * (4096 - 3784) + 2048) >> 12) - t54a_3
  let t42a_4 = ((t42_3  * -1567         + t53_3  * (4096 - 3784) + 2048) >> 12) - t53_3
  let t43_3 = ((t43a_3 * -1567         + t52a_3 * (4096 - 3784) + 2048) >> 12) - t52a_3
  let t52_3 = ((t43a_3 * (4096 - 3784) + t52a_3 *  1567         + 2048) >> 12) - t43a_3
  let t53a_4 = ((t42_3  * (4096 - 3784) + t53_3  *  1567         + 2048) >> 12) - t42_3
  let t54_3 = ((t41a_3 * (4096 - 3784) + t54a_3 *  1567         + 2048) >> 12) - t41a_3
  let t55a_3 = ((t40_2  * (4096 - 3784) + t55_2  *  1567         + 2048) >> 12) - t40_2
  let t56a_3 = ((t39_2  *  1567         + t56_2  * (3784 - 4096) + 2048) >> 12) + t56_2
  let t57_3 = ((t38a_3 *  1567         + t57a_3 * (3784 - 4096) + 2048) >> 12) + t57a_3
  let t58a_4 = ((t37_3  *  1567         + t58_3  * (3784 - 4096) + 2048) >> 12) + t58_3
  let t59_3 = ((t36a_3 *  1567         + t59a_3 * (3784 - 4096) + 2048) >> 12) + t59a_3
  let t32a_3 = clip_i(t32_2  + t47_2, min, max)
  let t33_3 = clip_i(t33a_3 + t46a_3, min, max)
  let t34a_4 = clip_i(t34_3  + t45_3, min, max)
  let t35_3 = clip_i(t35a_3 + t44a_3, min, max)
  let t36a_4 = clip_i(t36_3  + t43_3, min, max)
  let t37_4 = clip_i(t37a_4 + t42a_4, min, max)
  let t38a_4 = clip_i(t38_3  + t41_3, min, max)
  let t39_3 = clip_i(t39a_3 + t40a_3, min, max)
  let t40_3 = clip_i(t39a_3 - t40a_3, min, max)
  let t41a_4 = clip_i(t38_3  - t41_3, min, max)
  let t42_4 = clip_i(t37a_4 - t42a_4, min, max)
  let t43a_4 = clip_i(t36_3  - t43_3, min, max)
  let t44_3 = clip_i(t35a_3 - t44a_3, min, max)
  let t45a_4 = clip_i(t34_3  - t45_3, min, max)
  let t46_3 = clip_i(t33a_3 - t46a_3, min, max)
  let t47a_3 = clip_i(t32_2  - t47_2, min, max)
  let t48a_3 = clip_i(t63_2  - t48_2, min, max)
  let t49_3 = clip_i(t62a_3 - t49a_3, min, max)
  let t50a_4 = clip_i(t61_3  - t50_3, min, max)
  let t51_3 = clip_i(t60a_3 - t51a_3, min, max)
  let t52a_4 = clip_i(t59_3  - t52_3, min, max)
  let t53_4 = clip_i(t58a_4 - t53a_4, min, max)
  let t54a_4 = clip_i(t57_3  - t54_3, min, max)
  let t55_3 = clip_i(t56a_3 - t55a_3, min, max)
  let t56_3 = clip_i(t56a_3 + t55a_3, min, max)
  let t57a_4 = clip_i(t57_3  + t54_3, min, max)
  let t58_4 = clip_i(t58a_4 + t53a_4, min, max)
  let t59a_4 = clip_i(t59_3  + t52_3, min, max)
  let t60_3 = clip_i(t60a_3 + t51a_3, min, max)
  let t61a_4 = clip_i(t61_3  + t50_3, min, max)
  let t62_3 = clip_i(t62a_3 + t49a_3, min, max)
  let t63a_3 = clip_i(t63_2  + t48_2, min, max)
  let t40a_4 = ((t55_3  - t40_3 ) * 181 + 128) >> 8
  let t41_4 = ((t54a_4 - t41a_4) * 181 + 128) >> 8
  let t42a_5 = ((t53_4  - t42_4 ) * 181 + 128) >> 8
  let t43_4 = ((t52a_4 - t43a_4) * 181 + 128) >> 8
  let t44a_4 = ((t51_3  - t44_3 ) * 181 + 128) >> 8
  let t45_4 = ((t50a_4 - t45a_4) * 181 + 128) >> 8
  let t46a_4 = ((t49_3  - t46_3 ) * 181 + 128) >> 8
  let t47_3 = ((t48a_3 - t47a_3) * 181 + 128) >> 8
  let t48_3 = ((t47a_3 + t48a_3) * 181 + 128) >> 8
  let t49a_4 = ((t46_3  + t49_3 ) * 181 + 128) >> 8
  let t50_4 = ((t45a_4 + t50a_4) * 181 + 128) >> 8
  let t51a_4 = ((t44_3  + t51_3 ) * 181 + 128) >> 8
  let t52_4 = ((t43a_4 + t52a_4) * 181 + 128) >> 8
  let t53a_5 = ((t42_4  + t53_4 ) * 181 + 128) >> 8
  let t54_4 = ((t41a_4 + t54a_4) * 181 + 128) >> 8
  let t55a_4 = ((t40_3  + t55_3 ) * 181 + 128) >> 8
  let t0_1 = c[base + 0 * stride]
  let t1_1 = c[base + 2 * stride]
  let t2_1 = c[base + 4 * stride]
  let t3_1 = c[base + 6 * stride]
  let t4_1 = c[base + 8 * stride]
  let t5_1 = c[base + 10 * stride]
  let t6_1 = c[base + 12 * stride]
  let t7_1 = c[base + 14 * stride]
  let t8_1 = c[base + 16 * stride]
  let t9_1 = c[base + 18 * stride]
  let t10_1 = c[base + 20 * stride]
  let t11_1 = c[base + 22 * stride]
  let t12_1 = c[base + 24 * stride]
  let t13_1 = c[base + 26 * stride]
  let t14_1 = c[base + 28 * stride]
  let t15_1 = c[base + 30 * stride]
  let t16_1 = c[base + 32 * stride]
  let t17_1 = c[base + 34 * stride]
  let t18_1 = c[base + 36 * stride]
  let t19_1 = c[base + 38 * stride]
  let t20_1 = c[base + 40 * stride]
  let t21_1 = c[base + 42 * stride]
  let t22_1 = c[base + 44 * stride]
  let t23_1 = c[base + 46 * stride]
  let t24_1 = c[base + 48 * stride]
  let t25_1 = c[base + 50 * stride]
  let t26_1 = c[base + 52 * stride]
  let t27_1 = c[base + 54 * stride]
  let t28_1 = c[base + 56 * stride]
  let t29_1 = c[base + 58 * stride]
  let t30_1 = c[base + 60 * stride]
  let t31_1 = c[base + 62 * stride]
  c[base + 0 * stride] = clip_i(t0_1  + t63a_3, min, max)
  c[base + 1 * stride] = clip_i(t1_1  + t62_3, min, max)
  c[base + 2 * stride] = clip_i(t2_1  + t61a_4, min, max)
  c[base + 3 * stride] = clip_i(t3_1  + t60_3, min, max)
  c[base + 4 * stride] = clip_i(t4_1  + t59a_4, min, max)
  c[base + 5 * stride] = clip_i(t5_1  + t58_4, min, max)
  c[base + 6 * stride] = clip_i(t6_1  + t57a_4, min, max)
  c[base + 7 * stride] = clip_i(t7_1  + t56_3, min, max)
  c[base + 8 * stride] = clip_i(t8_1  + t55a_4, min, max)
  c[base + 9 * stride] = clip_i(t9_1  + t54_4, min, max)
  c[base + 10 * stride] = clip_i(t10_1 + t53a_5, min, max)
  c[base + 11 * stride] = clip_i(t11_1 + t52_4, min, max)
  c[base + 12 * stride] = clip_i(t12_1 + t51a_4, min, max)
  c[base + 13 * stride] = clip_i(t13_1 + t50_4, min, max)
  c[base + 14 * stride] = clip_i(t14_1 + t49a_4, min, max)
  c[base + 15 * stride] = clip_i(t15_1 + t48_3, min, max)
  c[base + 16 * stride] = clip_i(t16_1 + t47_3, min, max)
  c[base + 17 * stride] = clip_i(t17_1 + t46a_4, min, max)
  c[base + 18 * stride] = clip_i(t18_1 + t45_4, min, max)
  c[base + 19 * stride] = clip_i(t19_1 + t44a_4, min, max)
  c[base + 20 * stride] = clip_i(t20_1 + t43_4, min, max)
  c[base + 21 * stride] = clip_i(t21_1 + t42a_5, min, max)
  c[base + 22 * stride] = clip_i(t22_1 + t41_4, min, max)
  c[base + 23 * stride] = clip_i(t23_1 + t40a_4, min, max)
  c[base + 24 * stride] = clip_i(t24_1 + t39_3, min, max)
  c[base + 25 * stride] = clip_i(t25_1 + t38a_4, min, max)
  c[base + 26 * stride] = clip_i(t26_1 + t37_4, min, max)
  c[base + 27 * stride] = clip_i(t27_1 + t36a_4, min, max)
  c[base + 28 * stride] = clip_i(t28_1 + t35_3, min, max)
  c[base + 29 * stride] = clip_i(t29_1 + t34a_4, min, max)
  c[base + 30 * stride] = clip_i(t30_1 + t33_3, min, max)
  c[base + 31 * stride] = clip_i(t31_1 + t32a_3, min, max)
  c[base + 32 * stride] = clip_i(t31_1 - t32a_3, min, max)
  c[base + 33 * stride] = clip_i(t30_1 - t33_3, min, max)
  c[base + 34 * stride] = clip_i(t29_1 - t34a_4, min, max)
  c[base + 35 * stride] = clip_i(t28_1 - t35_3, min, max)
  c[base + 36 * stride] = clip_i(t27_1 - t36a_4, min, max)
  c[base + 37 * stride] = clip_i(t26_1 - t37_4, min, max)
  c[base + 38 * stride] = clip_i(t25_1 - t38a_4, min, max)
  c[base + 39 * stride] = clip_i(t24_1 - t39_3, min, max)
  c[base + 40 * stride] = clip_i(t23_1 - t40a_4, min, max)
  c[base + 41 * stride] = clip_i(t22_1 - t41_4, min, max)
  c[base + 42 * stride] = clip_i(t21_1 - t42a_5, min, max)
  c[base + 43 * stride] = clip_i(t20_1 - t43_4, min, max)
  c[base + 44 * stride] = clip_i(t19_1 - t44a_4, min, max)
  c[base + 45 * stride] = clip_i(t18_1 - t45_4, min, max)
  c[base + 46 * stride] = clip_i(t17_1 - t46a_4, min, max)
  c[base + 47 * stride] = clip_i(t16_1 - t47_3, min, max)
  c[base + 48 * stride] = clip_i(t15_1 - t48_3, min, max)
  c[base + 49 * stride] = clip_i(t14_1 - t49a_4, min, max)
  c[base + 50 * stride] = clip_i(t13_1 - t50_4, min, max)
  c[base + 51 * stride] = clip_i(t12_1 - t51a_4, min, max)
  c[base + 52 * stride] = clip_i(t11_1 - t52_4, min, max)
  c[base + 53 * stride] = clip_i(t10_1 - t53a_5, min, max)
  c[base + 54 * stride] = clip_i(t9_1  - t54_4, min, max)
  c[base + 55 * stride] = clip_i(t8_1  - t55a_4, min, max)
  c[base + 56 * stride] = clip_i(t7_1  - t56_3, min, max)
  c[base + 57 * stride] = clip_i(t6_1  - t57a_4, min, max)
  c[base + 58 * stride] = clip_i(t5_1  - t58_4, min, max)
  c[base + 59 * stride] = clip_i(t4_1  - t59a_4, min, max)
  c[base + 60 * stride] = clip_i(t3_1  - t60_3, min, max)
  c[base + 61 * stride] = clip_i(t2_1  - t61a_4, min, max)
  c[base + 62 * stride] = clip_i(t1_1  - t62_3, min, max)
  c[base + 63 * stride] = clip_i(t0_1  - t63a_3, min, max)
}

///|
/// `dav1d_tx1d_types` from itx_1d.c: [TxfmType][2] → Tx1dType pairs
/// (DCT=0, ADST=1, FLIPADST=2, IDENTITY=3).
let av1_tx1d_types : FixedArray[Byte] = [
  0, 0, // DCT_DCT
  0, 1, // ADST_DCT (dav1d DSP applies dct_adst here)
  1, 0, // DCT_ADST (dav1d DSP applies adst_dct here)
  1, 1, // ADST_ADST
  0, 2, // FLIPADST_DCT
  2, 0, // DCT_FLIPADST
  2, 2, // FLIPADST_FLIPADST
  2, 1, // ADST_FLIPADST
  1, 2, // FLIPADST_ADST
  3, 3, // IDTX
  3, 0, // V_DCT
  0, 3, // H_DCT
  3, 1, // V_ADST
  1, 3, // H_ADST
  3, 2, // V_FLIPADST
  2, 3, // H_FLIPADST
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
