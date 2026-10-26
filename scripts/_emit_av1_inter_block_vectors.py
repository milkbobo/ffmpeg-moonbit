#!/usr/bin/env python3
"""Emit libavcodec/av1_inter_block_vectors/inter_block_test.mbt from
%TEMP%/interblock_dump.txt (dav1d 1.5.1 decode_b inter branch copy)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TPL = os.path.join(ROOT, 'scripts', '_av1_inter_block_test_body.tpl')
OUT = os.path.join(ROOT, 'libavcodec', 'av1_inter_block_vectors',
                   'inter_block_test.mbt')


def wrap(vals, per=16):
    return '\n'.join('    ' + ', '.join(vals[i:i + per]) + ','
                     for i in range(0, len(vals), per))


def main():
    lines = [l.split() for l in io.open(os.path.join(TMP, 'interblock_dump.txt'))
             if l.strip()]
    ins = [t for t in lines if t[0] == 'I']
    outs = [t for t in lines if t[0] == 'B']
    assert len(ins) == 96 and len(outs) == 96, (len(ins), len(outs))

    mseed, cseed, rseed, flags = [], [], [], []
    cfg, expected, m0, m1, allow = [], [], [], [], []
    difhi = []
    for t, o in zip(ins, outs):
        mseed.append('0x%08xU' % int(t[1]))
        cseed.append('0x%08xU' % int(t[2]))
        rseed.append('0x%08xU' % int(t[3]))
        cfg.extend(t[4:11])
        flags.append('0x%08xU' % int(t[11], 16))
        assert len(o) == 34, len(o)
        expected.extend(o[1:29])
        difhi.append('0x%08xL' % int(o[29], 16))
        allow.append(o[30])
        m0.append('0x%016xUL' % int(o[31], 16))
        m1.append('0x%016xUL' % int(o[32], 16))

    data = []
    data.append('  let mseeds : Array[UInt] = [\n' + wrap(mseed) + '\n  ]')
    data.append('  let cseeds : Array[UInt] = [\n' + wrap(cseed) + '\n  ]')
    data.append('  let rseeds : Array[UInt] = [\n' + wrap(rseed) + '\n  ]')
    data.append('  let flags : Array[UInt] = [\n' + wrap(flags) + '\n  ]')
    data.append('  let cfg : Array[Int] = [\n' + wrap(cfg) + '\n  ]')
    data.append('  let expected : Array[Int] = [\n' + wrap(expected) + '\n  ]')
    data.append('  let exp_m0 : Array[UInt64] = [\n' + wrap(m0) + '\n  ]')
    data.append('  let exp_m1 : Array[UInt64] = [\n' + wrap(m1) + '\n  ]')
    data.append('  let exp_allow : Array[Int] = [\n' + wrap(allow) + '\n  ]')
    data.append('  let exp_difhi : Array[Int64] = [\n' + wrap(difhi) + '\n  ]')
    body = io.open(TPL, encoding='utf-8').read().replace(
        '//<<DATA>>', '\n'.join(data))
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(body)
    with io.open(os.path.join(os.path.dirname(OUT), 'moon.pkg'), 'w',
                 encoding='utf-8', newline='\n') as f:
        f.write('import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    print('wrote', OUT, len(body), 'bytes')


if __name__ == '__main__':
    main()
