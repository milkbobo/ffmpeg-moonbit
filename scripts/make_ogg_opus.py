#!/usr/bin/env python3
"""Wrap raw Opus packets (u32-LE size prefixed, as written by the reference
harness) into an Ogg Opus file, for validating the ported encoder's output
with a stock FFmpeg build.

Usage: python make_ogg_opus.py <in.pkt> <out.opus> <channels> <preskip>
"""
import struct
import sys

POLY = 0x04C11DB7


def _crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ POLY) & 0xFFFFFFFF if r & 0x80000000 else (r << 1) & 0xFFFFFFFF
        table.append(r)
    return table


CRC_TABLE = _crc_table()


def ogg_crc(data):
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ CRC_TABLE[((crc >> 24) & 0xFF) ^ b]
    return crc


def page(serial, seq, header_type, granule, packets):
    segments = []
    body = b""
    for pkt in packets:
        n = len(pkt)
        while n >= 255:
            segments.append(255)
            n -= 255
        segments.append(n)
        body += pkt
    header = struct.pack(
        "<4sBBqIIIB",
        b"OggS",
        0,
        header_type,
        granule,
        serial,
        seq,
        0,
        len(segments),
    )
    raw = header + bytes(segments) + body
    crc = ogg_crc(raw)
    raw = raw[:22] + struct.pack("<I", crc) + raw[26:]
    return raw


def main():
    src, dst, channels, preskip = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    data = open(src, "rb").read()
    off = 0
    packets = []
    while off + 4 <= len(data):
        n = struct.unpack("<I", data[off:off + 4])[0]
        off += 4
        packets.append(data[off:off + n])
        off += n

    serial = 0x0BADF00D
    out = b""
    head = b"OpusHead" + struct.pack("<BBHIhB", 1, channels, preskip, 48000, 0, 0)
    out += page(serial, 0, 0x02, 0, [head])
    vendor = b"moonbit-ffmpeg-opus"
    tags = b"OpusTags" + struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", 0)
    out += page(serial, 1, 0, 0, [tags])
    seq = 2
    granule = preskip
    for i, pkt in enumerate(packets):
        granule += 960
        out += page(serial, seq, 0, granule, [pkt])
        seq += 1
    open(dst, "wb").write(out)
    print(f"wrote {dst}: {len(packets)} packets, {len(out)} bytes")


if __name__ == "__main__":
    main()
