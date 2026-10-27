# AI 交接：HEVC dependent segment 的 422/444 原生验证

本轮只增加验证夹具，不改解码路径：用 HM 16.8 原生编码 dependent slice
segment 的 4:4:4/4:2:2 流，补齐此前“dependent 只在 4:2:0 验证”的缺口。
全量 **1038/1038** 通过，严格 Wasm check 零警告。

## 工作目录与约束

- Windows / PowerShell，仓库：`D:/project/FFmpeg-n9.0.2/moonbit`。
- 用户目标：持续把 FFmpeg 功能迁移到纯 MoonBit。视频 H264/HEVC/AV1/VP9/MJPEG/PNG；音频 AAC/MP3/Opus；容器 MP4/MKV/TS/HLS/DASH/WebM/WAV。
- 自动化只用 `.mbtx`；C 文件仅作离线参考。运行时纯 MoonBit，无 FFI。
- 修改后跑 fmt、严格 Wasm check、相关测试、`moon info`；`.mbti` 不手改。

## 码流

HM 16.8，固定提交 `382e0a040c7f0189670c4aad9716d45db977b319`，scratch 树
`.scratch/hevc_rplm/HM-...`（由 `scripts/generate_hevc_rplm_vectors.mbtx`
构建；`HM_RPLM` 未设置时其补丁不生效）。

生成器 `scripts/generate_hevc_dependent_rext_vectors.mbtx`，编码参数：
`encoder_lowdelay_main_rext.cfg`、64×64、CTB 32、5 帧、
`--SliceSegmentMode=1 --SliceSegmentArgument=1`（每 CTB 一个依赖段），
关闭 persistent Rice（该工具另有夹具）与 CCP。

| stem | 格式 | QP |
| --- | --- | --- |
| dep4448 | 4:4:4 8-bit | 22 |
| dep42210 | 4:2:2 10-bit | 20 |
| dep44412 | 4:4:4 12-bit | 20 |

15 帧 × 默认/跳过环内滤波 = 30 份 framemd5 对齐 FFmpeg 9.0.2
`-threads 1 -xerror`。`trace_headers` 确认依赖段标志与非零段地址。

测试 `libavcodec/hevc_dependent_rext_wbtest.mbt` 三项：复用
`hevc_check_dependent`（会校验依赖段存在、POC 排序与双滤波 MD5），并
额外断言 SPS 的 `chroma_format_idc`/`bit_depth`。

## 再生

```powershell
moon run scripts/generate_hevc_dependent_rext_vectors.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rplm
moon fmt
moon test libavcodec --target wasm --no-render --filter '*HEVC dependent RExt*'
```

## 后续

1. CCP 与 dependent / PCM 组合、CCP 与 422 的组合仍未验证。
2. tiles + WPP 同时启用：HM 非 High Throughput profile 直接拒绝；FFmpeg
   走入口点子流（按 CTB 行）解码，需要 skipped-bytes 感知的偏移，建议
   独立一轮实现。
3. 当前图片引用（CPR）：HM 16.8 无 SCC 支持，无法生成夹具；若要做，
   需要 SCC 编码器或手工构造合法码流并说明验证边界。
4. 其他编解码器/容器缺口见 README。
