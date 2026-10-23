#!/usr/bin/env python3
# Emit libavcodec/opus_silk_realdata_wbtest.mbt from the libopus streams and
# framemd5 references under C:\Users\milkb\AppData\Local\Temp\opuss\vec.
#
# Streams: linuxserver/ffmpeg:9.0.2 (libopus), tone+pink noise, 2 s,
#   -application voip -vbr on (CBR variant -vbr off, FEC variant -fec 1
#   -packet_loss 15). Reference: FFmpeg 9.0.2 built with --disable-asm
#   (assembly-free scalar path; the x86 resample kernels use FMA and produce
#   different low float bits), decoded with -c:a pcm_f32le -f framemd5.
#   framemd5 hashes the interleaved f32le frames after the CLI applied the
#   OpusHead pre-skip; the final frame is the decoder drain.
#
# The test decodes packet-by-packet with OpusDecoder, drops pre_skip samples
# from the concatenated output, re-segments by the reference frame sizes and
# compares per-frame MD5s. LGPL-2.1-or-later.
import base64
import struct
import sys
import os

VEC_DIR = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\milkb\AppData\Local\Temp\opuss\vec"
OUT = os.path.join(os.path.dirname(__file__), "..", "libavcodec", "opus_silk_realdata_wbtest.mbt")

FILES = [
    # name, description
    ("silk_nb10", "NB 10 ms VBR (config 0)"),
    ("silk_nb20", "NB 20 ms VBR (config 1)"),
    ("silk_nb20cbr", "NB 20 ms CBR, code-3 multi-frame lacing (config 1)"),
    ("silk_wb20", "WB 20 ms VBR (config 9)"),
    ("silk_wb40", "WB 40 ms superframe (config 10)"),
    ("silk_wb40fec", "WB 40 ms with inband FEC/LBRR (config 10)"),
    ("silk_wb60", "WB 60 ms superframe (config 11)"),
    ("silk_st20", "stereo WB 20 ms (config 9, stereo)"),
    ("silk_st60", "stereo WB 60 ms, mid-only side channel (config 11, stereo)"),
]
HYBRID_FILES = [
    ("hyb_fb20", "hybrid fullband 20 ms (config 15)"),
    ("hyb_st20", "stereo hybrid fullband 20 ms (config 15, stereo)"),
]


def ogg_packets(path):
    packets = []
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    current = None
    while pos < len(data):
        if data[pos:pos + 4] != b"OggS":
            pos += 1
            continue
        segcount = data[pos + 26]
        segtable = data[pos + 27:pos + 27 + segcount]
        p = pos + 27 + segcount
        for seg in segtable:
            if current is None:
                current = bytearray()
            current += data[p:p + seg]
            p += seg
            if seg < 255:
                packets.append(bytes(current))
                current = None
        pos = p
    return packets


def coef_md5s(path):
    """Per-frame MD5 of the denormalized CELT coefficients (interleaved f32
    bits across channels), from the instrumented dec_celt dump."""
    import hashlib
    out = []
    for line in open(path):
        line = line.strip()
        if not line.startswith("COEF "):
            continue
        h = hashlib.md5()
        for token in line.split()[3:]:
            h.update(int(token).to_bytes(4, "little"))
        out.append(h.hexdigest())
    return out


def framemd5_lines(path):
    sizes = []
    md5s = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("0,"):
                continue
            fields = [x.strip() for x in line.split(",")]
            sizes.append(int(fields[3]))
            md5s.append(fields[5])
    return sizes, md5s


def main():
    out = []
    out.append("///|")
    out.append("/// FFmpeg 9.0.2 Opus SILK/hybrid end-to-end vectors. Streams encoded by")
    out.append("/// libopus (linuxserver/ffmpeg:9.0.2, tone + pink noise, voip); reference")
    out.append("/// MD5s from the assembly-free FFmpeg 9.0.2 build (see")
    out.append("/// scripts/emit_opus_silk_vectors.py for generation commands). framemd5")
    out.append("/// covers interleaved f32le frames after the 312-sample pre-skip, with")
    out.append("/// the resampler drain as the final frame. Regenerate with")
    out.append("/// scripts/emit_opus_silk_vectors.py. LGPL-2.1-or-later.")
    cases = []
    index_lines = []
    for fi, (name, desc) in enumerate(FILES):
        path = os.path.join(VEC_DIR, name + ".opus")
        packets = ogg_packets(path)
        head = packets[0]
        pre_skip = struct.unpack("<H", head[10:12])[0]
        media = b"".join(packets[2:])
        sizes, md5s = framemd5_lines(os.path.join(VEC_DIR, name + ".md5"))
        assert len(sizes) == len(md5s) and len(sizes) > 0
        sizes_pkts = [len(p) for p in packets[2:]]
        const = "opus_silk_%s_b64" % name
        out.append("///|")
        out.append("/// %s: %d packets, pre-skip %d, %d reference frames." % (desc, len(packets) - 2, pre_skip, len(sizes)))
        out.append("let %s : String =" % const)
        b64 = base64.b64encode(media).decode()
        for i in range(0, len(b64), 100):
            piece = b64[i:i + 100]
            tail = "" if i + 100 < len(b64) else ""
            out.append('  "%s"%s' % (piece, (" +" if i + 100 < len(b64) else "")))
        head_const = "opus_silk_%s_head_b64" % name
        out.append("///|")
        out.append("let %s : String = \"%s\"" % (head_const, base64.b64encode(head).decode()))
        cases.append((name, const, head_const, sizes_pkts, sizes, md5s, pre_skip))
    # Hybrid cases: per-frame MD5s of the denormalized CELT coefficients
    # (bit-exact pipeline through syntax/energy/allocation/PVQ/denormalize).
    out.append("///|")
    out.append("/// Hybrid cases: (name, packets b64, head b64, packet byte lengths,")
    out.append("/// per-frame denormalized-coefficient MD5s). The coefficients are the")
    out.append("/// CELT frame's spectral state before synthesis, dumped per frame from")
    out.append("/// the instrumented dec_celt.c (COEF lines of scripts/opus_dec_reference.c")
    out.append("/// runs; see agent.md for the patch). The synthesis stage is covered by")
    out.append("/// the established CELT PCM tolerance tests.")
    hybrid_table = []
    for name, desc in HYBRID_FILES:
        pathv = os.path.join(VEC_DIR, name + ".opus")
        packets = ogg_packets(pathv)
        head = packets[0]
        media = b"".join(packets[2:])
        sizes_pkts = [len(p) for p in packets[2:]]
        md5s = coef_md5s(os.path.join(VEC_DIR, name + "_coef.txt"))
        const = "opus_hybrid_%s_b64" % name
        head_const = "opus_hybrid_%s_head_b64" % name
        out.append("///|")
        out.append("/// %s: %d packets, %d coefficient frames." % (desc, len(packets) - 2, len(md5s)))
        out.append("let %s : String =" % const)
        b64 = base64.b64encode(media).decode()
        for i in range(0, len(b64), 100):
            out.append('  "%s"%s' % (b64[i:i + 100], (" +" if i + 100 < len(b64) else "")))
        out.append("///|")
        out.append('let %s : String = "%s"' % (head_const, base64.b64encode(head).decode()))
        hybrid_table.append("  (")
        hybrid_table.append('    "%s",' % name)
        hybrid_table.append("    %s," % const)
        hybrid_table.append("    %s," % head_const)
        hybrid_table.append("    [%s]," % ", ".join(str(s) for s in sizes_pkts))
        md5_chunks = []
        line = "    ["
        for m in md5s:
            piece = '"%s",' % m
            if len(line) + len(piece) > 96:
                md5_chunks.append(line.rstrip())
                line = "     "
            line += piece
        line = line.rstrip().rstrip(",") + "],"
        md5_chunks.append(line)
        hybrid_table.extend(md5_chunks)
        hybrid_table.append("  ),")
    out.append("let opus_hybrid_coef_cases : Array[(String, String, String, Array[Int], Array[String])] = [")
    out.extend(hybrid_table)
    out.append("]")
    # Emit the case table with sizes and md5 lists.
    out.append("///|")
    out.append("/// (name, packets b64, head b64, packet byte lengths, per-frame sizes,")
    out.append("/// per-frame md5).")
    out.append("let opus_silk_cases : Array[(String, String, String, Array[Int], Array[Int], Array[String])] = [")
    for name, const, head_const, sizes_pkts, sizes, md5s, _ in cases:
        out.append("  (")
        out.append('    "%s",' % name)
        out.append("    %s," % const)
        out.append("    %s," % head_const)
        out.append("    [%s]," % ", ".join(str(s) for s in sizes_pkts))
        out.append("    [%s]," % ", ".join(str(s) for s in sizes))
        md5_chunks = []
        line = "    ["
        for m in md5s:
            piece = '"%s",' % m
            if len(line) + len(piece) > 96:
                md5_chunks.append(line.rstrip())
                line = "     "
            line += piece
        line = line.rstrip().rstrip(",") + "],"
        md5_chunks.append(line)
        out.extend(md5_chunks)
        out.append("  ),")
    out.append("]")
    with open(OUT, "wb") as f:
        f.write(("\n".join(out) + "\n").encode("utf-8"))
    total = sum(len(m) for _, _, _, _, _, m, _ in cases)
    print("wrote %s: %d cases, %d reference frames" % (OUT, len(cases), total))


if __name__ == "__main__":
    main()
