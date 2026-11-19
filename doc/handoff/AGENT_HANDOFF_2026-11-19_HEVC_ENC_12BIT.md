# HEVC 编码器 12-bit 交接 —— §457

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§456（4:2:2 / 4:4:4 Range Extensions）

## 结果

HEVC 编码器新增 **12-bit**（Range Extensions），位深 × 色度格式矩阵至此
全覆盖：{8,10,12} × {4:2:0, 4:2:2, 4:4:4} 九种组合全部可用（12-bit ×
任意格式均走 Rext）。贯通既有 I/P/B、整数及 1/4 像素运动补偿、量化/
反量化、去块滤波和 SAO。纯 MoonBit、wasm-only，无 C FFI。默认 8-bit 与
既有 8/10-bit 黑盒钉值不变。

验证：HEVC 编码器测试 wasm-gc **79/79**、黑盒 wasm **10/10**；FFmpeg 9.0.2
在 `-loglevel error -xerror` 下零告警解出外部仲裁流，ffprobe 确认
`profile=Rext`、`pix_fmt=yuv420p12le`，4 帧 framemd5 已固化到公开 API 黑盒
测试。

## 改动面（极小——这正是选它做切片的原因）

1. **PTL**（`libavcodec/hevc_encode.mbt` 的 `hevc_enc_ptl`）：
   - `rext = chroma_format_idc != 1 || bit_depth > 10`：Main/Main10 只覆盖
     到 10-bit 4:2:0，**12-bit 即使 4:2:0 也必须宣告 Rext（profile_idc=4）**。
   - `max_10bit_constraint_flag` 从硬编码 1 改为 `if bit_depth <= 10`：
     12-bit 流不得宣称 10-bit 解码器可解。`max_12bit` 恒 1，其余约束位
     沿用 §456 的按格式推导。
2. **守卫**（`hevc_enc_guard_frame`）：接受 12，错误消息改为
   `hevc enc: bit_depth must be 8, 10 or 12`。§455 main10 白盒钉住旧消息
   的断言已同步。
3. **零改动部分**：量化/反量化（`hevc_enc_quant_val`/`hevc_enc_recon_transform`
   以 `bd` 为参数）、deblock beta/tc（按 `bit_depth - 8` 缩放）、MC 的
   `ox << (bd - 8)`、clip 上界 `(1 << bd) - 1`、色度 QP 表在解码侧本就
   全部经 `sps.bit_depth` 通用；`qp_bd_offset = 6*(12-8) = 24` 由参数集
   往返自动得到，本地重建的 `qp + qp_bd_offset` 关系原样成立。QP 40 时
   反量化 QP=64（scale 移位 qp/6=10），白盒 QP sweep 覆盖。

## 坑

- Git Bash 下 docker `-v` 与 `-i /work/...` 会被 MSYS 路径改写劫持成
  `D:/Program Files/Git/work/...`，命令前加 `MSYS_NO_PATHCONV=1`。
- 测试闭包/循环里对可选参数用 `label~` 简写要求**同名局部变量**存在；
  循环变量叫 `bad` 时必须写 `bit_depth=bad`。

## 测试

- 白盒 `libavcodec/hevc_enc_12bit_wbtest.mbt` **7/7**：
  SPS/PTL 往返（profile_idc=4、compat 只置第 4 位、max_10bit=0、
  qp_bd_offset=24、yuv420p12le、默认字节不变、与 Main10 PTL 字节不同）、
  422/444 组合的 max_422chroma/max_420chroma 交互、I 帧 QP 12/26/40 往返
  （含 >1023 样本断言）、非 CTB 对齐 48x40、I/P/B 平移（分数像素 MC）
  按 POC 对齐、422/444 12-bit intra 往返、非法位深 9/11/14。
- 黑盒 `libavcodec/hevc_enc_12bit_test.mbt` **1/1**（wasm-gc 与 wasm 都跑）：
  64x64、QP26、4 帧 I/P/B（编码序 POC 0/2/1/3 = I/P/B/P），本仓库解码
  `yuvp(12)` 16-bit LE 平面 MD5 对照 FFmpeg 9.0.2 framemd5：

  | 输出序 | POC | slice | MD5 |
  |---|---:|---|---|
  | 0 | 0 | I | `692d2ea8220b68a8bb80edb0c5a9ce4a` |
  | 1 | 2 | P | `42a798df129a2e6537937b291f6000f8` |
  | 2 | 1 | B | `1befb89dd7c6b45095fe184f6bf7932d` |
  | 3 | 3 | P | `fda6dc07783d5c6e07a29a25c4e4f0ea` |

- 生成器 `cmd/generate-hevc-12bit`：
  `moon run --target wasm-gc cmd/generate-hevc-12bit <已存在目录>` 写出
  `main12_ipb.265`（43028 字节）。复跑 SHA-256 一致：
  `08b3fc4694cd6c87f448e33373ec2c3667c1b5132a5dfdf4ed44967ca541aa40`。
- 仲裁（Git Bash 记得 `MSYS_NO_PATHCONV=1`）：

  ```bash
  MSYS_NO_PATHCONV=1 docker run --rm --network none \
    -v "<输出目录>:/work" --entrypoint ffmpeg linuxserver/ffmpeg:9.0.2 \
    -hide_banner -loglevel error -xerror -i /work/main12_ipb.265 -f framemd5 -
  ```

- 运行全部 HEVC 编码器测试：

  ```bash
  moon test libavcodec/hevc_enc_cabac_wbtest.mbt \
    libavcodec/hevc_enc_dct_wbtest.mbt \
    libavcodec/hevc_enc_residual_wbtest.mbt \
    libavcodec/hevc_enc_i_test.mbt libavcodec/hevc_enc_p_test.mbt \
    libavcodec/hevc_enc_i_wbtest.mbt libavcodec/hevc_enc_p_wbtest.mbt \
    libavcodec/hevc_enc_main10_wbtest.mbt \
    libavcodec/hevc_enc_main10_test.mbt \
    libavcodec/hevc_enc_422_wbtest.mbt libavcodec/hevc_enc_444_wbtest.mbt \
    libavcodec/hevc_enc_422_test.mbt libavcodec/hevc_enc_444_test.mbt \
    libavcodec/hevc_enc_12bit_wbtest.mbt libavcodec/hevc_enc_12bit_test.mbt \
    --target wasm-gc --no-render
  ```

## 检查状态

- `moon fmt`、`moon info` 已跑；`cmd/generate-hevc-12bit/pkg.generated.mbti`
  已生成。
- 全仓 `moon check --target wasm` **0 错误**（此前 handoff 报告的
  `cmd/encode-h264` 阻断已不复现）；定向 wasm-gc 仅既有 `v128` 未使用
  依赖警告。

## 边界与下一步

- 单色（`chroma_format_idc=0`）仍未开放（守卫拒绝 0；开放需要 n_cb/cbf/
  去块/SAO 的空色度链路单独处理）。
- 色度 SAO 仍关闭（`slice_sao_chroma_flag=0`）；B 片仍限 2Nx2N、
  `b_slices=true` opt-in；加权双向预测、时间 MVP、多参考帧索引未实现。
- 每帧仍单 slice、单 tile；码控（CRF/VBV）、流式 CLI 未实现。
- 路线：**码控（CRF/VBV）→ 流式 + CLI**（见 doc/PORTING_HISTORY.md §457
  末尾）。
