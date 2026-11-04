# AGENT_HANDOFF — Opus 原生编码器移植（2026-11-04，第二轮）

> 接手须知：先读本文，再读 `agent.md`（项目惯例）与 `PORTING_HISTORY.md` §270–275
> （AAC/MP2/MP3 编码器先例，Opus 应写为 §276）。本仓库 git 在 `moonbit/` 子目录。

---

## 0. 一句话状态（已交付，2026-11-04 收尾）

`moon check --target wasm --deny-warn` **干净**；全量 `moon test --target wasm`
**1382/1382** 通过。v1/v2 两组向量 **26/26 包逐字节一致**，ffmpeg 9.0.2
解码 Ogg Opus 零告警。临时探针与 dev 测试已删除，正式测试/文档见
PORTING_HISTORY §276。

交付前最后一轮修掉的四个根因：
1. `opus_enc_rc.mbt` 的 `end >> 23` 有符号移位（bit31 置位时 carry 少 1，
   单字节 0x44→0x42）；
2. `bands_dist` 的 `tdist` 必须按 C 用 Int 逐带截断（不是 Float 累加）；
3. `alloc_boost` 用截断而非 `rintf`；
4. `quant_band` 非立体声 split 的 `cmt` 移位与 level-0 collapse mask
   零扩展宽度（`B0 << recombine`）。

下文保留当时的分歧分析过程，供后续维护参考。

## 1. 本轮新增/确认的关键事实（都是真 bug，别再踩）

### 1.1 参考工具链（`_ref/opus/`）自身的错误 —— 已全部修正

上一轮"能量 2×"的根因不在 MoonBit，而在 **C 参考**：

| 问题 | 位置 | 说明 |
|---|---|---|
| MDCT 角度分母 | `ref_det.c: opus_ref_mdct_fwd` | 写成 `opus_ref_cos_multiple(a, N*2)`，应为 `N`（`tx_template.c` 里 `phase = M_PI/(4.0*len)`）。已用真 `av_tx` 判决过：den=N 时 `sum|diff|`=0.027，den=2N 时 121723，完全错 |
| 瞬态 MDCT 输出 stride | 同上 + `build_ref.sh` | av_tx 的第 4 个参数是 `sizeof(float)*blocks`（输出步长），旧版忽略了，导致瞬态帧系数写成一维连续；现 `opus_ref_mdct_fwd(dst,src,N,scale,stride)` 五参数 |
| 瞬态 MDCT scale | `build_ref.sh` | 旧值硬编码 1088，应为 `68 << 3` = 544 |
| psy 分析 MDCT scale | `build_ref.sh` | 旧值 136，应为 68（`bsize_analysis=CELT_BLOCK_960 → 68 << (3-3)`） |
| cos/sin 级数系数 | `ref_det.c` 的 `opus_ref_{sin,cos}_half` | 表是 `[1,1/2!,1/4!,...]` 错位，sin 需要 `1/(2k+1)!`、cos 需要 `1/(2k)!`。两处都已换成正确阶乘 |

**换向量了**：`fixtures.mbt` 已用修正后的 harness 重新生成（生成器
`scripts/gen_opus_enc_vectors.py`，13 包 = 12×241 + 1×1 字节，v1 2893 字节 / v2 1453 字节）。

### 1.2 MoonBit 侧的 bug（本轮修掉）

1. **`vector_fmul_reverse` 语义搞反**（`opus_enc_celt.mbt` 两处）：
   `dst[i] = src0[i] * src1[len-1-i]` —— **倒序的是第二个操作数（窗）**，不是采样。
   原来写成 `samples[rwin+127-i]*window[i]`，导致窗尾整段镜像，帧 MDCT 全错。
2. **`opus_enc_sin_half` / `opus_enc_cos_half` 阶乘表错位**（同上，与 C 同源错误）。
3. **`opus_enc_sinf` / `opus_enc_cosf`**（`opus_enc_math.mbt`）同一错位，已修。
4. **`OpusRangeEncoder::tell()` 少 1**（`opus_enc_rc.mbt`）：
   C 是 `total_bits - av_log2(range) - 1`，而 `av_log2(x) == ilog(x)-1`，
   所以 MB 应写 `total_bits - ilog(range)`。少 1 会让所有码率预算判断偏移。
5. **`celt_encode_frame` 里 `celt_bitalloc` 调了两次**（`opus_encode.mbt`）——
   第二次是在 dump 之后，纯多余且破坏 rc 状态。
6. **`alloc_trim` 的 cdf 表用错**（`opus_enc_alloc.mbt`）：
   应为 `[128, 2, 4, 9, 19, 41, 87, 109, 119, 124, 126, 128]`（tab.c），
   旧值是一张 10 项的无关表 —— **这一个让 tbits_8ths 差 4，直接毁掉整帧分配**。
7. **`pvq_band_cost` 原地量化了帧系数**（`opus_enc_psy2.mbt`）：
   C 把 X 拷到局部 `buf` 再量化，`f->block[].coeffs` 保持干净；MB 直接传进去，
   既污染后续误差计算，也污染真正的编码。
8. **`celt_calc_theta` 的 mono（时间分离）分支被硬编码成 0**（`opus_enc_bands.mbt`）：
   C 是 `itheta = quant ? celt_calc_theta(X, Y, stereo, N) : 0`，
   `coupling=0` 时算的是**时间分离角**，不是 0。
9. **itheta 的量化缩放被加了 `stereo` 条件**（同上）：
   C 是 `if (quant) itheta = (itheta*qn + 8192) >> 14;` —— **无条件**。
   漏掉后 mono 分支 itheta 爆到 1e6 量级。
10. **`celt_stereo_is_decouple` 的 epsilon 放错位置**：C 是
    `1.0f/(sqrt(e_l²+e_r²) + FLT_EPSILON)`，MB 写成 `1/sqrt(...) + FLT_EPSILON`。
11. **Bessel 系数表 stride 写成 8，实际每条带 10 个浮点**
    （`opus_enc_psy.mbt` 的 `opus_enc_bessel_hi/lo`）。除 0 号带外全部错位 →
    excitation/change_amp 全错 → 瞬态判定和 tf 搜索全错。
12. **psy 分析窗只填了后一半且错位一帧**（`opus_enc_psy.mbt: collect_step`）：
    C 的 `step_collect_psy_metrics` 在 `steps_per_half==1` 时把
    `bufqueue[index]` 放到 scratch[0..959]、`bufqueue[index+1]` 放到 scratch[960..1919]；
    旧实现只从 index+1 开始填前半段。
13. **`bands_dist` 覆写 `f.framebits`**（`opus_enc_psy2.mbt`）：
    C 的 `bands_dist` **不碰** framebits（gauge 已经算好，含 lambda）；
    旧实现用 `bit_rate/50` 重算，丢了 lambda。
14. **extradata 少一个字节**（`opus_encode.mbt`）：OpusHead 是 19 字节，
    C 在末尾还有 1 字节 channel mapping family（0）。`opus_encode_config_validation` 已通过。

**第二轮追加（折叠路径，全部在 `opus_enc_alloc.mbt` 的 `celt_quant_bands`）**

15. **`effective_lowband` 从来没被赋值**（写死 `let effective_lowband = -1`）——
    `norm_loc1/2` 永远是 `None`，于是 `quant_band` 里 `lowband == NULL`，
    **整条折叠（folding）路径被跳过，全部退化成 LCG 噪声填充**。
    C 是在 `lowband_offset != 0 && (spread != AGGRESSIVE || blocks > 1 || tf_change[i] < 0)`
    里给 `effective_lowband` 赋值的。
    判据：探针 `nf ... fold=` 在 C 是 1、MB 是 0。（修好包 2 直接 byte-exact）
16. **`foldstart` 多加了 1**。C 是
    `foldstart = lowband_offset; while (ff_celt_freq_bands[--foldstart] > effective_lowband);`
    —— do-while，**停在 `<= effective` 的位置就不再 +1**；
    MB 在循环后又 `foldstart += 1`，折叠范围少一个带。
17. **`collapse_masks` 没按 `uint8_t` 截断**。C 是 `uint8_t collapse_masks[]`，
    写入 `(uint8_t)cm[0]`；MB 是 `Array[UInt32]` 直接存。存的时候要 `& 0xFFU`。

18. **`tf_select` 表索引把 `select` 和 `change` 两个维度写反了**
    （`opus_enc_celt.mbt` 的 `opus_enc_celt_tf`）。
    C 是 `ff_celt_tf_select[size][transient][select][change]`，比较的是
    `[0][tf_changed]` 与 `[1][tf_changed]`；
    MB 写成 `flat = size*8 + transient*4 + tf_changed*2`，然后取 `flat, flat+1`
    —— 等价于 `[tf_changed][0]/[tf_changed][1]`。
    后果：`tf_select` 那 1 bit 该不该写判错，整帧位流差 1 bit（tbits 差 8）。
    正确写法：`base = size*8 + transient*4`，取 `base + tf_changed` 与 `base + 2 + tf_changed`。
    **修好这一条让 v1 的包 4 直接变成 byte-exact。**

### 1.3 现在能对到什么程度

```
v1 pkt 0/1/2  size 241  firstdiff -1     ← 逐字节一致
v1 pkt 3      ...       103
v1 pkt 4      ...       -1               ← 逐字节一致
v1 pkt 5      ...        19
...
v1 pkt 12     size 1    -1               ← 尾部静音包
v1 total 2893 = 2893

v2 pkt 0/1      -1
v2 pkt 2..9     有差异
v2 pkt 10/11/12 -1
```

合计 **v1 5/13 + v2 5/13 = 10/26 个包逐字节一致**。

## 2. 剩余卡点（接手第一件事）

### 2.1 现在的准确位置

首批 5 个包（v1 的 0/1/2/4/12）全链路一致。以 **v1 包 3**（`fm=3`）为例，
两边**所有阶段都对得上**：

```
coarse fm=3 tell=131 tf=1046   C == MB
tf     fm=3 tell=172 tf=1370   C == MB
alloc  fm=3 tell=200 tf=1597   C == MB   (pulses/fine 全同)
bands  fm=3 tell=1920 tf=15353 C == MB   ← quant_bands 结束，完全一致
```

`bq`（每个 split 节点的 qn/itheta/qalloc/b）序列前 8058 条也完全一致。
也就是说：**rng 状态一致、位数一致，但最终字节不同**（包 3 首差在 byte 103）。

结论：差异只能在 **`put_raw` 写入的"内容"** 上 —— 位数相同、值不同。
`put_raw` 只有三处来源：
1. `celt_quant_fine`（每带每声道写 `fine_bits[i]` 位的 `quant`）；
2. `celt_quant_final`（每带每声道 1 位的 `sign`）；
3. anticollapse 的 1 位。

`quant` 由 `floor((0.5 - error_energy[i]) * (1<<fine_bits[i]))` 决定，
而 `error_energy` 来自 `exp_quant_coarse` + `quant_fine` 的修正。
coarse 的 `e` 值两边已逐位一致，所以嫌疑在 `quant_final` 的 `sign`
或 `error_energy` 的 float 累减。

**下一步（需要 patch rc.c）**：
`build_ref.sh` 目前没有 patch `rc.c` —— 需要照 `celt.c` 的做法加一份
`rc_patched.c`（`ar d libavcodec_enc.a rc.o`），在 `ff_opus_rc_put_raw` 里打印
`(val, count, cachelen)`，再和 MB 的 `put_raw` 逐条对比，第一个不同的就是根因。

### 2.2 psy 路径仍有一段独立差异

`fm=6`（v1 包 5）起，psy 的 intensity 搜索曲线再次分叉：

```
        i=21      i=20      i=19
C     2154.0    2150.0    2141.0     ← 极小值在 19
MB    2147.6    2144.2    2157.1     ← 极小值在 20
```

后果：`is=19` vs `20`，`boost[6]` 0 vs 1 → alloc 阶段多/少写位，
`consumed` 差 69 eighths。**这条和 §2.1 是两条独立的分歧**，都要修。

### 2.3 已经确认一致的部分（不要再花时间）

- `frame_mdct`（含瞬态 8 块路径）逐系数一致；
- `celt_quant_coarse` / `celt_enc_tf` / `ff_celt_bitalloc` / `celt_quant_fine` 全部一致；
- `celt_gauge_psy_weight` 的 spread/alloc_boost/framebits 一致；
- `bands_dist` 里那次 bitalloc 的输出（cb/rem/fb/pulses/fine）一致；
- `alg_quant` 的输入 X（前 4 个采样）、旋转后的 X、PVQ 的 `y` 与 `norm`
  前 5356 次完全一致；
- `celt_cos` 全区间只有 `angle=16384` 一个差异（C 的 int16 回绕），该输入
  走 `itheta==0/16384` 特判，不影响；
- `celt_haar` / `celt_hadamard` / `exp_rotation_impl` / `stereo_merge` 的实现主体逐行等价。

### 2.4 对齐 diff 的方法（本轮验证有效）

两边都 dump 同一条序列（带 `fm=` 帧号），存成文本，用 Python 逐行解析、
按"有效采样数"比较（N=2 的带不要比 X[2]，C 侧那是 buf 里的残留垃圾，
MB 侧是新分配的 0）：

```python
# aq / sp 两条序列都适用；阈值 2e-6 对 float 够了
for i, (a, b) in enumerate(zip(c_seq, m_seq)):
    if a[:5] != b[:5]: print("STRUCT diff", i, a, b); break
```

⚠️ 不要用 `diff` 直接比文本：C 打印 `%.6e`、MB 打印 `{}`，格式不同会全行不同。

### 2.5 帧号对齐（本轮新增，务必使用）

两边都加了帧计数器，**但位置不同**：

- C：`celt_encode_frame` 里 `precoarse` 打印处自增（`opus_dbg_fm`），
  所以 **psy 探针（gauge/isearch/bc/tf）看到的是 N-1**，stage 探针（coarse/tf/alloc）看到 N。
- MB：同样在 `precoarse` 处自增（`_opus_frame_no`），行为一致。

**坑**：一开始我把 C 的计数器放在 `celt_encode_frame` 开头、MB 放在 precoarse，
导致两边 psy 探针差 1，`bc fm=3` 对出来的全是假的差异（还差点误判成
"tbits 差 170 比特"）。现在两边都在 precoarse 处自增，`bc fm=N` 可直接对比。

## 3. 已交付并提交（不要动）

| commit | 内容 | 验证 |
|---|---|---|
| `841daf7` | 统一格式探测层 + 文档精简 | 17 组真实夹具 |
| `a2613d1` | MP3 编码器（shine 3.1.1 移植，PORTING_HISTORY §275） | 三组向量与 C 参考逐字节一致 |
| `bf7fd3c` | Opus range 编码器 `opus_enc_rc.mbt` | 254 字节帧逐字节一致 |

**本轮所有改动都还没提交**（字节级没全绿，按 §7 的验收标准不能提交）。

## 4. 工作树

```
libavcodec/opus_enc_math.mbt      确定性数学（rintf/ln/log2f/expf/atan2f/sinf/cosf）
libavcodec/opus_enc_tables.mbt    表（band_end/mean_energy/window/bessel 等）
libavcodec/opus_enc_celt.mbt      CeltFrame/Block、preemph、frame_mdct、quant_coarse/fine/final
libavcodec/opus_enc_bands.mbt     quant_band 全模板、alg_quant、pvq_search、exp_rotation
libavcodec/opus_enc_alloc.mbt     celt_bitalloc + celt_quant_bands
libavcodec/opus_enc_psy.mbt       step 采集（MDCT/能量/tone/excitation/bessel）
libavcodec/opus_enc_psy2.mbt      gauge/pvq_band_cost/frame_init/process/postencode
libavcodec/opus_encode.mbt        OpusEncoder 编排（encode/decision/flush/toc/extradata）
libavcodec/opus_encode_vectors/   fixtures.mbt + opus_encode_vectors{,_test}.mbt
                                  + dev_dump_test.mbt（临时，提交前删）
scripts/gen_opus_enc_vectors.py   夹具生成器（本轮新增）
scripts/extract_opus_enc_tables.py 表提取
_ref/opus/                        C 参考工具链（gitignored）
```

### 临时调试代码清单（**提交前必须删**）

- `opus_enc_celt.mbt`: `debug_win` / `debug_samples` / `debug_mdct_bins` / `debug_mdct_dump`
- `opus_enc_psy2.mbt`: `debug_stage` / `debug_coeffs` / gauge、isearch、bc、tf 的 println
- `opus_enc_psy.mbt`: `collect_step` 末尾的 step println
- `opus_enc_alloc.mbt`: `alloc-supply` / `alloc-fine` / `fd` / `cm` println
- `opus_enc_bands.mbt`: `bq` / `aq` / `rx` / `pv` / `sp` / `nf` / `sm` println
- `opus_enc_psy2.mbt`: 追加 `qx` println（pvq_band_cost 里量化后的 X）
- `opus_encode.mbt`: `_opus_dbg` / `opus_enc_set_dbg` / `_opus_frame_no` / precoarse println
- `opus_encode_vectors/dev_dump_test.mbt`: 整个文件

（全部由 `_opus_dbg()` 或 `getenv("OPUS_DBG")` 控制，默认关闭，不影响正常路径。）

## 5. C 参考工具链现状

`bash _ref/opus/build_ref.sh` 会重建：

- `opus_ref_harness.exe <frames> <channels> <kbps> <out.pkt>` —— 确定性音源 + 包流 + `<out>.pkt.pcm`；
  设 `OPUS_DBG=1` 打开逐阶段 dump。
- `dumper.exe` —— 表 dump（`opus_enc_tables.mbt` 的源头）。
- `mdct_probe.c/exe` —— 用真 `av_tx` 验证朴素 MDCT 公式（分母 N vs 2N）。
- `celt_cos_probe.c/exe` —— **新增**：穷举 `celt_cos(0..16384)`，C 与 MB 只有
  `angle=16384` 一个差异（C 的 `int16_t` 回绕），该输入走特判，无影响。
- `patch_pvq.py` —— **新增**：pvq.c 的补丁逻辑独立成脚本（带 assert 锚点）。
  以后加探针改这个文件，**不要**再往 `build_ref.sh` 的 heredoc 里塞
  —— 那里 `s.replace(...)` 会互相吃掉锚点，本会话被坑过两次。

**本轮把 `celt.c` 也打了补丁**（`ff_celt_bitalloc` 在静态库里）：
`build_ref.sh` 现在会生成 `celt_patched.c`，dump `alloc-supply` / `alloc-fine`
两个中间态（pulses/tbits/total），并从 `libavcodec_enc.a` 里 `ar d celt.o`。

### 已加的 C 侧探针（都在 `build_ref.sh` 里，`OPUS_DBG=1` 才输出）

```
precoarse fm= tell= fb= pfilter= start= spread= trim= is= ds= boost: ...
frame/bx/qx/coeffs/cwin/...   （enc.c、dbg_dump.c、enc_psy.c）
step fm= idx= E: T: S:        （enc_psy.c step_collect_psy_metrics）
gauge fm= cb= rem= fb= pulses: fine:（enc_psy.c bands_dist，bitalloc 后）
isearch fm= i= dist=          （enc_psy.c celt_search_for_intensity）
bc fm= band= b= ex= ey= dist= cost=（enc_psy.c pvq_band_cost）
tf fm= cway= i= s0= s1=       （enc_psy.c celt_search_for_tf）
bq fm= band= qn= itheta= qalloc= b= N= is= cb=（pvq.c quant_band_template）
sp fm= band= n= b= ith= imid= iside= delta= mb= sb=（pvq.c split 位分配）
aq / rx / pv fm= n= k= ...    （pvq.c alg_quant 入口/旋转后/PVQ 结果）
nf fm= n= bl= fold= fill= seed=（pvq.c 零脉冲分支）
sm fm= n= mid= xp= side= E0= E1= X= Y=（pvq.c celt_stereo_merge）
coarse/tf/alloc/bands fm= tell= tf= fb= tr= ...（dbg_dump.c）
alloc-supply / alloc-fine fm= （celt.c ff_celt_bitalloc）
fd fm= band= lo= fs= fe= eff= rng= masks=（celt.c folding 区间）
cm fm= band= cm0= cm1= fbl= tf= tr= sp=（celt.c collapse mask）
```

**重要**：`fm` 在两边都在 `precoarse`（`celt_encode_frame` 中部）自增，
所以 **psy 探针看到的 fm 比 stage 探针小 1**（psy 在该帧的 `coarse` 之前跑）。
比较时按探针类型分别对齐。

**踩过的坑（观察者效应，本会话被坑两次）**：给 `ff_celt_bitalloc` 加
`alloc-fine` 探针时用了 `for (i = 0; i < CELT_MAX_BANDS; i++)` —— 而 C 紧接着有
`for (; i < f->end_band; i++) { f->fine_bits[i] = ... }`（复用上一次循环遗留的 `i`）。
探针把 `i` 改成了 21，导致 **C 的 fine 循环整个不执行**，C 的输出被污染，
我却拿它当"真值"追了好几轮"cm0=1 vs 255"的假差异。
**教训：探针的循环变量一律用独立名字（`qi`/`gi`/`fj`），绝不碰 `i`/`j`。**
同理，加探针后必须验证 harness 输出与 `fixtures.mbt` 仍逐字节一致（本会话最后一次验证：
2893 字节完全相同）。

**另一个坑**：`build_ref.sh` 里那段 `python - <<'EOF'` 往 C 源里注入 `printf("\n")`
时，`\n` 会被 Python 当转义变成真换行，生成非法 C 字符串。在 build_ref.sh 里必须写成
`\\n`（即文件里两个反斜杠）。

## 6. 复现命令

```bash
cd /d/project/FFmpeg-n9.0.2/moonbit
moon check --target wasm --deny-warn                                     # 必须干净
bash _ref/opus/build_ref.sh                                              # 重建 C 参考
python scripts/gen_opus_enc_vectors.py _ref/opus                         # 重生成夹具
moon test --target wasm libavcodec/opus_encode_vectors --filter dev_cmp_v1   # 逐包 diff
moon test --target wasm libavcodec/opus_encode_vectors --filter dev_mdct_v1  # 逐阶段 dump
cd _ref/opus && OPUS_DBG=1 ./opus_ref_harness.exe 12 2 96000 v1.pkt      # C 侧同上
```

⚠️ **对比时必须用同样的帧数**：`1 2 96000` 和 `12 2 96000` 的 psy 状态不同，
`tell`/能量都会不一样（本轮被这个坑过一次）。

## 7. 验收标准（全部满足才能提交）

1. `moon check --target wasm --deny-warn` 干净（**当前已满足**）。
2. `opus_encode_byte_exact_v1` / `_v2` 逐字节一致（含第 13 个 1 字节静音包）。
3. 删除 §4 列出的全部临时 dump + `dev_dump_test.mbt` 后，全量 `moon test` 全绿。
4. 新增正式测试：配置校验（声道数/样本不足，**已通过**）、
   extradata=19 字节 OpusHead（**已通过**）、解码往返（用本仓库 `opus_decode`
   解自己的包，SNR 合理）。
5. ffmpeg 9.0.2（本机 `D:\project\FFmpeg-n9.0.2\ffmpeg.exe`）能解码产出的 Ogg Opus
   且 `-v error` 无告警。
6. PORTING_HISTORY §276 + README 音频行 + agent.md「音频编码器」段。
7. 更新记忆文件 `opus-encoder-status.md`。

## 8. 已知边界（写进 §276 的「边界」段）

- 只支持 C 默认配置：48kHz、CELT-only、frame_size=960（20ms）、MONO/STEREO、FULLBAND。
- 与上游的显式偏差（均双端一致、需文档化）：确定性 libm 替换、
  直通 MDCT 替代 av_tx FFT（**注意：与真 av_tx 有 ~1 ulp 差异，见 §5 的 mdct_probe**）、
  Bessel 系数用 dump 而非 `tanf` 重算。
- native 目标未验证（本机无 MSVC，仓库 wasm-first 约定）。
- SILK/hybrid 不在 FFmpeg 原生编码器范围内。

## 9. MoonBit 语法/工具坑（累计）

- `Int` 与 `Int32` 同一类型；`Int → Float` 用 `Float::from_int`；`UInt32` 位重解释用
  `.reinterpret_as_int()`。
- 行折中缀运算符必须在**行尾**；字面量在左侧会推断成 Double。
- `~x` 不是取反；用 `x ^ 0xFFFFFFFF`（UInt32）。
- `.clip()` 不存在：用 `opus_enc_clip_i/clipf`。
- **`_test.mbt` 是黑盒测试**：本仓库新版本 MoonBit 要求它用
  `@包名.symbol` 全限定外部符号，且不能直接用 `@libavcodec.`。要访问私有实现
  必须命名 `_wbtest.mbt`（白盒）。`opus_enc_rc_test.mbt` 是黑盒，OK。
- heredoc 写 C 文件时 `printf("\n")` 会被 bash/python 弄成真换行 —— **用 Write 工具**。
- bash 的 cwd 会被随机重置到 `moonbit/` 根 —— 每条命令显式 `cd`。
- 清理一律 `mv` 到项目根 `.trash/<YYYY-MM-DD>/<原相对路径>`，不删。

## 10. 任务清单

1. 定位并修掉 psy intensity 搜索在第 3 帧起的差异 → v1/v2 全绿。
2. 删临时 dump（§4），保留正式测试，补 §7.4 的解码往返测试。
3. 全量回归 + PORTING_HISTORY §276 + README + agent.md。
4. 提交（一条 commit，对照 §275 风格）。
5. 更新记忆文件 `opus-encoder-status.md`。
