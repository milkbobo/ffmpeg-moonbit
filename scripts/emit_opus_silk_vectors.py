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
# Directory with the assembly-free raw f32le references (hyb_*.asmfree.f32).
REF_DIR = sys.argv[2] if len(sys.argv) > 2 else VEC_DIR
OUT = os.path.join(os.path.dirname(__file__), "..", "libavcodec", "opus_silk_realdata_wbtest.mbt")
OUT_HYBRID = os.path.join(
    os.path.dirname(__file__), "..", "libavcodec", "opus_hybrid_pcm_vectors", "pcm_vectors.mbt"
)

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
    out.append("let opus_hybrid_coef_cases : Array[")
    out.append("  (String, String, String, Array[Int32], Array[String]),")
    out.append("] = [")
    out.extend(hybrid_table)
    out.append("]")
    # Hybrid PCM: the CELT synthesis stage is only bit-exact to 3e-6 (see
    # opus_celt_pcm_reference.c), so the final hybrid output is compared sample
    # by sample against reference f32le frames instead of by framemd5. Emitted
    # into a separate package because the tables exceed the wasm __init local
    # count of libavcodec.
    hybrid_out = []
    hybrid_out.append("///|")
    hybrid_out.append("/// FFmpeg 9.0.2 Opus hybrid end-to-end vectors: selected reference f32le")
    hybrid_out.append("/// frames from the assembly-free build (SILK low band resampled to 48 kHz")
    hybrid_out.append("/// plus the CELT high band, so the whole composition is exercised).")
    hybrid_out.append("/// Kept in a separate package so the tables do not inflate the")
    hybrid_out.append("/// libavcodec wasm __init local count. The framemd5 of these references")
    hybrid_out.append("/// matches the stored hyb_*.md5 exactly. Regenerate with")
    hybrid_out.append("/// scripts/emit_opus_silk_vectors.py. LGPL-2.1-or-later.")
    for name, desc in HYBRID_FILES:
        packets = ogg_packets(os.path.join(VEC_DIR, name + ".opus"))
        head = packets[0]
        pre_skip = struct.unpack("<H", head[10:12])[0]
        media = b"".join(packets[2:])
        hybrid_out.append("///|")
        hybrid_out.append("/// %s: %d packets, pre-skip %d." % (desc, len(packets) - 2, pre_skip))
        hybrid_out.append("pub let opus_hybrid_pcm_%s_b64 : String =" % name)
        b64 = base64.b64encode(media).decode()
        for i in range(0, len(b64), 100):
            hybrid_out.append('  "%s"%s' % (b64[i:i + 100], (" +" if i + 100 < len(b64) else "")))
        hybrid_out.append("///|")
        hybrid_out.append(
            'pub let opus_hybrid_pcm_%s_head_b64 : String = "%s"'
            % (name, base64.b64encode(head).decode())
        )
    hybrid_out.append("///|")
    hybrid_out.append("/// (name, packets b64, head b64, packet byte lengths, per-frame sizes,")
    hybrid_out.append("/// selected (frame index, base64 of the interleaved f32le samples)).")
    hybrid_out.append("/// The frames cover the start (pre-skip trim and hybrid overlap), one")
    hybrid_out.append("/// mid-stream frame and the end (granule trim plus resampler drain).")
    hybrid_out.append("pub let opus_hybrid_pcm_ref_cases : Array[")
    hybrid_out.append("  (String, String, String, Array[Int32], Array[Int32], Array[(Int32, String)]),")
    hybrid_out.append("] = [")
    for name, _ in HYBRID_FILES:
        packets = ogg_packets(os.path.join(VEC_DIR, name + ".opus"))
        sizes_pkts = [len(p) for p in packets[2:]]
        sizes, _ = framemd5_lines(os.path.join(VEC_DIR, name + ".md5"))
        assert len(sizes) > 0
        channels = packets[0][9]
        raw = open(os.path.join(REF_DIR, name + ".asmfree.f32"), "rb").read()
        assert len(raw) == 4 * sum(sizes) * channels, (name, len(raw), channels)
        picks = sorted(
            {0, 1, 2, len(sizes) // 2, len(sizes) - 2, len(sizes) - 1}
        )
        picks = [i for i in picks if 0 <= i < len(sizes)]
        hybrid_out.append("  (")
        hybrid_out.append('    "%s",' % name)
        hybrid_out.append("    opus_hybrid_pcm_%s_b64," % name)
        hybrid_out.append("    opus_hybrid_pcm_%s_head_b64," % name)
        hybrid_out.append("    [%s]," % ", ".join(str(s) for s in sizes_pkts))
        hybrid_out.append("    [%s]," % ", ".join(str(s) for s in sizes))
        hybrid_out.append("    [")
        for i in picks:
            offset = 4 * channels * sum(sizes[:i])
            frame = raw[offset:offset + 4 * channels * sizes[i]]
            hybrid_out.append('      (%d, "%s"),' % (i, base64.b64encode(frame).decode()))
        hybrid_out.append("    ],")
        hybrid_out.append("  ),")
    hybrid_out.append("]")
    with open(OUT_HYBRID, "wb") as f:
        f.write(("\n".join(hybrid_out) + "\n").encode("utf-8"))
    # Emit the case table with sizes and md5 lists.
    out.append("///|")
    out.append("/// (name, packets b64, head b64, packet byte lengths, per-frame sizes,")
    out.append("/// per-frame md5).")
    out.append("let opus_silk_cases : Array[")
    out.append("  (String, String, String, Array[Int32], Array[Int32], Array[String]),")
    out.append("] = [")
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
