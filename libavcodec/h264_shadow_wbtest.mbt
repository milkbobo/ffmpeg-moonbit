// Shadow parser (debug): mirror the decoder's CAVLC I-slice reads over the
// encoder's own stream, printing every field and residual total, so the
// first divergence from the encoder's writes is visible. Runs native-only
// inside the ffref image (white-box access; the wasm executable is at the
// V8 init local-count limit).

///|
fn shadow_fixture(w : Int32, h : Int32) -> (Bytes, Bytes, Bytes) {
  let y : Array[Byte] = []
  let u : Array[Byte] = []
  let v : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let mut s2 = (col * 2 + row * 3) & 0xFF
      if (((col >> 3) + (row >> 3)) & 1) == 1 {
        s2 = (s2 + 48) & 0xFF
      }
      y.push(s2.to_byte())
    }
  }
  for row = 0; row < h / 2; row = row + 1 {
    for col = 0; col < w / 2; col = col + 1 {
      u.push((((col + row) & 0x3F) + 96).to_byte())
      v.push((((row * 2 + col) & 0x3F) + 96).to_byte())
    }
  }
  (Bytes::from_array(y[:]), Bytes::from_array(u[:]), Bytes::from_array(v[:]))
}

///|
test "shadow parse enc 32x32" {
  let (y, u, v) = shadow_fixture(32, 32)
  let enc = match h264_encode_intra_frame(y, u, v, width=32, height=32, qp=24) {
    Ok(e) => e
    Err(e) => {
      println("encode err: \{e}")
      fail(e)
    }
  }
  // Locate the IDR slice NAL (type 5) and strip header + emulation
  // prevention the same way the demuxer does.
  let data = enc.annexb
  let mut i = 0
  let mut slice_off = -1
  while i + 4 < data.length() {
    let nt = data[i + 4].to_int() & 0x1F
    let h1 = data[i] == b'\x00'
    let h2 = h1 && data[i + 1] == b'\x00'
    let h3 = h2 && data[i + 2] == b'\x00'
    let h4 = h3 && data[i + 3] == b'\x01'
    if h4 && nt == 5 {
      slice_off = i + 5
      break
    }
    i = i + 1
  }
  if slice_off < 0 {
    fail("no IDR slice NAL")
  }
  // Unescape.
  let mut nb2 = ""
  for i3 = 0; i3 < 16; i3 = i3 + 1 {
    if slice_off + i3 < data.length() {
      nb2 = nb2 + (data[slice_off + i3].to_int() & 0xFF).to_string() + ","
    }
  }
  println("SHADOW escaped first16: \{nb2}")
  let raw : Array[Byte] = []
  let mut z = 0
  let mut k = slice_off
  while k < data.length() {
    let b = data[k]
    if z >= 2 && b == b'\x03' {
      // emulation prevention byte: drop (next byte continues the RBSP)
      z = 0
    } else {
      raw.push(b)
      if b == b'\x00' {
        z = z + 1
      } else {
        z = 0
      }
    }
    k = k + 1
  }
  let mut nb3 = ""
  for i4 = 0; i4 < 16; i4 = i4 + 1 {
    if i4 < raw.length() {
      nb3 = nb3 + (raw[i4].to_int() & 0xFF).to_string() + ","
    }
  }
  println("SHADOW raw first16: \{nb3}")
  let gb = BitReader::new(Bytes::from_array(raw[:]))
  // Slice header (mirrors what the encoder writes).
  ignore(gb.read_ue31()) // first_mb_in_slice
  ignore(gb.read_ue31()) // slice_type
  ignore(gb.read_ue31()) // pps id
  ignore(gb.read(4)) // frame_num
  ignore(gb.read_ue31()) // idr_pic_id
  ignore(gb.read1()) // no_output_of_prior_pics
  ignore(gb.read1()) // long_term_reference_flag
  ignore(gb.read_se()) // slice_qp_delta
  println("hdr bits used: \{gb.count()}")
  // MB loop with the decoder's nz/mode mirrors.
  let mbw = 2
  let nz_rows : Array[Array[Int32]] = []
  for m = 0; m < mbw * 2; m = m + 1 {
    nz_rows.push(Array::make(48, 0))
  }
  let mode_rows : Array[Array[Int32]] = []
  for m = 0; m < mbw * 2; m = m + 1 {
    mode_rows.push(Array::make(16, 0))
  }
  let i4_rows : Array[Bool] = []
  for m = 0; m < mbw * 2; m = m + 1 {
    i4_rows.push(false)
  }
  let cur_nz = Array::make(48, 0)
  let cur_modes = Array::make(16, 0)
  fn pred_nz(a : Int32, b : Int32) -> Int32 {
    let sum = a + b
    if sum < 64 {
      (sum + 1) >> 1
    } else {
      sum & 31
    }
  }
  for mb_y = 0; mb_y < 2; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < mbw; mb_x = mb_x + 1 {
      let idx = mb_y * mbw + mb_x
      for t = 0; t < 48; t = t + 1 {
        cur_nz[t] = 0
      }
      let mb_type = gb.read_ue31()
      println("MB(\{mb_x},\{mb_y}) mb_type=\{mb_type}")
      if mb_type == 0 {
        i4_rows[idx] = true
        for i = 0; i < 16; i = i + 1 {
          let gx = h264_luma_block_x[i]
          let gy = h264_luma_block_y[i]
          let left = if gx > 0 {
            cur_modes[gy * 4 + gx - 1]
          } else if mb_x > 0 {
            let li = idx - 1
            if i4_rows[li] {
              mode_rows[li][gy * 4 + 3]
            } else {
              2
            }
          } else {
            -1
          }
          let top = if gy > 0 {
            cur_modes[(gy - 1) * 4 + gx]
          } else if mb_y > 0 {
            let ti = idx - mbw
            if i4_rows[ti] {
              mode_rows[ti][3 * 4 + gx]
            } else {
              2
            }
          } else {
            -1
          }
          let predicted = if left < 0 || top < 0 {
            2
          } else if left < top {
            left
          } else {
            top
          }
          let mode = if gb.read1() == 0U {
            let rem = gb.read(3).reinterpret_as_int()
            rem + (if rem >= predicted { 1 } else { 0 })
          } else {
            predicted
          }
          cur_modes[gy * 4 + gx] = mode
          println("  m\{i}=\{mode}")
        }
        println("")
      } else if mb_type >= 1 && mb_type <= 24 {
        let group = (mb_type - 1) / 4
        let cbp = h264_i16x16_cbp[group]
        println("  i16 cbp=\{cbp}")
      } else {
        fail("bad mb_type")
      }
      let cm = gb.read_ue31()
      println("  chroma_mode=\{cm}")
      let mut cbp = 0
      if mb_type == 0 {
        let code = gb.read_ue31()
        cbp = h264_golomb_to_intra4x4_cbp[code]
        println("  cbp_code=\{code} cbp=\{cbp}")
        if cbp != 0 {
          ignore(gb.read_se())
        }
      } else {
        cbp = h264_i16x16_cbp[(mb_type - 1) / 4]
        // I16 always codes mb_qp_delta (`cbp != 0 || is_i16x16`).
        ignore(gb.read_se())
      }
      fn nc_l(gx : Int32, gy : Int32) -> Int32 {
        let left = if gx > 0 {
          cur_nz[gy * 4 + gx - 1]
        } else if mb_x > 0 {
          nz_rows[idx - 1][gy * 4 + 3]
        } else {
          64
        }
        let top = if gy > 0 {
          cur_nz[(gy - 1) * 4 + gx]
        } else if mb_y > 0 {
          nz_rows[idx - mbw][3 * 4 + gx]
        } else {
          64
        }
        pred_nz(left, top)
      }
      if mb_type >= 1 && mb_type <= 24 {
        // I16: DC block + AC blocks.
        let blk = Array::make(16, 0)
        let left = if mb_x > 0 { nz_rows[idx - 1][3] } else { 64 }
        let top = if mb_y > 0 { nz_rows[idx - mbw][12] } else { 64 }
        let nc = pred_nz(left, top)
        let win = gb.show(32)
        println("SHADOW dc win32=\{win}")
        let t2 = h264_decode_residual(
          gb,
          blk,
          0,
          h264_zigzag_scan_t,
          0,
          None,
          16,
          nc,
          bit_depth=8,
        )
        println("  dc nc=\{nc} total=\{t2.unwrap_or(-1)}")
        if (cbp & 15) != 0 {
          for i = 0; i < 16; i = i + 1 {
            let gx = h264_luma_block_x[i]
            let gy = h264_luma_block_y[i]
            let blk2 = Array::make(16, 0)
            let nc2 = nc_l(gx, gy)
            let tot = h264_decode_residual(
              gb,
              blk2,
              0,
              h264_zigzag_scan_t,
              1,
              None,
              15,
              nc2,
              bit_depth=8,
            )
            println(
              "  DEC mb(\{mb_x},\{mb_y}) ac i=\{i} nc=\{nc2} total=\{tot.unwrap_or(-1)}",
            )
            cur_nz[gy * 4 + gx] = tot.unwrap_or(0)
          }
        }
      } else {
        for i8 = 0; i8 < 4; i8 = i8 + 1 {
          if (cbp & (1 << i8)) != 0 {
            for i4 = 0; i4 < 4; i4 = i4 + 1 {
              let i = i8 * 4 + i4
              let gx = h264_luma_block_x[i]
              let gy = h264_luma_block_y[i]
              let blk3 = Array::make(16, 0)
              let nc3 = nc_l(gx, gy)
              if mb_x == 1 && mb_y == 1 && i == 0 {
                let mut nzdump2 = ""
                for k7 = 0; k7 < 16; k7 = k7 + 1 {
                  nzdump2 = nzdump2 + nz_rows[idx - mbw][k7].to_string() + ","
                }
                println("DEC topMB nz: \{nzdump2}")
              }
              if mb_x == 1 && mb_y == 1 && i == 4 {
                println(
                  "DEC i4in: left=\{cur_nz[1]} top=\{nz_rows[idx - mbw][14]}",
                )
              }
              let tot3 = h264_decode_residual(
                gb,
                blk3,
                0,
                h264_zigzag_scan_t,
                0,
                None,
                16,
                nc3,
                bit_depth=8,
              )
              println(
                "  i4 i=\{i} nc=\{nc3} total=\{tot3.unwrap_or(-1)} pos=\{gb.count()}",
              )
              cur_nz[gy * 4 + gx] = tot3.unwrap_or(0)
            }
          }
        }
      }
      // Chroma.
      if (cbp & 0x30) != 0 {
        for c = 0; c < 2; c = c + 1 {
          let blk4 = Array::make(64, 0)
          let t4 = h264_decode_residual(
            gb,
            blk4,
            0,
            h264_chroma_dc_scan,
            0,
            None,
            4,
            0,
            bit_depth=8,
          )
          println("  cdc c=\{c} total=\{t4.unwrap_or(-1)}")
        }
      }
      if (cbp & 0x20) != 0 {
        for c = 0; c < 2; c = c + 1 {
          for i = 0; i < 4; i = i + 1 {
            let gx = i % 2
            let gy = i / 2
            let base = 16 + 16 * c
            let left = if gx > 0 {
              cur_nz[base + i - 1]
            } else if mb_x > 0 {
              nz_rows[idx - 1][base + 1 + 2 * gy]
            } else {
              64
            }
            let top = if gy > 0 {
              cur_nz[base + i - 2]
            } else if mb_y > 0 {
              nz_rows[idx - mbw][base + 2 + gx]
            } else {
              64
            }
            let ncc = pred_nz(left, top)
            let blk5 = Array::make(16, 0)
            let t5 = h264_decode_residual(
              gb,
              blk5,
              0,
              h264_zigzag_scan_t,
              1,
              None,
              15,
              ncc,
              bit_depth=8,
            )
            println("  cac c=\{c} i=\{i} nc=\{ncc} total=\{t5.unwrap_or(-1)}")
            cur_nz[base + i] = t5.unwrap_or(0)
          }
        }
      }
      for t = 0; t < 48; t = t + 1 {
        nz_rows[idx][t] = cur_nz[t]
      }
      for t = 0; t < 16; t = t + 1 {
        mode_rows[idx][t] = cur_modes[t]
      }
    }
  }
  println("SHADOW OK")
}
