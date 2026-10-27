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

## 已解决：testsrc2 源 random 流的 1 像素偏差（原遗留）

testsrc2 源 random 流 140x93 帧内 (139,60) 恰差 1，已定位并修复（该流
现为 `resize_random_t2` 夹具，24 帧全绿）。逐级双侧对拍（MC 参数/预测
块、反量化系数、itx 输出、level 网格）证明预测与残差链完全一致，差异
在去块阶段：**dav1d 的 `f->w4`/`f->h4` 是可见 4x4 网格（`(dim+3)>>2`），
level 缓存写入与去块边缘循环（cols/rows、tile 行修正）都以其为界，
帧对齐填充列/行从不写入也从不滤波**；本移植此前用 8 像素对齐的
`bw`/`bh`，帧缘 8x8 块（x136..143，可见宽 140）的填充列参与去块并
读到 stride 填充值，CDEF 的方向/方差改变传播到可见像素。修复：
`Av1FrameCtx` 新增 `w4`/`h4`，`lf_sbrow_cols/rows` 的边缘循环、
`av1_create_lf_mask_inter/intra` 的 level 写入、tile 行修正循环全部
改用可见网格；CDEF/重建/插入路径保持对齐域（与 dav1d 相同）。
该 bug 自 inter 整帧接入即潜伏（此前所有流的帧宽都恰为 4x4 网格
对齐，可见区域未被触及）。

调试要点（复用价值）：排查此类"单像素差"时，双侧按**同一内容特征**
匹配块后逐级 dump（MC 参数→预测块→系数→itx 输出→level 网格），
每级确认 0 差异再进下一级；注意区分同一 test 内多个 check_session
的打印（先跑的流会占满 head），且 `moon test` 输出与 stderr 混流时
按内容特征而非行号对齐。dav1d CLI 默认多线程（n_tc>1 走 task 路径），
单线程插桩需 `--threads 1` 才命中 `dav1d_filter_sbrow`。

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
