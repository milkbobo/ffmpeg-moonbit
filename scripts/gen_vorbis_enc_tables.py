# Extract the Vorbis encoder tables from libavcodec/vorbis_enc_data.h into
# libavcodec/vorbis_enc_tables.mbt.
#
# Usage: python -I scripts/gen_vorbis_enc_tables.py ../libavcodec/vorbis_enc_data.h libavcodec
import re
import sys


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()

    # codebooks[]: uint8_t blob; strip /* */ comments first (they contain
    # element counts like "Codebook 0 - 16 elements").
    m = re.search(r"static const uint8_t codebooks\[\] = \{(.*?)\};", text, re.S)
    body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
    clens = [int(x) for x in re.findall(r"\d+", body)]
    # quant_tables[]: int blob.
    m = re.search(r"static const uint8_t quant_tables\[\] = \{(.*?)\};", text, re.S)
    quants = [int(x) for x in re.findall(r"\d+", re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S))]

    # cvectors: { dim, len, real_len, lookup[, min, delta] }
    m = re.search(r"\} cvectors\[\] = \{(.*?)\};", text, re.S)
    rows = re.findall(r"\{([^}]*)\}", m.group(1))
    cvec = []
    for r in rows:
        vals = [v.strip() for v in r.split(",") if v.strip()]
        dim = int(vals[0])
        ln = int(vals[1])
        real = int(vals[2])
        lookup = int(vals[3])
        mn = float(vals[4]) if len(vals) > 4 else 0.0
        delta = float(vals[5]) if len(vals) > 5 else 0.0
        cvec.append((dim, ln, real, lookup, mn, delta))

    # floor_classes
    # floor_classes rows contain nested { nbooks } braces; parse line-wise.
    m = re.search(r"\} floor_classes\[\] = \{(.*?)\};", text, re.S)
    classes = []
    for line in m.group(1).strip().splitlines():
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        outer = re.match(r"\{\s*(\d+),\s*(\d+),\s*(\d+),\s*\{([^}]*)\}\s*\}", line)
        if not outer:
            continue
        dim = int(outer.group(1))
        subclass = int(outer.group(2))
        master = int(outer.group(3))
        books = [int(v.strip()) for v in outer.group(4).split(",") if v.strip()]
        books = (books + [-1, -1, -1, -1])[:4]
        classes.append((dim, subclass, master, books))

    def blob_lines(vals, per=20):
        lines = []
        for i in range(0, len(vals), per):
            chunk = ", ".join(str(v) for v in vals[i : i + per])
            lines.append("  " + chunk + ",")
        return "\n".join(lines)

    cv_lines = []
    for dim, ln, real, lookup, mn, delta in cvec:
        mn_s = repr(mn) if mn else "0.0"
        delta_s = repr(delta) if delta else "0.0"
        cv_lines.append(
            f"  {{ dim: {dim}, len: {ln}, real_len: {real}, lookup: {lookup}, min: {mn_s}, delta: {delta_s} }},"
        )

    cls_lines = []
    for dim, subclass, master, books in classes:
        bk = ", ".join(str(b) for b in books)
        cls_lines.append(
            f"  {{ dim: {dim}, subclass: {subclass}, masterbook: {master}, nbooks: [{bk}] }},"
        )

    out = f'''///|
/// Vorbis encoder tables extracted from FFmpeg 9.0.2
/// `libavcodec/vorbis_enc_data.h` by `scripts/gen_vorbis_enc_tables.py`
/// (rerun to regenerate).  Original FFmpeg code is LGPL-2.1-or-later.

///| `cvectors` entries.
pub struct VorbisEncCvectorRaw {{
  dim : Int32
  len : Int32
  real_len : Int32
  lookup : Int32
  min : Double
  delta : Double
}}

///| `floor_classes` entries.
pub struct VorbisEncFloorClassRaw {{
  dim : Int32
  subclass : Int32
  masterbook : Int32
  nbooks : FixedArray[Int32]
}}

///| `cvectors` (30 codebooks).
pub let vorbis_enc_cvectors : Array[VorbisEncCvectorRaw] = [
{chr(10).join(cv_lines)}
]

///| `floor_classes` (5 classes).
pub let vorbis_enc_floor_classes : Array[VorbisEncFloorClassRaw] = [
{chr(10).join(cls_lines)}
]

///| `codebooks[]`: concatenated codebook code lengths.
pub let vorbis_enc_codebooks : Array[Int32] = [
{blob_lines(clens)}
]

///| `quant_tables[]`: concatenated VQ quant lists.
pub let vorbis_enc_quant_tables : Array[Int32] = [
{blob_lines(quants)}
]
'''
    with open(f"{outdir}/vorbis_enc_tables.mbt", "w", newline="\n") as f:
        f.write(out)
    print("clens", len(clens), "quants", len(quants), "cvectors", len(cvec), "classes", len(classes))


main()
