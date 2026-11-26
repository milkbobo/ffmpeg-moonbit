///|
/// DSD to PCM, from FFmpeg dsd.c and dsddec.c (LGPL-2.1-or-later).
/// Based on BSD-licensed dsd2pcm, copyright 2009, 2011 Sebastian Gesemann.
/// FFmpeg port copyright 2014 Peter Ross.
let dsd_taps : FixedArray[Double] = [
  0.09950731974056658, 0.09562845727714668, 0.08819647126516944, 0.07782552527068175,
  0.06534876523171299, 0.05172629311427257, 0.0379429484910187, 0.02490921351762261,
  0.0133774746265897, 0.003883043418804416, -0.003284703416210726, -0.008080250212687497,
  -0.01067241812471033, -0.01139427235000863, -0.0106813877974587, -0.009007905078766049,
  -0.006828859761015335, -0.004535184322001496, -0.002425035959059578, -0.0006922187080790708,
  0.0005700762133516592, 0.001353838005269448, 0.001713709169690937, 0.001742046839472948,
  0.001545601648013235, 0.001226696225277855, 0.0008704322683580222, 0.0005381636200535649,
  0.000266446345425276, 7.002968738383528e-05, -5.279407053811266e-05, -0.0001140625650874684,
  -0.0001304796361231895, -0.0001189970287491285, -9.396247155265073e-05, -6.577634378272832e-05,
  -4.07492895872535e-05, -2.17407957554587e-05, -9.163058931391722e-06, -2.017460145032201e-06,
  1.249721855219005e-06, 2.166655190537392e-06, 1.930520892991082e-06, 1.319400334374195e-06,
  7.410039764949091e-07, 3.423230509967409e-07, 1.244182214744588e-07, 3.130441005359396e-08,
]

///|
let dsd_reverse_byte : FixedArray[Int32] = FixedArray::makei(256, byte => {
  let mut value = 0
  for i in 0..<8 {
    value = (value << 1) | ((byte >> i) & 1)
  }
  value
})

///|
let dsd_filter : FixedArray[FixedArray[Double]] = FixedArray::makei(6, row => {
  FixedArray::makei(256, byte => {
    let mut sum = 0.0
    for i in 0..<8 {
      let sign = if ((byte >> (7 - i)) & 1) == 0 { -1.0 } else { 1.0 }
      sum += sign * dsd_taps[(5 - row) * 8 + i]
    }
    sum
  })
})

///|
/// Stateful DSD synthesis. Each packet yields one PCM sample per input
/// byte per channel at one eighth of the DSD bit rate.
pub struct DsdDecoder {
  history : FixedArray[FixedArray[Int32]]
  mut position : Int32
  little_endian_bits : Bool
  planar : Bool
}

///|
/// Open a DSD decoder with one filter history per channel.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.dsd_decoder_new(0) is Err(_))
/// }
/// ```
pub fn dsd_decoder_new(
  channels : Int32,
  little_endian_bits~ : Bool = false,
  planar~ : Bool = false,
) -> Result[DsdDecoder, String] {
  if channels < 1 || channels > 64 {
    return Err("dsd: invalid channel count")
  }
  Ok({
    history: FixedArray::makei(channels, _ => FixedArray::make(16, 0x69)),
    position: 0,
    little_endian_bits,
    planar,
  })
}

///|
/// Decode one complete packet to planar PCM with FFmpeg's float rounding.
pub fn DsdDecoder::decode_packet(
  self : DsdDecoder,
  packet : Bytes,
) -> Result[Array[Array[Double]], String] {
  let channels = self.history.length()
  if packet.length() % channels != 0 {
    return Err("dsd: incomplete channel sample")
  }
  let count = packet.length() / channels
  let pcm = Array::makei(channels, ch => {
    let history = self.history[ch]
    let start = if self.planar { ch * count } else { ch }
    let stride = if self.planar { 1 } else { channels }
    Array::makei(count, i => {
      let pos = (self.position + i) & 15
      let byte = packet[start + i * stride].to_int()
      history[pos] = if self.little_endian_bits {
        dsd_reverse_byte[byte]
      } else {
        byte
      }
      let midpoint = (pos - 6) & 15
      history[midpoint] = dsd_reverse_byte[history[midpoint]]
      let mut sum = 0.0
      for tap in 0..<6 {
        let a = history[(pos - tap) & 15]
        let b = history[(pos - 11 + tap) & 15]
        sum += dsd_filter[tap][a] + dsd_filter[tap][b]
      }
      Float::from_double(sum).to_double()
    })
  })
  self.position = (self.position + count) & 15
  Ok(pcm)
}
