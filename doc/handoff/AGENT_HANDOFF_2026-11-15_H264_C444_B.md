# H.264 4:4:4 B 帧首片：16x16 inter / direct / skip

接续 C444_I8P。batch 的两种熵入口现在支持 4:4:4 B 调度的基本 inter 路径：

```text
chroma_format=3, b_slices=true,
b_parts=false, intra_in_b=false, intra4x4_in_b=false, dct8x8=false
```

这四项必须显式关闭（公共入口默认开启）。不支持的组合在入口报错。
stream 仍拒收 4:4:4 B，尚未放开本轮范围以外的组合。

- B SPS 补 separate_colour_plane_flag=0，mirror 使用 4:4:4 的零水平/垂直 subsampling shift。
- 单向/双向 16x16 MC 复制全尺寸三平面，direct 使用既有 decoder MC。
- 新 code_b444_residuals：三平面 4x4 量化/反量化/重建，共享四位 CBP。
- CAVLC 使用 gray inter CBP 和三平面 nC；CABAC 用 cat 2/8/12。
- B skip 的零残差判断和 SSD 在 4:4:4 下覆盖三平面；多参考 chroma SAD 修正预测 stride。
- batch 源平面加载、参考图像、重建打包均使用 4:4:4 几何。

验证：

- 新 c444_b 专项：五帧，两种熵模式 × multi_ref=1/3，编码 recon 与
  本地 skip_lf 解码逐字节一致。注意该 decoder 返回编码顺序，非显示顺序。
- native nine-x264 原生绑定增加 B oracle：FFmpeg 显示顺序与本地编码
  顺序按 I/P/B 映射，逐帧像素摘要一致，无 warning/error/decode_error_flags。
- moon fmt / moon check --target wasm --deny-warn / moon info --target wasm 通过。
- 相关组合回归 29 项初跑 28 项通过；P anchor 因前轮 full-chroma SSD
  改变模式选择。新增同一 96x64 fixture 的 native FFmpeg 对照通过后，
  将 P MD5 更新为 4f1577f252c919ebc3f8e1b2890085fc，并单独复跑该测试。
- 最终 native oracle 4/4。
- C ABI 和所有权不变；本轮未运行 ASan。

下一步：4:4:4 B 子分区、帧内候选、8x8 DCT；流式 B 调度。
