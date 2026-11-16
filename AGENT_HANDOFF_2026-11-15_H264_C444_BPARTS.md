# H.264 4:4:4 B 子分区

接续 STREAM_C444_B。batch 与 H264StreamEncoder 现在允许
`chroma_format=3, b_slices=true, b_parts=true`，继续要求
`intra_in_b=false, intra4x4_in_b=false, dct8x8=false`。

- 审查确认 subpartition evaluation 使用 decoder 自身的 mirror commit 与
  三平面 per-4x4 MC，再走上一轮 code_b444_residuals 和通用熵编码 tail；
  不需要另一份色度残差实现。移除四个入口对 b_parts 的限制。
- 修正 b_bi_part_sad 的预测 buffer 步长：h264_b_prediction 的 luma
  buffer 恒为 16，不能用当前分区宽度 w 索引。影响候选排序，重建仍走
  decoder MC。保留已有公开 API。
- 更新 stream 参数文档与错误提示；工具拒收测试仍覆盖余下三个限制。

验证：

- 新 48x48 五帧独立移动半幅 fixture，三平面内容不同；两种熵模式及
  CABAC RD 开关、multi_ref=3，断言 bpart_mbs > b8x8_mbs > 0，
  确认两分区与 B_8x8 均实际选中。逐字节 recon 解码一致，stream/batch 一致。
- 原 bparts 专项与 stream_c444_b 保护/排空/VBV 专项合计 10/10。
- nine-x264 native FFI 同一 fixture，两种熵模式均逐帧像素摘要一致，
  FFmpeg warning/error/decode_error_flags 均为零。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm。
- 无 C ABI、所有权或分配变化，本轮未跑 ASan。

下一步：4:4:4 B 帧内候选与 8x8 DCT。
