///|
/// Whitebox tests for the Matroska segment slice (`matroska.mbt`: Segment
/// walk, Info, SeekHead, resync, execute_seekhead), ported from FFmpeg 9.0.2
/// `libavformat/matroskadec.c`.
///
/// Synthetic layouts are hand-derived; the two real-file tests pin the same
/// docker-generated files as ebml_real_wbtest.mbt (1024-byte prefixes carry
/// header + SeekHead×2 + Info + Tracks + the first Cluster).

// ---------------------------------------------------------------------------
// real files (1024-byte prefixes)
// ---------------------------------------------------------------------------

test "matroska: real webm segment walk (docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_webm_1024_b64, 1200).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  // Info: TimecodeScale default 1000000, Duration 1008 (= 1.008 s),
  // MuxingApp Lavf63.1.102, no Title; Segment at 48; first Cluster at 685.
  assert_eq(mh.is_webm, true)
  assert_eq(mh.time_scale, 1000000UL)
  assert_eq(mh.duration, 1008.0)
  assert_eq(mh.title, None)
  assert_eq(mh.muxingapp, Some("Lavf63.1.102"))
  assert_eq(mh.date_utc, None)
  assert_eq(mh.segment_start, 48L)
  assert_eq(mh.first_cluster_pos, 685L)
  // Two SeekHeads of four entries each (Info/Tracks/Tags/Cues), identical.
  assert_eq(mh.seekhead.length(), 8)
  let ids = [
    matroska_id_info, matroska_id_tracks, matroska_id_tags, matroska_id_cues,
  ]
  let poss = [161UL, 214UL, 420UL, 22692UL]
  for i = 0; i < 8; i = i + 1 {
    assert_eq(mh.seekhead[i].id, ids[i % 4])
    assert_eq(mh.seekhead[i].pos, poss[i % 4])
  }
}

///|
test "matroska: real mkv segment walk (docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_mkv_1024_b64, 1200).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  assert_eq(mh.is_webm, false)
  assert_eq(mh.time_scale, 1000000UL)
  assert_eq(mh.duration, 1000.0)
  assert_eq(mh.muxingapp, Some("Lavf63.1.102"))
  assert_eq(mh.segment_start, 52L)
  assert_eq(mh.first_cluster_pos, 576L)
  assert_eq(mh.seekhead.length(), 8)
  assert_eq(mh.seekhead[0].id, matroska_id_info)
  assert_eq(mh.seekhead[0].pos, 161UL)
  assert_eq(mh.seekhead[3].id, matroska_id_cues)
  assert_eq(mh.seekhead[3].pos, 16712UL)
}

// ---------------------------------------------------------------------------
// synthetic segments
// ---------------------------------------------------------------------------

///|
/// The EBML header of ebml_wbtest's builder shape (doctype bytes in). */
fn synth_ebml_header(doctype : Bytes) -> Bytes {
  let children = bcat([
    el(b"\x42\xF7", b"\x01"),
    el(b"\x42\xF2", b"\x04"),
    el(b"\x42\xF3", b"\x08"),
    el(b"\x42\x82", doctype),
    el(b"\x42\x85", b"\x02"),
  ])
  bcat([b"\x1A\x45\xDF\xA3", vint1(children.length()), children])
}

///|
/// A u64 as `n` big-endian bytes (uint element payloads). */
fn be_u64(v : UInt64, n : Int32) -> Bytes {
  let a : Array[Byte] = []
  let mut i = n - 1
  while i >= 0 {
    a.push(((v >> (i * 8)) & 0xFFUL).to_byte())
    i = i - 1
  }
  Bytes::from_array(a[:])
}

///|
/// The Segment id + an 8-byte unknown-length marker. */
fn seg_open_unknown() -> Bytes {
  bcat([b"\x18\x53\x80\x67", b"\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF"])
}

///|
/// A well-formed empty Cluster: id + 1-byte length 0. The walk stops on
/// the id (EBML_STOP); without the length byte, an unknown element or a
/// second parse at this position would read past EOF. */
fn cluster_id() -> Bytes {
  b"\x1F\x43\xB6\x75\x80"
}

///|
/// An Info element with the given TimecodeScale payload. */
fn info_with_timescale(ts : UInt64) -> Bytes {
  let body = el(b"\x2A\xD7\xB1", be_u64(ts, 2))
  bcat([b"\x15\x49\xA9\x66", vint1(body.length()), body])
}

///|
test "matroska: synthetic segment with Info and cluster stop" {
  let info_children = bcat([
    el(b"\x2A\xD7\xB1", be_u64(500UL, 2)), // TimecodeScale 500
    el(b"\x44\x89", b"\x40\x8F\x80\x00\x00\x00\x00\x00"), // Duration 1008.0
    el(b"\x7B\xA9", b"clip"), // Title
    el(b"\x4D\x80", b"muxer"), // MuxingApp
    el(b"\x44\x61", b"\x00\x01\x02\x03\x04\x05\x06\x07"), // DateUTC
    b"\xEC",
    vint1(1),
    b"\x00", // VOID, skipped
  ])
  let info = bcat([
    b"\x15\x49\xA9\x66",
    vint1(info_children.length()),
    info_children,
  ])
  let header = synth_ebml_header(b"matroska")
  // 2-byte segment length covering Info + the cluster id
  let payload_len = (info.length() + 4).to_uint64()
  let seg_len : Array[Byte] = [
    (0x40 | ((payload_len >> 8) & 0x3FUL).to_int()).to_byte(),
    (0x80 | (payload_len & 0xFFUL).to_int()).to_byte(),
  ]
  let segment = bcat([
    b"\x18\x53\x80\x67",
    Bytes::from_array(seg_len[:]),
    info,
    cluster_id(),
  ])
  let mh = av_matroska_open(bcat([header, segment])).unwrap()
  assert_eq(mh.time_scale, 500UL)
  assert_eq(mh.duration, 1008.0)
  assert_eq(mh.title, Some("clip"))
  assert_eq(mh.muxingapp, Some("muxer"))
  assert_eq(mh.date_utc, Some(b"\x00\x01\x02\x03\x04\x05\x06\x07"))
  assert_eq(mh.is_webm, false)
  assert_eq(mh.segment_start, (header.length() + 4 + 2).to_int64())
  assert_eq(
    mh.first_cluster_pos,
    (header.length() + 4 + 2 + info.length()).to_int64(),
  )
}

///|
test "matroska: unknown-length segment ends at the cluster stop" {
  let header = synth_ebml_header(b"webm")
  let info = info_with_timescale(1000UL)
  let seg = bcat([seg_open_unknown(), info, cluster_id()])
  let mh = av_matroska_open(bcat([header, seg])).unwrap()
  assert_eq(mh.is_webm, true)
  assert_eq(mh.time_scale, 1000UL)
  assert_eq(
    mh.first_cluster_pos,
    (header.length() + 4 + 8 + info.length()).to_int64(),
  )
}

///|
test "matroska: empty Info leaves the defaults" {
  let header = synth_ebml_header(b"webm")
  let seg = bcat([
    seg_open_unknown(),
    b"\x15\x49\xA9\x66", // Info of length 0
    b"\x80",
    cluster_id(),
  ])
  let mh = av_matroska_open(bcat([header, seg])).unwrap()
  assert_eq(mh.time_scale, 1000000UL)
  assert_eq(mh.duration, 0.0)
  assert_eq(mh.title, None)
}

///|
test "matroska: SeekHead back-jump parses an Info after the first cluster" {
  // Cluster-first layout: the walk stops at the Cluster id; the SeekHead
  // entry points at an Info behind it, which execute_seekhead parses.
  let header = synth_ebml_header(b"webm")
  let info = info_with_timescale(250UL)
  // SeekHead right after the segment open: [SeekHead][Cluster][VOID][Info].
  // Positions are relative to segment_start (= header + 4 + 8).
  // [SeekHead 19][Cluster 5 (id + 1-byte length 0)][VOID 4] — the sizes are
  // fixed by construction; the Info must land exactly at info_pos
  let info_pos = 19 + 5 + 4
  let entry_children = bcat([
    el(b"\x53\xAB", be_u64(0x1549A966UL, 4)), // SeekID = Info
    el(b"\x53\xAC", be_u64(info_pos.to_uint64(), 1)), // SeekPosition
  ])
  let seek_entry = bcat([
    b"\x4D\xBB",
    vint1(entry_children.length()),
    entry_children,
  ])
  let seekhead = bcat([
    b"\x11\x4D\x9B\x74",
    vint1(seek_entry.length()),
    seek_entry,
  ])
  // seekhead.length() + cluster + VOID must equal info_pos
  let seg = bcat([
    seg_open_unknown(),
    seekhead,
    cluster_id(),
    b"\xEC",
    vint1(2),
    b"\x00\x00", // VOID padding so the Info lands at info_pos
    info,
  ])
  assert_eq(seekhead.length() + cluster_id().length() + 4, info_pos)
  let mh = av_matroska_open(bcat([header, seg])).unwrap()
  // The walk never reached the Info (it sits after the stop);
  // execute_seekhead jumped there and parsed TimecodeScale 250.
  assert_eq(mh.time_scale, 250UL)
  assert_eq(mh.seekhead.length(), 1)
  assert_eq(mh.seekhead[0].id, matroska_id_info)
  assert_eq(mh.seekhead[0].pos, info_pos.to_uint64())
  assert_eq(
    mh.first_cluster_pos,
    (header.length() + 4 + 8 + seekhead.length()).to_int64(),
  )
}

///|
test "matroska: resync skips garbage before the Info" {
  let header = synth_ebml_header(b"webm")
  let info = info_with_timescale(750UL)
  let seg = bcat([
    seg_open_unknown(),
    b"\x00\x00\x00\x00\x00", // garbage: 0x00 is invalid as a first byte
    info,
    cluster_id(),
  ])
  let mh = av_matroska_open(bcat([header, seg])).unwrap()
  assert_eq(mh.time_scale, 750UL)
  assert_eq(mh.duration, 0.0)
}
