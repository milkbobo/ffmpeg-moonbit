# H.264 §414 统一视频编码门面——交接文档

接续 `doc/handoff/AGENT_HANDOFF_2026-11-14_H264_WEIGHTP_DEFAULT.md`（§413 已交付）。
本片实现 §410 交接「下一片候选」第 3 项：**统一播放门面（`VideoEncoder`
抽象 + CLI 整合）**——纯字节保真转发层，零码流变化。

## 这一片做了什么

### 1. `libavcodec/video_encoder.mbt`（新）

- `pub(all) enum VideoCodec { H264 }` + `name()` + `default()`——未来
  编码器加 case 即接入，配置面与 CLI 不动。
- `pub(all) struct VideoEncConfig`：19 字段（几何/QP/熵/特性/率控），
  `::new` 默认 = §403/§413 序列默认。单入口特有项（`pcm_first`、
  `intra_in_p`、`level_idc`、`vbv_init`…）不进 config，文档指回直连入口。
- `VideoEncoder` 流式门面：`open(codec~, config~, stats?)` +
  `push_frame/drain/finish` + 报告访问器（`codec_name/pixel_format/
  width/height`）；率控流式拒收（CLI 的 `--stream` 排他规则上移入库）。
- `video_encode(frames, codec~, config~, recon?, stats?)` 批式分发：按
  `config.cabac` 转发 `h264_encode_frames(_cabac)`，逐参数一致（率控
  支持），字节保真由测试钉住。

### 2. CLI 整合（`cmd/encode-h264`）

- 新 `--codec h264` 旗标（默认 `VideoCodec::default()`，未知值拒收）。
- `video_config(opts)`：Options → `VideoEncConfig` 单点。
- `encode_raw` 双熵 if/else 两段 18 参数调用收敛为一行 `video_encode`；
  `open_stream_encoder` 返回门面；批式/流式字节不变（17 项既有测试即证）。
- `pixel_format_name` 上移 `@codec.video_pixel_format`；summary JSON 的
  `"codec"` 改 `opts.codec.name()`。

### 3. 可见性坑（新增工具坑入档）

`pub enum` / `pub struct` 外部**只读不可构造**（blackbox 测试构造报
`E4036 Cannot create values of the read-only type`）；跨包可构造必须
`pub(all)`（libavformat `MediaType`/`StreamInfo` 先例）。取舍：
`VideoCodec`/`VideoEncConfig` 用 `pub(all)`（外部要构造与 `{ ..cfg }`
更新）；`VideoEncoder` 保持 `pub`（外部只能 open——封装正确）。

### 4. 测试（门面 5 + CLI 1）

门面批式==直连（双熵 B-GOP）、率控三腿逐字节、流式三重一致（门面 ==
H264StreamEncoder == 批式）、像素格式命名 + 10-bit 过门面（profile 110）、
错误面（流式+率控拒收 / bad depth / 奇数几何透传）；CLI --codec 解析、
拒收与门面路由字节一致。

## 验证矩阵

| 项 | 命令 | 结果 |
| --- | --- | --- |
| wasm 类型检查 | `moon check --target wasm --deny-warn --no-render` | exit 0 干净 |
| wasm 全族+CLI | 18 h264 文件 + video_encoder_test + cmd | **159/159** |
| 接口 | `moon info --target wasm` | 门面进公开面（mbti 本地生成物） |

纯转发层无码流变化，无需 docker 仲裁（§413 的 framemd5/ffref 结论不受影响）。

## 遗留与下一片候选

1. 码控深化（ME/RD 细化）或 High 4:2:2/4:4:4 + 12/14-bit（大改）。
2. 未来第二个视频编码器接入时：加 `VideoCodec` case + CLI 值空间扩展即可。
3. x264 native oracle 8 项继续冻结（native-only 约定）。
4. B 帧显式/隐式权重未接（§410 边界 5，需要先改 GOP 形状才有收益）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/video_encoder_test.mbt --no-render
moon test --target wasm cmd/encode-h264 --no-render
```
