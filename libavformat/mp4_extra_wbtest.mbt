///|
/// Whitebox tests for the second MP4/MOV slice: extradata (`glbl`/`avcC`,
/// `esds`), the fragment index boxes (`sidx`, `mfra`/`tfra`), per-fragment
/// encryption (`senc` inside `moof`, `saiz`/`saio`), the chunked uncompressed
/// audio index, fragment-overlap discard flags and `mov_seek_stream`.
///
/// All inputs are synthesised byte by byte; expected values are hand-derived
/// from the box layouts and the `mov.c` semantics they exercise. Real-file
/// cross-validation against ffprobe lives in `mp4_real_wbtest.mbt`.

// ---------------------------------------------------------------------------
// Byte/box helpers (independently named to stay collision-free with
// mp4_wbtest.mbt should the two test files share a package scope)
// ---------------------------------------------------------------------------

fn xb16(v : UInt) -> Array[Byte] {
  [((v >> 8) & 0xFF).to_byte(), (v & 0xFF).to_byte()]
}

fn xb24(v : UInt) -> Array[Byte] {
  [
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    (v & 0xFF).to_byte(),
  ]
}

fn xb32(v : UInt) -> Array[Byte] {
  [
    ((v >> 24) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    (v & 0xFF).to_byte(),
  ]
}

fn xb64(v : UInt64) -> Array[Byte] {
  let a : Array[Byte] = []
  let mut i = 7
  while i >= 0 {
    a.push(((v >> (i * 8)) & 0xFF).to_byte())
    i = i - 1
  }
  a
}

fn xbytes(list : Array[Int]) -> Array[Byte] {
  let a : Array[Byte] = []
  for i = 0; i < list.length(); i = i + 1 {
    a.push(list[i].to_byte())
  }
  a
}

fn xfourcc(kind : String) -> Array[Byte] {
  xbytes([kind[0].to_int(), kind[1].to_int(), kind[2].to_int(), kind[3].to_int()])
}

fn xpush(dst : Array[Byte], src : Array[Byte]) -> Unit {
  for i = 0; i < src.length(); i = i + 1 {
    dst.push(src[i])
  }
}

fn xbox(kind : String, payload : Array[Byte]) -> Array[Byte] {
  let out = xb32((payload.length() + 8).reinterpret_as_uint())
  xpush(out, xfourcc(kind))
  xpush(out, payload)
  out
}

fn xconcat(parts : Array[Array[Byte]]) -> Array[Byte] {
  let out : Array[Byte] = []
  for i = 0; i < parts.length(); i = i + 1 {
    xpush(out, parts[i])
  }
  out
}

fn xftyp(major : String) -> Array[Byte] {
  xbox("ftyp", xconcat([xfourcc(major), xb32(0), xfourcc("isom")]))
}

fn xmvhd(timescale : UInt, duration : UInt) -> Array[Byte] {
  xbox(
    "mvhd",
    xconcat([
      xbytes([0]),
      xb24(0),
      xb32(0),
      xb32(0),
      xb32(timescale),
      xb32(duration),
      xbytes([]),
    ]),
  )
}

fn xtkhd(track_id : UInt) -> Array[Byte] {
  xbox(
    "tkhd",
    xconcat([
      xbytes([0]),
      xb24(0),
      xb32(0),
      xb32(0),
      xb32(track_id),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0x01000000),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0),
      xb32(0x00400000),
      xb32(0x00280000),
    ]),
  )
}

fn xmdhd(timescale : UInt, duration : UInt) -> Array[Byte] {
  xbox(
    "mdhd",
    xconcat([
      xbytes([0]),
      xb24(0),
      xb32(0),
      xb32(0),
      xb32(timescale),
      xb32(duration),
      xb16(0),
      xb16(0),
    ]),
  )
}

fn xhdlr(kind : String) -> Array[Byte] {
  xbox("hdlr", xconcat([xbytes([0]), xb24(0), xb32(0), xfourcc(kind), xb32(0)]))
}

///| VisualSampleEntry: `extra` boxes are appended after the fixed fields. */
fn xvideo_entry(codec : String, extra : Array[Array[Byte]]) -> Array[Byte] {
  let e : Array[Byte] = []
  // SampleEntry base: 6 reserved bytes + data reference index.
  xpush(e, xbytes(Array::make(6, 0)))
  xpush(e, xb16(1))
  // VisualSampleEntry: 16 pre-defined bytes, then the fixed fields.
  xpush(e, xbytes(Array::make(16, 0)))
  xpush(e, xb16(64))
  xpush(e, xb16(36))
  xpush(e, xb32(0x00480000))
  xpush(e, xb32(0x00480000))
  xpush(e, xb32(0))
  xpush(e, xb16(1))
  xpush(e, xbytes([0])) // compressorname length 0
  xpush(e, xbytes(Array::make(31, 0)))
  xpush(e, xb16(24)) // depth
  xpush(e, xb16(0xFFFF)) // pre_defined = -1
  for i = 0; i < extra.length(); i = i + 1 {
    xpush(e, extra[i])
  }
  let out = xb32((e.length() + 8).reinterpret_as_uint())
  xpush(out, xfourcc(codec))
  xpush(out, e)
  out
}

///| AudioSampleEntry version 0 (ISO layout), `extra` boxes appended. */
fn xaudio_entry(
  codec : String,
  channels : UInt,
  bits : UInt,
  rate : UInt,
  extra : Array[Array[Byte]]
) -> Array[Byte] {
  xaudio_entry_common(codec, xconcat([
    xbytes(Array::make(6, 0)),
    xb16(1),
    xb16(0), // entry version
    xbytes(Array::make(6, 0)), // revision + vendor (or reserved)
    xb16(channels),
    xb16(bits),
    xb16(0),
    xb16(0),
    xb32(rate << 16),
  ]), extra)
}

///| QuickTime AudioSampleEntry version 1 with explicit packing fields. */
fn xaudio_entry_v1(
  codec : String,
  channels : UInt,
  bits : UInt,
  rate : UInt,
  samples_per_frame : UInt,
  bytes_per_frame : UInt
) -> Array[Byte] {
  xaudio_entry_common(codec, xconcat([
    xbytes(Array::make(6, 0)),
    xb16(1),
    xb16(1), // entry version
    xb16(0), // revision
    xb32(0), // vendor
    xb16(channels),
    xb16(bits),
    xb16(0),
    xb16(0),
    xb32(rate << 16),
    xb32(samples_per_frame),
    xb32(1), // bytes per packet
    xb32(bytes_per_frame),
    xb32(2), // bytes per sample
  ]), [])
}

fn xaudio_entry_common(
  codec : String,
  fixed : Array[Byte],
  extra : Array[Array[Byte]]
) -> Array[Byte] {
  let e : Array[Byte] = []
  xpush(e, fixed)
  for i = 0; i < extra.length(); i = i + 1 {
    xpush(e, extra[i])
  }
  let out = xb32((e.length() + 8).reinterpret_as_uint())
  xpush(out, xfourcc(codec))
  xpush(out, e)
  out
}

fn xstsd(entries : Array[Array[Byte]]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0))
  xpush(p, xb32(entries.length().reinterpret_as_uint()))
  for i = 0; i < entries.length(); i = i + 1 {
    xpush(p, entries[i])
  }
  xbox("stsd", p)
}

fn xstts(entries : Array[(UInt, UInt)]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0))
  xpush(p, xb32(entries.length().reinterpret_as_uint()))
  for i = 0; i < entries.length(); i = i + 1 {
    let (c, d) = entries[i]
    xpush(p, xb32(c))
    xpush(p, xb32(d))
  }
  xbox("stts", p)
}

fn xstsc(entries : Array[(UInt, UInt, UInt)]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0))
  xpush(p, xb32(entries.length().reinterpret_as_uint()))
  for i = 0; i < entries.length(); i = i + 1 {
    let (f, c, id) = entries[i]
    xpush(p, xb32(f))
    xpush(p, xb32(c))
    xpush(p, xb32(id))
  }
  xbox("stsc", p)
}

fn xstsz_const(size : UInt, count : UInt) -> Array[Byte] {
  xbox("stsz", xconcat([xbytes([0]), xb24(0), xb32(size), xb32(count)]))
}

fn xstco(offsets : Array[Int64]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0))
  xpush(p, xb32(offsets.length().reinterpret_as_uint()))
  for i = 0; i < offsets.length(); i = i + 1 {
    xpush(p, xb32(offsets[i].to_int().reinterpret_as_uint()))
  }
  xbox("stco", p)
}

fn xstss(samples : Array[UInt]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0))
  xpush(p, xb32(samples.length().reinterpret_as_uint()))
  for i = 0; i < samples.length(); i = i + 1 {
    xpush(p, xb32(samples[i]))
  }
  xbox("stss", p)
}

fn xstbl(children : Array[Array[Byte]]) -> Array[Byte] {
  xbox("stbl", xconcat(children))
}

fn xmdia(children : Array[Array[Byte]]) -> Array[Byte] {
  xbox("mdia", xconcat(children))
}

fn xtrak(children : Array[Array[Byte]]) -> Array[Byte] {
  xbox("trak", xconcat(children))
}

fn xmoov(children : Array[Array[Byte]]) -> Array[Byte] {
  xbox("moov", xconcat(children))
}

fn xmdat(data : Array[Byte]) -> Array[Byte] {
  xbox("mdat", data)
}

///| Build `ftyp` + `moov` (+ more parts) and return the bytes. */
fn xbuild(parts : Array[Array[Byte]]) -> Bytes {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  for i = 0; i < parts.length(); i = i + 1 {
    xpush(all, parts[i])
  }
  Bytes::from_array(all[:])
}

// ---------------------------------------------------------------------------
// glbl / avcC / esds
// ---------------------------------------------------------------------------

test "mov: avcC payload becomes extradata verbatim (mov_read_glbl)" {
  let avcc = xbox("avcC", xbytes([1, 0x64, 0, 28, 0xFF, 0xE1, 0, 3, 1, 2, 3]))
  let stbl = xstbl([
    xstsd([xvideo_entry("avc1", [avcc])]),
    xstts([(10, 100)]),
    xstsc([(1, 10, 1)]),
    xstsz_const(50, 10),
    xstco([1000]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(1000, 1000), xhdlr("vide"), stbl])])
  let bytes = xbuild([xmoov([xmvhd(1000, 1000), trak]), xmdat([])])
  let movie = av_mov_open(bytes).unwrap()
  let t = movie.tracks[0]
  // The payload without the 8-byte box header, byte for byte.
  let ed = t.extradata.unwrap()
  assert_eq(ed.length(), 11)
  assert_eq(ed[0], 1)
  assert_eq(ed[1], 0x64)
  assert_eq(ed[5], 0xE1)
  assert_eq(ed[10], 3)
}

///| Wrap an ES descriptor chain into an `esds` box. */
fn xesds(obj_type : Int, avg_rate : UInt, dsi : Array[Byte]?) -> Array[Byte] {
  let dcd : Array[Byte] = []
  xpush(dcd, xbytes([obj_type, 0x15]))
  xpush(dcd, xb24(0)) // buffer size
  xpush(dcd, xb32(0)) // max bitrate
  xpush(dcd, xb32(avg_rate))
  match dsi {
    Some(d) => {
      // MP4DecSpecificDescrTag (0x05), one length byte suffices here.
      xpush(dcd, xbytes([0x05, d.length()]))
      xpush(dcd, d)
    }
    None => ()
  }
  // ES descriptor (0x03): ES_ID, flags, then the DCD (0x04).
  let es_len = 2 + 1 + 2 + dcd.length()
  let p : Array[Byte] = []
  xpush(p, xb32(0)) // version + flags
  xpush(p, xbytes([0x03, es_len]))
  xpush(p, xb16(1))
  xpush(p, xbytes([0]))
  xpush(p, xbytes([0x04, dcd.length()]))
  xpush(p, dcd)
  xbox("esds", p)
}

test "mov: esds with AAC DecoderSpecificInfo fills codec config" {
  // AudioSpecificConfig 0x12 0x10: AAC-LC, index 4 (44100), stereo.
  let esds = xesds(0x40, 64000, Some(xbytes([0x12, 0x10])))
  let stbl = xstbl([
    xstsd([xaudio_entry("mp4a", 1, 16, 8000, [esds])]),
    xstts([(10, 1024)]),
    xstsc([(1, 10, 1)]),
    xstsz_const(100, 10),
    xstco([2000]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(44100, 10240), xhdlr("soun"), stbl])])
  let bytes = xbuild([xmoov([xmvhd(44100, 10240), trak]), xmdat([])])
  let movie = av_mov_open(bytes).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.codec_id, "aac")
  assert_eq(t.bit_rate, 64000)
  let ed = t.extradata.unwrap()
  assert_eq(ed.length(), 2)
  assert_eq(ed[0], 0x12)
  assert_eq(ed[1], 0x10)
  // The AudioSpecificConfig overrides the (deliberately wrong) entry fields.
  assert_eq(t.channels, 2)
  assert_eq(t.sample_rate, 44100)
  assert_eq(t.frame_length, 1024)
}

test "mov: esds for MPEG-1 audio (0x6b) sets codec but no extradata" {
  // As per 14496-3 9.D.2.2, no DecoderSpecificInfo is honoured for MPEG audio.
  let esds = xesds(0x6B, 128000, Some(xbytes([1, 2, 3])))
  let stbl = xstbl([
    xstsd([xaudio_entry("mp4a", 2, 16, 44100, [esds])]),
    xstts([(10, 1152)]),
    xstsc([(1, 10, 1)]),
    xstsz_const(200, 10),
    xstco([2000]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(44100, 11520), xhdlr("soun"), stbl])])
  let bytes = xbuild([xmoov([xmvhd(44100, 11520), trak]), xmdat([])])
  let movie = av_mov_open(bytes).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.codec_id, "mp3")
  assert_eq(t.extradata is Some(_), false)
  assert_eq(t.channels, 2)
}

// ---------------------------------------------------------------------------
// Fragmented MP4 helpers
// ---------------------------------------------------------------------------

fn xtrex(track_id : UInt) -> Array[Byte] {
  xbox(
    "trex",
    xconcat([
      xbytes([0]),
      xb24(0),
      xb32(track_id),
      xb32(1),
      xb32(0),
      xb32(0),
      xb32(0x02000000), // default sample flags: sync sample
    ]),
  )
}

///| An empty-video-track init segment for fragmented files. */
fn xfrag_init() -> Array[Byte] {
  let stbl = xstbl([
    xstsd([xvideo_entry("avc1", [])]),
    xstts([]),
    xstsc([]),
    xstsz_const(0, 0),
    xstco([]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(1000, 0), xhdlr("vide"), stbl])])
  xmoov([xmvhd(1000, 0), trak, xbox("mvex", xtrex(1))])
}

///| One trun row: (size, duration, flags); data-offset and per-sample
/// duration/size/flags are declared.
fn xtrun(samples : Array[(UInt, UInt, UInt)]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([0]))
  xpush(p, xb24(0x701)) // data-offset | duration | size | flags
  xpush(p, xb32(samples.length().reinterpret_as_uint()))
  xpush(p, xb32(0)) // data_offset patched by xmoof
  for i = 0; i < samples.length(); i = i + 1 {
    let (size, dur, flg) = samples[i]
    xpush(p, xb32(dur))
    xpush(p, xb32(size))
    xpush(p, xb32(flg))
  }
  xbox("trun", p)
}

fn xtfhd(track_id : UInt) -> Array[Byte] {
  // default-base-is-moof, no explicit fields.
  xbox("tfhd", xconcat([xbytes([0]), xb24(0x020000), xb32(track_id)]))
}

fn xtfdt(t : Int64) -> Array[Byte] {
  xbox("tfdt", xconcat([xbytes([1]), xb24(0), xb64(t.reinterpret_as_uint64())]))
}

///| One `moof`/`mdat` pair with a single `traf`. The trun data offset is
/// patched to `moof size + 8 + offset_in_mdat` after assembly so the
/// materialised sample offsets are real.
fn xmoof(
  tfdt : Int64?,
  offset_in_mdat : Int,
  traf_extra : Array[Array[Byte]],
  samples : Array[(UInt, UInt, UInt)],
  data : Array[Byte]
) -> (Array[Byte], Array[Byte]) {
  let base : Array[Array[Byte]] = match tfdt {
    Some(t) => [xtfhd(1), xtfdt(t)]
    None => [xtfhd(1)]
  }
  let trun = xtrun(samples)
  let children : Array[Array[Byte]] = []
  for i = 0; i < base.length(); i = i + 1 {
    children.push(base[i])
  }
  children.push(trun)
  for i = 0; i < traf_extra.length(); i = i + 1 {
    children.push(traf_extra[i])
  }
  let mfhd = xbox("mfhd", xbytes([0, 0, 0, 0]))
  let moof = xbox("moof", xconcat([mfhd, xbox("traf", xconcat(children))]))
  // Patch the trun data offset in place: moof header (8) + mfhd (12) + traf
  // header (8) + tfhd (16) + tfdt (20, when present) + trun header (8) +
  // version/flags (4) + sample count (4).
  let pos = 8 + 12 + 8 + 16 + (if tfdt is Some(_) { 20 } else { 0 }) + 8 + 4 + 4
  let target = moof.length() + 8 + offset_in_mdat
  moof[pos] = ((target >> 24) & 0xFF).to_byte()
  moof[pos + 1] = ((target >> 16) & 0xFF).to_byte()
  moof[pos + 2] = ((target >> 8) & 0xFF).to_byte()
  moof[pos + 3] = (target & 0xFF).to_byte()
  (moof, xmdat(data))
}

///| N filler bytes. */
fn xfill(n : Int) -> Array[Byte] {
  Array::make(n, b'\x00')
}

// ---------------------------------------------------------------------------
// sidx / mfra
// ---------------------------------------------------------------------------

///| `sidx` version 1 with one reference per (size, duration). */
fn xsidx(timescale : UInt, earliest : Int64, refs : Array[(UInt, UInt)]) -> Array[Byte] {
  let p : Array[Byte] = []
  xpush(p, xbytes([1]))
  xpush(p, xb24(0))
  xpush(p, xb32(1)) // reference ID (track)
  xpush(p, xb32(timescale))
  xpush(p, xb64(earliest.reinterpret_as_uint64()))
  xpush(p, xb64(0)) // first offset
  xpush(p, xb16(0))
  xpush(p, xb16(refs.length().reinterpret_as_uint()))
  for i = 0; i < refs.length(); i = i + 1 {
    let (size, dur) = refs[i]
    xpush(p, xb32(size & 0x7FFFFFFF))
    xpush(p, xb32(dur))
    xpush(p, xb32(0x80000000)) // SAP type 1
  }
  xbox("sidx", p)
}

///| mfra trailer with a v1 tfra of the given (time, offset) entries, plus
/// the trailing `mfro` box whose last word carries the mfra size (this is
/// what `mov_read_mfra` probes from the end of the file).
fn xmfra(entries : Array[(Int64, Int64)]) -> Array[Byte] {
  let tfra : Array[Byte] = []
  xpush(tfra, xbytes([1]))
  xpush(tfra, xb24(0))
  xpush(tfra, xb32(1)) // track id
  xpush(tfra, xb32(0)) // field length: all 1-byte
  xpush(tfra, xb32(entries.length().reinterpret_as_uint()))
  for i = 0; i < entries.length(); i = i + 1 {
    let (t, o) = entries[i]
    xpush(tfra, xb64(t.reinterpret_as_uint64()))
    xpush(tfra, xb64(o.reinterpret_as_uint64()))
    xpush(tfra, xbytes([0, 0, 0]))
  }
  let tfra_box = xbox("tfra", tfra)
  // mfra size = header(8) + tfra + mfro(8 + 4 + 4).
  let mfra_size = 8 + tfra_box.length() + 16
  let mfro = xbox(
    "mfro",
    xconcat([xb32(0), xb32(mfra_size.reinterpret_as_uint())]),
  )
  xbox("mfra", xconcat([tfra_box, mfro]))
}

test "mov: sidx references are recorded and set the track duration" {
  // Layout: ftyp + moov + sidx + moof+mdat + sidx + moof+mdat + mfra.
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  xpush(all, xfrag_init())
  let (moof1, mdat1) = xmoof(
    Some(0),
    0,
    [],
    [(100, 500, 0x02000000), (100, 500, 0x01010000)],
    xfill(200),
  )
  let (moof2, mdat2) = xmoof(
    Some(1000),
    0,
    [],
    [(100, 500, 0x02000000), (100, 500, 0x01010000)],
    xfill(200),
  )
  let ref1_size = moof1.length() + mdat1.length()
  let ref2_size = moof2.length() + mdat2.length()
  let sidx1 = xsidx(1000, 0, [(ref1_size.reinterpret_as_uint(), 1000)])
  let sidx2 = xsidx(1000, 1000, [(ref2_size.reinterpret_as_uint(), 1000)])
  let moof1_off = all.length() + sidx1.length()
  xpush(all, sidx1)
  xpush(all, moof1)
  xpush(all, mdat1)
  let moof2_off = all.length() + sidx2.length()
  xpush(all, sidx2)
  xpush(all, moof2)
  xpush(all, mdat2)
  xpush(all, xmfra([(0, moof1_off.to_int64()), (1000, moof2_off.to_int64())]))
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  // Two sidx references, one per moof, with rescaled (identity) times.
  assert_eq(movie.sidx_refs.length(), 2)
  assert_eq(movie.sidx_refs[0].offset, moof1_off.to_int64())
  assert_eq(movie.sidx_refs[0].pts, 0)
  assert_eq(movie.sidx_refs[0].size, ref1_size.reinterpret_as_uint())
  assert_eq(movie.sidx_refs[1].offset, moof2_off.to_int64())
  assert_eq(movie.sidx_refs[1].pts, 1000)
  // The accumulated presentation time becomes the track duration.
  let t = movie.tracks[0]
  assert_eq(t.has_sidx, true)
  assert_eq(t.duration, 2000)
  // The mfra trailer yields the tfra random-access points.
  assert_eq(movie.mfra.length(), 1)
  assert_eq(movie.mfra[0].track_id, 1)
  assert_eq(movie.mfra[0].entries.length(), 2)
  assert_eq(movie.mfra[0].entries[0].offset, moof1_off.to_int64())
  assert_eq(movie.mfra[0].entries[0].time, 0)
  assert_eq(movie.mfra[0].entries[1].offset, moof2_off.to_int64())
  assert_eq(movie.mfra[0].entries[1].time, 1000)
  // The moofs themselves carry tfdt, so DTS comes from those.
  assert_eq(t.samples.length(), 4)
  assert_eq(t.samples[0].dts, 0)
  assert_eq(t.samples[2].dts, 1000)
}

test "mov: trun without tfdt falls back to the sidx time" {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  xpush(all, xfrag_init())
  let (moof, mdat) = xmoof(
    None,
    0,
    [],
    [(10, 100, 0x02000000), (10, 100, 0x01010000)],
    xfill(20),
  )
  let sidx = xsidx(1000, 7000, [((moof.length() + mdat.length()).reinterpret_as_uint(), 200U)])
  xpush(all, sidx)
  xpush(all, moof)
  xpush(all, mdat)
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  // sidx earliest presentation time 7000 (timescale 1000 = track timescale)
  // is used raw as the first DTS, exactly as the C fallback does.
  assert_eq(t.samples.length(), 2)
  assert_eq(t.samples[0].dts, 7000)
  assert_eq(t.samples[1].dts, 7100)
}

test "mov: overlapping fragments flag their samples as discard" {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  xpush(all, xfrag_init())
  let (moof1, mdat1) = xmoof(
    Some(0),
    0,
    [],
    [
      (10, 100, 0x02000000),
      (10, 100, 0x01010000),
      (10, 100, 0x01010000),
      (10, 100, 0x01010000),
    ],
    xfill(40),
  )
  // Second fragment restarts at tfdt 100, overlapping the first (end 400).
  let (moof2, mdat2) = xmoof(
    Some(100),
    0,
    [],
    [
      (10, 100, 0x02000000),
      (10, 100, 0x01010000),
      (10, 100, 0x01010000),
      (10, 100, 0x01010000),
    ],
    xfill(40),
  )
  xpush(all, moof1)
  xpush(all, mdat1)
  xpush(all, moof2)
  xpush(all, mdat2)
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.samples.length(), 8)
  // Fragment 1: dts 0..300, nothing discarded.
  for i = 0; i < 4; i = i + 1 {
    assert_eq(t.samples[i].dts, (i * 100).to_int64())
    assert_eq(t.samples[i].discard, false)
  }
  // Fragment 2 restarts at dts 100: every sample at or before the previous
  // fragment's last DTS (300) is flagged.
  assert_eq(t.samples[4].dts, 100)
  assert_eq(t.samples[4].discard, true)
  assert_eq(t.samples[5].dts, 200)
  assert_eq(t.samples[5].discard, true)
  assert_eq(t.samples[6].dts, 300)
  assert_eq(t.samples[6].discard, true)
  assert_eq(t.samples[7].dts, 400)
  assert_eq(t.samples[7].discard, false)
}

// ---------------------------------------------------------------------------
// seek
// ---------------------------------------------------------------------------

///| The classic 10-sample video table: dts 0..900 step 100, keyframes 1 and 7
/// (1-based stss), two chunks of 5 samples.
fn xseek_movie() -> Mp4Movie {
  let stbl = xstbl([
    xstsd([xvideo_entry("avc1", [])]),
    xstts([(10, 100)]),
    xstsc([(1, 5, 1), (2, 5, 1)]),
    xstsz_const(50, 10),
    xstco([1000, 2000]),
    xstss([1, 7]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(1000, 1000), xhdlr("vide"), stbl])])
  let bytes = xbuild([xmoov([xmvhd(1000, 1000), trak]), xmdat([])])
  av_mov_open(bytes).unwrap()
}

test "seek: backward seek snaps to keyframes" {
  let movie = xseek_movie()
  let t = movie.tracks[0]
  assert_eq(t.samples.length(), 10)
  // Before the second keyframe: backward seek lands on sample 0.
  let s = mov_seek_track(t, 500, avseek_flag_backward).unwrap()
  assert_eq(s.0, 0)
  assert_eq(s.1, 0)
  // At the second keyframe.
  let s2 = mov_seek_track(t, 600, avseek_flag_backward).unwrap()
  assert_eq(s2.0, 6)
  assert_eq(s2.1, 600)
  // Past the end: the last keyframe <= target.
  let s3 = mov_seek_track(t, 5000, avseek_flag_backward).unwrap()
  assert_eq(s3.0, 6)
  // Exact hit on a non-keyframe still snaps back with BACKWARD.
  let s4 = mov_seek_track(t, 350, avseek_flag_backward).unwrap()
  assert_eq(s4.0, 0)
  // ANY accepts the sample itself.
  let s5 = mov_seek_track(t, 350, avseek_flag_backward | avseek_flag_any).unwrap()
  assert_eq(s5.0, 3)
}

test "seek: forward (non-backward) seek finds the next entry" {
  let movie = xseek_movie()
  let t = movie.tracks[0]
  let s = mov_seek_track(t, 350, 0).unwrap()
  // Non-backward, non-any: the first keyframe at or after the target.
  assert_eq(s.0, 6)
  let s2 = mov_seek_track(t, 350, avseek_flag_any).unwrap()
  assert_eq(s2.0, 4)
  // A target before everything clamps to the first keyframe sample.
  let s3 = mov_seek_track(t, -50, avseek_flag_backward).unwrap()
  assert_eq(s3.0, 0)
}

test "seek: fragmented track seeks over materialised samples" {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  xpush(all, xfrag_init())
  let (moof1, mdat1) = xmoof(
    Some(0),
    0,
    [],
    [(10, 100, 0x02000000), (10, 100, 0x01010000), (10, 100, 0x01010000)],
    xfill(30),
  )
  let (moof2, mdat2) = xmoof(
    Some(300),
    0,
    [],
    [(10, 100, 0x02000000), (10, 100, 0x01010000)],
    xfill(20),
  )
  xpush(all, moof1)
  xpush(all, mdat1)
  xpush(all, moof2)
  xpush(all, mdat2)
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.samples.length(), 5)
  // Backward seek into the second fragment finds its keyframe (sample 3).
  let s = mov_seek_track(t, 400, avseek_flag_backward).unwrap()
  assert_eq(s.0, 3)
  assert_eq(s.1, 300)
  // Earlier target snaps to the first keyframe.
  let s2 = mov_seek_track(t, 200, avseek_flag_backward).unwrap()
  assert_eq(s2.0, 0)
}

// ---------------------------------------------------------------------------
// Uncompressed audio chunk demuxing
// ---------------------------------------------------------------------------

test "mov: old uncompressed audio chunk demuxing (sowt)" {
  // QuickTime file: 2500 samples of 16-bit mono PCM in two chunks
  // (1500 + 1000), stts a single entry of duration 1.
  let all : Array[Byte] = []
  xpush(all, xftyp("qt  "))
  let stbl = xstbl([
    xstsd([xaudio_entry("sowt", 1, 16, 8000, [])]),
    xstts([(2500, 1)]),
    xstsc([(1, 1500, 1), (2, 1000, 1)]),
    xstsz_const(2, 2500),
    xstco([500, 3500]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(8000, 2500), xhdlr("soun"), stbl])])
  xpush(all, xmoov([xmvhd(8000, 2500), trak]))
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.unsupported_audio_chunk_demux, true)
  // sowt: 2 bytes per sample and channel -> sc->sample_size == 2.
  assert_eq(t.sample_size, 2)
  assert_eq(t.bits_per_sample, 16)
  // Chunk 0 (1500 samples) -> 1024 + 476; chunk 1 (1000) -> one packet.
  assert_eq(t.samples.length(), 3)
  assert_eq(t.samples[0].offset, 500)
  assert_eq(t.samples[0].size, 2048)
  assert_eq(t.samples[0].dts, 0)
  assert_eq(t.samples[0].duration, 1024)
  assert_eq(t.samples[1].offset, 500 + 2048)
  assert_eq(t.samples[1].size, 952)
  assert_eq(t.samples[1].dts, 1024)
  assert_eq(t.samples[1].duration, 476)
  assert_eq(t.samples[2].offset, 3500)
  assert_eq(t.samples[2].size, 2000)
  assert_eq(t.samples[2].dts, 1500)
  assert_eq(t.samples[2].duration, 1000)
  // Every chunked-audio packet is a keyframe with min_distance 0.
  for i = 0; i < 3; i = i + 1 {
    assert_eq(t.samples[i].keyframe, true)
    assert_eq(t.samples[i].min_distance, 0)
    assert_eq(t.samples[i].discard, false)
  }
}

test "mov: audio entry version 1 packing (samples_per_frame from stsd)" {
  // A QT version-1 entry's samples_per_frame/bytes_per_frame are picked up;
  // with spf == 1 packets are still 1024 samples of sc->sample_size bytes.
  let all : Array[Byte] = []
  xpush(all, xftyp("qt  "))
  let stbl = xstbl([
    xstsd([xaudio_entry_v1("sowt", 2, 16, 44100, 1, 4)]),
    xstts([(2048, 1)]),
    xstsc([(1, 2048, 1)]),
    xstsz_const(4, 2048),
    xstco([400]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(44100, 2048), xhdlr("soun"), stbl])])
  xpush(all, xmoov([xmvhd(44100, 2048), trak]))
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.samples_per_frame, 1)
  assert_eq(t.bytes_per_frame, 4)
  assert_eq(t.sample_size, 4) // 16 bits * 2 channels
  assert_eq(t.samples.length(), 2)
  assert_eq(t.samples[0].size, 4096)
  assert_eq(t.samples[0].duration, 1024)
  assert_eq(t.samples[1].size, 4096)
  assert_eq(t.samples[1].duration, 1024)
}

// ---------------------------------------------------------------------------
// cenc: senc inside moof, saiz/saio auxiliary info
// ---------------------------------------------------------------------------

///| sinf/schm(cenc)/schi/tenc boxes for an encrypted video sample entry. */
fn xenc_sinf(per_sample_iv : Int) -> Array[Array[Byte]] {
  let tenc : Array[Byte] = []
  xpush(tenc, xbytes([0]))
  xpush(tenc, xb24(0))
  xpush(tenc, xbytes([0]))
  xpush(tenc, xbytes([0]))
  xpush(tenc, xbytes([1])) // is_protected
  xpush(tenc, xbytes([per_sample_iv]))
  xpush(tenc, xbytes([
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x01,
  ])) // default key ID
  let schi = xbox("schi", xbox("tenc", tenc))
  let schm = xbox("schm", xconcat([xb32(0), xb32(0x63656E63)]))
  [xbox("sinf", xconcat([schm, schi]))]
}

test "mov: senc inside moof appends per-fragment sample IVs" {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  let stbl = xstbl([
    xstsd([xvideo_entry("avc1", xenc_sinf(16))]),
    xstts([]),
    xstsc([]),
    xstsz_const(0, 0),
    xstco([]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(1000, 0), xhdlr("vide"), stbl])])
  xpush(all, xmoov([xmvhd(1000, 0), trak, xbox("mvex", xtrex(1))]))
  // senc: version 0, no subsamples, two 16-byte IVs.
  let senc : Array[Byte] = []
  xpush(senc, xbytes([0]))
  xpush(senc, xb24(0))
  xpush(senc, xb32(2))
  xpush(senc, Array::make(16, b'\x01'))
  xpush(senc, Array::make(16, b'\x02'))
  let (moof, mdat) = xmoof(
    Some(0),
    0,
    [xbox("senc", senc)],
    [(16, 100, 0x02000000), (16, 100, 0x01010000)],
    xfill(32),
  )
  xpush(all, moof)
  xpush(all, mdat)
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.cenc_scheme, 0x63656E63)
  assert_eq(t.samples.length(), 2)
  assert_eq(t.cenc_samples.length(), 2)
  let e0 = t.cenc_samples[0].unwrap()
  assert_eq(e0.iv[0], 1)
  assert_eq(e0.iv[15], 1)
  let e1 = t.cenc_samples[1].unwrap()
  assert_eq(e1.iv[0], 2)
  assert_eq(e1.iv[15], 2)
}

test "mov: saiz/saio stream-level auxiliary info builds the encryption samples" {
  let all : Array[Byte] = []
  xpush(all, xftyp("isom"))
  // saiz: default size 16 (one IV), two samples; saio: one offset, patched
  // below once the layout is known.
  let saiz = xbox(
    "saiz",
    xconcat([xbytes([0]), xb24(0), xbytes([16]), xb32(2)]),
  )
  let saio = xbox(
    "saio",
    xconcat([xbytes([0]), xb24(0), xb32(1), xb32(0)]),
  )
  let stbl = xstbl([
    xstsd([xvideo_entry("avc1", xenc_sinf(16))]),
    xstts([]),
    xstsc([]),
    xstsz_const(0, 0),
    xstco([]),
  ])
  let trak = xtrak([xtkhd(1), xmdia([xmdhd(1000, 0), xhdlr("vide"), stbl])])
  xpush(all, xmoov([
    xmvhd(1000, 0),
    trak,
    xbox("mvex", xtrex(1)),
    saiz,
    saio,
  ]))
  let aux = xconcat([Array::make(16, b'\xA1'), Array::make(16, b'\xB2')])
  let aux_off = all.length() + 8 // payload of the free box below
  let saio_entry_pos = all.length() - saio.length() + 8 + 4 + 4
  all[saio_entry_pos] = ((aux_off >> 24) & 0xFF).to_byte()
  all[saio_entry_pos + 1] = ((aux_off >> 16) & 0xFF).to_byte()
  all[saio_entry_pos + 2] = ((aux_off >> 8) & 0xFF).to_byte()
  all[saio_entry_pos + 3] = (aux_off & 0xFF).to_byte()
  xpush(all, xbox("free", aux))
  let movie = av_mov_open(Bytes::from_array(all[:])).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.cenc_samples.length(), 2)
  let e0 = t.cenc_samples[0].unwrap()
  assert_eq(e0.iv[0], 0xA1)
  assert_eq(e0.iv[15], 0xA1)
  assert_eq(e0.subsamples.length(), 0)
  let e1 = t.cenc_samples[1].unwrap()
  assert_eq(e1.iv[0], 0xB2)
}
