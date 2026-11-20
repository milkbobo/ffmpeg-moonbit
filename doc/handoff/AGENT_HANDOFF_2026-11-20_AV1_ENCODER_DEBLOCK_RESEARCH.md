# AV1 编码器侧去块滤波 —— 调研与探测交接（§468 预备，未实现）

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§467（CLI 扩展，已提交 214a591）

## 结论摘要

本片**只做调研与探测，未改代码**。目标是评估编码器侧去块滤波
（让 expected 重建 = 解码器滤波后输出）。结论：**底层滤波核可复用，
但编码器侧需要新写 intra 的 mask 构造 + 帧级循环，是一项 1.5–2 会话
的工程**，不适合单会话硬推。

## 已确认的事实（都已核对源码/实测）

### 1. 底层滤波核完全可复用，不依赖 Av1FrameCtx

- `av1_lf_filter`（`av1_lf.mbt:756`，私有但**同包可用**）：单个 4 行/列
  边界的滤波核，只吃 `dst/off/strides/wd/bpc/e/i/h`。
- `av1_lf_h_y` / `av1_lf_v_y` / `av1_lf_h_uv` / `av1_lf_v_uv`
  （:1078 / :1127 / :1179 / :1221）：同样只吃 planes/stride/mask/lvl/lut。
- `av1_lf_filter_kernel`（:1680）是**公开**的薄包装。
- `av1_calc_eih`（:72，私有同包可用）构造 `Av1FilterLut`；
  `av1_calc_lf_values`（:120）算每段的 level。

**即：帧级循环之外的零件都在同包内可用。**

### 2. 真正绑 Av1FrameCtx 的是 mask 构造与帧循环

- `create_lf_mask_intra`（:391）是 `Av1FrameCtx` 的方法，用
  `self.w4/h4/b4_stride/lf_level` 四个字段 + `lf_level` 数组。
- `lf_sbrow_cols` / `lf_sbrow_rows`（:1466 / :1619）与
  `loop_filter_frame`（:1666）都是 FrameCtx 方法。
- `Av1FrameCtx`（`av1_decode.mbt:99`）有 30+ 字段，构造它需要大量
  解码器状态，**不可行**。

### 3. 公开的 mask 入口只有 inter 版，不能直接用于 key 帧

- `av1_create_lf_mask_inter`（:664）是**公开**且完全参数化的。
- 但 intra 块的 bS 推导与 inter 不同（intra 边界恒为强滤波），
  所以 **key 帧必须用 intra 版的 mask 构造**，而那是私有方法。
- 结论：编码器要支持 key 帧去块，需**新写一份 intra mask 构造**
  （复刻 `av1_mask_edges_intra` 的调用序列，见 :425-487）。

### 4. 实测：编码器当前完全没把 loop_filter 传给解码器

写探针（已清理）编码同一 64×64 块状内容两次——一次 lf=0、一次
lf=32——**解码输出完全相同（differing pixels = 0）**。

根因：`Av1Encoder::encode_frame` 的 key 帧路径用
`Av1KeyFrameEncConfig::default()`，其中 `loop_filter_level0/1 = 0`
（`av1_encoder.mbt:166`）。session 层**根本没有暴露 loop_filter 参数**。

这是编码器侧去块的第一环（小改动），但也说明整条链路从未打通。

### 5. 解码器不暴露未滤波的中间结果

解码在 `decode_keyframe_tiles` 内部完成滤波
（`av1_decode6.mbt:522-524`），外部拿到的永远是滤波后的帧。
**没有「未滤波」oracle 可用来做增量验证。**

## 实现路径（下个会话）

### 第一环（小，可独立提交）：session 暴露 loop_filter 参数

给 `Av1Encoder::encode_frame` 增 `loop_filter_level0?` /
`loop_filter_level1?` / `loop_filter_sharpness?`，透传到
`Av1KeyFrameEncConfig` 与 `Av1InterFrameEncConfig`。

验收：探针显示「lf=0 vs lf=32 解码输出不同」——证明参数真的到达解码器。
**这一步不改重建，expected 会与解码器不一致**，所以必须同时做第二环
才能让现有「逐像素精确」测试继续通过（或把这几个测试改成 lf=0 路径）。

### 第二环（大，核心工程）：编码器重建后做同样的滤波

需要：

1. 新写 intra 的 lf_mask 构造（复刻 `av1_mask_edges_intra` 调用，
   参数取自我们固定的 4×32×32 分区 + TX_32X32 + skip=0）；
2. 填 `lf_level`（每 4x4 槽 4 个 level：v/h/u/v，来自
   `av1_calc_lf_values` + 帧头的 4 个 level + sharpness）；
3. 构造 `Av1FilterLut`（`av1_calc_eih`）；
4. 帧级循环：对每个 SB 行先 `cols` 后 `rows`，内部调
   `av1_lf_plane_cols_y/rows_y/cols_uv/rows_uv` 的等价实现
   （这些绑 FrameCtx，需重写或泛化）；
5. expected 平面 = 滤波后的重建。

**关键风险**：第 4 步的 `cols` 还要处理 tile 边界强度修正
（`lf_sbrow_cols` 里 `tile_cols > 1` 的分支）——我们目前是单 tile
或按 SB 分 tile，需确认走哪条路径。

### 验证策略

没有增量 oracle，只能用「端到端」：编码带 lf 的流 → 解码 →
断言 `decode == expected`。这要求第二环的实现与解码器**逐位一致**，
任何 mask/level 偏差都会立即暴露为像素差异。建议先用**单一 lf level
+ 单 tile + 64×64** 的最小配置起步。

## 交接给下个会话

本片**无代码改动、无提交**。探针已清理。建议按第一环 → 第二环推进；
第二环务必先写一个「64×64 单 tile + 固定 lf level」的 wbtest 把
mask/level 构造钉死，再扩到多 SB 与多 tile。
