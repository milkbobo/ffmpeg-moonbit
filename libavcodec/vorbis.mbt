///|
/// Vorbis I decoder (audio packets), ported from FFmpeg 9.0.2
/// `libavcodec/vorbisdec.c`, the shared helpers in `vorbis.c`
/// (`ff_vorbis_len2vlc`, floor1 rendering) and the two data tables from
/// `vorbis_data.c` (generated into `vorbis_tables.mbt`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: identification/setup headers, codebooks (VQ lookup type 1, lookups
/// 0/1), floor types 0 and 1, residue types 0/1/2, channel coupling, all
/// Vorbis modes, and overlap-add synthesis. The C uses an FFT based MDCT;
/// this port evaluates the inverse MDCT directly with a cosine recurrence
/// (exact, O(N^2); fine for test-sized inputs, a later optimisation target).
/// Output is planar doubles; `decode_stream` applies the decoder's first-frame
/// skip and the Vorbis-to-native channel order used by FFmpeg.

///|
/// Little-endian bit reader: Vorbis packs the first bit into the least
/// significant bit of the first byte (`BITSTREAM_READER_LE`).
pub struct VorbisBits {
  data : Bytes
  mut pos : Int32
}

///|
fn vorbis_bits_new(data : Bytes) -> VorbisBits {
  { data, pos: 0, }
}

///|
fn VorbisBits::left(self : VorbisBits) -> Int32 {
  self.data.length() * 8 - self.pos
}

///|
fn VorbisBits::read(self : VorbisBits, n : Int32) -> Int32 {
  let mut v = 0
  for i = 0; i < n; i = i + 1 {
    let bit = self.pos + i
    if bit < self.data.length() * 8 {
      let b = (self.data[bit / 8].to_int() >> (bit % 8)) & 1
      v = v | (b << i)
    }
  }
  self.pos = self.pos + n
  v
}

///|
fn VorbisBits::read1(self : VorbisBits) -> Int32 {
  self.read(1)
}

///|
fn VorbisBits::read64(self : VorbisBits, n : Int32) -> Int64 {
  let lo = self
    .read(if n > 32 { 32 } else { n })
    .reinterpret_as_uint()
    .to_int64()
  if n <= 32 {
    return lo
  }
  let hi = self.read(n - 32).reinterpret_as_uint().to_int64()
  (hi << 32) | lo
}

///|
fn VorbisBits::skip(self : VorbisBits, n : Int32) -> Unit {
  self.pos = self.pos + n
}

///|
/// `ilog(x)`: number of bits needed to express `x`. */
fn vorbis_ilog(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 0 {
    n = n + 1
    x = x >> 1
  }
  n
}

///|
fn vorbis_clip_uint8(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
fn vorbis_finite(v : Double) -> Bool {
  let a = if v < 0.0 { -v } else { v }
  v == v && a <= 1.7976931348623157e308
}

///|
/// `vorbisfloat2float`: 21-bit mantissa, 10-bit exponent, sign bit. */
fn vorbis_float2float(val : Int32) -> Double {
  let mant = (val & 0x1FFFFF).to_double()
  let exp = (val & 0x7FE00000) >> 21
  let m = if val < 0 { -mant } else { mant }
  m * @math.pow(2.0, (exp - 20 - 768).to_double())
}

///|
/// `ff_vorbis_nth_root`: floor(x^(1/n)) by integer search. */
fn vorbis_nth_root(x : Int32, n : Int32) -> Int32 {
  let mut ret = 0
  while true {
    ret = ret + 1
    let mut j = ret
    for i = 1; i < n; i = i + 1 {
      j = j * ret
    }
    if j > x {
      break
    }
  }
  ret - 1
}

///|
/// `ff_vorbis_len2vlc`: canonical codes from code lengths in Vorbis
/// (least-significant-bit first) order. */
fn vorbis_len2vlc(
  bits : Array[Int32],
  codes : Array[Int64],
  num : Int32,
) -> Result[Unit, String] {
  let exit_at_level : Array[Int64] = Array::make(33, 0L)
  let mut p = 0
  while p < num && bits[p] == 0 {
    p = p + 1
  }
  if p == num {
    return Ok(())
  }
  codes[p] = 0L
  if bits[p] > 32 {
    return Err("vorbis: code length above 32")
  }
  for i = 0; i < bits[p]; i = i + 1 {
    exit_at_level[i + 1] = 1L << i
  }
  p = p + 1
  let mut i = p
  while i < num && bits[i] == 0 {
    i = i + 1
  }
  if i == num {
    return Ok(())
  }
  while p < num {
    if bits[p] > 32 {
      return Err("vorbis: code length above 32")
    }
    if bits[p] == 0 {
      p = p + 1
      continue
    }
    let mut level = bits[p]
    while level > 0 && exit_at_level[level] == 0L {
      level = level - 1
    }
    if level == 0 {
      return Err("vorbis: overspecified Huffman tree")
    }
    let code = exit_at_level[level]
    exit_at_level[level] = 0L
    for j = level + 1; j <= bits[p]; j = j + 1 {
      exit_at_level[j] = code + (1L << (j - 1))
    }
    codes[p] = code
    p = p + 1
  }
  for j = 1; j < 33; j = j + 1 {
    if exit_at_level[j] != 0L {
      return Err("vorbis: underspecified Huffman tree")
    }
  }
  Ok(())
}

///|
/// One parsed codebook. Canonical codes are decoded bit by bit (LSB first)
/// through `decode_map`, keyed by `(length << 32) | code`.
pub struct VorbisCodebook {
  dimensions : Int32
  maxlen : Int32
  decode_map : Map[Int64, Int32]
  codevectors : Array[Double]
}

///|
fn VorbisCodebook::decode(
  self : VorbisCodebook,
  gb : VorbisBits,
) -> Result[Int32, String] {
  let mut code = 0L
  let mut len = 0
  while len < self.maxlen {
    let bit = gb.read1().to_int64()
    code = code | (bit << len)
    len = len + 1
    match self.decode_map.get((len.to_int64() << 32) | code) {
      Some(sym) => return Ok(sym)
      None => ()
    }
  }
  Err("vorbis: invalid Huffman code")
}

///|
fn vorbis_parse_codebooks(
  gb : VorbisBits,
) -> Result[Array[VorbisCodebook], String] {
  let count = gb.read(8) + 1
  let books : Array[VorbisCodebook] = []
  for cb = 0; cb < count; cb = cb + 1 {
    if gb.read(24) != 0x564342 {
      return Err("vorbis: bad codebook sync")
    }
    let dimensions = gb.read(16)
    if dimensions > 16 || dimensions == 0 {
      return Err("vorbis: invalid codebook dimension \{dimensions}")
    }
    let entries = gb.read(24)
    if entries > 65536 {
      return Err("vorbis: codebook has too many entries")
    }
    if entries == 0 {
      return Err("vorbis: empty codebook")
    }
    let ordered = gb.read1() == 1
    let mut lengths = Array::make(entries, 0)
    if !ordered {
      let sparse = gb.read1() == 1
      if sparse {
        for ce = 0; ce < entries; ce = ce + 1 {
          if gb.read1() == 1 {
            lengths[ce] = gb.read(5) + 1
          }
        }
      } else {
        for ce = 0; ce < entries; ce = ce + 1 {
          lengths[ce] = gb.read(5) + 1
        }
      }
    } else {
      let mut current_entry = 0
      let mut current_length = gb.read(5) + 1
      while current_entry < entries && current_length <= 32 {
        let number = gb.read(vorbis_ilog(entries - current_entry))
        for i = current_entry; i < number + current_entry; i = i + 1 {
          if i < entries {
            lengths[i] = current_length
          }
        }
        current_entry = current_entry + number
        current_length = current_length + 1
      }
      if current_entry > entries {
        return Err("vorbis: too many code lengths")
      }
    }
    let lookup_type = gb.read(4)
    let mut used = entries
    let mut codevectors : Array[Double] = []
    if lookup_type == 1 {
      let lookup_values = vorbis_nth_root(entries, dimensions)
      if lookup_values <= 0 {
        return Err("vorbis: invalid codebook lookup")
      }
      let minimum = vorbis_float2float(gb.read(32))
      let delta = vorbis_float2float(gb.read(32))
      let value_bits = gb.read(4) + 1
      let sequence_p = gb.read1() == 1
      if !vorbis_finite(minimum) || !vorbis_finite(delta) {
        return Err("vorbis: non-finite codebook value")
      }
      let multiplicands : Array[Int32] = Array::make(lookup_values, 0)
      for i = 0; i < lookup_values; i = i + 1 {
        multiplicands[i] = gb.read(value_bits)
      }
      used = 0
      for i = 0; i < entries; i = i + 1 {
        if lengths[i] > 0 {
          used = used + 1
        }
      }
      codevectors = Array::make(used * dimensions, 0.0)
      let compact : Array[Int32] = Array::make(used, 0)
      let mut j = 0
      for i = 0; i < entries; i = i + 1 {
        if lengths[i] > 0 {
          let mut last = 0.0
          let mut offset = i
          for k = 0; k < dimensions; k = k + 1 {
            let mi = offset % lookup_values
            let v = multiplicands[mi].to_double() * delta + minimum + last
            codevectors[j * dimensions + k] = v
            if sequence_p {
              last = v
            }
            offset = offset / lookup_values
          }
          compact[j] = lengths[i]
          j = j + 1
        }
      }
      lengths = compact
    } else if lookup_type >= 2 {
      return Err("vorbis: unsupported codebook lookup type \{lookup_type}")
    }
    let codes : Array[Int64] = Array::make(used, 0L)
    match vorbis_len2vlc(lengths, codes, used) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let decode_map : Map[Int64, Int32] = Map([])
    let mut maxlen = 0
    for s = 0; s < used; s = s + 1 {
      let len = lengths[s]
      if len > maxlen {
        maxlen = len
      }
      if len > 0 {
        decode_map[(len.to_int64() << 32) | codes[s]] = s
      }
    }
    books.push({ dimensions, maxlen, decode_map, codevectors, })
  }
  Ok(books)
}

///|
/// One floor1 entry: `x` coordinate plus the neighbours and sort order
/// computed by `ff_vorbis_ready_floor1_list`.
pub struct VorbisFloor1Entry {
  mut x : Int32
  mut sort : Int32
  mut low : Int32
  mut high : Int32
}

///|
pub struct VorbisFloor1 {
  partitions : Int32
  partition_class : Array[Int32]
  class_dimensions : Array[Int32]
  class_subclasses : Array[Int32]
  class_masterbook : Array[Int32]
  subclass_books : Array[Array[Int32]]
  multiplier : Int32
  list : Array[VorbisFloor1Entry]
}

///|
pub struct VorbisFloor0 {
  order : Int32
  rate : Int32
  bark_map_size : Int32
  amplitude_bits : Int32
  amplitude_offset : Int32
  book_list : Array[Int32]
  map : Array[Array[Int32]]
  map_size : Array[Int32]
  lsp : Array[Double]
}

///|
pub enum VorbisFloor {
  Floor0(VorbisFloor0)
  Floor1(VorbisFloor1)
}

///|
/// `BARK(x)` of `vorbisdec.c`: the Bark scale approximation used by floor 0. */
fn vorbis_bark(x : Double) -> Double {
  13.1 * @math.atan(0.00074 * x) +
  2.24 * @math.atan(1.85e-8 * x * x) +
  0.0001 * x
}

///|
fn vorbis_create_map(
  f0 : VorbisFloor0,
  blocksize0 : Int32,
  blocksize1 : Int32,
) -> Unit {
  for blockflag = 0; blockflag < 2; blockflag = blockflag + 1 {
    let blocksize = if blockflag == 0 { blocksize0 } else { blocksize1 }
    let n = blocksize / 2
    let map : Array[Int32] = Array::make(n + 1, 0)
    let scale = f0.bark_map_size.to_double() /
      vorbis_bark(f0.rate.to_double() / 2.0)
    for idx = 0; idx < n; idx = idx + 1 {
      let mut v = @math.floor(
        vorbis_bark(
          f0.rate.to_double() * idx.to_double() / (2.0 * n.to_double()),
        ) *
        scale,
      ).to_int()
      if f0.bark_map_size - 1 < v {
        v = f0.bark_map_size - 1
      }
      map[idx] = v
    }
    map[n] = -1
    f0.map[blockflag] = map
    f0.map_size[blockflag] = n
  }
}

///|
/// `ff_vorbis_ready_floor1_list`: neighbour and sort order of floor1 points. */
fn vorbis_ready_floor1_list(
  list : Array[VorbisFloor1Entry],
) -> Result[Unit, String] {
  let values = list.length()
  list[0].sort = 0
  list[1].sort = 1
  for i = 2; i < values; i = i + 1 {
    list[i].low = 0
    list[i].high = 1
    list[i].sort = i
    for j = 2; j < i; j = j + 1 {
      let tmp = list[j].x
      if tmp < list[i].x {
        if tmp > list[list[i].low].x {
          list[i].low = j
        }
      } else if tmp < list[list[i].high].x {
        list[i].high = j
      }
    }
  }
  for i = 0; i < values - 1; i = i + 1 {
    for j = i + 1; j < values; j = j + 1 {
      if list[i].x == list[j].x {
        return Err("vorbis: duplicate floor1 X coordinate")
      }
      if list[list[i].sort].x > list[list[j].sort].x {
        let tmp = list[i].sort
        list[i].sort = list[j].sort
        list[j].sort = tmp
      }
    }
  }
  Ok(())
}

///|
fn vorbis_parse_floors(
  gb : VorbisBits,
  codebooks : Array[VorbisCodebook],
  blocksize0 : Int32,
  blocksize1 : Int32,
) -> Result[Array[VorbisFloor], String] {
  let codebook_count = codebooks.length()
  let count = gb.read(6) + 1
  let floors : Array[VorbisFloor] = []
  for _fi = 0; _fi < count; _fi = _fi + 1 {
    let kind = gb.read(16)
    if kind == 1 {
      let partitions = gb.read(5)
      let partition_class : Array[Int32] = Array::make(32, 0)
      let mut maximum_class = -1
      for j = 0; j < partitions; j = j + 1 {
        partition_class[j] = gb.read(4)
        if partition_class[j] > maximum_class {
          maximum_class = partition_class[j]
        }
      }
      let class_dimensions : Array[Int32] = Array::make(16, 0)
      let class_subclasses : Array[Int32] = Array::make(16, 0)
      let class_masterbook : Array[Int32] = Array::make(16, 0)
      let subclass_books : Array[Array[Int32]] = Array::make(16, [])
      for j in 0..<16 {
        subclass_books[j] = Array::make(8, 0)
      }
      for j = 0; j <= maximum_class; j = j + 1 {
        class_dimensions[j] = gb.read(3) + 1
        class_subclasses[j] = gb.read(2)
        if class_subclasses[j] != 0 {
          let book = gb.read(8)
          if book >= codebook_count {
            return Err("vorbis: floor1 masterbook out of range")
          }
          class_masterbook[j] = book
        }
        for k = 0; k < 1 << class_subclasses[j]; k = k + 1 {
          let bits = gb.read(8) - 1
          if bits != -1 && bits >= codebook_count {
            return Err("vorbis: floor1 subclass book out of range")
          }
          subclass_books[j][k] = bits
        }
      }
      let multiplier = gb.read(2) + 1
      let mut x_list_dim = 2
      for j = 0; j < partitions; j = j + 1 {
        x_list_dim = x_list_dim + class_dimensions[partition_class[j]]
      }
      let list : Array[VorbisFloor1Entry] = []
      for _e in 0..<x_list_dim {
        list.push({ x: 0, sort: 0, low: 0, high: 0, })
      }
      let rangebits = gb.read(4)
      if rangebits == 0 && partitions != 0 {
        return Err("vorbis: floor1 rangebits is 0")
      }
      let rangemax = 1 << rangebits
      if rangemax > blocksize1 / 2 {
        return Err("vorbis: floor1 range too large for block size")
      }
      list[0].x = 0
      list[1].x = rangemax
      let mut pos = 2
      for j = 0; j < partitions; j = j + 1 {
        for _k = 0; _k < class_dimensions[partition_class[j]]; _k = _k + 1 {
          list[pos].x = gb.read(rangebits)
          pos = pos + 1
        }
      }
      match vorbis_ready_floor1_list(list) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      floors.push(
        Floor1({
          partitions,
          partition_class,
          class_dimensions,
          class_subclasses,
          class_masterbook,
          subclass_books,
          multiplier,
          list,
        }),
      )
    } else if kind == 0 {
      let order = gb.read(8)
      if order == 0 {
        return Err("vorbis: floor0 order is 0")
      }
      let rate = gb.read(16)
      if rate == 0 {
        return Err("vorbis: floor0 rate is 0")
      }
      let bark_map_size = gb.read(16)
      if bark_map_size == 0 {
        return Err("vorbis: floor0 bark map size is 0")
      }
      let amplitude_bits = gb.read(6)
      let amplitude_offset = gb.read(8)
      let num_books = gb.read(4) + 1
      let book_list : Array[Int32] = Array::make(num_books, 0)
      let mut max_codebook_dim = 0
      for idx = 0; idx < num_books; idx = idx + 1 {
        let book = gb.read(8)
        if book >= codebook_count {
          return Err("vorbis: floor0 book out of range")
        }
        book_list[idx] = book
        let dim = codebooks[book].dimensions
        if dim > max_codebook_dim {
          max_codebook_dim = dim
        }
      }
      let f0 : VorbisFloor0 = {
        order,
        rate,
        bark_map_size,
        amplitude_bits,
        amplitude_offset,
        book_list,
        map: [Array::make(0, 0), Array::make(0, 0)],
        map_size: [-1, -1],
        lsp: Array::make(order + 1 + max_codebook_dim, 0.0),
      }
      vorbis_create_map(f0, blocksize0, blocksize1)
      floors.push(Floor0(f0))
    } else {
      return Err("vorbis: invalid floor type \{kind}")
    }
  }
  Ok(floors)
}

///|
pub struct VorbisResidue {
  kind : Int32
  begin : Int32
  end : Int32
  partition_size : Int32
  classifications : Int32
  classbook : Int32
  books : Array[Array[Int32]]
  maxpass : Int32
  ptns_to_read : Int32
  classifs : Array[Int32]
}

///|
fn vorbis_parse_residues(
  gb : VorbisBits,
  codebook_count : Int32,
  channels : Int32,
) -> Result[Array[VorbisResidue], String] {
  let count = gb.read(6) + 1
  let residues : Array[VorbisResidue] = []
  for _ri = 0; _ri < count; _ri = _ri + 1 {
    let kind = gb.read(16)
    let begin = gb.read(24)
    let end = gb.read(24)
    let partition_size = gb.read(24) + 1
    if begin > end || (end - begin) / partition_size > 65535 {
      return Err("vorbis: residue partition out of bounds")
    }
    let classifications = gb.read(6) + 1
    let classbook = gb.read(8)
    if classbook >= codebook_count {
      return Err("vorbis: residue classbook out of range")
    }
    let ptns_to_read = (end - begin) / partition_size
    let classifs : Array[Int32] = Array::make(ptns_to_read * channels, 0)
    let cascade : Array[Int32] = Array::make(classifications, 0)
    for j = 0; j < classifications; j = j + 1 {
      let low = gb.read(3)
      let mut high = 0
      if gb.read1() == 1 {
        high = gb.read(5)
      }
      cascade[j] = (high << 3) + low
    }
    let books : Array[Array[Int32]] = Array::make(classifications, [])
    for j in 0..<classifications {
      books[j] = Array::make(8, -1)
    }
    let mut maxpass = 0
    for j = 0; j < classifications; j = j + 1 {
      for k = 0; k < 8; k = k + 1 {
        if (cascade[j] & (1 << k)) != 0 {
          let book = gb.read(8)
          if book >= codebook_count {
            return Err("vorbis: residue book out of range")
          }
          books[j][k] = book
          if k > maxpass {
            maxpass = k
          }
        }
      }
    }
    residues.push({
      kind,
      begin,
      end,
      partition_size,
      classifications,
      classbook,
      books,
      maxpass,
      ptns_to_read,
      classifs,
    })
  }
  Ok(residues)
}

///|
pub struct VorbisMapping {
  submaps : Int32
  coupling_steps : Int32
  magnitude : Array[Int32]
  angle : Array[Int32]
  mux : Array[Int32]
  submap_floor : Array[Int32]
  submap_residue : Array[Int32]
}

///|
fn vorbis_parse_mappings(
  gb : VorbisBits,
  channels : Int32,
  floor_count : Int32,
  residue_count : Int32,
) -> Result[Array[VorbisMapping], String] {
  let count = gb.read(6) + 1
  let mappings : Array[VorbisMapping] = []
  for _mi = 0; _mi < count; _mi = _mi + 1 {
    if gb.read(16) != 0 {
      return Err("vorbis: unsupported mapping type")
    }
    let submaps = if gb.read1() == 1 { gb.read(4) + 1 } else { 1 }
    let coupon = gb.read1() == 1
    let mut coupling_steps = 0
    let magnitude : Array[Int32] = Array::make(256, 0)
    let angle : Array[Int32] = Array::make(256, 0)
    if coupon {
      coupling_steps = gb.read(8) + 1
      if channels < 2 {
        return Err("vorbis: coupling with less than two channels")
      }
      for j = 0; j < coupling_steps; j = j + 1 {
        let m = gb.read(vorbis_ilog(channels - 1))
        if m >= channels {
          return Err("vorbis: coupling magnitude out of range")
        }
        let a = gb.read(vorbis_ilog(channels - 1))
        if a >= channels {
          return Err("vorbis: coupling angle out of range")
        }
        magnitude[j] = m
        angle[j] = a
      }
    }
    if gb.read(2) != 0 {
      return Err("vorbis: mapping reserved bits are set")
    }
    let mux : Array[Int32] = Array::make(channels, 0)
    if submaps > 1 {
      for j = 0; j < channels; j = j + 1 {
        mux[j] = gb.read(4)
      }
    }
    let submap_floor : Array[Int32] = Array::make(16, 0)
    let submap_residue : Array[Int32] = Array::make(16, 0)
    for j = 0; j < submaps; j = j + 1 {
      gb.skip(8)
      let fl = gb.read(8)
      if fl >= floor_count {
        return Err("vorbis: submap floor out of range")
      }
      let res = gb.read(8)
      if res >= residue_count {
        return Err("vorbis: submap residue out of range")
      }
      submap_floor[j] = fl
      submap_residue[j] = res
    }
    mappings.push({
      submaps,
      coupling_steps,
      magnitude,
      angle,
      mux,
      submap_floor,
      submap_residue,
    })
  }
  Ok(mappings)
}

///|
pub struct VorbisMode {
  blockflag : Int32
  windowtype : Int32
  transformtype : Int32
  mapping : Int32
}

///|
fn vorbis_parse_modes(
  gb : VorbisBits,
  mapping_count : Int32,
) -> Result[Array[VorbisMode], String] {
  let count = gb.read(6) + 1
  let modes : Array[VorbisMode] = []
  for _i = 0; _i < count; _i = _i + 1 {
    let blockflag = gb.read1()
    let windowtype = gb.read(16)
    let transformtype = gb.read(16)
    let mapping = gb.read(8)
    if mapping >= mapping_count {
      return Err("vorbis: mode mapping out of range")
    }
    modes.push({ blockflag, windowtype, transformtype, mapping, })
  }
  Ok(modes)
}

///|
/// Vorbis decoder state: parsed headers plus the overlap history and the
/// previous block size used for the next packet's window.
pub struct VorbisDecoder {
  channels : Int32
  sample_rate : Int32
  block_bits : Array[Int32]
  blocksize : Array[Int32]
  codebooks : Array[VorbisCodebook]
  floors : Array[VorbisFloor]
  residues : Array[VorbisResidue]
  mappings : Array[VorbisMapping]
  modes : Array[VorbisMode]
  channel_offsets : Array[Int32]
  saved : Array[Array[Double]]
  mut previous_window : Int32
}

///|
/// Vorbis channel order -> FFmpeg native order (`ff_vorbis_channel_layout_offsets`).
fn vorbis_channel_offsets(channels : Int32) -> Array[Int32] {
  match channels {
    1 => [0]
    2 => [0, 1]
    3 => [0, 2, 1]
    4 => [0, 1, 2, 3]
    5 => [0, 2, 1, 3, 4]
    6 => [0, 2, 1, 5, 3, 4]
    7 => [0, 2, 1, 6, 5, 3, 4]
    8 => [0, 2, 1, 7, 5, 6, 3, 4]
    _ => {
      let out : Array[Int32] = []
      for i = 0; i < channels; i = i + 1 {
        out.push(i)
      }
      out
    }
  }
}

///|
/// Parse the identification and setup header packets (each including its
/// one-byte packet type and `"vorbis"` signature).
pub fn vorbis_decoder_new(
  id_header : Bytes,
  setup_header : Bytes,
) -> Result[VorbisDecoder, String] {
  let id = vorbis_bits_new(id_header)
  if id.read(8) != 1 {
    return Err("vorbis: first header is not the id header")
  }
  let signature : Bytes = b"vorbis"
  for i = 0; i < 6; i = i + 1 {
    if id.read(8) != signature[i].to_int() {
      return Err("vorbis: bad id header signature")
    }
  }
  let _version = id.read(32)
  let channels = id.read(8)
  if channels <= 0 {
    return Err("vorbis: invalid channel count")
  }
  let sample_rate = id.read(32)
  if sample_rate <= 0 {
    return Err("vorbis: invalid sample rate")
  }
  let _bitrate_max = id.read(32)
  let _bitrate_nom = id.read(32)
  let _bitrate_min = id.read(32)
  let bl0 = id.read(4)
  let bl1 = id.read(4)
  if bl0 > 13 || bl0 < 6 || bl1 > 13 || bl1 < 6 || bl1 < bl0 {
    return Err("vorbis: illegal block size")
  }
  if id.read1() != 1 {
    return Err("vorbis: id header framing bit not set")
  }
  let block_bits : Array[Int32] = [bl0, bl1]
  let blocksize : Array[Int32] = [1 << bl0, 1 << bl1]
  let s = vorbis_bits_new(setup_header)
  if s.read(8) != 5 {
    return Err("vorbis: third header is not the setup header")
  }
  for i = 0; i < 6; i = i + 1 {
    if s.read(8) != signature[i].to_int() {
      return Err("vorbis: bad setup header signature")
    }
  }
  let codebooks = match vorbis_parse_codebooks(s) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let time_count = s.read(6) + 1
  for _i = 0; _i < time_count; _i = _i + 1 {
    if s.read(16) != 0 {
      return Err("vorbis: non-zero time domain transform")
    }
  }
  let floors = match
    vorbis_parse_floors(s, codebooks, blocksize[0], blocksize[1]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let residues = match vorbis_parse_residues(s, codebooks.length(), channels) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mappings = match
    vorbis_parse_mappings(s, channels, floors.length(), residues.length()) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let modes = match vorbis_parse_modes(s, mappings.length()) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if s.read1() != 1 {
    return Err("vorbis: setup header framing bit not set")
  }
  let saved : Array[Array[Double]] = []
  for _i in 0..<channels {
    saved.push(Array::make(blocksize[1] / 4, 0.0))
  }
  Ok({
    channels,
    sample_rate,
    block_bits,
    blocksize,
    codebooks,
    floors,
    residues,
    mappings,
    modes,
    channel_offsets: vorbis_channel_offsets(channels),
    saved,
    previous_window: -1,
  })
}

///|
fn vorbis_floor0_decode(
  floor : VorbisFloor0,
  codebooks : Array[VorbisCodebook],
  gb : VorbisBits,
  blockflag : Int32,
  vec : Array[Double],
) -> Result[Int32, String] {
  if floor.amplitude_bits == 0 {
    return Ok(1)
  }
  let amplitude = gb.read64(floor.amplitude_bits)
  if amplitude == 0L {
    return Ok(1)
  }
  let lsp = floor.lsp
  let mut lsp_len = 0
  let book_idx = gb.read(vorbis_ilog(floor.book_list.length()))
  if book_idx >= floor.book_list.length() {
    return Err("vorbis: floor0 book number too high")
  }
  let codebook = codebooks[floor.book_list[book_idx]]
  if codebook.codevectors.length() == 0 {
    return Err("vorbis: floor0 codebook has no vectors")
  }
  let mut last = 0.0
  while lsp_len < floor.order {
    let vec_off = match codebook.decode(gb) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let base = vec_off * codebook.dimensions
    for idx = 0; idx < codebook.dimensions; idx = idx + 1 {
      let v = codebook.codevectors[base + idx] + last
      lsp[lsp_len + idx] = v
    }
    last = lsp[lsp_len + codebook.dimensions - 1]
    lsp_len = lsp_len + codebook.dimensions
  }
  for i = 0; i < floor.order; i = i + 1 {
    lsp[i] = 2.0 * @math.cos(lsp[i])
  }
  let map = floor.map[blockflag]
  let map_size = floor.map_size[blockflag]
  let wstep = 3.14159265358979323846 / floor.bark_map_size.to_double()
  let mut i = 0
  while i < map_size {
    let iter_cond = map[i]
    let mut p = 0.5
    let mut q = 0.5
    let two_cos_w = 2.0 * @math.cos(wstep * iter_cond.to_double())
    let mut j = 0
    while j + 1 < floor.order {
      q = q * (lsp[j] - two_cos_w)
      p = p * (lsp[j + 1] - two_cos_w)
      j = j + 2
    }
    if j == floor.order {
      p = p * p * (2.0 - two_cos_w)
      q = q * q * (2.0 + two_cos_w)
    } else {
      q = q * (two_cos_w - lsp[j])
      p = p * p * (4.0 - two_cos_w * two_cos_w)
      q = q * q
    }
    if p + q == 0.0 {
      return Err("vorbis: floor0 division by zero")
    }
    let qv = @math.exp(
      (
        amplitude.to_double() *
        floor.amplitude_offset.to_double() /
        (((1L << floor.amplitude_bits) - 1L).to_double() * (p + q).sqrt()) -
        floor.amplitude_offset.to_double()
      ) *
      0.11512925,
    )
    while i < map_size && map[i] == iter_cond {
      vec[i] = qv
      i = i + 1
    }
  }
  Ok(0)
}

///|
/// `render_line` from `vorbis.c`: integer line rasterisation over the
/// floor1 inverse-dB table.
fn vorbis_render_line(
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  buf : Array[Double],
) -> Unit {
  let dy = y1 - y0
  let adx = x1 - x0
  let ady = if dy < 0 { -dy } else { dy }
  let sy = if dy < 0 { -1 } else { 1 }
  buf[x0] = vorbis_floor1_inverse_db_table[vorbis_clip_uint8(y0)]
  if ady * 2 <= adx {
    // render_line_unrolled: the C advances buf by x1-1 and indexes with x.
    let mut err = -adx
    let mut x = x0 - (x1 - 1)
    let mut y = y0
    while true {
      x = x + 1
      if x >= 0 {
        break
      }
      err = err + ady
      if err >= 0 {
        err = err + ady - adx
        y = y + sy
        buf[x1 - 1 + x] = vorbis_floor1_inverse_db_table[vorbis_clip_uint8(y)]
        x = x + 1
      }
      buf[x1 - 1 + x] = vorbis_floor1_inverse_db_table[vorbis_clip_uint8(y)]
    }
    if x <= 0 {
      if err + ady >= 0 {
        y = y + sy
      }
      buf[x1 - 1 + x] = vorbis_floor1_inverse_db_table[vorbis_clip_uint8(y)]
    }
  } else {
    let base = dy / adx
    let mut x = x0
    let mut y = y0
    let mut err = -adx
    let ady2 = ady - (if base < 0 { -base } else { base }) * adx
    while true {
      x = x + 1
      if x >= x1 {
        break
      }
      y = y + base
      err = err + ady2
      if err >= 0 {
        err = err - adx
        y = y + sy
      }
      buf[x] = vorbis_floor1_inverse_db_table[vorbis_clip_uint8(y)]
    }
  }
}

///|
/// `ff_vorbis_floor1_render_list`. */
fn vorbis_floor1_render(
  list : Array[VorbisFloor1Entry],
  y_list : Array[Int32],
  flag : Array[Int32],
  multiplier : Int32,
  out : Array[Double],
  samples : Int32,
) -> Unit {
  let mut lx = 0
  let mut ly = y_list[0] * multiplier
  let mut i = 1
  while i < list.length() {
    let pos = list[i].sort
    if flag[pos] != 0 {
      let x1 = list[pos].x
      let y1 = y_list[pos] * multiplier
      if lx < samples {
        vorbis_render_line(
          lx,
          ly,
          if x1 < samples {
            x1
          } else {
            samples
          },
          y1,
          out,
        )
      }
      lx = x1
      ly = y1
    }
    if lx >= samples {
      break
    }
    i = i + 1
  }
  if lx < samples {
    vorbis_render_line(lx, ly, samples, ly, out)
  }
}

///|
fn vorbis_floor1_decode(
  floor : VorbisFloor1,
  codebooks : Array[VorbisCodebook],
  gb : VorbisBits,
  vec : Array[Double],
) -> Result[Int32, String] {
  if gb.read1() == 0 {
    return Ok(1)
  }
  let range_v : Array[Int32] = [256, 128, 86, 64]
  let range = range_v[floor.multiplier - 1]
  let y_list : Array[Int32] = Array::make(floor.list.length(), 0)
  let y_final : Array[Int32] = Array::make(floor.list.length(), 0)
  let flag : Array[Int32] = Array::make(floor.list.length(), 0)
  y_list[0] = gb.read(vorbis_ilog(range - 1))
  y_list[1] = gb.read(vorbis_ilog(range - 1))
  let mut offset = 2
  for i = 0; i < floor.partitions; i = i + 1 {
    let pc = floor.partition_class[i]
    let cdim = floor.class_dimensions[pc]
    let cbits = floor.class_subclasses[pc]
    let csub = (1 << cbits) - 1
    let mut cval = 0
    if cbits != 0 {
      let book = codebooks[floor.class_masterbook[pc]]
      cval = match book.decode(gb) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    for j = 0; j < cdim; j = j + 1 {
      let book = floor.subclass_books[pc][cval & csub]
      cval = cval >> cbits
      if book > -1 {
        let v = match codebooks[book].decode(gb) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        y_list[offset + j] = v
      } else {
        y_list[offset + j] = 0
      }
    }
    offset = offset + cdim
  }
  flag[0] = 1
  flag[1] = 1
  y_final[0] = y_list[0]
  y_final[1] = y_list[1]
  for i = 2; i < floor.list.length(); i = i + 1 {
    let low = floor.list[i].low
    let high = floor.list[i].high
    let dy = y_final[high] - y_final[low]
    let adx = floor.list[high].x - floor.list[low].x
    let ady = if dy < 0 { -dy } else { dy }
    let err = ady * (floor.list[i].x - floor.list[low].x)
    let off = err / adx
    let predicted = if dy < 0 { y_final[low] - off } else { y_final[low] + off }
    let val = y_list[i]
    let highroom = range - predicted
    let lowroom = predicted
    let room = if highroom < lowroom { highroom * 2 } else { lowroom * 2 }
    if val != 0 {
      flag[low] = 1
      flag[high] = 1
      flag[i] = 1
      if val >= room {
        y_final[i] = if highroom > lowroom {
          clip_u16(val - lowroom + predicted)
        } else {
          clip_u16(predicted - val + highroom - 1)
        }
      } else {
        y_final[i] = if (val & 1) != 0 {
          clip_u16(predicted - (val + 1) / 2)
        } else {
          clip_u16(predicted + val / 2)
        }
      }
    } else {
      flag[i] = 0
      y_final[i] = clip_u16(predicted)
    }
  }
  vorbis_floor1_render(
    floor.list,
    y_final,
    flag,
    floor.multiplier,
    vec,
    floor.list[1].x,
  )
  Ok(0)
}

///|
fn clip_u16(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 65535 {
    65535
  } else {
    v
  }
}

///|
/// `vorbis_inverse_coupling_c`. */
fn vorbis_inverse_coupling(
  vec : Array[Double],
  mag_off : Int32,
  ang_off : Int32,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let magi = vec[mag_off + i]
    let angi = vec[ang_off + i]
    if magi > 0.0 {
      if angi > 0.0 {
        vec[ang_off + i] = magi - angi
      } else {
        vec[ang_off + i] = magi
        vec[mag_off + i] = magi + angi
      }
    } else if angi > 0.0 {
      vec[ang_off + i] = magi + angi
    } else {
      vec[ang_off + i] = magi
      vec[mag_off + i] = magi - angi
    }
  }
}

///|
/// Inverse MDCT as used by Vorbis and FFmpeg's `AV_TX_FLOAT_MDCT` inverse
/// with `scale = -1` (verified against the C tx probe): `n` coefficients to
/// `n` samples,
/// `out[k] = sum_j c[j] * (-1)^(j+1) * sin(pi/(4n) * (2k+1) * (2j+1))`.
/// Evaluated with a sine recurrence, exact but O(N^2).
fn vorbis_imdct(coef : Array[Double], n : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(n, 0.0)
  let pi = 3.14159265358979323846
  for k = 0; k < n; k = k + 1 {
    let a = pi / (4.0 * n.to_double()) * (2 * k + 1).to_double()
    let s0 = @math.sin(a)
    let cd = @math.cos(2.0 * a)
    let mut sm1 = -s0
    let mut s = s0
    let mut acc = 0.0
    for j = 0; j < n; j = j + 1 {
      let sign = if (j & 1) == 0 { -1.0 } else { 1.0 }
      acc = acc + coef[j] * s * sign
      let next = 2.0 * cd * s - sm1
      sm1 = s
      s = next
    }
    out[k] = acc
  }
  out
}

///|
/// `vector_fmul_window` from `float_dsp.c` (the pointers in the C are
/// advanced by `len`, so the loop pairs `src0[i]` with `src1[len-1-i]`).
fn vorbis_fmul_window(
  dst : Array[Double],
  dstoff : Int32,
  src0 : Array[Double],
  s0off : Int32,
  src1 : Array[Double],
  s1off : Int32,
  win : Array[Double],
  len : Int32,
) -> Unit {
  for k = 0; k < len; k = k + 1 {
    let a = src0[s0off + k]
    let b = src1[s1off + len - 1 - k]
    let wk = win[k]
    let wr = win[2 * len - 1 - k]
    dst[dstoff + k] = a * wr - b * wk
    dst[dstoff + 2 * len - 1 - k] = a * wk + b * wr
  }
}

///|
/// `setup_classifs`: decode the classword(s) of one residue partition. */
fn vorbis_setup_classifs(
  book : VorbisCodebook,
  vr : VorbisResidue,
  do_not_decode : Array[Int32],
  ch_used : Int32,
  partition_count : Int32,
  ptns_to_read : Int32,
  gb : VorbisBits,
) -> Result[Unit, String] {
  let c_p_c = book.dimensions
  let mut p = 0
  for j = 0; j < ch_used; j = j + 1 {
    if do_not_decode[j] == 0 {
      let mut temp = match book.decode(gb) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if vr.classifications == 1 {
        for i = partition_count + c_p_c - 1; i >= partition_count; i = i - 1 {
          if i < ptns_to_read {
            vr.classifs[p + i] = 0
          }
        }
      } else {
        for i = partition_count + c_p_c - 1; i >= partition_count; i = i - 1 {
          let temp2 = temp / vr.classifications
          if i < ptns_to_read {
            vr.classifs[p + i] = temp - temp2 * vr.classifications
          }
          temp = temp2
        }
      }
    }
    p = p + ptns_to_read
  }
  Ok(())
}

///|
/// `vorbis_residue_decode_internal`: adds the decoded VQ vectors into the
/// flat per-channel residue buffer.
fn vorbis_residue_decode(
  codebooks : Array[VorbisCodebook],
  vr : VorbisResidue,
  ch : Int32,
  do_not_decode : Array[Int32],
  vec : Array[Double],
  base : Int32,
  vlen : Int32,
  ch_left : Int32,
  vr_type : Int32,
  gb : VorbisBits,
) -> Result[Unit, String] {
  let c_p_c = codebooks[vr.classbook].dimensions
  let classifs = vr.classifs
  let mut ptns_to_read = vr.ptns_to_read
  let mut libvorbis_bug = false
  let mut ch_used = ch
  let mut max_output = (ch - 1) * vlen
  if vr_type == 2 {
    for j = 1; j < ch; j = j + 1 {
      do_not_decode[0] = do_not_decode[0] & do_not_decode[j]
    }
    if do_not_decode[0] != 0 {
      return Ok(())
    }
    ch_used = 1
    max_output = max_output + vr.end / ch
  } else {
    max_output = max_output + vr.end
  }
  if max_output > ch_left * vlen {
    if max_output <= ch_left * vlen + vr.partition_size * ch_used / ch {
      ptns_to_read = ptns_to_read - 1
      libvorbis_bug = true
    } else {
      return Err("vorbis: insufficient residue output buffer")
    }
  }
  for pass = 0; pass <= vr.maxpass; pass = pass + 1 {
    let mut voffset = vr.begin
    let mut partition_count = 0
    while partition_count < ptns_to_read {
      if pass == 0 {
        match
          vorbis_setup_classifs(
            codebooks[vr.classbook],
            vr,
            do_not_decode,
            ch_used,
            partition_count,
            ptns_to_read,
            gb,
          ) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      let mut i = 0
      while i < c_p_c && partition_count < ptns_to_read {
        let mut j_times_ptns = 0
        for j = 0; j < ch_used; j = j + 1 {
          if do_not_decode[j] == 0 {
            let vqclass = classifs[j_times_ptns + partition_count]
            let vqbook = vr.books[vqclass][pass]
            if vqbook >= 0 && codebooks[vqbook].codevectors.length() > 0 {
              let codebook = codebooks[vqbook]
              let dim = codebook.dimensions
              let step = vr.partition_size * 2 / (dim * 2)
              if gb.left() < 0 {
                return Ok(())
              }
              if vr_type == 0 {
                let voffs = voffset + j * vlen
                for k = 0; k < step; k = k + 1 {
                  let coffs = match codebook.decode(gb) {
                    Ok(v) => v
                    Err(e) => return Err(e)
                  }
                  let coff = coffs * dim
                  for l = 0; l < dim; l = l + 1 {
                    vec[base + voffs + k + l * step] = vec[base +
                      voffs +
                      k +
                      l * step] +
                      codebook.codevectors[coff + l]
                  }
                }
              } else if vr_type == 1 {
                let mut voffs = voffset + j * vlen
                for _k = 0; _k < step; _k = _k + 1 {
                  let coffs = match codebook.decode(gb) {
                    Ok(v) => v
                    Err(e) => return Err(e)
                  }
                  let coff = coffs * dim
                  for l = 0; l < dim; l = l + 1 {
                    vec[base + voffs] = vec[base + voffs] +
                      codebook.codevectors[coff + l]
                    voffs = voffs + 1
                  }
                }
              } else {
                let mut voffs_div = if ch == 1 { voffset } else { voffset / ch }
                let mut voffs_mod = voffset - voffs_div * ch
                for _k = 0; _k < step; _k = _k + 1 {
                  let coffs = match codebook.decode(gb) {
                    Ok(v) => v
                    Err(e) => return Err(e)
                  }
                  let coff = coffs * dim
                  for l = 0; l < dim; l = l + 1 {
                    let idx = base + voffs_div + voffs_mod * vlen
                    vec[idx] = vec[idx] + codebook.codevectors[coff + l]
                    voffs_mod = voffs_mod + 1
                    if voffs_mod == ch {
                      voffs_div = voffs_div + 1
                      voffs_mod = 0
                    }
                  }
                }
              }
            }
          }
          j_times_ptns = j_times_ptns + ptns_to_read
        }
        partition_count = partition_count + 1
        voffset = voffset + vr.partition_size
        i = i + 1
      }
    }
    if libvorbis_bug && pass == 0 {
      for j = 0; j < ch_used; j = j + 1 {
        if do_not_decode[j] == 0 {
          match codebooks[vr.classbook].decode(gb) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
      }
    }
  }
  Ok(())
}

///|
/// Decode one audio packet (starting with the 0 packet-type bit). Returns one
/// planar buffer per Vorbis channel (decode order), each with the packet's
/// overlap-add output length `(blocksize + previous_blocksize) / 4`.
pub fn VorbisDecoder::decode_packet(
  self : VorbisDecoder,
  packet : Bytes,
) -> Result[Array[Array[Double]], String] {
  if packet.length() == 0 {
    return Err("vorbis: empty packet")
  }
  let gb = vorbis_bits_new(packet)
  if gb.read1() != 0 {
    return Err("vorbis: not an audio packet")
  }
  let mode_number = if self.modes.length() == 1 {
    0
  } else {
    gb.read(vorbis_ilog(self.modes.length() - 1))
  }
  if mode_number >= self.modes.length() {
    return Err("vorbis: mode number out of range")
  }
  let mode = self.modes[mode_number]
  let mapping = self.mappings[mode.mapping]
  let blockflag = mode.blockflag
  let blocksize = self.blocksize[blockflag]
  let vlen = blocksize / 2
  let mut previous_window = self.previous_window
  if blockflag == 1 {
    let code = gb.read(2)
    if previous_window < 0 {
      previous_window = code >> 1
    }
  } else if previous_window < 0 {
    previous_window = 0
  }
  let residue_buf : Array[Double] = Array::make(self.channels * vlen, 0.0)
  let floors : Array[Array[Double]] = []
  for _i in 0..<self.channels {
    let buf : Array[Double] = Array::make(self.blocksize[1] / 2, 0.0)
    for k = 0; k < vlen; k = k + 1 {
      buf[k] = 0.0
    }
    floors.push(buf)
  }
  let no_residue : Array[Int32] = Array::make(self.channels, 1)
  for i = 0; i < self.channels; i = i + 1 {
    let fi = if mapping.submaps > 1 {
      mapping.submap_floor[mapping.mux[i]]
    } else {
      mapping.submap_floor[0]
    }
    let ret = match self.floors[fi] {
      Floor0(f0) =>
        match
          vorbis_floor0_decode(f0, self.codebooks, gb, blockflag, floors[i]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      Floor1(f1) =>
        match vorbis_floor1_decode(f1, self.codebooks, gb, floors[i]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
    }
    no_residue[i] = ret
  }
  for i = mapping.coupling_steps - 1; i >= 0; i = i - 1 {
    let m = mapping.magnitude[i]
    let a = mapping.angle[i]
    if (no_residue[m] & no_residue[a]) == 0 {
      no_residue[m] = 0
      no_residue[a] = 0
    }
  }
  let res_chan : Array[Int32] = Array::make(self.channels, 0)
  let mut res_num = 0
  let mut ch_left = self.channels
  for i = 0; i < mapping.submaps; i = i + 1 {
    let do_not_decode : Array[Int32] = Array::make(self.channels, 0)
    let mut ch = 0
    for j = 0; j < self.channels; j = j + 1 {
      if mapping.submaps == 1 || i == mapping.mux[j] {
        res_chan[j] = res_num
        do_not_decode[ch] = no_residue[j]
        ch = ch + 1
        res_num = res_num + 1
      }
    }
    if ch_left < ch {
      return Err("vorbis: too many residue channels")
    }
    if ch > 0 {
      let residue = self.residues[mapping.submap_residue[i]]
      match
        vorbis_residue_decode(
          self.codebooks,
          residue,
          ch,
          do_not_decode,
          residue_buf,
          (res_num - ch) * vlen,
          vlen,
          ch_left,
          residue.kind,
          gb,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    ch_left = ch_left - ch
  }
  if ch_left > 0 {
    return Err("vorbis: not all channels have residue data")
  }
  for i = mapping.coupling_steps - 1; i >= 0; i = i - 1 {
    let mag = res_chan[mapping.magnitude[i]] * vlen
    let ang = res_chan[mapping.angle[i]] * vlen
    vorbis_inverse_coupling(residue_buf, mag, ang, vlen)
  }
  for j = self.channels - 1; j >= 0; j = j - 1 {
    let base = res_chan[j] * vlen
    if no_residue[j] != 0 {
      for k = 0; k < vlen; k = k + 1 {
        residue_buf[base + k] = 0.0
      }
      continue
    }
    for k = 0; k < vlen; k = k + 1 {
      floors[j][k] = floors[j][k] * residue_buf[base + k]
    }
    let transformed = vorbis_imdct(floors[j], vlen)
    for k = 0; k < vlen; k = k + 1 {
      residue_buf[base + k] = transformed[k]
    }
  }
  let retlen = (blocksize + self.blocksize[previous_window]) / 4
  let win = vorbis_vwin[self.block_bits[blockflag & previous_window] - 6]
  let out : Array[Array[Double]] = []
  for j = 0; j < self.channels; j = j + 1 {
    let dst : Array[Double] = Array::make(retlen, 0.0)
    let base = res_chan[j] * vlen
    let saved = self.saved[j]
    if blockflag == previous_window {
      vorbis_fmul_window(
        dst,
        0,
        saved,
        0,
        residue_buf,
        base,
        win,
        blocksize / 4,
      )
    } else if blockflag > previous_window {
      let bs0 = self.blocksize[0]
      let bs1 = self.blocksize[1]
      vorbis_fmul_window(dst, 0, saved, 0, residue_buf, base, win, bs0 / 4)
      let ncopy = (bs1 - bs0) / 4
      for k = 0; k < ncopy; k = k + 1 {
        dst[bs0 / 2 + k] = residue_buf[base + bs0 / 4 + k]
      }
    } else {
      let bs0 = self.blocksize[0]
      let bs1 = self.blocksize[1]
      let ncopy = (bs1 - bs0) / 4
      for k = 0; k < ncopy; k = k + 1 {
        dst[k] = saved[k]
      }
      vorbis_fmul_window(
        dst,
        ncopy,
        saved,
        ncopy,
        residue_buf,
        base,
        win,
        bs0 / 4,
      )
    }
    for k = 0; k < blocksize / 4; k = k + 1 {
      saved[k] = residue_buf[base + blocksize / 4 + k]
    }
    out.push(dst)
  }
  self.previous_window = blockflag
  Ok(out)
}

///|
fn VorbisDecoder::decode_stream_impl(
  self : VorbisDecoder,
  packets : Array[Bytes],
  total_samples : Int64,
) -> Result[Array[Array[Double]], String] {
  let decoded : Array[Array[Double]] = []
  for _i in 0..<self.channels {
    decoded.push([])
  }
  let mut first = true
  let mut first_len = 0
  for packet in packets {
    let frames = match self.decode_packet(packet) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if first {
      first = false
      first_len = frames[0].length()
      continue
    }
    for ch = 0; ch < self.channels; ch = ch + 1 {
      for v in frames[ch] {
        decoded[ch].push(v)
      }
    }
  }
  // The Ogg granule gives the total sample count; the final packet is trimmed
  // to it (FFmpeg's oggparsevorbis end_trimming).
  if total_samples > 0L {
    let target = total_samples - first_len.to_int64()
    for ch = 0; ch < self.channels; ch = ch + 1 {
      let n = decoded[ch].length()
      if target >= 0L && target < n.to_int64() {
        decoded[ch] = decoded[ch][0:target.to_int()].to_owned()
      } else if target < 0L {
        decoded[ch] = []
      }
    }
  }
  // FFmpeg maps decode channel `offsets[i]` onto native output channel i.
  let out : Array[Array[Double]] = Array::make(self.channels, [])
  for i = 0; i < self.channels; i = i + 1 {
    out[i] = decoded[self.channel_offsets[i]]
  }
  Ok(out)
}

///|
/// Decode every audio packet and return planar PCM in FFmpeg's native channel
/// order. The first packet's output is dropped, mirroring the decoder's
/// `skip_samples = len` on the first frame.
pub fn VorbisDecoder::decode_stream(
  self : VorbisDecoder,
  packets : Array[Bytes],
) -> Result[Array[Array[Double]], String] {
  self.decode_stream_impl(packets, -1L)
}

///|
/// Like `decode_stream`, but trims the output to the stream's granule
/// (`OggVorbisDemux::total_samples`), as FFmpeg's Ogg demuxer does through
/// `end_trimming`.
pub fn VorbisDecoder::decode_stream_trimmed(
  self : VorbisDecoder,
  packets : Array[Bytes],
  total_samples : Int64,
) -> Result[Array[Array[Double]], String] {
  self.decode_stream_impl(packets, total_samples)
}
