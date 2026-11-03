#!/usr/bin/env bash
# Regenerate the MP3 (shine) encoder tables and test fixtures from the C
# reference. Everything lives under _ref/shine (gitignored):
#   1. fetch shine 3.1.1 if missing and patch the stale header prototype
#   2. build the table dumper, the deterministic-ln patch and the harness
#   3. dump tables -> libavcodec/mp3_enc_tables.mbt   (zero transcription)
#   4. encode the three vectors -> libavcodec/mp3_encode_vectors/fixtures.mbt
#
# The harness output is byte-identical to shineenc (checked inline for v1).
# Requires: gcc, python3, curl.
set -euo pipefail
cd "$(dirname "$0")/.."
REF=_ref/shine
SRC=$REF/shine-3.1.1/src/lib

mkdir -p "$REF"
if [ ! -f "$SRC/layer3.c" ]; then
  curl -sL --max-time 120 https://github.com/toots/shine/archive/refs/tags/3.1.1.tar.gz -o "$REF/shine.tar.gz"
  tar xzf "$REF/shine.tar.gz" -C "$REF"
fi
# the 3.1.1 release ships a stale K&R prototype that gcc 16 rejects
sed -i 's/void shine_mdct_initialise();/void shine_mdct_initialise(shine_global_config *config);/' "$SRC/l3mdct.h"

LIB_SOURCES=("$SRC/tables.c" "$SRC/huffman.c" "$SRC/layer3.c" "$SRC/l3subband.c" "$SRC/l3mdct.c" "$SRC/reservoir.c" "$SRC/l3bitstream.c" "$SRC/bitstream.c")
LOOPSRC="$SRC/l3loop.c"

# shine's calc_scfsi uses libm log(); patch it with the deterministic
# shine_ref_log (same algorithm as MoonBit mp3enc_ln) so the truncation to
# Int is reproducible on wasm
gcc -O2 -c -Dlog=shine_ref_log -I"$SRC" -o "$REF/l3loop_patched.o" "$LOOPSRC"
gcc -O2 -c -o "$REF/shine_ln.o" "$REF/shine_ln.c"

# 1) table dumper (includes huffman.c textually for the static code arrays)
DUMPER_SOURCES=("$SRC/tables.c" "$SRC/layer3.c" "$SRC/l3subband.c" "$SRC/l3mdct.c" "$SRC/l3loop.c" "$SRC/reservoir.c" "$SRC/l3bitstream.c" "$SRC/bitstream.c")
gcc -O2 -o "$REF/dumper.exe" "$REF/dumper.c" "${DUMPER_SOURCES[@]}" -I"$SRC" -lm
"$REF/dumper.exe" > "$REF/tables_dump.txt"
python3 -I scripts/extract_mp3_enc_tables.py "$REF/tables_dump.txt" libavcodec/mp3_enc_tables.mbt

# 2) reference harness (staged pipeline, byte-identical to shineenc)
gcc -O2 -o "$REF/harness.exe" "$REF/harness.c" "${LIB_SOURCES[@]}" "$REF/l3loop_patched.o" "$REF/shine_ln.o" -I"$SRC" -lm
gcc -O2 -o "$REF/shineenc.exe" "$SRC/../bin/main.c" "$SRC/../bin/wave.c" "${LIB_SOURCES[@]}" "$LOOPSRC" -I"$SRC" -lm
"$REF/harness.exe" 12 44100 2 128 "$REF/v1" "$REF/v1.dump"
"$REF/harness.exe" 12 48000 1 192 "$REF/v2" "$REF/v2.dump"
"$REF/harness.exe" 12 22050 1 64 "$REF/v3" "$REF/v3.dump"

# sanity: the staged harness must be byte-identical to the unmodified shineenc
python3 - "$REF" <<'EOF'
import struct, sys
ref = sys.argv[1]
pcm = open(f"{ref}/v1.pcm", "rb").read()
hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack(
    "<IHHIIHH", 16, 1, 2, 44100, 44100 * 4, 4, 16) + b"data" + struct.pack("<I", len(pcm))
open(f"{ref}/v1.wav", "wb").write(hdr + pcm)
EOF
"$REF/shineenc.exe" -b 128 "$REF/v1.wav" "$REF/v1_shineenc.mp3"
md5sum "$REF/v1.mp3" "$REF/v1_shineenc.mp3"

python3 -I scripts/gen_mp3_enc_vectors.py "$REF" libavcodec/mp3_encode_vectors/fixtures.mbt
echo "done"
