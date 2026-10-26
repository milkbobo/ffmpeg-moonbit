#!/usr/bin/env python3
"""Emit libavcodec/av1_inter_warp_vectors/warp_test.mbt from
%TEMP%/warp_dump.txt (dav1d 1.5.1 warpmv.c + copied decode.c scan)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, 'libavcodec', 'av1_inter_warp_vectors')
OUT = os.path.join(OUTDIR, 'warp_test.mbt')

HEADER = '''///|
/// Warp model derivation verified against dav1d 1.5.1: `warpmv.c`
/// (`get_shear_params`, `find_affine_int`, `set_affine_mv2d`) and the
/// `find_matching_ref`/`derive_warpmv` pair from `decode.c`
/// (`scripts/_emit_av1_warpmv_vectors.py`).

///|
fn av1_warp_test_hash(row : Int, x : Int, seed : UInt) -> UInt {
  let mut h = (row.reinterpret_as_uint() * 0x9E3779B1U) ^
    (x.reinterpret_as_uint() * 0x85EBCA6BU) ^ (seed * 0xC2B2AE35U)
  h = h ^ (h >> 15)
  h = h * 0x2545F491U
  h ^ (h >> 13)
}

///|
fn av1_warp_test_rows(seed : UInt) -> FixedArray[FixedArray[@libavcodec.Av1Rb]] {
  let bss : FixedArray[Int] = [21, 17, 12, 9, 14, 16]
  FixedArray::makei(
    37,
    r => FixedArray::makei(64, x => {
      let h = av1_warp_test_hash(r, x, seed)
      {
        ref0: (h >> 5).reinterpret_as_int() % 9,
        ref1: if ((h >> 8) & 1) != 0 {
          -1
        } else {
          (h >> 9).reinterpret_as_int() % 8
        },
        bs: bss[(h >> 2).reinterpret_as_int() % 6],
        mf: ((h >> 12) & 3).reinterpret_as_int(),
        mv0: (
          (h >> 14).reinterpret_as_int() % 2001 - 1000,
          (h >> 25).reinterpret_as_int() % 2001 - 1000,
        ),
        mv1: (
          (h >> 3).reinterpret_as_int() % 2001 - 1000,
          (h >> 20).reinterpret_as_int() % 2001 - 1000,
        ),
      }
    }),
  )
}
'''


def wrap(vals, indent='    ', per=16):
    lines = []
    for i in range(0, len(vals), per):
        lines.append(indent + ', '.join(str(v) for v in vals[i:i + per]) + ',')
    return '\n'.join(lines)


def main():
    lines = [l.split() for l in io.open(os.path.join(TMP, 'warpmv_dump.txt'))
             if l.strip()]
    S = [list(map(int, t[1:])) for t in lines if t[0] == 'S']
    A = [list(map(int, t[1:])) for t in lines if t[0] == 'A']
    T = [list(map(int, t[1:])) for t in lines if t[0] == 'T']
    G = [t[1:] for t in lines if t[0] == 'G']
    assert len(S) == 64 and len(A) == 64 and len(T) == 32 and len(G) == 96
    for a in A:
        assert len(a) == 46, len(a)
    for t in T:
        assert len(t) == 18, len(t)

    out = io.StringIO()
    w = out.write
    w(HEADER)

    # ---------------- shear params ----------------
    w('\n///|\n')
    w('test "warp shear params match dav1d" {\n')
    w('  let data : Array[Int] = [\n')
    w(wrap([v for row in S for v in row]))
    w('\n  ]\n')
    w('  let expected : Array[Int] = []\n')
    w('  let actual : Array[Int] = []\n')
    w('  for i in 0..<64 {\n')
    w('    let wm = @libavcodec.av1_warpmv_default()\n')
    w('    for j in 0..<6 {\n')
    w('      wm.matrix[j] = data[i * 11 + j]\n')
    w('    }\n')
    w('    let invalid = @libavcodec.av1_warpmv_get_shear_params(wm)\n')
    w('    actual.push(if invalid { 1 } else { 0 })\n')
    w('    actual.push(wm.alpha)\n')
    w('    actual.push(wm.beta)\n')
    w('    actual.push(wm.gamma)\n')
    w('    actual.push(wm.delta)\n')
    w('    for j in 6..<11 {\n')
    w('      expected.push(data[i * 11 + j])\n')
    w('    }\n')
    w('  }\n')
    w('  assert_eq(actual, expected)\n')
    w('}\n')

    # ---------------- find_affine_int ----------------
    w('\n///|\n')
    w('test "warp find_affine_int matches dav1d" {\n')
    w('  let data : Array[Int] = [\n')
    w(wrap([v for row in A for v in row]))
    w('\n  ]\n')
    w('  let expected : Array[Int] = []\n')
    w('  let actual : Array[Int] = []\n')
    w('  for i in 0..<64 {\n')
    w('    let np = data[i * 46]\n')
    w('    let pts : FixedArray[Int] = FixedArray::makei(32, j => data[i * 46 + 1 + j])\n')
    w('    let bw4 = data[i * 46 + 33]\n')
    w('    let bh4 = data[i * 46 + 34]\n')
    w('    let mvy = data[i * 46 + 35]\n')
    w('    let mvx = data[i * 46 + 36]\n')
    w('    let bx4 = data[i * 46 + 37]\n')
    w('    let by4 = data[i * 46 + 38]\n')
    w('    let wm = @libavcodec.av1_warpmv_default()\n')
    w('    let ret = @libavcodec.av1_warpmv_find_affine_int(\n')
    w('      pts, np, bw4, bh4, (mvy, mvx), bx4, by4, wm,\n')
    w('    )\n')
    w('    actual.push(if ret { 1 } else { 0 })\n')
    w('    for j in 0..<6 {\n')
    w('      actual.push(wm.matrix[j])\n')
    w('    }\n')
    w('    for j in 39..<46 {\n')
    w('      expected.push(data[i * 46 + j])\n')
    w('    }\n')
    w('  }\n')
    w('  assert_eq(actual, expected)\n')
    w('}\n')

    # ---------------- set_affine_mv2d ----------------
    w('\n///|\n')
    w('test "warp set_affine_mv2d matches dav1d" {\n')
    w('  let data : Array[Int] = [\n')
    w(wrap([v for row in T for v in row]))
    w('\n  ]\n')
    w('  let expected : Array[Int] = []\n')
    w('  let actual : Array[Int] = []\n')
    w('  for i in 0..<32 {\n')
    w('    let wm = @libavcodec.av1_warpmv_default()\n')
    w('    for j in 0..<6 {\n')
    w('      wm.matrix[j] = data[i * 18 + j]\n')
    w('    }\n')
    w('    let mvy = data[i * 18 + 6]\n')
    w('    let mvx = data[i * 18 + 7]\n')
    w('    let bw4 = data[i * 18 + 8]\n')
    w('    let bh4 = data[i * 18 + 9]\n')
    w('    let bx4 = data[i * 18 + 10]\n')
    w('    let by4 = data[i * 18 + 11]\n')
    w('    @libavcodec.av1_warpmv_set_affine_mv2d(bw4, bh4, (mvy, mvx), bx4, by4, wm)\n')
    w('    for j in 0..<6 {\n')
    w('      actual.push(wm.matrix[j])\n')
    w('      expected.push(data[i * 18 + 12 + j])\n')
    w('    }\n')
    w('  }\n')
    w('  assert_eq(actual, expected)\n')
    w('}\n')

    # ---------------- neighbour masks + derive ----------------
    seeds, cfgs, m0, m1, types, vals = [], [], [], [], [], []
    for g in G:
        seeds.append('0x%08xU' % int(g[0]))
        cfgs.extend(int(v) for v in g[1:13])
        m0.append('0x%016xUL' % int(g[13], 16))
        m1.append('0x%016xUL' % int(g[14], 16))
        types.append(int(g[15]))
        tail = [int(v) for v in g[16:]]
        assert len(tail) in (0, 10), len(tail)
        vals.extend(tail + [0] * (10 - len(tail)))
    expected = []
    for i in range(96):
        expected.append(types[i])
        expected.extend(vals[i * 10:i * 10 + 10])
    w('\n///|\n')
    w('test "warp neighbour masks and derivation match dav1d" {\n')
    w('  let seeds : Array[UInt] = [\n')
    w(wrap(seeds))
    w('\n  ]\n')
    w('  let cfg : Array[Int] = [\n')
    w(wrap(cfgs))
    w('\n  ]\n')
    w('  let exp_m0 : Array[UInt64] = [\n')
    w(wrap(m0))
    w('\n  ]\n')
    w('  let exp_m1 : Array[UInt64] = [\n')
    w(wrap(m1))
    w('\n  ]\n')
    w('  let expected : Array[Int] = [\n')
    w(wrap(expected))
    w('\n  ]\n')
    w('  let actual : Array[Int] = []\n')
    w('  for i in 0..<96 {\n')
    w('    let rows = av1_warp_test_rows(seeds[i])\n')
    w('    let bx4 = cfg[i * 12 + 0]\n')
    w('    let by4 = cfg[i * 12 + 1]\n')
    w('    let bw4 = cfg[i * 12 + 2]\n')
    w('    let bh4 = cfg[i * 12 + 3]\n')
    w('    let w4 = cfg[i * 12 + 4]\n')
    w('    let h4 = cfg[i * 12 + 5]\n')
    w('    let have_left = cfg[i * 12 + 6] != 0\n')
    w('    let have_top = cfg[i * 12 + 7] != 0\n')
    w('    let top_right = cfg[i * 12 + 8] != 0\n')
    w('    let ref_ = cfg[i * 12 + 9]\n')
    w('    let mvy = cfg[i * 12 + 10]\n')
    w('    let mvx = cfg[i * 12 + 11]\n')
    w('    let (mask0, mask1) = @libavcodec.av1_inter_find_matching_ref(\n')
    w('      rows, bx4, by4, bw4, bh4, w4, h4, have_left, have_top,\n')
    w('      top_right, 64, ref_,\n')
    w('    )\n')
    w('    assert_eq(mask0, exp_m0[i])\n')
    w('    assert_eq(mask1, exp_m1[i])\n')
    w('    if (mask0 | mask1) != 0UL {\n')
    w('      let r = @libavcodec.av1_inter_derive_warpmv(\n')
    w('        rows, bx4, by4, bw4, bh4, mask0, mask1, (mvy, mvx),\n')
    w('      )\n')
    w('      actual.push(r.typ)\n')
    w('      for j in 0..<6 {\n')
    w('        actual.push(r.matrix[j])\n')
    w('      }\n')
    w('      actual.push(r.alpha)\n')
    w('      actual.push(r.beta)\n')
    w('      actual.push(r.gamma)\n')
    w('      actual.push(r.delta)\n')
    w('    } else {\n')
    w('      actual.push(-1)\n')
    w('      for _ in 0..<10 {\n')
    w('        actual.push(0)\n')
    w('      }\n')
    w('    }\n')
    w('  }\n')
    w('  assert_eq(actual, expected)\n')
    w('}\n')
    os.makedirs(OUTDIR, exist_ok=True)
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    with io.open(os.path.join(OUTDIR, 'moon.pkg'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('import {\n  "ffmpeg/moonbit/libavcodec",\n} for "test"\n')
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
