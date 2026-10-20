///|
/// White-box tests for the raw AAC/MPEG-audio framing slice.
///
/// Both files were produced by `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.2" \
///          -c:a aac -b:a 48k aac.aac
///   ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.1" \
///          -c:a libmp3lame -b:a 128k -id3v2_version 0 -write_xing 1 \
///          mp3_short.mp3
///
/// The expected frame positions/sizes are `ffprobe -show_packets` output.
/// The MP3 file starts with a Xing/Info frame (417 bytes at 0) which the C
/// parser drops; the first returned packet is therefore at 417. A synthetic
/// ID3v2 tag is prepended in one test to cover the tag skip and verify that
/// ffprobe's packet offsets shift by exactly the tag length (44).

///| Real 1517-byte ADTS AAC file (AAC-LC, 44100 Hz, mono).
let raw_aac_b64 : Bytes =
  bcat([
    b"//FQQBsf/NwATGF2YzYzLjEuMTAyAAI8qVspTFIerUV3rjWdNxJe7zVSoyj1kSIASOAiE5IgSIhkhnIqCSDEu2Vg2Bx5nSd7GUXP",
    b"tOFM7qjg0O6TXUUz6T9qx6XOxKxLdQqJH9i/C+vdV4bgd64Hes5yrG4q42bQbNjbFiblZblnOvYnHY3FPrZ9bPqqNfmr81fjKpSa",
    b"Wmn1s+qlKpquw0YeEmOrHVjqxw0YaMNEk0k0jSTSTSTSTSTSTSTSNI0k0kz0PQ82XLlii48YoooooooooooooouA//FQQBpf/AE4",
    b"mNrKXdZTyynYmyXelz/Pt1w2eNXdf+nr9+uNcavV6//seP588a41ern/9v3/nzxrrWr47Df62W2ePHlwH2TTuwWKXwqdZvKY25wG",
    b"c4DAzuEzAwM7hISDAzuEhIMDAzu4SErBgYGd3CQk4DDmXdwk40DMg153fIJCclwmwl3+EKsN1PnLlelK3pQm9mblCSpLMGlCQkle",
    b"BpQkJJXnBjZsJCSoNm4MDGwkJK3sc0WMoSVuwEEGXhwsxy8Q1FFFBqKKKKNxtdFH03Pc//FQQA///AFA9SykWgk3RkHQiHRiHQiH",
    b"QiV3++fn/t+/n6v+fTTS9VLkcEnF3cakuJAA0BYxxHEeYXbyKwxjOzs61MjJ8GGf3AyfBhn94R8fAGf3A4fAGf3AyfAHuQpzAJdT",
    b"F4Vt1yuMyLqxJWgnEYE5opI1Tj7BSkzv3Z2GfP/xUEARf/wA+DUs5IM6E0KB0SC0SB0RC0asn/p/T+f861epKvfEmNKt6lUq03ku",
    b"oEx08dPHTN3OAgQVCheHgKKKKKKKKGULoNaNhP+48dJ4KGevk7UvMWFbCyOFcmC8UFNmjnR+WBj2i57dV5Wv76PJAY4/fquKqLeB",
    b"yna4VK5pKQhh0/Vlt/zjMFf/8VBAE7/8AQI1GJY2KRThoUCItEIdEud/9vf/77v41e6dZUlWqTLyUPG8pRA7V010n7vfTpgKhGhq",
    b"kwjI7b677aa6SpnUJ5zqylU1pfU0HZXU3mn/yVNJwZuVTNgOzrmlo5OMv9NmvOOtvsfJ8+jMvvG77SCdm1Rqm3kg3977FN/WUIDr",
    b"qL7RFiTW9PAonWat2rRv3ya4FK6ESdOA//FQQBD//AEENS0IlSkLQqPQmLVEF7d1/+38f/P+271USfj9tI47d+pur2q6mQWBRlla",
    b"Onio0TfltRr/0QcLi+TfJvk3yaVEDGzcsuMtDXHQyyPDM1JVpzNKxFx75oRVV6BX7AmcKqtr9cYordNVEtBfLDDM181rcdZLOBnp",
    b"rcErhKzN6hfA//FQQBGf/AD2NSzwQ1IUh6IQ6Ig6EQ6Eg6NjP/7Xv/+P4vTaV1m71zqrlZD3lUjFqgGQsmaBGzp1vyevmo9QwBaF",
    b"OhToU2E0IdXVatM9HUyWMv8iEHMurYX/7Vc1reW+OALYditQL9Cot3TcmEoMVTzOTy0hD+wIbuyWcRHFaOuiQoOyNah9I9y3uY//",
    b"8VBAEB/8AQY1LWiFGQ9EodEJNOIXxPH/1+f/P/S647kipdRKO4yypkqSmAYVqaXU0jzG5a1ZQAFTyAtqaWppTJVpKmShISEpcDlM",
    b"qJptNU5n1LNkuhQiKvyurS2wxPNynSygPNNyHZkaJWlo4b4ynslkjglSzgXvrTVrFNFYcP/xUEAQf/wBHjUtFKQ+tIOjL7/r3/v7",
    b"U43e7marmSD2tJFln4iD+Jty4/75MpbvHHWQBOz1CiQHfqHrmAEpH2v+/9XT75/2f1OEm2fK7GVXM4sBA7durCYNGjgdubLQMNFB",
    b"w7dWk/4G0h7YgxGHwAFEPWAMDz8Bi0PcAcesuwxyTvHA//FQQBDf/AE0NSoMMja4huMzN/U8X9VYpe5EjuiSRIifiAlxP7XoLDlX",
    b"q3321eVerdC+awv5n4FSAybefU1Dx3KY0SSyqxOWM7OrRm0cqDMtVJLY4zFXhILY4sVeEPxmz6H/hPvN8N+8OTM77n+De5ZE+5fD",
    b"eeF/M77n+De8OTM7of+E+/A=",
  ])

///| Real 2506-byte MP3 file (LAME MPEG-1 Layer III 128 kbps 44.1 kHz mono,
/// no ID3v2 tag, leading Xing/Info frame).
let raw_mp3_b64 : Bytes =
  bcat([
    b"//uQwAAAAAAAAAAAAAAAAAAAAAAASW5mbwAAAA8AAAAFAAAJygBVVVVVVVVVVVVVVVVVVVVVVVVVf39/f39/f39/f39/f39/f39/",
    b"f3+qqqqqqqqqqqqqqqqqqqqqqqqqqtXV1dXV1dXV1dXV1dXV1dXV1dXV//////////////////////////8AAAAATGF2YzYzLjEu",
    b"AAAAAAAAAAAAAAAAJAMGAAAAAAAACcotUS3AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//uQxAAAFFSVIFW3gAsDKmOrPUAABZATg4E311NnUQUx",
    b"mPKxwVId1hHdUhwCYZ2KmHi5j5GZCOmMiZh4WYOBlo0wxMBbBCA1AhguBCDQUCvT6HnOh6Hq9nj0gPGBkePKa94b9+/vv3+KUpr3",
    b"pr//0pHu/w8MAPgAAeHh4eGADoAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAO94",
    b"eAAkAAAQAAQGAQmoYh4/hiX1zGBADAYwMUxghAEGO2ZkaxxGpglhCG8EJESgSnI4FsVAMzELCgMJUJ4OBekYCAqlYGQXgaxOZPga",
    b"RaAKOAx4xFfgY0kA4CBgAIGACpfwsSACBAYEIGyg3D/4YBFJCCwfEMaKB//DIoxwgsILDkigRQP/+KSDVwZGGND5RBUcoUEKC///",
    b"KJFSKmRFiLGJdLpkXv//V8ixiRUunCeNjpdNSw87+tjBHLxm0tCQGBUJA0owIQDbMCMA2zB8AkEwGIH2MD9CsjgffnU2ZI8jMfmF",
    b"FzD1gsUwdMJM//uSxBQD1eIJAB3ygAKdwCAB/g05MIVCBjCQQbwwMMCwRqYukTFZUOEj5mMYisKu1nM8rhNDORrmUQFCszOhUmVT",
    b"iY7MhqFoXERN3Rd2IaiEuRmQbEZBMrOtCO9FMe6TM7t1adGcyrn1c13MVTFPLkYrnlWcyOy2Z2lazsxDVH73TNKjEO7s7lVHGmZj",
    b"id2YhWKcySOi1Lb3SOcUMAlALTAigJYwQ0EtMH2CaDEix183ZjhjNzlHYzEoAqgwi0HHMEtBTTiUqOI/01WnTEQIRTZw/8OUlPz/",
    b"x7jrL+Rqpl+Hefnnqhw5mnTlnxcnx6fKDKrRKJnkKt+u8MbPYvVb5MxVjkTbUiJmMTySz3zVlOlVDxfTyzyISrn59J6XIFqqIM0j",
    b"mRfvqmZ5spTPN//XXNPhekKFThJD9iK6PyitVJpQ9ViVMCPAnjAnANMwNUFKMFmCfTDNx6Y1XjtQNTpHejC9AiU1+kjKRlNqrQ4h",
    b"ZzXBrMTgBK1xp3M5DWl3RwFPaiaig0EfyqxXs+h0LLUaxJrGKysKE87zEvdkfbzrPUlBzP/7ksQvA9NSBQIP8KbK00Ffwf6g2Z0V",
    b"F1dZOcyMZXGWRL1Yl1PzUqWpVIREosyuZ0ae1yGY5abJ6GcqpdVldkY5HnJV2dq5hjvYpUTdW2IsZrMA2AKjAqwKcwTwFKMJPCpz",
    b"FTCBg4nn3aOGoIIDFYwvc6EgQ1YYI01WE0ulQy+LowpA8vAw9/IbD8cPi+aVmQJr6l3m35CvN8PMp201UVRFVyrXMxOkcFqiJd3B",
    b"cW4yZi4+qa+KFLl38wqYzkttbSru8+HilMcS1yz9S2VY+kiRi9tVMzxd3csPvq7iLrp0FEW5qmjeD0ZebqjxjWZPznxY+hjN0lxn",
    b"pUTrwylIuzrLdLFUWMVVMCMAnzAmQNYwMwFRMFZCjDDFB9M1KPyZNQYHpzC0QjY1UozL5YNuKs4zWDXpmARNSSdWRYIUz3UrOWA9",
    b"N+jnBSsjalMKK7mdFXVUEB70IyoVJsrs1ktRLTu7XiplU7WvOmsg9vqYnt1XWgQFNy+f2W9BKjjwc5O2Twq+/sjXF2TpFbXxMW2b",
    b"9WX7+4D4WUlquWH35GpVMAoAPTD/+5LETYPSwPUCD/CmyuM9n8K+gAEewREwgcHBMHEEODEcCK46yzhNOWrSjzKDRwkxVsKRMGvD",
    b"QTC7QqMwtEKhMCtA8zALQAcSAC0vHEdQOCDHdRm/Ug4WTKPPRbWGmpEzJm6fOuD5RL/IHzVu9rYxDeVmhQdDLrF13G8RfNSOW2TH",
    b"T9T0tajZdvTmr6qJmFiYpJtH7dqF7n/pJ+RpXmhzeUjxj4m2pm7i6dVmF7P55+jmeq5trkaz1Ky/DcIZVpMjqLj+aSB5850CACBC",
    b"CBCAwhQkDKUmuMno1gzHvFDFAGVMO8wQ8fwWBECkdCYY5lcEFGfCg0YLgSJgrgFw8YewcRhSAjGCMAOYAgEMXpDq3k1dFXWYcM3r",
    b"GZm4iaETGKBRiwmFwoxcY73DgODAMPtvGzGRoKBJhweYcJ8/+cflU7bpCIBBCAGBgBgYMpSkT/5f/qwF40H1roAExC/rtQ87XJV3",
    b"/1rH2SJhsTddlkYlkaiLWWcwEzpd37/vf//kdTkrhuXv47EUfVnLDYk/zlSmWyn/1zX97/fct34u5EOSyH6e//uSxGyAJ64vFtnt",
    b"gAFui2ELnjAG3LOZf+qaNTMZhmajX6//1v//+f//qksU8btxiMTkPxu3GKR/pmMwzWppVjzf441qb///1//////////////9inzz",
    b"5vOpSWKentyyksS+nt//////yqrSxmtTRqrS0uWWX/+6tKICDkiASgE4kx2j0niPoFMcJfh6jqjp1DWXSgICArGb4xn8b+HqFAYK",
    b"xEeER6CsNOER4RHtYa/BqIpU6JQ1BpQNSp0q7/xLxEeLB2Co8FXA0HAaBpYKrBXiJ6gaTEFNRTQuMFVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQ==",
  ])

///| A synthetic ID3v2.4 tag: 10-byte header + 34 bytes of padding = 44 bytes
/// (the same total size as the LAME tag in the original test file).
fn synth_id3v2() -> Bytes {
  bcat([b"ID3\x04\x00\x00\x00\x00\x00\x22", b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"])
}

test "rawaudio: ID3v2 match and tag length" {
  let tag = synth_id3v2()
  assert_eq(tag.length(), 44)
  assert_true(ff_id3v2_match(tag))
  assert_eq(ff_id3v2_tag_len(tag), 44)
  // flags bit 4 signals a 10-byte footer, which ff_id3v2_tag_len adds.
  let with_footer = bcat([
    b"ID3\x04\x00\x10\x00\x00\x00\x22",
    tag.clamped_view(start=10, end=44).to_owned(),
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  ])
  assert_eq(ff_id3v2_tag_len(with_footer), 54)
  assert_true(!ff_id3v2_match(b"ID3\x04\xFF"))
}

test "rawaudio: ADTS AAC frames match ffprobe" {
  let data = @libavutil.av_base64_decode(raw_aac_b64, 4096).unwrap()
  assert_eq(data.length(), 1517)
  let t = av_adts_open(data).unwrap()
  assert_eq(t.codec, "aac")
  assert_eq(t.profile, "LC")
  assert_eq(t.sample_rate, 44100)
  assert_eq(t.channels, 1)
  assert_eq(t.frame_size, 1024)
  assert_eq(t.id3v2_size, 0)
  assert_eq(t.frames.length(), 10)
  assert_eq(t.total_samples, 10240L)
  // ffprobe packet (size,pos) pairs.
  let sizes = [216, 210, 127, 139, 157, 135, 140, 128, 131, 134]
  let poss = [0L, 216L, 426L, 553L, 692L, 849L, 984L, 1124L, 1252L, 1383L]
  for i = 0; i < 10; i = i + 1 {
    assert_eq(t.frames[i].size, sizes[i])
    assert_eq(t.frames[i].pos, poss[i])
    assert_eq(t.frames[i].duration, 1024)
    assert_eq(t.frames[i].pts, (i * 1024).to_int64())
    assert_true(t.frames[i].is_keyframe)
  }
}

test "rawaudio: MP3 frames match ffprobe and skip the Info frame" {
  let data = @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()
  assert_eq(data.length(), 2506)
  let t = av_mp3_open(data).unwrap()
  assert_eq(t.codec, "mp3")
  assert_eq(t.sample_rate, 44100)
  assert_eq(t.channels, 1)
  assert_eq(t.frame_size, 1152)
  assert_eq(t.bit_rate, 128000)
  assert_eq(t.id3v2_size, 0)
  assert_eq(t.info_frame_size, 417)
  assert_eq(t.frames.length(), 5)
  assert_eq(t.total_samples, 5760L)
  let sizes = [417, 418, 418, 418, 418]
  let poss = [417L, 834L, 1252L, 1670L, 2088L]
  for i = 0; i < 5; i = i + 1 {
    assert_eq(t.frames[i].size, sizes[i])
    assert_eq(t.frames[i].pos, poss[i])
    assert_eq(t.frames[i].duration, 1152)
  }
}

test "rawaudio: ID3v2 tag is skipped and shifts frame offsets" {
  let mp3 = @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()
  let data = bcat([synth_id3v2(), mp3])
  let t = av_mp3_open(data).unwrap()
  assert_eq(t.id3v2_size, 44)
  assert_eq(t.info_frame_size, 417)
  assert_eq(t.frames.length(), 5)
  // The Info frame moved from 0 to 44, the first packet from 417 to 461.
  assert_eq(t.frames[0].pos, 461L)
  assert_eq(t.frames[0].size, 417)
  assert_eq(t.frames[4].pos, 2132L)
}

test "rawaudio: truncated inputs are rejected" {
  assert_true(av_adts_open(b"\xFF\xF1\x50\x40\x1B\x1F\xFC") is Err(_))
  assert_true(av_mp3_open(b"\x00\x00\x00\x00") is Err(_))
  let mp3 = @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()
  let head = mp3.clamped_view(start=0, end=500).to_owned()
  // Only the Info frame fits before the cut, so there is no packet.
  assert_true(av_mp3_open(head) is Err(_))
}
