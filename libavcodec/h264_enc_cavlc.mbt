///|
/// CAVLC coefficient writing for the H.264 encoder: the exact inverse of
/// `h264_decode_residual`. Every VLC comes from the decoder's own
/// `(length, bits)` tables, so a stream written here parses back
/// bit-identically: `coeff_token` symbols pack
/// `total_coeff * 4 + trailing_ones`, levels are emitted highest frequency
/// first with the suffix-length machine the decoder mirrors, then
/// `total_zeros` and the backward `run_before` chain.

///|
/// Write `level_prefix`: `prefix` zero bits then a terminating one. */
fn h264_enc_write_level_prefix(r : H264Rbsp, prefix : Int) -> Unit {
  for k = 0; k < prefix; k = k + 1 {
    r.put_bit(0)
  }
  r.put_bit(1)
}

///|
/// Emit one level code value `v` (the pre-adjustment `levelCode` remainder
/// the decoder reconstructs) with `suffix_length` suffix bits, mirroring the
/// reader's prefix/suffix/escape cases. Returns the `level_prefix` used. */
fn h264_enc_write_level_code(
  r : H264Rbsp,
  v : Int,
  suffix_length : Int,
) -> Int {
  if suffix_length == 0 {
    if v < 14 {
      h264_enc_write_level_prefix(r, v)
      return v
    }
    if v < 30 {
      h264_enc_write_level_prefix(r, 14)
      r.put(v - 14, 4)
      return 14
    }
  } else if suffix_length == 1 {
    if v < 28 {
      h264_enc_write_level_prefix(r, v >> 1)
      r.put(v & 1, 1)
      return v >> 1
    }
    if v < 30 {
      h264_enc_write_level_prefix(r, 14)
      r.put(v - 28, 1)
      return 14
    }
  } else {
    let limit = 15 << suffix_length
    if v < limit {
      let prefix = v >> suffix_length
      h264_enc_write_level_prefix(r, prefix)
      r.put(v & ((1 << suffix_length) - 1), suffix_length)
      return prefix
    }
    let over = v - limit
    if over < 4096 {
      h264_enc_write_level_prefix(r, 15)
      r.put(over, 12)
      return 15
    }
  }
  // Escape: prefix 15 carries a 12-bit suffix; prefixes >= 16 continue the
  // window chain (base(16) joins the prefix-15 window exactly).
  let base0 = if suffix_length >= 2 {
    15 << suffix_length
  } else {
    30
  }
  let over = v - base0
  if over < 4096 {
    h264_enc_write_level_prefix(r, 15)
    r.put(over, 12)
    return 15
  }
  let mut p = 16
  while p < 29 {
    let window = 1 << (p - 3)
    let base = base0 + window - 4096
    if v < base + window {
      break
    }
    p = p + 1
  }
  let window2 = 1 << (p - 3)
  let base = base0 + window2 - 4096
  h264_enc_write_level_prefix(r, p)
  r.put(v - base, p - 3)
  p
}

///|
/// `coeff_token` for `(total_coeff, trailing_ones)` under the nC class. */
fn h264_enc_write_coeff_token(
  r : H264Rbsp,
  max_coeff : Int,
  total : Int,
  trail : Int,
  nc : Int,
) -> Unit {
  let sym = total * 4 + trail
  let pair = if max_coeff == 4 {
    (
      h264_chroma_dc_coeff_token_len[sym],
      h264_chroma_dc_coeff_token_bits[sym],
    )
  } else {
    let t = h264_coeff_token_table_for_nc(nc & 31)
    (h264_coeff_token_len[t][sym], h264_coeff_token_bits[t][sym])
  }
  r.put(pair.1, pair.0)
}

///|
/// Write one coefficient block and return the non-zero count (the value
/// the decoder stores as `nz`). `levels[i]` is the level at zigzag index
/// `i` (storage position `scan[scan_start + i]`), `max_coeff` entries.
/// `nc` is the nC prediction used for the `coeff_token` table choice. */
fn h264_enc_write_residual(
  r : H264Rbsp,
  levels : Array[Int],
  max_coeff : Int,
  nc : Int,
) -> Int {
  // Scan-order statistics.
  let mut total = 0
  let mut last_idx = -1
  for i = 0; i < max_coeff; i = i + 1 {
    if levels[i] != 0 {
      total = total + 1
      last_idx = i
    }
  }
  if total == 0 {
    h264_enc_write_coeff_token(r, max_coeff, 0, 0, nc)
    return 0
  }
  // Trailing ones: up to three +1/-1 levels at the highest-frequency
  // end of the NON-ZERO sequence (gaps of zeros in between do not break
  // the run - the coefficient list has no zeros in it).
  // The level list the syntax codes: the non-zero levels highest frequency
  // first (scan positions with zeros in between are NOT part of it).
  let rev : Array[Int] = Array::make(total, 0)
  let mut ri = 0
  let mut p = last_idx
  while p >= 0 {
    if levels[p] != 0 {
      rev[ri] = levels[p]
      ri = ri + 1
    }
    p = p - 1
  }
  let mut trail = 0
  while trail < 3 && trail < total {
    let v = rev[trail]
    if v == 1 || v == -1 {
      trail = trail + 1
    } else {
      break
    }
  }
  h264_enc_write_coeff_token(r, max_coeff, total, trail, nc)
  // Trailing-one sign bits, highest frequency first.
  for k = 0; k < trail; k = k + 1 {
    r.put_bit(if rev[k] < 0 { 1 } else { 0 })
  }
  if trail < total {
    // First non-trailing level (highest frequency of the remainder).
    let first_v = rev[trail]
    let mag = if first_v < 0 { -first_v } else { first_v }
    let mut suffix_length = if total > 10 && trail < 3 { 1 } else { 0 }
    let code = 2 * (mag - 1) + (if first_v < 0 { 1 } else { 0 }) -
      (if trail < 3 { 2 } else { 0 })
    let prefix = h264_enc_write_level_code(r, code, suffix_length)
    // Decoder's post-first suffix_length update (uses the OLD value in
    // the condition and the fresh prefix inside).
    suffix_length = if prefix + 1 + suffix_length <= 8 {
      1 + (if mag > 3 { 1 } else { 0 })
    } else {
      2
    }
    // Remaining levels, still highest frequency first.
    for k = trail + 1; k < total; k = k + 1 {
      let v = rev[k]
      let mag2 = if v < 0 { -v } else { v }
      let c2 = 2 * (mag2 - 1) + (if v < 0 { 1 } else { 0 })
      ignore(h264_enc_write_level_code(r, c2, suffix_length))
      if mag2 > h264_suffix_limit[suffix_length] {
        suffix_length = suffix_length + 1
      }
    }
  }
  // total_zeros: zeros preceding the last non-zero coefficient.
  if total != max_coeff {
    let zeros_left = last_idx - (total - 1)
    if max_coeff == 4 {
      r.put(
        h264_chroma_dc_total_zeros_bits[total - 1][zeros_left],
        h264_chroma_dc_total_zeros_len[total - 1][zeros_left],
      )
    } else {
      r.put(
        h264_total_zeros_bits[total - 1][zeros_left],
        h264_total_zeros_len[total - 1][zeros_left],
      )
    }
    // run_before chain, from the second-highest coefficient downward.
    let mut zl = zeros_left
    let mut zeros_since = 0
    let mut i = last_idx - 1
    while i >= 0 && total > 1 {
      if levels[i] != 0 {
        if zl > 0 {
          let row = if zl < 7 { zl - 1 } else { 6 }
          r.put(
            h264_run_bits[row][zeros_since],
            h264_run_len[row][zeros_since],
          )
          zl = zl - zeros_since
        }
        zeros_since = 0
      } else {
        zeros_since = zeros_since + 1
      }
      i = i - 1
    }
  }
  total
}

///|
/// CAVLC residual conformance self-check (used by the blackbox tests): run
/// one write/decode round trip of `levels` (scan order, `max_coeff`
/// entries, `nc` class) through the encoder writer and the decoder's own
/// `h264_decode_residual`, and report whether every level and the total
/// come back identical.
pub fn h264_enc_residual_roundtrip(
  levels : Array[Int],
  max_coeff : Int,
  nc : Int,
) -> Result[Bool, String] {
  let r = H264Rbsp::new()
  let total = h264_enc_write_residual(r, levels, max_coeff, nc)
  r.trailing_bits()
  // RAW RBSP: the residual reader consumes unescaped bytes (finish() would
  // apply emulation prevention and corrupt any 00 00 0x run).
  let gb = BitReader::new(r.finish_raw_of())
  // 64 slots: the 4:2:0 chroma DC scan writes at offsets 0/16/32/48.
  let block : Array[Int] = Array::make(64, 0)
  let scan = if max_coeff == 4 {
    h264_chroma_dc_scan
  } else {
    h264_zigzag_scan
  }
  let scan_start = if max_coeff == 15 { 1 } else { 0 }
  let decoded = match
    h264_decode_residual(
      gb,
      block,
      0,
      scan,
      scan_start,
      None,
      max_coeff,
      nc,
      bit_depth=8,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if decoded != total {
    return Err("total wrote \{total} decoded \{decoded}")
  }
  let mut lv = ""
  let mut bv = ""
  for k = 0; k < max_coeff; k = k + 1 {
    lv = lv + " " + levels[k].to_string()
    bv = bv + " " + block[scan[scan_start + k]].to_string()
  }
  if lv != bv {
    return Err(
      "levels:\{lv} | decoded:\{bv} | max=\{max_coeff} nc=\{nc}",
    )
  }
  Ok(true)
}
