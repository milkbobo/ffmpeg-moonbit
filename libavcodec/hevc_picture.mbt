///|
/// Decoded 8/10/12-bit 4:2:0 picture planes (samples stored as `Int32`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct HevcPicture {
  width : Int32
  height : Int32
  y : Array[Int32]
  cb : Array[Int32]
  cr : Array[Int32]
}

///|
pub fn hevc_picture_new(width : Int32, height : Int32) -> HevcPicture {
  let cw = (width + 1) >> 1
  let ch = (height + 1) >> 1
  {
    width,
    height,
    y: Array::make(width * height, 0),
    cb: Array::make(cw * ch, 0),
    cr: Array::make(cw * ch, 0),
  }
}

///|
/// Deep copy: output frames must not alias DPB slots that later pictures reuse. */
fn HevcPicture::clone(self : HevcPicture) -> HevcPicture {
  {
    width: self.width,
    height: self.height,
    y: self.y.copy(),
    cb: self.cb.copy(),
    cr: self.cr.copy(),
  }
}

///|
fn HevcPicture::plane(self : HevcPicture, c_idx : Int32) -> Array[Int32] {
  if c_idx == 0 {
    self.y
  } else if c_idx == 1 {
    self.cb
  } else {
    self.cr
  }
}

///|
fn HevcPicture::plane_stride(self : HevcPicture, c_idx : Int32) -> Int32 {
  if c_idx == 0 {
    self.width
  } else {
    (self.width + 1) >> 1
  }
}

///|
fn HevcPicture::sample(
  self : HevcPicture,
  c_idx : Int32,
  x : Int32,
  y : Int32,
) -> Int32 {
  self.plane(c_idx)[y * self.plane_stride(c_idx) + x]
}
