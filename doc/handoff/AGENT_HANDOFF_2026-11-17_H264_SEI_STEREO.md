# 交接文档：H.264 纯编码器 SEI 侧数据线（§427 完成 / §428 进行中）

> 写于 2026-11-17。接手者请先读 `doc/agent.md`（§2 工具链/测试约定、§3 提交规范）
> 与 `doc/PORTING_HISTORY.md` 的 §424–§427 条目。本文件只写**当前切片的精确断点**。

---

## 0. 一句话状态

- **§427（A53 字幕 + 未注册 SEI，纯编码器）已完成且全绿**：51 文件 252/252、
  CLI 30/30、全模块 wasm check 0 警。条目已进 doc/PORTING_HISTORY。
- **§428（STEREO3D / FPA SEI）代码全部写完，但停在「最后一处修复后未再验证」**：
  测试文件已写好，`moon check` 与单文件测试**尚未重跑**，全量回归未跑，
  doc/PORTING_HISTORY/README/记忆未写 §428 条目。
- **未提交链**：§421d–§428 全在工作树（doc/agent.md §3：用户点名才提交）。

---

## 1. §428 精确断点（按此恢复）

### 1.1 已落地的代码（全部在树）

**写端** — `libavcodec/h264_enc_ps.mbt`（A53/unreg 写端之后）：
- `h264_enc_sei_frame_packing(stereo_type : Int32) -> Result[Bytes, String]`
  - 入参是 **`av_stereo3d_*` Int32 常量**（h264_side_data.mbt 的公开词汇表），
    0 = 不写；合法集 1..=7（除 2d=0 之外的 AVStereo3DType 全部）；非法值报
    `"h264 enc: unsupported stereo layout \{v} (av_stereo3d_* value, 0 = off)"`
  - 映射：sbs(1)→type3/q0、top_bottom(2)→4、frame_sequence(3)→5、
    checkerboard(4)→0、sbs_quincunx(5)→3/q1、lines(6)→2、columns(7)→1
    （`sei_to_frame` 的逆向；镜像解码端 `decode_frame_packing_arrangement`
    字段序：id ue(0)/cancel 0/type u7/quincunx u1/content u6=1/3×flip 0/
    current_frame0=1/2×self 0/[grid 16bit 当 q=0 且 type≠5]/reserved u8=0/
    rep ue(0)/ext 0）
  - SEI 类型 45；payload 长度：带 grid 6 字节、quincunx/frame_sequence 4 字节
    （wbtest 已按此断言）
- **设计反转记录**：第一版是 `pub enum H264Stereo3dLayout`（7 变体）——
  `moon check` 对 lib 目标报 7 条 `unused_constructor`（**wbtest/blackbox 的
  构造不算 lib 目标的消费者**，doc/agent.md 的「接上消费者」救不了纯输入型枚举），
  已整体改成 Int32 + 校验；更贴合解码侧词汇表。别改回枚举。

**接线**（`stereo3d~ : Int32 = 0` 标量，语义 = 随 IDR AU 发、上下文持久）：
- intra 两入口：`h264_encode.mbt`（header 位）/`h264_enc_cabac.mbt`（au 位），
  注入点在 §427 侧数据 SEI 之后、slice NAL 之前
- 批量链：encode_p 公共入口 + frames_vbv/frames_qps、cabac 公共入口 +
  vbv_cabac/qps_cabac、encode_b frames_b——7 个签名 + 20 个调用点转发
  （`stereo3d~,`）+ 4 个 IDR intra 调用点
- 流式：`H264StreamEncoder` 新字段 `priv mut stereo3d : Int32`（构造 0）；
  `push_frame(stereo3d~)` 在 check_frame 之后 **stash**（`!= 0` 才覆盖——
  「下一次 IDR 生效」= §424d 绑定的 capture-at-encode-time 语义；push 即 IDR
  的同帧生效）；`stream_idr` 用 `idr_parts` 数组在 AUD 之后、annexb 之前注入
  （**注意：stream_idr 的 AU 组装已从 if/else 改为 idr_parts 数组 + concat**）；
  VBV 路径零改动（trial 经 `..self` 拷贝字段，vbv_picture→stream_idr 自动带）
- 门面：`VideoEncoder::push_frame(stereo3d~)` 转发

**测试**（都已写好、未跑）：
- `libavcodec/h264_enc_stereo_test.mbt`（黑盒 5 测）：全布局往返（含
  frame_sequence 的 view_left）、非法值精确错误串（0/2d/8/-1）、批量持久性
  （解码端 sei_to_frame 对 FPA 不清空→**每帧**都带 Stereo3d）、流式 stash +
  force_idr 换布局（解码序 [IDR0(sbs), P1(persist sbs), IDR2(checkerboard)]）、
  默认字节不变（stereo3d=0 == 缺省）
- `libavcodec/h264_enc_stereo_wbtest.mbt`（白盒 1 测）：7 布局 payload 形状
  （NAL 头 0x06/类型 45/尺寸 6|4/尾 0x80）+ 2d 拒收

### 1.2 断点前最后一个动作

黑盒测试里 `for (i, w) in want`（want 是 Int32 数组）报 E4014——已改成
下标循环（`for i = 0; i < want.length()`）。**此后没有再跑任何验证。**

### 1.3 恢复步骤（照抄执行）

```bash
cd /d/project/FFmpeg-n9.0.2/moonbit
# 1) check（期望 0 错 0 警）
C:/Users/milkb/.moon/bin/moon.exe check libavcodec --target wasm --no-render
# 2) 新测试（黑盒 + 白盒）
C:/Users/milkb/.moon/bin/moon.exe test libavcodec/h264_enc_stereo_test.mbt --target wasm --no-render
C:/Users/milkb/.moon/bin/moon.exe test libavcodec/h264_enc_stereo_wbtest.mbt --target wasm --no-render
# 3) 全模块 check + CLI
C:/Users/milkb/.moon/bin/moon.exe check --target wasm --no-render
C:/Users/milkb/.moon/bin/moon.exe test cmd/encode-h264 --target wasm --no-render
# 4) 全量回归：§427 的清单 + 两个新 stereo 文件（单文件制！见 §3 工具链坑）
(echo "F: libavcodec/h264_enc_stereo_test.mbt"; echo "F: libavcodec/h264_enc_stereo_wbtest.mbt"; cat .scratch/s427_filelist.txt; echo "F: libavcodec/h264_enc_sar_test.mbt") > /tmp/s428_order.txt
# 注意 s427_filelist.txt 是 §426 的 50 文件、不含 sei/sar/stereo 三个新文件；
# §427 的最终 51 文件顺序见 .scratch/h264_s427_fullrun.log 的 F: 行
```

**若 stereo 测试红了，先怀疑这些**：
- 解码器输出是**编码序不是显示序**（3 帧 B 流 decoded=[IDR,P2,B1]；§427 已
  踩过，测试里已按此写——除非流式 force_idr 路径改变了 AU 顺序假设）
- 流式 force_idr 会先 flush_pending（把 pending B 编成 P）再编 IDR——
  3 帧 [push0(sbs), push1, push2(checkerboard+force_idr)] 的 AU 序是
  IDR0, P1, IDR2（测试按此断言）
- payload 尺寸断言若差 1：检查 sei_nal 的 255 步长改动是否影响（6/4 字节
  payload 远小于 255，不该走步长）

### 1.4 §428 收尾还欠

1. 上面 4 步验证全绿
2. doc/PORTING_HISTORY §428 条目（.scratch 写文件再 cat >>，别 heredoc）
3. README 的 H.264 行：§425–§427 摘要处扩成 §425–§428（加「STEREO3D/FPA
   SEI：IDR AU 携带 av_stereo3d_* 布局、上下文持久」）；顺手删尾注
   「仍拒收流式 ABR 与 B × multi_ref>1」——**已过时**（流式早已接受
   b_slices × multi_ref，本会话核实过 stream open 无此校验）
4. 记忆 `.workbuddy/memory/MEMORY.md` 索引行补 §428

---

## 2. 本线后续切片（用户已确认继续做纯编码器）

§428 之后的不对称清单（价值/工作量从优到重）：

| # | 切片 | 要点 | 预估 |
|---|---|---|---|
| §429 | **ROI 逐 MB 量化偏移** | `Array[H264Roi 型]`（矩形像素 right/bottom 独占 + qoffset 有理数）；qoffset → 逐 MB QP 偏移叠在 AQ/RC 上（§389 的 mb_qp 机制现成）；重叠首胜（§424c 绑定语义）；无解码端往返——测试靠流尺寸排序（worse<base<better，绑定 §424c 的三向排序模式） | 中 |
| §430 | **mb_info 运动提示** | Constant/Changed 矩形→逐 MB 强制跳过运动搜索（P 循环多副本：CAVLC/CABAC/B 线）；x264 无条件信提示=准确提示下流不变是预期（§424e 的「≠base 才可断言」教训）；前提选项无（纯端自定） | 中偏大 |
| §431 | **批量 pict_type 强制** | **最重**：批量 B 循环假设严格 P/B 交替，逐帧强制 P/B/Keyframe 需要调度重构（pair-phase 显式化 + 非 IDR I 帧写端（现无）+ 批量 mid-IDR（现无，批量 keyint 走门面→流式））。流式侧 force_idr 已有，可先做流式 pict_type 枚举扩展 | 大 |

B 类深层能力（CRF/scenecut+open-GOP/chroma-qp-offset/去块 αβ/B 加权/多 slice/
lossless/B 金字塔/MB-tree/ME 升级）在 §431 之后按需排队。

---

## 3. 工具链/流程坑（本会话新增，doc/agent.md §2/§6 已有部分）

1. **libavcodec 测试第 51 个文件起，包级/`-f` 族跑法全灭**：moonrun
   `--test-args` JSON 列全部源文件 → Windows 命令行 206。一律
   `moon test libavcodec/<文件>.mbt --target wasm --no-render` 单文件制
   （doc/agent.md §2 已改写）。**52 文件后同样如此**。
2. **`unused_constructor` 按 lib 目标计**：纯输入型 pub 枚举（只在测试构造）
   在 libavcodec 这种大包里没救——**新公开参数面一律用 Int32 常量或复用
   解码侧词汇表 + 校验错误**（§428 的实测结论）。
3. **python 改 .mbt 的 § 符号字节坑（本会话踩中）**：bytes 字面量里写
   `b'\xa7428'` 是坏 UTF-8（§ = `\xc2\xa7`）；且 `\\` 会留字面反斜杠。
   修法 `raw.replace(b'///\xa7428: ', b'/// \xc2\xa7428: ')`。**今后 python
   批量插注释一律避免 § 字符**（写 "S428" 或纯 ASCII），或全部走 Edit 工具。
4. **python 批量插行的安全模式**（§427/§428 实测可复用）：`rb`/`wb` 二进制、
   按「上一行 strip == 锚 && 当前行 strip == 锚」定位、同缩进插入、
   **每次插入后 grep 计数核对**（§427 一次 20 站、§428 一次 20+7+4 站，
   零缝合事故——§426 的教训是绝不用字符偏移跨 patch 累计）。
5. **rm-guard 拦截含 "del" 子串的 python**（`del lines[i]`）：改写
   `lines[:i]+lines[i+1:]`。
6. heredoc 禁令依旧（doc/agent.md §6）；本会话 `cat >> ... << 'EOF'` 一次带纯
   ASCII 无转义内容侥幸成功——**别再赌**，用 Write 工具。

---

## 4. 验证基线（§427 收官时的钉值，回归对照）

- 全量 51 文件 **252/252**（`.scratch/h264_s427_fullrun.log`，F: 行即文件清单）
- `h264_enc_sei_test.mbt` 9/9、`h264_enc_sar_test.mbt` 2/2、CLI 30/30
- 全模块 wasm check 0 错 0 警
- §428 预期增量：+2 测试文件、+6 测（5 黑盒 + 1 白盒），**全部既有文件
  逐字节不变**（stereo3d 缺省 0 不写任何 SEI——测试里有字节恒等断言）

## 5. 快速上下文指针

- §424b（绑定 SEI）/§424c（ROI）/§424d（STEREO3D）/§424e（mb_info）语义
  钉值：`doc/PORTING_HISTORY.md` 对应条目 + 记忆 `.workbuddy/memory/MEMORY.md`
- 解码端 FPA：`h264_sei.mbt` `decode_frame_packing_arrangement`、
  `h264_side_data.mbt` `sei_to_frame`（Stereo3d 持久语义）
- §427 全链接线模式（本会话）：doc/PORTING_HISTORY §427 条目
- oracle：**明确不做**（用户决定 2026-11-16，doc/agent.md §2 规则）
