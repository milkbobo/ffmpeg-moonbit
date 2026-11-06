///|
/// Raw extern declarations over the ffref stub (native-only). Everything
/// here is package-private; the safe surface is in ffref.mbt. The stub
/// returns NULL on failure, which lands as `None` on the `Bytes?` returns.
#borrow(data)
extern "c" fn ffref_packets_ffi(data : Bytes) -> Bytes? = "ffref_packets"

///|
#borrow(data)
extern "c" fn ffref_decode_audio_ffi(data : Bytes) -> Bytes? = "ffref_decode_audio"

///|
#borrow(data)
extern "c" fn ffref_decode_video_ffi(data : Bytes) -> Bytes? = "ffref_decode_video"

///|
#borrow(pcm)
#borrow(codec)
#borrow(options)
extern "c" fn ffref_encode_audio_ffi(
  pcm : Bytes,
  codec : Bytes,
  options : Bytes,
  sample_rate : Int32,
  channels : Int32,
  bitrate : Int32,
) -> Bytes? = "ffref_encode_audio"

///|
extern "c" fn ffref_avformat_version() -> Int32 = "ffref_avformat_version"
