# 裸 DTS 核心与 AIFF/AIFF-C 接手（2026-11-25）

## 当前状态

继 [ADPCM 接手](AGENT_HANDOFF_2026-11-25_ADPCM.md) 之后，这一片接通裸 DTS 核心流与 AIFF/AIFF-C 播放。代码与测试已提交为 `2481da0`，文档（§517、README、本文件）随其后的文档片提交。工作区开工前已有 AV1、RealMedia、部分 playback 文件与夹具脚本的改动，未纳入。项目仍以纯 MoonBit/Wasm 为交付目标，不依赖 FFmpeg 程序或 C FFI 运行。

## 改动入口

- [dca_header.mbt](../../libavcodec/dca_header.mbt)、[dca_decode.mbt](../../libavcodec/dca_decode.mbt)：共享 DTS 核心头解析，支持 16 位与 14 位字打包的大小端归一化；16 位 LE 同步字是 `FE 7F 01 80`（逐 16 位字交换，不是整 32 位反序）。Matroska 的原有 BE 核心解码链仍使用同一解码器。
- [dts_demux.mbt](../../libavformat/dts_demux.mbt)、[probe.mbt](../../libavformat/probe.mbt)：`av_dts_open` 为完整核心帧建立索引，保留原始包字节，PTS 与 duration 以每声道样本计。前导完整帧若恰好到 EOF 或下一帧匹配，探测分数 53，避免被 DTS 负载内偶然出现的 MPEG Audio 同步字（52 分）抢占。拒绝截断、采样率/声道数变化、DTS-HD 扩展子流。14 位覆盖来自真实 16 位帧的重打包，未用原生 14 位采集流独立验证。
- [aiff.mbt](../../libavformat/aiff.mbt)：保留原有 PCM 解封装，新增 AIFF-C `ima4`（复用 `adpcm_ima_qt`）；每块 `34 × channels` 字节、64 个样本/声道，`COMM` 里的块数用于流时长，实际拆包受 `SSND` 和 offset 限制，不读尾部残块、pad 或后续 chunk。
- [playback.mbt](../../libavformat/playback.mbt)、[playback_dump.mbt](../../libavformat/playback_dump.mbt)：接通流信息、拆包、时长、时间戳与解码。PCM 支持 8/16/24/32 位有符号样本，含 AIFC `sowt`。`probe`、`dump-packets`、`decode-audio` 共用门面，无需再改 CLI 分发；[浏览器入口](../../demo/main.js) 新增 `.aifc` 音频分类（原已有 `.dts`、`.aif`、`.aiff`）。
- 能力概览见 [README](../../README.md)，移植记录见 [§517](../PORTING_HISTORY.md#L18488)。DTS-HD、其他 AIFC 压缩标签仍不支持；Speex 与 WMA Pro/Lossless 可作为后续独立移植片。

## 验证与接续

- `moon check --no-render`、`moon info libavcodec libavformat` 和 `git diff --check` 已通过。尚未单独运行下面的 `libavcodec` 用例。
- AIFF 门面三个 Wasm 用例已通过。FFmpeg 9.0.2 生成的 8 kHz 双声道 IMA4 样本，FFprobe 与 Wasm CLI 均得到每声道 256 样本，解码为 s16le 的 MD5 都是 `75b382cc32f516d57822864ac0a407fe`。本地样本如仍在，路径为 `_build/aiff_ima4_stereo.aifc`（不提交）。
- 裸 DTS 的 48 kHz 立体声文件已用 Wasm CLI `probe` 验证。修正 LE 同步字及探测优先级后，下方 `libavformat` 五个文件共 **23/23** 项 Wasm 测试通过，含 AIFF、DTS、既有 Matroska 和 ADPCM 回归。

```powershell
moon check --no-render
moon test libavformat/dts_demux_test.mbt libavformat/aiff_ima4_test.mbt libavformat/aiff_playback_test.mbt libavformat/playback_audio_codecs_wbtest.mbt libavformat/adpcm_facade_realdata_test.mbt --target wasm --no-render
moon test libavcodec/dca_realdata_test.mbt --target wasm --no-render
moon info libavcodec libavformat
```

注意：Windows 环境曾因 `libavcodec` 聚合测试命令行过长而无法运行，即使按文件指定。若复现，保留错误记录，优先用 `libavformat` 的 Wasm 门面测试验证链路；不要把未执行的测试记为通过。
