# 许可与法律注意事项

> 参照 FFmpeg 官方 [legal 页面](https://ffmpeg.org/legal.html)（[中文翻译镜像](https://ffmpeg.cpp.org.cn/legal.html)，非官方站点）为本项目定制。
> **本文不是法律意见。** 商业决策请咨询律师，并以许可证原文为准。LGPL 全文本目录已附副本
> （`COPYING.LGPLv2.1`、`COPYING.LGPLv3`），本项目许可声明见 `LICENSE.md`；`../COPYING.GPLv2`、
> `../LICENSE.md` 指外层 FFmpeg n9.0.2 源码树中的原文（该树不在本 git 仓库内，单独分发本仓库时
> 可对照 <https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/LICENSE.md>）。

---

## 1. 本项目的许可证

**本项目是 FFmpeg n9.0.2 的 MoonBit 翻译/移植，法律上属于 FFmpeg 的衍生作品（derivative work），因此继承上游许可证：LGPL-2.1-or-later。**

- `moon.mod` 已声明 `license = "LGPL-2.1-or-later"`；本目录附带 `LICENSE.md`（本项目许可声明）、
  `COPYING.LGPLv2.1` 与 `COPYING.LGPLv3` 全文，仓库自成一体。
- 每个 `.mbt` 文件头部标注了对应的 C 源文件（如 `libavcodec/hevc/hevcdec.c`）及其许可证。
- 移植是逐行翻译，"换语言"不产生新版权，也不能解除上游许可：原版权头（作者与年份）同时保留在
  `.mbt` 文件头与外层 FFmpeg 源码树对应的 C 文件中，二者一一对应。**裁剪仓库对外发布时，必须连同
  各文件版权头、本目录 `LICENSE.md` 与 `COPYING.*` 一起保留，不可剥离。**
- FFmpeg 不提供任何其他许可（包括付费的专有/商业授权），本项目同样无法绕开这一点——想以别的条款发布，只能做净室重写（见 §5）。

### 目前移植范围的许可证归属（已对照 n9.0.2 `LICENSE.md` 核对）

| 移植内容 | 上游对应 | 许可证 |
|---|---|---|
| libavutil 纯算法（md5、aes、base64、定点/数学等） | `libavutil/*` | LGPL-2.1+ |
| 封装/解封装（MPEG-TS、Matroska/EBML、MP4 头、PNG/APNG/MJPEG、VP9/AV1 头解析） | `libavformat/*`、`libavcodec/png*` 等 | LGPL-2.1+ |
| H.264/HEVC/AAC 解码（CABAC、残差、去块、SAO、MC、DPB 等） | `libavcodec/h264*`、`libavcodec/hevc/*`、`libavcodec/aac*` | LGPL-2.1+ |
| `scripts/_hevc_ref_harness*.c`（插桩 C 参考解码器） | 修改自 FFmpeg 源码 | LGPL-2.1+ |

**注意**：上游把 HEVC 解码器放在 `libavcodec/hevc/` 子目录，这些文件均不在 GPL 清单内；GPL-only 的
`tests/checkasm/*`、`tests/tiny_ssim.c`、GPL 滤镜（`vf_fspp`/`vf_pp7`/`vf_spp` 等 34 个）与
`x86/flac_dsp_gpl.asm`、`x86/idct_mmx.c` **均未被移植**，将来也不要移植（见 §4）。

---

## 2. LGPL-2.1 合规清单（把本库用进你的产品时）

以下是对官方 checklist 的本项目版本。凡分发包含本 MoonBit 移植（源码或编译产物）的产品：

1. **不启用 GPL/nonfree 内容** —— 不移植/链接 §4 列出的 GPL 文件与 GPL 外部库，本库即保持 LGPL。
2. **提供对应源码** —— 分发二进制时，随附（或书面承诺提供）本库完整对应源码。以源码形式随应用发布最简单，天然合规；可用 `git diff <上游基线>` 说明改动。
3. **保持库的可替换性** —— LGPL 是围绕"用户可替换的库"设计的。最干净是动态链接/独立 `.wasm` 模块；
   若静态编进应用，LGPLv2.1 §4 要求提供目标文件或等价手段让用户能重新链接替换本库。
4. **声明与署名** —— 在下载页、"关于"对话框、EULA 中注明：包含依 LGPLv2.1+ 授权的 FFmpeg（MoonBit 移植），
   并正确拼写 **FFmpeg**（两个 F 大写）。
5. **EULA 不得与 LGPL 冲突** —— 删除禁止反向工程的条款（LGPLv2.1 §6 允许为调试而逆向）；
   不得声称对本库拥有所有权或施加额外限制。
6. **模块命名** —— 引用 FFmpeg 之名的模块/产物不得混淆来源（官方例子：`avcodec.dll` 不许改叫
   `MyProgDec.dll`，`avcodec-MyProg.dll` 可以）。本项目模块名 `ffmpeg/moonbit` 保持来源清晰，符合要求。
7. **对依赖重复此流程** —— 若本库将来引入其他 LGPL 外部库，同样逐一合规；不引入 GPL 库。

---

## 3. 商标

**FFmpeg 是 Fabrice Bellard 的商标。** 本项目是独立的重构工作，与 FFmpeg 项目无附属或背书关系：
项目名、README、发布页不得暗示官方背书；使用 FFmpeg 名称时保持"FFmpeg 的 MoonBit 移植"这类描述性用法。
（你给过的 `ffmpeg.cpp.org.cn` 是第三方翻译站，与官方无关——法律表述请以 `ffmpeg.org` 为准。）

---

## 4. 会"改变许可证"的雷区（红线清单）

以下任何一项都会把整个组合升级为 **GPL-2.0+** 甚至**不可再分发**，移植前必须查上游 LICENSE 清单
（外层 `../LICENSE.md`；不在手边时对照 <https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/LICENSE.md>）：

- **移植上游 GPL-only 文件**：34 个 `vf_*` 滤镜、`tests/checkasm/*`、`tests/tiny_ssim.c`、
  `doc/texi2pod.pl`、`x86/flac_dsp_gpl.asm`、`x86/idct_mmx.c` 等。特别提醒：README 约定用
  "FFmpeg 自己的测试"做校验——**FATE 参考输出数据可以随便用，但 checkasm/tiny_ssim 的代码不能移植**。
- **移植/绑定 GPL 外部库**：libx264、libx265、libvidstab、frei0r、librubberband、avisynth、
  libcdio、libdavs2、libxavs(2)、libxvid 共 12 个。
- **LGPLv3-only 依赖**（gmp、libaribb24、liblensfun）会把许可证升级到 v3；Apache-2.0 依赖
  （VMAF、mbedTLS 等）与 v2.1 不兼容，同样要求 `--enable-version3` 档位。
- **nonfree（fdk-aac、OpenSSL）**：组合结果**不可再分发**，绝对不能进本库。
- **三个 IJG 特殊条款文件**（`jfdctfst.c`、`jfdctint_template.c`、`jrevdct.c`）：将来移植 IDCT 时
  有额外署名与变更说明义务（见 `../LICENSE.md` 末段）。

**不受影响（常见误解澄清）**：
- 用 `linuxserver/ffmpeg`（含 libx264/libx265 的 GPL 构建）**生成**的测试码流、参考输出、MD5 ——
  GPL 只覆盖程序文本，不覆盖程序的输出数据；测试向量可自由嵌入（内容本身的版权另计，见 §6 末条）。
- 分发 FFmpeg CLI（GPL 构建）二进制属于"分发 GPL 软件"，那一份按 GPL 办即可，不传染本库。

---

## 5. 想摆脱 LGPL 的唯一路径：净室重写

逐行翻译永远是衍生作品。若将来需要以宽松许可（MIT/Apache-2 等）发布某模块，唯一合规路径是
**净室流程**：一组成员读规范（ITU-T H.265/H.264 规范可自由下载）或产出到 C 参考解码器的对拍报告，
另一组从未接触 FFmpeg 源码的成员仅凭规范文本实现。本项目当前的"对照 C 源逐行移植"**不满足**净室要求，
因此本库整体必须保持 LGPL-2.1+。

---

## 6. 专利迷你 FAQ（HEVC/H.265 重点）

**问：本项目的解码器用了专利算法吗？**
FFmpeg 官方的回答同样适用于此：开发者没有为实现而阅读过任何专利，无法回答；但 H.264 与 HEVC
规范文本自身都声明"符合本规范可能需要使用一项或多项专利"。HEVC 相关的主要专利池有 Via-LA
（原 MPEG LA）、HEVC Advance、Velos Media，另有池外持有者——**解码**同样落在多数许可主张范围内。

**问：在中国大陆使用安全吗？**
取决于司法管辖区。算法/软件专利在多数国家（包括中国和欧盟大部分情形）可专利性受限或难以执行，
但在美国等法域有效。仅在本地开发、研究、教学使用，实际风险很低。

**问：个人使用需要担心吗？**
几乎不需要。私人使用历来没有被追讨的先例。

**问：做成商业产品呢？**
有公司在产品中使用 FFmpeg 后被专利持有者（如 MPEG LA）追讨许可费的公开先例。**商业化分发
（尤其是面向美国市场或上架应用商店）之前，必须做专利评估。** 本项目当前定位是研究性移植验证，
风险可控；发布含 HEVC/H.264 解码能力的二进制前请重读本条。

**测试素材**：x265/x264 编码的测试流内容若无额外授权，仅限内部测试，不要再分发内容本身。

---

## 7. 本仓库的额外义务与建议

- 开发工作区外层是**完整未修改的 FFmpeg 源码树**（不在本 git 仓库内，仅作对照参考）：本仓库发布时
  保留各文件版权头、`LICENSE.md` 与 `COPYING.*` 即可，不要剥离。
- `scripts/_*.py`、`_hevc_ref_harness*.c` 是开发工具，若随产品分发同样受 LGPL 约束（保留基于 FFmpeg
  修改的文件头与来源说明）。
- 新增 `.mbt` 文件务必延续现有文件头约定：注明对应 C 源文件 + "Original FFmpeg code is
  LGPL-2.1-or-later; this port keeps the same license."
- 新增第三方依赖（包括 MoonBit 包）时，先核对其许可证与 LGPL-2.1 的兼容性，再进 `moon.mod`。

## 参考

- 官方原文：<https://ffmpeg.org/legal.html>、<https://ffmpeg.org/legal.html#license>（License 章节）
- 许可证文本：本目录 `LICENSE.md` / `COPYING.LGPLv2.1` / `COPYING.LGPLv3`；上游原文在外层 FFmpeg
  源码树 `../COPYING.LGPLv2.1`、`../COPYING.GPLv2`、`../LICENSE.md`（GPL 文件与外部库清单的权威
  来源，亦可对照 <https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/LICENSE.md>）
- GPL FAQ：<https://www.gnu.org/licenses/gpl-faq.html>

---
*2026-10-21 依据 FFmpeg n9.0.2 源码树核对编写。*
