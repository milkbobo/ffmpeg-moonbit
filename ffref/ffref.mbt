///|
/// Safe surface over the FFmpeg reference oracle. The flat blobs the C stub
/// returns are decoded here into plain MoonBit values; a NULL blob becomes
/// `FFRefError`.

///|
/// One oracle packet record: `pts_us`/`dts_us` are AV_TIME_BASE
/// microseconds (`None` where FFmpeg reports N/A).
pub(all) struct FFRefPacket {
  stream_index : Int
  keyframe : Bool
  pts_us : Int64?
  dts_us : Int64?
  size : Int
}

///|
/// A whole-file oracle probe: per-stream timebases (num/den) and every
/// demuxed packet in read order.
pub struct FFRefProbe {
  timebases : Array[(Int, Int)]
  packets : Array[FFRefPacket]
}

///|
/// The oracle's audio decode: interleaved s16le PCM plus its parameters.
pub struct FFRefAudio {
  sample_rate : Int
  channels : Int
  samples_per_channel : Int
  pcm_s16le : Bytes
}

///|
/// The oracle call failed (open/decode error on the FFmpeg side).
pub(all) suberror FFRefError {
  OracleFailed(String)
} derive(Debug)

///|
pub extend FFRefError with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn rd_i32(b : Bytes, i : Int) -> Int {
  b[i].to_int() |
  (b[i + 1].to_int() << 8) |
  (b[i + 2].to_int() << 16) |
  (b[i + 3].to_int() << 24)
}

///|
fn rd_i64(b : Bytes, i : Int) -> Int64 {
  let lo = rd_i32(b, i).reinterpret_as_uint().to_int64()
  let hi = rd_i32(b, i + 4).reinterpret_as_uint().to_int64()
  lo | (hi << 32)
}

///|
fn rd_opt_i64(v : Int64) -> Int64? {
  if v == 0x8000000000000000L {
    None
  } else {
    Some(v)
  }
}

///|
/// The bound libavformat's major version (the oracle must track the same
/// FFmpeg line as the port: 9.0.2 ships libavformat 63.x). FFmpeg 9 packs
/// AV_VERSION_INT as (major << 16) | (minor << 8) | micro.
pub fn ffref_libavformat_major() -> Int {
  ffref_avformat_version() >> 16
}

///|
/// Demux `data` with the real FFmpeg and return its packet view.
pub fn ffref_probe(data : Bytes) -> FFRefProbe raise FFRefError {
  let blob = match ffref_packets_ffi(data) {
    Some(v) => v
    None => raise OracleFailed("avformat could not open or read the input")
  }
  let nstreams = rd_i32(blob, 0)
  let npackets = rd_i32(blob, 4)
  let timebases : Array[(Int, Int)] = []
  for i = 0; i < nstreams; i = i + 1 {
    timebases.push((rd_i32(blob, 8 + i * 8), rd_i32(blob, 8 + i * 8 + 4)))
  }
  let base = 8 + nstreams * 8
  let packets : Array[FFRefPacket] = []
  for i = 0; i < npackets; i = i + 1 {
    let r = base + i * 32
    packets.push({
      stream_index: rd_i32(blob, r),
      keyframe: rd_i32(blob, r + 4) != 0,
      pts_us: rd_opt_i64(rd_i64(blob, r + 8)),
      dts_us: rd_opt_i64(rd_i64(blob, r + 16)),
      size: rd_i32(blob, r + 24),
    })
  }
  { timebases, packets }
}

///|
/// Decode `data`'s first audio stream with the real FFmpeg decoder chain.
pub fn ffref_decode_audio(data : Bytes) -> FFRefAudio raise FFRefError {
  let blob = match ffref_decode_audio_ffi(data) {
    Some(v) => v
    None => raise OracleFailed("FFmpeg could not decode the first audio stream")
  }
  {
    sample_rate: rd_i32(blob, 0),
    channels: rd_i32(blob, 4),
    samples_per_channel: rd_i32(blob, 8),
    pcm_s16le: blob[12:blob.length()].to_owned(),
  }
}
