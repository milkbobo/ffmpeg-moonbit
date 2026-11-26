///|
/// FFmpeg 9.0.2 encoded the source tones at 48 kHz. The unchanged
/// access units and codec configuration were wrapped in CAF chunks.
fn check_caf_variable_fixture(
  file : Bytes,
  codec : String,
  channels : Int32,
  samples : Int32,
  priming : Int32,
  bits : Int32,
) -> Bytes raise {
  let demux = av_caf_open(file).unwrap()
  assert_eq(demux.priming, priming)
  assert_eq(demux.packets[0].pts, -priming.to_int64())
  let last = demux.packets[demux.packets.length() - 1]
  assert_eq(last.pts + last.duration.to_int64(), samples.to_int64())
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, "caf")
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.sample_rate, 48000)
  assert_eq(audio.channels, channels)
  assert_eq(audio.read_error, "")
  assert_eq(audio.duration_seconds, Some(samples.to_double() / 48000.0))
  for row in audio.samples {
    assert_eq(row.length(), samples)
  }
  if bits == 24 {
    assert_eq(demux.format.bits, 24)
    let pcm : Array[Byte] = []
    for i in 0..<samples {
      for row in audio.samples {
        let word = (row[i] * 2147483648.0).to_int()
        for byte in 0..<4 {
          pcm.push((word >> (byte * 8)).to_byte())
        }
      }
    }
    Bytes::from_array(pcm)
  } else {
    let wav = audio.to_wav_s16()
    let demux = av_wav_open(wav).unwrap()
    assert_eq(demux.data_size, (samples * channels * 2).to_int64())
    wav[demux.data_offset.to_int():].to_owned()
  }
}

///|
test "CAF aac against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAGFhYyAAAAAAAAAAAAAABAAAAAABAAAAAGt1a2kAAAAAAAAALgAAAAADgI",
    b"CAJQABAASAgIAXQBUAAAAAANqOAADajgWAgIAFEYhW5QAGgICAAQJkYXRhAAAAAAAAAXkAAAAA3ABMYXZjNjMuMS4xMDIA",
    b"AlyjU5E6aw6QgtT+jqfPm/XHlkktIfEWn/8Lkn/0E9O7VtPVuqhAhAmjLJSECqebV6byf+DSJlUmSnUKyUmjJQpQMDAwMD",
    b"AwMDAwMDAwMDGzZtEiRSyyyyykYgLui49h4FEx7Du6JdsPAoVixMCg2LDu6DZsKzoNmwbGgxRRRRRRRcABGpTayl2WS6sl",
    b"1ZTp//e/8/jjTx1Nb//sf9fv1rri9fx//U/7/frXWta/v//Z/064vjWtCJd25tBISElXTnKc92TdPoSYogIgyIc8RAc7Io",
    b"gPpz8YgPp9IouIA+nO38ssQA+n054r2E57QBYU+mDFEYRGZEHoiAeHGIDne4xAfR75RRAD6fRny4/IAfT6QfUPsBkPDw8P",
    b"Ph4eHh4eHh4eHh/AARaVtkvyJDsO37Pir8fee491+OB/N/iDruUH333weF1weF4XXcoAyyyyAPC8LwvCAPC8LwvC8LwgAP",
    b"4/x/iBwHBha3QAAAAAAAAAHQAAAAAAAAADAAAAAAAABgAAAAQAAAACAIESgSNA",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "aac", 1, 1536, 1024, 16)
  assert_eq(caf_md5(pcm), "ca0b69d18634102747884e90912ddcae")
  let packets = av_caf_open(file).unwrap().packets
  assert_eq(packets.map(packet => (packet.pts, packet.duration)), [
    (-1024L, 1024),
    (0L, 1024),
    (1024L, 512),
  ])
  let corrupt = file.to_array()
  // The last packet length now signals a continuation beyond the chunk.
  corrupt[corrupt.length() - 1] = 0xC0
  assert_true(
    av_caf_open(Bytes::from_array(corrupt))
    is Err("caf: truncated aac packet table"),
  )
}

///|
test "CAF aac-stereo against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAGFhY2wAAAAAAAAAAAAABAAAAAACAAAAAGt1a2kAAAAAAAAALgAAAAADgI",
    b"CAJQABAASAgIAXQBUAAAAAAO8zAADvMwWAgIAFEZBW5QAGgICAAQJkYXRhAAAAAAAAAV8AAAAA3ABMYXZjNjMuMS4xMDIA",
    b"Qk2QAP/hRMmhkvREInioqjUkuS5JbxlwM81eODOzs7OztWVA8n+YvEyEmOHU888888888888888888888888888888UUUU",
    b"UUUUUUUUwmNGrOazM3v9P19pLkuSXt/gp3SJEiBxxxx2rbb2GWWWWWWWWWWWWWWWWWWWWWWWWUDA0YGGBgYGBnIUhsnE5g",
    b"AFQPGmyXFkeA5f1/8/v1OGvf/+f/v+OuNa9v/9P36u7glcfB8GxcnEi+dC+JWjFDFEZhGehM98hQOd75cTD6PfLiB9Ochw",
    b"TgRDfcyIgikE40A1Hx/i+P8T+I/j/EP4/xD+P8SNoldVkb6sjSQcv/7P8/frTy44//rf8/frjH7//6f5861xoRutRG164g",
    b"6P6eGzsiMvdZrooECACEiYQiQrpVj2GAQPif4P8H+P8B8/nwfA+fz+PgDiFA2kYIwcBwYWt0AAAAAAAAAB0AAAAAAAAAAw",
    b"AAAAAAAASAAAAEAAAAA4CBFoE+Bw==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "aac", 2, 1152, 1024, 16)
  assert_eq(caf_md5(pcm), "af1ee4fc9f081727f5df790e21eba0bb")
}

///|
test "CAF flac against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAGZsYWMAAAAAAAAAAAAAAAAAAAABAAAAAGt1a2kAAAAAAAAAMgAAAABkZk",
    b"xhAAAAAIAAACICQAJAAADHAAECC7gA8AAABgAw6afhmGM169lxIZLTr/uoZGF0YQAAAAAAAALNAAAAAP/4KggA5k4AAAIU",
    b"BCEGGgf6CbYLSAyq5ixvt0gT6/PYcX9rwQR+9gAJhQoFwImgWUKcNChgUKUCCARAjCUyhQyhlJJSRA0CyUOHCIQggEQKHD",
    b"koSwkQoRCFMnhEKSYUIRAoEEChQ5KTOUoFwIhSFJ4EQw4SkOGSmaFgU5SETChQ5wPDMMOQwiYUpKHCk4RDPCk4UmSZCkKB",
    b"YUKGchElDCIYcPDwPOHmTCyRCkocklJKBZgRIUDQkQKSU4RCksAgkkqBThECIFhShTKSSgUwpNAicKUPChEMOGFhMiBIhJ",
    b"SGZwoRDQkQkQygWclISIBkQySIGTMIgRDzLCJAiHMlgVADWP/4KggB4U78af54AI4CogSpBp0IdAom5ivutiwgh+sgP9/F",
    b"QMo/EIAHJmHJQIgchEOBEhZQpNAIoBEkQoZMyEQCJDCJAskIhhkoESESkoESShSTkwyTIUJEDOSEQ0ymWSmYTzCIFMOQiB",
    b"Q5NhyhQiEiBpClA8ygRAwpJhQoGmZMoRIEYEECocJZOSUCIEECUlJmWUoRDkiBEKGhJQKZhSSEQJTJkplJmFmBUOHCUMhy",
    b"SgaQiHJTSEQpKFJkoZyTDJkCIUDhEkpzlCk5TyYZhKQ4dDwKUhcKGIUCwsymHhmFIEQhTJQOZmESaAQQCMMOcMoSIFChMo",
    b"FMLDMoRAIgzuz/+HoIAgF/fk75Afrw/PT/BgEdAy0FMQce5jAxkmqRTynxfQ17I1O+BQQkTCZEwhgQYIymq6TFxMsXFJIW",
    b"iwmKSUliaxNJk1KsQxUsTFQpAYEEAIhhmFAggEBAIzsiZTKZQoYZDAiBhMlA4c4RNNNCzKYUJkMSWEYLRUiolyuqYnQgwI",
    b"MLViYpSLJRKCMUpYjCZMqqrWIYRiYjCMRhMUKKKRJgjCyUkstMTTJqpayy0liYTIookWJlRNRGJqqqky0smSRMIOVQcGFr",
    b"dAAAAAAAAAAkAAAAAAAAAAMAAAAAAAAGAAAAAAAAAAAAggKEQIIAhECBR4MA",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "flac", 1, 1536, 0, 16)
  assert_eq(caf_md5(pcm), "30e9a7e1986335ebd9712192d3affba8")
}

///|
test "CAF flac-stereo against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAGZsYWMAAAAAAAAAAAAAAkAAAAACAAAAAGt1a2kAAAAAAAAAMgAAAABkZk",
    b"xhAAAAAIAAACICQAJAAAVmAAWZC7gDcAAABIB+XboVIM+knwnte463vn80ZGF0YQAAAAAAAAsDAAAAAP/4KqwAqk4IUesK",
    b"KPIL0UENQ7EOehEPb0IQH0kQh2PlmwS67Fpnpjhof3FA0v9kKGlzMXROXHR6KRQMxgNhiMhaKxGeGpYQOlqJN08zKay5vJ",
    b"LJpZLZdLJXKJDd3FXTe9+rIsbviowOjwSiYWioViwTiQZ8dGRUQuF6dNs7f6mruriQyKSyWSyWQXtvZ1NL55asKdk7IBlp",
    b"acHR+IRIJRAIhAbmpeTv3S1SjzdO9DT11lb3V3e3l5dWllKelr9v77JAiUOCI4NBUJhoLh0MBkLhEfGRU0ZeXTY8o3rkyi",
    b"nsK61sbS0r6+pqf/7tw05Mapc4dvyUrKi8vMi4wLCwmJRWzxAkqonxQp2rUnJTMvMzMzLy8lIW7VD/nLFV54sZPCviYqJj",
    b"ImMCYiIGzRMg4ygizvQpU7VyzI3JG5ft269WlI2ujCeFkiRQweEhIYGhQYEhI4WLPKKYxWv0WXyJMhM6VNmS5dsuumvm9Z",
    b"assgw08SeLOFniDBBJRDw+RdL1qT0i2i2iXltJWm11eZyGIK45TBDCMMbEzSLlqqvX1dlE4nCQQzCDUjlVmVsLhqX+S9pf",
    b"npWv92qxSinHEUaYceaeaaWa0tbkJXv/rarJdkuTKvl3WyKKpP5nTHkmCBIwYFDQoIChw8cLFHGvchHu32TZUTEStXbl23",
    b"Zt1a31LbrFHlh8oTOmBI8Knxk8LHhEybJEXCd71wp+avY/ePTf34QAAZ/4CcQICUqzBscx8s1eXW4x08FIVe+LIJf/mtBL",
    b"QlYI24S7pGmXDepSitdsb4SOylS1y/TEzEy9y0SfSNXftDV6iHf7XiWfM69BQDCnMEJE6FmGEGbGdGhGQFyFVEcPUacrJE",
    b"W4WFCVR6r/qqWavJI/KlL5M1NXNpNdM5MDKvJLei0VW//7LT8HWVwyKFsNqIEJoLeMqNgOIOKOGNQMaLAJWeo0hU38aRQ0",
    b"U3n06W18ujIhKlL/NTOHOlOvOPN1MVLNJReezdRv143N8wYt7SiGaPQJWLSMyN4OwPOPCO2NyMyLMJSeQyhQ3gYdI1A6Cg",
    b"FWLZX6k/l8mrnNnmnwntnbnEmVlkkkuzYyl3p7phWot6RMu5wxGBVBlBvB4x9B/B+h4xxBmxYhHDrF+JG4yuoCt/kUusTd",
    b"qSaWyZ+c+eyIBEDn8nknEmTlZkVuJXCiHZ6PjTAPMUQ0J8BPxfBtR3h9whwQgIGPOOCMkKgIabgsJAWfTZKua/KsFq5CZT",
    b"ZjJwJ6IgUQ6IZEBnkm7mFlHvzampv18TkGjNeQ4uRxxGBYRnRzh8whQRYIcEBHfG3F8E6PkZMoTqryhaseHSOwV2JJ5b5p",
    b"p1Z+ohkROIdPxOxNRLfJVdqwtJPG1nBl1dYnRlj2CcC8jcDtBBAhgRkIKPwOcM6LII2cguhE2vUlHeG+qpVpr9SgTETbTx",
    b"xAIhcRKf6eub6ZGU6QW29V//5TNM3ZogZWTeiBCrDEDjjxBAghYQofkd8bUXwUM+BpiiPUwSOqP1lEa03FkPlamOnDnjn6",
    b"iCz+z3TmzRS1SV3ZsdSz0tpwjXm/JIXk6YjIsIy44Q8g/A/A/g7I4gyArIixyS7kYb1V0L2z1aT2MurJDLFMlOFOzPfPbP",
    b"HOnNRL9KBf62VWaC9BoeQMG8BPDKHdEtFdGaG4HXHgHnHTHCGWFqEtPOZ0oz3samSZcd91RbLXnkjljmLm0nHnVnPnGmlm",
    b"ElMkYuVYSl3q7zjmiM+/hTDSHiEtFZGOGmG/HFHCGuGXFqE9P4bkthGHFWVEFV6WgtUbRXkkjlUl+mbmrmympmbl6lSkhv",
    b"HZ2qlAer1XB1dbghRWDSnlEcFQFwGPGbGgGXGDAEUN//gqnAFUTgJ4TYKPMQHrDaFCzyDFJ/hys6BAZfgjJ9jlmwC6ml1v",
    b"m9B8n1SA8v9SJIq0DpeX7aUrCz7nvuSEkpSSek7JaQ973HYtWUX5uLosOqWa8STK0zzfPcQgkhJibEeI8+jxNIwihIZwMJ",
    b"OobVcv30XVVh2xdt8SDkTIiQt+Xhb1l1lS367e1zWMVbOdpEFSXBsG4ex8H6fh+ngchrmAVRHvRqrdKonV8b1/2oKxse1r",
    b"kuu7bzui47ZsWt6cof1c/YZLGKllN8gySK0vTMNg4DnOE4DaHE4fBtFgQDMT21WSuShVq7yPMc2xAiRFKKcVYoxLn+cJik",
    b"672Ki9+jkMRAKZwP4sjGO49BKCMEoJA+jyNQriYcy6SHFRQ2Hwp1hukmSlNE1zzOsQJxnqY5jk6QLfWKN26+EqOJELBuPY",
    b"nCuMI2DaNo4jOMQsCcejcWiM6LSQn8X1SLDa77JUoS7Lcxy/L0qShIV5s9YonrvZmSsuT8UzIbj+IYoikLIqCyOSxQPh5N",
    b"BbJT2zqyIob/pQKtXLdeL1JElSRJckSDfbjZ63S//v2M/FVmh2IhWLhvNwgnsRhEEIQD2czUYCkR3dmXEVD3eH3otLsNhu",
    b"Fxvl3kC63q5Wez1Kn/vpvbGBjrrO7EcnFwxnA3Hw6nw7nU5GYxlUlEJsaFBHSdrk+KBUKrabJdLjerle7bdLBY6fTvjv5M",
    b"vHzltqdyOUS+YjkO5Hc/Ho+HM7mYzFUmEBvZU5HT9zp/aNU7Fabde71fpAvt4utssVZpX92cWZhKLI5kMoF02nA/iEIolC",
    b"OI4hnk6mYukx/blxMSNfq+adV7Tcr7I0lyhKEnSdIkg3Oz12kfPRq4GiyvBJLZpPIgCmKAwCwMQriwJgkHU2FYlubAmI+9",
    b"4UetWi8yZJ8vzBNcyTPMkqypIV4r9X+ujSxFpzIhdN5O9HUl8vMr8a3x8Ktk7/A273/O71w574Yc5Zlsve5vQ01hEb6HAa",
    b"K/ICCOcgiYLAuzRNQ3zeN42TLMUrScIZ0tJZpRC6jg+H7UnUtc2Nals29blsWfYlY1FQ316O+zOA0K6bbyI0oi1MY0jZOA",
    b"3jcNQyS6KgkH43mKpkSltj0PRQ9MVhX1m2tbdwWxbFjWDVFMfzz8jW4/HK1kuV/EuVRemYahvG6cBsGgYZZE+QzwaS2TaH",
    b"z/B7f1o6pK2sa0Lbtq4LVtOxK0qOi/t199n8FnF20noRBPlsYRpmucJum+aRnFuVpJv1yMVWIlHbPkev+05VVf2Xa1tW9b",
    b"VsWRYVUU7/fXzNhlMYqGK5HySxTl6Y5smwcZum0aJhlsTpGu5tLdPoTN8Dq/WiajrSxLQtm3bctq0rGrepKP+/b4egwuXW",
    b"zTdxCk+WBhmcbBwG6b5qmYXpWEu/3MyVcjUZrOT5f9S1V11Zto29bdu2tZlhVbTlCevo7HM4xQMlsv4jSrLUzDQN82zjNg",
    b"0jILIqCIfLVYKfQCZ3PU+NDVDWFi2bbVt2/a9rWNXFUUj++7xdNicusGk6CGJksDAM42DcOI2jaMsvywJYh3Kz1kj0NrOH",
    b"4/1SlT13ZFp25bdwWpaNf1nTdF+ns7LN4RRr1vvMkSiLkxzRN03ThNo0zILYqCMfbZYaiQyZ2nT9tCU/WFg2dbFt2/a9sW",
    b"LX1TUt+/FydRjMir2a5iDJYsC8M41zcOE3DcMoxisJ4hXU01gm0Xo+F4PtSVS1vZFpW1btu2vaNhVtT1F/HrbrO4JPL1rv",
    b"UiikLQyDON42zhNs1DLLgqCTfLgYioQ6S2vM9dB0zWNeWfatt3BbNrWTXtWUrQHl5OvxuNVjIcz+JUrC8Ms1jdN44DXNEw",
    b"C1JsjHW11mnUPnuH2PvRtSVtY1o2xbtvWvadhV1TlJe/ub3QYHOLdrvAiCgLMxDPNs3jfARGNwYWt0AAAAAAAAABwAAAAA",
    b"AAAAAgAAAAAAAASAAAAAAAAAAACKZosZ",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "flac", 2, 1152, 0, 24)
  assert_eq(caf_md5(pcm), "cb86a80b4f529008a535d161aff4fdb9")
}

///|
test "CAF opus against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAG9wdXMAAAAAAAAAAAAAA8AAAAABAAAAAGt1a2kAAAAAAAAAE09wdXNIZW",
    b"FkAQE4AYC7AAAAAABkYXRhAAAAAAAAAIsAAAAAeIKHU6b0FR2HuvBj+V3f5keRPdJjnRB22oJrGUlJP2SX9M/A6BVSQ7O0",
    b"h0xPh44bYGXyzAOyIYYlrlfqB6lcwUffJnSZZne8+bFOfy0gIC2wXnieJUGQdqQoMkdmgNawdMUOLv/qOhAX/8I1uhWcPk",
    b"kPsBmR9wMafyhovHR8HbFOMHurAiIhcGFrdAAAAAAAAAAaAAAAAAAAAAIAAAAAAAAGAAAAATgAAABIUjU=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "opus", 1, 1536, 312, 16)
  assert_eq(caf_md5(pcm), "cd0675313f4808bbb03264fce0b79e23")
}

///|
test "CAF opus-stereo against FFmpeg PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAG9wdXMAAAAAAAAAAAAAAAAAAAACAAAAAGt1a2kAAAAAAAAAE09wdXNIZW",
    b"FkAQI4AYC7AAAAAABkYXRhAAAAAAAAATgAAAAA9H4PJQG/bcVVS3j9HVr1W0NwqsfKWWTCiDAKzKEuNeINOSQrVg69e77E",
    b"bZkLD+XTMrUQDHgRqDAljC47lwBmtSTxsbCHnQnEorD+QadURvpn31J0rXAfVQlxtm0BQ425sNOjxN6GWRl0DfkZtIWhOJ",
    b"YJoHF1I9OQsMeeB/uuB/jNBXN6ocLdinPRN59s9joBAAPDRE5vbuW8Ux22aa6JThtxdVOhtcy1mcogqp5ZLy+KIiSwfN7a",
    b"zGbfTypRH7cMbPgUK+fOrE1n1CFHPpKzi6mCMzXnffJ0qnuY+78l5hRGjHlQeHCekpt2OdeLR9trp1TZlM6tW56YjlseCK",
    b"08cZkMgab9s++lgK101wN0BU3b+V88Q+sUneDMKIYLWuFXRvrxLG/9RS74OcCg2EEtluWy1QtwYWt0AAAAAAAAACUAAAAA",
    b"AAAABAAAAAAAAASAAAABOAAAAchTg2CBBINgNoNgJ4Ng",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  let pcm = check_caf_variable_fixture(file, "opus", 2, 1152, 312, 16)
  let reference = bcat([
    b"SwOyEVkEfRGhB6URvgsND6APXQ0sE/4MghZBCtsZxglgHF0IJB4aBq4fHgWgIAcDsyCKABcgzv4WH+n8mx2x+X4b7PbIGG",
    b"b1pBVc80cSMPGfDvXvlgof73EGtu5gAtfuLP6D7ub50e7Q9czvAvJO8HjuGfEr66/yRuge9dblFPfb4/b4UeKO+yPh2f1/",
    b"4JsAZuDzAtjgywTX4dEGOeNsCA3lCgtO54YNDequDljtww/l8MoQkPSlEXb4FBKY/OERvgAwEcMErRC0CAIQmQxhDlYQag",
    b"yjE0IKgRaDCAUZwwYdGzQExByoAe0dOP+bHhf9xh63+nkePfjFHTr2hhzO88YaMfKEGGzxyRVU8McSiu96D/fu4guq7hkI",
    b"te40BPTuMgCz7xH87PDw92/y9PP38yzwp/Wi7Jj3c+mL+bnmd/ts5Gb9guK7/w/hcgIn4JME29+GBiTg3gji4GoKOeLuCy",
    b"nkyw145t8OPOkdEIPsAhEy8BoRF/QLEQb4wRAi/AIRWABnEIwEjg64CDoNpQzZC0UQRwqdE4MIohZuBk0ZaQSEG/8BQx2G",
    b"/4UeTP01H+n6WB+f+PIepPb4HZj0dBzM8nQaePH3FzjwEhVa79YRvu5fDmfuuQpA7t0GA+7oAsbu5/4W8O/6J/Eq937yl/",
    b"MP9DXwHPYR7VX4SeqA+vPn//wE5k7/ieScAZTjHgQc410GH+OKCKPjtAqm5IcMJOYIDg/oUg9X6l8Q+OwmEejvlxEW87gR",
    b"dvaNEfn5DBGS/TMQLgEJD7oEoQ0qCPwLcAsjCn8OIAhJEfoFxxPFA+8VdAG3Fxj/GxnN/BMakfqdGnP4uRp89mYar/SoGR",
    b"bzgBi58fYWofAOFc7v0BJD70cQBe97DRTvdwpw70YHGPD2AwnxkgA/8ib9tPO/+WP1a/ZC9zfzSvkv8HD7Yu2r/dvq7/+n",
    b"6DMCz+ZsBFzljgZX5JIIxONsCqjjFQwF5IUN2eS1DiPmnw/f50EQBeqWEIzsnRBr71cQlfLFD/316Q6T+ccNSP1jDAsBww",
    b"rMBPEIegj0BgQM1wRaD6ECbBJcAC0VFf6RF9X7ixmn+RQblfckHKn1txzt88gcaPJZHCPxbBsk8AMacO8mGAnv3BXz7jET",
    b"MO8vELzv5gyU8GMJt/G2BR/z8QHC9CP+m/Zd+qH4sPbL+izzDv3h72D/2+y1ASrqAwTZ5z4G8+VaCH/kTgqF4w8MCOOVDQ",
    b"vj2g6O49gPjeSLEATm7xDs5wYRPurNEO/sRRDz73IPPvNXDsL2+gxw+mALN/6QCQcClgfQBXsFgAlHAwYNBgFVEMX+XROM",
    b"/BAWZfpkGFr4Txp09sobvvTLHDrzUB3x8Vcd6vDeHCfw6Ruu73saf++aGJ3vThYE8KETsvChEKrxWg3n8toJYfQuBgr2ZQ",
    b"La95P+0/nH+un7FPcX/onzUwAy8IcCHe2tBF3qxAb457kI9+V/CmfkFgxQ43wNtOKoDpXijQ/z4ikQzON5EB3lexDi5jEQ",
    b"EumdD6brwA6R7pwNxvExDDr1iwre+LYIovy6BnMAmgRABF8C/AcdAJQL3v36Dqn7HhKN+fIUj/drF7j1fhkR9CEbofJOHG",
    b"/xAB2E8DId4e/iHIXvEhx078gate8JGUfw2xYh8UkUQPJeEaTzKA4/9bUKC/cWBwH5WgMV+5P/Pf3S+3T/KfitAaj03QNe",
    b"8fUFW+7rB67ruwlj6VsLgue6DBPm2Q0e5bcOpuRKD63kkQ8y5Y4PMOY9D6Lnpg5/6cgNvOunDFDuSAsw8bEJUPTwB6D3EA",
    b"YJ+xoEdv4XAtEBEwAPBRr+Jwg1/BALbvq7Dc34FBBc9wsSIvaVEyT1rRRo9FYV7fOOFbXzWhXD87wUFPS7E6H0YBJi9bQQ",
    b"Vfa9Dnf3ggzE+A8KNfp5B7771gRR/TYC4P6f/2cAEP3dAZD6PgM0+IUEEfalBTz0mAa28l8HePH8B3rwcAi577IIP++6CB",
    b"jvhghG7xwIyO+LB5nw3Qay8RUGC/MuBaD0JQRr9v0CZfi9AYb6dQC+/C7//v7v/TsBvPxtA5T7jQV4+pUHbvl7CYP4NAvC",
    b"97gMPPcBDvH2Dw/f9t0PA/dlEFb3nxDV94gQefgmEDv5gA8V+pcOBPtrDQ/8+As7/T8KgP5TCNb/RwYrASwEbwIJAp4D2/",
    b"+8BKb9zwV0+9cGVvnOB1v3pwiH9VEJ3PPACWHy7gkm8d8JOvCZCabvJwlh740IWu/NB47v5QYE8NQFyfCeBOTxSwNL8+gB",
    b"6fR/AKz2Gv+Q+MD9lPpz/Lj8Mfvx/vv5LAHW+F0Dy/eBBd/2mQcc9qAJifWJCy/1Pw0Q9awOKPW9D3T1bRDy9cIQoPbSEH",
    b"73rxCK+GIQwvnfDxn7FQ9//PwN6/2aDFj//QrIADAJQQIwB8ED+gRBBZYCsgYkAAcIyf0zCZX7KwqA+fAKdPeBC2r14gt6",
    b"8xEMy/EKDHjwyAuA70ELz+51ClbucgkW7ksIH+4TB4HuzQU/724ETfDhApvxIgEe80j/zPRz/ab2v/uu+DL65frD+ET9Zf",
    b"e9/xj2OgLl9KcE3fPzBg/zEwmC8gELOfK6DDbyOA528nwP+fKJEL7zYBHF9PsRB/ZKEnT3QBL/+NoRnvohEVL8JBAi/uoO",
    b"DABzDQ0CtQsSBKwJBgZiB+AH7QSWCWACJAvM/4gMO/28DbT6uA4/+HQP6fXmD7vzBBC/8cYP/e8qD37uOg5O7Q0Nc+yzC/",
    b"PrMgrR64UICOyhBpTshARv7UICl+74/wjwvf3B8aD7wfOe+QL2s/eA+N71MPso9Pn9ofK9AFjxYgNd8OMFt+9NCGPvsQpY",
    b"7wwNk+9ADxPwIRHb8JYS6PGkEzPzZRSw9OgUXfYmFTz4DBVW+oUUo/ySEwz/RRJvAbEQswPkDtAF3gzGB5oKnwkWCF4LVw",
    b"X6DHMCZA6R/4wP0fxlEEH66RDV9xwRdvUIESDzsxDt8BgQBO8xD4ft/w127I0Mv+vpCkrrHgkT6ykHKOsGBZfrtwJt7E0A",
    b"rO3k/Unvi/s48Uf5ZvMV9731/PQp+BLzmvpw8Q/9KvCM/znvEQKP7pgEIe4PB/HtXgkL7nILeu5EDUPv1w5h8DMQyfFgEX",
    b"jzVhJl9QkThfdsE8b5bhMS/A8TZP5RErwARBEfA/gPigVzDucHuwwYCtIKCAy6CLANewYTDx0EPRCrATIRLv/sEbD8YhI7",
    b"+ogS1/dREpD1uxF288gQk/GAD+7v8w2F7jAMVO1ACmXsJwjK6+YFlet9A8vr9QBY7F/+Je3U+yHuZvlT7yD3zPAI9ZvyH/",
    b"PC9GzxMff478/5x+6G/NvtRf807QMC1ey4BMnsYAcb7fAJ0+1bDO7ukQ5g8IcQGPI7Egj0rBMk9tYUZvitFcb6IRY+/SsW",
    b"zP/MFWoCDxUOBQMUpQesEhgKDRFODCAPNw7oDNEPagogEbAHKxLLBPUSzQF7E8j+shPI+5AT2PgOEwT2JxJU89wQ2fA3D6",
    b"DuSQ247CcLLOvmCAbqjgZP6SAECOmWASjp9f6h6U/8Y+q4+WnrS/e17BL1Uu4R80vwSvGj8rvvTfVt7jH4ae0v+73sLP50",
    b"7BkBjez0A/3sxQa17ZIJse5QDPPv6A6G8T4RaPM7E4n1zhTP9/EVJvqpFoz8/BYD//UWjgGfFiUE/RWyBgoVIAm4E10LAB",
    b"JdDeQPGw94DZQQ1QrFEREIqRIxBTkTOgJwEy7/SRMf/MkSJfn4EVT22RC3828PVvG9DTDvxgtH7ZMJp+syB1rqsgRq6R8C",
    b"3eiG/7fo7vz06GD6kOnl94rqjPXf62bzju2E8Zfv8O/28avunfSw7Xz3/ux3+pbseP1+7HMAv+xgA1ztQQZU7hMJo+/OC0",
    b"DxYQ4h87gQO/XAEoX3cBT1+cEVg/y0FiL/ShfGAYIXZARaF+4GzBZXCdUVlAt8FJsNxxJlD8IQ6RB6DiMS9gsNE0EJoRNh",
    b"BtkTYgOyE1EAKhM8/UMSM/oDET73cw9m9J4NsPGQCy3vVAnz7PQGFut6BKjp7QGn6Fb/CujB/MjnOfrd58r3TOiE9R3pcP",
    b"NZ6pjx/usE8ATuu+5c8MTt8fIm7bP14OyV+O/sk/tM7av+8+3ZAefuEQUq8D4IvfFFC5bzDA6n9YMQ4venEjz6fBSv/AkW",
    b"Mv9LF7wBORg/BMAYrgbVGPsIbhgdC44XCg09FroOihQlEIMSRhE1EBkSpQ2cEtsKyRLgB6ASvgQeEoQBSRFA/igQAPvGDt",
    b"L3Kw3E9FoL4vFWCTrvIgfb7McEz+pTAiDp0//S51P96ebd+mXmfvhM5kD2oeYy9GrnX/Ks6NLwYuqQ74Lsnu747vztrvGp",
    b"7ZH0pe2U9+/tsfqJ7ub9c+8vAazwhAQw8tIH9/MEC/j1Aw4n+LsQePoiE9/8NRVT/+8WygFLGDsEQhmdBssZ4gjiGf8KhR",
    b"nmDLcYjA5/F+oP5hX+EPMTwhGsETUSGg9SEkQMGBIyCYgR8gWlEI8CdA8a//gNovs2DDv4Nwr29AMI6PGoBSHvNQOv7LYA",
    b"muo6/uboyfuT52v5nuYq9wvmDfXh5R/zKuZt8evmAPAl6OLu0OkW7t/roO0/7n3t5PCt7cHzLu7P9gHvCvok8Gf9lPHZAE",
    b"vzSwQ+9aYHY/fVCqz5xg0N/HQQf/7dEvgAAhVxA9sW3wVbGDcIbhlrCgYabAwcGi8OthmqD90Y2BCaF7kR9xVKEvgTjBKi",
    b"EXsS+w4UEg4MWBHpCEoQnQXyDjwCVQ3S/noLbftnCRz4Jgf09MMEB/JOAmTv1v8P7WT9Cuv++lXpq/j653P2Audi9HrmhP",
    b"Jj5uHwvuaG74fneO676L/tVepe7U7sVO2Z7p3tKfE37vHzHe/p9k3wCPrI8Ub9ivOXAI317API9zAHLvpRCq38PA02/+YP",
    b"vQFHEjsEXBSoBh8W+giFFyQLhBgXDRAZxg4jGSoQvhhAEeIXBxKWFn0S3xSfEskSbBJfEOMRsg0HEc0K3g/AB3IOlQTMDF",
    b"kB8AoZ/uMI4vqnBsD3RAS+9MgB6fFG/0/vzvwB7Wr6Eesh+Ifp+fVm6Pzzrec18lvnsPBy53fv+OeP7vHo/e1Z6sHtKezd",
    b"7VbuUe7T8BzvkvM58IX2o/Ge+VDzzvw29QYAR/c4A3r5VQbD+1EJG/4gDHwAuA7eAg4RNwUXE34HyRSlCRsWoQsJF2YNjh",
    b"fsDqkXLBBWFyARlBbDEWQVFBLLExAS0hG6EYUPExHuDBsQHArVDh4HQw0FBHAL4gBmCcb9Mwe9+uIE0veAAhD1GACD8rX9",
    b"OPBj+0DuJPml7Pv2cevr9J/qA/Mj6l3x9OkU8A/qN++B6sLuXOum7qjs0u5e7jzvavDn77Ty2PAs9RPyyfeY84X6YvVY/W",
    b"r3NwCk+RYDAPzqBWv+pgjTADcLKwONDW0FlA+UB0URmgmiEnQLsBMVDXMUcw7nFIkPARVXELkU2hAVFBARDxPyEK0RexD6",
    b"D7AP6Q2YDpQLPA0YCaYLfAbaCdAD4QckAccFaP6VA6L7UgEB+Qn/ffa8/Bv0c/oC8kP4GPA69mjuaPQc7djyL+yH8ZDrc/",
    b"BZ66Tvgese79rr4+6i7Pzu3+1p713vIPA88SXxWfNy8oX1+PMD+LL1yvqR94n9iPlBAJ/71gLf/ScFQwBTB7wCewkwBY4L",
    b"fwdcDZIJ2A5lC8AP8gxwEE8OnRGWD9kStBATFKQRSBVbErQVsBJvFZgS8xQgEvITPBFjEvYP4BB1DhAPvAzjDNIK+wrPCM",
    b"EIoAYUBkMEcQPPAb8AT/8W/tX8ifty+gX5M/h99h32LvRD9BjyqfIF8E3xee5H8Gztle857B3vUevq7ufq/O6R6kbv7eri",
    b"7+br0PDE7PbxE+5m88/vGvWF8fb2mvP8+ED2KfvZ+Fv9UfuK/zz+wgHkAOIDgwPrBb4G6wdxCawJtAsuCwUOgQz1D5INgx",
    b"FjDj4TCA+WFGkP3BRpD0IVMQ9JFbEOqRTpDWwUAg2EE9sLsRFsCtcP3wjvDTMHXQtZBQ4JfgP9BqQBgQOX/3cAnv3t/cb7",
    b"5Pr0+bH4W/h89uX24vOG9VvxWvSY73bz2+298p7sSPIA7Tvy2Osn8vPqSvK469byKeyH86XtjfSc79j18/A091DxmPjz81",
    b"b6D/f/+1L5Yv1hACv/dgHQ/4L+kP9fAygA",
  ])
  // FFmpeg's float Opus output differs by at most two s16 LSBs here.
  let expected = @libavutil.av_base64_decode(reference, 8192).unwrap()
  assert_eq(pcm.length(), expected.length())
  let s16 = (data : Bytes, pos : Int32) => {
    let word = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    word << 16 >> 16
  }
  let mut max_error = 0
  for pos = 0; pos < pcm.length(); pos = pos + 2 {
    max_error = max_error.max((s16(expected, pos) - s16(pcm, pos)).abs())
  }
  assert_true(max_error <= 2, msg="maximum Opus sample error: \{max_error}")
}
