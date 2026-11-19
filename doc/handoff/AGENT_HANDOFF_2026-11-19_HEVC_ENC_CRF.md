# HEVC 编码器 CRF 码控交接 —— §458

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§457（12-bit，位深×色度矩阵全覆盖）

## 结果

HEVC 编码器新增**恒定速率因子 CRF**（x265 `--crf` 语义，模型与 H.264
§435 共享）：质量驱动的逐帧 QP。`hevc_encode_sequence` 与
`hevc_encode_frames` 新增可选 `crf~ : Double = -1.0`（0.0..=51.0，负值
关闭）。CRF 开启时平直 `qp` 参数被忽略；关闭路径与既有钉值**字节恒等**。
纯 MoonBit、wasm-only，无 C FFI。

验证：HEVC 编码器测试 wasm-gc **88/88**、黑盒 wasm 11/11；FFmpeg 9.0.2
零告警解出仲裁流，4 帧 framemd5 已固化黑盒。

## 模型（与 §435 同款）

```text
qp_i = round(base + 6 * (qcompress - 1) * log2(cplx_i / mean(cplx_1..i)))
```

- `base = round(crf)`；qcompress=0.6 → 每倍增复杂度 -2.4 QP；±6 饱和。
- `cplx_i` = 对上一**显示**帧的 luma SAD（隔行隔列子采样，Int32 样本
  平面，绝对尺度无关故位深无需折叠）。
- 样本先进均值再取比：位置 1 恒基线；全静态序列（均值<0.5）恒基线；
  静态帧对运动均值 +6 封顶。
- **display-causal**：样本 i 只需显示序帧 i-1 与 i → B 片编码重排
  （I0, P2, B1, ...）不影响：`hevc_enc_crf_qps` 按 display 位次一次算好，
  编码循环 `pic_qp = qps[i]`。

## 文件

- `libavcodec/hevc_enc_crf.mbt`（新）：`HevcCrf`（**priv struct**，
  `qp_for`）、`hevc_enc_crf_sad`、`hevc_enc_crf_qps`。常量（0.6/±6）就地
  内联——包白盒测试贴 V8 `__moonbit__init__` 局部上限，顶层 `let` 每个
  耗一个 init local（§435 同款约束）。
- `libavcodec/hevc_encode.mbt`：两入口 `crf` 参数（`> 51.0` →
  `hevc enc: crf must be in 0.0..=51.0`）+ 编码循环逐帧 QP。每帧本就
  携带自己的 PPS/slice QP（`hevc_enc_frame_ex` 按帧写参数集），逐帧 QP
  无需新语法通路——这是 HEVC 侧比 H.264 侧改动小的原因。

## 测试

- 白盒 `libavcodec/hevc_enc_crf_wbtest.mbt` **8/8**：
  - 手算序列精确钉值：SAD `[-, 4000, 0]` @ crf26 → `[26, 26, 32]`；
    round 半值边界 18.4→18、18.5→19；crf51+静态饱和钳 51。
  - 递增复杂度至少一帧 refine；全静态恒基线；B 重排下取值稳定。
  - crf=28 I/P/B 按 POC 对齐逐样本重建一致；crf=10 于 8/10/12-bit 往返。
  - `qp` 在 CRF 下不改一字节；`crf=-1.0` 与不传恒等；重跑恒等；
    51.5/52/100 拒绝、0.0/51.0 合法。
- 黑盒 `libavcodec/hevc_enc_crf_test.mbt` **1/1**（wasm-gc/wasm 双跑）：
  64x64、crf=28、4 帧 I/P/B（编码序 POC 0/2/1/3），MD5 对照 FFmpeg 9.0.2：

  | 输出序 | POC | slice | MD5 |
  |---|---:|---|---|
  | 0 | 0 | I | `c6111e30fdd6fedd991b7f65c8155a95` |
  | 1 | 2 | P | `e3e97fe5425cf3dd3b86c0464082ab19` |
  | 2 | 1 | B | `bd7123fb72320e6e4b2e691f8310b99a` |
  | 3 | 3 | P | `f87ee55cb7c1e9f0f9634e167515c91d` |

- 生成器 `cmd/generate-hevc-crf`：
  `moon run --target wasm-gc cmd/generate-hevc-crf <已存在目录>` 写
  `crf28_ipb.265`（4769 字节）。复跑 SHA-256 一致：
  `5d6d5777b60729e958d7a3089a8cf372f1a296806f824d736b63443824ba8425`。
- 仲裁命令（Git Bash 记得 `MSYS_NO_PATHCONV=1`）：

  ```bash
  MSYS_NO_PATHCONV=1 docker run --rm --network none \
    -v "<输出目录>:/work" --entrypoint ffmpeg linuxserver/ffmpeg:9.0.2 \
    -hide_banner -loglevel error -xerror -i /work/crf28_ipb.265 -f framemd5 -
  ```

- 运行全部 HEVC 编码器测试（在 §457 清单后追加两个 CRF 文件）：

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
    libavcodec/hevc_enc_crf_wbtest.mbt libavcodec/hevc_enc_crf_test.mbt \
    --target wasm-gc --no-render
  ```

## 本轮踩到的坑

1. **all-IDR 多帧流不能整段解码**：`ff_hevc_decode_frames_ex` 对 N 个 IDR
   会因全部 POC 0 报 `duplicate POC in a sequence`；而逐帧单独解又因
   `with_ps` 只在首帧写参数集报 `missing PPS`。位深 sweep 测试改用
   inter=true（单 IDR I/P 序列）整段解。
2. `Result` 无 `is_ok()`——用 `expr is Ok(_)` 模式断言。
3. 循环里 `crf~` 简写要求同名局部变量（§457 已踩，重申）。

## 检查状态

- `moon fmt`、`moon info` 已跑；`cmd/generate-hevc-crf/pkg.generated.mbti`
  已生成。全仓 `moon check --target wasm` 0 错误；定向 wasm-gc 仅既有
  `v128` 未使用依赖警告。

## 边界与下一步

- VBV/ABR（目标码率反馈）未实现；x265 的 cu-tree/lookahead/aq-mode 未
  引入（单一带内 SAD 复杂度）。`hevc_encode_intra_frame` 不接受 crf。
- 其余边界不变：单色、色度 SAO、B 片加权/时间 MVP/多参考、多 slice/tile、
  流式 CLI。
- 路线：**流式（逐帧推送）+ CLI → 或 VBV/ABR**。流式可参照 H.264
  `H264StreamEncoder`（§435/§436 的 crf_qp_for/scenecut 前车），CRF 的
  display-causal 性质正是流式=批式恒等的前提，已在白盒钉住。
