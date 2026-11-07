///|
fn reload_playlist(
  sequence : Int64,
  uris : Array[String],
  tags~ : String = "",
) -> @libavformat.HlsPlaylist {
  let text = StringBuilder()
  text.write_string("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\{sequence}\n\{tags}\n")
  for uri in uris {
    text.write_string("#EXTINF:1,\n\{uri}\n")
  }
  @libavformat.av_hls_parse(text.to_string()).unwrap()
}

///|
test "HLS reload continues overlapping windows and never rewinds on stale input" {
  let calls : Array[String] = []
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a", "b"]),
    (uri, _, _) => {
      calls.push(uri)
      Ok(b"data")
    },
  ).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 10L)
  reader.reload(reload_playlist(11L, ["b", "c"])).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 11L)
  assert_eq(reader.next().unwrap().unwrap().sequence, 12L)
  assert_true(reader.next().unwrap() is None)
  reader.reload(reload_playlist(10L, ["a", "b"])).unwrap()
  assert_true(reader.next().unwrap() is None)
  reader.reload(reload_playlist(12L, ["c", "d"])).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 13L)
  assert_eq(calls, ["a", "b", "c", "d"])
}

///|
test "HLS reload skips expired sequences and preserves gap discontinuity across end" {
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a"]),
    (_, _, _) => Ok(b"data"),
  ).unwrap()
  reader.reload(reload_playlist(12L, ["c"])).unwrap()
  assert_true(reader.next().unwrap().unwrap().discontinuity)
  let gap = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:13\n#EXT-X-DISCONTINUITY\n#EXT-X-GAP\n#EXTINF:1,\ngap",
  ).unwrap()
  reader.reload(gap).unwrap()
  assert_true(reader.next().unwrap() is None)
  reader.reload(reload_playlist(14L, ["e"])).unwrap()
  let segment = reader.next().unwrap().unwrap()
  assert_eq(segment.sequence, 14L)
  assert_true(segment.discontinuity)
}

///|
test "HLS failed segment remains pending through reload" {
  let attempts = Ref(0)
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a"]),
    (_, _, _) => {
      attempts.val += 1
      if attempts.val == 1 {
        Err("retry")
      } else {
        Ok(b"data")
      }
    },
  ).unwrap()
  assert_true(reader.next() is Err("retry"))
  reader.reload(reload_playlist(10L, ["a", "b"])).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 10L)
  assert_eq(attempts.val, 2)
}

///|
test "HLS reload invalidates reused initialization indexes" {
  let calls : Array[String] = []
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a"], tags="#EXT-X-MAP:URI=old.init"),
    (uri, _, _) => {
      calls.push(uri)
      Ok(
        if uri == "old.init" {
          b"OLD"
        } else if uri == "new.init" {
          b"NEW"
        } else {
          b"data"
        },
      )
    },
  ).unwrap()
  assert_eq(reader.next().unwrap().unwrap().initialization, b"OLD")
  reader
  .reload(reload_playlist(11L, ["b"], tags="#EXT-X-MAP:URI=new.init"))
  .unwrap()
  assert_eq(reader.next().unwrap().unwrap().initialization, b"NEW")
  assert_eq(calls, ["old.init", "a", "new.init", "b"])
}

///|
test "HLS reload invalidates same-URI rotated key indexes" {
  let key1 = b"\x2b\x7e\x15\x16\x28\xae\xd2\xa6\xab\xf7\x15\x88\x09\xcf\x4f\x3c"
  let key2 = b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  let cipher = b"\x76\x49\xab\xac\x81\x19\xb2\x46\xce\xe9\x8e\x9b\x12\xe9\x19\x7d"
  let iv = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
  let tags = "#EXT-X-KEY:METHOD=AES-128,URI=key,IV=0x000102030405060708090a0b0c0d0e0f"
  let key_calls = Ref(0)
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a"], tags~),
    (uri, _, _) => {
      if uri == "key" {
        key_calls.val += 1
        Ok(if key_calls.val == 1 { key1 } else { key2 })
      } else {
        Ok(cipher)
      }
    },
  ).unwrap()
  assert_eq(
    reader.next().unwrap().unwrap().media,
    @libavformat.hls_decrypt_aes128(key1, iv, cipher).unwrap(),
  )
  reader.reload(reload_playlist(11L, ["b"], tags~)).unwrap()
  assert_eq(
    reader.next().unwrap().unwrap().media,
    @libavformat.hls_decrypt_aes128(key2, iv, cipher).unwrap(),
  )
  assert_eq(key_calls.val, 2)
}

///|
test "HLS invalid reload leaves the existing reader usable" {
  let reader = @libavformat.hls_segment_reader_new(
    reload_playlist(10L, ["a", "b"]),
    (_, _, _) => Ok(b"data"),
  ).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 10L)
  let master = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlist.m3u8",
  ).unwrap()
  assert_true(reader.reload(master) is Err(_))
  assert_true(
    reader.reload(reload_playlist(9223372036854775807L, ["overflow"])) is Err(_),
  )
  assert_eq(reader.next().unwrap().unwrap().sequence, 11L)
}
