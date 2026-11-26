///|
/// First DSTF packet of the FFmpeg FATE dst/dst-64fs44-2ch.dff sample.
/// FORM and DST sizes and the FRTE packet count match the trimmed file.
let dst_fate_frame_b64 : Bytes = bcat([
  b"RlJNOAAAAAAAABLYRFNEIEZWRVIAAAAAAAAABAEEAABQUk9QAAAAAAAAAEpTTkQgRlMgIAAAAAAAAAAEACsRAENITkwAAAAA",
  b"AAAACgACU0xGVFNSR1RDTVBSAAAAAAAAABREU1QgDkRTVCBFbmNvZGVkICAgAERTVCAAAAAAAAASYkZSVEUAAAAAAAAABgAA",
  b"AAEAS0RTVEYAAAAAAAASRPv/QGJReNSKRyiXS6cUCi1Kr2O5XvH5/WcHm975AALCsclEwHJCJJRLJeMxpt10u96vt8v19vh7",
  b"vF2ulutdmsNcqxQpdFHw2mArEcdi4QhQD/r4+bvdbmcbgbfaa7V6nTaXSaPS6LSaPQ6TS6jWa3Y7jc77fcLj8jk87o9ftdzw",
  b"+Tzej0+z3e/4fP6ff8f3/f0Af0BiUXjUikcol0unFAotSq9juV7x+f1nB5ve+QACwrHJRMByQiSUSyXjMabddLver7fL9fb4",
  b"e7xdrpbrXZrDXKsUKXRR8NpgKxHHYuEIUA/6+Pm73W5nG4G32mu1ep02l0mj0ui0mj0Ok0uo1mt2O43O+33C4/I5PO6PX7Xc",
  b"8Pk83o9Ps93v+Hz+n3/H9/39AH7x036tV+rRlQYDRcsSnSxIuQEiwwQKCBgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAP3jpv1ar9WjKgwGi5YlOliRcgJFhggUEDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAmQkAkAkJmZCZmZ",
  b"kLQkJCZCQkAJCZCQAAACZACQCZAJC8m0gAWAEIWjBYPiGevgI0BxnU7iGRHI1Reyeu4En8AL41oGZaGfkDTez5mwUYwlU2lR",
  b"zSyD8BoBYvzwYqCGAH6yH51uj3N1RxmAmrmr3pl9XYlR778nZ7oOvjnBO/q74Ze2RxZJ6fogzKa7aJDBWX9HdlONrkR3SY0Y",
  b"4uUkFPxQtWKVE+tu9BWKEgrr1Auigm9csUBPpV2BjxKbZX/QepOTvSMkLhVs8oP5/+p7BjClZhLnYmZqJ6Jm/rEqdeHiRjAe",
  b"tOQJjHpCiI8dXXSzw9wfMCgQHZWINrQNKmhWlUBsgLdkRRJmugklsrwg13qsncFG9aW86rqukjdC9TM78lVXlJyS0YKo1dbY",
  b"7l/hzcq2ZybNawigB9nMMl2gOOvRpo1yzxMkcUNsXRsCr11S6ow5Pvm21xueE+o3PIXz4IZ+1ExO8TOnnN8bpmkQtabWh/mF",
  b"YvZGyY7nOCjRT/fslxkcEqYJom4kZJ7tP+G4/yVDGGaR44f0yAJ7N1jJkwyyEA3JDP3TksV1nUP8EWApLEdhP+5pZL/eWn3S",
  b"jZR1R8FFyQZDKMRox0VdbUe9UPFoC9MD6/zhj8y7f0grlR5ygzQVwXpGUXZEswq5mIbOuwGVPZIEvIr9iqmAjHia+fnveQjt",
  b"eY60cslpkjCG17EfRJMLtd97x/DygQu9bk58gNuD6dbSjQM8CuN7HnufQcIfgQYjZjfL4NNmdomKtdHrT8Cx1BqJ+LUtROdq",
  b"PqAtoJjQKJk/OS1FPOjqrE/jMw8Ix3Wk6IbDuWNoblJc3H9U+uXndzi8ck4p4ZiIpz0CKZHzvM/vECceyF/iulH5jTKL8OKT",
  b"2bDd1gAUBF3Ana6EKPjSCinSbV29p7IlibSsAAJMuLwD+ZVD4Z+BasVyaxBDSOJlRpLY+1IV7CQKpYEAsjFh/tEP/o3AI1EW",
  b"ADpikFxFeEoa7rSnWwCXhhUdYbINCxNLDEUgSTUeK69DBWTVS7Sk7JuO+xzBPvnQWs/JaMjdu7jPx3BojwJCFYe8wt342XMA",
  b"d4c9p8Rvm+bEEdewoLPmGSDNfUrbx8sifMoopIG7Dr5CMn+E0VLtX92wysCfI+gimv/J2K0yJYEOUzo9t/A1+YbW1uQXhTyo",
  b"WZ8mi8zEdeBl4oM9oNIWpgG6SWO5RSIqPfZoDdjbzMycO5YJTLbuyw7tGnSiCwQfICNHwxK1XT2n5iEnqgeQYwGeTT6r5wEz",
  b"DsYPYYQcPZxPFWu79Cjp/W85QC/FpAi557QMKK+mAjVO5h4cCBlCeFZcBoZCV/F2t3RdHDUbEJbpku5FiKtFeaysHfsUlVL2",
  b"OU99OAyWiEf4PTYGbo4oZgQmwB8IgOkvxpWjdNH8CWNtD/S3Dfu30cAgY8q8Gn/z+pqMCCGDjTMG3GAam1Z6fcGrk0mnoSjr",
  b"IKadsZtyhoc0aZHc5iYkGFCxxR0hzQI26fNXjKSbOfMBjD7fNG/Kah9BUYVllgPJ/cQh60McIQDLE70a1uN8IwVQ+P8rSZJE",
  b"ruhOxmxPYhW1PWTVGrUuQsjO706MVTHO068cVebNzg4GL32xUuq7PKfVwBoL31zWmtJ+22Ie8Zcz7inpmu7s0x006EG1dQUc",
  b"57WM7wNuhO6wuxLPib8rGI4s9IBQe48lStN1IUXLi/XZi7YqpkijmJ/bqQCq1RGe+ZF+gw2uXPnf3o6ej3CWp0XdXNrXXrIx",
  b"u/LlZmg1o4ipnjPawOw3+YaLH0QtV8nQNIbGct3unkrx0jLGPIArkbgDk4RE3CQQRfPb8Lu298Z6YrQU1FVJVSMvQbnltN/9",
  b"1gXTJvQeZEEOZNuja7VWzMjk1Yzg33UM3k9lSnNM3UNt4mgV6lwVoYhJ8Q+i7pWbBW6KatyFg9fVDS1rRynTDL1MvSodH3JI",
  b"ruI1++wyvQPqrsKJP4qxlstVtaStoz+gVIur2qHa7HBDpVfmLTRZetqx8h/G30pbnUpRVlCKu/CTObwM5qsuC9a2yHKtZMn4",
  b"rVxYwW3/BfV/IktXe38S0Jatd+tvx8mpfWDWLg2t7WPkoFyD1egtfTzBmREPwF4dEz1YAAPmklbQa753buFeZuISoUftltuO",
  b"+2NfuVFU5skiTBZV+/NQkUsyh3Vh2JxXgXIfCxSkOiekaSHcB/MWU9Ch/GyJ4IX+tWak+YARZx01ulrABaPPXhCY5/2RKZqx",
  b"ls1q0l1287/zy4HX3aZb73vXq6PQq1FD4ERn/Yho1prnyeo4cv75hj6Lv8nkwQLDOSAxluMNN87chL35veg3nSVBZILhIwRT",
  b"aEShwLKVNBUK9fJ2vDbrHAb2Y8bx4Cs0mN10Pb7mANMG8rY0pCkhotQenVwhCnXRNj/ELhgf0xELR5LHoxEUFUVYkyNMyOtq",
  b"/nD6dp9SiI+3giVUuWeEV33iCghgeDxeIPjkRwaJXkincNP0UVTrFoaJ7Zyq5Ay0qrLYM2Mq+qoCaWimWHTxfHBK7Jpyzzik",
  b"QH5oguu+9cnvoNEKy3gp33FmQH3morO8RMpi6isIY4EVvTAz6zjvw0nc7BqFco5GLfYmBJ9ftGBz3dsRBkDN70fojEdBH61N",
  b"zDocb0Tx+axuydiwmnqAIWgMgyMVeNm3s8xbAXb8Tlvf9vHpsOiTiJiTfU8La6fLW0/hTto8rVdmRPYrY/e99xt1Cz7aIFTu",
  b"CgfKrE8E2UdZbupPeHCLJKhd2C5cfhtxgPUZngmmh4TWJ67z1OSR6KOQcfNF09W1PC0Z9gbhnMT2T7Lnzw0tBbGCmpNcx9Tp",
  b"WF6sxx+JQMMKRYdGuSUpazz+wvZ6PBc9Lpah2UPU/PtSom9GauGFuHicAGoGx/a086Y/8ASQYBu7MN4SHaXIPkB5jm7nKosA",
  b"yKFxaKtvAJKa5RL43N2/D5eUsq8+yF//C/aj2ra+9hidxOUkRoXAzYZSfzRaSxvzyV/cnpmjcer6B7GEGWhwR4Pg/6mwliWY",
  b"+2Y5IZcSynN1Xzc7FzKgaDQwwSY+G6FzbMETTJ5TONPBX23hLC0ZO5wN1UWNMdyMgoGsHbDF84sFLFK08XebYZONOeo848es",
  b"12aY8VfMOfsit7DOO6XrSsqhi9tcwXAld2GhaVzVAONqVwQfBhVAO3LjFfi7P2mVRgLBzsONTCvuvz6UKPPSgxtCv7vphrse",
  b"HaubiTF6edj3v4Sk5P/oxcXbWff3armVz8dV/8CgvnWFw6Mbt2PlO4pVQN5smLI18DrLaiOhV7P2sbSgnU9q2lSRNV5MiK0S",
  b"uUPOlTu9pRiy/ud22MxfQQ1n10bhkuuMhgaGTpBDKX7xRtDLbZI+Jp6wh3G7Pnyyy4fCJx5NUEvUMFOX2EONKN0FhhqowSBV",
  b"J/DmlzAx5MpEebSFKfxphdYkYpb3U9Y5Yx6S1+9ZAnQv8QWqY3MaF2RldRQTjCL3n+u57eK1/hJrewi0TkYbE+ajFN3HZnFv",
  b"TGo7EYTzvGf2NWOmBOEGezPDIF5tjobFfTCZQqnFSAx1K6Y0VQCtJEIsTGk+VkAwOIr12hyBBymgWvoi20rcA/jDYxyuOZ07",
  b"xKmPnM4hNcEqDdiVv84wtkPauKQF2t/of39gw1hRN+zCnOT2UIn0fMlyna4TpTbSi2v6/6LxuDtLVIHsrsiHxtv4T/IWBzhR",
  b"9UZEbU74aCkJOuQRvqB/NQ6U514WamiyOxym3aawXz9zAFvW1IUPaiwQsQLLRiRYtYKvVbKRTKfPF3tCALosb4/T1f+X6jRa",
  b"Hcy8pLx0jigmoKUMX7+Z1zf5tENBGPZjb27lUKo2sz4bf2ObvayqY5NNvVNZoFDeyQLlHbADbve96KYKzjpslIk6C5i9Gi3W",
  b"nPw5S7lb60M6wTTWxBZvKXUuiJXKngRKf0StpzX1jOG3Kfaur3pPUxtGSqTQby5+j8KG5rArcIHPWGxCXowiDZALWvHSn/wW",
  b"XOnEvkXSl1ZaPOJzbzryaXDBYc+/kWWVXkZ71tUaIDwFNXL0nrOcg5n+LYaxHdZIWI/GPwHNQCOU1oSUEHiXv8kbx+yo4/cQ",
  b"PrZURX/+ghpy1KzHFMW9fB8IRcuwnKlmStlRFUyBTLWoTgWeS6nVtcn3EZMsAF0feaoYMcVXLGVrPkqUCns8NQPvHsxcjXp5",
  b"zAiQfTVeTcH6l0fHd1R323sNnM0hQCd8Qyo8eB7kCdsWD0GFijF1RaBHKv4NqiibaYwqtBR7XmstVhd+QApvJp/d+jVWzjNJ",
  b"6DQUQE4MOHdZyMbCU6fH/wv2HikSS5YOvCM6w9jD0yPMcWBKk+2+ClNS5SeDGTvk1TcwDzx/4NypdmQM+9Lhr3Bubuq5NtIU",
  b"TIHqCG4v/TFIi1rxzZad97vcRxcRoakrxNkWUT+gkkOl89cLlHOjFU75m+dpOF5+aA8xDNo3ibQ3YF77UtH/yQD9m/bg3Q3I",
  b"quHwjAWZW2rWsCiGmYrq8whrn+WlLH1M83d+0Ob0ACcBHysUKkgYh2pz/vqgzaFXafy5FHBS9VDRgv+TYbmDyq8euY2LDL1/",
  b"b+OJ6n2R9vevk1OxH7AA/4WL14cdq+mdZ/AOUb/+aEh/bWxCRWnh+JWV7SipK6BM2K6qjBBO/SCiCXysN7qJuMRvxy++7zF/",
  b"B2u52k4iW3FkSyMGhBC9LZU2+/W3UITaZBQe+8y+wy2zJL6Oww8cxDwkJNFwQ+soyAS+zIZhO+8EK6Oeko4ZeFckBmy8f6ix",
  b"IsQSgMQDNZKQK4QTMvAsju8vee54IgQDJUKyBgAfyw4FDJO1xY2iBRoNK2AJP9DVIpBRGbUvjXuK68B1HrwXcsn/I9BOq+ep",
  b"58FRgXr/mJ9Aenzk3eT/DyP7e5MpbF2myoO5lmflyFyF6Q8gvCgEdOsI+a9zAfAgqxuONNlTOdBtGW+Cmj4x5flQjW21ZUGB",
  b"RYfGPt8tlrwpMNQQ2VnpYne7zgCb/9mAABwJ/SVeRsPRajef9EMwrEEzf2uWB9zsk7bL6uyuCJOMdmgOMRXc9gOZ8kPDOP7W",
  b"kgqbrC//5A9SqnPEijlCbGjn1tG9a3NRQHj4eZR2Nzi9KyLaVdGrnMtIwDKdKXN3ZYxsQp9om4EdS6wqKDv9yF2uajTt75i1",
  b"OTD+KPjo5GMTNakj50PhpnJInhoTftCcN2K60xwdpVdgS5wrCh27hh16zxC39nVqw9A9e9oEu57GUDrSIbByIeeZYETgxGGV",
  b"1i8M+qeEA+q2gim69d2WVSrvJI1A7WRvfK1lQXO5JiuqutJbBvw+1m2hw00f21NfR6J12jdcx6t3KhhgqOd5NDCECaqjbg1s",
  b"8NcdIpIia7nwuAC+ADgNSVU0THLaJQf5ZJQ6r3XmYkz/etdc5m5IFnGvFpj2I0b6XBowYkjhy5Y0m/dGVBfrJycEhkC2VMhi",
  b"zf4Q6e0zAEnXBUU1OdlJMc4dmBrcL4lpDaYxp4Llfba+3uq8VlOuRVSZqOt7KRcgKSl5PPwGJUFN8CskcCn122xEIqbtjZkH",
  b"fR7ivCIFLZdsjjX7uvyH7Bwnn0izKrsDxCZiE7qPVKBcDfAP0zvgs3OUu/qgQYv8xBMs5+3U2F3JUShPHg1USWMUajrq5oJX",
  b"drHiNv09/lk8yADTG9z5hinO8MbD9PDKE6cs1JUhDZK1drPUNGNhLeTWjT0HhW8lzpUWCOspZJICgJaXI5LjZwOfYHVb6aIv",
  b"RkxI0regyJQnxnvQ",
])

///|
test "DSDIFF DST matches FFmpeg float PCM" {
  let file = @libavutil.av_base64_decode(dst_fate_frame_b64, 6000).unwrap()
  let track = av_dff_open(file).unwrap()
  assert_eq(track.codec, "dst")
  assert_eq(track.sample_rate, 352800)
  assert_eq(track.channels, 2)
  assert_eq(track.total_samples, 4704L)
  let frame = track.frames[0]
  assert_eq(
    (frame.pos, frame.pts, frame.duration, frame.size),
    (160L, 0L, 4704, 4676),
  )
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, "iff")
  assert_eq(audio.codec_id, "dst")
  assert_eq(audio.duration_seconds, Some(1.0 / 75.0))
  for row in audio.samples {
    assert_eq(row.length(), 4704)
  }
  let pcm : Array[Byte] = []
  for i in 0..<4704 {
    for row in audio.samples {
      let word = Float::from_double(row[i]).reinterpret_as_int()
      for byte in 0..<4 {
        pcm.push((word >> (8 * byte)).to_byte())
      }
    }
  }
  // Docker FFmpeg 9.0.2: -c:a pcm_f32le -f md5.
  assert_eq(caf_md5(Bytes::from_array(pcm)), "c8f5f98c983ef30f8b4a8c6f17c3e4b3")
}

///|
test "DST reports invalid packet sizes, unsupported segmentation and FRTE mismatch" {
  let dec = @libavcodec.dst_decoder_new(2, 352800).unwrap()
  assert_true(dec.decode_packet(b"\xff") is Err("dst: invalid frame size"))
  assert_true(dec.decode_packet(b"\xff\xff") is Err("dst: truncated frame syntax"))
  assert_true(
    dec.decode_packet(b"\x80\x00") is Err("dst: unsupported segmentation"),
  )
  let file = @libavutil.av_base64_decode(dst_fate_frame_b64, 6000)
    .unwrap()
    .to_array()
  file[145] = 2
  assert_true(
    av_dff_open(Bytes::from_array(file)) is Err("dff: invalid DST frame count"),
  )
}
