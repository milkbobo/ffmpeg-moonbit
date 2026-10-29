///|
/// Real FFmpeg 9.0.2 MP3 with an ID3v2.4 tag (UTF-8 text frames, TSSE and a
/// `TXXX` comment frame).

///|
fn id3tags_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let id3tags_b64 : Bytes = id3tags_concat([
  b"SUQzBAAAAAABGFRJVDIAAAALAAADTXAzIFRpdGxlAFRQRTEAAAAMAAADTXAzIEFydGlzdABUQUxCAAAACwAAA01wMyBBbGJ1bQBURFJDAAAABgAAAzIwMjYAVFJDSwAAAAMAAAMzAFRYWFgAAAAPAAADY29tbWVudABoZWxsbwBUU1NFAAAA",
  b"DgAAA0xhdmY2My4xLjEwMgAAAAAAAAAAAAAA//tQwAAAAAAAAAAAAAAAAAAAAAAASW5mbwAAAA8AAAAJAAAIKAAzMzMzMzMzMzMzM0xMTExMTExMTExMZmZmZmZmZmZmZmZ/f39/f39/f39/f5mZmZmZmZmZmZmZs7Ozs7Ozs7Ozs7PMzMzM",
  b"zMzMzMzMzObm5ubm5ubm5ubm//////////////8AAAAATGF2YzYzLjEuAAAAAAAAAAAAAAAAJAPMAAAAAAAACCgXXmbeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP/7UMQAAAosQy5VlIABgRVmIzrQAAeqw44zhdNk8aHBCBxY",
  b"H14fGBxGBB6J5bMuWg+oOxNr8PhgUBQEAwKCRAxOaNGjbB94gBAEMTg/wQdOdPnOX85y/u6fdy4Pg+D4fBAMSgDB/SABCAABBAAYajoYe3EIAEMU5GRoMbTKNbiFAIHG+wdKdnMwOKJmJYTGEYSLe6/WwR0B0+A5RJgtX4Wodowolv+O4YYS",
  b"4kR6/+SJkXi8Yl3/8umReLyJdLv8RBUFREe/4KoAAAAEeW83ulv/+1LEBIIIcCEt/dEAIX+K4VHP1EhZSykwAAUcAAQgYbg7yatGGYsBeYOAaAQGMAwCAQFM679lzqVZmnX6qEo4e/Kt/612/1fq/enG+//+8AEGBQSY6IBn9Hm+JkYSiHlm",
  b"ezOsZnhIeaYS4CqAcVcIGj1CBoBHAaBfoGSyKAoBBZZFC+aIJ9vy8pX7qOoGde5Kdbpi9OXejr1Gi2r3K+1Fv7jfunTBlC3utO3zF/WhNQCQAipjEcGOCiZTQxpSKmC0huRk5DZEZMOGvGClAdpo5v/7UsQQggncIw7Of2JBQgRh5b/sSEYs",
  b"PmpoRtkqaIQiQE/Mu4tiOVa4UoJf/X9HeIP7+j9+tjms5KPbfrXVsfv/dzQEJKgoGADKSk1xiO/3TBzAsozB1XKMvSCzDB1QPk9CkNmdjW2k1jAMwLkN38p8AfTXqy+jLi9O4hX9aO2xv/GU/+2nLG7GJjO8jqTlEem64coA0IpUZMXmWoho",
  b"Dubz6GCWBipkH7CqZAIGBmCIgaRsl5lSRxmZ3/BuyyBsDWexNul9+jyH5R6tyZ1yPT3f//tSxB6CCdAjEM3/QkEsBGIZv+xI77R99kgcR8m0ZQXtS1f5bQJhIg0oQBmRDhqKedNbGDNhKplbCS2ZUuEsmDPAaB2sWaqymkLRo9SZKTp0Rukz",
  b"BDVlBf0aP9X0VlHfL3ySUI9w29X2fz/XWydVv/6aAFBBjsiGPjKZZUxpymmC+iDhlIkBsZP+IDGCrAkZoKcZQMm0oxw06asSiQc6sus9eddsCzdgo7vf+xleH9ik/ivKSFuj7ldWr+7orRr6P02gEChnJSbozHz9JhEwXYb/+1LEL4MJ9CUM",
  b"rn9iQUmEoYW/7Ehy+tmGcDBeRhFoIaftdG7RhscCa90GaHhdt/JXSVwtkN1LKnbFKsUXZIO+p19TndM7p07mUaV1t36rkO0X/tZXfRppMBGAUzASQHYwGIDFMCvBhjBnhMkyy2VfMrgEsTBdQVg0BnM5GDgE06OsNpKg4ZadFbWq276xTLv0",
  b"cM66lyKWZKui4qz7XbXijN2b/1LfR0PZ3XLAn6vZ9yhUYJCZmA4bOonlXxg9ITeZmkmHmZChOpg9gHAevOmxvP/7UsQ8ggsYVQoP7EbBC4Sh1b/sSJpzgaXmmTmqKD/0lfBNvCVOO7V9/Jffn/317nN/Tb/+n2ddAAAQAWg/NZG3VhkqQuIA",
  b"fMB8JgxalTjr6UMMBlCcyVK4sirDPGarOQY1tT/f37fnOr+j7fT2avsX/1U6YAHhgzMXNoSjz7MwfAJOM0HSEjMtglQwfUDXPWmjYHg0tzNE0DIjRIt/KekB8zvrzWR6vp3/s/+nu/39v/T//+kAAAAwQuYkF5iUkGMkCZfhBgeAaiY2G0Km",
  b"NJBo//tSxEyAB4gdKex7giEDBGHFv+xIJgaYHYY6OCpR0kZ6bxwRw0BgazfV2VK8j6P1P9ND1env/2/7P7PVXLHP29QXALMBcEUwgwSzC4F4MbI1Y+AOLzylWfMv8h0xjwsTBnDnMNMLkwyQ0TAZA/BwBau6CMSw+IhV93dyieiebjmn0/T9",
  b"3//+n9f/pQAMIIFIAiGQAAAADHItDOyfjBgCzFEoK2Zz2BpkELBlGQzqXMjE4LAMFBgGBRgSA2fjx0TFVUHf9NQs2W3SFiU9/+wdTR3/+1LEbAII/CMRbn9CQSeLIgK8MADJZ807TWv//e5rDqKDqnlMZjOXf//+Lu5LLGVJjWpo1Vpf///5",
  b"Y/7/y+HLGFLr8dVqbwwD4ORKdiI95QBh85FQVwa/QD5qou92o9////YqTEFNRTQuMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
  b"qqqqqqqqqqqqqqqqqqqqqv/7UsSBABKEuS9Z3AAAAAA0g4AABKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
])

///|
fn id3tags_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
test "id3v2: reads ffmpeg tag" {
  let data = @libavutil.av_base64_decode(id3tags_b64, 100000).unwrap()
  let tags = @libavformat.id3v2_read_tags(data).unwrap()
  assert_eq(tags.length(), 7)
  assert_eq(id3tags_find(tags, "title"), "Mp3 Title")
  assert_eq(id3tags_find(tags, "artist"), "Mp3 Artist")
  assert_eq(id3tags_find(tags, "album"), "Mp3 Album")
  assert_eq(id3tags_find(tags, "date"), "2026")
  assert_eq(id3tags_find(tags, "track"), "3")
  assert_eq(id3tags_find(tags, "comment"), "hello")
  assert_eq(id3tags_find(tags, "encoder"), "Lavf63.1.102")
}

///|
test "id3v2: writer replaces the tag and keeps the audio" {
  let data = @libavutil.av_base64_decode(id3tags_b64, 100000).unwrap()
  // Audio after the original tag starts with an MP3 frame sync.
  let old_size = 10 +
    ((data[6].to_int() & 0x7F) << 21) +
    ((data[7].to_int() & 0x7F) << 14) +
    ((data[8].to_int() & 0x7F) << 7) +
    (data[9].to_int() & 0x7F)
  let audio = data[old_size:].to_owned()
  assert_eq(audio[0].to_int(), 0xFF)
  let out = @libavformat.id3v2_add_tags(data, [
    ("title", "New"),
    ("artist", "Up"),
    ("track", "8"),
    ("custom key", "custom value"),
  ]).unwrap()
  let tags = @libavformat.id3v2_read_tags(out).unwrap()
  assert_eq(tags.length(), 4)
  assert_eq(id3tags_find(tags, "title"), "New")
  assert_eq(id3tags_find(tags, "artist"), "Up")
  assert_eq(id3tags_find(tags, "track"), "8")
  assert_eq(id3tags_find(tags, "custom key"), "custom value")
  assert_eq(id3tags_find(tags, "album"), "")
  // The audio payload survives byte-for-byte.
  let new_size = 10 +
    ((out[6].to_int() & 0x7F) << 21) +
    ((out[7].to_int() & 0x7F) << 14) +
    ((out[8].to_int() & 0x7F) << 7) +
    (out[9].to_int() & 0x7F)
  assert_eq(out[new_size:].to_owned(), audio)
  // Stripping the tag leaves the bare MP3 stream; a payload without a tag
  // reads as an empty list.
  let bare = @libavformat.id3v2_add_tags(out, []).unwrap()
  assert_eq(bare, audio)
  assert_eq(@libavformat.id3v2_read_tags(bare).unwrap().length(), 0)
}
