///|
/// MoonBit port of the VP9 uncompressed frame header from FFmpeg 9.0.2
/// `libavcodec/vp9.c` (`decode_frame_header`, `read_colorspace_details`) for
/// keyframes and intra-only frames.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: frame marker/profile, show-existing-frame, keyframe/intra-only flags,
/// sync code, colour configuration (profile 0..3, 8/10/12-bit, chroma
/// subsampling), frame and render dimensions, and the refresh mask. Inter
/// frames report their refresh mask and reference indices but stop before the
/// reference-size prediction (which needs the DPB). The compressed header,
/// bool decoder, loop filter/quantization/segmentation/tile parsing and pixel
/// decode are out of scope.

///|
pub struct Vp9FrameHeader {
  mut profile : Int32
  mut keyframe : Bool
  mut show_existing_frame : Bool
  /// 0-based index when `show_existing_frame` is set, else -1.
  mut frame_to_show : Int32
  mut show_frame : Bool
  mut error_resilient : Bool
  mut intra_only : Bool
  mut bit_depth : Int32
  mut color_space : Int32
  mut color_range : Int32
  mut chroma_subsampling_x : Bool
  mut chroma_subsampling_y : Bool
  mut width : Int32
  mut height : Int32
  mut render_width : Int32
  mut render_height : Int32
  mut refresh_frame_flags : Int32
  ref_indices : Array[Int32]
}

///|
let vp9_sync_code : Int32 = 0x498342

///|
/// `read_colorspace_details`. */
fn vp9_read_colorspace_details(br : BitReader, h : Vp9FrameHeader) -> Bool {
  let mut bits = 0
  if h.profile >= 2 {
    bits = 1 + br.read(1).to_int()
  }
  h.bit_depth = match bits {
    0 => 8
    1 => 10
    2 => 12
    _ => 8
  }
  h.color_space = br.read(3).to_int()
  if h.color_space != 7 {
    // not RGB
    h.color_range = br.read(1).to_int()
    if h.profile == 1 || h.profile == 3 {
      h.chroma_subsampling_x = br.read(1) != 0
      h.chroma_subsampling_y = br.read(1) != 0
      if h.bit_depth == 8 && h.chroma_subsampling_x && h.chroma_subsampling_y {
        // 8-bit 4:2:0 is not allowed in profiles 1/3.
        return false
      }
      if br.read(1) != 0 {
        // Reserved bit must be zero.
        return false
      }
    } else {
      h.chroma_subsampling_x = true
      h.chroma_subsampling_y = true
    }
  } else {
    h.color_range = 1
    h.chroma_subsampling_x = false
    h.chroma_subsampling_y = false
  }
  true
}

///|
/// Parse a VP9 uncompressed header (the start of every frame packet).
pub fn vp9_parse_frame_header(data : Bytes) -> Result[Vp9FrameHeader, String] {
  if data.length() < 1 {
    return Err("vp9: empty frame")
  }
  let br = BitReader::new(data)
  if br.read(2) != 2U {
    return Err("vp9: invalid frame marker")
  }
  let h : Vp9FrameHeader = {
    profile: 0,
    keyframe: false,
    show_existing_frame: false,
    frame_to_show: -1,
    show_frame: true,
    error_resilient: false,
    intra_only: false,
    bit_depth: 8,
    color_space: 0,
    color_range: 0,
    chroma_subsampling_x: true,
    chroma_subsampling_y: true,
    width: 0,
    height: 0,
    render_width: 0,
    render_height: 0,
    refresh_frame_flags: 0,
    ref_indices: [],
  }
  h.profile = br.read(1).to_int() | (br.read(1).to_int() << 1)
  if h.profile == 3 {
    h.profile = h.profile + br.read(1).to_int()
  }
  if h.profile > 3 {
    return Err("vp9: unsupported profile")
  }
  if br.read(1) != 0 {
    h.show_existing_frame = true
    h.frame_to_show = br.read(3).to_int()
    return Ok(h)
  }
  h.keyframe = br.read(1) == 0
  h.show_frame = br.read(1) != 0
  h.error_resilient = br.read(1) != 0
  if h.keyframe {
    if br.read(24).to_int() != vp9_sync_code {
      return Err("vp9: invalid sync code")
    }
    if !vp9_read_colorspace_details(br, h) {
      return Err("vp9: reserved profile colour bit")
    }
    h.refresh_frame_flags = 0xFF
    h.width = br.read(16).to_int() + 1
    h.height = br.read(16).to_int() + 1
    if br.read(1) != 0 {
      h.render_width = br.read(16).to_int() + 1
      h.render_height = br.read(16).to_int() + 1
    }
    return Ok(h)
  }
  if !h.show_frame {
    h.intra_only = br.read(1) != 0
  }
  if h.intra_only {
    if br.read(24).to_int() != vp9_sync_code {
      return Err("vp9: invalid sync code")
    }
    if h.profile >= 1 {
      if !vp9_read_colorspace_details(br, h) {
        return Err("vp9: reserved profile colour bit")
      }
    }
    h.refresh_frame_flags = br.read(8).to_int()
    h.width = br.read(16).to_int() + 1
    h.height = br.read(16).to_int() + 1
    if br.read(1) != 0 {
      h.render_width = br.read(16).to_int() + 1
      h.render_height = br.read(16).to_int() + 1
    }
    return Ok(h)
  }
  // Inter frame: refresh mask and the three reference slots. Sizes are
  // predicted from the DPB in the C and are not resolved in this header slice.
  h.refresh_frame_flags = br.read(8).to_int()
  for _ in 0..<3 {
    h.ref_indices.push(br.read(3).to_int())
    ignore(br.read(1)) // sign_bias
  }
  Ok(h)
}
