# AGENT_HANDOFF — AAC 3GPP 心理声学模型交付 / twoloop 量化器下一片（2026-11-04）

> 接手须知：先读本文，再读 `agent.md`（项目惯例）与 `PORTING_HISTORY.md` §277。
> 本仓库 git 在 `moonbit/` 子目录；`_ref/` 下的参考工具链是 gitignored 的。

---

## 0. 一句话状态

`aac_psy.mbt`（FFmpeg 9.0.2 `aacpsy.c` 的 3GPP 模型）已移植完成、与 C 参考
逐带对拍通过，`moon check --target wasm --deny-warn` 干净，全量
`moon test --target wasm` 全绿并已提交。**该模块目前是独立可验证层，尚未接入
`aac_encode.mbt`**；后者仍用 §271 的简化心理声学与全局 delta 二分。

---

## 1. 已交付内容

| 文件 | 内容 |
|---|---|
| `libavcodec/aac_psy.mbt` | 755 行：`psy_3gpp_init`（长/短窗静态系数）、`calc_thr_3gpp`、双向扩散、预回声控制、`calc_bit_demand`、PE / reduction 两轮估计、avoid-holes、linearization、高频 PE 削减、`FFPsyBand` 发布与跨帧状态提交 |
| `libavcodec/aac_psy_vectors/fixtures.mbt` | 5 帧 × 1024 点谱 + 49 带参考（PSYBAND / TWOBAND / PSYALLOC），由 `scripts/gen_aac_psy_vectors.py` 生成 |
| `libavcodec/aac_psy_vectors/aac_psy_vectors_test.mbt` | 黑盒 3 项：5 帧逐带对拍、跨帧预回声状态、band plan 与有限阈值 |
| `_ref/aacenc/` | C 参考工具链（gitignored）：`patch.py` + `build.sh` + `harness.c` → `aac_ref.exe` → `vectors.txt`，README 逐字段标注了 C 源行号 |
| 文档 | `PORTING_HISTORY.md` §277、`README.md` 音频行、`agent.md` 音频编码器段 |

### 复现

```bash
cd /d/project/FFmpeg-n9.0.2/moonbit
moon check --target wasm --deny-warn
moon test --target wasm libavcodec/aac_psy_vectors     # 3/3
cd _ref/aacenc && bash build.sh && ./aac_ref.exe > vectors.txt
cd ../.. && python scripts/gen_aac_psy_vectors.py
```

### 验收口径

- `alloc` / `fill_level` / 每带 `bits`：**逐位一致**。
- energy / spread / entropy：相对误差 ≤1e-5；threshold：≤5e-4。
- threshold 放宽是因为 frame 4 band 0 恰好落在 reduction/linearization
  边界，C 的 f32 与移植侧 f64+边界舍入差 1 ulp 被放大到约 1e-4 相对。
  其余 244 个 threshold 都在 1e-5 量级内。**不要把这个容差再放宽**，
  否则会掩盖结构性错误。

---

## 2. 关键坑（改动 `aac_psy.mbt` 前必读）

1. `psy_3gpp_init` 的 `coeffs[g+1].barks - coeffs->barks`：`coeffs` 是**数组
   指针**，减的是 `coeffs[0].barks`（从 0 号带起的累积 Bark 宽度），不是
   相邻带差。写成相邻差会让所有 `min_snr` 掉到 -25 dB 下限，reduction 整段失效。
2. `calc_reduced_thr_3gpp` 是 `(sqrt(sqrt(thr)) + reduction)^4`（C 两次
   `sqrtf` + 两次自乘），不是混合根相乘。
3. `en_spread_hi` 的上游判据把 bits/s 的 `chan_bitrate` 与 `22`（kbps）比较，
   对任何真实 ABR 码率恒选 `HI_L1`；照抄，别"修正"单位。
4. C 全程 `float`。谱输入必须 f64 `sin/cos` 算完再**强转 f32**；psy 内部
   每个 `log2f/exp2f/exp10f` 的结果都存进 `float`，移植侧用
   `aac_psy_f32()` 在 libm 边界舍入一次（不是每步都舍入）。
5. 参考 harness 的 `bitres.bits = 0`（每帧）→ `fill_level` 被
   `av_clip(..., 0, bitres.size)` 钳成恒 4656。真正演化的跨帧状态是
   `bitres.alloc`（2229→1966→1943→1910→1971）、`entropy`、`pe.min/max`、
   `prev_band`。`fill_level` 恒定不是 bug。
6. `analyze(coefs, prev_bits)` 的 `prev_bits` 是显式参数，未来接比特流写入器时
   喂 `bitres.bits`；现在测试恒传 0。

### 边界

单长窗（`num_windows=1`、`ONLY_LONG_SEQUENCE`、44100 Hz / 49 带）、ABR（无
QSCALE）、PNS/TNS/IS/M-S 全关、无块切换。短窗系数表在 `init` 里构建但
`analyze` 不走。合成谱输入，未跑 PCM→MDCT。

---

## 3. 下一片：twoloop 量化器（`aaccoder_twoloop.h`）

**夹具已经备好**：`fixtures.mbt` 里的 `aac_psy_ref_two_sf` /
`aac_psy_ref_two_cb` / `aac_psy_ref_two_zeroes` / `aac_psy_ref_two_maxval`
共 5 帧 × 49 带 = 245 条，来自未修改的 FFmpeg 9.0.2
`search_for_quantizers_twoloop`。目前**没有任何 MoonBit 代码消费它们**。

### 3.1 参考 harness 的固定配置（可大幅简化实现）

`_ref/aacenc/harness.c` 的调用是
`ff_aac_coders[AAC_CODER_TWOLOOP].search_for_quantizers(&avctx, s, sce, 120.0f)`，
且：

- `num_windows = 1`、`group_len[0] = 1`、`num_swb = 49`、`ONLY_LONG`；
  `w`/`w2` 两层循环都退化成 1 次。
- `avctx->flags & AV_CODEC_FLAG_QSCALE == 0`（ABR 分支）。
- `s->options.pns / intensity_stereo / mid_side / tns` 全 0，
  `sce->can_pns[]` 全 0 → **所有 PNS / zeroable / spread_thr_r 分支可整段跳过**。
- `lambda = 120.0f`，`s->psy.bitres.alloc` 来自上一节 psy 的 `analyze`。
- `avctx->bit_rate = 128000`、`nb_channels = 2`、`sample_rate = 44100`。

因此 C 的 759 行里真正要移植的是：uplims/nzs 初始化 → 初始 scaler →
`abs_pow34` + `find_max_val` + `coef2minsf` → `find_form_factor` 调整 →
内层 qstep 位率收敛循环 → 外层 fflag/distortion 循环 → SF delta 重钳 →
`find_min_book` 收尾。PNS 那一大段（约 120 行）与 QSCALE 分支可省略。

### 3.2 依赖清单（源码位置均已核实）

| 依赖 | 位置 | 说明 |
|---|---|---|
| `abs_pow34_v` | `aacencdsp.c:26` | `out[i] = sqrtf(a * sqrtf(a))`，`a = fabsf(in[i])`；每步 f32 |
| `find_max_val` | `aacenc_utils.h:56` | 带内取 `scaled` 最大值 |
| `coef2minsf` / `coef2maxsf` | `aacenc_utils.h:133,139` | `av_clip_uint8(log2f(coef)*4 - 69 + SCALE_ONE_POS - SCALE_DIV_512)` |
| `find_min_book` | `aacenc_utils.h:68` | `Q34 = ff_aac_pow34sf_tab[...]`，`qmaxval = maxval*Q34 + C_QUANT`，查 `aac_maxval_cb[]` |
| `find_form_factor` | `aacenc_utils.h:80` | 方差/峰值比，含 `ff_fast_powf(s/thresh, nzslope)` |
| `quantize_band_cost_cached` | `aacenc_quantization_misc.h:31` | 只是按 `[scale_idx][w*16+g]` 缓存 `rd/bits/energy`，generation 失效重算 |
| `ff_quantize_and_encode_band_cost` | `aaccoder.c`（模板展开） | 真正算量化 + Huffman 位数 + 失真 + 量化能量 |
| 表 | `aactab.c:44,85,200` | `ff_aac_pow34sf_tab[428]`、`ff_aac_pow2sf_tab[428]`、`ff_aac_scalefactor_bits[121]`；`aac_maxval_cb` 在 `aacenc_utils.h` |
| 收尾工具 | `aacenc_utils.h:200-230` | `ff_init_nextband_map` / `ff_sfdelta_can_remove_band` |

MoonBit 侧已有 `aac_tables.mbt` 的 `aac_pow2sf` / `aac_pow43` 与码本
（`aac_spectral_sizes` 等）、`aac_encode.mbt` 的
`aac_encode_quantize_band` / `aac_encode_tuple_key` / Huffman 位数计算，
**先核对这些表与 C 的 `ff_aac_pow34sf_tab` 是否逐位相同**（harness 的
`aac_ref_tableinit()` 是 `aactab.c:49-88` 的逐字复制，可作真值），
不要直接拿 `aac_pow2sf` 当 `pow34sf` 用。

### 3.3 建议的对拍顺序

1. **先单独验证 `maxval`**（最容易、且不依赖搜索）：实现
   `abs_pow34`（注意 `sqrtf(a*sqrtf(a))` 的每一步 f32 舍入）+ `find_max_val`，
   对拍 245 条 `aac_psy_ref_two_maxval`。这一步能同时确认 swb 的
   `band_sizes` 与 C 的 `swb_sizes` 完全一致。
2. 再实现 `find_min_book` / `coef2minsf` / 位数与失真计算，用 C 侧
   `patch.py` 加探针 dump 中间态（照 `_ref/aacenc/README.md` §4.9 的做法：
   注入全局导出变量，不要 printf，避免格式漂移）。
3. 最后接 two-loop 搜索，对拍 `sf_idx` / `band_type` / `zeroes`。
   这三项是**整数决策**，必须逐位一致；浮点中间量用相对容差。
4. 加探针后务必验证 `aac_ref.exe > vectors.txt` 与 `fixtures.mbt` 仍逐字节
   一致（本项目在 Opus 轮被"探针复用循环变量 `i`"坑过，教训：探针循环变量
   一律用独立名字，绝不碰 `i`/`j`）。

### 3.4 更远的目标

twoloop 对齐后再把 `aac_psy.mbt` + twoloop 接入 `aac_encode.mbt`，替换
§271 的简化模型与全局 delta 二分，形成 FFmpeg 式的
"psy 分析 → 两遍码率控制 → 逐带量化"链路。接入会改变现有 AAC 编码输出，
现有 `aac_encode` 的往返 SNR / 码率 / ffmpeg 对拍测试需要重新定基准。

---

## 4. 工具坑（本轮实测）

- `moon test --target wasm` 全量曾**偶发卡在 `moonc` 编译
  `libavcodec/opus_hybrid_pcm_vectors`**（moon/moonc 两进程 20 分钟 CPU=0、
  无产物更新）。单独跑该包 13 秒通过，重跑全量也正常 → 是偶发的编译进程
  挂起，不是代码问题。遇到时 `TaskStop` 掉重跑即可，别去改那个包。
- 全量输出别用 `... | tail -N`（缓冲会让你完全看不到进度）；重定向到
  日志文件再 `tail`，能直接看到跑到哪个测试。
- `README.md` 工作区是 CRLF（git blob 是 LF，`core.autocrlf` 规范化），
  Edit 单行替换不会破坏；但还是建议改完看一眼 `git diff --stat` 是否只有 1 行。
- 清理一律 `mv` 到项目根 `.trash/<YYYY-MM-DD>/<原相对路径>`，不删。
- `moon fmt` 禁止跑；heredoc 会挂死（写 .py 用 Write 工具）。
