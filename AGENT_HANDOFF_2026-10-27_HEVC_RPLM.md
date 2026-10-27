# AI 交接：HEVC 参考列表修改（RPLM）

本轮接通 `ref_pic_list_modification` 的解析与应用，并用打了补丁的 HM
16.8 生成真实码流验证。全量 **1030/1030** 通过，严格 Wasm check 零警告。
工作区本轮改动已提交（见文末状态）。

## 工作目录与约束

- Windows / PowerShell，仓库：`D:/project/FFmpeg-n9.0.2/moonbit`。
- 用户目标：持续把 FFmpeg 功能迁移到纯 MoonBit。视频 H264/HEVC/AV1/VP9/MJPEG/PNG；音频 AAC/MP3/Opus；容器 MP4/MKV/TS/HLS/DASH/WebM/WAV。
- 自动化只用 `.mbtx`；C 文件仅作离线参考内核。运行时保持纯 MoonBit，无 FFI。
- 不主动创建子代理（需用户/本地规则授权）。
- 修改后运行 fmt、严格 Wasm check、相关测试、`moon info`；`.mbti` 不手改。

## 实现

`libavcodec/hevc_slice.mbt`

- `hevc_frame_nb_refs`：按 short-term RPS 的 `used` 位、long-term RPS 的
  `used[]` 与当前图片引用（计入但本移植仍拒绝 CPR）计算候选数。
- 切片头解析：P/B 且候选数为 0 报错；`lists_modification_present_flag`
  且候选数 > 1 时读 L0（B 还有 L1）标志，每项 `ceil_log2(nb_refs)` 位，
  存入新的 `rpl_modification_flag_l0/l1`、`list_entry_l0/l1`（16 项）。
- 依赖 slice segment 通过 `..prev` 自动继承。

`libavcodec/hevc_inter_decode.mbt`

- `hevc_slice_rpl`：候选串接与截断完成后，若标志置位则按条目下标逐个
  取 `rpl_tmp[idx]`；越界返回 `hevc: invalid reference index`。未置位
  保持原来的截断行为。权重表与 `collocated_ref_idx` 都按重排后的列表解释。

## 参考码流与验证

HM 16.8 including RExt，固定提交 `382e0a040c7f0189670c4aad9716d45db977b319`，
scratch 树：`.scratch/hevc_rplm/HM-...`。`scripts/generate_hevc_rplm_vectors.mbtx`
会**幂等**地给 scratch 树打补丁（`HM_RPLM=1` 生效）：

1. `TEncTop.cpp`：`m_cPPS.setListsModificationPresentFlag(true)`；
2. `TEncGOP.cpp`：反转每条活动列表并写入 `setRefPicSetIdxL0/L1(i, n-1-i)`，
   同时置位 L0/L1 标志——编码器自身也按反转后的列表预测，码流自洽。

四组码流（64×64、`--GolombRiceParameterAdaptation=0`）：

| stem | 配置 | 覆盖 |
| --- | --- | --- |
| rplm_p8 | lowdelay P，420 8-bit，6 帧 | L0 最多 4 个活动参考，反转 3,2,1,0 |
| rplm_b8 | random access，420 8-bit，9 帧 | L0+L1 同时修改 |
| rplm_b444_10 | random access RExt，444 10-bit，9 帧 | 高位深 + 444 |
| rplm_b422_12 | random access RExt，422 12-bit，9 帧 | 高位深 + 422 |

33 帧 × 默认/跳过环内滤波 = 66 份 framemd5 对齐 FFmpeg 9.0.2
`-threads 1 -xerror`。`ffmpeg -bsf:v trace_headers` 确认
`lists_modification_present_flag=1`、`ref_pic_list_modification_flag_l0/l1=1`
与反转条目真实出现。

测试：`libavcodec/hevc_rplm_wbtest.mbt` 五项——四组整流（同时断言解析出的
条目等于 `n-1-i`、P 流至少 3 个 L0、B 流存在同时修改两表的 slice）+ 一项
把 `list_entry_l0[0]` 改成 99 后确认 `hevc_slice_rpl` 返回错误。
码流与参考内嵌在 `libavcodec/hevc_rplm_*_realdata_wbtest.mbt`。

## 已知缺口（本轮发现）

RExt 随机接入配置默认打开 **persistent Rice 参数自适应**
（`persistent_rice_adaptation_enabled_flag`）。本移植只解析该标志、
未实现参数跨 TU 持久化，开启时整帧残差都会解错。夹具因此显式
`--GolombRiceParameterAdaptation=0`。下一步若要扩大 RExt 覆盖，应先实现
该工具（参考 `hevc_dep/src/libavcodec/hevc/cabac.c` 412-421、1322-1394）。

## 再生

```powershell
moon run scripts/generate_hevc_rplm_vectors.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rplm
moon fmt
moon test libavcodec --target wasm --no-render --filter '*HEVC RPLM*'
```

生成器会用 `vpxdev-img` 里的 `make -C build/linux -j8 release` 重建打了补丁的
HM（增量很快）。Docker 入口需 `--entrypoint make`；镜像默认入口是
`sh -c sleep infinity`。

## 后续

1. persistent Rice 参数自适应（上面）；随后可重新生成未关闭该工具的 RExt 流。
2. tiles + WPP 同时启用、当前图片引用（CPR）。
3. dependent segment 的 422/444，CCP 与 dependent/PCM 组合验证。
4. 其他编解码器/容器缺口见 README。
