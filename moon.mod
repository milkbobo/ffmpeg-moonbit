name = "milkbobo/ffmpeg-moonbit"

version = "0.1.0"

license = "LGPL-2.1-or-later"

preferred_target = "wasm"

description = "Pure MoonBit port of FFmpeg n9.0.2: codec bitstream line (H.264/H.265/VP9/AV1 video, AAC/MP3/Opus/FLAC decode; AAC/MP3/Opus encode), libavutil DSP, libavformat mux/demux (MP4/MKV/Ogg/WAV/FLAC/ADTS/MPEG-TS and more), plus a unified playback facade with ffprobe-style JSON CLI commands"

keywords = ["ffmpeg", "codec", "audio", "video", "demux", "mux", "h264", "aac", "opus", "flac"]

repository = "https://github.com/milkbobo/ffmpeg-moonbit"

import {
  "moonbitlang/x@0.5.7",
}
