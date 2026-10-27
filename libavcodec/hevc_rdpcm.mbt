///|
/// FFmpeg 9.0.2 hevc/dsp_template.c transform_rdpcm: cumulative spatial
/// residuals, with int16 storage wrapping after every addition.
/// Original FFmpeg code is LGPL-2.1-or-later.
fn hevc_transform_rdpcm(
  coeffs : Array[Int32],
  log2_size : Int32,
  vertical : Bool,
) -> Unit {
  let size = 1 << log2_size
  for y in 0..<size {
    for x in 0..<size {
      if (vertical && y == 0) || (!vertical && x == 0) {
        continue
      }
      let at = y * size + x
      let prev = at - (if vertical { size } else { 1 })
      coeffs[at] = ((coeffs[at] + coeffs[prev] + 32768) & 65535) - 32768
    }
  }
}

///|
/// Explicit RDPCM has independent luma/chroma context pairs. -1 = off;
/// 0 = horizontal; 1 = vertical.
fn HevcCabac::explicit_rdpcm(self : HevcCabac, plane : Int32) -> Int32 {
  let chroma = if plane == 0 { 0 } else { 1 }
  if self.bin(49 + chroma) == 0 {
    -1
  } else {
    self.bin(51 + chroma)
  }
}
