# 许可、源码分发与专利 / Licensing, source distribution, and patents

本文说明项目分发政策和合规注意事项，不是法律意见，不替代或修改许可证。
中英文说明与适用许可证冲突时，以许可证正文为准。

This document describes the project's distribution policy and compliance considerations.
It is not legal advice and does not replace or amend any license. Applicable license
texts govern if either language version conflicts with them.

## 1. 项目许可与分发政策 / License and distribution policy

本项目将 FFmpeg 的部分代码翻译、移植为 MoonBit，许可为 **LGPL-2.1-or-later**，
与 `moon.mod` 一致。各文件及第三方组件的特定许可、版权和署名通知仍须保留。
换用编程语言不解除上游义务；移植贡献的版权也不替代原作者的权利。
许可说明见 [LICENSE.md](LICENSE.md)，正文见 [LGPL 2.1](COPYING.LGPLv2.1)
和 [LGPL 3](COPYING.LGPLv3)。选择 LGPL 3 时，还须遵守其纳入的 GPL 3 条款，
并随适用的再分发附上所需许可证全文。

**维护者仅以源代码形式开源发布本项目，不对外提供或分发以下制品：**

- WebAssembly（WASM）编译产物；
- 二进制文件、可执行程序、目标文件、静态库或动态库；
- `bin/` 目录中的编译产物、预编译包及其他预构建制品。

本政策适用于维护者管理的仓库、发布附件、软件包渠道、公开 CI 构建产物及网页演示。
目录名称或扩展名不改变产物性质；网页向浏览器交付 WASM 也属于本政策不提供的情形。
构建脚本、源码示例和测试说明供使用者自行本地构建，并不表示提供预编译下载。
测试码流和参考数据不是可执行编译产物，其权利问题另见 §4、§6。

仅分发源码可减少与预编译产物分发相关的合规负担，但**不免除源码分发义务，不消除
专利或其他法律风险，也不撤销既有分发行为可能产生的义务**。本政策约束维护者的
发布方式，不禁止使用者按适用许可证自行编译、修改或再分发，不构成附加许可限制。

This project ports parts of FFmpeg to MoonBit under **LGPL-2.1-or-later**, as
specified in `moon.mod`. File-specific and third-party notices remain applicable.
Changing languages does not remove upstream obligations, and translation copyrights
do not replace the original authors' rights. See [LICENSE.md](LICENSE.md),
[LGPL 2.1](COPYING.LGPLv2.1), and [LGPL 3](COPYING.LGPLv3). Choosing LGPL 3 also
requires compliance with the GPL 3 terms it incorporates and inclusion of required
license texts when redistributing.

**The maintainers release source code only. They do not publicly provide or distribute
WASM build artifacts, binaries, executables, object files, static or shared libraries,
compiled artifacts under `bin/`, precompiled packages, or other prebuilt artifacts.**
This policy covers maintainer-controlled repositories, release attachments, package
channels, public CI artifacts, and web demos. Names and extensions do not change an
artifact's nature; delivering WASM to a browser is also excluded by this policy.
Build scripts, source examples, and testing instructions enable local builds; they
are not offers of precompiled downloads. Test bitstreams and reference data are not
executable build artifacts; see §§4 and 6 for their rights considerations.

Source-only distribution can reduce compliance burdens associated with prebuilt
artifacts. It does **not** remove source-distribution obligations, eliminate patent
or other legal risks, or discharge obligations arising from earlier distributions.
This is a maintainer publishing policy, not an additional restriction on recipients'
rights to compile, modify, or redistribute under applicable licenses.

## 2. 源码与下游分发义务 / Source and downstream distribution

源码发布仍应符合 LGPL 2.1 §§1–2：保留适用版权、许可及无担保通知，附上许可证，
并为修改的文件提供显著的修改说明及修改日期；衍生代码须按适用条款分发。
仅放置许可证链接或声称“已开源”不能替代这些要求。

下游若分发编译后的库或与其链接的应用，应按实际情况评估 LGPL 2.1 §§4–6，
包括完整对应源码、必要的构建材料，以及适用时供用户修改库并重新链接的应用目标文件、
源码或符合条款的共享库机制。**重新链接要求见 §6，不是 §4。**
独立 `.wasm` 文件或动态链接形式本身不保证合规。书面源码提供承诺仅能在相应条款
允许且满足期限、范围等条件时使用。应用条款不得与 LGPL 授予的权利冲突，包括
§6 所述为自身使用而修改及为调试这些修改而逆向工程。

Source releases remain subject to LGPL 2.1 §§1–2: preserve applicable copyright,
license, and warranty notices, include the license, and prominently identify modified
files and modification dates. Distribute derivative code under applicable terms.
A license link or an "open source" label alone does not fulfill these requirements.

Downstream distributors of compiled libraries or linked applications must assess
LGPL 2.1 §§4–6 as applicable, including complete corresponding source, necessary
build materials, and, where required, application object code, source, or a compliant
shared-library mechanism enabling modification of the library and relinking.
**The relinking provisions are in §6, not §4.** A separate `.wasm` file or dynamic
linking alone does not establish compliance. Written source offers are available only
where the relevant provisions permit them and their conditions are met. Application
terms must respect LGPL rights, including modification for the customer's own use
and reverse engineering for debugging those modifications under §6.

## 3. 商标与项目关系 / Trademark and affiliation

FFmpeg 是 Fabrice Bellard 的商标。本项目是独立的 MoonBit 移植，不代表 FFmpeg 官方，
也不暗示得到其认可或背书。项目名、文档及下游产品应清楚说明来源。

FFmpeg is a trademark of Fabrice Bellard. This is an independent MoonBit port,
not an official FFmpeg project or an assertion of endorsement. Names,
documentation, and downstream products should identify their origin clearly.

## 4. 第三方代码与测试数据 / Third-party code and test data

本项目以维持 LGPL-2.1-or-later 许可为目标。新增代码或依赖前，应核对具体文件、
版本及组合方式；本说明不是对所有文件的完整许可审计。

- GPL-only 代码（如上游 `tests/checkasm/*`、`tests/tiny_ssim.c` 和部分滤镜）或
  GPL 库的组合可能要求适用 GPL，不能直接沿用本项目的 LGPL 声明。
- LGPLv3、Apache-2.0 或其他条款的依赖可能要求调整适用版本或分发方式。
  不应仅凭库名推断兼容性，也不应把所有组合一律称为 GPL-2.0+ 或不可分发。
- 特殊署名要求（如 IJG 相关文件）、第三方版权和修改记录必须单独保留。
- 使用 FFmpeg、x264、x265 等工具生成输出，不会仅因使用该工具就使输出受其程序许可证
  约束；但素材内容、嵌入的受保护内容、来源许可和专利问题仍需另行检查。
  不能把“测试用途”理解为任意素材均可自由再分发。

The project aims to retain LGPL-2.1-or-later licensing. Review specific files,
versions, and combinations before adding ports or dependencies; this document is
not a complete license audit. GPL-only code or GPL library combinations may require
the applicable GPL. LGPLv3, Apache-2.0, or other dependencies may affect license
version or distribution options. Do not infer compatibility from a library name or
classify every combination as GPL-2.0+ or non-redistributable. Preserve special
attribution requirements, third-party notices, and modification records.

Generating output using FFmpeg, x264, or x265 does not by itself subject the output
to the tool's program license. Content rights, embedded protected material, provenance,
and patents must still be considered. Testing does not automatically permit redistribution.

## 5. 独立实现与重新许可 / Independent implementations and relicensing

对照上游代码翻译或移植不能仅因换用语言而改为 MIT、Apache 或专有许可。
若考虑其他许可，应确认全部相关权利人的授权或独立实现的权利基础。
净室开发可帮助记录独立实现过程，但不是自动获得许可的保证，也不解决专利问题。

Translating upstream code into another language does not authorize relicensing it
under MIT, Apache, or proprietary terms. Alternative licensing requires an adequate
rights basis, such as authorization from all relevant rights holders or an independent
implementation. Clean-room development may help document independence; it does
not automatically establish licensing rights or resolve patent issues.

## 6. 解码器专利特别声明 / Special decoder patent notice

**本项目包含 H.264/AVC、HEVC/H.265、AAC 等解码器实现，所实现的部分编解码技术
可能受第三方专利保护。** 此处提示专利风险，不宣称维护者拥有这些专利，也不认定
任何特定专利有效、必要或已被本项目侵犯。所列格式不是完整的专利风险清单。

源码公开、采用 LGPL、仅提供解码功能或不提供预编译包，均不代表已取得相关专利许可，
也不保证免许可、免版税或不侵权。除适用许可证明确授予的专利权利外，本声明不授予
额外专利许可，也不削减适用许可证已经授予的权利。

专利评估取决于具体权利要求、有效性、期限、司法辖区、实施方式及使用场景。
不能仅凭个人、研究、教学、非商业用途或某个国家/地区认定没有风险或当然豁免。
使用者在编译、使用、集成、部署或再分发前，应根据这些因素评估许可需求，必要时
取得相关权利人的授权。商业产品及跨境发布应进行适合其具体情况的专业评估。
本声明不把维护者依法承担的责任转移给使用者，也不承诺所有相关专利均已识别。

**This project includes decoder implementations such as H.264/AVC, HEVC/H.265,
and AAC. Some of the codec technologies implemented may be covered by third-party
patents.** This notice identifies a risk; it does not claim maintainer ownership of
those patents or determine that any particular patent is valid, essential, or infringed.
The listed formats are not an exhaustive patent-risk inventory.

Source availability, LGPL licensing, decoding-only functionality, and the absence
of precompiled packages do not establish patent clearance or guarantee license-free,
royalty-free, or non-infringing use. Except for patent rights expressly granted under
applicable licenses, this notice grants no additional patent license and does not
reduce any rights already granted by those licenses.

Patent assessment depends on specific claims, validity, term, jurisdiction,
implementation, and activities. Personal, research, educational, or noncommercial
use, or a particular location, does not alone establish an exemption or absence of
risk. Before compiling, using, integrating, deploying, or redistributing, users should
assess licensing needs in light of these factors and obtain authorization where
required. Commercial products and cross-border distribution warrant assessment
appropriate to their circumstances. This notice does not transfer the maintainers'
legal responsibilities to users or represent that all relevant patents have been identified.

## 7. 发布维护与无担保 / Release maintenance and warranty

发布源码前应检查实际发布内容，包括仓库跟踪文件、压缩包、软件包、CI 附件和网页资源，
确保符合 §1 的分发政策；声明和忽略规则本身不能阻止误发布。
新增源文件应记录真实来源、适用许可证、原作者版权及修改说明，不能把不同来源一律标为 FFmpeg LGPL。
本软件的无担保和责任限制以适用许可证及法律为准；本说明不提供适销性、特定用途适用性或不侵权保证。

Before releasing source, inspect the actual tracked files, archives, packages, CI
attachments, and web assets for compliance with §1. Notices and ignore rules alone
do not prevent accidental publication. New source files should record their actual
origin, license, original copyrights, and modifications; do not label every source
as FFmpeg LGPL regardless of provenance. Warranty exclusions and liability limits
are governed by applicable licenses and law. This document offers no warranty of
merchantability, fitness for a particular purpose, or non-infringement.

## 参考 / References

- [本项目许可说明 / Project license notice](LICENSE.md)
- [LGPL 2.1 正文 / License text](COPYING.LGPLv2.1)；[LGPL 3](COPYING.LGPLv3)
- [GNU 官方 LGPL 2.1 / Official GNU text](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html)
- [FFmpeg 官方法律说明 / Official legal information](https://ffmpeg.org/legal.html)
- [FFmpeg 许可说明 / Upstream license information](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html)
  （当前上游说明；具体移植须以对应版本和文件头为准 / current upstream summary;
  use the relevant version and file headers for each port）
- [GNU 许可证常见问题 / GNU license FAQ](https://www.gnu.org/licenses/gpl-faq.html)

更新于 / Updated: 2026-10-29.
