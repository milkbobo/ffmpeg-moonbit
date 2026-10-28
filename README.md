# FFmpeg → MoonBit

本项目将 FFmpeg 9.0.2 的部分算法、解码器和解复用器移植为 MoonBit 包。代码位于 `libavutil/`、`libavcodec/` 和 `libavformat/`；它是按功能逐步验证的移植，尚不能替代完整的 FFmpeg 命令行或全部库接口。

## 当前移植情况

| 范围 | 已可用 | 主要边界 |
| --- | --- | --- |
| H.264 | I/P/B 帧；CAVLC/CABAC；8/9/10/12/14 bit、单色及 4:2:0/4:2:2/4:4:4；多 slice、MBAFF/PAFF、参考帧管理、SEI、去块滤波；Annex B 与 MP4 `avcC` 入口；渐进帧与 MBAFF 帧缺失或截断 slice 的宏块补偿；两条独立 4:2:0 源的 P 帧损坏矩阵（丢 IDR/P 首 slice、丢多个 P slice、截断尾 slice，逐帧 MD5 对齐 FFmpeg） | 错误恢复的色度几何复刻 FFmpeg 的 4:2:0 硬编码（`put_dc` 固定 8x8 chroma/MB、uint8 语义），高位深/4:4:4/4:2:2 流的恢复输出因此与 FFmpeg 的未定义行为区域耦合，明确不在对齐范围；场图片按上游边界明确报错；SP/SI 明确不做。FMO、separate colour plane 和数据分区不在 FFmpeg 9.0.2 的可解码范围内 |
| HEVC | I/P/B 帧；8/10/12 bit、多种色度格式及单色；多 slice、WPP、tiles、去块滤波与 SAO；dependent slice segments 的帧头/CABAC/QP/邻域继承（含 WPP 或 tiles，8/10/12-bit 420 共 81 帧双滤波模式对齐，含 54 帧派生高位深流；另有原生 4:4:4/4:2:2 8/10/12-bit dependent 共 30 帧（6 组流））；PCM（独立 Y/C 精度、CABAC 重启与滤波保护）；transquant bypass 无损残差；implicit/explicit RDPCM（8/10/12-bit、420/422/444/单色，30 帧双滤波模式对齐 FFmpeg 单线程）；跨分量预测（CCP，含 CBF=0 的纯亮度预测色度块、intra/inter 与 skip/bypass 组合，及与 dependent slice segments/PCM 的 4 组 4:4:4 组合验证）；参考列表修改（ref_pic_list_modification，L0/L1 重排与越界拒绝）；persistent Rice 参数自适应（按 luma/chroma × skip/bypass 四类状态跨 TU 保持，WPP 行状态保存/恢复）；tiles 与 WPP 同时启用（High Throughput Intra 4:4:4，含 `cabac_bypass_alignment` 的符号/escape 对齐，6 组 30 帧对齐 HM 16.8 解码，含 2 组 dependent slice segments 与 1 组多独立 slice） | 当前图片引用（SCC）仍缺：FFmpeg 9.0.2 的 native HEVC 解码器对 SCC profile 直接报 PATCHWELCOME，且需要 SCC 编码器生成码流；FFmpeg 9.0.2 自身无法解码 tiles+WPP（单线程 `cabac_init` 用 tile-scan 索引对 picture CTB 宽度取模），该组合因此以 HM 解码输出为参考；RDPCM bypass 保留 FFmpeg 单线程残留模式语义 |
| AAC / MPEG 音频 / FLAC | AAC-LC PCM；AAC SBR（HE-AAC：显式与 ADTS 隐式信令，SBR 头/网格/包络/噪声全语法位级对拍 C 插桩 dump，QMF 分析/合成、HF 生成/调整/limit、双缓冲 Y 与 f_indexnoise/f_indexsine 跨帧状态，8/10/12 kHz 核心率全表）；AAC PS 合成（HE-AACv2 两条真实流完整 PCM 对拍最大差 1；10/20/34 频带、IPD/OPD、HB 和编码负载逐缓冲对拍 C，wasm 8 帧、native 16 帧）；MPEG 音频 Layer I/II/III 定点 PCM；FLAC 无损 PCM（8/16/20/24/32-bit；32-bit 定点/LPC 残差走 64 位路径） | PS 更多随机组合仍可扩充；USAC 等未覆盖；FLAC 32-bit stereo 的 33-bps side channel 明确报错 |
| 其他视频 / 音频 | VP9 profile 0/1/2/3：关键帧与帧间帧（P 帧四种 MV 模式、三路参考、可切换/固定插值滤波、并行提交与计数驱动概率自适应；`comp_inter_blocks` 诊断计数器；参考缩放——scaled MC 双向（libvpx 官方 vp90-2-05-resize 向量 10 帧 MD5 对齐 vpxdec 原生输出，缩放系数 14 位分数步进与 `webm/issues/820` 舍入复刻）、8/10/12-bit、4:2:0/4:2:2/4:4:0/4:4:4；AV1 8/10/12-bit 4:2:0/4:2:2/4:4:4/单色 多 tile 无损关键帧、有损关键帧（8/10/12-bit，DCT/ADST/IDTX 全变换、环路去块滤波、CDEF、环路恢复 Wiener/SGR 与 SWITCHABLE（4:2:0/4:2:2/4:4:4 全布局）、逐 SB delta-q/delta-lf、关键帧 segmentation 的 ALT_Q/ALT_LF/SKIP 与 seg_id 空间预测，多 tile 含 64/128 SB 与 tile 边界强度修正）；AV1 inter 会话入口（含 2×2 tiles、GM warp、隐藏帧/show-existing，5 组真实流 35 帧 MD5 对齐）；AV1 整帧 superres（coded 解码 + resize 上采样 + LR 上采样网格 + scaled 参考 MC，4 组 aomenc 流 34 帧 MD5 对齐）；AV1 整帧 qmatrix（16 级别、Y/U/V 独立级别，13 组 57 帧 MD5 对齐，包含 12-bit 及 4:2:2/4:4:4/单色 inter）；AV1 帧尺寸变化（aomenc resize-mode：KF↔inter 2×/2⁄3 缩放与逐帧随机尺寸的升降双向 scaled MC、非均匀 tile 间距、显式帧尺寸，7 组 168 帧 MD5 对齐 dav1d 原生输出）；AV1 inter 工具组合验证（interintra 含 wedge/smooth、masked compound、OBMC、local warp、dual filter、ref-frame-mvs 的隔离与全开组合共 5 组 70 帧 MD5 对齐 dav1d）；MJPEG、PNG/APNG；Opus SILK/混合/CELT 全模式与多流包级解码 | VP9 复合预测（B 帧，libvpx 编码器无法生成，已用 alt-ref 码流计数探针证实）；AV1 film grain/intrabc 不做；resize×superres 组合会使 dav1d 1.5.1 段错误（无参考，不纳入）；Opus 包丢失隐藏（PLC）未实现 |
| 容器与分片 | MP4/MOV（含 AAC/H.264/HEVC/AV1/VP9/Opus/FLAC 及 H.264+AAC 双轨、单轨 MP3/FLAC 写入器）、Matroska/WebM（含 H.264/HEVC/VP9/AV1/Opus、单轨 AAC/FLAC、VP9+Opus 与 H.264+AAC 多轨写入器；VP9/AV1/Opus 写入器可选 webm/matroska DocType，HEVC 写入器固定 matroska DocType；真实 VP9+Opus WebM 写入经 ffmpeg 解码与本地 VP9/Opus 解码双向验证）、MPEG-TS（含 H.264+AAC 与 HEVC/MP3 stream type 写入器；AAC 自动 ADTS 封装，ffmpeg 9.0.2 可解码）、WAV（含 PCM 8/16/24/32-bit、IEEE float32 与 extensible 写入器；非 PCM 写 fact 块、extensible float 用 0xFFFE + IEEE_FLOAT 子格式，8/16/24/32-bit、float32 与 5.1 输出经 ffmpeg 9.0.2 解码样本逐字节一致）、Ogg（Opus 与 FLAC 读写，真实 Opus 写入经 ffmpeg 解码验证）、裸 AAC/MP3（含 ADTS AAC 写入器，真实 AAC 帧经 ffmpeg 解码验证）；HLS/DASH 通过回调读取 TS/fMP4（HLS AES-128 真实加密流解密+解码验证），含 H.264/HEVC/AV1/VP9/AAC/Opus 单轨 fMP4 初始化段/媒体段写入器、HLS 主/媒体播放列表（含 EXT-X-MAP，fMP4 可由 ffmpeg 播放验证）与 DASH SegmentTemplate MPD 写入器（真实 fMP4 分片经 ffmpeg 播放验证） | 尚无统一播放 API、完整网络协议层或完整 muxer 集合 |
| 基础算法 | 位流、哈希/校验和、AES 等密码算法、数学/时间基及部分 `@v128` 内核 | `libavutil` 其余模块及 `libswscale`、`libswresample` 等尚未整体移植 |

**H.264 取舍**：SP/SI 切片极少使用，本项目不实现其像素重建。入口会明确报错，避免将其当作 P/I 切片产生错误像素。冗余 slice 会在解析头部后丢弃。FFmpeg 9.0.2 自身不解码 H.264 数据分区或 FMO；本移植对数据分区 NAL 明确报错。

错误恢复默认关闭；持久解码器可调用 `set_error_concealment(true)` 开启。恢复帧的 `damaged_macroblocks` 给出补偿的宏块数。渐进帧和 MBAFF 帧都已支持缺失首段、中段或尾段 slice（含截断 slice）；MBAFF 沿用 `h264_slice_init` 的宏块对地址换算，其余按 FFmpeg 的 raster 状态表处理。**场图片不做恢复**：FFmpeg 9.0.2 的 `er_supported()` 对 `field_picture` 直接返回 0，本项目因此明确报错，而不是输出上游从未产生的像素。

表格只描述已实现的功能类别，并不表示任意参数组合或损坏输入都已验证。具体码流、逐帧对拍结果和已知偏差见 [移植过程记录](PORTING_HISTORY.md)。

AV1 帧间帧的基础工作已开始：`av1_mc_core` 提供非缩放单参考的 8-tap 与
bilinear 运动补偿插值、复合预测中间样本及等权/距离加权/mask 合成，
OBMC 水平/垂直重叠混合、wedge 掩码与 inter-intra 掩码表
（444/422/420 全布局、两种极性，含 wedge 复合 blend），缩放参考
MC（8-tap/bilinear put+prep）、superres resize 与 warp 仿射
8x8（put/prep），支持
8/10/12-bit、边界复制和窄块滤波，并与 dav1d C 参考输出对拍。
refmvs 的候选查找、时域加载/保存、superblock 行环和单/双参考
模式/MV 解码原语已加入，并用 dav1d C 随机状态机对拍（16/32 像素
superblock 行环、空间发布、时域保存、缩放投影与等值游程快进）；
参考帧槽位按 coded（dav1d width[0]）网格管理时域 MV 图。MV 之后的
帧间语法（复合 mask/jnt、inter-intra、motion variation、subpel
滤波器）也已与 dav1d C 逐位对拍；warp 邻居匹配与仿射模型推导
（find_matching_ref/derive_warpmv/warpmv.c）同样完成；帧间环路
滤波掩码（tx 展开 / inter 边掩码 / chroma skip）也已移植并与 C 对拍；
帧间变换类型选择（`txtp_inter1/2/3` 与色度 `get_uv_inter_txtp` 派生）
与 var-tx 分区树（`read_vartx_tree`/`txpart` 与 tx 邻域上下文）完成
C 位级对拍；帧间残差遍历（luma 系数树 + 色度 uvtx 循环、系数上下文
与 luma-txtp 映射）也已对拍；块重建已把预测与残差（含逆变换）装配到帧
平面（`av1_recon_b_inter`）。帧头分段已解析 inter 的 REF_FRAME/SKIP/
GLOBALMV 特征，`decode_b` 已加入 skip_mode 前置语法并使用分段 SKIP；
帧间邻域上下文区分「绝对坐标（refmvs/OBMC 行）」与「SB 内坐标（a/l）」。
分段语法已补齐 temporal 预测与旧 segmap 读取、primary reference 特征继承；
CDF 支持独立快照，邻域发布使用 `&31` 并可单独重置 left（§95）。
`Av1Decoder::decode_packet` 现已接入 inter 整帧、8 个参考槽位、primary
CDF/segmap 继承、隐藏帧与 show-existing；主循环按 sbrow × tile 共享时域
MV 投影，完整执行 deblock/CDEF/LR。5 组 libaom 真实码流共 35 个显示帧
与 libdav1d 逐帧 MD5 一致，覆盖普通 P 帧、2×2 tiles、10-bit、帧级 GM warp
和隐藏/重排序帧。film grain、intrabc 仍不做。qmatrix 已接通，验证见下文。
整帧 superres 已接通：coded 宽度解码/deblock/CDEF 后按 dav1d
`resize_c`（`scale_fac(coded, upscaled)` 步长 + `get_upscale_x0` 相位）
水平上采样，LR 在上采样宽度上运行（单元网格用 `sr_sb128w`，
`read_restoration_sb` 按 SuperresDenom 把 coded SB 区间映射到上采样
单元索引，可一 SB 多单元），LR 边界备份行逐行 resize；参考帧按其上采样
宽度参与 scaled MC 与 2×/16× 尺寸限制，refmvs/segmap 继承按 coded 网格
比较。另修复 LR 条带循环未随 dav1d `left += stripe_h` 推进左边界指针的
潜伏问题（sb128 单次调用多条带才触发）。4 组 aomenc superres 真实流
（fixed denom 13/12、全关键帧、random 逐帧变 denom 含非 superres inter 帧）
共 34 个显示帧与 libdav1d 逐帧 MD5 一致；scaled MC 路径首次被真实流覆盖。
新增 qmatrix 的 13 组码流共 57 个显示帧与 libdav1d MD5 一致：包含
关键帧/帧间帧、重排序、8/10/12-bit、4:2:0/4:2:2/4:4:4/单色、色度
delta-q、矩阵级别 0/15，以及 Y/U/V 独立级别与单平面 identity。
矩阵权重的全部 16×2×19 个组合也与原始 dav1d C 初始化结果一致。
inter 的代表性验证已扩大到 12-bit、4:2:2/4:4:4 和单色；帧尺寸变化与
更广 inter 工具组合已在后续轮次接通，见下文。qmatrix 实现和再生步骤见
[qmatrix 交接](AGENT_HANDOFF_2026-10-27_QMATRIX.md)。

AV1 帧级尺寸变化已接通：帧头保存显式 tile 边界数组（均匀与非均匀
`uniform_tile_spacing_flag=0` 间距都按 dav1d `parse_tile_info` 解析，
解码、LF 与 tile 任务全部查表），显式帧尺寸使用序列头的位宽字段。
7 组 aomenc `--resize-mode` 码流（KF 192×128 ↔ inter 96×64 与
128×85 交替、10-bit、qmatrix 组合、mandelbrot 逐帧随机 96~192
尺寸、444/隐藏帧对照）共 168 帧与 dav1d 1.5.1 CLI 原生输出逐帧
MD5 一致，覆盖升降双向 scaled MC 与跨尺寸参考的门控。注意参考基准
不能用 FFmpeg framemd5：它会把尺寸变化的流自动缩放到首帧尺寸再
哈希；改由 dav1d CLI 逐帧输出原生 YUV。resize 与 superres 的组合
会使 dav1d 1.5.1 在首帧后段错误，无参考可用，未纳入。再生与坑见
[resize 交接](AGENT_HANDOFF_2026-10-27_AV1_RESIZE.md)。

AV1 inter 工具组合已用真实码流验证：interintra（wedge/smooth）、
masked compound、OBMC、local warp、dual filter、ref-frame-mvs 的
隔离组合与全开组合共 5 组 14 帧（testsrc2 192x128，aomenc 工具开关
互斥隔离编码决策）与 dav1d 1.5.1 CLI 逐帧 MD5 一致，覆盖 §83-96
各 inter 工具路径的组合使用。
实现与再生步骤见 [superres 交接](AGENT_HANDOFF_2026-10-26_SUPERRES.md)。

HEVC dependent slice segments 已接通帧头、概率状态、QP 与独立 slice
边界继承，支持单独与 WPP 或 tiles 组合。FFmpeg FATE 的 DSLICE A/B/C
各 9 帧在默认滤波与跳过滤波两种模式下均逐帧 MD5 一致。同时修复了
L1 参考索引的 CABAC 上下文、inter 4×4 亮度误用 DST，以及 1080 行图像
底部色度去块滤波的 QP 越界。验证与再生步骤见
[HEVC dependent segment 交接](AGENT_HANDOFF_2026-10-27_HEVC_DEPENDENT.md)。

HEVC PCM 与 transquant bypass 已接通，并保留受保护样本的单侧去块滤波与
SAO 语义。七个原始 PCM 一致性流及四组真实 x265 无损流共 27 帧，在两种
滤波模式下均与 FFmpeg MD5 一致；覆盖 8-bit 420、10-bit 422、12-bit 444、
不同 Y/C PCM 精度及无损单色流。另以保留 slice bytes、改写 VPS/SPS 的
六组派生流补充 54 帧 10/12-bit 420 dependent segment 验证；它们不是原始
高位深编码器一致性样本。详见
[PCM / 无损与高位深交接](AGENT_HANDOFF_2026-10-27_HEVC_PCM.md)。

HEVC implicit/explicit RDPCM 已接通，涵盖 transform skip、bypass、
方向累加及 int16 回绕。HM 16.8 六组流共 30 帧在两种滤波模式下与
FFmpeg 9.0.2 **单线程**输出逐帧一致。bypass 路径保留上游残留色度
模式和方向优先级，因此不声称等同于默认多线程或 HM 编码器重建。
另用原始 C 内核验证 128 组尺寸/方向/满范围随机输入，详见
[RDPCM 交接](AGENT_HANDOFF_2026-10-27_HEVC_RDPCM.md)。

HEVC 跨分量预测（CCP）已接通：Cb/Cr 独立的四步截断一元 scale、色度
CBF=0 时仅由亮度预测生成残差、跳过像素裁剪前的亮度空间残差合成，
并在 intra（原始色度模式为 DM）与 inter 下按 PPS 开关门控。HM 16.8
六组 4:4:4 五帧流共 30 帧在两种滤波模式下与 FFmpeg 9.0.2 **单线程**
输出逐帧一致，另有原始 C 合成循环生成的 576 组尺寸/scale/随机输入
摘要。本轮同时把 DPB 槽位改为按需分配帧缓冲与运动场（对齐上游
`alloc_frame`），把 dependent 流的测试峰值内存从约 3.2 GB 降到
可稳定通过全量的水平。详见
[CCP 交接](AGENT_HANDOFF_2026-10-27_HEVC_CCP.md)。

HEVC 参考列表修改（ref_pic_list_modification）已接通：按 slice 的
`list_entry_l0/l1` 对 RPS 候选串接结果重排，越界索引报错，依赖
slice segment 沿用独立段的列表。HM 16.8 的 scratch 构建补丁在
`HM_RPLM=1` 下反转每条活动列表并如实写入语法；P 低延迟、层次 B 与
8/10/12-bit 420/422/444 共 33 帧在两种滤波模式下与 FFmpeg 9.0.2
**单线程**输出逐帧一致。persistent Rice 参数自适应在当轮尚未覆盖，夹具
显式关闭该工具，避免把它混入 RPLM 结论；该工具已在后续轮次接通
（见下文）。详见
[RPLM 交接](AGENT_HANDOFF_2026-10-27_HEVC_RPLM.md)。

HEVC persistent Rice 参数自适应已接通：`stat_coeff[4]` 按帧内位置
（luma/chroma × transform-skip-or-bypass）跨 TU 保持，独立 slice 与
tile 起点清零，dependent 段与 WPP 行按上游规则继承/恢复，剩余系数
阈值比较与增减完全对齐 C。HM 16.8 的 4:4:4 10-bit、4:2:2 12-bit WPP、
4:2:0 8-bit 与 4:4:4 10-bit dependent segment 四组流共 29 帧在两种滤波
模式下与 FFmpeg 9.0.2 **单线程**输出逐帧一致。同时修正切片头内联 short-term RPS 漏读
`inter_ref_pic_set_prediction_flag` 的潜伏问题。详见
[persistent Rice 交接](AGENT_HANDOFF_2026-10-27_HEVC_PERSISTENT_RICE.md)。

HEVC CCP 与 dependent slice segments/PCM 的组合已单独验证：HM 16.8 的
四组 4:4:4 流分别覆盖 CCP×dependent（8/10-bit 各一）、CCP×PCM（强制
transquant bypass 的噪声源）与三者全开，共 20 帧在默认滤波与
`-skip_loop_filter all` 两种模式下与 FFmpeg 9.0.2 **单线程**输出逐帧
一致。流内 `dependent_slice_segments_enabled_flag`、`pcm_enabled_flag`
与 `cross_component_prediction_enabled_flag` 已用 FFmpeg `trace_headers`
核对，PCM 路径经插桩确认每流 20 个 PCM CU。详见
[CCP 组合交接](AGENT_HANDOFF_2026-10-28_HEVC_CCP_COMBO.md)。

HEVC tiles 与 WPP 同时启用已接通并验证：该组合仅 High Throughput Intra
4:4:4 profile 允许，HM 16.8 的六组流（64×64 2×2 tiles 8/10-bit、192×128
非方形 tile 8-bit，以及 dependent/多 slice 变体）共 30 帧与 HM 解码
输出逐帧 MD5 一致。实现按
`TDecSlice` 以 slice header 的 entry point 偏移定位每个子流（偏移按
EBSP 计数，经 `H2645Nal` 新记录的防竞争字节位置映射回 RBSP），每个
tile 的每个 CTU 行独立重启 CABAC，并按上右 CTU 的同 slice/tile 可用性
继承上下文；同时补上 RExt `cabac_bypass_alignment`（对齐后按原始字节
读取符号与 escape 值）。HT 配置默认开启 CCP，流内命中 4262 次
`cross_component_scale` 语法，故 CCP 与 tiles+WPP 的组合一并覆盖（intra）。
另两组 8-bit 流（64×64 与 128×128，后者每 tile 2×2 CTU、含 tile 内
WPP 行首的依赖段）把 dependent slice segments 与 tiles+WPP 也组合
覆盖（每帧 1 独立 + 15 依赖段）；第 6 组为每 2 CTU 一个独立 slice
（每帧 8 slice，含 tile 内 WPP 行首起 slice）。**FFmpeg 9.0.2 无法解码该组合**（单线程
`hls_decode_entry` 的 `cabac_init` 用 tile-scan 索引对 picture CTB 宽度
取模，实测输出 PSNR 仅约 10 dB），因此本组夹具以 HM 解码输出为参考，
FFmpeg 仅用于把原始 YUV 哈希成 framemd5。详见
[tiles+WPP 交接](AGENT_HANDOFF_2026-10-28_HEVC_TILES_WPP.md)。

## 构建与测试

在本目录运行：

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render
moon info --target wasm
```

最近一次完整验证（2026-10-28）：`moon check --target wasm --deny-warn --no-render` 通过，Wasm 测试 **1091/1091** 通过。H.264 等真实码流测试将输出与 FFmpeg 9.0.2 对拍；测试素材和生成说明位于各 `*_realdata_wbtest.mbt` 与 `*_test.mbt` 文件及 `scripts/`。

## 代码位置

- [libavcodec/](libavcodec/)：视频、音频解码与码流处理。
- [libavformat/](libavformat/)：容器解复用、分片读取与参数桥。
- [libavutil/](libavutil/)：基础算法和数据结构。
- [PORTING_HISTORY.md](PORTING_HISTORY.md)：详细实现记录、验收矩阵和排错笔记。

## 许可证

本移植遵循 [LGPL-2.1-or-later](LICENSE.md)。许可证正文见 [LGPL 2.1](COPYING.LGPLv2.1) 和 [LGPL 3](COPYING.LGPLv3)。
