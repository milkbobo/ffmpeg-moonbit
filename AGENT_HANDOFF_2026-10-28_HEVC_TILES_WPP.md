# AI 交接：HEVC tiles+WPP 与 cabac_bypass_alignment（2026-10-28）

本轮在前一轮 CCP 组合验证之后，继续清理 README 的 HEVC 缺口：**tiles
与 WPP 同时启用**。该组合仅 High Throughput Intra 4:4:4 profile 允许；
实现后三组流共 15 帧与 HM 16.8 解码输出逐帧 MD5 一致，全量 wasm
**1064/1064**，严格 check 零警告。

## 一、为什么参考不是 FFmpeg

FFmpeg 9.0.2 的单线程 `hls_decode_entry` 是 `-threads 1` 的解码路径，
也是 tiles+WPP 唯一可能的路径（多线程 WPP 只在 1×1 tiles 时启用）。
它的 `ff_hevc_cabac_init`/`ff_hevc_save_states` 用 **tile-scan 索引
`ctb_addr_ts % picture_ctb_width`** 判定 WPP 行起点，tiles 下该条件与
tile 行边界无关；实测：

- HM 重建 vs 源：PSNR ≈ 41 dB（正确）；
- FFmpeg 9.0.2 解码同一码流 vs 源：PSNR ≈ 10 dB（垃圾）；
- FFmpeg 解码输出 vs HM 重建同样 ≈10 dB。

因此本组夹具以 **HM 解码器输出**（`TAppDecoderStatic`，已先确认与
编码器重建逐字节一致）为逐帧参考；FFmpeg 仅用 `-f rawvideo` 把 HM 的
YUV 哈希成 framemd5。README/PORTING_HISTORY 已明确记录该边界。

## 二、验证矩阵

| 夹具 | 配置 | 帧 |
| --- | --- | --- |
| `htw8` | 8-bit 444，64×64，CTU 32，2×2 tiles，WPP，QP 22 | 5 |
| `htw10` | 10-bit 444，同上，QP 20 | 5 |
| `htw_wide8` | 8-bit 444，192×128，CTU 64，2×2 tiles（2+1 列 × 1+1 行非方形） | 5 |

三组都来自 `encoder_intra_high_throughput_rext.cfg`，即
`cabac_bypass_alignment_enabled_flag = 1`（HT profile 规范要求），
每帧 `num_entry_point_offsets = 3`、`tiles_enabled_flag = 1`、
`entropy_coding_sync_enabled_flag = 1`（`trace_headers` 核对）。

## 三、实现要点

1. `hevc_inter_decode.mbt`：子流不再用 terminate/字节推算，而是按
   slice header 的 entry point 偏移直接 `ff_init_cabac_decoder`
   定位（HM `TDecSlice::decompressSlice` 语义）。每个 tile 起点重置
   概率与 persistent Rice 统计；tile 内后续 CTU 行只有在上右 CTU
   与当前 CTU 同 slice 且同 tile 时装载上一行第二个 CTU 保存的上下文。
2. **entry point 是 EBSP 字节数，而 `H2645NAL.data` 是 RBSP**：
   `h2645_parse.mbt` 的 `RbspExtract`/`H2645Nal` 新增 `skipped_pos`
   （记录每个被删 `00 00 03` 中第二个 0x00 的 RBSP 位置），
   `hevc_decode_picture` 照搬 FFmpeg `hls_slice_data_wpp` 的 `cmpt`
   调整，把 entry 偏移映射到 RBSP。未映射时 8-bit 流只有含防竞争字节的
   帧会坏（htw8 第 5 帧、htw10 第 2 帧起），10-bit 更早暴露。
3. **cabac_bypass_alignment**（`hevc_cabac_syntax.mbt` +
   `hevc_residual.mbt`）：`TDecBinCABAC::align` 等价物把 range 置 256，
   使符号与 escape 值按原始字节读取；escape 判定按 HM 补齐为
   「第二个及以上 greater1 命中 / gt2 为 1 / nCoeff > 8」。缺任何一条
   都会在含 escape 的系数组处失步。FFmpeg 9.0.2 对 SPS 该标志只打
   "not yet implemented" 警告，没有实现。
4. 邻域可用性保持按 tile 的 `end_of_tiles_x`。FFmpeg 在其 WPP 分支把
   该值设为 picture 宽度，是它与本组合失效相关的一环，未复刻。
5. 旧 `cabac.cc.reinit`（skip_bytes(0)）不再使用，已删除；PCM 路径仍用
   `skip_bytes`。

## 四、夹具与再生命令

- 生成器：`scripts/generate_hevc_tiles_wpp_vectors.mbtx`
- 夹具：`libavcodec/hevc_tiles_wpp_vectors_test.mbt`（生成）
- 断言：`libavcodec/hevc_tiles_wpp_test.mbt`（黑盒）

```sh
moon run scripts/generate_hevc_tiles_wpp_vectors.mbtx \
  D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_ccp \
  D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rdpcm
moon test libavcodec --target wasm --no-render --filter "*tiles + WPP*"
```

环境：HM 16.8 pinned `382e0a040c7f0189670c4aad9716d45db977b319`，
源码与 `bin/TAppEncoderStatic`、`bin/TAppDecoderStatic` 在
`.scratch/hevc_rdpcm/`；容器 `vpxdev-img` + `linuxserver/ffmpeg:9.0.2`；
Git Bash 下需要 `MSYS_NO_PATHCONV=1`。

## 五、剩余缺口

- HEVC：当前图片引用（CPR，需 SCC 编码器）；CCP 与 tiles/WPP 组合未验证
  （本组未开 CCP）；dependent segment 与 tiles+WPP 组合未验证。
- 其他见 README「主要边界」：VP9 复合预测（libvpx 不生成）、H.264 EC
  高位深/444/422（FFmpeg 硬编码）、AAC USAC、AV1 film grain/intrabc、
  统一播放 API（建议单独立项）。

## 六、坑

- HM 的 HT cfg 默认 `AlignCABACBeforeBypass: 1`；把它关掉能生成
  flag=0 的流，但那是非规范 profile 流，只能当临时调试对照。
- `.mbtx` 里写 `println("...\\{var}...")` 注意转义；生成的内嵌 base64
  每段 40000 字符，测试里必须先 `av_base64_decode` 再比较（本轮调试时
  曾把 base64 文本当成原始帧比较，浪费了一轮）。
- HM 解码器没有 `-skip_loop_filter`；tiles+WPP 只能对拍滤波输出。
