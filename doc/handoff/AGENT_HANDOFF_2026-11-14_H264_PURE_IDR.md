# 纯 MoonBit 流式 H.264：逐帧强制 IDR

本轮扩展纯 MoonBit 编码能力。与此前 FORCE_IDR 交接中的 libx264 编码
绑定扩展不同，此实现不调用 C 编码器；两个 C 绑定技能用于现有 FFmpeg
参考解码对拍。

## API

H264StreamEncoder::push_frame 和 VideoEncoder::push_frame 增加可选
标签参数 force_idr（默认 false）。调用 enc.push_frame(y,u,v,force_idr=true)
请求当前输入成为 IDR，重复 SPS/PPS，并重新开始独立 GOP。

首帧请求与原首帧行为相同。后续请求要求 b_slices=false；B 调度存在
延迟图片，此时明确返回错误，不消耗当前输入或推进调度。调用者可去掉
该标志重试同一帧。输入平面验证仍在状态推进之前。

新 IDR 编码成功后，现有参考平面列表替换为该 I 帧重建；宏块状态节点
重新初始化，再写入 I 帧 nz，避免旧 MV/ref/skip/intra 标记残留；参考
frame_num 计数重置为 0，下一 P 帧从 1 开始。累计输出及统计不清空。

默认调用签名向后兼容，没有新增 VideoEncConfig 字段。该接口是流式
P-only 功能，本轮不增加批式 keyint、B 调度中途 IDR 或流式 VBV。

## 验证

新黑盒：8/9/10-bit × CAVLC/CABAC × AUD 开关，三参考、AQ6、加权
预测启用，八帧序列在位置 3、4 连续强制 IDR（另测首帧显式请求）。
断言三个 SPS/PPS/IDR；完整流八帧；每段与全新批式编码相同输入逐字节
一致；每段独立解码后的像素与完整流相应帧一致。拒收 B 调度请求的测试
再送相同输入，与普通批式流逐字节一致，证明拒收没有丢帧或推进状态。

- 新 IDR 文件 2/2；既有流式专项 8/8；统一接口专项 7/7。
- native oracle 同样覆盖 12 种配置，完整流共 96 帧；另从位置 3、4
  分别截取 24 条尾流，合计 108 次尾流帧对比，覆盖连续 IDR 无 AUD。
  对完整流及每条尾流检查 FFmpeg warning/error 为零，并逐像素对齐两侧。
- 严格 wasm check、moon info、git diff --check 通过。moon ide doc
  已核对两个 push_frame 的新可选参数；mbti 为本仓库忽略的生成文件。

```text
moon test --target wasm --release libavcodec/h264_enc_idr_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_stream_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*pure streaming forced IDR*'
```

native 环境为 ffmpeg-moonbit-ffref:nine-x264。本轮没有修改 C 绑定实现，
不重复 ASan；未跑全仓库测试。工作区此前未提交内容均保留，没有创建提交。
