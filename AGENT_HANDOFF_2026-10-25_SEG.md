# AI 交接文档（2026-10-25）：AV1 关键帧链路收敛 + segmentation 进行中

> **完成状态（2026-10-25）**：segmentation 关键帧路径与 SWITCHABLE LR
> 已实现；rav1e 4:4:4 10-bit 4 帧逐帧 MD5 匹配 libdav1d，
> `moon check --target wasm --deny-warn --no-render` 通过，
> `moon test --target wasm --no-render` **873/873**。详见
> [PORTING_HISTORY.md](PORTING_HISTORY.md) §62。下文 §2 保留原 WIP 交接记录。
> 其中“ALT_LF 为 7 数据位+1 符号位”的判断有误：dav1d
> `get_sbits(gb, 7)` 实际读取 7 位补码；最终代码已按源码修正。
> **后续进展**：AV1 帧间单参考 MC 基础核提交 `4598726`，见 PORTING_HISTORY §63；
> 最新 Wasm 全量测试 **874/874**。本文件其余内容保留 segmentation 阶段记录。

> 交接对象：下一个接手本仓库的 AI/协作者。
> 仓库：`D:\project\FFmpeg-n9.0.2\moonbit`（Windows 10 + Git Bash）
> 远端：`github.com:milkbobo/ffmpeg-moonbit.git`，分支 `master`
> **segmentation 实现提交：`e0ff9e0 feat: 完成 AV1 关键帧 segmentation 与 SWITCHABLE LR 验证`**
> 已提交基线：`moon check --target wasm --deny-warn --no-render` 0 error/0 warning，
> `moon test --target wasm --no-render` **873/873**。
> **工作区有未提交的 segmentation WIP（3 个文件，编译差 1 个错误）**，
> 备份 patch 在 `.scratch/dav1d_dbg/segmentation_wip.patch`（.scratch 不入库）。
>
> 先读：[README.md](README.md)、[agent.md](agent.md)、[PORTING_HISTORY.md](PORTING_HISTORY.md)
> （§52–§61 是近期）、[AV1_AGENT_HANDOFF.md](AV1_AGENT_HANDOFF.md)（AV1 总览）。
> 本文只讲**这个会话做了什么、正在做什么、怎么接着做**。

---

## 1. 本会话已完成（全部已提交并 push）

| commit | 内容 |
|---|---|
| `707bb45` | **多 tile 有损环内滤波**：dav1d `lf_apply_tmpl.c` 的 tile 列/行边界 LF 强度修正（`lf_sbrow_cols` 开头两段：左邻 tile 右边缘 `tile_lpf_y/uv` 钳制列掩码档位、上一 tile 行残留 above 上下文钳制行掩码）。移除 LF/CDEF/LR 的 `num_tiles>1` 拒绝。向量 mt8（64SB）/mt444（444 10-bit）/mtsb128（**128x128 SB**，debian aom-tools `aomenc --sb-size=128` 生成——libaom DYNAMIC 恒选 64SB，此前有损向量全是 64SB）。 |
| `2864f26` | **逐 SB delta-lf**：tile ctx 的 `last_delta_lf[4]`+`lf_lvl_cur[8*64]`（副本替代 dav1d `ts->lflvl` 指针切换，prev 快照精确复刻三种转移）；`av1_calc_lf_values` 补 `lf_delta[4]` 参数。向量 dlfm3/dlft3（`multi=false`；`multi=true` 无编码器可产，分支已实现）。 |
| `2706d4c` | **LR 格式扩展**：新包 `av1_lossy_lr_fmt/`，SVT 420 10-bit（SGR+Wiener 混合+deltaq，首个高位深 SGR 整帧向量）+ libaom 444 8/10-bit、422 8/10-bit（chroma Wiener），五条全过，代码零改动。 |

至此 AV1 关键帧（帧内）覆盖：**8/10/12-bit × 4:2:0/4:2:2/4:4:4/单色 × 无损/有损 ×
多 tile × 64/128 SB × LF+CDEF+LR（全格式）× delta-q/delta-lf**。
入口仅剩的拒绝：segmentation（WIP 中）、qmatrix、superres、非关键帧、intrabc、film grain。

---

## 2. 正在进行的任务：segmentation（未提交，接手从这里开始）

### 2.1 已写好（在工作区/patch 里）

- **帧头解析**（`libavcodec/av1.mbt`）：
  - `Av1FrameHeader` 新字段：`seg_delta_lf : Array[Int32]`（`[seg*4+dir]`，dir 0/1/2/3 = y_v/y_h/u/v）、`seg_preskip : Bool`、`seg_last_active : Int32`（-1=无）、`seg_qidx[8]`、`seg_lossless[8]`。
  - **修了两个既有解析 bug**：ALT_LF（feature 1..4）此前 `skip(7)` 漏了符号位，现在 7 数据位+1 符号位（dav1d `get_sbits(gb,7)`）；`coded_lossless` 此前漏查 `dq_v_dc/dq_v_ac`，且现在按 segment 推导（`obu.c` 848–859 的移植：`seg_qidx[i]=clip_u8(base+alt_q[i])`、`seg_lossless[i]=qidx==0&&delta_lossless`、enabled 时 `coded_lossless=所有 seg 都 lossless`）。
  - seg 头内变量已提升到外层作用域（`seg_lf/seg_preskip/seg_last_active/seg_qs/seg_ls`，在 `segmentation_alt_qs` 声明旁边），update_data=false 时 `seg_lf` 填 32 个 0。
- **frame ctx**（`libavcodec/av1_decode.mbt`）：
  - `Av1FrameCtx.cur_segmap : FixedArray[Byte]`（初值 8 = 未赋值，dav1d cur_segmap）。
  - `fill_dq` 改为 **per-seg**：enabled 时 8 段各自 `clip_u8(qidx+alt_q[i])` 建表（dav1d `init_quant_tables` 58–60 行）。
  - `init_quant` 的 `seg_lossless` 改读 `hdr.seg_lossless[i]`。
  - 新增辅助：`av1_neg_deinterleave`（decode.c 169–189 一比一）与
    `av1_get_cur_frame_segid`（dav1d `src/env.h` 一比一：left/above/
    above-left 三样本，ctx 2=全等/1=任两等/0=全异，pred=`a==al ? a : l`；
    只有一侧邻居时 ctx=0）。
- **入口**（`libavcodec/av1_decode6.mbt`）：segmentation 拒绝已删；
  `cur_segmap: FixedArray::make(b4_stride * bh, 8)` 已分配。

### 2.2 剩余编译错误（先修这个）

`libavcodec/av1.mbt:1018/1019`：lossless 推导块里引用了 `seg_alt_qs`，
实际外层变量名是 **`segmentation_alt_qs`**，改名即过。
（这是本会话踩的作用域坑：MoonBit `{}` 块内声明不对外可见，相关变量
已全部提升到 886 行附近的外层声明区。）

### 2.3 待写：decode_b 的 seg_id 符号（`libavcodec/av1_decode4.mbt`）

现在 `decode_b` 里是 `let seg_id = 0` + segmentation PATCHWELCOME raise
（约 200–205 行）。参照 dav1d `src/decode.c`：

- **关键帧简化**：key frame 的 `primary_ref_frame = 7`（PRIMARY_REF_NONE）
  → `update_map=1、temporal=0、update_data=1` 恒成立，所以
  **seg_pred 符号路径和 prev_segmap 路径都不会触发**，只需写非 temporal 分支。
  （若不放心，入口对 `temporal`/`!update_map` 显式拒绝也行——关键帧到不了。）
- **preskip 路径**（`hdr.seg_preskip`，即任一 seg 启用 REF/SKIP/GLOBALMV feature）：
  seg_id 在 **skip 符号之前**解码（decode.c 829–866）：
  `have_left = self.bx > self.col_start`，`have_top = self.by > self.row_start`（tile 边界语义，与 dav1d 一致）；
  `pred/ctx = av1_get_cur_frame_segid(f.cur_segmap, f.b4_stride, by, bx, have_top, have_left)`；
  `diff = msac.decode_symbol_adapt(cdf.seg_id, ctx*8, 7)`（CDF 是 `[3][8]`）；
  `seg_id = av1_neg_deinterleave(diff, pred, hdr.seg_last_active + 1)`；
  `> seg_last_active → 0`，`>= 8 → 0`。
- **skip 符号**（decode.c 886–893）：preskip 且该 seg 的 SKIP feature
  （`hdr.segmentation_feature_mask[seg_id]` bit 5）启用 → `skip=true` 不读符号；
  否则照旧读 `cdf.skip`。
- **postskip 路径**（!seg_preskip，decode.c 895–940）：skip 符号之后；
  `skip=true → seg_id=pred`（不读符号），否则读符号同上。
- **上下文/segmap 写回**（decode.c 1936–1947）：块覆盖的 `bh4×bw4` 个 4x4
  写 `f.cur_segmap[by*b4_stride+bx] = seg_id`；`a.seg_pred[bx4..]`/`l.seg_pred[by4..]`
  写 0（非 temporal 时 seg_pred 恒 0，但上下文要写）。

### 2.4 已经不用动的对接点（写 decode_b 前确认过）

- **dequant**：`decode_coefs`（`av1_decode2.mbt:276`）已经按
  `b.seg_id * 6 + plane*2` 索引 `dq_cur`——decode_b 产出真实 seg_id 即自动生效；
  `fill_dq`/`f.dq` 已 per-seg。
- **tx/lossless**：`av1_decode4.mbt` 的 `f.seg_lossless[seg_id]` 消费已在
  （340/439 行）。
- **CDEF noskip/cdef_idx**：都由 `!skip` 门控，seg SKIP feature 让 skip=1
  自然联动，无需改。

### 2.5 待写：`av1_calc_lf_values` 的 seg_delta（`libavcodec/av1_lf.mbt`）

dav1d `lf_mask.c` `calc_lf_value(base_lvl, lf_delta, seg_delta, mr_delta)`：
`base = iclip(iclip(base_lvl + lf_delta, 0, 63) + seg_delta, 0, 63)`。
当前 MoonBit 版只加 `lf_delta`；需要给 `av1_calc_lf_value` 加 `seg_delta`
参数，`av1_calc_lf_values` 的 seg 循环里取
`hdr.seg_delta_lf[s*4 + dir]`（`n_seg=8` 分支已存在）。chroma 的
`level==0` 早退在加 delta 之前判断（现结构已对）。`create_lf_mask_intra`
的 `lvl[seg*64+dir*16]` 索引已对，不用改。

### 2.6 验收

```sh
moon check --target wasm --deny-warn --no-render   # 先修 §2.2
moon test --target wasm --no-render                # 期望 ≥872/872 无回归
```

**现成向量**：`.scratch/av1_hbd/rav44410.ivf`（rav1e 444p10 320x240 4 帧，
`segmentation_enabled` + **`lr_type=[1,1,1]` SWITCHABLE**——修完 seg 顺带
覆盖此前缺失的 SWITCHABLE LR）。期望 md5（libdav1d framemd5）：

```
6d2e878462c1662a0d512bdfe777939f
409f3b3dba66f0ad7d11d913c562ed9d
4697af2a0fe6608f8d665fb11c1265a9
82650ec88b7303f28d4d9e90bbfc5a56
```

该向量此前只被 segmentation 拒绝挡住；seg 修好后若再冒出别的拒绝
（rav1e 可能带 delta_q），按报错逐个处理。建议再补一条 rav1e 420 8-bit
的 seg 向量（`-pix_fmt yuv420p -c:v librav1e -qp 60 -speed 6 -g 1`）。
向量并入按惯例放独立测试包（rav1e 流可能大，别塞进 extra_test）。

通过后收尾清单：README 能力行（segmentation 从缺口移到能力）、
PORTING_HISTORY 新章节（§62）、AV1_AGENT_HANDOFF §7、两份旧 handoff 的
HEAD 与测试数、中文 commit + `git push origin master`。

---

## 3. 向量生成速查（本会话踩出来的，全部验证过）

| 需求 | 唯一/最稳做法 |
|---|---|
| LR（任何格式） | **libaom + `testsrc2` 内容** + `-aom-params enable-restoration=1`（mandelbrot 永不启用；testsrc2 稳出 chroma Wiener）。444/422 的 LR 只此一条路。 |
| 高位深 SGR | SVT（ffmpeg 包装 `-pix_fmt yuv420p10le`）——**只支持 yuv420p/420p10**，444/422 输入会被**静默转成 420**（三条流 md5 相同才发现；SVT CLI alpine v2.0 也只编 420）。 |
| 128x128 SB | debian `aom-tools` aomenc `--sb-size=128 --tile-columns=1 --tile-rows=1`（libaom `SUPERBLOCK_SIZE_DYNAMIC` 恒选 64SB，720p 也是；ffmpeg 无透传）。bookworm aomenc 无 `--y4m`，用 `--i420 -w -h --fps` 喂 rawvideo 管道。 |
| delta-q + delta-lf | aomenc `--enable-tpl-model=1 --deltaq-mode=3 --delta-lf-mode=1` + `--kf-max-dist=1`（**mode 3 是关键帧专用 deltaq**；`--deltaq-mode=1` 在全帧内不发符号；SVT 任何 preset 都不发 delta_lf 且无参数键）。 |
| segmentation / SWITCHABLE LR | **rav1e**（ffmpeg 内 `-c:v librav1e`）——唯一带 seg 的关键帧码流来源。 |
| 期望 md5 | `docker run --rm -i linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -i pipe:0 -f framemd5 - < x.ivf \| grep -v '^#' \| awk -F, '{print $NF}'`（docker 入口点即 ffmpeg，命令里**不要**再写 ffmpeg；Git Bash 卷挂载不可靠，走 stdin/stdout 管道）。 |

生成命令模板（libaom）：
```sh
docker run --rm linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=320x240:rate=1 -frames:v 4 -pix_fmt yuv444p10le \
  -c:v libaom-av1 -crf 30 -cpu-used 3 -g 1 \
  -aom-params enable-restoration=1 -f ivf - > out.ivf
```

---

## 4. 本会话新踩的坑

1. **MoonBit 块作用域**：`av1_parse_frame_header` 的解析代码在 `{}` 块里，
   块内 `let` 的变量（如 seg 数据）在后面同函数的推导代码里**不可见**——
   把声明提升到外层（886 行区），引用时注意外层变量名
   （`segmentation_alt_qs` 不是 `seg_alt_qs`，§2.2 的错误就是这么来的）。
2. **bash 拼 .mbt 文件会断字符串**：`printf`/heredoc 组装大 base64 常量时
   行被折断产生 unterminated string。**一律用 Write 工具或 python 脚本**
   生成 .mbt 文件（这也是既有约定，重犯了一次）。
3. `moon test` 输出重定向后必须 `grep -a`（日志含二进制）；
   `-p 包名 -f "测试名"` 可只跑单个测试。
4. 删除文件用 `zcode-trash`（PreToolUse 钩子拦 `rm`，`rm -f` 也拦）。
5. MD5 数组从 shell 拼装时引号闭合易错（本会话拼坏过一次），拼完先
   `moon check` 再跑。

---

## 5. segmentation 之后的优先级

1. **inter 帧**（refmvs + MC 全家，最大一块；参照 VP9 inter 的移植节奏，
   VP9 侧见 `AGENT_HANDOFF_2026-10-24.md` §5 与 VP9 相关章节）。
2. intrabc、film grain、superres 仍报 PATCHWELCOME（入口有检查）。
3. delta_lf `multi=true` 码流手搓（分支已实现，无编码器可产）。

---

## 6. 约定速查（务必遵守）

- **用户偏好：自主推进，每个增量中文 commit 并 `git push origin master`**，
  不需要逐次询问；提交信息风格看 `git log`。
- **不要跑 `moon fmt`**（大面积改写污染 diff）；`moon info` 可以。
- 不提交 `*.generated.mbti`（已 gitignore）、`.scratch/`、`_build/`。
- 大 base64 向量放**独立测试包**（wasm 模块 init 局部变量数有上限）。
- 每个增量收尾：check --deny-warn → 全量 test（重定向 + grep Total tests）
  → 更新 README/PORTING_HISTORY/AV1_AGENT_HANDOFF/两份旧 handoff 的
  HEAD 与测试数 → commit + push。
- 参照物优先级：**dav1d 1.5.1 源码**（`C:\Users\milkb\AppData\Local\Temp\dav1d-src`，
  被清理就 `git clone --depth 1 --branch 1.5.1
  https://code.videolan.org/videolan/dav1d.git`）> FFmpeg 9.0.2；
  像素期望值一律 docker `linuxserver/ffmpeg:9.0.2`（libdav1d）的 framemd5。
