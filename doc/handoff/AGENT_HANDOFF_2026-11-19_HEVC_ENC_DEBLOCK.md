# HEVC 编码器去块滤波开启（2026-11-19）

接续 [§451 P 片 RD 选模](AGENT_HANDOFF_2026-11-19_HEVC_ENC_RD.md)，本切片打开
HEVC 环内滤波的第一级：去块滤波（DBF）。纯 MoonBit/wasm；条目见
`doc/PORTING_HISTORY.md` §452。公开 API 不变。

## 实现

### 语法侧：零新增 bin 的开启方式

编码器此前写 `pps_deblocking_filter_disabled_flag = 1`。现在置 0，并利用
`deblocking_filter_override_enabled_flag = 0` +
`seq_loop_filter_across_slices_enabled_flag = 0` 这两个前提，使**片头不新增
任何语法元素**，只在 PPS 补写 `pps_beta_offset_div2` / `pps_tc_offset_div2`
（均 0）。这是 HEVC 允许的最省位开启方式：码流长度不变（I 夹具仍 752B）。

### 镜像实现：共享 bS 推导

- 把解码器的 bS 推导从 `HevcIntraDecoder::deblocking_boundary_strengths`
  抽成自由函数 `hevc_bs_derive(...)`（位于 `hevc_inter_decode.mbt`），
  编解码器调用**同一份代码**——这是 recon == decode 的结构性保证。
- 编码器新增状态：`cbf_luma_tab`（按解码器规则标记每个 min-TB）、
  `vertical_bs` / `horizontal_bs`（尺寸 `(w>>2+1)*(h>>2+1)`）、`bs_width`。
- 在 TU 结束处推导 bS；帧末调用解码器的 `hevc_deblock_picture` 处理整幅重建。

### 顺序对齐（本切片最大的坑）

解码器顺序：`prediction_unit` 填 `tab_mvf` → `transform_unit` 里推 bS。
编码器最初在残差编码**之后**才填 mvf，导致 bS 读到陈旧的 `pred_flag == 0`
（`hevc_pf_intra`）把 inter 边界误判为 bS=2。修正为**先填 mvf 再推 bS**，
并补齐两条此前缺失的 bS 路径：

1. skip CU（无变换树）——补 `hevc_enc_fill_mvf` + `hevc_bs_derive`；
2. P 片 intra CU——补 `qp_y_tab` 填充（此前 intra 分支提前 `return`，
   去块会按错误 QP 取 beta/tc）。

## 验证

- 白盒改为**带滤波解码**（`ff_hevc_decode_intra_frame` /
  `ff_hevc_decode_frames_ex(..., apply_filters=true)`），与编码器重建在同一
  滤波域比较：I 9/9、P 11/11，HEVC 编码器白盒合计 33/33。
- 黑盒钉值全部重钉，并经 FFmpeg 9.0.2 仲裁（零告警，三方逐字节一致）：
  - I 两帧：`2ce4c26c6559cda49e446eaa7ce7da6b` / `4d62cabe9cfa99da49e837d6d350551a`
  - I+P 四帧：`3cd0cc018a300377c23c154eb8ce1ce5` / `08ef1f76ccaaad9a2364c3949efe09c2` /
    `21d88024934d81ef8ec833de8c27c48c` / `953904dce2339a8f405b8f7afaa893da`
  - intra-CU 两帧：`9de31269479cce2e8b46460db9926fba` / `c2705b19af387140b62b873458405e98`
- `moon check --target wasm --deny-warn --no-render` 零警告；改动文件
  `moonfmt` 且幂等。

## 边界与后续

只开了去块，SAO 仍关（SPS `sample_adaptive_offset_enabled_flag = 0`）。
未做 B 片、高位深/高色度、码控、流式 CLI。下一步建议：SAO（顺序必须在
去块之后）→ B 片 → Main10/422/444 → 码控 → 流式/CLI。
