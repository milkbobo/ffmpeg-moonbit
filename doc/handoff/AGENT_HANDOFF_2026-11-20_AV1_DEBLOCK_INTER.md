# AV1 编码器 inter 帧去块交接 —— §468c

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§468b（intra 帧去块，已提交 13b984d）

## 结果

把 §468b 的编码器侧去块扩展到 **inter 帧**，至此编码器两种帧类型都
支持环路去块滤波。

- 新文件 `libavcodec/av1_enc_deblock_inter.mbt`：公开入口
  `av1_enc_deblock_frame_inter`。直接驱动**公开的**
  `av1_create_lf_mask_inter`（解码端已参数化），再跑与 §468b 相同的
  cols→rows 滤波循环（复用 `deblock_cols_y` / `deblock_rows_y` /
  `deblock_cols_uv` / `deblock_rows_uv`）。
- `av1_enc_write_me_res420_inter_frame_obu` 增
  `loop_filter_level0~` / `loop_filter_level1~` / `loop_filter_sharpness~`：
  写进 inter 帧头，并对 expected 三平面滤波（全 0 时跳过）。
- `Av1Encoder::encode_frame` 的 inter 路径透传这三个参数。

## 与 intra 版本的关键差异

| | intra key 帧（§468b） | inter 帧（§468c） |
|---|---|---|
| 分区 | 64x64 SB → 4×32x32 PARTITION_NONE | 64x64 SB **单块** |
| mask 构造 | `av1_mask_edges_intra`（私有，同包可用） | `av1_create_lf_mask_inter`（**公开**） |
| tx | 每块 TX_32X32 | var-tx SPLIT → 4×TX_32X32（`tx_masks=[1,0]`，`ytx=TX_64X64`） |
| skip | 恒 0 | 每 SB 一个 skip 标志 |

## 一个踩到的真 bug：`lvl` 与 `lf_level` 是两个不同的数组

第一版把 `av1_calc_lf_values` 算出的 4 项小数组 `lvl_y` 传给了
`av1_create_lf_mask_inter` 的 `lvl` 参数，直接数组越界崩溃
（`av1_lf.mbt:698` 的 `lvl[seg * 64 + 0 * 16]` 需要 ≥64 项）。

根因：该函数的两个参数用途不同——

- `lvl`：`av1_calc_lf_values` 输出的 **每段 × 4 方向** 的表
  （`seg*64 + dir*16` 布局，非分段时 64 项足够）；
- `lf_level`：**每 4x4 缓存项** 的 4 个 level（本函数会往里写）。

两者都应由 `av1_calc_lf_values(lf_level, hdr, ...)` 的**同一个数组**
提供（它同时承担这两个角色）。修正为 `av1_create_lf_mask_inter(lf_level,
lf_level, ...)` 后立即通过。

**教训：解码端函数里名字相近的两个参数（`lvl` / `lf_level`）可能是同一
份数据的不同视图，也可能是两份；看调用点比看名字可靠。**

## 验证

新白盒 **3/3**（`av1_enc_deblock_inter_wbtest.mbt`）：

1. **decode == expected**：key + inter 两帧序列，inter 帧 lf = 8 / 32 / 63
   三档强度下 `Y=0 UV=0`（逐像素完全一致）；
2. **滤波真的生效**：lf=0 vs lf=32 的 inter expected 相差
   **119 个 luma 像素**；
3. **默认不变**：不传参数与显式 `lf=0` 的 inter 码流**逐字节相同**。

回归全绿 **93 个测试**：encoder 8/8、refring 5/5、RD 三维 5/5、RD 4/4、
skip 5/5、NEARMV 2/2、RD×skip 4/4、multiref 4/4、ME 复用 4/4、
loop-filter 3/3、deblock-intra 3/3、deblock-inter 3/3、inter 24/24、
tile 12/12、frame 7/7。

`moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- **只覆盖「全残差」inter 路径**（`av1_enc_write_me_res420_inter_frame_obu`，
  所有 SB skip=0）。**skip 混合路径**
  （`av1_enc_write_me_skip420_inter_frame_obu`，§458/§460）尚未接
  loop_filter——那里的 `skips` 数组已存在，接入很直接：把
  `skip_flags` 传给 `av1_enc_deblock_frame_inter` 即可。
- 未处理 tile 边界强度修正（`tile_cols > 1` 的分支）；当前编码器
  按 SB 分 tile，多 tile 时需补。
- CDEF / LR 仍未做。
- 下一步建议：①把 skip 路径接上（小改动，立刻补齐 inter 全覆盖）；
  ②CDEF（解码端 `av1_cdef` 已有，可照 §468 的模式复用内核 + 自写驱动）。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
