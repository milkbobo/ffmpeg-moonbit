# H.264 libx264：逐帧强制 IDR

本轮按 MoonBit 技能，重点使用 `moonbit-c-binding` 和
`make-moonbit-c-bindings`，扩展现有系统库绑定，不重新 vendor FFmpeg。

## API 与契约

`X264Encoder::send_frame(pts~, y~, u~, v~, force_idr=true)` 请求该输入帧
成为 IDR；默认 false 保持原行为。返回 false（EAGAIN）时，调用者应先取包，
然后以相同 PTS、平面及 force_idr 标志重试。该能力属于 native libx264 绑定。

C 层以 `AVFrame.pict_type = AV_PICTURE_TYPE_I` 配合私有选项
`forced-idr=1` 实现，依据本仓库上游 `../libavcodec/libx264.c` 的
`X264_frame` 映射。每帧 `av_frame_unref` 重置 picture type，下一帧不继承请求。
Bool 在 ABI 上为 int32；所有句柄及平面参数仍为调用期间借用，平面复制到
AVFrame。没有新增存储的 MoonBit 指针或新的分配所有权。

## 验证

新增测试 `x264 forced IDR respects PTS and does not persist across frames`：
九帧输入在 PTS=4 强制 IDR，检查只有 0/4 为关键帧、恰有两个 IDR NAL、
FFmpeg 无警告/错误、完整流与从第二个 IDR 开始的五帧尾流均能独立解码，
MoonBit 与 FFmpeg 解码像素一致。覆盖 bf=0 和开放 GOP 的 bf=2，后者以
b_strategy=0 固定 B 帧决策并断言确实产生 B 帧。

```text
moon fmt libavcodec/x264 --check
moon check --target wasm --deny-warn --no-render
moon test --target native -p libavcodec/x264 --filter '*forced IDR*'
moon info --target native -p libavcodec/x264
```

native 命令在 ffmpeg-moonbit-ffref:nine-x264 容器运行，先 moon update。
本机和容器工具链版本不同；容器产生两条已有 derive 语法弃用警告。
moon info 的 canonical backend 为 wasm，因此 native 接口只展示差异，
不会写出 native pkg.generated.mbti；已核对新增可选 Bool 参数。
定向 native `moon check --warn-list +73` 通过（27 条已有警告、0 错误），
wasm 严格检查及定向格式检查通过。全模块 `--target all --warn-list +73`
检查返回非零，并输出大量其他包已有告警，不作为本轮通过项。

定向 ASan 验证通过：用 gcc 的 `-g -fsanitize=address
-fno-omit-frame-pointer` 同时编译 moon test 生成的
`x264.whitebox_test.c`、`libx264_stub.c` 与 MoonBit `runtime/runtime.c`，
链接测试构建的 libruntime.a、libbacktrace.a 和包的 FFmpeg/x264 系统库。
不链接 libmoonbitrun.o，以 stdlib allocator 替代 mimalloc；运行
`x264-idr-asan x264_wbtest.mbt:0-1` 返回成功，未报 ASan/LSan 错误。
上游静态 FFmpeg/x264 库未插桩。技能现成 ASan runner 固定全模块测试，
本轮使用定向编译以隔离工作区已有其他未提交的编码器改动。

## 工作区边界

绑定包完整 native 回归：39 项，31 通过、8 失败。失败为四项
P-slice Intra4x4 fixture 未触发目标模式、CAVLC 紧 VBV picture 2
在 QP 51 下溢、两项 CABAC 紧 VBV 未提升 QP，以及 legacy I/P-only
流被判含 B 帧。这些是纯 MoonBit 编码 oracle 测试，没有调用新增
force_idr API；本轮未修复，也未在修改前跑完整基线，不能宣称全量通过。
新增 IDR 测试最终版（含实际 B 帧断言）独立验证通过；全量测试是在
加 B 帧断言之前启动的，因此最终版以随后定向测试和 ASan 结果为准。

开始时已有 h264_enc_cabac.mbt、h264_enc_stream.mbt 修改及
h417_dbg_wbtest.mbt 未跟踪文件；本轮未编辑这些文件。
