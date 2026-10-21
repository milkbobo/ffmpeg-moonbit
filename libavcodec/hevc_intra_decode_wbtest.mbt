///|
/// Real single-IDR HEVC sample decoded end to end. Reference:
///
///   ffmpeg -f lavfi -i "testsrc2=size=32x32:rate=1:duration=1" \
///          -c:v libx265 -x265-params \
///          "log-level=none:keyint=1:bframes=0:ctu=32:min-cu-size=8:sao=0:\
///           deblock=0:strong-intra-smoothing=0:amp=0:transform-skip=0:\
///           cu-lossless=0:scaling-list=off:repeat-headers=1:info=0" \
///          -pix_fmt yuv420p -f hevc one.hevc
///
/// Expected MD5 is the raw yuv420p frame decoded with
/// `-skip_loop_filter all` (this decoder returns pre-loop-filter samples).

///|
let hevc_intra_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoEIIWW6uTCsBaAgAAAMACAAAAwAIQAAAAAFE",
  b"AcFzwIkAAAEoAa3gJUYgxXZHktSujIOH9Y3xDgqukMU6OfvHJ+PSuSP5QNefYwJq54aV1OFEMk8nt81gmgfnVPQmi+5EI6icCYvR",
  b"nvb+M4rRb/F9EoP/z6qF/8IaKC7IY3apyD7dvLEVDbG8iyHhpsA5y+n7u95Z+h4ABg9W+uIaKiKHDsBbJfgVRdCctFq5lCveuyO6",
  b"Rlqyinx9Jwp0JqJpc88VQe03diyE+ZuMbwUH+mW9CQuPfd6TGh+WkFp1avGwgeEbSc8knn3avwhS2AeM76/iToyvgShUeWyg1Iga",
  b"3bS982sQwQENEj5cFUT06rTneWlyZFEYZwP0H7t/8v8S7E2KKpkgieqLQ6b9qYx1vi1EzNhTje2ZjzCzMsoKO5DQqJeQxJr8o0UE",
  b"9YgKl2N592AZeKk8Ns8QY7bdWbiN7BoulcE6MDKkiRgA5bDxuyfvJ4xyQM1p3AbwJ3QQdpCDOU8Wb/yzyvlPLwZ04MsUHM0OwRLc",
  b"xGILQpWkZoee9oa/OuqP7RynOLoma9CQwA==",
])

///|
/// Concatenate the three planes into a raw yuv420p frame.
fn hevc_intra_yuv(pic : HevcPicture) -> Bytes {
  let out : Array[Byte] = []
  for v in pic.y {
    out.push(v.to_byte())
  }
  for v in pic.cb {
    out.push(v.to_byte())
  }
  for v in pic.cr {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// `ffmpeg -skip_loop_filter all` IDCT of the real 8x8 block at (8, 0). */
test "hevc intra: idct matches FFmpeg for a real 8x8 block" {
  let c : Array[Int32] = [
    3468, -1428, 612, 612, -612, -408, -204, 408, 3060, -1020, -816, 408, 1020, -204,
    204, 204, 4896, -408, 408, 204, -816, -204, -204, 204, 1020, -408, 204, 204,
    816, 0, 0, 0, 0, 0, -612, 0, -612, 0, 204, 0, -816, 204, 816, 0, 612, 0, -408,
    0, -1836, 204, -816, -204, -408, 0, 408, 0, -612, 204, 408, 0, 204, 0, -204,
    0,
  ]
  hevc_idct(c, 3, 8).unwrap()
  let expected : FixedArray[Int32] = [
    79, 72, 69, 73, 146, 133, 134, 134, 78, 75, 73, 74, 137, 135, 137, 133, -24,
    -21, -16, -23, 2, -6, -8, -7, -23, -25, -26, -21, -4, -7, -6, -7, -21, -26, -23,
    -21, -7, -1, -6, -8, -21, -25, -16, -24, -12, -1, -7, -1, 71, 67, -21, -22, -2,
    -8, 74, 72, -11, 76, 77, -20, -5, 72, 75, -4,
  ]
  for i in 0..<64 {
    assert_eq(c[i], expected[i])
  }
}

///|
/// 64x48 sample spanning four 32x32 CTUs (CTB row/column availability):
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x48:rate=1:duration=1" ... multi.hevc
///   ffmpeg -skip_loop_filter all -i multi.hevc -f rawvideo multi_nolf.yuv

///|
let hevc_intra_multi_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoCCDFlurkwrAWgIAAAMAAgAAAwACEAAAAAFE",
  b"AcFzwIkAAAEoAa3gJUYgxXZHktSujIOH9Y3xDgqukMU6OfvHJ+PSuSP5QNefYwJqnYx/Z5r1BQmMEkJfMLr7D0sUV4CtXkuY/spt",
  b"uuPZkMUELB///4pmQwRq0wnxziDuIsM5HTCNuZ+Vnl4L/R6w5Ym47fUiFtAohOAh29HhgVUPmwY0n5an28XSyv0NByt4Zj4OS+z3",
  b"6sIMBRbgF8eKYWAK6ek+iDjgxzkMrsrxdSH7FZsqfTtAKAUmzatCjNhpga+Pjhypm/dqD7RRIiXcZDwY89HG0u220xmQ5NbDFUUV",
  b"42alOiG8HEQmsasDQMajZ/kHuAVmmQQwceJ1J1OIfmnOzC37ybWxI+YaD8wuQ+BN1GtIccMmMgQ/ix2NnVe+LCui0iMI2fe/TqFd",
  b"GTkikm56DYJcteg9GjzbeGx3ZUjXbcTWNQy5o/VHnHCDynv5XaBD9Egt2ZufhEJU4hMVpqDFRKibT6as6oPYa3rHHfEMoofrjEt+",
  b"y05cJEjB7kkg4JGLYA0GnfCBKfzKEoOiwSjxqqrTD2TQU5VMU/JWA0wt7rhTPT761pwaagEiDVWpNQ1d2ebbY9h9J3nNifVxz9e9",
  b"YYCIEgKQG2YVchTiKvpDP5SF/HLA//uyoY+B63nIkNU01t4bIn8wPmaoKTMEax9O1mlwKHqE65nZ2FcCrQfQh2V5wGPRIcXG1kci",
  b"ACvQjhlU5I0YbSsxqA1UdCv84PDMUKKNeiWkUcg/XSasOv2/So6HLvShz7Orl313IczI8F/zBOnZ+KrO2Wtl11kxmNycke4zZ9Q9",
  b"kqPe4Cu+KB+MliEPIItkFRe7joHuHVGOiqsHctcpnFb7I1Phh4XJGFRigzMs6pdY4g9qmOr5ZnRgWHVvcWadJuT1CRk+U/GaluKE",
  b"camD9BPsu2gtnqgWhdAo2UwNd4sh0yhB5AwKVfyxQab3ONt5r0FGEOqmmdEvbYZU/JNyYiYC38yKCBMFjX00nujb6Bz5HosZ38AP",
  b"BA2rtjGqIy3XZWEIBGnDRyk2+CJ6Bt/WiDYqeyca25EtuyMZ1CeJCjZYqoatJdQtvrPLEbdXBQ0Svq6Z8wz+g9DvscxeNC+NrQGl",
  b"dWMHbmXhUPSld0vCnSgGIA==",
])

///|
/// 64x64 sample with x265's default strong intra smoothing enabled:
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x64:rate=1:duration=1" ... strong.hevc
///
/// Expected MD5 is `-skip_loop_filter all` raw yuv420p.

///|
let hevc_intra_strong_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoCCBBZbq5MLwFoCAAAADAIAAAAMAhAAAAAFE",
  b"AcFzwIkAAAEoAa3gJUYgxXZHktSujIOH9Y3xDgqukMU6OfvHJ+PSuSP5QNefYwJql6ElUseoKExgkxi1ty//MwXb4ZXTaMrQjQ1q",
  b"9a1h1///rsJXEUNNYsnNuzBhGNiizRbS47w4pgm395ykZng/2iWhCLOaQj/+249FAuwjVls/LPV4M0OTEElC5E0+ODuvEB2moUMy",
  b"m9rWuoPlHVIlK73eBNBVdhXnTimgX2+DPlnywPg8XFV+f5Mcwj/Dhf+UgXloWaP2d55ahrsxjeicFYx56jDSuxWMwXgRBNmhCeZo",
  b"ghkt+Mf/vQw8o8vzY+Gnagct4WGSYeOWHf/5paBYGTQydcnx/KgCHpnWJVUlylxguT7ZUCXdgGKiXiWellxTBeZYvpdbv7BqRHP5",
  b"0vLDoUGuW0xJ88LSICeQRj3nX6qcsIhXUVcuXFqzpBihoxaGQsJDrUtPBRMVcncAcR+8YDyudGDlnB8yW6cNoK07u+Q4zBfXjXuI",
  b"zgPp8RvaC6o5gNazPe828UIyP9L7Lc506SQkM8vE6WB94grrJqSQawZMjpLnkKPmXRmniCOyFwwP3Oli/Wulh2L+WS1DficoWoPn",
  b"IMVbts8KMqSIJqK1yY/lrovNphUG5Hc4pIxVubtGUH+2ay2iQCQRnWrUgMDpK/E8zePQsEnnMng3x6U9lzPG/BrbcKlSs5hfnUkc",
  b"ijq9LdcnHr3XkRjaVGZKtz4NWni5LNqwxLWF9An5XKpTMjR5H2XKB8qq2dFgegRasSF0Z4KolctP3XZUH9oOwkLOXFDtvlbS5Qfb",
  b"k3hQFl9uyOtVjAk7mpwxkyfNHVTYrdBXTQO5GAzJrQf80DCYtfoUm2UZgoZCD/62Ig9P+h0MK/NuZ5zhxn06Cp3bQ8PvqBr+KUDM",
  b"n71tcCCks7d7uCU9irIG+A9amCKV/x5YpNdbnaysiRk8Jyb/P4mcPgoGaaFZsfTPjPb5FsOuqU1C4MyxvkD0VE6TiBBomPwfLJYs",
  b"TinVAGfKat680/hQUH74bqTdBojOcDKJ3yn9oa8eZ86+R0OUWbTHVXoT2i1yGefSJXbLxQYs/7SAHpkzLFPwLgAbsbFNJEXwUw6k",
  b"vtg0Oe1QNHJhcOpyAklvZ769EkLy9FVpEJ3CBQ/qgo1Np+KN0maYQXHJq6BvavfKI/278QVrRKOp45zuMYBSxbY0/kEqaMk3UaA6",
  b"cY/V1pc4W5simO113Nv+GrzwP43ch+1REe0rzMu6jQ9QpGUxJx8OFFwwLngJfcVzJmGofo8cIrj6YZPqz+3PzxCFzo+T2o2EwHjW",
  b"d0wZJ6e2SwAK7Vr0M/Mmln2ekRVXWYaV28OL/d0F89zkVpYEQXK5nYqOS2A7kiu0lmgjGzWduCeLXpEk58ZUbdSframZhDyEAoF1",
  b"8vhIfuwCibYfNUJU5zlTrrUSSa9BmZHwhuMF8YfLwZq7mh1xbmdUczYtbWZ5aTotYJEW2bQJjkW+dAX479l9RZGzeFM0N/8UH23D",
  b"On5Z7tCggIxzpYzu5/g=",
])

///|
test "hevc intra: 64x64 strong-smoothing sample matches ffmpeg" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_strong_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame_unfiltered(bytes, false, 0).unwrap()
  assert_eq(pic.width, 64)
  assert_eq(pic.height, 64)
  let yuv = hevc_intra_yuv(pic)
  assert_eq(yuv.length(), 6144)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0x3f, 0x4a, 0xf6, 0xd8, 0x03, 0x62, 0x81, 0x14, 0xdd, 0x35, 0x80, 0x09, 0xf4,
    0x30, 0xf8, 0x3a,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
/// 80x64 sample: the third CTB column is partial (80 = 2*32 + 16).
///
///   ffmpeg -f lavfi -i "testsrc2=size=80x64:rate=1:duration=1" \
///          -c:v libx265 -x265-params "...:sao=0:deblock=0:wpp=0" partial.hevc

///|
let hevc_intra_partial_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoCiBBZbq5MKwFoCAAAADAIAAAAMAhAAAAAFE",
  b"AcFzwIkAAAEoAa3gI0YWHZA1uKlqiGQIKmvNcpaOoB/RveOT9BSDSQy7wz8EO8SEi/m1LgqWAIhflFNySC6LvIBuabhFm8PddQiz",
  b"Ts29VyzdvPm//uibSGxgazQbRggoNPc2tFFCjLOMsLkpZ0Ciq2PpaLsX/ZryZHRM1hz5ucy5sjhcff5EflqfbprKNPjMRWC12b+J",
  b"mJCEGFgC/6GHyibK1CEt5pNziqRa/Huad6tNGdyLj191+48EEj055aGhxT08zAnwedw3LeBrPnzzFcW4Qrn4KPajcDpuxftH/HBO",
  b"iEVIxJwZqw8eroGc1tDfbRVMfQUvrBCmAA4TmBTpqPYhwBJ/xDUymU3zWWR5yOW/eCART7vw0PTJwkLj18s+XYVuVSgoHR8scF/i",
  b"NMWU5TbqYpN7pW8lArIYnEW/giZo0NX4B1AAVjKwy3b8O6d00Z0o75mBNah/cUlwgxvHVWYjigTMzvHzM3+zsMtHF7icOKBHl6/i",
  b"4sApfkdnfE3/1+oHMHNSCMJnSwtnJWsmaf4NSETD2H2kBz+FEN/kgS3Uxbt3bgzDI9CScPIXUT7ViMqlGDTvz2W0ai6bHT9eqwzx",
  b"Yy5t5h4cXUham6KO7F32unSvTyusZ0HhycAemxSrOBDGVJ2m2xJFiJXqEVV48GbF37BtULOQNuugxvgJkQyzmMAMFDupdufT8mCO",
  b"n1ROcu1R0DluoeQOQSi+9bcQKG02K4FOkaDif59+E8FlEReDt3EHTi0zuCjQNjVJESz8NBi6N9XBwPqq+RBmvhRrru2KIGVFuZV+",
  b"aAKcEgIRDGTCVYC8U9ifFWLEbwsNEfjm+fYnQnUPfPZZ0+cMOGxaYbXLndyqODenAhkw1QLxJ9prbVA/qxi789uDIzm+Th0jIpoX",
  b"UEY50sLWUadagOYgWRQJb/6floeiuhTo5BckMsjrh9Ay7liRMbpYW9DvbIs4ygnexjSvxyzzIe9iE9FOHSgyNmWY092cNNJaLO2w",
  b"3yLnixgJWeG4HZW6M/B+Pg4F07K144PwO3vcj2Wu+YgMF/shNi9rZW95xJ7tYUKCe4wARTQnulW0yYgxtJQ+jUFnjd5Nja1a099U",
  b"6P17f0QAqwFTAyoX3kQMRnOOGMQMI3NbmNlnwTPPSgLUiNY5jvH/g3Vdlls6gKcU3OjR7pzRf7FYyhkYZIVPdN6QOybUVInrgQ/R",
  b"9Gk+RY0LLDKpHGMCOL4YoBXa+WemTogYRW9dyP8VECB1juw0HysPGUuX67XNjCrSeNozaBRFZtSsr6XuLF+Wm9GBDU9/9uA6AETB",
  b"VGUj6zAwq10Eo5wuujex/gw+9tEqvrrrOUfo3WTovt/B5qIxqaPpl7D5FTIaPTCzL239UjVpumykBXXPkL5U978b0RiDFPeW6FOs",
  b"QK9if3d/AGunoQoOQOoTQga4Bx8WXADCjzMUGSE7TcKAJb6Ryqgl61BmOgG6AX7i0gwSEi6dsgAjRCzZEzgCV9e4uag7XNr3QMxJ",
  b"A0QL/mSpWhN9x66mDo0+h8bI88VCvsxIuTZKAJE7C0YsUX95Mg/A",
])

///|
test "hevc intra: 80x64 partial-CTB sample matches ffmpeg" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_partial_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame_unfiltered(bytes, false, 0).unwrap()
  assert_eq(pic.width, 80)
  assert_eq(pic.height, 64)
  let yuv = hevc_intra_yuv(pic)
  assert_eq(yuv.length(), 7680)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0x76, 0x54, 0x05, 0x9c, 0x0a, 0x05, 0x5b, 0xa1, 0x81, 0x01, 0x77, 0x66, 0x94,
    0x2b, 0x68, 0x91,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
test "hevc intra: deblocking matches ffmpeg for the 64x48 sample" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_multi_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame(bytes, false, 0).unwrap()
  let yuv = hevc_intra_yuv(pic)
  assert_eq(yuv.length(), 4608)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0x8b, 0xe6, 0x77, 0x15, 0x85, 0x76, 0xf0, 0xd3, 0x0c, 0xda, 0x43, 0x32, 0x58,
    0xd2, 0x3b, 0xd9,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
test "hevc intra: 64x48 four-CTU picture matches ffmpeg without loop filter" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_multi_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame_unfiltered(bytes, false, 0).unwrap()
  assert_eq(pic.width, 64)
  assert_eq(pic.height, 48)
  let yuv = hevc_intra_yuv(pic)
  assert_eq(yuv.length(), 4608)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0xee, 0x7f, 0x36, 0xf2, 0xb8, 0xb6, 0xf9, 0xaf, 0x05, 0x2e, 0x53, 0xb3, 0x9c,
    0xe4, 0x4c, 0x9c,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
test "hevc intra: deblocking 32x32" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame(bytes, false, 0).unwrap()
  let yuv = hevc_intra_yuv(pic)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0xd6, 0xd0, 0xe1, 0x0c, 0xde, 0x08, 0x65, 0x24, 0x31, 0xef, 0xda, 0x51, 0xb8,
    0xc8, 0xfa, 0x14,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
test "hevc intra: length-prefixed NAL input decodes identically" {
  let annexb = @libavutil.av_base64_decode(hevc_intra_b64, 100000).unwrap()
  let pkt = ff_h2645_packet_split(annexb, 0, Hevc, false).unwrap()
  let out : Array[Byte] = []
  for nal in pkt.nals {
    let n = nal.data.length()
    out.push(((n >> 24) & 0xFF).to_byte())
    out.push(((n >> 16) & 0xFF).to_byte())
    out.push(((n >> 8) & 0xFF).to_byte())
    out.push((n & 0xFF).to_byte())
    for b in nal.data {
      out.push(b)
    }
  }
  let pic = ff_hevc_decode_intra_frame_unfiltered(
    Bytes::from_array(out),
    true,
    4,
  ).unwrap()
  let yuv = hevc_intra_yuv(pic)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0xe2, 0x26, 0x2a, 0x62, 0xc9, 0x64, 0x6c, 0x9c, 0x7a, 0x57, 0xdd, 0xfa, 0x0a,
    0x5d, 0xdb, 0x86,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}

///|
test "hevc intra: real x265 IDR frame matches ffmpeg without loop filter" {
  let bytes = @libavutil.av_base64_decode(hevc_intra_b64, 100000).unwrap()
  let pic = ff_hevc_decode_intra_frame_unfiltered(bytes, false, 0).unwrap()
  assert_eq(pic.width, 32)
  assert_eq(pic.height, 32)
  let yuv = hevc_intra_yuv(pic)
  assert_eq(yuv.length(), 1536)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let expected : FixedArray[Int32] = [
    0xe2, 0x26, 0x2a, 0x62, 0xc9, 0x64, 0x6c, 0x9c, 0x7a, 0x57, 0xdd, 0xfa, 0x0a,
    0x5d, 0xdb, 0x86,
  ]
  for i in 0..<16 {
    assert_eq(digest[i].to_int(), expected[i])
  }
}
