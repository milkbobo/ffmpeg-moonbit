///|
/// Real CABAC vectors for the intra path.
///
/// All five streams were written by linuxserver/ffmpeg:9.0.2 / libx264 with
///   -x264-params "keyint=1:bframes=0:cabac=1:8x8dct=0:slices=1:scenecut=0:ref=1"
/// (`-profile:v high`), i.e. every picture is an IDR I frame coded with the
/// arithmetic coder and 8x8DCT disabled. Expected YUV is FFmpeg's default
/// decode of the same file, one MD5 per frame from `-f framemd5`.
///
/// Coverage: a single macroblock, a row of 2 and 3 macroblocks (left-neighbour
/// contexts), and 2/3 rows of flat I16x16 content (top-neighbour contexts,
/// luma DC coded-block flags).
///
/// KNOWN GAP (see README "CABAC 的已知偏差"): streams that combine a top
/// neighbour with dense residual/I4x4 content (for example testsrc2 at 64x48)
/// still desynchronise from the third row on. The vectors below are the
/// combinations that are byte-exact today; they are kept as regression pins so
/// any change to the context derivation is caught immediately.

///|
/// `ts_16x16.h264`: testsrc2 16x16, 1 macroblock.
let h264_cabac_ts_16x16_b64 : Bytes = b"AAAAAWdNQArd7ARAAAADAEAAAAMAg8SJ4AAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAt" +
  b"IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0" +
  b"Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1l" +
  b"PTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4" +
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2th" +
  b"aGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJh" +
  b"eV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNj" +
  b"ZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9" +
  b"NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhDedjVMFWT1QMsgtmxFj/F6SFTvLg7GBZG5wEWQlyTys" +
  b"lXVehDMOJ/tux+EAChqYLzpAfAuZCOBGSrVAazbK6ftTQJov1mb27xZZTwnwq55U0Etz1hp89kCcu1j/8G4vz4SICQnjHIujTV/b" +
  b"jHpHe4T1fEh0sqtTU1p4my9HhmSGuRKn3uZkI2cKtDE57t9q3JtlhSKY0UahDzcEo+/XXXM40cVJ34SsI316UCfztyd/6umzpxk="

///|
/// `ts_32x16.h264`: testsrc2 32x16, 2 macroblocks in a row.
let h264_cabac_ts_32x16_b64 : Bytes = b"AAAAAWdNQArcuwEQAAADABAAAAMAIPEieAAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAt" +
  b"IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0" +
  b"Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1l" +
  b"PTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4" +
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2th" +
  b"aGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJh" +
  b"eV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNj" +
  b"ZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9" +
  b"NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhDede+mE7y9zURikqiYHQA2gSFTvLg7GBZG5wjY+wRnq" +
  b"PN6iTC0sreO7GbbQgwU5Bw5z4qkrgp+xun8tIpdrD70ACBBZ1GI6jIH9QoXHp7WySCgEdagb6184paFmMz74hJgvo6FgY0RXJSTQ" +
  b"+7QkFCer4kOllVqamt6bwbtSRaxqXSBkQ2IppmyGZ0N3IKveNLQmvK7RUsMNhuv+bqmEPFkA6s1Z9z2VelnZL+Ej4pEB2GnqotKV" +
  b"wboFgLQFHX3v5rDgcAHXJo04hkiPLC5lwC4ABfZsAV7jYHccAxwEShJrqK70jMTi+qLNj9guM/XPkmHsjd6RcXeLzTAO6B2JFHs7" +
  b"juwAk1SFOhJVYGQc3lju4WyuaFWGzxFE7oMTunTkfKrWmdHRX6iuC8MFAvDA6wUhyH5O5gDy4d+vOhvF7h9Q+K6m3C9PzkErZvAh" +
  b"zIRi3vJnYhsXiRKkJHEiDT24Lo544Q=="

///|
/// `ts_48x16.h264`: testsrc2 48x16, 3 macroblocks in a row.
let h264_cabac_ts_48x16_b64 : Bytes = b"AAAAAWdNQArc+wEQAAADABAAAAMAIPEieAAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAt" +
  b"IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0" +
  b"Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1l" +
  b"PTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4" +
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2th" +
  b"aGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJh" +
  b"eV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNj" +
  b"ZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9" +
  b"NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhDede+mE7oPRTckFs2Isf4vSQqd5cHYwLI3OEbH2FAlN" +
  b"g9q3nSebBzWOAxyqzo9qBtHVEm6SwUC4DZfMiHUQ8C45sdDZ4hp6bdXvN/Mdb4r7gxRbv2w5xTg5g4b0i3qG02LUw6BG4+1z0MsT" +
  b"FCer4kOllVqaowOv69QiBR7ZEakOSvfv8UyOuvBoCgRZPbv2rLdpkiPg3ps0sy9y0boke7LwBheoYvdTONXHkqila7PI89Jh4qY5" +
  b"/YBta7g5IGlA7DbMhSYjx3BUUBbH2Xa4C9IL5+vJZCZTbFZDb2uZC+jsdPj9gYvwCRtVMRajnW/5VbbKRmQiaP1kNrPvqm2lOs/i" +
  b"TuHsMaHL5f9JRxCGCLhwJH9TFsZpH8E+ClrTVP3OMdmnupWJgZHIp0j5KcDniBoPICzQ0XiqfnS0WY+xRDlK9AkcWGtROaaODB/i" +
  b"w6tfCIK9oYsfKF99daGsrV4Qi+om1mXAvJPZyr2eF0TSnFDG5ctRn00IokeTldDPo5aWznhO/XzHuoGl7b3sERi+UdozeTyXRkl0" +
  b"8FMj37zpFkw21pa0E2lYeZwPrbyiS8Hmxjbgpz6dLoqFm8xay2+GV830S/t9DYRLYOvGt4NRUFtMnC9Zf0tn0O9b4II+Xy8="

///|
/// `flat_32x32.h264`: flat black 32x32, I16x16 only.
let h264_cabac_flat_32x32_b64 : Bytes = b"AAAAAWdNQArclsBEAAADAAQAAAMACDxIngAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAt" +
  b"IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0" +
  b"Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1l" +
  b"PTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4" +
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2th" +
  b"aGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJh" +
  b"eV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNj" +
  b"ZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9" +
  b"NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhAS//vet34FNwys1a7fdt0/B"

///|
/// `flat_16x48.h264`: flat black 16x48, 3 rows of I16x16.
let h264_cabac_flat_16x48_b64 : Bytes = b"AAAAAWdNQArdewEQAAADABAAAAMAIPEieAAAAAFo7g8sgAAAAQYF//9U3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSAt" +
  b"IEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0" +
  b"Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1l" +
  b"PTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4" +
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2th" +
  b"aGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBzbGljZXM9MSBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJh" +
  b"eV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNj" +
  b"ZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9" +
  b"NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhAS//vet34FNwyszMHE4+Q=="

///|
test "h264: CABAC I frame (testsrc2 16x16, 1 macroblock) matches FFmpeg YUV" {
  let data = @libavutil.av_base64_decode(h264_cabac_ts_16x16_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(h264_yuv_md5(frames[0]), "8b8441ef68c2962b17b4bc19590b968c")
}

///|
test "h264: CABAC I frame (testsrc2 32x16, 2 macroblocks in a row) matches FFmpeg YUV" {
  let data = @libavutil.av_base64_decode(h264_cabac_ts_32x16_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(h264_yuv_md5(frames[0]), "f66ddf5fd1ac674a165d461ee7f0aaf1")
}

///|
test "h264: CABAC I frame (testsrc2 48x16, 3 macroblocks in a row) matches FFmpeg YUV" {
  let data = @libavutil.av_base64_decode(h264_cabac_ts_48x16_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(h264_yuv_md5(frames[0]), "de69b6c2f8ef493fd0192678b3d90ba8")
}

///|
test "h264: CABAC I frame (flat black 32x32, I16x16 only) matches FFmpeg YUV" {
  let data = @libavutil.av_base64_decode(h264_cabac_flat_32x32_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(h264_yuv_md5(frames[0]), "1386fbf9bcbef3bc8576923d932dc1a5")
}

///|
test "h264: CABAC I frame (flat black 16x48, 3 rows of I16x16) matches FFmpeg YUV" {
  let data = @libavutil.av_base64_decode(h264_cabac_flat_16x48_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(h264_yuv_md5(frames[0]), "1d193c2e6029eec06e62e26240354b28")
}
