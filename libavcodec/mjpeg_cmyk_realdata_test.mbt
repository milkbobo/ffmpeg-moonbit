///|
/// ImageMagick CMYK JPEG (17x13, 4 components 1x1) decoded through the Adobe
/// APP14 transform paths: transform 2 (YCCK) -> yuva444p and transform 0
/// (CMYK) -> gbrap, byte-identical to `ffmpeg -f rawvideo` for the same
/// files.

///|
let jpeg_cmyk_t2_b64 : Bytes = b"/9j/4AAQSkZJRgABAQAAAAAAAAD/7gAOQWRvYmUAZAAAAAAC/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/9sAQwEDBAQFBAUJBQUJFA0LDRQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU/8AAFAgADQARBAERAAIRAQMRAQQRAP/EABkAAQACAwAAAAAAAAAAAAAAAAcDBQQGCP/EAC0QAAEDAwIEBQMFAAAAAAAAAAECAwQFBhEAEgcTFCEVMVaV0wgiMhclQVjS/8QAGgEAAgIDAAAAAAAAAAAAAAAABQgECQYHCv/EADMRAAECAwYCBQ0AAAAAAAAAAAECAwQREgAFBhMhMRQiMkFUYdIHFRYXJTNTVpKToqTR/9oADgQBAAIRAxEEAAA/AMVyHDhWXKucS/Dqq+ESnpgaLjYdB2hvkfht78vATt77sfzpecXtPwmI3LkVBcO01IJYzA4UBSEqJztVKKvedKYnROzytocciEwJZKkicm65bp155z6qt9+82YqZbVvMfSqvjOa10t/Oftq+IXSOLfMVNUMJL5jZxzOm+zdt5mD+WRnTXDh7aXXWEsJic6KJq4rsoJYp77kcKc2lRCEoaWCrana2dijgbzk/Fwvm66cSw/CcLQYNOWFZppzdJrEysuAzmZqTWEz5RaqXGDELfDWFL0PtVyJ4ytesNn5ZSlOmgbywJTABXTrOdgXi9b1GqFr8Eb2dprl9V+4pNUg1SYhTsaRcUeFNTHh7wMlDhZwncBzDkBRUUjR50Uj19b/uED5daVzE9kc+lzw2jej8J8qfun+2m8Ft7+qdwe+1L49B9wXJUaLVhVIcnlVGU8ZD0ooSpxbqUhKV5IJCsEjI799On5W8GXDh+Hu6EuyHy2yHQRUsiU2zLmUdJk2udgrngH2DDuNAoTsNRvvtqdABr1abWGI/G29Id4OXQzWtlYciJgKV0rJY6YNlsMhjZyg3tJ+wIxnvjPfXYU2KxQqNU1Q47IVLWt2Up5tLxlLcwhxTxWDzCpOEkrz2AHkBobjjCdz4ewfeAutkt15IMlrMgh5JQEzUaaSokUy1MzbnXcx5iO9r4YvWNian26glVDYlNNJ5QkJ6Ilt3762pa3fVer91t3NMqLnjTLbDLEiOlLCYyGU7WUstthKGgkeQQEjJJ8ySdI6am+n7f9jh/FpL6nvjOfcX4rZl6xMT9q/BvwWtv1v4h+t7g9yd/wBa/9k="

///|
let jpeg_cmyk_t0_b64 : Bytes = b"/9j/4AAQSkZJRgABAQAAAAAAAAD/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/9sAQwEDBAQFBAUJBQUJFA0LDRQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU/8AAFAgADQARBAERAAIRAQMRAQQRAP/EABkAAQACAwAAAAAAAAAAAAAAAAcDBQQGCP/EAC0QAAEDAwIEBQMFAAAAAAAAAAECAwQFBhEAEgcTFCEVMVaV0wgiMhclQVjS/8QAGgEAAgIDAAAAAAAAAAAAAAAABQgECQYHCv/EADMRAAECAwYCBQ0AAAAAAAAAAAECAwQREgAFBhMhMRQiMkFUYdIHFRYXJTNTVpKToqTR/9oADgQBAAIRAxEEAAA/AMVyHDhWXKucS/Dqq+ESnpgaLjYdB2hvkfht78vATt77sfzpecXtPwmI3LkVBcO01IJYzA4UBSEqJztVKKvedKYnROzytocciEwJZKkicm65bp155z6qt9+82YqZbVvMfSqvjOa10t/Oftq+IXSOLfMVNUMJL5jZxzOm+zdt5mD+WRnTXDh7aXXWEsJic6KJq4rsoJYp77kcKc2lRCEoaWCrana2dijgbzk/Fwvm66cSw/CcLQYNOWFZppzdJrEysuAzmZqTWEz5RaqXGDELfDWFL0PtVyJ4ytesNn5ZSlOmgbywJTABXTrOdgXi9b1GqFr8Eb2dprl9V+4pNUg1SYhTsaRcUeFNTHh7wMlDhZwncBzDkBRUUjR50Uj19b/uED5daVzE9kc+lzw2jej8J8qfun+2m8Ft7+qdwe+1L49B9wXJUaLVhVIcnlVGU8ZD0ooSpxbqUhKV5IJCsEjI799On5W8GXDh+Hu6EuyHy2yHQRUsiU2zLmUdJk2udgrngH2DDuNAoTsNRvvtqdABr1abWGI/G29Id4OXQzWtlYciJgKV0rJY6YNlsMhjZyg3tJ+wIxnvjPfXYU2KxQqNU1Q47IVLWt2Up5tLxlLcwhxTxWDzCpOEkrz2AHkBobjjCdz4ewfeAutkt15IMlrMgh5JQEzUaaSokUy1MzbnXcx5iO9r4YvWNian26glVDYlNNJ5QkJ6Ilt3762pa3fVer91t3NMqLnjTLbDLEiOlLCYyGU7WUstthKGgkeQQEjJJ8ySdI6am+n7f9jh/FpL6nvjOfcX4rZl6xMT9q/BvwWtv1v4h+t7g9yd/wBa/9k="

///|
fn mjpeg_cmyk_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
fn mjpeg_cmyk_check(
  encoded : Bytes,
  pix_fmt : String,
  reference : String,
) -> Unit raise {
  let bytes = @libavutil.av_base64_decode(encoded, 10000).unwrap()
  let img = @libavcodec.av_mjpeg_decode(bytes).unwrap()
  assert_eq(img.width, 17)
  assert_eq(img.height, 13)
  assert_eq(img.pix_fmt, pix_fmt)
  assert_eq(img.planes.length(), 4)
  let planes : Array[Byte] = []
  for p in img.planes {
    assert_eq(p.length(), 17 * 13)
    for b in p {
      planes.push(b)
    }
  }
  assert_eq(mjpeg_cmyk_md5(Bytes::from_array(planes)), reference, msg=pix_fmt)
}

///|
test "mjpeg: CMYK and YCCK 4-component match ffmpeg" {
  mjpeg_cmyk_check(
    jpeg_cmyk_t2_b64, "yuva444p", "af5279d0431426b8a115004ccb2ea1f1",
  )
  mjpeg_cmyk_check(
    jpeg_cmyk_t0_b64, "gbrap", "9718a46965a8f9486f1ea7ffda6d3583",
  )
}
