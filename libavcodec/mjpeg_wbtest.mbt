///|
/// Tests for the baseline MJPEG decoder.
///
/// Reference files from `linuxserver/ffmpeg:9.0.2`:
///   ffmpeg -f lavfi -i testsrc2=size=16x16:rate=1 -frames:v 1 \
///          -pix_fmt yuvj420p -c:v mjpeg -q:v 3 mjpeg_420.jpg
/// (likewise yuvj422p/yuvj444p). Expected MD5s are the decoder's own
/// `-f rawvideo -pix_fmt yuvj42xp` output, i.e. Y, U and V planes concatenated.

///|
let mjpeg_420_b64 : Bytes = bcat([
  b"/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAYGBwYHCAgICAgICQkJCgoKCQkJCQoKCgoKCgwMDAoK",
  b"CgoKCgoMDAwMDQ4NDQ0MDQ4ODw8PEhIRERUVFRkZH//EAGsAAQEBAAAAAAAAAAAAAAAAAAUDBwEBAQAAAAAAAAAAAAAAAAAAAAYQ",
  b"AAICAQMEAwEBAQAAAAAAAAIBAwQSEQUTACJBIRQkFUIjFhEAAwABBAIDAQAAAAAAAAAAAwECBBMFEQASMQYhI1H/wAARCAAQABAD",
  b"ASIAAhEAAxEA/9oADAMBAAIRAxEAPwDLpC3Ozfmr0/fHHylrwiEcYRojkkllxAAXkjJLVpeV1bYf+i2jcCjr/wCUzgGzn9SSF13G",
  b"bVhTlnXcWhNciPHLt1y9dM7PJGUu+VWHNLN+fIFbJiVgKz5JgAl/WHge9rVinp0jUnrDsS2f4+F1a2/x+U3MNYr7sjXcumXL8b3g",
  b"/sY9zDXpnfO92yS5KGiwEpRLR1yWhiPLIzV+gkwhb8HyOY/pJ9doN02oTNmhIay6Y88T98WqRA1jKfAqVFF9uU7bl8adLv8A/9k=",
])

///|
let mjpeg_422_b64 : Bytes = bcat([
  b"/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAYGBwYHCAgICAgICQkJCgoKCQkJCQoKCgoKCgwMDAoK",
  b"CgoKCgoMDAwMDQ4NDQ0MDQ4ODw8PEhIRERUVFRkZH//EAGwAAQEBAAAAAAAAAAAAAAAAAAUDBwEBAQEAAAAAAAAAAAAAAAAABgUH",
  b"EAACAgEDBAMBAQEAAAAAAAACAQMEEhEFEwAiQSEUJBVCIxYRAAICAQQDAQEAAAAAAAAAAAECBAMREgUAMSFBUQYT/8AAEQgAEAAQ",
  b"AwEiAAISAAMSAP/aAAwDAQACEQMRAD8Ay6Qtzs35q9P3xx8pa8IhHGEaI5JJZcQAF5IyS1aXldW2H/oto3Ao6/8AlM4Bs5/Ukhdd",
  b"xm1YU5Z13FoTXIjxy7dcvXTOzyRlLvlVhzSzfnyBWyYlYCs+SYAJf1h4Hva1Yp6dI1J6w7Etn+PhdWtv8flNzDWK+7I13Lply/G9",
  b"4P7GPcw16Ubz+utjyNxhNLUKhsOkKCP5LYQAGHZx0OzzLmS53OLSCkqBLcHyRHqj6XuJPYVvBX3nlDcY0qaLl06keqdFAPg6ZEd6",
  b"XU/AUJXPriDdijTdzAr1Zrnxhg4zc91jrSPhKEHV65//2Q==",
])

///|
let mjpeg_444_b64 : Bytes = bcat([
  b"/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAYGBwYHCAgICAgICQkJCgoKCQkJCQoKCgoKCgwMDAoK",
  b"CgoKCgoMDAwMDQ4NDQ0MDQ4ODw8PEhIRERUVFRkZH//EAHUAAQEBAAAAAAAAAAAAAAAAAAUGBwEBAQEAAAAAAAAAAAAAAAAABgcF",
  b"EAACAgEDBAMBAQEAAAAAAAACAQMEEhEFEwAiQSEUJBVCIxYRAAEDAwMDAgcBAAAAAAAAAAECAxEEEgUAMQYhIhNBMiRRkVMUJTOS",
  b"/8AAEQgAEAAQAwESAAISAAMSAP/aAAwDAQACEQMRAD8Ay6Qtzs35q9P3xx8pa8IhHGEaI5JJZcQAF5IyS1aXldP7PJGUu+VWHNLN",
  b"+fIFbJiVgKz5JgAl/WHge9rVinp015Hyh7EVjo/LQ2ym222F/SD11H63yfrni4oIbUq9aiVR19Qd9bjy6tVQtpqR02IiJHqTre5K",
  b"toZCup7Qp15LfjbHbdA69w20NsP/AEW0bgUdf/KZwDZz+pJC67jNqwpyzruLQmuRHjl265euqqpPWHYls/x8Lq1t/j8puYaxX3ZG",
  b"u5dMuX43vB/Yx7mGvVGyPNXKykDjlYFN/KyFf592p48xUHMjJ+aaIpHxMdvtj+W2+hNRiql/GZLGFuW6ooLqLoCikyCF7CNIH7V4",
  b"RdEGSagRNPdCt/ub6//Z",
])

///|
fn mjpeg_test_md5(data : Bytes) -> String {
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let sb = StringBuilder()
  for b in digest {
    let v = b.to_int()
    let hi = v >> 4
    let lo = v & 0x0F
    sb.write_char(
      (if hi < 10 { '0'.to_int() + hi } else { 'a'.to_int() + hi - 10 }).unsafe_to_char(),
    )
    sb.write_char(
      (if lo < 10 { '0'.to_int() + lo } else { 'a'.to_int() + lo - 10 }).unsafe_to_char(),
    )
  }
  sb.to_string()
}

///|
fn mjpeg_test_decode(b64 : Bytes) -> JpegImage raise {
  let bytes = @libavutil.av_base64_decode(b64, 10000).unwrap()
  match av_mjpeg_decode(bytes) {
    Ok(img) => img
    Err(e) => fail("mjpeg decode: \{e}")
  }
}

///|
fn mjpeg_test_concat(img : JpegImage) -> Bytes {
  let out : Array[Byte] = []
  for p in img.planes {
    for b in p {
      out.push(b)
    }
  }
  Bytes::from_array(out[:])
}

///|
test "mjpeg: 4:2:0 matches ffmpeg rawvideo" {
  let img = mjpeg_test_decode(mjpeg_420_b64)
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  assert_eq(img.pix_fmt, "yuvj420p")
  assert_eq(img.plane_widths, [16, 8, 8])
  assert_eq(img.plane_heights, [16, 8, 8])
  assert_eq(img.planes[0].length(), 256)
  assert_eq(img.planes[1].length(), 64)
  assert_eq(img.planes[2].length(), 64)
  assert_eq(
    mjpeg_test_md5(mjpeg_test_concat(img)),
    "84d096a8ed4e6971f9210b5ae9fd8466",
  )
}

///|
test "mjpeg: 4:2:2 matches ffmpeg rawvideo" {
  let img = mjpeg_test_decode(mjpeg_422_b64)
  assert_eq(img.pix_fmt, "yuvj422p")
  assert_eq(img.plane_widths, [16, 8, 8])
  assert_eq(img.plane_heights, [16, 16, 16])
  assert_eq(img.planes[0].length(), 256)
  assert_eq(img.planes[1].length(), 128)
  assert_eq(img.planes[2].length(), 128)
  assert_eq(
    mjpeg_test_md5(mjpeg_test_concat(img)),
    "10b4093afcdae3236a466db3dbebcda5",
  )
}

///|
test "mjpeg: 4:4:4 matches ffmpeg rawvideo" {
  let img = mjpeg_test_decode(mjpeg_444_b64)
  assert_eq(img.pix_fmt, "yuvj444p")
  assert_eq(img.plane_widths, [16, 16, 16])
  assert_eq(img.plane_heights, [16, 16, 16])
  assert_eq(img.planes[0].length(), 256)
  assert_eq(img.planes[1].length(), 256)
  assert_eq(img.planes[2].length(), 256)
  assert_eq(
    mjpeg_test_md5(mjpeg_test_concat(img)),
    "79f90c3dd2b8f2f5b26f3a5eb591fb65",
  )
}

///|
test "mjpeg: rejects non-JPEG and progressive input" {
  match av_mjpeg_decode(b"not a jpeg") {
    Ok(_) => fail("expected SOI error")
    Err(e) => assert_true(e.contains("SOI"))
  }
  // SOI + SOF2 (progressive) with a minimal segment.
  let sof2 : Bytes = b"\xff\xd8\xff\xc2\x00\x0b\x08\x00\x10\x00\x10\x01\x01\x11\x00"
  match av_mjpeg_decode(sof2) {
    Ok(_) => fail("expected progressive error")
    Err(e) => assert_true(e.contains("JPEG process") || e.contains("scan"))
  }
}
