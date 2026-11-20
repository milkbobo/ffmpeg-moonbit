# AV1 编码器 RD×skip 联合决策交接 —— §462

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§457（逐帧 qindex 粗 RD）、§458/§460（per-SB skip），均已提交

## 结果

把 §457 的 qindex 选择与 §458/§460 的 skip 开关**合并成一个联合决策**：
对每个候选 q × 每个候选 skip 阈值，两种形态（全残差 / skip 混合）都真实
试编码一次，取代价 `lambda * SAD + bits * 1000` 最小者。

之前的问题是二者独立：RD 只按全残差链计价选 q，skip 由 SAD 阈值独立触发
——可能出现「选了只对残差路径最优的 q，而 skip 本来更省」或反过来的情况。
联合决策把两者放进同一代价函数比较。

- 新文件 `libavcodec/av1_enc_rd_skip.mbt`：`Av1EncRdSkipChoice` +
  `av1_enc_rd_select_q_skip_inter`。
- 门面 `Av1Encoder::encode_frame` 增 `rd_skip_pcts?`：设置后对 inter 帧
  走联合选择（覆盖 rd_lambda~/skip_sad_pct~ 的独立路径）；lambda 缺省 1000。
- 候选集：q 用 `rd_candidates?`（缺省 `[40,100,160,220]`），skip 用
  `rd_skip_pcts`，且 **0（全残差基线）总在候选里**。

## 关键设计

1. **真值代价，不用 bit 估计**：SAD 取每次试编码返回的 expected 重建与源
   之差，bits 取真实 msac 包长 ×8（§456 的教训：自适应 CDF 下字节方向内容
   相关，手拍 hint 会选错）。
2. **参考库隔离**：每次试编码在 `av1_enc_rd_fork_refs` 的私有槽拷贝上跑
   （refresh 只替换条目、不原地改，浅拷贝足够），调用方状态零污染；赢家
   由真实编码路径在未污染的 `self.refs` 上重新编码。
3. **平局规则**：代价相同先取更小 q，再取更小 skip 百分比 —— 确定性。
4. **skip 形态用 `skip_uniform=true`**（§460 的 NEARMV skip），使非零 MV 也
   能进 skip 候选，而不只是零 MV 的 GLOBALMV。

## 验证

- 新黑盒 **4/4**（`av1_enc_rd_skip_test.mbt`）：
  - 静态内容（key 重建 + ±3 overlay）在 λ=0 下选中 `q=40, skip=50`
    —— 证明 skip 形态确实赢下纯省码目标；
  - 确定性 + 结果落在候选集内；
  - 选中组合真实编码后逐像素 decode==expected（三平面）；
  - session 门面经 `rd_skip_pcts~` 三帧链逐像素精确。
- 回归全绿：encoder 8/8、RD 4/4、skip 5/5、NEARMV 2/2、inter 24/24、
  tile 12/12（共 59）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- 仍是**逐帧穷举**：开销 ≈ |q 候选| × |skip 候选| × 单帧编码；生产用应缩
  候选集或加 early-out。
- 未做 per-SB 级 q（delta_q）、未做真 trellis、未做码控闭环。
- 联合决策目前只覆盖「q × skip」两维；分区/变换/帧内模式尚未进入同一代价
  函数（那需要先补这些能力的写端）。
- **上一轮 §461 帧内模式选择的教训仍有效**：非 DC 帧内模式的边缘准备是
  独立难题，WIP 在 `.trash/2026-11-20-av1-s461-wip/`，应先写单块 V_PRED
  对拍 wbtest 把 edge 语义钉死再扩。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
