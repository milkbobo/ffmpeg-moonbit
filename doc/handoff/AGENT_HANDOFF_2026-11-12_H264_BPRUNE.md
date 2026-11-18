# H.264 B 子分割候选剪枝

接续 BRC，本轮对 `b_parts` 的 16x8/8x16 两分割候选加**粗估排序 + top-3
精评**剪枝（§399）：每朝向的九种 list 组合先按「Σ 分区 SAD +
λ·20·mvd 对数」的粗估排序，仅粗估最优的三种组合过 `eval_b_parts` 的完整
评估（commit + compensate + 残差 + 双熵定价）。每 B 宏块的候选评估从
18 次两分割精评降到 6 次（整体候选数 24 → 12）。

机制：

- 粗估数据零额外搜索：`me_b_part` 返回的分区 SAD 供 L0/L1，Bi 的分区
  SAD 由 `b_bi_part_sad`（Bi 预测 = 两 ME 结果的 (a+b+1)>>1 平均）每
  分区一次；九组合的粗估 = 查表求和，廉价。
- 排序确定性：复合键 `(rough_cost * 16 + kind)` 的 Int64 选择排序——
  同价组合按 kind 升序，两次编码逐位一致（determinism 测试守门）。
- 粗估与精评的 lambda 口径一致（同一 `h264_rd_lambda`），Bi 的位惩罚
  按 mask 的 mvd 对数计。
- B_8x8 的逐组 13 sub 类型决策本就是线性择优（无组合爆炸），不动。

钉值影响：剪枝改变 `b_parts` 开启的输出流——ARBBPARTS / ARBBPARTSCABAC
两条 framemd5 已用 docker ffmpeg 重新零告警验证并重钉（其余 B 线钉值
ARBBINTRA / ARBBI4 / ARBBRC 不含两分割枚举，未变）。

验证：bparts 7/7（roundtrip 逐像素、流式逐字节、确定性、门控、重钉后的
两条 ffmpeg 仲裁）；全部既有编码器回归绿；CLI 10/10；docker x264 native
34/34、ffref 42/42；`moon check --target all` 0 错误。

B 线至此：b_slices（§393）→ B RD → B 子分割（§395）→ intra-in-B（§396）
→ I4x4-in-B（§397）→ B×VBV/ABR（§398）→ 剪枝（§399）。剩余：I8x8-in-B
（需 High 8x8DCT SPS/PPS 改造）、流式宿主分块读、x264 HRD 逐字段对拍。
