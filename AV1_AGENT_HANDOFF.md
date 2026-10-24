# AV1 解码移植交接文档（2026-10-24）

接手者请通读本文档再动手。项目背景见 [README.md](README.md)、
[PORTING_HISTORY.md](PORTING_HISTORY.md) 与 [agent.md](agent.md)；
本文只覆盖 **AV1 像素解码** 这一条正在进行的切片。

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
| `libavcodec/av1_decode.mbt`~`av1_decode6.mbt` | decode.c+recon_tmpl.c 关键帧路径：BlockContext、FrameCtx/TileCtx、edge 树（intra_edge.c）、partition 递归（10 种）、decode_b（skip/ymode/angle/uv/CFL/palette/filter-intra/tx）、decode_coefs（eob/tokens/golomb/sign/dequant）、recon_b_intra（预测+itx 逐子块）、backup_ipred_edge、tile sbrow 循环、入口 `av1_decode_keyframe` | **全帧解码已跑通**（6 行 SB 无 overread），MD5 尚未对齐（见 §3） |
| `libavcodec/av1_kf_realdata_wbtest.mbt` | 两条无损向量（ll128 单帧 128×96、ll160 六帧 160×120，base64 内嵌）+ framemd5 期望 + 全链测试 | 结构就绪，MD5 待收敛 |
| `scripts/_gen_av1_kf_vectors.py` + `_av1_kf_test_body.tpl` | 向量生成脚本（模板文件分离） | 可重跑 |
| `scripts/extract_av1_cdf_tables.py`、`extract_av1_decode_tables.py` | CDF/解码表提取器（支持 `--check`；后者需要 §4 的 dump 文件） | C 对拍 0 差异 |

调试用的临时文件（**收敛后必须删除**）：
- `libavcodec/av1_probe_wbtest.mbt` — 像素/位流探针测试
- 解码器内的 `println` 调试输出（av1_decode2/3/4/5/6.mbt 里所有
  `println("B "/"PART"/"CF "/"PP "/"Z1"...` 等）——见 §6 清理清单

## 3. 当前卡点：无损关键帧 MD5 未对齐

`ll128` 单帧：got `59c794743afb69e60ad1fddab53d7344`，want
`f9db7bbaf792b693d4c88d3039a68d75`。

2026-10-24 后续修复：`av1_prepare_intra_edges` 的 Z3 左下参考像素写入
位置已按 dav1d 调整；FILTER_PRED 补齐 p5 抽头并修正后续行的 top 来源；
palette 索引完成阶段按 dav1d 填充不可见的右/下边缘。以上改变了 MD5，
但尚未对齐参考值，仍需从首个熵解码/重建分叉继续排查。
后续还修复了 luma/chroma 子块的 top-right 可用性判断：dav1d 只在子块
触及当前块右边界时禁用该参考边缘，不能整行禁用。

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
moon check --target wasm --deny-warn --no-render     # 必须 0 警告
moon test --target wasm --no-render                  # 全量（收敛前 AV1 向量会挂）
moon test --target wasm --no-render libavcodec/av1_kf_realdata_wbtest.mbt   # AV1 向量
moon test --target wasm --no-render libavcodec/av1_probe_wbtest.mbt         # 像素探针
python .scratch/av1/trace2.py .scratch/av1/ll128.ivf > py_full.txt          # python 参照轨迹
python .scratch/av1/norm_diff.py mb_full.txt py_full.txt                    # 轨迹 diff
```

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
4. `moon fmt` + `moon info`，review `pkg.generated.mbti`
5. `moon check --deny-warn` + 全量 `moon test` 绿后：
   - ll128/ll160 全帧 MD5 断言进 `av1_kf_realdata_wbtest.mbt`
   - 更新 README 表格（AV1 行）与 PORTING_HISTORY.md 新章节
     （记录：参照=dav1d 1.5.1 及其许可证说明、对拍方法、
     踩过的坑——可直接引用 §3.4）
6. git commit（用户约定：不主动 commit，先问或等用户指示；
   提交信息风格看 git log，如 `feat: 支持 AV1 无损关键帧解码`）

## 7. 收敛后的路线（按优先级）

1. **有损关键帧**（2026-10-24 晚开工，见 PORTING_HISTORY §50）：解码层
   （tx_mode=2 逐块 tx size、txtp_intra1/2、eob_bin 全表、dequant/cf_max）
   已就位；`-enable-cdef 0 -enable-restoration 0` 的 crf30 向量 8 帧中
   6 帧可整帧解码、2 帧 overread——分歧点已用逐 tx 子块 msac cnt 插桩
   定位到帧尾 (18,23) 的 4x4 IDTX 块附近（levels 转置布局已修，见 §50，
   但该分歧另有原因）。**下一步**：①写全帧 C 仲裁器（在
   `C:/Users/milkb/AppData/Local/Temp/trace_arb.c` 基础上扩展，或扩展
   `.scratch/av1/trace2.py` 补 tx size/txtp/eob 大表符号）对拍找首个
   分歧符号；②移植 LF（`lf_mask.c`+`lf_apply_tmpl.c`+
   `loopfilter_tmpl.c`，帧头 LF 参数已解析但 delta 被 skip、CDEF 强度
   被 skip）；③CDEF/LR 后续。注意 ffmpeg `-skip_loop_filter` 对
   libdav1d 无效，未滤波参考不可得。
2. **多 tile / 128x128 SB / 4:2:2 / 4:4:4 / 高位深**：入口现在硬编码
   4:2:0、8bit、单 tile、64x64 SB（`seq.use_128x128_superblock` 支持
   读但 edge 树/上下文环按 64x64 布局）。
3. **inter 帧**：需要 refmvs/mc 全家（工程量大，参照 VP9 inter 的
   移植节奏）。
4. intrabc、film grain 明确报 PATCHWELCOME（入口已有检查）。

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
