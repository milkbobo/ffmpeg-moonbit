///|
/// Seeking for the MP4/MOV demuxer slice, ported from FFmpeg 9.0.2
/// `libavformat/mov.c` (`mov_seek_stream`, `can_seek_to_key_sample`) and
/// `libavformat/seek.c` (`ff_index_search_timestamp`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations, all documented:
///   * `sc->min_corrected_pts` is always 0 here (only the not-ported
///     `advanced_editlist` pass produces a non-zero value).
///   * `can_seek_to_key_sample`'s open-GOP status comes from the
///     `sgpd`('sync') + `sbgp` pass (`build_open_gop_key_points` in
///     mov.mbt); without sync groups every key sample counts as closed,
///     which is what FFmpeg itself falls back to when `open_key_samples`
///     is empty. The HEVC-only gate is keyed on the `hvc1`/`hev1`
///     sample-entry fourcc.
///   * `mov_seek_fragment` and the frag-index walk are unnecessary: this port
///     materialises every sample up front, so the index search below already
///     covers fragmented files.

///| `AVSEEK_FLAG_BACKWARD` semantics for `index_search_timestamp`. */
pub let avseek_flag_backward : Int = 1

///| `AVSEEK_FLAG_ANY` semantics for `index_search_timestamp`. */
pub let avseek_flag_any : Int = 4

///|
/// `ff_index_search_timestamp` over the materialised sample index (the entry
/// timestamp is the DTS). Returns the sample index, or -1 when no entry
/// satisfies the request.
pub fn index_search_timestamp(
  samples : Array[Mp4Sample],
  wanted_timestamp : Int64,
  flags : Int
) -> Int {
  let nb_entries = samples.length()
  if nb_entries <= 0 {
    return -1
  }
  let mut a = -1
  let mut b = nb_entries
  // Optimize appending index entries at the end.
  if samples[b - 1].dts < wanted_timestamp {
    a = b - 1
  }
  while b - a > 1 {
    let mut m = (a + b) >> 1
    // Search for the next non-discarded packet.
    while samples[m].discard && m < b && m < nb_entries - 1 {
      m = m + 1
      if m == b && samples[m].dts >= wanted_timestamp {
        m = b - 1
        break
      }
    }
    let timestamp = samples[m].dts
    if timestamp >= wanted_timestamp {
      b = m
    }
    if timestamp <= wanted_timestamp {
      a = m
    }
  }
  let backward = (flags & avseek_flag_backward) != 0
  let mut m = if backward { a } else { b }
  if (flags & avseek_flag_any) == 0 {
    let step = if backward { -1 } else { 1 }
    while m >= 0 && m < nb_entries && !samples[m].keyframe {
      m = m + step
    }
  }
  if m == nb_entries {
    return -1
  }
  m
}

///|
/// `can_seek_to_key_sample`: HEVC open-GOP samples that would be presented
/// before the request point are not safe to seek to, even though they come
/// after in decoding order. `key_sample_pts = dts + sample_offset + dts_shift`
/// with the per-sample ctts offset from `build_open_gop_key_points`.
fn can_seek_to_key_sample(
  track : Mp4Track,
  sample : Int,
  requested_pts : Int64
) -> Bool {
  let hevc = track.codec == "hvc1" || track.codec == "hev1"
  if !hevc {
    return true
  }
  if sample >= track.sample_offsets.length() {
    return true
  }
  let key_sample_dts = track.samples[sample].dts
  let key_sample_pts = key_sample_dts +
    track.sample_offsets[sample].to_int64() +
    track.dts_shift.to_int64()
  if is_open_key_sample(track, sample) && key_sample_pts > requested_pts {
    return false
  }
  true
}

///|
/// `mov_seek_stream`: find the sample a seek to `timestamp` (in track
/// timescale units, interpreted as a PTS as in the C) should start from.
/// Returns the sample index.
pub fn mov_seek_stream(
  track : Mp4Track,
  timestamp : Int64,
  flags : Int
) -> Result[Int, String] {
  // Here we consider timestamp to be PTS, hence try to offset it so that we
  // can search over the DTS timeline.
  let mut ts = timestamp - track.dts_shift.to_int64()
  let backward = (flags & avseek_flag_backward) != 0
  let any = (flags & avseek_flag_any) != 0
  let search_flags = (if backward { avseek_flag_backward } else { 0 }) +
    (if any { avseek_flag_any } else { 0 })
  let mut sample = -1
  let mut settled = false
  while !settled {
    sample = index_search_timestamp(track.samples, ts, search_flags)
    if sample < 0 &&
      track.samples.length() > 0 &&
      ts < track.samples[0].dts {
      sample = 0
    }
    if sample < 0 {
      // not sure what to do
      return Err("EINVAL")
    }
    if sample == 0 || can_seek_to_key_sample(track, sample, ts) {
      settled = true
      break
    }
    let step : Int64 = if track.min_sample_duration > 1 {
      track.min_sample_duration.to_int64()
    } else {
      1
    }
    let next_ts = ts - step
    let requested_sample = index_search_timestamp(
      track.samples,
      next_ts,
      search_flags,
    )
    if requested_sample < 0 {
      return Err("EINVAL")
    }
    // If we've reached a different sample trying to find a good pts to seek
    // to, give up searching.
    if sample != requested_sample &&
      !can_seek_to_key_sample(track, requested_sample, next_ts) {
      settled = true
      break
    }
    ts = next_ts
  }
  Ok(sample)
}

///|
/// `mov_read_seek` for one track: seek by a timestamp in the track's media
/// timescale (the equivalent of `av_seek_frame` with the stream time base
/// 1/timescale). The found sample's DTS is returned alongside its index.
pub fn mov_seek_track(
  track : Mp4Track,
  timestamp : Int64,
  flags : Int
) -> Result[(Int, Int64), String] {
  match mov_seek_stream(track, timestamp, flags) {
    Err(e) => Err(e)
    Ok(sample) => Ok((sample, track.samples[sample].dts))
  }
}
