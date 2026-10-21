///|
/// Tests for the WAV/RIFF demuxer slice.
///
/// The three real files were produced by `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=0.01" \
///          -ac 2 -c:a pcm_s16le wav_s16t.wav
///   ffmpeg -f lavfi -i "sine=frequency=500:sample_rate=22050:duration=0.02" \
///          -ac 1 -c:a pcm_f32le wav_f32t.wav
///   ffmpeg -f lavfi -i "sine=frequency=500:sample_rate=8000:duration=0.1" \
///          -ac 1 -c:a pcm_s24le wav_s24s.wav
///
/// Expected packet rows are `ffprobe -show_packets`; the `pcm_s24le` file is
/// WAVE_FORMAT_EXTENSIBLE (0xFFFE) with a 40-byte `fmt ` chunk and no `fact`
/// chunk, while the float file carries a `fact` chunk.

///|
/// 1842-byte PCM s16le stereo 44.1 kHz (0.01 s). */
let wav_s16t_b64 : Bytes = bcat([
  b"UklGRioHAABXQVZFZm10IBAAAAABAAIARKwAABCxAgAEABAATElTVBoAAABJTkZPSVNGVA0AAABMYXZmNjMuMS4xMDIAAGRhdGHk",
  b"BgAAAAAAAJsBmwEuAy4DsASwBBoGGgZlB2UHiQiJCIAJgAlHCkcK2ArYCjALMAtQC1ALNAs0C94K3gpQClAKjAmMCZYIlgh0B3QH",
  b"LAYsBsQExARCA0IDsAGwARUAFQB6/nr+5/zn/GP7Y/v3+ff5q/ir+IX3hfeL9ov2wvXC9S71LvXS9NL0sPSw9Mn0yfQd9R31qPWo",
  b"9Wr2avZc91z3fPh8+MP5w/kq+yr7qvyq/Dv+O/7W/9b/cgFyAQYDBgOKBIoE9wX3BUUHRQdtCG0IaglqCTUKNQrMCswKKwsrC08L",
  b"Tws5CzkL6QrpCmAKYAqiCaIJsQixCJMHkwdOBk4G6QTpBGkDaQPYAdgBPgA+AKP+o/4O/Q79ifuJ+xr6GvrL+Mv4ofeh96L2ovbU",
  b"9dT1OvU69dn02fSx9LH0xPTE9BL1EvWY9Zj1VPZU9kL3Qvde+F74ofmh+QX7BfuD/IP8E/4T/q3/rf9JAUkB3gLeAmQEZATUBdQF",
  b"JQclB1IIUghSCVIJIwojCr8KvwokCyQLTgtOCz4LPgv0CvQKcQpxCrcJtwnLCMsIsQexB3AGcAYNBQ0FkQORAwECAQJnAGcAy/7L",
  b"/jb9Nv2v+6/7Pvo++uv46/i897z3ufa59ub15vVH9Uf14PTg9LP0s/TA9MD0B/UH9Yf1h/U/9j/2KPco9z/4P/h/+X/54Prg+lz8",
  b"XPzr/ev9hP+E/yABIAG2ArYCPwQ/BLEFsQUFBwUHNQg1CDsJOwkRChEKsgqyChwLHAtNC00LQgtCC/4K/gqACoAKzAnMCeUI5QjQ",
  b"B9AHkgaSBjMFMwW4A7gDKgIqApEAkQD1/vX+Xf1d/dT71Pth+mH6C/kL+dn32ffR9tH2+fX59VX1VfXo9Oj0tfS19Lz0vPT+9P70",
  b"efV59Sr2KvYO9w73Ifgh+F35Xfm8+rz6NPw0/ML9wv1b/1v/9wD3AI4CjgIYBBgEjQWNBeQG5AYZCBkIIwkjCf4J/gmkCqQKFAsU",
  b"C0sLSwtGC0YLBwsHC48KjwrgCeAJ/gj+CO0H7QezBrMGVwVXBd8D3wNSAlICugC6AB7/Hv+G/Yb9+/v7+4b6hvos+Sz59vf29+r2",
  b"6vYM9gz2Y/Vj9fD08PS39Lf0uPS49PT09PRq9Wr1FvYW9vb29vYE+AT4PPk8+Zf6l/oO/A78mv2a/TL/Mv/OAM4AZgJmAvID8gNo",
  b"BWgFxAbEBvsH+wcKCQoJ6gnqCZYKlgoMCwwLSAtIC0kLSQsQCxALnQqdCvQJ9AkXCRcJCggKCNUG1QZ7BXsFBgQGBHoCegLjAOMA",
  b"R/9H/679rv0i/CL8qvqq+k35TfkT+BP4AvcC9yD2IPZx9XH1+fT59Lr0uvS19LX07PTs9Fz1XPUC9gL23fbd9uf35/cb+Rv5c/pz",
  b"+uf75/tx/XH9Cf8J/6UApQA9Aj0CywPLA0QFRAWiBqIG3wffB/II8gjWCdYJhwqHCgILAgtEC0QLSwtLCxgLGAurCqsKBwoHCi8J",
  b"LwknCCcI9Qb1Bp8FnwUsBCwEowKjAgwBDAFw/3D/1v3W/Un8SfzO+s76bvlu+TD4MPgb9xv3NfY19oD1gPUC9QL1vvS+9LP0s/Tk",
  b"9OT0TfVN9e/17/XF9sX2y/fL9/v4+/hP+k/6wfvB+0n9Sf3g/uD+ewB7ABQCFAKjA6MDIAUgBYEGgQbBB8EH2AjYCMEJwQl4CngK",
  b"+Qr5CkALQAtNC00LIAsgC7kKuQobChsKRwlHCUQIRAgWBxYHwwXDBVIEUgTLAssCNQE1AZn/mf///f/9cPxw/PP68/qQ+ZD5T/hP",
  b"+DX3NfdJ9kn2kPWQ9Qz1DPXC9ML0svSy9Nz03PRB9UH13fXd9a32rfau96732vja+Cv6K/qb+5v7If0h/bb+tv5SAFIA7AHsAXwD",
  b"fAP6BPoEXwZfBqIHoge+CL4IrAmsCWgKaAruCu4KPAs8C08LTwsnCycLxgrGCiwKLApeCV4JYAhgCDYHNgfmBeYFeAR4BPIC8gJe",
  b"AV4Bwv/C/yj+KP6X/Jf8GPsY+7L5svlt+G34T/dP91/2X/ag9aD1F/UX9cf0x/Sx9LH01fTV9DT1NPXL9cv1lvaW9pP3k/e7+Lv4",
  b"CfoJ+nb7dvv6/Pr8jf6N/ikAKQDEAcQBVQNVA9UE1QQ9Bj0GgweDB6MIowiWCZYJVwpXCuMK4wo2CzYLUAtQCy4LLgvSCtIKPwo/",
  b"CnYJdgl7CHsIVQdVBwoGCgaeBJ4EGgMaA4cBhwHr/+v/Uf5R/r78vvw9+z371PnU+Yz4jPhq92r3dPZ09rD1sPUi9SL1zPTM9LD0",
  b"sPTP9M/0KPUo9bn1ufWA9oD2d/d395v4m/jl+eX5T/tP+9H80fxk/mT+",
])

///|
/// 1856-byte PCM f32le mono 22.05 kHz (0.02 s). */
let wav_f32t_b64 : Bytes = bcat([
  b"UklGRjgHAABXQVZFZm10IBIAAAADAAEAIlYAAIhYAQAEACAAAABmYWN0BAAAALkBAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2",
  b"My4xLjEwMgAAZGF0YeQGAAAAAAAAAECRPADgDz0AIFQ9ABCKPQBQpz0AIME9AADXPQCQ6D0AYPU9ADD9PQDw/z0AgP09AOD1PQBQ",
  b"6T0AANg9AFDCPQCwqD0AoIs9AKBXPQCAEz0AwJg8AABwOgAAirwAQAy9AMBQvQCQiL0A8KW9AOC/vQAA1r0AwOe9AND0vQDw/L0A",
  b"8P+9AMD9vQBg9r0AEOq9APDYvQCAw70AEKq9ADCNvQDgWr0AABe9AACgvAAA7LoAwII8AOAIPQCATT0AAIc9AICkPQCwvj0AANU9",
  b"AADnPQBQ9D0AsPw9AOD/PQDw/T0A4PY9AMDqPQDw2T0AsMQ9AGCrPQCwjj0AIF49AGAaPQAApzwAADA7AAB3vABABb0AIEq9AHCF",
  b"vQAQo70AcL29APDTvQAw5r0AwPO9AGD8vQDg/70AMP69AFD3vQCA670A4Nq9ANDFvQDArL0AMJC9AGBhvQDgHb0AQK68AABquwCA",
  b"aDwAwAE9AMBGPQDggz0AsKE9AEC8PQDw0j0AYOU9ADDzPQAQ/D0A0P89AGD+PQDQ9z0AQOw9ANDbPQDwxj0AEK49ALCRPQCgZD0A",
  b"YCE9AIC1PAAAkjsAgFq8AID8vABgQ70AUIK9AECgvQAAu70A8NG9AJDkvQCg8r0AwPu9AMD/vQCQ/r0AQPi9APDsvQDA3L0AIMi9",
  b"AHCvvQAwk70AAGi9AMAkvQCAvLwAAK+7AABMPACA9TwAIEA9AMCAPQDgnj0AwLk9AODQPQDA4z0AAPI9AGD7PQCw/z0AwP49ALD4",
  b"PQCQ7T0AsN09AEDJPQDAsD0AsJQ9AEBrPQBAKD0AwMM8AADNOwAAPbwAgO68AMA8vQBgfr0AcJ29AIC4vQDQz70A8OK9AHDxvQAQ",
  b"+70AkP+9APD+vQAg+b0AQO69AJDevQBgyr0AELK9ADCWvQBgbr0AwCu9AADLvAAA6rsAgC48AEDnPABAOT0AIHs9APCbPQBAtz0A",
  b"wM49ABDiPQDQ8D0AsPo9AID/PQAQ/z0AkPk9APDuPQBw3z0AgMs9AGCzPQCglz0AoHE9ACAvPQAA0jwAgAM8AAAgvAAA4LwA4DW9",
  b"AOB3vQCAmr0A8LW9AKDNvQAw4b0AMPC9AFD6vQBg/70AQP+9APD5vQCQ770AYOC9AJDMvQCwtL0AEJm9AOB0vQCAMr0AQNm8AAAS",
  b"vACAETwAANk8AIAyPQDAdD0AEJk9AKC0PQCQzD0AUOA9AJDvPQDw+T0AQP89AGD/PQBQ+j0AMPA9ADDhPQCwzT0A8LU9AJCaPQAA",
  b"eD0AADY9AEDgPACAIDwAAAO8AADSvAAAL70AgHG9AJCXvQBQs70AcMu9AHDfvQDg7r0AgPm9ABD/vQCA/70AsPq9ANDwvQAQ4r0A",
  b"wM69AEC3vQAAnL0AIHu9AGA5vQCA57wAAC+8AADpOwDAyjwAoCs9AGBuPQAglj0AELI9AGDKPQCQ3j0AQO49ACD5PQDw/j0AkP89",
  b"ABD7PQBw8T0A8OI9ANDPPQCAuD0AcJ09AGB+PQDAPD0AwO48AIA9PAAAzLsAwMO8ACAovQAga70AsJS9AMCwvQBAyb0AoN29AJDt",
  b"vQCw+L0AwP69ALD/vQBg+70AEPK9AMDjvQDg0L0AwLm9AOCevQDQgL0AIEC9AMD1vAAATLwAAK47AEC8PACgJD0A4Gc9ADCTPQBw",
  b"rz0AIMg9AMDcPQDg7D0AQPg9AJD+PQDA/z0AwPs9AKDyPQCg5D0A8NE9AAC7PQBQoD0AYII9AIBDPQDA/DwAgFo8AACRuwBAtbwA",
  b"QCG9AIBkvQCgkb0AEK69APDGvQDQ270AMOy9AND3vQBg/r0A0P+9ABD8vQAw870AYOW9AADTvQBAvL0AwKG9APCDvQDgRr0A4AG9",
  b"AABpvAAAaDsAAK48AMAdPQBAYT0AIJA9ALCsPQDQxT0A4No9AIDrPQBQ9z0AMP49AOD/PQBg/D0AwPM9ADDmPQAA1D0AgL09ACCj",
  b"PQBwhT0AQEo9AGAFPQCAdzwAAC67AACnvABgGr0AAF69AKCOvQBgq70AoMS9AODZvQDA6r0A4Pa9APD9vQDg/70AsPy9AFD0vQAA",
  b"570AANW9ALC+vQCApL0AAIe9AIBNvQDgCL0AAIO8AADoOgDAnzwA4BY9AMBaPQAgjT0AAKo9AHDDPQDw2D0AAOo9AGD2PQCw/T0A",
  b"8P89APD8PQDg9D0A0Oc9ABDWPQDwvz0A8KU9AKCIPQDgUD0AYAw9AECKPAAAaLoAgJi8AGATvQCAV70AoIu9ALCovQBQwr0AANi9",
  b"AFDpvQDg9b0AgP29APD/vQBA/b0AYPW9AJDovQAA170AIMG9AFCnvQAgir0AQFS9AAAQvQCAkbw=",
])

///|
/// 2502-byte WAVE_FORMAT_EXTENSIBLE PCM s24le mono 8 kHz (0.1 s). */
let wav_s24s_b64 : Bytes = bcat([
  b"UklGRr4JAABXQVZFZm10ICgAAAD+/wEAQB8AAMBdAAADABgAFgAYAAQAAAABAAAAAAAQAIAAAKoAOJtxTElTVBoAAABJTkZPSVNG",
  b"VA0AAABMYXZmNjMuMS4xMDIAAGRhdGFgCQAAAAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5",
  b"AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAA",
  b"AOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8G",
  b"AFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0",
  b"ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcO",
  b"AP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHw",
  b"ADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcO",
  b"AFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0",
  b"AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8G",
  b"AAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAA",
  b"AB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5",
  b"ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFAL",
  b"AMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnx",
  b"AAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8P",
  b"AMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnx",
  b"ALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFAL",
  b"AB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5",
  b"AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAA",
  b"AOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8G",
  b"AFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0",
  b"ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcO",
  b"AP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHw",
  b"ADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcO",
  b"AFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0",
  b"AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8G",
  b"AAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAA",
  b"AB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5",
  b"ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFAL",
  b"AMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnx",
  b"AAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8P",
  b"AMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnx",
  b"ALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFALAB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5AAAAAB8GAFALAMcOAP8PAMcOAFAL",
  b"AB8GAAAAAOH5ALD0ADnxAAHwADnxALD0AOH5",
])

///|
fn wav_u16le(v : Int32) -> Array[Byte] {
  [(v & 0xFF).to_byte(), ((v >> 8) & 0xFF).to_byte()]
}

///|
fn wav_u32le(v : Int64) -> Array[Byte] {
  [
    (v & 0xFFL).to_int().to_byte(),
    ((v >> 8) & 0xFFL).to_int().to_byte(),
    ((v >> 16) & 0xFFL).to_int().to_byte(),
    ((v >> 24) & 0xFFL).to_int().to_byte(),
  ]
}

///|
fn wav_u64le(v : Int64) -> Array[Byte] {
  let lo = wav_u32le(v & 0xFFFFFFFFL)
  let hi = wav_u32le(v >> 32)
  lo + hi
}

///|
fn wav_bytes(parts : Array[Array[Byte]]) -> Bytes {
  let out : Array[Byte] = []
  for p in parts {
    out.append(p)
  }
  Bytes::from_array(out)
}

///|
/// Build a canonical little-endian RIFF/WAVE file with a PCM `fmt ` chunk.
fn wav_build_pcm(
  fmt_tag : Int32,
  channels : Int32,
  sample_rate : Int32,
  bits : Int32,
  data : Bytes,
) -> Bytes {
  let block_align = channels * ((bits + 7) / 8)
  let fmt_body = wav_bytes([
    wav_u16le(fmt_tag),
    wav_u16le(channels),
    wav_u32le(sample_rate.to_int64()),
    wav_u32le(sample_rate.to_int64() * block_align.to_int64()),
    wav_u16le(block_align),
    wav_u16le(bits),
  ])
  let riff_size = 4 + 8 + fmt_body.length() + 8 + data.length()
  let parts : Array[Array[Byte]] = [
    b"RIFF".to_array(),
    wav_u32le(riff_size.to_int64()),
    b"WAVE".to_array(),
    b"fmt ".to_array(),
    wav_u32le(16L),
    fmt_body.to_array(),
    b"data".to_array(),
    wav_u32le(data.length().to_int64()),
    data.to_array(),
  ]
  wav_bytes(parts)
}

///|
test "wav: real ffmpeg pcm_s16le (plain WAVE_FORMAT_PCM)" {
  let bytes = @libavutil.av_base64_decode(wav_s16t_b64, 100000).unwrap()
  assert_true(av_wav_probe(bytes))
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.codec, "pcm_s16le")
  assert_eq(wav.format.channels, 2)
  assert_eq(wav.format.sample_rate, 44100)
  assert_eq(wav.format.bits_per_sample, 16)
  assert_eq(wav.format.block_align, 4)
  assert_eq(wav.format.bit_rate, 1411200)
  assert_eq(wav.data_offset, 78L)
  assert_eq(wav.data_size, 1764L)
  assert_eq(wav.sample_count, 441L)
  assert_eq(wav.max_size, 16384)
  assert_eq(wav.packets.length(), 1)
  assert_eq(wav.packets[0].pos, 78L)
  assert_eq(wav.packets[0].size, 1764)
  assert_eq(wav.packets[0].pts, 0L)
  assert_eq(wav.packets[0].duration, 441)
}

///|
test "wav: real ffmpeg pcm_f32le (fact chunk)" {
  let bytes = @libavutil.av_base64_decode(wav_f32t_b64, 100000).unwrap()
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.codec, "pcm_f32le")
  assert_eq(wav.format.channels, 1)
  assert_eq(wav.format.sample_rate, 22050)
  assert_eq(wav.format.bits_per_sample, 32)
  assert_eq(wav.format.block_align, 4)
  assert_eq(wav.format.bit_rate, 705600)
  // fmt(18+6 pad) + fact + LIST ... data body starts at 92.
  assert_eq(wav.data_offset, 92L)
  assert_eq(wav.data_size, 1764L)
  assert_eq(wav.sample_count, 441L)
  assert_eq(wav.packets.length(), 1)
  assert_eq(wav.packets[0].pos, 92L)
  assert_eq(wav.packets[0].size, 1764)
  assert_eq(wav.packets[0].duration, 441)
}

///|
test "wav: real ffmpeg pcm_s24le (WAVE_FORMAT_EXTENSIBLE)" {
  let bytes = @libavutil.av_base64_decode(wav_s24s_b64, 100000).unwrap()
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.format_tag, 1)
  assert_eq(wav.format.codec, "pcm_s24le")
  assert_eq(wav.format.channels, 1)
  assert_eq(wav.format.sample_rate, 8000)
  assert_eq(wav.format.bits_per_sample, 24)
  assert_eq(wav.format.block_align, 3)
  assert_eq(wav.format.channel_mask, 4U)
  assert_eq(wav.format.extradata.length(), 0)
  assert_eq(wav.data_offset, 102L)
  assert_eq(wav.data_size, 2400L)
  assert_eq(wav.sample_count, 800L)
  assert_eq(wav.max_size, 1536)
  assert_eq(wav.packets.length(), 2)
  assert_eq(wav.packets[0].pos, 102L)
  assert_eq(wav.packets[0].size, 1536)
  assert_eq(wav.packets[0].pts, 0L)
  assert_eq(wav.packets[0].duration, 512)
  assert_eq(wav.packets[1].pos, 1638L)
  assert_eq(wav.packets[1].size, 864)
  assert_eq(wav.packets[1].pts, 512L)
  assert_eq(wav.packets[1].duration, 288)
}

///|
test "wav: multi-packet framing follows max_size and block alignment" {
  // 44.1 kHz stereo s16: bit rate 1411200 -> 4096 samples (16384 bytes)
  // per packet, exactly like ff_pcm_default_packet_size.
  let data = Bytes::make(100000, b'\x00')
  let bytes = wav_build_pcm(1, 2, 44100, 16, data)
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.max_size, 16384)
  assert_eq(wav.sample_count, 25000L)
  // 6 full packets, then a 1696-byte tail (424 samples).
  assert_eq(wav.packets.length(), 7)
  let expected_sizes = [16384, 16384, 16384, 16384, 16384, 16384, 1696]
  let mut pts = 0L
  for i, p in wav.packets {
    assert_eq(p.size, expected_sizes[i])
    assert_eq(p.pts, pts)
    assert_eq(p.duration, p.size / 4)
    pts = pts + p.duration.to_int64()
  }
  assert_eq(pts, 25000L)
}

///|
test "wav: RIFX big-endian header" {
  let data = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a"
  let fmt_body = wav_bytes([
    [0x00, 0x01], // tag 1, big endian
    [0x00, 0x01], // mono
    [0x00, 0x00, 0x1F, 0x40], // 8000
    [0x00, 0x00, 0x1F, 0x40], // 8000 bytes/s
    [0x00, 0x01], // block align
    [0x00, 0x08], // 8 bits
  ])
  let riff_size = 4 + 8 + 16 + 8 + data.length()
  let bytes = wav_bytes([
    b"RIFX".to_array(),
    [
      ((riff_size >> 24) & 0xFF).to_byte(),
      ((riff_size >> 16) & 0xFF).to_byte(),
      ((riff_size >> 8) & 0xFF).to_byte(),
      (riff_size & 0xFF).to_byte(),
    ],
    b"WAVE".to_array(),
    b"fmt ".to_array(),
    [0x00, 0x00, 0x00, 0x10],
    fmt_body.to_array(),
    b"data".to_array(),
    [0x00, 0x00, 0x00, 0x0A],
    data.to_array(),
  ])
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.codec, "pcm_u8")
  assert_eq(wav.format.channels, 1)
  assert_eq(wav.format.sample_rate, 8000)
  assert_eq(wav.format.block_align, 1)
  assert_eq(wav.data_offset, 44L)
  assert_eq(wav.data_size, 10L)
  assert_eq(wav.packets.length(), 1)
  assert_eq(wav.packets[0].duration, 10)
}

///|
test "wav: RF64 uses ds64 sizes for an all-ones data chunk" {
  let data = Bytes::make(16, b'\x00')
  let fmt_body = wav_bytes([
    wav_u16le(1),
    wav_u16le(1),
    wav_u32le(8000L),
    wav_u32le(16000L),
    wav_u16le(2),
    wav_u16le(16),
  ])
  // ds64: riff size, data size, sample count, table length.
  let ds64 = wav_bytes([
    wav_u64le(0L),
    wav_u64le(16L),
    wav_u64le(8L),
    wav_u32le(0L),
  ])
  let bytes = wav_bytes([
    b"RF64".to_array(),
    [0xFF, 0xFF, 0xFF, 0xFF],
    b"WAVE".to_array(),
    b"ds64".to_array(),
    wav_u32le(ds64.length().to_int64()),
    ds64.to_array(),
    b"fmt ".to_array(),
    wav_u32le(16L),
    fmt_body.to_array(),
    b"data".to_array(),
    [0xFF, 0xFF, 0xFF, 0xFF],
    data.to_array(),
  ])
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.codec, "pcm_s16le")
  assert_eq(wav.data_size, 16L)
  assert_eq(wav.sample_count, 8L)
  assert_eq(wav.packets.length(), 1)
  assert_eq(wav.packets[0].size, 16)
  assert_eq(wav.packets[0].duration, 8)
}

///|
test "wav: odd-sized chunk padding is skipped" {
  let data = Bytes::make(8, b'\x7f')
  let base = wav_build_pcm(1, 1, 8000, 8, data)
  // Insert a 3-byte JUNK chunk (plus pad byte) before the fmt chunk.
  let head = base[0:12].to_owned()
  let rest = base[12:].to_owned()
  let junk = b"JUNK\x03\x00\x00\x00abc\x00"
  let bytes = head + junk + rest
  let wav = av_wav_open(bytes).unwrap()
  assert_eq(wav.format.codec, "pcm_u8")
  assert_eq(wav.data_offset, 12L + 12L + 8L + 16L + 8L)
  assert_eq(wav.data_size, 8L)
  assert_eq(wav.packets[0].size, 8)
}

///|
test "wav: errors for missing fmt/data and bad headers" {
  match av_wav_open(b"RIFF") {
    Ok(_) => fail("expected short-file error")
    Err(e) => assert_true(e.contains("too short"))
  }
  let no_fmt = wav_bytes([
    b"RIFF".to_array(),
    wav_u32le(4L),
    b"WAVE".to_array(),
    b"data".to_array(),
    wav_u32le(0L),
  ])
  match av_wav_open(no_fmt) {
    Ok(_) => fail("expected missing-fmt error")
    Err(e) => assert_true(e.contains("fmt"))
  }
  let no_data = wav_bytes([
    b"RIFF".to_array(),
    wav_u32le(4L),
    b"WAVE".to_array(),
    b"fmt ".to_array(),
    wav_u32le(16L),
    wav_u16le(1),
    wav_u16le(1),
    wav_u32le(8000L),
    wav_u32le(8000L),
    wav_u16le(1),
    wav_u16le(8),
  ])
  match av_wav_open(no_data) {
    Ok(_) => fail("expected missing-data error")
    Err(e) => assert_true(e.contains("data"))
  }
  assert_false(av_wav_probe(b"RIFFxxxxWAVE"))
}
