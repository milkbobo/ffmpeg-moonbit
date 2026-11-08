# AGENT_HANDOFF_2026-11-08 — AAC 根因 #8 破案：域偏移 + 缺失 trellis 段（§366）

> 上下文：FFmpeg→MoonBit 迁移，AAC 感知编码器与 ffref 进程内 C 预言机
> （ffmpeg-moonbit-ffref:nine-dbg 镜像，libavcodec_dbg.a 含探针对象）对拍。
> §365 把帧预算失控收窄到 (q, cb, 带集合)；本片（§366）双时点 per-band
> 打点 + gg 序列内容配对，**两个根因全部现形且都已修复**，spectral
> 位差从 +47% 收敛到 **−1.6% / −0.1%**。

## 一、本轮两个根因（都已在工作树修复，未提交）

### 根因 ①：初始 sf 阶梯 3.5≠4 域偏移（已修）

**机制**：port 的 frame_coefficients 出口是 C 的 2× 系数域 → psy 频带
（threshold/energy）= **4×C**（TWOINITP vs TWOINIT 实测逐带 ratio≈4.0000，
残差 ~1e-5 来自 psy 链里的 ATH 绝对常数，非齐次）。量化器表网格是
**每倍频程 +4 sf**（2× 系数恰好吸收），但初始 sf 公式
`140 + 1.75·log2(peak/size)` 对 4× 的 peak 只补偿 `1.75·2 = 3.5` 步 →
**整个初始阶梯半步偏**（每带 +3 或 +4 舍入不一）。这就是历史记录里
「初始 sf +3 域回影」的机械本质。搜索的 qstep/细化循环随后把半步偏
放大成 ±1~2 sf/带的全程偏差（两帧搜索都跑满 maxits=30 未收敛，
fflag=1，ε 被迭代放大）。

**修复**（`libavcodec/aac_twoloop.mbt`）：
- `aac_two_uplim_floor`：0.0012499999720603228 → **0.004999999888241291**
  （= 4×f32(0.00125)，域一致下 max(4f,u)=4·max(f,u)）。
- 初始 sf 块（~line 960-990）：`peak_c = peak/4`（回 C 域）后
  `140 + 4.0 + 1.75·log2(peak_c/denom) + sfoffs` —— 显式 +4 网格移位。
- 修复后实测：TWOINIT 8 带 sf **逐带精确 +4**（181/181/182/… vs C
  177/177/178/…）。

### 根因 ②：缺失 `codebook_trellis_rate` 段（已修）

**机制**：C 的 twoloop coder 在搜索与写位之间（`encode_band_info`，
aacenc.c:615-627 → aaccoder_trellis.h:52）对每个窗组跑一个
**(codebook × run) Viterbi**：用与搜索同一个计价函数（lambda=0 只取
bits）+ 段落开销（run_bits+4 起、run_value_bits 表）最小化**实写位**，
重选每带 cb 并把部分带改成零带，**in-place 改写 element 的
band_type/zeroes（sticky 状态！）**，段落数据由它自己发。port 完全
没有这一段 → 写位用搜索的原始 cb，多花 ~20% 位。
判决性数据：同 sf 带 C cb=10 17bits vs port cb=7 24bits（run366b，
ch1 g5 sf 162/162）。噪声/强度带不受影响（in_map/startcb 机制使
13/14/15 只有自己是合法候选）。

**修复**：
- 新文件 `libavcodec/aac_enc_trellis.mbt`：完整端口（run_value_bits
  long/short 表、aac_trellis_cb_in/out[15/16] 表、`priv struct
  AacTrellisNode`、DP + 回溯 + cb/zeroes 就地改写；C 的段落位输出由
  port 既有 write_sections 从改写后的 cb 数组推导，位等价）。
  代价全是整数值（bits+run_bits）→ **DP 无 ε、纯确定**。
  bits 计价复用 `aac_two_band_cost(..., lambda=0.0)`（§364 已证与写位
  恒等；port 无 uplim 早退 = C 传 INFINITY 的语义）。
- 集成（`libavcodec/aac_encode.mbt` ~line 3370，channel_data_psy 之前
  每通道调用）：传 work[ch]（TNS 后系数）、内部 sf（+4 域，
  与表网格自洽）、mutating cb_ch/zeros。**非 MS 时 cb_ch/zeros 就是
  sticky 数组本体**（cbs.push(st_cb)/zeros.push(st_z) 是别名）→ 自动
  回写；**MS 时 cb_ch 是 ms.cb0/ms.cb1 副本** → 加了显式
  sticky_cb 回写循环（对齐 C 的 sce->band_type in-place 语义）。
  trellis 只动 cb/zeroes，sf 链不动。

## 二、验证状态（已跑 / 未跑）

**已验证**（docker native `-p ffref`，nine-dbg 镜像，全部测试 exit=0）：
- 帧预算逐字段恒等：TWOPARM vs TWOPARMP dest=1114 many=1253 few=975
  cutoff=743 rdlambda=1.414213538（感知立体声首帧）。
- 搜索轨迹结构恒等（run366c）：its 相位序列、fflag、bt0/bt1 全同；
  port 阶梯 = C+4±1~2（its0 一度 +6 后稳定 +5 —— ε 残余，见下）。
- **trellis 落地后（run366d）帧内 spectral 总量**：
  ch0 C 1504 vs port 1480（−1.6%）；ch1 1418 vs 1417（−0.1%）。
  修复前同口径 +21.7%/+22.5%，§363 时 +47%。
- cb 选择对齐 C 家族（10/11），per-band bits 差 ±2 以内
  （ch0 g8-11 port cb8 vs C cb10 = sf ±2 的下游，非 trellis bug）。

**未验证/未跑**（交接首要）：
1. ~~run366e（FBDBG 帧尺寸 vs C RCDBG）~~ **已补跑完成（run366e.log
   37757 行，exit=0）**：感知立体声 13 帧逐帧 port vs C =
   **−0.5% / +0.9% / +3.7% / +9.9% / +3.6% / +5.7% / +2.7% / +0.6% /
   −0.9% / +3.4% / −4.1% / +1.1% / −3.8%**（平均 ~+1.8%；帧 1 从修复前
   +45% 收敛到 −0.5%；残余 = λ 跨帧漂移下游，见残余问题 1）。
   注意 C 侧 RCDBG 每 ABR 迭代打一行（同帧可多行），对齐取段内顺序前
   13 行即可。（ffref/moon.pkg 目前链 **libavcodec_dbg.a**；C 侧
   RCDBG/CHC/SPECC/TWOEXITC/TWOINIT/TWOPARM/TWOOUT/TWOLOOP 探针都在
   镜像里。分析脚本 .scratch/ffref/parse366.py + 各内联 python，日志
   run366.log/b/c/d/e 都在 .scratch/ffref/。）
2. **向量 28/28 未在两修复后重跑**；本机 wasm 全套（moon test，
   预期 1606/1606）未跑。**风险点**：向量由 _ref/aacenc harness 生成
   （跑真 C 编码器 → 含 trellis 效果），理论上现在更接近；但 PNS/IS
   夹具若断言 cb 序列可能受 trellis 改写影响（trellis 不改 sf、
   保噪声/强度带）。若断言失败先看是不是夹具假设而非行为回归。
3. 质量门（NMR/谱 SNR）未重测（此前 128k 15.14 / 64k 19.12 dB
   超原生；trellis 是省位不省质量，预期不降）。
4. **未提交**。

## 三、残余问题（按优先级）

1. **λ 跨帧漂移**：帧 1 位差已缩到 ~±2%，但 26 帧立体声 gg 序列仍只
   2/26 精确（f1 +1/−1 的 ε 级；f7 一度 +23 —— ABR λ 对首帧尺寸的
   敏感放大）。trellis 落地后尺寸差大幅缩小应连带缓解，需 run366e
   确认 FBDBG 逐帧 vs RCDBG。
2. **ε 本源**：psy 链非齐次（ATH 绝对常数）→ port 阈值 = 4×C(1±1e-5)，
   30 次未收敛迭代放大成 ±1-2 sf/带。彻底消除 = **全域统一**（psy
   输入 ÷2、量化器域、去 channel_data_psy 的 −4 层、向量全重生成；
   5-10 片工程，此前已评估）。+4 网格方案已把可对齐的部分全对齐。
3. **简化路径（默认/SNR 配置）独立 bug 未动**：port gg=176/175(f1)、
   102/94(f2) vs C 149/149、184/147；帧位 ~24k/通道爆炸。注意
   **C 没有简化路径**（永远 psy+twoloop+trellis）；port 的简化路径是
   自创（向量夹具钉住其行为）。修法二选一：a) 简化路径内部修 offset
   搜索；b) 默认配置也走感知管线（改向量）。单列一片。
4. C 写位传 `sce->ics.window_clipping[w]` 作为 rounding（削波回避），
   port 未建模（无削波时 = C_QUANT 恒等；正弦测试未触发）。远处项。

## 四、工作树状态与打点清理清单（提交前必做）

**工作树含未提交的：两个修复 + 新文件 aac_enc_trellis.mbt（保留）+
§366 全部打点（要清）**。精确清单（grep "§366" 可复核）：

- `libavcodec/aac_twoloop.mbt`：line 865-867 TWOPARMP、
  1018-1022 TWOINITP（含循环）、1567-1570 TWOOUTP。
  （**保留** line ~72-75 的 uplim_floor×4 和 ~960-990 的 init 修复——
  这两个不是打点！）
- `libavcodec/aac_encode.mbt`：line 746-749 两个 aac_dbg 计数器、
  3179-3184 TWOEXITP（含循环）、2390+2396-2426 WRB（dbg_bb0/bb1/qb
  包裹 + println）、2475-2478 WBDBG、3416-3417 FBDBG。
- `ffref/ffref_encode_ref_test.mbt`：SEG-A/SEG-B 两行 println。
- `ffref/ffref_test.mbt`：SEG-C 一行 println。
- `ffref/moon.pkg`：cc-link-flags 里 `libavcodec_dbg.a` → 改回
  `libavcodec_ref.a`。
- 清完跑：`moon check -p libavcodec` → 本机 `moon test`（wasm 全套）
  → docker native `-p ffref`（ref 镜像即可）全绿后提交。

**提交约定**：按精确路径 add（aac_twoloop.mbt、aac_encode.mbt、
aac_enc_trellis.mbt、PORTING_HISTORY.md、agent.md）；中文 feat: 信息；
尾行 `Co-Authored-By: ZCode <zcode@zcode.ai>`；同步记忆
（ffmpeg-moonbit-migration-progress.md）与 MEMORY.md 索引。

## 五、方法论坑（本轮新踩，交接必读）

1. **测试按名称字母序运行**：SEG-C(SNR) → SEG-A(stereo) → SEG-B(mono)
   （"AAC encoder…" < "AAC mono…" < "AAC perceptual…"），跨测试计数器
   （CHC k=26 起、WBDBG k=217 起）必须按内容配对，不能按段内首个。
2. **C 侧 stderr 与 port 侧 stdout 缓冲不同步**：SEG 分段对 C 行不可靠
   （stderr 即时、stdout 测试末尾 flush，日志里错位）。可靠配对法：
   gg 序列窗口匹配 + TWOINIT uplim 特征值（1.0925532e+07 第二次出现
   = 感知立体声首帧）+ CHC k 字段。
3. **SNR 测试与感知测试输入几乎相同**（都是 440Hz 立体声），短帧签名
   （gg=184/147, nwin=8）两边都有——用 CHC k 字段锚，别用形状锚。
4. **%.9e 打印被截断会骗人**：uplim=1.092553200e（+07 被吃了）差点
   误判域比 4e7；打印对齐时全串比较。
5. Git Bash 的 `-w /work` 被 MSYS 路径转换吃掉 → 必须
   `MSYS_NO_PATHCONV=1` 前缀。
6. `Double::INFINITY` 不存在（MoonBit）→ 用 1.0e308 哨兵（trellis 里
   语义等价：只参与 >比较与加法放大）。
