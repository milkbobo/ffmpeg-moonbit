///|
/// Whitebox tests for the sample-group (sgpd/sbgp) + open-GOP seek +
/// multi-sample-description (pseudo_stream_id) slice, ported from
/// FFmpeg 9.0.2 `libavformat/mov.c` (`mov_read_sgpd`, `mov_read_sbgp`,
/// `build_open_gop_key_points`, `can_seek_to_key_sample`,
/// `ff_mov_read_stsd_entries`, the `pseudo_stream_id` index filter and the
/// tfdt/trun `stsd_id` gates).
///
/// Expected values are hand-derived from the box layouts and the mov.c
/// semantics; the open-GOP seek test is differential (the same file with a
/// non-HEVC fourcc must seek to the CRA sample the HEVC path rejects).

// ---------------------------------------------------------------------------
// Local box builders (sgpd/sbgp/multi-entry stsd/stbl-with-groups)
// ---------------------------------------------------------------------------

///| `sgpd` v1, grouping 'sync', default_length 1: one NAL-type byte/entry. */
fn sgpd_sync_box(nal_types : Array[UInt]) -> Array[Byte] {
  let body : Array[Byte] = []
  push_all(body, b"sync".to_array()) // grouping_type, file order
  push_all(body, be32(1)) // default_length (version >= 1)
  push_all(body, be32(nal_types.length().reinterpret_as_uint()))
  for i = 0; i < nal_types.length(); i = i + 1 {
    body.push(nal_types[i].to_byte())
  }
  fbox(b"sgpd", 1, 0, body)
}

///| `sbgp` v0 for one grouping type: runs of (sample_count, group index). */
fn sbgp_runs_box(grouping : Bytes, runs : Array[(UInt, UInt)]) -> Array[Byte] {
  let body : Array[Byte] = []
  push_all(body, grouping.to_array())
  push_all(body, be32(runs.length().reinterpret_as_uint()))
  for i = 0; i < runs.length(); i = i + 1 {
    push_all(body, be32(runs[i].0))
    push_all(body, be32(runs[i].1))
  }
  fbox(b"sbgp", 0, 0, body)
}

///| `stbl` with the standard tables plus trailing sgpd/sbgp boxes. */
fn stbl_with_groups(
  stsd : Array[Byte],
  stts : Array[Byte],
  ctts : Array[Byte],
  stsc : Array[Byte],
  stsz : Array[Byte],
  stco : Array[Byte],
  stss : Array[Byte],
  groups : Array[Byte]
) -> Array[Byte] {
  let parts : Array[Array[Byte]] = [stsd, stts]
  if ctts.length() > 0 {
    parts.push(ctts)
  }
  parts.push(stsc)
  parts.push(stsz)
  parts.push(stco)
  if stss.length() > 0 {
    parts.push(stss)
  }
  if groups.length() > 0 {
    parts.push(groups)
  }
  box(b"stbl", cat(parts))
}

///| Append a child box to a sample entry, fixing the entry's size field. */
fn entry_with_child(entry : Array[Byte], child : Array[Byte]) -> Array[Byte] {
  let out = cat([entry, child])
  let sz = be32(out.length().reinterpret_as_uint())
  out[0] = sz[0]
  out[1] = sz[1]
  out[2] = sz[2]
  out[3] = sz[3]
  out
}

///| A `glbl` sample-entry child whose payload becomes the extradata. */
fn glbl_box(payload : Bytes) -> Array[Byte] {
  box(b"glbl", payload.to_array())
}

///| `stsd` with an arbitrary number of entries. */
fn stsd_box_n(entries : Array[Array[Byte]]) -> Array[Byte] {
  let body : Array[Byte] = be32(entries.length().reinterpret_as_uint())
  for i = 0; i < entries.length(); i = i + 1 {
    push_all(body, entries[i])
  }
  fbox(b"stsd", 0, 0, body)
}

///| `mvex` whose `trex` carries an explicit `stsd_id`. */
fn mvex_box_sid(track_id : UInt, stsd_id : UInt) -> Array[Byte] {
  let trex = fbox(
    b"trex",
    0,
    0,
    cat([be32(track_id), be32(stsd_id), be32(0), be32(0), be32(0)]),
  )
  box(b"mvex", trex)
}

///| `tfhd` with `default-base-is-moof` and an explicit `stsd_id`. */
fn tfhd_box_dbm_sid(track_id : UInt, stsd_id : UInt) -> Array[Byte] {
  fbox(b"tfhd", 0, 0x020002, cat([be32(track_id), be32(stsd_id)]))
}

// ---------------------------------------------------------------------------
// sgpd / sbgp tables
// ---------------------------------------------------------------------------

test "groups: sgpd sync entries and sbgp runs land in the track tables" {
  let stbl = stbl_with_groups(
    stsd_box(video_entry_isom(b"avc1", 16, 16)),
    stts_box([(2, 50)]),
    [],
    stsc_box([(1, 2, 1)]),
    stsz_box(10, 2),
    stco_box([500]),
    [],
    cat([
      sgpd_sync_box([19, 21]),
      sbgp_runs_box(b"sync", [(1, 2), (1, 1), (0, 0)]),
      sbgp_runs_box(b"rap ", [(2, 1)]),
    ]),
  )
  let trak = build_trak(
    tkhd_box(1, 100, 16, 16),
    mdhd_box(1000, 100),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let movie = av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 100), trak, false))).unwrap()
  let t = movie.tracks[0]
  // sgpd 'sync': NAL unit types masked to 6 bits.
  assert_eq(t.sgpd_sync.length(), 2)
  assert_eq(t.sgpd_sync[0], 19)
  assert_eq(t.sgpd_sync[1], 21)
  // sbgp 'sync' runs (including the trailing zero-count run, as C keeps it).
  assert_eq(t.sync_group.length(), 3)
  assert_eq(t.sync_group[0].count, 1)
  assert_eq(t.sync_group[0].index, 2)
  assert_eq(t.sync_group[1].index, 1)
  assert_eq(t.sync_group[2].count, 0)
  // sbgp 'rap ' runs.
  assert_eq(t.rap_group.length(), 1)
  assert_eq(t.rap_group[0].count, 2)
  assert_eq(t.rap_group[0].index, 1)
  // Non-HEVC: the open-GOP pass early-returns, no offsets, no min duration.
  assert_eq(t.sample_offsets.length(), 0)
  assert_eq(t.open_key_samples.length(), 0)
  assert_eq(t.min_sample_duration, 0)
}

test "groups: HEVC without a CRA entry unrolls offsets but no key samples" {
  // sgpd has only IDR_W_RADL (19), no CRA (21): the C unrolls sample_offsets
  // and returns before building open_key_samples / min_sample_duration.
  let stbl = stbl_with_groups(
    stsd_box(video_entry_isom(b"hvc1", 16, 16)),
    stts_box([(2, 50)]),
    ctts_box([(1, -5), (1, 7)]),
    stsc_box([(1, 2, 1)]),
    stsz_box(10, 2),
    stco_box([500]),
    [],
    cat([sgpd_sync_box([19]), sbgp_runs_box(b"sync", [(1, 1), (1, 0)])]),
  )
  let trak = build_trak(
    tkhd_box(1, 100, 16, 16),
    mdhd_box(1000, 100),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let movie = av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 100), trak, false))).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.sample_offsets, [-5, 7])
  assert_eq(t.open_key_samples.length(), 0)
  assert_eq(t.min_sample_duration, 0)
}

// ---------------------------------------------------------------------------
// Open-GOP seek (build_open_gop_key_points + can_seek_to_key_sample)
// ---------------------------------------------------------------------------

///| The open-GOP test file: HEVC, ctts (-10,-10,+10), CRA at sample 2. */
fn open_gop_movie(codec : Bytes) -> Mp4Movie {
  let groups = if codec == b"hvc1" {
    cat([sgpd_sync_box([21]), sbgp_runs_box(b"sync", [(2, 0), (1, 1)])])
  } else {
    zbytes(0)
  }
  let stbl = stbl_with_groups(
    stsd_box(video_entry_isom(codec, 64, 64)),
    stts_box([(3, 10)]),
    ctts_box([(2, -10), (1, 10)]),
    stsc_box([(1, 1, 1)]),
    stsz_box(10, 3),
    stco_box([100, 200, 300]),
    stss_box([1, 3]),
    groups,
  )
  let trak = build_trak(
    tkhd_box(1, 30, 64, 64),
    mdhd_box(1000, 30),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 30), trak, false))).unwrap()
}

test "seek: open-GOP CRA sample is rejected until its presentation point" {
  let t = open_gop_movie(b"hvc1").tracks[0]
  // dts 0/10/20; the negative ctts offset sits in entries the C's
  // mov_update_dts_shift skips (it runs for all but the last two entries),
  // so dts_shift stays 0 and pts = dts + offset → -10/0/30.
  assert_eq(t.dts_shift, 0)
  assert_eq(t.samples[0].pts, -10)
  assert_eq(t.samples[1].pts, 0)
  assert_eq(t.samples[2].pts, 30)
  // Open-GOP bookkeeping: offsets unrolled, CRA sample 2, min stts duration.
  assert_eq(t.sample_offsets, [-10, -10, 10])
  assert_eq(t.open_key_samples, [2])
  assert_eq(t.min_sample_duration, 10)
  // Seek (PTS) 30 → ts 30: sample 2's pts is 30, not > 30 → allowed.
  assert_eq(mov_seek_stream(t, 30, avseek_flag_backward).unwrap(), 2)
  // Seek PTS 25 → ts 25: sample 2 is open with pts 30 > 25 → rejected; the
  // back-off walks down (25→15, FFMAX(min_sample_duration,1)=10 steps) and
  // settles on the closed key sample 0.
  assert_eq(mov_seek_stream(t, 25, avseek_flag_backward).unwrap(), 0)
  // The same file as non-HEVC has no open-GOP gate: the CRA sample is fine.
  let plain = open_gop_movie(b"avc1").tracks[0]
  assert_eq(mov_seek_stream(plain, 25, avseek_flag_backward).unwrap(), 2)
  assert_eq(plain.min_sample_duration, 0)
}

// ---------------------------------------------------------------------------
// Multi sample description (pseudo_stream_id)
// ---------------------------------------------------------------------------

test "stsd: same-fourcc second entry indexes every chunk (pseudo -1)" {
  // Entry 0 carries a glbl child; entry 1 repeats the fourcc so it is parsed
  // too and flips pseudo_stream_id to -1 (codec_tag already set).
  let e0 = entry_with_child(video_entry_isom(b"hvc1", 16, 16), glbl_box(b"\xC0\x01"))
  let e1 = entry_with_child(video_entry_isom(b"hvc1", 32, 32), glbl_box(b"\xC0\x02"))
  let stbl = build_stbl(
    stsd_box_n([e0, e1]),
    stts_box([(1, 10), (1, 10)]),
    [],
    stsc_box([(1, 1, 1), (2, 1, 2)]),
    stsz_box(10, 2),
    stco_box([1000, 2000]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 20, 16, 16),
    mdhd_box(1000, 20),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let movie = av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 20), trak, false))).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.stsd_count, 2)
  assert_eq(t.pseudo_stream_id, -1)
  // Last parsed entry wins the codec fields (both entries overwrite in place).
  assert_eq(t.codec, "hvc1")
  assert_eq(t.width, 32)
  // Every chunk is indexed, from both sample descriptions.
  assert_eq(t.samples.length(), 2)
  assert_eq(t.samples[0].offset, 1000)
  assert_eq(t.samples[1].offset, 2000)
  // Primary extradata stays entry 0's. Only slot 0 is ever written: later
  // parsed entries carry pseudo_stream_id -1, so their extradata cannot be
  // slotted (the C indexes sc->extradata[-1], dead in practice — kept as a
  // documented no-op here).
  assert_eq(t.extradata, Some(b"\xC0\x01"))
  assert_eq(t.stsd_extradata.length(), 1)
  assert_eq(t.stsd_extradata[0], Some(b"\xC0\x01"))
  assert_eq(t.last_stsd_index, 0)
}

test "stsd: differing-fourcc second entry is skipped, id-2 chunks drop out" {
  let e0 = entry_with_child(video_entry_isom(b"hvc1", 16, 16), glbl_box(b"\xC0\x01"))
  let e1 = entry_with_child(video_entry_isom(b"avc1", 32, 32), glbl_box(b"\xC0\x02"))
  let stbl = build_stbl(
    stsd_box_n([e0, e1]),
    stts_box([(1, 10), (1, 10)]),
    [],
    stsc_box([(1, 1, 1), (2, 1, 2)]),
    stsz_box(10, 2),
    stco_box([1000, 2000]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 20, 16, 16),
    mdhd_box(1000, 20),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let movie = av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 20), trak, false))).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.stsd_count, 2)
  assert_eq(t.pseudo_stream_id, 0)
  assert_eq(t.codec, "hvc1")
  // pseudo_stream_id 0 filters the index to stsc id 1 chunks only.
  assert_eq(t.samples.length(), 1)
  assert_eq(t.samples[0].offset, 1000)
  assert_eq(t.extradata, Some(b"\xC0\x01"))
}

test "stsd: first chunk referencing entry 2 switches the primary extradata" {
  // Same-fourcc entries + a first chunk with stsc id 2: mov_read_header's
  // last_stsd pass selects slot 1 — which no entry ever filled (see the
  // slot discussion above), so the primary extradata becomes empty.
  let e0 = entry_with_child(video_entry_isom(b"hvc1", 16, 16), glbl_box(b"\xC0\x01"))
  let e1 = entry_with_child(video_entry_isom(b"hvc1", 32, 32), glbl_box(b"\xC0\x02"))
  let stbl = build_stbl(
    stsd_box_n([e0, e1]),
    stts_box([(1, 10)]),
    [],
    stsc_box([(1, 1, 2)]),
    stsz_box(10, 1),
    stco_box([1000]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 10, 16, 16),
    mdhd_box(1000, 10),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let movie = av_mov_open(Bytes::from_array(build_movie(mvhd_box(1000, 10), trak, false))).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.last_stsd_index, 1)
  assert_eq(t.extradata, None)
  // pseudo -1 keeps the chunk in the index regardless of its stsd id.
  assert_eq(t.samples.length(), 1)
}

// ---------------------------------------------------------------------------
// Fragment stsd_id gates (tfdt + trun)
// ---------------------------------------------------------------------------

///| An init segment + one moof, with a configurable trex stsd_id. */
fn frag_movie_sid(stsd_id : UInt) -> Mp4Movie {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"hvc1", 16, 16)),
    [],
    [],
    stsc_box([]),
    stsz_box(0, 0),
    stco_box([]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 0, 16, 16),
    mdhd_box(1000, 0),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let moov = cat([
    fbox(b"mvhd", 0, 0, zbytes(100)),
    box(b"trak", trak),
    mvex_box_sid(1, stsd_id),
  ])
  let data = cat([
    ftyp_box(b"isom"),
    box(b"moov", moov),
    frag_moof(1, Some(0), 600, [(10, 5, 0x2000000), (10, 5, 0x1000001)]),
  ])
  av_mov_open(Bytes::from_array(data)).unwrap()
}

test "frag: fragments of a different stsd_id are skipped (trex path)" {
  // trex stsd_id 1 matches pseudo_stream_id 0 + 1: the fragment lands.
  let ok = frag_movie_sid(1).tracks[0]
  assert_eq(ok.samples.length(), 2)
  assert_eq(ok.samples[0].dts, 0)
  // trex stsd_id 2: both the tfdt and the trun gates reject the fragment.
  let skip = frag_movie_sid(2).tracks[0]
  assert_eq(skip.samples.length(), 0)
}

test "frag: an explicit tfhd stsd_id overrides the trex default" {
  // Same file shape but the stsd_id comes from the tfhd flag (0x000002):
  // 2 mismatches the track, 1 matches.
  fn frag_movie_tfhd(stsd_id : UInt) -> Mp4Movie {
    let stbl = build_stbl(
      stsd_box(video_entry_isom(b"hvc1", 16, 16)),
      [],
      [],
      stsc_box([]),
      stsz_box(0, 0),
      stco_box([]),
      [],
    )
    let trak = build_trak(
      tkhd_box(1, 0, 16, 16),
      mdhd_box(1000, 0),
      hdlr_box(b"vide"),
      stbl,
      [],
    )
    let trun_flags : UInt = 0x1 | 0x100 | 0x200 | 0x400
    let trun_body : Array[Byte] = []
    push_all(trun_body, be32(1))
    push_all(trun_body, be32(600))
    push_all(trun_body, be32(10))
    push_all(trun_body, be32(5))
    push_all(trun_body, be32(0x2000000))
    let traf = box(
      b"traf",
      cat([
        tfhd_box_dbm_sid(1, stsd_id),
        tfdt_box_v0(0),
        fbox(b"trun", 0, trun_flags, trun_body),
      ]),
    )
    let moov = cat([
      fbox(b"mvhd", 0, 0, zbytes(100)),
      box(b"trak", trak),
      mvex_box(1),
    ])
    av_mov_open(
      Bytes::from_array(cat([ftyp_box(b"isom"), box(b"moov", moov), box(b"moof", traf)])),
    ).unwrap()
  }
  assert_eq(frag_movie_tfhd(1).tracks[0].samples.length(), 1)
  assert_eq(frag_movie_tfhd(2).tracks[0].samples.length(), 0)
}
