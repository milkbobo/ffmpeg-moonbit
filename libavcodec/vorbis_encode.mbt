///|
/// Native Vorbis encoder — MoonBit port of FFmpeg 9.0.2
/// `libavcodec/vorbisenc.c` (`ff_vorbis_encoder`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations from the C:
///   * The bitstream writer is LSB-first (`BITSTREAM_WRITER_LE` in the C),
///     implemented by a dedicated `VorbisBitWriter`; everything else
///     mirrors `put_bits`.
///   * The MDCT is the direct f64 evaluation of `ff_tx_mdct_naive_fwd`
///     (scale 1, len 1024) shared with the WMA encoder port; the stock
///     build runs the av_tx f32 codelet.  Verified by round-trip decode
///     and cross-decode against the stock encoder's Ogg output.
///   * `float` intermediates are evaluated in f64; the quantization-style
///     comparisons (floor_fit thresholds, residue class maxes) sit on
///     coarse grids where the f32 rounding is far below decision distance.
///   * PTS/DTS bookkeeping (`AudioFrameQueue`) is reduced to a running
///     sample counter; `skip_samples` side data is surfaced as a field.

///|
/// `MAX_FLOOR_CLASS_DIM`.
let vorbis_enc_max_floor_class_dim = 4

///|
/// `NUM_FLOOR_PARTITIONS`.
let vorbis_enc_num_floor_partitions = 8

///|
/// `MAX_FLOOR_VALUES`.
let vorbis_enc_max_floor_values : Int32 = vorbis_enc_max_floor_class_dim *
  vorbis_enc_num_floor_partitions +
  2

///|
/// `RESIDUE_SIZE`.
let vorbis_enc_residue_size = 1600

///|
/// `RESIDUE_PART_SIZE`.
let vorbis_enc_residue_part_size = 32

///|
/// `NUM_RESIDUE_PARTITIONS`.
let vorbis_enc_num_residue_partitions : Int32 = vorbis_enc_residue_size /
  vorbis_enc_residue_part_size

///|
/// `MAX_CHANNELS`.
let vorbis_enc_max_channels : Int32 = 2

///|
/// LSB-first bit writer (the C's `BITSTREAM_WRITER_LE` put_bits).
pub struct VorbisBitWriter {
  buf : Array[Byte]
  mut acc : UInt32
  mut nbits : Int32
}

///|
pub fn VorbisBitWriter::new() -> VorbisBitWriter {
  { buf: [], acc: 0, nbits: 0, }
}

///|
/// `put_bits` with the LE bit order: value bits go out LSB first.
pub fn VorbisBitWriter::put(
  self : VorbisBitWriter,
  v : UInt32,
  n : Int32,
) -> Unit {
  let mut k = 0
  while k < n {
    self.acc = self.acc | (((v >> k) & 1) << self.nbits)
    self.nbits = self.nbits + 1
    if self.nbits == 8 {
      self.buf.push(self.acc.to_byte())
      self.acc = 0
      self.nbits = 0
    }
    k = k + 1
  }
}

///|
/// `put_bits32`: 32 bits, LSB first.
pub fn VorbisBitWriter::put32(self : VorbisBitWriter, v : UInt32) -> Unit {
  self.put(v, 32)
}

///|
/// `put_bits_count` in bits.
pub fn VorbisBitWriter::bits(self : VorbisBitWriter) -> Int32 {
  self.buf.length() * 8 + self.nbits
}

///|
/// `flush_put_bits` and return the bytes.
pub fn VorbisBitWriter::finish(self : VorbisBitWriter) -> Bytes {
  if self.nbits > 0 {
    self.buf.push(self.acc.to_byte())
    self.acc = 0
    self.nbits = 0
  }
  Bytes::from_array(self.buf[:])
}

///|
/// `ilog`.
fn vorbis_enc_ilog(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 0 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `av_xiphlacing`: lacing values for a code length (255 continuation).
fn vorbis_enc_xiphlacing(out : Array[Byte], v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x >= 255 {
    out.push(255)
    x = x - 255
    n = n + 1
  }
  out.push(x.to_byte())
  n + 1
}

///|
/// `put_float`: the Vorbis float32 wire format.
fn vorbis_enc_put_float(bw : VorbisBitWriter, f : Double) -> Unit {
  // frexp on the absolute value (frexp(-x) = [-frexp(x).mant, same exp]),
  // then ldexp(mant, 20); all table values are exact in binary32.
  let mut mant = if f < 0 { -f } else { f }
  let mut exp = 0
  if mant != 0.0 {
    while mant >= 1.0 {
      mant = mant * 0.5
      exp = exp + 1
    }
    while mant < 0.5 {
      mant = mant * 2.0
      exp = exp - 1
    }
  }
  let m = (mant * 1048576.0).to_int() // ldexp(frexp, 20)
  let exp2 = exp + 788 - 20
  let mut res : UInt32 = 0
  if f < 0 && mant != 0.0 {
    res = res | 0x80000000
  }
  res = res |
    (m.reinterpret_as_uint() & 0xFFFFF) |
    (exp2 << 21).reinterpret_as_uint()
  bw.put32(res)
}

///|
/// `vorbis_enc_codebook`.
struct VorbisEncCodebook {
  nentries : Int32
  lens : Array[Int32]
  codewords : Array[UInt32]
  ndimensions : Int32
  min : Double
  delta : Double
  seq_p : Int32
  lookup : Int32
  quantlist : Array[Int32]?
  mut dimensions : Array[Double]?
  mut pow2 : Array[Double]?
}

///|
/// `cb_lookup_vals`.
fn vorbis_enc_cb_lookup_vals(
  lookup : Int32,
  dimensions : Int32,
  entries : Int32,
) -> Int32 {
  if lookup == 1 {
    vorbis_nth_root(entries, dimensions)
  } else if lookup == 2 {
    dimensions * entries
  } else {
    0
  }
}

///|
/// `ready_codebook`.
fn vorbis_enc_ready_codebook(cb : VorbisEncCodebook) -> Result[Unit, String] {
  let codes : Array[Int64] = []
  for i = 0; i < cb.nentries; i = i + 1 {
    codes.push(0L)
  }
  match vorbis_len2vlc(cb.lens, codes, cb.nentries) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for i = 0; i < cb.nentries; i = i + 1 {
    cb.codewords[i] = codes[i].to_int().reinterpret_as_uint()
  }
  if cb.lookup == 0 {
    cb.dimensions = None
    cb.pow2 = None
  } else {
    let vals = vorbis_enc_cb_lookup_vals(cb.lookup, cb.ndimensions, cb.nentries)
    let dimensions : Array[Double] = Array::make(
      cb.nentries * cb.ndimensions,
      0.0,
    )
    let pow2 : Array[Double] = Array::make(cb.nentries, 0.0)
    let quant = cb.quantlist.unwrap()
    for i = 0; i < cb.nentries; i = i + 1 {
      let mut last = 0.0
      let mut div = 1
      for j = 0; j < cb.ndimensions; j = j + 1 {
        let off = if cb.lookup == 1 {
          i / div % vals
        } else {
          i * cb.ndimensions + j
        }
        let d = last + cb.min + quant[off].to_double() * cb.delta
        dimensions[i * cb.ndimensions + j] = d
        if cb.seq_p != 0 {
          last = d
        }
        pow2[i] = pow2[i] + d * d
        div = div * vals
      }
      pow2[i] = pow2[i] / 2.0
    }
    cb.dimensions = Some(dimensions)
    cb.pow2 = Some(pow2)
  }
  Ok(())
}

///|
/// `vorbis_enc_floor_class`.
priv struct VorbisEncFloorClass {
  dim : Int32
  subclass : Int32
  masterbook : Int32
  books : Array[Int32]
}

///|
/// `vorbis_enc_floor`.
struct VorbisEncFloor {
  partitions : Int32
  partition_to_class : Array[Int32]
  nclasses : Int32
  classes : Array[VorbisEncFloorClass]
  multiplier : Int32
  rangebits : Int32
  values : Int32
  list : Array[VorbisFloor1Entry]
}

///|
/// `vorbis_enc_residue`.
struct VorbisEncResidue {
  begin : Int32
  end : Int32
  partition_size : Int32
  classifications : Int32
  classbook : Int32
  books : Array[FixedArray[Int32]]
  mut maxes : Array[FixedArray[Double]]?
}

///|
/// `vorbis_enc_mapping`.
struct VorbisEncMapping {
  submaps : Int32
  mux : Array[Int32]
  floor : Array[Int32]
  residue : Array[Int32]
  coupling_steps : Int32
  magnitude : Array[Int32]
  angle : Array[Int32]
}

///|
/// `vorbis_enc_mode`.
struct VorbisEncMode {
  blockflag : Int32
  mapping : Int32
}

///|
/// `vorbis_enc_context` (encoder side).
pub struct VorbisEncoder {
  channels : Int32
  sample_rate : Int32
  log2_blocksize : Array[Int32]
  win : Array[Array[Double]]
  mut have_saved : Int32
  saved : Array[Double]
  samples : Array[Double]
  floor : Array[Double]
  coeffs : Array[Double]
  scratch : Array[Double]
  quality : Double
  ncodebooks : Int32
  codebooks : Array[VorbisEncCodebook]
  floors : Array[VorbisEncFloor]
  residues : Array[VorbisEncResidue]
  mappings : Array[VorbisEncMapping]
  modes : Array[VorbisEncMode]
  mut extradata : Bytes?
  frame_size : Int32
  initial_padding : Int32
}

///|
/// `create_vorbis_context` + `vorbis_encode_init` (quality 8 => 64).
pub fn vorbis_encoder_new(
  sample_rate : Int32,
  channels : Int32,
) -> Result[VorbisEncoder, String] {
  if channels != 2 {
    return Err(
      "vorbis_enc: current FFmpeg Vorbis encoder only supports 2 channels",
    )
  }
  let log2_blocksize = [11, 11]
  let ncodebooks = vorbis_enc_cvectors.length()
  let codebooks : Array[VorbisEncCodebook] = []
  // codebook 0..14 - floor1 book, values 0..255
  // codebook 15 residue masterbook
  // codebook 16..29 residue
  let mut clens_pos = 0
  let mut quant_pos = 0
  for book = 0; book < ncodebooks; book = book + 1 {
    let cv = vorbis_enc_cvectors[book]
    let lens : Array[Int32] = []
    for i = 0; i < cv.real_len; i = i + 1 {
      lens.push(0)
    }
    for i = 0; i < cv.len; i = i + 1 {
      lens[i] = vorbis_enc_codebooks[clens_pos + i]
    }
    clens_pos = clens_pos + cv.len
    let mut quantlist : Array[Int32]? = None
    if cv.lookup != 0 {
      let vals = vorbis_enc_cb_lookup_vals(cv.lookup, cv.dim, cv.real_len)
      let q : Array[Int32] = []
      for i = 0; i < vals; i = i + 1 {
        q.push(vorbis_enc_quant_tables[quant_pos + i])
      }
      quant_pos = quant_pos + vals
      quantlist = Some(q)
    }
    let cb : VorbisEncCodebook = {
      nentries: cv.real_len,
      lens,
      codewords: Array::make(cv.real_len, 0),
      ndimensions: cv.dim,
      min: cv.min,
      delta: cv.delta,
      seq_p: 0,
      lookup: cv.lookup,
      quantlist,
      dimensions: None,
      pow2: None,
    }
    match vorbis_enc_ready_codebook(cb) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    codebooks.push(cb)
  }
  // just 1 floor
  let partition_to_class : Array[Int32] = []
  let mut nclasses = 0
  for i = 0; i < vorbis_enc_num_floor_partitions; i = i + 1 {
    let a : Array[Int32] = [0, 1, 2, 2, 3, 3, 4, 4]
    partition_to_class.push(a[i])
    if a[i] > nclasses {
      nclasses = a[i]
    }
  }
  nclasses = nclasses + 1
  let classes : Array[VorbisEncFloorClass] = []
  for i = 0; i < nclasses; i = i + 1 {
    let fc = vorbis_enc_floor_classes[i]
    let books : Array[Int32] = []
    let nb = 1 << fc.subclass
    for j = 0; j < nb; j = j + 1 {
      books.push(fc.nbooks[j])
    }
    classes.push({
      dim: fc.dim,
      subclass: fc.subclass,
      masterbook: fc.masterbook,
      books,
    })
  }
  let mut values = 2
  for i = 0; i < vorbis_enc_num_floor_partitions; i = i + 1 {
    values = values + classes[partition_to_class[i]].dim
  }
  let list : Array[VorbisFloor1Entry] = []
  let rangebits = log2_blocksize[1] - 1
  for i = 0; i < values; i = i + 1 {
    list.push({ x: 0, sort: 0, low: 0, high: 0, })
  }
  list[0].x = 0
  list[1].x = 1 << rangebits
  let xs : Array[Int32] = [
    93, 23, 372, 6, 46, 186, 750, 14, 33, 65, 130, 260, 556, 3, 10, 18, 28, 39, 55,
    79, 111, 158, 220, 312, 464, 650, 850,
  ]
  for i = 2; i < values; i = i + 1 {
    list[i].x = xs[i - 2]
  }
  match vorbis_ready_floor1_list(list) {
    Err(_) => return Err("vorbis_enc: floor1 list preparation failed")
    Ok(_) => ()
  }
  // single residue
  let books : Array[FixedArray[Int32]] = []
  let a : Array[FixedArray[Int32]] = [
    [-1, -1, -1, -1, -1, -1, -1, -1],
    [-1, -1, 16, -1, -1, -1, -1, -1],
    [-1, -1, 17, -1, -1, -1, -1, -1],
    [-1, -1, 18, -1, -1, -1, -1, -1],
    [-1, -1, 19, -1, -1, -1, -1, -1],
    [-1, -1, 20, -1, -1, -1, -1, -1],
    [-1, -1, 21, -1, -1, -1, -1, -1],
    [22, 23, -1, -1, -1, -1, -1, -1],
    [24, 25, -1, -1, -1, -1, -1, -1],
    [26, 27, 28, -1, -1, -1, -1, -1],
  ]
  for i = 0; i < 10; i = i + 1 {
    books.push(a[i])
  }
  let residue : VorbisEncResidue = {
    begin: 0,
    end: 1600,
    partition_size: 32,
    classifications: 10,
    classbook: 15,
    books,
    maxes: None,
  }
  match vorbis_enc_ready_residue(residue, codebooks) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  // single mapping
  let mux : Array[Int32] = []
  for _i in 0..<channels {
    mux.push(0)
  }
  let floor_map : Array[Int32] = [0]
  let residue_map : Array[Int32] = [0]
  let coupling_steps = if channels == 2 { 1 } else { 0 }
  let magnitude : Array[Int32] = []
  let angle : Array[Int32] = []
  if coupling_steps != 0 {
    magnitude.push(0)
    angle.push(1)
  }
  let mapping : VorbisEncMapping = {
    submaps: 1,
    mux,
    floor: floor_map,
    residue: residue_map,
    coupling_steps,
    magnitude,
    angle,
  }
  // modes: short block, long block
  let modes : Array[VorbisEncMode] = [
    { blockflag: 0, mapping: 0, },
    { blockflag: 1, mapping: 0, },
  ]
  // buffers (interleaved per channel blocks of frame_size)
  let frame_size = 1 << log2_blocksize[1]
  let half = frame_size / 2
  let win : Array[Array[Double]] = [
    vorbis_vwin[log2_blocksize[0] - 6],
    vorbis_vwin[log2_blocksize[1] - 6],
  ]
  let mut quality = 8.0
  quality = quality * quality
  let enc : VorbisEncoder = {
    channels,
    sample_rate,
    log2_blocksize,
    win,
    have_saved: 0,
    saved: Array::make(half * channels, 0.0),
    samples: Array::make(frame_size * channels, 0.0),
    floor: Array::make(half * channels, 0.0),
    coeffs: Array::make(half * channels, 0.0),
    scratch: Array::make(frame_size * channels, 0.0),
    quality,
    ncodebooks,
    codebooks,
    floors: [
      {
        partitions: vorbis_enc_num_floor_partitions,
        partition_to_class,
        nclasses,
        classes,
        multiplier: 2,
        rangebits,
        values,
        list,
      },
    ],
    residues: [residue],
    mappings: [mapping],
    modes,
    extradata: None,
    frame_size: 64,
    initial_padding: 1 << (log2_blocksize[1] - 1),
  }
  match vorbis_enc_put_main_header(enc) {
    Err(e) => return Err(e)
    Ok(data) => enc.extradata = Some(data)
  }
  Ok(enc)
}

///|
/// `ready_residue`.
fn vorbis_enc_ready_residue(
  rc : VorbisEncResidue,
  codebooks : Array[VorbisEncCodebook],
) -> Result[Unit, String] {
  let maxes : Array[FixedArray[Double]] = []
  for i = 0; i < rc.classifications; i = i + 1 {
    maxes.push(FixedArray::make(2, 0.0))
  }
  for i = 0; i < rc.classifications; i = i + 1 {
    let mut j = 0
    while j < 8 {
      if rc.books[i][j] != -1 {
        break
      }
      j = j + 1
    }
    if j == 8 {
      continue
    }
    let cb = codebooks[rc.books[i][j]]
    let dims = cb.dimensions.unwrap()
    for j = 0; j < cb.nentries; j = j + 1 {
      if cb.lens[j] == 0 {
        continue
      }
      let a1 = if dims[j * cb.ndimensions] < 0 {
        -dims[j * cb.ndimensions]
      } else {
        dims[j * cb.ndimensions]
      }
      if a1 > maxes[i][0] {
        maxes[i][0] = a1
      }
      let a2 = if dims[j * cb.ndimensions + 1] < 0 {
        -dims[j * cb.ndimensions + 1]
      } else {
        dims[j * cb.ndimensions + 1]
      }
      if a2 > maxes[i][1] {
        maxes[i][1] = a2
      }
    }
  }
  // small bias
  for i = 0; i < rc.classifications; i = i + 1 {
    maxes[i][0] = maxes[i][0] + 0.8
    maxes[i][1] = maxes[i][1] + 0.8
  }
  rc.maxes = Some(maxes)
  Ok(())
}
