# AV1 解码移植交接文档（2026-10-24）

接手者请通读本文档再动手。项目背景见 [README.md](README.md)、
[PORTING_HISTORY.md](PORTING_HISTORY.md) 与 [agent.md](agent.md)；
本文只覆盖 **AV1 像素解码** 这一条正在进行的切片。

> **2026-10-26 帧间交接请先读
> [AGENT_HANDOFF_2026-10-26_INTER.md](AGENT_HANDOFF_2026-10-26_INTER.md)**
> （§67–§81 已推送：refmvs 的 find/初始化/行环/load/save/参考槽位，
> 状态机、MV 之后的帧间语法与 warp 仿射推导均已用 dav1d C 随机对拍，
> 宽度按 superres 上采样网格，934/934；仍需接入 decode_b inter 与
> 整帧入口）。以下为 2026-10-25 的快照：

> **2026-10-25 最新进展请先读
> [AGENT_HANDOFF_2026-10-25_SEG.md](AGENT_HANDOFF_2026-10-25_SEG.md)**：
> 多 tile 有损 LF（§59）、delta-lf（§60）、LR 全格式（§61）及关键帧
> segmentation + SWITCHABLE LR（§62）已收敛；rav1e 4:4:4 10-bit 的
> 4 帧 MD5 与 libdav1d 一致，全量测试 873/873。环路恢复与高位深有损见
> [AGENT_HANDOFF_2026-10-25_AV1_LR.md](AGENT_HANDOFF_2026-10-25_AV1_LR.md)。
> 帧间帧的非缩放单参考 MC 核已在 §63 落地，14 组 C 参考像素通过，
> 该阶段全量测试 874/874；帧间块语法与整帧入口尚未接入。
> §64 已补齐复合预测的 `prep` 中间样本和等权/距离加权平均；
> 并修正 §63 的实际向量数（原提交 10 组，现已补至 14 组）。
> §65 新增 mask 混合及 4:4:4/4:2:2/4:2:0 差值 mask；
> §66 新增 OBMC 水平/垂直重叠混合（`4fe3c70`）；
> §67 新增 wedge 复合预测掩码与 inter-intra 掩码表（wedge.c 完整
> 移植，含 wedge blend 向量）；§68 新增缩放参考 MC 与 superres
> resize；§69 新增 warp 仿射 8x8 MC；最新全量测试 885/885。
> `av1_mc_core` 的 MC 核（单参考/复合/mask/wedge/OBMC/缩放/warp）
> 至此全部就绪；§70 补齐帧间帧头（GM/skip_mode/短信令/
> frame_size_with_refs + 8-slot 参考状态 Av1RefSlotState）。
> §71 新增 NEWMV 残差解码原语（4×400 步位级对拍）；
> §72 新增 refmvs 候选查找（1008 例 C 对拍，空间/时域/gmv/ctx）；
> §73 新增 refmvs 帧初始化（sign/mfmv 选择，20 组对拍）。
> 剩余 load/save_tmvs 接线、帧间块语法主体与整帧入口。
> 本文 §2/§3 中「仍错的像素模式」等段落是无损收敛期的历史记录，已全部解决。

---

## 1. 任务与总体策略

用户清单里 AV1 此前只有 OBU/序列头/帧头/tile 提取（`av1.mbt` +
`av1_tiles.mbt`），缺像素解码。FFmpeg 9.0.2 的 `av1dec.c` 本身**没有**
软件像素解码（只做 OBU 解析，像素交给 libdav1d/硬件），因此像素层的
移植参照是 **dav1d 1.5.1**（FFmpeg 官方集成的 AV1 参考解码器，
BSD-2-Clause）。

源码已克隆在 `C:\Users\milkb\AppData\Local\Temp\dav1d-src`（含
`.git`；若被清理，重新 `git clone --depth 1 --branch 1.5.1
https://code.videolan.org/videolan/dav1d.git`）。

验收标准与项目其它解码器一致：**docker `linuxserver/ffmpeg:9.0.2`
（libdav1d）的 framemd5 作为期望值**，MoonBit 逐帧 MD5 对拍。

首个收敛目标是**无损关键帧**（`-crf 0` 的 libaom 流）：无损时
CodedLossless=1，环内滤波（LF/CDEF/LR）全部旁路，只需
熵解码+预测+反变换，是把管线调通的最好切入。

## 2. 已完成（全部已落盘、`moon check` 0 警告）

| 文件 | 内容 | 验证状态 |
|---|---|---|
| `libavcodec/av1.mbt`（修改） | 帧头解析缺陷修正：superres/render 位序（superres 在 render **之前**、render 取降采样后宽）；LF/CDEF/LR/tx_mode 的 CodedLossless/intrabc 门控；tx_mode=ONLY_4X4(0)；lr_params；delta_q/delta_lf/dq/dv 字段捕获；seq 头 `enable_filter_intra`/`enable_intra_edge_filter` | 既有 791 测试不受影响 |
| `libavcodec/av1_msac.mbt` | dav1d msac.c 全量：refill/norm/bool_equi/bool/symbol_adapt（含 CDF 自适应）/bool_adapt/bools/uniform/subexp/hi_tok/golomb | **3000 步 bool_equi 与 C 逐步位级一致**（见 §5 探针） |
| `libavcodec/av1_cdf_tables.mbt` | dav1d cdf.c 全部默认 CDF（121 个数组，16872 u16） | 由 `scripts/extract_av1_cdf_tables.py` 提取，并与 **C 编译 dump 零差异**（见 §4） |
| `libavcodec/av1_tables.mbt` | dav1d tables.c/scan.c/dequant_tables 的解码表（58 个：block_sizes/dimensions、txfm_dimensions、max_txfm_size、tx_type_class、skip_ctx、lo_ctx_offsets、scans、lnz、dq_tbl、sm_weights、dr_intra_derivative、filter_intra_taps、al_part_ctx、partition_type_count 等） | 同上，C dump 零差异；`scripts/extract_av1_decode_tables.py` |
| `libavcodec/av1_cdf.mbt` | 每帧 CDF 工作副本 `Av1CdfCtx` + `av1_cdf_copy_defaults(qidx)`（qcat 规则与 dav1d 一致） | 编译绿 |
| `libavcodec/av1_itx.mbt` + `av1_itx64.mbt` | itx_1d.c 全部 1D 核（dct4/8/16/32/64、adst4/8/16+flip、identity、wht4）+ 通用 `inv_txfm_add` + `itxfm_add` 分发（shift 表）+ tx1d_types + scan/lnz 访问器 | WHT 已用 python 重算 dav1d C 数学对拍通过（74 填充 ±3 残差与解码输出一致）；其余核尚未单测 |
| `libavcodec/av1_ipred.mbt` | ipred_tmpl.c + ipred_prepare_tmpl.c：DC 家族、V/H、Paeth、Smooth×3、Z1/Z2/Z3（含 edge filter/upsample）、FILTER_PRED、CFL AC/pred、pal_pred、`av1_prepare_intra_edges`、`av1_ipred_predict` 分发 | 部分经像素对拍间接验证 |
| `libavcodec/av1_decode.mbt`~`av1_decode6.mbt` | decode.c+recon_tmpl.c 关键帧路径：BlockContext、FrameCtx/TileCtx、edge 树（intra_edge.c）、partition 递归（10 种）、decode_b（skip/ymode/angle/uv/CFL/palette/filter-intra/tx）、decode_coefs（eob/tokens/golomb/sign/dequant）、recon_b_intra（预测+itx 逐子块）、backup_ipred_edge、tile sbrow 循环、入口 `av1_decode_keyframe` | **无损与有损关键帧均与 libdav1d 逐帧 MD5 一致** |
| `libavcodec/av1_lf.mbt` | 环路去块滤波：lf_mask.c intra 掩码/level cache/calc_eih/calc_lf_values、loopfilter_tmpl.c 四个 C 核、lf_apply_tmpl.c 列/行驱动（单 tile） | 8-bit 4:2:0 有损向量 8/8 帧 MD5 一致 |
| `libavcodec/av1_cdef.mbt` | CDEF：方向搜索（八方向代价/方差）、主次抽头约束滤波、cdef_idx/noskip 掩码、全帧快照调度 | 开启 CDEF 的 crf30 向量 8/8 帧 MD5 一致 |
| `libavcodec/av1_lr.mbt` | 环路恢复语法层：帧头 unit_size、逐 unit 的 switchable/wiener/sgrproj 符号与 lr_ref、SGR 表 | 符号轨迹与 dav1d 一致 |
| `libavcodec/av1_lr_filter.mbt` | LR 滤波核：Wiener h/v/hv（滑窗）、SGR 3x3/5x5/mix | 1980 组 C 参考哈希全绿 |
| `libavcodec/av1_lr_apply.mbt` | LR 应用：逐 SB 行 stripe 调度（8 行滞后）、`backup4xU` 左边界、`backup_lpf` 12 行备份 | 整帧 framemd5 一致 |
| `libavcodec/lr_kernel/` | LR 核级回归（dav1d C 参考 1980 例 FNV 哈希） | 全绿 |
| `libavcodec/av1_lossy_lr/` | 整帧 LR 回归：wt1(Wiener) / t5(SGR) / lr10 / lr10nc / lr12 | 全绿 |
| `libavcodec/lf_kernel/` | 去块滤波核 800 组随机输入与 dav1d `loop_filter` 校验和回归 | 全绿 |
| `libavcodec/itx_probe/` | 155 个 (RectTxfmSize, TxfmType) 逆变换组合与 dav1d DSP 校验和回归 | 全绿 |
| `libavcodec/av1_lossy_vectors/` | 8 帧 8-bit 4:2:0 有损关键帧（crf30，CDEF/LR 关闭）framemd5 回归 | 全绿 |
| `libavcodec/av1_lossy_extra/` | 4:4:4 / 4:2:2 8-bit 与 10-bit 4:2:0 有损关键帧（各 4 帧）framemd5 回归 | 全绿 |
| `libavcodec/av1_kf_realdata_wbtest.mbt` | 两条无损向量（ll128 单帧 128×96、ll160 六帧 160×120，base64 内嵌）+ framemd5 期望 + 全链测试 | 结构就绪，MD5 待收敛 |
| `scripts/_gen_av1_kf_vectors.py` + `_av1_kf_test_body.tpl` | 向量生成脚本（模板文件分离） | 可重跑 |
| `scripts/extract_av1_cdf_tables.py`、`extract_av1_decode_tables.py` | CDF/解码表提取器（支持 `--check`；后者需要 §4 的 dump 文件） | C 对拍 0 差异 |

调试用的临时文件（**收敛后必须删除**）：
- `libavcodec/av1_probe_wbtest.mbt` — 像素/位流探针测试
- 解码器内的 `println` 调试输出（av1_decode2/3/4/5/6.mbt 里所有
  `println("B "/"PART"/"CF "/"PP "/"Z1"...` 等）——见 §6 清理清单

## 3. 无损关键帧（已收敛）

无损关键帧的符号与像素均已与 dav1d 1.5.1 一致（ll128/ll160、10/12-bit、
4:4:4/4:2:2/单色）。历史排查记录见 §3.4 与 PORTING_HISTORY §49。

有损关键帧（2026-10-25，PORTING_HISTORY §52/§53）也已收敛：8 帧符号
轨迹与 dav1d 完全一致，未滤波重建逐字节一致，带 LF 与 CDEF 的 framemd5
均与 FFmpeg 9.0.2（libdav1d）完全一致。已修复的 bug：
`cfl_allowed_mask` 位集、非 2D DC hi-token 上下文、palette 索引与 tx_size
的符号顺序、逆变换 1D 类型表的行列转置、ADST16/DCT64 核转录错误、
chroma LF 掩码 sidx 移位与行滤波 level 偏移。

有损格式覆盖（2026-10-25，PORTING_HISTORY §56）：4:4:4、4:2:2 与
10-bit 4:2:0 关键帧的 framemd5 也已与 libdav1d 一致。这里踩过的坑：
`decode_b` 的色度变换尺寸必须按 `dav1d_max_txfm_size_for_bs`
的**像素布局列**（y / 420 / 422 / 444）取值，曾固定用 4:2:0 列，
4:4:4 有损时色度 tx 取小导致 `decode_coefs` 熵解码分叉、连 luma 也错；
无损因强制 4x4 tx 掩盖了该 bug。

**语法层（熵解码）已与真 dav1d 逐步对拍确认一致**的部分：
- 3000 步 `decode_bool_equi` 位级一致（rng/difhi/cnt/pos 全同）
- 逐符号对拍到第 3 块（partition/skip/ymode/uvmode/CFL/palette
  值/palette bits/eob/tokens/dc/sign 链），见 §5 的 trace 工具
- 首块 (0,0) 像素**完全正确**（Y4[0..7]=74 74 30 30 30 30 30 30 与参考逐字节一致，palette 路径正确）

**仍错的像素模式**（`Y0/Y4/U0` 对参考，scratch 里有参考 yuv）：
- 参考帧 `ll128_ref.yuv`（18432 = 128×96×1.5）：Y0=
  74×8,81×14,145×10；Y4=74,74,30×6,44,44,47,47,32×10,48×10；U0=
  221×4,90×7,54×5
- 我方 Y4 前 8 像素正确，之后 x=8..11 给 0 0 0 0（应为 44 44 47 47），
  x=12+ 给 29/30（应 32/48，±2-3 小偏差）；U0 前 4 差 ±1-3，后半错块
- Y0 x=16..19 给 75 76 75 75（应 81），x=20/21 给 255/0（截断，应 81）

### 3.1 已排除

- msac 算术核（位级 3000 步一致）
- CDF 表内容（与 C 编译 dump 零差异）
- WHT 反变换（python 重算 C 数学对拍一致；74±3 残差模式与我方输出吻合，
  说明错在**预测值**而非残差）
- 首块 palette 值+索引+pal_pred（像素逐字节对）
- 帧头解析（tiles=2313 与 tile 边界对齐，语法能全帧跑完）

### 3.2 主要怀疑点（按优先级）

1. **非 palette 块的预测（edge 准备/Z 角度/edge filter）**。x=8..11 全 0
   说明某 4×4 块预测值严重为负被截断——重点查 `av1_prepare_intra_edges`
   的 left/top 填充与 `av1_ipred_z1/z2/z3` 的 base 索引、upsample 路径。
   注意 Z2/Z3 我把 C 的双指针 in/out 改成了两个数组（`filter_edge`/
   `upsample_edge` 已分离 in_buf/out_buf），检查各调用点参数序。
2. **block (2,0) 的 palette 未生效**：该块 ypal=1、palette={85,175,255×…}
   （与 C 仲裁器一致），但 Y0[8..16] 输出 74（来自左侧块的值）——
   好像 recon 走了普通预测而非 pal_pred。检查 `recon_b_intra` 里
   `b.pal_sz.0 != 0` 分支是否真的命中该块（可能与 pal_idx 缓冲复用、
   或 `decode_b` 里 pal_sz 元组赋值时序有关）。
3. **CFL 色度**：U0 后半块 147 vs 90/54，块级偏移；查 `av1_cfl_ac` 的
   w_pad/h_pad 与 `cfl_pred` 的 alpha 应用。
4. `backup_ipred_edge`/`ipred_edge` 跨 SB 行边界（首行内就错，优先级低）。

### 3.3 对拍方法论（项目沉淀，务必沿用）

1. **符号级 trace 对拍**：MoonBit 与参照解同一流，每步打印
   `标签 值 rng difhi cnt pos`，归一化后逐行 diff 找首个分叉。
   工具已就绪：
   - `python .scratch/av1/trace2.py .scratch/av1/ll128.ivf`（python 参照，
     自带 msac+CDF；注意它历史上出过 bug，见下）
   - `.scratch/av1/norm_diff.py mb_full.txt py_full.txt`（轨迹归一化 diff）
   - MoonBit 侧 trace 靠解码器里现成的 println（运行
     `moon test libavcodec/av1_kf_realdata_wbtest.mbt` 收集）
2. **C 仲裁器**（最权威）：`C:\Users\milkb\AppData\Local\Temp\trace_arb.c`
   用 `#include "src/msac.c"` 等直接吃 dav1d 真源码，gcc 编译即得
   权威符号序列。**一个全帧版已写好但尚未编译验证**（旧版只解前几
   个符号、已验证可用；新版把 decode_b/palette/coeffs 扩到全帧，
   其中 read_pal_plane 的 cache 合并段是新写的、需要对照
   recon_tmpl.c 的 dav1d_read_pal_plane 校对一遍再信）。
   构建方法见 §4。
3. **像素对拍**：`.scratch/av1/ll128_ref.yuv` 是参考帧；用
   `av1_probe_wbtest.mbt` 打印我方行像素直接比。

### 3.4 python 参照（trace2.py）的已知历史 bug

这些都已修，但如果重写/回退要小心（当时每修一个，对拍结果就前进一步）：

- CFL_MASK 位集抄错（必须含 BS_8x8=17，完整集是
  7,8,9,11,12,13,14,15,16,17,18,19,20,21）
- `norm()` 的 `d` 公式：C 是 `15 ^ (31 ^ clz(rng))`（异或），不是 `31-clz`
  （对 rng<2^16 恰好等价，但别再改错）
- refill 条件：C 的 `(unsigned)cnt < (unsigned)d` 意味着 **cnt<0 时不
  refill**（负数变巨大无符号）；python 初版写成了 `cnt < d`
- eob_bin CDF 行基址是 `[chroma][is_1d]` 两维：`(chroma*2+is_1d)*8`
- palette 后 filter-intra 的前提是 `!pal_sz[0]`
- uv palette 的 pal_ctx = (pal_sz[0] > 0)
- 块级系数要按 4×4 子块循环（8x8 块 lossless 是 4 个亮度子块）
- 块后要更新 a/l 的 pal_sz 上下文

MoonBit 侧同样修过的真 bug（引以为戒）：
- `read_pal_plane` bits 更新用了 ctz，应为 **ulog2**（180 的 ctz=2 会把
  bits 砍到 3，解码出 79 而非 146）
- `decode_coefs` i 循环 `rc_i` 对 TX_CLASS_2D 应为 `scan[i]` 而非 `i`
  （rc 链起点错导致符号链 5→10→12… 而非 8→7→13…）
- `av1_mode_conv` 表必须 13 行（DC..PAETH 每模式 4 项），只放 2 行时
  PAETH(12) 索引越界
- intra edge 树的 tip 层级判断（BL_16X16=3，不是 2）写错过一次
- ipred 的实现模式常量是 dav1d 特殊布局：LEFT_DC=3, TOP_DC=4, DC_128=5,
  Z1=6, Z2=7, Z3=8（复用方向模式的枚举槽位），别按直觉写 5..11
- above 上下文（f.a）**每帧开始**要按关键帧默认值 reset（intra=1、
  mode=DC、lcoef/ccoef=0x40、tx_intra=-1、tx=4）；漏掉会让色度
  skip ctx 从第一块就错
- `Ref(angle)` 要先建变量再传，每次 `Ref(angle)` 新建副本会丢掉
  prepare_intra_edges 里的角度映射结果

## 4. 基础设施：C dump / C 编译（docker）

表/CDF 的"真值 dump"流程（提取器靠它与 C 零差异）：

1. dump 源码在 `C:\Users\milkb\AppData\Local\Temp\`：
   `dump_cdf_fields.c`（CDF 按字段）、`dump_av1_tables.c`（解码表）、
   `trace_arb.c`（符号仲裁器）
2. 打 tar（源码树 + config.h + dump 程序）→ `docker run --rm -i
   ubuntu:24.04 bash -c "…gcc…"` 管道 stdin 传 tar，stdout 回传结果 tar。
   **必须先 `cat > in.tar` 再跑 apt**（apt 会吃 stdin；曾因此反复失败）。
   成品脚本：`.scratch/av1/dump_cycle.py`（表 dump+重生成）、
   `.scratch/av1/run_arb.py`（仲裁器）
3. dump 结果：`C:\Users\milkb\AppData\Local\Temp\cdf_fields.txt`、
   `...\av1t\av1_tables.txt`

注意 `dump_av1_tables.c` 的 scan/lnz 长度公式是
`(min(w,8) * min(h,8)) * 16`（64px 方向截到 32 的表），曾写成 `w*h` /
`w*h*16` 出过错。

docker 里 **apt 网络当前不稳**（universe 连不上，pip 装不了），所以
"meson 构建 dav1d-dbg"（`build_dav1d_dbg.py`）一直失败——别再走那条
路；gcc 直编可用，仲裁器方案就是为此准备的。

## 5. 现成调试入口

```sh
cd D:\project\FFmpeg-n9.0.2\moonbit
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render                              # 全量 864
moon test --target wasm --no-render -p libavcodec/itx_probe      # 逆变换回归
moon test --target wasm --no-render -p libavcodec/av1_lossy_vectors
```

有损对拍的权威参照由 `.scratch/dav1d_dbg/build_trace.sh` 构建：直接
gcc 编译 dav1d 源码（不用 meson），打开 `DEBUG_BLOCK_INFO` 与
`decode_coefs` 的 `dbg`，并可选择 `inloop_filters=0` 导出未滤波 YUV。
`build_itx_ref.sh` 导出 `inv_txfm_add`/1D 核校验和。

素材在 `.scratch/av1/`：`ll128.ivf`（单帧）、`ll160_multi.ivf`（六帧）、
`ll128_ref.yuv`/`ll160_multi.framemd5`（期望）、探针/补丁脚本若干
（`patch*.py`、`add_*_trace.py` 都是历史调试补丁，可留作参考）。

生成新向量（docker 正常时）：
```sh
docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -f lavfi \
  -i "testsrc2=size=160x120:rate=10" -frames:v 6 -pix_fmt yuv420p \
  -c:v libaom-av1 -crf 0 -deadline good -cpu-used 8 -g 1 -f ivf pipe:1 > x.ivf
docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -c:v libdav1d \
  -i pipe:0 -f framemd5 -pix_fmt yuv420p pipe:1 < x.ivf > x.framemd5
python scripts/_gen_av1_kf_vectors.py    # 重 emit 测试文件
```

## 6. 收敛后的清理清单

1. 删 `libavcodec/av1_probe_wbtest.mbt`
2. 删解码器里所有调试 println（av1_decode2/3/4/5/6.mbt 搜
   `println`，保留的应该只有 0 个；av1_ipred.mbt 里的 Z1/Z2 打印、
   av1_decode.mbt 的 init_quant 里 `ignore(av1_ymode_size_context[0])`
   这类"消费未用表"的 hack 改成真用或删行）
3. `.scratch/av1/` 的调试脚本不需要提交（惯例是 `_*` 前缀/scratch
   不进库；`scripts/_gen_av1_kf_vectors.py` 按惯例可提交，`_` 前缀
   表示生成器）
4. `moon info`（不要跑 `moon fmt`），review `pkg.generated.mbti` 但不提交
5. `moon check --deny-warn` + 全量 `moon test` 绿后：
   - ll128/ll160 全帧 MD5 断言进 `av1_kf_realdata_wbtest.mbt`
   - 更新 README 表格（AV1 行）与 PORTING_HISTORY.md 新章节
     （记录：参照=dav1d 1.5.1 及其许可证说明、对拍方法、
     踩过的坑——可直接引用 §3.4）
6. 每个增量中文 commit 并 `git push origin master`（用户约定：自主推进，
   不需要逐次询问；提交信息风格看 git log，如
   `feat: 支持 AV1 无损关键帧解码`）

## 7. 路线（按优先级）

1. **有损覆盖扩展**：LR 已收敛且覆盖 4:2:0/4:2:2/4:4:4 × 8/10/12-bit
   （PORTING_HISTORY §57/§61，`av1_lossy_lr` + `av1_lossy_lr_fmt`）。
   rav1e 4:4:4 10-bit 的 `lr_type=SWITCHABLE` + segmentation 向量已通过
   （PORTING_HISTORY §62，`av1_seg_vectors`）。
2. **高位深有损**：10/12-bit 4:2:0 与 10/12-bit 4:4:4、10-bit 4:2:2 均有
   整帧向量并通过（`av1_lossy_extra`、`av1_lossy_lr`）。
3. **多 tile / 128x128 SB**：已收敛（PORTING_HISTORY §59）——LF 的
   tile 列/行边界强度修正已移植，`mt8`（64SB）、`mt444`（444 10-bit）、
   `mtsb128`（128SB）三条 2x2 tile 向量通过；128x128 SB 有损链路首次
   被整帧验证（向量由 debian aom-tools `aomenc --sb-size=128` 生成，
   libaom DYNAMIC 恒选 64）。
4. **delta_lf**：已收敛（PORTING_HISTORY §60）——单模式（`multi=false`）
   向量两条通过；`multi=true` 的码流 libaom（硬编码单模式）、SVT
   （不发 delta_lf）、rav1e 均产不出，同 VP9 复合预测的情况留待手搓。
5. **inter 帧**：非缩放单参考 8-tap/bilinear MC、复合预测
   `prep`/等权/距离加权/mask 合成及 OBMC 混合已实现（§63–§66，`av1_mc_core`）；
   接下来需要 refmvs、帧间块语法、参考帧生命周期、wedge、
   缩放/warp MC 与整帧对拍。
6. intrabc、film grain 明确报 PATCHWELCOME（入口已有检查）。

## 8. 相关约定速查

- 删除文件用 `zcode-trash`，绝不用 rm（PreToolUse 钩子会拦）
- Git Bash 下 docker 卷挂载路径会坏，走 stdin/stdout 管道
- heredoc 在此环境不稳（rm-guard 拦截 + 截断），复杂补丁一律写
  `.py` 文件再执行；写 MoonBit 大文件用 Write 工具别用 bash 拼接
- MoonBit 坑：`let x : T` 后接赋值不合法（用元组/表达式或 `let mut`）；
  `in` 是关键字；`~` 不存在（用 `-1 - x` 或 `.lnot()`）；`FixedArray`
  下标越界直接 trap；`pub` 字段默认公有（struct 字段别写 pub）；
  Byte 字面量 `b'\x00'`；类型转换 `to_int()/reinterpret_as_int()` 等
  按需选对（Int↔UInt 必须 reinterpret）
- 参考解码器对拍时两侧同名字段含义可能有别名（如 dav1d 的实现模式
  枚举 vs 语法元素枚举），先对表再对拍
