///|
/// Whitebox tests for the MP4/MOV demuxer slice.
///
/// The MP4 files are synthesised byte by byte in the test, so every expected
/// value below is hand-derived from the box layout and the `mov.c` semantics
/// that `mov.mbt` ports (per-sample offsets from `stsc`/`stsz`/`stco`, DTS from
/// `stts`, PTS from `ctts` plus `dts_shift`, keyframe flags from `stss`).

// ---------------------------------------------------------------------------
// Big-endian byte writers and box builders
// ---------------------------------------------------------------------------

fn be16(v : UInt) -> Array[Byte] {
  let a : Array[Byte] = []
  a.push(((v >> 8) & 0xFF).to_byte())
  a.push((v & 0xFF).to_byte())
  a
}

fn be24(v : UInt) -> Array[Byte] {
  let a : Array[Byte] = []
  a.push(((v >> 16) & 0xFF).to_byte())
  a.push(((v >> 8) & 0xFF).to_byte())
  a.push((v & 0xFF).to_byte())
  a
}

fn be32(v : UInt) -> Array[Byte] {
  let a : Array[Byte] = []
  a.push(((v >> 24) & 0xFF).to_byte())
  a.push(((v >> 16) & 0xFF).to_byte())
  a.push(((v >> 8) & 0xFF).to_byte())
  a.push((v & 0xFF).to_byte())
  a
}

fn be64(v : UInt64) -> Array[Byte] {
  let a : Array[Byte] = []
  let mut i = 7
  while i >= 0 {
    a.push(((v >> (i * 8)) & 0xFF).to_byte())
    i = i - 1
  }
  a
}

///| `n` zero bytes. */
fn zbytes(n : Int) -> Array[Byte] {
  Bytes::make(n, b'\x00').to_array()
}

fn push_all(dst : Array[Byte], src : Array[Byte]) -> Unit {
  for i = 0; i < src.length(); i = i + 1 {
    dst.push(src[i])
  }
}

fn cat(parts : Array[Array[Byte]]) -> Array[Byte] {
  let out : Array[Byte] = []
  for i = 0; i < parts.length(); i = i + 1 {
    push_all(out, parts[i])
  }
  out
}

fn cat2(a : Array[Byte], b : Array[Byte]) -> Array[Byte] {
  cat([a, b])
}

///| A 32-bit-sized box: `size(4) + type(4) + payload`. */
fn box(kind : Bytes, body : Array[Byte]) -> Array[Byte] {
  cat([
    be32((body.length() + 8).reinterpret_as_uint()),
    kind.to_array(),
    body,
  ])
}

///| A box using the 64-bit `largesize` form: `size(4)=1 + type(4) + largesize(8) + payload`. */
fn box64(kind : Bytes, body : Array[Byte]) -> Array[Byte] {
  cat([
    be32(1),
    kind.to_array(),
    be64((body.length() + 16).to_uint64()),
    body,
  ])
}

///| A full box: version and flags occupy the first 4 payload bytes. */
fn fbox(kind : Bytes, version : UInt, flags : UInt, body : Array[Byte]) -> Array[Byte] {
  box(kind, cat2(be32((version << 24) | flags), body))
}

// ---------------------------------------------------------------------------
// Sample-table box builders
// ---------------------------------------------------------------------------

fn mvhd_box(timescale : UInt, duration : UInt) -> Array[Byte] {
  fbox(
    b"mvhd",
    0,
    0,
    cat([be32(0), be32(0), be32(timescale), be32(duration)]),
  )
}

fn tkhd_box(track_id : UInt, duration : UInt, width : UInt, height : UInt) -> Array[Byte] {
  fbox(
    b"tkhd",
    0,
    3,
    cat([
      be32(0),
      be32(0),
      be32(track_id),
      be32(0),
      be32(duration),
      be32(0),
      be32(0),
      be16(0),
      be16(0),
      be16(0),
      be16(0),
      zbytes(36),
      be32(width << 16),
      be32(height << 16),
    ]),
  )
}

fn mdhd_box(timescale : UInt, duration : UInt) -> Array[Byte] {
  fbox(
    b"mdhd",
    0,
    0,
    cat([be32(0), be32(0), be32(timescale), be32(duration), be16(0), be16(0)]),
  )
}

fn hdlr_box(handler : Bytes) -> Array[Byte] {
  fbox(
    b"hdlr",
    0,
    0,
    cat([b"mhlr".to_array(), handler.to_array(), zbytes(12), b"name".to_array()]),
  )
}

///|
/// A video sample entry (isom layout), enough for `mov_parse_stsd_video`:
/// 16 pre-defined bytes, width/height, resolutions, frame count, a zero-length
/// codec name padded to 32 bytes, and the depth.
fn video_entry_isom(format : Bytes, width : UInt, height : UInt) -> Array[Byte] {
  let entry_body = cat([
    zbytes(16),
    be16(width),
    be16(height),
    be32(0),
    be32(0),
    be32(0),
    be16(1), // frame count
    [b'\x00'], // codec name length 0
    zbytes(31), // name padding to 32 bytes
    be16(24), // depth
    [b'\xff', b'\xff'], // pre_defined = -1
  ])
  cat([
    be32((entry_body.length() + 16).reinterpret_as_uint()),
    format.to_array(),
    zbytes(6),
    be16(1),
    entry_body,
  ])
}

///| A video sample entry using the QuickTime (non-isom) layout. */
fn video_entry_qt(format : Bytes, width : UInt, height : UInt) -> Array[Byte] {
  let entry_body = cat([
    be16(0),
    be16(0),
    be32(0),
    be32(0),
    be32(0),
    be16(width),
    be16(height),
    be32(0),
    be32(0),
    be32(0),
    be16(1), // frame count
    [b'\x00'], // codec name length 0
    zbytes(31), // name padding to 32 bytes
    be16(24), // depth
    [b'\xff', b'\xff'], // color_table_id = -1
  ])
  cat([
    be32((entry_body.length() + 16).reinterpret_as_uint()),
    format.to_array(),
    zbytes(6),
    be16(1),
    entry_body,
  ])
}

///| An audio sample entry (isom layout): version, 6 reserved bytes, channels, sample size, ids, sample rate. */
fn audio_entry_isom(
  format : Bytes,
  channels : UInt,
  sample_bits : UInt,
  sample_rate : UInt
) -> Array[Byte] {
  let entry_body = cat([
    be16(0),
    zbytes(6),
    be16(channels),
    be16(sample_bits),
    be16(0),
    be16(0),
    be32(sample_rate << 16),
  ])
  cat([
    be32((entry_body.length() + 16).reinterpret_as_uint()),
    format.to_array(),
    zbytes(6),
    be16(1),
    entry_body,
  ])
}

fn stsd_box(entry : Array[Byte]) -> Array[Byte] {
  fbox(b"stsd", 0, 0, cat([be32(1), entry]))
}

fn stts_box(counts : Array[(UInt, UInt)]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < counts.length(); i = i + 1 {
    push_all(body, be32(counts[i].0))
    push_all(body, be32(counts[i].1))
  }
  fbox(b"stts", 0, 0, cat([be32(counts.length().reinterpret_as_uint()), body]))
}

fn ctts_box(entries : Array[(UInt, Int)]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < entries.length(); i = i + 1 {
    push_all(body, be32(entries[i].0))
    push_all(body, be32(entries[i].1.reinterpret_as_uint()))
  }
  fbox(b"ctts", 0, 0, cat([be32(entries.length().reinterpret_as_uint()), body]))
}

fn stsc_box(entries : Array[(UInt, UInt, UInt)]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < entries.length(); i = i + 1 {
    push_all(body, be32(entries[i].0))
    push_all(body, be32(entries[i].1))
    push_all(body, be32(entries[i].2))
  }
  fbox(b"stsc", 0, 0, cat([be32(entries.length().reinterpret_as_uint()), body]))
}

fn stsz_box(sample_size : UInt, entries : UInt) -> Array[Byte] {
  fbox(b"stsz", 0, 0, cat([be32(sample_size), be32(entries)]))
}

fn stsz_variable_box(sizes : Array[UInt]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < sizes.length(); i = i + 1 {
    push_all(body, be32(sizes[i]))
  }
  fbox(
    b"stsz",
    0,
    0,
    cat([be32(0), be32(sizes.length().reinterpret_as_uint()), body]),
  )
}

///| `stz2` with `field_size` bits per sample; `packed` holds the raw packed sizes. */
fn stz2_box(field_size : UInt, entries : UInt, packed : Array[Byte]) -> Array[Byte] {
  fbox(
    b"stz2",
    0,
    0,
    cat([be24(0), [field_size.to_byte()], be32(entries), packed]),
  )
}

fn stco_box(offsets : Array[UInt]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < offsets.length(); i = i + 1 {
    push_all(body, be32(offsets[i]))
  }
  fbox(b"stco", 0, 0, cat([be32(offsets.length().reinterpret_as_uint()), body]))
}

fn co64_box(offsets : Array[UInt64]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < offsets.length(); i = i + 1 {
    push_all(body, be64(offsets[i]))
  }
  fbox(b"co64", 0, 0, cat([be32(offsets.length().reinterpret_as_uint()), body]))
}

fn stss_box(keyframes : Array[UInt]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < keyframes.length(); i = i + 1 {
    push_all(body, be32(keyframes[i]))
  }
  fbox(b"stss", 0, 0, cat([be32(keyframes.length().reinterpret_as_uint()), body]))
}

fn elst_box(entries : Array[(UInt, Int)]) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < entries.length(); i = i + 1 {
    push_all(body, be32(entries[i].0))
    push_all(body, be32(entries[i].1.reinterpret_as_uint()))
    push_all(body, be32(65536)) // rate = 1.0
  }
  fbox(b"elst", 0, 0, cat([be32(entries.length().reinterpret_as_uint()), body]))
}

///| `ftyp`: the major brand is the first 4 payload bytes. */
fn ftyp_box(major : Bytes) -> Array[Byte] {
  box(b"ftyp", cat([major.to_array(), be32(512), be32(0)]))
}

///| Assemble `moov` from a track body plus the movie header. */
fn build_movie(mvhd : Array[Byte], trak : Array[Byte], use_64bit_moov : Bool) -> Array[Byte] {
  let moov_body = cat([mvhd, trak])
  let moov = if use_64bit_moov { box64(b"moov", moov_body) } else { box(b"moov", moov_body) }
  let mdat = box(b"mdat", zbytes(32))
  cat([ftyp_box(b"isom"), moov, mdat])
}

///| Assemble one `trak` from its boxes. */
fn build_trak(tkhd : Array[Byte], mdhd : Array[Byte], hdlr : Array[Byte], stbl : Array[Byte], edts : Array[Byte]) -> Array[Byte] {
  let minf = box(b"minf", stbl)
  let mdia = box(b"mdia", cat([mdhd, hdlr, minf]))
  let parts = if edts.length() > 0 { cat([tkhd, edts, mdia]) } else { cat([tkhd, mdia]) }
  box(b"trak", parts)
}

fn build_stbl(
  stsd : Array[Byte],
  stts : Array[Byte],
  ctts : Array[Byte],
  stsc : Array[Byte],
  stsz : Array[Byte],
  stco : Array[Byte],
  stss : Array[Byte]
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
  box(b"stbl", cat(parts))
}

// ---------------------------------------------------------------------------
// Fragmented MP4 (moof / traf / trun) builders
// ---------------------------------------------------------------------------

///| `tfhd` with `default-base-is-moof` and no per-fragment defaults. */
fn tfhd_box_dbm(track_id : UInt) -> Array[Byte] {
  fbox(b"tfhd", 0, 0x020000, be32(track_id))
}

///| `tfdt` (version 0). */
fn tfdt_box_v0(bmdt : UInt) -> Array[Byte] {
  fbox(b"tfdt", 0, 0, be32(bmdt))
}

///| A `mvex` box with one `trex` (no default duration/size/flags). */
fn mvex_box(track_id : UInt) -> Array[Byte] {
  let trex = fbox(
    b"trex",
    0,
    0,
    cat([be32(track_id), be32(1), be32(0), be32(0), be32(0)]),
  )
  box(b"mvex", trex)
}

///|
/// One `moof` with a single `traf` (`tfhd` + optional `tfdt` + one `trun`).
/// Each sample tuple is `(duration, size, flags)`; the `trun` carries
/// `data-offset | sample-duration | sample-size | sample-flags`.
fn frag_moof(
  track_id : UInt,
  tfdt : UInt?,
  data_offset : UInt,
  samples : Array[(UInt, UInt, UInt)]
) -> Array[Byte] {
  let trun_flags : UInt = 0x1 | 0x100 | 0x200 | 0x400
  let trun_body : Array[Byte] = []
  push_all(trun_body, be32(samples.length().reinterpret_as_uint()))
  push_all(trun_body, be32(data_offset))
  for i = 0; i < samples.length(); i = i + 1 {
    push_all(trun_body, be32(samples[i].0))
    push_all(trun_body, be32(samples[i].1))
    push_all(trun_body, be32(samples[i].2))
  }
  let trun = fbox(b"trun", 0, trun_flags, trun_body)
  let tfdt_part = match tfdt {
    None => zbytes(0)
    Some(v) => tfdt_box_v0(v)
  }
  let traf = box(b"traf", cat([tfhd_box_dbm(track_id), tfdt_part, trun]))
  box(b"moof", traf)
}

// ---------------------------------------------------------------------------
// cenc (encrypted MP4) builders
// ---------------------------------------------------------------------------

fn hexfind(digits : Bytes, c : Char) -> Int {
  let mut i = 0
  while i < digits.length() {
    if digits[i].to_char() == c {
      return i
    }
    i = i + 1
  }
  0
}

///| Decode a hex string into bytes (test-local; libavformat has no hex helper). */
fn hexbytes(s : String) -> Bytes {
  let digits : Bytes = b"0123456789abcdef"
  let a = s.to_array()
  let out : Array[Byte] = []
  let mut i = 0
  while i + 1 < a.length() {
    let hi = hexfind(digits, a[i])
    let lo = hexfind(digits, a[i + 1])
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out[:])
}

///| `sinf` with `schm` (scheme) and `schi`/`tenc` (pattern, IV size, KID, constant IV). */
fn sinf_box(
  scheme : Bytes,
  iv_size : UInt,
  key_id : Bytes,
  tenc_version : UInt,
  crypt : UInt,
  skip : UInt,
  constant_iv : Bytes
) -> Array[Byte] {
  let tenc_head = cat([
    [b'\x00'], // reserved
    [((crypt << 4) | skip).to_byte()], // pattern
    [b'\x01'], // is_protected
    [iv_size.to_byte()],
    key_id.to_array(),
  ])
  let tenc_body = if iv_size == 0 {
    cat([tenc_head, [constant_iv.length().to_byte()], constant_iv.to_array()])
  } else {
    tenc_head
  }
  let tenc = fbox(b"tenc", tenc_version, 0, tenc_body)
  let schi = box(b"schi", tenc)
  let schm = fbox(b"schm", 0, 0, cat([scheme.to_array(), be32(0)]))
  box(b"sinf", cat([schm, schi]))
}

///| A video sample entry whose payload carries a trailing `sinf` box. */
fn enc_video_entry(
  scheme : Bytes,
  iv_size : UInt,
  key_id : Bytes,
  tenc_version : UInt,
  crypt : UInt,
  skip : UInt,
  constant_iv : Bytes
) -> Array[Byte] {
  let fixed = cat([
    zbytes(16),
    be16(320),
    be16(240),
    be32(0),
    be32(0),
    be32(0),
    be16(1), // frame count
    [b'\x00'], // codec name length 0
    zbytes(31), // name padding to 32 bytes
    be16(24), // depth
    [b'\xff', b'\xff'], // pre_defined = -1
  ])
  let sinf = sinf_box(scheme, iv_size, key_id, tenc_version, crypt, skip, constant_iv)
  let entry_body = cat([fixed, sinf])
  cat([
    be32((entry_body.length() + 16).reinterpret_as_uint()),
    b"avc1".to_array(),
    zbytes(6),
    be16(1),
    entry_body,
  ])
}

///| `senc`: per-sample IV (and optional subsample map), matching `mov_read_senc`. */
fn senc_box(
  entries : Array[(Bytes, Array[(UInt, UInt)])],
  use_subsamples : Bool
) -> Array[Byte] {
  let body : Array[Byte] = []
  push_all(body, be32(entries.length().reinterpret_as_uint()))
  for i = 0; i < entries.length(); i = i + 1 {
    push_all(body, entries[i].0.to_array())
    if use_subsamples {
      let subs = entries[i].1
      push_all(body, be16(subs.length().reinterpret_as_uint()))
      for k = 0; k < subs.length(); k = k + 1 {
        push_all(body, be16(subs[k].0))
        push_all(body, be32(subs[k].1))
      }
    }
  }
  let flags : UInt = if use_subsamples { 0x02 } else { 0x00 }
  fbox(b"senc", 0, flags, body)
}

///|
/// Assemble a one-sample encrypted MP4: `ftyp` + `moov`(empty-`stbl` track with
/// `sinf` + `senc`) + `mdat`(ciphertext). `stco` is recomputed so the sample
/// offset points at the `mdat` payload; returns `(data, sample_offset)`.
fn assemble_cenc(
  entry : Array[Byte],
  senc : Array[Byte],
  sample_size : UInt,
  ciphertext : Bytes
) -> (Array[Byte], Int) {
  let ftyp = ftyp_box(b"isom")
  let make_stbl = fn(off : UInt) -> Array[Byte] {
    box(
      b"stbl",
      cat([
        stsd_box(entry),
        stts_box([(1, 100)]),
        stsc_box([(1, 1, 1)]),
        stsz_box(sample_size, 1),
        stco_box([off]),
        senc,
      ]),
    )
  }
  let placeholder = box(
    b"moov",
    cat([
      mvhd_box(1000, 100),
      build_trak(tkhd_box(1, 100, 320, 240), mdhd_box(1000, 100), hdlr_box(b"vide"), make_stbl(0), []),
    ]),
  )
  let off = ftyp.length() + placeholder.length() + 8
  let moov = box(
    b"moov",
    cat([
      mvhd_box(1000, 100),
      build_trak(
        tkhd_box(1, 100, 320, 240),
        mdhd_box(1000, 100),
        hdlr_box(b"vide"),
        make_stbl(off.reinterpret_as_uint()),
        [],
      ),
    ]),
  )
  let mdat = box(b"mdat", ciphertext.to_array())
  (cat([ftyp, moov, mdat]), off)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

///|
/// Video track, constant sample size, 10 samples in 5 chunks of 2.
/// `stts` gives 100 ticks per sample, `stss` marks samples 0 and 6 as sync
/// samples, so DTS is 0,100,...,900 and each chunk starts at its `stco` offset.
test "mp4: video sample table from stsc/stsz/stco/stts/stss" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 640, 360)),
    stts_box([(10, 100)]),
    [],
    stsc_box([(1, 2, 1)]),
    stsz_box(50, 10),
    stco_box([1000, 2000, 3000, 4000, 5000]),
    stss_box([1, 7]),
  )
  let trak = build_trak(
    tkhd_box(1, 5000, 640, 360),
    mdhd_box(1000, 5000),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 5000), trak, false)
  let movie = av_mov_open(Bytes::from_array(data)).unwrap()

  assert_eq(movie.major_brand, "isom")
  assert_eq(movie.isom, true)
  assert_eq(movie.timescale, 1000)
  assert_eq(movie.duration, 5000)
  assert_eq(movie.tracks.length(), 1)

  let t = movie.tracks[0]
  assert_eq(t.track_id, 1)
  assert_eq(t.handler, "vide")
  assert_eq(t.codec, "avc1")
  assert_eq(t.timescale, 1000)
  // mov_read_stts caps the mdhd duration with the stts total:
  // FFMIN(5000, 10 samples * 100) == 1000.
  assert_eq(t.duration, 1000)
  assert_eq(t.width, 640)
  assert_eq(t.height, 360)
  assert_eq(t.samples.length(), 10)

  // Chunk 0 starts at 1000 and holds samples 0-1 (50 bytes each).
  assert_eq(t.samples[0].offset, 1000)
  assert_eq(t.samples[1].offset, 1050)
  assert_eq(t.samples[2].offset, 2000)
  assert_eq(t.samples[3].offset, 2050)
  assert_eq(t.samples[8].offset, 5000)
  assert_eq(t.samples[9].offset, 5050)
  for i = 0; i < 10; i = i + 1 {
    assert_eq(t.samples[i].size, 50)
    assert_eq(t.samples[i].duration, 100)
    assert_eq(t.samples[i].dts, (i * 100).to_int64())
    // No ctts: the presentation timestamp equals the DTS.
    assert_eq(t.samples[i].pts, (i * 100).to_int64())
  }
  // stss lists 1-based samples 1 and 7, so indices 0 and 6 are keyframes.
  assert_eq(t.samples[0].keyframe, true)
  assert_eq(t.samples[1].keyframe, false)
  assert_eq(t.samples[6].keyframe, true)
  assert_eq(t.samples[7].keyframe, false)
  assert_eq(t.samples[0].min_distance, 0)
  assert_eq(t.samples[1].min_distance, 1)
}

///|
/// `ctts` shifts presentation: 2 samples at offset 0 then 2 at offset 100,
/// giving PTS 0,100,300,400 against DTS 0,100,200,300.
test "mp4: ctts produces reordered pts" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 320, 240)),
    stts_box([(4, 100)]),
    ctts_box([(2, 0), (2, 100)]),
    stsc_box([(1, 4, 1)]),
    stsz_box(10, 4),
    stco_box([100]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 400, 320, 240),
    mdhd_box(1000, 400),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 400), trak, false)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.samples.length(), 4)
  assert_eq(t.samples[0].dts, 0)
  assert_eq(t.samples[1].dts, 100)
  assert_eq(t.samples[2].dts, 200)
  assert_eq(t.samples[3].dts, 300)
  assert_eq(t.samples[0].pts, 0)
  assert_eq(t.samples[1].pts, 100)
  assert_eq(t.samples[2].pts, 300)
  assert_eq(t.samples[3].pts, 400)
  // A track without stss treats every sample as a sync sample.
  for i = 0; i < 4; i = i + 1 {
    assert_eq(t.samples[i].keyframe, true)
  }
}

///|
/// A negative `ctts` offset on a non-final entry sets `dts_shift` (50), which is
/// subtracted from every DTS and added back into every PTS:
/// DTS -50,50,150,250 and PTS -50,200,200,300.
test "mp4: negative ctts offset sets dts_shift" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 320, 240)),
    stts_box([(4, 100)]),
    ctts_box([(1, -50), (1, 100), (2, 0)]),
    stsc_box([(1, 4, 1)]),
    stsz_box(10, 4),
    stco_box([100]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 400, 320, 240),
    mdhd_box(1000, 400),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 400), trak, false)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.dts_shift, 50)
  assert_eq(t.samples[0].dts, -50)
  assert_eq(t.samples[1].dts, 50)
  assert_eq(t.samples[2].dts, 150)
  assert_eq(t.samples[3].dts, 250)
  assert_eq(t.samples[0].pts, -50)
  assert_eq(t.samples[1].pts, 200)
  assert_eq(t.samples[2].pts, 200)
  assert_eq(t.samples[3].pts, 300)
}

///|
/// Variable sample sizes from `stsz` (`sample_size == 0`): sizes 10,20,30 in a
/// single chunk at offset 700 accumulate to 700,710,730.
test "mp4: variable sample sizes from stsz" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 16, 16)),
    stts_box([(3, 50)]),
    [],
    stsc_box([(1, 3, 1)]),
    stsz_variable_box([10, 20, 30]),
    stco_box([700]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 150, 16, 16),
    mdhd_box(1000, 150),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 150), trak, false)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.sample_sizes, [10, 20, 30])
  assert_eq(t.samples.length(), 3)
  assert_eq(t.samples[0].offset, 700)
  assert_eq(t.samples[0].size, 10)
  assert_eq(t.samples[1].offset, 710)
  assert_eq(t.samples[1].size, 20)
  assert_eq(t.samples[2].offset, 730)
  assert_eq(t.samples[2].size, 30)
  assert_eq(t.samples[2].dts, 100)
}

///|
/// `stz2` with 4-bit fields packs two samples per byte: 0x12 0x34 decodes to
/// sizes 1,2,3,4, so chunk offsets accumulate as 500,501,503,506.
test "mp4: stz2 4-bit sample sizes" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 320, 240)),
    stts_box([(4, 10)]),
    [],
    stsc_box([(1, 4, 1)]),
    stz2_box(4, 4, [b'\x12', b'\x34']),
    stco_box([500]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 40, 320, 240),
    mdhd_box(1000, 40),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 40), trak, false)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.samples.length(), 4)
  assert_eq(t.sample_sizes, [1, 2, 3, 4])
  assert_eq(t.samples[0].offset, 500)
  assert_eq(t.samples[0].size, 1)
  assert_eq(t.samples[1].offset, 501)
  assert_eq(t.samples[1].size, 2)
  assert_eq(t.samples[2].offset, 503)
  assert_eq(t.samples[3].offset, 506)
}

///|
/// Audio track with a 64-bit `moov` header and `co64` chunk offsets above 2^32.
test "mp4: audio metadata with 64-bit box size and co64 offsets" {
  let stbl = build_stbl(
    stsd_box(audio_entry_isom(b"mp4a", 2, 16, 44100)),
    stts_box([(2, 1024)]),
    [],
    stsc_box([(1, 1, 1)]),
    stsz_box(100, 2),
    co64_box([4294967296, 4294967396]),
    [],
  )
  let trak = build_trak(
    tkhd_box(7, 1024, 0, 0),
    mdhd_box(44100, 1024),
    hdlr_box(b"soun"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 1024), trak, true)
  let movie = av_mov_open(Bytes::from_array(data)).unwrap()
  let t = movie.tracks[0]

  assert_eq(t.track_id, 7)
  assert_eq(t.handler, "soun")
  assert_eq(t.codec, "mp4a")
  assert_eq(t.channels, 2)
  assert_eq(t.bits_per_sample, 16)
  assert_eq(t.sample_rate, 44100)
  // One sample per chunk, so the two co64 offsets are used verbatim and exceed
  // the 32-bit range that stco could express.
  assert_eq(t.samples.length(), 2)
  assert_eq(t.samples[0].offset, 4294967296)
  assert_eq(t.samples[0].size, 100)
  assert_eq(t.samples[0].dts, 0)
  assert_eq(t.samples[1].offset, 4294967396)
  assert_eq(t.samples[1].dts, 1024)
}

///|
/// An edit list whose first entry is empty (media time -1) shifts the first DTS:
/// `time_offset = start_time - rescale(empty_duration)`, so DTS starts at
/// `-clip(time_offset)` == 800.
test "mp4: edit list shifts the first dts" {
  let edts = box(b"edts", elst_box([(1000, -1), (4000, 200)]))
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 320, 240)),
    stts_box([(4, 100)]),
    [],
    stsc_box([(1, 4, 1)]),
    stsz_box(10, 4),
    stco_box([100]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 4000, 320, 240),
    mdhd_box(1000, 4000),
    hdlr_box(b"vide"),
    stbl,
    edts,
  )
  let data = build_movie(mvhd_box(1000, 5000), trak, false)
  // Non-advanced: the whole track keeps its 4 samples with the first DTS
  // shifted by -time_offset (200 - 1000 = -800 → dts starts at 800).
  let t = av_mov_open_with(Bytes::from_array(data), false).unwrap().tracks[0]
  assert_eq(t.elst.length(), 2)
  assert_eq(t.time_offset, -800)
  assert_eq(t.samples.length(), 4)
  assert_eq(t.samples[0].dts, 800)
  assert_eq(t.samples[1].dts, 900)
  // Advanced (FFmpeg default): the walk starts at the closest key frame at
  // or before media_time 200 — sample 2 (no stss ⇒ every sample is a key
  // frame) — and the timeline starts after the 1000-unit empty edit.
  let a = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]
  assert_eq(a.samples.length(), 2)
  assert_eq(a.samples[0].dts, 1000)
  assert_eq(a.samples[1].dts, 1100)
  assert_eq(a.start_time, 1000)
  assert_eq(a.min_corrected_pts, 0)
}

///| QuickTime branding turns `isom` off, which selects the non-isom sample-entry layout. */
test "mp4: qt brand uses the QuickTime video sample entry" {
  let moov = box(
    b"moov",
    cat([
      mvhd_box(600, 600),
      build_trak(
        tkhd_box(1, 600, 0, 0),
        mdhd_box(600, 600),
        hdlr_box(b"vide"),
        build_stbl(
          stsd_box(video_entry_qt(b"avc1", 1920, 1080)),
          stts_box([(1, 600)]),
          [],
          stsc_box([(1, 1, 1)]),
          stsz_box(10, 1),
          stco_box([100]),
          [],
        ),
        [],
      ),
    ]),
  )
  let data = cat([ftyp_box(b"qt  "), moov, box(b"mdat", zbytes(16))])
  let movie = av_mov_open(Bytes::from_array(data)).unwrap()

  assert_eq(movie.isom, false)
  assert_eq(movie.major_brand, "qt  ")
  assert_eq(movie.tracks[0].width, 1920)
  assert_eq(movie.tracks[0].height, 1080)
}

///| Unknown boxes must be skipped without derailing the walk. */
test "mp4: unknown boxes are skipped" {
  let stbl = box(
    b"stbl",
    cat([
      box(b"abcd", zbytes(24)),
      stsd_box(video_entry_isom(b"avc1", 16, 16)),
      box(b"wxyz", zbytes(3)),
      stts_box([(1, 100)]),
      stsc_box([(1, 1, 1)]),
      stsz_box(10, 1),
      stco_box([64]),
    ]),
  )
  let trak = build_trak(
    tkhd_box(1, 100, 16, 16),
    mdhd_box(1000, 100),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 100), trak, false)
  let movie = av_mov_open(Bytes::from_array(data)).unwrap()

  assert_eq(movie.tracks.length(), 1)
  assert_eq(movie.tracks[0].samples.length(), 1)
  assert_eq(movie.tracks[0].samples[0].offset, 64)
}

///| An empty or truncated buffer parses to an empty movie rather than failing. */
test "mp4: empty and truncated input" {
  let empty = av_mov_open(b"").unwrap()
  assert_eq(empty.tracks.length(), 0)

  // A box header declaring a size smaller than the header itself.
  let bad = av_mov_open(Bytes::from_array(be32(4))).unwrap()
  assert_eq(bad.tracks.length(), 0)

  // Truncated in the middle of a box: the walk stops at the buffer end.
  let truncated = av_mov_open(Bytes::from_array(cat([be32(1024), b"moov".to_array()]))).unwrap()
  assert_eq(truncated.tracks.length(), 0)
}

///| An invalid `stsd` entry count is rejected, mirroring AVERROR_INVALIDDATA. */
test "mp4: invalid stsd entry count is an error" {
  let stbl = box(
    b"stbl",
    cat([fbox(b"stsd", 0, 0, be32(0)), stts_box([(1, 100)])]),
  )
  let trak = build_trak(
    tkhd_box(1, 100, 16, 16),
    mdhd_box(1000, 100),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 100), trak, false)
  assert_true(av_mov_open(Bytes::from_array(data)) is Err(_))
}

///| The `stsc` validation pass repairs non-monotonic entries, as `mov_read_stsc` does. */
test "mp4: stsc validation repairs a trailing bad entry" {
  // Entry 0 is valid; entry 1 repeats first=1 (not increasing) and count=0.
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 16, 16)),
    stts_box([(2, 100)]),
    [],
    stsc_box([(1, 1, 1), (1, 0, 1)]),
    stsz_box(10, 2),
    stco_box([100]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 200, 16, 16),
    mdhd_box(1000, 200),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let data = build_movie(mvhd_box(1000, 200), trak, false)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  // The trailing zero-count entry is dropped, leaving one valid entry.
  assert_eq(t.stsc.length(), 1)
  assert_eq(t.stsc[0].first, 1)
  assert_eq(t.samples.length(), 1)
  assert_eq(t.samples[0].offset, 100)
}

///|
/// Fragmented MP4: an empty-`stbl` init segment plus two `moof` fragments.
/// Fragment 1 carries `tfdt=0` and three samples (DTS 0/100/200); fragment 2
/// has no `tfdt` and continues from `track_end = 300` (DTS 300/350). Sample
/// offsets come from `default-base-is-moof` + the `trun` data offset.
test "mp4: fragmented mp4 (moof/trun) sample index" {
  let stbl = build_stbl(
    stsd_box(video_entry_isom(b"avc1", 320, 240)),
    stts_box([]),
    [],
    stsc_box([]),
    stsz_box(0, 0),
    stco_box([]),
    [],
  )
  let trak = build_trak(
    tkhd_box(1, 0, 320, 240),
    mdhd_box(1000, 0),
    hdlr_box(b"vide"),
    stbl,
    [],
  )
  let ftyp = ftyp_box(b"isom")
  let moov = box(b"moov", cat([mvhd_box(1000, 0), trak, mvex_box(1)]))

  let s1 : Array[(UInt, UInt, UInt)] = [(100, 10, 0), (100, 20, 0x10000), (100, 30, 0)]
  let s2 : Array[(UInt, UInt, UInt)] = [(50, 15, 0), (50, 25, 0x10000)]

  // The data offset points from the moof start to the mdat payload that
  // immediately follows it, so it is `moof_length + 8`.
  let moof1_ph = frag_moof(1, Some(0), 0, s1)
  let moof1 = frag_moof(1, Some(0), moof1_ph.length().reinterpret_as_uint() + 8, s1)
  let mdat1 = box(b"mdat", zbytes(60))
  let moof2_ph = frag_moof(1, None, 0, s2)
  let moof2 = frag_moof(1, None, moof2_ph.length().reinterpret_as_uint() + 8, s2)
  let mdat2 = box(b"mdat", zbytes(40))

  let prefix = ftyp.length() + moov.length()
  let off_frag1 = prefix + moof1.length() + 8
  let off_frag2 = prefix + moof1.length() + mdat1.length() + moof2.length() + 8

  let data = cat([ftyp, moov, moof1, mdat1, moof2, mdat2])
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.samples.length(), 5)
  assert_eq(t.samples[0].offset, off_frag1.to_int64())
  assert_eq(t.samples[1].offset, (off_frag1 + 10).to_int64())
  assert_eq(t.samples[2].offset, (off_frag1 + 30).to_int64())
  assert_eq(t.samples[3].offset, off_frag2.to_int64())
  assert_eq(t.samples[4].offset, (off_frag2 + 15).to_int64())

  assert_eq(t.samples[0].dts, 0)
  assert_eq(t.samples[1].dts, 100)
  assert_eq(t.samples[2].dts, 200)
  assert_eq(t.samples[3].dts, 300)
  assert_eq(t.samples[4].dts, 350)
  assert_eq(t.samples[0].pts, 0)
  assert_eq(t.samples[4].pts, 350)

  let sz : Array[UInt] = [10, 20, 30, 15, 25]
  let du : Array[UInt] = [100, 100, 100, 50, 50]
  for i = 0; i < 5; i = i + 1 {
    assert_eq(t.samples[i].size, sz[i])
    assert_eq(t.samples[i].duration, du[i])
    assert_eq(t.samples[i].pts, t.samples[i].dts)
  }

  // Sample flags: 0 means keyframe, IS_NON_SYNC marks the others.
  assert_eq(t.samples[0].keyframe, true)
  assert_eq(t.samples[1].keyframe, false)
  assert_eq(t.samples[2].keyframe, true)
  assert_eq(t.samples[3].keyframe, true)
  assert_eq(t.samples[4].keyframe, false)
  assert_eq(t.samples[1].min_distance, 1)
  assert_eq(t.samples[4].min_distance, 1)
}

///|
/// cenc (AES-CTR) full-sample decryption. The `mdat` holds ciphertext produced
/// by AES-CTR with the same key/IV; the demuxer must recover the plaintext
/// through the `sinf`(schm/tenc) + `senc` metadata.
test "mp4: cenc (AES-CTR) full-sample decryption" {
  let plain = hexbytes("00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100")
  let key = hexbytes("000102030405060708090a0b0c0d0e0f")
  let iv = hexbytes("101112131415161718191a1b1c1d1e1f")
  let ctr = @libavutil.av_aes_ctr_alloc()
  let _ = @libavutil.av_aes_ctr_init(ctr, key).unwrap()
  @libavutil.av_aes_ctr_set_full_iv(ctr, iv)
  let ct = @libavutil.av_aes_ctr_crypt(ctr, plain, plain.length())

  let entry = enc_video_entry(
    b"cenc",
    16,
    hexbytes("00000000000000000000000000000000"),
    0,
    0,
    0,
    b"",
  )
  let senc = senc_box([(iv, [])], false)
  let (data, off) = assemble_cenc(entry, senc, plain.length().reinterpret_as_uint(), ct)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.cenc_scheme, 0x63656E63)
  assert_eq(t.cenc_per_sample_iv_size, 16)
  assert_eq(t.samples.length(), 1)
  assert_eq(t.samples[0].offset, off.to_int64())
  assert_eq(t.samples[0].size, plain.length().reinterpret_as_uint())

  let payload = Bytes::from_array(data[off:off + plain.length()])
  assert_eq(mov_decrypt_sample(t, 0, key, payload).unwrap(), plain)
}

///|
/// cenc with subsample encryption: bytes 0..16 are clear and 16..32 protected.
/// Decryption must leave the clear range untouched and only unwrap the
/// protected range (whose keystream starts at the IV).
test "mp4: cenc (AES-CTR) subsample decryption" {
  let plain = hexbytes("00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100")
  let key = hexbytes("000102030405060708090a0b0c0d0e0f")
  let iv = hexbytes("101112131415161718191a1b1c1d1e1f")
  let plain_arr = plain.to_array()
  let ctr = @libavutil.av_aes_ctr_alloc()
  let _ = @libavutil.av_aes_ctr_init(ctr, key).unwrap()
  @libavutil.av_aes_ctr_set_full_iv(ctr, iv)
  let enc_part = @libavutil.av_aes_ctr_crypt(ctr, Bytes::from_array(plain_arr[16:32]), 16)
  let ct_arr : Array[Byte] = []
  for i = 0; i < 16; i = i + 1 {
    ct_arr.push(plain_arr[i])
  }
  for i = 0; i < enc_part.length(); i = i + 1 {
    ct_arr.push(enc_part[i])
  }
  let ct = Bytes::from_array(ct_arr)

  let entry = enc_video_entry(
    b"cenc",
    16,
    hexbytes("00000000000000000000000000000000"),
    0,
    0,
    0,
    b"",
  )
  let senc = senc_box([(iv, [(16, 16)])], true)
  let (data, off) = assemble_cenc(entry, senc, plain.length().reinterpret_as_uint(), ct)
  let t = av_mov_open(Bytes::from_array(data)).unwrap().tracks[0]

  assert_eq(t.samples.length(), 1)
  let payload = Bytes::from_array(data[off:off + plain.length()])
  assert_eq(mov_decrypt_sample(t, 0, key, payload).unwrap(), plain)
}
