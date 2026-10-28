///|
/// Raw AMR-NB demuxer tests: the `#!AMR` magic and RFC 4867 TOC bytes are
/// parsed by `av_amr_open`; 4.75 and 12.2 kbit/s fixtures (see the encoder
/// commands in `libavcodec/amr_realdata_test.mbt`) frame correctly and the
/// 4.75 kbit/s stream decodes within one s16 LSB of FFmpeg's PCM.

///|
fn amr_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let amr_4750_b64 : Bytes = amr_concat([
  b"IyFBTVIKBOf3QL/jafSNoWSOSATZyK9t0Y6fPfkvj1AE85S2q+GpTlSprMaMBPPItq3bhOLNUYtQpATz7Laqtap4KMcSqCAEj8i2rNN7ZTelAzmABPOUtqrh6e5ghRqTMARUyLaq0YmurHEsmiQE8/e2p7sFEuzQKhDqBPOUtq6l3ujsk4yWMASPyLa603/VLHkED2IE85S17dGKv6AgMtoQBFTItqqR+Y8UW0BKoATz97arqwQyqKtKChwE85S2rrXaaMqjtXLOBI/Itq3TXsU1vQUoVATzlLaq4au+DGErHZgEVMi2qrGI7qiwPRAqBPP3tqurhzLQyAwAPATzlLautXpY0uuhBdwEjwgvXjgdkuj4oQew",
])

///|
let amr_4750_ref_b64 : Bytes = amr_concat([
  b"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",
])

///|
let amr_12200_b64 : Bytes = amr_concat([
  b"IyFBTVIKPOGA+Wh/ccXs7G+b9nN3VUAAIBPNiFcsAADFE2D7MyA8BlAdbn7cJY0jhAuTkYKARICeLbQfoY/VpE4lsHXPcDwPgBRmfmRTq1TXG176SsVdp3kLauxR60AW1ppGQY3QPAd+EWZ+d8oh/4Bq4x1utsw9g85cahD0sCv0N9rAheA8CXoOXn5/5fhvgetJYhXaZS5KjQ+ZucDjWKmEhg9WYDwbf5MGf4nerbOE+/xCT41AJXA5qYXWO2IkwYFObcjQPAl/sWZ/gD3tO4BruK3lakYIeJZRhB4VmHKDMo5qVbA8B3rcZn41LE05gqvhPZ0GVGND6AR/tIiWzsxsBciAcDwJfg5mftXliXeEalkx6sPEA59MIBmYDq24i7wF2fnQPAd7sV5+b+HJdtVr0Kpd3FHm5tMabAgAYTtmx1RjzaA84X7cBn7V2sn5Lvvbcj5IdUHYIEqrOHYjQLHHxQlDEDwHfhNmf5nsEO+Faw1VV0pCX0kMiBcBjlCrobGwWY1wPA96E2Z+YWyJfYKrjG3LHnG6+zsB418VUYZ08CvCfrA8B3+xZn+B6El3hGqNoOXf/Fs/P1IQaxQf34hAhHyK0DwJe7FefmHkqXOJaw3LkJdwGKfvuqE1z0kIERTV1bpgPBt+3AZ+3d+awS77fnotyUBn8BhEbAGDEibih2MACzA8CX4TZn+G8ctVhes0A4WJYDsRHYKf8x3Q3OqqNpFZ4DwHehNmfjMszRrVK4Ar+0REQ2uGAow+pbMSLxzBDKzwPAl/sWZ+1ewYY4Fq3zEl1OBAkw8i/jVmEbdbYUYlQLA8B3uxXn5v4Yl01WuyPsHzRaQzTBZIyxABY9LAsELM8DzhfiA8VYkRGIABGs6uMiPiAqAYAhgzATm4CgD3QvgA",
])

///|
fn amr_decode(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 1000000).unwrap()
}

///|
test "raw AMR-NB demuxer: header and frame splitting" {
  let data = amr_decode(amr_concat([amr_4750_b64]))
  let track = av_amr_open(data).unwrap()
  assert_eq(track.codec, "amr_nb")
  assert_eq(track.sample_rate, 8000)
  assert_eq(track.channels, 1)
  assert_eq(track.frame_size, 160)
  assert_eq(track.frames.length(), 21)
  assert_eq(track.total_samples, 3360L)
  for i = 0; i < 21; i = i + 1 {
    assert_eq(track.frames[i].pos, (6 + i * 13).to_int64())
    assert_eq(track.frames[i].size, 13)
    assert_eq(track.frames[i].pts, (i * 160).to_int64())
    assert_eq(track.frames[i].duration, 160)
  }
  let wide = av_amr_open(amr_decode(amr_concat([amr_12200_b64]))).unwrap()
  assert_eq(wide.frames.length(), 21)
  for frame in wide.frames {
    assert_eq(frame.size, 32)
  }
  // AMR-WB is a different codec and is rejected.
  match av_amr_open(b"#!AMR-WB\n\x04\x00") {
    Ok(_) => fail("AMR-WB must be rejected")
    Err(_) => ()
  }
}

///|
test "raw AMR-NB demuxer: decoded 4.75 kbit/s matches FFmpeg PCM" {
  let data = amr_decode(amr_concat([amr_4750_b64]))
  let reference = amr_decode(amr_concat([amr_4750_ref_b64]))
  let track = av_amr_open(data).unwrap()
  let dec = @libavcodec.amrnb_decoder_new()
  let pcm : Array[Int32] = []
  for frame in track.frames {
    let start = frame.pos.to_int()
    let bytes = data[start:start + frame.size].to_owned()
    let samples = dec.decode_frame(bytes).unwrap()
    for v in samples {
      let q = if v >= 1.0 {
        32767
      } else if v <= -1.0 {
        -32768
      } else {
        (v * 32768.0).round().to_int()
      }
      pcm.push(q)
    }
  }
  assert_eq(pcm.length(), 3360)
  let mut max_diff = 0
  for i = 0; i < pcm.length(); i = i + 1 {
    let raw = reference[i * 2].to_int() | (reference[i * 2 + 1].to_int() << 8)
    let want = if raw >= 32768 { raw - 65536 } else { raw }
    let d = if pcm[i] > want { pcm[i] - want } else { want - pcm[i] }
    if d > max_diff {
      max_diff = d
    }
  }
  assert_true(max_diff <= 1, msg="max diff \{max_diff}")
}
