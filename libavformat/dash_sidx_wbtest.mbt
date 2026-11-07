///|
fn sidx_test_put32(bytes : Array[Byte], off : Int32, value : Int32) -> Unit {
  for i in 0..<4 {
    bytes[off + i] = ((value >> (24 - 8 * i)) & 255).to_byte()
  }
}

///|
fn sidx_test_index() -> Bytes {
  // ISO BMFF version 0, timescale 1000, first_offset 2, one 3-byte reference.
  b"\x00\x00\x00\x2csidx\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\xe8\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x03\xe8\x90\x00\x00\x00"
}

///|
test "DASH index range skips leading boxes and ignores trailing boxes" {
  let prefix = b"\x00\x00\x00\x08free"
  let suffix = b"\x00\x00\x00\x08skip"
  let index = prefix + sidx_test_index() + suffix
  let parsed = dash_parse_sidx(index, 100L).unwrap()
  assert_eq(parsed.media_start, 154L)
  assert_eq(parsed.sizes, [3L])
  let extended = b"\x00\x00\x00\x01free\x00\x00\x00\x00\x00\x00\x00\x10"
  assert_eq(
    dash_parse_sidx(extended + sidx_test_index(), 100L).unwrap().media_start,
    162L,
  )
}

///|
test "DASH index box scan rejects malformed skipped boxes" {
  for
    bytes in [
      b"\x00\x00\x00\x01free", b"\x00\x00\x00\x07free", b"\x00\x00\x00\x20free",
      b"\x00\x00\x00\x08freeX", b"\x00\x00\x00\x01free\xff\xff\xff\xff\xff\xff\xff\xff",
      b"\x00\x00\x00\x00free",
    ] {
    assert_true(dash_parse_sidx(bytes, 0L) is Err(_))
  }
  assert_true(
    dash_parse_sidx(
      b"\x00\x00\x00\x08free" + sidx_test_index(),
      9223372036854775807L,
    )
    is Err("dash: sidx offset overflow"),
  )
}

///|
test "DASH real MP4 wider indexRange preserves both media fragments" {
  let original = @libavutil.av_base64_decode(dash_sb_mp4_b64, 100000).unwrap()
  let file = original[0:817].to_owned() +
    b"\x00\x00\x00\x08free" +
    original[817:].to_owned()
  let mpd = av_dash_parse(
    "<MPD><Period><AdaptationSet><Representation><BaseURL>file.mp4</BaseURL><SegmentBase indexRange=\"817-888\"><Initialization range=\"0-816\"/></SegmentBase></Representation></AdaptationSet></Period></MPD>",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let calls : Array[(Int64, Int64)] = []
  let reader = dash_segment_reader_new(rep, (_, offset, length) => {
    calls.push((offset, length))
    let start = offset.to_int()
    let end = start + length.to_int()
    if start < 0 || length < 0L || end > file.length() {
      return Err("unexpected range")
    }
    Ok(file[start:end].to_owned())
  })
  let first = reader.next().unwrap().unwrap()
  let second = reader.next().unwrap().unwrap()
  assert_eq(first.initialization, original[0:817].to_owned())
  assert_eq(first.media, original[881:2804].to_owned())
  assert_eq(second.media, original[2804:4139].to_owned())
  assert_eq(av_mov_open(first.bytes()).unwrap().tracks[0].samples.length(), 5)
  assert_eq(av_mov_open(second.bytes()).unwrap().tracks[0].samples.length(), 5)
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [(0L, 817L), (817L, 72L), (889L, 1923L), (2812L, 1335L)])
}

///|
test "DASH sidx version 0 and extended-size boxes retain absolute offsets" {
  let regular = sidx_test_index()
  let parsed = dash_parse_sidx(regular, 100L).unwrap()
  assert_eq(parsed.media_start, 146L)
  assert_eq(parsed.sizes, [3L])
  let extended : Array[Byte] = [
    b'\x00', b'\x00', b'\x00', b'\x01', b's', b'i', b'd', b'x', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x34',
  ]
  for byte in regular[8:] {
    extended.push(byte)
  }
  let parsed = dash_parse_sidx(Bytes::from_array(extended), 100L).unwrap()
  assert_eq(parsed.media_start, 154L)
  assert_eq(parsed.sizes, [3L])
}

///|
test "DASH sidx rejects every truncated version header without a panic" {
  for
    index in [
      sidx_test_index(),
      fmp4_sidx(1, 1000, 0L, [Fmp4SidxRef::new(3, 1000L)]).unwrap(),
    ] {
    for length in 0..<index.length() {
      let prefix : Array[Byte] = [ for byte in index[0:length] => byte ]
      if length >= 8 {
        // Also exercise boxes whose declared size matches the truncated data.
        sidx_test_put32(prefix, 0, length)
      }
      assert_true(dash_parse_sidx(Bytes::from_array(prefix), 0L) is Err(_))
    }
  }
}

///|
test "DASH sidx rejects hierarchy zero timescale and offset overflow" {
  let index = sidx_test_index()
  let hierarchy : Array[Byte] = [ for byte in index => byte ]
  hierarchy[32] = b'\x80'
  assert_true(
    dash_parse_sidx(Bytes::from_array(hierarchy), 0L)
    is Err("dash: hierarchical sidx references are unsupported"),
  )
  let zero_time : Array[Byte] = [ for byte in index => byte ]
  sidx_test_put32(zero_time, 16, 0)
  assert_true(
    dash_parse_sidx(Bytes::from_array(zero_time), 0L)
    is Err("dash: invalid sidx timescale"),
  )
  assert_true(
    dash_parse_sidx(index, 9223372036854775800L)
    is Err("dash: sidx offset overflow"),
  )
  assert_true(
    dash_parse_sidx(index, 9223372036854775760L)
    is Err("dash: sidx offset overflow"),
  )
  let empty : Array[Byte] = [ for byte in index => byte ]
  sidx_test_put32(empty, 32, 0)
  assert_true(
    dash_parse_sidx(Bytes::from_array(empty), 0L)
    is Err("dash: empty sidx reference"),
  )
}

///|
test "DASH reader retries a malformed index before fetching any media" {
  let mpd = av_dash_parse(
    "<MPD><Period><AdaptationSet><Representation><BaseURL>file.mp4</BaseURL><SegmentBase indexRange=\"0-43\"/></Representation></AdaptationSet></Period></MPD>",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let bad : Array[Byte] = [ for byte in sidx_test_index() => byte ]
  bad[32] = b'\x80'
  let calls : Array[(Int64, Int64)] = []
  let reader = dash_segment_reader_new(rep, (_, offset, length) => {
    calls.push((offset, length))
    if offset == 0L {
      Ok(
        if calls.length() == 1 {
          Bytes::from_array(bad)
        } else {
          sidx_test_index()
        },
      )
    } else if offset == 46L && length == 3L {
      Ok(b"abc")
    } else {
      Err("unexpected media range")
    }
  })
  assert_true(
    reader.next() is Err("dash: hierarchical sidx references are unsupported"),
  )
  let segment = reader.next().unwrap().unwrap()
  assert_eq(segment.media, b"abc")
  assert_true(reader.next().unwrap() is None)
  assert_eq(calls, [(0L, 44L), (0L, 44L), (46L, 3L)])
}
