# H.264 4:4:4 P 帧内 I8 候选

接续 C444_I8。batch 入口 `intra_in_p=true, dct8x8=true,
chroma_format=3, b_slices=false` 现在参与 I8 模式决策（CAVLC/CABAC）。
I16/I4 候选仍保持 4:4:4 禁用；stream 沿用原有不启用 P 内 intra 的策略。

- 搜索后按固定模式回放三平面 I8 预测、量化及重建。
- P slice I_NxN 不写 chroma_pred_mode，CAVLC 使用 gray CBP 表，
  残差逐平面写四个 interleaved 子列表；CABAC 使用 cat 5/9/13。
- CABAC 精确 RD 与 CAVLC 定价共用已实现的语法路径。
- reconstruction_ssd 按 chroma format 计算完整色度宏块，修正 4:4:4
  列宽与基址及 4:2:2 行覆盖范围。未改公共 API。
- I8 模式搜索传入正确的扩展 QP 与 bit_depth。

验证：

- 新场景切换测试明确断言 i8p_mbs > 0，编码重建逐字节等于 skip_lf 解码。
- 新测试连同 I8、CABAC、inter8、4:2:2 及旧 P-intra 专项：15/15。
- native nine-x264 FFI：两种熵模式的 I8-in-P 三帧序列，FFmpeg 零
  warning/error/decode_error_flags，逐帧像素摘要与本地默认解码一致；
  连同已有 streaming 444 oracle 共 2/2。
- moon fmt、moon check --target wasm --deny-warn、moon info --target wasm。
- 未改 C ABI 或内存所有权；本轮未运行 ASan。

后续：4:4:4 B 帧、I4/I16 的 P 内候选，或对流式入口增加 intra 选项。
