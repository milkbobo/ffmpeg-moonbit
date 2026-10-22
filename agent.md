# agent.md —— 本项目维护手册（供 AI / 协作者）

> 面向「在这个仓库里继续干活」的实操指引。**进度、模块清单、行数、验证来源**等动态信息
> 以 [README.md](README.md) 为准；本文只记录**稳定约定、命令、坑与流程**。

---

## 0. 一句话定位

用 MoonBit 逐模块重写 FFmpeg 9.0.2 的**纯算法**部分。当前覆盖：

- **libavutil**：数学/有理数、CRC/Adler-32、Base64、MD5、SHA-1/224/256、avstring、
  RC4、AES(ECB/CBC)、XTEA、TEA、Blowfish、CAST-128、AES-CTR；另有 `@v128` SIMD 版：
  Adler-32、base64 编码、`av_strnstr`、MD5 多缓冲（`adler32_v128.mbt`/`base64_v128.mbt`/
  `avstring_v128.mbt`/`md5_v128.mbt`）
- **libavformat**：`aviobuf.c` 流式 AVIO 层（`AvioContext`：回调驱动缓冲读写、四路径
  seek、dyn buf、CRC 校验和）+ MP4/MOV 解复用切片（box 遍历 + 采样表索引，**跑在
  AvioContext 上**，`av_mov_open_avio` 支持流式源；**sgpd/sbgp sample group** 与
  open-GOP seek（`build_open_gop_key_points` → `can_seek_to_key_sample`）、**多 sample
  description**（`pseudo_stream_id` 过滤 + extradata 槽位 + tfdt/trun `stsd_id` 门）、
  **advanced_editlist**（`mov_fix_index` 全量：edit 时间轴索引重建、`skip_samples`、
  `min_corrected_pts`、`start_time`、tts 重建、`mov_estimate_video_delay`；
  `av_mov_open_with(buf, false)` 非 advanced 路径）；碎片化
  MP4 含 `sidx`/`mfra` 与重叠片段 discard、extradata `avcC`/`esds`+AAC 配置、
  `mov_seek_stream` seek、未压缩音频分块路径、cenc 全家含碎片内 `senc` 与 `saiz`/`saio`）
- **libavformat（Matroska/WebM，已开始）**：`ebml.mbt`（EBML 变长整数原语 +
  通用元素游走器：level 栈/LEVEL_ENDED/未知长度终止/VOID 跳过/非 seekable 启发式
  /level-1 注册表；C 的 `EbmlSyntax` offset 写 → sink 闭包 + 子表 thunk）与
  `matroska.mbt`（EBML 头校验链 + Segment/Info/SeekHead/resync/execute_seekhead，
  入口 `av_matroska_open`）与 `matroska_track.mbt`（TrackEntry 全表：字段默认值、
  video/audio/encodings 层级）；后续 Cluster/Block lace 逐片推进
- **libavcodec**：SIMPLE-C IDCT（`int16` 8/10/12 bit）+ `idctdsp` 像素/扫描表辅助；
  `huffman.c` 的树/码长构建（`ff_huff_build_tree`/`ff_huff_gen_len_table`）+ 规范化
  Huffman 码的编/解码；`mpeg4audio.c` 的 AudioSpecificConfig 解析（`mpeg4audio.mbt`，
  供 libavformat 的 `esds` 用 —— **libavformat 依赖 libavcodec**，与 FFmpeg 方向一致）；
  IDCT 的 8/10/12 位另有 `@v128` SIMD 版（`idct_v128.mbt`，块/像素改用 **字节缓冲**，
  v128 才能载入）
- **libavcodec（码流层，2026-10 新增）**：`bitstream.mbt`（get_bits + Exp-Golomb）、
  `h2645_parse.mbt`（RBSP 去防竞争字节 + Annex B/长度前缀 NAL 拆分）、
  `h2645_vui.mbt`（公共 VUI）、`h264_ps.mbt`（H.264 SPS/PPS/avcC）、
  `hevc_ps.mbt`（HEVC VPS/SPS/PPS/PTL/RPS/hvcC）、`audio_headers.mbt`（ADTS、MP1/2/3
  帧头）。这一层**只解析码流**；多层 HEVC 扩展与部分解码端派生表未建模
- **libavcodec（CABAC + avcC 入口，2026-10 新增）**：`cabac.mbt`（算术解码核心 +
  `ff_h264_init_cabac_states`）、`h264_cabac_tables.mbt`（1343 项算术表 + 上下文初值，
  由脚本批量提取，规范见 §9）、`h264_cabac_mb.mbt`（I 宏块的 CABAC
  解析：mb_type/chroma 预模式/CBP/dqp/残差）、`h264_mb.mbt`（CAVLC 与 CABAC 共用的宏块
  重建）、`h264_decode_avc_frames`（MP4 `avcC` + 长度前缀样本入口）。
  **算术核心已用 FFmpeg 自己的 `tests/cabac.c` 逐比特验证；稠密多行 I 与运动 I/P
  的 13 帧新增回归，在滤波/未滤波两套 MD5 下均 byte-exact**（见 README §3）。
- **libavcodec（P 帧 + DPB，2026-10 新增）**：`h264_mc.mbt`（luma 6 抽头 qpel +
  chroma 1/8 双线性 MC，边界复制；**块基准位置必须显式传**，见 §7）、`h264_mvpred.mbt`
  （A/B/C 邻块、`mid_pred`、P_SKIP 捷径）、`h264_inter.mbt`（P 宏块层：skip/type 四种
  划分/ref/mvd + inter 残差，CAVLC 与 CABAC 共用重建）、`h264_dpb.mbt`（滑窗 DPB、
  POC type 0/2 跟踪、默认 L0 序；`H264Decoder` 的 Annex B/avcC 入口跨样本保状态）。
  向量：真实 I+P+P 流 + 合成 CABAC P 帧（`h264_psynth_wbtest.mbt`：全 I_PCM 非平坦
  参考 + P_L0_16x16 整数 MV，编码器逐 bin 镜像解码端上下文）。
- **libavcodec（AAC 频谱解码，2026-10 新增）**：`aac_tables.mbt`（aactab.c 全部
  解码表 + pow2sf/cbrt 运行时表的 float32 复刻，`scripts/extract_aac_tables.py`
  批量提取并与 C 源逐值 diff）+ `aac_spectrum.mbt`（scalefactor 差分/noise 前导、
  码书 1..11 Huffman + VMUL 打包索引解包、book 11 escape、pulse 重建、PNS、TNS Levinson+AR、
  gain-control 语法）+ `aac_mdct.mbt`（四窗口序列 + KBD/正弦窗、综合 2/N、
  `vector_fmul_window` 2×len、FIL/DSE 跳过及 SCE/CPE/LFE 多元素帧编排）。真实 libfdk_aac 码流逐帧解码出 PCM；
  `aac_stereo.mbt` 支持 CPE 共享/独立窗口、M/S 与强度立体声。**单/双声道长短窗、
  窗口切换/TNS/PNS 及合成 pulse 向量与 FFmpeg 参考的最大差分为 1 LSB**（见 README §3）。
  `aac_layout.mbt` 支持默认配置 1..7/11..14 和三层 PCE、FFmpeg 元素输出排序；真实 5.1/PCE
  5.1/7.1 与标签乱序向量的最大差分同样为 1 LSB。
  `aac_config.mbt` 支持 LC GASpecificConfig/ASC-only PCE 与 `new_aac_decoder_from_asc`；
  MP4 esds 和参数桥接能解析 PCE 声道数，真实 MP4→raw packets→PCM 最大差分 1 LSB。
  ASC frameLengthFlag 可选择 960/120 的频带与综合窗口；短窗频谱步长仍为 128，
  逆变换结果按 120 排列。合成 mono/CPE 的四序列/双窗形/首尾频带对拍最大差分 1 LSB；
  本机 FDK 拒绝 960 配置，真实编码器样本仍待验证。
  `aac_coupling.mbt` 支持 CCE 三个耦合位置、四增益尺度与 CPE 声道选择，
  PCE/ASC 保存耦合声明，源历史按标签独立维护。1024/960 合成码流对拍最大差分 1 LSB。
- **libavutil（bessel）**：`av_bessel_i0`（Blair/Edwards 极小有理逼近，KBD 窗用）。
- **libavcodec（解码切片，2026-10 新增，首次产出像素/PCM）**：
  - H.264 Baseline **I 帧重建 + 环路去块滤波**：`h264_slice.mbt`（I/SI slice header）+
    `h264_cavlc.mbt`（CAVLC + dequant/chroma-QP 表）+ `h264_idct.mbt`（4x4 IDCT +
    luma/chroma DC Hadamard）+ `h264_pred.mbt`（4x4/16x16/chroma 8x8 帧内预测）+
    `h264_deblock.mbt`（`h264dsp` 四个滤波核 + `h264_loopfilter` 边界强度推导）+
    `h264_decode.mbt`（宏块路径编排 + Annex B 入口）。默认入口**带滤波**，视觉对齐
    FFmpeg 默认解码；`..._ex(data, true)` 跳过滤波，对齐 `-skip_loop_filter all`
  - MPEG 音频**三层**定点解码：`mp3_tables.mbt`（Layer III 码表/Huffman）+
    `mp3_dsp.mbt`（IMDCT/DCT32/合成窗）+ `mp3_decode.mbt`（Layer III：side info/
    反量化/立体声/PCM，另含三层共用的合成滤波 `mpa_synthesize`）+
    `mpa_layer12.mbt`/`mpa_layer12_tables.mbt`（Layer I/II：bit allocation/
    scalefactor/组量化）；`decode_frame` 按帧头 `layer` 分派
- **libavformat（码流层接入）**：`rawaudio.mbt`（裸 ADTS/MP3 分帧，ID3v2/v1 +
  Xing/Info/VBRI）、`codec_tags.mbt`（MKV CodecID / MP4 fourcc 映射）、
  `codec_parameters.mbt`（容器 + extradata → 统一 `CodecParameters`）

策略：**垂直切片**，从自包含、可独立验证的纯算法入手。**向量化（SIMD）内核用 MoonBit
`@v128`（`moonbitlang/core/v128`，Wasm SIMD128 / native SIMD）重写** —— FFmpeg 的
NASM（`*.asm`）是 x86 汇编，**无法**编译进本模块的 `wasm` 目标；仅 x86 专有指令
（AES-NI / SHA-NI / PCLMULQDQ）与线程/平台代码留待 `extern "C"` FFI 复用（见 §8）。

---

## 1. 位置与仓库

| 项 | 值 |
|---|---|
| 工作目录 | `d:\project\FFmpeg-n9.0.2`（FFmpeg 源码根，**不是** git 仓库） |
| git 仓库 | `d:\project\FFmpeg-n9.0.2\moonbit`（分支 `master`，origin 为 `git@github.com:milkbobo/ffmpeg-moonbit.git`） |
| 忽略项 | `_build/`（`.gitignore` 已含；勿提交） |
| 模块名 | `ffmpeg/moonbit`，`preferred_target = "wasm"` |
| 包 | `ffmpeg/moonbit/libavutil`、`ffmpeg/moonbit/libavformat`、`ffmpeg/moonbit/libavcodec`（后两者依赖 libavutil；libavcodec 的 libavutil 依赖仅白盒测试用） |

> ⚠️ 提交前 `git status` 应在 `moonbit/` 下执行；FFmpeg 根目录不是仓库。

---

## 2. 工具链与命令

- `moon.exe`：`C:\Users\milkb\.moon\bin\moon.exe`（已验证 `0.1.20261012`）
- 标准流程（`cwd` 设为 `moonbit`）：

```powershell
C:\Users\milkb\.moon\bin\moon.exe check --no-render   # 必须 0 error / 0 warning
C:\Users\milkb\.moon\bin\moon.exe test  --no-render   # 必须全绿
```

- 加 `--no-render` 抑制刷屏；用 `Select-String -NotMatch "INFO"` 过滤日志后看结论。
- **交付标准**：`moon check` 0 error / 0 warning，且 `moon test` 全通过。

---

## 3. 提交规范

- **仅在用户明确要求时提交**；不主动 commit。
- 按**精确路径** `git add`（勿用 `git add -A` / `git add .`，以免带入无关文件）。
- 提交信息风格：`feat: …`（中文摘要），末尾附 `Co-Authored-By:` 行。
- PowerShell **没有 bash 式 heredoc**，多行信息用 here-string 经 stdin 传入：

```powershell
$msg = @'
feat: 摘要

详细说明……
'@
$msg | git commit -F -
```

---

## 4. 新增一个模块的标准步骤

1. **通读 C 源**：`libavutil/xxx.c` 与 `xxx.h`（或 `libavformat/xxx.c`）。
2. **先找权威向量**：`libavutil/tests/xxx.c` 内嵌向量 或 `tests/ref/fate/xxx`（见 §5）。
3. 建 `moonbit/libavutil/xxx.mbt`（或 `libavformat/`）；文件头保留原 C 的版权/许可证说明，
   并显式写明任何**实现偏差**。
4. **逐行移植**，遵循 §6 约定。
5. 在 `*_wbtest.mbt`（或按主题合并进 `cipher_wbtest.mbt` 等）加白盒测试，期望值**必须**
   取自权威向量。
6. `moon check` / `moon test` 达到交付标准。
7. **更新 README.md**：目录树、模块表、总行数、状态（`N/N`）、验证来源表、阶段勾选、
   未完成清单。
8. 汇报进度；**不要自行 commit**（除非用户要求）。

---

## 5. 验证铁律

- **每个模块必须用独立权威向量验证；禁止自造期望值。**
- 优先级：FFmpeg 自带（`libavutil/tests/*.c` 内嵌向量、`tests/ref/fate/*`）→ FIPS/NIST/RFC 官方标准。
- 注意：`tests/ref/fate/*` 很多只是「成功行」文本，**没有数值**；数值通常在同名
  `libavutil/tests/*.c` 里（如 `xtea`、`tea`、`blowfish`、`cast5` 均如此）。
- 可补强：分块更新与一次性计算等价、加密→解密往返、CTR「任意切分 == 一次性」。
- **真实文件交叉验证（有 Docker 时优先做）**：本机存在镜像 `linuxserver/ffmpeg:9.0.2`
  时，用它生成真实 MP4（普通/碎片化/cenc），并以同镜像 `ffprobe` 的
  `-show_entries packet=pts,dts,duration,pos,size,flags` 输出作为期望值，与解析结果
  逐 packet 比对。范本见 `libavformat/mp4_real_wbtest.mbt`（文件 base64 内嵌 + 生成命令）。
  **码流参数集**的权威期望值用 FFmpeg 自己的
  `ffmpeg -i x -c copy -bsf:v trace_headers -f null -`（SPS/PPS/VPS 每个字段的
  位偏移与值）；`ffprobe -show_streams` 只给 profile/level/尺寸，粒度不够。
  裸音频范本见 `libavformat/rawaudio_wbtest.mbt`（ADTS/MP3 逐帧 `pos`/`size` 对齐
  `ffprobe -show_packets`）。
  cenc 文件可用 `-encryption_scheme cenc-aes-ctr -encryption_key … -encryption_kid …`
  生成，再以已知密钥解密核对明文样本。
- **无 FATE 数值向量时（如 `libavcodec/huffman.c`）**：用「期望值由 FFmpeg 自己的另一实现产生」
  或「能被数学性质唯一确定的量」作判据 —— 例如 Huffman 用 Kraft 等和 `Σ2^-len == 1` +
  与独立教科书两队列法的最优代价相等 + FFmpeg 两套实现互证 + 编解码往返；IDCT 则对照
  FFmpeg 自带的双精度参考 `libavcodec/dctref.c`，判据照抄 `libavcodec/tests/dct.c`。
- **SIMD 路径同样要吃向量**：SIMD 实现必须与标量路径、以及该模块既有权威向量**逐值一致**
  （同一测试里同时跑 SIMD 与标量并断言相等，或先证标量再切 SIMD）；不得因为"是优化路径"
  就放宽断言。
- **测试失败先怀疑自己的期望值**：本项目已多次出现「实现正确、期望写错」的情况
  （如 `av_strcasecmp` 返回值、`av_strlcat` 预算不足返回所需长度、`av_match_name` 的
  首命中短路语义）。先回到 C 源码重推。
- **解码器（出像素/PCM）的向量做法**：参考输出由 docker `linuxserver/ffmpeg:9.0.2`
  现场生成，期望值是 **MD5**：
  - H.264：`-x264-params "keyint=1:bframes=0:cabac=0:8x8dct=0:slices=1:scenecut=0"`
    产出「全 IDR + 单 slice」码流，再按 `w*h*3/2` 切帧算 MD5。**两套参考值都要取**：
    默认解码（带环路滤波）对 `h264_decode_annexb_i_frames`；`-skip_loop_filter all`
    （放在 `-i` 之前）对 `..._ex(data, true)`。只取一套时，滤波时序/强度的错误会被
    另一套掩盖（本项目的去块滤波就是靠两套对照才定位到时序问题）。
  - MP3：期望 PCM MD5 必须取自**定点**解码器 `-c:a mp3 -f s16le`；浮点（默认
    `mp3float`）给出不同 MD5，用错就永远对不上。
  - Layer II：编码用 FFmpeg 原生 `-c:a mp2`，解码期望值取 `-c:a mp2`（定点，非
    `mp2float`）。同一份 `decode_mp3_stream` 能吃三层，因为帧头解析已给出 `layer` 与
    `frame_size`。Layer I 没有编码器 → 手工拼帧 + 让 FFmpeg 解码取期望值（见 §7）。
  - **扫描式验证**：按宏块/每行算 luma MD5 与参考 YUV 同区域比对，比整帧 MD5 更快
    定位到具体宏块或单条预测路径。
  - **负例也要吃向量**：多 slice / CABAC / P slice / 4:2:2 / 10-bit 等未支持输入，断言
    **具体错误串**（而不只是"是 Err"），否则错误路径掩盖真实原因时测试仍然通过。
  - 生成命令写进 `*_realdata_wbtest.mbt` 文件头，码流 base64 内嵌（范本：
    `libavcodec/h264_decode_realdata_wbtest.mbt`、`mp3_decode_realdata_wbtest.mbt`）。
  - docker 挂载在 Git Bash 下要用 **Windows 路径** + `MSYS_NO_PATHCONV=1`
    （`-v "C:/Users/…/dir:/s"`）；`/c/…` 形式会被 MSYS 改写挂载串。

---

## 6. MoonBit 语法 / 工具链坑（务必遵守）

清一色来自本项目的真实踩坑，照做可少走弯路：

- 按位取反 `~` 不存在 → 用 `x.lnot()`。
- 逻辑右移 `>>>` 不存在 → 改用 `UInt`/`UInt64`（其 `>>` 即逻辑右移）。
- `to_int` / `to_uint` 已弃用 → `reinterpret_as_int` / `reinterpret_as_uint`；
  `Int`（32 位）**没有** `reinterpret_as_uint64`，需先 `to_int64()`。
- 方法声明必须带类型前缀：`fn Type::name(self : Type)`（裸 `fn name(self : Type)` 是弃用告警）。
- 丢弃非 `Unit` 返回值必须写 `let _ = ...`（否则 `E4139`）。
- 结构体里**只改元素、从不整体重赋值**的数组字段**不能加 `mut`**（`unused_mut` 报错）；
  标量字段需重赋值才加 `mut`。
- `T` 不会隐式转 `T?`，实参要写 `Some(x)`。
- **不要** `derive(Eq, Show)`（触发 `implicit_impl_as_method` / `deprecated_syntax` 告警）；
  用 `match` 辅助函数。
- **值标识符/参数名须以小写或 `_` 开头**：大写如 `K` 会报 `E4074` / `E3002`。
- `Bytes` → `String`：`to_string()` 返回 `b"..."` 字面量、`to_unchecked_string()` 按 UTF-16
  解释字节，**都不能**把 ASCII 字节正确转字符串；需按码位构造 `String::from_array(Array[Char])`。
- 顶层 `let` + `FixedArray` 字面量可作常量表。
- `UInt` 是 **32 位回绕算术**（SHA、各分组密码的 `+ - * <<` 均依赖此语义）。
- **十六进制字面量前缀必须小写 `0x`**（`0X` 不被识别）。
- 未使用的循环计数变量**不会**告警，C 风格 `for i = 0; i < n; i = i + 1` 可安全照搬。
- **`test` 是保留字**，不能作参数/变量名（否则报大片 `E3002` 解析错误并连带无关告警），
  移植 `dct.c` 之类含 `int test` 的函数时改名（如 `mode`）。
- **白盒测试专用依赖**用 `moon.pkg` 的 `import { "…" } for "wbtest"`；写成普通 `import`
  会因非测试文件不使用该包而触发 `unused_package` 告警。
- **core 包**：`Double::sqrt`（方法）可用；`floor`/`round`/`ceil` 可用方法或 `@math.*`；
  `@math.cos` 等数学函数需在 `moon.pkg` 里 `import { "moonbitlang/core/math" }`（别名为 `@math`）。
- **行数统计口径**：`Get-Content $f | Measure-Object -Line` 会少计，统一用 `(Get-Content $f).Count`。
- **顶层常量与类型别名（0.1.20261012 工具链）**：大写标识符的顶层常量必须 `pub const`
  （`pub let` 报 E3002）；类型别名用 `pub type X = …`（不是 `typealias`）；`Option::is_some()`
  弃用 → `x is Some(_)` / `x is None`；局部 `var x =` 弃用 → `let mut x =`；`Char::from_int`
  弃用 → `Int::unsafe_to_char`（码点已知合法时）；`Bytes::from_fixedarray` 弃用 →
  `Bytes::from_array(arr[:])`（Bytes 不可变，无 `op_set`）。
- **`-unused_constructor` 消警已移除**：`EbmlKind::Sint` 在 Cluster 切片拿到了真实消费者
  （BlockGroup 的 DiscardPadding），`libavformat/moon.pkg` 里的全局消警已删且 `moon check`
  仍 0 告警。今后新增枚举变体不要靠全局消警，先在代码里接上消费者。
- **`b"…"` 字节字面量走 UTF-8，非 ASCII 字符会展开成多字节**：写 EBML id 时 `b"£"`
  实际是 `0xC2 0xA3`，于是 SimpleBlock 的 `0xA3` 变成两字节 id，解析器读到 `0xC2` 后整条
  元素链错位（症状：cluster 内 `id=194` 而不是 `163`，packet 队列全空）。二进制 id 一律
  写 `b"\xA3"`，非 ASCII 字符只出现在真正要文本的地方。
- **`BytesView::data()` 返回底层 `Bytes`，不是视图窗口**：`b[a:b].data()` 得到整个 `b`。
  取子区间必须 `.to_owned()`，切片辅助函数写成
  `b.clamped_view(start=from, end=to).to_owned()`。Tracks/Cluster 切片各踩过一次
  （症状：lace sizes 全错、EBML lacing 直接 `unwrap` 失败）。
- **`moon fmt` 会全局改写类型名 `UInt`→`UInt32`、`Int`→`Int32`**：一次格式化就动 59 个
  文件、把公共签名全部换名，**绝不能直接提交**。本项目统一短名，**不要跑 `moon fmt`**；
  万一跑了，`git checkout -- .` 还原再重放自己的改动（新文件用整词替换
  `\bUInt32\b`→`UInt`、`\bInt32\b`→`Int` 回滚）。交接验收里的"跑 fmt"按这条理解。
- **脚本改 `.mbt` 会把 `\xDE` 之类转义二次编码成 mojibake**：文本模式读写的 python
  会写坏 `b"\xDE\xAD"` 里的反斜杠。改 `.mbt` 一律用编辑工具；必须用脚本时读写都走
  二进制（`'rb'`/`'wb'`），且只做整词替换。
- **sink 里抛的错误必须显式传播**：`let _ = deliver(...)` 会把
  `matroska_parse_block` 的 `EINVAL`（未知轨道号、损坏 lacing）静默吞掉，上层只看到
  "0 个 packet"。游走器的三处 `deliver` 已改为 `match … { Err(e) => return Err(e) }`。
- **`MatroskaHeader` 的 master 内元素顺序不可假设**：BlockGroup 里 `BlockDuration`/
  `ReferenceBlock` 可能排在 `Block` 之后，边读 `Block` 边解码会拿到 0/默认值。做法是
  Bin 只暂存字节与位置，在 master 结束的 sink（收到 `EbmlValue::Master`）里再解码。
- **MoonBit struct 字段是引用、但 `let v = t.video` 取的是值拷贝**：表工厂里 sink 闭包
  若捕获局部拷贝（`let v = t.video; sink(u => v.x = u)`）写入会全部丢失——必须写
  `sink(u => t.video.x = u)` 穿透字段。Tracks 切片因此踩过一次（嵌套 master 全部
  字段静默为默认值）。
- **合成 EBML 测试的元素层级要与规范一致**：ContentEncodings(0x6D80) 下必须先有
  ContentEncoding(0x6240) 再有 ContentCompression(0x5034)——漏掉中间层时外层照常
  匹配、内层静默 skip（期望值写 0 != 1 才暴露）。
- **`@v128` 的 experimental 告警**：调用 `@v128.*` 会触发 `alert_experimental`（E0014）；
  在 `moon.pkg` 写 `warnings = "-alert_experimental"` 即可消警（core 自身亦如此，见
  `core/debug/moon.pkg`）。完整范本：`libavutil/adler32_v128.mbt`（构造用 `i16x8_const`、
  块载入用 `[v128le(v), .. _]` 模式、横向归约用 `i32x4_extract_lane`、`UInt64` 字面量用 `16UL`）。
- **不存在的 `?` 后缀运算符**：MoonBit 这里没有 Rust 式 `expr?`。已有代码用
  `try { ... } catch { InvalidData(msg) => ... }`（如 `mov.mbt` 的 `mov_open`）或显式
  `match ... { Err(e) => return Err(e), Ok(v) => v }`。在 `let x = match ...` 里
  `return` 是合法的，可放心用。
- **`Result[T, String]` 少写一个 `]` 的报错极具误导性**：写成 `Result[Foo, String> {`
  时解析器会在 `>` 处报 `unexpected token infix ... expected , or ]`，随后整段函数被
  当成顶层表达式，堆出一大片“return 必须在函数内”的假错误。本项目已在
  `hevc_ps.mbt`/`audio_headers.mbt` 各踩一次；看到该类错误先数类型括号。
- **跨包不能构造外部 struct**：`@libavcodec.MpaDecodeHeader` 在 libavformat 里是只读类型，
  `let h : @libavcodec.MpaDecodeHeader = { ... }` 报 E4036/E4033。不要给外部 struct
  写默认值，重构为“先找候选、再调用返回处”的写法。
- **像素格式名是 native-endian**：FFmpeg 的 `AV_PIX_FMT_YUV420P10` 是
  `AV_PIX_FMT_NE(BE, LE)`；本机/目标为小端时名字是 `yuv420p10le`（不是 `yuv420p10`）。
  `hevc_ps.mbt` 的 `map_pixel_format` 与 `codec_parameters.mbt` 均按 `*le` 命名。
- **`cbp & 15 != 0` 会被解析成 `cbp & (15 != 0)`**：混合 `&`/`|` 与比较运算时**必须加
  括号**，否则 CBP 判定全错、整帧像素错位（H.264 解码切片踩过）。
- **`Array::make(n, inner)` 让 n 个元素别名同一个内部数组**：需要「每项独立的数组字段」
  时必须用循环逐个新建（H.264 的逐宏块 `nz`/`modes` 就因此踩过：所有宏块共享一份邻居
  信息，预测模式互相污染）。
- **未使用的 `mut` 与未使用的私有顶层符号在 `moon check` 下按错误/告警严格处理**：
  移植时先写后弃的辅助函数、只在调试期用到的变量，提交前清掉或接上消费者。
- **`fn name(self : T, ...)` 会被解析成方法定义**：MoonBit 把首参名为 `self` 的 `fn`
  当作 `T::name`（并给 `deprecated_syntax` 警告），于是同包其它文件、甚至同文件后面的
  调用点都报 `unbound identifier`。**自由函数第一参数不要叫 `self`**——本项目改叫
  `dec`/`ctx`/`gb`（`mpa_synthesize`、`mpa_decode_layer1/2` 都踩过）。
- **测试文件间可复用同包私有常量/函数**：如 `real_mkv_1024_b64`（`ebml_real_wbtest.mbt`）、
  `bcat`（`ebml_wbtest.mbt`）可被同包其它 `_wbtest.mbt` 直接使用，不必重复内嵌。
  H.264 的三个码流常量放在 `h264_decode_realdata_wbtest.mbt`，测试在
  `h264_decode_wbtest.mbt`，同包直接引用。

---

## 7. 移植算法常见陷阱

- **端序**：严格区分 `AV_RB*`/`AV_RL*`，写出用对应的 `wb32`/`wl32` 辅助。
- **输出参数**：C 的 `int *dst`、`uint32_t *xl,*xr` → 改为**返回值**（元组）。
- **错误码**：C 返回 `<0`（`AVERROR(EINVAL)`）→ 返回 `Result[T, String]`，错误信息 `"EINVAL"`。
- **CBC 次序**：加密 = `tmp = src ^ iv` → 加密 → `iv = 密文块`；解密 = 先解密 → `^ iv` →
  `iv = 消费的密文块`。务必与 C 的先后一致（尤其 `iv` 用的是 `src` 还是 `dst`）。
- **结构体声明与实际使用不符**：多个密码的 `key[16]` 实际只用前 4 个字，移植时只存实际
  用到的长度并加注释。
- **平台相关**：`av_get_random_seed` 之类不移植，留待 FFI（例：`aes_ctr.mbt` 未做
  `set_random_iv`）。
- **串行哈希的 SIMD 方向**：MD5/SHA 一类的轮函数前后强依赖，**单流无法向量化**（FFmpeg
  自身也为标量 C）；可并行的是**多路独立输入**。做法是在 `i32x4` 的 4 个 lane 里各放一条
  **等长**消息，逐 lane 施加同一轮常量/混合/`rotl`（`i32x4_shl` + `i32x4_shr_u`），循环外围
  仍是标量块调度（`av_md5_sum_x4`，见 `md5_v128.mbt`）。这类内核需**新增多缓冲 API**，
  且必须与标量单流版逐 lane 逐值一致。
- **Exp-Golomb**：`get_se_golomb` 的 C 实现作用于 **`code_num = ue + 1`**，不是 ue 本身
  （ue 1→se 1，ue 2→se -1）；直接对 ue 套 `((v>>1)^sign)-sign` 会整体错位。
  `get_ue_golomb_long` 在 32 位窗口全零时 `av_log2(0)=0` → 跳 31 位再读 32 位，
  与“读到 32 个前导零”并不是一回事；照 C 的 `log = 31 - av_log2(buf)` 实现即可。
- **NAL 拆分**：H.264/HEVC 的 SPS/PPS 解析入口在 C 里是 **NAL header 之后**的
  `GetBitContext`（`nal->gb` 已被 NAL 头解析消费 8/16 位），自行 `BitReader::new(nal.data)`
  后必须 `skip(8)`/`skip(16)`。`get_bits_bytesize(gb, 1)` 用的是 `size_in_bits`（整个
  NAL），不是 `bits_left`。
- **RBSP 与起始码**：`ff_h2645_extract_rbsp` 的 `consumed` 可能小于输入长度（遇到下一个
  `00 00 01`）；Annex B 循环在“剩余 <4 字节”时仍应完成当前 NAL 的提取（C 的循环条件只
  在迭代开始时检查），否则会吞掉最后一个 3 字节 NAL。
- **HEVC 参数集**：`vps_max_layers > 1` 且 `vps_extension_flag` 置位、PPS 的
  multilayer/3D 扩展均按本项目边界返回 `PATCHWELCOME`；普通 x265 Main/Main10 流不会
  触发。HRD 必须**逐位消费**（即使不存值），否则后续字段全部错位。
- **MP3 分帧**：包不能从文件头开始算——LAME 会在第一个音频帧里写 Xing/Info 标签，FFmpeg
  的包流会跳过这一帧（本项目 `info_frame_size` 记录其大小）；Xing 标签偏移是
  `4 + xing_offtbl[lsf==1][channels==1]`（MPEG1 mono 为 17），VBRI 固定在 header+32。
  `.mp3` 尾部还可能有 `TAG` 开头的 128 字节 ID3v1。
- **AAC ADTS**：`adts_frame_length` 含 7 字节头（有 CRC 时含 CRC），ffprobe 的 packet
  size 就是这个值；`samples = (num_raw_data_blocks+1)*1024`，不是恒为 1024。
- **H.264 4x4 IDCT 两遍的索引不同**：行变换用 `b`/`b+4`/`b+8`/`b+12` 系列，列变换的正确
  邻居是 `b+2`/`b+1`/`b+3`；照抄第一遍会整帧像素均匀偏移（症状：MD5 全错但图像"像"）。
- **4x4 top-right 可用性按 z-order 判**：块按 8x8 组重建，`bx`/`by` 与视觉位置不对应，
  必须用 FFmpeg 的 `topright_samples_available` 规则（`by == 0` 时
  `bx < 3 || 右方 MB 存在`；`by > 0` 时 `bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)`）。
- **16x16 / chroma 8x8 平面预测的梯度索引**：C 的 `8+k`/`8-k`、`4+k`/`4-k` 是**以块宽为
  基**的写法，移植成 `7+k`/`7-k`、`3+k`/`3-k`；写错会底边越界 panic。
- **SPS 裁剪偏移已折算成亮度像素**：`h264_ps.c:510-513` 乘过 `step_x`/`step_y`，
  `init_dimensions` 直接 `width - (cr + cl)`，解码端**不能再乘 2**。这类 bug 只有非宏块
  对齐分辨率（如 88x56）能暴露，整数倍分辨率的向量一定漏掉。
- **多 slice 必须解码前预扫**：宏块循环按 `mb_count` 读，第二个 slice 之前越界读零会静默
  产出垃圾像素；先扫每个 slice NAL 的 `first_mb_in_slice`，非 0 直接拒绝。
- **MP3 定点 vs 浮点**：期望 MD5 只能用 `-c:a mp3`（定点）生成；默认 `mp3float` 不同。
- **滤波时序 ≠ 滤波算法**：FFmpeg 是「解完一行 → `loop_filter()` 滤这一行」，而帧内预测
  读的是**滤波前**备份的 `sl->top_borders`。等价写法是「**先整帧重建，再按光栅序整帧
  滤波**」。「每解一个宏块就立刻滤波」会让同行的后续宏块拿**已滤波**左邻做预测，重建值
  整体偏移——症状是整帧只差一两百个样本、集中在 MB 边界附近，逐核对照 kernel 永远查不出。
- **内部边 bS 是 3（弱核）**：`filter_mb_dir` 只把**宏块边**抬到 bS=4，内部边保持 3 且
  `intra=0`；误用强核会让 `|p0-q0| < (alpha>>2)+2` 的平坦边多改一排像素。
  `filter_mb_edgev(..., bs, qp, a, b, h, intra)` 的 `intra` 参数决定「bS>=4 时是否走强核」，
  内部边这个参数恒为 0。
- **slice 级 deblock 偏移是 `div2 * 2`**：语法元素 `slice_alpha_c0_offset_div2` 是 se(v)，
  C 在 `h264_slice.c:1909` 乘 2 后才存；漏乘会让 `alpha`/`beta` 偏小。
- **PPS 的 `chroma_qp_index_offset` 不一定是 0**：本项目向量里是 **-2**（`pic_init_qp_minus26`
  是 -3）。自己写参考模型时直接解析 PPS，别假设默认值；差 2 会让表下标错位、个别样本差 1~2。
- **Layer II 的分配表遍历**：`alloc_table` 每行的第 0 个字节是该子带的**位宽**，其后
  `1 << bits` 项是该分配值对应的**量化索引**，所以推进是 `j += 1 << bit_alloc_bits`、
  取索引是 `alloc_table[j + b]`。把 `j` 当子带序号、或漏掉 `1 << bits`，会从第二个
  子带起整体错位（症状：只有最低几个子带对）。
- **`scale_code` 的四种共享模式不是「都读三个」**：`0` 读 3 个 6 位；`1` 读第 1、3 个
  （中间继承第 1 个）；`2` 只读第 1 个（三个相同）；`3` 读第 1、3 个（中间继承第 3 个）。
- **Layer I/II 与 Layer III 的共性只有合成滤波**：不要复用 Layer III 的
  `compute_band_indexes`/`reorder_block`/`compute_antialias`/`compute_imdct`——L1/L2 的
  `sb_samples` 已经是量化后可直接用的子带样本，任何一层 IMDCT 叠上去都会毁掉输出。
- **`ff_division_tabs` 该派生不该抄 2368 个常量**：
  `tab[v] = (v%steps) + (((v/steps)%steps)<<4) + ((v/steps/steps)<<8)`，只有 qindex 0/1/3
  （3/5/9 步）需要；`ff_scale_factor_modshift = (i%3) | ((i/3)<<2)`；L1 乘子是
  `MULLx(norm, FIXR(k*2), FRAC_BITS)`。派生时**整数运算顺序必须与 C 一致**（先 FIXR 再 MULL）。
- **Layer I 没有参考编码器**：FFmpeg 只有 mp2/mp3 编码器。覆盖 Layer I 的办法是按规范
  手工拼帧（header + 4 位分配 + 6 位 scalefactor + `n+1` 位尾数），再让 FFmpeg 解码取
  期望值；mp2 demuxer 需要至少两个连续帧才能探测，所以一条向量至少 3 帧。
- **CABAC 的 `cbp_all` 在残差解码后不能再重置**：C 里 `h->cbp_table[mb_xy] = sl->cbp = cbp`
  发生在残差**之前**，之后 `decode_cabac_residual_internal` 只是把 DC 非零标志
  `|= 0x40<<…` / `|= 0x100<<…` 进去。移植时若在宏块末尾再赋一次 `cbp_all = cbp`，DC 标志
  被抹掉，下一宏块的 `get_cabac_cbf_ctx` 全部偏 1~2 个上下文——症状是前两个宏块完美、第三个
  起整行像素错。
- **CABAC 上方邻居的 `nz` 取的是上宏块的「最后一行」**：`non_zero_count_cache[scan8[n]-8]`
  对首行块等价于上宏块的 `nz[3*4+x]`（luma）/ `nz[1*2+x]`（chroma），不是 `nz[x]`。写成
  `nz[x]` 会让含上邻的宏块 cbp/残差上下文全错。
- **`write_back_intra_pred_mode()` 在 `check_intra4x4_pred_mode()` 之前**：邻居的
  Intra4x4 模式用的是**原始码值**，不是被改判成 `TOP_DC`/`LEFT_DC`/`DC_128` 后的值。所以
  `info.modes` 存原始模式、重建才用改判后的副本，两个数组都要留。
- **FFmpeg `tests/cabac.c` 的参考编码器会吞掉流的第一位**：`init_cabac_encoder` 里
  `pb.bit_left++` 让 `PutBitContext` 多出一个「幽灵空位」，算术编码器必发的前导 0 因此不
  入流；`ff_init_cabac_decoder` 用合成 guard 位补回来。移植该测试时要丢掉 `bits[0]`。
- **验证脚本的盲区**：拿「未滤波 YUV + 逐宏块滤波」当参考模型时，它与 FFmpeg 默认解码
  **逐字节一致**（因为 FFmpeg 预测也读滤波前像素），能验出核/强度错误但**验不出时序错误**。
  时序问题要用整帧 MD5 + 「逐 MB 区域哈希」这类粗粒度对照来定位。
- **运动补偿的取样位置必须带「块基准」**：luma 与 chroma 一样，源位置 =
  `块在帧内的基准 + 分区内偏移 + MV>>shift`。只传 `MV>>shift + 分区内偏移`（漏基准）时
  第 0 行/列宏块**恰好正确**，其余全部错位——单元测试若只在基准 0 处调用永远测不出
  （`h264_mc_chroma` 的首版就这么漏掉，由合成 CABAC P 帧向量抓出）。端到端断言
  「P 帧 == 参考帧平移」必须用**非平坦**参考（I_PCM 图案），平坦参考对任何 MV 都通过。
- **DPB 参考图的平面尺寸字段**：`H264RefPic.height` 是 MC 边界复制的钳制上限，必须取
  宏块对齐平面高（`mb_height*16`）。首版误写 `cstride*2`（=平面宽），潜伏到真实 P 码流
  的子像素插值触底才越界 panic——真实向量（带 sub-pel MV）对此是必测项。
- **合成码流的编码器必须逐 bin 镜像解码端上下文**：CABAC 上下文是自适应的，编码器用
  错上下文（如 `decode_cabac_mb_cbp_luma` bit1 的 `(cbp&1)==0 → +1`）时流会**延迟**
  失步——前几个宏块照样解对，后面整片错。定位法：打印首个失配像素坐标，看它落在
  哪个宏块、该宏块与之前正确宏块在**上下文推导上**首个不同点（如「首个 A/B/C 全可用」
  或「首个上邻可用」）。
- **CAVLC PCM（及一切非 CABAC 结尾）码流要补 rbsp trailing bits**：`get_bit_length`
  把最后一个置位比特当 `rbsp_stop_one_bit` 剥掉，PCM 数据以 `...10101` 之类结尾时
  末样本少 1 位、被 `bits_left` 检查拒绝。合成器在 PCM 数据后显式写 `1` + 零填充即可。
- **AAC 频谱层的四个坑**（真实码流调试沉淀）：① `cbt_m1` 在 C 里是 **unsigned**
  （`ZERO_BT-1` 回绕进 intensity 分支做零填充），移植成 signed 必须显式 `cbt_m1<0`
  走零填充；② VLC 解码行号不是码书索引——符号要过 `codebook_vector_*_idx`
  打包表（books 7..11 对应 **6,6,8,8,10**，不能抄成 6,8,8,10,10；提取脚本
  直接读 C 指针表，`python scripts/extract_aac_tables.py --check` 核对全部数组）；
  ③ FFmpeg 的 `vector_fmul_window` 一次写 **2×len**（含符号翻转与倒序索引），
  窗表长为 1024/128；`ff_tx_mdct_naive_inv` 等价于教科书全 IMDCT **中间一半的负值**。
  教科书逆变换归一为 **2/N**，AAC `init_dsp` 的浮点缩放为 **1/(N*32768)**，
  所以综合包装层须对教科书结果乘 **-1/65536**（长短窗相同）；
  ④ FIL 元素的 count 是**字节数**且 count=0 合法（无载荷），FDK 会在帧尾连写
  两个 FIL；`decode_gain_control` 在 FFmpeg 里解析后**丢弃**（FIXME 注释），
  移植同样只消费语法。
- **AAC PCM 差分不能重复补编码器延迟**：参考 `ffmpeg -i tone_fade.aac -f s16le`
  的 PCM 与本解码器都保留 priming，按同一帧比较；额外偏移 1024 样本会制造失配。
- **AAC CPE 的工具顺序与状态边界**：左/右频谱（含 pulse）→M/S→强度立体声→
  各声道 TNS→IMDCT。共享 ICS 只共享当前窗口/频带信息，不能覆盖右声道的历史窗
  shape。M/S 掩码按 window group × max_sfb 读取，mode=2 不读显式位；噪声/强度带
  不做 butterfly。强度书 14/15 的符号相反，有 M/S 掩码时再翻转。帧尾 END 校验
  失败不推进窗口历史；多元素由布局核对完整性，不能静默返回首个声道。
  `scripts/generate_aac_stereo_vectors.py` 生成真实与合成 CPE 参考，期望 PCM 为
  FFmpeg 9.0.2 解码同一码流的交错 s16le；对照时需按 L/R 交错索引分离声道。
- **AAC 多元素不能按到达次序绑定历史**：以 type/tag/subchannel 为 key，输出按
  AVChannel 排列；`decoder.layout` 是输出顺序，`decoder.channels` 是历史存储槽位。
  PCE 开头还有四位 instance tag，不能直接从 object_type 读起；PCE 对齐相对于
  raw_data_block 开始。默认布局表与 PCE 在错误帧中不能提交，PNS 随机状态也须恢复。
  PCE 非连续标签与每帧元素乱序参考见 `scripts/generate_aac_layout_vectors.py`；7.1
  native ADTS 必须强制 PCE（indexed config 12 放不进 ADTS 的三位 channel_config）。
  本移植对歧义及无法命名的 height+CCE PCE 显式拒绝；CCE 标签单独保存，不计输出声道，
  不仿真 C 的 unspecified 输出顺序回退。高度 comment 长度只计 front/side/back，
  保留高度值 3 按 C 行为忽略重排。普通布局按整个元素的掩码排序、CPE 保持相邻；
  22.2 必须执行 C 的特殊元素交换，不能改成逐个 AVChannel 排序。
- **AAC ASC-only PCE 不能靠等待第一包补布局**：MP4/MKV 可能只在 extradata 中携带
  PCE。用 `aac_parse_audio_specific_config` 读取 GA/PCE 并用 `new_aac_decoder_from_asc`
  建立布局/容量；不要改通用 `ff_mpeg4audio_get_config` 的返回位数契约。coreCoderDelay
  多出 14 位时，PCE 的 byte align 仍相对 ASC bit zero。容器 LC config=0 的声道数
  也须从 GA/PCE 得到，不能用通用头部返回的 0 覆盖轨道；非法 PCE 不宣称解析成功。
  MP4 原始包与 FFmpeg PCM 对拍用 `-flags2 +skip_manual` 保留完整帧，避免再补一次
  priming。参考生成脚本为 `scripts/generate_aac_asc_vectors.py`。
- **AAC pulse 的位置依赖实际采样率的 SWB 表**：语法层保留起始带和每个 5 位
  offset，帧层在频谱解码前转为累计位置；起始带按完整 num_swb 校验，不按 max_sfb。
  重建放在反量化后、TNS 前，先撤销 4/3 幂再加 pulse 再反量化；重复位置必须顺序
  应用，NOISE_BT 与零缩放带跳过。短窗中的 pulse 必须拒绝。参考向量生成脚本为
  `scripts/generate_aac_transient_vectors.py`（包括 native/FDK 真实窗口切换和合成 pulse）。
- **HEVC B 帧对拍先按 POC 排序**：`ff_hevc_decode_frames` 返回的是**解码序**
  （I,P,B,P,B,P…），framemd5 是**显示序**；不排序直接逐帧比 MD5，B 帧会"全错"，
  从而误判成"未滤波输出一致、滤波后才有差"的假结论（本轮实际是 B 帧重建本身就错）。
  任何含 B 帧的端到端对拍，第一步就是把输出数组按 POC 升序排。
- **HEVC slice header 尾部必须读 `alignment_bit_equal_to_one` 并字节对齐**：
  `header_bits` 是**对齐后**的位置（对应 C 的 `align_get_bits`），CABAC 数据从
  `(header_bits+7)>>3` 字节开始。头部恰好在字节边界结束时，少读这 1 位会让 CABAC
  起点整体错 1 字节、整帧语法全乱；注意 `(x+7)>>3` 与 `align()` 数值等价，但**读对齐
  位本身会推进 1 位**，header_bits 的期望值要按对齐后写（既有测试 28→32）。
- **HEVC MC 的参考图尺寸参数（rw/rh）按路径分别传**：uni 路径传 `cw,ch` 正确、
  bi 路径容易误传 `ch,ch`——`hevc_fill_edge` 会把图内 x≥rw 的区域当越界做边缘复制，
  表现为"从第 rw 列起整体错、左侧全对"。chroma 的 rw/rh 独立传（chw/chh），
  所以 chroma 可能全对而 luma 半幅错。差异起点坐标 == 传错的参数值，可直接反推。
- **像素级对拍先分 plane 再定位**：先分 Y/Cb/Cr 统计差异数与首差坐标，能一刀切开
  "MV/预测错（chroma 也错）"与"luma 插值错（chroma 对）"；再用 8x8 块级差异计数看
  空间分布。另外"我方没滤边"的结论要用 C 参考的滤波/不滤波 YUV 逐像素 diff 先证实
  C 确实动了像素，再决定查 bS 推导还是查滤波本身，避免在错误的假设上二分。
- **构造 HEVC 负例流**：多 slice 用 x265 `-x265-params slices=2`（第二片
  `first_slice_segment_in_pic_flag=0` 即触发拒绝路径）；tiles/PCM 用位级补丁——
  按语法走完 SPS/PPS 后重序列化（PPS 字段序：`tiles_enabled` →
  `entropy_coding_sync` → tile 字段（含 `loop_filter_across_tiles`）→
  `loop_filter_across_slices`；SPS 的 VUI 可整体丢弃，不影响切片解码）。
  补丁基流与生成逻辑见 `scripts/_gen_hevc_inter_realdata.py`。

- **差分向量生成走 stdin/stdout 管道**：Git Bash 会把 `-v "$(pwd):/w"` 的卷挂载
  改写成无效路径，docker 报 `destination can't be '/'`；用
  `docker run --rm -i ... pipe:1 > out` 绕开。

- **VP9 系数对拍先收敛语法，再比较像素**：在 C/MoonBit 的 EOB 读取处记录
  `i/band/nnz/tp0/code_word/high/bits/val`，按字段归一化后找首个分歧。
  `prob_coef[tx][plane][inter]` 的 slab 步长为 **396 = 6×6×11**；UV 的 band counts
  取 `uvtx`。非零上下文必须按 **MERGE → decode → SPLAT** 更新，helper 的 end
  是相对长度。TU 逆变换后清系数；DC-only 缩放位数为 **4/5/6/6**。
- **VP9 超块像素与滤波地址**：逐 SB 调用时 y/uv 偏移都要加当前 col；滤波前写入
  `level[row7*8+col7]` 的块矩形。混合滤波参数为宽度索引 **0/1 → 4/8**，不得直接
  当像素宽度；有语法完全一致、像素仍不同的情况时，分 Y/Cb/Cr 定位首差。
- **VP9 负例使用 MSB-first 帧头**：show-existing 的最短 profile-0 包为 `0x88`；
  inter 负例复用真实 P 包，解码器在依赖参考尺寸或消费压缩头之前拒绝。五流验收为
  3+3+2+2+2 = **12 帧**，生成脚本和参考 MD5 见 `vp9_kf_realdata_wbtest.mbt`。

- **H.264 P_SKIP 的缺邻规则独立于普通 MV 中值预测**：左邻或上邻为
  `REF_NOT_AVAIL` 时直接取零 MV；不能只处理「ref 0 且 MV=0」的捷径。真实 HLS/DASH
  4 帧流在第 4 帧左边界首次暴露此错误，TS/fMP4/DASH 三条端到端 MD5 都会抓住。
- **AV1 tile size 与数据交错**：读一个 little-endian `tile_size_minus_1` 后先跳过
  此 tile，再读下一长度；末 tile 吃剩余字节。用 UInt32 解析四字节长度，先与剩余
  字节比较再加 1，避免 `0xffffffff + 1` 回绕。`data_offset` 指向真实首 tile payload，
  不包含首个长度字段。四 tile 的 offset/size/MD5 用 `av1_tiles_reference.c` 独立生成。
- **Opus 两端读同一帧**：熵符号按 MSB-first 向前，CELT raw bits 按低位优先从尾部
  向后读；tell/tell_frac 同时计入二者。回归应交错两种读取并比较完整 range/value/
  total_bits，不能只测符号。self-delimiting 的末帧长度位于长度头末尾、padding 在包尾。
- **CELT PVQ 查表与数值宽度**：`U(n,k)` 对称，原 C 的行指针含偏移，必须同时校验
  `U(n,k)` 与 `U(n,k+1)` 的有效列。`V=U+U` 用 UInt64 检查再转 UInt32，不能先经过
  Int；指数解码的索引可能超过 INT_MAX。`celt_cwrsi` 的末两维是专门路径，符号顺序
  不能改成普通字典序。零脉冲不读熵；归一化的正脉冲核不能用于折叠/零能量频带。
  表生成/核对用 `scripts/extract_opus_pvq_tables.mbtx [--check]`；原 C harness 为
  `scripts/opus_pvq_reference.c`，使用 `-ffp-contract=off`，整数与熵状态精确比较，
  Float32 频带以绝对误差 1e-6 比较。Float 转换由 `Float::from_int/from_double/from_int64`
  完成，平方根可直接 `Float::sqrt`，不要假设 Int/Double 有 `to_float()`。
- **Opus 多流与通道映射是两层**：仅最后一条逻辑流没有 self-delimiting 长度；所有流
  的 `frame_count * frame_duration` 必须一致，但帧数可以不同。偏移先是流内相对值，
  访问原容器包时要加流偏移。family 1 的 header map 先按 Vorbis 顺序重排，再解释
  coupled stream 的左右通道；255 表示静音，重复索引复制先前输出。family 2/255
  保持原顺序。OpusHead 的输入采样率只是元数据，解码时基始终 48 kHz，pre-skip 同理。
  MP4 dOps 的增益/pre-skip/rate 是大端，转换后的 OpusHead 为小端，增益按有符号 Q8 解释。
- **CELT 分配中的隐式无符号比较**：`opus_rc_tell_frac` 返回 UInt32，和有符号
  `tbits_8ths` 比较时 C 会把预算转成无符号；`CeltBlockSize` 仅含非负枚举值，GCC
  下 `(f->size + 2) << 3` 同样使 anti-collapse 预留比较转成无符号。极小畸形帧中
  预算可为负，照普通 Int 比较会在 trim/boost/anti-collapse 上分歧；移植显式用 UInt32
  比较，896 组 C 分配回归覆盖这些情况。`pvq_bits` 是 eighth-bit 预算，不是 K 脉冲数。
- **CELT setup 不是帧终态**：`decode_celt_setup` 仅解到 fine-energy 后、PVQ 前，
  输入历史为两个声道各 21 个 Float32 能量，mono 先取两行最大值。输出的 energy 不应
  立即当成下一帧历史；还须 PVQ、最终能量、静音修正和帧尾历史提交。TF 的正负值
  区分频率/时间分辨率，静音 setup 也要保留 C 的中间状态。`opus_celt_reference.c`
  以 `-ffp-contract=off` 编译，粗细能量与后滤波增益按 Float32 位模式对拍。
- **CELT 的 TF 块数与物理短块数不同**：physical blocks 最多 8，负 TF 可使内部 PVQ
  blocks 达到 16；基本 PVQ 核必须允许 16。TF 检查需依据 `size/transient` 对应的四项
  表，不能只检查 -3..size；伪造 transient TF=-3 可把 stride 扩到 64 并越过 Hadamard 表。
  C 的 `M_SQRT1_2`/`M_SQRT2` 是 double 常量，Haar/anti-collapse 的对应乘法先在 Double
  完成再转 Float，不能提早把常量舍入成 Float。折叠向量在 TF 重排前复制，防止污染 norm。
- **CELT 连续频域历史的提交顺序**：先 PVQ、保留的 anti-collapse bit、最终能量，
  然后 anti-collapse/反归一化/静音修正。mono 再把 energy 复制到第二行；长块推进两代
  previous，transient 只取 recent 的最小值，频带外 energy=0/recent=-28。帧尾 noise seed
  必须设为 range coder 的 `range`，不能持久化最终 LCG。`OpusCeltHistory` 输入保持不变，
  只提交返回历史。静音帧安全余量可使 PVQ budget=-1，归一化入口需要保留此合法情况。
- **最小 C 树的 Opus reference callback**：若 CONFIG_OPUS_DECODER=0，`pvq_decode_band`
  会直接返回 0；对拍需显式用 `quant_band_template(..., quant=0)` 作回调，再调用原始
  `ff_celt_quant_bands`。黄金脚本为 `opus_celt_spectrum_reference.c`，同前用
  `-ffp-contract=off`。新流的 ffprobe 转换可用
  `emit_opus_multistream_vectors.mbtx --prepare --stem=NAME`，不会改动运行时依赖。
- **HLS 初始化的密钥属于声明时刻**：MAP 之后发生 KEY 轮换，不能用媒体段的当前密钥
  解密已声明的 MAP；按 key entry 缓存，同 URI 的两次声明也要区分。加密 MAP 必须显式 IV。
  `MediaFetch` 范围回调返回恰好请求的字节；短响应拒绝，Err 后游标不前进，允许重试。
- **DASH SegmentList 保留原 startNumber**：枚举使用单独 number/time 游标，不改表示层
  的 start_number。初始化和媒体字节范围均为闭区间，传给 IO 前换算为 offset/length。

---

## 8. 边界与偏差原则

- **纯算法 → MoonBit 逐行重写**。
- **向量化（SIMD）内核 → 用 MoonBit `@v128`（`moonbitlang/core/v128`，Wasm SIMD128 /
  native SIMD）重写**。FFmpeg 的 NASM（`*.asm`）**不能**编译进本模块的 `wasm` 目标，
  故它们不是"留作 FFI 的黑盒"，而是 SIMD 化的**目标对象**：实现时用
  `#cfg(any(target="native", target="wasm"))` 门控并配标量回退，参考 core 的
  `encoding/base64/encode_v128.mbt`；已移植代码的候选清单见 README §3。
- **例外（才留 C / FFI）**：MoonBit 无法表达的 x86 专有指令（AES-NI / SHA-NI /
  PCLMULQDQ 等）与线程/平台代码（`pthread`、随机源、文件/网络 IO）。
- 目前 **libavutil 内唯一**一处「按规范而非按 C 源码逐行」实现的是 `aes.mbt` 的轮函数
  （FIPS-197）；libavcodec 的 Huffman 规范化码另有等效性说明。均在 README 记录理由；
  改动实现方式时必须在源码头与 README 同步记录。

---

## 9. 批量常量表处理规范

适用于 Blowfish `orig_s`、CAST5 `S1..S8` 等大型表：

- 从对应 **C 源批量提取**十六进制常量并生成表字面量，**禁止手工转录**（易错且难查）。
- **陷阱一**：对提取结果整体 `ToUpper()` 会把 `0x` 前缀变成 `0X` → 只大写十六进制**数位**，
  或整体保持小写。
- **陷阱二**：不要对提取结果再做「行重排」等二次处理 —— 曾因此把 8 张 S-box 表**错位**，
  一版测试失败。
- 生成后**双重校验**：① 模块自带权威向量全部通过；② 与 C 源**逐值 diff == 0**。

---

## 10. 故障排查清单

- `moon check` 报错位置看起来「不可能」（例如指向 `]`）→ **按字节 hexdump 该行**核对
  （渲染会掩盖形近错拼，历史上有 `>`(0x3E) 误写成 `]`(0x5D) 的情况）。
- git 提示 `LF will be replaced by CRLF` 只是警告，不影响提交。
- 新增文件名/路径含空格时，命令中加引号。
- **超长迭代向量**（如 `libavutil/tests/cast5.c` 的 100 万次迭代）耗时过大 → 不纳入测试，
  在 README 记录来源与跳过原因。
- 运行命令统一用 Shell 工具的 `cwd` 参数指向 `moonbit`，不要 `cd` 链式拼接。

---

## 11. 目录结构（简）

```
moonbit/                      # git 仓库根
├── .gitignore                # 忽略 _build/ 等
├── moon.mod                  # name = "ffmpeg/moonbit", preferred_target = wasm
├── COPYING.LGPLv2.1          # GNU LGPL 2.1 正文（与 FFmpeg 根同名文件逐字节一致）
├── COPYING.LGPLv3            # GNU LGPL 3.0 正文（同上）
├── README.md                 # 进度 / 模块表 / 验证来源 / 约定 / 踩坑（动态信息看这里）
├── agent.md                  # 本文件（稳定约定、命令、流程）
├── libavutil/                # 包 ffmpeg/moonbit/libavutil
│   ├── moon.pkg              # 含 moonbitlang/core/v128 + warnings = "-alert_experimental"
│   ├── *.mbt                 # 各纯算法模块
│   ├── *_v128.mbt            # `@v128` SIMD 版（adler32/base64/avstring/md5）+ 同主题 wbtest
│   └── *_wbtest.mbt          # 白盒测试（含 cipher_wbtest.mbt 汇总各密码）
├── libavformat/              # 包 ffmpeg/moonbit/libavformat（依赖 libavutil + libavcodec）
│   ├── moon.pkg
│   ├── aviobuf.mbt           # 流式 AVIO 层（aviobuf.c 忠实移植）
│   ├── aviobuf_wbtest.mbt    # AVIO 白盒测试（分块源/seek 路径/dyn buf/流式 MP4 回归）
│   ├── mov.mbt               # MP4/MOV 解复用（box 遍历 + 采样表 + 碎片化 + cenc）
│   ├── extradata.mbt         # glbl（avcC 等原样）+ esds 描述符链 + AAC 配置
│   ├── frag.mbt              # sidx + mfra/tfra（mfro 探测）
│   ├── seek.mbt              # ff_index_search_timestamp + mov_seek_stream
│   ├── mp4_wbtest.mbt        # 第一批合成 box 测试
│   ├── mp4_group_wbtest.mbt  # sgpd/sbgp、open-GOP seek 差分、多 stsd 三态、frag stsd_id 门
│   ├── mp4_editlist_wbtest.mbt # advanced_editlist：mov_fix_index 各分支 + video_delay + 碎片禁用时序
│   ├── ebml.mbt              # Matroska EBML 层（原语 + 通用游走器 + level-1 注册表）
│   ├── matroska.mbt          # Matroska 切片 1+2：EBML 头 + Segment/Info/SeekHead
│   ├── matroska_track.mbt    # Matroska 切片 3：TrackEntry 全表
│   ├── matroska_block.mbt    # Matroska 切片 4：Cluster/Block 与三种 lacing
│   ├── rawaudio.mbt          # 裸 ADTS AAC / MPEG 音频分帧（ID3/Xing/Info/VBRI）
│   ├── codec_tags.mbt        # Matroska CodecID / MP4 fourcc 映射
│   ├── codec_parameters.mbt  # 容器 + extradata → CodecParameters
│   ├── ebml_wbtest.mbt       # EBML 白盒测试（VINT 规范向量 + 游走器路径）
│   ├── ebml_real_wbtest.mbt  # 真实 webm/mkv 头（docker，base64 内嵌）
│   ├── mkv_segment_wbtest.mbt # Segment 切片测试（合成布局 + 真实 1024 字节前缀）
│   ├── mkv_track_wbtest.mbt  # Tracks 切片测试（合成轨道 + 真实 webm/mkv 轨道）
│   ├── mkv_cluster_wbtest.mbt # Cluster 切片测试（lacing + 真实 packet 表）
│   ├── mkv_cluster_realdata_wbtest.mbt # Cluster 真实文件 base64 素材
│   ├── rawaudio_wbtest.mbt   # 真实 AAC/MP3 逐帧比对 ffprobe
│   ├── codec_parameters_wbtest.mbt # avcC/hvcC/ASC + 真实 MP4/MKV 轨道
│   ├── mp4_extra_wbtest.mbt  # 第二批合成 box 测试（extradata/sidx/seek/音频分块…）
│   └── mp4_real_wbtest.mbt   # 真实文件交叉验证（两批，docker ffmpeg/ffprobe）
└── libavcodec/               # 包 ffmpeg/moonbit/libavcodec（@math/@v128 + libavutil 仅白盒测试用）
    ├── moon.pkg
    ├── bitstream.mbt         # get_bits + Exp-Golomb
    ├── h2645_parse.mbt       # RBSP/NAL 拆分（Annex B + 长度前缀）
    ├── h2645_vui.mbt         # 公共 VUI
    ├── h264_ps.mbt           # H.264 SPS/PPS/VUI + avcC
    ├── h264_slice.mbt        # H.264 I/P slice header（B/SP/SI 拒绝）
    ├── h264_cavlc.mbt        # CAVLC 残差 + dequant/chroma-QP 表
    ├── h264_idct.mbt         # H.264 4x4 IDCT + DC Hadamard（8-bit）
    ├── h264_pred.mbt         # 帧内预测 4x4/16x16/chroma 8x8
    ├── h264_decode.mbt       # Baseline I 帧重建 + 环路滤波编排 + Annex B 入口
    ├── h264_deblock.mbt      # 去块滤波核（h264dsp）+ 边界强度推导（h264_loopfilter）
    ├── h264_sei.mbt          # H.264 SEI 消息框架 + 公共消息集
    ├── cabac.mbt             # CABAC 算术解码核心 + 上下文初值派生
    ├── h264_cabac_tables.mbt # CABAC 算术表 + 上下文初值表（脚本批量提取）
    ├── h264_cabac_mb.mbt     # CABAC I 宏块解析（mb_type/CBP/残差）
    ├── h264_mb.mbt           # CAVLC/CABAC 共用的宏块重建
    ├── h264_mc.mbt           # 运动补偿（luma qpel + chroma 1/8 + 边界复制）
    ├── h264_mvpred.mbt       # MV 预测（A/B/C、mid_pred、P_SKIP）
    ├── h264_inter.mbt        # P 宏块层（skip/type/ref/mvd + inter 残差）
    ├── h264_dpb.mbt          # 滑窗 DPB + H264Decoder（Annex B/avcC 入口）
    ├── aac_ics.mbt           # AAC ICS 语法（ics_info/section/pulse/TNS/gain-control）
    ├── aac_mdct.mbt          # AAC IMDCT/加窗（四窗口序列 + KBD/正弦窗）
    ├── aac_coupling.mbt      # CCE 三耦合位置、增益与标签历史
    ├── aac_stereo.mbt        # CPE、M/S/强度立体声、独立声道状态
    ├── aac_layout.mbt        # 默认 1..7/11..14 / 三层 PCE / FFmpeg 元素排序 / DSE
    ├── aac_config.mbt        # ASC/GA/PCE 初始化与 AAC-LC 解码器工厂
    ├── aac_spectrum.mbt      # AAC 频谱解码（码书 1..11/scalefactor/pulse/PNS/TNS）
    ├── aac_tables.mbt        # AAC 解码表（脚本批量提取）
    ├── hevc_ps.mbt           # HEVC VPS/SPS/PPS/PTL/RPS + hvcC
    ├── hevc_slice.mbt        # HEVC slice header（I/P/B、RPS、权重表、对齐位）
    ├── hevc_sei.mbt          # HEVC SEI
    ├── hevc_access_unit.mbt  # HEVC 访问单元组装 + POC 跟踪
    ├── hevc_cabac.mbt        # HEVC CABAC 引擎
    ├── hevc_cabac_syntax.mbt # HEVC CABAC 语法元素
    ├── hevc_intra.mbt        # HEVC 帧内预测（33 模式）
    ├── hevc_scan.mbt         # HEVC 系数扫描
    ├── hevc_transform.mbt    # HEVC IDCT/DST/反量化/residual
    ├── hevc_intra_ref.mbt    # HEVC 参考样本可用性/邻域
    ├── hevc_picture.mbt      # HEVC 图像缓冲
    ├── hevc_residual.mbt     # HEVC 残差解码
    ├── hevc_deblock.mbt      # HEVC 去块滤波
    ├── hevc_sao.mbt          # HEVC SAO
    ├── hevc_intra_decode.mbt # HEVC I 片整帧解码器
    ├── hevc_refs.mbt         # HEVC 参考帧管理（DPB/RPS/L0/L1/MV 缩放）
    ├── hevc_mc.mbt           # HEVC 运动补偿（qpel/epel uni/bi/加权）
    ├── hevc_inter.mbt        # HEVC inter 语法（merge/AMVP/mvd）
    ├── hevc_inter_decode.mbt # HEVC P/B 帧级驱动 + bS
    ├── audio_headers.mbt     # ADTS + MPEG 音频帧头
    ├── mp3_tables.mbt        # Layer III 码表/Huffman 表
    ├── mp3_dsp.mbt           # 定点 IMDCT/DCT32/合成窗
    ├── mpa_layer12.mbt       # Layer I/II 定点解码器（分配/scalefactor/组量化）
    ├── mpa_layer12_tables.mbt# Layer I/II 分配表 + 派生定点缩放/除法表
    ├── mp3_decode.mbt        # Layer III 定点解码器 + 三层共用合成滤波
    ├── idct.mbt              # SIMPLE-C IDCT + idctdsp 辅助（标量，Array[Int]）
    ├── idct_v128.mbt         # IDCT 的 `@v128` 版（块/像素用字节缓冲）
    ├── dctref.mbt            # 双精度参考 DCT/IDCT（IDCT 测试的期望值来源）
    ├── huffman.mbt           # Huffman 树/码长 + 规范化码编解码
    ├── mpeg4audio.mbt        # AudioSpecificConfig 解析（esds/AAC 用）
    ├── bitstream_wbtest.mbt
    ├── h2645_parse_wbtest.mbt
    ├── h264_ps_wbtest.mbt
    ├── h264_slice_wbtest.mbt
    ├── h264_decode_wbtest.mbt      # 逐帧 YUV MD5 + 未支持输入负例
    ├── h264_decode_realdata_wbtest.mbt  # 码流 base64 + 期望 MD5（含生成命令）
    ├── h264_cabac_wbtest.mbt       # tests/cabac.c 参考编码器 + 逐比特向量
    ├── h264_inter_wbtest.mbt       # MC/mvpred 单元测试
    ├── h264_psynth_wbtest.mbt      # 合成 CABAC P 帧端到端（I_PCM 参考 + MV 平移）
    ├── aac_wbtest.mbt              # ICS/TNS 逐字段 + MDCT/TDAC + 静音帧 PCM
    ├── mp3_decode_wbtest.mbt
    ├── mp3_decode_realdata_wbtest.mbt
    ├── hevc_ps_wbtest.mbt
    ├── audio_headers_wbtest.mbt
    ├── idct_wbtest.mbt
    ├── idct_v128_wbtest.mbt
    ├── huffman_wbtest.mbt
    └── mpeg4audio_wbtest.mbt
```

---

## 12. 许可证

本仓库是 FFmpeg 的衍生移植，遵循 **LGPL-2.1-or-later**（见 `moon.mod` 与各源文件头部）。
新增文件须保留原始 C 文件的版权与作者信息。

许可证正文在仓库根：`COPYING.LGPLv2.1`（v2.1 全文）与 `COPYING.LGPLv3`（v3 全文），
均从 FFmpeg 仓库根同名文件**逐字节复制**（不要改写正文、不要重新折行）。改许可证相关
文件时用 `md5sum` 与 FFmpeg 源树对照确认未被编辑器改动。
