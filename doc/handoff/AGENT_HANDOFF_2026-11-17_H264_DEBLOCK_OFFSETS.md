# Agent 交接：H.264 纯编码器 §433 slice 级去块 α/β 偏移（2026-11-17）

接 `doc/handoff/AGENT_HANDOFF_2026-11-17_H264_CHROMA_QP_OFFSET.md`（§432）。本切片完成
x264 `--deblock alpha:beta` 的纯 MoonBit 编码面，opt-in，缺省 0/0 逐字节不变。

## 1. 做了什么

- 共享 `H264EncParams` 增 `deblock_alpha` / `deblock_beta`（div2 单位，
  -6..=6）。任一非零 → PPS `deblocking_filter_control_present_flag=1`
  （CAVLC `h264_enc_pps_body` 与 CABAC `h264_enc_pps_rbsp_cabac` 两处）。
- 六处 slice 头（CAVLC/CABAC × I/P/B）在 `slice_qp_delta` 后、CABAC 对齐位
  前，按回读 PPS 标志写 `disable_deblocking_filter_idc=0` + 两个 se(v)。
- `h264_enc_deblock_picture` 增 `alpha~`/`beta~`，传 `52+2*偏移` 给
  `h264_filter_mb`（与解码器 `52 + sh.slice_alpha_c0_offset` 同式），
  编码器重建 == 解码器 filtered 输出（含 ±6 角点，黑盒 MD5 钉死）。
- 校验 helper `h264_enc_deblock_offsets_ok`（h264_enc_deblock.mbt）：
  越界 / `deblock=false` 互斥，exact 消息见 doc/PORTING_HISTORY §433。
- 全链透传：intra ×2、batch ×6（含 frames_b）、流式 open/idr/i/p/b、
  VBV/ABR trial（`{ ..self }` 继承 + p 字面量补字段）、门面
  `VideoEncConfig`/`video_encode`/periodic ×3、CLI
  `--deblock-alpha`/`--deblock-beta` + 帮助行。

## 2. 关键文件

| 文件 | 改动 |
|---|---|
| libavcodec/h264_enc_ps.mbt | 参数字段 + PPS 标志派生 |
| libavcodec/h264_enc_deblock.mbt | 滤波偏移参数 + 校验 helper |
| libavcodec/h264_encode.mbt | CAVLC I 全链 |
| libavcodec/h264_encode_p.mbt | CAVLC P slice + frames/vbv/qps 透传 |
| libavcodec/h264_encode_b.mbt | CAVLC/CABAC B slice + frames_b 透传 |
| libavcodec/h264_enc_cabac.mbt | CABAC I/P slice + PPS + 批量三入口 |
| libavcodec/h264_enc_stream.mbt | 流式字段/open/idr/i/p/b |
| libavcodec/video_encoder.mbt / video_encoder_periodic.mbt | 门面透传 |
| cmd/encode-h264/options.mbt / main.mbt | CLI 选项 + 帮助 |
| libavcodec/h264_enc_deblock_offsets_test.mbt | 7 黑盒用例（新） |
| cmd/encode-h264/options_wbtest.mbt | +1 用例（31/31） |

## 3. 设计决策（后续切片沿用）

1. **共享参数块**：新编码旋钮放 `H264EncParams`，PPS writer 零签名改动，
   `moon check` 缺字段错误自动枚举全部字面量站点。
2. **slice 写端读回读 PPS**：编码器自写参数集经真实解析器往返，写/读一致
   由构造保证，不需要额外传参。
3. **互斥拒收**：`deblock=false` + 非零偏移 → Err（未滤波参考 vs 码流声称
   非中性滤波会失配）。idc 恒 0，不做 disable=1/2。
4. 批量转发用单行多参 `deblock~, deblock_alpha~, deblock_beta~,` 写法 +
   `moon fmt` 规范化，避免逐站点缩进匹配（32 处一次完成）。

## 4. 验证基线（本会话钉值）

- 新测 `h264_enc_deblock_offsets_test` 7/7；CLI 31/31
- 57 文件 h264 编码器全量回归 295 用例 0 失败（`.scratch/s433_order.txt`，
  日志 `.scratch/h264_s433_batch{1..7}.log`）
- 全模块 wasm `moon check --deny-warn` 0 错 0 警
- 缺省 0/0：intra/batch/流式/门面逐字节不变（测试断言）

## 5. 本线后续切片

| # | 切片 | 要点 |
|---|---|---|
| 后续 | B 类深层能力 | CRF/scenecut+open-GOP/B 加权/多 slice/lossless/B 金字塔/MB-tree/ME 升级 |
| 备选 | 强制类型 × 码控 | plan 派生编码序 + sizes/fillers 按编码序索引（当前互斥） |
| 备选 | deblock idc=1/2 | slice 边界豁免语义（x264 不发，需求出现再做） |

## 6. 工具链坑（沿用）

- 回归前台小批 ≤9 文件（Windows os error 206）；单文件
  `moon test libavcodec/<file>.mbt --target wasm --no-render`。
- `moon info` 不支持 `--no-render`；heredoc 禁令；python 批量 .mbt 插入禁忌；
  libavcodec 新测试必须黑盒（白盒 wasm `__moonbit__init` local 上限）。
- `H264EncodedFrame` 无 Eq/Debug：Result 断言用 match，不用 assert_eq。
- 仅在用户明确要求时提交（doc/agent.md §3）。