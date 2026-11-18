# HEVC RDPCM 交接（2026-10-27）

本轮在纯 MoonBit Wasm 路径接入 implicit/explicit RDPCM，上一轮进展见
[PCM 交接](AGENT_HANDOFF_2026-10-27_HEVC_PCM.md)。未使用运行时 FFI。

## 实现

`hevc_rdpcm.mbt` 实现空间残差水平/垂直累加，每次加法按 int16 回绕；
explicit flag/dir 使用 CABAC contexts 49/50、51/52，位于 transform skip
之后、last significant coefficient 之前。残差入口新增默认值为 DC=1 的
可选 `intra_mode` 参数，CU/TU 驱动分别传入真实亮度/色度方向。

保留 FFmpeg 的旋转、反量化、RDPCM 顺序；explicit RDPCM 禁用 sign
hiding，implicit RDPCM 在 transform skip 方向模式 10/26 禁用 sign
hiding。transform-skip significance 上下文同时覆盖 transquant bypass。
完整帧和旧 intra 入口移除 RDPCM 拒绝；旧 intra 入口也移除 transform
skip 拒绝。其余尚未支持的 RExt 特征仍明确报错。

每个 CU 开始把四个亮度 PU 方向重置为 DC，避免 inter CU 误用之前的
方向。色度方向则按 C 单线程 local context 保持跨 CU、slice、picture
状态，新增 `HevcDecoder` 私有数组，不增加公开诊断接口。

## 参考实现行为的边界

FFmpeg 9.0.2 `hevc/cabac.c` 的 bypass 分支没有为 implicit RDPCM 加上
`MODE_INTRA` 条件；只要 SPS 开启 implicit，方向还会优先按残留的
TU intra mode 决定，即使该块使用 explicit RDPCM。这与非 bypass
分支不同。本移植保留该上游行为，不自行改成规范算法。

因此这类流的 FFmpeg 输出会受帧线程 local context 的历史影响。
`rdpcm_implicit8` 的默认线程输出、`-threads 1` 输出和 HM 编码器重建
结果并不相同。此处**只声称与 FFmpeg 9.0.2 单线程解码逐像素一致**，
不声称与 HM 重建或 FFmpeg 默认多线程输出一致。所有新参考生成显式
指定 `-threads 1 -xerror`，两种滤波模式使用同样设置。

## 独立验证

HM **16.8 including RExt**，固定镜像仓库提交
`382e0a040c7f0189670c4aad9716d45db977b319`：
[源码](https://github.com/listenlink/HM/tree/382e0a040c7f0189670c4aad9716d45db977b319)。
构建仅删除 `build/linux/common/makefile.base` 的 `-Werror`，处理现代 GCC
对旧 C++ 的警告，不修改编码算法。所有输入为 64×64，五帧 lowdelay，
QP=4、CU=32、Level=3.1；完整配置与输入生成在 `.mbtx` 生成器中。

| 流 | 格式 | 路径 | 插桩 C 确认 |
| --- | --- | --- | --- |
| implicit8 | 8-bit 444 | implicit + bypass | 两方向，4×4/32×32，含残留 inter 色度状态 |
| implicit10 | 10-bit 422 | implicit + transform skip + rotation/sigmap | 两方向，4×4，Y/Cb/Cr |
| explicit8 | 8-bit 420 | explicit + bypass + sigmap | 两方向，4×4/8×8/16×16 |
| explicit12 | 12-bit 444 | explicit + transform skip + sigmap | 水平 56 块、垂直 24 块 |
| both12 | 12-bit 444 | implicit + explicit + bypass + rotation/sigmap | 两工具真实激活，含 32×32；方向沿用上游优先级 |
| mono10 | 10-bit mono | implicit + bypass | 水平 356 块、垂直 300 块 |

六流共 30 帧，默认/跳过滤波共 60 份 MD5 对拍。夹具全部内嵌，无
Docker/网络测试依赖。独立复制原始 C `transform_rdpcm` 产生 128 份
摘要：4/8/16/32 方块、两方向、16 个满范围有符号随机种子，验证累加
溢出行为。该参考表不是用 MoonBit 实现生成。

## 再生

将上述 HM 源码解压到 `.scratch/hevc_rdpcm/HM-382e0a040c7f0189670c4aad9716d45db977b319`。
删除构建警告升级参数后，用 `vpxdev-img` 中 GCC 的
`make -j8 release`（工作目录为 `HM-.../build/linux`）生成 `bin/TAppEncoderStatic`。

```sh
moon run scripts/generate_hevc_rdpcm_vectors.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rdpcm
moon run scripts/emit_hevc_rdpcm_reference.mbtx -- ../libavcodec/hevc/dsp_template.c D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rdpcm
moon fmt
moon test libavcodec --target wasm --no-render --filter '*HEVC RDPCM*'
```

分支插桩不参与夹具生成。可选 `emit_hevc_rdpcm_reference.mbtx` 第三个
参数 `trace` 使用上一轮 `.scratch/hevc_dep/build/ffmpeg`；需要在其两处
`transform_rdpcm` 调用前记录 `bypass/explicit/dir/plane/size/intra`。
日志保存在 `.scratch/hevc_rdpcm/*_trace.txt`，编译副本只用于诊断。

剩余范围：cross-component prediction、reference-list modification、
tiles 与 WPP 同时启用、当前图片引用，以及更多真实工具组合；dependent
segment 的 422/444 组合也尚未验证。RDPCM 尚未与 dependent/PCM 混合
码流组合验证。本轮覆盖是上述六个配置，不能据此声称 RExt 已全覆盖。

验证结果：严格 Wasm check 零警告，全量测试 **1018/1018**；新增七项
RDPCM 回归。`moon fmt`、两份脚本格式化、`moon fmt --check`、
`moon info --target wasm` 与 `git diff --check` 均完成。全量日志保存在
`.scratch/hevc_rdpcm/full_tests.log`，所有必要夹具已内嵌在仓库测试文件。
