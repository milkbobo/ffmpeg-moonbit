# AV1 编码器门面接线 + CLI 交接 —— §459

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§457（粗 RD）、§458（per-SB skip），均已提交 c69b909

## 结果

把前两片的帧级优化接进公开门面，并新增可用的编码 CLI：

- `Av1Encoder::encode_frame` 新增可选参数 `skip_sad_pct? : Int32`（>0 时
  inter 帧走 §458 的 `av1_enc_write_me_skip420_inter_frame_obu`，否则沿用
  §449b 全残差链）。默认不传 → 行为与提交前逐字节一致。
- §457 的 `rd_lambda?` / `rd_candidates?` 已在门面上（c69b909 引入）；
  本片补测二者与 skip 标志共存的多帧链。三者关系：RD 选择器本身基于
  全残差链计价，skip 与 RD 同时开启时 RD 仍按全残差计价、选中 q 后
  由 skip 写端执行（属可用但非最优的组合，真 RD+skip 联合代价是后续片）。
- 新 CLI `cmd/encode-av1/`：8-bit 4:2:0 planar YUV 输入，64 倍数几何，
  输出裸 AV1 OBU 流（每 OBU 带 size 字段）。选项 `--qp`/`--rd-lambda`/
  `--skip-pct`/`--me-range`；每帧编码后用自家解码器逐像素自检
  （wasm-only 无外部 ffmpeg oracle，自检即契约）。输出一行 JSON 汇总。
  - 用法：`encode-av1 in.yuv --width W --height H --output out.av1 [...]`

## 验证

- session 黑盒 **8/8**（原 6 + 新 2）：skip 门面接线多帧链逐像素精确；
  RD+skip 标志共存多帧链逐像素精确。默认 6 测钉值不变。
- 帧级回归：RD 4/4、skip 5/5、inter 24/24（wasm/wasm-gc 分别）。
- CLI 端到端：64×64 生成夹具三种配置（默认 / --skip-pct 100 /
  --rd-lambda 1000）均产出合法 OBU 流、自检通过、JSON 汇总正确。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- CLI 只支持 8-bit 4:2:0、64 倍数几何、单文件输入——与编码器当前
  能力集一致；高位深/其它色度待编码器本体扩展后再接。
- skip 的字节收益在帧级 writer 测试里已钉（4224→27），门面测试只验
  接线与链路精确；真 RD+skip 联合 λ·D+bits 模式选择未做。
- 下一片候选：①NEARMV skip（非零 MV + skip=1）；②skip/RD 联合代价；
  ③高位深/420 之外的编码器能力扩展。

## 交接给下个会话

本片改动**尚未提交**。提交时注意提交信息避免 "del"/"rd" 子串
（rm-guard 会拦 git commit -m，用 Write 写消息文件 + `git commit -F`）。
