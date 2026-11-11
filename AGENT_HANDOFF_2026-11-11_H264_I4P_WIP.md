# AGENT_HANDOFF_2026-11-11 — H.264 P slice Intra4x4（§390）半成品交接

> **状态：WIP（未提交）。** HEAD = `5e2234a`（§389 AQ）。本片代码已写完且
> `moon check --deny-warn` / `moon fmt` 干净，探针重建不变式四链全过，但
> **ffmpeg/x264 仲裁、钉值测试、全量回归、文档/提交/推送都还没做**。
> 接手者从「剩余步骤」第 1 条继续即可，无需追问。收尾后本片替换为
> `AGENT_HANDOFF_2026-11-11_H264_I4P.md`（去掉 _WIP）。

## 本片目标

`h264_encode_frames` / `h264_encode_frames_cabac` 增 opt-in
`intra4x4_in_p~ : Bool = false`：允许 P slice 里出现 **Intra_NxN（I4x4）
宏块**（mb_type=5），十六个独立预测的 4x4 块，给 16x16/8x8 预测器跟不上
的细节纹理。两熵（CAVLC + CABAC）同构。**默认 false 必须逐字节不变**
（存量钉值不能动）。这是 §389 AQ handoff「剩余」第 3 条点名的 I4-in-P。

## 工作树（务必区分真实改动 vs 行尾伪改动）

`git status` 有 7 个 M，但**只有 4 个是 §390 真实改动**（+483/−5）：

| 文件 | 增量 | 内容 |
| --- | --- | --- |
| `libavcodec/h264_enc_dct.mbt` | +147 | 共享 I4 luma pass + 可用性助手 |
| `libavcodec/h264_encode_p.mbt` | +178/−5 | CAVLC 侧 plan/decide/residual/recon/write/stat |
| `libavcodec/h264_enc_cabac.mbt` | +100 | CABAC 侧写端 + 贯穿参数 + stat |
| `libavcodec/h264_enc_rc_test.mbt` | +63 | 探针 test "h264 i4p probe"（**待转钉值**） |

**另 3 个是纯 CRLF 行尾伪改动，`git diff --numstat` 为空（0 内容差），
不要提交、不要还原**：`ffref/ffref_test.mbt`、`libavcodec/h264_inter.mbt`、
`libavformat/playback_streaming.mbt`。提交时只 `git add` 上面 4 个文件。

## 已验证（探针，wasm-gc）

命令：`moon test --target wasm-gc -p milkbobo/ffmpeg-moonbit/libavcodec -f "h264 i4p probe"`
（**包名必须全路径**：`-p libavcodec` 会误匹配 native-only 的 x264 子包而报
「do not support target backend 'wasm-gc'」）。

夹具 `h264_rc_fixture(4)`（64×48 纹理游动，4 帧），qp=26，四配置：

| 配置 | 参数 | 结果 |
| --- | --- | --- |
| cavlc-all | intra_in_p=T, intra4x4_in_p=T, **dct8x8=T** | i4=6 i16=0 i8=0 len=2624 |
| cabac-all | 同上（CABAC 入口） | i4=6 i16=0 i8=0 len=2464 |
| cavlc-no8 | intra_in_p=T, intra4x4_in_p=T, **dct8x8 缺省=F** | i4=0 len=2198 |
| cabac-no8 | 同上（CABAC 入口） | i4=0 len=1956 |

**四链 `h264_rc_recon_invariant` 全过**（编码器逐 P 帧重建 == 解码器
未滤波 yuvp 的 md5；解码走 `h264_decode_annexb_frames(stream, true)`）。
即：写出的 I4 码流自洽、可被本移植解码器逐像素重建。`Total tests: 1, passed: 1`。

探针 stdout 已打出两整段字节 dump（**仲裁用，尚未落盘**）：
- `I4ARB:`（CAVLC，2624 字节，逗号分隔十进制）
- `I4CARB:`（CABAC，2464 字节）
no8 两配置只打 i4 计数 + 跑不变式，不打 dump。

## 未决问题（接手先查这条）

**no8 为什么 i4=0？** dct8x8=T 时 6 个 MB 选 I4；dct8x8=F 时同样夹具
0 个选 I4（那 6 个 MB 大概率回落 inter，码流更小 2198<2624）。两配置
`intra_in_p`/`intra4x4_in_p` 都为 T，唯一差 dct8x8。I4 候选本身只 gated
on `intra4x4_in_p`（见下），与 dct8x8 无关，所以**不是 I4 被关掉**，而是
RD 竞争结果随 dct8x8 改变。猜测：dct8x8 改变了 inter 残差的 8x8 路径
（`code_mb_residuals` 的 `dct8` 分支，`h264_encode_p.mbt:1882` 起），
使那 6 个 MB 的 inter 计价/重建变化，从而 I4 在 T 时胜出、F 时落败。
**尚未证实是合法 RD 结果还是 bug。** 排查入口：`eval_plan` 对 inter 的
干跑计价 + `code_mb_residuals` inter dct8 分支。注意：无论结论如何，
**cavlc-all/cabac-all（i4=6）已是有效的 I4 仲裁向量**，no8 只是额外
覆盖「无 transform_size_8x8_flag」路径——但 no8 既然 i4=0，就**没真正
走到 I4 写端**，需要一个无 dct8x8 仍 i4>0 的夹具才能钉住 no8 的 I4 语法
（换更细纹理/更高 qp 的夹具，或临时强制 I4 候选）。

## 两处决策质量/门控注记（_review，非码流Validity bug）

1. **I4 候选未 gated on `allow_intra`**：`h264_encode_p.mbt:1349`
   `if self.intra4x4_in_p`，而 I16（:1287）/I8（:1309）都是
   `if allow_intra`（=`intra_in_p`，调用点 :677）。字段文档（:114）写
   「independent of intra_in_p」，所以**可能是有意**：intra4x4_in_p=T 但
   intra_in_p=F 时只放 I4、不放 I16/I8。探针四配置都 intra_in_p=T，
   **这条组合从未测过**。接手决定：要么补 `allow_intra &&`，要么补一个
   intra_in_p=F + intra4x4_in_p=T 的用例确认语义。
2. **I8/I4 胜出时不更新 `best_cost`**：I16 胜出会 `best_cost = c16x`
   （:1296），但 I8（:1338）/I4（:1375）只 `plan = ...` 不改 best_cost
   （Part8x8 :1278  likewise，是存量模式）。后果：I8 先胜（plan=I8，
   best_cost 仍停在 min(inter,I16)），随后 I4 拿**陈旧 best_cost** 比较，
   若 c8<c4<best_cost 则 I4 顶掉更便宜的 I8。探针 i8=0 没触发，但
   dct8x8=T + intra4x4_in_p=T 同开时是真实决策缺陷。**只影响 RD 选优、
   不影响码流自洽**（选中的 plan 总被一致编码，故重建不变式照过）。
   建议收尾时让 I8/I4 胜出也更新 best_cost（与 I16 对齐），再重钉。

## 实现地图（已核对行号）

### 共享 pass — `libavcodec/h264_enc_dct.mbt`
- `:464 h264_enc_luma_i4_pass(src_y, rec_y, ystride, mb_x, mb_y, pps, qp,
  store, modes, mb, avail, fixed_modes~=[]) -> Result[(Int32,Int32),String]`
  qmul_y=`h264_build_dequant4(pps,0,qp)`；i=0..15 **z-order** 遍历，
  gx/gy 取自 `h264_luma_block_x/y`，g=gy*4+gx（**grid 索引**），
  off=ybase+gy*4*ystride+gx*4；(top,left,topright)=avail(gx,gy)；
  `fixed_modes.length()==16` 时回放（best_sig=fixed_modes[g]，eff 经
  `h264_check_intra4x4_mode`），否则 sig 0..8 按 `h264_enc_sad4` 搜索
  （先 `h264_pred4x4`）；胜者重跑，cost+=SAD，modes[g]=best_sig；
  残差→`h264_enc_fdct_quant_res(res,0,qp)`，store[16*i+s]=levels；
  mb 反量化经 `h264_enc_dequant_level`；total!=0 → cbp|=1<<(i/4)，
  total==1&&mb[16*i]!=0 走 `h264_idct_dc_add` 否则 `h264_idct_add`。
  返回 (cost, cbp)。**逐块内联重建**（每块用前面块的重建做预测）。
- `:583 h264_enc_i4_avail(mb_x,mb_y,mb_width) -> (Int32,Int32)->(Bool,Bool,Bool)`
  top=gy>0||mb_y>0；left=gx>0||mb_x>0；topright= gy==0 ?
  top&&(gx<3||mb_x<mb_width-1) : (gx==0||gx==2||(gx==1&&gy%2==0))。

### CAVLC — `libavcodec/h264_encode_p.mbt`
- `:55` `H264EncStats.i4p_mbs`（mut，::new() 置 0）；`:116` 编码器字段
  `intra4x4_in_p : Bool`；`:176` `h264_encode_frames` 参数（贯穿 RC 试跑
  :204 与终跑 :233 → `h264_encode_frames_qps` :257 → literal :391）。
- `:744` plan 变体 `I4(Array[Int32], Int32)`（16 grid 索引 mode + chroma mode）。
- `:1343-1379` decide_plan I4 候选（I8 块之后；scratch 跑 pass →
  raw_modes[16] → pick_chroma → eval_plan → 严格更便宜才换 plan）。
- `:1749` `h264_p_dct8x8_allowed` 增 `I4(_,_) => false`。
- `:1818` mc_plan `I4(_,cm) => predict_intra_chroma(...)`。
- `:1877-1881` code_mb_residuals `is_i4`/`is_intra`；`:1899-1907`
  qmul_y 对 I16||I4 用矩阵 0（intra），否则 3（inter）。
- `:2008-2015` I4 残差臂：fixed_modes=raw_modes 回放 pass 进 luma_store，
  逐块置 cur_nz（**z-order i → g=grid** 数 luma_store[16*i+s] 非零）。
- `:2278` 重建尾 `} else if !dct8 && !is_i4 {`——**I4 已内联重建，
  必须排除否则二次重建**（关键正确性点）。
- `:2328` write_mb_syntax is_intra 含 I4；`:2378` I4 CAVLC 臂：
  `put_ue(5)`；`if dct8x8 { put_bit(0) }`（transform flag）；16 mode 经
  `pred_nxn_mode(...,gx,gy,raw_modes)`（==predicted → put_bit(1)，否则
  put_bit(0)+put(rem,3)）；`put_ue(chroma_mode)`；
  cbp=luma_cbp|(chroma_c_cbp<<4)，`put_ue(h264_enc_cbp_golomb(cbp))`；
  cbp!=0 → put_se(mb_dqp)+prev_qp=mb_qp+stat；luma4 残差 i8/i4 循环
  `scan_view_at(luma_store,i,h264_zigzag_scan_t,0,16)`+nc_luma+
  `h264_enc_write_residual(r,view,16,nc)`。**色度残差走共享尾**（~:2522）。
- `:2715/2734` commit_plan_state：st.intra 含 I4；`I4(raw_modes,_) =>
  st.intra_nxn=true; st.modes[g]=raw_modes[g]`。
- `:685` encode_p_frame `if plan is I4(_,_) { stats.i4p_mbs += 1 }`。

### CABAC — `libavcodec/h264_enc_cabac.mbt`
- `:2752` `h264_encode_frames_cabac` 参数（RC 试跑 :2778 / 终跑 :2806 →
  `_qps` :2830 → literal :2956）。
- `:2129-2218` write_cabac_mb_syntax I4 臂：`decision(14,1)`（intra）+
  `decision(17,0)`（I_NxN）；ctx.cur_mb_is_intra=true；
  `if dct8x8 { decision(399+h264_neighbor_transform_size(...), 0) }`；
  info.transform_8x8=false；16 mode 经 `h264_pred_intra_mode(ctx,...,gx,gy,
  raw_modes)`，ctx 68（prev flag）/69（rem 3 bin **LSB-first**，
  rem=mode>predicted?mode-1:mode）；色度树 cc=左/顶 chroma_mode!=0 计数，
  ctx 64+cc / 67；cbp 经 `h264_cabacw_cbp(...,true)`，info.cbp_all=cbp；
  cbp!=0 → `h264_cabacw_dqp`+stat，else ctx.last_qscale_diff=0；
  luma 残差 **cat 2** i8/i4 循环 cbp-gated，`scan_view_at(...,0,16)`+
  `h264_cabacw_residual(...,2,i,view,16,false)`；`h264_cabacw_chroma(...)`；
  info.mb_type_bits=`h264_mb_type_intra4x4`、intra4x4=true、chroma_mode、
  qp=ctx.qscale、modes[g]=raw_modes[g]。
- `:2695` encode_p_frame_cabac `if plan is I4(_,_) { stats.i4p_mbs += 1 }`。
- CABAC P 复用 CAVLC 的 decide_plan/code_mb_residuals/mc_plan/
  commit_plan_state/eval_plan（**eval_plan 用 CAVLC 写器干跑计位**，
  两熵共用），故 I4 的 plan/残差/重建侧只写一遍。

### 探针 — `libavcodec/h264_enc_rc_test.mbt:631-691`
test "h264 i4p probe"，四配置见上表。可复用助手：`h264_rc_fixture(n)`、
`h264_rc_md5`、`h264_rc_recon_invariant(name,stream,recon,n)`、`h264_rc_sad`。

## 剩余步骤（按序）

1. **落盘 dump + ffmpeg 仲裁**：重跑探针把 stdout 存文件，用 node 把
   `I4ARB:`/`I4CARB:` 逗号串转二进制 `.h264`（写 `.scratch/`）。docker
   `linuxserver/ffmpeg:9.0.2` 解到 framemd5，**零 stderr 告警**，四帧
   md5 与编码器 recon 对齐。命令前置
   `export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`。
2. **x264 C oracle 交叉解码**（**用户硬性要求：必须用
   `moonbit-c-binding` + `make-moonbit-c-bindings` 两个 skill**）：
   `libavcodec/x264/x264_wbtest.mbt` 末尾加 I4 双熵 `x264_cross_decode`
   用例（参考 §389 AQ 用例写法：`x264_dct8_fixture` + intra4x4_in_p=true
   + i4p_mbs>0 断言）。运行见下「环境速查」。
3. **no8 未决问题**：先判定合法/bug（见上）。若合法，补一个无 dct8x8
   仍 i4>0 的夹具钉住 no8 I4 语法；若 bug，根修后重钉。
4. **探针转永久钉值**（追加进 `h264_enc_rc_test.mbt`，**别新建 .mbt**）：
   i4p_mbs 钉值（all=6）、重建不变式、**默认 byte-exact（intra4x4_in_p
   缺省 → i4=0 且与 §389 存量 dump 逐字节同）**、ffmpeg framemd5 钉值、
   no8 路径。先把 println dump 放在钉值断言之前（先收 dump 再钉）。
5. **决策质量注记**（见上两条）：决定是否补 allow_intra 门 / best_cost
   更新；若改 decide_plan 需重钉 all 配置 i4 计数与 dump。
6. **全量回归**：`moon check --target wasm --deny-warn`；`moon fmt`；
   全仓 wasm-gc（§389 基线 **1747**，本片应 ≥1747+新增）；非 gc 黑盒
   编码器（基线 47）；存量编码器 40 项钉值逐字节不变。
7. **文档 + 提交 + 推送**：`PORTING_HISTORY.md` 补 §390 节；`README.md`
   H.264 行 + 测试计数；本 handoff 去 _WIP；项目 memory 加进度指针。
   中文提交走 `git commit -F .scratch/msg390.txt`（**长中文 + rm-guard
   拦 `commit -m`，必须 Write 落盘再 -F**）；只 add 4 个真实文件；
   `git push origin master`（memory 授权每增量推送，无需再问）。

## 环境速查 / 坑

- **whitebox 一律 wasm-gc**；非 gc 只跑黑盒。非 gc whitebox `__init`
  局部数上限是预存限制（基线即触发 `local count too large`），与本片无关。
- 测试包名全路径 `-p milkbobo/ffmpeg-moonbit/libavcodec`（短名误匹配
  native-only x264 子包）。
- **Windows 32K 命令行上限**：libavcodec 包文件数贴近阈值，
  **严禁新增 .mbt 文件**，测试一律追加进既有文件。
- **rm-guard 拦 bash 删除类子串 + 长中文 `commit -m`**：长文本/提交信息
  一律 Write 工具落盘再执行/`git commit -F`。heredoc `\n` 在本 shell
  管线会被吞——写脚本用 Write，别用 heredoc 拼多行。
- docker 仲裁镜像 `ffmpeg-moonbit-ffref:nine-x264`；x264 oracle 运行：
  `MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh -v
  "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work
  ffmpeg-moonbit-ffref:nine-x264 -c "/root/.moon/bin/moon update
  >/dev/null 2>&1; /root/.moon/bin/moon test --target native -p
  libavcodec/x264 --target-dir /tmp/mbuild"`
- 参考解码镜像 `linuxserver/ffmpeg:9.0.2`（entrypoint=ffmpeg；ffprobe 加
  `--entrypoint ffprobe`）。framemd5：`-f framemd5`；取 Annex B：
  `-c:v copy -bsf:v h264_mp4toannexb -f h264`。
- `.scratch/` 未跟踪（dump/中间产物/提交信息）；别提交 `pkg.generated.mbti`
  与本地 scratch 目录。

##  standing 约束（来自 memory，持续有效）

- 每增量：全量 wasm 测试 + 中文提交 + 推 origin/master，**无需再问**。
- 裸「继续」= 自主挑下一个缺口并交付完整增量。
- 不提交 3 个行尾伪改动文件；不提交 pkg.generated.mbti / scratch。
- 用户原始指令：用所有 MoonBit skill，**必须**用 `moonbit-c-binding` 与
  `make-moonbit-c-bindings`（x264 oracle 步骤强制触发）。