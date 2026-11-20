# AV1 编码器 per-SB skip/MV 模式决策交接 —— §458

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§457（per-frame qindex 粗 RD）；§438a–§456 全部未提交

## 结果

新增 **§458 per-SB skip/MV 模式决策**：inter 帧里静止 64x64 SB 走
GLOBALMV skip（零 MV、无残差 token 链），运动 SB 走 §449b 全残差链。
这是 AV1 标准语法里真实省码的路径——静止 SB 从数百~数千字节的 token
链塌缩成几个 bool。

- 新文件：`libavcodec/av1_enc_me_skip.mbt`（帧级入口 `av1_enc_write_me_skip420_inter_frame_obu`）、
  `libavcodec/av1_enc_me_skip_test.mbt`（黑盒 5 测）。
- 改动：`libavcodec/av1_enc_res_tile.mbt` 的 `av1_enc_write_me_res_tile`
  增可选 `skip_flags~ : FixedArray[Bool]?`（缺省全 false → §449b 行为不变）。

## 关键设计（不要随意改动）

1. **决策律（整数、确定性）**：`skip(sb) = (mv8 == (0,0)) && (SAD(src, ref) ≤ skip_sad_pct% × 64×64×255)`。
   - 只让零 MV 的 SB 走 GLOBALMV——非零 MV 的 skip 要走 NEARESTMV/NEWMV
     + skip=1，当前 tile 写端的 skip 分支钉死 GLOBALMV，所以强约束
     `mv8 == (0,0)`（写端也校验，违者 Err）。
   - `skip_sad_pct=0` 完全关闭（等于 §449b），保证既有钉值不变。
   - 阈值用 64×64×255 的百分比（Int64 防溢出），非浮点。
2. **skip 块的上下文银行同步（本片最容易出错的点）**：skip=1 时解码器
   不读 var-tx/token 符号，但仍**照常写上下文**：
   - `av1_read_vartx_tree` 的 switchable+skip 分支：
     a/l tx 银行按块 `bw_lw`/`bh_lh` 填（64x64 块：`av1_block_dimensions[bs*4+2/+3]` = 5 → 32 槽）；
   - `av1_recon_b_inter` 的 skip 分支：a/l lcoef 填 0x40（bw4/bh4 槽）、
     a/l ccoef 双平面填 0x40（chroma 域尺寸）。
   写端 `tail` 的 `is_skip` 分支逐条镜像，否则下一个 SB 的 sctx 从第二块
   起分叉（§454 B 片 `tab_ct_depth` 漏写的同类坑）。
3. **skip 块仍写 intra=inter 位与 ref tree**（av1_decode4:377-404 不按 skip
   门控），本仓的 `av1_enc_inter_skip_block` 已照此实现，直接复用。
4. **GLOBALMV motion**：newmv_mode=1、globalmv_mode=0（mv=(0,0)），
   返回 mode=2 供 refmvs splat——与 §446b 的 skip writer 一致。
5. **expected 平面**：skip 块 = 纯 MC 块拷贝（pred）；残差块 = §449b 的
   pred+itx(recon)。两者都来自解码器自己的核，所以 decode==expected by
   construction——这是抓上下文失步的唯一强断言。

## 验证

- 新黑盒 **5/5**（`moon test --target wasm libavcodec/av1_enc_me_skip_test.mbt`）：
  - skip=0 基线逐像素精确；
  - **静态帧省码实测**：128x128 静止+±3 overlay，q=40/100/180 下
    基线 4224/1515/92 字节 → skip 恒 27 字节（全部 < 基线一半）；
  - skip 开的运动内容仍逐像素精确；
  - 混合静态/运动 SB（跨 128px a 银行边界 + l 银行行重置）逐像素精确；
  - 确定性：同输入两遍字节数相同、都精确。
- 回归：inter 24/24（wasm-gc）、encoder 6/6、RD 4/4（wasm）。
- `moon check --target wasm --deny-warn` 零警告；`moon fmt`/`moon info` 已跑。

## 边界与下一步

- 目前 skip 只在**全零 MV** 上触发；NEARMV 的 skip（非零 MV + skip=1）
  未做（tile 写端的 GLOBALMV 钉死需先参数化 motion 的 skip 形态）。
- 决策是 SAD 阈值启发式，未与 §457 的 RD 联动（真 RD 应把 skip vs
  残差的 bits 也纳入代价）。
- 未接 `Av1Encoder::encode_frame` 门面（目前只暴露帧级函数）；如需 CLI/
  session 默认开启 skip，下一片接线并重新验证帧链 MD5。
- 下一片候选：①把 skip 接到 session 门面（加 `skip_sad_pct~` 可选参数）；
  ②NEARMV skip；③skip 决策与 §457 RD 合并成统一 λ·D+bits 模式选择。

## 交接给下个会话

§458 代码与测试**未提交**（与 §446–§457 同批留在工作树）。`skip_flags~`
是 `av1_enc_write_me_res_tile` 的可选参数，默认不改既有行为。
