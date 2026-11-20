# AV1 编码器变换尺寸扩展 —— 调研交接（§466 预备，未实现）

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§465（三维联合决策，已提交 17018cc）

## 结论摘要

本片**只做调研，未改代码**。目标是评估「变换尺寸/类型扩展」的可行性，
为下一个会话给出确定的入口。结论：**token 链与 CDF 已就绪，真正的工程
量集中在 var-tx 树的语法写端**，不是一个小切片。

## 已确认的事实（都已核对源码）

### 1. token 链与量化/重建已完全按 tx 参数化 —— 无需改动

- `av1_enc_itx_basis(tx)`（`av1_enc_fdct.mbt:40`）按 tx 尺寸探测解码器
  逆变换核构造伪逆基，`Av1EncItxBasis` 存 `tx/n/g/basis/probe_scale`。
- `av1_enc_quantize_leaf`（:90）与 `av1_enc_recon_leaf`（:168）都用
  `basis.tx` 推导 `pw/ph/n`，与尺寸无关。
- `av1_enc_txb_tokens`（`av1_enc_tile.mbt:355`）的 `szctx = slw + slh`
  （各上限 3）覆盖 0..6，**eob_bin_16/32/64/128/256/512/1024 七个表全部
  有写端分支**（:408-416），`scan_len = (4<<lw)*(4<<lh)` 也正确。
- 所以 TX_4X4 / 8X8 / 16X16 / 32X32 的 token 链**当前就能写**。

### 2. 解码端 eob 读取路径完整覆盖

`av1_decode2.mbt:175-215` 的 `tx2dszctx` 分支覆盖 0..6，七个 eob_bin 表
齐全。解码器能解任何 ≤TX_32X32 的 txb。

### 3. TX_64X64 不可行（重要边界）

- `av1_cdf.mbt:12-18` 的 `Av1CdfCtx` **没有 `eob_bin_4096` 字段**，
  解码端 `av1_decode2.mbt` 也没有 4096 的读取分支。
- TX_64X64 需要 `eob_bin_4096`（4096 系数）。**编解码两侧 CDF 结构都要
  新增字段 + 4 组 qsel 表数据 + 读写分支**，属于跨两侧的工程。
- 结论：**TX_64X64 不在近期范围**；扩展方向应选「更小的变换」
  （TX_16X16/8X8/4X4），这对纹理/细节内容反而更有价值。

### 4. 真正的工程量在 var-tx 树语法写端

`av1_tx_tree.mbt` 的 `av1_read_tx_tree`（:34）是递归结构：

- 每层写一个 `txpart` bool，`cat = 2*(4 - txfm_max(from)) - depth`，
  ctx 来自 `a_tx[bx4] < txw` / `l_tx[by4] < txh` 的比较；
- `depth < 2 && from > 0` 才读分割位；`is_split` 且 `txfm_max > 1` 才递归；
- 分割后在 `masks[depth]` 置位，供后续取叶用；
- 递归按 (x_off*2, y_off*2) 与 (x_off*2+1, ...) 的树序展开。

当前 `av1_enc_res_tile.mbt:196-228` 把这条树**硬编码成
「根 split=1 + 四个叶 split=0 → 4×TX_32X32」**。要支持其它形态必须：

1. 参数化每层的 split 决策（或按目标形态反推每个 txpart 位）；
2. 每个叶的 tx 尺寸不同 → 各自的 token 规格数组布局、`t_dim_ctx`、
   `dq_shift`（`av1_imax(0, av1_txfm_ctx(tx) - 2)`）、chroma 的 uvtx
   都随叶变化；
3. 上下文银行 `a_tx/l_tx` 的写回宽度 = `1 << lw/lh`，逐叶不同；
4. `a_lcoef/l_ccoef` 的写回宽度同样随叶 tx 变化；
5. inter 的每个 txb 还要一个 `txtp_inter3` bool（DCT_DCT 选择），
   且 txtp 的读条件与 tx 尺寸/类型相关（`av1_tx_type_class`）。

这五项叠加，加上「每个叶的量化/重建/token 规格都要重排」，是
**跨 `av1_enc_res_tile.mbt` + `av1_enc_me420.mbt` + 测试**的一次大改。

## 建议的下个会话入口（按风险从低到高）

### 方案 A 已被本轮证伪（重要！）

原计划「写一个只含单个 txb 的最小 tile 来独立验证各尺寸 token 链」**不可行**，
本轮已实现并测试证伪，WIP 在 `.trash/2026-11-20-av1-s466-txb-wip/`。

**证伪原因**：tile 的块是 64×64 PARTITION_NONE，`txsz` 只编码「相对块 max tx
（TX_64X64）的分割深度」：depth 0 = TX_64X64、1 = TX_32X32、2 = TX_16X16。
但 depth ≥ 1 意味着块内要写**多个** txb（TX_32X32 需 4 个、TX_16X16 需 16 个），
不是单 txb。实测：depth=1 只写 1 个 txb 时，解码器输出恒 128（残差未被消费），
深度=2 直接 `symbol decoder overread`。

所以「单 txb 独立验证」这条路与 var-tx 树的多叶结构是绑定的，**无法绕过**。
`txsz` 的 3 个符号（0/1/2）也决定了 TX_8X8/TX_4X4 根本不可达（需要更小的块）。

**这意味着：变换尺寸扩展没有「小而独立」的切入点，必须整体做 var-tx 树
的多叶写端。** 这也是为什么 §449a 当初直接选 4×TX_32X32。

### 修正后的入口建议

#### 方案 B（推荐，风险最低的真实切片）：key 帧 luma 改 TX_16X16

key 帧**没有 var-tx 树**：`tx_mode = TX_MODE_LARGEST` 下每个块的 tx 由
`txsz` 单符号决定，且 key 帧的块是 4 个 32×32（BL_32X32），其 max tx 就是
TX_32X32（m=3），`txsz` 的 depth 0/1 分别对应 TX_32X32/TX_16X16。
**一个 32×32 块改成 TX_16X16 需要在该块内写 4 个 txb**（2×2），
但仍在单块内、无 var-tx 递归，比 inter 的树简单。

#### 方案 C：inter var-tx 树参数化（工程量最大）

## 最大风险点

1. **txpart 的 ctx 与写回宽度**：`1 << lw` 随尺寸变，写错一位后续全失步，
   且症状是「自洽的错图」而非解码报错（§458 的教训）。
2. **`dq_shift` 随 tx 变**：`av1_imax(0, av1_txfm_ctx(tx) - 2)`，
   TX_32X32 是 1、TX_16X16 是 0，量化/重建两侧必须同源。
3. **chroma uvtx**：4:2:0 下 BS_32x32 的 uvtx 是 TX_16X16，与 luma 的
   tx 不同步变化，容易漏改。
4. **txtp 位**：inter TX_32X32 有 `txtp_inter3` bool，小尺寸可能没有
   （`txfm_max` 规则），写多了会失步。
5. **`txsz` 符号值域**：`encode_symbol_adapt` 的 symbol 必须 < nsym（2），
   本轮踩过——传 `m_tx` 而不是 `depth` 会直接越界崩溃。

## 交接给下个会话

本片**无代码改动、无提交**（只有本文档）。WIP 在
`.trash/2026-11-20-av1-s466-txb-wip/`，**不要直接恢复**——其设计前提已被
证伪，但其中的 tile 骨架代码可作为方案 B 的起点参考。

建议按方案 B 推进；若做方案 C，需 2–3 个会话且必须配 wbtest 逐叶对拍。

