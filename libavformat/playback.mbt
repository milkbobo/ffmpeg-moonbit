///|
/// The unified playback API (proposal deliverable ①), audio-line first slice:
/// `MediaFile::open` probes a byte buffer with the §270 format-probe layer,
/// opens the matching demuxer and exposes every stream as a `StreamInfo`, and
/// `next_packet` walks the container's packets in stream order. On top of that
/// `AudioDecoder::open` dispatches the stream's codec to the ported decoder
/// and `decode` turns packets into `AudioFrame`s - the pipeline the JSON CLI's
/// `decode-audio` command and `libswresample` slice build on.
///
/// The adapters keep each demuxer's own semantics: MP4 samples are sliced from
/// the file buffer at their `stco` offsets and merged across tracks by DTS
/// (the C's `AVPacket.stream_index` ordering), Matroska/Ogg packets come out
/// of the demuxers' own queues, and WAV packets are the data-chunk slices the
/// packetiser already laid out.
///
/// Errors are a closed taxonomy (`MediaError`) instead of strings, so callers
/// can match on the failure class; the human-readable detail rides along.

///|
/// The failure classes of the playback pipeline.
pub(all) suberror MediaError {
  /// The probe layer found no matching demuxer.
  FormatNotFound
  /// A demuxer matched but this build has no adapter for it yet.
  UnsupportedFormat(String)
  /// The container failed to open (truncated, malformed, ...).
  DemuxError(String)
  /// The stream's codec has no decoder wired into the facade yet.
  UnsupportedCodec(String)
  /// A packet failed to decode.
  DecodeError(String)
} derive(Debug)

///|
pub extend MediaError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Render the error the way a CLI would print it.
pub fn MediaError::message(self : MediaError) -> String {
  match self {
    FormatNotFound => "Format not found"
    UnsupportedFormat(f) => "Unsupported format: \{f}"
    DemuxError(e) => "Demux error: \{e}"
    UnsupportedCodec(c) => "Unsupported codec: \{c}"
    DecodeError(e) => "Decode error: \{e}"
  }
}

///|
/// The kind of an elementary stream.
pub(all) enum MediaType {
  Audio
  Video
  Subtitle
} derive(Eq)

///|
pub extend MediaType with Eq::{not_equal, equal}

///|
/// One elementary stream's parameters, the subset the facade's consumers
/// need (the per-codec decoders read the rest from `extradata`).
pub(all) struct StreamInfo {
  index : Int32
  media_type : MediaType
  /// FFmpeg codec name ("aac", "opus", "pcm_s16le", "h264", ...).
  codec_id : String
  /// Audio only (0 on other streams).
  sample_rate : Int32
  channels : Int32
  /// Video only (0 on other streams).
  width : Int32
  height : Int32
  extradata : Bytes?
} derive(Eq)

///|
pub extend StreamInfo with Eq::{not_equal, equal}

///|
/// One compressed packet as the container delivered it.
pub(all) struct MediaPacket {
  stream_index : Int32
  data : Bytes
  pts : Int64
  keyframe : Bool
}

///|
/// One decoded audio frame: `samples[channel][i]` in `[-1, 1)` float range.
pub struct AudioFrame {
  samples : Array[Array[Double]]
  nb_samples : Int32
  sample_rate : Int32
  /// The source packet's presentation timestamp (container units), when the
  /// container carries one.
  pts : Int64?
}

///|
/// The demuxer behind a `MediaFile`.
pub(all) enum Source {
  Mov(Mp4Movie, Bytes)
  Mkv(MatroskaHeader)
  OggOpus(OggOpusDemux)
  Wav(WavDemux, Bytes)
  /// The demuxer plus, per stream, the next interpolated AAC timestamp
  /// (`ts_nopts` until the first PES timestamp is seen).
  Ts(TsDemux, Array[Int64])
}

///|
/// An opened media file: the probed format, the stream table and the packet
/// cursor. The internals are private; read them through the methods.
pub struct MediaFile {
  format_name : String
  streams : Array[StreamInfo]
  source : Source
  /// Per-track read cursors for the MP4 k-way DTS merge; a plain FIFO
  /// position on the other sources.
  cursor : Array[Int32]
}

///|
/// The probed format's name (what ffprobe prints as `format_name`).
pub fn MediaFile::format_name(self : MediaFile) -> String {
  self.format_name
}

///|
/// The stream table, in container order.
pub fn MediaFile::streams(self : MediaFile) -> Array[StreamInfo] {
  self.streams
}

///|
/// Open a byte buffer: probe the format, open the demuxer, build the stream
/// table. Formats without an adapter yet come back as `UnsupportedFormat`
/// with the probe's name, so callers can distinguish "not media" from
/// "recognised but not wired".
pub fn MediaFile::open(data : Bytes) -> MediaFile raise MediaError {
  let pd = ProbeData::new(data)
  let (found, _) = av_probe_input_format(pd)
  let format = match found {
    Some(f) => f
    None => raise FormatNotFound
  }
  match format {
    Mov => {
      let movie = match av_mov_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams : Array[StreamInfo] = []
      for i = 0; i < movie.tracks.length(); i = i + 1 {
        let t = movie.tracks[i]
        let (mt, rate, ch, w, h) = match t.media_type {
          Mp4MediaType::Audio =>
            (
              MediaType::Audio,
              t.sample_rate.reinterpret_as_int(),
              t.channels.reinterpret_as_int(),
              0,
              0,
            )
          Mp4MediaType::Video => (MediaType::Video, 0, 0, t.width, t.height)
          _ => (MediaType::Subtitle, 0, 0, 0, 0)
        }
        streams.push({
          index: i,
          media_type: mt,
          codec_id: if t.codec_id != "" {
            t.codec_id
          } else {
            t.codec
          },
          sample_rate: rate,
          channels: ch,
          width: w,
          height: h,
          extradata: t.extradata,
        })
      }
      {
        format_name: format.name(),
        streams,
        source: Mov(movie, data),
        cursor: Array::make(movie.tracks.length(), 0),
      }
    }
    Matroska => {
      let mh = match av_matroska_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams : Array[StreamInfo] = []
      for i = 0; i < mh.tracks.length(); i = i + 1 {
        let t = mh.tracks[i]
        let params = mkv_track_codec_parameters(t)
        let mt = if t.track_type == 1 {
          MediaType::Video
        } else if t.track_type == 0x11 {
          MediaType::Subtitle
        } else {
          MediaType::Audio
        }
        streams.push({
          index: i,
          media_type: mt,
          codec_id: params.codec,
          sample_rate: params.sample_rate,
          channels: params.channels,
          width: t.video.pixel_width.to_int(),
          height: t.video.pixel_height.to_int(),
          extradata: t.codec_priv,
        })
      }
      { format_name: format.name(), streams, source: Mkv(mh), cursor: [0], }
    }
    Ogg => {
      let demux = match av_ogg_opus_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams : Array[StreamInfo] = [
        {
          index: 0,
          media_type: Audio,
          codec_id: "opus",
          sample_rate: demux.input_sample_rate,
          channels: demux.channels,
          width: 0,
          height: 0,
          extradata: Some(demux.extradata),
        },
      ]
      {
        format_name: format.name(),
        streams,
        source: OggOpus(demux),
        cursor: [0],
      }
    }
    Wav => {
      let demux = match av_wav_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams : Array[StreamInfo] = [
        {
          index: 0,
          media_type: Audio,
          codec_id: demux.format.codec,
          sample_rate: demux.format.sample_rate,
          channels: demux.format.channels,
          width: 0,
          height: 0,
          extradata: if demux.format.extradata.length() > 0 {
            Some(demux.format.extradata)
          } else {
            None
          },
        },
      ]
      {
        format_name: format.name(),
        streams,
        source: Wav(demux, data),
        cursor: [0],
      }
    }
    MpegTs => playback_ts_build(data)
    other => raise UnsupportedFormat(other.name())
  }
}

///|
/// The next packet in stream order, or `None` at end of file.
pub fn MediaFile::next_packet(
  self : MediaFile,
) -> MediaPacket? raise MediaError {
  let ts_demux : (TsDemux, Array[Int64])? = match self.source {
    Ts(d, next_pts) => Some((d, next_pts))
    _ => None
  }
  match ts_demux {
    Some((d, next_pts)) => return self.playback_ts_next(d, next_pts)
    None => ()
  }
  match self.source {
    Mov(movie, data) => {
      // K-way merge by DTS across the tracks' sample tables - the C's
      // interleaved `AVPacket` order.
      let mut best_track = -1
      let mut best_dts : Int64 = 0
      for t = 0; t < movie.tracks.length(); t = t + 1 {
        let cur = self.cursor[t]
        let samples = movie.tracks[t].samples
        if cur < samples.length() {
          let dts = samples[cur].dts
          if best_track < 0 || dts < best_dts {
            best_track = t
            best_dts = dts
          }
        }
      }
      if best_track < 0 {
        return None
      }
      let t = movie.tracks[best_track]
      let sample = t.samples[self.cursor[best_track]]
      self.cursor[best_track] = self.cursor[best_track] + 1
      let start = sample.offset.to_int()
      let end = start + sample.size.reinterpret_as_int()
      if end > data.length() {
        raise DemuxError("sample extends past end of file")
      }
      Some({
        stream_index: best_track,
        data: data[start:end].to_owned(),
        pts: sample.pts,
        keyframe: sample.keyframe,
      })
    }
    Mkv(mh) => {
      let cur = self.cursor[0]
      if cur >= mh.packets.length() {
        return None
      }
      self.cursor[0] = cur + 1
      let p = mh.packets[cur]
      Some({
        stream_index: p.stream_index,
        data: p.data,
        pts: p.pts,
        keyframe: p.is_keyframe,
      })
    }
    OggOpus(demux) => {
      let cur = self.cursor[0]
      if cur >= demux.packets.length() {
        return None
      }
      self.cursor[0] = cur + 1
      let p = demux.packets[cur]
      Some({ stream_index: 0, data: p.data, pts: p.pts, keyframe: true, })
    }
    Wav(demux, data) => {
      let cur = self.cursor[0]
      if cur >= demux.packets.length() {
        return None
      }
      self.cursor[0] = cur + 1
      let p = demux.packets[cur]
      let start = p.pos.to_int()
      let end = start + p.size
      if end > data.length() {
        raise DemuxError("wav packet extends past end of file")
      }
      Some({
        stream_index: 0,
        data: data[start:end].to_owned(),
        pts: p.pts,
        keyframe: p.is_keyframe,
      })
    }
    Ts(_, _) => abort("unreachable: TS is routed above")
  }
}

///|
/// The audio decoder behind an `AudioDecoder`.
pub(all) enum AudioDec {
  Aac(@libavcodec.AacDecoder)
  Opus(@libavcodec.OpusDecoder)
  Mp3(@libavcodec.Mp3Decoder)
  /// Raw PCM: (little_endian, bytes_per_sample).
  Pcm(Bool, Int32)
}

///|
/// A codec dispatch on top of the ported decoders. Open it from the
/// `StreamInfo` a `MediaFile` handed out; `decode` turns each packet into an
/// `AudioFrame` (`None` when the codec suppresses the packet, e.g. Opus
/// packets that carry no new frame).
pub struct AudioDecoder {
  dec : AudioDec
  channels : Int32
  sample_rate : Int32
}

///|
/// The frame's channel count.
pub fn AudioDecoder::channels(self : AudioDecoder) -> Int32 {
  self.channels
}

///|
/// The decoded PCM's sample rate.
pub fn AudioDecoder::sample_rate(self : AudioDecoder) -> Int32 {
  self.sample_rate
}

///|
/// Build the decoder for one audio stream. Codecs without a ported decoder
/// come back as `UnsupportedCodec` with the stream's name.
pub fn AudioDecoder::open(info : StreamInfo) -> AudioDecoder raise MediaError {
  if info.media_type != MediaType::Audio {
    raise UnsupportedCodec(info.codec_id)
  }
  match info.codec_id {
    "aac" => {
      let extradata = match info.extradata {
        Some(v) => v
        None => raise UnsupportedCodec("aac without extradata")
      }
      let dec = match @libavcodec.new_aac_decoder_from_asc(extradata) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      { dec: Aac(dec), channels: info.channels, sample_rate: info.sample_rate, }
    }
    "mp3" | "mp2" | "mp1" =>
      // The MPEG audio decoder reads the format from each frame header; the
      // container's rate/channels pair (WAV fmt, MP4 esds) is authoritative
      // for the facade's StreamInfo.
      {
        dec: Mp3(@libavcodec.new_mp3_decoder()),
        channels: info.channels,
        sample_rate: info.sample_rate,
      }
    "opus" => {
      let extradata = match info.extradata {
        Some(v) => v
        None => raise UnsupportedCodec("opus without extradata")
      }
      let head = match @libavcodec.opus_parse_head(extradata) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      let dec = match @libavcodec.OpusDecoder::new(head) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      { dec: Opus(dec), channels: head.channels, sample_rate: 48000, }
    }
    "pcm_s16le" =>
      {
        dec: Pcm(true, 2),
        channels: info.channels,
        sample_rate: info.sample_rate,
      }
    "pcm_s16be" =>
      {
        dec: Pcm(false, 2),
        channels: info.channels,
        sample_rate: info.sample_rate,
      }
    other => raise UnsupportedCodec(other)
  }
}

///|
/// `aac_decode_frame_int` consumes an in-band ADTS header when a packet
/// starts with the 12-bit syncword: 7 bytes, plus the 2-byte CRC when
/// `protection_absent` is clear.
fn aac_strip_adts(data : Bytes) -> Bytes {
  if data.length() >= 7 &&
    data[0].to_int() == 0xFF &&
    (data[1].to_int() & 0xF0) == 0xF0 {
    let header = if (data[1].to_int() & 1) != 0 { 7 } else { 9 }
    data[header:].to_owned()
  } else {
    data
  }
}

///|
/// Decode one packet. `Ok(None)` means the packet produced no frame.
pub fn AudioDecoder::decode(
  self : AudioDecoder,
  pkt : MediaPacket,
) -> AudioFrame? raise MediaError {
  match self.dec {
    Aac(dec) => {
      let out = match dec.decode_frame(aac_strip_adts(pkt.data)) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      if out.length() == 0 {
        return None
      }
      // `AacPcm.samples` is one flat channel array per element (an SCE is
      // one channel, a CPE arrives as two elements), so the facade's frame
      // channels are the elements in order.
      let channels : Array[Array[Double]] = []
      let mut nb = 0
      for element in out {
        channels.push(element.samples)
        nb = element.samples.length()
      }
      Some({
        samples: channels,
        nb_samples: nb,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Opus(dec) => {
      let (pcm, n) = match dec.decode_packet(Some(pkt.data)) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      if n == 0 {
        return None
      }
      let channels : Array[Array[Double]] = []
      for ch = 0; ch < pcm.length(); ch = ch + 1 {
        let row : Array[Double] = []
        for i = 0; i < n; i = i + 1 {
          row.push(pcm[ch][i].to_double())
        }
        channels.push(row)
      }
      Some({
        samples: channels,
        nb_samples: n,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Pcm(little_endian, bytes_per_sample) => {
      let frame_bytes = self.channels * bytes_per_sample
      if pkt.data.length() < frame_bytes {
        return None
      }
      let nb = pkt.data.length() / frame_bytes
      let channels : Array[Array[Double]] = []
      for ch = 0; ch < self.channels; ch = ch + 1 {
        let row : Array[Double] = Array::make(nb, 0.0)
        for i = 0; i < nb; i = i + 1 {
          let base = (i * self.channels + ch) * bytes_per_sample
          let v = if bytes_per_sample == 2 {
            let lo = pkt.data[base].to_int()
            let hi = pkt.data[base + 1].to_int()
            let raw = if little_endian {
              lo | (hi << 8)
            } else {
              (lo << 8) | hi
            }
            let signed = if raw >= 32768 { raw - 65536 } else { raw }
            signed.to_double() / 32768.0
          } else {
            0.0
          }
          row[i] = v
        }
        channels.push(row)
      }
      Some({
        samples: channels,
        nb_samples: nb,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Mp3(dec) => {
      let out = match dec.decode_frame(pkt.data) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      let ch = out.channels
      if ch <= 0 || out.samples.length() == 0 {
        return None
      }
      // `Mp3Pcm.samples` is interleaved (the same layout `pcm_bytes` packs).
      let nb = out.samples.length() / ch
      let channels : Array[Array[Double]] = []
      for c = 0; c < ch; c = c + 1 {
        let row : Array[Double] = Array::make(nb, 0.0)
        for i = 0; i < nb; i = i + 1 {
          row[i] = out.samples[i * ch + c].to_double() / 32768.0
        }
        channels.push(row)
      }
      Some({
        samples: channels,
        nb_samples: nb,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
  }
}

///|
/// Decode every frame a packet carries. One packet can hold several access
/// units (RAW AAC in WAV is demuxed as one blob; the C's decoder consumes
/// concatenated frames from a single packet the same way), so the facade's
/// bulk decode goes through here; `decode` stays the one-frame contract.
pub fn AudioDecoder::decode_all(
  self : AudioDecoder,
  pkt : MediaPacket,
) -> Array[AudioFrame] raise MediaError {
  match self.dec {
    Aac(dec) => {
      let frames : Array[AudioFrame] = []
      // In-band ADTS headers are the decoder's own sniff in C
      // (`aac_decode_frame_int`); the port does it at the facade. Strip
      // before slicing so `consumed` and `rest` share one coordinate system.
      let mut rest = aac_strip_adts(pkt.data)
      while rest.length() > 0 {
        let out = match dec.decode_frame_with_consumed(rest) {
          Ok(v) => v
          Err(e) => raise DecodeError(e)
        }
        let (elements, consumed) = out
        if consumed <= 0 || elements.length() == 0 {
          break
        }
        // `AacPcm.samples` is one flat channel array per element (an SCE is
        // one channel, a CPE arrives as two elements).
        let channels : Array[Array[Double]] = []
        let mut nb = 0
        for element in elements {
          channels.push(element.samples)
          nb = element.samples.length()
        }
        frames.push({
          samples: channels,
          nb_samples: nb,
          sample_rate: self.sample_rate,
          pts: Some(pkt.pts),
        })
        rest = rest[consumed:rest.length()].to_owned()
      }
      frames
    }
    _ =>
      match self.decode(pkt) {
        Some(f) => [f]
        None => []
      }
  }
}

///|
/// The container's total duration in seconds, when it declares one:
/// MP4 `mdhd`/`mvhd` rescaled through the movie timescale, Matroska's Info
/// Duration in time-scale units, Ogg Opus's last granule minus pre-skip over
/// 48 kHz, WAV's sample count over the rate. `None` when the container
/// carries no duration.
pub fn MediaFile::duration_seconds(self : MediaFile) -> Double? {
  match self.source {
    Mov(movie, _) =>
      if movie.timescale != 0U && movie.duration > 0UL {
        Some(movie.duration.to_double() / movie.timescale.to_double())
      } else {
        None
      }
    Mkv(mh) =>
      if mh.duration > 0.0 && mh.time_scale > 0UL {
        // Info Duration is in time-scale units (ns at the default 1e6).
        Some(mh.duration * mh.time_scale.to_double() / 1.0e9)
      } else {
        None
      }
    Ts(demux, _) => {
      // Span between the first and last packet timestamp (90 kHz), like
      // ffprobe's stream duration when the container has no explicit end.
      let mut first : Int64 = ts_nopts
      let mut last : Int64 = ts_nopts
      for p in demux.packets {
        let t = if p.dts != ts_nopts { p.dts } else { p.pts }
        if t == ts_nopts {
          continue
        }
        if first == ts_nopts || t < first {
          first = t
        }
        if last == ts_nopts || t > last {
          last = t
        }
      }
      if first != ts_nopts && last > first {
        Some((last - first).to_double() / 90000.0)
      } else {
        None
      }
    }
    OggOpus(demux) => {
      let last = if demux.packets.length() > 0 {
        demux.packets[demux.packets.length() - 1].granule
      } else {
        -1L
      }
      if last >= 0L {
        let samples = last - demux.pre_skip.to_int64()
        if samples > 0L {
          Some(samples.to_double() / 48000.0)
        } else {
          None
        }
      } else {
        None
      }
    }
    Wav(demux, _) =>
      if demux.format.sample_rate > 0 && demux.sample_count > 0L {
        Some(
          demux.sample_count.to_double() / demux.format.sample_rate.to_double(),
        )
      } else {
        None
      }
  }
}

///|
/// A fully decoded audio stream: one flat sample row per channel in
/// `[-1, 1)`, plus everything a consumer needs to label it.
pub struct DecodedAudio {
  samples : Array[Array[Double]]
  sample_rate : Int32
  channels : Int32
  format_name : String
  codec_id : String
  duration_seconds : Double?
}

///|
/// Decode the first audio stream of a container to PCM - the engine the JSON
/// CLI's `decode-audio` command and the libswresample slice build on. Files
/// without an audio stream raise `UnsupportedCodec` with the format name.
pub fn decode_audio_file(data : Bytes) -> DecodedAudio raise MediaError {
  let mf = MediaFile::open(data)
  let mut audio = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if audio < 0 && mf.streams()[i].media_type == MediaType::Audio {
      audio = i
    }
  }
  if audio < 0 {
    raise UnsupportedCodec("no audio stream in \{mf.format_name()}")
  }
  let dec = AudioDecoder::open(mf.streams()[audio])
  let rows : Array[Array[Double]] = []
  for _ch = 0; _ch < dec.channels(); _ch = _ch + 1 {
    rows.push([])
  }
  // Encoder priming and end padding are not presentation audio; FFmpeg drops
  // them in decode.c's `discard_samples`. For MP4 the demuxer supplies
  // `skip_samples` and flags edit-list-cut packets AV_PKT_FLAG_DISCARD: a
  // discarded frame is dropped whole and consumes `skip_samples` by its own
  // length, the remainder trims the head of the next kept frame, and the
  // last packet's `discard_padding` trims the tail.
  let (mov_track, tail) = match mf.source {
    Mov(movie, _) => {
      let track = movie.tracks[audio]
      (Some(track), mov_audio_tail_discard(movie, track))
    }
    _ => (None, 0)
  }
  let mut skip = match mov_track {
    Some(t) => t.skip_samples
    None => 0
  }
  let mut nth = 0
  while true {
    let pkt = mf.next_packet()
    if pkt is None {
      break
    }
    let p = pkt.unwrap()
    if p.stream_index != audio {
      continue
    }
    let frames = dec.decode_all(p)
    let discarded = match mov_track {
      Some(t) => nth < t.samples.length() && t.samples[nth].discard
      None => false
    }
    nth = nth + 1
    for f in frames {
      if discarded {
        skip = if skip > f.nb_samples { skip - f.nb_samples } else { 0 }
        continue
      }
      let from = if skip < f.nb_samples { skip } else { f.nb_samples }
      skip = skip - from
      for ch = 0; ch < dec.channels(); ch = ch + 1 {
        for i = from; i < f.nb_samples; i = i + 1 {
          rows[ch].push(f.samples[ch][i])
        }
      }
    }
  }
  // Ogg Opus pre-skip from OpusHead (initial_padding) trims the head.
  let head = match mf.source {
    OggOpus(demux) => demux.pre_skip
    _ => 0
  }
  if rows.length() > 0 && (head > 0 || tail > 0) {
    let total = rows[0].length()
    let start = if head < total { head } else { total }
    let end = if total - tail > start { total - tail } else { start }
    for ch = 0; ch < rows.length(); ch = ch + 1 {
      rows[ch] = rows[ch][start:end].to_owned()
    }
  }
  {
    samples: rows,
    sample_rate: dec.sample_rate(),
    channels: dec.channels(),
    format_name: mf.format_name(),
    codec_id: mf.streams()[audio].codec_id,
    duration_seconds: mf.duration_seconds(),
  }
}

///|
/// Samples to drop from the end of an MP4 audio track: `mov_read_packet`
/// derives `first_discard_sample` from the last packet and the track
/// duration, and `read_frame_internal` turns that into the packet's
/// `discard_padding`. Fragmented files skip this in the C (`found_tfhd`);
/// fragments are also what switches `advanced_editlist` off, so that flag
/// tells them apart here. The iTunSMPB gapless path is not covered.
fn mov_audio_tail_discard(movie : Mp4Movie, track : Mp4Track) -> Int32 {
  let n = track.samples.length()
  let rate = track.sample_rate.reinterpret_as_int()
  let scale = track.timescale.reinterpret_as_int()
  if !movie.advanced_editlist || n == 0 || rate <= 0 || scale <= 0 {
    return 0
  }
  let to_samples = fn(ts : Int64) -> Int64 {
    @libavutil.av_rescale_q(
      ts,
      @libavutil.av_make_q(1, scale),
      @libavutil.av_make_q(1, rate),
    )
  }
  let last = track.samples[n - 1]
  let st_duration = track.duration.reinterpret_as_int64()
  let last_duration = last.duration.to_int64()
  let kept = if st_duration < last.pts {
    0L
  } else if last_duration < st_duration - last.pts {
    last_duration
  } else {
    st_duration - last.pts
  }
  let sample = to_samples(last.pts)
  let first_discard = sample + to_samples(kept)
  if first_discard == 0L {
    return 0
  }
  // `FFMAX(codecpar->frame_size, ts_to_samples(pkt->duration))`.
  let frame_size = to_samples(track.samples[0].duration.to_int64())
  let in_samples = to_samples(last_duration)
  let duration = if frame_size > in_samples { frame_size } else { in_samples }
  let end_sample = sample + duration
  if duration > 0L &&
    end_sample >= first_discard &&
    sample < to_samples(st_duration) {
    let excess = end_sample - first_discard
    (if excess < duration { excess } else { duration }).to_int()
  } else {
    0
  }
}

///|
/// The frame's channel count.
pub fn DecodedAudio::channels(self : DecodedAudio) -> Int32 {
  self.channels
}

///|
/// The decoded PCM's sample rate.
pub fn DecodedAudio::sample_rate(self : DecodedAudio) -> Int32 {
  self.sample_rate
}

///|
/// Per-channel sample rows.
pub fn DecodedAudio::samples(self : DecodedAudio) -> Array[Array[Double]] {
  self.samples
}

///|
/// The container's declared duration in seconds (when present).
pub fn DecodedAudio::duration_seconds(self : DecodedAudio) -> Double? {
  self.duration_seconds
}

///|
/// The probed format's name.
pub fn DecodedAudio::format_name(self : DecodedAudio) -> String {
  self.format_name
}

///|
/// The audio stream's codec name.
pub fn DecodedAudio::codec_id(self : DecodedAudio) -> String {
  self.codec_id
}

///|
/// Render the decoded PCM as a 16-bit little-endian WAV file (the output
/// format of the CLI's `decode-audio`): samples are clipped into the s16
/// range and interleaved.
pub fn DecodedAudio::to_wav_s16(self : DecodedAudio) -> Bytes raise MediaError {
  let mux = match wav_muxer_new(self.sample_rate, self.channels, 16) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let nb = if self.samples.length() > 0 { self.samples[0].length() } else { 0 }
  let inter : Array[Int32] = Array::make(nb * self.channels, 0)
  for i = 0; i < nb; i = i + 1 {
    for ch = 0; ch < self.channels; ch = ch + 1 {
      // FFmpeg's float->s16 conversion: av_clip_int16(lrintf(x * 32768)),
      // i.e. round half to even - plain truncation loses an LSB on every
      // half-way sample, which used to show up as +-1 diffs against the
      // docker reference decodes.
      inter[i * self.channels + ch] = @swr.swr_flt_to_s16(self.samples[ch][i])
    }
  }
  mux.write_samples(inter[:])
  mux.finish()
}

///|
/// One decoded video picture, wrapped without copying. `yuv_bytes` renders
/// the visible planes as planar YUV (8-bit samples, little-endian words above
/// 8 bits) - the layout FFmpeg's rawvideo output and the CLI's
/// `extract-frame` use.
pub(all) enum VideoFrameData {
  H264(@libavcodec.H264Frame)
  Hevc(@libavcodec.HevcDecodedFrame)
  Vp9(@libavcodec.Vp9Frame)
  Av1(@libavcodec.Av1FrameOutput)
  Mjpeg(@libavcodec.JpegImage)
  Png(@libavcodec.PngImage)
}

///|
pub struct VideoFrame {
  data : VideoFrameData
}

///|
/// The visible (cropped) width.
pub fn VideoFrame::width(self : VideoFrame) -> Int32 {
  match self.data {
    H264(f) => f.width
    Hevc(f) => f.pic.width
    Vp9(f) => f.width
    Av1(f) => f.width
    Mjpeg(f) => f.width
    Png(f) => f.width
  }
}

///|
/// The visible (cropped) height.
pub fn VideoFrame::height(self : VideoFrame) -> Int32 {
  match self.data {
    H264(f) => f.height
    Hevc(f) => f.pic.height
    Vp9(f) => f.height
    Av1(f) => f.height
    Mjpeg(f) => f.height
    Png(f) => f.height
  }
}

///|
/// The H.264 picture's luma plane (only meaningful when the frame came from
/// the H.264 dispatch; other codecs panic — match on `data` first).
pub fn VideoFrame::y(self : VideoFrame) -> Array[Int32] {
  match self.data {
    H264(f) => f.y
    _ => abort("VideoFrame::y on a non-H264 frame")
  }
}

///|
/// The H.264 luma stride.
pub fn VideoFrame::ystride(self : VideoFrame) -> Int32 {
  match self.data {
    H264(f) => f.ystride
    _ => abort("VideoFrame::ystride on a non-H264 frame")
  }
}

///|
/// The presentation-order count where the codec defines one (H.264/HEVC);
/// `-1` for codecs whose output order is the display order (VP9/AV1).
pub fn VideoFrame::poc(self : VideoFrame) -> Int32 {
  match self.data {
    H264(f) => f.poc
    Hevc(f) => f.poc
    _ => -1
  }
}

///|
/// The bit depth the planes are rendered at (8 for 8-bit codecs).
pub fn VideoFrame::bit_depth(self : VideoFrame) -> Int32 {
  match self.data {
    H264(_) => 8
    Hevc(_) => 8
    Vp9(_) => 8
    Av1(f) => f.bitdepth
    Mjpeg(f) => if f.pix_fmt.has_suffix("16le") { 16 } else { 8 }
    Png(f) =>
      if f.bit_depth == 16 {
        16
      } else if f.pix_fmt == "monob" {
        1
      } else {
        8
      }
  }
}

///|
/// Pack the visible planes as planar YUV. For JPEG/PNG use pixel_bytes and
/// image_pixel_format instead, since their output may be RGB or paletted.
pub fn VideoFrame::yuv_bytes(self : VideoFrame) -> Bytes {
  match self.data {
    Mjpeg(_) | Png(_) =>
      abort("use VideoFrame::pixel_bytes for JPEG/PNG frames")
    H264(f) => {
      // The H.264 planes are macroblock-aligned with strides; the visible
      // region starts at (crop_top, crop_left) and spans width x height
      // (chroma subsampled by the frame's shifts).
      let w = f.width
      let h = f.height
      let cw = w >> f.chroma_hshift
      let ch = h >> f.chroma_vshift
      let out : Array[Byte] = []
      let ytop = f.crop_top
      let ctop = f.crop_top >> f.chroma_vshift
      let cleft = f.crop_left >> f.chroma_hshift
      for row = ytop; row < ytop + h; row = row + 1 {
        let base = row * f.ystride + f.crop_left
        for i = 0; i < w; i = i + 1 {
          out.push(f.y[base + i].to_byte())
        }
      }
      for row = ctop; row < ctop + ch; row = row + 1 {
        let base = row * f.cstride + cleft
        for i = 0; i < cw; i = i + 1 {
          out.push(f.u[base + i].to_byte())
        }
      }
      for row = ctop; row < ctop + ch; row = row + 1 {
        let base = row * f.cstride + cleft
        for i = 0; i < cw; i = i + 1 {
          out.push(f.v[base + i].to_byte())
        }
      }
      Bytes::from_array(out)
    }
    Hevc(f) => f.yuvp(8)
    Vp9(f) => f.data
    Av1(f) => {
      let out : Array[Byte] = []
      let cw = (f.width + f.ss_h) >> f.ss_h
      let ch = (f.height + f.ss_v) >> f.ss_v
      for row = 0; row < f.height; row = row + 1 {
        let base = row * f.y_stride
        for i = 0; i < f.width; i = i + 1 {
          let sample = f.y[base + i]
          out.push(sample.to_byte())
          if f.bitdepth > 8 {
            out.push((sample >> 8).to_byte())
          }
        }
      }
      if !f.mono {
        for row = 0; row < ch; row = row + 1 {
          let base = row * f.uv_stride
          for i = 0; i < cw; i = i + 1 {
            let sample = f.u[base + i]
            out.push(sample.to_byte())
            if f.bitdepth > 8 {
              out.push((sample >> 8).to_byte())
            }
          }
        }
        for row = 0; row < ch; row = row + 1 {
          let base = row * f.uv_stride
          for i = 0; i < cw; i = i + 1 {
            let sample = f.v[base + i]
            out.push(sample.to_byte())
            if f.bitdepth > 8 {
              out.push((sample >> 8).to_byte())
            }
          }
        }
      }
      Bytes::from_array(out)
    }
  }
}

///|
/// The video codec dispatch behind a `VideoDecoder`.
pub(all) enum VideoDec {
  H264(@libavcodec.H264Decoder, Bool, Int32)
  /// HEVC's ported entry is batch-shaped (a fresh session per call), so the
  /// facade buffers the stream's packets and decodes them in one pass at
  /// `finish_video`.
  Hevc(Int32)
  Vp9(@libavcodec.Vp9Decoder)
  Av1(@libavcodec.Av1Decoder)
  Mjpeg(@libavcodec.MjpegDecoder)
  Png
}

///|
/// A codec dispatch for video streams, on top of the ported decoders.
pub struct VideoDecoder {
  dec : VideoDec
  width : Int32
  height : Int32
  /// The HEVC batch's pending packets.
  pending : Array[Bytes]
}

///|
/// The coded width from the stream parameters.
pub fn VideoDecoder::width(self : VideoDecoder) -> Int32 {
  self.width
}

///|
/// The coded height from the stream parameters.
pub fn VideoDecoder::height(self : VideoDecoder) -> Int32 {
  self.height
}

///|
/// Unroll the parameter-set NALs embedded in an hvcC record (VPS/SPS/PPS
/// and friends) into stream-format bytes - each NAL prefixed with a
/// `nal_length_size` length, exactly like the in-band slices they precede.
/// This mirrors FFmpeg's `hevc_parse_extradata` path: Matroska samples
/// never repeat the parameter sets in band, so the decoder session must be
/// seeded with them or the first slice fails with "missing PPS".
fn hevc_hvcc_paramsets(extradata : Bytes, nal_length_size : Int32) -> Bytes? {
  if extradata.length() < 23 || extradata[0].to_int() != 1 {
    return None
  }
  let out : Array[Byte] = []
  let mut pos = 22
  let num_arrays = extradata[pos].to_int()
  pos = pos + 1
  for _a = 0; _a < num_arrays; _a = _a + 1 {
    pos = pos + 1 // array_completeness + NAL_unit_type
    if pos + 2 > extradata.length() {
      return None
    }
    let num_nalus = (extradata[pos].to_int() << 8) | extradata[pos + 1].to_int()
    pos = pos + 2
    for _n = 0; _n < num_nalus; _n = _n + 1 {
      if pos + 2 > extradata.length() {
        return None
      }
      let len = (extradata[pos].to_int() << 8) | extradata[pos + 1].to_int()
      pos = pos + 2
      if len <= 0 || pos + len > extradata.length() {
        return None
      }
      for i = 0; i < nal_length_size; i = i + 1 {
        let shift = (nal_length_size - 1 - i) * 8
        out.push(((len >> shift) & 0xFF).to_byte())
      }
      for i = 0; i < len; i = i + 1 {
        out.push(extradata[pos + i])
      }
      pos = pos + len
    }
  }
  if out.length() == 0 {
    None
  } else {
    Some(Bytes::from_array(out[:]))
  }
}

///|
/// Build the decoder for one video stream. Codecs without a ported decoder
/// raise `UnsupportedCodec`.
pub fn VideoDecoder::open(info : StreamInfo) -> VideoDecoder raise MediaError {
  if info.media_type != MediaType::Video {
    raise UnsupportedCodec(info.codec_id)
  }
  match info.codec_id {
    "h264" => {
      let extradata = match info.extradata {
        Some(v) => v
        None => raise UnsupportedCodec("h264 without extradata")
      }
      let dec = @libavcodec.new_h264_decoder()
      let parsed = match
        @libavcodec.ff_h264_decode_extradata(extradata, dec.ps) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      {
        dec: H264(dec, parsed.is_avc, parsed.nal_length_size),
        width: info.width,
        height: info.height,
        pending: [],
      }
    }
    "hevc" => {
      let extradata = match info.extradata {
        Some(v) => v
        None => raise UnsupportedCodec("hevc without extradata")
      }
      // hvcC's lengthSizeMinusOne lives at a fixed offset (byte 21, low two
      // bits) + 1; Annex B private data passes 0 (unused in the batch call).
      let nal_length_size = if extradata.length() > 21 &&
        extradata[0].to_int() == 1 {
        (extradata[21].to_int() & 0x03) + 1
      } else {
        0
      }
      {
        dec: Hevc(nal_length_size),
        width: info.width,
        height: info.height,
        // Seed the batch with the hvcC parameter sets so the first slice
        // finds its VPS/SPS/PPS (Matroska never carries them in band).
        pending: match hevc_hvcc_paramsets(extradata, nal_length_size) {
          Some(seed) => [seed]
          None => []
        },
      }
    }
    "vp9" =>
      {
        dec: Vp9(@libavcodec.vp9_decoder_new()),
        width: info.width,
        height: info.height,
        pending: [],
      }
    "av1" =>
      {
        dec: Av1(@libavcodec.Av1Decoder::new()),
        width: info.width,
        height: info.height,
        pending: [],
      }
    "mjpeg" =>
      {
        dec: Mjpeg(@libavcodec.MjpegDecoder::new()),
        width: info.width,
        height: info.height,
        pending: [],
      }
    "png" => { dec: Png, width: info.width, height: info.height, pending: [], }
    other => raise UnsupportedCodec(other)
  }
}

///|
/// Decode one packet into zero or more pictures. VP9/AV1 emit at most one
/// picture per packet; H.264 may emit a reorder batch; HEVC buffers until
/// `finish_video`.
pub fn VideoDecoder::decode(
  self : VideoDecoder,
  pkt : MediaPacket,
) -> Array[VideoFrame] raise MediaError {
  match self.dec {
    Mjpeg(dec) =>
      match dec.decode(pkt.data) {
        Ok(image) => [{ data: Mjpeg(image), }]
        Err(e) => raise DecodeError(e)
      }
    Png =>
      match @libavcodec.av_png_decode(pkt.data) {
        Ok(image) => [{ data: Png(image), }]
        Err(e) => raise DecodeError(e)
      }
    H264(dec, is_avc, nal_length_size) => {
      // `decode_avc_sample` yields at most one buffered picture per sample
      // (None while the decoder reorders); the stream entry yields a batch.
      let out : Array[@libavcodec.H264Frame] = if is_avc {
        match dec.decode_avc_sample(pkt.data, nal_length_size, false) {
          Ok(Some(frame)) => [frame]
          Ok(None) => []
          Err(e) => raise DecodeError(e)
        }
      } else {
        match dec.decode_annexb(pkt.data, false) {
          Ok(v) => v
          Err(e) => raise DecodeError(e)
        }
      }
      let frames : Array[VideoFrame] = []
      for frame in out {
        frames.push({ data: H264(frame), })
      }
      frames
    }
    Hevc(_) => {
      self.pending.push(pkt.data)
      []
    }
    Vp9(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(frames) => {
          let out : Array[VideoFrame] = []
          for f in frames {
            out.push({ data: Vp9(f), })
          }
          out
        }
        Err(e) => raise DecodeError(e)
      }
    Av1(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(Some(out)) => [{ data: Av1(out), }]
        Ok(None) => []
        Err(e) => raise DecodeError(e)
      }
  }
}

///|
/// Flush the pending HEVC batch (a no-op for the other codecs): join the
/// buffered packets and decode them in one session, the shape the ported
/// entry point is built for.
pub fn VideoDecoder::finish_video(
  self : VideoDecoder,
) -> Array[VideoFrame] raise MediaError {
  match self.dec {
    Hevc(nal_length_size) => {
      if self.pending.length() == 0 {
        return []
      }
      let joined : Array[Byte] = []
      for p in self.pending {
        for i = 0; i < p.length(); i = i + 1 {
          joined.push(p[i])
        }
      }
      let out = match
        @libavcodec.ff_hevc_decode_frames_ex(
          Bytes::from_array(joined[:]),
          nal_length_size > 0,
          nal_length_size,
          true,
        ) {
        Ok(v) => v
        Err(e) => raise DecodeError(e)
      }
      let frames : Array[VideoFrame] = []
      for frame in out {
        frames.push({ data: Hevc(frame), })
      }
      // The batch decoder emits pictures in decode order; present them in
      // POC order, the order FFmpeg's receive_frame yields B-frame streams.
      for i = 0; i < frames.length(); i = i + 1 {
        let mut best = i
        for j = i + 1; j < frames.length(); j = j + 1 {
          if frames[j].poc() < frames[best].poc() {
            best = j
          }
        }
        if best != i {
          let tmp = frames[i]
          frames[i] = frames[best]
          frames[best] = tmp
        }
      }
      frames
    }
    _ => []
  }
}

///|
/// JSON string escaping for the probe renderer (RFC 8259 `"` / `\` and the
/// C0 range; everything else passes through as UTF-8).
pub fn probe_json_escape_for_test(s : String) -> String {
  let bs = "\u005C".get_char(0).unwrap()
  let out = StringBuilder()
  for ch in s {
    let code = ch.to_int()
    if code == 34 {
      out.write_char(bs)
      out.write_char(ch)
    } else if code == 92 {
      out.write_char(bs)
      out.write_char(bs)
    } else if code < 0x20 {
      out.write_char(bs)
      out.write_char('u')
      let hexdigits = "0123456789abcdef"
      out.write_char(hexdigits.get_char((code >> 12) & 15).unwrap())
      out.write_char(hexdigits.get_char((code >> 8) & 15).unwrap())
      out.write_char(hexdigits.get_char((code >> 4) & 15).unwrap())
      out.write_char(hexdigits.get_char(code & 15).unwrap())
    } else {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// Render the opened file the way `ffprobe -show_format -show_streams`
/// structures its JSON (the CLI `probe` command's payload): a `format`
/// object with the probed name and duration, and one `streams` entry per
/// stream carrying the facade's parameters. Numbers are plain; everything
/// else is escaped.
pub fn MediaFile::probe_json(self : MediaFile) -> String {
  let out = StringBuilder()
  out.write_string("{\n  \"format\": {\n    \"format_name\": \"")
  out.write_string(probe_json_escape_for_test(self.format_name()))
  out.write_string("\",\n    \"nb_streams\": ")
  out.write_string("\{self.streams().length()}")
  let dur = match self.duration_seconds() {
    Some(v) => v.to_string()
    None => "null"
  }
  out.write_string(",\n    \"duration\": ")
  out.write_string(dur)
  out.write_string("\n  },\n  \"streams\": [")
  for i = 0; i < self.streams().length(); i = i + 1 {
    let info = self.streams()[i]
    out.write_string(if i == 0 { "\n    " } else { ",\n    " })
    out.write_string(
      "{\n      \"index\": \{info.index},\n      \"codec_type\": \"",
    )
    let kind = match info.media_type {
      Audio => "audio"
      Video => "video"
      Subtitle => "subtitle"
    }
    out.write_string(kind)
    out.write_string("\",\n      \"codec_name\": \"")
    out.write_string(probe_json_escape_for_test(info.codec_id))
    out.write_string("\"")
    if info.media_type == Audio {
      out.write_string(
        ",\n      \"sample_rate\": \{info.sample_rate},\n      \"channels\": \{info.channels}",
      )
    } else {
      out.write_string(
        ",\n      \"width\": \{info.width},\n      \"height\": \{info.height}",
      )
    }
    out.write_string(",\n      \"has_extradata\": ")
    out.write_string(if info.extradata is Some(_) { "true" } else { "false" })
    out.write_string("\n    }")
  }
  if self.streams().length() > 0 {
    out.write_string("\n  ")
  }
  out.write_string("]\n}")
  out.to_string()
}
