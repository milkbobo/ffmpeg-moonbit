# H.264 编码器侧显式加权预测（§410）——交接文档

接续 `AGENT_HANDOFF_2026-11-13_H264_BLINE_CLOSE.md`（B 线 §405–§409 收口已完成）。
本文交付 §410：P 切片显式加权（`weightp`，`weighted_pred_flag = 1`），并记录
一条**继承欠账**（12 项陈旧测试，非本片引入）与下一片入口。

## 这一片做了什么

### 选片

先评估「B 隐式权重（`weighted_bipred_idc = 2`）」再放弃：本编码器 GOP 是
`I,P2,B1,P4,B3…`、`poc_lsb = display * 2`，每个 B 恰在两参考中点，
`h264_b_mc.mbt::mc_part_weighted` 的隐式推导恒得 `scale = 32` /
`implicit0 = 32`（中性），几乎没有收益。转做 **P 显式加权**——fade
（淡入/淡出、增益变化）场景有真实收益，且 x264 默认 `weightp` 开，是
实质缺口（本仓编码器 PWT 此前一直硬写 0）。

### 实现

新文件 `libavcodec/h264_enc_weight.mbt`：

| 函数 | 职责 |
| --- | --- |
| `h264_enc_plane_weight` | 最小二乘 `dst ≈ (w / 2^denom) * src + o`，Int64 累加（1080p Σs² 可达 1.4e11）；平坦/退化参考（`nΣs² − (Σs)² <= 0`）退化为中性权重但仍拟合 offset；w 夹 0..127、o 夹 −128..127 |
| `h264_enc_div_round` | Int64 半数远离零 |
| `h264_enc_fit_p_weight` | `denom = 5`，Y/U/V 三平面各拟合；`use_weight` / `use_weight_chroma` 只在「偏离中性表」时置位（与解码器 `h264_slice.mbt` 同门控） |
| `h264_enc_put_pwt` | 写 `pred_weight_table()`：两个 denom + luma flag/pair + 单个覆盖两分量的 chroma flag |

接线（8 个既有文件 + 1 个新测试白盒文件）：

- `H264PEncoder` 增 `weightp : Bool` / `pwt : H264PredWeight`；5 处结构体
  字面量补齐（`h264_encode_p.mbt` CAVLC 序列、`h264_encode_b.mbt`
  `new_p_encoder` + B 帧 `b_enc`（写死 `false`）、`h264_enc_cabac.mbt`
  CABAC 序列、`h264_enc_stream.mbt` `stream_p`/`stream_b`）。
- `encode_p_frame` / `encode_p_frame_cabac` 帧首拟合（可见区
  `self.p.width/height`）；PWT 写在 `ref_pic_list_modification_flag_l0`
  之后、`adaptive_ref_pic_marking_mode_flag` 之前（FFmpeg
  `h264_slice.c:1841` 读 PWT、`:1853` 读 marking；本仓解码器
  `h264_slice.mbt:251` 同序）。
- `mc_into_rec` 末尾按矩形套 `h264_weight_rect`（luma + U + V）——skip 与
  16x16/16x8/8x16/8x8 全部分区都经此入口，一处注入全覆盖。
- PPS：`h264_enc_pps_body` / `h264_enc_pps_rbsp_cabac` / `h264_enc_write_pps`
  增 `weightp~`（默认 0，旧字节不变）。
- 参数贯通：`h264_encode_intra_frame(_cabac)`、`h264_encode_frames(_qps/_b/
  _cabac/_cabac_qps/_vbv/_vbv_cabac)`、`H264StreamEncoder::open`（18 处内部
  调用点）。
- CLI：`--weightp` / `--no-weightp`，`open_stream_encoder` 与 `encode_raw`
  的 CAVLC/CABAC 两处透传。

### 测试期修掉的两个真缺陷（最有价值产出）

1. `H264StreamEncoder::open` 构建 `pps_raw` 时**漏传 `weightp~`**：流式
   PPS 声明 `weighted_pred_flag = 0` 而 P 切片带 PWT —— 自相矛盾的流。
2. `stream_idr` 调 `h264_encode_intra_frame(_cabac)` **漏传 `weightp`**：
   IDR 自带的 SPS/PPS 前言仍写 0（PPS 第 17 字节 206 vs 207，差一位即该
   flag）。

修好后流式与批式同参输出**逐字节一致**（测试 ⑥ 钉住）。

## 验证矩阵（本次实际跑到的）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| wasm 类型检查 | `moon check --target wasm --deny-warn --no-render` | exit 0，干净 |
| 新黑盒 | `moon test --target wasm libavcodec/h264_enc_weightp_test.mbt` | **6/6**（含 6 帧 framemd5 pin） |
| 流式 | `moon test --target wasm libavcodec/h264_enc_stream_test.mbt` | **8/8** |
| CLI | `moon test --target wasm cmd/encode-h264 --no-render` | **16/16** |
| 新白盒 | `moon test --target wasm-gc -p …/libavcodec -f "h264 enc weight*"` | **4/4**（wasm 二进制 `local count too large` 属该包既有状态） |
| 接口 | `moon info --target wasm` | 无 `.mbti` 变化 |
| docker native 全族 | `moon test --target native -p …/libavcodec -f 'h264*'` | **362 项 / 350 过 / 12 失败（全部继承，见下）** |
| x264 native oracle | `moon test --target native -p …/libavcodec/x264` | **38 项 / 30 过 / 8 失败（全部继承，见下）** |
| C 仲裁 | `ffmpeg -f h264 -i wp_fade.h264 -f framemd5` | 零告警，六帧哈希与自家 filtered 解码逐一相同 |

`moon check --target all --warn-list +73` **未通过**：本仓 js/native 面既有
`[4024]/[4014]` 诊断与 `@fs.` 注解告警（与本片无关）；本片沿用项目既有
wasm-only 检查口径。`scripts/run-asan.py` 与本仓 §391 的 mock 运行时方案不
适配；本片**未改动任何 C 侧代码**（`ffi.mbt`/`x264_wrapper.c` 零改动），
ASan 基线沿用 §403 的定向 harness 结论。

## 量化收益（钉在测试里的数字）

| 夹具 | 关 | 开 | 备注 |
| --- | --- | --- | --- |
| 96×64 fade 6 帧 QP26（`b_slices=false`） | 9686 B / MAE 11 | **7335 B / MAE 10** | −24.3%；5 个 P 帧 recon 与 `skip_lf=false` 解码 md5 逐帧相等 |
| 纯增益 2 帧 QP30 | 3386 B / MAE 4 | 3323 B / MAE 3 | 断言为「加权必须优于不加权」 |
| CABAC fade 5 帧 QP26 | 更大 | 更小 | 5 个 P 帧 recon 不变式 |
| 默认 B-GOP 6 帧 QP26 | 10025 B | 8013 B | 6 画面全解码 |
| 流式 vs 批式 | — | 6436 B | md5 完全一致 |

C 仲裁钉住的六帧哈希（`h264_enc_weightp_test.mbt` 内）：

```
a89bd6379ca72e67b8593d4546f172f8
70ad49b3f0d98ddb494fd8c90a94581f
f3e840210eea8690dc4ab5b427e41906
1a7e01b35ddb423598c496c140958b44
936394915bdfc14a978b98a002efe77d
6d8751612c86016c73ccff7189362006
```

复跑外部仲裁：把测试里的 `WPARB:` 十六进制转回
`%TEMP%\wp_fade.h264`，然后

```sh
$env:MSYS_NO_PATHCONV='1'
docker run --rm -v "$env:TEMP:/data" --entrypoint /bin/sh \
  ffmpeg-moonbit-ffref:nine-x264 \
  -c 'ffmpeg -hide_banner -nostdin -f h264 -i /data/wp_fade.h264 -f framemd5 /data/wp_ff.md5'
```

## 继承欠账（非本片引入，必须下一片处理）

用 `git worktree` 在改动前基线 `955d35c` 复跑同一命令，失败项**逐条逐值
相同**（含 `RD luma PSNR 19.544714063430735 dB` 这种精确值），因此确认是
§406 六开关转正后**未重钉的陈旧断言**，本片零回归：

- `h264_encode_p_test.mbt`（4）：移动场景 MAD 门、两处 `expect` 六帧快照、
  RD 工作点 PSNR 地板 40.5 dB（实际 19.54 —— 六帧按解码序比对而 B 已默认
  开启，需按 `I,P2,B1,P4,B3,P5` 映射回显示位）。
- `h264_encode_p_intra_test.mbt`（4）、`h264_encode_dct8_test.mbt`（4）：
  「8x8 流与默认流相同」在 `dct8x8` 转正后语义反转；「未选 Intra」，
  需按新默认工作点重跑夹具判据。
- `x264/x264_wbtest.mbt`（8）：`fixture must drive P-slice Intra4x4 macroblocks`
  ×4、`legacy I/P-only stream reported a B picture`、VBV tight-buffer 两项、
  `probe separates flat and VBV CABAC streams`。

建议做法：一个「重钉陈族」专片——先按 §406 的显示序映射表统一修正断言域，
再用 `moon test --update` 重钉快照，最后 `ffmpeg -f framemd5` 逐钉复核。

## 已知边界与待定

1. **`weightp` 保持 opt-in（默认 false）**：默认流逐字节不变。是否像 §403
   那样转正为默认开，用户尚未表态——转正需重钉全部 `h264*` 快照。
2. 拟合用**可见区** `p.width/height`；MC/参考平面是 MB 对齐，边界填充区不
   参与拟合（不影响语法一致性）。
3. ME（`me_fixed` / `me_part`）与 `skip_sad == 0` 快捷判据仍用**未加权**
   SAD：可能漏掉「加权后完美预测」的 skip，只影响决策质量，不影响语法。
4. 编码器 recon 是**去块前**像素，权重也对去块前参考拟合；与
   `skip_lf=true` 对比路径自洽，真实解码会去块（既有约定，已由 C 仲裁的
   filtered 哈希对照验证）。
5. B 帧显式/隐式权重未接（B 的 `weightp` 写死 false）。隐式权重按上面的
   GOP 结构恒中性，真要收益需先改 GOP 形状。

## 下一片候选

1. **重钉陈族**（上面 12 项，纯测试债，优先级最高——它们会掩盖真回归）。
2. `weightp` 转正 + x264 `--weightp` 对照（真 x264 流逐帧对拍）。
3. 统一播放门面（`VideoEncoder` 抽象 + CLI 整合）。
4. 码控深化 / 更多 profile 与位深（4:2:2、4:4:4、9/10-bit 编码面）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_weightp_test.mbt
moon test --target wasm libavcodec/h264_enc_stream_test.mbt
moon test --target wasm cmd/encode-h264 --no-render
moon test --target wasm-gc -p milkbobo/ffmpeg-moonbit/libavcodec -f "h264 enc weight*"
# docker（nine-x264）：
$env:MSYS_NO_PATHCONV='1'
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 \
  -c "/root/.moon/bin/moon update >/dev/null 2>&1; \
      /root/.moon/bin/moon test --target native -p milkbobo/ffmpeg-moonbit/libavcodec -f 'h264*' --target-dir /tmp/mbuild"
```

工具坑（Windows）：`moon test -f` 在整包上会间歇性 `Failed to spawn command`
（把整包文件名塞进 `--test-args` 超命令行长度）——直接指名测试文件最稳；
`moon` 正常输出走 stderr，判成功要看 `$LASTEXITCODE`；`moonfmt <file> -w`
逐文件格式化（`moon fmt` 选整包）。
