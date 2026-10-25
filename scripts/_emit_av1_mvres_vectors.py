#!/usr/bin/env python3
"""Emit libavcodec/av1_mvres_vectors/mvres_test.mbt from
%TEMP%/mvres_dump.txt (produced by .scratch/av1/mvres_cycle.py against
dav1d 1.5.1 read_mv_residual, verbatim copy, default CDF)."""
import io
import os

TMP = r'C:\Users\milkb\AppData\Local\Temp'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_mvres_vectors', 'mvres_test.mbt')

CASES = [
    (0x12345678, 400, 2),
    (0x9E3779B9, 400, 1),
    (0xDEADBEEF, 400, 0),
    (0xCAFEBABE, 400, 3),
]

def main():
    rows = [l.split() for l in io.open(os.path.join(TMP, 'mvres_dump.txt'))]
    rows = [r for r in rows if r and r[0] == 'R']
    by_case = {}
    for t in rows:
        assert t[0] == 'R'
        prec = int(t[2])
        by_case.setdefault(prec, []).append(t)
    assert all(len(by_case[p]) == 400 for _, _, p in CASES)

    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// MV residual decoding (`av1_read_mv_residual`) verified step by\n')
    w('/// step (y/x/rng/dif) against dav1d 1.5.1 `read_mv_residual` run\n')
    w('/// over LCG byte streams with the default MV CDF\n')
    w('/// (`scripts/_emit_av1_mvres_vectors.py`).\n\n')
    w('///|\n')
    w('fn av1_mvres_test_lcg(seed : UInt, n : Int) -> Bytes {\n')
    w('  let mut state = seed\n')
    w('  let out : Array[Byte] = []\n')
    w('  for _ in 0..<n {\n')
    w('    state = state * 1664525 + 1013904223\n')
    w('    out.push(((state >> 16) & 0xff).reinterpret_as_int().to_byte())\n')
    w('  }\n')
    w('  Bytes::from_array(out)\n')
    w('}\n\n')
    for ci, (seed, n, prec) in enumerate(CASES):
        w('///|\n')
        w(f'test "av1 mv residual seed 0x{seed:08x} prec {prec}" {{\n')
        w('  let buf = av1_mvres_test_lcg('
          f'0x{seed:08x}, 8192)\n')
        w('  let msac = @libavcodec.Av1Msac::init(buf, false)\n')
        w('  let cdf = @libavcodec.av1_cdf_copy_defaults(0)\n')
        w('  let mut y = 0\n')
        w('  let mut x = 0\n')
        w('  let expected : FixedArray[Int] = [\n')
        vals = []
        for t in by_case[prec]:
            # fields: R i prec joint y x rng dif
            dif = int(t[7], 16)
            if dif >= 1 << 31:
                dif -= 1 << 32
            vals.append(f'{t[4]}, {t[5]}, {t[6]}, {dif}')
        for i in range(0, len(vals), 8):
            w('    ' + ', '.join(vals[i:i + 8]) + ',\n')
        w('  ]\n')
        w('  for i in 0..<400 {\n')
        w(f'    let (ny, nx) = @libavcodec.av1_read_mv_residual(msac, cdf, y, x, {prec})\n')
        w('    y = ny\n')
        w('    x = nx\n')
        w('    let k = i * 4\n')
        w('    if y != expected[k] {\n')
        w('      fail("y at \\{i}: got \\{y}, want \\{expected[k]}")\n')
        w('    }\n')
        w('    if x != expected[k + 1] {\n')
        w('      fail("x at \\{i}: got \\{x}, want \\{expected[k + 1]}")\n')
        w('    }\n')
        w('    if msac.rng.reinterpret_as_int() != expected[k + 2] {\n')
        w('      fail("rng at \\{i}: got \\{msac.rng}, '
          'want \\{expected[k + 2]}")\n')
        w('    }\n')
        w('    if (msac.dif >> 32).reinterpret_as_int64().to_int() != expected[k + 3] {\n')
        w('      fail("dif at \\{i}: got \\{(msac.dif >> 32)}, '
          'want \\{expected[k + 3]}")\n')
        w('    }\n')
        w('  }\n')
        w('}\n\n')
    io.open(OUT, 'w', newline='\n').write(out.getvalue())
    print('wrote', OUT)

if __name__ == '__main__':
    main()
