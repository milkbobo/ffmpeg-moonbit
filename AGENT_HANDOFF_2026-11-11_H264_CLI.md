# H.264 编码续迁移：命令行入口

新增 `cmd/encode-h264`，将原始 8-bit YUV420P 文件编码为 Annex B。
第一帧 IDR，之后 P 帧；支持 CAVLC/CABAC、QP、AQ、AUD、ABR、VBV。
参数、输入验证和编码函数与文件 IO 分开，编码成功后才写输出并打印 JSON。
输入整文件加载内存，不是流式编码器；暂无 B 帧、RGB 输入和容器输出。

```sh
moon run cmd/encode-h264 -- input.yuv --width 640 --height 480 --output out.264 --cabac --aud
```

参数契约及说明见 `cmd/encode-h264/README.md`。
拒绝未知/重复/缺值选项、非法几何/QP/码率组合、空文件及截断帧。
字节平面按 Y/U/V 拆分，色度各为亮度的四分之一；全部通过纯 MoonBit
库 API 编码，C 仅作独立验证。

## 技能与 C 验证

沿用 MoonBit 全套技能中的项目布局、mbtx 自动化、API 本地查询、
保持既有接口与有效/无效输入契约测试。本轮无 OCaml 源码或 Why3
证明任务，没有引入声明式空实现或声称完成形式化证明。

按指定 `moonbit-c-binding` / `make-moonbit-c-bindings`：复核现有
私有 extern 与 `#borrow(stream)`，复用 `libx264_stub.c` 的真实
FFmpeg parser/decoder 和既有 ASan harness，未增加 ABI 或依赖。
使用既有 harness 的原因：此前已确认官方 ASan runner 与本机
mimalloc MoonBit runtime 不兼容。harness 测 C 所有权、两轮探针、
输出 blob 形状及解码，正常流 warnings/errors 均为零。
故意喂四字节短流时出现的诊断属于 harness 负例。

## 复现与验证

```sh
moon run scripts/gen_h264_cli_fixture.mbtx
moon run cmd/encode-h264 -- .scratch/h264_cli_input.yuv --width 16 --height 16 --output .scratch/h264_cli_cavlc.264 --aq --aud --target-bytes 1000
moon run cmd/encode-h264 -- .scratch/h264_cli_input.yuv --width 16 --height 16 --output .scratch/h264_cli_cabac.264 --cabac --aq --aud --vbv-maxrate 64000 --vbv-bufsize 32000 --fps 30
moon test --target wasm --no-render -p cmd/encode-h264
```

- 实际 CLI：CAVLC 232 B、CABAC/VBV 400 B，JSON 均报告三帧。
- docker nine-x264：两个 CLI 文件均被真实 FFmpeg 解码为 3×16×16；
  C probe 每流两轮均为 3 AU、3 帧、warnings=errors=0。
- 同镜像 `-fsanitize=address`、`ASAN_OPTIONS=detect_leaks=1`：退出 0。
- 同镜像 `ffmpeg -v warning -i <上述文件> -f null -`：两流退出 0，零告警。
- `moon check --target all --no-render`：退出 0，既有 v128 未使用导入警告。
- `moon fmt` / `moon info --target wasm` 已运行。
- CLI 定向回归 4/4：非法参数、空/截断帧、双熵非宏块对齐尺寸、
  多帧 Y/U/V 拆分及 AQ/AUD/ABR/VBV 组合。
- `moon check --target wasm --deny-warn --no-render`：退出 0，无警告。

上一轮 AUD 改动仍在工作树；本轮未改动编码内核，未提交。
