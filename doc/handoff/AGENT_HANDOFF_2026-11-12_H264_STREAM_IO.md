# H.264 流式宿主分块读写（§402）——native C stdio 绑定 + wasm 整文件回退

接续 §401 的剩余项「流式宿主分块读」。目标是让 `encode-h264 --stream`
在 native 上真正逐帧读、逐 AU 写，同时保持与批式路径逐字节相同；wasm
宿主没有分块文件 API，保留整文件回退。

## 实现

### native C 绑定

新增 `cmd/encode-h264/host_io_stub.c`：

- `H264HostReader` / `H264HostWriter` 用
  `moonbit_make_external_object` 分配，finalizer 关闭仍打开的 `FILE*`。
- `h264cli_reader_open` / `writer_open` 永远返回句柄；失败信息放在
  句柄的 `errmsg[256]`，由 `h264cli_*_error` 以 `Bytes?` 取出。
- 读端 `fread` 循环填满一帧：`frame_size` = 整帧，`0` = 干净 EOF，
  `0 < n < frame_size` = 截断尾帧，负值 = I/O 错误。
- 写端 `fwrite` 循环 + `fflush`，每个访问单元完成即写出；`close` 失败
  单独返回错误。
- `h264cli_reader_size` 用 `fseek/ftell` 取长度（Windows 走
  `_fseeki64`/`_ftelli64`），失败写 `errmsg`。
- 路径是 UTF-8 `Bytes`，直接作为 `const char *` 传入。

新增 `cmd/encode-h264/host_io_native.mbt`：

- 私有 `FrameReader` / `FrameWriter` 外部对象与 `extern "c"` 声明；
  路径、句柄、读写缓冲全部 `#borrow`。
- `open` 后检查 `error`，`size` / `read` / `write` / `close` 把 C 状态
  转成 MoonBit `raise`。
- `read` 返回 `Bytes?`：整帧 / `None`；截断或 I/O 错误直接 `fail`。

### wasm/js 回退

新增 `cmd/encode-h264/host_io_wasm.mbt`，暴露同名
`FrameReader` / `FrameWriter`：

- `FrameReader` 持有整文件 `Bytes` 与游标，`read` 按帧切片。
- `FrameWriter` 把 AU 追加到 `Array[Byte]`，`close` 时
  `@fs.write_bytes_to_file` 一次写出。
- 路径在公共边界统一编码为 UTF-8 `Bytes`，wasm 侧再
  `@utf8.decode_lossy` 交给 `@fs`。

### CLI 接线

`cmd/encode-h264/options.mbt`：

- 新增 `frame_planes` 与 `open_stream_encoder`，批式/流式共用，保证
  平面切分与编码配置逐字一致。
- 新增 `encode_stream_file(opts)`：
  1. 打开 reader，先校验 `size > 0 && size % frame_size == 0`，
     失败时**不创建输出**；
  2. 打开 `H264StreamEncoder` 与 writer；
  3. 逐帧 `read → push_frame → drain → write`，`finish` 的尾 AU 同样
     立即写出；
  4. 返回 `(帧数, 写出字节数)`。
- 原 `encode_raw_stream` 移到 `options_wbtest.mbt`，只作为编码器流式
  契约的测试 oracle。

`cmd/encode-h264/main.mbt`：`--stream` 改调 `encode_stream_file`；批式
路径仍是「整文件读 → 编码 → 写文件」。摘要 `bytes` 改用流式计数，
JSON 键与顺序不变。

`cmd/encode-h264/moon.pkg`：

```moonbit
options(
  "native-stub": [ "host_io_stub.c" ],
  targets: {
    "host_io_native.mbt": [ "native" ],
    "host_io_wasm.mbt": [ "wasm", "js" ],
  },
)
```

## 验证

- `moon check --target wasm --deny-warn --no-render`：干净。
- `moon test --target wasm cmd/encode-h264 --no-render`：**16/16**。
  新增 `host_io_wbtest.mbt` 5 项：
  1. 分块宿主路径与批式编码逐字节相同（CABAC + AUD + B slices，5 帧）；
  2. reader 整帧读取 + 干净 EOF；
  3. reader 拒绝截断尾帧；
  4. 坏输入长度不创建输出文件；
  5. 目录作输出时报错。
- Docker `ffmpeg-moonbit-ffref:nine-x264` 内：
  `moon test --target native cmd/encode-h264 --target-dir /tmp/mbuild`
  **16/16**（C 桩参与编译和执行）。
- 端到端 192×128×3 真实 YUV（CABAC + AUD + B slices）：
  native 批式、native `--stream`、wasm 批式三份输出 SHA-256 全为
  `e5fba9495daf185e7e657e9ce894d7ab7aec8c911acf7125f26bc82449a72fd9`，
  摘要均 11231 B / 3 帧。

## 限制与后续

- wasm/js 仍整文件缓冲（宿主 API 限制）；native 是真正常量内存。
- native `--stream` 编码中途失败会留下已写出的前缀；输入长度错误在
  创建输出前拒绝。
- 剩余项：B 线各 opt-in 转正（`b_slices`/`b_parts`/`intra_in_b`/
  `intra4x4_in_b`/`dct8x8`/`cabac_rd`）、`H264EncStats` B-intra 计数
  口径。
- ASan（后补，同日）：`asan_host_io_probe.c` 沿 §391 mock 运行时符号
  方案直连 C 桩，finalizer 真执行、`mock_gc` 统一释放 mock 分配；
  Docker 内 `detect_leaks=1` 一轮全清（首轮 2 处失败均为探针自身
  bug，C 桩零改动）。复现：
  ```sh
  cc -fsanitize=address -g -O1 -I/root/.moon/include \
    cmd/encode-h264/host_io_stub.c cmd/encode-h264/asan_host_io_probe.c \
    -o /tmp/asan_host_io && \
  mkdir -p /tmp/asio && \
  ASAN_OPTIONS=detect_leaks=1:fast_unwind_on_malloc=0 \
    /tmp/asan_host_io /tmp/asio
  ```
- `moon check --target js` 仍被历史遗留的 `libavutil/moon.pkg` 中
  `v128` unused_package 拦住（与 §402 无关）；本包 wasm 检查干净。

## 当前工作区状态（未提交）

本轮改动均在 `cmd/encode-h264`、`README.md`、`doc/PORTING_HISTORY.md`
和本交接文档，**尚未 commit/push**：

```text
 M doc/PORTING_HISTORY.md
 M README.md
 M cmd/encode-h264/README.md
 M cmd/encode-h264/main.mbt
 M cmd/encode-h264/moon.pkg
 M cmd/encode-h264/options.mbt
 M cmd/encode-h264/options_wbtest.mbt
?? AGENT_HANDOFF_2026-11-12_H264_STREAM_IO.md
?? cmd/encode-h264/host_io_native.mbt
?? cmd/encode-h264/host_io_stub.c
?? cmd/encode-h264/host_io_wasm.mbt
?? cmd/encode-h264/host_io_wbtest.mbt
?? cmd/encode-h264/asan_host_io_probe.c
```

已执行 `moon fmt cmd/encode-h264`（仅本包）与
`moon info --target wasm`；`pkg.generated.mbti` 无变化（新增符号均为
私有）。仓库内无 `*.tmp` 遗留；端到端验证文件在仓库外的
`%TEMP%\opencode\eh264`。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm cmd/encode-h264 --no-render
moon fmt cmd/encode-h264
moon info --target wasm

MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native cmd/encode-h264 --target-dir /tmp/mbuild"
```
