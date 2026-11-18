# H.264 CABAC 多参考编码收口

本轮推进纯 MoonBit 编码；moonbit-c-binding 和 make-moonbit-c-bindings
用于复用现有借用/复制语义安全的 FFmpeg 参考解码绑定作独立对拍，没有新增
编码 FFI。本轮读取并参考 MoonBit 技能；未引入无关的 OCaml 转译或 Why3
证明工程，运行测试和重建不变式不等同于形式化证明。

## 根因与修复

接续工作区已有的分区 ref_idx 读写交错修正与入口解禁改动。
原诊断仍报 EINVAL；bin trace 表明最初没有进入 ref_idx 解码：

1. CABAC Main SPS 的 max_num_ref_frames 写死 1，改为 p.nrefs。
2. CABAC PPS 的默认 L0 活动数量写死 1，改为 p.nrefs。
3. IDR 的参数集副本 p_ps.nrefs 写死 1，改为 multi_ref；否则外发 PPS
   与后续 P 片写入的 reference count 不同。
4. 参数集修复后，首个实际上下文分歧在第三个 P 帧 mb21：编码器用 ctx0，
   解码器用 ctx1。前一 mb20 的运动分区写回将 ref_idx 错置为 0。
   cabac_mvd_partition 现在写回 self.cur_ref_mb，保留真实参考索引。

既有分区内写回顺序修正仍保留，批式及流式 CABAC 多参考现在可用。
调用时设置 b_slices=false、multi_ref=2 或 3；B 切片多参考及批式多参考
码率控制仍明确拒收。没有改变默认单参考的参数值或增加公开 API。

## 验证

- 多参考黑盒测试 8/8：2/3 参考帧、Main/High 变换选择、批式/流式
  逐字节一致；移动图案在 RD 开关与 8/10 位深组合下逐帧 recon 一致。
- 原临时六帧复现用例通过，RD 开关均 recon-bad=0。
- CABAC 专项 10/10。
- 流式编码专项 8/8。
- native x264 oracle 新增一项：四条七帧纯 MoonBit CABAC 多参考流，
  真实 FFmpeg 和 MoonBit 解码输出共 28 帧逐像素一致。
- moon check --target wasm --deny-warn、moon info --target wasm、
  git diff --check 通过；已格式化修改所在包并恢复无关文件的格式变动。
- wasm debug 白盒因既有巨大初始化函数触及 local count too large，
  白盒复现使用 --release；黑盒专项也统一使用 --release。

复现（native 命令在 ffmpeg-moonbit-ffref:nine-x264 镜像执行）：

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_cabac_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_stream_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*CABAC multiref*'
```

## 已知限制与工作区

FFmpeg 在早期 DPB 未填满时仍可能输出 Missing reference picture 提示，
与 CAVLC 多参考既有边界相同；本轮不声称无告警解码。实际输出像素对齐。
本轮不修改 C 绑定实现，因此未重复 ASan；上轮 IDR 绑定改动及其 ASan
记录保留在 FORCE_IDR 交接中。

开始时已有 h264_enc_cabac.mbt/h264_enc_stream.mbt 未提交修改、
h417_dbg_wbtest.mbt 未跟踪文件，以及上一轮 FFI IDR 相关改动。
未覆盖这些内容；本轮追加修复和正式回归。临时诊断文件属于进入时已有内容，
继续保留，新增 tracing 打印均已移除。
