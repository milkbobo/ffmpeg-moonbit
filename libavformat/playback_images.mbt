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

///|
fn playback_open_png(
  data : Bytes,
  format_name : String,
) -> MediaFile raise MediaError {
  guard data.length() >= 33 && data[8:16].to_owned() == b"\x00\x00\x00\x0dIHDR" else {
    raise DemuxError("png: missing IHDR")
  }
  let width = pb_be32(data, 16).reinterpret_as_int()
  let height = pb_be32(data, 20).reinterpret_as_int()
  guard width > 0 && height > 0 else {
    raise DemuxError("png: invalid dimensions")
  }
  {
    format_name,
    streams: [
      {
        index: 0,
        media_type: Video,
        codec_id: "png",
        sample_rate: 0,
        channels: 0,
        width,
        height,
        extradata: None,
      },
    ],
    source: StillImage(data),
    cursor: [0],
  }
}

///|
/// Convert a native packed image to RGB24 for display.
pub fn VideoFrame::image_rgb24(self : VideoFrame) -> Bytes? {
  let image = match self.data {
    Png(image) => image
    Mjpeg(image) if image.pix_fmt == "rgb24" => return Some(self.pixel_bytes())
    _ => return None
  }
  if image.pix_fmt == "rgb24" {
    return Some(image.pixels)
  }
  let out : Array[Byte] = []
  for y in 0..<image.height {
    let row = y * image.stride
    for x in 0..<image.width {
      let at = match image.pix_fmt {
        "rgba" => row + x * 4
        "rgb48be" => row + x * 6
        "rgba64be" => row + x * 8
        "gray16be" | "ya8" => row + x * 2
        "ya16be" => row + x * 4
        "monob" => row + x / 8
        _ => row + x
      }
      let (r, g, b) = match image.pix_fmt {
        "rgba" => (image.pixels[at], image.pixels[at + 1], image.pixels[at + 2])
        "rgb48be" | "rgba64be" =>
          (image.pixels[at], image.pixels[at + 2], image.pixels[at + 4])
        "pal8" => {
          let color = image.pixels[at].to_int() * 4
          (
            image.palette[color],
            image.palette[color + 1],
            image.palette[color + 2],
          )
        }
        "monob" => {
          let gray = if (image.pixels[at].to_int() & (128 >> (x % 8))) != 0 {
            b'\xff'
          } else {
            b'\x00'
          }
          (gray, gray, gray)
        }
        _ => (image.pixels[at], image.pixels[at], image.pixels[at])
      }
      out.push(r)
      out.push(g)
      out.push(b)
    }
  }
  Some(Bytes::from_array(out))
}

///|
/// Chroma subsampling shifts of a planar video frame with chroma planes.
pub fn VideoFrame::chroma_shifts(self : VideoFrame) -> (Int32, Int32)? {
  match self.data {
    H264(f) => Some((f.chroma_hshift, f.chroma_vshift))
    Vp9(f) => Some((f.chroma_hshift, f.chroma_vshift))
    Av1(f) if !f.mono => Some((f.ss_h, f.ss_v))
    Hevc(f) if f.pic.cw > 0 && f.pic.ch > 0 =>
      Some(
        (
          if f.pic.cw == f.pic.width {
            0
          } else {
            1
          },
          if f.pic.ch == f.pic.height {
            0
          } else {
            1
          },
        ),
      )
    Mjpeg(f) =>
      match f.pix_fmt {
        "yuvj420p" | "yuv420p" => Some((1, 1))
        "yuvj422p" | "yuv422p" => Some((1, 0))
        "yuvj444p" | "yuv444p" => Some((0, 0))
        _ => None
      }
    _ => None
  }
}
