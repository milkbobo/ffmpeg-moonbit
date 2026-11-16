# H.264 4:4:4 高位深在线组合验证及 CLI 收尾

接续 C444_BINTER8。验证默认 B 工具、多参考、AQ/AUD、在线 VBV、
待定 B 遇强制 IDR 排空和 finish 尾 P 的组合，无新增 C ABI。

- libavcodec 新专项：8/10/12/14 位 × CAVLC/CABAC，六帧，multi_ref=3，
  在线 VBV 320000 bit/s、CPB 128000 bit、25 fps，第 2 个显示位置强制
  IDR。确认六个 AU/六个 QP、VBV bit 统计与实际流大小一致、四个 inter
  recon 与本地 skip_lf 解码逐字节相同。
- native nine-x264 FFI：10/12/14 位 × 两种熵模式，实际流式同类组合；
  FFmpeg 显示顺序逐帧像素摘要与本地默认滤波解码一致，无解码诊断。
- CLI 新回归：10/14 位、chroma 444、默认 B 工具、multi_ref=3、keyint=2、
  AQ/AUD、VBV 开关。无 VBV 时 batch/stream 字节相同；有 VBV 时分别
  验证六帧及高位深三平面输出尺寸。
- 修正 CLI **测试辅助函数** encode_raw_stream 的 4:4:4 chroma 长度，
  产品的 encode_raw / encode_stream_file 几何原本已正确。
- 更新 CLI 帮助和 Options 注释：chroma 420/422/444、8/9/10/12/14 位、
  P/B 多参考均反映现有实现。

验证结果：新 codec 专项 1/1，CLI 28/28，native oracle 1/1（内部六种组合）；
moon fmt、moon check --target wasm --deny-warn、moon info --target wasm 通过。
原生编译只有原有 derive 语法弃用提示。C 内存管理未变，本轮未运行 ASan。

后续：扩大真实素材和非宏块对齐几何对照、低容量 VBV 的事务回滚/重试，
以及性能与压缩效率测量。以上用例证明其覆盖范围内的正确性，不代表编码器
所有功能已完整迁移。
