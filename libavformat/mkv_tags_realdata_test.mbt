///|
/// Real FFmpeg 9.0.2 Matroska (Opus audio) with container-level and
/// track-targeted `Tags`, used to exercise the metadata reader and writer.

///|
fn mkvmeta_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mkvmeta_b64 : Bytes = mkvmeta_concat([
  b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAKXhFNm3TAv4QaOL3lTbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB+027jFOrhBJUw2dTrIIBd027jFOrhBxTu2tTrIIKQuwBAAAAAAAAUwAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZtW/hH11vX8q17GDD0JAe6mJTWt2IFRpdGxlTYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEu",
  b"MTAyc6SQv6gNk1CTSboW2gvJohH+bkSJiEBbAAAAAAAAFlSua/e/hJvlowKuAQAAAAAAAGjXgQFzxYj86U7gqiJ/+JyBACK1nIN1bmSIgQCGhkFfT1BVU1aqg2MuoFa7hATEtACDgQIj44OEATEtAOGRn4ECtYhA53AAAAAAAGJkgRBV7oEA",
  b"Y6KTT3B1c0hlYWQBAjgBgLsAAAAAABJUw2dA8L+EBGkld3NzQI1jwIBnyJZFo4ZBUlRJU1REh4pNa3YgQXJ0aXN0Z8iURaOFQUxCVU1Eh4lNa3YgQWxidW1nyI5Fo4REQVRFRIeEMjAyNmfImEWjh0NPTU1FTlREh4tta3YgY29tbWVudGfI",
  b"j0WjhUdFTlJFRIeEVGVzdGfImUWjh0VOQ09ERVJEh4xMYXZmNjMuMS4xMDJzc9ZjwItjxYj86U7gqiJ/+GfIoUWjh0VOQ09ERVJEh5RMYXZjNjMuMS4xMDIgbGlib3B1c2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMTA4MDAwMDAwAB9D",
  b"tnVHz7+EjtgYPueBAKNByoEAAID8fgKZ5/ns9RHWFtwZSMPA5L3N//Z1bgNgedQ3yt9qhPRIbQNMeW8Gj5aIArv5rUPGcRHAag+LyvFUUvrFyyVUG3SejDbm34e47UmK9qTfkKhwYhUMUCKfZ1EWnkng3BGYeTgeLfaq9ZQzx8TGp5zlRzBA",
  b"xG2i3TZcDNuGPsfrSA3kZ2d2V49FQiCCYoRWpsA0QJjphu58hltLOcySwg3DGBsEq6WZ+4HDM6Bk3CQ8JICaFCHvA0373269rEwYToQgT5Gz+3qjvPR6OrM1egQej1r/jtAM1ks418OP/xeKoVrPoDxDcLmW6WoZF71JVBobGm2TPgOYyWSB",
  b"2K55vqExmi8i1rpn2w8oDSN20ALYsZkL9F4E8vCagl4E8uqJhyWFVOtS2tSXTQV8iQ9gfstoAxy1cqWf5UdoG7qohz6c3p+Ihz6WR7lp139D67iGBvUpgRrv0Zxr3d2WMNWXXlBXZr7p5y3H+cv5HaCeEgLL0t4/P3D+pUsyd8AnhBiVfMGS",
  b"tfWVu3RR0rvIMSFDCdNZnxTkemrOy9El/dMHySxGRnNNXM8uZOy950PLPBN6vtFkwZv1IODYAmdkgJAJLW9pAtJSk/mQo0EdgQAVgPyxo77PQkALTKEx24ThjTTeT7nS0TUjUNKuikDZu7/0dK/FhylYF3pErRqq7pBbm/yTuCeuWakVIAY1",
  b"sX2p0CEioIMDRKIFiOgho08ASFWSGgbm9hpm5P2dWygX6syJR9s6tNU3SEqh3JwVrRBEoo93tfpcYRzQBWCOvjVK1he0HY3KPohn3Wh/Fi3ZzxDuDi81B67eZgx1C6w2kQknT0acFGo5FqNFKI3cV8THqC3HXSEY44fJ0twJYzkSvul3E9cA",
  b"h6mqVVHUgZBAhRmDWf1WmWgSKPv3fcXg2u9wJGL7oq1HpOBfTFSHeHXTDK0R/Gt4nDPcXOUfZ8exo1atM6cS1mFACBkewEm1siQAABNNudnKle8EOefuo0EbgQApgPyxo8eutaKYqwLroYw/G0E/1N1GYWIVUnGKAGVbM8HMDCmDzcnVf+9F",
  b"g2QPOqa9IJFZ5eMCmv0AMi2GWQZm6YfFAYlt2xRimpr88ajlvrqLk47XDYAFWRmgCVoDN/tRs/HXl/TtGYbi8JdfxT294d5XMVrlxaMDvfy8ENTWpEcLbiAvJLyCtYKfG7cQ9CP+hBOOozj+cbXlPv7p/plNtHfWyko749NB2JIGjju0X7RQ",
  b"PmBDi/IWB4SYYUrndH1n7mOZrwa8vZkFVzYOUTrO9wT8/UMloL9FsrQbMAotlSZ6Zsdie4mY75Nl7iOpd71fPagVH8MhnkZteiX2I2rPOabm7/+ABITJtI2SSq+34HOLX3pzpTPP7qNBEIEAPYD8sC6bTZEUnU2tCWJSfvrcWI9Y8jMinyE2",
  b"IGlYPxgPbS0l/3mfX+N2ExaMCAbgsPFq8Y77L+08e4RRBeT6CoLRLfRHVeldvAuaRZMd4jLNcEgdRMLBZeegLvwVTjuY827B2yO7JHhmKehvG+1tnfBS6z/gjG4320crrsZwPo549K7Uz7QxeUDQfJt0aQPr3yQSzjNtvUL6cY01cpgDCuE1",
  b"5ca60+h6yUQKGOhApeK23h1kBJ3JEQb9+gfmzwH/JL2D0BOXFRwRn5Hxv5Kxerrsu63HcfbL0YG9/4mTYIdRHEDqOSPCuHI1J/RjQhxP6e64fersGOXFAA//yEgSJLtstV/7DHKVKa0pW+/uo0EMgQBRgPywH8mqyw6U3xEo0JsszYjW51pK",
  b"vSu9zcwnAL9pVDlgiJ2/y6+jwdwV+U9XtNMmbHWZfKm0hjupTIoGRiL86oQV3dILovAiK3RaiHdKAiLtc+9gkQNXpRxur0n4quiIpW5Cvvbe8x7vPoxYJIO8Q7vTqVcq5JXspJPvBB8+dCCnk4khNtzXI4nrcqEvzaAIkRh8qjQtc9bKQbrI",
  b"A74dLRtLswKan/W/i8QdZaNNCfXXnJSOqR+IiPL8z7UYeLBA2/N6e/lAkv5HZb/ZrxmCJKQKClB4LJk2Qwrmh5Sm2ekKgEjZF+xLiL3JGeUThJ/qupkG9v/wHDf9ttqybBX+oDGa0UtrMYYZ7qBBlqFBiYEAZQD8tSmEFP28RTFNFk29RYnx",
  b"OQ+rQzeyK2SUNtQ0NsSQSniPYkD6ZheqFEu5g6n8yHCrfInS+JozmbgPwDSJUJENBbNmFPksx9Byr2bSfxhZCCyBBo02bsItR1Kh3Gg2YWgBlPf5ifBnjOmlUwPljVpXg7E3e/fGh7/Lbg+USmqpp5zWhzhlMR6V71J0EEYOkwJvd9++GzHQ",
  b"6rjQtkKh+FVu0n5HqfJrgW1kZwBqJ7NzPIkbG41fqP8wR2QVXd7h3FDswI8QUwnyJ+H0YFblXQXM7zS5RmA/Xvb8xGKlYvtMMBcMzgGYAAAAAAAAAAAAAAAAAAAAAAAAAAAMzM/w/JMFAo8XrWXBc8vn/inUsoo9i2AFpqttc+YH7LbOb6A3",
  b"52RbPhvmcAXABIV1KE1b1MccgZ8WP7zndKDXcaz8CHNGMiAcrWEWQHbNEJK0nQymo4w5wT12F0tXaJs3HAW3kGmSGc90tGMy6PL+N/h+xAkkRPIwFM9J+3skBIBba3bIk2klJa3IrZuBB3WihADN/mAcU7trl7+E/f58truPs4EAt4r3gQHx",
  b"ggJt8IEJ",
])

///|
fn mkvmeta_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
test "mkv tags: reads ffmpeg SimpleTags" {
  let data = @libavutil.av_base64_decode(mkvmeta_b64, 100000).unwrap()
  let mh = @libavformat.av_matroska_open(data).unwrap()
  assert_eq(mh.title.unwrap(), "Mkv Title")
  // Container-level Tag only; the track-targeted Tag (ENCODER/DURATION with a
  // TrackUID) belongs to that stream and is skipped.
  assert_eq(mh.metadata.length(), 6)
  assert_eq(mkvmeta_find(mh.metadata, "ARTIST"), "Mkv Artist")
  assert_eq(mkvmeta_find(mh.metadata, "ALBUM"), "Mkv Album")
  assert_eq(mkvmeta_find(mh.metadata, "DATE"), "2026")
  assert_eq(mkvmeta_find(mh.metadata, "COMMENT"), "mkv comment")
  assert_eq(mkvmeta_find(mh.metadata, "GENRE"), "Test")
  assert_eq(mkvmeta_find(mh.metadata, "ENCODER"), "Lavf63.1.102")
}

///|
test "mkv tags: writer appends uppercased SimpleTags" {
  let data = @libavutil.av_base64_decode(mkvmeta_b64, 100000).unwrap()
  let plain = @libavformat.av_matroska_open(data).unwrap()
  let out = @libavformat.mkv_add_tags(data, [
    ("title", "New Title"),
    ("artist", "New Artist"),
    ("custom key", "value"),
  ]).unwrap()
  let mh = @libavformat.av_matroska_open(out).unwrap()
  assert_eq(mh.tracks.length(), plain.tracks.length())
  assert_eq(mh.packets.length(), plain.packets.length())
  assert_eq(mh.metadata.length(), plain.metadata.length() + 3)
  assert_eq(mkvmeta_find(mh.metadata, "TITLE"), "New Title")
  assert_eq(mkvmeta_find(mh.metadata, "ARTIST"), "New Artist")
  assert_eq(mkvmeta_find(mh.metadata, "CUSTOM_KEY"), "value")
  // Appending keeps the existing tags.
  assert_eq(mkvmeta_find(mh.metadata, "ALBUM"), "Mkv Album")
}

///|
test "mkv tags: writer rejects non-Matroska input" {
  match @libavformat.mkv_add_tags(b"not an ebml file at all", [("a", "b")]) {
    Ok(_) => fail("expected a non-EBML file to be rejected")
    Err(_) => ()
  }
}
