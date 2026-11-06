///|
/// libswscale port, slice 1: the 24-bit packed-RGB output path for planar
/// 8-bit YUV 4:2:0 (`yuv2rgb_1_c_template` + `yuv2rgb_write`). The lookup
/// tables are the official FFmpeg n9.0.2 probe (see
/// swscale_official_data.mbt) - FFmpeg 9 builds them through the
/// double-precision color-management pass, so byte-exactness comes from
/// consuming the probed data rather than re-deriving it.

///|
/// A reusable YUV420P -> packed 24-bit RGB converter (BT.601 limited
/// range, the swscale default).
pub struct Yuv2Rgb {
  priv bgr : Bool
}

///|
/// The swscale default: BT.601 limited (MPEG) range.
pub fn Yuv2Rgb::mpeg() -> Yuv2Rgb raise {
  { bgr: false }
}

///|
/// Convert one compact planar YUV 4:2:0 frame (`y` is w*h bytes, `u`/`v`
/// are (w/2)*(h/2); exactly the layout `VideoFrame::yuv_bytes` emits) to
/// packed RGB24 (`bgr=false`, R first) or BGR24 (`bgr=true`).
pub fn Yuv2Rgb::yuv420_to_rgb24(
  self : Yuv2Rgb,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  width : Int,
  height : Int,
  bgr~ : Bool = false,
) -> Bytes raise {
  if width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0 {
    fail("yuv2rgb: width and height must be positive and even")
  }
  let cw = width / 2
  let ch = height / 2
  if y.length() < width * height || u.length() < cw * ch || v.length() < cw * ch {
    fail("yuv2rgb: plane too small for the given geometry")
  }
  let w = width
  let h = height
  let flip = self.bgr || bgr
  let out : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    let crow = row / 2
    let yrow = row * w
    let crow_off = crow * cw
    for col = 0; col < w; col = col + 1 {
      let yv = y[yrow + col].to_int()
      let uv = u[crow_off + col / 2].to_int() + 512
      let vv = v[crow_off + col / 2].to_int() + 512
      let r = official_y_table[official_base_r[vv] + yv]
      // The C stores G as table_gU[U][Y] + table_gV[V] and writes through
      // a uint8_t pointer, so the possibly negative sum wraps mod 256.
      let g = (official_y_table[official_base_gu[uv] + yv] + official_off_gv[vv]) & 0xFF
      let b = official_y_table[official_base_b[uv] + yv]
      if flip {
        out.push(b.to_byte())
        out.push(g.to_byte())
        out.push(r.to_byte())
      } else {
        out.push(r.to_byte())
        out.push(g.to_byte())
        out.push(b.to_byte())
      }
    }
  }
  Bytes::from_array(out[:])
}
