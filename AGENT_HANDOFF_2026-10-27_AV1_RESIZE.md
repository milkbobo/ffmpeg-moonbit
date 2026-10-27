# AV1 帧尺寸变化（resize-mode）移植（2026-10-27）

在 AAC PS（§107）之后继续迁移，首次用真实码流覆盖 AV1 帧级尺寸切换。
运行时纯 MoonBit/Wasm；C 代码仅作离线参考。

## 本轮成果

七组 aomenc resize-mode 流逐帧 MD5 对齐 dav1d 1.5.1（CLI 原生输出）。
新增/修改：

- `libavcodec/av1.mbt`：非均匀 tile 间距（dav1d `parse_tile_info` 完整
  移植）；`Av1FrameHeader` 新增 `tile_col_start_sb`/`tile_row_start_sb`
  （显式边界数组，cols+1/rows+1 项）；显式帧尺寸改用序列头
  `frame_width_bits`/`frame_height_bits`（新增序列头字段）；
  `context_update_tile_id` 越界拒绝。
- `libavcodec/av1_decode6.mbt`：tile 任务起点与 `tile_col_start4` 查
  边界数组；入口校验数组长度。
- 生成链：`scripts/generate_av1_resize_vectors.mbtx`（aomenc 编码 +
  dav1d CLI 参考）、`scripts/assemble_resize_md5.mbtx`（组装 framemd5）、
  `scripts/emit_av1_session_vectors.mbtx`（新增 resize_ 路由）、
  `libavcodec/av1_inter_realdata_vectors/resize*_fixture_test.mbt` +
  `resize_test.mbt`。

## 关键坑（必读）

1. **FFmpeg framemd5 不能当尺寸变化流的参考**：filter graph 会把后续帧
   自动缩放到首帧尺寸再哈希。必须用 dav1d CLI 按帧输出原生 YUV 再哈希。
2. dav1d CLI 的 `%n`/`%w`/`%h` 文件名替换**只在未强制 `--muxer` 时生效**
   （按扩展名探测 + 文件名含 %n 才进 per-frame 模式）。
3. 容器 sh 是 dash：`for f in glob` 的词表只展开一次，逐帧循环要用
   `while :; do set -- dir/d${n}_*.yuv; [ -e "$1" ] || break; ...`。
4. 帧序严禁按文件名排序（stem 名含下划线会破坏 sort 键）；按帧号 glob。
5. MoonBit 字符串里 `$` 无需转义；`\$` 是非法转义（曾导致整轮再生静默
   未跑）。
6. aomenc 固定 resize 模式语义反直觉：`--resize-denominator=16
   --resize-kf-denominator=8` 得到 KF 全尺寸/inter 半尺寸；仅
   `--resize-denominator=8`（无 kf 参数）不触发缩放。resize×superres×qm
   组合会让 dav1d 1.5.1 首帧后段错误（上游 bug，无参考，不做）。
7. ffmpeg CLI 包装器不接受 resize 参数（`-aom-params` 报
   "Cannot find aom option"），必须用 apt 的 aom-tools（aomenc）。

## 已知遗留：resize_random 的 1 像素偏差（testsrc2 源时）

testsrc2 源的 random 流（已换 mandelbrot 源规避；若复现按下述继续）：
140x93 帧内 (139,60) 恰差 1。逐级二分（临时给 deblock/CDEF/LR 加旁路
门控对比 dav1d `--inloopfilters` 变体）结论：deblock 输出与 dav1d 完全
一致；分叉在 CDEF 的 noskip 判定——8x8 单元 (bx4=34, by4=14)（帧右缘
最后单元，含 padding 列）我们的 noskip 位置位（存在 !skip 块
(136..143, 56..63)），dav1d 跳过了该单元（其插桩转储未触发）。该差异
经 SGR/LR 传播到最后一列可见像素。矛盾点：两侧符号流与像素级均一致，
唯此 noskip 决策不同——下一步应给 dav1d decode.c 的
`if (!b->skip)` noskip 标记处（decode.c:1968）加帧号+坐标转储，与我们
`av1_decode_inter.mbt` 的标记逐块对拍，定位是 skip 值还是标记范围差异。

## 再生

```sh
moon run scripts/generate_av1_resize_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1
```

包含：y4m 源（linuxserver/ffmpeg:9.0.2）→ aomenc（ubuntu:24.04 +
aom-tools，TUNA 源）→ dav1d 1.5.1 CLI（.scratch/av1/trace_src 容器内
meson 构建）逐帧 md5 → assemble → emit 夹具。之后跑：

```sh
moon test libavcodec/av1_inter_realdata_vectors --target wasm --no-render
```
