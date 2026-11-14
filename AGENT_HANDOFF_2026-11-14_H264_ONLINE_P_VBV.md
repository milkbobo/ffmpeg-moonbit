# P-only 在线 VBV

本轮将纯 MoonBit H.264 的 P-only VBV 接入逐帧编码，无需整条原始
序列探测。继续应用 moonbit-c-binding、make-moonbit-c-bindings，用
既有 FFmpeg native FFI 独立解码仲裁；未修改 C 层，未新增编码 FFI。

## 实现

`H264StreamEncoder::open` 新增可选 vbv_maxrate、vbv_bufsize、fps、
vbv_init（默认90）参数。三个码率参数全0保持旧行为；正值配置复用
h264_vbv_new，并验证在线周期 BP 所需的满缓冲24位延迟范围。负参数、
不完整 VBV、B 序列 VBV 明确拒收。VideoEncoder::open 从已有配置转发
VBV 参数，仍拒收 ABR。

新增私有 h264_enc_stream_vbv.mbt。每次 push 先校验输入平面，然后
从配置 QP（限于原 VBV 的10..51范围）开始尝试当前图片。候选编码器
共享只读参考像素与 PPS，独立复制可变宏块镜像、参考列表外层数组、
统计和输出队列。stream_idr / stream_p 新增私有逐帧 QP 参数，保持
PPS 的基础 QP 为配置值，实际片 QP 通过 delta 传递。

以真实 AU 字节（含 SPS/PPS、AUD、SEI、防起始码转义）计算当前 CPB
消耗，使用已有 filler 调度补齐 CBR。只有实际 AU 加 filler 可以移除，
且下一帧到达不会溢出时，才提交参考帧、宏块镜像、计数、CPB余量、
输出和统计。失败候选被丢弃；QP51 仍不适配时报错，不消费该输入。
每个已接受帧追加一次 QP 和最终模式统计，不计失败探测。

周期和手动 IDR 都沿用连续 CPB。首 BP 使用配置初始余量，后续 BP
反映当时的实际余量。IDR 的 cpb_removal_delay 相对前一 BP，其后 P
时序相对当前 IDR。失败的强制 IDR 不改变时钟、参考历史或旧输出队列。

默认无 VBV 的 I/P/B 流保持旧字节行为。已有 recon 历史仍保留，在线
VBV 同样保留 frame_qps；只是原始输入/参考工作集不随输入帧数增长，
不能宣称整个编码器总内存与序列长度无关。文档已明确这个限制。

CLI 已支持 `--stream --no-b-slices` 加 VBV 三参数，也可用 keyint 和
multi_ref。默认 B 配置的在线 VBV、任何流式 ABR 继续拒收。批式 B VBV
及上一轮的周期码控支持保持不变。

## 验证

- 新在线 VBV 专项4/4：8/9/10-bit × 双熵 × keyint0/3，共12配置，
  初始QP10、3参考帧、AQ3、含有/无AUD、64kbit/s、4000bit缓冲、25fps。
  每次 push 立即获得一个 AU，不需要未来输入；完整输出和 QP 数组
  与批式逐字节一致，模式计数、filler计数/字节及总bits一致，实际 CPB
  全局回放通过。
- 错误平面、不可行的后续强制 IDR 均保留参考状态、QP/统计和未取走的
  旧输出；之后编码有效 P，与从未失败的参考编码器逐字节相同。
  首 IDR 两次失败均不消费输入、不输出、不累计统计。
- 另测低层直接 open、连续手动 IDR、BP真实余量、pic_timing、P recon，
  ABR/B VBV/部分及负 VBV 配置拒收。
- 原 stream8、IDR5、facade7、周期P VBV4、周期B VBV3，共27/27。
  CLI25/25。加上新专项，本轮 wasm 共56项通过。
- native 2/2（优化构建）：
  1. 8/9/10-bit × 双熵 × 手动/周期 IDR，12条七帧流（84帧）；
     24条独立 IDR 尾流（72帧重复对拍），均独立可解码。
  2. 双熵、16参考帧、连续35帧 filler 流（70帧），覆盖历史淘汰和
     两次 frame_num 回绕。
  完整流共154帧，纯解码与 FFmpeg 逐像素一致，所有完整流和尾流
  FFmpeg warning/error 均0。真实逐 AU CPB 回放通过。
- native CLI：FFmpeg生成32x32、25fps、七帧输入；分块流式CABAC、
  keyint3、multi_ref3、AUD、64kbit/s/4000bit/25fps，输出2362字节。
  ffprobe计数七帧；与相同配置批式文件 cmp 逐字节一致。
- 严格wasm check、定向格式化、moon info、git diff --check通过。
  公开变化为低层open的四个可选参数；facade配置字段不变。
  native保留已有derive语法弃用警告，零警告指FFmpeg解码诊断。
  未修改C，不重复ASan；未运行全仓库测试，没有创建提交。

```text
moon test --target wasm --release libavcodec/h264_enc_stream_vbv_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_stream_test.mbt libavcodec/h264_enc_idr_test.mbt libavcodec/video_encoder_test.mbt libavcodec/h264_enc_periodic_vbv_test.mbt libavcodec/h264_enc_periodic_bvbv_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --release --target native -p libavcodec/x264 --filter '*online P VBV*'
moon check --target wasm --deny-warn
moon info --target wasm
git diff --check
```

native镜像仍为ffmpeg-moonbit-ffref:nine-x264。保留此前未提交工作、
旧交接文档和h417_dbg_wbtest.mbt。下一步可以迁移 B 的在线 VBV，需要
事务性处理待编码 B/未来 P 成对输出，以及强制 IDR 前的尾 P 收尾，
不能只解除当前 b_slices 拒收条件。
