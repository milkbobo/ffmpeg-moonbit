# License

**ffmpeg/moonbit** — the MoonBit port of FFmpeg 9.0.2 (release n9.0.2).

SPDX-License-Identifier: LGPL-2.1-or-later

## 1. Overview

This repository is a line-by-line translation of parts of the FFmpeg source
tree from C to MoonBit. A translation is a **derivative work** of FFmpeg, so
this repository as a whole is licensed under the **GNU Lesser General Public
License version 2.1 or later (LGPL-2.1-or-later)** — the same license as the
upstream code it derives from. Changing languages does not create new
copyright that could weaken the upstream terms, and no alternative (proprietary
or more permissive) licensing is possible for this code; see `LEGAL.md` §5 for
the clean-room conditions under which that could change.

The authoritative license texts are distributed in this repository and must be
kept with any redistribution:

- `COPYING.LGPLv2.1` — GNU LGPL version 2.1 (the default)
- `COPYING.LGPLv3` — GNU LGPL version 3 (since the license is "2.1 or later",
  you may opt to apply this version instead)

`moon.mod` declares `license = "LGPL-2.1-or-later"`.

## 2. Copyright and attribution

- The original C code is Copyright (c) 2000–2025 the FFmpeg developers and
  their respective contributors.
- The MoonBit translation changes are Copyright (c) 2026 the ffmpeg/moonbit
  contributors, licensed under the same terms; no additional or weaker claims
  are made over the translated code.
- **Every `.mbt` file header records the upstream C file(s) it translates and
  the original copyright holders (authors and years) of that code.** That
  per-file attribution is authoritative; this file only summarizes. When
  distributing a trimmed copy of this repository, keep the file headers and
  the `COPYING.*` texts intact — they must not be stripped.

## 3. Files covered

Unless a file explicitly states otherwise, everything in this repository is
LGPL-2.1-or-later, including:

- `libavutil/`, `libavformat/`, `libavcodec/` — the `.mbt` ports (MD5/AES and
  math utilities; MPEG-TS / Matroska / MP4 demuxing; H.264, HEVC, AAC and FLAC
  decoding; and their tests);
- `scripts/` — development tooling, including the instrumented C reference
  decoders (`_hevc_ref_harness*.c` and similar), which are modified FFmpeg
  sources and therefore LGPL with their upstream headers preserved;
- the documentation (`README.md`, `LEGAL.md`, this file).

Test bitstreams, reference checksums and other data embedded in tests are
*outputs* of running FFmpeg/x264/x265 etc. Program licenses cover program
text, not program output, so these vectors are not part of the LGPL-covered
work; they are provided for testing only, and no rights over the underlying
multimedia content are claimed or granted (see `LEGAL.md` §4, §6).

## 4. Deliberately not included (kept LGPL, not GPL)

No GPL-only upstream file has been ported and no GPL/nonfree external library
is referenced. Upstream categories that must stay out (per the upstream
`LICENSE.md`, the authoritative list):

- `tests/checkasm/*`, `tests/tiny_ssim.c`, `doc/texi2pod.pl`,
  `compat/solaris/make_sunver.pl`, `doc/t2h.pm`,
  `libswresample/tests/swresample.c`;
- the GPL x86 optimizations (`x86/flac_dsp_gpl.asm`, `x86/idct_mmx.c`,
  `vf_removegrain.asm`);
- the 34 GPL `vf_*`/`vsrc_*` filters (`vf_fspp.c`, `vf_pp7.c`, `vf_spp.c`,
  `vf_delogo.c`, …).

Porting or linking any of these — or binding GPL external libraries such as
libx264/libx265 — would relicense the whole combination under GPL-2.0+.
Do not do so accidentally; re-read `LEGAL.md` §4 before extending scope.

## 5. Using this library in your product

LGPLv2.1 imposes obligations on distributors; the project-specific checklist
is `LEGAL.md` §2. In short: ship (or offer) the corresponding source of this
library, keep it user-replaceable (dynamic linking or a standalone `.wasm`
module is cleanest; if you static-link, provide object files or an equivalent
relinking mechanism per LGPLv2.1 §4), credit "FFmpeg (MoonBit port) licensed
under the LGPLv2.1+" — spelled **FFmpeg** — and do not add EULA terms that
conflict with the LGPL (e.g. no forbidding reverse engineering for debugging).

## 6. Trademark

**FFmpeg is a trademark of Fabrice Bellard.** This is an independent port; it
is not affiliated with, endorsed by, or official in any way. Use the FFmpeg
name descriptively ("a MoonBit port of FFmpeg") and never in ways that imply
endorsement or confuse the origin of binaries.

## 7. NO WARRANTY

This library is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License
(`COPYING.LGPLv2.1`) for more details.

## 8. Canonical per-file notice

New files must follow the existing header convention (see `LEGAL.md` §7):

```text
MoonBit port of <FFmpeg file/function(s)> from FFmpeg 9.0.2.

Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) <year> <author>.
This port keeps the same license.
```

---

## 中文简读

本仓库是 FFmpeg n9.0.2 的逐行 MoonBit 翻译，法律上属 FFmpeg 的衍生作品，
因此整体许可为 **LGPL-2.1-or-later**，与上游一致；许可证全文见本目录
`COPYING.LGPLv2.1`（默认）与 `COPYING.LGPLv3`（"or later" 档位）。
每个 `.mbt` 文件头已注明对应的 C 源文件及原作者版权，是对外的权威署名，
再分发时不得剥离。本仓库未移植任何 GPL-only 文件、未绑定 GPL 外部库；
将来扩充范围前务必先读 `LEGAL.md` §4 的红线清单。把本库用于产品时的
LGPL 合规清单见 `LEGAL.md` §2。

*依据 FFmpeg n9.0.2 源码树与 `LEGAL.md`（2026-10-21）编写；不是法律意见。*
