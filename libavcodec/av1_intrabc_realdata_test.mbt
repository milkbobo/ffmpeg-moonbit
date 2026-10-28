///|
/// Real AV1 intra block copy: SVT-AV1 v4.2 streams (`-svtav1-params
/// enable-intrabc=1`, with and without screen-content-mode=2) whose key
/// frames carry `allow_intrabc=1` and intrabc blocks. Frame MD5s match
/// dav1d 1.5.1's `-fps_mode passthrough -f framemd5` output.

///|
let av1_intrabc_cases : Array[(String, Bytes, Array[String])] = [
  (
    "testsrc2, intrabc",
    @libavutil.av_base64_decode(
      b"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",
      8192,
    ).unwrap(),
    [
      "a8e4db41b9c5ecc2eb461b90188a6a73", "ad93113ecf812b16a5158b7f2c4e3892", "81f80d179ac15b2353769ed34953d34d",
      "81f80d179ac15b2353769ed34953d34d",
    ],
  ),
  (
    "smptebars, intrabc",
    @libavutil.av_base64_decode(
      b"REtJRgAAIABBVjAxQAAwAAoAAAABAAAABAAAAAAAAABjAQAAAAAAAAAAAAASAAoOAgAABVV/vGr5ECAgUEAyzgIUAKPAQL9VxGNpqns6KZ8eBacjBsdrH/7MqK8Qzc4t4X7c5BCgefErlcCa7S61zL9xpjx2hSSo+h30EwA0Ijcdhnn+7v61Ule1g3pSafjJJxBXVSh5/8YSkpKeG2P7W889+ItD60TPXhzRd7g2bN/mW5Oc8BoSWymHRgsTm0a2pixCoNo7f8wQuVT59j6RRxo2UniW/0mqOReBCGfLyz9P9L9BKejumpmvzVA9Ngp3GzJgRtcEW1o4LFHviAW/g8lAFTyA/Wd92O9+egSg+Cow1nVX1vkSF+V9u1hRWNEjKOIP8tIW0iSAV8/OZnCgkpdrAxH2KYQ/m/oAQjTTwOIli68aSi3ztvHpwD+mz1ypiIZlexrhX2M2ZYwx5EQtQLDxdBxxwWfRbcUlcO9wVWBHflcDk7/Zbik7LMdBCQIcEDfE4oASrjA99/t15rlAFAAAAAEAAAAAAAAAEgAyEDACAAAAAHrwAAACAAAAlphjAQAAAgAAAAAAAAASAAoOAgAABVV/vGr5ECAgUEAyzgIUBKPAQL9VxGNpqns6KZ8eBacjBsdrH/7MqK8Qzc4t4X7c5BCgefErlcCa7S61zL9xpjx2hSSo+h30EwA0Ijcdhnn+7v61Ule1g3pSafjJJxBXVSh5/8YSkpKeG2P7W889+ItD60TPXhzRd7g2bN/mW5Oc8BoSWymHRgsTm0a2pixCoNo7f8wQuVT59j6RRxo2UniW/0mqOReBCGfLyz9P9L9BKejumpmvzVA9Ngp3GzJgRtcEW1o4LFHviAW/g8lAFTyA/Wd92O9+egSg+Cow1nVX1vkSF+V9u1hRWNEjKOIP8tIW0iSAV8/OZnCgkpdrAxH2KYQ/m/oAQjTTwOIli68aSi3ztvHpwD+mz1ypiIZlexrhX2M2ZYwx5EQtQLDxdBxxwWfRbcUlcO9wVWBHflcDk7/Zbik7LMdBCQIcEDfE4oASrjA99/t15rlAFAAAAAMAAAAAAAAAEgAyEDAGAAAAAHrwAAACAAAAlpg=",
      8192,
    ).unwrap(),
    [
      "9f7229b841a757f2c721e698bee33d7c", "9f7229b841a757f2c721e698bee33d7c", "9f7229b841a757f2c721e698bee33d7c",
      "9f7229b841a757f2c721e698bee33d7c",
    ],
  ),
  (
    "testsrc2, screen-content-mode=2",
    @libavutil.av_base64_decode(
      b"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",
      8192,
    ).unwrap(),
    [
      "a8e4db41b9c5ecc2eb461b90188a6a73", "ad93113ecf812b16a5158b7f2c4e3892", "81f80d179ac15b2353769ed34953d34d",
      "81f80d179ac15b2353769ed34953d34d",
    ],
  ),
  (
    "smptebars, screen-content-mode=2",
    @libavutil.av_base64_decode(
      b"REtJRgAAIABBVjAxQAAwAAoAAAABAAAABAAAAAAAAABjAQAAAAAAAAAAAAASAAoOAgAABVV/vGr5ECAgUEAyzgIUAKPAQL9VxGNpqns6KZ8eBacjBsdrH/7MqK8Qzc4t4X7c5BCgefErlcCa7S61zL9xpjx2hSSo+h30EwA0Ijcdhnn+7v61Ule1g3pSafjJJxBXVSh5/8YSkpKeG2P7W889+ItD60TPXhzRd7g2bN/mW5Oc8BoSWymHRgsTm0a2pixCoNo7f8wQuVT59j6RRxo2UniW/0mqOReBCGfLyz9P9L9BKejumpmvzVA9Ngp3GzJgRtcEW1o4LFHviAW/g8lAFTyA/Wd92O9+egSg+Cow1nVX1vkSF+V9u1hRWNEjKOIP8tIW0iSAV8/OZnCgkpdrAxH2KYQ/m/oAQjTTwOIli68aSi3ztvHpwD+mz1ypiIZlexrhX2M2ZYwx5EQtQLDxdBxxwWfRbcUlcO9wVWBHflcDk7/Zbik7LMdBCQIcEDfE4oASrjA99/t15rlAFAAAAAEAAAAAAAAAEgAyEDACAAAAAHrwAAACAAAAlphjAQAAAgAAAAAAAAASAAoOAgAABVV/vGr5ECAgUEAyzgIUBKPAQL9VxGNpqns6KZ8eBacjBsdrH/7MqK8Qzc4t4X7c5BCgefErlcCa7S61zL9xpjx2hSSo+h30EwA0Ijcdhnn+7v61Ule1g3pSafjJJxBXVSh5/8YSkpKeG2P7W889+ItD60TPXhzRd7g2bN/mW5Oc8BoSWymHRgsTm0a2pixCoNo7f8wQuVT59j6RRxo2UniW/0mqOReBCGfLyz9P9L9BKejumpmvzVA9Ngp3GzJgRtcEW1o4LFHviAW/g8lAFTyA/Wd92O9+egSg+Cow1nVX1vkSF+V9u1hRWNEjKOIP8tIW0iSAV8/OZnCgkpdrAxH2KYQ/m/oAQjTTwOIli68aSi3ztvHpwD+mz1ypiIZlexrhX2M2ZYwx5EQtQLDxdBxxwWfRbcUlcO9wVWBHflcDk7/Zbik7LMdBCQIcEDfE4oASrjA99/t15rlAFAAAAAMAAAAAAAAAEgAyEDAGAAAAAHrwAAACAAAAlpg=",
      8192,
    ).unwrap(),
    [
      "9f7229b841a757f2c721e698bee33d7c", "9f7229b841a757f2c721e698bee33d7c", "9f7229b841a757f2c721e698bee33d7c",
      "9f7229b841a757f2c721e698bee33d7c",
    ],
  ),
]

///|
fn av1_intrabc_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b' ')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "av1: intrabc blocks decode like dav1d" {
  for entry in av1_intrabc_cases {
    let (name, data, refs) = entry
    let dec = @libavcodec.Av1Decoder::new()
    let mut pos = 32
    let mut index = 0
    while pos + 12 <= data.length() {
      let size = data[pos].to_int() |
        (data[pos + 1].to_int() << 8) |
        (data[pos + 2].to_int() << 16) |
        (data[pos + 3].to_int() << 24)
      match dec.decode_packet(data[pos + 12:pos + 12 + size].to_owned()) {
        Ok(Some(picture)) => {
          assert_true(index < refs.length(), msg=name)
          assert_eq(
            av1_intrabc_md5(picture.packed()),
            refs[index],
            msg="\{name} frame \{index}",
          )
          index = index + 1
        }
        Ok(None) => ()
        Err(e) => fail("\{name} packet \{index}: \{e}")
      }
      pos = pos + 12 + size
    }
    assert_eq(index, refs.length(), msg=name)
  }
}
