///|
/// Hand-built VP9 compound-prediction session (3 frames, 64x64, one
/// superblock each), produced by .scratch/vp9compound/gen.py.  The inter
/// frames use refreshctx=0 + parallelmode=1 so no backward probability
/// adaptation runs and every table stays at its default.  Frame contents:
///   f0: keyframe, 64x64 DC_PRED -> Y=128 everywhere
///   f1: split into 4x 32x32 intra blocks; V_PRED without above (DC_127)
///       on top, H_PRED without left (DC_129) on the bottom; refreshes GOLD
///   f2: 64x64 ZEROMV compound (fix=LAST=f0, var=GOLD=f1):
///       top (128+127+1)>>1 = 128, bottom (128+129+1)>>1 = 129
/// Distinct from both f0 and either single-reference copy, so a decoder
/// that skips compound averaging is caught.
/// Reference: FFmpeg 9.0.2 native vp9 decoder framemd5 (`-threads 1`).

///|
let compound_ivf_b64 : Bytes = b"REtJRgAAIABWUDkwQABAAB4AAAABAAAAAwAAAAAAAAAeAAAAAAAAAAAAAACCSYNCAAPwA/AAACAACAegAAAAAAAARFAAAAAAAAAgAAAAAQAAAAAAAACGAIACBAAAQAASAD6AAAAAAAAAedZu180NYAAAAAAAABwAAAACAAAAAAAAAIYAAMYEAABAABIHXSAAAAAAAABnTgAAAAAAAAA="

///|
let compound_md5 : Array[String] = [
  "9604569c8e5fcd812a940b82ef39b552", "470e3310235bde394d3bb41ac9b59894", "fee9ffe4345401fe39524606a66a9ecf",
]

///|
fn vp9_ivf_frames(ivf : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos + 12 <= ivf.length() {
    let size = ivf[pos].to_int() |
      (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos += 12 + size
  }
  frames
}

///|
fn vp9_frame_md5(frame : @libavcodec.Vp9Frame) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, frame.data, frame.data.length())
  let text = StringBuilder()
  let hex = "0123456789abcdef"
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "vp9 compound prediction matches FFmpeg 9.0.2" {
  let ivf = @libavutil.av_base64_decode(compound_ivf_b64, 100000).unwrap()
  let decoder = @libavcodec.vp9_decoder_new()
  let frames = vp9_ivf_frames(ivf)
  assert_eq(frames.length(), compound_md5.length())
  for i, payload in frames {
    let output = decoder.decode_packet(payload).unwrap()
    assert_eq(output.length(), 1)
    let hash = vp9_frame_md5(output[0])
    assert_eq(
      hash,
      compound_md5[i],
      msg="compound frame \{i}: got \{hash}, want \{compound_md5[i]}",
    )
  }
}
