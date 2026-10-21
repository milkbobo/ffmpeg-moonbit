"""Synthetic MP4 AAC-LC 960/120 references from FFmpeg 9.0.2.

All reference PCM decodes the MP4 with skip_manual, preserving encoded
frames/priming so the raw packet decoder can compare every sample.
ffprobe supplies ASC bytes, packet offsets/sizes and channel metadata.
"""
import base64
import json
import re
from pathlib import Path
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "linuxserver/ffmpeg:9.0.2"


def run(args, data=None, probe=False):
    command = ["docker", "run", "--rm", "-i"]
    if probe:
        command += ["--entrypoint", "ffprobe"]
    result = subprocess.run(command + [IMAGE, "-v", "error", *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def emit(name, data):
    chunks = textwrap.wrap(base64.b64encode(data).decode("ascii"), 112)
    return "///|\nlet " + name + " : Bytes = " + " +\n  ".join('b"' + c + '"' for c in chunks) + "\n"


def dump_bytes(dump):
    return b"".join(bytes.fromhex(line.split(":", 1)[1].strip().split("  ", 1)[0])
                    for line in dump.strip().splitlines())


# FDK in the local image rejects AACENC_GRANULE_LENGTH=960. Build LC
# syntax explicitly, remux ADTS to MP4, then set ASC frameLengthFlag.
# Packet timing retains the remuxer's 1024 ticks; reference decoding uses
# complete encoded frames, independent of those fixture-only timestamps.
source = (ROOT.parent / "libavcodec/aactab.c").read_text(encoding="utf-8")
def table(name):
    body = re.search(r"\b" + name + r"\s*\[[^]]*\]\s*=\s*\{([^}]+)\}", source).group(1)
    return [int(t.strip(), 0) for t in body.split(",") if t.strip()]
sf_codes, sf_bits = table("ff_aac_scalefactor_code"), table("ff_aac_scalefactor_bits")
codes, bits = table("codes5"), table("bits5")
class Frame:
    def __init__(self): self.bits = []
    def put(self, value, count):
        self.bits.extend((value >> i) & 1 for i in reversed(range(count)))
    def channel(self, sequence, shape, index):
        self.put(140 + index * 4, 8)
        self.put(0, 1)
        self.put(sequence, 2)
        self.put(shape, 1)
        offsets = table("swb_offset_120_48" if sequence == 2 else "swb_offset_960_48")
        count = len(offsets) - 1
        self.put(count, 4 if sequence == 2 else 6)
        self.put(127 if sequence == 2 else 0, 7 if sequence == 2 else 1)
        for band in range(count):
            self.put(5 if band in (0, count - 1) else 0, 4)
            self.put(1, 3 if sequence == 2 else 5)
        for _ in range(2): self.put(sf_codes[60], sf_bits[60])
        self.put(0, 3) # pulse, TNS, gain control
        for band in (0, count - 1):
            for window in range(8 if sequence == 2 else 1):
                for pair in range((offsets[band + 1] - offsets[band]) // 2):
                    first = (pair + window + index) % 7 - 3
                    second = (pair * 3 + window + index) % 7 - 3
                    row = (first + 4) * 9 + second + 4
                    self.put(codes[row], bits[row])
    def finish(self, channels):
        self.put(7, 3)
        while len(self.bits) % 8: self.put(0, 1)
        payload = bytes(sum(self.bits[i + j] << (7 - j) for j in range(8))
                        for i in range(0, len(self.bits), 8))
        size = len(payload) + 7
        return bytes([255, 241, 76, (channels << 6) | (size >> 11),
                      (size >> 3) & 255, ((size & 7) << 5) | 31, 252]) + payload

lines = ["///|\n/// Synthetic AAC-LC 960/120 references; scripts/generate_aac_960_vectors.py.",
         "/// FFmpeg 9.0.2 PCM with -flags2 +skip_manual; MP4 ASC frameLengthFlag=1.",
         "/// Every window sequence and shape, independent CPE windows, first/final bands.",
         "/// Fixture MP4 timestamps retain ADTS remuxer's 1024 ticks; PCM frames are 960.",
         "/// LGPL-2.1-or-later.\n"]
for name, channels in [("mono", 1), ("stereo", 2)]:
    frames = []
    for i, sequence in enumerate([0, 1, 2, 2, 3, 0, 1, 2, 3, 0]):
        f = Frame()
        f.put(channels - 1, 3)
        f.put(0, 4)
        if channels == 2: f.put(0, 1) # independent windows
        for channel in range(channels):
            f.channel(sequence, (i + channel) % 2, channel)
        frames.append(f.finish(channels))
    # Valid silent 1024 syntax lets the ADTS demuxer establish metadata.
    # Replace these equal-sized placeholders after extracting packet offsets.
    silent = Frame()
    silent.put(channels - 1, 3)
    silent.put(0, 4)
    if channels == 2: silent.put(0, 1)
    for _ in range(channels):
        silent.put(100, 8)
        silent.put(0, 11) # long ICS info, max_sfb=0
        silent.put(0, 3)
    silence = silent.finish(channels)[7:]
    placeholders = [f[:7] + silence + bytes(len(f) - 7 - len(silence)) for f in frames]
    movie = run(["-f", "aac", "-i", "pipe:0", "-c:a", "copy", "-bsf:a", "aac_adtstoasc",
                 "-movflags", "frag_keyframe+delay_moov+default_base_moof", "-f", "mp4", "pipe:1"], b"".join(placeholders))
    probe_args = ["-show_streams", "-show_packets", "-show_data", "-of", "json", "pipe:0"]
    probe = json.loads(run(probe_args, movie, probe=True))
    for packet, frame in zip(probe["packets"], frames, strict=True):
        position, size = int(packet["pos"]), int(packet["size"])
        assert size == len(frame) - 7
        movie = movie[:position] + frame[7:] + movie[position + size:]
    old_asc = dump_bytes(probe["streams"][0]["extradata"])
    asc = old_asc[:1] + bytes([old_asc[1] | 4]) + old_asc[2:]
    position = movie.index(old_asc, movie.index(b"esds"))
    movie = movie[:position] + asc + movie[position + len(asc):]
    probe = json.loads(run(probe_args, movie, probe=True))
    assert dump_bytes(probe["streams"][0]["extradata"]) == asc
    packets = probe["packets"]
    pcm = run(["-flags2", "+skip_manual", "-i", "pipe:0", "-f", "s16le", "pipe:1"], movie)
    assert len(pcm) == len(packets) * 960 * channels * 2
    prefix = "aac_960_" + name
    lines.append(emit(prefix + "_mp4_b64", movie))
    lines.append(emit(prefix + "_config_b64", asc))
    lines.append(emit(prefix + "_pcm_b64", pcm))
    lines.append(f"///|\nlet {prefix}_packets : Array[(Int64, UInt32)] = [")
    lines += [f'  ({packet["pos"]}, {packet["size"]}),' for packet in packets]
    lines.append("]\n")
    print(name, "MP4", len(movie), "ASC", asc.hex(), "packets", len(packets), "samples", len(pcm) // 2)
(ROOT / "libavformat/aac_960_realdata_wbtest.mbt").write_text("\n".join(lines), encoding="utf-8", newline="\n")
