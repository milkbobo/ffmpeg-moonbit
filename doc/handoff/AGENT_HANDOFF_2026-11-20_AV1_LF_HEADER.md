# AV1 编码器 loop_filter 帧头打通交接 —— §468 第一环

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§467（CLI 扩展，已提交 214a591）

## 结果

打通了编码器 → 帧头 → 解码器去块滤波的**参数链路**（§468 第一步）：

`Av1Encoder::encode_frame` 新增三个可选参数
`loop_filter_level0~` / `loop_filter_level1~` / `loop_filter_sharpness~`，
透传到 `Av1KeyFrameEncConfig`。默认全 0，与既有行为完全一致。

**这一步只通参数，不做编码器侧滤波**：设了非零 level 后，解码器会滤波
而编码器的 expected 平面仍未滤波，所以该帧「decode == expected」的契约
暂时不成立——这是刻意的中间状态，第二步（编码器侧滤波）完成后才恢复。

## 关键验证（含两个踩到的坑）

新白盒 **3/3**（`av1_enc_loopfilter_wbtest.mbt`）：

1. **level 到达解码器**：lf=32 vs lf=0 解码输出有 **114 个 luma 像素不同**；
2. **sharpness 到达解码器**：sharp=7 vs sharp=0 有 **117 个像素不同**；
3. **默认等价**：不传参数与显式 `lf=0` 的码流**逐字节相同**。

### 坑 1：夹具阶跃太大，滤波按规范本来就不触发

第一版夹具用 40/200 的硬阶跃（差 160），测出来「像素无变化」，一度
以为参数没接上。实际上 `av1_lf_filter` 的门控是：

```
|p1-p0| <= i && |q1-q0| <= i && |p0-q0|*2 + (|p1-q1|>>1) <= e
```

`i`/`e` 由 level 推出的 limit 很小，**160 的阶跃远超标，不滤波才是正确
行为**。换成 120/128（差 8）的轻阶跃 + ±5 纹理后，立刻出现 114 个差异
像素。

**教训：验证去块是否生效，夹具的边缘差必须落在 level 推导出的 limit
之内；大阶跃不滤波是规范的正常行为，不是 bug。**

### 坑 2：`Array<Int32>` 不是合法语法

编辑时误把 `rd_ref_ages? : Array[Int32]` 写成了 `Array<Int32>`，导致
解析报错「The type alias Array expects 1 argument(s)」。MoonBit 的泛型
用方括号。已修。

## 已确认的后续路径（第二步）

第一步完成后，第二步（编码器侧滤波）需要的零件已全部确认可用
（详见 `AGENT_HANDOFF_2026-11-20_AV1_ENCODER_DEBLOCK_RESEARCH.md`）：

- 底层核 `av1_lf_filter` / `av1_lf_h_y` / `av1_lf_v_y` / `av1_lf_h_uv` /
  `av1_lf_v_uv` 都在同包内可用，且**不依赖 `Av1FrameCtx`**；
- `av1_calc_eih`（造 `Av1FilterLut`）、`av1_calc_lf_values`（造
  `lf_level`）都是同包私有函数，可直接调用；
- 缺的是 **intra 的 lf_mask 构造**（`create_lf_mask_intra` 是
  FrameCtx 方法）与**帧级 cols/rows 循环**（`lf_sbrow_cols/rows` 也是
  FrameCtx 方法），需要新写。

第二步完成后，本节 114/117 个差异像素就是编码器侧滤波必须复现的目标：
expected 平面经滤波后应与解码输出逐像素相同。

## 验证

- 新白盒 **3/3**（见上）。
- 回归全绿：encoder 8/8、refring 5/5、RD 三维 5/5、RD 4/4、skip 5/5、
  NEARMV 2/2、RD×skip 4/4、multiref 4/4、ME 复用 4/4、loop-filter 3/3、
  inter 24/24、tile 12/12、frame 7/7（共 87）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

注：`moon check --target wasm-gc` 会报 `cmd/encode-h264` 的
`FrameReader`/`FrameWriter` 找不到——这是**既有的、与本片无关**的问题
（wasm 目标正常），不要误判为本片引入。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
