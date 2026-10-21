///|
/// AAC channel configuration from FFmpeg 9.0.2 aac/aacdec.c
/// (decode_pce, count_paired_channels, assign_channels, sniff_channel_order)
/// and aac/aacdec_tab.c (ff_aac_channel_layout_map / ff_aac_channel_map).
/// Copyright (c) 2005-2006 Oded Shimon
/// Copyright (c) 2006-2007 Maxim Gavrilov
/// Copyright (c) 2008-2013 Alex Converse <alex.converse@gmail.com>
/// LGPL-2.1-or-later.
///
/// Named base/top/bottom layouts follow FFmpeg's three-layer inference.
/// Ambiguous arrangements that C emits with unspecified channel order
/// are rejected. Default config 7 follows FFmpeg's non-strict
/// 7.1 interpretation. Nonstandard element-tag remapping is not emulated.
pub struct AacLayoutChannel {
  element_type : Int32
  element_tag : Int32
  element_channel : Int32
  /// AVChannel number: FL=0, FR=1, FC=2, LFE=3, BL/BR=4/5,
  /// FLc/FRc=6/7, BC=8, SL/SR=9/10, top=11..17/36..37,
  /// LFE2=35, bottom front=38..40; -1 if unconfigured.
  position : Int32
}

///|
priv struct AacLayoutElement {
  kind : Int32
  tag : Int32
  group : Int32 // front=1, side=2, back=3, LFE=4
}

///|
fn AacLayoutChannel::key(self : AacLayoutChannel) -> Int32 {
  self.element_type * 32 + self.element_tag * 2 + self.element_channel
}

///|
fn aac_layout_from_elements(
  elements : Array[AacLayoutElement],
) -> Result[Array[AacLayoutChannel], String] {
  let layout : Array[AacLayoutChannel] = []
  let seen = Array::make(128, false)
  for element in elements {
    let key = element.kind * 32 + element.tag * 2
    if seen[key] {
      return Err("duplicate PCE channel element")
    }
    seen[key] = true
  }
  let channel_maps = [
    [
      [2, 6, 7, 0, 1, -1],
      [-2, 9, 10, -1, -1, -1],
      [-2, 9, 10, 4, 5, 8],
      [3, 35, -1, -1, -1, -1],
    ],
    [
      [13, -1, -1, 12, 14, -1],
      [-2, 36, 37, -1, -1, 11],
      [-2, -1, -1, 15, 17, 16],
      [-1, -1, -1, -1, -1, -1],
    ],
    [
      [38, -1, -1, 39, 40, -1],
      [-1, -1, -1, -1, -1, -1],
      [-1, -1, -1, -1, -1, -1],
      [-1, -1, -1, -1, -1, -1],
    ],
  ]
  // Match sniff_channel_order: consume contiguous position runs, then
  // advance to the next layer when the group sequence starts again.
  let mut current = 0
  for layer = 0; layer < 3; layer = layer + 1 {
    let channel_map = channel_maps[layer]
    for group = 1; group <= 4; group = group + 1 {
      let row : Array[AacLayoutElement] = []
      let mut count = 0
      let mut first_pair = false
      let mut parity = false
      while current < elements.length() && elements[current].group == group {
        let element = elements[current]
        current = current + 1
        row.push(element)
        if element.kind == 1 {
          if parity {
            if group == 1 && !first_pair {
              parity = false
            } else {
              return Err("unsupported PCE channel arrangement")
            }
          }
          first_pair = true
          count = count + 2
        } else {
          count = count + 1
          if group != 4 {
            parity = !parity
          }
        }
      }
      if parity && group == 1 && first_pair {
        return Err("unsupported PCE channel arrangement")
      }
      if count > 5 || (group == 4 && count > 2) {
        return Err("unsupported PCE channel arrangement")
      }
      let positions : Array[Int32] = []
      if group == 4 {
        for i = 0; i < count; i = i + 1 {
          positions.push(channel_map[3][i])
        }
      } else {
        if (count & 1) != 0 && channel_map[group - 1][0] != -2 {
          positions.push(channel_map[group - 1][0])
          count = count - 1
        }
        let mut index = if group != 2 && count <= 3 { 3 } else { 1 }
        while count >= 2 {
          positions.push(channel_map[group - 1][index])
          positions.push(channel_map[group - 1][index + 1])
          index = index + 2
          count = count - 2
        }
        if count == 1 {
          positions.push(channel_map[group - 1][5])
        }
      }
      let mut next = 0
      for element in row {
        let n = if element.kind == 1 { 2 } else { 1 }
        for ch = 0; ch < n; ch = ch + 1 {
          let position = positions[next]
          if position < 0 {
            return Err("unsupported PCE channel arrangement")
          }
          for existing in layout {
            if existing.position == position {
              return Err("overlapping PCE channel positions")
            }
          }
          layout.push({
            element_type: element.kind,
            element_tag: element.tag,
            element_channel: ch,
            position,
          })
          next = next + 1
        }
      }
    }
  }
  if current != elements.length() {
    return Err("unsupported PCE channel arrangement")
  }
  if layout.length() == 0 {
    return Err("PCE has no audio channels")
  }
  let masks : Array[UInt64] = Array::make(128, 0UL)
  let keys : Array[Int32] = []
  let mut mask = 0UL
  for channel in layout {
    let key = channel.element_type * 32 + channel.element_tag * 2
    let bit = 1UL << channel.position
    masks[key] = masks[key] | bit
    mask = mask | bit
    if channel.element_channel == 0 {
      keys.push(key)
    }
  }
  // sniff_channel_order sorts whole elements by their combined mask,
  // keeping a CPE adjacent even when its center speaker lies between L/R.
  let mut mask_22 = 0UL
  for
    position in [
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 35, 36, 37, 38,
      39, 40,
    ] {
    mask_22 = mask_22 | (1UL << position)
  }
  if mask == mask_22 {
    // FFmpeg's 22.2 special case is an element permutation, not a sort
    // of individual AVChannel numbers. Preserve it for byte-level parity.
    for
      pair in [
        (2, 0),
        (2, 1),
        (6, 2),
        (4, 3),
        (6, 4),
        (7, 6),
        (9, 8),
        (11, 10),
        (12, 11),
      ] {
      let (a, b) = pair
      let saved = keys[a]
      keys[a] = keys[b]
      keys[b] = saved
    }
  } else {
    keys.sort_by((a, b) => masks[a].compare(masks[b]))
  }
  let ordered : Array[AacLayoutChannel] = []
  for key in keys {
    for channel in layout {
      if channel.element_type * 32 + channel.element_tag * 2 == key {
        ordered.push(channel)
      }
    }
  }
  Ok(ordered)
}

///|
fn aac_default_layout(
  config : Int32,
) -> Result[Array[AacLayoutChannel], String] {
  let rows : Array[Array[Int32]] = match config {
    0 => return Ok([])
    1 => [[0, 0, 1]]
    2 => [[1, 0, 1]]
    3 => [[0, 0, 1], [1, 0, 1]]
    4 => [[0, 0, 1], [1, 0, 1], [0, 1, 3]]
    5 => [[0, 0, 1], [1, 0, 1], [1, 1, 3]]
    6 => [[0, 0, 1], [1, 0, 1], [1, 1, 3], [3, 0, 4]]
    7 => [[0, 0, 1], [1, 0, 1], [1, 1, 3], [1, 2, 3], [3, 0, 4]]
    11 => [[0, 0, 1], [1, 0, 1], [1, 1, 3], [0, 1, 3], [3, 0, 4]]
    12 => [[0, 0, 1], [1, 0, 1], [1, 1, 3], [1, 2, 3], [3, 0, 4]]
    13 =>
      [
        [0, 0, 1],
        [1, 0, 1],
        [1, 1, 1],
        [1, 2, 3],
        [1, 3, 3],
        [0, 1, 3],
        [3, 0, 4],
        [3, 1, 4],
        [0, 2, 1],
        [1, 4, 1],
        [1, 5, 2],
        [0, 3, 2],
        [1, 6, 3],
        [0, 4, 3],
        [0, 5, 1],
        [1, 7, 1],
      ]
    14 => [[0, 0, 1], [1, 0, 1], [1, 1, 3], [3, 0, 4], [1, 2, 1]]
    _ => return Err("unsupported AAC channel configuration")
  }
  let elements : Array[AacLayoutElement] = []
  for row in rows {
    elements.push({ kind: row[0], tag: row[1], group: row[2], })
  }
  aac_layout_from_elements(elements)
}

///|
/// Cursor starts at element_instance_tag, after the three-bit PCE id.
/// Alignment is relative to bit zero of the raw block or standalone ASC.
fn aac_decode_pce(
  gb : BitReader,
  coupling_tags~ : Array[Int32] = [],
) -> Result[Array[AacLayoutChannel], String] {
  if gb.bits_left() < 34 {
    return Err("program_config_element overruns the frame")
  }
  gb.skip(4) // instance tag belongs to the PCE, not an audio channel
  gb.skip(6) // object type and sampling index (as in C, retain configured rate)
  let counts = [
    gb.read(4).reinterpret_as_int(),
    gb.read(4).reinterpret_as_int(),
    gb.read(4).reinterpret_as_int(),
    gb.read(2).reinterpret_as_int(),
  ]
  let assoc = gb.read(3).reinterpret_as_int()
  let cc = gb.read(4).reinterpret_as_int()
  if gb.read1() != 0 {
    gb.skip(4)
  }
  if gb.read1() != 0 {
    gb.skip(4)
  }
  if gb.read1() != 0 {
    gb.skip(3)
  }
  let count = counts[0] + counts[1] + counts[2]
  if gb.bits_left() < 5 * (count + cc) + 4 * (counts[3] + assoc + cc) {
    return Err("program_config_element overruns the frame")
  }
  let mut elements : Array[AacLayoutElement] = []
  for group = 1; group <= 4; group = group + 1 {
    for _i = 0; _i < counts[group - 1]; _i = _i + 1 {
      let kind = if group == 4 { 3 } else { gb.read1().reinterpret_as_int() }
      let tag = gb.read(4).reinterpret_as_int()
      elements.push({ kind, tag, group, })
    }
  }
  gb.skip(4 * assoc)
  // Coupling elements do not add output channels. Their independent flag
  // is descriptive; the CCE itself supplies the actual coupling point.
  let seen_coupling = Array::make(16, false)
  for _i = 0; _i < cc; _i = _i + 1 {
    gb.skip(1)
    let tag = gb.read(4).reinterpret_as_int()
    if seen_coupling[tag] {
      return Err("duplicate PCE coupling element")
    }
    seen_coupling[tag] = true
    coupling_tags.push(tag)
  }
  let align = (0 - gb.count()) & 7
  if gb.bits_left() < align + 8 {
    return Err("program_config_element overruns the frame")
  }
  gb.skip(align)
  let comment_bits = gb.read(8).reinterpret_as_int() * 8
  if gb.bits_left() < comment_bits {
    return Err("program_config_element overruns the frame")
  }
  let height_count = counts[0] + counts[1] + counts[2]
  let height_bits = 8 + 2 * height_count
  if comment_bits >= 16 + 2 * height_count && gb.show(8) == 0xacU {
    gb.skip(8)
    let heights = Array::make(elements.length(), 0)
    let mut invalid = false
    let mut elevated = false
    for i = 0; i < height_count; i = i + 1 {
      let height = gb.read(2).reinterpret_as_int()
      heights[i] = height
      if height == 3 {
        invalid = true
      }
      if height == 1 || height == 2 {
        elevated = true
      }
    }
    // FFmpeg consumes reserved height values but retains the original
    // base-layer order when any value is invalid.
    if !invalid {
      if elevated && cc != 0 {
        return Err("height PCE with coupling has no supported named layout")
      }
      let ordered : Array[AacLayoutElement] = []
      for layer = 0; layer < 3; layer = layer + 1 {
        for i = 0; i < elements.length(); i = i + 1 {
          if heights[i] == layer {
            ordered.push(elements[i])
          }
        }
      }
      elements = ordered
    }
    gb.skip(comment_bits - height_bits)
  } else {
    gb.skip(comment_bits)
  }
  aac_layout_from_elements(elements)
}

///|
/// `skip_data_stream_element`, with the instance tag already consumed.
fn aac_skip_data_element(gb : BitReader) -> Result[Unit, String] {
  if gb.bits_left() < 9 {
    return Err("data_stream_element overruns the frame")
  }
  let align = gb.read1() != 0
  let mut count = gb.read(8).reinterpret_as_int()
  if count == 255 {
    if gb.bits_left() < 8 {
      return Err("data_stream_element overruns the frame")
    }
    count = count + gb.read(8).reinterpret_as_int()
  }
  if align {
    gb.skip((0 - gb.count()) & 7)
  }
  if gb.bits_left() < 8 * count {
    return Err("data_stream_element overruns the frame")
  }
  gb.skip(8 * count)
  Ok(())
}
