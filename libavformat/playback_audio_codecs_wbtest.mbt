///|
fn playback_audit_fixture(parts : Array[Bytes]) -> Bytes {
  let data : Array[Byte] = []
  for part in parts {
    for b in part {
      data.push(b)
    }
  }
  @libavutil.av_base64_decode(Bytes::from_array(data), data.length()).unwrap()
}

///|
fn playback_audit_mkv(codec : String, packets : Array[Bytes]) -> Bytes {
  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, 48000.0)
  webm_uint_elem(audio, 0x9F, 1, 2UL)
  let events : Array[MkvAudioEvent] = packets.mapi((i, data) => {
    data,
    pts_ms: i.to_int64() * 10L,
    duration_ms: 10,
  })
  mkv_audio_document(codec, b"", audio, events)
}

///|
fn playback_audit_pcm(
  output : DecodedAudio,
  expected : Array[Int32],
  scale : Double,
  rate : Int32,
) -> Unit raise {
  assert_eq(output.channels, 2)
  assert_eq(output.sample_rate, rate)
  assert_eq(output.samples[0].length() * 2, expected.length())
  assert_eq(output.samples[1].length() * 2, expected.length())
  for i, sample in expected {
    assert_eq(output.samples[i % 2][i / 2] * scale, sample.to_double())
  }
}

///|
test "playback: Matroska DTS core preserves state across packets" {
  let raw = playback_audit_fixture([
    b"f/6AAfw8PvC14AE4AAPvf+AG2xef8nn8g4AAAgAAAAAAAAAAIxhB73Oa1jWNYxS0pMYQQhCEIQhjGEHvc5rmtY1jFrSk5hhC",
    b"EIQhCEAAAAAAAAAAMNCLBdvGzlo3ZNWDJcyXMVrJYwWslrFaxWsFy/DTjw3r5w7auGTZi0XtFzNe0WMlzRczXMl7JgxAAAAD",
    b"//AD//QA5/M/vwAAAAgAAAR/cQsXj1VFQAAAD/j/3/FgcPmxSEAAAC/7AHfxQRzvqceAAAB/5AJ/LCe+eT2AAAB/7AL/JBo8",
    b"rKsAAAD/oCP0Bq+iy0AAAP+gE/KCnzhDgAAD/wE/cNfvZAAAA/8AvyA/0BmAAAAAC/od/TVAAAP/AH8wK9QRAAAAAAv8HP8z",
    b"wAAD/wB/IB/QC8AAAAAL/h0AtMAAD/gD9AL1AmIio2pCwAAAAD9APX+kklxv8knzjAr3AkAYAAQAAgABAMBAMAAAAAAAAO/7",
    b"QD38n/JQAAABAAgAD/GB1OoFNdAAAAP+P/X8OBm+WlBAAAAL/sAd/FhG++5xMAAAH/kAn8wJr6BNwAAAH/sAv8oGby8p4AAA",
    b"P+gI/SGj6TGgAAA/6AT8oKPPEHAAAP/AX9w7+5uwAAA/6AP84HfTi/AAAP/AX+Q+/NzAAAD/wB/IC/QEsAAAAAP/B/+uYAAA",
    b"/8AfyAf0QtAAAAAD/4gALqAAA/4A/QC9YJAAAAAQAQAnYAAAAA/QD1/pJJcI2ST5xv/tyYEgD4AAgABAACAYCAfSi3DlGsS6",
    b"RCs3tQVkQwpwnvzRBKP5H/7fuYErHaov9NPFv4T+r/6//RLuffvr93+VABf9f/0IcgfbHfP4f8f+3/UUvSHuf635//v/n/0Z",
    b"4N+B7l+f+X/v+w77H7b935P/f9ADWMZ+n4H7f0AAAQz43tf1+n//9/+Di3w8H9/wAAEc+/7f+/oAP/ABtZB8vD/v8AgBAf4e",
    b"sAP5AGAIB96P/bxf39gAARMB+z//kAAAA4Ez9kTFQ4P7gH8AgP9tvEtJJv3WHyTzoQOiwG4GAsDAWBgLA4CwOA7tXkLAb6x2",
    b"d+MmNXSvKFULZrq07D4HvOwrb0oo19C7ox4l+//1f/H/+Kr0S9/fv/ygAL/kAAhlkg7a79/A/n/4AAjN6X93/Z/NAB/5//j5",
    b"DHwfdfy/z///6KHaPa/t/R///gAKPgT0O5/X+v9/2OXlfbfz/P/4AAALwgL2e3/f+gA/yCfY9f+/x////+10I+Pb//7AH/g7",
    b"7/WAD8gBAAAO9CPz3gB/gD/o0BPaAv0AP+AQWDAPEA/v//iwf2Af3/AADbfhaSRGdYSSFPOv/osBPAYCwMBYHAWBwFgcB//4",
    b"f/6AAfw8PvC14AE4AAPvf+AG2x/769X6SQAAAgAAAAAAAAAAM0c972tY1a1qUpKUGOMIQhCEIQhzh73uc1rGLWpalJOcpAhC",
    b"EIQhCEAAAAAAAAAALi4oUKFB48WPGCRosePIERowmNIFBpEaUHjB5C5HKFChQoPHixYwgNGjyBAWNHkCBEoSKkSZMgTeSsn3",
    b"5xYswURu0pOqp47EE7jx56yZxYTRx4JqkvGao8ekjG/E+GLFvw3t4NAUCSAEFoKP/cUv5woz38gr/ACngv7XpvlD2Ae8Nrjo",
    b"KMAHZkQ/2YDEK8SvYEz0TpB4cM3DnkN4BUuhIAi2jDu/LaMz1PgKw6KzclTD4ify68ANUAI/t0gE6SIXDcOW7bTDhIJFyFi0",
    b"BwZCjIF8Bm2Fi8GFFkg9kkYf5nE1o5lelH6hi6UYvHDyf9RmqRAn6j6Xru9sMZAJhe6Aa7bvnYTr9gT422/BsjJYRuIr99XC",
    b"vcY15so56a+CT8lU9pitpCblnIposzc1+s25agXHmV/TweiRlvhywKPms2s3NKS5CHAzej+UPRCyvkRF/9wTvYRL/Bfp+wBu",
    b"cCAd7cdXyOhA46yCASvVwOB793rT7fyCvohv6sUvJ9rZpCH/tuEFmtcv2Oqp9n6ymNEKkQLkqxcQX4hQ4Pa6D2qfzB8eVPf8",
    b"q2qP5CDPAaaoPs8OLh/oN57UnfWW34sCMTtzuQe8+QXYrekPaY5K5WfCqcWlAtddXi10LDukTIMDYsA67iC8HTOLSz7k6fLS",
    b"WRaTKtnGEmdReEnbr++s6sZZ9o1PQojLJr3dLgUczs1bgzGZLxwfNwlW2r07uHwj935nn4CcIINgRoRMYsbIFwHP+cIbh//o",
    b"Q7WsTX/Df8NjmhAD7gd4DMksS4oi8t90csZG02ek7CoNnP0f7+v0HUpxZPUeBH6M/XGa6lOQBDNgHwg9IBjY5wYf8GqubNOX",
    b"s3YT9s8gIQzwI/OVmwB6tJN6KHztfxgKDvGNv1Qv+JPIF70BEaMhjvXjRkVfMkLWwcQ7ON3utxhp4f/4bvmm5EJDDqIZgHQR",
    b"8248vFe5hJiG0jBODZ5+tF1v/bDeAUbHeM8q5ZlC6Czs2HWCYWCX6bEUD5RxhjoAL7108JoMyJ//T831ACb3QQeFJ4oDwGP7",
    b"YDHkQdeZ5yKTxoWff6g/gF0BYGhQcAj2jfOoo07Rm98XeQ+xdGeB0NQWamLwccejJ9pBGH3urWCbGtdad/uXnQrKchSGCnkL",
    b"gfKKgo/vhYl/DvXoGggGxvt8SQ9oQsQGLbdv63nodEz2cK91dOyvAgWunHHsDFZm7V5i5/Y0v7LOmuAEeXATwqP92f/+AAAA",
  ])
  let expected = @libavcodec.ff_dca_decode_stream(raw).unwrap()
  let output = decode_audio_file(
    playback_audit_mkv("A_DTS", [raw[:1008].to_owned(), raw[1008:].to_owned()]),
  )
  assert_eq(output.codec_id, "dts")
  playback_audit_pcm(
    output,
    expected.samples,
    2147483648.0,
    expected.sample_rate,
  )
}

///|
test "playback: Matroska MLP and TrueHD decode every access unit in a packet" {
  let mlp = playback_audit_fixture([
    b"gFn/2Phyb7sPjwABt1JAAAAAjZoQBUwDAACAgAAbgCsgSPHqAAABEAAAAPHGAAAAAAOYgiICry7wGX/+RlXALGAAgyAfyOUm",
    b"TUftMq81dcN2a2hC+MrV5cqT4Zrv1shpEA4t4RP8T4YqelGHTO9jFLX2XIAAR7W8H3OfboWvyq/M0CgEAAIc1ODj7ZNvZnWn",
    b"2LG6Os0sozW4cHZXez0pK5qlVI9a9Y0iaMSEcxItYAAwXHAiAABgH5FAhHCGb6I7va/I4DHyRC8CwgmgwjYRPnsUUU5FPAop",
    b"WgrFoNvr9ab381iCi1TWjUoYi/G0brOpGDaORvR+",
  ])
  let thd = playback_audit_fixture([
    b"gH//2Phyb7oAUKABt1IAAAAAjH8QFAAAAAAAAAAANCggbvHqAAABEAAAABfGAAAAAALUggS//y8v/8u/wAF/gANzPdq3Og7o",
    b"2mwRMHxx/67qX20AOrhtSalH6yZA/u0RziadHaPBeZ15JEA4p4JLNpFWxdxJKBPYyCQn7LIAAk8U8Ehqy6NBmdEIjPcMhxb8",
    b"2kAASpDKull004w4iEqlhLSKrFxFype26ymwNYp3jtq9cy42Y9hxlOPu4W4yiB5fq4MAr2CdT34l+PoZ1qcKZ/9DnucQ/Cvg",
    b"hWe+jWLm++wM/5+QSO1jgBl0UaKuDqxxw5IdAmGHyItg6hAAcn9ASAAAYEWRQIkxKNiBqY5AMe3eGz3xh8tNLFnEWKIsJ5I2",
    b"MvPOxqhpMVbxndfyMEJGQi4qmGlfjE4bPD5Ndg/L7QLuKcxHhISMErZ5nnk5fv6wZ/xo2bS9+cMUTOrqT50jUwPS7VB2zC4I",
    b"ZejiB3/Q6dk+OyzFFRZZh8zMwXGqMGvK311n7manuMrFzaAAatc=",
  ])
  for (codec, raw, truehd) in [("A_MLP", mlp, false), ("A_TRUEHD", thd, true)] {
    let expected = @libavcodec.MlpDecoder::new(truehd)
      .decode_stream(raw)
      .unwrap()
    let output = decode_audio_file(playback_audit_mkv(codec, [raw]))
    assert_eq(output.codec_id, if truehd { "truehd" } else { "mlp" })
    let scale = if expected.bits <= 16 { 32768.0 } else { 2147483648.0 }
    playback_audit_pcm(output, expected.samples, scale, expected.sample_rate)
  }
}

///|
test "playback: AC-3 encoder to Matroska to PCM" {
  let samples = FixedArray::make(3072, 0)
  let raw = @libavcodec.ff_ac3_fixed_encode_stream(
    [samples, samples],
    48000,
    192000,
    3,
  ).unwrap()
  let output = decode_audio_file(
    playback_audit_mkv("A_AC3", [raw[:768].to_owned(), raw[768:].to_owned()]),
  )
  assert_eq(output.codec_id, "ac3")
  assert_eq(output.channels, 2)
  assert_eq(output.sample_rate, 48000)
  assert_eq(output.samples[0].length(), 3072)
  assert_eq(output.samples[1].length(), 3072)
}

///|
test "playback: raw AC-3 encoder output reaches the unified decoder" {
  let samples = FixedArray::make(4 * 1536, 0)
  let raw = @libavcodec.ff_ac3_fixed_encode_stream(
    [samples, samples],
    48000,
    192000,
    3,
  ).unwrap()
  let output = decode_audio_file(raw)
  assert_eq(output.format_name, "ac3")
  assert_eq(output.samples[0].length(), samples.length())
  assert_eq(output.samples[1].length(), samples.length())
}
