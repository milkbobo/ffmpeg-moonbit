///|
/// Whitebox tests for the SIMD (`@v128`) four-way MD5 (`md5_v128.mbt`).
///
/// The SIMD path must agree with the scalar authoritative port (`av_md5_sum`)
/// on every lane, and with FFmpeg's own reference digests
/// (`tests/ref/fate/md5`, produced by libavutil/tests/md5.c) and the RFC 1321
/// vectors used in `hash_wbtest.mbt`. Because the four-way kernel hashes four
/// equal-length messages at once, each case is run with either four identical
/// fates (against the published digests) or four distinct generated buffers
/// (against the scalar port, lane by lane).

///|
/// Render the 16-byte digest of lane `l` (at `dst[16*l ..]`) as hex. */
fn md5x4_lane_hex(dst : FixedArray[Byte], l : Int32) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < 16; i = i + 1 {
    let v = dst[16 * l + i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
/// Four copies of `msg`, so a case can be checked against a known digest. */
fn md5x4_four(msg : Bytes) -> FixedArray[Bytes] {
  let srcs : FixedArray[Bytes] = FixedArray::make(4, b"")
  for l = 0; l < 4; l = l + 1 {
    srcs[l] = msg
  }
  srcs
}

///|
/// `tests/ref/fate/md5` reference digests, in all four lanes. The two buffer
/// phases and the lengths 63/64/65 exercise the block/tail/padding boundaries.
test "md5 x4 simd: fate/md5 reference digests in every lane" {
  let dst : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  let buf1 : FixedArray[Byte] = FixedArray::make(1000, b'\x00')
  for i = 0; i < 1000; i = i + 1 {
    buf1[i] = (i * i).reinterpret_as_uint().to_byte()
  }
  let ns1 : Array[Int32] = [1000, 63, 64, 65]
  let refs1 : Array[String] = [
    "0bf1bcc8a1d72e2cf58d42182b637e56", "993a3eb298e52aca83ecfbb6a766b4d0", "07c01ca7c733475fad38c84c56f305c1",
    "9fc8404827cac26385f48f4f58fd32ce",
  ]
  for k = 0; k < ns1.length(); k = k + 1 {
    let n = ns1[k]
    av_md5_sum_x4(dst, md5x4_four(Bytes::from_array(buf1[:n])), n)
    for l = 0; l < 4; l = l + 1 {
      assert_eq(md5x4_lane_hex(dst, l), refs1[k])
    }
  }
  let buf2 : FixedArray[Byte] = FixedArray::make(1000, b'\x00')
  for i = 0; i < 1000; i = i + 1 {
    buf2[i] = (i % 127).reinterpret_as_uint().to_byte()
  }
  av_md5_sum_x4(dst, md5x4_four(Bytes::from_array(buf2[:999])), 999)
  for l = 0; l < 4; l = l + 1 {
    assert_eq(md5x4_lane_hex(dst, l), "a22bfef14302c5ca46e0ae91092bc0e0")
  }
}

///|
/// RFC 1321 / well-known vectors, in all four lanes. */
test "md5 x4 simd: RFC 1321 vectors in every lane" {
  let dst : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  av_md5_sum_x4(dst, md5x4_four(b""), 0)
  for l = 0; l < 4; l = l + 1 {
    assert_eq(md5x4_lane_hex(dst, l), "d41d8cd98f00b204e9800998ecf8427e")
  }
  av_md5_sum_x4(dst, md5x4_four(b"abc"), 3)
  for l = 0; l < 4; l = l + 1 {
    assert_eq(md5x4_lane_hex(dst, l), "900150983cd24fb0d6963f7d28e17f72")
  }
  av_md5_sum_x4(dst, md5x4_four(b"message digest"), 14)
  for l = 0; l < 4; l = l + 1 {
    assert_eq(md5x4_lane_hex(dst, l), "f96b697d7cb7938d525a2f31aaf161d0")
  }
}

///|
/// Exhaustive agreement with the scalar `av_md5_sum`: four *distinct* generated
/// messages per length, spanning 0, the 55/56/63/64/65 padding boundaries, and
/// multi-block inputs.
test "md5 x4 simd: equals scalar for four distinct messages" {
  let lens : Array[Int32] = [
    0, 1, 55, 56, 63, 64, 65, 119, 120, 128, 999, 1000, 4096,
  ]
  let dst : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  for k = 0; k < lens.length(); k = k + 1 {
    let n = lens[k]
    let srcs : FixedArray[Bytes] = FixedArray::make(4, b"")
    for l = 0; l < 4; l = l + 1 {
      srcs[l] = simd_gen_bytes(
        0x9E3779B9U + 17U * l.reinterpret_as_uint() + n.reinterpret_as_uint(),
        n,
      )
    }
    av_md5_sum_x4(dst, srcs, n)
    for l = 0; l < 4; l = l + 1 {
      let scalar : FixedArray[Byte] = FixedArray::make(16, b'\x00')
      av_md5_sum(scalar, srcs[l], n)
      assert_eq(md5x4_lane_hex(dst, l), hash_hex(scalar, 16))
    }
  }
}
