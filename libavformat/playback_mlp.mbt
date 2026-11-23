///|
fn playback_decode_mlp(
  data : Bytes,
  truehd : Bool,
  budget : Int64?,
) -> DecodedAudio raise MediaError {
  let codec = if truehd { "truehd" } else { "mlp" }
  let dec = @libavcodec.MlpDecoder::new(truehd)
  let rows : Array[Array[Double]] = []
  let mut rate = 0
  let mut used = 0L
  for pos = 0; pos < data.length(); {
    let size = @libavcodec.mlp_access_unit_size(data[pos:])
    guard size >= 4 && size <= data.length() - pos else {
      raise DecodeError("invalid MLP access unit length")
    }
    let result = dec.decode_packet(data[pos:pos + size].to_owned())
    match result {
      Ok(Some(out)) => {
        used += out.samples.length().to_int64()
        if budget is Some(limit) {
          guard used <= limit else {
            raise DecodeError("decoded audio sample budget exceeded")
          }
        }
        let scale = if out.bits <= 16 { 32768.0 } else { 2147483648.0 }
        let frame = playback_integer_audio_frame(
          out.samples,
          out.channels,
          out.sample_rate,
          scale,
          0L,
        )
        rate = playback_append_audio(rows, rate, frame, 0)
      }
      Ok(None) => ()
      Err(error) => raise DecodeError(error)
    }
    continue pos + size
  }
  guard rows.get(0) is Some(first) && rate > 0 else {
    raise DecodeError("MLP stream has no output frames")
  }
  {
    samples: rows,
    sample_rate: rate,
    channels: rows.length(),
    format_name: codec,
    codec_id: codec,
    duration_seconds: Some(first.length().to_double() / rate.to_double()),
  }
}
