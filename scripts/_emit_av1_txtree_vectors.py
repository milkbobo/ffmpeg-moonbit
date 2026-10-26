#!/usr/bin/env python3
"""Emit libavcodec/av1_tx_tree_vectors/txtree_test.mbt from
%TEMP%/txtree_dump.txt (dav1d 1.5.1 read_vartx_tree/read_tx_tree)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, 'libavcodec', 'av1_tx_tree_vectors')
OUT = os.path.join(OUTDIR, 'txtree_test.mbt')


def wrap(vals, per=16):
    return '\n'.join('    ' + ', '.join(vals[i:i + per]) + ','
                     for i in range(0, len(vals), per))


def main():
    rows = [l.split() for l in io.open(os.path.join(TMP, 'txtree_dump.txt'))
            if l.strip()]
    assert len(rows) == 256, len(rows)
    cfg, maxy, uvtx, s0, s1, rng, dif, actx, lctx = ([] for _ in range(9))
    for t in rows:
        assert t[0] == 'V'
        cfg.extend(t[1:10])
        maxy.append(t[10])
        uvtx.append(t[11])
        s0.append(t[12])
        s1.append(t[13])
        rng.append(t[14])
        dif.append('0x%sL' % t[15])
        actx.extend(t[16:48])
        lctx.extend(t[48:80])
    os.makedirs(OUTDIR, exist_ok=True)
    pkg = os.path.join(OUTDIR, 'moon.pkg')
    if not os.path.exists(pkg):
        io.open(pkg, 'w', encoding='utf-8', newline='\n').write(
            'import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Inter transform-tree partitioning verified against dav1d 1.5.1\n')
    w('/// `read_vartx_tree`/`read_tx_tree` over LCG byte streams: `txpart`\n')
    w('/// symbols, split masks and the `tx` neighbour context updates\n')
    w('/// (`scripts/_emit_av1_txtree_vectors.py`).\n\n')
    w('///|\n')
    w('fn av1_txtree_lcg_bytes(seed : UInt, n : Int) -> Bytes {\n')
    w('  let mut state = seed\n')
    w('  let out : Array[Byte] = []\n')
    w('  for _ in 0..<n {\n')
    w('    state = state * 1664525 + 1013904223\n')
    w('    out.push(((state >> 16) & 0xff).reinterpret_as_int().to_byte())\n')
    w('  }\n')
    w('  Bytes::from_array(out)\n')
    w('}\n\n')
    w('///|\n')
    w('/// Each fixture case decodes from `buf + i * 13`, so the test slices\n')
    w('/// the LCG stream before handing it to the range decoder.\n')
    w('fn av1_txtree_slice(src : Bytes, start : Int) -> Bytes {\n')
    w('  let out : Array[Byte] = []\n')
    w('  for i in start..<src.length() {\n')
    w('    out.push(src[i])\n')
    w('  }\n')
    w('  Bytes::from_array(out)\n')
    w('}\n\n')
    w('///|\n')
    w('test "vartx tree matches dav1d" {\n')
    w('  let seeds : Array[UInt] = [0x31415926U, 0x27182818U]\n')
    for name, vals, ty in [
        ('cfg', cfg, 'Int'), ('exp_max', maxy, 'Int'), ('exp_uv', uvtx, 'Int'),
        ('exp_s0', s0, 'Int'), ('exp_s1', s1, 'Int'), ('exp_rng', rng, 'Int'),
        ('exp_dif', dif, 'Int64'), ('exp_a', actx, 'Int'),
        ('exp_l', lctx, 'Int'),
    ]:
        w('  let %s : Array[%s] = [\n' % (name, ty))
        w(wrap(vals))
        w('\n  ]\n')
    w('  // The C probe adapts one CdfContext across both LCG seeds.\n')
    w('  let cdf = @libavcodec.av1_cdf_copy_defaults(0)\n')
    w('  for s in 0..<2 {\n')
    w('    let stream = av1_txtree_lcg_bytes(seeds[s], 8192)\n')
    w('    for i in 0..<128 {\n')
    w('      let k = s * 128 + i\n')
    w('      let bs = cfg[k * 9]\n')
    w('      let a_tx = FixedArray::make(32, 0)\n')
    w('      let l_tx = FixedArray::make(32, 0)\n')
    w('      for j in 0..<32 {\n')
    w('        a_tx[j] = (j * 3 + bs) % 5\n')
    w('        l_tx[j] = (j * 5 + (i % 8)) % 5\n')
    w('      }\n')
    w('      let msac = @libavcodec.Av1Msac::init(av1_txtree_slice(stream, i * 13), false)\n')
    w('      let r = @libavcodec.av1_read_vartx_tree(\n')
    w('        msac, cdf, bs, cfg[k * 9 + 1] != 0, cfg[k * 9 + 2] != 0,\n')
    w('        cfg[k * 9 + 3] != 0, cfg[k * 9 + 4], a_tx, l_tx, cfg[k * 9 + 5],\n')
    w('        cfg[k * 9 + 6], cfg[k * 9 + 7], cfg[k * 9 + 8],\n')
    w('      )\n')
    w('      if r.max_ytx != exp_max[k] || r.uvtx != exp_uv[k] ||\n')
    w('        r.split0.reinterpret_as_int() != exp_s0[k] || r.split1.reinterpret_as_int() != exp_s1[k] {\n')
    w('        fail("txtree k " + k.to_string() + " cfg " + cfg[k * 9].to_string() + " " + cfg[k * 9 + 1].to_string() + " " + cfg[k * 9 + 2].to_string() + " " + cfg[k * 9 + 3].to_string() + " " + cfg[k * 9 + 4].to_string() + ": " + r.max_ytx.to_string() + "/" + r.uvtx.to_string() + "/" + r.split0.reinterpret_as_int().to_string() + "/" + r.split1.reinterpret_as_int().to_string() + " != " + exp_max[k].to_string() + "/" + exp_uv[k].to_string() + "/" + exp_s0[k].to_string() + "/" + exp_s1[k].to_string())\n')
    w('      }\n')
    w('      assert_eq(msac.rng.reinterpret_as_int(), exp_rng[k])\n')
    w('      assert_eq((msac.dif >> 32).reinterpret_as_int64(), exp_dif[k])\n')
    w('      for j in 0..<32 {\n')
    w('        if a_tx[j] != exp_a[k * 32 + j] ||\n')
    w('          l_tx[j] != exp_l[k * 32 + j] {\n')
    w('          fail("txtree ctx k " + k.to_string() + " j " + j.to_string() + ": a " + a_tx[j].to_string() + "/" + l_tx[j].to_string() + " != " + exp_a[k * 32 + j].to_string() + "/" + exp_l[k * 32 + j].to_string())\n')
    w('        }\n')
    w('      }\n')
    w('    }\n')
    w('  }\n')
    w('}\n')
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
