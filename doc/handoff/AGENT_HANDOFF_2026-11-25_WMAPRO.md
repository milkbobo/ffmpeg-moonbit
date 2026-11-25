# WMA Pro（wmapro）解码器接手（2026-11-25）

## 当前状态

本片新增 WMA Pro 解码器，并接入统一播放 API 的 ASF 与 WAV 两条路径。记录见
[§518](../PORTING_HISTORY.md#L18494)。已连同上一片（[裸 DTS 与 AIFF/AIFF-C](AGENT_HANDOFF_2026-11-25_DTS_AIFF.md)）
按片提交到本地 `master`：

| 片 | 提交 | 内容 |
| --- | --- | --- |
| ① | `2481da0` | 裸 DTS 核心解复用与 AIFF/AIFF-C 播放（上一片的代码与测试） |
| ② | `9e91bd5` | WMA Pro 解码器 + 表 + 表生成器 |
| ③ | `d7ea625` | WMA Pro 接入 ASF / WAV / 门面 + 测试 + 夹具生成器 |
| ④ | 文档片（本文件所在提交） | README、PORTING_HISTORY §517–§518、agent.md §6、两份接手文档、体积探针 |

每一片都是在「工作树 = HEAD + 本片」的状态下过了 `moon check` 与该片测试再
提交的。`playback.mbt` 两片都改过：第 ① 片只含 DTS/AIFF 的改动（按块拆出），
WMA Pro 的部分随第 ③ 片。开工前就有的行尾幻影（`git status` 为 M 而
`git diff` 为空）不纳入，`git update-index --refresh` 后已消失。项目仍以纯
MoonBit/Wasm 为交付目标。

## 改动入口

- 解码器 `libavcodec/wmapro.mbt`（常量、位读取器、Huffman 表、结构体、逆 MDCT、
  加窗）、`wmapro_init.mbt`（`wmapro_decoder_new`、比例因子带表、余弦表）、
  `wmapro_decode.mbt`（分块头、声道变换、系数、游程解码）、`wmapro_subframe.mbt`
  （比例因子、逆变换、子帧、帧）、`wmapro_packet.mbt`（位缓冲池、包状态机、
  对外接口 `decode_packet` / `flush` / `last_error`）。表 `wmapro_tables.mbt` 由
  `scripts/gen_wmapro_tables.py` 从 `wmaprodata.h` 提取。
- 范围：WMAPRO 路径。XMA1/2、WMA Lossless、MP4/ISM 的 WMA Pro 样本条目未做。
- 容器：`libavformat/asf.mbt` 识别标签 0x0162，并放宽截断文件（Data Object
  声明大小超过文件长度时读到文件尾）；`libavformat/wav.mbt` 保持 0x0162 →
  `wmapro` 的映射，WMA 包的 pts 改为 NOPTS。
- 门面 `libavformat/playback.mbt`：`AudioDec::WmaPro`，`AsfAudio` 与
  `Wav(demux, _) if codec_id == "wmapro"` 两个来源；一个包含多帧，
  `decode_all` 逐步消费，单帧 `decode` 用队列保存余下帧；`flush` 不产出
  （见下）。
- 文档：README 能力表与 demo 导入说明、[§518](../PORTING_HISTORY.md#L18494)、
  `doc/agent.md` §6（本机参考 FFmpeg 的构建、UTF-16 日志、WAV 头长度、
  `AV_TX_FLOAT_MDCT` 的长度约定、VLC 码字分配、`GetBitContext` 钳制、
  `AV_CODEC_CAP_DELAY`、MoonBit 语法补充）、本文件。

## 验证与接续

```powershell
moon check --no-render
moon test libavformat/wmapro_realdata_test.mbt --target wasm --no-render
moon test libavformat/wmapro_realdata_test.mbt --target wasm-gc --no-render
moon test demo/api --target wasm-gc --no-render
python scripts/generate_wasm_size_probe.py
```

- 整模块 `moon check` 0 error / 0 warning；libavformat 逐文件全量回归 **184 个文件、
  777 项、0 失败**（含 DTS/AIFF 片的测试与既有 ASF、WAV、ADPCM 回归）；
  demo/api 26 项通过；体积探针重生成（670 个公开函数，含 DTS/AIFF 片的
  `av_dts_open`、`parse_dca_core_header`；wasm-gc gzip 914.8 KiB，wasm gzip
  1363.7 KiB）；`demo/api.wasm` 已重建。CLI `probe`、`dump-packets`、
  `decode-audio` 对 ASF 与 WAV 两种封装实跑通过。

- 两个 FATE 样本（`wmapro/Beethovens_9th-1_small.wma`、
  `wmapro/latin_192_mulitchannel_cut.wma`）整文件解码，对 FATE 自带的 s16 参考
  PCM 逐样本比较：180,224 个值里 35 个差 1 LSB，1,253,376 个值里 19 个差 1 LSB，
  长度完全相同（本机 wasm-gc CLI 与参考 FFmpeg 9.0.2 对比）。测试内嵌两个文件
  与抽样参考（每 97 / 251 个值），9 项在 wasm 与 wasm-gc 通过。
- 参考解码器：Docker 不可用，改为在本机用 WinLibs gcc 构建了 FFmpeg 9.0.2
  （`.scratch/wmapro_ff/src/ffmpeg.exe`，构建脚本 `build.sh` / `make.sh` 在
  `.scratch/wmapro_ff/`，做法见 `doc/agent.md` §6）。它对 FATE 自带参考的偏差
  同样不超过 1 LSB。生成器 `scripts/gen_wmapro_fixtures.py` 需要这个二进制
  （提取 ASF 包载荷、校验手工封装的 WAV）：`python -I scripts/gen_wmapro_fixtures.py
  libavformat [ffmpeg.exe]`。样本缺失时生成器会从 fate-suite.ffmpeg.org 下载。
- 调试时用过插桩的 C 副本逐量对比（系数、比例因子、IMDCT 输入输出、加窗输出
  在全部 106 个帧段上一致）；C 侧的插桩副本已还原，脚本留在
  `.scratch/wmapro_dl/instrument_c.py`，不在仓库里。
- 一个与参考解码器的已知口径差：`ff_wmapro_decoder` 没有
  `AV_CODEC_CAP_DELAY`，fftools 在流结束时不会要它的收尾帧；门面同样不产出，
  所以长度与 FATE 参考一致。解码器 API 的 `flush()` 会给出最后一个半帧（后半
  为 0），留给需要它的调用方。
- 后续候选：MP4/ISM 的 WMA Pro 样本条目（FATE `isom/vc1-wmapro.ism`，样本已
  在 `.scratch/wmapro_dl/`）、WMA Lossless（共用本解码器的上下文）、Speex。
