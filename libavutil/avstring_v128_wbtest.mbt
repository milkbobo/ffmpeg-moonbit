///|
/// Whitebox tests for the SIMD (`@v128`) `av_strnstr` (`avstring_v128.mbt`).
///
/// `av_strnstr_v128` must return exactly what the scalar authoritative port
/// `av_strnstr` returns (`tests/ref/fate/avstring` covers the related
/// `av_get_token` semantics). Checked exhaustively over generated ASCII
/// haystacks/needles and every `hay_length`, plus a few fixed cases.

///|
/// Deterministic ASCII string generator (LCG, alphabet `abc`). */
fn strv128_gen(seed : UInt32, n : Int32) -> String {
  let alphabet : Array[Char] = ['a', 'b', 'c']
  let chars : Array[Char] = []
  let mut s = seed
  for _i = 0; _i < n; _i = _i + 1 {
    s = s * 1103515245U + 12345U
    chars.push(alphabet[((s >> 16) % 3).reinterpret_as_int()])
  }
  String::from_array(chars[:])
}

///|
test "strnstr simd: fixed cases" {
  assert_eq(av_strnstr_v128("", "a", 0), av_strnstr("", "a", 0))
  assert_eq(av_strnstr_v128("abcabc", "", 6), Some(0))
  assert_eq(av_strnstr_v128("abcabc", "ca", 6), Some(2))
  assert_eq(av_strnstr_v128("abcabc", "ca", 3), None)
  assert_eq(av_strnstr_v128("abcabc", "abcabc", 6), Some(0))
  assert_eq(av_strnstr_v128("abcabc", "c", 100), Some(2))
  assert_eq(av_strnstr_v128("ab", "abc", 2), None)
}

///|
test "strnstr simd: equals the scalar path on generated inputs" {
  for t = 0; t < 120; t = t + 1 {
    let hl = t * 17 % 60
    let nl = 1 + t * 7 % 5
    let hay = strv128_gen(0xA5A5U + t.reinterpret_as_uint(), hl)
    let needle = strv128_gen(0x5A5AU + t.reinterpret_as_uint(), nl)
    for cut = 0; cut < hl + 3; cut = cut + 1 {
      assert_eq(av_strnstr_v128(hay, needle, cut), av_strnstr(hay, needle, cut))
    }
  }
  // long haystack crosses many SIMD blocks, needle hit and miss
  let big = strv128_gen(0x31337U, 500)
  assert_eq(av_strnstr_v128(big, "abc", 500), av_strnstr(big, "abc", 500))
  assert_eq(av_strnstr_v128(big, "zzz", 500), av_strnstr(big, "zzz", 500))
  // non-ASCII (but still BMP) must also agree
  let uni = "héllo wörld héllo"
  assert_eq(
    av_strnstr_v128(uni, "wörld", uni.length()),
    av_strnstr(uni, "wörld", uni.length()),
  )
  assert_eq(av_strnstr_v128(uni, "héllo", 6), av_strnstr(uni, "héllo", 6))
}
