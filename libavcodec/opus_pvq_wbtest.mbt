///|
fn opus_pvq_reference_fields(line : String) -> Array[UInt64] {
  let values : Array[UInt64] = []
  let mut number = 0UL
  let mut active = false
  for ch in line {
    if ch is '0'..='9' {
      number = number * 10UL + (ch.to_int() - '0').to_uint64()
      active = true
    } else if active {
      values.push(number)
      number = 0UL
      active = false
    }
  }
  if active { values.push(number) }
  values
}

///|
fn opus_pvq_check_vector(
  md5 : @libavutil.AVMD5, n : Int32, k : Int32, index : UInt32,
) -> Unit raise {
  let vector = opus_pvq_unrank(n, k, index).unwrap()
  assert_eq(vector.pulses.length(), n)
  let mut sum = 0
  let mut norm = 0L
  let bytes : Array[Byte] = []
  for word in [n.reinterpret_as_uint(), k.reinterpret_as_uint(), index] {
    for j in 0..<4 { bytes.push(((word >> (j * 8)) & 255U).to_byte()) }
  }
  for j in 0..<8 { bytes.push(((vector.norm_squared >> (j * 8)) & 255L).to_byte()) }
  for value in vector.pulses {
    sum += value.abs()
    norm += value.to_int64() * value.to_int64()
    for j in 0..<4 { bytes.push(((value >> (j * 8)) & 255).to_byte()) }
  }
  assert_eq(sum, k)
  assert_eq(norm, vector.norm_squared)
  @libavutil.av_md5_update(md5, Bytes::from_array(bytes[:]), bytes.length())
}

///|
test "opus PVQ: all 2000 C codebooks and enumerated vectors" {
  let md5 = @libavutil.av_md5_alloc()
  @libavutil.av_md5_init(md5)
  let mut count = 0
  for line in opus_pvq_sizes_reference {
    let f = opus_pvq_reference_fields(line)
    let n = f[0].to_int()
    let k = f[1].to_int()
    if f[2] > 0xffffffffUL {
      assert_true(opus_pvq_size(n, k) is Err("opus: PVQ codebook exceeds 32 bits"))
      continue
    }
    let size = f[2].to_uint()
    assert_eq(opus_pvq_size(n, k).unwrap(), size)
    if n <= 6 && k <= 5 {
      for index = 0U; index < size; index = index + 1U {
        opus_pvq_check_vector(md5, n, k, index)
        count += 1
      }
    } else {
      for index in [0U, size / 3U, size / 2U, size - 1U] {
        opus_pvq_check_vector(md5, n, k, index)
        count += 1
      }
    }
  }
  assert_eq(count, opus_pvq_vector_count)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_final(md5, digest)
  let hex = "0123456789abcdef"
  let actual = StringBuilder()
  for byte in digest {
    actual.write_char(hex[byte.to_int() >> 4].to_int().unsafe_to_char())
    actual.write_char(hex[byte.to_int() & 15].to_int().unsafe_to_char())
  }
  assert_eq(actual.to_string(), opus_pvq_vector_md5)
}

///|
test "opus CELT: 416 bands and entropy states match original C" {
  let dimensions = [(2,1), (3,5), (8,4), (16,6), (24,4), (48,3), (96,2), (176,1),
    (4,100), (5,80), (12,12), (13,13), (14,13)]
  let mut line = 0
  let mut max_error = 0.0
  for seed in 0..<8 {
    let data = Bytes::from_array([for i in 0..<256 =>
      ((seed * 67 + i * 29 + ((i * i) >> 2)) & 255).to_byte()][:])
    for spread in 0..<4 {
      let rc = opus_rc_init(data).unwrap()
      for j, (n, k) in dimensions {
        let mut blocks = 1 << (j % 4)
        while n % blocks != 0 { blocks = blocks >> 1 }
        let gain : Float = 0.25 * Float::from_int(1 + j % 5)
        let band = rc.decode_celt_band(n, k, spread, blocks, gain).unwrap()
        let f = opus_pvq_reference_fields(opus_pvq_bands_reference[line])
        assert_eq([seed, spread, n, k], [for i in 0..<4 => f[i].to_int()])
        assert_eq(band.collapse_mask, f[4].to_uint())
        assert_eq(rc.range, f[5].to_uint())
        assert_eq(rc.value, f[6].to_uint())
        assert_eq(rc.total_bits, f[7].to_uint())
        assert_eq(rc.tell_frac(), f[8].to_int())
        assert_eq(band.coefficients.length() + 9, f.length())
        let mut energy = 0.0
        for i, value in band.coefficients {
          let expected = Float::reinterpret_from_uint(f[9 + i].to_uint())
          let error = (value.to_double() - expected.to_double()).abs()
          max_error = max_error.max(error)
          assert_true(error <= 0.000001)
          energy += value.to_double() * value.to_double()
        }
        assert_true((energy - gain.to_double() * gain.to_double()).abs() <= 0.00001)
        line += 1
      }
    }
  }
  assert_eq(line, 416)
  assert_true(max_error <= 0.000001)
}
