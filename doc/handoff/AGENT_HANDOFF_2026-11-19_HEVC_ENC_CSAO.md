# HEVC 编码器色度 SAO 交接 —— §460

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§459（流式编码器 + CLI，已提交 733d1f8/37223d7）

## 结果

HEVC 编码器新增**色度 SAO**（opt-in `sao_chroma : Bool = false`）：置位后
`slice_sao_chroma_flag = 1`，Cb/Cr 走 §453 luma 同款 band-offset 决策，
组件耦合严格镜像解码器 `hevc_sao_parse`。纯 MoonBit、wasm-only；默认
关闭，全部既有钉值流字节不变。

验证：HEVC 编码器测试 wasm-gc **100/100**、黑盒 wasm 13/13；FFmpeg 9.0.2
`-xerror` 零告警仲裁；I+P 与 B 调度探针流 30720 字节 raw 与 FFmpeg
**逐字节一致**。

## 参数面

- `hevc_encode_sequence` / `hevc_encode_frames` / `hevc_encode_intra_frame`
  新增 `sao_chroma~ : Bool = false`；`HevcStreamEncoder::open` 同名参数；
  CLI `--chroma-sao`。
- 线程：API → `hevc_enc_frame_ex(sao_chroma~)` → slice header 置位 +
  `hevc_enc_sao_decide(chroma=true)`。

## 组件耦合（写侧/决策侧都要镜像 `hevc_sao_parse`）

- **Cb**：自己的 `sao_type_idx` bin + offsets/sign/band_position bins。
- **Cr**：**无 type bin**——type_idx/eo_class 继承 Cb；offsets、sign、
  band_position 仍是自己的 bins。cIdx 循环顺序 0→1→2。
- 决策侧：Cr 在 Cb 的 type 约束下跑自己的 band 决策；Cb 关则 Cr 全关
  （`type_idx[ctb*3+2] = type_idx[ctb*3+1]`）。
- CABAC 写端分量无关（零改动）；`hevc_sao_apply` 三分量通用（零改动）；
  色度 CTB 几何 `ctb >> hshift/vshift`（422 半宽全高）。
- `HevcPicture` 的平面是 `Array[Int32]`——决策函数 `rec` 参数签名用它。

## 测试与仲裁

- 白盒 `libavcodec/hevc_enc_csao_wbtest.mbt` **5/5**：POC 对齐逐样本重建
  （Y/U/V）；耦合钉值（Cr type==Cb、-3/+2 偏置下 Cb offset>0 / Cr
  offset<0、off 时色度全 0）；默认字节恒等 + 开启必不同；422/10-bit
  往返；流式==批式（CRF+B+色度 SAO）。
- 黑盒 `libavcodec/hevc_enc_csao_test.mbt` **1/1** 双目标：5 帧（逐帧
  色度偏置 ±4k，第 5 帧平移 (20,10)）、crf=28、b_slices、sao_chroma，
  POC 0/2/1/4/3 MD5：`063479b0…`/`814d15ad…`/`5dc66de5…`/`7d340c3f…`/
  `96ebec1a…`。
- 生成器 `cmd/generate-hevc-crf` 写 `csao_ipb.265`（5651 字节），复跑
  SHA-256 `6335214256e2b59527e547aad0ccba6192b56f3646f1b3afb6f88a5e390cbd10`。
- 仲裁：docker ffmpeg framemd5（Git Bash 加 `MSYS_NO_PATHCONV=1`）；
  raw 逐字节 diff 用 `-f rawvideo -pix_fmt yuv420p` 双侧落盘。

## 本轮踩的坑（重要）

1. **黑盒钉值与生成器帧序列必须逐帧同步**：首轮把生成器流（第 5 帧
   平移 (20,10)）的 MD5 钉到测试帧（第 5 帧 (16,8)）上——假阳性
   「测试 != FFmpeg」触发一轮 I+P/B 调度二分排查，探针 raw 逐字节全同
   才定位是数据不同步。**生成器与黑盒的帧构造要 copy-paste 级一致**。
2. `with` 是关键字不能做变量名；单行调用 + `) {` 的 match 写法在部分
   上下文解析歧义，用两步式（先存 Result 再 match）最稳。
3. `for k, f in arr` 是 index/value；`Int` 无 `to_int32()`（标注即可）。

## 检查状态

`moon fmt`/`moon info` 已跑；全仓 `moon check --target wasm` 0 错误；
定向 wasm-gc 仅既有 v128 警告。

## 边界与下一步

- SAO 决策仍 band-only：**EO 0-3 的写端/apply 已支持，只差决策**
  （EO 增益评估：按 edge_idx 分类残差统计，选最优 eo_class 与 4 offsets）。
- 单色（cfidc=0）、VBV/ABR 未实现；其余边界不变。
- 路线：**SAO EO 决策 → VBV/ABR → 单色**。
