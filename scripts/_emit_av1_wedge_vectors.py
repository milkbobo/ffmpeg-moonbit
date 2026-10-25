#!/usr/bin/env python3
"""Emit libavcodec/av1_mc_vectors/wedge_test.mbt from %TEMP%/wedge_dump.txt
(produced by .scratch/av1/wedge_cycle.py against dav1d 1.5.1 wedge.c and
mc_tmpl.c). Blend fixtures with more than 256 pixels are compared via FNV-32
checksum, smaller ones pixel by pixel."""
import io
import os

TMP = r'C:\Users\milkb\AppData\Local\Temp'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_mc_vectors', 'wedge_test.mbt')

# wslot order must match dump_wedge.c wedge_sizes[].
BS_LIST = [7, 8, 9, 11, 12, 13, 15, 16, 17]
II_BS_LIST = [7, 8, 11, 12, 13, 16, 17]
HASH_LIMIT = 256

def fnv32(values):
    h = 0x811C9DC5
    for v in values:
        for b in range(4):
            h = ((h ^ ((v >> (8 * b)) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
    return h

def s32(u):
    return u - (1 << 32) if u >= (1 << 31) else u

def wrap(items, indent='    ', per_line=12):
    lines = []
    for i in range(0, len(items), per_line):
        lines.append(indent + ', '.join(items[i:i + per_line]) + ',')
    return '\n'.join(lines)

def main():
    wedge = {}   # (layout, wslot, sign, idx) -> [values]
    ii = {}      # (layout, islot, mode) -> [values]
    blends = []  # (meta, in1, in2, out)
    lines = [l.split() for l in io.open(os.path.join(TMP, 'wedge_dump.txt'))]
    i = 0
    while i < len(lines):
        t = lines[i]
        if not t:
            i += 1
            continue
        if t[0] == 'W':
            key = tuple(int(x) for x in t[1:5])
            vals = [int(x, 16) for x in t[7:]]
            assert len(vals) == int(t[5]) * int(t[6])
            wedge[key] = vals
            i += 1
        elif t[0] == 'I':
            key = (int(t[1]), int(t[2]), int(t[3]))
            vals = [int(x, 16) for x in t[7:]]
            assert len(vals) == int(t[5]) * int(t[6])
            ii[key] = vals
            i += 1
        elif t[0] == 'B':
            meta = [int(x) for x in t[1:]]
            in1 = [int(x) for x in lines[i + 1][1:]]
            in2 = [int(x) for x in lines[i + 2][1:]]
            outv = [int(x) for x in lines[i + 3][1:]]
            assert len(in1) == meta[-2] * meta[-1]
            blends.append((meta, in1, in2, outv))
            i += 4
        else:
            i += 1
    assert len(wedge) == 864, len(wedge)
    assert len(ii) == 84, len(ii)
    assert len(blends) == 7, len(blends)

    wedge_hashes = [fnv32(wedge[(l, s, g, n)])
                    for l in range(3) for s in range(9)
                    for g in range(2) for n in range(16)]
    ii_hashes = [fnv32(ii[(l, s, m)]) for l in range(3) for s in range(7)
                 for m in range(4)]
    for l in range(3):  # DC masks are uniformly 32
        for s in range(7):
            assert set(ii[(l, s, 0)]) == {32}

    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Wedge and inter-intra compound masks and wedge blends, verified\n')
    w('/// against dav1d 1.5.1 `src/wedge.c` and `mc_tmpl.c` `mask_c` via a\n')
    w('/// standalone C dumper (`scripts/_emit_av1_wedge_vectors.py`).\n\n')
    w('///|\n')
    w('fn av1_wedge_test_fnv32(values : FixedArray[Int32]) -> Int32 {\n')
    w('  let mut h : UInt = 0x811c9dc5\n')
    w('  for v in values {\n')
    w('    for b in 0..<4 {\n')
    w('      h = (h ^ (((v >> (8 * b)) & 0xff).reinterpret_as_uint())) * 0x01000193\n')
    w('    }\n')
    w('  }\n')
    w('  h.reinterpret_as_int()\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_wedge_test_expect(what : String, got : Int32, want : Int32) -> Unit raise {\n')
    w('  if got != want {\n')
    w('    fail("\\{what}: got \\{got}, want \\{want}")\n')
    w('  }\n')
    w('}\n\n')

    w('///|\n')
    w('test "av1 wedge masks match dav1d C reference" {\n')
    w('  let bs_list : FixedArray[Int] = [7, 8, 9, 11, 12, 13, 15, 16, 17]\n')
    w('  let expected : FixedArray[Int32] = [\n')
    w(wrap([str(s32(h)) for h in wedge_hashes]) + '\n')
    w('  ]\n')
    w('  let mut k = 0\n')
    w('  for layout in 0..<3 {\n')
    w('    for wslot in 0..<9 {\n')
    w('      for sign in 0..<2 {\n')
    w('        for idx in 0..<16 {\n')
    w('          let m = @av1_mc_core.av1_wedge_mask(layout, bs_list[wslot], sign, idx)\n')
    w('          av1_wedge_test_expect(\n')
    w('            "wedge layout=\\{layout} bs=\\{bs_list[wslot]} sign=\\{sign} idx=\\{idx}",\n')
    w('            av1_wedge_test_fnv32(m), expected[k],\n')
    w('          )\n')
    w('          k = k + 1\n')
    w('        }\n')
    w('      }\n')
    w('    }\n')
    w('  }\n')
    w('}\n\n')

    w('///|\n')
    w('test "av1 inter-intra masks match dav1d C reference" {\n')
    w('  let bs_list : FixedArray[Int] = [7, 8, 11, 12, 13, 16, 17]\n')
    w('  let expected : FixedArray[Int32] = [\n')
    w(wrap([str(s32(h)) for h in ii_hashes]) + '\n')
    w('  ]\n')
    w('  let mut k = 0\n')
    w('  for layout in 0..<3 {\n')
    w('    for slot in 0..<7 {\n')
    w('      for mode in 0..<4 {\n')
    w('        let m = @av1_mc_core.av1_ii_mask(layout, bs_list[slot], mode)\n')
    w('        av1_wedge_test_expect(\n')
    w('          "ii layout=\\{layout} bs=\\{bs_list[slot]} mode=\\{mode}",\n')
    w('          av1_wedge_test_fnv32(m), expected[k],\n')
    w('        )\n')
    w('        if mode == 0 {\n')
    w('          // DC masks are uniformly 32.\n')
    w('          for i in 0..<m.length() {\n')
    w('            if m[i] != 32 {\n')
    w('              fail("ii dc mask not constant 32")\n')
    w('            }\n')
    w('          }\n')
    w('        }\n')
    w('        k = k + 1\n')
    w('      }\n')
    w('    }\n')
    w('  }\n')
    w('}\n\n')

    w('///|\n')
    w('test "av1 wedge mask literals match dav1d byte for byte" {\n')
    literals = [
        ('32x32 4:4:4 wedge idx 1', 0, 0, 0, 1),
        ('8x8 4:2:0 wedge sign 1 idx 12', 2, 8, 1, 12),
        ('32x8 4:2:2 wedge idx 5', 1, 2, 0, 5),
    ]
    for name, layout, wslot, sign, idx in literals:
        vals = wedge[(layout, wslot, sign, idx)]
        w(f'  let m = @av1_mc_core.av1_wedge_mask({layout}, {BS_LIST[wslot]}, {sign}, {idx})\n')
        w('  // ' + name + '\n')
        w('  let expected : FixedArray[Int32] = [\n')
        w(wrap([str(v) for v in vals], '    ', 16) + '\n')
        w('  ]\n')
        w('  if m.length() != expected.length() {\n')
        w('    fail("' + name + ': length mismatch")\n')
        w('  }\n')
        w('  for i in 0..<m.length() {\n')
        w('    av1_wedge_test_expect("' + name + ' byte \\{i}", m[i], expected[i])\n')
        w('  }\n')
    # inter-intra smooth literal
    vals = ii[(2, 6, 3)]
    w('  let m = @av1_mc_core.av1_ii_mask(2, 17, 3)\n')
    w('  // 8x8 4:2:0 inter-intra smooth\n')
    w('  let expected : FixedArray[Int32] = [\n')
    w(wrap([str(v) for v in vals], '    ', 16) + '\n')
    w('  ]\n')
    w('  for i in 0..<m.length() {\n')
    w('    av1_wedge_test_expect("ii smooth byte \\{i}", m[i], expected[i])\n')
    w('  }\n')
    w('}\n\n')

    full = [(m, a, b, o) for (m, a, b, o) in blends
            if m[-2] * m[-1] <= HASH_LIMIT]
    hashed = [(m, a, b, o) for (m, a, b, o) in blends
              if m[-2] * m[-1] > HASH_LIMIT]
    w('///|\n')
    w('test "av1 wedge compound blends match dav1d mask_c" {\n')
    w('  let bs_list : FixedArray[Int] = [7, 8, 9, 11, 12, 13, 15, 16, 17]\n')
    for meta, in1, in2, outv in full:
        bitdepth, layout, wslot, sign, idx, fw, fh = meta
        name = 'blend {bd}b layout={la} sign={sg} idx={ix}'.format(
            bd=bitdepth, la=layout, sg=sign, ix=idx)
        w(f'  // {fw}x{fh} bitdepth={bitdepth} layout={layout} sign={sign} idx={idx}\n')
        w(f'  let mask = @av1_mc_core.av1_wedge_mask({layout}, bs_list[{wslot}], {sign}, {idx})\n')
        w('  let in1 : FixedArray[Int32] = [\n')
        w(wrap([str(x) for x in in1]) + '\n')
        w('  ]\n')
        w('  let in2 : FixedArray[Int32] = [\n')
        w(wrap([str(x) for x in in2]) + '\n')
        w('  ]\n')
        w('  let expected : FixedArray[Int32] = [\n')
        w(wrap([str(x) for x in outv]) + '\n')
        w('  ]\n')
        w(f'  let blended = @av1_mc_core.av1_mc_mask(in1, in2, mask, {bitdepth})\n')
        w('  for i in 0..<expected.length() {\n')
        w(f'    av1_wedge_test_expect("{name} px \\{{i}}", blended[i], expected[i])\n')
        w('  }\n')
    w('}\n\n')

    w('///|\n')
    w('test "av1 wedge compound blend checksums match dav1d mask_c" {\n')
    w('  let bs_list : FixedArray[Int] = [7, 8, 9, 11, 12, 13, 15, 16, 17]\n')
    for meta, in1, in2, outv in hashed:
        bitdepth, layout, wslot, sign, idx, fw, fh = meta
        name = 'blend {bd}b layout={la} sign={sg} idx={ix}'.format(
            bd=bitdepth, la=layout, sg=sign, ix=idx)
        w(f'  // {fw}x{fh} bitdepth={bitdepth} layout={layout} sign={sign} idx={idx}\n')
        w(f'  let mask = @av1_mc_core.av1_wedge_mask({layout}, bs_list[{wslot}], {sign}, {idx})\n')
        w('  let in1 : FixedArray[Int32] = [\n')
        w(wrap([str(x) for x in in1]) + '\n')
        w('  ]\n')
        w('  let in2 : FixedArray[Int32] = [\n')
        w(wrap([str(x) for x in in2]) + '\n')
        w('  ]\n')
        w(f'  let blended = @av1_mc_core.av1_mc_mask(in1, in2, mask, {bitdepth})\n')
        want = s32(fnv32(outv))
        w(f'  av1_wedge_test_expect("{name} fnv", av1_wedge_test_fnv32(blended), {want})\n')
    w('}\n\n')

    io.open(OUT, 'w', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')

if __name__ == '__main__':
    main()
