# H.264 周期 IDR：统一接口与命令行

在纯 MoonBit 流式 force_idr 之上增加周期 GOP 控制，没有新增编码 FFI。
两个 C 绑定技能用于复用独立 FFmpeg 参考解码验证。

## 接口与边界

VideoEncConfig 新增 keyint:Int32，默认 0（关闭）。正数表示两次 IDR
的输入帧间隔：1 为每帧 IDR，3 为位置 0、3、6……。要求 b_slices=false
且无 target_bytes/VBV。负数、B 调度和码率控制组合均明确拒收。

VideoEncoder::push_frame 根据当前 GOP 的参考帧计数自动请求 IDR；
手动 force_idr 会重置该计数，因此也重新开始周期。例如 keyint=3，在
位置 1 手动请求后，IDR 位于 0、1、4、7。

video_encode 在 keyint>0 时使用同一流式路径实现批式编码；统计中的
frame_qps 每个输入一项，recon 仅包含 P 图片，排除每个 GOP 的 IDR。
默认 keyint=0 保持原编解码入口转发路径。低层 h264_encode_frames /
h264_encode_frames_cabac 没有增加 keyint 参数，该能力经统一接口使用。

命令行新增 --keyint N，支持内存批式和 --stream；帮助与 JSON 摘要同步。
参数解析阶段要求 --no-b-slices，排除码率控制，以免输出文件创建后才拒收。
同时修正 --multi-ref 帮助中过时的“不支持码率控制”说明。

示例：

```text
moon run cmd/encode-h264 input.yuv --width 32 --height 32 --output out.264 --no-b-slices --multi-ref 3 --keyint 3
```

## 验证

- IDR 专项 5/5：包含之前 force_idr 测试，以及新增 8/9/10-bit、双熵、
  keyint=0/1/3/20 组合。每个周期批式流与各 GOP 独立调用 keyint=0 的
  拼接逐字节一致；检查 IDR 数量、最终 QP/recon 数量和重建像素。
- 手动 IDR 重启周期；负数、空序列、B 调度、ABR/VBV 不支持组合拒收。
- CLI 全部 20/20：keyint=2 的五帧输入确有三个 IDR，批式和流式逐字节
  一致；默认值、负数和不支持组合解析验证通过。
- 统一接口原专项 7/7；合计 32/32。
- native FFmpeg oracle：三个位深 × 两种熵编码，共六条八帧完整流
  （48 帧）逐像素一致；每条流从位置 3/6 截取两条尾流，合计 12 条
  尾流、42 帧重复对拍，均独立解码，零解码 warning/error。
- moon check --target wasm --deny-warn、moon info --target wasm、
  git diff --check 通过。公开新增字段由生成接口确认，生成文件在本仓库忽略。

```text
moon test --target wasm --release libavcodec/h264_enc_idr_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --target native -p libavcodec/x264 --filter '*periodic batch IDR*'
```

本轮没有修改 C 包装层，不重复 ASan；未跑全仓库测试。既有未提交内容
保留，没有创建提交。周期 IDR 与 VBV/ABR 的统一时间线尚未实现，不应
通过分别编码 GOP 后拼接的方式假装支持全序列码率约束。

后续状态：周期 IDR × 全序列 target_bytes 已由 KEYINT_ABR 交接实现并
验证，使用一次全局 QP 搜索；上文的“码率控制拒收”仅是本片交付时状态。
VBV 与流式预算限制仍保留。
