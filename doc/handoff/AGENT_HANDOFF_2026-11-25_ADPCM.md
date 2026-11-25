# ADPCM 接手（2026-11-25）

## 最新接手状态

本会话（「继续迁移常用音频格式」第四片）把仓库里已有但没接线的 ADPCM 块解码器补齐，
并接入统一播放 API（WAV 与 MOV/MP4）。**工作区改动尚未提交**（仓库约定：仅在用户明确
要求时提交）；AMR 那一片（见 `AGENT_HANDOFF_2026-11-25_AMR.md`）同样仍未提交。记录见
`doc/PORTING_HISTORY.md` §516。

### 已完成

- `libavcodec/adpcm.mbt`（在原文件上扩展，没有重写）：
  - 新增 `adpcm_ima_oki`（`decode_oki` / `adpcm_oki_expand` / 49 项
    `adpcm_oki_step_table`）；
  - IMA WAV 2 / 3 / 5 位码宽：`adpcm_ima_block_sizes` {4,12,4,20}、
    `adpcm_ima_block_samples` {16,32,8,32}、`adpcm_index_table2/3/5`，LSB 先行的
    `AdpcmLeBits`，`adpcm_ima_expand_wide`，`decode_ima_wav` 的非 4 位路径；
  - MS 3–6 声道：`decode_ms_planar`（每通道 7 字节头紧跟自己的数据）；
  - `adpcm_decoder_new(codec, channels, block_align~, bits_per_coded_sample~)`；
    OKI / Yamaha ≤ 2 声道，MS ≤ 6，IMA WAV 码宽 2..=5；
  - `packet_consumed(packet_size)`；`decode_block` 只对 ms / ima_wav 按
    `block_align` 截断；OKI / Yamaha 允许 `nb_samples ≥ 1`。
  `AdpcmImaQtDecoder` / `adpcm_ima_qt_decoder_new` 未改。
- `libavformat/playback.mbt`：`AudioDec::Adpcm` / `AdpcmImaQt`；`AudioDecoder::open`
  接 `adpcm_ms|adpcm_ima_wav|adpcm_ima_oki|adpcm_yamaha|adpcm_ima_qt`（通用 open 对
  ms / ima_wav 报 `UnsupportedCodec`，因为缺 `block_align`）；
  `MediaFile::audio_decoder` 按来源分发 `Wav(demux, _)`（`format.block_align` /
  `format.bits_per_sample`）与 `Mov(movie, _)`（`track.bytes_per_frame`，bits = 4）；
  `decode_all` 按 `packet_consumed` 循环消费整包。
- `libavformat/codec_tags.mbt`：`mov_wav_fallback_codec`（`ms\x00\x??` → WAV 标签
  byte3 | byte2 << 8），`mov_codec_name` 使用它。
- `libavformat/mov.mbt`：`bps` 匹配对 `adpcm_ms` / `adpcm_ima_wav` / `adpcm_ima_oki` /
  `adpcm_yamaha` / `adpcm_ima_qt` 一律给 `bits_per_sample = 4`（对齐
  `av_get_bits_per_sample`）。
- C 参照 `scripts/adpcm_c_ref/`（`adpcm_ref.c` + `build.cmd`，mingw gcc 编译上级目录的
  `adpcm.c` / `adpcm_data.c` 原样源码）；`.gitignore` 加 `scripts/*_c_ref/*.exe` 与
  `__pycache__/`。
- 测试 `libavformat/adpcm_facade_realdata_test.mbt`（生成器
  `scripts/gen_adpcm_fixtures.py`，9 个用例，wasm 与 wasm-gc 全过）：
  FATE `oki/test.wav` 整文件（FATE md5 `641049800e735b62e975baacc9a011a4`）；
  从 qt-surge-suite 的 `surge-2-16-L-ms02.mov` / `ms11.mov` 抽 48 个真实块，分别封成
  WAV 与带 `ms\x00\x02` / `ms\x00\x11` 条目的 MOV；MS 单声道 / 6 声道、IMA 3 位、
  Yamaha 的合成 WAV。合成用例的期望值是 C 参照解码同一批块的 s16le MD5。
- `libavcodec/adpcm_crafted_test.mbt`：MS 7 声道 / OKI 3 声道 / IMA 码宽 1、6 被拒；
  6 声道 MS 与 3 位 IMA 的输出长度；单字节 Yamaha 包给出 1 个样本帧（与 C 一致，
  原断言“报错”是错的）。
- README（能力表 ADPCM 行、demo 导入说明）、`doc/PORTING_HISTORY.md` §516、
  `doc/agent.md` §6（base64 字面量、init-locals 分片、MOV `ms\x00` 回退、各家包长口径）。

### 验证

```powershell
moon check --no-render
moon test libavformat/adpcm_facade_realdata_test.mbt --target wasm --no-render
moon test libavformat/adpcm_facade_realdata_test.mbt --target wasm-gc --no-render
moon test libavformat/adpcm_realdata_wbtest.mbt --target wasm-gc --no-render
moon test libavformat/ima_qt_realdata_wbtest.mbt --target wasm-gc --no-render
# 全量（逐文件，约 4 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File .scratch/realmedia_dl/regress.ps1 -Log .scratch/adpcm_dl/regress_full.log
```

`libavcodec/adpcm_crafted_test.mbt` 在本机不能直接跑（命令行超长）；把内容复制到
`libavformat/` 下加 `zz` 前缀跑一遍即可（本会话这么验证过，2/2 通过）。

重新生成夹具（需要 gcc 与上级 FFmpeg 源码树，会从 fate-suite.ffmpeg.org 下载两个
surge MOV 与 OKI WAV 到 `.scratch/adpcm_dl/`）：
`python -I scripts/gen_adpcm_fixtures.py libavformat`。

差分 / 整链对拍脚本在 `.scratch/adpcm_dl/`：`difftest.py`（8 种子 × 80 随机包，
逐帧位级一致）、`chain.py <file>`（门面解码 MD5 对 C）。

### 接续

1. 本片未覆盖：ADPCM 的其他变体（EA 系列、Xbox、DK3/DK4、THP、SBPRO、SWF、PSX 等
   `adpcm.c` 里 30 多个 CASE），它们在常用格式里出现得少；需要时在 `adpcm.mbt` 里按
   同样的 C 参照流程加。
2. 候选后续：Speex（Ogg Speex 头 + `speexdec.c` 浮点）、WMA Pro / Lossless、
   `adpcm` 在 AVI / WMV 之外的容器（AIFF 的 IMA4、`ima4` 在 FATE 里还有 WAV 变体）。
3. Docker 本会话仍未起来；C 参照的做法继续可用（`scripts/adpcm_c_ref/build.cmd`）。
4. 提交分片建议：(1) `libavcodec/adpcm.mbt` + `adpcm_crafted_test.mbt`；(2) 门面 /
   MOV 映射（`playback.mbt`、`codec_tags.mbt`、`mov.mbt`）+ 测试 + 生成器 + C 参照 +
   `.gitignore`；(3) README / PORTING_HISTORY / agent.md / 本文件。AMR 那片另见其接手
   文档的三片。`git status` 里 `git diff` 为空的幻影 M 不纳入。
