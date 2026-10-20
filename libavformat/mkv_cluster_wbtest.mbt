///|
/// Whitebox tests for the Matroska Cluster/Block slice
/// (`matroska_block.mbt`): SimpleBlock/BlockGroup parsing, the three lacing
/// schemes, timecode computation and packet delivery — ported from FFmpeg
/// 9.0.2 `libavformat/matroskadec.c` (`matroska_parse_laces`,
/// `matroska_parse_block`, the cluster tables).
///
/// Synthetic block payloads are hand-derived from the block layout
/// (VINT track number, BE16 signed time offset, flags, laced frames);
/// the real-file tests pin the ffprobe packet tables of the two docker
/// files used throughout this slice series.

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

///|
/// A SimpleBlock element: id A3 + vint length + payload. */
fn simple_block(
  track_num_vint : Bytes,
  time : Int,
  flags : Int,
  frames : Bytes,
) -> Bytes {
  let payload : Array[Byte] = []
  for i = 0; i < track_num_vint.length(); i = i + 1 {
    payload.push(track_num_vint[i])
  }
  payload.push(((time >> 8) & 0xFF).to_byte())
  payload.push((time & 0xFF).to_byte())
  payload.push(flags.to_byte())
  for i = 0; i < frames.length(); i = i + 1 {
    payload.push(frames[i])
  }
  // NB: `b"£"` would be the two UTF-8 bytes 0xC2 0xA3; the id is one byte.
  el(b"\xA3", Bytes::from_array(payload[:]))
}

///|
/// VINT track number for values < 128 (0x80 | n). */
fn track_vint(n : Int) -> Bytes {
  vint1(0x80 | n)
}

///|
/// A minimal movie with one video track (num 1, 1e6 scale, no defaults). */
fn block_movie(tracks_payload : Bytes, clusters : Bytes) -> Bytes {
  let header = synth_ebml_header(b"webm")
  let tracks = tracks_box(track_entry(block_video_track_children()))
  let body = bcat([tracks_payload, tracks, clusters])
  bcat([header, seg_open_unknown(), body])
}

///|
/// TrackNumber 1, TrackType video, CodecID V_VP8 (no DefaultDuration). */
fn block_video_track_children() -> Bytes {
  bcat([el(b"\xD7", b"\x01"), el(b"\x83", b"\x01"), el(b"\x86", b"V_VP8")])
}

// ---------------------------------------------------------------------------
// lacing (matroska_parse_laces over a synthetic payload)
// ---------------------------------------------------------------------------

///|
test "block: no lacing — one frame of the whole payload" {
  let data = b"\xAA\xBB\xCC"
  let (sizes, hdr) = matroska_parse_laces(data, 0).unwrap()
  assert_eq(sizes.length(), 1)
  assert_eq(sizes[0], 3U)
  assert_eq(hdr, 0)
}

///|
test "block: Xiph lacing splits by 0xFF-chained byte lengths" {
  // lace count 3 (0x02), lengths 2 / 255+1=256, remainder last
  let data = bcat([
    b"\x02", // laces-1 = 2 → 3 frames
    b"\x02", // frame 0: 2 bytes
    b"\xFF\x01", // frame 1: 255+1 = 256
    // frames: 2 bytes + 256 bytes + 1 byte
    b"\x11\x22",
    fixed_bytes(256, 0x55),
    b"\x33",
  ])
  let (sizes, hdr) = matroska_parse_laces(data, 1).unwrap()
  assert_eq(sizes.length(), 3)
  assert_eq(sizes[0], 2U)
  assert_eq(sizes[1], 256U)
  assert_eq(sizes[2], 1U)
  assert_eq(hdr, 1 + 3) // count byte + 1 + 2 length bytes
  // an over-long length chain runs past the payload
  let bad = bcat([b"\x02", b"\x02", b"\xFF\xFF"])
  assert_eq(matroska_parse_laces(bad, 1), Err("EINVAL"))
}

///|
/// `n` bytes of value `v`. */
fn fixed_bytes(n : Int, v : Int) -> Bytes {
  Bytes::make(n, v.to_byte())
}

///|
test "block: fixed-size lacing divides evenly" {
  let data = bcat([b"\x01", b"\xAA\xBB\xCC\xDD"]) // 2 frames of 2
  let (sizes, hdr) = matroska_parse_laces(data, 2).unwrap()
  assert_eq(sizes.length(), 2)
  assert_eq(sizes[0], 2U)
  assert_eq(sizes[1], 2U)
  assert_eq(hdr, 1)
  // uneven division is invalid
  let bad = bcat([b"\x01", b"\xAA\xBB\xCC"]) // 2 frames over 3 bytes
  assert_eq(matroska_parse_laces(bad, 2), Err("EINVAL"))
}

///|
test "block: EBML lacing first uint + signed deltas" {
  // 3 frames: 10, then one explicit delta +2 → 12, the last one takes the
  // remainder (31 - 22 = 9). Only `laces-2` deltas are stored.
  // A delta vint is rebased by 2^(7*width-1)-1: one byte rebases by 63, so
  // +2 encodes as 0xC1 (65).
  let data = bcat([
    b"\x02", // 3 frames
    b"\x8A", // first size: unsigned vint 10
    b"\xC1", // delta +2 (65 - 63)
    fixed_bytes(31, 0x77),
  ])
  let (sizes, hdr) = matroska_parse_laces(data, 3).unwrap()
  assert_eq(sizes.length(), 3)
  assert_eq(sizes[0], 10U)
  assert_eq(sizes[1], 12U)
  assert_eq(sizes[2], 9U)
  assert_eq(hdr, 3)
  // a delta that makes a size negative is rejected
  let bad = bcat([b"\x02", b"\x8A", b"\x8A", fixed_bytes(5, 0x77)])
  assert_eq(matroska_parse_laces(bad, 3), Err("EINVAL"))
  // declared sizes overrunning the payload are rejected
  let bad2 = bcat([b"\x02", b"\x8A", b"\xC1", fixed_bytes(5, 0x77)])
  assert_eq(matroska_parse_laces(bad2, 3), Err("EINVAL"))
}

// ---------------------------------------------------------------------------
// blocks → packets (through a full movie walk)
// ---------------------------------------------------------------------------

///|
/// One cluster with timecode `tc` and `blocks` payload. */
fn cluster_box(tc : UInt64, blocks : Bytes) -> Bytes {
  // the timecode payload must be wide enough to hold the value
  let n = if tc <= 0xFFUL {
    1
  } else if tc <= 0xFFFFUL {
    2
  } else if tc <= 0xFFFFFFFFUL {
    4
  } else {
    8
  }
  let body = bcat([el(b"\xE7", be_u64(tc, n)), blocks])
  bcat([b"\x1F\x43\xB6\x75", vint1(body.length()), body])
}

///|
test "block: simple block delivers one keyframe packet" {
  let block = simple_block(track_vint(1), 0, 0x80, b"\xDE\xAD\xBE\xEF")
  let mh = av_matroska_open(block_movie(b"", cluster_box(0UL, block))).unwrap()
  assert_eq(mh.packets.length(), 1)
  let p = mh.packets[0]
  assert_eq(p.stream_index, 0)
  assert_eq(p.data, b"\xDE\xAD\xBE\xEF")
  assert_eq(p.is_keyframe, true)
  assert_eq(p.pts, 0L)
  assert_eq(p.duration, 0UL)
}

///|
test "block: cluster timecode + block time offset, scaled by track" {
  // cluster tc 1000, block time -250 → pts 750 (time_scale 1.0 via the
  // track's default); codec_delay 0
  let block = simple_block(track_vint(1), -250, 0x80, b"\x01\x02")
  let mh = av_matroska_open(block_movie(b"", cluster_box(1000UL, block))).unwrap()
  assert_eq(mh.packets.length(), 1)
  assert_eq(mh.packets[0].pts, 750L)
}

///|
test "block: laced simple block yields per-lace packets and durations" {
  // flags 0x82 = keyframe + Xiph lacing; 2 frames: one explicit 3-byte
  // length, the last frame takes the remainder (5 - 3 = 2)
  let frames = b"\x11\x12\x13\x14\x15"
  let lace_payload = bcat([b"\x01", b"\x03", frames])
  let block = simple_block(track_vint(1), 0, 0x82, lace_payload)
  // give the track a DefaultDuration so lace durations divide block_duration
  let children = bcat([
    el(b"\xD7", b"\x01"),
    el(b"\x83", b"\x01"),
    el(b"\x86", b"V_VP8"),
    el(b"\x23\xE3\x83", be_u64(1000000UL, 3)), // 1e6 ns
  ])
  let header = synth_ebml_header(b"webm")
  let body = bcat([tracks_box(track_entry(children)), cluster_box(0UL, block)])
  let mh = av_matroska_open(bcat([header, seg_open_unknown(), body])).unwrap()
  assert_eq(mh.packets.length(), 2)
  // no explicit BlockDuration: default_duration * 2 / 1e6 (time_scale) = 2
  assert_eq(mh.packets[0].duration, 1UL) // 2*1/2 - 2*0/2 = 1
  assert_eq(mh.packets[1].duration, 1UL)
  assert_eq(mh.packets[0].data, b"\x11\x12\x13")
  assert_eq(mh.packets[1].data, b"\x14\x15")
  // second frame's pts advanced by its lace duration
  assert_eq(mh.packets[0].pts, 0L)
  assert_eq(mh.packets[1].pts, 1L)
}

///|
test "block: blockgroup duration and reference keyframe logic" {
  // a BlockGroup with a ReferenceBlock is not a keyframe; BlockDuration
  // overrides the default
  let bg_body = bcat([
    el(b"\xA1", b"\x81\x00\x00\x00\xAA\xBB"), // Block: track 1, time 0, no lacing
    el(b"\x9B", be_u64(42UL, 1)), // BlockDuration 42
    el(b"\xFB", b"\x00\x01"), // ReferenceBlock -1... payload is a signed int
  ])
  let blockgroup = bcat([b"\xA0", vint1(bg_body.length()), bg_body])
  let mh = av_matroska_open(block_movie(b"", cluster_box(0UL, blockgroup))).unwrap()
  assert_eq(mh.packets.length(), 1)
  let p = mh.packets[0]
  assert_eq(p.is_keyframe, false) // has a reference
  assert_eq(p.duration, 42UL)
  assert_eq(p.data, b"\xAA\xBB")
}

///|
test "block: two clusters deliver in payload order" {
  let c1 = cluster_box(0UL, simple_block(track_vint(1), 0, 0x80, b"\x01"))
  let c2 = cluster_box(500UL, simple_block(track_vint(1), 0, 0x80, b"\x02"))
  let mh = av_matroska_open(block_movie(b"", bcat([c1, c2]))).unwrap()
  assert_eq(mh.packets.length(), 2)
  assert_eq(mh.packets[0].data, b"\x01")
  assert_eq(mh.packets[1].data, b"\x02")
  assert_eq(mh.packets[1].pts, 500L)
  // first_cluster_pos points at the first cluster's id
  assert_true(mh.first_cluster_pos > 0)
}

///|
test "block: unknown track number in a block is rejected" {
  let block = simple_block(track_vint(9), 0, 0x80, b"\x01")
  // av_matroska_open surfaces the parse error from the unknown-track block
  assert_eq(
    av_matroska_open(block_movie(b"", cluster_box(0UL, block))).unwrap_err_pk(),
    "EINVAL",
  )
}

// ---------------------------------------------------------------------------
// real files vs ffprobe packet tables
// ---------------------------------------------------------------------------

///|
test "block: real webm packet stream matches ffprobe" {
  let bytes = @libavutil.av_base64_decode(cluster_real_webm_b64, 2000).unwrap()
  // the prefix ends right after the second packet, so the walk hits EOF in
  // the middle of the third block and keeps the two it finished
  let mh = av_matroska_open(bytes).unwrap()
  assert_eq(mh.packets.length(), 2)
  // ffprobe: audio packet — pos 697, size 307, pts -7, keyframe
  let p0 = mh.packets[0]
  assert_eq(p0.stream_index, 1)
  assert_eq(p0.pos, 697L)
  assert_eq(p0.data.length(), 307)
  assert_eq(p0.pts, -7L)
  assert_eq(p0.is_keyframe, true)
  // ffprobe: video packet — pos 1011, size 759, pts 0, keyframe
  let p1 = mh.packets[1]
  assert_eq(p1.stream_index, 0)
  assert_eq(p1.pos, 1011L)
  assert_eq(p1.data.length(), 759)
  assert_eq(p1.pts, 0L)
  assert_eq(p1.is_keyframe, true)
}

///|
test "block: real mkv packet stream matches ffprobe" {
  let bytes = @libavutil.av_base64_decode(cluster_real_mkv_b64, 3500).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  assert_eq(mh.packets.length(), 2)
  // ffprobe: audio packet — pos 775, size 256, pts -23, keyframe
  let p0 = mh.packets[0]
  assert_eq(p0.stream_index, 1)
  assert_eq(p0.pos, 775L)
  assert_eq(p0.data.length(), 256)
  assert_eq(p0.pts, -23L)
  assert_eq(p0.is_keyframe, true)
  // ffprobe: video packet — pos 1038, size 1931, pts 0, keyframe
  let p1 = mh.packets[1]
  assert_eq(p1.stream_index, 0)
  assert_eq(p1.pos, 1038L)
  assert_eq(p1.data.length(), 1931)
  assert_eq(p1.pts, 0L)
  assert_eq(p1.is_keyframe, true)
}

///|
/// Test-only: the error of an open. */
fn Result::unwrap_err_pk(r : Result[MatroskaHeader, String]) -> String {
  match r {
    Err(e) => e
    Ok(_) => ""
  }
}
