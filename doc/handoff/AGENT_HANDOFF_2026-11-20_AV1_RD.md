# AV1 编码器 per-frame qindex 粗 RD 交接 —— §457

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§438a–§456（AV1 编码全部，工作树未提交）

## 结果

新增 **§457 per-frame qindex 粗码率失真（RD）选择**：在 inter 帧编码时，
对候选 `base_q_idx` 集合逐个试编码，用「真实解码重建的 SAD」与「msac
实际产出的包字节数」计算整数定点代价值，取最小者作为该帧的 qindex。
不新增任何语法——选中的 q 就是帧头既有的 `base_q_idx`，所有候选流由同一个
解码器解码，赢家天然逐像素 round-trip。

- 新文件：`libavcodec/av1_enc_rd.mbt`（选择器 + 参考库快照）、
  `libavcodec/av1_enc_rd_test.mbt`（黑盒 4 测）。
- 改动：`libavcodec/av1_encoder.mbt` 的 `encode_frame` 增两个可选参数
  `rd_lambda? : Int32` 与 `rd_candidates? : Array[Int32]`（默认不启用，
  既有调用零改动）。
- `pkg.generated.mbti` 经 `moon info` 重生成，公开 API 已含新函数。

## 设计决策

1. **代价 = `lambda * SAD + bits * 1000`**（整数定点，Int64 防溢出）：
   - `D = Σ|recon − src|` 取自试编码返回的 expected 平面（§449b 保证
     解码器逐像素实现它），不是估计值；
   - `bits = packet.length() * 8` 取自 msac 真实输出，不是启发式 bit hint——
     §456 已证明量化死区的字节方向在自适应 CDF 下是内容依赖的，手拍 hint
     会选错模式；
   - 权重 1000 = 每 SAD 单位相对 1/1000 bit；lambda=0 纯省码（选最粗 q），
     lambda→∞ 纯保真（选最细 q）。平局取小 qindex。
2. **候选集默认 `[40, 100, 160, 220]`**（`av1_enc_rd_default_q_candidates`），
   只给 `rd_lambda~` 时用默认梯；两者都不给则完全走旧路径（q 恒为
   `base_q_idx`），保证所有既有钉值不变。
3. **参考库隔离**：试编码会调 `refs.refresh(prepared, 1)` 改写 slot 0，
   因此每次试验前用 `av1_enc_rd_fork_refs` 对 `refs.slots` 做浅拷贝
   （refresh 只替换条目、不原地改条目 → 浅拷贝足够）。真实编码在未污染的
   `self.refs` 上再跑一遍，wynik 帧的参考链保持正确。
4. **只对 inter 帧生效**：key 帧路径完全未动。

## 验证

- 新黑盒 4/4（`moon test --target wasm libavcodec/av1_enc_rd_test.mbt`）：
  - 确定性 + 候选集约束：同输入两次选出同一 q，结果 ∈ 候选集；
  - lambda 单调端点：lambda=0 → q220（最粗）、lambda=1e6 → q40（最细）；
  - 参考库隔离：选择前后 slot 0 的 poc/coded_width/rp 状态不变；
  - session e2e：`rd_lambda~` 选出的 inter 帧经解码逐像素 == expected。
- 回归：`av1_encoder_test.mbt` 6/6（wasm）、`av1_enc_inter_test.mbt` 24/24
  （wasm-gc，v128 unused-package 警告是包级既有噪声，非本次引入）。
- `moon check --target wasm --deny-warn` 零警告；`moon fmt` 与 `moon info`
  已跑。

## 边界与下一步

- 这是**逐帧、候选集穷举**的粗 RD：每个候选都会完整试编码一次，开销
  ≈ 候选数 × 单帧编码成本；生产可用时应缩小候选集或做 early-out。
- 不做：per-SB/delta_q 自适应量化、量化器内真 RD/trellis、CABAC 级
  bit 代价、VBV/ABR、qmatrix/segmentation、hp 接线。
- 下一片候选：①per-SB skip/MV 模式决策（静止 SB 走 GLOBALMV skip，省
  token；tile 写端 `av1_enc_inter_skip_block` 已参数化 skip~，需同步
  a/l skip、tx、lcoef/ccoef 银行）；②RA/码控闭环；③CLI 多 inter 帧链。

## 交接给下个会话

§457 代码与测试**未提交**（与 §446–§456 同批留在工作树）。建议下个会话
先确认是否把 §446–§457 一并提交固化，再决定做 per-SB skip 决策还是码控。
