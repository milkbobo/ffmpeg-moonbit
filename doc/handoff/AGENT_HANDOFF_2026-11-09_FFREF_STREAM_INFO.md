# AGENT_HANDOFF_2026-11-09 — ffref 流元数据预言机：容器×编解码矩阵对拍加固（§372）

> 上下文：FFmpeg 9.0.2 → 纯 MoonBit 移植。本轮按「加固 ffref C FFI 预言机」
> 方向推进，走完 `moonbit-c-binding` / `make-moonbit-c-bindings` 的完整流程
> （survey 上游 ABI → 设计安全 API → FFI 边界 → native 差分测试 →
> ASan / `moon info` 验证）。**纯 MoonBit 路线不变**：新入口只在
> native-only 的 `ffref/` 测试预言机包内，没有新增任何运行时对 C 库的依赖。
> §370 / §371 的 AAC 未提交工作树一行未碰。

## 一、为什么做这一片

原有 `ffref_probe` / `ffref_probe_path` 只回报**包序列**（stream_index、
keyframe、pts、dts、size、timebase），看不到「播放器选解码器之前」的流表。
因此容器侧的 codec 名、几何、采样率、声道数、extradata 一直是自测
（`container_codec_matrix_realdata_test.mbt`）而非与真 FFmpeg 对拍。

本片补上这个维度，覆盖用户清单里的 7 种容器 × 6 种视频解码 + 3 种音频
+ PCM：MP4 / fMP4、MKV、WebM、TS、Ogg、WAV（+ HLS/DASH 已有路径式逐包
对拍，见后续建议）。

## 二、新增 C FFI 入口 `ffref_stream_info`

- **`ffref/ffref_stub.c`**：新增
  `MOONBIT_FFI_EXPORT moonbit_bytes_t ffref_stream_info(moonbit_bytes_t data)`。
  复用 `open_input`（内含 `avformat_find_stream_info`），逐流读
  `AVCodecParameters`：`avcodec_get_name(codec_id)`、`codec_type`、
  `width/height`、`sample_rate`、`ch_layout.nb_channels`、
  `extradata(_size)`。
- **blob 布局（小端）**：`n_streams i32` → 每流 32B 固定头
  （type / w / h / sr / ch / codec_len / extra_len / flags）→ 所有 codec
  名拼接 → 所有 extradata 拼接。两段变长区都在**全部固定头之后**，
  MoonBit 侧两个单调游标即可解析，无需长度前缀表。
- **所有权**：`#borrow(data)` —— `open_input` 的 `MemIO` 在本次调用内
  malloc/free，C 不长期持有指针；返回 `moonbit_make_bytes`，失败
  `NULL` → `None` → `FFRefError::OracleFailed`。
- **`ffref/ffi.mbt`**：私有 extern `ffref_stream_info_ffi`。
- **`ffref/ffref.mbt`**：`pub(all) struct FFRefStream` +
  `pub fn ffref_stream_info(data) -> Array[FFRefStream] raise FFRefError`；
  codec 名用 `@utf8.decode_lossy` 还原。
- **`ffref/moon.pkg`**：utf8 import 从 `for "test"` 提到主 import 块
  （`ffref.mbt` 现在要用），`targets` 注册新测试文件。**link flags 未改**
  （仍是上一轮 §370 的 `libavcodec_dbg.a`）。

### 顺带修掉的真实内存泄漏（ASan 驱动）

`close_input` 原来只调 `avio_context_free(&avio)`，它**只释放结构体**；
`avio_alloc_context` 的探测缓冲区（`av_malloc(65536)`，且会被
`av_probe_input_buffer2` realloc）从来没人释放。每次内存型 oracle 调用
都漏一份。ASan 首次跑就报 `1114112 byte(s) leaked in 17 allocation(s)`，
栈全部指向 `av_probe_input_buffer2 → avformat_open_input → open_input`。

修法：新增 `free_custom_avio(AVIOContext*)`，从 context 读回**最终**
buffer 指针（探测期可能 realloc 过），依次 `avio_context_free` →
`av_free(buffer)` → `free(opaque)`；`close_input` 与 `open_input` 的
全部 4 条失败路径统一走它，并补上 `av_malloc` 失败时的 `free(io)`。
这是所有 oracle 入口（`ffref_packets` / `decode_audio` / `decode_video`
/ 新的 `stream_info`）共用的路径，所以做了全量 + 扩大 ASan 回归。

## 三、新增测试（`ffref/ffref_stream_info_test.mbt`，native-only，3 项）

1. `stream table matches libavformat across the container codec matrix`
   —— 16 个现成 base64 夹具里 13 个有 `MediaFile` 适配器的，逐流严格比对
   media_type / codec 名 / 宽高 / 采样率 / 声道 / **extradata 字节**。
   覆盖 Ogg-Opus、WAV(PCM / AAC / MP3 / ADTS-AAC)、
   MKV(H264+AAC / HEVC / AV1 / MJPEG)、WebM-VP9、TS(H264+AAC)、
   MP4-AAC、fMP4。
2. `stream-info blob parses bare MP3 and PNG elementary streams`
   —— 裸 MP3 / PNG 无 `MediaFile` 适配器（走 codec 入口），单独钉住
   oracle 侧的 codec 名 / 几何 / 零长 extradata，验证变长区游标解析。
3. `oracle failures are mapped to FFRefError`
   —— 空输入 + 不存在的 encoder 必须抛错，不能静默返回空结果。

### 本片发现的真实缺口（以前的 packet 对拍看不到）

**TS 容器流表漂移**：

| 字段 | C (libavformat) | MoonBit `MediaFile` |
|---|---|---|
| TS 视频 width / height | 32 / 32 | 0 / 0 |
| TS 视频 extradata | 35 B | 1250 B |
| TS 音频 extradata | 0 B | 2 B |

另有 `WAV/ADTS-AAC`：C extradata 0 B vs port 2 B（已知的 WAV/AAC
分包差异，与 `ffref_test.mbt` "ADTS-in-WAV" 同源）。

这两处在测试里以 `skip_geometry` / `skip_extradata` **显式声明**，不是
静默放宽，其余字段仍严格。修 TS 需要从 SPS 推几何并规范化 extradata，
是独立垂直切片，留给下一轮。

## 四、验证

| 项目 | 结果 |
|---|---|
| 新测试（native） | **3/3** |
| 全量 `moon test --target native -p ffref`（nine-dbg） | **76 / 75 / 1** |
| 全量基线（本轮开始前） | 73 / 72 / 1 |
| 唯一 native 失败 | `aac-tns 128000: packet 1 (424 vs 423)` —— §371 既有，前后完全一致 |
| 定向 ASan（新测试） | 3/3，`TEST_EXIT=0`，无 ASan / LSan 报告 |
| 扩大 ASan（`ffref_test.mbt` + 新测试） | 34/34，无 double-free / 泄漏 |
| `moon check --target wasm` | 0 error（4 条警告全来自 §370 未提交的 `aac_mdct_tx`） |
| `moon test --target wasm --no-render` | **1713 / 1710 / 3** |
| 3 个 wasm 失败 | 全在 `aac_encode_vectors_test.mbt`（PNS/IS、TNS、max_sfb carryover），§371 既有 |
| `moon info --target native` | 退出 0，正确列出 `pub fn ffref_stream_info(Bytes) -> Array[FFRefStream] raise FFRefError` |

wasm 侧的 3 个失败与本轮改动无因果关系：本轮只改 `ffref/`，该包
`supported_targets = "native"`，wasm 构建整包跳过。

### ASan runner 的适配说明（必读）

按技能要求先直接调用 `moonbit-c-binding/scripts/run-asan.py`，在本项目
**跑不通**：runner 会把 `libmoonbitrun.o` 换成空对象来禁用 mimalloc，
但本镜像的 moon 0.1.20261104 的 `libruntime.a` 直接引用
`mi_malloc` / `mi_free`，导致所有 native 包链接 `undefined reference`
（`RUNNER_EXIT=1`）。另外 runner 硬编码 `moon test --target native -v`
全模块，对 wasm-first 项目不合适。

按技能「runner cannot fit the project」条款，改为**等价的定向验证**：
用 PATH 包装把 runner 的调用收窄到 `-p ffref`（runner 本身一行未改，
已验证 patch/restore 与 mimalloc 还原都正常），再临时给
`ffref/moon.pkg` 的 `cc-flags` / `stub-cc-flags` / `cc-link-flags`
加 `-fsanitize=address`（保留必需的 `-I/usr/local/include`），
保留 mimalloc，跑完立即还原。验证结束后 `moon.pkg` 已确认零 ASan 残留。

## 五、工作树与后续

- §370 / §371（AAC av_tx MDCT + KBD/TNS）仍是**未提交工作树**，本轮
  一行未碰；`ffref/moon.pkg` 仍指向 `libavcodec_dbg.a`，提交前按上一轮
  handoff 还原成 `libavcodec_ref.a`。`ffref_encode_ref_test.mbt` 里的
  §371 临时 `PKT1` 探针也仍在。
- 本轮新增/修改文件：`ffref/ffref_stub.c`、`ffref/ffi.mbt`、
  `ffref/ffref.mbt`、`ffref/moon.pkg`、新增 `ffref/ffref_stream_info_test.mbt`。
- 下一片建议：
  1. **TS 流表几何 / extradata 对齐**（本片实测缺口，最有价值）；
  2. 把 `ffref_stream_info` 接到 HLS/DASH 的路径式 oracle
     （仿 `ffref_probe_path`），把清单里两种流媒体容器也纳入流表对拍；
  3. MJPEG 12-bit / 算术编码的明确拒绝与 C 行为对照；
  4. 若后续升级 moon 工具链，重测官方 ASan runner 的 mimalloc 兼容性。
