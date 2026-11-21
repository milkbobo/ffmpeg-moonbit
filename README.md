# MoonFFmpeg

用 MoonBit 移植 FFmpeg 9.0.2 的常用媒体处理功能，面向 WebAssembly。可以读取媒体信息、解码音视频、转码和封装文件。

## 编解码支持范围

截至 2026-11-21，主要格式的实现情况如下。

| 格式 | 解码 | 编码 |
| --- | --- | --- |
| H.264、HEVC（H.265） | 已实现 I/P/B 帧 | 已实现，可输出 MP4 |
| AV1 | 已实现关键帧、帧间帧及 film grain 等工具 | 已实现关键帧、帧间帧和多参考帧，目标码率控制待实现 |
| VP9 | 已实现 Profile 0–3 | 未实现 |
| MJPEG、PNG/APNG | 已实现，MJPEG 支持部分格式 | 未实现 |
| AAC | 已实现 AAC-LC、HE-AAC v1/v2，未覆盖 USAC | 已实现 AAC-LC |
| MP2、MP3、FLAC、ALAC、Opus | 已实现 | 已实现 |
| Vorbis、AC-3、E-AC-3、WavPack 等 | 已实现，E-AC-3 支持部分模式 | 未实现 |

**容器和工具**　支持读取 MP4/MOV、MKV/WebM、MPEG-TS、WAV、Ogg 等容器，可写入 MP4、WebM、MPEG-TS、WAV 等格式，也支持 HLS/DASH 分片读取、图像缩放和音频重采样。

**其他边界**　H.264 SP/SI、硬件加速、完整滤镜图和 DRM 密钥协商均未覆盖。各格式的具体限制和验证样例见[移植记录](doc/PORTING_HISTORY.md)。

## 运行浏览器 Demo

安装 MoonBit 工具链和 Python 3。在仓库根目录用 Bash 运行以下命令（Windows 可用 Git Bash）。

```sh
bash scripts/build_demo.sh
python -m http.server 8000 --directory demo
```

用支持 WasmGC 和 JS String Builtins 的浏览器打开 [本地 Demo](http://localhost:8000/)。点击「试用样片」或「选择文件」查看媒体信息，然后按需操作。

- **播放和截图**　点击「Wasm 播放」和「播放视频」，拖动进度条后可点「截取当前帧」。
- **导出音频**　选择 WAV 或 FLAC，点击「生成音频」，完成后下载。
- **转换视频**　选择 MP4（H.264 或 HEVC），点击「转换视频」。WebM 选项使用浏览器自带的编码器。

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
