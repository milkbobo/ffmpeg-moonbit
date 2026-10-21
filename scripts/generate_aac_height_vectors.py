"""FFmpeg 9.0.2 references for AAC indexed 11..14 and height PCE layouts.

Synthetic raw packets use distinct codebook-5 spectra per channel and
alternate element arrival order. ffprobe supplies ASC/packet metadata;
FFmpeg decoding the identical encoded bytes supplies every PCM sample.
Indexed MP4s start with equal-sized stereo placeholder packets, then
replace ASC, sample-entry channel count and packets. PCE MP4s use the
ADTS-to-ASC bitstream filter; 960 fixtures set ASC frameLengthFlag.
"""
import base64
import json
from pathlib import Path
import re
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT.parent / "libavcodec/aactab.c").read_text(encoding="utf-8")


def table(name):
    body = re.search(r"\b" + name + r"\s*\[[^]]*\]\s*=\s*\{([^}]+)\}", SOURCE).group(1)
    return [int(t.strip(), 0) for t in body.split(",") if t.strip()]


CODES, BITS = table("codes5"), table("bits5")
# (type, tag, front/side/back/LFE, height). Source: aacdec_tab.c
# ff_aac_channel_layout_map; height represents its three ordered layers.
CONFIGS = {
    11: [(0, 0, 1, 0), (1, 0, 1, 0), (1, 1, 3, 0), (0, 1, 3, 0), (3, 0, 4, 0)],
    12: [(0, 0, 1, 0), (1, 0, 1, 0), (1, 1, 3, 0), (1, 2, 3, 0), (3, 0, 4, 0)],
    13: [(0, 0, 1, 0), (1, 0, 1, 0), (1, 1, 1, 0), (1, 2, 3, 0), (1, 3, 3, 0),
         (0, 1, 3, 0), (3, 0, 4, 0), (3, 1, 4, 0), (0, 2, 1, 1), (1, 4, 1, 1),
         (1, 5, 2, 1), (0, 3, 2, 1), (1, 6, 3, 1), (0, 4, 3, 1), (0, 5, 1, 2), (1, 7, 1, 2)],
    14: [(0, 0, 1, 0), (1, 0, 1, 0), (1, 1, 3, 0), (3, 0, 4, 0), (1, 2, 1, 1)],
}


def run(args, data, probe=False):
    command = ["docker", "run", "--rm", "-i"]
    if probe:
        command += ["--entrypoint", "ffprobe"]
    result = subprocess.run(command + ["linuxserver/ffmpeg:9.0.2", "-v", "error", *args],
                            input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or result.stderr:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def emit(name, data):
    chunks = textwrap.wrap(base64.b64encode(data).decode("ascii"), 112)
    return "///|\nlet " + name + " : Bytes = " + " +\n  ".join('b"' + c + '"' for c in chunks) + "\n"


def dump_bytes(dump):
    return b"".join(bytes.fromhex(line.split(":", 1)[1].strip().split("  ", 1)[0])
                    for line in dump.strip().splitlines())


class Frame:
    def __init__(self):
        self.bits = []

    def put(self, value, count):
        self.bits.extend((value >> i) & 1 for i in reversed(range(count)))

    def align(self):
        while len(self.bits) % 8:
            self.put(0, 1)

    def pce(self, elements):
        self.put(5, 3)
        self.put(0, 4)
        self.put(1, 2)
        self.put(3, 4)
        groups = [[e for e in elements if e[2] == group] for group in range(1, 5)]
        for entries, width in zip(groups, [4, 4, 4, 2]):
            self.put(len(entries), width)
        self.put(0, 3 + 4 + 3)
        for group, entries in enumerate(groups):
            for kind, tag, _, height in entries:
                if group != 3:
                    self.put(kind, 1)
                self.put(tag, 4)
        self.align()
        # Serialize the actual height extension independently of the main
        # writer's alignment, including the minimum 8 trailing comment bits.
        comment = Frame()
        comment.put(0xAC, 8)
        for entries in groups[:3]:
            for _, _, _, height in entries:
                comment.put(height, 2)
        comment.put(0, 8)
        comment.align()
        self.put(len(comment.bits) // 8, 8)
        self.bits.extend(comment.bits)

    def channel(self, seed, frame, sequence):
        short = sequence == 2
        self.put(144 + seed % 8 * 2, 8)
        self.put(0, 1)
        self.put(sequence, 2)
        self.put((seed + frame) % 2, 1)
        self.put(1, 4 if short else 6)
        self.put(127 if short else 0, 7 if short else 1)
        self.put(5, 4)
        self.put(1, 3 if short else 5)
        self.put(0, 1)  # scalefactor delta=0
        self.put(0, 3)
        for window in range(8 if short else 1):
            for pair in range(2):
                first = (seed + pair + window) % 7 - 3
                second = (seed // 2 + 3 * pair + window) % 7 - 3
                row = (first + 4) * 9 + second + 4
                self.put(CODES[row], BITS[row])

    def element(self, element, seed, frame, sequence):
        kind, tag, _, _ = element
        self.put(kind, 3)
        self.put(tag, 4)
        if kind == 1:
            self.put(0, 1)
        self.channel(seed, frame, sequence)
        if kind == 1:
            self.channel(seed + 1, frame, sequence)

    def finish(self, config=0):
        self.put(7, 3)
        self.align()
        payload = bytes(sum(self.bits[i + j] << (7 - j) for j in range(8))
                        for i in range(0, len(self.bits), 8))
        size = len(payload) + 7
        return bytes([255, 241, 76, (config << 6) | (size >> 11), (size >> 3) & 255,
                      ((size & 7) << 5) | 31, 252]) + payload


def frames_for(elements, pce):
    frames = []
    seeds, channel = {}, 0
    for kind, tag, group, height in elements:
        seeds[kind, tag] = channel
        channel += 2 if kind == 1 else 1
    for i, sequence in enumerate([0, 1, 2, 3]):
        frame = Frame()
        if pce and i == 0:
            frame.pce(elements)
        order = list(reversed(elements)) if pce and i % 2 == 0 else elements
        for element in order:
            frame.element(element, seeds[element[0], element[1]], i, sequence)
        frames.append(frame.finish())
    return frames, channel


def probe(movie):
    return json.loads(run(["-show_streams", "-show_packets", "-show_data", "-of", "json", "pipe:0"], movie, probe=True))


def movie_for(frames, config, channels):
    if config:
        # A valid stereo packet with empty spectra, padded after END to
        # exactly match each final raw packet's byte length.
        silent = Frame()
        silent.put(1, 3)
        silent.put(0, 5)  # tag/common_window
        for _ in range(2):
            silent.put(100, 8)
            silent.put(0, 14)  # ICS info and absent tools
        silence = silent.finish(2)[7:]
        encoded = b"".join(bytes([f[0], f[1], f[2], f[3] | 128]) + f[4:7] +
                           silence + bytes(len(f) - 7 - len(silence)) for f in frames)
    else:
        encoded = b"".join(frames)
    movie = run(["-f", "aac", "-i", "pipe:0", "-c:a", "copy", "-bsf:a", "aac_adtstoasc",
                 "-movflags", "frag_keyframe+delay_moov+default_base_moof", "-f", "mp4", "pipe:1"], encoded)
    metadata = probe(movie)
    if config:
        for packet, frame in zip(metadata["packets"], frames, strict=True):
            position, size = int(packet["pos"]), int(packet["size"])
            assert size == len(frame) - 7
            movie = movie[:position] + frame[7:] + movie[position + size:]
        old_asc = dump_bytes(metadata["streams"][0]["extradata"])
        assert len(old_asc) == 2
        asc = (0x1180 | (config << 3)).to_bytes(2, "big")
        position = movie.index(old_asc, movie.index(b"esds"))
        movie = movie[:position] + asc + movie[position + 2:]
        position = movie.index(b"mp4a") + 20
        assert movie[position:position + 2] == b"\x00\x02"
        movie = movie[:position] + channels.to_bytes(2, "big") + movie[position + 2:]
    return movie


header = ["///|\n/// Generated by scripts/generate_aac_height_vectors.py.",
          "/// Synthetic AAC-LC layouts; ffprobe metadata and FFmpeg 9.0.2 PCM references.",
          "/// Four window sequences, alternating shapes; PCE streams reverse element arrival order.",
          "/// LGPL-2.1-or-later.\n"]
codec_lines, format_lines = list(header), list(header)
for config in [11, 12, 13, 14]:
    frames, channels = frames_for(CONFIGS[config], pce=False)
    movie = movie_for(frames, config, channels)
    metadata = probe(movie)
    stream = metadata["streams"][0]
    assert stream["channels"] == channels
    asc = dump_bytes(stream["extradata"])
    pcm = run(["-flags2", "+skip_manual", "-i", "pipe:0", "-f", "s16le", "pipe:1"], movie)
    assert len(pcm) == 4 * 1024 * channels * 2
    prefix = f"aac_height_index{config}"
    format_lines.append(f'/// config {config}: ffprobe {stream.get("channel_layout")}, {channels} channels.\n')
    for suffix, data in [("mp4", movie), ("config", asc), ("pcm", pcm)]:
        format_lines.append(emit(prefix + "_" + suffix + "_b64", data))
    format_lines.append(f"///|\nlet {prefix}_packets : Array[(Int64, UInt32)] = [")
    format_lines.extend(f'  ({packet["pos"]}, {packet["size"]}),' for packet in metadata["packets"])
    format_lines.append("]\n")
    print(config, stream.get("channel_layout"), channels, "samples", len(pcm) // 2)

for name, elements in [("pce22", CONFIGS[13]), ("pce_top", CONFIGS[14]),
                       ("top_centers", [(0, 0, 1, 0), (1, 0, 1, 0), (1, 1, 3, 0),
                                        (3, 0, 4, 0), (0, 2, 1, 1), (1, 4, 1, 1),
                                        (1, 6, 3, 1), (0, 4, 3, 1)]),
                       ("reserved", [(1, 9, 1, 3)])]:
    frames, channels = frames_for(elements, pce=True)
    encoded = b"".join(frames)
    pcm = run(["-i", "pipe:0", "-f", "s16le", "pipe:1"], encoded)
    assert len(pcm) == 4 * 1024 * channels * 2
    codec_lines.append(emit("aac_height_" + name + "_b64", encoded))
    codec_lines.append(emit("aac_height_" + name + "_pcm_b64", pcm))
    print(name, channels, "samples", len(pcm) // 2)
    if name == "pce22":
        movie = movie_for(frames, 0, channels)
        metadata = probe(movie)
        old_asc = dump_bytes(metadata["streams"][0]["extradata"])
        asc = old_asc[:1] + bytes([old_asc[1] | 4]) + old_asc[2:]
        position = movie.index(old_asc, movie.index(b"esds"))
        movie = movie[:position] + asc + movie[position + len(asc):]
        metadata = probe(movie)
        pcm = run(["-flags2", "+skip_manual", "-i", "pipe:0", "-f", "s16le", "pipe:1"], movie)
        assert len(pcm) == 4 * 960 * channels * 2
        prefix = "aac_height_pce22_960"
        format_lines.append("/// 960 fixture timestamps retain remuxer's 1024 ticks; PCM retains complete frames.\n")
        for suffix, data in [("mp4", movie), ("config", asc), ("pcm", pcm)]:
            format_lines.append(emit(prefix + "_" + suffix + "_b64", data))
        format_lines.append(f"///|\nlet {prefix}_packets : Array[(Int64, UInt32)] = [")
        format_lines.extend(f'  ({packet["pos"]}, {packet["size"]}),' for packet in metadata["packets"])
        format_lines.append("]\n")
        print("pce22_960", channels, "samples", len(pcm) // 2)

(ROOT / "libavcodec/aac_height_realdata_wbtest.mbt").write_text("\n".join(codec_lines), encoding="utf-8", newline="\n")
(ROOT / "libavformat/aac_height_realdata_wbtest.mbt").write_text("\n".join(format_lines), encoding="utf-8", newline="\n")
