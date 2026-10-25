# AI Agent 交接文档（2026-10-24）

> 交接对象：下一个接手本仓库的 AI/协作者。
> 仓库：`D:\project\FFmpeg-n9.0.2\moonbit`（Windows 10 + Git Bash）
> 远端：`github.com:milkbobo/ffmpeg-moonbit.git`，分支 `master`
> 当前 HEAD：`0ae19ea feat: VP9 新增复合预测诊断计数器并转正 alt-ref 向量测试`
> 全量 Wasm 测试：**869/869 通过**；`moon check --deny-warn` 0 error / 0 warning。

先读这几份文档，再动手：

1. [README.md](README.md)：能力矩阵、边界、构建/测试命令（动态进度以它为准）。
2. [agent.md](agent.md)：稳定约定、目录结构、历史踩坑。
3. [PORTING_HISTORY.md](PORTING_HISTORY.md)：逐次增量的实现与验收记录（共 45 节）。
4. [AV1_AGENT_HANDOFF.md](AV1_AGENT_HANDOFF.md)、[H264_AGENT_HANDOFF.md](H264_AGENT_HANDOFF.md)：两条大解码链路的专题交接。
5. 本文：**当前状态、下一步优先级、验证流程与禁止事项**。

---

## 1. 任务背景

原始需求（中文）：用 MoonBit 继续迁移 FFmpeg 9.0.2 的功能：

- 解码：H.264 + HEVC + AV1 + VP9 + MJPEG + PNG
- 音频：AAC + MP3 + Opus（另有 FLAC）
- 容器：MP4、MKV、TS、HLS、DASH、WebM、WAV

策略：只移植**纯算法**部分，逐模块对照 FFmpeg 9.0.2 源码；像素/PCM 验收一律以
docker `linuxserver/ffmpeg:9.0.2` 的 framemd5 / 原始 PCM 为基准。用户偏好：
自主推进、每个增量中文提交并推送，不需要逐次询问。

---

## 2. 当前能力（截至 HEAD）

### 视频解码

| 编解码器 | 已覆盖 | 已知缺口 |
| --- | --- | --- |
| H.264 | I/P/B、CAVLC/CABAC、8/9/10/12/14-bit、单色、4:2:0/4:2:2/4:4:4、多 slice、MBAFF/PAFF、DPB、SEI、去块；Annex B 与 MP4 `avcC` 入口；渐进帧/MBAFF 错误补偿 | 高位深与 P 帧大缺口下的错误恢复未逐像素对齐；SP/SI 明确不做；FMO/数据分区/separate colour plane 上游不支持 |
| HEVC | I/P/B、8/10/12-bit、多种色度与单色、多 slice、WPP、tiles、去块、SAO、scaling list、transform skip（RDPCM 拒绝） | dependent slice、tiles 与 WPP 组合、PCM/RDPCM 未做 |
| AV1 | 8/10/12-bit 多 tile 无损关键帧；8-bit 4:2:0 **有损关键帧**（全变换核 + 环路去块滤波 + CDEF + delta-q） | 环路恢复、高位深有损、帧间帧；入口显式报错 |
| VP9 | profile 0/1/2/3、8/10/12-bit、4:2:0/4:2:2/4:4:0/4:4:4、关键帧与 P 帧、三路参考、插值滤波、概率自适应 | 参考帧缩放（scaled reference）；复合预测代码已存在但文档仍写“编码器无法生成”，需进一步确认 |
| MJPEG | SOF0/SOF1/SOF2（含渐进）、4:2:0/4:2:2/4:4:4、灰度 | 算术编码、无损 JPEG、12-bit |
| PNG/APNG | 8/16-bit、调色板、1/2/4-bit、Adam7、APNG 合成 | 无重大缺口 |

### 音频解码

- AAC-LC：完整 PCM 链路（ICS/TNS/PNS/耦合/立体声/瞬时/960 帧长）；**SBR/PS/USAC 未覆盖并显式拒绝**。
- MPEG 音频：Layer I/II/III，含 LSF（MPEG-2/2.5）。
- FLAC：constant/verbatim/fixed/LPC、4 种立体声模式。
- Opus：SILK/混合/CELT、多流包；**PLC（丢包隐藏）未实现**。

### 容器

- 解复用：MP4/MOV（含 fMP4 `moof/traf/tfhd/tfdt/trun/trex`、sidx/mfra、cenc、edit list、
  多 sample description）、Matroska/WebM、MPEG-TS（H.264/HEVC/AAC/MP3）、Ogg/Opus、
  WAV、裸 ADTS AAC/MP3、HLS M3U8、DASH MPD。
- 复用：
  - MP4：AAC、H.264、HEVC、AV1、VP9、Opus、H.264+AAC 双轨。
  - Matroska：H.264、H.264+AAC；WebM：Opus、VP9、VP9+Opus、AV1。
  - MPEG-TS：H.264+AAC 双流（PAT/PMT/PCR/PES）。
  - WAV：PCM 8/16/24/32-bit、float32、extensible。
  - ADTS AAC；Ogg/Opus。
  - HLS 主/媒体播放列表；DASH SegmentTemplate MPD。
  - **fMP4**：单轨初始化段 + 媒体段，支持 H.264/HEVC/AV1/VP9/AAC/Opus。
- fMP4 限制：每段单轨（视频或音频各自成 Representation）；无 `sidx`、无多轨同段、
  无加密；`base_decode_time`/每样本 duration/keyframe 由调用方给出。

---

## 3. 关键 API 速查

### 解码器入口

```text
H.264: h264_decode_annexb_frames / h264_decode_avc_frames
       h264_decode_annexb_display_frames / h264_decode_avc_display_frames
HEVC:  hevc_decoder_new() + ff_hevc_decode_frames[_ex]
       ff_hevc_decode_intra_frame[_unfiltered]
AV1:   av1_parse_sequence_header / av1_parse_frame_header / av1_extract_tiles
       av1_decode_keyframe(s, hdr, tile) / av1_decode_keyframe_tiles(s, hdr, tiles)
VP9:   vp9_decoder_new() + decode_packet(pkt) + frame_bytes()
AAC:   aac_parse_audio_specific_config / new_aac_decoder_from_asc
       new_aac_decoder(config, n) + 逐包解码
MP3:   new_mp3_decoder() / decode_mp3_stream(data)
FLAC:  ff_flac_decode(data)
Opus:  OpusDecoder::decode_packet
```

### 容器入口

```text
av_mov_open / av_mov_open_with / av_mov_open_avio
av_matroska_open / av_mpegts_open / av_ogg_opus_open
av_wav_open / av_adts_open / av_mp3_open
av_hls_parse / av_dash_parse
```

### 复用入口（均在本包内，测试直接调用）

```text
fmp4_h264_init_segment / fmp4_hevc_init_segment / fmp4_av1_init_segment
fmp4_vp9_init_segment / fmp4_aac_init_segment / fmp4_opus_init_segment
fmp4_media_segment(track_id, sequence_number, base_decode_time, samples)
ts_muxer_new / write_video / write_audio / finish
wav_muxer_*、ogg_opus_mux_*、mp4_*_muxer_new、webm_*、mkv_*、hls_*、dash_*
```

---

## 4. 下一步优先级建议

**2026-10-24 晚间更新**：原清单前 3 项已全部完成（提交 `5b0a7c8`、
`5113d54`、`0ae19ea`），详见 PORTING_HISTORY 第 46–48 节：

- ✅ MPEG-TS `ts_muxer_new` 新增 `video_stream_type`/`audio_stream_type`
  （默认 0x1B/0x0F 兼容），HEVC+MP3 回读与 ffmpeg framemd5 全一致。
- ✅ `webm_{vp9,av1,opus}_muxer_new` 新增 `doctype` 参数（webm/matroska）；
  同轮对齐 ffmpeg `matroskaenc.c` 的 Opus 语义（CodecDelay/SeekPreRoll/
  ts_offset 补偿），三类 .mkv 经 ffprobe 识别 + 解码对拍全一致。
- ✅ VP9 新增 `comp_inter_blocks` 诊断计数器；alt-ref 21 包码流证实
  `comp_pred_mode` 全 0（libvpx 不触发复合块），向量已转正为
  `vp9_vectors/vp9_altref_test.mbt`。

剩余优先级（按"可独立验收 + 风险"排序）：

1. **AV1 CDEF / 环路恢复 / 高位深有损 / 帧间**（有损关键帧已于 2026-10-25 收敛，
   见 PORTING_HISTORY §52 与 `AV1_AGENT_HANDOFF.md` §7）
   - 8-bit 4:2:0 有损关键帧（含 LF、CDEF、delta-q）已与 libdav1d framemd5 完全一致；
     LR 语法层已就位但滤波核未移植，`lr_type`/delta_lf 生效时入口显式拒绝。
   - 下一步：LR 滤波核 → 高位深有损 → 多 tile/128 SB → 帧间。

2. **AAC SBR/PS**
   - 工作量大（QMF、包络/噪声、patch、HF 生成、PS）；先确认 docker 镜像是否有可用的
     HE-AAC 编码器（大概率没有 libfdk_aac），否则需要外部样本。

3. **HEVC dependent slice / tiles+WPP / PCM / RDPCM**
   - tiles+WPP：FFmpeg 9.0.2 的单线程路径对组合情形的处理本身可疑（`ctb_addr_ts %
     ctb_width` 与 tile scan 不完全对应），先确认上游能否正确解码再决定是否跟进。

4. **VP9 参考缩放**
   - 复合预测已证实编码器无法触发（见上）；剩余工作是参考帧缩放
     （`mc_*_scaled` 的移植），需自己构造不同分辨率的参考链或用外部样本。

5. **H.264 错误恢复残余**
   - 不要基于 `.scratch/h264_er_trunc_p_mid.yuv` 改去块：该参考不可复现（新旧参考
     frame 0 一致、1–5 不一致）。先用脚本重新生成干净 fixture，再复现残差。

6. **Opus PLC**
   - 无位精确上游基准（FFmpeg 原生 opus 解码器不实现 PLC），优先级最低。

---

## 5. 构建、测试与验证

### 必跑命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render
moon test --target wasm --no-render -p libavformat -f "fmp4*"
```

- `-f` 是**测试名 glob**，不是文件名；`"fmp4*"` 才匹配。
- 提交前必须全量测试通过；文档中的测试计数要同步更新（README 顶部与验证段落）。
- `moon info --target wasm` 会生成 `pkg.generated.mbti`，**不要提交**。

### 参考实现与 Docker

```sh
MSYS_NO_PATHCONV=1 docker run --rm -v "D:/abs/path:/s" -w /s \
  linuxserver/ffmpeg:9.0.2 -v error -i in.ivf -f framemd5 ref.md5

# ffprobe 需要改 entrypoint
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint ffprobe -v "...:/s" -w /s \
  linuxserver/ffmpeg:9.0.2 -v error -show_entries stream=codec_name -of default=nw=1 in.mp4
```

- Windows Git Bash 下**必须** `MSYS_NO_PATHCONV=1`，否则 `-v` 路径被改写。
- ffmpeg 默认不覆盖输出，重跑加 `-y` 或先删旧文件。
- 生成真实码流的完整命令写在各 `*_realdata_wbtest.mbt` 的文档注释里；批量向量
  生成脚本在 `scripts/`（`_emit_*`、`_gen_*`、`generate_*`）。

### 新增真实向量测试的流程

1. 用 docker ffmpeg 生成码流与 `framemd5`。
2. 把码流 base64 内嵌到测试（小向量直接放 `libavcodec/<codec>_realdata_wbtest.mbt`；
   大向量放到独立包，如 `vp9_vectors/`、`av1_vectors/`、`av1_tiles_vectors/`）。
3. 逐帧解码并与 framemd5 比对；错误信息带上帧号。
4. 如果是新容器/复用器：先 `av_*_open` 回读验证，再写临时探针把产物 base64 打印出来，
   在 Python 侧拼文件后用 ffmpeg 解码做外部校验；探针用完移到 `.trash/<date>/`。

### 最近一次外部校验方法（可复用）

- fMP4：临时 wbtest 打印 `VIDEO/AUDIO <b64>`，Python 拼接 → ffprobe 识别 codec →
  `ffmpeg -f framemd5` 对比源 MP4；Opus 对比 WAV PCM 时注意 pre-skip（312）与
  AAC 首帧 priming（1024）。
- 结论：H.264 6 帧完全一致；HEVC/AV1/VP9 前 3 帧完全一致；AAC 去掉首帧 priming
  后逐样本一致；Opus 去掉 pre-skip 后逐样本一致。

---

## 6. 约定与禁止事项（重要）

- 提交信息用中文，格式沿用 `feat: ...` / `fix: ...` / `docs: ...`。
- 每个增量完成后**直接** `git push origin master`，无需询问（用户长期授权）。
- **不要提交**：`pkg.generated.mbti`、`.scratch/`、`.trash/`、`_build/`。
- 清理文件用“移动到 `.trash/<日期>/`”，不要直接删除（仓库 hook 会拦截 `del`/`rm` 文本）。
- 每次提交前跑全量测试与 `moon check --deny-warn`，并更新 README/PORTING_HISTORY。
- 当前工作区有两个**既有未提交**脚本改动（`scripts/_av1_kf_test_body.tpl`、
  `scripts/_gen_av1_kf_vectors.py`），与本轮无关，**不要顺手提交**。

---

## 7. 已知坑（MoonBit / FFmpeg / 容器）

### MoonBit / 工具链

- Wasm 包的 `__init` 有局部变量数量上限：大 base64 字面量放独立测试包，或把多个流
  合成一个常量再切片。
- `String::to_bytes` 按 UTF-16 处理；二进制字面量 `b"\x80"` 在生成代码里可能变成
  UTF-8 字节，二进制数据一律用 `Bytes::from_array([...])` 或 base64 解码。
- 本工具链里 `Int` 与 `Int32` 基本同型；`UInt32::to_int()` 已废弃，用
  `reinterpret_as_int()` / `reinterpret_as_uint()`。
- 方法定义写 `Type::method`，`fn method(self : Type)` 已废弃。
- 移位量会按类型宽度掩码（Int 为 31），EBML/64 位长度用 `Int64` 或最小 VINT。
- 结构体字面量在数组参数中依赖上下文推断；必要时显式构造函数。
- 观察到的坑：局部变量名 `opus` 曾触发解析错误（改名 `opus_pkts` 解决）；`as`
  也建议避开。
- `Result` 没有 `?` 运算符；用 `match`。

### FFmpeg / 容器

- `av_crc` 是非反射语义，**不能**直接用于 Ogg CRC；`ogg.mbt` 内是自实现。
- MP4 `avcC`/`hvcC`/`av1C`/`vpcC` 参数是**裸记录**（不含 box 头）；从 ffmpeg 产物
  提取时要剥掉 4 字节 size + 4 字节 type。
- fMP4 `trun.data_offset` 相对 `moof` 起点；`tfhd` 用 `default-base-is-moof`。
- AudioSampleEntry 子 box 偏移是 entry body + 28；QuickTime version-1 音频条目
  另有扩展字段，但 `stsd` 里 `hvc1/avc1/av01/vp09` 为 +78。
- Opus `dOps` 字段：version(1)、channels(1)、pre_skip(2)、input_sample_rate(4)、
  gain(2)、mapping family(1)。
- 容器时间基：MP4 视频常用 90000，AAC 用采样率，Opus 用 48000。
- 测试里的 frame MD5：视频用 `frame_bytes()`/`packed()` 的平面紧凑输出；音频直接
  对 PCM 字节做 MD5，注意 priming/pre-skip 的偏移。

---

## 8. 当前工作区状态

```text
HEAD  0ae19ea  feat: VP9 新增复合预测诊断计数器并转正 alt-ref 向量测试
      bfacdd8  feat: 新增 fMP4 初始化段与媒体段写入器
      12035a1  feat: 新增 HLS 主播放列表写入器
```

- 工作树仅剩两条既有脚本修改（见 §6），可忽略。
- `.scratch/` 下保留了本轮验证用的源 MP4、fMP4 产物与 dump 输出（未跟踪，可复现）。
- `.trash/2026-10-24/` 存放用过的临时探针（`fmp4_dump_wbtest.mbt`、
  `fmp4_codec_dump_wbtest.mbt`、`vp9_altref_probe_wbtest.mbt` 等），可参考其写法。

---

## 9. 接手后的验收基线

```sh
moon check --target wasm --deny-warn --no-render   # 期望：0 error / 0 warning
moon test --target wasm --no-render                # 期望：869/869
git log --oneline -1                               # 期望：0ae19ea 或更新
```

达标后再开始新增量；每个增量结束重复上面的命令并更新文档。
