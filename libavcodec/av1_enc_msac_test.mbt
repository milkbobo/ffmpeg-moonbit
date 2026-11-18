// Blackbox round-trip tests for the AV1 msac encoder (§438a): the writer
// must satisfy the decoder in `av1_msac.mbt` byte-for-byte — same CDF
// trajectories, same interval arithmetic, stream inverted-refill
// compatible. These tests are the calibration oracle for the encoder.

///|
/// Deterministic LCG (fixed seed — every backend takes the same path).
fn av1msac_lcg(state : Int64) -> Int64 {
  (state * 6364136223846793005L + 1442695040888963407L) & 0x7FFFFFFFFFFFFFFFL
}

///|
test "av1 msac enc: bool_equi / bool round-trip" {
  let mut seed = 12345L
  // Pre-generate (kind, f, bit) so encoder and decoder replay the same
  // sequence (the decoder needs `f` at the call site).
  let equi : Array[Bool] = []
  let fs : Array[UInt32] = []
  let bits : Array[UInt32] = []
  for i = 0; i < 512; i = i + 1 {
    seed = av1msac_lcg(seed)
    bits.push(((seed >> 33) & 1L).to_int().reinterpret_as_uint())
    if i % 3 == 0 {
      equi.push(true)
      fs.push(0U)
    } else {
      equi.push(false)
      fs.push(((seed >> 20) & 0x7FFFL).to_int().reinterpret_as_uint())
    }
  }
  let enc = @libavcodec.Av1MsacEnc::init(false)
  for i = 0; i < 512; i = i + 1 {
    if equi[i] {
      enc.encode_bool_equi(bits[i])
    } else {
      enc.encode_bool(fs[i], bits[i])
    }
  }
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  for i = 0; i < bits.length(); i = i + 1 {
    let got = if equi[i] {
      dec.decode_bool_equi()
    } else {
      dec.decode_bool(fs[i])
    }
    if got != bits[i] {
      fail("bool round-trip broke at \{i}: wrote \{bits[i]} read \{got}")
    }
  }
}

///|
test "av1 msac enc: symbol_adapt round-trip with shared CDF updates" {
  // A 4-symbol CDF (3 bounds + count), arbitrary but decreasing.
  let enc_cdf : FixedArray[UInt16] = [20000, 14000, 6000, 0]
  let dec_cdf : FixedArray[UInt16] = [20000, 14000, 6000, 0]
  let mut seed = 999L
  let symbols : Array[Int32] = []
  let enc = @libavcodec.Av1MsacEnc::init(false)
  for _i in 0..<300 {
    seed = av1msac_lcg(seed)
    let s = ((seed >> 40) & 3L).to_int()
    symbols.push(s)
    enc.encode_symbol_adapt(enc_cdf, 0, 3, s)
  }
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  for i = 0; i < symbols.length(); i = i + 1 {
    let got = dec.decode_symbol_adapt(dec_cdf, 0, 3)
    if got != symbols[i] {
      fail("symbol round-trip broke at \{i}: wrote \{symbols[i]} read \{got}")
    }
  }
  // The CDF trajectories must agree slot for slot.
  for i = 0; i < 4; i = i + 1 {
    if enc_cdf[i] != dec_cdf[i] {
      fail("CDF diverged at slot \{i}: \{enc_cdf[i]} vs \{dec_cdf[i]}")
    }
  }
}

///|
test "av1 msac enc: bools and uniform round-trip" {
  // Pre-generate (word, n, u) triples for both sides.
  let words : Array[UInt32] = []
  let ns : Array[UInt32] = []
  let unis : Array[Int32] = []
  let mut seed = 4242L
  for _i in 0..<64 {
    seed = av1msac_lcg(seed)
    let v : UInt32 = ((seed >> 24) & 0xFFFL).to_int().reinterpret_as_uint()
    words.push(v)
    seed = av1msac_lcg(seed)
    // n in 2..40 — uniform's short-code path.
    let n : UInt32 = (((seed >> 20) & 38L) + 2L).to_int().reinterpret_as_uint()
    let u : UInt32 = ((seed >> 44) % n.to_int64())
      .to_int()
      .reinterpret_as_uint()
    ns.push(n)
    unis.push(u.reinterpret_as_int())
  }
  let enc = @libavcodec.Av1MsacEnc::init(false)
  for i in 0..<64 {
    enc.encode_bools(12, words[i])
    enc.encode_uniform(ns[i], unis[i].reinterpret_as_uint())
  }
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  for i in 0..<64 {
    let v = dec.decode_bools(12)
    if v != words[i] {
      fail("bools round-trip broke at \{i}")
    }
    let u = dec.decode_uniform(ns[i])
    if u != unis[i] {
      fail("uniform round-trip broke at \{i}: \{unis[i]} vs \{u}")
    }
  }
}

///|
test "av1 msac enc: empty stream and single bool" {
  let enc = @libavcodec.Av1MsacEnc::init(false)
  enc.encode_bool_equi(1U)
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  if dec.decode_bool_equi() != 1U {
    fail("single bool=1 round-trip failed")
  }
  let enc2 = @libavcodec.Av1MsacEnc::init(false)
  enc2.encode_bool_equi(0U)
  let data2 = enc2.done()
  let dec2 = @libavcodec.Av1Msac::init(data2, false)
  if dec2.decode_bool_equi() != 0U {
    fail("single bool=0 round-trip failed")
  }
}

///|
test "av1 msac enc: hi_tok round-trip incl. every escape tier" {
  // Walk tok 3..15 repeatedly (15 = the all-escape tier) over an adapting
  // br-style CDF; the decoder must land on the same token and the CDF
  // trajectory must stay slot-identical.
  let enc_cdf : FixedArray[UInt16] = [22000, 13000, 5000, 0]
  let dec_cdf : FixedArray[UInt16] = [22000, 13000, 5000, 0]
  let toks : Array[Int32] = []
  let mut seed = 31337L
  for _i in 0..<240 {
    seed = av1msac_lcg(seed)
    // 3..15, biased to the upper tiers to exercise every nesting depth.
    toks.push(3 + ((seed >> 40) % 13L).to_int())
  }
  toks.push(15)
  let enc = @libavcodec.Av1MsacEnc::init(false)
  for i in 0..<toks.length() {
    enc.encode_hi_tok(enc_cdf, 0, toks[i])
  }
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  for i in 0..<toks.length() {
    let got = dec.decode_hi_tok(dec_cdf, 0)
    if got != toks[i] {
      fail("hi_tok round-trip broke at \{i}: wrote \{toks[i]} read \{got}")
    }
  }
  for i in 0..<4 {
    if enc_cdf[i] != dec_cdf[i] {
      fail("hi_tok CDF diverged at slot \{i}: \{enc_cdf[i]} vs \{dec_cdf[i]}")
    }
  }
}

///|
test "av1 msac enc: golomb round-trip" {
  // 0 (single one-bit), small values, and LCG values up to ~4096.
  let vals : Array[Int32] = [0, 1, 2, 3, 7, 15, 16, 31]
  let mut seed = 555L
  for _i in 0..<120 {
    seed = av1msac_lcg(seed)
    vals.push(((seed >> 32) & 0xFFFL).to_int())
  }
  let enc = @libavcodec.Av1MsacEnc::init(false)
  for i in 0..<vals.length() {
    enc.encode_golomb(vals[i])
  }
  let data = enc.done()
  let dec = @libavcodec.Av1Msac::init(data, false)
  for i in 0..<vals.length() {
    let got = dec.read_golomb()
    if got != vals[i] {
      fail("golomb round-trip broke at \{i}: wrote \{vals[i]} read \{got}")
    }
  }
}

///|
test "av1 msac enc: 2000-symbol mixed stress and disable_cdf_update" {
  // Mixed primitive stream at scale, both adaptation modes.
  for adapt in [true, false] {
    let enc_cdf : FixedArray[UInt16] = [20000, 14000, 6000, 0]
    let dec_cdf : FixedArray[UInt16] = [20000, 14000, 6000, 0]
    let bool_cdf_e : FixedArray[UInt16] = [16000, 0]
    let bool_cdf_d : FixedArray[UInt16] = [16000, 0]
    let ops : Array[Int32] = [] // 0=symbol 1=bool_adapt 2=bools 3=uniform
    let vals : Array[Int32] = []
    let mut seed = 777L
    let enc = @libavcodec.Av1MsacEnc::init(!adapt)
    for _i in 0..<2000 {
      seed = av1msac_lcg(seed)
      let op = ((seed >> 60) & 3L).to_int()
      ops.push(op)
      if op == 0 {
        vals.push(((seed >> 40) & 3L).to_int())
        enc.encode_symbol_adapt(enc_cdf, 0, 3, vals[vals.length() - 1])
      } else if op == 1 {
        vals.push(((seed >> 33) & 1L).to_int())
        enc.encode_bool_adapt(
          bool_cdf_e,
          0,
          vals[vals.length() - 1].reinterpret_as_uint(),
        )
      } else if op == 2 {
        vals.push(((seed >> 24) & 0x7FFL).to_int())
        enc.encode_bools(11, vals[vals.length() - 1].reinterpret_as_uint())
      } else {
        vals.push(((seed >> 44) & 31L).to_int() + 6)
        enc.encode_uniform(38U, vals[vals.length() - 1].reinterpret_as_uint())
      }
    }
    let data = enc.done()
    let dec = @libavcodec.Av1Msac::init(data, !adapt)
    for i in 0..<2000 {
      let got = if ops[i] == 0 {
        dec.decode_symbol_adapt(dec_cdf, 0, 3)
      } else if ops[i] == 1 {
        dec.decode_bool_adapt(bool_cdf_d, 0).reinterpret_as_int()
      } else if ops[i] == 2 {
        dec.decode_bools(11).reinterpret_as_int()
      } else {
        dec.decode_uniform(38U)
      }
      if got != vals[i] {
        fail(
          "stress round-trip broke at \{i} (op \{ops[i]}, adapt \{adapt}): wrote \{vals[i]} read \{got}",
        )
      }
    }
    if adapt {
      for i in 0..<(4 : Int32) {
        if enc_cdf[i] != dec_cdf[i] {
          fail("stress CDF diverged at slot \{i}")
        }
      }
    }
  }
}
