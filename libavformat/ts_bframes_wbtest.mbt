///|
/// Real H.264 MPEG-TS with B-frames (x264 bf=3, 64x48, 6 frames). The TS
/// writer must emit PES headers carrying both PTS and DTS; remuxing keeps
/// the timestamps (relative) and decodes to the same frames.

///|
let ts_bframes_src_b64 : Bytes = b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgMAKMQAJ8aERAAfYYQAAAAEJ8AAAAAFnZAAKrNlEewEQAAADABAAAAMAoPEiWWAAAAABaOvjyyLAAAABBgX//5fcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3hHAQARMjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdEcBABJfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpRwEAE3JlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTYga2V5aW50X21pbj00IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD02IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjFHAQAULjAwAIAAAAFliIQD/9G3bEfXd6WA9bVc7aYKqtpzPIGOElIo9yDw5CevhSiehNtjRft18Ufpcjvs/RBmkWV+oYZFH+QePXFlW6t/MwqjLDuHPhwsb0K8ier9ErZK+EpKpSL3/8vhraVp+7+fh9PrvrlJtYxwFu+bDajQqoF6AOoXMMjKW5zb0VcaoJhxOshp52bdzOhOp+i2Ne/BwZGf7t/OBpbiYSt88xfb2pkijUE7KuWmWjKRZEcBABUgY5LA8gyRnaxwE8renuvFFpsufs3Z5SXIpEe62++IW++flWv+ghE4f4irfFveTDFDMVPCyzaD77KXdvDlgMbFvEE+0Bt+JZCYDkoxGQvuBpbGzf31Yh72dORixOsinRLX9fsK0ndgCRMjOySaGZFJ1amJICIbNjaZFWzLmjeDrnUY8OD+EwStxz4sJjWZEDn2tNbvCGGeUMJe7ISppmxUe0uXP0J7PMkWfOpQEY+ccyLFEt3f8aUDRwEAFvnRBTa3UMr2y+VulzLsni6voQX7D68LTdzLdwhmC8zJwm8dNCeUO4aHkcpg/HHdSi9mq7jI9FQj1YxtrO4AgVzTqqWi0godNjDatrPMZBRcqNG3GM9BcU3bdwSkonJt+W8lpso+UsoflW9RiLQOZoxQt89bEQofMFpmBkW92fFvmkD+r8id9eYUVwZdijwW9AemuFyj9bWGeqQRwYzbzM4NAZjP/u7G8OqAFHcdcWI0Tvrs40f7ntxHAQAXdR6Srbf0bSKhV8W0i9uiBvnD8aPcH8ItTqUR0XpNnsLzP2E4ICkpgshN8BHKWDr6zIQjCL0g8Pdierz/G11cdqp6L3sFrQUwGkJ9j4d19iw+yC45Q1XmHty9T6gz//WXZydGKxSec4q2D4g9aLOEiOAnMvzSUHOnJhXiqS2q4jyi4llyCiOg6HVpTkdgVRC1x6qVRE93QDgl2s/tu95qX1PVQtfxmCDh8UoDgRAQb7U00HuMuZoiREcBABhQGX7xQEZFDNuh0BFfhd6pZHIDOyRrCcAwek0hFm2wQRJaazu0jkfWcMO1xptyMz85L7SIse+gcRrQ/3+48aoFK+58VkE+Wlr7WjLZ97iDt7vBpgOjeIu1NlBMyBl9LIfQsp2NzZ++gD2MIZzPSugYDN3qde/CDTgoRcKvBf+Ti/QH2N+Layo54ffzHzhNHqG5VVQfSWOf//ypjJIk29I0Ah1PlhUmYCWwc7+KD40GHFqaTvjfJl3ORwEAOSsA////////////////////////////////////////////////////////TaeNejNM9QGRR6RLVODdy2p9tJySDV7l/jnSfh7sapsUpeCnKn8RtlL6YfE/DU+atU56/dQ6ou0cDYWn8U7NALWXU4Y3QV0ZPTp1y9jGiClfvZ26fJG+c4fGCYxeTy0lYj8xRdeLUSkXTCmLftRS+tkhWSBye2YMoOXeMDkgx4rHfzSdLDZxasDtLOFHQAARAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABEAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAOh8QAACeNH4A////////////////////////////////AAAB4AAAgMAKMQAPJCERAAllAQAAAAEJ8AAAAAFBmiRsTf/GJ4kwNmnN54AQ3rfw0CSjNKxnsXpW57Ht+ygwmRg7lHDJqRH2evGDOVe3U+3kpek+F4X4/H9qR3KqXaD7lDUrIhuHVo5OxY/Vf+vNmiaT8rP0ebtUVo6svEBuPn+cfW9J7nmkFgCsR4l5zbCrgOXjrQJfQIBHQAASAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABIAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAO3sQAADBXH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAA0K4REACfGhAAAAAQnwAAAAAUGeQnib//gBJ9juQ6wIHoe7PfT+aqghlO3hLfcvFeNHQBERAELwJQABwQAA/wH/AAH8gBRIEgEGRkZtcGVnCVNlcnZpY2UwMXd8Q8r//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dAABMAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAEwACsBIAAcEAAOEA8AAb4QDwABW9TVb///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA8fBAAAOSEfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAt+QQAAAAEJ8AAAAAEBnmF0RX/55d1oNp441cDOcH7E6XaLU+/gfPNE1tdxZfCVJ0dAABQAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAFAACsBIAAcEAAOEA8AAb4QDwABW9TVb///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA9gRAAAQesfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEADZeBEQANCuEAAAABCfAAAAABAZ5jakV/6hnR3U2wtk3vfrV/btkir2gZwUdAABUAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAFQACsBIAAcEAAOEA8AAb4QDwABW9TVb///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA+FhAAASrUfgD///////////////////8AAAHgAACAwAoxAA+wwREADZeBAAAAAQnwAAAAAUGaZUmoQWiZTAiv3SzmS00ualfGbK146w4ptgGfmd//hvbk9v5lbT093R6w4SoMZAdQpdiyv3TIoW7UD66F0hbv/wh+te865F482eF/FBZaW+dBuea7LZTdli563vh6bUqdDIb1u+wqBUtRKAI4sEfUsDfmhYGHXyU9YClZ5tiigPPAwQ=="

///|
fn ts_bframes_md5(yuv : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
fn ts_bframes_decode(annexb : Bytes) -> Array[String] raise {
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode: \{e}")
  }
  let md5s : Array[String] = []
  for frame in frames {
    md5s.push(ts_bframes_md5(frame.yuvp()))
  }
  md5s
}

///|
test "ts muxer: B-frame PTS/DTS survive remux" {
  let src = @libavutil.av_base64_decode(ts_bframes_src_b64, 100000).unwrap()
  let demux = av_mpegts_open(src).unwrap()
  assert_eq(demux.packets.length(), 6)
  let mut min_dts = 0L
  let mut reordered = false
  for packet in demux.packets {
    if packet.dts < min_dts {
      min_dts = packet.dts
    }
    if packet.pts != packet.dts {
      reordered = true
    }
  }
  assert_true(reordered, msg="fixture must contain B-frames")
  let offset = -min_dts
  let mux = ts_muxer_new(video=true, audio=false)
  let src_stream : Array[Byte] = []
  for packet in demux.packets {
    for b in packet.payload {
      src_stream.push(b)
    }
    mux.write_video(
      packet.pts + offset,
      packet.payload,
      dts=packet.dts + offset,
    )
  }
  let out = mux.finish()
  let remux = av_mpegts_open(out).unwrap()
  assert_eq(remux.packets.length(), demux.packets.length())
  let src_base = demux.packets[0].dts
  let out_base = remux.packets[0].dts - offset
  for i in 0..<demux.packets.length() {
    let a = demux.packets[i]
    let b = remux.packets[i]
    assert_eq(b.pts - b.dts, a.pts - a.dts, msg="cts \{i}")
    assert_eq(b.dts - offset - out_base, a.dts - src_base, msg="dts \{i}")
    assert_eq(b.payload, a.payload, msg="payload \{i}")
  }
  let out_stream : Array[Byte] = []
  for packet in remux.packets {
    for b in packet.payload {
      out_stream.push(b)
    }
  }
  let src_md5 = ts_bframes_decode(Bytes::from_array(src_stream))
  let out_md5 = ts_bframes_decode(Bytes::from_array(out_stream))
  assert_eq(out_md5.length(), src_md5.length())
  for i in 0..<src_md5.length() {
    assert_eq(out_md5[i], src_md5[i], msg="frame \{i}")
  }
}
