///|
/// Raw extern declarations over the ffref stub (native-only). Everything
/// here is package-private; the safe surface is in ffref.mbt. The stub
/// returns NULL on failure, which lands as `None` on the `Bytes?` returns.
#borrow(data)
extern "c" fn ffref_packets_ffi(data : Bytes) -> Bytes? = "ffref_packets"

///|
#borrow(path)
extern "c" fn ffref_probe_path_ffi(path : Bytes) -> Bytes? = "ffref_probe_path"

///|
#borrow(path, data)
extern "c" fn ffref_write_file_ffi(path : Bytes, data : Bytes) -> Int32 = "ffref_write_file"

///|
#borrow(data)
extern "c" fn ffref_decode_audio_ffi(data : Bytes) -> Bytes? = "ffref_decode_audio"

///|
#borrow(data)
extern "c" fn ffref_decode_video_ffi(data : Bytes) -> Bytes? = "ffref_decode_video"

///|
#borrow(pcm, codec, options)
extern "c" fn ffref_encode_audio_ffi(
  pcm : Bytes,
  codec : Bytes,
  options : Bytes,
  sample_rate : Int32,
  channels : Int32,
  bitrate : Int32,
) -> Bytes? = "ffref_encode_audio"

///|
/// Per-stream codec parameters as libavformat reports them after
/// avformat_find_stream_info(). NULL lands as `None` on open/probe failure.
/// The stub only reads `data` during this call (open_input's MemIO is freed
/// before returning), so the borrow is call-scoped.
#borrow(data)
extern "c" fn ffref_stream_info_ffi(data : Bytes) -> Bytes? = "ffref_stream_info"

///|
extern "c" fn ffref_avformat_version() -> Int32 = "ffref_avformat_version"

///|
#borrow(base, reference)
extern "c" fn ffref_resolve_uri_ffi(base : Bytes, reference : Bytes) -> Bytes? = "ffref_resolve_uri"
