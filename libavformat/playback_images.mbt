///|
/// Native JPEG/PNG pixel format, or None for other video codecs. These image
/// decoders can emit RGB, grayscale, planar YUV or indexed pixels.
pub fn VideoFrame::image_pixel_format(self : VideoFrame) -> String? {
  match self.data {
    Mjpeg(image) => Some(image.pix_fmt)
    Png(image) => Some(image.pix_fmt)
    _ => None
  }
}

///|
/// Compact decoded pixels. JPEG planes are concatenated in their native order;
/// PNG pixels retain native packing, with the BGRA palette appended for pal8
/// (the FFmpeg rawvideo layout).
/// Other codecs use the planar layout returned by yuv_bytes.
pub fn VideoFrame::pixel_bytes(self : VideoFrame) -> Bytes {
  match self.data {
    Mjpeg(image) => {
      let bytes : Array[Byte] = []
      for plane in image.planes {
        for byte in plane {
          bytes.push(byte)
        }
      }
      Bytes::from_array(bytes)
    }
    Png(image) => {
      let palette : Array[Byte] = []
      for i in 0..<(image.palette.length() / 4) {
        palette.push(image.palette[i * 4 + 2])
        palette.push(image.palette[i * 4 + 1])
        palette.push(image.palette[i * 4])
        palette.push(image.palette[i * 4 + 3])
      }
      image.pixels + Bytes::from_array(palette)
    }
    _ => self.yuv_bytes()
  }
}
