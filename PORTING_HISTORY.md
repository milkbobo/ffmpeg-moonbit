# FFmpeg → MoonBit 移植过程记录

本文保留历次实现说明、对拍向量和排错记录。文中的“当前”“剩余”及测试数量对应各段记录时点；项目的现状请以 [README.md](README.md) 为准。

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
│   ├── display.mbt           # av_display_rotation_set / av_display_matrix_flip
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
│   ├── segment_io.mbt        # HLS/DASH 初始化/媒体/密钥回调与范围读取、缓存和重试
│   ├── segment_io_wbtest.mbt # 真实 TS/fMP4 分片读取→解复用→H.264 的逐帧 MD5
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
    ├── av1_tiles.mbt         # AV1 tile group 连续覆盖与压缩 payload 边界提取
    ├── opus_rc.mbt           # Opus SILK/CELT 共享熵解码（448 条 C 状态对拍）
    ├── opus_head.mbt         # OpusHead 四类通道映射与完整多流包拆分
    ├── opus_pvq.mbt          # CELT PVQ 脉冲向量、频带归一化/spread/collapse mask
    ├── opus_pvq_tables.mbt   # 从原 C 提取的 1272 项 PVQ U 表（.mbtx --check）
    ├── opus_celt_alloc.mbt   # CELT 动态比特分配、跳带、立体声与 fine/PVQ 预算
    ├── opus_celt_energy.mbt  # CELT setup：静音/后滤波参数、粗细能量与 TF 切换
    ├── opus_celt_tables.mbt  # 17 张原 C CELT 整数表（.mbtx --check）
    ├── opus_celt_bands.mbt   # 递归 PVQ 分带、theta、折叠/噪声与立体声
    ├── opus_celt_math.mbt    # Hadamard/Haar、theta 定点核与归一化
    ├── opus_celt_spectrum.mbt# CELT 整帧归一化频谱与 collapse masks
    ├── opus_celt_coefficients.mbt # 最终能量、anti-collapse、缩放与连续帧历史
    ├── opus_celt_synthesis.mbt # 半逆 MDCT、120 样本 overlap/add、后滤波与去加重
    ├── opus_celt_decode.mbt  # 有状态 CELT-only 帧 → 48 kHz planar Float PCM
    ├── opus_celt_windows.mbt # 两张原 C 合成窗（.mbtx --check）
    ├── vp9_packet_decode.mbt # superframe、隐藏关键帧与八槽 show-existing 输出
    ├── vp9_decode.mbt        # VP9 帧解码入口、概率更新、tile 编排与 YUV 输出
    ├── vp9_block.mbt         # 分区/模式/系数解码，MERGE/SPLAT 非零上下文
    ├── vp9_recon.mbt         # 帧内参考样本准备与 TU 重建
    ├── vp9_dsp.mbt           # 帧内预测、DCT/ADST/WHT 与去块内核
    ├── vp9_lpf.mbt           # 边掩码、滤波强度与逐超块去块驱动
    ├── vp9_tables.mbt        # 从 vp9data.c 提取的 33 张表（脚本 --check）
    ├── vp9_kf_wbtest.mbt     # 五流 12 帧 YUV MD5 与具体错误串负例
    ├── vp9_kf_realdata_wbtest.mbt # 内嵌 libvpx-vp9 码流与 FFmpeg 参考 MD5
    ├── vp9_dsp_wbtest.mbt    # DC 缩放/清系数、HOR_UP 坐标与饱和裁剪回归
    ├── vp9_decode_test.mbt   # 公共解码入口黑盒测试
    ├── h2645_parse.mbt       # H.264/HEVC NAL 拆分：去防竞争字节、Annex B/长度前缀
    ├── h2645_vui.mbt         # H.264/HEVC 公共 VUI（SAR/色彩/chroma location）
    ├── h264_ps.mbt           # H.264 SPS/PPS/VUI/缩放矩阵 + avcC extradata
    ├── h264_slice.mbt        # I/P/B/SP/SI header、L0/L1 重排与显式权重
    ├── h264_picture_slice.mbt # 多 slice 共享画面、独立熵状态与完整性检查
    ├── h264_slice_neighbors.mbt # slice/受限帧内预测的邻居可用性
    ├── h264_cavlc8.mbt       # CAVLC 8×8 的四路交错残差与熵计数
    ├── h264_pcm.mbt          # CABAC I_PCM escape、原始样本和算术重启
    ├── h264_poc.mbt          # POC 0/1/2 与 frame_num 回绕
    ├── h264_reference_marking.mbt # MMCO 1–6、长参考与滑窗标记
    ├── h264_cavlc.mbt        # CAVLC 残差解码 + 去量化/chroma QP 派生表（含 8x8 dequant8 表）
    ├── h264_idct.mbt         # H.264 4x4/8x8 IDCT + luma/chroma DC Hadamard（8-bit）
    ├── h264_pred.mbt         # 帧内预测 4x4/16x16/chroma 8x8 + 可用性改判
    ├── h264_pred8x8l.mbt     # High profile 8x8 帧内预测（pred8x8l 九模式 + DC 边缘变体）
    ├── h264_decode.mbt       # Baseline I 帧重建（CAVLC→dequant→IDCT→预测→写回）+ Annex B 入口
    ├── h264_deblock.mbt      # 环路去块滤波（h264dsp 核 + h264_loopfilter 边界强度推导）
    ├── h264_sei.mbt          # H.264 SEI：消息框架 + BP/PT/恢复点/green + 公共消息集
    ├── itut35.mbt           # ITU-T T.35 注册用户数据：provider 分发 + A53/AFD/LCEVC/HDR Vivid/AOM 颗粒
    ├── h264_side_data.mbt   # SEI→帧 side-data 导出与访问单元边界语义（stereo3d/矩阵/mastering 等）
    ├── h264_mc.mbt           # 运动补偿：luma 6 抽头 qpel + chroma 1/8 双线性 + 边界复制
    ├── h264_mvpred.mbt       # MV 预测：A/B/C 邻块、mid_pred、P_SKIP 捷径
    ├── h264_inter.mbt        # P 宏块层（CABAC+CAVLC）：skip/type/ref/mvd + inter 残差
    ├── h264_gap.mbt          # frame_num 间隙合成、前参考像素复制/灰图与参考缓冲身份
    ├── h264_gap_wbtest.mbt   # 间隙/回绕/灰图/PAFF/复位与失败重试状态回归
    ├── h264_gap_realdata_wbtest.mbt # 19 流/86 帧，默认滤波与跳过滤波 FFmpeg MD5
    ├── h264_dpb.mbt          # 滑窗 DPB、PAFF 互补场配对与共享平面/运动历史（H264Decoder）
    ├── h264_ref_list.mbt     # 帧/场默认短长参考表、场交错、重排与缺失参考替换
    ├── h264_b_mb.mbt         # B 宏块层：类型/子分区/L0L1 ref+mvd/直接模式
    ├── h264_b_mc.mbt         # B 双向 MC：显式/隐式加权与 (a+b+1)>>1 平均
    ├── h264_b_refs.mbt       # B 默认 L0/L1 列表（短/长参考排序）
    ├── h264_b_direct.mbt     # 帧/场空间/时间 direct、异场 colocated 行偏移与缩放
    ├── h264_colocated.mbt    # 帧↔场 colocated 抽取、参考身份映射与场奇偶选择
    ├── h264_paff_realdata_wbtest.mbt # JM 19.0 PAFF/帧场混编 24 流/276 帧，滤波与未滤波 MD5
    ├── h264_paff_wbtest.mbt   # 场配对/POC、slice 隔离、B 表场交换、MMCO 场掩码/超限
    ├── h264_depth.mbt        # 8–14 bit 的样本截断与 QP 上限
    ├── h264_output.mbt       # 显示重排：POC 排序、epoch、reorder_depth drain
    ├── h264_chroma_realdata_wbtest.mbt # 4:2:2/4:4:4 真实码流逐帧 MD5
    ├── h264_mono_realdata_wbtest.mbt # 4:0:0 真实码流逐帧 MD5（含 10-bit/B 帧）
    ├── h264_mbaff_realdata_wbtest.mbt # MBAFF 隔行帧图真实码流逐帧 MD5（I/P/B、混合 field/frame 宏块对、多参考/B-pyramid、CQM、4:2:0/4:2:2/4:4:4、8/10-bit、多 slice）
    ├── h264_bypass_realdata_wbtest.mbt # High 4:4:4 lossless transform bypass 真实码流逐帧 MD5
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
    ├── hevc_picture.mbt      # HEVC 图像缓冲（单色/4:2:0/4:2:2/4:4:4 的 y/cb/cr 平面与 clone）
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
    ├── flac_decode.mbt       # FLAC 解码器（frame/subframe、Rice、fixed/LPC、声道去相关）
    ├── mpa_layer12_tables.mbt# Layer I/II 分配表/量化表/定点缩放表
    ├── idct.mbt              # SIMPLE-C IDCT（int16 8/10/12 bit）+ idctdsp 像素/扫描表辅助
    ├── dctref.mbt            # 双精度参考 DCT/IDCT（dctref.c），供 IDCT 测试作期望值
    ├── huffman.mbt           # Huffman 树/码长构建（huffman.c）+ 规范化码编解码
    ├── mpeg4audio.mbt        # AudioSpecificConfig 解析（mpeg4audio.c，esds/AAC 用）
    ├── h264_slice_wbtest.mbt # slice header 逐字段对照 trace_headers
    ├── h264_slice_realdata_wbtest.mbt # slice header 真实码流 base64 素材
    ├── h264_decode_wbtest.mbt# H.264 真实码流逐帧 YUV MD5 + 未支持输入负例
    ├── h264_decode_realdata_wbtest.mbt # H.264 码流 base64 素材与期望 MD5
    ├── h264_weightp_wbtest.mbt # H.264 加权 P + 4 参考去块真实码流逐帧 MD5
    ├── h264_weightp_realdata_wbtest.mbt # 加权 P/多参考码流 base64 素材与期望 MD5
    ├── h264_p8x8_deblock_realdata_wbtest.mbt # CABAC P_8x8 多参考去块真实码流逐帧 MD5
    ├── h264_8x8dct_realdata_wbtest.mbt # High profile 8x8 变换（inter/intra）真实码流逐帧 MD5
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
    ├── hevc_monochrome_wbtest.mbt # 8/10-bit 单色真实码流逐帧 MD5 + 独立 intra
    ├── hevc_monochrome_realdata_wbtest.mbt # 单色码流 base64 素材与期望 MD5
    ├── audio_headers_wbtest.mbt # 真实 ADTS/MP3 帧头 + LSF/自由格式
    ├── flac_decode_wbtest.mbt # FLAC 真实文件 PCM MD5（constant/verbatim/fixed/LPC、四种立体声模式）
    ├── flac_decode_realdata_wbtest.mbt # FLAC 文件 base64 素材与期望 PCM MD5
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
（`moonbit/**/*.mbt`，不含 `_build` 生成文件）共 **149453 行**（libavutil 6483 行 +
libavformat 的 aviobuf 流式 AVIO 层、MP4 解复用、Matroska EBML/Segment/Tracks/Cluster、
裸 AAC/MP3 分帧、容器码流参数桥与 HLS/DASH 分片回调 33319 行 + libavcodec 的位流/H.264/HEVC/AAC/MP3 码流头、
IDCT/Huffman/MPEG-4 音频切片、**H.264 I 帧重建 + 环路去块滤波（CAVLC 全通 / CABAC 部分
向量 / MP4 `avcC` 长度前缀入口）**、**H.264 P 帧解码与滑窗 DPB（运动补偿/MV 预测/inter
宏块层，含 CABAC P 路径的合成码流端到端向量、显式加权预测、参考列表重排与多参考去块）**、
**H.264 High profile 8x8 变换（`transform_8x8_mode`：CABAC cat5 残差/`dequant8_coeff`/`pred8x8l`
帧内预测含 DC 边缘改判/去块跳过 8x8 内部奇边，真实 x264 码流逐帧 YUV MD5 与 ffmpeg 逐字节一致）**、**H.264 MBAFF 隔行帧图（I/P/B、CAVLC/CABAC、8/10-bit、4:0:0/4:2:0/4:2:2/4:4:4，真实 x264 码流滤波/未滤波逐字节一致）**、**H.264 High 4:4:4 lossless transform bypass（qpprime_y_zero_transform_bypass_flag / pred_add 累加语义）**、**H.264 SEI 解析**、**AAC 频谱解码
（Huffman 码书 1..11 + scalefactor + PNS/TNS + IMDCT/加窗全管线，真实 libfdk_aac
码流逐帧解码）**、**FLAC 无损解码（frame/subframe、Rice 分区、fixed/LPC、wasted bits、四种立体声去相关，9 个真实文件 PCM 逐字节一致）**、**MPEG 音频 Layer I/II/III 定点解码**、**HEVC I 片整帧解码与完整
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
I/P/B+WPP 码流逐字节一致）**、**HEVC 单色（chroma_format_idc=0：仅亮度平面，跳过色度帧内模式/
残差/MC/去块/SAO，8/10-bit I/P/B 真实码流逐字节一致）**
及 **VP9 profile-0 关键帧解码（五流 12 帧 YUV MD5 一致）**、**Opus 共享熵解码、
CELT 连续帧频域/PCM 解码与 OpusHead 多流映射**，109651 行，含测试）——约占整体 **9.4%**。

### 已完成模块（阶段 0 + 阶段 1 开端 + 阶段 4/5 码流层）

| 模块 | 对应 C 源码 | 移植内容 | 测试 |
|---|---|---|---|
| [mathematics.mbt](libavutil/mathematics.mbt) | `libavutil/mathematics.c`、`intmath.h` | `av_gcd`(Stein 二进制 GCD)、`av_rescale_rnd`(128 位拆分乘法 + 位长除法)、`av_rescale`/`av_rescale_q`/`av_rescale_q_rnd`、`av_log2`、`ff_ctzll`、`av_compare_ts`、`av_compare_mod` | ✅ |
| [display.mbt](libavutil/display.mbt) | `libavutil/display.c` | `av_display_rotation_set`（16.16 定点、C 截断语义）、`av_display_matrix_flip` | ✅ |
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
| [h264_slice.mbt](libavcodec/h264_slice.mbt) | `libavcodec/h264_slice.c`、`h264_parse.c` | I/P/B/SP/SI slice header：POC 0/1/2、MMCO、L0/L1 参考计数覆盖/重排、显式亮度/色度权重、B direct 标志、SP/SI QS、CABAC 初值与去块字段；B 像素重建仍拒绝 | ✅ |
| [h264_cavlc.mbt](libavcodec/h264_cavlc.mbt) | `libavcodec/h264_cavlc.c`(`decode_residual`)、`h264_ps.c`(`ff_h264_dequant4_coeff_init`/`ff_h264_chroma_qp`) | CAVLC 残差：coeff_token/total_zeros/run_before/level_prefix-suffix 三级码表（C 的 VLC 子系统改为同表构建的二叉 trie，逐位等价）、PPS 派生的去量化表与 chroma QP 表；系数按 C 的转置布局存放 | ✅ |
| [h264_idct.mbt](libavcodec/h264_idct.mbt) | `libavcodec/h264idct_template.c` | `ff_h264_idct_add`、`ff_h264_idct8_add`（High profile 8x8DCT，含 `idct8_add4` 的 nnz==1 DC 捷径）、`ff_h264_idct_dc_add`、`ff_h264_luma_dc_dequant_idct`、`ff_h264_chroma_dc_dequant_idct`（8-bit）；`SUINT` 用 32 位 `UInt` 复刻回绕语义，`dctcoef` 写回按 `int16` 截断 | ✅ |
| [h264_pred8x8l.mbt](libavcodec/h264_pred8x8l.mbt) | `libavcodec/h264pred_template.c`(`pred8x8l_*`) | High profile 8x8 帧内预测：参考行/列 3 抽头滤波（含 topleft/topright 可用性），九种 4x4 风格模式 + `ff_h264_check_intra4x4_pred_mode` 的 DC 边缘改判（LEFT_DC/TOP_DC/DC_128） | ✅ |
| [h264_pred.mbt](libavcodec/h264_pred.mbt) | `libavcodec/h264pred_template.c`、`h264_parse.c`(`ff_h264_check_intra4x4_pred_mode`/`ff_h264_check_intra_pred_mode`) | 4x4 九模式（含 DC 边缘变体）、16x16 四模式、chroma 8x8 四模式的 8-bit 帧内预测，以及「参考样本可用性 → 模式改判」逻辑；邻居直接读重建平面（FFmpeg 读每 MB 的边界缓冲，样本值相同） | ✅ |
| [h264_decode.mbt](libavcodec/h264_decode.mbt) | `h264_cavlc.c`(`ff_h264_decode_mb_cavlc`)、`h264_mb_template.c`(`hl_decode_mb`)、`h264_slice.c`(`init_dimensions`) | **H.264 Baseline I 帧重建**：CAVLC 宏块解析 → dequant → 4x4 IDCT / luma & chroma DC Hadamard → 帧内预测 → 写回平面；`I_4x4`/`I_16x16`/`I_PCM` 三条宏块路径、8x8 z-order 块序与 top-right 可用性掩码、SPS 裁剪与 `H264Frame::yuv420p` 输出；入口 `h264_decode_annexb_i_frames`（Annex B，就地解析 SPS/PPS），默认出厂即走环路滤波，`..._ex(data, true)` 跳过 | ✅ |
| [h264_deblock.mbt](libavcodec/h264_deblock.mbt) | `h264dsp_template.c`(`h264_loop_filter_luma{,_intra}`、`h264_loop_filter_chroma{,_intra}`)、`h264_loopfilter.c`(`filter_mb_dir`/`ff_h264_filter_mb_fast`) | **环路去块滤波**：弱/强（intra）luma 与 chroma 内核（`xstep`/`ystep` 参数化后一套代码同时覆盖横向/纵向边）；bS 按 8.7.2.3 逐 4x4：intra 宏块边=4/内部边=3，非零系数=2，ref 或 MV（|dx|/|dy|≥4）差异=1；参考索引经 `ref2frm` 的 POC 身份比较（重排列表中的重复图片视为同一参考）；色度边沿用 luma 的 bS[4]，每段 2 样本各取 `tc0_table[..][bS[i]]+1`；`alpha_table`/`beta_table`/`tc0_table` 由 C 源批量提取；左右/上下 QP 取均值、chroma QP 按 `chroma_qp_index_offset` 派生、slice 偏移按 C 的 `div2 * 2` 缩放 | ✅ |
| [h264_sei.mbt](libavcodec/h264_sei.mbt) | `libavcodec/h264_sei.c`、`h2645_sei.c`、`sei.h` | **H.264 SEI 解析**：消息框架（type/size 的 0xFF 扩展、双零字节截尾）；buffering period（缺失 SPS 返回 `AVERROR_PS_NOT_FOUND` 非致命）、picture timing（payload 暂存 + `ff_h264_sei_process_picture_timing` 对 SPS 延迟解析，含时钟时间戳全语法）、recovery point、green metadata；公共消息集（h2645_sei.c）：user data unregistered（含 `x264 - core N` 版本嗅探）、display orientation、frame packing arrangement（H.264 分支）、film grain characteristics、alternative transfer、ambient viewing environment、mastering display（`present=2` 语义）、content light。ITU-T T.35（type 4）经 `itut35.mbt` 解析，帧 side-data 导出在 `h264_side_data.mbt`（均见下两行）；HEVC 侧入口未接 | ✅ |
| [itut35.mbt](libavcodec/itut35.mbt) | `libavcodec/itut35.c`、`atsc_a53.c`、`dynamic_hdr_vivid.c`、`aom_film_grain.c` | **ITU-T T.35 注册用户数据**：`ff_itut_t35_parse_buffer` 全 provider 分发（US 的 ATSC GA94/DTG1、AOM、Samsung、Dolby、SMPTE；UK V-Nova；CN HDR Vivid，含 0xFF 国家码扩展字节与截断 EINVAL）；载荷解析：A53 CC（`ff_parse_a53_cc` 双场合并、尾 marker 字节边界）、AFD（`&0xf`）、LCEVC 原样保存、HDR Vivid 全字段（T/UWA 005.1-2022）、AOM AFGS1 颗粒集（含 scaling 预测/参考集、CICP 合法性、错误清空）。Dolby 与 C 一致忽略（H.264 路径无 DOVIContext）；HDR10+/SMPTE 2094-40 App5 保留原始载荷（结构级解析未做） | ✅ |
| [h264_side_data.mbt](libavcodec/h264_side_data.mbt) | `h2645_sei.c`(`ff_h2645_sei_to_frame`/`h2645_sei_to_side_data`)、`libavutil/display.c`、`h264dec.c`(`decode_nal_units` 的 SEI/边界)、`h264_slice.c`(`h264_export_frame_props`/`h264_frame_start`) | **帧 side-data 与 NAL 边界语义**：`H264FrameSideData` 标签列表（stereo3d、displaymatrix、A53/AFD/LCEVC、SEI 未注册、ambient、mastering display（g,b,r→r,g,b 重排与合法性检查）、content light、H.274 颗粒、AOM 颗粒集）；`H264Decoder.decode_nals` 按 C 语义在 AU 入口 `ff_h264_sei_uninit`（待配场跳过）、首 slice 前 SEI 归属本图、slice 后 SEI 只更新状态；导出时机=帧图或场对第二场；场对 A53 合并/AFD 取后场/LCEVC 先场挂载；`sei_recovery_frame_cnt` 取首场值。HDR10+/2094-App5/HDR Vivid 与 C 一致留在 SEI 上下文不导出 | ✅ |
| [audio_headers.mbt](libavcodec/audio_headers.mbt) | `libavcodec/adts_header.c`、`adts_parser.c`、`mpegaudiodecheader.c`、`mpegaudiotabs.h` | `ff_adts_header_parse{,_buf}`（AAC-LC/Main/SSR/LTP、采样率/声道/帧长/码率）、`ff_mpa_check_header`、`avpriv_mpegaudio_decode_header`（MPEG1/2/2.5、Layer I/II/III、LSF、自由格式）、`ff_mpa_decode_header`；码率/采样率全表 | ✅ |
| [mp3_tables.mbt](libavcodec/mp3_tables.mbt) | `libavcodec/mpegaudiodec_common.c`、`mpegaudiodsp_data.c` | `ff_band_size_long/short`、`ff_slen_table`、`ff_lsf_nsf_table`、`ff_mpa_pretab`、`ff_mpa_huff_data` 与 Layer III 的 15 张 Huffman 码长/符号表，全部由 C 源批量提取（不手工转录） | ✅ |
| [mp3_dsp.mbt](libavcodec/mp3_dsp.mbt) | `mpegaudiodsp_template.c`(fixed, `USE_FLOATS=0`)、`mpegaudiodsp.c`、`dct32_template.c` | 定点 IMDCT/多相合成滤波：`ff_imdct36` 与 36 点/12 点窗表生成、`ff_dct32`、合成窗与频率反转；`INTFLOAT`=`int` → MoonBit 32 位回绕 `Int`，`mulh`/`mull` 走 64 位中间积 | ✅ |
| [mp3_decode.mbt](libavcodec/mp3_decode.mbt) | `mpegaudiodec_template.c`(fixed) | **MPEG-1/2/2.5 Layer III 定点解码**：side info、scalefactor（slen 表）、Huffman 解码、反量化（`ff_mpa_pretab` 预增益）、立体声处理（MS/intensity）、短块重排、bit reservoir、输出 S16 交织 PCM；三层共用的合成滤波 `mpa_synthesize`；入口 `decode_mp3_stream` / `Mp3Decoder`（`decode_frame` 按帧头 `layer` 分派） | ✅ |
| [flac_decode.mbt](libavcodec/flac_decode.mbt) | `libavcodec/flacdec.c`、`flac.c`(`ff_flac_decode_frame_header`)、`flacdsp.c`/`flacdsp_template.c` | **FLAC 无损解码**：`fLaC` 元数据块（STREAMINFO）、frame header（UTF-8 帧号/块大小/采样率/声道模式）、constant/verbatim/fixed(order 0-4)/LPC(order 1-32) 子帧、Rice 分区与 escape 编码、wasted bits、lpc16（C 的有符号 int 累加+算术右移）/lpc32 预测、independent/left-side/right-side/mid-side 去相关，输出 S16/S32 交织 PCM；支持 8/16/20/24-bit（夹具覆盖 16/24-bit）、1-8 声道、44.1/48 kHz，9 个真实文件 PCM MD5 与 ffmpeg 逐字节一致 | ✅ |
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
| [h264_inter.mbt](libavcodec/h264_inter.mbt) | `h264_cabac.c` 的 P 分支(`decode_cabac_mb_skip`/`decode_cabac_mb_type`/`decode_cabac_p_mb_sub_type`/`decode_cabac_mb_ref`/`decode_cabac_mb_mvd`)、`h264_cavlc.c` 的 P 分支、`h264_mb.c`(`mc_part_std`/`mc_part_weighted`) | **P 宏块层**：skip flag、P_L0_16x16/16x8/8x16/8x8 四种划分与子划分、ref_idx（`ref_count>1` 才解码，且每个分区的 ref 立即写回邻域表供后续分区的 CABAC 上下文使用）、mvd 读取与写回、inter CBP 与残差路径、分块运动补偿编排（CAVLC/CABAC 共用）、显式加权预测（luma/chroma 权重与偏移，`(v*w + off<<denom + round) >> denom`，含 skip 与所有划分） | ✅ |
| [h264_dpb.mbt](libavcodec/h264_dpb.mbt)、[h264_ref_list.mbt](libavcodec/h264_ref_list.mbt)、[h264_reference_marking.mbt](libavcodec/h264_reference_marking.mbt) | `h264dec.c`、`h264_parse.c`、`h264_refs.c` | I/P/B 的 POC 0/1/2、frame_num 回绕、MMCO 1–6/IDR 长参考；帧/场短长参考表与重排、缺失参考替换、B 同表场交换；PAFF 互补场配对、共享平面/运动历史、逐场参考掩码与 DPB 超限回收；frame_num 间隙参考合成、灰图替换与 invalid_gap 过期；Annex B/avcC 多 slice 入口，画面完整后提交参考与 POC | ✅ |
| [aac_ics.mbt](libavcodec/aac_ics.mbt) | `libavcodec/aac/aacdec.c`(`decode_ics_info`/`decode_band_types`/`ff_aac_decode_tns`/`decode_pulses`、gain-control) | **AAC ICS 语法层**：窗口序列/`max_sfb`/分组、section escape、scalefactor 差分、TNS 压缩系数、1..4 个 pulse 的起始带/offset/amp、gain-control；短窗 pulse 与截断语法拒绝 | ✅ |
| [aac_mdct.mbt](libavcodec/aac_mdct.mbt) | `aacdec_dsp_template.c`(`imdct_and_windowing`)、`aacdec.c` 的 raw_data_block/SCE/CPE/LFE 框架、`kbdwin.c` | **AAC IMDCT/加窗 + 多元素帧框架**：直接法 MDCT/IMDCT（O(N²)，适配 FFmpeg 符号与浮点缩放）、四种窗口序列、正弦/KBD 窗；循环解码 SCE/CPE/LFE/FIL/PCE/DSE，按布局输出 PCM，以类型/标签/子声道绑定历史；校验 END 和元素完整性后才提交布局与窗状态，错误时恢复 PNS 随机状态 | ✅ |
| [aac_stereo.mbt](libavcodec/aac_stereo.mbt) | `aacdec.c`(`decode_cpe`/`decode_mid_side_stereo`)、`aacdec_dsp_template.c`(`apply_mid_side_stereo`/`apply_intensity_stereo`) | **AAC-LC CPE**：共享或独立 ICS、M/S 模式 0/1/2 与逐组掩码、噪声带排除、强度立体声 14/15 的极性与 M/S 反转；左右频谱/pulse→M/S→强度立体声→各声道 TNS/IMDCT，左右历史窗口独立 | ✅ |
| [aac_coupling.mbt](libavcodec/aac_coupling.mbt) | `aacdec_proc_template.c`(`decode_cce`)、`aacdec.c`(`apply_channel_coupling`)、`aacdec_float_coupling.h` | AAC-LC CCE：8 个目标/16 组增益、四增益尺度、公共或逐带有符号差分增益、CPE 四种声道选择、TNS 前/后频域耦合与 IMDCT 后时域耦合；独立标签历史、PCE/ASC 声明及成功布局更新时清理移除的 CCE；支持 1024/960 帧 | ✅ |
| [aac_layout.mbt](libavcodec/aac_layout.mbt) | `aacdec.c`(`decode_pce`/`count_paired_channels`/`assign_channels`/`sniff_channel_order`/`skip_data_stream_element`)、`aacdec_tab.c` 的默认布局/声道表 | 默认配置 1..7/11..14、PCE base/top/bottom 三层前/侧/后/LFE 标签映射，元素掩码排序与 22.2 特殊重排、mixdown/associated-data/comment 语法、DSE 对齐和扩展长度；PCE 耦合标签列表及独立声明；拒绝歧义布局、重复标签、越界与无法命名的 height+CCE 组合；配置 7 采用 FFmpeg 默认非 strict 的 7.1 解释 | ✅ |
| [aac_config.mbt](libavcodec/aac_config.mbt) | `aacdec.c`(`decode_audio_specific_config_gb`/`decode_ga_specific_config`) | AAC-LC 专用 ASC 解析：GA 标志、14 位 coreCoderDelay、ASC-only PCE、extensionFlag3 与 consumed bits；`new_aac_decoder_from_asc` 自动建立布局与声道容量；MP4 esds / CodecParameters 解析 LC PCE 声道数；支持 1024/128 与 960/120 帧长，其他 profile/SBR/PS 初始化显式拒绝 | ✅ |
| [aac_spectrum.mbt](libavcodec/aac_spectrum.mbt) | `aacdec_proc_template.c`(`decode_spectrum_and_dequant` 浮点路径)、`aacdec.c`(`decode_scalefactors`/`decode_pulses`)、`aacdec_dsp_template.c`(`dequant_scalefactors`/`apply_tns`、Levinson 展开) | **AAC 频谱解码**：scalefactor 差分、码书 1..11 Huffman + 打包索引/符号位、book 11 escape、PNS 单位能量噪声、intensity 零填充、采样率相关 pulse 位置校验与重建、TNS Levinson + 就地 AR 滤波 | ✅ |
| [aac_tables.mbt](libavcodec/aac_tables.mbt) | `aactab.c` 全部解码表 + `ff_aac_pow2sf_tab`/`ff_cbrt_tab` 生成算法 | 批量提取表：scalefactor VLC（121 项）、码书 1..11 的 codes/bits、5 张 `codebook_vector_*_idx` 打包索引表、3 张 vals 表、`pow2sf` 428 项 float32、`pow43` 8192 项、swb 偏移表（1024/128 与 960/120 全采样率）与 `tns_max_bands`；提取脚本 `scripts/extract_aac_tables.py`（与 C 源逐值 diff 校验） | ✅ |

**当前状态**：`moon check` 0 error / 0 warning，`moon test` **699/699 全绿**。各格式的能力边界见本节末尾的迁移矩阵。

### CABAC 的验证范围

CABAC 算术核心（`cabac.mbt`）**已用 FFmpeg 自己的 `libavcodec/tests/cabac.c` 向量验证**：把该测试里的参考编码器一并移植（`cabac_wbtest.mbt`），10240 个 bypass 比特 + 10240 个上下文比特全部逐比特还原，终止位也命中。`av_lfg_get`（`libavutil/lfg.c`，MD5 播种）在测试里复刻，向量完全可复现。

宏块层已对上 FFmpeg 输出的组合包括

* 单宏块（`testsrc2` 16x16）、一行 2 / 3 / 4 个宏块（左邻上下文，`testsrc2` 稠密残差逐像素等于 FFmpeg `-skip_loop_filter all`）；
* 平坦 I16x16 内容的 2 行 / 3 行（上邻上下文 + luma DC 的 coded-block 标志）；
* 3x3 宏块（48x48 稠密）；
* **单行 I + 全 skip CABAC P 帧经滑窗 DPB 端到端**（`libavformat/h264_cabac_p_realdata_wbtest.mbt`：MP4 `avcC` + 长度前缀样本入口与 Annex B 入口各一条，逐帧 YUV MD5 等于 FFmpeg 默认解码）。

**2026-10-22 复核**：旧文档所列的 16×48 / 32×48 / 64×48 稠密多行 I 流和静态编码型 P 流已通过。新增 `h264_cabac_regression_wbtest.mbt`：上述三条 I 流、64×16 I+3P（关闭 fast-pskip）和 96×64 运动 I+5P，共 **13 帧**，默认滤波与 `-skip_loop_filter all` 两套 YUV MD5 均完全一致。16×48 的 2403 条、64×48 的 8233 条 CABAC 上下文/状态/解码位与禁用汇编的原 C 参考逐条一致。该证据覆盖这些流；B/SP/SI、场编码、高位深与多 slice 等边界仍按入口限制处理。

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
  CAVLC、宏块重建、环路去块滤波）见下一小节；**SEI 已完成**（`h264_sei.mbt` + `itut35.mbt` 的 T.35 与
  `h264_side_data.mbt` 的帧 side-data/NAL 边界语义）；**P/B 帧与滑窗 DPB 已完成**（`h264_inter/mvpred/mc/dpb` + `h264_b_*`：
  B 全子分区、空间/时间 direct、显式/隐式双向加权与显示重排；SP/SI 重建仍拒绝；
  单色 4:0:0 已支持，按 FFmpeg 的 yuv420p 中性色度输出逐字节对齐；
  MBAFF 帧图（I/P/B、CAVLC/CABAC、混合 field/frame 宏块对、多参考/B-pyramid、
  空间/时间 direct、CQM、8/10-bit 4:2:0/4:2:2/4:4:4、多 slice）已逐字节对齐，
  High 4:4:4 lossless transform bypass（4:0:0/4:2:0/4:2:2/4:4:4、8/10-bit、CABAC/CAVLC、含 MBAFF）
  也已逐字节对齐；PAFF 场图与帧场交叉引用已验证（I/P/B、CAVLC/CABAC、空间/时间 direct，
  8/9/10/12/14-bit、4:0:0/4:2:0/4:2:2/4:4:4、POC 0/1/2、bottom-first、
  多 slice 与禁止跨 slice 去块），具体组合见下方 PAFF 验收矩阵；
  CABAC 的多行与运动 I/P 验证范围见 §3。
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
- 该切片当时的边界是 Progressive 8-bit 4:2:0 单 slice；后续切片已解除大部分限制：
  CABAC、P/B slice、多 slice、8x8DCT、8–14 bit 与 4:2:2/4:4:4 均已支持
  （见 2026-10-22/23 增量）。**仍显式拒绝**（返回 `Err`，不 panic）：场/MBAFF、
  separate colour plane、单色、SP/SI 重建；参考帧间隙已补齐，见下方验收。
- **代码已写但无真实向量**：`I_PCM` 宏块路径（x264 的 baseline profile 不接受
  `-qp 0` lossless，且 lossless 走变换旁路而非 I_PCM，需手工构造码流才能覆盖；该路径在
  滤波里按 C 的 `qscale_table = 0` 处理）。
- **未接**：SEI 已在后续切片完成（`h264_sei.mbt`）；`chroma_qp_diff`
  （`second_chroma_qp_index_offset` 与第一个不等）时的非 fast 路径
  ——当前按 fast 路径用 plane 0 的偏移派生出 Cb/Cr 各自的 QP。

**H.264 High profile 8x8 变换**（`h264_cavlc.mbt` 的 dequant8 表 + `h264_cabac_mb.mbt` 的 cat5 残差 + `h264_idct.mbt` 的 `idct8_add` + `h264_pred8x8l.mbt` + 去块/重建接线）：

- **已做**：PPS `transform_8x8_mode` 下的完整 8x8DCT 路径——CABAC 残差 category 5（luma cbp 位隐含 cbf、`significant_coeff_flag_offset_8x8` 上下文与压缩的 `last_coeff_flag_offset_8x8` 表）、`dequant8_coeff`（注意 C 的 8x8 移位是 `quant_div6[q]`，**没有** 4x4 表的 +2）、`ff_h264_idct8_add`/`idct8_dc_add`（`idct8_add4` 按 `nnz==1 && DC!=0` 走 DC 捷径）、`get_dct8x8_allowed`（P_8x8 四个子块都是 8x8 且 `direct_8x8_inference` 才允许）、`neighbor_transform_size` 上下文（399+左/上 8x8DCT 邻居数）、`pred8x8l_*` 九模式（参考行/列 3 抽头滤波 + topleft/topright 可用性）与 `ff_h264_check_intra4x4_pred_mode` 的 DC 边缘改判（LEFT_DC/TOP_DC/DC_128 对应 `pred8x8l_left_dc`/`_top_dc`/`_128_dc`）、去块滤波跳过 8x8DCT 宏块的内部奇数 luma 边。CAVLC 路径仍显式拒绝 8x8DCT（与 FFmpeg 的 CAVLC 8x8 支持面一致取舍）。
- **验证**：4 条真实 libx264 High profile 码流（inter 8x8DCT 单参考/双参考、噪声内容 + 去块、CRF36 all-intra 含 intra 8x8DCT 宏块），滤波与 `-skip_loop_filter all` 两种模式逐帧 YUV MD5 与 ffmpeg 一致；测试 **535/535**。
- **踩过的坑**：`h264_zigzag_scan8x8` 是 `ff_zigzag_direct` 的**转置**（`h264_slice.c` 的 `TRANSPOSE`），系数块本身按转置布局存储；`idct8_add` 第二遍按行内列偏移 0/4/2/6 读系数（不是第一遍的 +8 步长）；`pred8x8l` 的 DDR/VR/HD 用**滤波后的** top/topleft 样本，且 `ff_h264_check_intra4x4_pred_mode` 可能把模式改判到 9/10/11（`pred8x8l[9+3]` 表）。

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

**FLAC 无损解码**（`flac_decode.mbt`）：

- **已做**：`fLaC` + 元数据块（STREAMINFO 的采样率/声道/位深/总样本数）、frame
  header（同步码、块大小/采样率码表、UTF-8 帧号、声道模式、位深）、constant/
  verbatim/fixed(order 0-4)/LPC(order 1-32) 子帧、Rice 分区残差（含 escape 原始
  样本）、wasted bits、`lpc16`/`lpc32` 预测（`lpc16` 按 C 的 **有符号 int** 累加与
  算术右移，这是与 `lpc32` 的 int64 路径唯一不同处）、independent/left-side/
  right-side/mid-side 去相关。
- **验证**：9 条真实 FLAC（mono/stereo LPC、24-bit、静音 constant、低压缩 fixed、
  `lpc_type=none` verbatim、left/right/mid-side 强制模式），解码后 S16/S32 交织 PCM
  的 MD5 与 `ffmpeg -i x.flac -f s16le/s32le` 逐字节一致；测试 **535/535**。
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
  其余未做（H.264 的 B 帧与 4:2:2/4:4:4 已在 2026-10-22/23 增量完成）：SP/SI 重建、HEVC 的 tiles+WPP 组合与
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
| HEVC 整帧解码（I 片） | [hevc_intra_decode.mbt](libavcodec/hevc_intra_decode.mbt)、[hevc_cabac_syntax.mbt](libavcodec/hevc_cabac_syntax.mbt)、[hevc_residual.mbt](libavcodec/hevc_residual.mbt)、[hevc_intra_ref.mbt](libavcodec/hevc_intra_ref.mbt)、[hevc_scan.mbt](libavcodec/hevc_scan.mbt)、[hevc_picture.mbt](libavcodec/hevc_picture.mbt)、[hevc_deblock.mbt](libavcodec/hevc_deblock.mbt)、[hevc_sao.mbt](libavcodec/hevc_sao.mbt) | 打通 I 片主链路与完整环路滤波：CTU/CU 四叉树、split/part_mode、帧内 MPM（含 CTB 边界规则）、变换树与 cbf、cu_qp_delta/qP 预测、残差语法（sign hiding）、反量化、IDCT/DST、参考样本可用性/z-scan/3-tap 与 strong 平滑、4:2:0 重建、TU 边界 bS=2 的去块（亮度 weak/strong、色度）、SAO（merge、band/edge offset、图片边界恢复）。真实 x265 流 32×32、64×48 四 CTU（默认与未滤波）、64×48 SAO+去块（默认解码）、64×64 强平滑、80×64 部分 CTU 的 yuv420p MD5 均与 ffmpeg 逐字节一致；长度前缀 NAL 输入一致；另有 8×8 真实块 IDCT 对 C DSP 的逐值回归。范围：8/10/12-bit 单色/4:2:0/4:2:2/4:4:4 单 I 片（Main10 IDR 已逐字节验证），支持 SPS/PPS scaling list（默认矩阵与显式数据），无 PCM/transform skip/tiles/WPP；`ff_hevc_decode_intra_frame_unfiltered` 返回滤波前像素 |
| HEVC P/B 帧间预测 | [hevc_refs.mbt](libavcodec/hevc_refs.mbt)、[hevc_mc.mbt](libavcodec/hevc_mc.mbt)、[hevc_inter.mbt](libavcodec/hevc_inter.mbt)、[hevc_inter_decode.mbt](libavcodec/hevc_inter_decode.mbt) | 在 I 片链路上补齐 P/B：MvField/DPB 槽位池、RPS 候选列表与 `ff_hevc_slice_rpl` L0/L1 拼接、`mv_scale`/`check_mvset` 时域 MV 缩放；运动补偿全套（luma 8-tap qpel / chroma 4-tap epel 的 uni/bi 与加权变体、`ff_emulated_edge_mc` 语义的边界复制）；inter 语法（skip/merge/merge_idx/inter_pred_idc/ref_idx/mvd_coding/mvp_lx/part_mode 全模式含 AMP）；merge 候选推导（空间 A1/B1/B0/A0/B2 + 时域 + 组合 BI + 零 MV 填充）、AMVP（`ff_hevc_luma_mv_mvp_mode` 含 `mp_mx`/`mp_mx_lt`/`dist_scale`）；prediction_unit 的 MC 编排（PF_L0/L1/BI 分派 + 加权分支）；inter 去块 bS 推导（`ff_hevc_deblocking_boundary_strengths` + `boundary_strength`）。三条真实 x265 流（gray I+6P、moving I+6P、I/P/B bframes=2）共 21 帧逐帧 YUV MD5 与 FFmpeg 9.0.2 默认解码逐字节一致；slice header 补 POC 全推导/short-term RPS/long-term RPS/collocated/完整 pred_weight_table/alignment_bit_equal_to_one。范围：8/10/12-bit 4:2:0，支持单/多 slice、WPP（单线程语义：entry point 解析、行边界 terminate+reinit、第二 CTB 后状态同步、跨 slice bS/SAO 边界恢复）与 tiles（PPS 尺寸派生、CTB raster↔tile-scan、tile 边界 CABAC 重置、tile 感知邻居/预测可用性、跨 tile bS/SAO 边界；kvazaar 2×2 uniform tiles 已验证，tiles+WPP 暂拒绝）；closed GOP、无 dependent slice/reference-list modification/PCM/scaling list/RDPCM（均有具体错误串的负例）。transform skip 支持 transform-skip significance 上下文（x265 `tskip=1` 真实流中 4×4 亮度/色度 skip 块逐字节一致）。Main10 加权 I/P/B、Main12 32×32 TU、320×240 四 slice、单 slice WPP、2×2 tiles 与 transform skip 流共 27 帧，滤波后与 `-skip_loop_filter all` 未滤波两条路径均与 FFmpeg 9.0.2 逐字节一致；去块 `beta`/`tc` 按 `bit_depth - 8` 缩放并按 CTB 取 slice 偏移。4:4:4（hshift = vshift = 0）复用同一驱动：全尺寸色度平面、逐 PU 色度模式、4×4 色度 TU、色度 QP 截断 51、4:4:4 色度 MC/去块/SAO，8-bit I/P、8-bit 加权 B、10-bit 加权 B 三流共 17 帧同样逐字节一致。4:2:2（hshift = 1, vshift = 0）：半宽全高色度平面、每亮度 TU 两个纵向堆叠色度块、`tab_mode_idx` 重映射、色度 QP 截断 51 与通用 `mv >> (2+shift)` 色度 MC，8-bit I/P、8-bit 加权 B、10-bit 加权 B 三流共 17 帧同样逐字节一致。单色（chroma_format_idc=0）仅分配亮度平面，跳过色度模式/cbf/MC/去块/SAO，8/10-bit I/P/B 两流共 14 帧同样逐字节一致。scaling list 在反量化时按 `sl[log2-2][3*inter+c_idx]` 取系数矩阵、`sl_dc` 取 DC 缩放（transform skip 且 log2>2 时禁用），kvazaar 默认矩阵流（I/P/B+WPP）3 帧逐字节一致 |

测试总数 627/627（`moon test --target wasm`）。仍未完成的重点：HEVC 的 dependent slice、
tiles+WPP 组合、PCM 与 RDPCM，VP9 帧间解码与 AV1 像素解码、
Opus SILK/混合模式、CELT 包级 PCM 编排与 pre-skip/gain、HLS/DASH 网络 adapter/live reload、MJPEG 无损/12-bit/算术编码。

### 2026-10-22 增量：VP9 profile-0 关键帧像素解码

入口为 `vp9_decoder_new()` → `decode_frame(payload)` → `frame_bytes()`，输入单帧 VP9
payload，输出紧密排列的 8-bit Y/Cb/Cr。支持 4:2:0 关键帧、单/多 tile、压缩头真实概率
更新、分区/帧内模式/系数上下文、4/8/16/32 DCT 与 ADST、lossless 4×4 WHT、去块滤波。
分段量化与滤波特征已接入；真实向量未单独覆盖所有 segmentation 组合。

| 验证流 | 尺寸 | 关键帧数 | 参考来源 |
|---|---|---|---|
| basic | 160×144 | 3 | docker `linuxserver/ffmpeg:9.0.2` 解码 YUV MD5 |
| small | 70×36 | 3 | 同上，非超块对齐边界 |
| qfull | 64×48 | 2 | 同上，最低量化器与密集小 TU |
| lossless | 64×48 | 2 | 同上，无损 WHT |
| tiles | 512×128 | 2 | 同上，2×2 tiles |

五流共 **12 帧逐帧 MD5 完全一致**；qfull 第 0 帧 1411 条、small 第 0 帧 1287 条
系数 STEP 与插桩 C 参考逐项一致。生成与嵌入方法保留在
`scripts/_gen_vp9_kf_vectors.py`、`scripts/_emit_vp9_kf_realdata.py`；33 张常量表由
`scripts/extract_vp9_tables.py --check` 与原 C 源核对。

本切片拒绝 inter/intra-only 与非 profile-0 输入；后续已接入隐藏帧与 show-existing 显示。不实现帧间预测、
自适应概率统计回写或其他 profile。负例断言具体错误串。调试插桩、临时调试测试与
轨迹补丁脚本已清理。

### 2026-10-22 继续迁移：解码正确性、AV1/Opus 基础与分片读取

本轮沿用纯 MoonBit 算法实现，自动化新增为 `.mbtx`。C 文件仅作为独立黄金向量生成器，
不进入运行时 FFI。新增实现及验证：

- **H.264**：修复 P_SKIP 左/上邻不可用时遗漏零运动矢量捷径的问题。
  HLS TS、HLS fMP4、DASH fMP4 三条真实链路共 12 帧全部通过 YUV MD5；
  另补齐上文五条 CABAC 流的 13 帧双路径回归，撤销旧文档中过时的多行失步结论。
- **AV1**：修复交错 tile size/payload 被读成连续长度表的问题，补全每 tile 的
  offset/size，新增 `av1_extract_tiles` 检查 group 连续覆盖、越界、对齐及 LEB128 溢出。
  真实 256×128、2×2 tile libaom 流的四个 payload 偏移/长度/MD5 与 C 参考一致。
  **这仍是 tile 输入准备，尚未实现 AV1 像素重建。**
- **VP9**：新增 `decode_packet`，支持 superframe、隐藏关键帧与八槽 show-existing；
  保留每个输出自身的尺寸和像素快照。FFmpeg 对隐藏关键帧后八次显示的 MD5 均为
  `7476553695d6397f4ab595fa8fb2b68c`，与本实现一致。inter/intra-only 仍拒绝。
- **Opus**：新增 `opus_rc.mbt`，移植 SILK/CELT 共用的 CDF/log/uniform/step/triangular/
  Laplace 熵解码、倒序 raw bits 与 tell/tell_frac；32×14 = **448 条符号和完整状态**
  与原 `opus/rc.c` 一致。包层新增 self-delimiting、frame offsets 与 consumed size，
  拒绝超长帧和 padding 导致的负长度。**尚未产出 Opus PCM。**
- **HLS/DASH**：新增 [segment_io.mbt](libavformat/segment_io.mbt)，通过 `MediaFetch`
  回调获取初始化、媒体和密钥；支持字节范围、初始化缓存、失败重试。HLS 还支持
  AES-128/显式或序号 IV、密钥轮换、GAP、discontinuity；初始化段保留声明时的密钥。
  DASH SegmentList 补齐继承、timescale/startNumber、时间递增和媒体/初始化范围。
  真实 TS/fMP4 分片经现有 demux → H.264 解码，三流各 4 帧 MD5 全部一致。

| 请求范围 | 当前可用切片 | 主要剩余项 |
|---|---|---|
| H.264 | progressive + MBAFF（含混合 field/frame 宏块对）8–14 bit 4:0:0/4:2:0/4:2:2/4:4:4 I/P/B；CAVLC/CABAC 4×4/8×8、I_PCM、多 slice/受限帧内预测、POC 0/1/2、MMCO/短长参考、空间/时间 direct、显式/隐式双向加权、显示重排、High 4:4:4 lossless transform bypass；PAFF 与 frame_num 间隙参考合成；渐进帧与 MBAFF 帧的错误补偿（多轮 MV 猜测 + 恢复区滤波） | SP/SI 重建、FMO、数据分区；场图片按上游边界报错；P 帧大缺口/高位深恢复未逐像素对齐 |
| HEVC | I/P/B，8/10/12-bit，多色度/单色，WPP/tiles/多 slice | dependent slice、tiles+WPP、PCM/RDPCM 等 |
| AV1 | OBU/序列与帧头、tile payload 提取；8-bit 4:2:0/4:2:2/4:4:4/单色 多 tile 无损关键帧像素输出 | 有损帧的环路滤波、帧间帧、10/12-bit 等 |
| VP9 | profile 0/1/2/3 关键帧与帧间帧，8/10/12-bit，4:2:0/4:2:2/4:4:0/4:4:4；隐藏/show-existing、superframe、多 tile、概率自适应 | 复合预测（B 帧）、参考缩放 |
| MJPEG | 8-bit baseline/progressive，重启标记与多采样 | 无损、12-bit、算术编码 |
| PNG | 灰度/RGB/RGBA/调色板、1–16-bit、Adam7、APNG | 更多扩展元数据/色彩管理 |
| AAC | LC，多声道/PCE、CCE、960/1024、短窗/TNS/PNS/pulse | SBR/PS、USAC 与更多真实 CCE/960 向量 |
| MP3 | Layer I/II/III 定点 PCM | 更多损坏流恢复/边界向量 |
| Opus | OpusHead 四类映射、多流包拆分、共享熵解码、CELT 连续帧完整频域及 48 kHz 单/双声道 Float PCM（IMDCT/加窗/后滤波/去加重） | SILK/混合模式、包级 PCM 编排/多流声道重映射、pre-skip/gain、声道数切换/下混、PLC |
| MP4 | 普通/碎片化、索引/seek、avcC/hvcC/av1C/vpcC、cenc | 公共统一播放入口及更多扩展 |
| MKV / WebM | EBML、轨道、Cluster/Block/lacing、Cues | 更多压缩/侧数据与流式特化 |
| TS | 188/192/204、PAT/PMT、PES、PTS/DTS/PCR | CRC、加扰、33-bit 时间回绕等 |
| HLS | 播放列表 + 回调读取 + TS/fMP4 + AES-128 | 实际 HTTP adapter、live reload/LL-HLS、SAMPLE-AES |
| DASH | MPD/template/timeline/list + 回调范围读取 + fMP4 | SegmentBase index 播放、动态刷新/时钟、DRM |
| WAV | RIFF/RIFX/RF64/BW64、PCM/扩展格式与分块 | 更多 WAV 编码器及播放桥接 |

新增黄金向量与复现方式见 `scripts/emit_*_vectors.mbtx`、
`scripts/emit_h264_cabac_regression.mbtx`、`scripts/opus_rc_reference.c`、
`scripts/av1_tiles_reference.c` 及对应 `*_realdata_wbtest.mbt` 文件头。

### 2026-10-22 继续迁移：Opus CELT PVQ 与多声道容器链路

- [opus_pvq.mbt](libavcodec/opus_pvq.mbt) 移植 `opus/pvq.c` 的 `celt_cwrsi`、
  `celt_decode_pulses`、`celt_alg_unquant`：有符号脉冲向量、平方范数、频带归一化、
  四种 spread 与 collapse mask。支持原 C 查表域、2..176 维，拒绝越界参数/索引；
  码本大小用 UInt64 求和，超过 UInt32 时拒绝，不能用有符号 Int 存储大码本。
  零脉冲向量不消费熵状态；频带归一化要求正脉冲数。
- 1,272 项 U 表由 `scripts/extract_opus_pvq_tables.mbtx` 从 `opus/tab.c` 提取，
  `--check` 可逐值核对。`scripts/opus_pvq_reference.c` 直接调用原 C 核，验证
  **2,000 个码本大小、14,181 个整数向量**；向量整体 MD5 为
  `b6bac12c1663ec747dbd52166094338e`（LE N/K/index/norm64/pulses32）。
  同一 forward/raw coder 连续解码的 **416 组频带**覆盖四种 spread、长短块和高脉冲数：
  collapse mask、range/value/total_bits/tell_frac 完全一致，Float32 系数绝对误差 ≤1e-6。
- [opus_head.mbt](libavcodec/opus_head.mbt) 移植 OpusHead 版本、pre-skip、
  有符号 Q8 增益、原输入采样率和 0/1/2/255 四种映射族；包括 Vorbis→原 C 输出顺序、
  coupled/mono 流定位、重复通道复制与静音通道。`OpusHead::parse_packet` 拆分整个多流包，
  仅末流使用普通 framing，检查各流总样本数一致，允许帧数不同、padding 与零字节 DTX。
  使用 BytesView 解析，避免对每条流复制剩余容器包。
- 真实 libopus **5.1 WebM 与无损重封装 MP4**：各 4 包、每包 640 字节，4 条逻辑流、
  2 条 coupled stream、pre-skip=312；OpusHead/dOps、6 个输出通道映射及全部 16 条逻辑包
  的 offset/size/config/stereo/frame spans 与原 `opus/parse.c` 一致。MP4 与 WebM 的
  原始 packet bytes 逐字节一致。畸形 OpusHead 不再覆盖容器中已有的采样率/声道元数据。

此 PVQ 切片本身不产出 Opus PCM；后续章节继续完成 CELT 频域编排。
C harness 仅生成黄金参考，运行时保持纯 MoonBit。
上述数值回归在默认 Wasm 目标验收；native 补测在运行测试前因本机 MSVC/Windows SDK
工具链不可用而未能构建，不能据此宣称 native 已通过。

### 2026-10-22 继续迁移：CELT 比特分配与 PVQ 前置能量状态

- [opus_celt_alloc.mbt](libavcodec/opus_celt_alloc.mbt) 移植 `ff_celt_bitalloc` 解码路径：
  spread、动态 boost、trim、anti-collapse 预留、两层二分分配、跳带、intensity/dual stereo
  标志与逐带 fine-energy/PVQ 预算。`pvq_bits`/`remaining` 的单位为 1/8 bit，不能直接当作
  脉冲数。模型/频带/静态分配/caps/TF 表从 `opus/tab.c` 提取（后续已扩为 17 张），可用
  `moon run scripts/extract_opus_celt_tables.mbtx --check` 核对。
- [opus_celt_energy.mbt](libavcodec/opus_celt_energy.mbt) 新增 `decode_celt_setup`：
  解析静音、postfilter 参数与 transient，做粗能量的时域/频域预测、TF 切换与 fine-energy
  raw bits 解码，输出 PVQ 语法起点的完整状态。支持 120/240/480/960 样本、单/双声道、
  指定频带和 42 项调用方能量历史；mono 按原 C 合并两行历史。参数错误不消费熵，
  调用方历史不原地修改；中途畸形帧错误可能消费该帧熵状态，应丢弃该 range decoder。
- `scripts/opus_celt_reference.c` 直接调用原 C 的 `celt.c`/`dec_celt.c`：
  **896 组比特分配 + 896 组 setup + 8 组标准静音 setup** 全字段一致。
  覆盖两种声道数、四种时长、七种频带区间、1..1275 字节、预消费熵和零/非零能量历史；
  包含 transient、postfilter、正负 TF、dual stereo 与跳带。逐带 caps/PVQ/fine/priority、
  range/value/total_bits/tell_frac 及 Float32 能量/postfilter 增益的位模式均精确一致。
- 上轮真实 5.1 WebM/MP4 所含 **16 个 CELT 逻辑帧**，分别以 flush 能量历史进入 setup，
  至 PVQ 前的上述状态同样与 C 精确一致；这验证真实字节输入的前置阶段，尚未完成连续帧
  音频解码。标准静音的 setup 输出也是中间能量，最终置为 -28/清频谱位于完整帧后段。

此 setup 切片的后续频域处理见下节；当前仍未输出 Opus PCM。

### 2026-10-22 继续迁移：CELT 递归频带与连续频域帧

- [opus_celt_bands.mbt](libavcodec/opus_celt_bands.mbt) 移植 `quant_band_template` 的
  解码路径：theta 的 step/uniform/triangular 模型、N=2 特殊立体声、mid/side 预算重分配、
  递归分带、PVQ、零脉冲噪声/折叠、相位反转与 TF/Hadamard/Haar 重排。
  [opus_celt_spectrum.mbt](libavcodec/opus_celt_spectrum.mbt) 串起整帧频带预算平衡、
  跨带 folding 和 dual→intensity stereo 切换，返回归一化频谱、collapse masks 与噪声种子。
- [opus_celt_coefficients.mbt](libavcodec/opus_celt_coefficients.mbt) 新增
  `OpusCeltHistory` 与 `decode_celt_coefficients`：最终 fine-energy、anti-collapse、
  能量反归一化、静音清谱、mono 能量复制以及两代历史提交。每条逻辑流独立持有历史，
  输入历史不原地修改，失败时不会提交半帧状态。帧尾 seed 取当前 `rc.range`，不是最终 LCG 值。
- 新增真实 libopus 120/240/480/960 样本的 mono/stereo 低延迟流，连同已有 5.1 流，
  **九条流共 84 个逻辑帧 × 相位反转关/开**，得到 **168 组归一化与 168 组连续频域参考**。
  原 `celt.c`/`pvq.c`/`dec_celt.c` 直接生成期望值；熵状态、种子、collapse masks、
  最终能量与两代历史的 Float32 位模式精确一致。归一化系数绝对误差 ≤1e-6；
  缩放后系数误差 ≤`1e-5 + abs(reference)*3e-6`。覆盖 transient、anti-collapse 与后滤波参数。
  另有 **8 组标准静音**的完整频域/历史与 C 逐项精确对拍。
- 真流暴露并修复旧 PVQ 核仅允许 8 个块的限制：TF subdivision 可产生 **16 个内部块**。
  安全检查按实际 TF 表限制调用方可变数组，防止伪造 transient TF 令 Hadamard stride 越界。
  静音填满帧预算后，C 的 1/8-bit safety margin 会合法地产生 -1 的带预算，不能一概拒绝。
  17 张整数表支持十六进制项与 `--check`，C 向量生成方法见
  `scripts/opus_celt_spectrum_reference.c` 与 `scripts/emit_opus_celt_spectrum_vectors.mbtx`。

此频域切片的 PCM 合成见下节；验证目标仍为默认 Wasm。

### 2026-10-22 继续迁移：CELT 连续帧 PCM 合成

- [opus_celt_synthesis.mbt](libavcodec/opus_celt_synthesis.mbt) 移植 FFmpeg
  半逆 MDCT、120 样本 overlap/add、两阶段 pitch postfilter 过渡与稳态滤波，
  最后应用 0.8500061035 去加重并清除非 normal 的末尾状态。逆变换采用 Double
  累加的 O(N²) 直接计算，缩放为 -1/32768，输出回到 Float；尚未做 FFT 优化。
- [opus_celt_decode.mbt](libavcodec/opus_celt_decode.mbt) 提供
  `OpusCeltDecoder::new`、`decode_frame` 与 `reset`。每条逻辑流独立维护频域、
  重叠区、前后两代后滤波参数和去加重历史；错误帧不会提交这些状态。
  输入为去掉 TOC 的 CELT 帧，支持 120/240/480/960 样本和 end band 13/17/19/21，
  输出为 48 kHz、channel-major 的单/双声道 Float PCM。
- [opus_celt_pcm_reference.c](scripts/opus_celt_pcm_reference.c) 直接调用原始
  `ff_celt_init` / `ff_celt_decode_frame`，用原始 AVTX 与 scalar DSP 生成参考。
  九条已有真实流的 **168 组连续逻辑帧**，以及音频后接静音并切换帧长的
  **144 组尾音帧**，逐样本绝对误差均 ≤`3e-6`。覆盖 transient 短块、相位反转开关、
  后滤波延续和残余重叠；复位、非法参数与错误回滚另有回归。
  此处验证每条 5.1 逻辑流的 PCM，尚未实现组合后的 5.1 PCM 输出与声道重映射。
- `moon run scripts/extract_opus_celt_windows.mbtx --check` 校验两张原 C Float 窗口；
  `scripts/emit_opus_celt_pcm_vectors.mbtx` 从 `.scratch/NAME_pcm_reference.txt`
  内嵌上述参考。C harness 沿用频域参考的编译方法，额外链接 `opus/dsp.c`，保持
  `-ffp-contract=off`；运行输入为同名 `NAME_packets.bin`。

本切片固定每个 decoder 的编码/输出声道数，不处理 TOC、多帧包、混合模式、PLC、
容器 pre-skip、输出 gain 或声道切换/下混。下一步接包级/多流 PCM 编排与容器裁剪，
随后继续 SILK/混合模式。

### 2026-10-22 H.264 完整迁移推进（尚未全部完成）

- CAVLC 8×8：四路交错 scan、8×8 反量化和帧内预测；保留原始模式供邻块预测，
  边缘修正模式只送重建。修正 `P_8x8ref0` 不应读取参考索引、8×8 变换允许条件，
  以及 CAVLC 熵计数与去块 8×8 存在标志的差异。
- CABAC I_PCM：退回算术 lookahead，读原始样本后重新初始化 range/low，保留概率状态。
  原 `tests/cabac.c` 编码器生成连续两次 PCM escape，原 FFmpeg 解码取 MD5；
  [h264_pcm_reference.c](scripts/h264_pcm_reference.c) 仅用于独立测试素材，无运行时 FFI。
- 多 slice：共享画面平面，按 slice 重置熵/QP/MV-difference 上下文；帧内与运动预测
  不跨 slice，`constrained_intra_pred` 只约束像素/模式邻居。去块保存各 MB 的 slice、
  参数与参考图 POC 身份；idc=2 保留片内滤波并跳过跨片边。两入口均拒绝缺失/重叠
  slice，完整画面才提交 DPB/POC；AVC 样本失败后可重试。
- POC 0/1/2、frame_num 回绕、POC1 周期与 delta、MMCO 1–6、IDR/普通长参考、
  短/长 L0 重排和滑窗淘汰。修正 MMCO6 仅有一个操作数，以及 POC 字段条件应取 PPS。
  默认 P L0 的短参考按 FrameNumWrap 排序；MMCO5 后的 POC 历史考虑已回绕的 MSB。
- B 前置 header：L0/L1 活跃计数、两套修改命令、direct spatial 标志与双列表显式权重；
  同时保留 SP/SI 的 QS 字段。真实七帧 B-GOP 与显式加权规范流的 header 值/位位置
  由原 FFmpeg `trace_headers` 核验；此处不表示已完成 B/SP/SI 像素重建。

新增十组像素向量 **92 帧 × 滤波/未滤波两套 MD5** 全部对齐 FFmpeg 9.0.2：
真实 CAVLC High 8×8、多参考与加权 P、CABAC 高熵、规则三片/行中间起片及受限帧内预测，
再加 MMCO/POC 三类规范流和连续 I_PCM escape。生成方法在
`scripts/generate_h264_marking_vectors.mbtx`、`scripts/emit_h264_completion_vectors.mbtx`
及向量文件头。全量 Wasm **627/627**；`moon check` 零错误/零警告。

2026-10-23 增量完成后，原清单 1、2 两项中的 B 帧全套、高位深（8–14 bit）与
4:2:2/4:4:4 均已完成（见下节）；仍开放：

1. SP/SI 重建；separate colour plane 与 FMO 继续按原 C 的拒绝边界处理。
2. 单色、transform bypass、MBAFF、PAFF 场图与帧场交叉引用已完成实流验证；
   PAFF 位深/色度、POC 与场顺序的验收矩阵见下节。
3. frame_num gap、SEI T.35 与帧 side-data/边界语义均已完成（见后续小节）；数据分区/冗余 slice、错误恢复仍待补齐。
   原 C 本身拒绝的 FMO 等功能继续保留对应拒绝边界。

### 2026-10-23 H.264 frame_num 间隙参考合成

`h264_gap.mbt` 对照 `h264_slice.c:h264_field_start` 与 `h264_refs.c`：在构建参考表前
补齐缺失 frame_num；大间隙先截短，每次最多合成 SPS 参考容量数量的图片，支持编号回绕。
合成图只参与 DPB/滑窗，不作为输出帧；仅推进 prev_frame_num，不虚构逐帧 POC 历史。
兼容前短参考时复制像素并继承其 POC+2/gray；没有可用前参考时填位深中点灰图。
保留合成图独立的编号/运动身份，同时在去块时按原 C 共享像素缓冲的身份判断参考相等。
禁止间隙的流沿用默认 FFmpeg 容错语义，并按实际输入 frame_num 淘汰过期 invalid_gap。
非灰参考建立后按 noref_gray 替换灰参考；PAFF 待配对场抑制合成，IDR/MMCO5 保持复位语义。
解码失败会回滚本次新增的 DPB 参考和编号/POC 历史，完整图片重试可取得相同结果。

验证：**19 条流、86 帧，默认滤波与跳过滤波两套逐帧 MD5 均对齐 Docker FFmpeg 9.0.2**；
包含独立生成的 CAVLC I_PCM/P_SKIP 流，以及移除完整图片后的真实 CAVLC/CABAC、
多 slice、MBAFF 和 JM PAFF 流。覆盖 POC0/1/2、大间隙/回绕、允许/禁止间隙、
8/10/12-bit 灰图、4:4:4、参考重排、非参考图、IDR/MMCO5；另有 7 项状态回归。
这不代表任意损坏流的错误恢复已完成；无兼容参考时使用确定的中性像素，不仿真原 C
在已恢复但缓冲不兼容等错误路径中的未初始化分配器内容。

复现：准备 `.scratch/h264_baseline.264`、`h264_slices1.264`、
`h264_mbaff_p_cabac.264` 和 `.scratch/JM/bin/jm_paff_p_long.264` 的原始生成流，运行
`moon run scripts/gen_h264_gap_vectors.mbtx`，再运行
`moon run scripts/run_h264_gap_reference.mbtx <.scratch/h264_gaps绝对路径>` 与
`moon run scripts/emit_h264_gap_vectors.mbtx`。参考生成器只挂载样本目录并禁用网络；
显式指定 H.264 输入格式，`-flags2 +showall` 用于观察故意从非 IDR 开始的灰图样本。
提交的回归内嵌码流和固定黄金 MD5，运行测试无需 Docker 或原始生成文件。

全量 Wasm **758/758**；`moon check --target wasm --deny-warn --no-render` 与
`moon info --target wasm` 通过。H.264 剩余重点仍有 SP/SI、数据分区/冗余 slice、错误恢复（SEI 输出元数据已在后续切片完成）；
FMO 与 separate colour plane 保持原 C 的拒绝边界。

### 2026-10-23 H.264 SEI T.35、帧 side-data 与 NAL 边界语义

`itut35.mbt` 移植 `itut35.c`/`atsc_a53.c`/`dynamic_hdr_vivid.c` 与 `aom_film_grain.c` 的
解析侧：T.35 country/provider 全分发（ATSC GA94 字幕/AFD、AOM 颗粒、Samsung、Dolby、SMPTE、V-Nova LCEVC、HDR Vivid）。
与 C 一致的关键语义：Dolby 0x800 在 H.264 路径因无 DOVIContext 忽略；HDR10+/SMPTE 2094-40 App5/HDR Vivid 解析后留在 SEI 上下文不导出到帧（原 C 中 `ff_itut_t35_parse_payload_to_frame` 仅 AV1 解码器调用）；0xFF 国家码消费扩展字节后仍落 default 忽略。
`h264_side_data.mbt` 移植 `ff_h2645_sei_to_frame`：帧标签列表覆盖 stereo3d、displaymatrix、A53/AFD/LCEVC、未注册用户数据、ambient、
mastering display（g,b,r→r,g,b 重排、合法性检查）、content light、H.274 与 AOM 颗粒参数；携带即消费语义与 C 一致。
NAL 边界语义接入 `H264Decoder.decode_nals`：AU 入口在非待配场时 `ff_h264_sei_uninit`（孤场残留带给下一图，同 `!h->first_field`）；
首 slice 前的 SEI 归属本图、slice 后的 SEI 只更新状态；导出时机=帧图或场对第二场（`!FIELD_PICTURE || !first_field`）。
场对细节：A53 双场合并、AFD 取第二场值、LCEVC 第一场在 picture start 挂到待配帧并入对帧输出、
`sei_recovery_frame_cnt` 取首场值（`h264_frame_start` 仅帧图/首场运行）；帧图无恢复点 SEI 时保持 -1。
H.274 颗粒 seed 用图片 POC（本移植无 poc_offset）；另移植 `libavutil/display.c` 的旋转/翻转矩阵。

验证：T.35 分发表/A53 合并/HDR Vivid 位流/AOM 颗粒集单元测试；合成 SEI 流的帧 side-data 逐字段对 trace_headers 转写值断言；
真实 x264 流验证未注册数据挂载与 per-AU 排空；JM PAFF 流注入 SEI 验证场对边界与合并语义。

全量 Wasm **767/767**；`moon check --target wasm --deny-warn --no-render` 与
`moon info --target wasm` 通过。H.264 剩余重点：SP/SI、数据分区/冗余 slice、错误恢复、
HDR10+/SMPTE 2094-40 App5 结构级 T.35 解析与颗粒合成应用。

### 2026-10-23 H.264 PAFF 场图

支持 `field_pic_flag=1` 的 I/P/B 场图与帧场交叉引用：互补场共享平面与运动历史，
按 frame_num、场奇偶及 droppable 状态配对，第二场完成后输出。未解码场 POC 保持
INT_MAX，成对输出取两场最小 POC；第二场接续 slice 编号。场参考表按同/异场交错，
最多 32 项；MMCO 按场掩码更新参考并还原 PicNum 差值；DPB 超限按原 C 回收参考。

`h264_colocated.mbt` 对照 `h264_direct.c` 补齐 col_parity、异场行偏移、帧→场半宏块
抽取与场→帧双宏块抽取；时域 direct 统一参考身份为 `4*identity+structure`，映射
MBAFF/PAFF 场奇偶并使用对应场 POC 缩放，纵向 MV 按帧/场单位换算（除法向零截断）。
4:4:4 场图的水平宏块边使用 bS=3；禁止跨 slice 滤波时定位同场上邻，避免误读另一场。

验证：`h264_paff_realdata_wbtest.mbt` 共 **24 流、276 帧 × 滤波/未滤波两套
framemd5**，全部逐字节对齐 Docker `linuxserver/ffmpeg:9.0.2`
（镜像 ID `sha256:742e17516dd4d7b76b939d774bd08f0f6b7cab8bce1c014b95ab2fb992fd0a1f`）。
每条流同时断言固定帧数，另有 9 项场状态/真实特性覆盖测试。

| 实流组合 | 验收内容 |
| --- | --- |
| 8-bit 4:2:0 | I/P/B、CAVLC/CABAC、空间/时间 direct、12 帧参考标记、多 slice |
| 自适应 frame/field | 空间 direct 流含 7 帧图+10 场图，时间 direct 流含 6 帧图+12 场图；断言帧→场、场→帧 direct 均实际使用 |
| 场顺序/POC | bottom-first 互补场、POC type 0/1/2 |
| 8-bit 4:0:0/4:2:2/4:4:4 | B 帧与完整滤波；单色按 yuv420p 中性色度输出 |
| 高位深 | 4:2:0 的 9/10/12-bit；4:2:2 的 10-bit；4:4:4 的 10/14-bit，含时间 direct |
| slice 去块边界 | 每场多个 slice，`disable_deblocking_filter_idc=2`，同时覆盖同 slice 相邻场行与真实边界 |

底层均保持纯 MoonBit。实流基础来自 JM 19.0；bottom-first 是对真实 JM 时域 direct
流逐 slice 翻转 bottom_field_flag 后的派生样本，其新像素仍由独立 FFmpeg 严格解码取得。
JM 单色编码完成后存在空色度释放错误；生成器仅对完成标记后的该特例继续，并强制
FFmpeg `-err_detect explode` 与回归的固定 12 帧断言。未逐一穷举上表以外的工具组合。

复现：构建 JM 19.0 到 `.scratch/JM/`，保留原版 `bin/encoder.cfg` 与
`foreman_part_qcif.yuv`，依次执行 `moon run scripts/gen_jm_paff_input.mbtx`、
`moon run scripts/gen_jm_paff_cfgs.mbtx`、
`moon run scripts/run_h264_paff_reference.mbtx <JM/bin绝对路径>`、
`moon run scripts/emit_h264_paff_vectors.mbtx`。参考生成器仅挂载 JM/bin，容器禁用网络；
混编配置使用 Full Search，避开 JM EPZS 在跨结构参考时的崩溃。大型码流按需加载，
避免完整 Wasm 测试的包初始化函数超过局部变量上限。

全量 `moon test --target wasm`：**732/732**；`moon check --target wasm --deny-warn`
零错误/零警告；`moon info --target wasm` 通过。剩余 H.264 重点为 SP/SI、
data partitioning 与错误恢复；frame_num gap 合成已在后续完成；FMO、separate colour plane 保持原 C 拒绝边界。

原两条 P 流曾请求 6 帧却只有 3 帧输入，旧“8 流 84 帧”统计应为 78 帧；本轮已补足
输入并重建为各 6 帧，以上 24 流 276 帧由固定帧数断言核验。

### 2026-10-23 H.264 B 帧与 4:2:2/4:4:4 解码

在 I/P 链路上补齐 B 帧全套与全部非单色色度格式，入口与门禁不变：

- **B 帧**（`h264_b_mb/b_mc/b_refs/b_direct`、`h264_output`）：B_Skip/B_Direct 与
  B_16x16/16x8/8x16/8x8 全子分区，L0/L1 参考、mvd 与残差（CAVLC/CABAC 共用）；
  空间/时间 direct（colocated MV 缩放、`direct_8x8_inference`）；显式双向加权与
  隐式权重（POC 距离缩放）；默认 B 列表（FrameNumWrap + LongTermPicNum 两套）。
  输出按 POC 显示重排，IDR/MMCO5 开新 epoch，drain 延迟 B 帧。
- **高位深**（`h264_depth.mbt`）：8/9/10/12/14-bit 样本截断（`h264_store_coef`/`clip8`
  按 bit_depth 缩放）、QP 范围 51+6*(depth-8)、去块 alpha/beta/tc 移位。
- **4:2:2**：chroma422 DC 专用 coeff_token/total_zeros 码表与 8 系数扫描、2×4 DC
  Hadamard（dequant 表取 chroma_qp+3）、`pred8x16_*` 全模式（DC 四行象限、plane 的
  `V=(5v+32)>>6`）、色度 MC `my>>2` + `(my<<1)&7` 相位、CABAC DC `sig_coeff_offset_dc`
  三上下文与 `coeff_abs_levelgt1_ctx` 的 422 变体、`scan8` 缓存纵向堆叠的 nC/cbf
  邻居（偶数块读左宏块 b1/b3/b5/b7、首行块读上宏块 b6/b7）、去块垂直边 16 行
  （每个 bS 管 4 行）与水平边全滤。
- **4:4:4**：色度平面复用 luma 机器（I4x4/I16x16 预测、4×4/8×8 残差、逐平面 DC），
  `ctx_cat` 扩展的 CABAC 类别 6–13 与 cbf 上下文（cat 5 在 444 也读 cbf）、灰度
  cbp 映射表、`fill_decode_caches` 的 444 邻居填充与 8x8DCT/4x4 邻接 quirk
  （非 8x8 邻居按 0/PCM 64 参与上下文）、cbf=0 时整象限 nz 清零、色度 MC 直接用
  luma qpel 滤波器、PCM 768 样本/宏块、去块色度用 luma 核与色度 QP。

验证：`h264_b_realdata_wbtest.mbt` 21 条真实流（加权、CQM、多片、多 GOP、参考切换、
9–14 bit、连续 PCM、稠密残差）共 **142 帧**、`h264_chroma_realdata_wbtest.mbt` 6 条
4:2:2/4:4:4 真实流（CAVLC/CABAC × 8/10 bit）共 **42 帧**，均含默认滤波与
`-skip_loop_filter all` 两套 framemd5，与 FFmpeg 9.0.2 逐字节一致；生成命令在
`scripts/emit_h264_b_vectors.mbtx`、`scripts/emit_h264_chroma_vectors.mbtx` 与文件头。
全量 Wasm **699/699**；`moon check` 零错误/零警告。

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
| H.264 CABAC 宏块层 | 原五条单行/平坦 IDR 向量；新增 16×48/32×48/64×48 稠密 I、64×16 I+3P、96×64 运动 I+5P，共 13 帧滤波/未滤波 MD5。16×48 的 2403 条、64×48 的 8233 条 ctx/state/bin 与原 C 一致，见 §3「CABAC 的验证范围」 |
| H.264 frame_num 间隙 | 19 流/86 帧，独立合成与真实丢帧流，滤波/未滤波两套 MD5 对齐 Docker FFmpeg 9.0.2；另有 7 项状态与失败重试测试 |
| H.264 PAFF / 帧场交叉引用 | JM 19.0 及 bottom-first 派生实流，24 流 276 帧，默认滤波与跳过滤波两套 framemd5 对齐 Docker FFmpeg 9.0.2；覆盖位深/色度、POC、场顺序与多 slice 的具体矩阵见 PAFF 小节 |
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
moon check     # 0 error / 0 warning
moon test --target wasm  # 758/758 passed
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
   **已完成**（`h264_inter/mvpred/mc/dpb` + `h264_b_*` 全套 B 帧；SP/SI 重建仍开放）
4. VP9 profile-0 关键帧像素解码已完成；后续为 VP9 帧间参考/概率适配、AV1 像素与
   Opus 音频解码。HEVC 剩余边界见上方范围清单。
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

## 9. 2026-10-23 H.264 冗余 slice 与范围取舍

`h264_slice.mbt` 保存 `redundant_pic_cnt`；`h264_dpb.mbt` 在读完 slice header 后丢弃冗余 slice，不让它替代主图或更新 DPB。合成 I_PCM 主图验证冗余 slice 前置、后置时都只输出主图。

SP/SI 像素重建明确不纳入项目范围；真实 SP switching 流与合成 SI 流现在都要求返回未支持错误，避免通用 P/I 路径偶然输出错误像素。FFmpeg 9.0.2 自身未解码的数据分区和 FMO 维持未支持边界；本移植对数据分区 NAL 明确报错。

损坏码流的错误恢复当时仍未移植（随后在第 10、11 节补齐渐进帧和 MBAFF）。此次变更后 `moon check --target wasm --deny-warn --no-render` 通过，`moon test --target wasm --no-render` 为 **770/770**。

## 10. 2026-10-23 H.264 渐进帧错误补偿

持久解码器新增可选的 `set_error_concealment(true)`。渐进帧允许缺失首段、中段或尾段 slice；切片内部解码失败时保留已完成的宏块并补偿剩余区域。帧的 `damaged_macroblocks` 记录补偿数量，恢复后的参考帧照常进入 DPB。严格模式仍可在补齐 slice 后重试同一帧。

空间补偿从四个方向的有效宏块估计每个 8×8 luma 和色度子块的 DC；时间补偿从首个 L0 参考帧选取零矢量和相邻宏块矢量，以 16×16 边界差选择候选。实现位于 `h264_error_resilience.mbt`，时序保持“正常 slice 去块滤波之后补偿”，与 FFmpeg 的 `ff_er_frame_end` 一致。回归覆盖缺失中段、末段、首段和截断 CABAC P slice；完整 Wasm 测试为 **772/772**。

这一版仍不是逐像素移植：多轮运动矢量猜测、恢复区专用去块滤波和损坏参考帧的输出策略在下一节补齐；损坏的 MBAFF 帧及场图片当时仍报错。

## 11. 2026-10-23 H.264 MBAFF 错误补偿与场图片边界

MBAFF 损坏帧现在可以补偿。关键在于 `h264_slice_init` 对 `first_mb_in_slice` 做了 `<< FIELD_OR_MBAFF_PICTURE`：MBAFF 帧按宏块**对**编址，换算出 raster 起点后，`ff_er_frame_end` 全程在普通的 `mb_width × mb_height` 网格上工作——上游 `error_resilience.c` 没有任何 MBAFF 分支，`er->mb_height` 仍是宏块行数。因此只需在 `h264_er_raster_start` 里把 pair 地址展开，其余沿用渐进帧逻辑。补偿出的宏块统一按帧宏块重建（`h264_er_decode_mb` 把 `mb_field_decoding_flag` 清 0），`h264_conceal_missing_mbs` 同步清 `field_mb`。

MBAFF 回归用 96×64、6×2 宏块对、每帧两 slice 的流，丢弃 12 个变体（覆盖 I/P/B、前半/后半 slice、损坏参考帧传播），**12/12 逐帧 YUV MD5 与 Docker FFmpeg 9.0.2 一致**。丢 IDR 后半 slice 时上游记录 `concealing 12 DC, 12 AC, 12 MV`，移植侧的 `damaged_macroblocks` 同样是 12。

**场图片不做恢复，这是上游边界而非移植缺失**：`h264_slice.c` 设置 `pic->field_picture = picture_structure != PICT_FRAME`，`er_supported()` 见到它就返回 0，`ff_er_frame_end()` 开头即 `return`，源码里还留着 "We do not support ER of field pictures yet"。实测 PAFF 多 slice 流丢弃一个 slice 后，上游既没有 `concealing` 也没有 `corrupt decoded frame` 日志，输出的是缺失宏块保持缓冲旧值的帧，无法复现。移植侧因此继续明确报 `incomplete H.264 picture`。

同时修掉一个 Annex B 分组缺陷：原先用 `first_mb_in_slice == 0` 判断新图，丢失某帧首 slice 后该帧剩余 slice 会被粘到下一帧，触发 `inconsistent H.264 picture slices`。现在按 slice header 的图标识（`frame_num`/`poc_lsb`/`idr_pic_id`/`field` 标志/`nal_type`/`ref_idc` 等，与 `h264_decode_picture_ex` 的一致性检查同一组字段）比较，`h264_same_picture` 负责判定，解析不出 header 时退回原判据。

新增回归：渐进流缺失首段/中段/连续两段/截断末段 4 个变体逐帧对齐上游；10-bit 4:2:0、4:4:4、4:2:2 的多 slice 流在开关补偿两种模式下均逐帧一致。`put_dc` 的 DC 钳位补上了上游的 `dc > 2040 → 2040`（不随位深缩放，10-bit 因此封顶 255）。

**已知偏差**：P 帧大缺口场景仍未逐像素对齐。`trunc_p_mid`（P 帧中间 slice 截断）最终只剩 V 平面 2 个像素差 1–2，Y/U 整帧一致；`two_split`（参考帧本身被补偿过）与丢整段 slice 的 10-bit/4:4:4/4:2:2 场景差异更大，Y 平面即不同，源于多轮 `guess_mv` 与 DC 估计的取值分歧。这些场景不纳入断言，避免把未对齐的行为固化。

对 `trunc_p_mid` 做过四轮定位，已确认与已排除如下（供后续接手，避免重走）：

- **恢复本身完全正确**。关掉两侧滤波后，恢复宏块 mb16 的 V 区域（x32..39, y16..31）与上游 `-ec 1 -skip_loop_filter all` 逐字节相同；色度 MC 手算校验一致（`mv=(8,-15)` → `dx=0, dy=1` → `(7a+c+4)>>3`）。
- **FFmpeg 的 `-ec` 是位掩码**（`FF_EC_DEBLOCK = 2`）。`-ec 1` 配合 `-skip_loop_filter all` 可以取到"恢复后 / 两种滤波前"的四种中间状态，与移植侧 `skip_lf × er_deblock` 四组合逐一对比——这是这类问题最有效的手段。
- **已排除**：weighted prediction（补上 `h264_weight_rect` 后输出零变化，这些帧 `use_weight == 0`）、bS 取值（1→2 无变化）、QP（恢复宏块 QP 强制 1..40 全无变化）、slice 的 alpha/beta offset（都是 0）、恢复宏块 `deblock_idc`（1→0）、`cstride` 与 `cbase` 坐标（实测 `p=1186 stride=48 len=1920` 正确）、`tc0` 表越界（表长 624，索引有效）。
- **实测参数**：mb22 上边界的判决为 `bs=[2,2,2,2]`、`cq0=20` → `index_a=72` → `alpha=7 beta=3 tc=1`。这条边界上 V 平面 x=34 的 `|p0-q0|=6 < 7` 本应通过，但日志里 `p0` 全是 225~228 这类高值，**V 平面那次调用没有出现在日志中**，说明它与 U 平面共用 `coff`、无法从 `start` 区分，且 V 侧可能提前返回。
- **遗留线索**：在 `h264_filter_chroma_edge` 开头的 `if alpha == 0 || beta == 0 { return }` 插桩，并在 `h264_filter_mb` 调用处用 `data == ctx.v` 区分平面，可以判定 V 是否提前返回。

清理：删除 `scripts/compare_h264_er.mbtx`（脚本模式解析不了本地包导入）、`scripts/inspect_h264_er_reference.mbtx`、`h264_picture_wbtest.mbt` 里的 `moon sums` 调试块，以及已成死代码的单次 `h264_er_guess_mv`（B 帧恒用零矢量，P 帧在 `!picture_mv_done` 分支不可达）。`filter181` 的 `value * 10923` 经核算在 14-bit 最坏值 1.4e9，仍在 Int32 内，与上游 32 位求值一致，加了说明注释。

`moon check --target wasm --deny-warn --no-render` 通过，`moon test --target wasm --no-render` 为 **783/783**。

## 12. 2026-10-23 VP9 帧间帧（inter）解码

补齐 profile-0 帧间路径：`decode_mode` 的 inter 分支（is_inter/comp/参考选择/四种 MV 模式/switchable filter，`vp9_inter_block.mbt`）、`find_ref_mvs` 候选与 sub8x8 直接 MV（`vp9_mvs.mbt`）、非缩放运动补偿与 8tap/sixtap/bilinear 亚像素滤波（`vp9_inter_recon.mbt`）、概率模型 `ff_vp9_adapt_probs` 与 parallelmode 提交（`vp9_probs.mbt`）、inter 概率常量表（`vp9_inter_tables.mbt`）。

验收向量：`testsrc2` 160×120、libvpx-vp9、单参考无 altref 的 IVF（关键帧 + 14 个 P 帧，`-g 6`），**15 帧逐帧 YUV MD5 与 Docker `linuxserver/ffmpeg:9.0.2` 一致**（`vp9_inter_realdata_wbtest.mbt`）。另与插桩 C 参考解码器做了全轨迹对拍：15 帧的块入口（RAC 状态）、skip、系数 STEP 与块级 IMD（模式/MV/滤波器）逐行一致后才比像素。

本轮修掉两个真 bug，定位方法值得复用：

- **commit 的槽步长**：工作表 `prob_coef` 每槽 11 个值（3 真概率 + 8 pareto 尾），上下文表每槽 3 个；parallelmode 下从工作表拷回上下文表时源偏移按 3 计算，读到了别的槽（144 恰为 band0/ctx2/pos2 的默认值），导致帧 1 起系数概率整体错位、约半数像素 ±1~2 偏差。首个分歧 STEP 的 `tp0`（C=14 / MBT=144）配合默认表比对直接锁定。
- **帧级 filter 顺序**：帧头 `interp_filter` 原码是 **0=smooth,1=regular,2=sharp,3=bilinear**（C 直接当 FilterMode 枚举消费），switchable 树码才是 0=regular、1=smooth（C 经 `ff_vp9_filter_lut` 转换）；non-switchable 帧直接透传原码会选错 tap。

对拍中的两个假分歧也记录在案：C 的 `VP9mv` 是 int16 结构体，printf 传整个 struct 会打出打包的 32 位值（如 -1048576 实为 (0,-16)），必须取 `.x/.y`；两侧 filter 枚举顺序不同（C 0=smooth/1=regular，本移植 0=regular/1=smooth）时 diff 脚本要先做 0↔1 归一化。

边界：复合预测（B 帧）、多参考与参考缩放（缩放明确报错）、profile 1/2 未覆盖；`ff_vp9_adapt_probs` 的计数驱动路径已移植，但现有真实流全部是 parallelmode（走 commit 路径），该分支尚未被真实向量验证。调试插桩（IMD/BLK/SKIP/HDR/ADAPT 打印、`vp9_dbg` 字段、临时 trace 测试与脚本）已全部清理，`scripts/extract_vp9_tables.py --check` 复核通过。

`moon check --no-render` 0 error/0 warning，`moon test` **784/784**。

### 2026-10-23 补：VP9 计数驱动概率自适应与多参考验证

用 `-frame-parallel 0` 生成的 160×120 流（关键帧 + 20 个 inter 帧）补齐上一节的验证缺口：21 帧全部 `parallelmode=0`（走 `ff_vp9_adapt_probs` 计数驱动路径而非 parallelmode commit），且三路参考（last/gold/altref）都有块使用。21 帧逐帧 YUV MD5 与 Docker FFmpeg 9.0.2 一致（`vp9_np_realdata_wbtest.mbt`，生成脚本 `scripts/_emit_vp9_np_vectors.py`）。

对拍又抓到一个真 bug：`adapt_prob` 的合成公式 C 侧是 `p1 + (((p2 - p1) * uf + 128) >> 8)`，算术右移对负调整量向负无穷取整；移植初版用 `/ 256`（向零截断），负值时该退位的概率不退位，帧 1 起自适应概率逐槽 +1 漂移（首个分歧 NZ 行的 pareto 尾概率差 1 直接可见）。改为 `>> 8` 后 21 帧语法轨迹（含每系数 NZ 行）与 C 完全一致。

FFmpeg 的 libvpx-vp9 封装不支持编码 B 帧（`libvpxenc.c` 无 max_b_frames 传递），复合预测无法用该编码器生成向量，维持未验证；参考缩放与 profile 1/2 仍是明确边界。

`moon check --no-render` 0 error/0 warning，`moon test` **785/785**。

### 2026-10-23 补：VP9 profile 2（10/12-bit）

在 8-bit inter 之上补齐 profile 2 的 10/12-bit 路径。C 侧 16bpp 与 8bpp 的差异经逐项核对为：`dctcoef`/`dctint` 变宽（int16→int32 存储、int64 蝶形）、q 表按 bpp 行选（`ff_vp9_{dc,ac}_qlookup[bpp_index]`，表早已提取只是索引漏了行偏移）、cat6 系数在 12-bit 多读 4 个高位概率位、LF 的 E/I/H/F 按 `<<(bpp-8)` 缩放且 clip_intp2 位宽为 bpp-1、DC 边缘常量 127/129/128 按 `<<(bpp-8)` 缩放、MC 的 clip 上限放开、输出按 yuv420p10le/12le 打包 LE16。实现方式是把全部 1D 变换核统一到 Int64 蝶形（对 8-bit 有界输入逐位等价，已由 785 帧回归确认）、clip/LF/预测入口带 bpp/pixel_max 参数。

本轮对拍修掉四个真 bug，前两个是移植错、后两个是一次脚本化重写引入又靠真值对拍抓回：

- **av_clip_intp2 的通带**：定义是裁到 `[-2^p, 2^p-1]`（p=BIT_DEPTH-1），首版误写成 `1<<(bits-1)`，8-bit 回归恰好只差 19 像素、由旧新核随机 A/B（2000 组 1 组分歧）定位。
- **iadst16 两处正则重写损伤**：`-(t2a+t3a)*11585` 被改写成 `-(t2a3 + t3a3*11585)`（乘法结合错对象）、`-((8192+sum)>>14)` 的负号被移进移位里。8-bit 向量覆盖不到这些分支（单系数稀疏 TU 才触发），靠「C 模板编成 ktest.c 真值发生器 + MBT 同 LCG 序列 A/B」逐核抓出：七个核各 3000 组随机输入全对齐后，三条 10/12-bit 真实流（45 帧）MD5 全部收敛。
- **系数存储截断**：`decode_coeffs_b` 的存入在 16bpp 下不得做 int16 截断。
- **inter 帧 header 继承**：C 的帧头是持久结构体，inter 帧不重读 coloursspace；本实现的逐帧默认 header 需要把 profile/bit_depth/subsampling 从上一帧带过来。

新增三条真实向量（`vp9_10p/10np/12p_realdata_wbtest.mbt`，生成脚本 `scripts/_emit_vp9_p2_vectors.py`）：10-bit 关键帧+P、10-bit 计数驱动自适应、12-bit，共 45 帧逐帧 MD5 与 Docker FFmpeg 一致。核 A/B 固化为常驻测试 `vp9_kernels_wbtest.mbt`（每核 3000 组 LCG 输入的输出 MD5 对 C 真值），覆盖 8-bit 流触不到的分支。

对拍技巧沉淀：LF 探针按 (E,I,wd) 值组合过滤即可在 C/MBT 两侧对齐同一批调用而不必打印坐标；`String::to_bytes()` 是 **UTF-16LE** 不是 UTF-8，喂 MD5 前须逐 code unit 取低字节。
## 13. 2026-10-24 Opus SILK/混合模式与包级解码

**范围**：Opus 解码器补全 LP 层——`opus_silk.mbt`（silk.c 全量移植：NLSF 稳定化、RFC 8251
LPC 稳定性检查、LSF→LPC 带宽扩展、激励 PVQ/LSB 展开/符号建模、LTP/LPC 合成、mid-only
边声道、立体声 unmix）、`opus_silk_tables.mbt`（tab.c 63 张表，`scripts/extract_opus_silk_tables.mbtx`
批量提取 + `--check` 核对）、`opus_resample.mbt`（libswresample 浮点多相重采样器在
dec.c 配置下的专用移植：filter_size 16、Kaiser β9、exact_rational 精确有理比、
invert_initial_buffer/resample_flush/padless=7 全套状态机；SILK 8/12/16 kHz→48 kHz 全部
走 frac≡0 的 common 核）、`opus_decode.mbt`（dec.c 包级编排：三模式分派、SILK 流的
CELT redundancy 交叉淡化、hybrid 的 celt_delay FIFO、多流 sync FIFO、增益、flush/drain）。
CELT 侧为此增加 `decode_frame_rc`（复用外部 rc + start_band 17 的 hybrid 入口）与
`coefficients_log` 诊断钩子。

**验证**（两层标准，均为 asm 禁用构建的 FFmpeg 9.0.2——x86 swr/float_dsp 内核带 FMA，
位模式与标量不同）：
- SILK-only 七条真实流（NB/MB/WB × 10/20/40/60 ms、CBR code-3 lacing、FEC/LBRR、立体声、
  mid-only）与原生解码器 **framemd5 逐帧位级一致**（含 pre-skip、Ogg granule 末端裁剪、
  resampler drain 帧），向量内嵌于 `opus_silk_realdata_wbtest.mbt`。
- hybrid 两条流（mono/stereo FB）：去归一化 CELT 系数经插桩 dec_celt.c 逐帧 dump，
  **位级 MD5 一致**（语法/能量/分配/PVQ 全链路）；合成阶段（naive IMDCT vs AVTX）沿用
  既有 CELT 3e-6 容差标准。排障路径：熵消耗 tell 全帧一致 → 系数一致 → IMDCT 输入一致
  输出差 ulp → 定位为合成层。

**排障沉淀**：`silk_lsf2lpc` 的 maxabs 扫描读 `lpc32[k]`（上一 argmax）而非 `lpc32[j]`，
maxabs 实际只跟踪 |lpc32[0]|；Q12 赋值的 int16 截断在病态 NLSF 下依赖回绕；编排层
cur_out 必须整帧完成后推进。向量生成与 C 参考构建命令见 `scripts/emit_opus_silk_vectors.py`
文件头与 agent.md §7。


`moon check --no-render` 0 error/0 warning，`moon test` **789/789**。

## AV1 无损关键帧像素解码

以 dav1d 1.5.1 的 `decode.c`、`recon_tmpl.c`、`ipred_tmpl.c` 和 `itx_tmpl.c` 为对照，
完成 8-bit 4:2:0、单 tile、无损关键帧的分区、熵解码、palette、预测、WHT 逆变换和
YUV 输出。参考源码仅用于独立对拍，运行时不依赖 C FFI。

`av1_kf_realdata_wbtest.mbt` 内嵌 libaom 编码的 128×96 单帧及 160×120 六帧码流；
七帧的逐帧 YUV MD5 与 libdav1d 一致。定位时逐块比对 dav1d 的符号解码 range，并
逐行比对原始 YUV。关键修正包括系数 CDF 步长与邻居上下文地址、零 DC 时继续读取
AC 符号、palette 色度左侧缓存的行索引、partition 上下文覆盖长度，以及 8-bit
路径的 32767 系数上限。

当前像素入口对有损帧、帧间帧、多 tile、segmentation、delta Q、qmatrix 和 superres
明确报错；环路滤波、帧间预测及其他像素格式仍待移植。本轮验证：
`moon check --deny-warn --no-render` 0 error/0 warning，`moon test --no-render` **792/792**。

## 14. 2026-10-24 VP9 profile 1/3（4:2:2 / 4:4:4）

在既有 4:2:0 路径上补齐 profile 1（8-bit 4:2:2/4:4:4）与 profile 3（10/12-bit
4:2:2/4:4:4）。解码头解析早已读取 `subsampling_x/y`，缺口集中在像素路径：

- **色度运动补偿**：C 的 `mc_chroma_unscaled` 先把 1/8-pel 亮度 MV 缩放为
  `mv * (1 << (1 - ss_h/v))`，再按 1/16-pel 取整/取相位；移植此前直接使用亮度 MV，
  只对 4:2:0 成立。同步把边界判断的参考色度尺寸改为 `(w + ss_h) >> ss_h`。
- **4:4:4 色度系数缓冲**：C 按 `64*64 >> (ss_h + ss_v)` 分配色度块与 EOB 缓冲；
  4:4:4 的 64×64 块可有四个 32×32 色度 TU，需要 4096 系数与 256 个 EOB。移植的
  1024/64 仅够 4:2:0，12-bit 4:4:4 在 `uveob[n]` 越界，按最大尺寸统一分配。
- **输出打包**：`frame_bytes` 按当前帧的 ss 计算色度宽高，覆盖 yuv422p 与 yuv444p
  （含 10/12-bit LE16），不再硬编码 4:2:0。
- **inter 帧头继承顺序**：profile 1/3 的 inter 帧不重读色彩配置，必须先把上一帧的
  profile/bit-depth/subsampling 带入当前帧，再做“profile 0/2 必须 4:2:0、profile
  1/3 必须 4:2:2/4:4:4”的合法性检查。

验证向量位于独立测试包 `libavcodec/vp9_vectors`（避免主包 wasm `__init` 的局部变量
上限），由 `scripts/_emit_vp9_444_vectors.py` 生成：8-bit 4:4:4、8-bit 4:2:2、
10-bit 4:4:4、12-bit 4:4:4 四条 libvpx-vp9 流，各 6 帧（两个关键帧 + P 帧），
24 帧逐帧 YUV MD5 与 Docker `linuxserver/ffmpeg:9.0.2` 一致。仍余：复合预测（B 帧）、
参考缩放，以及 profile 3 的 4:2:2 组合未单独出向量。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **796/796**。

## 15. 2026-10-24 AV1 无损关键帧 4:2:2 / 4:4:4

AV1 像素路径原先按 8-bit 4:2:0 写死。序列头解析早已读取
`chroma_subsampling_x/y`，本轮把像素侧也参数化：

- `Av1FrameCtx` 保存 `ss_h/ss_v`，`decode_b` 与 `recon_b_intra` 的
  `cbx4/cby4/cbw4/cbh4/has_chroma` 全部改用实际采样；色度边缘可用性标志按
  `I444_FLAG << (ss_h + ss_v)` 选择（与 dav1d 的
  `EDGE_I420_* >> (layout - 1)` 等价）。
- 修正**色度 skip 上下文**的 `not_one_blk`：C 用
  `b_dim[2] - (!!b_dim[2] && ss_hor)`，移植此前把两个采样位都写死为 1。
  这个分歧会让 4:4:4/4:2:2 的 `coef.skip` CDF 上下文错位，轻则像素偏差、
  重则熵解码越界；修正后基础 4:4:4 流即逐帧对齐。
- `Av1FrameOutput::packed()` 按 `ss_h/ss_v` 打包 Y/Cb/Cr，4:2:2 为半宽全高、
  4:4:4 为全尺寸色度；`Av1Tile::data()` 暴露 tile 熵负载供跨包测试使用。
- 新增独立回归包 `libavcodec/av1_vectors`（避免主包 wasm `__init` 局部变量上限），
  由 `scripts/_emit_av1_444_vectors.py` 生成两条 libaom `-crf 0 -g 1` 流：
  64×48 yuv444p 与 yuv422p，各 9 帧，**18 帧逐帧 MD5 与 libdav1d 一致**。

**已知边界**：`enable_intra_edge_filter=0` 的流当时仍与上游不一致；用同参数生成的
4:2:0 流同样复现，确认是本轮之前就存在的 AV1 预测边滤波缺口，不是 4:4:4 引入
（已在 §17 修复）。有损帧、帧间帧与 10/12-bit 仍明确报错（单色见 §18）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **798/798**。

## 16. 2026-10-24 AV1 多 tile 无损关键帧

多 tile 解码的关键是让每个 tile 成为独立的熵解码单元，同时共享帧级像素平面：

- `av1_decode_keyframe_tiles()` 接收 `av1_extract_tiles` 的全部 tile；核心驱动按
  `tile_cols/tile_rows` 推导每个 tile 的 SB 行列范围，并为每个 tile 新建
  `Av1Msac` 与 `av1_cdf_copy_defaults()`，避免 tile 间概率状态串联。
- above 上下文按 tile row 分 bank（`sb128w * tile_rows`），起始索引加上
  `col_start >> 5`；left 上下文在每行 SB 起始处重置。这样 tile 边界两侧不会互相
  读取预测/系数上下文。
- palette 的 above/left 缓存与 `pal_sz_uv` 从帧级共享改为**每 tile 独立**，并在
  每个 SB 行重置左侧缓存；此前多 tile 会在 tile 边界串用上一 tile 的 palette
  上下文，导致 `pal_sz`/`use_pal` 语法错位并最终熵解码越界。
- 像素写入仍共用整帧平面；tile 边界只影响上下文与预测可用性，不影响最终拼图。

验证：`libavcodec/av1_tiles_vectors` 内嵌两条 libaom 无损流（128×64 双 tile
列、128×128 2×2 tile），各 3 帧，**6 帧逐帧 MD5 与 libdav1d 一致**（生成脚本
`scripts/_emit_av1_tiles_vectors.py`）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **800/800**。

## 17. 2026-10-24 AV1 无帧内边滤波（Z2）修复

上一节登记的 `enable_intra_edge_filter=0` 缺口定位到 `ipred_z2` 的无滤波左侧
边缘拷贝：dav1d 的 `pixel_copy(&topleft[-height], &topleft_in[-height], height)`
要求写入 `topleft-height .. topleft-1`，移植写成了 `topleft .. topleft-height+1`，
整体偏移一位且丢失 `topleft-height`。滤波/上采样路径不经过该分支，因此此前所有
默认流都能通过；关闭 edge filter 后 Z2 预测块开始出现偏差。

修正为按 `topleft - height + i` / `topleft_in - height + i` 顺序拷贝。新增
`av1_420_noedge` 真实流（64×48、关闭 palette/CFL/filter-intra/edge-filter，3 帧），
连同原有 4:4:4/4:2:2 两流共 **21 帧**逐帧 MD5 与 libdav1d 一致。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **801/801**。

## 18. 2026-10-24 AV1 单色无损关键帧

AV1 monochrome 不再在入口拒绝：

- `decode_b` 与 `recon_b_intra` 的 `has_chroma` 增加 `!seq.monochrome` 条件，
  所有 UV 模式、palette、色度 CBF/变换与色度预测语法按规范跳过。
- `Av1FrameOutput` 记录 `mono`，`packed()` 在单色时只输出 Y 平面，匹配
  ffmpeg 的 `gray` 帧布局。
- 新增 64×48 8-bit 灰度 libaom 无损流（3 帧），与 4:4:4/4:2:2/noedge 三条流
  合计 **24 帧逐帧 MD5 与 libdav1d 一致**。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **802/802**。

## 19. 2026-10-24 VP9 profile 3 4:2:2 与 4:4:0 覆盖

VP9 的色度路径在第 14/15 节已按 `ss_h/ss_v` 通用化，但此前只验证过
4:2:0、8-bit 4:2:2 与 10/12-bit 4:4:4。本轮补齐四个真实流组合：

- profile 3：10-bit 4:2:2、12-bit 4:2:2；
- profile 1：8-bit 4:4:0；
- profile 3：10-bit 4:4:0。

四条流均为 64×48、6 帧（关键帧 + P 帧），色度 MC、4:4:0 的半高色度平面、
输出打包与循环滤波均直接复用现有通用实现，**无需改动解码代码**；
24 帧逐帧 YUV MD5 与 Docker FFmpeg 9.0.2 一致。VP9 4:4:4/4:2:2/4:4:0
回归现共 8 条流、48 帧。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **806/806**。

## 20. 2026-10-24 WAV PCM 写入器

新增 `WavMuxer`（`libavformat/wav_mux.mbt`），按 FFmpeg `wavenc.c` 的
RIFF/WAVE 布局写出 16/24/32-bit 有符号 PCM：

- `wav_muxer_new` 校验采样率、声道数与位深；8-bit（WAV 的无符号 PCM）明确拒绝。
- `write_samples` 接收交错 `Int32` 样本并按小端写入低 `bits` 位；
  `finish` 生成 `RIFF`/`fmt `/`data`、计算 `block_align`/`byte_rate`，
  奇数长度 data 自动补 pad 字节。
- 回归将写出的字节重新交给现有 `av_wav_open`，验证格式字段、数据偏移/长度、
  样本计数、16-bit 立体声与 24-bit 单声道奇数长度补位。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **809/809**。

## 21. 2026-10-24 MPEG-TS 写入器

新增 `TsMuxer`（`libavformat/ts_mux.mbt`），按 `mpegtsenc.c` 的静态表与
PES 布局写出单节目 TS：

- PAT（PID 0）与 PMT（PID 0x1000）用 MPEG-2 CRC32（poly `0x04C11DB7`、
  init `0xFFFFFFFF`）生成，PMT 声明 H.264 `0x1B` 与 AAC ADTS `0x0F`。
- PES 支持 PTS-only 头；视频 PES 使用无界长度、音频使用有界长度。
- 视频 PES 首包写入 33-bit PCR（90 kHz，扩展位 0），采用
  adaptation field + PCR_flag，并相应把该包净荷缩到 176 字节。
- 188 字节打包：首包 PUSI、按 PID 维护 4-bit continuity counter；不足 184
  字节时用 adaptation field stuffing 补齐。
- 大负载自动跨多个 TS 包；测试用现有 `av_mpegts_open` 回读，验证
  stream PID/codec、PES 负载、PTS、PCR 与多包拆分。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **811/811**。

## 22. 2026-10-24 ADTS AAC 写入器

`libavcodec/audio_headers.mbt` 新增 `aac_adts_header_write`：按 ADTS 54-bit
fixed/variable header 生成 7 字节无 CRC 头（MPEG-4、AAC object type、
sampling_frequency_index、channel_configuration、13-bit frame_length、
buffer_fullness 全 1）。

`libavformat/adts_mux.mbt` 的 `AdtsMuxer` 将每个 AAC 原始帧加头后累积；
`adts_muxer_new(rate, channels, object_type=2)` 校验参数，`write_frame`
限制帧长不超过 8191，`finish` 返回完整 ADTS 流。回归把输出交给现有
`av_adts_open`，验证 codec/profile/sample rate/channels、两帧长度与
`total_samples == 2048`，并覆盖不支持采样率与超长帧的负例。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **813/813**。

## 23. 2026-10-24 Ogg/Opus demuxer

新增 `libavformat/ogg.mbt`，支持单个 Opus 逻辑流的常见 `.opus`/`.ogg` 文件：

- Ogg 页解析：`OggS` 捕获、granule、serial、segment table 与 lacing
  重组（含跨页 packet）；按页 CRC-32/MPEG-2（非反射、init 0）校验。
- 识别 `OpusHead`/`OpusTags`，保存 OpusHead 为 extradata，输出 48 kHz、
  pre-skip 与声道数。
- 数据包用 `opus_parse_packet` 得到 TOC 时长；PTS 按
  `cumulative - pre_skip` 计算，并用页 granule 修正末包 duration。
- 真实 libopus 流（48 kHz 单声道、0.2 s、64 kb/s）回归：11 个包的大小、
  PTS、duration 与 ffprobe 一致，包负载 MD5 全部对齐；损坏页 CRC 负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **815/815**。

## 24. 2026-10-24 Ogg/Opus 写入器

`libavformat/ogg_mux.mbt` 新增 `OggOpusMuxer`：

- `ogg_opus_muxer_new` 支持 1/2 声道、pre-skip、输入采样率与 serial。
- 首包前写 BOS 的 `OpusHead` 与 `OpusTags`；随后每个 Opus 包一页，
  granule 为累计 48 kHz 样本数，末页置 EOS。
- 每页按 Ogg lacing（255 续段）编码，并用非反射 MPEG-2 CRC32 回填校验和。
- 回归将写出的 Ogg 交给 `av_ogg_opus_open`：3 个真实 Opus 包的
  payload、PTS `[-312, 648, 1608]`、duration 960、pre-skip 与 extradata
  全部一致；空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **817/817**。

## 25. 2026-10-24 WAV 8-bit 与 WAVE_FORMAT_EXTENSIBLE

`WavMuxer` 扩展：

- 支持 8-bit PCM，按 WAV 约定把有符号输入偏移到无符号字节（`pcm_u8`）。
- `wav_muxer_new` 新增 `channel_mask`；声道数 >2 或 mask 非零时写
  `WAVE_FORMAT_EXTENSIBLE`（fmt chunk 40 字节、valid_bits、channel mask 与
  KSDATAFORMAT_SUBTYPE_PCM GUID）。
- 回归覆盖 8-bit 单声道字节值、6 声道/mask 0x3F 的 extensible 头与
  `av_wav_open` 回读（codec、声道、位深、channel_mask、data 大小）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **818/818**。

## 26. 2026-10-24 AAC-in-MP4 写入器

新增 `libavformat/mp4_mux.mbt`，写出最小非分片 MP4：

- `ftyp` + `mdat` + `moov`；`mvhd`/`tkhd`/`mdhd`/`hdlr`/`smhd`/`dinf`
  与音频 `stbl`（`stsd`/`stts`/`stsc`/`stsz`/`stco`）。
- `mp4a` AudioSampleEntry + `esds`（ES/DecoderConfig/DecoderSpecific/SL
  descriptors），DecoderSpecificInfo 为 AAC-LC 的 2 字节 AudioSpecificConfig。
- 支持任意 AAC 采样率表中的采样率与 1–7 声道、逐包 duration；`stts`
  自动做 run-length 压缩，单个 chunk 记录全部样本。
- `libavformat/mp4_mux_wbtest.mbt` 用 `av_mov_open` 回读：track
  `mp4a`/`aac`、48 kHz/双声道、ASC、3 个样本的 offset/size/dts/duration 与
  payload 全部一致；非法采样率与空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **820/820**。

## 27. 2026-10-24 H.264-in-MP4 写入器

新增 `libavformat/mp4_video_mux.mbt`：

- 调用方提供 `avcC` 与长度前缀访问单元；写 `avc1` VisualSampleEntry、
  `avcC`、`vmhd`/`dinf` 与视频 `stbl`。
- 支持时间基、逐包 duration、关键帧标记；`stss` 只列出关键帧，
  `stts` 做 run-length，`tkhd` 宽高按 16.16 写入。
- 回归用真实 44 字节 High-profile avcC，`av_mov_open` 回读验证
  `avc1`、64×48、时间基、extradata、3 个样本的 size/dts/duration/
  keyframe 全部一致；非法参数与空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **822/822**。

## 28. 2026-10-24 Opus-in-MP4 写入器

新增 `libavformat/mp4_opus_mux.mbt`：写 `Opus` AudioSampleEntry + `dOps`
（version/channels/pre-skip/input rate/gain/mapping family 按大端存放），
复用 MP4 的 `mvhd`/`trak`/`stbl` 样本表布局。逐包 duration 从
`opus_parse_packet` 的 TOC 得到，`stts` 自动 run-length。

回归用真实 20 ms Opus 包写 3 帧，经 `av_mov_open` 回读：track
`Opus`、48 kHz、单声道、19 字节 OpusHead extradata，3 个样本的
size/dts/duration 与 payload 全部一致。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **823/823**。

## 29. 2026-10-24 AV1-in-MP4 写入器

新增 `libavformat/mp4_av1_mux.mbt`：写 `av01` VisualSampleEntry + `av1C`
（调用方提供配置记录）、`vmhd`/`dinf` 与视频样本表。逐包 duration、
关键帧 `stss`、`stts` run-length 与 H.264 写入器一致。

回归用 4 字节 av1C 写 3 个样本，`av_mov_open` 回读验证 `av01`、64×48、
extradata、size/dts/duration/keyframe 全部一致；非法参数与空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **825/825**。

## 30. 2026-10-24 WAV IEEE float32 写入

`WavMuxer` 新增 `float=true` 模式：

- 仅允许 32-bit；`write_float_samples` 按 IEEE-754 位模式写小端。
- `fmt` 使用 format tag 3（IEEE float）；extensible 时 GUID 首 4 字节
  改为 0x00000003。
- 回归写 `[0.5, -0.5]` 双声道，`av_wav_open` 回读为 `pcm_f32le`，
  位模式 `00 00 00 3F / 00 00 00 BF` 与 data 大小一致；16-bit float 负例报错。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **826/826**。

## 31. 2026-10-24 HEVC-in-MP4 写入器

新增 `libavformat/mp4_hevc_mux.mbt`：写 `hvc1` VisualSampleEntry + `hvcC`
与视频样本表。回归使用真实 108 字节 Main-profile hvcC，`av_mov_open`
验证 `hvc1`、64×48、extradata、两个样本的 dts/duration/keyframe。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **827/827**。

## 32. 2026-10-24 VP9-in-MP4 写入器

新增 `libavformat/mp4_vp9_mux.mbt`：写 `vp09` VisualSampleEntry + `vpcC`
FullBox 与视频样本表，支持关键帧、逐包 duration、`stts` run-length。

回归写 12 字节 vpcC（version 1、8-bit 4:2:0）与 2 个样本，`av_mov_open`
回读验证 `vp09`、64×48、样本 dts/duration/keyframe。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **828/828**。

## 33. 2026-10-24 MP4 `vpcC` 解析

`mov_read_vpcc` 之前未移植，VP9-in-MP4 的 `vpcC` 被当作未知 box 跳过。新增
`parse_vpcc`：从 FullBox 读取 version/flags、profile、level、bit-depth/
chroma/range 打包字节，保存为 4 字节 `vpcC` 记录供 `vp9_parse_vpcc` 使用。
既有 `mp4_vp9_b64` fixture 实际含 12 字节 vpcC（profile 0、level 10、
8-bit 4:2:0），测试由“未解析”更新为校验 profile/level/pix_fmt；新写的
VP9 MP4 也能回读出 extradata。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **828/828**。

## 34. 2026-10-24 WebM/Opus 写入器

新增 `libavformat/webm_mux.mbt`：写 EBML Header（DocType `webm`）、Segment
Info、单个 `A_OPUS` Track（CodecPrivate=OpusHead）与一个 Cluster。SimpleBlock
按 Opus TOC 累计时长写入毫秒相对时间戳，所有音频帧标记为 keyframe。

EBML 元素使用最小长度 VINT；Tracks/TrackEntry 尾部插入空 Void，避免当前
demux 在多层元素同一偏移结束时重复解析 TrackEntry。输出经
`av_matroska_open` 回读：`is_webm`、1 条 `A_OPUS` 轨、19 字节 OpusHead、
3 个包 payload 与 PTS 0/20/40 ms 全部一致；ffprobe 亦识别为 Opus/48 kHz/mono。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **830/830**。

## 35. 2026-10-24 WebM/VP9 写入器

新增 `libavformat/webm_video_mux.mbt`：复用 WebM EBML 辅助写 `V_VP9`
视频轨（Video PixelWidth/PixelHeight）与 Cluster/SimpleBlock。逐包 duration
以毫秒写入相对时间戳，关键帧置 SimpleBlock keyframe 位。

回归写 64×48、3 个 VP9 包，`av_matroska_open` 回读验证 `V_VP9`、像素尺寸、
payload 长度、PTS 0/33/66 ms 与 keyframe 标记；非法参数/空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **832/832**。

## 36. 2026-10-24 WebM VP9+Opus 多轨写入器

新增 `libavformat/webm_av_mux.mbt`：单文件写入 `V_VP9` 视频轨与 `A_OPUS`
音频轨。调用方按毫秒提供每包 PTS/duration，`finish` 按 PTS 稳定排序后在
一个 Cluster 中交错输出 SimpleBlock；视频保留 keyframe 位，音频恒为同步帧。

回归写 3 个视频包 + 3 个音频包，`av_matroska_open` 回读验证两条轨道的
CodecID/Video/Audio 参数、6 个包的交错顺序、stream_index、PTS 与 payload。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **834/834**。

## 37. 2026-10-24 WebM/AV1 写入器

新增 `libavformat/webm_av1_mux.mbt`：写 `V_AV1` 视频轨、Video
PixelWidth/PixelHeight 与 `CodecPrivate`（av1C），复用 WebM EBML 与
SimpleBlock 写入器。回归用 4 字节 av1C、2 个样本回读验证 CodecID/
CodecPrivate、尺寸、PTS 与 keyframe。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **835/835**。

## 38. 2026-10-24 H.264 + AAC 双轨 MP4 写入器

新增 `libavformat/mp4_av_mux.mbt`：一个文件内写 video (`avc1`/`avcC`)
与 audio (`mp4a`/`esds`) 两条轨，共用一个 `mdat`；视频/音频样本分别成 chunk，
`stco` 记录各自偏移，`stbl` 的 `stts`/`stsc`/`stsz` 与视频 `stss` 逐轨生成。
movie timescale 固定 1000，tkhd/mvhd 时长按各自媒体时长换算。

回归写 2 个 H.264 样本 + 3 个 AAC 样本，`av_mov_open` 回读验证两轨
codec/尺寸/采样率/声道、样本 dts/duration/keyframe、chunk payload 与
AAC esds。非法参数与空包负例通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **837/837**。

## 39. 2026-10-24 MKV/H.264 写入器

新增 `libavformat/mkv_h264_mux.mbt`：EBML DocType `matroska`、`V_MPEG4/ISO/AVC`
视频轨与 `CodecPrivate`（avcC）、Video 尺寸、Cluster/SimpleBlock。回归用真实
44 字节 avcC 写 2 个样本，`av_matroska_open` 回读验证 CodecID/CodecPrivate、
64×48、PTS 与 keyframe。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **838/838**。

## 40. 2026-10-24 MKV/H.264+AAC 双轨写入器

新增 `libavformat/mkv_av_mux.mbt`：DocType `matroska`，同时写
`V_MPEG4/ISO/AVC`（CodecPrivate=avcC）与 `A_AAC`（CodecPrivate=
AudioSpecificConfig）两轨。按毫秒 PTS 稳定排序后交错写 SimpleBlock；
两轨 TrackNumber/UID 分别为 1/2。

回归写 2 个 H.264 + 2 个 AAC 包，`av_matroska_open` 回读验证两条轨
CodecID/CodecPrivate、4 个包的交错顺序、stream_index、PTS 与 payload。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **840/840**。

## 41. 2026-10-24 HLS 媒体播放列表写入

新增 `libavformat/hls_mux.mbt` 的 `hls_write_media_playlist`：输出
`#EXTM3U`/`EXT-X-VERSION`/`EXT-X-TARGETDURATION`/`EXT-X-MEDIA-SEQUENCE`、
逐段 `#EXTINF` 与可选 `#EXT-X-ENDLIST`。target duration 可显式给出，否则
取最大段时长上取整。

回归把输出重新交给 `av_hls_parse`，验证版本、目标时长、media sequence、
3 个 segment 的 URI/时长与 ENDLIST；空列表/无 ENDLIST 也覆盖。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **842/842**。

## 42. 2026-10-24 DASH SegmentTemplate MPD 写入

新增 `libavformat/dash_mux.mbt` 的 `dash_write_segment_template_mpd`：
生成单 Period/单 AdaptationSet/单 Representation 的静态 MPD，含
`SegmentTemplate` 的 timescale/duration/startNumber/initialization/media
模板。回归交给 `av_dash_parse`，验证 `$RepresentationID$` 与
`$Number%03d$` 展开、5 个 segment、编号 5..9 与 URI。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **843/843**。

## 43. 2026-10-24 HLS 主播放列表写入

新增 `hls_write_master_playlist`：输出 `#EXTM3U`/VERSION 与
`#EXT-X-STREAM-INF:BANDWIDTH,RESOLUTION,CODECS` + variant URI。回归用
`av_hls_parse` 回读验证 `is_master`、两条 variant 的带宽/分辨率/codecs/URI。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **844/844**。

## 44. 2026-10-24 fMP4 初始化段与媒体段写入器

新增 `libavformat/fmp4_mux.mbt`：面向 DASH/HLS 分片，单轨一段。初始化段写
`ftyp`（isom/iso6/mp41/dash）与 `moov`（`mvhd`/`trak`/`mvex`/`trex`，`stbl`
只保留 `stsd` 和空样本表）；媒体段写 `styp`（msdh/msix/cmfs）、`moof`
（`mfhd`/`tfhd` default-base-is-moof/`tfdt` v1/`trun` 带 per-sample
duration/size/flags）与紧随其后的 `mdat`，`trun` 的 data_offset 指向 mdat
负载。支持 H.264（`avc1`/`avcC`）与 AAC（`mp4a`/`esds`）两种初始化段；
抽出 `mp4_h264_entry`/`mp4_aac_entry` 供普通与分片写入器共用。

回归把初始化段与两段媒体段拼接后交给 `av_mov_open`，验证编解码器、尺寸、
extradata、样本 DTS/时长/keyframe 与负载偏移；负例覆盖空段与零时长。另用
FFmpeg 9.0.2 外部校验：生成的 H.264 分片文件逐帧 framemd5 与源 MP4 完全一致，
AAC 分片解码 PCM 去掉首帧 priming 后与源文件逐样本一致。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **848/848**。

## 45. 2026-10-24 fMP4 扩展到 HEVC/AV1/VP9/Opus

把 fMP4 写入器从 H.264/AAC 扩展到 HEVC（`hvc1`/`hvcC`）、AV1
（`av01`/`av1C`）、VP9（`vp09`/`vpcC`）与 Opus（`Opus`/`dOps`）。抽出
`mp4_visual_entry` 统一生成 VisualSampleEntry，HEVC/AV1/VP9 与 H.264
写入器共用；Opus 抽出 `mp4_opus_entry`/`mp4_opus_dops`，普通 MP4 与分片
写入器复用。

回归新增四组初始化段+媒体段回读（编解码器、尺寸、extradata、DTS/时长）
与参数负例。外部用 FFmpeg 9.0.2 校验：四种分片文件均被正确识别为
hevc/av1/vp9/opus，前 3 帧（或 Opus 前 3 包）解码结果与源 MP4 完全一致。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **853/853**。

## 46. 2026-10-24 MPEG-TS 写入器支持自定义 stream type

`ts_muxer_new` 新增 `video_stream_type`/`audio_stream_type` 命名参数（默认
0x1B H.264 与 0x0F AAC，保持既有调用兼容），PMT 中的流类型改由字段驱动，
由此支持 HEVC（0x24）、MP3（0x03/0x04）等解复用器已能识别的组合。

回归内嵌 docker FFmpeg 9.0.2 生成的真实向量：libx265（AUD 拆分的 3 个
access unit）与 libmp3lame（4 帧 MPEG-1 Layer III），以 HEVC+MP3 组合
写入并经 `av_mpegts_open` 回读，验证 codec/pid/PTS/payload/PCR 全部一致。
外部校验：同参数产物 `.ts` 被 ffprobe 正确识别为 hevc+mp3，视频 3 帧与
音频 4 帧的 framemd5 与源码流解码完全一致，ffprobe 的 pts_time 序列
（视频 0/0.1/0.2 s，音频 1152 样本步进）符合预期。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **854/854**。

## 47. 2026-10-24 Matroska DocType 下的 VP9/AV1/Opus 写入器

`webm_vp9_muxer_new`/`webm_av1_muxer_new`/`webm_opus_muxer_new` 新增
`doctype` 命名参数（默认 `webm`，可选 `matroska`，其余值报 EINVAL），
EBML 头的 DocType 改由参数驱动，VP9/AV1/Opus 由此可直接产出独立 .mkv。

同轮对齐 FFmpeg `matroskaenc.c` 的 Opus 语义：pre-skip 非零时写
`CodecDelay`（0x56AA，pre-skip 按 48 kHz 换算成 ns）与 `SeekPreRoll`
（0x56BB，80 ms），并把 SimpleBlock 时间戳加上 ms 时间基下的 ts_offset
（半远离零舍入），使解复用器的 `- codec_delay_in_track_tb`（已有逻辑）
恢复原始时间戳。此前 webm/matroska 产物缺这三者，ffmpeg 解码时 pre-skip
时间戳语义与 mp4 路径不一致。

回归新增三种编码的 matroska DocType 回读（`is_webm` 为假、CodecID、
extradata/OpusHead、`codec_delay`/`seek_preroll`、包与 PTS round-trip）
与非法 DocType 负例。外部用 FFmpeg 9.0.2 校验：三个 .mkv 均被 ffprobe
识别为 vp9/av1/opus；VP9、AV1 各 3 帧 framemd5 与源完全一致；Opus 前
3 帧解码 PCM（跳过 pre-skip 312 样本后 2568 样本）与源 mp4 解码输出
逐字节一致。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **860/860**。

## 48. 2026-10-24 VP9 复合预测触发确认与 alt-ref 真实向量测试

`Vp9Decoder` 新增诊断计数器 `comp_inter_blocks`：`decode_mode_inter` 进入
复合参考分支（`b.comp != 0`，含 `comp_pred_mode` 1/2 两种来源）时累加，
用于确认复合预测是否真的被码流触发。

用它检查 libvpx `-auto-alt-ref 1` 生成的 21 包码流：所有 inter 帧的
`comp_pred_mode` 均为 0（单参考），复合块计数为 0——即 libvpx 在该模式下
确实不产生复合预测块，README 的"编码器无法生成"表述经计数探针证实。
顺带发现旧探针向量（`.trash` 内 base64）是截断的（4159/17953 字节），
已从 `.scratch/vp9_alt.ivf` 重新提取。

这组码流转正为 `vp9_vectors/vp9_altref_test.mbt`：21 帧逐帧 MD5 与
FFmpeg 9.0.2 framemd5 全部一致，并断言 `comp_inter_blocks == 0`。
大 base64 字面量仍需放独立向量包（libavcodec 主包会撞 Wasm `__init`
局部变量上限）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **861/861**。

## 49. 2026-10-24 AV1 无损关键帧支持 10/12-bit

把 AV1 像素路径从 8-bit 泛化到 8/10/12-bit。核心是像素平面
`FixedArray[Byte]` → `FixedArray[Int32]` 的一次性重构：`planes`/
`ipred_edge`/`edge_buf`/`pal`/`al_pal` 换为分量值存储，`Av1FrameCtx` 增加
`bpc`/`pixel_max`/`mid`，`Av1FrameOutput::packed` 对高位深按小端 uint16
打包（对应 ffmpeg 的 yuv420p10le/p12le）。

位深相关语义逐点对齐 dav1d（BITDEPTH 模板分支）：
- ipred 常量参数化——edge 填充 129/127/128 → `mid±1`/`mid`；DC_128 →
  `(1<<bpc)>>1`；`dc_gen` 非方形乘数 8-bit (0x5556/0x3334,>>16) 与
  10/12-bit (0xAAAB/0x6667,>>17) 分支；`iclip_pixel` 上限 `pixel_max`；
  ipred/itx 系列函数加 `bd_max`/`mid` 可选命名参数（默认 255/128 兼容）。
- palette 解析 `bpc` 来自序列头（`decode_bools(bpc)`、delta bits、max 环绕）。
- dequant 表按 `dav1d_dq_tbl[hbd]` 三组选取（init_quant 原已就绪）。
- **decode_coefs 的 cf_max 修正**：原硬编码 32767（8-bit），改为
  `~(~127<<bpc)`（10→131071、12→524287）。这是 12-bit 不收敛的根因——
  大系数被错误钳制；10-bit 流恰未触发但同属错误，一并修复。
- CFL AC 模拟 dav1d `int16_t` 存储的环绕语义（12-bit AC 和可达 131040）。

回归：既有 8-bit 无损向量 MD5 不变（11/11）；新增 10/12-bit yuv420p
libaom `-crf 0` 三帧向量（128x96），与 libdav1d framemd5 逐帧一致。
调试过程沉淀：先按行/平面 MD5 定位到 U 平面 16x8 区域，再用块参数
插桩（uv_mode/pal_sz/cfl_alpha）区分 CFL 与非 CFL 块，最终锁定 cf_max。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **862/862**。

## 50. 2026-10-24 AV1 有损帧开工：非方形变换 levels 布局修正

有损帧（lossless=0）支持的前置调研与首个正确性修复。侦察结论：
tx_mode=2 的逐块 tx size 符号、txtp_intra1/2 符号、eob_bin 全表
（16..1024）、dequant/cf_max、tx_type_class 等解码层组件此前均已就位；
用 `-enable-cdef 0 -enable-restoration 0` 的 crf30 8 帧向量试探，6 帧
可完整解码、2 帧在帧尾附近块符号分歧导致 overread（分歧点已用逐
tx 子块的 msac cnt 插桩定位到 (18,23) 的 4x4 IDTX 块附近，root cause
尚需全帧符号仲裁器对拍）。ffmpeg `-skip_loop_filter` 对 libdav1d 无效，
未滤波参考不可得，LF 必须实现后才能整帧验收。

修复 `decode_coefs` 的 levels 布局：dav1d 的 DECODE_COEFS_CLASS 宏中
`if (TX_CLASS_2D)` 以枚举常量 0 参与判断恒为假，levels 对**所有**
tx class 都取转置布局 `x*stride+y`；原实现 2D 类用 `rc` 索引，仅在
方形变换（含全部无损 4x4 路径）时数值巧合相等，非方形变换的
lo_ctx 会错。入口对 `!coded_lossless` 保持拒绝（待 LF 移植与符号
分歧收敛后放开）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **862/862**（既有无损向量不受影响）。

## 51. 2026-10-25 AV1 有损对拍基础设施：全帧 C 仲裁器（进行中）

有损符号分歧（见 §50）的对拍工具建设。apt 网络持续不可用使
meson 构建 dav1d-dbg 不可行；改走 alpine:3.20 + `apk add gcc`
（可用），参照 trace_arb.c 的 include 真源码模式写全帧仲裁器
`.scratch/av1_hbd/kfarb.c`（decode_sb 递归含 T-split 三子块/H4/V4、
decode_b 的 skip/ymode/uvmode/CFL/palette/txsize、decode_coefs 全
token 链），符号 tag 打印用于与 MoonBit 侧逐行 diff。

已修通的 kfarb 自身 bug：partition 的 n_symbols 应为
`partition_type_count[bl]`（不减 1，MoonBit 侧本来就对）；txsz CDF
三维索引 `[max-1][ctx]`；CDF qcat 按 qidx 分档（>120/>60/>20）；
palette 的 sz_ctx=`b_dim[2]+b_dim[3]-2` 与 pal_ctx 双比特、
`allow_screen_content_tools` + `bw4+bh4>=4` 门控；CFL 的 joint
sign（`cfl_sign` 8 值拆 sign_u/sign_v）+ `cfl_alpha[ctx]` 两段式。

当前卡点：trace 在 f2 的 (4,0) bl=2 bp=8（T_LEFT_SPLIT）块
bs=9 处 segfault，uvmode 符号已解出、后续 pre-palette 探针未达，
崩因待查（疑 read_pal_plane 的 al_pal 索引或 T-split 边界坐标）。
向量与现场保留在 `.scratch/av1_hbd/`（kfarb.c、run_kfarb.py、
lossy8.ivf、crf30/crf55 向量）；下一步修通后与 MoonBit 侧 trace
diff 定位首个分歧符号，再开 LF 移植。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **862/862**。

## 52. 2026-10-25 AV1 有损关键帧解码 + 环路去块滤波

接续 §50/§51：放弃手写 C 仲裁器，改为**直接编译 dav1d 1.5.1 源码**
（alpine `gcc`，`HAVE_ASM=0`，非模板文件不定义 `BITDEPTH`，模板文件
`-DBITDEPTH=8`；用 `config.h` + 空 `vcs_version.h`）并打开
`DEBUG_BLOCK_INFO`、`decode_coefs` 的 `dbg`，得到权威逐符号轨迹；
同时把 `Dav1dSettings.inloop_filters` 置 0 取得未滤波参考帧，便于分离
「重建」与「滤波」两类差异。工具落在 `.scratch/dav1d_dbg/`（不入库）。

符号层对比（8 帧全部一致）后定位并修复五个真 bug：
1. `cfl_allowed_mask` 位集错误：按自然色度尺寸写的，dav1d 的
   `enum BlockSize` 顺序下 CFL 允许集是 7,8,9,11..21（含 `BS_8x8=17`）。
   有损路径首个块即分歧；无损走 `cbw4==cbh4==1` 分支所以从未暴露。
2. `decode_coefs` 非 2D（H/V）变换的 DC hi-token 上下文：必须用 DC 处
   `get_lo_ctx` 返回的 `hi_mag`，原实现丢弃后沿用了 AC 循环残留值。
3. palette 索引与 tx_size 的**符号顺序**：dav1d 是
   palette → filter_intra → palette 索引 → tx_size；原实现在 tx_size 之后
   读索引。无损时 tx_size 不读符号，顺序错也通过。
4. 逆变换 1D 类型表方向：dav1d 的 DSP 赋值对非对称类型做了行列转置
   （`[ADST_DCT] = inv_txfm_add_dct_adst`、`[V_DCT] = identity_dct`），
   原表按名字序，导致所有混合类型（DCT+ADST/FLIPADST/IDENTITY）错，
   同类型组合因对称而通过。
5. 逆变换核自身：`inv_adst16_1d` 的第二级旋转读到了被覆盖的中间量；
   `inv_dct64_1d` 多处系数转录错误（-2824/-1474/-2191）与 SSA 名混淆，
   改为脚本从 C 源机械生成（357 条语句的 SSA 版本）。

新增 `libavcodec/av1_lf.mbt`：`lf_mask.c` 的 intra 掩码/level cache /
`calc_eih` / `calc_lf_values`，`loopfilter_tmpl.c` 的 4 个 C 核，以及
`lf_apply_tmpl.c` 的列/行驱动（单 tile；多 tile 有损显式拒绝）。
整帧解码完成后按超级块行依次做「列→行」滤波，对 intra 帧与 dav1d 的
逐行时序等价（预测已消费未滤波像素，行间只读上一行）。修复了
chroma 掩码 `sidx` 的移位（应为 `sidx << vbits/hbits`，此前写成
`sidx * vbits`）、行滤波 level 的重复行偏移、行分量漏加 `+1`、
64x64 行级别指针基准等错误。

契约收紧：有损帧在 CDEF 强度非零、任一平面环路恢复类型非零、
`delta_lf_present` 时仍显式拒绝（`cdef` 强度位已完整解析保存）。

验证：
- 符号轨迹：8 帧逐符号与 dav1d 完全一致（含 palette/CFL/所有 token）。
- 逆变换：155 个 (RectTxfmSize, TxfmType) 组合的 `inv_txfm_add` 校验和
  与 dav1d DSP 逐值一致，固化在 `libavcodec/itx_probe/itx_probe_test.mbt`。
- 像素：未滤波重建与 dav1d（`inloop_filters=0`）逐字节一致；
  带环路滤波的 8 帧 framemd5 与 `linuxserver/ffmpeg:9.0.2`（libdav1d）
  完全一致，向量见 `libavcodec/av1_lossy_vectors/av1_lossy_test.mbt`
  （libaom crf30、`-enable-cdef 0 -enable-restoration 0`、128x96）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **864/864**。

## 53. 2026-10-25 AV1 CDEF（约束方向增强滤波）

新增 `libavcodec/av1_cdef.mbt`：dav1d `cdef_tmpl.c` 的
`cdef_find_dir`（八方向代价 + 方差）与 `cdef_filter_block`（主/次抽头、
`constrain`、主+次分支的 min/max 钳制），以及 `cdef_apply_tmpl.c` 的
单线程逐块调度（cdef_idx/强度/方向/边缘标志）。

实现要点：
- 每 128x128 区域的 `cdef_idx[4]` 与 `noskip_mask[16][2]` 挂在
  `Av1Filter` 上：前者在 `decode_b` 读 cdef 索引时按 64-SB 槽位
  （`((bx&16)>>4)+((by&16)>>3)`）写入（此前所有 64-SB 共用槽 0，
  导致 3/4 的块被漏滤）；后者按 dav1d 的 4x8 位布局在 `!skip` 时填充。
- 滤波在 LF 之后进行，但先对整帧做一次**未 CDEF 快照**：CDEF 每个
  8x8 块只读快照、写当前帧。对 intra 帧这与 dav1d 的逐 SB 行+2 行滞后
  调度等价（deblock 不能消费 CDEF 输出），实现上更简单。
- `cdef_find_dir` 只在 luma 主强度或 chroma 主强度非零时计算；luma
  次强度单开时 dav1d 传 `dir=0`（这是本轮最后一个差异点）。
- 4:2:0 色度用 4x4 核、damping-1；4:2:2 用 4x8 核与 uv 方向映射。

验证：libaom crf30（`-enable-restoration 0`，CDEF 开启）128x96 8 帧，
逐块 (bx,by,cdef_idx,yl,uvl,dir,var,edges) 与 dav1d 完全一致，
framemd5 8/8 与 FFmpeg 9.0.2（libdav1d）一致；向量见
`libavcodec/av1_lossy_vectors/cdef_test.mbt`。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **865/865**。

## 54. 2026-10-25 AV1 逐 SB delta-q 与 tile 边界修正；LR 语法层

为接入 SVT-AV1 的环路恢复向量（本机 libaom 在 `-enable-restoration 1`
下仍选择 NONE，只有 SVT/rav1e 实际发出 LR；SVT 同时启用 delta-q），实现
了 `decode_b` 的逐超级块 delta_q：

- `Av1TileCtx` 增加 `last_qidx` 与 `dq_cur[8*6]`；在 SB 原点（`bx/by`
  按 64/128 对齐）于 skip/cdef 索引之后解析 `delta_q` 符号（含
  `3` → n_bits 扩展、符号位、`<< delta_q_res`、clip 到 1..255），并按
  当前 qidx 重建 dequant 表（新增 `fill_dq`，与 `init_quant_tables` 的
  非分割路径一致）。`decode_coefs` 改用 tile 的 `dq_cur`。
- delta_lf 仍未实现（该向量 dlf=false），入口在 `delta_lf_present` 时
  继续拒绝。

顺带修复一个**帧边界裁剪** bug：tile 的 `col_start/row_start/col_end/
row_end` 此前按 SB 对齐（如 160x120 得到 48/32），未按 `bw/bh` 裁剪；
dav1d 的 `setup_tile` 用 `imin(..., f->bw/f->bh)`。该差异使
`prepare_intra_edges` 的 `px_have = imin(sz,(h-y)<<2)` 多读越界行，
导致帧底部 CFL 块的 AC 用到错误的 luma 填充值（同帧可见像素仍完全
正确，只有 CFL 色度错）。修正后 SVT delta-q 向量 6/6 帧 framemd5 与
libdav1d 一致；向量见 `av1_lossy_vectors/deltaq_test.mbt`。

另外把去块滤波核的对拍固化：用 dav1d 的 `loop_filter` C 参考在
4/6/8/16 四种宽度上跑 800 组随机输入，FNV-1a 校验和作为期望值，
新增 `libavcodec/lf_kernel` 回归包（为排查本轮 CFL 伪影时建立）。

LR（环路恢复）本轮完成了**语法层**：帧头 `unit_size[2]` 解析、
`read_restoration_info`（switchable/wiener/sgrproj + subexp + lr_ref
初值）与逐 SB 的 unit 槽位存放（`Av1Filter.lr[3*4]`），8 帧 SVT SGR
向量的 `Post-lr_sgrproj` 轨迹与 dav1d 完全一致。滤波核（Wiener/SGR）
尚未移植，入口仍对非零 `lr_type` 显式拒绝；`av1_lr.mbt` 已含
`sgr_params`/`sgr_x_by_x` 表（脚本自 c->src 提取）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **867/867**。

## 55. 2026-10-25 AV1 ipred edge 缓冲尺寸修正（高帧)

在尝试接入 LR 向量（libaom + mandelbrot 内容可产出 Wiener 类型）时发现：
`ipred_edge` 按 `sb128w * 128 * (sb128h + 1)` 分配，而 dav1d 按
`sbh * sb128w * 128`（`sbh` = 64/128 行超级块行数）。对高度 >128 的帧，
`backup_ipred_edge` 的 `sby = by >> sb_shift` 可超过 `sb128h`，写入越界
（320x240 直接 trap）。改为按实际 SB 行数分配。

新增 320x240 的 SVT-AV1 delta-q 关键帧向量（6 帧，framemd5 与 libdav1d
一致），覆盖多 SB 行、`ipred_edge` 跨行备份与 LF/CDEF 的多行驱动。

LR 部分留待下一增量：本轮实现了 Wiener unit 滤波原型（快照 + 逐 unit），
帧内绝大多数像素正确，但 dav1d 的 LR 按 8 行滞后的 **stripe** 处理，
stripe 顶部（56/120/184 行）使用 `lr_lpf_line` 的两行 + 特殊重复窗口，
与「整 unit 按帧边界钳制」相差 ±1。SGR（3x3/5x5/mix）尚未实现。
入口对任何非零 `lr_type` 仍显式拒绝。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **868/868**。

## 56. 2026-10-25 AV1 有损 4:4:4 / 4:2:2 / 10-bit

此前有损路径只在 8-bit 4:2:0 上验收。补上 libaom 生成的 128x96 关键帧
向量（4 帧，crf30，关闭 CDEF/LR，仅去块滤波）后发现 **4:4:4 未滤波
重建即错**：首块 luma 正确，随后整帧 Y/U/V 全错。

根因是 `decode_b` 里色度变换尺寸取了 `dav1d_max_txfm_size_for_bs`
的**固定 4:2:0 列**（`bs*4+1`）。dav1d 用的是
`...[bs][f->cur.p.layout]`（列 0=y、1=420、2=422、3=444）；4:4:4 时
色度 tx 被取小（如 16x16 块应 16x16 却按 8x8），`decode_coefs` 读错的
系数个数导致**熵解码分叉**，此后连 luma 也错。无损路径强制 4x4 tx，
所以此前的 4:4:4 无损向量发现不了。

修正：按 `monochrome/420/422/444` 选择列。修正后未滤波 4:4:4 首帧
与 dav1d 逐字节一致，带 LF 的 framemd5 也与 libdav1d 完全一致。

新增 `libavcodec/av1_lossy_extra/`：4:4:4、4:2:2（均为 yuv444p/
yuv422p 8-bit）与 10-bit 4:2:0 三条流，各 4 帧 framemd5 对拍。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **869/869**。

## 57. 2026-10-25 AV1 环路恢复（Wiener / SGR）

补齐 AV1 有损关键帧最后一个环内滤波：环路恢复（LR）。照 dav1d 1.5.1
`looprestoration_tmpl.c` / `lr_apply_tmpl.c` / `lf_apply_tmpl.c` 移植：

- **滤波核**（`av1_lr_filter.mbt`）：wiener_filter_h/v/hv + wiener_c 的
  流式滑窗；SGR 的 3x3 / 5x5 / mix 三套（行聚合、A/B 反演、finish 与
  加权）。行缓冲按 dav1d 的 400/390/384 步长组织。
- **应用驱动**（`av1_lr_apply.mbt`）：逐 SB 行、逐 unit 的 stripe 调度，
  8 行滞后 + 每 stripe 56/64 行；unit 左右边界的 4 列备份
  （`backup4xU`）与 `lr_lpf_line` 12 行备份（`backup_lpf`，含跨 SB 行
  顶部 4 行复制与帧末 3 行复制规则）。

对拍方式：先做**核级回归** `libavcodec/lr_kernel`——用 dav1d C 参考
（`looprestoration_tmpl.c` 直接编入）在 w=4/8/13/64/128/256、h=1/2/3/7/
56/64、11 种 edge 组合上跑 1980 组随机输入，FNV 哈希逐例一致。期间
修掉两个移植错误：Wiener `hv` 的中间行必须写临时缓冲（`ptrs[6]` 在
稳态会等于 `ptrs[0]`，先写会破坏仍要被读的窗口）；SGR 的 A/B 目标行
必须用旋转后的指针（`A_ptrs[2]`/`A_ptrs[1]`/`A3_ptrs[3]`），不能写死；
mix 的第二行 3x3 邻居需从 `&A3_ptrs[1]` 起算。

整帧验收（`libavcodec/av1_lossy_lr`）：
- `wt1.ivf` 320x240 ×4（libaom + mandelbrot，Wiener）
- `t5.ivf` 160x120 ×6（SVT-AV1，SGR）
- `lr10.ivf` / `lr10nc.ivf` / `lr12.ivf` 128x96 ×4（10/12-bit 关键帧）
全部 framemd5 与 libdav1d 一致。

整帧测试还暴露出一个**高位深逆变换** bug：`av1_inv_txfm_add` 的
行/列中间裁剪此前固定为 int16（dav1d 的 8-bit 分支），10-bit 时
dav1d 用 `~bitdepth_max << 7` / `<< 5` 的更大范围。固定 int16 会让
大系数块（本例 x=80 的 16x16 H 分块）产生 ±1..47 偏差；改为按
`bd_max` 选择后 lr10/lr12 逐帧一致（8-bit 不变）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **871/871**。

## 58. 2026-10-25 AV1 高位深 4:4:4 / 4:2:2 有损覆盖

在 LR 收敛后补齐高位深非 4:2:0 的有损关键帧向量（libaom，128x96，4 帧，
crf30，LF+CDEF 默认开启）：10-bit 4:4:4、10-bit 4:2:2、12-bit 4:4:4，
framemd5 均与 libdav1d 一致，加入 `av1_lossy_extra`。这同时回归了 §57
的逆变换裁剪修正与高位深 CDEF/LF 在 444/422 布局下的路径。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **871/871**。

## 59. 2026-10-25 AV1 多 tile 有损环内滤波（LF tile 边界强度修正）

补上多 tile 有损帧的最后缺口：去块滤波在 tile 边界处的**变换尺寸档位
修正**（dav1d 1.5.1 `src/lf_apply_tmpl.c` `dav1d_loopfilter_sbrow_cols`
前半，约 331–401 行）。此前 `av1_decode6.mbt` 对 LF/CDEF/LR 开启且
`num_tiles > 1` 的帧显式拒绝；CDEF/LR 本身无 tile 专用逻辑（消费 LF
输出），拒绝解除后即可整帧通过。

实现分三块：

- **右边缘备份**（`src/decode.c` 2734–2742 行的移植）：`decode_tile_sbrow`
  返回后把左上下文 `f.l.tx_lpf_y[by&16 .. +sb_step)` / `tx_lpf_uv` 存入
  `Av1FrameCtx` 新增的 `tile_lpf_y` / `tile_lpf_uv`（每 tile 列行距
  `align_h=(bh+31)&~31`，chroma 为 `align_h>>ss_v`——dav1d 源码里
  chroma 行距在保存处有 `align_h >>= ss_ver` 一句，易漏）；同时每 tile
  行首个 sbrow 在 `start_of_tile_row[by/sb_step]` 记下 tile 行号。
- **tile 列边界修正**（`av1_lf.mbt` `lf_sbrow_cols` 开头）：对每个
  `tile_col >= 1`，取该列首个 SB 的 4x4 起点 `tile_col_start4[tc]`，
  用左邻 tile 的右边缘值钳制列方向掩码档位：`idx = 2*!!(lvl2)+!!(lvl1)`，
  清 0/1/2 三档后置 `min(idx, lpf_y[y-starty4])`。luma 位图 16 位半区
  （`sidx = bit>=0x10000`），chroma 半区 `16>>ss_v` 位、基址
  `(tc-1)*(align_h>>ss_v) + (sby<<sbl2)>>ss_v`。
- **tile 行边界修正**：`start_of_tile_row[sby] != 0` 时用**上一 tile 行
  残留的 above 上下文** `f.a[sb128w*(r-1)+x].tx_lpf_y/uv` 钳制行方向
  掩码（`f.a` 按 tile 行分段，`a_idx = tile_row*sb128w + col_start>>5`，
  与 dav1d 布局一致）；uv 只有 0/1 两档。

新向量（libaom 320x240 crf30，`-g 1`，`tile-columns=1:tile-rows=1`，
均 4 帧、framemd5 与 libdav1d 一致，入 `av1_lossy_extra`）：

- `mt8`：64x64 SB、4:2:0 8-bit 2x2 tile（上一会话备好）；
- `mt444`：64x64 SB、4:4:4 10-bit 2x2 tile——覆盖 `ss_h=ss_v=0` 的
  chroma 半区/基址路径；
- `mtsb128`：**128x128 SB**、4:2:0 8-bit 2x2 tile。扫描发现此前全部
  有损向量（§52–§58）都是 64x64 SB——libaom 的
  `AOM_SUPERBLOCK_SIZE_DYNAMIC` 恒选 64（720p 也是），ffmpeg 9.0.2 又
  没透传 `--sb-size`；该向量改用 debian `aom-tools` 的 aomenc
  `--sb-size=128 --tile-columns=1 --tile-rows=1` 生成（ffmpeg 出
  rawvideo 管道进容器）。这是 128x128 SB 有损链路（LF 的
  `is_sb64=0` 分支）首次被整帧验证。

三条向量解码与 dav1d 逐帧 md5 全部一致。`moon check --target wasm
--deny-warn --no-render` 0 error/0 warning，`moon test --target wasm
--no-render` **871/871**（向量并入既有 test 块，总数不变）。

## 60. 2026-10-25 AV1 逐 SB delta-lf

补上最后一个显式拒绝的帧头特性：`delta_lf_present`。实现完全对齐
dav1d `decode.c` 960–1027 行的符号读取与 `ts->lflvl` 切换：

- `Av1TileCtx` 新增 `last_delta_lf[4]`（每 tile 重置为 0，对应
  `setup_tile` 的 `ts->last_delta_lf.u32 = 0`）与 `lf_lvl_cur[8*64]`
  （SB 级 LF level 表副本，对应 `ts->lflvl`/`ts->lflvlmem` 的指针切换）。
- `decode_b` 在 delta_q 符号之后、同一 SB 原点门控内读取 delta_lf：
  `n_lfs = multi ? (单色 ? 2 : 4) : 1`，CDF 行 `i + multi`
  （`av1_cdf_delta_lf[5][4]`）；`3` → n_bits 扩展、符号位、
  `<< delta_lf_res`、clip ±63。
- 表切换与 dav1d 一比一（用 prev 快照替代指针状态）：全 0 → 回帧级
  `f.lf_lvl`；非 0 且（从 0 变来或值变化）→ `av1_calc_lf_values` 重算
  副本；非 0 未变 → 不动。`create_lf_mask_intra` 改用 tile 的
  `lf_lvl_cur`。
- `av1_calc_lf_values` 补 `lf_delta[4]` 参数：dir0 用 `lf_delta[0]`，
  dir1/2/3 用 `lf_delta[multi ? i : 0]`（chroma 的 level==0 早退在加
  delta 之前判断，与 dav1d `calc_lf_value_chroma` 一致）。

**向量生成的坑**：libaom 的全帧内路径不发 delta_q（`-g 1` 时
`--deltaq-mode=1` 无效），SVT 任意 preset 都只发 deltaq 不发 delta_lf，
SVT 也没有 `enable-deltalf` 参数键。可行组合是 aomenc
`--enable-tpl-model=1 --deltaq-mode=3 --delta-lf-mode=1`
（mode 3 = key frame visual quality，关键帧专用 deltaq）+ `--kf-max-dist=1`。
bookworm 与 trixie 的 aom-tools 各出一条（`dlfm3`/`dlft3`，320x240
crf30，LF 配置不同），均 `multi=false`、4 帧 framemd5 与 libdav1d 一致，
入 `av1_lossy_extra`。`multi=true` 的码流主流编码器产不出
（libaom 硬编码单模式），multi 分支（n_lfs=4/2 + CDF 行 +1）已实现但
暂无向量，同 VP9 复合预测的情况留待手搓码流。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **871/871**。

## 61. 2026-10-25 AV1 环路恢复的 4:2:2 / 4:4:4 / 10-bit 覆盖

LR 的整帧向量此前全是 4:2:0（§57）。本轮补齐格式矩阵，代码零改动——
五条向量全部直接通过，验证的是既有实现：

- `svt42010`：SVT-AV1 420 **10-bit**（320x240 crf35），`lr_type=[SGR,
  Wiener, Wiener]` 的混合 + 逐 SB delta-q——首个高位深 SGR 整帧向量；
- `ts4448` / `ts44410`：libaom 4:4:4 8/10-bit，chroma Wiener（y=NONE）；
- `ts422` / `ts42210`：libaom 4:2:2 8/10-bit，chroma Wiener。

**向量生成的关键经验**：libaom 对 mandelbrot 内容永不启用 restoration，
但换成 `testsrc2`（`-f lavfi -i testsrc2=...`）+ `-aom-params
enable-restoration=1` 后 chroma Wiener 稳定启用；SVT 走 ffmpeg 包装时
只支持 yuv420p/420p10（444/422 输入被静默转成 420，三条探测流 md5
完全相同才发现），SVT CLI（alpine v2.0）也只编 420。444/422 的 LR
只能靠 libaom+testsrc2。rav1e 虽能编 444 10-bit 且 `lr_type=SWITCHABLE`
（每 unit 动态选核，尚无向量覆盖），但其码流带 segmentation（入口仍
拒绝），暂不可用。向量入新包 `libavcodec/av1_lossy_lr_fmt/`。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
`moon test --target wasm --no-render` **872/872**。

## 62. 2026-10-25 AV1 关键帧 segmentation 与 SWITCHABLE 环路恢复

在关键帧路径接入 segmentation：帧头保存每段 ALT_Q/ALT_LF、preskip 与
last_active；量化和 lossless 状态按段计算；块级 seg_id 依 dav1d 的空间
预测、neg_deinterleave 和 preskip/postskip 顺序解码，并写回当前帧 segmap。
SKIP feature 直接设置块 skip；LF 等级按段叠加 ALT_LF。关键帧没有上一参考帧，
temporal/update_map=false 路径仍属于后续 inter 帧工作。

复核 dav1d `get_sbits(gb, 7)` 后确认 ALT_LF 是 **7 位补码**，不是额外
读取符号位；修正了交接草稿中的错误判断。同时修复 LR 多 restoration unit
时四列边界备份的行偏移单位错误。新包 `libavcodec/av1_seg_vectors/` 使用
rav1e 4:4:4 10-bit 的 4 帧关键帧（含 segmentation 与 SWITCHABLE LR），
逐帧 packed MD5 与 libdav1d framemd5 相同：
`6d2e878462c1662a0d512bdfe777939f`、
`409f3b3dba66f0ad7d11d913c562ed9d`、
`4697af2a0fe6608f8d665fb11c1265a9`、
`82650ec88b7303f28d4d9e90bbfc5a56`。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **873/873**。

## 63. 2026-10-25 AV1 帧间帧基础：非缩放单参考运动补偿

新增 `libavcodec/av1_mc_core/`：移植 dav1d 1.5.1 `mc_tmpl.c` 的
`put_8tap_c` 与 `put_bilin_c`，支持 8/10/12-bit、九种 8-tap 水平/垂直
组合、bilinear、单轴/双轴十六分之一像素相位，以及宽或高不超过 4 时的
短滤波器选择。边界抽样按 dav1d 的 edge emulation 重复最近像素。
滤波系数由 dav1d `tables.c` 的 6×15×8 表机械提取，逐行和均为 64。

独立 C 参考程序按 dav1d 的整数舍入与滤波顺序生成 14 组固定像素结果；
新包 `libavcodec/av1_mc_vectors/` 逐像素对拍，覆盖各滤波家族、
8/10/12-bit、帧边界和窄块。大型系数表放进独立 `av1_mc_core` 包，
避免主 `libavcodec` Wasm 白盒测试模块的初始化局部变量超限。
这一步只实现单参考 MC 核；参考帧管理、帧间块语法、复合预测、
缩放/warp 与整帧入口仍需继续。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **874/874**。

## 64. 2026-10-25 AV1 复合预测中间样本与平均合成

在 `av1_mc_core/compound.mbt` 接入 dav1d 1.5.1 的 `prep_8tap_c`、
`prep_bilin_c`、`avg_c` 和 `w_avg_c` 整数路径。`prep` 保留滤波后的
中间精度与高位深偏置，等权/距离加权合成再完成舍入和像素钳制；
复合预测的 mask、wedge、OBMC、warp 和缩放路径仍待后续实现。

先修正 §63 的向量生成位置：当时独立测试包实际只收录了 10 组，
文档误写成 14 组；本轮已把余下 4 组写入并通过。新增两个测试，
用独立 C 参考程序的固定输出逐像素验证 14 组 `prep` 和 3 组
8/10/12-bit 双参考的等权/加权合成（各 2 种合成结果）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **876/876**。

## 65. 2026-10-25 AV1 复合预测逐像素 mask

新增 `av1_mc_core/mask.mbt`，移植 dav1d 1.5.1 `mc_tmpl.c` 的
`mask_c`、`blend_c` 与 `w_mask_c`。支持外部 0..64 mask 对两个
`prep` 中间块加权、已重建像素块混合，以及按两个中间块差值生成
compound mask 和对应像素。差值 mask 的 4:4:4/4:2:2/4:2:0 缩采样
与 `sign` 舍入按 dav1d 的行/列顺序实现。

独立 C 参考程序固定 4 组 8/10/12-bit、三种布局和两种 sign 的输出；
`av1_mc_vectors/mask_test.mbt` 同时对拍像素与缩采样 mask。
OBMC 专用空间掩码、wedge 掩码、warp/缩放和帧间块语法仍待实现。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **877/877**。

## 66. 2026-10-25 AV1 OBMC 水平与垂直重叠混合

新增 `av1_mc_core/obmc.mbt`，按 dav1d 1.5.1 `tables.c` 的
`dav1d_obmc_masks` 与 `mc_tmpl.c` 的 `blend_v_c`、`blend_h_c`
实现 OBMC。垂直路径只混合左侧 3/4 宽度，水平路径只混合顶部
3/4 高度，剩余像素保留原目标块；2/4/8/16/32 像素掩码按
宽度或高度索引，使用整数舍入公式 `(a*(64-m)+b*m+32)>>6`。

独立 C 参考程序固定 5 组 8/10/12-bit 块，覆盖全部掩码尺寸及
两个混合方向；`av1_mc_vectors/obmc_test.mbt` 对拍完整块摘要并
检查输入块不被修改。wedge、warp/缩放、refmvs、帧间块语法与整帧
解码入口仍需后续实现。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **878/878**。

## 67. 2026-10-25 AV1 wedge 复合预测掩码与 inter-intra 掩码表

新增 `av1_mc_core/wedge.mbt`：完整移植 dav1d 1.5.1 `src/wedge.c`
的一次性初始化 `dav1d_init_ii_wedge_masks`——六个 64×64 主模板
（insert_border/transposed/hflip）、三套 16 项 wedge codebook
（heqw/hltw/hgtw，逐尺寸 signs 位掩码）、`fill2d_16x2` 的 444 掩码
裁剪与 422/420 色度下采样（含两种极性的舍入差），以及 inter-intra
的 ii_dc 常量掩码与九个共享 nondc 缓冲（vert/hor/smooth 三平面）。
对外提供 `av1_wedge_mask(layout, bs, sign, wedge_idx)` 与
`av1_ii_mask(layout, bs, mode)`，按 dav1d `enum BlockSize` 值索引，
444 两个 sign 槽位同值（亮度路径极性由操作数顺序处理）。

验证走 docker（`vpxdev-img` 自带 gcc，绕开 apt 网络不稳）：C dump
程序包含真实 `wedge.c`，dump 全部 864 条 wedge 掩码与 84 条
inter-intra 掩码字节，并按 8bpc/16bpc 两份 TU 实例化 `mc_tmpl.c`
用真 `mask_c` 生成 7 组固定 blend 向量；`av1_mc_vectors/wedge_test.mbt`
（`scripts/_emit_av1_wedge_vectors.py` 生成）逐条 FNV-32 对拍掩码、
4 组逐像素 + 3 组校验和比对 blend。期间修掉三处移植坑：MoonBit
`FixedArray::make(n, ref_init)` 会让嵌套引用数组互相别名（主模板
六方向共板、ii 槽位三布局共板，须 `makei` 逐个新建）；dav1d 1.5.1
`wedge_codebook_16_hgtw` 的 idx5/idx6 是 (H,4,4)、(H,4,6)（初抄时
二者颠倒，靠 C-dump 反向暴力搜索裁剪参数定位）；16bpc `mc_tmpl.c`
的 `PXSTRIDE` 是字节跨距（`w*sizeof(pixel)`，误传像素数导致 10-bit
fixture 行错位）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **883/883**。warp/缩放 MC、
refmvs、帧间块语法与整帧解码入口仍需后续实现。

## 68. 2026-10-25 AV1 缩放参考 MC 与 superres resize

新增 `av1_mc_core/scaled.mbt`：移植 dav1d 1.5.1 `mc_tmpl.c` 的
`put_8tap_scaled_c`、`prep_8tap_scaled_c`、`put_bilin_scaled_c`、
`prep_bilin_scaled_c` 与 `resize_c`。环形缓冲实现改写为等价的直接
二维求值：输出像素 (x,y) 的源位置为 `(mx+x·dx, my+y·dy)`（1/1024
单位），8-tap 相位 `(pos>>6)&15` 查 `av1_mc_subpel_filters`（含
w/h≤4 的短滤波行与 phase-0 直通路径）；prep 保留中间精度。resize
按 1/16384 步进查新表 `av1_mc_resize_filter`（64 相位 × 8 抽头，
机械提取进 `tables.mbt`），每个抽头围绕未钳位 `src_x` 独立钳位，
整个抽头和取反（dav1d 全抽头取反存储）。

C 参考按 §67 的 docker 管道（vpxdev-img gcc）实例化真
`mc_tmpl.c`（8bpc/16bpc 两份 TU）：源平面 96×64 加 8px 边距、
LCG 生成，25 组向量覆盖上/下采样步进、双相位、窄块、phase-0
直通、bilinear 与 resize 的 8/10/12-bit；测试侧用同一 LCG 重建
平面并以 FNV-32 锚定（`av1_mc_vectors/scaled_test.mbt`，生成器
`scripts/_emit_av1_scaled_vectors.py`）。修复两处移植错误：resize
的 F[3] 抽头漏了 `src_x=-1` 起点的独立钳位（越界 trap），以及把
C 的 `-(F[0]*…+F[7]*…)` 误读成仅取反首抽头——负号作用于整个和。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **884/884**。warp MC、refmvs、
帧间块语法与整帧解码入口仍需后续实现。

## 69. 2026-10-25 AV1 warp 仿射运动补偿

新增 `av1_mc_core/warp.mbt`：移植 dav1d 1.5.1 `mc_tmpl.c` 的
`warp_affine_8x8_c`（像素）与 `warp_affine_8x8t_c`（prep 中间样本）。
两核共享 15 行 × 8 列水平中间层：每行按仿射模型推进
`mx += abcd[1]`、每列 `tmx += abcd[0]`，相位
`64 + ((tmx+512)>>10)` 查 193 相位 warp 滤波表（机械提取为
`av1_mc_warp_filter`，1544 个系数）；垂直pass 以
`my += abcd[3]`、`tmy += abcd[2]` 查同一表，put 走 `7+ib` 舍入并
钳位，prep 走 `7` 舍入保留中间精度再减 bias。块锚点以显式
`(ox, oy)` 传入，对应 dav1d 传入的源指针。

C 参考沿用 §67/§68 的 docker 管道：8bpc/16bpc 两份 TU 实例化真
`warp_affine_8x8*_c`，112×80 填充平面（块锚 (8,8)），10 组向量覆盖
单位矩阵（相位 64 恒等抽头）、正/负混合 abcd 与 8/10/12-bit 的
put/prep；测试侧同一 LCG 重建平面并以 FNV-32 锚定
（`scripts/_emit_av1_warp_vectors.py`）。本轮一次对拍通过。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **885/885**。MC 核全部就绪；
refmvs、帧间块语法、参考帧生命周期与整帧解码入口仍需后续实现。

## 70. 2026-10-25 AV1 帧间帧头：全局运动、skip_mode 与参考状态

补齐 `av1.mbt` 帧间/switch 帧头的全部缺口，为此前跳过的位与桩：

- **序列头六工具位**：interintra/masked_compound/warped_motion/dual_filter
  与 jnt_comp/ref_frame_mvs 此前 `skip` 丢弃，现读入
  `Av1SequenceParameters`（warp/use_ref_frame_mvs 的帧级位以它们为门）。
- **全局运动**：替换 `PATCHWELCOME` 桩为完整解析（类型三连位 +
  ROT_ZOOM/AFFINE 的 mat[2..5] 与 TRANSLATION 的 mat[0..1] subexp 增量，
  基准取 primary ref 的矩阵或默认）。为此给帧头 BitReader 移植了
  dav1d getbits.c 的 `get_uniform`/`get_bits_subexp`（复用已有
  `inv_recenter`）。
- **skip_mode**：按 dav1d 的 off_before/off_after → before2 两段推导
  计算 `skip_mode_allowed` 与 refs 对，需要 8 slot 的 order hint。
- **frame_size_with_refs**：inter/switch 且非 error-resilient、
  frame_size_override 时逐 ref 读 found_ref 位，命中则从该 slot 拷贝
  尺寸（superres 位仍读）；未命中走显式尺寸。superres 下采样宽度
  补上 dav1d 的 `imax(ds, imin(16, w))` 钳位。
- **短信令 refidx 派生**：`frame_ref_short_signaling` 的完整移植
  （refidx0/3 显式读，其余按 8 slot 的 wrapped order hint 推导，
  含全局最早兜底），此前只 skip(6) 且不填 ref_frame_idx。
- switch 帧的 frame_size_override 强制为 1；reference_select/
  allow_warped_motion 扩展到 switch 帧。
- 新增 `Av1RefSlotState`（order hint/尺寸/GM）与可选参数
  `av1_parse_frame_header(data, seq, ref_slots?=...)`。

向量 `libavcodec/av1_inter_hdr_vectors/`（docker libaom）：testsrc2
-crf 30 的普通 P 帧（identity GM，检验全字段 + tile group 分裂的位
精确性）与 mandelbrot -crf 20 的 P 帧（**LAST 带 ROT_ZOOM 矩阵
[73728,67584,64458,72,-72,64458]，subexp 路径实测**；后续 P 帧
**skip_mode 开启 refs=[0,6]**，覆盖 skip 推导分支）。两向量共用
8-slot 参考池模拟 key 0xFF 刷新。libavcodec 主测试包的 Wasm init
已到局部变量上限，向量放独立包（同 av1_tiles_vectors 惯例）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **887/887**。剩余：refmvs、
帧间块语法、参考帧生命周期与整帧解码入口。

## 71. 2026-10-26 AV1 NEWMV 残差解码原语

新增 `libavcodec/av1_inter.mbt`：移植 dav1d 1.5.1 `decode.c` 的
`read_mv_component_diff` 与 `read_mv_residual`——joint（3 符号）+
每分量的 sign/classes(10)/class0/class0_fp/class0_hp 或
classN[cl]/classN_fp/classN_hp 链，`mv_prec < 0`（整像素）跳过
fp/hp 位；CDF 用 `Av1CdfCtx` 的 mv0/mv1 平铺表（comp[1] 与 comp[0]
同源，dav1d copy 规则）。MVJoint 映射：H=1→x 分量、V=2→y 分量。

C 对拍（docker vpxdev-img）：`dump_mvres.c` 逐字拷贝 dav1d 的两个
函数 + `msac.c`/`cdf.c` 直编（mem pool 链接桩），经公开的
`dav1d_cdf_thread_init_static/copy` 取默认 MV CDF（default 表是
file-static 不能直接引）；LCG 字节流 × 4 组（seed/精度组合）×
400 步，逐步对拍 y/x/rng/dif。`av1_mvres_vectors/`（emit：
`scripts/_emit_av1_mvres_vectors.py`）全部一致。

调试记录（教训）：(1) dav1d 的 `class0_hp` 读取**不带 up 索引**
（永远用行 0，classN_hp 同理）——初版按直觉传了 up 导致第 2 步
rng 分叉；(2) C dump 的 `dav1d_msac_init` 第 4 参是
**disable_cdf_update_flag**，误传 1 得到"永不更新的 CDF"，
与 MoonBit 的允许更新在首步后表值分叉——用"在 i=1 前打印两侧
joint 表"定位；(3) CDF 宏 `CDF1(x)=(32768-x)`，dav1d 内存即镜像
表示，与 MoonBit 提取表一致，勿按 cdf.c 字面值对照。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **892/892**。帧间块语法主体
（skip_mode/is_comp/refidx/comp 类型/interintra/motion_mode）与
refmvs 仍待移植。

## 72. 2026-10-26 AV1 refmvs 候选查找（空间/时域 + gmv + 上下文）

新增 `libavcodec/av1_refmvs.mbt`：移植 dav1d 1.5.1 `src/refmvs.c` 的
`dav1d_refmvs_find` 主体——空间候选（scan_row/scan_col 的单块直扫与
多块步进两种权重形态、top-right/top-left、8x8 分辨率的 secondary
行列）、时域候选（rp_proj 8x8 网格投影 + 右下角补点，首点探
globalmv_ctx）、`mv_projection`（7.9.3 舍入/钳位）、`get_gmv_2d`
（translation/rot-zoom/affine 的块中心投影）与 `fix_mv_precision`；
nearest/secondary 两段稳定冒泡排序、compound 的 same/diff 扩展候选
合并（**dav1d 的 `same` 是 mvstack 尾部别名**，cnt=1 时槽位偏移）、
single 扩展候选、±(block+4)*32 边界钳位与 ctx 输出（单参考
`(refmv<<4)|(gmv<<3)|newmv`，compound 的三分支映射）。

C 对拍（docker vpxdev-img）：`dump_refmvs.c` 直接 include 真
`refmvs.c`，LCG 构造 37×48 空间块阵 + 16×40 时域块（24 seed ×
14 尺寸 × 3 ref 组合 = 1008 例，覆盖单/双参考、bs 1..32、
ROT_ZOOM/TRANSLATION GM），外加 12 组 gmv_2d 与 16 组 projection
单元向量；`av1_refmvs_vectors/`（emit：
`scripts/_emit_av1_refmvs_vectors.py` + 模板 `_av1_refmvs_test_body.tpl`）
全部一致。调试记录：(1) C dump 初版漏设 `use_ref_frame_mvs`，
时域路径被静默跳过（首例 cnt 8 vs 3 暴露）；(2) compound 扩展候选
初用独立数组，cnt=1 时错覆 stack[0]——dav1d 的 same 指针别名语义
是关键；(3) 测试 bs 表把 BS_64x32 误写为 5（枚举值是 4）；
(4) 单参考时 C dump 的 mv1 是未初始化栈内存，emit 侧归零对拍。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **894/894**。剩余：
refmvs 的 init_frame/load-save_tmvs/splat（状态机接线）、帧间块
语法主体与整帧解码入口。

## 73. 2026-10-26 AV1 refmvs 帧初始化（sign 偏置与 mfmv 选择）

`av1_refmvs.mbt` 新增 `av1_refmvs_init_frame`（dav1d 同名函数的
标量部分，单 tile/帧线程路径）：7 个参考的 sign_bias/mfmv_sign/
pocdiff（wrapped order-hint 差与 ±31 钳位），以及时域 MV 的参考
选择——last（slot0，除非 alt-of-last==gold）、bwd(4)/altref2(5)/
altref(6)（须为过去帧）、last2(1) 兜底，共 total 个；ref2cur 取
±diff1（INT_MIN 表示超界）并填 ref2ref 的 21 个投影距离
（unsigned >31 归零）。

C 对拍扩展进 `dump_refmvs.c`：20 组随机 ref_poc/rp_ref/
ref_ref_poc（7-bit order hint 环绕），逐字段对拍 n_mfmvs、三组
偏置、pocdiff、mfmv_ref/ref2cur 与 21 个 ref2ref。调试记录：
(1) **rp_ref 的 has 语义**——dav1d `rnd()%3==0` 是 NULL（无时域），
初版条件写反；(2) F 行的 `ref:cur` 对与 ref2ref 列表间需显式
分隔符，否则解析粘连；(3) 期望表去掉行首标记后 token 下标整体
-1。测试基建：**rnd 状态从全局改为 build 返回尾状态**（MoonBit
测试并行，全局可变状态会数据竞争）。

`moon check --target wasm --deny-warn --no-render` 0 error/0 warning；
`moon test --target wasm --no-render` **895/895**。剩余：
load/save_tmvs、splat_mv、sbrow_init（与 decode 接线）、帧间块
语法主体与整帧解码入口。

## 74. 2026-10-26 AV1 refmvs 行状态与帧间参考上下文

新增 `av1_refmvs_state.mbt`：单线程路径的 37 槽行指针环（MoonBit
用共享行数组表示）、`splat_mv_c`、`save_tmvs_c`、`load_tmvs_c`。
保存遵循 dav1d 的第二参考优先级与 4096 MV 范围检查；加载按
ref2cur/ref2ref 投影，并保持相邻相同 MV 块的 x 快进语义。
`Av1RefmvsFrameState` 串联 sbrow begin/load、find/splat、end/save，
并持有可供后续参考帧使用的 rp 时域图。
另在 `av1_inter_ctx.mbt` 增加帧间参考树、复合方向、滤波器、
mask、jnt 与 DRL 上下文；`av1_inter.mbt` 增加单/双参考索引的
算术解码树，以及单/双参考模式、DRL 与 MV 解码原语。

直接用 dav1d 1.5.1 `refmvs.c` 编译的 C 探针
（`.scratch/av1/state_ref.c`，不入库）核对 64x64 superblock 的
sby=0/1 行映射、双参考保存和时域投影。C 输出 `save -30 40 2
11 22 1`、`load 0 0 1`，与 MoonBit 独立测试一致。
参考树另用 `dump_mvres.c` 的真 MSAC/CDF 构建 C 探针，四种
64 字节输入 × 单/双参考共 8 例，参考索引均与 MoonBit 相同。
核对 `refmvs.h` 发现早期交接文档对 `save_tmvs` 实参的描述有误：
真实调用传 `rt->r + 6`，函数内部再用 `(y & 15) * 2` 选行。

**尚未完成**：状态与 `decode_b` 接线、inter 块语法和重建、参考帧
生命周期、整帧入口、P/B 帧 framemd5 对拍。此阶段不能声称 AV1
迁移完成。`moon check --target wasm --deny-warn --no-render` 无警告，
`moon test --target wasm --no-render` **904/904**。

## 75. 2026-10-26 AV1 refmvs 缩放投影与跨帧传播验证

新增 refmvs 测试覆盖非零 MV 的 LAST/BWD 双向时域投影、2:1 参考帧距离
缩放、8×8 时域 superblock 边界、128×128 superblock 的空间行环，以及
“当前帧 splat/save → 下一帧 load/find”完整传播链。直接编译 dav1d 1.5.1
`refmvs.c` 的 C 探针确认两种方向的投影坐标与保存的原始 MV 一致。
`mv_projection` 的倍率表改为模块级常量，避免每次候选查询重复创建数组。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_refmvs_vectors` **16/16**，全量测试 **907/907**。`moon fmt --check` 在当前 Windows 路径下
因 formatter 生成文件路径不可读而失败；`moon info -p libavcodec` 通过。

## 76. 2026-10-26 AV1 帧间块 MV 入口与参考上下文修正

`av1_inter_ctx.mbt` 修正两个对照 dav1d `env.h` 发现的参考上下文偏差：
只有一个帧内邻块时，`get_comp_ctx` 要把参考索引 `-1` 按 C 的无符号
比较视为后向；`av1_get_bwd_ref_ctx` 的计数顺序是 ALTREF 对 BWD +
ALTREF2，原实现反向。增加七棵参考树对单个参考索引 0..6 的完整
49 格期望值测试。

`av1_refmvs_state.mbt` 增加与 dav1d `splat_intraref`、
`splat_oneref_mv`、`splat_tworef_mv` 对应的发布方法，保存参考索引、
NEWMV/GLOBALMV 标记与 MV。新增 `av1_inter_motion.mbt`，串联复合标志、
单/双参考选择、refmvs 候选、skip mode 及单/双 MV 模式读取；块内其余
语法读取与重建仍需接入 `decode_b`。定向测试覆盖发布标记、skip mode
不消耗算术码以及 segmentation 强制参考的全局 MV。
`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_refmvs_vectors` **22/22**，全量测试 **913/913**；
`moon info -p libavcodec` 通过。

## 77. 2026-10-26 AV1 帧间 MC 坐标桥接

已有 `av1_mc_core` 具备经 dav1d C 向量对拍的 8-tap、bilinear、
复合、缩放、OBMC 和 warp 内核；本节补上 `predict.mbt`，从块 4×4 坐标、
luma 1/8 像素 MV、色度 subsampling 和参考帧尺寸推导单参考 MC 的源像素
位置、1/16 相位，以及缩放路径的 1/1024 起点和步长。提供单参考像素块
预测和复合预测 prep 两个入口，边界由现有内核执行最近边缘像素扩展。
定向测试涵盖负 MV 的 luma/chroma 相位、80×48 参考帧对 64×64 当前帧的
缩放坐标，以及预测/prep 与内核的逐像素一致性。
`av1_mc_vectors` **15/15**，全量测试 **916/916**；
`moon check --target wasm --deny-warn --no-render` 与
`moon info -p av1_mc_core` 通过。

尚需在帧间块解码入口接入参考帧图像、剩余 inter 语法、复合模式与残差
重建，才能解出 P/B 帧。

## 78. 2026-10-26 AV1 refmvs 参考槽位与跨帧投影

新增 `av1_refmvs_refs.mbt`，管理 AV1 的 8 个参考槽位。完成帧的
时域 MV 图及其 7 个参考 order hint 随 refresh mask 保存；下一帧从帧头
的 `ref_frame_idx` 取槽位、检查参考图尺寸，并构造 refmvs 初始化参数。
尺寸判断按 dav1d 的 8 像素向上取整规则。`prepare_header` 将已解析的
inter/switch 帧头直接接入这一流程，包含全局运动、MV 精度与
superblock 尺寸。

测试验证 key 帧槽位刷新、前帧 MV 图保存到后帧 LAST 投影、2:1 距离
缩放、尺寸不匹配时禁用时域图、四个连续 superblock 行的空间环与时域
保存，以及 LAST/BWD 投影相撞时后者覆盖前者。帧头向量测试也调用
`prepare_header`。参考槽位生命周期目前是可供帧间解码器调用的独立
模块；`decode_b` 尚未接入帧间块语法和重建，P/B 帧解码仍未完成。
`moon check --target wasm --deny-warn --no-render`、`moon info -p libavcodec`
通过；`av1_refmvs_vectors` **26/26**，帧头向量 **2/2**，全量测试
**920/920**。

## 79. 2026-10-26 AV1 refmvs 状态机随机对拍与上采样宽度语义

新增 `libavcodec/av1_refmvs_vectors/refmvs_state_parity_test.mbt`（生成器
`scripts/_emit_av1_refmvs_state_vectors.py`）。探针
`.scratch/av1/state_dump.c`（不入库）直接 `#include` dav1d 1.5.1
`refmvs.c`，取 `dump_refmvs.c` 的 static 符号，覆盖五组几何：
64×80/64×56/128×80/128×96/64×72 等（各含奇数尾行与 sb64/sb128），
每个 sbrow 依次 `tile_sbrow_init`、8 次随机 `splat_mv_c`（随机
ref/bs/mf、±4200 MV 触发 4096 保存门限）、`save_tmvs_c`，对
37 槽行环（含奇偶 sby 交换，跳过 dav1d 的 NULL 槽 1/3）、当前 rp
和 16 行 rp_proj 做 31 进制模 1e9+7 哈希；随后每组几何再用三组
`load_tmvs_c`：整幅、部分列 + SB 对齐的次行带、超宽列（内部截断），
源时域图按 3 列 × 2 行的等值游程构造，MV 为 ±64 的倍数，覆盖
正/负投影、ref2cur/ref2ref 缩放、跨 8×8 时域块边界与游程快进。
5 例空间哈希与 15 例投影哈希全部与 C 一致。

对拍陷阱：`load_tmvs` 的 `row_start8` 必须是 superblock 行对齐。
dav1d 清行时用 `&rf->rp_proj[(row_start8 & 15) * stride]` 再线性前进
`row_end8 - row_start8` 行；行带若从 10 起且长 10 行会越过 16 行
环形缓冲（C 侧越界写）。MoonBit 按 `(y & 15)` 逐行取模，只在合法
SB 行带上与 C 等价，因此探针改用对齐行带；这不是移植偏差。

修正 refmvs 宽度语义：dav1d `dav1d_refmvs_init_frame` 的
`iw8/rp_stride` 与参考尺寸门都用 `frame_hdr->width[0]`（superres
上采样后的宽度），不是编码宽度 `width[1]`。`Av1RefmvsReference` /
`Av1RefmvsPreparedFrame` 的 `coded_width` 更名 `upscaled_width`，
`prepare_header` 改传 `hdr.upscaled_width`；尺寸门仍先按 8 像素
向上取整。新增测试验证两个上采样宽度同为 128 的 superres 帧可共享
时域 MV 图，而编码宽度相同、上采样宽度 119 的参考被排除。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_refmvs_vectors` **32/32**，帧头向量 **2/2**，全量测试 **926/926**。

## 80. 2026-10-26 AV1 帧间块复合/inter-intra/motion/filter 语法

新增 `av1_inter_syntax.mbt`，补齐 `decode_b` 帧间分支里 MV 之后的语法：

- 复合 mask：`mask_comp` 判定 seg/wedge，`jnt_comp`（weighted/avg），
  `wedge_comp` + `wedge_idx`（16 符号），以及等概率 `mask_sign`；
- inter-intra：`interintra` 门、4 值 `interintra_mode`、
  `interintra_wedge` 与楔形索引；
- motion variation：可 warp 时三值 `motion_mode`，否则 `obmc` 布尔；
- subpel 滤波器：可切换时按 `filter[dir][ctx]` 读水平/垂直滤波器
  （dual_filter 才读第二个），输出 dav1d `Filter2d` 组合索引。

同时移植 `dav1d_wedge_ctx_lut`、`dav1d_filter_2d` 与
`wedge_allowed`/`interintra_allowed` 尺寸门（32x8、8x32 不参与
inter-intra）。CDF 行宽与 dav1d 一致：interintra_mode/motion_mode/
filter 为 3 符号、wedge_idx 为 15 符号。

对拍探针 `.scratch/av1/inter_syntax_dump.c`（不入库）把 dav1d 1.5.1
`decode_b` 的对应片段原样拷出，用 `dump_mvres.c` 的 MSAC/CDF 设施跑
4 组 LCG 字节流 × 256 次随机上下文调用，逐例比较输出并在每组末尾
校验 `msac.rng`，生成器
`scripts/_emit_av1_inter_syntax_vectors.py` → 独立测试包
`av1_inter_syntax_vectors`（4/4）。

坑：`Dav1dFilterMode` 的顺序是 REGULAR=0、**SMOOTH=1、SHARP=2**
（不是 regular/sharp/smooth），因此 `dav1d_filter_2d` 的三行是
`{0,1,2}`、`{6,7,8}`、`{3,4,5}`。最初按字面初始器猜成
`{0,2,1}`，C 对拍在 subpel_mode=2 时立即暴露；另外
`interintra_wedge` 表只有 7 行，靠尺寸门排除 wedge_ctx 7/8 才不越界。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_inter_syntax_vectors` **4/4**，全量测试 **930/930**。

## 81. 2026-10-26 AV1 warp 邻居匹配与仿射模型推导

新增 `av1_warpmv.mbt`（dav1d `src/warpmv.c` 完整移植）：257 项
`div_lut`、`resolve_divisor_32/64`、`iclip_wmp`、
`get_shear_params`（alpha/beta/gamma/delta 与发散判定）、
`find_affine_int`（int64 最小二乘、对角/非对角权重裁剪）以及
`set_affine_mv2d`（帧级 GM 的 warp 锚定）。

新增 `av1_inter_warp.mbt`：`find_matching_ref` 在 refmvs 行环上沿
块尺寸步进扫描上/左邻域，输出两段 32 位游程掩码（bit 32 表示
top-left / top-right），最多 8 个候选；`derive_warpmv` 按掩码取样
（含 `-off` 左对齐特例）、以 `4 * clip(max(bw4,bh4),4,28)` 为阈值
剔除离群样本、压缩后做仿射拟合，拟合或 shear 检查失败时回退
identity。至此 `motion_mode == MM_WARP` 的矩阵来源齐备（warp MC
核已在 §69 就绪）。

对拍探针 `.scratch/av1/warp_dump.c`（不入库）**直接链接 dav1d
`warpmv.c`**，并原样拷贝 `decode.c` 的 `find_matching_ref` /
`derive_warpmv`（仅把 `t->rt.r`/`t->bx`/`t->by`/`t->ts->tiling.col_end`
换成探针全局）；覆盖 64 个随机矩阵的 shear、64 组点集的最小二乘、
32 组 `set_affine_mv2d`、96 组合成行环的掩码+推导（矩阵/type/
shear 全比较）。生成器 `scripts/_emit_av1_warpmv_vectors.py` →
独立测试包 `av1_inter_warp_vectors`（4/4）。

坑：①拷贝 `derive_warpmv` 时 `bs()` 宏定义在 `find_matching_ref`
尾部被 `#undef`，推导函数内要重新 `#define`；②`find_matching_ref`
假定 `have_top/have_left` 与块位置一致，随机测试若在 `bx=0` 置
`have_left` 会读 `[-1]` 列（C 越界、MoonBit 越界 panic）；
③合成行环的 `by` 需满足 `(by&31)+h4 <= 32`（真实解码中块不跨
superblock 行），否则行环槽位越界。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_inter_warp_vectors` **4/4**，全量测试 **934/934**。

## 82. 2026-10-26 AV1 帧间环路滤波掩码（decomp_tx / mask_edges_inter）

补齐 `lf_mask.c` 的 inter 分支：`av1_decomp_tx` 按 `tx_split` 递归
展开每个 4x4 的 tx 宽度（log2 截到 2）与步长上下文；
`av1_mask_edges_inter` 写块左/上边与内部 tx 边（skip 时跳过内部边），
并回写 a/l 的右/下 tx 宽度；`av1_mask_edges_chroma` 增加 `skip_inter`
参数（intra 调用传 false），从而与 dav1d 的 chroma skip 语义一致。
新增自由函数 `av1_create_lf_mask_inter`（显式传入 4x4 级缓存、
b4_stride、帧宽高、色度移位、mask 数组与 a/l），供后续帧间块解码
调用；intra 路径保持不变。

对拍探针 `.scratch/av1/lfmask_dump.c`（不入库）直接 `#include`
dav1d 1.5.1 `lf_mask.c`，调用真实 `dav1d_create_lf_mask_inter`，
覆盖 8 组合法 block/tx、48 个随机位置、skip、`tx_split`、四种
pixel layout；对 `filter_y`/`filter_uv`/级缓存/a/l 做哈希比较。
生成器 `scripts/_emit_av1_lf_mask_vectors.py` → 独立测试包
`av1_lf_mask_vectors`（1/1，48 组）。

坑：①C 的 chroma 分支只看 `auv != NULL`，不看 layout，I400 调用者
必须传 NULL；探针起初无条件传数组，导致 I400 的 chroma 哈希与
MoonBit 不符；②`case_set_upto16` 的写入个数是 `1<<t_dim->lw`
（未截断），而写入值是 `min(2, lw)`；③`dav1d_memset_pow2[lw]`
写 `1<<lw` 个字节的 `t_dim->h`，两者都按未截断的 lw 取个数；
④最初把 inter 包装改成公开方法时误伤了 intra 函数（同名片段被
全局替换），已按函数切片修复并由关键帧真实码流测试回归。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_lf_mask_vectors` **1/1**，全量测试 **935/935**。

## 83. 2026-10-26 AV1 帧间块语法驱动接线

新增 `av1_inter_block.mbt`：`Av1InterTileState` 维护逐 4x4 的
上/左邻域（dav1d `BlockContext` 的 inter 子集，含 `set_block` 与
`findoddzero` 等价的重叠邻块判定）；`av1_inter_read_block` 按
dav1d `decode_b` 顺序串联参考/MV（`av1_inter_read_block_motion`）、
复合 mask、inter-intra、motion variation（含 `find_matching_ref`/
`derive_warpmv` 与 `allow_warp`）、subpel 滤波器，并把最终块发布到
refmvs。返回的 `Av1InterBlock` 含 refs/mode/DRL/MV/复合类型/wedge/
mask 符号/inter-intra/motion mode/warp 矩阵/滤波器/掩码与 refmvs
find 上下文，可直接供重建使用。

C 源码对照发现一处关键语义：dav1d 1.5.1 的 inter-intra 与 motion
variation **位于单参考 `else` 分支内部**，复合（含 skip mode）块不读
这两个语法；驱动据此只在 `ref1 < 0` 时读取。另修正
`av1_inter_comp_ctx` 单邻块分支：dav1d 对 `ref[0] >= 4` 使用有符号
比较，帧内邻块（-1）不算后向（此前 §76 的测试假设相反，已更新）。

对拍进展（探针 `.scratch/av1/interblock_dump.c` + 生成器，均不入库）：
直接拷贝 dav1d `decode_b` 的 inter 分支（1383–1872 行）并复用真实
`env.h` 上下文函数、refmvs 与默认 CDF，96 组随机码流/邻居/行环下，
**已解码语法字段、refmvs find 上下文、warp 掩码与 `allow_warp` 全部
与 C 一致**；但算术解码器的 `msac` 最终状态仍有差异，尚未定位到
具体 CDF 选择，故本轮不提交该对拍测试，仅提交确定性单元测试
（skip mode 零符号消费、复合块不读 inter-intra/motion、发布结果与
邻域更新）。该差异意味着驱动尚不能宣称位级对拍完成，接线整帧入口
前需继续收敛。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_refmvs_vectors` **34/34**，全量测试 **937/937**。

## 84. 2026-10-26 AV1 帧间块驱动 C 位级对拍收敛

上一节遗留的 `msac` 状态差异定位到参考树上下文，并顺带修正两处
真实偏差：

1. `av1_inter_ref_tree_ctx` 的 **bwd 变体（tree 4）比较方向写反**
   （应等价于 `cnt[0]+cnt[1]` 与 `cnt[2]` 比较，0 表示前者更小）；
   `ref_2_ctx` 即 bwd 上下文，`ref_3/4/5/6` 分别复用
   fwd/fwd_1/fwd_2/bwd_1 变体（与 env.h 的宏别名一致）。
2. dav1d 的 `get_mask_comp_ctx` / `get_jnt_comp_ctx` / `get_filter_ctx`
   **不使用 have_top/have_left**，直接读 a/l 数组（tile 边界预置为
   intra）；驱动此前对缺失邻居传默认 intra 邻块，随机上下文中会选错
   上下文。改为始终传数组值后，msac 状态与 C 完全一致。

修正后，完整对拍（96 组随机码流/邻居/refmvs 行环）在
`scripts/_emit_av1_inter_block_vectors.py` 生成、测试包
`av1_inter_block_vectors` 中比较：refs、复合类型/wedge/mask 符号、
mode/DRL/MV、inter-intra、motion mode、warp type/矩阵、滤波器、
refmvs find 上下文、`msac.rng` 与 `dif>>32`、warp 掩码与
`allow_warp` —— **全部与 dav1d 一致**。生成器复用
`scripts/_av1_inter_block_test_body.tpl`（测试体与数据分离）；探针
`.scratch/av1/interblock_dump.c`/`interblock_gen2.py` 不入库。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_inter_block_vectors` **1/1**（96 组），
`av1_refmvs_vectors` **34/34**，全量测试 **938/938**。

## 85. 2026-10-26 AV1 warp 平面预测驱动

`av1_mc_core/warp.mbt` 新增 `av1_mc_warp_predict_plane`：按 dav1d
`recon_tmpl.c` 的 `warp_affine` 逐 8x8 子块计算变换中心
（`src_x/src_y` 含色度移位）、`abcd`（矩阵 2/3/4/5 减 0x10000）与
相位 `mx/my`（含 alpha/beta/gamma/delta 修正并 `& ~0x3f`），再调用
已对拍的 `warp_affine_8x8` 核；边界由核内最近像素扩展等价于
dav1d `emu_edge`。支持 4:2:0/4:2:2/4:4:4 与 8/10/12-bit。

新增 `av1_mc_vectors/warp_plane_test.mbt`：恒等矩阵逐像素等于源块、
整像素平移（含负向平移的边界钳制）、4:2:0 色度按 2 倍子采样相位
取样。该驱动补齐了 `MM_WARP` 从语法/矩阵推导到像素预测的最后一环；
帧间重建仍缺 OBMC 驱动、inter-intra 混合、复合 mask 合成与残差叠加。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_mc_vectors` **18/18**，全量测试 **941/941**。

## 86. 2026-10-26 AV1 复合预测合成与 warp prep 平面驱动

`av1_mc_core/compound.mbt` 新增 `av1_mc_compound_blend`：按 dav1d
`recon_inter_block` 的分派把两块 `prep` 合成——AVG（`avg`）、
WEIGHTED_AVG（`w_avg`，权重来自 `jnt_weights`）、SEG（`w_mask`，
`mask_sign` 交换输入并参与掩码）与 WEDGE（`mask`，掩码由调用方按
亮度/色度选择，输入按 `mask_sign` 交换）。WEDGE/SEG 的输入顺序与
dav1d `tmp[mask_sign]` / `tmp[!mask_sign]` 一致。

`av1_mc_core/warp.mbt` 新增 `av1_mc_warp_prepare_plane`：与
`av1_mc_warp_predict_plane` 相同的 8x8 相位/ABCD 遍历，改用
`warp_affine_8x8t` 输出复合预测精度的 `prep` 平面（全局 warp 复合的
两参考准备）。

测试（`av1_mc_vectors/compound_blend_test.mbt`）：AVG 与直接 `avg` 核一致；
WEIGHTED_AVG 使用传入权重且忽略 `mask_sign`；WEDGE 在 `mask_sign=0/1`
下分别等价于 `mask(a,b)` / `mask(b,a)`；SEG 等价于 `w_mask` 的对应
符号与输入顺序；warp prep 8x8 与直接 `warp_affine_8x8t` 一致。

`moon check --target wasm --deny-warn --no-render` 无警告，
`av1_mc_vectors` **21/21**，全量测试 **944/944**。

## 87. 2026-10-26 AV1 帧间块预测装配（单/复合/warp）

新增 `av1_recon_inter.mbt`（libavcodec 现依赖 `av1_mc_core`）：
- `Av1InterBlock` 增加 `bs` 与派生 warp 的 alpha/beta/gamma/delta；
- `av1_jnt_comp_weight`：dav1d `jnt_weights` 的距离量化权重
  （`quant_dist_weight`/`lookup` 搜索）；
- `av1_recon_predict_block`：单参考按 `filter2d` 走 put 平面预测，
  `motion_mode=MM_WARP` 且仿射有效时走 warp 平面预测（8x8 相位 +
  派生剪切参数）；复合参考先对两帧做 `prep`，再按
  `av1_mc_compound_blend` 合成（AVG/W_AVG/WEDGE/SEG，WEDGE 掩码
  亮度用 sign 0、色度用 `mask_sign`）；亮度/色度分别按 4:2:0/4:2:2/
  4:4:4 取样。inter-intra、OBMC 与复合 GLOBALMV warp 暂显式返回错误，
  色度 sub8x8 派生也未接入。

新增测试包 `av1_recon_vectors`（3/3）：单参考逐平面与 MC 核一致、
复合 AVG 与 `prep+avg` 一致、WEDGE(sign=1) 与交换输入的 `mask` 一致、
未支持路径返回错误，以及两组 jnt 权重（5/11）核对。

`moon check --target wasm --deny-warn --no-render` 无警告，
全量测试 **947/947**。

## 88. 2026-10-26 AV1 inter-intra 混合与 OBMC 驱动

`av1_recon_inter.mbt` 扩展：
- **inter-intra**：`interintra_type` 为 BLEND 时用 `av1_ii_mask`
  （按 interintra_mode），WEDGE 时用 `av1_wedge_mask(layout, bs, 0,
  wedge_idx)`（II_MASK 语义：亮度 sign 0、色度同样 sign 0），再用
  `blend_pixels` 以掩码加权 intra 样本；由 `av1_recon_predict_block`
  的 `intra` 参数接入，缺失时返回错误。
- **OBMC**：按 dav1d `obmc()` 遍历上/左邻块（refmvs 行环、邻块
  `bs` 尺寸 clip 2..16、每侧最多 `min(ulog2(w4/h4),4)` 个重叠、
  top 高度 `min(bh4,16)>>1` 且预测高度 `(oh4*3+3)>>2`、left 宽度
  `min(bw4,16)>>1`），邻块滤波器由 `Av1InterTileState` 的 filter0/1
  合成 `Filter2d`；重叠块经单参考预测后用 `blend_h`/`blend_v` 写回
  目标子块。色度要求边界像素和 ≥16（dav1d 条件）。`obmc` 参数缺失
  且 `motion_mode=MM_OBMC` 时返回错误。

新增测试（`av1_recon_vectors` 5/5）：II BLEND 逐平面等于
`blend_pixels(inter, intra, ii_mask)`；OBMC 顶部邻块的重叠预测与
直接 `predict + obmc_horizontal` 一致，且 8x8 4:2:0 块按 dav1d 条件
跳过色度 OBMC。

已知未接：色度 sub8x8 派生（bw4==ss_hor/ bh4==ss_v 时邻块 MV 推导）、
复合 GLOBALMV warp、残差系数与加法、`decode_b`/整帧入口。

`moon check --target wasm --deny-warn --no-render` 无警告，
全量测试 **949/949**。

## 89. 2026-10-26 AV1 色度 sub8x8 预测派生

`av1_recon_inter.mbt` 新增 `av1_recon_sub8x8_chroma`：单参考下
4x4/4x8/8x4 luma 块（`bw4==ss_h` 或 `bh4==ss_v`，且仅 4:2:0/4:2:2）
的色度预测按 dav1d `recon_b_inter` 的 sub8x8 规则从邻块运动派生：
- 检查左/上/左上邻块 `ref0>0`，缺任一所需邻居则回退普通块级色度预测；
- 4x4 块由左上、左、上、自身 MV 各预测 2x2 象限拼成 4x4 色度单元；
  4x8/8x4 分别由左/上邻块与自身各占一半；
- 邻块滤波器由 `Av1InterTileState` 的 filter0/1 合成（左上取 `top[bx4-1]`，
  左取 `left[by4]`，上取 `top[bx4]`）；
- 输出为覆盖该 8x8 luma 单元的色度尺寸（4x4 或 4x8），
  `Av1ReconPlanes.cw/ch` 同步修正；
- 若需要 sub8x8 但调用方未提供邻域状态则返回错误（避免静默错像素）。

测试（`av1_recon_vectors` 7/7）：4x4 块的四个象限逐像素等于
左上/左/上/自身 MV 的直接色度预测；缺少邻域时返回错误；既有 II/OBMC
与单/复合用例保持通过。

`moon check --target wasm --deny-warn --no-render` 无警告，
全量测试 **951/951**。

## 90. 2026-10-26 AV1 帧间变换类型选择（txtp）

`av1_decode2.mbt` 把 `decode_coefs` 里的变换类型选择抽成
`av1_decode_txtp`，并补齐帧间路径（此前只实现帧内分支）：
- 早退：`t_dim->max + intra >= TX_64X64` 直接 DCT_DCT；色度先走
  `get_uv_inter_txtp`（32x32 上限只允许 IDTX，16x16 下限剔除
  H/V_FLIPADST 与 H/V_ADST），帧内色度仍用 `dav1d_txtp_from_uvmode`；
- 帧间亮度 `qidx==0` 隐式 DCT_DCT；
- `reduced_txtp_set || max==TX_32X32`：`txtp_inter3[min]` 单 bool
  （`idx ? DCT_DCT : IDTX`）；
- `min==TX_16X16`：`txtp_inter2`（11 符号、基址 12）；
- 其余：`txtp_inter1[min]`（15 符号、基址 24）；
- `decode_coefs` 增加 `luma_txtp` 参数，色度帧间由亮度类型派生；
  无损块仍直接 WHT_WHT，全跳过返回 DCT_DCT。

对拍：`.scratch/av1/txtp_dump.c` 直接链接 dav1d 的 msac/cdf 表，按
2 个 LCG seed × 256 组随机 `(intra, plane, tx, qidx_zero, reduced,
y_mode, y_angle, uv_mode, luma_txtp)` 调用 `txtp_select`，dump
返回值、`msac.rng`、`dif>>32` 与该步实际 CDF 概率；生成器
`scripts/_emit_av1_txtp_vectors.py` 产出
`av1_inter_syntax_vectors/txtp_test.mbt`（逐例校验 txtp/rng/dif）。

踩坑：C 探针的 `CdfContext` 在两个 seed 之间**不重置**（只在最外层
`dav1d_cdf_thread_copy` 一次），最初生成的测试每个 seed 新建 CDF，
seed 1 的 k=281 首次复用 `txtp_inter3[2]` 时概率仍为默认 30770，
而 C 已被 seed 0 自适应到 29321，rng 随即分叉（48964 vs 46720）。
把 CDF 提出 seed 循环后完全一致——这不是实现错误，而是对拍夹具的
状态生命周期写错。

`moon check --target wasm --deny-warn --no-render` 无警告，
全量测试 **952/952**。
