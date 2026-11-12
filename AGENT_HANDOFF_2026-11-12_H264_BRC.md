# H.264 B×VBV/ABR（B 序列接入码率控制）

接续 BI4，本轮解除 B slices 与码率控制的互斥（§398）：ABR 的两遍
`target_bytes` 搜索与 CPB 约束的 VBV/CBR 模式现在驱动 B 序列的
**按显示位置**的帧级 QP（I=qps[0]，显示位 f=qps[f]，PPS `pic_init_qp`
=qps[0]）。批式 CAVLC/CABAC、CLI（`--b-slices` + `--target-bytes` /
`--vbv-*`）全打通。默认关闭（qps 空 = 全标量），原有码流逐字节不变。

要点（P 端 RC 管线原样复用，B 侧差异只在显示位索引与 AU 结构）：

- `h264_encode_frames_b` 签名扩展：`qps~`（显示位索引）、`vbv~`
  （每 AU 开头 `h264_enc_sei_pic_timing(v, display*2)`）、`fillers~`
  （逐 AU filler NAL）；返回 `(Bytes, sizes)`（每 AU 字节数，供
  rc/vbv 求解）。P/B encoder 的 `p.qp`/`base_qp`/`mb_qp`/`prev_qp`/
  `chroma_qp` 按显示位 QP——`prev_qp = qps[f]` 的依据是本图
  `slice_qp_delta` 先行生效，MB 循环起点 running QP = 本图 QP（与 P 端
  qps 版本同纪律）。I 帧调用透传 `vbv~`（SPS VUI/HRD + buffering
  period SEI）。B 序列入口**统一推送** `stats.frame_qps`（pub 的
  ABR/VBV 分支不再推，避免双计）。
- 两个 pub 入口的 b_slices 分支：ABR 走 `h264_rc_solve`（探测即真实
  B 序列编码），VBV 走 `h264_vbv_solve`（单调抬 QP）+ `h264_vbv_fillers`
  + 终趟 SEI/filler；`b_slices`×`dct8x8` 互斥保留，B AU 的 SEI/filler
  顺序与 P AU 一致（[SEI, slice, filler]，AUD 前插）。
- B AU 初版漏了 pic_timing SEI（NAL 类型序列打点一眼定位）；测试侧
  `expect_sei` 初值错误把 IDR 的 SPS 误报——两处均为一次性修复。

验证：brc 套件 4/4（ABR 双熵×双目标命中且 ≤ target、frame_qps 长度、
B 路径行使、recon 不变量；VBV 双熵 CPB 轨迹合法（`vbv_cpb_check`）+
逐 AU pic_timing SEI 断言 + AUD 边界；确定性 + 更紧目标更小流）；
**ffmpeg 9.0.2 零告警解码 ABR 与 VBV 两条 b_slices 流，display 序
framemd5 六帧钉值**（ARBBRC 路由）；既有 B 7/7、GOP 4/4、bparts 7/7、
bintra 9/9、CABAC RD 6/6、stream/CABAC/P/RC(14)/VBV(9)/DCT8/I4P 全绿；
CLI 10/10；docker x264 native 34/34、ffref 42/42；`moon check --target
all` 0 错误。

沿用全部 MoonBit 技能；moonbit-c-binding 与 make-moonbit-c-bindings 用
于原生 oracle 容器化重跑边界复核。未改 C ABI、未新增 vendoring。

B 线至此：b_slices（§393）→ B RD → B 子分割（§395）→ intra-in-B（§396）
→ I4x4-in-B（§397）→ **B×VBV/ABR（§398）**。剩余：I8x8-in-B（需 High
8x8DCT SPS/PPS 改造）、流式宿主分块读、子分割候选剪枝、x264 HRD 逐字段
对拍（B 流的 pic_timing/HRD 语义已在 AU 层落地）。
