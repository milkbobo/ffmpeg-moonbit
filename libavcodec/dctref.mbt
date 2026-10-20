///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/dctref.c`: the double-precision
/// reference DCT/IDCT used by `libavcodec/tests/dct.c` to validate the integer
/// IDCTs (`ff_ref_dct_init`, `ff_ref_fdct`, `ff_ref_idct`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2009 Dylan Yudaken.
/// This port keeps the same license.
///
/// This module exists so the ported `simple_idct` can be checked against the
/// very reference FFmpeg uses, with the same error tolerances. It is a faithful
/// port: `floor(tmp + 0.499999999999)` / `floor(tmp + 0.5)` values are stored
/// back through `i16` on purpose, because the C code stores into `short`.

///|
/// `static double coefficients[8 * 8]`, filled by `ff_ref_dct_init`. */
let coefficients : Array[Double] = Array::make(64, 0.0)

///|
/// `ff_ref_dct_init`: build the DCT basis matrix. */
pub fn ff_ref_dct_init() -> Unit {
  for j = 0; j < 8; j = j + 1 {
    coefficients[j] = 0.125.sqrt()
    let mut i = 8
    while i < 64 {
      coefficients[i + j] = 0.5 *
        @math.cos(i.to_double() * (j.to_double() + 0.5) * @math.PI / 64.0)
      i = i + 8
    }
  }
}

///|
/// `ff_ref_fdct`: double-precision forward DCT,
/// `block = coefficients * block * coefficients'`.
pub fn ff_ref_fdct(block : Array[Int32]) -> Unit {
  let out : Array[Double] = Array::make(64, 0.0)
  for i = 0; i < 64; i = i + 8 {
    for j = 0; j < 8; j = j + 1 {
      let mut tmp = 0.0
      for k = 0; k < 8; k = k + 1 {
        tmp = tmp + coefficients[i + k] * block[k * 8 + j].to_double()
      }
      out[i + j] = tmp * 8.0
    }
  }
  for j = 0; j < 8; j = j + 1 {
    for i = 0; i < 64; i = i + 8 {
      let mut tmp = 0.0
      for k = 0; k < 8; k = k + 1 {
        tmp = tmp + out[i + k] * coefficients[j * 8 + k]
      }
      block[i + j] = i16(@math.floor(tmp + 0.499999999999).to_int())
    }
  }
}

///|
/// `ff_ref_idct`: double-precision inverse DCT,
/// `block = (coefficients') * block * coefficients`.
pub fn ff_ref_idct(block : Array[Int32]) -> Unit {
  let out : Array[Double] = Array::make(64, 0.0)
  for i = 0; i < 64; i = i + 8 {
    for j = 0; j < 8; j = j + 1 {
      let mut tmp = 0.0
      for k = 0; k < 8; k = k + 1 {
        tmp = tmp + block[i + k].to_double() * coefficients[k * 8 + j]
      }
      out[i + j] = tmp
    }
  }
  for i = 0; i < 8; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      let mut tmp = 0.0
      let mut k = 0
      while k < 64 {
        tmp = tmp + coefficients[k + i] * out[k + j]
        k = k + 8
      }
      block[i * 8 + j] = i16(@math.floor(tmp + 0.5).to_int())
    }
  }
}
