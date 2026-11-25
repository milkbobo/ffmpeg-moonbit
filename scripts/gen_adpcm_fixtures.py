# Generate libavformat/adpcm_facade_realdata_test.mbt: ADPCM through the
# unified playback API (WAV and MOV containers, `decode_audio_file`) against
# the C reference decoder (scripts/adpcm_c_ref/build.cmd compiles FFmpeg
# 9.0.2 adpcm.c unmodified) and the FATE vectors.
#
# Fixtures:
# * the FATE `oki/test.wav` whole (FATE md5 641049800e735b62e975baacc9a011a4);
# * blocks taken from the qt-surge-suite MOV files `surge-2-16-L-ms02.mov`
#   (MS ADPCM, 1024-byte blocks) and `surge-2-16-L-ms11.mov` (IMA ADPCM,
#   512-byte blocks), re-wrapped by the generator into a WAV and into a MOV
#   with the `ms\x00\x02` / `ms\x00\x11` sample entries (the WAV-tag fallback
#   of `mov_codec_id`), so both container paths run on real encoded audio;
# * WAVs of the other shapes - MS mono and 6 channels, IMA 3-bit codes,
#   Yamaha - with valid block headers and random nibbles (the C decoder is
#   deterministic on them, so its output is the expectation).
#
# Every expected value is the MD5 of the interleaved s16le the C reference
# decodes from the very same blocks.
#
# Usage (from the repo root; needs gcc and the FFmpeg tree at the parent
# directory for the C reference):
#   python -I scripts/gen_adpcm_fixtures.py libavformat [--fetch-only]
import base64
import hashlib
import os
import random
import struct
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DL = os.path.join(ROOT, ".scratch", "adpcm_dl")
CREF = os.path.join(HERE, "adpcm_c_ref")
BASE = "https://fate-suite.ffmpeg.org/"
SAMPLES = {
    "oki__test.wav": "oki/test.wav",
    "surge-2-16-L-ms02.mov": "qt-surge-suite/surge-2-16-L-ms02.mov",
    "surge-2-16-L-ms11.mov": "qt-surge-suite/surge-2-16-L-ms11.mov",
}
BLOCKS = 48  # real blocks embedded per container shape


def fetch():
    os.makedirs(DL, exist_ok=True)
    for local, remote in SAMPLES.items():
        dst = os.path.join(DL, local)
        if not (os.path.exists(dst) and os.path.getsize(dst) > 0):
            print("download", remote)
            urllib.request.urlretrieve(BASE + remote, dst)


def build_cref():
    if not os.path.exists(os.path.join(CREF, "adpcm_ref.exe")):
        subprocess.run(["cmd", "/c", os.path.join(CREF, "build.cmd")], cwd=ROOT,
                       capture_output=True)


# ---------------------------------------------------------------------------
# a minimal MOV reader / writer
# ---------------------------------------------------------------------------


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


def find(data, start, end, path):
    """Body (start, end) of the box at `path` (a list of tags), or None."""
    cur = (start, end)
    for tag in path:
        hit = None
        for t, body, bend in boxes(data, cur[0], cur[1]):
            if t == tag.encode():
                hit = (body, bend)
                break
        if hit is None:
            return None
        cur = hit
    return cur


def mov_audio_samples(data):
    """(codec fourcc, channels, sample_rate, bytes_per_frame, sample bytes) of
    the first audio track."""
    moov = find(data, 0, len(data), ["moov"])
    trak = None
    for t, body, bend in boxes(data, moov[0], moov[1]):
        if t == b"trak":
            mdia = find(data, body, bend, ["mdia"])
            hdlr = find(data, mdia[0], mdia[1], ["hdlr"])
            if data[hdlr[0] + 8:hdlr[0] + 12] == b"soun":
                trak = (body, bend)
                break
    assert trak is not None, "no audio track"
    mdia = find(data, trak[0], trak[1], ["mdia"])
    mdhd = find(data, mdia[0], mdia[1], ["mdhd"])
    sample_rate = struct.unpack(">I", data[mdhd[0] + 12:mdhd[0] + 16])[0]
    minf = find(data, mdia[0], mdia[1], ["minf"])
    stbl = find(data, minf[0], minf[1], ["stbl"])
    stsd = find(data, stbl[0], stbl[1], ["stsd"])
    entry = stsd[0] + 8  # the sample entry box starts with its size + type
    fourcc = data[entry + 4:entry + 8]
    version = struct.unpack(">H", data[entry + 16:entry + 18])[0]
    channels = struct.unpack(">H", data[entry + 24:entry + 26])[0]
    bytes_per_frame = 0
    if version == 1:
        # Sound Description v1: samples_per_packet, bytes_per_packet,
        # bytes_per_frame, bytes_per_sample after the 36-byte v0 part
        bytes_per_frame = struct.unpack(">I", data[entry + 44:entry + 48])[0]
    # The audio is the only track: its chunks (stco) tile the mdat. Each
    # chunk is split into blocks of `bytes_per_frame`, the packet size the
    # demuxer hands out (ffmpeg's mov demuxer uses the v1 field as the block
    # size for the ADPCM codecs).
    stco = find(data, stbl[0], stbl[1], ["stco"])
    _, nchunks = struct.unpack(">II", data[stco[0]:stco[0] + 8])
    offsets = list(struct.unpack(">%dI" % nchunks, data[stco[0] + 8:stco[0] + 8 + 4 * nchunks]))
    mdat = next((body, bend) for t, body, bend in boxes(data, 0, len(data)) if t == b"mdat")
    samples = []
    for i, start in enumerate(offsets):
        end = offsets[i + 1] if i + 1 < len(offsets) else mdat[1]
        assert start >= mdat[0] and end <= mdat[1] and (end - start) % bytes_per_frame == 0, \
            (start, end, mdat, bytes_per_frame)
        samples.extend(data[p:p + bytes_per_frame]
                       for p in range(start, end, bytes_per_frame))
    return fourcc, channels, sample_rate, bytes_per_frame, samples


def box(tag, payload):
    return struct.pack(">I4s", 8 + len(payload), tag) + payload


def full(tag, version, flags, payload):
    return box(tag, bytes([version]) + flags.to_bytes(3, "big") + payload)


def be16(v):
    return struct.pack(">H", v)


def be32(v):
    return struct.pack(">I", v)


def audio_entry(fourcc, sample_rate, channels, bits, bytes_per_frame):
    entry = (be16(0) * 3 + be16(1) + be16(0) + be16(0) + be32(0) + be16(channels) +
             be16(bits) + be16(0) + be16(0) + be32(sample_rate << 16))
    if bytes_per_frame:
        # Sound Description v1: samples_per_packet, bytes_per_packet,
        # bytes_per_frame, bytes_per_sample
        entry += be32(0) + be32(0) + be32(bytes_per_frame) + be32(0)
    return box(fourcc, entry)


def build_mov(fourcc, samples, sample_rate, channels, bits, bytes_per_frame, samples_per_frame):
    ftyp = box(b"ftyp", b"qt  " + be32(0) + b"qt  ")
    frames = len(samples) * samples_per_frame
    mvhd = full(b"mvhd", 0, 0, be32(0) + be32(0) + be32(1000) + be32(frames * 1000 // sample_rate) +
                be32(0x00010000) + be32(0x01000000) + be32(0) + be32(0x40000000) +
                be32(0x10000) * 9 + b"\0" * 36 + be32(2))
    tkhd = full(b"tkhd", 0, 3, be32(0) + be32(0) + be32(1) + be32(0) + be32(frames) +
                be32(0) * 4 + be32(0x10000) + be32(0) * 2 + be32(0x40000000))
    mdhd = full(b"mdhd", 0, 0, be32(0) + be32(0) + be32(sample_rate) + be32(frames) +
                be32(0x55C40000) + be16(0) + be16(0))
    hdlr = full(b"hdlr", 0, 0, be32(0) + b"soun" + be32(0) * 3 + b"SoundHandler\0")
    vmhd = full(b"vmhd", 0, 1, be16(0) * 4)
    dinf = box(b"dinf", full(b"dref", 0, 0, be32(1) + full(b"url ", 0, 1, b"")))
    stsd = box(b"stsd", be32(0) + be32(1) + audio_entry(fourcc, sample_rate, channels, bits, bytes_per_frame))
    stts = box(b"stts", be32(0) + be32(1) + be32(len(samples)) + be32(samples_per_frame))
    stsc = box(b"stsc", be32(0) + be32(1) + be32(1) + be32(len(samples)) + be32(1))
    stsz = box(b"stsz", be32(0) + be32(0) + be32(len(samples)) +
               b"".join(be32(len(s)) for s in samples))
    mdat = box(b"mdat", b"".join(samples))
    mdat_data = len(ftyp)
    for _ in range(2):
        stco = box(b"stco", be32(0) + be32(1) + be32(mdat_data))
        stbl = box(b"stbl", stsd + stts + stsc + stsz + stco)
        mdia = box(b"mdia", mdhd + hdlr + box(b"minf", vmhd + dinf + stbl))
        moov = box(b"moov", mvhd + box(b"trak", tkhd + mdia))
        mdat_data = len(ftyp) + len(moov) + 8
    return ftyp + moov + mdat


def build_wav(codec_tag, samples, sample_rate, channels, bits, block_align, extra=b""):
    data = b"".join(samples)
    byte_rate = (sample_rate * block_align) & 0xFFFF
    fmt = struct.pack("<HHIIHH", codec_tag, channels, sample_rate, byte_rate, block_align, bits) + extra

    def chunk(tag, payload):
        pad = b"\0" if len(payload) & 1 else b""
        return tag + struct.pack("<I", len(payload)) + payload + pad

    body = b"WAVE" + chunk(b"fmt ", fmt) + chunk(b"data", data)
    return b"RIFF" + struct.pack("<I", len(body)) + body


# ---------------------------------------------------------------------------
# the C reference
# ---------------------------------------------------------------------------


def c_md5(codec, ch, block_align, bits, samples):
    """MD5 of the interleaved s16le the C decoder produces for `samples`."""
    spec = os.path.join(DL, "cref_spec.txt")
    binp = os.path.join(DL, "cref_packets.bin")
    dump = os.path.join(DL, "cref_dump.txt")
    with open(spec, "w", encoding="utf-8") as f, open(binp, "wb") as b:
        f.write(f"{codec} {ch} {block_align} {bits} {len(samples)}\n" +
                " ".join(str(len(s)) for s in samples) + "\n")
        b.write(b"".join(samples))
    r = subprocess.run([os.path.join(CREF, "adpcm_ref.exe"), spec, binp, dump],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise SystemExit(f"adpcm_ref failed: {r.stdout} {r.stderr}")
    pcm = bytearray()
    frames = []
    errors = 0
    for line in open(dump, encoding="utf-8"):
        t = line.split()
        if not t:
            continue
        if t[0] == "E":
            errors += 1
        elif t[0] == "S":
            frames.append([int(x) for x in t[2:]])
            if len(frames) == ch:
                for i in range(len(frames[0])):
                    for c in range(ch):
                        pcm += struct.pack("<h", frames[c][i])
                frames = []
    if errors:
        raise SystemExit(f"{codec}: the C decoder rejected {errors} packet(s)")
    return hashlib.md5(bytes(pcm)).hexdigest(), len(pcm)


def b64_lines(data, indent="  ", width=120):
    text = base64.b64encode(data).decode("ascii")
    rows = [text[i:i + width] for i in range(0, len(text), width)]
    return " +\n".join(f'{indent}b"{row}"' for row in rows)


def emit_bytes(name, data, doc):
    return f"///|\n/// {doc}\nlet {name} : Bytes = adpcm_cat([\n{b64_lines(data)},\n])\n\n"


HELPERS = r'''///|
fn adpcm_cat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn adpcm_load(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 8 << 20).unwrap()
}

///|
fn adpcm_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
/// The facade's decode as interleaved s16le (swresample's rounding: half
/// to even), quantised exactly as the s16 values the ADPCM decoders emit.
fn adpcm_s16(audio : @libavformat.DecodedAudio) -> Bytes {
  let rows = audio.samples()
  let n = if rows.length() > 0 { rows[0].length() } else { 0 }
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    for row in rows {
      let q = (row[i] * 32768.0).round().to_int()
      out.push(q.to_byte())
      out.push((q >> 8).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// Decode `data` through the facade and check the stream labels and the
/// s16le MD5 against the C reference / FATE.
fn adpcm_check(
  data : Bytes,
  format : String,
  codec : String,
  rate : Int32,
  channels : Int32,
  pcm_bytes : Int,
  want_md5 : String,
  label : String,
) -> Unit raise {
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.format_name(), format, msg="\{label}: format")
  assert_eq(audio.codec_id(), codec, msg="\{label}: codec")
  assert_eq(audio.sample_rate(), rate, msg="\{label}: rate")
  assert_eq(audio.channels(), channels, msg="\{label}: channels")
  assert_eq(audio.read_error(), "", msg="\{label}: read error")
  let pcm = adpcm_s16(audio)
  assert_eq(pcm.length(), pcm_bytes, msg="\{label}: decoded length")
  assert_eq(adpcm_md5(pcm), want_md5, msg="\{label}: s16le MD5")
}
'''

HEADER = r'''///|
/// ADPCM through the unified playback API, against the C decoder and FATE.
/// Every file is decoded by `decode_audio_file` (container, demuxer, the
/// ADPCM block decoders) and its interleaved s16le output must match the
/// MD5 of what FFmpeg 9.0.2 `adpcm.c` decodes from the same blocks
/// (`scripts/adpcm_c_ref/build.cmd` compiles it unmodified); the OKI file
/// additionally carries FATE's own `adpcm-ima-oki` reference MD5.
///
/// The MS / IMA blocks come from the qt-surge-suite MOV files and are
/// re-wrapped into a WAV and into a MOV with the `ms\x00\x02` / `ms\x00\x11`
/// sample entries, so both container paths run on real encoded audio; the
/// other shapes (MS mono and 6 channels, 3-bit IMA WAV, Yamaha) use valid
/// block headers with random nibbles, which the integer decoder handles
/// deterministically. Generated by `scripts/gen_adpcm_fixtures.py`.
///
/// Regenerate with `python -I scripts/gen_adpcm_fixtures.py libavformat`.
'''


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavformat"
    fetch()
    if "--fetch-only" in sys.argv:
        return
    build_cref()
    rng = random.Random(20261125)
    cases = []  # (name, doc, data, format, codec, rate, ch, pcm_bytes, md5)

    # FATE: Dialogic OKI WAV
    oki = open(os.path.join(DL, "oki__test.wav"), "rb").read()
    md5, nbytes = c_md5("adpcm_ima_oki", 1, 256, 4, mov_packets_wav(oki, 256))
    assert md5 == "641049800e735b62e975baacc9a011a4", md5
    cases.append(("oki_wav", "FATE `oki/test.wav`: Dialogic OKI IMA, 11.025 kHz mono.",
                  oki, "wav", "adpcm_ima_oki", 11025, 1, nbytes, md5))

    # real blocks from the surge suite
    for local, fourcc, codec, bits, spf in (
            ("surge-2-16-L-ms02.mov", b"ms\x00\x02", "adpcm_ms", 4, 505),
            ("surge-2-16-L-ms11.mov", b"ms\x00\x11", "adpcm_ima_wav", 4, 505)):
        data = open(os.path.join(DL, local), "rb").read()
        fcc, ch, rate, bpf, samples = mov_audio_samples(data)
        assert fcc == fourcc, (fcc, fourcc)
        blocks = samples[:BLOCKS]
        block_align = bpf or len(blocks[0])
        tag = 0x0002 if codec == "adpcm_ms" else 0x0011
        stem = local[len("surge-2-16-L-"):-4]  # ms02 / ms11
        md5, nbytes = c_md5(codec, ch, block_align, bits, blocks)
        wav = build_wav(tag, blocks, rate, ch, bits, block_align)
        cases.append((f"{stem}_wav", f"WAV wrapping {len(blocks)} blocks of `{local}`.",
                      wav, "wav", codec, rate, ch, nbytes, md5))
        mov = build_mov(fourcc, blocks, rate, ch, bits, bpf, spf)
        cases.append((f"{stem}_mov", f"MOV with `{fourcc.decode('latin1')}` entries, "
                      f"{len(blocks)} blocks of `{local}`.", mov, "mov,mp4,m4a,3gp,3g2,mj2",
                      codec, rate, ch, nbytes, md5))

    # crafted shapes: valid headers, random payloads
    def rand_ms(ch, block_align):
        if ch <= 2:
            header = bytes([rng.randrange(7) for _ in range(ch)])
            header += b"".join(struct.pack("<h", rng.randrange(-100, 100)) for _ in range(3 * ch))
            return header + bytes(rng.randrange(256) for _ in range(block_align - len(header)))
        # >2 channels: planar, one 7-byte header + data run per channel
        per_ch = block_align // ch
        block = b""
        for _ in range(ch):
            block += bytes([rng.randrange(7)]) + b"".join(
                struct.pack("<h", rng.randrange(-100, 100)) for _ in range(3))
            block += bytes(rng.randrange(256) for _ in range(per_ch - 7))
        return block[:block_align]

    def rand_ima(ch, bits, block_align):
        header = b"".join(struct.pack("<hBB", rng.randrange(-2000, 2000), rng.randrange(89), 0)
                          for _ in range(ch))
        return header + bytes(rng.randrange(256) for _ in range(block_align - len(header)))

    for ch in (1, 6):
        blocks = [rand_ms(ch, 256 if ch == 1 else 7 * ch + 240) for _ in range(12)]
        md5, nbytes = c_md5("adpcm_ms", ch, len(blocks[0]), 4, blocks)
        wav = build_wav(0x0002, blocks, 8000, ch, 4, len(blocks[0]))
        cases.append((f"ms{ch}_wav", f"WAV MS ADPCM, {ch} channel(s), valid headers, random nibbles.",
                      wav, "wav", "adpcm_ms", 8000, ch, nbytes, md5))
    blocks = [rand_ima(2, 3, 1024) for _ in range(12)]
    md5, nbytes = c_md5("adpcm_ima_wav", 2, 1024, 3, blocks)
    wav = build_wav(0x0011, blocks, 22050, 2, 3, 1024)
    cases.append(("ima3bit_wav", "WAV IMA ADPCM with 3-bit codes (wBitsPerSample 3).", wav,
                  "wav", "adpcm_ima_wav", 22050, 2, nbytes, md5))
    payload = bytes(rng.randrange(256) for _ in range(1000))
    md5, nbytes = c_md5("adpcm_yamaha", 2, 500, 4, [payload[:500], payload[500:]])
    wav = build_wav(0x0020, [payload[:500], payload[500:]], 44100, 2, 4, 500)
    cases.append(("yamaha_wav", "WAV Yamaha ADPCM, stereo, random nibbles.", wav, "wav",
                  "adpcm_yamaha", 44100, 2, nbytes, md5))

    body = HEADER + "\n" + HELPERS
    for name, doc, data, fmt, codec, rate, ch, nbytes, md5 in cases:
        body += emit_bytes(f"adpcm_{name}", data, f"{doc} {len(data)} bytes.")
    for name, doc, data, fmt, codec, rate, ch, nbytes, md5 in cases:
        body += f'''///|
test "adpcm facade {name}: decodes to the reference s16le" {{
  adpcm_check(
    adpcm_load(adpcm_{name}),
    "{fmt}",
    "{codec}",
    {rate},
    {ch},
    {nbytes},
    "{md5}",
    "{name}",
  )
}}

'''
    path = os.path.join(out_dir, "adpcm_facade_realdata_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(path, os.path.getsize(path), "bytes")
    for name, doc, data, fmt, codec, rate, ch, nbytes, md5 in cases:
        print(f"  {name:16} {fmt:28} {codec:15} {rate:6} Hz {ch} ch {len(data):7} B -> {nbytes:8} B {md5}")


def mov_packets_wav(data, block_align):
    """The data chunks of a WAV as block-aligned packets (for the C run)."""
    packets = []
    pos = 12
    while pos + 8 <= len(data):
        tag = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if tag == b"data":
            body = data[pos + 8:pos + 8 + size]
            for i in range(0, len(body), block_align):
                packets.append(body[i:i + block_align])
        pos += 8 + size + (size & 1)
    return packets


if __name__ == "__main__":
    main()
