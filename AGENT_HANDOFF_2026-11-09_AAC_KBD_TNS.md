# AGENT_HANDOFF_2026-11-09 — AAC KBD 窗 + bandwidth 写回 + TNS f32（§371，未提交）

> 接续 `AGENT_HANDOFF_2026-11-09_AAC_MDCT.md`（§370：av_tx f32 MDCT 移植，帧 2 分叉待查）。
> 本片在 §370 工作树之上继续，**两片都未提交**，工作树含临时探针。
> 用户约束：必须使用 moonbit-c-binding / make-moonbit-c-bindings 技能（ffref C 绑定 oracle 是常驻基础设施）。

## 一、结论速览

| 项 | 状态 |
|---|---|
| §370 帧 2 分叉根因 | **已修**：C 的 ONLY_LONG/LONG_STOP 帧用 **KBD 窗**（`window_shape=1`），port 只有正弦窗 |
| ffref 立体声 13 帧 | **与 C 逐字节恒等**（13/13 帧 bits+λ 全等，测试已升级为逐字节断言） |
| ffref 单声道 | **逐字节恒等**（测试已升级） |
| 新增 TNS 开启（stock 默认 `aac_tns=1`）差分 | 24k ✅ 64k ✅ **128k ❌（包 1 差 1 bit）** |
| 第二根因 bandwidth 写回 | **已修**（让 24k/64k 通过） |
| wasm 全量 | 仅在 KBD 改动后跑过：**1711/1713**（2 个 TNS 属性测试红，见 §四.3）；之后的 bandwidth/TNS 改动**未再跑 wasm** |

## 二、已完成改动（工作树）

### 1. 根因 #1：窗形状 KBD（`aacpsy.c:1000-1016` + `aacenc.c:383-436/857-860/473`）
- **枚举坑（我踩了半小时）**：AAC `WindowSequence` = 0 ONLY_LONG、**1 LONG_START、2 EIGHT_SHORT**、3 LONG_STOP。
  按正确映射，C 序列 = LONG_START → EIGHT_SHORT → LONG_STOP → ONLY_LONG…，与 port 一致；
  差在 shape：`psy_lame_window` 对 ONLY_LONG/LONG_STOP 设 shape=1（KBD），LONG_START/EIGHT_SHORT 设 0。
- C 选窗是**不对称**的（照抄，含怪癖）：ONLY_LONG 升=kb[0]、降=kb[1]；LONG_START 长升=kb[1]、短降=kb[0]；
  LONG_STOP 短升=kb[1]、长降=kb[0]；EIGHT_SHORT 窗 0 升=kb[0]、窗 1..7 升=kb[1]、降一律 kb[0]。ics_info 写 kb[0]。
- 改动：
  - `libavcodec/aac_mdct_tx/`：`moon.pkg` 加 libavutil；`aac_mdct_tx.mbt` 加 `kbd1024/kbd128`（`aac_mdct_tx_kbd` = `kbd_window_init` 双精度 + f32 存储）
    与 `kbd_long/kbd_short/long_window(shape)/short_window(shape)`；`aac_mdct_tx_ref_checks.mbt` 由 dumper 重生成（**末尾新增 2 对**，c[38..41]，原 19 对不变）；
    `aac_mdct_tx_wbtest.mbt` 新测试「KBD windows match」——**首跑位级一致 4/4**（含 `av_bessel_i0` exp 分支）。
  - `scripts/aac_mdct_tx_dump.c`：extern `ff_aac_kbd_long_1024/ff_aac_kbd_short_128/ff_aac_float_common_init` + 两条 `emit_check`。
  - `libavcodec/aac_enc_window.mbt`：`aac_lame_window_shape(type)`。
  - `libavcodec/aac_encode.mbt`：`AacEncoder.use_kb`（逐通道上一帧 shape）；`encode_pipeline(bufs, sequences, shapes, lame_grp)`；
    `frame_coefficients(buf, seq, shape, prev_shape)`；`aac_encode_window` 6 参；`AacEncChannel.window_shape`、`AacEncPlan.shape`；
    common_window 比较 shape；ics_info 写 shape；flush A/B 带 shape；**顺修 flush 的 prev_type 用 `prev_sequence[ch]`（原误用 [0]）**。
    简化路径恒 shape 0（正弦），基线不变。`spectrum()` 测试尺仍为正弦。
- 验证：run371a 13 帧 frame_bits + λ 两侧全等；run371b AAC 3/3。

### 2. 根因 #2：twoloop bandwidth 未写回 psy.cutoff（`aaccoder_twoloop.h:197`）
- C：`bandwidth = FFMAX(3000, AAC_CUTOFF_FROM_BITRATE(frame_bit_rate,1,rate)); s->psy.cutoff = bandwidth;`，此后 psy 分析都用它划带。
- 改动：`AacTwoResult.bandwidth`（`aac_twoloop.mbt`，两处构造）；`encode_pipeline` 在每次搜索后 `self.psy.set_cutoff(two.bandwidth)`。
- 暴露方式：24k 八短窗帧 psy `desired_bits` C 384 vs port 367（C alloc≈192 → dest=183，port dest=174）。修后 24k/64k 逐字节一致。

### 3. TNS f32 对齐（部分）
- `aac_encode_tns_lpc`：`compute_lpc_coefs`（float `LPC_TYPE`，`lpc_functions.h`）镜像递推逐步 f32。
- `aac_encode_apply_tns`：`coeffs[start] += lpc[i-1]*pcoeffs[...]` 乘、加各 f32。
- `search_tns` 新可选参 `psy_bands?`：感知路径按 C 用 `psy_bands[w*16+g].energy`、f32 累加、循环界 `g < num_swb && g <= sfb_end`；
  简化路径（None）保持原系数能量逻辑逐位不变。调用点：rate-control 循环内传 `psy_bands=r.bands`。
- **未做**：`quant_array_idx` 的 float 比较（C 先把 double coef 转 float，误差平方 float）；增益门限 float 常量
  （`TNS_GAIN_THRESHOLD_LOW 1.4f`、`HIGH 1.16f*1.4f`，port 仍是 double 1.4/1.4*1.16）。

### 4. ffref 测试（`ffref/ffref_encode_ref_test.mbt`，**CRLF 文件**）
- 新 `ffref_aac_strip_adts`；立体声、单声道 AAC 测试改 `ffref_expect_ref_packets(去 ADTS 头的 ours, native)`——逐字节。
- 新夹具 `ffref_enc_pcm_tonal`（= wasm 测试 `aac_encode_test_shared_high(shared=true)` 公式 + s16 量化）与新测试
  「ffref: AAC perceptual encoder with TNS on matches the oracle byte-for-byte」（24k/64k/128k，`aac_pns=0:aac_tns=1:aac_ms=0:aac_is=0`）。
- 背景：port 感知路径**没有 TNS 开关**（恒开 = stock 默认），旧差分钉 `aac_tns=0` 只因 440 Hz 纯音不触发 TNS 才一致。

## 三、当前未解：128k TNS-on 包 1（八短窗）差 1 bit

- 现象：port 3382 vs C 3381 bits（包 424 vs 423 B，首差字节 6）。
- **已证相同**：psy desired/alloc、TWOPARM（dest 948/cutoff 92/rdλ）、gg、max_sfb=12、分组（walk w∈{0,1,4,7}，group_len 1/3/3/1）、
  **twoloop 终态 sf/cb/zeroes 112 行全同**、TNS（n_filt=[1,0,0,1,1,0,0,1]，len 11/ord 7/dir 1/系数逐个相同）。
- **不同**：trellis 选出的码本/分段（SPECP vs SPECC 同 sf）：ch0 组 w1 带 6,7,9,10,11、组 w4 带 6,9,10,11（port cb3/1 vs C cb2/3），ch1 组 w1 带 6,7…；
  频谱位合计 port 2239 vs C 2256（分段位反向补偿到总差 1）。组 w0、w7 也含 TNS 窗但一致。
- **头号嫌疑（下一步先查源码）**：C 的 trellis 读到「TNS 前」的数据：
  1. `aaccoder.c` `codebook_trellis_rate` 调 `quantize_band_cost_cached(s, w+win, swb, coeffs, s->scoefs, ...)`——
     **band cost cache**（`aacenc_quantization_misc.h`，键 = (w,g,scale_idx,cb,rtz)，仅 twoloop 开头 `ff_quantize_band_cost_cache_init` 换代）
     会把 twoloop 在**未滤波谱**上算过的 (sf,cb) 成本原样返回；port trellis 现在是在滤波后谱上新算。
  2. `s->scoefs`（pow34）若 trellis 不重算，则是**最后一次 twoloop 调用（CPE 下是 ch1）**的未滤波值。
  → 查清 C 实际语义后让 port trellis 复现（cache 命中用 twoloop 时的成本 / stale scoefs），再跑 128k。
- 复跑命令（单测过滤可用，`-F` 在本版 moon 生效）：
  ```
  MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
    ffmpeg-moonbit-ffref:nine-dbg -c "/root/.moon/bin/moon update >/dev/null 2>&1; \
    /root/.moon/bin/moon test --target native -p ffref --target-dir /tmp/mbuild -F 'ffref: AAC*'" > .scratch/ffref/runXXX.log 2>&1
  ```
  配对：port 探针在 stdout、C 在 stderr；C 的 static 计数器（f=/k=）**跨码率累计**，按 RCDBG/FRAMEP 边界切段（run371i 中 128k 帧 1：
  port 自 `PSYDBGP ch=0 desired_bits=1960` 起至下一个 FRAMEP；C 自上一条 RCDBG(3347) 至 `RCDBG frame_bits=3381`）。

## 四、下一步（按序）

1. 解 §三（trellis 读 TNS 前数据的 C 语义），128k 逐字节 → TNS-on 差分三码率全绿。
2. 补完 TNS float 细节：`quant_array_idx` float、增益门限 float 常量；复跑全部 AAC 差分。
3. 重钉两个 wasm TNS 属性测试（`aac_encode_vectors_test.mbt`：`aac_lc_perceptual_path_emits_tns`、
   `aac_lc_perceptual_max_sfb_and_tns_carryover`）：KBD 后该 double 夹具 64k/128k 不再出 TNS（frames=0/8、tns_later=0）。
   做法：夹具改成与 `ffref_enc_pcm_tonal` 相同的 s16 量化版（oracle 已认证），断言按 port（=stock）实际行为。
4. 收尾清理（`grep -rn "§370 probe\|§371 probe"` 复核）：
   - `aac_encode.mbt`：FRAMEP、CHWRITEP、TWOSEARCHP、PLANGRP（pipeline 里无标记的 println）、SPECP（`aac_encode_write_spectral` 内含 `dbg_bits0`）；
   - `aac_twoloop.mbt`：TWOPARMP、TWOINITP、TWOEXITP；`aac_psy.mbt`：PSYDBGP；
   - `ffref_encode_ref_test.mbt`：TNS 测试里的 PKT1 dump 块；
   - `ffref/moon.pkg`：`libavcodec_dbg.a` → 还原 `libavcodec_ref.a`；
   - `aac_mdct_tx` 的 unused 警告（`aac_mdct_tx_checksum/_i`、`aac_mdct_tx_ref_input`、`aac_mdct_tx_ref_checks` 只被 wbtest 用 → 移进 wbtest 或改结构），交付要求 0 警告；
   - `moon fmt`、`moon info`（mbti 变化：AacMdctTx 新 pub 方法、AacTwoResult.bandwidth）。
5. 全量验证：wasm 全量；nine-ref oracle 全量（`ffmpeg-moonbit-ffref:nine-ref`，原 72 + 新测试）；§368 质量门（NMR/SNR，窗变 KBD 后需重测）。
6. 文档与提交：PORTING_HISTORY 补 §370、§371 条目；agent.md；记忆 + MEMORY.md；精确路径 add，中文 `feat:`，尾行 `Co-Authored-By: ZCode <zcode@zcode.ai>`。

## 五、本片新坑

1. **AAC 枚举值**：EIGHT_SHORT=2、LONG_START=1（别凭印象，看 `aac.h`）。
2. `ffref/ffref_encode_ref_test.mbt` 是 **CRLF**：python 补丁须 `\r\n`；Edit 工具慎用（混行尾）。
3. `libavcodec/aac_mdct.mbt` 已提交内容里含**字面 NUL 字节**（`b'\x00'` 写成了真 NUL）→ Read 工具报二进制、grep 静默，用 `sed`/`grep -a`。
4. `aac_decode_ics_with_info` 不消费频谱数据 → 只能解析 CPE 的 ch0（解 ch1 会 panic）。
5. `BitWriter` 无 bit_count：用 `bw.buf.length() * 8 + bw.nbits`。
6. 包级 `moon check -p ffref` 在 wasm 报「不支持后端」属正常（native-only 包），检查要进 docker 跑。

## 六、产物位置

- 日志：`.scratch/ffref/run371a..i.log`（a=KBD 后立体声 13 帧全等；e=bandwidth 修后 3/4；h=TNS f32 后；i=SPECP 配对）、`wasm371a.log`（KBD 后 wasm 1711/1713）。
- dumper 输出：`.scratch/ffref/ref_checks_371.mbt`（已复制进子包）。
