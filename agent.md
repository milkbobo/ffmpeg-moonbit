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
  POC type 0/1/2、MMCO 1–6、短长参考 L0；`H264Decoder` 的 Annex B/avcC 入口跨样本保状态）。
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
- **libavcodec（Opus SILK/hybrid 全模式解码，2026-10 新增）**：`opus_silk.mbt`
  （silk.c 全量：NLSF 稳定化 + RFC 8251 LPC 稳定性检查、LSF→LPC 带宽扩展、激励
  PVQ/LSB/符号、LTP/LPC 合成、mid-only、立体声 unmix）+ `opus_silk_tables.mbt`
  （tab.c 的 63 张表，脚本批量提取）+ `opus_resample.mbt`（libswresample 浮点多相
  重采样器按 dec.c 配置的专用移植：filter_size 16、Kaiser β9、exact_rational、
  invert_initial_buffer/resample_flush/padless=7 全套状态机）+ `opus_decode.mbt`
  （dec.c 包级编排：SILK/hybrid/CELT 分派、redundancy 交叉淡化、celt_delay FIFO、
  多流 sync FIFO、Ogg pre-skip/end-trim 属测试层）。SILK-only 流与 FFmpeg 逐位
  一致（framemd5），hybrid 流系数级位级一致（合成阶段沿用 CELT 3e-6 容差标准）。
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
- **libavcodec（音频编码器，2026-11 新增）**：AAC-LC（`aac_encode.mbt`，
  §270-273）、MP2（`mpa_encode.mbt`，§274）、MP3（`mp3_encode.mbt` +
  `mp3_enc_subband/mdct/loop/bitstream.mbt`，shine 3.1.1 移植，§275）、
  Opus（`opus_encode.mbt` + `opus_enc_rc/math/tables/celt/bands/alloc/psy/psy2.mbt`，
  FFmpeg 原生 CELT-only 路径，§276）、AAC 3GPP 心理声学模型
  （`aac_psy.mbt` + `aac_psy_vectors/`，§277；§281 已把状态结构对齐
  `FFPsyContext`——单 ctx + 每声道 band 状态，`analyze(channel, coefs, prev_bits)`，
  `fill_level`/`pe.min/max` 元素级共享，做 PNS 前必须先有这个前提）与 AAC twoloop 量化器
  （`aac_twoloop.mbt` + `aac_twoloop_tables.mbt` + `aac_twoloop_vectors/`，§278）、
  以及二者组合的可选码率控制链（`aac_encode_config_perceptual`，§279：`ONLY_LONG`
  长窗帧（ONLY_LONG 与两个过渡窗）走 psy→twoloop→λ 严格重试，只有 8 短窗帧仍走简化模型；**默认不启用**，因为感知
  路径在本仓库的音调夹具上比默认路径低约 8 dB SNR——该差距已用
  `_ref/aacenc/aac_ref.exe --in` 交叉验证：同一份输入下 C 与本移植 98/98 带逐位
  一致，属 3GPP 模型在该码率下的固有行为，不是移植问题）。§280 用模型自身的
  噪声-掩蔽比把取舍量化了：感知路径 12.88 dB vs 默认 14.45 dB（谱 SNR 21.6 vs
  31.6 dB），即用 10 dB SNR 换 1.6 dB 掩蔽余量——所以维持 opt-in。
  `AacEncoder::spectrum` 是为此新增的公开访问器（与编码器内部同一条窗 + MDCT）。
  AAC psy 的 C 参考是 `_ref/aacenc/`（`bash build.sh && ./aac_ref.exe > vectors.txt`
  → `python scripts/gen_aac_psy_vectors.py`）；`psy_3gpp_init` 的
  `coeffs[g+1].barks - coeffs->barks` 减的是 `coeffs[0].barks`（累积宽度），
  写成相邻带差会让 min_snr 全掉到 -25 dB 下限；`calc_reduced_thr` 是
  `(sqrt(sqrt(thr)) + reduction)^4`；参考 harness 的 `bitres.bits=0` 使
  `fill_level` 恒 4656，真正跨帧演化的是 alloc/entropy/pe.min-max/prev_band。
  `TWOBAND` 的 245 条向量已在夹具里，§278 的 twoloop 移植即消费它们。
  twoloop 的表同源于 `_ref/aacenc/tables.txt`
  （`python scripts/gen_aac_twoloop_tables.py` 重新生成）；`quantize_band_cost`
  在 `search_for_quantizers_twoloop` 里固定传 **lambda=1.0**（不是搜索用的
  120.0），传错会让 `dists` 整体放大 120 倍、逐带 sf 立刻分叉；codebook 0
  走零带短路（不进量化）、codebook 11 的 escape 用 `165140.0*IQ` 截断而非
  `CLIPPED_ESCAPE` 的 8191；内层循环的 `iters` 上限是 30 且必须跑满语义
  （参考侧 30 次全用完），外层对 `sf0` 的振荡不做收敛判断。
  接进编码器时（§279）有两条硬约束：twoloop 的 `sf` 是内部标度（`Q =
  2^((104-sf)/4)`），写码流要减 4（本模块 `q = floor((|c|·2^(-(s-100)/4))^(3/4)
  +0.405)`），写错 4 就是 6 dB 电平错；写出的系数必须用
  `aac_twoloop_quantize_band` 按同一条 f32 路径重量化，否则成本函数定价的位数
  和实际写出的位数对不上（逐带核对过，正常时误差 ≤6 位，只在 escape 带）。
  码率控制用 `aac_encode_frame` 的严格分支：帧超了就 λ *= min(0.9, rate/frame)
  重来，装得下复位 120——不要用 ABR 容差带那套，容差带会让 `fill_level` 持续
  失血、alloc 逐帧下降。
  AAC 强度立体声（§290，`aac_encode_config_with_is`）与 M/S 一起挪到了量化决策
  之后（§291）：感知路径现在是
  `（每轮 λ：analyze → twoloop → TNS → PNS → 强度 → M/S → adjust → 量化 → 写）`
  （§297 把 analyze 挪进循环、§298 把 TNS 也挪进去：上游的 element 循环整个在
  `do { } while` 里，TNS 搜索读未滤波谱、滤波写进本轮副本，PNS 定价与码流都吃
  滤波后的谱，`coefs` 永远保持干净的左右谱；§299 补上每轮的 `adjust_frame_information`），
  分析读**左右谱**、量化读**混合后的谱**，与 `aacenc.c` 同序；
  简化路径仍先混合（它的每带标度因子就是从真正要编码的那份谱算出来的，
  §279/§280 的 29.045 dB 基线因此逐字节不变）。混合之所以必须**每轮重做**：
  噪声带随 λ 变，而 `apply_mid_side_stereo` 不能碰任一声道判成 `NOISE_BT` 的带
  （解码侧 `aac_apply_stereo` 对 `sect_cb >= 13` 的带根本不做逆变换）。
  IS 判据在感知路径上已经是 FFmpeg 的 `aac_is_encoding_err` 成本比较（§292，
  `libavcodec/aac_is.mbt`，逐位对拍见 `libavcodec/aac_is_vectors/`）；只有默认
  （简化）路径还留着 §290 的频率门 + `|rho| >= 0.95`，因为那条路径没有
  twoloop 的 `sf/band_type/阈值` 可定价。M/S 掩码同理：感知路径已经是 FFmpeg 的
  `search_for_ms`（§295，`libavcodec/aac_ms.mbt`，逐位对拍在同一个
  `aac_is_vectors/` 里——harness 的 `--is` 模式把 IS 之后的两步一起重放），
  简化路径仍用能量掩码（`rm + rs < 0.9*(rl + rr)`，我们的发明，没有 twoloop 的
  成本可定价）。感知路径换判据后的实测：往返 SNR 让出 0.31 dB、码长 +2 B/帧，
  但 IS 夹具上开 IS 的增益从 +1.55 dB 涨到 +3.02 dB——它的目标函数是 λ 下的
  率失真，不是 PCM 信噪比。硬知识：
  ① C 的 `IS[i] = (L + phase*R) * sqrt(ener0/ener01)` 里开方是 **double**
  （除法才是 float），只在存回数组时舍一次 float，照抄才不会差 ulp；
  ② `_ref/aacenc` 的 `--is` 模式要把 `ff_psy_init` 的 `group_map[0]` 写成
  **1**（`psymodel.c:52` 是 `num_ch = group_map[i] + 1`），否则
  `psy.ch[1]` 不是 CPE 的第二声道；
  ③ 夹具里的浮点必须按 C 实际消费的 **float** 存（`%.9e` 足够往返 float），
  否则"完全相等"的断言会假失败；④ escape 码本（cb 11）的
  `quantized = c*cbrtf(c)*IQ` **不能**按「double `cbrt` 再舍 f32」建模——
  本机工具链的 `cbrtf` 在 `c = 0..8191` 里有 2196 个值与它差 1 ulp（§293），
  所以 `aac_twoloop_cbrt_prod` 是从 `dump_tables.c` 的 `CBRT` 记录零转录来的。
  ⑤ **C 的 `float` 字面量必须按 f32 值存**：`0.0035f` 的真值是
  `0.0035000001080334187`，把十进制原值当 f64 喂进 `aac_two_mul` 会差 1 ulp——
  §295 的 `dist2` 差 2 ulp 就是这么来的（拆到 `bmax` 那层才看见）。
  **§296 已把有逐位向量把关的那批清掉**（`C_QUANT`/`ROUND_STANDARD`、`0.00125f`、
  `0.0125f` 与整条 `zspread`、PNS 的 `1.948f/0.9f/0.7f/0.88f/0.85f`、
  `frame_bit_rate *= 1.15f` 的「整数除 → 单精度乘 → 截回 int」，以及
  `options.pns || options.intensity_stereo` 这条带宽条件），而且**没有改变任何
  输出**：三条链的逐位向量全绿，两个端到端夹具的 ADTS 与 §295 逐字节相同。
  原因是这类分歧的窗口只有 8e-9（≈ 1/15 个 f32 ulp），可达分歧需要 `x` 正好落进
  那个窗口。**还在欠账里的**：`aac_psy.mbt` 那批从 C 抄来的十进制常量——但该模块
  的口径本来就是「整数决策逐位、浮点相对误差 ≤5e-4」，要动它得先把 psy 的
  energy/threshold 逐位化，是单独一步；`aac_encode.mbt` 里 TNS 与简化路径的
  `1.4/1.16/0.405/0.95` 是简化模型自己的常量，不参与逐位对拍。
  ⑥ `quantize_and_encode_band_cost` 的分派表把 `cb` 13/14/15 也送到
  `BT_ZERO || BT_NOISE || BT_STEREO` 那条（成本 = 带能量×λ、0 位），
  所以 `aac_two_band_cost` 的条件是 `cb == 0 || cb >= 13`；`search_for_ms`
  的守卫只看 `zeroes`/`is_mask`，PNS 帧的噪声带**一定**以 `cb = 13` 撞进去。
  ⑦ `apply_mid_side_stereo` 的 side 是 `M - R`，不是 `(L - R) * 0.5`；
  浮点不等价，而 M/S 定价用的就是前者。
  ⑧ M/S 命中会改写两声道的 `sf_idx`/`band_type`（成对量化在
  `min(sf_L, sf_R)`），所以量化与写码流必须吃终值——`channel_data_psy` 收
  `final_sf`/`final_cb` 而不是 `AacTwoResult`。代价是右声道 IS 带的 `cb` 这时
  已经是 14/15，跳过量化的条件不能再写 `cb <= 0`。
  ⑨ §297：`aacenc.c:916-945` 把整个 element 循环（**含 `analyze`**）放在码率重试的
  `do { } while` 里，每轮还先重置 `bitres.alloc = -1` /
  `bitres.bits = last_frame_pb_count / channels`，所以上游对需要重试的帧会分析两次，
  第二次读到第一次写过的 `fill_level`/`linpow`。照搬要小心一件事：**严格分支
  （`bit_rate_tolerance == 0`）在 `continue` 前不恢复 `sce->coeffs`**
  （`memcpy(coeffs, pcoeffs, …)` 只在 ABR 分支里，`aacenc.c:1075-1089`），字面搬过去
  等于每重试一次就把 IS/MS 混合再乘一遍。本移植的口径是
  **ABR 的恢复语义 + 严格的 λ 规则**（`coefs` 保持干净左右谱，混合写在副本上），
  只把「每轮重新分析」搬实——这是有意取舍，别当 bug 改回去。效果只有重试过的帧
  看得到（per-frame 打印是唯一证据），感知路径 +0.49 dB。
  ⑩ 回归集的取帧别用手工下标：`gen_aac_is_vectors.py` 的 `TAKE = (0,1,4,5)` 在
  §295 插入新测试后悄悄指到了别的帧，同一条生成命令的强度带覆盖从 64 掉到 9，
  而测试全绿。现在 `choose()` 按参考侧答出来的工具活跃度选帧。
  ⑪ §299 的三条 `adjust_frame_information` 规则：`max_sfb` 剪的是
  **`zeroes[]`**（最后一个 `!zeroes` 的带，窗口组与 CPE 两声道取 max），不是
  「哪一带还有码本」——所以解码侧看到 `max_sfb` 之内**可以**有空带（断言只能写
  `highest <= max_sfb`；写相等会在 24 kbps 上被 5 帧 slack 假失败）；
  `ms_mode` 还有第三种取值 **2**（每一窗每一带都被标记），而 mode 2 **不写掩码位**
  （`encode_ms_info`）；TNS 的带范围读**上一轮/上一帧**的 `ics.max_sfb`
  （`AacEncoder.last_max_sfb`，零初始化 → 流的第一帧必然不发滤波器）。
  这三条在现有夹具上都不改变输出，属于结构闭环：感知路径至此与
  `aacenc.c` 的 element 循环同构。
  ⑫ §300 的八短窗 psy 有四处一写歪就查不出来：形状是**从序列推导**的
  （`window_type == aac_eight_short` ⇒ 8 窗），不要给 `analyze` 加 `num_windows`
  参数，上游两个 block switcher 也正是这么设 `wi->num_windows` 的；
  `aacpsy.c:670` 把本窗首带能量写进 `spread_en[0]` 而**不是** `spread_en[w]`，
  于是窗口 1..7 的扩散链从数组初始的 0.0 起跳（照抄，别"顺手修好"）；
  5.6.1.3.4 的 `pe/a/active_lines` 重置在**窗循环内部**，交给第二估计的"全帧"量
  其实只是最后一个窗的；发布布局是 C 的 `psy_bands[w * 16 + g]` 槽位数组——长窗
  恰好是头 49 个连续槽位，所以换布局不动老向量，而 `prev_band` 必须整表抄 128 槽
  （`memcpy` 语义），否则长短帧交替时预回声读到错值。给短窗做黄金向量时，harness
  是**强制** `EIGHT_SHORT`（真实编码器由 psy 的 `window()` 决定），谱要用逐窗
  攻击斜坡，八个窗能量一致的话逐窗链路整条都是平的、测不出东西。短窗目前只到
  psy：量化器/`scale_factor_grouping`/IS/M-S 仍只吃长窗。
  ⑬ §301 把 twoloop 也做成按窗分组（`AacTwoShape = {num_windows, group_len}`，
  `w += group_len[w]` 一共 15 处外层），四条只能这样抄：一个窗组**共享**一条
  `sf_idx` 与一个码本，所以带成本要把组内 `group_len` 个窗的 `cost/bits/qenergy`
  分别累加再 `dist = cost - bits`；标度因子差链 `prev` 与「平地扫 128 槽升/降 sf」
  的两个循环都**不按窗重置**，分组之间的差约束是连着的；`minsf` 写给组内每个窗的
  槽位（`(w+w2)*16+g`），而 `maxvals/zeroes/sf` 只写在组首槽；
  `ff_pns_bits(sce, w, g)` 的回看是 `(w<<4)+g-1`（同组上一条带），长窗下 `g-1`
  才恰好等价。形态因子那一趟有两条只在短窗露面的上游怪癖（分母把**窗号当带号索引**
  的 `swb_sizes[w]`、守卫 `nzs[g]` 只看第一个窗组），再算上 DC 带保护与
  `de_psy_factor = 8/group_len` 的瞬态降权——当成 bug 改掉就会分歧（把
  `de_psy_factor` 换成常量 1.0 做变异，向量立刻报 `frame 0 slot 96: sf 115 != 116`）。
  flip 带只写 `ms_mask` 位、不做 M/S 混合（上游 `apply_mid_side_stereo` 跳过
  所有 `is_mask` 带，符号翻转由解码器完成）。另有两条硬约束：IS 带写进
  码流的是**强度位置**（范围 `[-155,100]`，正负一样常见），所以
  ①写标度因子必须先用 `cb` 认出 14/15，不能再用 `sf >= 0` 这个"该带被编码"的
  哨兵（否则位置为负的带被整体跳过，section 与标度因子链从那条带起错位）；
  ②`global_gain` 同样要跳过 14/15，否则一条位置会变成整帧的全局增益。
  IS 与 PNS 自 §294 起可以在同一配置里同时开：感知路径的
  `aac_is_search` 拿到的就是 PNS 终值 `cb`/`zeroes`，噪声带与空带都被它自己的
  门排除（与上游 `band_type != NOISE_BT && !zeroes` 同一条），实测同一条噪声夹具
  的噪声带数在开不开 IS 时完全相同（81/78），IS 另加 14 个强度带、再省 3.3% 码。
  IS 带一律**不被 M/S 改写**，但它们的 `ms_mask` 位是**读改写** surviving 的：
  `search_for_is` 把 out-of-phase（flip）标记寄存在 `ms_mask` 里，上游
  `search_for_ms` 只对 `!is_mask` 的带写 0（`aaccoder.c:727`），IS 带原样保留，
  解码侧 `aac_apply_stereo` 正是读那一位决定强度重建要不要取负号。把掩码整个
  重算（能量版的写法）会清掉 flip 位，是行为差异不是记账差异（§295 的向量
  `frame 0 band 28` 抓的就是它）。两个声道都是 `NOISE_BT` 的带可以留着掩码位
  ——`apply_mid_side_stereo` 与解码侧 `aac_apply_stereo` 都用
  `band_type/sect_cb < 13` 跳过混合，只写位不混谱。
  MP3 的表来自编译后 C 参考的零转录 dump（`scripts/gen_mp3_enc_tables.sh`
  可重建 dumper/harness 并再生成表与夹具）；`calc_scfsi` 的 `mp3enc_ln`
  与 C 侧 `shine_ref_log` 必须保持同一段 IEEE 运算（libm log 跨平台位级
  不一致，截断后翻转 scfsi 判定）；子带缓冲按 C 的倒序填充（`for (i=32;i--;)`
  后缀自减——首个样本写入 x[off+31]）；位流 32 位缓存跨帧连续（帧尾不足
  一字的位是下一帧第一个字的高位）。
  Opus 参考链路是 `_ref/opus/build_ref.sh`（给 `enc.c`/`enc_psy.c`/`pvq.c`/
  `celt.c`/`rc.c` 打探针后链接静态库，`OPUS_DBG=1` 逐阶段 dump）；argv 的
  帧数必须与夹具一致（1/12 帧的 psy 状态不同）；C 的 `bands_dist` 用
  `int tdist` 逐带截断、`alloc_boost` 也是截断而非四舍五入——照抄上游，
  不要"修正"成浮点/round；`ff_opus_rc_enc_end` 的 `end >> 23` 必须无符号
  移位（有符号会在 bit31 置位时把 carry 减一）。
- **libavformat（码流层接入）**：`rawaudio.mbt`（裸 ADTS/MP3 分帧，ID3v2/v1 +
  Xing/Info/VBRI）、`codec_tags.mbt`（MKV CodecID / MP4 fourcc 映射）、
  `codec_parameters.mbt`（容器 + extradata → 统一 `CodecParameters`）、
  `probe.mbt`（统一格式探测：`format.c` 的 `av_probe_input_format3` /
  `av_probe_input_format2` / `av_probe_input_buffer2`，20 个 `read_probe`
  覆盖全部已移植容器与裸流；17 组真实夹具对齐 `ffprobe format_name`）
  ⑭ §302 把短窗接进感知路径，但**默认关**（`AacEncodeConfig.perceptual_short` +
  `aac_encode_config_with_perceptual_short`）：一组八窗共享一条 `sf_idx`，瞬态
  夹具掉 6~10 dB 波形 SNR，而短窗的 NMR 还没尺子量，按 PNS / IS 的先例做成
  opt-in，开关关闭时 `use_psy` 与 §301 的门逻辑等价、长窗基线逐字节不变。
  三条硬事实：`AacTwoResult.sf/cb/zeroes` 是 **128 槽**数组、只有窗组起始槽
  携带决策，单组八窗时前 14 槽就是共享决定；`aac_encode_test_tone` 带 LCG
  dither 会触发 EIGHT_SHORT，且从静音历史起步的任何夹具头三帧都是
  `LONG_START → EIGHT_SHORT → LONG_STOP`，所以基线断言必须按窗口形状分帧
  比，不能要求整条流相等；探针里的低 SNR 不是延时错位（helper 已做 1024
  对齐，扫过 960..1089 的最优延时仍是 1024）。外部 ffmpeg 9.0.2 解这两条
  短窗流与本解码器 PCM 差 3.5e-9 / 140.5 dB，说明码流语法没问题，差的是
  量化取舍。临时 main 包先移进 `.trash/<日期>/` 再跑全量测试。
  ⑮ §304 短窗分组闭环：FFmpeg 注册的窗回调是 `psy_lame_window`（`psy_3gpp_window`
  是 `av_unused` 死代码且签名不匹配，别移植那个）。移植体在
  `libavcodec/aac_enc_window.mbt`（`AacLameWindow`，每通道状态：16 个子块峰值/
  `prev_attack`/`next_attack0_zero`/`next_grouping`），编码器在 buf 构造时逐帧
  调（`buf[523..1568)` 就是 C 前瞻覆盖的同一块样本——同步改写口径），CPE 取
  较早首攻块；**每帧都跑**（节奏必须与 C 一致，向量的 next_grouping 链才对得上），
  但只在 `use_psy && is8` 消费（`window_grouping[i]` 展开），其余路径单组不变
  （stash 前后 default/perceptual 流字节级一致已证）。写侧短帧 sf/cb 平铺 128
  槽（`w*16+b`）、sections/scalefactor/spectral 全部按组主序、sf 差分链跨组连续、
  `scale_factor_grouping` 按 `!group_len[w]` 写。黄金向量在
  `aac_win_vectors/`（26 帧×2 通道整数决策逐帧全等，`_ref/aacenc` `--win` 模式
  再生）；外部 ffmpeg 9.0.2 解分组流 138.5 dB。NMR 复测：分组改善 0.8 dB 但
  未翻过简化臂，`perceptual_short` 仍 opt-in。测试侧 fixtures 必须 `pub let` 且
  引用带 `@包名.` 前缀；Int→Int32 无转换方法，直接 Int32 算术。
  ⑯ §305 PNS 八短窗形态：`mark_pns`/`search_for_pns` 按 `w += group_len[w]`
  分组（mark 的门组内求和/取 min + 瞬态门；search 的噪声逐窗拉 LCG、逐窗按该窗
  psy band 与该窗槽 `sf_idx/band_alt` 定价，决策写组起点）。关键是**元素 sticky
  槽状态**：C 的 `sce` 把 `sf_idx/band_type/zeroes`（128 槽）跨帧保留，twoloop
  只写组起点但速率循环缩放全部槽、zero-band 段写被置零的内窗槽，而
  `search_for_pns` 恰恰读这些遗留内窗槽定价——`AacEncoder` 挂三条 sticky 数组、
  每轮 `>12→0` 清理、`aac_twoloop_search_pns` 加 `sticky?` 参数原地写回。
  向量 `aac_pns_vectors/fixtures_short.mbt` 连每帧末的 STICKY 128×3 都逐槽钉死；
  短窗+PNS 流 ffmpeg 9.0.2 解码 0 errors、双解码器一致 140 dB。
  ⑰b §307 窗型状态机换 FFmpeg 语义（§304 偏差①收口）：
  `aac_lame_apply_block_type(state, uselong)` 纯函数——发射存储态（短窗路径先
  补丁 ONLY_LONG→LONG_START、LONG_STOP→EIGHT_SHORT），存 computed block type
  （短窗运行必多一帧安静 EIGHT_SHORT 再 LONG_STOP 回长窗）。`AacLameWindow.
  next_window_seq` + 输出 `window_type`；`--win` 夹具改 8000 样本周期（burst 只在
  前半）后 wt0 四态全覆盖 + 首攻块全表，26×2 向量含 window_type 逐帧全等。编码器
  感知短窗路径 seq = pair 合流机（uselong=各通道 AND，「任一短则短」，与分组同
  口径；两通道一致时与 C per-channel 机逐位同），`AacEncoder.lame_pair_seq` 承载；
  其余路径保留旧机。steady 夹具因 10.0 初始峰值开跑即一次短窗运行（与 FFmpeg
  同输入一致）。NMR 复测仍劣（12.07/17.28 vs 9.75/15.62），opt-in 不变。
  ⑱ §308 NMR 悬案第三方裁决：docker ffmpeg 9.0.2 原生编码器编同夹具
  （fixtures_ff_ref.mbt 内嵌流+解码），同一把 psy 逐带尺上三方对拍——128k
  简化 12.74/感知 14.03/原生 14.41，64k 18.18/20.19/18.56。「感知臂劣于简化臂」
  是 FFmpeg 短窗固有行为（原生也劣），opt-in 定案（选 FFmpeg 语义而非更优
  NMR）；感知臂与原生差 <1.7 dB（128k 反超）= 移植质量背书。
  `aac_ffmpeg_ref_test.mbt` 固化断言。FIL 元素无 element_instance_tag
  （id+count 直连，首帧 count=14 版本串）。
  ⑳ §310 统一播放 API 骨架（申报书①第一期，音频线）：`libavformat/playback.mbt`——
  `MediaFile::open`（probe→分发 MP4/MKV/WebM/Ogg/WAV 四适配器，MP4 样本按 stco 切片
  跨轨 DTS K 路归并）→ `StreamInfo` 表（codec_id 统一 FFmpeg 名）→ `next_packet`
  → `AudioDecoder::open/decode`（aac=from_asc、opus=head、pcm_s16 直解释），
  `MediaError` 闭合分类 + `message()`，failable API 用 raise 风格。黑盒 5 测：
  WebM/Opus、Ogg/Opus、WAV/PCM（解出 PCM 与 data 块逐字节同）、MKV/AAC（本仓
  编码器现做→mux→facade→解码 60.3 dB）、FormatNotFound。坑：probe 夹具是 base64
  且多为截断探针样例（demux 测试用 muxer 现做）；probe_fixture_aac 首帧带 LFE，
  ASC 声明布局严格报错是设计语义。⑳b §311 播放 API 第二期：`MediaFile::duration_seconds`（四容器各自口径：mvhd/timescale、
  Matroska Duration×scale、Ogg granule−pre_skip、WAV 计数）；`decode_audio_file` →
  `DecodedAudio`（decode-audio 命令引擎）+ `to_wav_s16`（WavMuxer 限幅交错导出）。
  黑盒 3 测：WAV to_wav data 块逐字节恒等、Ogg 时长精确到毫秒、四适配器时长断言。
  ⑳c §312 播放 API 第三期（视频线首条）：`VideoDecoder::open/decode`——h264 经
  `ff_h264_decode_extradata`（avcC/Annex B 双形态）装参数集，is_avc 走
  `decode_avc_sample`（None=重排缓冲未出帧）否则 `decode_annexb`；`VideoFrame`
  包 H264Frame 不复制。真实 MKV（H264+AAC）facade 解帧与直连像素级全等。
  ⑳d §313 播放 API 第四期：`VideoFrame` 重构 tagged union（H264/Hevc/Vp9/Av1）
  + 统一 `yuv_bytes()`（planar YUV，extract-frame 出口）+ StreamInfo 补宽高
  （MP4 tkhd/MKV PixelWidth）；三家分发——VP9 `decode_packet`（superframe 内建，
  真实 libvpx 五帧 MD5 与 FFmpeg 逐帧一致）、AV1 `decode_packet`（OBU 内建）、
  HEVC 批式（入口每调用新会话→facade 缓冲至 finish_video 拼接，hvcC
  lengthSize 从偏移 21）。全量 1434/1434。⑳p §327 播放 API 第五容器
  MPEG-TS：Source::Ts（probe mpegts → playback_ts_build）；H264 = 首 PES
  作 AnnexB extradata + IDR 检测；AAC-ADTS = PES 内切帧（cursor[1] 帧内
  进度）+ ADTS 头直构 2 字节 ASC；duration = 首末包 90kHz 跨度。docker
  对拍：首帧 YUV MD5 逐字节一致、AAC 解码 7/19456 孤点。坑：**`is Ts(_)`
  运行时恒 false（guard 失效 → abort）——用 match 转 Option**；旧方法
  语法 fn name(self:T,..) 是方法定义（unbound → fn T::name）；wasm 的
  fail() = abort 无输出（cmd 错误路径改 println+return）。wasm 全量绿。
  ⑳q §328-§331 ffref 全面差分（音频/容器/图像/编码）：TS 门面四处真实
  偏差修复（视频留一 PES 对齐 h264 parser AU 语义、ADTS 帧帧 pts 用
  av_add_stable 插值、AAC 帧全 keyframe、ADTS 头保留）、MP4 discard 帧整帧
  丢并消耗 skip_samples（decode.c 语义）、MP3 oracle 按注册名 `mp3` 选定点
  版、MJPEG/PNG 逐字节恒等（镜像需 zlib）、shine 拼接码流逐字节恒等、
  Opus/AAC 走互通+SNR（原生编码器语义≠打补丁 C 参考）；**AAC 默认路径
  无 coef2minsf 下限的饱和 bug 由 oracle 揭出并修复**（3.4→67.7 dB）。
  **oracle mem_read 越界读是 §328 前所有包级对拍的隐患**（症状：包数/尺寸
  随机错）。wasm 钉住：playback_oracle_pins_test.mbt。
  ⑳r §332 WAV parser 分包：C 对 WAV 音频全量 AVSTREAM_PARSE_FULL_RAW——
  有 parser 的编解码按帧分包（MP3 整帧含头+CBR pts 1152 步进；ADTS 逐帧
  含头+pts NOPTS；**RAW_AAC1 无 C 锚**：parser 意外同步字乱切+解码器拒包
  内多 RDB，我们取整块单包+decode_all 消费循环）。门面 AudioDec 增 Mp3
  分支。坑：decode_all 剥 ADTS 头必须在切片前（错位 7 字节→幽灵迭代）。
  oracle 61/61；wasm 1457/1457。
  ⑳x §350 grouping 链修复 + ABR 落地（wasm 1709/1709 + ffref 72/72 +
  NMR 128k 15.14/64k 19.12 双超原生 14.41/18.56）：①时序重构后重验——
  端口 k=23 与 C k=52 全字段相等（atk/grp/ngrp/att_sum/carry 链），
  §348 grouping 分歧=滞后 la，已消失；②**grouping 链真 bug 一行修**：
  发射窗分组取上一次分析存的 next_grouping（=d.wi_grp_pre），不是当前
  group_byte（早一帧）；③"section too long"真凶=测试 helper：ms 位按
  （窗组×频带）写而 helper 只读 max_sfb 个位——四处组感知修复
  （sect_cb[g][b]/ms_bits[g][b]/scale_factors[g][b]）；④ABR 落地
  （§347 已验证移植）+ 8 处质量门重校（CBR 纪律→C 稳定窗 +12.5%、
  SNR 18→15/25→22、IS -2→-4、3 个 short 测试钉 no-op 语义
  changed==0/NMR==）。AAC 编码剩余字节差=域伪影（向量重生成）。
  ⑳w §349 感知路径发射时序重构：**帧 i 用 buf_i[523..1568) 分析决定
  buf_{i-1} 的窗型并发射之**（C 的 call k 同 call 内 la 决策+MDCT 发射，
  la=缓冲里的下一帧头；N 帧→N-1 流内包+flush 双包=N+1 与旧总数同）；
  flush 恒两包（pending 窗 la=NULL + [hist|z]，C 探针 1/2/3/12 帧全实证，
  remaining 归零不拦第二包）。API：encode_frame→Result[Bytes?,String]、
  flush→Result[Array[Bytes],String]（对齐 OpusEncoder）；新状态
  pending_bufs；LAME analyze 节奏放开到 perceptual、use_psy=perceptual
  （is8 一律 psy/twoloop）；简化路径保持同步。调用点 10 文件 15 站点
  （简化站点双 .unwrap()；Option::unwrap 存在，panic on None）。5 基线
  朝 stock 重校：drain 尾包 la=NULL 冻结窗型（短 run 溢 eight-short 到
  半零窗）→ 尾包门 25/18 dB、stop>=1 放开；NMR 64k 感知臂反超原生
  2.89 dB → guard 改 -2/+6。**质量：感知 NMR 128k 15.33 / 64k 21.45，
  双码率首次双超原生（14.41/18.56）**。wasm 1709/1709；ffref 72/72。
  ⑳v §348 窗口模型真相（纯发现片、代码零变更）：**stock 唯一窗口模型 =
  psy_lame_window**（aacpsy.c:1022；psy_3gpp_window 是 av_unused 死代码，
  其 iir_filter(int in) 收 float 实参隐式截断归零也旁证）——§347 路线图
  ①「移植 IIR」作废；真分歧 = 端口感知路径用自研 attack machine 而非已
  移植的 LAME 机。LAME 预热瞬态（prev_energy_subshort 初始 10.0 vs 峰
  0.3）解释 stock 静止正弦切短窗；WINDBG 探针实证 carry 链逐帧一致。
  剩两点：grouping 边际分歧（stock 子块 1 vs 端口子块 4）、**la 区域
  滞后一帧**（stock 的 la 含下一帧头；同步 rewrite 旧一帧）→ 修法 =
  发射时序重构（包缓冲一帧、encode_frame 返回 Option、flush 双包）。
  use_lame=perceptual 实验：ffref 72/72 仍绿、wasm 11 红全是 plain≠short
  旧区分钉子（perceptual_short 轴 stock 不存在）→ 回滚，11 测试重设计
  下片做。坑：patch 脚本（python）里 C 的 \n 须写 \\n；docker COPY 层
  缓存看内容哈希；grep -c=0 短路 && 链再次踩中。
  ⑳u §347 AAC 字节差分根因链（无新特性、实验全回滚、仓库全绿）：探针
  基建 nine-dbg（aac_ref_patch.py in-image 适配 + aacpsy/aaccoder/
  aacenc_is 探针对象 ar r 进档案副本）+ 两侧同格式打点逐层 diff。四大
  发现：①stock 选项默认全开（pns/is/tns=1、ms=auto）vs harness 全 0——
  options 字典对齐有效但 **bit_rate_tolerance 经 dict 静默失效**（须
  cc 字段直赋）；②**MDCT 域伪影**：harness 域=65536=2× stock av_tx
  32768，全部向量烙着「stock 常数×4× 能量」——域改 32768 后 psy/twoloop
  与 stock 对齐到 f32 噪声（thr/TWOINIT sf/帧0 终态全一致）但 SNR 崩
  5.9 dB（SPL/ATH 绝对锚点锁旧域）→ 域统一须绑定全量向量重生成；③
  rate control 双分支：stock 默认走 ABR（its==0 必更新、稳定窗 sqrt√
  钳 [0.9,1.1]），strict 分支无迭代上限会死循环（挂死实证）；ABR 已
  移植且帧 1 预算 1580==1580 逐帧验证，但有状态 lambda 破坏三个自基准
  （IS 资格阈值随 lambda 收窄清零、同窗序列⇒同字节不变量失效）→ 回滚；
  ④窗口机：stock=psy_3gpp_window（IIR 探测器+一帧超前），端口=自研同步
  attack machine（仅 LAME 路径有向量）——静止正弦上 stock 切
  EIGHT_SHORT 端口不切（TWOPARM cutoff 682→85=短窗指纹）= 字节对齐
  最后大件。AAC 测试=框架差分；调试代码全清。坑：heredoc 连吃 `\\n`
  进 C 源（C 编辑用 Edit 工具）；顶层 let mut 禁止用 Ref；-F 过滤器
  不生效用标记切分；stdout 块缓冲跨测试污染段；杀 docker 任务后
  Docker Desktop 假死要重启；ar grep -c=0 短路 && 链。
  ⑳s §345 ffref 预言机复活 + HLS/DASH 路径式差分：moon.pkg 恢复
  native-stub/link；包级 supported_targets="native"（wasm 跳整包，9 条
  unused_package 清零，mooncakes 消费者仍零 C 依赖）。新 C 面
  ffref_probe_path（真 avformat 按路径开输入，hls/dash 自行跟随清单开
  分片）+ ffref_write_file（mkdir -p 铺场）；包遍历抽 probe_common。
  fixture 四套（aac/libx264；HLS TS、DASH SegmentTemplate+Timeline）
  base64 内嵌，纯侧 media_fetch_from_map 同字节喂 StreamingMedia；
  断言包数/流号/尺寸/关键帧逐包精确、pts 按流内 tick 域 delta ±1 tick。
  **ffmpeg hls demuxer 首段双重读 → 首段 pts 滞后一帧**（ffprobe 双验；
  纯侧=裸 TS 真值；测试 pts_from_segment 参数记录该 oracle 行为）。
  dashdec 依赖 libxml2 → 镜像叠层 .scratch/ffref/Dockerfile.xml，新 tag
  **ffmpeg-moonbit-ffref:nine-xml**（configure 开关是 --enable-libxml2；
  liblzma 传染 → moon.pkg 链接 -lxml2 -llzma；运行命令见 ffref/moon.pkg
  头注释）。ffmpeg-src 的 hevcdec.c 携带主树实验损伤，GitHub n9.0.2
  raw 还原后镜像才编译过。oracle 69/69；wasm 1708/1708。坑：sed BRE
  `\+`=量词；docker build 接管道吞退出码；ADD tarball 网络不稳改 COPY
  本地树；:nine 残留空 /ffmpeg 目录会把 cp -r 拷成子目录。
  ⑳t §346 编码器逐字节 oracle：镜像叠层 .scratch/ffref/Dockerfile.ref →
  **ffmpeg-moonbit-ffref:nine-ref**（/usr/local-ref/libavcodec_ref.a =
  stock 档案 ar d enc/enc_psy/pvq + ar r ref_det 确定性孪生版 patched
  对象；nm 校验 ff_opus_encoder 是 R 不是 T）。Opus 逐字节一次全绿
  （10 帧 13 包恒等；fixture 量化到 s16 网格使两侧浮点输入恒等）。
  oracle 逼出 C 的 AV_CODEC_CAP_DELAY 帧计（12 帧进 13 包出、flush 出
  2 包末包编码 1024 零样本）→ **AacEncoder::flush() 落地（§304 遗留
  收口）**：encode_pipeline 抽出共享、lame_grp 改携字节、la==NULL 分支
  （默认 seq=prev 冻结；LAME uselong=!(prev==short) 机器照走）。
  **AAC 逐字节=装配级漂移开放前沿**：stock 每帧跑 twoloop、端口默认
  路径是简化量化器（必然不等）；感知路径大幅逼近（首包 global_gain
  相等）但 sticky 漂移——子系统向量全位级、端到端装配从未字节验证，
  探针档案配方对 AAC 同样适用留待根因。收口：感知 framing 差分
  （13==13 + 双流等样本数）。oracle 72/72；坑：nm R/T、无 `?` 传播、
  Opus 平面是 Float/ADC 是 Double、python 补丁先删后建顺序、fmt 钩子
  编辑间改文件。
  ⑳o §325 libswresample 第一片：
  `libswresample/` 新包——同采样率转换（`swr_flt_to_s16` =
  audioconvert.c 的 av_clip_int16(lrintf) **round-half-to-even** 逐分支
  复刻、planar→packed 交错、mono→stereo 复制）。**§315 ±1 残差翻案**：
  归因 dither 实为舍入——to_wav_s16 截断→swr 舍入后 docker 参考非零差
  13k→12 孤点（opus 解码尾数）。坑：只读 struct 测试不可构造（加
  Swr::new）；packed s16 读回需符号扩展。libswresample 3/3；wasm
  全量 1446/1446。
  ⑳n §324 libswscale 422/444：
  `yuv422_to_rgb24`/`yuv444_to_rgb24` 共享每行核（chroma 行映射差异，
  同官方表）；合成帧测试（444 Y 轴 = 官方 blob、422≡444 恒定 chroma、
  BGR 互换）。libswscale 3/3；wasm 全量绿。
  ⑳m §322 extract-frame RGB 输出：
  `--format yuv|rgb24|bgr24`（缺省扩展名随格式；JSON format 字段区分）——
  planar blob 拆三平面走 §321 官方表。对拍定论：docker sws 主路径 chroma
  **半像素中心插值**（bilinear 相位 0.5，1:1 也插）→ G 回绕 ±255 形态，
  字节对齐需 hscale 半像素插值移植（后续片）。坑：匿名 fn 是
  `fn () -> T {}`；frame.width() 已 Int。wasm 全量绿。
  ⑳l §321 libswscale 第一片：`libswscale/`
  新包——YUV420P→RGB24/BGR24（yuv2rgb_1_c_template 查表语义，BT.601 limited）。
  **表数据 probe 而非公式复算**：FFmpeg 9 系数经 cms 双精度重算（y_coeff=9539
  非旧公式 9540），镜像内编译官方 yuv2rgb.c 直调 init_tables 全量 probe 内嵌
  （blob 2048 + base 1280×3 + gv 偏移）。实测矩阵：CLI/c-only/单线程三种构建
  输出互差（blob ±1 LSB、帧 chroma 255 级——graph 主路径 hcscale 半像素插值，
  unscaled 特判失效）→ 对拍锚 = 官方表自洽 + ramp 形状（前 17 零/单调/
  near-white 253）+ G uint8 回绕锚点。坑：b"..." 是 base64 文本非解码字节
  （走 av_base64_decode）；顶层 let 小写；Bytes 无 op_set。libswscale 2/2；
  wasm 全量 1442/1442。
  ⑳k §320 ffref 镜像加 libdav1d
  （configure --enable-libdav1d + 链接 -ldav1d）：AV1 从占位转正为正式字节
  差分——dav1d 与我们 AV1 解码器逐字节恒等。**视频四家对拍矩阵闭环**：
  H.264（含 444）/HEVC（含 B 帧）/VP9/AV1 真实流全帧全部进程内常驻回归
  （42/42）。
  ⑳j §319 HEVC/VP9/AV1 真实流 e2e（§313
  遗留收口）：docker 三流 fixture（64×64×5 帧）；修 HEVC "missing PPS"（hvcC
  参数集 numOfArrays 展开 seed 进批式 pending，镜像 hevc_parse_extradata）+
  HEVC B 帧显示序（finish_video 按 POC 排序）；**ffref SIGSEGV 根因=MemIO 栈
  变量被 avio 回调悬垂引用**（堆分配修复——C 绑定「#borrow vs 存储」正反面
  教材）。ffref 42/42：HEVC/VP9 全帧与真 FFmpeg 逐字节恒等；AV1 因镜像无
  libdav1d 暂记 oracle 拒绝语义。坑：moon `try?` 已移除（try Some/catch None）；
  catch 臂类型须同成功值。
  ⑳i §318 ffref 视频帧差分：
  `ffref_decode_video`（真 libavcodec 解码→紧凑 planar YUV，chroma_mode
  0/1/2=420/422/444 与 yuv_bytes 同布局），H.264 4:4:4 fixture 全帧**与真
  FFmpeg 逐字节恒等**（ffref 39/39）。坑：**FFmpeg 9 AVPixelFormat 枚举重排
  （5=YUV444P 非 YUVJ420P）按符号名判**；独立 C 诊断传裸 malloc 指针会让
  `Moonbit_array_length` 读垃圾（宏从对象头取 length）；mem AVIO 补
  AVIO_SEEKABLE_NORMAL。
  ⑳h §317 CLI ④⑤收口：`cmd/extract-frame`
  （首视频流第 N 帧 planar YUV + JSON 摘要，docker 对拍首帧 MD5 逐字节一致）与
  `cmd/extract-cover`（MKV Attachments 新移植 + MP4 ilst/covr 捕获 →
  `MediaFile::cover` 统一 API；两容器提取 MD5 恒等 2e84456f…；MP4 covr fixture
  系 python 手搓注入+size 链修复，ffmpeg ipod muxer 拒写 mjpeg）。坑：else-if
  挂错层级永不执行；`& 0xFFFFFF == 13` 优先级。全量 1439/1439——申报书②五命令
  全部交付。
  ⑳g §316 ffref 原生参考 oracle⑳g §316 ffref 原生参考 oracle（C 绑定落地）：`ffref/` 包
  全 native-gated——stub.c 走 mem AVIO + av_read_frame / avcodec+swr 首音频流
  解码，Value-as-Bytes 扁平 blob（每包 32B 记录 + 每流 timebase / s16 PCM），
  `ffref_probe`/`ffref_decode_audio` 安全包装。运行于专用镜像
  ffmpeg-moonbit-ffref:nine（单阶段：aliyun apt + GitHub 官方 n9.0.2 tarball
  静态库 + moon CLI；linuxserver ENTRYPOINT=ffmpeg 必须 --entrypoint sh）。
  差分 4 条 38/38：Ogg/WAV 逐包 tick 级（±1 rescale）、真 FFmpeg opus 解码
  逐样本（±1）；§315 三修复获进程内常驻回归。坑：moon Windows native 要
  MSVC（本机 MinGW 不行）；新版 moon -p 是目录路径、test 独立编译单元（黑盒
  模式 import 本包 + fixture 同文件）、suberror 才是 error 类型、assert msg=
  标签、**AV_VERSION_INT 新编码 (maj<<16)|(min<<8)|micro**。wasm 全量
  1438/1438 不受影响。
  ⑳f §315 CLI ②③ + 三处 ffmpeg 对齐修复：
  `MediaFile::dump_packets_json`（playback_dump.mbt：按容器时间基 stream_timebase
  的 JSONL，stream/limit 过滤，仅发射行计数）+ `cmd/dump-packets`、`cmd/decode-audio`
  （--output 写 §311 WAV，stdout summary_json）；**ogg.mbt pts 重写为 ffmpeg 语义**
  （非 EOS 页按页 gp 后缀和回退、EOS/无 gp 页走 lastpts 链 + 末包 end-trim——
  oggparseopus.c 逐行核对，RFC 7845 gp 含 pre_skip 的文件首包 0 而非 -pre_skip）；
  **opus 空熵帧修复**（opus_rc_init 放开空帧，空 CELT 帧经 MDCT 重叠输出上帧衰减
  拖尾——1 字节 TOC-only 包不再 concealment 全零）；**decode_audio_file Ogg 首段
  pre_skip 裁剪**（ffmpeg initial_padding 语义）。docker 对拍：dump-packets 四容器
  pts/size/flags 全对齐（opus 0/20/40、mkv、m4a 含 -21.3ms edit list、PCM WAV
  1024@0/576@64）；decode-audio 对 ffmpeg 参考解码 max|diff|=1（纯 ±1 dither）。
  已知限制：AAC-in-WAV 分包 ffmpeg 走 AAC parser 按帧（738/383），我们按块对齐。
  标签参数调用语法 `f(x=v)`（旧 `x~:` 报 parse error）。全量 1438/1438。
  ⑳e §314 播放 API 第五期 + CLI ①：`MediaFile::probe_json()`（ffprobe 风格
  format+streams JSON，自带 RFC 8259 转义）与 `cmd/probe`（x/fs 读文件→JSON 打印，
  错误 `MediaError::message` + 非零退出，moon.mod 加 moonbitlang/x）。命令实跑：
  WAV/MKV 双流/垃圾字节三路径全对。转义字面量坑：含反斜杠的 MoonBit 源码一律
  码点比较 + `\` 取反斜杠，不走 heredoc/python 转义链。全量 1436/1436。
  下一步：dump-packets/decode-audio 命令（引擎已就绪）/seek/HEVC·AV1 e2e。
  ⑲ §309 CPE common_window=0 分叉（§304 偏差②收口）：窗决策彻底 per-channel——
  `AacEncPlan` 每通道（seq/带计划/分组/窗数），attempt 循环全部吃自己的 plan，
  `lame_seq` 数组替代合流机（判定一致时逐位同），`last_max_sfb` per-channel。
  common_window 判定 = 类型相等 &&（非短窗 || 分组展开相等）；forked 时写侧
  `assemble_frame` 走双独立 gg+ics_info+body 分支（无 ms），stereo 工具/ms 计数/
  max_sfb 合并/mark_is 全部加 common_window 门。非对称瞬态 8/11 帧 forked，
  docker ffmpeg 解码 0 errors、双解码器 140.2 dB；四条长窗基线字节不变。剩
  la==NULL flush（需 flush API，文档化保留）。
  ⑰ §306 立体声对八短窗形态（短窗工具链收口）：`aac_is_search`/`aac_ms_search`
  按 `w += group_len[w]` 分组——IS 的能量门组内求和、逐窗按各自 psy band 定价但
  sf/cb 取组起点槽，`freq_mult` 分母是 `1024/num_windows`；MS 的 Mmax/Smax 取全组
  峰、bits 逐窗扣除、输出规整到槽长（`aac_ms_fit`，sf 源恒 128 而 cb1 视图长度随
  窗形变）。**MS 重写必须回流 sticky**：分组会跨帧变化，上一帧的组起点可能变成
  下一帧的内窗（向量帧 1 slot 53 实证）；长窗全部槽都是组起点、回流无行为差异
  （四条长窗基线字节不变已证）。写侧 `ms_used`/`mark_is` 组走、`ms_present` 计数
  按 C 逐窗槽走（多组帧取不到 mode 2 是 C 原样）。harness `--isms` 模式
  （`group_map[0]=1` 共享 analyze + `alloc /= chans`）；向量
  `aac_is_vectors/fixtures_short.mbt`（532 槽 + STICKY 全等，is=77/flip 21/ms=140）；
  pns+is+short 全开流 ffmpeg 解码 0 errors、双解码器 140 dB。全量 1421/1421。

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
- **wasm 体积测量**：`python scripts/generate_wasm_size_probe.py`（重新生成探针 →
  编译 `wasm`/`wasm-gc` release → 报告原始/gzip 体积并做字符串指纹验证）。
  `wasm_probe/main/main.mbt` 是生成物，勿手改；**公共 API 变更后探针失配**
  （`moon check` 报 unbound/参数不符），重跑脚本再提交。

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

- **wasm 运行时 externref 链表的 2 GiB 地址问题（moonc v0.10.16+b1a0e846e；
  v0.10.17+d971670cd 生成的 wasm 仍使用相同判断）**：
  生成的 `moonbit.alloc_externref` 以 `i32.lt_s 0` 判断空闲链表为空；当有效链表指针
  越过 `0x80000000` 时会误判为空，反复扩张 externref 表，最终 `table.grow` 失败。
  本项目的 16 帧 PS 对拍夹具或额外 600 KB 测试数据可触发，8 帧夹具可全量通过。
  诊断中把判断临时改成 `head == -1` 可避免该误判；不要直接修改生成的 wasm 或已安装
  工具链作为项目修复。具体证据见 AAC PS 交接记录。

- **绝对不能用 heredoc**（`python - <<'EOF'`、`cat <<EOF` 等）：在本机 Git Bash +
  工具链的组合里，heredoc 内含 `\n`、`\\n`、引号或 NUL 转义的内容会被反复改写/截断，
  已三次写入损坏文件（Python `SyntaxError: unterminated string literal`、源文件里出现
  真实换行甚至 NUL 字节）。**生成或修改脚本一律用 Write/Edit 工具写完整文件**；必须在
  shell 里内联 Python 时只允许无反斜杠转义的单行 `python -c`。
  另一类症状是**进程挂死**：工具以 stdin 喂脚本（`bash -s` 语义）时，heredoc
  结束符一旦因缩进/转义改写而不匹配，bash 会一直读 stdin 找结束符，连后面的
  `exit` 也被当成正文吞掉；工具持有的 stdin 不给 EOF，进程便永不返回（实测
  结束符正确 `exit=0`，带缩进 `timeout 3` 得 124）。`bash -c` 把正文放在命令
  字符串里、不从 stdin 取，结束符错只报 warning 后退出，不会挂。CRLF 的 `\r`
  在 Git Bash 文本模式下会被吃掉，不是这里的元凶。
- **wasm `__moonbit__init` 局部变量上限（约 5 万）**：包级大 `Array` 字面量每个元素都会
  变成 init 的局部变量，libavcodec 白盒测试包已贴近上限——新增大表/大向量时**禁止**用
  `Array[Double]`/`Array[Int32]` 字面量，改为 **base64 `Bytes` 字面量（数据段，不占局部）
  + init 期解码**（参考 `aac_ps_tables.mbt` 的 `ps_unpack_f64/ps_unpack_huff` 与
  `scripts/extract_ps_tables.py`）。注意 `av_base64_decode` 的 `out_size` 是**截断上限**，
  传 `0` 会得到空数组，应传 `1 << 20` 之类的上界。另外：未被引用的顶层表会被 DCE 干掉，
  "只加表不接线就能编译过"是假绿，接线后才见真章。
- 错误标记函数用 `raise`（不是 `raises`）：`fn f() -> Unit raise { ... }`；
  测试块内可直接用 `.unwrap()` / `fail(...)`。
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
- **纯库测 wasm 体积必须防 DCE**：链接期全程序死代码消除会删掉未被真实调用的函数——
  `let _ = @pkg.fn` 裸引用、「函数引用数组 + `.length()`」都会被优化器折叠掉
  （分别只剩 2.6 KB / 14.6 KB 空壳，库字符串指纹全缺失）。可靠做法是用发散表达式
  `abort("p")` 作实参**调用**每个公开函数（调用点无法消除，函数体必须链入），见
  `scripts/generate_wasm_size_probe.py`。验证库真链入要查 **UTF-16LE** 字符串指纹
  （wasm 目标下 `String` 按 UTF-16 存储，ASCII `grep` 必漏判）。
- **可执行包声明（TOML 版 moon.pkg，0.1.20261016 工具链）**：`pkgtype(kind: "executable")`；
  `is_main` 键不存在（报 Unknown key）。moon.pkg 是 TOML 风格（`import { "…" }`、
  `warnings = "…"`），写成 JSON 对象在包发现阶段直接解析失败。
- **标签参数三处语法不一致**：`.mbti` 显示 `label~ : T`（必选）/`label? : T`（可选）；
  **调用点**写 `label = expr`（不带 `~`，写 `label~=…` 报 E3016 提示正确语法）；
  带标签参数的函数**不能作裸值引用**（"can only be applied directly"），自动化只能生成调用。
- **顶层 `let _ = …` 不允许**（通配符只能局部绑定，顶层必须具名）；关键字是 `fn`
  不是 `func`（写 `func main` 会在函数体里堆出大片级联解析假错误）。
- **`Any` 在当前 core 不存在**：函数引用无法装箱进异构数组，按「同签名分组」也只能
  组同构数组；`moonbitlang/core` 裸包**不能** import（Cannot find import），要用
  `moonbitlang/core/builtin` 或具体子包（`core/math`、`core/v128`…）。
- **wasm-gc 目标下 `core/v128` 不可用**：`*_v128`、`av_md5_sum_x4` 等目标受限函数
  在 wasm-gc 编译报 "Value … not found"，测体积时需剔除（探针脚本自动迭代剔除）。

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

- **H.264 4:2:2 的 nz 邻居按 scan8 缓存的纵向堆叠**：两个 8x8 色度块在缓存里是
  **上下叠放**（8x8#1 在第 6–7 行、#2 在第 8–9 行，各占列 4–5），不是左右并排。
  因此块 i（0..7，行 6+i/2、列 4+i%2）的左邻：奇数 i 取块 i-1，偶数 i 取**左宏块
  同分量的 b1/b3/b5/b7**；上邻：i>=2 取块 i-2，i<2 取**上宏块同分量的 b6/b7**
  （`fill_decode_caches` 的 `!chroma_y_shift` 填充正是这个几何）。nC 与 CABAC cbf
  上下文都要用这套关系。
- **H.264 4:2:2 色度 DC 反量化查 chroma_qp+3 的表**：2x4 Hadamard 的增益比 2x2 低
  一半，C 用 `qp[0] = sl->chroma_qp[0] + 3` 补偿（`h264_mb_template.c`），AC 残差仍
  用原 QP。漏掉 +3 时整帧色度系统性偏移。
- **H.264 4:2:2 垂直色度去块边滤 16 行、每个 bS 管 4 行**：`h264_h_loop_filter_chroma422`
  传 `inner_iters=4`（普通版为 2），intra 变体 `4*inner_iters=16` 行；水平色度边仍
  8 列、bS 各管 2 列。另外 422 水平奇数边在 8x8DCT 宏块里**亮度跳过滤、色度仍滤**
  （`!deblock_edge && (!chroma422 || dir == 0)` 才 continue）。
- **H.264 4:2:2 的 pred8x16_left_dc 是四象限**：两个 `pred8x8_left_dc` 纵向堆叠，
  每 4 行用自己的左列均值 `(dc+2)>>2`；写成 8 行平均 `(dc+8rows+4)>>3` 会让 MB 边
  缘象限恒差 ±4。pred8x16_plane 的垂直梯度 `V=(5V+32)>>6`、求和到 k=8 且左列 y=15
  与 topleft 相接。
- **H.264 4:4:4 CABAC 的三个陷阱**：① cat 5（luma 8x8）在 444 **也读 coded block
  flag**（`(cat != 5 || CHROMA444)`），cbf=0 时要清**整个 2x2 象限**的 nz
  （420 里 cat5 从不读 cbf，这条路径从未执行过）；② 8x8DCT/4x4 邻接 quirk 对
  **三个平面**都生效（当前宏块是 8x8DCT 而左/上邻是 4x4 变换时，该邻居的边界
  nz 按 0 参与（I_PCM 邻居为 64）），不能限定 luma 平面；③ 444 的 nz 象限索引要
  用 `n & 15`（平面内相对索引），用全局 n/4 会写越界。
- **对照 harness 要先在已验证路径上校准**：本轮用 C 表复刻 decode_residual 的
  harness 连续暴露四个自身 bug（total_zeros 数组差一、run 循环起点、escape 分界、
  缓冲未初始化），一度把正确的 MoonBit 实现改错又回退。正确顺序是先让 harness
  在 420（已 byte-exact）的调用序列上复现已知结果，再拿它质疑 422。
- **README 是 CRLF**：脚本做多行替换时把 `
` 换成 `
` 再匹配，否则静默失配。
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

- **VP9 inter 对拍插桩用 IMD 行**：在 C `ff_vp9_decode_block`（decode_mode 之后）
  与 MoonBit `decode_block` 对应位置打印 `bs/col/row/comp/ref/mode[4]/uvmode/
  filter/tx/uvtx/skip/mv[4]`，加上块入口 BLK 行（带 cw/hi/bits）与 EOB 的 STEP
  行即可覆盖 inter 全路径；C 的 `VP9mv` 是 int16 结构体，printf 时必须取
  `.x/.y` 字段，整 struct 传 %d 会打印打包后的 32 位值造成假分歧。
- **VP9 工作概率表与上下文表的槽步长不同**：`prob_coef` 每槽 **11** 个值
  （3 真概率 + 8 pareto 尾），`prob_ctx_coef` 每槽 **3** 个；parallelmode 的
  commit 从工作表拷回上下文表时源偏移必须按 11 算（曾按 3 算导致帧 1 起概率
  全错、帧间像素大面积 ±1~2 偏差，对拍首个 STEP 的 `tp0` 即定位）。
- **VP9 帧级 filter 字段与 switchable 树码顺序不同**：帧头 `interp_filter`
  原码为 **0=smooth,1=regular,2=sharp,3=bilinear**（C 直接当 FilterMode 枚举
  用），而 switchable 树码为 0=regular、1=smooth（C 经 `ff_vp9_filter_lut`
  转换）；两个顺序恰在前两项互换，non-switchable 帧直接透传原码会选错 tap。
- **VP9 adapt_prob 的负向舍入必须用算术右移**：C 的
  `p1 + (((p2 - p1) * uf + 128) >> 8)` 对负调整量向负无穷取整（-96>>8=-1），
  用 `/ 256`（向零截断，-96/256=0）会让自适应概率逐帧 +1 漂移；帧 1 起首个
  分歧 NZ 行的 pareto 尾概率差 1 即此因。触发条件：`-frame-parallel 0` 编码
  （默认 auto 时 libvpx 常开并行模式，只走 commit 路径测不出）。
- **VP9 av_clip_intp2 通带是 [-2^p, 2^p-1]**（p = BIT_DEPTH-1）：上界在 2^p-1，
  负号在移位**外**（`-((8192+sum)>>14)`）；iadst 类负号位置与括号结合极易抄错，
  用「C 模板编 ktest.c 真值 + MBT 同 LCG 序列 A/B」逐核抓（vp9_kernels_wbtest.mbt
  已固化为常驻校验和）。**String::to_bytes() 是 UTF-16LE**，喂 av_md5_sum 前要逐
  code unit 取低字节转 ASCII。
- **VP9 向量 b64 内嵌用单行 `b"..."`**：多行续行需要每段都带 `b` 前缀，
  否则续段是 String 字面量触发 deprecated overload 警告（交付要求 0 警告）。

- **Opus SILK 对拍必须用 asm 禁用的 FFmpeg 构建**：x86 的 swr 重采样内核
  （resample_common_float_fma3）与 float_dsp 用 FMA，位模式与标量 C 不同；
  vpxdev-img 里 `./configure --disable-asm --disable-everything
  --enable-decoder=opus --enable-demuxer=ogg --enable-muxer=framemd5
  --enable-encoder=pcm_f32le --enable-filter=aresample,aformat,anull
  --enable-protocol=file` 构建参考解码器，`-c:a pcm_f32le -f framemd5` 给出
  逐帧 f32 位模式 MD5（CLI 已扣 pre-skip、按 Ogg granule 末端裁剪、末帧为
  drain）。CELT 合成本身沿用 opus_celt_pcm_reference.c 的 3e-6 容差。
- **Opus SILK 的三个 C 怪癖必须复刻**：①`silk_lsf2lpc` 的 maxabs 扫描读的是
  `lpc32[k]`（上一个 argmax 槽位）而不是 `lpc32[j]`——maxabs 实际只跟踪
  |lpc32[0]|，照「正常」写法会在应扩展时不扩展；②Q12 系数赋值有 int16 截断
  （wrap），病态 NLSF 下依赖回绕行为；③`ff_silk_decode_superframe` 对单声道
  读未初始化的 `redundancy[1]`（移植按 0 处理，值不可观测）。
- **Opus 包级编排的 cur_out 时序**：`opus_decode_frame` 内 cur_out 在整帧
  （SILK 重采样 + CELT 叠加 + redundancy 淡化）完成后才由调用方按 samples
  推进；SILK 分支提前推进会与 hybrid 的 CELT 叠加重叠越界（症状：hybrid 首
  包即 OOB）。hybrid 的 CELT 叠加基点是帧首（out_tmp = cur_pos + delay）。
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
- **CELT 合成的 half-IMDCT 约定**：N 个输入系数返回 N 个半逆样本，AVTX scale 为
  -1/32768；transient 输入按 block 交错，输出按 block 连续。写入 buf+1024+60，
  再用原 C 的 120 项窗 overlap/add。后滤波必须先跑 old→current 的首 120 点过渡，
  再提交 current←new；长帧继续跑第二次过渡和稳态区。最后 memmove 1084 个 Float，
  去加重从新 buf[1024-frame_size] 读。不能在静音帧直接清空重叠或滤波历史。
  transition 中 C 的 `(1.0-w)` 使累加链提升到 Double，另三项先算 Float；移植需保留。
  `opus_celt_pcm_reference.c` 使用原始 AVTX/DSP 的完整解码入口生成期望值。
- **H.264 CAVLC 8×8 的两种 nz 语义**：四路 residual 列表各有 4×4 熵计数，
  解析完一个 8×8 后把总和加到 leader；去块则把 leader 的存在标志展开到整个 8×8。
  不能覆盖原熵计数，否则后续 CAVLC nC 上下文变化。P_8x8ref0 不读取 ref_idx。
- **H.264 slice 边界不只限制 MV**：CABAC mvd 邻居也必须在同 slice，否则会造成
  后续 bin 分歧和 end_of_slice_flag 丢失。重建共享未滤波平面，语法/预测缓存独立；
  deblock 按 MB 保存参数与真实参考图身份，idc=2 只跳过跨片边。I_PCM 须设置 mb_type，
  否则完整性检查误判缺块。CABAC PCM 退回 lookahead 后读样本，再重启 coder；两个
  PCM 之间还有 end_of_slice_flag=0，不能漏编码。
- **H.264 POC/MMCO 操作数**：POC delta_bottom 的存在条件是 PPS 的 pic_order_present
  且非 field_pic，不能取 bottom_field_flag。MMCO6 只有 long_term_frame_idx，
  MMCO3 才同时有短图差与长索引。MMCO5 后 prev_poc_lsb 应取归一化后的 top POC，
  需先加回 poc_msb，不能直接用旧 lsb 减整帧 POC。P 默认 L0 按 FrameNumWrap 排序。
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
├── wasm_probe/               # wasm 体积探针（scripts/generate_wasm_size_probe.py 生成，勿手改）
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
│   ├── probe.mbt             # 统一格式探测（format.c: probe3/format2/buffer2）
│   ├── probe_container.mbt   # 容器 read_probe（mov/matroska/mpegts/wav/w64/hls/dash）
│   ├── probe_elementary.mbt  # 裸流/图片 read_probe（aac/ac3/flac/mp3/ogg/png/mjpeg…）
│   ├── probe_vectors/        # 探测夹具（base64）+ 黑盒测试（12 项）
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
    ├── h264_slice.mbt        # I/P/B/SP/SI header、L0/L1 显式权重
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
