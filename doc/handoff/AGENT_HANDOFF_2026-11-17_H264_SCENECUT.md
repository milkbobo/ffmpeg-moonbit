# Agent 交接：H.264 流式 §436 scenecut 场景切换自动 IDR（2026-11-17）

接 `doc/handoff/AGENT_HANDOFF_2026-11-17_H264_CRF.md`（§435）。x264 `--scenecut`
（0..=100）的流式自动场景切换检测：切点帧自动编码为 IDR，闭合当前 GOP。
opt-in，缺省 0 全流逐字节不变。未提交（doc/agent.md §3：用户未点名）。

---

## 0. 一句话状态

- **§436 完成且全绿**：检测器 + 流式（含 VBV 事务与 pending B 闭合）+
  门面 + CLI 全链。新测 7/7；CLI 27/27；流式回归 5 文件全绿；facade
  7/7；8 个 h264_enc wbtest（wasm-gc）8/8；全模块 wasm
  `moon check --deny-warn` 0/0。

## 1. 设计

```
inter  = SAD(上一显示帧, 当前帧)      —— 复用 §435 h264_enc_crf_sad（隔行隔字节）
intra  = |p[x]−p[x−1]| + |p[x]−p[row]|（同网格；每样本两条边，×2 尺度由阈值吸收）
cut    = inter*100 ≥ intra*(100 − scenecut)   （整数；s=40 → inter 达 intra 60% 切）
         且 inter*16 ≥ samples（绝对地板，防平坦噪声）
         intra≤0 且 inter>0 → 切（平坦→纹理硬切）
```

- 显示序因果、纯整数（跨后端同决策）；流式专属（批式显式 `pict_types`）。
- auto 只在 `request == auto` 时评估（显式 pict_type/force_idr 优先）；
  首帧不判（d==0 本就是 IDR）；切点可距上一 IDR 任意近（无 x264
  min-keyint 偏置，见语义边界）。

## 2. 关键文件

| 文件 | 改动 |
|---|---|
| libavcodec/h264_enc_scenecut.mbt | 新：intra 梯度 + cut 决策（含绝对地板） |
| libavcodec/h264_enc_stream.mbt | 字段 scenecut + open 参数/校验 + push_frame 统一 prev_y 与 auto→IDR（VBV 分派前） |
| libavcodec/h264_enc_crf.mbt | `crf_qp_for(prev, y)` 纯函数化（prev_y 生命周期移交 push_frame；CRF 值与顺序不变） |
| libavcodec/video_encoder.mbt | `VideoEncConfig.scenecut` + 流式 open 透传 |
| cmd/encode-h264/options.mbt / main.mbt | `--scenecut`（0..=100）+ 帮助行 |
| libavcodec/h264_enc_scenecut_test.mbt | 7 黑盒用例（新） |

## 3. 接线要点

- **检测在 push_frame 的 VBV 分派之前**：`request = idr` 后 §431 既有
  路径全数复用——非 VBV 侧 flush_pending（尾 P）→ stream_idr；VBV 侧
  `push_vbv(pict_type=idr)` → `vbv_picture(Idr)` 的 mid-stream 重
  init_delay。
- **prev_y 统一**：crf/scenecut 任一开启时 push 结束推进；双关闭时零
  写入（缺省路径位级惰性）。

## 4. 语义边界

- 代理式检测（x264 用 lowres SATD 双成本）：剧烈运动非切换内容可能
  触发切；阈值调节此权衡。
- 批式入口不接（显式 `pict_types` 等价覆盖）。
- VBV 组合时 IDR AU 尺寸受桶容量物理约束（小桶在切点 QP51 仍溢出会按
  既有 underflow 报错）。

## 5. 验证基线

| 项 | 结果 |
|---|---|
| 新测 `h264_enc_scenecut_test.mbt` | 7/7（硬切第二 IDR、静态 s=100 不切、显式 P 压制、CRF/VBV 组合、门面==直调） |
| CLI `options_wbtest.mbt` | 27/27（26+1） |
| 流式回归 stream/stream_vbv/stream_abr/pict_type/idr | 8/4/3/9/5 全绿 |
| facade `video_encoder_test.mbt` | 7/7 |
| 8 个 h264_enc wbtest（wasm-gc） | 8/8 |
| 全模块 wasm deny-warn | 0/0 |
| 缺省 0 | 逐字节不变 |

## 6. 本线后续切片

| # | 切片 | 要点 |
|---|---|---|
| 优先 | open-GOP keyframe 模式 + recovery point SEI | 切点选非 IDR I（§431 keyframe 已有）+ SEI type 6 写端（解码器 has_recovery_point 已有）；`scenecut_mode` 或 open_gop 参数 |
| 后续 | 多 slice | slice-max-size/slices（每帧多 slice NAL） |
| 后续 | lossless | qp=0 + qpprime_y_zero_transform_bypass |
| 后续 | B 金字塔 | B 作参考（num_reorder_refs），解码端已支持 |
| 备选 | min-keyint 偏置 | 切点距上一 IDR 的最小间距（x264 i_keyint_min 语义） |

## 7. 坑（新增）

- 测试期望「s=100 平滑序列不切」是错的：x264 语义 100 = 任何 inter
  活动都切；「不切」断言只能用真静态（inter==0）序列。
- VBV 组合测试的桶必须容得下 mid-stream IDR AU（带 SPS/PPS 重发）；
  小桶在切点 QP51 仍 underflow 属物理约束非 bug。
