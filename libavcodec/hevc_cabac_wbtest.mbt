///|
/// Tests for HEVC CABAC initialization and bin decoding.
///
/// Payload: the first IDR_N_LP slice of testsrc2 64x48 (x265), RBSP bytes after
/// the 2-byte NAL header and the 2-byte slice header (header_bits=27 plus the
/// alignment bit). Slice QP = 26 + 0 - 1 = 25, I slice.
///
/// Reference from FFmpeg 9.0.2 C: states[7..9]=1, then 64 bins at ctx 7 and 16
/// bypass bits decoded from the same payload (compiled `hevc/cabac.c` +
/// `libavcodec/cabac.c`).

///|
let hevc_slice_cabac_b64 : Bytes = bcat([
  b"VflF5y7OcyG+teyPJaldGQcP6xviHBVdIYp0c/eOT8elckfyga8+xgTVOxj+zzXqChMYJIS+YXX2HpYorwFavJcx/ZTbdcezIYoI",
  b"WD///xTMhgjVphPjnEHcRYZyOmEbcz8rPLwX+j1hyxNx2+pELaBRCcBDt6PDAqofNgxpPy1Pt4ullfoaDlbwzHwcl9nv1YQYCi3A",
  b"L48UwsAV09J9EHHBjnIZXZXi6kP2KzZU+naAUApNm1aFGbDTA18fHDlTN+7UH2iiREu4yHgx56ONpdttpjMhya2GKoorxs1KdEN4",
  b"OIhNY1YGgY1Gz/IPcArNMghg48TqTqcQ/NOdmFv3k2tiR8w0H5hch8CbqNaQ44ZMZAh/FjsbOq98WFdFpEYRs+9+nUK6MnJFJNz0",
  b"GwS5a9B6NHm28NjuypGu24msahlzR+qPOOEHlPfyu0CH6JBbszc/CISpxYTE+K01BiolRNp9NWdUHsNb1jjviGUUP1xiW/ZacuEi",
  b"Rg9ySQcEjFsAaDTvhAlP5lCUHRYJR41VVph7JoKcqmKfkrAaYW91wpnp99a04NNQCRBqrUmoau7PNtsew+k7zmxPq45+vesMBECQ",
  b"FIDbMKuQpxFX0hn8pC/jlgf/3ZUMfA9bzkSGqaa28NkT+YHzNUFJmCNY+nazS4FD1Cdczs7CuBVoPoQ7K84DHokOLjayORABXoRw",
  b"yqckaMNpWY1AaqOhX+cHhmKFFGvRLSKOQfrpNWHX7fpUdDl3pQ59nVy767kOZkeC/6IHTs/FVnbLWy66yYzG5OSPcZs+oexWJIIG",
  b"1oS3JIyWIQ8gi2QVF7uOge4dUY6Kqwdy1ymcVvsjU+GHhckYVGKDMy0el1jhWWqY6vlmdGBYdW9xZp0m5PUJGT5T8ZqW4oRxqYP0",
  b"E+y7aC2eqBaF0CjZTA13iyHTKEHtqrGqbm8T9tJTDQTuWjdA1CkAMMeDYZEYlfxHxSIQoVosXEZC0WXvNQoOjMCEyF+wWUV+FjEE",
  b"vPfkeIy3XZWEH5aDS2MJ9Xc84PRV5uz0371iCIYvwdXGdW9Ihmrd1KEmkIsp3V5tw7TEAsIFh2958wcIm7yhWVPxkHHP2gOausYO",
  b"3MvCgdXeb/c6Gg==",
])

///|
test "hevc cabac: init states and real slice bins match C" {
  let states = ff_hevc_init_cabac_states(25, 2, false)
  assert_eq(states.length(), 199)
  assert_eq(states[7], 1)
  assert_eq(states[8], 1)
  assert_eq(states[9], 1)
  let payload = @libavutil.av_base64_decode(hevc_slice_cabac_b64, 100000).unwrap()
  assert_eq(payload.length(), 835)
  let cabac = ff_init_cabac_decoder(payload, 0).unwrap()
  let bins : Array[Int32] = []
  for _ in 0..<64 {
    bins.push(cabac.get_cabac(states, 7))
  }
  assert_eq(bins, [
    1, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0,
    0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0,
    1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0,
  ])
  let bypass : Array[Int32] = []
  for _ in 0..<16 {
    bypass.push(cabac.get_cabac_bypass())
  }
  assert_eq(bypass, [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1])
}
