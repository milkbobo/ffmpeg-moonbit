"""Synthesize AAC-LC CCE syntax; FFmpeg 9.0.2 supplies every expected sample.

PCEs declare the audible elements and all coupling tags. ADTS is 48 kHz,
config=0. Gain VLCs/codebook 5 are read directly from aactab.c. Tests cover
all coupling points, gain scales, signed cumulative gains, CPE selections,
multiple CCEs in reversed tag order, TNS and grouped short windows.
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


SF_CODES, SF_BITS = table("ff_aac_scalefactor_code"), table("ff_aac_scalefactor_bits")
CODES, BITS = table("codes5"), table("bits5")


class Frame:
    def __init__(self):
        self.bits = []

    def put(self, value, count):
        self.bits.extend((value >> i) & 1 for i in reversed(range(count)))

    def sf(self, delta):
        self.put(SF_CODES[60 + delta], SF_BITS[60 + delta])

    def pce(self, stereo, sources):
        self.put(5, 3)
        self.put(0, 4)
        self.put(1, 2)  # LC
        self.put(3, 4)  # 48 kHz
        self.put(1, 4)  # one front SCE or CPE
        self.put(0, 4 + 4 + 2 + 3)
        self.put(len(sources), 4)
        self.put(0, 3)
        self.put(int(stereo), 1)
        self.put(0, 4)
        for tag, point in sources:
            self.put(int(point == 3), 1)
            self.put(tag, 4)
        while len(self.bits) % 8:
            self.put(0, 1)
        # FFmpeg's PCE precheck reserves nine bits per coupling entry,
        # although the syntax consumes five. A comment keeps standalone
        # ASC PCEs above that conservative bound after ADTS remuxing.
        self.put(4, 8)
        self.put(0, 32)

    def channel(self, sequence, shape, seed, tns=False):
        short = sequence == 2
        groups = [2, 3, 3] if short else [1]
        self.put(148 + seed % 3 * 4, 8)
        self.put(0, 1)
        self.put(sequence, 2)
        self.put(shape, 1)
        self.put(3, 4 if short else 6)
        self.put(0b1011011 if short else 0, 7 if short else 1)
        for _ in groups:
            for book in [5, 0, 5]:
                self.put(book, 4)
                self.put(1, 3 if short else 5)
        for _ in groups:
            self.sf(0)
            self.sf(0)
        self.put(0, 1)  # no pulse
        self.put(int(tns), 1)
        if tns:
            for window in range(8 if short else 1):
                self.put(1, 1 if short else 2)
                self.put(0, 1)  # coefficient resolution 3
                self.put(14 if short else 49, 4 if short else 6)
                self.put(1, 3 if short else 5)
                self.put(seed % 2, 1)
                self.put(0, 1)
                self.put(1 if window % 2 else 7, 3)
        self.put(0, 1)  # no gain control
        window = 0
        for group in groups:
            for band in [0, 2]:
                for w in range(group):
                    for pair in range(2):
                        first = (seed + window + w + pair + band) % 7 - 3
                        second = (seed + 3 * pair + band) % 7 - 3
                        row = (first + 4) * 9 + second + 4
                        self.put(CODES[row], BITS[row])
            window += group

    def cce(self, tag, point, targets, sequence, shape, scale, signed, common, tns):
        self.put(2, 3)
        self.put(tag, 4)
        self.put(int(point == 3), 1)
        self.put(len(targets) - 1, 3)
        gains = 0
        for kind, target, select in targets:
            self.put(kind, 1)
            self.put(target, 4)
            if kind:
                self.put(select, 2)
            gains += 2 if select == 3 else 1
        self.put(int(point != 0), 1)
        self.put(int(signed), 1)
        self.put(scale, 2)
        self.channel(sequence, shape, tag + 2, tns)
        for index in range(1, gains):
            if point != 3:
                self.put(int(common), 1)
            if point == 3 or common:
                self.sf(index % 4 - 1)
            else:
                for group in range(3 if sequence == 2 else 1):
                    for delta in ([1, 0] if group % 2 == 0 else [-3, 2]):
                        self.sf(delta)

    def finish(self):
        self.put(7, 3)
        while len(self.bits) % 8:
            self.put(0, 1)
        payload = bytes(sum(self.bits[i + j] << (7 - j) for j in range(8))
                        for i in range(0, len(self.bits), 8))
        size = len(payload) + 7
        return bytes([255, 241, 76, size >> 11, (size >> 3) & 255,
                      ((size & 7) << 5) | 31, 252]) + payload


def emit(name, data):
    chunks = textwrap.wrap(base64.b64encode(data).decode("ascii"), 112)
    return "///|\nlet " + name + " : Bytes = " + " +\n  ".join('b"' + c + '"' for c in chunks) + "\n"


lines = ["///|\n/// Generated by scripts/generate_aac_coupling_vectors.py.",
         "/// Synthetic LC CCE/PCE syntax; PCM decoded by Docker linuxserver/ffmpeg:9.0.2.",
         "/// See generator for gain/selection/TNS/window coverage. LGPL-2.1-or-later.\n"]
lines_960 = ["///|\n/// Generated by scripts/generate_aac_coupling_vectors.py.",
             "/// Synthetic CCE/PCE MP4: ASC frameLengthFlag=1, PCM decoded by FFmpeg 9.0.2.",
             "/// Fixture packet timestamps retain 1024 ticks; complete PCM frames have 960 samples.",
             "/// LGPL-2.1-or-later.\n"]


def run(args, data, probe=False):
    command = ["docker", "run", "--rm", "-i"]
    if probe:
        command += ["--entrypoint", "ffprobe"]
    result = subprocess.run(command + ["linuxserver/ffmpeg:9.0.2", "-v", "error", *args],
                            input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or result.stderr:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def dump_bytes(dump):
    return b"".join(bytes.fromhex(line.split(":", 1)[1].strip().split("  ", 1)[0])
                    for line in dump.strip().splitlines())


def vector_960(name, encoded):
    # Only bands 0..2 are nonzero; their offsets match 960/1024 and
    # 120/128 at 48 kHz. TNS band counts also match, so the packet syntax
    # is valid for both lengths and ASC selects synthesis geometry.
    movie = run(["-f", "aac", "-i", "pipe:0", "-c:a", "copy", "-bsf:a", "aac_adtstoasc",
                 "-movflags", "frag_keyframe+delay_moov+default_base_moof", "-f", "mp4", "pipe:1"], encoded)
    probe_args = ["-show_streams", "-show_packets", "-show_data", "-of", "json", "pipe:0"]
    probe = json.loads(run(probe_args, movie, probe=True))
    old_asc = dump_bytes(probe["streams"][0]["extradata"])
    asc = old_asc[:1] + bytes([old_asc[1] | 4]) + old_asc[2:]
    position = movie.index(old_asc, movie.index(b"esds"))
    movie = movie[:position] + asc + movie[position + len(asc):]
    probe = json.loads(run(probe_args, movie, probe=True))
    assert dump_bytes(probe["streams"][0]["extradata"]) == asc
    pcm = run(["-flags2", "+skip_manual", "-i", "pipe:0", "-f", "s16le", "pipe:1"], movie)
    packets = probe["packets"]
    assert len(pcm) == len(packets) * 960 * 2 * 2
    prefix = "aac_coupling_960_" + name
    lines_960.append(emit(prefix + "_mp4_b64", movie))
    lines_960.append(emit(prefix + "_config_b64", asc))
    lines_960.append(emit(prefix + "_pcm_b64", pcm))
    lines_960.append(f"///|\nlet {prefix}_packets : Array[(Int64, UInt32)] = [")
    lines_960.extend(f'  ({packet["pos"]}, {packet["size"]}),' for packet in packets)
    lines_960.append("]\n")
    print(name, "960 samples", len(pcm) // 2)
for name, stereo, point, common, signed, multiple in [
    ("before_tns", False, 0, False, True, False),
    ("after_tns", False, 1, False, False, False),
    ("independent", False, 3, True, False, False),
    ("stereo_select", True, 0, True, False, False),
    ("stereo_signed", True, 1, False, True, False),
    ("stereo_independent", True, 3, True, True, False),
    ("multiple", True, 0, False, True, True),
]:
    frames = []
    for i, sequence in enumerate([0, 1, 2, 2, 3, 0, 1, 2, 3, 0]):
        sources = [(9, point)] if not multiple else [(9, 3), (2, 1), (5, 0)]
        f = Frame()
        f.pce(stereo, sources)
        def audio():
            f.put(int(stereo), 3)
            f.put(0, 4)
            if stereo:
                f.put(0, 1)  # independent CPE info, no M/S
            for channel in range(2 if stereo else 1):
                f.channel(sequence, (i + channel) % 2, channel, tns=True)
        if i % 2:
            audio()
        for tag, position in sources:
            targets = [(int(stereo), 0, i % 4 if stereo else 2)]
            # Repeated targets intentionally exercise every gain list, up to
            # the syntax maximum of eight CPE targets / sixteen gain lists.
            if i == 9 and stereo:
                targets = [(1, 0, 3)] * 8
            elif not stereo:
                targets *= 2
            f.cce(tag, position, targets, sequence, (i + 1) % 2, i % 4,
                  signed, common, tns=True)
        if not i % 2:
            audio()
        frames.append(f.finish())
    encoded = b"".join(frames)
    result = subprocess.run(["docker", "run", "--rm", "-i", "linuxserver/ffmpeg:9.0.2",
                             "-v", "error", "-i", "pipe:0", "-f", "s16le", "pipe:1"],
                            input=encoded, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or result.stderr:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    assert len(result.stdout) == 10 * 1024 * (2 if stereo else 1) * 2
    lines.append(emit("aac_coupling_" + name + "_b64", encoded))
    lines.append(emit("aac_coupling_" + name + "_pcm_b64", result.stdout))
    print(name, "ADTS", len(encoded), "PCM samples", len(result.stdout) // 2)
    if name in ("stereo_independent", "multiple"):
        vector_960(name, encoded)
(ROOT / "libavcodec/aac_coupling_realdata_wbtest.mbt").write_text("\n".join(lines), encoding="utf-8", newline="\n")
(ROOT / "libavformat/aac_coupling_960_realdata_wbtest.mbt").write_text("\n".join(lines_960), encoding="utf-8", newline="\n")
