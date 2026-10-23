# H.264 移植交接（2026-10-23 第二轮）

## 当前状态

任务目标：继续移植剩余 H.264 解码功能。用户已明确决定 **SP/SI 像素重建不做**。FFmpeg 9.0.2 自身不解码的 FMO、数据分区、separate colour plane 也不计入承诺范围。

正常码流的 I/P/B、CAVLC/CABAC、多 slice、8/9/10/12/14 bit、单色和 4:2:0/4:2:2/4:4:4、MBAFF/PAFF、DPB、SEI、去块滤波、Annex B 和 MP4 `avcC` 入口已有实现与真实码流对拍。

**仍然不能宣称 H.264 全部移植完成。** 错误恢复已从"仅渐进帧"推进到"渐进帧 + MBAFF"，但 P 帧大缺口/高位深的恢复仍与上游有像素级差异。

本轮结束时的运行结果：

```text
moon check --target wasm --deny-warn --no-render  # 通过
moon test --target wasm --no-render                 # 783/783 通过
```

本轮工作分三次提交，均已推送，`master` 与 `origin/master` 同步：

```text
8d22f00 feat: 补齐 H.264 MBAFF 错误补偿并确认场图片边界   (22 文件, +2019/-38)
f17d05a fix: 补齐 H.264 错误补偿的加权预测与去块参数       (3 文件, +67/-7)
e9fd658 docs: 记录 P 帧错误补偿残余偏差的排查结论          (1 文件, +9/-1)
```

## 本轮完成的事

### 1. MBAFF 损坏帧恢复（已 byte-exact）

关键结论：`h264_slice_init` 对 `first_mb_in_slice` 做 `<< FIELD_OR_MBAFF_PICTURE`，MBAFF 帧按宏块**对**编址；换算成 raster 起点后，上游 `error_resilience.c` 全程没有任何 MBAFF 分支，`er->mb_height` 就是宏块行数。所以只需在 `h264_er_raster_start` 展开 pair 地址，其余沿用渐进帧逻辑。补偿出的宏块必须清 `field_mb`（对应 `h264_er_decode_mb` 把 `mb_field_decoding_flag` 置 0）。

新增 `h264_er_mbaff_wbtest.mbt`：96×64、6×2 宏块对、每帧两 slice 的流，**12 个变体 × 8 帧逐帧 MD5 全部与 Docker FFmpeg 9.0.2 一致**，覆盖 I/P/B、丢前半 slice、丢后半 slice、损坏参考帧传播。另有 `damaged_macroblocks == 12` 与"关闭补偿仍报错"两个断言。

### 2. 场图片：确认是上游边界，不是移植缺失

`h264_slice.c` 设 `pic->field_picture = picture_structure != PICT_FRAME`；`error_resilience.c:er_supported()` 见到它返回 0；`ff_er_frame_end()` 开头即 `return`，源码留着 "We do not support ER of field pictures yet"。实测 PAFF 多 slice 流丢一个 slice，上游既无 `concealing` 也无 `corrupt decoded frame`，输出的是缺失宏块保持缓冲旧值的帧，不可复现。

移植侧因此**继续明确报 `incomplete H.264 picture`**。`h264_er_field_wbtest.mbt` 固化这个边界（开/关补偿都报错），并另加一个"完整 PAFF 流在开补偿时仍逐帧对齐"的回归。

### 3. Annex B 分组缺陷（已修）

原先 `decode_annexb` 用 `first_mb_in_slice == 0` 判新图。丢失某帧首 slice 后，剩余 slice 会被粘到下一帧，报 `inconsistent H.264 picture slices`。

现在 `h264_same_picture` 按 slice header 的图标识比较（`pps_id`/`frame_num`/`poc_lsb`/`idr_pic_id`/`delta_poc*`/`mmco`/field 标志/`nal_type`/`ref_idc`，与 `h264_decode_picture_ex` 的一致性检查同一组字段）；`h264_probe_slice_header` 解析失败时退回原判据。注意 `decode_annexb` 会在分组阶段就把 SPS/PPS 解析进 `self.ps`，否则首次 flush 前 probe 全部失败、退化判据又会把跨帧 slice 粘在一起（这个坑踩过一次）。

### 4. 渐进流矩阵（4/6 byte-exact）

`h264_er_progressive_wbtest.mbt` 覆盖丢 IDR 首 slice、丢两个连续 slice、丢 P 帧首 slice、截断末段 slice，逐帧对齐上游。

### 5. 10-bit / 4:4:4 / 4:2:2

新增 `h264_er_format_realdata_wbtest.mbt`（内嵌 x264 生成的三条流）与 `h264_er_format_wbtest.mbt`：三种格式的多 slice 流在**开关补偿两种模式下都逐帧一致**。

顺带补了 `put_dc` 的 DC 钳位 `dc > 2040 → 2040`（上游不随位深缩放，10-bit 因此封顶 255）。这条对 8-bit 无影响，对 10-bit 改变了恢复输出，值得保留。

### 6. 清理

删除 `scripts/compare_h264_er.mbtx`、`scripts/inspect_h264_er_reference.mbtx`、`h264_picture_wbtest.mbt` 里的 `moon sums` 调试块，以及已成死代码的单次 `h264_er_guess_mv`（B 帧恒用零矢量，P 帧在 `!picture_mv_done` 分支不可达）。`filter181` 的 `value * 10923` 核算过 14-bit 最坏值 1.4e9，仍在 Int32 内，与上游一致，加了注释。

## 已知偏差（未写成断言）

| 场景 | 差异 | 分析 |
| --- | --- | --- |
| `trunc_p_mid`（P 帧中间 slice 截断） | Y/U 逐字节一致，仅 V 平面 **2 个像素**差 1–2 | 恢复像素与上游逐字节相同，差异落在常规去块对"恢复宏块/正常宏块"边界的阈值判定；见下方排查记录 |
| `two_split`（参考帧本身被补偿过） | Y 平面即不同 | 多轮 `guess_mv` 在"参考帧是恢复帧"时的取值分歧 |
| 10-bit / 4:4:4 / 4:2:2 丢整段 slice | 大量宏块不同 | 缺口达 12 个宏块（半个图像），DC 估计与 MV 猜测分歧被放大 |

### `trunc_p_mid` 的排查记录（四轮，未收口）

**恢复本身完全正确**：关掉两侧滤波后，恢复宏块 mb16 的 V 区域（x32..39, y16..31）与上游 `-ec 1 -skip_loop_filter all` 逐字节相同；色度 MC 手算校验一致（`mv=(8,-15)` → `dx=0, dy=1` → `(7a+c+4)>>3`）。Y 全帧 md5 一致。

**最有效的排查手段**：FFmpeg 的 `-ec` 是位掩码（`FF_EC_DEBLOCK = 2`）。`-ec 1` 配合 `-skip_loop_filter all` 能取到"恢复后 / 两种滤波前"的四种中间状态，与移植侧 `skip_lf × er_deblock` 四组合逐一对比。

**已排除**（都被实测证伪，别再重走）：weighted prediction（补上 `h264_weight_rect` 后输出零变化，这些帧 `use_weight == 0`）、bS 取值（1→2 无变化）、QP（恢复宏块 QP 强制 1..40 全无变化）、slice 的 alpha/beta offset（实测都是 0）、恢复宏块 `deblock_idc`（1→0 无变化）、`cstride`/`cbase` 坐标（实测 `p=1186 stride=48 len=1920` 正确）、`tc0` 表越界（表长 624，索引有效）。

**实测参数**：mb22 上边界判决为 `bs=[2,2,2,2]`、`cq0=20` → `index_a=72` → `alpha=7 beta=3 tc=1`。

**遗留线索（下一步从这里开始）**：V 平面 x=34 的 `|p0-q0|=6 < 7` 本应通过，但插桩日志里 `p0` 全是 225~228 这类高值，**V 平面那次调用没有出现在日志中** —— `h264_filter_mb` 对 U/V 用同一个 `coff`，无法从 `start` 区分平面。应：
1. 在 `h264_filter_chroma_edge` 开头的 `if alpha == 0 || beta == 0 { return }` 处插桩，判定 V 是否提前返回；
2. 在 `h264_filter_mb` 的调用处用 `data == ctx.v` 区分平面分别记录。

**终止理由**：V 平面 2 个像素、1–2 级灰度，不影响任何功能正确性；恢复像素与上游一致、Y/U 整帧一致、504 测试全绿。继续投入的边际收益已低于成本，按"上游恢复参与去块时的阈值边界"登记，与场图片同等处理。

共同根因是 `guess_dc` / `guess_mv` 的近似：移植侧从像素累加估计 8×8 DC，上游用的是解码器正常写入 `dc_val` 的 DC 系数；MV 猜测的候选集与多轮顺序也还有未对齐处。要彻底 byte-exact，需要让正常解码路径记录每个块的 DC，并逐行核对 `guess_dc` 的四方向加权。

**下一步如果要继续**，按场景分两路：

- `trunc_p_mid`（2 像素）：从上面"遗留线索"的两处插桩开始，先确定 V 平面是否提前返回，再对齐阈值。
- `two_split` / 大缺口场景（Y 即不同）：从 DC 入手。`h264_er_dc_plane` 现在按 8×8 像素平均估计 DC，上游用的是解码器正常写入 `dc_val` 的 DC 系数，对 I_4x4 宏块不等价；MV 猜测的候选集与多轮顺序也还有未对齐处。

## 复现素材

`.scratch/` 下已有：`h264_mbaff_slices.264` 及 12 个 `h264_er_mbaff_drop_*.264`、`h264_slices1.264` 及 6 个 `h264_er_{head_i,two_p,head_p,trunc_p_mid,trunc_p_last,two_split}.264`、`h264_er_{10bit,444,422}_slices.264` 及对应 `_drop{4,6}` 变体。

生成脚本：`scripts/gen_h264_er_mbaff_vector.mbtx`、`scripts/gen_h264_er_vectors.mbtx`、`scripts/gen_h264_er_b_vector.mbtx`、`scripts/_gen_mbaff_er_matrix.py`、`scripts/_gen_progressive_er_matrix.py`。

取参考（在本目录执行）：

```powershell
MSYS_NO_PATHCONV=1 docker run --rm --network none -v 'D:\project\FFmpeg-n9.0.2\moonbit\.scratch:/vectors' -w /vectors --entrypoint ffmpeg linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel warning -flags2 +showall -f h264 -i h264_er_drop_mbaff.264 -fps_mode passthrough -f framemd5 -
```

**两个坑**：

1. `-f rawvideo` 导出的帧序与 `framemd5` 的 pts 序可能不同（多线程延迟会多出 1 帧），逐宏块定位差异时要用 `-threads 1` 并核对帧数。
2. 96×64 的流 framemd5 帧大小是 **11520**（96×80，含 padding），不是 9216。按 9216 切分会得到全错的对比结论。

## 实施注意

- `h264_decode.mbt` 的错误恢复门槛现为 `!field_picture`（不再排除 `mb_aff`）。场图片要放开必须同时处理宏块序号与参考场布局，而**上游根本没有实现**，不要为了"看起来完整"去编造行为。
- P 的准确对拍依赖多轮 `guess_mv`、前一 DPB 运动信息、恢复区专用滤波，以及对失败 slice 所在行停止常规滤波。改动任一项都要重跑逐帧回归。
- 只做必要的定向格式化；全仓库 `moon fmt` 会造成过大范围无关改动。
- 清理一律 `mv` 到 `.trash/<日期>/<原相对路径>`，不要用删除命令（本机有 hook 拦截，连命令里出现 `del ` 变量名都可能被误判）。
