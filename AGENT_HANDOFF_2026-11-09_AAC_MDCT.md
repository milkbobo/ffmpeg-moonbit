# AGENT_HANDOFF_2026-11-09 — AAC av_tx f32 MDCT 移植完成、帧 2 分叉新根因（§370）

> 上下文：FFmpeg 9.0.2 → MoonBit 纯算法迁移。AAC 感知编码器与 ffref 进程内
> C 预言机（nine-dbg 镜像，`libavcodec_dbg.a` 含探针）逐字段对拍。本片
> （§370）把 `av_tx` AV_TX_FLOAT_MDCT 的精确运算序**完整移植**并接入编码器：
> **帧 0（长窗）与帧 1（八短窗）的 frame_bits/λ/搜索/写位已与 C 逐位一致**；
> 帧 2 起出现**新根因**（psy 阈值差 2%~18%，已收窄指向窗序列/窗型），
> 详见下文。工作树**未提交**，含临时探针。

## 一、本片已完成（工作树，未提交）

### 1. av_tx FLOAT MDCT 子包 `libavcodec/aac_mdct_tx/`

- `aac_mdct_tx.mbt`：`ff_tx_mdct_fwd` 全链路——折叠/预旋转（preshuffle
  scatter map）/split-radix FFT（`ff_tx_fft*_ns`：fft4/8/16 手写特化，
  32..512 按 `DECL_SR_CODELET(n,n2,n4)` 递归 + `ff_tx_sr_combine`）/
  后旋转，全部 f32（`mtx_f32/add/sub/mul` 本地助手）。scale 32768 折进
  exp twiddle（`sqrt(scale)` 两处），**不再额外乘 32768**。
- 表运行时生成（C 公式逐条对齐：`sinf((i+0.5)*(M_PI/(2n)))` 的 f32
  角、cos 表 double cos→f32、exp `M_PI_2*(i+1/8)/len4`→×sqrt(32768)→f32、
  map 用 `split_radix_permutation` 的 SCATTER 排列）。
- **17 个 sine 窗值与 glibc `sinf` 差 1 ulp**（glibc sinf 非正确舍入）→
  `aac_mdct_tx_ref_checks.mbt` 里随附 `aac_mdct_tx_sine1024_fix`（14 项）
  与 `aac_mdct_tx_sine128_fix`（3 项），(index, f32-bits) 补丁。cos/exp/map
  全部与 glibc 位同（变换测试通过佐证）。
- `aac_mdct_tx_wbtest.mbt`：3 个测试——19 组表的 (sum,xor) f32 位校验 +
  长短两个变换输出校验，全部通过（输入用 dumper 同款 LCG：`s=s*1664525+
  1013904223`，`x=f32((s>>8&0xFFFF)/32768-1)`）。
- `scripts/aac_mdct_tx_dump.c`：在 nine-ref 镜像里编译运行，输出校验/修正
  文件（**不要提交生成前的大数组版本**——见坑 1）。

### 2. 编码器接入（`libavcodec/aac_encode.mbt`）

- `AacEncoder` 新增 `mdct_tx : @aac_mdct_tx.AacMdctTx`；**删除** 2M 项
  `cos_table`（16MB/实例）与 `aac_encode_cos_table`/`short_window`/
  `aac_encode_short_window`。
- `aac_encode_window(seq, buf, win, swin)`：窗值改用 f32 `ff_sine_*` 表，
  **所有窗乘积 f32 舍入**（`aac_two_mul`），反向半窗用 `win[1023-i]`/
  `swin[127-i]`（`vector_fmul_reverse` 语义）。
- `frame_coefficients`：八短窗每块 256 样本 = `f32(buf*swin[j])` +
  `f32(buf[128+j]*swin[127-j])` → `aac_mdct_tx_128`；长窗走
  `aac_encode_window` → `aac_mdct_tx_1024`。

### 3. 与 C 的对拍实证（run370a/c，nine-dbg）

- 帧 0：bits **3281=3281**；帧 1（八短窗）：bits **3711=3711**（MDCT ε
  根因消除，短窗带 sf±1 消失）。
- λ 链：λ₁=117.0689926147461、λ₂=110.74684143066406 与 C 完全一致。
- TWOPARM（dest/many/few/cutoff/rdlambda/zeroscale）帧 0..2 全部 SAME。
- **帧 2 分叉（新根因）**：C frame_bits=2538 vs port 2650；ch0 gg C=155 vs
  P=150。TWOSEARCHP `alloc` 一致（792），但 **TWOINITP 的 uplim/ener
  相对差 2%~18%**（g0 ch0：uplim rel 1.8e-1、ener 1.8e-1；ch1 ~1e-1）——
  比 §369 的 3e-5 大三个数量级，**不是舍入噪声**。nwin/maxsfb 两侧一致
  （CHC/CHWRITEP 均 nwin=1、maxsfb=43），但 gg 差 5 步。
- 判读：帧 2 是八短窗之后的过渡长窗（LONG_STOP 或 ONLY_LONG，两者
  nwin 都是 1，CHC 探针不打印 window_sequence）。**首要怀疑：port 的
  窗序列决策/窗型与 C 不同**（不同窗型会让窗后样本能量差 O(10%)）。
  次怀疑：LAME 状态链在短窗帧后分歧（但 §349 已移植 LAME 机并逐帧
  对齐过）。

## 二、下一步（按序）

1. **确认帧 2 的 window_sequence**：在 `assemble_frame` 临时打印
   `chans[ch].window_sequence`（或 bitstream 的 ics_info 2 位字段）；
   C 侧可在 `aac_ref_patch.py` 的 CHC 探针里加 `wi/ics.window_sequence`，
   重建 nine-dbg 镜像（`docker build -f .scratch/ffref/Dockerfile.dbg ...`）。
   若序列不同 → 查 `aac_encode_frame` 到 LAME 决策的映射（发射时序
   §349 的「分析 buf_i / 发射 buf_{i-1}」下，序列数组是否取错帧）。
2. 若序列相同 → 在 C `apply_window_and_mdct` 后加窗后样本探针
   （前 8 个 + 能量），与 port `aac_encode_window` 输出对比，确认窗内容；
   再比 MDCT 输出（C 侧 dump `sce->coeffs`）。
3. 修好后重跑 run370 探针对拍，期望 13 帧 frame_bits 全等 → 届时把
   ffref 测试从「包数断言」升级为**逐字节断言**（`ffref_expect_ref_packets`），
   并去掉测试里的 ADTS 头差异说明（port ADTS vs C raw，需各自去头比较）。

## 三、工作树现状与提交前清理清单

**临时探针（grep "§370 probe" 可复核）**：
- `libavcodec/aac_encode.mbt`：`FRAMEP`（encode_pipeline assemble 后）、
  `TWOSEARCHP`（twoloop 调用前）、`CHWRITEP`（assemble_frame 立体声循环）。
- `libavcodec/aac_twoloop.mbt`：`TWOPARMP`（clamp 后）、`TWOINITP`（首 8 带）、
  `TWOEXITP`（退出阶梯循环）。
- `ffref/moon.pkg`：`libavcodec_dbg.a` → 提交前必须还原 `libavcodec_ref.a`。

**新增（保留提交）**：`libavcodec/aac_mdct_tx/{aac_mdct_tx.mbt,
aac_mdct_tx_ref_checks.mbt, aac_mdct_tx_wbtest.mbt, moon.pkg}`、
`scripts/aac_mdct_tx_dump.c`；`libavcodec/moon.pkg` 新增子包 import。

**验证口径**：本机 wasm **1712/1712**（含 3 个新测试）；`moon check` 0 err；
docker nine-dbg 立体声差分 exit=0。**未做**：nine-ref 全量 72、mono 差分、
§368 质量门复测（MDCT 变化后 SNR/NMR 需重测一次）。

**提交约定**：精确路径 add；中文 feat:；尾行 `Co-Authored-By: ZCode
<zcode@zcode.ai>`；同步 PORTING_HISTORY（§370 条目）、agent.md、
记忆与 MEMORY.md 索引。

## 四、方法论坑（本片新踩，必读）

1. **wasm 初始化函数局部变量上限（V8 "local count too large"）**：
   `libavcodec` 的白箱测试 wasm 的 `__moonbit__init` 已贴近 50k locals，
   任何大的顶层字面量（几千个标量、24KB 的 `b"..."` 字节串内联物化）
   都会超限；`#inline(never)`/builder 函数都救不了。**解法 = 数据不进
   顶层：运行时按公式生成 + 校验和固定**（本片做法），或放进独立子包
   （init 分开，仍建议避免顶层大表）。
2. **MoonBit 语法**：`Bytes` 字面量/数组大表都会压 init；`0x..U` 是 UInt
   后缀（小写 `u` 解析失败）；`Float::reinterpret_from_uint` /
   `UInt32::reinterpret_as_int` 是位转 API；`f64` 后缀不存在
   （`32768.0.sqrt()` 直接可用）；white-box 测试文件名必须是 `*_wbtest.mbt`
   （`*_test.mbt` 看不到私有符号）。
3. **子包测试二分法**：`moon test -p libavcodec` 报 wasm 编译错时，把新
   文件移出再跑即可确认是否新代码触顶（本片据此定位）。
4. **glibc `sinf` 非正确舍入**：1024 点窗 14 个值、128 点窗 3 个值与
   `(float)sin(double)` 差 1 ulp；`cos`/`sin` double 与 MoonBit `@math`
   在本项目全部输入上位同（cos 表 261 值 + exp 1024×2 值校验全过）。
5. **探针配对**：C stderr 与 port stdout 缓冲不同步；TWOSEARCHP/TWOPARMP/
   TWOINITP/TWOEXITP 按调用序分组、CHC/CHWRITEP 按 k 序配对；
   `parse369.py` 可直接跑 run370 日志（同格式）。
6. **dumper 必须跑在 oracle 镜像**（nine-ref/nine-dbg 同 glibc/同
   libavutil）：`gcc ... /usr/local-ref/libavcodec_ref.a -lavutil -lm`；
   生成文件头注释记录命令；`/refbuild/ffmpeg` 已删，sinewin.h 不导出——
   extern 声明 `ff_sine_1024/ff_sine_128/ff_init_ff_sine_windows` 即可。
