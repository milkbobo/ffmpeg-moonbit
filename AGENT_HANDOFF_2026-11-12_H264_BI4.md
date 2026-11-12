# H.264 B 帧内 Intra4x4（intra4x4_in_b）

接续 BINTRA，本轮 `intra4x4_in_b~` opt-in 支持 B slice 内 Intra_NxN（4x4）
宏块（B mb_type 23 = I-slice intra 表的 I_NxN + 23）。细纹理场景下 16 个
pred4x4 逐块预测入 RD 竞争。批式（CAVLC/CABAC/CABAC RD）、流式、CLI
（`--intra4x4-in-b`，要求 `--b-slices`）全打通。默认关闭，原有码流逐字节
不变。

要点（I16-in-B 骨架 + P 端 I4x4 全部构件）：

- 决策：`h264_enc_luma_i4_pass`（无 fixed_modes 一遍选出 16 个 signalled
  模式并重建）+ `pick_chroma` → `code_b_mb_i4_residuals`（pass 以
  `fixed_modes` 回放——逐块从已建重建预测、intra 矩阵 0 量化、原地重建
  ——+ 抽出的共享 `code_b_mb_chroma_intra`（I16/I4 共用的 intra 色度链：
  预测、Hadamard DC、矩阵 1/2、intra nC 语义、重建））。I16 残差编码器
  同步改用共享色度 helper。
- CAVLC 写端：`ue(23)`（B PPS 关 8x8DCT，无 transform_size_8x8_flag）→
  16 个差分模式 bin（`pred_nxn_mode`，1-bin/0+3bit）→ 色度 ue → **INTRA
  cbp 码字**（`h264_enc_cbp_golomb`，与 I16 的「由 mb_type 组推导」不同）
  → cbp 门控 dqp → 16 个 cbp 门控 4x4 块（含 DC）→ 色度共享尾。
- CABAC 写端：B mb_type 树 bits=13 后 intra 树**首 bin=0**（I_NxN，无
  terminate/模式域）→ 16 个差分模式 bin（解码器自己的
  `h264_pred_intra_mode` + ctx 68/69）→ 色度树 → `h264_cabacw_cbp` →
  cbp 门控 dqp → luma cat2 逐块 → `h264_cabacw_chroma` 共享色度。
- 镜像状态：BI4 提交 = slot 重置 + `mb_type_bits = intra4x4` +
  `intra4x4 = true`；`commit_b_mb_state` 填 `st.intra_nxn = true` +
  `st.modes[g] = raw_modes[g]`（后续 MB 的 CAVLC 模式预测读它）；
  `price_b_bits` 快照扩 `info.intra4x4`/`info.modes`（I4 定价写镜像，
  落选须回滚——否则污染后续 intra 候选的模式预测）。

**本轮唯一真 bug（bin 级打点定位）**：`commit_b_mb_state` 尾部残留一行
旧 `st.intra_nxn = false` 把新 match 的结果覆写——跨 MB 模式预测读旧值
（解码器读 `infos[左].modes[gy*4+3]`，两侧 predicted 分歧 → 同一位流不
同 mode）。教训：扩写既有函数时先清点尾部既有赋值。

验证：bi4 套件 9/9（CAVLC/CABAC roundtrip 重建逐像素、流式逐字节、
确定性、门控、**ffmpeg 9.0.2 零告警 + display 序 framemd5 六帧钉值**
ARBBI4 路由）；全部既有编码器回归绿（B 7/7、GOP 4/4、bparts 7/7、
bintra 5/5、CABAC RD 6/6、stream/CABAC/P/RC/VBV/DCT8/I4P 全绿）；CLI
10/10；docker x264 native 34/34、ffref 42/42；`moon check --target all`
0 错误。

B 线至此：b_slices（§393）→ B RD → B 子分割（§395）→ intra-in-B（§396）
→ I4x4-in-B（§397）。剩余：I8x8-in-B（需 High 8x8DCT SPS/PPS 改造，B 现
与 dct8x8 互斥）、B×VBV/ABR、流式宿主分块读、候选剪枝、x264 HRD 对拍。
