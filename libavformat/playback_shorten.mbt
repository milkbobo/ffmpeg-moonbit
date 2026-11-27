///|
/// Shorten commands are bit-aligned and carry predictor history throughout
/// the file. Decode the raw stream without inventing packet boundaries.
fn playback_decode_shorten(
  data : Bytes,
  budget : Int64?,
) -> DecodedAudio raise MediaError {
  let out = match
    @libavcodec.ff_shorten_decode(
      data,
      allow_truncated=true,
      sample_budget?=budget,
    ) {
    Ok(out) => out
    Err(e) => raise DecodeError(e)
  }
  let count = out.samples.length() / out.channels
  let (center, scale) = if out.bits == 8 { (128, 128.0) } else { (0, 32768.0) }
  let samples = Array::makei(out.channels, ch => {
    Array::makei(count, i => {
      (out.samples[i * out.channels + ch] - center).to_double() / scale
    })
  })
  {
    samples,
    sample_rate: out.sample_rate,
    channels: out.channels,
    format_name: "shn",
    codec_id: "shorten",
    duration_seconds: Some(count.to_double() / out.sample_rate.to_double()),
    read_error: "",
    channel_mask: 0U,
  }
}
