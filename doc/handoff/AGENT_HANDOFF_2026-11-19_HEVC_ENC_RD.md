# HEVC 编码器 P 片 RD 选模 / I+inter 混合编码（2026-11-19）

接续 [§450 分数像素 ME](AGENT_HANDOFF_2026-11-19_HEVC_ENC_FRACME.md)，本切片在 P 片
加入 intra 候选与率失真选模。纯 MoonBit/wasm；条目见
`doc/PORTING_HISTORY.md` §451。公开 API 不变。

## 实现

- `hevc_enc_inter.mbt`：
  - `hevc_enc_intra_eval`：无副作用的 35 模式 luma intra 搜索（scratch 画面），
    返回最佳模式与带非 MPM regulariser 的 SAD；不写 bin、不写 `tab_ipm`。
  - `hevc_enc_mvf_intra`：intra CU 的 `tab_mvf` 写 `PF_INTRA`，防止陈旧 MV
    泄漏到后续 merge 候选与去块强度。
  - `hevc_enc_coding_unit_inter`：提交前用 `distortion + lambda * bit_hint`
    比较 inter 与 intra（lambda = `1 << (qp/6)`；inter 2/8 bit，intra 10 bit）。
    决策确定、无浮点、解码器无关；bit_hint 是粗粒度 bin 数估计，不是精确
    码率模型——属于启发式 RD。
  - intra 胜出时写 `skip_flag=0` + `pred_mode_flag=1`，然后复用 I 帧的
    `hevc_enc_coding_unit` 体（与 §448 逐 bin 同源）。
- **关键约束**：两候选都写 `ctx.pic`，因此必须都在 scratch 上评价，只对
  胜者提交一次预测+残差。

## 验证

- 白盒（hevc_enc_p_wbtest.mbt，11/11）：新增「intra-favoured 新内容」（第二帧
  与第一帧无关，触发 intra CU）与「三帧 inter/intra 交替」（验证状态与邻域表
  跨帧不泄漏）。HEVC 编码器白盒合计 33/33。
- 黑盒（hevc_enc_p_test.mbt，新增 1 例）：含 intra CU 的 P 片码流经 FFmpeg
  9.0.2 零告警解码，两帧 framemd5 钉值
  `2c22b1c1db90c212edc036dfff2cb2ff` / `a36cb10d0d9d443b8015a33253cd99d7`
  与自家解码器逐字节一致；黑盒合计 3/3。
- 行为实测：平移帧 P=584B vs I=1054B（inter 生效），突发新内容帧 P=1639B
  （intra 生效，含额外 pred_mode 开销但重建更优）。
- `moon check --target wasm --deny-warn --no-render` 零警告；改动文件
  `moonfmt` 且幂等。

## 边界与后续

当前是启发式 RD（粗粒度 bit_hint、CU 级决策、无 sub-CU 拆分、无真正熵码率
估计），未做 B 片、SAO/去块开启、Main10/422/444、码控与流式 CLI。下一步建议：
精确码率模型 → sub-CU 层级决策 → B 片 → 高位深/高色度 → 码控 → 流式/CLI。
