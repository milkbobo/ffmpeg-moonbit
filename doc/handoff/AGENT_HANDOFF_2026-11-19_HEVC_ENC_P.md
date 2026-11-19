# HEVC 编码器 P 帧（2026-11-19）

接续 [§448 I 帧切片](AGENT_HANDOFF_2026-11-19_HEVC_ENC_I.md)（若该文档尚未单独落盘，
则接续 `PORTING_HISTORY.md` §448），本轮交付 HEVC 编码器的第二切片：**P 帧帧间
预测**（I 带头 + 单 L0 参考的前向 P 帧）。运行时仍为纯 MoonBit/wasm，没有 C
FFI 或网络依赖。详细条目见 `doc/PORTING_HISTORY.md` §449。

## 公开 API

- `hevc_encode_sequence(frames, width~, height~, qp? = 26, inter? = true)`
  — 新增。返回 `HevcEncodedSequence { annexb, frames }`，`frames` 是每帧的
  `HevcEncodedFrame`（含 `poc` / `is_idr` 与逐帧局部重建）。
  - `inter = true`（默认）：首帧 IDR I，其余为引用前一帧重建的 P 帧。
  - `inter = false`：全 IDR I 序列（与 `hevc_encode_frames` 等价）。
- `hevc_encode_frames(...)` / `hevc_encode_intra_frame(...)`：签名与 §448 兼容，
  前者仍是全 IDR 序列（外部黑盒仲裁钉值依赖这一契约，勿改）。

## 实现要点

- **帧间语法写端**：`hevc_enc_cabac.mbt` 新增 `skip_flag`、`pred_mode_flag`、
  `part_mode_inter_2nx2n`、`merge_flag`、`merge_idx`、`mvd_coding`、
  `mvp_lx_flag`、`no_residual_flag` 的写端，逐 bin 镜像
  `hevc_cabac_syntax.mbt` / `hevc_intra_decode.mbt::coding_unit` 的读取顺序。
  MVD 的 `get_cabac_bypass_sign` 语义是「1 = 负」，EG 风格幅度
  `2 + Σ2^k` 后接 k 数据位；`merge_idx` 到达 `max_num_merge_cand - 1` 时
  不写终止 bin。
- **运动估计与决策**：`hevc_enc_inter.mbt` 的整数 ME（SAD，`[-16,16]` 全搜
  索，静态块保留 MV 0）给出候选 MV；merge 候选表与 AMVP 预测器直接调用
  解码器自己的 `hevc_derive_spatial_merge_candidates` /
  `hevc_luma_mv_mvp_mode`；MC 调用 `hevc_luma_mc_uni` / `hevc_chroma_mc_uni`。
  精确命中的 merge 候选走 skip/merge，否则写 AMVP+MVD；残差经
  `rqt_root_cbf` 与 inter 专用 cbf 规则（depth-0 的 cbf_luma 仅在有 chroma
  cbf 时写出）后进入 §448 的 TU 写端。
- **序列级镜像**：`hevc_enc_frame_ex` 每次写出 VPS/SPS/PPS 与切片头后，立即
  用 `ff_hevc_decode_extradata` / `ff_hevc_decode_slice_header` 回读，CTU 循环
  跑在解析出的结构上——写端/读端每帧互证。SPS 的短时 RPS 由
  `sequence_inter` 决定（首帧 I 但后续有 P 时 SPS 仍须带 RPS）。切片头单独
  回读必须按原始 RBSP 精确位长，不能走 `ff_h2645_packet_split`（会裁尾部
  对齐位）。

## 验证

- 白盒 `libavcodec/hevc_enc_p_wbtest.mbt`：7 个用例（静态 skip/merge、四组
  纯平移 AMVP+MVD、带残差 merge+rqt_root_cbf、三帧参考链、qp 阶梯、
  确定性双跑、P 显著小于 I），判据是编码器局部重建与帧级解码器
  （`ff_hevc_decode_frames_ex(..., apply_filters=false)`）逐字节一致。
- 黑盒 `libavcodec/hevc_enc_p_test.mbt`：纯 MoonBit I+P 码流经 FFmpeg
  9.0.2 framemd5 钉值（4 帧 64x64 qp26）：
  `1f82a62968f60a66d45a21fd7994f5d9` /
  `d898bd3e360b3f022b3b4ed3a4997c95` /
  `d107765e36c0608b055a2bc3fb17b344` /
  `ef8c10f83b1c18358db7f7da8f40b741`；FFmpeg 零告警，四帧与自家解码器同。
- 生成器 `scripts/generate_hevc_p_vectors.mbtx` 写出 I+P `.265` 流；注意脚本
  模式无法直接 import `libavcodec` 包，当前以白盒 hex 输出 + 外部解码落盘的
  流程取钉值（临时工具已移入 `.trash/2026-11-19/`）。
- 全量：`moonfmt` 改动文件后 `moon check --target wasm --deny-warn --no-render`
  零警告；HEVC 编码器白盒 29/29、黑盒 2/2 全绿；`moon info --target wasm`
  已生成并检查接口。

## 边界与后续

本切片只支持整数 MV、2Nx2N、单参考 L0、全 inter 的 P 片；未做分数像素 ME、
B 片、多参考、sub-2Nx2N 划分、P 片内 intra CU、率失真选模、SAO/去块开启、
Main10/422/444、码控、流式与 CLI。下一步建议：分数像素 ME（复用解码器
MC 的 qpel/epel 核）→ 带 intra 候选的 RD 选模 → B 片 → 高色度/高位深。
