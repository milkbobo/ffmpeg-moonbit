# AGENT HANDOFF — 2026-11-05 AAC 强度立体声（§290）

本轮把 `aacenc_is.c` 的强度立体声接进了 `aac_encode.mbt`，码流侧由 ffmpeg 9.0.2
外部解码验证通过；紧接着的 §291 已经把感知路径的顺序改成与 FFmpeg 同序，
所以下一步的大件只剩**用真成本判据替换简化判据**。以下把"已经落地的"和
"下一次要怎么做的"分清楚。

## 1. 本轮交付了什么

- 配置：`AacEncodeConfig.is_stereo`（默认 false）+
  `aac_encode_config_with_is(config)`。它与 `pns` 互斥（两侧配置函数互相清
  对方），与 `perceptual` 无依赖——简化判据只需要带能量，所以默认路径也吃这个
  开关。
- 决策：`aac_encode_is_search`（`libavcodec/aac_encode.mbt:994`）——
  FFmpeg 频率门 + 带内互相关 `|rho| >= 0.95` + 相位取互相关符号 +
  强度位置 `round(2*log2(ener0/ener1))`，先裁到 `[-155,100]` 再裁到相对上一条
  IS 位置的 `±60`。
- 变换：`aac_encode_apply_is`，与 `apply_intensity_stereo` 逐式一致
  （`L' = (L + p·R) · sqrt(ener0/ener01)`，`R' = 0`）。
- 码流：`aac_encode_write_scalefactors` 的第三条独立差分链 `off_is`（起点 0），
  `aac_encode_write_spectral` 与 `aac_encode_band_has_data` 跳过 14/15，
  `aac_encode_global_gain` 跳过 14/15（也跳过噪声带）。
- 测试：`aac_encode_vectors` 14/14，其中三条是本轮新增
  （`aac_lc_is_config` / `aac_lc_intensity_stereo_round_trip` /
  `aac_lc_intensity_stereo_skips_uncorrelated`）。全量 1399/1399。

实测数字（44.1 kHz / 128 kbps / 2ch，感知路径，4 帧 + 1 收尾帧；§291 换了顺序之后
重测）：

| 夹具 | IS 带 | 码长 | R 的 9 kHz 电平 | 往返 SNR |
|---|---|---|---|---|
| 高音共享（L 440 + R 550 低音不同） | 10 | 1744 → 1711 B | −0.03 dB | 22.92 → 22.35 dB |
| 高音不共享（L 9 kHz / R 11.7 kHz） | 0 | 1773 = 1773 B | — | — |

（§290 当时的数是 1831 → 1802 B、+0.38 dB、18.60 → 18.54 dB；顺序改成与
FFmpeg 同序后 SNR 涨了 4 dB 多、音调重建电平几乎无偏。）

外部对拍：同一条 8 帧 IS 流（3102 字节），`linuxserver/ffmpeg:9.0.2` 报
`9 frames decoded; 0 decode errors`；ffmpeg 的 PCM 与本解码器的 PCM
最大差 `1.49e-7`、RMS `2.43e-8`、相对 SNR `138.92 dB`。

## 2. 下一步：真成本判据（前置的顺序重构已在 §291 完成）

FFmpeg 的顺序是
`psy → mark_pns → search_for_quantizers(twoloop) → common_window → TNS →
search_for_pns → search_for_is → apply_intensity_stereo →
search_for_ms → apply_mid_side_stereo → adjust_frame_information → 写`。

也就是说 IS 是在**左右声道各自的谱已经被 twoloop 定过 sf/band_type/zeroes**
之后才跑的，`aac_is_encoding_err`（`libavcodec/aacenc_is.c:45`）才能给三样东西
分别定价：L 带、R 带、以及 IS 和带，代价式是
`quantize_band_cost(s, in, scaled, size, sf_idx, band_type, s->lambda /
threshold, INFINITY, NULL, NULL)`，两个相位各跑一次取 `dist2 <= dist1` 的那个。

**§291 已经把顺序改完了**：感知路径现在是
`psy → TNS →（每轮 λ：twoloop → PNS → 强度 → M/S → 量化 → 写）`，分析读左右谱、
量化读混合后的谱，与 `aacenc.c` 同序；简化路径保持先混合（它的每带标度因子
来自真正要编码的那份谱，§279/§280 的 29.045 dB 基线逐字节不变）。顺带补上了
`apply_mid_side_stereo` 对噪声带的排除。指标全线改善：感知 SNR 20.14 → 21.31 dB、
IS 夹具 18.60 → 22.92 dB、音调重建电平 +0.38 → −0.03 dB。所以真成本判据的
前置条件已经满足，下面按顺序做：

1. **给 `_ref/aacenc` 加 IS harness**：把 `aacenc_is.c` 编进
   `libavcodec_ref.a`（依赖 `find_max_val`/`find_min_book`/
   `quantize_band_cost`/`pos_pow34`/`ff_init_nextband_map`/
   `ff_sfdelta_can_remove_band`——这些在本移植里都已经有对应实现，见
   `aac_twoloop.mbt` 与 `aac_pns_search.mbt`，所以 C 侧也不缺）；
   参考侧输出每条带的 `is_mask / ms_mask / ch[1].band_type / is_ener`，
   照 §284/§286/§287 的做法做逐位向量。
   注意 `--in <dump>` 那条外部谱通道（`aac_pns_vectors` 已经用过），
   可以直接复用 §278 的 245 带夹具。
2. 用 `aac_is_encoding_err` 替掉 `aac_encode_is_search` 里的频率门 +
   `|rho| >= 0.95`（误差式子与推导留在它的 docstring 里，别丢）。
3. 打开 IS 与 PNS 的组合：两个配置入口目前互相清对方；顺序已经允许像上游那样
   靠 `band_type != NOISE_BT && !zeroes` 排除噪声带，改完要补一组 IS+PNS 夹具。
4. `search_for_ms` 的完整形态（`aaccoder.c:702` 的 `sid_sf_boost` 四轮尝试 +
   `ff_sfdelta_can_replace`）——本移植的 M/S 掩码仍是能量版，等价于上游
   `mid_side=1` 那条不重新定标的分支。

另外两条小的：短窗 IS 结构上已经支持（`num_windows` 与每窗带内偏移都参数化了），
但没有专门的 8 短窗夹具；`set_special_band_scalefactors` 上游是一轮里同时管
IS 位置和噪声 `3+ceil(log2(pns_ener)*2)`，我们的噪声仍取 `search_for_pns` 的
`noise_sfi`（§288 的结论，别说改回去）。

## 3. 本轮踩到的坑（下一轮直接用）

- **`sf[b] >= 0` 这个哨兵只对真标度因子成立**。IS 位置可以为负，写侧必须先按
  `cb` 判 14/15；`aac_encode_global_gain` 同理。
- **让 ffmpeg 解我们的码流**这条验证路径值得保留，做法（本轮实测可用）：
  1. 建一个临时 main 包（`import` 写在 `moon.pkg`，源码里再写一遍会报
     `[3001] Invalid import declaration`）；
  2. `moon run <dir>`，**目录不能以 `.` 开头**（moon 跳过点目录，
     `.scratch/xxx` 会报 "does not match any known package"），本轮用的是
     根下的 `zz_is_dump/`，用完移进 `.trash/2026-11-05/`；
  3. `moon run` 走 wasm 目标（这台 Windows 的 native 目标要求 MSVC `cl.exe`，
     本机没有），所以不能写文件——把 ADTS 用 `println("BYTES \{...}")` 打出来
     （`Byte::to_string()` 打的是 `b'\xFF'`，Python `ast.literal_eval`
     直接还原），PCM 一行一个样本；
  4. Python 落成 `out.adts` 后
     `docker run --rm -e MSYS_NO_PATHCONV=1 --entrypoint ffmpeg
     linuxserver/ffmpeg:9.0.2 -v debug -i out.adts -c:a pcm_f32le -f f32le
     ref.f32`，再和本解码器的 PCM 比。
- **IS 的相位/带类型别记反**：`INTENSITY_BT2 = 14` 是**反相**，
  `INTENSITY_BT = 15` 是**同相**（`libavcodec/aac.h:74`）；编解码两侧的
  `p = -1 + 2*(bt - 14)` 必须同式。
- MoonBit 不把 `a = x` 换行 `+ y` 当续行（多行算术要拆 `let` 或加括号）。
- 其余照旧：`moon fmt` 禁跑、heredoc 禁用、清理走 `.trash/<日期>/`、
  每条 bash 显式 `cd`、`libavcodec` 包**不要再加白盒测试**（wasm init 的
  local count 已接近上限，§288 记过），提交消息含 `remove`/`rm` 子串会被钩子
  拦，用 `git commit -F <file>`。
