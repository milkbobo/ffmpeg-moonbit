#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the intensity-stereo vectors for `libavcodec/aac_is_vectors`.

Pipeline (two sides have to agree, so the script drives both):

  1. The MoonBit encoder, with the §292 `ISDUMP-` probe in
     `libavcodec/aac_encode.mbt`, prints the exact channel-pair state it has
     when it reaches the stereo stage:

       moon test --target wasm libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log

  2. This script turns those blocks into the C harness's `--is` dump, runs
     `_ref/aacenc/aac_ref.exe --is` (FFmpeg 9.0.2 `aacenc_is.c`
     `ff_aac_search_for_is`) over them and reads back the per-band decision.
  3. It writes both sides into `libavcodec/aac_is_vectors/fixtures.mbt`, so the
     test compares our port against FFmpeg on identical inputs.

The spectra are stored as the *float* values the C harness actually consumed
(`(float)v`), which is what our port models with `aac_two_f32`.

Usage:
  python scripts/gen_aac_is_vectors.py .scratch/is_dump/enc.log
"""
import os
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(REPO, "_ref", "aacenc", "aac_ref.exe")
OUT_DIR = os.path.join(REPO, "libavcodec", "aac_is_vectors")
NSPEC = 1024
NBANDS = 49
TAKE = (0, 1, 4, 5)  # two correlated frames + two uncorrelated ones


def f32(v):
    return struct.unpack("<f", struct.pack("<f", v))[0]


def read_blocks(path):
    blocks = []
    cur = None
    which = None
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line.startswith("ISDUMP-"):
            continue
        if line.startswith("ISDUMP-FRAME"):
            cur = {"spec0": [], "spec1": [], "bands0": {}, "bands1": {},
                   "sf0": {}, "sf1": {}, "alloc": 0}
            blocks.append(cur)
            which = None
        elif line == "ISDUMP-SPEC0":
            which = "spec0"
        elif line == "ISDUMP-SPEC1":
            which = "spec1"
        elif line.startswith("ISDUMP-V "):
            cur[which].append(f32(float(line[len("ISDUMP-V "):])))
        elif line.startswith("ISDUMP-ALLOC "):
            cur["alloc"] = int(line[len("ISDUMP-ALLOC "):])
        elif line.startswith("ISDUMP-PSYBAND0 ") or line.startswith("ISDUMP-PSYBAND1 "):
            key = "bands" + line[len("ISDUMP-PSYBAND"):][0]
            p = line.split()
            cur[key][int(p[1])] = [f32(float(p[2])), f32(float(p[3])),
                                    f32(float(p[4])), int(p[5])]
        elif line.startswith("ISDUMP-SF0 ") or line.startswith("ISDUMP-SF1 "):
            key = "sf" + line[len("ISDUMP-SF")][0]
            p = line.split()
            cur[key][int(p[1])] = [int(p[2]), int(p[3]), int(p[4])]
        elif line == "ISDUMP-END":
            which = None
    for i, b in enumerate(blocks):
        for k in ("spec0", "spec1"):
            if len(b[k]) != NSPEC:
                sys.exit("block %d: %s has %d values" % (i, k, len(b[k])))
        for k in ("bands0", "bands1", "sf0", "sf1"):
            if len(b[k]) != NBANDS:
                sys.exit("block %d: %s has %d bands" % (i, k, len(b[k])))
    if len(blocks) < max(TAKE) + 1:
        sys.exit("expected at least %d blocks, got %d" % (max(TAKE) + 1, len(blocks)))
    return [blocks[i] for i in TAKE]


def write_dump(blocks, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for i, b in enumerate(blocks):
            f.write("FRAME %d\n" % i)
            for k in ("spec0", "spec1"):
                f.write("SPEC%s\n" % k[-1])
                for v in b[k]:
                    f.write("%.9e\n" % f32(v))
            f.write("PSYALLOC %d\n" % b["alloc"])
            for k in ("bands0", "bands1"):
                for g in range(NBANDS):
                    e, t, s, bits = b[k][g]
                    f.write("PSYBAND%s %d %.9e %.9e %.9e %d\n"
                            % (k[-1], g, f32(e), f32(t), f32(s), bits))
            for k in ("sf0", "sf1"):
                for g in range(NBANDS):
                    sf, cb, z = b[k][g]
                    f.write("SF%s %d %d %d %d\n" % (k[-1], g, sf, cb, z))
            f.write("END\n")


def run_ref(dump_path):
    out = subprocess.run([REF, "--is", dump_path], capture_output=True, text=True,
                         check=True, cwd=REPO).stdout
    frames = []
    cur = None
    for line in out.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "FRAME":
            cur = {"mode": 0, "band": {}, "err": {}, "d1l": {}, "ms": {},
                   "mscost": {}}
            frames.append(cur)
        elif p[0] == "ISMODE":
            cur["mode"] = int(p[1])
        elif p[0] == "ISBAND":
            cur["band"][int(p[1])] = [int(p[2]), int(p[3]), int(p[4]),
                                      f32(float(p[5])), f32(float(p[6]))]
        elif p[0] == "MSBAND":
            cur["ms"][int(p[1])] = [int(x) for x in p[2:11]]
        elif p[0] == "MSCOST":
            cur["mscost"][int(p[1])] = [int(p[2]), int(p[3]),
                                        f32(float(p[4])), f32(float(p[5])),
                                        f32(float(p[6])), int(p[7]),
                                        f32(float(p[8]))]
        elif p[0] == "ISD1L":
            cur["d1l"][int(p[1])] = [f32(float(p[2])), f32(float(p[3]))]
        elif p[0] == "ISERR":
            cur["err"][int(p[1])] = [int(p[2]), f32(float(p[3])),
                                     f32(float(p[4])), int(p[5]),
                                     f32(float(p[6])), f32(float(p[7]))]
    for i, fr in enumerate(frames):
        for k in ("band", "err", "d1l", "ms", "mscost"):
            if len(fr[k]) != NBANDS:
                sys.exit("frame %d: %s has %d rows" % (i, k, len(fr[k])))
    return frames


def rows(blocks, pick):
    out = []
    for b in blocks:
        out.append([pick(b, g) for g in range(NBANDS)])
    return out


def fmt_d(v):
    return repr(float(v))


def arr(name, typ, data):
    body = ",\n".join("  [" + ", ".join(
        (fmt_d(v) if typ == "Double" else str(int(v))) for v in row) + "]"
        for row in data)
    return "///|\npub let %s : Array[Array[%s]] = [\n%s,\n]\n" % (name, typ, body)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: gen_aac_is_vectors.py <encoder log>")
    blocks = read_blocks(sys.argv[1])
    os.makedirs(OUT_DIR, exist_ok=True)
    scratch = os.path.join(REPO, ".scratch", "is_dump")
    os.makedirs(scratch, exist_ok=True)
    dump = os.path.join(scratch, "pair.txt")
    write_dump(blocks, dump)
    frames = run_ref(dump)
    if len(frames) != len(blocks):
        sys.exit("harness answered %d frames, dumped %d" % (len(frames), len(blocks)))

    header = (
        "///|\n"
        "/// AUTOGENERATED by scripts/gen_aac_is_vectors.py from\n"
        "/// `_ref/aacenc/aac_ref.exe --is` (FFmpeg 9.0.2 `aacenc_is.c`\n"
        "/// `ff_aac_search_for_is`) over the channel-pair state the MoonBit\n"
        "/// encoder prints with its §292 `ISDUMP-` probe. Do not edit by hand.\n"
        "/// Regenerate with:\n"
        "///   bash _ref/aacenc/build.sh\n"
        "///   moon test --target wasm libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log\n"
        "///   python scripts/gen_aac_is_vectors.py .scratch/is_dump/enc.log\n"
        "///\n"
        "/// " + str(len(blocks)) + " frames. Each carries the two spectra the search reads\n"
        "/// (float-rounded, exactly as the harness consumed them), both channels' psy band\n"
        "/// records and twoloop outcome, and the per-band reference decision:\n"
        "/// `is_mask`, the post-search `ms_mask`, the right channel's band type and the\n"
        "/// two `is_ener` values. `*_d1`/`*_d2` are `aac_is_encoding_err`'s dist1/dist2\n"
        "/// for phase -1 and +1 (0 when the band never reached the cost test).\n"
    )
    parts = [header]
    parts.append(arr("aac_is_spec0", "Double", [b["spec0"] for b in blocks]))
    parts.append(arr("aac_is_spec1", "Double", [b["spec1"] for b in blocks]))
    parts.append(arr("aac_is_thr0", "Double",
                     [[b["bands0"][g][1] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_thr1", "Double",
                     [[b["bands1"][g][1] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_sf0", "Int", [[b["sf0"][g][0] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_cb0", "Int", [[b["sf0"][g][1] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_zero0", "Int", [[b["sf0"][g][2] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_sf1", "Int", [[b["sf1"][g][0] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_cb1", "Int", [[b["sf1"][g][1] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_zero1", "Int", [[b["sf1"][g][2] for g in range(NBANDS)] for b in blocks]))
    parts.append(arr("aac_is_ref_mask", "Int",
                     [[f["band"][g][0] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms", "Int",
                     [[f["band"][g][1] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_bt1", "Int",
                     [[f["band"][g][2] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ener0", "Double",
                     [[f["band"][g][3] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ener1", "Double",
                     [[f["band"][g][4] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d11l", "Double",
                     [[f["d1l"][g][0] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d21l", "Double",
                     [[f["d1l"][g][1] for g in range(NBANDS)] for f in frames]))
    for i, f in enumerate(frames):
        for g in range(NBANDS):
            got = f["ms"][g][1:5]
            want = [blocks[i]["sf0"][g][0], blocks[i]["sf0"][g][1],
                    blocks[i]["sf1"][g][0], blocks[i]["sf1"][g][1]]
            # On an intensity band the reference has already rewritten the right
            # channel's band type to 14/15 (`search_for_is`), which is the state
            # `search_for_ms` is meant to see; everything else must match what
            # the encoder handed over.
            if f["band"][g][0] == 1:
                want[3] = want[3] if got[3] == want[3] else got[3]
            if got != want:
                sys.exit("frame %d band %d: reference pre-MS state %s != dumped %s"
                         % (i, g, got, want))
    parts.append(arr("aac_is_ref_ms_mask", "Int",
                     [[f["ms"][g][0] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_sf0", "Int",
                     [[f["ms"][g][5] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_cb0", "Int",
                     [[f["ms"][g][6] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_sf1", "Int",
                     [[f["ms"][g][7] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_cb1", "Int",
                     [[f["ms"][g][8] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_boost", "Int",
                     [[f["mscost"][g][1] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_d1", "Double",
                     [[f["mscost"][g][2] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_d2", "Double",
                     [[f["mscost"][g][3] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_cm", "Double",
                     [[f["mscost"][g][4] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_b1", "Int",
                     [[f["mscost"][g][5] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_ms_bmax", "Double",
                     [[f["mscost"][g][6] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_pass1", "Int",
                     [[f["err"][g][0] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_pass2", "Int",
                     [[f["err"][g][3] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d11", "Double",
                     [[f["err"][g][1] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d12", "Double",
                     [[f["err"][g][2] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d21", "Double",
                     [[f["err"][g][4] for g in range(NBANDS)] for f in frames]))
    parts.append(arr("aac_is_ref_d22", "Double",
                     [[f["err"][g][5] for g in range(NBANDS)] for f in frames]))
    modes = "pub let aac_is_ref_mode : Array[Int] = [%s]\n" % ", ".join(
        str(f["mode"]) for f in frames)
    parts.append("///|\n")
    parts.append(modes)

    with open(os.path.join(OUT_DIR, "fixtures.mbt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(parts))
    with open(os.path.join(OUT_DIR, "moon.pkg"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write('import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    total = sum(sum(r) for r in
                [[f["band"][g][0] for g in range(NBANDS)] for f in frames])
    print("wrote %s/fixtures.mbt (%d frames, %d IS bands in the reference)"
          % (OUT_DIR, len(blocks), total))


main()
