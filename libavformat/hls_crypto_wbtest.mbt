///|
/// Tests for HLS AES-128-CBC segment decryption.
///
/// Encrypted HLS from `linuxserver/ffmpeg:9.0.2`:
///   key_info = "key.bin\nkey.bin\n000102030405060708090a0b0c0d0e0f\n"
///   ffmpeg ... -f hls -hls_key_info_file key_info -hls_segment_filename enc%d.ts
/// A second run without a key produces the same TS bytes in clear; the
/// decrypted segment must match plain0.ts (MD5 bf6f27b740498b885cf3531b2c62fbcf).

///|
let hls_enc0_b64 : Bytes = bcat([
  b"qtgdafNnlsV7NKjfK33bgfnkLyb7gUDQCe8lASyqFhUADxqSZm3SdbYSZuJqKlFKmhPZPJxpD7+w5K8ydyjRi3KHN4/GNdu+TppL",
  b"ShpHIR/0j64RdLqPSHtgp5ek3pgPUwy37mVziFGEi0U0WgeDKs1hckcFtBJ11PXCQ++UWnw9/V66OCOvu6DACgv7P1ZJwNPHiFpZ",
  b"NvYraljwr5WAqCpf7uW2Uq5tw9yLXzxZMzBwSDEGZS57Oyam/9fwpm49qCx6gedkDldd/NDjaM/dd+h0rdhq6ypxgJVpl+l8btKT",
  b"h790tBOBlYdC/yoPlvJBeHq4RMKGVp1I8dlIU/WhorT/FKQwnqURK34eKmW8Jups0Hr8FxP5SXh/DQP3KW7XJebyVOj4mgS8OuUp",
  b"solFu0aAwmTuYXUeiRRIUqByCqLb/3UZBxPPnt3E7OepV01Al3JB265LgKf5teA8OkNxOnvYgpzNPgtqrDUR/WT4wk0/wu83Opcw",
  b"7jz00SwMvF5E/pkPgNxD35yi/Ndp1ze14hUGgUY76WPYoiH1eRHa1cMSmhi5OiU3DMhdaw8LA1pE1yr67YJHaNusGgrXuKzLKTea",
  b"Lh0KiceFDmQ31N3cBLJxK8DjhkhfOZ8gJ8V2aUUiU1aKyML20G4SdDDCFhkg5vWFnurMpreEv8IL6Xj4luaeSisNk9i9Dra7q4sk",
  b"xWg/uWEtnpXX9bI3IKOiU3J1xRBljRtG4XEskDPTwLeuFq5Y8QY/Ny5K4zaFjKM3xnBGhEJCSi+Gl1G4eEkKgRlkbyh3eE0WkJ7D",
  b"ds9mKs97Vm9sIPlx/wZoVUdSfm0V+aK172JtRyF0a7/pqZuuOzkS8F8+/Sw4rRxW3JOm8t4RIoZpuUKpXIF5URjYSUkCkFR5ebyU",
  b"W5Edwmb71c1NNO5hVEjOFfuskB7HV/AfZZcrV1rcarDYdbvQFV8IGaO1yOmcekcYAES8swLD9z3NuES6SBcspqwWsZsREPUpRD1W",
  b"C7QvNp7z3HoUILr3K2iz2eYN+ck0P6yIBOg2o4FyUwSK61YMa97r+3iCC5QUR+ePHOV5rTwa/X2+jon/xcxdm1lkDINMoKC8+OSC",
  b"nquo+AYiAWbLX/sIhtkqwNR9y4cdu6CYddxitYca02cuhbSS3lqiVmHpqDDDTcLsqklxAeP/L+5isv2t1tQMfwPV5Aktf/v3jYZs",
  b"9F3+CfQE3jRhkK5w7gKCi6ZMMKC1b40OfLhw/JyMg6RolfuqVM48SwUlysPzWh2NvQ3Mkr1RoEutqvZKYhAMv0emO66uNXm0Yn/T",
  b"TrSgpBbgh9ug4Jwx8MJBwrVSdk1HWcfcPU2EcEkH2MXwvRLaIvFAutozfXgqrsEJxrBhIHHEikz3LPA482d5sy+vmcB/LKI07Pl1",
  b"8ZhWJ0JC6SZM9StmWVAZ0Z5OPOXOWt7FNhhm8b4FAEZjd8fEJWsZnsZNDg4T1IZ2nn8RZ8bQWqJFpX7LFoyVoCnmiTIISDYkv8yQ",
  b"Pr6Q9GVVn2vMf6GtkH0shW16yRx7t0xmVMljKsEthAIBBdY/akVmDb3WWQz3/SZiV0X5GGPUIKAEWzUtPMTEEVPWT7BQl4cy43gd",
  b"IqkNNnXzMNyPMIqgYqm36Viwvj54+sFkS3Iy0XQavFLn1U/o6rpDxPzEYb/BRNMLwtp7ONl1rSRdshFttAuypNsqqZAMT2eyTsvQ",
  b"QNosSSj0G5Zd8C2Spy6wPBZCMso1IV/QSM8iN42SZrf3EsxbEwLI5vW4c2c6O6u3A052uCRmLqgNBQoncVWNfqAkTWjK2Cki1jra",
  b"GWX0XfIVvToVVGVsgoUgTYFYMuk7/1u4GT8xkQjDcaNk+DFhnkZHyIEQylRUIATyIwz2k7D/nvUJWxNeGP8UFqrcs8I7IhqBoDz9",
  b"jtJ9/wN9+FFn3gE6b3YBzeRo/YpKkihA6e02xOrhPfF5a+Lxw9FqJLkdxRnkRcDPDkIJcflSfDeYQgwpPeVcnOwdW6SsrBDLKaMH",
  b"P5OdiQBepNGeskiQan/yzTHch2RRpdwOISXc2v6cZ6r7MRrKV94pZjetB9OtuG3Gh8tz1x3s8CQEeCJSX6N27Pf+slEeHQnLSeVb",
  b"OBeEJZZSxsWM8GpZN18S+PP+dUcQAA0CVyjz91nS6OCxQR9k40Jw6DcaEVR2A5HwNVeM+sAzgPO52o5Y57mMyA4F1Asngm5UNa0K",
  b"ox92F++zBvqh/sBc1MFmfvo2Fiu7NSW4vF5xCzPxWLMIxLj1TTRE6PY5kVOwSthaxmLaPyrM7548aJd+kuB4+SBFwAkUSGTJ35hn",
  b"h8GZ8r6jCIcYVy8iy3l5qqA7paGl+i0rkifZIXqpXkikevJrDCF9nh0Reuikl9z5Uiv31rbN2WQ6F7tilaDPr7mfE6u9gnVXowlW",
  b"hxZ2DNtzHC9Kj6HyeE1OECUXws6X1ZwOSmXUBGRZECRncmXboXws0qjRpZTz7GNFSRxV1pCuY1lM9Ut24NeX5ftVbeCOkgjh9gVA",
  b"bYSMSYTSIwCBROHcfNTgc67ivKNqE2L1+3ONCN3E/AUUVT/+NBxAnYQh1cDoL3noAqSuPNNE2VEe8hcEuPy2EThbF/fi3263aYRM",
  b"+Cd2kLvOAxdzbLbscMg0G4c6M2Pi0rZGCfjZ4eBzL9VnBnn2Nm5Ultw5ThjJaDRBTgNYYw796yeqBCYh/i5ooLML5hL02nHDP0pw",
  b"+U+OmfuB9bNQDsv1OJ+C6bCXbnoBLfUy7cPW8AxjFBsQLdEvhAYSf6xgvBR+lzjze3+et8KbB+3xLEuzy0Fit9p2l9vfyxMX4Nzo",
  b"FJPGk/6t/BsILcR4WLFD2xNlc9onSthZaboy3ppI0EUOAxqudCTCkgC7hfKvqWAgi4JVSeu+P4atWTBSORoFahA6z/yvzTaU8WJc",
  b"jzHy6g1Q/QVeVqdxY4N4L+j6bSvyPLyhYEfagjSwRcg7ojswfT7tmDP+CRAyDWwilkOM5wTiW6F0KWftHV5ArY9Kkx2agB0DTg+n",
  b"JjJxw19ktzu9zCjLRVJVVQoLWIJClpAvWoAIXGlqhXSpUChlMlBjE4Lf6L3Hpx+43DWGz5vVaSmxBvkl9LUdxMJwWm2vdZC/dWWt",
  b"gt3F6uCInvvItwpH8MAjfA7xWV1zCvlflG1J8eQ02hpseT/a2O+1vgr+VTeTm2lB+hwXVrjl7f1etV4Zja3Apoz512OU50br+5IA",
  b"dpqQQTlN/DJW6YRiRPg5IAQNwHUKbIVJUPkXOeb23ADhRro4X2vNnGTuln1KffEmAr7cfad498c+Xf+BHkl6Lszhl3jeE+jZo85C",
  b"AKn57bR4waAWgEkVI/Vegtd+g5llYYPL8uuOBdF/WVQQjqNiMqxAStWTfBJDxt1y0Zte8qw1MJ6K5jVUwy+s8JpJg8V+VXGBSjWv",
  b"UXZpeF6Ugr9yXflWC6ZOpFanCJlKnHfDHVtlPv9Y4ksD676yd/2zuoAa2Gnu0+gobO7+w3twlZ/icS1kf7FCGg1rsy00gNO4NXwf",
  b"RLDftT7fNu0A7MJLbIbbGDFIIA5z1csHgdpuLTYoLoWwn3459xbPgy2ecmjPv/ZjDhek+6mtgvxcZMaMmFI53psiJwzeXGcxgrr8",
  b"gO0Vo668QfHCB5eP+3hZPM0hEpUnvkkEH4TIi1Cve+WT7gCMWJfSMqqTd3r8SqsSLg67o8M+7AWwhsiObJip51YzFl0tydWOHRUf",
  b"ABlg4LlMtlDYNUfbUNP2RzVduJf6KjUxgb3/ZEZCUvYcPvBBC0nDK80gq1OIGMdVt+oC8FOPzKEu1zH8s+Yc+Cj72NSyAec++qy7",
  b"gFbu+tgATVq+hhWD7oAYKFt4rNaUm0ReIhmznu1Funim1NQH9ZJ9/yq5YfXQaUaMnugVvJIu5gszQvCC2kgU1LGiCcbfuf21YaHx",
  b"nnTGbhUPG1c7MllclrbTNuqZjO/g3OvVeVYmQN4wBoBXgfXxuQ1iuSke6j0y0cg/EAX/USbZ4VEBT5wXEzbyrRJvfUY20bKftcM8",
  b"xydtq5dPSCbTax85d6T5atOhlRmnS3LiprCkpjiVxeq1hFEbwliMhxU0o1tEGwP5xNVododhE1n3vb0gq0PEVpUaymh4ySTqN4vE",
  b"WB1AdxhGIqqy6HTiOeaonXMvRd4E0kI/5Al/5nHfb6k5y2x8b4DxZQ+Cy+Iw1CgnkwiswtQmGTstJOlrkHIb04JxuzgsUoZCyYw2",
  b"DtTbwcQQ77YeYXnPxYk60XnsmmkcNKUPCNlZWUtS5N9wWJIYusTNSPvIx/bW3siveAhezjigkJA8C12BVkE72tTEt13IGVMKkdwn",
  b"EnKJEfyxO+8BQOwVErG3z+z65y8LeZNcCrCmm7pYljoSqr2BF2LU41k/JNHHl+ySmfBOPgRdQSYmTbYB+vsRc5Vs2guSCzuaTqt6",
  b"VSyq9lhq6gD4+BrfDxiUzXsFCpXZ4/2uTTD0i4Pb+aCVvoM4023rf4QvpnAQVYCUXutbK8pu0p5ffnyOai1Y9EFhJkR/usz/EUF5",
  b"fleKuePjHmCJECRWmbpFrE6puItWrTgXgi3aT6ShebKz+eEir/Bzh9HFDD7F5amlIVgdweyPCBgUgBHdPUybAybhThYREVldrDK3",
  b"E4U0VmDmz24JdGPqDaz7M0Jgceo7nNIZdFPxtdbirq8y09fAMkC131G9uPOrmIQPlga6/uR0oZrafe+NMejI6lfOztaz7r/IrB4U",
  b"ge/7WUFF0WAmrBjKd0+YVHJK1FuQU2Q63FvD2CAOzpVDkGIrQYWa9TVH1Mqp1u0A5MI84Q9tBKvejMoGMo5pWmabpkNgT+J5CidF",
  b"ssWDIkMPFaklK1NR2TR+thUpjS+RyAkdc+QcLZb88r8K/m2ahjGmChK8TbzdwIij91mGX5e+DcXjmT58gVuIWTrR+mLJzK7cdxse",
  b"YQ678vYBODkc70b6wMuObKpHlaz5ecp0zfXG/DRt7Kl2uTGZGmT6S/82kiQp6a3Exx23/FcnSBadX6onmSk72SvxIEHhVBVXwrVv",
  b"xlwdt7XyZQ4LYB9RQ9GI3+9XeAvje49JcVQ=",
])

///|
fn hls_crypto_md5(data : Bytes) -> String {
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let sb = StringBuilder()
  for b in digest {
    let v = b.to_int()
    sb.write_char(
      (if v >> 4 < 10 {
        '0'.to_int() + (v >> 4)
      } else {
        'a'.to_int() + (v >> 4) - 10
      }).unsafe_to_char(),
    )
    sb.write_char(
      (if (v & 15) < 10 {
        '0'.to_int() + (v & 15)
      } else {
        'a'.to_int() + (v & 15) - 10
      }).unsafe_to_char(),
    )
  }
  sb.to_string()
}

///|
test "hls crypto: decrypt a real AES-128 segment" {
  let key : Bytes = b"1234567890123456"
  let iv = hls_parse_iv("0x000102030405060708090a0b0c0d0e0f").unwrap()
  let enc = @libavutil.av_base64_decode(hls_enc0_b64, 100000).unwrap()
  let plain = hls_decrypt_aes128(key, iv, enc).unwrap()
  assert_eq(plain.length(), 3760)
  assert_eq(hls_crypto_md5(plain), "bf6f27b740498b885cf3531b2c62fbcf")
  // MPEG-TS sync byte after decryption.
  assert_eq(plain[0], b'\x47')
  assert_eq(plain[188], b'\x47')
}

///|
test "hls crypto: IV helpers" {
  let seq0 = hls_iv_from_sequence(0L)
  assert_eq(seq0.length(), 16)
  for i in 0..<16 {
    assert_eq(seq0[i], b'\x00')
  }
  let seq = hls_iv_from_sequence(0x0102030405060708L)
  assert_eq(seq[8], b'\x01')
  assert_eq(seq[15], b'\x08')
  assert_true(hls_parse_iv("nope") is None)
}

///|
test "hls crypto: AES-128 encrypt/decrypt round-trips with PKCS#7" {
  let key = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
  let iv : Bytes = Bytes::make(16, b'\x00')
  for len in [0, 1, 15, 16, 17, 31, 32, 100] {
    let data : Array[Byte] = []
    for i in 0..<len {
      data.push((i * 7).to_byte())
    }
    let plain = Bytes::from_array(data)
    let encrypted = hls_encrypt_aes128(key, iv, plain).unwrap()
    assert_eq(encrypted.length(), (len / 16 + 1) * 16)
    assert_true(encrypted != plain)
    assert_eq(hls_decrypt_aes128(key, iv, encrypted).unwrap(), plain)
  }
  match hls_encrypt_aes128(b"\x00", iv, b"x") {
    Ok(_) => fail("short key must fail")
    Err(_) => ()
  }
  match hls_encrypt_aes128(key, b"\x00", b"x") {
    Ok(_) => fail("short IV must fail")
    Err(_) => ()
  }
}
