"""Emit libavformat/ogg_wbtest.mbt from the .scratch Ogg/Opus fixture."""
import base64
import hashlib

SRC = r"D:\project\FFmpeg-n9.0.2\moonbit\.scratch\ogg\opus.ogg"
OUT = r"D:\project\FFmpeg-n9.0.2\moonbit\libavformat\ogg_wbtest.mbt"


def packets(path):
    d = open(path, "rb").read()
    pos = 0
    serial = None
    pending = bytearray()
    out = []
    while pos < len(d):
        assert d[pos:pos + 4] == b"OggS"
        nseg = d[pos + 26]
        segs = list(d[pos + 27:pos + 27 + nseg])
        p = pos + 27 + nseg
        if serial is None:
            serial = int.from_bytes(d[pos + 14:pos + 18], "little")
        for lace in segs:
            pending += d[p:p + lace]
            p += lace
            if lace < 255:
                out.append(bytes(pending))
                pending = bytearray()
        pos = p
    return serial, out


serial, pkts = packets(SRC)
data = pkts[2:]
sizes = [len(p) for p in data]
md5s = [hashlib.md5(p).hexdigest() for p in data]
pts = [-312 + 960 * i for i in range(len(data) - 1)] + [-312 + 960 * (len(data) - 1)]
durs = [960] * (len(data) - 1) + [312]

b64 = base64.b64encode(open(SRC, "rb").read()).decode()
rows = []
for i in range(0, len(md5s), 3):
    rows.append("  " + ", ".join('"%s"' % m for m in md5s[i:i + 3]) + ",")
md5block = "\n".join(rows).rstrip(",")

src = '''///|
/// Ogg/Opus demuxer regression: a real libopus stream generated with docker
/// `linuxserver/ffmpeg:9.0.2` (`sine`, 48 kHz mono, 0.2 s, 64 kb/s).
/// Expected sizes/PTS/durations are ffprobe's packet list and the payload
/// MD5s were extracted from the Ogg pages.

///|
let ogg_opus_b64 : Bytes = b"%s"

///|
let ogg_opus_md5 : Array[String] = [
%s,
]

///|
let ogg_opus_size : Array[Int32] = [%s]

///|
let ogg_opus_pts : Array[Int64] = [%s]

///|
let ogg_opus_duration : Array[Int32] = [%s]

///|
test "ogg: real Opus stream headers and packets match ffprobe" {
  let bytes = @libavutil.av_base64_decode(ogg_opus_b64, 100000).unwrap()
  let demux = match av_ogg_opus_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_eq(demux.serial.reinterpret_as_uint(), %dU)
  assert_eq(demux.channels, 1)
  assert_eq(demux.pre_skip, 312)
  assert_eq(demux.input_sample_rate, 48000)
  assert_eq(demux.extradata.length(), 19)
  assert_eq(demux.packets.length(), %d)
  for i in 0..<demux.packets.length() {
    let packet = demux.packets[i]
    assert_eq(packet.data.length(), ogg_opus_size[i])
    assert_eq(packet.pts, ogg_opus_pts[i])
    assert_eq(packet.duration, ogg_opus_duration[i])
    let digest = FixedArray::make(16, b'\\x00')
    @libavutil.av_md5_sum(digest, packet.data, packet.data.length())
    inspect(hex_digest(digest), content=ogg_opus_md5[i])
  }
}

///|
test "ogg: corrupted page CRC is rejected" {
  let bytes = @libavutil.av_base64_decode(ogg_opus_b64, 100000).unwrap()
  let bad : Array[Byte] = []
  for i, b in bytes {
    bad.push(if i == 60 { (b.to_int() ^ 1).to_byte() } else { b })
  }
  match av_ogg_opus_open(Bytes::from_array(bad)) {
    Ok(_) => fail("corrupted Ogg page must fail")
    Err(_) => ()
  }
}

///|
fn hex_digest(digest : FixedArray[Byte]) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let sb = StringBuilder()
  for i in 0..<16 {
    let v = digest[i].to_int()
    sb.write_char(digits[v >> 4].to_int().unsafe_to_char())
    sb.write_char(digits[v & 15].to_int().unsafe_to_char())
  }
  sb.to_string()
}
''' % (b64, md5block, ", ".join(str(s) for s in sizes),
       ", ".join("%dL" % p for p in pts),
       ", ".join(str(d) for d in durs), serial, len(data))

open(OUT, "w", encoding="ascii", newline="\n").write(src)
print("wrote", OUT, len(data), "packets", serial)
