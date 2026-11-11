# AGENT_HANDOFF_2026-11-11 — H.264 P slice Intra4x4（§390）已交付

> **状态：已完成交付。** 详情见 `PORTING_HISTORY.md` §390 节。本片
> `h264_encode_frames` / `h264_encode_frames_cabac` 增 opt-in
> `intra4x4_in_p~ : Bool = false`：P slice 允许 I_NxN 宏块（mb_type=5，
> 十六个独立预测的 4x4 块），两熵同构，默认 false 逐字节不变。

## 交付清单（相对 HEAD 02c32e3）

| 文件 | 内容 |
| --- | --- |
| `libavcodec/h264_enc_dct.mbt` | 共享 `h264_enc_luma_i4_pass` + `h264_enc_i4_avail` |
| `libavcodec/h264_encode_p.mbt` | CAVLC 侧 plan/decide/residual/recon/write/stat + **决策链修复**（I8/I4 胜出更新 `best_cost`，与 I16 对齐） |
| `libavcodec/h264_enc_cabac.mbt` | CABAC 侧写端 + 贯穿参数 + stat |
| `libavcodec/h264_enc_rc_test.mbt` | 6 个钉值测试（探针转正，实验已删） |
| `libavcodec/x264/x264_wbtest.mbt` | x264 oracle 扩 I4 四用例 + `x264_i4p_fixture`/`x264_i4_stripe_fixture` |
| `PORTING_HISTORY.md` / `README.md` | §390 节 + H.264 行 |

## 验证结论

- 全仓 wasm-gc **1753/1753**（§389 基线 1747 + 6）；非 gc 黑盒编码器
  **53/53**（47 + 6）；`moon check --target wasm --deny-warn` 干净；
  `moon fmt` / `moon info` 过；存量钉值全绿（默认 byte-exact 用例钉死）。
- 四条 I4 流（std dct8x8 双熵 + stripe no8 双熵）docker ffmpeg 9.0.2
  **零 stderr 告警**，framemd5 与本仓滤波解码逐帧一致（钉值在
  `h264 i4p: ffmpeg-arbitrated…` 与 `…without the 8x8 transform`）。
- x264 native C oracle **24/24**（20 + 4；`ffmpeg-moonbit-ffref:nine-x264`
  镜像，moonbit-c-binding / make-moonbit-c-bindings 流程复核）。

## WIP 遗留问题的收口结论

1. **no8 为何 i4=0**：合法 RD。标准夹具是 4x4 像素棋盘纹理，no8 的
   inter 残差走 4x4 变换（完美匹配）压过 I4；dct8x8 的 8x8 变换对
   4x4 棋盘不友好使 inter 变贵、I4 胜出（std-all i4=6）。no8 的 I4
   语法用**斜纹夹具**钉住（每帧变斜率对角条纹，i4=14 双熵）。
2. **allow_intra 门控**：保留独立性语义（字段文档写明 I4 独立于
   `intra_in_p`），用例钉死：stripe 夹具 `intra4x4_in_p=T, intra_in_p=F`
   → i4=34 / i16=0 / i8=0。
3. **I8/I4 best_cost**：已根修（胜出即更新）。数学上零存量影响：I8
   更新只影响其后 I4 候选（intra4x4_in_p 默认关），I4 是最后候选；
   dump 逐字节复核不变。stripe-all 流（i4=4/i16=14/i8=16）钉住
   「I8 胜出后 I4 须击败 I8」的链。

## 剩余（下一片候选）

1. VBV/CBR 缓冲约束（现纯 ABR 目标 + 帧内 AQ ±1）
2. I16/8x8/I4 转默认策略权衡（重钉流水线 `.scratch/repin_all.py` 就绪）
3. CABAC 位定价（eval_plan 目前统一走 CAVLC 干跑计位）
4. B 帧（编码器尚无 B slice）
