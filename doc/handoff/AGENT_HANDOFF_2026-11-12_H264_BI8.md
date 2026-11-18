# H.264 I8x8-in-B 基础设施（未收口：b_slices×dct8x8 维持互斥）

本轮目标 I8x8-in-B 的全部基础设施已落地，但 b_slices×dct8x8 组合的完整
链路在 CABAC 的 B 帧 8x8DCT 上下文上与 ffmpeg 存在一帧分歧（见下），
故该组合维持互斥，基础设施留给下轮收口。**全部默认路径逐字节不变**，
既有回归与钉值全绿。

## 已落地的基础设施

- `h264_enc_sps_rbsp_b(p, dct8x8~)`：B 序列 High profile（100）SPS 变体
  ——chroma_format_idc 块、无 constraint flags、POC type 0 与
  max_num_ref_frames=2 保持。CABAC I 帧编码器的 b_seq 分支同步接入
  （根因之一：它曾用 `h264_enc_sps_rbsp_b(p)` 无 dct8x8，I8x8 IDR 流的
  SPS 仍是 Main → 解码器按 4x4 读）。PPS 的 dct8x8 参数两侧均已透传。
- `H264EncodedFrame` 扩展 `mb_modes/mb_intra4x4/mb_tf8`（CABAC 与 CAVLC
  I 帧编码器都导出 IDR 的 16 槽 modes 镜像、Intra_NxN 标志、每 MB
  transform_8x8；`H264EncMbState` 加 `transform_8x8`）；B 序列的
  `new_p_encoder` seed 用这些字段（modes + intra_nxn；mirror seed 段已
  移除——它是本轮回归的来源之一，见下）。
- BI8 计划/残差编码器/双熵写端全套（`BI8(Array[Int32], Int32)`、
  `code_b_mb_i8_residuals`（luma_i8_pass fixed_modes 回放 + 共享 intra
  色度链）、CAVLC `ue(23)+flag=1+4 模式 bin+INTRA cbp`、CABAC
  `bits=13+首 bin 0+flag bin(399+邻居 tf8 计数)+68/69 树+cbp bins+cat5`），
  候选在 `decide_b_mb` 末尾、受 `self.dct8x8 && !self.cabac_on` 门控。
- B inter 残差尾的 `transform_size_8x8_flag = 0` 位：两熵尾函数加
  `dct8_allowed` 参数，**发射门 = `self.dct8x8 && dct8_allowed &&
  (cbp&15)!=0`**（PPS 开关必须参与——本轮回归根因见下）；分割
  ≥8x8 才 allowed。
- 测试：High b_seq IDR 的 roundtrip + **docker ffmpeg framemd5 钉值**
  （ARBBDC8 路由，`2084…`）；b_slices+dct8x8 双熵入口拒绝断言。

## 回归根因（已根修）

初版 inter flag 位的发射门只看 `dct8_allowed`（分割形状），16x16 路径
传 `true`——**Main profile PPS（transform_8x8_mode=0）下解码器不读该
位，写端却发了** → 全部默认 b_slices 流错位（B 7/7 挂）。修复 = 发射门
加上 `self.dct8x8`（PPS 开关），两侧熵一致。教训：给既有码流加
「条件位」时，发射条件必须逐字对齐解码端读取条件（PPS flag × cbp ×
分割形状三者与）。

## 未收口：CABAC 的 B 帧 8x8DCT 上下文

解除互斥后 CABAC 的 b_slices+dct8x8 流与 docker ffmpeg 在**最后一帧的
个别 MB** 分歧（CAVLC 同配置流六帧全对；BI8 候选禁用后仍分歧 → 与 BI8
无关，是 B 帧 inter 残差在 transform_8x8_mode=1 PPS 下的 CABAC 上下文
差异——本地解码器自洽，故是 ffmpeg 的某个 CABAC ctx 我们没对齐）。
候选：`h264_cabac_residual` 的 ctx 偏移在 8x8DCT PPS 下的分支、
`ctx.cur_mb_is_intra` 对 cat5 的 nC 门。下轮从「BI8 禁用 + 仅解互斥 +
CABAC B 帧 inter flag=0 位」的最小流开始 bin zip。

收口清单：解互斥（两入口删拒绝分支 + CLI/README）→ bin zip 定位 CABAC
分歧 → 双熵 ffmpeg 钉值 → stream/CLI 透传。
