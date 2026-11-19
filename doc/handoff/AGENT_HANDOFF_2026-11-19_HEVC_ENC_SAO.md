# HEVC 编码器 SAO 开启（2026-11-19）

接续 [§452 去块滤波](AGENT_HANDOFF_2026-11-19_HEVC_ENC_DEBLOCK.md)，本切片打开
HEVC 环内滤波的第二级：SAO（样点自适应偏移）。顺序严格按规范——去块之后。
纯 MoonBit/wasm；条目见 `doc/PORTING_HISTORY.md` §453。公开 API 不变。

## 实现

### 语法侧

- SPS `sample_adaptive_offset_enabled_flag` 置 1。
- 片头新增 `slice_sao_luma_flag = 1` / `slice_sao_chroma_flag = 0`，位置在
  short-term RPS **之后**、参考帧计数**之前**，与
  `ff_hevc_decode_slice_header` 完全一致（放错位置会报
  `alignment_bit_equal_to_one=0`）。
- 每个 CTB 在**编码四叉树之前**写 SAO 参数，对齐解码器 `hevc_sao_parse`
  的调用点。码流长度 752B → 773B。

### 真实决策（不是退化）

新增 `hevc_enc_sao.mbt`。对每个 CTB 的 luma：

1. 建 32-band 直方图，统计每带残差 `source − 去块重建` 的
   `sum(e)` / `sum|e|` / `count`；
2. 该带偏移 `o = clamp(round(mean(e)))`，上限 `(1<<(bd-5))-1`（8-bit 为 7）；
3. 用精确 SAD 增益 `sum|e| − sum|e − o|` 选出增益最大的**四个连续带**
   （band 模式，32 带环绕）；
4. 没有任何带获益 → 写 `sao_type_idx = 0`（该 CTB 关闭）。

实测：在人为 −3 偏置的重建上，4/4 CTB 全部选出 band 模式、偏移 +3，各 CTB
独立选择 band 位置——确实是失真补偿，不是全部退化关闭。

### 两遍编码（本切片的结构性难点）

SAO 参数必须在 CTB 数据**之前**写，但决策需要**去块后**的重建。因此 CTU
循环跑两遍：

- **pass 1**：全关 SAO（语法合法、参数数组尺寸正确）→ 得到去块重建；
- **决策**：读 pass 1 的重建算 SAO 参数；
- **pass 2**：带真实参数重编，重建含 SAO。

所有像素级决策确定且与 CABAC 状态无关，故 pass 2 重建除 SAO 本身外与 pass 1
完全一致。

### 镜像保证

编码器调用解码器的 `hevc_sao_apply`（**同一份滤波核**），
`filter_slice_edges` 全 1、`ctb_slice_idx` 全 0（单 slice）。新增 6 个 CABAC
写方法：`sao_merge_flag` / `sao_type_idx` / `sao_offset_abs` /
`sao_offset_sign` / `sao_band_position`（`sao_eo_class` 因未用 edge 模式而删）。

## 验证

- 白盒 I 10/10（新增 §453 永久测试：SPS 必须置位、决策必须产出非零 band
  偏移、应用后样本必须更接近源）、P 11/11；HEVC 编码器白盒合计 34/34。
- 黑盒 3/3，钉值全部重钉并经 FFmpeg 9.0.2 仲裁（零告警，三方逐字节一致）：
  - I 两帧：`41161203d03781c8a9b1f80e4b1b773c` / `d1eb62e3e53523b2eccb73ade254f992`
  - I+P 四帧：`5339917ee1981843254cc740e4d00157` / `5d67d379e920e467241e0219b3e020dc` /
    `8caabf3aeaa269c6fa3d10dce5a6b37d` / `14cd0ecf168b8310fd83e4f26c38b04b`
  - intra-CU 两帧：`a979107f1dc0c9579bbe3c2ec8a1bb18` / `ac475a20c09ffb1993a9a2905730e8df`
- `moon check --target wasm --deny-warn --no-render` 零警告；改动文件
  `moonfmt` 且幂等。

## 边界与后续

只做 **luma band 模式**。未实现：chroma SAO（由
`slice_sao_chroma_flag = 0` 干净关闭）、edge 模式（EO class）、SAO merge
（merge flag 恒写 0）。环内滤波到此完整（去块 + SAO）。

下一步建议：B 片 → Main10/4:2:2/4:4:4 → 码控（CRF/VBV）→ 流式/CLI。
