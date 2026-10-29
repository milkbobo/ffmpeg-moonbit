///|
/// Real FFmpeg 9.0.2 MP4 (AAC audio + chapter text track) carrying iTunes
/// `ilst` tags and a Nero `chpl` chapter box.

///|
fn mp4chap_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mp4chap_b64 : Bytes = mp4chap_concat([
  b"AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAEkG1kYXQABUZpcnN0AAAADGVuY2QAAAEAAAZTZWNvbmQAAAAMZW5jZAAAAQDcAExhdmM2My4xLjEwMgACYKxbqVByJqV49eP3rriW1UlqlpUkyTuDoQEGFXLxdxrpLWva",
  b"XmPBu2PO6vk8UtgzPkvnnTXSPN3Nu4tg5S4jr7VNtWzZVO1Vn3VWI4VjcVcbNoNmxtixNystyznXsTjsbirjZrjPVmOjX5q/NX5rHPrZ9bUs9Sx0a/NaZq/NX59bPrZ9bPqp9fmsM1hps6LOitRWopU2MzGZjMxorUVqK1FjTYzMZmMTGizo",
  b"rUVqLGixmYzMYkokp4p4okol8L5L5JRJTxTxTxRL5L5L5L7xTxTxTxRL5L8UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUXAATSa2tJNwGzFTCbMVKJ03U2p5+tXw2+NXdf+nH6/VwXep//S8/r8cBq5v/+31+/tIavjOhJdBBf4mjAw8eXAfZNO",
  b"7BYpfDaiYXXBmtILtidzjSIfCxdrjYIcbFqaqa1BCpdVNnM/8bQ127+s6JBga7kEhIMDA2TuEhISDAwM7uEhJwGHMu7hJxoGZBrzu+QSE5L8/MDZGaE2Eu/whVhpq4jpBkpRSqSNzKzZ2VRuaWttttk0WkUps5kqqotM6mBvkwN/WQkGJAwM",
  b"EhJK84MbNhISVBs3BgY2EhJW9jmixlCSt2Aggy8OFmOXiPtdf3h9NlWVflOiQk5NNMlWcmmCUt3gARL2LPS2MRdQIdM+a9fOf417NcIpcy4m5EeUiJOpdLoSL8jTukeYftuI8wxGTQ/COa7gc1fVZVwxuy7T978Dxmwwr1nXVurcayqOcsZ3",
  b"E4mwxqk4Zk2bNjRUQrFq1a4SHTj5scZmB8MMMJHBpsccZkB68MJHcGpxxmZAf394T/Hw2n39yP8fDaff3I/jmMPf3lGb4NLvaCcXARJWLZTtGwdc7yuf6f9X1nHFPPNy7CzzlxqrSry0yx2p9w0h3Bxp6x6x9w1LMgpdKq3YD75+Q9cINWQQ",
  b"X9pzRtxZufjcmAH//+35rx41k451Tqm0WDGJeP+r7XteLj1YkhiNo2jKIwgeTzva9rxceWwsm0bRtGIjHDOTxeLxdnf3JiQnJycjFBw7eTn49uXEAYaNGkYoOHbyc/HsyzxFDRo0UEHDt2eeamBXXZZQAGufASybsttEgqzWZDL62B8+vNuL",
  b"S5ev/7fn9er6CXP/6n6/fi/Kzpkg6WqMMHmaFx6QEDDnL23fuLXdEmG/qsYtXXhok8nXTXM+GOOFLzSM+GOGNNbOzs+GNbBISlmBgYJCQmaZwYGBgkJCZncGBgYJqWzO4MiBsOH1oj+dUPXrTRs92/VCjKlVq6z0bXu4mgF68psYloX8asMm",
  b"kfF/GsTBzFheVWF2NCS5TnrXGcqxJk0C5cOXB9inY5qAGAiKCnm8mOBkziggCY4Y4YyIKCij+X8v5Xvcfy/l/JVqVfy/l/L1TgB8P5fy1/PY32DZNGOfjTC+Iaj3roapQfZvOeZtc6UpenMLqjbY1i0FiUJhDn4BGIG0cAAABaptb292AAAA",
  b"bG12aGQAAAAAAAAAAAAAAAAAAKxEAAAROgABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAACUXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAA",
  b"AAEAAAAAAAAROgAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAEToAAAQAAAEAAAAAABR0cmVmAAAADGNoYXAAAAACAAABtW1kaWEA",
  b"AAAgbWRoZAAAAAAAAAAAAAAAAAAArEQAABU6VcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAWBtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAA",
  b"AQAAASRzdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAArEQAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAABHEwAARxMBYCAgAUSCFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIAAAAF",
  b"AAAEAAAAAAEAAAE6AAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAGAAAAAQAAACxzdHN6AAAAAAAAAAAAAAAGAAABAAAAAQIAAACZAAAAsQAAARAAAAAFAAAAFHN0Y28AAAAAAAAAAQAAAFMAAAAac2dwZAEAAAByb2xsAAAAAgAAAAH//wAAABxz",
  b"YmdwAAAAAHJvbGwAAAABAAAABgAAAAEAAAIPdHJhawAAAFx0a2hkAAAAAgAAAAAAAAAAAAAAAgAAAAAAABE6AAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAc",
  b"ZWxzdAAAAAAAAAABAAAROgAAAAAAAQAAAAABh21kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAArEQAABE6AAAAAAAAADBoZGxyAAAAAAAAAAB0ZXh0AAAAAAAAAAAAAAAAU3VidGl0bGVIYW5kbGVyAAAAAS9taW5mAAAATGdtaGQAAAAYZ21p",
  b"bgAAAAAAQIAAgACAAAAAAAAAAAAsdGV4dAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAALdzdGJsAAAAS3N0c2QAAAAAAAAAAQAAADt0ZXh0AAAAAAAA",
  b"AAEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAANZnRhYgABAAEAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAAidAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAACAAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAEwAAABQAAAAUc3RjbwAA",
  b"AAAAAAABAAAALAAAANZ1ZHRhAAAAoG1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAAc2lsc3QAAAAlqW5hbQAAAB1kYXRhAAAAAQAAAABDaGFwdGVyZWQgTVA0AAAAIqlBUlQAAAAaZGF0YQAAAAEAAAAATXA0",
  b"IEFydGlzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMgAAAC5jaHBsAQAAAAAAAAACAAAAAAAAAAAFRmlyc3QAAAAAAAehIAZTZWNvbmQ=",
])

///|
fn mp4chap_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
test "mp4 chapters: reads chpl atoms" {
  let data = @libavutil.av_base64_decode(mp4chap_b64, 100000).unwrap()
  let movie = @libavformat.av_mov_open(data).unwrap()
  // Audio track plus the QuickTime chapter text track.
  assert_eq(movie.tracks.length(), 2)
  assert_eq(movie.chapters.length(), 2)
  assert_eq(movie.chapters[0].title, "First")
  assert_eq(movie.chapters[0].start_100ns, 0L)
  assert_eq(movie.chapters[1].title, "Second")
  assert_eq(movie.chapters[1].start_100ns, 500000L)
  assert_eq(mp4chap_find(movie.metadata, "title"), "Chaptered MP4")
  assert_eq(mp4chap_find(movie.metadata, "artist"), "Mp4 Artist")
}

///|
test "mp4 chapters: writer replaces chpl and keeps tags" {
  let data = @libavutil.av_base64_decode(mp4chap_b64, 100000).unwrap()
  let plain = @libavformat.av_mov_open(data).unwrap()
  let out = @libavformat.mp4_add_chapters(data, [
    @libavformat.mp4_chapter_new(0L, "Intro"),
    @libavformat.mp4_chapter_new(1000000L, "Middle"),
    @libavformat.mp4_chapter_new(2000000L, "Outro"),
  ]).unwrap()
  let movie = @libavformat.av_mov_open(out).unwrap()
  assert_eq(movie.tracks.length(), plain.tracks.length())
  assert_eq(movie.tracks[0].samples.length(), plain.tracks[0].samples.length())
  assert_eq(movie.chapters.length(), 3)
  assert_eq(movie.chapters[0].title, "Intro")
  assert_eq(movie.chapters[1].title, "Middle")
  assert_eq(movie.chapters[1].start_100ns, 1000000L)
  assert_eq(movie.chapters[2].title, "Outro")
  // Tags are untouched by the chapter rewrite.
  assert_eq(mp4chap_find(movie.metadata, "title"), "Chaptered MP4")
}

///|
test "mp4 chapters: metadata rewrite keeps chapters" {
  let data = @libavutil.av_base64_decode(mp4chap_b64, 100000).unwrap()
  let out = @libavformat.mp4_add_metadata(data, [("title", "Retagged")]).unwrap()
  let movie = @libavformat.av_mov_open(out).unwrap()
  assert_eq(mp4chap_find(movie.metadata, "title"), "Retagged")
  assert_eq(mp4chap_find(movie.metadata, "artist"), "")
  assert_eq(movie.chapters.length(), 2)
  assert_eq(movie.chapters[0].title, "First")
  assert_eq(movie.chapters[1].title, "Second")
}
