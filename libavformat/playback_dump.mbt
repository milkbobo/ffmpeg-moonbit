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
fn MediaFile::stream_timebase(self : MediaFile, index : Int) -> (Double, Double)? {
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
    Wav(demux, _) =>
      if demux.format.sample_rate > 0 {
        Some((demux.format.sample_rate.to_double(), 0.0))
      } else {
        None
      }
    Ts(_) => Some((90000.0, 0.0))
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
  stream~ : Int = -1,
  limit~ : Int = -1,
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
    let p = match self.next_packet() {
      Some(pkt) => pkt
      None => break
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
    out.write_string(
      "{\"stream_index\": \{p.stream_index}, \"pts_ms\": \{pts_ms}, \"size\": \{p.data.length()}, \"flags\": \"\{flag}\"}\n",
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
  let nb = if self.samples.length() > 0 {
    self.samples[0].length()
  } else {
    0
  }
  let real_dur = if self.sample_rate > 0 {
    (nb.to_double() / self.sample_rate.to_double()).to_string()
  } else {
    "null"
  }
  "{\n  \"codec_name\": \"\{self.codec_id}\",\n  \"sample_rate\": \{self.sample_rate},\n  \"channels\": \{self.channels},\n  \"format_name\": \"\{self.format_name}\",\n  \"samples_per_channel\": \{nb},\n  \"container_duration\": \{dur},\n  \"decoded_duration\": \{real_dur}\n}"
}
