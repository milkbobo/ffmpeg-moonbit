# 在线 B 帧 VBV 与成对事务

本轮在纯 MoonBit H.264 中开放 B 序列在线 VBV。继续应用
moonbit-c-binding、make-moonbit-c-bindings，用已有 FFmpeg native FFI
独立验证；没有新增编码 FFI，也没有修改 C 边界。

## 调度与事务

重构私有 h264_enc_stream_vbv.mbt：共用 vbv_trial / vbv_commit 克隆与
提交逻辑，vbv_picture 搜索单个解码顺序移除。候选共享只读参考像素和
PPS，拥有独立宏块状态、参考列表外层数组、输出队列和统计。

首帧/强制 IDR：先在整组候选上把旧 pending 图片作为尾 P 编码，然后
编码新 IDR，两者都成功才提交。普通 B 调度：奇数局部显示位置只缓冲
输入；未来偶数 P 到来后，先选 P 的 QP，再按剩余缓冲选择待编码 B 的
QP。两张图片全部成功才提交，否则撤销已成功的 P，不消费本次未来
输入，保留先前已接收的 pending B、参考帧、统计和旧输出。

finish 对 pending 尾 P 使用相同事务，不通过无 VBV 的 flat 路径。
B 在 QP51 仍不能装入时整对报错；搜索不回溯未来 P 的已选 QP，因此
不是全组合最优搜索。测试中该失败也能通过 finish 将 pending 图片
作为 P 收尾，输出与从未失败的参考编码器逐字节相同。

新增私有 vbv_coded，区分已接收显示帧数与实际编码 AU 数。CPB 时钟
按实际编码顺序推进，DPB delay 按显示位置与编码位置计算。BP 的实际
余量、跨 IDR 时钟沿用连续 CPB。IDR 使用既有2 tick输出滞后，P参考4，
B为0，尾P为2；实际片头和输出时刻均有测试核对。

输出和 recon 仍按 P/B 编码顺序，frame_qps 则在整对成功后交换两项，
保持显示顺序。pending 输入尚未编码时不会提前写入 QP/模式统计。
已有统计和重建历史仍保留，原始输入只缓冲一张待编码图片。

私有 stream_b 新增实际图片 QP 与 VBV 时序参数，stream_p 支持显式
CPB/DPB时序。无VBV默认行为不变，P-only在线VBV回归仍与批式逐字节
一致。B在线PPS保持配置基础QP，批式B以IDR实际QP作PPS基础，因此
两种B码控路径的搜索成本、QP和字节输出可以不同，不承诺字节相同。

CLI已开放默认B配置下 --stream 加完整VBV三参数，也支持keyint。
流式ABR仍拒收，B × multi_ref>1仍拒收。没有新增公开API或配置字段。
H264EncStats.frame_qps 的注释已更正为实际的显示顺序语义。

## 验证

- 新在线B专项4/4：8/9/10-bit × 双熵 × keyint0/3/4，八帧、初始QP10，
  AQ3、64kbit/s、4000bit缓冲、25fps；每次push的0/1/2 AU调度，
  QP按显示位置、B计数、未滤波recon、BP真实余量、每个pic_timing的
  移除/输出时刻、真实AU全局CPB回放均通过。
- 另测连续手动IDR、奇偶/全IDR短GOP、filler；64x64有噪声输入使未来P
  成功后B在AU2失败，验证整对回滚，随后finish尾P恢复与参考流完全
  相同。新IDR在已成功尾P之后失败也完整回滚，换有效IDR重试与从未失败
  的参考流相同。错误未来平面不影响pending输入。
- 原在线P VBV4、stream8、IDR5、facade7、批式周期B VBV3、固定QP
  周期B3，合计30/30；CLI25/25。本轮wasm共59项通过。
- native 3/3（优化构建）：
  1. 8/9/10-bit × 双熵 × keyint0/3/4，18条八帧流（144帧），
     18条独立IDR尾流（66帧重复对拍）。
  2. 手动IDR/全IDR/短GOP × 双熵，6条九帧流（54帧），
     6条独立手动IDR尾流（28帧重复对拍）。
  3. 双熵各35帧长GOP（70帧），覆盖POC与frame_num回绕、68个B宏块
     和filler。
  共268个完整流帧、24条尾流，纯解码与FFmpeg显示顺序逐像素一致，
  FFmpeg解码warning/error均0；独立AU大小回放CPB通过。
- native CLI：FFmpeg生成32x32、25fps、八帧输入，默认B、CABAC、
  keyint4、AUD、64kbit/s/4000bit/25fps，分块写出2510字节；ffprobe
  无错误且计数八帧，包含GOP边界的尾P/IDR及文件末尾尾P处理。
- 严格wasm check、moon info、定向格式化、git diff --check通过。
  native有既有derive语法弃用警告；零警告指FFmpeg解码诊断。
  未修改C，不重复ASan；未跑全仓库测试，没有创建提交。

```text
moon test --target wasm --release libavcodec/h264_enc_stream_bvbv_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_stream_vbv_test.mbt libavcodec/h264_enc_stream_test.mbt libavcodec/h264_enc_idr_test.mbt libavcodec/video_encoder_test.mbt libavcodec/h264_enc_periodic_bvbv_test.mbt libavcodec/h264_enc_periodic_b_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --release --target native -p libavcodec/x264 --filter '*online B VBV*'
moon check --target wasm --deny-warn
moon info --target wasm
git diff --check
```

native镜像仍为ffmpeg-moonbit-ffref:nine-x264。工作区此前未提交的修改、
旧交接文档和h417_dbg_wbtest.mbt均保留。流式ABR还需要明确总字节预算
与未知输入长度的契约；不能直接解除target_bytes的拒收条件。
