# AV1 帧间整帧与会话入口（2026-10-26）

从 `8cd7860` 接续，包含上一轮 §95 状态基础。本轮按用户要求提交并推送。
原 FRAME_ENTRY 是设计参考，当前状态以本文和
PORTING_HISTORY §96 为准。

## 本轮实现

- `av1_session.mbt` 新增 `Av1Decoder::new/decode_packet`，输入为带 size 的
  OBU packet，返回 `Result[Av1FrameOutput?, String]`。None 表示无显示帧；
  同一 packet 可有多个隐藏帧，但最多一个显示帧。维护 sequence、8 槽图像、
  header、CDF、segmap 与 refmvs 图，成功解码后按 refresh bits 提交。
  sequence payload 改变时清参考；show-existing 返回滤波后的旧图像，
  若该参考是 key frame 则刷新全部槽位。
- `av1_decode4.mbt/av1_decode_inter.mbt` 接入 intra 标志、inter 帧内 intra
  y_mode、inter 语法/vartx/预测/残差/LF/邻域与公共尾。intra 块发布到
  refmvs 行环。inter-intra 使用当前帧实际像素边缘和 SB 行备份；OBMC
  使用实际 refmvs 与滤波上下文。分段 ref/global/skip 参与块语法选择。
- `av1_decode6.mbt` 的通用帧驱动采用 tile-row → sbrow → tile-col 顺序。
  所有 tile 共用物理 refmvs 存储和投影图，各有行指针副本与 entropy state；
  每行全宽 load/save 一次。above 按 tile-row/128px 列分 bank，left 每 tile
  行重置。inter 的 intra 边缘初值是 **0**（旧交接的 1 有误）。
- 保留原 keyframe API；完整执行既有 deblock/CDEF/LR。primary_ref 映射到
  真实槽位后选择 CDF 与匹配 coded-grid 的 segmap，继承 LF ref/mode delta。
  context_update_tile_id 的终态 CDF 经 `for_reference()` 清 adaptation count，
  padding 保留。独立 C 测试覆盖 80 表的全部元素摘要；另外两表 kfym/intrabc
  不参与 inter 参考复制，82 表深拷贝隔离回归继续保留。
- 有效 frame GM affine/rotzoom 模型接入单/复合参考 warp，按 plane 最小尺寸
  决定是否允许 warp；scaled reference 禁用 frame warp。

真实流暴露并修复的原语问题：header 的 use_ref_frame_mvs 与投影是否可用
必须分开（globalmv_ctx 初值）；时域边缘坐标清低三位用 `& -8`；左上次候选
要求 top 和 left 都可用；derive_warpmv 的 mask0 比较须截成 unsigned32；
warp DSP 用舍入后的 shear 而不是原始 matrix 差值；sub8x8 色度缺 inter 邻居
时预测整个覆盖色度单元；segment compound 的色度使用从亮度生成并下采样
的 mask，不能每 plane 重新按差值生成。既有块级 C 对拍全部保持通过。

## 真实码流验证与再生

新增独立 `libavcodec/av1_inter_realdata_vectors` 包，内嵌 IVF 与 libdav1d
framemd5。共 5 组、35 个显示帧逐帧一致；未把这些样本的覆盖范围外推到
所有格式/工具组合。

| stem | 源与编码参数（均 libaom-av1） | 显示帧 |
| --- | --- | --- |
| seg_inter | testsrc2 160x120 rate5；cpu-used6 crf30 aq-mode1 lag-in-frames0 g30 | 8 |
| inter_tiles | testsrc2 320x192 rate5；cpu-used6 crf30 lag0 g30 tiles2x2 | 5 |
| inter_10bit | testsrc2 160x120 rate5；yuv420p10le cpu-used6 crf30 lag0 g30 | 5 |
| inter_global | mandelbrot 160x120 rate5；yuv420p cpu-used4 crf20 lag0 g30 | 5 |
| inter_reorder | testsrc2 160x120 rate5；cpu-used6 crf30 lag8 auto-alt-ref1 g30 | 12 |

其余样本是 yuv420p。以多 tile 为例（从仓库根执行）：

```sh
docker run --rm -v D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1:/work linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x192:rate=5 -frames:v 5 -c:v libaom-av1 -cpu-used 6 -crf 30 -lag-in-frames 0 -g 30 -tiles 2x2 -f ivf -y /work/inter_tiles.ivf
docker run --rm -v D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1:/work linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -i /work/inter_tiles.ivf -f framemd5 -y /work/inter_tiles.framemd5
moon run scripts/emit_av1_session_vectors.mbtx inter_tiles
```

其余替换表中源、帧数和参数；`lag0/lag8` 对应 `-lag-in-frames 0/8`，
`g30` 对应 `-g 30`，像素格式用 `-pix_fmt`。生成脚本默认 stem=seg_inter。

CDF oracle：`moon run scripts/emit_av1_cdf_reference_vectors.mbtx --prepare`
写出 `.scratch/av1/cdf_reference.c`。使用 dav1d 1.5.1 config.h 和源代码，
链接 msac.c/cdf.c/ref.c/tables.c（同 §95 的 vpxdev-img C 参考环境），
stdout 保存 `.scratch/av1/cdf_reference.txt`，再不带参数运行生成脚本。
核心 oracle 直接调用 `dav1d_cdf_thread_update`，不复制 MoonBit 算法。

新入口接入后，主包白盒测试的 Wasm 全局初始化函数超过 local 数量上限。
`scripts/compact_test_bytes.mbtx` 合并 AAC height 既有 base64 常量的相邻
Bytes 字面量，每段最多 60000 字符；字节内容不变。这是唯一 AAC 修改，
避免数千次运行时拼接；重生成该 AAC fixture 后再次运行此脚本。新增 AV1
大向量继续放独立测试包，不能搬回主包白盒初始化。

## 后续范围

1. **整帧 superres**：resize 原语已有，但当前通用入口明确返回 unsupported。
   接 coded/output 两种宽度、滤波顺序、LR 边界备份和参考图像尺寸语义，
   用真实动态 superres 流逐帧验证；勿仅移除 guard。
2. **qmatrix**：既有关键帧入口也明确 unsupported，不能声称已支持。
3. **扩大 inter 验证**：目前真实流是 4:2:0 8/10-bit；补 12-bit、444/422/
   mono、128SB、多格式 GM、参考尺寸变化、更多 temporal segmentation 场景。
   现有 segmentation 合成/C 对拍不能替代所有真实跨帧 feature 组合。
4. film grain、intrabc、grain-from-reference 按既定范围不做。

验证结果：`moon check --target wasm --deny-warn --no-render` 零警告；全量
`moon test --target wasm --no-render` **968/968**；已运行 `moon info --target wasm`。
生成接口按本仓库约定忽略；不要未经用户要求提交或推送。
