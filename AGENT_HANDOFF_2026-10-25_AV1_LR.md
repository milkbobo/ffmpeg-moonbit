# AI 交接文档（2026-10-25）：AV1 环路恢复 + 多 tile 有损 LF 均已完成

> 交接对象：下一个接手本仓库的 AI/协作者。
> 仓库：`D:\project\FFmpeg-n9.0.2\moonbit`（Windows 10 + Git Bash）
> 远端：`github.com:milkbobo/ffmpeg-moonbit.git`，分支 `master`
> **AV1 segmentation 实现提交：`e0ff9e0 feat: 完成 AV1 关键帧 segmentation 与 SWITCHABLE LR 验证`**（本文件其余内容为 LR 阶段记录）
> `moon check --target wasm --deny-warn` 0 error / 0 warning；
> `moon test --target wasm --no-render` **873/873 通过**。
>
> 先读：[README.md](README.md)、[agent.md](agent.md)、[PORTING_HISTORY.md](PORTING_HISTORY.md)
> （§52–§58 是本轮）、[AGENT_HANDOFF_2026-10-24.md](AGENT_HANDOFF_2026-10-24.md)（总体）、
> [AV1_AGENT_HANDOFF.md](AV1_AGENT_HANDOFF.md)（AV1 专题）、
> [H264_AGENT_HANDOFF.md](H264_AGENT_HANDOFF.md)。本文只讲**这次会话做了什么、正在做什么、下一步怎么做**。

---

## 1. 本次会话已完成（全部已提交并 push）

| commit | 内容 |
|---|---|
| `33257e8` | **有损 4:4:4/4:2:2/10-bit 修复**：`decode_b` 的色度变换尺寸此前固定取 `dav1d_max_txfm_size_for_bs` 的 4:2:0 列，4:4:4 有损时色度 tx 取小 → `decode_coefs` 熵解码分叉 → 整帧（含 luma）都错。改为按像素布局选列（`libavcodec/av1_decode4.mbt` 的 `layout`）。新增 `libavcodec/av1_lossy_extra/`（444/422/10-bit，各 4 帧 framemd5）。无损路径因强制 4x4 tx 掩盖了该 bug。 |
| `bf70c1d` | **环路恢复（LR）**：移植 dav1d 1.5.1 `looprestoration_tmpl.c`（Wiener h/v/hv、SGR 3x3/5x5/mix）与 `lr_apply_tmpl.c`+`lf_apply_tmpl.c:backup_lpf`（逐 SB 行 stripe 驱动、8 行滞后、`backup4xU` 左边界、12 行 `lr_lpf_line` 备份）。新增 `libavcodec/av1_lr_filter.mbt`、`libavcodec/av1_lr_apply.mbt`、核级回归包 `libavcodec/lr_kernel/`（1980 例 C 参考哈希）、整帧回归包 `libavcodec/av1_lossy_lr/`（wt1 Wiener、t5 SGR、lr10/lr10nc/lr12）。同时修掉 **10/12-bit 逆变换中间裁剪**：`av1_inv_txfm_add` 的行/列裁剪此前固定 int16（dav1d 8-bit 分支），高位深应为 `-(bd_max+1)<<7` / `<<5`；固定 int16 会截断大系数（lr10 第 2 帧起 ±1..47 偏差）。入口不再拒绝非零 `lr_type`（多 tile 仍拒绝，见 §2）。 |
| `0c3230e` | **高位深 444/422 有损向量**：10-bit 4:4:4、10-bit 4:2:2、12-bit 4:4:4（libaom，128x96×4，crf30，LF+CDEF 开）加入 `av1_lossy_extra`，framemd5 与 libdav1d 一致。 |

AV1 关键帧（帧内）像素链路现在覆盖：**8/10/12-bit × 4:2:0/4:2:2/4:4:4/单色 × 无损/有损 × 逐 SB delta-q × 多 tile（无损）× 环内滤波 LF+CDEF+LR（单 tile）**。

---

## 2. 任务：AV1 多 tile 有损环内滤波——**已完成（commit `707bb45`，PORTING_HISTORY §59）**；以下为当时的进行时记录

### 2.1 现象与已确认的事实

- 测试向量 `mt8.ivf`：320x240、yuv420p、libaom crf30、`-g 1`、`-aom-params tile-columns=1:tile-rows=1`（2x2 tile）、**LR 关闭、CDEF 开启、LF 开启**。
- 期望 framemd5（docker `linuxserver/ffmpeg:9.0.2`，libdav1d）：
  ```
  41edbb8a279036935860d57bea894ef9
  65be00a3a5ff7508d359940cbfdcbef7
  52ddd050bda4eebcff260d990eb9dfd5
  0a3a77a689bed0ada0cd0300855e234e
  ```
- 生成命令（docker 入口点即 ffmpeg，**不要**在命令里再写 `ffmpeg`）：
  ```sh
  docker run --rm linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error \
    -f lavfi -i mandelbrot=size=320x240:rate=1 -frames:v 4 -pix_fmt yuv420p \
    -c:v libaom-av1 -crf 30 -cpu-used 8 -g 1 \
    -aom-params tile-columns=1:tile-rows=1 -f ivf - > .scratch/av1_hbd/mt8.ivf
  docker run --rm -i linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error \
    -i pipe:0 -f framemd5 - < .scratch/av1_hbd/mt8.ivf | grep -v '^#'
  ```
  （文件已在 `.scratch/av1_hbd/mt8.ivf`；`-f framemd5`/`rawvideo` 均走 `stdin/stdout` 管道，
  Git Bash 下 docker 卷挂载不可靠。）
- 多 tile 解码本身（熵解码 + 重建）是好的：无损多 tile 向量长期通过（`av1_tiles_vectors/`），
  `av1_decode_keyframe_tiles` 能跑完 2x2 tile。失败发生在**环内滤波阶段**，
  目前 `av1_decode6.mbt` 对 `num_tiles > 1` 且 LF/CDEF/LR 开启时显式
  `raise Unsupported("av1: multi-tile ... unsupported")`。

### 2.2 根因：缺 dav1d 的 tile 边界 LF 掩码修正

dav1d 在跑列滤波前会修正 tile 边界处的滤波强度掩码（`src/lf_apply_tmpl.c`
的 `dav1d_loopfilter_sbrow_cols`，约 313–410 行）：

1. **tile 列边界**：对每个 `tile_col >= 1`，取该列首个 SB 的 x（SB 单位），
   用 `f->lf.tx_lpf_right_edge[0/1][align_h*tile_col + by]` 里保存的
   「左邻 tile 右边缘 `tx_lpf_y/uv`」去钳制掩码 level：
   `idx = min(idx_from_mask_bits, lpf_y[y-starty4])`，再清 3 档 bit、置回
   `y_hmask[imin(idx, ...)] |= smask`。`lpf_y` 每过一个 tile 列 `+= halign`
   （`halign = (bh+31)&~31`），`lpf_uv` 同理但按 `>> ss_ver`。
2. **tile 行边界**：`start_of_tile_row[sby] != 0` 时，用**上一 tile 行的 above
   上下文** `f->a[f->sb128w*(start_of_tile_row-1)+x]` 的 `tx_lpf_y/uv` 钳制
   行方向掩码（`filter_y[1][starty4]`），逻辑同上（uv 的 idx 只有 0/1 两档）。
3. 这些 `tx_lpf_right_edge` 值在 `decode_tile_sbrow` 结束时保存
   （`src/decode.c` 约 2735–2742 行）：
   ```c
   memcpy(&f->lf.tx_lpf_right_edge[0][align_h*tile_col + t->by],
          &t->l.tx_lpf_y[t->by & 16], sb_step);
   memcpy(&f->lf.tx_lpf_right_edge[1][align_h*tile_col + (t->by >> ss_ver)],
          &t->l.tx_lpf_uv[(t->by & 16) >> ss_ver], sb_step >> ss_ver);
   ```
   `start_of_tile_row[]` 在 `dav1d_decode_frame_init`（约 2753–2770 行）填：
   每个 tile 行首个 sbrow 存 `tile_row`，其余存 0。

CDEF/LR 本身**没有** tile 专用修正（它们消费 LF 的输出），所以只要 LF 掩码修好，
mt8 很可能就通了；若仍有差异，再查 CDEF 的 `lr_lpf_line`/`cdef_line` 备份是否
按 SB 行、跨 tile 列覆盖完整。

### 2.3 已经写好但**未提交**的脚手架（patch 已保存）

`.scratch/dav1d_dbg/multi_tile_wip.patch`（155 行 diff）里已经做了：

- `Av1FrameCtx` 新增字段：`tile_cols`、`tile_col_start4 : Array[Int32]`
  （每 tile 列起点，4x4 单位）、`tile_lpf_y`、`tile_lpf_uv`
  （`align_h*tile_cols` / `(align_h>>ss_v)*tile_cols`）、
  `start_of_tile_row : FixedArray[Int32]`（`sb_rows`）。
- `av1_decode6.mbt` 构造 `f` 时分配上述数组；tile 循环里每解码完一个 sbrow
  就保存 `tx_lpf_y/uv` 右边缘值，并在 `by == row_start && tile_row > 0` 时
  写 `start_of_tile_row[by/sb_step] = tile_row`。
- 删掉了 LF/CDEF/LR 的 `num_tiles > 1` 拒绝（改回时记得：多 tile 未验证前
  不要提交这个删除）。
- `av1_lossy_extra/extra_test.mbt` 里加了 `av1_le_decode_tiles`（走
  `av1_decode_keyframe_tiles`）与 mt8 的 base64/期望 md5。
- `.scratch/dav1d_dbg/mt_dbg_test.mbt`：打印 tile 数 / lr_type / lf level /
  cdef 开关的小测试（mt8 实测：`tiles=2x2 lr=[] lf=[14,14,10,14] cdef=true`）。

应用方式：
```sh
cd D:/project/FFmpeg-n9.0.2/moonbit
git apply .scratch/dav1d_dbg/multi_tile_wip.patch
```

**该 patch 目前编译不过（4 个错）**，接手后先修：

1. `libavcodec/av1_decode6.mbt:368` / `:372`：写成了 `ts.l.tx_lpf_y`，
   本移植里左上下文在 **frame ctx** 上，应为 `f.l.tx_lpf_y` / `f.l.tx_lpf_uv`
   （`Av1TileCtx` 没有 `l` 字段；`Av1FrameCtx.l : Av1BlockContext`）。
2. `libavcodec/av1_decode.mbt:145/146`：`tile_cols`、`tile_col_start4`
   “never read” 警告（`--deny-warn` 会失败）——因为**消费端还没写**。
   写完 §2.4 的掩码修正后自然消除。

### 2.4 待写：`lf_sbrow_cols` 里的两段修正

在 `libavcodec/av1_lf.mbt` 的 `Av1FrameCtx::lf_sbrow_cols(sby)`（约 885 行）
**开头**（`for x in 0..<self.sb128w` 之前）插入，掩码索引用现成的
`av1_fy_i(dir, col, lvl, sidx)` / `av1_fuv_i(...)`（dir 0=列/h，1=行/v；
lvl 0..2；sidx 0/1 是 16 位半区，bit 号 = `y - sidx*16`）：

```text
// (a) tile 列边界
if self.tile_cols > 1 {
  let is_sb64 = if self.seq.use_128x128_superblock { 0 } else { 1 }
  let sbl2 = 5 - is_sb64                     // 4 或 5
  let halign = (self.bh + 31) & -32
  let starty4 = (sby & is_sb64) << 4
  let endy4 = starty4 + imin(self.bh - sby*(32>>is_sb64), 32>>is_sb64)
  let mask_row = sby >> is_sb64
  for tc in 1..<self.tile_cols {
    let x4 = self.tile_col_start4[tc]
    if x4 >= self.bw { break }               // dav1d: (x<<sbl2) >= bw
    let bx4 = if is_sb64 != 0 && (x4 & 16) != 0 { 16 } else { 0 }
    let x128 = x4 >> 5
    let mask = self.lf_mask[mask_row * self.sb128w + x128]
    let lpf_base = (tc - 1) * halign + (sby << sbl2)   // 左邻 tile 的右边缘
    for y in starty4..<endy4 {
      let bit = 1U << y
      let sidx = if bit >= 0x10000U { 1 } else { 0 }
      let smask = bit >> (sidx * 16)
      let idx = 2*(if (mask.fy[av1_fy_i(0,bx4,2,sidx)] & smask) != 0 {1} else {0})
              +   (if (mask.fy[av1_fy_i(0,bx4,1,sidx)] & smask) != 0 {1} else {0})
      // 清 0/1/2 三档，再置 min(idx, lpf_y[lpf_base + (y-starty4)])
    }
    // uv 同理：cbx4 = bx4 >> ss_h，列索引 (starty4..endy4) >> ss_v，
    // lpf_uv 基址 (tc-1)*(halign>>ss_v) + ((sby<<sbl2)>>ss_v)，idx 只有 0/1 两档
  }
}
// (b) tile 行边界
let r = self.start_of_tile_row[sby]
if r != 0 {
  for x in 0..<self.sb128w {
    let a = self.a[self.sb128w * (r - 1) + x]      // 上一 tile 行的 above 上下文
    let w = imin(32, self.bw - x*32)
    // 行方向掩码：av1_fy_i(1, starty4, lvl, sidx)，bit = 1<<i
    //   idx = 2*!!(lvl2) + !!(lvl1)，钳到 min(idx, a.tx_lpf_y[i])
    // uv：av1_fuv_i(1, starty4>>ss_v, lvl, sidx)，idx = !!(lvl1)，
    //   钳到 min(idx, a.tx_lpf_uv[i])，i < cw = (w+ss_h)>>ss_h
  }
}
```

注意：`f.a` 每个 tile 行一段（`a_idx = tile_row*sb128w + (col_start>>5)`，
`av1_decode6.mbt:320`），所以 `a[sb128w*(r-1)+x]` 正是上一 tile 行的
above 上下文，与 dav1d 一致。

### 2.5 验收步骤

```sh
git apply .scratch/dav1d_dbg/multi_tile_wip.patch
# 修 §2.3 的 2 个错误 + 写 §2.4
moon check --target wasm --deny-warn --no-render
moon test --target wasm --no-render -p libavcodec/av1_lossy_extra   # mt8 4 帧
moon test --target wasm --no-render                                # 期望 872/872
```
通过后：把 mt8 向量与测试正式并入 `av1_lossy_extra`（或新建
`av1_lossy_tiles/`），更新 README 能力行（去掉「有损多 tile」缺口）、
PORTING_HISTORY 新增一节、AV1_AGENT_HANDOFF §7 路线、
AGENT_HANDOFF 的测试数与 HEAD，然后中文 commit + `git push origin master`。
建议再补一条 **128x128 SB + 多 tile** 与一条 **4:4:4/10-bit 多 tile** 向量。

---

## 3. 对拍/调试工具链（都在 `.scratch/`，不入库）

dav1d 1.5.1 源码在 `C:\Users\milkb\AppData\Local\Temp\dav1d-src`（含 `.git`；
若被清理：`git clone --depth 1 --branch 1.5.1
https://code.videolan.org/videolan/dav1d.git`）。

| 脚本 | 作用 |
|---|---|
| `.scratch/dav1d_dbg/build_lr_ref.sh` | alpine gcc 编 `lr_ref.c`（直接 `#include "src/tables.c"` + `src/looprestoration_tmpl.c`），对 5 类核（wiener×2、sgr3/5/mix）× w∈{4,8,13,64,128,256} × h∈{1,2,3,7,56,64} × 11 种 edge = **1980 例**输出 `lr_ref.txt`（FNV-1a 哈希）；`LRDUMP=<caseid>` 额外 dump 该例逐像素。 |
| `.scratch/dav1d_dbg/lr_ref.c` | 上述 harness（LCG：`rs = rs*1103515245+12345`，取值 `(rs>>16)&255`；种子 `0x12345678 + caseid*2654435761`；填充顺序 plane 512*256 → left 256*4 → lpf 12*512 → 参数）。 |
| `.scratch/dav1d_dbg/patch_lr_tmpl.py` | 给 stage 里的 `looprestoration_tmpl.c` 打调试 printf（`T`/`AA`/`BB`）。**改 C 字符串里的 `\n` 一定用 Write 工具写文件**，heredoc 会把 `\\n` 变成真换行、破坏 printf。 |
| `.scratch/dav1d_dbg/gen_lr_kernel_test.py` | 由 `lr_ref.txt` 生成 `libavcodec/lr_kernel/lr_kernel_test.mbt`（参数 `4` = 全部 kind；MoonBit 侧必须复刻同一 LCG 与 case 顺序）。 |
| `.scratch/dav1d_dbg/build_trace.sh` | 8-bit dav1d + `DEBUG_BLOCK_INFO` 符号级 trace + YUV dump（模式 `""`/`nolf`/`lf`/`lc`）。**YUV 写入硬编码 4:2:0**（`sw=(w+1)>>1`），4:4:4/4:2:2 的 chroma 不可比。 |
| `.scratch/dav1d_dbg/build_trace_hbd.sh` | 同上但 `config_hbd.h`（`CONFIG_16BPC 1`），`*_tmpl.c` 同时编 8/16 两份，`trace_main.c` 按 `bpc>8` 写 2 字节/样本；可 dump 10/12-bit YUV 与块级 trace（`poc=,y=,x=,bl=,ctx=,bp=`，`bl` 是 BlockLevel：1=64x64、2=32x32、3=16x16、4=8x8）。 |
| `.scratch/av1_hbd/*.ivf` | 向量：`ll444/ll422/l10`（extra）、`lr10/lr10nc/lr12`（HBD）、`wt1`（Wiener 320x240）、`t5`（SGR 160x120）、`mt8`（2x2 tile 320x240）、`l444_10/l422_10/l444_12`。对应 `*_ref.md5` / `*.yuv` 参考也在同目录。 |

生成新向量的通用套路（libaom 全帧内 + 期望 md5）：
```sh
docker run --rm linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error \
  -f lavfi -i mandelbrot=size=128x96:rate=1 -frames:v 4 -pix_fmt yuv420p10le \
  -c:v libaom-av1 -crf 30 -cpu-used 8 -g 1 \
  -aom-params enable-restoration=1:enable-cdef=1 -f ivf - > out.ivf
docker run --rm -i linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error \
  -i pipe:0 -f framemd5 - < out.ivf | grep -v '^#' | awk -F, '{print $NF}'
```
注意：`-g 1` 必须加（否则 libaom 出帧间帧，本移植只解关键帧）；
ffmpeg 9.0.2 的 libdav1d wrapper **不支持** `-skip_loop_filter`
（`libavcodec/libdav1d.c` 里没有映射），要 nolf/lf-only 参考只能用
`.scratch/dav1d_dbg/build_trace*.sh`。libaom 在 mandelbrot 内容上
经常**不启用 restoration**（`lr_type=[]`），要 LR 向量优先用 `wt1.ivf`
（Wiener）/`t5.ivf`（SVT，SGR）或换内容试。

---

## 4. 本轮踩过的坑（dav1d 移植，值得记住）

1. **Wiener `hv` 必须用独立 tmp 行**：稳态下 `ptrs[6] == ptrs[0]`，
   dav1d 先算 `tmp` 再 `memcpy` 到 `ptrs[6]`；若先把水平结果写进
   `ptrs[6]` 再读 `ptrs[0..5]`，会覆盖仍要用的窗口行（表现为 h≤3 全对、
   h≥7 全错）。
2. **SGR 的 A/B 目标行要用旋转后的指针**（`A_ptrs[2]` / `A5_ptrs[1]` /
   `A3_ptrs[3]`），写死行号会让 5x5/mix 丢掉上一行数据（3x3 因为三行对称
   恰好看不出来）。`sgr_finish_mix` 的第二行 3x3 邻居要从 `&A3_ptrs[1]`
   起算（我们的实现给 `av1_sgr_finish_filter_row1` 加了 `p_base` 参数）。
3. **`sgr_calc_row_ab` 的 `z` 是 unsigned**：`p*s + (1<<19)` 会绕 32 位，
   MoonBit 的 `Int`(=Int32) 有符号右移会得到负下标并 trap；必须
   `reinterpret_as_uint()` 后再乘、移位。
4. **`lr_lpf_line` 12 行缓冲必须跨 SB 行持久**：每行开头 4 行是从上一 SB 行
   缓冲的 `top = 4<<sb128` 处拷来的；每个 SB 行新建缓冲会让 stripe 顶部边界
   全错（实测：wt1 首帧仅 stripe 边界 56/14 行出错）。
5. **高位深逆变换裁剪**：见 §1 `bf70c1d`。8-bit 与 HBD 的中间裁剪范围不同，
   且行/列两段用不同范围（`<<7` / `<<5`）。
6. **`dav1d_max_txfm_size_for_bs` 有四列**（y / 420 / 422 / 444），
   色度 tx 必须按 layout 取列。
7. **MoonBit 语言坑**（本项目反复踩）：`Int` 就是 `Int32`（没有
   `Int32::to_int`，直接当 Int 用；`UInt`↔`Int` 用 `reinterpret_as_*`）；
   `UInt64` 字面量后缀是 `UL` 不是 `ULL`；`~` 不存在（用 `-1 - x` 或
   `.lnot()`）；`for x in -1..<(w+1)` 这类负起点区间不稳，改 `while`；
   数组字面量里 `FixedArray[Int32]` 的 `]` 会让脚本化替换错位（写表时
   用 `= [` 之后再找 `]`）；wasm 数组越界直接 `unreachable` trap，
   没有行号——定位靠 `println` 打点或换 `--target native`（本机无 MSVC，
   native 不可用）。
8. **测试输出会被大 base64/CELT 打印淹没**：`moon test` 输出请重定向到文件
   再 `grep -a "Total tests"`（`-a` 必须，日志含二进制）。

---

## 5. 下一步优先级（AV1 之外见 `AGENT_HANDOFF_2026-10-24.md` §5）

1. **多 tile 有损 LF/CDEF/LR**（本文 §2，脚手架已备好）——目前唯一
   显式拒绝的有损关键帧场景。
2. **delta_lf**（`delta_lf_present`）：入口仍拒绝；需要 per-block ref/mode
   delta 与 `lf.level` 缓存（dav1d `decode_b` 里的 `lf_y/uv` 计算）。
3. **LR 覆盖扩展**：现有整帧 LR 向量都是 4:2:0；补 4:4:4/4:2:2 与高位深
   LR（需要能产出 restoration 的编码器/内容，SVT-AV1 的 SGR 比较稳）。
4. **inter 帧**：refmvs + MC 全家（参照 VP9 inter 的移植节奏），最大的一块。
5. intrabc、film grain、superres 仍显式报 PATCHWELCOME（入口有检查）。

---

## 6. 约定速查（务必遵守）

- **用户偏好：自主推进，每个增量中文 commit 并 `git push origin master`，
  不需要逐次询问**；提交信息风格看 `git log`。
- **不要跑 `moon fmt`**（会大面积改写、污染 diff）。`moon info` 可以。
- **不要提交** `*.generated.mbti`（已在 `.gitignore`）、`.scratch/`、
  `.trash/`、`_build/`。删文件用 `zcode-trash`，不要 `rm`（有 PreToolUse
  钩子拦截；本次会话中 `.scratch/` 内的临时文件可直接覆盖）。
- 每个增量的收尾清单：`moon check --target wasm --deny-warn --no-render` →
  `moon test --target wasm --no-render`（重定向到文件后 grep `Total tests`）→
  更新 README 能力表/测试数、PORTING_HISTORY 新章节、AV1_AGENT_HANDOFF §2/§7、
  AGENT_HANDOFF 的 HEAD 与测试数 → commit + push。
- 参照物优先级：**dav1d 1.5.1 C 源码** > FFmpeg 9.0.2（AV1 像素层 FFmpeg
  自己没有实现）；像素/PCM 期望值一律用 docker `linuxserver/ffmpeg:9.0.2`
  （libdav1d）的 framemd5。
- 大 base64 向量放**独立测试包**（wasm 模块 init 的局部变量数有上限），
  例如 `av1_lossy_vectors/`、`av1_lossy_extra/`、`av1_lossy_lr/`、
  `lr_kernel/`、`lf_kernel/`、`itx_probe/`。
- 私有核函数要给外部测试包用时，按既有做法加一个 `pub fn ..._kernel` /
  `..._probe` 包装（见 `av1_lf_filter_kernel`、`av1_lr_filter_probe`）。
