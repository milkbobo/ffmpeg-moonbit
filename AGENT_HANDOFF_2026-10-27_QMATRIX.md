# AV1 qmatrix（2026-10-27）

在 AAC SBR（PORTING_HISTORY §98）之后继续迁移，补齐 AV1 整帧量化矩阵。
运行时仍为纯 MoonBit/Wasm；C 代码只用于独立参考向量。

## 实现

- `av1.mbt` 不再跳过矩阵级别，保存 `qm_y/qm_u/qm_v`；
  `separate_uv_delta_q=false` 时 V 继承 U。未启用时级别为 15。
- `av1_qm_tables.mbt` 保留 dav1d 1.5.1 `src/qm.c` 的 BSD 许可证，
  存储原始 32×16 和 32×32 三角表（共 31,200 个字节）。
  `av1_qm.mbt` 直接计算采样/转置地址，不展开 19 种尺寸的完整矩阵；
  64 点变换沿用对应的 32 点矩阵，级别 15 返回 identity 权重 32。
- `av1_decode2.mbt` 的系数反量化在乘 token 和 `dq_shift` 之前执行
  `(dq * weight + 16) >> 5`，保留 Golomb 的 20 位 token、24 位乘积掩码、
  正负饱和边界和上下文累计值；`txtp >= IDTX` 绕过矩阵。
- 帧上下文只创建一次三个平面的级别数组，关键帧和 inter 的 coefficient
  state 共用。`av1_decode6.mbt` 移除 qmatrix 拒绝入口。
- **公开接口变化**：`Av1FrameHeader` 新增三个只读级别字段；
  `Av1CoefState` 新增 `qm_levels : FixedArray[Int32]`，顺序为 Y/U/V。
  手动构造 coefficient state 的调用方应填 `[15, 15, 15]` 保留旧行为。

## 独立验证与再生

1. 提取权重表：

   ```sh
   moon run scripts/extract_av1_qm.mbtx .scratch/av1/trace_src/src/qm.c
   ```

2. 编译原始 C 初始化代码，生成每个矩阵按存储顺序的 FNV-1a 摘要：

   ```sh
   moon run scripts/emit_av1_qm_reference.mbtx .scratch/av1/trace_src/src/qm.c D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1
   ```

   脚本将原始 `qm.c` 仅去掉 include 后嵌入 C harness；保留上游全部
   untriangle/subsample/transpose/init 函数。`vpxdev-img` 中 gcc 编译，
   16 级别 × 两种平面 × 19 个变换的 608 个摘要全部匹配 MoonBit。

3. 生成 13 组 IVF 与 FFmpeg 9.0.2/libdav1d framemd5：

   ```sh
   moon run scripts/generate_av1_qm_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1
   ```

   原始编码参数完整记录于脚本，使用 `linuxserver/ffmpeg:9.0.2`。
   `qm_separate` 的历史文件名指 enable-chroma-deltaq 样本；其序列
   separate_uv_delta_q 实际仍为 0，不把它当作独立 UV 语法的证据。

   `patch_av1_qm_planes.mbtx` 从 `qm_44410` 第一关键帧派生另外两组：
   原始系数保持不变，设置序列的 separate_uv_delta_q，插入 diff_uv_delta=0，
   改写三个矩阵级别为 (3,8,12) / (0,15,7)，调整 header 对齐及 OBU/IVF
   长度。位偏移由 FFmpeg `trace_headers` 确认；修改后再次由同一工具确认
   字段，并由 libdav1d 解码生成期望 MD5。两者均为有效单关键帧流。
   第二组专门验证仅 U 平面禁用矩阵。原始及派生流总计 57 帧逐帧 MD5 一致。

4. `moon fmt` 后运行仓库标准 check/test/info。两份原有 AAC SBR
   base64 夹具超过编译器列限制，本轮仅拆分字面量并保留相同编码数据。
   `compact_test_bytes.mbtx` 新增可选路径参数，默认行为保留。

最终验证：严格 Wasm check 零警告，全量测试 **987/987**；包和新增/修改
脚本已格式化，`moon info --target wasm` 已生成并检查接口。

## 后续范围

本轮完成 qmatrix，并为更广 inter 格式增加代表性码流验证。尺寸切换、
superres 与 qmatrix 的组合、更多 segmentation/delta-q 组合仍需补测。
film grain/intrabc 按现有项目边界未实现。H.264、HEVC、VP9、AAC/MP3/Opus
及容器的其他已知缺口仍见 README；本轮没有把这些缺口标记为完成。
