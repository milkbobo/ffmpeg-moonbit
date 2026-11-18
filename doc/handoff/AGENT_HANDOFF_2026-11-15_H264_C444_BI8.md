# H.264 4:4:4 B 帧内 I8

接续 C444_BPARTS。batch 与 H264StreamEncoder 的 4:4:4 B 调度现在可
使用 `dct8x8=true`：I/P 使用已有三平面 8x8 路径，B 可选择 I8 宏块。
仍需显式 `intra_in_b=false, intra4x4_in_b=false`（I16/I4 尚未迁移）。
注意 B inter 残差仍为 4x4，不能将此功能理解为 B inter 8x8 DCT。

- B I8 残差回放复用 P 编码器已验证的三平面 I8 实现。
- 候选搜索跳过 subsampled chroma mode 选择，三平面共享四个 luma 模式。
- CAVLC 无 chroma mode，使用 gray intra CBP，逐平面写 interleaved lists。
- CABAC 无 chroma mode bins、无 chroma CBP bins，使用 cat 5/9/13。
- 放开四个入口的 dct8x8 限制，保留 I16/I4 的拒收及对应测试。

验证：

- 新 32x32 场景切换 fixture：参考图像平坦，B 图片为梯度；明确断言
  bi8_mbs > 0，两种熵模式 × b_parts 开关，重建逐字节等于本地 skip_lf
  解码，stream/batch 全字节相同。
- native nine-x264 FFI 同一 fixture，两种熵模式逐帧像素摘要与本地默认
  滤波解码一致，FFmpeg warning/error/decode_error_flags 全为零。
- 原 BI8、新 BI8、stream_c444_b 及 c444_bparts 组合回归 11/11。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm 通过。
- 无公共 API 或 C ABI/所有权变化，本轮未运行 ASan。

下一步：4:4:4 B I4/I16 候选，B inter 8x8 DCT。
