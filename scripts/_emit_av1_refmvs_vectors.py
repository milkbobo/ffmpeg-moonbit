#!/usr/bin/env python3
"""Emit libavcodec/av1_refmvs_vectors/refmvs_test.mbt from
%TEMP%/refmvs_dump.txt (dav1d 1.5.1 refmvs.c dumper). Data tables are
generated here; the test bodies come from _av1_refmvs_test_body.tpl."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_refmvs_vectors', 'refmvs_test.mbt')
TPL = os.path.join(ROOT, 'scripts', '_av1_refmvs_test_body.tpl')

def wrap(vals, indent='  ', per=12):
    lines = []
    for i in range(0, len(vals), per):
        lines.append(indent + ', '.join(vals[i:i + per]) + ',')
    return '\n'.join(lines)

def main():
    lines = [l.split() for l in io.open(os.path.join(TMP, 'refmvs_dump.txt'))]
    cases = []
    gs, js = [], []
    i = 0
    while i < len(lines):
        t = lines[i]
        if t[0] == 'P':
            ref1 = int(t[3])
            c = [int(x) for x in lines[i + 1][1:]]
            ms = []
            i += 2
            while i < len(lines) and lines[i][0] == 'M':
                ms.append([int(x) for x in lines[i][1:]])
                i += 1
            cases.append((c, ms, ref1))
        elif t[0] == 'GO':
            gs.append([int(x) for x in t[1:]])
            i += 1
        elif t[0] == 'J':
            js.append([int(x) for x in t[1:]])
            i += 1
        else:
            i += 1
    assert len(cases) == 1008, len(cases)
    assert len(gs) == 12 and len(js) == 16

    fs = []
    for l in lines:
        if l[0] == 'F':
            fs.append(l[1:])  # keep string tokens, parse in-test via table
    assert len(fs) == 20
    offs, data = [], []
    for c, ms, ref1 in cases:
        offs.append(len(data))
        data.append(c[0])
        data.append(c[1])
        for m in ms:
            if ref1 == -1:
                # single-ref: the C stack's mv1 is uninitialized garbage
                data.extend([m[1], m[2], m[3], 0, 0])
            else:
                data.extend(m[1:])
    offs.append(len(data))

    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// `av1_refmvs_find` verified against dav1d 1.5.1 `refmvs.c` over\n')
    w('/// LCG-built spatial/temporal contexts (24 seeds x 14 sizes x 3 ref\n')
    w('/// variants); get_gmv_2d and mv_projection unit vectors included\n')
    w('/// (`scripts/_emit_av1_refmvs_vectors.py`).\n\n')

    w('///|\n')
    w('fn av1_refmvs_test_rnd(st : Ref[UInt]) -> UInt {\n')
    w('  st.val = st.val * 1664525 + 1013904223\n')
    w('  st.val >> 8\n')
    w('}\n\n')
    w('///|\n')
    w('fn av1_refmvs_test_inrange(st : Ref[UInt], hi : Int) -> Int {\n')
    w('  (av1_refmvs_test_rnd(st) % hi.reinterpret_as_uint()).reinterpret_as_int()\n')
    w('}\n\n')
    w('///|\n')
    w('/// Rebuild one seed\'s contexts; mirrors dump_refmvs.c build_case.\n')
    w('fn av1_refmvs_test_build(seed : Int) -> (@libavcodec.Av1Rf, FixedArray[FixedArray[@libavcodec.Av1Rb]], FixedArray[@libavcodec.Av1Rtb], UInt) {\n')
    w('  let st : Ref[UInt] = Ref(seed.reinterpret_as_uint())\n')
    w('  let sign_bias : FixedArray[Int] = FixedArray::make(7, 0)\n')
    w('  let pocdiff : FixedArray[Int] = FixedArray::make(7, 0)\n')
    w('  for i in 0..<7 {\n')
    w('    sign_bias[i] = (av1_refmvs_test_rnd(st) & 1).reinterpret_as_int()\n')
    w('    pocdiff[i] = av1_refmvs_test_inrange(st, 63) - 31\n')
    w('  }\n')
    w('  let invalid = (0x8000, 0x8000)\n')
    w('  let blank : @libavcodec.Av1Rb = {\n')
    w('    ref0: 0, ref1: -1, bs: 17, mf: 0, mv0: invalid, mv1: invalid,\n')
    w('  }\n')
    w('  let rows = FixedArray::makei(37, _ => FixedArray::make(48, blank))\n')
    w('  for y in 0..<37 {\n')
    w('    let mut x = 0\n')
    w('    while x < 48 {\n')
    w('      let k = av1_refmvs_test_inrange(st, 4)\n')
    w('      if k == 0 {\n')
    w('        let b : @libavcodec.Av1Rb = {\n')
    w('          ref0: 0, ref1: -1, bs: 17, mf: 0, mv0: invalid, mv1: invalid,\n')
    w('        }\n')
    w('        rows[y][x] = b\n')
    w('        rows[y][x + 1] = b\n')
    w('        x = x + 2\n')
    w('      } else {\n')
    w('        let r0 = 1 + av1_refmvs_test_inrange(st, 7)\n')
    w('        let r1 = if k == 3 { 1 + av1_refmvs_test_inrange(st, 7) } else { -1 }\n')
    w('        let y0 = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('        let x0 = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('        let y1 = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('        let x1 = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('        let mf = (av1_refmvs_test_rnd(st) & 3).reinterpret_as_int()\n')
    w('        let b : @libavcodec.Av1Rb = {\n')
    w('          ref0: r0, ref1: r1, bs: 17, mf, mv0: (y0, x0), mv1: (y1, x1),\n')
    w('        }\n')
    w('        rows[y][x] = b\n')
    w('        rows[y][x + 1] = b\n')
    w('        x = x + 2\n')
    w('      }\n')
    w('    }\n')
    w('  }\n')
    w('  let tblank : @libavcodec.Av1Rtb = { mv: invalid, ref_: 0 }\n')
    w('  let rp = FixedArray::makei(16 * 40, _ => tblank)\n')
    w('  for i in 0..<(16 * 40) {\n')
    w('    if av1_refmvs_test_inrange(st, 4) == 0 {\n')
    w('      rp[i] = { mv: invalid, ref_: 0 }\n')
    w('    } else {\n')
    w('      let y = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('      let x = av1_refmvs_test_inrange(st, 4096) - 2048\n')
    w('      let r = 1 + av1_refmvs_test_inrange(st, 7)\n')
    w('      rp[i] = { mv: (y, x), ref_: r }\n')
    w('    }\n')
    w('  }\n')
    w('  // gmv models matching the dump header: [0] rot-zoom, [3] translation\n')
    w('  let gm_types : FixedArray[Int] = FixedArray::make(7, 0)\n')
    w('  let gm_mats : FixedArray[FixedArray[Int]] = FixedArray::makei(\n')
    w('    7,\n')
    w('    _ => [0, 0, 65536, 0, 0, 65536],\n')
    w('  )\n')
    w('  gm_types[0] = 2\n')
    w('  gm_mats[0] = [73728, 67584, 64458, 72, -72, 64458]\n')
    w('  gm_types[3] = 1\n')
    w('  gm_mats[3] = [32768, -16384, 65536, 0, 0, 65536]\n')
    w('  let rf : @libavcodec.Av1Rf = {\n')
    w('    iw4: 32,\n')
    w('    ih4: 32,\n')
    w('    sign_bias,\n')
    w('    pocdiff,\n')
    w('    hp: true,\n')
    w('    force_integer_mv: false,\n')
    w('    use_ref_frame_mvs: true,\n')
    w('    gm_types,\n')
    w('    gm_matrices: gm_mats,\n')
    w('  }\n')
    w('  (rf, rows, rp, st.val)\n')
    w('}\n\n')

    w('///|\n')
    w('let av1_refmvs_test_offsets : FixedArray[Int] = [\n')
    w(wrap([str(v) for v in offs]) + '\n')
    w(']\n\n')
    w('///|\n')
    w('let av1_refmvs_test_expect : FixedArray[Int] = [\n')
    w(wrap([str(v) for v in data]) + '\n')
    w(']\n\n')
    w('///|\n')
    w('let av1_refmvs_gmv_expect : FixedArray[Int] = [\n')
    gv = []
    for g in gs:
        gv.extend(str(v) for v in g)
    w(wrap(gv) + '\n')
    w(']\n\n')
    w('///|\n')
    w('let av1_refmvs_proj_expect : FixedArray[Int] = [\n')
    jv = []
    for j in js:
        jv.extend(str(v) for v in j)
    w(wrap(jv) + '\n')
    w(']\n\n')
    # init_frame vector table: one string per case
    w('///|\n')
    w('let av1_refmvs_init_expect : Array[String] = [\n')
    for f in fs:
        w('  "' + ' '.join(f) + '",\n')
    w(']\n\n')
    w(io.open(TPL, encoding='utf-8').read())
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')

if __name__ == '__main__':
    main()
