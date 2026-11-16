# H.264 4:4:4 三平面 inter 8x8 DCT

接续 C444_CABAC_P。`chroma_format=3, b_slices=false, dct8x8=true`
现在对 P 帧中允许 8x8 变换的 inter 宏块编码三平面 8x8 残差。
同时覆盖 CAVLC / CABAC 和流式 / batch。I 帧仍使用原有三平面 4x4。

- 三平面分别按 QPy/QPc 量化，使用 dequant8 矩阵 3/4/5，即时 IDCT8 重建。
- `planes_444` 按 plane*256 + quadrant*64 存储，三个平面共享 CBP。
- CAVLC 的四个 interleaved 子列表按平面维护 nC，写后合并 quadrant leader。
- CABAC 使用 cat 5/9/13，保留 4:4:4 的显式 coded_block_flag，允许共享
  CBP 已置位但当前平面为空的块。
- 避免再执行原 4x4 色度重建；`dct8x8=false` 继续使用原路径。
- 旧 I+P 的 FFmpeg MD5 锚点显式关闭 dct8x8，保留原 4x4 fixture 的用途。

验证：

- c444 / c444_cabac / stream_c444 / 原有 dct8 专项合计 21/21。
- 新 `h264_enc_c444_dct8_test.mbt`：色度单独变化、空 Y/V 残差，
  CAVLC/CABAC 与 4x4 fallback 的本地重建闭环。
- nine-x264 镜像 native FFI：两种熵模式 × 普通/恒定 luma fixture，
  各四帧，FFmpeg 零 warning/error，逐帧像素摘要与本地默认解码一致。
- moon fmt、moon check --target wasm --deny-warn、moon info --target wasm 通过。
- C ABI、借用/释放约定无改动；本轮未运行 ASan。

后续：4:4:4 I8x8 预测/变换、B 帧双向 MC 和 CABAC B 语法。
