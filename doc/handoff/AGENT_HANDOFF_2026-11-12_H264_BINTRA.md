# H.264 B 帧内 Intra16x16（intra_in_b）

接续 BPARTS，本轮 `intra_in_b~` opt-in 支持 B slice 内 Intra16x16 宏块
（B mb_type 24..47 = I-slice intra 表 1..24 + 23）。场景切换的 B 图像中，
inter/direct 全候选残差巨大，宏块改用本帧邻居预测入 RD 竞争。批式
（CAVLC/CABAC/CABAC RD）、流式、CLI（`--intra-in-b`，要求 `--b-slices`）
全打通。默认关闭，原有码流逐字节不变。

要点（复用 intra-in-P 的全部构件，B 侧差异只在信令与镜像状态）：

- 决策：`pick_i16`（P 端原样复用）+ `pick_chroma` →
  `code_b_mb_i16_residuals`（预测入 rec → luma Hadamard DC（矩阵 0）+
  AC level[0]=0 → intra 色度矩阵 1/2 → `h264_luma_dc_dequant_idct` 先散
  DC 再逐块 IDCT 的 I16 重建序；nC 走 intra 语法语义：全零种子，luma AC
  仅 cbp&15 写、色度仅 cbp&0x20 写）→ `SSD + λ·bits` 与全部 inter/分割
  候选同台，末位加入故平手归 inter。
- CAVLC 写端：`ue(23 + 1 + spec_mode + 4*group)`（无 cbp 码字——I16 由
  mb_type 组推导）、色度模式 ue、**无条件** `mb_qp_delta`、DC 块
  （`nc_block0`）+ cbp 门控 AC（`nc_luma` 渐进回填）+ 色度共享尾。
- CABAC 写端：B mb_type 树落在后缀 `bits = 13`（bins 31/32/32/32 =
  1/1/0/1），解码端由此进 `h264_cabac_intra_mb_type(ctx_base 32,
  intra_slice 0)` 加 23——故 I16 模式域为 intra 树 b0..b4（ctx
  33/34/34/35/35，`terminate(0)` 拒 PCM），色度树 64+cc/67，
  `h264_cabacw_dqp` 无条件，残差类别与 I slice 相同（luma DC cat0/n48）。
- 镜像状态：BI16 提交 = `h264_b_slot_reset`（运动槽回解码器逐图新值——
  解码器 intra 分支不动运动槽）+ `mb_type_bits = intra16x16`；
  `mirror.cur_mb_is_intra = true` 驱动 CABAC 残差上下文（inter 写端逐 MB
  置回 false，与解码器一致）；`info.chroma_mode` 仅 intra 写端填写（后续
  MB 色度树读邻居）；`price_b_bits` 快照/回滚扩 `cur_mb_is_intra` 与
  `chroma_mode`；`commit_b_mb_state` 的 `st.intra` 使下一 B 图像的
  colocated 把该块判为 intra（`h264_b_colocated_from_states` 原有分支）。

验证：bintra 套件 5/5（CAVLC/CABAC/CABAC-RD 重建逐像素相等；流式逐字节
相等；门控拒绝）；**ffmpeg 9.0.2（nine-x264 镜像）零告警解码，display 序
framemd5 六帧逐帧一致**（ARBBINTRA dump 路由钉值；两个场景切换 B 帧内容
相同故帧 1/3 MD5 相同）；全部既有编码器回归绿（B 7/7、GOP 4/4、CABAC RD
6/6、bparts 7/7、stream/CABAC/P/RC/VBV/DCT8/I4P 全绿）；docker x264
native 34/34、ffref 42/42；`moon check --target all` 0 错误。

沿用全部 MoonBit 技能；moonbit-c-binding 与 make-moonbit-c-bindings 用于
原生 oracle 容器化重跑边界复核。未改 C ABI、未新增 vendoring；ASan 继承
既有记录。wbtest 包 local count 上限与 blackbox 整包 spawn 超长仍为既有
宿主限制（基线已复现）。

B 线至此：b_slices（§393）→ B RD（price_b_bits）→ B 子分割（§395）→
intra-in-B（§396）。剩余：I4x4/I8x8-in-B（I16 同构可推）、B×VBV/ABR、
流式宿主分块读、子分割候选剪枝、x264 HRD 逐字段对拍。
