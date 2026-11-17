# 交接文档：H.264 纯编码器 SEI/ROI/mb_info/pict_type 收尾（§428–§431 完成）

> 写于 2026-11-17。接手者先读 `agent.md`（§2 工具链/测试约定、§3 提交规范）
> 与 `PORTING_HISTORY.md` 的 §427–§431 条目。本文件只写**当前状态与后续切片**。

---

## 0. 一句话状态

- **§428（STEREO3D/FPA SEI）已完成且全绿**：IDR-only 语义按 C 源码纠正，
  白盒断言并入黑盒（白盒包不可运行），见 §1。
- **§429（ROI 逐 MB 量化偏移）已完成且全绿**：`H264Roi` + 8 个 AQ 注入点 +
  批量/VBV/ABR/流式/门面全链，见 §2。
- **§430（mb_info 运动提示）已完成且全绿**：`H264VideoHint` + 常量 MB
  强制 Skip（P/B 双熵）+ 批量/VBV/流式/门面全链，见 §3。
- **§431 已完成且全绿（流式 + 批量）**：`h264_pict_type_*` 选择子、
  非 IDR I 写端、流式/VBV/门面逐帧强制，以及批量 `pict_types~` 的
  plan 调度重构（含 mid-IDR），见 §4。
- **未提交链**：§421d–§431 全在工作树（agent.md §3：用户点名才提交）。


---

## 1. §428 收尾记录（已闭环，勿重做）

- **语义纠正**：上游事实是 x264 的 frame-packing SEI **只写在 IDR 帧**
  （§424d），且 `h264dec.c decode_nal_units` 每个 AU 起始调用
  `ff_h264_sei_uninit` 重置 FPA——旧交接文档“解码端持久到后续帧”的假设
  是错的。批量/流式测试已按 **仅 IDR 帧携带 `Stereo3d`** 断言。
- **非法值**：`av_stereo3d_2d` == 0 == “off”（合法），旧测试把 0 当非法值
  已改为 8 / -1。
- **白盒测试**：libavcodec 白盒包（196 个 `*wbtest.mbt`）在 wasm 下撞
  `__moonbit__init` 局部变量上限（移走新文件仍复现，属既有状态），
  `h264_enc_stereo_wbtest.mbt` 的 FPA SEI 形状断言已并入黑盒
  `h264_enc_stereo_test.mbt`（Annex B 扫描 + 防竞争字节剥除），原文件删除。
- 测试面：`h264_enc_stereo_test.mbt` 6 测。

## 2. §429 ROI 实现要点

- `h264_enc_roi.mbt`：`pub(all) struct H264Roi`、
  `h264_roi_offsets_for`（AQ 关/空图 → `Ok([])`，否则校验 den≠0 再展开）、
  `h264_roi_off_at`。换算：`qoffset = num * qp_range / den`（向零截断，
  `qp_range = 51 + 6*(bit_depth-8)`，夹 ±qp_range），矩形按 16px 网格
  `[top/16, ceil(bottom/16))`，**逆序遍历 → 首条区域胜出**。
- 叠加点：`mq = qp + aq_adj + roi_off`，随后夹 0..51（8 个 AQ 站点：
  CAVLC I ×2、CABAC I ×2、CAVLC P、CABAC P、CAVLC B、CABAC B）。
- 结构字段：`H264IntraEncoder`/`H264CabacIEnc`/`H264PEncoder` 的 `roi_off`；
  批量入口 `roi~ : Array[H264Roi] = []`（CAVLC/CABAC × 普通/VBV/ABR/周期 B），
  每序列展开一次共享。
- 流式：`push_frame(roi~)` 逐帧生效；B 调度 odd push 时
  `pending_roi = self.roi.copy()`，`stream_b`/`flush_pending` 用 pending
  图（VBV 事务经 `..self` 继承 `roi`/`pending_roi`）；`VideoEncoder`
  门面转发。
- 测试：`h264_enc_roi_test.mbt` 7 测（CAVLC/CABAC intra 三向排序、
  重叠首胜、AQ 关跳过且 den=0 不报错、den=0 精确串（intra+push）、
  批量 P 三向排序、流式=批式 + pending B stash）。

## 3. §430 mb_info 运动提示实现要点

- `h264_enc_hint.mbt`：`h264_video_hint_constant`(1) /
  `h264_video_hint_changed`(2)、`pub(all) struct H264VideoRect`、
  `H264VideoHint { kind, rects }`；`h264_hint_constants` 按 libx264.c
  `setup_mb_info` 展开——Constant 只取完全落入的 MB（ceil/floor），
  Changed 从全常量里清除相交 MB（floor/ceil），空 rects 合法；
  `h264_hint_at` 按显示位取图，未知 kind 报精确串。
- 行为：常量 MB 强制 P_Skip/B_Skip（B 的 direct 试验仍先跑以产生
  skip 预测/重建），跳过 ME 与 RD 候选；IDR 忽略。
- 接线：`H264PEncoder.hint_const : Array[Bool]`；批量入口
  `hints~ : Array[H264VideoHint?] = []`（空或与帧数等长），
  CAVLC/CABAC × 普通/VBV/ABR/周期 B 全链；流式 `push_frame(hint~)`
  逐帧生效（B 调度 pending_hint stash、VBV 事务继承）；门面转发。
- 测试：`h264_enc_hint_test.mbt` 6 测（强制 Skip 双熵变小、准确提示
  静态+无损 IDR 逐字节不变、空 rects 拼写等价、网格取整拼写等价、
  未知 kind 错误串、流式=批式 + pending stash）。

## 4. §431 流式 pict_type 实现要点

- `h264_enc_pict_type.mbt`：`h264_pict_type_auto`(0) / `_keyframe`(1) /
  `_idr`(2) / `_p`(3) / `_b`(4)，与 §424a 绑定 `X264PictType::to_sel`
  逐值对应；`h264_pict_type_validate` 报精确串。`force_idr=true`
  等价 `pict_type=idr` 且优先（上游 forced-idr 规则）。
- **非 IDR I 写端**：`h264_encode_intra_frame` /
  `h264_encode_intra_frame_cabac` 新增 `idr~ : Bool = true`、
  `frame_num~`、`poc_lsb~`。`idr=false` 时：NAL type 1、`frame_num` /
  `pic_order_cnt_lsb`（b_seq）写当前位置、`dec_ref_pic_marking`
  非 IDR 语法、不写 SPS/PPS、不写 buffering period、不写 FPA SEI。
  缺省 IDR 路径逐字节不变。
- **流式调度**（`h264_enc_stream.mbt`）：`push_frame(pict_type~)`。
  首帧恒 IDR；`Idr` flush pending 后开新 GOP；`Keyframe` flush pending
  后 `stream_i`（fn_counter 前进、重建入参考链、states 按 IDR 重播）；
  `P` 立即 `stream_p`，待定 B 以此为 future 配对；`B` 进 pending
  （`b_slices=false` 报错 `h264 enc: forced B requires b_slices (POC type 0)`）。
  Auto 分支与旧调度逐分支等价。
- **VBV**（`h264_enc_stream_vbv.mbt`）：`H264VbvPicture::I`，非 IDR I
  只带 pic_timing；`push_vbv(pict_type~)` 与流式同套分派（forced B
  先 flush 旧 pending、再 stash）。
- **门面**：`VideoEncoder::push_frame(pict_type~)` 转发；keyint 的
  周期 force_idr 仍优先。
- **批量侧（§431b）**：`h264_encode_frames` / `h264_encode_frames_cabac`
  的 `pict_types~`；`h264_pict_type_plan` 与流式同一套规则展开编码序；
  批量 B 核心按「参考图 + 其后 B」单元循环（`gop_start` 相对 POC、
  `hist_poc` 真实 POC），P-only 核心按显示序；mid-IDR 与非 IDR I 都复用
  intra 的 `idr~`/`frame_num~`/`poc_lsb~`。强制类型与 `target_bytes`/VBV
  互斥（求解器按默认编码序索引），报
  `h264 enc: pict_types is not supported with target_bytes or VBV (use the streaming encoder)`。
- **顺带修复**：P 加权预测表拟合源改为 `refs_[0]`（CAVLC 在
  `encode_p_frame`、CABAC 在 `encode_p_frame_cabac` 各一处）。流式
  `b_slices` 下 `ref_y` 在孤立 P 之后仍是过去参考，强制 P/B 会让 PWT
  拟合到过期参考；批量本来 `ref_y == refs_[0]`，故无默认行为变化。
- 测试 `h264_enc_pict_type_test.mbt` 9 测（流式 5 + 批量 4，详见
  PORTING_HISTORY §431）。

## 5. 验证基线（本会话钉值）

- 全量 **55 文件回归 0 失败**（`.scratch/s430_order.txt` 54 文件 +
  `h264_enc_pict_type_test.mbt`；本次日志 `.scratch/h264_s431b_fullrun.log`）
- `h264_enc_pict_type_test` 9/9、`h264_enc_roi_test` 7/7、
  `h264_enc_hint_test` 6/6、`h264_enc_stereo_test` 6/6、CLI 30/30
- 全模块 wasm `moon check --deny-warn` 0 错 0 警；`moon info` 通过
- 缺省（`pict_types=[]`/`roi=[]`/`hint=None`/`stereo3d=0`）逐字节不变

## 6. 本线后续切片（用户已确认继续纯编码器）

| # | 切片 | 要点 |
|---|---|---|
| 后续 | B 类深层能力 | CRF/scenecut+open-GOP/chroma-qp-offset/去块 αβ/B 加权/多 slice/lossless/B 金字塔/MB-tree/ME 升级 |
| 备选 | 强制类型 × 码控 | `target_bytes`/VBV 的求解器若要吃强制编码序，需把 `h264_b_coding_order` 改成由 plan 派生并把 sizes/fillers 按编码序索引（当前明确互斥） |

## 7. 工具链坑（本会话新增）

1. **终端会话重置会杀掉跨 turn 的后台回归**：回归改**前台小批**（每批 ≤9
   个文件，单文件 `moon test libavcodec/<file>.mbt --target wasm --no-render`），
   日志追加到 `.scratch/`；每批结束后用日志里的 `F:` 行核对遗漏文件。
2. 后台命令的 `Select-String` 无匹配时退出码 1，会被当成命令失败；需要
   零匹配也成功时把总结交给后续 `Write-Host`。
3. `moon info` **不支持 `--no-render`**（会报 unexpected argument）。
4. heredoc 禁令、python 批量插入禁忌、白盒 wasm 上限等旧坑不变
   （agent.md §6 与 §428 交接 §3）。
