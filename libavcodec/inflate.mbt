///|
/// Pure MoonBit zlib/DEFLATE decoder (RFC 1950/1951), used by the PNG slice.
///
/// FFmpeg delegates PNG decompression to zlib (`libavcodec/pngdec.c` via
/// `z_stream`); this port keeps the algorithm in-tree so the wasm build has no
/// external dependency. The decoding strategy follows Mark Adler's `puff`
/// reference: canonical Huffman tables decoded bit by bit, LZ77 with
/// overlapping copies, stored/fixed/dynamic blocks.
///
/// Out of scope: preset dictionaries (FDICT is rejected), inflate back-references
/// beyond 32 KiB, and streaming/incremental output (the caller supplies an
/// output cap and receives the whole buffer).

///|
priv struct InflateBits {
  data : Bytes
  mut bitpos : Int32
}

///|
fn ib_read(bits : InflateBits, n : Int32) -> Int32 {
  let mut v = 0
  for i in 0..<n {
    let p = bits.bitpos + i
    if p < bits.data.length() * 8 {
      let byte = bits.data[p / 8].to_int()
      v = v | (((byte >> (p % 8)) & 1) << i)
    }
  }
  bits.bitpos = bits.bitpos + n
  v
}

///|
fn ib_align(bits : InflateBits) -> Unit {
  bits.bitpos = (bits.bitpos + 7) / 8 * 8
}

///|
fn ib_byte(bits : InflateBits) -> Int32 {
  ib_align(bits)
  let p = bits.bitpos / 8
  let v = if p < bits.data.length() { bits.data[p].to_int() } else { 0 }
  bits.bitpos = bits.bitpos + 8
  v
}

///|
/// Canonical Huffman table in `puff` form: `count[len]` code counts and
/// `symbol[]` ordered by (length, code). */
priv struct InflateHuffman {
  count : Array[Int32]
  symbol : Array[Int32]
}

///|
fn inflate_huffman_build(
  lengths : Array[Int32],
) -> Result[InflateHuffman, String] {
  let count : Array[Int32] = []
  for _ in 0..<16 {
    count.push(0)
  }
  let mut max_len = 0
  for len in lengths {
    if len < 0 || len > 15 {
      return Err("inflate: bad code length")
    }
    count[len] = count[len] + 1
    if len > max_len {
      max_len = len
    }
  }
  if max_len == 0 {
    return Ok({ count, symbol: [], })
  }
  // Kraft check: over-subscribed trees are invalid.
  let mut left = 1
  for len in 1..<=15 {
    left = left * 2 - count[len]
    if left < 0 {
      return Err("inflate: over-subscribed Huffman tree")
    }
  }
  let offsets : Array[Int32] = []
  for _ in 0..<16 {
    offsets.push(0)
  }
  // puff: offs[1] = 0, offs[len+1] = offs[len] + count[len].
  for len in 1..<15 {
    offsets[len + 1] = offsets[len] + count[len]
  }
  let total = offsets[15] + count[15]
  let symbol : Array[Int32] = []
  for _ in 0..<total {
    symbol.push(0)
  }
  let next : Array[Int32] = []
  for len in 0..<16 {
    next.push(offsets[len])
  }
  for len in 0..<16 {
    next[len] = offsets[len]
  }
  for sym in 0..<lengths.length() {
    let len = lengths[sym]
    if len != 0 {
      symbol[next[len]] = sym
      next[len] = next[len] + 1
    }
  }
  Ok({ count, symbol, })
}

///|
fn inflate_decode_symbol(
  bits : InflateBits,
  h : InflateHuffman,
) -> Result[Int32, String] {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for len in 1..<=15 {
    code = code | ib_read(bits, 1)
    let count = h.count[len]
    if code - first < count {
      return Ok(h.symbol[index + (code - first)])
    }
    index = index + count
    first = (first + count) * 2
    code = code * 2
  }
  Err("inflate: invalid Huffman code")
}

///|
let inflate_length_base : FixedArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let inflate_length_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let inflate_dist_base : FixedArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let inflate_dist_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
fn inflate_fixed_trees() -> (InflateHuffman, InflateHuffman) {
  let lit_lengths : Array[Int32] = []
  for sym in 0..<288 {
    let len = if sym < 144 {
      8
    } else if sym < 256 {
      9
    } else if sym < 280 {
      7
    } else {
      8
    }
    lit_lengths.push(len)
  }
  let dist_lengths : Array[Int32] = []
  for _ in 0..<32 {
    dist_lengths.push(5)
  }
  // Fixed tables are valid by construction.
  let lit = inflate_huffman_build(lit_lengths).unwrap()
  let dist = inflate_huffman_build(dist_lengths).unwrap()
  (lit, dist)
}

///|
fn inflate_dynamic_trees(
  bits : InflateBits,
) -> Result[(InflateHuffman, InflateHuffman), String] {
  let hlit = ib_read(bits, 5) + 257
  let hdist = ib_read(bits, 5) + 1
  let hclen = ib_read(bits, 4) + 4
  let order : FixedArray[Int32] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  ]
  let cl_lengths : Array[Int32] = []
  for _ in 0..<19 {
    cl_lengths.push(0)
  }
  for i in 0..<hclen {
    cl_lengths[order[i]] = ib_read(bits, 3)
  }
  let cl_tree = match inflate_huffman_build(cl_lengths) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let total = hlit + hdist
  let lengths : Array[Int32] = []
  while lengths.length() < total {
    let sym = match inflate_decode_symbol(bits, cl_tree) {
      Ok(s) => s
      Err(e) => return Err(e)
    }
    if sym < 16 {
      lengths.push(sym)
    } else if sym == 16 {
      if lengths.length() == 0 {
        return Err("inflate: repeat with no previous length")
      }
      let prev = lengths[lengths.length() - 1]
      let rep = 3 + ib_read(bits, 2)
      for _ in 0..<rep {
        lengths.push(prev)
      }
    } else if sym == 17 {
      let rep = 3 + ib_read(bits, 3)
      for _ in 0..<rep {
        lengths.push(0)
      }
    } else if sym == 18 {
      let rep = 11 + ib_read(bits, 7)
      for _ in 0..<rep {
        lengths.push(0)
      }
    } else {
      return Err("inflate: bad code-length symbol")
    }
    if lengths.length() > total {
      return Err("inflate: code lengths overflow")
    }
  }
  let lit_lengths : Array[Int32] = []
  let dist_lengths : Array[Int32] = []
  for i in 0..<hlit {
    lit_lengths.push(lengths[i])
  }
  for i in 0..<hdist {
    dist_lengths.push(lengths[hlit + i])
  }
  let lit = match inflate_huffman_build(lit_lengths) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let dist = match inflate_huffman_build(dist_lengths) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  Ok((lit, dist))
}

///|
fn inflate_block(
  bits : InflateBits,
  out : Array[Byte],
  lit : InflateHuffman,
  dist : InflateHuffman,
  max_output : Int32,
) -> Result[Unit, String] {
  for ;; {
    let sym = match inflate_decode_symbol(bits, lit) {
      Ok(s) => s
      Err(e) => return Err(e)
    }
    if sym < 256 {
      if out.length() >= max_output {
        return Err("inflate: output limit exceeded")
      }
      out.push(sym.to_byte())
    } else if sym == 256 {
      return Ok(())
    } else {
      let li = sym - 257
      if li >= inflate_length_base.length() {
        return Err("inflate: bad length symbol")
      }
      let length = inflate_length_base[li] +
        ib_read(bits, inflate_length_extra[li])
      let dsym = match inflate_decode_symbol(bits, dist) {
        Ok(s) => s
        Err(e) => return Err(e)
      }
      if dsym >= inflate_dist_base.length() {
        return Err("inflate: bad distance symbol")
      }
      let distance = inflate_dist_base[dsym] +
        ib_read(bits, inflate_dist_extra[dsym])
      if distance > out.length() {
        return Err("inflate: distance too far back")
      }
      if out.length() + length > max_output {
        return Err("inflate: output limit exceeded")
      }
      for _ in 0..<length {
        out.push(out[out.length() - distance])
      }
    }
  }
}

///|
fn inflate_deflate(
  bits : InflateBits,
  max_output : Int32,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut last_block = false
  while !last_block {
    last_block = ib_read(bits, 1) == 1
    let btype = ib_read(bits, 2)
    if btype == 0 {
      let len = ib_byte(bits) | (ib_byte(bits) << 8)
      let nlen = ib_byte(bits) | (ib_byte(bits) << 8)
      if (len ^ 0xFFFF) != nlen {
        return Err("inflate: stored length mismatch")
      }
      if out.length() + len > max_output {
        return Err("inflate: output limit exceeded")
      }
      for _ in 0..<len {
        out.push(ib_byte(bits).to_byte())
      }
    } else if btype == 1 || btype == 2 {
      let (lit, dist) = if btype == 1 {
        inflate_fixed_trees()
      } else {
        match inflate_dynamic_trees(bits) {
          Ok(t) => t
          Err(e) => return Err(e)
        }
      }
      match inflate_block(bits, out, lit, dist, max_output) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else {
      return Err("inflate: reserved block type")
    }
  }
  Ok(out)
}

///|
/// `adler32` (RFC 1950). */
pub fn inflate_adler32(data : Bytes) -> UInt32 {
  let mut a = 1U
  let mut b = 0U
  for byte in data {
    a = (a + byte.to_uint()) % 65521U
    b = (b + a) % 65521U
  }
  (b << 16) | a
}

///|
/// Decompress a zlib stream. `max_output` bounds the inflated size.
pub fn inflate_zlib(data : Bytes, max_output : Int32) -> Result[Bytes, String] {
  if data.length() < 6 {
    return Err("zlib: stream too short")
  }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  if (cmf & 0x0F) != 8 {
    return Err("zlib: unsupported compression method")
  }
  if cmf >> 4 > 7 {
    return Err("zlib: invalid window size")
  }
  if ((cmf << 8) | flg) % 31 != 0 {
    return Err("zlib: header check failed")
  }
  if (flg & 0x20) != 0 {
    return Err("zlib: preset dictionary unsupported")
  }
  let bits : InflateBits = { data, bitpos: 16, }
  let out = match inflate_deflate(bits, max_output) {
    Ok(o) => o
    Err(e) => return Err(e)
  }
  ib_align(bits)
  let p = bits.bitpos / 8
  if p + 4 <= data.length() {
    let expected = (data[p].to_uint() << 24) |
      (data[p + 1].to_uint() << 16) |
      (data[p + 2].to_uint() << 8) |
      data[p + 3].to_uint()
    if inflate_adler32(Bytes::from_array(out[:])) != expected {
      return Err("zlib: adler32 mismatch")
    }
  }
  Ok(Bytes::from_array(out[:]))
}
