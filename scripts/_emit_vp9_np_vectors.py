"""Emit `vp9_np_realdata_wbtest.mbt`: embed the non-frame-parallel
(multi-reference, counts-driven adaptation) VP9 IVF stream and its
per-frame reference MD5s.

Reproduce the vector with:
  ffmpeg -f lavfi -i testsrc2=size=160x120:rate=30 -t 0.7 \
         -c:v libvpx-vp9 -b:v 250k -g 12 -keyint_min 6 -frame-parallel 0 \
         -an -y vp9_np.ivf
  ffmpeg -threads 1 -i vp9_np.ivf -f framemd5 -
"""
import base64
import subprocess
import sys

IVF = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch\vp9_np.ivf"
OUT = r"D:\project\FFmpeg-n9.0.2\moonbit\libavcodec\vp9_np_realdata_wbtest.mbt"

data = open(IVF, "rb").read()
b64 = base64.b64encode(data).decode()

# reference per-frame MD5s from docker ffmpeg 9.0.2 (framemd5, yuv420p)
md5 = [
    "b84238e63cc61744a62efb0c925f370e", "69c4e2a7bd45e9158f2863282f0311c2",
    "cb5db82921cfeeedfe0ef150c99f5957", "64ded86b19b219646c9dcb56b17896c6",
    "b53b28d11811a6b46c242c229a4da5e6", "c67497ab1e5660ebf4bfae5861373f77",
    "fae082a0d9087d79e0e939a95b5a50a3", "6afb406f1ed481977f6c4fee3d6271ff",
    "35c5bf71753cc85277a124f8329f621d", "45c852c1a5e87b18802b86ef67572f46",
    "911193275e93ff0d4b5501785f5f5c35", "e21125fcf45998208e8b4ea92df7cb5e",
    "4d22a86143552eb501adb70c3be29c55", "297a8f5d3293d82820ab88a266cf3098",
    "6ed4078f2463327e163c32fbe303e5fe", "49604b0930b800f4af4e4717fd5ed6c1",
    "2d4b5c5563a9088c6f02c13ace1447d9", "01335d56280787376d49f097ad9151c3",
    "4b5b511690d62ebbc86d2bc3353a6594", "13a645659e57371e85b1fa5d64a03504",
    "077b2f792fcf3c0b51817e75ce515750",
]

md5_rows = []
for i in range(0, len(md5), 3):
    md5_rows.append("  " + ", ".join(f'"{m}"' for m in md5[i:i + 3]) + ",")
md5_block = "\n".join(md5_rows)
if md5_rows:
    md5_block = md5_block.rstrip(",")

b64_rows = []
for i in range(0, len(b64), 100):
    b64_rows.append(b64[i:i + 100])
# one single-line b"..." literal (the established vector style; multi-line
# continuation would need a b-prefix on every row)
b64_lit = 'b"' + b64 + '"'

src = f'''///|
/// VP9 non-frame-parallel real-world vector: one keyframe + 20 inter
/// frames (libvpx-vp9, 160x120, `-frame-parallel 0`), generated with
/// docker `linuxserver/ffmpeg:9.0.2`.  Exercises the counts-driven
/// probability adaptation path (`refreshctx && !parallelmode`) and all
/// three references (last/gold/altref).  Expected values are the
/// reference decoder's per-frame yuv420p MD5s over the same bytes.
///
/// Reproduce with:
/// ```text
/// ffmpeg -f lavfi -i testsrc2=size=160x120:rate=30 -t 0.7 \\
///        -c:v libvpx-vp9 -b:v 250k -g 12 -keyint_min 6 -frame-parallel 0 \\
///        -an -y vp9_np.ivf
/// ffmpeg -threads 1 -i vp9_np.ivf -f framemd5 vp9_np.md5
/// ```
///
/// Original FFmpeg code is LGPL-2.1-or-later; the vectors are libre test data.

///|
/// base64 of the reference `vp9_np.ivf` ({len} bytes). */
let vp9_np_ivf_b64 : Bytes = {b64_lit}

///|
fn vp9_np_ivf_bytes() -> Bytes {{
  @libavutil.av_base64_decode(vp9_np_ivf_b64, 1000000).unwrap()
}}

///|
/// Split an IVF file into per-frame VP9 payloads (12-byte frame headers).
fn vp9_np_ivf_frames(ivf : Bytes) -> Array[Bytes] {{
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos < ivf.length() {{
    let size = (ivf[pos].to_int() | (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16)) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }}
  frames
}}

///|
let vp9_np_md5 : Array[String] = [
{md5_block},
]

///|
/// Decode the non-parallel stream and compare every frame's YUV MD5 with
/// the reference decoder.  Covers multi-reference inter blocks and the
/// per-frame probability back-adaptation (`adapt_probs`) instead of the
/// parallel-mode commit used by the earlier inter vector.
test "vp9 np: keyframe + 20 inter frames with adaptation match FFmpeg YUV" {{
  let dec = vp9_decoder_new()
  let frames = vp9_np_ivf_frames(vp9_np_ivf_bytes())
  assert_eq(frames.length(), vp9_np_md5.length())
  for i in 0..<frames.length() {{
    let out = match dec.decode_packet(frames[i]) {{
      Ok(fs) => fs
      Err(e) => fail("frame \\{{i}}: \\{{e}}")
    }}
    assert_eq(out.length(), 1)
    inspect(vp9_kf_frame_md5(dec), content=vp9_np_md5[i])
  }}
}}
'''

open(OUT, "w", encoding="ascii", newline="\n").write(src)
print("wrote", OUT, len(data), "bytes ivf,", len(md5), "md5s")
