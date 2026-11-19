# HEVC 编码器 4:2:2 / 4:4:4 交接 —— §456

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§455（Main10 10-bit 4:2:0）

## 结果

HEVC 编码器新增 **4:2:2 与 4:4:4**（Range Extensions，`profile_idc=4`），
贯通既有 I/P/B、整数及 1/4 像素运动补偿、量化/反量化、去块滤波和 SAO，
8-bit 与 10-bit 均可。纯 MoonBit、wasm-only，无 C FFI。
默认 4:2:0 行为及 §453/§455 既有黑盒钉值不变。

验证：HEVC 编码器测试 wasm-gc **62/62**、wasm 黑盒 **9/9**；FFmpeg 9.0.2 在
`-loglevel error -xerror` 下零告警解出 5 条外部仲裁流，framemd5 已固化到
公开 API 黑盒测试。

## 公开 API

三个入口新增可选 `chroma_format_idc : Int32 = 1`（4:2:0 保持不变）：

- `hevc_encode_frames`
- `hevc_encode_sequence`
- `hevc_encode_intra_frame`

取值 1/2/3 分别对应 4:2:0、4:2:2、4:4:4；0 与 >3 返回
`hevc enc: chroma_format_idc must be 1, 2 or 3`。色度平面尺寸由
`hevc_sub_width_c` / `hevc_sub_height_c` 决定，`hevc_enc_guard_frame` 按格式
校验 `u`/`v` 长度（4:2:2 是 `(w/2) x h`，4:4:4 是 `w x h`）。
既有「不加样本值域拒绝」的约定继续有效。

`HevcEncodedFrame.cstride` 现在等于色度平面行跨度（4:2:0/4:2:2 为
`pad_w/2`，4:4:4 为 `pad_w`）；色度平面高度仍是 `cstride` 无法表达的维度，
4:2:2 请按 `frame.height`（无垂直下采样）取。

## 参数集

- PTL：`chroma_format_idc != 1` 走 Rext 布局——`profile_idc=4`，compat 只置
  第 4 位，随后 9 个 `XXX_constraint_flags`（`max_12bit`/`max_10bit`/
  `max_8bit`/`max_422chroma`/`max_420chroma`/`max_monochrome`/`intra`/
  `one_picture_only`/`lower_bit_rate`）加 34 位保留位，共 43 位，与
  `decode_profile_tier_level` 的 Rext 分支逐位对应。4:2:0 仍写 Main/Main10
  的 43 位保留位，8-bit I/P 码流字节不变。
- SPS：`chroma_format_idc` 按参数写；`chroma_format_idc == 3` 追加
  `separate_colour_plane_flag=0`。一致性窗口偏移按 `hevc_sub_width_c` /
  `hevc_sub_height_c` 折算（4:2:2 只除水平、4:4:4 不除）。
- 4:2:2/4:4:4 的 `hshift`/`vshift` 由既有 `map_pixel_format` 从
  `chroma_format_idc` 推导，`pix_fmt` 相应变成 `yuv422p`/`yuv422p10le`/
  `yuv444p`，无需另写映射。

## 编码器侧改动

### 色度 QP

`hevc_enc_chroma_qp` 改成 `(sps, qp_y)` 两参数、格式通用，返回值**已含**
`sps.qp_bd_offset`。同时新增 `hevc_enc_chroma_qp_fwd(sps, qp_y)`（= 上式减去
`qp_bd_offset`）供前向量化使用，保持 §455 的关系：前向量化用公开 QP，
本地反量化用 `QP + qp_bd_offset`。四个调用点（`hevc_enc_ctu.mbt` 一处、
`hevc_enc_inter.mbt` 三处）与四处重建 QP 已按此改写。

### 变换单元

`hevc_enc_transform_unit` 的色度段改成镜像 `hls_transform_unit` 的循环：

- `log2_c = log2_tb - hshift[1]`，`nc = 1 << log2_c`；
- `n_cb = if chroma_format_idc == 2 { 2 } else { 1 }`，4:2:2 的两个色度块
  上下堆叠于 `y_c = y0 + (i << log2_c)`；
- 每块单独 `hevc_enc_set_na`（尺寸按 luma 单位 `1 << (log2_c + hshift/vshift)`）、
  单独预测、单独量化，并在块 i 之后立即叠加残差——解码器就是这样让块 i+1
  的邻居看到块 i 的重建；
- 每块各写一个 `cbf_cb` / `cbf_cr` bin，顺序仍是 cb 全部在前、cr 全部在后；
- 色度 DM 模式在 4:2:2 下经 `hevc_tab_mode_idx` 重映射（解码器
  `luma_intra_pred_mode` 的同一条路径）；
- 色度扫描索引用**色度模式**选择、但用 **luma** `log2_tb` 门控，因为解码器
  的 `log2_trafo_size < 4` 判断用的是 luma 尺寸。

### 帧间

- `hevc_enc_mc_l0/l1/b` 的色度块尺寸拆成 `csize_w = size >> hs` 与
  `csize_h = size >> vs`。原来只有 `size >> hs`，4:2:2（`vs=0`）会把色度块
  高度写成一半，是本次唯一的运动补偿几何 bug。
- `hevc_enc_code_residual_inter` 的 `cb_levels`/`cr_levels` 从单个
  `FixedArray` 改成 `Array[FixedArray[Int32]]`（4:2:2 两块），cbf 逐块计算、
  逐块写 bin、逐块重建。
- `hevc_enc_coding_unit_inter` 与 `hevc_enc_coding_unit_b` 的量化循环同样按
  `n_cb` 展开；`has_residual` 汇总所有色度块。

## 本轮踩到的坑

1. **色度块高度**：`hevc_enc_mc_*` 里 `csize = size >> hs` 同时用作宽高。
   4:2:0 两者相等所以看不出来；4:2:2 只水平下采样，色度块高度必须是
   `size >> vs = size`。不改会把 4:2:2 的色度预测写少一半。
2. **色度扫描门控**：`hevc_enc_scan_for_mode(tu_mode_c, log2_c)` 看似自然，
   但解码器用的是 luma `log2_trafo_size` 做 `< 4` 判断。4:2:0 时
   `log2_c == log2_tb - 1` 两者同侧，4:2:2/4:4:4 会分叉。改为
   `hevc_enc_scan_for_mode(tu_mode_c, log2_tb)`。
3. **cbf 数组先填长度**：4:2:2 需要在 `chroma_coded == false`（理论上不会
   发生，最小 TU 是 8x8）时也能安全读 `cbf_cb[i]`，所以先按 `n_cb` 压入
   `false` 再在循环里按下标赋值，而不是 `push`。
4. **Rext PTL 与 43 位保留位**：Rext 的 43 位是「9 个约束标志 + 34 位保留」，
   不是 43 位保留。写错时 `decode_profile_tier_level` 的
   `2+1+5+32+4+43+1` 预算检查仍然通过，但字段会整体错位——只能用参数集
   往返测试（编码器每帧都做）来抓。

## 验证

- 白盒 `hevc_enc_422_wbtest.mbt` **12/12**：64x64 往返、非 CTB 对齐 48x40、
  平坦色度（零 cbf 路径）、QP 12/26/40/51、10-bit、SPS 的
  `chroma_format_idc`/shift/`pix_fmt`/Rext profile 断言、10-bit
  `yuv422p10le` 与 `qp_bd_offset=12`、色度平面尺寸守卫、非法格式拒绝、
  I/P 静止帧、I/P 纯平移（色度 MC）、10-bit I/P。
- 白盒 `hevc_enc_444_wbtest.mbt` **7/7**：同上覆盖 4:4:4，另加全平面
  尺寸与 `cstride` 断言、I/P 平移。
- 黑盒 `hevc_enc_422_test.mbt` **3/3**、`hevc_enc_444_test.mbt` **2/2**：
  本仓库解码器逐帧 MD5 与 FFmpeg 9.0.2 对齐。
- FFmpeg 9.0.2 在 `-loglevel error -xerror` 下零告警，输出尺寸自证格式：
  64x64 8-bit 4:2:2 每帧 8192 字节（`64*64 + 2*32*64`）、10-bit 4:2:2
  16384 字节、8-bit 4:4:4 12288 字节（`64*64*3`）。framemd5：

  | 流 | 帧 | framemd5 |
  | --- | --- | --- |
  | `hevc422_i.265` | I | `a4b6e1166c3120c855472b55c8440fcb` |
  | `hevc422_ip.265` | I / P | `a4b6e1166c3120c855472b55c8440fcb` / `a9960e5db6869f77e887e909d7e95d2c` |
  | `hevc422_i10.265` | I (10-bit) | `9e431e626bb8971de4cdfd92aea50aee` |
  | `hevc444_i.265` | I | `d120074228e928227abd8aad38d1f444` |
  | `hevc444_ip.265` | I / P | `d120074228e928227abd8aad38d1f444` / `d2709c85f193d1cc3a0fa4b1c43ab9e0` |

- 可复跑生成器：`moon run --target wasm-gc cmd/generate-hevc-422 <目录>`，
  一次写出上表 5 条流。
- `moon check --target wasm` 0 错误 0 警告（仅既有 `v128` 未使用依赖警告）。

## 边界

- 色度 SAO 仍关闭（`slice_sao_chroma_flag=0`），SAO 只有 luma band 模式；
  4:2:2/4:4:4 不改变这一点。
- 12-bit 未支持（`hevc_enc_guard_frame` 仍只接受 8/10）。PTL 的 Rext 布局与
  `map_pixel_format` 的 12-bit 名字已就位，补 12-bit 主要是放宽守卫并验证
  `qp_bd_offset = 24` 的重建路径。
- 单色（`chroma_format_idc=0`）未开放：色度平面为空时 `hevc_enc_guard_frame`
  会因长度检查拒绝；如需支持要单独处理 `n_cb`/cbf/去块/SAO 的全链路。
- B 片继续由 `b_slices=true` opt-in；默认 8-bit 4:2:0 I/P 行为与钉值不变。
- 码控（CRF/VBV）、多 slice/多 tile、流式 CLI 仍未实现。

## 下一步建议

12-bit 是剩余色度/位深矩阵里最小的一步（守卫 + `qp_bd_offset=24` 验证）；
之后按 `doc/PORTING_HISTORY.md` §456 末尾的路线推进码控与流式 CLI。
