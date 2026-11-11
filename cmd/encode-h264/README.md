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
