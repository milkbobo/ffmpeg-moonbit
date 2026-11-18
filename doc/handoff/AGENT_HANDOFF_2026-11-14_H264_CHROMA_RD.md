# H.264 编码：色度失真与参考选择

纯 MoonBit 编码改动。沿用所有 MoonBit 技能的适用约束，两个 C 绑定技能
用于现有 FFmpeg 参考解码器对拍；未新增编码 FFI 或修改 C 所有权。

## 问题与修复

- 快速 Skip 只检查亮度 SAD：现在还要求按真实 MC/权重预测的 YUV SSD
  为零。亮度相同但颜色变化不能直接跳过。
- RD 的 coded/Skip 候选只统计亮度：统一用 reconstruction_ssd，包含
  16×16 Y 与两个 8×8 色度块。10-bit 最坏 384×1023²，Int32 内安全，
  后续代价乘法仍在 Int64 中进行。
- 多参考选择增加真实运动补偿后的 Cb/Cr SAD，包含现有色度权重，不修改
  探测期间的参考指针或重建缓冲；保留原 25% 改善门槛与亮度 MV 搜索。
- DC 全零但 AC 非零时，原 cbp 判断漏写色度 AC；修复 CAVLC/CABAC
  I 帧与共享 P 帧路径，优先判断 AC（cbp=2），再判断 DC（cbp=1）。
- CABAC 检查下一 MB 的 Skip 前漏重置 reference slot 0；现在与 CAVLC
  一致恢复 cur_ref_mb/ref_y/u/v，防止旧参考造成错误的 Skip 代价。
- P_8x8 赢得候选比较时原先未更新 best_cost，可能被后续更差的 intra
  候选覆盖；现在同步更新该代价。

## 回归与对拍

新黑盒：恒定亮度、颜色棋盘交替，CAVLC/CABAC、1/2 参考帧。逐 P 帧
验证 recon 一致，Cb 平均绝对误差低于 16（QP16，仍有量化/去块损失），
两参考码流小于单参考。修复前误差约 105/像素，错误 Skip 可达约 170。

已有 toggle 场景在保留色度残差后，双参考大小收益由原 luma-only
决策下的 20% 门槛调整为至少 10%；不以牺牲色度维持旧码率断言。

- 多参考 10/10；CABAC 10/10；流式 8/8；High 10 8/8；I 编码 8/8。
- P 编码 8/8；上述专项合计 52/52。
- 新 native 色度 oracle：8/10-bit × CAVLC/CABAC × weightp 开关，
  8 条七帧流共 56 帧，FFmpeg/MoonBit 逐像素一致，零解码 warning/error。
- 重跑多参考 warm-up/环绕 oracle 两项，共 224 帧对齐且解码零告警。
- CABAC QP22/24 和 CAVLC P 四/六帧的旧帧哈希按真实 FFmpeg
  framemd5 重新生成，分别按 coding/display order 填入。参考文件在
  .scratch/cabac22.md5、cabac24.md5、p4.md5、p6.md5；不是直接接受
  本地 decoder 快照。FFmpeg 导出这四条流无告警。
- moon check --target wasm --deny-warn、moon info --target wasm 和
  git diff --check 通过。

本轮未跑全仓库测试。没有修改 C 绑定代码，未重复 ASan。源码中的数据
格式、公开 API、默认选项保持原签名，但正确的色度计价会改变编码字节与
重建像素，不能承诺旧码流哈希不变。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*chroma-only AC*'
moon test --target native -p libavcodec/x264 --filter '*multiref*'
```

native 验证环境为 ffmpeg-moonbit-ffref:nine-x264。工作区此前未提交改动
全部保留；没有创建 Git 提交。临时 .mbtx 与抓取码流位于忽略的 .scratch。
