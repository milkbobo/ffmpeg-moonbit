#!/usr/bin/env python3
"""Emit libavcodec/av1_inter_syntax_vectors/txtp_test.mbt from
%TEMP%/txtp_dump.txt (dav1d 1.5.1 decode_coefs transform-type selection)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_inter_syntax_vectors',
                   'txtp_test.mbt')


def wrap(vals, per=16):
    return '\n'.join('    ' + ', '.join(vals[i:i + per]) + ','
                     for i in range(0, len(vals), per))


def main():
    cfg, exp_txtp, exp_rng, exp_difhi = [], [], [], []
    lines = [l.split() for l in io.open(os.path.join(TMP, 'txtp_dump.txt'))
             if l.strip()]
    assert len(lines) == 512, len(lines)
    for t in lines:
        cfg.extend(t[1:10])
        exp_txtp.append(t[10])
        exp_rng.append(t[11])
        exp_difhi.append('0x%sL' % t[12])
    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Transform-type selection verified against dav1d 1.5.1\n')
    w('/// `decode_coefs` over LCG byte streams: intra/inter luma CDF paths and\n')
    w('/// chroma `get_uv_inter_txtp` derivation\n')
    w('/// (`scripts/_emit_av1_txtp_vectors.py`).\n\n')
    w('///|\n')
    w('fn av1_txtp_lcg_bytes(seed : UInt, n : Int) -> Bytes {\n')
    w('  let mut state = seed\n')
    w('  let out : Array[Byte] = []\n')
    w('  for _ in 0..<n {\n')
    w('    state = state * 1664525 + 1013904223\n')
    w('    out.push(((state >> 16) & 0xff).reinterpret_as_int().to_byte())\n')
    w('  }\n')
    w('  Bytes::from_array(out)\n')
    w('}\n\n')
    w('///|\n')
    w('test "txtp selection matches dav1d" {\n')
    w('  let seeds : Array[UInt] = [0x31415926U, 0x27182818U]\n')
    w('  let cfg : Array[Int] = [\n')
    w(wrap(cfg))
    w('\n  ]\n')
    w('  let exp_txtp : Array[Int] = [\n')
    w(wrap(exp_txtp))
    w('\n  ]\n')
    w('  let exp_rng : Array[Int] = [\n')
    w(wrap(exp_rng))
    w('\n  ]\n')
    w('  let exp_difhi : Array[Int64] = [\n')
    w(wrap(exp_difhi))
    w('\n  ]\n')
    w('  // The C probe adapts one CdfContext across both LCG seeds.\n')
    w('  let cdf = @libavcodec.av1_cdf_copy_defaults(0)\n')
    w('  for s in 0..<2 {\n')
    w('    let msac = @libavcodec.Av1Msac::init(av1_txtp_lcg_bytes(seeds[s], 8192), false)\n')
    w('    for i in 0..<256 {\n')
    w('      let k = s * 256 + i\n')
    w('      let txtp = @libavcodec.av1_decode_txtp(\n')
    w('        msac, cdf, cfg[k * 9] != 0, cfg[k * 9 + 1], cfg[k * 9 + 2],\n')
    w('        cfg[k * 9 + 3] != 0, cfg[k * 9 + 4] != 0, cfg[k * 9 + 5],\n')
    w('        cfg[k * 9 + 6], cfg[k * 9 + 7], cfg[k * 9 + 8],\n')
    w('      )\n')
    w('      if txtp != exp_txtp[k] {\n')
    w('        fail("txtp case " + k.to_string() + ": " + txtp.to_string() + " != " + exp_txtp[k].to_string())\n')
    w('      }\n')
    w('      assert_eq(msac.rng.reinterpret_as_int(), exp_rng[k])\n')
    w('      assert_eq((msac.dif >> 32).reinterpret_as_int64(), exp_difhi[k])\n')
    w('    }\n')
    w('  }\n')
    w('}\n')
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
