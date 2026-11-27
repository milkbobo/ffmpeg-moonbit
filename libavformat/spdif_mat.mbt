///|
/// TrueHD MAT assembly adapted from FFmpeg `libavformat/spdifenc.c`
/// (LGPL-2.1-or-later, copyright Bartlomiej Wolowiec, Anssi Hannula,
/// and Carl Eugen Hoyos).
let spdif_mat_burst_size : Int = 61440

///|
let spdif_mat_payload_size : Int = 61424

///|
let spdif_mat_markers : Array[(Int, Bytes)] = [
  (0, b"\x07\x9e\x00\x03\x84\x01\x01\x01\x80\x00\x56\xa5\x3b\xf4\x81\x83\x49\x80\x77\xe0"),
  (30708, b"\xc3\xc1\x42\x49\x3b\xfa\x82\x83\x49\x80\x77\xe0"),
  (spdif_mat_payload_size - 16, b"\xc3\xc2\xc0\xc4\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x97\x11"),
]

///|
fn spdif_mux_truehd(data : Bytes, big_endian : Bool) -> Result[Bytes, String] {
  let out : Array[Byte] = []
  let mut mat : Array[Byte] = []
  let mut marker_index = 0
  let mut samples_per_unit = 0
  let mut previous_timing = 0
  let mut previous_size = 0
  let mut pos = 0
  while pos < data.length() {
    let size = @libavcodec.mlp_access_unit_size(data[pos:])
    guard size >= 10 && size <= data.length() - pos else {
      return Err("spdif: invalid or truncated TrueHD access unit")
    }
    let unit = data[pos:pos + size]
    if unit[4:7] == b"\xf8\x72\x6f"[:] {
      guard unit[7] == 0xba else { return Err("spdif: expected TrueHD major sync") }
      let rate_bits = unit[8].to_int() >> 4
      guard (rate_bits & 7) <= 2 else { return Err("spdif: invalid TrueHD sample rate") }
      samples_per_unit = 40 << (rate_bits & 3)
    }
    guard samples_per_unit > 0 else { return Err("spdif: TrueHD must begin at a major sync") }
    let timing = wav_u16(unit, 2, true)
    let mut padding = 0
    if previous_size > 0 {
      // The 16-bit input timing wraps. Each nominal access unit occupies
      // 2560 carrier bytes regardless of the TrueHD sample-rate family.
      let elapsed = (timing - previous_timing) & 0xffff
      let missing = elapsed * 2560 / samples_per_unit - previous_size
      if missing >= 0 && missing < spdif_mat_payload_size / 2 {
        padding = missing
      }
    }
    let mut offset = 0
    let mut accounted_size = size
    while padding > 0 || offset < size || mat.length() == spdif_mat_markers[marker_index].0 {
      let (position, marker) = spdif_mat_markers[marker_index]
      if mat.length() == position {
        mat.append(marker.to_array())
        let mut carrier_bytes = marker.length()
        marker_index += 1
        if marker_index == spdif_mat_markers.length() {
          let payload = Bytes::from_array(mat)
          match spdif_write_burst(out, payload[:], 0x16, big_endian~) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          mat = []
          marker_index = 0
          // Include the IEC 61937 preamble and the gap between MAT payloads.
          carrier_bytes += spdif_mat_burst_size - spdif_mat_payload_size
        }
        let padding_used = padding.min(carrier_bytes)
        padding -= padding_used
        accounted_size += carrier_bytes - padding_used
      } else if padding > 0 {
        let count = padding.min(position - mat.length())
        for _ in 0..<count {
          mat.push(0)
        }
        padding -= count
      } else {
        let count = (size - offset).min(position - mat.length())
        for byte in unit[offset:offset + count] {
          mat.push(byte)
        }
        offset += count
      }
    }
    previous_timing = timing
    previous_size = accounted_size
    pos += size
  }
  guard !out.is_empty() else { return Err("spdif: no complete TrueHD MAT burst") }
  Ok(Bytes::from_array(out))
}
