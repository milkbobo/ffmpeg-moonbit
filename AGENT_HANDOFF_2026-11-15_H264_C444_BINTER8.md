# H.264 4:4:4 B inter 8x8 DCT

接续 C444_BI16。4:4:4 B 调度在 dct8x8=true 时，符合分区限制的 inter
宏块现在使用三平面 8x8 变换，batch/stream、CAVLC/CABAC 均支持。
4:2:0/4:2:2 的 B inter 仍保持 4x4。

- code_b444_residuals 新增 8x8 量化/反量化/重建分支；每平面独立 QP
  和 inter dequant8 矩阵 3/4/5，共享 CBP，零块对应显式空列表/CBF。
- 私有 h264_b_transform8_allowed 镜像 decoder gate：子分区至少 8x8，
  direct 组要求 direct_8x8_inference。候选定价与最终重放使用相同 gate。
- CAVLC flag 按 coded.dct8 写入，三平面复用 interleaved lists 与 nC。
- CABAC flag 同步，残差 cat 5/9/13；CBP 为零时 mirror transform bit
  必须保持 false（flag 未出现），避免影响后续 ctx-399。
- 没有新增公共 API。

验证：

- 新白盒专项读取解码后 B 图片 infos，确认实际存在 inter + transform_8x8
  的宏块；8/10 位 × 两种熵模式，recon 与 skip_lf 解码逐字节一致，
  stream/batch 全字节一致。另检查小分区/direct gate。
- 新 inter8 与 c444 B parts、BI4/BI8/BI16 组合回归 5/5。
- nine-x264 native FFI 五帧同一 fixture，CAVLC/CABAC 的 FFmpeg 显示
  顺序像素摘要与本地默认滤波解码一致，零 warning/error/decode_error_flags。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm 通过。
- 无 C ABI 或所有权变化，本轮未运行 ASan。

后续：高位深和在线 VBV/强制 IDR 的组合回归，扩大真实素材编码对照。
