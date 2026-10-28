///|
/// MP4 Opus writer end-to-end test: three real Opus packets are muxed with
/// `mp4_opus_muxer`, read back by `av_mov_open`, and decoded through the
/// dOps-derived OpusHead. Reference PCM is FFmpeg 9.0.2's s16le decode of the
/// same MP4 (one pre-skip of 312 samples trimmed); the port matches within
/// one LSB on four of 2568 samples.

///|
let mp4_opus_ref_pcm_b64 : Bytes = b"SAAgASEC9gLpA8UEpQWFBlQHKQjrCK4JZQoQC7sLUQzmDGkN4Q1UDrEOCg9TD44PwA/eD/UP+w/xD98PvQ+LD04PBQ" +
  b"+rDkoO2w1fDdkMRgyrCwULVgqdCdsIEwhAB2sGjwWtBMkD3gL0AQgBGQAs/z3+U/1q/IX7ovrD+e34G/hP94v20PUb" +
  b"9XD00PM5867yLfK48VLx9fCo8GbwMfAN8PPv6u/s7/3vHPBI8IPwyfAd8X7x6vFj8ubydfMN9K/0WvUP9s32kfdc+C" +
  b"35Bfri+sH7pPyJ/XH+W/9DACsBEgL3AtkDtwSSBWYGNgf/B8EIfQkvCtoKeQsQDJ4MHw2WDQAOXg6xDvYOLw9bD3oP" +
  b"jA+SD4kPdQ9VDyYP7Q6mDlIO9A2JDRMNkwwIDHML0worCnsJwwgDCDwHcAadBcYE6wMNAywCSQFlAID/m/64/db89v" +
  b"sZ+0D6bPmd+NT3EvdX9qX1+/RZ9MHzMvOv8jfyyvFo8RPxyvCN8F7wPfAo8CHwKPA78F3wi/DH8A/xZPHE8THyqvIu" +
  b"873zV/T79Kf1XPYZ99/3rfiA+Vj6NvsX/Pv84/3M/rX/nwCIAW8CVQM3BBcF8gXHBpgHYQgkCd8JkQo8C90Lcgz9DH" +
  b"4N8w1bDrgOBw9JD34PpQ/AD8wPyg+8D58Pdg8/D/oOqQ5LDuENbA3pDFoMwgsgC3QKvQn+CDcIaQeTBroF2QTzAwwD" +
  b"IgI0AUcAWf9r/n/9lfyu+8v67PkS+T74cfer9u31OPWM9OrzUfPD8kLyzPFh8QTxtPBy8DzwE/D47+rv6u/47xPwO/" +
  b"Bx8LTwBPFh8cnxPfK+8knz3vN/9Cf12fWT9lX3Hvjt+ML5m/p5+1v8QP0o/hH/+v/kAM0BtQKbA34EXQU2BgsH2wei" +
  b"CGIJGwrKCnALDgyhDCoNqA0YDn4O2g4nD2cPmg/AD9kP5g/kD9UPuA+PD1kPFQ/GDmgO/w2KDQkNfQzoC0YLmwroCS" +
  b"wJaAidB8oG8wUXBTQETgNmAnsBjwCi/7X+yv3h/Pr7Ffs2+lz5iPi49/H2MvZ59cv0J/SN8/zyd/L88Y3xLPHY8I7w" +
  b"UfAi8AHw7e/l7+vv/+8g8E/wjPDV8CvxjvH88Xfy/fKO8yv00vSC9Tn2+vbD95L4aPlD+iP7B/zu/Nf9w/6v/5sAhg" +
  b"FwAlYDOgQaBfUFzQadB2cIKgnmCZkKRQvmC3wMCA2JDQAOag7IDhoPXg+WD8EP3w/vD/EP5w/ND6gPdQ80D+YOjQ4m" +
  b"DrQNNg2tDBgMegvSCiEKaAmnCN4HDgc6BmAFgAScA7YCzQHiAPf/DP8h/jf9Ufxt+436s/nd+A34RPeD9sn1GfVx9N" +
  b"PzQPO38jnyx/Fh8QfxuPB48EXwHvAE8Pnv++8K8CfwU/CK8NDwI/GA8evxYvLk8nHzCfSq9Ff1DPbK9pH3X/gz+Q36" +
  b"7PrR+7n8o/2P/n3/awBYAUUCLwMWBPsE2wW0BooHWgghCeEJmQpHC+wLiAwXDZwNFQ6BDuAOMw96D7IP3A/5DwgQCR" +
  b"D8D+IPug+ED0EP8A6UDisOtg01DagMEQxwC8UKEQpUCZAIxAfwBhcGOQVXBHADhQKaAawAvv/Q/uP99/wO/Cj7Rvpq" +
  b"+ZH4v/f19jL2d/XE9Bv0fPPn8l3y3vFr8QXxq/Be8B/w7e/I77Lvqu+w78Pv5e8V8FLwnPDz8FjxyPFF8s7yYPP+86" +
  b"f0WfUT9tb2ofdz+Ez5KfoL+/L73PzI/bb+pv+TAIABawJUAzcEFAXqBbkGgAc8COwIkQkqCrUKMQufC/wLSQyGDLIM" +
  b"zAzVDM0MtAyKDFAMBQyrC0ILzApKCrsJIgmACNcHJwd0Br0FBAVLBJQD4QIyAokB5wBOAL7/Ov/C/lX+9v2k/WD9Kv" +
  b"0C/ej82/zb/Oj8Af0k/VL9if3H/Q3+WP6o/vv+UP+n//3/UgClAPUAQQGIAcsBBwI9Am0ClgK4AtMC5wL0AvsC/AL4" +
  b"Au4C3wLMArUCmwJ/AmACQAIfAv0B2wG6AZoBegFcAUABJQENAfYA4QDPAL4ArwChAJUAigCAAHcAbwBoAGEAWwBWAF" +
  b"EATABIAEQAQQA+ADoAOAA1ADIALwAsACkAJQAhAB0AGQAVABAACwAFAP//+P/x/+r/4v/a/9L/yv/B/7n/sP+o/6D/" +
  b"mP+Q/4j/gf97/3X/cP9s/2j/Zf9i/2H/YP9g/2H/Y/9m/2n/bf9y/3j/fv+E/4v/kv+Z/6H/qP+w/7b/vf/D/8n/z/" +
  b"/T/9b/2P/Z/9j/1v/T/87/yP/A/7f/rP+e/4//fv9s/1f/Qf8q/xL/+f7g/sX+qf6N/m/+Uf40/hX+9/3Z/br9n/2D" +
  b"/Wn9Uf05/ST9Ev0C/fX87Pzl/OH84fzl/Ov89vwF/RT9J/07/U79Yf1y/YD9jP2T/ZX9kv2H/Xb9Xv0+/RT95Pyr/G" +
  b"r8I/zU+337H/u5+kz62vlj+ej4avjs92/38vZ69gf2mfU09db0gvQ89AP02PPA87jzxPPh8xD0U/Sp9BX1l/Uv9t72" +
  b"ovd9+G/5dvqW+8v8GP52//AAfAIhBOAFpgeVCYkLng1BEAgTwhWeGGsbOx4LIcgjgSYfKawrHy5zMKwyujSoNmY4+T" +
  b"lhO5M8mT1nPv4+YD+FP3c/MD+wPvw9ED3rO5I6BDlAN001KTPXMFousyvlKPIl3SKoH1Yc7RhqFdkROg6PCuIGMQOF" +
  b"/977QPiv9CzxvO1g6hrn7uPc4OvdGdtn2NrVcdMt0RHPHs1Vy7jJRsgCx+zFAsVJxL3DYMM1wzbDasPKw1rEGcUFxi" +
  b"DHZ8jayXrLQ803z1LRldP91YrYO9sN3gHhE+RB54nq6+1h8er0hfgs/OH/nwNhBycL7Q6xEm8WJBrOHWgh8CRkKL8r" +
  b"AC8jMiY1BTi9Ok09sD/lQehDuEVTR7VI30nPSoFL90stTCRM20tSS4dKfUkxSKVG20TRQotACT5NO1k4LzXRMUMuhi" +
  b"qeJo8iXB4IGpcVDxFyDMUHDgNP/o/50vQe8Hfr4uZl4gjeztm81djRJM6kyl3HTsR7wee+kbx9uqy4HbfQtci0A7SA" +
  b"s0GzRbOJsw200LTRtQ23hLgyuha8Lr54wPDClsVnyF7LfM680RvVltgs3NrfnONv51DrPu808zD3L/su/yoDIgcQC/" +
  b"UOzBKTFkga6R1xIeEkNShsK4IudzFINPM2djnPO/89AUDWQXxD8EQ0RkVHI0jNSEJJgkmNSWFJAElqSJ1Hm0ZjRfdD" +
  b"V0KDQHw+RTzdOUY3gjSRMXcuNSvMJ0AkkSDCHNkY1RS5EIoMSgj7A6P/Q/vf9nvyGu7B6XLlM+EG3e/Y9NQW0VvNx8" +
  b"lfxirDK8BnveK6n7ihtum0ebNUsnqx67CpsLKwBbGksY2yvLMzte626rgnu6C9UsA9w1rGp8khzcPQitRz2Hncl+DL" +
  b"5A/pYe278Rr2evrX/iwDdweyC9wP7xPoF8Ubgx8dI5Im3ykBLfYvvjJUNbk36jnlO6w9PD+TQLNBm0JLQ8JDAkQLRN" +
  b"xDd0PeQhFCEEHfP30+7TwxO0o5OTcDNacyKDCKLc0q9CcCJfgh2h6qG2kYGhXBEV8O9gqKBxsErQBC/dv5fPYm89vv" +
  b"nuxu6VHmR+NQ4HHdq9r912vV9tKg0GrOVsxlypfI8MZwxRnE68LrwRrBfMASwN6/4r8fwJXARcEtwlHDrcRBxg3ID8" +
  b"pFzKzORNEL1PzWFtpW3bfgOeTV54rrVO8u8xX3Bfv5/u0C3wbKCqkOehI3Ft4Zah3ZICYkUCdRKiYtzi9GMos0nDZ1" +
  b"OBU6fDunPJU9Rz67PvE+6j6kPiE+Yz1oPDM7xjkiOEk2PjQCMpgvAy1GKmMnXiQ7Ifsdoxo3F7kTLRCXDPoIWgW7AR" +
  b"/+jPoD94jzH/DL7I7pa+Zl43/gu90a26DYTdYk1CXSU9CuzjbN7MvTyufJK8meyEHIEcgPyDvIlMgXycTJm8qYy7zM" +
  b"Bc5uz/nQpNJr1FHWUthv2qfc+N5i4ePje+Yn6ebrtu6X8Yb0gfeH+pb9qgDDA94G+QkQDSQQLxMvFiQZChzdHpwhQy" +
  b"TQJkEpkyvDLc4vtDFwMwE1ZTabN584cTkPOnk6rDqpOm46+zlROW44UjcBNng0ujLGMKAuSCzAKQonKSQeIe0dmBoi" +
  b"F44T4A8bDEIIWQRlAGn8aPhn9GrwdOyL6LHk6+A+3avZN9bn0r3PvMzpyUbH1sSbwpjA0L5Evfa76Lobuo+5R7lAuX" +
  b"25/rnBusS7Cb2Nvk/ATMKDxPDGk8lnzGrPmNLt1WfZAt244Ibkaehb7FnwXfRj+Gn8agBhBEwIJwzrD5cTJxeWGuAd" +
  b"AiH4I78mVCmzK9otxS9zMeIyEDT7NKE1BDYiNvs1kDXhNPEzwDJSMagvxy2wK2gp9CZYJJkhux7GG70YphWJEmoPTw" +
  b"w+CT0GUgOAAM79Qfvb+KL2mfTD8iHxtu+E7ortyuxD7PTr2+v360Xsw+xt7T/uN+9P8ITx0vIy9KH1G/ec+B36nPsV" +
  b"/YT+5f82AXQCnAOsBKQFgQZDB+kHcwjiCDYJcQmSCZwJkAlxCT8J/QitCFII7QeBBw8HmgYjBqwFNwXGBFgE8QOPAz" +
  b"UD4gKXAlMCFgLhAbIBigFmAUYBKwETAf0A6wDbAM0AwAC2AKwApACdAJcAkgCMAIgAgwB+AHkAdABvAGkAYwBcAFQA" +
  b"TABDADkALgAiABUACAD6/+v/3P/N/73/rf+d/43/fv9v/2D/Uv9F/zn/L/8l/xz/Ff8P/wv/B/8G/wb/B/8J/w3/Ev" +
  b"8Y/x//J/8w/zn/Q/9N/1f/Yf9q/3P/e/+C/4j/jf+Q/5H/j/+L/4T/ev9t/13/S/80/xv//v7d/rn+kf5m/jj+B/7U" +
  b"/Z79Z/0v/fT8uPx7/Dz8/vvA+4H7RPsI+836lvph+i/6A/rZ+bT5lvl8+Wn5XflX+Vj5Yfly+Yn5qfnQ+fv5Kvpc+o" +
  b"v6ufri+gP7HPsq+yr7G/v7+sj6gvon+rX5LvmR+N33Fvc59kf1QvQr8wLyy/CJ7z3u6uyW60Lq8+iu53XmSuU15Dbj" +
  b"UuKQ4fHgeOAs4A7gIeBl4NvgiOFr4ofj3+Ry5kLoS+qS7BXv0fHI9Pn3Yfv8/s8C0gYHC24P8ROtGIQdgyL/J58tOj" +
  b"PzOJg+NkTFSTFPglSgWY9eQ2O0Z+Frum9Dc212OHmke6N9PH//f/9//3//f/9/cn/nfe17gnmmdl9zrm+UaxpnQWIO" +
  b"XYlXslGTSzBFjj61N6sweCkhIrIaMBOlCx0EnPwu9djtoOaO36XY7dFnyxrFCb83uauzZa5nqbWkUaA7nHeYBZXokS" +
  b"KPsYyZitmIcYdjhq2FUoVRhaiFW4Zmh8mIhYqYjAOPw5HYlEKY/psMoGmkE6kJrkiz0LicvqvE+cqC0UPYOd9e5qzt" +
  b"IvW4/GwENgwQFPYb4SPMK68zhTtGQ+1KclLOWfxg9Gewbip1WXv/f/9//3//f/9//3//f/9//3//f/9//3//f/9//3" +
  b"//f/9//3//f/9//3//f/9//3//f9Z6v3M1bD1k3lsdUwRKm0DpNvcs0CJ9GAgOfAPk+EruuuNB2enOvsTPuiqx26fs" +
  b"nmiWWI7BhgCAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAkIPriZaQjJfEnj" +
  b"qm6K3HtdG9AcZQzrfWMt+650jw2fhlAecJWxK5Gv4iJCsmMwE7rUIoSmxRdlhCX8tlDWwFcq93CH3/f/9//3//f/9/" +
  b"/3//f/9//3//f/9//3//f/9//3//f/9//3//f/9//3//f/9//3//f4N94nfgcYFrxmSzXU5WmU6ZRlQ+zzUOLRkk9B" +
  b"qnETkIsP4T9WzrwOEa2IDO/MSXu1qyTql9oO+XsI/Nh1KAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAA" +
  b"gACAAIAAgACAAIAAgACARIW4jImUr5wgpdStwrbgvybJitIC3IblDe+N+P0BVguPFKAdgCYoL5I3tj+NRxNPQVYSXY" +
  b"JjjGktb2F0Jnl4ff9//3//f/9//3//f/9//3//f/9//3//f/9//3//f/9//3+aftl6yXZtcsht4Gi5Y1hewVj6UgVN" +
  b"6UaqQEo60DNALZ4m7R8zGXISrgvsBC7+effQ8DbqruM73eLWpdCGyonEs74EuYCzK64IqRmkZJ/pmq6WtJIAj5eLe4" +
  b"i0hUmDQIEAgACAAIAAgACAAIAAgN2A74J8hYKI/ovvj1CUIJlYnvWj8alHsO+25L0exZbMRdQi3CTkRex69Lv8/wQ/" +
  b"DW8ViR2CJVIt8jRYPH1DWkrlUBlX71xhYmhnAWwlcNFzAnezeeR7kX26fl1/fH8Vfyx+wXzWem94j3U6cnVuRGqtZb" +
  b"VgZFvAVc5PmEkjQ3g8nTWdLn0nRSD+GLARYQobA+X7xfTD7eXmM+Cy2WjTW82QxwrC0Lzjt0izAq8Tq32nQaRiod6e" +
  b"uJzumoCZbpi2l1eXT5eblzuYKplmmu2bvJ3NnyCisKR4p3aqp60IsZm0V7hCvFnAmsQDyZTNStIj1x/cOuF05sjrNf" +
  b"G49k/89AGmB2INIhPkGKIeWSQCKpwvIDWIOtE/80TrSbJORFOaV69bf18DYzdmF2mda8Vti2/scORxb3KMcjhycnE5" +
  b"cIpuZ2zQacZmSWNcXwFbO1YOUX5Lj0VFP6g4vDGHKhMjZBuDE3cLSQMC+6nySOro4ZHZTNEkySHBS7mssUuqMqNpnP" +
  b"eV4481ivSEJYAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAWYSbiU2PapXqm8ai9qlysTO5LcFZya7R" +
  b"Idqp4jzr"

///|
test "mp4 muxer: Opus track decodes against FFmpeg PCM" {
  let packet = @libavutil.av_base64_decode(mp4_opus_packet_b64, 10000).unwrap()
  let mux = mp4_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  let track = movie.tracks[0]
  let head = @libavcodec.opus_parse_head(track.extradata.unwrap()).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let out : Array[Float] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let pkt = bytes[start:end].to_owned()
    let (pcm, n) = dec.decode_packet(Some(pkt)).unwrap()
    for i = 0; i < n; i = i + 1 {
      out.push(pcm[0][i])
    }
  }
  assert_eq(out.length(), 2880)
  let reference = @libavutil.av_base64_decode(mp4_opus_ref_pcm_b64, 16384).unwrap()
  assert_eq(reference.length(), 5136)
  let mut max_diff = 0
  for i = 0; i < 2568; i = i + 1 {
    let v = out[i + 312].to_double() * 32768.0
    let q = if v >= 32767.5 {
      32767
    } else if v <= -32768.5 {
      -32768
    } else {
      v.round().to_int()
    }
    let start = 2 * i
    let want = reference[start].to_int() | (reference[start + 1].to_int() << 8)
    let want = if want >= 32768 { want - 65536 } else { want }
    let diff = if q > want { q - want } else { want - q }
    if diff > max_diff {
      max_diff = diff
    }
  }
  assert_true(max_diff <= 1, msg="Opus PCM max diff \{max_diff}")
}
