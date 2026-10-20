///|
/// White-box tests for the fixed-point Layer III decoder.
///
/// `mp3_raw_b64` is a 2089-byte MP3 produced by `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.1" \
///          -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 \
///          mp3_raw.mp3
///
/// It has 5 frames (5760 samples, 44100 Hz mono). The expected PCM MD5 is
/// from FFmpeg's fixed decoder:
///
///   ffmpeg -c:a mp3 -i mp3_raw.mp3 -f s16le -acodec pcm_s16le ref.pcm
///   md5(ref.pcm) = 7c931d35ff3115c5704ba1ed4afce00e
///
/// The float decoder produces a different MD5 (`ef1b9388...`), so this vector
/// specifically pins the fixed-point path.

///| Real MP3, no ID3/Xing frame.
let mp3_raw_b64 : Bytes =
  b"//uQxAAAFFSVIFW3gAsDKmOrPUAABZATg4E311NnUQUxmPKxwVId1hHdUhwCYZ2KmHi5j5GZCOmMiZh4WYOBlo0wxMBbBCA1AhguBCDQUCvT6HnOh6Hq9nj0gPGBkePKa94b9+/vv3+KUpr3pr//0pHu/w8MAPgAAeHh4eGADoAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAAAAHh4eHhgAAO94eAAkAAAQAAQGAQmoYh4/hiX1zGBADAYwMUxghAEGO2ZkaxxGpglhCG8EJESgSnI4FsVAMzELCgMJUJ4OBekYCAqlYGQXgaxOZPgaRaAKOAx4xFfgY0kA4CBgAIGACpfwsSACBAYEIGyg3D/4YBFJCCwfEMaKB//DIoxwgsILDkigRQP/+KSDVwZGGND5RBUcoUEKC///KJFSKmRFiLGJdLpkXv//V8ixiRUunCeNjpdNSw87+tjBHLxm0tCQGBUJA0owIQDbMCMA2zB8AkEwGIH2MD9CsjgffnU2ZI8jMfmFFzD1gsUwdMJM//uSxBQD1eIJAB3ygAKdwCAB/g05MIVCBjCQQbwwMMCwRqYukTFZUOEj5mMYisKu1nM8rhNDORrmUQFCszOhUmVTiY7MhqFoXERN3Rd2IaiEuRmQbEZBMrOtCO9FMe6TM7t1adGcyrn1c13MVTFPLkYrnlWcyOy2Z2lazsxDVH73TNKjEO7s7lVHGmZjid2YhWKcySOi1Lb3SOcUMAlALTAigJYwQ0EtMH2CaDEix183ZjhjNzlHYzEoAqgwi0HHMEtBTTiUqOI/01WnTEQIRTZw/8OUlPz/x7jrL+Rqpl+Hefnnqhw5mnTlnxcnx6fKDKrRKJnkKt+u8MbPYvVb5MxVjkTbUiJmMTySz3zVlOlVDxfTyzyISrn59J6XIFqqIM0jmRfvqmZ5spTPN//XXNPhekKFThJD9iK6PyitVJpQ9ViVMCPAnjAnANMwNUFKMFmCfTDNx6Y1XjtQNTpHejC9AiU1+kjKRlNqrQ4hZzXBrMTgBK1xp3M5DWl3RwFPaiaig0EfyqxXs+h0LLUaxJrGKysKE87zEvdkfbzrPUlBzP/7ksQvA9NSBQIP8KbK00Ffwf6g2Z0VF1dZOcyMZXGWRL1Yl1PzUqWpVIREosyuZ0ae1yGY5abJ6GcqpdVldkY5HnJV2dq5hjvYpUTdW2IsZrMA2AKjAqwKcwTwFKMJPCpzFTCBg4nn3aOGoIIDFYwvc6EgQ1YYI01WE0ulQy+LowpA8vAw9/IbD8cPi+aVmQJr6l3m35CvN8PMp201UVRFVyrXMxOkcFqiJd3BcW4yZi4+qa+KFLl38wqYzkttbSru8+HilMcS1yz9S2VY+kiRi9tVMzxd3csPvq7iLrp0FEW5qmjeD0ZebqjxjWZPznxY+hjN0lxnpUTrwylIuzrLdLFUWMVVMCMAnzAmQNYwMwFRMFZCjDDFB9M1KPyZNQYHpzC0QjY1UozL5YNuKs4zWDXpmARNSSdWRYIUz3UrOWA9N+jnBSsjalMKK7mdFXVUEB70IyoVJsrs1ktRLTu7XiplU7WvOmsg9vqYnt1XWgQFNy+f2W9BKjjwc5O2Twq+/sjXF2TpFbXxMW2b9WX7+4D4WUlquWH35GpVMAoAPTD/+5LETYPSwPUCD/CmyuM9n8K+gAEewREwgcHBMHEEODEcCK46yzhNOWrSjzKDRwkxVsKRMGvDQTC7QqMwtEKhMCtA8zALQAcSAC0vHEdQOCDHdRm/Ug4WTKPPRbWGmpEzJm6fOuD5RL/IHzVu9rYxDeVmhQdDLrF13G8RfNSOW2THT9T0tajZdvTmr6qJmFiYpJtH7dqF7n/pJ+RpXmhzeUjxj4m2pm7i6dVmF7P55+jmeq5trkaz1Ky/DcIZVpMjqLj+aSB5850CACBCCBCAwhQkDKUmuMno1gzHvFDFAGVMO8wQ8fwWBECkdCYY5lcEFGfCg0YLgSJgrgFw8YewcRhSAjGCMAOYAgEMXpDq3k1dFXWYcM3rGZm4iaETGKBRiwmFwoxcY73DgODAMPtvGzGRoKBJhweYcJ8/+cflU7bpCIBBCAGBgBgYMpSkT/5f/qwF40H1roAExC/rtQ87XJV3/1rH2SJhsTddlkYlkaiLWWcwEzpd37/vf//kdTkrhuXv47EUfVnLDYk/zlSmWyn/1zX97/fct34u5EOSyH6e//uSxGyAJ64vFtntgAFui2ELnjAG3LOZf+qaNTMZhmajX6//1v//+f//qksU8btxiMTkPxu3GKR/pmMwzWppVjzf441qb///1//////////////9inzz5vOpSWKentyyksS+nt//////yqrSxmtTRqrS0uWWX/+6tKICDkiASgE4kx2j0niPoFMcJfh6jqjp1DWXSgICArGb4xn8b+HqFAYKxEeER6CsNOER4RHtYa/BqIpU6JQ1BpQNSp0q7/xLxEeLB2Co8FXA0HAaBpYKrBXiJ6gaTEFNRTQuMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQ=="

///| Lowercase hex of a byte buffer.
fn mp3_hex(bytes : FixedArray[Byte], n : Int) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///| S16 little-endian MD5 of an interleaved sample buffer.
fn mp3_pcm_md5(samples : Array[Int]) -> String {
  let bytes = FixedArray::make(samples.length() * 2, b'\x00')
  for i = 0; i < samples.length(); i = i + 1 {
    let v = samples[i]
    bytes[2 * i] = (v & 0xFF).to_byte()
    bytes[2 * i + 1] = ((v >> 8) & 0xFF).to_byte()
  }
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, Bytes::from_array(bytes[:]), bytes.length())
  mp3_hex(digest, 16)
}

test "mp3: fixed-point decode matches FFmpeg (mono, 5 frames)" {
  let data = @libavutil.av_base64_decode(mp3_raw_b64, 4096).unwrap()
  assert_eq(data.length(), 2089)
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 1)
  assert_eq(pcm.samples.length(), 5760) // 5 * 1152
  assert_eq(mp3_pcm_md5(pcm.samples), "7c931d35ff3115c5704ba1ed4afce00e")
  // FFmpeg fixed decoder: first 16 samples are zero, sample 31 is -1.
  for i = 0; i < 16; i = i + 1 {
    assert_eq(pcm.samples[i], 0)
  }
  assert_eq(pcm.samples[31], -1)
}

test "mp3: fixed-point stereo decode matches FFmpeg" {
  let data = @libavutil.av_base64_decode(mp3_stereo_b64, 4096).unwrap()
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.samples.length(), 11520) // 5 * 1152 * 2
  assert_eq(mp3_pcm_md5(pcm.samples), mp3_stereo_md5)
}

test "mp3: MPEG-2 LSF decode matches FFmpeg" {
  let data = @libavutil.av_base64_decode(mp3_lsf_b64, 4096).unwrap()
  let pcm = decode_mp3_stream(data).unwrap()
  assert_eq(pcm.sample_rate, 22050)
  assert_eq(pcm.channels, 1)
  assert_eq(pcm.samples.length(), 3456) // 6 * 576
  assert_eq(mp3_pcm_md5(pcm.samples), mp3_lsf_md5)
}
