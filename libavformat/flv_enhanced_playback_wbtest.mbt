///|
/// Stereo 48 kHz Enhanced FLV fixtures muxed by FFmpeg 9.0.2.
fn check_enhanced_flv(
  file : Bytes,
  codec : String,
  count : Int32,
  priming : Int32,
  expected : String,
) -> Unit raise {
  let demux = av_flv_audio_open(file).unwrap()
  assert_eq(demux.priming, priming)
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, "flv")
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.sample_rate, 48000)
  assert_eq(audio.channels, 2)
  assert_eq(audio.read_error, "")
  for row in audio.samples {
    assert_eq(row.length(), count)
  }
  let pcm = if codec == "flac" {
    // Compare 24-bit FLAC as left-aligned s32, retaining every bit.
    let out : Array[Byte] = []
    for i in 0..<count {
      for row in audio.samples {
        let word = (row[i] * 2147483648.0).to_int()
        for byte in 0..<4 {
          out.push((word >> (8 * byte)).to_byte())
        }
      }
    }
    Bytes::from_array(out)
  } else {
    let wav = audio.to_wav_s16()
    let demux = av_wav_open(wav).unwrap()
    assert_eq(demux.data_size, (count * 4).to_int64())
    wav[demux.data_offset.to_int():].to_owned()
  }
  assert_eq(caf_md5(pcm), expected)
}

///|
test "Enhanced FLV opus packet timing and PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/om6XjU/fOwANYXVkaW9kYX",
    b"RhcmF0ZQBAP0AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDncAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEBAAxhdWRpb2NvZGVjaWQAQdPcHVzAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECAAAAAAA",
    b"AAAAAJAAAAywgAABgAAAAAAAAAkE9wdXNPcHVzSGVhZAECOAGAuwAAAAAAAAAAIwgAAAsAAAAAAAAAlE9wdXMBAgAAAAMA",
    b"AAAWCAAAcAAAAAAAAACRT3B1c3yuW/4WuG22ILmaEPC03Uu6aXuVf2PVR7xs1LIXWidqBfnxa5Um8e4gr+vcHYOwg0aka0",
    b"XCB14PwzgDpKNr+YTR2OcIYbPuKN2bSqgaAtvnoeRvNLJf2z6walUltsVax6dfUC346ZGIvGwpAAAAewgAAFUAABUAAAAA",
    b"kU9wdXN8rSKIBB8EcWIumNzlaw1q0iKRCLnuqO994ysXBuNZlw8JGTwpArujyLRU7+Rd6Wy/cyFLy4U5ZwLYXs8pL/qC1f",
    b"GM6+NR1RI6/RvpyS1nLwAAAGA=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  check_enhanced_flv(
    file, "opus", 1608, 312, "3bee07e37c418500cf000cda2465c457",
  )
  assert_eq(
    av_flv_audio_open(file).unwrap().packets.map(p => (p.pts, p.size)),
    [(0L, 107), (21L, 80)],
  )
}

///|
test "Enhanced FLV flac packet timing and PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/nKwIMSbpeQANYXVkaW9kYX",
    b"RhcmF0ZQBAX0AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDncAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEBAAxhdWRpb2NvZGVjaWQAQdmTGFDAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECtKgAAAA",
    b"AAAAAJAAAAywgAACcAAAAAAAAAkGZMYUMCQAJAAAAAAA3iC7gDcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMggAAAsAAAAA",
    b"AAAAlGZMYUMBAgAAAAMAAAAWCAAFUwAAAAAAAACRZkxhQ//4KqwAqk4GZmYIAe8JeLAKxFkL31oMxQENcY4N4j3lmyS7Xl",
    b"Knwfg3/6jAob98JmrZEZSbHgqFI2GY8Go8Go0FomERsWEbhagz9/9VZ3silUtmczm0vmkpld5d2VJ/5ZsK5yQlpqeiEWC0",
    b"XDMaC0XisSjPDgtJ3LNOj39aKqsbu/kcslEtlsplEiv7axqvfrXgyMnJIVGhyfCUTCoVigUiU/PTUuJnrdWiTbfVDS2dje",
    b"30jkMnkEiv7m3mWVdB36ZMOpi8fFhcZnh2IBEIBEdiEyNiopeuV6dAp3evlPUWVlc293dXVtbWFVV/ffTTmyKmLh+SFRgX",
    b"nJmdG5waGRaWClDxom2slv9VtSEnNTU/PxGJT0/NTErfs1vusMWCBUydFxMbHB4dHh0cFxcSOmirziSLO1ajav35OWlZiW",
    b"lpOVvXZWa33+ueSzRMgZOHBIQFhAWFT4mdOlypNpxNNXP7qrRtV7du9dtX7FqpY9p6/YJ5KtskSRMyUOFzZsyZLmBCxQok",
    b"9hCEc3XXZfKvnSZsybJmXTK7qaP51ljSCTTBJo0QKGiRQ04UIMNLe9qGM1qr1dVtt998hFsm6222miju9YWpxBBhpogQKF",
    b"ChQsSLPPPMMeQxKEEZsoutkSZM26IkTZEuuVVV2jC/MIOLEipEjJcscMFzZcsWJPvPKMI5M6/eVKVezatXbdu1brWKNLzz",
    b"LXRRt0gWMnDggJiImKCAobPmi5Egysmrt5Sp3zMzT7Uu5+kUR/wB4AHJDgLGWoJOzYGYhfyzWDdbzGFwnRTl46QlH+cUEw",
    b"tMde5vyv2pPUetFg7KWjtLaeytja3VSpdQT1ei3DM8ATpc2odwhBOStl7MuaU2ptDZmmMmXoq5MiCOuzy1JghuhcD2H3UV",
    b"qPWuxVo7aW+uDbu1VnK71gpTQny+a13JsZVRjHKfclxWC9GeNmcM55yzjG1NCYArhMCAuQyypo6kmvc76NDaa1psVae4Nz",
    b"7q3Uudbmz9g6rUv/Pyt/1DCMuXRqHpIyU0uhnTcnKPAd08J0jfmkMGVglL7N4vqiIDnfAdv+dKqsWEtNcW6l5b03gutb+0",
    b"teasUd+zsdvzXDlQYxzCCk7LMZY2p0DxHvPeeo7BxDRF7KgRl5mlWhKEc1nn/VolUmuNobeXcvNfO+V6rrXAs7XWodFPT5",
    b"3VcYyxa2teokJVzCGrOUeQ+R+D8HqO4bkzxbCgEGc9jVLQ5PN37v8qYVfsja27N4b930v3ee61srL1epx+3h71oGEqMxjk",
    b"kFJ+WwzRwTrnzPqIKfA95yzbmIK6S17G0XRL0S1flPXojUWvNn7iXgvffm/t8LyXJtNYKp9G/e6bXsgyJamgewjBVzAmqO",
    b"aeI+5+j+HvPAcQzhfCfkWc9mlRRNLty7P7qUVZsTa2515L5X5vje+51vrGVypbQfwOH0PBNCYJvSAEwLOY4250D0HzPofM",
    b"8R0DWmLK4St821XtNUJ07iPNoDT2stl7Z3RvFe+9157t28tPXap9F/l6LasmxtWWadUh5QC5mVN2c88p5z2HgOkbUzJayi",
    b"EIdllFgRdJth6f2qKVHrhZm2tzLuXfvHdC5NoLHVZpj/PicTo+GZmuLYPGR0phczOmvOgdE751DnG1M8XYqBInubJf05QN",
    b"Qd07n6KPVLrpZO11wbnXJuhbW1tha2U5oj7vP7hlGEKcwDfPgSUpJeDHGvNycU4hvzWmdL2VgmT/Ogy6vJGieqcL4n3Ukq",
    b"VW2xVo7WW7tlbGz9h60VKo1+Pc8XpmMZGrDLOA/hHSmFoMSZU1RqTVmfMmXYrxNyGvKHuXAAAFXggABTMAAAwAAAAAkWZM",
    b"YUP/+CqcAVROAZGXgeXugX0GAQAXsJ6MSF0eRDSo0hzqweWbMLrYVUO6sESvl8C0/3CgYxF4wFApER0ZlhE3XJlHD1Q2Nd",
    b"IL+UyiXyuXyyVSORW9rSU3HjhRNnBMWmp+IRQLhWMRgLBcJRCfGJYSN2KFBy7UlVZXcgk0ol0slsslMkkVtaVND34YcrFu",
    b"TFhiID0VCkXC8YCsVio/PTIxevl6ZJs60lNZ3F9JpNLZZLZTK5HIbe3p6Xrwy5lT1+WmRyIxKKBYMRYLRWJxCemRiRO2Sd",
    b"Fs6UdHa2cgkkklkslctkspvrm2qaXxyx4F7V+XFxyeigSi4UjEVCoUCI7NjAifsVCFbx/VFZcXUjk8olcrlUnk9/dW9RT+",
    b"+GjCsaPyYyNBEfigWCsWisWiMRnxsXE71qoRqufqnqra4ksglcnlsok8nv7u1raX110YdjF8TFpqeiESioVi0UDAQCk3Oj",
    b"IiJWDBBk5+KWnt7a/ksklcnlsmkkkuLisqPnbVi0MnJMVmJ8eCcTC0VCoVig+EZsXlZA1YoUm339q7G2vZFJ5LLpLKJTdy",
    b"Kzr6n/13Y8zBwQFpgcH4iFQnFopFojFB4dGJWQumCRAv7fKmsubiSyGUyiVSaTyC/t6+s+fduXItbEBSXHR4IRQJxULBSJ",
    b"xKIDoyLiN0xVo9HT9R11le30klMklslk0jvrizqaTx0x4dblwUlxqdCQQi0UCoViYUHx2bFxI9aqEanp4pqm3tJFIpLKpP",
    b"KpHKLq+r7Ci+89GLavfEhYbHAiEQrE4sFAtPxScHBgTP2ypMo4daamtLSRSCSyiUSmSye+vLWup/fjTiyk73Hwn19iH0+/",
    b"X0NRLzpRXzTp7zMz/zU3jlmW295m9fTSESHobBor8gIHVDcehRFcaBsHIchyGsZBWEs9GYov7Eopm/902zXSSZTmOZZzmy",
    b"dZmmmVZQvNtqdD6dHEXnQlGE5iIKovDWNw5jkN40C+KAjG4wkZ0WkJT7aDW7TIEly7MM3zZOk1zVL8qyLdbDTvTixs9nIB",
    b"UNJ7EwVxmGscRyHIbBjFsSz4aSs/s6kk7vzSrFdJGlOYJom6cZvm6YpekqQrVWqF17GOrOhHLxxEIVBcGobhyHIcBoGMUB",
    b"IORhJbquoyj1f1Zs1/kuWpjmybp0mqbJflWSLrZqb+cGZnsb4UTOeRKFgYhtG4dRxG0ZBcE0/GwrENpU0Lf8qVXrlIkpS/",
    b"M83ThOE2zJLsnyBcazR+/YwNhvIxaOAgieL4yjgN47DaNYwisIx3MROeGBIT+X/qNqvEmSvMU2zZOc2TZMMrSRerLUvzlz",
    b"ctieCiYzuI4rjENQ3joOI2jQLQpHs5FYitymgLnfSa3cpAlKW5omycJxm2aJclGRLdYKL6bGHrNZFK5uP4mi6Mo3DkOY4D",
    b"YMIsCQdzOTnxiTE7h/afaLvI8tS9Ns1zpN01zLKsnXm0Vb76s7HYHYnGE7CMKgxjOOQ4jmNwzC+J4hm4vENzVkJY7KRWbd",
    b"IEny3NE0zrNc5zHMUoyJcrBSvXbx9RqfyyaT8JgtjMNg5jiOQ1DKKwmHgzlN8Zk1J4fmnWS6yRKkwzPN84zfNswy7JN/tV",
    b"WoXTp4q66EowHIRhRGIaRuHQcBwGgXhTEQ4l8kua0hqnXQ6xa79J0sTPNM4zhN01S7K8hXmvU/33srSZCCUTYdxPFYaBpH",
    b"IcxvG8YhaE08m4oERkVEra+qTY7nIspy/NE3ThN83TFL0lSHaK5QPDTwVl1IpgN4iiiLg1jWOo4g40cAAAU+CAACUgAAGA",
    b"AAAACRZkxhQ//4GpwCvE76pWl9qiP/Ber/nZCf3PdH9ebX/sOUAU9C5jD7hFDNerrx5616Aov+zSCl2l+F+l4FpFZE9khv",
    b"3dc09e6kUYo70vwPrvu6CaWKk6za8rFLHbKLELA606pqZKHfkdv4XqfHeLVOr+bW8QiAm4rAu4xYzo0g08z4y0v0s8o0j1",
    b"9zhGVqzSaijS3BO4/TovqFrNsKs4tdtttztptMsqrsqwpaoF8/zTY+TsSqZYg318xJJUJdZmJrZw5ypzpyRuxp5iZZxPhD",
    b"rt2irQS0ibTvGPF/7peq8sKtOuDuou6vGuyuctrs2rmqVow+H1HamWsWqlZU58hEn0tozA3I6c9M+E+w9s745M08wgqckh",
    b"6LWltJZRhrHnHr6Laka/rR7mbyL85A8g2/u966u2yxqrqlL7HYNq5Sx0sQnf8I/gJ8YgXkNAkwmgxSNg86dBHbzhQqBcsz",
    b"z31suRcasTDefoHA/uxBCpI11MhToLP8rzUZUtiWzd19SIkXIuRMgLxuCyavpP5c/X4fNL9wkGUJemsdJ+CFEYJARggz6O",
    b"Q1S3J1+N5bJhJbHrfqla2su5bykDIqRkjZCXzdlqWBUVC+LhZ3EKlpO0kytMg4DwEEIgR4jhFH+eRumOVpGvBmKlCp/h+W",
    b"hqksC17rvqQsjZFyJkFeNx2ZWVLfbqbDH5ldN5/k8XJqnOfIhRFiREUIg9zrNMvidINvr9LInYdH50tV1m29el/SJkbI2Q",
    b"t+XXbNf1TQvp4ugwCpZLuIwqzGN07z/ESI8RwihBHiKgoAAAJdCAAAJwAAHAAAAACQZkxhQwJAAkAAAk0ABU4LuANwAAAF",
    b"QAfTRCUeHYgLwSzncK2S2fAAAAAyCAAACwAAHAAAAACUZkxhQwECAAAAAwAAABYIAAAFAAAcAAAAAJFmTGFDAAAAEA==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  check_enhanced_flv(file, "flac", 1344, 0, "d60ee0ade2b7f06ef2f8d67532792439")
  let demux = av_flv_audio_open(file).unwrap()
  assert_eq(demux.packets.map(p => (p.pts, p.size)), [
    (0L, 1358),
    (12L, 1326),
    (24L, 589),
  ])
  assert_eq(demux.extradata.unwrap()[14:18].to_owned(), b"\x00\x00\x05\x40")
}

///|
test "Enhanced FLV ac3 packet timing and PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/oGJN0vGp/AANYXVkaW9kYX",
    b"RhcmF0ZQBAV3AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDncAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEBAAxhdWRpb2NvZGVjaWQAQdhYy0zAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECE8AAAAA",
    b"AAAAAJAAAAywgAAAUAAAAAAAAAkGFjLTMAAAAQCAAACwAAAAAAAACUYWMtMwECAAAAAwAAABYIAAGFAAAAAAAAAJFhYy0z",
    b"C3ct1gxAQ+EG8AET0pGh+QEM/V8+ru391ywN2GZf0yhQpAEd22mV6cR5qehpGbtIESHicpImzcaa+NzD9k0LzYyd4f2Q29",
    b"oNnajV2w09uNHcD5ArkkZupmD5Bac8jzQyEbNUEVIYDzvfQ58mpOKxpixXWklhge+UmtpRZkPz89jWhJWVqG+fPn1NTTU0",
    b"3z79wAysvfONes+fPj+gACOx/LkOG/fPgD5xgevPT3VbDzx+9DaPTF8ycIhMr62rLDCAAfOcD/uv/s7/zsgE0FsGnQZse8",
    b"2WghNBYYYADlt/hbQsTWE+0CBd1aPTH86eIVN7/2dLDDgAhtQD32OwXbflis/dTMGm4ZsO+WOfxQNYZCgrLYdnxBP1fV3z",
    b"svdchl7hgLW0UmZcTAQ1XhNZUD2u91fgExMhHPDXXqDnH0vK58AkVTgMq9MtI93x0iHG1OeisYXlq7GlRfYvsSL3UqqRwA",
    b"er0XyfySDA/vBigXg7bfzvZyyAWt+n6mpBiuQAABCkAAABkA==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  // Pin MoonBit PCM. The reference comparison differs by at most 1 LSB.
  check_enhanced_flv(file, "ac3", 1536, 0, "88346f062e668cfe2b81695d48ba4d95")
}

///|
test "Enhanced FLV eac3 packet timing and PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/oGJN0vGp/AANYXVkaW9kYX",
    b"RhcmF0ZQBAV3AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDncAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEBAAxhdWRpb2NvZGVjaWQAQdlYy0zAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECE8AAAAA",
    b"AAAAAJAAAAywgAAAUAAAAAAAAAkGVjLTMAAAAQCAAACwAAAAAAAACUZWMtMwECAAAAAwAAABYIAAGFAAAAAAAAAJFlYy0z",
    b"C3cAvzSHwAAgjGMYoyAACelIwfkBCK+fV3b+65YG7DACO7bTK9OI81PQ0jN2kESFxOUkTM3GmtxW2H7JkV8rDEtcH+Yx2+",
    b"Zx1+ah1dsNPbjR3A35id2ZGbqZg+QWnPIuaGQjZqgipDAed76HnpNScVjTFitXSpb9898pWWaaFiH5+exrQkrVDfPnz6mp",
    b"pqab59+4AZWXvnGvWfPnx/QABHY/lyHDfvnwNIHrns91Ww88/dRsyjesXmTgiEyvu1aQQawAB1v+zv/OwBNgtkwDnQzY28",
    b"2WgiaEgw2/hegsTWE+0ED1qxmN6yedPCFTfAbOkhxpA97HsF235Y2jcppbAOcDNhb5Y5/KBpIUFZbDs+IIr6u+dl7rkMvc",
    b"MLW0UmZcTAQ1XhNZUD2u/q/AJiZCOeGtXqDnH0nmufAJFU4DKroxVMbe7Doc9xtTnorGF5auxpUX2L7Ei91KqkcAHq9F8n",
    b"8kgwP8AxRF4O232d7OWIAmm/o/U1IC+nEEAAAAAN2PAAABkA==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 8192).unwrap()
  // Pin MoonBit PCM. The reference comparison differs by at most 1 LSB.
  check_enhanced_flv(file, "eac3", 1536, 0, "fd6c66a3d5a848dbc2c0c401d7466c6a")
}
