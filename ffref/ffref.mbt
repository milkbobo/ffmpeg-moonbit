// ORACLE (C FFI) - EXPLICITLY NOT DONE / INTENTIONALLY DISABLED.
// The module ships as pure MoonBit and does not bind native FFmpeg;
// this oracle differential harness is preserved below, line-commented
// for reference only. See ffref/moon.pkg for how to re-enable.
// ///|
// /// Safe surface over the FFmpeg reference oracle. The flat blobs the C stub
// /// returns are decoded here into plain MoonBit values; a NULL blob becomes
// /// `FFRefError`.
// 
// ///|
// /// Resolve UTF-8 URI bytes using the pinned FFmpeg URL implementation, with
// /// DOS path handling disabled. Embedded NULs and invalid URLs raise an error.
// pub fn ffref_resolve_uri(
//   base : Bytes,
//   reference : Bytes,
// ) -> Bytes raise FFRefError {
//   match ffref_resolve_uri_ffi(base, reference) {
//     Some(result) => result
//     None => raise OracleFailed("invalid URI or allocation failure")
//   }
// }
// 
// ///|
// /// One oracle packet record: `pts_us`/`dts_us` are AV_TIME_BASE
// /// microseconds (`None` where FFmpeg reports N/A).
// pub(all) struct FFRefPacket {
//   stream_index : Int32
//   keyframe : Bool
//   pts_us : Int64?
//   dts_us : Int64?
//   size : Int32
// }
// 
// ///|
// /// A whole-file oracle probe: per-stream timebases (num/den) and every
// /// demuxed packet in read order.
// pub struct FFRefProbe {
//   timebases : Array[(Int32, Int32)]
//   packets : Array[FFRefPacket]
// }
// 
// ///|
// /// The oracle's audio decode: interleaved s16le PCM plus its parameters.
// pub struct FFRefAudio {
//   sample_rate : Int32
//   channels : Int32
//   samples_per_channel : Int32
//   pcm_s16le : Bytes
// }
// 
// ///|
// /// The oracle call failed (open/decode error on the FFmpeg side).
// pub(all) suberror FFRefError {
//   OracleFailed(String)
// } derive(Debug)
// 
// ///|
// pub extend FFRefError with @moonbitlang/core/debug.Debug::{to_repr}
// 
// ///|
// fn rd_i32(b : Bytes, i : Int32) -> Int32 {
//   b[i].to_int() |
//   (b[i + 1].to_int() << 8) |
//   (b[i + 2].to_int() << 16) |
//   (b[i + 3].to_int() << 24)
// }
// 
// ///|
// fn rd_i64(b : Bytes, i : Int32) -> Int64 {
//   let lo = rd_i32(b, i).reinterpret_as_uint().to_int64()
//   let hi = rd_i32(b, i + 4).reinterpret_as_uint().to_int64()
//   lo | (hi << 32)
// }
// 
// ///|
// fn rd_opt_i64(v : Int64) -> Int64? {
//   if v == 0x8000000000000000L {
//     None
//   } else {
//     Some(v)
//   }
// }
// 
// ///|
// /// The bound libavformat's major version (the oracle must track the same
// /// FFmpeg line as the port: 9.0.2 ships libavformat 63.x). FFmpeg 9 packs
// /// AV_VERSION_INT as (major << 16) | (minor << 8) | micro.
// pub fn ffref_libavformat_major() -> Int32 {
//   ffref_avformat_version() >> 16
// }
// 
// ///|
// /// Demux `data` with the real FFmpeg and return its packet view.
// pub fn ffref_probe(data : Bytes) -> FFRefProbe raise FFRefError {
//   let blob = match ffref_packets_ffi(data) {
//     Some(v) => v
//     None => raise OracleFailed("avformat could not open or read the input")
//   }
//   let nstreams = rd_i32(blob, 0)
//   let npackets = rd_i32(blob, 4)
//   let timebases : Array[(Int32, Int32)] = []
//   for i = 0; i < nstreams; i = i + 1 {
//     timebases.push((rd_i32(blob, 8 + i * 8), rd_i32(blob, 8 + i * 8 + 4)))
//   }
//   let base = 8 + nstreams * 8
//   let packets : Array[FFRefPacket] = []
//   for i = 0; i < npackets; i = i + 1 {
//     let r = base + i * 32
//     packets.push({
//       stream_index: rd_i32(blob, r),
//       keyframe: rd_i32(blob, r + 4) != 0,
//       pts_us: rd_opt_i64(rd_i64(blob, r + 8)),
//       dts_us: rd_opt_i64(rd_i64(blob, r + 16)),
//       size: rd_i32(blob, r + 24),
//     })
//   }
//   { timebases, packets, }
// }
// 
// ///|
// /// The oracle's 8-bit video decode: compact frames plus the (constant)
// /// geometry. `chroma_mode` is 0 for planar 4:2:0, 1 for 4:2:2, 2 for 4:4:4
// /// (the plane layout `VideoFrame::yuv_bytes` emits), 3 for packed rgb24,
// /// 4 for packed rgba and 5 for gray8.
// pub struct FFRefVideo {
//   width : Int32
//   height : Int32
//   chroma_mode : Int32
//   frames : Array[Bytes]
// }
// 
// ///|
// /// Accessors.
// pub fn FFRefVideo::width(self : FFRefVideo) -> Int32 {
//   self.width
// }
// 
// ///|
// pub fn FFRefVideo::height(self : FFRefVideo) -> Int32 {
//   self.height
// }
// 
// ///|
// pub fn FFRefVideo::chroma_mode(self : FFRefVideo) -> Int32 {
//   self.chroma_mode
// }
// 
// ///|
// pub fn FFRefVideo::frames(self : FFRefVideo) -> Array[Bytes] {
//   self.frames
// }
// 
// ///|
// /// Decode `data`'s first video stream with the real FFmpeg decoder chain.
// /// Only fixed-geometry 8-bit planar YUV (4:2:0/4:2:2/4:4:4), packed
// /// rgb24/rgba and gray8 frames are supported; anything else raises.
// pub fn ffref_decode_video(data : Bytes) -> FFRefVideo raise FFRefError {
//   let blob = match ffref_decode_video_ffi(data) {
//     Some(v) => v
//     None =>
//       raise OracleFailed(
//         "FFmpeg could not decode the first video stream as fixed 8-bit frames",
//       )
//   }
//   let n = rd_i32(blob, 0)
//   let w = rd_i32(blob, 4)
//   let h = rd_i32(blob, 8)
//   let mode = rd_i32(blob, 12)
//   let frame_len = ffref_video_frame_len(w, h, mode)
//   let frames : Array[Bytes] = []
//   for i = 0; i < n; i = i + 1 {
//     let base = 16 + i * frame_len
//     frames.push(blob[base:base + frame_len].to_owned())
//   }
//   { width: w, height: h, chroma_mode: mode, frames, }
// }
// 
// ///|
// /// Per-frame byte length for a video blob `chroma_mode` (see `FFRefVideo`).
// fn ffref_video_frame_len(w : Int32, h : Int32, mode : Int32) -> Int32 {
//   if mode <= 2 {
//     let cw = if mode == 2 { w } else { (w + 1) / 2 }
//     let ch = if mode == 0 { (h + 1) / 2 } else { h }
//     w * h + 2 * cw * ch
//   } else if mode == 3 {
//     w * h * 3
//   } else if mode == 4 {
//     w * h * 4
//   } else {
//     w * h
//   }
// }
// 
// ///|
// /// Decode `data`'s first audio stream with the real FFmpeg decoder chain.
// pub fn ffref_decode_audio(data : Bytes) -> FFRefAudio raise FFRefError {
//   let blob = match ffref_decode_audio_ffi(data) {
//     Some(v) => v
//     None => raise OracleFailed("FFmpeg could not decode the first audio stream")
//   }
//   {
//     sample_rate: rd_i32(blob, 0),
//     channels: rd_i32(blob, 4),
//     samples_per_channel: rd_i32(blob, 8),
//     pcm_s16le: blob[12:blob.length()].to_owned(),
//   }
// }
// 
// ///|
// /// The oracle's audio encode: the real encoder's packets in emission order
// /// (flush included).
// pub struct FFRefEncode {
//   packets : Array[Bytes]
// }
// 
// ///|
// pub fn FFRefEncode::packets(self : FFRefEncode) -> Array[Bytes] {
//   self.packets
// }
// 
// ///|
// /// ASCII text as NUL-terminated C-string bytes (the runtime terminates
// /// `Bytes`).
// fn ascii_cstring(s : String) -> Bytes {
//   let out : Array[Byte] = []
//   for c in s {
//     out.push(c.to_int().to_byte())
//   }
//   Bytes::from_array(out)
// }
// 
// ///|
// /// Encode interleaved s16le `pcm` with the real FFmpeg encoder named
// /// `codec` (e.g. "aac", "libshine", "opus"). The input is converted to
// /// whatever sample format the encoder wants; fixed-size frames are fed
// /// through `avcodec_send_frame` and the emitted packets (including the
// /// flush tail) come back for byte-level differential against the MoonBit
// /// encoder ports. `options` is a `key=value:key=value` list for
// /// `avcodec_open2`; the reference always runs scalar and BITEXACT.
// pub fn ffref_encode_audio(
//   pcm : Bytes,
//   codec : String,
//   options~ : String = "",
//   sample_rate~ : Int32,
//   channels~ : Int32,
//   bitrate~ : Int32,
// ) -> FFRefEncode raise FFRefError {
//   let blob = match
//     ffref_encode_audio_ffi(
//       pcm,
//       ascii_cstring(codec),
//       ascii_cstring(options),
//       sample_rate,
//       channels,
//       bitrate,
//     ) {
//     Some(v) => v
//     None => raise OracleFailed("FFmpeg could not encode with codec \{codec}")
//   }
//   let n = rd_i32(blob, 0)
//   let packets : Array[Bytes] = []
//   let mut off = 4 + n * 4
//   for i = 0; i < n; i = i + 1 {
//     let sz = rd_i32(blob, 4 + i * 4)
//     packets.push(blob[off:off + sz].to_owned())
//     off = off + sz
//   }
//   { packets, }
// }
//
