# H.264 4:4:4 B 帧内 I4

接续 C444_BI8。两种熵模式的 batch 与 stream 现在允许
`chroma_format=3, b_slices=true, intra4x4_in_b=true`；仅需继续关闭
`intra_in_b`（I16）。`dct8x8` 的原有 I8 候选可按需开启。

- 新 code_bi444_residuals：三平面共享 16 个模式，各自回放 I4 预测，
  使用独立 QP 与 intra dequant4 矩阵，更新每个平面的 nz。
- 私有 h264_enc_luma_i4_pass 新增 matrix 可选参数（默认 0）。
- CAVLC gray intra CBP、无 chroma mode、三平面残差及 nC；CABAC 对应
  无 chroma mode/CBP bins，使用 cat 2/8/12。
- 候选搜索不再对 4:4:4 调用 subsampled chroma predictor。
- 四个入口放开 intra4x4_in_b，保护测试继续拒收 I16。

验证：

- 新 32x32 场景切换测试，bi4_mbs > 0；Y/V 为梯度，U 恒定，覆盖共享
  CBP 下空平面残差。两种熵模式和 CABAC RD 开关均 recon 一致，
  stream/batch 字节相同。
- 原 bintra、新 c444 BI4/BI8、stream_c444_b 组合回归 15/15。
- nine-x264 native FFI 将 I4/I8 一起验证，两种熵模式均逐帧 FFmpeg
  像素摘要与本地默认滤波解码一致，warning/error/decode_error_flags 全零。
- moon fmt、moon check --target wasm --deny-warn、moon info --target wasm 通过。
- 无 C ABI 或所有权变化，本轮未运行 ASan。

下一步：4:4:4 B I16 候选及 B inter 8x8 DCT。
