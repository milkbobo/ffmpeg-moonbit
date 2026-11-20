# AV1 编码器 q×skip×ref_age 三维联合决策交接 —— §465

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§462（q×skip 联合）、§464（session 参考环形缓冲），均已提交

## 结果

把 §462 的二维联合选择器扩成**三维**：同时对
**qindex × per-SB skip 阈值 × 参考帧年龄** 做真实试编码择优。

- 新文件 `libavcodec/av1_enc_rd_ref.mbt`：
  - `Av1EncRefCandidate`：一个候选参考（槽位 + 年龄 + 三平面）；
  - `Av1EncRdRefChoice`：赢家（q / skip_pct / ref_index / cost）；
  - `av1_enc_rd_select_q_skip_ref_inter`：遍历所有 (q, skip, ref) 组合。
- 门面 `Av1Encoder::encode_frame` 增 `rd_ref_ages? : Array[Int32]`：
  设置后对 inter 帧走三维选择，并**覆盖** rd_skip_pcts~/rd_lambda~/ref_age~。
  - q 候选来自 `rd_candidates?`（缺省 `[40,100,160,220]`）；
  - skip 候选来自 `rd_skip_pcts?`（缺省 `[50,100]`），0 恒在集内；
  - 参考候选由 `rd_ref_ages` 逐个解析到 §464 的槽环，无保留图的年龄跳过。

## 设计要点

1. **沿用 §462 的真值代价**：`lambda * SAD + bits * 1000`，SAD 取试编码
   返回的 expected 重建，bits 取真实 msac 包长 —— 不引入 bit 估计模型。
2. **参考隔离**：每次试验在 `av1_enc_rd_fork_refs` 的私有槽拷贝上跑，
   调用方 `self.refs` 零污染；赢家由真实编码路径在未污染状态上重编码。
3. **三维结果的复用**：三维选择已经把 q 和 skip 定下，因此把它包装成
   §462 的 `joint` 结果喂给后续分支，避免二次搜索（否则会重复编码）。
4. **平局规则**：代价相同 → 更小 q → 更小 skip 百分比 → 更早的候选
   （即更年轻的参考），保证确定性。
5. **候选参考的槽位随结果一起返回**，调用方直接用它做 `ref_slot`
   与 `refresh_slot`，无需二次查找。

## 验证

- 新黑盒 **5/5**（`av1_enc_rd_ref_test.mbt`）：
  - 6 帧链三维选择后逐像素 decode==expected；
  - **参考维度真生效**：只给 age0 与只给 age2 的码流不同
    （2301 vs 3059 字节）—— 防「年龄被忽略」；
  - **q 维度真生效**：q220-only 与 q40-only 码流不同（495 vs 3404 字节）；
  - 确定性（两次运行帧长序列恒等）；
  - 钉死候选（q=100/skip=0/age=0）时逐像素精确。
- 回归全绿：encoder 8/8、refring 5/5、RD 4/4、skip 5/5、NEARMV 2/2、
  RD×skip 4/4、multiref 4/4、inter 24/24、tile 12/12、frame 7/7（共 80）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- 三维穷举的开销 = |q| × |skip| × |ref| × 单帧编码，生产用必须缩候选集
  或加 early-out（例如先用整像素 SAD 粗筛参考，再对 top-1 做全搜索）。
- 仍是**单参考**（每帧只选一张参考图），没有复合预测。
- **分区树（固定 64×64）、变换尺寸/类型（只有 TX_32X32 DCT_DCT）、
  CDEF/LR 仍未做** —— 这几项是压缩率的最大杠杆，且分区树会牵动整个
  tile 写端与上下文银行体系，是下一个数量级的工程。
- **§461 帧内模式选择的教训仍有效**：WIP 在
  `.trash/2026-11-20-av1-s461-wip/`，重做前应先写单块 V_PRED 对拍 wbtest
  把 `av1_prepare_intra_edges` 的坐标/tile 边界/sb_has_tr-bl 语义钉死。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
