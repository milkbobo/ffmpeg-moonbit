# FFmpeg → MoonBit

本项目将 FFmpeg 9.0.2 的部分算法、解码器和解复用器移植为 MoonBit 包。代码位于 `libavutil/`、`libavcodec/` 和 `libavformat/`；它是按功能逐步验证的移植，尚不能替代完整的 FFmpeg 命令行或全部库接口。

## 源码分发与专利声明 / Source-only distribution and patent notice

**本项目仅以源代码形式开源发布。** 维护者不对外提供或分发 WASM 编译产物、二进制文件、可执行程序、静态库、动态库、`bin/` 目录中的编译产物、预编译包或其他预构建制品。下文构建和测试命令供使用者自行在本地构建。

**本项目包含 H.264/AVC、HEVC/H.265、AAC 等解码器实现，相关技术可能受第三方专利保护。** 源码公开不代表已取得专利许可，也不保证免许可、免版税或不侵权。仅分发源码可减少与预编译产物分发相关的合规负担，但不免除源码分发的许可证义务，也不消除专利或其他法律风险。

**This project is released as source code only.** The maintainers do not publicly provide or distribute WASM build artifacts, binaries, executables, static or shared libraries, compiled artifacts under `bin/`, precompiled packages, or other prebuilt artifacts. The build and test commands below are for local builds by users.

**This project includes decoder implementations such as H.264/AVC, HEVC/H.265, and AAC, whose technologies may be covered by third-party patents.** Source availability does not establish patent clearance or guarantee license-free, royalty-free, or non-infringing use. Source-only distribution can reduce compliance burdens associated with prebuilt artifacts, but does not remove source-distribution obligations or eliminate patent or other legal risks.

本政策不限制适用开源许可证授予的权利。除适用许可证明确授予的专利权利外，本声明不授予额外专利许可。详见 [LICENSE.md](LICENSE.md) 与 [LEGAL.md](LEGAL.md)。

This policy does not restrict rights granted under applicable open-source licenses. Except for patent rights expressly granted under applicable licenses, this notice grants no additional patent license. See [LICENSE.md](LICENSE.md) and [LEGAL.md](LEGAL.md).

### ⚠️ 历史版本提示 / Historical version notice

本仓库早期开发提交未包含专利风险提示。截至本声明更新之日（2026-10-29），所有历史提交快照仅为开发过程中的中间版本，不作为项目正式发行版本。

无论检出任何版本代码，使用者均应自行评估编译、分发及运行相关产物涉及的专利与许可要求，并承担其自身行为依法产生的相应责任。**商用前请自行进行专利与许可证合规评估，并在必要时取得授权。**

历史版本未包含提示，不表示不存在专利风险或已获得相关授权。“非正式发行版本”的描述不否认代码曾被公开或分发，也不撤销既有义务；本声明不免除维护者依法承担的责任，不修改适用开源许可证。

Early development commits in this repository did not include a patent-risk notice. As of this notice's update date (2026-10-29), all historical commit snapshots are intermediate development versions and are not designated as formal project releases.

Regardless of which version is checked out, users should independently assess the patent and licensing requirements associated with compiling, distributing, and running the resulting artifacts, and bear the responsibilities arising under applicable law from their own activities. **Before commercial use, conduct a patent and license compliance assessment and obtain authorization where required.**

The absence of a notice in historical versions does not establish the absence of patent risks or the existence of authorization. Describing a version as an informal development snapshot does not deny that code was made public or distributed, or discharge existing obligations. This notice does not exempt maintainers from their legal responsibilities or amend applicable open-source licenses.

## 当前移植情况

| 范围 | 已可用 | 主要边界 |
| --- | --- | --- |
| H.264 | I/P/B 帧；CAVLC/CABAC；8/9/10/12/14 bit、单色及 4:2:0/4:2:2/4:4:4；多 slice、MBAFF/PAFF、参考帧管理、SEI、去块滤波；Annex B 与 MP4 `avcC` 入口；渐进帧与 MBAFF 帧缺失或截断 slice 的宏块补偿；两条独立 4:2:0 源的 P 帧损坏矩阵（丢 IDR/P 首 slice、丢多个 P slice、截断尾 slice，逐帧 MD5 对齐 FFmpeg）；H.264 编码（`libavcodec/x264/`，native C 绑定：FFmpeg n9.0.2 的 H.264 软件编码本体即 libx264 封装（`libx264.c`），按 moonbit-c-binding 流程绑定——avcodec 编码 API 的薄 C 包装（external object 句柄 + finalizer、平面拷入/包拷出、失败句柄模式）+ 私有 extern + 安全 MoonBit 层（`X264Encoder::open/send_frame/receive_packet/send_eof/flush/extradata/close`、`x264_supports` 能力探测），yuv420p/yuv420p10le，`thread_count=1` + BITEXACT 默认开启保证确定性；96×64×33 帧确定性夹具的 ultrafast/Baseline（CAVLC 无 B）、medium/High（CABAC + 8x8 + B 金字塔）与 High 10 三组流，经本仓库纯 H.264 解码器与 FFmpeg C 解码器（AVParser 切 AU 的进程内 oracle）**逐像素对拍一致**；`global_header` 的 Annex B 参数集 extradata 走 movenc 式 avcC 构建 + 4 字节长度前缀样本路径，SPS 的 profile_idc=100/chroma_format_idc/bit_depth 与纯 `h264_ps` 解析同验；双跑逐字节一致回归固化确定性；wasm 构建视该包为空，宿主 wasm 全量不受影响）。**纯 MoonBit H.264 编码器第一切片（§376）**：I 帧（IDR 单 slice、CAVLC、Baseline 4:2:0 8-bit、平 QP，I_PCM/I16/I4x4），逐行镜像自家解码器（参数集写后即 `h264_ps` 回读、预测/重建直调 `h264_pred*`/`h264_idct*`、残差写码逐表逆向 `h264_decode_residual`、nC/模式预测镜像），本地重建与自家解码器输出逐字节相等（构造保证）；CAVLC 残差性质测试 3000 随机模式写→读逐值相等；docker ffmpeg 9.0.2 外部仲裁零告警且 framemd5 `92f60474…` 与自家开滤波解码器逐位一致（MD5 钉死回归，含去块滤波验证）；I_PCM 无损、确定性、QP 阶梯单调、奇尺寸裁剪路径。**P 帧切片（§377）**：P_Skip + P_L0_16x16（CAVLC、单参考、平 QP），`h264_encode_frames` GOP 序列；MV 预测逐行复刻 `h264_pred_motion`/`h264_mv_fetch`/`h264_pred_pskip_motion`，MC 直调 `h264_mc_luma/chroma`，ME 为 ±16 整素 SAD + MC 四分素精化（零 MV 偏置），inter 残差走反量化矩阵 3/4/5；mb_skip_run 片尾残留写出；量化定标修正为 3 类 `2^17/init`（13107 族）+ 解码器镜像填充 `(level*qmul+32)>>6`；外部仲裁 I+P 四帧 framemd5 `e454d8…/a8a44b…/970f51…/87806a…` 与 ffmpeg 逐帧一致（钉死回归） | 错误恢复的色度几何复刻 FFmpeg 的 4:2:0 硬编码（`put_dc` 固定 8x8 chroma/MB、uint8 语义），高位深/4:4:4/4:2:2 流的恢复输出因此与 FFmpeg 的未定义行为区域耦合，明确不在对齐范围；场图片按上游边界明确报错；SP/SI 明确不做。FMO、separate colour plane 和数据分区不在 FFmpeg 9.0.2 的可解码范围内。编码器是 native-only C 绑定（须在 `ffmpeg-moonbit-ffref:nine-x264` 镜像内运行；libx264 为 GPL 组件，`--enable-gpl` 只作用于该测试镜像层，MoonBit 侧源码仍为 LGPL；x264 的 4:2:2/4:4:4 与 8/9/12/14-bit 编码面未接） |
| HEVC | I/P/B 帧；8/10/12 bit、多种色度格式及单色；多 slice、WPP、tiles、去块滤波与 SAO；dependent slice segments 的帧头/CABAC/QP/邻域继承（含 WPP 或 tiles，8/10/12-bit 420 共 81 帧双滤波模式对齐，含 54 帧派生高位深流；另有原生 4:4:4/4:2:2 8/10/12-bit dependent 共 30 帧（6 组流））；PCM（独立 Y/C 精度、CABAC 重启与滤波保护）；transquant bypass 无损残差；implicit/explicit RDPCM（8/10/12-bit、420/422/444/单色，30 帧双滤波模式对齐 FFmpeg 单线程）；跨分量预测（CCP，含 CBF=0 的纯亮度预测色度块、intra/inter 与 skip/bypass 组合，及与 dependent slice segments/PCM 的 4 组 4:4:4 组合验证）；参考列表修改（ref_pic_list_modification，L0/L1 重排与越界拒绝）；persistent Rice 参数自适应（按 luma/chroma × skip/bypass 四类状态跨 TU 保持，WPP 行状态保存/恢复）；tiles 与 WPP 同时启用（High Throughput Intra 4:4:4，含 `cabac_bypass_alignment` 的符号/escape 对齐，6 组 30 帧对齐 HM 16.8 解码，含 2 组 dependent slice segments 与 1 组多独立 slice） | 当前图片引用（SCC）仍缺：FFmpeg 9.0.2 的 native HEVC 解码器对 SCC profile 直接报 PATCHWELCOME，且需要 SCC 编码器生成码流；FFmpeg 9.0.2 自身无法解码 tiles+WPP（单线程 `cabac_init` 用 tile-scan 索引对 picture CTB 宽度取模），该组合因此以 HM 解码输出为参考；RDPCM bypass 保留 FFmpeg 单线程残留模式语义 |
| AAC / MPEG 音频 / FLAC | AAC-LC PCM；AAC-LC 编码器（`aac_encode.mbt`：正弦窗长窗 + 1024 点 MDCT、逐带在码本 1..11 中选最小位耗码本（codebook 11 走 escape，量化幅度上限 8191）、整帧单标度因子 + 以参考标度因子为中心的全局 delta 二分（取仍装得下帧预算的最小 delta，按目标码率填满）、单声道 SCE / 立体声独立双 ICS + ADTS 封装；ffmpeg 9.0.2 可直接解码 44.1 kHz 立体声 9 帧流，实测 119.7 kbps（目标 128 kbps 的 93.5%）、往返 SNR 29.97 dB / PSNR 39.8 dB，ffmpeg 解码输出与本仓库解码器差 0.0008 MSE（亚 LSB）；3GPP 心理声学模型独立移植（`aac_psy.mbt` + `aac_psy_vectors/`：`aacpsy.c` 全链路——Bark/ATH 静态系数、双向扩散、预回声控制、PE 与比特池需求、reduction 两轮估计与 linearization，5 帧×49 带对拍 FFmpeg 9.0.2 参考，整数决策逐位一致、浮点相对误差 ≤5e-4；twoloop 量化器同层移植（`aac_twoloop.mbt` + `aac_twoloop_tables.mbt` + `aac_twoloop_vectors/`：`aaccoder_twoloop.h` 的 `search_for_quantizers_twoloop` 全链路——逐带 `find_max_val`/form factor/最小码本选择、`quantize_and_encode_band_cost` 的 RD 成本（codebook 0 的零带短路、codebook 11 escape 分支按 `165140.0*IQ` 截断）、内层按帧预算收敛 30 轮与外层逐带失真调整及 band 移除，表与 `pow2sf/pow34sf` 由 C dumper 零转录提取；5 帧×49 带 `sf_idx`/`band_type`/`zeroes` 逐位一致、maxval 相对误差 ≤1e-5，连参考侧 30 轮跑满与 `sf0` 在 127/131/132/136/137 间振荡都复现；两者可组合成可选码率控制链（`aac_encode_config_perceptual`：`ONLY_LONG` 长窗帧（ONLY_LONG 与两个过渡窗）走 psy→twoloop→λ 严格重试，只有 8 短窗帧仍走简化模型；默认路径不变，因此 117.1 kbps / 29.05 dB 的往返指标不受影响；感知路径实测 125.8 kbps / 21.5 dB（§291 把 M/S 挪到 twoloop/PNS 之后、分析改读左右谱，比 §279 的 122.7 kbps / 20.1 dB 高 1.4 dB；§295 换上真 `search_for_ms` 后码长 +2 B/帧、SNR 让出 0.3 dB；§297 把 §289 偏差 2 闭环——λ 重试的每一轮都重跑 psy `analyze`（上游的 element 循环整个在重试 `do-while` 里，第二轮读到第一轮消费过的 bit reservoir），取 ABR 分支的系数恢复语义 + 严格分支的 λ 规则，只有真正重试过的帧会变，实测再 +0.49 dB、码长 −1 B/帧；§298 再把 TNS 也挪进同一轮——量化之后、PNS 之前，滤波写进本轮的谱副本、`coefs` 保持干净左右谱，四音指标一字不变（那内容上 TNS 不点火），共享高音夹具只有 TNS 点火的那一帧从 366 变 369 B；§299 再补上每轮的 `adjust_frame_information`——`max_sfb` 改由量化器的 `zeroes[]` 反推（24 kbps 下剪到 19/49）、`ms_mode` 补第三种取值 2（全带标记时不写掩码位）、TNS 带范围改用上一轮/上一帧的 `max_sfb`（因此流的第一帧必然不发滤波器）；三个码率的 `max_sfb` 与 §298 完全相同，属结构闭环，至此感知路径与 `aacenc.c` 的 element 循环同构；§300 再补齐 3GPP 模型的**八短窗形态**——`calc_thr_3gpp` 的 `w += 16` 逐窗外层、44.1 kHz 下 14 带 × 8 窗的短窗带计划与 `psy_coef[1]` 短窗扩散常量、`cutoff` 除以窗数、`PSY_3GPP_AH_THR_SHORT`（按 f32 存 0.6299999952316284）、短窗那组 `calc_bit_demand` 斜率、只有窗口 0 读上一帧的预回声，发布布局换成 C 的 `psy_bands[w * 16 + g]` 槽位数组；harness 新 `--short` 模式（长窗输出逐字节不变）给出 5 帧 × 8 窗 × 14 带 = 560 条黄金记录，`bits`/`alloc`/`fill_level` 逐位一致、最坏相对误差 energy 1.7e-7 / threshold 4.9e-6，而上游那条"`spread_en[0]` 而不是 `spread_en[w]`"的怪癖也一并照抄；编码器仍只把长窗帧交给感知路径，三条端到端流与 §299 逐字节相同；§301 再把 twoloop 量化器也扩到**按窗分组**——新入口 `AacTwoShape`（1 长窗 / 8 短窗 + `group_len`），C 的 15 处 `for (w = 0; w < num_windows; w += group_len[w])` 外层全部补齐，一个窗组共享一条标度因子与一个码本、带成本按组内 `group_len` 个窗累加、标度因子差链跨窗组不重置、`ff_pns_bits` 的回看按 `(w<<4)+g-1`、`ff_init_nextband_map` 同形；两条只在短窗才会露面的上游怪癖（形态因子那趟的分母用**窗号当带号索引**的 `swb_sizes[w]`、守卫 `nzs[g]` 只看第一个窗组）连同 DC 带保护与 `8/group_len` 瞬态降权一起照抄。harness 的 `--short` 现在顺手跑真实搜索并轮转 `window_grouping[]` 的前五个字节当分组（组大小 1/2/3 都踩到），266 条 `sf/cb/zeroes` **逐位一致**、`maxvals` 相对误差 ≤1e-5，且用"同一帧换分组必须给出不同标度因子"的回归防住分组被默默忽略；把 `de_psy_factor` 改成常量做变异测试时，向量立刻报 `frame 0 slot 96: sf 115 != 116`），差距经交叉验证不是移植问题——把编码器同一份输入喂回未修改的 C，98/98 带逐位一致，属 3GPP 模型在该码率下的固有行为；用模型自身的噪声-掩蔽比衡量，感知路径 12.83 dB 优于默认路径 14.45 dB（代价是 10 dB 谱 SNR），见 §279/§280/§291/§297；PNS 可用 `aac_encode_config_with_pns` 开启（`mark_pns` → PNS-aware twoloop → `search_for_pns` → 码流 `off_pns` 独立标度因子链 + 9 位前导，三批 245 带黄金数据逐位一致，白噪声夹具 344 B/帧 vs 未开启的 357 B/帧，见 §284–§289；强度立体声可用 `aac_encode_config_with_is` 开启（`aacenc_is.c` 的简化版——FFmpeg 频率门 `6100·(λ/170)` 加带内互相关选带与相位，右声道该带改写为 14/15 带并走独立的 `off_is` 标度因子链、不写谱数据，与 M/S 的带互斥规则和上游一致，§294 起在感知路径上还能与 PNS 同时开（噪声带由 PNS 终值直接排除，同一夹具噪声带数开不开 IS 都是 81/78）；感知路径已换成 `aac_is_encoding_err` 的真成本判据并与 FFmpeg 逐位对拍（§292：4 帧 × 49 带的 `is_mask`/`ms_mask`/右声道带类型/两个 `is_ener`/两相位 `pass`/`is_mode` 全等，64 个强度带，连 `dist1/dist2` 成本量值也逐位相等——为此把 escape 码本的 `c*cbrtf(c)` 从「double cbrt 再舍 f32」改成 C 侧零转录表（2196/8192 个整数输入原本差 1 ulp，§293）；默认路径仍用 §290 的频率门 + 相关性下限，因为它没有 twoloop 的 sf/阈值可定价）；感知路径的 M/S 掩码同层换成 FFmpeg 的 `search_for_ms`（`aac_ms.mbt`，§295：每带四轮 `sid_sf_boost`、`ff_sfdelta_can_replace` 的 ±60 标度因子链守卫、`bmax = bval2bmax(g·17/num_swb)/0.0045` 折扣的 side lambda、判据 `dist2 <= dist1 && B1 < B0`，命中即改写两声道的 `sf_idx`/`band_type`——量化与写码流都吃改写后的终值；4 帧 × 49 带的掩码/boost/两条 sf/两条 cb/`dist1`/`dist2`/mid 带成本/`B1`/`bmax` 与参考逐位相等，67 个 M/S 带；能量掩码只留在简化路径；§296 又把量化器与 PNS 链上残余的「C 单精度常量按十进制原值使用」和 `int *= 1.15f` 的整型截断一次扫清（`C_QUANT`/`0.00125f`/`0.0125f`/`1.15f`/`1.948f`/`0.9f`/`0.7f`/`0.88f`/`0.85f`，以及 `options.pns || options.intensity_stereo` 这条带宽补偿条件），并证明它是**保真而非改行为**：三批 245 带、64 强度带 + 67 M/S 带向量全绿，两个端到端夹具的 ADTS 与 §295 逐字节相同）——共享高音夹具触发 55 带、省 8.5% 码长（1748 > 1599 B），去相关夹具触发 43 带、SNR 22.52 → 24.99 dB，且每声道自己的强音原样回来（−0.13 dB）不串进另一声道（−57.6 dB）；同一条码流经 ffmpeg 9.0.2 解码 0 errors 零告警，与本解码器 PCM 最大差 1.49e-7；§295 起把「感知 + M/S」与「噪声 + PNS + IS」两条流各 9 帧送同一条链路，§297 在新实现上重跑仍是 0 errors 零告警（3163 / 2980 字节），最大差 1.49e-7 / 4.47e-8（SNR 138.971 / 138.404 dB）——M/S 改写后的标度因子链、噪声带上的掩码位与 IS 的 flip 位都被 FFmpeg 自己的解码器原样接受；§297 还把 IS/M/S 夹具的选帧改成按参考侧的工具活跃度自动挑，在当前编码器状态上覆盖 72 个强度带 + 79 个 M/S 带并继续逐位相等，见 §290–§297）；§302 把短窗帧也接进这条链（`aac_encode_config_with_perceptual_short`，默认关）：psy 的 8×128 槽位带记录与按窗分组的 twoloop 终于进 `encode_frame`，`channel_data_psy` 按 `w*128+offsets[b]` 逐窗量化、组内共享 `(sf,cb)`，码流沿用 `scale_factor_grouping=0x7f` 的一组八窗；短窗上三件仍是单窗移植的工具（PNS / IS / M-S）显式关闭，但带宽补偿条件照 C 保持与窗形状无关；因一组八窗共用一个标度因子，瞬态夹具从 31.84 掉到 25.21 dB 而短窗 NMR 尚未量化，故按 PNS/IS 先例做成 opt-in —— 开关关闭时 8 个长窗帧逐字节不变（含短窗之后的帧），三条端到端流仍是 3166/2980/727 B；开关打开后 mono 128k 3042 B 与 stereo 64k 1626 B 两条 ADTS 经 ffmpeg 9.0.2 解码，与本解码器 PCM 差 3.5e-9 / 140.5 dB、零延时偏移；§303 补上短窗 NMR 尺子并裁决不转正——重放全部帧建立预回声历史、按 8×128 谱与 `psy_bands[w*16+g]` 逐窗阈值测量，感知臂在两码率、八个窗全线更差（128k：14.21 vs 9.75 dB、64k：18.69 vs 15.62 dB，低频带最重——单组八窗共享一个标度因子所致），长窗的「SNR 换掩蔽余量」交易在短窗不存在，故保持 opt-in；§304 把窗分组补上——FFmpeg 真正注册的窗回调 `psy_lame_window` 整体移植（`aac_enc_window.mbt`：21 点 FIR 高通 + 18 子块峰值 + attacks/级联/喇叭抑制全链按 C float 语义逐运算 f32 化，每通道跨帧状态挂 `AacEncoder.lame`，同步改写口径——对本帧 MDCT 输入 `buf[523..1568)` 分析，恰是 C 前瞻覆盖的同一块样本；harness 新 `--win` 模式给出 26 帧×2 通道整数决策黄金向量，首攻块覆盖 `window_grouping[]` 全表 0..8，`aac_win_vectors/` 逐帧整数全等），感知短帧按首攻块查表展开**真实 `scale_factor_grouping`**（CPE 取较早首攻），写侧 sf/cb 平铺 `w*16+b` 128 槽、sections/scalefactor/spectral 全部按组主序、sf 差分链跨组连续、`adjust` 逐组尾零扫描+组内归并（新鲜数组下恒等，C 的跨帧粘性 zeroes 为文档化偏差）；stash 前后对拍证明 default/perceptual 流逐字节不变，分组 ADTS（4554 B/13 帧）经 ffmpeg 9.0.2 解码 0 errors、与本解码器 PCM 差 1.19e-7（≈138.5 dB）；NMR 复测分组把感知臂 14.21→13.40 dB（128k）/18.69→18.26 dB（64k）改善 0.8/0.4 dB 但未翻转对简化臂（9.75/15.62 dB）的劣势；§305–§307 把短帧三件套与窗型状态机全部换上 FFmpeg 形态——`mark_pns`/`search_for_pns`、`aac_is_search`/`aac_ms_search` 按 `w += group_len[w]` 分组（PNS 逐窗拉 LCG 逐窗定价、IS 能量门组内求和、MS 组级 Mmax/Smax 与逐窗 bits 扣除，元素 sticky 槽状态跨帧、MS 重写回流），`lame_apply_block_type` 窗型机（发射存储态+短窗路径补丁，短窗运行必多一帧安静 EIGHT_SHORT 再经 LONG_STOP 回长窗）接进编码器，`--win`/`--isms`/`--short --pns` 三组 harness 向量（分组/窗型/槽决策逐帧逐槽全等），短窗全开流 ffmpeg 9.0.2 解码 0 errors、双解码器 PCM 一致 140 dB；§308 用真实 ffmpeg 原生编码器做第三方裁决——同夹具同尺三方对拍 128k 简化 12.74/感知 14.03/**原生 14.41**、64k 18.18/20.19/18.56 dB，「感知臂劣于简化臂」是 FFmpeg 短窗固有行为（原生也劣），`perceptual_short` 的 opt-in 定案为选 FFmpeg 语义而非更优 NMR，感知臂与原生差 <1.7 dB（128k 反超）即移植背书（`aac_ffmpeg_ref_test.mbt` 固化；全量 1422/1422））；配置矩阵汇总在 §289）））；AAC SBR（HE-AAC：显式与 ADTS 隐式信令，SBR 头/网格/包络/噪声全语法位级对拍 C 插桩 dump，QMF 分析/合成、HF 生成/调整/limit、双缓冲 Y 与 f_indexnoise/f_indexsine 跨帧状态，8/10/12 kHz 核心率全表）；AAC PS 合成（HE-AACv2 两条真实流完整 PCM 对拍最大差 1；10/20/34 频带、IPD/OPD、HB 和编码负载逐缓冲对拍 C，wasm 8 帧、native 16 帧；编码负载现覆盖 header 复用、IID/ICC 关闭、fixed grid 0/1/2/4 包络与跨帧补包络、扩展开关；WAV 原始 AAC 块按解码消费字节切帧（`aac_decode_raw_stream`，与 ffmpeg PCM 差≤1 LSB））；SBR/PS 边界新增 32 kHz stereo、44.1 kHz stereo HE-AAC 与 44.1 kHz HE-AACv2 三组真实流，逐帧 PCM 与 FFmpeg 9.0.2 最大差≤1 LSB 且 99.9% 以上样本逐位相等；多声道 SBR 覆盖 5.1、5.0、7.1(wide) 三组 libfdk_aac 真实 ADTS 流与 6.1(back)、5.1.2(back) 两组真实 MP4/ASC 流（每个 channel element 独立 SBR 上下文，无 SBR 负载的 LFE 也走纯上采样 QMF 路径），三帧 2048 样本/声道、PCM 最大差≤1 LSB 且 99.9% 以上样本逐位相等（6.1(back)/5.1.2(back) 的 ADTS 头无法表达：3-bit `channel_configuration` 会把 ASC 的 11/14 截成 3/6，故按原始 AU + ASC 通道配置解码）；SBR 的 `bs_sbr_crc_bits` 与上游 `aacsbr_template.c` 的 TODO 一致地跳过校验；MPEG 音频 Layer I/II/III 定点 PCM；MP2 编码器（`mpa_encode.mbt`：移植 `mpegaudioenc.c` 的 `mp2fixed` 定点路径——32 点多相分析滤波器组（`ff_mpa_enwindow` 64 点窗化 + 32 点 `idct32`、`FRAC_BITS=15`）、帧长与填充按 `frame_frac` 累计、逐带 3 个标度因子与 25 种合并规则、固定 SMR 表驱动的贪心位分配、定点量化与 `bits<0` 的 3 样本打包写位；44.1 kHz 立体声 128 kbps 12 帧共 5015 字节与 ffmpeg `-c:a mp2fixed` 输出逐字节一致（MD5 `049A7489…`），ffprobe 识别 `mp2`、ffmpeg 9.0.2 解码无 codec 告警，补偿 962 样本延迟后对源 SNR 21.77 dB / PSNR 29.66 dB；MP3 编码器（`mp3_encode.mbt` + `mp3_enc_subband/mdct/loop/bitstream.mbt`：移植 shine 3.1.1——FFmpeg `libshine.c` 封装的外部 Layer III 编码器，纯定点：32 带多相分析滤波器组（512 点 enwindow 环形缓冲、`mul=(a*b)>>32` 乘积族）、36 点 MDCT + 混叠蝶形、量化内外迭代循环（`steptabi`/`int2idx` 查表 + 浮点回退、`new_choose_table` 码本成对比较）、34 张 Huffman 码表与 32 位缓存位写入器（缓存跨帧连续，帧尾不足一个字的位留到下一帧）；表由 C dumper 零转录提取（`scripts/gen_mp3_enc_tables.sh`）；唯一算法偏差是 `calc_scfsi` 用双端一致的确定性 ln 替代 libm log（wasm/native 位级可复现）；44.1k stereo 128k、48k mono 192k、22.05k mono 64k（MPEG-2 LSF）三组向量与编译后的 shine 参考逐字节相同（参考与 shineenc MD5 一致），ffmpeg 9.0.2 解码零告警，本解码器往返 SNR 17.4–18.1 dB）；Opus 编码器（`opus_encode.mbt` + `opus_enc_rc/math/tables/celt/bands/alloc/psy/psy2.mbt`：移植 FFmpeg 原生 `opus/enc.c` 的 CELT-only 路径——range coder（前向 range 字节 + 反向 raw-bit 区、末尾合并）、瞬态/非瞬态 MDCT 与逐带能量归一化、coarse 能量预测与精细位（fine bits/sign）、tf/alloc_trim/动态 boost 的熵编码、PVQ 频带量化（split/折叠/LCG 降级与 collapse mask 传播）、心理声学包决策（bessel 激励、强度/双声道/tf 搜索、21 阶帧预算分配）；48 kHz 20 ms MONO/STEREO FULLBAND，确定性 libm 与直通 MDCT 双端一致；48k stereo 96k、48k mono 48k 两组 12 帧向量 **26/26 包逐字节一致**，Ogg Opus 封装经 ffmpeg 9.0.2 解码零告警，本仓库 Opus 解码器往返 SNR 15.7 / 13.0 dB，与参考解码器（16.6 / 13.5 dB）相差 <1 dB））；FLAC 无损 PCM（8/16/20/24/32-bit；32-bit 定点/LPC 残差走 64 位路径，32-bit stereo 的 33-bps side channel 走 64 位缓冲）；FLAC Vorbis comment 标签读写（`flac_read_tags`/`flac_add_tags`，替换/删除注释块且不动帧，ffmpeg 夹具读回与 ffprobe 验证）；FLAC 编码器（固定预测 0-4 阶 + LPC 1-12 阶 Levinson-Durbin/15-bit 量化 + Rice/Rice2 分区阶 0-8 搜索与 Rice escape 分区（分区阶>0 时把密集残差存为定宽样本；固定/LPC 每个候选阶都用完整分区搜索的真实位数选优）、立体声 left/right/mid-side 去相关、wasted bits、UTF-8 帧号、STREAMINFO/MD5/CRC，8/12/16/20/24/32-bit 1-8 声道；32-bit 走 64 位预测/残差与 33-bit 侧声道宽写；16-bit stereo、24-bit mono、8-bit mono、相关立体声、AR(2) LPC、非平稳分区、32-bit 单/双声道及极值 33-bit 侧声道均与 ffmpeg 解码 PCM 逐字节一致，16-bit stereo 夹具 7361→4903 字节、相关立体声 1646→1266 字节）；ALAC 解码（16/20/24/32-bit、1-8 声道，MP4 `alac` magic cookie、未压缩元素与 Rice+LPC 压缩元素，ffmpeg 编码的 16/24-bit 单/双声道与 5.1 文件解码 PCM 逐字节一致）；ALAC 编码器（16/24-bit 单/双声道，SCE/CPE + 自适应 FIR LPC（Levinson/EST、9-bit 系数）+ Rice 熵编码，四种立体声去相关模式（left/right、left/side、right/side、mid/side），36 字节 cookie；16-bit 立体声/相关立体声与 24-bit 单/双声道经 ffmpeg 9.0.2 解码 PCM 逐字节一致）；TTA 无损解码（8/16/24-bit，LE 位流、自适应 Rice 与混合滤波，ffmpeg 编码的 8 kHz 单/双声道夹具 PCM 逐字节一致）；ADPCM 解码（IMA WAV 4-bit、Microsoft、Yamaha，以及 MOV `ima4`/IMA QuickTime；WAV 块对齐/QuickTime 34 字节块解复用后与 ffmpeg s16le 参考逐字节一致）；WavPack 无损解码（16/24/32-bit 单/双声道，小端熵位流/自适应中值/反相关，ffmpeg 夹具 PCM 逐字节一致）；G.711 A-law/µ-law、G.722、G.726 16/24/32/40 kbit/s 解码（WAV 块解复用后与 ffmpeg s16le 参考逐字节一致）；aptX/aptX HD 解码（原始 4/6 字节块、两级 QMF 与自适应预测，ffmpeg 夹具 s32le 逐字节一致）；AC-3 解码（bsid≤10，双单声道/单声道/立体声/3F/2F1R/3F1R/2F2R/3F2R+LFE，耦合与耦合坐标、立体声 rematrixing、delta bit allocation、零尾数抖动、dynrng 动态范围；256/128 点 IMDCT 直接实现 + KBD 窗；ffmpeg 9.0.2 夹具 s16 参考最大差 1 LSB，单声道逐字节一致）；AMR-NB 解码（4.75–12.2 kbit/s 全部八种模式，RFC 4867 位重排、LSF/LSP/LPC 与 12.2k 分裂量化、基音滞后插值、代数码本、固定增益平滑与抗稀疏 IR 滤波、合成/后滤波/二阶高通；ffmpeg 9.0.2 libopencore 夹具 s16 参考最大差 1 LSB）；E-AC-3 解码（bsid 11–16 独立帧，2/3/6 块；帧头语法标志、LUT/AC-3 式指数策略、E-AC-3 耦合与快速增益/转换器 SNR 偏移、默认比特分配参数；SPX/AHT/增强耦合/依赖帧/缩减采样率明确报错；ffmpeg 9.0.2 原生 eac3 夹具（单/立体声/5.1、32/44.1/48 kHz、2/3/6 块）s16 参考最大差 1 LSB）；WMA v1/v2 解码（ASF 包级：exp-VLC/LSP 指数、run-level 系数、噪声编码、MS stereo、比特储备与可变块语法，自建正弦窗/全 IMDCT；ffmpeg 9.0.2 wmav1/wmav2 夹具 s16 参考最大差 1 LSB；ASF（.wma/.asf）解复用读取 Stream Properties WAVEFORMATEX 与 Data 包负载分片，端到端解码同参考一致）；Vorbis I 解码（Ogg 三头解析、码本 Huffman/VQ、floor 0/1、residue 0/1/2、耦合与 submap/mux、全部模式、重叠相加；IMDCT 与 FFmpeg tx 半逆变换逐点对拍；libvorbis 真实 mono/stereo/5.1/噪声短块流 s16 参考最大差 1 LSB） | 多声道 HE-AAC 已覆盖 5.0/5.1/7.1(wide)/6.1(back)/5.1.2(back)，libfdk_aac 不支持的 2.1 布局仍无真实夹具；6.1(back)/5.1.2(back) 只能以原始 AU + ASC 通道配置验证，因为 ADTS 的 3-bit `channel_configuration` 无法表达 ASC 值 11/14（`adtsenc.c` 会截断）；E-AC-3 的 SPX/AHT/增强耦合、AMR-WB、USAC 等未覆盖 |
| 其他视频 / 音频 | VP9 profile 0/1/2/3：关键帧与帧间帧（P 帧四种 MV 模式、三路参考、可切换/固定插值滤波、并行提交与计数驱动概率自适应；复合预测（fix/var 双参考选择与 `(a+b+1)>>1` 复合平均：手工构造 3 帧 64x64 确定性流（switchable comp 模式、ZEROMV 双参考）逐帧 MD5 对齐 FFmpeg 9.0.2，另有 libvpx 真实 128x96/64x48/96x64（alt-ref 隐藏帧、非 frame-parallel 反向适配）会话共 34 帧逐帧对齐，向量在 `libavcodec/vp9_realdata_vectors/`，生成脚本 `scripts/emit_vp9_realdata_vectors.py`；`comp_inter_blocks` 诊断计数器；参考缩放——scaled MC 双向（libvpx 官方 vp90-2-05-resize 向量 10 帧 MD5 对齐 vpxdec 原生输出，缩放系数 14 位分数步进与 `webm/issues/820` 舍入复刻）、8/10/12-bit、4:2:0/4:2:2/4:4:0/4:4:4；AV1 8/10/12-bit 4:2:0/4:2:2/4:4:4/单色 多 tile 无损关键帧、有损关键帧（8/10/12-bit，DCT/ADST/IDTX 全变换、环路去块滤波、CDEF、环路恢复 Wiener/SGR 与 SWITCHABLE（4:2:0/4:2:2/4:4:4 全布局）、逐 SB delta-q/delta-lf、关键帧 segmentation 的 ALT_Q/ALT_LF/SKIP 与 seg_id 空间预测，多 tile 含 64/128 SB 与 tile 边界强度修正）；AV1 inter 会话入口（含 2×2 tiles、GM warp、隐藏帧/show-existing，5 组真实流 35 帧 MD5 对齐）；AV1 整帧 superres（coded 解码 + resize 上采样 + LR 上采样网格 + scaled 参考 MC，4 组 aomenc 流 34 帧 MD5 对齐）；AV1 整帧 qmatrix（16 级别、Y/U/V 独立级别，13 组 57 帧 MD5 对齐，包含 12-bit 及 4:2:2/4:4:4/单色 inter）；AV1 帧尺寸变化（aomenc resize-mode：KF↔inter 2×/2⁄3 缩放与逐帧随机尺寸的升降双向 scaled MC、非均匀 tile 间距、显式帧尺寸，7 组 168 帧 MD5 对齐 dav1d 原生输出；resize×superres 组合 24 帧对齐 libaom aomdec 原生输出，补齐 dav1d 1.5.1 崩溃的组合）；AV1 film grain 合成（dav1d 1.5.1 算法：缩放点插值、AR 滤波 grain 模板、32×32 块 overlap、色度 luma 混合、8/10/12-bit，含 show-existing 输出与 update_grain=0 引用继承，真实 libaom film-grain-test 5 帧及手工构造的引用继承变体 MD5 均对齐 dav1d）；AV1 intrabc（关键帧 intrabc CDF、refmvs DV 预测/裁剪、当前帧 bilinear 预测 + 残差，SVT-AV1 真实流 8 组 32 帧——含 8/10-bit、128×96、2×2 tiles——MD5 对齐 dav1d）；AV1 inter 工具组合验证（interintra 含 wedge/smooth、masked compound、OBMC、local warp、dual filter、ref-frame-mvs 的隔离与全开组合共 5 组 70 帧 MD5 对齐 dav1d）；MJPEG（8-bit 基线/渐进 + SOF3 无损平面预测，4:2:0/4:2:2/4:4:4；1x1 三分量 lossless RGB 8/9-bit 输出 bgr24，9-bit 走可逆颜色变换；单分量 lossless 10..16-bit 与单分量 9/10/12-bit 基线/渐进输出 gray16le；10/12-bit YCbCr（4:2:0/4:2:2/4:4:0/4:4:4）输出 yuv*16le（MSB 对齐；12-bit 无损、单分量基线与 4:2:0 基线夹具均与 ffmpeg 对应 pix_fmt 逐字节一致）；4 分量 1x1 CMYK/YCCK（基线/渐进）按 Adobe APP14 transform 0/2 输出 gbrap/yuva444p；子采样 YCCK（2x2 Y + 全分辨率 K）按 FFmpeg 的 2× chroma 上采样后转 4:4:4；3 分量 1x1 APP14 transform 0/RGB 组件 ID 输出 gbrp，均与 ffmpeg 逐字节一致）、PNG/APNG；Opus SILK/混合/CELT 全模式与多流包级解码（OpusHead `output_gain` 标量增益：±5 dB 的 ffmpeg `ff_exp10` float 常量下逐样本一致；SILK-only 端到端 PCM 与无汇编 FFmpeg 9.0.2 framemd5 逐帧一致，hybrid 最终 PCM 逐样本对拍最大误差 1.5e-8，受 CELT 合成 3e-6 容差约束） | MJPEG 12-bit/算术编码、其他 4 分量子采样布局与子采样 3 分量 Adobe 变换未支持；Opus 包丢失隐藏（PLC）与 FFmpeg 9.0.2 原生解码器一致地不生成补偿帧（PLC 只存在于 libopus 封装路径，不在本移植范围） |
| 容器与分片 | MP4/MOV（含 AAC/ALAC/H.264/HEVC/AV1/VP9/Opus/FLAC、AC-3/E-AC-3（`ac-3`+`dac3`、`ec-3`+`dec3` 条目，ffmpeg 解码与裸流逐字节一致）及 H.264+AAC 双轨（真实 5 帧 + 45 AAC 包：视频 framemd5 一致、音频与同 AU 的 ADTS 解码逐字节一致；AAC 编码器延迟可用 `aac_priming` 以 edts/elst 表达，ffmpeg 解码与源 MKV 裁剪后一致）、HEVC/AV1/VP9+AAC/Opus 双轨（`video_codec="hevc"|"av1"|"vp9"` 写 hvc1/av01/vp09 条目，B 帧沿用 ctts；`audio_codec="opus"` 写 Opus/dOps 并以 elst 表达 pre-skip；真实 x265 B 帧、AV1+AAC 与 AV1+Opus 重封装后 video framemd5、AAC/Opus PCM 均与源一致）；双轨写入器按首帧 PTS 写视频 `edts`/`elst` 修剪 B 帧重排延迟，A/V 起点与源时间线一致，`mdhd` 语言可配（`video_language`/`audio_language` 按 ISO 639-2/T 打包，未知码回落 und；读取端解析 mdhd 语言）、H.264+AC-3/E-AC-3 双轨（真实 5 视频帧 + 4 音频帧：ffmpeg framemd5 与音频 PCM MD5 均与裸流参考一致；A/V 写入器可用 `set_tags`/`set_chapters`/`write_subtitle` 一次写入标签、章节与 mov_text 字幕轨）、单轨 MP3/FLAC/ALAC、AAC/AC-3/E-AC-3、Opus 与 mov_text 字幕写入器均可配 `language`（写入 mdhd；ffmpeg 9.0.2 解码 PCM 与参考逐字节一致）、单轨 H.264/HEVC/AV1/VP9 视频写入器（均可配 `language` 写 mdhd；真实 4:2:0/4:4:4 样本经 ffmpeg framemd5 与本地解码帧 MD5 一致；单轨 H.264/HEVC/AV1/VP9 与 H.264+AAC 双轨写入器均支持 `ctts` 呈现偏移（负偏移 version 1），并按首帧 PTS 写 `edts`/`elst` 修剪重排延迟；H.264 单/双轨与 HEVC 以真实 B 帧流验证，重封装后 video framemd5、packet DTS/PTS 与 AAC PCM 均与源一致）；`mp4_faststart` 将 ftyp+mdat+moov 重排为 ftyp+moov+mdat 并修正 stco/co64（ffmpeg 解码 framemd5 一致）、`udta/meta/ilst` 元数据读写（title/artist/album/date/comment/genre/copyright 等 iTunes atom，ffmpeg 夹具读回、写入后 ffprobe/解码验证）、`chpl` 章节读写（1/10,000,000 s 起点 + 标题；ffmpeg 夹具读回、写入后 ffprobe 章节与 seek 验证）、mov_text（`tx3g`）字幕读取与写入（单轨写入器及 H.264+AAC/AC-3/E-AC-3 A/V 写入器的可选字幕轨，u16 长度 + UTF-8 样本、间隙/收尾空样本、`mp4_tx3g_text`；ffmpeg 提取 SRT 与源一致，A/V+字幕文件视频 framemd5 与音频 PCM 与无字幕版相同））、Matroska/WebM（含 H.264/HEVC/VP9/AV1/Opus、单轨 AAC/FLAC/ALAC、AC-3/E-AC-3/MP3（均可配 `language`，A_AC3/A_EAC3 单轨与 H.264 双轨，ffmpeg 解码音视频均与裸流参考一致；A/V 写入器可用 `set_tags`/`set_chapters`/`write_subtitle` 一次写入 Tags、Chapters 与 SRT 字幕轨）（ffmpeg 重封装解码与源一致；ALAC CodecPrivate 按 Matroska 规范仅存 24 字节配置、读取时补出 36 字节 atom）、VP9+Opus 与 H.264+AAC 多轨写入器；VP9/AV1/Opus 写入器可选 webm/matroska DocType，HEVC 写入器固定 matroska DocType；`Tags` SimpleTag 元数据读写（读取时过滤 track-targeted 标签并应用 LEAD_PERFORMER/PART_NUMBER 映射；写入在首个 Cluster 前插入并重写 SeekHead/Cues 位置，ffprobe 读到标签、seek 输出与源一致）、`Chapters`/`ChapterAtom` 章节读写（纳秒时间 + ChapterDisplay 标题；写入替换旧 Chapters 或插到簇前，ffprobe 章节与 seek 输出验证）、`S_TEXT/UTF8` 字幕读取与写入（单轨写入器按 BlockGroup + BlockDuration、16-bit 相对时间码超限自动分簇，TrackLanguage/TrackName/FlagDefault/FlagForced 可配置；H.264+AAC/AC-3/E-AC-3 双轨写入器可直接追加字幕轨，真实样本 framemd5/PCM 与无字幕版本一致）；真实 VP9+Opus WebM 写入经 ffmpeg 解码与本地 VP9/Opus 解码双向验证；WebM 单轨/双轨写入器（VP9/AV1/Opus 可配 `language`）输出 SeekHead/Cues（关键帧 CueTime + CueClusterPosition），ffmpeg 全片解码与 `-ss` 定位均与源一致；VP9+Opus 双轨写 CodecDelay/SeekPreRoll 与末块 DiscardPadding（轨道语言可配 `video_language`/`audio_language`，默认 und），真实 WebM 重封装后视频帧与 Opus PCM 与源一致，真实 AV1 WebM 写入帧 MD5 与 ffmpeg framemd5 及本地 AV1 解码一致，真实 H.264 与 H.264+AAC Matroska 写入帧 MD5 与 ffmpeg framemd5 一致；单轨 H.264/HEVC 写入器支持可选 `pts_ms` 与 `language`（解码顺序与呈现顺序分离，B 帧）并输出 SeekHead/Cues，ffmpeg 全片解码与 `-ss` 定位与源一致；A/V 写入器按各轨累计 DTS 交错（块时间码保留 PTS）并输出 SeekHead/Cues，Tags/Chapters 插入后索引位置自动修正，AAC priming 用 CodecDelay + 尾块 DiscardPadding 表达；视频/音频/字幕 TrackLanguage 与字幕 FlagForced 可配（`video_language`/`audio_language`/`subtitle_language`/`subtitle_forced`）；真实 B 帧+AAC 重封装视频帧与 AAC PCM 均与 ffmpeg 一致）、MPEG-TS（含 H.264+AAC、HEVC/MP3 与 H.264+AC-3/E-AC-3 双轨（stream type 0x81/0x87，PAT/PMT 按 mpegtsenc 写字节交换的 MPEG-2 CRC）；AAC 自动 ADTS 封装、LOAS/LATM AAC 读取（`latm_parse_stream`：StreamMuxConfig 内嵌 ASC + PayloadMux 重打包为原始 AU；裸 LOAS 与 TS stream type 0x11 均经 ffmpeg 解码 PCM 差≤1 LSB），ffmpeg 9.0.2 可解码且 AC-3/E-AC-3 输出与裸流逐字节一致；PES 支持 PTS+DTS（B 帧，PCR 跟随 DTS；纯音频 TS 在音频 PID 写 PCR），真实 x264 B 帧 TS 重封装后 ffmpeg 的 DTS/PTS 与帧哈希均与源一致；H.264 B 帧 + AAC 双轨重封装后两路 PES 时间戳/payload 与视频解码帧一致；PAT/PMT 支持多节目，双节目 TS 的 programs/streams/PES 解复用与两路视频解码均与 ffmpeg 一致；写入 SDT 服务描述（`service_name`/`service_provider`/`service_type`/`transport_stream_id`/`original_network_id`，SDT 段与 ffmpeg mpegtsenc 逐字节一致，解复用回读服务名与提供商）；`nit` 开关写 NIT（PID 0x10：network_name_descriptor + service_list_descriptor，段与 mpegtsenc 逐字节一致，解复用回读 `network_name`）；PMT 可写音频 ISO 639 语言描述符（`audio_language`）与 HEVC registration 描述符（0x05 "HEVC"），PMT 段与 mpegtsenc 逐字节一致、解复用回读 language/registration）、WAV（含 PCM 8/16/24/32-bit、IEEE float32、A-law/µ-law（G.711）与 extensible 写入器及 `LIST`/`INFO` 标签读写（`wav_read_tags`/`wav_add_tags`，RIFF 与 RF64 的 ds64 尺寸同步，ffprobe/解码验证）与 Broadcast Wave `bext` 读写（`WavBext`/`wav_read_bext`；描述/来源/时间参考/UMID/coding history，段与 ffmpeg `-write_bext 1` 逐字节一致）；非 PCM 写 fact 块、extensible float 用 0xFFFE + IEEE_FLOAT 子格式，8/16/24/32-bit、float32、A-law/µ-law（WAVEFORMATEX cbSize=0；6 声道 extensible 子格式 6/7，头部与 ffmpeg 逐字节一致）与 5.1 输出经 ffmpeg 9.0.2 解码样本逐字节一致；`rf64` 开关支持 RF64 大文件头，`big_endian` 开关写 RIFX 大端；RIFX 读端映射 pcm_*be（FFmpeg 9.0.2 对 RIFX 仍报 LE codec，属其自身限制，8-bit 外部验证通过）、Ogg（Opus/FLAC/Vorbis：Opus 与 FLAC 读写，真实 Opus 写入经 ffmpeg 解码验证，FLAC 回写解码 PCM 与源一致；Vorbis 读取三头与包序列，交给 Vorbis 解码器；三者 Vorbis comment 标签读取，Opus 写入器可带自定义 OpusTags 且 ffprobe 与解码验证）、AIFF/AIFC（PCM 8/16/24/32-bit 读写，80-bit 扩展采样率解析/生成；ffmpeg 解码与本地回读 PCM 一致）、Wave64（`w64`：GUID 分块 + 64 位块长读写，PCM 8/16/24/32-bit 与 IEEE float32，`summarylist` 标签读写（UTF-16LE，ffprobe 读回）；ffmpeg 夹具与 WAV 载荷逐字节一致、写入经 ffmpeg 解码一致）、CAF（ALAC 变长包表与 LPCM 16/24-bit 读写，`frma`+`alac` cookie、pakt 包大小 varint 与帧数校验；ffmpeg 解码与本地回读一致）、AU（PCM 8/16/24/32-bit 大端与 µ-law/A-law 编解码读写、G.726LE 读取；编码字节与 ffmpeg 一致，解码与本地回读一致）、裸 AAC/MP3/AC-3/E-AC-3/AMR-NB/ASF（含 ADTS AAC 写入器、AC-3/E-AC-3 帧切分读取器、`#!AMR`/RFC 4867 TOC 帧切分读取器与 ASF/WMA 解复用、ID3v2 标签读写（`id3v2_read_tags`/`id3v2_add_tags`，v2.3/2.4 文本/TXXX/COMM、UTF-8 写入，ffprobe 与解码验证）；真实 AAC 帧经 ffmpeg 解码验证，AC-3 切片按头部帧长含 44.1 kHz 变长帧，同一读取器按 bsid 识别 E-AC-3（2/3/6 块帧），AMR-NB 覆盖 13–32 字节 TOC 帧）；MOV `jpeg`/`png ` 与 Matroska `V_MS/VFW/FOURCC`（MPNG/MJPG）静像轨解码，Matroska `V_MJPEG`/VFW-MPNG 与 `A_MPEG/L3` 写入，MP4/MOV `jpeg`/`png ` 静像写入，WAV 内 MP3/AAC 载荷读取（AAC 原始块按解码消费字节切帧）；HLS/DASH 通过回调读取 TS/fMP4（HLS AES-128 真实加密流解密+解码验证；写入侧支持 AES-128-CBC+PKCS#7 加密与 EXT-X-KEY，ffmpeg 播放与明文流音频一致），含 H.264/HEVC/AV1/VP9/AAC/Opus 单轨 fMP4 初始化段/媒体段写入器（初始化段可选 `language`/`video_language`/`audio_language`，按 ISO 639 写入 mdhd；真实 HEVC/AV1/VP9 分片经 ffmpeg framemd5 与本地解码帧 MD5 一致；`trun` 支持 composition time offset（B 帧，负值 version 1），真实 x264 B 帧分片重封装后 ffmpeg 的 DTS/PTS 与帧哈希一致；HLS fMP4（EXT-X-MAP）与 DASH SegmentTemplate 的 B 帧分片经各自 reader 回读后 CTS/DTS 与解码帧一致），AC-3/E-AC-3 分片（`ac-3`+`dac3`、`ec-3`+`dec3` 初始化段，ffmpeg 解码与裸流逐字节一致），以及 H.264+AAC 双轨 fMP4（一个 `moof` 内两个 `traf`、`mdat` 先视频后音频；真实 5 视频帧 + 45 AAC 包分两段写入，ffmpeg 解码视频 framemd5 与本地帧 MD5 一致、音频 PCM 与同 AU 的 ADTS 解码逐字节一致）、HLS 主/媒体播放列表（含 EXT-X-MAP、EXT-X-BYTERANGE 单文件分片、EXT-X-DISCONTINUITY/EXT-X-GAP/EXT-X-PROGRAM-DATE-TIME 分段标签（`hls_write_media_playlist_specs`，标签顺序与 hlsplaylist.c 一致；每条分段可覆盖 EXT-X-MAP 与 EXT-X-KEY（密钥轮换/METHOD=NONE））与 EXT-X-DISCONTINUITY-SEQUENCE、EXT-X-PLAYLIST-TYPE/EXT-X-ALLOW-CACHE/EXT-X-I-FRAMES-ONLY/EXT-X-INDEPENDENT-SEGMENTS 头标签、EXT-X-MEDIA 音轨/字幕 rendition、`SUBTITLES`/`CLOSED-CAPTIONS`/`VIDEO` 属性、`AVERAGE-BANDWIDTH`、`FRAME-RATE`、`EXT-X-START`、`EXT-X-I-FRAME-STREAM-INF`（`is_i_frame`）、CLOSED-CAPTIONS rendition 的 `INSTREAM-ID`（无 URI）与字幕 `FORCED=YES`、WebVTT 分片写入器（绝对 cue 时间，ffmpeg 提取一致）；TS 与 fMP4 两种分片均支持分离音轨，多 rendition 主播放列表经 ffmpeg 播放与本地 reader 解码验证；读取侧同理跟随 `AUDIO=`/`SUBTITLES=` 声明的 `EXT-X-MEDIA` rendition：音频 rendition 由 `decode_audio` 转交，字幕 rendition 的 WebVTT 分片由 `hls_vtt_parse` 解析后按 `EXTINF` 累计的时间轴归位，经 `StreamingMedia::subtitles` 取用——解析器接受 `HH:MM:SS.mmm`/`MM:SS.mmm`/`SS.mmm` 与逗号小数、跳过 NOTE/STYLE/REGION 与 cue id、多行文本按 `\n` 连接、`X-TIMESTAMP-MAP` 解析上报但不施加（映射它需要复用流的 MPEG-TS 时钟）；多语言字幕可经 `subtitle_renditions()`/`select_subtitles()` 列出与切换，`refresh_subtitles()` 跟随所选那条推进 live 窗口，音频 rendition 可经 `audio_renditions()`/`select_audio()` 换轨；DASH 侧同一个 Period 里的 `text/vtt` AdaptationSet 也进 `subtitles()`，段起点取 `SegmentTimeline@t`/timescale，TTML/SRT 之类文本集跳过而不致错）与 DASH SegmentTemplate（时长或 SegmentTimeline/$Time$ 寻址；`dash_write_segment_template_mpd_periods` 支持多 Period，显式 duration 参与分段展开）/SegmentList/SegmentBase MPD 写入器（音频 Representation 在提供 `channels` 时写 AudioChannelConfiguration，scheme 与 ffmpeg dashenc 一致；前两者均支持 `text/vtt` 字幕 AdaptationSet：省略 codecs/initialization/bandwidth，SegmentList 与 SegmentTimeline 字幕经 ffmpeg allowed_extensions 读取与源一致；SegmentBase 写入器生成全局 `sidx` 与 `indexRange`/`Initialization range`，sidx 与 ffmpeg movenc 字节一致）、SegmentBase 单文件 `indexRange`/sidx 读写（读取真实 fMP4 分片经 ffmpeg 播放验证，自写单文件+MPD 经 HTTP 由 ffmpeg 解码 framemd5 与源一致；支持视频+音频多 AdaptationSet，分离音轨 MPD 经 ffmpeg 播放、本地 reader 解码验证；SegmentList 支持分离文件与单文件 BaseURL+mediaRange，默认 startNumber=1 省略以兼容 ffmpeg dashdec）；HLS `EXT-X-MAP` 与 DASH SegmentTemplate 均实测 HEVC/AV1/VP9 fMP4 分片（解复用后帧 MD5 与 fMP4 源一致） | 尚无完整网络协议层或完整 muxer 集合；统一播放 API 与 JSON CLI 已落地（见上） |
| 基础算法 | 位流、哈希/校验和、AES 等密码算法、数学/时间基及部分 `@v128` 内核；libswresample 格式/通道转换 + 原生 polyphase 重采样 | `libavutil` 其余模块及 `libswscale`（仅 YUV→RGB 查表路径）尚未整体移植 |

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
和隐藏/重排序帧。film grain 合成与 intrabc 均已接通（见下文）。qmatrix 已接通，验证见下文。
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

**参考源交叉验证（本轮补充）**：用 libde265 1.1.3（master，`dec265`）独立解码
上述夹具。`htw_slices8` 的 5 帧与 HM MD5 逐帧完全一致（5/5），可作为该组合的
第二参考源；其余 5 组（2×2 tiles/WPP、10-bit、非方形 tile、两类 dependent
slice segments）libde265 不报错但输出与 HM 不同（htw8 首帧
`1797123e6242face9761ac21b0d78e92` vs HM `017ebde8e1d4351a4edaffa083ccfbec`），
说明其 HT 扩展解码路径与 HM 不一致，不能作为这些流的第二参考。FFmpeg 9.0.2
对这些流同样不报错，但 htw8 首帧 MD5 为 `82f46e8be06b529e60fb805c01a65d3c`，
与 HM/libde265 均不同，属静默错误解码，因此该组合仍只能以 HM 输出为准。

**读取层边界（本轮补测）**：HLS 覆盖同一列表内两条 `EXT-X-KEY` 的 AES-128
密钥轮换（首段隐式 IV 由 `EXT-X-MEDIA-SEQUENCE` 推出、次段显式 `IV`），以及无
`EXT-X-ENDLIST` 的活动列表在首次读取失败后保留游标重试；DASH 覆盖多 Period
各自的 BaseURL/`startNumber` 编号与 `SegmentBase indexRange`；fMP4 覆盖单
`traf` 多 `trun` 的 DTS 续接（与 `mov_read_trun` 的
`frag_stream_info->next_trun_dts` 一致）及按 `trun` 串联的显式数据偏移；WAV
覆盖零长度未知 chunk，以及声明长度为 0 的 `data` chunk（按上游语义视为未知
长度、读到 EOF 并停止 chunk 扫描）。

**统一格式探测层（本轮新增）**：`libavformat/probe.mbt` 移植了
`format.c` 的 `av_probe_input_format3` / `av_probe_input_format2` /
`av_probe_input_buffer2`，把此前各自独立的容器入口收进一条探测链：
ID3v2 跳过与降级、扩展名提分、MIME bonus、同分清空，以及
`PROBE_BUF_MIN`(2048)→`PROBE_BUF_MAX`(1 MB) 的倍增读取。注册了 20 个
`read_probe`——MP4/MOV、Matroska/WebM、MPEG-TS（含 188/192/204 三种包长
的 sync 直方图）、WAV/W64、HLS、DASH、ADTS AAC、AC-3/E-AC-3、AIFF、AMR、
PNG、ASF、AU、CAF、FLAC、MJPEG、MP3、Ogg。17 组由参考 FFmpeg 9.0.2
生成的真实文件，探测结果与 `ffprobe -show_entries format=format_name`
逐一对齐（再生脚本 `scripts/gen_probe_fixtures.sh` +
`scripts/gen_probe_vectors.py`）。HLS/DASH 的播放列表识别与解析在此层；
媒体字节由调用方通过 `MediaFetch` 回调提供（见下）。

**统一播放 API 与 JSON CLI（2026-11-06）**：`libavformat/playback*.mbt`
提供 `MediaFile`——`open`（探测分发 MP4/MKV/Ogg/WAV）、`next_packet`
（MP4 按 DTS 跨轨归并）、`AudioDecoder`/`VideoDecoder`（H.264/HEVC/VP9/AV1
视频、AAC/Opus/PCM 音频，全部经已移植解码器）、`duration_seconds`、
`decode_audio_file` + `to_wav_s16`、`cover()`（MKV Attachments / MP4
`ilst/covr`）与 ffprobe 风格的 `probe_json`/`dump_packets_json`。配套六个
JSON CLI 命令（`cmd/`）：`probe`、`dump-packets`、`decode-audio`、
`extract-frame`（`--format yuv|rgb24|bgr24`）、`extract-cover`、
`stream-audio`（HLS/DASH → WAV，可带 `--dir`/`--output`/`--rate`/
`--variant`/`--reloads`），pts/分包/解码输出均与 FFmpeg 9.0.2 docker
对拍逐字节或 ±1 舍入一致。
**libswscale 移植开篇**（`libswscale/`）：YUV420P -> RGB24/BGR24
（`yuv2rgb_1_c_template` 查表语义，表数据从 FFmpeg 9.0.2
`ff_yuv2rgb_c_init_tables` 全量 probe 内嵌——FFmpeg 9 的系数经 cms
双精度通路重算，不可公式复算）；420/422/444 三种子采样；**通用缩放片**
（`swscale_scale.mbt` = legacy `initFilter`/`hScale8To15_c`/`yuv2planeX_8_c`
定点管线，bicubic 任意比例 420P→420P；A/B 考古证明 CLI(x86 SIMD, filterAlign=4)
与纯 C(filterAlign=1) 是双官方路径（±1 误差扩散差异），本移植对齐纯 C 语义，
docker `av_force_cpu_flags(0)` harness 为权威向量：64→40x30、64→96x72
**逐字节恒等**；§339 修正 initFilter 近零削减阈值 SWS_MAX_REDUCE_CUTOFF
为 swscale.h 的 0.002（§334 曾误抄 0.00002，旧向量恰未落入中间区间），修正后
全部对拍逐字节恒等，并支持 **4:2:2/4:4:4 源与目的地任意组合**（色度几何
AV_CEIL_RSHIFT、滤波器维度无关，7 组向量含 420↔444/422↔420 混合与奇尺寸
全部逐字节恒等））；**缩放+色彩转换组合片**
（`SwsRgbScaler`：planar YUV→RGB24/BGR24，legacy `yuv2rgb_X_c_template`
成对垂直写出复用同组滤波器与官方 LUT——G 通道是指针先加再索引的语义；
40x30/96x72/50x38 **逐字节恒等**）；**奇宽 full-chroma 插值**
（`yuv2rgb_full_X_c`+`yuv2rgb_write_full` 逐像素定点写出，6 个 BT.601 系数
从 docker FFmpeg 9.0.2 探针：43x28/43x29 **逐字节恒等**）；**422/444→RGB
组合**（§340：444 源按 utils.c 强制 full-chroma（"input having non
subsampled chroma"），422 源偶宽走 pair 模板/奇宽走 full-chroma，色度垂直
恒全率 dstH（RGB 格式无垂直子采样）；5 组向量含 444+bgr+奇尺寸全部
**逐字节恒等**）；**full-range（yuvj/JPEG）色彩**（§341：`full_range=`
开关，cy 1<<16/oy 0、色度系数 ×224/255，24bpp LUT 与 per-pixel 系数均为
limited 版的探针对偶——探针先自证 limited 表与已提交数据逐值一致；
4 组向量 yuvj420p/422p/444p→RGB（含奇宽+bgr）全部**逐字节恒等**）；
**BT.709 色彩空间矩阵**（§342：`colorspace=` 开关（Bt601 默认/Bt709），
harness 经 public `sws_getCoefficients`+`sws_setColorspaceDetails` 探针——
注意 n9 表构造链中段有 cms 双精度介入（limited 表 crv=89830≠inv 原值
104597，整数推导只能复刻系数段），故每组 (CS×range) 表仍为探针硬编码；
4 组 709 向量 limited/full × pair/full-chroma 全部**逐字节恒等**）；
**FCC/SMPTE240M/BT.2020 矩阵**（§343：`sws_getCoefficients` 其余与 601
不同值的三个矩阵全补齐——BT.2020 NCL/CL 共表、SMPTE170M 值同 601 故不单列；
6 组 (CS×range) 表 + 7 向量全部**逐字节恒等**）；**10bit 平面缩放**
（§344：`src_bits/dst_bits=`（8/10），hScale16To15 `sh=depth-1` LE u16 读取、
yuv2planeX_10 `shift=11+16-bits` + av_clip_uintp2；**10→8 时 N-BPS 源启用
有序 dither `ff_dither_8x8_128[行&7][列&7]`，V 平面列偏移 +3**（vscale.c）；
4 向量含奇尺寸与降位深全部**逐字节恒等**）；**CLI 接线**：
`extract-frame --scale W:H`（yuv/planar 输出走 SwsPlanarScaler（奇尺寸走 ceil 色度几何，与 C 一致）、
rgb24/bgr24 走 SwsRgbScaler（奇宽走 full-chroma 插值）；RGB 组合路径与 docker `ffmpeg -vf scale` CLI 输出
**逐字节恒等**，yuv 输出为已文档化的 SIMD/C 双路径 ±1）。**libswresample
两片**（`libswresample/`）：①同采样率格式/通道转换（planar float ->
packed s16、mono->stereo），float->s16 采用 FFmpeg 的
`av_clip_int16(lrintf())` round-half-to-even 舍入（decode-audio 的 WAV
导出随之与 FFmpeg 舍入语义一致）；②**原生重采样器**（`swresample_resample.mbt`
= `resample.c`/`resample_template.c` FLTP 路径全量移植：32 抽头 kaiser β9
polyphase 滤波器组、exact_rational 相位坍缩、`invert_initial_buffer`
镜像启动史、`multiple_resample` 窗口边界与 `resample_flush` 镜像尾——
内积逐乘 IEEE f32 与 C 一致、设计期 f64 仅 libm 差 ~1 ulp；48k→8k 198 抽头
抽取与 FFmpeg 9.0.2 docker `aresample` **逐字节恒等**，48k↔44.1k、
48k→96k、stereo 五组向量输出计数恒等、值 ≤1 LSB（≤6/4410 样本翻转），
流式输出与分块边界无关）；③**播放门面接线**（`DecodedAudio::resample_to`
整体流 process+flush 重采样、标签保留、8000..=192000 守卫；CLI
`decode-audio --rate N` 与 `extract-frame --scale` 对偶——48k→8k 0.1s
双音源 vs docker `ffmpeg -ar 8000`：输出 800 样本计数恒等、值差
1/800 ±1 LSB（SIMD/C 双路径，钉住））。包已发布
[mooncakes.io/milkbobo/ffmpeg-moonbit](https://mooncakes.io/docs/milkbobo/ffmpeg-moonbit)
（`moon add milkbobo/ffmpeg-moonbit`）。发布形态的模块为**纯 MoonBit**：
wasm 目标不含任何 C FFI / 原生库依赖。开发用的原生 FFmpeg 参考 oracle
（`ffref/`）是独立的 native-only 附加包（`supported_targets = "native"`，
wasm 构建视其为空包），已于 §345 复活并常驻——链接 docker 镜像内构建的
FFmpeg 9.0.2 静态库做进程内差分，含 HLS/DASH 路径式逐包对拍；差分验证
记录见 PORTING_HISTORY §328-§332、§345 与
`AGENT_HANDOFF_2026-11-06_FFREF_ORACLE.md`。

**自适应流统一播放（2026-11-07）**：`libavformat/playback_streaming.mbt`
的 `StreamingMedia` 把 HLS 媒体播放列表与 DASH MPD 接入同一套
`next_packet`/`decode_audio` 表面。调用方提供 `MediaFetch(uri, offset,
length)` 回调（等价 FFmpeg 的自定义 AVIO），每个分片复用既有
`MediaFile` 解复用器与 `AudioDecoder`，不重复任何容器/编解码逻辑。
跨分片 pts 用「上片末 pts + 该流最后步长」归一到单一单调时间轴
（Int64 饱和算术，拒绝异常流索引）；`#EXT-X-DISCONTINUITY` 只在分片
首包标记并重置解码器，时间轴不回退。回调失败抛 `DemuxError` 且游标
不变，可重试；越界的 DASH Period/AdaptationSet/Representation 索引
均明确报错。

`StreamingMedia::open` 遇到 HLS master 播放列表时自动选带宽最高的
可播放 variant（跳过 I-frame-only 项，也可用 `variant~` 指定索引），
用 `MediaFetch` 拉取子播放列表并以其绝对 URI 为 base 再解析；
嵌套 master 会被拒绝以免形成无界拉取循环，`variant_uri()` 可查询选中项。
音频线 `decode_audio` 与视频线 `decode_video` 都跨分片保持解码器状态
（视频在 discontinuity 时先 flush HEVC 批式缓冲再重建，末尾
`finish_video` 收口）；MP4 fourcc（`avc1`/`hvc1`）在分段流表内经
`mov_codec_name` 规范化为 `h264`/`hevc`，既有文件门面契约不变。

**直播刷新**：`reload(HlsPlaylist)`/`reload_bytes(Bytes)` 复用
`HlsSegmentReader::reload` 的重叠窗口、过期段 discontinuity 与
key/map 缓存失效语义，保留已归一化的 pts 时间轴并复活会话；
`is_live()`/`reload_count()` 可观测，VOD 明确拒绝。
`open` 的可选 `playlist_fetch~` + `max_reloads~` 让段耗尽时自动
重新拉取播放列表（master 场景刷选中的 variant 列表），预算以循环
而非递归实现，枯竭窗口不会无限轮询；刷新失败抛 `DemuxError`
且游标不变可重试。单包分片无段内步长时 pts 回退为 1 tick，
保证时间轴严格单调。

**DASH 直播刷新**：`type="dynamic"` 的 MPD 同样以 `is_live()` 打开，
`reload_dash(DashMpd)` 按分片**起始时间**（表示内部 timescale）续接
——已播过的分段跳过，刷新后的滑动窗口既不重复也不丢包；窗口若跳过了
从未播放的分段，下一分片标记 `discontinuity` 以便解码器重置（该标志
是粘性的，二次刷新不会把它抹掉）。选中的 Period/AdaptationSet/
Representation 会记住，也可用参数覆盖；只列一段的 SegmentBase
单文件表示无法续接，明确拒绝。刷新后窗口没有新分段不算错误：游标停在
末尾、`next_packet` 继续返回 `None`，与 `dashdec` 的轮询语义一致。
`open`/`open_dash` 的可选 `mpd_fetch~` + `mpd_uri~` + `max_reloads~`
让窗口自动推进，同样以循环而非递归实现。

**DASH 多 Period 续播**：`open_dash(period~)` 选中的 Period 播完后，
会话自动进入下一个含**同类 AdaptationSet** 的 Period（先按
content_type+codecs 精确匹配，再按 MIME 类型，最后才退到同位置且要求
content_type 一致——只带字幕/视频的 Period 不会把会话悄悄变成别的读取器），
Representation 按 codec 匹配。每个 Period 都有自己的媒体时间轴，因此
Period 边界标记 `discontinuity`、分段游标重置；`period_index()` 可观测
当前播到第几个。单 Period MPD 行为不变。

**HLS 分离音轨**：变体声明 `AUDIO="group"` 时音频并不在该变体的分片里，
而在 `EXT-X-MEDIA:TYPE=AUDIO` 的另一个 rendition 播放列表中。选中变体后
门面会解析该组（优先 `DEFAULT=YES`，否则取第一个带 `URI` 的成员）、
把 rendition 播放列表作为独立会话打开，`decode_audio` 直接跟随它——
不再抛 `UnsupportedCodec`。`next_packet`/`decode_video` 仍留在变体上；
`audio_track()` 可拿到该会话（用于换语言轨或直接驱动）。
`URI` 为空的 rendition 是复用变体自身音轨的内嵌项，不会被单独打开
（解析层同时修掉一处缺陷：空 `URI` 曾被解析成 master 自身的地址）。

**字幕轨（HLS rendition / DASH text AdaptationSet）**：字幕落在
`SubtitleTrack` 上，两条来源都汇到 `subtitles()`，首窗在打开时一次性取完
（cue 比媒体分片小几个数量级），访问器无 IO、不抛。

HLS 侧：变体声明 `SUBTITLES="group"` 时字幕在
`EXT-X-MEDIA:TYPE=SUBTITLES` 的 WebVTT rendition 播放列表里。选组规则与
音轨共用一处（先 `DEFAULT=YES`，再第一个带 `URI` 的同组同类型成员；
`AUDIO` 组里的成员不会被当字幕解析），打开时就把各分片取回、解析成一
条 cue 列表挂在会话上。cue 时间按 `EXTINF` 累计的播放列表时间轴处理。

DASH 侧：字幕是同一个 Period 里 `contentType="text"`（或 `mimeType` 以
`text/` 开头）的 AdaptationSet。只认 `text/vtt`——TTML/SRT 之类不喂给
WebVTT 读取器，免得一个无关的文本格式把本来健康的音视频流带崩；没有可
解析的 `text/vtt` 时照常打开、只是没有字幕轨（多个文本集时第一个
`text/vtt` 胜出）。段起点直接取 `SegmentTimeline@t`/`SegmentTemplate`
的 time 按 timescale 折成毫秒（先除后乘，损坏时间轴不会溢出），
`mediaRange` 走与媒体段相同的取字节路径。

两条来源共用的放置规则：首尾相接的绝对时间原样保留，而「所有 cue 都在
本段起点之前结束」的段说明作者写的是段内相对时间，按段起点平移（首段
平移量为 0，因此这条规则不靠猜）。解析器要求 `WEBVTT` 签名、跳过
NOTE/STYLE/REGION 与 cue id、丢弃 cue settings、支持 CRLF 与 BOM、多行
文本按 `\n` 连接，`X-TIMESTAMP-MAP` 解析并上报但不施加——映射它需要复用
流的 MPEG-TS 时钟，字幕 playlist/分段自身不携带。某个分片不是 WebVTT 或
取不回来都会让 `open` 报错，而不是静默播一个没有字幕的视频（HLS 侧与
`hls_read_header` 提前打开每个声明过的 rendition 一致）。

**live 字幕跟窗**：`refresh_subtitles()` 只追加新段，返回新增 cue 数；
HLS 重取 rendition 播放列表、DASH 读会话上当前的 MPD（所以
`reload_dash(new_mpd)` 就是推进它的动作）。进度键两边不同：HLS 用绝对
`EXT-X-MEDIA-SEQUENCE`（窗口内下标会滑动，序号不会），DASH 用段的
`uri@mediaRange`——duration 型 `SegmentTemplate` 的窗口滑动时序号与时间
都会从 0 重来，只有段自己的地址稳定。HLS 的时间轴按累计 `EXTINF` 续接；
DASH 以 `next_start_ms` 作为声明时间的单调下限，于是「窗口重置」的流不会
把新 cue 叠到旧 cue 上。`reload`/`reload_dash` 都会顺带刷新（best effort：
cue 出问题不推翻已经移动的媒体窗口），失败次数由
`subtitle_refresh_failures()` 观测；要拿到错误本身就直接调
`refresh_subtitles()`——它在整趟成功前不提交，所以可原样重试。

**多语言字幕选择**：`subtitle_renditions()` 列出会话所在的字幕组／文本集，
每条带 `language`/`name`/`forced`/`is_default` 与来源地址；`subtitle_selected()`
返回当前在用的下标（没有字幕时为 `-1`），`select_subtitles(index)` 换轨。
列表顺序就是清册顺序，**默认轨不一定是第 0 条**——打开时按「先
`DEFAULT=YES`，再第一个带地址的成员」选定，所以 `subtitle_selected()`
可能返回 1 甚至更后面，调用方要按 `is_default` 而不是下标 0 理解默认。

换轨是重取而不是合并：新轨从首窗重新收集，旧轨整体替换。重复选同一条是
no-op——否则会把 live 游标重置回首窗、把已发布的 cue 再吃一遍。切换失败
（分片取不回、不是 WebVTT）保留旧轨并抛出，不会把会话留在「有轨但空」的
状态；下标越界报错而不静默忽略。`refresh_subtitles()` 跟随**当前所选**那条，
所以换语言后 live 继续在新语言上推进。DASH 侧每个文本集各占一条候选
（取该集里第一个 `text/vtt` Representation），TTML 之类不进列表（选不到，
也就不会在切换时才炸）。

**多语言音轨选择**：同一组 API 管音频——`audio_renditions()` 列出变体
`AUDIO="group"` 指到的 `EXT-X-MEDIA:TYPE=AUDIO` 成员，`audio_selected()`
返回在用的下标，`select_audio(index)` 把该 rendition 的播放列表打开成一个
新的子会话并接上 `audio_track()`/`decode_audio()`。两条候选都按 `TYPE`
过滤，所以同一个 `GROUP-ID` 下的字幕成员不会被当成音频语言（反之亦然）。

音频与字幕的差别在「换轨换的是什么」：字幕换的是 cue 列表，音频换的是
**整个子会话**，所以 `select_audio` 要把打开时那三个参数
（`prefer_x_start`/`live_start_index`/`max_reloads`）原样交给新子会话，
且用的是**原始**刷新预算而不是父会话剩余的——否则 live 换轨后音轨会比
视频先耗尽刷新次数。重复选同一条同样 no-op。DASH 侧没有这个入口：一个
会话播一个 AdaptationSet，混流音轨没法在菜单里切，列表就是空的。

两处列表都用 `Rendition` 描述（HLS 靠 rendition URI、DASH 靠
`(set, rep)` 索引对定位），`FORCED` 对音频恒为 false。

**本地文件取媒体**：`playback_fetch.mbt` 给出 `MediaFetch` 的三种现成实现
——`media_fetch_from_reader`（把 `(路径) -> Bytes` 的读取器适配成带
offset/length 的回调，`length = -1` 表示读到 EOF）、`media_fetch_from_map`
（内存资源表，测试用）与 `media_fetch_path_key`（把分片 URI 收敛成安全的
单层文件名：剥掉 scheme/host/query/fragment，只取最后一段路径，拒绝
`.`/`..`/反斜杠与 `%2F`/`%5C` 编码分隔符）。这让 `StreamingMedia` 无需任何
网络栈就能跑通本地 HLS/DASH 目录，也不把 URI 路径拼进文件系统。

测试覆盖真实 AAC→TS/fMP4 与 x264→fMP4 分片：多段包序列、
逐样本 PCM 与 `decode_audio_file` 一致、视频 5 帧与 FFmpeg 9.0.2
参考 MD5 逐帧一致、断点重置、失败重试、master variant 选择、
live 窗口推进/过期/预算、DASH 动态 MPD 续接/滑动窗口/跳段/静态拒绝、
DASH 多 Period 链式续播与类型不匹配即停、HLS 分离音轨跟随与内嵌/
非默认回退
及空列表（58 项纯 Wasm，无 FFI）。

## 构建与测试

连续 MJPEG 帧可以复用 `@libavcodec.MjpegDecoder::new()` 返回的会话，逐包调用
`decoder.decode(packet)`。会话保留成功帧中的 DQT/DHT 定义，支持后续帧省略这些表；
失败帧不会覆盖已保存的表。独立图片仍可调用 `av_mjpeg_decode`，其状态互不共享。

在本目录运行：

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render
moon info --target wasm
```

最近一次完整验证（2026-11-07）：Wasm 测试 **1708/1708** 通过，`moon check --target wasm --deny-warn` 与 `moon check --target native --deny-warn` 零警告，`moon info` 通过（`--target js` 有 1 处 `libavutil/moon.pkg` 的 `v128` 未使用告警，`git stash` 回退到上一提交后仍在，属历史遗留、与本轮无关）（新增 HLS/DASH 分段播放 15 项、master 选路与视频线 9 项、live 刷新 8 项、本地文件 `MediaFetch` 适配 6 项、滤波器类型码与缩放算法查询 2 项、DASH 动态 MPD 刷新 9 项、DASH 多 Period 续播 5 项、HLS 分离音轨 6 项、WebVTT 读取 14 项、HLS 字幕 rendition 9 项、DASH 字幕 Representation 9 项 + 分段毫秒换算 1 项、live 字幕跟窗 6 项、多语言字幕选择 8 项、多语言音轨选择 8 项 + 刷新预算白盒 1 项，与 libswresample 重采样 15 项、swscale 通用缩放 3 项 + RGB 组合 5 项（含奇宽 2 项）、422/444 组合 8 项（含
奇尺寸）、422/444→RGB 组合 6 项、full-range 4 项、BT.709 4 项、FCC/SMPTE240M/BT.2020 7 项、10bit 缩放 5 项、奇宽源 2 项、重采样门面 3 项；同日 ffref 原生 oracle 整体注释停用后复验仍全绿）。零警告是本轮清账的结果：1127 处 `"..."` 字面量迁到 `b"..."`（字节字面量，拼接语义不变）、9 处把保留字 `ref` 当标识符、2 处 `SwsScaleError` 单变体使 `catch` 兜底与 `noraise` 分支不可达、3 处声明了却永不抛出的 `raise`、2 处未使用参数/局部变量、1 处调试残留函数；另补齐 `SwrFilterType::from_code`（对齐 `SWR_FILTER_TYPE_*` 的 0/1/2）与 `SwsPlanarScaler::algo` 两个小接口，让原先"只在测试里构造"的枚举变体和"只写不读"的字段各有正式入口。ffref 原生 oracle 差分已于 §345 复活并常驻（72/72：音频解码 MP3 定点逐字节/AAC/Opus、TS/MKV/WebM/MP4/fMP4 逐包、MJPEG/PNG 逐字节、HLS TS 与 DASH fMP4 路径式逐包差分、shine 编码逐字节与 AAC 互通，**Opus 编码与确定性 C 参考逐字节恒等**、AAC `AV_CODEC_CAP_DELAY` 帧计差分（§346 新增 `flush` 尾帧 API）；运行于 docker 镜像 `ffmpeg-moonbit-ffref:nine-ref`，命令见 `ffref/moon.pkg` 头注释），记录见 PORTING_HISTORY §328-§332、§345 与 §346。H.264 等真实码流测试将输出与 FFmpeg 9.0.2 对拍；测试素材和生成说明位于各 `*_realdata_wbtest.mbt` 与 `*_test.mbt` 文件及 `scripts/`。

## 代码位置

- [libavcodec/](libavcodec/)：视频、音频解码与码流处理。
- [libavformat/](libavformat/)：容器解复用、分片读取与参数桥。
- [libavutil/](libavutil/)：基础算法和数据结构。
- [PORTING_HISTORY.md](PORTING_HISTORY.md)：详细实现记录、验收矩阵和排错笔记。

## 许可证

本移植遵循 [LGPL-2.1-or-later](LICENSE.md)。许可证正文见 [LGPL 2.1](COPYING.LGPLv2.1) 和 [LGPL 3](COPYING.LGPLv3)。
