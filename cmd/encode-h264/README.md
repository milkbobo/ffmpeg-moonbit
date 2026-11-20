# encode-h264

将原始 8-bit YUV420P（逐帧 Y、U、V 平面，无行填充）编码为 H.264
Annex B。编码由纯 MoonBit 实现，第一帧 IDR、随后 P 帧。

```sh
moon run cmd/encode-h264 -- input.yuv --width 640 --height 480 --output out.264 --qp 26 --cabac --aud
```

必需参数：输入路径、`--width`、`--height`、`--output`。
宽高必须为 2..16384 的偶数。输入必须非空，长度为 `width*height*3/2`
的整数倍；不接受被截断的末帧。输出成功后 stdout 打印一行 JSON 摘要。

| 选项 | 默认值 / 含义 |
| --- | --- |
| `--qp N` | 26，范围 0..51 |
| `--cabac` | 使用 CABAC；缺省为 CAVLC |
| `--cabac-rd` | 用真实 CABAC 位数评估 P/B 帧候选；要求 `--cabac`，支持批式与流式 |
| `--dct8x8` | High profile 8x8 变换（I8x8、inter 8x8，与 `--b-slices` 组合时含 B 帧内 Intra8x8）；支持批式与流式 |
| `--stream` | 逐帧编码并逐个访问单元写出；native 目标分块读写文件，wasm/wasm-gc/js 宿主整文件缓冲；支持 P/B VBV，与 ABR 互斥 |
| `--b-slices` | 奇数显示位置使用 B 帧，编码顺序重排；可与 ABR/VBV 组合（B 序列按显示位置分配帧级 QP，VBV 逐 AU 带 pic_timing SEI 与 filler） |
| `--b-parts` | B 帧子分割（16x8/8x16 与 B_8x8 逐 8x8 组决策）；要求 `--b-slices`，支持批式与流式 |
| `--intra-in-b` | B 帧内 Intra16x16 宏块（场景切换）；要求 `--b-slices`，支持批式与流式 |
| `--intra4x4-in-b` | B 帧内 Intra4x4 宏块；要求 `--b-slices`，支持批式与流式 |
| `--aq` | 开启宏块自适应量化 |
| `--aq-strength N` | 0..6，默认 1；仅在 `--aq` 时生效，0 等价于关闭 AQ |
| `--aud` | 每个访问单元前写入 AUD |
| `--target-bytes N` | 整个序列的 ABR 字节目标，0 为关闭 |
| `--keyint N` | 按显示帧计数的周期 IDR 间隔，0 为关闭；固定 QP 支持 P/B、批式与流式，批式 ABR/VBV 支持 P/B |
| `--vbv-maxrate N` | VBV 码率，bit/s |
| `--vbv-bufsize N` | VBV 缓冲大小，bit |
| `--fps N` | VBV 所需的整数帧率 |
| `--deblock` / `--no-deblock` | 环路去块滤波默认开启；`--no-deblock` 显式关闭，原 `--deblock` 保留兼容。重建与参考帧按解码器语义滤波；支持批式与流式，I/P/B、双熵、420/422/444 与各深度 |
| `--sar NUM:DEN` | 样本宽高比写进 SPS VUI（§426，Extended_SAR，自动 gcd 约简）；缺省不写 aspect-ratio 字段。非方像素源（如 16:11 PAL-DV）显示比例正确的前提 |

VBV 三个选项必须一起提供正值，与 `--target-bytes` 互斥。
VBV 初始填充使用库默认值 90%。未启用 VBV 时，此命令不写入帧率信息。
周期 IDR 与 VBV 组合时，所有 GOP 共享连续缓冲模型，IDR 不重置缓冲容量。
每个 IDR 携带独立解码所需的参数集与缓冲周期 SEI。
B 序列的 CPB 按解码顺序消耗，QP 按显示位置调整；HRD 同时记录重排
所需的输出延迟。IDR 不为新 GOP 重新分配初始缓冲。
固定 QP 的 B 序列在 GOP 末尾把尚无未来参考帧的待编码帧作为 P 帧收尾，
然后从 IDR 重置调度和 POC。库接口的手动 IDR 会重置周期计数。
周期 ABR 的 `--target-bytes` 预算覆盖全部 GOP、重复参数集、IDR 和 AUD，
逐帧 QP 按显示位置分配；不可行的小预算以 QP51 最佳努力输出。
在线 VBV 使用 `--stream`，可配合 `--keyint`；P-only 还支持多参考帧。
B 图片等待下一张未来 P，再按解码顺序搜索当前 CPB 余量。整对失败不会
提交未来 P，也不会消费本次输入；先前已接收的待编码 B 保留供重试或收尾。
强制 IDR 的尾 P/新 IDR 同样整组提交。失败不修改参考帧、统计或旧输出。
库接口仍保留逐帧 QP 和重建历史；没有整序列原始输入探测。

默认（批式）路径会把全部帧读入内存，适合有限长度的原始视频文件。
`--stream` 使用 `H264StreamEncoder` 逐帧编码：native 目标通过 C 标准
I/O 每次读入一帧、每个访问单元完成即写出，原始输入缓冲不随序列增长；
编码器仍保留重建历史及在线 VBV 的 QP 历史。wasm/wasm-gc/js
宿主没有分块文件 API，仍整文件读取输入并在结束时写出输出。固定 QP 和
P-only VBV 已逐字节验证批式/流式一致；B 在线 VBV 的逐对搜索可产生不同
QP及字节输出，完整 AU 均受连续 CPB 约束。
`--stream` 在输入长度校验通过后才创建/截断输出文件；
编码中途失败时可能留下已写出的前缀。
成功编码后写入指定输出文件（替换已有内容）。
