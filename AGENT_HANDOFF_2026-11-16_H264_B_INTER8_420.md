# H.264 B 帧交互 8x8 DCT 的 420/422 面（§422e）

接续 §422d。BINTER8 交付了 444 的 B inter 8x8；本片把同一变换接到
4:2:0/4:2:2（BINTER8 交接留下的最后变换缺口），并加了一层 444 没有
的 RD 抉择。dct8x8 默认开时，B slice 里符合 gate 的 inter 宏块
（16x16/direct 种类恒合格；BParts 需全 ≥8x8 子分区）对胜者计划同时
编码 4x4 与 8x4 两版残差，按 `SSD·1024 + λ·price_b_bits` 取更廉者。

**后补更正（同日收口片）**：`code_b_mb_residuals` 开头就把 cf=3 转发给
`code_b444_residuals(dct8_allowed~)`，而 RD 双试挂在它的上层——所以
**444 实际也已被 RD 化**（初版交接「444 维持 gate-through 行为不变」
的论断是错的）。验证：`h264_enc_c444_binter8_wbtest` 1/1（count>0
断言仍成立——8x8 在纹理夹具上仍有胜者）、c444_b/bparts/bi16 黑盒
3/3，新增 `h264 c444 B: ffmpeg-arbitrated default-tools streams` 锚点
（默认全工具 = RD 生效组合，双熵七帧）docker framemd5 零告警、与本仓
默认解码逐帧一致后钉值。`restore_prediction` 闭包对 444 天然有效
（direct 重推/uni·bi MC/parts commit 都是 cf 无关的共享路径）。

## 关键发现：解码端与写端早已就绪

- 解码端 gate（`h264_b_mb.mbt:495`）与残差路径（`h264_inter_residual_
  cavlc/cabac` 与 P 共享）从 §400 起就是 cf 无关的。
- 写端 flag 门（kinds 0..3 的 `direct_8x8 || kind != 0`、BParts 的
  `parts.all(≥2x2) && (direct8 || 无 direct)`）逐条与解码端一致。
- 真正的缺口只有三处：`code_b_mb_residuals` 的 420/422 分支（恒
  `dct8: false`）、CAVLC 尾巴的 `coded.dct8` 分支（`for p in 0..<3`
  是 444 专用）、CABAC 尾巴同分支读 `planes_444`（420 的 8x8 levels
  在 `luma8_store`）。

## 本片的真 bug（排障记录，可复用）

**`code_b_mb_residuals` 不是幂等的**：它从 `rec` 读预测（`src - rec`
为残差），coding 完成后 `rec` 已是「预测 + 重建」。RD 双试里第二版
直接接着第一版跑，残差会复合（`src − 8x8重建`），流与重建双坏
（症状一：解码 `residual scan out of range`——nC 失配；症状二：
recon 1 逐字节不等）。**修法：提取 `restore_prediction` 闭包
（direct 重推 + compensate / uni·bi MC / parts commit + compensate），
每次 (re)coding 前重建胜者预测**。二分法（强选 8/强选 4）快速定位。

## gate-through vs RD 的取舍（数据）

- gate-through（444 同款）：平滑渐变夹具（vbv flat）B 流 +356B
  （+13.5%），P/cabac RD operating point 超上限（2713>2700、>2100）。
- RD 双试：flat +58B（+2.2%），两上限测试回绿；纹理夹具保留 8x8
  胜者（wbtest 断言 inter transform_8x8 计数 > 0）。
- 定价器沿用 `price_b_bits`（cabac_rd 开→活 CABAC 写 dry-run，否则
  CAVLC 位回退）——与 16x16 候选同口径。

## 实现

- `code_b_mb_residuals`（420/422）：`dct8 = dct8x8 && dct8_allowed`；
  8x8 臂镜像 P 帧 inter（`fdct8_quant_res` + inter dequant8 矩阵 3 +
  `idct8_add/dc_add` 内联重建 + cbp 位/8x8 块 + luma cur_nz 清零——
  语法层渐进回填）；4x4 臂与末尾 4x4 idct pass 原样；色度恒 4x4+DC。
- CAVLC 尾巴：cf!=3 时 `write_luma8_cavlc(plane=0)` 后**落入**色度段
  （444 三平面后仍 return）；CABAC 尾巴：store 按 cf 选
  `luma8_store`/`planes_444`（cat 5，n=4·i8）。
- `decide_b_mb` 最终回放的 inter 臂：RD 双试（见上）；dry 写的
  dqp/prev_qp 漂移由既有 restores 兜底。

## 钉值重仲裁（docker framemd5 全部零告警、与本仓解码逐帧一致）

- 级联提示：**fail() 提前中止会藏住同测试后半段的陈旧钉值**——
  nrefs=2 修好后 nrefs=3 才首次跑断言。本轮共重钉 9 处：
  b_multiref（nrefs=2/3 各 4 帧 B 图）、c422_depth（d10 4 帧、d12 2 帧
  显示 B）、h1214（d12/d14 各 2 帧）、rc（pins1/pins2 全 5 帧——ABR
  试编码换 QP，I 帧也变）、vbv 1261（pins1/pins2 全 5 帧——VBV 同理）、
  vbv flat（CAVLC 2685B/`8ac7d744…`、CABAC 2471B/`bd3b8b51…`）。
- rc/vbv 的钉值在**解码序**（display↔decode 置换 [0,2,1,4,3]），
  ffmpeg framemd5 输出是显示序——转录时要重排。

## 验证

- 新专项 `h264_enc_binter8_420_wbtest.mbt`（wasm-gc）：420/422 ×
  CAVLC/CABAC，B 图存在 inter transform_8x8 宏块、6 个 inter recon ==
  skip_lf 解码、流式 == 批式逐字节；gate 单元断言（8x8 子分区合格、
  4x4 不合格）。
- 最终门：全族（h264_enc*+h264_encode*+video_encoder）**235/235**、
  CLI 29/29、wbtest 1/1、`moon check --target wasm --deny-warn` 干净、
  `moon info` 零公共 API 变更。无 C ABI/所有权变更，未跑 ASan。

## 工具坑（本轮新踩，下轮直接绕行）

- **`moon test --update` 对 `content=pins[i]`（变量引用）破坏性改写**：
  它会把循环体内联成字面量并逐 pass 追加空 `#|` 行（内容越滚越大，
  256-pass 上限撞满仍不收敛）。正解：在 pins 循环前临时 `println`
  全列表（一次运行拿全——循环内打印会被首个失配中止），手写数组。
- expect 失配的 got 值在日志里有完整 `(- expected, + actual)` diff，
  单值字面量直接抄；多帧数组才需要临时打印法。
- `--update` 的 256-pass 上限按文件分摊；重跑循环在变量 content 的
  场景只会越改越坏（先确认 pins 形态再选路径）。
- git checkout 回滚测试文件会连带回滚**之前写进去的 ARB 钉值**——
  本轮 rc 的 pins1/2 因此重写了一次；回滚清单要先对照自己的编辑史。

## 下一步候选

- ~~444 B inter 8x8 的 RD 化~~（已随本片覆盖，见顶部更正）。
- ~~BDirect16 胜者脏 cell（§419 遗留）~~——查证为**已在 §419 提交
  c50455d 修复**（「Re-derive every quadrant」段即该修复；旧记忆把
  「发现」当「遗留」记了）。
- 流式 ABR（总字节契约待用户定夺）。
- 更多真实素材的质量/压缩效率与性能测量。
