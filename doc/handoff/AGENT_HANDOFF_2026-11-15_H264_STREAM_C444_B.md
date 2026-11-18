# H.264 4:4:4 流式 B 帧

接续 C444_B。H264StreamEncoder 现在允许与 batch 相同的 4:4:4 B 子集：

```text
chroma_format=3, b_slices=true,
b_parts=false, intra_in_b=false, intra4x4_in_b=false, dct8x8=false
```

复用既有 stream_p/stream_b 和上一轮三平面参考/MC/残差实现，放开 open
的对应组合限制。四种尚未实现的工具仍在 open 阶段分别拒收。
没有新增公共 API，也没有改变 C ABI 或借用/释放规则。

验证：

- 新 stream_c444_b 专项：两种熵模式 × multi_ref=1/3 × 4/5 帧，
  AQ/AUD 开启；逐次 drain 的 AU 数、finish 尾 P 排空、完整字节与 batch
  一致、inter 重建与本地 skip_lf 解码一致。
- 强制 IDR：待定 B 先作为旧 GOP 的 P 排空，再输出新 IDR；验证 AU
  数、两组 IDR、重建及无丢帧。在线 VBV 开关 × 两种熵模式均通过。
- 单独开启任一不支持工具的参数组合均拒收。
- native nine-x264 FFI 的 B oracle 改为实际推送 streaming，再验证输出与
  batch 长度/MD5 相同，FFmpeg 三帧显示顺序像素摘要与本地一致，零诊断。
  原生 oracle 4/4。
- 新专项前两项加 stream_c444 原四项 6/6（后补工具拒收项单独复跑）。
- 现有 stream / stream_vbv / stream_bvbv 回归 16/16。
- moon fmt、moon check --target wasm --deny-warn、moon info --target wasm 通过。
- 本轮未改 C 内存管理，未运行 ASan。

下一步：4:4:4 B 子分区、B 帧内候选、B 8x8 DCT。
