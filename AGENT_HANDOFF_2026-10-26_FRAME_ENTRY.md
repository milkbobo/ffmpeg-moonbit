# AV1 帧间整帧入口交接报告（2026-10-26 晚，第三份）

> 最新接续见 [INTER_SESSION](AGENT_HANDOFF_2026-10-26_INTER_SESSION.md)
> 与 PORTING_HISTORY §96。inter 整帧与会话入口已接入，5 组真实流 MD5
> 收敛；本报告的上游接线说明仍供参考，待办以最新报告为准。
> §3 的 inter reset_context.intra 初值应为 0；已由真实多帧对拍修正。

> 接续状态见 [FRAME_STATE 报告](AGENT_HANDOFF_2026-10-26_FRAME_STATE.md)
> 与 PORTING_HISTORY §95：G1 的 set_block 坐标、G3 的块级分段语法和
> 特征继承、G4 的 CDF 深拷贝已有工作区实现；整帧入口仍待接入。
> 本文 §3.1 的 get_prev_frame_segid 应为「遍历可见块取最小值」，
> 并非首块一致性检查。以 dav1d decode.c:494–510 原文和新 C 对拍为准。

> 交接对象：下一个接手本仓库的 AI。本文取代
> [AGENT_HANDOFF_2026-10-26_INTER.md](AGENT_HANDOFF_2026-10-26_INTER.md)
> （其 §3.1 refmvs 接线、§3.2 decode_b 块语法**均已完成**，见
> PORTING_HISTORY §74–§94）。基线：提交 `509e30e`，工作树干净，
> `moon check --target wasm --deny-warn --no-render` 0 警告，
> Wasm 全量测试 **956/956**。
>
> **本报告包含一次完整的 dav1d 源码调研结论（§3），把整帧入口
> 需要的全部上游语义（decode_b 顺序/CDF 继承/槽位刷新/segmap/
> superres/单线程主循环）逐条钉死，并给出文件级行号。接手后
> 不需要重新读 decode.c/lib.c/obu.c 的这些部分。**

---

## 1. 任务与验收

用户清单中 AV1 是唯一未完成的解码器。块级（语法/MC/残差/重建）
已全部位级收敛；剩余唯一大战役 = **帧间整帧入口 + 端到端 MD5**：

1. `decode_b` 接入 inter 帧（intra 标志、inter 帧内 intra 块、
   inter 块驱动接线、上下文回写、LF 掩码、segmap、noskip）；
2. 会话级参考池（8 槽位：图像/CDF/segmap/refmvs rp/GM 状态）；
3. 帧级循环（sbrow × tile，refmvs load/save 钩子）+ 后处理
   （deblock/CDEF/LR/superres）；
4. docker `linuxserver/ffmpeg:9.0.2`（libdav1d）P/B 帧流 framemd5
   逐帧一致（关键帧已有先例：`av1_lossy_vectors` 等）。

明确不做（PATCHWELCOME）：film grain、intrabc、
grain-from-reference。SP/SI（H.264）、VP9 复合预测同理（历史定论）。

参照实现 dav1d 1.5.1 源码：`C:\Users\milkb\AppData\Local\Temp\dav1d-src`
（若被清理：`git clone --depth 1 --branch 1.5.1
https://code.videolan.org/videolan/dav1d.git`）。

## 2. 当前状态（全部已提交推送）

| 阶段 | 提交 | 内容 |
|---|---|---|
| §63–§79 | 见旧文档 | MC 核、帧头 §70、MV 残差 §71、refmvs find/init/状态机/load/save/splat/sbrow_init |
| §80–§84 | … | 块语法（复合/inter-intra/motion/filter/warp 推导/LF 掩码）+ 驱动，96 组 C 位级对拍 |
| §85–§89 | … | warp 平面预测、复合合成、块预测装配、OBMC、inter-intra、色度 sub8x8 |
| §90–§94 | `117c4f4`…`509e30e` | txtp 选择、var-tx 树、残差遍历、`av1_recon_b_inter` 重建装配、分段 inter 特征 + skip_mode 前置 + 邻域坐标修正 |

关键帧路径（§42–§62）全部收敛，改动它时先跑全量测试。

## 3. dav1d 整帧接线全图（本次调研钉死的语义）

### 3.1 decode_b 完整顺序（decode.c:683 起，单线程 pass 0）

```
1. seg_id（segmentation.enabled 时三分支）:
   a. !update_map          → seg_id 直接取 prev_segmap（无 cdf 读取，
      decode.c:818-828；prev_segmap 为空则 0）；seg = d[seg_id]
   b. update_map && preskip → temporal 时先读 seg_pred bool
      （cdf.seg_pred[a.seg_pred+bx4 + l.seg_pred+by4]），
      seg_pred=1 → temporal 取 prev_segmap；否则空间预测
      （get_cur_frame_segid + neg_deinterleave）      decode.c:829-867
   c. update_map && !preskip → skip 之后再读，同 b 但 skip=1 时
      seg_id=pred 且不读 cdf、不读 seg_pred            decode.c:896-940
   ※ 现有 MoonBit decode_b 只实现了空间分支；b/c 的 temporal
     seg_pred 分支与 a 的 !update_map 分支未实现。
2. skip_mode（seg 无 globalmv/ref==-1/!skip 特征 且
   skip_mode_enabled 且 min(bw4,bh4)>1）→ 已实现（§94）
3. skip → 已实现
4. cdef idx（!skip，cur_sb_cdef_idx==-1 时读 cdef_bits 个 bool）
   → 已实现（关键帧路径同款，inter 无差异）
5. delta-q/lf → 已实现（含 lflvl/dq SB 级刷新）
6. ★intra 标志（decode.c:1030-1049，inter 帧才有，读在 delta-q 之后）:
   - skip_mode → intra=0
   - seg && (seg.ref >= 0 || seg.globalmv) → intra = !seg.ref
     （注意 1.5.1 不看 seg->skip！与 §3.1-2 的 skip_mode 门不同）
   - 否则 ictx = get_intra_ctx(a,l,by4,bx4,have_top,have_left)
     （= av1_inter_intra_ctx，已有），intra = !bool_adapt(cdf.intra[ictx])
7. intra 分支（inter 帧内差异，decode.c:1052-1266）:
   - ymode：inter 帧用 cdf.y_mode[ymode_size_context[bs]]
     （单 ctx，不是 kfym 矩阵！）；angle/uv/cfl/palette/filter_intra/
     pal_indices/tx size 读取全部同关键帧（同一套 cdf 与 ctx 函数）
   - tx size：同关键帧（get_tx_switch_ctx 用 a/l.tx_intra）
   - 重建 recon_b_intra → 已有
   - LF 掩码 create_lf_mask_intra → 已有
   - 上下文回写：除关键帧字段外，inter 帧还要写
     comp_type=0、ref[0]=ref[1]=-1、filter[0]=filter[1]=3
     （= N_SWITCHABLE，解码.c:1246-1251）
   - ★splat_intraref（decode.c:1265-1266）：把 intra 块发布进
     refmvs 行环（rstate.splat_intra，已有）
8. inter 分支：= av1_inter_read_block（§83-84 已位级验证）+
   read_vartx_tree（§91）+ av1_recon_b_inter（§93）+
   create_lf_mask_inter（§82）+ splat（驱动内已含）+
   上下文回写（decode.c:1891-1910：seg_pred/skip_mode/intra=0/skip/
     pal_sz=0/tx_intra=b_dim[2+i]/comp_type/filter[0,1]/
     mode=inter_mode/ref[0]/ref[1]）
9. 公共尾：segmap 写回（update_map 时，decode.c:1913-1925）+
   noskip 掩码（!skip，关键帧路径同款）
```

### 3.2 reset_context 的 inter 版（decode.c:2392）

关键帧重置之外，inter 帧每个 sbrow 对 a（帧首一次）与 l（每 sbrow）
额外置：`ref[2]=-1、comp_type=0、mode=NEARESTMV(0)、
filter[2]=3`；`intra=1` 对 keyframe 参数化（inter 帧=1）。
uvmode=DC_PRED、tx_intra=-1、tx=TX_64X64、lcoef/ccoef=0x40 等同关键帧。

### 3.3 单线程主循环（decode.c:3203-3246 `dav1d_decode_frame_main`）

```
for tile_row:
  for sby in [row_start_sb[tile_row], min(row_start_sb[tile_row+1], sbh)):
    by = sby << sb_shift;  by_end = (by + sb_step) >> 1
    if use_ref_frame_mvs:  load_tmvs(rf, tile_row, 0, bw>>1, by>>1, by_end)
        // ★全帧宽度 0..bw>>1，每个 tile_row 每 sbrow 只调一次（tile 外！）
    for tile_col: decode_tile_sbrow(t)   // 内部：refmvs tile_sbrow_init
                                            + reset_context(l) + 逐 SB
    if IS_INTER_OR_SWITCH: save_tmvs(rt, 0, bw>>1, by>>1, by_end)
    filter_sbrow(f, sby)   // deblock→cdef→lr（+resize）
```

- `rp_proj` 是**帧级**（Dav1dRefmvsFrame），全 tile 共享；load 每
  sbrow 一次写满整行。MoonBit 侧 `Av1RefmvsTileState.rp_proj` 目前
  每 tile 一份——多 tile 时必须让同 tile_row 的 tile 共享同一
  FixedArray 实例（引用语义，直接把同一数组塞进多个 state）。
- decode_tile_sbrow 内的 LR 读取（read_restoration_sb）：superres 时
  LR unit 的 x 坐标按 `4*bx*d >> ss + rnd >> shift` 从 upscaled 宽度
  反投影（decode.c:2672-2692）。现有 `av1_lr.mbt::read_restoration_sb`
  只移植了非 superres 路径（av1_lr_apply.mbt 头注"no superres"）。
- tile 边界的 tx_lpf 右边缘备份 + start_of_tile_row 标记
  （关键帧入口已实现，逐行照搬）。

### 3.4 CDF 继承与帧末更新（decode.c:3494-3501, 3148-3150, 3310-3313；cdf.c:3955）

- `in_cdf`：primary_ref_frame==7（NONE）→ `av1_cdf_copy_defaults(yac)`；
  否则 → **槽位 `cdf[pri_ref]`**（上一帧存档）。
- `refresh_context` = !disable_frame_end_update_cdf：帧末把
  **context_update_tile_id 号 tile 的终态 cdf** 存进刷新槽位；
  `dav1d_cdf_thread_update` = memcpy 模式部分 + 系数 CDF 每行尾
  padding 清零（标量实现不脏 padding，直接深拷贝 tile 终态即可）。
- refresh_context=0 时槽位存 in_cdf（原样继承）。
- ★MoonBit 需要新增：`Av1CdfCtx` 深拷贝函数（字段都是
  FixedArray[UInt16]，逐字段 .copy()），槽位结构持有 CDF 快照。

### 3.5 槽位刷新与帧级状态（decode.c:3671-3712）

refresh_frame_flags 置位的槽位 i 获得：
- `p` = sr_cur（**upscaled + 全部 in-loop 滤波后**的输出图）；
- `cdf[i]` = out_cdf（refresh_context）或 in_cdf；
- `segmap` = cur_segmap（segmentation 时；cur/prev 双缓冲语义见
  decode.c:3614-3667：update_map → 新 buffer；!update_map → 直接
  沿用 prev_segmap 引用；prev_segmap 仅当 `temporal || !update_map`
  且 primary ref 的 bw/bh 相等时从 `refs[refidx[pri]].segmap` 取）；
- `refmvs` = 本帧 rp（!allow_intrabc 时）。
- `refpoc[i] = refp[i].frame_hdr->frame_offset`（7 个 ref 的 order hint）。

### 3.6 参考有效性 / svc 缩放 / gmv_warp_allowed（decode.c:3446-3492）

- 每 ref 校验：图像存在、尺寸 2x/16x 范围、layout/bpc 一致，否则报错。
- 缩放判定用 **本帧 coded width（width[0]）vs ref 的 upscaled p.w**：
  不等 → `scale = ((ref<<14)+cur/2)/cur`，`step=(scale+8)>>4`
  （y 与 uv 各一套）；相等 → scale=0（不缩放）。
- `gmv_warp_allowed[i] = gmv[i].type > TRANSLATION &&
  !force_integer_mv && !get_shear_params(gmv[i])（失败=false 即函数
  返回 0 才算成功）&& !svc[i].scale`。★GM warp 预测**尚未接线**
  （见 §4 缺口 G2）。
- `ref_mvs[i]`（rp_ref）：refs[refidx[i]].refmvs 存在且
  ref 的 **coded** 宽高换算 bw/bh 与本帧相等时可用，否则 NULL。

### 3.7 superres（decode.c:3528-3548 + get_upscale_x0）

- 解码用 coded-width 平面（f->cur），输出/参考用 upscaled（sr_cur）；
  `resize_step = scale_fac(coded, upscaled)`（y 与 uv），
  `resize_start = get_upscale_x0(in, out, step)`：
  `x0 = (-(out-in)<<13 + out/2)/out + 128 - err/2`，
  `err = out*step - in<<14`。
- 顺序：resize → deblock → CDEF → LR（全部作用于 upscaled）。
  dav1d 按 sbrow 交错；单线程可等价改为整帧 resize 后再做帧级
  deblock/CDEF/LR（现有 loop_filter_frame/cdef_frame/lr_frame 均为
  帧级，改造成本最低——但 `av1_lr_apply.mbt` 的 backup_lpf 语义
  “无 superres”注释要重新核对：LR 备份的是 deblock 后 CDEF 前的
  **upscaled** 平面）。
- LR unit 坐标映射见 §3.3。

### 3.8 obu.c 分段 update_data=false（obu.c:754-825）

`segmentation.update_data=0` 时**整个 seg_data 结构**
（8 段的 delta_q/delta_lf/ref/skip/globalmv + preskip +
last_active_segid + lossless 推导输入）从
`refs[refidx[primary_ref]].p.frame_hdr->segmentation.seg_data`
**逐字段复制**。MoonBit 侧 `av1_parse_frame_header` 是纯函数——
需要把 primary ref 槽位的**分段数据快照**传进去（建议扩展
`Av1RefSlotState` 或新增参数；同时注意 update_map/temporal 的
PRIMARY_REF_NONE 默认 1/0/1）。§94 只接了 seg_ref/seg_skip/
seg_globalmv 的特征读取，复制路径未做。

## 4. 已就绪部件 vs 缺口清单（MoonBit 侧）

已就绪（文件 → 能力）：
- `av1_inter_block.mbt`：`av1_inter_read_block`（完整 inter 语法 +
  splat 发布）；`Av1InterBlockParams`（含 skip/seg/svc 开关、
  bx4/by4 绝对 + bx4_ctx/by4_ctx SB 内坐标）。
- `av1_tx_tree.mbt::av1_read_vartx_tree`（内部自做 `&31`）、
  `av1_inter_residual.mbt::av1_read_inter_residual`、
  `av1_recon_inter.mbt::av1_recon_b_inter`（预测写回帧平面 +
  残差 itxfm_add + skip 上下文）。
- `av1_refmvs_state.mbt`：frame/tile 状态、begin/finish_sbrow、
  splat_*、find；`av1_refmvs.mbt::av1_refmvs_init_frame`。
- `av1_lf.mbt::av1_create_lf_mask_inter`（§82）、
  `av1_decode6.mbt` 的帧级 `loop_filter_frame/cdef_frame/lr_frame`、
  `av1_mc_core/scaled.mbt::av1_mc_resize`（§68）。
- `av1.mbt`：`Av1FrameHeader` 已含 primary_ref_frame/
  refresh_frame_flags/context_update_tile_id/disable_frame_end_update_cdf/
  ref_frame_idx/superres 等全部字段；`av1_extract_tiles`；
  `av1_warpmv.mbt` 有 `dav1d_get_shear_params` 移植。

缺口（按实施顺序）：
- **G1 decode_b inter 接入**（§3.1 的 6/7/8/9 + §3.2 reset）。
  - 邻域结构要**双份**：`Av1BlockContext`（intra/lcoef/skip/...）+
    `Av1InterTileState`（intra/comp/ref/filter）。两份都要在块尾回写。
  - ★坐标一致性（§94 遗留）：`Av1InterTileState` 的读取方
    （mask/jnt/filter ctx、has_overlappable、OBMC 滤波器、sub8x8）
    全部用 `&31` SB 内坐标；`set_block` 目前按绝对坐标写。两种修法：
    (a) 数组按 dav1d 32 项 + `&31` 索引，top 为 128 列 bank 跨 sbrow
    保存、left 每 sbrow reset（推荐，最贴上游）；
    (b) 全绝对坐标 + 把所有读取处改绝对（改动面大，不推荐）。
    现有 96 组对拍在坐标 <32 时两者等价，改完必须复跑。
  - inter 帧内 intra 块：ymode 走 `cdf.y_mode[ymode_size_context[bs]]`；
    重建复用 `recon_b_intra`；额外回写 inter 邻域字段 + splat_intra。
  - inter 块：`av1_inter_read_block` → vartx → recon → LF 掩码
    （is_globalmv = inter_mode==(is_comp?GLOBALMV_GLOBALMV:GLOBALMV)，
    lf_lvls 基址 `lflvl[seg_id][0][ref0+1][!is_globalmv]`）→ 回写。
  - interintra 的 intra 预测平面（Av1ReconPlanes）：用
    `av1_prepare_intra_edges`+`av1_ipred_predict` 在**当前帧平面**
    上生成（dav1d recon_tmpl.c interintra 分支；§88 测试是手工构
    平面，驱动里要现算，注意 DC 边缘不足时的 fallback 与
    interintra 模式 angle）。
- **G2 GM warp 预测**：`av1_recon_single_plane`/compound 只认
  `motion_mode==2` 的 derive_warpmv 矩阵。dav1d recon_tmpl.c
  1604-1608（单参考 luma）、1716-1722（chroma）、1795（复合）：
  `inter_mode==GLOBALMV && gmv_warp_allowed[ref]` 时用**帧头 GM 矩阵**
  走 warp_affine（矩阵要过 get_shear_params 求剪切参数）。libaom
  常开 GM 的流（mandelbrot ROT_ZOOM 向量已有 GM 矩阵真值）会踩中。
- **G3 seg temporal/!update_map 三个分支**（§3.1-1）+
  `get_prev_frame_segid` 移植（decode.c:494-510：prev_segmap 上
  w4×h4 首块一致性检查）+ update_data=false 复制（§3.8）。
- **G4 会话对象**（建议新文件 `av1_session.mbt`）：
  ```
  Av1RefSlot { picture: Av1FrameOutput?, order_hint, coded_w/h,
               seg_data 快照, segmap?, cdf?, rp?, gm(已有 Av1RefSlotState) }
  av1_decode_obu_packet(session, obus) -> Av1FrameOutput?   // show 才输出
  ```
  - show_existing_frame → 直接输出槽位 picture（无解码）；
  - key/intra 帧：复用关键帧解码（superres 时需 G5）；
  - inter 帧：新入口（§3.3 主循环 + §3.4/3.5 状态机）。
- **G5 superres**：coded/upscaled 双平面 + resize_step/start +
  整帧 resize + LR unit 坐标映射 + read_restoration_sb 补分支。
  关键帧入口目前**显式拒绝** use_superres——inter 序列里关键帧
  也可能开 superres，会话入口必须两条路都支持（可先拒绝跑通
  非 superres 流，再补）。
- **G6 端到端**：docker 产流（命令在旧文档 §4.4）+ IVF 驱动
  （照 `av1_kf_realdata_wbtest.mbt` 的 12 字节包头逐包喂）+
  framemd5 对拍 + 新向量包 `av1_inter_realdata_wbtest`（放独立包，
  主包 wbtest 的 Wasm init 局部变量已满）。

## 5. 推荐实施顺序与验收

1. G1（decode_b inter + 双邻域 + reset）：先用 §84 的 96 组向量
   复跑保证不回归；新增长随机流（含 intra/inter 混合）用
   `.scratch/av1/` 的 C 仲裁器对拍 decode_b 全决策序列。
2. G3 + G4 骨架（单 tile、无 superres、无 temporal seg 的简单
   P 帧流）：目标 = docker 单 key + 2P 流前 3 帧 MD5 收敛。
   分二分：先只比 msac 终态/帧头解析，再比像素。
3. G5 superres + LR 映射：`-sunloss`/libaom superres 流
   （`ffmpeg -c:v libaom-av1 -superres-mode 2`）。
4. G2 GM warp：`mandelbrot` GM 流（GM 矩阵真值向量已在
   `av1_inter_hdr_vectors`）。
5. G6 全量：多 tile P/B、10-bit、422/444、segmentation
   temporal、skip_mode、OBMC/inter-intra/wedge 真实流
   （testsrc2/mandelbrot + `-cpu-used 4..8` 各档）。
每步：`moon check --deny-warn --no-render` 0/0 → 全量绿 →
中文 commit → push（自主推进）。

## 6. 工具链速查（细节看旧文档 §4/§5，仍然有效）

- docker C 参照：`vpxdev-img:latest`（gcc；entrypoint `[sh]` 要
  `-c`）；`linuxserver/ffmpeg:9.0.2` 产流与 framemd5。
- 向量生成：emitter `scripts/_emit_av1_*.py` + 模板
  `scripts/_av1_*_test_body.tpl`，向量放独立 `*_vectors` 包。
- 调试：符号级 trace 对拍（MoonBit 与 C 同流打印 `值 rng difhi
  cnt pos` 归一化 diff）；测试并行 → rnd 状态局部化。
- 交付：`moon info` 生成 .mbti 不提交；README/PORTING_HISTORY/
  AV1_AGENT_HANDOFF 三件套同步。

## 7. 坑（旧文档 §5 全部适用，另加本轮 3 条）

1. **邻域坐标**：见 G1 —— 上 sbrow 的 top 必须保留（dav1d 的 a
   bank 跨 sbrow），left 每 sbrow reset；`has_overlappable_neighbor`
   读 left[by4+1..]（块内行,已被左块写过）。
2. **CDF 行尾 padding**：标量 msac 不会脏，但若以后对拍
   cdf_thread_update 的 dump，注意 C 版会把尾槽清零。
3. **尺寸比较基准**：svc 缩放比较用 ref **upscaled** vs 本帧
   **coded**；refmvs/segmap 继承比较用 ref **coded**（bw/bh 公式
   `((w+7)>>3)<<1`）——两处基准不同，别混。
