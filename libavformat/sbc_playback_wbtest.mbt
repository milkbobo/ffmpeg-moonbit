///|
/// FFmpeg 9.0.2 SBC reference streams. Stereo input uses 48 kHz
/// `aevalsrc=0.55*sin(2*PI*997*t)|0.42*sin(2*PI*1201*t)`, encoded at
/// 160 and 320 kb/s. The 16 kHz 997 Hz mono sine uses `-b:a 96k
/// -sbc_delay 0.003` and `-msbc 1`, respectively.
let sbc_joint_fixture = b"nP0UN/7ZhmZW1DISBn7b+A2/hNv4scCxNC8mSJ7c4m3FGNrH7aDY25xN4mzeg428WNjZDZWc/RS0sNIAAADQAAAApTSZM/GBGBeid2zAxdy7cLraacrBkFjyUjlHMp0fg7hOW0zWDhXKu5z9FLSw0gAAANAAAAAGTZPM9cGwP4kmo5SisyMaqwesdNMtvEuOchskEvxaIyi8TZ20GSPynP0UtLDSAAAA0AAAAIgYqBqAbEDlbLNqujp7x8iQ2UJfN6dyNRV/N15pSNsO1hLKBi2zhOec/RS0sNIAAADQAAAAvS9PeyanlZMLMByq52xmzK0MK5B3G9SLBVwjCFxDljOJE/KPGSiKiZz9FLSw0gAAANAAAABsIRT8rGO5eoPDzxFZmmw3J8HdC3o2bnNE34+GUtoGreNM2rguX2MlnP0UtLDSAAAA0AAAAKqWY2M9HyrnLFnFzFv7kXuchQMPXqMIBDuOMvj78JWZmQqTbSFUjKac/RS0sNIAAADQAAAAXTjKg73Vkcn6ejaoIY0DdTVuaz7jkDag6gguIxTNs01vOyOtlzPJSw=="

///|
let sbc_stereo_fixture = b"nPkva+mGZlbZhmZWf7u1f3drAHdrAO7WCxDWEiGsNiCsTEFZvW4KutwYYpo8BTRnsQ1gIhqsndqNO7U5u7U/d2rAd2t67taY7teV3a4t3awDu1n7u1GXdqs3dqfu7U5u7W9d2q9d2vK7tZz5L0HiEQAA0AAAAKVbHLvAT4zBUjcZ5oWZyNSA8tmWWRL705mWqlcyS8Byu0gA6Q5MNyM3YzRQlZA7oo52NF+0uK2mJOYc5lVakv765txvUGY6MVKL0gsYzRWrW/3o7ZyRPL4uvmWI37uc+S9B4hEAANAAAAA5l2LUDLC3bxuzQdqHtNO3gKYzJUbTlwpNh2JT8uvU2Wphk45nVLToSa1Kvt0wMaDBMP3yy4yxYjZ9zpfh2RYyGv6mOJULE5rU6UYJqy6yPS5WZ+TLOy+n4yNWhYY5nPkvQeIRAADQAAAApxSGRSGcwgWV5MGo5w1b08piwtxPUfKp5hMM0MX4xdUhVDsqC5+BeEMxG19heUE53U60PgyuixOyGJZ0tQNyiFYwhSZXCjqUJx9nJoxtWV5nuM5/07EDDasYxt0RKJz5L0HiEQAA0AAAAJv3PNzhf4vVadbknqlRp1T1+yUWWhBhE6J07kooyqQxuww25q/QNzyN4uBWbV6bq2Jl9gwQy7l2BkWQ6V0rUYe6oLxvT5DpmDNSy874sdaZUX/rGxx5aMGzjV+JsROc+S9B4hEAANAAAAA6izrz8gKmHxwReU5hFSN0L7YqtehdGhrXKCNmJe0LGOA+PM6xUcUPF6kFxQzF7ZcFNOyjgYoxidfFLrnJ2BXHM0zVmR3gs7B0sEi8iiFxQTR3pXDOO1izYmpcfbjYnPkvQeIRAADQAAAAr3BiBbvO1blmBhdw7T0MDI/qgIxQyxgpR/WPzxlYkRefh3DsGhh9gum2EWN5Ehw7nS7kYzqeMxQx4vJM3SP07P4hxmZcXLsVxuBqR22tFeJsbg78UsD8VycTxvSde5z5L0HiEQAA0AAAAJHxUP0Lh4fBcddJaskx2BuOm3WF15OKA8S0KzOq6adxyQFu5CnSO2k84cFqbnHuszhyB3Ei3/lOBnTQ8qzMDi2iYoxyRSmI9dWPzkEYZBmXjiDtCBt5zog4o02JRa0="

///|
let sbc_mono_fixture = b"nAAMKoZDe7gznEzonAAMSbdmpK5JTVCVnAAMP7IQro9rUiCDnAAMJrEArG96VABznAAMJrEAqd+DVpBsnAAMJrEAp++TWQBbnAAMJrEApV+bWwBTnAAMJrEAo1+sXYBLnAAMJrEAoN+zX4A7nAAMJrEAnm+7YhAznAAMJrEAnF/DZJAqnAAMJrEAme/KZwAjnAAMJrEAl2/TaRAbnAAMJrEAlN/ba4AbnAAMJrEAku/kbhATnAAMJrEAkG/jcJALnAAMJrEAjd/rcoAKnAAMJrEAi1/rdQADnAAMJrEAiN/zd4ADnAAMJrEAht/zehADnAAMJrEAhG/0fJACnAAMJrEAge/0fpADnAAMJrEAf1/zgRADnAAMJrEAfO/0g4ACnAAMJrEAeu/0hhACnAAMJrEAeG/ziJACnAAMJrEAdd/sioALnAAMJrEAc1/sjRAKnAAMJrEAcO/kj5ASnAAMJrEAbu/jkhASnAAMJrEAbG/clBAanAAMJrEAae/UloAinAAMJrEAZ1/MmQAqnAAMJrEAZW/Em5AynAAMJrEAYt+8nZA6nAAMJrEAYF+0oBBCnAAMJrEAXl+sopBRnAAMJrEAW9+kpJBZnAAMJrEAWV+UpxBinAAMJrEAV1+MqRBynAAMJrEAVN98q5CCnAAMJrEAUt9srZCJnAAMJrEAUG9ksBCanAAMJrEATl9UshCpnAAMJrEAS99EtJC5nAAMJrEASd80tpDJnAAMJrEAR98luJDanAAMJrEARV8VuxDpnAAMJrEAQ179vQEBnAAMJrEAQV7svxERnAAMJrEAP17dwREpnAAMarAAPS7Lw8E+nAAMJrEAO061xRFRnAAMJrEAOV6dx5FhnAAMJrEAN16FyRF4nAAMJrEANU5syxGRnAAMJrEAM15VzSGpnAAMJrEAMV5FzxHBnAAMJrEAL14t0RHZnAAMJrEALd4N0pHwnAAMJrEAK9311JIJnAAMJrEAKc3e1qIpnAAMJrEAKE3F2BJBnAAMJrEAJl2l2aJZ"

///|
let sbc_msbc_fixture = b"rQAAILuGVlV+92tfvdrYcIa146DMxVyhUpZo6jmGtXldrZ+Xa1gV2tnZdrWBXa2bl2tYldrZmXa0rQAA85sAAAAXgqF5R1hR4imbefWlJMKSdfNcErcot0Q12TIyhXKbXtOQKAcOdgU/sntvN2GUaCdkrQAA1osAAADsDYpGpJyd6NjUoMm90M2RTYSbHDDZRQ6JpbVdllRUmdp42XV8yZmZ7ZlbQJlYwtmUrQAA1osAAAB6omRfl2aYhyZFwjZlliJlWLtmGkEmZVQ2XbGiaFHbZVv3JqTmdk3NIm1LA2QdrSb0rQAA85sAAABPHY1tDJzUhNiW7AndQY2FcHSfE6vYByJKBTQNenPUodLT10dYSjUmnW53LKTR/9Z0rQAAnKsAAACxrKaTKdYLT8qJJX1YuEyqkYXVC7jKzQstR77Irw/k0+wgCxTxnTTFOLPOTNKchYtorQAAnKsAAAA2A0fy4i5DLfRTOpLwL8tCNG8vwsuz81NTCCmjO/X0MVJqs49rUyIjrzV3dDMCC3McrQAAnKsAAADgxM+Hc8ueOg00a5yq5oTWxgLJvpWNrFTci+wg3sSdx77uDiw/DGvxpObDQsWvRM6w"

///|
/// Four 4-subband frames using the 12-bit independent pools from the mono
/// sample, repacked for dual channel and SNR allocation, with CRCs updated.
let sbc_dual_snr_fixture = b"nAYMdoZDhkN7t7uDODOcScTOjOicBgxet2a3ZqSqSuSeSU1U1QlQlZwGDLayELIQroro9r9rUiUiCDCDnAYMDbEAsQCsasb3r3pUBUAHMHM="

///|
test "SBC and mSBC packets and PCM match FFmpeg" {
  for
    (b64, rate, channels, count, size, duration, md5) in [
      (
        sbc_joint_fixture, 48000, 2, 1024, 53, 128, "97cc0a88bd17d56ca364553374cfab40",
      ),
      (
        sbc_stereo_fixture, 48000, 2, 1024, 106, 128, "634671e47985dcacf5ead8b383be95d2",
      ),
      (
        sbc_mono_fixture, 16000, 1, 1024, 12, 16, "c39d8636f959683038d928d3c628c478",
      ),
      (
        sbc_msbc_fixture, 16000, 1, 960, 57, 120, "2fb9f90a1608bf9703116c65b4980b62",
      ),
      (
        sbc_dual_snr_fixture, 16000, 2, 64, 20, 16, "d5650108f52badfbff130ac2a9f3c30a",
      ),
    ] {
    let data = @libavutil.av_base64_decode(b64, 2048).unwrap()
    let track = av_sbc_open(data).unwrap()
    assert_eq(track.total_samples, count.to_int64())
    for i, frame in track.frames {
      assert_eq(frame.pos, (i * size).to_int64())
      assert_eq(frame.pts, (i * duration).to_int64())
      assert_eq(frame.size, size)
      assert_eq(frame.duration, duration)
    }
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name, "sbc")
    assert_eq(audio.codec_id, "sbc")
    assert_eq(audio.sample_rate, rate)
    assert_eq(audio.channels, channels)
    assert_eq(audio.samples[0].length(), count)
    let wave = audio.to_wav_s16()
    let demux = av_wav_open(wave).unwrap()
    let start = demux.data_offset.to_int()
    let pcm = wave[start:start + demux.data_size.to_int()].to_owned()
    assert_eq(caf_md5(pcm), md5)
  }
}

///|
test "raw SBC validates CRC and frame bounds" {
  let data = @libavutil.av_base64_decode(sbc_joint_fixture, 2048).unwrap()
  let frame = data[:53].to_owned()
  assert_eq(MediaFile::open(frame).format_name(), "sbc")
  let corrupt = frame.to_array()
  corrupt[3] = (corrupt[3].to_int() ^ 1).to_byte()
  assert_true(
    av_sbc_open(Bytes::from_array(corrupt)) is Err("sbc: header CRC mismatch"),
  )
  assert_true(
    av_sbc_open(data[:data.length() - 1].to_owned())
    is Err("sbc: truncated frame"),
  )
}
