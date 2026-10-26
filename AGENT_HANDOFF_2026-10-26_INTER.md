# AV1 帧间帧解码交接报告（2026-10-26）

> 后续进展：`PORTING_HISTORY.md` §74–§84 已加入 refmvs 行状态、
> 参考/MV 模式语法原语、参考槽位与上采样宽度语义、复合 mask/
> inter-intra/motion variation/subpel 滤波器语法、warp 邻居匹配与
> 仿射模型推导、帧间环路滤波掩码，以及帧间块语法驱动；块驱动已完成
> 与 dav1d `decode_b` inter 分支的 96 组随机位级对拍（含 msac 终态），
> 并新增 warp 平面预测/prep、复合合成、块级预测装配、inter-intra
> 与 OBMC、色度 sub8x8 派生（§85–§89），以及帧间变换类型选择
> `txtp_inter1/2/3` 与色度派生（§90），Wasm 全量测试 952/952；
> 下一步是残差叠加与整帧入口。
> 本文 §3.1 对 `save_tmvs` 实参的描述有误；真实实参见
> dav1d `src/refmvs.h`，为 `rt->r + 6`。

> 交接对象：下一个接手本仓库的 AI/协作者。
> 仓库：`D:\project\FFmpeg-n9.0.2\moonbit`（Windows 10 + Git Bash）。
> 基线：提交 `67437fc` 已推送，`moon check --deny-warn` 0 警告，
> Wasm 全量测试 **895/895**，工作树干净。
> 历史背景见 [AV1_AGENT_HANDOFF.md](AV1_AGENT_HANDOFF.md) 头部指针与
> [PORTING_HISTORY.md](PORTING_HISTORY.md) §63–§73；本文自包含开工所需全部信息。

---

## 1. 任务与验收

用户清单中 AV1 是唯一未完成的解码器（H.264/HEVC/VP9/MJPEG/PNG/
AAC/MP3/Opus/全部容器均已提交）。当前战线是 **AV1 帧间（inter）帧**：
关键帧（无损+有损、全格式、多 tile、LF/CDEF/LR、segmentation）已全收敛。

- **参照实现**：dav1d 1.5.1（FFmpeg 的 av1dec.c 无软件像素解码）。
  源码已克隆在 `C:\Users\milkb\AppData\Local\Temp\dav1d-src`（若被清理：
  `git clone --depth 1 --branch 1.5.1
  https://code.videolan.org/videolan/dav1d.git`）。
- **最终验收**：docker `linuxserver/ffmpeg:9.0.2`（libdav1d）的
  framemd5 与 MoonBit 逐帧 MD5 一致（关键帧路径已有此验收先例，
  见 `av1_lossy_vectors` 等包）。
- **中间验收**：每个组件与真 C 实现位级对拍（本文 §4 的管道）。

## 2. 已完成（全部已提交推送）

| 阶段 | 提交 | 内容 |
|---|---|---|
| §63–§66 | 历史 | 单参考 MC put（8tap/bilin）、prep/avg/w_avg、diffwtd mask、OBMC blend |
| §67 | `dbf4d04` | wedge + inter-intra 掩码表（wedge.c 完整移植）与 wedge blend |
| §68 | `e377dde` | 缩放 MC put/prep + superres resize（环形缓冲改直接求值） |
| §69 | `25ba9b5` | warp 仿射 8x8 put/prep（193 相位表） |
| §70 | `fc83d4f` | 帧间帧头：GM 三类型 subexp、skip_mode 两段推导、短信令 refidx 派生、frame_size_with_refs、seq 六工具位；`Av1RefSlotState` 参考池 |
| §71 | `acace0d` | NEWMV 残差解码原语 `av1_read_mv_residual`（4×400 步位级对拍） |
| §72 | `8d5f71c` | **refmvs_find 完整移植**（空间/secondary/时域候选、mv_projection、get_gmv_2d、双段排序、compound same/diff 别名合并、ctx；1008 例对拍） |
| §73 | `67437fc` | refmvs 帧初始化（sign_bias/mfmv_sign/pocdiff + mfmv 参考选择 ref2cur/ref2ref；20 组对拍） |

关键帧路径（§42–§62）此前已全部收敛，本报告不涉及；改动它时先跑全量测试。

## 3. 剩余工作（按推荐顺序）

### 3.1 #5b-2：refmvs 状态机接线（中等，~300 行）

`av1_refmvs.mbt` 已有 find/init_frame 的纯函数；缺 dav1d `refmvs.c` 的：

1. **`load_tmvs_c`**（refmvs.c:690）——把参考帧的 `rp`（8x8 时域块）按
   mfmv_ref/ref2cur/ref2ref 投影进当前 sbrow 的 `rp_proj[16×stride]`。
   内层有"连续同 ref 同 mv 块沿 x 快进"的去重循环（`rb++` 直到
   ref/mv 变化），移植时保持 `x--` 回退语义。
2. **`save_tmvs_c`**（refmvs.c:763）——从 `rt->r` 的空间块（4x4）抽
   8x8 时域块写回 `rp`；优先 ref[1]（mfmv_sign 且 |mv|<4096）再 ref[0]。
   注意实参是 `&t->rt.r[t->by & 31]`（decode.c 调用点），行取
   `rr[(y & 15) * 2]`——**先读 decode.c 的调用序列再定接口**。
3. **`splat_mv_c`**（refmvs.c:900）——把解码后的块 MV 填进
   `rt->r` 主区行（`rr++` 逐行、`r[x] = *rmv`）。
4. **`dav1d_refmvs_tile_sbrow_init`**（refmvs.c:653）——37 槽行指针环
   （off=16*sby&16、偶数槽交换）。MoonBit 表示建议：物理行数组
   `FixedArray[FixedArray[Av1Rb]]`（行数 2*sbsz+3）+ 槽→物理行号
   `FixedArray[Int]`（代替 dav1d 的指针表）。

**对拍方案**：扩展 `%TEMP%/dump_refmvs.c`——随机 `rt->r` 空间块阵
→ save → dump `rp`；随机 `rp_ref` → load → dump `rp_proj`；
随机模板 → splat → dump；sbrow_init 逐 sby dump 槽表。emitter/
模板模式照抄 §4.3（rnd 状态务必**局部化**，见 §5 坑 6）。

### 3.2 #4b：帧间块语法 decode_b inter 分支（大，~800 行，最难）

dav1d `src/decode.c` 的 `decode_b` inter 部分（约 1200–1700 行区域）。
**依赖已就绪**：全部 CDF（`av1_cdf_tables.mbt`）、MV 残差（§71）、
refmvs_find（§72）。按 dav1d 顺序：

1. `skip_mode` 块（hdr.skip_mode_enabled 时双 ref + NEARESTMV_NEARESTMV
   + comp AVG 直通路径）；
2. seg_id（关键帧路径已有，复用）、skip（inter 用不同上下文）；
3. `is_comp`（reference_select 门）→ refidx 读法（单 ref 3 符号树 /
   comp 的 fwd/bwd/uni 三表）；
4. inter 模式：`refmv_mode`（DRL）+ newmv/globalmv/refmv CDF 组合，
   由 §72 的 ctx 驱动（ctx>>4=refmv_ctx、ctx>>3&1=globalmv_ctx、
   ctx&7=newmv_ctx）；NEWMV→`av1_read_mv_residual`；NEAR/NEAREST→
   mvstack 取；GLOBALMV→tgmv（`gmv_warp_allowed` 时走 warp MC）；
5. comp 类型（wedge/diffwtd/seg）、interintra（wedge 掩码查 §67 的
   `av1_wedge_mask`/`av1_ii_mask`）、motion_mode（obmc 驱动 + warp）；
6. filter 选择（switchable 时读 filter CDF，dual_filter 影响 h/v 独立）；
7. recon：mc 调用（recon_tmpl.c `mc()`——emu edge + scaled/非 scaled
   分发、`obmc()` 驱动邻居块）；系数解码复用关键帧 `decode_coefs`
   （inter 的 eob/tx 上下文不同，核对 cdf 键）。

落地文件：`libavcodec/av1_inter.mbt`（已有 mv residual）；解码器骨架
复用 `av1_decode.mbt`~`av1_decode6.mbt` 的 TileCtx/FrameCtx 结构。

### 3.3 #6：整帧入口 + 端到端对拍

- `av1_decode_inter` 入口（复用关键帧 tile sbrow 循环 + refmvs 的
  load/save 钩子 + 参考帧池挂载（`Av1RefSlotState` × 8，
  解码后按 refresh_frame_flags 更新）；
- docker 产 P/B 帧流对拍 framemd5（见 §4.4 命令）；
- superres（§68 resize 已就绪，接 `dav1d_filter_sbrow_resize` 时机）。

### 3.4 明确不做（已声明 PATCHWELCOME）

film grain、intrabc、grain-from-reference（入口已报错，与上游 FFmpeg
行为一致）。SP/SI（H.264）、VP9 复合预测同理（历史定论）。

## 4. 工具链（全部现成，直接复用）

### 4.1 docker C 参考管道

- 镜像：**`vpxdev-img:latest`**（自带 gcc；`ubuntu:24.04` 的 apt 不稳，
  别再用）。MSYS 路径会坏，一律 stdin/stdout 管道；
  `--entrypoint /bin/bash` 且 python 里传参数表（不经 shell）。
- 16bpc TU 需要**空 config.h 覆盖搜索序**（dav1d config.h 硬编码
  BITDEPTH=8），参见 `.scratch/av1/mvres_cycle.py` 的 cfg16 做法。
- 现成管道脚本（`.scratch/av1/`）：`wedge_cycle.py`、`scaled_cycle.py`、
  `warp_cycle.py`、`mvres_run.py`、`refmvs_run.py`。
  **refmvs_run.py 不重建 tar**——改 C 后必须先重建（wedge/scaled
  同理，见各脚本内注释或手动 tar，这是踩过的坑）。
- C dump 程序（`%TEMP%`）：`dump_wedge.c`+`wedge_blend8/16.c`、
  `scaled_ref8/16.c`、`warp_ref8/16.c`、`dump_mvres.c`、
  `dump_refmvs.c`。链接集按需：msac/cdf/ref 要配 mem-pool 桩
  （见 dump_mvres.c 头部）。

### 4.2 关键库直编要点

- `refmvs.c` 可直接 `#include "src/refmvs.c"` 进 dump（static 函数
  可用）；链接 `tables.c scan.c dequant_tables.c`。
- `default_cdf` 是 file-static——经公开 `dav1d_cdf_thread_init_static/
  copy` 取（见 dump_mvres.c）。
- `mc_tmpl.c` 按 8bpc/16bpc 两份 TU 实例化；16bpc 中间样本是
  int16 带 PREP_BIAS，`PXSTRIDE(x)=x>>1`（字节跨距）。

### 4.3 向量生成（emitter + 模板模式）

固定套路：`scripts/_emit_av1_<组件>_vectors.py` 读 `%TEMP%` 的 dump
生成数据表，**测试逻辑放 `scripts/_av1_<组件>_test_body.tpl` 模板**
（避免 python 字符串嵌套 MoonBit 的转义地狱）；测试包
`libavcodec/av1_<组件>_vectors/`（独立包，libavcodec 主包 wbtest 的
Wasm init 局部变量已满，**新向量一律放独立包**）。
范例：`_emit_av1_refmvs_vectors.py` + `_av1_refmvs_test_body.tpl`。

### 4.4 端到端向量

```sh
docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -f lavfi \
  -i "testsrc2=size=160x120:rate=10" -frames:v 4 -pix_fmt yuv420p \
  -c:v libaom-av1 -crf 30 -deadline good -cpu-used 4 -f ivf pipe:1 > x.ivf
docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -c:v libdav1d \
  -i pipe:0 -f framemd5 -pix_fmt yuv420p pipe:1 < x.ivf > x.framemd5
```

## 5. 本轮踩坑清单（新接手先读，能省半天）

1. **`dav1d_msac_init` 第 4 参是 disable_cdf_update**（传 1=禁更新）；
   dump 与 MoonBit 的 update 语义必须一致，否则首步后 CDF 表分叉
   （症状：首例全对、第二例 rng 漂移）。
2. dav1d `read_mv_component_diff` 的 **class0_hp 读取不带 up 索引**
   （恒行 0；classN_hp 同理）。
3. dav1d CDF 宏 `CDF1(x)=(32768-x)`——**内存即镜像表示**，与 MoonBit
   提取表天然一致；对拍别按 cdf.c 字面值手工对照。
4. **compound 扩展候选的 `same` 是 mvstack 尾部别名**（
   `same = &mvstack[*cnt]`）——cnt=1 时槽位从 stack[1] 起；
   用独立数组会错覆 stack[0]。
5. `BS_64x32` 的枚举值是 **4**（0,3,7,8,11,12,13,16,17,18,20,21,4,6
   这张 bs 测试表别抄错）。
6. **MoonBit 测试并行执行**：测试间共享的全局可变状态（如 LCG rnd）
   会数据竞争——rnd 状态一律**局部化并由函数返回尾状态**传递。
7. **bash heredoc 写含 `\n` 的 C/python 字符串会断行**——写 C 一律用
   Edit/Write 工具，python 脚本嵌套字符串宁可拆模板文件。
8. 单参考时 C dump 里 mvstack 的 mv1 是**未初始化栈内存**——emit
   侧归零对拍（compound 才有效）。
9. `refmvs_run.py` 等**不重建 tar**：改了 `%TEMP%` 的 C 源必须手动
   重建 tar 再跑（症状：输出"没变"）。
10. MoonBit 语法速查（本轮实际踩到）：`&=` 不存在；`is` 是关键字；
    `pub struct` 字段外部只读（跨包构造要 `pub(all)`）；
    `String::split` 返回 `Iter[StringView]`（`.to_array()` 后元素是
    StringView，inspect 的 content 要 `.to_owned()`）；
    `FixedArray::make(n, 引用初值)` 所有元素别名同一实例（嵌套数组
    用 `makei`）。

## 6. 工作约定

- 删除文件一律 `zcode-trash <路径>`（绝不用 rm，PreToolUse 钩子拦截）。
- 每完成一个组件：`moon check --target wasm --deny-warn --no-render`
  0 警告 → `moon test --target wasm --no-render` 全绿 → 中文 commit
  （风格看 git log，如 `feat: 增加 AV1 ...`）→ `git push origin master`
  （自主推进，不需逐次询问）。
- 文档三件套同步：PORTING_HISTORY.md 新章节（含参照/对拍方法/坑）、
  README.md 测试数与能力描述、AV1_AGENT_HANDOFF.md 头部指针。
- 生成器脚本以 `_` 前缀进 `scripts/`；`.scratch/` 不进库。
- `moon info --target wasm` 生成 .mbti 但**不提交**（仓库惯例）。

## 7. 建议的第一个动作

按 §3.1 顺序做 load/save_tmvs：先读 dav1d `decode.c` 中
`dav1d_refmvs_save_tmvs`/`load` 的调用点（确认实参的 `&rt.r[...]`
槽位语义），再扩展 `dump_refmvs.c` 做 save→rp / rp_ref→load→rp_proj
的闭环 dump，emitter/模板照 refmvs 先例。完成后 #4b 的 decode_b
才有完整的候选输入。
