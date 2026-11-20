# AV1 编码器 NEARMV skip 交接 —— §460

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§459（门面 + CLI，已提交 b4f4ad8）

## 结果

把 §458 的 per-SB skip 从「零 MV GLOBALMV」扩展到「非零 MV 走
NEWMV/NEARESTMV」：当 ME 找到的非零 MV 已让预测足够接近源（低 SAD）时，
该 SB 用 skip=1 但通过 uniform motion 链编码 MV，省掉整条残差 token 链。

- `av1_enc_write_me_res_tile` 增 `skip_uniform~`（默认 false = §458
  GLOBALMV 行为）。开启时 skip 块的 motion 回调复用
  `av1_enc_write_uniform_motion`（NEWMV/NEARESTMV），零 MV 前置校验放开。
- `av1_enc_write_me_skip420_inter_frame_obu` 增 `skip_uniform~`：决策律
  从「mv8==0 且 SAD(src,ref) 低」扩展为「SAD(src, MC(ref,mv8)) 低，任意 MV」，
  SAD 用解码器自己的 MC 核算（和 expected 一致）。
- 门面 `Av1Encoder::encode_frame` 增 `skip_uniform~`；CLI `encode-av1`
  增 `--skip-uniform` 开关（JSON 汇总含该字段）。

## 关键设计（方案 C，避免双循环状态镜像）

调研确认了两条路：A）预演 refmvs stack 求 NEARESTMV 的邻居值，但需在
expected 循环外另跑一遍逐 SB 的 begin/find/splat/finish，双状态镜像极易
失步；B）skip_mode 机制，但帧头 reference_select=0、skip_mode 禁用，
不可用。**采用 C**：skip 块的 motion 直接复用 `av1_enc_write_uniform_motion`
——NEARESTMV 命中时写 3 个 bool（MV=near=target），否则写 NEWMV（MV=target）。
两种情形**编码 MV 都等于 ME target**，而 expected 平面本就按 ME target 的 MC
预测计算 → decode==expected 自动成立，零时序耦合。代价是未命中邻居时多付
几个 MV bit，但仍省整条残差链。

skip 块仍不写 var-tx/token 符号，a/l tx/lcoef/ccoef 银行镜像照搬 §458。

## 验证

- 新黑盒 2/2（`av1_enc_nearmv_test.mbt`）：①平移夹具逐像素精确；②确定性
  字节恒等 + 平移静态内容 12824 → **33 字节**（且 ME 断言确认 best MV 非零，
  证明 NEARMV 真正被触发，而非误走零 MV）。
- 回归：encoder 8/8、RD 4/4、skip 5/5、inter 24/24、tile 12/12（wasm/wasm-gc）。
- CLI：`--skip-pct 100 --skip-uniform` 64×64 端到端产出合法 OBU、自检通过。
- `moon check --target wasm --deny-warn` 0；fmt/info 已跑。

## 边界与下一步

- 只对 `mv8` 偶数（hp=0 可编码）生效；ME 输出满足此约束。
- 邻居候选命中与否由 `av1_enc_write_uniform_motion` 决定，未针对 skip
  单独优化 NEARESTMV 命中率（可让 skip 决策偏好邻居 MV 值）。
- 真 RD+skip 联合代价（把 skip 省的 token bit 纳入 §457 的 λ·D+bits）未做。
- 下一片候选：①skip 决策偏好邻居 MV 提升 NEARESTMV 命中；②RD+skip 联合
  代价；③高位深/其它色度编码。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
