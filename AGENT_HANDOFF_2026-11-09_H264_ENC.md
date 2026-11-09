# H.264 编码（libx264 绑定）交接（2026-11-09）

## 交付内容

"编码：H264" 完成。FFmpeg n9.0.2 树内没有软件 H.264 编码器（`ohenc.c` 是
OpenHarmony 硬件封装；其余注册名是 libx264/libopenh264/nvenc/qsv/amf/mf/
v4l2m2m/rkmpp 外库或硬编）。FFmpeg 的 H.264 软件编码能力就是 `libx264.c`
封装，因此按 moonbit-c-binding / make-moonbit-c-bindings 技能流程做了
native FFI 绑定。

| 层 | 文件 | 说明 |
| --- | --- | --- |
| 镜像 | `.scratch/ffref/Dockerfile.x264`（tag `nine-x264`） | nine-ref + libx264-dev + `--enable-libx264 --enable-gpl` 重编 FFmpeg 静态库（GPL 只在测试镜像层） |
| C stub | `libavcodec/x264/libx264_stub.c` | avcodec 编码 API 薄包装 + 测试用 C 解码 oracle（AVParser 切 AU） |
| FFI | `libavcodec/x264/ffi.mbt` | 私有 extern，全部 `#borrow` |
| 安全层 | `libavcodec/x264/x264.mbt` | `X264Encoder::open/send_frame/receive_packet/send_eof/flush/encode_all/extradata/close`、`x264_supports` |
| 测试 | `libavcodec/x264/x264_wbtest.mbt` | 6 用例，镜像内 6/6 |

验证：96×64×33 帧确定性夹具三组流（ultrafast/Baseline、medium/High、High 10）
经**纯 MoonBit 解码器与 FFmpeg C 解码器双解码逐像素一致**；确定性双跑逐字节
一致；avcC（movenc 式构建）+ 长度前缀样本路径全通。宿主 wasm 全量 1713/1713、
ffref 76/76（nine-x264 内）。

## 如何运行

```sh
# native 测试（Windows 无 MSVC，须在镜像内）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild"

# 宿主类型检查（不链接）
moon check --target native libavcodec/x264
```

## 关键坑（下次绑定 C 库前先读）

1. **external object 可选返回失效**：`-> Handle?` 下 C 返回 external object
   指针、MoonBit 恒得 `None` 且对象立即被 finalize（moon 0.1.20261104 实测；
   `#external` 注解同样无效；非可选返回正常）。**失败句柄模式**：open 永远
   返回句柄，失败时是带 errmsg 的 failed 句柄，MoonBit 侧用 status/errmsg
   查验。`libx264_stub.c` 与 `ffi.mbt` 的注释里有完整说明。
2. **C 解码 oracle 必须用 AVParser 切 AU**：把整条 Annex B 流当单个
   send_packet 只能解出 1-2 帧（解码器每包只出一帧）。`x264dec_annexb` 用
   `av_parser_parse2` 逐 AU 喂，与 raw h264 demuxer 行为一致。
3. **`x264-params=b_annexb=0` 无效**：`x264_param_parse` 不认识 `b_annexb`
   （libx264.c 只 WARNING）。extradata 因此总是 Annex B 参数集 blob；MP4 场景
   由 muxer（movenc）自建 avcC——测试 `x264_build_avcc` 镜像了这条路径。
4. **宿主/镜像工具链代差**：宿主 moon 20261016 不认 `#derive`，镜像 20261104
   对 `derive(...)` 报 deprecation 警告。包内用旧式语法保宿主干净；derive 的
   隐式方法提升警告用 `pub extend T with Trait::{...}` 显式声明消除。
5. **链接行**：`-lavcodec` 的 allcodecs.o 拉全编码器注册表，需要
   `-lx264 -lz -ldav1d -llzma -lshine -lswresample -lpthread -lm`。ffref 的
   `/usr/local-ref/libavcodec_ref.a` 的 allcodecs.o 早于 x264，无需 -lx264。

## 未接的面（后续可选）

- x264 的 4:2:2/4:4:4 编码（`yuv422p/yuv444p` 选择器加进 sel_pix_fmt 即可）
- 8/9/12/14-bit 之外的 yuv420p（如 4:0:0）
- 码率控制面的显式参数化（bit_rate 已通，x264 的 ABR/CRF/QP 模式经 options
  直通，未做逐参数断言）
- 把编码器接进 `cmd/` CLI 或统一播放门面（当前是库 API + 测试）

## 复现素材

夹具是确定性的（`x264_fixture`：梯度 + 棋盘 + 漫游方块 + 漂移色度），无外部
向量文件。镜像重建：`.scratch/ffref` 目录下
`docker build -f Dockerfile.x264 -t ffmpeg-moonbit-ffref:nine-x264 .`
（需要同目录的 `ffmpeg-src/` 源码树，已在）。
