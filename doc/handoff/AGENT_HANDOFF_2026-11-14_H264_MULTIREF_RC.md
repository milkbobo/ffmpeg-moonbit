# H.264 多参考与平均字节预算

本轮继续纯 MoonBit 编码迁移，开放 CAVLC/CABAC P-only 序列中
multi_ref 与 target_bytes 的组合。未新增 C 编码 FFI，现有 FFmpeg
参考绑定按 moonbit-c-binding / make-moonbit-c-bindings 用于独立验证。

## 实现

此前两个入口把 target_bytes 和 VBV 一并拒收，但已有平均字节预算路径
在每次 QP 探测和最终编码时都传递 multi_ref，并由各自的 qps 编码器
维护参考历史。本轮将入口限制缩小到 VBV，并更新公开参数文档。

使用 h264_encode_frames / h264_encode_frames_cabac：设置
b_slices=false、multi_ref=3、target_bytes=预算字节数。统一 video_encode
批式接口通过 VideoEncConfig 同样支持。流式接口仍不提供序列总字节预算。

保持已有预算契约：预算包含 Annex B 参数集/头部等所有字节；可行时选择
预算内的 QP 分配。即使 QP51 仍超过预算时，返回 QP51 最佳努力码流，
不承诺任意小目标都能满足。回退流的 PPS 仍用调用者基础 QP，因此不能
要求与 qp=51 的普通调用逐字节相同，应比较未去块重建像素。

VBV、多参考 B 切片继续明确拒收，错误消息将 VBV 与 target_bytes 区分。

## 新验证

- 黑盒：CAVLC/CABAC × 8/10-bit，五帧、参考深度 3；先编码 QP20/51
  确定可行目标，再验证输出不超目标、QP 确实提高、frame_qps 只有五项、
  recon 只有四项且与解码逐像素一致，确认搜索探测未污染最终统计。
- 目标为 1 字节时，各组合均回退为全 QP51，像素与普通 QP51 流一致。
- 统一编码接口：两种熵编码均与对应直接调用逐字节一致。
- 多参考完整专项 11/11；新增统一接口测试 1/1。
- native oracle：四条预算编码流，共 20 帧，FFmpeg/MoonBit 逐像素一致，
  且零解码 warning/error。
- moon check --target wasm --deny-warn、moon info --target wasm、
  git diff --check 通过；格式化仅限修改文件。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_rc_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt --filter '*multiref average-byte*' --no-render
moon test --target native -p libavcodec/x264 --filter '*multiref average-byte*'
```

native 环境为 ffmpeg-moonbit-ffref:nine-x264。未修改 C 代码，不重复 ASan；
未运行全仓库回归，工作区此前未提交改动均保留。

## 扩展回归未通过

h264_enc_rc_test.mbt 完整文件实际包含 RC、AQ 和 I4P 共 15 项，本次
5 通过、10 失败，包含旧帧 MD5、模式数量和质量阈值。此前色度 RD 修改
改变了决策，本轮尚未完成这批测试的独立重新仲裁，不能声称完整 RC/AQ
测试族全绿。没有放宽这些断言或直接接受新快照。新增多参考预算四组合
与独立 FFmpeg 对拍通过；上述 10 项仍是后续需要核查的回归债务。

单独 RC 子集四项复核：1 通过、3 失败，当前首个失败点分别是 QP 数组
快照 [36,36,36,37,37]→[36,37,37,37,37]、
[38,38,38,38,39]→[38,38,38,38,38]，以及外部仲裁帧 MD5 快照。
尚未更新这些旧快照，也不据此断言后续所有断言已通过。

后续状态：上述 10 项已由 H264_RC_REPIN 交接完成核查，八条流共 34 帧
经 FFmpeg 无告警仲裁并重置哈希，15 项均完成通过验证，未放宽功能阈值。
详见 AGENT_HANDOFF_2026-11-14_H264_RC_REPIN.md。
