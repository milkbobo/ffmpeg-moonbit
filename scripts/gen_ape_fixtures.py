# Generate libavcodec/ape_realdata_*_wbtest.mbt fixtures from the FATE APE
# samples downloaded into .scratch/ape_dl (see the file headers for the
# regeneration commands).
#
# Inputs per sample: <name>.ape, <name>.packets (-c copy -f data dump),
# <name>.sizes (ffprobe packet sizes, space separated) and <name>.pcm
# (the docker ffmpeg decode: s16le, or s32le for 24-bit streams).
#
# The APE header parsing mirrors libavformat/ape.c so the extradata bytes
# (fileversion/compressiontype/formatflags) match what FFmpeg hands the
# decoder.  PCM alignment is cross-checked against the nblocks field of each
# packet before any MD5 is emitted.
#
# Usage: python -I scripts/gen_ape_fixtures.py .scratch/ape_dl libavcodec
import base64
import hashlib
import struct
import sys

SAMPLES = [
    # (tag, file stem, packets to embed, pcm format)
    ("v380", "luckynight-mac380-c2000", 4, "s16le"),
    ("v388", "luckynight-mac388-c2000", 4, "s16le"),
    ("v389", "luckynight-mac389b1-c2000", 4, "s16le"),
    ("v388c4", "luckynight-mac388-c4000", 1, "s16le"),
    ("v391", "luckynight-mac391b1-c2000", 1, "s16le"),
    ("v394c2", "luckynight-mac394b1-c2000", 1, "s16le"),
    ("v394c4", "luckynight-mac394b1-c4000", 1, "s16le"),
    ("v399", "luckynight-partial", 1, "s16le"),
    ("v24", "NoLegacy-cut", 1, "s32le"),
]


def parse_header(data):
    assert data[0:4] == b"MAC ", "bad magic"
    version = struct.unpack_from("<H", data, 4)[0]
    if version >= 3980:
        # ape.c >= 3980 layout: descriptor (52 B incl. md5) then the
        # header block at 52: comp/flags, blocksperframe, finalframeblocks,
        # totalframes, bps, channels, samplerate.
        comp = struct.unpack_from("<H", data, 52)[0]
        flags = struct.unpack_from("<H", data, 54)[0]
        bps = struct.unpack_from("<H", data, 68)[0]
        channels = struct.unpack_from("<H", data, 70)[0]
    else:
        comp = struct.unpack_from("<H", data, 6)[0]
        flags = struct.unpack_from("<H", data, 8)[0]
        channels = struct.unpack_from("<H", data, 10)[0]
        # MAC_FORMAT_FLAG_8_BIT = 1, MAC_FORMAT_FLAG_24_BIT = 8.
        if flags & 1:
            bps = 8
        elif flags & 8:
            bps = 24
        else:
            bps = 16
    return version, comp, flags, bps, channels


def b64_lines(blob, per_line=100):
    text = base64.b64encode(blob).decode("ascii")
    lines = []
    for i in range(0, len(text), per_line):
        lines.append('  b"' + text[i : i + per_line] + '"')
    return " +\n".join(lines)


TEMPLATE = '''///|
/// Real-data APE decode test: `{stem}` from the FFmpeg FATE suite
/// (fileversion {version}, compression {comp}, flags {flags}, {bps}-bit,
/// {channels} ch; {npkt} packet(s), {total_samples} interleaved samples).
///
/// Regeneration (host + docker linuxserver/ffmpeg:9.0.2, samples in
/// `.scratch/ape_dl`, inside the container at /s):
///   curl -sSL -o {stem}.ape \\\\
///     https://fate-suite.ffmpeg.org/lossless-audio/{stem}.ape
///   ffprobe -v error -select_streams a -show_entries packet=size \\\\
///     -of csv=p=0 /s/{stem}.ape | tr "\\n" " " > /s/{stem}.sizes
///   ffmpeg -v error -y -i /s/{stem}.ape -map 0:a:0 -c copy -f data /s/{stem}.packets
///   ffmpeg -v error -y -i /s/{stem}.ape -f {pcmfmt} /s/{stem}.pcm
///   python -I scripts/gen_ape_fixtures.py .scratch/ape_dl libavcodec
/// Expected PCM is the docker FFmpeg 9.0.2 decode (lossless: bit-exact MD5;
/// the first four interleaved samples are pinned as spot values).

///|
let ape_{tag}_extradata : Bytes = b"{extradata}"

///|
let ape_{tag}_sizes : Array[Int32] = [{sizes}]

///|
let ape_{tag}_truncated : Bool = {truncated}

///|
let ape_{tag}_pcm_md5 : String = "{md5}"

///|
let ape_{tag}_pcm_bytes : Int32 = {pcm_bytes}

///|
let ape_{tag}_spots : Array[Int32] = [{spots}]

///|
let ape_{tag}_packets_b64 : Bytes =
{b64}

///|
fn ape_{tag}_md5(data : Bytes) -> String {{
  let md5 = @libavutil.av_md5_alloc()
  @libavutil.av_md5_init(md5)
  @libavutil.av_md5_update(md5, data, data.length())
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\\x00')
  @libavutil.av_md5_final(md5, digest)
  let h = "0123456789abcdef"
  let mut out = ""
  for b in digest {{
    let v = b.to_int()
    out = out +
      h.get_char((v >> 4) & 15).unwrap().to_string() +
      h.get_char(v & 15).unwrap().to_string()
  }}
  out
}}

///|
test "APE: {tag} real packets match FFmpeg PCM" {{
  let dec = ape_decoder_new(ape_{tag}_extradata, {channels}, {bps}).unwrap()
  let blob = @libavutil.av_base64_decode(ape_{tag}_packets_b64, 1 << 24).unwrap()
  let out : Array[Byte] = []
  let mut pos = 0
  for _, sz in ape_{tag}_sizes {{
    let pkt = blob.clamped_view(start=pos, end=pos + sz).to_owned()
    pos = pos + sz
    // Feed the packet until the decoder reports it fully consumed, exactly
    // like the decode API loop around ape_decode_frame (blocks_per_loop
    // chunking).  Truncated FATE cuts end in a decode error after the last
    // clean chunk, matching the ffmpeg reference decode.
    let mut done = false
    while !done {{
      match dec.decode_frame(pkt) {{
        Ok(chunk) => {{
          for v in chunk.frame.samples {{
            out.push((v & 0xFF).to_byte())
            out.push(((v >> 8) & 0xFF).to_byte())
            if {wide} {{
              out.push(((v >> 16) & 0xFF).to_byte())
              out.push(((v >> 24) & 0xFF).to_byte())
            }}
          }}
          done = chunk.packet_done
        }}
        Err(e) => {{
          if !ape_{tag}_truncated {{
            fail("decode error: \\{{e}}")
          }}
          done = true
        }}
      }}
    }}
  }}
  let bytes = Bytes::from_array(out)
  inspect(bytes.length(), content=ape_{tag}_pcm_bytes.to_string())
  let got = ape_{tag}_md5(bytes)
  if got != ape_{tag}_pcm_md5 {{
    fail("PCM MD5 mismatch: got \\{{got}} want \\{{ape_{tag}_pcm_md5}}")
  }}
  for i = 0; i < 4; i = i + 1 {{
    let v = if {wide} {{
      let b0 = bytes[i * 4].to_uint().reinterpret_as_int()
      let b1 = bytes[i * 4 + 1].to_uint().reinterpret_as_int()
      let b2 = bytes[i * 4 + 2].to_uint().reinterpret_as_int()
      let b3 = bytes[i * 4 + 3].to_uint().reinterpret_as_int()
      b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }} else {{
      let lo = bytes[i * 2].to_uint().reinterpret_as_int()
      let hi = bytes[i * 2 + 1].to_uint().reinterpret_as_int()
      let s = lo | (hi << 8)
      if (s & 0x8000) != 0 {{ s - 65536 }} else {{ s }}
    }}
    inspect(v, content=ape_{tag}_spots[i].to_string())
  }}
}}
'''


def main():
    indir, outdir = sys.argv[1], sys.argv[2]
    for tag, stem, npkt, pcmfmt in SAMPLES:
        ape = open(f"{indir}/{stem}.ape", "rb").read()
        version, comp, flags, bps, channels = parse_header(ape)
        sizes = [int(x) for x in open(f"{indir}/{stem}.sizes").read().split()]
        packets_bytes = open(f"{indir}/{stem}.packets", "rb").read()
        pcm = open(f"{indir}/{stem}.pcm", "rb").read()
        assert sum(sizes) == len(packets_bytes), (stem, sum(sizes), len(packets_bytes))
        packets = []
        off = 0
        for sz in sizes:
            packets.append(packets_bytes[off : off + sz])
            off += sz
        chosen = packets[:npkt]
        nblocks = [struct.unpack("<I", p[0:4])[0] for p in chosen]
        per_sample = channels * (bps // 8)
        # Truncated FATE cuts (NoLegacy-cut): ffmpeg's default chunked decode
        # emits the clean 4608-sample blocks and then errors mid-frame, so
        # the reference PCM is shorter than the packet's declared nblocks.
        truncated = len(pcm) < nblocks[0] * per_sample
        want = len(pcm) if truncated else sum(nblocks) * per_sample
        assert len(pcm) >= want, (stem, len(pcm), want)
        slice_ = pcm[:want]
        md5 = hashlib.md5(slice_).hexdigest()
        if pcmfmt == "s16le":
            spots = list(struct.unpack_from("<4h", slice_, 0))
            spots += list(struct.unpack_from("<2h", slice_, len(slice_) - 4))
        else:
            spots = list(struct.unpack_from("<4i", slice_, 0))
            spots += list(struct.unpack_from("<2i", slice_, len(slice_) - 8))
        extradata = struct.pack("<HHH", version, comp, flags)
        body = TEMPLATE.format(
            tag=tag,
            stem=stem,
            version=version,
            comp=comp,
            flags=flags,
            bps=bps,
            channels=channels,
            npkt=npkt,
            total_samples=want // (channels * (bps // 8)),
            truncated="true" if truncated else "false",
            extradata="".join("\\x%02x" % b for b in extradata),
            sizes=", ".join(str(s) for s in sizes[:npkt]),
            md5=md5,
            pcm_bytes=len(slice_),
            spots=", ".join(str(v) for v in spots),
            b64=b64_lines(b"".join(chosen)),
            wide="true" if pcmfmt == "s32le" else "false",
            pcmfmt=pcmfmt,
        )
        out = f"{outdir}/ape_realdata_{tag}_wbtest.mbt"
        with open(out, "w", newline="\n") as f:
            f.write(body)
        print(f"{out}: {sum(sizes[:npkt])} packet bytes, pcm {want} B, md5 {md5}")


main()
