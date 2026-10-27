///|
/// dav1d 1.5.1 qm.c: address the compact source matrices directly rather than
/// expanding all 19 transform sizes. Coefficients use transposed x*height+y
/// storage. 64-point transforms reuse the corresponding 32-point matrix.
fn av1_qm_weight(
  level : Int32,
  chroma : Int32,
  tx : Int32,
  rc : Int32,
) -> Int32 {
  if level == 15 {
    return 32
  }
  let w = 4 << av1_imin(av1_txfm_lw(tx), 3)
  let h = 4 << av1_imin(av1_txfm_lh(tx), 3)
  let x = rc / h
  let y = rc % h
  let bank = level * 2 + chroma
  if w == h {
    let step = 32 / w
    let off = if w == 4 { 3 } else if w == 8 { 1 } else { 0 }
    let sx = x * step + off
    let sy = y * step + off
    let hi = av1_imax(sx, sy)
    let lo = av1_imin(sx, sy)
    av1_qm_square[bank * 528 + hi * (hi + 1) / 2 + lo].to_int()
  } else {
    let major = if w > h { x } else { y }
    let minor = if w > h { y } else { x }
    let big = av1_imax(w, h)
    let small = av1_imin(w, h)
    let col_off = if big == 8 { 1 } else { 0 }
    let row_off = if small == 4 { 1 } else { 0 }
    let col = major * (32 / big) + col_off
    let row = minor * (16 / small) + row_off
    av1_qm_rect[bank * 512 + row * 32 + col].to_int()
  }
}
