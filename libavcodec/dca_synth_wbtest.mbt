///|
/// VLC layer consistency: all 62 books (48 quantization + 5 bit-allocation +
/// 5 scale-factor + 4 transition-mode) must build into complete prefix
/// trees, and the source-order code assignment (`acc += 1 << (32 - len)`,
/// the `ff_vlc_init_from_lengths` rule) must round-trip through the bit
/// decoder. */
test "dca: vlc books are complete trees and round-trip" {
  let books : Array[DcaVlcBook] = []
  for i = 0; i < 48; i = i + 1 {
    books.push(dca_vlc_quant_index[i])
  }
  for i = 0; i < 5; i = i + 1 {
    books.push(dca_vlc_bit_allocation[i])
  }
  for i = 0; i < 5; i = i + 1 {
    books.push(dca_vlc_scale_factor[i])
  }
  for i = 0; i < 4; i = i + 1 {
    books.push(dca_vlc_transition_mode[i])
  }
  assert_eq(books.length(), 62)
  // Complete-tree invariant: every node has both child slots either empty
  // or set.
  for book in books {
    let n = book.nodes.length() / 2
    for i = 0; i < n; i = i + 1 {
      let l = book.nodes[i + i]
      let r = book.nodes[i + i + 1]
      assert_eq(l == -1, r == -1)
    }
  }
  // Round-trip the first, middle and last entry of every quantization book
  // plus all auxiliary books.
  let gsize = dca_quant_index_group_size
  let sizes = dca_bitalloc_sizes
  let offsets = dca_bitalloc_offsets
  let mut book = 0
  let mut src = 0
  for i = 0; i < 10; i = i + 1 {
    for _j = 0; _j < gsize[i]; _j = _j + 1 {
      dca_vlc_roundtrip_check(books[book], src, sizes[i], offsets[i])
      book += 1
      src += sizes[i]
    }
  }
  dca_vlc_roundtrip_check(books[48], dca_vlc_segment_offset(48), 12, 1)
  dca_vlc_roundtrip_check(books[53], dca_vlc_segment_offset(53), 129, -64)
  dca_vlc_roundtrip_check(books[58], dca_vlc_segment_offset(58), 4, 0)
}

///|
/// Pack the codes of the first, middle and last entries of one segment and
/// decode them back. */
fn dca_vlc_roundtrip_check(
  book : DcaVlcBook,
  src : Int32,
  n : Int32,
  offset : Int32,
) -> Unit raise {
  // Re-derive the codes exactly like ff_vlc_init_from_lengths: in source
  // order, acc is the left-aligned code of the current entry.
  let picks : Array[(Int32, Int32, Int32)] = [] // (code, len, value)
  let mut acc = 0
  for i = 0; i < n; i = i + 1 {
    let len = dca_vlc_src_tables[(src + i) * 2 + 1]
    if i == 0 || i == n / 2 || i == n - 1 {
      picks.push((acc, len, dca_vlc_src_tables[(src + i) * 2] + offset))
    }
    acc = acc + (1 << (32 - len))
  }
  // Pack the picked codes MSB-first.
  let nbits = {
    let mut t = 0
    for (_, len, _) in picks {
      t += len
    }
    t
  }
  let buf = Array::make((nbits + 7) / 8, (0).to_byte())
  let mut k = 0
  for (code, len, _) in picks {
    // The code is left-aligned in 32 bits; emit its top `len` bits.
    let mut sh = 31
    let stop = 32 - len
    while sh >= stop {
      if ((code >> sh) & 1) != 0 {
        buf[k / 8] = (buf[k / 8].to_int() | (1 << (7 - k % 8))).to_byte()
      }
      k += 1
      sh = sh - 1
    }
  }
  let gb = BitReader::new(Bytes::from_array(buf))
  for (_, _, want) in picks {
    assert_eq(book.decode(gb), want)
  }
}
