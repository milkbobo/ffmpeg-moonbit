# AI 交接：HEVC persistent Rice 参数自适应 + 切片内联 RPS 修正

本轮接通 `persistent_rice_adaptation_enabled`，并修复验证中暴露的切片头
内联 short-term RPS 解析缺陷。全量 **1034/1034** 通过，严格 Wasm check
零警告。改动已提交并推送。

## 工作目录与约束

- Windows / PowerShell，仓库：`D:/project/FFmpeg-n9.0.2/moonbit`。
- 用户目标：持续把 FFmpeg 功能迁移到纯 MoonBit。视频 H264/HEVC/AV1/VP9/MJPEG/PNG；音频 AAC/MP3/Opus；容器 MP4/MKV/TS/HLS/DASH/WebM/WAV。
- 自动化只用 `.mbtx`；C 文件仅作离线参考。运行时纯 MoonBit，无 FFI。
- 不主动创建子代理（需用户/本地规则授权）。
- 修改后跑 fmt、严格 Wasm check、相关测试、`moon info`；`.mbti` 不手改。

## 实现

1. `libavcodec/hevc_cabac_syntax.mbt`：`HevcCabac` 增加 `stat_coeff[4]`；
   `hevc_cabac_new` 增加可选 `stat_coeff`（默认清零）。
2. `libavcodec/hevc_residual.mbt`：
   - `sb_type = 2 * (c_idx == 0) + (transform_skip || transquant_bypass)`；
   - 子集初始 `c_rice_param = stat_coeff[sb_type] / 4`；
   - 开启时递增不截断到 4；
   - 每个子集首个 remaining 值触发 `hevc_persistent_rice_update`：
     `>= 3 << init` 增 1，`2 * remaining < 1 << init` 减 1（下限 0）。
3. `libavcodec/hevc_inter_decode.mbt`：
   - `hevc_make_slice_state` 的继承参数改为 `(states, stat_coeff)`；
   - 独立 slice / tile 起点清零；dependent 段继承前段；WPP 行起点取
     `common_stat`；列边界 `rs % ctb_width == 1` 与 `states` 一起保存。
4. `libavcodec/hevc_ps.mbt`：切片头内联 RPS 读
   `inter_ref_pic_set_prediction_flag` 的条件改为
   `(is_slice_header || rps_index > 0) && nb_st_rps > 0`（对齐 C
   `rps != sps->st_rps && sps->nb_st_rps`）。

## 参考码流

HM 16.8，固定提交 `382e0a040c7f0189670c4aad9716d45db977b319`，scratch 树
`.scratch/hevc_rplm/HM-...`（由 RPLM 轮构建，`HM_RPLM` 环境变量未设置时
其补丁不生效）。生成器 `scripts/generate_hevc_persistent_rice_vectors.mbtx`：

| stem | 配置 | 覆盖 |
| --- | --- | --- |
| rice_b444_10 | RExt RA，444 10-bit，9 帧 | 基础持久化 + 高位深 |
| rice_b422_12_wpp | RExt RA，422 12-bit，WPP，9 帧 | WPP 行列状态保存/恢复 |
| rice_p420_8 | RExt RA，420 8-bit，6 帧 | 8-bit + 切片内联预测 RPS（触发 RPS 修正） |
| rice_dep_444_10 | RExt lowdelay，444 10-bit，5 帧 | dependent slice segment 跨段继承（SliceSegmentMode=1，每段 1 CTB） |

29 帧 × 默认/跳过环内滤波 = 58 份 framemd5 对齐 FFmpeg 9.0.2
`-threads 1 -xerror`。`trace_headers` 确认 `persistent_rice_adaptation_enabled=1`
（WPP 流另有 `entropy_coding_sync_enabled_flag=1`）。

测试 `libavcodec/hevc_persistent_rice_wbtest.mbt`：三组整流（断言 SPS 标志，
WPP 流另断言 PPS 标志）+ 一项直接验证 `stat_coeff` 的增/减/不变与按 sb_type
隔离。

## 再生

```powershell
moon run scripts/generate_hevc_persistent_rice_vectors.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rplm
moon fmt
moon test libavcodec --target wasm --no-render --filter '*HEVC persistent rice*'
```

前置：先跑一次 `scripts/generate_hevc_rplm_vectors.mbtx` 构建打过补丁的 HM
（或手工在 `.scratch/hevc_rplm` 里 `make -C build/linux -j8 release`）。
Docker 入口用 `--entrypoint make`。

## 已知缺口

- tiles 与 WPP 同时启用、当前图片引用（CPR）仍未实现。
- dependent segment 的 422/444 组合、CCP 与 dependent/PCM 组合待验证。
- tiles 与 WPP 同时启用：HM 在非 High Throughput profile 下拒绝该组合；
  FFmpeg 的 WPP 路径按入口点子流逐 CTB 行解码，需要 skipped-bytes 感知的
  入口点偏移（现有实现用单流 + terminate/reinit，只能覆盖 WPP-only）。
  建议独立一轮实现，并注意 FFmpeg `ff_hevc_cabac_init` 在 tiles+WPP 下
  的 substream 语义。

## 后续

1. tiles + WPP 同时启用。
2. 当前图片引用（CPR）。
3. 上述组合验证；其他编解码器/容器缺口见 README。
