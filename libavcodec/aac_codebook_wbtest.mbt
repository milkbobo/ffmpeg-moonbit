///|
/// AAC spectral regression vectors: the Cartesian tuple order used by
/// FFmpeg's aactab.c codebook_vector0/2/4/6/8/10, independently of the
/// packed index tables used by the decoder. LGPL-2.1-or-later.
test "aac: all spectral tuples and sign patterns consume exactly their bits" {
  let codes = [
    aac_codes1, aac_codes2, aac_codes3, aac_codes4, aac_codes5, aac_codes6, aac_codes7,
    aac_codes8, aac_codes9, aac_codes10, aac_codes11,
  ]
  let lengths = [
    aac_bits1, aac_bits2, aac_bits3, aac_bits4, aac_bits5, aac_bits6, aac_bits7,
    aac_bits8, aac_bits9, aac_bits10, aac_bits11,
  ]
  let info = aac_test_ics_info(1)
  let swb = aac_swb_tables(4).unwrap() // band zero has four coefficients
  for book = 1; book <= 11; book = book + 1 {
    assert_eq(aac_book_idx[book - 1].length(), codes[book - 1].length())
    let dim = if book <= 4 { 4 } else { 2 }
    let radix = if book <= 4 {
      3
    } else if book <= 6 {
      9
    } else if book <= 8 {
      8
    } else if book <= 10 {
      13
    } else {
      17
    }
    let signed = book <= 2 || (book >= 5 && book <= 6)
    for row = 0; row < codes[book - 1].length(); row = row + 1 {
      let values = Array::make(dim, 0)
      let mut rest = row
      let mut nnz = 0
      for j = dim - 1; j >= 0; j = j - 1 {
        values[j] = rest % radix - (if signed { radix / 2 } else { 0 })
        rest = rest / radix
        if values[j] != 0 {
          nnz = nnz + 1
        }
      }
      let patterns = if signed { 1 } else { 1 << nnz }
      for mask = 0; mask < patterns; mask = mask + 1 {
        let bw = BitWriter::new()
        let mut used = 0
        for _tuple = 0; _tuple < 4 / dim; _tuple = _tuple + 1 {
          bw.put(codes[book - 1][row], lengths[book - 1][row])
          used = used + lengths[book - 1][row]
          if !signed {
            bw.put(mask.reinterpret_as_uint(), nnz)
            used = used + nnz
          }
          if book == 11 {
            for j = 0; j < dim; j = j + 1 {
              if values[j] == 16 {
                bw.put(0, 5) // escape: unary 0, four low bits 0000 -> 16
                used = used + 5
              }
            }
          }
        }
        bw.put(0x2d, 6) // sentinel after the spectral data
        let gb = BitReader::new(bw.finish())
        let coef = Array::make(1024, 0.0)
        aac_decode_spectrum(
          gb,
          info,
          swb,
          [[book]],
          [[-1.25]],
          new_aac_spectrum_state(),
          coef,
        ).unwrap()
        assert_eq(gb.count(), used)
        assert_eq(gb.read(6), 0x2dU)
        let mut sign_left = nnz
        for j = 0; j < dim; j = j + 1 {
          let q = values[j]
          let mag = (if q < 0 { -q } else { q }).to_double()
          let mut expected = mag * @math.cbrt(mag)
          if q < 0 {
            expected = -expected
          }
          if !signed && q != 0 {
            sign_left = sign_left - 1
            if ((mask >> sign_left) & 1) != 0 {
              expected = -expected
            }
          }
          expected = expected * -1.25
          for k = j; k < 4; k = k + dim {
            assert_true(
              (coef[k] - expected).abs() < 0.000005 * mag * mag + 0.000001,
            )
          }
        }
        for k = 4; k < 1024; k = k + 1 {
          assert_eq(coef[k], 0.0)
        }
      }
    }
  }
}

///|
/// One-bin instance of libavutil/tx_template.c's ff_tx_mdct_naive_inv.
/// Keep its two cosine expressions and AAC init_dsp's scale, rather
/// than deriving the expectation from the port's full inverse transform.
fn aac_tx_bin_ref(n : Int32, bin : Int32, value : Double) -> Array[Double] {
  let buf = Array::make(n, 0.0)
  let phase = 3.14159265358979323846 / (4 * n).to_double()
  let scale = value / (n.to_double() * 32768.0)
  for i = 0; i < n / 2; i = i + 1 {
    buf[i] = @math.cos(
        (2 * bin + 1).to_double() * phase * (2 * n - 2 * i - 1).to_double(),
      ) *
      scale
    buf[i + n / 2] = -@math.cos(
        (2 * bin + 1).to_double() * phase * (3 * n + 2 * i + 1).to_double(),
      ) *
      scale
  }
  buf
}

///|
test "aac: long and short synthesis match FFmpeg inverse sign and PCM scale" {
  let coef = Array::make(1024, 0.0)
  coef[7] = 32768.0
  let state = new_aac_channel_state()
  let out = aac_imdct_and_window(state, coef, aac_only_long, 0).unwrap()
  let buf = aac_tx_bin_ref(1024, 7, 32768.0)
  for i = 0; i < 512; i = i + 1 {
    let phase = 3.14159265358979323846 * (i.to_double() + 0.5) / 2048.0
    assert_true((out[i] + buf[511 - i] * @math.sin(phase)).abs() < 1.0e-12)
    assert_true(
      (out[1023 - i] - buf[511 - i] * @math.cos(phase)).abs() < 1.0e-12,
    )
    assert_true((state.saved[i] - buf[512 + i]).abs() < 1.0e-12)
  }
  coef[7] = 0.0
  coef[7 * 128 + 3] = 32768.0
  let state = new_aac_channel_state()
  let out = aac_imdct_and_window(state, coef, aac_eight_short, 0).unwrap()
  let buf = aac_tx_bin_ref(128, 3, 32768.0)
  for i = 0; i < 1024; i = i + 1 {
    assert_eq(out[i], 0.0)
  }
  for i = 0; i < 64; i = i + 1 {
    let phase = 3.14159265358979323846 * (i.to_double() + 0.5) / 256.0
    assert_true(
      (state.saved[320 + i] + buf[63 - i] * @math.sin(phase)).abs() < 1.0e-12,
    )
    assert_true(
      (state.saved[447 - i] - buf[63 - i] * @math.cos(phase)).abs() < 1.0e-12,
    )
    assert_true((state.saved[448 + i] - buf[64 + i]).abs() < 1.0e-12)
  }
}
