# AAC SBR 交接报告（2026-10-27）

## 状态

**已完成并收敛**。AAC SBR（HE-AAC）语法层 + DSP 层 + 帧级接线全部移植，
与 FFmpeg 9.0.2 原生 `aac` float 解码器逐级对拍：

- **语法层位级一致**：24 帧（48 kHz 单声道）+ 17 帧（32 kHz 三声道 SCE+CPE，
  含 `bs_coupling=1` 立体声耦合路径）的全部解析字段（TBL/网格/包络/噪声/
  invf/harmonic/dtdf）与插桩 C dump 逐行相同。
- **端到端 PCM**：mono48 24 帧、3ch 17 帧 —— `max_diff=1` LSB，
  98234/98304 逐样本精确（99.93%），差 1 LSB 者为 Double vs C float32
  的固有舍入。
- Wasm 全量 **976/976**；`moon check --deny-warn` 零警告。

## 新增文件（libavcodec/）

| 文件 | 内容 |
|---|---|
| `aac_sbr.mbt` | `AacSbr`/`AacSbrData` 状态、Huffman（表序码字分配）、header/grid/dtdf/invf/envelope/noise、f_master/f_derived/patches/f_tablelim、`decode_extension` |
| `aac_sbr_dsp.mbt` | IMDCT64（naive 直译）、QMF 分析/合成、sbrdsp kernels、dequant/chirp/hf_inverse_filter/mapping/env_estimate/gain_calc/hf_assemble/x_gen/lf_gen、`AacSbr::apply` |
| `aac_sbr_entry.mbt` | `decode_fill_element`（EXT_SBR_DATA 门控）与 `apply_sbr`（per-element 应用、隐式 PS 升格） |
| `aac_sbr_tables.mbt` | 脚本提取的 sbr_offset/QMF 窗/噪声表/Huffman 表 |
| `aac_sbr_syntax_*_wbtest.mbt` | 语法位级对拍（C dump 期望值内嵌） |
| `aac_sbr_pcm_*_wbtest.mbt` | 端到端 PCM 对拍（max_diff 统计） |

## 再生对拍基建（`_build/sbr_work/`）

1. **向量生成**：docker `linuxserver/ffmpeg:9.0.2` + `libfdk_aac
   -profile:a aac_he`；参考 PCM 用原生 `-c:a aac` 解码（s16le）。
2. **插桩 C**：`instrument_sbr.py` 对 `aacsbr_template.c`/`aacsbr.c` 副本
   做锚点插桩；`build_trace.sh` 在 `vpxdev-img` 内最小化构建（aac 解码 +
   aresample + null muxer）。产出 `/tmp/sbr_syntax.txt` 与
   `/tmp/sbrbin/<tag>_<帧>_<ch>.f32`。
   注意：`--disable-everything` 会禁用 fftools；`printf` 的 `\n` 转义在
   多层 heredoc 传递中易错，脚本统一用 `chr(92)` 构造。
3. **MB 侧**：f32 位模式（`Float::reinterpret_as_uint`）序列化同序状态；
   对比脚本 `cmp_stages.py`。

## 修复链（分级 dump 定位，按发现顺序）

1. 表提取正则漏掉 `aacsbrdata.h` 的 `-Q31(...)` 负号（4 处，两个窗表各 2）。
2. `vector_fmul_reverse` 是 `dst[i] = win[i] * x[319-i]`。
3. `env_estimate`：`X_high[m+kx1] + ilb` 中 `ilb` 是**复元素**偏移，
   `sum_square` 的计数参数也是复元素数（浮点指针 `[2]` 类型算术）。
4. `hf_gen` 的 `X_high[k]+2`/`X_low[p]+2` 是 +2 复元素（= +4 float）。
5. `hf_g_filt` 的 `X_high + kx` 行偏移漏译。
6. `indexnoise`：kernel 内递增按值传递**不回传**；assemble 每槽尾部
   `+m_max` 一次（e_a 槽也递增）。双重递增导致噪声表错位 120。

## 边界与已知限制

- **PS（参数化立体声）未移植**：SBR 扩展中出现 `EXTENSION_ID_PS` 载荷时
  `AacSbr::apply` 显式报错；单声道隐式 PS（无 PS 数据）按双通道复制输出。
- USAC SBR 入口（`ff_aac_sbr_decode_usac_data`）未移植（本仓 USAC 不做）。
- `make_bands`/`lrintf` 走 f32 连乘；其余 DSP 为 Double，端点 PCM 与 C
  差 ≤1 LSB（f32 FFT vs naive IMDCT 的舍入差异被合成吸收）。
- `bs_sbr_crc_bits` 未校验（与 C 相同，仅跳过）。

## 后续可做

- AAC PS（`aacps.c`/`aacpsdsp_template.c`，约 1.6k 行；QMF 已就绪，
  `ps_allowed` 门与 `aac_sbr_ps_seen` 旗标已预留）。
- AV1 qmatrix、VP9 复合预测/参考缩放（见 [[av1-pixel-status]]）。
