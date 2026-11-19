# HEVC 编码器单色交接 —— §463

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§462（流式 ABR，未提交）；§447-§459 在 733d1f8/37223d7

## 结果

HEVC 编码器开放**单色（`chroma_format_idc=0`）**：空色度平面、picture
几何 0x0（镜像解码器）、Rext profile + `max_monochrome_constraint_flag=1`
（§456 预留约束位生效）、gray/gray10le/gray12le。8/10/12-bit ×
I/P/B/CRF/ABR/流式/CLI（`--chroma 400`）全可用。**位深×色度矩阵十二格
全开**（{8,10,12} × {mono,420,422,444}）。默认 4:2:0 与全部钉值不变。

验证：HEVC 编码器测试 wasm-gc **114/114**；FFmpeg 9.0.2 gray 流零告警
仲裁钉黑盒。

## 本轮真 bug：cbf bins 在门控外

`hevc_enc_transform_unit` 的 **cbf_cb/cbf_cr bins 写在 `chroma_coded`
块外**（按 n_cb 无条件写）——单色流每 TU 多 2 个 bin → CABAC 全链失步。
症状很有迷惑性：**编码器本地重建正确（30）、解码输出错（111=DC 类
预设），且我们解码器与 FFmpeg 读出同一张错图**——即流本身描述的就是
错位图像。修复：bins 写入移入 `chroma_coded` 块（镜像解码器
transform_tree 的 `cfidc != 0` 读取门控）。

**教训**：写侧门控要贴着**解码端读取门控**逐 bin 对照，不能只看
计算/循环路径——bins 序列失步的表现是「自洽的错误图像」而非解码
报错，本地往返测试（enc recon vs dec output）才是抓它的唯一手段。

## 门控清单（触点全录）

守卫（cfidc=0 只查 luma）/frame_ex（cw=ch=0、pad 跳过）/intra DM bin
（不写）/transform_unit（chroma_coded 加 cfidc!=0；cbf bins 入块）/
inter（n_cb=0；MC 三函数色度段包裹——hshift=0 不门控会写 0 尺寸平面）/
SAO（sao_chroma_flag 本就 cfidc!=0 才写；sao_eo 单色可用）/流式 open
（0..3 + sao_chroma 互斥）/CLI（400 + gray* 命名 + 帧尺寸公式 0 色度）。

## 测试与仲裁

- 白盒 `hevc_enc_mono_wbtest.mbt` **4/4**：PTL/pix_fmt 断言（注意 8-bit
  的映射名是 **"gray"** 非 "gray8"）；I/P/B/intra/10-bit/流式恒等；
  互斥与拒绝（§456 的「0/4 拒绝」断言已更新为 4/-1）。
- 黑盒 `hevc_enc_mono_test.mbt` **1/1** 双目标：2 帧流 `yuvp(8)` 恰
  4096 字节，MD5 `e9e605002e93cff46c0d4fd266db85cb` /
  `834f9effbdbf7bb071ecca653a1f677f`（FFmpeg gray framemd5）。

## 检查状态

fmt/info/check 全绿；CLI options 2/2；§460-§463 四切片未提交。

## 下一步

HEVC 编码器大项已清：剩余为完整 CPB/VBV 流级语法、B 片加权/时间 MVP/
多参考、多 slice/tile、SAO merge——均为增强项。建议：提交 §460-§463
（色度 SAO/EO/ABR/单色 四切片）后转回主线清单（AAC USAC、AV1 inter
编码等）或 HEVC 增强项。
