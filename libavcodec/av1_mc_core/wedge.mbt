///|
/// Wedge and inter-intra compound masks: port of dav1d 1.5.1 `src/wedge.c`
/// (`dav1d_init_ii_wedge_masks`). Masks are generated deterministically at
/// package load exactly as dav1d's one-time initializer does. Layout index is
/// 0 = 4:4:4, 1 = 4:2:2, 2 = 4:2:0; `bs` is the dav1d `enum BlockSize` value
/// (only BS_32x32..BS_8x8 wedge sizes carry masks).

///|
/// dav1d `enum WedgeDirectionType`.
let av1_wedge_dir_horizontal : Int = 0

///|
let av1_wedge_dir_vertical : Int = 1

///|
let av1_wedge_dir_oblique27 : Int = 2

///|
let av1_wedge_dir_oblique63 : Int = 3

///|
let av1_wedge_dir_oblique117 : Int = 4

///|
let av1_wedge_dir_oblique153 : Int = 5

///|
/// `insert_border` from wedge.c: one 64-wide master row from an 8-tap border.
fn av1_wedge_insert_border(
  dst : FixedArray[Byte], dst_off : Int, src : FixedArray[Byte], ctr : Int,
) -> Unit {
  if ctr > 4 {
    for i in 0..<(ctr - 4) {
      dst[dst_off + i] = 0
    }
  }
  let dst_at = (if ctr > 4 { ctr } else { 4 }) - 4
  let src_at = if 4 - ctr > 0 { 4 - ctr } else { 0 }
  let n = if 64 - ctr < 8 { 64 - ctr } else { 8 }
  for i in 0..<n {
    dst[dst_off + dst_at + i] = src[src_at + i]
  }
  if ctr < 60 {
    for i in 0..<(60 - ctr) {
      dst[dst_off + ctr + 4 + i] = 64
    }
  }
}

///|
fn av1_wedge_transpose(dst : FixedArray[Byte], src : FixedArray[Byte]) -> Unit {
  for y in 0..<64 {
    for x in 0..<64 {
      dst[x * 64 + y] = src[y * 64 + x]
    }
  }
}

///|
fn av1_wedge_hflip(dst : FixedArray[Byte], src : FixedArray[Byte]) -> Unit {
  for y in 0..<64 {
    for x in 0..<64 {
      dst[y * 64 + 63 - x] = src[y * 64 + x]
    }
  }
}

///|
/// The six 64x64 master templates.
fn av1_wedge_build_master() -> FixedArray[FixedArray[Byte]] {
  let odd_border : FixedArray[Byte] = [
    1, 2, 6, 18, 37, 53, 60, 63,
  ]
  let even_border : FixedArray[Byte] = [
    1, 4, 11, 27, 46, 58, 62, 63,
  ]
  let vert_border : FixedArray[Byte] = [
    0, 2, 7, 21, 43, 57, 62, 64,
  ]
  // makei: each direction needs its own buffer (a shared init value would
  // alias one array across all six templates).
  let master = FixedArray::makei(6, _ => FixedArray::make(4096, b'\x00'))
  for y in 0..<64 {
    av1_wedge_insert_border(
      master[av1_wedge_dir_vertical], y * 64, vert_border, 32,
    )
  }
  for y = 0, off = 0, ctr = 48; y < 64; y = y + 2, off = off + 128, ctr = ctr - 1 {
    av1_wedge_insert_border(
      master[av1_wedge_dir_oblique63], off, even_border, ctr,
    )
    av1_wedge_insert_border(
      master[av1_wedge_dir_oblique63], off + 64, odd_border, ctr - 1,
    )
  }
  av1_wedge_transpose(
    master[av1_wedge_dir_oblique27], master[av1_wedge_dir_oblique63],
  )
  av1_wedge_transpose(
    master[av1_wedge_dir_horizontal], master[av1_wedge_dir_vertical],
  )
  av1_wedge_hflip(
    master[av1_wedge_dir_oblique117], master[av1_wedge_dir_oblique63],
  )
  av1_wedge_hflip(
    master[av1_wedge_dir_oblique153], master[av1_wedge_dir_oblique27],
  )
  master
}

///|
/// wedge_code_type: (direction, x_offset, y_offset).
let av1_wedge_codebook_heqw : FixedArray[(Int, Int, Int)] = [
  (2, 4, 4), (3, 4, 4), (4, 4, 4), (5, 4, 4), (0, 4, 2), (0, 4, 6), (1, 2, 4), (1, 6, 4),
  (2, 4, 2), (2, 4, 6), (5, 4, 2), (5, 4, 6), (3, 2, 4), (3, 6, 4), (4, 2, 4), (4, 6, 4),
]

///|
let av1_wedge_codebook_hltw : FixedArray[(Int, Int, Int)] = [
  (2, 4, 4), (3, 4, 4), (4, 4, 4), (5, 4, 4), (1, 2, 4), (1, 4, 4), (1, 6, 4), (0, 4, 4),
  (2, 4, 2), (2, 4, 6), (5, 4, 2), (5, 4, 6), (3, 2, 4), (3, 6, 4), (4, 2, 4), (4, 6, 4),
]

///|
let av1_wedge_codebook_hgtw : FixedArray[(Int, Int, Int)] = [
  (2, 4, 4), (3, 4, 4), (4, 4, 4), (5, 4, 4), (0, 4, 2), (0, 4, 4), (0, 4, 6), (1, 4, 4),
  (2, 4, 2), (2, 4, 6), (5, 4, 2), (5, 4, 6), (3, 2, 4), (3, 6, 4), (4, 2, 4), (4, 6, 4),
]

///|
/// `copy2d` from wedge.c: crop a w*h window out of a master template and
/// optionally invert it (64 - v).
fn av1_wedge_copy2d(
  master : FixedArray[Byte], invert : Bool, w : Int, h : Int,
  x_off : Int, y_off : Int,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = master[(y_off + y) * 64 + x_off + x].to_int()
      dst[y * w + x] = if invert { 64 - v } else { v }
    }
  }
  dst
}

///|
/// `init_chroma` from wedge.c: subsample a luma mask to chroma. `sign` is
/// dav1d's 0/1 rounding adjustment selecting one of the two polarities.
fn av1_wedge_init_chroma(
  luma : FixedArray[Int32], sign : Int, w : Int, h : Int, ss_ver : Int,
) -> FixedArray[Int32] {
  let cw = w >> 1
  let ch = h >> ss_ver
  let dst = FixedArray::make(cw * ch, 0)
  for y = 0; y < h; y = y + 1 + ss_ver {
    let dy = y >> ss_ver
    for x = 0; x < w; x = x + 2 {
      let mut sum = luma[y * w + x] + luma[y * w + x + 1] + 1
      if ss_ver != 0 {
        sum = sum + luma[(y + 1) * w + x] + luma[(y + 1) * w + x + 1] + 1
      }
      dst[dy * cw + (x >> 1)] = (sum - sign) >> (1 + ss_ver)
    }
  }
  dst
}

///|
/// Wedge mask storage for one layout: `slot` is `bs - 7` (0..10; slots 3 and
/// 7 are non-wedge sizes and stay empty), entries are `sign * 16 + wedge_idx`.
/// For 4:4:4 both sign halves hold the same mask, as in dav1d.
priv struct Av1WedgeLayoutMasks {
  slots : FixedArray[FixedArray[FixedArray[Int32]]]
}

///|
fn av1_wedge_empty_slot() -> FixedArray[FixedArray[Int32]] {
  let empty : FixedArray[Int32] = FixedArray::make(0, 0)
  FixedArray::make(0, empty)
}

///|
fn av1_wedge_empty_slots() -> FixedArray[FixedArray[FixedArray[Int32]]] {
  FixedArray::make(11, av1_wedge_empty_slot())
}

///|
/// `fill2d_16x2` from wedge.c: build the 16 masks of one block size in all
/// three layouts.
fn av1_wedge_fill(
  master : FixedArray[FixedArray[Byte]], cb : FixedArray[(Int, Int, Int)],
  w : Int, h : Int, signs : Int,
) -> (Av1WedgeLayoutMasks, Av1WedgeLayoutMasks, Av1WedgeLayoutMasks) {
  let m444 = FixedArray::make(32, FixedArray::make(0, (0 : Int32)))
  let m422 = FixedArray::make(32, FixedArray::make(0, (0 : Int32)))
  let m420 = FixedArray::make(32, FixedArray::make(0, (0 : Int32)))
  for n in 0..<16 {
    let dir = cb[n].0
    let xo = cb[n].1
    let yo = cb[n].2
    let invert = ((signs >> n) & 1) == 1
    let luma = av1_wedge_copy2d(
      master[dir], invert, w, h, 32 - ((w * xo) >> 3), 32 - ((h * yo) >> 3),
    )
    m444[n] = luma
    m444[16 + n] = luma
    m422[n] = av1_wedge_init_chroma(luma, 0, w, h, 0)
    m422[16 + n] = av1_wedge_init_chroma(luma, 1, w, h, 0)
    m420[n] = av1_wedge_init_chroma(luma, 0, w, h, 1)
    m420[16 + n] = av1_wedge_init_chroma(luma, 1, w, h, 1)
  }
  (
    { slots: FixedArray::make(1, m444) },
    { slots: FixedArray::make(1, m422) },
    { slots: FixedArray::make(1, m420) },
  )
}

///|
/// `ii_weights_1d` from wedge.c.
let av1_ii_weights_1d : FixedArray[Int] = [
  60, 52, 45, 39, 34, 30, 26, 22, 19, 17, 15, 13, 11, 10, 8, 7,
  6, 6, 5, 4, 4, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 1,
]

///|
/// `build_nondc_ii_masks` from wedge.c: one buffer of three planes
/// (vert, hor, smooth), each w*h.
fn av1_ii_build_nondc(
  w : Int, h : Int, step : Int,
) -> FixedArray[FixedArray[Int32]] {
  let planes = FixedArray::make(3, FixedArray::make(0, 0))
  for p in 0..<3 {
    let m = FixedArray::make(w * h, 0)
    for y in 0..<h {
      let off = y * w
      for x in 0..<w {
        m[off + x] = match p {
          0 => av1_ii_weights_1d[y * step] // vert: row constant
          1 => av1_ii_weights_1d[x * step] // hor
          _ => {
            let d = if x < y { x } else { y }
            av1_ii_weights_1d[d * step] // smooth
          }
        }
      }
    }
    planes[p] = m
  }
  planes
}

///|
/// The nine shared nondc buffers: (w, h, step).
let av1_ii_nondc_dims : FixedArray[(Int, Int, Int)] = [
  (32, 32, 1), (16, 32, 1), (16, 16, 2), (8, 32, 1), (8, 16, 2), (8, 8, 4),
  (4, 16, 2), (4, 8, 4), (4, 4, 8),
]

///|
/// Inter-intra block sizes (bs enum, w, h) in dav1d's assignment order.
let av1_ii_sizes : FixedArray[(Int, Int, Int)] = [
  (7, 32, 32), (8, 32, 16), (11, 16, 32), (12, 16, 16), (13, 16, 8), (16, 8, 16), (17, 8, 8),
]

///|
/// Source buffer index per layout for each inter-intra size.
let av1_ii_src_444 : FixedArray[Int] = [0, 0, 1, 2, 2, 4, 5]

///|
let av1_ii_src_422 : FixedArray[Int] = [1, 2, 3, 4, 5, 6, 7]

///|
let av1_ii_src_420 : FixedArray[Int] = [2, 2, 4, 5, 5, 7, 8]

///|
/// Wedge block sizes: (bs enum, w, h, codebook index 0=heqw 1=hltw 2=hgtw,
/// signs bitmask).
let av1_wedge_sizes : FixedArray[(Int, Int, Int, Int, Int)] = [
  (7, 32, 32, 0, 0x7bfb), (8, 32, 16, 1, 0x7beb), (9, 32, 8, 1, 0x6beb),
  (11, 16, 32, 2, 0x7beb), (12, 16, 16, 0, 0x7bfb), (13, 16, 8, 1, 0x7beb),
  (15, 8, 32, 2, 0x7aeb), (16, 8, 16, 2, 0x7beb), (17, 8, 8, 0, 0x7bfb),
]

///|
fn av1_wedge_codebook(idx : Int) -> FixedArray[(Int, Int, Int)] {
  if idx == 0 {
    av1_wedge_codebook_heqw
  } else if idx == 1 {
    av1_wedge_codebook_hltw
  } else {
    av1_wedge_codebook_hgtw
  }
}

///|
/// Generated tables, mirroring `dav1d_masks`: per layout 11 bs slots
/// (`bs - 7`), wedge entries `sign * 16 + idx`, ii entries by mode.
priv struct Av1CompoundMaskTables {
  wedge : FixedArray[Av1WedgeLayoutMasks] // 3 layouts
  ii : FixedArray[FixedArray[FixedArray[FixedArray[Int32]]]] // [layout][slot][mode]
}

///|
fn av1_wedge_build_tables() -> Av1CompoundMaskTables {
  let master = av1_wedge_build_master()
  // makei at every nested level of reference type: a shared init value
  // would alias one array across layouts / slots / modes.
  let wedge = FixedArray::makei(3, _ => { slots: av1_wedge_empty_slots() })
  // 11 slots; 3 (16x64) and 7 (16x4) are not wedge sizes and stay empty.
  for layout in 0..<3 {
    wedge[layout] = { slots: av1_wedge_empty_slots() }
  }
  for entry in av1_wedge_sizes {
    let (bs, w, h, cb_idx, signs) = entry
    let (l444, l422, l420) = av1_wedge_fill(
      master, av1_wedge_codebook(cb_idx), w, h, signs,
    )
    wedge[0].slots[bs - 7] = l444.slots[0]
    wedge[1].slots[bs - 7] = l422.slots[0]
    wedge[2].slots[bs - 7] = l420.slots[0]
  }
  // Inter-intra masks: shared nondc buffers plus the all-32 dc mask.
  let buffers = FixedArray::makei(
    9,
    _ => FixedArray::make(3, FixedArray::make(0, (0 : Int32))),
  )
  for i in 0..<9 {
    let (w, h, step) = av1_ii_nondc_dims[i]
    buffers[i] = av1_ii_build_nondc(w, h, step)
  }
  let ii = FixedArray::makei(
    3,
    _ => FixedArray::makei(
      11,
      _ => FixedArray::make(4, FixedArray::make(0, (0 : Int32))),
    ),
  )
  let srcs = [av1_ii_src_444, av1_ii_src_422, av1_ii_src_420]
  for layout in 0..<3 {
    let ss_hor = if layout == 0 { 0 } else { 1 }
    let ss_ver = if layout == 2 { 1 } else { 0 }
    for isi in 0..<7 {
      let (bs, w, h) = av1_ii_sizes[isi]
      let cw = w >> ss_hor
      let ch = h >> ss_ver
      let slot = FixedArray::make(4, FixedArray::make(0, (0 : Int32)))
      let dc = FixedArray::make(cw * ch, 32)
      slot[0] = dc
      for mode in 1..<4 {
        let src = buffers[srcs[layout][isi]][mode - 1]
        let m = FixedArray::make(cw * ch, 0)
        for i in 0..<(cw * ch) {
          m[i] = src[i]
        }
        slot[mode] = m
      }
      ii[layout][bs - 7] = slot
    }
  }
  { wedge, ii }
}

///|
let av1_compound_masks : Av1CompoundMaskTables = av1_wedge_build_tables()

///|
/// Wedge compound mask. `layout` 0=4:4:4 1=4:2:2 2=4:2:0; `bs` is the dav1d
/// `enum BlockSize` value; the returned packed block has the layout's chroma
/// dimensions (for 4:4:4, the luma dimensions).
pub fn av1_wedge_mask(
  layout : Int, bs : Int, sign : Int, wedge_idx : Int,
) -> FixedArray[Int32] {
  av1_compound_masks.wedge[layout].slots[bs - 7][(sign & 1) * 16 + wedge_idx]
}

///|
/// Inter-intra mask. `mode` is dav1d `enum InterIntraPredMode`
/// (0=DC, 1=VERT, 2=HOR, 3=SMOOTH); semantics follow the `II_MASK` lookup
/// except that the caller handles the interintra-type wedge fallback.
pub fn av1_ii_mask(
  layout : Int, bs : Int, mode : Int,
) -> FixedArray[Int32] {
  av1_compound_masks.ii[layout][bs - 7][mode]
}
