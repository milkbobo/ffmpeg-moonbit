///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/huffman.c` and `libavcodec/huffman.h`:
/// the Huffman tree builder (`ff_huff_build_tree`) and the heap-based code
/// length generator (`ff_huff_gen_len_table`), plus the bit-level canonical
/// Huffman code assignment / encode / decode that the C code hands to the VLC
/// subsystem (`ff_vlc_init_from_lengths` in `libavcodec/vlc.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2006 Konstantin
/// Shishkov, Copyright (c) 2007 Loren Merritt. This port keeps the same license.
///
/// Implementation notes / deviations:
///   * `ff_huff_build_tree` returns the `(lens, xlat)` data that
///     `ff_vlc_init_from_lengths` would consume, instead of building a `VLC`
///     table (the whole VLC subsystem is out of scope here, see README).
///   * The `AV_QSORT(nodes, nb_codes, Node, cmp)` step is reproduced with a
///     stable ascending-by-count sort. FFmpeg's `AV_QSORT` is not stable, so for
///     equal `count` values the leaf order can differ from FFmpeg's; the
///     resulting code is still an optimal Huffman code (verified in the tests).
///   * `nb_bits` (only used to size the VLC table) is dropped.
///   * `get_tree_codes` emits leaves in DFS order, exactly like the C code; the
///     canonical codes below are assigned in `(length, emission index)` order,
///     which coincides with FFmpeg's top-aligned accumulation whenever the DFS
///     emission lengths are non-decreasing (the case `ff_vlc_init_from_lengths`
///     accepts).

///|
/// `#define HNODE -1`. */
pub let hnode : Int32 = -1

///|
/// `FF_HUFFMAN_FLAG_HNODE_FIRST`. */
pub let ff_huffman_flag_hnode_first : Int32 = 0x01

///|
/// `FF_HUFFMAN_FLAG_ZERO_COUNT`. */
pub let ff_huffman_flag_zero_count : Int32 = 0x02

///|
/// `struct Node { int16_t sym; int16_t n0; uint32_t count; }`. */
pub struct HuffNode {
  sym : Int32
  n0 : Int32
  count : Int32
}

///|
/// Reproduce `AV_QSORT(nodes, nb_codes, Node, cmp)` for the ascending-by-count
/// comparator the `ff_huff_build_tree` callers use. Stable insertion sort.
fn huff_sort(nodes : Array[HuffNode], nb : Int32) -> Unit {
  for i = 1; i < nb; i = i + 1 {
    let key = nodes[i]
    let mut j = i - 1
    while j >= 0 && nodes[j].count > key.count {
      nodes[j + 1] = nodes[j]
      j = j - 1
    }
    nodes[j + 1] = key
  }
}

///|
/// `get_tree_codes`: DFS emitting leaf code lengths and symbols. */
fn get_tree_codes(
  nodes : Array[HuffNode],
  node : Int32,
  pl : Int32,
  lens : Array[Int32],
  xlat : Array[Int32],
  no_zero_count : Bool,
) -> Unit {
  let s = nodes[node].sym
  if s != hnode || (no_zero_count && nodes[node].count == 0) {
    lens.push(pl)
    xlat.push(s)
  } else {
    get_tree_codes(nodes, nodes[node].n0, pl + 1, lens, xlat, no_zero_count)
    get_tree_codes(nodes, nodes[node].n0 + 1, pl + 1, lens, xlat, no_zero_count)
  }
}

///|
/// `ff_huff_build_tree`: build an optimal Huffman code over `counts`.
/// Returns the `(lens, xlat)` pair (`lens[i]` bits, symbol `xlat[i]`) that
/// FFmpeg would feed into `ff_vlc_init_from_lengths`, or `Err` when the symbol
/// frequencies are too high (the C `sum >> 31` check).
pub fn ff_huff_build_tree(
  counts : Array[Int32],
  flags : Int32,
) -> Result[(Array[Int32], Array[Int32]), String] {
  let nb_codes = counts.length()
  let zero_count = (flags & ff_huffman_flag_zero_count) != 0
  let hnode_first = (flags & ff_huffman_flag_hnode_first) != 0
  let nodes : Array[HuffNode] = Array::make(nb_codes * 2, {
    sym: 0,
    n0: -2,
    count: 0,
  })
  let mut sum : Int64 = 0
  for i = 0; i < nb_codes; i = i + 1 {
    nodes[i] = { sym: i, n0: -2, count: counts[i], }
    sum = sum + counts[i].to_int64()
  }
  if sum >> 31 != 0 {
    return Err("Too high symbol frequencies. Tree construction is not possible")
  }
  huff_sort(nodes, nb_codes)
  let mut cur_node = nb_codes
  nodes[nb_codes * 2 - 1] = {
    sym: nodes[nb_codes * 2 - 1].sym,
    n0: nodes[nb_codes * 2 - 1].n0,
    count: 0,
  }
  let mut i = 0
  while i < nb_codes * 2 - 1 {
    let cur_count = nodes[i].count + nodes[i + 1].count
    let mut j = cur_node
    while j > i + 2 {
      let nc = nodes[j - 1].count
      if cur_count > nc || (cur_count == nc && !hnode_first) {
        break
      }
      nodes[j] = nodes[j - 1]
      j = j - 1
    }
    nodes[j] = { sym: hnode, n0: i, count: cur_count, }
    cur_node = cur_node + 1
    i = i + 2
  }
  let lens : Array[Int32] = []
  let xlat : Array[Int32] = []
  get_tree_codes(nodes, nb_codes * 2 - 2, 0, lens, xlat, !zero_count)
  Ok((lens, xlat))
}

// ---------------------------------------------------------------------------
// ff_huff_gen_len_table
// ---------------------------------------------------------------------------

///|
/// `struct HeapElem { uint64_t val; int name; }`. */
priv struct HeapElem {
  val : UInt64
  name : Int32
}

///|
/// `INT64_MAX` as an unsigned 64-bit value (the C saturated heap entry). */
let u64_max : UInt64 = 0xFFFFFFFFFFFFFFFF

///|
/// `heap_sift`: sift `h[root]` down inside a min-heap of `size` elements. */
fn heap_sift(h : Array[HeapElem], root : Int32, size : Int32) -> Unit {
  let mut root = root
  while root * 2 + 1 < size {
    let mut child = root * 2 + 1
    if child < size - 1 && h[child].val > h[child + 1].val {
      child = child + 1
    }
    if h[root].val > h[child].val {
      let t = h[root]
      h[root] = h[child]
      h[child] = t
      root = child
    } else {
      break
    }
  }
}

///|
/// `ff_huff_gen_len_table`: heap-based Huffman code length generator. `dst[i]`
/// receives the code length of symbol `i` (or 255 when skipped); `skip0` drops
/// zero-frequency symbols. Mirrors the C `offset <<= 1` retry loop that caps
/// the generated lengths below 32.
pub fn ff_huff_gen_len_table(
  stats : Array[UInt64],
  skip0 : Bool,
) -> Array[Int32] {
  let n = stats.length()
  let dst : Array[Int32] = Array::make(n, 255)
  let map : Array[Int32] = []
  for i = 0; i < n; i = i + 1 {
    if stats[i] != 0 || !skip0 {
      map.push(i)
    }
  }
  let size = map.length()
  if size == 0 {
    return dst
  }
  let up : Array[Int32] = Array::make(2 * size, 0)
  let len : Array[Int32] = Array::make(2 * size, 0)
  let h : Array[HeapElem] = Array::make(size, { val: 0, name: 0, })
  let mut offset : UInt64 = 1
  let mut done = false
  while !done {
    for i = 0; i < size; i = i + 1 {
      h[i] = { val: (stats[map[i]] << 14) + offset, name: i, }
    }
    let mut i2 = size / 2 - 1
    while i2 >= 0 {
      heap_sift(h, i2, size)
      i2 = i2 - 1
    }
    let mut next = size
    while next < size * 2 - 1 {
      let min1v = h[0].val
      up[h[0].name] = next
      h[0] = { val: u64_max, name: h[0].name, }
      heap_sift(h, 0, size)
      up[h[0].name] = next
      h[0] = { val: h[0].val + min1v, name: next, }
      heap_sift(h, 0, size)
      next = next + 1
    }
    len[2 * size - 2] = 0
    let mut i3 = 2 * size - 3
    while i3 >= size {
      len[i3] = len[up[i3]] + 1
      i3 = i3 - 1
    }
    let mut i4 = 0
    let mut overflow = false
    while i4 < size {
      dst[map[i4]] = len[up[i4]] + 1
      if dst[map[i4]] >= 32 {
        overflow = true
        break
      }
      i4 = i4 + 1
    }
    if !overflow {
      done = true
    } else {
      offset = offset << 1
    }
  }
  dst
}

// ---------------------------------------------------------------------------
// Canonical Huffman codes: encode / decode (the vlc + get_bits model)
// ---------------------------------------------------------------------------

///|
/// Canonical Huffman code table built from a `(lens, xlat)` pair. */
pub struct HuffmanCode {
  lens : Array[Int32]
  codes : Array[UInt32]
  xlat : Array[Int32]
}

///|
/// Assign canonical codes: entries are ordered by `(length, emission index)`,
/// and the code value is accumulated exactly like a canonical Huffman code
/// (equivalent to `ff_vlc_init_from_lengths`'s top-aligned accumulation).
pub fn huffman_build_codes(
  lens : Array[Int32],
  xlat : Array[Int32],
) -> HuffmanCode {
  let n = lens.length()
  let codes : Array[UInt32] = Array::make(n, 0)
  // order[0..n) = 0..n-1, then stable sort by length.
  let order : Array[Int32] = []
  for i = 0; i < n; i = i + 1 {
    order.push(i)
  }
  for i = 1; i < n; i = i + 1 {
    let key = order[i]
    let mut j = i - 1
    while j >= 0 && lens[order[j]] > lens[key] {
      order[j + 1] = order[j]
      j = j - 1
    }
    order[j + 1] = key
  }
  let mut code : UInt32 = 0
  let mut prev_len = 0
  for k = 0; k < n; k = k + 1 {
    let i = order[k]
    if k > 0 {
      code = (code + 1) << (lens[i] - prev_len)
    }
    prev_len = lens[i]
    codes[i] = code
  }
  { lens, codes, xlat, }
}

///|
/// Bit writer, MSB-first (the `put_bits` order used by FFmpeg's VLC). */
pub struct BitWriter {
  buf : Array[Byte]
  mut acc : UInt32
  mut nbits : Int32
}

///|
/// Create an empty MSB-first bit writer. */
pub fn BitWriter::new() -> BitWriter {
  { buf: [], acc: 0, nbits: 0, }
}

///|
/// Append one bit. */
pub fn BitWriter::put_bit(self : BitWriter, b : Int32) -> Unit {
  self.acc = (self.acc << 1) | (b & 1).reinterpret_as_uint()
  self.nbits = self.nbits + 1
  if self.nbits == 8 {
    self.buf.push((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.nbits = 0
  }
}

///|
/// Append the low `n` bits of `value`, most significant bit first. */
pub fn BitWriter::put(self : BitWriter, value : UInt32, n : Int32) -> Unit {
  for k = n - 1; k >= 0; k = k - 1 {
    self.put_bit(((value >> k) & 1).reinterpret_as_int())
  }
}

///|
/// Flush the partial byte and return the encoded bytes. */
pub fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.nbits > 0 {
    self.buf.push(((self.acc << (8 - self.nbits)) & 0xFF).to_byte())
  }
  Bytes::from_array(self.buf[:])
}

///|
/// `HuffmanCode::encode`: encode the given symbols into MSB-first bits. */
pub fn HuffmanCode::encode(self : HuffmanCode, symbols : Array[Int32]) -> Bytes {
  let bw = BitWriter::new()
  for s = 0; s < symbols.length(); s = s + 1 {
    let sym = symbols[s]
    let mut entry = -1
    for i = 0; i < self.xlat.length(); i = i + 1 {
      if entry < 0 && self.xlat[i] == sym {
        entry = i
      }
    }
    if entry >= 0 {
      bw.put(self.codes[entry], self.lens[entry])
    }
  }
  bw.finish()
}

///|
/// `HuffmanCode::decode`: decode exactly `nsym` symbols from `data`
/// (MSB-first, matching `encode`).
pub fn HuffmanCode::decode(
  self : HuffmanCode,
  data : Bytes,
  nsym : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut pos = 0
  let mut acc : UInt32 = 0
  let mut nbits = 0
  let mut cur : UInt32 = 0
  let mut depth = 0
  while out.length() < nsym {
    if nbits == 0 {
      acc = data[pos].to_uint()
      pos = pos + 1
      nbits = 8
    }
    nbits = nbits - 1
    cur = (cur << 1) | ((acc >> nbits) & 1)
    depth = depth + 1
    let mut found = false
    for i = 0; i < self.lens.length(); i = i + 1 {
      if !found && self.lens[i] == depth && self.codes[i] == cur {
        out.push(self.xlat[i])
        found = true
      }
    }
    if found {
      cur = 0
      depth = 0
    }
  }
  out
}
