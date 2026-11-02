"""Emit the VP9 realdata fixture for libavcodec/vp9_realdata_vectors from
the .scratch IVF vectors and their framemd5 reference hashes.

Vectors are produced with docker `linuxserver/ffmpeg:9.0.2`:
  r1: testsrc2=128x96, crf 30, g=3, alt-ref off   (multi-P single-ref)
  r2: testsrc2=64x48,  crf 8,  g=2, alt-ref off   (dense keyframes, high q)
  r3: testsrc2=96x64,  crf 40, g=4, alt-ref on    (hidden frames + compound)

  ffmpeg -f lavfi -i <source> -frames:v <n> -c:v libvpx-vp9 -crf <q> -b:v 0 \
      -cpu-used 6 -g <g> -auto-alt-ref <0|1> -lag-in-frames <l> -threads 1 \
      -y <stem>.ivf
  ffmpeg -threads 1 -i <stem>.ivf -f framemd5 <stem>.md5
"""
import base64

OUTDIR = r"D:\project\FFmpeg-n9.0.2\moonbit\libavcodec\vp9_realdata_vectors"
SCRATCH = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch\vp9real"

STREAMS = [
    ("r1", "128x96 crf30 g=3 alt-ref off, 10 frames",
     "vp9 realdata: 128x96 multi-P session matches FFmpeg 9.0.2"),
    ("r2", "64x48 crf8 g=2 alt-ref off, 12 frames",
     "vp9 realdata: 64x48 high-quality dense-keyframe session matches FFmpeg 9.0.2"),
    ("r3", "96x64 crf40 g=4 alt-ref on, 12 displayed frames",
     "vp9 realdata: 96x64 alt-ref session with hidden frames matches FFmpeg 9.0.2"),
]

TEMPLATE = '''///|
/// libvpx-vp9 testsrc2, {desc}.  Reference: FFmpeg 9.0.2 native vp9
/// decoder framemd5 (-threads 1).  Reproduce with
/// scripts/emit_vp9_realdata_vectors.py.

///|
let {stem}_ivf_b64 : Bytes = b"{b64}"

///|
let {stem}_md5 : Array[String] = [
{md5rows}
]

///|
test "{testname}" {{
  let ivf = @libavutil.av_base64_decode({stem}_ivf_b64, 1000000).unwrap()
  let decoder = @libavcodec.vp9_decoder_new()
  let frames = vp9_ivf_frames(ivf)
  let mut shown = 0
  for i, payload in frames {{
    let output = decoder.decode_packet(payload).unwrap()
    for frame in output {{
      assert_true(shown < {stem}_md5.length())
      let hash = vp9_frame_md5(frame)
      assert_eq(
        hash,
        {stem}_md5[shown],
        msg="{stem} packet \\{{i}}: got \\{{hash}}, want \\{{{stem}_md5[shown]}}",
      )
      shown += 1
    }}
  }}
  assert_eq(shown, {stem}_md5.length())
}}
'''

blocks = []
for stem, desc, testname in STREAMS:
    data = open("%s\\%s.ivf" % (SCRATCH, stem), "rb").read()
    b64 = base64.b64encode(data).decode()
    md5 = [
        l.split(",")[-1].strip()
        for l in open("%s\\%s.md5" % (SCRATCH, stem))
        if l.strip() and not l.startswith("#")
    ]
    rows = []
    for i in range(0, len(md5), 3):
        rows.append("  " + ", ".join('"%s"' % m for m in md5[i:i + 3]) + ",")
    md5block = "\n".join(rows).rstrip(",")
    blocks.append(
        TEMPLATE.format(desc=desc, stem=stem, b64=b64, md5rows=md5block,
                        testname=testname)
    )
    print("wrote %s: %d bytes, %d md5s" % (stem, len(data), len(md5)))

path = "%s\\realdata_test.mbt" % OUTDIR
open(path, "w", encoding="ascii", newline="\n").write("".join(blocks))
print("wrote", path)
