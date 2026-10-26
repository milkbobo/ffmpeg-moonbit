#!/usr/bin/env python3
"""Emit libavcodec/av1_refmvs_vectors/refmvs_state_parity_test.mbt from
%TEMP%/refmvs_state_dump.txt produced by .scratch/av1/state_dump.c
(dav1d 1.5.1 refmvs.c state machine)."""
import io
import os

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_refmvs_vectors',
                   'refmvs_state_parity_test.mbt')

HEADER = '''///|
/// refmvs state machine verified against dav1d 1.5.1 `src/refmvs.c`:
/// `tile_sbrow_init` ring over 16/32-pixel superblocks, `splat_mv_c`,
/// `save_tmvs_c`, and `load_tmvs_c` with scaled temporal projection and
/// equal-run fast-forward (`scripts/_emit_av1_refmvs_state_vectors.py`).

///|
fn refmvs_state_hash_v(h : Int64, v : Int) -> Int64 {
  (h * 31L + (v & 0xffff).to_int64()) % 1000000007L
}

///|
fn refmvs_state_hash_slots(
  state : @libavcodec.Av1RefmvsTileState,
  off : Int,
  sbsz : Int,
) -> Int64 {
  let mut h = 17L
  for i in 0..<37 {
    let used = i == off || i == off + 2 || i == off + 4 ||
      (i >= off + 5 && i < off + 5 + sbsz)
    if !used {
      continue
    }
    let row = state.rows[i]
    for x in 0..<(state.rp_stride * 2) {
      let b = row[x]
      h = refmvs_state_hash_v(h, b.ref0)
      h = refmvs_state_hash_v(h, b.ref1)
      h = refmvs_state_hash_v(h, b.bs)
      h = refmvs_state_hash_v(h, b.mf)
      h = refmvs_state_hash_v(h, b.mv0.0)
      h = refmvs_state_hash_v(h, b.mv0.1)
      h = refmvs_state_hash_v(h, b.mv1.0)
      h = refmvs_state_hash_v(h, b.mv1.1)
    }
  }
  h
}

///|
fn refmvs_state_hash_rp(
  rp : FixedArray[@libavcodec.Av1Rtb],
  n : Int,
) -> Int64 {
  let mut h = 17L
  for i in 0..<n {
    h = refmvs_state_hash_v(h, rp[i].mv.0)
    h = refmvs_state_hash_v(h, rp[i].mv.1)
    h = refmvs_state_hash_v(h, rp[i].ref_)
  }
  h
}

///|
fn refmvs_state_hash_proj(state : @libavcodec.Av1RefmvsTileState) -> Int64 {
  let mut h = 17L
  for i in 0..<(16 * state.rp_stride) {
    h = refmvs_state_hash_v(h, state.rp_proj[i].mv.0)
    h = refmvs_state_hash_v(h, state.rp_proj[i].mv.1)
    h = refmvs_state_hash_v(h, state.rp_proj[i].ref_)
  }
  h
}

///|
fn refmvs_state_src_maps(
  seed : Int,
  stride : Int,
  ih8 : Int,
) -> FixedArray[FixedArray[@libavcodec.Av1Rtb]] {
  FixedArray::makei(
    7,
    _ => FixedArray::makei(stride * ih8, i => {
      let y = i / stride
      let x = i % stride
      let qx = x / 3
      let qy = y / 2
      let k = qx * 5 + qy * 7 + seed * 3
      {
        mv: (
          ((qx * 11 + qy * 13 + seed * 17) % 9 - 4) * 64,
          ((qx * 19 + qy * 23 + seed * 29) % 9 - 4) * 64,
        ),
        ref_: if k % 6 == 0 { 0 } else { 1 + (k & 7) % 7 },
      }
    }),
  )
}
'''


def main():
    cases = []
    with io.open(os.path.join(TMP, 'refmvs_state_dump.txt')) as f:
        lines = [l.split() for l in f if l.strip()]
    cur = None
    for t in lines:
        if t[0] == 'F':
            cur = {
                'idx': int(t[1]), 'stride': int(t[2]), 'iw8': int(t[3]),
                'ih8': int(t[4]), 'sbsz': int(t[5]), 'seed': int(t[6]),
                'signs': [], 'sby': [], 'nops': [], 'slot': [], 'rp': [],
                'ops': [], 'loads': [], 'proj': [],
            }
            cases.append(cur)
        elif t[0] == 'G':
            cur['signs'] = [int(v) for v in t[1:]]
        elif t[0] == 'O':
            cur['ops'].append([int(v) for v in t[1:]])
        elif t[0] == 'H':
            cur['sby'].append(int(t[1]))
            cur['nops'].append(len(cur['ops']) - sum(cur['nops']))
            cur['slot'].append(int(t[2]))
            cur['rp'].append(int(t[3]))
        elif t[0] == 'L':
            vals = [int(v) for v in t[1:]]
            assert len(vals) == 34, len(vals)
            cur['loads'].append(vals[:33])
            cur['proj'].append(vals[33])

    assert len(cases) == 5, len(cases)
    out = io.StringIO()
    w = out.write
    w(HEADER)
    for c in cases:
        stride, iw8, ih8, sbsz = c['stride'], c['iw8'], c['ih8'], c['sbsz']
        w('\n///|\n')
        w('test "refmvs state machine matches dav1d C (case %d)" {\n' % c['idx'])
        w('  let sign : FixedArray[Int] = [%s]\n'
          % ', '.join(str(v) for v in c['signs']))
        w('  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(\n')
        w('    %d * %d, _ => { mv: (0, 0), ref_: 0 },\n' % (stride, ih8))
        w('  )\n')
        w('  let state = @libavcodec.av1_refmvs_tile_state_new(%d, %d, %d, %d)\n'
          % (stride, iw8, ih8, sbsz))
        w('  let ops : Array[Array[Int]] = [\n')
        for o in c['ops']:
            w('    [%s],\n' % ', '.join(str(v) for v in o))
        w('  ]\n')
        w('  let sbys : Array[Int] = [%s]\n'
          % ', '.join(str(v) for v in c['sby']))
        w('  let nops : Array[Int] = [%s]\n'
          % ', '.join(str(v) for v in c['nops']))
        w('  let slot_hashes : Array[Int64] = [%s]\n'
          % ', '.join('%dL' % v for v in c['slot']))
        w('  let rp_hashes : Array[Int64] = [%s]\n'
          % ', '.join('%dL' % v for v in c['rp']))
        w('  let mut oi = 0\n')
        w('  for s in 0..<sbys.length() {\n')
        w('    let sby = sbys[s]\n')
        w('    state.init_sbrow(sby)\n')
        w('    for _ in 0..<nops[s] {\n')
        w('      let o = ops[oi]\n')
        w('      oi = oi + 1\n')
        w('      let block : @libavcodec.Av1Rb = {\n')
        w('        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],\n')
        w('        mv0: (o[8], o[9]), mv1: (o[10], o[11]),\n')
        w('      }\n')
        w('      state.splat_mv(block, o[0], o[1], o[2], o[3])\n')
        w('    }\n')
        w('    let rs = sby * (%d / 2)\n' % sbsz)
        w('    let re = if rs + %d / 2 < %d { rs + %d / 2 } else { %d }\n'
          % (sbsz, ih8, sbsz, ih8))
        w('    state.save_tmvs(rp, sign, 0, %d, rs, re)\n' % iw8)
        w('    assert_eq(\n')
        w('      refmvs_state_hash_slots(state, (%d * sby) & 16, %d),\n'
          % (sbsz, sbsz))
        w('      slot_hashes[s],\n')
        w('    )\n')
        w('    assert_eq(\n')
        w('      refmvs_state_hash_rp(rp, %d * %d),\n' % (stride, ih8))
        w('      rp_hashes[s],\n')
        w('    )\n')
        w('  }\n')
        w('  let refs = refmvs_state_src_maps(%d, %d, %d)\n'
          % (c['seed'], stride, ih8))
        w('  for i in 0..<(16 * %d) {\n' % stride)
        w('    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }\n')
        w('  }\n')
        w('  let loads : Array[Array[Int]] = [\n')
        for l in c['loads']:
            w('    [%s],\n' % ', '.join(str(v) for v in l))
        w('  ]\n')
        w('  let proj_hashes : Array[Int64] = [%s]\n'
          % ', '.join('%dL' % v for v in c['proj']))
        w('  for li in 0..<loads.length() {\n')
        w('    let l = loads[li]\n')
        w('    let init = @libavcodec.av1_refmvs_frame_init_probe(\n')
        w('      FixedArray::make(7, 0), FixedArray::make(7, 0),\n')
        w('      FixedArray::make(7, 0),\n')
        w('      FixedArray::makei(3, i => l[6 + i]),\n')
        w('      FixedArray::makei(3, i => l[9 + i]),\n')
        w('      FixedArray::makei(3, m => FixedArray::makei(7, j => '
          'l[12 + m * 7 + j])),\n')
        w('      l[5], true,\n')
        w('    )\n')
        w('    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])\n')
        w('    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])\n')
        w('  }\n')
        w('}\n')
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out.getvalue())
    print('wrote', OUT, len(out.getvalue()), 'bytes')


if __name__ == '__main__':
    main()
