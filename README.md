# FFmpeg → MoonBit 重构计划与进度

用 MoonBit 重写 FFmpeg 9.0.2。仓库是完整的 FFmpeg 源码（4652 个 C/H 文件、约 66 MB 源码、
约 160 万行 C 代码，实测 1,595,275 行），本文档记录这项工作的**范围界定、重构计划、当前进度与移植约定**。

MoonBit 模块位于本目录（`moonbit/`），与 FFmpeg 的 C 源码并存，互不修改。

---

## 1. 范围与策略

一次重写整个 FFmpeg 不现实：

- libavcodec 单个库就有 38 MB 源码（占总量的 57%）；
- 大量代码依赖 x86/ARM 内联汇编、SIMD intrinsics、指针运算、宏元编程与平台特定实现；
- 这些部分**不适合也无法直接"翻译"**成 MoonBit。

因此采用**垂直切片（vertical slice）**策略：从自包含、可独立验证的纯算法模块入手，
每个模块都对照 C 源码逐行移植，并用 FFmpeg **自己的测试与 FATE 参考输出**做向量校验。
编译目标为 `wasm`/`wasm-gc`（纯算法无需 C 工具链，`moon test` 可直接验证）。

**边界原则**：纯算法 → MoonBit 重写；SIMD/汇编/线程/平台代码 → 保留 C 实现，后续通过
MoonBit 的 `extern "C"` FFI 复用，而不是硬翻译。

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
└── libavformat/              # 包：ffmpeg/moonbit/libavformat（依赖 libavutil）
    ├── moon.pkg              # 声明对 ffmpeg/moonbit/libavutil 的依赖
    ├── reader.mbt            # 内存字节读取器（对应 avio_rb/rl/skip/tell/feof）
    ├── mov.mbt               # MP4/MOV 解复用器：box 遍历 + 采样表 → 每样本索引
    └── mp4_wbtest.mbt        # 合成 MP4 构造器与白盒测试
```

## 3. 当前进度

**总体**：全量 FFmpeg 约 160 万行，本次完成 MoonBit 源文件（`moonbit/**/*.mbt`，不含
`_build` 生成文件）共 **7357 行**（libavutil 5267 行 + libavformat 的 MP4 解复用切片
2090 行，两者均含白盒测试）—— 约占整体 **0.46%**。

### 已完成模块（阶段 0 + 阶段 1 开端）

| 模块 | 对应 C 源码 | 移植内容 | 测试 |
|---|---|---|---|
| [mathematics.mbt](libavutil/mathematics.mbt) | `libavutil/mathematics.c`、`intmath.h` | `av_gcd`(Stein 二进制 GCD)、`av_rescale_rnd`(128 位拆分乘法 + 位长除法)、`av_rescale`/`av_rescale_q`/`av_rescale_q_rnd`、`av_log2`、`ff_ctzll`、`av_compare_ts`、`av_compare_mod` | ✅ |
| [rational.mbt](libavutil/rational.mbt) | `libavutil/rational.c` | `AVRational`、`av_make_q`、`av_cmp_q`、`av_q2d`、`av_inv_q`、`av_reduce`、`av_mul_q`/`av_div_q`/`av_add_q`/`av_sub_q`、`av_d2q`(自实现 `frexp`)、`av_gcd_q`、`av_q2intfloat` | ✅ |
| [crc.mbt](libavutil/crc.mbt) | `libavutil/crc.c` | `AVCRCId`、`av_crc_init`(任意多项式表生成)、`av_crc_get_table`、`av_crc`、`av_crc_ids` | ✅ |
| [adler32.mbt](libavutil/adler32.mbt) | `libavutil/adler32.c` | `av_adler32_update` | ✅ |
| [base64.mbt](libavutil/base64.mbt) | `libavutil/base64.c` | `av_base64_encode`、`av_base64_decode`、`av_base64_decode_syntax`、`av_base64_size` | ✅ |
| [md5.mbt](libavutil/md5.mbt) | `libavutil/md5.c` | `AVMD5`、`av_md5_init/update/final/sum` | ✅ |
| [sha.mbt](libavutil/sha.mbt) | `libavutil/sha.c` | `AVSHA`、`av_sha_init/update/final/sum`（SHA-1/224/256） | ✅ |
| [avstring.mbt](libavutil/avstring.mbt) | `libavutil/avstring.c`、`bprint.c`(`av_bprint_escape`) | `av_strstart`/`av_stristart`/`av_stristr`/`av_strnstr`、`av_strlcpy`/`av_strlcat`、`av_strcasecmp`/`av_strncasecmp`、`av_get_token`、`av_strireplace`、`av_basename`/`av_dirname`/`av_append_path_component`、`av_match_name`/`av_match_list`、`av_escape`(QUOTE/XML/BACKSLASH 三模式 + flag)、`av_utf8_decode` | ✅ |
| [rc4.mbt](libavutil/rc4.mbt) | `libavutil/rc4.c` | `AVRC4`、`av_rc4_alloc`、`av_rc4_init`(KSA，key_bits 非 8 倍数报错)、`av_rc4_crypt`(密钥流/加解密) | ✅ |
| [aes.mbt](libavutil/aes.mbt) | `libavutil/aes.c` | `AVAES`、`av_aes_init`(128/192/256 密钥扩展 + S-box 表生成)、`av_aes_crypt`(ECB / CBC，含 iv 链式更新)。**轮函数按 FIPS-197 规范实现**，见下方说明 | ✅ |
| [xtea.mbt](libavutil/xtea.mbt) | `libavutil/xtea.c` | `AVXTEA`、`av_xtea_alloc`、`av_xtea_init`(大端密钥装载)、`av_xtea_le_init`(小端)、`av_xtea_crypt`/`av_xtea_le_crypt`(ECB / CBC，含 iv 链式更新)。32 轮用 `CONFIG_SMALL` 循环形式（与 C 展开版等价） | ✅ |
| [tea.mbt](libavutil/tea.mbt) | `libavutil/tea.c` | `AVTEA`、`av_tea_alloc`、`av_tea_init`(大端密钥 + `rounds` 参数，标准 64)、`av_tea_crypt`(ECB / CBC，含 iv 链式更新)。Feistel 网络 `rounds/2` 个双轮，delta `0x9E3779B9` | ✅ |
| [blowfish.mbt](libavutil/blowfish.mbt) | `libavutil/blowfish.c` | `AVBlowfish`、`av_blowfish_alloc`、`av_blowfish_init`(P-array 密钥异或 + 用 (0,0) 反复加密重导出 P/S)、`av_blowfish_crypt_ecb`(16 轮 Feistel，返回两半)、`av_blowfish_crypt`(ECB / CBC，含 iv 链式更新)。`orig_p`/`orig_s` 表逐值移植 | ✅ |
| [cast5.mbt](libavutil/cast5.mbt) | `libavutil/cast5.c` | `AVCAST5`、`av_cast5_alloc`、`av_cast5_init`(40/80/128 位密钥 → `Km`/`Kr` 轮密钥，`Kr` 掩到 5 位)、`av_cast5_crypt`(ECB)、`av_cast5_crypt2`(CBC)。`F1/F2/F3` 轮函数与 `COMPUTE_Z/COMPUTE_X` 密钥调度；`S1`..`S8` 表由 C 源码逐值提取 | ✅ |
| [aes_ctr.mbt](libavutil/aes_ctr.mbt) | `libavutil/aes_ctr.c` | `AVAESCTR`、`av_aes_ctr_alloc/init`、`av_aes_ctr_set_iv`(8 字节 IV+零计数器)、`av_aes_ctr_set_full_iv`/`get_iv`(16 字节)、`av_aes_ctr_increment_iv`(BE64 高位加一)、`av_aes_ctr_crypt`(keystream 缓存 + `block_offset` 跨调用状态，支持任意切分)。`set_random_iv` 依赖平台随机源，留待 FFI | ✅ |
| [reader.mbt](libavformat/reader.mbt) | `avio_*` 子集 | `Mp4Reader`：`avio_r8/rb16/rb24/rb32/rb64/rl32`、`skip`/`seek`/`tell`/`feof` 语义（越界读返回 0 并置 eof，与 AVIO 一致） | ✅ |
| [mov.mbt](libavformat/mov.mbt) | `libavformat/mov.c` | box 遍历 + `ftyp`/`mvhd`/`tkhd`/`mdhd`/`hdlr`/`elst`/`stsd`(视频/音频 sample entry)/`stts`/`ctts`/`stsc`/`stsz`/`stz2`/`stco`/`co64`/`stss`/`stps` 解析；`mov_merge_tts_data` 合并 + `mov_build_index` 采样索引 → 每样本 offset/size/DTS/PTS/duration/关键帧/`min_distance` | ✅ |

**当前状态**：`moon check` 0 error / 0 warning，`moon test` **71/71 通过**（libavutil 59 + MP4 12）。

### AES 的唯一实现偏差（已记录）

`aes.mbt` 是本项目**唯一一处按规范而非按 C 源码逐行实现**的地方：

- **逐行移植**的部分：S-box / 逆 S-box 的生成（`aes_init_static` 的 log8/alog8 + 仿射变换）、
  `rcon` 表、密钥扩展的 Rcon/SubWord 结构（含 AES-256 的 `KC == 8 && j == KC >> 1` 特例）。
- **按 FIPS-197 规范实现**的部分：轮函数（SubBytes / ShiftRows / MixColumns / AddRoundKey
  及其逆）。FFmpeg 的 `subshift` / `mix` / `multbl` 表驱动内核是同一算法的等价优化，
  其字节布局依赖小端 `u32`/`u64` 类型双关与 `sizeof(av_aes_block)` 指针运算；复刻风险高、
  零行为收益，而 FIPS-197 形式可用官方标准向量直接验证。
- **后果**：轮密钥按 FIPS-197 顺序存放，而非 FFmpeg 内部对解密预变换的形式；
  `av_aes_init` / `av_aes_crypt` 的签名与 ECB/CBC 行为保持一致。

### MP4 demuxer 切片的范围边界

- **已做**：从内存 `Bytes` 解析整文件（调用方读文件），因此无需 AVIO/AVPacket/AVFormatContext；
  采样表全部展开为每样本索引，DTS/CTS 与 FFmpeg 的 `pkt->dts`/`pkt->pts`/`pkt->duration` 计算一致
  （含 `max_stts_delta` 裁剪、DTS 漂移修正、负 `ctts` 触发的 `dts_shift`、edit list 的
  `time_offset`、`stsc` 校验修复、`stz2` 的 MSB-first 4/8/16/32 位打包、64 位 box 长度与 `co64`）。
- **未做**：fragmented MP4（`moof`/`trun`）、加密 `cenc`、seek、多 sample description 轨道、
  音频特例（`stts` 单条目 duration==1 的旧式未压缩音频分块路径，遇到时置
  `unsupported_audio_chunk_demux` 标志并产出空样本表）、`rap_group`(sgpd/sbgp)、
  codec 私有 extradata（`avcC`/`esds`/`wave`）、`advanced_editlist`、muxer。

### 未完成（本次切片外）

- `mathematics.c` 中：`av_rescale_delta`、`av_add_stable`、`av_bessel_i0`
- `libavutil/sha512.c`（SHA-384/512）
- libavutil 其余部分：`dict`、`opt`、`pixdesc`、`samplefmt`、`intreadwrite`、
  `des/twofish/sm4`、`lzo`、`eval`、`timecode`、`parseutils` 等
- libavformat 其余部分：`aviobuf.c`/`avio.c`（流式与文件 AVIO）、其余 demuxer/muxer、
  aac/AC-3 等音频解析、字幕（`tx3g`/TTML）、AVIF/HEIF 图像
- libswscale / libswresample / libavcodec / libavdevice / fftools：**未开始**

---

## 4. 验证方式

所有期望值都取自 FFmpeg 仓库内的**一手资料**，不使用自造数据：

| 被测模块 | 向量来源 |
|---|---|
| crc | `tests/ref/fate/crc`（7 组原始输出）+ `libavutil/crc.c` 内硬编码表前缀（直接验证表生成器） |
| adler32 | `libavutil/tests/adler32.c` 内断言 `0x50E6E508` + Adler-32 规范示例 |
| base64 | `libavutil/tests/base64.c` 的参考编码表 |
| md5 | `tests/ref/fate/md5`（5 组摘要：1000 / 63 / 64 / 65 / 999 字节） |
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
| MP4 demuxer | 测试内**逐字节合成**的 MP4/MOV（`ftyp`+`moov`+`trak`+`stbl`+`mdat`），期望值由 box 布局与 `mov.c` 语义手算：chunk→样本 offset 累积、`stts` DTS 序列、`ctts` 重排后的 PTS、负 `ctts` 的 `dts_shift`、`stss` 关键帧、`stz2` 位打包、`co64` 与 64 位 box、`elst` 的 `time_offset`、`stsc` 校验修复 |

补充交叉校验：分块更新与一次性计算等价（CRC / Adler-32 / MD5 / SHA）、增量 MD5、
Base64 截断输出行为与非法输入检测。

**待补**：MP4 的合成用例覆盖的是 box 语义与算法分支，尚未覆盖真实编码器产出的文件。
若提供一个真实 MP4/MOV 路径，可用于端到端核对（例如比对 `ffprobe` 的
`nb_frames`/`time_base`/`start_time` 与本文档解析出的样本数/时基/DTS 起点）。

复现命令：

```bash
cd moonbit
moon check     # 0 error / 0 warning
moon test      # 71/71 passed
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
SIMD 内核保留在 C 侧。

### 阶段 4 —— libavformat（**已开始**：MP4/MOV 解复用切片）
已完成 MP4/MOV 容器解析与采样表索引（见第 3 节的范围边界与第 4 节的验证方式）。
后续在该包内继续：

1. 碎片化 MP4（`moof`/`trun`/`tfhd`/`sidx`），复用已有的 `MovTts` 合并机制
2. `aviobuf.c`/`avio.c` 的流式读取（文件/网络），替代当前"整文件入内存"的做法
3. codec 私有 extradata（`avcC`/`hvcC`/`esds`）与 `mov_read_stsd_entries` 的多描述支持
4. `cenc` 加密、seek（`mov_seek_stream`）、`rap_group`
5. 其他容器：Matroska/WebM、AVI、MPEG-TS（字节级解析优先）

### 阶段 5 —— libavcodec
只做纯 C 的编解码器（Huffman/VLC 表、LZO、部分无损编解码），
SIMD 与汇编保持 C 实现并通过 FFI 调用。

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
8. **`mov.c` 9.0 的 `tts` 合并**：`mov_build_index` 已不再直接消费 `stts_data`/`ctts_data`，
   而是先经 `mov_merge_tts_data` 展开为每样本一条的 `MovTts`；PTS 由
   `mov_finalize_packet` 的 `dts + dts_shift + tts.offset` 得到（`mov.c:11686`）。
   按旧版（直接读 stts/ctts）移植会与 9.0 行为不一致。
9. **大写标识符不能作参数名**：MoonBit 的值标识符须以小写或 `_` 开头；`cast5.mbt` 的
   密钥调度参数 `K` 触发 `E4074/E3002`，改名 `k` 即可。
10. **批量提取常量表时的两个陷阱**：把 C 源码里的 `0x…` 常量转大写时，`0x` 前缀会
   一并变成 `0X`（MoonBit 不识别，须只大写十六进制数位）；此外不要对提取结果做
   「行重排」式的二次处理 —— 曾因此把 8 张 S-box 表错位，靠「与 C 源码逐值 diff == 0」
   才定位。生成后务必用模块自带向量 + 与 C 源的逐值比对双重校验。

---

## 8. 许可证

本目录是对 FFmpeg 的衍生移植，遵循 FFmpeg 的 **LGPL-2.1-or-later**（`moon.mod` 中已声明）。
各源文件头部保留了原始 C 文件的版权与作者信息（如 Michael Niedermayer、Ryan Martell 等）。
