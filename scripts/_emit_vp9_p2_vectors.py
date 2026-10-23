"""Emit the profile-2 (10/12-bit) VP9 realdata wbtests from the .scratch
IVF vectors and their framemd5 reference hashes."""
import base64

OUTDIR = r"D:\project\FFmpeg-n9.0.2\moonbit\libavcodec"
SCRATCH = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch"

STREAMS = [
    ("vp9_10p", "10-bit keyframe + inter frames",
     "vp9 10p: profile-2 keyframe + 14 P frames match FFmpeg YUV",
     "testsrc2=size=160x120:rate=30 -t 0.5 -c:v libvpx-vp9 -profile 2 \\\n"
     "       -pix_fmt yuv420p10le -b:v 250k -an -y vp9_10p.ivf"),
    ("vp9_10np", "10-bit non-parallel stream (counts-driven adaptation)",
     "vp9 10np: profile-2 adaptation stream matches FFmpeg YUV",
     "testsrc2=size=160x120:rate=30 -t 0.7 -c:v libvpx-vp9 -profile 2 \\\n"
     "       -pix_fmt yuv420p10le -b:v 250k -g 12 -keyint_min 6 \\\n"
     "       -frame-parallel 0 -an -y vp9_10np.ivf"),
    ("vp9_12p", "12-bit keyframe + inter frames",
     "vp9 12p: profile-2 12-bit keyframe + P frames match FFmpeg YUV",
     "testsrc2=size=160x120:rate=30 -t 0.3 -c:v libvpx-vp9 -profile 2 \\\n"
     "       -pix_fmt yuv420p12le -b:v 250k -g 6 -an -y vp9_12p.ivf"),
]

TEMPLATE = '''///|
/// {desc}, generated with docker `linuxserver/ffmpeg:9.0.2`.  Expected
/// values are the reference decoder's per-frame yuv420p{{depth}}le MD5s
/// (little-endian 16-bit samples).
///
/// Reproduce with:
/// ```text
/// ffmpeg -f lavfi -i {gen}
/// ffmpeg -threads 1 -i {stem}.ivf -f framemd5 {stem}.md5
/// ```
///
/// Original FFmpeg code is LGPL-2.1-or-later; the vectors are libre test data.

///|
/// base64 of the reference `{stem}.ivf` ({{nbytes}} bytes). */
let {stem}_ivf_b64 : Bytes = b"{b64}"

///|
fn {stem}_ivf_bytes() -> Bytes {{
  @libavutil.av_base64_decode({stem}_ivf_b64, 1000000).unwrap()
}}

///|
/// Split an IVF file into per-frame VP9 payloads (12-byte frame headers).
fn {stem}_ivf_frames(ivf : Bytes) -> Array[Bytes] {{
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
let {stem}_md5 : Array[String] = [
{md5rows},
]

///|
test "{testname}" {{
  let dec = vp9_decoder_new()
  let frames = {stem}_ivf_frames({stem}_ivf_bytes())
  assert_eq(frames.length(), {stem}_md5.length())
  for i in 0..<frames.length() {{
    let out = match dec.decode_packet(frames[i]) {{
      Ok(fs) => fs
      Err(e) => fail("frame \\{{i}}: \\{{e}}")
    }}
    assert_eq(out.length(), 1)
    inspect(vp9_kf_frame_md5(dec), content={stem}_md5[i])
  }}
}}
'''

for stem, desc, testname, gen in STREAMS:
    data = open("%s\\%s.ivf" % (SCRATCH, stem), "rb").read()
    b64 = base64.b64encode(data).decode()
    md5 = [l.strip() for l in open("%s\\%s.md5" % (SCRATCH, stem)) if l.strip()]
    rows = []
    for i in range(0, len(md5), 3):
        rows.append("  " + ", ".join('"%s"' % m for m in md5[i:i + 3]) + ",")
    md5block = "\n".join(rows).rstrip(",")
    depth = 12 if "12p" in stem else 10
    src = TEMPLATE.format(desc=desc, gen=gen, stem=stem, b64=b64,
                          md5rows=md5block, testname=testname,
                          nbytes=len(data), depth=depth)
    path = "%s\\%s_realdata_wbtest.mbt" % (OUTDIR, stem)
    open(path, "w", encoding="ascii", newline="\n").write(src)
    print("wrote", path, len(data), "bytes,", len(md5), "md5s")
