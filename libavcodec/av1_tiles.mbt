///|
/// Tile payload extraction following FFmpeg 9.0.2 av1dec.c get_tiles_info
/// and cbs_av1_syntax_template.c tile_group_obu. LGPL-2.1-or-later.
/// This prepares bounded entropy payloads; AV1 pixel decoding is not included.
pub struct Av1Tile {
  index : Int32
  row : Int32
  column : Int32
  /// Absolute offset inside the input OBU stream, excluding size prefixes.
  offset : Int32
  data : Bytes
}

///|
/// Entropy payload of this tile.
pub fn Av1Tile::data(self : Av1Tile) -> Bytes {
  self.data
}

///|
/// Extract all tiles of the first frame from consecutive tile groups. Groups
/// must cover the frame once, in order, without gaps or overlaps. The caller
/// supplies the corresponding parsed frame header; show-existing has no tiles.
pub fn av1_extract_tiles(
  data : Bytes,
  header : Av1FrameHeader,
) -> Result[Array[Av1Tile], String] {
  let tiles : Array[Av1Tile] = []
  let mut cursor = 0
  while cursor < data.length() {
    let group = match av1_parse_tile_group(data[cursor:].to_owned(), header) {
      Ok(value) => value
      Err(e) => return Err(e)
    }
    if group.tile_start != tiles.length() {
      return Err("av1: noncontiguous tile groups")
    }
    for i in 0..<group.tile_sizes.length() {
      let index = group.tile_start + i
      let offset = cursor + group.payload_offset + group.tile_offsets[i]
      let size = group.tile_sizes[i]
      tiles.push({
        index,
        row: index / header.tile_cols,
        column: index % header.tile_cols,
        offset,
        data: data[offset:offset + size].to_owned(),
      })
    }
    if tiles.length() == group.num_tiles {
      return Ok(tiles)
    }
    let last = group.tile_sizes.length() - 1
    cursor += group.payload_offset +
      group.tile_offsets[last] +
      group.tile_sizes[last]
  }
  Err("av1: incomplete tile groups")
}
