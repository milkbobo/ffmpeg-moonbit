///|
/// Tests for the pure-MoonBit zlib inflate and the PNG decoder.
///
/// All eight PNGs were written by `linuxserver/ffmpeg:9.0.2` at 16x16 from
/// `testsrc2`, one per native pixel format. The expected MD5s are
/// `ffmpeg -i png_<fmt>.png -f rawvideo -pix_fmt <fmt>` output (for pal8 the
/// rawvideo layout is 256 index bytes followed by 256 BGRA palette entries).

///|
fn bcat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for p in parts {
    for b in p {
      out.push(b)
    }
  }
  Bytes::from_array(out[:])
}

///|
let png_gray_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAAAAAA6mKC9AAAACXBIWXMAAAABAAAAAQBPJcTWAAAAcElEQVR4nGN0YYCAm0Dsw+DF",
  b"wMKABoACZ8CM70C8keEwVhXECbQDcQEQZ0MF2hkqv0+YUMBQyzCVhYOBmaGFYaHG+YIJExgYpuI2ND6+AExn41Sx8DyEnopdRV9R",
  b"/EKGCQwFwrXZUBVAkXiQw5prswHPjxs23qv5GQAAAABJRU5ErkJggg==",
])

///|
let png_gray16_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQEAAAAABqCHz+AAAACXBIWXMAAAABAAAAAQBPJcTWAAAApklEQVR4nGN0PsOAAm7lQmif",
  b"3wwM3hcYGFgYCACwgrMTEQLfT0HoDVsYGA5vIdYE6ilonwkkgLiAF8LP7kZRAJKuTP++bMLnCZ9BSursGRimlrJw6DMwMIUzMLQ6",
  b"MTAsVNNgOA/UD1IC0jK1lHRHxt+Kh7sA4gpSTViodv45Mh/oSKJN6Csq6ou/tVCNgQHkgwJeoS119tndKCZAlMQzwAKq6SBICQBn",
  b"zDXFCYq6qwAAAABJRU5ErkJggg==",
])

///|
let png_monob_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQAQAAAAA3iMLMAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAL0lEQVR4nGNgYGYIdWUAAkdG",
  b"EOnAysDUBBLhsGBwFWHgWMEQKgpmizKwqTEEOgIAbycFTjvrsdkAAAAASUVORK5CYII=",
])

///|
let png_pal8_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAACXBIWXMAAAABAAAAAQBPJcTWAAADAFBMVEUAAAAkAABIAABsAACQ",
  b"AAC0AADYAAD8AAAAJAAkJABIJABsJACQJAC0JADYJAD8JAAASAAkSABISABsSACQSAC0SADYSAD8SAAAbAAkbABIbABsbACQbAC0",
  b"bADYbAD8bAAAkAAkkABIkABskACQkAC0kADYkAD8kAAAtAAktABItABstACQtAC0tADYtAD8tAAA2AAk2ABI2ABs2ACQ2AC02ADY",
  b"2AD82AAA/AAk/ABI/ABs/ACQ/AC0/ADY/AD8/AAAAFUkAFVIAFVsAFWQAFW0AFXYAFX8AFUAJFUkJFVIJFVsJFWQJFW0JFXYJFX8",
  b"JFUASFUkSFVISFVsSFWQSFW0SFXYSFX8SFUAbFUkbFVIbFVsbFWQbFW0bFXYbFX8bFUAkFUkkFVIkFVskFWQkFW0kFXYkFX8kFUA",
  b"tFUktFVItFVstFWQtFW0tFXYtFX8tFUA2FUk2FVI2FVs2FWQ2FW02FXY2FX82FUA/FUk/FVI/FVs/FWQ/FW0/FXY/FX8/FUAAKok",
  b"AKpIAKpsAKqQAKq0AKrYAKr8AKoAJKokJKpIJKpsJKqQJKq0JKrYJKr8JKoASKokSKpISKpsSKqQSKq0SKrYSKr8SKoAbKokbKpI",
  b"bKpsbKqQbKq0bKrYbKr8bKoAkKokkKpIkKpskKqQkKq0kKrYkKr8kKoAtKoktKpItKpstKqQtKq0tKrYtKr8tKoA2Kok2KpI2Kps",
  b"2KqQ2Kq02KrY2Kr82KoA/Kok/KpI/Kps/KqQ/Kq0/KrY/Kr8/KoAAP8kAP9IAP9sAP+QAP+0AP/YAP/8AP8AJP8kJP9IJP9sJP+Q",
  b"JP+0JP/YJP/8JP8ASP8kSP9ISP9sSP+QSP+0SP/YSP/8SP8AbP8kbP9IbP9sbP+QbP+0bP/YbP/8bP8AkP8kkP9IkP9skP+QkP+0",
  b"kP/YkP/8kP8AtP8ktP9ItP9stP+QtP+0tP/YtP/8tP8A2P8k2P9I2P9s2P+Q2P+02P/Y2P/82P8A/P8k/P9I/P9s/P+Q/P+0/P/Y",
  b"/P/8/P+BTFLuAAAA2ElEQVR4nEWOMWqCQRCF38iiayEewCJVBMtUv5U7guYE6cRuL6G1Rc6gdpJ0HsAiZHcrK3sbmxADIoJJ4YLF",
  b"Zv9V+OcxM7zh4zE0URRyfTBQwRPE3VP0qQSFDpuoz9iONywCKShwkkI7JyzbxBi2an0nzI1R9vlGON5na56BeJcTjKBXb6G7GEKb",
  b"d9HDFc3xX/20NU2Mzj0BBPLyUGXzIL1sIR4I0pdeYKP3biDyL72EyeKMWwpKROW44J94KX8VGfBFxm/f7Z1+nNP89TsRl2WtkdGU",
  b"oLX5B6mrXhqMAmQOAAAAAElFTkSuQmCC",
])

///|
let png_rgb24_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAACXBIWXMAAAABAAAAAQBPJcTWAAABC0lEQVR4nGOsZ/jHgA00IrH/",
  b"MfwHkkz/mYAkC1bVeABUw3wGBzyK7ME2MNgzUmADvTSIMZwHklsalIHkbyaQlHndDSApxAAKn1veMlhsaG9pZ/gzp7LhwkcGholN",
  b"JhO7JuaX5QPF62rqGBjmTZ16jaUOrHs/WPWBeqDJOfb7GBhsGQ4ftltXx/CvPjm4HmJUCdNWOwYFO2p42vAjQ0KC3g8vrfzKGcji",
  b"Hq8PZWeHUMOG8/wM59dfOnxYgIHBjoHhEFx8h6jdjlWvKLNBdRNDUVHYSvaDCxa8FGU4BAzWtRxzgcFqysAEDNZb3uBgRTOgr29V",
  b"YKh4QoJ47B9ZIBcSCUDQ1NLU3SmTna0FAPfoU3RIhuEJAAAAAElFTkSuQmCC",
])

///|
let png_rgb48_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQEAIAAADAAbR1AAAACXBIWXMAAAABAAAAAQBPJcTWAAABr0lEQVR4nGOsq2Ng+PuXgWjQ",
  b"1IRdHGTG//8QNjPzv39MTBA2C/FGkwdQLJg3j4HBwYGwJkZGTDF7ewaGf/9gPAcHmBr6+mB4WSAuzsBw4QKEvWVLU5OSEoT9+zcj",
  b"IwtUl4VFbe2NGxC2sDDQMKj4zZs+PlJSBCyAgPb2lpb2dlD0zZ5dWVlXd/Hip08g8QkTmpuNjSdO7OqaMCE/v6ysoACivra2pqa2",
  b"FsSaO3cqEFy/zgLKB8zMEOn9+xFGHzhQXw9xcU6OvT1Exs6OgeHIkUOH7OzWrQMZ8/dvfX1qalAQRCUMlJQwM2/ZYmvLwCAvb2s7",
  b"OCLZyOjjRwaG+PiEBF3dHz88PDQ1CwqqqmbOxKXew+PNm8OHs7NzcoKDB4cPzp3j5weR69dfvgyKA0FBkCgoRhgYDh3CVL9jh4iI",
  b"re2OHStWvHo1cD5QVd20iYGhqKi4OCxs5Up29oMHFyxYuPDlSzExkKshyXTdOnb22bMhydTUFJQPIMkUlA/gyRS//X19vb2rVgUG",
  b"hoaKiyckxMeLi8fG/v0rIwORRc4BENDc3NLS3NwFBFJS2UCgqQkAMiOmnuLIb1sAAAAASUVORK5CYII=",
])

///|
let png_rgba_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAAABAAAAAQBPJcTWAAABJklEQVR4nGOsZ/j3nwEPaETj",
  b"/2OAKGf6zwSmWfBpJgbADZjP4ECUBnuoCxjsGansgsFjgBjDeTC9pUEZTP9mgigxr7sBpoUYIKF/y1sGtwvaW9oZGP7MYahsuMDw",
  b"Ecif2GTCMLFrIkN+WT5Yvq6mDkjOY5g69RoDSx3UxP1QzQfqQdbmMNjvA9K2DAyHD9sxrAOq/1efzBBcD7OihIFpqx0Dg4IdDQPR",
  b"EOj2hAQ9hh9eWgz5lTMw5D1eH2LIzg6hoQvO8wPx+kvAMBAA8oD+ZTiEIr9D1I5hx6pXNHCB6iYGhqKiMIaV7AcZFix4ySAKtBkU",
  b"jWs55oKj0RQYa6BovOUNjUZspvb1rWIIDBUHBqI4Q+wfWbAYLA2AQFNLE0N3pwwwELUYACyQVHOjJvV4AAAAAElFTkSuQmCC",
])

///|
let png_rgba64_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQEAYAAABPYyMiAAAACXBIWXMAAAABAAAAAQBPJcTWAAADzklEQVR4nJWVDUxTVxTH/699",
  b"BdoiDDY0AcuHMl1iHEsY6oJGTZREaDJg08I+Ak4DMyzqmAmjSKkViiR+4IKZqJ06NH6x1a/NbG6S0M3hJkzmHDWrlDGFGKWj2kHB",
  b"Pp73VZN7qRHrSdp7f+ec9+7/3nvufZzxNcwVp4siHpv8Mi7BgaCtkp84Tt/8yDhuvOeJx+8XqMN7ZwQvQJE4UjTa//R4vy28Wx1G",
  b"WaPyFE8qn0DAmRn/ewyW4AU8OIztYR88PV4aOwj3fMr/DuV3erZOIMC9iF92Vc44ChEhe4/iWAumyK4x8aMCxAKK3E5cFCIpO4oV",
  b"q+UayqEt//0UdmQCAXKLkBA2xAyYj1n8Kcrin1iqZGfcJUZgIxPPQM5wMmXFMZ8JZymPLFaYlGWMAJ8VC8cVnVtsDKmmGHIObu8U",
  b"yi+9CTjzKAs7yG8Z5UE9kMCsQCg3BrGbcuxHw0n/tDMCRlfAyAwPsQ82/hBlZRV+GQihfMphrEmJY2ZkVDT4MimnDVT032hiBEhr",
  b"nEH59Abdz3E3GAHTo6BqY/Zc2QfcfUA5rg74m8RrX9zc8XE9me1mhfYC8ZUPlLs6SfW7S0SvlFe/qiY7iwg5HbOlMvcbYJ3l09S6",
  b"xWTF5mENTgKGVoOtpJDkD3Kf/7ESaHA2OG13iADtZK5o/Uw64P69oqU7lXLzQaM7fq3UE/AVWcp3is9V9fqP3Rv+eFvUxeJpHcA8",
  b"VJzsIuycYxq9RrakpdGUmUi2LrRUUPq+9qdmSKWUPut4pGo/6Wgn10mnnY9tEvdc6mJWoBfjLKJSNN+7Qtlr59vZ+PB5IEpNOeqC",
  b"78v222yG7FWkU7rfxke/bmO2AAEmZgU4riKTxWS9Z7bUFmwsrEgbIQLysnKW1gLr95VZzUYpwh0LeKOTpbQT7lcuLwBKkkoSV80h",
  b"AsQNAenSuujHeTQwMxiO849a0c5Z/T1d4CSex55xk0s2dpclxz51jtRWovmvX8lxtB21WYXrfmFIzfcL1rXPZJ+QJbH02/JI/xYU",
  b"4tCdzmAE3G5Ru6JNlEPujaW4DJRDOcCTS9lVxVckbWLi8YJO+IyySi94hzooP1NArrbpBWnAUk2pZkkRsE2V4715GDhQc7Da/i6p",
  b"gVbgOrma61ebV+StAa5Mlf+YbPTXhKOafPdm9+FD6T0Gm6F1nRawbtEdsS8CdvXs6vkuJQgBPd+rXVK7Fo2uH/aQmrRkW6OJp+xE",
  b"niz6bXI4v1hujomRMnz4nfwvuak/3voW6bxPbj3SxI9iN0c24ZNsE5oJ73651s7fAranr0TCt8BDjVVOdb38FnkAAAAASUVORK5C",
  b"YII=",
])

///|
fn png_test_md5(data : Bytes) -> String {
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
fn png_test_decode(b64 : Bytes, len : Int32) -> PngImage raise {
  let bytes = @libavutil.av_base64_decode(b64, len).unwrap()
  match av_png_decode(bytes) {
    Ok(img) => img
    Err(e) => fail("png decode: \{e}")
  }
}

///|
test "png: grayscale 8-bit matches ffmpeg rawvideo" {
  let img = png_test_decode(png_gray_b64, 10000)
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  assert_eq(img.pix_fmt, "gray")
  assert_eq(img.pixels.length(), 256)
  assert_eq(png_test_md5(img.pixels), "2fe5d61c17adc6f41ba6bd4ffebb863f")
}

///|
test "png: grayscale 16-bit matches ffmpeg rawvideo" {
  let img = png_test_decode(png_gray16_b64, 10000)
  assert_eq(img.pix_fmt, "gray16be")
  assert_eq(img.pixels.length(), 512)
  assert_eq(png_test_md5(img.pixels), "87bc10981e0cb26e3efd7e64253582ec")
}

///|
test "png: 1-bit monob matches ffmpeg rawvideo" {
  let img = png_test_decode(png_monob_b64, 10000)
  assert_eq(img.pix_fmt, "monob")
  assert_eq(img.bit_depth, 1)
  assert_eq(img.pixels.length(), 32)
  assert_eq(png_test_md5(img.pixels), "b425597dbc6e16e20a134a514329eec7")
}

///|
test "png: palette matches ffmpeg rawvideo (indices + BGRA palette)" {
  let img = png_test_decode(png_pal8_b64, 10000)
  assert_eq(img.pix_fmt, "pal8")
  assert_eq(img.pixels.length(), 256)
  assert_eq(img.palette.length(), 1024)
  let raw : Array[Byte] = []
  for b in img.pixels {
    raw.push(b)
  }
  // AV_PIX_FMT_PAL8 stores 0xAARRGGBB natively; rawvideo writes B,G,R,A.
  for i in 0..<256 {
    raw.push(img.palette[i * 4 + 2])
    raw.push(img.palette[i * 4 + 1])
    raw.push(img.palette[i * 4])
    raw.push(img.palette[i * 4 + 3])
  }
  assert_eq(
    png_test_md5(Bytes::from_array(raw[:])),
    "850b15aa017ac9eb3611b04f1f789fb7",
  )
}

///|
test "png: rgb24 matches ffmpeg rawvideo" {
  let img = png_test_decode(png_rgb24_b64, 10000)
  assert_eq(img.pix_fmt, "rgb24")
  assert_eq(img.pixels.length(), 768)
  assert_eq(png_test_md5(img.pixels), "4da68f68b1675ef2e284dfca9c15d499")
}

///|
test "png: rgb48be matches ffmpeg rawvideo" {
  let img = png_test_decode(png_rgb48_b64, 10000)
  assert_eq(img.pix_fmt, "rgb48be")
  assert_eq(img.pixels.length(), 1536)
  assert_eq(png_test_md5(img.pixels), "3e5fd59c33f42bd8a6afd9c612a3bd4f")
}

///|
test "png: rgba matches ffmpeg rawvideo" {
  let img = png_test_decode(png_rgba_b64, 10000)
  assert_eq(img.pix_fmt, "rgba")
  assert_eq(img.pixels.length(), 1024)
  assert_eq(png_test_md5(img.pixels), "73cad3afc263c9ac34ee111a0c166d95")
}

///|
test "png: rgba64be matches ffmpeg rawvideo" {
  let img = png_test_decode(png_rgba64_b64, 10000)
  assert_eq(img.pix_fmt, "rgba64be")
  assert_eq(img.pixels.length(), 2048)
  assert_eq(png_test_md5(img.pixels), "cb32de3396cb2a706dfbe1db221b0cfb")
}

///|
test "png: rejects bad signature and Adam7" {
  match av_png_decode(b"not a png file at all") {
    Ok(_) => fail("expected signature error")
    Err(e) => assert_true(e.contains("signature"))
  }
}

///|
test "inflate: stored block round-trip and adler32" {
  // zlib stream: 78 01, final stored block (01 05 00 FA FF "hello"), adler.
  let z : Bytes = b"\x78\x01\x01\x05\x00\xfa\xffhello\x06\x2c\x02\x15"
  let out = inflate_zlib(z, 100).unwrap()
  assert_eq(out.length(), 5)
  assert_eq(out[0], b'h')
  assert_eq(out[4], b'o')
  assert_eq(inflate_adler32(b"hello"), 0x062C0215U)
}

///|
let png_adam7_rgb_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAAHnlligAAADKUlEQVR42gEeA+H8AAAAAIA4aAAYWCiYkJAAQBw0wFScAFh0XNis",
  b"xAAMLBRMSEiMZHzMgLAAJIQ8ZKBwpLyk5NjYACAOGmAqTqBGguBitgAsOi5sVmKscpbsjsoAOGZCeIJ2uJ6q+LreAESSVoSuisTK",
  b"vgTm8gAGFgomJCRGMj5mQFiGTnKmXIzGaqbmeMAAEkIeMlA4Ul5ScmxsknqGsoig0pa68qTUAB5uMj58TF6KZn6YgJ6mmr60tN7C",
  b"zv7Q6AAqmkZKqGBqtnqKxJSq0q7K4Mjq7uIK/PwAEAcNMBUnUCNBcDFbkD91sE2P0Fup8GnDABYdFzYrMVY5S3ZHZZZVf7ZjmdZx",
  b"s/Z/zQAcMyE8QTtcT1V8XW+ca4m8eaPch738ldcAIkkrQldFYmVfgnN5ooGTwo+t4p3HAqvhAChfNUhtT2h7aYiJg6iXncilt+iz",
  b"0QjB6wAudT9Og1lukXOOn42urafOu8HuydsO1/UANItJVJljdKd9lLWXtMOx1NHL9N/lFO3/ADqhU1qvbXq9h5rLobrZu9rn1fr1",
  b"7xoDCQADCwUTEhIjGR8zICxDJzlTLkZjNVNzPGCDQ22TSnqjUYezWJTDX6HTZq7jbbvzdMgACSEPGSgcKS8pOTY2ST1DWURQaUtd",
  b"eVJqiVl3mWCEqWeRuW6eyXWr2Xy46YPF+YrSAA83GR8+Ji9FMz9MQE9TTV9aWm9hZ39odI9vgZ92jq99m7+EqM+Ltd+Swu+Zz/+g",
  b"3AAVTSMlVDA1Wz1FYkpVaVdlcGR1d3GFfn6VhYuljJi1k6XFmrLVob/lqMz1r9kFtuYAG2MtK2o6O3FHS3hUW39ha4Zue417i5SI",
  b"m5uVq6Kiu6mvy7C827fJ677W+8XjC8zwACF5NzGAREGHUVGOXmGVa3GceIGjhZGqkqGxn7G4rMG/udHGxuHN0/HU4AHb7RHi+gAn",
  b"j0E3lk5HnVtXpGhnq3V3soKHuY+XwJynx6m3zrbH1cPX3NDn49336uoH8fcX+AQALaVLPaxYTbNlXbpybcF/fciMjc+Zndamrd2z",
  b"veTAzevN3fLa7fnn/QD0DQcBHQ4OawOFkF+JqQ4AAAAASUVORK5CYII=",
])

///|
let png_adam7_mono_b64 : Bytes = bcat([
  b"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQAQAAAAFAj/JaAAAAGklEQVR42mNgQAIfoHAVHIaiYGNjhjNnMEkAEYoSXfwvABsAAAAA",
  b"SUVORK5CYII=",
])

///|
test "png: Adam7 interlaced RGB and 1-bit gray match ffmpeg" {
  let rgb = png_test_decode(png_adam7_rgb_b64, 10000)
  assert_eq(rgb.pix_fmt, "rgb24")
  assert_eq(rgb.width, 16)
  assert_eq(rgb.height, 16)
  assert_eq(rgb.pixels.length(), 768)
  assert_eq(png_test_md5(rgb.pixels), "8b71dd82e3f8bb35641086c3f30541c9")
  let mono = png_test_decode(png_adam7_mono_b64, 10000)
  assert_eq(mono.pix_fmt, "monob")
  assert_eq(mono.pixels.length(), 32)
  assert_eq(png_test_md5(mono.pixels), "946fb03323d3e4981674221fe6b0fd43")
}
