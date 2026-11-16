# H.264 4:2:2 高位深收口（§422d）

接续 WIDE_RD_QUANT。`§420` 交付 4:2:2 时暂只开 8-bit（「高位深 + 4:2:2
未接，缺专项」）；本轮探针证明 `§419`/`§421` 的深度泛化
（qp_ext、dequant、chroma_qp 表按深度平移、16-bit 平面装卸）对
chroma_format=2 **已经全链贯通**——9/10/12/14 位 round-trip 首跑即绿，
零实现改动。本片的工作是专项化 + 外部仲裁 + 两处遗留红的清偿。

## 组合语义（已验证）

- 深度 ≤10：profile 122（High 4:2:2，其规范域就是 8..10）；
  深度 >10：profile 244（Hi444PP 是唯一 bit_depth_minus8≤6 的 profile，
  4:2:2 是它的子集——本仓解码器与 FFmpeg 都按此接受）。
  chroma_format_idc 恒 2；`h264_get_chroma_qp` 的 420/422 共表 + 深度
  平移对两种色度格式同一条路径（444 才直通）。
- 入口文档同步：`chroma_format~` 注释去掉「8..10 bits」限定。

## 新专项（libavcodec/h264_enc_c422_depth_test.mbt，4 项）

1. round-trip：9/10/12/14 × CAVLC/CABAC，7 帧默认 B 调度（b_parts/
   intra/weightp/dct8 全默认开），SPS profile/chroma/depth 断言 +
   recon == 本地 skip_lf 解码（编码序）。
2. 流式 = 批式逐字节（10/12 × 双熵）。
3. 在线 VBV + 默认 B 工具 + multi_ref=3 + AQ/AUD + 第 2 显示位强制 IDR
   （10/12 × 双熵；六 AU、逐 AU QP、VBV 位统计与实际流一致、四 inter
   recon == skip_lf 解码）。
4. FFmpeg 仲裁锚点：ARBC22D10（CAVLC）/ARBC22D12（CABAC）六帧 qp24，
   docker framemd5 零告警，显示序 MD5 与本仓默认（带滤波）解码逐帧
   相同后钉值。

## CLI

- `--chroma 422 --bit-depth 10|12` 端到端（`raw_frame_size` 16-bit 翻倍、
  双熵 round-trip、yuvp 全高色度平面长度）；CLI 29/29。
- `video_pixel_format` 补 9/12/14 位 422 命名断言（yuv422p9le/12le/14le）。

## 遗留红清偿（本轮基线发现的 2 个）

1. **`stream_c444_test.mbt` 陈旧负例**：BI16 轮删除 4:4:4 B 拒收条件时
   「更新旧默认拒收测试」漏了这一处——444 B 全工具已放开，负例主体
   消失。删除该测试块，注释指向正向覆盖所在文件。
2. **`h1214_test.mbt` depth=14 钉值**：WIDE_RD_QUANT 的 Int64 SSD/量化
   改变了 14 位 B/P 决策（I 帧不变，显示帧 1 起全变）。docker framemd5
   零告警、与本仓默认解码六帧全同后重钉（12 位 CAVLC 原钉值未动）。

## 验证

- c422_depth 4/4；CLI 29/29；video_encoder/h1214/stream_c444 15/15。
- 全族回归（h264_enc*+h264_encode*，wasm release）见本轮日志。
- `moon check --target wasm --deny-warn`、`moon info --target wasm`。
- 无 C ABI/所有权变更，未跑 ASan。
- docker 仲裁脚本与流：`.scratch/c422d/`（extract_arbh.py 复用于
  ARBC22D 两标签）。

## 下一步候选

- B inter 8x8 DCT 的 420/422 面（444 已通，BINTER8 后唯一剩的变换缺口）。
- 流式 ABR（总字节契约待用户定夺）。
- §419 遗留：BDirect16 胜者脏 cell 潜伏 bug（420 B 调度）。
