///|
/// Vorbis encoder, part 2: header assembly, floor fitting/encoding,
/// residue coding and the frame driver.  See `vorbis_encode.mbt`.

///|
/// `put_codebook_header`.
fn vorbis_enc_put_codebook_header(
  bw : VorbisBitWriter,
  cb : VorbisEncCodebook,
) -> Unit {
  bw.put(0x564342, 24) // magic "VCB"
  bw.put(cb.ndimensions.reinterpret_as_uint(), 16)
  bw.put(cb.nentries.reinterpret_as_uint(), 24)
  let mut ordered = 0
  let mut i = 1
  while i < cb.nentries {
    if cb.lens[i] < cb.lens[i - 1] {
      break
    }
    i = i + 1
  }
  if i == cb.nentries {
    ordered = 1
  }
  bw.put(ordered.reinterpret_as_uint(), 1)
  if ordered == 1 {
    let mut len = cb.lens[0]
    bw.put((len - 1).reinterpret_as_uint(), 5)
    i = 0
    while i < cb.nentries {
      let mut j = 0
      while j + i < cb.nentries {
        if cb.lens[j + i] != len {
          break
        }
        j = j + 1
      }
      bw.put(j.reinterpret_as_uint(), vorbis_enc_ilog(cb.nentries - i))
      i = i + j
      len = len + 1
    }
  } else {
    let mut sparse = 0
    i = 0
    while i < cb.nentries {
      if cb.lens[i] == 0 {
        break
      }
      i = i + 1
    }
    if i != cb.nentries {
      sparse = 1
    }
    bw.put(sparse.reinterpret_as_uint(), 1)
    for i = 0; i < cb.nentries; i = i + 1 {
      if sparse == 1 {
        bw.put((cb.lens[i] != 0).to_uint(), 1)
      }
      if cb.lens[i] != 0 {
        bw.put((cb.lens[i] - 1).reinterpret_as_uint(), 5)
      }
    }
  }
  bw.put(cb.lookup.reinterpret_as_uint(), 4)
  if cb.lookup != 0 {
    let tmp = vorbis_enc_cb_lookup_vals(cb.lookup, cb.ndimensions, cb.nentries)
    let quant = cb.quantlist.unwrap()
    let mut bits = vorbis_enc_ilog(quant[0])
    for i = 1; i < tmp; i = i + 1 {
      let b = vorbis_enc_ilog(quant[i])
      if b > bits {
        bits = b
      }
    }
    vorbis_enc_put_float(bw, cb.min)
    vorbis_enc_put_float(bw, cb.delta)
    bw.put((bits - 1).reinterpret_as_uint(), 4)
    bw.put(cb.seq_p.reinterpret_as_uint(), 1)
    for i = 0; i < tmp; i = i + 1 {
      bw.put(quant[i].reinterpret_as_uint(), bits)
    }
  }
}

///|
/// `put_floor_header`.
fn vorbis_enc_put_floor_header(
  bw : VorbisBitWriter,
  fc : VorbisEncFloor,
) -> Unit {
  bw.put(1, 16) // type, only floor1 is supported
  bw.put(fc.partitions.reinterpret_as_uint(), 5)
  for i = 0; i < fc.partitions; i = i + 1 {
    bw.put(fc.partition_to_class[i].reinterpret_as_uint(), 4)
  }
  for i = 0; i < fc.nclasses; i = i + 1 {
    let c = fc.classes[i]
    bw.put((c.dim - 1).reinterpret_as_uint(), 3)
    bw.put(c.subclass.reinterpret_as_uint(), 2)
    if c.subclass != 0 {
      bw.put(c.masterbook.reinterpret_as_uint(), 8)
    }
    let books = 1 << c.subclass
    for j = 0; j < books; j = j + 1 {
      bw.put((c.books[j] + 1).reinterpret_as_uint(), 8)
    }
  }
  bw.put((fc.multiplier - 1).reinterpret_as_uint(), 2)
  bw.put(fc.rangebits.reinterpret_as_uint(), 4)
  for i = 2; i < fc.values; i = i + 1 {
    bw.put(fc.list[i].x.reinterpret_as_uint(), fc.rangebits)
  }
}

///|
/// `put_residue_header`.
fn vorbis_enc_put_residue_header(
  bw : VorbisBitWriter,
  rc : VorbisEncResidue,
) -> Unit {
  bw.put(2, 16) // type 2
  bw.put(rc.begin.reinterpret_as_uint(), 24)
  bw.put(rc.end.reinterpret_as_uint(), 24)
  bw.put((rc.partition_size - 1).reinterpret_as_uint(), 24)
  bw.put((rc.classifications - 1).reinterpret_as_uint(), 6)
  bw.put(rc.classbook.reinterpret_as_uint(), 8)
  for i = 0; i < rc.classifications; i = i + 1 {
    let mut tmp = 0
    for j = 0; j < 8; j = j + 1 {
      if rc.books[i][j] != -1 {
        tmp = tmp | (1 << j)
      }
    }
    bw.put((tmp & 7).reinterpret_as_uint(), 3)
    bw.put((tmp > 7).to_uint(), 1)
    if tmp > 7 {
      bw.put((tmp >> 3).reinterpret_as_uint(), 5)
    }
  }
  for i = 0; i < rc.classifications; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      if rc.books[i][j] != -1 {
        bw.put(rc.books[i][j].reinterpret_as_uint(), 8)
      }
    }
  }
}

///|
/// `put_main_header`: identification + comment + setup, xiphlacing-packed.
fn vorbis_enc_put_main_header(enc : VorbisEncoder) -> Result[Bytes, String] {
  let bw = VorbisBitWriter::new()
  // identification header
  bw.put(1, 8)
  for c in "vorbis" {
    bw.put(c.to_int().reinterpret_as_uint(), 8)
  }
  bw.put32(0) // version
  bw.put(enc.channels.reinterpret_as_uint(), 8)
  bw.put32(enc.sample_rate.reinterpret_as_uint())
  bw.put32(0) // bitrate
  bw.put32(0) // bitrate
  bw.put32(0) // bitrate
  bw.put(enc.log2_blocksize[0].reinterpret_as_uint(), 4)
  bw.put(enc.log2_blocksize[1].reinterpret_as_uint(), 4)
  bw.put(1, 1) // framing
  let h0 = bw.finish()
  // comment header
  let bw = VorbisBitWriter::new()
  bw.put(3, 8)
  for c in "vorbis" {
    bw.put(c.to_int().reinterpret_as_uint(), 8)
  }
  bw.put32(0) // vendor length
  bw.put32(0) // amount of comments
  bw.put(1, 1) // framing
  let h1 = bw.finish()
  // setup header
  let bw = VorbisBitWriter::new()
  bw.put(5, 8)
  for c in "vorbis" {
    bw.put(c.to_int().reinterpret_as_uint(), 8)
  }
  // codebooks
  bw.put((enc.ncodebooks - 1).reinterpret_as_uint(), 8)
  for i = 0; i < enc.ncodebooks; i = i + 1 {
    vorbis_enc_put_codebook_header(bw, enc.codebooks[i])
  }
  // time domain, reserved, zero
  bw.put(0, 6)
  bw.put(0, 16)
  // floors
  bw.put((enc.floors.length() - 1).reinterpret_as_uint(), 6)
  for i = 0; i < enc.floors.length(); i = i + 1 {
    vorbis_enc_put_floor_header(bw, enc.floors[i])
  }
  // residues
  bw.put((enc.residues.length() - 1).reinterpret_as_uint(), 6)
  for i = 0; i < enc.residues.length(); i = i + 1 {
    vorbis_enc_put_residue_header(bw, enc.residues[i])
  }
  // mappings
  bw.put((enc.mappings.length() - 1).reinterpret_as_uint(), 6)
  for i = 0; i < enc.mappings.length(); i = i + 1 {
    let mc = enc.mappings[i]
    bw.put(0, 16) // mapping type
    bw.put((mc.submaps > 1).to_uint(), 1)
    if mc.submaps > 1 {
      bw.put((mc.submaps - 1).reinterpret_as_uint(), 4)
    }
    bw.put((mc.coupling_steps != 0).to_uint(), 1)
    if mc.coupling_steps != 0 {
      bw.put((mc.coupling_steps - 1).reinterpret_as_uint(), 8)
      for j = 0; j < mc.coupling_steps; j = j + 1 {
        bw.put(
          mc.magnitude[j].reinterpret_as_uint(),
          vorbis_enc_ilog(enc.channels - 1),
        )
        bw.put(
          mc.angle[j].reinterpret_as_uint(),
          vorbis_enc_ilog(enc.channels - 1),
        )
      }
    }
    bw.put(0, 2) // reserved
    if mc.submaps > 1 {
      for j = 0; j < enc.channels; j = j + 1 {
        bw.put(mc.mux[j].reinterpret_as_uint(), 4)
      }
    }
    for j = 0; j < mc.submaps; j = j + 1 {
      bw.put(0, 8) // reserved time configuration
      bw.put(mc.floor[j].reinterpret_as_uint(), 8)
      bw.put(mc.residue[j].reinterpret_as_uint(), 8)
    }
  }
  // modes
  bw.put((enc.modes.length() - 1).reinterpret_as_uint(), 6)
  for i = 0; i < enc.modes.length(); i = i + 1 {
    bw.put(enc.modes[i].blockflag.reinterpret_as_uint(), 1)
    bw.put(0, 16) // reserved window type
    bw.put(0, 16) // reserved transform type
    bw.put(enc.modes[i].mapping.reinterpret_as_uint(), 8)
  }
  bw.put(1, 1) // framing
  let h2 = bw.finish()
  // xiphlacing packing
  let out : Array[Byte] = [2]
  let _ = vorbis_enc_xiphlacing(out, h0.length())
  let _ = vorbis_enc_xiphlacing(out, h1.length())
  for b in h0 {
    out.push(b)
  }
  for b in h1 {
    out.push(b)
  }
  for b in h2 {
    out.push(b)
  }
  Ok(Bytes::from_array(out))
}

///|
/// `get_floor_average`.
fn vorbis_enc_get_floor_average(
  fc : VorbisEncFloor,
  coeffs : Array[Double],
  base : Int32,
  i : Int32,
) -> Double {
  let begin = fc.list[fc.list[if i - 1 > 0 { i - 1 } else { 0 }].sort].x
  let hi = if i + 1 < fc.values - 1 { i + 1 } else { fc.values - 1 }
  let end = fc.list[fc.list[hi].sort].x
  let mut average = 0.0
  for j = begin; j < end; j = j + 1 {
    let v = coeffs[base + j]
    average = average + (if v < 0 { -v } else { v })
  }
  average / (end - begin).to_double()
}

///|
/// `floor_fit`.
fn vorbis_enc_floor_fit(
  enc : VorbisEncoder,
  fc : VorbisEncFloor,
  coeffs : Array[Double],
  base : Int32,
  posts : Array[Int32],
  _samples : Int32,
) -> Unit {
  let range = 255 / fc.multiplier + 1
  let tot_average : Ref[Double] = Ref(0.0)
  let averages : Array[Double] = Array::make(fc.values, 0.0)
  for i = 0; i < fc.values; i = i + 1 {
    averages[i] = vorbis_enc_get_floor_average(fc, coeffs, base, i)
    tot_average.val = tot_average.val + averages[i]
  }
  let mut tot = tot_average.val / fc.values.to_double()
  tot = tot / enc.quality
  for i = 0; i < fc.values; i = i + 1 {
    let position = fc.list[fc.list[i].sort].x
    let average = averages[i]
    let avg = (tot * average).sqrt() *
      @math.pow(1.25, position.to_double() * 0.005) // MAGIC!
    let mut j = 0
    while j < range - 1 {
      if vorbis_floor1_inverse_db_table[j * fc.multiplier] > avg {
        break
      }
      j = j + 1
    }
    posts[fc.list[i].sort] = j
  }
}

///|
/// `render_point`.
fn vorbis_enc_render_point(
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  x : Int32,
) -> Int32 {
  y0 + (x - x0) * (y1 - y0) / (x1 - x0)
}

///|
/// `put_codeword`.
fn vorbis_enc_put_codeword(
  bw : VorbisBitWriter,
  cb : VorbisEncCodebook,
  entry : Int32,
) -> Bool {
  bw.put(cb.codewords[entry], cb.lens[entry])
  true
}

///|
/// `floor_encode`.
fn vorbis_enc_floor_encode(
  enc : VorbisEncoder,
  fc : VorbisEncFloor,
  bw : VorbisBitWriter,
  posts : Array[Int32],
  floor : Array[Double],
  base : Int32,
  samples : Int32,
) -> Bool {
  let range = 255 / fc.multiplier + 1
  let coded : Array[Int32] = Array::make(vorbis_enc_max_floor_values, 0)
  bw.put(1, 1) // non zero
  bw.put(posts[0].reinterpret_as_uint(), vorbis_enc_ilog(range - 1))
  bw.put(posts[1].reinterpret_as_uint(), vorbis_enc_ilog(range - 1))
  coded[0] = 1
  coded[1] = 1
  for i = 2; i < fc.values; i = i + 1 {
    let predicted = vorbis_enc_render_point(
      fc.list[fc.list[i].low].x,
      posts[fc.list[i].low],
      fc.list[fc.list[i].high].x,
      posts[fc.list[i].high],
      fc.list[i].x,
    )
    let highroom = range - predicted
    let lowroom = predicted
    let room = if highroom < lowroom { highroom } else { lowroom }
    if predicted == posts[i] {
      coded[i] = 0 // must be used later as flag!
    } else {
      if coded[fc.list[i].low] == 0 {
        coded[fc.list[i].low] = -1
      }
      if coded[fc.list[i].high] == 0 {
        coded[fc.list[i].high] = -1
      }
      if posts[i] > predicted {
        if posts[i] - predicted > room {
          coded[i] = posts[i] - predicted + lowroom
        } else {
          coded[i] = (posts[i] - predicted) * 2
        }
      } else if predicted - posts[i] > room {
        coded[i] = predicted - posts[i] + highroom - 1
      } else {
        coded[i] = (predicted - posts[i]) * 2 - 1
      }
    }
  }
  let mut counter = 2
  for i = 0; i < fc.partitions; i = i + 1 {
    let c = fc.classes[fc.partition_to_class[i]]
    let csub = 1 << c.subclass
    let mut cval = 0
    if c.subclass != 0 {
      let book = enc.codebooks[c.masterbook]
      let mut cshift = 0
      for k = 0; k < c.dim; k = k + 1 {
        let mut l = 0
        while l < csub {
          let maxval = if c.books[l] != -1 {
            enc.codebooks[c.books[l]].nentries
          } else {
            1
          }
          // coded could be -1, but this still works, cause that is 0
          if coded[counter + k] < maxval {
            break
          }
          l = l + 1
        }
        cval = cval | (l << cshift)
        cshift = cshift + c.subclass
      }
      if !vorbis_enc_put_codeword(bw, book, cval) {
        return false
      }
    }
    for k = 0; k < c.dim; k = k + 1 {
      let book = c.books[cval & (csub - 1)]
      let mut entry = coded[counter]
      counter = counter + 1
      cval = cval >> c.subclass
      if book == -1 {
        continue
      }
      if entry == -1 {
        entry = 0
      }
      if !vorbis_enc_put_codeword(bw, enc.codebooks[book], entry) {
        return false
      }
    }
  }
  // The shared renderer writes indices 0..samples; the encoder's floor
  // buffer is channel-major, so render into a scratch and copy at `base`
  // (C renders straight into `&venc->floor[i * frame_size]`).
  let rendered : Array[Double] = Array::make(samples, 0.0)
  vorbis_floor1_render(fc.list, posts, coded, fc.multiplier, rendered, samples)
  for i = 0; i < samples; i = i + 1 {
    floor[base + i] = rendered[i]
  }
  true
}

///|
/// `put_vector`: nearest VQ vector; returns the chosen vector.
fn vorbis_enc_put_vector(
  book : VorbisEncCodebook,
  bw : VorbisBitWriter,
  num : Array[Double],
  num_off : Int32,
) -> Int32? {
  let dims = book.dimensions.unwrap()
  let pow2 = book.pow2.unwrap()
  let mut entry = 0
  let mut distance = 1.0e38 // FLT_MAX
  for i = 0; i < book.nentries; i = i + 1 {
    let vec_base = i * book.ndimensions
    let mut d = pow2[i]
    if book.lens[i] == 0 {
      continue
    }
    for j = 0; j < book.ndimensions; j = j + 1 {
      d = d - dims[vec_base + j] * num[num_off + j]
    }
    if distance > d {
      entry = i
      distance = d
    }
  }
  if !vorbis_enc_put_codeword(bw, book, entry) {
    return None
  }
  Some(entry)
}

///|
/// `residue_encode` (type 2 only, both channels interleaved).
fn vorbis_enc_residue_encode(
  enc : VorbisEncoder,
  rc : VorbisEncResidue,
  bw : VorbisBitWriter,
  coeffs : Array[Double],
  samples : Int32,
  real_ch : Int32,
) -> Bool {
  let psize = rc.partition_size
  let partitions = (rc.end - rc.begin) / psize
  // C: `channels = (rc->type == 2) ? 1 : real_ch`.  The encoder creates a
  // single type-2 residue (begin 0 / end 1600), identified here by config.
  let channels = if rc.begin == 0 && rc.end == 1600 && real_ch == 2 {
    1
  } else {
    real_ch
  }
  let classes : Array[Array[Int32]] = []
  for _c in 0..<vorbis_enc_max_channels {
    classes.push(Array::make(vorbis_enc_num_residue_partitions, 0))
  }
  let classwords = enc.codebooks[rc.classbook].ndimensions
  let maxes = rc.maxes.unwrap()
  for p = 0; p < partitions; p = p + 1 {
    let max1 : Ref[Double] = Ref(0.0)
    let max2 : Ref[Double] = Ref(0.0)
    let s = rc.begin + p * psize
    let mut k = s
    while k < s + psize {
      // FFMAX(max, fabs(...)): the maximum over the partition, not the
      // last element's magnitude.
      let v1 = coeffs[k / real_ch]
      let a1 = if v1 < 0 { -v1 } else { v1 }
      if a1 > max1.val {
        max1.val = a1
      }
      let v2 = coeffs[samples + k / real_ch]
      let a2 = if v2 < 0 { -v2 } else { v2 }
      if a2 > max2.val {
        max2.val = a2
      }
      k = k + 2
    }
    let mut i = 0
    while i < rc.classifications - 1 {
      if max1.val < maxes[i][0] && max2.val < maxes[i][1] {
        break
      }
      i = i + 1
    }
    classes[0][p] = i
  }
  for pass = 0; pass < 8; pass = pass + 1 {
    let mut p = 0
    while p < partitions {
      if pass == 0 {
        for j = 0; j < channels; j = j + 1 {
          let book = enc.codebooks[rc.classbook]
          let mut entry = 0
          for i = 0; i < classwords; i = i + 1 {
            entry = entry * rc.classifications
            entry = entry + classes[j][p + i]
          }
          if !vorbis_enc_put_codeword(bw, book, entry) {
            return false
          }
        }
      }
      let mut i = 0
      while i < classwords && p < partitions {
        for j = 0; j < channels; j = j + 1 {
          let nbook = rc.books[classes[j][p]][pass]
          if nbook == -1 {
            continue
          }
          let book = enc.codebooks[nbook]
          // rc->type == 2 path (the only one the encoder creates):
          // gather ndimensions interleaved coefficients, quantize to the
          // nearest VQ vector, subtract it back.
          let s2 = rc.begin + p * psize
          let mut a1 = s2 % real_ch * samples
          let mut b1 = s2 / real_ch
          let send = real_ch * samples
          let mut k = 0
          while k < psize {
            let ndim = book.ndimensions
            let vec : Array[Double] = Array::make(ndim, 0.0)
            let mut a2 = a1
            let mut b2 = b1
            for vi in 0..<ndim {
              vec[vi] = coeffs[a2 + b2]
              a2 = a2 + samples
              if a2 == send {
                a2 = 0
                b2 = b2 + 1
              }
            }
            let pv = match vorbis_enc_put_vector(book, bw, vec, 0) {
              None => return false
              Some(v) => v
            }
            let dims = book.dimensions.unwrap()
            let base = pv * ndim
            for vi in 0..<ndim {
              coeffs[a1 + b1] = coeffs[a1 + b1] - dims[base + vi]
              a1 = a1 + samples
              if a1 == send {
                a1 = 0
                b1 = b1 + 1
              }
            }
            k = k + ndim
          }
        }
        i = i + 1
        p = p + 1
      }
    }
  }
  true
}
