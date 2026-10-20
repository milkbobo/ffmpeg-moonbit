# FFmpeg → MoonBit 重构计划与进度

用 MoonBit 重写 FFmpeg 9.0.2。仓库是完整的 FFmpeg 源码（4652 个 C/H 文件、约 66 MB 源码、
约 160 万行 C 代码，实测 1,595,275 行），本文档记录这项工作的**范围界定、重构计划、当前进度与移植约定**。

MoonBit 模块位于本目录（`moonbit/`），与 FFmpeg 的 C 源码并存，互不修改。

---

## 1. 范围与策略

一次重写整个 FFmpeg 不现实：

- libavcodec 单个库就有 38 MB 源码（占总量的 57%）；
- 大量代码依赖 x86/ARM 内联汇编、SIMD intrinsics、指针运算、宏元编程与平台特定实现；
- 这些部分**大多无法逐行"翻译"**成 MoonBit（其中**向量化内核改用 MoonBit `@v128` 重写**，
  见下方边界原则）。

因此采用**垂直切片（vertical slice）**策略：从自包含、可独立验证的纯算法模块入手，
每个模块都对照 C 源码逐行移植，并用 FFmpeg **自己的测试与 FATE 参考输出**做向量校验。
编译目标为 `wasm`/`wasm-gc`（纯算法无需 C 工具链，`moon test` 可直接验证）。

**边界原则（2026-10 修订）**：纯算法 → MoonBit 逐行重写；**向量化（SIMD）内核 → 用
MoonBit 的 `@v128`（`moonbitlang/core/v128`，对应 Wasm SIMD128 / native SIMD）重写**。
FFmpeg 的 `*.asm` 是 x86 汇编（NASM），**无法编译进本项目当前的 `wasm` 目标**，因此它们
不是"留作 FFI 的黑盒"，而是 SIMD 化的**目标对象**：实现时用
`#cfg(any(target="native", target="wasm"))` 门控并配标量回退。仅当指令在 MoonBit 中
无法表达（AES-NI / SHA-NI / PCLMULQDQ 等 x86 专有指令）或属线程/平台范畴（`pthread`、
随机源、文件/网络 IO）时，才保留 C 实现并通过 `extern "C"` FFI 复用。

参考：全树共 **186 个 NASM 文件**（`libavcodec/x86` 113、`libavfilter/x86` 42、
`libswscale/x86` 13、`libavutil/x86` 12、`libswresample/x86` 3）；MoonBit core 自身的
`encoding/hex/encode_v128.mbt`、`encoding/base64/*_v128.mbt` 是 `@v128` 用法范本。

---

## 2. 目录结构

```
moonbit/
├── moon.mod                  # 模块声明：name = "ffmpeg/moonbit"，preferred_target = "wasm"
├── libavutil/                # 包：ffmpeg/moonbit/libavutil
│   ├── moon.pkg              # 包配置（空 = 默认）
│   ├── mathematics.mbt       # av_gcd / av_rescale_rnd / av_log2 / ...
│   ├── rational.mbt          # AVRational 全部运算
│   ├── crc.mbt               # CRC 表生成与计算
│   ├── adler32.mbt           # Adler-32
│   ├── base64.mbt            # Base64 编解码
│   ├── md5.mbt               # MD5
│   ├── sha.mbt               # SHA-1 / SHA-224 / SHA-256
│   ├── avstring.mbt          # 前缀/子串查找、strlcpy/strlcat、token、路径、转义、UTF-8
│   ├── rc4.mbt               # RC4 流密码（KSA + 密钥流/加解密）
│   ├── aes.mbt               # AES-128/192/256，ECB/CBC（S-box 表生成逐行移植）
│   ├── xtea.mbt              # XTEA 32 轮分组密码（大端/小端，ECB/CBC）
│   ├── tea.mbt               # TEA 64 轮分组密码（rounds 参数，ECB/CBC）
│   ├── blowfish.mbt          # Blowfish 16 轮 Feistel（P-array/S-box 表，ECB/CBC）
│   ├── cast5.mbt             # CAST-128（RFC 2144，40/80/128 位密钥，ECB/CBC）
│   ├── aes_ctr.mbt           # AES-CTR（keystream、分部块状态、64 位计数器）
│   └── *_wbtest.mbt          # 与模块同名的白盒测试
├── libavformat/              # 包：ffmpeg/moonbit/libavformat（依赖 libavutil + libavcodec）
│   ├── moon.pkg              # 声明上述依赖（libavformat→libavcodec 与 FFmpeg 方向一致）
│   ├── aviobuf.mbt           # 流式 AVIO 层（aviobuf.c：缓冲读/写 + dyn buf + 校验和）
│   ├── mov.mbt               # MP4/MOV 解复用器：box 遍历 + 采样表 → 每样本索引（跑在 AvioContext 上）
│   ├── extradata.mbt         # mov_read_glbl（avcC/hvcC/av1C 原样）+ esds 描述符链 + AAC 配置
│   ├── frag.mbt              # sidx 参考 + mfra/tfra 随机访问表（含 mfro 探测）
│   ├── seek.mbt              # ff_index_search_timestamp + mov_seek_stream
│   ├── aviobuf_wbtest.mbt    # AVIO 白盒测试（分块源/seek 路径/dyn buf/get_str/流式 MP4）
│   ├── mp4_group_wbtest.mbt  # 第三切片白盒测试（sgpd/sbgp、open-GOP seek、多 sample description）
│   ├── mp4_editlist_wbtest.mbt # 第四切片白盒测试（advanced_editlist：mov_fix_index 全量）
│   ├── mp4_wbtest.mbt        # 合成 MP4 构造器与白盒测试
│   ├── mp4_extra_wbtest.mbt  # 第二切片白盒测试（extradata/sidx/mfra/senc/saiz/seek/音频分块）
│   ├── mp4_real_wbtest.mbt   # 真实文件交叉验证（docker ffmpeg/ffprobe，base64 内嵌）
│   ├── ebml.mbt              # Matroska/WebM EBML 层（变长整数原语 + 通用元素游走器）
│   ├── matroska.mbt          # Matroska 切片 1+2：EBML 头 + Segment/Info/SeekHead/resync
│   ├── matroska_track.mbt    # Matroska 切片 3：TrackEntry 全表（video/audio/encodings）
│   ├── ebml_wbtest.mbt       # EBML 白盒测试（VINT 规范向量/游走器/合成与损坏头部）
│   ├── ebml_real_wbtest.mbt  # 真实 webm/mkv 头交叉验证（docker ffmpeg，base64 内嵌）
│   ├── mkv_segment_wbtest.mbt # Segment 切片测试（合成布局 + 真实 1024 字节前缀）
│   └── mkv_track_wbtest.mbt  # Tracks 切片测试（合成轨道 + 真实 webm/mkv 轨道）
└── libavcodec/               # 包：ffmpeg/moonbit/libavcodec（依赖 libavutil，仅白盒测试用）
    ├── moon.pkg              # moonbitlang/core/math + libavutil（`for "wbtest"`）
    ├── idct.mbt              # SIMPLE-C IDCT（int16 8/10/12 bit）+ idctdsp 像素/扫描表辅助
    ├── dctref.mbt            # 双精度参考 DCT/IDCT（dctref.c），供 IDCT 测试作期望值
    ├── huffman.mbt           # Huffman 树/码长构建（huffman.c）+ 规范化码编解码
    ├── mpeg4audio.mbt        # AudioSpecificConfig 解析（mpeg4audio.c，esds/AAC 用）
    ├── idct_wbtest.mbt       # 对照 dctref 参考 + FFmpeg dct.c 判据
    ├── huffman_wbtest.mbt    # Kraft/最优性/两实现互证/往返
    └── mpeg4audio_wbtest.mbt # 位串手推的 AAC-LC/SBR/PS/USAC/ALS 头部用例
```

## 3. 当前进度

**总体**：全量 FFmpeg 约 160 万行，本次完成 MoonBit 源文件（`moonbit/**/*.mbt`，不含
`_build` 生成文件）共 **20817 行**（libavutil 5995 行 + libavformat 的 aviobuf 流式
AVIO 层、MP4 解复用切片与 Matroska EBML/Segment/Tracks 层 12242 行 +
libavcodec 的 IDCT/Huffman/MPEG-4 音频切片 2580 行，
均含白盒测试）——约占整体 **1.30%**。

### 已完成模块（阶段 0 + 阶段 1 开端 + 阶段 4/5 开端）

| 模块 | 对应 C 源码 | 移植内容 | 测试 |
|---|---|---|---|
| [mathematics.mbt](libavutil/mathematics.mbt) | `libavutil/mathematics.c`、`intmath.h` | `av_gcd`(Stein 二进制 GCD)、`av_rescale_rnd`(128 位拆分乘法 + 位长除法)、`av_rescale`/`av_rescale_q`/`av_rescale_q_rnd`、`av_log2`、`ff_ctzll`、`av_compare_ts`、`av_compare_mod` | ✅ |
| [rational.mbt](libavutil/rational.mbt) | `libavutil/rational.c` | `AVRational`、`av_make_q`、`av_cmp_q`、`av_q2d`、`av_inv_q`、`av_reduce`、`av_mul_q`/`av_div_q`/`av_add_q`/`av_sub_q`、`av_d2q`(自实现 `frexp`)、`av_gcd_q`、`av_q2intfloat` | ✅ |
| [crc.mbt](libavutil/crc.mbt) | `libavutil/crc.c` | `AVCRCId`、`av_crc_init`(任意多项式表生成)、`av_crc_get_table`、`av_crc`、`av_crc_ids` | ✅ |
| [adler32.mbt](libavutil/adler32.mbt) | `libavutil/adler32.c` | `av_adler32_update`（标量，`DO1`/`DO4`） | ✅ |
| [adler32_v128.mbt](libavutil/adler32_v128.mbt) | 同上 + FFmpeg 的 SSE2/AVX2 路径 | `av_adler32_update_v128`：16 字节块内用 `i32x4_dot_i16x8_s`（`pmaddwd` 等价）一次算出 `Σb` 与 `Σ(16-i)·b`，`NMAX=5552` 模数纪律；`#cfg(any(target="native", target="wasm"))`，其余目标回退标量。测试断言与标量逐值一致 | ✅ |
| [base64.mbt](libavutil/base64.mbt) | `libavutil/base64.c` | `av_base64_encode`、`av_base64_decode`、`av_base64_decode_syntax`、`av_base64_size` | ✅ |
| [base64_v128.mbt](libavutil/base64_v128.mbt) | 同上 + FFmpeg `base64.asm` | `av_base64_encode_v128`：12 字节 → 16 字符/轮；`i8x16_swizzle` 展开成 `[b0,b1,b2,0,…]`，四个 6-bit 字段由 `i32x4` 移位/掩码取得，`i32x4→i16x8→i8x16` 窄化 + `i8x16_shuffle` 重排，字母表无分支比较映射；尾部回退标量 | ✅ |
| [md5.mbt](libavutil/md5.mbt) | `libavutil/md5.c` | `AVMD5`、`av_md5_init/update/final/sum` | ✅ |
| [md5_v128.mbt](libavutil/md5_v128.mbt) | 同上（多缓冲 4 路并行） | `av_md5_sum_x4`：`i32x4` 的 4 个 lane 各承载一条**等长**消息，`T[i]` 常量、`F`/`G`/`H`/`I` 混合与 `rotl(S[i])` 全部逐 lane 施加，一轮同时推进 4 条摘要（单流 MD5 无 SIMD 收益，故新增多缓冲 API）；每路按各自长度填充到 `nblocks*64` 平面缓冲，块调度跨 lane 一致。`#cfg(any(target="native", target="wasm"))`；测试与标量 `av_md5_sum` 逐 lane 逐值一致 | ✅ |
| [sha.mbt](libavutil/sha.mbt) | `libavutil/sha.c` | `AVSHA`、`av_sha_init/update/final/sum`（SHA-1/224/256） | ✅ |
| [avstring.mbt](libavutil/avstring.mbt) | `libavutil/avstring.c`、`bprint.c`(`av_bprint_escape`) | `av_strstart`/`av_stristart`/`av_stristr`/`av_strnstr`、`av_strlcpy`/`av_strlcat`、`av_strcasecmp`/`av_strncasecmp`、`av_get_token`、`av_strireplace`、`av_basename`/`av_dirname`/`av_append_path_component`、`av_match_name`/`av_match_list`、`av_escape`(QUOTE/XML/BACKSLASH 三模式 + flag)、`av_utf8_decode` | ✅ |
| [avstring_v128.mbt](libavutil/avstring_v128.mbt) | 同上（扫描加速） | `av_strnstr_v128`：以 8 个 UTF-16 码元为步长用 `v128_load_i16x8` + `i16x8_eq` + `i16x8_bitmask` 先扫首字符，命中再标量核对；语义与 `av_strnstr` 完全一致，仅 BMP（码元==码点）走 SIMD | ✅ |
| [rc4.mbt](libavutil/rc4.mbt) | `libavutil/rc4.c` | `AVRC4`、`av_rc4_alloc`、`av_rc4_init`(KSA，key_bits 非 8 倍数报错)、`av_rc4_crypt`(密钥流/加解密) | ✅ |
| [aes.mbt](libavutil/aes.mbt) | `libavutil/aes.c` | `AVAES`、`av_aes_init`(128/192/256 密钥扩展 + S-box 表生成)、`av_aes_crypt`(ECB / CBC，含 iv 链式更新)。**轮函数按 FIPS-197 规范实现**，见下方说明 | ✅ |
| [xtea.mbt](libavutil/xtea.mbt) | `libavutil/xtea.c` | `AVXTEA`、`av_xtea_alloc`、`av_xtea_init`(大端密钥装载)、`av_xtea_le_init`(小端)、`av_xtea_crypt`/`av_xtea_le_crypt`(ECB / CBC，含 iv 链式更新)。32 轮用 `CONFIG_SMALL` 循环形式（与 C 展开版等价） | ✅ |
| [tea.mbt](libavutil/tea.mbt) | `libavutil/tea.c` | `AVTEA`、`av_tea_alloc`、`av_tea_init`(大端密钥 + `rounds` 参数，标准 64)、`av_tea_crypt`(ECB / CBC，含 iv 链式更新)。Feistel 网络 `rounds/2` 个双轮，delta `0x9E3779B9` | ✅ |
| [blowfish.mbt](libavutil/blowfish.mbt) | `libavutil/blowfish.c` | `AVBlowfish`、`av_blowfish_alloc`、`av_blowfish_init`(P-array 密钥异或 + 用 (0,0) 反复加密重导出 P/S)、`av_blowfish_crypt_ecb`(16 轮 Feistel，返回两半)、`av_blowfish_crypt`(ECB / CBC，含 iv 链式更新)。`orig_p`/`orig_s` 表逐值移植 | ✅ |
| [cast5.mbt](libavutil/cast5.mbt) | `libavutil/cast5.c` | `AVCAST5`、`av_cast5_alloc`、`av_cast5_init`(40/80/128 位密钥 → `Km`/`Kr` 轮密钥，`Kr` 掩到 5 位)、`av_cast5_crypt`(ECB)、`av_cast5_crypt2`(CBC)。`F1/F2/F3` 轮函数与 `COMPUTE_Z/COMPUTE_X` 密钥调度；`S1`..`S8` 表由 C 源码逐值提取 | ✅ |
| [aes_ctr.mbt](libavutil/aes_ctr.mbt) | `libavutil/aes_ctr.c` | `AVAESCTR`、`av_aes_ctr_alloc/init`、`av_aes_ctr_set_iv`(8 字节 IV+零计数器)、`av_aes_ctr_set_full_iv`/`get_iv`(16 字节)、`av_aes_ctr_increment_iv`(BE64 高位加一)、`av_aes_ctr_crypt`(keystream 缓存 + `block_offset` 跨调用状态，支持任意切分)。`set_random_iv` 依赖平台随机源，留待 FFI | ✅ |
| [aviobuf.mbt](libavformat/aviobuf.mbt) | `libavformat/aviobuf.c`（1484 行） | `AvioContext`：回调驱动的缓冲 IO（`read_packet`/`write_packet`/`seek` 闭包）。**读侧**：`fill_buffer` 的追加或回绕选择、探测后收缩回 `orig_buffer_size`、`avio_r8`/`rb16/24/32/64`/`rl16/24/32/64`、`avio_read`（超过缓冲的大请求直通回调）、`avio_read_partial`、`ffio_read_size/indirect`、`avio_get_str`/`get_str16le/be`（GET_UTF16 代理对）、`ff_get_line/chomp_line`、`ffio_read_varlen`/`leb`；**seek**：`avio_seek` 四路径（缓冲内快路 / short_seek 阈内读进 / 半缓冲回填 / 协议回调）+ `avio_skip/tell/size(AVSEEK_SIZE→SEEK_END 回退)/feof(清标志重测)`；**写侧**：`w8`/`write`/`flush`（回退位恢复）与 `wl/wb 16/24/32/64`、`ffio_fill`、`put_str`/`put_str16le/be`、`ffio_wfourcc`、`print_string_array`、`ffio_write_leb/lines`；**dyn buf**：`avio_open_dyn_buf`（×1.5+1 增长）/`get`/`reset`/`close`（64 字节 padding）/packet buf/null buf；**校验和**：`ff_crc04C11DB7/EDB88320/A001_update` + `ffio_init/get_checksum`（fill/flush 两侧的范围折算）；`ffio_ensure_seekback`/`ffio_realloc_buf`。未移植（无消费者）：`avio_printf` 族（需 AVBPrint）、`write_marker`、`avio_pause/seek_time`、probe/limit 辅助 | ✅ |
| [mov.mbt](libavformat/mov.mbt) | `libavformat/mov.c` | box 遍历 + `ftyp`（含 compatible brands）/`mvhd`/`tkhd`/`mdhd`/`hdlr`（仅认识 vide/soun/subp/clcp，数据 hdlr 如 `url ` 不覆盖）/`elst`/`stsd`(视频/音频 sample entry，音频含 QT v1/v2 打包字段 + `mov_int2double`)/`stts`（含 `FFMIN` 时长上限与 `track_end` 播种）/`ctts`/`stsc`/`stsz`/`stz2`/`stco`/`co64`/`stss`/`stps` 解析；`mov_merge_tts_data` 合并 + `mov_build_index` 采样索引 → 每样本 offset/size/DTS/PTS/duration/关键帧/`min_distance`/`discard`，含**未压缩音频分块路径**（1024 样本/包，MACE/ADPCM/GSM/PCM 打包默认）。**碎片化 MP4**：`moof`/`traf`/`tfhd`/`tfdt`/`trun`/`trex` 按 `default-base-is-moof` + `tfdt`/`sidx`/`track_end` 追加每样本索引，按 `trun` 采样标志判定关键帧，重叠片段置 `AVINDEX_DISCARD_FRAME`。**cenc 加密**：`sinf`/`schm`/`tenc`/`senc`（流级 + 碎片内）/`saiz`/`saio`（辅助信息块）解析 + `mov_decrypt_sample`（`cenc`/`cbc1`/`cens`/`cbcs`，基于 `aes_ctr`）；**sample group**：`sgpd`('sync' NAL 类型)/`sbgp`('rap '/'sync' run) 解析 + `build_open_gop_key_points`（逐样本 ctts offset 展开、CRA 开放 GOP 样本表、最小 stts 时长）→ seek 的 `can_seek_to_key_sample`（`pts = dts + offset + dts_shift > 请求点` 即拒绝 + 回退步进）；**多 sample description**：`ff_mov_read_stsd_entries` 逐 entry 走查（`mov_skip_multiple_stsd` 同 fourcc 才续析）、extradata 槽位（仅 slot 0 会被写入 —— 后续 entry 的 `pseudo_stream_id` 为 -1，C 对 `sc->extradata[-1]` 的越界写按无操作处理并记录）、`pseudo_stream_id` 索引过滤（-1 全收，否则只收 `stsc.id-1` 匹配的 chunk）、tfdt/trun 的 `stsd_id` 门（tfhd 旗标或 trex 默认）、首 chunk 引用 entry 2 时的 `last_stsd` 主 extradata 切换；**advanced edit list**（`mov_fix_index` 全量）：`get_edit_list_entry`（时长换算到轨道时标，u64 回绕判据照抄）、`find_prev_closest_index`（关键帧回退 + ctts 精化）、按 edit 时间轴重建索引（前导弃帧经 frame-duration 缓冲重写为严格递增时间戳、空 edit 平移时间轴并成为 `start_time`、音频部分帧修剪 `skip_samples`、正 `min_corrected_pts` 将首个视频 PTS 归零）、tts 重建 + PTS 重导出、时长钳制、`mov_estimate_video_delay`（H264 重排估计）、mov_read_trak 的 stsc 清理 quirk 与碎片化自动禁用（顺序敏感）；`av_mov_open_with(buf, false)` 走非 advanced 路径 | ✅ |
| [extradata.mbt](libavformat/extradata.mbt) | `mov.c`(`mov_read_glbl`)、`mov_esds.c`/`isom.c`(`ff_mov_read_esds`、`ff_mp4_read_descr*`、`ff_mp4_read_dec_config_descr`、`ff_mp4_obj_type`) | `avcC`/`hvcC`/`av1C`/`glbl`/`vvcC`(跳 4 字节)/`evcC`/`lvcC`/`apvC` 载荷原样入 extradata（含 `fiel` 包裹的破损文件回退）；`esds` 走 ES→DecoderConfig→DecoderSpecificInfo 描述符链（`ff_mp4_read_descr_len` 7 位长度、ES flags 的 URL/OCR 字段），对象类型表 → codec-id 字符串，MPEG 音频无 DSI 特例；AAC 时解析 AudioSpecificConfig 回填声道/采样率/帧长，`mp3on4`/`mp4als` 覆盖 | ✅ |
| [frag.mbt](libavformat/frag.mbt) | `mov.c`(`mov_read_sidx`、`mov_read_mfra`、`read_tfra`) | `sidx` v0/v1：参考 ID/时间戳/earliest_presentation_time/first_offset（锚点为入口 position+payload，`av_rescale_q` 换算到轨道时间戳）+ 每参考 offset/pts/size/duration，累计 pts 即 `track_end` 与时长；`mfra`：从文件尾 4 字节（`mfro`）探测大小、校验后读 `tfra`（v0/v1 时间+offset，field_length 定长的三个尺寸字段） | ✅ |
| [seek.mbt](libavformat/seek.mbt) | `mov.c`(`mov_seek_stream`、`can_seek_to_key_sample`)、`seek.c`(`ff_index_search_timestamp`) | 二分查找（丢弃帧跳过、BACKWARD/ANY 语义、关键帧回退）+ 时间戳 seek：`dts_shift` 折算、越界钳到首样本、`min_sample_duration` 回退步进、HEVC open-GOP 门（无 sgpd 时的无操作形式）；`mov_seek_track` 返回样本序号与 DTS；seek 入口按 C 减去 `min_corrected_pts + dts_shift`（advanced_editlist 产出） | ✅ |
| [ebml.mbt](libavformat/ebml.mbt) | `libavformat/matroskadec.c`（EBML 读取层；9.0 无独立 ebml.c） | 变长整数原语：`ebml_read_num`（首字节前导零定宽 + 标志位清除）、`ebml_read_length`（全一宽度 → 未知长度）、`ebml_read_uint/sint`（首字节符号扩展）/`float`（binary32/64 重构含 inf/NaN）、`ascii`（lenient UTF-8）、`binary`、`ebml_read_master`（16 层深度栈）、`matroska_ebmlnum_sint`（lace 尺寸再偏置）、`is_ebml_id_valid`（标志位与字节长度一致）；**通用元素游走器** `ebml_parse`/`ebml_parse_nest`：`current_id` 预读状态、level_check（元素越界即错 / 末端相等 → LEVEL_ENDED 多层连弹）、`max_lengths[]` 每类型上限、VOID/CRC32/未知元素跳过（非 seekable 的 unknown_count × UNKNOWN_EQUIV > SKIP_THRESHOLD 启发式）、NEEDS_CHECKING → EOF→EIO 转换、未知长度 master 遇上层元素终止（C 的 CHILD_OF 哨兵链 → 祖先栈）、live 模式 EOF 即止。**表驱动模型**：C 的 `EbmlSyntax{type,def,data_offset}` → `EbmlKind` + sink 闭包 + 子表 thunk（无环引用） | ✅ |
| [matroska.mbt](libavformat/matroska.mbt) | `matroskadec.c`（`ebml_header[]`/`ebml_syntax[]` 表 + `matroska_read_header` 头部校验链） | `EbmlHeader`（ReadVersion/MaxIDLength/MaxSizeLength/DocType/DocTypeReadVersion，默认值 = C 的 zero-init + nest 预置遍历）；`matroska_read_ebml_header`：解析头元素（缺 Segment 在此阶段不算失败，与 C 一致）、版本越界 → `PATCHWELCOME`、DocTypeReadVersion 3 → 警示、未知 doctype → 警示标志 | ✅ |
| [ebml.mbt](libavformat/ebml.mbt) + [matroska.mbt](libavformat/matroska.mbt)（切片 2） | `matroskadec.c`（`matroska_segment[]`/`matroska_segments[]`/`matroska_info[]`/`matroska_seekhead[]` 表、`matroska_read_header` 段走查、`matroska_execute_seekhead`/`matroska_parse_seekhead_entry`、`matroska_resync`/`matroska_reset_status`、`matroska_find_level1_elem`） | Segment 走查：首个 Cluster 即 `EBML_STOP`（data_offset = 其 id 起点），损坏输入经 `matroska_resync`（32 位滑窗找 level-1 id + 状态重置 + 未知长度级别）恢复；**Info**（TimecodeScale 默认 1e6/Duration 浮点/Title/MuxingApp/DateUTC，WritingApp/SegmentUID 按 C 跳过）；**SeekHead**（SeekID/SeekPosition，条目在 master 开始时按 C 的 EbmlList 语义追加）；**execute_seekhead**（仅 seekable：按条目回跳解析未过的 level-1 元素——CUES 恒延迟、失败标记 cues broken——dummy level + 位置恢复的 crude hack 照抄）；**level-1 注册表**（容量 64、SeekHead/Tags 按 id+pos 去重、Cluster/非法 id 排除、segment_start/cues_parsing_deferred 簿记并入游走器）；入口 `av_matroska_open`（Attachments/Chapters/Cues/Tags 识别为跳过，待后续切片） | ✅ |
| [matroska_track.mbt](libavformat/matroska_track.mbt) | `matroskadec.c`（`matroska_tracks[]`/`matroska_track[]`/`matroska_track_video[]`/`matroska_track_audio[]`/`matroska_track_encodings[]`/`matroska_block_addition_mapping[]`） | `MkvTrack` 全字段（TrackNumber/UID/Type/CodecID/CodecPrivate/CodecDelay/语言默认 eng/DefaultDuration/TimecodeScale 默认 1.0/五组旗标默认值/SeekPreRoll/MaxBlockAdditionID）+ `MkvTrackVideo`（Pixel/Display 尺寸默认 -1 未设、四向 crop、DisplayUnit、Interlaced/FieldOrder/StereoMode/AlphaMode、ColourSpace 二进制）+ `MkvTrackAudio`（采样率默认 8000、输出采样率、位深、声道默认 1）+ ContentEncodings（Scope 默认 1、Type、CompAlgo 默认 zlib、CompSettings；加密行识别跳过）+ BlockAdditionMapping。TrackOperation（3D）与 colour/projection masters 识别跳过待后续。轨道经 TRACKS Level1 行按 Entry 追加 | ✅ |
| [mpeg4audio.mbt](libavcodec/mpeg4audio.mbt) | `libavcodec/mpeg4audio.c`、`mpeg4audio_sample_rates.h` | `ff_mpeg4audio_get_config`：对象类型（32+ escape）、采样率表/24 位显式、声道配置表、头部隐式 SBR/PS、ALS 头嗅探与重载、USAC/LD 帧长、`0x2b7`/`0x548` 隐式 SBR/PS 同步扩展扫描、PS 修正（含 `channels & ~1`）。返回 GASpecificConfig 位偏移与 C 一致 | ✅ |
| [idct.mbt](libavcodec/idct.mbt) | `libavcodec/simple_idct.c`、`simple_idct_template.c`（`BIT_DEPTH` 8/10/12 + `IN_IDCT_DEPTH` 16）、`idctdsp.c` | `ff_simple_idct{,_put,_add}_int16_{8,10,12}bit`（行 DC 快速路径 + 列蝶形，`SUINT`→`UInt` 32 位回绕算术）；`ff_put_pixels_clamped_c`/`ff_add_pixels_clamped_c`/`put_signed_pixels_clamped_c`、`ff_init_scantable_permutation`、`ff_permute_scantable` | ✅ |
| [idct_v128.mbt](libavcodec/idct_v128.mbt) | 同上（表示改造 + `libavcodec/x86/simple_idct.asm`、`simple_idct10.asm`） | `ff_simple_idct{,_put,_add}_v128`（8 位）与 `..._v128_10bit`/`..._v128_12bit`：块改用 **128 字节 LE-int16 缓冲**；`i8x16_shuffle` 三级 unpack 做 8x8 转置，`i32x4` 逐 lane 蝶形 + `i16x8_narrow_i32x4_s` 收窄（含 int16 截断语义）；`put`/`add` 用饱和窄化（8 位）或 `i16x8_min/max_s`（10/12 位）实现 `av_clip_uintp2` | ✅ |
| [huffman.mbt](libavcodec/huffman.mbt) | `libavcodec/huffman.c`、`huffman.h`（+ `vlc.c`/`get_bits.h` 的位读取） | `ff_huff_build_tree`（两列表树构建 + `get_tree_codes` DFS → `lens`/`xlat`）、`ff_huff_gen_len_table`（堆法码长生成，含 `offset <<= 1` 重试）；另附规范化 Huffman 码的建立与 MSB-first 编/解码（对应 `ff_vlc_init_from_lengths` + `put_bits`/`get_bits`） | ✅ |

**当前状态**：`moon check` 0 error / 0 warning，`moon test` **128/128 通过**（libavutil 69 + libavformat 32 + libavcodec 27）。

### AES 的实现偏差（已记录）

`aes.mbt` 是 **libavutil 内唯一一处**按规范而非按 C 源码逐行实现的地方（libavcodec 的
Huffman 规范化码另有等效性说明，见下文）：

- **逐行移植**的部分：S-box / 逆 S-box 的生成（`aes_init_static` 的 log8/alog8 + 仿射变换）、
  `rcon` 表、密钥扩展的 Rcon/SubWord 结构（含 AES-256 的 `KC == 8 && j == KC >> 1` 特例）。
- **按 FIPS-197 规范实现**的部分：轮函数（SubBytes / ShiftRows / MixColumns / AddRoundKey
  及其逆）。FFmpeg 的 `subshift` / `mix` / `multbl` 表驱动内核是同一算法的等价优化，
  其字节布局依赖小端 `u32`/`u64` 类型双关与 `sizeof(av_aes_block)` 指针运算；复刻风险高、
  零行为收益，而 FIPS-197 形式可用官方标准向量直接验证。
- **后果**：轮密钥按 FIPS-197 顺序存放，而非 FFmpeg 内部对解密预变换的形式；
  `av_aes_init` / `av_aes_crypt` 的签名与 ECB/CBC 行为保持一致。

### libavcodec 切片（IDCT + Huffman）的范围边界与说明

- **已做（IDCT）**：`simple_idct_template.c` 的 `int16` 输入三档（`BIT_DEPTH` 8/10/12，
  均 `IN_IDCT_DEPTH == 16`）的 `put`/`add`/原地变换，以及 `idctdsp.c` 的钳位像素与扫描表
  辅助。C 宏（`W1..W7`、`ROW_SHIFT`/`COL_SHIFT`/`DC_SHIFT`、`MUL16`/`MAC16`）化为
  MoonBit 常量与内联算术；`SUINT` 用 `UInt`（32 位回绕）复刻生产构建的溢出语义，写回
  块时按 `int16` 截断（`i16`）。
- **未做（IDCT）**：`int32` 输入变体 `ff_simple_idct_*_int32_10bit`（MPEG-4 Simple Studio
  Profile）、2x4x8/8x4/4x8 的部分变换（DV/WMV2 的 `idct248`/`84`/`48`/`44`）、整数
  `FF_IDCT_INT`（`jrevdct.c`）、FAAN、Xvid 的**标量 C** 实现；其 x86 SIMD 变体
  （`libavcodec/x86/simple_idct.asm`、`simple_idct10.asm`、`idctdsp.asm`）按新边界原则
  列入下方「`@v128` 重写」清单，而非"留在 C"。
- **已做（Huffman）**：`ff_huff_build_tree`（排序 + 两列表原地合并 + `get_tree_codes` DFS）
  与 `ff_huff_gen_len_table`（堆 + `offset <<= 1` 长度上限重试）。二者返回 `(lens, xlat)`，
  即 `ff_vlc_init_from_lengths` 需要的输入。
- **说明 / 偏差（Huffman）**：不移植整个 VLC 子系统（`vlc.c` 的多级查表）；为使结果可
  解码验证，另按规范化 Huffman 规则由 `(lens, xlat)` 直接生成码字并做 MSB-first 编/解码
  （与 `ff_vlc_init_from_lengths` 的「按发射序累加码字」在码长非递减时等价）。FFmpeg 的
  `AV_QSORT` 非稳定排序，等频次叶子的次序可能与 FFmpeg 不同，但仍是同一最优码（测试以
  Kraft 等和 + 独立教科书法的最优代价互证）。
- **未做（libavcodec）**：LZO、`vlc.c` 表构建、aac/AC-3 等音频解析、其余编解码器
  （见阶段 5）。

### SIMD（`@v128`）化候选（已移植代码）

按新边界原则，FFmpeg 原用 NASM 写的向量化内核改用 MoonBit `@v128` 重写。下表为**已移植
代码**中可 SIMD 化的位置。「FFmpeg x86 对应」列是 FFmpeg 侧同功能的 `*.asm`（仅作参照与
可行性依据，**不是**要保留的黑盒）；「—」表示该功能在 FFmpeg 中本就是标量 C（仍可选做
并行化，但无现成参照）。

| 已移植模块 | 可 SIMD 化的内核 | FFmpeg x86 对应 | 说明 / 优先级 |
|---|---|---|---|
| [adler32.mbt](libavutil/adler32.mbt) | ✅ **已完成**：`av_adler32_update_v128`（`i32x4_dot_i16x8_s` 算 Σb 与 Σ(16-i)b） | —（FFmpeg 亦为标量 C） | 高；已与标量逐值一致 |
| [crc.mbt](libavutil/crc.mbt) | —（FFmpeg 的 `crc.asm` 用 **PCLMULQDQ**，Wasm SIMD128 无法表达） | `crc.asm` | **例外 → FFI**；纯软件只能做「多路并行查表」（ILP），并非向量化 |
| [base64.mbt](libavutil/base64.mbt) | ✅ **已完成**：`av_base64_encode_v128`（`i8x16_swizzle` 展开 + `i32x4` 取字段 + `i8x16_shuffle` 重排，字母表无分支映射） | `base64.asm`（libavcodec） | 高；与标量/RFC 4648 逐值一致 |
| [idct.mbt](libavcodec/idct.mbt) | ✅ **已完成（8/10/12 位）**：`idct_v128.mbt` 的 `ff_simple_idct{,_put,_add}_v128{,_10bit,_12bit}`（块改 128 字节 LE-int16 缓冲） | `simple_idct.asm`、`simple_idct10.asm`、`idctdsp.asm` | 高；8 位与标量逐值一致；10 位满足 dct.c 判据；12 位在 dct.c 中标 `nonspec=1`（其 omse 判据不适用），实测 profile 与标量一致 |
| 同上：`ff_put/add_pixels_clamped_c` | 已由 `put`/`add` 的 SIMD 路径覆盖（`i8x16_narrow_i16x8_u` 饱和钳位） | `pixblockdsp.asm`、`blockdsp.asm` | 高；独立的 8/16 路版本待做 |
| [aes.mbt](libavutil/aes.mbt) / [aes_ctr.mbt](libavutil/aes_ctr.mbt) | —（FFmpeg 的 `aes.asm` 用 **AES-NI**，Wasm SIMD128 无法表达） | `aes.asm` | **例外 → FFI**；纯 SIMD 只能位切片重写（成本高、收益低），列低 |
| [md5.mbt](libavutil/md5.mbt) | 多缓冲 4 路并行 | —（FFmpeg 亦为标量 C） | ✅ **已完成**：`av_md5_sum_x4`（`i32x4` 承载 4 条等长消息，逐 lane 施加轮函数）；与标量逐 lane 逐值一致 |
| [sha.mbt](libavutil/sha.mbt) | 多缓冲 4 路并行（SHA-1/256 轮函数 + 消息扩展） | —（SHA-NI 属 x86 专有） | 中；**需新增多缓冲 API**（单流无收益），FFmpeg 亦为标量 |
| [rc4.mbt](libavutil/rc4.mbt) | 4/8 路并行密钥流 | — | 低 |
| [blowfish](libavutil/blowfish.mbt) / [cast5](libavutil/cast5.mbt) / [tea](libavutil/tea.mbt) / [xtea](libavutil/xtea.mbt) | 4/8 块并行 ECB/CBC | —（FFmpeg 亦为标量 C） | 低 |
| [avstring.mbt](libavutil/avstring.mbt) | ✅ **已完成**：`av_strnstr_v128`（`v128_load_i16x8` + `i16x8_eq` + `i16x8_bitmask` 扫首字符，命中再标量核对；仅 BMP 走 SIMD） | —（FFmpeg 为标量 `strstr`） | 低；已与标量逐值一致 |
| [huffman.mbt](libavcodec/huffman.mbt) | 位串 MSB-first 解码难以向量化；表驱动多符号解码可局部并行 | —（`huffyuvdsp.asm` 属另一回事） | 低；收益有限 |
| [mathematics.mbt](libavutil/mathematics.mbt) / [rational.mbt](libavutil/rational.mbt) | —（标量整数运算） | — | 排除 |
| [aviobuf.mbt](libavformat/aviobuf.mbt) / [mov.mbt](libavformat/mov.mbt) | —（缓冲管理/box 解析、采样表展开，非数据并行） | — | 排除 |

**SIMD 进度**：已完成 5 个（`adler32`、`base64` 编码、`avstring` 的 `av_strnstr`、IDCT
8/10/12 位 + 其 `put`/`add`、MD5 多缓冲 4 路）。表达性受限的说明：

- **`crc` / `aes`**：FFmpeg 对应 asm 依赖 x86 专有指令（`PCLMULQDQ` / `AES-NI`），
  Wasm SIMD128 **无法表达** → 按边界原则属 **FFI 例外**，不进 `@v128` 清单。
- **IDCT 表示改造**（已完成）：块/像素改用字节缓冲（`FixedArray[Byte]`，128 字节 LE-int16
  / 像素面），转置用 `i8x16_shuffle` 三级 unpack，蝶形 `i32x4` 逐 lane；`put` 的钳位由
  `i8x16_narrow_i16x8_u`（8 位）或 `i16x8_min/max_s`（10/12 位）完成。
  `int32` 输入变体（MPEG-4 studio）仍走标量。
- **`md5` / `sha`**：可用 `i32x4` 做 4 路并行（不依赖专有指令），但要把状态机重写为多路。
  MD5 已完成（`av_md5_sum_x4`，4 条等长消息共享同一块调度）；SHA 的多缓冲版待做。
  注意这类内核**只对多路输入有收益**，单流仍需标量路径。

**未移植库**中同样存在向量化内核，待对应模块移植时一并按 `@v128` 重写：
`libavfilter/x86`（42 个，如 `vf_*` 滤镜内核）、`libswscale/x86`（13 个，缩放/像素转换）、
`libswresample/x86`（3 个，重采样/混音）。

### MP4 demuxer 切片的范围边界

- **已做**：从内存 `Bytes` 解析整文件（调用方读文件），因此无需 AVIO/AVPacket/AVFormatContext；
  采样表全部展开为每样本索引，DTS/CTS 与 FFmpeg 的 `pkt->dts`/`pkt->pts`/`pkt->duration` 计算一致
  （含 `max_stts_delta` 裁剪、DTS 漂移修正、负 `ctts` 触发的 `dts_shift`、edit list 的
  `time_offset`、`stsc` 校验修复、`stz2` 的 MSB-first 4/8/16/32 位打包、64 位 box 长度与 `co64`）。
- **已做（碎片化 MP4）**：`moof`/`traf`/`tfhd`/`tfdt`/`trun`/`trex`；按
  `default-base-is-moof`（或显式 `base-data-offset`/`implicit_offset`）+ `tfdt` 驱动 DTS，
  无 `tfdt` 时回退 `sidx` 最早呈现时间（按 C 原样不减 `time_offset`）再回退 `track_end`；
  按 `trun` 采样标志判定关键帧、按 `dts_shift` 计算 PTS；时间重叠的片段按
  `prev_dts >= dts` 置 `discard`（`AVINDEX_DISCARD_FRAME`）。
- **已做（片段索引）**：`sidx` v0/v1 参考表（offset/pts/size/duration，锚点与 `av_rescale_q`
  换算照 C）与 `st->duration = track_end = pts` 赋值；`mfra`/`tfra` 从文件尾 `mfro` 字探测。
- **已做（extradata）**：`avcC`/`hvcC`/`av1C`/`glbl` 等载荷原样；`esds` 描述符链 +
  AAC AudioSpecificConfig（libavcodec 的 `mpeg4audio.mbt`）回填声道/采样率/帧长/codec-id。
- **已做（seek）**：`ff_index_search_timestamp` + `mov_seek_stream`（BACKWARD/ANY、关键帧
  回退、`min_sample_duration` 步进；HEVC open-GOP 门取无 sgpd 的空集形式）。
- **已做（未压缩音频分块路径）**：`stts` 单条目 duration==1 的音频轨道走 C 的 chunk 索引
  （≤1024 样本/包或按 samples_per_frame 打包；`MAC3`/`MAC6`/`ima4`/`agsm` 与
  `sowt`/`twos`/`raw`/`in24`/`in32`/`fl32`/`fl64` 的 `av_get_bits_per_sample` 映射），
  原先置 `unsupported_audio_chunk_demux` 标志后产出空表的行为已替换为真实现（标志保留作路径指示）。
- **已做（cenc）**：`sinf`/`schm`/`tenc`（方案、pattern、每样本 IV 大小与常量 IV）、
  `senc`（流级 + 碎片内，每样本 IV + 子样本表，位置对齐追加）与 `saiz`/`saio`
  （默认/逐样本尺寸 + 绝对偏移，碎片内加 `base_data_offset`，`mov_parse_auxiliary_info`
  读辅助块后恢复读位置）；`mov_decrypt_sample` 对 `cenc`/`cbc1`/`cens`/`cbcs`
  四种方案解密单个样本（密钥由调用方提供）。
- **未做**：多 sample description 轨道（`pseudo_stream_id` 过滤只建模主描述）、
  `rap_group`(sgpd/sbgp) 与 HEVC open-GOP NAL 判定、`advanced_editlist`、`dvcC`/`dvvC`
  整 atom extradata 变体、强制 `use_mfra` 模式（AUTO 下 mfra 仅作数据源）、muxer。

### 未完成（本次切片外）

- `mathematics.c` 中：`av_rescale_delta`、`av_add_stable`、`av_bessel_i0`
- `libavutil/sha512.c`（SHA-384/512）
- libavutil 其余部分：`dict`、`opt`、`pixdesc`、`samplefmt`、`intreadwrite`、
  `des/twofish/sm4`、`lzo`、`eval`、`timecode`、`parseutils` 等
- libavformat 其余部分：`aviobuf.c`/`avio.c`（流式与文件 AVIO）、其余 demuxer/muxer
  （Matroska/WebM、AVI、MPEG-TS 优先）、AAC/AC-3 等音频流解析、字幕（`tx3g`/TTML）、
  AVIF/HEIF 图像、MP4 muxer
- libavcodec 已**开始**（IDCT SIMPLE-C 与 Huffman 树/码长，见上方范围边界），其余
  （VLC 表构建、LZO、无损/有损编解码器）未做
- libswscale / libswresample / libavdevice / fftools：**未开始**

---

## 4. 验证方式

所有期望值都取自 FFmpeg 仓库内的**一手资料**，不使用自造数据：

| 被测模块 | 向量来源 |
|---|---|
| crc | `tests/ref/fate/crc`（7 组原始输出）+ `libavutil/crc.c` 内硬编码表前缀（直接验证表生成器） |
| adler32 | `libavutil/tests/adler32.c` 内断言 `0x50E6E508` + Adler-32 规范示例；SIMD 版（`adler32_v128.mbt`）另用公开向量 Adler-32("Wikipedia")=`0x11E60398`，并对生成缓冲区与标量版**逐值相等**（含 `NMAX=5552` 边界） |
| base64 | `libavutil/tests/base64.c` 的参考编码表；SIMD 版（`base64_v128.mbt`）另用 **RFC 4648 §10** 向量，并与标量版在长度 0..129、长缓冲、12 字节边界及全 256 字节值上**逐值相等** |
| avstring | `tests/ref/fate/avstring`（`av_get_token` 的 26 组 input→token→rest）+ 该测试中的 `av_append_path_component`(7 组) / `av_strireplace`(3 组) / `av_strnstr` 偏移期望；其余用例由 `avstring.c`、`bprint.c` 的算法手推。SIMD 版 `av_strnstr_v128` 与标量版在生成输入（含每个 `hay_length`、非 ASCII BMP 串）上**逐值相等** |
| md5 | `tests/ref/fate/md5`（5 组摘要：1000 / 63 / 64 / 65 / 999 字节）+ RFC 1321 向量；SIMD 多缓冲版（`md5_v128.mbt`）的 `av_md5_sum_x4` 以四路相同消息复现全部上述摘要，并与标量 `av_md5_sum` 在**每 lane、跨 0/55/56/63/64/65/119/120/128/999/1000/4096 长度的四路不同缓冲**上**逐值相等** |
| sha | `libavutil/tests/sha.c` 引用的 FIPS 180 向量（含百万个 `'a'`） |
| mathematics | `libavutil/mathematics.h` 语义 + 边界用例 |
| rational | `libavutil/tests/rational.c` 的 `unit_mul_q` / `unit_add_q` 饱和表；`av_cmp_q` 与 `double` 比较的全枚举对拍 |
| avstring | `tests/ref/fate/avstring`（`av_get_token` 的 26 组 input→token→rest）+ 该测试中的 `av_append_path_component`(7 组) / `av_strireplace`(3 组) / `av_strnstr` 偏移期望；其余用例由 `avstring.c`、`bprint.c` 的算法手推 |
| rc4 | `libavutil/tests/rc4.c` 内转录的 **RFC 6229** 密钥流向量（40/56/64/128 位密钥，各 8 字节） |
| aes | **FIPS-197** 附录 C.1/C.2/C.3 的 ECB 向量（128/192/256）与 S-box 公开值；**NIST SP 800-38A** F.2.1 的 CBC-AES128 两分组向量（含 iv 链式值）——均为独立于 FFmpeg 的官方标准 |
| xtea | `libavutil/tests/xtea.c` 内嵌的 6 组 key/明文/密文三元组（大端，另按 C 测试的字节序变换覆盖小端路径）；CBC 分支复用该测试的 `"HALLO123"` IV 与 4 分组往返。`tests/ref/fate/xtea` 仅打印成功行，不含数值 |
| tea | `libavutil/tests/tea.c` 内嵌的 4 组 key/明文/密文三元组（64 轮）；CBC 分支复用该测试的 `"HALLO123"` IV 与 4 分组往返。`tests/ref/fate/tea` 仅打印成功行 |
| blowfish | `libavutil/tests/blowfish.c` 内嵌的 **34 组可变密钥 ECB 三元组** + 字符串 ECB(`"BLOWFISH"→324ed0fe…`) / CBC(`"BLOWFISHBLOWFISH"`，IV `"blowfish"`) 向量；均为该测试自带、可直接校验大 S-box 表的权威数据 |
| cast5 | `libavutil/tests/cast5.c` 内嵌的 **RFC 2144** 向量（128/80/40 位密钥，明文 `0123456789abcdef`）；CBC 分支复刻该测试的 `av_cast5_crypt2` 往返。该测试另含 100 万次迭代向量 `rct2`，因耗时未纳入 |
| aes_ctr | `libavutil/tests/aes_ctr.c` 的固定密钥/IV 40 字节向量（`fixed_key`=`"0123456789abcdef"`、`fixed_iv`=`deadbeefdeadbeef`）；另按 CTR 性质校验「任意切分 == 一次性」以覆盖分部块状态；`increment_iv`/`set_iv` 的计数器语义按 `aes_ctr.c` 手推 |
| MP4 demuxer | 测试内**逐字节合成**的 MP4/MOV（`ftyp`+`moov`+`trak`+`stbl`+`mdat`），期望值由 box 布局与 `mov.c` 语义手算：chunk→样本 offset 累积、`stts` DTS 序列、`ctts` 重排后的 PTS、负 `ctts` 的 `dts_shift`、`stss` 关键帧、`stz2` 位打包、`co64` 与 64 位 box、`elst` 的 `time_offset`、`stsc` 校验修复；碎片化：空 `stbl` 初始化段 + 两个 `moof` 片段（`tfdt` 驱动首段、无 `tfdt` 由 `track_end` 续接），校验 offset/DTS/PTS/size/duration/关键帧；cenc：合成的加密 MP4（`sinf`+`senc`），以同密钥/IV 的 AES-CTR 生成密文，验证 `mov_decrypt_sample` 还原明文（全样本与子样本各一）；**真实文件交叉验证**：由 `linuxserver/ffmpeg:9.0.2` 生成普通/碎片化/cenc 三种真实 MP4，以 `ffprobe` 的 `packet` 输出（`pos/size/dts/pts/duration/flags`）为期望值逐 packet 比对（普通与碎片化完全一致），cenc 用已知密钥解密后与明文样本逐字节一致 |
| aviobuf | 期望值全部由 `aviobuf.c` 的缓冲/seek 路径语义手推（跨 1 字节分块的 BE/LE 读写、EOF 语义与 seek 恢复、`avio_read` 直通/短读、四条 seek 路径各自不经/必经回调、`avio_size` 双回退、写侧 flush 时机与 seekback 恢复、dyn buf 增长/packet 前缀/padding、`get_str`/`get_str16` 代理对的消费计数、leb/varlen）；CRC 三助手与已验证的 libavutil `av_crc` 同表互证，流式 checksum 与一次性计算逐位相等；**集成回归**：既有 MP4 全部测试改经 `init_read_context` 跑在 AVIO 上，另以 3 字节分块 + 7 字节缓冲的 seekable / 不可 seek 源对同一合成 MP4 复算采样表，与整文件解析逐值一致 |
| Matroska Tracks | 合成轨道手推（空 Entry 的全表默认值——语言 eng/flag_default 1/采样率 8000/声道 1/Display 尺寸 -1；视频全字段（含 crop/AlphaMode/ColourSpace）；音频（48000 双声道 16 位、CodecDelay/SeekPreRoll/TimecodeScale）；header-strip 压缩的三层 ContentEncodings→ContentEncoding→ContentCompression 结构（Scope 默认 1）；双轨字段互不串扰）；**真实文件**：webm 双轨（V_VP8 128x96 无 Display 字段 → 默认 -1、Interlaced=2、DefaultDuration 1e8=10fps、A_OPUS 48000 单声道 + OpusHead CodecPrivate、CodecDelay 6.5e6/SeekPreRoll 8e7）与 mkv 单视频轨（V_MPEG4/ISO/AVC + avcC，首字节 1）逐值断言 |
| Matroska Segment/Info/SeekHead | 合成布局手推（已知/未知长度 Segment、空 Info 默认值、SeekHead 回跳——cluster-first 布局验证 execute_seekhead 真跳回解析未过的 Info、resync 跨 0x00 垃圾恢复）；**真实文件**：docker 生成的 webm/mkv 各取 1024 字节前缀（头 + 双 SeekHead×4 条目 + Info + Tracks + 首 Cluster），TimecodeScale/Duration（1008/1000 = ffprobe 的 1.01s/1.00s）/MuxingApp=Lavf63.1.102/segment_start/first_cluster_pos/8 条 SeekHead 的 id 与位置逐值断言 |
| EBML 层 + EBML 头 | VINT 取 EBML 规范（RFC 8796 §4）宽度示例（含全一宽度的未知长度映射与 2/3/8 字节最大值；两处易错点由测试反推确认：0x3F 是 3 字节前缀而非 2 字节全一，最大已知 1 字节长度是 0xFE）；`is_ebml_id_valid` 用 matroska.h 的真实 ID（Header/Segment/Info/Void/CRC32）+ 标志位错位反例；游走器各路径（VOID 跳过、未知长度 master 遇 Segment 终止 = CHILD_OF 语义、零长 master、live 模式、元素越界、空流/截断）合成字节手推；**真实文件**：docker `linuxserver/ffmpeg:9.0.2` 生成的 webm（libvpx+libopus）与 mkv（libx264+aac），头部 64 字节 base64 内嵌，doctype/版本/长度上限与 ffprobe 的 EBML 头输出一致，头后紧跟的 Segment（未知长度）触发 EBML_STOP |
| advanced_editlist | 全部由 mov_fix_index 的步进语义手推：中部 media_time 编辑（前导弃帧保留但时间戳经 duration 缓冲重写为 -20/-10，保留帧从 0 起，含关键帧回退）；空首 edit（时间轴 +500、`start_time=500`、`min_corrected_pts` 净 0）；音频部分帧（`skip_samples=512`、首帧行至 -512）；正 `min_corrected_pts`（视频 DTS 整体 -50 使首 PTS 归零，seek 落在修正后时间轴）；`mov_estimate_video_delay`（ctts +20/0/+10 → 1，非 avc1 不估）；碎片化 trak 按 mov_read_trak 顺序禁用（先建 trak 仍被 fix、后建 trak 直通、movie 旗标翻转）；**真实文件回归**：docker AAC 文件 14 个包仍与 ffprobe 逐值一致，并新增 `discard`（首帧 AVINDEX_DISCARD_FRAME）与 `skip_samples=1024`（编码器延迟）断言 |
| sgpd/sbgp/open-GOP/多 stsd | 期望值由 mov.c 语义手推：sgpd NAL 类型（6 位掩码）与 sbgp run 表（含零计数 run 保留）；HEVC 无 CRA entry 时 offsets 仍展开但 key 表/min 时长不建（`cra_index==0` 早退）；open-GOP seek 为**差分测试**——同一文件 `hvc1`（CRA 样本 pts `dts+offset+dts_shift` 超过请求点即拒、按 `FFMAX(min_sample_duration,1)` 回退到闭合关键帧）与 `avc1`（无门直达 CRA）各求一次；`dts_shift` 为 0 的成因（`mov_update_dts_shift` 只跑非最后两条 entry）一并断言；多 stsd 三态（同 fourcc → `pseudo_stream_id=-1` 全索引且仅 slot 0 有 extradata；异 fourcc → 跳过且 `stsc.id=2` 的 chunk 剔除；首 chunk 引用 entry 2 → `last_stsd` 切到空槽清空主 extradata）；碎片 `stsd_id` 门走 trex 默认与 tfhd 旗标两条路径（匹配 1 收样、2 全拒） |
| mpeg4audio | 位串按 ISO/IEC 14496-3 手推：AAC-LC 44100 单/多声道、显式 24 位采样率、escape 对象类型、头部隐式 SBR、`0x2b7` 同步扩展的 SBR/PS、AAC-LD 帧长；`12 08 56 e5 00` 五字节直接取自 docker 生成的 `aac.mp4`（与真实文件互证） |
| extradata/esds | 合成 ES→DCD→DSI 描述符链（AAC 0x40 带 `12 10` 配置、MPEG-1 0x6b 无 DSI 特例）手推期望；**真实文件**：docker `ffmpeg:9.0.2` 生成的 `aac.mp4`，codec-id/声道/采样率/帧长/码率/5 字节 extradata 与 ffprobe 及 python 直读 esds 的结果逐项一致，14 个 packet 的 pos/size/pts/dts/duration 逐值比对（首包 pts -1024 的 edit-list 偏移在内） |
| sidx/mfra/碎片化 | 合成 box 手推（参考偏移、`FFMIN` 无关的 track_end/duration、无 tfdt 时的 sidx 回退、重叠片段 discard、mfro 探测）；**真实文件**：`-movflags +frag_keyframe+dash` 生成的 `sidx.mp4`，两条 sidx 参考（offset 891/2315、size 1372/1272）与 tfra 表（(0,891)/(10240,2315)）和 python box 直读一致，10 个 packet 与 ffprobe 逐值比对 |
| saiz/saio/senc | 合成 box：流级 saiz+saio 指向 free box 内的辅助块、`moof` 内 senc 的逐样本 IV，手推期望 |
| seek | 合成 10 样本索引（关键帧 1/7）：BACKWARD 回退到关键帧、ANY 精确命中、越界钳制、碎片化索引跨片段 seek；真实 `sidx.mp4` 上 seek 12000→样本 5、5000→样本 0 |
| 未压缩音频分块 | 合成 QT `sowt` 文件（2500 样本两 chunk → 1024+476+1000 样本三包）手推；**真实文件**：docker 生成的 `pcm_short.mov`，7 个 packet（6×1024 样本 + 471）的 pos/size/dts/duration 与 ffprobe 逐值比对 |
| idct | 期望值来自 FFmpeg **自带的双精度参考 IDCT** `libavcodec/dctref.c`（`libavcodec/tests/dct.c` 亦以此为准）；随机系数由 FFmpeg 自己的 `av_lfg`（`libavutil/lfg.c`，seed 1）与 `init_block()` 生成，**复刻 FATE `fate-idct8x8-0/1/2` 的方法**；判据逐字取自 `dct.c`（`err_inf ≤ 1`、`omse ≤ 0.02`、`|ome| ≤ 0.0015`），SIMPLE-C 8/10 两档完全满足；**12 位**在 `dct.c` 中标记 `nonspec = 1`（其 omse/bias 判据本就不适用），实测 SIMD 与标量 profile 完全一致（如 mode 0 两者均为 `err_inf=1, omse=0.1351, bias=-0.00259`）。SIMD 版（`idct_v128.mbt`，8/10/12 位）另在全 64 个单系数块上与标量版**逐值一致**，转置额外做「转置两次 == 原块」校验 |
| huffman | `tests/ref/fate/` 无 `huffman.c` 的数值向量（`fate-libavcodec-huffman` 实测的是另一套 `mjpegenc_huffman.c`）。采用：① Kraft 等和 `Σ2^-len == 1`；② 与**独立教科书两队列 Huffman** 的加权路径长相等（最优性）；③ FFmpeg 自带两套独立实现 `ff_huff_build_tree` 与 `ff_huff_gen_len_table` 互证；④ 编→解往返；⑤ 手推教科书样例（频次 1,1,2,4 → 码长 {1,2,3,3}）；⑥ `sum >> 31` 的过高频次拒绝 |

补充交叉校验：分块更新与一次性计算等价（CRC / Adler-32 / MD5 / SHA）、增量 MD5、
Base64 截断输出行为与非法输入检测。

**真实文件交叉验证（已完成，两批）**：由 Docker 镜像 `linuxserver/ffmpeg:9.0.2` 生成真实
MP4/MOV，用其 `ffprobe` 的 `packet` 输出作为期望值，与本文档解析结果逐 packet 比对
（`pos`/`size`/`dts`/`pts`/`duration`/关键帧）。第一批覆盖普通、碎片化（`frag_keyframe`）
与 cenc 加密三种文件（cenc 以已知密钥解密后与明文样本逐字节一致）；第二批新增
AAC `esds`（extradata/声道/采样率/帧长/码率 + 首包 edit-list 偏移 -1024）、PCM `sowt`
（未压缩音频分块路径）与 `+dash` 碎片（`sidx`/`mfra` + 跨片段 seek）。文件以 base64
内嵌于 `libavformat/mp4_real_wbtest.mbt`（附生成命令便于复现）。第二批还暴露并修复了
一个保真 bug：QuickTime 在 `minf` 里放置的数据 `hdlr`（subtype `url `）不应覆盖
`mdia`/`hdlr` 已识别的媒体类型（C 只对 vide/soun/subp/clcp 赋值）。

复现命令：

```bash
cd moonbit
moon check     # 0 error / 0 warning
moon test      # 201/201 passed
```

---

## 5. 后续重构计划

### 阶段 0 —— 工程骨架 + libavutil 纯算法首批（已完成）
见第 3 节。

### 阶段 1 —— 补齐 libavutil 纯算法模块
优先级从高到低（1 已完成）：

1. ~~`avstring.c`~~ **已完成**（见第 3 节；varargs 三件套 `av_strlcatf`/`av_asprintf`/`av_bprintf`
   与依赖就地改写字符串的 `av_strtok` 未移植）
2. `intreadwrite.h` 语义的字节读写工具（BE/LE 定点读写，作为后续所有解析器的基础）
3. `aes.c`、`rc4.c`、`xtea.c`、`tea.c`、`blowfish.c`、`cast5.c`、`aes_ctr.c`
   **已完成**（见第 3 节）；其余分组密码 `des.c`、`twofish.c`、`sm4.c` 待做 —— 其
   `libavutil/tests/{des,twofish}.c` 自带向量可作权威参考，`sm4` 用标准向量。
4. `lzo.c`（解压）、`eval.c`（表达式求值）、`timecode.c`、`parseutils.c`
5. `pixdesc.c`、`samplefmt.c`（大量纯数据表 + 少量逻辑）
6. `dict.c`、`opt.c`（依赖内存分配，见阶段 2 的约束）

### 阶段 2 —— 内存与平台相关部分
`mem.c`、`av_malloc`/`av_free`、`pthread`/`thread` 抽象。这些依赖宿主内存模型，
需要先确定 MoonBit 侧的策略（MoonBit 原生内存 + FFI，还是保留 C 侧实现）。

### 阶段 3 —— libswresample / libswscale
重采样与缩放中的纯算法部分（有理数重采样比、滤波器系数计算）；
向量化内核（`libswscale/x86` 13 个、`libswresample/x86` 3 个）按新边界原则用 `@v128` 重写。

### 阶段 4 —— libavformat（**MP4/MOV 切片 + 流式 AVIO 层基本完备**）
已完成 MP4/MOV 容器解析、采样表索引、**碎片化 MP4**（含 `sidx`/`mfra` 与重叠片段
`discard`）、**extradata**（`avcC`/`hvcC`/`av1C` 原样 + `esds`/AAC 配置）、**seek**
（`mov_seek_stream`）、**未压缩音频分块路径**与 **cenc 全家**（流级 + 碎片内 `senc`、
`saiz`/`saio`；见第 3 节范围边界与第 4 节验证方式），以及 **`aviobuf.c` 的流式 AVIO
层**（读+写+dyn buf+校验和，回调驱动）——MP4 解复用已改跑在 `AvioContext` 上
（`av_mov_open_avio`），"整文件入内存"仅剩 `init_read_context` 便捷封装——以及
**sample group 与多 sample description**：`sgpd`/`sbgp` 解析、
`build_open_gop_key_points` → `can_seek_to_key_sample` 的 HEVC 开放 GOP seek、
`ff_mov_read_stsd_entries` 多 entry 走查 + `pseudo_stream_id` 索引过滤 +
tfdt/trun `stsd_id` 门，以及 **`advanced_editlist`**（`mov_fix_index` 全量：
edit 时间轴索引重建/discard 时间戳重写/`skip_samples`/`min_corrected_pts` 归零/
`start_time`/tts 重建/`mov_estimate_video_delay`/碎片化自动禁用）。MP4/MOV 解复用
至此覆盖 mov.c 的全部索引与时间戳路径。余下：

1. 其他容器：**Matroska/WebM 已开始**（EBML 层 + EBML 头 + Segment/Info/SeekHead/resync +
   Tracks 切片完成；余下 Cluster/Block lace 逐片推进）；AVI、MPEG-TS（字节级解析优先）
2. `avio.c` 的 URL/协议层与 `avio_open`（文件/网络 IO，属平台边界，或留 FFI）

### 阶段 5 —— libavcodec（**已开始**：IDCT + Huffman）
只做纯 C 的编解码器（Huffman/VLC 表、LZO、部分无损编解码）；其向量化内核
（`libavcodec/x86`，共 113 个 `*.asm`）按新边界原则用 `@v128` 重写，而非保留 C/FFI。

已完成 SIMPLE-C IDCT（`int16` 8/10/12 bit）与 `huffman.c` 的树/码长构建（见第 3 节）。后续：

1. `vlc.c` 的 `ff_vlc_init_from_lengths` 表构建（当前只产出它需要的 `lens`/`xlat`）
2. `jrevdct.c`（`FF_IDCT_INT`）、`faanidct.c`、`xvididct.c` 与 `idct248/84/48/44` 部分变换
3. `lzo.c`、`golomb`/`cabac` 等熵编解码基础，再到具体编解码器（无损优先）

### 阶段 6 —— 公共 API 层与 fftools
为已移植部分提供稳定的 MoonBit 公共 API，并提供 `extern "C"` 绑定层，
让未移植的 C 代码与 MoonBit 代码互通。

---

## 6. 移植约定（C → MoonBit）

为保证可对照、可 review，逐行移植时统一遵循以下约定：

| C 惯用法 | MoonBit 约定 |
|---|---|
| 输出参数 `int *dst_num, *dst_den` | 改为返回值，例如 `av_reduce` 返回 `(num, den, exact)` 元组 |
| 返回 `<0` 表示错误（`AVERROR(EINVAL)`） | 返回 `Result[T, String]`，错误信息为 `"EINVAL"` |
| C 字符串 `const char *` + 长度 | 输入用 `Bytes`；文本输出返回 `String` |
| 可变输出缓冲区 | `FixedArray[Byte]` / `FixedArray[UInt]` |
| `goto`（base64 解码状态机） | 结构化改写为显式状态标志 |
| 函数指针（`ctx->transform`） | 布尔选择器（`is_sha1`） |
| `~x`、`>>>`（本工具链不可用） | `x.lnot()`；逻辑右移改用 `UInt`/`UInt64` |
| `CONFIG_SMALL` 分支 | 统一实现 small 分支（等价结果，可读性优先） |
| `av_mallocz` 零初始化上下文 | 构造器 `*_alloc()` 显式置零 |
| 大常量表（Blowfish `orig_s`、CAST5 `S1..S8`） | 从对应 C 源文件批量提取十六进制常量后生成表字面量，避免手工转录出错；再用模块自带的权威向量校验 |
| FFmpeg x86 SIMD 内核（NASM `*.asm`） | 用 `@v128`（`moonbitlang/core/v128`）重写，`#cfg(any(target="native", target="wasm"))` 门控 + 标量回退；不可表达的 x86 专有指令（AES-NI / SHA-NI / PCLMULQDQ）才留 C/FFI |
| SIMD 实现的可验证性 | SIMD 路径必须与标量路径、以及既有权威向量**逐值一致**（同一测试同时跑两条路径，或断言 SIMD == 标量） |

**注意**：MoonBit 的 `String` 是 UTF-16。`Bytes::to_string()` 返回的是 `b"..."`
字面量形式、`to_unchecked_string()` 按 UTF-16 解释字节 —— 二者都不能把 ASCII 字节
转成正确字符串，需要按码位构造 `String`（见 `base64.mbt` 的 `ascii_to_string`）。

---

## 7. 踩坑记录

1. **`av_rescale_rnd` 无限递归（已修复）**：负数分支 `-FFMAX(a, -INT64_MAX)` 有两层取反，
   初次移植漏掉内层取反，导致 `rnd` 在 2↔3 之间振荡、无限递归、测试进程栈溢出
   （退出码 `0xc00000fd`）。测试立即暴露。
2. **`Bytes` ↔ `String` 转换语义**：见第 6 节末尾，曾导致 base64 测试"两边一起错"的假通过。
3. **工具链语法差异**：`~`（按位取反）与 `>>>`（逻辑右移）在此工具链不存在；
   `in` 是保留字；`for i = 0; ...` 与 `for i in 0..<n` 均可用。
4. **方法定义需带类型前缀**：`fn position(self : Mp4Reader)` 已弃用，须写成
   `fn Mp4Reader::position(self : Mp4Reader)`。
5. **转换函数命名**：`UInt::to_int` / `Int::to_uint` 等按位转换已更名为 `reinterpret_as_int` /
   `reinterpret_as_uint`；真实的加宽转换（`to_int64`/`to_uint64`）仍可用。注意
   `Int`（32 位）没有 `reinterpret_as_uint64`，需要先 `to_int64()`。
6. **`to_uint()`/`to_int()` 的返回值**：丢弃非 `Unit` 返回值必须显式写出（`let _ = ...`），
   否则报 `4139`；结构体字段上多余的 `mut` 会当作错误（`unused_mut`）。
7. **枚举比较需要 `Eq`**：`derive(Eq, Show)` 会触发 `implicit_impl_as_method` 与
   `deprecated_syntax` 告警；本切片改为 `match` 辅助函数（`media_is_video`/`media_is_audio`）
   避免派生的连锁告警。
8. **绝对寻址 peek 不能模拟顺序位读（流式 AVIO 教训）**：`stz2`/变长 `stsz` 的
   `get_bits_long` 初版用「save 游标 → 绝对 seek → 读 1 字节 → 回退」的 peek 实现，
   在不可 seek 的流式源上内部 seek 失败被忽略，游标漂移导致后续 box 全部错位（整文件
   与 seekable 源都测不出来）。正确做法与 C 一致：把位域字节**顺序读入**再解包。
9. **`mov.c` 9.0 的 `tts` 合并**：`mov_build_index` 已不再直接消费 `stts_data`/`ctts_data`，
   而是先经 `mov_merge_tts_data` 展开为每样本一条的 `MovTts`；PTS 由
   `mov_finalize_packet` 的 `dts + dts_shift + tts.offset` 得到（`mov.c:11686`）。
   按旧版（直接读 stts/ctts）移植会与 9.0 行为不一致。
9. **大写标识符不能作参数名**：MoonBit 的值标识符须以小写或 `_` 开头；`cast5.mbt` 的
   密钥调度参数 `K` 触发 `E4074/E3002`，改名 `k` 即可。
10. **批量提取常量表时的两个陷阱**：把 C 源码里的 `0x…` 常量转大写时，`0x` 前缀会
   一并变成 `0X`（MoonBit 不识别，须只大写十六进制数位）；此外不要对提取结果做
   「行重排」式的二次处理 —— 曾因此把 8 张 S-box 表错位，靠「与 C 源码逐值 diff == 0」
   才定位。生成后务必用模块自带向量 + 与 C 源的逐值比对双重校验。
11. **ISO VisualSampleEntry 末尾的 `pre_defined = -1`（2 字节）**：`parse_stsd_video`
   起初漏读这 2 字节，使其后子 box（`esds`/`sinf`）整体错位；普通非加密文件因
   「跳过 entry 其余部分」而无感，但 cenc 的 `sinf` 永远读不到（`cenc_scheme` 为 0）。
   该问题由**真实文件交叉验证**（docker `ffmpeg:9.0.2` + `ffprobe`）暴露并修复。
12. **`test` 是 MoonBit 保留字**：与其同名的参数/变量（如 `dct.c` 的 `init_block(..., int test, ...)`）
   会触发大面积 `E3002` 解析错误并连带出无关告警；移植时改名为 `mode` 即可。
13. **白盒测试专用依赖**：`moon.pkg` 里 `import { "…/libavutil", } for "wbtest"` 只对
   `*_wbtest.mbt` 生效，避免非测试文件不使用依赖而触发 `unused_package` 告警。
14. **行数统计口径**：`Get-Content $f | Measure-Object -Line` 会比 `(Get-Content $f).Count`
   少计（末行无换行符时不计入）。本 README 统一用后者。
15. **合成 MP4 的 SampleEntry 头是 8 字节**（6 保留 + 2 字节 `data_reference_index`），
   视频入口后还有 16 字节 pre_defined、`compressorname` 是 1 长度字节 + 31 字节；音频入口
   后是 QT 的 version/revision/vendor 8 字节。第一版合成器各少写/漏写导致 entry 内整体
   错位、extradata 与声道全错 —— 对照 `mp4_wbtest.mbt` 的既有构造器修正。
16. **`minf` 里的数据 `hdlr`（subtype `url `）**：QuickTime/ffmpeg 的 PCM MOV 会在 `minf`
   下放一个 `hdlr`（数据引用），C 的 `mov_read_hdlr` 只对 vide/soun/subp/clcp 赋值、
   其余类型不覆盖已识别的媒体类型；第一版把它也当媒体 hdlr 处理，把 `soun` 覆盖成
   Unknown，`stsd` 采样入口不再解析（声道为 0）。真实文件交叉验证暴露。
17. **`mov_read_sidx` 的锚点在函数入口取**：`offset = avio_tell(pb) + atom.size` 是进入
   函数时的 position；若在读完 28 字节头部字段后再取 position，参考偏移会整体后移
   28 字节，`trun` 的 sidx 回退随之失配（表现为 DTS 落到 `track_end`）。
18. **`mfra` 必须带 `mfro` 尾**：demuxer 从文件最后 4 字节读 mfra 大小 —— 那是 `mfro`
   box 的最后一个字段；合成不带 `mfro` 的 `mfra` 永远探测不到。

---

## 8. 许可证

本目录是对 FFmpeg 的衍生移植，遵循 FFmpeg 的 **LGPL-2.1-or-later**（`moon.mod` 中已声明）。
各源文件头部保留了原始 C 文件的版权与作者信息（如 Michael Niedermayer、Ryan Martell 等）。
