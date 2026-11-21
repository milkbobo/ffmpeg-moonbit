///|
fn image_argument(
  args : Array[String],
  index : Int32,
  min : Int32,
  max : Int32,
) -> Int32 raise {
  let value = @string.parse_int(args[index]) catch {
    _ => fail("encode-image: expected an integer at argument \{index}")
  }
  guard value >= min && value <= max else {
    fail("encode-image: numeric argument must be in \{min}..\{max}")
  }
  value
}

///|
fn image_frame_size(
  codec : String,
  format : String,
  width : Int32,
  height : Int32,
) -> Int32 raise {
  let pixels = width.to_int64() * height.to_int64()
  let size = match (codec, format) {
    ("mjpeg", "gray") => pixels
    ("mjpeg", "rgb24" | "yuvj444p") => pixels * 3L
    ("mjpeg", "yuvj420p") =>
      pixels + 2L * ((width + 1) / 2).to_int64() * ((height + 1) / 2).to_int64()
    ("png" | "apng", "gray") => pixels
    ("png" | "apng", "gray16be" | "ya8") => pixels * 2L
    ("png" | "apng", "rgb24") => pixels * 3L
    ("png" | "apng", "rgba" | "ya16be") => pixels * 4L
    ("png" | "apng", "rgb48be") => pixels * 6L
    ("png" | "apng", "rgba64be") => pixels * 8L
    _ =>
      fail("encode-image: pixel format is unsupported for the selected codec")
  }
  guard size <= 64000000L else {
    fail("encode-image: frame exceeds the image budget")
  }
  size.to_int()
}

///|
fn image_output(result : Result[Bytes, String]) -> Bytes raise {
  match result {
    Ok(bytes) => bytes
    Err(error) => fail(error)
  }
}

///|
#cfg(target="js")
fn image_args() -> Array[String] {
  // Node prepends its own executable to the script's arguments.
  @env.args()[1:].to_owned()
}

///|
#cfg(not(target="js"))
fn image_args() -> Array[String] {
  @env.args()
}

///|
fn main raise {
  let args = image_args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(
      "usage: encode-image <png|apng|mjpeg> <pixel-format> <width> <height> <input.raw> <output> [fps-or-quality]",
    )
    println("  png: one raw frame")
    println("  apng: packed frames, optional integer FPS (default 12)")
    println(
      "  mjpeg: packed frames, optional JPEG quality 1–100 (default 85)",
    )
    return
  }
  guard args.length() == 7 || args.length() == 8 else {
    fail("encode-image: see --help")
  }
  let codec = args[1]
  let format = args[2]
  let width = image_argument(args, 3, 1, 65535)
  let height = image_argument(args, 4, 1, 65535)
  let frame_size = image_frame_size(codec, format, width, height)
  let data = @fs.read_file_to_bytes(args[5])
  guard data.length() > 0 &&
    data.length() <= 64000000 &&
    data.length() % frame_size == 0 else {
    fail(
      "encode-image: input must contain complete raw frames within the 64 MB budget",
    )
  }
  let output = match codec {
    "png" => {
      guard args.length() == 7 && data.length() == frame_size else {
        fail("encode-image: PNG takes one frame and no extra argument")
      }
      image_output(@codec.av_png_encode(width, height, data, format~))
    }
    "apng" => {
      let fps = if args.length() == 8 {
        image_argument(args, 7, 1, 65535)
      } else {
        12
      }
      let frames : Array[@codec.ApngEncodeFrame] = []
      for offset = 0; offset < data.length(); offset = offset + frame_size {
        frames.push({
          pixels: data[offset:offset + frame_size].to_owned(),
          delay_num: 1,
          delay_den: fps,
        })
      }
      image_output(@codec.av_apng_encode(width, height, frames, format~))
    }
    _ => {
      let quality = if args.length() == 8 {
        image_argument(args, 7, 1, 100)
      } else {
        85
      }
      let stream = []
      for offset = 0; offset < data.length(); offset = offset + frame_size {
        let frame = data[offset:offset + frame_size].to_owned()
        for
          byte in image_output(
            @codec.av_mjpeg_encode(width, height, frame, format~, quality~),
          ) {
          stream.push(byte)
        }
      }
      Bytes::from_array(stream)
    }
  }
  @fs.write_bytes_to_file(args[6], output)
}
