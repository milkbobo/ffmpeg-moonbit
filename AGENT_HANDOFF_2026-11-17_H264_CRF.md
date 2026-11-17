# Agent 交接：H.264 纯编码器 §435 CRF 恒定速率因子（2026-11-17）

接 `AGENT_HANDOFF_2026-11-17_H264_WEIGHTP_B.md`（§434）。本切片完成 x264
`--crf` 的质量驱动码控，opt-in，缺省关闭时码流逐字节不变。

---

## 0. 一句话状态

- **§435 完成且全绿**：CRF 基线 QP + 显示序因果复杂度加权，batch
  （CAVLC/CABAC）+ VBV 种子组合 + 流式（含 VBV 事务）+ 门面 + CLI 全链。
  未提交（agent.md §3：用户未点名）。
- 新测 `h264_enc_crf_test.mbt` 7/7（wasm + wasm-gc 双后端）；CLI
  `options_wbtest` 26/26；编码器黑盒全量回归 0 失败；8 个 h264_enc
  wbtest 于 **wasm-gc** 7/8（唯一红=既有解码器问题，见 §5）；全模块
  wasm `moon check --deny-warn` 0 错 0 警。
- **回归目标教训**：libavcodec **wbtest 必须跑 wasm-gc**——白盒单元在
  wasm（V8 MVP）下 `__moonbit__init` local count 越限（包级既有，195 个
  wbtest 全部同症；删净 §435 顶层常量仍越限，与 §435 无关）。黑盒文件
  两后端皆可。

---

## 1. 设计

```
qp_i = round(crf + 0) + 6*(qcompress-1)*log2(cplx_i / mean(cplx_1..i))
       \_ round(crf) _/   \_ qcompress = 0.6: 每倍复杂度 −2.4 QP _/
```

- `crf~ : Double = -1.0`；负值=关；`round(crf)` 是基线 QP（crf 18/23/28 →
  QP 18/23/28——x264 的 ratefactor→QP 标定是内部 λ 模型，不复刻）。
- `cplx_i` = luma SAD(帧 i, 帧 i−1)，隔行隔字节（>8bit 只采低字节，只用
  序列内比值）。帧 0 恒 base 不进均值；均值含当前样本（帧 1 恒 base）。
- ±6 QP 饱和；全静态（均值~0）偏移 0；单帧静态 +6。
- **因果性 = stream==batch 逐字节恒等的前提**（两侧同公式同顺序）。

## 2. 关键文件

| 文件 | 改动 |
|---|---|
| libavcodec/h264_enc_crf.mbt | 新：H264Crf 状态机 + SAD + 批量驱动 + 流式 `crf_qp_for`/`pic_suggest`/`pps_qp` |
| libavcodec/h264_encode_p.mbt | CAVLC 入口 crf~ + 校验 + 三分支接线；`h264_encode_frames_vbv` crf_qps~；`h264_vbv_solve` start_qps~ 种子 |
| libavcodec/h264_enc_cabac.mbt | CABAC 入口镜像 + `h264_encode_frames_vbv_cabac` crf_qps~ |
| libavcodec/h264_enc_stream.mbt | 字段（crf/prev_y/pending_qp）+ open 参数 + push_frame QP 选择点 + stash_pending(qp~) + stream_pending_b/flush_pending 用 pending_qp + `base_qp: self.pps_qp()` 根修 ×2 |
| libavcodec/h264_enc_stream_vbv.mbt | `push_vbv(qp_hint~)` + `vbv_picture(qp_hint~)`（CRF 不受 rc_min 钳位）+ pair-B/尾-P 传 pending_qp |
| libavcodec/video_encoder.mbt | `VideoEncConfig.crf` + 门面互斥 + 批式两调用点透传 |
| cmd/encode-h264/options.mbt / main.mbt | `--crf`（parse_double，NaN 安全范围）+ 帮助行 |
| libavcodec/h264_enc_crf_test.mbt | 7 黑盒用例（新） |

## 3. 根因修复（本次最大发现）

**流式 P/B 编码器 `base_qp` 恒钉 `self.qp`**。`slice_qp_delta = p.qp −
base_qp`；批式 B 线用 `base_qp = qps_arr[0]`（=PPS pic_init_qp）。plain
路径图 QP 恒等于 self.qp、流式 ABR 的 PPS 也恒 self.qp，两类既有路径都
掩盖了它。CRF 下 B 线 PPS base = CRF 基线（新 `pps_qp()` helper：B 线=
CRF 基线、P 线=用户 qp，镜像两批式入口的 PPS 语义差异）后，QP≠base 的
delta/dqp 码字分叉（n=2 全 QP 23 仍差 2 字节 → 定位到 base_qp）。两处
构造（stream_p/stream_b）改 `self.pps_qp()`，CRF 关闭时逐字节等旧路径。

**教训**：透传 qp 的入口面，「QP 参数」与「PPS 基准」是两个独立维度，
任何把图 QP 与 open QP 解耦的特性（RC 类）都会暴露 base_qp 类钉死。

## 4. 验证基线

| 项 | 结果 |
|---|---|
| 新测 `h264_enc_crf_test.mbt` | 7/7（wasm + wasm-gc；QP 序列精确钉值 [23,23,29,22,29,21]） |
| CLI `options_wbtest.mbt` | 26/26（25+1） |
| 编码器黑盒全量回归（h264_enc_*/encode/video_encoder *_test.mbt，wasm 单文件制） | 0 失败 |
| 8 个 h264_enc wbtest（wasm-gc 单文件制） | 7/8（唯一红见 §5 第 0 行） |
| 全模块 wasm `moon check --deny-warn` | 0 错 0 警 |
| 缺省关闭 | 逐字节不变（crf=-1 == 不传参） |
| stream==batch（B/P 调度，plain CRF） | 逐字节相等 |
| crf+VBV（批式紧桶 + 流式） | 解码 6 帧；QP ≥ CRF 地板 |

### 回归附带的既有问题处置（非 §435 引入；均已收口）

- `h264_enc_binter8_420_wbtest` / `h264_enc_c444_binter8_wbtest` 的
  recon 断言在 §424 去块默认翻转后过期（仍用跳过滤波解码对比滤波
  recon）——两处 `decode(stream, true)` 重钉为 `false`（补 §424 全族
  重钉在当时 wasm 跑不到的文件）。420 变体 wasm-gc 全绿。
- **c444_binter8 的 inter-8x8 断言收口（后续切片当日完成）**：CABAC×444
  腿默认 `cabac_rd=true` 的真实位计价把 8x8/4x4 候选拉到 ~40 位内，
  失真项合法选 4x4（插桩：ssd 2805/2530、cabac 价 1521/1563、cavlc 价
  1849/2088；rd=false 全 8x8 流 1641B < rd=true 1655B，均为合法 RD 产物）。
  **非解码器/滤波问题**——探针证明 skip_lf 开关对 infos 逐字段零影响
  （首判「滤波改变 infos」系被测试循环顺序误导）。修法：tf8 断言改吃
  `cabac_rd=false` 流（CAVLC 定价确定性选 8x8，钉 CABAC 444 inter8
  写/读路径），默认 rd 流保留 stream==batch 与 recon 断言。8 个
  h264_enc wbtest 于 wasm-gc 全 8/8。

## 5. 本线后续切片（沿用 §434 清单，CRF 已销项）

| # | 切片 | 要点 |
|---|---|---|
| 后续 | scenecut + open-GOP | 流式已有 §431 keyframe/IDR 请求面；缺自动检测（cut 检测→强制 IDR/keyframe + recovery point SEI） |
| 后续 | 多 slice | slice-max-size/slices（每帧多 slice NAL） |
| 后续 | lossless | qp=0 + qpprime_y_zero_transform_bypass（High 444 谱系已在） |
| 后续 | B 金字塔 | B 作参考（num_reorder_refs），解码端已支持 |
| 后续 | MB-tree / ME 升级 | lookahead 类，需大基建 |
| 备选 | CRF qcompress 暴露 | 当前内部常量 0.6；x264 --qcomp 语义 |
| 备选 | 白盒单元 wasm 减负 | 顶层 let 改 match 常量/黑盒迁移——除非有人需要 wasm 白盒跑，优先级低 |

## 6. 工具链坑（新增）

- 黑盒测试文件独立编译单元：跨文件 helper 不可见，concat/fixture 本地重定义。
- `stats=bstats~` 非法（`~` 后缀=标签 punning）；变量名≠标签名用 `stats=bstats`。
- Array 插值 `\{arr}` 弃用 Show——手工拼串。
- 流式 `stats.frame_qps` 编码序 vs 批式 B 线显示序（对比先重排）。
- 探针三板斧：AU 尺寸表 + 首分歧字节 ±16 dump + n=2 消减变量。
