# HEVC PCM、transquant bypass 与高位深分段验证（2026-10-27）

接续 dependent slice segments，本轮新增 PCM 与无损 transquant bypass，
并把 dependent segment 的代表性验证扩展到 10/12-bit 4:2:0。
运行时仍为纯 MoonBit；没有引入 FFmpeg FFI 或网络依赖。

## PCM 与滤波保护

- `hevc_intra_decode.mbt` 按 CU 类型、PART_2Nx2N、SPS PCM 尺寸区间
  读取 terminate 编码的 pcm_flag。PCM CU 设置默认帧内预测/运动信息，
  不读取帧内方向模式或变换树，仍更新 QP、深度、去块边界强度等共享状态。
- `CabacContext::skip_bytes` 依照 FFmpeg `skip_bytes` 回退 CABAC 的
  pending guard bits，检查原始样本负载长度，在负载末端重启算术引擎；
  CABAC 概率数组保持不变。原有 `reinit()` 复用零字节路径。
- `hevc_pcm.mbt` 按独立的 luma/chroma PCM 精度读取 Y/Cb/Cr，
  左移到输出位深，覆盖色度子采样和单色的样本布局。
- PCM 禁用环路滤波或 CU transquant bypass 时，记录每个 min-PU 的
  保护标记。没有相关工具的图片使用空数组。
- 去块滤波仍计算边缘两侧，但只修改未保护侧。亮度以四行独立滤波组
  为单位保存并立即还原保护侧的三个样本，等价于 C 的 no_p/no_q 写入
  门控；不能延迟到全图滤波后再还原，否则下一条边会读到修改过的 PCM。
  色度直接按侧门控写入。SAO 从不可变的 pre-SAO 平面读取，因此可在
  全部 CTB 处理后还原保护区域，而不影响邻居分类。

## Transquant bypass

混合 PCM 一致性样本 `ipcm_D_NEC_3` 的 PPS 允许 transquant bypass。
本轮同时实现 CU 的 bypass flag，保护该 CU 的滤波输出，并将残差作为
空间域样本直接相加：不读 transform_skip_flag，不执行量化矩阵/反量化/
逆变换，并禁用 sign hiding。QP 历史和系数熵上下文沿用原来的 CU/TU 流程。
RDPCM 和 cross-component prediction 仍明确拒绝。

历史 `hevc_pb_neg_pcm_b64` 只是一个启用 PCM 的 SPS，不要求每个 CU
使用 PCM。FFmpeg 9.0.2 `-xerror` 仍输出与原来相同的七帧灰色图像；
对应旧拒绝测试已改为正例，保留同一份夹具。

## 独立参考向量

七个原始 FFmpeg FATE 流（各一帧，目录为
[hevc-conformance](https://fate-suite.ffmpeg.org/hevc-conformance/)）：

| 流 | 输出 | PCM 精度 Y/C | PCM 禁用滤波 |
| --- | --- | --- | --- |
| ipcm_A_NEC_3 | 8-bit 4:2:0 | 8/8 | 否 |
| ipcm_B_NEC_3 | 8-bit 4:2:0 | 6/6 | 否 |
| ipcm_C_NEC_3 | 8-bit 4:2:0 | 8/8 | 是 |
| ipcm_D_NEC_3 | 8-bit 4:2:0 | 8/8 | 否，PPS 允许 bypass |
| ipcm_E_NEC_2 | 8-bit 4:2:0 | 6/8 | 否 |
| IPCM_A_RExt_NEC | 10-bit 4:2:2 | 8/8 | 否 |
| IPCM_B_RExt_NEC | 12-bit 4:4:4 | 8/8 | 否 |

另外用 FFmpeg 9.0.2/libx265 的 `lossless=1` 生成四组五帧 I/P/B 流，
分别为 8-bit 420、10-bit 422、12-bit 444 和 8-bit 单色。编码参数完整
记录于 `scripts/generate_hevc_pcm_vectors.mbtx`。这些流在默认滤波与
跳过滤波模式下的参考 MD5 也相同，验证 bypass 样本未被修改。

以上 27 帧的双滤波模式共 54 份逐帧 MD5 全部与 FFmpeg 9.0.2 一致。
还增加了原始 PCM 负载越界检查的回归，保证错误时不改变 CABAC 状态。

## 高位深 dependent segment 向量

`patch_hevc_dependent_depth.mbtx` 从上一轮原始 DSLICE A/B/C 的九帧片段
派生 10/12-bit 版本：修改 VPS/SPS 的 profile/compatibility/constraints、
位深 Exp-Golomb 字段，重建 RBSP 对齐与防竞争字节，保留 slice bytes。
Main10 使用 profile 2，12-bit 使用 profile 4 及 max_12bit 约束。

这六组是**派生测试流**，不是原始高位深一致性流。每组都由未修改的
FFmpeg 9.0.2 `-xerror` 独立解码为参考输出；不能把它们当作真实高位深
编码器的全工具组合覆盖。新增 54 帧在默认/跳过滤波两种模式下的 MD5
全部对齐，覆盖普通 dependent 链、WPP 和 tiles 的高位深路径。
本轮没有声称 dependent segment 的 422/444 组合已经验证。

## 再生

下载上述七个 `.bit` 流到 `.scratch/hevc_dep/` 后：

```sh
moon run scripts/generate_hevc_pcm_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_dep
moon run scripts/generate_hevc_pcm_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_dep lossless
# 需要上一轮 dep_a/dep_b/dep_c.265，默认模式可先再生这三个片段。
moon run scripts/generate_hevc_dependent_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_dep depth
moon fmt
```

生成器均使用 `linuxserver/ffmpeg:9.0.2`，参考解码增加 `-xerror`。
夹具内嵌 base64，普通测试不依赖 Docker 或外部文件。

公开接口仅新增可选参数，现有调用保持兼容：

- `hevc_hls_residual_coding(..., transquant_bypass?)`
- `hevc_deblock_picture(..., pcm?)`
- `hevc_sao_apply(..., pcm?)`

`pcm` 是按 SPS min-PU 栅格组织的数组，非零单元表示禁止滤波写入。
新原始采样工具、CU 状态和 CABAC skip helper 均为私有实现。

严格 Wasm check 零警告；全量测试 **1011/1011** 通过。`moon fmt`、
新增/修改脚本格式化、`moon fmt --check` 和 `moon info --target wasm`
已完成并检查兼容接口。全量日志为 `.scratch/hevc_dep/pcm_full_tests.log`。

后续仍有 RDPCM、cross-component prediction、reference-list
modification、tiles 与 WPP 同时启用及当前图片引用等缺口。
