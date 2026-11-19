# HEVC 流式 ABR 码率控制交接 —— §462

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§461（SAO EO，未提交）；§447-§459 在 733d1f8/37223d7

## 结果

HEVC 流式编码器新增 **ABR 码率控制**（`target_bitrate~ : Int32 = 0` +
`fps~ : Int32 = 0`）：单 pass QP 反馈控制器，模型与 H.264 §422f 共享
（`h264_rc_qp_jump` 同包直接复用——"每 +6 QP 尺寸减半"的整型搜索、
三帧窗阻尼、+1..+3 步钳制、**只升不降**）。零新码流语法；默认关闭字节
恒等。CLI `--target-bitrate N --fps N`。纯 MoonBit、wasm-only。

验证：HEVC 编码器测试 wasm-gc **109/109**；FFmpeg 9.0.2 `-xerror` 零
告警仲裁钉黑盒；生成器复跑字节确定。

## 控制器（libavcodec/hevc_enc_stream.mbt）

```
budget = target_bitrate / fps
ahead  = abr_bits − budget × abr_pics     // 累计超支
corr   = clamp(qp_jump(ahead, budget×3), 1, 3)   // 超支才升
qp_next = clamp(abr_qp + corr, 0, 51)     // abr_qp = 上一接受帧 QP
```

- `push_frame`：ABR 开启时 QP 建议替换 flat（CRF 在 open 互斥拒绝）；
  pending B park 时的建议值随帧暂存，编码序计入。
- `code_picture`：帧接受后 `abr_note(annexb_bits, qp)`——所有路径
  （I/P/B/尾 P）统一。
- 校验：`target_bitrate > 0` 需 `fps > 0`、与 `crf >= 0` 互斥、
  `target/fps >= 1`、非负。

## 测试与仲裁

- 白盒 `hevc_enc_abr_wbtest.mbt` **3/3**：紧预算上限性质（ABR 流 ≤
  平坦流）+ 可解全 POC；宽预算字节恒等平坦；B 调度组合；四组拒绝 +
  fps 单独合法。
- 黑盒 `hevc_enc_abr_test.mbt` **1/1** 双目标：4 帧 B 调度 60 kbit/s@30
  qp22（5382 字节）MD5 `564d84ed…`/`51f8f0b4…`/`e5f4cd35…`/`0db1e6a0…`。
- 生成器写 `abr_ipb.265`，SHA-256
  `653d4b9131995f5d711cf6ee691527fb1a8f0dacf6b37f7177e583ab017496cc`。

## 本轮坑

- `Array::fold` 的 init 是**标签参数**（`fold(init=0, …)`），位置传参
  报 Unit Add——手写累计循环最稳。
- `for label, x in [tuple…]` 是 index/value——解构要括号。

## 检查状态

`moon fmt`/`moon info` 已跑；全仓 `moon check --target wasm` 0 错误；
CLI options 2/2。

## 边界与下一步

- 无 CPB/HRD 流级语法（H.264 VBV 的 VUI HRD/filler NAL/buffering SEI
  未做）；QP 单 pass 只升。批式入口（`hevc_encode_sequence`）无 ABR
  （流式专属，与 H.264 同构）。
- 剩余：**单色（cfidc=0）**、HEVC 完整 CPB/VBV、B 片加权/时间 MVP/
  多参考、多 slice/tile。
- §460/§461/§462 均未提交（与 733d1f8/37223d7 衔接）。
