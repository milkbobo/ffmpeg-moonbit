///|
/// Displayed frame output from a VP9 container packet. Planar 8-bit YUV420,
/// tightly packed Y then Cb then Cr with the frame's native subsampling and bit depth.
/// Based on FFmpeg 9.0.2 vp9.c reference/display and superframe semantics.
/// LGPL-2.1-or-later.
pub struct Vp9Frame {
  width : Int32
  height : Int32
  bit_depth : Int32
  chroma_hshift : Int32
  chroma_vshift : Int32
  data : Bytes
}

///|
/// Decode one container packet, splitting a VP9 superframe index when present.
/// Hidden keyframes refresh references without producing output; show-existing
/// packets display the selected snapshot.
/// On error, state from successfully decoded preceding subframes is retained.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.vp9_decoder_new()
///   assert_true(
///     decoder.decode_packet(b"\x88")
///     is Err("vp9: show_existing_frame references an empty slot"),
///   )
/// }
/// ```
pub fn Vp9Decoder::decode_packet(
  self : Vp9Decoder,
  packet : Bytes,
) -> Result[Array[Vp9Frame], String] {
  let split = match vp9_split_superframe(packet) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let frames : Array[Vp9Frame] = []
  for payload in split.frames {
    match self.decode_frame(payload) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    if self.frame_ready {
      let (bit_depth, chroma_hshift, chroma_vshift) = if self.header.show_existing_frame &&
        self.references[self.header.frame_to_show] is Some(reference) {
        (reference.bit_depth, reference.chroma_hshift, reference.chroma_vshift)
      } else {
        (self.bpp, self.ss_h, self.ss_v)
      }
      frames.push({
        width: self.width,
        height: self.height,
        bit_depth,
        chroma_hshift,
        chroma_vshift,
        data: self.frame_bytes(),
      })
    }
  }
  Ok(frames)
}
