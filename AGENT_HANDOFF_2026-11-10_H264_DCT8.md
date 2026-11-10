# AGENT_HANDOFF_2026-11-10 — H.264 transform_8x8（8x8DCT）写端（§385）全绿

## 本片结论

High profile `transform_8x8` 的编码器写端完成并 opt-in 接线
（`dct8x8=true`）：I 帧 I_NxN 的第三候选 **I8x8**（transform_size_8x8_flag
+ 每 8x8 块 pred8x8l + cat5 残差）与 P 帧 **inter 8x8 残差**
（dct8x8_allowed 门 + flag bin + cat5）。默认关闭，既有全部钉值逐字节不变。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 干净 |
| 白盒探针 `h264_dct8_wbtest.mbt`（误差率 + 斜坡） | **2/2** |
| 黑盒 `h264_encode_dct8_test.mbt`（I/P 双测 + ffmpeg 钉值） | **2/2** |
| 存量编码器测试（CAVLC/CABAC/P-intra） | **32/32** |
| 全仓 `moon test --target wasm-gc` | **1733/1733** |
| 非 gc wasm（cmd/avutil/avformat/swr/swscale/wasm_probe） | **853/853** |
| x264 native C oracle（docker `nine-x264`，含新增 8x8 用例） | **13/13** |
| docker ffmpeg 9.0.2 framemd5 | 零告警，三帧与本仓滤波输出逐字节一致 |

## 定标方法论（下片可复用）

1. **fdct8 正变换**取 x264 `DCT8_1D` 权威形式（WebFetch 公开镜像；docker
   镜像只有 x264 头文件没有源码）：偶部纯加减、奇部 `3·d07+2·d16+2·d25`
   移位近似族；免移位约定（DC 增益 = 8 点和），与既有 fdct4 同款。
2. **MF8 用不变式定标，别用「误差该多小」直觉**：量化步长（`2^qbits/MF8`）
   必须等于反量化步长（`qmul8/64`，`qmul8 = init8·scaling << div`）→
   `mf8 = round(2^19/init8)`。此式**逐值复现 x264 `quant8_mf` 真表**
   （26214/29127/16384/27541/20972/21846）——外部权威双重确认。
3. **误差率对照才是定标判据**：白噪声残差下 4x4 已验证链本身就是 ~93%
   误差率（量化杀高频），逐 QP 误差率相等（93/89/92 vs 93/89/92）即定标
   正确；低频斜坡另设 SSD 门（8x8 严格不劣于 4x4：5377 vs 8388）。
   「误差 < 能量的 1/8」这类直觉断言是错的，别再写。

## 语法速查（8x8 全部新增位）

| 语法位 | 值/位置 |
| --- | --- |
| I 帧 flag | mb_type 首 bin（@3+c=0）后：ctx **399 + neighbor_transform_size**（左/上 8x8 数） |
| P 帧 flag | cbp bins 后、dqp 前：同 ctx 399+邻居，仅 `dct8x8_allowed && cbp&15≠0` 时读写 |
| P 帧 allowed | PPS 位 && 全部分割 ≥8x8（P_8x8 须四子块全 sub_mb_type 0；I16 恒否） |
| I8x8 模式 | z 序 0/4/8/12 槽位各一个，ctx 68/69 与 I4 同 bin 树；modes 2x2 复制 |
| I8x8 残差 | cat 5、`h264_zigzag_scan8x8`、4:2:0 **无 cbf bin**（cbp 位隐含，空块非法） |
| 残差 ctx | sig = base + `h264_cabac_sig8[q]`、last = base + `h264_cabac_last8[q]` |
| nz 回填 | 象限 2x2 填 count（`fill_rectangle` 镜像）；I 帧矩阵 0、inter 矩阵 3 |
| 重建捷径 | `h264_idct8_add4`：total==1 且仅 DC → `h264_idct8_dc_add`，否则全 idct8 |

## 决策与镜像要点

- I8x8 决策：对 I4 **平价即胜**（4 模式树+≤4 残差块 vs I4 的 16+16，语法
  严格更省）；对 I16 仍 6% 门槛（`100*i8 < 94*i16`）。
- I8x8 评估 pass 的 modes 写**独立 scratch 数组**——`cur_modes` 必须保持
  零值进入 I4 pass（I4 的块内预测器读它；解码端 modes 数组每 MB 从零起）。
- redo = 评估函数再调一次（确定性一致）：首块只读 MB 外边界样本，后续块
  读 pass 自己刚重建的 8x8 块——与解码端重建顺序 0..3 完全同构。
- **`info.transform_8x8` 生命周期（本片修复的真分叉）**：FFmpeg 是每 MB
  独立的 `MB_TYPE_8x8DCT` mb_type 位，未读 flag 的宏块对邻居 ctx399 贡献
  0。原移植只置真不清零 → 混合流跨 MB 残留分叉。修复：CABAC
  （`h264_decode_mb_cabac`）与 CAVLC（`h264_decode_mb`）入口清零，编码器
  两个 MB 循环同款。

## 复现命令

```sh
# 黑盒（宿主 wasm）
moon test --target wasm --no-render libavcodec/h264_encode_dct8_test.mbt
# 白盒探针（wasm-gc，避开 V8 局部数上限）
moon test --target wasm-gc --no-render libavcodec/h264_dct8_wbtest.mbt
# 全仓
moon test --target wasm-gc

# 外部仲裁：测试打印的 DCT8ARB 行 → Annex B → docker ffmpeg framemd5
python -c "import re,pathlib; s=pathlib.Path('.scratch/dct8arb_raw.txt').read_text(); pathlib.Path('.scratch/dct8.264').write_bytes(bytes(int(x) for x in s.strip(',').split(',')))"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -y -v warning -i /work/.scratch/dct8.264 -f framemd5 -c:v rawvideo /work/.scratch/dct8.md5"

# x264 C oracle（13/13）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native \
   -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"
```

钉值 `5e000f9f8f4751c735c9595853041e9c / b765d76e71eff64313c6355e8bfcc8af /
2070b0ecc8fee0af012416d7456d5468`（已进黑盒 inspect；qp24、96×64×3、
斜坡+棋盘+游走方块夹具）。

## 剩余

1. CAVLC 8x8 写端（读端 `h264_cavlc8.mbt` 已有；写端需 8x8 的
   coeff_token/total_zeros/run 表镜像 + `transform_size_8x8_flag` 位写）。
2. 码率控制 / 广义 RD（QP 恒定）。
3. I16 与 8x8 转默认策略（需重钉全部仲裁钉值与质量门）。
4. P 帧 CABAC 位定价（现用 CAVLC 位数估位，§381 既有取舍）。
5. 8x8 与 I4 的真 RD 竞争（现为 SAD 平价即胜 + allowed 即用）。

## 权威文件

- `libavcodec/h264_enc_dct.mbt` — fdct8/MF8/量化（`h264_enc_mf8` 注释含定标推导）
- `libavcodec/h264_enc_cabac.mbt` — `encode_luma_i8`、SPS High/PPS 尾、
  `h264_cabacw_residual` 8x8 扩展、I/P 写端接线
- `libavcodec/h264_encode_p.mbt` — `h264_p_dct8x8_allowed`、inter 8x8 残差
- `libavcodec/h264_cabac_mb.mbt` / `h264_decode.mbt` — transform_8x8 入口清零修复
- `libavcodec/h264_cavlc8.mbt` — CAVLC 8x8 读端（下片写端的镜像源）
- `libavcodec/h264_encode_dct8_test.mbt` / `h264_dct8_wbtest.mbt` — 黑盒/探针
- `libavcodec/x264/x264_wbtest.mbt` — C oracle 8x8 用例
- `D:\project\FFmpeg-n9.0.2\libavcodec\h264_cabac.c` — C 真源（L2348 flag 读）
- `PORTING_HISTORY.md` §385 / `README.md` H.264 行
