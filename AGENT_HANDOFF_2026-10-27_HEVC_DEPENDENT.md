# HEVC dependent slice segments（2026-10-27）

后续更新：10/12-bit 420 的派生流验证、PCM 和 transquant bypass 现已补齐，
见 [后续交接](AGENT_HANDOFF_2026-10-27_HEVC_PCM.md)。下文保留本轮完成时的状态。

接续 AV1 qmatrix，本轮完成 dependent segment 的帧头、CABAC/QP/邻域继承、
WPP 和 tiles 的单线程分段解码，并修复真实 B 帧暴露的三个原有问题。
运行时仍为纯 MoonBit/Wasm。

## 实现

- `ff_hevc_decode_slice_header` 增加可选的 `previous` 参数；独立 segment
  沿用原来的四参数调用。dependent segment 校验 PPS 和地址后继承前段头，
  只重新解析 entry points、扩展、alignment 和 CABAC offset。没有可继承
  的头或非法零地址时明确报错；公共批量解析入口自动维护前段头。
- AU 探测对 dependent segment 不读取不存在的 slice_type/POC，保留第一
  独立 segment 的 AU 信息。帧驱动校验 tile-scan 顺序中前一 CTB 已属于
  当前独立 slice，缺失前段时报错。
- dependent segment 启动新的算术解码器，但继承概率状态；tile 首 CTB
  重置概率，WPP 行首装入上一行第二 CTB 的概率，单 CTB 宽行使用初始
  概率。WPP 保存状态跨 segment 保留。统一的 tile-scan CTB 循环替代
  原有三套循环，可处理行中起始 segment。
- dependent segment 不新增独立 slice 编号，不重复构建 RPL；QP delta
  开启时保留 QP/qPy_pred 历史，first_qp_group 按依赖关系及 WPP/tile
  边界更新。邻域可用性用独立 slice 起点，而不是当前 segment 起点。

## 对拍中修复的原有问题

1. `HevcCabac::ref_idx_lx` 原先按 L0/L1 选择两套 context。
   FFmpeg `cabac.c` 对两份参考列表都使用 `REF_IDX_L0_OFFSET`。
   FATE 的 B 帧使用多个 L1 参考时，旧代码在参考索引处开始 CABAC 失步。
   本轮统一上下文并删掉私有 helper 的 list 参数。
2. `hevc_hls_residual_coding` 原先对所有 4×4 亮度块使用 DST。
   现在只有 intra 4×4 亮度走 DST，inter 走 DCT/DC 路径。
   第一个 inter 显示帧中仅 281 个亮度像素有误，后续参考传播扩大差异；
   预测单元 MV 全部对齐后据此定位变换选择。
3. 1920×1080 的底部色度滤波循环原先无条件读取第二半块的 QP，
   该半块可能落到图外。bs1 != 2 时 tc1 恒为 0，现跳过无用读取，
   保留相同滤波输出并避免数组越界。

调试使用官方 `n9.0.2` HEVC C 源插桩，固定单线程；首三帧共 4341 个
prediction units 的活跃参考索引和 MV 全部与 MoonBit 一致。插桩 C
输出 raw YUV 也与未修改的 `linuxserver/ffmpeg:9.0.2` 完全相同。

## 向量与再生

来源为 FFmpeg FATE 的 HEVC 一致性测试流：

- https://fate-suite.ffmpeg.org/hevc-conformance/DSLICE_A_HHI_5.bit
- https://fate-suite.ffmpeg.org/hevc-conformance/DSLICE_B_HHI_5.bit
- https://fate-suite.ffmpeg.org/hevc-conformance/DSLICE_C_HHI_5.bit

三者均为 1920×1080、8-bit 4:2:0；A 含多个独立 slice 及其依赖链，
B 含 WPP（包括行中起始 segment），C 含 tiles。每组截取前九个解码
包，覆盖 I/B、POC 0..8 的重排序及跨帧参考，共 27 个显示帧。
两套参考分别为默认滤波和 `-skip_loop_filter all`；54 个逐帧 MD5
全部一致。夹具以分段 base64 内嵌，测试不依赖下载或 Docker。

下载原始流到 `.scratch/hevc_dep/` 后运行：

```sh
moon run scripts/generate_hevc_dependent_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/hevc_dep
moon fmt
moon test libavcodec --target wasm --no-render --filter '*HEVC dependent*'
```

六项回归覆盖三组真实流（每组双滤波模式）、独立头继承、缺失前段、
非法零地址与截断输入。新夹具使用最长 40,000 字符的 base64 chunk：
112 字符分块会使整个 libavcodec 白盒模块的 Wasm 初始化函数超过
局部变量数量上限，单行超过 65,535 字符又会触发列长度警告。

最终验证：`moon check --target wasm --deny-warn --no-render` 零警告，
全量 Wasm 测试 **993/993** 通过；包和新增脚本已格式化，
`moon info --target wasm` 已生成并检查可选参数的兼容接口。

## 边界与后续工作

本轮 dependent segment 的端到端向量为 8-bit 4:2:0；10/12-bit 和更多
色度格式的组合尚未单独验证。tiles 与 WPP 同时启用仍明确拒绝；PCM、
RDPCM、transquant bypass、cross-component prediction、当前图片引用
及 reference-list modification 继续按现有边界拒绝。

调试产物位于 `.scratch/hevc_dep/`。本地上游目录的 `hevcdec.c` 曾丢失
两处函数/引用初始化片段；插桩参考以官方
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.2/libavcodec/hevc/hevcdec.c`
核对并补全在 scratch 副本中，未修改仓库外的上游源文件。
