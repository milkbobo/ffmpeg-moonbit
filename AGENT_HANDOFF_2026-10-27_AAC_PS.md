# AI 交接：AAC PS（参数化立体声 / HE-AACv2）端口 —— 只剩 DSP 对拍收敛

## 2026-10-27 后续进展

- 修正同网格参数不应重映射、混合矩阵插值步长括号、右声道高频综合误读左缓冲、IPD/OPD 实部混合符号。
- 两条完整流端到端 PCM：48 kHz 51 帧、44.1 kHz 47 帧，均最大差 1；PS 测试 13/13。生成器使用 60000 字符的 base64 分块以避开 wasm 局部变量和文本列限制。
- 新增网格、双声道综合与 IPD/OPD 混合内核回归。真实流仍仅覆盖 20 频带，34 频带、IPD/OPD、HB、多包络组合仍需按下文建立独立 C harness 对拍；不要把这些路径视为已验证。
- `moon check --target wasm --no-render` 无警告，`moon info --target wasm` 成功，全量 wasm 测试 1043/1043。Docker Desktop 已启动，`vpxdev-img:latest` 可用；Windows 有 gcc，WSL Ubuntu 中未找到 gcc/make。
- 尚未提交。`hevc_inter_decode.mbt` 和 `agent.md` 是既有改动，保留原状。

任务：把 FFmpeg 9.0.2 的 Parametric Stereo（`aacps_common.c` 语法 + `aacps.c` 合成 +
`aacpsdsp_template.c` 内核 + `aacps_tablegen.h` 表）移植到纯 MoonBit，接进已完成的
SBR 管线。**语法层已完成并位级对齐**；**DSP 层已全部写完但有转录错误，端到端 PCM
未收敛**。本文件给出精确断点、验证基建与定位方法。

## 当前状态（精确断点）

- `moon check --target wasm --no-render`：**0 error / 0 warning**。
- `moon test libavcodec --filter "*PS*"`：**9/10 绿**。唯一红的是
  `aac_ps_pcm_wbtest.mbt` 的端到端 PCM：`48_32k: frames=12 samples=24576
  max_diff=47765 exact=10%`（44_24k 未跑到，48 流先失败）。
- 语法测试（`aac_ps_syntax_wbtest.mbt`）**已全绿**：两组真实流全部 PS 负载
  （折叠探测重复后 48_32k 50 条 + 44_24k 46 条）逐字段位级一致，含
  iid/icc 粗细量化、df/dt、frame_class、假包络、边界、ipdopd 门控。
- 基线（无 PS 的旧测试）不受影响：动手前全量 1038/1038。

### 新增/修改文件

新增（均未 git add）：
- `libavcodec/aac_ps.mbt` —— `PSCommonContext` 状态 + `ff_ps_read_data` 全语义 +
  Huffman trie（`ps_unpack_f64/i32/huff` init 期解码）+ 白盒 trace 钩子。
- `libavcodec/aac_ps_dsp.mbt` —— hybrid 分析/合成、decorrelation、stereo_processing、
  `ff_ps_apply`（`AacPs` 状态、全部布局见文件头注释）。
- `libavcodec/aac_ps_tables.mbt` —— **生成文件**（base64 f64 blob + 压缩 huff blob），
  由 `scripts/extract_ps_tables.py` 从 C 转储位级转录。
- `libavcodec/aac_ps_syntax_wbtest.mbt`、`aac_ps_pcm_wbtest.mbt` —— **生成文件**，
  由 `scripts/generate_aac_ps_tests.py` 生成。
- `scripts/extract_ps_tables.py`、`scripts/generate_aac_ps_tests.py`（生成器本体）。

修改（已跟踪）：
- `libavcodec/aac_sbr.mbt`：`AacSbr` 加 `ps : AacPs` 字段；`read_extension` 的
  EXTENSION_ID_PS 分支从"跳过+报错"改为 `ps.common.read_data(gb, num_bits_left)`；
  删除了 `aac_sbr_ps_seen` 全局。
- `libavcodec/aac_sbr_dsp.mbt`：`apply` 的 ps_enabled 分支：`ps.common.start` 为真时
  调 `self.ps.apply(self.x_qmf, self.kx[1] + self.m[1])`，否则复制 X0→X1。
- `libavcodec/hevc_inter_decode.mbt`：**与本任务无关**的既有换行符差异（diff 为 0 行），提交时别带上。

## 向量与参考（`_build/ps_work/`，未入库）

- 流：`hev2_48_32k.aac`（48kHz/32kbps，51 帧）、`hev2_44_24k.aac`（44.1k/24kbps，
  46 帧），docker `linuxserver/ffmpeg:9.0.2` 的 libfdk_aac `-profile:a aac_he_v2`
  生成（`gen_vectors.sh`，注意镜像 entrypoint 是 ffmpeg，要 `--entrypoint bash`，
  Git Bash 下还要 `MSYS_NO_PATHCONV=1`）。参考 PCM 同镜像原生解码 s16le。
- **fdk 只发 20 频带、无 ipdopd**（iccm=1、偶发 iquant=1、nenv 1–2）。
  34 频带/ipdopd/HB 混合路径要用内核级定向负载覆盖（见"剩余工作"）。
- `instrument_ps.py`：对 `aacps.c`/`aacps_common.c` 副本做锚点插桩（语法状态行、
  payload 位串、`ff_ps_apply` 分级 f32 转储 LIN/LBUF/DEC/H11..H22/HOUT/ROUT、
  一次性表 hex 转储）。`build_trace.sh` 在 `vpxdev-img` 内最小化构建出
  `ffmpeg_psstrace`（源挂 `/src` = FFmpeg 树，工挂 `/work`）。
- `dumps/hev2_*_syntax.txt`、`dumps/hev2_*_payloads.txt`（位串）、
  `dumps/hev2_48_32k_bin/*.f32`（分级缓冲）、`dumps/ps_tables.txt`（表 hex）。
  44_24k 的 `_bin` 还没跑（`run_trace.sh` 里加一段即可）。

## 已解决的关键坑（别再踩）

1. **heredoc 绝对禁用**（已写进 agent.md §6）：本轮三次把 `\n`/引号/NUL 写坏文件。
   生成/改文件一律 Write/Edit 工具。
2. **wasm `__moonbit__init` 局部变量上限≈5 万**：libavcodec 白盒包已贴边。大数组
   字面量每个元素占一个局部 → 大表必须 base64 `Bytes` 字面量 + init 期解码
   （`ps_unpack_*` 即此模式）。**`av_base64_decode` 的 out_size 是截断上限，传 0 得
   空数组**，传 `1 << 20`。另外未引用的顶层表会被 DCE：只加表不接线"能编译"是假绿。
3. **`AacVlc` trie 以 `sym < 0` 判内部节点**（AAC 谱码书符号非负）。PS 的 offset
   烘焙符号有负数 → 叶子被当内部节点。解法：trie 存 +32 字节偏置值（恒非负），
   `read_iid/icc/ipdopd_data` 里 `vlc.decode(gb) - 32`。**已修**，语法全绿证明正确。
4. ffmpeg CLI 的 `find_stream_info` 探测会把**前两帧用新解码器实例再解码一遍**，
   转储里出现重复负载且 `nenvo=0`（顺序重放无法复现）。生成器
   `read_payloads()` 在前 6 条内折叠"位串与前一条完全相同"的重复并重编号 id。
   `-probesize 32 -analyzeduration 0 -c:a aac` 都压不掉，别浪费时间再试。
5. MoonBit 细节：错误标记是 `raise` 不是 `raises`；`x.to_byte()` 要写 `(x).to_byte()`
   （`0.` 会被当浮点）；`UInt64 << Int`（移位量是 Int）；含端区间 `1..=n`（不是
   `1..=<n`）；`String[i]` 是 Char（和 `'1'` 比，不是 `"1"`）；数组只改元素不加
   字段 `mut`；大 b64 用行尾 `" +` 续行（SBR 先例）。
6. docker 里删文件连命令字符串里的 `rm` 都会被 rm-guard 拦——容器本就全新，直接跑。

## 剩余工作（按序）

1. **DSP 收敛（主任务）**：在 `AacPs::apply` 里临时加分级转储钩子（参照
   `aac_ps_syntax_trace` 的全局 Ref 模式；**用 Edit 工具加**，别用 heredoc——上次
   就是这么坏的，钩子已回退干净）。跑 1–2 帧后与
   `dumps/hev2_48_32k_bin/{LIN,LBUF,DEC,H11..H22,HOUT,ROUT}_001.f32` 逐级对比
   （注意布局换算：C 的 LIN/HOUT/ROUT 是 `[2][38][64][2]` 交错复数，我们的
   `x_qmf` 是 `[ch][re/im][38][64]` 平面；C 的 LBUF/DEC 是 `[91][32][2]`，
   H 是 `[2][6][34]`，与 `AacPs` 字段同构）。Double vs f32 有 ~1e-6 相对差，
   找的是**结构性**差异（量级错/符号错/错位）。SBR 轮同类 bug 链：表负号漏、
   方向反、偏移单位错（复元素 vs 标量）、双重递增——重点自查 `hybrid_analysis`
   的滑动窗（窗口起点 win、12 点对称和）、`hybrid2_re` 的 g1_Q2（**7 个实抽头，
   不是复对**）、ileave/deint 的 base 偏移（27/7、i 从 5/3 起）、decorrelation 的
   delay 平移（46 槽行，读 +12/+0/+13）与 ap_delay 平移、stereo_interpolate 的
   **h 先加 step 再乘**、ipdopd 负号条件。语法层全绿说明参数与表是对的，
   问题只能在 `aac_ps_dsp.mbt`。
2. PCM 两条流收敛到 `max_diff ≤ 2`（SBR 轮标准；当前阈值 `ps_pcm_max_diff = 2`
   已写进生成器）后，把 48_32k/44_24k 全量帧（不只 12 帧）考虑进去——PCM 向量
   当前裁到 12 帧（wasm 局部数上限），若要扩回全量需继续用 base64 行续模式，
   大小 ~262KB/流 是安全的（SBR 先例 262KB 单行可过，再大要警惕）。
3. **内核级覆盖 34 频带/ipdopd/HB**（fdk 不会发）：写 `ps_harness.c`（链接
   `aacps_common.c`+`aacps.c`+tablegen，读"payload 字节 + L 种子 + top"用例文件，
   逐例 `ff_ps_read_data`→合成 L→`ff_ps_apply`，插桩版自动产分级 dump），
   在 vpxdev-img 编译跑；用例 = 定向构造（34 频带 iid/icc、iccm≥3 走 HB、
   ipdopd 全开、frame_class=1、num_env 1–4、dt/df 混合）+ 随机若干。
   MoonBit 侧 wbtest 重放同批负载与 L，对比分级统计（max/sumAbs + 采样点，
   容差 1e-3 相对）。编码方向：哈夫曼编码=解码表逆用，`canonical()` 在
   `scripts/extract_ps_tables.py` 里有现成实现。
4. 收尾：`moon fmt`、全量 `moon test`（应 1040+）、`moon info --target wasm`、
   `.mbti` 不手改；README 的 AAC 行更新（PS 合成完成、USAC 仍缺）；
   `PORTING_HISTORY.md` 新 §107；本文件补"完成记录"；记忆文件更新；
   按精确路径 git add（**别把 `hevc_inter_decode.mbt` 的换行差异带进来**），
   中文 `feat:` + `Co-Authored-By:`。

## 再生命令（PowerShell，仓库根 `moonbit/`）

```powershell
# 向量（需要时）
docker run --rm --entrypoint bash -v "D:/project/FFmpeg-n9.0.2/moonbit/_build/ps_work:/work" linuxserver/ffmpeg:9.0.2 /work/gen_vectors.sh
# 插桩二进制（改了 instrument_ps.py 后）
cd _build/ps_work; python instrument_ps.py aacps_instr.c aacps_common_instr.c   # 先从 /src 拷新副本
docker run --rm --entrypoint bash -v "D:/project/FFmpeg-n9.0.2:/src:ro" -v "D:/project/FFmpeg-n9.0.2/moonbit/_build/ps_work:/work" vpxdev-img:latest /work/build_trace.sh
# 转储（每流一段；参考 run_trace.sh）
docker run --rm --entrypoint bash -v "...ps_work:/work" vpxdev-img:latest -c "/work/ffmpeg_psstrace -v error -i /work/hev2_48_32k.aac -c:a pcm_s16le -f null - ; cp /tmp/ps_payloads.txt /work/dumps/hev2_48_32k_payloads.txt; cp /tmp/ps_syntax.txt /work/dumps/hev2_48_32k_syntax.txt"
# 表 + 测试
python scripts/extract_ps_tables.py      # 需 _build/ps_work/ps_tables.txt（dumps/ps_tables.txt 拷上来）
python scripts/generate_aac_ps_tests.py
C:/Users/milkb/.moon/bin/moon.exe test libavcodec --target wasm --no-render --filter "*PS*"
```

调试利器：`_build/ps_work/ps_debug_decode.py <N>` 用与端口相同的规范码表在
Python 里解第 N 条负载（对照 `dumps/*_payloads.txt`），已验证与 C 一致；
MoonBit 侧有 `aac_ps_err_tag`（read_data 错误位点标签）和 `aac_ps_entry_dbg`
（每次调用入口位串）两个调试全局，跑测试时打印即可。
