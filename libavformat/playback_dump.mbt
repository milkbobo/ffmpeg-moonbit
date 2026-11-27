///|
/// Packet dumping for the CLI's `dump-packets` command (proposal
/// deliverable ②): one JSON object per packet, ffprobe `-show_packets`
/// style - `stream_index`, `pts` (the container's own timebase, converted to
/// milliseconds like ffprobe's default `pts_time`), `size` and `flags`
/// (`K` for keyframe, `-` otherwise). `MediaFile::dump_packets_json`
/// renders the whole file as newline-delimited JSON; the command streams
/// them line by line.
///
/// The timebase conversion is per container, matching what each demuxer
/// reports: MP4 tracks carry `mdhd` timescales, Matroska packets carry
/// nanosecond-scaled timecodes, Ogg Opus granules are 48 kHz samples, and
/// WAV's packetiser emits sample counts at the file rate.

///|
/// One stream's timebase as (ticks_per_second, tick_offset); `None` when the
/// container declares no usable timestamps for that stream. All four
/// adapters already emit packet `pts` on FFmpeg's presentation timeline
/// (the Ogg demuxer folds granule walk-back and pre-skip in), so the offset
/// is zero everywhere today - it stays in the signature for containers
/// that need a shift (e.g. MP4 edit lists applied at the demux layer).
fn MediaFile::stream_timebase(
  self : MediaFile,
  index : Int32,
) -> (Double, Double)? {
  match self.source {
    Mov(movie, _) => {
      let track = movie.tracks[index]
      if track.timescale > 0U {
        Some((track.timescale.to_double(), 0.0))
      } else {
        None
      }
    }
    Mkv(mh) => Some((1.0e9 / mh.time_scale.to_double(), 0.0))
    OggOpus(_) => Some((48000.0, 0.0))
    OggVorbis(demux) => Some((demux.sample_rate.to_double(), 0.0))
    OggFlac(demux) => Some((demux.sample_rate.to_double(), 0.0))
    AsfAudio(_) | FlvAudio(_, _) => Some((1000.0, 0.0))
    RealMediaAudio(_) => Some((1000.0, 0.0))
    RawAdts(_, _, _) => Some((self.streams[index].sample_rate.to_double(), 0.0))
    LoasAac(_, sample_rate, _) => Some((sample_rate.to_double(), 0.0))
    RawDts({ sample_rate, .. }, _)
    | RawSpdif({ sample_rate, .. }, _)
    | RawMpegAudio({ sample_rate, .. }, _, _, _)
    | NativeFlac({ sample_rate, .. }, _)
    | RawGsm({ sample_rate, .. }, _)
    | RawTelephony({ sample_rate, .. }, _, _)
    | WestwoodAud({ sample_rate, .. }, _)
    | RawSbc({ sample_rate, .. }, _)
    | RawAdx({ sample_rate, .. }, _)
    | RetroAudio({ sample_rate, .. }, _)
    | RawQoa({ sample_rate, .. }, _)
    | DsdAudio({ sample_rate, .. }, _)
    | RawAc3({ sample_rate, .. }, _)
    | Amr({ sample_rate, .. }, _) => Some((sample_rate.to_double(), 0.0))
    AiffAudio({ format: { sample_rate, .. }, .. }, _)
    | AuAudio({ format: { sample_rate, .. }, .. }, _)
    | CafAudio({ format: { sample_rate, .. }, .. }, _) =>
      Some((sample_rate.to_double(), 0.0))
    RawTta(track, _) => Some((track.header.sample_rate.to_double(), 0.0))
    ApeAudio(demux) => Some((demux.sample_rate.to_double(), 0.0))
    MusepackAudio(demux) => Some((demux.sample_rate.to_double() / 1152.0, 0.0))
    Musepack8Audio(demux) =>
      Some(
        (
          demux.sample_rate.to_double() /
          (1152 * demux.frames_per_packet).to_double(),
          0.0,
        ),
      )
    StillImage(_) => None
    Wav(demux, _) =>
      if demux.format.sample_rate > 0 {
        Some((demux.format.sample_rate.to_double(), 0.0))
      } else {
        None
      }
    Ts(_, _) => Some((90000.0, 0.0))
  }
}

///|
/// Dump every packet as one JSON object per line (`packet` entries like
/// ffprobe's `-show_packets -of json` flattened to JSONL). Streams may be
/// filtered (`stream` = -1 for all) and the walk capped (`limit` = -1 for
/// everything; only emitted lines count toward it). The returned string
/// ends with a newline per emitted line.
pub fn MediaFile::dump_packets_json(
  self : MediaFile,
  stream~ : Int32 = -1,
  limit~ : Int32 = -1,
) -> String raise MediaError {
  let out = StringBuilder()
  let timebases : Array[(Double, Double)?] = []
  for i = 0; i < self.streams().length(); i = i + 1 {
    timebases.push(self.stream_timebase(i))
  }
  let mut emitted = 0
  while true {
    if limit >= 0 && emitted >= limit {
      break
    }
    let p = match self.next_packet_tolerant() {
      Ok(Some(pkt)) => pkt
      // ffprobe prints the packets a demuxer delivered before it failed
      // and exits 0, so the walk ends at the error instead of raising it.
      Ok(None) | Err(_) => break
    }
    if stream >= 0 && p.stream_index != stream {
      continue
    }
    let pts_ms = match timebases[p.stream_index] {
      Some((tps, off)) => {
        let ms = (p.pts.to_double() + off) * 1000.0 / tps
        // NaN (or absurd magnitudes from broken timestamps) render as null,
        // like ffprobe prints "N/A".
        if ms == ms && ms.abs() < 1.0e15 {
          ms.to_string()
        } else {
          "null"
        }
      }
      None => "null"
    }
    let flag = if p.keyframe { "K" } else { "-" }
    let size = if self.source is Ts(_, _) &&
      self.streams[p.stream_index].codec_id == "opus" &&
      ts_opus_control(p.data[:]) is Ok(control) {
      control.payload_end - control.payload_start
    } else {
      p.data.length()
    }
    out.write_string(
      "{\"stream_index\": \{p.stream_index}, \"pts_ms\": \{pts_ms}, \"size\": \{size}, \"flags\": \"\{flag}\"}\n",
    )
    emitted = emitted + 1
  }
  out.to_string()
}

///|
/// Render the `decode-audio` result as one JSON summary object (the PCM
/// itself goes to the WAV the command writes; this is what prints on
/// stdout): stream parameters, decoded length and duration.
pub fn DecodedAudio::summary_json(self : DecodedAudio) -> String {
  let dur = match self.duration_seconds {
    Some(v) => v.to_string()
    None => "null"
  }
  let nb = if self.samples.length() > 0 { self.samples[0].length() } else { 0 }
  let real_dur = if self.sample_rate > 0 {
    (nb.to_double() / self.sample_rate.to_double()).to_string()
  } else {
    "null"
  }
  let read_error = if self.read_error == "" {
    "null"
  } else {
    "\"" + probe_json_escape_for_test(self.read_error) + "\""
  }
  "{\n  \"codec_name\": \"\{self.codec_id}\",\n  \"sample_rate\": \{self.sample_rate},\n  \"channels\": \{self.channels},\n  \"format_name\": \"\{self.format_name}\",\n  \"samples_per_channel\": \{nb},\n  \"container_duration\": \{dur},\n  \"decoded_duration\": \{real_dur},\n  \"read_error\": \{read_error}\n}"
}
