// Whitebox tests for the MLP/TrueHD decoder internals: rate/layout tables,
// the TrueHD channel-order remap, the residual Huffman codebooks and the
// CRC helpers.

///|
test "mlp: samplerate table" {
  inspect(mlp_samplerate(0), content="48000")
  inspect(mlp_samplerate(1), content="96000")
  inspect(mlp_samplerate(2), content="192000")
  inspect(mlp_samplerate(3), content="384000")
  inspect(mlp_samplerate(8), content="44100")
  inspect(mlp_samplerate(9), content="88200")
  inspect(mlp_samplerate(0xF), content="0")
}

///|
test "mlp: truehd channel map" {
  // LR + C + LFE + LRs = 6 channels, 0x3 | 0x4 | 0x8 | 0x600.
  inspect(mlp_truehd_channels(0xF), content="6")
  inspect(mlp_truehd_layout(0xF), content="1551")
  // 0x60F = FL|FR|C|LFE|SL|SR: set bits {0,1,2,3,9,10}.
  inspect(mlp_thd_extract_channel(0x60F, 0), content="0")
  inspect(mlp_thd_extract_channel(0x60F, 3), content="3")
  inspect(mlp_thd_extract_channel(0x60F, 4), content="9")
  inspect(mlp_thd_extract_channel(0x60F, 5), content="10")
  inspect(mlp_thd_extract_channel(0x60F, 6), content="-1")
  inspect(mlp_layout_index(0x60F, 9), content="4")
  inspect(mlp_layout_index(0x60F, 10), content="5")
  inspect(mlp_layout_index(0x60F, 0), content="0")
}

///|
test "mlp: residual huffman codebooks" {
  // Book 0: 100 001 011 110 — symbols 7, 6, 11, 9.
  let gb0 = BitReader::new(b"\x85\xE0")
  inspect(mlp_huff_decode(gb0, mlp_huffman_tables[0]), content="7")
  inspect(mlp_huff_decode(gb0, mlp_huffman_tables[0]), content="6")
  inspect(mlp_huff_decode(gb0, mlp_huffman_tables[0]), content="11")
  inspect(mlp_huff_decode(gb0, mlp_huffman_tables[0]), content="9")
  // Book 1: 11 10 001 0101 — symbols 8, 7, 6, 10.
  let gb1 = BitReader::new(b"\xE2\xA0")
  inspect(mlp_huff_decode(gb1, mlp_huffman_tables[1]), content="8")
  inspect(mlp_huff_decode(gb1, mlp_huffman_tables[1]), content="7")
  inspect(mlp_huff_decode(gb1, mlp_huffman_tables[1]), content="6")
  inspect(mlp_huff_decode(gb1, mlp_huffman_tables[1]), content="10")
  // Book 2: 1 011 000000001 — symbols 7, 8, 0.
  let gb2 = BitReader::new(b"\xB0\x08")
  inspect(mlp_huff_decode(gb2, mlp_huffman_tables[2]), content="7")
  inspect(mlp_huff_decode(gb2, mlp_huffman_tables[2]), content="8")
  inspect(mlp_huff_decode(gb2, mlp_huffman_tables[2]), content="0")
}

///|
test "mlp: checksums and parity" {
  let buf : Bytes = Bytes::from_array(
    Array::makei(28, i => i.to_byte()),
  )
  let dec = MlpDecoder::new(true)
  // checksum16(buf, N) CRCs N-2 bytes and xors the RL16 tail; the reference
  // value comes from FFmpeg's crc_2D table over bytes 0..27.
  inspect(mlp_checksum16(dec.crc_2d, buf, buf.length() - 2).to_string(), content="29803")
  // checksum8(buf, N) CRCs N-1 bytes (init 0x3c) and xors the last byte.
  inspect(mlp_checksum8(dec.crc_63, buf, buf.length()), content="225")
  inspect(mlp_parity(buf), content="0")
}
