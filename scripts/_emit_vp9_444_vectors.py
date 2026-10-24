"""Emit the profile-1/3 VP9 realdata wbtest from the .scratch IVF vectors
and their framemd5 reference hashes.

All streams share one base64 constant: adding one large literal per stream
pushes the package's wasm __init local count past the engine limit.
"""
import base64

OUTDIR = r"D:\project\FFmpeg-n9.0.2\moonbit\libavcodec\vp9_vectors"
SCRATCH = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch\vp9_444"

STREAMS = [
    ("vp9_444_8", "profile-1 8-bit 4:4:4 keyframe + P frames",
     "vp9 444 8-bit: profile-1 keyframes and P frames match FFmpeg YUV",
     "testsrc2=size=64x48:rate=30 -t 0.2 -vf format=yuv444p "
     "-c:v libvpx-vp9 -profile:v 1 -b:v 80k -g 3 -an -y vp9_444_8.ivf",
     "yuv444p"),
    ("vp9_422_8", "profile-1 8-bit 4:2:2 keyframe + P frames",
     "vp9 422 8-bit: profile-1 keyframes and P frames match FFmpeg YUV",
     "testsrc2=size=64x48:rate=30 -t 0.2 -vf format=yuv422p "
     "-c:v libvpx-vp9 -profile:v 1 -b:v 80k -g 3 -an -y vp9_422_8.ivf",
     "yuv422p"),
    ("vp9_444_10", "profile-3 10-bit 4:4:4 keyframe + P frames",
     "vp9 444 10-bit: profile-3 keyframes and P frames match FFmpeg YUV",
     "testsrc2=size=64x48:rate=30 -t 0.2 -vf format=yuv444p10le "
     "-c:v libvpx-vp9 -profile:v 3 -b:v 80k -g 3 -an -y vp9_444_10.ivf",
     "yuv444p10le"),
    ("vp9_444_12", "profile-3 12-bit 4:4:4 keyframe + P frames",
     "vp9 444 12-bit: profile-3 keyframes and P frames match FFmpeg YUV",
     "testsrc2=size=64x48:rate=30 -t 0.2 -vf format=yuv444p12le "
     "-c:v libvpx-vp9 -profile:v 3 -b:v 80k -g 3 -an -y vp9_444_12.ivf",
     "yuv444p12le"),
]


def md5s(stem):
    out = []
    for line in open("%s\\%s.md5" % (SCRATCH, stem)):
        if line.startswith("#") or not line.strip():
            continue
        out.append(line.strip().split(",")[-1].strip())
    return out


def rows(values):
    lines = []
    for i in range(0, len(values), 3):
        lines.append("  " + ", ".join('"%s"' % v for v in values[i:i + 3]) + ",")
    return "\n".join(lines).rstrip(",")


data = {stem: open("%s\\%s.ivf" % (SCRATCH, stem), "rb").read()
        for stem, *_ in STREAMS}
blob = b"".join(data[stem] for stem, *_ in STREAMS)
b64 = base64.b64encode(blob).decode()

stream_info = []
for stem, desc, testname, gen, pix_fmt in STREAMS:
    stream_info.append((stem, desc, testname, gen, pix_fmt, data[stem], md5s(stem)))

sizes = ", ".join(str(len(data[stem])) for stem, *_ in STREAMS)
desc_rows = "\n".join(
    "/// - `%s`: %s (%d bytes, %s)" % (stem, desc, len(data[stem]), pix_fmt)
    for stem, desc, _, _, pix_fmt, _, _ in stream_info)
md5_decls = []
for stem, _, _, _, _, _, hashes in stream_info:
    md5_decls.append("""///|
let %s_md5 : Array[String] = [
%s,
]""" % (stem, rows(hashes)))

tests = []
for index, (stem, _, testname, gen, _, _, hashes) in enumerate(stream_info):
    tests.append('''///|
test "%s" {
  let (frames, dec) = vp9_444_decode(%d)
  assert_eq(frames.length(), %s_md5.length())
  for i in 0..<frames.length() {
    let out = match dec.decode_packet(frames[i]) {
      Ok(fs) => fs
      Err(e) => fail("frame \\{i}: \\{e}")
    }
    assert_eq(out.length(), 1)
    inspect(vp9_444_frame_md5(dec), content=%s_md5[i])
  }
}''' % (testname, index, stem, stem))

src = '''///|
/// VP9 profile-1/3 real streams, generated with docker
/// `linuxserver/ffmpeg:9.0.2`.  Expected values are the reference decoder's
/// per-frame MD5s.
///
@@DESC@@
///
/// Reproduce each stream from its `testsrc2` pipeline in the stream list
/// above, then run `ffmpeg -threads 1 -i <stem>.ivf -f framemd5 <stem>.md5`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; the vectors are libre test data.

///|
/// base64 of the concatenated IVF files (@@NBYTES@@ bytes total). */
let vp9_444_vectors_b64 : Bytes = b"@@B64@@"

///|
/// IVF byte lengths of `vp9_444_vectors_b64`, in stream order. */
let vp9_444_sizes : Array[Int] = [@@SIZES@@]

///|
fn vp9_444_vectors() -> Bytes {
  @libavutil.av_base64_decode(vp9_444_vectors_b64, 1000000).unwrap()
}

///|
/// Split the concatenated blob into the IVF streams.
fn vp9_444_streams() -> Array[Bytes] {
  let all = vp9_444_vectors()
  let out : Array[Bytes] = []
  let mut off = 0
  for n in vp9_444_sizes {
    out.push(all[off:off + n].to_owned())
    off = off + n
  }
  out
}

///|
/// Split an IVF file into per-frame VP9 payloads (12-byte frame headers).
fn vp9_444_ivf_frames(ivf : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos < ivf.length() {
    let size = (ivf[pos].to_int() | (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16)) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }
  frames
}

///|
fn vp9_444_hex(bytes : FixedArray[Byte], n : Int32) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
fn vp9_444_frame_md5(dec : @libavcodec.Vp9Decoder) -> String {
  let yuv = dec.frame_bytes()
  let digest = FixedArray::make(16, b'\\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  vp9_444_hex(digest, 16)
}

///|
fn vp9_444_decode(index : Int) -> (Array[Bytes], @libavcodec.Vp9Decoder) {
  let streams = vp9_444_streams()
  (vp9_444_ivf_frames(streams[index]), @libavcodec.vp9_decoder_new())
}

@@MD5@@

@@TESTS@@
'''
src = (src.replace("@@DESC@@", desc_rows)
       .replace("@@NBYTES@@", str(len(blob)))
       .replace("@@B64@@", b64)
       .replace("@@SIZES@@", sizes)
       .replace("@@MD5@@", "\n\n".join(md5_decls))
       .replace("@@TESTS@@", "\n\n".join(tests)))

path = "%s\\vp9_444_test.mbt" % OUTDIR
open(path, "w", encoding="ascii", newline="\n").write(src)
print("wrote", path, len(blob), "bytes,", sum(len(md5s(s)) for s, *_ in STREAMS), "md5s")
