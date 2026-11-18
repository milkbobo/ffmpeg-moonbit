# H.264 P 工具组合与 9-bit 参考解码

本轮继续纯 MoonBit 编码验证，没有增加编码 FFI。按 moonbit-c-binding
和 make-moonbit-c-bindings 补齐现有参考解码绑定的 9-bit 输出搬运。

## 绑定变化

FFmpeg 原有 Annex B 参考解码器只接收 AV_PIX_FMT_YUV420P 和
AV_PIX_FMT_YUV420P10LE，无法仲裁编码器已支持的 9-bit 输出。
现在接受 AV_PIX_FMT_YUV420P9LE，使用已有 plane sink 逐行复制两个字节
的 LE 样本；kind=2 表示 9-bit。原 kind=0（8-bit）、1（10-bit）不变。
MoonBit 包装验证接受新标识，并以两个字节计算帧/平面长度。

所有权不变：输入 Bytes 调用期间借用，FFmpeg 解码缓冲复制为 MoonBit
Bytes；C 资源仍由已有清理路径释放。没有新增保存的 MoonBit 指针或
分配类型。X264PixelFormat 的编码输入枚举没有扩展，本轮只补参考解码。
统一 VideoEncConfig 的多参考文档同时更新，移除过时的“不能码率控制”说明。

## 组合回归

8/9/10-bit × CAVLC/CABAC × 4×4/8×8 变换，共 12 种配置；均启用：
multi_ref=3、AQ strength=6、显式加权预测、AUD、VBV/CBR，P-only。
通过统一 video_encode 接口编码六帧 32×32 输入。

本地逐项断言：实际 dqp 数量大于零、确有 filler、AUD 数量为六、CPB
按实际 AU（含 AUD/filler）回放无上下溢、最终 QP/recon 数量正确、
位深信号正确、全部 P recon 与本地解码逐像素一致。

native oracle 以另一组纹理源，按位深放大到高字节非零的输入样本，
12 条流共 72 帧 FFmpeg/MoonBit 逐像素一致；逐流零解码 warning/error。
同时断言参考端 kind 和 bytes_per_sample 正确，覆盖新 9-bit 分支。

多参考完整测试文件现为 14/14 通过。严格 wasm check、moon info、
git diff --check 通过。没有运行全仓库或整个 native x264 包。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*all P tools*'
```

## 定向内存检查

沿用本仓库此前定向 ASan 方法：gcc 同时以 -g -fsanitize=address
-fno-omit-frame-pointer 编译生成的 x264.whitebox_test.c、libx264_stub.c
和 MoonBit runtime/runtime.c，链接 libruntime.a、libbacktrace.a 与现有
FFmpeg/x264 静态库。不链接 mimalloc 的 libmoonbitrun.o，使用标准分配器。
运行 x264_wbtest.mbt:7-8（已核对本次 test info 的实际索引），设置
ASAN_OPTIONS=detect_leaks=1:fast_unwind_on_malloc=0。上游静态库本身未插桩。
该定向测试返回成功，ASan/LSan 未报告错误。

所有先前未提交内容均保留，没有创建提交。
