# Agent 交接：H.264 纯编码器 §434 B 片显式加权预测（2026-11-17）

接 `doc/handoff/AGENT_HANDOFF_2026-11-17_H264_DEBLOCK_OFFSETS.md`（§433）。本切片完成
x264 `--weightp` 在 **B 片**上的显式加权预测（`weighted_bipred_idc = 1`），
opt-in，缺省关闭时码流逐字节不变。

---

## 0. 一句话状态

- **§434 完成且全绿**：PPS 标志、B 片双列表 `pred_weight_table()`、L0/L1
  最小二乘拟合、解码器与编码器私有 MC 路径同式应用权重；batch（CAVLC/
  CABAC）+ 流式 + 门面 + CLI 全链透传。未提交（doc/agent.md §3：用户未点名）。
- 新测 `h264_enc_weightp_b_test.mbt` 6/6；核心回归 8 文件 62 用例 0 失败；
  补充 4 文件 42 用例 0 失败；CLI `options_wbtest` 25/25；
  全模块 wasm `moon check --deny-warn` 0 错 0 警。

---

## 1. 做了什么

1. **参数块**：`H264EncParams` 增 `weightp_b : Bool`。CAVLC / CABAC 两个
   PPS writer 的 `weighted_bipred_idc` 从 `r.put(0,2)` 改为
   `r.put(if p.weightp_b { 1 } else { 0 }, 2)`。
2. **权重拟合**（`h264_enc_weight.mbt`）：把 §410 的单列表拟合抽成
   `h264_enc_fit_list_weight(list~)`，新增 `h264_enc_fit_b_weight`（同一源帧
   对 L0/L1 各拟合一次）与 `h264_enc_put_bwt`（写两个列表的权重表）。
   沿用 §412/§413 的 offset 缩放 + SAD 收益门（无增益则中性）。
3. **B 片头**（CAVLC / CABAC 两处）：在 `ref_pic_list_modification` 两标志
   之后、`dec_ref_pic_marking` 之前，按回读 PPS 的 `weighted_bipred_idc==1`
   写 `pred_weight_table()`。
4. **重建同式**：解码器 `h264_b_compensate` 本就支持显式权重（读
   `ctx.pwt`），只需把拟合表装进 mirror；编码器私有的
   `mc_b_uni_into_rec` / `mc_b_bi_into_rec` 补上与解码器逐式相同的
   加权/偏移/取整。
5. **全链透传**：intra ×2（IDR 写 PPS 必须带上标志）、batch ×5 B 调用、
   stream（open + idr/i + P/B 编码器）、门面 ×2、CLI `--weightp-b`。

---

## 2. 关键文件

| 文件 | 改动 |
|---|---|
| libavcodec/h264_enc_ps.mbt | 参数字段 + CAVLC PPS 标志 |
| libavcodec/h264_enc_cabac.mbt | CABAC PPS 标志 + intra 入口 p/p_ps + 批量 B 调用透传 |
| libavcodec/h264_enc_weight.mbt | 列表拟合抽取、B 拟合、B PWT 写端、权重参数 helper |
| libavcodec/h264_encode.mbt | CAVLC intra 入口参数 + p/p_ps |
| libavcodec/h264_encode_p.mbt | 主入口参数 + 5 处 B 调用透传 |
| libavcodec/h264_encode_b.mbt | fit_b_weights、两处 B 片头、两条私有 MC、IDR 调用透传 |
| libavcodec/h264_enc_stream.mbt | 结构体字段 + open 参数 + idr/i/P/B 编码器透传 |
| libavcodec/video_encoder.mbt / video_encoder_periodic.mbt | 门面配置透传 |
| cmd/encode-h264/options.mbt / main.mbt | CLI 选项 + 帮助 |
| libavcodec/h264_enc_weightp_b_test.mbt | 6 个黑盒用例（新） |

---

## 3. 设计决策（后续切片沿用）

1. **共享参数块 + 回读 PPS**：新旋钮放 `H264EncParams`，PPS writer 零签名
   改动；slice 写端读回读 PPS 的标志，写/读一致由构造保证（§433 同款）。
2. **只动 PPS 的两个位**：`weighted_bipred_idc` 从 0→1，语法面最小；
   解码器 `h264_b_compensate` 早已支持，无需改解码端一行。
3. **两个列表用 denom=5 的同一分母**（H.264 语法要求 luma/chroma 分母
   各一个、两列表共用）。拟合的 SAD 收益门保证静态内容写中性表。
4. **mirror.pwt 直接引用 `self.pwt`**：同一对象，杜绝编码/解码两侧漂移；
   非拟合的 ref 槽填 `1<<denom` 保持恒等，语法位写 0。
5. **P-only helper 不接该旋钮**：`h264_encode_frames_vbv` / `_qps` 是多参考
   P 路径（`b_slices=false`），没有 B 片，参数在那里会被编译器报未使用，
   故只在 `h264_encode_frames_b` 及其 5 处调用上透传。

---

## 4. 验证基线（本会话钉值）

| 项 | 结果 |
|---|---|
| 新测 `h264_enc_weightp_b_test.mbt` | 6/6 |
| 核心回归 8 文件（encode/p/b/cabac/stream/weightp/deblock_offsets/video_encoder） | 62 用例 0 失败 |
| 补充回归 4 文件（vbv/b_gop/stream_vbv/…） | 42 用例 0 失败 |
| CLI `options_wbtest.mbt` | 25/25 |
| 全模块 `moon check --target wasm --deny-warn` | 0 错 0 警 |
| 缺省关闭 vs 不传参 | 逐字节相等；PPS bipred=0 |
| opt-in batch vs stream | 逐字节相等；PPS bipred=1 |
| 重建一致性 | 编码 recon == 解码 filtered（B 片 slot 逐像素） |

CLI 实测 25/25；旧交接文档 §433 写的「31/31」是历史文件里的旧数字，未改。

---

## 5. 本线后续切片

| # | 切片 | 要点 |
|---|---|---|
| 后续 | B 类深层能力 | CRF/scenecut+open-GOP/多 slice/lossless/B 金字塔/MB-tree/ME 升级 |
| 备选 | L1 独立收益门 | 当前 L0/L1 共用 `use_weight` OR；可给未来参考单独阈值 |
| 备选 | deblock idc=1/2 | slice 边界豁免语义（x264 不发，需求出现再做） |
| 备选 | 强制类型 × 码控 | plan 派生编码序 + sizes/fillers 按编码序索引 |

---

## 6. 工具链坑（沿用 + 本次新增）

- 回归前台小批 ≤9 文件（Windows os error 206）；单文件
  `moon test libavcodec/<file>.mbt --target wasm --no-render`。
- heredoc 禁用；Python 内联脚本里 `"\{...}"` 触发 SyntaxWarning 但无害；
  `Println` 单参数，帮助文本不能一次给两个字符串。
- **黑盒解析 PPS 必须先喂 SPS**：`ff_h264_decode_picture_parameter_set`
  依赖 param-set 表里的 SPS，跳过 SPS NAL 会 EINVAL。
- **写 PPS 的 `p` 是 intra 入口的 `p_ps`**：批量 IDR 走
  `h264_encode_frames_b`，流式 IDR 走 `stream_idr`；只改 open 的局部 `p`
  不影响线上的参数集——stream==batch 的差异就是这么暴露的。
- v128/白盒 wasm `__moonbit__init` local 上限、探针文件收尾 `mv` 进
  `.trash/<日期>/`（本次探针已移入 `.trash/2026-11-17/libavcodec/`）。
- `moon info` 不支持 `--no-render`；仅在用户明确要求时提交。
