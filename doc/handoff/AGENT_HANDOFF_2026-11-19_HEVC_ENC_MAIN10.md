# HEVC 编码器 Main10 交接 —— §455

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§454（B 片双向预测）

## 结果

HEVC 编码器新增 **Main10 10-bit 4:2:0**，贯通既有 I/P/B、整数及 1/4 像素
运动补偿、量化/反量化、去块滤波和 SAO。纯 MoonBit、wasm-only，无 C FFI。
默认 Main 8-bit 行为及既有黑盒钉值不变。

验证：HEVC 编码器全部测试文件 wasm-gc **47/47**；FFmpeg 9.0.2 在
`-loglevel error -xerror` 下零告警解出外部仲裁流，4 帧 framemd5 已固化到
公开 API 黑盒测试。

## 公开 API

以下三个入口新增可选 `bit_depth : Int32 = 8`：

- `hevc_encode_frames`
- `hevc_encode_sequence`
- `hevc_encode_intra_frame`

仅接受 8 或 10；其他值返回 `hevc enc: bit_depth must be 8 or 10`。
`bit_depth=10` 选择 Main10；B 片仍由 `b_slices=true` opt-in。不要给既有输入
样本追加 0..255/0..1023 的严格值域拒绝：旧测试向量包含超范围样本，新增
校验会破坏兼容行为。

## 参数集与码流

- 10-bit PTL：`profile_idc=2`，Main 与 Main10 compatibility flags 均置位。
- VPS/SPS 复用同一位深参数；SPS `bit_depth_luma_minus8` 与
  `bit_depth_chroma_minus8` 都写 2。
- 色度格式仍为 4:2:0；Main10 不等于 4:2:2/4:4:4 支持。
- 整数和分数像素 MC 原本就使用 `ctx.sps.bit_depth`，不要为 Main10 重写一套
  写死位深的运动补偿。

## 本轮关键 bug：本地重建的反量化 QP 域

症状：10-bit I 帧及 I/P/B 重建在 POC 0 的第一个亮度样本失配，编码器为
512、解码器为 298。

根因：解码器反量化使用 `qp + sps.qp_bd_offset`（10-bit 时偏移 12），编码器
本地重建却直接传公开 QP。码流前向量化本身没有错，错的是编码器参考帧重建。

修复：

- `libavcodec/hevc_enc_ctu.mbt`：intra 亮度、色度本地重建加 `qp_bd_offset`。
- `libavcodec/hevc_enc_inter.mbt`：inter 残差亮度、色度本地重建加相同偏移。
- 前向量化仍使用原 QP；8-bit 的 `qp_bd_offset=0`，数值路径不变。

## 测试与外部仲裁

### 永久测试

- `libavcodec/hevc_enc_main10_wbtest.mbt`：4 组白盒，覆盖参数集/profile、
  QP 12/26/40 的 I 帧往返、I/P/B 与分数像素 MC、非法 9-bit；I/P/B 按 POC
  对齐编码器重建与解码输出，逐样本比较 Y/Cb/Cr。
- `libavcodec/hevc_enc_main10_test.mbt`：公开 API 黑盒，重新生成同一向量，
  本仓库解码并计算 `yuvp(10)` 的 16-bit little-endian 平面 MD5，对照
  FFmpeg 9.0.2 framemd5。

运行全部 HEVC 编码器测试：

```powershell
moon test libavcodec/hevc_enc_cabac_wbtest.mbt `
  libavcodec/hevc_enc_dct_wbtest.mbt `
  libavcodec/hevc_enc_residual_wbtest.mbt `
  libavcodec/hevc_enc_i_test.mbt libavcodec/hevc_enc_p_test.mbt `
  libavcodec/hevc_enc_i_wbtest.mbt libavcodec/hevc_enc_p_wbtest.mbt `
  libavcodec/hevc_enc_main10_wbtest.mbt `
  libavcodec/hevc_enc_main10_test.mbt --target wasm-gc --no-render
```

### 可复跑生成器

普通可执行包 `cmd/generate-hevc-main10` 生成 64x64、QP26、10-bit、4 帧
I/P/B 流：

```powershell
moon run --target wasm-gc cmd/generate-hevc-main10 <已存在的输出目录>
```

注意 `--target` 必须放在包名之前；放在输出目录之后会被当成程序参数。
输出文件为 `<目录>/main10_ipb.265`，本次大小 23671 字节，编码 AU 为
POC 0/2/1/3，slice type 2/1/0/1，大小 5434/5734/6399/6104 字节。
生成器复跑前后 SHA-256 均为
`58D71C39DB059569FD396FB41DE22DCC785E7329436E326175FE85EC0A92D314`，
确认输出字节确定不变。

Docker 仲裁：

```powershell
docker run --rm --network none -v "<输出目录>:/work" `
  --entrypoint ffmpeg linuxserver/ffmpeg:9.0.2 `
  -hide_banner -loglevel error -xerror -i /work/main10_ipb.265 -f framemd5 -
```

原始 Annex B 没有容器时间戳，FFmpeg framemd5 按**解码顺序**输出 POC
0/2/1/3，不要把它误标为显示序。显示序 POC 0/1/2/3 的重建一致性由白盒
测试负责。

| 输出序 | POC | slice | MD5 |
|---|---:|---|---|
| 0 | 0 | I | `f8408f1a8dc72c0d08eb928d8353d9b8` |
| 1 | 2 | P | `c0fd3680d01781507c64ac0b2e9f5913` |
| 2 | 1 | B | `ff73d0cb0995a7dc74b8090e78d8050f` |
| 3 | 3 | P | `6445b66a286c1bc48586b12967d19550` |

每帧外部 rawvideo 为 12288 字节，即 64x64 `yuv420p10le` 三平面 16-bit
数据。临时仲裁流位于 `.scratch/hevc_main10/main10_ipb.265`，不是发布产物。

## 检查状态与边界

- `moon check libavcodec --target wasm-gc` 通过，仅有 libavcodec/libavutil
  未使用 `moonbitlang/core/v128` 的既有警告。
- `moon info libavcodec --target wasm-gc` 已运行；wasm/wasm-gc 的 v128 接口
  差异是目标条件导出的既有现象。
- 全仓检查仍被 `cmd/encode-h264` 的既有 `FrameReader`/`FrameWriter` 与
  `Int64`/`Int` 错误阻断，本轮未修改该包。
- Main10 仅限 4:2:0；4:2:2/4:4:4、12-bit、CRF/VBV、流式 CLI 未实现。
- B 片仍限 2Nx2N，加权双向预测、时间 MVP、多参考帧索引仍未实现；去块与
  SAO 仍只覆盖 luma。

下一步路线：4:2:2/4:4:4 或 12-bit → 码控（CRF/VBV）→ 流式 + CLI。
