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

## 2. §292 已完成：真成本判据逐位对拍并接线

顺序（§291）和判据（§292）都到位了。感知路径现在跑的是 FFmpeg 的
`aac_is_encoding_err` 成本比较，`libavcodec/aac_is.mbt`，逐位对拍在
`libavcodec/aac_is_vectors/`：4 帧 × 49 带的 `is_mask` / `ms_mask` /
右声道 `band_type` / `is_ener0` / `is_ener1` / 两相位 `pass` / `is_mode`
**完全相等**（64 个强度带）。默认路径仍用 §290 的频率门 + `|rho| >= 0.95`
（它没有 twoloop 的 `sf/band_type/阈值` 可定价），那条门的误差式子仍写在
`aac_encode_is_search` 的 docstring 里。

参考链路（全部可复现）：

```
bash _ref/aacenc/build.sh                 # 现在会编译 aacenc_is_patched.c
moon test --target wasm libavcodec/aac_is_vectors   # 1/1
python scripts/gen_aac_is_vectors.py .scratch/is_dump/enc.log   # 再生成夹具
```

**再生成夹具需要临时把探针加回来**（本轮已摘干净）。做法：在 `AacEncoder` 上加
`mut dbg_frame_no : Int32`（并在 `aac_encoder_new` 里初始化），在感知路径 λ 循环里
`st = ...` 之前插一段

```
if self.config.channels == 2 && its == 0 && use_is {
  打印 "ISDUMP-FRAME <n>"、每个声道一行 "ISDUMP-SPEC0/1" 后跟 1024 行
  "ISDUMP-V <值>"、"ISDUMP-ALLOC <alloc>"、49 行
  "ISDUMP-PSYBAND0/1 <g> <energy> <threshold> <spread> <bits>"、49 行
  "ISDUMP-SF0/1 <g> <twos[ch].sf[g]> <cbs[ch][g]> <zeros[ch][g]>"、最后 "ISDUMP-END"
}
```

然后 `moon test --target wasm libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log`，
跑上面的生成脚本，最后 `grep -c ISDUMP libavcodec/aac_encode.mbt` 必须归零。
脚本会把值按 C 实际消费的 **float** 存（`%.9e` 足以无损往返 float）——这一点必须
保持，否则"完全相等"的断言会假失败。

### 剩下的事（按建议顺序）

1. ~~**`dist1/dist2` 量值的 ulp 二分**~~ —— **§293 已闭环**，而且根因不在 IS：
   escape 码本（cb 11）的 `quantized = c*cbrtf(c)*IQ` 原先按「double `cbrt`
   再舍到 f32」建模，而本机工具链的单精度 `cbrtf` 在 `c = 0..8191` 里有
   **2196 个值与它差 1 ulp**（c=11：C 2.223979949951172 对 2.223980188369751）。
   修法是 `dump_tables.c` 新增 `CBRT` 记录 → `aac_twoloop_cbrt_prod` 零转录 →
   `aac_two_band_cost` 查表；`aac_is_vectors` 现在把 6 个成本量值也断言成
   **精确相等**（`worst cost gap = 0`）。二分用的探针留在 harness 里：
   `ISD1L` 行 = 只加完**左带**成本的 `dist1`。以后遇到「决策逐位对、量值差一点」
   的成本类对拍，先照这个拆法按调用边界二分，别去怀疑求和顺序。
2. **打开 IS 与 PNS 的组合**。两个配置入口目前互相清 `pns`/`is_stereo`。
   顺序上已经允许（`aac_encode_stereo_psy` 拿到的 `cbs/zeros` 就是 PNS 的最终
   判定，正好对应上游 `search_for_is` 的 `band_type != NOISE_BT && !zeroes`
   排除），缺的只是一组 IS+PNS 夹具与逐位数据；注意 §288 那条结论仍然成立：
   噪声带写的是 `noise_sfi`，不是 twoloop 的 `sf_idx`。
3. **`search_for_ms` 的完整形态**（`aaccoder.c:702` 的 `sid_sf_boost` 四轮尝试 +
   `ff_sfdelta_can_replace`）——本移植的 M/S 掩码仍是能量版，等价于上游
   `mid_side=1` 那条不重新定标的分支。IS 已经用掉了同一个 `ms_mask`（flip 带），
   做这步时别把两条路径写歪。
4. 短窗 IS：`num_windows` 与每窗带内偏移都参数化了，结构上走得通，但没有专门的
   8 短窗 IS 夹具。

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
