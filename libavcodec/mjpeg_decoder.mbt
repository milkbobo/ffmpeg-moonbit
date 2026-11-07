///|
/// JPEG/MJPEG decoder session. Quantization and Huffman tables survive between
/// successful frames, as in FFmpeg's MJpegDecodeContext. Frame geometry and
/// prediction state are recreated for each image. Use a new session for an
/// unrelated stream; av_mjpeg_decode remains the independent-image entry point.
pub struct MjpegDecoder {
  priv mut quant : Array[Array[Int32]]
  priv mut dc_tables : Array[JpegHuffman?]
  priv mut ac_tables : Array[JpegHuffman?]
}

///|
/// Start with standard Huffman tables and no quantization tables.
pub fn MjpegDecoder::new() -> MjpegDecoder {
  {
    quant: [[], [], [], []],
    dc_tables: [
      Some(jpeg_default_huffman(false, false)),
      Some(jpeg_default_huffman(false, true)),
      None,
      None,
    ],
    ac_tables: [
      Some(jpeg_default_huffman(true, false)),
      Some(jpeg_default_huffman(true, true)),
      None,
      None,
    ],
  }
}

///|
/// Decode a complete JPEG packet, inheriting omitted DQT/DHT definitions from
/// the last successful packet. Invalid packets leave the table state unchanged.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.MjpegDecoder::new()
///   assert_true(decoder.decode(b"not JPEG") is Err(_))
/// }
/// ```
pub fn MjpegDecoder::decode(
  self : MjpegDecoder,
  data : Bytes,
) -> Result[JpegImage, String] {
  // Parsing replaces whole tables; it never mutates a prior table's contents.
  // Copying the table slots makes the commit atomic without copying pixels.
  let quant = self.quant.copy()
  let dc_tables = self.dc_tables.copy()
  let ac_tables = self.ac_tables.copy()
  let image = match
    mjpeg_decode_with_tables(data, quant, dc_tables, ac_tables) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  self.quant = quant
  self.dc_tables = dc_tables
  self.ac_tables = ac_tables
  Ok(image)
}
