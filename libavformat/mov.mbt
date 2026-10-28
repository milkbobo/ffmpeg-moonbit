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
///   * sample groups: `sgpd`('sync') NAL-type entries, `sbgp`('rap '/'sync')
///     runs, `build_open_gop_key_points` (per-sample ctts offsets + the CRA
///     open-key list + min stts duration) feeding `can_seek_to_key_sample`
///     in seek.mbt; multi sample descriptions (`ff_mov_read_stsd_entries`
///     walk, `mov_skip_multiple_stsd`, per-entry extradata slots,
///     `pseudo_stream_id` index filter, the tfdt/trun `stsd_id` gates and
///     the first-chunk `last_stsd` extradata switch).
///   * advanced edit lists (`mov_fix_index`): the index is rebuilt against
///     the edit-list timeline — discarded leading frames keep strictly
///     increasing timestamps via the frame-duration buffer rewrite, empty
///     edits offset the timeline and become `start_time`, partial first
///     audio frames trim `skip_samples`, a positive `min_corrected_pts`
///     re-zeros the first video PTS (and feeds `mov_seek_stream`), the tts
///     runs are rebuilt and presentation timestamps re-derived from them.
///     `mov_estimate_video_delay` (H264 reorder) and the mov_read_trak
///     quirks (stsc clearing, fragmented auto-disable of the option) ride
///     along. `av_mov_open_with(buf, false)` selects the non-advanced path.
///   * not ported: AVIO/AVPacket/AVFormatContext plumbing (this parser works
///     on an `AvioContext` the caller supplies) and the `dvcC`/`dvvC`
///     whole-atom extradata variants. The C's `index_ranges` (old→new sample
///     mapping for the demux cursor) are unnecessary here: the filtered
///     index is materialised directly.
///   * simplified: per-sample timestamps are materialised up front instead
///     of being consulted lazily, the `free`/`hoov`-hiding-`moov` recovery is
///     omitted, and corrupt-count guards are tightened relative to the C code.

///|
/// Parse failure, corresponding to the negative returns in libavformat/mov.c. */
pub suberror MovError {
  InvalidData(String)
}

// ---------------------------------------------------------------------------
// Data model (mirrors the MOV structs in libavformat/isom.h)
// ---------------------------------------------------------------------------

///|
/// `MOVStts` from libavformat/isom.h. */
pub struct MovStts {
  count : Int32
  duration : UInt32
}

///|
/// `MOVCtts` from libavformat/isom.h. */
pub struct MovCtts {
  count : Int32
  offset : Int32
}

///|
/// `MOVStsc` from libavformat/isom.h. */
pub struct MovStsc {
  first : Int32
  count : Int32
  id : Int32
}

///|
/// `MOVSbgp` from libavformat/isom.h: one sample-to-group run. */
pub struct MovSbgp {
  count : UInt32
  index : UInt32
}

///|
/// `MOVElst` from libavformat/isom.h. */
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
  count : Int32
  offset : Int32
  duration : UInt32
}

///|
/// One entry of the sample index, corresponding to FFmpeg's `AVIndexEntry`
/// (`pos`, `timestamp`, `size`, `min_distance`, `flags`) plus the presentation
/// timestamp that `mov_finalize_packet` derives from it. `discard` mirrors
/// `AVINDEX_DISCARD_FRAME`: fragments overlapping in decode order are flagged
/// and skipped at demux time.
pub struct Mp4Sample {
  offset : Int64
  size : UInt32
  /// `AVIndexEntry.timestamp`; rewritten by `mov_fix_index`. */
  mut dts : Int64
  /// Presentation timestamp derived from the tts table at demux; recomputed
  /// after `mov_fix_index` rebuilds the tts runs. */
  mut pts : Int64
  duration : UInt32
  keyframe : Bool
  min_distance : UInt32
  discard : Bool
}

///|
/// Media type derived from the `hdlr` handler type (AVMediaType subset). */
pub enum Mp4MediaType {
  Video
  Audio
  Subtitle
  Unknown
}

///|
/// True for video tracks, avoiding a structural `Eq` on `Mp4MediaType`. */
fn media_is_video(t : Mp4MediaType) -> Bool {
  match t {
    Video => true
    _ => false
  }
}

///|
/// True for audio tracks. */
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
  mut track_id : UInt32
  mut handler : String
  mut media_type : Mp4MediaType
  mut codec : String
  /// FFmpeg codec-id name resolved from `esds` (`""` when not set). */
  mut codec_id : String
  /// Raw codec private data (`avcC`/`hvcC`/`av1C`/`glbl` payload or the `esds` DecoderSpecificInfo). */
  mut extradata : Bytes?
  /// `sc->extradata[]`: one extradata slot per sample-description entry. */
  stsd_extradata : Array[Bytes?]
  /// `sc->stsd_count`: entries seen in the `stsd` box (parsed or skipped). */
  mut stsd_count : Int32
  /// `sc->pseudo_stream_id`: -1 keeps every chunk in the index, else only
  /// chunks whose `stsc` id - 1 equals it are indexed. */
  mut pseudo_stream_id : Int32
  /// `sc->last_stsd_index`: sample description the first chunk references. */
  mut last_stsd_index : Int32
  mut timescale : UInt32
  mut duration : UInt64
  mut width : Int32
  mut height : Int32
  mut sample_rate : UInt32
  mut channels : UInt32
  mut bits_per_sample : UInt32
  /// `st->codecpar->frame_size` from the AAC AudioSpecificConfig. */
  mut frame_length : Int32
  /// `st->codecpar->bit_rate` from the `esds` DecoderConfigDescriptor. */
  mut bit_rate : UInt32
  mut encoder : String
  /// Audio sample entry v1/v2 packing (`sc->samples_per_frame`). */
  mut samples_per_frame : UInt32
  /// Audio sample entry v1/v2 packing (`sc->bytes_per_frame`). */
  mut bytes_per_frame : UInt32
  /// Audio sample entry `compression_id` (`sc->audio_cid`). */
  mut audio_cid : Int32
  stts : Array[MovStts]
  ctts : Array[MovCtts]
  stsc : Array[MovStsc]
  mut stsz_sample_size : UInt32
  mut sample_size : UInt32
  sample_sizes : Array[UInt32]
  mut sample_count : Int32
  chunk_offsets : Array[Int64]
  keyframes : Array[UInt32]
  stps : Array[UInt32]
  mut keyframe_absent : Bool
  /// `sc->sgpd_sync`: NAL unit types of the 'sync' sample-group descriptions. */
  sgpd_sync : Array[UInt32]
  /// `sc->sync_group`: 'sync' sample-to-group runs (`sbgp`). */
  sync_group : Array[MovSbgp]
  /// `sc->rap_group`: 'rap ' sample-to-group runs (`sbgp`). */
  rap_group : Array[MovSbgp]
  /// `sc->sample_offsets`: per-sample ctts offsets, unrolled (open-GOP path). */
  sample_offsets : Array[Int32]
  /// `sc->open_key_samples`: sample numbers of open-GOP (CRA) key samples. */
  open_key_samples : Array[Int32]
  elst : Array[MovElst]
  mut stsd_version : UInt32
  mut dts_shift : Int32
  mut time_offset : Int64
  mut track_end : Int64
  mut min_sample_duration : UInt32
  /// `msc->min_corrected_pts`: PTS floor from the elst pre-pass, recomputed
  /// by `mov_fix_index`; `mov_seek_stream` subtracts it like the C does. */
  mut min_corrected_pts : Int64
  /// `sti->skip_samples` (== `codecpar->initial_padding` after the fix). */
  mut skip_samples : Int32
  /// `st->start_time` in track timescale; `av_nopts_value` until set. */
  mut start_time : Int64
  /// `codecpar->video_delay` from `mov_estimate_video_delay` (H264 only). */
  mut video_delay : Int32
  mut has_sidx : Bool
  mut cenc_scheme : UInt32
  mut cenc_per_sample_iv_size : Int32
  mut cenc_crypt_byte_block : UInt32
  mut cenc_skip_byte_block : UInt32
  mut cenc_default_iv : FixedArray[Byte]
  cenc_samples : Array[MovEncSample?]
  /// `saiz`: default per-sample size of the auxiliary info chunk. */
  mut aux_info_default_size : Int32
  /// `saiz`: per-sample sizes when the default is 0. */
  aux_info_sizes : Array[UInt32]
  /// `saiz`: declared sample count. */
  mut aux_info_sample_count : Int32
  /// `saio`: absolute offsets of the auxiliary info chunks. */
  aux_info_offsets : Array[Int64]
  mut tts : Array[MovTts]
  mut has_stts : Bool
  mut has_ctts : Bool
  mut unsupported_audio_chunk_demux : Bool
  samples : Array[Mp4Sample]
}

///|
/// `MOVStreamContext` fragment-reference state from `mov_read_sidx`, kept per reference. */
pub struct MovSidxRef {
  track_id : UInt32
  /// Byte offset of the referenced fragment (its `moof`). */
  offset : Int64
  /// Earliest presentation time rescaled to the track timescale. */
  pts : Int64
  /// Subsegment byte size. */
  size : UInt32
  /// Subsegment duration in sidx timescale units. */
  duration : UInt32
}

///|
/// One `tfra` entry (fragment random-access point). */
pub struct MovTfraEntry {
  time : Int64
  offset : Int64
}

///|
/// A `tfra` box: random-access points of one track. */
pub struct MovTfra {
  track_id : UInt32
  entries : Array[MovTfraEntry]
}

///|
/// Movie-level state, corresponding to the `MOVContext`/`AVFormatContext` fields used here. */
pub struct Mp4Movie {
  /// `mov->advanced_editlist` (default on); auto-disabled by the first
  /// fragmented track, exactly at that trak's build point as in the C. */
  mut advanced_editlist : Bool
  mut timescale : UInt32
  mut duration : UInt64
  mut isom : Bool
  mut major_brand : String
  /// All compatible brands of `ftyp`, concatenated (used by the QuickTime audio-entry check). */
  mut compatible_brands : String
  /// `sidx` references, in file order. */
  sidx_refs : Array[MovSidxRef]
  /// `mfra`/`tfra` random-access tables when the file ends with an `mfra`. */
  mfra : Array[MovTfra]
  tracks : Array[Mp4Track]
}

///|
fn new_track() -> Mp4Track {
  {
    track_id: 0,
    handler: "",
    media_type: Mp4MediaType::Unknown,
    codec: "",
    codec_id: "",
    extradata: None,
    stsd_extradata: [],
    stsd_count: 0,
    pseudo_stream_id: 0,
    last_stsd_index: 0,
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
    sgpd_sync: [],
    sync_group: [],
    rap_group: [],
    sample_offsets: [],
    open_key_samples: [],
    elst: [],
    stsd_version: 0,
    dts_shift: 0,
    time_offset: 0,
    track_end: 0,
    min_sample_duration: 0,
    min_corrected_pts: 0,
    skip_samples: 0,
    start_time: av_nopts_value,
    video_delay: 0,
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

///|
fn new_movie() -> Mp4Movie {
  {
    advanced_editlist: true,
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

///|
/// `max_stts_delta` default from the mov demuxer options: `UINT_MAX - 48000*10`. */
let max_stts_delta : UInt32 = 4294487295

///|
/// `UINT32_MAX`, used as mdhd's "unknown duration" marker in version 0. */
let u32_max_u64 : UInt64 = 0xFFFFFFFF

///|
/// `AV_NOPTS_VALUE`: sentinel for "no presentation timestamp". */
let av_nopts_value : Int64 = -9223372036854775807L - 1L

///|
/// `UINT64_MAX`, the version 1 "unknown duration" marker. */
let u64_max : UInt64 = 0xFFFFFFFFFFFFFFFF

///|
/// `INT64_MAX`, used as the "no next chunk" sentinel in `mov_build_index`. */
let i64_max : Int64 = 0x7FFFFFFFFFFFFFFF

// Fragment flags, from libavformat/isom.h.

///|
/// `MOV_TFHD_BASE_DATA_OFFSET`. */
let tfhd_base_data_offset : UInt32 = 0x000001

///|
/// `MOV_TFHD_STSD_ID`. */
let tfhd_stsd_id : UInt32 = 0x000002

///|
/// `MOV_TFHD_DEFAULT_DURATION`. */
let tfhd_default_duration : UInt32 = 0x000008

///|
/// `MOV_TFHD_DEFAULT_SIZE`. */
let tfhd_default_size : UInt32 = 0x000010

///|
/// `MOV_TFHD_DEFAULT_FLAGS`. */
let tfhd_default_flags : UInt32 = 0x000020

///|
/// `MOV_TFHD_DEFAULT_BASE_IS_MOOF`. */
let tfhd_default_base_is_moof : UInt32 = 0x020000

///|
/// `MOV_TRUN_DATA_OFFSET`. */
let trun_data_offset : UInt32 = 0x0001

///|
/// `MOV_TRUN_FIRST_SAMPLE_FLAGS`. */
let trun_first_sample_flags : UInt32 = 0x0004

///|
/// `MOV_TRUN_SAMPLE_DURATION`. */
let trun_sample_duration : UInt32 = 0x0100

///|
/// `MOV_TRUN_SAMPLE_SIZE`. */
let trun_sample_size : UInt32 = 0x0200

///|
/// `MOV_TRUN_SAMPLE_FLAGS`. */
let trun_sample_flags : UInt32 = 0x0400

///|
/// `MOV_TRUN_SAMPLE_CTS`. */
let trun_sample_cts : UInt32 = 0x0800

///|
/// `MOV_FRAG_SAMPLE_FLAG_IS_NON_SYNC`. */
let frag_sample_flag_is_non_sync : UInt32 = 0x00010000

///|
/// `MOV_FRAG_SAMPLE_FLAG_DEPENDS_YES`. */
let frag_sample_flag_depends_yes : UInt32 = 0x01000000

// Encryption scheme fourccs, `MKBETAG('c','e','n','c')` etc.

///|
/// `cenc` (AES-CTR, full sample). */
let schm_cenc : UInt32 = 0x63656E63

///|
/// `cens` (AES-CTR with pattern). */
let schm_cens : UInt32 = 0x63656E73

///|
/// `cbc1` (AES-CBC, full sample). */
let schm_cbc1 : UInt32 = 0x63626331

///|
/// `cbcs` (AES-CBC with pattern). */
let schm_cbcs : UInt32 = 0x63626373

///|
/// `MOVTrackExt` from libavformat/isom.h, parsed from a `trex` box. */
priv struct MovTrex {
  track_id : UInt32
  stsd_id : UInt32
  duration : UInt32
  size : UInt32
  flags : UInt32
}

///|
/// `MOVFragment` from libavformat/isom.h: the current `moof`/`traf` header
/// state shared across the `tfhd`/`tfdt`/`trun` boxes of one track fragment.
priv struct MovFrag {
  mut found_tfhd : Bool
  mut track_id : UInt32
  /// `frag->stsd_id`: the fragment's sample description (tfhd flag or trex). */
  mut stsd_id : UInt32
  mut base_data_offset : Int64
  mut moof_offset : Int64
  mut implicit_offset : Int64
  mut duration : UInt32
  mut size : UInt32
  mut flags : UInt32
  mut tfdt : Int64
  mut has_tfdt : Bool
}

///|
/// Zero-valued initial fragment state. */
fn new_frag() -> MovFrag {
  {
    found_tfhd: false,
    track_id: 0,
    stsd_id: 0,
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

///|
/// `AVSubsampleEncryptionInfo` from libavutil/encryption_info.h. */
pub struct MovSubSample {
  bytes_of_clear : Int32
  bytes_of_protected : Int32
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

///|
/// `mov_stsc_index_valid`: `index < count - 1` (with the C unsigned wraparound). */
fn mov_stsc_index_valid(index : Int32, count : Int32) -> Bool {
  index < count - 1
}

///|
/// 4CC equal to four characters, mirroring `MKTAG('a','b','c','d')`. */
fn tag(a : Char, b : Char, c : Char, d : Char) -> String {
  let chars : Array[Char] = [a, b, c, d]
  String::from_array(chars[:])
}

///|
/// Saturating 64-bit addition (`av_sat_add64`). */
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

///|
/// `av_rescale` for the edit-list conversion, delegating to the libavutil port. */
fn mov_rescale(a : Int64, b : UInt32, c : UInt32) -> Int64 {
  @libavutil.av_rescale(a, b.to_int64(), c.to_int64())
}

// ---------------------------------------------------------------------------
// Parser state and box traversal
// ---------------------------------------------------------------------------

///|
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
fn parse_box(
  st : MovState,
  r : AvioContext,
  kind : String,
  size : Int64,
) -> Unit raise MovError {
  if kind == "trak" {
    parse_trak(st, r, size)
  } else if kind == "moof" {
    parse_moof(st, r, size)
  } else if kind == "moov" ||
    kind == "mdia" ||
    kind == "minf" ||
    kind == "stbl" ||
    kind == "edts" ||
    kind == "mvex" ||
    kind == "traf" ||
    kind == "sinf" ||
    kind == "schi" {
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
  } else if kind == "sgpd" {
    parse_sgpd(st, r, size)
  } else if kind == "sbgp" {
    parse_sbgp(st, r)
  } else if kind == "esds" {
    parse_esds(st, r)
  } else if kind == "dOps" {
    parse_dops(st, r, size)
  } else if kind == "dfLa" {
    parse_dfla(st, r, size)
  } else if kind == "vpcC" {
    parse_vpcc(st, r, size)
  } else if kind == "avcC" ||
    kind == "hvcC" ||
    kind == "av1C" ||
    kind == "glbl" ||
    kind == "vvcC" ||
    kind == "evcC" ||
    kind == "lvcC" ||
    kind == "apvC" {
    // mov_read_glbl: the whole payload becomes the codec extradata.
    parse_glbl(st, r, kind, size)
  } else {
    let _ = r.avio_skip(size)
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
fn parse_default(
  st : MovState,
  r : AvioContext,
  parent_size : Int64,
) -> Unit raise MovError {
  let mut consumed : Int64 = 0
  while consumed <= parent_size - 8 {
    let box_start = r.avio_tell()
    let size32 = r.avio_rb32().to_int64()
    let kind = r.avio_rl32_tag()
    if r.avio_feof() {
      break
    }
    let mut header : Int64 = 8
    let mut size = size32
    if size32 == 1 {
      // 64-bit extended size: `avio_rb64(pb) - 8` on top of the 8 bytes read.
      size = r.avio_rb64().reinterpret_as_int64()
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
    let left = payload - (r.avio_tell() - box_start - header)
    if left != 0 {
      // mov_read_default ignores the skip result unless AV_EF_EXPLODE is set
      let _ = r.avio_skip(left)
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
  let neg = v >> 63 == 1
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
  if neg {
    -mag
  } else {
    mag
  }
}

///|
/// Exact `2^k` for -1074 <= k <= 1023, by squaring the base power. */
fn mov_pow2(k : Int32) -> Double {
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
fn parse_ftyp(st : MovState, r : AvioContext, size : Int64) -> Unit {
  let major = r.avio_rl32_tag()
  let _ = r.avio_rb32() // minor version
  st.movie.major_brand = major
  if major != tag('q', 't', ' ', ' ') {
    st.movie.isom = true
  }
  let brands : Array[Char] = []
  // The compatible-brand list fills the rest of the atom, 4 bytes per brand.
  let end = r.avio_tell() + (size - 8L)
  while r.avio_tell() + 4L <= end {
    for i = 0; i < 4; i = i + 1 {
      brands.push(r.avio_r8().to_byte().to_char())
    }
  }
  st.movie.compatible_brands = st.movie.compatible_brands +
    String::from_array(brands[:])
}

///|
/// `mov_read_mvhd`. */
fn parse_mvhd(st : MovState, r : AvioContext) -> Unit {
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  // creation and modification times (mov_metadata_creation_time)
  if version == 1 {
    let _ = r.avio_skip(16L)
  } else {
    let _ = r.avio_skip(8L)
  }
  let raw_ts = r.avio_rb32()
  st.movie.timescale = if raw_ts.reinterpret_as_int() <= 0 { 1 } else { raw_ts }
  st.movie.duration = if version == 1 {
    r.avio_rb64()
  } else {
    r.avio_rb32().to_uint64()
  }
}

///|
/// `mov_read_mdhd`. */
fn parse_mdhd(st : MovState, r : AvioContext) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  if st.cur.timescale != 0 {
    raise InvalidData("multiple mdhd")
  }
  let version = r.avio_r8()
  if version > 1 {
    raise InvalidData("unsupported mdhd version")
  }
  let _ = r.avio_rb24() // flags
  if version == 1 {
    let _ = r.avio_skip(16L)
  } else {
    let _ = r.avio_skip(8L)
  }
  let raw_ts = r.avio_rb32()
  if raw_ts.reinterpret_as_int() <= 0 {
    raise InvalidData("invalid mdhd time scale")
  }
  st.cur.timescale = raw_ts
  let dur = if version == 1 { r.avio_rb64() } else { r.avio_rb32().to_uint64() }
  let unknown = if version == 1 { u64_max } else { u32_max_u64 }
  st.cur.duration = if dur == unknown { 0 } else { dur }
  let _ = r.avio_rb16() // language
  let _ = r.avio_rb16() // quality
}

///|
/// `mov_read_tkhd`. */
fn parse_tkhd(st : MovState, r : AvioContext) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  // Each trak has exactly one tkhd; `st->id` starts at -1 in mov_read_trak.
  if st.cur.track_id != 0 {
    raise InvalidData("duplicate tkhd")
  }
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  if version == 1 {
    let _ = r.avio_skip(16L)
  } else {
    let _ = r.avio_skip(8L)
  }
  st.cur.track_id = r.avio_rb32()
  let _ = r.avio_rb32() // reserved
  if version == 1 {
    let _ = r.avio_skip(8L)
  } else {
    let _ = r.avio_skip(4L)
  }
  let _ = r.avio_skip(8L) // two reserved dwords
  let _ = r.avio_skip(8L) // layer, alternate group, volume, reserved
  let _ = r.avio_skip(36L) // 3x3 display matrix (16.16 / 2.30 fixed point)
  let width = r.avio_rb32()
  let height = r.avio_rb32()
  st.cur.width = width.reinterpret_as_int() >> 16
  st.cur.height = height.reinterpret_as_int() >> 16
}

///|
/// `mov_read_hdlr`. */
fn parse_hdlr(st : MovState, r : AvioContext) -> Unit {
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let _ = r.avio_rl32_tag() // component type ('mhlr'/'dhlr')
  let kind = r.avio_rl32_tag() // component subtype
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

///|
/// `mov_read_elst`. */
fn parse_elst(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  let entry_size : Int64 = if version == 1 { 20 } else { 12 }
  let mut remaining = size - 8
  let declared = r.avio_rb32().reinterpret_as_int()
  let mut edit_count = declared
  if remaining != declared.to_int64() * entry_size {
    // Non-strict compliance: derive the entry count from the atom size.
    edit_count = (remaining / entry_size).to_int()
  }
  for i = 0; i < edit_count; i = i + 1 {
    if remaining <= 0 || r.avio_feof() {
      break
    }
    let duration : Int64 = if version == 1 {
      r.avio_rb64().reinterpret_as_int64()
    } else {
      r.avio_rb32().to_int64()
    }
    let time : Int64 = if version == 1 {
      r.avio_rb64().reinterpret_as_int64()
    } else {
      r.avio_rb32().reinterpret_as_int().to_int64()
    }
    remaining = remaining - (if version == 1 { 16 } else { 8 })
    let rate = r.avio_rb32().to_double() / 65536.0
    remaining = remaining - 4
    if duration < 0 {
      raise InvalidData("invalid edit list duration")
    }
    st.cur.elst.push({ duration, time, rate, })
  }
}

///|
/// `mov_read_stsd`, embedding the sample-entry layouts of
/// `mov_parse_stsd_video` and `mov_parse_stsd_audio`.
fn parse_stsd(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  let entries = r.avio_rb32().reinterpret_as_int()
  if entries <= 0 || entries.to_int64() > size / 8 || entries > 1024 {
    raise InvalidData("invalid STSD entries")
  }
  st.cur.stsd_version = version
  // `ff_mov_read_stsd_entries`: every entry is walked. Same-fourcc entries
  // are parsed in place (fields overwritten, extradata slotted per entry);
  // differing fourccs are skipped but still counted in stsd_count.
  for pseudo_stream_id = 0
      pseudo_stream_id < entries && r.avio_feof() == false
      pseudo_stream_id = pseudo_stream_id + 1 {
    let entry_start = r.avio_tell()
    let entry_size = r.avio_rb32().to_int64()
    let format = r.avio_rl32_tag()
    if entry_size >= 16 {
      let _ = r.avio_rb32() // reserved
      let _ = r.avio_rb16() // reserved
      let _ = r.avio_rb16() // dref_id
    } else if entry_size <= 7 {
      raise InvalidData("invalid size in stsd")
    }
    let left = entry_size - (r.avio_tell() - entry_start)
    if mov_skip_multiple_stsd(st.cur.codec, format) {
      let _ = r.avio_skip(left)
      st.cur.stsd_count = st.cur.stsd_count + 1
      continue
    }
    // `sc->pseudo_stream_id = st->codecpar->codec_tag ? -1 : pseudo_stream_id`
    st.cur.pseudo_stream_id = if st.cur.codec != "" {
      -1
    } else {
      pseudo_stream_id
    }
    st.cur.codec = format // mov_codec_id sets codec_tag = format
    if media_is_video(st.cur.media_type) {
      parse_stsd_video(st, r)
    } else if media_is_audio(st.cur.media_type) {
      parse_stsd_audio(st, r)
    }
    // Parse the child boxes of the sample entry (`sinf`/`avcC`/`esds`/`wave`/...);
    // unknown boxes are skipped by parse_box. This is what lets `sinf`/`schm`/
    // `tenc` inside an encrypted sample entry be seen.
    let used = r.avio_tell() - entry_start
    if entry_size > used {
      let child_size = entry_size - used
      let child_start = r.avio_tell()
      parse_default(st, r, child_size)
      let consumed = r.avio_tell() - child_start
      if consumed < child_size {
        let _ = r.avio_skip(child_size - consumed)
      }
    }
    // Move the entry's extradata into its slot (`sc->extradata[pseudo_stream_id]`).
    let slot = st.cur.pseudo_stream_id
    if slot >= 0 {
      while st.cur.stsd_extradata.length() <= slot {
        st.cur.stsd_extradata.push(None)
      }
      if st.cur.extradata != None {
        st.cur.stsd_extradata[slot] = st.cur.extradata
      }
    }
    st.cur.extradata = None
    st.cur.stsd_count = st.cur.stsd_count + 1
  }
  if r.avio_feof() {
    raise InvalidData("EOF in STSD atom")
  }
  // Restore back the primary extradata (`sc->extradata_size[0]`).
  if st.cur.stsd_extradata.length() > 0 {
    st.cur.extradata = st.cur.stsd_extradata[0]
  }
}

///|
/// `mov_skip_multiple_stsd`: a later entry with a different fourcc is
/// skipped; same-fourcc entries, and the AVID/prores/dv pairs, are parsed
/// into the next extradata slot. `c->fc->video_codec_id` is a user override
/// that is always unset here, so the C default arm (`codec_tag != 'jpeg'`)
/// applies.
fn mov_skip_multiple_stsd(codec_tag : String, format : String) -> Bool {
  if codec_tag != "" &&
    codec_tag != format &&
    !(codec_tag == "AV1x" && format == "AVup") &&
    codec_tag != "apcn" &&
    codec_tag != "apch" &&
    codec_tag != "dvpp" &&
    codec_tag != "dvcp" &&
    codec_tag != "jpeg" {
    true
  } else {
    false
  }
}

///|
/// `mov_parse_stsd_video`: VisualSampleEntry fields (the 16 header bytes are already read). */
fn parse_stsd_video(st : MovState, r : AvioContext) -> Unit {
  if st.movie.isom {
    let _ = r.avio_skip(4L) // pre_defined
    let _ = r.avio_skip(12L) // pre_defined
  } else {
    let _ = r.avio_rb16() // version
    let _ = r.avio_rb16() // revision level
    let _ = r.avio_rl32() // vendor
    let _ = r.avio_rb32() // temporal quality
    let _ = r.avio_rb32() // spatial quality
  }
  st.cur.width = r.avio_rb16().reinterpret_as_int()
  st.cur.height = r.avio_rb16().reinterpret_as_int()
  let _ = r.avio_rb32() // horiz resolution
  let _ = r.avio_rb32() // vert resolution
  let _ = r.avio_rb32() // data size, always 0
  let _ = r.avio_rb16() // frames per sample
  let mut len = r.avio_r8().reinterpret_as_int()
  if len > 31 {
    len = 31
  }
  let chars : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    chars.push(r.avio_r8().to_byte().to_char())
  }
  st.cur.encoder = String::from_array(chars[:])
  if len < 31 {
    let _ = r.avio_skip((31 - len).to_int64())
  }
  st.cur.bits_per_sample = r.avio_rb16() // depth
  // ISO VisualSampleEntry ends with `pre_defined = -1` (QuickTime writes
  // `color_table_id` here); the child boxes (avcC/esds/sinf/...) follow it.
  let _ = r.avio_skip(2L)
}

///|
/// `mov_parse_stsd_audio`: AudioSampleEntry fields (the 16 header bytes are
/// already read), including the QuickTime version 1/2 extension that carries
/// the PCM packing (`samples_per_frame`/`bytes_per_frame`) needed by the
/// chunked audio index path, and the codec-specific packing defaults
/// (`av_get_bits_per_sample` for the PCM fourccs).
fn parse_stsd_audio(st : MovState, r : AvioContext) -> Unit {
  let version = r.avio_rb16()
  if st.movie.isom {
    let _ = r.avio_skip(6L) // reserved
  } else {
    let _ = r.avio_rb16() // revision level
    let _ = r.avio_rl32() // vendor
  }
  st.cur.channels = r.avio_rb16()
  st.cur.bits_per_sample = r.avio_rb16()
  st.cur.audio_cid = r.avio_rb16().reinterpret_as_int()
  let _ = r.avio_rb16() // packet size
  st.cur.sample_rate = r.avio_rb32() >> 16
  // Read the QT version 1/2 fields; in version 0 these do not exist. The C
  // also honours a "qt  " compatible brand inside an ISO file.
  let qt = st.movie.compatible_brands.contains("qt  ")
  if !st.movie.isom || qt || (st.cur.stsd_version == 0 && version > 0) {
    if version == 1 {
      st.cur.samples_per_frame = r.avio_rb32()
      let _ = r.avio_rb32() // bytes per packet
      st.cur.bytes_per_frame = r.avio_rb32()
      let _ = r.avio_rb32() // bytes per sample
    } else if version == 2 {
      let _ = r.avio_rb32() // sizeof struct only
      st.cur.sample_rate = mov_int2double(r.avio_rb64())
        .to_int()
        .reinterpret_as_uint()
      st.cur.channels = r.avio_rb32()
      let _ = r.avio_rb32() // always 0x7F000000
      st.cur.bits_per_sample = r.avio_rb32()
      let _ = r.avio_rb32() // lpcm format specific flag
      st.cur.bytes_per_frame = r.avio_rb32()
      st.cur.samples_per_frame = r.avio_rb32()
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
  if bps != 0 && bps / 8 * st.cur.channels <= 4294967295 {
    st.cur.bits_per_sample = bps
    if st.cur.sample_size == 0 {
      // `sc->sample_size`: do not overwrite a value computed above.
      st.cur.sample_size = bps / 8 * st.cur.channels
    }
  }
}

///|
/// `mov_read_stts`, including the `max_stts_delta` clipping and DTS drift correction. */
fn parse_stts(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let entries = r.avio_rb32().reinterpret_as_int()
  // Corrupt counts are rejected up front; the C code relies on allocation
  // failure instead.
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid STTS entries")
  }
  let mut corrected_dts : Int64 = 0
  let mut current_dts : Int64 = 0
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    let sample_count = r.avio_rb32()
    let sample_duration = r.avio_rb32()
    let mut duration = sample_duration
    if sample_duration > max_stts_delta {
      // A huge delta is assumed to be a negative correction cast to uint32.
      let delta_magnitude = sample_duration.reinterpret_as_int()
      duration = 1
      let inc = (if delta_magnitude < 0 {
          delta_magnitude.to_int64()
        } else {
          1
        }) *
        sample_count.to_int64()
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
      duration = (duration.to_int64() - correction)
        .reinterpret_as_uint64()
        .to_uint()
    }
    st.cur.stts.push({ count: sample_count.reinterpret_as_int(), duration, })
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

///|
/// `mov_read_ctts`: per-entry presentation offsets, plus the `dts_shift` they imply. */
fn parse_ctts(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let entries = r.avio_rb32().reinterpret_as_int()
  if entries < 0 || entries.to_int64() * 8 > size - 8 {
    raise InvalidData("invalid CTTS entries")
  }
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    let count = r.avio_rb32().reinterpret_as_int()
    let offset = r.avio_rb32().reinterpret_as_int()
    if count <= 0 {
      continue
    }
    st.cur.ctts.push({ count, offset, })
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

///|
/// `mov_read_stsc`, including the validation pass that repairs corrupt tables. */
fn parse_stsc(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let entries = r.avio_rb32().reinterpret_as_int()
  if entries.to_int64() * 12 + 4 > size {
    raise InvalidData("invalid STSC size")
  }
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    let first = r.avio_rb32().reinterpret_as_int()
    let count = r.avio_rb32().reinterpret_as_int()
    let id = r.avio_rb32().reinterpret_as_int()
    st.cur.stsc.push({ first, count, id, })
  }
  // Validity pass, walking backwards exactly like the C loop.
  let mut i = st.cur.stsc.length() - 1
  while i >= 0 {
    let first_min = i.to_int64() + 1
    let e = st.cur.stsc[i]
    let forward_bad = i + 1 < st.cur.stsc.length() &&
      e.first >= st.cur.stsc[i + 1].first
    let backward_bad = i > 0 && e.first <= st.cur.stsc[i - 1].first
    if forward_bad ||
      backward_bad ||
      e.first.to_int64() < first_min ||
      e.count < 1 ||
      e.id < 1 {
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
        st.cur.stsc[i] = { first, count, id, }
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

///|
/// `mov_read_stsz` / `mov_read_stz2`. */
fn parse_stsz(
  st : MovState,
  r : AvioContext,
  size : Int64,
  stz2 : Bool,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let mut sample_size : UInt32 = 0
  let mut field_size = 32
  if !stz2 {
    sample_size = r.avio_rb32()
    if st.cur.sample_size == 0 {
      st.cur.sample_size = sample_size
    }
    st.cur.stsz_sample_size = sample_size
  } else {
    let _ = r.avio_rb24() // reserved
    field_size = r.avio_r8().reinterpret_as_int()
  }
  let entries = r.avio_rb32().reinterpret_as_int()
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
  if entries.to_int64() * field_size.to_int64() > (size - 12L) * 8L {
    raise InvalidData("STSZ atom truncated")
  }
  // `get_bits_long(&gb, field_size)` is an MSB-first bit reader over the
  // atom payload; read the packed bytes sequentially, then unpack, so that
  // 4-bit (stz2) fields pack two samples per byte and the stream cursor
  // advances exactly like the C bit reader's backing buffer.
  let nbytes = (entries.to_int64() * field_size.to_int64() + 7) / 8
  let packed : Bytes = match r.avio_read(nbytes.to_int()) {
    Ok(p) => p
    Err(_) => b""
  }
  let mut bitpos = 0
  for i = 0; i < entries; i = i + 1 {
    let mut v : UInt32 = 0
    for b = 0; b < field_size; b = b + 1 {
      let byte = if bitpos / 8 < packed.length() {
        packed[bitpos / 8].to_uint()
      } else {
        0
      }
      let shift = 7 - bitpos % 8
      v = (v << 1) | ((byte >> shift) & 1)
      bitpos = bitpos + 1
    }
    st.cur.sample_sizes.push(v)
  }
}

///|
/// `mov_read_stco` / `mov_read_co64`. */
fn parse_stco(
  st : MovState,
  r : AvioContext,
  size : Int64,
  co64 : Bool,
) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let raw_entries = r.avio_rb32()
  let entry_size : Int64 = if co64 { 8 } else { 4 }
  // Clamp the declared count to what the atom can hold, as mov_read_stco does.
  let cap0 : Int64 = (size - 8) / entry_size
  let cap : Int64 = if cap0 < 0 { 0L } else { cap0 }
  let raw : Int64 = raw_entries.reinterpret_as_int().to_int64()
  let entries : Int32 = if raw < cap { raw.to_int() } else { cap.to_int() }
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    if co64 {
      let off = r.avio_rb64().reinterpret_as_int64()
      // An impossible (negative) chunk offset is clamped to 0, as in the C code.
      st.cur.chunk_offsets.push(if off < 0 { 0 } else { off })
    } else {
      st.cur.chunk_offsets.push(r.avio_rb32().to_int64())
    }
  }
}

///|
/// `mov_read_stss`: sync-sample (keyframe) table. */
fn parse_stss(st : MovState, r : AvioContext) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let entries = r.avio_rb32().reinterpret_as_int()
  if entries <= 0 {
    // An empty stss means every sample is a sync sample.
    st.cur.keyframe_absent = true
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    st.cur.keyframes.push(r.avio_rb32())
  }
}

///|
/// `mov_read_stps`: partial-sync (open-GOP) sample table. */
fn parse_stps(st : MovState, r : AvioContext) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.avio_rb32() // version + flags
  let entries = r.avio_rb32().reinterpret_as_int()
  if entries <= 0 {
    return
  }
  for i = 0; i < entries; i = i + 1 {
    if r.avio_feof() {
      break
    }
    st.cur.stps.push(r.avio_rb32())
  }
}

///|
/// `mov_read_sgpd`: 'sync' sample-group descriptions. Only the 'sync'
/// grouping type is consumed (one NAL unit type byte per entry); other types
/// ('tscl', 'tsas', 'stsa', …) are parsed past, as in the C.
fn parse_sgpd(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.avio_r8().reinterpret_as_int()
  let _ = r.avio_rb24() // flags
  let grouping_type = r.avio_rl32_tag()
  if grouping_type != "sync" {
    return
  }
  let default_length : Int64 = if version >= 1 {
    r.avio_rb32().to_int64()
  } else {
    0L
  }
  if version >= 2 {
    let _ = r.avio_rb32() // default_group_description_index
  }
  let entry_count = r.avio_rb32()
  if entry_count.to_int64() > size {
    raise InvalidData("SGPD entry count exceeds atom size")
  }
  st.cur.sgpd_sync.clear()
  for i = 0
      i < entry_count.reinterpret_as_int() && r.avio_feof() == false
      i = i + 1 {
    let mut description_length = default_length
    if version >= 1 && default_length == 0 {
      description_length = r.avio_rb32().to_int64()
    }
    // 'sync': one byte of NAL unit type, remaining description bytes skipped.
    st.cur.sgpd_sync.push(r.avio_r8() & 0x3F)
    let _ = r.avio_skip(description_length - 1L)
  }
  if r.avio_feof() {
    raise InvalidData("EOF in SGPD atom")
  }
}

///|
/// `mov_read_sbgp`: 'rap ' and 'sync' sample-to-group runs. Other grouping
/// types are ignored. The entry loop is capped by eof exactly as in C, so a
/// truncated atom yields the runs read so far.
fn parse_sbgp(st : MovState, r : AvioContext) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let version = r.avio_r8().reinterpret_as_int()
  let _ = r.avio_rb24() // flags
  let grouping_type = r.avio_rl32_tag()
  if grouping_type != "rap " && grouping_type != "sync" {
    return
  }
  if version == 1 {
    let _ = r.avio_rb32() // grouping_type_parameter
  }
  let entries = r.avio_rb32()
  if entries == 0 {
    return
  }
  let dst = if grouping_type == "rap " {
    st.cur.rap_group
  } else {
    st.cur.sync_group
  }
  dst.clear()
  for i = 0
      i < entries.reinterpret_as_int() && r.avio_feof() == false
      i = i + 1 {
    let count = r.avio_rb32()
    let index = r.avio_rb32()
    dst.push({ count, index, })
  }
  if r.avio_feof() {
    raise InvalidData("EOF in SBGP atom")
  }
}

///|
/// `mov_read_trak`: parse one track's boxes, then build its sample index. */
fn parse_trak(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  st.in_trak = true
  st.cur = new_track()
  parse_default(st, r, size)
  st.in_trak = false
  // mov_read_trak: stsc referring to chunks stco never describes is
  // overlooked (cleared) when the track has no samples at all.
  if st.cur.chunk_offsets.length() == 0 &&
    st.cur.stts.length() == 0 &&
    st.cur.stsc.length() > 0 {
    st.cur.stsc.clear()
  }
  // Advanced edit lists do not work with fragmented MP4 (empty stts ⇒ the
  // samples stream in via trun): disable before this track's build, so only
  // traks parsed earlier keep the advanced treatment — same order as the C.
  if st.cur.stts.length() == 0 && st.movie.advanced_editlist {
    st.movie.advanced_editlist = false
  }
  mov_build_index(st, st.cur)
  st.movie.tracks.push(st.cur)
}

// ---------------------------------------------------------------------------
// Fragmented MP4 (moof / traf / tfhd / tfdt / trun / trex)
// ---------------------------------------------------------------------------

///|
/// Look up a track by `track_id`, as mov_read_tfdt/trun do. */
fn mov_find_track(st : MovState, id : UInt32) -> Mp4Track? {
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
fn mov_update_dts_shift(track : Mp4Track, duration : Int32) -> Unit {
  if duration < 0 {
    let d : Int64 = duration.to_int64()
    let mag : Int64 = if d == -2147483648 { 2147483647 } else { -d }
    if mag.to_int() > track.dts_shift {
      track.dts_shift = mag.to_int()
    }
  }
}

///|
/// `mov_read_trex`: one track's fragment defaults. */
fn parse_trex(st : MovState, r : AvioContext) -> Unit {
  let _ = r.avio_r8() // version
  let _ = r.avio_rb24() // flags
  let track_id = r.avio_rb32()
  let stsd_id = r.avio_rb32()
  let duration = r.avio_rb32()
  let size = r.avio_rb32()
  let flags = r.avio_rb32()
  st.trex.push({ track_id, stsd_id, duration, size, flags, })
}

///|
/// `mov_read_moof`: reset fragment state and recurse into `traf`. */
fn parse_moof(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  st.frag.found_tfhd = false
  st.frag.has_tfdt = false
  let off = r.avio_tell() - 8
  st.frag.moof_offset = off
  st.frag.implicit_offset = off
  // While inside a moof, encryption boxes target the fragment's track
  // (get_current_encryption_info's frag_index.current path).
  st.in_moof = true
  parse_default(st, r, size)
  st.in_moof = false
}

///|
/// `mov_read_tfhd`: track fragment header; merges `trex` defaults. */
fn parse_tfhd(st : MovState, r : AvioContext) -> Unit {
  let _ = r.avio_r8() // version
  let flags = r.avio_rb24()
  let track_id = r.avio_rb32()
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
        r.avio_rb64().reinterpret_as_int64()
      } else if (flags & tfhd_default_base_is_moof) != 0 {
        st.frag.moof_offset
      } else {
        st.frag.implicit_offset
      }
      st.frag.stsd_id = if (flags & tfhd_stsd_id) != 0 {
        r.avio_rb32()
      } else {
        trex.stsd_id
      }
      st.frag.duration = if (flags & tfhd_default_duration) != 0 {
        r.avio_rb32()
      } else {
        trex.duration
      }
      st.frag.size = if (flags & tfhd_default_size) != 0 {
        r.avio_rb32()
      } else {
        trex.size
      }
      st.frag.flags = if (flags & tfhd_default_flags) != 0 {
        r.avio_rb32()
      } else {
        trex.flags
      }
    }
  }
}

///|
/// `mov_read_tfdt`: base media decode time for the current track fragment. */
fn parse_tfdt(st : MovState, r : AvioContext) -> Unit {
  // Fragments targeting a different sample description are skipped for this
  // track (the C returns before consuming the payload; the caller realigns).
  match mov_find_track(st, st.frag.track_id) {
    Some(track) =>
      if track.pseudo_stream_id != -1 &&
        (track.pseudo_stream_id + 1).reinterpret_as_uint() != st.frag.stsd_id {
        return
      }
    None => ()
  }
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  let bmdt : Int64 = if version != 0 {
    r.avio_rb64().reinterpret_as_int64()
  } else {
    r.avio_rb32().to_int64()
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
fn parse_trun(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  if !st.frag.found_tfhd {
    raise InvalidData("trun without tfhd")
  }
  match mov_find_track(st, st.frag.track_id) {
    None => ()
    Some(track) => {
      if track.pseudo_stream_id != -1 &&
        (track.pseudo_stream_id + 1).reinterpret_as_uint() != st.frag.stsd_id {
        return
      }
      let _ = r.avio_r8() // version
      let flags = r.avio_rb24()
      let mut entries = r.avio_rb32().reinterpret_as_int()
      let mut data_offset : Int32 = 0
      if (flags & trun_data_offset) != 0 {
        data_offset = r.avio_rb32().reinterpret_as_int()
      }
      let mut first_sample_flags = st.frag.flags
      if (flags & trun_first_sample_flags) != 0 {
        first_sample_flags = r.avio_rb32()
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
        let max_entries = if left < 0 {
          0L
        } else {
          left / entry_size.to_int64()
        }
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
      let mut distance : UInt32 = 0
      for i = 0; i < entries; i = i + 1 {
        if r.avio_feof() {
          break
        }
        let mut sample_size = st.frag.size
        let mut sample_flags = if i != 0 {
          st.frag.flags
        } else {
          first_sample_flags
        }
        let mut sample_duration = st.frag.duration
        let mut ctts : Int32 = 0
        if (flags & trun_sample_duration) != 0 {
          sample_duration = r.avio_rb32()
        }
        if (flags & trun_sample_size) != 0 {
          sample_size = r.avio_rb32()
        }
        if (flags & trun_sample_flags) != 0 {
          sample_flags = r.avio_rb32()
        }
        if (flags & trun_sample_cts) != 0 {
          ctts = r.avio_rb32().reinterpret_as_int()
        }
        mov_update_dts_shift(track, ctts)
        let keyframe = (
            sample_flags &
            (frag_sample_flag_is_non_sync | frag_sample_flag_depends_yes)
          ) ==
          0
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

///|
/// `mov_read_schm`: the protection scheme fourcc. */
fn parse_schm(st : MovState, r : AvioContext) -> Unit {
  if !st.in_trak {
    return
  }
  let _ = r.avio_rb32() // version and flags
  st.cur.cenc_scheme = r.avio_rb32()
}

///|
/// `mov_read_tenc`: pattern, per-sample IV size, default KID and constant IV. */
fn parse_tenc(st : MovState, r : AvioContext, size : Int64) -> Unit {
  if !st.in_trak {
    return
  }
  if size < 20 {
    return
  }
  let version = r.avio_r8()
  let _ = r.avio_rb24() // flags
  let _ = r.avio_r8() // reserved
  let pattern = r.avio_r8()
  if version > 0 {
    st.cur.cenc_crypt_byte_block = pattern >> 4
    st.cur.cenc_skip_byte_block = pattern & 0xF
  }
  let is_protected = r.avio_r8()
  let iv_size = r.avio_r8().reinterpret_as_int()
  st.cur.cenc_per_sample_iv_size = iv_size
  for i = 0; i < 16; i = i + 1 {
    // Default key ID; not needed when the key is supplied directly.
    let _ = r.avio_r8()
  }
  if is_protected != 0 && iv_size == 0 {
    let constant_size = r.avio_r8().reinterpret_as_int()
    let iv = FixedArray::make(16, b'\x00')
    let n = if constant_size < 16 { constant_size } else { 16 }
    for i = 0; i < n; i = i + 1 {
      iv[i] = r.avio_r8().to_byte()
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
fn parse_senc(
  st : MovState,
  r : AvioContext,
  size : Int64,
) -> Unit raise MovError {
  match current_enc_track(st) {
    None => ()
    Some(track) => {
      let _ = size
      let _ = r.avio_r8() // version
      let flags = r.avio_rb24()
      let use_subsamples = (flags & 0x02) != 0
      let sample_count = r.avio_rb32().reinterpret_as_int()
      let per_iv = track.cenc_per_sample_iv_size
      for i = 0; i < sample_count; i = i + 1 {
        if r.avio_feof() {
          raise InvalidData("EOF in senc")
        }
        if per_iv != 0 || use_subsamples {
          let iv = FixedArray::make(16, b'\x00')
          if per_iv != 0 {
            for k = 0; k < per_iv; k = k + 1 {
              iv[k] = r.avio_r8().to_byte()
            }
          }
          let subs : Array[MovSubSample] = []
          if use_subsamples {
            let n = r.avio_rb16().reinterpret_as_int()
            for k = 0; k < n; k = k + 1 {
              if r.avio_feof() {
                raise InvalidData("EOF in senc subsamples")
              }
              let clear = r.avio_rb16().reinterpret_as_int()
              let prot = r.avio_rb32().reinterpret_as_int()
              subs.push({ bytes_of_clear: clear, bytes_of_protected: prot, })
            }
          }
          track.cenc_samples.push(Some({ iv, subsamples: subs, }))
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
  r : AvioContext,
  per_iv : Int32,
  use_subsamples : Bool,
) -> MovEncSample {
  let iv = FixedArray::make(16, b'\x00')
  if per_iv != 0 {
    for k = 0; k < per_iv; k = k + 1 {
      iv[k] = r.avio_r8().to_byte()
    }
  }
  let subs : Array[MovSubSample] = []
  if use_subsamples {
    let n = r.avio_rb16().reinterpret_as_int()
    for k = 0; k < n; k = k + 1 {
      let clear = r.avio_rb16().reinterpret_as_int()
      let prot = r.avio_rb32().reinterpret_as_int()
      subs.push({ bytes_of_clear: clear, bytes_of_protected: prot, })
    }
  }
  { iv, subsamples: subs, }
}

///|
/// `mov_parse_auxiliary_info`: with both `saiz` and `saio` present, read the
/// per-sample encryption info from the auxiliary chunk. The reader position
/// is restored afterwards, as the C does with `prev_pos`.
fn mov_parse_auxiliary_info(
  track : Mp4Track,
  r : AvioContext,
) -> Unit raise MovError {
  if track.cenc_samples.length() > 0 {
    return
  }
  let sample_count = track.aux_info_sample_count
  if track.aux_info_offsets.length() != 1 {
    raise InvalidData("multiple auxiliary info chunks unsupported")
  }
  let prev_pos = r.avio_tell()
  let _ = r.avio_seek(track.aux_info_offsets[0], SEEK_SET)
  for i = 0; i < sample_count && !r.avio_feof(); i = i + 1 {
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
  if r.avio_feof() {
    raise InvalidData("EOF in auxiliary info")
  }
  let _ = r.avio_seek(prev_pos, SEEK_SET)
}

///|
/// `mov_read_saiz`: per-sample sizes of the auxiliary info chunk. The
/// `aux_info_type` filtering of the C reduces here to accepting the box only
/// when the track already carries encryption metadata.
fn parse_saiz(st : MovState, r : AvioContext) -> Unit raise MovError {
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
      let _ = r.avio_r8() // version
      let flags = r.avio_rb24()
      if (flags & 0x01) != 0 {
        let _ = r.avio_rb32() // aux_info_type
        let _ = r.avio_rb32() // aux_info_type_parameter
      }
      track.aux_info_default_size = r.avio_r8().reinterpret_as_int()
      let sample_count = r.avio_rb32().reinterpret_as_int()
      if track.aux_info_default_size == 0 {
        if sample_count == 0 {
          raise InvalidData("saiz without sizes")
        }
        for i = 0; i < sample_count; i = i + 1 {
          track.aux_info_sizes.push(r.avio_r8())
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
fn parse_saio(st : MovState, r : AvioContext) -> Unit raise MovError {
  match current_enc_track(st) {
    None => ()
    Some(track) => {
      if track.cenc_samples.length() > 0 {
        return
      }
      if track.aux_info_offsets.length() > 0 {
        raise InvalidData("duplicate saio")
      }
      let version = r.avio_r8().reinterpret_as_int()
      let flags = r.avio_rb24()
      if (flags & 0x01) != 0 {
        let _ = r.avio_rb32() // aux_info_type
        let _ = r.avio_rb32() // aux_info_type_parameter
      }
      let entry_count = r.avio_rb32().reinterpret_as_int()
      for i = 0; i < entry_count && !r.avio_feof(); i = i + 1 {
        let off = if version == 0 {
          r.avio_rb32().to_int64()
        } else {
          r.avio_rb64().reinterpret_as_int64()
        }
        let abs = if st.in_moof { off + st.frag.base_data_offset } else { off }
        track.aux_info_offsets.push(abs)
      }
      if r.avio_feof() {
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
  size : Int32,
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
  size : Int32,
) -> Result[Unit, String] {
  let aes = @libavutil.av_aes_alloc()
  match @libavutil.av_aes_init(aes, key, 128, true) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let ivbuf : FixedArray[Byte] = iv.copy()
  if subs.length() == 0 {
    let blocks = size / 16
    let dec = @libavutil.av_aes_crypt(
      aes,
      Bytes::from_array(out[:]),
      blocks,
      Some(ivbuf),
    )
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

///|
/// `cens_scheme_decrypt`: AES-CTR with a crypt/skip block pattern. */
fn cens_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  cb : UInt32,
  sb : UInt32,
  out : Array[Byte],
  size : Int32,
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

///|
/// `cbcs_scheme_decrypt`: AES-CBC with a crypt/skip block pattern; the IV resets per subsample. */
fn cbcs_decrypt(
  key : Bytes,
  iv : FixedArray[Byte],
  subs : Array[MovSubSample],
  cb : UInt32,
  sb : UInt32,
  out : Array[Byte],
  size : Int32,
) -> Result[Unit, String] {
  let aes = @libavutil.av_aes_alloc()
  match @libavutil.av_aes_init(aes, key, 128, true) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if subs.length() == 0 {
    let ivbuf : FixedArray[Byte] = iv.copy()
    let blocks = size / 16
    let dec = @libavutil.av_aes_crypt(
      aes,
      Bytes::from_array(out[:]),
      blocks,
      Some(ivbuf),
    )
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
  index : Int32,
  key : Bytes,
  payload : Bytes,
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
    None => { iv: track.cenc_default_iv.copy(), subsamples: [], }
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
  let q1024 : UInt32 = 1024
  let q1023 : UInt32 = 1023
  // Compute the total packet count, exactly like the C first pass.
  let mut total : UInt32 = 0
  for i = 0; i < track.stsc.length(); i = i + 1 {
    let chunk_samples = track.stsc[i].count.reinterpret_as_uint()
    if i != track.stsc.length() - 1 && spf != 0 && chunk_samples % spf != 0 {
      // error unaligned chunk
      return
    }
    let count : UInt32 = if spf >= 160 {
      // gsm
      chunk_samples / spf
    } else if spf > 1 {
      let samples = q1024 / spf * spf
      (chunk_samples + samples - 1) / samples
    } else {
      (chunk_samples + q1023) / q1024
    }
    let chunk_count : UInt32 = if mov_stsc_index_valid(i, track.stsc.length()) {
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
      let (samples, size) : (UInt32, UInt32) = if spf >= 160 {
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
  let tts : Array[MovTts] = Array::make(n, { count: 0, offset: 0, duration: 0, })
  let mut idx = 0
  if has_ctts {
    for i = 0; i < track.ctts.length(); i = i + 1 {
      let e = track.ctts[i]
      let mut j = 0
      while j < e.count && idx < n {
        tts[idx] = { count: 1, offset: e.offset, duration: 0, }
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
        tts[idx] = { count: 1, offset: prev.offset, duration: e.duration, }
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

///|
/// `HEVC_NAL_CRA_NUT` (libavcodec/hevc.h): Clean Random Access NAL type. */
let hevc_nal_cra_nut : UInt32 = 21

///|
/// `get_sgpd_sync_index`: the 1-based index of the first 'sync' entry whose
/// NAL unit type matches, 0 when absent.
fn get_sgpd_sync_index(track : Mp4Track, nal_unit_type : UInt32) -> UInt32 {
  for i = 0; i < track.sgpd_sync.length(); i = i + 1 {
    if track.sgpd_sync[i] == nal_unit_type {
      return (i + 1).reinterpret_as_uint()
    }
  }
  0
}

///|
/// `is_open_key_sample`: linear scan with the C's monotonic early break. */
fn is_open_key_sample(track : Mp4Track, sample : Int32) -> Bool {
  for i = 0; i < track.open_key_samples.length(); i = i + 1 {
    let oks = track.open_key_samples[i]
    if oks == sample {
      return true
    }
    if oks > sample {
      break // list is monotonically increasing so we can stop early
    }
  }
  false
}

///|
/// `get_edit_list_entry`: fetch edit `edit_list_index` (media time, duration
/// rescaled from the movie to the track timescale). `None` ends the walk.
fn get_edit_list_entry(
  movie : Mp4Movie,
  track : Mp4Track,
  edit_list_index : Int32,
) -> (Int64, Int64)? {
  if edit_list_index == track.elst.length() {
    return None
  }
  let media_time = track.elst[edit_list_index].time
  let mut duration = track.elst[edit_list_index].duration
  if movie.timescale == 0 {
    return None
  }
  duration = mov_rescale(duration, track.timescale, movie.timescale)
  // `duration + (uint64_t)media_time > INT64_MAX` with wrapping u64 math:
  // media_time -1 (empty edit) wraps around and keeps the duration.
  let sum = duration.reinterpret_as_uint64() +
    media_time.reinterpret_as_uint64()
  if sum > 9223372036854775807UL {
    duration = 0L
  }
  Some((media_time, duration))
}

///|
/// `find_prev_closest_index`: the closest previous frame to a PTS in the old
/// index — keyframes only when ctts is present (B-frame reordering), with
/// the C's backward refinement over `timestamp + ctts offset`. Returns
/// `(index, tts_index, tts_sample)` or `None` when nothing is before it.
fn find_prev_closest_index(
  track : Mp4Track,
  e_old : Array[Mp4Sample],
  tts_old : Array[MovTts],
  timestamp_pts_in : Int64,
  flag : Int32,
) -> (Int32, Int32, Int32)? {
  let mut timestamp_pts = timestamp_pts_in
  // With dts_shift > 0 every index timestamp needs it added to become a PTS,
  // so compensate the searched timestamp instead.
  if track.dts_shift > 0 {
    timestamp_pts = timestamp_pts - track.dts_shift.to_int64()
  }
  let mut index = index_search_timestamp(
    e_old,
    timestamp_pts,
    flag | avseek_flag_backward,
  )
  // Keep going backwards while the timestamp repeats.
  if index >= 0 {
    let mut i = index
    while i > 0 && e_old[i].dts == e_old[i - 1].dts {
      if (flag & avseek_flag_any) != 0 || e_old[i - 1].keyframe {
        index = i - 1
      }
      i = i - 1
    }
  }
  let mut tts_index = 0
  let mut tts_sample = 0
  if track.has_ctts && index >= 0 {
    // tts position of the found frame
    let mut counted = 0
    while counted < index {
      if tts_index < tts_old.length() {
        tts_sample = tts_sample + 1
        if tts_old[tts_index].count == tts_sample {
          tts_index = tts_index + 1
          tts_sample = 0
        }
      }
      counted = counted + 1
    }
    // Walk back to a keyframe whose PTS (timestamp + ctts offset) fits.
    while index >= 0 && tts_index >= 0 && tts_index < tts_old.length() {
      if e_old[index].dts + tts_old[tts_index].offset.to_int64() <=
        timestamp_pts &&
        e_old[index].keyframe {
        break
      }
      index = index - 1
      if tts_sample == 0 {
        tts_index = tts_index - 1
        if tts_index >= 0 {
          tts_sample = tts_old[tts_index].count - 1
        }
      } else {
        tts_sample = tts_sample - 1
      }
    }
  }
  if index < 0 {
    None
  } else {
    Some((index, tts_index, tts_sample))
  }
}

///|
/// `fix_index_entry_timestamps`: rewrite the timestamps of the last
/// `frame_duration_buffer.length()` entries by stepping `end_ts` backwards
/// through the buffered durations, so discarded leading frames get strictly
/// increasing timestamps before the edit starts.
fn fix_index_entry_timestamps(
  entries : Array[Mp4Sample],
  end_ts_in : Int64,
  frame_duration_buffer : Array[Int64],
) -> Unit {
  let mut end_ts = end_ts_in
  for i = 0; i < frame_duration_buffer.length(); i = i + 1 {
    end_ts = end_ts -
      frame_duration_buffer[frame_duration_buffer.length() - 1 - i]
    entries[entries.length() - 1 - i].dts = end_ts
  }
}

///|
/// `mov_fix_index`: rebuild the sample index so it contains only the frames
/// (plus what is needed to decode them) inside the edit-list time ranges,
/// with timestamps rewritten to the edit-list timeline. The rebuilt
/// `tts` runs replace the merged ones; `min_corrected_pts`, `skip_samples`,
/// `start_time` and the duration clamp are set as in the C. The C's
/// `index_ranges` (old→new sample mapping for the demux cursor) are not
/// modelled: this port materialises the filtered index directly.
fn mov_fix_index(st : MovState, track : Mp4Track) -> Unit {
  let e_old = track.samples
  let nb_old = e_old.length()
  if track.elst.length() <= 0 || nb_old <= 0 {
    return
  }
  let tts_old = track.tts
  let tts_count_old = tts_old.length()
  let mut tts_index_old : Int32 = 0
  let mut tts_sample_old : Int32 = 0
  let mut edit_list_dts_entry_end : Int64 = 0
  let mut empty_edits_sum_duration : Int64 = 0
  let mut num_discarded_begin = 0
  let mut first_non_zero_audio_edit = -1
  let mut frame_duration_buffer : Array[Int64] = []
  let new_samples : Array[Mp4Sample] = []
  let new_tts : Array[MovTts] = []
  let mut min_corrected_pts : Int64 = -1
  let mut found_non_empty_edit = false
  // Reinitialise min_corrected_pts so it can be computed again.
  // If dts_shift is positive (negative ctts), negate the DTS by it.
  if track.dts_shift > 0 {
    edit_list_dts_entry_end = edit_list_dts_entry_end -
      track.dts_shift.to_int64()
  }
  let start_dts = edit_list_dts_entry_end
  let mut edit_list_index = 0
  let mut stop_outer = false
  while stop_outer == false {
    let (edit_list_media_time, edit_list_duration) = match
      get_edit_list_entry(st.movie, track, edit_list_index) {
      None => break
      Some(v) => v
    }
    edit_list_index = edit_list_index + 1
    let mut edit_list_dts_counter = edit_list_dts_entry_end
    edit_list_dts_entry_end = sat_add64(
      edit_list_dts_entry_end, edit_list_duration,
    )
    if edit_list_dts_entry_end == 9223372036854775807L {
      stop_outer = true
      break
    }
    num_discarded_begin = 0
    if found_non_empty_edit == false && edit_list_media_time == -1 {
      empty_edits_sum_duration = empty_edits_sum_duration + edit_list_duration
      continue
    }
    found_non_empty_edit = true
    // A non-negative edit resets the skip_samples bookkeeping for audio.
    if media_is_audio(track.media_type) {
      if first_non_zero_audio_edit < 0 {
        first_non_zero_audio_edit = 1
      } else {
        first_non_zero_audio_edit = 0
      }
      if first_non_zero_audio_edit > 0 {
        track.skip_samples = 0
      }
    }
    // Start from the closest previous key frame; audio searches a second
    // earlier to cover decoder delay.
    let mut search_timestamp = edit_list_media_time
    if media_is_audio(track.media_type) {
      let back = search_timestamp - track.timescale.to_int64()
      search_timestamp = if back > e_old[0].dts { back } else { e_old[0].dts }
    }
    let found = match
      find_prev_closest_index(track, e_old, tts_old, search_timestamp, 0) {
      Some(v) => Some(v)
      None =>
        // fall back to any frame, then to the first frame of the track
        match
          find_prev_closest_index(
            track, e_old, tts_old, search_timestamp, avseek_flag_any,
          ) {
          Some(v) => Some(v)
          None => {
            tts_index_old = 0
            tts_sample_old = 0
            Some((0, 0, 0))
          }
        }
    }
    match found {
      None => {
        tts_index_old = 0
        tts_sample_old = 0
      }
      Some((i0, ti0, ts0)) => {
        tts_index_old = ti0
        tts_sample_old = ts0
        let mut index = i0
        let mut edit_list_start_tts_sample = tts_sample_old
        let mut edit_list_start_encountered = false
        let mut found_keyframe_after_edit = false
        // Iterate over the old index and arrange it according to the edit.
        let mut stop_inner = false
        while index < nb_old && stop_inner == false {
          let current = index
          let frame_duration : Int64 = if current + 1 < nb_old {
            e_old[current + 1].dts - e_old[current].dts
          } else {
            edit_list_duration
          }
          let keyframe = e_old[current].keyframe
          let mut discard = false
          let mut curr_cts = e_old[current].dts + track.dts_shift.to_int64()
          let mut curr_ctts : Int64 = 0
          if tts_count_old > 0 && tts_index_old < tts_count_old {
            curr_ctts = tts_old[tts_index_old].offset.to_int64()
            curr_cts = curr_cts + curr_ctts
            tts_sample_old = tts_sample_old + 1
            if tts_sample_old == tts_old[tts_index_old].count {
              new_tts.push({
                count: tts_old[tts_index_old].count - edit_list_start_tts_sample,
                offset: tts_old[tts_index_old].offset,
                duration: tts_old[tts_index_old].duration,
              })
              tts_index_old = tts_index_old + 1
              tts_sample_old = 0
              edit_list_start_tts_sample = 0
            }
          }
          if curr_cts < edit_list_media_time ||
            curr_cts >= edit_list_duration + edit_list_media_time {
            if media_is_audio(track.media_type) &&
              track.codec_id != "vorbis" &&
              curr_cts < edit_list_media_time &&
              curr_cts + frame_duration > edit_list_media_time &&
              first_non_zero_audio_edit > 0 {
              // A partial frame at the edit start: keep it, trim
              // `skip_samples` leading samples and shift its timestamp.
              let packet_skip_samples = edit_list_media_time - curr_cts
              track.skip_samples = track.skip_samples +
                packet_skip_samples.to_int()
              edit_list_dts_counter = edit_list_dts_counter -
                packet_skip_samples
              if edit_list_start_encountered == false {
                edit_list_start_encountered = true
                if frame_duration_buffer.length() > 0 {
                  fix_index_entry_timestamps(
                    new_samples, edit_list_dts_counter, frame_duration_buffer,
                  )
                  frame_duration_buffer = []
                }
              }
            } else {
              discard = true
              if edit_list_start_encountered == false {
                num_discarded_begin = num_discarded_begin + 1
                frame_duration_buffer.push(frame_duration)
                if media_is_audio(track.media_type) &&
                  first_non_zero_audio_edit > 0 &&
                  track.codec_id != "vorbis" {
                  track.skip_samples = track.skip_samples +
                    frame_duration.to_int()
                }
              }
            }
          } else {
            // inside the edit: track the minimum corrected PTS
            let cand = edit_list_dts_counter +
              curr_ctts +
              track.dts_shift.to_int64()
            if min_corrected_pts < 0 {
              min_corrected_pts = cand
            } else if cand < min_corrected_pts {
              min_corrected_pts = cand
            }
            if edit_list_start_encountered == false {
              edit_list_start_encountered = true
              if frame_duration_buffer.length() > 0 {
                fix_index_entry_timestamps(
                  new_samples, edit_list_dts_counter, frame_duration_buffer,
                )
                frame_duration_buffer = []
              }
            }
          }
          new_samples.push({
            offset: e_old[current].offset,
            size: e_old[current].size,
            dts: edit_list_dts_counter,
            pts: e_old[current].pts,
            duration: e_old[current].duration,
            keyframe,
            min_distance: e_old[current].min_distance,
            discard,
          })
          // Only advance the timeline once the edit window started.
          if edit_list_start_encountered {
            edit_list_dts_counter = edit_list_dts_counter + frame_duration
          }
          // Break on the first key frame completing the edit entry.
          if curr_cts + frame_duration >=
            edit_list_duration + edit_list_media_time &&
            (keyframe || media_is_audio(track.media_type)) {
            if track.has_ctts {
              // With CTTS, wait one extra keyframe for trailing B-frames.
              if media_is_video(track.media_type) &&
                found_keyframe_after_edit == false {
                found_keyframe_after_edit = true
                index = index + 1
                continue
              }
              if tts_sample_old != 0 {
                new_tts.push({
                  count: tts_sample_old - edit_list_start_tts_sample,
                  offset: tts_old[tts_index_old].offset,
                  duration: tts_old[tts_index_old].duration,
                })
              }
            }
            stop_inner = true
          }
          index = index + 1
        }
      }
    }
  }
  // Empty edits intentionally raise min_corrected_pts; subtract them back.
  min_corrected_pts = min_corrected_pts - empty_edits_sum_duration
  track.min_corrected_pts = min_corrected_pts
  // Video: offset the DTS so the first PTS becomes zero.
  if media_is_video(track.media_type) && min_corrected_pts > 0 {
    for i = 0; i < new_samples.length(); i = i + 1 {
      new_samples[i].dts = new_samples[i].dts - min_corrected_pts
    }
  }
  // Start time equals the duration of any empty edits.
  track.start_time = empty_edits_sum_duration
  // The stream cannot be longer than the edit list timeline.
  let span = edit_list_dts_entry_end - start_dts
  if span >= 0 && track.duration > span.reinterpret_as_uint64() {
    track.duration = span.reinterpret_as_uint64()
  }
  // Install the rebuilt index and tts (in place for the non-mut samples
  // array; the tts field is reassignable).
  track.samples.clear()
  for i = 0; i < new_samples.length(); i = i + 1 {
    track.samples.push(new_samples[i])
  }
  track.tts = new_tts
  // The C derives presentation timestamps at demux from the rebuilt tts
  // (`dts + dts_shift + tts.offset`); materialise them the same way.
  let mut si = 0
  for ti = 0; ti < track.tts.length(); ti = ti + 1 {
    for j = 0; j < track.tts[ti].count; j = j + 1 {
      if si >= track.samples.length() {
        break
      }
      track.samples[si].pts = track.samples[si].dts +
        track.dts_shift.to_int64() +
        track.tts[ti].offset.to_int64()
      si = si + 1
    }
  }
}

///|
/// `mov_estimate_video_delay`: H264 reorder estimate — insertion-sorts the
/// PTS stream through a 17-slot circular buffer and records the maximum
/// number of swaps any frame needed (the C keys on AV_CODEC_ID_H264; this
/// port keys on the `avc1` sample-entry fourcc).
fn mov_estimate_video_delay(track : Mp4Track) -> Unit {
  if track.video_delay > 0 || track.has_ctts == false || track.codec != "avc1" {
    return
  }
  let pts_buf : FixedArray[Int64] = FixedArray::make(17, av_nopts_value)
  let mut buf_start = 0
  let mut ctts_ind = 0
  let mut ctts_sample = 0
  track.video_delay = 0
  let mut ind = 0
  while ind < track.samples.length() && ctts_ind < track.tts.length() {
    let mut j = buf_start
    buf_start = buf_start + 1
    if buf_start == 17 {
      buf_start = 0
    }
    pts_buf[j] = track.samples[ind].dts + track.tts[ctts_ind].offset.to_int64()
    let mut num_swaps = 0
    while j != buf_start {
      let mut r = j - 1
      if r < 0 {
        r = 16
      }
      if pts_buf[j] < pts_buf[r] {
        let tmp = pts_buf[j]
        pts_buf[j] = pts_buf[r]
        pts_buf[r] = tmp
        num_swaps = num_swaps + 1
      } else {
        break
      }
      j = r
    }
    if num_swaps > track.video_delay {
      track.video_delay = num_swaps
    }
    ctts_sample = ctts_sample + 1
    if ctts_sample == track.tts[ctts_ind].count {
      ctts_ind = ctts_ind + 1
      ctts_sample = 0
    }
    ind = ind + 1
  }
}

///|
/// `build_open_gop_key_points`: open-GOP bookkeeping for HEVC tracks with
/// 'sync' sample groups — unrolled per-sample ctts offsets, the CRA sample
/// list and the minimal stts duration used by the seek back-off.
fn build_open_gop_key_points(track : Mp4Track) -> Unit {
  let hevc = track.codec == "hvc1" || track.codec == "hev1"
  if !hevc || track.sync_group.length() == 0 {
    return
  }
  // Build an unrolled index of the samples (per-sample ctts offsets).
  track.sample_offsets.clear()
  for i = 0; i < track.ctts.length(); i = i + 1 {
    for j = 0; j < track.ctts[i].count; j = j + 1 {
      track.sample_offsets.push(track.ctts[i].offset)
    }
  }
  let cra_index = get_sgpd_sync_index(track, hevc_nal_cra_nut)
  if cra_index == 0 {
    return
  }
  // Build a list of open-GOP key samples.
  track.open_key_samples.clear()
  let mut sample_id = 0
  for i = 0; i < track.sync_group.length(); i = i + 1 {
    let sg = track.sync_group[i]
    if sg.index == cra_index {
      for j = 0; j < sg.count.reinterpret_as_int(); j = j + 1 {
        track.open_key_samples.push(sample_id)
      }
    }
    sample_id = sample_id + sg.count.reinterpret_as_int()
  }
  // Identify the minimal time step between samples.
  let mut min_dur : UInt32 = 4294967295
  for i = 0; i < track.stts.length(); i = i + 1 {
    if track.stts[i].duration < min_dur {
      min_dur = track.stts[i].duration
    }
  }
  track.min_sample_duration = min_dur
}

///|
fn mov_build_index(st : MovState, track : Mp4Track) -> Unit raise MovError {
  let mut current_dts : Int64 = 0
  let mut stsc_index = 0
  let mut stss_index = 0
  let mut stps_index = 0

  // Edit list pre-pass (mov_build_index head): collect the empty-edit
  // duration and media start time; with advanced_editlist the DTS shift is
  // deferred to mov_fix_index at the end of the build instead.
  if track.elst.length() > 0 {
    let mut empty_duration : Int64 = 0
    let mut start_time : Int64 = 0
    let mut edit_start_index = 0
    let mut multiple_edits = false
    for i = 0; i < track.elst.length(); i = i + 1 {
      let e = track.elst[i]
      if i == 0 && e.time == -1 {
        // An empty first edit carries the stream start time in movie timebase.
        empty_duration = e.duration
        edit_start_index = 1
      } else if i == edit_start_index && e.time >= 0 {
        start_time = e.time
      } else {
        multiple_edits = true
      }
    }
    if (empty_duration != 0 || start_time != 0) && st.movie.timescale > 0 {
      if empty_duration != 0 {
        empty_duration = mov_rescale(
          empty_duration,
          track.timescale,
          st.movie.timescale,
        )
      }
      track.time_offset = start_time - empty_duration
      track.min_corrected_pts = start_time
      if st.movie.advanced_editlist == false {
        current_dts = -mov_clip64(track.time_offset)
      }
    }
    // Non-advanced AAC with a positive start: encoder delay as padding.
    if multiple_edits == false &&
      st.movie.advanced_editlist == false &&
      track.codec_id == "aac" &&
      start_time > 0 &&
      track.sample_rate > 0 {
      track.skip_samples = mov_rescale(
        start_time,
        track.sample_rate,
        track.timescale,
      ).to_int()
    }
  }

  // Set the primary extradata based on the first Sample if it doesn't
  // reference the first stsd entry (mov_read_header's last_stsd pass).
  if track.stsc.length() > 0 &&
    track.stsd_extradata.length() > 0 &&
    track.stsc[0].id > 1 &&
    track.stsc[0].id.reinterpret_as_uint() <=
    track.stsd_count.reinterpret_as_uint() {
    let idx = track.stsc[0].id - 1
    track.last_stsd_index = idx
    // The C frees the old extradata before re-assigning from the slot, so an
    // unwritten slot clears it instead of keeping slot 0's bytes.
    track.extradata = if idx < track.stsd_extradata.length() {
      track.stsd_extradata[idx]
    } else {
      None
    }
  }
  // `build_open_gop_key_points` unrolls the ctts offsets, collects the
  // open-GOP (CRA) key samples and the minimal stts duration for the seek
  // back-off; it early-returns untouched unless the track is HEVC with
  // 'sync' groups, so min_sample_duration stays 0 in the common case (the
  // FFMAX(min_sample_duration, 1) in the seek back-off covers it, as in C).
  build_open_gop_key_points(track)

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
  if track.sample_count <= 0 ||
    track.tts.length() == 0 ||
    track.stsc.length() == 0 ||
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
  let mut distance : UInt32 = 0
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
      track.stsc[stsc_index].count.to_int64() *
      track.stsz_sample_size.to_int64() >
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
        (
          track.keyframes.length() == 0 ||
          (current_sample + key_off).reinterpret_as_uint() ==
          track.keyframes[stss_index]
        ) {
        keyframe = true
        if stss_index + 1 < track.keyframes.length() {
          stss_index = stss_index + 1
        }
      } else if track.stps.length() > 0 &&
        (current_sample + key_off).reinterpret_as_uint() ==
        track.stps[stps_index] {
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
      // `sc->pseudo_stream_id == -1 || stsc.id - 1 == pseudo_stream_id`:
      // -1 (a same-fourcc multi entry was parsed) indexes everything, else
      // only the entry's own chunks join the index. The `id - 1` wraps in
      // unsigned arithmetic exactly as in C (id 0 never matches).
      if track.pseudo_stream_id == -1 ||
        track.stsc[stsc_index].id - 1 == track.pseudo_stream_id {
        let pts = if track.has_ctts {
          current_dts +
          track.dts_shift.to_int64() +
          track.tts[stts_index].offset.to_int64()
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
      if stts_index + 1 < track.tts.length() &&
        stts_sample == track.tts[stts_index].count {
        stts_sample = 0
        stts_index = stts_index + 1
      }
    }
  }

  // Fix index according to edit lists (advanced path).
  if st.movie.advanced_editlist {
    mov_fix_index(st, track)
  }
  // Update start time of the stream.
  if track.start_time == av_nopts_value &&
    media_is_video(track.media_type) &&
    track.samples.length() > 0 {
    track.start_time = track.samples[0].dts + track.dts_shift.to_int64()
    if track.tts.length() > 0 {
      track.start_time = track.start_time + track.tts[0].offset.to_int64()
    }
  }
  mov_estimate_video_delay(track)
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
  mov_open(AvioContext::init_read_context(buf))
}

///|
/// `av_mov_open` with the `advanced_editlist` demuxer option (FFmpeg default
/// on). Turning it off selects the plain first-DTS-shift edit-list handling.
pub fn av_mov_open_with(
  buf : Bytes,
  advanced_editlist : Bool,
) -> Result[Mp4Movie, String] {
  mov_open(AvioContext::init_read_context(buf), advanced=advanced_editlist)
}

///|
/// Streaming entry point: the same walk over a caller-supplied `AVIOContext`
/// (file/network source). The whole-file wrapper above is now just
/// `init_read_context` plus this.
pub fn av_mov_open_avio(pb : AvioContext) -> Result[Mp4Movie, String] {
  mov_open(pb)
}

///|
fn mov_open(
  r : AvioContext,
  advanced~ : Bool = true,
) -> Result[Mp4Movie, String] {
  let movie = new_movie()
  movie.advanced_editlist = advanced
  let st : MovState = {
    movie,
    cur: new_track(),
    in_trak: false,
    in_moof: false,
    trex: [],
    frag: new_frag(),
  }
  // Unknown size (non-seekable source): treat as unbounded, stop on eof.
  let total = r.avio_size().unwrap_or(9223372036854775807L)
  try {
    let mut consumed : Int64 = 0
    while consumed <= total - 8 {
      let box_start = r.avio_tell()
      let size32 = r.avio_rb32().to_int64()
      let kind = r.avio_rl32_tag()
      if r.avio_feof() {
        break
      }
      let mut header : Int64 = 8
      let mut size = size32
      if size32 == 1 {
        size = r.avio_rb64().reinterpret_as_int64()
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
      let left = payload - (r.avio_tell() - box_start - header)
      if left != 0 {
        let _ = r.avio_skip(left)
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
