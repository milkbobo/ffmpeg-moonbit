# 交接：ffref 原生参考 oracle（§316）+ mooncakes 发布（2026-11-06）

> 本文档承接 `AGENT_HANDOFF_2026-11-05_*` 系列与 PORTING_HISTORY §310–§316。
> 面向下一个会话：仓库在 `D:\project\FFmpeg-n9.0.2\moonbit`（git master，
> mooncakes 已发布 `milkbobo/ffmpeg-moonbit@0.1.0`）。

## 一、本切片交付了什么

1. **§315 CLI ②③**：`cmd/dump-packets`（JSONL 包转储，`--stream/--limit`）与
   `cmd/decode-audio`（`--output` WAV + `summary_json`）。引擎：
   `libavformat/playback_dump.mbt` 的 `MediaFile::dump_packets_json`。
2. **§315 三处 ffmpeg 对齐修复**（docker ffprobe 交叉验证驱动）：
   - `ogg.mbt` pts 重写：非 EOS 页按页 granule 后缀和回退（oggparseopus.c
     逐行核对）；EOS/无 gp 页走 lastpts 链 + 末包 end-trim。
   - `opus_rc.mbt` 空熵帧合法化：1 字节 TOC-only 包解出 MDCT 重叠拖尾
     （145 样本），不再 concealment 全零。
   - `playback.mbt` decode_audio_file 裁 Ogg pre_skip（initial_padding 语义）。
   - 对拍结果：四容器 pts/size/flags 全对齐 ffprobe；opus 解码 vs ffmpeg
     参考 max|diff|=1（±1 全是 dither）。
3. **mooncakes.io 发布**：模块重命名 `milkbobo/ffmpeg-moonbit`（47 moon.pkg
   同步替换），0.1.0 已上线（Server 200；包页
   https://mooncakes.io/docs/milkbobo/ffmpeg-moonbit@0.1.0 ）。
4. **§316 ffref 原生参考 oracle**（本次交接重点，见下）。

## 二、ffref oracle：是什么、怎么跑

**目的**：把「与真 FFmpeg 对拍」从 docker 命令行往返变成进程内直查。
`ffref/` 包通过 native FFI 链接 FFmpeg n9.0.2 静态库，暴露两个安全 API：
`ffref_probe(data) -> FFRefProbe`（每流 timebase + 每包
stream/pts_us/dts_us/size/keyframe）和 `ffref_decode_audio(data) -> FFRefAudio`
（首音频流 s16 无 dither PCM + rate/channels/样本数）。C 侧
`ffref/ffref_stub.c`（mem AVIO + av_read_frame + avcodec/swr），返回
Value-as-Bytes 扁平 LE blob，NULL → `FFRefError`（suberror）。

**运行方式**（Windows 本机跑不了：moon 的 Windows native 后端要求 MSVC，
本机只有 MinGW；故 oracle 在 docker 镜像内跑）：

```bash
# 镜像已构建好：ffmpeg-moonbit-ffref:nine（2.56GB，本机 docker images 可见）
# 重建脚本：.scratch/ffref/Dockerfile（gitignored；aliyun apt 源 + GitHub 官方
# n9.0.2 tarball 静态库 --disable-programs/avdevice/swscale/avfilter/network
# + moon CLI。注意宿主 FFmpeg 源码树 hevcdec.c 有旧实验损伤，勿用作镜像源）

MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native -p ffref --target-dir /tmp/mbuild"
```

要点：
- **必须 `--entrypoint /bin/sh`**（linuxserver 基础镜像 ENTRYPOINT=ffmpeg）。
- 容器是一次性的：每次都要 `moon update`（拉 registry 索引）才能解析
  moonbitlang/x 依赖。
- `--target-dir /tmp/mbuild`：构建产物放容器内（Windows 挂载卷上编译极慢）。
- 当前结果：**38/38 绿**（含真 FFmpeg opus 解码逐样本 ±1 对拍）。
- 本机 wasm 主套件 **1438/1438** 不受影响（ffref 全文件 native-gated，
  wasm 下是空包）。

**扩展方向**：往 `ffref_stub.c` 加新 oracle 面（例如视频帧 → YUV MD5、
seek 一致性、AAC-in-WAV parser 分包真相值）+ 在 `ffref_test.mbt` 加差分；
每扩展一条就永久获得进程内回归。

## 三、下一个会话的候选工作（按优先级）

1. **CLI ④⑤ extract-frame / extract-cover**（申报书②收尾）：引擎已就绪
   （§313 `yuv_bytes()`、§312 视频分发）。extract-frame 可选绑定/内嵌
   YUV→RGB（swscale 未移植——纯 MoonBit 写 BT.601/709 limited/full 即可，
   或先输出 YUV444P 原始帧 + ffprobe 验证）。
2. **ffref 扩展**：视频差分（`ffprobe -show_frames` 真值 vs 我们
   VideoDecoder）、AAC/MP3 解码差分（现只钉了 opus/pcm）。
3. **HEVC/AV1 轻量真实流 e2e**（§313 遗留）。
4. **libswresample/libswscale 核心移植**（重采样 + 色彩转换，extract-frame
   的完整形态需要）。
5. mooncakes 0.2.0 发版（README 包页渲染瑕疵顺手修：表格换行/`））`）。

## 四、坑清单（本切片新增，均已写进 PORTING_HISTORY §315/§316 与记忆）

- **moon 版本差异**（宿主 0.1.20261016 vs 容器 0.1.20261104）：新版 `-p` 是
  目录路径；test 文件是独立编译单元（顶层 let/私有 extern/构造器不可见，
  fixture 必须与测试同文件 + `for "test"` import 本包）；`assert_*(c, msg="")`
  标签参数且 raise Error 不能出现在 raise 具体类型函数里；`suberror` 才是
  error 类型；`**debug**` 通配不识别（用 `"moonbitlang/core/debug"`）。
- **FFmpeg 9 的 `AV_VERSION_INT` 新编码**：`(major<<16)|(minor<<8)|micro`
  （63.1.102 = 4129126）。
- **moon Windows native = MSVC only**（runtime `#error`）；MinGW gcc 会连
  编译都过不去。C 绑定开发走 docker Linux。
- **linuxserver/ffmpeg 镜像**：ENTRYPOINT 劫持一切命令；`sh -c` 内引号转义
  会被吃（heredoc 直写 C 测试程序）。
- **转义地狱第三定律**：任何「python 生成含字面量的 MoonBit 源文件」都会
  出事（无分号字面量让正则吞掉后续声明、`'\\n'` 变真换行）——fixture/测试
  代码一律 Edit/Write 工具直写；机械复制只做纯文本逐行拼。
- 标签参数调用是 `f(x=v)`；String 没有 substring/find（写辅助函数或绕开）。
- docker 构建时 Ubuntu 26.04 apt 源不稳（archive.ubuntu.com 404/超时），
  Dockerfile 已换 aliyun 镜像源；`ffbuild/common.mak` 是仓库文件，拷源码
  勿整目录排除 `ffbuild`。

## 五、状态快照

- git：master，最新提交见 `git log --oneline -3`（§315 + 重命名 + §316）。
- 测试：wasm **1438/1438**；ffref native（容器内）**38/38**。
- PORTING_HISTORY 至 §316；agent.md 至 ⑳g；记忆
  `ffmpeg-moonbit-migration-progress.md` 同步至本切片。
