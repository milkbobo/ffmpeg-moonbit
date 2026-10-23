import re
import subprocess
import sys

SRC = ".scratch/h264_mbaff_slices.264"
src = open(SRC, "rb").read()
idx = [m.start() for m in re.finditer(b"\x00\x00\x01", src)]
starts = []
for p in idx:
    start = p - 1 if p > 0 and src[p - 1] == 0 else p
    starts.append(start)
starts.append(len(src))

nals = []
for i in range(len(starts) - 1):
    t = src[idx[i] + 3] & 31
    nals.append((t, starts[i], starts[i + 1]))

targets = [int(x) for x in sys.argv[1:]] or [5, 8, 11, 14, 17, 20, 23, 26]
for t in targets:
    out = bytearray()
    for i, (kind, a, b) in enumerate(nals):
        if i == t:
            continue
        out += src[a:b]
    name = f".scratch/h264_er_mbaff_drop_{t}.264"
    open(name, "wb").write(bytes(out))
    print("wrote", name, "dropped nal", t, "type", nals[t][0])
