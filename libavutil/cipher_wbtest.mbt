///|
/// Whitebox tests for the `rc4`, `aes`, `xtea`, `blowfish`, `tea`, `cast5` and
/// `aes_ctr` ports.
///
/// Sources of truth, all independent of FFmpeg's own implementation:
///   * RC4: the RFC 6229 keystream vectors transcribed into
///     `libavutil/tests/rc4.c`.
///   * AES: the FIPS-197 Appendix C.1/C.2/C.3 ECB vectors, and the
///     NIST SP 800-38A F.2.1 CBC-AES128 example.
///   * XTEA: the six key/plaintext/ciphertext triples embedded in
///     `libavutil/tests/xtea.c` (the FATE test `tests/ref/fate/xtea` only
///     prints a success line).
///   * TEA: the four key/plaintext/ciphertext triples embedded in
///     `libavutil/tests/tea.c` (its FATE test likewise only prints a line).
///   * Blowfish: the 34 variable-key ECB triples and the string ECB/CBC
///     vectors embedded in `libavutil/tests/blowfish.c` (likewise the FATE
///     test only prints a success line).
///   * AES-CTR: the fixed-key/IV 40-byte vector from
///     `libavutil/tests/aes_ctr.c`.
///   * CAST5: the RFC 2144 test vectors embedded in
///     `libavutil/tests/cast5.c` (128/80/40-bit keys).

// ---------------------------------------------------------------------------
// RC4
// ---------------------------------------------------------------------------

///| key / key_bits / expected first 8 keystream bytes, from libavutil/tests/rc4.c. */
let rc4_vectors : Array[(Bytes, Int, Bytes)] = [
  (b"\x01\x02\x03\x04\x05", 40, b"\xb2\x39\x63\x05\xf0\x3d\xc0\x27"),
  (b"\x01\x02\x03\x04\x05\x06\x07", 56, b"\x29\x3f\x02\xd4\x7f\x37\xc9\xb6"),
  (b"\x01\x02\x03\x04\x05\x06\x07\x08", 64, b"\x97\xab\x8a\x1b\xf0\xaf\xb9\x61"),
  (
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10",
    128,
    b"\x9a\xc7\xcc\x9a\x60\x9d\x1e\xf7",
  ),
]

test "rc4: keystream matches the RFC 6229 vectors" {
  for i = 0; i < rc4_vectors.length(); i = i + 1 {
    let (key, bits, expected) = rc4_vectors[i]
    let ctx = av_rc4_alloc()
    let _ = av_rc4_init(ctx, key, bits).unwrap()
    // src == None reads the raw keystream, exactly like the C src == NULL case.
    assert_eq(av_rc4_crypt(ctx, None, 8), expected)
  }
}

test "rc4: encrypt/decrypt round-trips" {
  let ctx = av_rc4_alloc()
  let key = b"\x01\x02\x03\x04\x05"
  let plaintext = b"TestData"
  let _ = av_rc4_init(ctx, key, 40).unwrap()
  let encrypted = av_rc4_crypt(ctx, Some(plaintext), 8)
  // RC4 is symmetric, so re-initialising and crypting again decrypts.
  let _ = av_rc4_init(ctx, key, 40).unwrap()
  assert_eq(av_rc4_crypt(ctx, Some(encrypted), 8), plaintext)
  // The ciphertext must actually differ from the plaintext.
  assert_true(!(encrypted == plaintext))
}

test "rc4: in-place style round-trip with a 64-bit key" {
  let ctx = av_rc4_alloc()
  let key = b"\xFE\xDC\xBA\x98\x76\x54\x32\x10"
  let plaintext = b"InPlace!"
  let _ = av_rc4_init(ctx, key, 64).unwrap()
  let enc = av_rc4_crypt(ctx, Some(plaintext), 8)
  let _ = av_rc4_init(ctx, key, 64).unwrap()
  assert_eq(av_rc4_crypt(ctx, Some(enc), 8), plaintext)
}

test "rc4: key size must be a whole number of bytes" {
  let ctx = av_rc4_alloc()
  assert_true(av_rc4_init(ctx, b"\x01", 7) is Err(_))
  assert_true(av_rc4_init(ctx, b"\x01", 8) is Ok(_))
}

// ---------------------------------------------------------------------------
// AES
// ---------------------------------------------------------------------------

fn aes_hex(s : String) -> Bytes {
  // Decode a hex string into bytes; handy for transcribing the published vectors.
  let digits : Bytes = b"0123456789abcdef"
  let out : Array[Byte] = []
  let a = s.to_array()
  let mut i = 0
  while i + 1 < a.length() {
    let hi = find_hex(digits, a[i])
    let lo = find_hex(digits, a[i + 1])
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out[:])
}

fn find_hex(digits : Bytes, c : Char) -> Int {
  let mut i = 0
  while i < digits.length() {
    if digits[i].to_char() == c {
      return i
    }
    i = i + 1
  }
  0
}

///| The plaintext used by all three FIPS-197 Appendix C vectors. */
let fips_plain : String = "00112233445566778899aabbccddeeff"

///|
/// FIPS-197 C.1 / C.2 / C.3: key (hex) and the resulting ciphertext (hex).
let fips_ecb_vectors : Array[(String, String)] = [
  ("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
  ("000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"),
  (
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    "8ea2b7ca516745bfeafc49904b496089",
  ),
]

test "aes: FIPS-197 ECB vectors, all three key sizes" {
  let plaintext = aes_hex(fips_plain)
  for i = 0; i < fips_ecb_vectors.length(); i = i + 1 {
    let (key_hex, ct_hex) = fips_ecb_vectors[i]
    let key = aes_hex(key_hex)
    let bits = key.length() * 8
    let enc = av_aes_alloc()
    let _ = av_aes_init(enc, key, bits, false).unwrap()
    let ciphertext = av_aes_crypt(enc, plaintext, 1, None)
    assert_eq(ciphertext, aes_hex(ct_hex))

    // Decrypting with a decrypt context must return the plaintext.
    let dec = av_aes_alloc()
    let _ = av_aes_init(dec, key, bits, true).unwrap()
    assert_eq(av_aes_crypt(dec, ciphertext, 1, None), plaintext)
  }
}

test "aes: key size must be 128, 192 or 256 bits" {
  let a = av_aes_alloc()
  assert_true(av_aes_init(a, b"\x00\x01", 16, false) is Err(_))
  assert_true(av_aes_init(a, b"\x00", 8, false) is Err(_))
}

///| Spot-check the S-box values generated by the ported aes_init_static logic. */
test "aes: generated S-box matches the published table" {
  let a = av_aes_alloc()
  let _ = av_aes_init(a, aes_hex("000102030405060708090a0b0c0d0e0f"), 128, false).unwrap()
  assert_eq(a.sbox[0], b'\x63')
  assert_eq(a.sbox[1], b'\x7c')
  assert_eq(a.sbox[0x10], b'\xca')
  assert_eq(a.sbox[0x53], b'\xed')
  assert_eq(a.sbox[0xff], b'\x16')
  // The inverse table is the exact inverse mapping.
  for i = 0; i < 256; i = i + 1 {
    assert_eq(a.inv_sbox[a.sbox[i].to_int()], i.to_byte())
  }
}

///|
/// NIST SP 800-38A F.2.1: CBC-AES128 with a two-block plaintext, including the
/// chaining value that must remain in the caller's IV buffer.
test "aes: SP 800-38A CBC-AES128 encrypt and decrypt" {
  let key = aes_hex("2b7e151628aed2a6abf7158809cf4f3c")
  let iv : FixedArray[Byte] = aes_hex("000102030405060708090a0b0c0d0e0f").to_fixedarray()
  let plaintext = aes_hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
  let expected = aes_hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2")

  let enc = av_aes_alloc()
  let _ = av_aes_init(enc, key, 128, false).unwrap()
  let ciphertext = av_aes_crypt(enc, plaintext, 2, Some(iv))
  assert_eq(ciphertext, expected)
  // The IV buffer ends up holding the last ciphertext block.
  assert_eq(
    Bytes::from_array(iv[:]),
    aes_hex("5086cb9b507219ee95db113a917678b2"),
  )

  let iv2 : FixedArray[Byte] = aes_hex("000102030405060708090a0b0c0d0e0f").to_fixedarray()
  let dec = av_aes_alloc()
  let _ = av_aes_init(dec, key, 128, true).unwrap()
  assert_eq(av_aes_crypt(dec, expected, 2, Some(iv2)), plaintext)
}

// ---------------------------------------------------------------------------
// XTEA
// ---------------------------------------------------------------------------

///| The six key/plaintext/ciphertext triples from libavutil/tests/xtea.c. */
let xtea_test_key : Array[Bytes] = [
  aes_hex("000102030405060708090a0b0c0d0e0f"),
  aes_hex("000102030405060708090a0b0c0d0e0f"),
  aes_hex("000102030405060708090a0b0c0d0e0f"),
  aes_hex("00000000000000000000000000000000"),
  aes_hex("00000000000000000000000000000000"),
  aes_hex("00000000000000000000000000000000"),
]

let xtea_test_pt : Array[Bytes] = [
  aes_hex("4142434445464748"),
  aes_hex("4141414141414141"),
  aes_hex("5a5b6e278948d77f"),
  aes_hex("4142434445464748"),
  aes_hex("4141414141414141"),
  aes_hex("70e1225d6e4e7655"),
]

let xtea_test_ct : Array[Bytes] = [
  aes_hex("497df3d072612cb5"),
  aes_hex("e78f2d13744341d8"),
  aes_hex("4141414141414141"),
  aes_hex("a0390589f8b8efa5"),
  aes_hex("ed23375a821a8c2d"),
  aes_hex("4141414141414141"),
]

///|
/// Reverse the four bytes of every aligned 32-bit group, reproducing the
/// `AV_WL32(&x, AV_RB32(&y))` byte-swapping the C test applies to derive its
/// little-endian cases.
fn xtea_swap32_words(b : Bytes) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(b.length(), b'\x00')
  let mut i = 0
  while i + 3 < b.length() {
    out[i] = b[i + 3]
    out[i + 1] = b[i + 2]
    out[i + 2] = b[i + 1]
    out[i + 3] = b[i]
    i = i + 4
  }
  Bytes::from_array(out[:])
}

test "xtea: big-endian ECB vectors from libavutil/tests/xtea.c" {
  for i = 0; i < 6; i = i + 1 {
    let ctx = av_xtea_alloc()
    av_xtea_init(ctx, xtea_test_key[i])
    assert_eq(av_xtea_crypt(ctx, xtea_test_pt[i], 1, None, false), xtea_test_ct[i])
    assert_eq(av_xtea_crypt(ctx, xtea_test_ct[i], 1, None, true), xtea_test_pt[i])
  }
}

test "xtea: little-endian ECB vectors from libavutil/tests/xtea.c" {
  for i = 0; i < 6; i = i + 1 {
    let ctx = av_xtea_alloc()
    av_xtea_le_init(ctx, xtea_swap32_words(xtea_test_key[i]))
    assert_eq(
      av_xtea_le_crypt(ctx, xtea_swap32_words(xtea_test_pt[i]), 1, None, false),
      xtea_swap32_words(xtea_test_ct[i]),
    )
    assert_eq(
      av_xtea_le_crypt(ctx, xtea_swap32_words(xtea_test_ct[i]), 1, None, true),
      xtea_swap32_words(xtea_test_pt[i]),
    )
  }
}

///|
/// CBC round-trip mirroring the tail of libavutil/tests/xtea.c: 32 bytes of
/// `"HelloWorldHelloWorldHelloWorld"` with the `"HALLO123"` IV, encrypted then
/// decrypted, using the all-zero key of test case 5.
test "xtea: CBC round-trip with the HALLO123 IV" {
  // The C test passes 4 blocks (32 bytes) for the 30-byte string plus its NUL
  // and one zero pad byte; the extra two bytes are zero.
  let src = b"HelloWorldHelloWorldHelloWorld\x00\x00"
  let ctx = av_xtea_alloc()
  av_xtea_init(ctx, xtea_test_key[5])

  let iv_enc : FixedArray[Byte] = b"HALLO123".to_fixedarray()
  let ct = av_xtea_crypt(ctx, src, 4, Some(iv_enc), false)
  // The IV buffer ends up holding the last ciphertext block.
  for i = 0; i < 8; i = i + 1 {
    assert_eq(iv_enc[i], ct[24 + i])
  }

  let iv_dec : FixedArray[Byte] = b"HALLO123".to_fixedarray()
  assert_eq(av_xtea_crypt(ctx, ct, 4, Some(iv_dec), true), src)
}

test "xtea: context key is loaded in the selected endianness" {
  let key = aes_hex("000102030405060708090a0b0c0d0e0f")
  let be = av_xtea_alloc()
  av_xtea_init(be, key)
  assert_eq(be.key[0], 0x00010203)
  assert_eq(be.key[1], 0x04050607)
  assert_eq(be.key[2], 0x08090A0B)
  assert_eq(be.key[3], 0x0C0D0E0F)
  let le = av_xtea_alloc()
  av_xtea_le_init(le, key)
  assert_eq(le.key[0], 0x03020100)
  assert_eq(le.key[1], 0x07060504)
  assert_eq(le.key[2], 0x0B0A0908)
  assert_eq(le.key[3], 0x0F0E0D0C)
}

// ---------------------------------------------------------------------------
// Blowfish
// ---------------------------------------------------------------------------

///| Variable-key ECB vectors from libavutil/tests/blowfish.c (34 cases). */
let bf_keys : Array[String] = [
  "0000000000000000", "ffffffffffffffff", "3000000000000000", "1111111111111111",
  "0123456789abcdef", "1111111111111111", "0000000000000000", "fedcba9876543210",
  "7ca110454a1a6e57", "0131d9619dc1376e", "07a1133e4a0b2686", "3849674c2602319e",
  "04b915ba43feb5b6", "0113b970fd34f2ce", "0170f175468fb5e6", "43297fad38e373fe",
  "07a7137045da2a16", "04689104c2fd3b2f", "37d06bb516cb7546", "1f08260d1ac2465e",
  "584023641aba6176", "025816164629b007", "49793ebc79b3258f", "4fb05e1515ab73a7",
  "49e95d6d4ca229bf", "018310dc409b26d6", "1c587f1c13924fef", "0101010101010101",
  "1f1f1f1f0e0e0e0e", "e0fee0fef1fef1fe", "0000000000000000", "ffffffffffffffff",
  "0123456789abcdef", "fedcba9876543210",
]

let bf_pt_l : Array[UInt] = [
  0x00000000, 0xFFFFFFFF, 0x10000000, 0x11111111, 0x11111111, 0x01234567, 0x00000000,
  0x01234567, 0x01A1D6D0, 0x5CD54CA8, 0x0248D438, 0x51454B58, 0x42FD4430, 0x059B5E08,
  0x0756D8E0, 0x762514B8, 0x3BDD1190, 0x26955F68, 0x164D5E40, 0x6B056E18, 0x004BD6EF,
  0x480D3900, 0x437540C8, 0x072D43A0, 0x02FE5577, 0x1D9D5C50, 0x30553228, 0x01234567,
  0x01234567, 0x01234567, 0xFFFFFFFF, 0x00000000, 0x00000000, 0xFFFFFFFF,
]

let bf_pt_r : Array[UInt] = [
  0x00000000, 0xFFFFFFFF, 0x00000001, 0x11111111, 0x11111111, 0x89ABCDEF, 0x00000000,
  0x89ABCDEF, 0x39776742, 0x3DEF57DA, 0x06F67172, 0x2DDF440A, 0x59577FA2, 0x51CF143A,
  0x774761D2, 0x29BF486A, 0x49372802, 0x35AF609A, 0x4F275232, 0x759F5CCA, 0x09176062,
  0x6EE762F2, 0x698F3CFA, 0x77075292, 0x8117F12A, 0x18F728C2, 0x6D6F295A, 0x89ABCDEF,
  0x89ABCDEF, 0x89ABCDEF, 0xFFFFFFFF, 0x00000000, 0x00000000, 0xFFFFFFFF,
]

let bf_ct_l : Array[UInt] = [
  0x4EF99745, 0x51866FD5, 0x7D856F9A, 0x2466DD87, 0x61F9C380, 0x7D0CC630, 0x4EF99745,
  0x0ACEAB0F, 0x59C68245, 0xB1B8CC0B, 0x1730E577, 0xA25E7856, 0x353882B1, 0x48F4D088,
  0x432193B7, 0x13F04154, 0x2EEDDA93, 0xD887E039, 0x5F99D04F, 0x4A057A3B, 0x452031C1,
  0x7555AE39, 0x53C55F9C, 0x7A8E7BFA, 0xCF9C5D7A, 0xD1ABB290, 0x55CB3774, 0xFA34EC48,
  0xA7907951, 0xC39E072D, 0x014933E0, 0xF21E9A77, 0x24594688, 0x6B5C5A9C,
]

let bf_ct_r : Array[UInt] = [
  0x6198DD78, 0xB85ECB8A, 0x613063F2, 0x8B963C9D, 0x2281B096, 0xAFDA1EC7, 0x6198DD78,
  0xC6A0A28D, 0xEB05282B, 0x250F09A0, 0x8BEA1DA4, 0xCF2651EB, 0x09CE8F1A, 0x4C379918,
  0x8951FC98, 0xD69D1AE5, 0xFFD39C79, 0x3C2DA6E3, 0x5B163969, 0x24D3977B, 0xE4FADA8E,
  0xF59B87BD, 0xB49FC019, 0x937E89A3, 0x4986ADB5, 0x658BC778, 0xD13EF201, 0x47B268B2,
  0x08EA3CAE, 0x9FAC631D, 0xCDAFF6E4, 0xB71C49BC, 0x5754369A, 0x5D9E0A5A,
]

///|
/// The 34 variable-key ECB triples: each 8-byte key with plaintext/ciphertext
/// given as 32-bit halves, matching `av_blowfish_crypt_ecb`'s in/out halves.
test "blowfish: 34 variable-key ECB vectors from libavutil/tests/blowfish.c" {
  for i = 0; i < 34; i = i + 1 {
    let ctx = av_blowfish_alloc()
    av_blowfish_init(ctx, aes_hex(bf_keys[i]), 8)
    let (l, r) = av_blowfish_crypt_ecb(ctx, bf_pt_l[i], bf_pt_r[i], false)
    assert_eq(l, bf_ct_l[i])
    assert_eq(r, bf_ct_r[i])
    let (l2, r2) = av_blowfish_crypt_ecb(ctx, l, r, true)
    assert_eq(l2, bf_pt_l[i])
    assert_eq(r2, bf_pt_r[i])
  }
}

///|
/// String vectors from libavutil/tests/blowfish.c, key `"abcdefghijklmnop..."`:
/// ECB of `"BLOWFISH"`, then CBC of `"BLOWFISHBLOWFISH"` with IV `"blowfish"`.
test "blowfish: string ECB/CBC vectors from libavutil/tests/blowfish.c" {
  let key = b"abcdefghijklmnopqrstuvwxyz"
  let ctx = av_blowfish_alloc()
  av_blowfish_init(ctx, key, 26)

  let ct = av_blowfish_crypt(ctx, b"BLOWFISH", 1, None, false)
  assert_eq(ct, aes_hex("324ed0fef413a203"))
  assert_eq(av_blowfish_crypt(ctx, ct, 1, None, true), b"BLOWFISH")

  let iv_enc = b"blowfish".to_fixedarray()
  let pt = b"BLOWFISHBLOWFISH"
  let ct2 = av_blowfish_crypt(ctx, pt, 2, Some(iv_enc), false)
  assert_eq(ct2, aes_hex("5300400663f21d993b9b276446fd20c1"))
  // The IV buffer ends up holding the last ciphertext block.
  for i = 0; i < 8; i = i + 1 {
    assert_eq(iv_enc[i], ct2[8 + i])
  }

  let iv_dec = b"blowfish".to_fixedarray()
  assert_eq(av_blowfish_crypt(ctx, ct2, 2, Some(iv_dec), true), pt)
}

// ---------------------------------------------------------------------------
// AES-CTR
// ---------------------------------------------------------------------------

///|
/// The fixed-key/IV 40-byte vector from libavutil/tests/aes_ctr.c (its `i == 1`
/// case), using `fixed_key` = "0123456789abcdef" and `fixed_iv` = deadbeefdeadbeef.
let aes_ctr_key : String = "30313233343536373839616263646566"

let aes_ctr_iv : String = "deadbeefdeadbeef"

let aes_ctr_plain : String = "6d6f73742072616e646f6d6f73742072616e646f6d6f73742072616e646f6d6f73742072616e646f"

let aes_ctr_expected : String = "95cd9a8a83a21a8492edd6f2572f6198bc2098ee6ced53ae2fc4187ceb62bb3a7124228cd9faee10"

test "aes-ctr: fixed-key 40-byte vector from libavutil/tests/aes_ctr.c" {
  let enc = av_aes_ctr_alloc()
  let _ = av_aes_ctr_init(enc, aes_hex(aes_ctr_key)).unwrap()
  av_aes_ctr_set_iv(enc, aes_hex(aes_ctr_iv))
  assert_eq(
    av_aes_ctr_crypt(enc, aes_hex(aes_ctr_plain), 40),
    aes_hex(aes_ctr_expected),
  )
  // Decrypting with a fresh context returns the plaintext (CTR is symmetric).
  let dec = av_aes_ctr_alloc()
  let _ = av_aes_ctr_init(dec, aes_hex(aes_ctr_key)).unwrap()
  av_aes_ctr_set_iv(dec, aes_hex(aes_ctr_iv))
  assert_eq(
    av_aes_ctr_crypt(dec, aes_hex(aes_ctr_expected), 40),
    aes_hex(aes_ctr_plain),
  )
}

///|
/// Consuming the stream in uneven chunks must yield the same keystream as one
/// call, exercising the `block_offset` / `encrypted_counter` carry-over path.
test "aes-ctr: split calls equal a single call" {
  let ctx = av_aes_ctr_alloc()
  let _ = av_aes_ctr_init(ctx, aes_hex(aes_ctr_key)).unwrap()
  av_aes_ctr_set_iv(ctx, aes_hex(aes_ctr_iv))
  let plain = aes_hex(aes_ctr_plain).to_array()
  let split : Array[Int] = [1, 7, 16, 3, 13]
  let acc : Array[Byte] = []
  let mut off = 0
  for i = 0; i < split.length(); i = i + 1 {
    let c = split[i]
    let out = av_aes_ctr_crypt(ctx, Bytes::from_array(plain[off:off + c]), c)
    for j = 0; j < c; j = j + 1 {
      acc.push(out[j])
    }
    off = off + c
  }
  assert_eq(Bytes::from_array(acc[:]), aes_hex(aes_ctr_expected))
}

test "aes-ctr: set_full_iv / increment_iv / get_iv" {
  let c = av_aes_ctr_alloc()
  let _ = av_aes_ctr_init(c, aes_hex(aes_ctr_key)).unwrap()
  let full = aes_hex("00112233445566778899aabbccddeeff")
  av_aes_ctr_set_full_iv(c, full)
  assert_eq(av_aes_ctr_get_iv(c), full)
  // increment_iv bumps the top 64 bits and zeroes the low 64.
  av_aes_ctr_increment_iv(c)
  assert_eq(av_aes_ctr_get_iv(c), aes_hex("00112233445566780000000000000000"))
  // set_iv only fills the first 8 bytes and zeroes the counter half.
  av_aes_ctr_set_iv(c, aes_hex("deadbeefdeadbeef"))
  assert_eq(av_aes_ctr_get_iv(c), aes_hex("deadbeefdeadbeef0000000000000000"))
}

// ---------------------------------------------------------------------------
// TEA
// ---------------------------------------------------------------------------

///| The four key/plaintext/ciphertext triples from libavutil/tests/tea.c. */
let tea_test_key : Array[Bytes] = [
  aes_hex("00000000000000000000000000000000"),
  aes_hex("00000000000000000000000000000000"),
  aes_hex("00112233445566778899aabbccddeeff"),
  aes_hex("00112233445566778899aabbccddeeff"),
]

let tea_test_pt : Array[Bytes] = [
  aes_hex("0000000000000000"),
  aes_hex("0102030405060708"),
  aes_hex("0102030405060708"),
  aes_hex("0123456789abcdef"),
]

let tea_test_ct : Array[Bytes] = [
  aes_hex("41ea3a0a94baa940"),
  aes_hex("6a2f9cf3fccf3c55"),
  aes_hex("deb1c0a27e745db3"),
  aes_hex("126c6b92c0653a3e"),
]

test "tea: ECB vectors from libavutil/tests/tea.c (64 rounds)" {
  for i = 0; i < 4; i = i + 1 {
    let ctx = av_tea_alloc()
    av_tea_init(ctx, tea_test_key[i], 64)
    assert_eq(av_tea_crypt(ctx, tea_test_pt[i], 1, None, false), tea_test_ct[i])
    assert_eq(av_tea_crypt(ctx, tea_test_ct[i], 1, None, true), tea_test_pt[i])
  }
}

///|
/// CBC round-trip mirroring libavutil/tests/tea.c: 32 bytes of
/// `"HelloWorldHelloWorldHelloWorld"` with the `"HALLO123"` IV.
test "tea: CBC round-trip with the HALLO123 IV" {
  let src = b"HelloWorldHelloWorldHelloWorld\x00\x00"
  let ctx = av_tea_alloc()
  av_tea_init(ctx, tea_test_key[3], 64)
  let iv_enc = b"HALLO123".to_fixedarray()
  let ct = av_tea_crypt(ctx, src, 4, Some(iv_enc), false)
  // The IV buffer ends up holding the last ciphertext block.
  for i = 0; i < 8; i = i + 1 {
    assert_eq(iv_enc[i], ct[24 + i])
  }
  let iv_dec = b"HALLO123".to_fixedarray()
  assert_eq(av_tea_crypt(ctx, ct, 4, Some(iv_dec), true), src)
}

// ---------------------------------------------------------------------------
// CAST5
// ---------------------------------------------------------------------------

///|
/// RFC 2144 test vectors from libavutil/tests/cast5.c: the same plaintext under
/// 128-, 80- and 40-bit keys. The test also carries a 1,000,000-iteration
/// chaining vector (`rct2`), skipped here because of its runtime.
let cast5_keys : Array[String] = [
  "0123456712345678234567893456789a",
  "01234567123456782345",
  "0123456712",
]

let cast5_key_bits : Array[Int] = [128, 80, 40]

let cast5_rpt : String = "0123456789abcdef"

let cast5_rct : Array[String] = [
  "238b4fe5847e44b2",
  "eb6a711a2c02271b",
  "7ac816d16e9b302e",
]

test "cast5: RFC 2144 ECB vectors from libavutil/tests/cast5.c" {
  for i = 0; i < 3; i = i + 1 {
    let cs = av_cast5_alloc()
    let _ = av_cast5_init(cs, aes_hex(cast5_keys[i]), cast5_key_bits[i]).unwrap()
    let pt = aes_hex(cast5_rpt)
    let ct = av_cast5_crypt(cs, pt, 1, false)
    assert_eq(ct, aes_hex(cast5_rct[i]))
    assert_eq(av_cast5_crypt(cs, ct, 1, true), pt)
  }
}

///| CBC round-trip through `av_cast5_crypt2`, mirroring the tail of the C test. */
test "cast5: CBC round-trip via av_cast5_crypt2" {
  let cs = av_cast5_alloc()
  let _ = av_cast5_init(cs, aes_hex(cast5_keys[0]), 128).unwrap()
  let pt = aes_hex("eea9d0a249fd3ba6b3436fb89d6dca92")
  let iv_enc = aes_hex("eea9d0a249fd3ba6").to_fixedarray()
  let ct = av_cast5_crypt2(cs, pt, 2, iv_enc, false)
  // The IV buffer ends up holding the last ciphertext block.
  for i = 0; i < 8; i = i + 1 {
    assert_eq(iv_enc[i], ct[8 + i])
  }
  let iv_dec = aes_hex("eea9d0a249fd3ba6").to_fixedarray()
  assert_eq(av_cast5_crypt2(cs, ct, 2, iv_dec, true), pt)
}

test "cast5: key size must be 40..128 and a whole number of bytes" {
  let cs = av_cast5_alloc()
  assert_true(av_cast5_init(cs, aes_hex("00"), 4) is Err(_))
  assert_true(av_cast5_init(cs, aes_hex("00"), 136) is Err(_))
  assert_true(av_cast5_init(cs, aes_hex("0000000000"), 40) is Ok(_))
  assert_true(av_cast5_init(cs, aes_hex("00000000000000000000000000000000"), 128) is Ok(_))
}
