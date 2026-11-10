# H.264 纯 MoonBit 编码器交接（§376–§380 已交付；RD 选模已激活）

更新：2026-11-10（§380）。本文取代 2026-11-09 版——上一版描述的
「RD 激活失败态 + 排查插桩」工作树已收口，三个真 bug 全部修复。

## 状态

用户指令：**不能用 C FFI，把编码功能整体移植成纯 MoonBit**。§375 的
libx264 绑定（`libavcodec/x264/`）降级为对拍 oracle，不再是编码本体。

| 切片 | 内容 |
| --- | --- |
| §376 | I 帧：IDR、单 slice、CAVLC、Baseline 4:2:0 8-bit、平 QP，I_PCM/I16/I4x4 |
| §377 | P 帧：P_Skip + P_L0_16x16、单参考、±16 整素 SAD + MC 四分素精化、inter 残差（矩阵 3/4/5）、mb_skip_run |
| §378 | P 分割：P_L0_16x8/8x16/P_8x8（sub_mb_type 0..3）、mvd 预测读渐进状态镜像 |
| §379 | 两相重构（`code_mb_residuals`/`write_mb_syntax`）+ RD 基础设施。**其 nz 结论已被 §380 推翻，见下** |
| §380 | **RD 选模激活**（`SSD + λ·真实 CAVLC 位数`），三个真 bug 收口 |

全量 wasm **1729/1729**、`moon check --target wasm --deny-warn` 干净。

## §380 的三个真 bug（续做前必读）

只有第一个与「激活即失步」有关；后两个是排查过程中顺带挖出来的。

### ① 失步真因 = `mb_skip_run` 写出时序

`encode_p_frame` 原先在 `decide_plan` **之前**就 `r.put_ue(skip_run)`。
RD 允许「预测 SAD 非零的宏块」判成 Skip，这个 Skip 无法再追加到已写出的
run——解码器把被跳过的宏块当编码宏块读，**P 帧第一个 MB 即崩**。
SAD 链的 `decide_plan` 永不返回 Skip（零 SAD 已被上游早退吃掉），所以
这条路径从未执行过。修法：run 的 flush 挪到「已知是编码宏块」之后。

### ② §379 的 nz 持久化结论方向反了

C 的 `h->non_zero_count` 确实只分配一次（`h264dec.c:196`）、跨帧持久，
**但每种宏块都完整覆写 nC 会读到的槽位**，持久值永不透过 nC 可观测：

| 宏块 | C 位置 | 行为 |
| --- | --- | --- |
| skip | `h264_mvpred.h:939` | `memset(nnz[mb_xy], 0, 48)` |
| I_PCM | `h264_cavlc.c:757` | `memset(nnz[mb_xy], 16, 48)` |
| cbp==0 | `h264_cavlc.c:1142-1144` | luma+两色度 `fill_rectangle(...,0,1)` |
| cbp!=0，某 8x8 组位清零 | `h264_cavlc.c:657-658` | `nnz[0]=nnz[1]=nnz[8]=nnz[9]=0` |
| 色度 AC 未编码（`!(cbp&0x20)`） | `h264_cavlc.c:1136-1139` | `fill_rectangle(...,0,1)` |

两处修复：`commit_skip` 改回**清零全 48 槽**；`code_mb_residuals` 在
`chroma_c_cbp != 2` 时清零 8 个色度 AC 槽——量化器算出非零电平但语法
选择不编码时，**nC 镜像跟随语法而不是量化器输出**。
`cur_nz` 从 `states[mb].nz` 播种保留（镜像 `fill_decode_caches` 的 cache
生命周期），但所有会被读到的槽随后都覆写，播种值不参与任何预测。

> 移植解码器每帧新建 `infos`（nz 全零）因此是**对的**，不要改成跨帧持久。

### ③ RD 代价 Int32 溢出（质量 bug，流仍合法）

一个宏块 SSD 可达 ~1.7e7，`ssd * 1024` 的 2^10 定标越过 2^31；MoonBit
`Int` 是 32 位，回绕成负数后**每个高失真 Skip 都变成最便宜的候选**。
症状极具欺骗性：码流语法完全合法（ffmpeg 零告警接受），但 SAD 20851
的宏块被判 Skip，序列塌到 21.49 dB。修法：代价算术全程 `Int64`。
**只有质量门抓得到它**，语法仲裁全绿。

## RD 实现要点

- `eval_plan`：干跑 `code_mb_residuals` + `write_mb_syntax`（真写入器、
  一次性 bit buffer）得 (SSD, bits)。**干跑前重置 `cur_mv/cur_ref`**，
  让每个候选都从与最终写入相同的宏块入口状态定价（否则后续候选的 mvd
  预测经 `mv_fetch` 同 MB 路径读到上一个候选的 MV）。`cur_nz` 无需快照
  （每次重新播种），`rec_y` 由胜出者自己的 `code_mb_residuals` 覆写。
- λ = `0.85·2^((qp-12)/3)`（SSD 域；SAD 域运动 λ 指数减半、系数不变），
  用反复倍乘 + 2 的立方根构造，不依赖 libm `pow`。定标 2^10，代价 Int64。
- Skip 候选的失真 = `me_fixed_ssd`（pskip 预测 MV 处 MC 对源的 SSD），
  码率定价 0（`mb_skip_run` 是共享语法，摊薄）。
- 候选须**严格更便宜**才替换，故并列时取先出现的（更粗、更省位）。

## 验证矩阵

| 验证 | 口径 |
| --- | --- |
| CAVLC 残差性质 | 3000 随机模式写→读逐值相等 + 钉向量 |
| 重建不变量 | 编码器本地重建 == 自家解码器（跳滤波），96×64 全平面逐字节 |
| **外部仲裁** | docker ffmpeg（`nine-x264`）**零告警**；四帧 `e454d8…/a6814a…/74ecad…/791ea2…`、六帧补 `aa4569…/884043…`，framemd5 与自家解码器逐帧逐字节一致（MD5 钉死） |
| **RD 质量门** | 96×64×6/QP24：PSNR ≥ 26.5 dB、字节 ≤ 3200（实测 27.38 dB / 2940 B）。专门守 ③ 的溢出回归 |
| PCM 无损 / 静态纯 skip / 确定性 / QP 阶梯 / 裁剪 | 全绿 |
| 全量 | wasm **1729/1729**、`--deny-warn` 干净 |

收益实测（去滤波重建对源，只统计 5 个 P 帧）：

| 链 | 字节 | PSNR | SSD | 代价 |
| --- | --- | --- | --- | --- |
| SAD（§378） | 4272 | 27.02 dB | 3970767 | 4.542e9 |
| RD（§380） | **2940** | **27.38 dB** | **3654308** | **4.070e9** |

## 文件

| 文件 | 内容 |
| --- | --- |
| `h264_enc_bitstream.mbt` | RBSP 位写入器（ue/se/trailing/防竞争；`finish_raw_of`） |
| `h264_enc_ps.mbt` | SPS/PPS 序列化（raw RBSP 回读；裁剪序 L/R/T/B） |
| `h264_enc_dct.mbt` | 无移位 fdct + Hadamard + 量化（3 类 MF = 2^17/init、AC 21+qp/6）+ `h264_enc_dequant_level` |
| `h264_enc_cavlc.mbt` | `h264_enc_write_residual` + pub 自检 `h264_enc_residual_roundtrip` |
| `h264_encode.mbt` | I 帧主体（I_PCM/I16/I4x4、SAD 选模、本地重建镜像、`mb_nz` 导出） |
| `h264_encode_p.mbt` | P 帧/分割 + **RD**（`eval_plan`/`h264_rd_lambda`/`me_fixed_ssd`/`decide_plan`、GOP、pskip/pred_motion 镜像、ME、skip_run、两相写入、nz 回写） |
| `h264_encode_test.mbt` / `h264_encode_p_test.mbt` | 黑盒 8 + 8 测（含四帧/六帧仲裁钉值与 RD 质量门） |
| `h264_shadow_wbtest.mbt` | 调试工具：逐 MB 语法影子解析（native 门控） |
| `libavcodec/x264/` | libx264 native 绑定，**仅作 oracle**（镜像内运行） |

## 关键语义（续做前必读）

1. **量化刻度**：MF = 3 类 `2^17/dequant4_init`（13107 族）；AC shift
   21+qp/6、luma DC 17+qp/6、chroma DC 21+qp/6；mb 填充 =
   `(level*qmul+32)>>6`。重建不变量测不出刻度错误（自洽），必须看质量度量。
2. **CAVLC levels** 先抽非零序列再反向；escape prefix=15 是 12 位窗口
   [30,4125)；trailing ones 按非零序列数；scan 用转置系 `h264_zigzag_scan_t`。
3. **I16 语法**：mb_type 模式序 V/H/DC/P；cbp 分组 [0,16,32,15,31,47]。
4. **P 帧**：pskip/pred_motion 镜像含 match-count 中值与 pskip 早退；
   mb_skip_run 片尾残留**必须写出**，且**只能在已知是编码宏块后才 flush**；
   inter cbp 48 表反查；单参考 ref_idx 不编码。
5. **ME 零 MV 偏置**：平移不变内容大量 MV 并列，先测 (0,0)、严格更优才替换。
6. **分区 mvd 预测时序**：解码器边解析边 `write_back_part`，编码器镜像时
   `mv_fetch` 对当前 MB 的块必须读渐进 `cur_mv/cur_ref`。
7. **SAD 尺寸语义**：模式决策按「同 MB 总 SAD」比较；MC SAD 按分区尺寸
   取样（mcbuf 恒 16 行步长）。
8. **状态数组别名**：`Array::make(n, new_state())` 共享实例——逐个 push。
9. **色度 cbp 取舍**：当前实现「色度 DC 量化为零就整块色度不编码」
   （`chroma_c_cbp=0`），即使 AC 有非零电平也丢弃。这是自洽的有损选择，
   不是 bug；改它要连带改 nz 镜像与重建。

## 工具链坑（本片新增）

- **`Int` 是 32 位**：任何 `SSD * 定标` 的代价算术必须 `Int64`
  （`to_int64()` + `L` 字面量）。溢出成负数不会报错，只会让决策反转，
  且**码流仍然合法**——语法仲裁测不出来，必须有质量门。
- **`trace_headers` 只 dump slice 头，不含宏块层语法**。定位 MB 级失步
  要靠 oracle 的错误位置（`corrupted macroblock X Y (total_coeff=-1)`
  直接给出首个坏 MB），不是 trace_headers。
- **临时对照实验别写「恒假守卫」**（`&& cost < -1`）来禁用分支：会静默
  把对照链降级成「只选 16x16」，测出来的基线是假的。切换后必须逐分支
  核对真的生效（本片因此白测一轮）。
- **`python -c` 里的 `\n` 会被本工具链吞掉**（已知坑再次踩中）：改文件
  一律用 Write/Edit 工具，或写完整脚本文件再执行。
- 黑盒测试里 `b''` 字面量触发 moonc ICE——用重载字面量 `let mid : Byte = 128`。
- 白盒 wasm 可执行体 V8 init 局部数上限贴边——测试放黑盒、私有自检做 pub
  函数、顶层表改 match 常量、调试文件 native 门控。

## 后续切片

1. **CABAC 编码**（`h264_cabac.mbt` 的编码器方向）+ High profile 8x8dct。
   解码侧 CABAC 已逐比特验证（`tests/cabac.c`），编码器需逐 bin 镜像
   上下文；注意 `cbp_all` 在残差解码后不能再重置那条坑（agent.md §7）。
2. **码率控制**：QP 决策、CBP 折衷、B 帧。RD 基础设施（`eval_plan` 的
   SSD/bits 二元组）已就绪，可直接喂 QP 搜索。
3. **RD 精化**（可选）：Skip 的码率目前定价 0；分区 MV 仍由 SAD 选出
   后才进 RD 竞价（未做 RD 域 ME）；色度 SSD 未计入代价。
4. **编码器接进 `cmd/` CLI 或统一播放门面**（当前是库 API + 测试）。

## 运行

```sh
moon test --target wasm libavcodec/h264_encode_test.mbt     # 8 测
moon test --target wasm libavcodec/h264_encode_p_test.mbt   # 8 测
moon test --target wasm --no-render                          # 1729/1729
moon check --target wasm --deny-warn --no-render             # 干净
```

外部仲裁（重钉 MD5 时）：测试打印 `ARB3:`/`ARB4:` 十进制流 →
`.scratch/rd_dump_to_bin.py` 转 Annex B → 镜像内
`ffmpeg -y -v warning -i x.264 -f framemd5 -c:v rawvideo x.md5`。

```sh
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit/.scratch:/s" -w /s \
  ffmpeg-moonbit-ffref:nine-x264 -c "ffmpeg -hide_banner -y -v warning \
  -i rd_stream.264 -f framemd5 -c:v rawvideo rd_stream.md5"
```
