///|
/// Whitebox tests for the `libavcodec` Huffman slice (`huffman.mbt`).
///
/// `libavcodec/tests/mjpegenc_huffman.c` (FATE `fate-libavcodec-huffman`)
/// exercises a *different* Huffman routine (the JPEG length limiter), and
/// `tests/ref/fate/` contains no numeric vector for `huffman.c` itself: its
/// FATE entry only runs an encoder. Verification therefore uses properties that
/// pin down an optimal Huffman code unambiguously, plus a hand-derived textbook
/// example:
///   * Kraft equality: `sum 2^-len == 1` (a complete, prefix-free code),
///   * optimality: the weighted path length equals the cost produced by an
///     independent textbook two-queue Huffman implementation (a second,
///     different algorithm over the same frequencies),
///   * agreement between FFmpeg's own two independent builders
///     (`ff_huff_build_tree` and `ff_huff_gen_len_table`),
///   * encode -> decode round-trip through the canonical codes.

// ---------------------------------------------------------------------------
// Independent reference: textbook two-queue Huffman (not from FFmpeg)
// ---------------------------------------------------------------------------

///| Stable sort of a copy of `a` (insertion sort, avoids core API surface). */
fn sorted_copy(a : Array[Int]) -> Array[Int] {
  let r : Array[Int] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    r[i] = a[i]
  }
  for i = 1; i < r.length(); i = i + 1 {
    let key = r[i]
    let mut j = i - 1
    while j >= 0 && r[j] > key {
      r[j + 1] = r[j]
      j = j - 1
    }
    r[j + 1] = key
  }
  r
}

///| Take the smallest remaining node from the leaf / internal queues. */
fn pick_min(
  leaves : Array[Int64],
  internal : Array[Int64],
  i1 : Array[Int],
  i2 : Array[Int],
) -> Int64 {
  let l = if i1[0] < leaves.length() {
    leaves[i1[0]]
  } else {
    0x7FFFFFFFFFFFFFFF
  }
  let r = if i2[0] < internal.length() {
    internal[i2[0]]
  } else {
    0x7FFFFFFFFFFFFFFF
  }
  if l <= r {
    i1[0] = i1[0] + 1
    l
  } else {
    i2[0] = i2[0] + 1
    r
  }
}

///| Optimal Huffman cost of the strictly positive frequencies in `counts`. */
fn optimal_cost(counts : Array[Int]) -> Int64 {
  let leaves : Array[Int64] = []
  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] > 0 {
      leaves.push(counts[i].to_int64())
    }
  }
  for i = 1; i < leaves.length(); i = i + 1 {
    let key = leaves[i]
    let mut j = i - 1
    while j >= 0 && leaves[j] > key {
      leaves[j + 1] = leaves[j]
      j = j - 1
    }
    leaves[j + 1] = key
  }
  let nl = leaves.length()
  if nl < 2 {
    return 0
  }
  let internal : Array[Int64] = []
  let i1 : Array[Int] = [0]
  let i2 : Array[Int] = [0]
  let mut total : Int64 = 0
  let mut nodes = nl
  while nodes > 1 {
    let a = pick_min(leaves, internal, i1, i2)
    let b = pick_min(leaves, internal, i1, i2)
    let s = a + b
    total = total + s
    internal.push(s)
    nodes = nodes - 1
  }
  total
}

///| Weighted path length of a `(lens, xlat)` code over `counts`. */
fn code_cost(lens : Array[Int], xlat : Array[Int], counts : Array[Int]) -> Int64 {
  let mut total : Int64 = 0
  for i = 0; i < lens.length(); i = i + 1 {
    total = total + counts[xlat[i]].to_int64() * lens[i].to_int64()
  }
  total
}

///| Kraft equality: the code lengths form a complete prefix-free set. */
fn kraft_ok(lens : Array[Int]) -> Bool {
  let mut lmax = 0
  for i = 0; i < lens.length(); i = i + 1 {
    if lens[i] > lmax {
      lmax = lens[i]
    }
  }
  if lmax <= 0 || lmax >= 30 {
    return false
  }
  let mut sum = 0
  for i = 0; i < lens.length(); i = i + 1 {
    sum = sum + (1 << (lmax - lens[i]))
  }
  sum == (1 << lmax)
}

///| `Array[Int]` -> `Array[UInt64]` for the `ff_huff_gen_len_table` signature. */
fn to_u64(counts : Array[Int]) -> Array[UInt64] {
  let r : Array[UInt64] = []
  for i = 0; i < counts.length(); i = i + 1 {
    r.push(counts[i].to_int64().reinterpret_as_uint64())
  }
  r
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "huffman: ff_huff_build_tree gives an optimal, prefix-free, round-trippable code" {
  let counts : Array[Int] = [
    3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3,
  ]
  match ff_huff_build_tree(counts, 0) {
    Ok(pair) => {
      let (lens, xlat) = pair
      assert_eq(lens.length(), 16)
      assert_true(kraft_ok(lens))
      assert_eq(code_cost(lens, xlat, counts), optimal_cost(counts))
      let hc = huffman_build_codes(lens, xlat)
      let syms : Array[Int] = []
      for _r = 0; _r < 5; _r = _r + 1 {
        for i = 0; i < xlat.length(); i = i + 1 {
          syms.push(xlat[i])
        }
      }
      let enc = hc.encode(syms)
      let dec = hc.decode(enc, syms.length())
      assert_eq(dec, syms)
    }
    Err(_) => assert_true(false)
  }
}

test "huffman: hand-derived textbook example (counts 1,1,2,4)" {
  let counts : Array[Int] = [1, 1, 2, 4]
  match ff_huff_build_tree(counts, 0) {
    Ok(pair) => {
      let (lens, xlat) = pair
      // The only optimal Huffman code has lengths {1, 2, 3, 3}.
      assert_eq(sorted_copy(lens), [1, 2, 3, 3])
      let hc = huffman_build_codes(lens, xlat)
      let syms : Array[Int] = [0, 1, 2, 3, 3, 2, 1, 0]
      let enc = hc.encode(syms)
      let dec = hc.decode(enc, 8)
      assert_eq(dec, syms)
    }
    Err(_) => assert_true(false)
  }
}

test "huffman: ff_huff_gen_len_table is optimal and agrees with build_tree" {
  let counts : Array[Int] = [
    12, 5, 40, 3, 3, 7, 2, 1, 21, 13, 8, 4, 1, 1, 2, 9,
  ]
  let stats = to_u64(counts)
  let lens = ff_huff_gen_len_table(stats, false)
  assert_true(kraft_ok(lens))
  let mut total : Int64 = 0
  for i = 0; i < counts.length(); i = i + 1 {
    total = total + stats[i].reinterpret_as_int64() * lens[i].to_int64()
  }
  assert_eq(total, optimal_cost(counts))
  match ff_huff_build_tree(counts, 0) {
    Ok(pair) => {
      let (bl, bx) = pair
      assert_eq(code_cost(bl, bx, counts), total)
    }
    Err(_) => assert_true(false)
  }
}

test "huffman: ff_huff_gen_len_table skips zero frequencies (skip0)" {
  let counts : Array[Int] = [7, 0, 0, 3, 3, 0, 1, 1]
  let lens = ff_huff_gen_len_table(to_u64(counts), true)
  assert_eq(lens[1], 255)
  assert_eq(lens[2], 255)
  assert_eq(lens[5], 255)
  let part : Array[Int] = [lens[0], lens[3], lens[4], lens[6], lens[7]]
  assert_true(kraft_ok(part))
}

test "huffman: ff_huff_build_tree rejects too high frequencies" {
  let counts : Array[Int] = [0x40000000, 0x40000000]
  assert_true(ff_huff_build_tree(counts, 0) is Err(_))
}
