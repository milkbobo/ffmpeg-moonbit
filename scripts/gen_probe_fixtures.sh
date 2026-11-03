#!/bin/sh
# Generate probe fixtures with the reference FFmpeg 9.0.2 build.
set -e
OUT=/w
V="-f lavfi -i testsrc2=size=64x48:rate=10 -frames:v 3"
A="-f lavfi -i sine=frequency=440:sample_rate=8000:duration=1 -ac 1"

ffmpeg -loglevel error $V -c:v libx264 -x264-params keyint=1:bframes=0 -movflags +faststart -y $OUT/p.mp4
ffmpeg -loglevel error $V -c:v libx264 -x264-params keyint=1:bframes=0 -y $OUT/p.mkv
ffmpeg -loglevel error $V -c:v libvpx-vp9 -b:v 200k -y $OUT/p.webm
ffmpeg -loglevel error $V -c:v libx264 -y -f mpegts $OUT/p.ts
ffmpeg -loglevel error $A -c:a pcm_s16le -y $OUT/p.wav
ffmpeg -loglevel error $A -c:a flac -y $OUT/p.flac
ffmpeg -loglevel error $A -c:a libmp3lame -b:a 32k -y $OUT/p.mp3
ffmpeg -loglevel error $A -c:a aac -b:a 32k -f adts -y $OUT/p.aac
ffmpeg -loglevel error $A -c:a libopus -b:a 32k -y $OUT/p.ogg
ffmpeg -loglevel error $A -c:a ac3 -b:a 96k -y $OUT/p.ac3
ffmpeg -loglevel error $A -c:a pcm_s16be -y $OUT/p.aiff
ffmpeg -loglevel error $A -c:a pcm_s16be -f au -y $OUT/p.au
ffmpeg -loglevel error $A -c:a pcm_s16be -f caf -y $OUT/p.caf
ffmpeg -loglevel error $A -c:a wmav2 -b:a 32k -f asf -y $OUT/p.asf
ffmpeg -loglevel error $A -c:a pcm_s16le -f w64 -y $OUT/p.w64
ffmpeg -loglevel error -f lavfi -i testsrc2=size=32x32 -frames:v 1 -y $OUT/p.png
ffmpeg -loglevel error -f lavfi -i testsrc2=size=32x32 -frames:v 1 -c:v mjpeg -f mjpeg -y $OUT/p.mjpeg

for f in p.mp4 p.mkv p.webm p.ts p.wav p.flac p.mp3 p.aac p.ogg p.ac3 p.aiff p.au p.caf p.asf p.w64 p.png p.mjpeg; do
  printf "%s %s " "$f" "$(wc -c < $OUT/$f | tr -d ' ')"
  ffprobe -loglevel error -show_entries format=format_name -of default=nw=1:nk=1 $OUT/$f
done
