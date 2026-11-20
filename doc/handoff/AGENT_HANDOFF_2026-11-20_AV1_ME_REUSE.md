# AV1 编码器 RD 搜索 ME 复用交接 —— §466

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§465（q×skip×ref_age 三维联合决策，已提交 17018cc）

## 结果

三维 RD 选择器原先对每个 `(q, skip, ref)` 组合都调一次完整的帧编码入口，
而那个入口内部会跑运动估计（±8 全搜索 + 子像素精化）。**ME 只依赖
`(src, ref)`，与 qindex 和 skip 阈值都无关** —— 所以同一参考下每个 q/skip
组合都在重复做完全相同的搜索。

本片把 ME 拆出来复用：

- 两个帧级入口（`av1_enc_write_me_res420_inter_frame_obu` 与
  `av1_enc_write_me_skip420_inter_frame_obu`）增可选参数
  `precomputed_mvs_y8?` / `precomputed_mvs_x8?`：传入时跳过 full-pel 搜索
  与子像素精化，直接用给定 MV；数组长度必须等于 SB 数，两个数组必须同时给。
- 新增 `av1_enc_me_for_ref`（`av1_enc_rd_ref.mbt`）：把「full-pel SAD +
  子像素精化」封装成一次调用。
- `av1_enc_rd_select_q_skip_ref_inter` 增 `me_cache`：每个参考**惰性算一次**
  ME，后续所有 `(q, skip)` 组合复用。

## 收益

以 4 个 q 候选 × 3 个 skip 候选（0/50/100）× 3 个参考候选为例：

- 优化前：36 次试编码 → **36 次 ME**（每次 ±8 全搜索 = 289 候选/SB，
  外加 5 + 8 个子像素候选）
- 优化后：**3 次 ME**（每参考一次）→ ME 调用下降 **12×**

（`skip_sad_pct=0` 的基线形态走 res 路径，其余走 skip 路径，两条路径
本片都接入了预计算 MV，所以覆盖全部组合。）

## 关键约束：字节必须完全一致

这是纯性能优化，**不允许改变任何输出位**。验证方式：

- 三维选择器既有测试的字节数字逐一复现：`age0=2301`、`age2=3059`、
  `q220=495`、`q40=3404` —— 与 §465 记录完全相同。
- 新增白盒测试**逐字节比对**「自动 ME」与「预计算 ME」的输出：
  res 路径在 q = 40/100/160/220 四档全部一致，skip 路径在 pct = 50/100
  两档全部一致。

## 验证

- 新白盒 **4/4**（`av1_enc_me_reuse_wbtest.mbt`）：
  - res 路径四档 q 字节恒等；
  - skip 路径两档 pct 字节恒等；
  - `precomputed_mvs` 数组长度错误时拒收；
  - `av1_enc_me_for_ref` 与「full-pel + subpel 两段」逐 MV 相同。
- 回归全绿：encoder 8/8、refring 5/5、RD 三维 5/5、RD 4/4、skip 5/5、
  NEARMV 2/2、RD×skip 4/4、multiref 4/4、ME 复用 4/4、inter 24/24、
  tile 12/12、frame 7/7（共 84）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- 本片只消除了 **ME 的重复计算**；残差编码（量化 + token + 重建）仍然
  每个组合都完整跑一遍，那部分**不能**复用（它依赖 q 与 skip 决策）。
- 若要进一步提速，可考虑：
  1. **残差的量化前共享**：预测与残差 `src - pred` 在同一参考下与 q 无关，
     可只算一次并缓存，避免每个 q 重做 MC + 减法（收益中等）；
  2. **early-out**：先只对「参考维度」做低精度 SAD 粗筛，再对 top-1 参考
     做完整的 q×skip 搜索（收益大，但会改变搜索结果，需要新的验收标准）。
- 三维穷举的整体开销仍是 |q|×|skip|×|ref|×单帧编码，生产用必须缩候选集。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
