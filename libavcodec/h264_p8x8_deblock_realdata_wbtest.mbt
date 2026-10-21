///|
/// Real-file regression for CABAC P_8x8 / multiple references and the
/// in-loop deblocking bS derivation.
///
/// Stream from `linuxserver/ffmpeg:9.0.2`:
///   -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.4" -c:v libx264
///   -preset medium -x264-params
///   "cabac=1:ref=2:bframes=0:weightp=0:scenecut=0:8x8dct=0:subme=7"
///   -f h264 p8x8.h264
///
/// Expected hashes are `ffmpeg -f framemd5` with and without
/// `-skip_loop_filter all`. The deblocking fix (internal-edge bS=2 with
/// non-zero coefficients, MV bS=1 rather than 2) makes both match exactly.

///|
let p8x8_b64 : Bytes = bcat([
  b"AAAAAWdNQArbEewEQAAAAwBAAAADAoPEibgAAAABaOqDyyAAAAEGBf//XdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUg",
  b"LSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2",
  b"NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MiBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJt",
  b"ZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4",
  b"OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29r",
  b"YWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0",
  b"PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj01IHNjZW5lY3V0",
  b"PTAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1p",
  b"bj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAFliIQ3nXvphO6D0U3JBbNiLH+L0kKneXB2",
  b"MCyN+yFY/oMOfs8kp+8kgsmmbYpdhjCN5g3J2d2Rw865jOtfIvDOvLd0+h5pw57b1CeZE5fBaq1svCqcRV0H/10AITcj8xu6kyKy",
  b"B3OzFGbfj675Z7F3eiKv315+W2Camt6bugeWWeytIGRGeP5JYTBdDhH7DiSdLQy0xJU+2ILg4NtsnoLKmk/C6Az+WMl5JuZWCsdu",
  b"9WQahzW8qhUpWtDM9ncRpdU9XtfWWifpIT/DJ5s7JkM96AxEm9uAHjYj0epwkoxgmGb2/U2ML7BAvDOuZ7nPAERPKwqsC69SwMLa",
  b"bOwasyvItxbkE+ficlem4BZ7fosgh4yW5T/sKpHa4oyOP77RfEg0p5yA+iYMOXVAfOMZwxOag8lsL+jnGaNxe4WVUUK4M9sSr8+J",
  b"RIAiJvhsS6NVBdHYcxSSWxIB+SXBdNrDJrrmv0u5g6wWuYGEX7udG8G6+vnj1aeqbAfJTRFwUd03P853nwIUWblaCXrnnw4MuyX0",
  b"IImAy1IGjaXdvfYYttMlZeSRW/VQByK2DlFdxzzNEtUHMDpnE9p8RVSAQ8y+7v0M3zRehnML8a39+Zq3/mUzD5P7s61Lhgg2i5GJ",
  b"p2OmsPjUkQqIUIHCNqcBnRpzqFwDiW4zFHim/F+jjXGhBaBSFyGF5McUhg0v540AtW3Qa03aFQAsjRPSzIhW2CHaxoqOXMucNkES",
  b"GLiyRz054bs/ByaHzXQSJQOD4KP3timeFaCTr9SWcIBZaHAIzy2zmT4vh+x456BUX5EeAjQyZ4Cp4v19+8OQOXpa0BJdZK5Ao48O",
  b"TgE7J6cnXGoTNtifcI8FPLRe2rDahvQnCWAJGIpEYZu/92vofIwgWwfyaevHF+xbcSE8wf90Opea4ANQE6EKDTnd6dvuYOT7i7NG",
  b"OhaEwc25MVunIxfqqSrkwx4Gq/qTN4vycjw9hpOWxvk88eSto1fcn8pmOyvGiwG54mJd8oSwB4O3l36Lel/WlTQXgnoCHT6SC+rj",
  b"iPfkCU/JvsdiLYu1LNEMQltAoe9E8lDo9qB3tePiiH0uthedyeikPEOZfFXMUzuPKM/TibY8bQy+OD3fBBf4/epOgSYNoVSiqRJL",
  b"KY+e8jz3ANHHb6E6DIPpxk+pdjMi2Lylt6C4p65YDE2sy/eKGUHzo5zwqJZMnrQr4GTwt6VUmSJ/LO9tPK20WiwUl61pnpyJ3f3Q",
  b"CApP2/6UZOZFVmfNcQAAAAFBmjkV/7x6DwToC/7A6TOZTQ1aUWZfNH6cNSa3huOeVkWQptz439modcZxT6Emc0ADijn1tPTNs2Cp",
  b"eX3Q",
])

///|
test "h264: CABAC P_8x8 refs=2 with deblocking matches ffmpeg" {
  let data = @libavutil.av_base64_decode(p8x8_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "67209b5b9f9f453b541ba569d470bf06")
  assert_eq(h264_yuv_md5(frames[1]), "ed728021994f7930feee72f4a3b0bfe8")
}

///|
test "h264: CABAC P_8x8 refs=2 without loop filter matches ffmpeg" {
  let data = @libavutil.av_base64_decode(p8x8_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "0e08e3165ec3d10cf5ca18e0014e4504")
  assert_eq(h264_yuv_md5(frames[1]), "db8693a6dbc718ce3e8cf6beb7d7e225")
}
