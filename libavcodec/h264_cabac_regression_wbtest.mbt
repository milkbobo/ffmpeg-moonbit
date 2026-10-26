///|
/// Real libx264 CABAC regression streams, FFmpeg 9.0.2 reference YUV MD5.
/// Source: testsrc2 16x48/32x48/64x48, 1 fps, one IDR each; smptebars
/// 64x16, 1 fps, I+3P; testsrc2 96x64, 5 fps, I+5P.
/// All: profile main, yuv420p, cabac=1:bframes=0:8x8dct=0:slices=1:ref=1.
/// IDR-only: keyint=1:scenecut=0. Inter: keyint=999:min-keyint=999:
/// scenecut=0:weightp=0:fast-pskip=0. Output is Annex B H.264.
/// References: ffmpeg [-skip_loop_filter all] -i in.264 -f framemd5 out.md5
/// Emit after generation: moon run scripts/emit_h264_cabac_regression.mbtx
/// LGPL-2.1-or-later.

///|
let cabac_dense_b64 : Bytes = b"AAAAAWdNQArdewEQAAADABAAAAMAIPEieAAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAtIEguMjY0L01Q" +
  b"RUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBj" +
  b"YWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBt" +
  b"aXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tp" +
  b"cD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0w" +
  b"IGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5" +
  b"aW50PTEga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFw" +
  b"bWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhDedjVMFWT1QMsgtmxFj/F6SFTvLg7GBZG5wEWQl" +
  b"yTyslXVehDMOJ/tux+EAChqYLzpAfAuZCOBGSrVAazbK6ftTQJov1mb27xZZTwnwq55U0Etz1hp89kCcu1j/8G4vz4SICQnjHIujTV/bjHpHe4T1" +
  b"fEh0sqtTU1p4my9HhmSGuRKn3uZkI2cKtDE57t9q3JtlhSKY0UahDzcEo+/XXXM40cVJ34SsI316UCfztyd/6umzm9ngXlr04E8FMop3JsmCWFbr" +
  b"a1VPbA8VZe82sqaI+XgTpyVf9vKT1upiSX4OWvvbxeUwBq7VL+TOH5BMVyGwEddkMsqHbqf/qM7WEuCuK6H9ZrYxLUbjjs8K/ruu1+IBkP6UvAw2" +
  b"E90uYe4IIEZOzboH"

///|
let cabac_dense : Array[String] = ["1af1b8dc6a7875aa51eea15bcd43a191"]

///|
let cabac_dense_unf : Array[String] = ["5ce99a5d3c5c2141158e8555b25b8467"]

///|
test "h264 CABAC regression: cabac_dense filtered and unfiltered YUV" {
  let data = @libavutil.av_base64_decode(cabac_dense_b64, 65536).unwrap()
  for skip in [false, true] {
    let frames = h264_decode_annexb_frames(data, skip).unwrap()
    let expected = if skip { cabac_dense_unf } else { cabac_dense }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      assert_eq(h264_yuv_md5(frames[i]), expected[i])
    }
  }
}

///|
let cabac_dense32_b64 : Bytes = b"AAAAAWdNQArcnsBEAAADAAQAAAMACDxIngAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAtIEguMjY0L01Q" +
  b"RUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBj" +
  b"YWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBt" +
  b"aXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tp" +
  b"cD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0w" +
  b"IGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5" +
  b"aW50PTEga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFw" +
  b"bWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhDede+mE7y9zURikqiYHQA2gSFTvLg7GBZG5wjY+" +
  b"wRnqPN6iTC0sreO7GbbQgwU5Bw5z4qkrgp+xun8tIpdrD70ACBBZ1GI6jIH9QoXHp7WySCgEdagb6184paFmMz74hJgvo6FgY0RXJSTQ+7QkFCer" +
  b"4kOllVqamt6bwbtSRaxqXSBkQ2IppmyGZ0N3IKveNLQmvK7RUsMNhuv+bqmEPFkA6s1Z9z2VelnZL+Ej4pEB2GnqotKVwboFgLQFHX3v5rDgcAHX" +
  b"Jo04hkiPLC5lwC4ABfZsAV7jYHccAxwEShJrqK70jMTi+qLNj9guM/XPkmHsjd6RcXeLzTAO6B2JFHs7juwAk1SFOhJVYGQc3lju4WyuaFWGzxFE" +
  b"7oMTunTkfKrWmdHRX6iuC8MFAvDA6wUhyH5O5gDy4d+vOhvF7h9Q+K6m3C9PzkErZvAhzIRi3vJnYhsXiRKkJHEiDT24Lo5CP/MbMfZvY8Bxxjvt" +
  b"rDzGXv+wl2vPvVyyzZ10LNHJDWXCtZSvWaeEBC4DSxWcr3xgjwDi6RuOXNRA02te+tQhD63amysWZiCNbIYPLyWH1+t/D7AWigomEU9Puxyh1zo4" +
  b"zF5RHxbrpCXbotjTVZuYzD8VZ6HRp/WZfELonFsOETaA100Y6X2cMLv20NVDAjCxWd6gBVHBPMKLhxJnYLU5I3ALTJxnZ+jJu8U5wrnGzsscID0t" +
  b"ks1sRuCuiy9bnKE="

///|
let cabac_dense32 : Array[String] = ["73bae6910b3158555ee66945e9d28d02"]

///|
let cabac_dense32_unf : Array[String] = ["7a44648c138e1cb61cc98952f0db20c8"]

///|
test "h264 CABAC regression: cabac_dense32 filtered and unfiltered YUV" {
  let data = @libavutil.av_base64_decode(cabac_dense32_b64, 65536).unwrap()
  for skip in [false, true] {
    let frames = h264_decode_annexb_frames(data, skip).unwrap()
    let expected = if skip { cabac_dense32_unf } else { cabac_dense32 }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      assert_eq(h264_yuv_md5(frames[i]), expected[i])
    }
  }
}

///|
let cabac_dense64_b64 : Bytes = b"AAAAAWdNQArcR7ARAAADAAEAAAMAAg8SJ4AAAAABaO4PLIAAAAEGBf//VNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9N" +
  b"UEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczog" +
  b"Y2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAg" +
  b"bWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNr" +
  b"aXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgc2xpY2VzPTEgbnI9" +
  b"MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtl" +
  b"eWludD0xIGtleWludF9taW49MSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBx" +
  b"cG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAFliIQ3nXvphO6D0U3JBbNiLH+L0kKneXB2MCyN+yFY" +
  b"/oMOfs8kp+8kgsmmbYpdhjCN5g3J2d2Rw865jOtfIvDOvLd0+h5pw57b1CeZE5fBaq1svCqcRV0H/10AITcj8xu6kyKyB3OzFGbfj675Z7F3eiKv" +
  b"315+W2Camt6bugeWWeytIGRGeP5JYTBdDhH7DiSdLQy0xJU+2ILg4NtsnoLKmk/C6Az+WMl5JuZWCsdu9WQahzW8qhUpWtDM9ncRpdU9XtfWWifp" +
  b"IT/DJ5s7JkM96AxEm9uAHjYj0epwkoxgmGb2/U2ML7BAvDOuZ7nPAERPKwqsC69SwMLabOwasyvItxbkE+ficlem4BZ7fosgh4yW5T/sKpHa4oyO" +
  b"P77RfEg0p5yA+iYMOXVAfOMZwxOag8lsL+jnGaNxe4WVUUK4M9sSr8+JRIAiJvhsS6NVBdHYcxSSWxIB+SXBdNrDJrrmv0u5g6wWuYGEX7udG8G6" +
  b"+vnj1aeqbAfJTRFwUd03P853nwIUWblaCXrnnw4MuyX0IImAy1IGjaXdvfYYttMlZeSRW/VQByK2DlFdxzzNEtUHMDpnE9p8RVSAQ8y+7v0M3zRe" +
  b"hnML8a39+Zq3/mUzD5P7s61Lhgg2i5GJp2OmsPjUkQqIUIHCNqcBnRpzqFwDiW4zFHim/F+jjXGhBaBSFyGF5McUhg0v540AtW3Qa03aFQAsjRPS" +
  b"zIhW2CHaxoqOXMucNkESGLiyRz054bs/ByaHzXQSJQOD4KP3timeFaCTr9SWcIBZaHAIzy2zmT4vh+x456BUX5EeAjQyZ4Cp4v19+8OQOXpa0BJd" +
  b"ZK5Ao48OTgE7J6cnXGoTNtifcI8FPLRe2rDahvQnCV/shgzXlLuJRUVNBgNpXyRn/v2bnYgngteLxz4ibnmz9z2uPDT/lo8g23YBqf7a9yM0trx7" +
  b"JgX2RBnVCi+WhICRDi+4IMZdQQVY+6rjJR9RZkQh4N+vRiS+yqHAx8ipPXuNLIEeeYCXke952LB28t2AqBzs23vNAnKatEWxZqJZ5phmWy7KlDCr" +
  b"/zAbMCrDcKCS2cjVGgOXbbSxdBC5yxA4Zd9Lr0hggUlEE7pPbs3h6Ak+xDx7k4G7gpbgp5MH5XRjgnZc3okXKc4YV8PomaJcsLLc7yK3a0U1oAjp" +
  b"kAkXfPibILODUWvuN8T217Wb6ODRWfWrII6QT4HuiS9YxY62IcF4xjZgb366yCu4oaj9jJ7yRf0HRbvSWd429wFA6/glmHqAtkGqRRZd"

///|
let cabac_dense64 : Array[String] = ["0d0e1e41b85c93d65be60889a5b97e22"]

///|
let cabac_dense64_unf : Array[String] = ["2782458ffb5d1a106a2eaf63a43a9ce4"]

///|
test "h264 CABAC regression: cabac_dense64 filtered and unfiltered YUV" {
  let data = @libavutil.av_base64_decode(cabac_dense64_b64, 65536).unwrap()
  for skip in [false, true] {
    let frames = h264_decode_annexb_frames(data, skip).unwrap()
    let expected = if skip { cabac_dense64_unf } else { cabac_dense64 }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      assert_eq(h264_yuv_md5(frames[i]), expected[i])
    }
  }
}

///|
let cabac_inter64_b64 : Bytes = b"AAAAAWdNQAraE7AWoEBAqAAAAwAIAAADABB4kTUAAAABaO4PLIAAAAEGBf//aNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2" +
  b"NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9u" +
  b"czogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAu" +
  b"MDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3Rf" +
  b"cHNraXA9MCBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgc2xpY2VzPTEg" +
  b"bnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0w" +
  b"IGtleWludD05OTkga2V5aW50X21pbj01MDAgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9" +
  b"MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhBP/994F" +
  b"rdP4E+qw/WL90FyG1piXXf1NncXcldfVpDWcj8Bb0Jp9GhV2YOjn52pWvRQsrhIlr5CzzOiWjcR3W221EwN2iQstY+8QpjxVoCTkBniKxGP2Cw7L" +
  b"Vs+4ikRo70x36hPd3m8AJmg26RGisrAnVcxxf1nk8WqMOYccnh0jxMf8nYcOHPb8c+pygbilDYHOUWJPw9SiBW1LX2LTd252uyjl0L0ewoXsyz29" +
  b"JLPbIy3UFeDK5QJyc1YIUeidHVWU19SQBZJA+c1lmXmJqHMbAmUg7QFCbjnHUN2vOkqxZil8TaIQZ4ztpZVDT7cAMGxNyXXSVoXRtVSu+ZzAHl65" +
  b"vxSFix64FEaXNCdbDeypRip0TDaz/w5k96OBQGFDyEYHvAApmmyc75m7/wEkkfW8RK5M4naDx0fh5UwJHfoSe5vf4AF0XuEAAAABQZoif/EYAAAA" +
  b"AUGaQl+YMQAAAAFBmmP/HDA="

///|
let cabac_inter64 : Array[String] = [
  "6850f8451e7f9f794c9e695a4da1e1e9", "6850f8451e7f9f794c9e695a4da1e1e9", "6850f8451e7f9f794c9e695a4da1e1e9",
  "6850f8451e7f9f794c9e695a4da1e1e9",
]

///|
let cabac_inter64_unf : Array[String] = [
  "ff876d604d9d8c7bf954f832bcbcd497", "ff876d604d9d8c7bf954f832bcbcd497", "ff876d604d9d8c7bf954f832bcbcd497",
  "ff876d604d9d8c7bf954f832bcbcd497",
]

///|
test "h264 CABAC regression: cabac_inter64 filtered and unfiltered YUV" {
  let data = @libavutil.av_base64_decode(cabac_inter64_b64, 65536).unwrap()
  for skip in [false, true] {
    let frames = h264_decode_annexb_frames(data, skip).unwrap()
    let expected = if skip { cabac_inter64_unf } else { cabac_inter64 }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      assert_eq(h264_yuv_md5(frames[i]), expected[i])
    }
  }
}

///|
let cabac_moving96_b64 : Bytes = b"AAAAAWdNQAraGJsBEAAAAwAQAAADAKDxImoAAAABaO4PLIAAAAEGBf//aNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9N" +
  b"UEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczog" +
  b"Y2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAg" +
  b"bWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNr" +
  b"aXA9MCBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgc2xpY2VzPTEgbnI9" +
  b"MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtl" +
  b"eWludD05OTkga2V5aW50X21pbj01MDAgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBj" +
  b"cmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhF+rfWb7tPAq" +
  b"JtLUq3td8ZHLNXqoE3wQoAwNOGmYjmKwG/9/aFdhte/6Cd3Jwjx6H2BkAkH/qu1+4EDDvmbUwLUcQxjfSeTZ0U+A2gzBSqrV7l7N521k53Wsa2Ri" +
  b"zhA4k0XAB7446pXz2B4Dm1xfU9P2TM7sUrMxGTIPICyylI11a1HXz5pMzU7HUrMu2W27rRe2lg/JzhIW5LepnX0AiamTEm+jXoFr5gU2ZBp1V6eH" +
  b"xDhgs0iPJSbLI1ZHWIorlm/30FAuvYsdE9QV2ou3TtNE7iIkpbGv1sSuJUdML5MFZnO2qeQDPfgd/Shvp3pxuaoucHdnyrkwtZOY4wWV6cbsjQRs" +
  b"jq3st3xpvgFjnYbCDxdxCtE4siFGblWWrU/on0wg1e0DuiBg5gO5qIQZ5BEEQsRVgi1MNbfiM3hRF16qFmN2woiqAGQo5iRV0Ztfy+O2wyHWIJ16" +
  b"ZWOxJPsOI6h7NIQf74bvDNy+DPDZCrBoDKGUdDPXAxOh0wkv71sOIGjIKqO5XKphxlB4ws3Je83W7z03Tz3RQ6NOIIFpgsDBXbungxyiWpv3R279" +
  b"ZJtZXvujxrki8yC0oWKlVU5sSv5xU0y/SyOcFXDiF/TL0T6bkVmQKBIG1gDJJUizoYjV8DQ9I30t5Q2My5X3/JzUdXdwgPlbgKUBDXY/33XoGIIb" +
  b"iydLHwWMAWpKuSBoc/fHb/Sj/YwU8Go7OHtGt6GbOtG80mArF03uJxSzyKA4GOGKUi5efRNc92yTtAOOI8nP7kHOWLsulA+JIspPkhCR+lTuoOhY" +
  b"ezyaYTBJmkkJaCidAqpOLis+OK3FtwHcuJIfgfkg6ylLgxnv7p1X0DHSCl/Km67/XYwJsSccXQzkykg9WFw8HQWp/Wj8e5PGwSrr/Xqy5ufOLbvs" +
  b"C6tNJFkhJQlf9KIVarec6V4HlQYtSjweBOR4UQ2cCPHX6ROIM0aU+cj9hjU7xQ0yj4MpSJkIMqmRHQAeNtIrSJucoEPbmoAWXqb4hBdhSudoBOII" +
  b"z0Wg6EWMyuIQPDui7N5It2Hv5Am9+a9qvrJpMwXYkAh8IIH8GQs4X6NVHeYdci/OK2h+w3wzvPTIbBD0q1/QQ+tgv1ip6tUAIpYfpc4HTCmEi7lA" +
  b"qT25LC+mo4hbJ8QL7gDnufTlqUgzXj1simfKwrqSErTWZCtBqlxgPosXD2uGBemGKN/U8lBFjbfFp3wD7tSJNFTl/NHftE7eDQQbmZmnFuvDhvFa" +
  b"eu/CZxBT3u/PBHMN6i98POmojz6fT+agRdMXM71Rx3JvegI0JnAYzMJpywGAndqE0DTmyl99SKRKIRSnRgJ1vq2kUf0IOrsZsW4//emcU35Ls4on" +
  b"qmqP3CUOu/il+Af1bfwz5WUpH2QeI3/XkiZakEzL8DOnTUVnPXW9Sam0Ic7p+eTs3vLe9QOpRbOyN5u81xvL7NmDCAlAYOlCE2EwYmZH3N6o8c7I" +
  b"CAUKr0psJp6343MwbT746AwP1MUE69cpQBIzTDWd7MqN4uPR56rgOcDE1je8xAddfQv33CPQbbjTZYpZnXdVTj2CeEuaTRo69pnvQ7HJhKXPgj4u" +
  b"t0j+1mbZIO4jiMyo8TYl20TJwfzkY37zocVVnxhcOUx698oA0yteCIDLV+bJ1udNb+POBO+4a/KmRfrZCWtr7MFw649z7B49iHiwHr8RXj2g7AxK" +
  b"slayUQmEIHFn2qByqEjM+4NV0oSmUEnN1xzuRhBjiRDmOJw6iVpHWy67DDiB0uJ1hQ3uzCMnOe8xZiOdM5H7+vD3Y5YWFNEI1hQD5PmjbGD793CD" +
  b"818+Dwrl0gkym4oQe4vO3myDHhQTs3jzcqMQHDpN9zU9X6piyicyyeAVjaV+XDLG2q4jprrbULkfdH4QDKZyyx3bCQdK2KgdaPVruchbs0fodT8h" +
  b"dchv+dGQi2iUusdDIZY3IU+na03hG9TLXhKurxHeuHQGBrETAdsQj/tNJUtg+WUNJJ74tc9eDkhaoADpuQdOju29Qw2ZIMCNG6bkCqyWVfT+BVsS" +
  b"1GcwUxj3WHYRuWCA0kLwqW3t4IK5x9wOpRj1PD1Digyrl6vxgkBneIQn1c4puA8am51mbmL0hxDFR/f9PbQSCZAb4p5yytFV6hZ4WJSuNlkhc+k8" +
  b"4Be8XqAwPiqodxcEHh48EekC+/3bxC9GWJectEEPODZgwOmAdQqTNE4H/9Of0AEoHpmW64FhRMNe0QZZpBUO4UDM+bgrgMEB4DiRPPY9ND8bII31" +
  b"rKNZMQAAAAFBmiK/s3Gwf3MuFLRFWJezBnhCk0PoCRdC+xq705fg18jWtZKVgjELKwQ+Zqzw7pL5hLzhfjcf/JT8IhGwgSJRAwrv9WYOA2NcsrNG" +
  b"12/sv0gY6AJ9r2FICixe5RH0Ic+/eLWS5QqX/nfnnDSs+4mJiUtesazjF+dBtj3CKZ2jEXs27Jg2LVFHTPiggvLRJujUmQ5hSTBCgY1tWd2VZeyb" +
  b"ZELO9w95ONn6/0BGyTFcwlQWSS9Yfa3dPBiNEGcbutBHACRahtZzQ/HUi6kro56irWh1csQXFUFsGMAJJsoEkb+uFLajnOlAQZx4Z0yxk7cN/1b1" +
  b"26kkkEglQGLzw9TaWi17npL+w7dFr9peAjkzrM6Tn9NbxlNIwmcPE7HTlKUqdYQC7wa1K3aC3dfvxH90CUmAKMIYgRpbV25sLUjAMcJyYgKO3OWr" +
  b"lS7QzwLLATbPnIWTsRlHaw7gssd2waFlv+ANpm8upTZ8qiaJup5JtpWCZwBg0x3fTtH78rB0AhKL/1R24OO/807W1vNLHCLXCX6/7eXnBT34mVYh" +
  b"+XLtmQM2iFvwYqSbDYRatRlqTpO5av+kQ0XDqU6WduWJM+RoW6ech2+WlxjEPXrN65vrH7lxRRWEfOh2O7lnaJOehSiK2M789Kkkmzq+kvEoyexh" +
  b"s4WYn20BeM433UeKaDc5Pmi/h25/eCBku32FR5ok3AjNGirqDkiCKyMS5LfUbc3gzXW7vgVqf4U4Jt47H1FAFN1Gc0wj18h9539zhY0c3QhcAHEQ" +
  b"c0agCsCCwnXDGMO6/TgB8QB3D9qAvxc6ZhdI+qHalTIOLgHg7RcjTD22zvlq8A4DF5qvCu00MFMbxNmdh95zO6YvrWzgqE75OqfYy4MBm6JZeFQt" +
  b"AfWim6W3VYQoAYN9XdPT8PmDuLiLRaJEI+bscHUunDzGY517CsfoGrcdGZF8OPgqDAf9su2mLvRH0CMVM80S4czEwG3bJMwbfpdfZg5Pal/axJb5" +
  b"fA5e2B/rsz18RSEnEeXPQOGZhXCqHhdRe7plEJFJSERQRJ1oKY+EJzo9rQFSAIIVLtcjuAqZmAAAAAFBmkK/t8cMC1IYSafefKle1z5nZYj4JwO/" +
  b"/ZonTb8N7bLjh5HHPPRnyzW0Y4NjxRPD61iuQnCyLbhdJejEFdHwoKDeZl4tPmiXBTzG3Aux7JHvaM0sA2gRlI3qLTlPNgl7EmAyLw6/Lzt1DZIO" +
  b"Eag3Orlfm0LapCgBdl3knGkGi/d3DzzUBy4Zj1zRnysSm51A86H8BB47Vxv8+/FZ/tCLVhABwIcUpDhyU2wYC+PECitNhs3qmpkMWbVvmW/G5WWZ" +
  b"TAc8t7CxfRkfVjq9opmG/2NHkBVJTlOzsv1GUn6uaYeKEtt35pENy5sxm+gN3IQ4EIbboJQdMTiDdhhu1j+ZzIUS8v2Qw4iNn4Ir+wkV1Q0mm3WB" +
  b"D4r66ArInasOgO2fe8jAcYOppGEOk/YDseFJOw1xOfi0ThqQ1+gKhJ18KuTg7CzeiL9n2Zu1lVX24gKRrL8X4+SfFsVWBpq+eJNE6xvEMR5DWAs7" +
  b"eY/Bi4bFORvr/dQRZDQBaJRLfiqSBUj1mp/w2gyGVncOF1B8vCJprA2HNuxSp+FANFJU+Pe4iazLx3yMGKQXdGGuHAA2N6ky+lRCpuTHyBpUmxzK" +
  b"PTM6qqbuxj+nxJw1a3mxzAcPYS9mK9EH9GmVnvg5hsZU8LuKTciPbb5Gyspu6ONnniDAzbBfGODgjurLCG1fapD7k8DrckYw4xsG21xZdJ5WQK5a" +
  b"+ab7o+kM5f6pLYd3KnQR7Yvgq+HZIJPHuHmRQV8XIsrii/Ud8INp2XpzYoQGpautuOtaZusteYEln84cjKzdeJwF8Bi42hZ5zOkHnVu5tX5HaW/V" +
  b"KBKE3y3A+kX+F4CFiMOt8xOoCA7jv4R2cXpVqa8ztCdAwVBP2x1ddxTq2/mFj/LdU+BDL1/3iu7Evt2Kdzjb4uHXD1YebHsRU5GQhz9YOxcrWBJ0" +
  b"kjq4dBcmiClotxgoeAuVqPzf8YvfV1CAPYqt52WCLiimhVCbjzcy5ns6kA+gFqbmKPSwwIxQwkeQ+3UjkRyyLU0JGwxmsHA+Q909TfsopImdwGd9" +
  b"rCevkcStQWyJJrmtAdEdAAAAAUGaYk++Q+9A2Mrelm6A4gn0grs1Kr0Qnf0CCth/VypmX2hkalXO5cGgP1CAByJ2WeYRTAmAzHfkbbRLpTUDlnMd" +
  b"nP0UX42oG2oKT8O4wzeZzq/8FguPDuXjP26n03/92z+ay0TEkax4+WLiqwUtR7QT9oZT18mfaYTB7zeFUXmlEcl18cxKolZmhBzKznsI0FN0vDV3" +
  b"GpMk1JzkcQkwm+j++Ksm+n5kcTBa17fhaSlozPX9qhX3qvRTpIMh9/1nwFWnm0DKxBATxqGBk6KdqpBcGxt9h5rtKz9DVW/TqL9/zmjzvdBW4f1p" +
  b"dA8G9YkVmdqHyLnXoPpxsw9TXiufgUge0baFn03+D3bdChexXHxd706VhG/WP1uZ2NqyFLn59fQv0Sq2JmXXoO2BPTkjnFuToq/y5k5OraOsdgOJ" +
  b"wYeIif02iXrdtXUDVS3DUFXWeqgtldtXkdrgqETJk7qYGgnG+yhTNwJ3iEck2O/owXcLu+ZtTgEuEiLUfDhDE63KHKYlxwXcQxOa7exEBOIMaNtU" +
  b"z1ixktcOckSEPBKqEkL76oQOSJdqwuKHok6GSSNVH75QxxFAoEH93iOZ6NqlW3GxDf1rI+sCKJpLYwOVKzvzqPT5dKgXvSFls/01mxQNvTF2NQJ7" +
  b"PsJYD4WhZfiQrlWAOHdM1/vHzj8b3HCe2UEZPKm+9cszK7lbaaRJ28HDBCvpr4k2XntY7IyXsspxs7RSIH9mlxmXHZlEUy7hMFvwO2hxY0GwDLaU" +
  b"Zz0HGCfjMqAAAAABQZqCb8eLWrxxBQ9D5WCzwk5/nT1f2IDev8MAgftajErsGg9lMRTxphuZhEgKEj5Jz/S4QVv9OGr9+XOSI22mjV67auxbQ13Z" +
  b"/3D6KV95cOeSW/2Pd03cVXtgEt//XEq16tQIodl0TtbYUOf7/LJ8bG/aC+HXWH3Y2MJHLpSgxgRS2XmADXDClGzuWhmS3EKfeyiNba7/25jmL8Yq" +
  b"uhwx0KC+fl7DsSvypjmeTGK+5yBKEqjOkTOCB9YvsnF2OvLqrI7pP16e82LmBuZan9uninaL5Qhz8Dl+4AARknUyLdA8lWH6tHQIxNIp4DefvlgQ" +
  b"hsxQIzHOSPYNy/7q+Ir/1heCAQXVc4seI3L0asu44lRnGhirYHl+DExg8g6c+bwSKsefaeitWd/UUHu3IfrK08q0g1bJSyxc7EAPm8xtKE13uaC/" +
  b"6L1rPiLdoaDAxYfsr+gYtFoDS/tf91G1FKi7iAJDoFYS1IU9eYdi1oqlpmfpw5p7+zyCs5zE22hiKCRX8D3rc8/UNby/kqwMSxTY6i4DM9FhIqIb" +
  b"aMttojAc7ihKaZcJ3dT8yRdAkYJfNoWV18xyCgYXSLaBVaaeqtC3rvf/wCDMutsPeMd8oEIqp638I2mYT8kNFUW6suw+uq5bdCg1gqTeNJtk2kiO" +
  b"tKmyafd6WgA0bCvE5WKO+w0+8zRU/UANbqRRinTB65TANRZLVgBnsNkK818l799QBX2wJpk+j2yIIkhG+2p+RkG2V4SmNrrPFAxdLqCxLBb8H37v" +
  b"ZlZeZkA5bLY0wQEPDhS16HgRLK7WJaYyDoE1sd9JUcvAzapZXwPFoGxrhiw77ttT0FfzKMp6uZvOWVysydPpKYqpQivglm2gNgXSt32eCLlnosRB" +
  b"j60xCQTW9h1dhuEAAAABQZqiK/9HXsE0eyWn/+bOBk5OtQE718G7RH5PRCbclWyB1DJwecxgELVNxSIdClZ/jvLL9teMwRjbjDjrqmJ88S/QpF72" +
  b"iiCg8KUyF8yx/NqyiXf7sE56Rgx7OB+Bp5l4QqTa2KoipP9728mKjDU+WXr6czwpJxIqy7qeeMQACQhz6tHxjx/WsVLITNbjfpY9Ol8KN1qeLwBd" +
  b"6XhHzzYHgDkub9LctoDhEjA3pnv8qJitvdgwJuQ4IqoYYsCl1iiYT3yDki9h3edhHbdnMD8I5twjnzpssNCCOTNm0w66v7jqyRZ7LWzc49CQxDQv" +
  b"Yr+jnP51hc2+pozW+GqBjzR61hkvjRJMm4iRl2ry7b72az0GO/MgVpabZGXwqgZxf0qApgSoc7YtNmNrX9/CwZ05FP9CAsiy3Wh3CIga9zMJafy6" +
  b"BFq9IXyxYgb/xVvDgwcAE7tRxPt9RpjBrOgU86vkOgb+gMsQNyloJvj8yFdoQzmruUMfRQOsYV6P8j3S8uREZznt0pTe56ofN29JgCtGL87eK/24" +
  b"fdZAnujK0vk4Gw/Zbcd5kGVgVR781eT2sq08oBvIKDkA5kBaAxv0+7ja4UizSsFXmypyyQM6NcbcZEPesGmsk5ZRlyw/I/qznktCCzGWgsrfWqnf" +
  b"30TbuIMGAkoVukJJqa6NG8GDHhdNzmlJoJ5OIkATSjgNdFOBk+ZFs2qxDXVxmJhmANqKEQ6vXNF530HgcrfvNZ1V7nQUgYVtMJ4fjVh13eMueSE8" +
  b"PVO0xsqew2+Isnm7ytCJb5Es+cf5pCsr3ycYYwSTIjPAct8OZz8krwlsg4D6mguTPThDhO0HORXOLtGBtYcNkbvP0vkdBEEnFmiVSkLbAzQwvIhk" +
  b"CftULZ5wKml2HUJ1BKhvYynTWR6YtiF3svz6CPSFnku155yeaDuJkbmeB62M5Za5x357+bHUwz3JujYLNJ9Xl0ib6UXDjv9rvRDAcSTLsGBptYcq" +
  b"vqGfvLVxY4wFdfLzRB0iLBV/BXJzfHYos9Pg95WzsvGxFwQtjpZGshJ/NYzJyAqyANwFqDjmJWXKYA5XSchtuzBCi4Vv9/RAx8E="

///|
let cabac_moving96 : Array[String] = [
  "74d1f78ce4086ad7e63394dfe6d5bea1", "318015e7739b7ee4ef5b9362a4bdb0ac", "0f338e63858f03bfd2900483ac56e2e9",
  "fd093b6529fff56c4e19313338d69e12", "0c3bfc337820a5f026b3976da1ecda20", "cb419e23a412b2d2a72d74ed69cbcbe8",
]

///|
let cabac_moving96_unf : Array[String] = [
  "8e2e3355b552b33e638a3099199d638d", "d5e1a816a79013c772305e39491f1b32", "8e42c96e7ba7e24cbd657386c66e5c22",
  "f3d15c7d30d9a5475184eef06d10b6a4", "cf8ce7198ca5f3cfa5c8d3bcf0aeafbe", "fa1c71e30a71e01640d6dcb765ae8b8f",
]

///|
test "h264 CABAC regression: cabac_moving96 filtered and unfiltered YUV" {
  let data = @libavutil.av_base64_decode(cabac_moving96_b64, 65536).unwrap()
  for skip in [false, true] {
    let frames = h264_decode_annexb_frames(data, skip).unwrap()
    let expected = if skip { cabac_moving96_unf } else { cabac_moving96 }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      assert_eq(h264_yuv_md5(frames[i]), expected[i])
    }
  }
}
