# Agent 交接：H.264 流式 §437 open-GOP 场景切换——keyframe + recovery point SEI（2026-11-17）

接 `AGENT_HANDOFF_2026-11-17_H264_SCENECUT.md`（§436）。x264
`--open-gop`：检测到的场景切换编码为**非 IDR I**（不重置 POC/参考链/
参数集，旧参考继续服务后续解码），其 AU 携带 `recovery_point` SEI
（type 6，recovery_frame_cnt=0）。opt-in，缺省关闭时 §436 流逐字节不变。
未提交（agent.md §3：用户未点名）。

---

## 0. 一句话状态

- **§437 完成且全绿**：SEI 写端 + stream_i 注入 + auto 切分派 + VBV
  事务透传 + 门面/CLI。scenecut 文件 11/11（§436 7 + §437 4）；CLI
  28/28；流式回归全绿；全模块 wasm deny-warn 0/0。

## 1. 设计要点

- `h264_enc_sei_recovery_point(cnt)`：payload=`ue(cnt)`+4 零位，镜像
  自家 `decode_recovery_point` 位序；注入位=pic_timing 后、slice 前
  （§427 统一）。
- **SEI 只跟 auto 切**：显式 `pict_type=Keyframe` 保持 §431 字节
  （无 SEI）——`auto_cut` 局部标志区分两源，闭环 GOP（默认）不受影响。
- `open(open_gop~=false)` 校验 `open_gop requires scenecut > 0`。

## 2. 关键文件

| 文件 | 改动 |
|---|---|
| libavcodec/h264_enc_ps.mbt | `h264_enc_sei_recovery_point`（新） |
| libavcodec/h264_enc_stream.mbt | `stream_i(recovery_sei~)` + AU 注入 + `open_gop` 字段/参数/校验 + auto 分派 keyframe + `auto_cut` 标志 |
| libavcodec/h264_enc_stream_vbv.mbt | `push_vbv(recovery~)` → `vbv_picture(recovery~)` → I 分支透传 |
| libavcodec/video_encoder.mbt | `VideoEncConfig.open_gop` + 透传 |
| cmd/encode-h264/options.mbt / main.mbt | `--open-gop`（要求 --scenecut）+ 帮助行 |
| libavcodec/h264_enc_scenecut_test.mbt | +4 用例 |

## 3. 验证基线

| 项 | 结果 |
|---|---|
| `h264_enc_scenecut_test.mbt` | 11/11 |
| CLI `options_wbtest.mbt` | 28/28 |
| 流式回归 stream/stream_vbv/pict_type/crf/facade | 8/4/9/7/7 全绿 |
| 全模块 wasm deny-warn | 0/0 |

## 4. 坑（本片新增）

- **SEI NAL 的 nal_unit_type 恒为 6**：数 recovery SEI 必须解 SEI
  payload 首字节（pic_timing/buffering_period 同为 type 6 NAL；本仓每
  SEI 独立 NAL，首 payload 字节即判据）——`h264scn_count_recovery_sei`。
- CLI `fail()` 抛 `Failure(...)` 包装：wbtest 断言拒收即可，不 inspect
  消息（与既有 wbtest 口径一致）。

## 5. 语义边界

- open-GOP 切点前无 leading B（pending B 闭合为尾 P；x264 跨 GOP 前向
  B 不实现）。
- closed GOP（默认）auto 切仍 IDR；`open_gop` 只改 auto 切的形态。

## 6. 本线后续切片

| # | 切片 | 要点 |
|---|---|---|
| 后续 | 多 slice | slice-max-size/slices（每帧多 slice NAL） |
| 后续 | lossless | qp=0 + qpprime_y_zero_transform_bypass |
| 后续 | B 金字塔 | B 作参考（num_reorder_refs），解码端已支持 |
| 备选 | min-keyint 偏置 | 切点距上一 IDR 最小间距 |
| 备选 | leading B（open-GOP） | 跨 GOP 前向 B（x264 完整语义） |
