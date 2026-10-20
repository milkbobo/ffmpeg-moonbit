///|
/// Whitebox tests for the advanced edit-list slice, ported from FFmpeg 9.0.2
/// `libavformat/mov.c` (`mov_fix_index`, `find_prev_closest_index`,
/// `get_edit_list_entry`, `fix_index_entry_timestamps`,
/// `mov_estimate_video_delay`, the elst pre-pass branch and the fragmented
/// auto-disable).
///
/// Expected values are hand-derived from the mov.c walk: discarded leading
/// frames keep strictly increasing timestamps via the frame-duration buffer
/// rewrite, the timeline starts after empty edits, partial audio frames trim
/// `skip_samples`, and a positive `min_corrected_pts` re-zeros the first
/// video PTS. The real-file counterpart (ffprobe's -1024 first packet) lives
/// in mp4_real_wbtest.mbt.

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn edts_of(entries : Array[(UInt32, Int32)]) -> Array[Byte] {
  box(b"edts", elst_box(entries))
}

///|
/// A 6-sample video track (10/frame) with keyframes at samples 0 and 3. */
fn keyed_video_movie(edts : Array[Byte]) -> Mp4Movie {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 64, 64)),
    stts_box([(6, 10)]),
    [],
    stsc_box([(1, 6, 1)]),
    stsz_box(10, 6),
    stco_box([500]),
    stss_box([1, 4]),
  )
  let trak = build_trak(
    tkhd_box(1, 60, 64, 64),
    mdhd_box(1000, 60),
    hdlr_box(b"vide"),
    stbl,
    edts,
  )
  av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 60), trak, false))).unwrap()
}

// ---------------------------------------------------------------------------
// mov_fix_index
// ---------------------------------------------------------------------------

///|
test "elst: mid-media edit drops leading frames but rewrites their dts" {
  // Single edit (duration 4000, media_time 20): frames 0-1 fall before the
  // media time. The walk starts at the previous key frame (sample 0), so
  // they stay in the index flagged discard with timestamps stepped back
  // through the frame-duration buffer; the kept timeline starts at 0.
  let t = keyed_video_movie(edts_of([(4000, 20)])).tracks[0]
  assert_eq(t.samples.length(), 6)
  let disc = [true, true, false, false, false, false]
  let dts : Array[Int64] = [-20L, -10L, 0L, 10L, 20L, 30L]
  let kf = [true, false, false, true, false, false]
  for i = 0; i < 6; i = i + 1 {
    assert_eq(t.samples[i].discard, disc[i])
    assert_eq(t.samples[i].dts, dts[i])
    assert_eq(t.samples[i].keyframe, kf[i])
  }
  assert_eq(t.start_time, 0)
  assert_eq(t.min_corrected_pts, 0)
  assert_eq(t.skip_samples, 0)
}

///|
test "elst: empty first edit offsets the timeline and sets start_time" {
  // elst [(500, -1), (1000, 0)]: the 500-unit empty edit shifts every kept
  // timestamp and becomes the stream start_time; min_corrected_pts nets to
  // zero (the 500 computed inside minus the 500 empty-edit sum).
  let t = keyed_video_movie(edts_of([(500, -1), (1000, 0)])).tracks[0]
  assert_eq(t.samples.length(), 6)
  for i = 0; i < 6; i = i + 1 {
    assert_eq(t.samples[i].discard, false)
    assert_eq(t.samples[i].dts, (500 + i * 10).to_int64())
  }
  assert_eq(t.start_time, 500)
  assert_eq(t.min_corrected_pts, 0)
}

///|
test "elst: audio partial first frame trims skip_samples" {
  // AAC-style: 4 frames of 1024 samples, media_time 512 cuts into frame 0.
  // The frame is kept with its timestamp pulled back by 512 and the 512
  // leading samples become skip_samples (the encoder-delay trim).
  let stbl = build_stbl(
    stsd_box(audio_entry_isom(b"mp4a", 1, 16, 44100)),
    stts_box([(4, 1024)]),
    [],
    stsc_box([(1, 4, 1)]),
    stsz_box(100, 4),
    stco_box([500]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 4096, 0, 0),
    mdhd_box(44100, 4096),
    hdlr_box(b"soun"),
    stbl,
    edts_of([(100, 512)]), // duration 100 movie units → 4410 track units
  )
  let t = av_mov_open(
      Bytes::from_array(build_movie(mvhd_box(1000, 100), trak, false)),
    ).unwrap().tracks[0]
  assert_eq(t.skip_samples, 512)
  assert_eq(t.samples.length(), 4)
  for i = 0; i < 4; i = i + 1 {
    assert_eq(t.samples[i].discard, false)
  }
  assert_eq(t.samples[0].dts, -512)
  assert_eq(t.samples[1].dts, 512)
  assert_eq(t.samples[2].dts, 1536)
  assert_eq(t.samples[3].dts, 2560)
}

///|
test "elst: positive min_corrected_pts re-zeros the first video pts" {
  // ctts +50 lifts every PTS by 50; after the fix the video DTS is offset by
  // -min_corrected_pts so the first presentation timestamp becomes 0.
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 64, 64)),
    stts_box([(2, 10)]),
    ctts_box([(2, 50)]),
    stsc_box([(1, 2, 1)]),
    stsz_box(10, 2),
    stco_box([500]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 20, 64, 64),
    mdhd_box(1000, 20),
    hdlr_box(b"vide"),
    stbl,
    edts_of([(1000, 0)]),
  )
  let t = av_mov_open(
      Bytes::from_array(build_movie(mvhd_box(1000, 20), trak, false)),
    ).unwrap().tracks[0]
  assert_eq(t.min_corrected_pts, 50)
  assert_eq(t.samples[0].dts, -50)
  assert_eq(t.samples[1].dts, -40)
  assert_eq(t.samples[0].pts, 0)
  assert_eq(t.samples[1].pts, 10)
  // seek lands on the corrected timeline: PTS 10 → ts 10-50 = -40 → sample 1
  assert_eq(mov_seek_stream(t, 10, avseek_flag_backward).unwrap(), 1)
}

// ---------------------------------------------------------------------------
// mov_estimate_video_delay
// ---------------------------------------------------------------------------

///|
test "elst: h264 reorder estimate from ctts" {
  // dts 0/10/20 with ctts +20/0/+10 → PTS 20/10/30: the second frame needs
  // one swap to sort, the third none → video_delay 1.
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 64, 64)),
    stts_box([(3, 10)]),
    ctts_box([(1, 20), (1, 0), (1, 10)]),
    stsc_box([(1, 3, 1)]),
    stsz_box(10, 3),
    stco_box([500]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 30, 64, 64),
    mdhd_box(1000, 30),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let t = av_mov_open(
      Bytes::from_array(build_movie(mvhd_box(1000, 30), trak, false)),
    ).unwrap().tracks[0]
  assert_eq(t.video_delay, 1)
  // HEVC (or anything non-avc1) is not estimated.
  let stbl2 = build_stbl(
    stsd_box(video_entry_isom(b"hvc1", 64, 64)),
    stts_box([(3, 10)]),
    ctts_box([(1, 20), (1, 0), (1, 10)]),
    stsc_box([(1, 3, 1)]),
    stsz_box(10, 3),
    stco_box([500]),
    [],
  )
  let trak2 = build_trak(
    tkhd_box(1, 30, 64, 64),
    mdhd_box(1000, 30),
    hdlr_box(b"vide"),
    stbl2,
    [],
  )
  let t2 = av_mov_open(
      Bytes::from_array(build_movie(mvhd_box(1000, 30), trak2, false)),
    ).unwrap().tracks[0]
  assert_eq(t2.video_delay, 0)
}

// ---------------------------------------------------------------------------
// fragmented auto-disable (order-sensitive, as in mov_read_trak)
// ---------------------------------------------------------------------------

///|
test "elst: a fragmented track disables advanced edit lists from its build on" {
  // moov = [mvhd, trak(elst, normal tables), trak(empty stbl), mvex], then
  // one moof for the second track. The first trak builds while the flag is
  // still set (its edit list applies); the fragmented trak clears the flag
  // before its own build, and the movie ends with advanced_editlist off.
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 64, 64)),
    stts_box([(2, 10)]),
    [],
    stsc_box([(1, 2, 1)]),
    stsz_box(10, 2),
    stco_box([900]),
    stss_box([1]),
  )
  let trak1 = build_trak(
    tkhd_box(1, 20, 64, 64),
    mdhd_box(1000, 20),
    hdlr_box(b"vide"),
    stbl,
    edts_of([(1000, 10)]),
  )
  let frag_stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 64, 64)),
    [],
    [],
    stsc_box([]),
    stsz_box(0, 0),
    stco_box([]),
    [],
  )
  let trak2 = build_trak(
    tkhd_box(2, 0, 64, 64),
    mdhd_box(1000, 0),
    hdlr_box(b"vide"),
    frag_stbl,
    [],
  )
  let moov = cat([fbox(b"mvhd", 0, 0, zbytes(100)), trak1, trak2, mvex_box(2)])
  let data = cat([
    ftyp_box(b"isom"),
    box(b"moov", moov),
    frag_moof(2, Some(0), 600, [(10, 5, 0x2000000)]),
  ])
  let movie = av_mov_open(Bytes::from_array(data)).unwrap()
  assert_eq(movie.advanced_editlist, false)
  // trak1 was fixed while the flag was on: the walk backs off to key frame 0,
  // frame 0 (before media_time 10) is discard-flagged at rewritten dts -10,
  // and the kept timeline starts at 0.
  let t1 = movie.tracks[0]
  assert_eq(t1.samples.length(), 2)
  assert_eq(t1.samples[0].dts, -10)
  assert_eq(t1.samples[1].dts, 0)
  // trak2 receives its fragment samples untouched.
  let t2 = movie.tracks[1]
  assert_eq(t2.samples.length(), 1)
  assert_eq(t2.samples[0].dts, 0)
}
