///|
/// OpusHead `output_gain`: FFmpeg computes `ff_exp10(gain_i / (20*256))`
/// (i.e. `exp2(M_LOG2_10 * x)`) and multiplies every decoded sample by that
/// float. The embedded constants are glibc `exp2(M_LOG2_10 * x)` cast to
/// float for +5 dB and -5 dB, matching FFmpeg's `c->gain`. Scaling is checked
/// sample-exactly against the gain-free decode of the same libopus stream.

///|
let opus_gain_media_b64 : String = "+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd4FJ2BZdtZQn4K2vM4prjadnLmp+u4QMCAJiL3MXbVJBVJG8/5ATQq5rg5ZlscpBXWkzwE4GGFQaT/nhMi/VqnLKwRCFcpFnH/NqPx7RhjpvzicAu/blC/sRygALOf6blR6HYkOb7BLn/Vn3ijqdTVwCzwtcpWU2hbCXUOWnTEuXUOWaOmQKy8zmqYgzM7aOueo/2siHPpomLeiHPp4NH0cpD63qkSv4/XxX8MwKhtg9IvLpTk/IJ5G/svLBR4UxvJoDmg45nD177KfOUxlfoC3YGpJWKTCpaN1u64it+1vkpE7sfaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOcGJr8KDGTyQyJfiv6R3t2sduSEBEYA8nMG7eAQN3JexxEMT7vACAMpAWd/Zp9poedvVpAs2WSs9TX3hBroY7yweDg1WY9nd6krkAfegPLRVTGtID9ie4211xon2OSbyxVINrFTtHrEnlQnPzo2P8HY/bBZ0xSVBGe+I1eliD0bv2zY1qIqEbNtVdvyKvIKoRt7tBd66oVGCJkyT+LVNAOjlFm3NKjwGmSzR/INZBeCk9/AeWeeg7zb4T7vixoaDoHbwDNkt9CRpUbq2WVXZrV0tIiVmCNLoEsFV458W/rpxRHzHJsvHUx3qXmV4B4UTqEHfDr4NIN6Z+sfpidLyaEESkQ/NqK95OOidkPHQtW1YcyaDkcE7zNIsZaslrjlsvyzLa91MRGQypXL1aQP6cBDrIDLci4CApPyyvQK7K36tPg5tljqaxTXMkF6EFnyeIWvEsALrOurKqlfu4Ltr8/3gSCZuCqMJ7YMmViCcynsfd7visp7WpKXvAMT7g2Ia/8otxNqAWBUqW7F0xC86ybgZzgzLa/Bw3Y448Ttnh5N5WFq2suwet3WR4iLqYFQjPU+FKi0EbSYxXI9XrwW7baHoqbLvdCo9mdHGHwo4o7cO5DNv6/HWXgMpU7YixqZDMMhaJtbjqoqZEdR/NUJSkWGG5ugDwfwNnAuBVOxV0mKOdFLsJjNntZwtF4L+D2UbeGkhcRJwvwCERMQinPijP5PYTPb8FGCKEYh/u+K/pGMCYEj2uY4qLuMLv55DQi43Zf7jYNH41ju63e6DN92F61CBrnacYN424UVmNXtmSKDNKaxE5yytro2z0Huxmtxl16vkXwGBj53XHnd5ifUP6HZ5+q9fbvgx7OOdqIf99I+j3D8SqAL0f0ezDQZuDvaeG3Zh9lZcGp1mg1JHWKcS5iY3xcMECM+1yabRIeSFToGd+W3tp2ooTJIZXUru76gD30wkJxOtZqJck0Fc9UXPu+LBm8T9qSLNQx2LKgfNtQlEFsUAmUi2c1RmmJaKQBYFSwqmKNn5q+i9rQD2ZhBxnhyZlWs6qKzknxvNaxB9S7Du9zdWcM3zRqKyx+o1qqd07sOf73Ny0kXsoB8Yz6MdnFIF9LdIKXZGFdFQbHXKav/i8GS8QmIXygAmzwPg0TQ4b9oi47fU2yd6f/MUo8bCPE93VdajNkuZ/0vG3clv7/pZ4uy6vZg4+zHQ5GCvF9rM9NHCrXkwTze74el0/u4okHzKmAOk2m0l+XL1CLqkzmcDcapR34Yn5/OmIl1N+Vq2vTUPwwWpLNydIQndtIsAgHZxKofJK+gIIatFUd/2La+CRqn9x96BeR7QVnzSGA5SaxAJnt4QBPrG4f6u9kX99QZ9Cf7UjiLqKVkScuoZNg4jD8SLbCy05btRuAfb9QIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZme7k+esAye7xzdOj0mqP51fT86vomkP9flkSCLgr9M3JSmbkoAZAxYvrdiwCSm/W8Tm5KAi4hQkCC3I3Mk1imG1US5LVlfarPc8Z9YvtJkMgjbiUUSxNwsP/FM7NhcCs+HKCx18ACxPRDEKfI5YS7H5dRArU41FCdPo9Afa8w=="

///|
let opus_gain_pkt_sizes : Array[Int32] = [307, 177, 183, 185, 180, 185, 314]

///|
fn opus_gain_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// The gain-free OpusHead fixture with `output_gain` replaced (Q7.8 dB).
fn opus_gain_head(gain_i : Int32) -> Bytes {
  let head = @libavutil.av_base64_decode(
    opus_gain_bytes("T3B1c0hlYWQBATgBgLsAAAAAAA=="),
    256,
  ).unwrap()
  let out : Array[Byte] = []
  for b in head {
    out.push(b)
  }
  out[16] = (gain_i & 0xFF).to_byte()
  out[17] = ((gain_i >> 8) & 0xFF).to_byte()
  Bytes::from_array(out)
}

///|
/// Decode the whole fixture (pre-skip and resampler drain included).
fn opus_gain_decode(head : @libavcodec.OpusHead) -> Array[Array[Float]] {
  let decoder = @libavcodec.OpusDecoder::new(head).unwrap()
  let media = @libavutil.av_base64_decode(
    opus_gain_bytes(opus_gain_media_b64),
    100000,
  ).unwrap()
  let acc : Array[Array[Float]] = [ for _ in 0..<head.channels => [] ]
  let mut pos = 0
  for size in opus_gain_pkt_sizes {
    let (pcm, samples) = match
      decoder.decode_packet(Some(media[pos:pos + size].to_owned())) {
      Ok(v) => v
      Err(e) => abort("opus gain decode failed: " + e)
    }
    for c in 0..<head.channels {
      for i in 0..<samples {
        acc[c].push(pcm[c][i])
      }
    }
    pos += size
  }
  let (pcm, samples) = match decoder.decode_packet(None) {
    Ok(v) => v
    Err(e) => abort("opus gain drain failed: " + e)
  }
  for c in 0..<head.channels {
    for i in 0..<samples {
      acc[c].push(pcm[c][i])
    }
  }
  acc
}

///|
test "Opus output gain scales samples by the FFmpeg gain constant" {
  let plain = opus_gain_decode(
    @libavcodec.opus_parse_head(opus_gain_head(0)).unwrap(),
  )
  let cases : Array[(Int32, UInt32)] = [
    (1280, 1071881897U),
    (-1280, 1058010522U),
  ]
  for case in cases {
    let (gain_i, gain_bits) = case
    let head = @libavcodec.opus_parse_head(opus_gain_head(gain_i)).unwrap()
    assert_eq(head.output_gain, gain_i)
    let gained = opus_gain_decode(head)
    let gain = Float::reinterpret_from_uint(gain_bits)
    for c in 0..<plain.length() {
      assert_eq(gained[c].length(), plain[c].length())
      for i in 0..<plain[c].length() {
        assert_eq(
          gained[c][i].reinterpret_as_uint(),
          (plain[c][i] * gain).reinterpret_as_uint(),
          msg="gain \{gain_i} sample \{i}",
        )
      }
    }
  }
}
