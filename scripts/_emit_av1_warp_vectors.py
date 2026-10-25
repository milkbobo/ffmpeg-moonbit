#!/usr/bin/env python3
"""Emit libavcodec/av1_mc_vectors/warp_test.mbt from
%TEMP%/warp_dump.txt (produced by .scratch/av1/warp_cycle.py against
dav1d 1.5.1 mc_tmpl.c warp kernels). Same padded-plane LCG scheme as the
scaled vectors."""
import io
import os

TMP = r'C:\Users\milkb\AppData\Local\Temp'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_mc_vectors', 'warp_test.mbt')

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
    planes = []
    cases = []
    lines = [l.split() for l in io.open(os.path.join(TMP, 'warp_dump.txt'))]
    i = 0
    while i < len(lines):
        t = lines[i]
        if not t:
            i += 1
            continue
        if t[0] in ('SRC', 'SRC16'):
            bd = 8 if t[0] == 'SRC' else int(t[1])
            w, h = int(t[-2]), int(t[-1])
            vals = []
            for r in range(h):
                vals += [int(x) for x in lines[i + 1 + r][1:]]
            assert len(vals) == w * h
            planes.append((bd, w, h, vals))
            i += 1 + h
        elif t[0] == 'O':
            bd, kind = int(t[1]), t[2]
            a, b, c, d, mx, my = [int(x) for x in t[3:9]]
            rows = []
            for r in range(8):
                rows.append([int(x) for x in lines[i + 1 + r][1:]])
            cases.append((bd, kind, (a, b, c, d, mx, my), rows))
            i += 9
        else:
            i += 1
    assert len(planes) == 3, len(planes)
    assert len(cases) == 10, len(cases)

    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Warp-affine 8x8 kernels verified against dav1d 1.5.1\n')
    w('/// `mc_tmpl.c` `warp_affine_8x8_c`/`warp_affine_8x8t_c` via a\n')
    w('/// standalone C dumper (`scripts/_emit_av1_warp_vectors.py`).\n')
    w('/// Planes are 112x80 (8px margins); the block anchors at (8, 8).\n\n')
    w('///|\n')
    w('fn av1_warp_test_fnv32(values : FixedArray[Int32]) -> Int32 {\n')
    w('  let mut h : UInt = 0x811c9dc5\n')
    w('  for v in values {\n')
    w('    for b in 0..<4 {\n')
    w('      h = (h ^ (((v >> (8 * b)) & 0xff).reinterpret_as_uint())) * 0x01000193\n')
    w('    }\n')
    w('  }\n')
    w('  h.reinterpret_as_int()\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_warp_test_lcg(seed : UInt, n : Int, maxv : Int) -> FixedArray[Int32] {\n')
    w('  let mut state = seed\n')
    w('  let out = FixedArray::make(n, 0)\n')
    w('  for i in 0..<n {\n')
    w('    state = state * 1664525 + 1013904223\n')
    w('    out[i] = ((state >> 8).reinterpret_as_int() % (maxv + 1))\n')
    w('  }\n')
    w('  out\n')
    w('}\n\n')
    w('///|\n')
    w('test "av1 warp affine matches dav1d C reference" {\n')
    w('  let plane8 = av1_warp_test_lcg(0x13579bdf, 112 * 80, 255)\n')
    w('  let plane10 = av1_warp_test_lcg(0x2468ace0, 112 * 80, 1023)\n')
    w('  let plane12 = av1_warp_test_lcg(0x2468ace0, 112 * 80, 4095)\n')
    for bd, pw, ph, vals in planes:
        w(f'  let pf{bd} = av1_warp_test_fnv32(plane{bd})\n')
        w(f'  if pf{bd} != {s32(fnv32(vals))} {{\n')
        w(f'    fail("plane{bd} fnv mismatch")\n')
        w('  }\n')
    w('\n')
    for bd, kind, (a, b, c, d, mx, my), rows in cases:
        want = [v for r in rows for v in r]
        fn = ('av1_mc_warp_affine_8x8t' if kind == 'warpp'
              else 'av1_mc_warp_affine_8x8')
        name = f'{kind} {bd}b abcd=({a},{b},{c},{d}) mx={mx} my={my}'
        w(f'  // {name}\n')
        w(f'  let abcd : FixedArray[Int32] = [{a}, {b}, {c}, {d}]\n')
        w(f'  let out = @av1_mc_core.{fn}(plane{bd}, 112, 112, 80, 8, 8, abcd, {mx}, {my}, {bd})\n')
        w('  let expected : FixedArray[Int32] = [\n')
        w(wrap([str(v) for v in want]) + '\n')
        w('  ]\n')
        w('  for i in 0..<expected.length() {\n')
        w(f'    if out[i] != expected[i] {{\n')
        w(f'      fail("{name} px \\{{i}}: got \\{{out[i]}}, want \\{{expected[i]}}")\n')
        w('    }\n')
        w('  }\n\n')
    w('}\n')
    io.open(OUT, 'w', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')

if __name__ == '__main__':
    main()
