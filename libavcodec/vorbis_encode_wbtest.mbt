///|
/// White-box tests for the Vorbis encoder: header round-trip through the
/// bit-exact decoder, an encode -> self-decode round trip with a quality
/// gate, bit-exact parity with FFmpeg's native encoder for the first audio
/// packet, and bisection probes (X1/X3) kept from the bring-up.

///|
test "Vorbis encoder: extradata builds and decoder accepts it" {
  let enc = match vorbis_encoder_new(44100, 2) {
    Ok(e) => e
    Err(e) => fail("encoder construction failed: \{e}")
  }
  let data = match enc.extradata {
    Some(d) => d
    None => fail("no extradata")
  }
  inspect(data[0].to_int(), content="2")
  // xiph lacing: one value per of the first two headers (short headers fit
  // one byte); the setup header spans the remainder.
  inspect(data[1].to_int(), content="30")
  inspect(data[2].to_int(), content="16")
  inspect(data[3].to_int(), content="1") // id magic
  inspect(data[4].to_int(), content="118") // 'v'
  let (h0, _h1, h2) = vorbis_e2e_split_extradata(data)
  match vorbis_decoder_new(h0, h2) {
    Err(e) => fail("decoder rejected our headers: \{e}")
    Ok(_) => inspect("ok", content="ok")
  }
}

///|
test "Vorbis encoder: encode produces packets and decodes" {
  let enc = match vorbis_encoder_new(44100, 2) {
    Ok(e) => e
    Err(e) => fail("encoder construction failed: \{e}")
  }
  // The C encoder consumes 16 queued 64-sample frames (1024 new samples)
  // per emitted packet.
  let nframes = 34
  let queue : Array[Array[Double]] = []
  for f = 0; f < nframes; f = f + 1 {
    queue.push(vorbis_e2e_tone(enc.frame_size, 2, f * enc.frame_size))
  }
  let packets : Array[Bytes] = []
  let mut qi = 0
  while qi + 16 <= queue.length() {
    let pkt = match enc.encode(queue, qi, 16, false) {
      Ok(p) => p
      Err(e) => fail("encode error at \{qi}: \{e}")
    }
    inspect(pkt.length() > 0, content="true")
    packets.push(pkt)
    qi = qi + 16
  }
  let tail = match enc.encode(queue, qi, queue.length() - qi, true) {
    Ok(p) => p
    Err(e) => fail("flush error: \{e}")
  }
  if tail.length() > 0 {
    packets.push(tail)
  }
  let (h0, _h1, h2) = vorbis_e2e_split_extradata(enc.extradata.unwrap())
  let dec = match vorbis_decoder_new(h0, h2) {
    Err(e) => fail("decoder rejected our headers: \{e}")
    Ok(d) => d
  }
  let chs = match dec.decode_stream(packets) {
    Err(e) => fail("decode error: \{e}")
    Ok(v) => v
  }
  // Round-trip quality gate: after dropping the first (pre-skip) block the
  // decoded stream aligns with the input from sample 0 (verified sample-exact
  // against docker ffmpeg's decode of the same Ogg stream).
  let mut sig = 0.0
  let mut noise = 0.0
  let in_samples = nframes * enc.frame_size
  let cmp = if in_samples < chs[0].length() {
    in_samples
  } else {
    chs[0].length()
  }
  for i = 0; i < cmp; i = i + 1 {
    for c = 0; c < 2; c = c + 1 {
      let o = queue[i / enc.frame_size][i % enc.frame_size * 2 + c] * 32768.0
      let d = chs[c][i] * 32768.0
      sig = sig + o * o
      noise = noise + (o - d) * (o - d)
    }
  }
  let snr = 10.0 * @math.log10(sig / noise)
  if snr <= 20.0 {
    fail("round-trip SNR = \{snr} dB")
  }
  inspect(snr > 20.0, content="true")
}

///|
/// Bit-exact parity with FFmpeg's native vorbis encoder: the first audio
/// packet for the same 1024 input samples and quality (8^2) must be
/// byte-identical (reference packet produced by docker linuxserver/ffmpeg
/// 9.0.2, `ffmpeg -strict -2 -c:a vorbis`, hex-encoded).
test "Vorbis encoder: first packet is byte-identical to FFmpeg's" {
  let ff_pkt0 = hex_bytes(
    "3ed9eb218968d7052d50d2090ea860454cf25c40d175a1b4a494748ca3112a82d1f4a328cba228cba228cba2288f150080d3738c5f00808c042cabaa08000000000058d36c9772b273f971ad1399cd692a9119520010596651291487bab5d1d268da0d8b69352ce6c8cc1f968b59bc557e4d8571bdc6f61ed5fbba3dbd7a8a6b233e7df295934e9f7c79d2c589cbe317272e8f5f9cb81c79b6ec7ce4d9b21f2f7c7ff1c7d3f7e71f4fdf9f7f3c7d7ffe5fbffbbdfa9eabef99bbafb93b9ab8a3893b9ab8a3893b9ab8a3893b9ab897a7772f4fef5e9edebd3cbd7b797af7f2f4eee5e9ddcbd3bb97a7772f4fef5e9ededd39ed6eaadd9deaa653dd74da6ea38b19e32649e99393d22c24a9d1883a53fdd00ffdd00ffdd00ffdd00ffdd00ffdd00ffdd00ffdd08fc78f1f3f7efcf8f1e3c78f1f3f7efcf8f1e3c78f1f3f7efcf8f1e3c78f1f3f7efcf8f1e3c78f1f3f7efcf8f1e3c78f1f3f7efcf8f1e3c78f1f3f06",
  )
  let enc = match vorbis_encoder_new(44100, 2) {
    Ok(e) => e
    Err(e) => fail("encoder construction failed: \{e}")
  }
  let queue : Array[Array[Double]] = []
  for f = 0; f < 16; f = f + 1 {
    queue.push(vorbis_e2e_tone(enc.frame_size, 2, f * enc.frame_size))
  }
  let pkt = match enc.encode(queue, 0, 16, false) {
    Ok(p) => p
    Err(e) => fail("encode error: \{e}")
  }
  if pkt.length() != ff_pkt0.length() {
    fail("packet size \{pkt.length()} != FFmpeg's \{ff_pkt0.length()}")
  }
  if pkt != ff_pkt0 {
    let n = pkt.length()
    let mut d = -1
    for i = 0; i < n; i = i + 1 {
      if pkt[i] != ff_pkt0[i] {
        d = i
        break
      }
    }
    fail("first differing byte at \{d}")
  }
  inspect("byte-identical", content="byte-identical")
}

///|
/// Decode a hex string into bytes.
fn hex_bytes(s : String) -> Bytes {
  let digits : Bytes = b"0123456789abcdef"
  let chars = s.to_array()
  let out : Array[Byte] = []
  let mut i = 0
  while i + 1 < chars.length() {
    let mut hi = 0
    let mut lo = 0
    for d = 0; d < 16; d = d + 1 {
      if chars[i] == digits[d].to_char() {
        hi = d
      }
      if chars[i + 1] == digits[d].to_char() {
        lo = d
      }
    }
    out.push((hi * 16 + lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out[:])
}

///|
test "X1 len2vlc on codebook 0" {
  let lens : Array[Int32] = []
  for i in 0..<16 {
    lens.push(vorbis_enc_codebooks[i])
  }
  let codes : Array[Int64] = Array::make(16, 0L)
  match vorbis_len2vlc(lens, codes, 16) {
    Err(e) => fail("book0 len2vlc err: \{e}")
    Ok(_) => inspect(codes[1], content="2")
  }
}

///|
test "X3 full ready_codebooks loop" {
  let mut clens_pos = 0
  let mut quant_pos = 0
  for book = 0; book < vorbis_enc_cvectors.length(); book = book + 1 {
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
      Err(e) => fail("book \{book} err: \{e}")
      Ok(_) => ()
    }
  }
  inspect(clens_pos, content="4788")
}
