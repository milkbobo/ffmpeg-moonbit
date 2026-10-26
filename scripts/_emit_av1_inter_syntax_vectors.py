#!/usr/bin/env python3
"""Emit libavcodec/av1_inter_syntax_vectors/inter_syntax_test.mbt from
%TEMP%/inter_syntax_dump.txt produced by .scratch/av1/inter_syntax_dump.c
(dav1d 1.5.1 decode_b inter syntax snippets)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, 'libavcodec', 'av1_inter_syntax_vectors')
OUT = os.path.join(OUTDIR, 'inter_syntax_test.mbt')

HEADER = '''///|
/// Inter-block syntax verified against dav1d 1.5.1 `decode_b` snippets
/// over LCG byte streams and the default CDF tables: masked-compound type,
/// inter-intra flags, motion variation and switchable subpel filters
/// (`scripts/_emit_av1_inter_syntax_vectors.py`).

///|
fn av1_isyn_lcg_bytes(seed : UInt, n : Int) -> Bytes {
  let mut state = seed
  let out : Array[Byte] = []
  for _ in 0..<n {
    state = state * 1664525 + 1013904223
    out.push(((state >> 16) & 0xff).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(out)
}
'''


def wrap(vals, indent='    ', per=16):
    lines = []
    for i in range(0, len(vals), per):
        lines.append(indent + ', '.join(str(v) for v in vals[i:i + per]) + ',')
    return '\n'.join(lines)


def main():
    cases = {}
    raw = [l.split() for l in io.open(os.path.join(TMP, 'inter_syntax_dump.txt'))
           if l.strip()]
    for t in raw:
        if t[0] == 'K':
            cases[int(t[1])] = {
                'seed': int(t[2], 16), 'n': int(t[3]),
                'rng': int(t[4]), 'difhi': int(t[5], 16),
                'cfg': [], 'exp': [],
            }
    if True:
        for t in raw:
            if t[0] == 'K':
                continue
            elif t[0] == 'C':
                cases[0]['cfg'].extend(int(v) for v in t[2:7])
                cases[0]['exp'].extend(int(v) for v in t[7:10])
            elif t[0] == 'X':
                cases[1]['cfg'].extend(int(v) for v in t[2:4])
                cases[1]['exp'].extend(int(v) for v in t[4:7])
            elif t[0] == 'O':
                cases[2]['cfg'].extend(int(v) for v in t[2:5])
                cases[2]['exp'].append(int(t[5]))
            elif t[0] == 'F':
                cases[3]['cfg'].extend(int(v) for v in t[2:8])
                cases[3]['exp'].extend(int(v) for v in t[8:11])
    assert sorted(cases) == [0, 1, 2, 3]
    for k, c in cases.items():
        assert len(c['cfg']) % c['n'] == 0, (k, len(c['cfg']))
        per = len(c['cfg']) // c['n']
        assert len(c['exp']) == c['n'] * (3 if k == 0 else 3 if k == 1 else 1 if k == 2 else 3)

    specs = {
        0: ('inter compound mask syntax matches dav1d', 5, 3, 0x12345678),
        1: ('inter-intra flags match dav1d', 2, 3, 0x9e3779b9),
        2: ('motion variation matches dav1d', 3, 1, 0xdeadbeef),
        3: ('switchable subpel filters match dav1d', 6, 3, 0xcafebabe),
    }
    out = io.StringIO()
    w = out.write
    w(HEADER)
    for k in range(4):
        name, per, nout, seed = specs[k]
        c = cases[k]
        w('\n///|\n')
        w('test "%s" {\n' % name)
        w('  let buf = av1_isyn_lcg_bytes(0x%08x, 8192)\n' % seed)
        w('  let msac = @libavcodec.Av1Msac::init(buf, false)\n')
        w('  let cdf = @libavcodec.av1_cdf_copy_defaults(0)\n')
        w('  let cfg : Array[Int] = [\n')
        w(wrap(c['cfg']))
        w('\n  ]\n')
        w('  let expected : Array[Int] = [\n')
        w(wrap(c['exp']))
        w('\n  ]\n')
        w('  let actual : Array[Int] = []\n')
        w('  for i in 0..<%d {\n' % c['n'])
        bools = {0: [0, 1], 1: [0], 2: [0, 1], 3: [0, 1, 2]}[k]
        args = ', '.join(
            ('cfg[i * %d + %d] != 0' if j in bools else 'cfg[i * %d + %d]')
            % (per, j) for j in range(per))
        if k == 0:
            w('    let r = @libavcodec.av1_inter_read_compound_mask(\n')
            w('      msac, cdf, %s,\n' % args)
            w('    )\n')
            w('    actual.push(r.comp_type)\n')
            w('    actual.push(r.wedge_idx)\n')
            w('    actual.push(r.mask_sign)\n')
        elif k == 1:
            w('    let r = @libavcodec.av1_inter_read_interintra(\n')
            w('      msac, cdf, %s,\n' % args)
            w('    )\n')
            w('    actual.push(r.kind)\n')
            w('    actual.push(r.mode)\n')
            w('    actual.push(r.wedge_idx)\n')
        elif k == 2:
            w('    let r = @libavcodec.av1_inter_read_motion_mode(\n')
            w('      msac, cdf, %s,\n' % args)
            w('    )\n')
            w('    actual.push(r)\n')
        else:
            w('    let r = @libavcodec.av1_inter_read_filter(\n')
            w('      msac, cdf, %s,\n' % args)
            w('    )\n')
            w('    actual.push(r.filter0)\n')
            w('    actual.push(r.filter1)\n')
            w('    actual.push(r.filter2d)\n')
        w('  }\n')
        w('  assert_eq(actual, expected)\n')
        w('  inspect(msac.rng, content="%d")\n' % c['rng'])
        w('}\n')
    os.makedirs(OUTDIR, exist_ok=True)
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    with io.open(os.path.join(OUTDIR, 'moon.pkg'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
