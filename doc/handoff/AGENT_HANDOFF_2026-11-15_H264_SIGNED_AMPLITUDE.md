# H.264 满幅正负残差验证

接续 WIDE_RD_QUANT，扩展数值与端到端质量回归。

- 新 high_amplitude 白盒：10/12/14 位 × 4x4/8x8 × user QP 0/26 ×
  正 DC、负 DC、棋盘格、正负半幅。检查正向量化、反量化、IDCT 后的
  每像素绝对误差不超过按位深缩放的量化误差界，覆盖 48 组变换。
- high_contrast 黑盒从黑→白扩为黑→白→黑，覆盖正负满幅 P 残差；
  另加 B 调度并禁用竞争 I4/I8，确认实际 bi16_mbs > 0，验证高位深
  I16 Hadamard DC 重建。12/14 位 × 420/444 × CAVLC/CABAC × P/B，
  recon 字节一致，并检查亮场/暗场幅值。
- native nine-x264 FFI 同样扩为三帧及 P/B 两种顺序，核对 FFmpeg 显示
  顺序像素摘要、正确幅值及零 warning/error/decode_error_flags。

结果：本地两专项 2/2；native 1/1（内部16种端到端组合）；
moon fmt、moon check --target wasm --deny-warn、moon info --target wasm 通过。
本轮为回归覆盖扩展，没有更改编码核心或 C ABI/所有权；未运行 ASan。

下一步优先：4:4:4 P 帧内 I4/I16 候选（目前只启用其 I8 候选），
随后进行真实素材质量与性能测量。
