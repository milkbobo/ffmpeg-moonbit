# AGENT_HANDOFF_2026-11-11 — H.264 P-slice I8x8 + §385 缺陷修复 + 变换/量化根修（§387）

## 本片结论（一次交付三层）

1. **P slice 的 Intra 8x8**：`I8` 计划变体 + CAVLC/CABAC 双写端
   （opt-in：`intra_in_p=true, dct8x8=true`）。
2. **§385 遗留三缺陷修复**：I16/I8 双真信令冲突、I8 代价量纲、
   CABAC I4 漏 flag=0（变异验证咬合）。
3. **正变换/量化定标根修（§376 以来的存量缺陷）**：正变换 Hadamard →
   H.264 核心变换；4x4/8x8 MF 换 JVT/x264 真表；AC 4×、色度 DC 32×、
   8x8 MF 行别名（qp%6 全用 rem5）全部修正。
   **RD 六帧 QP24：27.38 dB@2940B → 42.14 dB@2163B（CAVLC）/ 44.24 dB@1725B（CABAC）**。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 干净 |
| 幅度门 `h264_enc_quant_wbtest.mbt`（四链×6 rem×8 形状） | 3/3 |
| 编码器 7 套件（含新回归 + 收紧质量门） | **40/40** |
| 全仓 wasm-gc / 非 gc wasm | **1740/1740** / 853/853 |
| x264 native C oracle（docker，+P-I8 双熵用例） | **16/16** |
| 12 条流 docker ffmpeg 9.0.2 重钉 | 全部零告警，逐帧一致 |

## 变换/量化根修（最重要——细节与判据）

**症状指纹**：mean abs error 与 QP 无关（QP10/22/34 同 ~14）；flat 残差
40 → 重建 10（1/4）；斜坡形状扭曲。流完全合法——解码器忠实解码错值，
所以重建不变式/外部仲裁/x264 oracle 全都绿，**只有幅度/质量度量可见**。

| 链 | 缺陷 | 修复 |
| --- | --- | --- |
| 4x4 正变换 | `dst[1]=d03+d12`（Hadamard） | `2·d03+d12` / `d03−2·d12`（核心变换） |
| 4x4 AC 量化 | qbits 17+div，MF=round(2^17/init) | qbits **15+div**，JVT `quant4_scale` |
| luma DC | 17+div（正确） | 不动 |
| chroma DC | 21+div（32× 过粗） | **16+div** |
| 8x8 MF 表 | 行别名 + 2^19/init 类错 | x264 `quant8_scale` 类表，qbits 16+div |

**表验证双重锚**：逐值核对 x264 `common/set.c`（curl 拉真源）+ 36 项
「MF×dequant 跨 rem 恒定」自洽校验（类比 {1,f,f²} / {1,f²,g²,f,g,gf}）。
**守门**：`h264_enc_quant_wbtest.mbt` 幅度门（量化-反量化-逆变换往返
≤ Qstep 界，全部 6 个 qp%6，平场/斜坡/大斜坡/脉冲/棋盘；中灰平面重建
避免负值裁剪伪影——§385 探针被零平面裁剪骗过）。此门当场咬住全部四个错。

## I16/I8 冲突的定位案例（bin 全对齐仍分叉——下次别再绕）

症状：CABAC P 帧 1 从 MB 2 起重建分叉。zip 探针 **17927/17927 上下文 bin
逐一相同** → 语法层排除 → MV/WBP 探针一致 → 转查 I 帧本身：坏 MB 恰为
`mb_x≥1 && mb_y≥1`。真因：决策允许 `use_i16 && use_i8` 同真，重建走 I8
redo、语法层 `if use_i16` 先到 → 信令 I16。教训：**bin 级对齐证明的是
「解码器忠实解出了写下的东西」，不证明「写的东西=编码器重建的东西」**
——信令与重建来源不同源时，对齐探针无感，必须比对 I 帧与逐 MB。

决策修复后的结构（互斥 by construction）：

```
use_i8  = i8_found && !(100*i4_cost < 97*i8_cost)   // NxN 形式：I4 须胜 3%
nxn     = use_i8 ? i8_cost : i4_cost
use_i16 = !use_i8 && i16_found && !(100*nxn < 94*i16_cost)  // 6% 门槛
```

（共享 I8 pass 的 cost 已改为**预测 SAD**——与 i4/i16 同量纲；§385 的
量化后 SAD 让 I8 假性必胜，正是三缺陷互相掩盖的根源。）

## P-slice I8x8 速查

| 项 | 值 |
| --- | --- |
| CAVAC mb_type | ue(5)，flag=1，4 模式（`pred_nxn_mode` 镜像），色度 ue，**intra** cbp 表，dqp 仅 cbp≠0 |
| CABAC | ctx14=1 → @17=0（无 terminate），flag @399+邻居，模式树（mirror `h264_pred_intra_mode`），cbp bins，cat5 |
| nz | intra 从 0 起；CAVLC 子列表渐进 + leader 累加；CABAC 象限 2x2 |
| 镜像 | `H264PMbState.intra_nxn/modes`（CAVLC 侧）；CABAC 侧 `info.intra4x4/modes` |
| 残差 | 共享 pass `fixed_modes=` 重放；intra 矩阵 0；idct8 nz 捷径 |

## 重钉流水线（基建，转正可直接复用）

`.scratch/repin_all.py`：跑全部编码器测试 → 收 ARB dump → 逐条 docker
ffmpeg framemd5（断言零 stderr）→ `.scratch/apply_pins.py` 按测试名回钉。
测试通过 = 本仓解码器滤波输出与 ffmpeg 逐帧一致。新测试的 dump 一律放
**钉值断言之前**（否则钉值失败时无流可仲裁——本片已把存量 dump 前移）。

## 新坑（Windows）

`moonrun --test-args {全文件 JSON}` 命令行 32K 上限：libavcodec 包文件
数越过阈值后 `moon test --target wasm-gc` 报 **os error 206**。对策：
合并小文件（本片把 `h264_enc_i8x8.mbt` 并入 `h264_enc_dct.mbt`、三个
dct8 黑盒并成一个）。以后大包加文件前留意；长期方案是测试独立分包
（x264/vectors 先例）。

## 剩余

1. 码率控制（QP 恒定 → 真 RC）——现在质量地基已正，值得做。
2. I16/8x8 转默认策略（重钉流水线已就绪）。
3. CABAC 位定价（干跑仍 CAVLC 位数）。
4. I4-in-P（I_NxN 的 4x4 形态在 P slice）。

## 权威文件

- `libavcodec/h264_enc_dct.mbt` — 核心变换 + 两张 MF 真表（含 8x8 pass/几何 avail/子列表 view，已并入）
- `libavcodec/h264_enc_quant_wbtest.mbt` — 幅度门（刻度错唯一守门）
- `libavcodec/h264_encode_p.mbt` — I8 计划/decide/CAVLC 写端/镜像
- `libavcodec/h264_enc_cabac.mbt` — CABAC P-I8 写端、I 帧决策重构、flag=0
- `libavcodec/h264_encode_dct8_test.mbt` — 8x8 全部黑盒（三文件合并）
- `PORTING_HISTORY.md` §387 / `README.md` H.264 行
