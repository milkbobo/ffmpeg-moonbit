///|
/// SIMD (`@v128`) accelerated `av_strnstr` from `libavutil/avstring.c`.
///
/// FFmpeg's `av_strnstr` is a byte (here: character) scan; the vectorised form
/// is the usual "memchr the first needle character, then verify" strategy:
/// scan the haystack 8 UTF-16 code units at a time with
/// `@v128.v128_load_i16x8`, compare against a splat of the needle's first
/// character (`i16x8_eq` + `i16x8_bitmask`), and only run the scalar
/// full-needle check on the surviving candidate positions.
///
/// Semantics are preserved exactly: the candidate positions are the same
/// `i in [0, min(hay_length - nl, h.length() - nl)]` the scalar loop visits,
/// and the first hit is returned.
///
/// UTF-16 caveat: `@v128.v128_load_i16x8` reads *code units*, while the port's
/// semantics index `String::to_array()` *code points*. These coincide only for
/// BMP-only text, so the SIMD path is taken only when both `haystack` and
/// `needle` are BMP (`length()` == code-point count); otherwise the scalar
/// `av_strnstr` is used verbatim.
///
/// Gated to `native`/`wasm`; equality with the scalar path is asserted in
/// `avstring_v128_wbtest.mbt`.

///| Full-needle check at `pos`. */
#cfg(any(target="native", target="wasm"))
fn strnstr_match(h : Array[Char], n : Array[Char], pos : Int) -> Bool {
  for k = 0; k < n.length(); k = k + 1 {
    if h[pos + k] != n[k] {
      return false
    }
  }
  true
}

///|
/// `av_strnstr` with a 8-code-unit SIMD candidate scan. Returns the same
/// `Int?` result as `av_strnstr`.
#cfg(any(target="native", target="wasm"))
pub fn av_strnstr_v128(
  haystack : String,
  needle : String,
  hay_length : Int,
) -> Int? {
  let n = needle.to_array()
  let nl = n.length()
  if nl == 0 {
    return Some(0)
  }
  let h = haystack.to_array()
  if hay_length < nl {
    return None
  }
  // BMP-only fast path; code units == code points there.
  if haystack.length() != h.length() || needle.length() != nl {
    return av_strnstr(haystack, needle, hay_length)
  }
  let mut max_i = hay_length - nl
  if h.length() - nl < max_i {
    max_i = h.length() - nl
  }
  if max_i < 0 {
    return None
  }
  let c0 : UInt16 = (n[0].to_int() & 0xFFFF).to_uint16()
  let first = @v128.i16x8_const(c0, c0, c0, c0, c0, c0, c0, c0)
  let hlen = h.length()
  let mut i = 0
  while i + 8 <= hlen {
    let v = @v128.v128_load_i16x8(haystack, i)
    let m = @v128.i16x8_bitmask(@v128.i16x8_eq(v, first))
    for k = 0; k < 8; k = k + 1 {
      if ((m >> k) & 1) == 1 {
        let pos = i + k
        if pos > max_i {
          return None
        }
        if strnstr_match(h, n, pos) {
          return Some(pos)
        }
      }
    }
    i = i + 8
  }
  while i <= max_i {
    if strnstr_match(h, n, i) {
      return Some(i)
    }
    i = i + 1
  }
  None
}
