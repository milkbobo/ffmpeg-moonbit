# agent.md —— 本项目维护手册（供 AI / 协作者）

> 面向「在这个仓库里继续干活」的实操指引。**进度、模块清单、行数、验证来源**等动态信息
> 以 [README.md](README.md) 为准；本文只记录**稳定约定、命令、坑与流程**。

---

## 0. 一句话定位

用 MoonBit 逐模块重写 FFmpeg 9.0.2 的**纯算法**部分。当前覆盖：

- **libavutil**：数学/有理数、CRC/Adler-32、Base64、MD5、SHA-1/224/256、avstring、
  RC4、AES(ECB/CBC)、XTEA、TEA、Blowfish、CAST-128、AES-CTR；另有 `@v128` SIMD 版：
  Adler-32、base64 编码、`av_strnstr`、MD5 多缓冲（`adler32_v128.mbt`/`base64_v128.mbt`/
  `avstring_v128.mbt`/`md5_v128.mbt`）
- **libavformat**：内存字节读取器 + MP4/MOV 解复用切片（box 遍历 + 采样表索引、碎片化
  MP4 含 `sidx`/`mfra` 与重叠片段 discard、extradata `avcC`/`esds`+AAC 配置、
  `mov_seek_stream` seek、未压缩音频分块路径、cenc 全家含碎片内 `senc` 与 `saiz`/`saio`）
- **libavcodec**：SIMPLE-C IDCT（`int16` 8/10/12 bit）+ `idctdsp` 像素/扫描表辅助；
  `huffman.c` 的树/码长构建（`ff_huff_build_tree`/`ff_huff_gen_len_table`）+ 规范化
  Huffman 码的编/解码；`mpeg4audio.c` 的 AudioSpecificConfig 解析（`mpeg4audio.mbt`，
  供 libavformat 的 `esds` 用 —— **libavformat 依赖 libavcodec**，与 FFmpeg 方向一致）；
  IDCT 的 8/10/12 位另有 `@v128` SIMD 版（`idct_v128.mbt`，块/像素改用 **字节缓冲**，
  v128 才能载入）

策略：**垂直切片**，从自包含、可独立验证的纯算法入手。**向量化（SIMD）内核用 MoonBit
`@v128`（`moonbitlang/core/v128`，Wasm SIMD128 / native SIMD）重写** —— FFmpeg 的
NASM（`*.asm`）是 x86 汇编，**无法**编译进本模块的 `wasm` 目标；仅 x86 专有指令
（AES-NI / SHA-NI / PCLMULQDQ）与线程/平台代码留待 `extern "C"` FFI 复用（见 §8）。

---

## 1. 位置与仓库

| 项 | 值 |
|---|---|
| 工作目录 | `d:\project\FFmpeg-n9.0.2`（FFmpeg 源码根，**不是** git 仓库） |
| git 仓库 | `d:\project\FFmpeg-n9.0.2\moonbit`（分支 `master`，**未配置远端**） |
| 忽略项 | `_build/`（`.gitignore` 已含；勿提交） |
| 模块名 | `ffmpeg/moonbit`，`preferred_target = "wasm"` |
| 包 | `ffmpeg/moonbit/libavutil`、`ffmpeg/moonbit/libavformat`、`ffmpeg/moonbit/libavcodec`（后两者依赖 libavutil；libavcodec 的 libavutil 依赖仅白盒测试用） |

> ⚠️ 提交前 `git status` 应在 `moonbit/` 下执行；FFmpeg 根目录不是仓库。

---

## 2. 工具链与命令

- `moon.exe`：`C:\Users\milkb\.moon\bin\moon.exe`（已验证 `0.1.20261012`）
- 标准流程（`cwd` 设为 `moonbit`）：

```powershell
C:\Users\milkb\.moon\bin\moon.exe check --no-render   # 必须 0 error / 0 warning
C:\Users\milkb\.moon\bin\moon.exe test  --no-render   # 必须全绿
```

- 加 `--no-render` 抑制刷屏；用 `Select-String -NotMatch "INFO"` 过滤日志后看结论。
- **交付标准**：`moon check` 0 error / 0 warning，且 `moon test` 全通过。

---

## 3. 提交规范

- **仅在用户明确要求时提交**；不主动 commit。
- 按**精确路径** `git add`（勿用 `git add -A` / `git add .`，以免带入无关文件）。
- 提交信息风格：`feat: …`（中文摘要），末尾附 `Co-Authored-By:` 行。
- PowerShell **没有 bash 式 heredoc**，多行信息用 here-string 经 stdin 传入：

```powershell
$msg = @'
feat: 摘要

详细说明……
'@
$msg | git commit -F -
```

---

## 4. 新增一个模块的标准步骤

1. **通读 C 源**：`libavutil/xxx.c` 与 `xxx.h`（或 `libavformat/xxx.c`）。
2. **先找权威向量**：`libavutil/tests/xxx.c` 内嵌向量 或 `tests/ref/fate/xxx`（见 §5）。
3. 建 `moonbit/libavutil/xxx.mbt`（或 `libavformat/`）；文件头保留原 C 的版权/许可证说明，
   并显式写明任何**实现偏差**。
4. **逐行移植**，遵循 §6 约定。
5. 在 `*_wbtest.mbt`（或按主题合并进 `cipher_wbtest.mbt` 等）加白盒测试，期望值**必须**
   取自权威向量。
6. `moon check` / `moon test` 达到交付标准。
7. **更新 README.md**：目录树、模块表、总行数、状态（`N/N`）、验证来源表、阶段勾选、
   未完成清单。
8. 汇报进度；**不要自行 commit**（除非用户要求）。

---

## 5. 验证铁律

- **每个模块必须用独立权威向量验证；禁止自造期望值。**
- 优先级：FFmpeg 自带（`libavutil/tests/*.c` 内嵌向量、`tests/ref/fate/*`）→ FIPS/NIST/RFC 官方标准。
- 注意：`tests/ref/fate/*` 很多只是「成功行」文本，**没有数值**；数值通常在同名
  `libavutil/tests/*.c` 里（如 `xtea`、`tea`、`blowfish`、`cast5` 均如此）。
- 可补强：分块更新与一次性计算等价、加密→解密往返、CTR「任意切分 == 一次性」。
- **真实文件交叉验证（有 Docker 时优先做）**：本机存在镜像 `linuxserver/ffmpeg:9.0.2`
  时，用它生成真实 MP4（普通/碎片化/cenc），并以同镜像 `ffprobe` 的
  `-show_entries packet=pts,dts,duration,pos,size,flags` 输出作为期望值，与解析结果
  逐 packet 比对。范本见 `libavformat/mp4_real_wbtest.mbt`（文件 base64 内嵌 + 生成命令）。
  cenc 文件可用 `-encryption_scheme cenc-aes-ctr -encryption_key … -encryption_kid …`
  生成，再以已知密钥解密核对明文样本。
- **无 FATE 数值向量时（如 `libavcodec/huffman.c`）**：用「期望值由 FFmpeg 自己的另一实现产生」
  或「能被数学性质唯一确定的量」作判据 —— 例如 Huffman 用 Kraft 等和 `Σ2^-len == 1` +
  与独立教科书两队列法的最优代价相等 + FFmpeg 两套实现互证 + 编解码往返；IDCT 则对照
  FFmpeg 自带的双精度参考 `libavcodec/dctref.c`，判据照抄 `libavcodec/tests/dct.c`。
- **SIMD 路径同样要吃向量**：SIMD 实现必须与标量路径、以及该模块既有权威向量**逐值一致**
  （同一测试里同时跑 SIMD 与标量并断言相等，或先证标量再切 SIMD）；不得因为"是优化路径"
  就放宽断言。
- **测试失败先怀疑自己的期望值**：本项目已多次出现「实现正确、期望写错」的情况
  （如 `av_strcasecmp` 返回值、`av_strlcat` 预算不足返回所需长度、`av_match_name` 的
  首命中短路语义）。先回到 C 源码重推。

---

## 6. MoonBit 语法 / 工具链坑（务必遵守）

清一色来自本项目的真实踩坑，照做可少走弯路：

- 按位取反 `~` 不存在 → 用 `x.lnot()`。
- 逻辑右移 `>>>` 不存在 → 改用 `UInt`/`UInt64`（其 `>>` 即逻辑右移）。
- `to_int` / `to_uint` 已弃用 → `reinterpret_as_int` / `reinterpret_as_uint`；
  `Int`（32 位）**没有** `reinterpret_as_uint64`，需先 `to_int64()`。
- 方法声明必须带类型前缀：`fn Type::name(self : Type)`（裸 `fn name(self : Type)` 是弃用告警）。
- 丢弃非 `Unit` 返回值必须写 `let _ = ...`（否则 `E4139`）。
- 结构体里**只改元素、从不整体重赋值**的数组字段**不能加 `mut`**（`unused_mut` 报错）；
  标量字段需重赋值才加 `mut`。
- `T` 不会隐式转 `T?`，实参要写 `Some(x)`。
- **不要** `derive(Eq, Show)`（触发 `implicit_impl_as_method` / `deprecated_syntax` 告警）；
  用 `match` 辅助函数。
- **值标识符/参数名须以小写或 `_` 开头**：大写如 `K` 会报 `E4074` / `E3002`。
- `Bytes` → `String`：`to_string()` 返回 `b"..."` 字面量、`to_unchecked_string()` 按 UTF-16
  解释字节，**都不能**把 ASCII 字节正确转字符串；需按码位构造 `String::from_array(Array[Char])`。
- 顶层 `let` + `FixedArray` 字面量可作常量表。
- `UInt` 是 **32 位回绕算术**（SHA、各分组密码的 `+ - * <<` 均依赖此语义）。
- **十六进制字面量前缀必须小写 `0x`**（`0X` 不被识别）。
- 未使用的循环计数变量**不会**告警，C 风格 `for i = 0; i < n; i = i + 1` 可安全照搬。
- **`test` 是保留字**，不能作参数/变量名（否则报大片 `E3002` 解析错误并连带无关告警），
  移植 `dct.c` 之类含 `int test` 的函数时改名（如 `mode`）。
- **白盒测试专用依赖**用 `moon.pkg` 的 `import { "…" } for "wbtest"`；写成普通 `import`
  会因非测试文件不使用该包而触发 `unused_package` 告警。
- **core 包**：`Double::sqrt`（方法）可用；`floor`/`round`/`ceil` 可用方法或 `@math.*`；
  `@math.cos` 等数学函数需在 `moon.pkg` 里 `import { "moonbitlang/core/math" }`（别名为 `@math`）。
- **行数统计口径**：`Get-Content $f | Measure-Object -Line` 会少计，统一用 `(Get-Content $f).Count`。
- **`@v128` 的 experimental 告警**：调用 `@v128.*` 会触发 `alert_experimental`（E0014）；
  在 `moon.pkg` 写 `warnings = "-alert_experimental"` 即可消警（core 自身亦如此，见
  `core/debug/moon.pkg`）。完整范本：`libavutil/adler32_v128.mbt`（构造用 `i16x8_const`、
  块载入用 `[v128le(v), .. _]` 模式、横向归约用 `i32x4_extract_lane`、`UInt64` 字面量用 `16UL`）。

---

## 7. 移植算法常见陷阱

- **端序**：严格区分 `AV_RB*`/`AV_RL*`，写出用对应的 `wb32`/`wl32` 辅助。
- **输出参数**：C 的 `int *dst`、`uint32_t *xl,*xr` → 改为**返回值**（元组）。
- **错误码**：C 返回 `<0`（`AVERROR(EINVAL)`）→ 返回 `Result[T, String]`，错误信息 `"EINVAL"`。
- **CBC 次序**：加密 = `tmp = src ^ iv` → 加密 → `iv = 密文块`；解密 = 先解密 → `^ iv` →
  `iv = 消费的密文块`。务必与 C 的先后一致（尤其 `iv` 用的是 `src` 还是 `dst`）。
- **结构体声明与实际使用不符**：多个密码的 `key[16]` 实际只用前 4 个字，移植时只存实际
  用到的长度并加注释。
- **平台相关**：`av_get_random_seed` 之类不移植，留待 FFI（例：`aes_ctr.mbt` 未做
  `set_random_iv`）。
- **串行哈希的 SIMD 方向**：MD5/SHA 一类的轮函数前后强依赖，**单流无法向量化**（FFmpeg
  自身也为标量 C）；可并行的是**多路独立输入**。做法是在 `i32x4` 的 4 个 lane 里各放一条
  **等长**消息，逐 lane 施加同一轮常量/混合/`rotl`（`i32x4_shl` + `i32x4_shr_u`），循环外围
  仍是标量块调度（`av_md5_sum_x4`，见 `md5_v128.mbt`）。这类内核需**新增多缓冲 API**，
  且必须与标量单流版逐 lane 逐值一致。

---

## 8. 边界与偏差原则

- **纯算法 → MoonBit 逐行重写**。
- **向量化（SIMD）内核 → 用 MoonBit `@v128`（`moonbitlang/core/v128`，Wasm SIMD128 /
  native SIMD）重写**。FFmpeg 的 NASM（`*.asm`）**不能**编译进本模块的 `wasm` 目标，
  故它们不是"留作 FFI 的黑盒"，而是 SIMD 化的**目标对象**：实现时用
  `#cfg(any(target="native", target="wasm"))` 门控并配标量回退，参考 core 的
  `encoding/base64/encode_v128.mbt`；已移植代码的候选清单见 README §3。
- **例外（才留 C / FFI）**：MoonBit 无法表达的 x86 专有指令（AES-NI / SHA-NI /
  PCLMULQDQ 等）与线程/平台代码（`pthread`、随机源、文件/网络 IO）。
- 目前 **libavutil 内唯一**一处「按规范而非按 C 源码逐行」实现的是 `aes.mbt` 的轮函数
  （FIPS-197）；libavcodec 的 Huffman 规范化码另有等效性说明。均在 README 记录理由；
  改动实现方式时必须在源码头与 README 同步记录。

---

## 9. 批量常量表处理规范

适用于 Blowfish `orig_s`、CAST5 `S1..S8` 等大型表：

- 从对应 **C 源批量提取**十六进制常量并生成表字面量，**禁止手工转录**（易错且难查）。
- **陷阱一**：对提取结果整体 `ToUpper()` 会把 `0x` 前缀变成 `0X` → 只大写十六进制**数位**，
  或整体保持小写。
- **陷阱二**：不要对提取结果再做「行重排」等二次处理 —— 曾因此把 8 张 S-box 表**错位**，
  一版测试失败。
- 生成后**双重校验**：① 模块自带权威向量全部通过；② 与 C 源**逐值 diff == 0**。

---

## 10. 故障排查清单

- `moon check` 报错位置看起来「不可能」（例如指向 `]`）→ **按字节 hexdump 该行**核对
  （渲染会掩盖形近错拼，历史上有 `>`(0x3E) 误写成 `]`(0x5D) 的情况）。
- git 提示 `LF will be replaced by CRLF` 只是警告，不影响提交。
- 新增文件名/路径含空格时，命令中加引号。
- **超长迭代向量**（如 `libavutil/tests/cast5.c` 的 100 万次迭代）耗时过大 → 不纳入测试，
  在 README 记录来源与跳过原因。
- 运行命令统一用 Shell 工具的 `cwd` 参数指向 `moonbit`，不要 `cd` 链式拼接。

---

## 11. 目录结构（简）

```
moonbit/                      # git 仓库根
├── .gitignore                # 忽略 _build/ 等
├── moon.mod                  # name = "ffmpeg/moonbit", preferred_target = wasm
├── README.md                 # 进度 / 模块表 / 验证来源 / 约定 / 踩坑（动态信息看这里）
├── agent.md                  # 本文件（稳定约定、命令、流程）
├── libavutil/                # 包 ffmpeg/moonbit/libavutil
│   ├── moon.pkg              # 含 moonbitlang/core/v128 + warnings = "-alert_experimental"
│   ├── *.mbt                 # 各纯算法模块
│   ├── *_v128.mbt            # `@v128` SIMD 版（adler32/base64/avstring/md5）+ 同主题 wbtest
│   └── *_wbtest.mbt          # 白盒测试（含 cipher_wbtest.mbt 汇总各密码）
├── libavformat/              # 包 ffmpeg/moonbit/libavformat（依赖 libavutil + libavcodec）
│   ├── moon.pkg
│   ├── reader.mbt            # 内存字节读取器
│   ├── mov.mbt               # MP4/MOV 解复用（box 遍历 + 采样表 + 碎片化 + cenc）
│   ├── extradata.mbt         # glbl（avcC 等原样）+ esds 描述符链 + AAC 配置
│   ├── frag.mbt              # sidx + mfra/tfra（mfro 探测）
│   ├── seek.mbt              # ff_index_search_timestamp + mov_seek_stream
│   ├── mp4_wbtest.mbt        # 第一批合成 box 测试
│   ├── mp4_extra_wbtest.mbt  # 第二批合成 box 测试（extradata/sidx/seek/音频分块…）
│   └── mp4_real_wbtest.mbt   # 真实文件交叉验证（两批，docker ffmpeg/ffprobe）
└── libavcodec/               # 包 ffmpeg/moonbit/libavcodec（@math/@v128 + libavutil 仅白盒测试用）
    ├── moon.pkg
    ├── idct.mbt              # SIMPLE-C IDCT + idctdsp 辅助（标量，Array[Int]）
    ├── idct_v128.mbt         # 8 位 IDCT 的 `@v128` 版（块/像素用字节缓冲）
    ├── dctref.mbt            # 双精度参考 DCT/IDCT（IDCT 测试的期望值来源）
    ├── huffman.mbt           # Huffman 树/码长 + 规范化码编解码
    ├── mpeg4audio.mbt        # AudioSpecificConfig 解析（esds/AAC 用）
    ├── idct_wbtest.mbt
    ├── idct_v128_wbtest.mbt
    ├── huffman_wbtest.mbt
    └── mpeg4audio_wbtest.mbt
```

---

## 12. 许可证

本仓库是 FFmpeg 的衍生移植，遵循 **LGPL-2.1-or-later**（见 `moon.mod` 与各源文件头部）。
新增文件须保留原始 C 文件的版权与作者信息。
