///|
/// HLS AES-128 real-data test: the playlist, key and encrypted segment are
/// produced by ffmpeg 9.0.2 (`-f hls -hls_key_info_file`). The playlist is
/// parsed, the key/segment fetched through `MediaFetch`, decrypted by
/// `HlsSegmentReader`, demuxed as MPEG-TS and decoded; frame MD5s match
/// FFmpeg's decode of the same encrypted HLS set.

///|
let hls_aes_key_b64 : Bytes = b"AAECAwQFBgcICQoLDA0ODw=="

///|
let hls_aes_segment_b64 : Bytes = b"5NarqBzHjC65cLowdio60EAGnf6V9XieaRyTyXpT1g37etJwDk9E/uXm67e7xZdwOaNn2Rq0iTDcKIpjB1JiWN+yCv" +
  b"N4AuYst4WnYGi4sYu55vS8cB+51UQLEV4+sfBMAzgqSvS/N0DUomM6tBBh2peKvQUM3zMiB1C2NSVAvSgVHAj+I1cW" +
  b"d9YMP5qDIfTgptldK2BdERananKkyibSIAg4tmqjKjkorlEwNv+g+tGNc8ls3MaMGZ0G6hjlIRw8EmMzKXgjOSdNXQ" +
  b"gqLeCy5WfvD63eV8MqdqsWpvf365/gA5t0PVrDVCunTPvJStJNrry2acbvNyS48B3tyC5k/4glEhlh/+xdEy6hpJ9y" +
  b"03pZd/8ks4bYfV+B/GcHeztwXhg0Gwq7fTzx1DBnu8Fn/3xdcxaoN1k/ihZujZ2TNazSMjDjS2oiCYicxQbamO31Sw" +
  b"z4Vl1HC2HB75Y/f/wJ8ZdhTh+UhVItyZSMOMvIaxoaf+bpMrhL1ZrJgpBoVZrRg0ZBax9O2W/GbeD7zqNUemyhRdYd" +
  b"8aVAULw+DSK/M8wFbsJU6jNw7RZCPDH/aAtY55pcWEbYWynfvS5ltc6dneDoAU9ZCT+UIheq8sGkUjlGPFoWOpBNeK" +
  b"dH6mXuDUPoQG6jiKPgxli6HbmCKuhtr3iYlm5dugjd1f5bRqv6TCiLJgwpIjaF8AkjLeb4yFc+0DLwc3IMuvzbs8BE" +
  b"j8ogidWWZ65Bh/JJ3MLPOPlUl+bCxHQb3FGpdkvjP0R9Mb6LUmsJW9y2DTL8O0ugrk/sTGDNlYuRFCCh6Ff8BGcCKM" +
  b"szJwR3z2MNOECrUKUop2djgR6O/mX5QAzywOKxvXfj1COdSkNeQU5AvW30R9e5gK724jgQ2bfOsbg2QjGPAS/m3S+Y" +
  b"sMG6dGImMU93cCOnnkU99eeBEuB/kgdDAepP6uW2ROi8Hov1XOo7w28Fwvwn8Lxgj0G3SewBlUb3tHVJzo3UmycOTd" +
  b"rVWykDtVhsVr2G3w7/how31VLyxALEvzDWr2ww3TjHwIOCDj81G67dKFXhSK5kmoYtOdaNErzg9i8pT1y1G78zWZb4" +
  b"3WKJau9McMPa+FJjmGL7TuHEvm1RU5RTmCAOblqoEr6BqgFICcVe1E2pvqNTLML/evGngH3yB1m7aX82HGYIM6HuW8" +
  b"xa0FmGFucy+zEj0TwiO9S6nvuWK2kxVepVSHuRQde3LwYD3SAdFBVI4UHZx+Fw/HooeR9Vtzphd5L+FY9/aaoOd32W" +
  b"w0EkmIsj0msWM2kmGk5S2F13zWIqxxYncfYIAwBoqzPlDvTwARnDX94Yu/VR9Vk5luhYWj37Y+sH99Zp1DgdIdP02G" +
  b"ya5Gs0KnQxePW1T3GSHNMfCB7aCM0E7EOKbNusAPuVAzZSEVUQ9U658BAVGuHKMWuwEMlm9y16BYUB9tPhv6WAOktp" +
  b"HVTRYN6kpGIO/qEtmqImkzM/WYz48D08OoVUNreTP6asqIZyWEfGTsrXWga2k/+TN3WQ1uD1c93Dp0lMWTNCQGG/mf" +
  b"t70ZxC3AKiLsqP+UNGTEyts7sFfUqfanSmSsE/argKTl32k38SxLTHSvwnaORrsabChZyhvbdNTTCQU2jK65rIdjAD" +
  b"CIS7EBrr6UmFNdHyiokpeNtXAoAgDJXzsb3UW7YbNc9PVPU2lV7p48hmWh0o5ORkbrpANFYjui55FMvQFaQWRe1IuK" +
  b"YD1A3tsmLRmuRQtoj8LhqUNwAKmFsriBkbJwQsLLkzYIKrZBt7ayd7Z98b/rzxV/AmcJm31fIPSAElyNs44LVOEs7G" +
  b"dfd7CJDVw4gin2pmGIJy6NtW+wnsDDmBXvLk0cqjQ3Es7QgV9LxzkPhJ7T1ZCPtYgu+zucaXx3rnt1LAgWuC4WwY2Y" +
  b"Fqch9rUwoCvks93uVfyo2zKT4mRj2YUlcqkqVkySXzcjXxmMTMPEgXZSFM0LiY6uWnzgGV+BjmdPk0zDruHmgrRIvW" +
  b"p4X7bWuYjIGh9rlOKoOt6/Fba5z9KOLoKjPtvkWRaZ1YLBurOdkH4+07+jBzKnrpVf93ob24lbUawzQiTtucycDVx8" +
  b"kfFXCFmZ1fUNj5VUWsGdcJrN5w4SL9EKmCzDmrBhNqzWWsk/LCIE3673lebRJ8VbKuO/3E99NmPKfp6C5HTcKQGGsg" +
  b"fBN1+At8vzbD0w9DdZOeu81nBEeoOBVOPu5bo7SsAKLjf9BLr5f3OeqrwV8P33JqbPI5dQMeBOD97WNAT7S3khn9Cg" +
  b"KzbiOQ5hU8qiCJImcb9Yq1JeYmUwm4xj36KNKnJR2CGnn5MDCbAGQC3ddQ+EQ19tQGQbs43MF4Mfy1QJVQo3Wa7vah" +
  b"QrsF/KLSiDU01x3xegZ4cMXKYY86Zlt2g4VpF4nS1RMeB6KiLANiAYmU8Lw9Oxl3Kis6KbSNMvzDKB7VWSCJIcXprQ" +
  b"aH2osaARABh1y7xZPaJi3vxCU60Go/uCR9BT0LqU2PZLuThbNDMn3xSqUT6dZukwe8IIYKvVRIAC7J0g6g3KTvTo6S" +
  b"BgPq72h23LsbbpnCN0l0QzHzVfNEaxmMoVQpGyvRwZLGl/yTWgZeKF7Jw8TxAz1HWFhTPJvk/EgX8yfHAf38lGqoXp" +
  b"nY4ks73RM4hHAPSbNb7mGVikRuzRMcoSdH2pExTIexvo8X49Vkn5gsWY3Fl9nkWCCCqzRkeog5Yd7NkVaSD1Ciewo4" +
  b"aVYivBbkB+CvVTg76ffDGi7+7SoM51NFaDr70Gn9i7g/Oswm/1ImvoYs2TptpSgo7s8/upcXdrzrg4f7n9iOZzw4dC" +
  b"YuuIynxb+yUtSfbHcnZW10NsAiD8VhUevmFPNn+r8uUWDMunho5dIMAbpmSdvA9JMKgngwkfrp/GkICESZBb6JRMB/" +
  b"RgYCjNqmSUXL+bAFoI+lnHPfQb7Mk2c3rGZMCONRgmnebuCJGJO95Jzr1/XEO5qQ9un4Pbs5xloUXvchcsaEwwbExq" +
  b"rn3uw68dbn+dH/GRTF3I2/ywhN5VUASgh+w9LE7mx/Vh9/7HrcmK00lpMnPSYG2/0WczAIJspXtC573kfA1S6Pfh29" +
  b"VDg4VGPUshm3rXDcFTnkSEpPIH2hB9ZDbXyhUaA12oEcTLTKBeYYBDk2PMKHxJEwj6velovhmPipob0Ldh7AhW9rk1" +
  b"sdc7BBSd+8rE7O2g2JGuT8QYPQTFAAfi3gmox2vjr3sswNOK46muTIBKtHPyAVQgxBL3SK7QCwdqvvNWKT7c5PL/+R" +
  b"3GRvIbzHtF+BcCpj/SZFy+nso8uaqi7z9MwxE1O3VzKlKiVXIfQxuL5XiE5qn5uB1vylxpWl8IKK0Ysa2r4anxg41V" +
  b"Qg0KAJSywe05z8kogKAXCVdZKLGj2GmeSYUSvoHW1Hisuoi0QBseeEBcsml9soCCh0p662gdoI39Asu8srIyAZ1CoI" +
  b"1vSrhOfiVUodkLxJQYF4vpm4lGSix3Yna/LIodJHtcnum6qaZAMdGRQImI3w28WK6aYt1TOVJetMttHwLragi8pOha" +
  b"Otm54VSa3qeMxnZ3lcBWYmV1nikms4e61TUNGM3RYP4xqvGl8hn3h2aHfGBN9IMRib2PGiLc0TBdbHEFyov1wbqJdx" +
  b"0BcaW0C8fRMuqGrpel1BB3evBEK7stn4zC3lRPUXAlrAtM1m+9Y/Yol0U/dnyw62VV2bfOCE6DG9eCv6wTEZAIJBaM" +
  b"i/cIryUaoOIiV+OgF3nJHVPPhgwKKkMCHMJXA7V3A4fYoXmbUy/J8pecmRvrHPJoK8OsNunIrdhkL/l+NVECamZuzc" +
  b"kiHZi/O9DUQRWAbfGwN6GhIMvrUbi1XpkMsBr9Zfh4MSuzjcgHVf/Fme6c09bso4yQUfNWvOGUVTB6N4/GEX5h9Qt3" +
  b"oZ1XoWxxfekMbVEi365UV+OCGNsBWPIPtmbbV+pceHYmJQ/MsQOdBOS/pHC4AWtd77SjIMBD9f7L8VaQ0UziglgfIW" +
  b"WIR/nBJukubnTE2xQvODModp706B6rO83PIrReLY4KF+EnG231bAObO8eEikB96iKuHqmxzP"

///|
let hls_aes_playlist : String = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:0\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n#EXTINF:0.500000,\nout0.ts\n#EXT-X-ENDLIST\n"

///|
let hls_aes_refs : Array[String] = [
  "67209b5b9f9f453b541ba569d470bf06", "4c68e9b9ab2953cdecf58ec39bdcb731", "bb1a50b7f8162369de23870524586f00",
  "0b3917a80f0ad951e4b841f6de258213", "5f67aea83c2fccc3403eca53df9b2740",
]

///|
fn hls_aes_fetch(key : Bytes, segment : Bytes) -> MediaFetch {
  (uri, offset, length) => {
    let data = if uri == "key.bin" {
      key
    } else if uri == "out0.ts" {
      segment
    } else {
      return Err("unexpected HLS resource: " + uri)
    }
    if offset < 0L || offset > data.length().to_int64() {
      return Err("bad range")
    }
    let end = if length < 0L {
      data.length().to_int64()
    } else {
      if offset + length > data.length().to_int64() {
        return Err("range past end")
      }
      offset + length
    }
    Ok(data[offset.to_int():end.to_int()].to_owned())
  }
}

///|
test "hls: AES-128 encrypted segment decrypts and decodes" {
  let key = @libavutil.av_base64_decode(hls_aes_key_b64, 64).unwrap()
  let segment = @libavutil.av_base64_decode(hls_aes_segment_b64, 16384).unwrap()
  let playlist = av_hls_parse(hls_aes_playlist).unwrap()
  assert_eq(playlist.keys.length(), 1)
  assert_eq(playlist.keys[0].method_, "AES-128")
  assert_eq(playlist.keys[0].uri, "key.bin")
  assert_eq(playlist.segments.length(), 1)
  assert_eq(playlist.segments[0].key_index, 0)
  let reader = hls_segment_reader_new(playlist, hls_aes_fetch(key, segment)).unwrap()
  let data = match reader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no HLS segment")
    Err(e) => fail("HLS read failed: \{e}")
  }
  let bytes = data.bytes()
  assert_true(bytes.length() > 0)
  assert_eq(bytes[0].to_int(), 0x47)
  let ts = av_mpegts_open(bytes).unwrap()
  assert_true(ts.streams.length() >= 1)
  let pid = ts.streams[0].pid
  let payload : Array[Byte] = []
  for packet in ts.packets {
    if packet.pid == pid {
      for b in packet.payload {
        payload.push(b)
      }
    }
  }
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(Bytes::from_array(payload), false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    let yuv = frames[i].yuvp()
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, yuv, yuv.length())
    let hex = "0123456789abcdef"
    let text = StringBuilder()
    for byte in digest {
      text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
      text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
    }
    assert_eq(text.to_string(), hls_aes_refs[i], msg="frame \{i}")
  }
}
