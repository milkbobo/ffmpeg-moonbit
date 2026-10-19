///|
/// MoonBit port of the MP4/MOV demuxer core of FFmpeg 9.0.2
/// (`libavformat/mov.c`), scoped to container parsing and sample-table
/// extraction.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope of this slice (see `README.md` for the roadmap):
///   * parsed: box traversal, `ftyp`, `moov`/`mvhd`, `trak`/`tkhd`, `mdia`/
///     `mdhd`, `hdlr`, `edts`/`elst`, `stbl`/`stsd`, `stts`, `ctts`, `stsc`,
///     `stsz`/`stz2`, `stco`/`co64`, `stss`/`stps`, and the
///     `mov_merge_tts_data` + `mov_build_index` sample-index construction.
///   * per sample: file offset, size, DTS, duration, presentation timestamp,
///     keyframe and `min_distance` flags -- mirroring what FFmpeg stores in
///     `AVIndexEntry` and later reports in `AVPacket`.
///   * fragmented MP4: `moof`/`traf`/`tfhd`/`tfdt`/`trun`/`trex` are parsed to
///     append per-sample entries to the matching track (base-data-offset /
///     default-base-is-moof, tfdt-driven DTS with the `sidx` fallback,
///     per-sample duration/size/flags/CTS); samples of overlapping fragments
///     are flagged `discard` as `AVINDEX_DISCARD_FRAME` would.
///   * fragment index: `sidx` references (offset / earliest presentation time
///     rescaled to the track timescale, subsegment size and duration) and the
///     trailing `mfra`/`tfra` random-access table (`mov_read_mfra` probing the
///     `mfro` size word at the end of the file).
///   * codec extradata: `avcC`/`hvcC`/`av1C`/`glbl`/... payloads become the
///     track extradata verbatim (`mov_read_glbl`); `esds` walks the MPEG-4
///     descriptor chain to the DecoderSpecificInfo and parses the AAC
///     AudioSpecificConfig (see `extradata.mbt` and the libavcodec
///     `mpeg4audio.mbt` port).
///   * seeking: `mov_seek_stream` / `ff_index_search_timestamp` over the
///     materialised samples (see `seek.mbt`), including the HEVC
///     open-GOP gate in its no-sgpd fallback form.
///   * the chunked "old uncompressed audio" index path (stts of a single
///     duration-1 entry) is ported, driven by the audio sample-entry v1/v2
///     packing fields (`samples_per_frame`/`bytes_per_frame`, plus the
///     MACE/ADPCM/GSM defaults and `av_get_bits_per_sample` for the PCM
///     fourccs).
///   * encryption (`cenc`): `sinf`/`schm`/`tenc` (scheme, pattern, per-sample
///     IV size, constant IV), `senc` (per-sample IV + subsample map, both at
///     stream level and inside `moof`), and `saiz`/`saio` auxiliary info are
///     parsed, and `mov_decrypt_sample` unwraps a sample for the
///     `cenc`/`cbc1`/`cens`/`cbcs` schemes with a caller-supplied key.
///   * not ported: AVIO/AVPacket/AVFormatContext plumbing (this parser works on
///     an in-memory buffer the caller has already read), `rap_group`
///     (sgpd/sbgp) keypoint marking, multi sample-description tracks,
///     `advanced_editlist`, and the `dvcC`/`dvvC` whole-atom extradata
///     variants.
///   * simplified: per-sample timestamps are materialised up front instead
///     of being consulted lazily, the `free`/`hoov`-hiding-`moov` recovery is
///     omitted, and corrupt-count guards are tightened relative to the C code.

///| Parse failure, corresponding to the negative returns in libavformat/mov.c. */
pub suberror MovError {
  InvalidData(String)
}

// ---------------------------------------------------------------------------
// Data model (mirrors the MOV structs in libavformat/isom.h)
// ---------------------------------------------------------------------------

///| `MOVStts` from libavformat/isom.h. */
pub struct MovStts {
  count : Int
  duration : UInt
}

///| `MOVCtts` from libavformat/isom.h. */
pub struct MovCtts {
  count : Int
  offset : Int
}

///| `MOVStsc` from libavformat/isom.h. */
pub struct MovStsc {
  first : Int
  count : Int
  id : Int
}

///| `MOVElst` from libavformat/isom.h. */
pub struct MovElst {
  duration : Int64
  time : Int64
  rate : Double
}

///|
/// `MOVTimeToSample` from libavformat/mov.c: the per-sample table produced by
/// merging `stts` and `ctts`, where `offset` is the CTTS presentation offset and
/// `duration` the STTS sample duration.
pub struct MovTts {
  count : Int
  offset : Int
  duration : UInt
}

///|
/// One entry of the sample index, corresponding to FFmpeg's `AVIndexEntry`
/// (`pos`, `timestamp`, `size`, `min_distance`, `flags`) plus the presentation
/// timestamp that `mov_finalize_packet` derives from it. `discard` mirrors
/// `AVINDEX_DISCARD_FRAME`: fragments overlapping in decode order are flagged
/// and skipped at demux time.
pub struct Mp4Sample {
  offset : Int64
  size : UInt
  dts : Int64
  pts : Int64
  duration : UInt
  keyframe : Bool
  min_distance : UInt
  discard : Bool
}

///| Media type derived from the `hdlr` handler type (AVMediaType subset). */
pub enum Mp4MediaType {
  Video
  Audio
  Subtitle
  Unknown
}

///| True for video tracks, avoiding a structural `Eq` on `Mp4MediaType`. */
fn media_is_video(t : Mp4MediaType) -> Bool {
  match t {
    Video => true
    _ => false
  }
}

///| True for audio tracks. */
fn media_is_audio(t : Mp4MediaType) -> Bool {
  match t {
    Audio => true
    _ => false
  }
}

///|
/// Per-track state, corresponding to `MOVStreamContext` plus the stream fields
/// of `AVStream` that this slice needs.
///
/// The array-valued fields are only ever mutated in place (`push`/element
/// assignment), so they carry no `mut` marker.
pub struct Mp4Track {
  mut track_id : UInt
  mut handler : String
  mut media_type : Mp4MediaType
  mut codec : String
  ///| FFmpeg codec-id name resolved from `esds` (`""` when not set). */
  mut codec_id : String
  ///| Raw codec private data (`avcC`/`hvcC`/`av1C`/`glbl` payload or the `esds` DecoderSpecificInfo). */
  mut extradata : Bytes?
  mut timescale : UInt
  mut duration : UInt64
  mut width : Int
  mut height : Int
  mut sample_rate : UInt
  mut channels : UInt
  mut bits_per_sample : UInt
  ///| `st->codecpar->frame_size` from the AAC AudioSpecificConfig. */
  mut frame_length : Int
  ///| `st->codecpar->bit_rate` from the `esds` DecoderConfigDescriptor. */
  mut bit_rate : UInt
  mut encoder : String
  ///| Audio sample entry v1/v2 packing (`sc->samples_per_frame`). */
  mut samples_per_frame : UInt
  ///| Audio sample entry v1/v2 packing (`sc->bytes_per_frame`). */
  mut bytes_per_frame : UInt
  ///| Audio sample entry `compression_id` (`sc->audio_cid`). */
  mut audio_cid : Int
  stts : Array[MovStts]
  ctts : Array[MovCtts]
  stsc : Array[MovStsc]
  mut stsz_sample_size : UInt
  mut sample_size : UInt
  sample_sizes : Array[UInt]
  mut sample_count : Int
  chunk_offsets : Array[Int64]
  keyframes : Array[UInt]
  stps : Array[UInt]
  mut keyframe_absent : Bool
  elst : Array[MovElst]
  mut stsd_version : UInt
  mut dts_shift : Int
  mut time_offset : Int64
  mut track_end : Int64
  mut min_sample_duration : UInt
  mut has_sidx : Bool
  mut cenc_scheme : UInt
  mut cenc_per_sample_iv_size : Int
  mut cenc_crypt_byte_block : UInt
  mut cenc_skip_byte_block : UInt
  mut cenc_default_iv : FixedArray[Byte]
  cenc_samples : Array[MovEncSample?]
  ///| `saiz`: default per-sample size of the auxiliary info chunk. */
  mut aux_info_default_size : Int
  ///| `saiz`: per-sample sizes when the default is 0. */
  aux_info_sizes : Array[UInt]
  ///| `saiz`: declared sample count. */
  mut aux_info_sample_count : Int
  ///| `saio`: absolute offsets of the auxiliary info chunks. */
  aux_info_offsets : Array[Int64]
  mut tts : Array[MovTts]
  mut has_stts : Bool
  mut has_ctts : Bool
  mut unsupported_audio_chunk_demux : Bool
  samples : Array[Mp4Sample]
}

///| `MOVStreamContext` fragment-reference state from `mov_read_sidx`, kept per reference. */
pub struct MovSidxRef {
  track_id : UInt
  ///| Byte offset of the referenced fragment (its `moof`). */
  offset : Int64
  ///| Earliest presentation time rescaled to the track timescale. */
  pts : Int64
  ///| Subsegment byte size. */
  size : UInt
  ///| Subsegment duration in sidx timescale units. */
  duration : UInt
}

///| One `tfra` entry (fragment random-access point). */
pub struct MovTfraEntry {
  time : Int64
  offset : Int64
}

///| A `tfra` box: random-access points of one track. */
pub struct MovTfra {
  track_id : UInt
  entries : Array[MovTfraEntry]
}

///| Movie-level state, corresponding to the `MOVContext`/`AVFormatContext` fields used here. */
pub struct Mp4Movie {
  mut timescale : UInt
  mut duration : UInt64
  mut isom : Bool
  mut major_brand : String
  ///| All compatible brands of `ftyp`, concatenated (used by the QuickTime audio-entry check). */
  mut compatible_brands : String
  ///| `sidx` references, in file order. */
  sidx_refs : Array[MovSidxRef]
  ///| `mfra`/`tfra` random-access tables when the file ends with an `mfra`. */
  mfra : Array[MovTfra]
  tracks : Array[Mp4Track]
}

fn new_track() -> Mp4Track {
  {
    track_id: 0,
    handler: "",
    media_type: Mp4MediaType::Unknown,
    codec: "",
    codec_id: "",
    extradata: None,
    timescale: 0,
    duration: 0,
    width: 0,
    height: 0,
    sample_rate: 0,
    channels: 0,
    bits_per_sample: 0,
    frame_length: 0,
    bit_rate: 0,
    encoder: "",
    samples_per_frame: 0,
    bytes_per_frame: 0,
    audio_cid: 0,
    stts: [],
    ctts: [],
    stsc: [],
    stsz_sample_size: 0,
    sample_size: 0,
    sample_sizes: [],
    sample_count: 0,
    chunk_offsets: [],
    keyframes: [],
    stps: [],
    keyframe_absent: false,
    elst: [],
    stsd_version: 0,
    dts_shift: 0,
    time_offset: 0,
    track_end: 0,
    min_sample_duration: 0,
    has_sidx: false,
    cenc_scheme: 0,
    cenc_per_sample_iv_size: 0,
    cenc_crypt_byte_block: 0,
    cenc_skip_byte_block: 0,
    cenc_default_iv: FixedArray::make(16, b'\x00'),
    cenc_samples: [],
    aux_info_default_size: 0,
    aux_info_sizes: [],
    aux_info_sample_count: 0,
    aux_info_offsets: [],
    tts: [],
    has_stts: false,
    has_ctts: false,
    unsupported_audio_chunk_demux: false,
    samples: [],
  }
}

fn new_movie() -> Mp4Movie {
  {
    timescale: 0,
    duration: 0,
    isom: false,
    major_brand: "",
    compatible_brands: "",
    sidx_refs: [],
    mfra: [],
    tracks: [],
  }
}

///| `max_stts_delta` default from the mov demuxer options: `UINT_MAX - 48000*10`. */
let max_stts_delta : UInt = 4294487295

///| `UINT32_MAX`, used as mdhd's "unknown duration" marker in version 0. */
let u32_max_u64 : UInt64 = 0xFFFFFFFF

///| `UINT64_MAX`, the version 1 "unknown duration" marker. */
let u64_max : UInt64 = 0xFFFFFFFFFFFFFFFF

///| `INT64_MAX`, used as the "no next chunk" sentinel in `mov_build_index`. */
let i64_max : Int64 = 0x7FFFFFFFFFFFFFFF

// Fragment flags, from libavformat/isom.h.

///| `MOV_TFHD_BASE_DATA_OFFSET`. */
let tfhd_base_data_offset : UInt = 0x000001

///| `MOV_TFHD_STSD_ID`. */
let tfhd_stsd_id : UInt = 0x000002

///| `MOV_TFHD_DEFAULT_DURATION`. */
let tfhd_default_duration : UInt = 0x000008

///| `MOV_TFHD_DEFAULT_SIZE`. */
let tfhd_default_size : UInt = 0x000010

///| `MOV_TFHD_DEFAULT_FLAGS`. */
let tfhd_default_flags : UInt = 0x000020

///| `MOV_TFHD_DEFAULT_BASE_IS_MOOF`. */
let tfhd_default_base_is_moof : UInt = 0x020000

///| `MOV_TRUN_DATA_OFFSET`. */
let trun_data_offset : UInt = 0x0001

///| `MOV_TRUN_FIRST_SAMPLE_FLAGS`. */
let trun_first_sample_flags : UInt = 0x0004

///| `MOV_TRUN_SAMPLE_DURATION`. */
let trun_sample_duration : UInt = 0x0100

///| `MOV_TRUN_SAMPLE_SIZE`. */
let trun_sample_size : UInt = 0x0200

///| `MOV_TRUN_SAMPLE_FLAGS`. */
let trun_sample_flags : UInt = 0x0400

///| `MOV_TRUN_SAMPLE_CTS`. */
let trun_sample_cts : UInt = 0x0800

///| `MOV_FRAG_SAMPLE_FLAG_IS_NON_SYNC`. */
let frag_sample_flag_is_non_sync : UInt = 0x00010000

///| `MOV_FRAG_SAMPLE_FLAG_DEPENDS_YES`. */
let frag_sample_flag_depends_yes : UInt = 0x01000000

// Encryption scheme fourccs, `MKBETAG('c','e','n','c')` etc.

///| `cenc` (AES-CTR, full sample). */
let schm_cenc : UInt = 0x63656E63

///| `cens` (AES-CTR with pattern). */
let schm_cens : UInt = 0x63656E73

///| `cbc1` (AES-CBC, full sample). */
let schm_cbc1 : UInt = 0x63626331

///| `cbcs` (AES-CBC with pattern). */
let schm_cbcs : UInt = 0x63626373

///| `MOVTrackExt` from libavformat/isom.h, parsed from a `trex` box. */
priv struct MovTrex {
  track_id : UInt
  duration : UInt
  size : UInt
  flags : UInt
}

///|
/// `MOVFragment` from libavformat/isom.h: the current `moof`/`traf` header
/// state shared across the `tfhd`/`tfdt`/`trun` boxes of one track fragment.
/// `stsd_id` is dropped because this slice models only the primary sample
/// description (no `pseudo_stream_id` filtering).
priv struct MovFrag {
  mut found_tfhd : Bool
  mut track_id : UInt
  mut base_data_offset : Int64
  mut moof_offset : Int64
  mut implicit_offset : Int64
  mut duration : UInt
  mut size : UInt
  mut flags : UInt
  mut tfdt : Int64
  mut has_tfdt : Bool
}

///| Zero-valued initial fragment state. */
fn new_frag() -> MovFrag {
  {
    found_tfhd: false,
    track_id: 0,
    base_data_offset: 0,
    moof_offset: 0,
    implicit_offset: 0,
    duration: 0,
    size: 0,
    flags: 0,
    tfdt: 0,
    has_tfdt: false,
  }
}

///| `AVSubsampleEncryptionInfo` from libavutil/encryption_info.h. */
pub struct MovSubSample {
  bytes_of_clear : Int
  bytes_of_protected : Int
}

///|
/// Per-sample (or default) `AVEncryptionInfo` subset used by the cenc path:
/// a zero-padded 16-byte IV plus the optional subsample map.
pub struct MovEncSample {
  iv : FixedArray[Byte]
  subsamples : Array[MovSubSample]
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

///|
/// `av_clip64(x, -INT64_MAX, INT64_MAX)`: note the lower bound is
/// `-INT64_MAX`, not `INT64_MIN`, exactly as in `mov_build_index`.
fn mov_clip64(x : Int64) -> Int64 {
  if x > i64_max {
    i64_max
  } else if x < -i64_max {
    -i64_max
  } else {
    x
  }
}

///| `mov_stsc_index_valid`: `index < count - 1` (with the C unsigned wraparound). */
fn mov_stsc_index_valid(index : Int, count : Int) -> Bool {
  index < count - 1
}

///| 4CC equal to four characters, mirroring `MKTAG('a','b','c','d')`. */
fn tag(a : Char, b : Char, c : Char, d : Char) -> String {
  let chars : Array[Char] = [a, b, c, d]
  String::from_array(chars[:])
}

///| Saturating 64-bit addition (`av_sat_add64`). */
fn sat_add64(a : Int64, b : Int64) -> Int64 {
  if (a >= 0) == (b >= 0) {
    let r = a + b
    if (r >= 0) != (a >= 0) {
      if a >= 0 {
        i64_max
      } else {
        -9223372036854775808
      }
    } else {
      r
    }
  } else {
    a + b
  }
}

///| `av_rescale` for the edit-list conversion, delegating to the libavutil port. */
fn mov_rescale(a : Int64, b : UInt, c : UInt) -> Int64 {
  @libavutil.av_rescale(a, b.to_int64(), c.to_int64())
}

// ---------------------------------------------------------------------------
// Parser state and box traversal
// ---------------------------------------------------------------------------

priv struct MovState {
  movie : Mp4Movie
  mut cur : Mp4Track
  mut in_trak : Bool
  mut in_moof : Bool
  trex : Array[MovTrex]
  frag : MovFrag
}

///|
/// Dispatch one box to its parser, mirroring the `mov_default_parse_table`
/// lookup in `mov_read_default`. Unknown boxes are skipped, like the C
/// fall-through that skips unregistered leaf atoms.
fn parse_box(st : MovState, r : Mp4Reader, kind : String, size : Int64) -> Unit raise MovError {
  if kind == "trak" {
    parse_trak(st, r, size)
  } else if kind == "moof" {
    parse_moof(st, r, size)
  } else if kind == "moov" || kind == "mdia" || kind == "minf" || kind == "stbl" || kind == "edts" ||
    kind == "mvex" || kind == "traf" || kind == "sinf" || kind == "schi" {
    // Container boxes: recurse, as mov_read_moov/mdia/minf/stbl/edts/mvex/traf/sinf/schi do.
    parse_default(st, r, size)
  } else if kind == "tfhd" {
    parse_tfhd(st, r)
  } else if kind == "tfdt" {
    parse_tfdt(st, r)
  } else if kind == "trun" {
    parse_trun(st, r, size)
  } else if kind == "trex" {
    parse_trex(st, r)
  } else if kind == "schm" {
    parse_schm(st, r)
  } else if kind == "tenc" {
    parse_tenc(st, r, size)
  } else if kind == "senc" {
    parse_senc(st, r, size)
  } else if kind == "saiz" {
    parse_saiz(st, r)
  } else if kind == "saio" {
    parse_saio(st, r)
  } else if kind == "sidx" {
    parse_sidx(st, r, size)
  } else if kind == "ftyp" {
    parse_ftyp(st, r, size)
  } else if kind == "mvhd" {
    parse_mvhd(st, r)
  } else if kind == "tkhd" {
    parse_tkhd(st, r)
  } else if kind == "mdhd" {
    parse_mdhd(st, r)
  } else if kind == "hdlr" {
    parse_hdlr(st, r)
  } else if kind == "elst" {
    parse_elst(st, r, size)
  } else if kind == "stsd" {
    parse_stsd(st, r, size)
  } else if kind == "stts" {
    parse_stts(st, r, size)
  } else if kind == "ctts" {
    parse_ctts(st, r, size)
  } else if kind == "stsc" {
    parse_stsc(st, r, size)
  } else if kind == "stsz" {
    parse_stsz(st, r, size, false)
  } else if kind == "stz2" {
    parse_stsz(st, r, size, true)
  } else if kind == "stco" {
    parse_stco(st, r, size, false)
  } else if kind == "co64" {
    parse_stco(st, r, size, true)
  } else if kind == "stss" {
    parse_stss(st, r)
  } else if kind == "stps" {
    parse_stps(st, r)
  } else if kind == "esds" {
    parse_esds(st, r)
  } else if kind == "avcC" || kind == "hvcC" || kind == "av1C" || kind == "glbl" ||
    kind == "vvcC" || kind == "evcC" || kind == "lvcC" || kind == "apvC" {
    // mov_read_glbl: the whole payload becomes the codec extradata.
    parse_glbl(st, r, kind, size)
  } else {
    r.skip(size)
  }
}

///|
/// Walk the child boxes of a container whose payload is `parent_size` bytes.
/// Corresponds to `mov_read_default`.
///
/// `consumed` tracks the position within the parent, so the loop mirrors the
/// intent of the C `while (total_size <= atom.size - 8)` guard while also
/// terminating on the actual byte budget. The `trak`/`mdat`-outside-`moov`
/// diagnostic and the non-seekable early return are omitted.
fn parse_default(st : MovState, r : Mp4Reader, parent_size : Int64) -> Unit raise MovError {
  let mut consumed : Int64 = 0
  while consumed <= parent_size - 8 {
    let box_start = r.position().to_int64()
    let size32 = r.read_u32().to_int64()
    let kind = r.read_fourcc()
    if r.eof_reached() {
      break
    }
    let mut header : Int64 = 8
    let mut size = size32
    if size32 == 1 {
      // 64-bit extended size: `avio_rb64(pb) - 8` on top of the 8 bytes read.
      size = r.read_u64().reinterpret_as_int64()
      header = 16
    } else if size32 == 0 {
      // The box extends to the end of its parent.
      size = parent_size - consumed
    }
    // `a.size -= 8` in the C code: the payload excludes the whole header.
    let mut payload = size - header
    if payload < 0 {
      break
    }
    // `a.size = FFMIN(a.size, atom.size - total_size)`
    let avail = parent_size - consumed - header
    if payload > avail {
      payload = avail
    }
    if payload < 0 {
      break
    }
    parse_box(st, r, kind, payload)
    // Consume whatever the parser left behind, or rewind if it overread.
    let left = payload - (r.position().to_int64() - box_start - header)
    if left > 0 {
      r.skip(left)
    } else if left < 0 {
      r.skip(left)
    }
    consumed = consumed + header + payload
  }
}

// ---------------------------------------------------------------------------
// Individual box parsers
// ---------------------------------------------------------------------------

///|
/// `av_int2double` (libavutil/intfloat.h): reinterpret a big-endian-read
/// 64-bit pattern as an IEEE-754 double. Exact: every intermediate is a
/// power-of-two product that stays representable, and the mantissa (with the
/// implicit bit) is below 2^53.
fn mov_int2double(v : UInt64) -> Double {
  let neg = (v >> 63) == 1
  let exp = ((v >> 52) & 0x7FF).to_int()
  let mant = v & 0xFFFFFFFFFFFFF
  let mag : Double = if exp == 0 {
    // Subnormal (or zero): mant * 2^-1074.
    mant.to_double() * mov_pow2(-1074)
  } else if exp == 0x7FF {
    // Infinity / NaN: 2^1024 overflows to +inf, and inf/inf is NaN.
    if mant == 0 {
      mov_pow2(1024)
    } else {
      mov_pow2(1024) / mov_pow2(1024)
    }
  } else {
    (4503599627370496.0 + mant.to_double()) * mov_pow2(exp - 1075)
  }
  if neg { -mag } else { mag }
}

///| Exact `2^k` for -1074 <= k <= 1023, by squaring the base power. */
fn mov_pow2(k : Int) -> Double {
  let mut result = 1.0
  let mut base = if k < 0 { 0.5 } else { 2.0 }
  let mut e = if k < 0 { -k } else { k }
  while e > 0 {
    if (e & 1) == 1 {
      result = result * base
    }
    base = base * base
    e = e >> 1
  }
  result
}

///|
/// `mov_read_ftyp`: the major brand decides whether the file is treated as ISO
/// BMFF, and the compatible brands are collected for the QuickTime audio
/// sample-entry check in `mov_parse_stsd_audio`.
fn parse_ftyp(st : MovState, r : Mp4Reader, size : Int64) -> Unit {
  let major = r.read_fourcc()
  let _ = r.read_u32() // minor version
  st.movie.major_brand = major
  if major != tag('q', 't', ' ', ' ') {
    st.movie.isom = true
  }
  let brands : Array[Char] = []
  // The compatible-brand list fills the rest of the atom, 4 bytes per brand.
  let end = r.position() + (size - 8).to_int()
  while r.position() + 4 <= end {
    for i = 0; i < 4; i = i + 1 {
      brands.push(r.read_u8().to_byte().to_char())
    }
  }
  st.movie.compatible_brands = st.movie.compatible_brands + String::from_array(
      brands[:],
    )
}

///| `mov_read_mvhd`. */
fn parse_mvhd(st : MovState, r : Mp4Reader) -> Unit {
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  // creation and modification times (mov_metadata_creation_time)
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  let raw_ts = r.read_u32()
  st.movie.timescale = if raw_ts.reinterpret_as_int() <= 0 { 1 } else { raw_ts }
  st.movie.duration = if version == 1 {
    r.read_u64()
  } else {
    r.read_u32().to_uint64()
  }
}

///| `mov_read_mdhd`. */
fn parse_mdhd(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  if st.cur.timescale != 0 {
    raise InvalidData("multiple mdhd")
  }
  let version = r.read_u8()
  if version > 1 {
    raise InvalidData("unsupported mdhd version")
  }
  let _ = r.read_u24() // flags
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  let raw_ts = r.read_u32()
  if raw_ts.reinterpret_as_int() <= 0 {
    raise InvalidData("invalid mdhd time scale")
  }
  st.cur.timescale = raw_ts
  let dur = if version == 1 {
    r.read_u64()
  } else {
    r.read_u32().to_uint64()
  }
  let unknown = if version == 1 { u64_max } else { u32_max_u64 }
  st.cur.duration = if dur == unknown { 0 } else { dur }
  let _ = r.read_u16() // language
  let _ = r.read_u16() // quality
}

///| `mov_read_tkhd`. */
fn parse_tkhd(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  // Each trak has exactly one tkhd; `st->id` starts at -1 in mov_read_trak.
  if st.cur.track_id != 0 {
    raise InvalidData("duplicate tkhd")
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  if version == 1 {
    r.skip(16)
  } else {
    r.skip(8)
  }
  st.cur.track_id = r.read_u32()
  let _ = r.read_u32() // reserved
  if version == 1 {
    r.skip(8)
  } else {
    r.skip(4)
  }
  r.skip(8) // two reserved dwords
  r.skip(8) // layer, alternate group, volume, reserved
  r.skip(36) // 3x3 display matrix (16.16 / 2.30 fixed point)
  let width = r.read_u32()
  let height = r.read_u32()
  st.cur.width = width.reinterpret_as_int() >> 16
  st.cur.height = height.reinterpret_as_int() >> 16
}

///| `mov_read_hdlr`. */
fn parse_hdlr(st : MovState, r : Mp4Reader) -> Unit {
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let _ = r.read_fourcc() // component type ('mhlr'/'dhlr')
  let kind = r.read_fourcc() // component subtype
  if !st.in_trak {
    return
  }
  // Only the media handlers are recognised; an unrecognised one (e.g. the
  // 'url ' data handler QuickTime puts in minf) leaves the stream untouched,
  // exactly as in the C.
  if kind == tag('v', 'i', 'd', 'e') {
    st.cur.handler = kind
    st.cur.media_type = Mp4MediaType::Video
  } else if kind == tag('s', 'o', 'u', 'n') {
    st.cur.handler = kind
    st.cur.media_type = Mp4MediaType::Audio
  } else if kind == tag('s', 'u', 'b', 'p') || kind == tag('c', 'l', 'c', 'p') {
    st.cur.handler = kind
    st.cur.media_type = Mp4MediaType::Subtitle
  }
}

///| `mov_read_elst`. */
fn parse_elst(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let entry_size : Int64 = if version == 1 { 20 } else { 12 }
  let mut remaining = size - 8
  let declared = r.read_u32().reinterpret_as_int()
  let mut edit_count = declared
  if remaining != declared.to_int64() * entry_size {
    // Non-strict compliance: derive the entry count from the atom size.
    edit_count = (remaining / entry_size).to_int()
  }
  for i = 0; i < edit_count; i = i + 1 {
    if remaining <= 0 || r.eof_reached() {
      break
    }
    let duration : Int64 = if version == 1 {
      r.read_i64()
    } else {
      r.read_u32().to_int64()
    }
    let time : Int64 = if version == 1 {
      r.read_i64()
    } else {
      r.read_u32().reinterpret_as_int().to_int64()
    }
    remaining = remaining - (if version == 1 { 16 } else { 8 })
    let rate = r.read_u32().to_double() / 65536.0
    remaining = remaining - 4
    if duration < 0 {
      raise InvalidData("invalid edit list duration")
    }
    st.cur.elst.push({ duration, time, rate })
  }
}

///|
/// `mov_read_stsd`, embedding the sample-entry layouts of
/// `mov_parse_stsd_video` and `mov_parse_stsd_audio`.
fn parse_stsd(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 || entries.to_int64() > size / 8 || entries > 1024 {
    raise InvalidData("invalid STSD entries")
  }
  st.cur.stsd_version = version
  // Only the primary sample description is modelled; the rest are skipped the
  // way `mov_skip_multiple_stsd` skips non-primary entries.
  let entry_start = r.position().to_int64()
  let entry_size = r.read_u32().to_int64()
  let format = r.read_fourcc()
  if entry_size >= 16 {
    let _ = r.read_u32() // reserved
    let _ = r.read_u16() // reserved
    let _ = r.read_u16() // dref_id
  } else if entry_size <= 7 {
    raise InvalidData("invalid size in stsd")
  }
  st.cur.codec = format
  if media_is_video(st.cur.media_type) {
    parse_stsd_video(st, r)
  } else if media_is_audio(st.cur.media_type) {
    parse_stsd_audio(st, r)
  }
  // Parse the child boxes of the sample entry (`sinf`/`avcC`/`esds`/`wave`/...);
  // unknown boxes are skipped by parse_box. This is what lets `sinf`/`schm`/
  // `tenc` inside an encrypted sample entry be seen.
  let used = r.position().to_int64() - entry_start
  if entry_size > used {
    let child_size = entry_size - used
    let child_start = r.position()
    parse_default(st, r, child_size)
    let consumed = r.position() - child_start
    if consumed < child_size.to_int() {
      r.skip((child_size - consumed.to_int64()))
    }
  }
  for i = 1; i < entries; i = i + 1 {
    let s = r.read_u32().to_int64()
    if s < 8 {
      break
    }
    r.skip(s - 4)
  }
}

///| `mov_parse_stsd_video`: VisualSampleEntry fields (the 16 header bytes are already read). */
fn parse_stsd_video(st : MovState, r : Mp4Reader) -> Unit {
  if st.movie.isom {
    r.skip(4) // pre_defined
    r.skip(12) // pre_defined
  } else {
    let _ = r.read_u16() // version
    let _ = r.read_u16() // revision level
    let _ = r.read_le32() // vendor
    let _ = r.read_u32() // temporal quality
    let _ = r.read_u32() // spatial quality
  }
  st.cur.width = r.read_u16().reinterpret_as_int()
  st.cur.height = r.read_u16().reinterpret_as_int()
  let _ = r.read_u32() // horiz resolution
  let _ = r.read_u32() // vert resolution
  let _ = r.read_u32() // data size, always 0
  let _ = r.read_u16() // frames per sample
  let mut len = r.read_u8().reinterpret_as_int()
  if len > 31 {
    len = 31
  }
  let chars : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    chars.push(r.read_u8().to_byte().to_char())
  }
  st.cur.encoder = String::from_array(chars[:])
  if len < 31 {
    r.skip((31 - len).to_int64())
  }
  st.cur.bits_per_sample = r.read_u16() // depth
  // ISO VisualSampleEntry ends with `pre_defined = -1` (QuickTime writes
  // `color_table_id` here); the child boxes (avcC/esds/sinf/...) follow it.
  r.skip(2)
}

///|
/// `mov_parse_stsd_audio`: AudioSampleEntry fields (the 16 header bytes are
/// already read), including the QuickTime version 1/2 extension that carries
/// the PCM packing (`samples_per_frame`/`bytes_per_frame`) needed by the
/// chunked audio index path, and the codec-specific packing defaults
/// (`av_get_bits_per_sample` for the PCM fourccs).
fn parse_stsd_audio(st : MovState, r : Mp4Reader) -> Unit {
  let version = r.read_u16()
  if st.movie.isom {
    r.skip(6) // reserved
  } else {
    let _ = r.read_u16() // revision level
    let _ = r.read_le32() // vendor
  }
  st.cur.channels = r.read_u16()
  st.cur.bits_per_sample = r.read_u16()
  st.cur.audio_cid = r.read_u16().reinterpret_as_int()
  let _ = r.read_u16() // packet size
  st.cur.sample_rate = r.read_u32() >> 16
  // Read the QT version 1/2 fields; in version 0 these do not exist. The C
  // also honours a "qt  " compatible brand inside an ISO file.
  let qt = st.movie.compatible_brands.contains("qt  ")
  if !st.movie.isom || qt || (st.cur.stsd_version == 0 && version > 0) {
    if version == 1 {
      st.cur.samples_per_frame = r.read_u32()
      let _ = r.read_u32() // bytes per packet
      st.cur.bytes_per_frame = r.read_u32()
      let _ = r.read_u32() // bytes per sample
    } else if version == 2 {
      let _ = r.read_u32() // sizeof struct only
      st.cur.sample_rate = mov_int2double(r.read_u64()).to_int().reinterpret_as_uint()
      st.cur.channels = r.read_u32()
      let _ = r.read_u32() // always 0x7F000000
      st.cur.bits_per_sample = r.read_u32()
      let _ = r.read_u32() // lpcm format specific flag
      st.cur.bytes_per_frame = r.read_u32()
      st.cur.samples_per_frame = r.read_u32()
    }
  }
  // Codec-specific packing defaults for the QuickTime codecs whose frame
  // packing is not in the sample entry (mov_parse_stsd_audio's switch).
  match st.cur.codec {
    "MAC3" => {
      st.cur.samples_per_frame = 6
      st.cur.bytes_per_frame = 2 * st.cur.channels
    }
    "MAC6" => {
      st.cur.samples_per_frame = 6
      st.cur.bytes_per_frame = 1 * st.cur.channels
    }
    "ima4" => {
      st.cur.samples_per_frame = 64
      st.cur.bytes_per_frame = 34 * st.cur.channels
    }
    "agsm" => {
      st.cur.samples_per_frame = 160
      st.cur.bytes_per_frame = 33
    }
    _ => ()
  }
  // `av_get_bits_per_sample` for the PCM fourccs: the canonical sample size
  // overrides the entry's declared depth, and yields sc->sample_size (bytes
  // per sample times channel count). For the 16-bit entries an 8/24/32-bit
  // depth promotes the codec (S8/S24/S32), keeping the declared size.
  let bps = match st.cur.codec {
    "sowt" | "twos" =>
      if st.cur.bits_per_sample == 8 ||
        st.cur.bits_per_sample == 24 ||
        st.cur.bits_per_sample == 32 {
        st.cur.bits_per_sample
      } else {
        16
      }
    "raw " => 8
    "in24" => 24
    "in32" => 32
    "fl32" => 32
    "fl64" => 64
    _ => 0
  }
  if bps != 0 && (bps / 8) * st.cur.channels <= 4294967295 {
    st.cur.bits_per_sample = bps
    if st.cur.sample_size == 0 {
      // `sc->sample_size`: do not overwrite a value computed above.
      st.cur.sample_size = (bps / 8) * st.cur.channels
    }
  }
}

///| `mov_read_stts`, including the `max_stts_delta` clipping and DTS drift correction. */
fn parse_stts(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  // Corrupt counts are rejected up front; the C code relies on allocation
  // failure instead.
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid STTS entries")
  }
  let mut corrected_dts : Int64 = 0
  let mut current_dts : Int64 = 0
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let sample_count = r.read_u32()
    let sample_duration = r.read_u32()
    let mut duration = sample_duration
    if sample_duration > max_stts_delta {
      // A huge delta is assumed to be a negative correction cast to uint32.
      let delta_magnitude = sample_duration.reinterpret_as_int()
      duration = 1
      let inc = (if delta_magnitude < 0 {
        delta_magnitude.to_int64()
      } else {
        1
      }) * sample_count.to_int64()
      corrected_dts = sat_add64(corrected_dts, inc)
    } else {
      corrected_dts = sat_add64(
        corrected_dts,
        sample_duration.to_int64() * sample_count.to_int64(),
      )
    }
    current_dts = current_dts + duration.to_int64() * sample_count.to_int64()
    if current_dts > corrected_dts {
      let divisor = if sample_count.reinterpret_as_int() > 1 {
        sample_count.to_int64()
      } else {
        1
      }
      let drift = (current_dts - corrected_dts) / divisor
      let correction = if duration.to_int64() > drift {
        drift
      } else {
        duration.to_int64() - 1
      }
      current_dts = current_dts - correction * sample_count.to_int64()
      duration = (duration.to_int64() - correction).reinterpret_as_uint64().to_uint()
    }
    st.cur.stts.push({ count: sample_count.reinterpret_as_int(), duration })
  }
  // `st->duration = FFMIN(st->duration, duration)` and `sc->track_end =
  // duration`: the stts total caps the mdhd duration and seeds the track end
  // used by later fragments without tfdt.
  let mut total : Int64 = 0
  for i = 0; i < st.cur.stts.length(); i = i + 1 {
    let e = st.cur.stts[i]
    total = total + e.duration.to_int64() * e.count.to_int64()
  }
  if total != 0 && total.reinterpret_as_uint64() < st.cur.duration {
    st.cur.duration = total.reinterpret_as_uint64()
  }
  st.cur.track_end = total
}

///| `mov_read_ctts`: per-entry presentation offsets, plus the `dts_shift` they imply. */
fn parse_ctts(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid CTTS entries")
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let count = r.read_u32().reinterpret_as_int()
    let offset = r.read_u32().reinterpret_as_int()
    if count <= 0 {
      continue
    }
    st.cur.ctts.push({ count, offset })
    // Any entry but the last: a negative offset forces an index-wide DTS shift
    // (mov_update_dts_shift).
    if i + 2 < entries && offset < 0 {
      let shift = -offset
      if shift > st.cur.dts_shift {
        st.cur.dts_shift = shift
      }
    }
  }
}

///| `mov_read_stsc`, including the validation pass that repairs corrupt tables. */
fn parse_stsc(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries.to_int64() * 12 + 4 > size {
    raise InvalidData("invalid STSC size")
  }
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    let first = r.read_u32().reinterpret_as_int()
    let count = r.read_u32().reinterpret_as_int()
    let id = r.read_u32().reinterpret_as_int()
    st.cur.stsc.push({ first, count, id })
  }
  // Validity pass, walking backwards exactly like the C loop.
  let mut i = st.cur.stsc.length() - 1
  while i >= 0 {
    let first_min = i.to_int64() + 1
    let e = st.cur.stsc[i]
    let forward_bad = i + 1 < st.cur.stsc.length() && e.first >= st.cur.stsc[i + 1].first
    let backward_bad = i > 0 && e.first <= st.cur.stsc[i - 1].first
    if forward_bad || backward_bad || e.first.to_int64() < first_min || e.count < 1 || e.id < 1 {
      if i + 1 >= st.cur.stsc.length() {
        if e.count == 0 && i > 0 {
          // Drop a trailing zero-count entry.
          let _ = st.cur.stsc.pop()
          i = i - 1
          continue
        }
        let mut first = if e.first.to_int64() > first_min {
          e.first
        } else {
          first_min.to_int()
        }
        if i > 0 && first <= st.cur.stsc[i - 1].first {
          first = st.cur.stsc[i - 1].first + 1
        }
        let count = if e.count > 1 { e.count } else { 1 }
        let id = if e.id > 1 { e.id } else { 1 }
        st.cur.stsc[i] = { first, count, id }
      } else {
        // Replace this entry by the next valid one.
        st.cur.stsc[i] = {
          first: st.cur.stsc[i + 1].first - 1,
          count: st.cur.stsc[i + 1].count,
          id: st.cur.stsc[i + 1].id,
        }
      }
    }
    i = i - 1
  }
}

///| `mov_read_stsz` / `mov_read_stz2`. */
fn parse_stsz(
  st : MovState,
  r : Mp4Reader,
  size : Int64,
  stz2 : Bool
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let mut sample_size : UInt = 0
  let mut field_size = 32
  if !stz2 {
    sample_size = r.read_u32()
    if st.cur.sample_size == 0 {
      st.cur.sample_size = sample_size
    }
    st.cur.stsz_sample_size = sample_size
  } else {
    let _ = r.read_u24() // reserved
    field_size = r.read_u8().reinterpret_as_int()
  }
  let entries = r.read_u32().reinterpret_as_int()
  if entries < 0 {
    raise InvalidData("invalid STSZ entries")
  }
  st.cur.sample_count = entries
  if sample_size != 0 {
    // Constant sample size: no per-sample table follows.
    return
  }
  if field_size != 4 && field_size != 8 && field_size != 16 && field_size != 32 {
    raise InvalidData("invalid sample field size")
  }
  if entries == 0 {
    return
  }
  if entries.to_int64() * field_size.to_int64() > (size - 12) * 8 {
    raise InvalidData("STSZ atom truncated")
  }
  // `get_bits_long(&gb, field_size)` is an MSB-first bit reader; reproduce it so
  // that 4-bit (stz2) fields pack two samples per byte.
  let base = r.position()
  let mut bitpos = 0
  for i = 0; i < entries; i = i + 1 {
    let mut v : UInt = 0
    for b = 0; b < field_size; b = b + 1 {
      let shift = 7 - bitpos % 8
      let bit = (r.peek_u8_at(base + bitpos / 8) >> shift) & 1
      v = (v << 1) | bit
      bitpos = bitpos + 1
    }
    st.cur.sample_sizes.push(v)
  }
  r.skip((bitpos / 8).to_int64())
}

///| `mov_read_stco` / `mov_read_co64`. */
fn parse_stco(
  st : MovState,
  r : Mp4Reader,
  size : Int64,
  co64 : Bool
) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let raw_entries = r.read_u32()
  let entry_size : Int64 = if co64 { 8 } else { 4 }
  // Clamp the declared count to what the atom can hold, as mov_read_stco does.
  let cap0 : Int64 = (size - 8) / entry_size
  let cap : Int64 = if cap0 < 0 { 0L } else { cap0 }
  let raw : Int64 = raw_entries.reinterpret_as_int().to_int64()
  let entries : Int = if raw < cap { raw.to_int() } else { cap.to_int() }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    if co64 {
      let off = r.read_i64()
      // An impossible (negative) chunk offset is clamped to 0, as in the C code.
      st.cur.chunk_offsets.push(if off < 0 { 0 } else { off })
    } else {
      st.cur.chunk_offsets.push(r.read_u32().to_int64())
    }
  }
}

///| `mov_read_stss`: sync-sample (keyframe) table. */
fn parse_stss(st : MovState, r : Mp4Reader) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 {
    // An empty stss means every sample is a sync sample.
    st.cur.keyframe_absent = true
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    st.cur.keyframes.push(r.read_u32())
  }
}

///| `mov_read_stps`: partial-sync (open-GOP) sample table. */
fn parse_stps(st : MovState, r : Mp4Reader) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u32() // version + flags
  let entries = r.read_u32().reinterpret_as_int()
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.eof_reached() {
      break
    }
    st.cur.stps.push(r.read_u32())
  }
}

///| `mov_read_trak`: parse one track's boxes, then build its sample index. */
fn parse_trak(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  st.in_trak = true
  st.cur = new_track()
  parse_default(st, r, size)
  st.in_trak = false
  mov_build_index(st, st.cur)
  st.movie.tracks.push(st.cur)
}

// ---------------------------------------------------------------------------
// Fragmented MP4 (moof / traf / tfhd / tfdt / trun / trex)
// ---------------------------------------------------------------------------

///| Look up a track by `track_id`, as mov_read_tfdt/trun do. */
fn mov_find_track(st : MovState, id : UInt) -> Mp4Track? {
  for i = 0; i < st.movie.tracks.length(); i = i + 1 {
    if st.movie.tracks[i].track_id == id {
      return Some(st.movie.tracks[i])
    }
  }
  None
}

///|
/// `mov_update_dts_shift`: a negative CTS offset raises the stream-wide
/// `dts_shift` so that presentation timestamps stay non-negative.
fn mov_update_dts_shift(track : Mp4Track, duration : Int) -> Unit {
  if duration < 0 {
    let d : Int64 = duration.to_int64()
    let mag : Int64 = if d == -2147483648 { 2147483647 } else { -d }
    if mag.to_int() > track.dts_shift {
      track.dts_shift = mag.to_int()
    }
  }
}

///| `mov_read_trex`: one track's fragment defaults. */
fn parse_trex(st : MovState, r : Mp4Reader) -> Unit {
  let _ = r.read_u8() // version
  let _ = r.read_u24() // flags
  let track_id = r.read_u32()
  let _ = r.read_u32() // stsd_id (primary description only in this slice)
  let duration = r.read_u32()
  let size = r.read_u32()
  let flags = r.read_u32()
  st.trex.push({ track_id, duration, size, flags })
}

///| `mov_read_moof`: reset fragment state and recurse into `traf`. */
fn parse_moof(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  st.frag.found_tfhd = false
  st.frag.has_tfdt = false
  let off = r.position().to_int64() - 8
  st.frag.moof_offset = off
  st.frag.implicit_offset = off
  // While inside a moof, encryption boxes target the fragment's track
  // (get_current_encryption_info's frag_index.current path).
  st.in_moof = true
  parse_default(st, r, size)
  st.in_moof = false
}

///| `mov_read_tfhd`: track fragment header; merges `trex` defaults. */
fn parse_tfhd(st : MovState, r : Mp4Reader) -> Unit {
  let _ = r.read_u8() // version
  let flags = r.read_u24()
  let track_id = r.read_u32()
  if track_id == 0 {
    return
  }
  let mut trex_opt : MovTrex? = None
  for i = 0; i < st.trex.length(); i = i + 1 {
    if st.trex[i].track_id == track_id {
      trex_opt = Some(st.trex[i])
    }
  }
  match trex_opt {
    None => ()
    Some(trex) => {
      st.frag.found_tfhd = true
      st.frag.track_id = track_id
      st.frag.base_data_offset = if (flags & tfhd_base_data_offset) != 0 {
        r.read_u64().reinterpret_as_int64()
      } else if (flags & tfhd_default_base_is_moof) != 0 {
        st.frag.moof_offset
      } else {
        st.frag.implicit_offset
      }
      if (flags & tfhd_stsd_id) != 0 {
        let _ = r.read_u32() // stsd_id (primary description only in this slice)
      }
      st.frag.duration = if (flags & tfhd_default_duration) != 0 {
        r.read_u32()
      } else {
        trex.duration
      }
      st.frag.size = if (flags & tfhd_default_size) != 0 {
        r.read_u32()
      } else {
        trex.size
      }
      st.frag.flags = if (flags & tfhd_default_flags) != 0 {
        r.read_u32()
      } else {
        trex.flags
      }
    }
  }
}

///| `mov_read_tfdt`: base media decode time for the current track fragment. */
fn parse_tfdt(st : MovState, r : Mp4Reader) -> Unit {
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let bmdt : Int64 = if version != 0 {
    r.read_u64().reinterpret_as_int64()
  } else {
    r.read_u32().to_int64()
  }
  st.frag.tfdt = bmdt
  st.frag.has_tfdt = true
  match mov_find_track(st, st.frag.track_id) {
    Some(track) => track.track_end = bmdt
    None => ()
  }
}

///|
/// `mov_read_trun`: append one track fragment's samples to the matching track,
/// mirroring the sample-index construction of the C code (DTS from tfdt/track
/// end, per-sample duration/size/flags/CTS, keyframe from the fragment flags).
fn parse_trun(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  if !st.frag.found_tfhd {
    raise InvalidData("trun without tfhd")
  }
  match mov_find_track(st, st.frag.track_id) {
    None => ()
    Some(track) => {
      let _ = r.read_u8() // version
      let flags = r.read_u24()
      let mut entries = r.read_u32().reinterpret_as_int()
      let mut data_offset : Int = 0
      if (flags & trun_data_offset) != 0 {
        data_offset = r.read_u32().reinterpret_as_int()
      }
      let mut first_sample_flags = st.frag.flags
      if (flags & trun_first_sample_flags) != 0 {
        first_sample_flags = r.read_u32()
      }
      // Bound the entry count to what the atom can still hold.
      let opt_bytes = (if (flags & trun_data_offset) != 0 { 4 } else { 0 }) +
        (if (flags & trun_first_sample_flags) != 0 { 4 } else { 0 })
      let entry_size = (if (flags & trun_sample_duration) != 0 { 4 } else { 0 }) +
        (if (flags & trun_sample_size) != 0 { 4 } else { 0 }) +
        (if (flags & trun_sample_flags) != 0 { 4 } else { 0 }) +
        (if (flags & trun_sample_cts) != 0 { 4 } else { 0 })
      if entry_size > 0 {
        let left = size - 8 - opt_bytes.to_int64()
        let max_entries = if left < 0 { 0L } else { left / entry_size.to_int64() }
        if entries.to_int64() > max_entries {
          entries = max_entries.to_int()
        }
      }
      if entries == 0 {
        // `if (entries == 0) return 0;` before any state is touched.
        return
      }
      if (flags & trun_sample_cts) != 0 {
        track.has_ctts = true
      }
      let has_ctts = track.has_ctts
      // DTS base: tfdt when present, else the fragment's sidx earliest
      // presentation time (used raw, without the time_offset shift, exactly
      // as the C FIXME documents), else the accumulated track end.
      let base_dts = if st.frag.has_tfdt {
        st.frag.tfdt - track.time_offset
      } else {
        match mov_sidx_lookup(st, st.frag.moof_offset, st.frag.track_id) {
          Some(sidx_pts) => sidx_pts
          None => track.track_end - track.time_offset
        }
      }
      let mut dts = base_dts
      // `prev_dts`: the DTS of the last sample before this trun; samples at
      // or before it overlap earlier fragments and are flagged for discard.
      let prev_dts : Int64? = if track.samples.length() > 0 {
        Some(track.samples[track.samples.length() - 1].dts)
      } else {
        None
      }
      let mut offset = st.frag.base_data_offset + data_offset.to_int64()
      let mut distance : UInt = 0
      for i = 0; i < entries; i = i + 1 {
        if r.eof_reached() {
          break
        }
        let mut sample_size = st.frag.size
        let mut sample_flags = if i != 0 { st.frag.flags } else { first_sample_flags }
        let mut sample_duration = st.frag.duration
        let mut ctts : Int = 0
        if (flags & trun_sample_duration) != 0 {
          sample_duration = r.read_u32()
        }
        if (flags & trun_sample_size) != 0 {
          sample_size = r.read_u32()
        }
        if (flags & trun_sample_flags) != 0 {
          sample_flags = r.read_u32()
        }
        if (flags & trun_sample_cts) != 0 {
          ctts = r.read_u32().reinterpret_as_int()
        }
        mov_update_dts_shift(track, ctts)
        let keyframe = (sample_flags &
          (frag_sample_flag_is_non_sync | frag_sample_flag_depends_yes)) == 0
        if keyframe {
          distance = 0
        }
        let pts = if has_ctts {
          dts + track.dts_shift.to_int64() + ctts.to_int64()
        } else {
          dts
        }
        let discard = match prev_dts {
          Some(v) => v >= dts
          None => false
        }
        track.samples.push({
          offset,
          size: sample_size,
          dts,
          pts,
          duration: sample_duration,
          keyframe,
          min_distance: distance,
          discard,
        })
        distance = distance + 1
        dts = dts + sample_duration.to_int64()
        offset = offset + sample_size.to_int64()
        if sample_size == 0 {
          raise InvalidData("zero sample size in trun")
        }
      }
      st.frag.implicit_offset = offset
      track.track_end = dts + track.time_offset
      if track.track_end >= 0 &&
        track.track_end.reinterpret_as_uint64() > track.duration {
        track.duration = track.track_end.reinterpret_as_uint64()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Encryption (cenc / sinf / schm / tenc / senc)
// ---------------------------------------------------------------------------

///| `mov_read_schm`: the protection scheme fourcc. */
fn parse_schm(st : MovState, r : Mp4Reader) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.read_u32() // version and flags
  st.cur.cenc_scheme = r.read_u32()
}

///| `mov_read_tenc`: pattern, per-sample IV size, default KID and constant IV. */
fn parse_tenc(st : MovState, r : Mp4Reader, size : Int64) -> Unit {
  if !st.in_trak {
    return
  }
  if size < 20 {
    return
  }
  let version = r.read_u8()
  let _ = r.read_u24() // flags
  let _ = r.read_u8() // reserved
  let pattern = r.read_u8()
  if version > 0 {
    st.cur.cenc_crypt_byte_block = pattern >> 4
    st.cur.cenc_skip_byte_block = pattern & 0xF
  }
  let is_protected = r.read_u8()
  let iv_size = r.read_u8().reinterpret_as_int()
  st.cur.cenc_per_sample_iv_size = iv_size
  for i = 0; i < 16; i = i + 1 {
    // Default key ID; not needed when the key is supplied directly.
    let _ = r.read_u8()
  }
  if is_protected != 0 && iv_size == 0 {
    let constant_size = r.read_u8().reinterpret_as_int()
    let iv = FixedArray::make(16, b'\x00')
    let n = if constant_size < 16 { constant_size } else { 16 }
    for i = 0; i < n; i = i + 1 {
      iv[i] = r.read_u8().to_byte()
    }
    st.cur.cenc_default_iv = iv
  }
}

///|
/// `get_current_encryption_info`'s track selection: inside a moof the boxes
/// apply to the fragment's track; inside a trak to that track; otherwise (the
/// stream-level `saiz`/`saio`/`senc` placed directly under `moov`) to the
/// most recently created track. A track is a valid target only if encryption
/// metadata was seen (`schm`/`tenc`, proxying the C's
/// `default_encrypted_sample` check).
fn current_enc_track(st : MovState) -> Mp4Track? {
  let track = if st.in_moof {
    if !st.frag.found_tfhd {
      return None
    }
    mov_find_track(st, st.frag.track_id)
  } else if st.in_trak {
    Some(st.cur)
  } else if st.movie.tracks.length() > 0 {
    Some(st.movie.tracks[st.movie.tracks.length() - 1])
  } else {
    None
  }
  match track {
    Some(t) => if t.cenc_scheme != 0 { Some(t) } else { None }
    None => None
  }
}

///|
/// `mov_read_senc`: per-sample IVs (and optional subsample maps). Each entry
/// is stored positionally so it lines up with the track's sample index; for a
/// fragmented file the entries of every fragment append after the previous
/// ones, matching how `trun` appends the samples themselves.
fn parse_senc(st : MovState, r : Mp4Reader, size : Int64) -> Unit raise MovError {
  match current_enc_track(st) {
    None => ()
    Some(track) => {
      let _ = size
      let _ = r.read_u8() // version
      let flags = r.read_u24()
      let use_subsamples = (flags & 0x02) != 0
      let sample_count = r.read_u32().reinterpret_as_int()
      let per_iv = track.cenc_per_sample_iv_size
      for i = 0; i < sample_count; i = i + 1 {
        if r.eof_reached() {
          raise InvalidData("EOF in senc")
        }
        if per_iv != 0 || use_subsamples {
          let iv = FixedArray::make(16, b'\x00')
          if per_iv != 0 {
            for k = 0; k < per_iv; k = k + 1 {
              iv[k] = r.read_u8().to_byte()
            }
          }
          let subs : Array[MovSubSample] = []
          if use_subsamples {
            let n = r.read_u16().reinterpret_as_int()
            for k = 0; k < n; k = k + 1 {
              if r.eof_reached() {
                raise InvalidData("EOF in senc subsamples")
              }
              let clear = r.read_u16().reinterpret_as_int()
              let prot = r.read_u32().reinterpret_as_int()
              subs.push({ bytes_of_clear: clear, bytes_of_protected: prot })
            }
          }
          track.cenc_samples.push(Some({ iv, subsamples: subs }))
        } else {
          track.cenc_samples.push(None)
        }
      }
    }
  }
}

///|
/// `mov_read_sample_encryption_info` as used by `mov_parse_auxiliary_info`:
/// one auxiliary-info entry (IV plus optional subsamples; `use_subsamples`
/// is decided by the caller from the entry size).
fn read_sample_encryption_info(
  r : Mp4Reader,
  per_iv : Int,
  use_subsamples : Bool
) -> MovEncSample {
  let iv = FixedArray::make(16, b'\x00')
  if per_iv != 0 {
    for k = 0; k < per_iv; k = k + 1 {
      iv[k] = r.read_u8().to_byte()
    }
  }
  let subs : Array[MovSubSample] = []
  if use_subsamples {
    let n = r.read_u16().reinterpret_as_int()
    for k = 0; k < n; k = k + 1 {
      let clear = r.read_u16().reinterpret_as_int()
      let prot = r.read_u32().reinterpret_as_int()
      subs.push({ bytes_of_clear: clear, bytes_of_protected: prot })
    }
  }
  { iv, subsamples: subs }
}

///|
/// `mov_parse_auxiliary_info`: with both `saiz` and `saio` present, read the
/// per-sample encryption info from the auxiliary chunk. The reader position
/// is restored afterwards, as the C does with `prev_pos`.
fn mov_parse_auxiliary_info(
  track : Mp4Track,
  r : Mp4Reader
) -> Unit raise MovError {
  if track.cenc_samples.length() > 0 {
    return
  }
  let sample_count = track.aux_info_sample_count
  if track.aux_info_offsets.length() != 1 {
    raise InvalidData("multiple auxiliary info chunks unsupported")
  }
  let prev_pos = r.position()
  r.seek(track.aux_info_offsets[0].to_int())
  for i = 0; i < sample_count && !r.eof_reached(); i = i + 1 {
    let info_size = if track.aux_info_default_size != 0 {
      track.aux_info_default_size
    } else {
      track.aux_info_sizes[i].reinterpret_as_int()
    }
    let use_subsamples = info_size > track.cenc_per_sample_iv_size
    let e = read_sample_encryption_info(
      r,
      track.cenc_per_sample_iv_size,
      use_subsamples,
    )
    track.cenc_samples.push(Some(e))
  }
  if r.eof_reached() {
    raise InvalidData("EOF in auxiliary info")
  }
  r.seek(prev_pos)
}

///|
/// `mov_read_saiz`: per-sample sizes of the auxiliary info chunk. The
/// `aux_info_type` filtering of the C reduces here to accepting the box only
/// when the track already carries encryption metadata.
fn parse_saiz(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  match current_enc_track(st) {
    None => ()
    Some(track) => {
      if track.cenc_samples.length() > 0 {
        // Both saio/saiz and senc present: the senc data wins.
        return
      }
      if track.aux_info_sample_count != 0 {
        raise InvalidData("duplicate saiz")
      }
      let _ = r.read_u8() // version
      let flags = r.read_u24()
      if (flags & 0x01) != 0 {
        let _ = r.read_u32() // aux_info_type
        let _ = r.read_u32() // aux_info_type_parameter
      }
      track.aux_info_default_size = r.read_u8().reinterpret_as_int()
      let sample_count = r.read_u32().reinterpret_as_int()
      if track.aux_info_default_size == 0 {
        if sample_count == 0 {
          raise InvalidData("saiz without sizes")
        }
        for i = 0; i < sample_count; i = i + 1 {
          track.aux_info_sizes.push(r.read_u8())
        }
      }
      track.aux_info_sample_count = sample_count
      if track.aux_info_offsets.length() > 0 {
        mov_parse_auxiliary_info(track, r)
      }
    }
  }
}

///|
/// `mov_read_saio`: absolute offsets of the auxiliary info chunks. Inside a
/// moof they are relative to the fragment's base data offset.
fn parse_saio(st : MovState, r : Mp4Reader) -> Unit raise MovError {
  match current_enc_track(st) {
    None => ()
    Some(track) => {
      if track.cenc_samples.length() > 0 {
        return
      }
      if track.aux_info_offsets.length() > 0 {
        raise InvalidData("duplicate saio")
      }
      let version = r.read_u8().reinterpret_as_int()
      let flags = r.read_u24()
      if (flags & 0x01) != 0 {
        let _ = r.read_u32() // aux_info_type
        let _ = r.read_u32() // aux_info_type_parameter
      }
      let entry_count = r.read_u32().reinterpret_as_int()
      for i = 0; i < entry_count && !r.eof_reached(); i = i + 1 {
        let off = if version == 0 {
          r.read_u32().to_int64()
        } else {
          r.read_i64()
        }
        let abs = if st.in_moof { off + st.frag.base_data_offset } else { off }
        track.aux_info_offsets.push(abs)
      }
      if r.eof_reached() {
        raise InvalidData("EOF in saio")
      }
      if track.aux_info_sample_count > 0 {
        mov_parse_auxiliary_info(track, r)
      }
    }
  }
}

///|
/// `cenc_scheme_decrypt`: AES-CTR over the whole sample or over each protected
/// subrange (the keystream keeps advancing across subranges).
fn cenc_ctr_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  out : Array[Byte],
  size : Int
) -> Result[Unit, String] {
  let ctx = @libavutil.av_aes_ctr_alloc()
  match @libavutil.av_aes_ctr_init(ctx, key) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  @libavutil.av_aes_ctr_set_full_iv(ctx, Bytes::from_array(iv[:]))
  if subs.length() == 0 {
    let enc = @libavutil.av_aes_ctr_crypt(ctx, Bytes::from_array(out[:]), size)
    for i = 0; i < size; i = i + 1 {
      out[i] = enc[i]
    }
    return Ok(())
  }
  let mut pos = 0
  for i = 0; i < subs.length(); i = i + 1 {
    let clear = subs[i].bytes_of_clear
    let prot = subs[i].bytes_of_protected
    if clear + prot > size - pos {
      return Err("subsample exceeds packet")
    }
    pos = pos + clear
    let enc = @libavutil.av_aes_ctr_crypt(
      ctx,
      Bytes::from_array(out[pos:pos + prot]),
      prot,
    )
    for j = 0; j < prot; j = j + 1 {
      out[pos + j] = enc[j]
    }
    pos = pos + prot
  }
  if pos != size {
    return Err("leftover packet bytes")
  }
  Ok(())
}

///|
/// `cbc1_scheme_decrypt`: AES-CBC over whole 16-byte blocks, IV chained across
/// subranges via a single running `iv` buffer.
fn cenc_cbc_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  out : Array[Byte],
  size : Int
) -> Result[Unit, String] {
  let aes = @libavutil.av_aes_alloc()
  match @libavutil.av_aes_init(aes, key, 128, true) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let ivbuf : FixedArray[Byte] = iv.copy()
  if subs.length() == 0 {
    let blocks = size / 16
    let dec = @libavutil.av_aes_crypt(aes, Bytes::from_array(out[:]), blocks, Some(ivbuf))
    for i = 0; i < blocks * 16; i = i + 1 {
      out[i] = dec[i]
    }
    return Ok(())
  }
  let mut pos = 0
  for i = 0; i < subs.length(); i = i + 1 {
    let clear = subs[i].bytes_of_clear
    let prot = subs[i].bytes_of_protected
    if clear + prot > size - pos {
      return Err("subsample exceeds packet")
    }
    if prot % 16 != 0 {
      return Err("subsample not a multiple of 16")
    }
    pos = pos + clear
    let blocks = prot / 16
    if blocks > 0 {
      let dec = @libavutil.av_aes_crypt(
        aes,
        Bytes::from_array(out[pos:pos + prot]),
        blocks,
        Some(ivbuf),
      )
      for j = 0; j < blocks * 16; j = j + 1 {
        out[pos + j] = dec[j]
      }
    }
    pos = pos + prot
  }
  if pos != size {
    return Err("leftover packet bytes")
  }
  Ok(())
}

///| `cens_scheme_decrypt`: AES-CTR with a crypt/skip block pattern. */
fn cens_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  cb : UInt,
  sb : UInt,
  out : Array[Byte],
  size : Int
) -> Result[Unit, String] {
  let ctx = @libavutil.av_aes_ctr_alloc()
  match @libavutil.av_aes_ctr_init(ctx, key) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  @libavutil.av_aes_ctr_set_full_iv(ctx, Bytes::from_array(iv[:]))
  if subs.length() == 0 {
    let enc = @libavutil.av_aes_ctr_crypt(ctx, Bytes::from_array(out[:]), size)
    for i = 0; i < size; i = i + 1 {
      out[i] = enc[i]
    }
    return Ok(())
  }
  if cb == 0 && sb == 0 {
    return Err("pattern missing in cens")
  }
  let cbb = cb.reinterpret_as_int() * 16
  let sbb = sb.reinterpret_as_int() * 16
  let mut pos = 0
  for i = 0; i < subs.length(); i = i + 1 {
    let clear = subs[i].bytes_of_clear
    let prot = subs[i].bytes_of_protected
    if clear + prot > size - pos {
      return Err("subsample exceeds packet")
    }
    pos = pos + clear
    let mut rem = prot
    let mut d = pos
    while rem > 0 {
      if rem < cbb {
        break
      }
      let enc = @libavutil.av_aes_ctr_crypt(
        ctx,
        Bytes::from_array(out[d:d + cbb]),
        cbb,
      )
      for j = 0; j < cbb; j = j + 1 {
        out[d + j] = enc[j]
      }
      d = d + cbb
      rem = rem - cbb
      let sk = if sbb < rem { sbb } else { rem }
      d = d + sk
      rem = rem - sk
    }
    pos = pos + prot
  }
  if pos != size {
    return Err("leftover packet bytes")
  }
  Ok(())
}

///| `cbcs_scheme_decrypt`: AES-CBC with a crypt/skip block pattern; the IV resets per subsample. */
fn cbcs_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  cb : UInt,
  sb : UInt,
  out : Array[Byte],
  size : Int
) -> Result[Unit, String] {
  let aes = @libavutil.av_aes_alloc()
  match @libavutil.av_aes_init(aes, key, 128, true) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if subs.length() == 0 {
    let ivbuf : FixedArray[Byte] = iv.copy()
    let blocks = size / 16
    let dec = @libavutil.av_aes_crypt(aes, Bytes::from_array(out[:]), blocks, Some(ivbuf))
    for i = 0; i < blocks * 16; i = i + 1 {
      out[i] = dec[i]
    }
    return Ok(())
  }
  if cb == 0 && sb == 0 {
    return Err("pattern missing in cbcs")
  }
  let cbb = cb.reinterpret_as_int() * 16
  let sbb = sb.reinterpret_as_int() * 16
  let cblocks = cb.reinterpret_as_int()
  let mut pos = 0
  for i = 0; i < subs.length(); i = i + 1 {
    let clear = subs[i].bytes_of_clear
    let prot = subs[i].bytes_of_protected
    if clear + prot > size - pos {
      return Err("subsample exceeds packet")
    }
    pos = pos + clear
    let ivbuf : FixedArray[Byte] = iv.copy()
    let mut rem = prot
    let mut d = pos
    while rem > 0 {
      if rem < cbb {
        break
      }
      let dec = @libavutil.av_aes_crypt(
        aes,
        Bytes::from_array(out[d:d + cbb]),
        cblocks,
        Some(ivbuf),
      )
      for j = 0; j < cbb; j = j + 1 {
        out[d + j] = dec[j]
      }
      d = d + cbb
      rem = rem - cbb
      let sk = if sbb < rem { sbb } else { rem }
      d = d + sk
      rem = rem - sk
    }
    pos = pos + prot
  }
  if pos != size {
    return Err("leftover packet bytes")
  }
  Ok(())
}

///|
/// `cenc_decrypt`: decrypt one sample's payload. The scheme, pattern, IV and
/// subsample map come from the track's cenc metadata (`sinf`/`schm`/`tenc`/
/// `senc`); `key` is the 16-byte AES-128 content key.
///
/// This slice wires the non-fragmented `senc` path; the per-sample info is
/// looked up positionally, falling back to the `tenc` default (constant IV).
pub fn mov_decrypt_sample(
  track : Mp4Track,
  index : Int,
  key : Bytes,
  payload : Bytes
) -> Result[Bytes, String] {
  if key.length() != 16 {
    return Err("EINVAL")
  }
  let sel : MovEncSample? = if index >= 0 && index < track.cenc_samples.length() {
    track.cenc_samples[index]
  } else {
    None
  }
  let enc : MovEncSample = match sel {
    Some(e) => e
    None => { iv: track.cenc_default_iv.copy(), subsamples: [] }
  }
  let iv = enc.iv
  let subs = enc.subsamples
  let scheme = track.cenc_scheme
  let cb = track.cenc_crypt_byte_block
  let sb = track.cenc_skip_byte_block
  let out = payload.to_array()
  let size = out.length()
  let res = if scheme == schm_cenc && cb == 0 && sb == 0 {
    cenc_ctr_decrypt(key, iv, subs, out, size)
  } else if scheme == schm_cbc1 && cb == 0 && sb == 0 {
    cenc_cbc_decrypt(key, iv, subs, out, size)
  } else if scheme == schm_cens {
    cens_decrypt(key, iv, subs, cb, sb, out, size)
  } else if scheme == schm_cbcs {
    cbcs_decrypt(key, iv, subs, cb, sb, out, size)
  } else {
    Err("invalid encryption scheme")
  }
  match res {
    Err(e) => Err(e)
    Ok(_) => Ok(Bytes::from_array(out))
  }
}

// ---------------------------------------------------------------------------
// mov_merge_tts_data and mov_build_index
// ---------------------------------------------------------------------------

///|
/// The "old uncompressed audio chunk demuxing" branch of `mov_build_index`:
/// chunks of `stsc`-declared samples are cut into packets of at most 1024
/// samples (or exactly one frame of the codec's packing, e.g. 6 for MACE or
/// 160 for GSM). Every entry is a keyframe with `min_distance` 0. The
/// subsequent CTTS-only merge is not ported: a PCM track carrying `ctts` is
/// not a combination FFmpeg produces or consumes meaningfully.
fn mov_build_audio_chunk_index(track : Mp4Track, current_dts : Int64) -> Unit {
  if track.chunk_offsets.length() == 0 || track.samples.length() > 0 {
    // `!sc->chunk_count || sc->tts_count`
    return
  }
  let spf = track.samples_per_frame
  let bpf = track.bytes_per_frame
  // Typed constants keep the packing arithmetic unsigned (the C works in
  // `unsigned int` throughout this branch).
  let q1024 : UInt = 1024
  let q1023 : UInt = 1023
  // Compute the total packet count, exactly like the C first pass.
  let mut total : UInt = 0
  for i = 0; i < track.stsc.length(); i = i + 1 {
    let chunk_samples = track.stsc[i].count.reinterpret_as_uint()
    if i != track.stsc.length() - 1 && spf != 0 &&
      chunk_samples % spf != 0 {
      // error unaligned chunk
      return
    }
    let count : UInt = if spf >= 160 {
      // gsm
      chunk_samples / spf
    } else if spf > 1 {
      let samples = q1024 / spf * spf
      (chunk_samples + samples - 1) / samples
    } else {
      (chunk_samples + q1023) / q1024
    }
    let chunk_count : UInt = if mov_stsc_index_valid(i, track.stsc.length()) {
      (track.stsc[i + 1].first - track.stsc[i].first).reinterpret_as_uint()
    } else {
      (track.chunk_offsets.length() - (track.stsc[i].first - 1)).reinterpret_as_uint()
    }
    total = total + chunk_count * count
  }
  // Populate the index.
  let mut stsc_index = 0
  let mut dts = current_dts
  for i = 0; i < track.chunk_offsets.length(); i = i + 1 {
    let mut offset = track.chunk_offsets[i]
    while mov_stsc_index_valid(stsc_index, track.stsc.length()) &&
      i + 1 == track.stsc[stsc_index + 1].first {
      stsc_index = stsc_index + 1
    }
    let mut chunk_samples = track.stsc[stsc_index].count.reinterpret_as_uint()
    while chunk_samples > 0 {
      if spf > 1 && bpf == 0 {
        // "Zero bytes per frame, but N samples per frame"
        return
      }
      let (samples, size) : (UInt, UInt) = if spf >= 160 {
        // gsm: exactly one frame per packet.
        (spf, bpf)
      } else if spf > 1 {
        let frame = q1024 / spf * spf
        let m = if frame < chunk_samples { frame } else { chunk_samples }
        (m, m / spf * bpf)
      } else {
        let m = if q1024 < chunk_samples { q1024 } else { chunk_samples }
        (m, m * track.sample_size)
      }
      if track.samples.length() >= total.reinterpret_as_int() {
        // wrong chunk count
        return
      }
      track.samples.push({
        offset,
        size,
        dts,
        pts: dts,
        duration: samples,
        keyframe: true,
        min_distance: 0,
        discard: false,
      })
      offset = offset + size.to_int64()
      dts = dts + samples.to_int64()
      chunk_samples = chunk_samples - samples
    }
  }
}

///|
/// `mov_merge_tts_data`: expand `stts` and `ctts` into a per-sample table where
/// each entry carries one sample's duration and one sample's CTTS offset, with
/// `count` set to 1 (the C code sets the same after the expansion).
/// `has_stts`/`has_ctts` keep the presence flags that C preserves in
/// `stts_count`/`ctts_count` after freeing the original arrays.
fn mov_merge_tts_data(track : Mp4Track) -> Unit raise MovError {
  let has_ctts = track.ctts.length() > 0
  let has_stts = track.stts.length() > 0
  if !has_ctts && !has_stts {
    return
  }
  if track.sample_count <= 0 {
    raise InvalidData("no sample count for tts merge")
  }
  let n = track.sample_count
  let tts : Array[MovTts] = Array::make(n, { count: 0, offset: 0, duration: 0 })
  let mut idx = 0
  if has_ctts {
    for i = 0; i < track.ctts.length(); i = i + 1 {
      let e = track.ctts[i]
      let mut j = 0
      while j < e.count && idx < n {
        tts[idx] = { count: 1, offset: e.offset, duration: 0 }
        idx = idx + 1
        j = j + 1
      }
    }
    track.has_ctts = true
  }
  // The stts pass restarts at sample 0, filling in the durations that the ctts
  // pass left at zero (C resets `idx = 0` between the two loops).
  idx = 0
  if has_stts {
    for i = 0; i < track.stts.length(); i = i + 1 {
      let e = track.stts[i]
      let mut j = 0
      while j < e.count && idx < n {
        let prev = tts[idx]
        tts[idx] = { count: 1, offset: prev.offset, duration: e.duration }
        idx = idx + 1
        j = j + 1
      }
    }
    track.has_stts = true
  }
  track.tts = tts
}

///|
/// `mov_build_index`: turn the sample tables into a per-sample index.
///
/// The chunked "old uncompressed audio" path is not ported: when it would apply
/// (`stts` reduces to a single entry of duration 1 on an audio track), the track
/// is flagged with `unsupported_audio_chunk_demux` and produces no samples.
fn mov_build_index(st : MovState, track : Mp4Track) -> Unit raise MovError {
  let mut current_dts : Int64 = 0
  let mut stsc_index = 0
  let mut stss_index = 0
  let mut stps_index = 0

  // Edit list: adjust the first DTS (non-advanced-editlist behaviour).
  if track.elst.length() > 0 {
    let mut empty_duration : Int64 = 0
    let mut start_time : Int64 = 0
    let mut edit_start_index = 0
    for i = 0; i < track.elst.length(); i = i + 1 {
      let e = track.elst[i]
      if i == 0 && e.time == -1 {
        // An empty first edit carries the stream start time in movie timebase.
        empty_duration = e.duration
        edit_start_index = 1
      } else if i == edit_start_index && e.time >= 0 {
        start_time = e.time
      }
    }
    if (empty_duration != 0 || start_time != 0) && st.movie.timescale > 0 {
      if empty_duration != 0 {
        empty_duration = mov_rescale(empty_duration, track.timescale, st.movie.timescale)
      }
      track.time_offset = start_time - empty_duration
      current_dts = -mov_clip64(track.time_offset)
    }
  }

  // `build_open_gop_key_points` computes the minimal stts duration for the
  // seek back-off; ported here since the sgpd/NAL part is not in this slice.
  let mut min_dur : UInt = 4294967295
  for i = 0; i < track.stts.length(); i = i + 1 {
    if track.stts[i].duration < min_dur {
      min_dur = track.stts[i].duration
    }
  }
  track.min_sample_duration = min_dur

  // Only use old uncompressed audio chunk demuxing when stts specifies it.
  let audio_special = media_is_audio(track.media_type) &&
    track.stts.length() == 1 &&
    track.stts[0].duration == 1
  if audio_special {
    // The "old uncompressed audio chunk demuxing": one index entry per 1024
    // samples (or per frame of the codec's packing), each entry a keyframe.
    track.unsupported_audio_chunk_demux = true
    mov_build_audio_chunk_index(track, current_dts)
    return
  }

  current_dts = current_dts - track.dts_shift.to_int64()

  mov_merge_tts_data(track)
  if track.sample_count <= 0 || track.tts.length() == 0 || track.stsc.length() == 0 ||
    track.chunk_offsets.length() == 0 ||
    track.samples.length() > 0 {
    // `!sc->sample_count || sti->nb_index_entries || sc->tts_count`: nothing
    // to index, or the track was already indexed by fragments.
    return
  }

  let key_off = if (track.keyframes.length() > 0 && track.keyframes[0] > 0) ||
    (track.stps.length() > 0 && track.stps[0] > 0) {
    1
  } else {
    0
  }

  let mut current_sample = 0
  let mut stts_sample = 0
  let mut distance : UInt = 0
  let mut stts_index = 0

  for i = 0; i < track.chunk_offsets.length(); i = i + 1 {
    let next_offset = if i + 1 < track.chunk_offsets.length() {
      track.chunk_offsets[i + 1]
    } else {
      i64_max
    }
    let mut current_offset = track.chunk_offsets[i]
    while mov_stsc_index_valid(stsc_index, track.stsc.length()) &&
      i + 1 == track.stsc[stsc_index + 1].first {
      stsc_index = stsc_index + 1
    }

    // The `stsz` sanity fixups from mov_build_index.
    if next_offset > current_offset &&
      track.sample_size > 0 &&
      track.sample_size < track.stsz_sample_size &&
      track.stsc[stsc_index].count.to_int64() * track.stsz_sample_size.to_int64() >
      next_offset - current_offset {
      track.stsz_sample_size = track.sample_size
    }
    if track.stsz_sample_size > 0 && track.stsz_sample_size < track.sample_size {
      track.stsz_sample_size = track.sample_size
    }

    for j = 0; j < track.stsc[stsc_index].count; j = j + 1 {
      if current_sample >= track.sample_count {
        raise InvalidData("wrong sample count")
      }
      let mut keyframe = false
      if !track.keyframe_absent &&
        (track.keyframes.length() == 0 ||
          (current_sample + key_off).reinterpret_as_uint() == track.keyframes[stss_index]) {
        keyframe = true
        if stss_index + 1 < track.keyframes.length() {
          stss_index = stss_index + 1
        }
      } else if track.stps.length() > 0 &&
        (current_sample + key_off).reinterpret_as_uint() == track.stps[stps_index] {
        keyframe = true
        if stps_index + 1 < track.stps.length() {
          stps_index = stps_index + 1
        }
      }
      if track.keyframe_absent &&
        track.stps.length() == 0 &&
        (media_is_audio(track.media_type) || (i == 0 && j == 0)) {
        keyframe = true
      }
      if keyframe {
        distance = 0
      }
      let sample_size = if track.stsz_sample_size > 0 {
        track.stsz_sample_size
      } else if current_sample < track.sample_sizes.length() {
        track.sample_sizes[current_sample]
      } else {
        raise InvalidData("missing sample size")
      }
      let duration = track.tts[stts_index].duration
      // Only the primary sample description (stsc id 1) is indexed, matching
      // FFmpeg's pseudo_stream_id filtering for the primary stream.
      if track.stsc[stsc_index].id == 1 {
        let pts = if track.has_ctts {
          current_dts + track.dts_shift.to_int64() + track.tts[stts_index].offset.to_int64()
        } else {
          current_dts
        }
        track.samples.push({
          offset: current_offset,
          size: sample_size,
          dts: current_dts,
          pts,
          duration,
          keyframe,
          min_distance: distance,
          discard: false,
        })
      }
      current_offset = current_offset + sample_size.to_int64()
      current_dts = current_dts + duration.to_int64()
      distance = distance + 1
      stts_sample = stts_sample + 1
      current_sample = current_sample + 1
      if stts_index + 1 < track.tts.length() && stts_sample == track.tts[stts_index].count {
        stts_sample = 0
        stts_index = stts_index + 1
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

///|
/// `av_mov_open`: parse an in-memory MP4/MOV container.
///
/// Walking top-level boxes mirrors `mov_read_default` called from
/// `mov_read_header` with `atom.type == 'root'`. Malformed input is reported as
/// `Err`, mirroring the negative return codes in libavformat/mov.c.
pub fn av_mov_open(buf : Bytes) -> Result[Mp4Movie, String] {
  let movie = new_movie()
  let st : MovState = {
    movie,
    cur: new_track(),
    in_trak: false,
    in_moof: false,
    trex: [],
    frag: new_frag(),
  }
  let r = Mp4Reader::new(buf)
  let total = r.total_size().to_int64()
  try {
    let mut consumed : Int64 = 0
    while consumed <= total - 8 {
      let box_start = r.position().to_int64()
      let size32 = r.read_u32().to_int64()
      let kind = r.read_fourcc()
      if r.eof_reached() {
        break
      }
      let mut header : Int64 = 8
      let mut size = size32
      if size32 == 1 {
        size = r.read_u64().reinterpret_as_int64()
        header = 16
      } else if size32 == 0 {
        size = total - consumed
      }
      let mut payload = size - header
      if payload < 0 {
        break
      }
      let avail = total - consumed - header
      if payload > avail {
        payload = avail
      }
      if payload < 0 {
        break
      }
      parse_box(st, r, kind, payload)
      let left = payload - (r.position().to_int64() - box_start - header)
      if left != 0 {
        r.skip(left)
      }
      consumed = consumed + header + payload
    }
    // mov_read_header looks for an `mfra` when it met moof boxes; with the
    // whole file in hand, scan for it once at the end.
    mov_read_mfra(movie, r)
    Ok(movie)
  } catch {
    InvalidData(msg) => Err(msg)
  }
}
