# H.264 4:4:4 CAVLC 流式 I/P

接续 H264_C444。`H264StreamEncoder::open(chroma_format=3,
b_slices=false)` 支持逐帧 CAVLC I/P 编码，复用现有三平面帧编码器。
4:4:4 CABAC 流式和 B 调度在 open 阶段拒收；批量入口不变。

- 色度 stride 在 4:4:4 下等于 luma stride，色度分配高度等于填充高度。
- 输入验证、加载的可见区域及重建打包使用可见宽高，分配使用 MB 对齐高度。
  同时修复非 16 对齐高度下 4:2:0 / 4:2:2 流式输入被误判长度的问题。
- 重建历史沿用原有约定：只记录 inter 图片，IDR 不进入 recons。
- 保留开始工作时已有的 h264_enc_c444_test.mbt 修改。

验证：

- `moon test --target wasm --release libavcodec/h264_enc_stream_c444_test.mbt --no-render`
  4/4：四帧序列与 batch 字节一致（multi_ref=1/3、AQ 开关、AUD），
  P 重建与 skip_lf 解码像素一致，非法调度及空色度拒收，34x18 的三种格式输入验证。
- 现有 stream / stream_vbv / stream_bvbv / c422 加本次初始三个测试：23/23。
- `moon fmt`、`moon check --target wasm --deny-warn`、`moon info --target wasm` 通过。
- native C 绑定回归：`libavcodec/x264/stream_c444_wbtest.mbt`，使用
  nine-x264 镜像内 FFmpeg probe 检查四帧、零 warning/error。

下一步仍包括：4:4:4 CABAC P/B、4:4:4 B 的双向 MC、三平面 8x8 DCT。
本次未改 C ABI 或内存所有权；没有新增 vendoring，也没有重复 ASan harness。
