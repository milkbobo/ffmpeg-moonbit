# FFmpeg → MoonBit

本项目将 FFmpeg 9.0.2 的部分算法、解码器和解复用器移植为 MoonBit 包。代码位于 `libavutil/`、`libavcodec/` 和 `libavformat/`；它是按功能逐步验证的移植，尚不能替代完整的 FFmpeg 命令行或全部库接口。

## 当前移植情况

| 范围 | 已可用 | 主要边界 |
| --- | --- | --- |
| H.264 | I/P/B 帧；CAVLC/CABAC；8/9/10/12/14 bit、单色及 4:2:0/4:2:2/4:4:4；多 slice、MBAFF/PAFF、参考帧管理、SEI、去块滤波；Annex B 与 MP4 `avcC` 入口；渐进帧与 MBAFF 帧缺失或截断 slice 的宏块补偿 | P 帧大缺口、高位深等复杂恢复场景尚未逐像素对齐 FFmpeg；场图片按上游边界明确报错；SP/SI 明确不做。FMO、separate colour plane 和数据分区不在 FFmpeg 9.0.2 的可解码范围内 |
| HEVC | I/P/B 帧；8/10/12 bit、多种色度格式及单色；多 slice、WPP、tiles、去块滤波与 SAO | dependent slice、tiles 与 WPP 的组合、PCM/RDPCM 等仍缺 |
| AAC / MPEG 音频 / FLAC | AAC-LC PCM；AAC SBR（HE-AAC：显式与 ADTS 隐式信令，SBR 头/网格/包络/噪声全语法位级对拍 C 插桩 dump，QMF 分析/合成、HF 生成/调整/limit、双缓冲 Y 与 f_indexnoise/f_indexsine 跨帧状态，单声道隐式 PS 复制输出，8/10/12 kHz 核心率全表）；MPEG 音频 Layer I/II/III 定点 PCM；FLAC 无损 PCM | AAC 的 PS 合成（参数化立体声）、USAC 等未覆盖 |
| 其他视频 / 音频 | VP9 profile 0/1/2/3：关键帧与帧间帧（P 帧四种 MV 模式、三路参考、可切换/固定插值滤波、并行提交与计数驱动概率自适应；`comp_inter_blocks` 诊断计数器）、8/10/12-bit、4:2:0/4:2:2/4:4:0/4:4:4；AV1 8/10/12-bit 4:2:0/4:2:2/4:4:4/单色 多 tile 无损关键帧、有损关键帧（8/10/12-bit，DCT/ADST/IDTX 全变换、环路去块滤波、CDEF、环路恢复 Wiener/SGR 与 SWITCHABLE（4:2:0/4:2:2/4:4:4 全布局）、逐 SB delta-q/delta-lf、关键帧 segmentation 的 ALT_Q/ALT_LF/SKIP 与 seg_id 空间预测，多 tile 含 64/128 SB 与 tile 边界强度修正）；AV1 inter 会话入口（8/10-bit 4:2:0，含 2×2 tiles、GM warp、隐藏帧/show-existing，5 组真实流 35 帧 MD5 对齐）；AV1 整帧 superres（coded 解码 + resize 上采样 + LR 上采样网格 + scaled 参考 MC，4 组 aomenc 流 34 帧 MD5 对齐）；MJPEG、PNG/APNG；Opus SILK/混合/CELT 全模式与多流包级解码 | VP9 复合预测（B 帧，libvpx 编码器无法生成，已用 alt-ref 码流计数探针证实）与参考缩放；AV1 整帧 qmatrix 尚缺（superres 已接通），film grain/intrabc 不做；inter 更广格式与尺寸变化待验证；Opus 包丢失隐藏（PLC）未实现 |
| 容器与分片 | MP4/MOV（含 AAC/H.264/HEVC/AV1/VP9/Opus 及 H.264+AAC 双轨写入器）、Matroska/WebM（含 H.264/VP9/AV1/Opus、VP9+Opus 与 H.264+AAC 多轨写入器；VP9/AV1/Opus 写入器可选 webm/matroska DocType）、MPEG-TS（含 H.264+AAC 写入器，PMT stream type 可选 HEVC/MP3 等）、WAV（含 PCM 8/16/24/32-bit、IEEE float32 与 extensible 写入器）、Ogg/Opus（读写）、裸 AAC/MP3（含 ADTS AAC 写入器）；HLS/DASH 通过回调读取 TS/fMP4，含 H.264/HEVC/AV1/VP9/AAC/Opus 单轨 fMP4 初始化段/媒体段写入器、HLS 主/媒体播放列表与 DASH SegmentTemplate MPD 写入器 | 尚无统一播放 API、完整网络协议层或完整 muxer 集合 |
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
和隐藏/重排序帧。film grain、intrabc 仍不做，qmatrix 仍明确拒绝。
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
当前 inter 端到端验证以 4:2:0 为限，更广格式和尺寸变化待补。
实现与再生步骤见 [superres 交接](AGENT_HANDOFF_2026-10-26_SUPERRES.md)。

## 构建与测试

在本目录运行：

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render
moon info --target wasm
```

最近一次完整验证（2026-10-27）：`moon check --target wasm --deny-warn --no-render` 通过，Wasm 测试 **976/976** 通过。H.264 等真实码流测试将输出与 FFmpeg 9.0.2 对拍；测试素材和生成说明位于各 `*_realdata_wbtest.mbt` 文件及 `scripts/`。

## 代码位置

- [libavcodec/](libavcodec/)：视频、音频解码与码流处理。
- [libavformat/](libavformat/)：容器解复用、分片读取与参数桥。
- [libavutil/](libavutil/)：基础算法和数据结构。
- [PORTING_HISTORY.md](PORTING_HISTORY.md)：详细实现记录、验收矩阵和排错笔记。

## 许可证

本移植遵循 [LGPL-2.1-or-later](LICENSE.md)。许可证正文见 [LGPL 2.1](COPYING.LGPLv2.1) 和 [LGPL 3](COPYING.LGPLv3)。
