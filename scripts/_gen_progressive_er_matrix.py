import re

SRC = ".scratch/h264_slices1.264"
src = open(SRC, "rb").read()
idx = [m.start() for m in re.finditer(b"\x00\x00\x01", src)]
starts = [(p - 1 if p > 0 and src[p - 1] == 0 else p) for p in idx]
starts.append(len(src))
n = len(starts) - 1

VARIANTS = {
    # drop the first slice of the IDR picture
    "head_i": {"drop": [3]},
    # drop two consecutive slices of the second P picture
    "two_p": {"drop": [9, 10]},
    # drop the first slice of the first P picture
    "head_p": {"drop": [6]},
    # truncate a middle slice of the first P picture to 3/4 of its bytes
    "trunc_p_mid": {"trunc": {7: 3}},
    # truncate the last slice of the second P picture
    "trunc_p_last": {"trunc": {11: 3}},
    # drop the last slice of the first P picture AND the first of the next
    "two_split": {"drop": [8, 9]},
}

for name, spec in VARIANTS.items():
    out = bytearray()
    for i in range(n):
        if i in spec.get("drop", []):
            continue
        a, b = starts[i], starts[i + 1]
        if i in spec.get("trunc", {}):
            b = a + (b - a) * spec["trunc"][i] // 4
        out += src[a:b]
    path = f".scratch/h264_er_{name}.264"
    open(path, "wb").write(bytes(out))
    print("wrote", path, len(out))
