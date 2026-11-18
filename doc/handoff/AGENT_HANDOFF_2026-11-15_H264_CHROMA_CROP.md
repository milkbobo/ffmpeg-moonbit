# H.264 非对齐尺寸裁剪修复与 4:4:4 VBV 回滚验证

接续 C444_ONLINE_DEPTH。新增 34x18 回归发现并修复两个实际问题：

1. High/B SPS 的裁剪偏移固定除以 2。现在按 chroma_format 派生单位：
   4:2:0 为 2x2，4:2:2 为 2x1，4:4:4 为 1x1。否则可见尺寸错误。
2. CAVLC batch P 源色度加载把 padded height 当 visible height，非 16
   对齐输入越界；recon 打包也使用 padded height。改为显式 visible height，
   保留分配/参考复制使用 padded height。

验证：

- 新 crop 专项：34x18，420/422/444，CAVLC/CABAC、I/P 与 B 调度；
  可见尺寸正确、recon 长度正确且逐字节等于 skip_lf 解码，batch/stream 相同。
- 新低容量 4:4:4 VBV 专项：64x64、32000 bit/s、1600 bit CPB，失败 IDR
  前已有 pending B；确认 next_display/pending/统计/队列/recon 均回滚。
  重试平坦 IDR 后，码流与未经历失败的运行全字节相同，能解出三帧。
- 既有 c444/c422/online_depth 回归 12/12。
- native nine-x264 FFI：34x18，422/444 × 两种熵模式 × I/P、B，FFmpeg
  width/height、显示顺序像素摘要与本地默认滤波解码一致，零诊断。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm。
- C ABI/内存所有权未改，本轮未运行 ASan。

后续：更广的实际素材编码对照、性能/压缩效率评估，及高位深大残差的
RD 累加范围审查。以上不等于全部 FFmpeg 编码特性已完整迁移。
