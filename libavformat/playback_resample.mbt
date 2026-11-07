///|
/// Resampling facade over the libswresample polyphase port: FFmpeg's
/// `aresample` semantics (32 taps, kaiser 9, mirrored start-up history
/// and flush tail) applied to a fully decoded stream.

///|
/// Resample every channel of a decoded stream to `rate` (8000..=192000).
/// The whole stream is fed in one pass (output values never depend on
/// chunking); equal rates return the stream unchanged.  The returned
/// `DecodedAudio` carries the new rate with all labels preserved.
pub fn DecodedAudio::resample_to(
  self : DecodedAudio,
  rate : Int32,
) -> DecodedAudio raise MediaError {
  if rate == self.sample_rate {
    return self
  }
  guard rate >= 8000 && rate <= 192000 else {
    raise DemuxError("resample: target rate must be in 8000..=192000")
  }
  let resampler = @swr.SwrResampler::new(
    in_rate=self.sample_rate,
    out_rate=rate,
    channels=self.channels,
  ) catch {
    InvalidResampleConfig(m) => raise DemuxError(m)
  }
  let per_channel : Array[Array[Double]] = []
  for _ in 0..<self.channels {
    per_channel.push([])
  }
  // process + flush, then reassemble per channel (the resampler returns
  // one plane of new samples per call).
  let calls : Array[Array[Array[Double]]] = [
    resampler.process(self.samples) catch {
      InvalidResampleConfig(m) => raise DemuxError(m)
    },
    resampler.flush(),
  ]
  for call in calls {
    for ci in 0..<call.length() {
      for v in call[ci] {
        per_channel[ci].push(v)
      }
    }
  }
  {
    samples: per_channel,
    sample_rate: rate,
    channels: self.channels,
    format_name: self.format_name,
    codec_id: self.codec_id,
    duration_seconds: self.duration_seconds,
  }
}
