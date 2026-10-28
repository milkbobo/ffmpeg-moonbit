# AI 交接：HEVC CCP × dependent/PCM 组合验证（2026-10-28）

本轮回应 README HEVC 行最后一个未受阻的验证缺口——"CCP 与
dependent/PCM 组合待验证"。四组 HM 16.8 4:4:4 组合流共 20 帧在默认
滤波与 `-skip_loop_filter all` 两种模式下与 FFmpeg 9.0.2 **单线程**
逐帧 MD5 一致。全量 wasm **1061/1061**（此前 1057），严格 check 零警告。

## 一、验证矩阵

| 夹具 | 组合 | 编码配置 | 流内证据 |
| --- | --- | --- | --- |
| `ccp_dep8` | CCP × dependent slice segments | 8-bit 444，低延迟 GOP，QP 22 | dependent=1、PCM=0、CCP=1；每帧 1 独立 + 3 依赖段 |
| `ccp_dep10` | 同上 | 10-bit 444，QP 20 | 同上 |
| `ccp_pcm8` | CCP × PCM | 8-bit 444，QP 4，强制 transquant bypass + PCM | dependent=0、PCM=1、CCP=1；每流 20 个 PCM CU |
| `ccp_dep_pcm10` | CCP × PCM × dependent | 10-bit 444，QP 4，强制 bypass + PCM + 段模式 | 三者全开；20 个 PCM CU + 每帧 3 依赖段 |

- 源：`ccp_dep8/10` 用与既有 CCP 夹具同族的结构化 64×64 五帧源；
  PCM 组用确定性满量程噪声源（xorshift32）。
- 标志核对：FFmpeg `trace_headers`（PPS
  `cross_component_prediction_enabled_flag`、
  `dependent_slice_segments_enabled_flag`，SPS `pcm_enabled_flag`）。
- PCM 覆盖：临时在 `hevc_intra_decode.mbt` 的 PCM 分支插桩计数后已移除，
  每流 20 CU（5 帧 × 4 个 32×32 CTU）。

## 二、关键坑

1. **HM 的 PCM 不会在普通 QP 下被选中**：`xCheckIntraPCM` 仅在
   `uiBestBits > uiRawBits` 时进入候选。结构化源、QP 22/45 都不会触发
   （流仍只有几千字节）。必须**强制 transquant bypass（无损）+ 满量程
   噪声源**，让每帧 4 个 CTU 全部走 PCM（码流约等于原始 YUV 大小）。
2. **`SliceMode` ≠ 依赖段**：`SliceMode` 生成独立 slice；
   `SliceSegmentMode=1` + `SliceSegmentArgument=1` 才把单 slice 按 CTU
   切成依赖段，HM 在 `sliceSegmentMode != NO_SLICES` 时置 PPS 的
   `dependent_slice_segments_enabled_flag`（TEncTop.cpp:980）。
3. **白盒局部数上限**：新夹具一律黑盒。为此在
   `hevc_inter_decode.mbt` 新增 pub 访问器 `HevcDecodedFrame::poc`
   与 `HevcDecodedFrame::yuvp(depth)`（先例 `H264Frame::yuvp`），
   黑盒测试自行按 POC 排序并计算 MD5。
4. 编码参数沿用既有 CCP 生成器：显式关闭 RDPCM/transform skip/
   bypass 之外的 RExt 工具、`GolombRiceParameterAdaptation=0`、
   `HighPrecisionPredictionWeighting=0`、`ExtendedPrecision=0`、
   `ScalingList=0`，保证组合结论只落在 CCP/dependent/PCM 上。

## 三、再生命令

```sh
moon run scripts/generate_hevc_ccp_combo_vectors.mbtx \
  D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_ccp \
  D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rdpcm
moon test libavcodec --target wasm --no-render --filter "*CCP +*"
```

生成器会写出 `libavcodec/hevc_ccp_combo_vectors_test.mbt`（四组夹具 +
FFmpeg 单线程参考 MD5，滤波/跳滤波各一套）；`hevc_ccp_combo_test.mbt`
为手写黑盒断言。HM 16.8 pinned commit
`382e0a040c7f0189670c4aad9716d45db977b319`，编码器在
`.scratch/hevc_rdpcm/`，仅移除 `-Werror`。

## 四、文档与剩余缺口

- README HEVC 行的"CCP 与 dependent/PCM 组合待验证"已移除，并修正了两处
  过时表述（inter 工具组合"待补"、RPLM 段"persistent Rice 仍未实现"）
  和测试计数（1018 → 1061）。
- PORTING_HISTORY §112 记录本轮。

剩余缺口仍为外部受阻（见 README"主要边界"）：VP9 复合预测（libvpx
编码器不生成）、HEVC tiles+WPP（HM 拒绝）/CPR（需 SCC 编码器）、
H.264 EC 高位深/444/422（FFmpeg 硬编码 420+uint8）、AAC USAC、
AV1 film grain/intrabc、统一播放 API（建议单独立项）。
