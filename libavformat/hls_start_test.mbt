///|
fn hls_start_test_playlist(
  offset : String,
  endlist~ : Bool = false,
) -> @libavformat.HlsPlaylist {
  @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-START:TIME-OFFSET=\{offset},PRECISE=YES\n#EXTINF:2,\na.ts\n#EXTINF:3,\nb.ts\n#EXTINF:5,\nc.ts\n" +
    (if endlist { "#EXT-X-ENDLIST" } else { "" }),
  ).unwrap()
}

///|
test "HLS opt-in start offset selects segments and clamps at both ends" {
  for
    (offset, expected) in [
      ("0", 0),
      ("1.5", 0),
      ("2", 1),
      ("4.9", 1),
      ("5", 2),
      ("10", 2),
      ("99", 2),
      ("-1", 2),
      ("-5", 2),
      ("-8", 1),
      ("-10", 0),
      ("-99", 0),
    ] {
    let calls : Array[String] = []
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist(offset),
      (uri, _, _) => {
        calls.push(uri)
        Ok(b"segment")
      },
      prefer_x_start=true,
    ).unwrap()
    let first = reader.next().unwrap().unwrap()
    assert_eq(first.sequence, 100L + expected.to_int64())
    assert_eq(first.media, b"segment")
    assert_eq(calls, [["a.ts", "b.ts", "c.ts"][expected]])
  }
}

///|
test "HLS start remains opt-in and finished playlists start at the beginning" {
  for finished in [false, true] {
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist("8", endlist=finished),
      (_, _, _) => Ok(b"segment"),
      prefer_x_start=finished,
    ).unwrap()
    assert_eq(reader.next().unwrap().unwrap().sequence, 100L)
  }
  for offset in ["invalid", "", "NaN", "Infinity", "-Infinity"] {
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist(offset),
      (_, _, _) => Ok(b"segment"),
      prefer_x_start=true,
    ).unwrap()
    assert_eq(reader.next().unwrap().unwrap().sequence, 100L)
  }
}

///|
test "HLS selected gap preserves discontinuity across a failed read" {
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-START:TIME-OFFSET=3\n#EXTINF:2,\na.ts\n#EXT-X-DISCONTINUITY\n#EXT-X-GAP\n#EXTINF:2,\nb.ts\n#EXTINF:2,\nc.ts",
  ).unwrap()
  let calls : Array[String] = []
  let reader = @libavformat.hls_segment_reader_new(
    playlist,
    (uri, _, _) => {
      calls.push(uri)
      if calls.length() == 1 {
        Err("retry")
      } else {
        Ok(b"segment")
      }
    },
    prefer_x_start=true,
  ).unwrap()
  assert_true(reader.next() is Err("retry"))
  let segment = reader.next().unwrap().unwrap()
  assert_eq(segment.sequence, 2L)
  assert_true(segment.discontinuity)
  assert_eq(calls, ["c.ts", "c.ts"])
}

///|
test "HLS empty playlist with start offset performs no fetch" {
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-START:TIME-OFFSET=-2",
  ).unwrap()
  let reader = @libavformat.hls_segment_reader_new(
    playlist,
    (_, _, _) => Err("unexpected fetch"),
    prefer_x_start=true,
  ).unwrap()
  assert_true(reader.next().unwrap() is None)
}

///|
test "HLS live start index counts from either end and clamps safely" {
  for
    (index, expected) in [
      (0, 0),
      (1, 1),
      (2, 2),
      (99, 2),
      (2147483647, 2),
      (-1, 2),
      (-2, 1),
      (-3, 0),
      (-99, 0),
      (-2147483648, 0),
    ] {
    let calls : Array[String] = []
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist("8"),
      (uri, _, _) => {
        calls.push(uri)
        Ok(b"segment")
      },
      live_start_index=index,
    ).unwrap()
    assert_eq(
      reader.next().unwrap().unwrap().sequence,
      100L + expected.to_int64(),
    )
    assert_eq(calls, [["a.ts", "b.ts", "c.ts"][expected]])
  }
}

///|
test "HLS valid preferred START overrides live index and invalid START falls back" {
  for
    (offset, expected) in [
      ("0", 0),
      ("5", 2),
      ("invalid", 1),
      ("", 1),
      ("NaN", 1),
    ] {
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist(offset),
      (_, _, _) => Ok(b"segment"),
      live_start_index=1,
      prefer_x_start=true,
    ).unwrap()
    assert_eq(
      reader.next().unwrap().unwrap().sequence,
      100L + expected.to_int64(),
    )
  }
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts",
  ).unwrap()
  let reader = @libavformat.hls_segment_reader_new(
    playlist,
    (_, _, _) => Ok(b"segment"),
    live_start_index=-1,
    prefer_x_start=true,
  ).unwrap()
  assert_eq(reader.next().unwrap().unwrap().sequence, 1L)
}

///|
test "HLS live index is ignored for finished lists and safe on empty lists" {
  for index in [-2147483648, -1, 1, 2147483647] {
    let reader = @libavformat.hls_segment_reader_new(
      hls_start_test_playlist("8", endlist=true),
      (_, _, _) => Ok(b"segment"),
      live_start_index=index,
      prefer_x_start=true,
    ).unwrap()
    assert_eq(reader.next().unwrap().unwrap().sequence, 100L)
    let empty = @libavformat.av_hls_parse("#EXTM3U").unwrap()
    let reader = @libavformat.hls_segment_reader_new(
      empty,
      (_, _, _) => Err("unexpected fetch"),
      live_start_index=index,
    ).unwrap()
    assert_true(reader.next().unwrap() is None)
  }
}

///|
test "HLS selected live segment retries without fetching an obsolete key" {
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=old.key\n#EXTINF:2,\na.ts\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:2,\nb.ts",
  ).unwrap()
  let calls : Array[String] = []
  let reader = @libavformat.hls_segment_reader_new(
    playlist,
    (uri, _, _) => {
      calls.push(uri)
      if uri != "b.ts" {
        return Err("unexpected old resource")
      }
      if calls.length() == 1 {
        Err("retry")
      } else {
        Ok(b"segment")
      }
    },
    live_start_index=-1,
  ).unwrap()
  assert_true(reader.next() is Err("retry"))
  assert_eq(reader.next().unwrap().unwrap().sequence, 1L)
  assert_eq(calls, ["b.ts", "b.ts"])
}
