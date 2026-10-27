# AI 交接：HEVC 跨分量预测（CCP）与 DPB 按需分配

本轮完成 CCP 接线并修复全量测试的内存耗尽。全量 **1025/1025** 通过，
严格 Wasm check 零警告。工作区仍未提交（沿用前几轮的未提交状态）。

## 工作目录与约束

- Windows / PowerShell，仓库：`D:/project/FFmpeg-n9.0.2/moonbit`。
- 用户原始目标：持续将 FFmpeg 功能迁移到纯 MoonBit。视频 H264/HEVC/AV1/VP9/MJPEG/PNG；音频 AAC/MP3/Opus；容器 MP4/MKV/TS/HLS/DASH/WebM/WAV。
- 当前按剩余功能逐轮推进，远未宣称完整替代 FFmpeg。
- **整个工作区有大量前几轮未提交改动，不能 reset/clean/覆盖。本轮没有创建提交。**
- 先读 `agent.md`，以及 `C:/Users/milkb/.agents/skills/` 下相关 MoonBit skills。按适用内容执行，运行时保持纯 MoonBit，无 FFI。
- 自动化只用 `.mbtx`，不新写 Python/PowerShell/Shell 自动化脚本。直接运行命令可以；C 文件仅作离线参考内核。
- 不主动创建子代理；需用户或适用本地规则明确授权后才可委派。
- 修改后运行 fmt、严格 Wasm check、相关测试、`moon info`；生成的 `.mbti` 不手改，当前被 Git 忽略。

## 最近基线（按顺序阅读）

1. `AGENT_HANDOFF_2026-10-27_QMATRIX.md`：AV1 qmatrix，987 项。
2. `AGENT_HANDOFF_2026-10-27_HEVC_DEPENDENT.md`：dependent segments，993 项。
3. `AGENT_HANDOFF_2026-10-27_HEVC_PCM.md`：PCM、bypass、高位深派生流，1011 项。
4. `AGENT_HANDOFF_2026-10-27_HEVC_RDPCM.md`：implicit/explicit RDPCM，1018/1018。

README 与 PORTING_HISTORY 已更新到本轮（README HEVC 行 + CCP 段落，PORTING_HISTORY §103）。

## 本轮改动

### 1. 跨分量预测（新功能）

新增 `libavcodec/hevc_cross_component.mbt`：

- `HevcCabac::cross_component_scale`：Cb/Cr 独立的四步截断一元绝对值（contexts 167..174）与符号（175..176），结果 0/±1/±2/±4/±8。
- `hevc_cross_component_residual`：`chroma += (scale * luma) >> 3`，逐项 int16 回绕（不饱和），像素裁剪在之后。

`libavcodec/hevc_residual.mbt`：公开 `hevc_hls_residual_coding` 签名与 Unit 返回不变，改为包装；私有 `hevc_decode_residual` 返回空间域残差数组，并接受私有可选 `cross`（亮度残差, scale），在逆变换/RDPCM 之后、加到图片之前合成。必须使用裁剪前的亮度残差，不能用解码图与预测图之差。

`libavcodec/hevc_intra_decode.mbt`：新增原始 chroma syntax mode 表（`pu_chroma_mode`/`tu_chroma_mode`），随 NxN PU 与 TU 分裂继承，区别于已映射的 `pu_mode_c`/`tu_mode_c`。门控为 `PPS cross flag && cbf_luma && (inter || 原始色度模式 == 4)`；先解亮度并保留残差，再依次处理 Cb、Cr；色度 CBF=0 时仍生成纯亮度预测残差。删除旧 intra 入口的 CCP 拒绝。

`libavcodec/hevc_inter_decode.mbt`：删除完整帧入口的 CCP 拒绝，更新支持说明。

### 2. DPB 按需分配（修复全量 OOM）

全量曾报 `Total tests: 1025, passed: 692, failed: 333`，失败均为
`RuntimeError: unreachable at moonbit.alloc_externref`。定位过程：

- 单测单独跑通过；失败在驱动内累计出现，属于 Wasm 线性内存耗尽（峰值 RSS 约 3.5 GB）。
- 用 `moon test <多个文件路径>` 二分：`hevc_dependent_wbtest.mbt` 单文件峰值 3.2 GB，单个测试 1.2 GB。
- 临时关闭 CCP 门控、改回旧亮度调用、让内部函数不返回数组，内存均不变，排除本轮 CCP 代码。
- 根因：`hevc_dpb_new` 预先创建 40 个槽位，每槽都分配整帧画面和 min-PU 运动场。上游 `alloc_frame` 是按需分配。

修复（`libavcodec/hevc_refs.mbt`）：`HevcRefFrame.pic`/`tab_mvf` 变为 `mut`，建库时给空画面与空运动场；新增 `HevcDpb::prepare_slot`，在 `set_new_ref` 与 `generate_missing_ref` 认领槽位时分配（槽位复用时保留缓冲）。dependent 单测峰值 1.2 GB → 0.45 GB，全量峰值 3.5 GB → 2.4 GB，全量恢复。注意：这改变了 `HevcRefFrame` 在槽位未被占用时的 `pic` 尺寸（0×0），任何新代码不要读取未认领槽位的画面。

## 验证

- `moon check --target wasm --deny-warn --no-render`：通过，零警告。
- `moon test --target wasm --no-render`：**1025/1025**，日志 `.scratch/hevc_ccp/full_tests_after.log`。
- 六个 HM 4:4:4 五帧流（30 帧）× 默认滤波/skip_loop_filter 共 60 份 MD5 对齐 FFmpeg 9.0.2 `-threads 1 -xerror`。
- C 插桩确认工具激活（如 ccp8 2604 个 scale 语法、2380 个 CBF=0），插桩二进制 YUV 与未修改 FFmpeg 逐字节一致。
- 原始 C 合成循环 576 份摘要（4/8/16/32 × 九种 scale × 16 seeds）。

新增测试：`hevc_cross_component_wbtest.mbt`（7 项：6 组整流 + 576 组内核对照）、`hevc_ccp_reference_wbtest.mbt`、六个 `hevc_ccp*_realdata_wbtest.mbt`。

再生命令：

```powershell
moon run scripts/generate_hevc_ccp_vectors.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_ccp D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_rdpcm
moon run scripts/emit_hevc_ccp_reference.mbtx -- ../libavcodec/hevc/cabac.c D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_ccp
moon run scripts/trace_hevc_ccp.mbtx -- D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_dep D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_ccp
```

HM 16.8 including RExt，commit `382e0a040c7f0189670c4aad9716d45db977b319`，源码与编码器在 `.scratch/hevc_rdpcm/`。仅移除 `-Werror` 以兼容现代 GCC。

## 下一步

1. HEVC reference-list modification（RPLM）、tiles+WPP 同时启用、当前图片引用（CPR）。
2. dependent segment 的 422/444，及 CCP 与 dependent/PCM 的组合仍需单独验证；不要把六个 CCP 配置外推为全部 RExt 工具组合。
3. 若继续降低测试内存：`tab_mvf` 仍是每 min-PU 三个对象（MvField + 两个 Mv），可考虑扁平化；DPB 的 40 槽位名实不符（上游 32），未改槽数。
4. 其他编解码器/容器缺口见 README。

## 环境坑

- PowerShell 下用 `rg -g 'hevc*.mbt' libavcodec`；不要把通配符当文件参数。
- `.mbtx` 顶层用 `async fn main`，for 更新表达式不用 `+=`，空 Map 用 `Map([])`。
- `moon fmt` 默认不处理独立 `.mbtx`，需逐路径显式格式化。
- 内嵌 base64 每段最多 40000 字符。
- 内存问题排查：`moon test <file1.mbt> <file2.mbt> ...` 可精确选文件；`moon test <file> -i N` 选单个测试；配合 PowerShell 轮询 `Get-Process moonrun` 的 `WorkingSet64` 测峰值。
