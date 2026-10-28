# 会话交接：AV1 resize 收尾 → VP9 参考缩放 → 工具组合/EC 验证（2026-10-28）

本会话从 AAC PS 提交（`37d2a92`）之后接手，六个提交全部已推送
（`origin/master` = `92efe71`），全量 wasm 测试 **1057/1057**。
专属交接已有两份：`AGENT_HANDOFF_2026-10-27_AV1_RESIZE.md`（AV1 帧尺寸
变化 + w4/h4 修复）与 `AGENT_HANDOFF_2026-10-28_VP9_SCALE.md`（VP9
参考缩放）；本文覆盖会话全貌、无专属交接的两项、EC 边界勘察记录、
用户清单最终状态与测试基建现状。

## 一、提交总览（37d2a92..92efe71）

| 提交 | 内容 | 验证 |
| --- | --- | --- |
| `f0dac88` | AV1 帧尺寸变化（resize-mode）+ 非均匀 tile 间距 + 显式帧尺寸位宽修复 | 7 组 aomenc 流 168 帧逐帧 MD5 对齐 dav1d 1.5.1 CLI 原生输出 |
| `e50ca5e` | AV1 去块/level 缓存改用可见 4x4 网格（`w4/h4 = (dim+3)>>2`），根治自 inter 接入即潜伏的单像素偏差 | testsrc2 random 流补回为 `resize_random_t2` 夹具，8 组流 192 帧全绿 |
| `5082a89` | VP9 参考缩放 scaled MC（`vp9_inter_scaled.mbt` 新文件，`mc_luma/mc_chroma` 分派现算 14 位 scale） | 内核级 C harness 12 用例 FNV 一致 + libvpx 官方 `vp90-2-05-resize.ivf` 10 帧双向缩放 MD5 对齐 vpxdec |
| `b40da98` | AV1 inter 工具组合真实流验证（见下文§二） | 5 组 70 帧 MD5 一致 |
| `9215cf6` | H.264 P 帧 EC 第二源矩阵 + `h264_display_order` pub 再导出（见下文§二） | 4 损坏案例 × 6 帧逐帧 MD5 一致 |
| `92efe71` | wasm_probe 主入口 fmt 现代化（`fn main()` → `fn main`，纯机械重排） | check 0 警告 |

## 二、无专属交接文档的两项

### 1. AV1 inter 工具组合（PORTING_HISTORY §110）

目的：回应 README"更广 inter 工具组合待验证"——§83-96 逐工具移植的
inter 路径此前只有单工具隔离测试，未在**组合开启的真实码流**上验证。

覆盖（`scripts/generate_av1_toolcombo_vectors.mbtx`，testsrc2 192x128
14 帧，aomenc 工具开关互斥隔离 + 全开组合）：

- `tool_iic`：interintra 家族（`--enable-interintra-comp/-wedge/
  -smooth-interintra`），关 masked/obmc/warp/dual-filter
- `tool_masked`：masked compound（wedge/diffwtd），关其余
- `tool_obmc`：OBMC + local warp，关其余
- `tool_rf_mvs`：dual filter + ref-frame-mvs，关其余
- `tool_all`：七项全开

**关键坑**：aomenc 默认全开这些工具，单独 `--enable-X=1` 不改变编码
决策（五流字节数完全相同，实测 14317/14498 两种）；必须**互斥关闭其他
工具**才能做出差异化编码、真正隔离验证。夹具：
`libavcodec/av1_inter_realdata_vectors/tool*_fixture_test.mbt` +
`toolcombo_test.mbt`；参考链复用 resize 轮（dav1d CLI 逐帧原生 md5 +
`assemble_resize_md5.mbtx` 组装 + `emit_av1_session_vectors.mbtx` 出
夹具，`tool_` 前缀已路由到本生成器）。

### 2. H.264 P 帧错误恢复第二源矩阵（PORTING_HISTORY §111）

目的：此前 EC 矩阵只有 `h264_slices1.264` 一个源；README 的"P 帧大
缺口"需要独立第二源确认 P 帧恢复（guess_mv → put_dc → EC deblock
链）非过拟合。

覆盖（`libavcodec/h264_er_420p_test.mbt`，blackbox）：testsrc2 96x64
8-bit 4:2:0，6 帧（IDR+4P+IDR，3 slice/帧 first_mb 0/12/18）：

| 案例 | 损坏 | NAL 索引 |
| --- | --- | --- |
| drop_idr_head | 丢 IDR 首 slice | drop [4] |
| drop_p_head | 丢 P 首 slice | drop [6] |
| two_p | 丢两个 P slice | drop [9,10] |
| trunc_p_last | 截断尾 P slice 至 3/4 | trunc [(11,3)] |

再生命成链（参考 FFmpeg framemd5 时注意 **`-fps_mode passthrough` 是
输出选项，必须放 `-i` 之后**，放前面报 option parsing 错误）：

```sh
# 源（linuxserver/ffmpeg:9.0.2）
ffmpeg -f lavfi -i testsrc2=size=96x64:rate=30 -frames:v 6 -pix_fmt yuv420p \
  -c:v libx264 -x264-params slices=3:bframes=0:keyint=5 -y h264_er_420p.264
# 损坏变体：主机 python 按 NAL start code 切分后 drop/trunc（见测试内
# h264_er_p_damage 函数，trunc 粒度 1/4 NAL）
# 参考（每案例一条）
ffmpeg -flags2 +showall -i h264_er_420p_<case>.264 -fps_mode passthrough \
  -f framemd5 -y <case>.md5
```

工程注意：该夹具原写为 wbtest，**libavcodec 白盒包 wasm init 局部数
已满**（加夹具即 "local count too large"），转 blackbox
（`*_test.mbt`）并为 `h264_display_order` 在 `h264_output.mbt` 加了
pub 再导出（内部实现改名 `_impl`，pub 包装调用）。

## 三、H.264 EC 非对齐边界勘察记录（444/422/10-bit，结论：不做）

对 `yuv444p/yuv422p/yuv420p10le` 三组同源损坏流做了逐像素对齐尝试，
定位到 FFmpeg `error_resilience.c` 的两个硬编码行为，属与未定义行为
耦合的实现细节，不做逐像素复刻（README 已改为"明确不在对齐范围"）：

1. **色度恢复固定 4:2:0 几何**：`put_dc`/DC 采集按
   `dest_cb = data[1] + mb_x*8 + mb_y*8*linesize` 每 MB 一个 DC、写
   8x8 区域。4:4:4/4:2:2 下写入只覆盖每 MB 左上 8x8 色度块，其余保留
   解码残留（参考输出中 U 平面下半全 0 即越界几何产物）。
2. **`put_dc` 写 `dc/8` 的 uint8 语义**：10-bit 平面按低字节截断，
   ER 的 dc 采集/SAD/EC deblock 同样全程 uint8。

勘察方法（复用价值）：构造损坏流 → FFmpeg `-f rawvideo -pix_fmt <fmt>
-frames:v 1` 导出参考帧 → 测试内嵌 base64 对比，按平面统计 diff 分布
与首差位置（`F0 dbg: diffs=... first=...` 模式）。本次实测：444
drop_head_i 帧 0 的 Y 平面**完全一致**、差异全在 U/V 从 row8 起——
即色度几何差异，佐证边界结论。勘察中确认的 MoonBit 侧正确形态
（conceal 色度 DC 网格应为 MB 几合而非每 8x8 块）在 4:2:0 下两种网格
重合，故不带入主线。

Opus PLC 同轮评估放弃：FFmpeg native opus 解码器本身无 PLC（那是
libopus 的功能），缺口定义不成立。

## 四、用户清单最终状态

原始清单：解码 H264+HEVC+AV1+VP9+MJPEG+PNG；音频 AAC+MP3+Opus；
容器 MP4、MKV、TS、HLS、DASH、WebM、WAV。

- **全部条目均有实现且经真实流验证**（README 表格为权威状态）。
- 本会话新收敛：AV1 帧尺寸变化/非均匀 tile、AV1 inter 工具组合、
  VP9 参考缩放、H.264 P 帧 EC 第二源。
- 剩余缺口全部为外部受阻，见 README"主要边界"列：
  - VP9 复合预测（B 帧）/ 变体：libvpx 编码器无法生成（alt-ref 探针证实）
  - HEVC tiles+WPP 同时启用 / 当前图片引用（CPR）：HM 拒绝 / 需 SCC 编码器
  - H.264 EC 高位深/444/422：FFmpeg ER 硬编码 420+uint8（本文§三）
  - AAC USAC：项目边界明确不做
  - AV1 film grain / intrabc：项目边界明确不做
  - 容器统一播放 API：新工程性质，建议单独立项

## 五、测试基建现状与坑（务必先读）

1. **libavcodec 白盒包 wasm init 局部数已贴上限**（≈5 万，moonc
   v0.10.16/17）：新增大 base64 夹具一律放 blackbox（`*_test.mbt`，
   经 `@libavcodec.` 前缀调用 pub API）。先例：AV1 resize 夹具
   （起初 wbtest 编译失败转 blackbox）、VP9 resize/kernel 夹具、
   H.264 EC 420p 夹具。需要白盒私有 helper 时在产品代码加 pub 薄包装
   （先例：`h264_display_order`）。
2. **尺寸变化流的参考不能用 FFmpeg framemd5**：filter graph 会把后续
   帧自动缩放到首帧尺寸再哈希。AV1 用 dav1d 1.5.1 CLI（容器内 meson
   构建 `.scratch/av1/trace_src`），VP9 用 `vpxdec --i420 -o
   'f%2n_%w_%h.yuv'` 逐帧原生输出（注意 `%2n` 帧号从 1 起）。
3. dav1d CLI：`%n` 文件名替换只在**未强制 `--muxer`** 时生效（按扩展名
   探测）；默认多线程走 task 路径，单线程插桩需 `--threads 1` 才命中
   `dav1d_filter_sbrow`。
4. 容器 sh 是 dash：`for f in glob` 词表只展开一次，逐帧循环用
   `while :; do set -- dir/d${n}_*.yuv; [ -e "$1" ] || break; ...`；
   帧序严禁按文件名排序（stem 含下划线破坏 sort 键）。
5. aomenc 语义：resize-mode 固定模式 `--resize-denominator=16
   --resize-kf-denominator=8` 得 KF 全/inter 半；单 denominator 不触发
   缩放；resize×superres×qm 组合会令 dav1d 1.5.1 段错误（不做）。
   工具开关默认全开，隔离验证需互斥关闭（§二）。
6. MoonBit 语法坑（本会话新增）：字符串里 `\$` 是非法转义（会静默
   使脚本编译失败）；`15.lnot()` 把 `15.` 当浮点、`~15` 词法拒绝，
   掩码写 `(-16)` 或 `.lnot()` 前加空格再括号；掩码与加法混用必须
   显式括号（ambiguous_precedence）。
7. rm-guard 会拦截命令**字符串**里的 `rm`/`del` 字样（含 "delete"
   注释、`rm` 出现在单词内），写 python 内联脚本时避免这些词。
8. 生成脚本模式：`moon run scripts/<name>.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1`
   （绝对路径挂载）；docker 需 `MSYS_NO_PATHCONV=1` 防 Git Bash 路径
   转换；apt 源换 TUNA（`mirrors.tuna.tsinghua.edu.cn`）。

## 六、再生命令速查

```sh
# AV1 resize + 工具组合夹具（含 dav1d 参考生成）
moon run scripts/generate_av1_resize_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1
moon run scripts/generate_av1_toolcombo_vectors.mbtx D:/project/FFmpeg-n9.0.2/moonbit/.scratch/av1
# VP9 resize（参考生成见 AGENT_HANDOFF_2026-10-28_VP9_SCALE.md）
# H.264 EC 420p（§二命令）
# 标准收尾
moon fmt && moon check --target wasm --no-render && moon test --target wasm --no-render && moon info --target wasm
# 相关测试过滤（moon filter 为 glob，不支持 |）
moon test libavcodec --target wasm --no-render --filter "*resize*"
moon test libavcodec --target wasm --no-render --filter "*tool*"
moon test libavcodec --target wasm --no-render --filter "*scaled*"
moon test libavcodec --target wasm --no-render --filter "*4:2:0 source*"
```

## 七、文档与记忆状态

- PORTING_HISTORY §108-§111 已记录本会话四项；
- README 的 AV1/VP9/H.264 三行及散文段已同步；
- 记忆文件 `av1-pixel-status.md`、`vp9-slice-status.md`、
  `ffmpeg-moonbit-migration-progress.md` 已更新；
- 工作树干净（仅 `scripts/__pycache__/` 未跟踪，本地缓存不入库）。
