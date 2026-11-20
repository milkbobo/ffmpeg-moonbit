# AV1 编码器侧去块滤波交接 —— §468b

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§468a（loop_filter 帧头打通，已提交 be8c1e9）

## 结果

**编码器侧去块滤波实现并接入**：key 帧重建后应用与解码器完全相同的
去块滤波，使 `expected` 平面 = 解码器滤波后的输出。这是 §468a 留的
第二环，现已闭环。

- 新文件 `libavcodec/av1_enc_deblock.mbt`：
  - 公开入口 `av1_enc_deblock_frame(...)`：在给定的三平面上就地滤波；
  - 自建 mask（复用同包私有的 `av1_mask_edges_intra` /
    `av1_mask_edges_chroma`）、lf_level（`av1_calc_lf_values`）、
    filter LUT（`av1_calc_eih`）；
  - 帧级循环复刻解码器的 cols→rows 顺序，复用底层核
    `av1_lf_h_y` / `av1_lf_v_y` / `av1_lf_h_uv` / `av1_lf_v_uv`。
- `Av1Encoder::encode_frame` 的 key 帧路径：帧头写出后解析回来取
  `hdr`，对 `expected_y/u/v` 滤波。**level 与 sharpness 全 0 时完全
  跳过**，保证默认行为零开销、零变化。

## 关键设计：为什么能保证与解码器一致

不重写滤波逻辑，而是**复用同一批内核**：

| 环节 | 复用的解码端函数 |
|---|---|
| mask 构造 | `av1_mask_edges_intra` / `av1_mask_edges_chroma`（同包私有） |
| level 计算 | `av1_calc_lf_values` |
| LUT | `av1_calc_eih` |
| 边界滤波 | `av1_lf_h_y` / `av1_lf_v_y` / `av1_lf_h_uv` / `av1_lf_v_uv` |

唯一新写的是**帧级 cols/rows 循环**（解码端那份绑 `Av1FrameCtx`），
以及 mask/level 的填充顺序。因为编码器的分区固定（单 tile、每个 64x64
SB 四个 32x32 PARTITION_NONE、TX_32X32、skip=0、4:2:0），可以省掉
解码端的 tile 边界修正与多 tile 记账。

## 一个踩到的真 bug：tx_lpf 银行的初值是 0 不是 −1

第一版把 `a_tx_y` / `l_tx_y` / `a_tx_uv` / `l_tx_uv` 初始化为 **−1**，
直接 `array element access out of bounds` 崩溃。

根因：解码端有**两个不同的 tx 银行**：

- `tx_intra`（`av1_decode.mbt:87` 的 `reset_keyframe` 设为 **−1**）——
  用于帧内模式/变换尺寸语法；
- `tx_lpf_y` / `tx_lpf_uv`（`av1_decode.mbt:64-67` 初始化为 **0**）——
  用于去块 mask 构造。

`av1_mask_edges_intra` 用的是后者。传 −1 后
`av1_imin(twl4c, -1) = -1` → `av1_fy_i(..., -1, ...)` 得到负索引 → 越界。

**教训：解码端同名概念可能有多份银行，初值不同；镜像前必须逐个确认
是哪一个。**

## 验证

新白盒 **3/3**（`av1_enc_deblock_wbtest.mbt`）：

1. **decode == expected**：lf = 8 / 32 / 63 三档强度下
   `Y=0 UV=0`（逐像素完全一致）；
2. **滤波真的生效**：同一内容 lf=0 vs lf=32 的 expected 平面相差
   **117 个 luma 像素**（排除「空跑」）；
3. **默认不变**：不传参数与显式 `lf=0` 的码流**逐字节相同**、expected
   平面逐像素相同。

回归全绿 **90 个测试**：encoder 8/8、refring 5/5、RD 三维 5/5、RD 4/4、
skip 5/5、NEARMV 2/2、RD×skip 4/4、multiref 4/4、ME 复用 4/4、
loop-filter 3/3、deblock 3/3、inter 24/24、tile 12/12、frame 7/7。

`moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- 只覆盖**编码器当前会产生的形态**：单 tile、intra key 帧、4:2:0、
  8-bit、64x64 SB + 4×32x32 分区、TX_32X32 luma / TX_16X16 chroma。
- **inter 帧未接**：`encode_frame` 的 inter 路径尚未调用滤波。inter 帧的
  mask 需要走 `av1_create_lf_mask_inter`（公开、参数化），且要按块传
  skip/ytx/uvtx，比 intra 多一层记账，建议作为下一片。
- 未处理 tile 边界强度修正（`lf_sbrow_cols` 里 `tile_cols > 1` 的分支）
  ——当前编码器只发单 tile 或按 SB 分 tile，后者需要补。
- CDEF / LR 仍未做。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
