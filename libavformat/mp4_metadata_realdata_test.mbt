///|
/// Real FFmpeg 9.0.2 MP4 (AAC audio) carrying `udta/meta/ilst` string tags.

///|
fn mp4meta_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mp4meta_b64 : Bytes = mp4meta_concat([
  b"AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAIx21kYXTcAExhdmM2My4xLjEwMgBCVh/////+AJK2U6DEXTl+PHP4u9cXkcZdokis1knaDrBB7F8L819RzsK7SdpeY9jSwHK4NRz+SXxer979i7S6R5u/E/Jdy+JUCD0b",
  b"wXsrqvDcDvXA71nOVY3FXGzek8q67xrE3Ky3LOdexOOxuK3nOtZzrXcdlNyxNystyxOOxtiuNmtM9ca1Wa1O007ap2tVmepZ60z1ZjqzTTtNO00bWqzHUs9Sx1LHRtNG1ZrTRr8+x0K2rZ1bOmxpsabGmxiSiSiSiSiSiXyX5saLGitRSosa",
  b"LGJjEvklElPFPFPFEvkvkvkvvFPFPFPFEvkvkvklPFPFPFPPvPkvxRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRSQ/J4tOX48c/i71xeRxl2iSKzWSdoOsEAAAAAAAAAAAAAAAAAAAAABwhTGz+B/5/5/5LWkm61UZJLdZnbrM3H1eu",
  b"G7xerr1vrzqQTX9fPRfFyj+77zWuIpQo+pjP8TRh48eWRTWIcewUmYIjrsmSTDJ82k+0w7ixjlYMg42OeB7k+5TYoCbjqzlNimTcdYbDPNWzp26BrUa2U+TwwxNzLw7ccMMcJjIyxwmcGBga67hISEgwMDO7hISEgw5l3cJONAzINed3yCQn",
  b"JeQc+Sv7eiXWp3YkXQE8Ht8HizsGgcTMyCSo2Cin0fT1EpoIGTifYek7F6zvX5XKcLXtdrWdWWuyUiyxtajY7OrLZpGyyUjJY2xVmOzrE2ayzslIsrDPRsdZrLPTrVs1ZGTUbHRsc1VT062kWzXDGtq2wxwxwmxwxwxwrZ2dpJnR5scMa6Sd",
  b"nN2IHZ2dnZq2dnZybZhLwZcmeJvShzd6+Sz3l2W9G1m5XHhtd16447G1qsxz6/NVRnwkm1TSNJM7Vs7CwsMsO3D36Hv0Pfpx9Xrhu8au69b686kB+fPRfFyj+77zWuIoAAAAAAAAAAAAAAAAAAAAAHAhew//////AEJbaixdS8eM/Nfjr6cd",
  b"UjNcVIvJCVUY8ZF0uhnnJo/tudRes/6f9JERc+1q0gE9hY+F81/W2dUwHfxj9xIkIRGH+z2DsHPX+okERIAP/L8lra7wvYfzP93+b57jSK9x7sW1ZVYlQcjnPHeq7T1XGiZLsX33o3Wsqfg5Haeq9V4zlL6hXsq491barEqFkbLtO04mNUoV",
  b"7OurdW41Yn53Izs7YZ1qSgabT09PRxSLGRnZ2NWkiJp6enp5saRYyM7Ozqkl0aZPTZ+VOUTLVq1YmVqBpUqbMlx6IqlqpYmQTxmTZsqVHk+GHbg9SNjjNomYq3wwreo2bGZmQq668HdQZpsZqRGSTCt5AZmmpmaAJ3rISZmmZkSEH5NS8eM/",
  b"Nfjr6cdUjNcVIvJCVUY8ZF0ugAAAAAAAAAAAAAAAAAAAAAchGw/////bADXbWLSmDoYFoYFomFoUDoUDoXvr8/+n7f+3/fjd3eVUry1vTeub5gt7q2t5L2UPz3tL+kHirYI3QUMIHJLLb9wgy+g/0O298Vdfttj2/vmPo1fTZjZ+uZLxwn9O",
  b"jVxFpZlTVSIA5tX+0nYdmmBEgWgqY0zgTU18429uPoau5pUwLdhGOFUhPM0rLH+gvOLV2W7TviwNSuDifoRpo5uNJUPcGyUQPD+wDFuTk0CzKMlGhXuuDnjj0Vfcmw5uZT8dHkoe3paIHDoEFyzlj/GLPQf0ExgluMsKRYFINJEFiWopTwmC",
  b"wvNzUxojWWFgRmkmNSaIkymVRrUtS5wCbaI3lbj2c3moply8v7FoZZrjM/G8rluWx899Vz9L3Qv4X2aNrHuhEWhEWi8Wh8Oh8Ohe+vz/6ft/7f9+N3d5VSvLW9N65vmC3ura2WKAAAAAAAAAAAAAAAAAAAchKw/////8ADxdKMxSFqSDoVd8",
  b"/1/T/29tcNVnDNJkl7blKyn5EqI0BPFYUnYh1pLIYzXEMZoCG24eQ0u4IcO5YQbLIO4lUK8/k99pyeUwxPiO4J6LHk87hydOBdySEOgQsXCF68QuWCFScQt0CEVXipMaybYJOHEJxIZOC4mUX4uP9+ECHIKYQYwgtRA5LsBnDRfw/9P///8y",
  b"Yw/e7Lvj7hnQGPA48B/E7wqiB9v/p/+f/n9/7zrczgOwfeftP2nVMob532P1f7/4PocemyHKPgPgP7nnmMPs/q/5v7/7/q7M9pZM4zjETjQNnJ4vF2OPVhCPEZjPGWUbsu/y9WWTL2Z9PGwWjLLvyygFvlzzzUki7LKdCOXPNZVAojKIgANc",
  b"5VEIiJ/mPAtR5OzrB6bgiMRsHBh7Xgfi1Ph0Ku+f6/p/7e2uGqzhmkyS9tylZT8iVEAAAAAAAAAAAAAAAAAAADghTNL/9/9/IABL2aUNNft8arOoPX1+F8UvV3//Z/n79X15uVWf/0uv8+WrfFasFqh0Zl3I0S6fpy2hG7pL1qlwslpMNbTa",
  b"LUUqcSy0SVOmtM0aTLUUokrRISDAwMDBISDAxuUJCQkGBgY3KoJShIMDA0pvEJShIMSBpWXOBNNaI3FQRG678fEwgw+xnY+BiJNoO3MnA9ZIhHd6snA+4kHTCIoH4L1mi6JCTHJBF/x/pfcbfw2BXiGBrkyXyRkESFJDGRAIlqLxDgmUJ4bc",
  b"ksJiCRSERDJADnUBDiWLJ6HhZK3qCHA4xIAMeh/8v8v676iT3fCCSNzLm9J7rakC7sjqo/a3ZOxuLdjZpJ6zKEJupI4moT0+BIW9KRsYG5qZp62aenknlpBC7kiLsCTx5iGExmC4Z1O1qcrE0rR2Xq5CxTyvYJTxkLMwmmySkOIWYduiwEkm",
  b"A5zI6/JEo+XJ7fKkeL5oljuBk8TjiPMMkS3HHCdbbEeEwiXEuPk08QojiRLh/AiFvfkuMyCPBOIEA8Hx/wYjwjeS4+eR88jxqE6g9fX4XxS9W/+v8/fq+vNyqf/1Ov8+WrfFasAAAAAAAAAAAAAAAAAAA4AhQNpGCMHAAAAD0m1vb3YAAABs",
  b"bXZoZAAAAAAAAAAAAAAAAAAArEQAABSsAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJBdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAA",
  b"AQAAAAAAABSsAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAUrAAABAAAAQAAAAABuW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAA",
  b"rEQAABisVcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAWRtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAShzdGJsAAAAanN0c2QAAAAA",
  b"AAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAACABAAAAAArEQAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAAB9AAAAeiKBYCAgAUSEFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIAAAAGAAAEAAAAAAEAAACsAAAAHHN0c2MA",
  b"AAAAAAAAAQAAAAEAAAAHAAAAAQAAADBzdHN6AAAAAAAAAAAAAAAHAAABUAAAAZgAAAFHAAABXwAAAWIAAAHIAAAABwAAABRzdGNvAAAAAAAAAAEAAAAsAAAAGnNncGQBAAAAcm9sbAAAAAIAAAAB//8AAAAcc2JncAAAAAByb2xsAAAAAQAA",
  b"AAcAAAABAAABHXVkdGEAAAEVbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAADoaWxzdAAAACKpbmFtAAAAGmRhdGEAAAABAAAAAE1ldGEgVGl0bGUAAAAjqUFSVAAAABtkYXRhAAAAAQAAAABNZXRhIEFydGlz",
  b"dAAAACKpYWxiAAAAGmRhdGEAAAABAAAAAE1ldGEgQWxidW0AAAAcqWRheQAAABRkYXRhAAAAAQAAAAAyMDI2AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAyAAAAHaljbXQAAAAVZGF0YQAAAAEAAAAAaGVsbG8AAAAcqWdl",
  b"bgAAABRkYXRhAAAAAQAAAABUZXN0",
])

///|
fn mp4meta_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
test "mp4 metadata: reads ffmpeg ilst tags" {
  let data = @libavutil.av_base64_decode(mp4meta_b64, 100000).unwrap()
  let movie = @libavformat.av_mov_open(data).unwrap()
  assert_eq(movie.tracks.length(), 1)
  assert_eq(mp4meta_find(movie.metadata, "title"), "Meta Title")
  assert_eq(mp4meta_find(movie.metadata, "artist"), "Meta Artist")
  assert_eq(mp4meta_find(movie.metadata, "album"), "Meta Album")
  assert_eq(mp4meta_find(movie.metadata, "date"), "2026")
  assert_eq(mp4meta_find(movie.metadata, "comment"), "hello")
  assert_eq(mp4meta_find(movie.metadata, "genre"), "Test")
  assert_eq(mp4meta_find(movie.metadata, "encoder"), "Lavf63.1.102")
}

///|
test "mp4 metadata: writer adds tags and keeps the media intact" {
  let data = @libavutil.av_base64_decode(mp4meta_b64, 100000).unwrap()
  let tags : Array[(String, String)] = [
    ("title", "New Title"),
    ("artist", "New Artist"),
    ("copyright", "(c) 2026 MoonBit"),
    ("album_artist", "Various"),
    ("unknown_key", "ignored"),
  ]
  let plain = @libavformat.av_mov_open(data).unwrap()
  let out = @libavformat.mp4_add_metadata(data, tags).unwrap()
  let movie = @libavformat.av_mov_open(out).unwrap()
  assert_eq(movie.tracks.length(), 1)
  assert_eq(movie.tracks[0].samples.length(), plain.tracks[0].samples.length())
  assert_eq(mp4meta_find(movie.metadata, "title"), "New Title")
  assert_eq(mp4meta_find(movie.metadata, "copyright"), "(c) 2026 MoonBit")
  assert_eq(mp4meta_find(movie.metadata, "album_artist"), "Various")
  assert_eq(mp4meta_find(movie.metadata, "unknown_key"), "")
  // Tags absent from the new set are dropped, like `-metadata` replacement.
  assert_eq(mp4meta_find(movie.metadata, "album"), "")
  assert_eq(mp4meta_find(movie.metadata, "encoder"), "")
  assert_true(
    out.length() != data.length(),
    msg="metadata rewrite should change the file",
  )
}

///|
test "mp4 metadata: writer rejects files without a trailing moov" {
  let data = @libavutil.av_base64_decode(mp4meta_b64, 100000).unwrap()
  // ftyp(28) + free(8) + mdat(2247) of this fixture: cutting there drops moov.
  let cut = data[0:2283].to_owned()
  match @libavformat.mp4_add_metadata(cut, [("title", "x")]) {
    Ok(_) => fail("expected a moov-less file to be rejected")
    Err(_) => ()
  }
}
