# License / 许可证

**ffmpeg/moonbit** — a MoonBit port of parts of FFmpeg 9.0.2.

SPDX-License-Identifier: LGPL-2.1-or-later

## License and attribution / 许可与署名

This project is licensed under the **GNU Lesser General Public License version
2.1 or later**, as declared in `moon.mod`, subject to file-specific and third-party
notices. The authoritative license texts are [LGPL 2.1](COPYING.LGPLv2.1) and
[LGPL 3](COPYING.LGPLv3). Choosing LGPL 3 also requires compliance with the GPL 3
terms it incorporates and inclusion of the required license texts when redistributing.

Original FFmpeg code remains copyright its respective authors. MoonBit translation
contributions are copyright (c) 2026 the ffmpeg/moonbit contributors. Preserve
original copyright, license, attribution, and warranty notices, together with
modification notices and dates required by the applicable license. Changing
languages does not remove upstream obligations or authorize relicensing third-party code.

Unless a file states otherwise, this project's source code, development tooling,
and documentation are LGPL-2.1-or-later. Separate third-party notices remain
applicable. Test data requires its own provenance and rights assessment; generating
output with an LGPL/GPL tool does not by itself determine the output's license.

本项目采用 **LGPL-2.1-or-later**，与 `moon.mod` 一致；各文件及第三方组件的
特定许可和通知仍然适用。许可证正文见 [LGPL 2.1](COPYING.LGPLv2.1) 和
[LGPL 3](COPYING.LGPLv3)。选择 LGPL 3 时，还须遵守其纳入的 GPL 3 条款，
并在再分发时附上所需许可证全文。

原始 FFmpeg 代码的版权归相应作者所有；MoonBit 移植贡献的版权归 2026 年
ffmpeg/moonbit 贡献者所有。须保留原始版权、许可、署名和无担保通知，并按适用
许可证标明修改内容及日期。换用语言不解除上游义务，也不授权重新许可第三方代码。
除文件另有说明外，本项目源码、开发工具和文档采用上述许可；第三方通知仍须遵守。
测试数据应单独核对来源和权利，不能仅凭生成工具的许可证确定其许可。

## Source-only distribution / 仅分发源码

The maintainers release source code only and do not publicly provide or distribute
WASM build artifacts, binaries, executables, object files, static or shared libraries,
compiled artifacts under `bin/`, precompiled packages, or other prebuilt artifacts.
This policy governs the maintainers' releases; it does not restrict recipients'
rights to compile, modify, or redistribute under applicable open-source licenses.

维护者仅发布源码，不对外提供或分发 WASM 编译产物、二进制文件、可执行程序、
目标文件、静态库、动态库、`bin/` 目录中的编译产物、预编译包或其他预构建制品。
这是维护者的发布政策，不限制接收者按适用开源许可证自行编译、修改或再分发的权利。

## Decoder patents / 解码器专利

**The project includes decoder implementations such as H.264/AVC, HEVC/H.265,
and AAC, whose technologies may be covered by third-party patents.** Source-only
distribution can reduce compliance burdens associated with prebuilt artifacts;
it does not remove source-distribution obligations, establish patent clearance,
or guarantee royalty-free or non-infringing use. Except for patent rights expressly
granted under applicable licenses, this notice grants no additional patent license.

**本项目包含 H.264/AVC、HEVC/H.265、AAC 等解码器实现，相关技术可能受第三方
专利保护。** 仅分发源码可减少与预编译产物相关的合规负担，但不免除源码分发义务，
不代表已取得专利许可，也不保证免版税或不侵权。除适用许可证明确授予的专利权利外，
本声明不授予额外专利许可。具体说明见 [LEGAL.md](LEGAL.md)。

## Distribution obligations / 分发义务

Source distribution remains subject to LGPL 2.1 §§1–2. Downstream distribution
of compiled libraries or linked applications requires assessment of §§4–6 as
applicable, including corresponding source and any required materials or mechanism
for modifying the library and relinking the application. A separate `.wasm` file
or dynamic linking alone does not establish compliance. Do not impose terms that
conflict with the LGPL. See [LEGAL.md](LEGAL.md) §2.

源码分发仍须遵守 LGPL 2.1 §§1–2。下游若分发编译后的库或链接应用，应按实际情况
遵守 §§4–6，包括对应源码及适用时供用户修改库和重新链接的材料或机制。
独立 `.wasm` 文件或动态链接形式本身不保证合规；不得施加与 LGPL 冲突的条款。
详见 [LEGAL.md](LEGAL.md) §2。

## Trademark and warranty / 商标与无担保

FFmpeg is a trademark of Fabrice Bellard. This is an independent port and does
not imply affiliation with or endorsement by the FFmpeg project.

This library is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the applicable GNU Lesser General Public License.

FFmpeg 是 Fabrice Bellard 的商标。本项目为独立移植，不暗示与 FFmpeg 官方存在
附属或背书关系。本库不提供担保，包括适销性或特定用途适用性的默示担保；
具体无担保和责任限制以适用许可证及法律为准。

This notice does not amend the licenses. Applicable license texts govern.
本声明不修改许可证；存在冲突时以适用许可证正文为准。

Updated / 更新：2026-10-29.
