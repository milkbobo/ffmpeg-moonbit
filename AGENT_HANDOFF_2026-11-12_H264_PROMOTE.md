# AGENT_HANDOFF_2026-11-12 — H.264 §403 组合正确性收口 + x264 帧级 C 仲裁探针

> **状态：已交付。** 用户指令：使用 moonbit 全部 skills，**必须用
> `moonbit-c-binding` 和 `make-moonbit-c-bindings`**，继续迁移「编码：H264」。
>
> 接手时 HEAD = `280363e`（§402），工作树是一片**未完成的 §403 WIP**：
> 六个 B 线 opt-in 默认已翻成 `true`、CLI 加了 `--no-*` 反开关、
> `h264_encode_b.mbt` 里一处 transform_8x8 清位修复「已改未验证」，
> 探针矩阵仍有 3 类解码错误，大量钉值待重钉。
>
> **本轮把 §403 重新界定为「先修正确性、再谈转正」**，并明确把转正
> 延后到独立一片。原 WIP 交接内容已由本文替代。

---

## 一、这一片做了什么

| 阶段 | 内容 |
| --- | --- |
| 1. 复核 WIP | `moon check` 干净；跑 `h264_promote_probe_test.mbt` 得到 28 组合基线，其中 6 个失败，确认清位修复**没有**解决 CABAC 组合 |
| 2. 定位根因 | 两路只读调查逐 bin 比对编码端 B slice 与解码端语法层，交叉印证「I_NxN 漏写 `transform_size_8x8_flag`」+「CABAC mirror 邻居位生命周期不对齐」 |
| 3. 修 4 处 | `h264_encode_b.mbt` 的 CAVLC I4 / CABAC I4 / CABAC I8 / CABAC inter tail，全部 `dct8x8` 门控，默认路径零字节变化；28/28 组合转 ok |
| 4. **回退转正** | 4 个文件的默认值翻转 `git checkout --` 回 §402；理由见 §二 |
| 5. C 绑定技能落地 | 新增 `x264probe_frames` 帧级仲裁探针（C stub → 私有 extern → 安全封装 → wbtest → 定向 ASan） |
| 6. 收口 | 临时探针按铁律 `mv` 进 `.trash/2026-11-12/`，正式回归测试、文档、验证矩阵 |

**纯 MoonBit 编码本体没有用 C FFI**：C 绑定只用在 x264 对拍 oracle 侧，
§376 起一贯如此。

---

## 二、为什么没有把六个 opt-in 转正

这是本轮最重要的判断，续做前请先看：

1. 转正会推翻 §376–§402 全部 **54 个测试文件**的码流钉值（md5 / hex /
   inspect），交接文档 §403 WIP 自己列了 ~10 个文件需重钉，每条都要
   docker ffmpeg 仲裁；
2. 「默认路径逐字节不变」是本项目 opt-in 契约的核心，转正与正确性修复
   夹带交付，一旦中途失败很难二分责任；
3. WIP 转正时默认路径**本身就是坏的**（全开组合解码失败），先修 bug
   是唯一合理顺序；修完后再决定是否单独做转正片更稳。

因此 `h264_encode_p.mbt` / `h264_enc_cabac.mbt` / `h264_enc_stream.mbt` /
`cmd/encode-h264/options.mbt` 已恢复到 HEAD，WIP diff 完整备份在
`.scratch/promote_wip.diff`（含 CLI `--no-*` 反开关、单帧自动降级、
`cabac_rd && !cabac` 静默 no-op、删除过时的「b-slices excludes rate
controls」CLI 校验）。**转正时可直接从该 diff 接着做**，但务必先完成
全部钉值重钉与 PSNR/字节门。

`h264_enc_combo_test.mbt` 新增了「默认流 == 显式全关流」的字节断言，
转正时这个测试会第一时间提醒你契约变了。

---

## 三、位级根因与修复（续做前必读）

解码端在 PPS `transform_8x8_mode != 0` 时对 **I_NxN 无条件读 1 bit**：

- CAVLC：`h264_decode.mbt:674`
  `info.transform_8x8 = pps.transform_8x8_mode != 0 && gb.read1() != 0U`
- CABAC：`h264_cabac_mb.mbt:997-1005`
  `get_cabac(399 + h264_neighbor_transform_size(...))`

B slice 的 I4x4 写入层沿用 §397 的旧注释「the B slices' PPS keeps
8x8DCT off」，只写 `put_ue(23)` 就进 16 个 pred mode。**I / P 帧的同一
分支早已修好**（`h264_encode.mbt:1187`、`h264_encode_p.mbt:3054`、
`h264_enc_cabac.mbt:2189`），B 帧漏跟；I8x8 分支（§400）写了 `1`，
inter 分支写了 `0`，唯独 I4x4 没写。

| # | 位置（`libavcodec/h264_encode_b.mbt`） | 修复 |
| --- | --- | --- |
| 1 | `write_b_mb_i4_syntax` | `if self.dct8x8 { r.put_bit(0) }`；显式 `info.transform_8x8 = false`；改正过时注释 |
| 2 | `write_b_mb_i4_syntax_cabac` | `if self.dct8x8 { enc.decision(399 + neighbor, 0) }`；显式清 mirror 位 |
| 3 | `write_b_mb_i8_syntax_cabac` | 删掉 ctx-399 推导**之前**的 `info.transform_8x8 = true`，移到写 flag 之后；flag bin 加 `if self.dct8x8` 门控 |
| 4 | `write_b_residual_tail_cabac` | inter MB 写 `flag=0` 后回写 `info.transform_8x8 = false` |

症状对照：

- CAVLC 少 1 bit → 解码端把 I4x4 按 I8x8 解读（16↔4 pred mode、
  16×4x4↔4×8x8 残差、nC 粒度错位）→ `invalid coeff_token`、
  `intra prediction mode needs unavailable left samples`；
- CABAC 少一个 bin 或 ctx 399/400 分歧 → `low/range` 与 `states[]`
  从该 bin 起分叉 → `missing end_of_slice_flag`、
  `H.264 CABAC bytestream overread`；
- `b+dct8x8` 在 n=2（I+P）ok、n=3（首现 B slice）挂，与「B slice 的
  8x8DCT 邻居计数第一次非 0」吻合。

**未做的一项**（写进剩余）：CABAC B inter 的 `dct8x8_allowed` 目前硬编码
`true` / 只查 `parts.all`，未镜像解码端 `h264_b_mb.mbt:495-497` 的
`(direct_8x8 || !direct.any())`。当前 SPS 恒 `direct_8x8=1`，不触发。

---

## 四、C 绑定技能落地（用户指定，重点）

### `moonbit-c-binding` 四阶段

| 阶段 | 动作 |
| --- | --- |
| 1 Project Setup | 复核 `libavcodec/x264/moon.pkg`：`native-stub: ["libx264_stub.c"]`、`targets` 门控 `ffi.mbt`/`x264.mbt`/`x264_wbtest.mbt` 为 native、`link.native` 链；未动 `supported_targets` |
| 2 FFI Layer | 新 extern `x264probe_frames_ffi` 私有，非原始参数全 `#borrow(stream)`；C 侧只在调用期把流拷进 parser，返回扁平 LE `Bytes`，无新所有权问题 |
| 3 MoonBit API | `X264FrameInfo` / `X264FrameProbe` 领域类型（无裸指针）；`x264_probe_frames` 做长度下限、`fields == 8`、`blob.length() == 32 + 32*n_frames` 精确形状校验；NULL → `Err` |
| 4 Testing | native 38/38 + 定向 ASan（官方 `run-asan.py` 不适配，沿用 §391 的 mock 运行时符号方案） |

### `make-moonbit-c-bindings` 五步

Survey 上游头 → **直接查镜像里的
`/usr/local/include/libavutil/frame.h`**（`moonbit-orientation` 的
freshness gate）：FFmpeg n9.0.2 **没有** `AVFrame.key_frame` /
`coded_picture_number` / `display_picture_number`。第一版按旧 API 写直接
编译失败，改走 `pict_type` / `AV_FRAME_FLAG_KEY` / `flags` /
`decode_error_flags` / `pts` 后通过。→ Design 只暴露领域类型 →
Vendor/Link 沿用镜像内 FFmpeg 静态库 → FFI 边界由 C 侧做 ABI 归一
（`Moonbit_array_length`、`moonbit_make_bytes`、`INT32_MAX` 上限、
`av_log` 回调装/卸）→ Validate 跑 check / native test / ASan / info。

### 新 C 入口 `x264probe_frames`

blob：`[8-word header][n_frames × 8 int32]`

```
header: n_frames, warnings, errors, width, height, pix_fmt, 8, 0
record: pict_type, key_flag, flags, decode_error_flags,
        pts_lo, pts_hi, digest_lo, digest_hi
```

digest 是可见区域平面（Y → chroma，逐行，LE 样本）的 64-bit FNV-1a，
用于不跨边界搬 YUV 地比较不同配置的解码输出。`av_log` 回调是进程全局的，
**两个 probe 不可并发**（`ffi.mbt` 注释已写明）。

价值：`x264_probe_annexb`（§391）看 NAL/AU，本探针看**图像类型、显示序、
像素摘要与诊断**，补上 §401 遗留的 C 侧复核，并给本轮修好的 B 线全开流
提供独立解码器仲裁。

---

## 五、验证矩阵

| 门 | 结果 |
| --- | --- |
| 修复前 / 后 28 组合探针 | 6 个失败 → **28/28 ok** |
| 正式黑盒 `libavcodec/h264_enc_combo_test.mbt` | **4/4** |
| H.264 编码全系 17 文件（wasm，按文件串行） | 15 个全绿；2 个白盒文件命中本机 wasm `local count too large`（既有上限），改 `--target wasm-gc` 各 **3/3** |
| `moon check --target wasm --deny-warn --no-render`、`moon info --target wasm` | **EXIT=0** |
| docker `moon test --target native -p .../libavcodec/x264`（C 桩重编） | **38/38**（原 34 + 新 4） |
| 定向 ASan（真 libx264 `-bf 2` 的 5 帧 B 流 + 短 blob） | **EXIT=0**，两轮 `n=5 warn=0 err=0 fields=8 len=192`，无越界 / UAF / 泄漏 |
| docker `moon check --target native` / `moon info --target native` | 见 §七收口 |

日志在 `.scratch/`：`promote_probe.log`（修复前）、`promote_probe2.log`
（修复后）、`h264_regress.log`、`combo_test.log`、`x264_native2.log`、
`asan_frames.log`、`final_*.log`。

ASan 日志开头的 `missing picture in access unit with size 4` /
`No start code is found.` 是 harness **故意喂的 4 字节短 blob**，不是缺陷。

---

## 六、复现命令

```sh
# 宿主（moon 命令必须串行，并发会抢 _build/.moon-lock 死锁）
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_combo_test.mbt --no-render
moon test --target wasm-gc libavcodec/h264_enc_quant_wbtest.mbt --no-render
moon test --target wasm-gc libavcodec/h264_enc_hrd_wbtest.mbt --no-render
moon info --target wasm

# 镜像：native C 桩 + 帧级探针
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native \
     -p milkbobo/ffmpeg-moonbit/libavcodec/x264 \
     --target-dir /tmp/mbuild"

# 镜像：定向 ASan（含 x264probe_frames）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -hide_banner -loglevel error -y -f lavfi \
     -i testsrc2=size=96x64:rate=30 -frames:v 5 -c:v libx264 -bf 2 \
     -pix_fmt yuv420p -f h264 .scratch/asan_bframes.264 && \
   cc -fsanitize=address -g -O1 -I/root/.moon/include \
     -I/usr/local/include libavcodec/x264/libx264_stub.c \
     libavcodec/x264/asan_probe_harness.c -L/usr/local/lib -lavcodec \
     -lswresample -lavutil -lx264 -lz -ldav1d -llzma -lshine \
     -lpthread -lm -o /tmp/asan_probe2 && \
   ASAN_OPTIONS=detect_leaks=1:fast_unwind_on_malloc=0 \
     /tmp/asan_probe2 .scratch/asan_bframes.264"
```

---

## 七、交付文件与收口

| 文件 | 内容 |
| --- | --- |
| `libavcodec/h264_encode_b.mbt` | 4 处 `transform_size_8x8_flag` 修复 + 注释 |
| `libavcodec/h264_enc_combo_test.mbt` | **新增**正式黑盒回归（4 测 / 14 组合 / 默认契约断言） |
| `libavcodec/x264/libx264_stub.c` | **新增** `x264probe_frames` + `probe_frame_fnv` / `probe_push_frame`；补 `common.h` / `pixdesc.h` |
| `libavcodec/x264/ffi.mbt` | **新增**私有 extern `x264probe_frames_ffi`（`#borrow`） |
| `libavcodec/x264/x264.mbt` | **新增** `X264FrameInfo` / `X264FrameProbe` / `x264_probe_frames` |
| `libavcodec/x264/x264_wbtest.mbt` | **新增** 4 个帧级仲裁用例 |
| `libavcodec/x264/asan_probe_harness.c` | 扩展覆盖新入口（两轮 + 短 blob + 形状校验） |
| `PORTING_HISTORY.md` / `README.md` / 本文档 | §403 节、H.264 行、交接 |
| `cmd/encode-h264/options.mbt`、`h264_encode_p.mbt`、`h264_enc_cabac.mbt`、`h264_enc_stream.mbt` | **已回退到 §402 HEAD**（WIP 转正），diff 备份 `.scratch/promote_wip.diff` |
| `libavcodec/h264_promote_probe_test.mbt` | 临时探针，按铁律 `mv` 进 `.trash/2026-11-12/libavcodec/` |

**环境坑（沿用）**：宿主 `moon` 并发抢锁会死锁，必须串行；全仓
`moon test --target wasm` 在本机 `moonrun` 会挂，按文件 / 按包口径跑；
libavcodec 白盒 wasm 已贴 `local count too large` 上限，别再加
`_wbtest.mbt` 大文件；`--target js` 有历史遗留的 `v128` unused_package
告警，别宣称 `--target all` 通过；`moon fmt` 会选整包，单文件用
`moonfmt <file> -w`。

---


## 九、§405 预演补充（2026-11-12 晚）

六开关默认翻转曾完整落地并普查：暴露两个**既有**真 bug（显式旗标即可
在 100addf 复现）。已修其一、其二未修，转正再次回退（WIP 仍在
`.scratch/promote_wip.diff`，重放须带上本轮 encode_b 修复）。

### 已修：CABAC `b_slices+b_parts+dct8x8` B slice 失步

- 复现：bi8 夹具（偏 intra）`b_slices+b_parts+dct8x8` CABAC——
  梯度夹具踩不到；`end_of_slice_flag`/`bytestream overread`，
  真 ffmpeg 同样拒收。
- 根因：decide 阶段候选试价（干跑写出 + 率失真计价）在**落选 inter
  MB** 的 mirror info 留下 intra 试验状态（`chroma_mode` /
  `transform_8x8`）。§403 的 MB 入口清位在试价**之前**，污染窗口仍在。
- 修复：`encode_b_frame_cabac` 真实写出前再清两字段（写出器权威）。
  回归：`h264 enc combo: parts+dct8x8 cabac on the bi8 fixture`。

### 未修：CABAC `b_parts+intra4x4_in_b+dct8x8` 编码器重建错

- 复现：`h264b_fixture(96,64,6)` qp24 CABAC
  `b_slices+b_parts+intra4x4_in_b+dct8x8`（cabac_rd 无关）；
  B3 的 MB(2,1)：左半 8 列 × 上 12 行像素错（blocks by0..2 × bx0..1）。
- 仲裁：本仓解码器 == 真 ffmpeg（像素 142 vs 147，去块差异），
  编码器重建（220）是异类 → **写出的系数 ≠ 编码器重建所用系数**，
  错在编码器侧 decide/写出系数路径，不在语法层。
- 已排除：bin 级 (ctx,bit) 全对拍 B1/B3 通过前的失步（B1 完全对齐；
  B3 分歧是本 bug 的下游表象）；I4 写出器的 transform flag/残差读取
  貌似正确；单开关与两两组合全部通过，仅三元组合触发。
- 下一步建议：在 `code_b_mb_residuals` 与
  `write_b_mb_i4_syntax_cabac` 之间对拍 BI4 计划的 `luma_store` 逐块
  系数；怀疑 b_parts 开启后某计划分支的 coded store 与重建用的系数
  来源不一致；或 MC/帧内预测输入在 decide 内用了源样本而非重建样本。

### 方法论沉淀（bin 级对拍增强版）

- bypass 与 bypass_sign（独立函数）都要打点，否则假分歧；
- ctx 序列一致 ≠ 值一致，须 (ctx,bit) 全量；
- 编码器 bin 数偏多时先怀疑干跑计价混入——用包级门控标志只采
  真实写出段；
- 对拍前先核对标记行号（每轮 trace 行号会漂移）。

## 八、剩余 / 下一片候选

1. **六个 opt-in 转正**（独立一片）：从 `.scratch/promote_wip.diff`
   接着做，前提是重钉全部码流/md5 与 PSNR/字节门；`bi8` 用例需显式
   `intra4x4_in_b=false`，`h264_enc_rc_test` 受 `dct8x8`/`cabac_rd`
   影响最大。
2. ~~`H264EncStats` B-intra 专用计数~~ —— **§404 已完成**（544cd75）：
   `bi16_mbs` / `bi4_mbs` / `bi8_mbs` 上线，bintra/bi8 断言已切新口径。
3. ~~B 尾 `dct8x8_allowed` 完整镜像~~ —— **§404 已完成**（四个残尾
   调用点补 direct 分量；当前 SPS 恒 direct_8x8=1，流不变，防御性对齐）。
4. ~~删 CLI 过时「b-slices excludes rate controls」~~ —— **§404 已完成**
   （`--stream`×码控互斥保留）。
5. 编码器接统一播放门面 / 更多 profile 与位深。

§404 验证：wasm 按族 91 项 + CLI 16/16 全绿；docker native 65/65、
x264 帧级仲裁 38/38；`moon check --deny-warn` 干净；`.mbti` 仅
`H264EncStats` 三个新字段。宿主白盒 wasm `local count too large` 为
100addf 起既有（白盒走 docker native）。

## 十、§406 转正落地（2026-11-13，commit c5d7961）

第九节的重建 bug 已修：落选 inter MB 的 mirror `intra4x4` 标志残留
（第三个同类污染字段）——真实写出前再清
`chroma_mode`/`transform_8x8`/`intra4x4`，回归
`h264 enc b: all-on cabac keeps the recon invariant`。随后六开关
默认转正最终落地（细节见 PORTING_HISTORY §406）：三入口默认 true、
降级语义（单帧/无 CABAC/无 b_slices 子旗标）、B SPS 补 VBV/HRD
（B×VBV 既有缺口）、CLI `--no-*` 反开关、测试全量重钉
（显示序映射 / 30+ md5 / 语义负例转降级正例 / AUD 0x50 / 流式补
finish()）。wasm 70 + CLI 16 全绿。

**待办（Docker 恢复后）**：native 全套（含 h264_enc_hrd_wbtest 白盒）、
x264 帧级仲裁 38 项、ffref、以及本仓重钉 md5 的 ffmpeg 逐钉复核
（ARB22/ARBCABAC/ARBBPARTS/ARBBRC 等 dump 路由已在测试内保留）。
`.scratch/promote_wip.diff` 已被本提交超越，可删。

## 十一、407 补验发现的两个未修 bug（下一片主菜）

### Bug A：CABAC×AQ recon 不对称（containment 中）

- 复现：`h264 aq: CABAC macroblock QP deltas`（64x48 h264_aq_fixture(4)，
  qp26，aq=true，CABAC，默认旗标或仅 dct8x8=false+ABR）——
  `h264_rc_recon_invariant` 报 "P frame 1/2: encoder reconstruction !=
  decoder"。
- 事实矩阵：CAVLC 同夹具绿；b_slices=false+aq+CABAC 绿（legacy）；
  dct8x8=true 或 target_bytes/ABR任一 + AQ + CABAC 即挂（决策矩阵探针
  已验证）。
- 现象：编码器 recon ≠ 本仓解码器（差 1~2），ffmpeg 解码无错（流合
  法）；首失配 MB 常为 cbp=0 的宏块，解码端 info.mv 为 -64 填充（不
  可用标记）→ 解码器把该 MB 解成 **P 切片内 I_NxN（cbp=0）**，编码器
  侧 plan/写出与重建的 MV/模式记账不对称——405 bi4 的 mirror 污染
  同族，但污染源不止 intra4x4 一个字段（dct8x8/ABR 路径各有一条）。
- 下一步：405 方法论（(ctx,bit) 全量 + bypass_sign + 门控），对
  `write_cabac_mb_syntax` 的 I4/I16 分支与解码端
  `h264_decode_mb_cabac_intra` 的模式回放逐 bin 对拍；重点查
  `eval_cabac_bits` 试价回滚漏掉的 mirror 字段与 h264_enc_cabac.mbt
  主循环 AQ 的 `ctx.qscale` 记账。

### Bug B：i4p「independent」夹具失效（结构性覆盖）

`intra4x4_in_p is independent of intra_in_p` 在现决策下 I4 全输
（i4p=0），独立性只剩结构性覆盖；CABAC 计价默认开后与 CAVLC 干跑
分歧按熵钉值（i4p 8 vs 6、2547 vs 2624、pins 拆 pins1/pins2）。专片
重调夹具恢复区分度。
