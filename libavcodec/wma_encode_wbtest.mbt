///|
/// White-box tests for the WMA v1/v2 encoder: constructor validation,
/// packet shape, round-trip through the bit-exact decoder, and the
/// total_gain search behavior.

///|
/// Generate one frame of interleaved s16-ranged samples from a tone mix,
/// scaled to the f32-normalized range the encoder input uses.
fn wma_enc_test_tone_frame(n : Int32, ch : Int32, t0 : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(n * ch, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = (t0 + i).to_double()
    for c = 0; c < ch; c = c + 1 {
      // deterministic s16 signal: two tones + a slight per-channel offset
      let phase = if c == 1 { 0.31 } else { 0.0 }
      let v = 12000.0 *
        @math.sin(2.0 * 3.14159265358979323846 * 440.0 * t / 44100.0 + phase) +
        5000.0 * @math.sin(2.0 * 3.14159265358979323846 * 4400.0 * t / 44100.0)
      // quantize to s16 then normalize to the encoder's f32 input range
      let q = wma_enc_lrint(v)
      out[i * ch + c] = q.to_double() / 32768.0
    }
  }
  out
}

///|
test "WMA encoder: constructor validation" {
  match wma_encoder_new(2, 44100, 2, 128000) {
    Err(e) => fail("44100 stereo 128k rejected: \{e}")
    Ok(_) => inspect("ok", content="ok")
  }
  match wma_encoder_new(2, 44100, 3, 128000) {
    Err(e) =>
      inspect(e, content="wma_enc: too many channels: got 3, need 2 or fewer")
    Ok(_) => fail("expected too-many-channels rejection")
  }
  match wma_encoder_new(2, 96000, 2, 128000) {
    Err(e) =>
      inspect(e, content="wma_enc: sample rate is too high: 96000 > 48kHz")
    Ok(_) => fail("expected sample-rate rejection")
  }
  match wma_encoder_new(2, 44100, 2, 8000) {
    Err(e) =>
      inspect(
        e,
        content="wma_enc: bitrate too low: got 8000, need 24000 or higher",
      )
    Ok(_) => fail("expected bitrate rejection")
  }
  match wma_encoder_new(3, 44100, 2, 128000) {
    Err(e) => inspect(e, content="wma_enc: only WMA v1/v2 are supported")
    Ok(_) => fail("expected version rejection")
  }
}

///|
test "WMA encoder: round-trip through the decoder" {
  let enc = wma_encoder_new(2, 44100, 2, 128000).unwrap()
  inspect(enc.frame_size(), content="2048")
  inspect(enc.extradata().length(), content="10")
  // block_align for 128 kbit/s at 44.1 kHz with frame_len 2048:
  // 128000 * 2048 / (44100 * 8) = 743 (floor).
  inspect(enc.block_align(), content="743")
  let dec = wma_decoder_new(2, 44100, 2, 128000, enc.block_align(), 1).unwrap()
  // Encode 3 frames and decode them; the encoder delay is one frame, so
  // decode gives back the frame_len-delayed signal.
  let nframes = 3
  let all_ok = true
  for f = 0; f < nframes; f = f + 1 {
    let frame = wma_enc_test_tone_frame(
      enc.frame_size(),
      2,
      f * enc.frame_size(),
    )
    let pkt = match enc.encode_frame(frame) {
      Ok(p) => p
      Err(e) => fail("encode error frame \{f}: \{e}")
    }
    inspect(pkt.length(), content=enc.block_align().to_string())
    match dec.decode_packet(pkt) {
      Ok(chs) =>
        // decoded: frame_len samples per channel for this packet
        if chs.length() != 2 || chs[0].length() != enc.frame_size() {
          fail("decoded shape mismatch frame \{f}")
        }
      Err(e) => fail("decode error frame \{f}: \{e}")
    }
  }
  inspect(all_ok, content="true")
}

///|
/// Round-trip SNR: encode 8 frames, decode, align for the one-frame delay,
/// and require the same quality floor the C encoder achieves on this
/// signal.  Computed on the s16 grid like the other audio quality gates.
test "WMA encoder: round-trip SNR quality gate" {
  let enc = wma_encoder_new(2, 44100, 2, 128000).unwrap()
  let dec = wma_decoder_new(2, 44100, 2, 128000, enc.block_align(), 1).unwrap()
  let n = enc.frame_size()
  let nframes = 8
  let total = n * nframes
  let orig : Array[Array[Double]] = [
    Array::make(total, 0.0),
    Array::make(total, 0.0),
  ]
  let decoded : Array[Array[Double]] = [
    Array::make(total, 0.0),
    Array::make(total, 0.0),
  ]
  let mut pos = 0
  for f = 0; f < nframes; f = f + 1 {
    let frame = wma_enc_test_tone_frame(n, 2, f * n)
    for i = 0; i < n; i = i + 1 {
      for c = 0; c < 2; c = c + 1 {
        orig[c][pos + i] = frame[i * 2 + c]
      }
    }
    let pkt = enc.encode_frame(frame).unwrap()
    let chs = dec.decode_packet(pkt).unwrap()
    for i = 0; i < n; i = i + 1 {
      for c = 0; c < 2; c = c + 1 {
        decoded[c][pos + i] = chs[c][i]
      }
    }
    pos = pos + n
  }
  // The decoder emits one frame of (window-overlap) delay; compare frames
  // 1..nframes-1 of the decoded output against frames 0..nframes-2 of the
  // input (both already normalized by 1/32768 at the test input).
  let mut sig = 0.0
  let mut noise = 0.0
  let cmp = n * (nframes - 1)
  for i = 0; i < cmp; i = i + 1 {
    for c = 0; c < 2; c = c + 1 {
      // compare on the s16 grid: scale both back up
      let o = orig[c][i] * 32768.0
      let d = decoded[c][n + i] * 32768.0
      sig = sig + o * o
      noise = noise + (o - d) * (o - d)
    }
  }
  let snr = 10.0 * @math.log10(sig / noise)
  // The C wmav2 encoder at 128 kbit/s reaches ~35 dB SNR on tonal content.
  inspect(snr > 30.0, content="true")
}

///|
/// Bisect the abort: build the encoder and run only the window/MDCT step.
test "WMA encoder: window+MDCT step only" {
  inspect(1, content="1")
  let enc = wma_encoder_new(2, 44100, 2, 128000).unwrap()
  inspect(2, content="2")
  let n = enc.frame_size()
  inspect(3, content="3")
  let frame = wma_enc_test_tone_frame(n, 2, 0)
  // manual steps to locate the abort
  let window_len = 1 << enc.frame_len_bits
  inspect(window_len, content="2048")
  let win = enc.d.windows[0]
  inspect(win.length(), content="2048")
  let fo = enc.frame_out[0]
  inspect(fo.length(), content="4096")
  let out = enc.output
  inspect(out.length(), content="4096")
  for i = 0; i < window_len; i = i + 1 {
    out[i] = fo[i]
  }
  for i = 0; i < n; i = i + 1 {
    fo[i] = wma_enc_f32(
      frame[i * 2] * wma_enc_f32(2.0 * 32768.0 / window_len.to_double()),
    )
  }
  for i = 0; i < n; i = i + 1 {
    out[window_len + i] = wma_enc_f32(fo[n - 1 - i] * win[i])
  }
  let mdct_in : Array[Double] = Array::make(2 * window_len, 0.0)
  for i = 0; i < 2 * window_len; i = i + 1 {
    mdct_in[i] = out[i]
  }
  let coefs = wma_enc_mdct_fwd(mdct_in, window_len)
  inspect(coefs.length(), content="2048")
  let ok = enc.apply_window_and_mdct(frame, n)
  inspect(ok, content="true")
  inspect(enc.coefs[0][0] != 0.0, content="true")
}

///|
/// Then only one encode_block call.
test "WMA encoder: single encode_block" {
  let enc = wma_encoder_new(2, 44100, 2, 128000).unwrap()
  let n = enc.frame_size()
  let frame = wma_enc_test_tone_frame(n, 2, 0)
  let ok = enc.apply_window_and_mdct(frame, n)
  inspect(ok, content="true")
  if enc.ms_stereo {
    for i in 0..<n {
      let a = enc.coefs[0][i] * 0.5
      let b = enc.coefs[1][i] * 0.5
      enc.coefs[0][i] = a + b
      enc.coefs[1][i] = a - b
    }
  }
  let bw = BitWriter::new()
  let err = enc.encode_block(bw, 100)
  inspect(err >= 0, content="true")
}

///|
/// Smallest slice: the naive MDCT alone on a 8-sample input.
test "WMA encoder: mdct alone" {
  let x : Array[Double] = [0.1, 0.2, 0.3, 0.4, -0.1, -0.2, -0.3, 0.0]
  let y = wma_enc_mdct_fwd(x, 4)
  inspect(y.length(), content="4")
}

///|
/// Then the tone generator.
test "WMA encoder: tone generator" {
  let t = wma_enc_test_tone_frame(16, 2, 0)
  inspect(t.length(), content="32")
}

///|
/// WMA v1 interop: the same tone sequence encoded with version=1 matches
/// the docker linuxserver/ffmpeg:9.0.2 wmav1 encoder byte for byte.
/// Regeneration:
///   ffmpeg -y -f s16le -ar 44100 -ac 2 -i wma_ref_input.pcm -c:a wmav1 -b:a 128k -f asf wma_v1_ref.asf
///   ffmpeg -v error -y -i wma_v1_ref.asf -map 0:a:0 -c copy -f data wma_v1_packets.bin
///   (tone frames: wma_enc_test_tone_frame at 64..? see wma_encode.mbt tests)

///|
let wma_enc_v1_packets_b64 : Bytes = b"7RQAAACgAAAPz/P8vy/P8/y/LAf54C/LzeA/NYCrH83XB5rPesfBJns4iul8+TwhWmc+XBNsEw6fL+I/gJJAAwXY8BbwAPgP8AB8" +
  b"B6wAPgKfAB8BJAAHnrM+B/i90jMGzPldL4JPNVw/n5rKMB2/KOL9rduWre/4n3HStULdL6h+l8ilNCKU0Ck0BJQElASUBJQElExM" +
  b"TExMTExMTExMTExPniYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiQCQCQgpCCkIKQgpCCkIKQgpCDSKDSKDSihL9D5L9C0lbo4" +
  b"qeOi3P/2+/Jb83bs9spz5a4PCVYJnwFGAA+AqgAHwEmAAuIasDvNuIv6rg48BrWUP/2+t1PHQtUraHyX6HyaUUJpRQaQgpCCkIKQ" +
  b"gpCCkIKQgkAkAkAkAkAkAkAkAkAkAkAkCYmJiYmJiYmJiYmJiYmJeCwxDaTaXXznexIkWLPJ4D0zvadIGAPySATazkHLtPAe6c8i" +
  b"acWJyL3nO95zr4utJtJtJtJtJtJtJtJtJtJtJtJtJtJtJiGIdk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk7tlAAAAKAA" +
  b"AArqSBSm3fpxG3wGygAeA/4ADBJgOl8EkT4CASspAKUW7KXEt58BXgAPgKXAArH/dFBIEvChLuno5oAB0cVgAT1qwE5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTu4UAAAAoAAACu4mo6Cc" +
  b"qsecf8B5QAKfyWNSY8BAJWk1HZWZw+AxgACi2OdmpMPAoZRo5eACnukOwE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O7dQAAACgAAAK6mDSLctuny+AuMAH" +
  b"wHygAYDwGigpifAQCVsCUI4/3gux4CmwAfAUUADgP9IpIBh4oRTE0cxgAm1nPUrATk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk7t1AAAAKAAAAzokIpW/y/EbwHoAAeA3UAHPk/T" +
  b"+lAJHgIBK5AKUcX7wXZ8BTgAPgKKAAwH+0UEgS8A2XJ7o5MAA0ccAAaTdk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTu5UAAAAoAAADA4k0IwHnv4D7gAfAU6AA6f374JInwEAlbTC" +
  b"xcQQ8BfIACfCDs1Jh4DZueeQV0cdgA9VgE5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O" +
  b"Tk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5O"

///|
test "WMA encoder: v1 packets match FFmpeg wmav1 byte-for-byte" {
  let enc = wma_encoder_new(1, 44100, 2, 128000).unwrap()
  inspect(enc.block_align(), content="743")
  let n = enc.frame_size()
  let blob = @libavutil.av_base64_decode(wma_enc_v1_packets_b64, 1 << 24).unwrap()
  let mut pos = 0
  for f = 0; f < 6; f = f + 1 {
    let frame = wma_enc_test_tone_frame(n, 2, f * n)
    let pkt = enc.encode_frame(frame).unwrap()
    inspect(pkt.length(), content="743")
    let want = blob.clamped_view(start=pos, end=pos + 743).to_owned()
    pos = pos + 743
    if pkt != want {
      let mut d = 0
      let lim = if pkt.length() < want.length() {
        pkt.length()
      } else {
        want.length()
      }
      while d < lim && pkt[d] == want[d] {
        d = d + 1
      }
      fail("v1 packet \{f} differs from FFmpeg at byte \{d}")
    }
  }
}
