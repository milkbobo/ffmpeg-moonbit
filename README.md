# MoonFFmpeg

用 MoonBit 移植 FFmpeg 9.0.2 的常用媒体处理功能，面向 WebAssembly。可以读取媒体信息、解码音视频、转码和封装文件。

## 编解码支持范围

截至 2026-11-25，主要格式的实现情况如下。

| 格式 | 解码 | 编码 |
| --- | --- | --- |
| H.264、HEVC（H.265） | 已实现 I/P/B 帧 | 已实现，可输出 MP4 |
| AV1 | 已实现关键帧、帧间帧及 film grain 等工具 | 已实现关键帧、帧间帧、多参考帧、per-SB 64x64/32x32 分割与 NEARMV 栈复用，目标码率控制待实现 |
| VP9 | 已实现 Profile 0–3 | 未实现 |
| MJPEG、PNG/APNG | 已实现，MJPEG 支持部分格式 | 已实现 8 位 baseline MJPEG，以及 8/16 位 PNG 和全画幅 APNG |
| AAC | 已实现 AAC-LC、HE-AAC v1/v2，未覆盖 USAC | 已实现 AAC-LC |
| AMR-NB / AMR-WB | 已实现：裸 `.amr`/`.awb` 流与 3GP/MP4 中的 `samr`/`sawb` 轨（单声道；多声道与 SID 舒适噪声帧不支持）。对 FATE 的 17 个样本，AMR-NB 与 FFmpeg 自带浮点解码器的偏差不超过 2 LSB，AMR-WB 不超过该解码器自身的偏差 | 未实现 |
| MP2、MP3、FLAC、ALAC、Opus | 已实现 | 已实现 |
| APE（Monkey's Audio） | 支持读取 v3.80–3.99 文件及解码 | 未实现 |
| WMA v1/v2 | 支持从 ASF/WMA 文件解码 | 已实现编码器，输出 WMA 压缩包 |
| WMA Pro | 支持从 ASF/WMA 文件和 WAV（标签 0x0162）解码；对 FATE 的立体声与 5.1 样本，输出与参考 PCM 的偏差不超过 1 LSB。XMA 与 WMA Lossless 未实现 | 未实现 |
| DTS | 支持裸 `.dts` 及 Matroska 中的 DTS 核心解码；不支持 DTS-HD 扩展 | 未实现 |
| AIFF / AIFF-C | 支持 8/16/24/32 位有符号 PCM（含 `sowt`）和 Apple IMA4 的解封装与播放 | 支持写入 PCM AIFF |
| MLP、TrueHD | 支持裸码流解码和 Matroska 播放 | 未实现 |
| Vorbis | 支持 Ogg 解码 | 支持实验性编码和 Ogg 封装，首包与 FFmpeg 原生编码器逐字节一致 |
| AC-3、E-AC-3 | 支持裸码流和 Matroska 解码，E-AC-3 支持部分模式 | AC-3 定点编码已实现，48 kHz 双声道参考流与 FFmpeg `ac3_fixed` 位级一致 |
| WavPack | 支持单声道和立体声无损整数解码 | 支持 16、24、32 位单声道和立体声无损编码，输出完整 `.wv` 文件 |
| Shorten | 支持 `.shn` 无损整数解码，可用 `decode-audio` 转 WAV | 未实现 |
| Musepack | 支持 SV7 立体声和 SV8 单声道、立体声 `.mpc` 解码，可用 `decode-audio` 转 WAV | 未实现 |
| Cook（RealAudio G2） | 支持从 RealMedia 容器解码单声道、立体声和联合立体声 | 未实现 |
| RealAudio 14.4 / 28.8 | 支持从 RealMedia 容器解码；RA 14.4 整文件输出与 FATE 参照位级一致 | 未实现 |
| SIPR（RealAudio SIPR / ACELP.NET） | 支持从 RealMedia 容器解码 5k0、6k5、8k5、16k 四种模式 | 未实现 |
| ADPCM（MS、IMA WAV、IMA OKI、Yamaha、IMA QuickTime） | 已实现：WAV 中的 MS（1–6 声道）、IMA WAV（2/3/4/5 位码）、Dialogic OKI、Yamaha，MOV/MP4 中的 `ms\x00\x02` / `ms\x00\x11` / `ima4`。解码输出与 FFmpeg 9.0.2 的 `adpcm.c` 位级一致 | 未实现 |

**容器和工具**　支持读取 MP4/MOV、MKV/WebM、MPEG-TS、WAV、Ogg、ASF/WMA、RealMedia（RM/RA）等容器，可写入 MP4、WebM、MPEG-TS、WAV 等格式，也支持 HLS/DASH 分片读取、图像缩放和音频重采样。

**其他边界**　H.264 SP/SI、硬件加速、完整滤镜图和 DRM 密钥协商均未覆盖。各格式的具体限制和验证样例见[移植记录](doc/PORTING_HISTORY.md)。

### 图像编码

```sh
moon run --target wasm cmd/encode-image -- png rgba 320 240 frame.rgba frame.png
moon run --target wasm cmd/encode-image -- apng rgba 320 240 frames.rgba animation.apng 12
moon run --target wasm cmd/encode-image -- mjpeg rgb24 320 240 frames.rgb output.mjpeg 85
```

输入为紧密排列的原始像素。PNG 接收一帧，APNG 和 MJPEG 接收连续帧。APNG 的末尾参数是帧率，MJPEG 的末尾参数是 JPEG 质量（1–100）。PNG/APNG 支持灰度、灰度带 alpha、RGB 和 RGBA，16 位样本使用大端序。MJPEG 接收 `gray`、`rgb24`、`yuvj420p` 或 `yuvj444p`。

## 运行浏览器 Demo

安装 MoonBit 工具链和 Python 3。在仓库根目录用 Bash 运行以下命令（Windows 可用 Git Bash）。

```sh
bash scripts/build_demo.sh
python -m http.server 8000 --directory demo
```

用支持 WasmGC 和 JS String Builtins 的浏览器打开 [本地 Demo](http://localhost:8000/)。点击「试用样片」或「选择文件」查看媒体信息，然后按需操作。

- **播放和截图**　视频可切换「Wasm 播放」后定位并截图，也可用 MoonBit 把首帧导出为 PNG 或 JPEG。音频文件可用「Wasm 播放」解码成 WAV 在页面试听。
- **导入音频**　支持 APE、ASF/WMA（含 WMA Pro）、WAV 里的 WMA Pro（标签 0x0162）、WavPack、Shorten、Musepack SV7/SV8、RealMedia/RealAudio（RA 14.4、RA 28.8、Cook、SIPR 音轨，含带视频轨的 RM/RMVB）、AMR-NB/AMR-WB（`.amr`、`.awb` 与 3GP 的 AMR 音轨）、ADPCM（WAV 里的 MS / IMA / OKI / Yamaha，MOV/MP4 里的 MS / IMA / `ima4`），以及 AIFF/AIFF-C（PCM、Apple IMA4）、裸 `.dts` 核心流和 MLP/TrueHD 裸流。Matroska 文件可读取 DTS 核心、AC-3、E-AC-3 和 MLP/TrueHD 音轨。
- **导出音频**　选择 WAV、FLAC、WavPack、AC-3 或 Ogg/Vorbis，点击「生成音频」。WavPack 导出为 16 位单声道或立体声。AC-3 支持 32、44.1 和 48 kHz 的单声道或立体声，末帧补齐到 1,536 个样本。实验性 Ogg/Vorbis 输出需要立体声。
- **音频后期处理**　展开音频导出下的「音频后期处理」，可加淡入淡出、去除首尾静音、按目标 LUFS 调整音量，或添加第二条音轨混音。响度归一化和混音支持单声道与立体声。
- **分析音轨**　点击「分析音轨」，查看首条音轨的波形、采样峰值和静音区间。单声道和立体声可测整体响度（LUFS）。
- **视频缩略图**　选择最多取 6、12 或 24 帧，下载带时间戳的 PNG 总览，或生成每帧停留 0.5 秒的 APNG 循环动图。
- **字幕**　打开带文本字幕的 MP4（mov_text）或 MKV（UTF-8），在预览区选轨播放，并可导出 SRT 或 WebVTT。
- **视频故障检测**　点击「检测视频」，查看黑场、画面冻结和首条音轨静音，点击结果定位。
- **关键帧裁剪与拼接**　导入 H.264 MP4（可带一条 AAC 音轨），输入裁剪范围，或添加参数一致的后续片段。导出时复制音视频压缩包，裁剪结果显示对齐到 IDR 后的实际区间。
- **转换视频**　选择 MP4（H.264、HEVC 或实验性 AV1），点击「转换视频」。AV1 最多处理 120 帧，等比缩放后居中补边，输出长边最多 512 像素。WebM 选项使用浏览器自带的编码器。

Demo 支持单文件最多 64 MiB，拼接最多 8 段、合计 96 MiB。耗时处理可点击「取消处理」或切换文件，超时也会自动停止。HEVC 采用批量解码，能处理的时长随画面分辨率而缩短。

项目目标与后续计划见[项目申报书](doc/项目申报书.md)。

## 源码分发与专利声明 / Source-only distribution and patent notice

**本项目仅以源代码形式开源发布。** 维护者不对外提供或分发 WASM 编译产物、二进制文件、可执行程序、静态库、动态库、`bin/` 目录中的编译产物、预编译包或其他预构建制品。下文构建和测试命令供使用者自行在本地构建。

**本项目包含 H.264/AVC、HEVC/H.265、AAC 等解码器实现，相关技术可能受第三方专利保护。** 源码公开不代表已取得专利许可，也不保证免许可、免版税或不侵权。仅分发源码可减少与预编译产物分发相关的合规负担，但不免除源码分发的许可证义务，也不消除专利或其他法律风险。

**This project is released as source code only.** The maintainers do not publicly provide or distribute WASM build artifacts, binaries, executables, static or shared libraries, compiled artifacts under `bin/`, precompiled packages, or other prebuilt artifacts. The build and test commands below are for local builds by users.

**This project includes decoder implementations such as H.264/AVC, HEVC/H.265, and AAC, whose technologies may be covered by third-party patents.** Source availability does not establish patent clearance or guarantee license-free, royalty-free, or non-infringing use. Source-only distribution can reduce compliance burdens associated with prebuilt artifacts, but does not remove source-distribution obligations or eliminate patent or other legal risks.

本政策不限制适用开源许可证授予的权利。除适用许可证明确授予的专利权利外，本声明不授予额外专利许可。详见 [LICENSE.md](LICENSE.md) 与 [LEGAL.md](LEGAL.md)。

This policy does not restrict rights granted under applicable open-source licenses. Except for patent rights expressly granted under applicable licenses, this notice grants no additional patent license. See [LICENSE.md](LICENSE.md) and [LEGAL.md](LEGAL.md).

### ⚠️ 历史版本提示 / Historical version notice

本仓库早期开发提交未包含专利风险提示。截至本声明更新之日（2026-10-29），所有历史提交快照仅为开发过程中的中间版本，不作为项目正式发行版本。

无论检出任何版本代码，使用者均应自行评估编译、分发及运行相关产物涉及的专利与许可要求，并承担其自身行为依法产生的相应责任。**商用前请自行进行专利与许可证合规评估，并在必要时取得授权。**

历史版本未包含提示，不表示不存在专利风险或已获得相关授权。“非正式发行版本”的描述不否认代码曾被公开或分发，也不撤销既有义务；本声明不免除维护者依法承担的责任，不修改适用开源许可证。

Early development commits in this repository did not include a patent-risk notice. As of this notice's update date (2026-10-29), all historical commit snapshots are intermediate development versions and are not designated as formal project releases.

Regardless of which version is checked out, users should independently assess the patent and licensing requirements associated with compiling, distributing, and running the resulting artifacts, and bear the responsibilities arising under applicable law from their own activities. **Before commercial use, conduct a patent and license compliance assessment and obtain authorization where required.**

The absence of a notice in historical versions does not establish the absence of patent risks or the existence of authorization. Describing a version as an informal development snapshot does not deny that code was made public or distributed, or discharge existing obligations. This notice does not exempt maintainers from their legal responsibilities or amend applicable open-source licenses.
