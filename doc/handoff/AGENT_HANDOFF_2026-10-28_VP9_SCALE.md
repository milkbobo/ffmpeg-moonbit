# VP9 参考缩放移植（2026-10-28）

在 AV1 resize（§108）之后继续迁移，补齐 README 中 VP9 的"参考缩放"缺口。
运行时纯 MoonBit/Wasm；C 仅作离线参考。

## 实现

- `libavcodec/vp9_inter_scaled.mbt`（新）：`mc_luma_scaled`/`mc_chroma_scaled`
  与 8tap/bilinear 缩放内核。缩放系数在 `mc_luma`/`mc_chroma` 分派时按
  `(ref_dim << 14) / cur_dim` 现算（与 C `vp9.c` REF_FRAME_SCALE 相同公式），
  参考尺寸相等即走原 unscaled 路径，全部既有调用点无需改动。
- 复刻 libvpx 舍入怪癖：MV 两分量分别缩放；4:2:0 色度的
  `webm/issues/820` 舍入（`scale_mv(x*16) & ~15 + scale_mv(x*32) & 15`）。
- `vp9_decode.mbt`：移除 "scaled reference frames not supported" 拒绝；
  新增 `mc_scaled_tmp`（64×135 水平暂存）与 `mc_scaled_emu`（288×135 边缘
  模拟，对应 C 的 stride-288 emu buffer；`refbh_m1+8` 上限 135）。
- chroma 的坐标约定：dispatcher（`mc_chroma`）传入的 `blk_x/blk_y/bw/bh`
  已是色度坐标，`mc_chroma_scaled` 内部不再下采样。
- MV 投影无需修改：VP9 跨尺寸的 MV "缩放"只是 sign-bias 取反
  （`vp9mvs.c` RETURN_SCALE_MV），`vp9_mvs.mbt` 已有。

## 验证

1. 内核级：`.scratch/av1/scaled_vp9_harness.c`（`do_scaled_8tap_c`/
   `do_scaled_bilin_c` 直编，LCG 源）12 用例 FNV-1a 与
   `mc_scaled_kernel` 逐像素一致（`vp9_scaled_kernel_test.mbt`）。
2. 整帧级：libvpx 官方 `vp90-2-05-resize.ivf`（fate-suite 的
   `vp9-test-vectors/`，FATE `fate-vp9-05-resize` 同源），10 帧
   352x288 ↔ 282x173，双向 scaled MC，逐帧 I420 MD5 对齐
   `vpxdec --i420 -o 'f%2n_%w_%h.yuv'` 的原生输出
   （`vp9_resize_realdata_test.mbt`，blackbox——白盒包 wasm init 局部
   数已贴边，新 fixture 一律放 `*_test.mbt`）。
   注意：FFmpeg framemd5 对尺寸变化流会自动缩放到首帧尺寸
   （AV1 resize 轮同一陷阱），参考必须用 vpxdec 逐帧输出。
   `vpxdec` 的 `%2n` 帧号从 1 起。

## 调试方法沉淀

"整帧 MD5 差、内核全对"的收敛路径：先分平面统计差异（Y/U/V 各自
diff 计数——VP9 测试的黑盒读法是 `dec.y[dec.ybase + y*stride + x]`，
基址字段是 decoder 上的 `ybase/uvbase`），锁到色度后打印块级中间值
（mv、scale、mx/my、x/y、emu off），与 C 语义手算对照。本轮两个
真实错误都是"从 C 直译时坐标域/掩码写反"：色度坐标二次下采样、
`& ~15` 写成 `lnot() & 15`。MoonBit 语法坑：`15.lnot()` 会把 `15.`
当浮点，用 `(~15)` 也会词法拒绝，写 `(-16)`。

## 全量

wasm 1051/1051。严格 check 0 警告，`moon info` 已跑。
