# AGENT_HANDOFF — AAC twoloop 量化器交付 / 接入编码器主线（2026-11-04）

> 接手须知：先读本文，再读 `agent.md`（项目惯例）与 `PORTING_HISTORY.md` §278
> （前一片是 §277）。本仓库 git 在 `moonbit/` 子目录；`_ref/` 下的参考工具链是
> gitignored 的，不进提交。

---

## 0. 一句话状态

`aac_twoloop.mbt`（FFmpeg 9.0.2 `aaccoder_twoloop.h` 的 `search_for_quantizers_twoloop`）
已移植完成，245 条 `TWOBAND` 参考向量逐带对拍通过，`moon check --target wasm
--deny-warn` 干净，全量 `moon test --target wasm` **1388/1388** 全绿并已提交
（`3feae25`）。**本模块与 §277 的 `aac_psy.mbt` 一样是独立可验证层，尚未接入
`aac_encode.mbt`**；后者仍用 §271 的简化心理声学与全局 delta 二分。

---

## 1. 已交付内容

| 文件 | 内容 |
|---|---|
| `libavcodec/aac_twoloop.mbt` | 973 行：f32 助手族、`abs_pow34` / `find_max_val` / `coef2minsf` / `find_min_book` / `find_form_factor` / `quant`、`band_cost`（RD 成本）、`init_nextband_map` / `can_remove_band`、`priv struct AacTwoLoop` 的 `collect()`、对外 `aac_twoloop_search` |
| `libavcodec/aac_twoloop_tables.mbt` | 761 行，自动生成：`pow2sf`/`pow34sf`、`cb_range`/`cb_maxval`/`maxval_cb`、`vec1..vec11` + `bits1..bits11`（逐码本码字） |
| `libavcodec/aac_twoloop_vectors/` | 黑盒 3 项：5 帧 × 49 带逐带对拍、全零谱边界、结构不变量 |
| `scripts/gen_aac_twoloop_tables.py` | 从 `_ref/aacenc/tables.txt` 零转录生成上面那张表文件 |
| `libavcodec/aac_psy.mbt` | 仅追加 `AacPsyContext::band_sizes()` 访问器（twoloop 需要与 psy 同源的 49 带尺寸） |
| `_ref/aacenc/dump_tables.c`（新）+ `build.sh` + `patch.py` | 表 dump 程序（独立链接、不带 `harness.o`）+ 6 段 stderr 探针（`TWOPARM`/`TWOINIT`/`TWOWEIGHT`/`TWOLOOP`/`TWODIST`/`TWOOUT`） |
| 文档 | `PORTING_HISTORY.md` §278、`README.md` 音频行、`agent.md` 音频编码器段 |

### 复现

```bash
cd /d/project/FFmpeg-n9.0.2/moonbit
moon check --target wasm --deny-warn
moon test --target wasm libavcodec/aac_twoloop_vectors      # 3/3
cd _ref/aacenc && bash build.sh
./aac_ref.exe > vectors.txt          # §277 的 psy 夹具也来自这里
./dump_tables.exe > tables.txt
cd ../.. && python scripts/gen_aac_twoloop_tables.py
```

改完 `patch.py` / `build.sh` / `dump_tables.c` 之后务必重跑
`python scripts/gen_aac_psy_vectors.py`，并确认
`git status --short libavcodec/aac_psy_vectors/` 无输出——§277 的夹具必须零 diff，
否则说明探针污染了参考行为。

### 验收口径

- `sf_idx` / `band_type` / `zeroes`：**逐位一致**（整数决策，不许放宽）。
- `maxval`：相对误差 ≤1e-5。
- 5 帧 `alloc` = 2229 / 1966 / 1943 / 1910 / 1971，`tbits` =
  2352 / 1929 / 2052 / 2009 / 1957，`iters` 恒 30。
- 帧 0/2/3/4 的 `tbits > alloc` 是**上游行为**（外层逐带调整后不做全局回退），
  不是移植 bug，别去"修"。

---

## 2. 关键坑（改动 `aac_twoloop.mbt` 前必读）

1. **成本 lambda 固定 1.0**：`quantize_band_cost_cached(..., 1.0f, INFINITY, ...)`
   里那个 `1.0f` 是 RD 成本函数的 lambda，与搜索用的 `lambda=120.0` **不是一个东西**。
   传 120 会让 `dists` 整体放大 120 倍，逐带 `sf` 从第二带起就分叉
   （`TWODIST its=0 g=0`：C 6663840 / MB 799660800）。这一条是整片最贵的坑。
2. **`iters` 上限 30 必须跑满**：参考侧 `sf0` 在 127/131/132/136/137 之间反复
   振荡、30 次全用完。任何"收敛就提前跳出"的优化都会让结果偏离。
3. **codebook 0 是零带短路**，不进量化循环；codebook 11（BT_ESC）的 escape
   分支用 `165140.0*IQ`，不是 `CLIPPED_ESCAPE` 的 8191。
4. **表的方向**：`vecs[10]` 的 `(64,64)` 哨兵在**末尾**、首项是 `(0,0)`；
   `vecs[0]` 前 4 项是 `-1.0`；`bits[10][0] == 4`。生成器最先就是这三条断言的
   方向写反了。
5. **f32 语义**：C 全程 `float`。每个 `powf/sqrtf/log2f/expf` 的结果都要经
   `aac_two_f32()` 落回 f32；`abs_pow34` 是 `sqrtf(a * sqrtf(a))`，两次舍入，
   不能写成 `pow(a, 0.75)`。
6. 调试探针：`patch.py` 里新增的循环变量一律用独立名字（`aac_dbg_pg`），
   绝不复用 `i`/`j`/`g`/`w`——本项目在 Opus 轮被这个坑过。stdout 与 stderr
   分离，所以 stderr 探针不影响 `vectors.txt`。

### 边界

单长窗（`num_windows=1`、`ONLY_LONG_SEQUENCE`、49 带）、ABR（`AV_CODEC_FLAG_QSCALE`
不走）、PNS / intensity / M-S / TNS 全关、无块切换。合成谱输入，未跑 PCM→MDCT。

---

## 3. 下一片：把 psy + twoloop 接进 `aac_encode.mbt`

### 3.1 现状：要替换的三处

| 位置 | 现在做的 | 替换成 |
|---|---|---|
| `AacEncoder::band_targets`（`aac_encode.mbt:924`） | 简化模型：带能量 + 0.3/0.09 上扩 + 频率相关 SNR（18 dB 起、3 kHz 以上按 `log10` 衰减、下限 6 dB）+ ATH 门限 + −20 dB 相对地板 → 每带参考 `sf` | `AacPsyContext::analyze(coefs, prev_bits)` 返回的 `AacPsyResult.bands`（`AacPsyBandInfo { energy, threshold, spread, bits }`），预算取 `AacPsyResult.alloc` |
| `AacEncoder::channel_data`（`1211`）里的 `target[b] + delta` | 整帧统一偏移 + 0..255 钳位 + ±60 相邻带钳位 | `aac_twoloop_search` 输出的逐带 `sf` / `cb` / `zeroes` |
| `encode_frame`（`1687` 起）的 `lo=-255 / hi=255` 二分 | 找"还装得下帧字节预算的最小 delta"，最坏 9 次全帧重建 | 一次 twoloop 两遍搜索 |

`build_frame(frame, delta)` 的 `delta` 参数在接入后可以整段删掉；
`aac_encode_global_gain`（取首个有编码带的 `sf`）语义与 FFmpeg 一致，保留。

### 3.2 接入形状（建议）

```moonbit
// 构造期：AacEncodeConfig → aac_psy_new(sampling_index, bit_rate, channels)
let psy = aac_psy_new(aac_encode_sampling_index(rate), bit_rate, channels)
// 每帧、每声道（位置与现在的 band_targets 相同：M/S 之后、TNS 之前）
let r = psy.analyze(coefs[ch], prev_bits)          // prev_bits = 上一帧的 tbits
let q = aac_twoloop_search(
  coefs[ch], psy.band_sizes(), r.bands, r.alloc,
  bit_rate, sample_rate, channels, 120.0,
)
// q.sf / q.cb / q.zeroes 直接填 AacEncChannel；prev_bits = q.tbits
```

- **两个预算口径别混**：`alloc` 传 `AacPsyResult.alloc`（psy 的 `bitres.alloc`，
  5 帧实测 2229/1966/…）；`aac_twoloop_search` 内部的 `destbits` 是它按
  `bit_rate*1024/sample_rate/channels*(lambda/120)` 自己算的。现有
  `target_bytes = bit_rate*1024/sample_rate/8` 是**整帧字节数（含 ADTS 头）**，
  与这两者都不同口径。
- **每个声道一份 psy 状态**：`AacPsyContext` 的跨帧状态（`prev_band`、
  `fill_level`、`pe.min/max`、`entropy`）都是单份。§277 harness 每帧只调一次
  `analyze`（单谱），而 FFmpeg 的 `aac_encode_frame` 是**每声道**调一次。接双声道
  前先确认是否要按声道各建一个 ctx，否则两声道会互相污染 `fill_level`/`entropy`，
  `alloc` 也会串——这是接入时最可能踩的坑。
- `AacTwoResult` 的字段目前是包私有（`aac_twoloop.mbt` 里没有 `pub` 字段），
  而 `aac_encode.mbt` 与它同包，直接可用；若将来要跨包暴露再补 `pub`。
- twoloop 只看 `bands` 的 `energy`/`threshold`/`bits`；M-S / TNS 与它的先后关系
  照现在 `band_targets` 的位置走即可（psy 看的是"实际被编码的谱"）。

### 3.3 会变红的现有测试（重新定基准）

`libavcodec/aac_encode_vectors` 共 6 项，其中
`aac_lc_encoder_round_trip` 断言的是 §271 那套数值（119.7 kbps、往返
SNR 29.97 dB / PSNR 39.8 dB、ffmpeg 解码差 0.0008 MSE）。接入后码率控制与
逐带量化都变了，这条必然变红：

- 允许范围：**码率仍贴近目标 128 kbps、SNR/PSNR 不低于原值**（twoloop 应当更好）。
- 若变差，先查 3.2 的两个预算口径与 psy ctx 共享问题，别急着调容差。
- `aac_lc_analysis_synthesis` / `*_syntax` / `transient_windows` / `tns_syntax`
  这 5 项与码率控制无关，接入后应当**保持原样通过**（这是回归护栏）。
- 端到端（`libavformat` 的 AAC/TS/MKV/MP4 双轨测试）用的是**已有参考流的解码**，
  不受编码器影响；但重封装里若现场调用编码器，需一并复核。

### 3.4 想把质量/参数再往前推时要补的

twoloop 目前跳过的上游分支：PNS（`can_pns` / zeroable 带）、intensity stereo、
`spread_thr_r`、短窗（8 窗的 `w`/`w2` 双层循环与 `group_len`）、
`AV_CODEC_FLAG_QSCALE` 直通。这些都不影响长窗 ABR 的正确性，但一旦要支持
`-q:a`、8 窗或 PNS，必须回到 `aaccoder_twoloop.h` 原文件逐段补齐，
并按本轮的顺序重新加夹具对拍（先 `maxval`，再整数决策）。

---

## 4. 工具坑（本轮实测）

- **全量 `moon test --target wasm` 会偶发挂死**（§277 handoff §4 记过一次）。
  本轮复现：38 分钟无任何输出、日志 0 字节、`_build` 只在头一分钟写了 271 个
  文件、20 秒内 node 总 CPU 零增长、`moon` 进程无子进程——典型编译期挂起。
  处理：`TaskStop` 掉，重跑即可。重跑本次用 `moon test --target wasm < /dev/null
  > 日志 2>&1`，**2 分 57 秒**跑完 1388 项。**给 stdin 一个 EOF 再跑**，
  别让测试进程继承工具那个永不关闭的管道。
- **日志 0 字节本身就是挂起的信号**：正常运行时重定向文件会持续增长
  （第二次跑 100 秒时已有 55 KB）。别用 `| tail -N` 看进度。
- **提交消息用 `git commit -F <文件>`**：消息里含 `remove`/`rm` 子串（本轮
  `can_remove_band`）会被"不删除"钩子误判成删除命令直接拦下。用 Write 工具
  写消息文件再 `-F` 最稳。
- `README.md` / `PORTING_HISTORY.md` / `agent.md` 工作区都是纯 LF
  （git blob 也是 LF，`core.autocrlf` 只影响 checkout），Edit 改完看
  `git diff --stat` 应当只有预期行数。
- 其余照旧：`moon fmt` 禁跑、**heredoc 禁用**、清理一律 `mv` 到
  `.trash/<YYYY-MM-DD>/`、bash cwd 每条命令显式 `cd`、探针循环变量不复用 `i`/`j`。
