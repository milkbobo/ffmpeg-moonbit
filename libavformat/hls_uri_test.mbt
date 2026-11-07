///|
test "HLS references resolve against the playlist path without its query" {
  let base = "https://example.com/live/list.m3u8?token=a/b#old"
  assert_eq(
    @libavformat.hls_resolve_uri(base, "segment.ts"),
    "https://example.com/live/segment.ts",
  )
  assert_eq(
    @libavformat.hls_resolve_uri(base, "?token=new"),
    "https://example.com/live/list.m3u8?token=new",
  )
  assert_eq(
    @libavformat.hls_resolve_uri(base, "#new"),
    "https://example.com/live/list.m3u8?token=a/b#new",
  )
}

///|
test "HLS URI paths preserve query and relative base semantics" {
  assert_eq(
    @libavformat.hls_resolve_uri("/live/list.m3u8", "/link/../seg.ts"),
    "/link/../seg.ts",
  )
  assert_eq(
    @libavformat.hls_resolve_uri("https://example.com/list.m3u8", "seg.ts"),
    "https://example.com/seg.ts",
  )
  assert_eq(
    @libavformat.hls_resolve_uri("https://example.com", "seg.ts"),
    "https://example.com/seg.ts",
  )
  assert_eq(
    @libavformat.hls_resolve_uri("live/list.m3u8", "../seg.ts?x=/a/../b"),
    "live/../seg.ts?x=/a/../b",
  )
  assert_eq(@libavformat.hls_resolve_uri("list.m3u8", "../seg.ts"), "../seg.ts")
  assert_eq(
    @libavformat.hls_resolve_uri(
      "https://example.com/a/list.m3u8", "/x/../seg.ts#part/../x",
    ),
    "https://example.com/seg.ts#part/../x",
  )
  assert_eq(
    @libavformat.hls_resolve_uri("list.m3u8", "//cdn.example/seg.ts"),
    "//cdn.example/seg.ts",
  )
  assert_eq(
    @libavformat.hls_resolve_uri(
      "https://example.com/live/list.m3u8", "seg.ts?next=https://cdn.example/x",
    ),
    "https://example.com/live/seg.ts?next=https://cdn.example/x",
  )
}
