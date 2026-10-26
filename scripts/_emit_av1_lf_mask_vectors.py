#!/usr/bin/env python3
"""Emit libavcodec/av1_lf_mask_vectors/lf_mask_test.mbt from
%TEMP%/lfmask_dump.txt (dav1d 1.5.1 lf_mask.c create_lf_mask_inter)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, 'libavcodec', 'av1_lf_mask_vectors')
OUT = os.path.join(OUTDIR, 'lf_mask_test.mbt')

HEADER = '''///|
/// Inter-frame loop-filter masks verified against dav1d 1.5.1
/// `dav1d_create_lf_mask_inter` (level cache, luma block/tx edges, chroma
/// edges with the skip shortcut) over random blocks and layouts
/// (`scripts/_emit_av1_lf_mask_vectors.py`).

///|
fn av1_lfm_hash_v(h : Int64, v : Int) -> Int64 {
  (h * 31L + (v & 0xffff).to_int64()) % 1000000007L
}
'''


def wrap(vals, indent='    ', per=16):
    return '\n'.join(indent + ', '.join(str(v) for v in vals[i:i + per]) + ','
                     for i in range(0, len(vals), per))


def main():
    lines = [l.split() for l in io.open(os.path.join(TMP, 'lfmask_dump.txt'))
             if l.strip()]
    assert len(lines) == 48, len(lines)
    seeds, cfg, expected = [], [], []
    for t in lines:
        seeds.append('0x%08xU' % int(t[1]))
        bx, by, skip, bs, ytx, uvtx, layout = (int(v) for v in t[2:9])
        tm0, tm1 = int(t[9]), int(t[10])
        lv = [int(v) for v in t[11:15]]
        cfg.append([bx, by, skip, bs, ytx, uvtx, layout, tm0, tm1] + lv)
        expected.extend(int(v) for v in t[15:22])
    flat = [v for row in cfg for v in row]
    out = io.StringIO()
    w = out.write
    w(HEADER)
    w('\n///|\n')
    w('test "inter loop-filter masks match dav1d" {\n')
    w('  let seeds : Array[UInt] = [\n')
    w(wrap(seeds))
    w('\n  ]\n')
    w('  let cfg : Array[Int] = [\n')
    w(wrap(flat))
    w('\n  ]\n')
    w('  let expected : Array[Int64] = [\n')
    w(wrap(['%dL' % v for v in expected]))
    w('\n  ]\n')
    w('  let actual : Array[Int64] = []\n')
    w('  for i in 0..<48 {\n')
    w('    let seed = seeds[i]\n')
    w('    let bx = cfg[i * 13 + 0]\n')
    w('    let by = cfg[i * 13 + 1]\n')
    w('    let skip = cfg[i * 13 + 2] != 0\n')
    w('    let bs = cfg[i * 13 + 3]\n')
    w('    let ytx = cfg[i * 13 + 4]\n')
    w('    let uvtx = cfg[i * 13 + 5]\n')
    w('    let layout = cfg[i * 13 + 6]\n')
    w('    let lf_level = FixedArray::make(32 * 32 * 4, (0 : Int32))\n')
    w('    let lvl = FixedArray::make(64, (0 : Int32))\n')
    w('    for d in 0..<4 {\n')
    w('      lvl[d * 16] = cfg[i * 13 + 9 + d]\n')
    w('    }\n')
    w('    let fy = FixedArray::make(2 * 32 * 3 * 2, (0 : UInt))\n')
    w('    let fuv = FixedArray::make(2 * 32 * 2 * 2, (0 : UInt))\n')
    w('    let ay = FixedArray::make(32, (0 : Int32))\n')
    w('    let ly = FixedArray::make(32, (0 : Int32))\n')
    w('    let auv = FixedArray::make(32, (0 : Int32))\n')
    w('    let luv = FixedArray::make(32, (0 : Int32))\n')
    w('    for j in 0..<32 {\n')
    w('      let ju = j.reinterpret_as_uint()\n')
    w('      ay[j] = ((ju * 7U + seed * 13U) % 3U).reinterpret_as_int()\n')
    w('      ly[j] = ((ju * 11U + seed * 17U) % 3U).reinterpret_as_int()\n')
    w('      auv[j] = ((ju * 5U + seed * 7U) % 2U).reinterpret_as_int()\n')
    w('      luv[j] = ((ju * 9U + seed * 11U) % 2U).reinterpret_as_int()\n')
    w('    }\n')
    w('    let has_chroma = layout != 0\n')
    w('    let ss_h : Int32 = if layout == 1 || layout == 2 { 1 } else { 0 }\n')
    w('    let ss_v : Int32 = if layout == 1 { 1 } else { 0 }\n')
    w('    @libavcodec.av1_create_lf_mask_inter(\n')
    w('      lf_level, lvl, 32, 32, 32, ss_h, ss_v, fy, fuv, bx,\n')
    w('      by, skip, bs, ytx,\n')
    w('      [cfg[i * 13 + 7], cfg[i * 13 + 8]], uvtx,\n')
    w('      ay, 0, ly, 0, auv, 0, luv, 0, has_chroma, 0,\n')
    w('    )\n')
    w('    let mut h = 17L\n')
    w('    for j in 0..<(2 * 32 * 3 * 2) {\n')
    w('      h = av1_lfm_hash_v(h, fy[j].reinterpret_as_int())\n')
    w('    }\n')
    w('    actual.push(h)\n')
    w('    h = 17L\n')
    w('    for j in 0..<(2 * 32 * 2 * 2) {\n')
    w('      h = av1_lfm_hash_v(h, fuv[j].reinterpret_as_int())\n')
    w('    }\n')
    w('    actual.push(h)\n')
    w('    h = 17L\n')
    w('    for j in 0..<(32 * 32 * 4) {\n')
    w('      h = av1_lfm_hash_v(h, lf_level[j])\n')
    w('    }\n')
    w('    actual.push(h)\n')
    w('    for arr in [ay, ly] {\n')
    w('      h = 17L\n')
    w('      for j in 0..<32 {\n')
    w('        h = av1_lfm_hash_v(h, arr[j])\n')
    w('      }\n')
    w('      actual.push(h)\n')
    w('    }\n')
    w('    if has_chroma {\n')
    w('      for arr in [auv, luv] {\n')
    w('        h = 17L\n')
    w('        for j in 0..<32 {\n')
    w('          h = av1_lfm_hash_v(h, arr[j])\n')
    w('        }\n')
    w('        actual.push(h)\n')
    w('      }\n')
    w('    } else {\n')
    w('      actual.push(0L)\n')
    w('      actual.push(0L)\n')
    w('    }\n')
    w('  }\n')
    w('  for k in 0..<actual.length() {\n')
    w('    if actual[k] != expected[k] {\n')
    w('      fail("mask mismatch at index " + k.to_string())\n')
    w('    }\n')
    w('  }\n')
    w('}\n')
    os.makedirs(OUTDIR, exist_ok=True)
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    with io.open(os.path.join(OUTDIR, 'moon.pkg'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
