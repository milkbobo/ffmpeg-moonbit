# 周期 IDR 与连续 VBV/CBR

本轮在纯 MoonBit 编码路径开放 `VideoEncConfig.keyint > 0` 与批式
VBV/CBR 组合。遵循 moonbit-c-binding、make-moonbit-c-bindings，继续
使用已有 FFmpeg native FFI 作为独立解码仲裁；本轮未修改 C 边界。

## 实现

`libavcodec/video_encoder_periodic.mbt` 的共享逐 QP 编码器返回完整码流
及实际 AU 大小。每个 GOP 清空预测参考历史，但全部 GOP 共享一次
`h264_vbv_solve` 搜索和连续 CPB。每个候选按顺序加入 filler，后续
GOP 的 buffering_period SEI 按之前所有 AU（包含 filler）消耗后的
实际缓冲余量生成。候选包含 SEI emulation prevention 的实际字节，
最终重放使用同一逻辑，不存在估算头部大小与最终输出大小偏离。

每个 IDR 都写 SPS/PPS、buffering_period 与 pic_timing。
首 IDR 保留原初始 delay/offset，后续 IDR 的 initial delay 来自当时
fullness，offset 来自满缓冲延迟减去该 delay。IDR 的 pic_timing
仍相对前一个 AU 中最近的 buffering period，因此是 keyint*2（低16位）；
其后的 P 图像改用当前 GOP 的 buffering period，仍为局部帧序号*2。
新增两个低层 intra 编码函数的可选 `idr_cpb_delay`（默认0）用于此时序，
没有增加新的公开函数或配置字段。

规范依据：[ITU-T H.264 (08/2024)](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.264-202408-I%21%21PDF-E&lang=e&type=items)，
D.2.1 要求每个 IDR AU 携带 buffering_period；D.2.2 的 cpb_removal_delay
相对 preceding AU 中最近的 buffering period，而非当前 AU 自带的 BP。

输入平面先完整验证，探测使用独立 stats/recon。无解缓冲、ABR/VBV
互斥、未填完整的 VBV 参数、超过24位的满缓冲延迟、初始延迟不足一个
90kHz tick 均报错，探测失败不污染调用者统计。最终记录逐帧 QP、总
VBV bits、filler 次数和字节。recon 仍只包含各 GOP 的 P 图片。

CLI 批式已支持 `--keyint N --no-b-slices --vbv-maxrate R
--vbv-bufsize B --fps F`；帮助文本和 README 已更新。保留流式 ABR/VBV
与周期 B 序列的拒收。CPB 仍沿用已有按帧整数到达量模型，未进行完整
HRD 认证。低层 h264_encode_frames 两函数仍无 keyint，组合入口为 facade。

## 验证

- 新周期 VBV 专项4/4：8/9/10-bit × 双熵 × keyint1/3；真实 AU
  全局 CPB 上下界、BP delay、IDR/P timing、QP响应、filler统计、P recon；
  另测低复杂度 filler、失败无副作用、单 GOP 与原 VBV 逐字节相同。
- 原 IDR5、周期 ABR3、统一接口7、VBV9 共24/24；CLI22/22。
  本轮这些专项合计50/50。
- native oracle1/1，内部12条八帧码流（96帧），54条独立 IDR 尾流
  （210帧重复对拍）；双解码器逐像素一致，FFmpeg warning/error均0。
  native 独立解析的 AU 大小同样通过全局 CPB 回放。
- 严格 wasm check、moon info、git diff --check 通过。native 编译有
  已有 derive 语法弃用警告；上面的零 warning 指 FFmpeg 解码诊断。
- 未更改 C，无需重复 ASan；没有运行全仓库测试，没有创建提交。

```text
moon test --target wasm --release libavcodec/h264_enc_periodic_vbv_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_idr_test.mbt libavcodec/h264_enc_periodic_rc_test.mbt libavcodec/video_encoder_test.mbt libavcodec/h264_enc_vbv_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild --filter '*periodic VBV keeps*'
moon check --target wasm --deny-warn
moon info --target wasm
git diff --check
```

native 环境：ffmpeg-moonbit-ffref:nine-x264。保留已有工作区修改与
`h417_dbg_wbtest.mbt`；旧交接记录只描述各自轮次，最新状态以本文件为准。
