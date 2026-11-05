# AGENT HANDOFF — 2026-11-05 AAC 短窗窗分组（§304）已完成

> 本轮把上一份侦察地图兑现成了代码：LAME 窗分析器移植 + C 黄金向量闭环 +
> 编码器写侧多组化 + 端到端验证，全部收口在一个提交里。
> 接手前先读 `PORTING_HISTORY.md` §304（完整记录）与 `agent.md` ⑮（要点）。
> 上一版的"三个最容易走错的方向"全部被证实并按计划处理（`psy_lame_window`
> 而非 3GPP 死代码；`group_len` 而非解码器派生量；同步改写而非复刻 la 前瞻）。

## 本轮落点（都在 §304 提交里）

- `libavcodec/aac_enc_window.mbt`：`AacLameWindow` 分析器（纯新增）。每通道
  状态 = `prev_energy_subshort[16]` / `prev_attack` / `next_attack0_zero` /
  `next_grouping`；`analyze(buf, 523)` 全链 f32 语义（`aac_two_*` 逐运算舍入，
  FIR 系数与 2.3f/阈值表按精确 f32 十进制转录）。**不含**窗型状态机。
- `libavcodec/aac_win_vectors/`：26 帧 × 2 通道黄金向量（`_ref/aacenc` `--win`
  模式 + `scripts/gen_aac_win_vectors.py` 再生）。首攻块覆盖全表 0..8，
  首跑即绿；外加 ABR 阈值端点选择 8 例。
- `libavcodec/aac_encode.mbt`：`AacEncoder.lame[2]`（`perceptual &&
  perceptual_short` 时每帧跑）；is8 && use_psy 时首攻块（CPE 取较早者）查
  `window_grouping[]` 展开；`AacEncChannel.group_len`；短帧 sf/cb 平铺 128 槽；
  sections/scalefactors/spectral 组主序；sf 差分链跨组连续；
  `write_ics_info` 按 `!group_len[w]` 写 7 位；`adjust` 逐组扫描+归并。
- 基线证明：stash 前后 default/perceptual 流字节级一致（zz 探针，已入
  `.trash/2026-11-05/`）；端到端：4554 B/13 帧分组 ADTS，ffmpeg 9.0.2 解码
  0 errors，PCM 对拍 1.19e-7（≈138.5 dB）、延时 0。

## 裁决与遗留偏差（都写进了 §304）

- **perceptual_short 仍 opt-in**：分组把感知臂 NMR 14.21→13.40（128k）、
  18.69→18.26（64k），改善 0.8/0.4 dB 但没翻过简化臂（9.75/15.62）；
  §303 的 `nmr_on > nmr_off` 断言原样保留。波形 SNR 守卫按数据调至 17.0。
- 文档化偏差：① seq 状态机不换（C 的 `LONG_STOP→attack→EIGHT_SHORT` 与我们
  的 `→LONG_START` 不同），窗型逐位对拍留待将来单独换机；② CPE 分组合并取
  较早首攻，C 的 `common_window=0` 分叉未移植；③ zeroes 跨帧粘性不复刻
  （新鲜数组下归并恒等）；④ `la==NULL` flush 路径不建模；⑤ trellis 层
  （`codebook_trellis_rate`）仍不走（§271 简化的延续）。

## 下一步候选（按价值排序）

1. **短帧三件套多组化**：`mark_pns`/`search_for_pns`、`aac_is_search`、
   `aac_ms_search` 上游都是 `w += group_len[w]` 外层——现在分组真的在码流里了，
   把它们的多窗形态补上才能在短帧开 PNS/IS/M-S（§304 的直接续篇）。
2. **C 决策逐位对拍（窗型）**：需要把 seq 机换成 C 的 `lame_apply_block_type`
   语义 + 前瞻 API（或继续同步改写但复刻状态机转移），向量基建（`--win` 的
   WI 行）已经在手。
3. NMR 差距的进一步分析：感知臂仍差 3.6 dB，可用 §303 尺子逐带定位
   （低频带最重——是否 cutoff/ATH 在短窗下的形状问题）。

## 复现命令

```bash
bash _ref/aacenc/build.sh
(cd _ref/aacenc && ./aac_ref.exe --win 26 > vectors_win.txt)
python scripts/gen_aac_win_vectors.py
moon test --target wasm -p ffmpeg/moonbit/libavcodec/aac_win_vectors
```
