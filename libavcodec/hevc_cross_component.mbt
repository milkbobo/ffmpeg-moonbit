///|
/// Cross-component prediction from FFmpeg 9.0.2 hevc/cabac.c and hevcdec.c.
/// Copyright (C) 2012 - 2013 Guillaume Martres, Gildas Cocherel.
/// Copyright (C) 2012 - 2013 Mickael Raulet, Wassim Hamidouche.
/// Original FFmpeg code is LGPL-2.1-or-later.
fn HevcCabac::cross_component_scale(self : HevcCabac, chroma : Int32) -> Int32 {
  let mut magnitude = 0
  while magnitude < 4 && self.bin(167 + 4 * chroma + magnitude) != 0 {
    magnitude += 1
  }
  if magnitude == 0 {
    0
  } else {
    (1 << (magnitude - 1)) * (1 - 2 * self.bin(175 + chroma))
  }
}

///|
/// Combine spatial residuals before clipping reconstructed pixels. The C
/// destination is int16_t, so additions wrap rather than saturate.
fn hevc_cross_component_residual(
  chroma : Array[Int32],
  luma : Array[Int32],
  scale : Int32,
) -> Unit {
  for i in 0..<chroma.length() {
    chroma[i] = ((chroma[i] + ((scale * luma[i]) >> 3) + 32768) & 65535) - 32768
  }
}
