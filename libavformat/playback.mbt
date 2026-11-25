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
/// Machine-readable stable error code (one per constructor, ASCII
/// UPPER_SNAKE). This is the unified error-code surface of the facade: the
/// wasm/browser layer reports `{code, message}` envelopes and callers match
/// on `code` without parsing `message()`.
pub fn MediaError::code(self : MediaError) -> String {
  match self {
    FormatNotFound => "FORMAT_NOT_FOUND"
    UnsupportedFormat(_) => "UNSUPPORTED_FORMAT"
    DemuxError(_) => "DEMUX_ERROR"
    UnsupportedCodec(_) => "UNSUPPORTED_CODEC"
    DecodeError(_) => "DECODE_ERROR"
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
  OggVorbis(OggVorbisDemux)
  OggFlac(OggFlacDemux)
  StillImage(Bytes)
  Wav(WavDemux, Bytes)
  AiffAudio(AiffDemux, Bytes)
  RawDts(DtsTrack, Bytes)
  AsfAudio(AsfDemux)
  RawAc3(RawAudioTrack, Bytes)
  /// A raw AMR-NB / AMR-WB stream (`av_amr_open`), in one channel.
  Amr(RawAudioTrack, Bytes)
  ApeAudio(ApeDemux)
  MusepackAudio(Mpc7Demux)
  Musepack8Audio(Mpc8Demux)
  /// The RealMedia demuxer's packets in file (interleave) order.
  RealMediaAudio(RealMediaDemux)
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
/// MP4 stsd fourcc → FFmpeg codec name for the facade's video dispatch
/// (still-image tracks included). Unknown tags pass through unchanged so
/// `VideoDecoder::open` reports the original fourcc.
fn playback_mov_video_codec(fourcc : String) -> String {
  match fourcc {
    "avc1" | "avc2" | "avc3" | "avc4" => "h264"
    "hvc1" | "hev1" => "hevc"
    "vp09" => "vp9"
    "av01" => "av1"
    "jpeg" => "mjpeg"
    "png " => "png"
    other => other
  }
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
          codec_id: {
            // Video tracks carry the raw stsd fourcc ("avc1", ...); the
            // facade's decoder dispatch speaks FFmpeg codec names.
            let raw = if t.codec_id != "" { t.codec_id } else { t.codec }
            match t.media_type {
              Mp4MediaType::Video => playback_mov_video_codec(raw)
              Mp4MediaType::Audio => mov_codec_name(t.codec, t.codec_id)
              _ => raw
            }
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
    Ogg if playback_ogg_codec(data) is Some(codec) =>
      playback_ogg_open(data, format.name(), codec)
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
    Aiff => {
      let demux = match av_aiff_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      {
        format_name: format.name(),
        streams: [
          {
            index: 0,
            media_type: Audio,
            codec_id: demux.format.codec,
            sample_rate: demux.format.sample_rate,
            channels: demux.format.channels,
            width: 0,
            height: 0,
            extradata: None,
          },
        ],
        source: AiffAudio(demux, data),
        cursor: [0],
      }
    }
    Dts => {
      let track = match av_dts_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      {
        format_name: format.name(),
        streams: [
          {
            index: 0,
            media_type: Audio,
            codec_id: "dts",
            sample_rate: track.sample_rate,
            channels: track.channels,
            width: 0,
            height: 0,
            extradata: None,
          },
        ],
        source: RawDts(track, data),
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
    Asf => {
      let demux = match av_asf_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams = demux.tracks.mapi((index, track) => StreamInfo::{
        index,
        media_type: Audio,
        codec_id: track.codec,
        sample_rate: track.sample_rate,
        channels: track.channels,
        width: 0,
        height: 0,
        extradata: Some(track.extradata),
      })
      {
        format_name: format.name(),
        streams,
        source: AsfAudio(demux),
        cursor: [0],
      }
    }
    Ac3 | Eac3 => {
      let track = match av_ac3_open(data) {
        Ok(track) => track
        Err(e) => raise DemuxError(e)
      }
      let streams = [
        StreamInfo::{
          index: 0,
          media_type: Audio,
          codec_id: track.codec,
          sample_rate: track.sample_rate,
          channels: track.channels,
          width: 0,
          height: 0,
          extradata: None,
        },
      ]
      {
        format_name: track.codec,
        streams,
        source: RawAc3(track, data),
        cursor: [0],
      }
    }
    Ape => {
      let demux = match av_ape_open(data) {
        Ok(demux) => demux
        Err(e) => raise DemuxError(e)
      }
      let streams = [
        StreamInfo::{
          index: 0,
          media_type: Audio,
          codec_id: "ape",
          sample_rate: demux.sample_rate,
          channels: demux.channels,
          width: 0,
          height: 0,
          extradata: Some(demux.extradata),
        },
      ]
      { format_name: "ape", streams, source: ApeAudio(demux), cursor: [0], }
    }
    Amr => {
      let track = match av_amr_open(data) {
        Ok(track) => track
        Err(e) => raise DemuxError(e)
      }
      let streams = [
        StreamInfo::{
          index: 0,
          media_type: Audio,
          codec_id: track.codec,
          sample_rate: track.sample_rate,
          channels: track.channels,
          width: 0,
          height: 0,
          extradata: None,
        },
      ]
      {
        format_name: format.name(),
        streams,
        source: Amr(track, data),
        cursor: [0],
      }
    }
    Mpc7 => {
      let demux = match av_mpc7_open(data) {
        Ok(demux) => demux
        Err(e) => raise DemuxError(e)
      }
      let streams = [
        StreamInfo::{
          index: 0,
          media_type: Audio,
          codec_id: "musepack7",
          sample_rate: demux.sample_rate,
          channels: 2,
          width: 0,
          height: 0,
          extradata: Some(demux.extradata),
        },
      ]
      {
        format_name: "mpc",
        streams,
        source: MusepackAudio(demux),
        cursor: [0],
      }
    }
    Mpc8 => {
      let demux = match av_mpc8_open(data) {
        Ok(demux) => demux
        Err(e) => raise DemuxError(e)
      }
      let streams = [
        StreamInfo::{
          index: 0,
          media_type: Audio,
          codec_id: "musepack8",
          sample_rate: demux.sample_rate,
          channels: demux.channels,
          width: 0,
          height: 0,
          extradata: Some(demux.extradata),
        },
      ]
      {
        format_name: "mpc8",
        streams,
        source: Musepack8Audio(demux),
        cursor: [0],
      }
    }
    RealMedia => {
      let demux = match av_realmedia_open(data) {
        Ok(v) => v
        Err(e) => raise DemuxError(e)
      }
      let streams = demux.tracks.mapi((index, track) => StreamInfo::{
        index,
        media_type: track.media_type,
        // Already the FFmpeg codec name (cook, sipr, ra_144, ra_288, ac3,
        // aac, rv40, ...).
        codec_id: track.codec,
        sample_rate: track.sample_rate,
        channels: track.channels,
        width: track.width,
        height: track.height,
        extradata: if track.extradata.length() > 0 {
          Some(track.extradata)
        } else {
          None
        },
      })
      {
        format_name: format.name(),
        streams,
        source: RealMediaAudio(demux),
        cursor: [0],
      }
    }
    Png => playback_open_png(data, format.name())
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
    OggVorbis(demux) => {
      let index = self.cursor[0]
      guard index < demux.packets.length() else { return None }
      self.cursor[0] = index + 1
      let packet = demux.packets[index]
      Some({
        stream_index: 0,
        data: packet.data,
        pts: packet.granule,
        keyframe: true,
      })
    }
    OggFlac(demux) => {
      let index = self.cursor[0]
      guard index < demux.frames.length() else { return None }
      self.cursor[0] = index + 1
      let frame = demux.frames[index]
      Some({
        stream_index: 0,
        data: frame.data,
        pts: frame.granule,
        keyframe: true,
      })
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
    StillImage(data) =>
      if self.cursor[0] == 0 {
        self.cursor[0] = 1
        Some({ stream_index: 0, data, pts: 0L, keyframe: true, })
      } else {
        None
      }
    AsfAudio(demux) => {
      let index = self.cursor[0]
      guard index < demux.packets.length() else { return None }
      self.cursor[0] = index + 1
      let p = demux.packets[index]
      Some({
        stream_index: p.stream_index,
        data: p.data,
        pts: p.pts,
        keyframe: p.is_keyframe,
      })
    }
    AiffAudio(demux, data) => {
      let index = self.cursor[0]
      guard index < demux.packets.length() else { return None }
      self.cursor[0] = index + 1
      let p = demux.packets[index]
      let start = p.pos.to_int()
      Some({
        stream_index: 0,
        data: data[start:start + p.size].to_owned(),
        pts: p.pts,
        keyframe: true,
      })
    }
    RawDts({ frames, .. }, data)
    | RawAc3({ frames, .. }, data)
    | Amr({ frames, .. }, data) => {
      let index = self.cursor[0]
      guard index < frames.length() else { return None }
      self.cursor[0] = index + 1
      let p = frames[index]
      let start = p.pos.to_int()
      Some({
        stream_index: 0,
        data: data[start:start + p.size].to_owned(),
        pts: p.pts,
        keyframe: p.is_keyframe,
      })
    }
    ApeAudio(demux) => {
      let index = self.cursor[0]
      guard demux.packet(index) is Some((data, pts)) else { return None }
      self.cursor[0] = index + 1
      Some({ stream_index: 0, data, pts, keyframe: true, })
    }
    MusepackAudio(demux) => {
      let index = self.cursor[0]
      guard demux.packet(index) is Some(data) else { return None }
      self.cursor[0] = index + 1
      Some({ stream_index: 0, data, pts: index.to_int64(), keyframe: true, })
    }
    Musepack8Audio(demux) => {
      let index = self.cursor[0]
      guard demux.packet(index) is Some(data) else { return None }
      self.cursor[0] = index + 1
      Some({ stream_index: 0, data, pts: index.to_int64(), keyframe: true, })
    }
    RealMediaAudio(demux) => {
      let index = self.cursor[0]
      let count = demux.packets.length()
      guard index < count else {
        // The demuxer keeps the packets it read before a truncated or
        // damaged chunk stopped it. Like `av_read_frame`, hand those out
        // first and report the error once the walk is over (the cursor then
        // moves past the error so the next call is a plain end of file).
        if index == count && demux.read_error != "" {
          self.cursor[0] = index + 1
          raise DemuxError(demux.read_error)
        }
        return None
      }
      self.cursor[0] = index + 1
      let p = demux.packets[index]
      Some({
        stream_index: p.stream_index,
        data: p.data,
        pts: p.pts,
        keyframe: p.keyframe,
      })
    }
    Ts(_, _) => abort("unreachable: TS is routed above")
  }
}

///|
/// The audio decoder behind an `AudioDecoder`.
pub(all) enum AudioDec {
  Musepack7(@libavcodec.Mpc7Decoder)
  Musepack8(@libavcodec.Mpc8Decoder)
  Aac(@libavcodec.AacDecoder)
  Opus(@libavcodec.OpusDecoder)
  Vorbis(@libavcodec.VorbisDecoder, Ref[Int32])
  Flac(Bytes)
  Mp3(@libavcodec.Mp3Decoder)
  DolbyAc3(@libavcodec.Ac3Decoder)
  Dts(@libavcodec.DcaCoreDecoder)
  Mlp(@libavcodec.MlpDecoder)
  Wma(@libavcodec.WmaDecoder, Ref[Int32])
  /// WMA Pro; the queue holds the frames of a packet that a single
  /// `decode` call did not return yet.
  WmaPro(@libavcodec.WmaProDecoder, Ref[Array[AudioFrame]])
  MonkeyAudio(@libavcodec.ApeDecoder)
  Cook(@libavcodec.CookDecoder)
  Sipr(@libavcodec.SiprDecoder)
  RealAudio144(@libavcodec.Ra144Decoder)
  RealAudio288(@libavcodec.Ra288Decoder)
  AmrNb(@libavcodec.AmrNbDecoder)
  AmrWb(@libavcodec.AmrWbDecoder)
  /// ADPCM blocks (`adpcm_ima_wav`, `adpcm_ms`, `adpcm_yamaha`,
  /// `adpcm_ima_oki`); `block_align` is the WAV / MOV block size.
  Adpcm(@libavcodec.AdpcmDecoder)
  AdpcmImaQt(@libavcodec.AdpcmImaQtDecoder)
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
    "musepack8" => {
      guard info.extradata is Some(extra) else {
        raise DecodeError("musepack: missing SV8 stream header")
      }
      let dec = match @libavcodec.Mpc8Decoder::new(extra) {
        Ok(dec) => dec
        Err(e) => raise DecodeError(e)
      }
      {
        dec: Musepack8(dec),
        channels: dec.channels,
        sample_rate: info.sample_rate,
      }
    }
    "musepack7" => {
      guard info.extradata is Some(extra) else {
        raise DecodeError("musepack: missing SV7 stream header")
      }
      let dec = match @libavcodec.Mpc7Decoder::new(extra) {
        Ok(dec) => dec
        Err(e) => raise DecodeError(e)
      }
      { dec: Musepack7(dec), channels: 2, sample_rate: info.sample_rate, }
    }
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
    "vorbis" | "flac" => playback_ogg_audio_decoder(info)
    "ac3" | "eac3" | "dts" | "mlp" | "truehd" => {
      let dec : AudioDec = match info.codec_id {
        "ac3" | "eac3" => DolbyAc3(@libavcodec.ac3_decoder_new())
        "dts" => Dts(@libavcodec.DcaCoreDecoder::new())
        codec => Mlp(@libavcodec.MlpDecoder::new(codec == "truehd"))
      }
      { dec, channels: info.channels, sample_rate: info.sample_rate, }
    }
    "ra_144" =>
      // RealAudio 1.0 carries no codec parameters: 8 kHz mono, as the C
      // decoder's init fixes it.
      {
        dec: RealAudio144(@libavcodec.Ra144Decoder::new()),
        channels: 1,
        sample_rate: if info.sample_rate > 0 { info.sample_rate } else { 8000 },
      }
    // AMR carries no codec parameters either: NB is 8 kHz and WB 16 kHz
    // mono, from the raw stream or the MP4/3GP sample entry.
    "amrnb" =>
      {
        dec: AmrNb(@libavcodec.amrnb_decoder_new()),
        channels: 1,
        sample_rate: if info.sample_rate > 0 { info.sample_rate } else { 8000 },
      }
    "amrwb" =>
      {
        dec: AmrWb(@libavcodec.amrwb_decoder_new()),
        channels: 1,
        sample_rate: if info.sample_rate > 0 { info.sample_rate } else { 16000 },
      }
    // ADPCM: the codecs whose packets carry no block header but the
    // predictor state (Yamaha, OKI) and the QuickTime variant need nothing
    // from the container.
    "adpcm_yamaha" | "adpcm_ima_oki" =>
      match @libavcodec.adpcm_decoder_new(info.codec_id, info.channels) {
        Ok(dec) => { dec: Adpcm(dec), channels: info.channels, sample_rate: info.sample_rate }
        Err(e) => raise DecodeError(e)
      }
    "adpcm_ima_qt" =>
      match @libavcodec.adpcm_ima_qt_decoder_new(info.channels) {
        Ok(dec) => {
          { dec: AdpcmImaQt(dec), channels: info.channels, sample_rate: info.sample_rate }
        }
        Err(e) => raise DecodeError(e)
      }
    // Block-header ADPCM reads `block_align` (and IMA WAV the code width)
    // off the container's stream description: open them through
    // `MediaFile::audio_decoder`.
    "adpcm_ms" | "adpcm_ima_wav" =>
      raise UnsupportedCodec(
        "\{info.codec_id} outside its WAV / MOV container (block_align missing)",
      )
    // These read `block_align` (and the bit rate) off the RealMedia track,
    // which a `StreamInfo` does not carry: open them through
    // `MediaFile::audio_decoder`.
    "cook" | "sipr" | "ra_288" =>
      raise UnsupportedCodec(
        "\{info.codec_id} outside its RealMedia container (block_align missing)",
      )
    // WMA Pro reads `block_align` and its extradata off the ASF stream
    // properties or the WAV format chunk: open it through
    // `MediaFile::audio_decoder`.
    "wmapro" =>
      raise UnsupportedCodec(
        "wmapro outside its ASF / WAV container (block_align missing)",
      )
    "pcm_s8"
    | "pcm_s16le"
    | "pcm_s16be"
    | "pcm_s24le"
    | "pcm_s24be"
    | "pcm_s32le"
    | "pcm_s32be" => {
      let (little_endian, width) = match info.codec_id {
        "pcm_s8" => (false, 1)
        "pcm_s16le" => (true, 2)
        "pcm_s16be" => (false, 2)
        "pcm_s24le" => (true, 3)
        "pcm_s24be" => (false, 3)
        "pcm_s32le" => (true, 4)
        _ => (false, 4)
      }
      guard info.channels > 0 && info.channels <= 0x7fffffff / width else {
        raise DecodeError("pcm: invalid channel count")
      }
      {
        dec: Pcm(little_endian, width),
        channels: info.channels,
        sample_rate: info.sample_rate,
      }
    }
    other => raise UnsupportedCodec(other)
  }
}

///|
/// Open a track using any decoder parameters carried by its container.
pub fn MediaFile::audio_decoder(
  self : MediaFile,
  index : Int32,
) -> AudioDecoder raise MediaError {
  guard self.streams.get(index) is Some(info) else {
    raise UnsupportedCodec("invalid audio stream index")
  }
  match self.source {
    ApeAudio(demux) => {
      let dec = match
        @libavcodec.ape_decoder_new(demux.extradata, demux.channels, demux.bits) {
        Ok(dec) => dec
        Err(e) => raise DecodeError(e)
      }
      {
        dec: MonkeyAudio(dec),
        channels: demux.channels,
        sample_rate: demux.sample_rate,
      }
    }
    AsfAudio(demux) => {
      let track = demux.tracks[index]
      if track.codec == "wmapro" {
        let dec = match
          @libavcodec.wmapro_decoder_new(
            track.extradata,
            track.sample_rate,
            track.channels,
            track.block_align,
          ) {
          Ok(dec) => dec
          Err(e) => raise DecodeError(e)
        }
        return {
          dec: WmaPro(dec, Ref([])),
          channels: dec.channels(),
          sample_rate: track.sample_rate,
        }
      }
      let version = if track.codec == "wmav1" { 1 } else { 2 }
      let offset = if version == 1 { 2 } else { 4 }
      let flags2 = if track.extradata.length() >= offset + 2 {
        track.extradata[offset].to_int() |
        (track.extradata[offset + 1].to_int() << 8)
      } else {
        0
      }
      let flags2 = if version == 2 &&
        track.extradata.length() >= 8 &&
        flags2 == 0xD {
        flags2 & -5
      } else {
        flags2
      }
      let dec = match
        @libavcodec.wma_decoder_new(
          version,
          track.sample_rate,
          track.channels,
          track.bit_rate,
          track.block_align,
          flags2,
        ) {
        Ok(dec) => dec
        Err(e) => raise DecodeError(e)
      }
      {
        dec: Wma(dec, Ref(dec.frame_len * 2)),
        channels: track.channels,
        sample_rate: track.sample_rate,
      }
    }
    RealMediaAudio(demux) => {
      let track = demux.tracks[index]
      let dec : AudioDec = match track.codec {
        "cook" => {
          let dec = match
            @libavcodec.CookDecoder::new(
              track.extradata,
              track.channels,
              track.block_align,
              sample_rate=track.sample_rate,
            ) {
            Ok(dec) => dec
            Err(e) => raise DecodeError(e)
          }
          Cook(dec)
        }
        "sipr" => Sipr(@libavcodec.SiprDecoder::new(track.block_align, bit_rate=track.bit_rate))
        "ra_144" => RealAudio144(@libavcodec.Ra144Decoder::new())
        "ra_288" =>
          match @libavcodec.Ra288Decoder::new(track.block_align) {
            Ok(dec) => RealAudio288(dec)
            Err(e) => raise DecodeError(e)
          }
        // ac3 (dnet, already byte-swapped by the demuxer) and aac (raac /
        // racp, extradata is an AudioSpecificConfig) take everything they
        // need from the `StreamInfo`.
        _ => return AudioDecoder::open(info)
      }
      let (channels, sample_rate) = match track.codec {
        "ra_144" => (1, if track.sample_rate > 0 { track.sample_rate } else { 8000 })
        _ => (track.channels, track.sample_rate)
      }
      { dec, channels, sample_rate }
    }
    // Block-header ADPCM: `block_align` (WAVEFORMAT's, or the MOV sample
    // entry's `bytes_per_frame`) and IMA WAV's code width come from the
    // container, as `ff_pcm_read_packet` and `mov_read_header` hand them to
    // the C decoder.
    Wav(demux, _) if info.codec_id == "adpcm_ms" ||
      info.codec_id == "adpcm_ima_wav" =>
      match
        @libavcodec.adpcm_decoder_new(
          info.codec_id,
          demux.format.channels,
          block_align=demux.format.block_align,
          bits_per_coded_sample=demux.format.bits_per_sample,
        ) {
        Ok(dec) => {
          { dec: Adpcm(dec), channels: info.channels, sample_rate: info.sample_rate }
        }
        Err(e) => raise DecodeError(e)
      }
    // WMA Pro in a WAV: the format chunk carries the same WAVEFORMATEX
    // extension as the ASF stream properties, and the packets are the
    // `block_align` chunks the demuxer cut.
    Wav(demux, _) if info.codec_id == "wmapro" => {
      let dec = match
        @libavcodec.wmapro_decoder_new(
          demux.format.extradata,
          demux.format.sample_rate,
          demux.format.channels,
          demux.format.block_align,
        ) {
        Ok(dec) => dec
        Err(e) => raise DecodeError(e)
      }
      {
        dec: WmaPro(dec, Ref([])),
        channels: dec.channels(),
        sample_rate: demux.format.sample_rate,
      }
    }
    Mov(movie, _) if info.codec_id == "adpcm_ms" ||
      info.codec_id == "adpcm_ima_wav" =>
      match
        @libavcodec.adpcm_decoder_new(
          info.codec_id,
          info.channels,
          block_align=movie.tracks[index].bytes_per_frame.reinterpret_as_int(),
          bits_per_coded_sample=movie.tracks[index].bits_per_sample.reinterpret_as_int(),
        ) {
        Ok(dec) => {
          { dec: Adpcm(dec), channels: info.channels, sample_rate: info.sample_rate }
        }
        Err(e) => raise DecodeError(e)
      }
    _ => AudioDecoder::open(info)
  }
}

///|
fn playback_wma_frame(
  samples : Array[Array[Double]],
  delay : Ref[Int32],
  rate : Int32,
  pts : Int64?,
) -> AudioFrame? {
  guard samples.get(0) is Some(first) else { return None }
  let skip = first.length().min(delay.val)
  delay.val -= skip
  guard first.length() > skip else { return None }
  let samples = if skip == 0 {
    samples
  } else {
    samples.map(ch => ch[skip:].to_owned())
  }
  Some({ samples, nb_samples: first.length() - skip, sample_rate: rate, pts, })
}

///|
/// One WMA Pro packet holds several frames: step the decoder until the
/// packet is used up. A packet the decoder drops (broken, or shorter than
/// `block_align` at the end of a file) yields no frame, as in the C.
fn playback_wmapro_frames(
  dec : @libavcodec.WmaProDecoder,
  data : Bytes,
  rate : Int32,
  pts : Int64?,
) -> Array[AudioFrame] raise MediaError {
  let frames : Array[AudioFrame] = []
  let mut pos = 0
  while pos < data.length() {
    let (used, frame) = match dec.decode_packet(data[pos:].to_owned()) {
      Ok(v) => v
      Err(e) => raise DecodeError(e)
    }
    match frame {
      Some(rows) =>
        frames.push({
          samples: rows,
          nb_samples: rows[0].length(),
          sample_rate: rate,
          pts,
        })
      None => ()
    }
    if used <= 0 {
      break
    }
    pos += used
  }
  frames
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
fn playback_integer_audio_frame(
  pcm : Array[Int32],
  channels : Int32,
  rate : Int32,
  scale : Double,
  pts : Int64,
) -> AudioFrame {
  let nb_samples = pcm.length() / channels
  let samples = Array::makei(channels, ch => {
    Array::makei(nb_samples, i => pcm[i * channels + ch].to_double() / scale)
  })
  { samples, nb_samples, sample_rate: rate, pts: Some(pts), }
}

///|
/// The packet's timestamp as the frame's optional `pts`: the RealMedia
/// demuxer hands `av_nopts_value` for packets whose timestamp it could not
/// derive, which the public frame reports as `None`.
fn playback_optional_pts(pts : Int64) -> Int64? {
  if pts == av_nopts_value { None } else { Some(pts) }
}

///|
/// One ADPCM frame: the decoders' interleaved s16 values as one float row
/// per channel.
fn playback_adpcm_frame(
  samples : Array[Int32],
  channels : Int32,
  rate : Int32,
  pts : Int64,
) -> AudioFrame {
  let nb = if channels > 0 { samples.length() / channels } else { 0 }
  let rows = Array::makei(channels, c =>
    Array::makei(nb, i => samples[i * channels + c].to_double() / 32768.0))
  { samples: rows, nb_samples: nb, sample_rate: rate, pts: Some(pts) }
}

///|
/// Decode one packet. `Ok(None)` means the packet produced no frame.
pub fn AudioDecoder::decode(
  self : AudioDecoder,
  pkt : MediaPacket,
) -> AudioFrame? raise MediaError {
  match self.dec {
    Musepack8(dec) => {
      let pcm = match dec.decode_packet(pkt.data) {
        Ok(pcm) => pcm
        Err(e) => raise DecodeError(e)
      }
      let samples = pcm.map(ch => ch.map(sample => sample.to_double() / 32768.0))
      Some({
        samples,
        nb_samples: pcm[0].length(),
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Musepack7(dec) => {
      let pcm = match dec.decode_packet(pkt.data) {
        Ok(pcm) => pcm
        Err(e) => raise DecodeError(e)
      }
      let samples = pcm.map(ch => ch.map(sample => sample.to_double() / 32768.0))
      Some({
        samples,
        nb_samples: pcm[0].length(),
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
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
    Vorbis(dec, first) => {
      let samples = match dec.decode_packet_native(pkt.data) {
        Ok(value) => value
        Err(e) => raise DecodeError(e)
      }
      let nb_samples = samples[0].length()
      if first.val < 0 {
        first.val = nb_samples
        return None
      }
      Some({
        samples,
        nb_samples,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Flac(streaminfo) => {
      let out = match @libavcodec.flac_decode_packet(streaminfo, pkt.data) {
        Ok(value) => value
        Err(e) => raise DecodeError(e)
      }
      let scale = if out.bits <= 16 { 32768.0 } else { 2147483648.0 }
      Some(
        playback_integer_audio_frame(
          out.samples,
          out.channels,
          out.sample_rate,
          scale,
          pkt.pts,
        ),
      )
    }
    DolbyAc3(dec) =>
      match dec.decode_frame(pkt.data) {
        Ok(out) =>
          Some({
            samples: out.samples,
            nb_samples: out.samples[0].length(),
            sample_rate: out.sample_rate,
            pts: Some(pkt.pts),
          })
        Err(e) => raise DecodeError(e)
      }
    Dts(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(Some(out)) =>
          Some(
            playback_integer_audio_frame(
              out.samples,
              out.channels,
              out.sample_rate,
              2147483648.0,
              pkt.pts,
            ),
          )
        Ok(None) => None
        Err(e) => raise DecodeError(e)
      }
    Mlp(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(Some(out)) => {
          let scale = if out.bits <= 16 { 32768.0 } else { 2147483648.0 }
          Some(
            playback_integer_audio_frame(
              out.samples,
              out.channels,
              out.sample_rate,
              scale,
              pkt.pts,
            ),
          )
        }
        Ok(None) => None
        Err(e) => raise DecodeError(e)
      }
    Wma(dec, delay) =>
      match dec.decode_packet(pkt.data) {
        Ok(samples) =>
          playback_wma_frame(samples, delay, self.sample_rate, Some(pkt.pts))
        Err(e) => raise DecodeError(e)
      }
    // A packet holds several frames: decode it whole and return the first;
    // the rest follow from the queue.
    WmaPro(dec, pending) => {
      if pending.val.length() == 0 {
        pending.val = playback_wmapro_frames(
          dec,
          pkt.data,
          self.sample_rate,
          Some(pkt.pts),
        )
      }
      if pending.val.length() == 0 {
        None
      } else {
        let first = pending.val[0]
        pending.val = pending.val[1:].to_owned()
        Some(first)
      }
    }
    MonkeyAudio(dec) => {
      let samples = Array::makei(self.channels, _ => [])
      let mut nb_samples = 0
      for ;; {
        let chunk = match dec.decode_frame(pkt.data) {
          Ok(chunk) => chunk
          Err(e) => raise DecodeError(e)
        }
        let frame = chunk.frame
        let (center, scale) = match frame.bps {
          8 => (128, 128.0)
          16 => (0, 32768.0)
          _ => (0, 2147483648.0)
        }
        for ch, row in samples {
          for i in 0..<frame.nb_samples {
            row.push(
              (frame.samples[i * self.channels + ch] - center).to_double() /
              scale,
            )
          }
        }
        nb_samples += frame.nb_samples
        if chunk.packet_done {
          break
        }
      }
      Some({
        samples,
        nb_samples,
        sample_rate: self.sample_rate,
        pts: Some(pkt.pts),
      })
    }
    Cook(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(Some(frame)) =>
          Some({
            samples: frame.samples.map(row => Array::makei(row.length(), i => row[i])),
            nb_samples: frame.samples[0].length(),
            sample_rate: self.sample_rate,
            pts: playback_optional_pts(pkt.pts),
          })
        // The decoder's two warm-up packets, or one shorter than
        // `block_align`.
        Ok(None) => None
        Err(e) => raise DecodeError(e)
      }
    Sipr(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(pcm) =>
          Some({
            samples: [pcm],
            nb_samples: pcm.length(),
            sample_rate: self.sample_rate,
            pts: playback_optional_pts(pkt.pts),
          })
        Err(e) => raise DecodeError(e)
      }
    RealAudio144(dec) => {
      // The C decoder consumes a packet 20 bytes at a time and refuses only
      // a trailing partial frame (`Frame too small`) - after the complete
      // frames went out - and fftools logs that and carries on. The last
      // packet of a truncated file arrives this way, flagged corrupt by the
      // demuxer: decode its whole frames and drop the remainder; a packet
      // without a whole frame yields none.
      let whole = pkt.data.length() - pkt.data.length() % 20
      if whole == 0 {
        return None
      }
      let pcm = match dec.decode_packet(pkt.data[:whole].to_owned()) {
        Ok(pcm) => pcm
        Err(e) => raise DecodeError(e)
      }
      Some({
        samples: [pcm.map(sample => sample.to_double() / 32768.0)],
        nb_samples: pcm.length(),
        sample_rate: self.sample_rate,
        pts: playback_optional_pts(pkt.pts),
      })
    }
    RealAudio288(dec) =>
      match dec.decode_packet(pkt.data) {
        Ok(pcm) =>
          Some({
            samples: [pcm],
            nb_samples: pcm.length(),
            sample_rate: self.sample_rate,
            pts: playback_optional_pts(pkt.pts),
          })
        Err(e) => raise DecodeError(e)
      }
    AmrNb(dec) =>
      match dec.decode_frame(pkt.data) {
        Ok(pcm) =>
          Some({
            samples: [pcm],
            nb_samples: pcm.length(),
            sample_rate: self.sample_rate,
            pts: playback_optional_pts(pkt.pts),
          })
        Err(e) => raise DecodeError(e)
      }
    AmrWb(dec) =>
      match dec.decode_frame(pkt.data) {
        Ok(pcm) =>
          Some({
            samples: [pcm],
            nb_samples: pcm.length(),
            sample_rate: self.sample_rate,
            pts: playback_optional_pts(pkt.pts),
          })
        Err(e) => raise DecodeError(e)
      }
    Adpcm(dec) =>
      match dec.decode_block(pkt.data) {
        Ok(audio) =>
          Some(
            playback_adpcm_frame(audio.samples, audio.channels, self.sample_rate, pkt.pts),
          )
        Err(e) => raise DecodeError(e)
      }
    AdpcmImaQt(dec) => {
      // one 34-byte block per channel per frame
      let block = 34 * self.channels
      if pkt.data.length() < block {
        raise DecodeError("adpcm: truncated IMA QuickTime block")
      }
      match dec.decode_block(pkt.data[:block].to_owned()) {
        Ok(samples) =>
          Some(playback_adpcm_frame(samples, self.channels, self.sample_rate, pkt.pts))
        Err(e) => raise DecodeError(e)
      }
    }
    Pcm(little_endian, bytes_per_sample) => {
      let frame_bytes = self.channels * bytes_per_sample
      if pkt.data.length() < frame_bytes {
        return None
      }
      let nb = pkt.data.length() / frame_bytes
      let pad_bits = 32 - bytes_per_sample * 8
      let scale = (1L << (31 - pad_bits)).to_double()
      let channels : Array[Array[Double]] = []
      for ch in 0..<self.channels {
        let row : Array[Double] = Array::make(nb, 0.0)
        for i in 0..<nb {
          let base = (i * self.channels + ch) * bytes_per_sample
          let raw = for j in 0..<bytes_per_sample; raw = 0 {
            let index = if little_endian { bytes_per_sample - 1 - j } else { j }
            continue (raw << 8) | pkt.data[base + index].to_int()
          } nobreak {
            raw
          }
          let signed = raw << pad_bits >> pad_bits
          row[i] = signed.to_double() / scale
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
    WmaPro(dec, _) =>
      playback_wmapro_frames(dec, pkt.data, self.sample_rate, Some(pkt.pts))
    Mlp(_) | Wma(_, _) => {
      let frames = []
      let mut pos = 0
      while pos < pkt.data.length() {
        let size = match self.dec {
          Wma(dec, _) => dec.block_align
          _ => @libavcodec.mlp_access_unit_size(pkt.data[pos:])
        }
        if size < 4 || size > pkt.data.length() - pos {
          raise DecodeError("invalid audio access unit length at \{pos}")
        }
        let data = pkt.data[pos:pos + size].to_owned()
        if self.decode({ ..pkt, data, }) is Some(frame) {
          frames.push(frame)
        }
        pos += size
      }
      frames
    }
    // A packet holds as many blocks as its block size allows; a block that
    // fails after the first one ends the packet silently (a truncated tail
    // past the last complete block, which the C logs and drops as well).
    Adpcm(dec) => {
      let frames = []
      let mut rest = pkt.data
      let mut first = true
      while rest.length() > 0 {
        match dec.decode_block(rest) {
          Ok(audio) => {
            frames.push(
              playback_adpcm_frame(audio.samples, audio.channels, self.sample_rate, pkt.pts),
            )
            rest = rest[dec.packet_consumed(rest.length()):].to_owned()
          }
          Err(e) => if first { raise DecodeError(e) } else { break }
        }
        first = false
      }
      frames
    }
    AdpcmImaQt(dec) => {
      let frames = []
      let block = 34 * self.channels
      let mut rest = pkt.data
      let mut first = true
      while rest.length() >= block {
        match dec.decode_block(rest[:block].to_owned()) {
          Ok(samples) => {
            frames.push(
              playback_adpcm_frame(samples, self.channels, self.sample_rate, pkt.pts),
            )
            rest = rest[block:].to_owned()
          }
          Err(e) => if first { raise DecodeError(e) } else { break }
        }
        first = false
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
/// Drain a buffered final audio frame at EOF. Call once after the last packet.
pub fn AudioDecoder::flush(self : AudioDecoder) -> AudioFrame? raise MediaError {
  match self.dec {
    Wma(dec, delay) =>
      match dec.decode_flush() {
        Ok(samples) =>
          playback_wma_frame(samples, delay, self.sample_rate, None)
        Err(e) => raise DecodeError(e)
      }
    // WMA Pro has no end-of-stream frame to drain here: the decoder can
    // emit the last half frame (`WmaProDecoder::flush`), but the C codec
    // lacks AV_CODEC_CAP_DELAY, so fftools never asks for it.
    _ => None
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
    StillImage(_) | AsfAudio(_) => None
    RawDts({ total_samples, sample_rate, .. }, _)
    | RawAc3({ total_samples, sample_rate, .. }, _)
    | Amr({ total_samples, sample_rate, .. }, _) =>
      Some(total_samples.to_double() / sample_rate.to_double())
    AiffAudio(demux, _) =>
      Some(
        demux.sample_count.to_double() / demux.format.sample_rate.to_double(),
      )
    ApeAudio(demux) =>
      Some(demux.total_samples.to_double() / demux.sample_rate.to_double())
    MusepackAudio(demux) =>
      Some(
        demux.frame_count.to_double() * 1152.0 / demux.sample_rate.to_double(),
      )
    Musepack8Audio(demux) =>
      Some(demux.samples.to_double() / demux.sample_rate.to_double())
    RealMediaAudio(demux) =>
      // `rm_read_header`: the PROP chunk's duration in ms while no stream
      // declares one of its own (a stream duration resets the file's), else
      // the longest stream - the format duration `update_stream_timings`
      // derives. ffprobe may refine stream durations from the packets
      // (`estimate_timings_from_pts`); that is not reproduced.
      if demux.duration != av_nopts_value && demux.duration > 0L {
        Some(demux.duration.to_double() / 1000.0)
      } else {
        let mut longest = 0L
        for track in demux.tracks {
          if track.duration > longest {
            longest = track.duration
          }
        }
        if longest > 0L {
          Some(longest.to_double() / 1000.0)
        } else {
          None
        }
      }
    OggVorbis(demux) if demux.total_samples > 0L =>
      Some(demux.total_samples.to_double() / demux.sample_rate.to_double())
    OggFlac(demux) if demux.total_samples > 0L =>
      Some(demux.total_samples.to_double() / demux.sample_rate.to_double())
    OggVorbis(_) | OggFlac(_) => None
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
  /// Why the container's packet walk ended early (a truncated or damaged
  /// RealMedia chunk, ...); empty when the file was read to its end. The
  /// packets before the failure are complete and are all decoded, as
  /// fftools keeps the output of a damaged input.
  read_error : String
}

///|
/// The demuxer error that ended the packet walk early, or `""` when the
/// container was read to its end.
pub fn DecodedAudio::read_error(self : DecodedAudio) -> String {
  self.read_error
}

///|
fn playback_append_audio(
  rows : Array[Array[Double]],
  rate : Int32,
  frame : AudioFrame,
  from : Int32,
) -> Int32 raise MediaError {
  if rows.is_empty() {
    for channel in frame.samples {
      rows.push(channel[from:].to_owned())
    }
    return frame.sample_rate
  }
  guard rows.length() == frame.samples.length() && rate == frame.sample_rate else {
    raise DecodeError("decoded audio format changed within the stream")
  }
  for ch, row in rows {
    for sample in frame.samples[ch][from:] {
      row.push(sample)
    }
  }
  rate
}

///|
/// `next_packet` for the bulk walks (the decode engine, the packet dumps).
/// A demuxer's end-of-stream error - the packets it read before a damaged
/// chunk are complete - ends the walk with `Err(reason)` instead of raising,
/// the way fftools logs it and treats the input as ended. Only the RealMedia
/// adapter reports such an error; every other source keeps raising.
fn MediaFile::next_packet_tolerant(
  self : MediaFile,
) -> Result[MediaPacket?, String] raise MediaError {
  match self.source {
    RealMediaAudio(_) =>
      try {
        Ok(self.next_packet())
      } catch {
        DemuxError(e) => Err(e)
        other => raise other
      }
    _ => Ok(self.next_packet())
  }
}

///|
/// Decode the first audio stream of a container to PCM - the engine the JSON
/// CLI's `decode-audio` command and the libswresample slice build on. Files
/// without an audio stream raise `UnsupportedCodec` with the format name.
pub fn decode_audio_file(
  data : Bytes,
  sample_budget? : Int64,
) -> DecodedAudio raise MediaError {
  if data.length() >= 4 && data[:4] == b"ajkg"[:] {
    return playback_decode_shorten(data, sample_budget)
  }
  if data.length() >= 4 && data[:4] == b"wvpk"[:] {
    return playback_decode_wavpack(data, sample_budget)
  }
  if data.length() >= 8 {
    match data[4:8] {
      [0xf8, 0x72, 0x6f, 0xba] =>
        return playback_decode_mlp(data, true, sample_budget)
      [0xf8, 0x72, 0x6f, 0xbb] =>
        return playback_decode_mlp(data, false, sample_budget)
      _ => ()
    }
  }
  let mf = MediaFile::open(data)
  if mf.source is ApeAudio(demux) && sample_budget is Some(limit) {
    guard demux.total_samples * demux.channels.to_int64() <= limit else {
      raise DecodeError("decoded audio sample budget exceeded")
    }
  }
  let mut audio = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if audio < 0 && mf.streams()[i].media_type == MediaType::Audio {
      audio = i
    }
  }
  if audio < 0 {
    raise UnsupportedCodec("no audio stream in \{mf.format_name()}")
  }
  let dec = mf.audio_decoder(audio)
  let rows : Array[Array[Double]] = []
  let mut rate = dec.sample_rate()
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
  let mut decoded = 0L
  let mut read_error = ""
  while true {
    let pkt = match mf.next_packet_tolerant() {
      Ok(pkt) => pkt
      Err(e) => {
        read_error = e
        None
      }
    }
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
      if sample_budget is Some(limit) {
        decoded += f.nb_samples.to_int64() * f.samples.length().to_int64()
        guard decoded <= limit else {
          raise DecodeError("decoded audio sample budget exceeded")
        }
      }
      if discarded {
        skip = if skip > f.nb_samples { skip - f.nb_samples } else { 0 }
        continue
      }
      let from = if skip < f.nb_samples { skip } else { f.nb_samples }
      skip = skip - from
      rate = playback_append_audio(rows, rate, f, from)
    }
  }
  if nth > 0 {
    if dec.flush() is Some(f) {
      if sample_budget is Some(limit) {
        decoded += f.nb_samples.to_int64() * f.samples.length().to_int64()
        guard decoded <= limit else {
          raise DecodeError("decoded audio sample budget exceeded")
        }
      }
      rate = playback_append_audio(rows, rate, f, 0)
    }
  }
  if rows.is_empty() {
    for _ in 0..<dec.channels() {
      rows.push([])
    }
  }
  // Ogg Opus pre-skip from OpusHead (initial_padding) trims the head.
  let head = match mf.source {
    OggOpus(demux) => demux.pre_skip
    _ => 0
  }
  let tail = match (mf.source, dec.dec) {
    (OggVorbis(demux), Vorbis(_, first)) if demux.total_samples > 0L &&
      !rows.is_empty() => {
      // A priming packet with granule zero contributes no presentation
      // samples. Preserve the existing offset for positive initial granules.
      let offset = if demux.packets[0].granule == 0L {
        0L
      } else {
        first.val.max(0).to_int64()
      }
      (rows[0].length().to_int64() - (demux.total_samples - offset).max(0L))
      .max(0L)
      .to_int()
    }
    _ => tail
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
    sample_rate: rate,
    channels: rows.length(),
    format_name: mf.format_name(),
    codec_id: mf.streams()[audio].codec_id,
    duration_seconds: mf.duration_seconds(),
    read_error,
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
  let inter = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    e => raise DecodeError(e.to_string())
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
    H264(f) => f.bit_depth
    Hevc(f) => f.bit_depth
    Vp9(f) => f.bit_depth
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
    H264(f) => f.yuvp()
    Hevc(f) => f.yuvp(f.bit_depth)
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
  pixel_budget? : Int64,
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
          pixel_budget?,
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
