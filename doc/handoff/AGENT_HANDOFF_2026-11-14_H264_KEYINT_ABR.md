# 周期 IDR 与全序列平均字节预算

本轮将 keyint 与 target_bytes 接入同一纯 MoonBit 批式搜索。没有新增
编码 FFI，两个 C 绑定技能用于现有 FFmpeg 参考解码独立仲裁。

## 实现与契约

新增私有 video_encoder_periodic.mbt，复用 h264_rc_solve 对整个输入的
逐帧 QP 数组搜索。每次候选编码按 keyint 分 GOP，分别初始化参考历史，
但使用同一全局 QP 分配。候选大小为完整拼接码流长度，包含所有 IDR、
重复 SPS/PPS 和 AUD；不是给每个 GOP 重新分配完整 target_bytes。

各 GOP 的 PPS 仍使用调用者基础 QP，图片自己的 QP 由片头 delta 传递。
最终重建只包含 P 图片（排除每个 GOP 的 IDR），frame_qps 每个输入一项。
探测使用独立 stats/recon；编码前验证全部平面形状，避免中途输入错误
污染调用者统计。不可行预算沿用原 ABR 契约：回退 QP51 最佳努力输出，
不承诺可以满足任意小的字节数。

CLI 批式现在支持 --keyint N --no-b-slices --target-bytes B。
流式 ABR 仍拒收；周期 IDR × VBV 继续拒收，尚未统一 CPB 时间线。
fps 本身也被视为已配置码率参数，不能在流式配置中静默忽略不完整 VBV。

## 验证

- 新预算专项 3/3：双熵、8/10-bit、七帧三 GOP，目标位于普通 QP20
  与 QP51 大小之间，最终整流在预算内，QP 响应、统计和重建一致。
  1 字节预算回退全 QP51，像素与普通 QP51 流一致；不比较因 PPS 基础
  QP 不同而合理变化的码流字节。另测错误输入不污染输出统计。
- keyint=1 全 IDR 无 P recon；keyint 大于序列长度时，与普通单 GOP
  ABR 逐字节相同。
- 原 IDR 专项 5/5；CLI 完整 21/21，包含新批式预算选项与流式拒收。
- 统一接口原专项 7/7；四份专项合计 36/36。
- native oracle：8/9/10-bit × 双熵，共六条七帧码流（42 帧），
  全部在预算内，FFmpeg 零解码 warning/error，逐像素一致。
  从每条流位置 3/6 的 AU 边界截取 12 条尾流（30 帧重复对拍），均能
  独立解码且双解码器像素一致。
- 严格 wasm check、moon info、git diff --check 通过；没有新增公开类型
  或函数，只开放已有 keyint/target_bytes 组合。

```text
moon test --target wasm --release libavcodec/h264_enc_periodic_rc_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_idr_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --target native -p libavcodec/x264 --filter '*periodic ABR uses*'
```

native 环境为 ffmpeg-moonbit-ffref:nine-x264。未改 C 包装层，不重复 ASan；
未跑全仓库测试。工作区先前未提交内容保留，未创建提交。
