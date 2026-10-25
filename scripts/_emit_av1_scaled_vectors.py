#!/usr/bin/env python3
"""Emit libavcodec/av1_mc_vectors/scaled_test.mbt from
%TEMP%/scaled_dump.txt (produced by .scratch/av1/scaled_cycle.py against
dav1d 1.5.1 mc_tmpl.c scaled kernels). Source planes are regenerated with
the dumper's LCG and anchored by FNV-32 checksums; outputs are compared
pixel by pixel."""
import io
import os

TMP = r'C:\Users\milkb\AppData\Local\Temp'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_mc_vectors', 'scaled_test.mbt')

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

def lcg_plane(seed, n, maxv):
    state = seed
    out = []
    mask = (1 << 32) - 1
    for _ in range(n):
        state = (state * 1664525 + 1013904223) & mask
        out.append((state >> 8) % (maxv + 1))
    return out

def filter2d_of(comp):
    h, v = comp & 3, comp >> 2
    group = 0 if h == 0 else (1 if h == 2 else 2)
    return 3 * group + v

def main():
    planes = []       # (bitdepth, w, h, values, fnv)
    cases = []        # (bitdepth, kind, params..., rows)
    lines = [l.split() for l in io.open(os.path.join(TMP, 'scaled_dump.txt'))]
    i = 0
    while i < len(lines):
        t = lines[i]
        if not t:
            i += 1
            continue
        if t[0] in ('SRC', 'SRC16'):
            bd = 8 if t[0] == 'SRC' else int(t[1])
            w, h = int(t[2]), int(t[3])
            vals = []
            for r in range(h):
                vals += [int(x) for x in lines[i + 1 + r][1:]]
            assert len(vals) == w * h
            planes.append((bd, w, h, vals))
            i += 1 + h
        elif t[0] == 'O':
            bd = int(t[1])
            kind = t[2]
            if kind == 'resize':
                params = [int(x) for x in t[3:]]  # dst_w h src_w dx mx0
                w, h = params[0], params[1]
            else:
                params = [int(x) for x in t[3:10]]  # w h mx my dx dy filter
                w, h = params[0], params[1]
            rows = []
            for r in range(h):
                rows.append([int(x) for x in lines[i + 1 + r][1:]])
            cases.append((bd, kind, params, rows))
            i += 1 + h
        else:
            i += 1
    assert len(planes) == 3, len(planes)
    assert len(cases) == 25, len(cases)

    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Scaled-reference MC and superres resize kernels verified against\n')
    w('/// dav1d 1.5.1 `mc_tmpl.c` scaled functions via a standalone C dumper\n')
    w('/// (`scripts/_emit_av1_scaled_vectors.py`). Source planes are rebuilt\n')
    w('/// with the dumper LCG and anchored by FNV-32.\n\n')
    w('///|\n')
    w('fn av1_scaled_test_fnv32(values : FixedArray[Int32]) -> Int32 {\n')
    w('  let mut h : UInt = 0x811c9dc5\n')
    w('  for v in values {\n')
    w('    for b in 0..<4 {\n')
    w('      h = (h ^ (((v >> (8 * b)) & 0xff).reinterpret_as_uint())) * 0x01000193\n')
    w('    }\n')
    w('  }\n')
    w('  h.reinterpret_as_int()\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_scaled_test_lcg(seed : UInt, n : Int, maxv : Int) -> FixedArray[Int32] {\n')
    w('  let mut state = seed\n')
    w('  let out = FixedArray::make(n, 0)\n')
    w('  for i in 0..<n {\n')
    w('    state = state * 1664525 + 1013904223\n')
    w('    out[i] = ((state >> 8).reinterpret_as_int() % (maxv + 1))\n')
    w('  }\n')
    w('  out\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_scaled_test_expect(what : String, got : Int32, want : Int32) -> Unit raise {\n')
    w('  if got != want {\n')
    w('    fail("\\{what}: got \\{got}, want \\{want}")\n')
    w('  }\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_scaled_test_px(what : String, got : FixedArray[Int32], want : Array[Int32]) -> Unit raise {\n')
    w('  if got.length() != want.length() {\n')
    w('    fail("\\{what}: length \\{got.length()} != \\{want.length()}")\n')
    w('  }\n')
    w('  for i in 0..<want.length() {\n')
    w('    if got[i] != want[i] {\n')
    w('      fail("\\{what} px \\{i}: got \\{got[i]}, want \\{want[i]}")\n')
    w('    }\n')
    w('  }\n')
    w('}\n\n')

    w('///|\n')
    w('test "av1 scaled MC matches dav1d C reference" {\n')
    # Planes are 112x80 (96x64 content with 8px margins); MC kernels sit at
    # the center, expressed as a +8px = +8192 offset on mx/my.
    w('  let plane8 = av1_scaled_test_lcg(0x1a2b3c4d, 112 * 80, 255)\n')
    w('  let plane10 = av1_scaled_test_lcg(0xfeedface, 112 * 80, 1023)\n')
    w('  let plane12 = av1_scaled_test_lcg(0xfeedface, 112 * 80, 4095)\n')
    for bd, pw, ph, vals in planes:
        w(f'  av1_scaled_test_expect("plane{bd} fnv", av1_scaled_test_fnv32(plane{bd}), {s32(fnv32(vals))})\n')
    w('\n')
    for bd, kind, params, rows in cases:
        want = [v for r in rows for v in r]
        name = '{k} {bd}b {p}'.format(k=kind, bd=bd, p=' '.join(str(x) for x in params))
        if kind == 'resize':
            dst_w, hh, src_w, dx, mx0 = params
            w(f'  // resize dst_w={dst_w} h={hh} src_w={src_w} dx={dx} mx0={mx0} ({bd}-bit)\n')
            w(f'  let out = @av1_mc_core.av1_mc_resize(plane{bd}, {src_w}, {src_w}, {hh}, {dst_w}, {dx}, {mx0}, {bd})\n')
        else:
            cw, ch, mx, my, dx, dy, comp = params
            f2d = 9 if kind in ('bilin', 'bilp') else filter2d_of(comp)
            fn = {'tap': 'av1_mc_put_scaled', 'tapp': 'av1_mc_prep_scaled',
                  'bilin': 'av1_mc_put_scaled', 'bilp': 'av1_mc_prep_scaled'}[kind]
            w(f'  // {kind} {cw}x{ch} mx={mx} my={my} dx={dx} dy={dy} filter={comp} ({bd}-bit)\n')
            w(f'  let out = @av1_mc_core.{fn}(plane{bd}, 112, 112, 80, {cw}, {ch}, {mx} + 8192, {my} + 8192, {dx}, {dy}, {f2d}, {bd})\n')
        w('  let expected : Array[Int32] = [\n')
        w(wrap([str(v) for v in want]) + '\n')
        w('  ]\n')
        w(f'  av1_scaled_test_px("{name}", out, expected)\n\n')
    w('}\n')
    io.open(OUT, 'w', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')

if __name__ == '__main__':
    main()
