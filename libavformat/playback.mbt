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
}

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
pub struct StreamInfo {
  index : Int32
  media_type : MediaType
  /// FFmpeg codec name ("aac", "opus", "pcm_s16le", "h264", ...).
  codec_id : String
  /// Audio only (0 on other streams).
  sample_rate : Int32
  channels : Int32
  extradata : Bytes?
} derive(Eq)

///|
pub extend StreamInfo with Eq::{not_equal, equal}

///|
/// One compressed packet as the container delivered it.
pub struct MediaPacket {
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
        let (mt, rate, ch) = match t.media_type {
          Mp4MediaType::Audio =>
            (
              MediaType::Audio,
              t.sample_rate.reinterpret_as_int(),
              t.channels.reinterpret_as_int(),
            )
          Mp4MediaType::Video => (MediaType::Video, 0, 0)
          _ => (MediaType::Subtitle, 0, 0)
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
    other => raise UnsupportedFormat(other.name())
  }
}

///|
/// The next packet in stream order, or `None` at end of file.
pub fn MediaFile::next_packet(
  self : MediaFile,
) -> MediaPacket? raise MediaError {
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
  }
}

///|
/// The audio decoder behind an `AudioDecoder`.
pub(all) enum AudioDec {
  Aac(@libavcodec.AacDecoder)
  Opus(@libavcodec.OpusDecoder)
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
/// Decode one packet. `Ok(None)` means the packet produced no frame.
pub fn AudioDecoder::decode(
  self : AudioDecoder,
  pkt : MediaPacket,
) -> AudioFrame? raise MediaError {
  match self.dec {
    Aac(dec) => {
      let out = match dec.decode_frame(pkt.data) {
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
  }
}
