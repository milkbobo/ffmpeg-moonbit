///|
fn mk_frames() -> Array[(Bytes, Bytes, Bytes)] {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < 5; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (64 - 16)
    let by = f * 3 % (48 - 16)
    for row = 0; row < 48; row = row + 1 {
      for col = 0; col < 64; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f * 5) & 0xFF
        if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
          s = (s + 40) & 0xFF
        }
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        let border = col == bx ||
          col == bx + 15 ||
          row == by ||
          row == by + 15
        if inbox && border {
          s = 40
        } else if inbox {
          s = 220
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < 24; row = row + 1 {
      for col = 0; col < 32; col = col + 1 {
        u.push((((col + f) & 0x3F) + 96).to_byte())
        v.push((((row + f * 2) & 0x3F) + 96).to_byte())
      }
    }
    frames.push(
      (Bytes::from_array(y[:]), Bytes::from_array(u[:]), Bytes::from_array(v[:])),
    )
  }
  frames
}

///|
fn main raise {
  let stream = match
    @libavcodec.h264_encode_frames(
      mk_frames(),
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=60000,
      vbv_bufsize=12000,
      fps=30,
      b_slices=false,
      dct8x8=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  println("LEN " + stream.length().to_string())
  let mut hex = ""
  for i = 0; i < stream.length(); i = i + 1 {
    let b = stream[i].to_int() & 0xFF
    hex = hex + (if b < 16 { "0" } else { "" }) + b.to_string()
    if i >= 800 {
      break
    }
  }
  println("HEAD " + hex)
}
