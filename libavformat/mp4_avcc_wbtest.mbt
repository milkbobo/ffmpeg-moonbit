///|
/// End-to-end MP4 → `avcC` → length-prefixed samples → pixels test.
///
/// `avcc_baseline.mp4` (5042 bytes) was written by linuxserver/ffmpeg:9.0.2:
///   -f lavfi -i "testsrc2=size=64x48:rate=2:duration=1.5" -c:v libx264
///   -profile:v baseline -x264-params "keyint=1:bframes=0:cabac=0:8x8dct=0:
///   slices=1:scenecut=0:ref=1" -pix_fmt yuv420p -movflags +faststart
/// so every picture is an IDR I frame, the container stores the parameter sets
/// in `avcC` (not in-band) and each sample is a 4-byte length-prefixed NAL.
/// Expected YUV is FFmpeg's default decode of the same file (`-f framemd5`).
///
/// This exercises the whole chain the Annex B tests cannot: `avcC` parsing,
/// `nal_length_size`, sample slicing by `stco`/`stsz` and the decoder entry
/// that consumes access units instead of an Annex B byte stream.

///|
/// `avcc_baseline.mp4` (base64).
let h264_avcc_mp4_b64 : Bytes = b"AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMabW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAABdwAAQAAAQAA" +
  b"AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA" +
  b"AkV0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAABdwAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA" +
  b"AAAAAAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAXcAAAAAAABAAAAAAG9bWRpYQAAACBtZGhk" +
  b"AAAAAAAAAAAAAAAAAABAAAAAYABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABaG1p" +
  b"bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAShzdGJsAAAAuHN0c2QA" +
  b"AAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4" +
  b"MjY0AAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAFmdCwArcR7ARAAADAAEAAAMABA8SJ4ABAAVozg8sgAAAABBwYXNwAAAA" +
  b"AQAAAAEAAAAUYnRydAAAAAAAAFeAAAAAAAAAABhzdHRzAAAAAAAAAAEAAAADAAAgAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAwAA" +
  b"AAEAAAAgc3RzegAAAAAAAAAAAAAAAwAABpAAAATkAAAE9AAAABRzdGNvAAAAAAAAAAEAAANKAAAAYXVkdGEAAABZbWV0YQAAAAAA" +
  b"AAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEw" +
  b"MgAAAAhmcmVlAAAQcG1kYXQAAAJYBgX//1TcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4yNjQvTVBFRy00IEFW" +
  b"QyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6" +
  b"IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9" +
  b"MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFk" +
  b"em9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBz" +
  b"bGljZWRfdGhyZWFkcz0wIHNsaWNlcz0xIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0" +
  b"cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MSBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9y" +
  b"ZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9y" +
  b"YXRpbz0xLjQwIGFxPTE6MS4wMACAAAAEMGWIhDfEIioAwIQ/AQpkQAAgE1qDDAAeLxnRjR0C+7/8TA4gQMy91GJHJ3vXJyvGXMSP" +
  b"hfZ/+J9kssyHyORn/2CBp8VLBtKn++uGoYTk+bx6vXU4YvI8rT1ekAGkZkjgf39/7QOOz6uDdv98CAAMADBTISADEAwAE+ZhVmOg" +
  b"Qi+vTLaA6iUZI24gOb//acAriG1iNIAN1xRVY62aC5ufAnaMnesBCMf/fmEHck5Yfwn90RUBH2u1PgISNjiVq/kyJi73/Yb4eABS" +
  b"8x5Gi46if/rjUMTk+Xx6vA72TIaOmr1B+Zkgtvn+2cmLorsg6gT2yRRnbzUlOgbEKbfenEx5FZEHVAK0PG4j+dYEEwgYFMqY+ZAM" +
  b"8HzMGcOTE8olpqQK//95Z029DlT/9zLyMcUx1C/fPlkTfXYM0NFtUPMZ/6wnkimCsj/vsTcRUCbKw8GkAAQI2XpkoMzObl73/9gL" +
  b"E8M6MbFQKkj/9A6BARl5qhszm5b1zB1DSDCIWk99d3sll2QXM9XP/qA+QhExQFT/98oDxSFTlARCf75cNIMIhaT+PV4GrWJWKxWP" +
  b"V6ga7ESB7ff904RkVnKqDqCCABtABAYCLrETASKgBBtTCGEFdaRgZv/YAAlQYrLG1PAk7O2YJkT/75nNpAxtTAdqHPUg6IawApyi" +
  b"3A2pyLRp7D7/9/EbCKu8EL/AQkxHNWqBMmN8xMqC+rv8HAaWSYq/8T/7leN8jR8dTf/gH6zxZo7z7Ek5IPIpEv+cEZURzMg6pAUu" +
  b"fQS3P767jowJnULx6vXVxgbMoTz1ekAazJo4Lr+/9oHHZdXBM3++AUABAcIAAoA4g3S8SRegTi8yRJ6EG1PA9nV+g9TKv3zABdDD" +
  b"VI2p8RoXJMKhpCIIZwGucBxtTsT0hfmLN//uMAAkUUm4G1OAB8IfYLD+eAHiACAAkQAAoADyECD3GQACUuB0CD3CoABKXBEFAkAA" +
  b"TEuDoKBQAAmJc+I//DR/7+e8DgAXECgAGhWFXAyirmQIQtwMOIQtzF48AAmGLAAED1MCgwMAAICwgABMAFXvhYiQseWQBsQcgDYh" +
  b"h/+gV/IhkQcQCFiAACA4AAIFMkq55RVzIAIcRc8OAQ4i5wwwD4bDQrATInYlav4HIDAzIIQAjAHCAAIg44oAye2UbhqZhmneEiK4" +
  b"WhMAASWhqlVhCdkmQY2lxLm6RAAhz7hYABUAAQAmOAYB4+GvgDehOK6tX3CAAIhBR0IAIArwQE5ST0UigIAIU6WQRkuYDMpEZmEx" +
  b"xGlTLIAAQYfc/DDH9jeDBJl8DhBzmU8JAAEBVgABAYCADwfg4AhD5YDUBnGLjvMtBMEuWATZMeMjvu1lgEA7HAMA/3+AmInFdWr7" +
  b"+93whAAzABggABAFCAObCd1eELAEJDlkTFcwFyIxryERxe9BABCnSyAACgBQRc4AAATgZYiCH8QiKgDAhD8ARTYMxgAD1qDDAAdB" +
  b"eikoYRTeF9c//QOIAQAzLzJIMxChNbP/iOIXpx+U6l8esR/+87BMXIwLnNcr/9wBk7UdE0Iu5H761DTCiuI9K8PV63C+ODqcsd09" +
  b"XpAACPEYxFNBfX9/7rAaHEX1tBEZW38A5CAAEBEIAAk4AIABwAQUScvPazditE2QAfYwMyFUqEA/XE/32IAhayTMMjtVgAFW22Ec" +
  b"pg2mGGcbGXBLI0mgrWRDCNkiZgAENEiv760Bkzj0fFx3dEVAR/dqfAEUyBmDlVq81IMjOJa53a4YUB4ADxPDOhBKThaTP/1qHscG" +
  b"U9Y/R6vApmmEpDkFQer0gADzGM2OAKt/f+uEMTUJWhB1APqzxI0d8+xwWWaBVMJIe/04IYuclSEHVYNPjpYE0qf74LBHCABYDh1x" +
  b"oOxyA5cX02ADpVAUXIHsCTsrZA0RP/vsGozPID1rfvtOZhFFryC/F7f0VNxCUvrsBuhyFvKA813/rAl7M2UJcQv99iYCKgTZWHg0" +
  b"IAAgWsvgyJgpSmkeTsrn//8IL8ctDCqegb1z/9A4IMHMvGSQMxjhNfPpxQdkg0wozyfS8j1e52CY+YgLyHud/+oAPjOYing/v/75" +
  b"QAeHc1FvB3P/3yyQaYUZ5Ppfx6vApjTmcR6iWHq9gBlRoMiIG1bv984EUj2NJSg6ggCAAIDSQABASDABDpbBGBEegDBtTBLiDXl2" +
  b"5gZAzAABgdAh61RtT0CIoi2RihlpT6//MJBqiBxtTAdSgcXkgOyjWAAEihTdobU8DXFR7XF+Y//YjYRUHghD/AEUyDMHKrVAVC5x" +
  b"cU7E9BayOBL5qQyM4lrnfzuIXpxeUyl8asz/8AP5THTMbHLj87CR8jD5yWM//OAik8xpDkHVrDbpaKiaO0R/+7UPY4Ipqxuj1etw" +
  b"vjgqmLGbPV6gHzGM2OAdc/3ygHjmO3OAZS/74EoAEADhAACAAABQ4ftPAiTOrAZgmJgTLwMNqeAbIcp1IB8myv3zAABI7BhFJjan" +
  b"wg0M4kca48Z6TTCICp5YFjangT9kN44ZtZ/+MAAFxEni7yG1OABjhD8NF8/YAAPGgACAZEAAEAYAA8gE4twWWA4Jxbh5YIAAJAEB" +
  b"FwQAQBGA4ABIAgIuDgCAIxHiP/wVn/vCQAQpgRAAEA8Q0iYrgYeYrmQAjF3Aw4CMXc/w/+CueAAIFP8IgYAQAAQVhAADoAAgCry0" +
  b"JiDoTHlgQOxBwIHYh//0GvkQMRB+/xAAIFg4AAgbAACCnImVzw8yuZAABABQq54cAAgAoVc4YYB8NhoVgCFpgjmNWr+ByAGAMyCA" +
  b"QEcDwgADIDgoSAEXq6ZihEh1UV1dogiNcLEBMABCZGQN26kDCbyRkFO8bCKzdIgABAoTcLAAPgACA8xwDAP+Cv4AhaIEcOVWoIAA" +
  b"yBAwfCAAJAAc8BAFFwUmXhxFAgACBQiWQE41zAhsiIJ3KIh5RZOcsgAAqAQF3PwwD/Ya4HhkZfA4QUOZBCAAIFJAABA4CAAJKA6g" +
  b"4ACBAmWBKAA5QQXK7zLEAmCiUsArGJT4blt3aywAIAHY4BgH+w18AQuII4cqtXvkIBAO4BQQAAgKgwAILgwuHJeMXB/iBEeWRGS5" +
  b"gLiYpyqM7lloW4gACBQiWQAAeABwGXOAAAAE8GWIhH8QiKgDAhD8ARTYMxgAD1qDDAAdBeikoYRTeF9c//QOIAQAzLzJIMxChNbP" +
  b"/iOIXpx+U6l8esR/+87BMXIwfOa5n/7gDbpR0TQi7k/vrUNMKK4j0nw9XrcL44Opyx2z1ekAAI8RjEU0F9f3/uADwrJai2h0sd9+" +
  b"A4ASAACAuEAAUOACAAMACCiTl57WbsVomyAD7GDEjquYHmJ7+2AFKeahKIrvP/4AFW22Ecpg2mGGcbGXBLI0mgrWRCybUtgAQaTP" +
  b"/9rSA7mR6LhdSx//RFQEfYXYE+AIpkDMHKrV5qQZGcS1zu1wwoDwAHieGdCCUnC0mf/rUPY4Mp6x+j1eBTNMJSHIKg9XrAN81GRA" +
  b"mK9/904QxLQkvUHUA+rPEjR3z7HBZZoFUwkh7/Tghi5yVIQdVg0+OlgTSp/vgNBDhAAsBw640HY5AcuL6bAB0qgKLkD2BIpnRGGm" +
  b"t392DUZnkB61v32nMwii15Bfi9v6Km4hKX12g3xWP64BZ2EP/7Al7M2UJcQv99iYCKgTZWHg0IAAgWsvgyJgpSmkeTsrn//8IL8c" +
  b"tDCqegb1z/9A4IMHMvGSQMxjhNfPpxQdkg0wozyfS8j1e52CY+YgLyHud/+oAPjOYing/v/75QAeHc1FvB3P/3yyQaYUZ5Ppfx6v" +
  b"ApjTmcR6iWHq9gBlRoMiIG1bv984EUj2NJSg6ggCAAIDSQABASDABCpbBGBEegDBtTBLiDXl25gZAzAABgdAh61RtT0CIoi2Rihl" +
  b"pT6//MJBqiBxtTAdSgcXkgOyjWAAEihTdobU8DXFR7XF+Y//YjYRW8EIG/AEUyDMHKrVAVC5xcU7E9BayOBL5qQyM4lrnfzuDZqt" +
  b"n6BMJJK/4AfymOmY2OXH52Ej5GHzksZ/+cBFJ5jSHIOrWG3S0VE0doj/92oexwRTVjdHq9ICdhRutc5tc6wN8hmmD6ff984E7iJU" +
  b"1BtTCAAEAAsIAA4ACgwK2ngRJnVgMwVNWMREfIj/1vANkOU6kA+TZX77AiFIrZiAaLn/34QaGcSONceM9JrE+EDrnpaBMPrAn7Ib" +
  b"xwzaz/80Gch2fucB5qIf+gAeAQ/DRfP33A8MjIIATDgFBAJABADSATi3KmaEhXIPu0HBOLcfLBAABIAgIuTSiMasG+0HAAJAEBFw" +
  b"sAQBGMMP/w2Xnr68IQCCsAwAAgFkBbcyINeYogVrgyLK53WiGOxHozXBkAiE3MXjwADIEEgACAGmBEGAYAAQPBAADIABV5aExB0J" +
  b"jywgViDhArEMIf+gV/IgzIOIAEFg4AAgVAACCLJJXAyiVzIAAgUdcDDgAQKOucMMA+Gw0IwBC0wRzGrV/A5ADAGZBAICEASEAAZA" +
  b"cECgAi9XTMUIkOqiurtEEI1wsQEwAEJkZA3bqQMJzJGQU7xsIrN0iAAEChNwsAA+AAIDzHAMA/4K/gCFogRw5VaggADIMGDoQABI" +
  b"ADngIAouCky8OIoEAAQKESyAnGuYENkRBO5REPKLJzlkAAFQCAu5+GAf7DXA8MjL4HCChzIIQABApIAAIHAQABJQCqDgAIECZYEo" +
  b"ADlBBcrvMtATBRKWAVjEp8Ny17tZYABAACscAwD/Ya+AIXEEcOVWr3yEAgHcAoIAAQFQYAEFwKLhyS8YuAgRHlkEZLmAuJinKozu" +
  b"WWhbiAAIFCJZAAB4AHAZc4A="

///|
/// Hex digest of one decoded frame's YUV420P planes.
fn h264_frame_md5(frame : @libavcodec.H264Frame) -> String {
  let yuv = frame.yuv420p()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < 16; i = i + 1 {
    let v = digest[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
test "mp4: avcC + length-prefixed samples decode to FFmpeg YUV" {
  let mp4 = @libavutil.av_base64_decode(h264_avcc_mp4_b64, 8192).unwrap()
  let movie = av_mov_open(mp4).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let t = movie.tracks[0]
  assert_eq(t.codec, "avc1")
  let extradata = match t.extradata {
    Some(e) => e
    None => fail("track has no extradata")
  }
  // `avcC` starts with configurationVersion 1.
  assert_eq(extradata[0], b'\x01')
  let samples : Array[Bytes] = []
  for i = 0; i < t.samples.length(); i = i + 1 {
    let s = t.samples[i]
    let off = s.offset.to_int()
    let end = off + s.size.reinterpret_as_int()
    samples.push(mp4.clamped_view(start=off, end~).to_owned())
  }
  assert_eq(samples.length(), 3)
  let frames = @libavcodec.h264_decode_avc_frames(extradata, samples, false).unwrap()
  assert_eq(frames.length(), 3)
  assert_eq(h264_frame_md5(frames[0]), "095a7084754121e94abd275275268b05")
  assert_eq(h264_frame_md5(frames[1]), "664f52209b9aa43fe82959438704fe50")
  assert_eq(h264_frame_md5(frames[2]), "365a2646c42630ed0a54447982936e76")
}
