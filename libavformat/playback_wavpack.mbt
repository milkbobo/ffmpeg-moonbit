///|
fn playback_decode_wavpack(
  data : Bytes,
  budget : Int64?,
) -> DecodedAudio raise MediaError {
  let out = match @libavcodec.ff_wavpack_decode(data, sample_budget?=budget) {
    Ok(out) => out
    Err(e) => raise DecodeError(e)
  }
  let count = out.samples.length() / out.channels
  let scale = if out.bits <= 16 { 32768.0 } else { 2147483648.0 }
  let samples = Array::makei(out.channels, ch => {
    Array::makei(count, i => {
      out.samples[i * out.channels + ch].to_double() / scale
    })
  })
  {
    samples,
    sample_rate: out.sample_rate,
    channels: out.channels,
    format_name: "wv",
    codec_id: "wavpack",
    duration_seconds: Some(count.to_double() / out.sample_rate.to_double()),
    read_error: "",
    channel_mask: 0U,
  }
}
