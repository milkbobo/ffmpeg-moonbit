# AGENT_HANDOFF_2026-11-11 — H.264 宏块级自适应量化（§389）全绿

> 本片替换 `AGENT_HANDOFF_2026-11-11_H264_AQ_WIP.md`（半成品状态已收尾）。

## 本片结论

`h264_encode_frames` / `h264_encode_frames_cabac` 增 opt-in `aq~`
（默认 false = 平 QP，逐字节不变——存量 40 项钉值 + 12 条 ffmpeg 仲裁
钉值全绿）。每 MB 按活动度 ±1 QP，`mb_qp_delta` 走解码器运行 QP，两熵
编码链同构；AQ 叠加在 §388 帧级 RC 之上。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 干净 |
| AQ 黑盒（`h264_enc_rc_test.mbt` 追加 3 项） | **3/3** |
| 存量编码器套件（默认路径逐字节不变） | **40/40** + quant 幅度门 3/3 |
| 全仓 wasm-gc | **1747/1747** |
| 非 gc 黑盒编码器 | **47/47** |
| x264 native C oracle（docker，+AQ 双熵用例） | **20/20** |
| AQ 双流 docker ffmpeg 9.0.2 | 零告警，四帧逐字节一致（AQARB/AQCARB） |

## API 与语义

```
h264_encode_frames(..., qp~ = 26, aq~ = false, target_bytes~ = 0, ...)
// aq=true：每 MB QP = clamp(帧 QP + adj, 0, 51)，adj ∈ {-1,0,+1}
// stats.dqp_mbs：实际写入非零 mb_qp_delta 的 MB 数（skip/cbp=0 不计）
```

- **AQ 规则**（`h264_enc_ps.mbt`）：`h264_aq_measure` 每 MB luma MAD
  （对 MB 均值的平均绝对偏差，整数）+ 全图平均；`h264_aq_adj`：
  `act*4 > avg*5` → +1、`act*4 < avg*3` → −1、中间 0；avg≤0 全 0
- `chroma_qp` 字段 MB 入口随 mb_qp 覆写（aq on 时），量化/dequant/
  色度 DC/AC 全部读点自动跟随

## 关键正确性：dqp 基准 = 运行 QP（本片根修）

解码器 `ctx.qscale` 跨 MB 累积（`h264_picture_slice.mbt:35` 仅 slice
起点重置），每个 `mb_qp_delta` 叠在前一个 MB 的 QP 上。WIP 半成品的
`mb_dqp = mb_qp − slice_qp` 会让连续调整 MB 的解码器 QP 漂移——
症状：I 帧重建正确、P 帧第一个纹理 MB 起 enc/dec 差 1。四链修复：

- **CAVLC I/P**：`H264IntraEncoder`/`H264PEncoder` 增 `mut prev_qp`
  （帧入口 literal 初始化为帧 QP）；`mb_dqp = mb_qp − prev_qp`；
  仅真实 dqp 写点推进 `prev_qp = mb_qp`（I16 无条件、I4/I8/inter
  仅 cbp≠0；skip/cbp=0 不推进）
- **CABAC I/P**：镜像 `ctx.qscale`/`last_qscale_diff` 整帧持久
  （去掉逐 MB 重置——`h264_cabac_mirror_new` 已按帧 QP 初始化）；
  `mb_dqp = mb_qp − 镜像运行 qscale`；`h264_cabacw_dqp` 助手自带
  环绕推进。skip 分支与 cbp=0 else 分支按 C 语义重置
  `last_qscale_diff = 0`（`h264_cabac.c:1952/2492`）；`info.qp` 改记
  运行 qscale（仅去块滤波读，编码镜像里是纯记录）
- **RD 计价保护**（`eval_plan`）：干跑 CAVLC 语法写器计位（CABAC P
  也经此计价），写器 dqp 写点会推进 prev_qp/计数——干跑前后
  保存/恢复 `prev_qp` 与 `stats.dqp_mbs`。**这是 CAVLC 独有的坑**：
  CABAC 用镜像 qscale 不被 CAVLC 计价写器触碰，故 CABAC 先过、
  CAVLC 后过
- `stats.dqp_mbs` 从 MB 入口移到真实写点计数（只计实际写入者）

## 实现要点（下片复用）

- 逐帧实例化仍是 QP 贯穿的关键：序列体每帧构造编码器实例，
  `p.qp`/`chroma_qp`/CABAC 初始化/`h264_rd_lambda` 读 `self.p.qp`
  的点无需逐点改；`decide_plan`/`code_mb_residuals` 本就读 `self.mb_qp`
- aq off 路径逐字节不变的锚：mb_qp/mb_dqp 初值即帧 QP/0，prev_qp
  初值即帧 QP，dqp 恒 0 → 写出的位与旧 `put_se(0)`/`decision(60,0)`
  完全相同；CABAC 镜像 qscale 恒帧 QP、last_qscale_diff 恒 0
- skip 宏块无 dqp（解码器 skip 路径不读 dqp）✓ 循环结构天然满足

## 验证清单（已全过）

1. `moon check --target wasm --deny-warn` 干净；`moon fmt`/`moon info`
2. aq off 回归：五存量编码器文件 40 项 + quant 3 项逐字节不变
   （ARB dump 与 §388 捕获逐行 diff 相同）
3. aq on：`h264_enc_rc_test.mbt` 三项（混合活动度夹具 64×48×4，
   左半平块漂移 + 右半梯度/棋盘/游动框）——双熵 dqp_mbs 钉值
   （CAVLC 22 / CABAC 20）、aq off==0、重建不变式、aq+RC ≤ 目标；
   仲裁测试 AQARB/AQCARB 两流 println 在钉值断言之前（先收双 dump）
4. x264 oracle：`x264_wbtest.mbt` 末尾 AQ 双熵 `x264_cross_decode`
   用例（`x264_dct8_fixture` + aq=true + dqp_mbs>0 断言），18→20
5. 全量 wasm-gc 1747、非 gc 黑盒编码器 47

## 环境速查 / 坑

- docker 仲裁镜像 `ffmpeg-moonbit-ffref:nine-x264`；x264 oracle 运行：
  `MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh -v
  "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work
  ffmpeg-moonbit-ffref:nine-x264 -c "/root/.moon/bin/moon update
  >/dev/null 2>&1; /root/.moon/bin/moon test --target native -p
  libavcodec/x264 --target-dir /tmp/mbuild"`
- **非 gc whitebox `__init` 局部数上限是预存限制**：基线 dc54e14 与
  本片以同一函数（#4268）同一偏移（@+2258862）触发
  `local count too large`——与 AQ 无关（本片只加函数/字段，无顶层
  全局量，init 不变）。whitebox 一律走 wasm-gc；非 gc 只跑黑盒
- Windows：`moonrun --test-args` 32K 命令行上限——libavcodec 包文件数
  贴近阈值，**别新增 .mbt 文件**（AQ 测试追加进既有 `h264_enc_rc_test.mbt`）；
  rm-guard 拦 bash 删除类子串——长文本一律 Write 工具落盘再执行/提交
- `.scratch/repin_all.py` TAG_RE 含 RCARB/RCCARB；AQ 两流本次手动
  docker 仲裁 + Edit 回钉（AQARB/AQCARB 各 4 帧 md5 已钉）

## 剩余

1. VBV/CBR 缓冲约束（现在是纯 ABR 目标 + 帧内 AQ）
2. I16/8x8 转默认策略（重钉流水线就绪）
3. CABAC 位定价；I4-in-P
4. AQ 强度/曲线可配（目前固定 ±1 与 25% 带）