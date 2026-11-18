# AGENT_HANDOFF_2026-11-11 — H.264 帧级码率控制（§388）全绿

## 本片结论

`h264_encode_frames` / `h264_encode_frames_cabac` 增 opt-in
`target_bytes~`（默认 0 = 平 QP，逐字节不变——存量 40 项钉值全绿）。
两遍 ABR：每帧 QP 经 slice_qp_delta 走单一 PPS，两熵编码链同构。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 干净 |
| RC 黑盒 `h264_enc_rc_test.mbt` | **4/4** |
| 存量编码器套件（默认路径逐字节不变） | **40/40** |
| 全仓 wasm-gc / 非 gc wasm | **1744/1744** / 853/853 |
| x264 native C oracle（docker，+RC 双熵用例） | **18/18** |
| RC 双流 docker ffmpeg 9.0.2 | 零告警，五帧逐字节一致（钉值） |

## API 与语义

```
h264_encode_frames(..., qp~ = 26, target_bytes~ = 0, ...)
// target_bytes > 0 时：qp = 搜索起点 + PPS 基准 QP；
// 结果恒 ≤ target（QP 51 也装不下则平 51 尽力而为）
// stats.frame_qps：每帧 QP（编码序）
```

- 单 PPS：`pic_init_qp = qp`（基准）；每帧 `slice_qp_delta = frame_qp − qp`
- QP 域 `[h264_rc_qp_min=10, h264_rc_qp_max=51]`（下限避开近无损 QP 的
  CAVLC escape 窗口风险）
- 探测即真实编码（决策/skip/参考全随 QP 变）→ 结果是实测非模型

## 求解器（h264_rc_solve，两熵共用）

1. **定界**：探 `start_qp` → 整数模型跳（`h264_rc_qp_jump`：
   2^(k/6)×1024 表，跨后端同路径；目标下少跳一步防回爬）→ 逐步走到
   最小可容纳平 QP `q_hi`（平 QP 结果记忆化）
2. **抖动**：末尾 k 帧取 `q_hi`、其余 `q_lo=q_hi−1`，二分最小 k
   （尾帧先粗化——P-only 序列末尾无人引用；I 帧最后）
3. 收敛实测（64×48×5，基准 26）：CAVLC 1569→1508（−3.9%）、
   3661→3625（−1.0%）；CABAC 1410→1379（−2.2%）；质量严格单调

## 实现要点（下片复用）

- **帧级 QP 贯穿的关键是逐帧实例化**：序列体本就每帧构造
  `H264PEncoder`，故 `p.qp`/`chroma_qp`/CABAC 状态初始化/`qscale`
  镜像/`h264_rd_lambda` 这些读 `self.p.qp` 的点无需逐点改——给实例换
  `p` 即可；新增 `base_qp` 字段供 slice 头差分
- I 帧入口增 `pps_qp~`：参数集用基准 QP、量化/重建用帧 QP
- 序列体内部化为 `*_qps(frames, base_qp, qps[])` 返回
  `(stream, 每 AU 字节数)`；RC 包装器在 `recon/stats` 上：探测用 scratch，
  终遍用调用者的
- **P 端函数顺序坑**：CABAC 文件里 `encode_p_frame_cabac` 在序列入口
  之前，且 `put_se(0) // slice_qp_delta` 同文件两处（I 与 P 上下文不同
  行）——区域限定替换：先改 I（intra 函数区间内），剩下的即 P 的

## 剩余

1. **宏块级自适应量化**（mb_qp_delta ≠ 0）：两写端目前恒写 dqp=0
   （CAVLC `put_se(0)`、CABAC `decision(60,0)`），解码端全支持
   （dqp 树 + `last_qscale_diff` 上下文 + chroma QP 联动）。片级：
   按块方差/AQ 公式给 mb_qp_delta、镜像 last_qscale_diff 语义
2. VBV/CBR 缓冲约束（现在是纯 ABR 目标）
3. I16/8x8 转默认策略（重钉流水线就绪）
4. CABAC 位定价；I4-in-P
