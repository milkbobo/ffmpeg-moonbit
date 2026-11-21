///|
/// End-to-end Vorbis round trip inside the repository: the MoonBit encoder
/// produces packets, the Ogg/Vorbis muxer frames them, the Ogg/Vorbis
/// demuxer parses the result, and the bit-exact decoder reconstructs the
/// tone within the lossy-quality gate.  The decoded output matches docker
/// ffmpeg's decode of the same stream sample-exactly; the first audio
/// packet is byte-identical to FFmpeg's native encoder (see
/// libavcodec/vorbis_encode_wbtest).

///|
test "Vorbis E2E: encode -> Ogg mux -> demux -> decode" {
  let enc = match @libavcodec.vorbis_encoder_new(44100, 2) {
    Ok(e) => e
    Err(e) => fail("encoder: \{e}")
  }
  let nframes = 34
  let queue : Array[Array[Double]] = []
  for f = 0; f < nframes; f = f + 1 {
    queue.push(@libavcodec.vorbis_e2e_tone(enc.frame_size, 2, f * enc.frame_size))
  }
  let packets : Array[Bytes] = []
  let mut qi = 0
  // The encoder consumes 16 queued 64-sample frames per emitted packet
  // (mirrors C's bufqueue semantics: 1024 new samples per long block).
  while qi + 16 <= queue.length() {
    let pkt = match enc.encode(queue, qi, 16, false) {
      Ok(p) => p
      Err(e) => fail("encode: \{e}")
    }
    packets.push(pkt)
    qi = qi + 16
  }
  let tail = match enc.encode(queue, qi, queue.length() - qi, true) {
    Ok(p) => p
    Err(e) => fail("flush: \{e}")
  }
  if tail.length() > 0 {
    packets.push(tail)
  }
  inspect(packets.length() >= 2, content="true")
  // Mux: each block decodes to 1024 samples per channel (blocksize 2048).
  let (h0, h1, h2) = @libavcodec.vorbis_e2e_split_extradata(enc.extradata.unwrap())
  let mux = match @libavformat.ogg_vorbis_muxer_new(h0, h1, h2) {
    Err(e) => fail("muxer: \{e}")
    Ok(m) => m
  }
  for pkt in packets {
    mux.write_packet(pkt, 1024)
  }
  let ogg = mux.finish()
  let magic = ogg.clamped_view(start=0, end=4).to_owned()
  let ok = magic[0] == b'O' && magic[1] == b'g' && magic[2] == b'g' && magic[3] == b'S'
  inspect(ok, content="true")
  // Demux and decode.
  let demux = match @libavformat.av_ogg_vorbis_open(ogg) {
    Err(e) => fail("demux: \{e}")
    Ok(d) => d
  }
  inspect(demux.channels, content="2")
  inspect(demux.sample_rate, content="44100")
  // mux/demux byte fidelity
  inspect(demux.id_header == h0, content="true")
  inspect(demux.packets.length(), content=packets.length().to_string())
  inspect(demux.packets[0].data == packets[0], content="true")
  inspect(demux.packets[1].data == packets[1], content="true")
  let dec = match @libavcodec.vorbis_decoder_new(demux.id_header, demux.setup_header) {
    Err(e) => fail("decoder: \{e}")
    Ok(d) => d
  }
  let pkt_data : Array[Bytes] = []
  for p in demux.packets {
    pkt_data.push(p.data)
  }
  let chs = match dec.decode_stream(pkt_data) {
    Err(e) => fail("decode: \{e}")
    Ok(v) => v
  }
  // Compare against the original input. After the first (pre-skip) block is
  // dropped, the decoded stream aligns with the input from sample 0 — this
  // offset was verified sample-exact against docker ffmpeg's decode of the
  // same Ogg stream.
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
    let mut diag = ""
    for i = 0; i < 6; i = i + 1 {
      let dv = (chs[0][i] * 32768.0).round().to_int()
      diag = diag + "\{dv} "
    }
    let mut refd = ""
    for i = 0; i < 6; i = i + 1 {
      let rv = (queue[i / enc.frame_size][i % enc.frame_size * 2] * 32768.0).round().to_int()
      refd = refd + "\{rv} "
    }
    fail("SNR = \{snr} dB; out: \{diag} in@0: \{refd}; outlen \{chs[0].length()}")
  }
  inspect(snr > 20.0, content="true")
}
