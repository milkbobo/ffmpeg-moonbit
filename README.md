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
├── COPYING.LGPLv2.1          # GNU LGPL 2.1 正文（与 FFmpeg 根同名文件逐字节一致）
├── COPYING.LGPLv3            # GNU LGPL 3.0 正文（同上）
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
│   ├── matroska_block.mbt    # Matroska 切片 4：Cluster/Block 与三种 lacing
│   ├── ebml_wbtest.mbt       # EBML 白盒测试（VINT 规范向量/游走器/合成与损坏头部）
│   ├── ebml_real_wbtest.mbt  # 真实 webm/mkv 头交叉验证（docker ffmpeg，base64 内嵌）
│   ├── mkv_segment_wbtest.mbt # Segment 切片测试（合成布局 + 真实 1024 字节前缀）
│   ├── mkv_track_wbtest.mbt  # Tracks 切片测试（合成轨道 + 真实 webm/mkv 轨道）
│   ├── mkv_cluster_wbtest.mbt # Cluster 切片测试（lacing 三模式 + 真实 packet 表）
│   ├── mkv_cluster_realdata_wbtest.mbt # Cluster 真实文件 base64 素材
│   ├── rawaudio.mbt        # 裸 ADTS AAC / MPEG 音频分帧（ID3v2/v1、Xing/Info/VBRI）
│   ├── rawaudio_wbtest.mbt # 真实 AAC/MP3 逐帧比对 ffprobe + ID3 前缀/截断用例
│   ├── codec_tags.mbt      # Matroska CodecID / MP4 fourcc → 编解码器名
│   ├── codec_parameters.mbt# 容器 → CodecParameters（avcC/hvcC/ASC 解析桥）
│   ├── aac_asc_wbtest.mbt  # MP4 → ASC/PCE 初始化 → 原始 AAC 包 → PCM 全链路差分
│   ├── aac_asc_realdata_wbtest.mbt # 真实 stereo/PCE 5.1/7.1 MP4、ASC、ffprobe 包索引与 PCM
│   └── codec_parameters_wbtest.mbt # avcC/hvcC/ASC + 真实 MP4 AAC / MKV H.264 用例
└── libavcodec/               # 包：ffmpeg/moonbit/libavcodec（依赖 libavutil，仅白盒测试用）
    ├── moon.pkg              # moonbitlang/core/math + libavutil（`for "wbtest"`）
    ├── bitstream.mbt         # MSB-first 位读取 + Exp-Golomb（get_bits.h/golomb.h）
    ├── h2645_parse.mbt       # H.264/HEVC NAL 拆分：去防竞争字节、Annex B/长度前缀
    ├── h2645_vui.mbt         # H.264/HEVC 公共 VUI（SAR/色彩/chroma location）
    ├── h264_ps.mbt           # H.264 SPS/PPS/VUI/缩放矩阵 + avcC extradata
    ├── h264_slice.mbt        # H.264 I/P slice header（B/SP/SI 显式拒绝）
    ├── h264_cavlc.mbt        # CAVLC 残差解码 + 去量化/chroma QP 派生表
    ├── h264_idct.mbt         # H.264 4x4 IDCT + luma/chroma DC Hadamard（8-bit）
    ├── h264_pred.mbt         # 帧内预测 4x4/16x16/chroma 8x8 + 可用性改判
    ├── h264_decode.mbt       # Baseline I 帧重建（CAVLC→dequant→IDCT→预测→写回）+ Annex B 入口
    ├── h264_deblock.mbt      # 环路去块滤波（h264dsp 核 + h264_loopfilter 边界强度推导）
    ├── h264_sei.mbt          # H.264 SEI：消息框架 + BP/PT/恢复点/green + 公共消息集
    ├── h264_mc.mbt           # 运动补偿：luma 6 抽头 qpel + chroma 1/8 双线性 + 边界复制
    ├── h264_mvpred.mbt       # MV 预测：A/B/C 邻块、mid_pred、P_SKIP 捷径
    ├── h264_inter.mbt        # P 宏块层（CABAC+CAVLC）：skip/type/ref/mvd + inter 残差
    ├── h264_dpb.mbt          # 滑窗 DPB：POC 跟踪、默认 L0、参考标记（H264Decoder）
    ├── aac_ics.mbt           # AAC ICS 语法：ics_info/section 数据/TNS/pulse/gain-control
    ├── aac_mdct.mbt          # AAC IMDCT/加窗 + SCE/CPE/LFE 多元素帧入口与标签状态绑定
    ├── aac_coupling.mbt      # CCE 增益、频域/时域耦合及声道选择
    ├── aac_stereo.mbt        # CPE 共享/独立窗口、M/S 与强度立体声、双声道频谱编排
    ├── aac_layout.mbt        # 默认配置 1..7/11..14、三层 PCE 与 FFmpeg 声道排序、DSE 跳过
    ├── aac_config.mbt        # AAC-LC GASpecificConfig/ASC PCE 与直接解码器初始化
    ├── aac_spectrum.mbt      # AAC 频谱解码（码书 1..11/scalefactor/pulse/PNS/TNS）
    ├── aac_tables.mbt        # AAC 解码表（脚本批量提取，与 C 源逐值 diff）
    ├── hevc_ps.mbt           # HEVC VPS/SPS/PPS/PTL/RPS/VUI + hvcC extradata
    ├── hevc_slice.mbt        # HEVC slice segment header（I/P/B、RPS、权重表、对齐）
    ├── hevc_sei.mbt          # HEVC SEI（前缀/后缀、CLL/mastering display 等）
    ├── hevc_access_unit.mbt  # HEVC 访问单元组装与 POC 跟踪
    ├── hevc_cabac.mbt        # HEVC CABAC 引擎（3×199 init_values 与状态迁移）
    ├── hevc_cabac_syntax.mbt # HEVC CABAC 语法元素（split/cbf/merge/mvd/系数）
    ├── hevc_intra.mbt        # HEVC 帧内预测（planar/DC/33 角度，4..32）
    ├── hevc_scan.mbt         # HEVC 系数扫描（对角/水平/垂直，3 组尺寸）
    ├── hevc_transform.mbt    # HEVC IDCT/DST/反量化/residual 叠加
    ├── hevc_intra_ref.mbt    # HEVC 参考样本可用性/边界填充/邻域表
    ├── hevc_picture.mbt      # HEVC 图像缓冲（色度格式感知的 y/cb/cr 平面与 clone）
    ├── hevc_residual.mbt     # HEVC 残差解码（含 transform skip 与 scaling list；RDPCM 拒绝）
    ├── hevc_deblock.mbt      # HEVC 去块滤波（weak/strong、亮度+色度、bS 驱动）
    ├── hevc_sao.mbt          # HEVC SAO（merge/band/edge、CTB 边界恢复）
    ├── hevc_intra_decode.mbt # HEVC I 片整帧解码器（CTU/CU/PU/TU 编排）
    ├── hevc_refs.mbt         # HEVC 参考帧管理（MvField、DPB 槽位、RPS/L0/L1）
    ├── hevc_mc.mbt           # HEVC 运动补偿（luma qpel/chroma epel、uni/bi/加权）
    ├── hevc_inter.mbt        # HEVC inter 语法（merge/AMVP/mvd/ref_idx）
    ├── hevc_inter_decode.mbt # HEVC P/B 帧级驱动（DPB+RPL+MC 编排+bS）
    ├── audio_headers.mbt     # AAC ADTS 头 + MPEG 音频帧头（MP1/MP2/MP3）
    ├── mp3_tables.mbt        # Layer III 码表/Huffman 表（C 源批量提取）
    ├── mp3_dsp.mbt           # 定点 IMDCT/DCT32/合成窗（mpegaudiodsp fixed 路径）
    ├── mp3_decode.mbt        # Layer III 定点解码器 + 三层共用的合成滤波（PCM 输出）
    ├── mpa_layer12.mbt       # Layer I/II 定点解码器（bit allocation/scalefactor/组量化）
    ├── mpa_layer12_tables.mbt# Layer I/II 分配表/量化表/定点缩放表
    ├── idct.mbt              # SIMPLE-C IDCT（int16 8/10/12 bit）+ idctdsp 像素/扫描表辅助
    ├── dctref.mbt            # 双精度参考 DCT/IDCT（dctref.c），供 IDCT 测试作期望值
    ├── huffman.mbt           # Huffman 树/码长构建（huffman.c）+ 规范化码编解码
    ├── mpeg4audio.mbt        # AudioSpecificConfig 解析（mpeg4audio.c，esds/AAC 用）
    ├── h264_slice_wbtest.mbt # slice header 逐字段对照 trace_headers
    ├── h264_slice_realdata_wbtest.mbt # slice header 真实码流 base64 素材
    ├── h264_decode_wbtest.mbt# H.264 真实码流逐帧 YUV MD5 + 未支持输入负例
    ├── h264_decode_realdata_wbtest.mbt # H.264 码流 base64 素材与期望 MD5
    ├── mp3_decode_wbtest.mbt # MP3 定点解码 PCM MD5（mono/stereo/LSF）
    ├── mpa_layer12_wbtest.mbt# MP2 四种分配表 + 手工 Layer I 帧的 PCM MD5
    ├── mpa_layer12_realdata_wbtest.mbt # MP2/MP1 码流 base64 素材
    ├── mp3_decode_realdata_wbtest.mbt # MP3 码流 base64 素材与期望 MD5
    ├── bitstream_wbtest.mbt  # H.264/H.265 表 9-1 Exp-Golomb + 位读取边界
    ├── h2645_parse_wbtest.mbt# RBSP/NAL 拆分合成与真实参数集用例
    ├── h264_ps_wbtest.mbt    # 真实 avcC + trace_headers 字段逐项断言
    ├── hevc_ps_wbtest.mbt    # 真实 hvcC/Annex B（8-bit/Main10）+ RPS/POC 用例
    ├── hevc_slice_wbtest.mbt # slice header 逐字段对照 trace_headers
    ├── hevc_sei_wbtest.mbt   # 真实 x265 SEI 逐字段对照 trace_headers
    ├── hevc_access_unit_wbtest.mbt # 真实 B 帧 GOP 的 POC/解码序
    ├── hevc_cabac_wbtest.mbt # CABAC init 状态 + 真实 slice bin/位对 C
    ├── hevc_intra_wbtest.mbt # 33 种帧内模式对自编译 C pred.c 逐值
    ├── hevc_transform_wbtest.mbt # IDCT/DST/反量化对 C DSP 逐值
    ├── hevc_intra_decode_wbtest.mbt # I 片真实码流逐帧 YUV MD5
    ├── hevc_inter_wbtest.mbt # P/B 真实码流逐帧 YUV MD5 + 拒绝路径负例
    ├── hevc_inter_realdata_wbtest.mbt # P/B 码流 base64 素材与期望 MD5
    ├── hevc_bitdepth_wbtest.mbt # Main10/Main12 真实码流逐帧 YUV MD5（滤波/未滤波）
    ├── hevc_bitdepth_realdata_wbtest.mbt # 10/12-bit 码流 base64 素材与期望 MD5
    ├── hevc_wpp_wbtest.mbt   # 单 slice WPP entry point 真实码流逐帧 MD5
    ├── hevc_wpp_realdata_wbtest.mbt # WPP 码流 base64 素材与期望 MD5
    ├── hevc_tiles_wbtest.mbt # 2x2 tiles 真实码流逐帧 MD5（滤波/未滤波）
    ├── hevc_tiles_realdata_wbtest.mbt # kvazaar tiles 码流 base64 素材与期望 MD5
    ├── hevc_tskip_wbtest.mbt # transform skip 真实码流逐帧 MD5（滤波/未滤波）
    ├── hevc_tskip_realdata_wbtest.mbt # transform skip 码流 base64 素材与期望 MD5
    ├── hevc_444_wbtest.mbt   # 8/10-bit 4:4:4 真实码流逐帧 MD5 + 独立 intra 接口
    ├── hevc_444_realdata_wbtest.mbt # 4:4:4 码流 base64 素材与期望 MD5
    ├── hevc_422_wbtest.mbt   # 8/10-bit 4:2:2 真实码流逐帧 MD5 + 独立 intra 接口
    ├── hevc_422_realdata_wbtest.mbt # 4:2:2 码流 base64 素材与期望 MD5
    ├── hevc_scaling_wbtest.mbt # 默认 scaling list 真实码流逐帧 MD5（滤波/未滤波）
    ├── hevc_scaling_realdata_wbtest.mbt # kvazaar scaling list 码流 base64 素材与期望 MD5
    ├── audio_headers_wbtest.mbt # 真实 ADTS/MP3 帧头 + LSF/自由格式
    ├── idct_wbtest.mbt       # 对照 dctref 参考 + FFmpeg dct.c 判据
    ├── huffman_wbtest.mbt    # Kraft/最优性/两实现互证/往返
    ├── h264_sei_wbtest.mbt   # SEI 真实码流逐字段对照 trace_headers + 负例
    ├── h264_sei_realdata_wbtest.mbt # SEI 码流 base64 素材（x264 CBR/bsf 注入/合成）
    ├── h264_inter_wbtest.mbt # MC 整数/半像素/四分像素 + mvpred 中值/回退单元测试
    ├── h264_psynth_wbtest.mbt # 合成 CABAC P 帧端到端（I_PCM 参考 + MV 平移断言）
    ├── aac_wbtest.mbt        # ICS/TNS 逐字段 + MDCT/TDAC/窗口性质 + 静音帧 PCM
    ├── aac_spectrum_wbtest.mbt # 真实 libfdk_aac 码流 46 帧 PCM 差分（≤1 LSB）
    ├── aac_codebook_wbtest.mbt # 全码书元组/符号/位消费 + 长短窗逆变换缩放回归
    ├── aac_pulse_wbtest.mbt   # pulse 语法、采样率相关边界与非法输入回归
    ├── aac_transient_wbtest.mbt # 真实短窗/窗口转换/TNS/PNS 与 pulse 的 PCM 差分
    ├── aac_transient_realdata_wbtest.mbt # native/FDK 突发信号与合成 pulse 参考素材
    ├── aac_stereo_wbtest.mbt  # CPE 逐样本差分、工具覆盖与畸形码流回归
    ├── aac_stereo_realdata_wbtest.mbt # native/FDK 立体声与独立/联合立体声合成素材
    ├── aac_layout_wbtest.mbt  # 真实 5.1/7.1、PCE、标签和元素乱序 PCM 差分
    ├── aac_layout_realdata_wbtest.mbt # 多声道与非连续标签/乱序元素参考素材
    ├── aac_pce_wbtest.mbt     # 默认布局、PCE 截断/重复、DSE 与失败帧状态回归
    ├── aac_height_wbtest.mbt   # 三层 PCE、indexed 11..14、22.2/960，含 codec/format 参考向量
    ├── aac_coupling_wbtest.mbt # CCE 三位置/增益/标签与截断回归，含 codec/format 参考向量
    ├── aac_960_wbtest.mbt     # 960/120 MP4 到 PCM，配套 aac_960_realdata_wbtest.mbt
    ├── aac_config_wbtest.mbt  # ASC 初始化、PCE 对齐、延迟/扩展字段及不支持配置回归
    ├── aac_spectrum_realdata_wbtest.mbt # 真实 AAC 码流 + 参考 PCM base64 素材
    └── mpeg4audio_wbtest.mbt # 位串手推的 AAC-LC/SBR/PS/USAC/ALS 头部用例
```

## 3. 当前进度

**总体**：全量 FFmpeg 约 160 万行（实测 1,595,275 行），本次完成 MoonBit 源文件
（`moonbit/**/*.mbt`，不含 `_build` 生成文件）共 **104184 行**（libavutil 6483 行 +
libavformat 的 aviobuf 流式 AVIO 层、MP4 解复用、Matroska EBML/Segment/Tracks/Cluster、
裸 AAC/MP3 分帧与容器码流参数桥 32305 行 + libavcodec 的位流/H.264/HEVC/AAC/MP3 码流头、
IDCT/Huffman/MPEG-4 音频切片、**H.264 I 帧重建 + 环路去块滤波（CAVLC 全通 / CABAC 部分
向量 / MP4 `avcC` 长度前缀入口）**、**H.264 P 帧解码与滑窗 DPB（运动补偿/MV 预测/inter
宏块层，含 CABAC P 路径的合成码流端到端向量）**、**H.264 SEI 解析**、**AAC 频谱解码
（Huffman 码书 1..11 + scalefactor + PNS/TNS + IMDCT/加窗全管线，真实 libfdk_aac
码流逐帧解码）**、**MPEG 音频 Layer I/II/III 定点解码**、**HEVC I 片整帧解码与完整
环路滤波（SAO+去块，真实 x265 码流逐帧 YUV MD5 与 ffmpeg 逐字节一致）** 与
**HEVC P/B 帧间预测（merge/AMVP、luma qpel/chroma epel 的 uni/bi/加权 MC、DPB+RPL、
MV 去块边界强度，真实 x265 码流 21/21 帧逐字节一致）**、**HEVC Main10/Main12 位深参数化
（10-bit 加权 B 帧、12-bit 32×32 TU 负移位反量化，去块 beta/tc 位深缩放）**、**HEVC
多 slice 与 WPP（AU 聚合、slice 起点/逐 slice CABAC/QP/RPL、跨 slice bS/SAO 边界、
entry point 与行间状态同步，320×240 四 slice 与单 slice WPP 流逐字节一致）**、**HEVC
tiles（uniform 2×2 tile 布局、CTB raster↔tile-scan 映射、tile 边界 CABAC 重置、tile
感知预测可用性、跨 tile 去块/SAO 边界，kvazaar 码流逐字节一致）**、**HEVC transform
skip（transform_skip_flag/上下文、仅反量化不做反变换，x265 真实码流逐字节一致）**、**HEVC
4:4:4（全尺寸色度平面、逐 PU 色度帧内模式、4×4 色度 TU、色度 QP 截断到 51、hshift=vshift=0
的色度 MC 与去块/SAO）**、**HEVC 4:2:2（hshift=1/vshift=0、每个亮度 TU 两个纵向堆叠色度块、
`tab_mode_idx` 色度模式重映射，8/10-bit I/P/B 真实码流滤波与未滤波两条路径均逐字节一致）**、**HEVC
scaling list（默认/SPS/PPS 矩阵、逐系数 scale_m 与 DC 缩放，kvazaar 默认矩阵
I/P/B+WPP 码流逐字节一致）**
65396 行，均含白盒测试）——约占整体 **6.53%**。

### 已完成模块（阶段 0 + 阶段 1 开端 + 阶段 4/5 码流层）

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
| [matroska_block.mbt](libavformat/matroska_block.mbt) | `matroskadec.c`（`matroska_parse_laces`/`matroska_parse_block`/`matroska_cluster_parsing[]`/`matroska_blockgroup[]`/`matroska_blockmore[]`） | `MkvPacket`（stream_index/data/pts/duration/pos/keyframe/discard_padding）；**三种 lacing**：Xiph（0xFF 链，越界即错）、fixed-size（整除校验）、EBML（首帧**无符号** vint + `laces-2` 个 sint 增量，按 `2^(7w-1)-1` 再偏置，负尺寸/溢出拒绝，末帧取余量）；`matroska_parse_block`：VINT 轨道号（`matroska_find_track_by_num`）、BE16 有符号时间偏移、flags（keyframe bit7 + lacing bits1-2）、`timecode = cluster_time/track.time_scale + block_time - codec_delay_in_track_tb`（`av_rescale_q` 四舍五入到 track timebase）、lace duration 由 BlockDuration 或 DefaultDuration×laces/time_scale 分摊、`pkt->pos` 恒为 **Block payload 起点**（9.0.2 的 `pkt->pos = pos`，各 lace 相同）；Cluster 表（Timecode/SimpleBlock/BlockGroup/BlockAdditions/Position/PrevSize）→ **多 Cluster 循环走查** + 尾部截断容忍（EOF 保留已入队 packet）；BlockGroup 在 master 结束时才解码，保证 BlockDuration/ReferenceBlock 已到齐（`!reference_count` 定关键帧） | ✅ |
| [mpeg4audio.mbt](libavcodec/mpeg4audio.mbt) | `libavcodec/mpeg4audio.c`、`mpeg4audio_sample_rates.h` | `ff_mpeg4audio_get_config`：对象类型（32+ escape）、采样率表/24 位显式、声道配置表、头部隐式 SBR/PS、ALS 头嗅探与重载、USAC/LD 帧长、`0x2b7`/`0x548` 隐式 SBR/PS 同步扩展扫描、PS 修正（含 `channels & ~1`）。返回 GASpecificConfig 位偏移与 C 一致 | ✅ |
| [idct.mbt](libavcodec/idct.mbt) | `libavcodec/simple_idct.c`、`simple_idct_template.c`（`BIT_DEPTH` 8/10/12 + `IN_IDCT_DEPTH` 16）、`idctdsp.c` | `ff_simple_idct{,_put,_add}_int16_{8,10,12}bit`（行 DC 快速路径 + 列蝶形，`SUINT`→`UInt` 32 位回绕算术）；`ff_put_pixels_clamped_c`/`ff_add_pixels_clamped_c`/`put_signed_pixels_clamped_c`、`ff_init_scantable_permutation`、`ff_permute_scantable` | ✅ |
| [idct_v128.mbt](libavcodec/idct_v128.mbt) | 同上（表示改造 + `libavcodec/x86/simple_idct.asm`、`simple_idct10.asm`） | `ff_simple_idct{,_put,_add}_v128`（8 位）与 `..._v128_10bit`/`..._v128_12bit`：块改用 **128 字节 LE-int16 缓冲**；`i8x16_shuffle` 三级 unpack 做 8x8 转置，`i32x4` 逐 lane 蝶形 + `i16x8_narrow_i32x4_s` 收窄（含 int16 截断语义）；`put`/`add` 用饱和窄化（8 位）或 `i16x8_min/max_s`（10/12 位）实现 `av_clip_uintp2` | ✅ |
| [huffman.mbt](libavcodec/huffman.mbt) | `libavcodec/huffman.c`、`huffman.h`（+ `vlc.c`/`get_bits.h` 的位读取） | `ff_huff_build_tree`（两列表树构建 + `get_tree_codes` DFS → `lens`/`xlat`）、`ff_huff_gen_len_table`（堆法码长生成，含 `offset <<= 1` 重试）；另附规范化 Huffman 码的建立与 MSB-first 编/解码（对应 `ff_vlc_init_from_lengths` + `put_bits`/`get_bits`） | ✅ |
| [bitstream.mbt](libavcodec/bitstream.mbt) | `libavcodec/get_bits.h`、`golomb.h` | MSB-first `BitReader`（`get_bits`/`show_bits`/`skip_bits`/越界归零/`get_bits_left`）+ `get_ue_golomb{,_long,_31}`、`get_se_golomb{,_long}`、`bytesize`、`align`；H.264 表 9-1 的 Exp-Golomb 向量 | ✅ |
| [h2645_parse.mbt](libavcodec/h2645_parse.mbt) | `libavcodec/h2645_parse.c`、`h2645_parse.h` | `ff_h2645_extract_rbsp`（防竞争字节去除 + 起始码截断）、`ff_h2645_packet_split`（Annex B / 长度前缀，H.264 与 HEVC NAL 头）、`ff_h2645_unit_requires_zero_byte`；NAL 头解析（`nal_ref_idc`/`nuh_layer_id`/`temporal_id`） | ✅ |
| [h2645_vui.mbt](libavcodec/h2645_vui.mbt) | `libavcodec/h2645_vui.c`、`h2645data.c` | 公共 VUI：SAR 表/扩展 SAR、overscan、video signal + 颜色描述（保留值映射 unspecified）、chroma location；`ff_h2645_pixel_aspect` 全表 | ✅ |
| [h264_ps.mbt](libavcodec/h264_ps.mbt) | `libavcodec/h264_ps.c`、`h264_ps.h`、`h264_parse.c`(`ff_h264_decode_extradata`) | SPS 全字段（高 profile 的 chroma/位深/缩放矩阵、POC、裁剪、VUI/HRD/bitstream restriction、帧率与 `num_reorder_frames` 推导）、PPS（CABAC/ref/SliceGroup 拒绝/加权/QP/缩放列表）、`avcC` 与 Annex B extradata 解析。未建解码端 dequant/chroma-QP 派生表 | ✅ |
| [hevc_ps.mbt](libavcodec/hevc_ps.mbt) | `libavcodec/hevc/ps.c`、`ps.h`、`hevc/parse.c`(`ff_hevc_decode_extradata`) | PTL（profile tier level + 兼容标志）、VPS、SPS（chroma/位深/裁剪/CTB 派生/RPS/PCM/VUI/RExt/SCC）、PPS（tiles/deblocking/缩放/RExt/SCC）、`hvcC`/Annex B extradata、`ff_hevc_compute_poc2`。多层/3D 扩展返回 `PATCHWELCOME`；HRD 按位消费但未存储 | ✅ |
| [h264_slice.mbt](libavcodec/h264_slice.mbt) | `libavcodec/h264_slice.c`(`ff_h264_decode_slice_header`) | I/P 单帧 slice header：`first_mb_in_slice`、slice_type、PPS/SPS 查找、`frame_num`、场旗标、IDR POC 与参考标记字段、P 的 `num_ref_idx` 覆盖/参考列表修改/`cabac_init_idc`、`slice_qp_delta`、去块滤波控制；B/SP/SI 的参考列表与权重表语法显式拒绝 | ✅ |
| [h264_cavlc.mbt](libavcodec/h264_cavlc.mbt) | `libavcodec/h264_cavlc.c`(`decode_residual`)、`h264_ps.c`(`ff_h264_dequant4_coeff_init`/`ff_h264_chroma_qp`) | CAVLC 残差：coeff_token/total_zeros/run_before/level_prefix-suffix 三级码表（C 的 VLC 子系统改为同表构建的二叉 trie，逐位等价）、PPS 派生的去量化表与 chroma QP 表；系数按 C 的转置布局存放 | ✅ |
| [h264_idct.mbt](libavcodec/h264_idct.mbt) | `libavcodec/h264idct_template.c` | `ff_h264_idct_add`、`ff_h264_idct_dc_add`、`ff_h264_luma_dc_dequant_idct`、`ff_h264_chroma_dc_dequant_idct`（8-bit）；`SUINT` 用 32 位 `UInt` 复刻回绕语义，`dctcoef` 写回按 `int16` 截断。8x8DCT 变体未移植（CAVLC 端直接拒绝 8x8 宏块） | ✅ |
| [h264_pred.mbt](libavcodec/h264_pred.mbt) | `libavcodec/h264pred_template.c`、`h264_parse.c`(`ff_h264_check_intra4x4_pred_mode`/`ff_h264_check_intra_pred_mode`) | 4x4 九模式（含 DC 边缘变体）、16x16 四模式、chroma 8x8 四模式的 8-bit 帧内预测，以及「参考样本可用性 → 模式改判」逻辑；邻居直接读重建平面（FFmpeg 读每 MB 的边界缓冲，样本值相同） | ✅ |
| [h264_decode.mbt](libavcodec/h264_decode.mbt) | `h264_cavlc.c`(`ff_h264_decode_mb_cavlc`)、`h264_mb_template.c`(`hl_decode_mb`)、`h264_slice.c`(`init_dimensions`) | **H.264 Baseline I 帧重建**：CAVLC 宏块解析 → dequant → 4x4 IDCT / luma & chroma DC Hadamard → 帧内预测 → 写回平面；`I_4x4`/`I_16x16`/`I_PCM` 三条宏块路径、8x8 z-order 块序与 top-right 可用性掩码、SPS 裁剪与 `H264Frame::yuv420p` 输出；入口 `h264_decode_annexb_i_frames`（Annex B，就地解析 SPS/PPS），默认出厂即走环路滤波，`..._ex(data, true)` 跳过 | ✅ |
| [h264_deblock.mbt](libavcodec/h264_deblock.mbt) | `h264dsp_template.c`(`h264_loop_filter_luma{,_intra}`、`h264_loop_filter_chroma{,_intra}`)、`h264_loopfilter.c`(`filter_mb_dir`/`ff_h264_filter_mb_fast`) | **环路去块滤波**：弱/强（intra）luma 与 chroma 四个内核（`xstep`/`ystep` 参数化后一套代码同时覆盖横向/纵向边）；宏块边 bS=4、内部边 bS=3（progressive intra 的真实取值，走弱核）；`alpha_table`/`beta_table`/`tc0_table` 由 C 源批量提取；左/上宏块 QP 取均值、chroma QP 按 `pps->chroma_qp_index_offset` 派生；`slice_alpha_c0_offset`/`slice_beta_offset` 按 C 的 `div2 * 2` 缩放 | ✅ |
| [h264_sei.mbt](libavcodec/h264_sei.mbt) | `libavcodec/h264_sei.c`、`h2645_sei.c`、`sei.h` | **H.264 SEI 解析**：消息框架（type/size 的 0xFF 扩展、双零字节截尾）；buffering period（缺失 SPS 返回 `AVERROR_PS_NOT_FOUND` 非致命）、picture timing（payload 暂存 + `ff_h264_sei_process_picture_timing` 对 SPS 延迟解析，含时钟时间戳全语法）、recovery point、green metadata；公共消息集（h2645_sei.c）：user data unregistered（含 `x264 - core N` 版本嗅探）、display orientation、frame packing arrangement（H.264 分支）、film grain characteristics、alternative transfer、ambient viewing environment、mastering display（`present=2` 语义）、content light。未接：ITU-T T.35（type 4）与 AVFrame side-data 层、HEVC 侧入口 | ✅ |
| [audio_headers.mbt](libavcodec/audio_headers.mbt) | `libavcodec/adts_header.c`、`adts_parser.c`、`mpegaudiodecheader.c`、`mpegaudiotabs.h` | `ff_adts_header_parse{,_buf}`（AAC-LC/Main/SSR/LTP、采样率/声道/帧长/码率）、`ff_mpa_check_header`、`avpriv_mpegaudio_decode_header`（MPEG1/2/2.5、Layer I/II/III、LSF、自由格式）、`ff_mpa_decode_header`；码率/采样率全表 | ✅ |
| [mp3_tables.mbt](libavcodec/mp3_tables.mbt) | `libavcodec/mpegaudiodec_common.c`、`mpegaudiodsp_data.c` | `ff_band_size_long/short`、`ff_slen_table`、`ff_lsf_nsf_table`、`ff_mpa_pretab`、`ff_mpa_huff_data` 与 Layer III 的 15 张 Huffman 码长/符号表，全部由 C 源批量提取（不手工转录） | ✅ |
| [mp3_dsp.mbt](libavcodec/mp3_dsp.mbt) | `mpegaudiodsp_template.c`(fixed, `USE_FLOATS=0`)、`mpegaudiodsp.c`、`dct32_template.c` | 定点 IMDCT/多相合成滤波：`ff_imdct36` 与 36 点/12 点窗表生成、`ff_dct32`、合成窗与频率反转；`INTFLOAT`=`int` → MoonBit 32 位回绕 `Int`，`mulh`/`mull` 走 64 位中间积 | ✅ |
| [mp3_decode.mbt](libavcodec/mp3_decode.mbt) | `mpegaudiodec_template.c`(fixed) | **MPEG-1/2/2.5 Layer III 定点解码**：side info、scalefactor（slen 表）、Huffman 解码、反量化（`ff_mpa_pretab` 预增益）、立体声处理（MS/intensity）、短块重排、bit reservoir、输出 S16 交织 PCM；三层共用的合成滤波 `mpa_synthesize`；入口 `decode_mp3_stream` / `Mp3Decoder`（`decode_frame` 按帧头 `layer` 分派） | ✅ |
| [mpa_layer12.mbt](libavcodec/mpa_layer12.mbt) | `mpegaudiodec_template.c`(`mp_decode_layer1`/`mp_decode_layer2`)、`mpegaudio.c`(`ff_mpa_l2_select_table`) | **Layer I / Layer II 定点解码**：Layer I 的 4 位分配 + 6 位 scalefactor + `n+1` 位尾数；Layer II 的五张分配表选择（含 `ff_mpa_l2_select_table` 的码率/采样率判据）、`scale_code` 四种 scalefactor 共享模式、分组量化（3/5/9 步，走 `ff_division_tabs`）与线性量化、joint stereo 的 `bound` 共享区；`l1_unscale`/`l2_unscale_group` 用与 C 相同的 `FRAC_BITS` 整数乘子；无 IMDCT/混叠/bit reservoir | ✅ |
| [mpa_layer12_tables.mbt](libavcodec/mpa_layer12_tables.mbt) | `mpegaudiodata.c`、`mpegaudiodec_common.c` | `ff_mpa_sblimit_table`、`alloc_table_{1,3,4}`、`ff_mpa_quant_{steps,bits}` 由 C 源脚本提取；`ff_scale_factor_modshift`、`scale_factor_mult`、`scale_factor_mult2`、`ff_division_tabs` 按 C 的初始化逻辑**派生**（不硬编码 2368 个魔数） | ✅ |
| [rawaudio.mbt](libavformat/rawaudio.mbt) | `libavformat/aacdec.c`、`mp3dec.c`、`id3v2.c`（分帧部分） | 裸 ADTS AAC 与 MPEG 音频分帧：ID3v2 跳过、ADTS 逐帧、MP3 帧扫描、首帧 Xing/Info/VBRI 识别并剔除、ID3v1 尾部跳过；输出与 `ffprobe` 一致的每帧 `pos`/`size`/`pts`/`duration` | ✅ |
| [codec_tags.mbt](libavformat/codec_tags.mbt) | `libavformat/matroska.c`(`ff_mkv_codec_tags`)、`isom_tags.c` | Matroska CodecID 与 MP4 sample-entry fourcc → FFmpeg 编解码器名（H.264/HEVC/AAC/MP3 及常用邻居） | ✅ |
| [codec_parameters.mbt](libavformat/codec_parameters.mbt) | `mov.c`/`matroskadec.c` 的 `codecpar` 汇聚 | 容器 → `CodecParameters` 桥：H.264/HEVC `avcC`/`hvcC` 解出分辨率/裁剪/位深/profile/level/VUI 帧率/SAR；AAC AudioSpecificConfig 解出采样率/声道/帧长；MP4/MKV 两套入口（`mp4_track_codec_parameters`/`mkv_track_codec_parameters`） | ✅ |

| [h264_mb.mbt](libavcodec/h264_mb.mbt) | `h264_mb_template.c`(`hl_decode_mb_predict_luma`/`hl_decode_mb_idct_luma` + chroma 路径) | 宏块**重建**半段：帧内预测 → IDCT/Hadamard 叠加 → 平面写回。CAVLC 与 CABAC 的解析层共用这一个函数，像素路径只有一份实现 | ✅ |
| [cabac.mbt](libavcodec/cabac.mbt) | `libavcodec/cabac.c`、`cabac_functions.h`、`h264_cabac.c`(`ff_h264_init_cabac_states`) | **CABAC 算术解码核心**：`ff_init_cabac_decoder`、`refill`/`refill2`/`renorm_cabac_decoder_once`、`get_cabac`、`get_cabac_bypass`、`get_cabac_bypass_sign`、`get_cabac_terminate`，以及按 slice QP 派生 1024 个上下文状态的 `ff_h264_init_cabac_states`。`low` 为 32 位回绕 `Int`，`ff_ctz` 用循环实现 | ✅ |
| [h264_cabac_tables.mbt](libavcodec/h264_cabac_tables.mbt) | `cabac.c`(`ff_h264_cabac_tables`)、`h264_cabac.c`(`cabac_context_init_I`/`_PB`) | 1343 项算术表（`norm_shift`/`lps_range`/`mlps_state`/`last_coeff_flag_offset_8x8`）+ 1024×2 与 3×1024×2 的上下文初值表，由一次性提取脚本从 C 源批量提取（`uint8_t` 负字面量按回绕存储） | ✅ |
| [h264_cabac_mb.mbt](libavcodec/h264_cabac_mb.mbt) | `h264_cabac.c`(`decode_cabac_intra_mb_type`/`_mb_intra4x4_pred_mode`/`_mb_chroma_pre_mode`/`_mb_cbp_luma`/`_mb_cbp_chroma`、`get_cabac_cbf_ctx`、`decode_cabac_residual_internal`、`ff_h264_decode_mb_cabac` 的 intra 分支) | **CABAC 宏块层（I 宏块）**：mb_type/I16x16 预测模式/chroma 预模式/两级 CBP/`mb_qp_delta`/残差（significance map + 逆序 level，含 `>15` 逃逸与 `bypass_sign`）；邻居上下文由每宏块的 `nz`/`cbp_all`/`mb_type_bits` 直接推导（复刻 `fill_decode_caches` 的 `left_cbp`/`top_cbp` 打包与 `0x7CF` 不可用默认值） | ✅（部分向量，见下） |
| [h264_decode.mbt](libavcodec/h264_decode.mbt)（`h264_decode_avc_frames`） | `h264dec.c`(`decode_nal_units` 的 extradata 路径) | **MP4 `avcC` + 长度前缀样本入口**：`ff_h264_decode_extradata` 解参数集并给出 `nal_length_size`，逐样本按长度前缀拆 NAL（`is_nalff=true`），SEI 跳过，切片 NAL 走同一解码路径 | ✅ |
| [h264_mc.mbt](libavcodec/h264_mc.mbt) | `h264_mb.c`/`mc.h`(`mc_dir_part`、`qpel_mc`/`chroma_mc` 标量内核) | **运动补偿**：6 抽头半像素 luma 滤波（qpel 四分插值取全/半平均）、chroma 1/8 双线性；越界取样按 `ff_emulated_edge_mc` 的边界复制钳制。块基准位置显式传入（luma 与 chroma 一致） | ✅ |
| [h264_mvpred.mbt](libavcodec/h264_mvpred.mbt) | `h264_mvpred.h`(`pred_motion`/`pred_16x8_motion`/`pred_8x16_motion`/`pred_pskip_motion`) | **MV 预测**：A/B/C 邻块提取（topright 缺席回退 topleft）、`match_count` 分支（多数取中值 `mid_pred`、单一匹配取该邻块、全不匹配且仅有左邻取 A）、`mvd_cache` 语义（不可用/intra 邻居贡献 0） | ✅ |
| [h264_inter.mbt](libavcodec/h264_inter.mbt) | `h264_cabac.c` 的 P 分支(`decode_cabac_mb_skip`/`decode_cabac_mb_type`/`decode_cabac_p_mb_sub_type`/`decode_cabac_mb_ref`/`decode_cabac_mb_mvd`)、`h264_cavlc.c` 的 P 分支、`h264_mb.c`(`mc_part_std`) | **P 宏块层**：skip flag、P_L0_16x16/16x8/8x16/8x8 四种划分与子划分、ref_idx（`ref_count>1` 才解码）、mvd 读取与写回、inter CBP 与残差路径、`mc_part_std` 等价的分块运动补偿编排（CAVLC 与 CABAC 两套解析共用一个重建） | ✅ |
| [h264_dpb.mbt](libavcodec/h264_dpb.mbt) | `h264dec.c`/`h264_slice.c`(`ff_h264_execute_ref_pic_marking` 滑窗、`ff_h264_build_ref_list0` 默认序、`ff_h264_init_poc` 的 type 0/2) | **滑窗 DPB**：POC type 0 的 MSB 回绕跟踪与 type 2、IDR 清空缓冲、参考图按 POC 降序构建默认 L0（无重排语法）、`ref_frame_count` 滑窗裁剪；`H264Decoder` 的 Annex B/avcC 两入口跨样本保状态 | ✅ |
| [aac_ics.mbt](libavcodec/aac_ics.mbt) | `libavcodec/aac/aacdec.c`(`decode_ics_info`/`decode_band_types`/`ff_aac_decode_tns`/`decode_pulses`、gain-control) | **AAC ICS 语法层**：窗口序列/`max_sfb`/分组、section escape、scalefactor 差分、TNS 压缩系数、1..4 个 pulse 的起始带/offset/amp、gain-control；短窗 pulse 与截断语法拒绝 | ✅ |
| [aac_mdct.mbt](libavcodec/aac_mdct.mbt) | `aacdec_dsp_template.c`(`imdct_and_windowing`)、`aacdec.c` 的 raw_data_block/SCE/CPE/LFE 框架、`kbdwin.c` | **AAC IMDCT/加窗 + 多元素帧框架**：直接法 MDCT/IMDCT（O(N²)，适配 FFmpeg 符号与浮点缩放）、四种窗口序列、正弦/KBD 窗；循环解码 SCE/CPE/LFE/FIL/PCE/DSE，按布局输出 PCM，以类型/标签/子声道绑定历史；校验 END 和元素完整性后才提交布局与窗状态，错误时恢复 PNS 随机状态 | ✅ |
| [aac_stereo.mbt](libavcodec/aac_stereo.mbt) | `aacdec.c`(`decode_cpe`/`decode_mid_side_stereo`)、`aacdec_dsp_template.c`(`apply_mid_side_stereo`/`apply_intensity_stereo`) | **AAC-LC CPE**：共享或独立 ICS、M/S 模式 0/1/2 与逐组掩码、噪声带排除、强度立体声 14/15 的极性与 M/S 反转；左右频谱/pulse→M/S→强度立体声→各声道 TNS/IMDCT，左右历史窗口独立 | ✅ |
| [aac_coupling.mbt](libavcodec/aac_coupling.mbt) | `aacdec_proc_template.c`(`decode_cce`)、`aacdec.c`(`apply_channel_coupling`)、`aacdec_float_coupling.h` | AAC-LC CCE：8 个目标/16 组增益、四增益尺度、公共或逐带有符号差分增益、CPE 四种声道选择、TNS 前/后频域耦合与 IMDCT 后时域耦合；独立标签历史、PCE/ASC 声明及成功布局更新时清理移除的 CCE；支持 1024/960 帧 | ✅ |
| [aac_layout.mbt](libavcodec/aac_layout.mbt) | `aacdec.c`(`decode_pce`/`count_paired_channels`/`assign_channels`/`sniff_channel_order`/`skip_data_stream_element`)、`aacdec_tab.c` 的默认布局/声道表 | 默认配置 1..7/11..14、PCE base/top/bottom 三层前/侧/后/LFE 标签映射，元素掩码排序与 22.2 特殊重排、mixdown/associated-data/comment 语法、DSE 对齐和扩展长度；PCE 耦合标签列表及独立声明；拒绝歧义布局、重复标签、越界与无法命名的 height+CCE 组合；配置 7 采用 FFmpeg 默认非 strict 的 7.1 解释 | ✅ |
| [aac_config.mbt](libavcodec/aac_config.mbt) | `aacdec.c`(`decode_audio_specific_config_gb`/`decode_ga_specific_config`) | AAC-LC 专用 ASC 解析：GA 标志、14 位 coreCoderDelay、ASC-only PCE、extensionFlag3 与 consumed bits；`new_aac_decoder_from_asc` 自动建立布局与声道容量；MP4 esds / CodecParameters 解析 LC PCE 声道数；支持 1024/128 与 960/120 帧长，其他 profile/SBR/PS 初始化显式拒绝 | ✅ |
| [aac_spectrum.mbt](libavcodec/aac_spectrum.mbt) | `aacdec_proc_template.c`(`decode_spectrum_and_dequant` 浮点路径)、`aacdec.c`(`decode_scalefactors`/`decode_pulses`)、`aacdec_dsp_template.c`(`dequant_scalefactors`/`apply_tns`、Levinson 展开) | **AAC 频谱解码**：scalefactor 差分、码书 1..11 Huffman + 打包索引/符号位、book 11 escape、PNS 单位能量噪声、intensity 零填充、采样率相关 pulse 位置校验与重建、TNS Levinson + 就地 AR 滤波 | ✅ |
| [aac_tables.mbt](libavcodec/aac_tables.mbt) | `aactab.c` 全部解码表 + `ff_aac_pow2sf_tab`/`ff_cbrt_tab` 生成算法 | 批量提取表：scalefactor VLC（121 项）、码书 1..11 的 codes/bits、5 张 `codebook_vector_*_idx` 打包索引表、3 张 vals 表、`pow2sf` 428 项 float32、`pow43` 8192 项、swb 偏移表（1024/128 与 960/120 全采样率）与 `tns_max_bands`；提取脚本 `scripts/extract_aac_tables.py`（与 C 源逐值 diff 校验） | ✅ |

**当前状态**：`moon check` 0 error / 0 warning，`moon test` **517/517 全绿**。CABAC 多行复杂码流的失步仍是已知偏差（见下）。

### CABAC 的已知偏差（重要）

CABAC 算术核心（`cabac.mbt`）**已用 FFmpeg 自己的 `libavcodec/tests/cabac.c` 向量验证**：把该测试里的参考编码器一并移植（`cabac_wbtest.mbt`），10240 个 bypass 比特 + 10240 个上下文比特全部逐比特还原，终止位也命中。`av_lfg_get`（`libavutil/lfg.c`，MD5 播种）在测试里复刻，向量完全可复现。

宏块层目前**部分正确**：已对上 FFmpeg 默认输出的组合是

* 单宏块（`testsrc2` 16x16）、一行 2 / 3 / 4 个宏块（左邻上下文，`testsrc2` 稠密残差逐像素等于 FFmpeg `-skip_loop_filter all`）；
* 平坦 I16x16 内容的 2 行 / 3 行（上邻上下文 + luma DC 的 coded-block 标志）；
* 3x3 宏块（48x48 稠密）；
* **单行 I + 全 skip CABAC P 帧经滑窗 DPB 端到端**（`libavformat/h264_cabac_p_realdata_wbtest.mbt`：MP4 `avcC` + 长度前缀样本入口与 Annex B 入口各一条，逐帧 YUV MD5 等于 FFmpeg 默认解码）。

**仍会失步**：上邻 + 稠密残差/I4x4 同时出现时（例如 `testsrc2` 16x48 / 32x48 / 64x48，从第二个有上邻的稠密宏块起 qp 即与 FFmpeg 的 `-debug 16` 逐宏块轨迹分岔），以及 P slice 中出现**被编码（非 skip）的 inter 宏块**之后（静态内容 64x16 码流的 P 帧第 3 个宏块失步）。已做并通过的排除：逐条比对 `get_cabac_cbf_ctx`/`decode_cabac_mb_cbp_*`/intra4x4 模式传播/chroma_pred_mode_table/残差与重建全部与 C 一致（独立审计结论）；已修掉 `cbp==0` 宏块缺少 `last_qscale_diff = 0` 复位（C `h264_cabac.c` 尾部 else 分支）。候选疑点记录在 `agent.md` §7，下一步可用「逐符号 (mb,cat,n,ctx,bit) 与带插桩的 C 解码器对照」继续二分。**在修好之前，多行复杂 CABAC 码流与含编码型 inter 宏块的 P slice 输出不可信。**

已修掉并沉淀进 `agent.md` 的坑（都会被这三个向量立刻抓住）：`cbp_all` 在残差后不能被重置（DC 标志会被抹掉）、CABAC 上方邻居的 `nz` 要取上宏块**最后一行**（luma `nz[12+x]`、chroma `nz[2+x]`）、`write_back_intra_pred_mode` 发生在 `check_intra4x4_pred_mode` **之前**（邻居上下文用原始模式而非改判后的 DC 变体）、`cbp==0` 且非 I16x16 的宏块必须复位 `last_qscale_diff`（否则下一宏块的 `mb_qp_delta` 上下文选错）。

**CABAC P 路径**另有一组合成码流端到端向量（`h264_psynth_wbtest.mbt`）：手写 SPS/双
PPS（CAVLC+CABAC）、全 `I_PCM` 的 IDR 帧（非平坦图案，也是 `I_PCM` 路径的首个真实
覆盖）与逐宏块 `P_L0_16x16` + 整数 MV (-8,-8) 的 CABAC P 帧——编码器是
`cabac_wbtest.mbt` 参考编码器的镜像，skip/type/mvd/CBP 的每个上下文推导都按解码端
逐 bin 复刻（含 `amvd` 邻域、inter CBP 的逐 bit 邻域与不可用邻域 `0x00F`）。P 帧必须
等于参考帧按 MV 平移（边界按 `ff_emulated_edge_mc` 复制）。该向量曾抓出两个潜伏
bug：**chroma 运动补偿漏掉块在帧内的基准位置**（此前只有基准 0 的单元测试，列 0
以外的宏块全部取样错位）与 **DPB 参考图的 `height` 字段误取 `cstride*2`**（真实
P 码流的子像素插值一旦触底即越界 panic）。

### AAC 的差分验证与剩余范围

**既有真实向量的逐样本差分已收敛**：libfdk_aac 生成的 44100 Hz 单声道正弦淡入流
（46 帧、全 ONLY_LONG、KBD 窗），全部 **47,104 样本最大误差 1 LSB**，其中
**47,091 样本完全一致**。参考 PCM 已由本机 Docker 的 FFmpeg 9.0.2 重新解码核对，
与内嵌素材逐字节相同。回归测试强制完整解码、最大误差 ≤1 LSB、精确匹配率 ≥99.9%。

此前的大幅度饱和与符号位疑点已定位并修复：

* 索引表的逐项值虽正确，**码书到表的指针映射抄错**：books 7/8 均应使用
  `codebook_vector6_idx`，9/10 均使用 `codebook_vector8_idx`，仅 11 使用
  `codebook_vector10_idx`。提取脚本现直接读取 C 的指针表并校验各表长度；
  `python scripts/extract_aac_tables.py --check` 可核对全部 55 个数组而不改格式。
* FFmpeg 半逆变换是本移植教科书 IMDCT **中间一半的负值**；AAC 浮点路径的
  `init_dsp` 缩放为 `1/(N*32768)`，相对于本移植的 `2/N` 还需乘 **-1/65536**。
  长短窗均已修正，窗表长度分别为 1024/128。
* 参考 PCM 已包含编码器延迟，差分时应对齐同一帧；原探针额外偏移 1024 样本。
* 新增全 11 本码书的**所有元组与非零值符号组合**回归，独立按笛卡尔积顺序构造
  期望系数，并断言位消费数量及尾随哨兵；长短窗综合另对照
  `ff_tx_mdct_naive_inv` 的余弦公式、符号与 PCM 缩放。

**新增真实短窗与窗口转换对拍**：48 kHz 单声道突发信号分别由 FFmpeg native AAC
与 libfdk_aac 编码，参考 PCM 由 FFmpeg 9.0.2 解码取得。native 的 13 帧覆盖
ONLY_LONG/LONG_START/EIGHT_SHORT/LONG_STOP = 1/2/9/1、24 个多窗分组、70 个 PNS
频带；FDK 的 14 帧对应 3/2/7/2、16 个多窗分组、13 帧 TNS。两者均包含正弦/KBD
窗，合计 **27,648 样本最大误差 1 LSB，27,644 样本完全一致**，测试强制窗口/工具
覆盖计数和精确匹配率 ≥99.9%。生成脚本：`scripts/generate_aac_transient_vectors.py`。

**pulse 工具已移植**：解析 1..4 个 pulse、按实际采样率解析 SWB 起点与累计位置、
在谱系数反量化后/TNS 前执行 pulse 重建；噪声与零缩放频带保持原值。语法解析器保留
原始 band/offset，帧解码器在读取频谱前检查位置（与 C 把位置转换放在语法解析中的
组织方式不同，计算与边界相同）。六帧合成码流由 FFmpeg 解码取得参考，覆盖零系数、
正负系数、跨带、重复位置以及 ZERO_BT/NOISE_BT 跳过：**6,144 样本最大误差 1 LSB，
6,136 样本完全一致**；pulse 多步浮点运算采用 Double，精确匹配率要求 ≥99.8%。
另有短窗 pulse、截断语法、非法起始带和越界位置的负例，以及多采样率边界回归。

**新增 AAC-LC CPE 双声道解码**：支持共享 ICS 窗口和左右独立窗口、M/S 的 0/1/2
模式、强度立体声及其 M/S 极性翻转。先解左右频谱/pulse，再做 M/S、强度立体声，
之后各自执行 TNS/IMDCT；共享当前窗口信息不会覆盖右声道的历史窗口形状。

立体声参考由 `scripts/generate_aac_stereo_vectors.py` 生成：native 10 帧（M/S 全带、
20 个强度立体声频带、241 个 PNS 频带），FDK 11 帧（M/S 显式掩码、86 个强度频带、
18 个声道帧 TNS），两者均有短窗；另有 5 帧左右独立窗口与 9 帧显式 M/S/强度/PNS
组合的合成码流。四组参考 PCM 均由 FFmpeg 9.0.2 解码同一码流取得，双声道合计
**71,680 样本最大误差 1 LSB，71,655 样本完全一致**。测试强制左右声道、帧数、
工具覆盖计数与精确匹配率 ≥99.9%。负例覆盖保留的 M/S 模式、掩码截断、越界频带、
声道状态不足和非法尾元素；尾部校验失败不会推进左右窗口历史。

**新增多元素声道布局**：默认 channel_config 1..7 与带内 PCE 已接入，支持同块多个
SCE/CPE/LFE，按 AVChannel 顺序返回 PCM；PCE 支持前/侧/后/LFE 分组、非连续标签、
mixdown/associated-data/comment 语法。PCE 的四位 instance tag 已正确消费，布局跨帧
保留；历史缓冲按元素类型/标签/子声道绑定，元素顺序改变不会交换声道历史。输出顺序
可读 `AacDecoder.layout`，`channels` 保存历史槽位，槽位次序不等同于输出顺序。
`new_aac_decoder(config, n)` 的 n 是容量，必须足以容纳实际布局。带内 PCE 成功提交后
更新 config 的声道数并将 channel_config 置 0。双 SCE 的 indexed stereo 也可解码。

`scripts/generate_aac_layout_vectors.py` 新增五组参考：真实默认 5.1、PCE 5.1/PCE 7.1
各五帧，非连续标签双 SCE 和乱序 PCE 5.1 各四帧，共 **135,168 个声道样本最大误差
1 LSB，135,137 个完全一致**，精确匹配率要求 ≥99.9%。7.1 编码强制 PCE，因为 native
编码器的 indexed config 12 超出 ADTS 三位字段。合成码流每帧交换音频元素顺序，
并覆盖 DSE 普通/扩展长度与对齐；期望 PCM 全部由 FFmpeg 解码同一码流取得。
负例覆盖默认布局范围、PCE 的逐位截断/重复/空布局/不支持排列、缺失/重复/未声明
元素和 DSE 截断。失败帧不提交新布局、不推进窗口历史，并恢复 PNS 随机状态。

**新增 ASC-only PCE 初始化与容器桥接**：`aac_parse_audio_specific_config` 在通用
MPEG 音频头解析之后读取 AAC-LC GASpecificConfig，包括 coreCoderDelay、PCE 和
extensionFlag3，返回配置、布局和 GA 消费位数；PCE 对齐仍相对于 ASC 起点，不因
14 位延迟字段或 PCE 起始位置改变。`new_aac_decoder_from_asc` 据此分配声道容量并
保存布局，MP4 原始音频包无需重复带内 PCE。MP4 esds 与容器通用 CodecParameters
桥接（也用于 Matroska）现能从 LC ASC 的 PCE 得到声道数，避免 config=0 被当作 0 声道。
通用 `ff_mpeg4audio_get_config` 的返回契约及其他音频类型路径保持原有行为。

`scripts/generate_aac_asc_vectors.py` 生成三个真实 MP4：indexed stereo、仅 ASC
携带 PCE 的 5.1/7.1。ffprobe 提供 ASC 和逐包 offset/size，参考 PCM 由 FFmpeg
`-flags2 +skip_manual` 解码，保留 priming 和完整编码帧。三组共 12 包、**65,536 个
声道样本最大误差 1 LSB，65,528 个完全一致**，精确匹配率要求 ≥99.9%；测试同时核对
轨道、参数桥接和初始化后的声道数/布局。新增 GA/PCE/延迟/extensionFlag3 截断、
不支持 profile/采样率与 SBR/PS 的负例；非法 PCE 参数桥接保留容器回退值。
**新增 960/120 帧长综合**：移植 FFmpeg 的 960/120 频带表、正弦/KBD 窗及
420/60 过渡窗重叠，ASC 工厂按 frameLengthFlag 选择几何。短窗频谱仍保持 128 点
步长，IMDCT 结果按 120 点排列；MP4 与参数桥接的 frame_size 同步为 960。
`scripts/generate_aac_960_vectors.py` 合成单/双声道各 10 帧，覆盖四窗口序列、
两种窗形、独立 CPE 窗形及首尾频带；FFmpeg 解码同一 MP4 的 **28,800 个声道样本
最大误差 1 LSB，精确匹配率 ≥99.9%**。本机 FDK 编码器拒绝 960 granule 配置，
因此尚未验证真实编码器产生的 960 码流。合成 MP4 由等长 ADTS 占位包重封装后
替换包内容并设置 ASC 标志；测试容器时间戳保留重封装器的 1024 tick，逐帧 PCM
参考保留完整编码帧，每帧输出 960 样本。

**新增 AAC-LC CCE 声道耦合**：`aac_coupling.mbt` 移植 CCE 语法、目标选择及增益链，
支持最多 8 个目标、16 组增益、四个尺度、公共和逐带差分增益（含符号与零增量缓存）。
源频谱先完成 TNS，目标分别在 TNS 前、TNS 后或 IMDCT 后接收耦合；多个源按标签
顺序累加，独立 CCE 的窗口历史不占输出声道容量。PCE/ASC 保存耦合标签列表，
带内 PCE 成功移除标签后清除对应历史。重复源、未声明源、缺失目标及截断帧在提交
历史前报错；失败帧保持源/目标窗口和 PNS 状态。截断回归同时修复 section data
读尽后持续读取补零而无法退出的问题；空 section 仍遵循 FFmpeg 行为继续消费输入。

`scripts/generate_aac_coupling_vectors.py` 合成 7 组 1024 帧 ADTS 和 2 组 960 帧 MP4：
覆盖四窗口序列、交替窗形、分组短窗、源/目标 TNS、全部增益尺度与 CPE 选择，
包括 16 组增益上限、乱序多个 CCE 和 ASC/PCE 引导。FFmpeg 9.0.2 解码同一码流
产生参考，共 **151,040 个声道样本最大差分 1 LSB，精确匹配率 ≥99.9%**。
这是合成语法覆盖，尚未取得真实编码器产生的 CCE 样本；960 测试容器的时间戳
仍保留 ADTS 重封装的 1024 tick，PCM 对比使用每包完整 960 样本。

**新增高度 PCE 与 indexed 11..14**：按 `decode_pce` 读取 comment 中的 0xAC
高度扩展，先按 base/top/bottom 重排，再移植 `sniff_channel_order` 的三层前/侧/后/LFE
推导。高度值 3 按 C 行为保留原始顺序；短 0xAC comment 仍视作普通注释，高度字段
长度不包含 LFE。普通命名布局按整个元素的声道掩码排序，CPE 左右始终相邻；22.2
执行 C 的九次元素交换，输出顺序有意保留 FFmpeg 的特例，并非逐个 AVChannel 排序。
默认配置 11/12/13/14 及 ASC 工厂、MP4 参数桥接、24 声道容量现在全部接通。

`scripts/generate_aac_height_vectors.py` 合成 4 组 indexed MP4、4 组带高度注释的 ADTS
和一组 ASC-only PCE 的 960 帧 22.2 MP4，由 ffprobe 提供元数据、FFmpeg 9.0.2 解码
同一字节流提供参考 PCM。共 **473,088 个声道样本最大差分 1 LSB，精确匹配率
≥99.9%**，覆盖四窗口序列、交替窗形、PCE 元素乱序、顶层中置/CPE 邻接、保留高度值
回退及 22.2 的 LFE2、顶层、底层。另有 PCE 注释截断与失败帧不推进历史的回归。
这些高度与 indexed 扩展向量为合成语法，真实编码器产生的高度样本尚待补充；960
测试容器时间戳仍保留重封装的 1024 tick，参考比较每包完整 960 样本。

剩余范围与偏差：只支持能映射为命名声道的三层 PCE；C 可回退为 unspecified
顺序的歧义布局在本移植中显式拒绝，高度与 CCE 并用时暂拒绝无法命名的布局；
SBR/PS、USAC 未接入。默认配置 8..10、15 保留/不支持，配置 7 跟随 FFmpeg 默认
非 strict 的 7.1 解释；
未复刻错误 element tag 的位置重映射等兼容 quirk。无布局配置时保留单音频元素的
语法测试入口，多元素必须有 indexed/PCE 布局。更多采样率和工具组合仍需扩充。

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
- **未做（libavcodec）**：LZO、`vlc.c` 表构建、AC-3 等音频解析、其余编解码器
  （见阶段 5）。

### libavcodec 码流层切片（H.264 / H.265 / AAC / MP3）的范围边界与说明

- **H.264**：`h2645_parse.mbt` 完成 RBSP 去防竞争字节、Annex B 与长度前缀两种 NAL 拆分、
  H.264/HEVC NAL 头；`h264_ps.mbt` 完成 SPS/PPS 全语法（含高 profile 缩放矩阵、VUI、
  HRD、bitstream restriction、裁剪尺寸、`num_reorder_frames` 的水平表推导）与
  `avcC`/Annex B extradata。**像素解码已开始**：Baseline I 帧重建通路（slice header、
  CAVLC、宏块重建、环路去块滤波）见下一小节；**SEI 已完成**（`h264_sei.mbt`，T.35 与
  side-data 层未接）；**P 帧与滑窗 DPB 已完成**（`h264_inter/mvpred/mc/dpb`，B/SP/SI
  slice 仍拒绝）；CABAC 的多行复杂码流收敛仍是已知偏差（见 §3）。
- **H.265**：`hevc_ps.mbt` 完成 VPS/SPS/PPS 与 PTL、short-term RPS、VUI、缩放列表、
  Range Extension 与 SCC 语法、`hvcC`/Annex B extradata、POC 计算。**未做**：slice
  segment header、CABAC、预测/变换/滤波、SEI；多层扩展（VPS multilayer、PPS
  multilayer/3D）不建模，遇到即返回 `PATCHWELCOME`；HRD 字段按位消费但不存储。
- **AAC**：`audio_headers.mbt` 完成 ADTS 头；`rawaudio.mbt` 完成裸 ADTS 流逐帧分帧
  （含 ID3v2 跳过与重同步）。**频谱解码已完成**（`aac_spectrum.mbt` + `aac_tables.mbt`：
  Huffman 码书 1..11 含 escape、scalefactor 差分/noise 前导、pulse 重建、PNS、TNS 应用、gain
  control 语法解析；`aac_mdct.mbt`：全四窗口序列 + KBD/正弦窗的 IMDCT→TDAC 叠接），
  CPE 的共享/独立窗口、M/S 和强度立体声已接入，真实长短窗单/双/多声道码流可逐帧
  解码出 PCM，**现有单/双/多声道向量的逐样本差分
  最大为 1 LSB**，含 TNS/PNS/pulse（见 §3「AAC 的差分验证与剩余范围」）；
  默认配置 1..7/11..14、多元素 SCE/CPE/LFE、三层 PCE 及 CCE 已接入；
  SBR/PS、USAC 未做；960 综合已用合成码流对拍。
- **MP3/MP2/MP1**：`audio_headers.mbt` 完成 MPEG 音频头（版本/层/码率/采样率/帧长/
  自由格式）；`rawaudio.mbt` 完成裸流分帧、ID3v2/ID3v1 跳过与首帧 Xing/Info/VBRI
  识别剔除。**三层定点解码均已完成**（见下一小节）。
- **容器接入**：`codec_tags.mbt` 负责 Matroska CodecID / MP4 fourcc 到统一编解码器名的
  映射，`codec_parameters.mbt` 把容器的尺寸/采样率与 `avcC`/`hvcC`/AudioSpecificConfig
  解析结果合并成 `CodecParameters`（profile/level/位深/色度格式/像素格式/帧率/SAR/
  AAC 帧长），MKV 与 MP4 共用同一结构。
- **偏差**：H.264 的 `AV_CODEC_FLAG2_IGNORE_CROP`、`SMV2` codec tag、严格合规级别选项
  未建模；HEVC 的 `setup_pps` 瓦片扫描表未建；像素格式名采用本机小端名
  （如 `yuv420p10le`），与 FFmpeg 的 `AV_PIX_FMT_YUV420P10` 在 x86 上的取值一致。

### libavcodec 解码切片（H.264 Baseline I 帧 / MPEG 音频 Layer I·II·III）的范围边界与说明

这是本项目第一次产出**像素与 PCM**，不再是纯解析层。

**H.264 I 帧重建 + 去块滤波**（`h264_slice.mbt` + `h264_cavlc.mbt` + `h264_idct.mbt` +
`h264_pred.mbt` + `h264_decode.mbt` + `h264_deblock.mbt`）：

- **已做**：I/SI slice header；CAVLC 残差（`coeff_token`/`total_zeros`/`run_before`/
  `level_prefix`+`suffix`，含 chroma DC 的 4 项特殊码表）；PPS 派生的 `dequant4_coeff`
  （`dequant8_coeff` 未建，因为 8x8DCT 直接拒绝）与 `chroma_qp` 表；4x4 IDCT（行/列两遍）
  与 luma/chroma DC Hadamard；4x4 九模式、16x16 四模式、chroma 8x8 四模式的帧内预测与
  可用性改判；`I_4x4`/`I_16x16`（含 `cbp` 六类）/`I_PCM` 三条宏块路径；8x8 z-order 的
  块重建次序与 top-right 可用性掩码；SPS 帧裁剪与 `yuv420p` 打包；**环路去块滤波**
  （宏块边 bS=4 走强核、内部边 bS=3 走弱核，左右/上下 QP 取均值，`alpha`/`beta`/`tc0`
  三张表 + slice 级 `alpha_c0`/`beta` 偏移，`disable_deblocking_filter_idc` 0/1/2）。
- **验证**：默认入口 `h264_decode_annexb_i_frames` **本身就做去块滤波**，因此参考输出是
  FFmpeg 的**默认解码**；需要未滤波像素时用 `h264_decode_annexb_i_frames_ex(data, true)`
  对照 `ffmpeg -skip_loop_filter all`（该选项必须在 `-i` 之前）。两种模式都有对应向量。
- **滤波时序（踩过的坑，务必保持）**：帧内预测必须看到**未滤波**的重建像素，而滤波必须
  按光栅序、且下一行的边要看到**已滤波**的上一行。FFmpeg 用两个机制同时满足：逐行
  `loop_filter()` + 预测读滤波前备份的 `sl->top_borders`。本移植的等价做法是
  **先把整帧重建完，再按宏块光栅序整帧滤波**——「每解一个宏块就立刻滤波」会让后续宏块
  的帧内预测吃到已滤波的左邻，整帧像素会偏。
- **只支持**：Progressive、8-bit 4:2:0、单 slice、`first_mb_in_slice == 0`、每帧一个
  slice。**显式拒绝**（返回 `Err`，不 panic）：CABAC、P/B/SP/SI slice、多 slice、
  场/MBAFF、8x8DCT、非 4:2:0、非 8-bit。
- **代码已写但无真实向量**：`I_PCM` 宏块路径（x264 的 baseline profile 不接受
  `-qp 0` lossless，且 lossless 走变换旁路而非 I_PCM，需手工构造码流才能覆盖；该路径在
  滤波里按 C 的 `qscale_table = 0` 处理）。
- **未接**：SEI 已在后续切片完成（`h264_sei.mbt`）；`chroma_qp_diff`
  （`second_chroma_qp_index_offset` 与第一个不等）时的非 fast 路径
  ——当前按 fast 路径用 plane 0 的偏移派生出 Cb/Cr 各自的 QP。

**MP3 Layer III 定点解码**（`mp3_tables.mbt` + `mp3_dsp.mbt` + `mp3_decode.mbt`）：

- **已做**：MPEG-1/2/2.5 Layer III、mono/stereo/joint stereo（MS 与 intensity）、短块
  重排、scalefactor（slen 表 + `ff_lsf_nsf_table`）、15 张 Huffman 表（符号按 C 的
  `transform_huff_symbol` 变换）、反量化与 `ff_mpa_pretab` 预增益、定点 IMDCT/DCT32/
  合成窗、bit reservoir、输出 S16 交织 PCM。数值路径完全走 C 的 `USE_FLOATS=0`。
- **偏差（bit reservoir）**：C 用 `last_buf` 滚动缓冲 + `gb`/`in_gb` 双读取器切换；本
  移植改为「保留每帧 main-data 区拼接 + 从 `8*main_data_begin` 位前起读」，字节流与 C
  重建的一致，良性码流下逐位相同；reservoir 超过 8 KiB 时截断到最近 4 KiB。
- **未做**：浮点路径、自由格式码流的解码、合成后处理（如 LAME 的 `iTunSMPB` 相关裁剪）。
- **验证**：与 FFmpeg **定点**解码器（`-c:a mp3`，非 `mp3float`）的 PCM MD5 逐字节
  一致——这正是区分定点/浮点两条实现的关键点（浮点解码器给出不同 MD5）。

**MPEG 音频 Layer I / Layer II 定点解码**（`mpa_layer12.mbt` + `mpa_layer12_tables.mbt`）：

- **已做**：Layer I 的 4 位 bit allocation（joint stereo 时按 `bound = (mode_ext+1)*4`
  切分）、6 位 scalefactor、`n+1` 位尾数；Layer II 的分配表选择（`ff_mpa_l2_select_table`
  按每声道码率/采样率/LSF 选 5 张表之一，`sblimit` 分别为 27/30/8/12/30）、`scale_code`
  的四种 scalefactor 共享模式、分组量化（3/5/9 步，用 `ff_division_tabs` 一次取三个样本）
  与线性量化、joint stereo 的 `bound` 共享区（一份尾数、两个 scalefactor）。
  两个层都不用 IMDCT、混叠抑制和 bit reservoir，量化后的子带样本直接进三层共用的
  多相合成滤波（`mpa_synthesize`）。
- **数值路径**：`l1_unscale` / `l2_unscale_group` 与 C 完全相同——`ff_scale_factor_modshift`
  拆出 `shift`/`mod`，乘子是 `MULLx(norm, FIXR(k*2), FRAC_BITS)` 与 `SCALE_GEN`，全部
  按 C 的初始化表达式在 MoonBit 里算出来（含 `4/3`、`4/5`、`4/9` 三组组量化乘子）。
- **验证**：Layer II 用 FFmpeg 原生 `mp2` 编码器生成 4 条码流（stereo 44.1k/192k、
  mono 44.1k/64k、joint stereo 32k/64k、MPEG-2 LSF stereo 24k/64k），覆盖分配表
  1/0/3/4、`bound` 共享区、分组与线性量化；参考 PCM 取 FFmpeg **定点**解码器
  `-c:a mp2`。**Layer I 在 FFmpeg 里没有编码器**，所以两条 Layer I 向量是按规范手工
  拼的帧（3 帧/流，让 mp2 demuxer 能探测），但期望值仍是 FFmpeg 解码同一段码流的
  PCM MD5——手工的是输入，不是期望值。
- **未做**：CRC 校验（与 Layer III 一致：只跳过 16 位 CRC）、自由格式码流、Layer II 的
  ISO 13818-3 低采样率扩展表以外的私有编码器约定（FFmpeg 也只有这 5 张表）。

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
| [h264_idct.mbt](libavcodec/h264_idct.mbt) | 4x4 IDCT 与 DC Hadamard（块级，天然 8/16 位并行） | `h264_idct.asm`、`h264_idct_10bit.asm` | 中；需先把系数的转置布局与 `v128` 载入对齐 |
| [h264_pred.mbt](libavcodec/h264_pred.mbt) | 帧内预测（16x16/chroma 的整块填充与 4x4 的多次 4 行搬移） | `h264_intrapred.asm`、`h264_intrapred_10bit.asm` | 中；DC/plane 的横向/纵向求和可用 `i16x8` 归约 |
| [h264_deblock.mbt](libavcodec/h264_deblock.mbt) | 去块滤波四个核（luma/chroma × 弱/强）：16 或 8 条边沿样本天然是一条 `i16x8`/`i8x16`，`p0/p1/p2/q0/q1/q2` 六个向量载入后按掩码混合 | `h264_deblock.asm`、`h264_deblock_10bit.asm` | 中高；`|p0-q0| < alpha` 等判据可转成 `i8x16_lt_u` + `bitmask` 生成的逐通道掩码，避免分支 |
| [mp3_dsp.mbt](libavcodec/mp3_dsp.mbt) | IMDCT36 / DCT32 / 合成窗（多相滤波的乘加链） | `x86/mpegaudiodsp.c`（SSE 内联） | 中；32 位定点乘加需 `i32x4` 双倍宽技巧，先保证与标量逐样本一致 |
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
- **已做（码流参数桥）**：`codec_tags.mbt`/`codec_parameters.mbt` 为 MP4 与 MKV 提供统一的
  `CodecParameters`（H.264/HEVC 分辨率/profile/level/位深/VUI 帧率/SAR，AAC 采样率/声道/
  帧长）；MP4 的 `esds` 与 MKV 的 CodecPrivate 都走同一套 libavcodec 解析器。
- **未做**：`dvcC`/`dvvC` 整 atom extradata 变体、强制 `use_mfra` 模式（AUTO 下 mfra 仅作
  数据源）、muxer；MP4 中的 MP3 样本仍按通用 `mp4a` 路径处理（`ff_mov_read_esds` 已能给出
  "mp3" codec-id）。

### 未完成（本次切片外）

- `mathematics.c` 中：`av_rescale_delta`、`av_add_stable`、`av_bessel_i0`
- `libavutil/sha512.c`（SHA-384/512）
- libavutil 其余部分：`dict`、`opt`、`pixdesc`、`samplefmt`、`intreadwrite`、
  `des/twofish/sm4`、`lzo`、`eval`、`timecode`、`parseutils` 等
- libavformat 其余部分：`avio.c` 的 URL/协议层、其余 demuxer/muxer
  （AVI、MPEG-TS 优先）、AC-3/DTS 等其余音频流解析、字幕（`tx3g`/TTML）、
  AVIF/HEIF 图像、MP4 muxer；裸 AAC/MP3 分帧与 Matroska 已完成
- libavcodec 已**开始**：IDCT SIMPLE-C、Huffman 树/码长、位流读取、H.264/HEVC 参数集与
  NAL 拆分、AAC ADTS 与 MPEG 音频帧头，以及**三条真正出数据的解码通路**——H.264
  I 帧重建 + 环路去块滤波（CAVLC 全通、CABAC 部分向量、MP4 `avcC` 长度前缀入口）与
  **H.264 P 帧解码 + 滑窗 DPB**（MC/MV 预测/inter 宏块层，Annex B 与 avcC 两入口）、
  MP3 Layer III 定点解码（IMDCT/合成滤波/PCM）+ MPEG 音频 Layer I/II（分配/scalefactor/
  组量化）、+ **H.264 SEI**（`h264_sei.mbt`，含公共消息集）与 **AAC 频谱解码**
  （码书 1..11/scalefactor/PNS/TNS + 四窗口序列 IMDCT/KBD 窗，真实码流逐帧出 PCM）；
  其余未做：**CABAC 多行复杂码流的收敛**、B/SP/SI slice、HEVC 的 tiles+WPP 组合与
  dependent slice（I/P/B、10/12-bit、多 slice、WPP、tiles 与 transform skip 主链路已出数据）、
  AAC SBR/PS 与无法命名的 height+CCE 布局、**SEI 的 ITU-T T.35 与 AVFrame side-data 层**、
  VLC 表构建、LZO 与其余编解码器
- libswscale / libswresample / libavdevice / fftools：**未开始**

---

### 2026-10-21 增量：WAV/TS/HLS/DASH 容器 + PNG/MJPEG 解码 + VP9/AV1/Opus 码流头

本轮在既有 MP4/MKV/H.264/AAC/MP3 切片之上新增：

| 切片 | 文件 | 范围与验证 |
|---|---|---|
| WAV/RIFF | [wav.mbt](libavformat/wav.mbt) | RIFF/RIFX/RF64/BW64、`fmt `/`fact`/`data` 走查、WAVE_FORMAT_EXTENSIBLE、`ff_pcm_default_packet_size` 的 10 fps 包长与块对齐；真实 ffmpeg s16/f32/s24 文件的 pos/size/pts/duration 逐值对齐 ffprobe，另含 RIFX/RF64/奇数块填充/缺失块负例 |
| MPEG-TS | [mpegts.mbt](libavformat/mpegts.mbt) | 188/192(M2TS)/204 布局、PAT/PMT（PSI 分片累积）、PES 头部/PTS/DTS、无长度视频 PES 在下一 PUSI/EOF 冲刷、已知长度 PES 即时输出、PCR、ISO/HDMV/registration 流类型表；真实 H.264+AAC 与 B 帧 TS 的 5 个/3 个 PES 的 pos/pts/dts/size 与 `ffprobe -fflags +noparse` 逐值一致；真实 x265 HEVC+AAC TS 的两个流映射（0x24/0x0F）与 5 个 PES 交错的 pos/pts/dts/size 逐值一致；合成 HEVC+Opus 注册描述符与 M2TS 用例 |
| HLS | [hls.mbt](libavformat/hls.mbt)、[hls_crypto.mbt](libavformat/hls_crypto.mbt) | 主/媒体 M3U8（VERSION/TARGETDURATION/MEDIA-SEQUENCE/ENDLIST/PLAYLIST-TYPE）、EXTINF、BYTERANGE 续接、KEY/MAP/DISCONTINUITY/GAP/PROGRAM-DATE-TIME、STREAM-INF/I-FRAME-STREAM-INF/EXT-X-MEDIA、`$...$` 之外的 URI 相对解析；真实 ffmpeg TS/fMP4 播放列表与手工边界用例 |
| DASH | [xml.mbt](libavformat/xml.mbt)、[dash.mbt](libavformat/dash.mbt) | 最小 XML（元素/属性/CDATA/注释/实体/命名空间后缀匹配）+ MPD Period/AdaptationSet/Representation 继承、BaseURL 链、SegmentTemplate `$Number%05d$`/`$Time$`/`$RepresentationID$`/`$Bandwidth$`、SegmentTimeline（含 `r="-1"`）、duration 枚举、SegmentList/SegmentBase；真实 ffmpeg MPD 的 3+3 个分片编号/时间/时长/URL 逐值断言 |
| Matroska Cues | [matroska_cues.mbt](libavformat/matroska_cues.mbt) | CuePoint/CueTime/CueTrackPositions/CueClusterPosition/RelativePosition/BlockNumber 解析与按时间二分 seek；真实 x264 MKV（关键帧 0/1/2s）3 条 cue 与 ffprobe 关键帧位置对应 |
| MP4/WebM 参数桥 | [codec_parameters.mbt](libavformat/codec_parameters.mbt)、[extradata.mbt](libavformat/extradata.mbt) | VP9 `vpcC`、AV1 `av1C`、Opus`OpusHead` 解析；MP4 `dOps` → OpusHead、`av1C`/`vpcC` 路径；真实 VP9/AV1/Opus WebM 与 MP4 AV1/VP9/Opus 的 codec/尺寸/位深/声道/pre-skip 对齐 ffprobe |
| PNG | [inflate.mbt](libavcodec/inflate.mbt)、[png.mbt](libavcodec/png.mbt)、[png_apng.mbt](libavcodec/png_apng.mbt) | 纯 MoonBit zlib/DEFLATE（stored/fixed/dynamic Huffman、LZ77、Adler32）+ PNG IHDR/PLTE/tRNS/IDAT、五种行滤波、Adam7 隔行、1/2/4/8/16-bit 与调色板/灰度/RGB/RGBA/GA、tRNS 提升；8 种原生 pix_fmt 的原始输出 MD5 与 `ffmpeg -f rawvideo` 完全一致（含 pal8 的 256 项 BGRA 调色板）。另含分块 CRC-32 校验（`av_png_decode_ex(data, true)`，对齐 `-err_detect crccheck+explode`）与 APNG：`acTL`/`fcTL`/`fdAT`、默认图排除、帧矩形、delay/loop、NONE/BACKGROUND/PREVIOUS 处置与 SOURCE/OVER 混合，输出规范化 RGBA；FFmpeg 生成的 3 帧 APNG 逐帧 MD5 一致 |
| MJPEG | [mjpeg.mbt](libavcodec/mjpeg.mbt)、[mjpeg_scan.mbt](libavcodec/mjpeg_scan.mbt) | 基线 SOF0/SOF1 与渐进式 SOF2、DQT/DHT/DRI/SOS、重启标记、DC 预测（`4<<8` 偏置）、AC 游程、多扫描累积系数、渐进 DC first/refine 与 AC first/refine（含 EOBRUN/ZRL/last_nnz）、Simple-C IDCT、4:2:0/4:2:2/4:4:4/灰度采样与原生 yuvj 输出；真实 ffmpeg 顺序与渐进 JPEG 三平面 MD5 逐字节一致 |
| HEVC slice header | [hevc_slice.mbt](libavcodec/hevc_slice.mbt) | 首片/独立非首片的 slice segment header：IRAP no_output、PPS/SPS 查找、slice address、slice_type、POC LSB、short/long-term RPS、temporal-MVP、SAO、P/B 参考计数与权重表、collocated/merge、I/P/B 的 QP/chroma-QP/去块字段；真实 x265 IDR 与 B 帧 GOP 的字段和 `trace_headers` 逐值一致，依赖片段与列表重排返回 PATCHWELCOME |
| H.264 去块修复 | [h264_deblock.mbt](libavcodec/h264_deblock.mbt) | bS 派生修正：内部边非零系数=2、MB 边=3，MV/ref 差异只产生 bS=1（|dx|/|dy|≥4）；真实 CABAC P_8x8 refs=2 流在默认与 `-skip_loop_filter all` 两种 framemd5 下均与 ffmpeg 逐字节一致 |
| HEVC CABAC | [hevc_cabac.mbt](libavcodec/hevc_cabac.mbt) | 3×199 init_values 与 cabac_init_state 公式；真实 x265 IDR slice 的上下文状态、64 个 ctx=7 bin 与 16 个 bypass 位和自编译 FFmpeg C 逐值一致 |
| HEVC intra pred | [hevc_intra.mbt](libavcodec/hevc_intra.mbt) | planar/DC（含 corner 平滑）/33 个角度模式，4/8/16/32 全部模式；用自编译 FFmpeg C pred.c 生成参考，和值+首末样本逐值一致（参考样本平滑/可用性由调用层后续接入） |
| HEVC transform | [hevc_transform.mbt](libavcodec/hevc_transform.mbt) | 8/10/12-bit IDCT 4/8/16/32（含 col_limit 逐列收缩）、DC-only IDCT、4x4 DST、反量化（`15 - bit_depth - log2_size`，12-bit 大块负移位按 C 的 uint16 回绕）与 residual 叠加；4x4/8x8 全量系数、16/32 和值与抽样点均与 FFmpeg C DSP 逐值一致 |
| HEVC SEI | [hevc_sei.mbt](libavcodec/hevc_sei.mbt) | 前缀/后缀 SEI、0xFF type/size 续接；mastering display、content light、user_data_unregistered、recovery point、alternative transfer、ambient viewing；x265 真实 SEI 的 CLL/色域/亮度与 trace_headers 逐值一致 |
| HEVC access unit | [hevc_access_unit.mbt](libavcodec/hevc_access_unit.mbt) | 按 `first_slice_segment_in_pic_flag` 组装访问单元、IDR/IRAP 关键帧标记、按 temporal-id-0 更新 POC；真实 x265 B 帧 GOP（I/P/B/B）的 POC 0,3,2,1 与解码顺序逐值一致 |
| 码流头 | [opus_packet.mbt](libavcodec/opus_packet.mbt)、[av1.mbt](libavcodec/av1.mbt)、[vp9.mbt](libavcodec/vp9.mbt) | Opus TOC/四种包码/Xiph lacing/120 ms 限制；AV1 OBU LEB128 + `av1C`/序列头（含 order-hint/screen-content/superres 状态）与关键/帧内/inter frame header（类型/show/尺寸/render/superres/intrabc、primary_ref/refresh、7 个参考槽、统一 tile 布局与 base_q_idx/量化 delta；关键帧与 inter 字段均对齐 `trace_headers`）；VP9 帧头（profile、关键帧/帧内、色彩配置、尺寸、刷新掩码）与 superframe index 拆分；真实 WebM 包与 ffprobe 对齐 |
| VP9 压缩头/分片 | [vp9_rac.mbt](libavcodec/vp9_rac.mbt)、[vp9.mbt](libavcodec/vp9.mbt) | FFmpeg `VPXRangeCoder` 的 MoonBit 移植（norm_shift/renorm/概率与等概率比特/`update_prob`）；压缩头 marker、tx_mode 0–4（lossless 强制 0，switchable 的 tx8/16/32 概率更新）、skip 概率、系数/模式/MV 更新语法的精确消费；tile 布局 tile_cols/rows log2、多行多列、除末片外的 4 字节大端长度、末片剩余字节。libvpx-vp9 真实向量的 tx_mode 由 FFmpeg 解码器 `vp9.c` 插桩逐帧核对（0/1/2/3/4 均覆盖）；512×256 双列与 512×512 双行双列分片的 offset/size/首 marker 均逐值断言 |
| HEVC 整帧解码（I 片） | [hevc_intra_decode.mbt](libavcodec/hevc_intra_decode.mbt)、[hevc_cabac_syntax.mbt](libavcodec/hevc_cabac_syntax.mbt)、[hevc_residual.mbt](libavcodec/hevc_residual.mbt)、[hevc_intra_ref.mbt](libavcodec/hevc_intra_ref.mbt)、[hevc_scan.mbt](libavcodec/hevc_scan.mbt)、[hevc_picture.mbt](libavcodec/hevc_picture.mbt)、[hevc_deblock.mbt](libavcodec/hevc_deblock.mbt)、[hevc_sao.mbt](libavcodec/hevc_sao.mbt) | 打通 I 片主链路与完整环路滤波：CTU/CU 四叉树、split/part_mode、帧内 MPM（含 CTB 边界规则）、变换树与 cbf、cu_qp_delta/qP 预测、残差语法（sign hiding）、反量化、IDCT/DST、参考样本可用性/z-scan/3-tap 与 strong 平滑、4:2:0 重建、TU 边界 bS=2 的去块（亮度 weak/strong、色度）、SAO（merge、band/edge offset、图片边界恢复）。真实 x265 流 32×32、64×48 四 CTU（默认与未滤波）、64×48 SAO+去块（默认解码）、64×64 强平滑、80×64 部分 CTU 的 yuv420p MD5 均与 ffmpeg 逐字节一致；长度前缀 NAL 输入一致；另有 8×8 真实块 IDCT 对 C DSP 的逐值回归。范围：8/10/12-bit 4:2:0/4:2:2/4:4:4 单 I 片（Main10 IDR 已逐字节验证），支持 SPS/PPS scaling list（默认矩阵与显式数据），无 PCM/transform skip/tiles/WPP；`ff_hevc_decode_intra_frame_unfiltered` 返回滤波前像素 |
| HEVC P/B 帧间预测 | [hevc_refs.mbt](libavcodec/hevc_refs.mbt)、[hevc_mc.mbt](libavcodec/hevc_mc.mbt)、[hevc_inter.mbt](libavcodec/hevc_inter.mbt)、[hevc_inter_decode.mbt](libavcodec/hevc_inter_decode.mbt) | 在 I 片链路上补齐 P/B：MvField/DPB 槽位池、RPS 候选列表与 `ff_hevc_slice_rpl` L0/L1 拼接、`mv_scale`/`check_mvset` 时域 MV 缩放；运动补偿全套（luma 8-tap qpel / chroma 4-tap epel 的 uni/bi 与加权变体、`ff_emulated_edge_mc` 语义的边界复制）；inter 语法（skip/merge/merge_idx/inter_pred_idc/ref_idx/mvd_coding/mvp_lx/part_mode 全模式含 AMP）；merge 候选推导（空间 A1/B1/B0/A0/B2 + 时域 + 组合 BI + 零 MV 填充）、AMVP（`ff_hevc_luma_mv_mvp_mode` 含 `mp_mx`/`mp_mx_lt`/`dist_scale`）；prediction_unit 的 MC 编排（PF_L0/L1/BI 分派 + 加权分支）；inter 去块 bS 推导（`ff_hevc_deblocking_boundary_strengths` + `boundary_strength`）。三条真实 x265 流（gray I+6P、moving I+6P、I/P/B bframes=2）共 21 帧逐帧 YUV MD5 与 FFmpeg 9.0.2 默认解码逐字节一致；slice header 补 POC 全推导/short-term RPS/long-term RPS/collocated/完整 pred_weight_table/alignment_bit_equal_to_one。范围：8/10/12-bit 4:2:0，支持单/多 slice、WPP（单线程语义：entry point 解析、行边界 terminate+reinit、第二 CTB 后状态同步、跨 slice bS/SAO 边界恢复）与 tiles（PPS 尺寸派生、CTB raster↔tile-scan、tile 边界 CABAC 重置、tile 感知邻居/预测可用性、跨 tile bS/SAO 边界；kvazaar 2×2 uniform tiles 已验证，tiles+WPP 暂拒绝）；closed GOP、无 dependent slice/reference-list modification/PCM/scaling list/RDPCM（均有具体错误串的负例）。transform skip 支持 transform-skip significance 上下文（x265 `tskip=1` 真实流中 4×4 亮度/色度 skip 块逐字节一致）。Main10 加权 I/P/B、Main12 32×32 TU、320×240 四 slice、单 slice WPP、2×2 tiles 与 transform skip 流共 27 帧，滤波后与 `-skip_loop_filter all` 未滤波两条路径均与 FFmpeg 9.0.2 逐字节一致；去块 `beta`/`tc` 按 `bit_depth - 8` 缩放并按 CTB 取 slice 偏移。4:4:4（hshift = vshift = 0）复用同一驱动：全尺寸色度平面、逐 PU 色度模式、4×4 色度 TU、色度 QP 截断 51、4:4:4 色度 MC/去块/SAO，8-bit I/P、8-bit 加权 B、10-bit 加权 B 三流共 17 帧同样逐字节一致。4:2:2（hshift = 1, vshift = 0）：半宽全高色度平面、每亮度 TU 两个纵向堆叠色度块、`tab_mode_idx` 重映射、色度 QP 截断 51 与通用 `mv >> (2+shift)` 色度 MC，8-bit I/P、8-bit 加权 B、10-bit 加权 B 三流共 17 帧同样逐字节一致。scaling list 在反量化时按 `sl[log2-2][3*inter+c_idx]` 取系数矩阵、`sl_dc` 取 DC 缩放（transform skip 且 log2>2 时禁用），kvazaar 默认矩阵流（I/P/B+WPP）3 帧逐字节一致 |

测试总数 517/517（`moon test --target wasm`）。仍未完成的重点：HEVC 的 dependent slice、
tiles+WPP 组合、PCM 与 RDPCM，VP9/AV1 的像素解码（VP9 压缩头已解析）、
Opus SILK/CELT 解码、HLS/DASH 的网络/分片 IO、MJPEG 无损/12-bit/算术编码。

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
| Matroska Cluster/Block | 合成手推：lacing 四模式（无/Xiph/fixed/EBML）各有正例，三个反例（Xiph 长度链越界、fixed 不整除、EBML 负尺寸与尺寸超量）；SimpleBlock 单包（stream_index/data/keyframe/pts）、cluster timecode + 负 block 偏移（tc 1000、offset -250 → pts 750）、Xiph 双帧逐帧数据与 lace duration 分摊、BlockGroup（ReferenceBlock → 非关键帧、BlockDuration 覆盖默认）、双 Cluster 按 pos 排序、未知轨道号 → `EINVAL`；**真实文件**：docker `linuxserver/ffmpeg:9.0.2` 生成 32x32/5fps 的 webm（VP8+Opus）与 mkv（H.264+AAC），按 `pos + size + 4` 精确截到第二个包（正好落在第三个 Block 头前，顺带验证尾部截断容忍），前两个包的 stream_index/pos/size/pts/keyframe 与 ffprobe 逐值一致——负 pts 来自 `av_rescale_q(codec_delay, …)` 的舍入（Opus 6.5ms → 7 tick = -7、AAC 23.22ms → -23） |
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
| bitstream | Exp-Golomb 码表直接取 **ITU-T H.264 / ISO 14496-10 表 9-1**（`1/010/011/00100/...` → 0..7，se 映射 0/1/-1/2/-2/3）；位读取的 MSB-first/`show_bits`/overread 语义按 `get_bits.h` 手推，含零窗口 `get_ue_golomb_long` 的 C 特有跳过行为 |
| h2645 NAL | 合成字节手推：00 00 03 去除、遇到 00 00 01 截断、尾零/停位 `get_bit_length`、Annex B 双 NAL（含前导垃圾）、无起始码报错、长度前缀双 NAL 与尺寸越界、HEVC NAL 头层号/时域号（含 temporal_id_plus1=0 拒绝）。**真实数据**：`avcC`/`hvcC` 的 VPS/SPS/PPS NAL 经长度前缀路径解析（见下） |
| h264_ps | **真实文件**：docker `linuxserver/ffmpeg:9.0.2` 生成的 `h264.mp4`（libx264，64x48，High@3.0），avcC 44 字节内嵌；期望值逐项取自 FFmpeg 自己的 `trace_headers` 输出（profile 100/level 30/chroma 1/8-bit/POC 2/ref 3/4x3 MB/VUI SAR 1:1 + timing 1/10 + bitstream restriction 0/3；PPS CABAC、ref 3/1、QP 23/26、chroma offsets -2、transform_8x8、second offset -2）；同一参数集另走 Annex B extradata 路径复核；截断 SPS 与缺失 SPS 的 PPS 均被拒绝 |
| hevc_ps | **真实文件**：docker 生成的 `hevc.mp4`（libx265 Main@3.0，64x48）与 `hevc10.mp4`（Main10），hvcC 内嵌（仅保留 VPS/SPS/PPS 数组，头字节/NAL 原样）；期望值取自 `trace_headers`（Main profile 1/level 30/64x48/chroma 1/8-bit、POC LSB 8、CTB 32x32、VUI 1:1 + timing 1/5；PPS sign hiding/ref 1/1/init QP 0/CU-QP-delta/weighted；10 位档 profile 2、`yuv420p10le`、qp_bd_offset 12）；另走 Annex B extradata 路径。short-term RPS 用规范位串手推（-1/+1、used 位图），`compute_poc2` 覆盖回绕与 BLA 类型复位 |
| AAC/MP3 帧头与裸流 | `audio_headers`：真实 ADTS 首帧 `FF F1 50 40 1B 1F FC`（LC/44100/mono/216 字节，与 ffprobe packet size 一致）与 LAME 首帧 `FF FB 90 C0`（MPEG-1 L3/128k/44100/mono/417 字节）；MPEG-2 LSF（22050/64k/208 字节）与自由格式（bitrate_index 0）手推；ADTS 同步/采样率/帧长错误与头部检查负例。`rawaudio`：内嵌 docker 生成的完整 1517 字节 ADTS AAC 与 2506 字节 MP3（LAME 128k CBR + Xing/Info），逐帧 `pos`/`size` 与 `ffprobe -show_packets` 全部一致（AAC 10 帧 216/210/127/…；MP3 剔除 417 字节 Info 帧后 417,418×4，首包 pos 417）；另加 44 字节合成 ID3v2 前缀验证整体偏移 +44，以及截断输入拒绝 |
| 码流参数桥 | H.264/HEVC 用上述真实 avcC/hvcC 断言 `CodecParameters`（64x48、profile/level、chroma/位深、pix_fmt、VUI 帧率 5/1 或 10/2、SAR 1:1）；AAC 用 `12 08 56 e5 00`（LC/44100/mono/1024）；**真实容器**：MP4 `aac.mp4`（`esds` → AudioSpecificConfig）与 Matroska x264 文件（avcC → Baseline@1.0、128x96）分别经 `mp4_track_codec_parameters` / `mkv_track_codec_parameters` 解出同一结构 |

| H.264 I 帧解码 | **真实码流 + 逐帧 YUV MD5**：docker `linuxserver/ffmpeg:9.0.2` 生成 6 组 Baseline 两帧 IDR 码流（`testsrc2`，`keyint=1:bframes=0:cabac=0:8x8dct=0:slices=1`），参考输出取 **`-skip_loop_filter all`** 的 rawvideo yuv420p，逐帧 MD5 即期望值：64x48 qp26（I_4x4 为主）、64x48 `gradients`（I_16x16 luma DC）、64x48 纯色（I_16x16 DC/VERT、无残差）、**88x56 裁剪流**（6x4 宏块裁到 88x56）、80x64 qp40（长零游程）、64x48 qp10（稠密残差）。另有「重建结果不是平坦预测」护栏（luma 动态范围 > 32），以及 5 条**负例**断言具体错误串：P slice→`PATCHWELCOME`、多 slice→`multi-slice pictures are not supported`、CABAC→（已支持，见下两行）、4:2:2→`only 4:2:0 is supported`、10-bit→`only 8-bit decoding is supported` |
| H.264 去块滤波 | **同一批 6 条码流的第二套期望值**：参考输出改取 FFmpeg **默认解码**（不传 `-skip_loop_filter`）的 rawvideo yuv420p，逐帧 YUV MD5 必须与默认入口 `h264_decode_annexb_i_frames` 一致；原先的 6 组向量继续以 `..._ex(data, true)` 钉住未滤波重建。两组向量合起来同时钉死「重建是否正确」与「滤波是否只改了该改的样本」——本切片最初就是靠这组对照发现「逐宏块滤波破坏了帧内预测输入」的。这 6 条里 `gradients` 的第 2 帧与纯色流两帧的滤波前后 MD5 相同（边沿低于 `alpha`/`beta`，滤波器合法地不改任何样本） |
| H.264 CABAC 核心 | FFmpeg 自带 `libavcodec/tests/cabac.c`：测试内的参考编码器（`put_cabac`/`put_cabac_bypass`/`put_cabac_terminate`）与 `av_lfg_get`（`libavutil/lfg.c`，MD5 播种、种子 1）一并移植，10240 bypass + 10240 上下文比特逐比特还原；`get_cabac_terminate` 必须非零。注意 `init_cabac_encoder` 的 `pb.bit_left++` 会吞掉首个比特，打包时要丢掉流的第一位 |
| H.264 CABAC 宏块层 | linuxserver/ffmpeg:9.0.2 + libx264 生成 5 条 CABAC IDR 码流（`testsrc2` 16x16 / 32x16 / 48x16、平坦 32x32 / 16x48，`8x8dct=0`），期望值为同文件 `-f framemd5` 的逐帧 MD5；多行复杂内容仍失步，见 §3「CABAC 的已知偏差」 |
| H.264 P 帧 / DPB | 真实码流：`keyint=10` 的 Baseline I+P+P 流经 `h264_decode_annexb_frames` 解出 3 帧（滑窗 DPB 出参考）；单元测试覆盖 MC 的整数/半像素/四分像素与 chroma 1/8 双线性（含负位移的边界复制）、`mid_pred` 与 A/B/C 邻块回退、P_SKIP 零捷径。**合成码流**：全 `I_PCM` IDR（非平坦图案 = `I_PCM` 路径首个向量）+ CABAC P 帧（`P_L0_16x16`、整数 MV、零残差），P 帧逐像素等于参考帧平移（左/上边界按 `ff_emulated_edge_mc` 复制）；编码器镜像复刻解码端每个 CABAC 上下文推导 |
| AAC ICS/TNS/IMDCT | 合成位串手推：`ics_info` 各窗口序列与 `max_sfb`、section 数据（含 escape 长度）、TNS 逐字段、EIGHT_SHORT 分组展开、codebook 0 静音帧、TNS 一阶 AR 滤波、predictor 数据拒绝；全部 11 本码书的元组/符号组合与位消费；MDCT/加窗的 Princen-Bradley 互补性、核行逐点、`vector_fmul_window` 2×len、KBD 窗和窗口转换结构；长短窗综合对照 `ff_tx_mdct_naive_inv` 的符号与 PCM 缩放；**真实码流**：libfdk_aac 46 帧正弦淡入流的 47,104 样本对照 FFmpeg PCM，最大误差 1 LSB、精确匹配率 ≥99.9%（见 §3） |
| AAC 真实窗口切换 / pulse | `generate_aac_transient_vectors.py` 调用 Docker FFmpeg 9.0.2：native/FDK 分别编码同一 48 kHz 突发信号，覆盖四种序列、两种 window shape、短窗分组、PNS/TNS，27 帧共 27,648 样本最大误差 1 LSB；六帧合成 pulse 码流由 FFmpeg 解码取得参考 PCM，6,144 样本最大误差 1 LSB；另有 pulse 语法、多采样率边界及短窗/截断/越界负例 |
| AAC CPE / M/S / 强度立体声 | `generate_aac_stereo_vectors.py` 用 FFmpeg native/FDK 生成真实双声道码流，另构造独立左右窗口与 M/S 0/1/2、强度 14/15、噪声频带排除的合成码流；四组共 35 帧、71,680 个声道样本对照 FFmpeg 9.0.2 PCM 最大误差 1 LSB、精确匹配率 ≥99.9%；另有掩码分组/消费位数和非法模式/频带/声道状态/尾元素回归 |
| AAC 多元素 / PCE / LFE | `generate_aac_layout_vectors.py` 生成真实 indexed 5.1、PCE 5.1/7.1 与非连续标签双 SCE、每帧乱序 PCE 5.1；五组 23 帧共 135,168 个声道样本对照 FFmpeg PCM 最大误差 1 LSB、精确匹配率 ≥99.9%；默认 1..7 声道表对照、PCE 逐位截断/重复/布局边界、DSE 对齐和扩展长度、失败帧窗历史/布局/PNS 状态回归 |
| AAC ASC / MP4 到 PCM | `generate_aac_asc_vectors.py` 生成 stereo 与 ASC-only PCE 5.1/7.1 的真实 MP4；ffprobe 的 ASC/逐包位置与大小为元数据期望，FFmpeg `-flags2 +skip_manual` PCM 为音频期望；MP4 demux→参数桥接→ASC 初始化→raw packet 解码共 65,536 样本最大差分 1 LSB、精确匹配率 ≥99.9%，另含 ASC 延迟/对齐/截断/不支持配置及畸形 PCE 的回退行为 |
| AAC-LC 960/120 | `generate_aac_960_vectors.py` 合成 mono/CPE 的四窗口序列、正弦/KBD、首尾频带；FFmpeg 9.0.2 解码 PCM 为期望，28,800 样本最大误差 1 LSB、精确匹配率 ≥99.9%；真实编码器样本尚待验证 |
| AAC-LC CCE | `generate_aac_coupling_vectors.py` 合成 7 组 ADTS（1024）及 2 组 MP4（960）；FFmpeg 9.0.2 PCM 为期望；三耦合位置、四增益尺度、有符号差分、CPE 选择、TNS/分组短窗、16 增益列表和多源乱序，共 151,040 样本最大差分 1 LSB；另含截断/错误目标/PCE 标签清理与历史回滚 |
| AAC 高度 / indexed 11..14 | `generate_aac_height_vectors.py` 的 9 组合成 ADTS/MP4；ffprobe 元数据与 FFmpeg PCM 为期望；三层 PCE、22.2 特殊元素顺序、普通 CPE 掩码排序、24 声道、四窗序列、保留高度回退、960 ASC-only PCE，共 473,088 样本最大差分 1 LSB，另有截断与历史回滚回归 |
| H.264 `avcC` 入口 | 真实 `avcc_baseline.mp4`（5042 字节，baseline/CAVLC）：`av_mov_open` → `track.extradata`（`avcC`）+ 按 `stco`/`stsz` 切样本 → `h264_decode_avc_frames`，逐帧 YUV MD5 对齐 FFmpeg 默认解码 |
| H.264 SEI | **真实码流 + `trace_headers` 逐字段**：docker `linuxserver/ffmpeg:9.0.2` 生成三条码流——① x264 `nal-hrd=cbr:vbv-maxrate=200:vbv-bufsize=200`（buffering period ×2 + picture timing ×2 + x264 user-data，VUI HRD 全字段，BP/PT 的值延迟对 SPS 解析）；② 同一流经 `h264_metadata` bsf 注入 display orientation（旋转 16384 + 双翻转）；③ 手工构造的 11 类合成消息流（恢复点、green metadata、film grain、frame packing、alternative transfer、ambient viewing、mastering display、content light、双 unregistered、cancel 的 display orientation、带时钟时间戳的 picture timing——后者靠 SPS VUI 的 `pic_struct_present_flag` 原位翻转启用，不移动任何后续字段）。期望值逐字段转录自 `ffmpeg -c copy -bsf:v trace_headers` 输出（green metadata 无 CBS dumper，期望值取 trace 的 payload 字节）；负例按 C 的错误路径断言具体错误串（<16 字节 unregistered、size 越界、`recovery_frame_cnt ≥ 1<<16`、film grain `num_model_values>6`、缺失 SPS 的 buffering period 返回 `AVERROR_PS_NOT_FOUND` 非致命）。码流以 base64 内嵌于 `h264_sei_realdata_wbtest.mbt` |
| MPEG 音频 Layer I/II 解码 | **真实码流 + PCM MD5（Layer II）**：docker 生成 4 条 `mp2`（stereo 44.1k/192k、mono 44.1k/64k、joint stereo 32k/64k、MPEG-2 LSF stereo 24k/64k），期望值为 FFmpeg 定点解码器 `-c:a mp2 -f s16le` 的 MD5（`818bac4a…` / `5c6c8e47…` / `941cb133…` / `f9bf9037…`），覆盖分配表 1/0/3/4 与 3/5/9 步组量化。**Layer I 无编码器**，改用按规范手工拼帧、由 FFmpeg 解码同一段码流取得期望值（`cb2824e3…` mono 32k、`a0ed4a92…` joint stereo 44.1k bound=4），输入是手工的、期望值仍是参考实现的 |
| MP3 Layer III 解码 | **真实码流 + PCM MD5**：docker 生成 stereo（440Hz L / 660Hz R，44100Hz，128kbps，无 Xing 帧）、mono（5 帧共 5760 样本）与 MPEG-2 LSF（22050Hz，64kbps）三条码流，期望值为 FFmpeg **定点**解码器 `-c:a mp3 -f s16le` 的 MD5（`c6f9d146…` / `7c931d35…` / `97d37691…`）；浮点解码器给出不同 MD5，故这组向量专门钉住定点路径 |

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

**解码器向量（第三批）**：H.264 的 6 条 Baseline 码流与 MP3 的 3 条码流同样由该镜像生成，
期望值分别是 `-skip_loop_filter all` 的**逐帧 YUV MD5** 与定点解码器的 **PCM MD5**；
码流与期望值以 base64 内嵌于 `libavcodec/h264_decode_realdata_wbtest.mbt` 和
`libavcodec/mp3_decode_realdata_wbtest.mbt`（文件头附完整生成命令）。这一批暴露并修复了
两个 bug：SPS 裁剪被**缩放两次**（88x56 解出 80 宽），以及多 slice 码流被「当整帧解」
后才报错（现改为解码前预扫 `first_mb_in_slice`）。

**音频 Layer I/II 向量（第五批）**：Layer II 用 FFmpeg 原生 `mp2` 编码器现场生成 4 条码流；
**Layer I 没有任何编码器可用**，因此两条 Layer I 向量是按规范手工拼出的帧（3 帧/流以便
mp2 demuxer 探测），期望值取 FFmpeg 解码同一段码流的定点 PCM MD5——手工的只是输入。
这一批暴露的坑记在 §7 的 31–33。

**去块滤波向量（第四批）**：同 6 条码流再取一套 FFmpeg **默认解码**（启用环路滤波）的
逐帧 YUV MD5，作为 `h264_decode_annexb_i_frames` 的期望值。这一批暴露并修复了三个 bug：
`slice_alpha_c0_offset`/`slice_beta_offset` 漏乘 2（C 存的是 `div2 * 2`）；内部边误走强
核而非 bS=3 弱核；以及最关键的**滤波时序**——逐宏块滤波会让后续宏块的帧内预测读到已滤波
像素，必须「整帧重建后再按光栅序滤波」才能同时满足预测读未滤波、滤波读已滤波。

复现命令：

```bash
cd moonbit
moon check     # 0 error / 0 warning（仅 CABAC 调试区一个已知弃用告警）
moon test      # 315/316 passed（唯一失败为 CABAC P 帧调试区已知用例）
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

1. 其他容器：**Matroska/WebM 已到可出包阶段**（EBML 层 + EBML 头 + Segment/Info/SeekHead/
   resync + Tracks + **Cluster/Block 与三种 lacing** 完成，`av_matroska_open` 已产出带
   pos/size/pts/keyframe 的 `MkvPacket` 队列，多 Cluster 走查并对尾部截断容忍；余下 Cues
   索引与 `skip_to_keyframe` 懒解复用、BlockAdditions 侧数据、header-strip 解压、RM 音频 /
   WebVTT 特化）。**WAV/RIFF、MPEG-TS（188/192/204、PAT/PMT/PES/PCR）、HLS（主/媒体
   播放列表与分片元数据）、DASH（MPD + SegmentTemplate/Timeline/BaseURL）已在
   2026-10-21 切片中落地**；余 AVI、HLS/DASH 的实际网络/分片 IO 与 AES-128。
2. **裸 AAC/MP3 流**：`rawaudio.mbt` 完成 ADTS 与 MPEG 音频分帧（ID3v2/v1、Xing/Info/VBRI、
   `ffprobe` 对齐的 pos/size），后续可接公共 `avformat_open_input` 风格入口
3. **码流参数桥**：`codec_tags.mbt`/`codec_parameters.mbt` 让 MP4/MKV 共用
   `CodecParameters`（H.264/H.265/AAC/MP3 的 profile/level/位深/帧率/SAR/帧长）
4. `avio.c` 的 URL/协议层与 `avio_open`（文件/网络 IO，属平台边界，或留 FFI）

### 阶段 5 —— libavcodec（**已开始**：IDCT + Huffman + 码流层 + H.264 I 帧+去块 / MPEG 音频三层）
只做纯 C 的编解码器（Huffman/VLC 表、LZO、部分无损编解码）；其向量化内核
（`libavcodec/x86`，共 113 个 `*.asm`）按新边界原则用 `@v128` 重写，而非保留 C/FFI。

已完成 SIMPLE-C IDCT（`int16` 8/10/12 bit）、`huffman.c` 的树/码长构建、`get_bits`/Golomb
位流层、H.264/HEVC NAL 拆分与参数集、AAC ADTS 与 MPEG 音频帧头、**H.264 SEI**
（消息框架 + buffering period/picture timing/恢复点/green metadata + h2645 公共消息集），
以及 **H.264 Baseline
I 帧重建 + 环路去块滤波**（slice header + CAVLC + 4x4 IDCT + 帧内预测 + `h264_loopfilter`，
逐帧 YUV MD5 同时对齐 FFmpeg 默认解码与 `-skip_loop_filter all` 两套输出）与
**MPEG 音频 Layer I/II/III 定点解码**（逐样本 PCM MD5 对齐 FFmpeg 定点解码器）——见第 3 节。仍是「部分解码器 + 完整解析层」的能力边界。后续：

1. H.264 SEI 的 ITU-T T.35（`itut35.c`/`atsc_a53.c`）与 AVFrame side-data 层；
   HEVC SEI 入口（`hevc/sei.c`）
2. `vlc.c` 的 `ff_vlc_init_from_lengths` 表构建（当前只产出它需要的 `lens`/`xlat`）
3. ~~接 MP4 的 avcC + 长度前缀入口 → CABAC（`h264_cabac.c`）→ P 帧与 DPB/参考帧管理~~
   **已完成**（`h264_inter/mvpred/mc/dpb`；B/SP/SI slice 与 CABAC 多行收敛仍开放）
4. HEVC slice segment header + CABAC + 帧内预测/变换，先 I 帧（本轮未动；VP9/AV1/Opus
   目前只到帧头/包级解析，像素解码仍未开始）
5. AAC 原始帧解析：ICS/TNS/MDCT/**频谱 Huffman**/scalefactor/pulse/PNS/gain-control
   语法与**全四窗口序列 + KBD 窗**已完成（`aac_spectrum.mbt`/`aac_tables.mbt`，
   真实长窗、短窗/窗口切换及 pulse 合成码流 PCM 对照 FFmpeg 最大误差 1 LSB）；
   CPE 双声道与共享/独立窗口、M/S/强度立体声已完成；余下更多采样率/工具组合
   向量、SBR/PS、height+CCE 命名布局与 CCE/960/高度真实编码器样本；默认 1..7/11..14、多元素
   SCE/CPE/LFE、带内与 ASC PCE 已完成，960 综合已有合成参考验证
6. `jrevdct.c`（`FF_IDCT_INT`）、`faanidct.c`、`xvididct.c` 与 `idct248/84/48/44` 部分变换；
   `lzo.c` 与其余编解码器（无损优先）

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
19. **H.264 4x4 IDCT 的第二遍索引**：行变换读 `b/k*4` 系列，列变换若沿用第一遍的
   `b+8`/`b+4`/`b+12` 就会拿到错位的系数（正确是 `b+2`/`b+1`/`b+3`）。这是最初
   「整帧像素全错、但 MD5 差距均匀」的主因。
20. **4x4 top-right 可用性不能按几何位置判断**：块是**按 8x8 z-order** 重建的，同一行
   的 `bx`/`by` 与视觉位置并不对应。最终规则（`h264_decode.mbt`）：
   `by == 0` → 上方 MB 存在且（`bx < 3` 或右方 MB 存在）；`by > 0` →
   `bx == 0 || bx == 2 || (bx == 1 && by % 2 == 0)`，与 FFmpeg 的
   `topright_samples_available` 掩码 `0xEEEA`/`0x26EA` 一致。
21. **16x16 / chroma 8x8 平面预测的梯度 off-by-one**：C 的 `8+k`/`8-k` 应为 `7+k`/`7-k`、
   `4+k`/`4-k` 应为 `3+k`/`3-k`；写错不只是梯度偏移，底边会直接越界 panic。
22. **SPS 裁剪被缩放两次**：`h264_ps.mbt` 已按 `step_x`/`step_y` 把裁剪偏移折成**亮度
   像素**（`h264_ps.c:510-513`），`h264_slice.c` 的 `init_dimensions` 直接
   `width - (cr+cl)`；解码端再乘一次 2 就把 88x56 解成 80 宽。**只有非宏块对齐的分辨率
   能暴露**——64x48 之类整数倍分辨率的向量永远测不出来。
23. **多 slice 码流会「当整帧解」**：宏块循环按 `mb_count` 读完第一个 slice 后越界读零，
   于是静默产出垃圾像素（常在 `chroma prediction mode out of range` 之类的下游错误上
   才炸）。正确做法是解码前**预扫每个 slice NAL 的 `first_mb_in_slice`**，非 0 即拒绝。
24. **MoonBit 表达式优先级的两个坑（解码切片踩到）**：`cbp & 15 != 0` 会按
   `cbp & (15 != 0)` 解析，必须写 `(cbp & 15) != 0`；`Array::make(n, inner)` 会让 n 个
   元素**别名同一个内部数组**，逐宏块信息必须用循环逐个新建。
25. **调试解码器最省时的办法**：按宏块（或每行）分别算 luma MD5，与参考 YUV 的同区域
   比对，能一次把问题定位到单个宏块/单条预测路径，而不是对着整帧 MD5 猜。
26. **去块滤波的时序比算法本身更容易错**：FFmpeg 是「解完一行 → 滤这一行」，并且帧内
   预测读的是**滤波前**备份的上边界（`sl->top_borders`）。等价实现是「先整帧重建，再按
   宏块光栅序整帧滤波」。写成「每解一个宏块就立刻滤波」时，同一行里后面的宏块会拿已滤波
   的左邻做预测，重建值就变了——症状是整帧只差一两百个样本、且集中在 MB 边界附近。
27. **内部边是 bS=3（弱核），不是 bS=4**：`h264_loopfilter.c` 的 `filter_mb_dir` 只把
   **宏块边**的 bS 抬到 4，内部边保持 3 并用 `intra=0` 走弱滤波；误走强核后，凡是
   `|p0-q0| < (alpha>>2)+2` 的平坦边都会多改一排像素。
28. **`slice_alpha_c0_offset` 存的是 `div2 * 2`**：语法元素是 `slice_alpha_c0_offset_div2`
   （se(v)，-6..6），C 在 `h264_slice.c:1909` 乘 2 后存进 `sl->slice_alpha_c0_offset`。
   漏乘 2 时 `a`/`b` 偏移只有应有值的一半，`alpha`/`beta` 会偏小（漏滤），且只在这两个
   值非 0 的码流上暴露。
29. **`get_chroma_qp` 的偏移来自 PPS 而不是 0**：本次向量集的 PPS 里
   `chroma_qp_index_offset = -2`、`pic_init_qp_minus26 = -3`（手工解析 PPS 确认）。写参考
   模型时若默认偏移为 0，`alpha_table`/`beta_table` 下标会差 2，表现为 V 平面个别样本
   相差 2。审计这类常量时直接从码流解 PPS 比猜默认值可靠。
30. **验证脚本里最难发现的一类错**：拿「未滤波 YUV + 逐宏块滤波」当参考模型时，它**恰好**
   与 FFmpeg 默认解码逐字节一致——因为 FFmpeg 的预测也是读滤波前像素。这类模型能验出
   滤波核/强度推导的错，但验不出时序错，所以时序必须另有对照（整帧 MD5 + 逐 MB 区域哈希）。
31. **`fn f(self : T, ...)` 会被当成方法定义**：MoonBit 把首参名为 `self` 的 `fn` 解释成
   `T::f`（还给一条 `deprecated_syntax` 警告），于是从别的文件、甚至同文件的调用点都
   报 `unbound identifier`。**自由函数的第一参数不要叫 `self`**（本项目改用 `dec`/`ctx`）。
32. **Layer I 没有参考编码器**：FFmpeg 只有 `mp2`/`mp3` 编码器，Layer I 只能手工拼帧。
   做法是按规范写 header + 4 位分配 + 6 位 scalefactor + `n+1` 位尾数，**把期望值交给
   FFmpeg 解码**（`-c:a mp2`）；手工的必须是输入，绝不能是期望值。另外 mp2 demuxer 要求
   至少两个连续帧才能探测，所以一条向量至少拼 3 帧。
33. **Layer II 分配表是「行首字节 = 位宽，其余 = 该分配值对应的量化索引」**：遍历时
   `j += 1 << bit_alloc_bits`，`qindex = alloc_table[j + b]`；把 `j` 当成「子带序号」或
   漏掉 `1 << bits` 会从第二个子带起整体错位（症状：只有最低几个子带对，后面全错）。

---

## 8. 许可证

本目录是对 FFmpeg 的衍生移植，遵循 FFmpeg 的 **LGPL-2.1-or-later**（`moon.mod` 中已声明）。
各源文件头部保留了原始 C 文件的版权与作者信息（如 Michael Niedermayer、Ryan Martell 等）。

许可证正文随仓库提供两份，均为 GNU 官方文本（与 FFmpeg 仓库根的同名文件逐字节一致）：

| 文件 | 内容 | MD5 |
|---|---|---|
| [COPYING.LGPLv2.1](COPYING.LGPLv2.1) | GNU Lesser General Public License, Version 2.1, February 1999（502 行） | `eed22b3456132611e3d4aa7a7ec64dac` |
| [COPYING.LGPLv3](COPYING.LGPLv3) | GNU Lesser General Public License, Version 3, 29 June 2007（165 行） | `e6a600fd5e1d9cbde2d983680233ad02` |

之所以两份都放：FFmpeg 是 **LGPL-2.1-or-later**，被许可人可以按 v2.1 或**任一更晚版本**
（含 v3）使用。注意 LGPLv3 **不是完整条款**——它是在 GNU GPLv3 之上追加许可的短文本，
引用前须一并提供 GPLv3 正文（FFmpeg 发行包根目录的 `COPYING.GPLv3`，本项目未内置）。
本项目自身的选则是 **v2.1**（见 `moon.mod` 的 `license` 字段），保留 v3 文本只为让下游
可以按 v3 条款再分发。
