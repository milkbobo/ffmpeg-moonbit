# AGENT HANDOFF — 2026-11-05 AAC 短窗感知路径（§302）

> 【2026-11-05 更新】§5 第 1 项已由 **§303** 闭环：短窗 NMR 夹具落地
> （`aac_encode_test_nmr_short`），实测两码率、八个窗全线劣化 → **保持 opt-in
> 不转正**（README 已写死结论）。后续编号顺移：窗分组 = **§304**、多窗
> 工具 = **§305**。§4 增补一条坑：`assert_eq`/`assert_true` 用在非 test
> 函数里必须给该函数签名加 `raise`（错误码 [4122]）。

接上一轮留下的半成品：`libavcodec/aac_encode.mbt` 里 `use_psy` 的短窗门已经拆掉、
`channel_data_psy` 已按窗量化，但没有提交、没有回归、外部解码也没验，工作树里还
躺着一个探针测试和一个 `zz_short_ab/` main 包。本轮把这条线收尾：**验证 → 加开关 →
补回归 → 外部对拍 → 文档 → 提交**。

## 1. 结论：接线是对的，但默认不开

- §300（psy 八短窗）与 §301（twoloop 按窗分组）都是地基，编码器门
  `use_psy = perceptual && seq != aac_eight_short` 一直没动。本轮真正把短窗帧交给了
  这条链：`planned_max_sfb` 按 `w*16+g` 槽位扫、`band_sizes_short()` / 短窗 offsets /
  `AacTwoShape = short([8,0,...])` 喂进 psy→twoloop→TNS，`channel_data_psy` 按
  `w*128+offsets[b]` 逐窗量化（每窗自己的系数、组内共享 `(sf,cb)`），写侧复用
  简化路径已有的 `num_windows=8` 与 `scale_factor_grouping=0x7f`。
- **但改成 opt-in**：新增 `AacEncodeConfig.perceptual_short`（默认 false）与
  `aac_encode_config_with_perceptual_short(config)`；
  `use_psy = perceptual && (!is8 || perceptual_short)`。开关关闭时与 §301 的门逻辑
  等价。理由不是"没验完"，是数据：一组八窗共享一个标度因子，而瞬态夹具的相邻窗
  能量差一个数量级，波形 SNR 掉 6~10 dB，同时短窗的噪声-掩蔽比**还没有尺子量**
  （`aac_encode_test_nmr` 是长窗 spectrum）。按 PNS / IS 的先例保住基线，§303 用
  短窗 NMR 再决定要不要转正。
- 短窗上三件仍是单窗移植的工具显式关闭：`use_pns = pns && !is8`、
  `use_stereo_psy = channels == 2 && !is8`。**唯一例外**：`aac_twoloop_pns` 的
  `on` 仍传 `config.pns`，因为 C 的带宽补偿读
  `options.pns || options.intensity_stereo`，与窗形状无关（§296 已记）。

## 2. 实测数据

| 项 | 开关关（§301 行为） | 开关开（§302） |
|---|---|---|
| `aac_lc_perceptual_transient` 6 帧 SNR | 30.08 dB（§282 时 31.84） | 25.21 dB |
| 瞬态 8 帧 mono 128 kbps | — | 23.31 dB / 3042 B |
| 瞬态 8 帧 mono 64 kbps | 12.35 dB / 1603 B | 9.44 dB / 1687 B |
| 瞬态 8 帧 stereo 128 kbps | — | 10.83 dB |
| 稳态 stereo 9 帧基线 | 8 个长窗帧 + 1 个短窗帧 | **8 个长窗帧逐字节不变**，短窗帧变 |
| 三条端到端流 | 3166 / 2980 / 727 B | 同左（默认关） |

外部 `linuxserver/ffmpeg:9.0.2` 解码两条**开了开关**的 ADTS：

| 流 | 字节 | RMS 差 | 峰值差 | 相对 SNR | 最佳延时偏移 |
|---|---|---|---|---|---|
| S：mono 128 kbps 瞬态 | 3042 | 3.537e-9 | 7.648e-8 | 140.50 dB | 0 |
| T：stereo 64 kbps 瞬态 | 1626 | 3.689e-9 | 4.554e-8 | 140.77 dB | 0 |

ffmpeg 退出码 0、stderr 空；本解码器 PCM 与 ffmpeg PCM 都是 9216 / 18432 样本，
零延时偏移。开关打开后的两条流与上一轮未提交的半成品**逐字节相同**。
=> 码流语法与 FFmpeg 解码器语义一致，低 SNR 是量化取舍，不是接线 bug。

检查：`moon check --target wasm --deny-warn` 干净；`aac_encode_vectors` 23/23；
全量 **1414/1414**（§301 是 1410，正好新增 4 条）。

## 3. 复现外部对拍

1. 在模块根（**不能以 `.` 开头**，moon 跳过点目录）建临时 main 包 `zz_short_ab/`：
   `moon.pkg` 里 `import` 两个包并写 `options("is-main": true)`；`main.mbt` 用
   `aac_encode_config_with_perceptual_short(aac_encode_config_perceptual(...))`
   编码 8 帧瞬态夹具 + 1 静音收尾帧，`println` 出
   `S-BYTES b'\xFF' ...`（`Byte::to_string()` 的格式，Python `ast.literal_eval`
   直接还原）以及每行一个样本的 `S-PCM <f> <i> <v...>`。
2. `moon run zz_short_ab < /dev/null > .scratch/short_ab_dump.txt`。
3. Python 落成 `*_short.adts` 与本解码器 `*_own.f32`，然后
   `MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD":/w --entrypoint ffmpeg
   linuxserver/ffmpeg:9.0.2 -y -v error -i /w/.scratch/S_short.adts
   -c:a pcm_f32le -f f32le /w/.scratch/S_ref.f32`（`-y` 在 ffmpeg 那一侧，
   否则撞旧文件会静默不写而退出码仍为 0）。
4. 逐样本比，并扫 0..4096 的延时找最佳偏移；本轮最优就是 0。
5. **先**把 `zz_short_ab/` 与探针移进 `.trash/<日期>/`，**再**跑全量测试。

## 4. 本轮踩到的坑（下一轮直接用）

- `AacTwoResult.sf/cb/zeroes` 是 **128 槽**数组，只有窗组起始槽携带决策；单组八窗
  时前 14 槽就是共享决定。`final_sf[b]`（b < max_sfb）拿来量化 8 个窗是对的，
  `adjust_frame_information` 的窗口组归并在单组下确为恒等 —— 别以为漏了归并。
- `aac_encode_test_tone` 带 LCG dither，**会触发 EIGHT_SHORT**，不能拿来做
  "纯长窗基线"。改成无 dither 的稳态夹具后仍然有短窗：编码器从静音历史起步，
  任何从零开始的夹具头三帧都是 `LONG_START → EIGHT_SHORT → LONG_STOP`。所以基线
  断言必须**按窗口形状分帧比**（长窗逐字节相等、短窗必须变），不能要求整条流相等。
  实测只有 frame 1 变，frame 2..8 全等 → psy 状态没有跨形状串扰。
- 探针里的低 SNR **不是延时错位**：`aac_encode_test_pcm_snr` 已做 1024 样本对齐，
  另扫 960..1089 全部延时，最优仍是 `@1024`。别再往这条路上查。
- 给 `AacEncodeConfig` 加字段时，**四个**构造函数都要带上它：
  `aac_encode_config` / `_perceptual` 填 false，`with_pns` / `with_is` 复制
  `config.perceptual_short`，否则组合开关会悄悄丢标志。新增的
  `with_perceptual_short` 同样要保留 `pns` / `is_stereo`（本轮第一条回归就测三种
  组合顺序）。
- 短窗 `write_ics_info` 的 `max_sfb` 只有 4 位，所以回归里断言
  `max_sfb <= 14`；越界会静默截断而不是报错。
- 临时 main 包会被整模块测试图收进去，中途移走会让那次全量测试白跑（§294 记过）。
- 老规矩：`moon fmt` 禁跑、heredoc 禁用、清理走 `.trash/<日期>/`、
  `libavcodec` 包不要再加白盒测试（wasm init 的 local count 接近上限）、
  提交消息含 `remove`/`rm` 子串会被钩子拦，用 `git commit -F <文件>`。

## 5. 下一步（按建议顺序）

1. **短窗 NMR 夹具**（决定转正与否）：现在的 NMR helper 用 1024 长窗 spectrum 和
   长窗阈值，短窗需要 8×128 谱 + `psy_bands[w*16+g]` 的逐窗阈值，把"噪声/阈值"
   放到同一把尺子上。若开开关后 NMR 明显优于简化路径，再讨论把
   `perceptual_short` 设为默认；否则保持 opt-in 并在 README 里写死这个结论。
2. **窗分组计划**（§303）：展开 `window_grouping[]`（`aacpsy.c:398`），
   让攻击检测产出 `group_len[8]`，按它写 7 位 `scale_factor_grouping`；
   `channel_data_psy` / `write_scalefactors` 吃逐窗组的 `sf_idx`/`band_type`/`zeroes`，
   `adjust_frame_information` 补窗口组 zeroes 归并，
   `msc == max_sfb * num_windows` 里的 `num_windows` 第一次真的等于 8。
3. **多窗工具**（§304）：`mark_pns` / `search_for_pns` / `aac_is_search` /
   `aac_ms_search` 都还只有单长窗形态，C 侧外层是 `w += group_len[w]`；
   `search_for_ms` 的 `Mmax/Smax` 是整窗组共用的。
   `_ref/aacenc/aac_ref.exe --short` 已经能跑 psy + twoloop 并打印 `SHORTGRP`，
   加个开关就能出多窗 IS/M-S 的黄金数据。
4. 短窗 IS 夹具：结构上 `num_windows` 与每窗带内偏移都参数化了，缺一组真夹具。

`AGENT_HANDOFF_2026-11-05_AAC_IS.md` 的 §2b 是 §301 时点的快照，其中第 1 项的
"编码器接线"已由本轮闭环；第 2~4 项仍然有效。
