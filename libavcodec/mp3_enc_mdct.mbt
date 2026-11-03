/// MoonBit port of shine 3.1.1 `l3mdct.c`: the 36-point MDCT of the
/// polyphase subband samples plus the aliasing-reduction butterfly.

///|
/// Table B.9 aliasing-reduction coefficients, computed exactly like the C
/// macros `MDCT_CA` / `MDCT_CS` (the C `(int32_t)` cast truncates toward
/// zero, as does MoonBit's `Double::to_int`).
fn mp3enc_mdct_ca(coef : Double) -> Int32 {
  (coef / (1.0 + coef * coef).sqrt() * 2147483647.0).to_int()
}

///|
fn mp3enc_mdct_cs(coef : Double) -> Int32 {
  (1.0 / (1.0 + coef * coef).sqrt() * 2147483647.0).to_int()
}

///|
let mp3enc_mdct_ca_tab : Array[Int32] = [
  mp3enc_mdct_ca(-0.6),
  mp3enc_mdct_ca(-0.535),
  mp3enc_mdct_ca(-0.33),
  mp3enc_mdct_ca(-0.185),
  mp3enc_mdct_ca(-0.095),
  mp3enc_mdct_ca(-0.041),
  mp3enc_mdct_ca(-0.0142),
  mp3enc_mdct_ca(-0.0037),
]

///|
let mp3enc_mdct_cs_tab : Array[Int32] = [
  mp3enc_mdct_cs(-0.6),
  mp3enc_mdct_cs(-0.535),
  mp3enc_mdct_cs(-0.33),
  mp3enc_mdct_cs(-0.185),
  mp3enc_mdct_cs(-0.095),
  mp3enc_mdct_cs(-0.041),
  mp3enc_mdct_cs(-0.0142),
  mp3enc_mdct_cs(-0.0037),
]

///|
/// `cmuls` of `l3mdct.c`: complex multiply with `>>31` truncation, writing
/// the real part into `a_re` and the imaginary part into `a_im`'s slot.
fn mp3enc_cmuls(
  a_re : Int32,
  a_im : Int32,
  b_re : Int32,
  b_im : Int32,
) -> (Int32, Int32) {
  let tre = ((
    a_re.to_int64() * b_re.to_int64() - a_im.to_int64() * b_im.to_int64()
  ) >>
  31).to_int()
  let tim = ((
    a_re.to_int64() * b_im.to_int64() + a_im.to_int64() * b_re.to_int64()
  ) >>
  31).to_int()
  (tre, tim)
}

///|
/// `shine_mdct_sub`: run the subband analysis into `l3_sb_sample[gr+1]`,
/// MDCT the 18+18 sample granule window per band, apply the alias butterfly,
/// and carry the last granule's subband samples into slot 0.
fn Mp3Encoder::mdct_sub(self : Mp3Encoder) -> Unit {
  let gpf = self.granules_per_frame
  let mut ch = self.channels - 1
  while ch >= 0 {
    for gr in 0..<gpf {
      let curr = self.l3_sb_sample[ch][gr + 1]
      // polyphase filtering, two subband rows per iteration
      let mut k = 0
      while k < 18 {
        self.window_filter_subband(ch, curr[k], 0)
        self.window_filter_subband(ch, curr[k + 1], 0)
        // Compensate for inversion in the analysis filter
        // (every odd index of band AND k)
        let odd = curr[k + 1]
        for band = 1; band < 32; band = band + 2 {
          odd[band] = -odd[band]
        }
        k += 2
      }
      // Perform imdct of 18 previous subband samples + 18 current subband
      // samples, viewed as mdct_freq[32][18]
      let mdct_enc = self.mdct_freq[ch][gr]
      let prev = self.l3_sb_sample[ch][gr]
      let cos_l = mp3enc_mdct_cos_l
      let mdct_in = self.mdct_in
      for band in 0..<32 {
        for k in 0..<18 {
          mdct_in[k] = prev[k][band]
          mdct_in[k + 18] = curr[k][band]
        }
        let band_base = band * 18
        for k in 0..<18 {
          let tbl = k * 36
          let mut vm : Int32 = mp3enc_mul(mdct_in[35], cos_l[tbl + 35])
          for j in 0..<35 {
            vm += mp3enc_mul(mdct_in[j], cos_l[tbl + j])
          }
          mdct_enc[band_base + k] = vm
        }
        // Perform aliasing reduction butterfly
        if band != 0 {
          let prev_base = (band - 1) * 18
          for i in 0..<8 {
            let re = mdct_enc[band_base + i]
            let im = mdct_enc[prev_base + 17 - i]
            let (tre, tim) = mp3enc_cmuls(
              re,
              im,
              mp3enc_mdct_cs_tab[i],
              mp3enc_mdct_ca_tab[i],
            )
            mdct_enc[band_base + i] = tre
            mdct_enc[prev_base + 17 - i] = tim
          }
        }
      }
    }
    // Save latest granule's subband samples to be used in the next mdct call
    let src = self.l3_sb_sample[ch][gpf]
    let dst = self.l3_sb_sample[ch][0]
    for k in 0..<18 {
      for band in 0..<32 {
        dst[k][band] = src[k][band]
      }
    }
    ch -= 1
  }
}
