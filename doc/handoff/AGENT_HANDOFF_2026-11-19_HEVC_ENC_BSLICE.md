# HEVC 编码器 B 片（双向预测）交接 —— §454

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§453（SAO）

## 本轮完成的内容

编码器从 I/P 扩展到 **I/P/B**，实现真正的双向预测：两个参考列表、L0/L1/BI
三种预测形状、B 片的合并候选与 AMVP。纯 MoonBit、wasm-only，无任何 C FFI。

**结果**：白盒 26/26、黑盒 3/3 全绿，`moon check --target wasm --deny-warn`
零警告，FFmpeg 9.0.2 权威仲裁逐帧 MD5 完全一致。

## 关键设计决策（不要随意改动）

1. **B 片是 opt-in**：`hevc_encode_sequence(..., b_slices=true)`。默认仍只产
   I/P，所以 §453 的全部黑盒 MD5 钉值保持稳定。**若要让 B 片成为默认，必须
   重钉** `hevc_enc_i_test.mbt` / `hevc_enc_p_test.mbt` 的钉值。

2. **编码顺序 `I0, P2, B1, P4, B3, ...`**：每个 B 位于两锚点之间，先编它后面
   的锚点。偶数帧是锚点，奇数帧是 B。帧数为偶数时末尾奇数帧退化为 P。

3. **B 片用内联 RPS**（1 负 POC−1 + 1 正 POC+1），使 `hevc_slice_rpl` 的 L0
   取 `ST_CURR_BEF`、L1 取 `ST_CURR_AFT`，不需要
   `ref_pic_list_modification`。SPS 仍只有 1 个 RPS，所以
   `short_term_ref_pic_set_sps_flag` 宽度为 0 bit，**P 码流字节不变**。

4. **`mvd_l1_zero_flag = 0`**：L1 的 MVD 必须真实编码，不能依赖解码器推断为 0。

5. **P 锚点的 `rps_delta`**：只有"后面还有 B 片"的锚点（`i % 2 == 0 && i + 1 < n`）
   才用 −2，尾帧 P 用 −1。这是本轮修掉的第二个 bug。

## 两个真实 bug 的定位方法（可复用）

### bug 1：B 片 CU 漏写 `tab_ct_depth` / `qp_y_tab`

**症状**：B 帧重建大范围错（3370/4096 像素差 ±1），P 帧完全正常。

**定位**：给编码器和解码器的 CABAC 各加一个 bin trace（`(ctx, bit)`），
逐 bin 对齐比较。I 帧 3708/3708 完全一致、P 帧 1991/1991 完全一致，
B 帧在第 **87** 个 bin 分叉：编码器 `ctx=2`、解码器 `ctx=3`，bin 值都是 1。
ctx 2/3 正是 `hevc_cabac_inter_pred_idc + ct_depth`——编码器以为 CU 深度 0，
解码器以为 1。根因是 `split_coding_unit_flag` 的上下文依赖邻居
`tab_ct_depth`，而 B 路径（skip 分支直接 return、inter 分支末尾也没补）
从未写过它，于是**从第二个 CU 起**四叉树划分就分叉了。

**修复**：抽出 `hevc_enc_b_post_cu(ctx, x0, y0, cb_size, cb_depth)`，
skip 分支和函数末尾都调用。

**教训**：任何新 slice 类型的 CU 编码器都必须复制 P 路径的
`tab_ct_depth` / `qp_y_tab` 尾部记账。漏掉它不会报错，只会静默错位。

### bug 2：尾帧 P 片的 `rps_delta` 误用 −2

**症状**：修完 bug 1 后 B 帧（poc 1）完全正确，但 poc 3 全错（4096/4096）。

**根因**：原逻辑对所有 P 片都用 −2，但末尾那个 P 前面并没有 B 帧，它的 L0
应是紧邻的前一张图（delta −1）。编码器把 P2 的重建当参考，解码器却按 RPS
去找 POC 1。

**修复**：`has_following_b = is_b_interleaved && i % 2 == 0 && i + 1 < n`。

## 调试基础设施（本轮临时加、已清理）

逐 bin 对比的完整做法，下次遇到编解码不同步时直接照做：

1. 编码器 `HevcEncCabac` 已有 `trace : Array[(Int32, Int32)]`，在 `bin` 里
   记 `(ctx, bit)`、在 `bypass` 里记 `(-1, bit)`。
2. 解码器在 `HevcCabac::bin` 里往模块级 `Ref[Array[(Int32, Int32)]]` 追加。
   **注意**：`let mut` 在 MoonBit 顶层不可用，必须用 `Ref`。
3. 比较时**过滤掉编码器 trace 里的 bypass 项**（`ctx < 0`），因为解码器
   只记 context-coded bin。
4. 单帧解码验证：只把该帧的 `annexb` 喂给 `ff_hevc_decode_frames_ex`，就能
   把 decoder trace 按帧切开。
5. `HevcEncodedFrame` 临时加 `cabac_trace` 字段带出编码器 trace；CTU 循环
   返回 `Array[Byte]` 装不下，用模块级 `Ref` 转存。

## 码流导出与 FFmpeg 仲裁

`.mbtx` 脚本无法 `import @libavcodec`，所以走临时 `zz_*_wbtest.mbt` 打印 hex：

- 打印 `ZZSTREAM_HEX:<hex>`，PowerShell 抓取后写 `.scratch/hevc_enc/bslice.265`。
- **hex 拼接的坑**：MoonBit 里 `"0123456789abcdef"[i]` 取的是 `Char`，
  `write_char` 类型不匹配；用 `Array[String]` 查表 + `write_string` 最稳。
- 仲裁命令：
  ```
  docker run --rm --network none -v "D:\project\FFmpeg-n9.0.2\moonbit\.scratch\hevc_enc:/work" \
    --entrypoint ffmpeg linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel warning -xerror \
    -i /work/bslice.265 -f framemd5 -
  ```
- 想要逐帧 MD5 对账，再导出 `-pix_fmt yuv420p -f rawvideo /work/x.yuv`，
  按 `w*h*3/2` 切帧算 MD5，与编码器重建的 hex 对比。

## 当前 B 片码流钉值（FFmpeg 9.0.2 framemd5，64x64、qp=26、4 帧 I/B/P/P）

| 帧 | POC | slice_type | MD5 |
|----|-----|-----------|-----|
| 0 | 0 | I (2) | `8ef0079cf2173e40bd90a7e2868a95da` |
| 1 | 2 | P (1) | `3fb850ebcb18a7d0efe6e9cd031bd7e8` |
| 2 | 1 | B (0) | `db76e5fb00c495b2746f4ce8acb1fa3c` |
| 3 | 3 | P (1) | `c558552fa4e0d35a7644f4b0a637d227` |

（按编码顺序；显示顺序是 POC 0,1,2,3。）

码流总长 2827 字节。生成该流的测试内容：`y0 = (i*3+j*5)&255`、
`y1 = (i*3+j*5+17)&255`、`y2 = (i*3+(j+4)*5)&255`、`y3 = (i*2+(j+7)*3)&255`，
`u = (i*7+j*3)&255`、`v = (i*11)&255`。

## 关键代码位置

| 文件 | 内容 |
|------|------|
| `libavcodec/hevc_enc_inter.mbt` | `hevc_enc_make_rpl`、`hevc_enc_mc_l1`、`hevc_enc_mc_b`、`hevc_enc_me_search_ref`、`hevc_enc_sad_bi`、`hevc_enc_merge_candidates`、`hevc_enc_merge_match_b`、`hevc_enc_fill_mvf_b`、`hevc_enc_amvp_l1`、`hevc_enc_l0_delta`、`hevc_enc_l1_delta`、`hevc_enc_coding_unit_b`、`hevc_enc_b_post_cu` |
| `libavcodec/hevc_enc_cabac.mbt` | `inter_pred_idc`（`pred_flag` → idc 映射）、`mvd_coding` / `mvd_one` |
| `libavcodec/hevc_encode.mbt` | `hevc_enc_slice_header` 的 B 分支、`hevc_enc_frame_ex(ref_pic_l1~, rps_delta~)`、`hevc_encode_sequence(b_slices~)` 的编码顺序与参考记账 |
| `libavcodec/hevc_enc_ctu.mbt` | `HevcEncCtx` 的 `ref_pic_l1` / `tab_mvf` 字段、CU dispatch（B → `hevc_enc_coding_unit_b`） |
| `libavcodec/hevc_enc_p_wbtest.mbt` | `hevc_enc_b_roundtrip` + 4 个 B 片永久测试 |

## 已知边界 / 后续可做

- 只做 **2Nx2N** 的 B CU。`part_mode` 的 2NxN / Nx2N / NxN 未实现。
- **加权双向预测**（`weighted_bipred_flag`）未实现，PPS 里恒为 0。
- **时间 MVP**（`sps_temporal_mvp_enabled_flag`）恒为 0。
- 多参考帧索引（`num_ref_idx_l0/l1_active` > 1）未实现。
- 每帧单 slice、单 tile；去块与 SAO 只覆盖 luma。
- `HevcIntraDecoder::deblocking_boundary_strengths` 与 `hevc_bs_derive` 仍有
  逻辑重复，可以合并（§452 遗留）。

## 下一步路线

Main10/4:2:2/4:4:4 → 码控（CRF/VBV）→ 流式 + CLI。
