# AGENT_HANDOFF_2026-11-10 — H.264 CAVLC 8x8DCT 写端（§386）全绿

## 本片结论

§385 交接剩余第一项完成：**CAVLC 熵编码下的 transform_8x8 写端**
（`h264_encode_intra_frame` / `h264_encode_frames` 增 opt-in `dct8x8=`，
默认关闭保 Baseline 链逐字节不变）。I 帧 I8x8 与 P 帧 inter 8x8 全链，
与 §385 的 CABAC 链共享同一 I8x8 pass、决策与残差生成——**只有熵编码
层不同**（CAVLC 2749 B vs CABAC 2086 B，同决策同重建）。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 干净 |
| 黑盒 `h264_encode_dct8_cavlc_test.mbt`（I/P + ffmpeg 钉值 + QP 阶梯） | **3/3** |
| 存量编码器套件（含 CABAC dct8 重钉） | **34/34** |
| 全仓 `moon test --target wasm-gc` | **1736/1736** |
| 非 gc wasm（cmd/avutil/avformat/swr/swscale/wasm_probe） | **853/853** |
| x264 native C oracle（docker，含新增 CAVLC 8x8 用例） | **14/14** |
| docker ffmpeg 9.0.2（CAVLC 8x8 流） | 零告警，三帧与本仓滤波输出逐字节一致 |

## CAVLC 8x8 的正确心智模型（与 CABAC 完全不同的扫描语义）

- **四条交织子列表**：`zigzag_scan8x8_cavlc` 是一条全局 64 位 zigzag，
  子列表 `sub` 的第 k 个系数 = 全局第 `4*k + sub` 位（CABAC 是四条
  各自独立的 16 位块扫描）。写端 `h264_cavlc8_sub_view` =
  `store8[64*q + h264_zigzag_scan8x8[4*k + sub]]`。
- 每条子列表就是一条普通 16 系数 CAVLC 列表：复用已验证的
  `h264_enc_write_residual`（coeff_token/level/total_zeros/run 原样），
  nC 用该子列表自己 4x4 格位（z 序块 `4*q + sub` 的 (gx,gy)）的标准
  左/上推导。
- **leader 累加**：象限四条写完后 `nz[leader] += nz[leader+1] +
  nz[leader+4] + nz[leader+5]`（leader = `h264_luma_block_grid[4*q]`，
  即格位 0/2/8/10）。此后无人再读 leader 作 nC（象限外邻居格位只读
  各自子列表计数；下一 MB 的 block0 nC 读左 MB 格 3 / 上 MB 格 12，
  都不是 leader）——但 deblock 与下一帧种子会读，必须镜像。
- **nC 必须在语法层渐进回填**：子列表 1 的左邻是同象限子列表 0 的
  cell，此时它还是自己的子列表计数（未累加）——预填终值会读错。
  `code_mb_residuals` 的 dct8 分支因此只**清零** 16 个 luma 格
  （未编码象限解码端读新鲜零计数），写入全部由 `write_mb_syntax`
  边写边填。
- 解码端重建的 nz 捷径用 leader 值（`h264_idct8_add4` 读
  `nz[i8x8/2*8 + i8x8%2*2]`）= 象限总计数 → 编码端 `total==1 && DC`
  的 DC-add 捷径判定与之一致。

## 语法位（CAVLC 侧）

| 位 | 位置 | 值 |
| --- | --- | --- |
| I 帧 flag | mb_type ue(0) 之后、pred 模式之前 | PPS 开启即每个 I_NxN 都写（选 4x4 写 0） |
| I8x8 模式 | z 序 0/4/8/12 槽各一条（prev_flag + rem3） | cur_modes 2x2 复制，`pred_mode` 镜像零改动 |
| P 帧 flag | cbp golomb 之后、mb_qp 增量位之前 | 仅 `dct8x8_allowed && cbp&15≠0` 时写 |
| 残差 | cbp 位门控的象限 × 4 子列表 | nC 渐进 + leader 累加 |

## 计价升级与 CABAC 重钉（本片唯一的既有钉值变化）

`decide_plan` 干跑位计走 `write_mb_syntax`（§381 的 CAVLC-位数定价
取舍）：§385 时 dct8 候选按全零 4x4 列表计位（`luma_store` 空），本片
起按真实 8x8 子列表语法计位 → 计划选择变化 → **CABAC dct8 P 帧流变化**
（像素不变，两链共享决策与残差链）。三帧钉值重钉
`5e000f9f…/5956be95…/50c176cb…`，docker ffmpeg 仲裁一致。CAVLC 黑盒
的 P 帧像素钉值与 CABAC 版相同——这正是共享决策的证明（断言
`plain == stream` 与 ffmpeg 仲裁覆盖 CAVLC 语法本身）。

## 验证方法论（nC 镜像的守门测试）

nC 任何滑步 → VLC 表选择失步 → 解码失败或重建成垃圾。守门 =
**QP 阶梯 × 双几何 × busy 夹具的全链重建不变式**（QP 14/22/30/38 ×
96×64 与 80×48（裁剪路径+边缘 MB）× 梯度+棋盘+游走框），I 图三平面与
每个 P 帧的 enc.recon == 解码器 unfiltered 输出。

## 复现命令

```sh
moon test --target wasm --no-render libavcodec/h264_encode_dct8_cavlc_test.mbt

# 外部仲裁：测试打印的 DCT8CARB 行 → Annex B → docker ffmpeg framemd5
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -y -v warning -i /work/.scratch/dct8c.264 -f framemd5 -c:v rawvideo /work/.scratch/dct8c.md5"

# x264 C oracle（14/14）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native \
   -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"
```

## 剩余

1. 码率控制 / 广义 RD（QP 恒定，`h264_rd_lambda` 已有）。
2. I16 与 8x8 转默认策略（需重钉全部仲裁钉值与质量门）。
3. CABAC 位定价（干跑仍是 CAVLC 位数；8x8 候选计价已升级）。
4. 8x8 与 I4 的真 RD 竞争（现为 SAD 平价即胜 + allowed 即用）。
5. P slice 的 I8x8（I_NxN 在 P slice 的 mb_type 5 + flag + 模式树；
   解码端 `h264_decode.mbt:669` 的 P 分支只接 I16，需扩）。

## 权威文件

- `libavcodec/h264_enc_i8x8.mbt` — 共享 I8x8 pass + 几何 avail + 子列表 view
- `libavcodec/h264_encode.mbt` — CAVLC I 帧的 I8x8 决策/redo/语法/残差
- `libavcodec/h264_encode_p.mbt` — CAVLC P 的 nz 清零 + flag 位 + 子列表写
- `libavcodec/h264_enc_ps.mbt` — `h264_enc_sps_body_high` / `h264_enc_pps_body` 共享
- `libavcodec/h264_cavlc8.mbt` — 读端权威镜像
- `libavcodec/h264_encode_dct8_cavlc_test.mbt` — 黑盒 3 项
- `PORTING_HISTORY.md` §386 / `README.md` H.264 行
