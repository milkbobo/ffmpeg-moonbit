///|
/// Ogg/Opus demuxer regression: a real libopus stream generated with docker
/// `linuxserver/ffmpeg:9.0.2` (`sine`, 48 kHz mono, 0.2 s, 64 kb/s).
/// Expected sizes/PTS/durations are ffprobe's packet list and the payload
/// MD5s were extracted from the Ogg pages.

///|
let ogg_opus_b64 : Bytes = b"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"

///|
let ogg_opus_md5 : Array[String] = [
  "e2d556a8332179c689943e298508a47a", "2cf749fc5ec2569348d8d188e6b3961a", "2ebf153d75c7588a281b40ca65155f1e",
  "85acf7c47744bf36bb4ebe4d60ef7441", "2be7efdf3116fee21b708987a08873b8", "73bbe88f4fed1eb1830602dd8cd4dac9",
  "8f073ba5474f5886ce9f55e66af5c8c3", "31b6658333742136cd057b7eda3f50d4", "1bc4363672de090adb8fccce8b3a5ca6",
  "3b70f2be904d96513fdac0b87b90fd31", "2906ade2411112de57c07204a5ef9603",
]

///|
let ogg_opus_size : Array[Int32] = [
  307, 168, 175, 175, 176, 177, 174, 175, 175, 176, 318,
]

///|
let ogg_opus_pts : Array[Int64] = [
  -312L, 648L, 1608L, 2568L, 3528L, 4488L, 5448L, 6408L, 7368L, 8328L, 9288L,
]

///|
let ogg_opus_duration : Array[Int32] = [
  960, 960, 960, 960, 960, 960, 960, 960, 960, 960, 312,
]

///|
test "ogg: real Opus stream headers and packets match ffprobe" {
  let bytes = @libavutil.av_base64_decode(ogg_opus_b64, 100000).unwrap()
  let demux = match av_ogg_opus_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_eq(demux.serial.reinterpret_as_uint(), 2662840857U)
  assert_eq(demux.channels, 1)
  assert_eq(demux.pre_skip, 312)
  assert_eq(demux.input_sample_rate, 48000)
  assert_eq(demux.extradata.length(), 19)
  assert_eq(demux.packets.length(), 11)
  for i in 0..<demux.packets.length() {
    let packet = demux.packets[i]
    assert_eq(packet.data.length(), ogg_opus_size[i])
    assert_eq(packet.pts, ogg_opus_pts[i])
    assert_eq(packet.duration, ogg_opus_duration[i])
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, packet.data, packet.data.length())
    inspect(hex_digest(digest), content=ogg_opus_md5[i])
  }
}

///|
test "ogg: corrupted page CRC is rejected" {
  let bytes = @libavutil.av_base64_decode(ogg_opus_b64, 100000).unwrap()
  let bad : Array[Byte] = []
  for i, b in bytes {
    bad.push(if i == 60 { (b.to_int() ^ 1).to_byte() } else { b })
  }
  match av_ogg_opus_open(Bytes::from_array(bad)) {
    Ok(_) => fail("corrupted Ogg page must fail")
    Err(_) => ()
  }
}

///|
fn hex_digest(digest : FixedArray[Byte]) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let sb = StringBuilder()
  for i in 0..<16 {
    let v = digest[i].to_int()
    sb.write_char(digits[v >> 4].to_int().unsafe_to_char())
    sb.write_char(digits[v & 15].to_int().unsafe_to_char())
  }
  sb.to_string()
}
