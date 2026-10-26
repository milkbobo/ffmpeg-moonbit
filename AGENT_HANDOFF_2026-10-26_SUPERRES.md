# AV1 整帧 superres（2026-10-26）

从 `8efc14e`（§96 inter 会话）接续，本轮把整帧 superres 从「明确拒绝」
接通到端到端 MD5 收敛，并顺带修复一个 sb128 下必触发的 LR 左边界 bug。
当前状态以本文和 PORTING_HISTORY §97 为准。

## 本轮实现（dav1d 1.5.1 语义）

- 帧驱动 `av1_decode_frame_payloads`（av1_decode6.mbt）去掉 superres
  guard。管线改为 dav1d 双平面模型：coded 宽度（`hdr.width`）完成
  解码/deblock/CDEF → resize 级把三平面上采样到 `hdr.upscaled_width`
  （逐行 `@av1_mc_core.av1_mc_resize`，原语新增 `src_off` 参数；步长
  `av1_scale_fac(in, out) = ((in<<14)+out/2)/out`（注意参数序：分子是
  **coded** 尺寸）、相位 `av1_get_upscale_x0`，两者等价 dav1d
  `scale_fac`/`get_upscale_x0`）→ 重绑 `f.planes/y_stride/uv_stride` 到
  上采样平面 → LR 在上采样宽度上跑 → 输出 picture 宽度 = upscaled。
  重绑是安全的：重绑后只有 LR 与输出使用这些字段。
- LR upscaled 化：`Av1FrameCtx` 新增 `sr_sb128w = (upscaled+127)>>7`
  （LR 单元网格 stride，`>= sb128w`，lf_mask 按 `sr_sb128w*sb128h` 分配，
  LF/CDEF 索引不变）；`av1_lr_sbrow` 的 plane_w 用 upscaled；
  `read_restoration_sb`（av1_lr.mbt）补 superres 分支——coded SB 区间
  `x0/x1 = ((bx*4*d >> ss_h) + unit_size*8-1) >> (log2+3)` 映射到上采样
  单元索引、`sb_idx` 用 `sr_sb128w`，一个 SB 可读多个单元，逐个
  `read_restoration_info`。
- LR 边界备份 resize：`av1_lr_backup_lpf` 补 dav1d `backup_lpf` 的
  resize 分支——每条带只 resize `n_lines` 行（src 指针不随行推进，组间
  固定跳 64 行），`n_lines==3` 时复制上一行；buffer 以重绑后的上采样
  stride 分配，但源行仍从 coded 快照按 coded stride 取（`lr_frame` 显式
  收 `coded_y_stride/coded_uv_stride`）。step/phase 与主 resize 相同。
- 会话入口 `av1_session.mbt` 去 guard。参考槽位语义：picture 保持上采样
  宽度（scaled MC 的 svc、2×/16× 限制都按上采样宽，dav1d
  `f->frame_hdr->width[0]*2 < ref->p.p.w` 一致）；但
  `Av1RefmvsReference.upscaled_width` 更名 `coded_width`——dav1d 的
  时域 MV 同尺寸门比较 ref **coded** 宽 8 对齐值与当前 `bw`（§96 期间
  按上采样理解是错的，无 superres 流两者相等故未暴露）。
- **顺带修复（sb128/superres 必触发）**：`av1_lr_stripe` 条带循环原先
  不推进左边界指针；现按 dav1d `left += stripe_h` 在**每条带滤波后**用
  「刚滤波完的条带高度」推进 `loff += stripe_h*4`，且必须在下一条带
  高度重算之前（首条带 56 行）。此前 sb64 每次 `lr_stripe` 调用恰一条带
  （left 每单元重取）从未暴露。
- 帧头 `Av1FrameHeader` 新增 `superres_denom`（9..=16，未启用=16）。

## 真实流验证与再生

FFmpeg 的 libaom/svt 封装都不暴露 superres 参数；用 apt 的 `aom-tools`
（aomenc）。源 y4m 由 linuxserver/ffmpeg:9.0.2 生成（10bit 需
`-strict -1`）。全部 8-bit/10-bit yuv420p：

| stem | 源与编码参数 | 显示帧 |
| --- | --- | --- |
| superres_inter | testsrc2 192x128 rate5；cpu-used6 cq30 lag0 g30 superres-mode=1 denom=13 | 8 |
| superres_kf | mandelbrot 192x128 rate5；同上但 kf-max-dist=1 denom=9（aomenc fixed 模式关键帧不启用，对照流） | 10 |
| superres_10bit | testsrc2 yuv420p10le；mode=1 denom=12 | 8 |
| superres_mixed | testsrc2 192x128；mode=2（逐帧随机 denom 9–15，含非 superres 帧） | 8 |

```sh
# 1) y4m 源（linuxserver/ffmpeg）
docker run --rm --entrypoint sh -v $PWD/.scratch/av1:/work linuxserver/ffmpeg:9.0.2 -c \
  "ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=192x128:rate=5 -frames:v 8 -pix_fmt yuv420p -f yuv4mpegpipe -y /work/src8.y4m"
# 2) aomenc（ubuntu:24.04 + aom-tools）
docker run --rm -v $PWD/.scratch/av1:/work ubuntu:24.04 sh -c \
  "apt-get update -qq && apt-get install -y -qq aom-tools && aomenc --codec=av1 -o /work/superres_inter.ivf /work/src8.y4m --ivf --cpu-used=6 --end-usage=q --cq-level=30 --lag-in-frames=0 --kf-max-dist=30 --superres-mode=1 --superres-denominator=13 --passes=1 --threads=1 --quiet"
# 3) libdav1d framemd5（linuxserver/ffmpeg）
docker run --rm --entrypoint sh -v $PWD/.scratch/av1:/work linuxserver/ffmpeg:9.0.2 -c \
  "ffmpeg -hide_banner -loglevel error -i /work/superres_inter.ivf -f framemd5 -y /work/superres_inter.framemd5"
# 4) MoonBit fixture
moon run scripts/emit_av1_session_vectors.mbtx superres_inter
```

注意 aomenc 旗标是 `--superres-denominator`（无 `--superres-denom`）。
34 帧全部与 libdav1d 逐帧 MD5 一致；scaled-reference MC 路径首次被
真实流覆盖。fixture 头注释指向本文。

## 调试基建（可复用）

`.scratch/av1/run_sr_stage.py`：把 trace_src dav1d 树打进
vpxdev-img gcc 直编（`-Wno-error=incompatible-pointer-types`，upstream
自身有该警告），插桩 dump 逐级像素（coded post-CDEF / resize 输出 /
final），base64 通道回传——Windows 管道会吞二进制 NUL 字节，不能 cat
tar。本轮就是用它两级 0 差分定位：(1) resize 全错 = `scale_fac` 参数序
反了；(2) resize 0 差异但 final 偏 = LR 左边界指针推进缺失 + 推进时序。
trace_src 里残留的 PIXPRE/PIXPOST/RSZP/LRST 调试打印无害（编译期常量
裁剪或仅 stdout）。

## 后续范围

1. **qmatrix**：仍明确拒绝（`av1_decode_frame_payloads` 开头 guard）。
2. 扩大 inter 验证：12-bit、444/422/mono、128SB、参考尺寸变化、
   superres × 更广工具组合（现仅 4:2:0 8/10-bit + yuv420 变 denom）。
3. film grain、intrabc、grain-from-reference 按既定范围不做。

验证结果：`moon check --target wasm --deny-warn --no-render` 零警告；
全量 `moon test --target wasm --no-render` **972/972**；`moon fmt` 与
`moon info --target wasm` 已运行。生成接口按仓库约定忽略；按长期授权
自主提交并推送。
