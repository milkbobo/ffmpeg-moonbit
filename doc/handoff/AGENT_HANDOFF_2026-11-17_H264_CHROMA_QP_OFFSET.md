# H.264 编码器 §432 交接文档 — PPS chroma QP offset（Cb/Cr 色度 QP 偏移）

日期：2026-11-17
上游参考：x264 `chroma-qp-offset`（Cb/Cr 共用一个偏移值）

---

## §0 本次交接范围与结论

实现纯 MoonBit H.264 编码器的 **PPS chroma QP offset**：Cb 与 Cr 共用一个
`Int32` 偏移值（范围 -12..12），写入 PPS 的 `chroma_qp_index_offset` 与
`second_chroma_qp_index_offset` 两个字段。默认 0 保持逐字节不变；解码器
`h264_get_chroma_qp` 已从解析后的 PPS 读取偏移，编码器各站点无需额外改动。

**结论**：实现完成、编译通过（`moon check --target wasm --deny-warn` 0/0）、
`h264_enc_chroma_qp_test` 8/8 通过、核心 h264 编码器测试 86/86 通过。
未提交（用户未点名）。

---

## §1 接口与文件清单

### 新增文件
- `libavcodec/h264_enc_chroma_qp_test.mbt` — 黑盒测试，8 个用例。

### 修改文件（按职责分组）

**PPS 写端**：
- `libavcodec/h264_enc_ps.mbt` — `h264_enc_pps_body` / `h264_enc_pps_rbsp` /
  `h264_enc_write_pps` 新增 `chroma_qp_offset~ : Int32 = 0`，两个 `put_se(0)`
  改为 `put_se(chroma_qp_offset)`。
- `libavcodec/h264_enc_cabac.mbt` — `h264_enc_pps_rbsp_cabac` 同样处理。

**intra 入口**：
- `libavcodec/h264_encode.mbt` — `h264_encode_intra_frame` 加 param + 范围校验。
- `libavcodec/h264_enc_cabac.mbt` — `h264_encode_intra_frame_cabac` 同上。

**batch 入口**：
- `libavcodec/h264_encode_p.mbt` — `h264_encode_frames` / `_vbv` / `_qps`
  加 param、校验、透传。
- `libavcodec/h264_encode_b.mbt` — `h264_encode_frames_b` 加 param、校验、透传。
- `libavcodec/h264_enc_cabac.mbt` — `h264_encode_frames_cabac` / `_cabac_vbv` /
  `_cabac_qps` 加 param、校验、透传。

**流式**：
- `libavcodec/h264_enc_stream.mbt` — `H264StreamEncoder` 加 `chroma_qp_offset`
  字段；`open()` 加 param + 校验；`stream_idr` / `stream_i` 透传。VBV 文件
  无需改（`self` 继承）。

**门面/CLI**：
- `libavcodec/video_encoder.mbt` — `VideoEncConfig` 加 `chroma_qp_offset`
  字段（`new` 默认 0），`video_encode` 透传。
- `libavcodec/video_encoder_periodic.mbt` — 3 处调用透传。
- `cmd/encode-h264/options.mbt` — `--chroma-qp-offset` 选项 + 解析 + 校验。
- `cmd/encode-h264/main.mbt` — 帮助行。

### 公共参数签名

所有新增参数均为 `chroma_qp_offset~ : Int32 = 0`（带默认值，缺省逐字节不变）。
越界（<-12 或 >12）返回
`Err("h264 enc: chroma_qp_offset must be in -12..=12")`。

---

## §2 实现要点

1. **只改 PPS 写字段**：编码器侧唯一实质改动是把 PPS 里两个原本写 0 的
   `put_se(0)` 换成 `put_se(chroma_qp_offset)`。色度量化由
   `h264_get_chroma_qp(qp, pps)` 在宏块级读取 PPS 偏移后计算，编码器传
   `qp` 不变。
2. **Cb/Cr 共用一值**：对齐 x264 语义，`chroma_qp_index_offset` 与
   `second_chroma_qp_index_offset` 写同一个值。未来如需分离可扩为两个
   参数，目前不做。
3. **全链接线**：intra / batch（CAVLC+CABAC）/ VBV / ABR / 流式 / 门面
   / CLI 全部透传，每层都做范围校验。流式 `H264StreamEncoder` 把值存
   在 struct 字段里，`stream_idr` / `stream_i` 从 `self` 读取。
4. **缺省逐字节不变**：所有参数默认 0，且 `put_se(0)` 与原本的
   `put_se(0)` 字节相同，故存量流不受影响。

---

## §3 测试与验证

`libavcodec/h264_enc_chroma_qp_test.mbt`，8 个用例：

| # | 用例 | 验证点 |
|---|------|--------|
| 1 | 默认 offset 字节一致 | offset=0 与省略参数逐字节相等 |
| 2 | CAVLC intra chroma-only | offset 0/6/12 的 luma 逐字节相同、chroma 两两不同 |
| 3 | CABAC intra chroma-only | 同上 |
| 4 | PPS 字段回读 | 自写 start-code 扫描器 + SPS/PPS 解码器回读两字段 |
| 5 | 越界拒收 | ±13 在 intra/batch/流式/门面四处均返回 Err |
| 6 | batch P chroma 变化 | offset 0 vs 6 解码帧数相同、每帧 chroma 不同 |
| 7 | 流式=批式 | 同参输出逐字节相等 |
| 8 | 门面透传 | `VideoEncConfig.chroma_qp_offset` 影响编码结果 |

**验证命令**：
```
moon test libavcodec/h264_enc_chroma_qp_test.mbt --target wasm --no-render
# Total tests: 8, passed: 8, failed: 0.

moon check --target wasm --deny-warn --no-render
# 0 错 0 警
```

核心 h264 编码器回归 86/86 通过（`h264_enc_cabac_test` / `h264_enc_b_test` /
`h264_encode_test` / `h264_encode_p_test` / `video_encoder_test` /
`h264_enc_stream_test` / `h264_enc_periodic_b_test` / `h264_enc_rc_test` /
`h264_enc_vbv_test` / `h264_enc_cabacrd_test` / `h264_enc_b_gop_test`）。

---

## §4 已知边界与遗留

1. **QP 0 非无损**：H.264 QP 0 的量化步非零，luma 重建与源不逐字节相等。
   测试用 offset 间互相比对而非与源比对。
2. **负 offset 在低 QP 下夹零**：chroma QP index = `qp + offset`，低于 0 时
   解码器夹到 0。故 QP 0 下 offset -6 与 offset 0 产出相同 chroma。测试
   用 0/6/12 三个非负 offset 避免此问题。
3. **P/B 帧 luma 可能受 chroma offset 影响**：intra 下 luma 与 chroma
   offset 逐字节无关；但 P/B 帧的 inter 决策可能把 chroma 代价耦合进
   luma 模式选择，故 batch 测试只断言 chroma 不同、不断言 luma 相等。
   这是编码器行为，非 bug。
4. **未做 docker ffmpeg 外部仲裁**：本功能不改变流结构（只改 PPS 两个
   SE 字段），且解码器 `h264_get_chroma_qp` 已验证读取正确，故未跑
   docker framemd5 钉值。如需可补。

---

## §5 给下一位 Agent 的操作建议

1. **跑全量回归**：剩余 56 个 `*_test.mbt` 尚未逐个跑（只跑了核心 11 个
   共 86 项）。建议前台小批（≤9 文件/批）跑完，核对 `^F:` 与
   `failed: [1-9]`。
2. **补 docker 仲裁（可选）**：用一条带 `--chroma-qp-offset 6` 的 6 帧
   流送 docker ffmpeg 9.0.2 解码，确认零告警且 framemd5 与本解码器
   filtered 输出一致。如要钉值，把 framemd5 写进测试。
3. **Cb/Cr 分离（未来需求）**：x264 实际上 Cb/Cr 可分别设 offset
   （`chroma-qp-offset` 是两者共用，`--chroma-qp-offset` 只设 Cb，
   `--crf` 模式下另有 `--cr-crf`）。当前实现两者共用，如需分离需扩
   `chroma_qp_offset` 为元组或加第二个参数。

---

## §6 未完成项与风险

| 项 | 状态 | 风险 |
|----|------|------|
| 全量 56 文件回归 | 未跑 | 低（参数带默认值，存量调用不受影响） |
| docker ffmpeg framemd5 钉值 | 未做 | 低（只改 PPS 两字段，解码器已验证） |
| moon info | 未跑 | 无（仅信息输出） |

**不提交**，等用户确认。

---

## 附录 A：MoonBit 语言坑（本次踩过）

- 结构体字面量在黑盒测试里须用 `{ ..@libavcodec.VideoEncConfig::new(...), field: v }`
  展开语法，不能裸写字面量。
- `Bytes` 无 `concat` / `empty` / `slice` 方法；拼接用 `Array[Byte]` 逐字节
  push 再 `Bytes::from_array(arr[:])`；切片用 `bytes.to_array()[start:end]`。
- `Array` 无 `.slice()` 方法，用 `[start:end]` 切片语法。
- 带 `raise` 的函数须显式写返回类型（`-> Unit raise` 或 `-> T raise`），
  否则报 `E4074 Missing type annotation`。
- `test "name" { ... }` 是块语法，不是 `test("name", fn)` 函数调用。
- `for i in 0..<n` 是正确循环语法，`for i = 0; i < n; i = i + 1` 不被支持。
- `H264EncodedFrame` 未实现 `Eq`，不能 `assert_eq(result, Err(msg))`，
  须 `match { Err(e)=>assert_eq(e,msg); Ok(_)=>fail }`。
- `H264ParamSets` 的 PPS 存在 `pps_list : Array[H264Pps?]`，不是 `.pps`
  字段；须遍历找第一个 `Some`。
- `ff_h264_decode_seq_parameter_set` 第三参数是 `ignore_truncation : Bool`，
  不是 bit 长度。
