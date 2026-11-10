# AGENT_HANDOFF_2026-11-10 — H.264 CABAC P 切片 Intra16x16（§384）全绿

## 本片结论

§383 交接列出的第一项「CABAC P slice intra（ctx_base 17）」完成。
**解码端本来就已支持**（`h264_cabac_p_mb_type` 的 `Err(intra)` 分支），
本片只补写端 bins + 镜像状态，并把 CABAC 序列入口做成 opt-in。
一次对拍即全绿，没有出现 §382 那种 bin 级失步。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` / native x264 包 | 干净 |
| `h264_encode_p_intra_test.mbt`（3 CAVLC + 3 CABAC） | **6/6** |
| 旧 CAVLC `h264_encode_p_test.mbt` / CABAC `h264_enc_cabac_test.mbt` | **8/8** / **10/10** |
| 全量 `moon test --target wasm-gc` | **1729/1729** |
| x264 native oracle（docker `nine-x264`） | **12/12** |
| docker ffmpeg 9.0.2 | 零告警，framemd5 三帧与自家解码器逐帧一致 |

## 两套 mb_type bin 表（本片最容易抄错的地方）

| | I slice（§382） | P slice intra（本片） |
| --- | --- | --- |
| 入口 | `decode_cabac_intra_mb_type(..., 3, 1)` | ctx14=1 后 `decode_cabac_intra_mb_type(..., 17, 0)` |
| 首 bin | `3 + c`（c = 左/上 I16/PCM 邻居数） | 固定 `17`，**不带 c** |
| state 跃迁 | `state += 2` | **无** |
| terminate | `terminate(0)` 拒 I_PCM | 同 |
| b0 | 6 | 18 |
| b1 | 7 | 19 |
| b2（仅 b1=1） | 8 | **19**（与 b1 同 ctx） |
| b3 | 9 | 20 |
| b4 | 10 | **20**（与 b3 同 ctx） |

`v = group*4 + spec_mode = mb_type - 1` 的分解式两片相同：
`v = 12*b0 + 4*(b1+b2) + 2*b3 + b4`，即
`b0 = v>=12`、`rem = v/4 - 3*b0`、`b1 = rem>=1`、`b2 = rem==2`、
`b3 = (spec_mode>>1)&1`、`b4 = spec_mode&1`。
`group = luma_cbp != 0 ? 3 + chroma_c_cbp : chroma_c_cbp`，
`spec_mode` 由 pred8 编号 DC/H/V/Plane 映射到 spec V/H/DC/Plane（2/1/0/3）。

## 实现要点

- `write_cabac_mb_syntax` 的 `I16` 分支：ctx14=1 → @17=1 → `terminate(0)`
  → 上表五 bins → chroma pred mode 树（ctx 64+cc / 67，与 I slice 同）
  → `info.cbp_all`（**I16 无 cbp bins**）→ 无条件 dqp bin（ctx60=0）
  → DC cat0(blk 48, n16, chroma_dc=true) + `luma_cbp` 门控的 16 个 AC
  cat1(blk i, scan 1..15) + 色度 DC cat3 / AC cat4 → 最后 `return`
  （绕开 inter 的公共尾部）。
- 镜像状态必须同步：`ctx.cur_mb_is_intra = true`（cbf 上下文）、
  `info.mb_type_bits = h264_mb_type_intra16x16`（下一 MB 的 skip ctx）、
  `info.intra4x4 = false` / `chroma_mode` / `cbp_all` / `qp`。
- `h264_encode_frames_cabac` 增 `intra_in_p~`（默认 false）与 `recon~`；
  `encode_p_frame_cabac` 把它传给 `decide_plan`。`h264_enc_pack_recon`
  提为包级函数，CAVLC / CABAC 两个入口共用。
- 复用 §383 的 `code_mb_residuals`（`luma_dc_store`、intra 反量化矩阵
  0/1/2、I16 的 `cur_nz` 从 0 起）。CABAC 解码器每 MB 清零 `nz`，
  与 §383 的修复天然一致，所以没有再出现 CAVLC 那种 nC 失步。

## 为什么一次就绿（下片可复用的判断）

1. 先查**解码端**是否已支持，避免重复实现：`h264_inter.mbt:749`
   的 `h264_decode_mb_cabac_p` 已有 `Err(intra) → h264_decode_mb_cabac_intra`。
2. 写端残差链与 §382 的 I-slice I16 **完全同构**，只换 mb_type bins；
   没有重写任何残差/重建逻辑。
3. 判读仍按 §382 准则：`recon ≠ enc.recon` 才是病，用 **unfiltered**
   解码对拍；零告警 + 515 B + mean_abs 0 + 逐帧 recon MD5 一致一次收口。

## 复现命令

```sh
moon test --target wasm --no-render libavcodec/h264_encode_p_intra_test.mbt
moon test --target wasm-gc < /dev/null

# CABAC P-intra 流外部仲裁：测试打印的 CABARB 行
python -c "import re,pathlib; s=pathlib.Path('.scratch/i16test2.log').read_text(); m=re.search(r'CABARB:([0-9,]+)',s); pathlib.Path('.scratch/cab_i16.264').write_bytes(bytes(int(x) for x in m.group(1).strip(',').split(',')))"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -y -v warning -i /work/.scratch/cab_i16.264 \
   -f framemd5 -c:v rawvideo /work/.scratch/cab_i16.md5"

# x264 C oracle（12/12）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native \
   -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"
```

钉值 `50e3b8d58ddfb7d2d3fc3c3f54a8f2a1 /
80fe0f660ef17d69b35e6a335553d209 /
80fe0f660ef17d69b35e6a335553d209`（已进黑盒 `inspect`）。

## 剩余

1. transform_8x8 的 I16/I8x8 组合（解码端 `pps.transform_8x8_mode` 分支
   已有，写端未接）。
2. 码率控制 / 广义 RD（QP 恒定，`h264_rd_lambda` 已有）。
3. 把 I16 转成默认策略：CAVLC 与 CABAC 两条链目前都 opt-in，转正要重钉
   全部仲裁钉值与 PSNR/字节门。
4. CABAC I 帧的 I16 决策与 P 帧共用同一套 `decide_plan`，但 P 帧的
   CABAC 位定价仍用 CAVLC 位数（§381 的既有取舍），可换成 CABAC 位定价。

## 权威文件

- `libavcodec/h264_enc_cabac.mbt` — `write_cabac_mb_syntax` 的 I16 分支、
  `encode_p_frame_cabac` / `h264_encode_frames_cabac` 开关
- `libavcodec/h264_inter.mbt` — `h264_cabac_p_mb_type` / `h264_decode_mb_cabac_p`
- `libavcodec/h264_cabac_mb.mbt` — `h264_cabac_intra_mb_type` /
  `h264_decode_mb_cabac_intra`
- `libavcodec/h264_encode_p.mbt` — 共享 `code_mb_residuals` / `H264EncStats` /
  `h264_enc_pack_recon`
- `libavcodec/h264_encode_p_intra_test.mbt` — 6 项黑盒
- `libavcodec/x264/x264_wbtest.mbt` — 12 项 native C oracle
- `PORTING_HISTORY.md` §384 / `README.md` H.264 行
