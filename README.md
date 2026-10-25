# FFmpeg → MoonBit

本项目将 FFmpeg 9.0.2 的部分算法、解码器和解复用器移植为 MoonBit 包。代码位于 `libavutil/`、`libavcodec/` 和 `libavformat/`；它是按功能逐步验证的移植，尚不能替代完整的 FFmpeg 命令行或全部库接口。

## 当前移植情况

| 范围 | 已可用 | 主要边界 |
| --- | --- | --- |
| H.264 | I/P/B 帧；CAVLC/CABAC；8/9/10/12/14 bit、单色及 4:2:0/4:2:2/4:4:4；多 slice、MBAFF/PAFF、参考帧管理、SEI、去块滤波；Annex B 与 MP4 `avcC` 入口；渐进帧与 MBAFF 帧缺失或截断 slice 的宏块补偿 | P 帧大缺口、高位深等复杂恢复场景尚未逐像素对齐 FFmpeg；场图片按上游边界明确报错；SP/SI 明确不做。FMO、separate colour plane 和数据分区不在 FFmpeg 9.0.2 的可解码范围内 |
| HEVC | I/P/B 帧；8/10/12 bit、多种色度格式及单色；多 slice、WPP、tiles、去块滤波与 SAO | dependent slice、tiles 与 WPP 的组合、PCM/RDPCM 等仍缺 |
| AAC / MPEG 音频 / FLAC | AAC-LC PCM；MPEG 音频 Layer I/II/III 定点 PCM；FLAC 无损 PCM | AAC 的 SBR/PS、USAC 等未覆盖 |
| 其他视频 / 音频 | VP9 profile 0/1/2/3：关键帧与帧间帧（P 帧四种 MV 模式、三路参考、可切换/固定插值滤波、并行提交与计数驱动概率自适应；`comp_inter_blocks` 诊断计数器）、8/10/12-bit、4:2:0/4:2:2/4:4:0/4:4:4；AV1 8/10/12-bit 4:2:0/4:2:2/4:4:4/单色 多 tile 无损关键帧、有损关键帧（8/10/12-bit，DCT/ADST/IDTX 全变换、环路去块滤波、CDEF、环路恢复 Wiener/SGR、逐 SB delta-q，多 tile 含 64/128 SB 与 tile 边界强度修正）；MJPEG、PNG/APNG；Opus SILK/混合/CELT 全模式与多流包级解码 | VP9 复合预测（B 帧，libvpx 编码器无法生成，已用 alt-ref 码流计数探针证实）与参考缩放；AV1 帧间帧仍待移植；Opus 包丢失隐藏（PLC）未实现 |
| 容器与分片 | MP4/MOV（含 AAC/H.264/HEVC/AV1/VP9/Opus 及 H.264+AAC 双轨写入器）、Matroska/WebM（含 H.264/VP9/AV1/Opus、VP9+Opus 与 H.264+AAC 多轨写入器；VP9/AV1/Opus 写入器可选 webm/matroska DocType）、MPEG-TS（含 H.264+AAC 写入器，PMT stream type 可选 HEVC/MP3 等）、WAV（含 PCM 8/16/24/32-bit、IEEE float32 与 extensible 写入器）、Ogg/Opus（读写）、裸 AAC/MP3（含 ADTS AAC 写入器）；HLS/DASH 通过回调读取 TS/fMP4，含 H.264/HEVC/AV1/VP9/AAC/Opus 单轨 fMP4 初始化段/媒体段写入器、HLS 主/媒体播放列表与 DASH SegmentTemplate MPD 写入器 | 尚无统一播放 API、完整网络协议层或完整 muxer 集合 |
| 基础算法 | 位流、哈希/校验和、AES 等密码算法、数学/时间基及部分 `@v128` 内核 | `libavutil` 其余模块及 `libswscale`、`libswresample` 等尚未整体移植 |

**H.264 取舍**：SP/SI 切片极少使用，本项目不实现其像素重建。入口会明确报错，避免将其当作 P/I 切片产生错误像素。冗余 slice 会在解析头部后丢弃。FFmpeg 9.0.2 自身不解码 H.264 数据分区或 FMO；本移植对数据分区 NAL 明确报错。

错误恢复默认关闭；持久解码器可调用 `set_error_concealment(true)` 开启。恢复帧的 `damaged_macroblocks` 给出补偿的宏块数。渐进帧和 MBAFF 帧都已支持缺失首段、中段或尾段 slice（含截断 slice）；MBAFF 沿用 `h264_slice_init` 的宏块对地址换算，其余按 FFmpeg 的 raster 状态表处理。**场图片不做恢复**：FFmpeg 9.0.2 的 `er_supported()` 对 `field_picture` 直接返回 0，本项目因此明确报错，而不是输出上游从未产生的像素。

表格只描述已实现的功能类别，并不表示任意参数组合或损坏输入都已验证。具体码流、逐帧对拍结果和已知偏差见 [移植过程记录](PORTING_HISTORY.md)。

## 构建与测试

在本目录运行：

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render
moon info --target wasm
```

最近一次完整验证（2026-10-25）：`moon check --deny-warn` 通过，Wasm 测试 **871/871** 通过。H.264 等真实码流测试将输出与 FFmpeg 9.0.2 对拍；测试素材和生成说明位于各 `*_realdata_wbtest.mbt` 文件及 `scripts/`。

## 代码位置

- [libavcodec/](libavcodec/)：视频、音频解码与码流处理。
- [libavformat/](libavformat/)：容器解复用、分片读取与参数桥。
- [libavutil/](libavutil/)：基础算法和数据结构。
- [PORTING_HISTORY.md](PORTING_HISTORY.md)：详细实现记录、验收矩阵和排错笔记。

## 许可证

本移植遵循 [LGPL-2.1-or-later](LICENSE.md)。许可证正文见 [LGPL 2.1](COPYING.LGPLv2.1) 和 [LGPL 3](COPYING.LGPLv3)。
