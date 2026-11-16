# H.264 高位深 SSD 与量化溢出修复

接续 CHROMA_CROP。范围审查发现两类实际溢出：

1. reconstruction_ssd/b_mb_ssd 用 Int32 累加，再转 Int64 计算 RD，转换
   已晚。14 位 4:4:4 最坏 SSD=206133265152，32 位回绕为 -25165056，
   可能令 P_Skip 的负分数胜出。
2. h264_enc_quant_val 与 fdct8_quant_res 的 magnitude*factor 在 Int32 中
   溢出。12 位黑场→白场回归中，修复 SSD 后仍重建出约 20 的亮度
   （目标 4095）；修复量化乘法后恢复到 4095。

实现：

- 私有 h264_enc_plane_ssd：差值、平方、累加全用 Int64。
- P 的 fixed SSD、eval_plan、三平面 SSD，B 的 SSD 与 skip 零误差判断
  及候选 RD 比较保留 Int64，移除末端无效转换。公开 API 不变。
- 4x4/8x8 量化乘法与舍入改为 Int64，最终 level 再转回 Int32。

验证：

- 白盒精确边界：14 位单平面 SSD=68711088384，三平面为206133265152；
  12 位 420 宏块最坏 SSD=6439305600。覆盖 stride/offset、正负差值。
- 大系数量化正负符号与精确 level 断言。
- 黑→白 P 帧：12/14 位 × 420/444 × CAVLC/CABAC，关闭 weightp，
  不允许溢出导致错误 skip；检查解码亮度幅值与 recon 字节一致。
- 新专项、既有量化幅值、online_depth、B inter8 组合回归 8/8。
- native nine-x264 FFI：高对比度和高位深 online VBV/IDR 两专项 2/2，
  FFmpeg 像素摘要与本地默认解码一致，零解码诊断。
- SSD 改造后、量化改造前另跑 c444/c422/crop/online/inter8 共14项通过；
  最终以以上8项和2项native结果为本轮主要验证。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm。
- 无 C ABI/所有权变更，本轮未运行 ASan。

后续：更多真实素材质量/压缩效率与性能测量，尤其大幅场景切换。
