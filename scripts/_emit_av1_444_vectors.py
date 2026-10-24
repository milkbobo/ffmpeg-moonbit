"""Emit the AV1 4:4:4 / 4:2:2 lossless keyframe realdata test from the
.scratch IVF vectors and their libdav1d framemd5 reference hashes."""
import base64

OUTDIR = r"D:\project\FFmpeg-n9.0.2\moonbit\libavcodec\av1_vectors"
SCRATCH = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch\av1_444"

STREAMS = [
    ("av1_444", "8-bit 4:4:4 lossless keyframes", "yuv444p",
     "testsrc2=size=64x48:rate=30 -t 0.3 -vf format=yuv444p "
     "-c:v libaom-av1 -crf 0 -cpu-used 8 -g 1 -an -y av1_444.ivf"),
    ("av1_422", "8-bit 4:2:2 lossless keyframes", "yuv422p",
     "testsrc2=size=64x48:rate=30 -t 0.3 -vf format=yuv422p "
     "-c:v libaom-av1 -crf 0 -cpu-used 8 -g 1 -an -y av1_422.ivf"),
]


def md5s(stem):
    out = []
    for line in open("%s\\%s.md5" % (SCRATCH, stem)):
        parts = line.strip().split(",")
        if len(parts) >= 5 and parts[0] == "0":
            out.append(parts[-1].strip())
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
sizes = ", ".join(str(len(data[stem])) for stem, *_ in STREAMS)

desc = "\n".join(
    "/// - `%s`: %s (%s, %d bytes)" % (stem, text, pix, len(data[stem]))
    for stem, text, pix, _ in STREAMS)
md5_decls = "\n\n".join("""///|
let %s_md5 : Array[String] = [
%s,
]""" % (stem, rows(md5s(stem))) for stem, *_ in STREAMS)

tests = []
for index, (stem, stream_desc, _, _) in enumerate(STREAMS):
    tests.append('''///|
test "%s: %s match libdav1d framemd5" {
  let frames = av1_444_ivf_frames(av1_444_streams()[%d])
  assert_eq(frames.length(), %s_md5.length())
  let mut seq : @libavcodec.Av1SequenceParameters? = None
  for i in 0..<frames.length() {
    let obus = frames[i]
    if seq is None {
      let parsed = match @libavcodec.av1_parse_sequence_header(obus) {
        Ok(v) => v
        Err(e) => fail("frame \\{i}: sequence header: \\{e}")
      }
      seq = Some(parsed)
    }
    let s = seq.unwrap()
    let hdr = match @libavcodec.av1_parse_frame_header(obus, s) {
      Ok(v) => v
      Err(e) => fail("frame \\{i}: frame header: \\{e}")
    }
    let tiles = match @libavcodec.av1_extract_tiles(obus, hdr) {
      Ok(v) => v
      Err(e) => fail("frame \\{i}: tiles: \\{e}")
    }
    let out = match @libavcodec.av1_decode_keyframe(s, hdr, tiles[0].data()) {
      Ok(v) => v
      Err(e) => fail("frame \\{i}: decode: \\{e}")
    }
    inspect(av1_444_frame_md5(out.packed()), content=%s_md5[i])
  }
}''' % (stem, stream_desc, index, stem, stem))

src = '''///|
/// AV1 lossless keyframe real streams for 4:4:4 and 4:2:2, generated with
/// docker `linuxserver/ffmpeg:9.0.2`.  Expected values are libdav1d's
/// per-frame framemd5 hashes.
///
@@DESC@@
///
/// Reproduce each stream from its `testsrc2` pipeline in the stream list
/// above, then run `ffmpeg -threads 1 -i <stem>.ivf -f framemd5 <stem>.md5`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; the vectors are libre test data.

///|
/// base64 of the concatenated IVF files (@@NBYTES@@ bytes total). */
let av1_444_vectors_b64 : Bytes = b"@@B64@@"

///|
/// IVF byte lengths of `av1_444_vectors_b64`, in stream order. */
let av1_444_sizes : Array[Int] = [@@SIZES@@]

///|
fn av1_444_vectors() -> Bytes {
  @libavutil.av_base64_decode(av1_444_vectors_b64, 1000000).unwrap()
}

///|
fn av1_444_streams() -> Array[Bytes] {
  let all = av1_444_vectors()
  let out : Array[Bytes] = []
  let mut off = 0
  for n in av1_444_sizes {
    out.push(all[off:off + n].to_owned())
    off = off + n
  }
  out
}

///|
/// IVF: 32-byte header, then per frame a 12-byte header and the OBU payload.
fn av1_444_ivf_frames(ivf : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos + 12 <= ivf.length() {
    let size = (ivf[pos].to_int() | (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16)) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }
  frames
}

///|
fn av1_444_hex(digest : FixedArray[Byte]) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i in 0..<16 {
    let v = digest[i].to_uint().reinterpret_as_int()
    chars.push(digits[v >> 4].to_char())
    chars.push(digits[v & 15].to_char())
  }
  String::from_array(chars[:])
}

///|
fn av1_444_frame_md5(packed : Bytes) -> String {
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\\x00')
  @libavutil.av_md5_sum(digest, packed, packed.length())
  av1_444_hex(digest)
}

@@MD5@@

@@TESTS@@
'''
src = (src.replace("@@DESC@@", desc)
       .replace("@@NBYTES@@", str(len(blob)))
       .replace("@@B64@@", b64)
       .replace("@@SIZES@@", sizes)
       .replace("@@MD5@@", md5_decls)
       .replace("@@TESTS@@", "\n\n".join(tests)))

path = "%s\\av1_444_test.mbt" % OUTDIR
open(path, "w", encoding="ascii", newline="\n").write(src)
print("wrote", path, len(blob), "bytes,", sum(len(md5s(s)) for s, *_ in STREAMS), "md5s")
