# Extract the raw AMR-WB frames (TOC byte + payload) of a FATE 3GP sample
# whose samples all have one size: the frames are the mdat payload. The
# frame size follows the first TOC byte (amrwb_packed_size) and the total
# must divide exactly.
import struct
import sys

PACKED = [18, 24, 33, 37, 41, 47, 51, 59, 61, 6, 1, 1, 1, 1, 1, 1]


def boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size, tag = struct.unpack(">I4s", data[pos:pos + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        yield tag, pos + header, pos + size
        pos += size


def find_mdat(data):
    for tag, body, end in boxes(data, 0, len(data)):
        if tag == b"mdat":
            return body, end
    raise SystemExit("no mdat")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    body, end = find_mdat(data)
    payload = data[body:end]
    mode = payload[0] >> 3 & 0x0F
    size = PACKED[mode]
    if len(payload) % size:
        raise SystemExit(f"mdat {len(payload)} bytes is not a multiple of {size}")
    open(dst, "wb").write(payload)
    print(f"{dst}: {len(payload)} bytes = {len(payload) // size} frames of mode {mode} ({size} bytes)")


main()
