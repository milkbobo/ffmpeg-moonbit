///|
/// Whitebox tests for the `md5` and `sha` ports.
/// Reference digests come from `tests/ref/fate/md5`, `tests/ref/fate/sha` and
/// the FIPS 180 test vectors quoted in libavutil/tests/sha.c.

///|
/// Render the first `n` bytes of `bytes` as a lowercase hex string. */
fn hash_hex(bytes : FixedArray[Byte], n : Int32) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
/// tests/ref/fate/md5, produced by libavutil/tests/md5.c. */
test "av_md5 matches fate/md5 reference" {
  let buf : FixedArray[Byte] = FixedArray::make(1000, b'\x00')
  for i = 0; i < 1000; i = i + 1 {
    buf[i] = (i * i).reinterpret_as_uint().to_byte()
  }
  let dst : FixedArray[Byte] = FixedArray::make(16, b'\x00')

  av_md5_sum(dst, Bytes::from_array(buf[:]), 1000)
  assert_eq(hash_hex(dst, 16), "0bf1bcc8a1d72e2cf58d42182b637e56")
  av_md5_sum(dst, Bytes::from_array(buf[:]), 63)
  assert_eq(hash_hex(dst, 16), "993a3eb298e52aca83ecfbb6a766b4d0")
  av_md5_sum(dst, Bytes::from_array(buf[:]), 64)
  assert_eq(hash_hex(dst, 16), "07c01ca7c733475fad38c84c56f305c1")
  av_md5_sum(dst, Bytes::from_array(buf[:]), 65)
  assert_eq(hash_hex(dst, 16), "9fc8404827cac26385f48f4f58fd32ce")

  for i = 0; i < 1000; i = i + 1 {
    buf[i] = (i % 127).reinterpret_as_uint().to_byte()
  }
  av_md5_sum(dst, Bytes::from_array(buf[:]), 999)
  assert_eq(hash_hex(dst, 16), "a22bfef14302c5ca46e0ae91092bc0e0")
}

///|
/// RFC 1321 / well-known MD5 vectors, plus an incremental-vs-one-shot check. */
test "av_md5 known vectors" {
  let dst : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  av_md5_sum(dst, b"", 0)
  assert_eq(hash_hex(dst, 16), "d41d8cd98f00b204e9800998ecf8427e")
  av_md5_sum(dst, b"abc", 3)
  assert_eq(hash_hex(dst, 16), "900150983cd24fb0d6963f7d28e17f72")
  av_md5_sum(dst, b"message digest", 14)
  assert_eq(hash_hex(dst, 16), "f96b697d7cb7938d525a2f31aaf161d0")

  // Feeding the same bytes in 1-byte steps must match the one-shot digest.
  let ctx = av_md5_alloc()
  av_md5_init(ctx)
  av_md5_update(ctx, b"a", 1)
  av_md5_update(ctx, b"b", 1)
  av_md5_update(ctx, b"c", 1)
  av_md5_final(ctx, dst)
  assert_eq(hash_hex(dst, 16), "900150983cd24fb0d6963f7d28e17f72")
}

///|
/// tests/ref/fate/sha and FIPS 180 vectors (160/224/256 bits). */
test "av_sha matches FIPS 180 vectors" {
  let abc = b"abc"
  let two_block = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  let million_fill : FixedArray[Byte] = FixedArray::make(1000000, b'a')
  let million = Bytes::from_array(million_fill[:])
  let dst : FixedArray[Byte] = FixedArray::make(32, b'\x00')

  // SHA-1
  let _ = av_sha_sum(dst, abc, 3, 160).unwrap()
  assert_eq(hash_hex(dst, 20), "a9993e364706816aba3e25717850c26c9cd0d89d")
  let _ = av_sha_sum(dst, two_block, 56, 160).unwrap()
  assert_eq(hash_hex(dst, 20), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
  let _ = av_sha_sum(dst, million, 1000000, 160).unwrap()
  assert_eq(hash_hex(dst, 20), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")

  // SHA-224
  let _ = av_sha_sum(dst, abc, 3, 224).unwrap()
  assert_eq(
    hash_hex(dst, 28),
    "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7",
  )
  let _ = av_sha_sum(dst, two_block, 56, 224).unwrap()
  assert_eq(
    hash_hex(dst, 28),
    "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525",
  )
  let _ = av_sha_sum(dst, million, 1000000, 224).unwrap()
  assert_eq(
    hash_hex(dst, 28),
    "20794655980c91d8bbb4c1ea97618a4bf03f42581948b2ee4ee7ad67",
  )

  // SHA-256
  let _ = av_sha_sum(dst, abc, 3, 256).unwrap()
  assert_eq(
    hash_hex(dst, 32),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  let _ = av_sha_sum(dst, two_block, 56, 256).unwrap()
  assert_eq(
    hash_hex(dst, 32),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  let _ = av_sha_sum(dst, million, 1000000, 256).unwrap()
  assert_eq(
    hash_hex(dst, 32),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

///|
/// `av_sha_init` must reject digest sizes other than 160/224/256. */
test "av_sha_init rejects unsupported sizes" {
  let ctx = av_sha_alloc()
  assert_true(av_sha_init(ctx, 128) is Err(_))
  assert_true(av_sha_init(ctx, 512) is Err(_))
  assert_true(av_sha_init(ctx, 256) is Ok(_))
}
