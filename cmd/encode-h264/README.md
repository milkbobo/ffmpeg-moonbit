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
| `--stream` | 逐帧编码；与 ABR/VBV 互斥，宿主仍整文件读取和收集输出 |
| `--b-slices` | 奇数显示位置使用 B 帧，编码顺序重排；可与 ABR/VBV 组合（B 序列按显示位置分配帧级 QP，VBV 逐 AU 带 pic_timing SEI 与 filler） |
| `--b-parts` | B 帧子分割（16x8/8x16 与 B_8x8 逐 8x8 组决策）；要求 `--b-slices`，支持批式与流式 |
| `--intra-in-b` | B 帧内 Intra16x16 宏块（场景切换）；要求 `--b-slices`，支持批式与流式 |
| `--intra4x4-in-b` | B 帧内 Intra4x4 宏块；要求 `--b-slices`，支持批式与流式 |
| `--aq` | 开启宏块自适应量化 |
| `--aq-strength N` | 0..6，默认 1；仅在 `--aq` 时生效，0 等价于关闭 AQ |
| `--aud` | 每个访问单元前写入 AUD |
| `--target-bytes N` | 整个序列的 ABR 字节目标，0 为关闭 |
| `--vbv-maxrate N` | VBV 码率，bit/s |
| `--vbv-bufsize N` | VBV 缓冲大小，bit |
| `--fps N` | VBV 所需的整数帧率 |

VBV 三个选项必须一起提供正值，与 `--target-bytes` 互斥。
VBV 初始填充使用库默认值 90%。未启用 VBV 时，此命令不写入帧率信息。
命令会将全部帧读入内存，适合有限长度的原始视频文件。
成功编码后写入指定输出文件（替换已有内容）。
