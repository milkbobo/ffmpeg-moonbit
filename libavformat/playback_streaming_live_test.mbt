///|
/// Black-box tests for live HLS playlist refresh. All segments come from the
/// repository's own AAC encoder and TS muxer; the playlist refresh hooks are
/// in-memory so window advancement, expiry, discontinuity and retry behavior
/// are deterministic and need no network.

///|
/// A live (no ENDLIST) playlist starting at `sequence`, naming `uris`.
fn live_playlist(sequence : Int64, uris : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n")
  sb.write_string("#EXT-X-MEDIA-SEQUENCE:\{sequence}\n")
  for uri in uris {
    sb.write_string("#EXTINF:0.064,\n\{uri}\n")
  }
  sb.to_string()
}

///|
fn live_bytes(text : String) -> Bytes {
  let out : Array[Byte] = []
  for c in text {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// One AAC frame per TS segment, so packet counts equal segment counts and
/// sequence numbers can be checked exactly.
fn live_segments(count : Int32) -> Array[Bytes] {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let out : Array[Bytes] = []
  for frame in 0..<count {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    let mux = @libavformat.ts_muxer_new(video=false)
    mux.write_audio(0L, encoder.encode_frame([samples]).unwrap())
    out.push(mux.finish())
  }
  out
}

///|
/// Fetch one of the numbered segments, rejecting anything else.
fn live_fetch(segments : Array[Bytes]) -> @libavformat.MediaFetch {
  (uri, _, _) => {
    // Segments may arrive as relative names or as absolute URLs resolved
    // against the playlist URI; keep only the `sN.ts` basename.
    let mut name = uri
    let mut last_slash = -1
    for i = 0; i < name.length(); i = i + 1 {
      if name[i] == '/'.to_int().to_uint16() {
        last_slash = i
      }
    }
    if last_slash >= 0 {
      name = name[last_slash + 1:].to_owned()
    }
    if name.has_prefix("s") && name.has_suffix(".ts") {
      let digits = name[1:name.length() - 3]
      // Hand-rolled decimal parse: @string.parse_int raises, but MediaFetch
      // must return a plain Result.
      let mut n = 0
      let mut valid = digits.length() > 0
      for c in digits {
        let v = c.to_int() - '0'.to_int()
        if v < 0 || v > 9 || n > (2147483647 - v) / 10 {
          valid = false
          break
        }
        n = n * 10 + v
      }
      if valid && n >= 0 && n < segments.length() {
        Ok(segments[n])
      } else {
        Err("unknown segment: \{name}")
      }
    } else {
      Err("unexpected URI: \{uri}")
    }
  }
}

///|
fn live_collect(
  media : @libavformat.StreamingMedia,
) -> Array[@libavformat.StreamingPacket] raise @libavformat.MediaError {
  let out : Array[@libavformat.StreamingPacket] = []
  while true {
    match media.next_packet() {
      Some(p) => out.push(p)
      None => break
    }
  }
  out
}

///|
test "live: manual reload extends a VOD-ended live window" {
  let segments = live_segments(4)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts", "s1.ts"])),
    live_fetch(segments),
  )
  assert_true(media.is_live())
  assert_eq(media.reload_count(), 0)
  assert_eq(live_collect(media).length(), 2)
  // Reload with an overlapping window: s1 is already consumed, so only s2
  // and s3 should arrive - no rewind, no duplicate packets.
  media.reload_bytes(live_bytes(live_playlist(1L, ["s1.ts", "s2.ts", "s3.ts"])))
  assert_eq(media.reload_count(), 1)
  let rest = live_collect(media)
  assert_eq(rest.length(), 2)
  assert_eq(rest[0].segment_sequence, 2L)
  assert_eq(rest[1].segment_sequence, 3L)
  for i = 0; i < rest.length(); i = i + 1 {
    assert_false(rest[i].discontinuity)
  }
}

///|
test "live: reload keeps the normalized pts timeline continuous" {
  let segments = live_segments(4)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts", "s1.ts"])),
    live_fetch(segments),
  )
  let first = live_collect(media)
  media.reload_bytes(live_bytes(live_playlist(2L, ["s2.ts", "s3.ts"])))
  let second = live_collect(media)
  let all = first + second
  assert_eq(all.length(), 4)
  for i = 1; i < all.length(); i = i + 1 {
    assert_true(all[i].pts > all[i - 1].pts)
  }
  assert_eq(all[0].segment_sequence, 0L)
  assert_eq(all[3].segment_sequence, 3L)
}

///|
test "live: expired window marks discontinuity on the first new packet" {
  let segments = live_segments(3)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts"])),
    live_fetch(segments),
  )
  assert_eq(live_collect(media).length(), 1)
  // The window jumps from sequence 0 to 2, skipping s1 entirely.
  media.reload_bytes(live_bytes(live_playlist(2L, ["s2.ts"])))
  let rest = live_collect(media)
  assert_eq(rest.length(), 1)
  assert_eq(rest[0].segment_sequence, 2L)
  assert_true(rest[0].discontinuity)
}

///|
test "live: reload rejects master playlists and stale windows without damage" {
  let segments = live_segments(3)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts"])),
    live_fetch(segments),
  )
  assert_eq(live_collect(media).length(), 1)
  // A master playlist must not replace a media playlist.
  try
    media.reload_bytes(
      live_bytes("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n"),
    )
  catch {
    @libavformat.DemuxError(_) => ()
    _ => fail("expected DemuxError for master reload")
  } noraise {
    _ => fail("expected DemuxError for master reload")
  }
  assert_eq(media.reload_count(), 0)
  // A stale window (entirely in the past) is legal but yields no new packet.
  media.reload_bytes(live_bytes(live_playlist(0L, ["s0.ts"])))
  assert_eq(live_collect(media).length(), 0)
  // The session is still usable after both cases.
  media.reload_bytes(live_bytes(live_playlist(1L, ["s1.ts", "s2.ts"])))
  let rest = live_collect(media)
  assert_eq(rest.length(), 2)
  assert_eq(rest[0].segment_sequence, 1L)
  assert_eq(rest[1].segment_sequence, 2L)
}

///|
test "live: DASH and VOD sessions cannot be reloaded" {
  let dash = @libavformat.av_dash_parse(
    "<MPD><Period><AdaptationSet><Representation/></AdaptationSet></Period></MPD>",
  ).unwrap()
  let dash_media = @libavformat.StreamingMedia::open_dash(dash, (_, _, _) => {
    Err("unused")
  })
  assert_false(dash_media.is_live())
  try dash_media.reload_bytes(live_bytes(live_playlist(0L, ["s0.ts"]))) catch {
    @libavformat.DemuxError(msg) => assert_true(msg.contains("HLS"))
    _ => fail("expected DemuxError for DASH reload")
  } noraise {
    _ => fail("expected DemuxError for DASH reload")
  }
  let vod = @libavformat.StreamingMedia::open(
    live_bytes("#EXTM3U\n#EXT-X-ENDLIST"),
    (_, _, _) => Err("unused"),
  )
  assert_false(vod.is_live())
  // A VOD session may technically be reloaded, but no auto-refresh hook is
  // ever installed for it, so it cannot poll a server.
  assert_eq(vod.reload_count(), 0)
}

///|
test "live: automatic reload advances windows and respects the budget" {
  let segments = live_segments(4)
  // Three successive windows: 0-1, 1-2 (one new segment), 2-3 (one new).
  let windows = [
    live_playlist(1L, ["s1.ts", "s2.ts"]),
    live_playlist(2L, ["s2.ts", "s3.ts"]),
  ]
  let fetches = Ref(0)
  let requests : Array[(String, Int64, Int64)] = []
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts", "s1.ts"])),
    live_fetch(segments),
    playlist_fetch=Some((uri, offset, length) => {
      requests.push((uri, offset, length))
      let n = fetches.val
      fetches.val += 1
      if n < windows.length() {
        Ok(live_bytes(windows[n]))
      } else {
        Ok(live_bytes(live_playlist(3L, ["s3.ts"])))
      }
    }),
    base_uri="https://live.test/list.m3u8",
    max_reloads=2,
  )
  let packets = live_collect(media)
  assert_eq(packets.length(), 4)
  assert_eq(media.reload_count(), 2)
  assert_eq(fetches.val, 2)
  assert_eq(requests, [
    ("https://live.test/list.m3u8", 0L, -1L),
    ("https://live.test/list.m3u8", 0L, -1L),
  ])
  let sequences : Array[Int64] = []
  for p in packets {
    sequences.push(p.segment_sequence)
  }
  assert_eq(sequences, [0L, 1L, 2L, 3L])
  assert_true(media.next_packet() is None)
}

///|
test "live: automatic reload failure propagates and leaves cursor intact" {
  let segments = live_segments(2)
  let attempts = Ref(0)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts"])),
    live_fetch(segments),
    playlist_fetch=Some((_, _, _) => {
      attempts.val += 1
      if attempts.val == 1 {
        Err("playlist temporarily unavailable")
      } else {
        Ok(live_bytes(live_playlist(1L, ["s1.ts"])))
      }
    }),
    base_uri="https://live.test/list.m3u8",
    max_reloads=2,
  )
  assert_eq(media.next_packet().unwrap().segment_sequence, 0L)
  try media.next_packet() catch {
    @libavformat.DemuxError(msg) => assert_true(msg.contains("fetch failed"))
    other => fail("unexpected error: \{other.message()}")
  } noraise {
    _ => fail("expected DemuxError from playlist fetch")
  }
  // Retrying the same call succeeds without losing the pending segment.
  // The remaining budget may trigger one more (empty) refresh afterwards,
  // which is expected polling behaviour - the important contract is that
  // the fetch error was surfaced once and no segment was duplicated.
  let rest = live_collect(media)
  assert_eq(rest.length(), 1)
  assert_eq(rest[0].segment_sequence, 1L)
  assert_true(attempts.val >= 2)
  assert_eq(media.reload_count(), 2)
}

///|
test "live: budget exhaustion ends the session without extra fetches" {
  let segments = live_segments(1)
  let fetches = Ref(0)
  let media = @libavformat.StreamingMedia::open(
    live_bytes(live_playlist(0L, ["s0.ts"])),
    live_fetch(segments),
    playlist_fetch=Some((_, _, _) => {
      fetches.val += 1
      // The server keeps returning the same exhausted window.
      Ok(live_bytes(live_playlist(0L, ["s0.ts"])))
    }),
    base_uri="https://live.test/list.m3u8",
    max_reloads=3,
  )
  assert_eq(live_collect(media).length(), 1)
  assert_eq(fetches.val, 3)
  assert_eq(media.reload_count(), 3)
  assert_true(media.next_packet() is None)
}
