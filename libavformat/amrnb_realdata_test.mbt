///|
/// AMR-NB real-data tests: the eight FATE samples (`amrnb/<rate>.amr`, raw
/// `#!AMR` streams) decoded by the facade end to end (raw demuxer,
/// `AmrNbDecoder`) against two references, as in `amrwb_realdata_test.mbt`
/// (the C decoder `amrnbdec.c` for the first and last 16 frames within
/// 2 LSB; FATE decimated every 16th sample). A 3GP file with the `samr`
/// sample entry built from the 12.2k frames covers the MP4 mapping.
///
/// Regenerate with `python -I scripts/gen_amr_fixtures.py libavformat`.

///|
fn amrnb_cat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn amrnb_load(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 8 << 20).unwrap()
}

///|
/// The decode quantised the way swresample writes s16 (round half to even).
fn amrnb_s16(samples : Array[Double]) -> Array[Int] {
  samples.map(v => {
    let q = (v * 32768.0).round().to_int()
    if q > 32767 { 32767 } else if q < -32768 { -32768 } else { q }
  })
}

///|
/// Little-endian s16 reference bytes as values.
fn amrnb_ref(b64 : Bytes) -> Array[Int] {
  let raw = amrnb_load(b64)
  let n = raw.length() / 2
  Array::makei(n, i => (raw[2 * i].to_int() | (raw[2 * i + 1].to_int() << 8)) <<
    16 >>
    16)
}

///|
/// `actual[from ..]` against `expected`, sample by sample, within
/// `tolerance` LSB; returns the worst difference.
fn amrnb_compare(
  actual : Array[Int],
  from : Int32,
  expected : Array[Int],
  tolerance : Int,
  label : String,
) -> Int raise {
  assert_true(from + expected.length() <= actual.length(), msg="\{label}: short decode")
  let mut worst = 0
  let mut where_ = -1
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (actual[from + i] - expected[i]).abs()
    if d > worst {
      worst = d
      where_ = from + i
    }
  }
  assert_true(
    worst <= tolerance,
    msg="\{label}: sample \{where_} differs by \{worst} LSB (tolerance \{tolerance})",
  )
  worst
}

///|
/// Decode `data` through the facade and check the stream labels, the two
/// C-reference windows and the decimated FATE reference.
fn amrnb_check(
  data : Bytes,
  format : String,
  codec : String,
  rate : Int32,
  channels : Int32,
  sample_count : Int32,
  cref_head : Array[Int],
  head_tol : Int,
  cref_tail : Array[Int],
  tail_tol : Int,
  fate : Array[Int],
  fate_step : Int32,
  fate_tol : Int,
  label : String,
) -> Unit raise {
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.format_name(), format, msg="\{label}: format")
  assert_eq(audio.codec_id(), codec, msg="\{label}: codec")
  assert_eq(audio.sample_rate(), rate, msg="\{label}: rate")
  assert_eq(audio.channels(), channels, msg="\{label}: channels")
  assert_eq(audio.read_error(), "", msg="\{label}: read error")
  let rows = audio.samples()
  assert_eq(rows[0].length(), sample_count, msg="\{label}: sample count")
  let actual = amrnb_s16(rows[0])
  let per_frame = if rate == 16000 { 320 } else { 160 }
  let frames = sample_count / per_frame
  ignore(
    amrnb_compare(actual, 0, cref_head, head_tol, label + " C reference head"),
  )
  ignore(
    amrnb_compare(
      actual,
      (frames - cref_tail.length() / per_frame) * per_frame,
      cref_tail,
      tail_tol,
      label + " C reference tail",
    ),
  )
  let mut worst = 0
  let mut where_ = -1
  for i = 0; i < fate.length(); i = i + 1 {
    let d = (actual[i * fate_step] - fate[i]).abs()
    if d > worst {
      worst = d
      where_ = i * fate_step
    }
  }
  assert_eq(fate.length(), sample_count / fate_step, msg="\{label}: FATE length")
  assert_true(
    worst <= fate_tol,
    msg="\{label}: sample \{where_} differs from FATE by \{worst} LSB (tolerance \{fate_tol})",
  )
}
///|
/// `4.75k`: 3698 bytes, 284 frames
let amrnb_4_75k_file : Bytes = amrnb_cat([
  b"IyFBTVIKBDzlME/yvflfgPtKhgSWQiZ/+YYvyMnW3uIEkSqDfO3FrjzZiJygBNbmKN/k6LG0KFTm/gRVEyc/9C8gLwwePjIElgojv8RHUNcIQJcgBJYz74/9" +
  b"lj/ASc/DTASWKejs9Ishm8Izz5AEPObyjv3nP1o4rprEBE4T7UzEwZCeoUChPASOnaqvxcplCGTYP5QE8+Ym/v2Pj/jobDVwBPgqyczzjTYaYnZTVATzEH8/" +
  b"zWIP6xal06wEkQDsDOlBvwDjYsugBPPwjw/dyg5oEpgt+gSOENOJ6aZ/l2hLiK4E89x3fuyhL8JYUQVeBNkRy+7dzg4O1lLq1gSRKn4+ksIpbfFlQhgE8xHL" +
  b"uO17npQghpbaBJFzejzSxXnM7X0IuATnEcs8ie1uQYeOVRAEkUJ/eZJvumBhz6G6BPNChLidu3yswOecoASWbH/M7ZceJOwxa7wE+PBsaeXJwPu7sYiQBKDA" +
  b"Eq7Fb5BEZCOM/AQ8bPKu5YIA8dYiBiAEPGwSqfWPcED5LFLGBDxf8q7dwmV+OobqXAQ8XxKe7Y70YaGsiD4EPBTyrL7ChT4g7HwKBDxfYm7tw1X5NkEfwASO" +
  b"X66t1cEhbOLnY3wE82zyvuXDgTOnxZnEBPNfrz7/iRHrh5HifATzX5fezc+V/wac9d4EkV9ezMV9sfNz6jaiBJHwpx75gQaHSTPDzAT4wOk/xcIA7aQYHtoE" +
  b"kfDo/J3VXJnxjVXgBPjA7J6Zdgam1UmALgSR8OzOwEXGWu+IEyAE+F/tPN1xtUCwPe9aBI7l782dxRxM0HBGCATzbOi/zjJE6eT1K2YEjl/xPO0ldNRGzxBg" +
  b"BEJf5XydFZS4cUAcEgSWQteM3X21AQxS+y4EkfDnLe2zMeK2cldwBJZmt/yd0UVziveVXASR8K7PnZiamqjZAuQETvCvOeOB96uFkPTGBIfw7w+t1KUnVMyH" +
  b"SgQQX7QOzWOkZAgoihIEEPBQT4W+MZHzgKMwBNlfQ971ixFjRpCFXASPQlfN+SsiqjHEShIE82jgzuTvpmWC0QzuBHhst1/0JycHHYalFASWX86f9Mt2jxLK" +
  b"JmoEeF/7v/TfNtQNoEYIBKDAry/w5iQlK16DSgQB1l5PnN92hJI3go4EHcLWD/XoISJ+1K2MBNN5Hfz5haJpMs3OHATzQov89YMQ4exExVYE+MKD/Mxlh/Fi" +
  b"ktEMBJFsvMntg+B4eQVCVAT4ELj+8IFFfeKfV14E+L2QHoVuBfDiyiHgBJZfzh7VSjXxt4xwTgQ88KW8lfk0sdakfLIE8xRCPcnfDl8JlzQ8BJFs7c7l6jSd" +
  b"wiSH7ATU8IA/6eRC+/bOFT4ElfqhLoi32B+QU+4QBLXwmX+daU20OOCdqgTnnJne1YKRZarnR1IEteWazu0iIO2ZggcSBOcqJtyc0bSa+huDUATn8Jpst51N" +
  b"ohrZlygE8ycqPsnPjnGdEzGQBLWLj46do/2eAmKRQgTnfClP7U+vDweIpH4ElV97z5yXF8cRCJEYBPMQe+7Z655EgwYtRATT8IH57NN3BmCXOXQE5xTtzviA" +
  b"SDI4565EBNPwf4np12/r2AbrEgS1QojI9ZDROvcGCAIE5xCBfc15Hz6vl4IYBPMqhNnohljqDAbjGATzQLP96OQRDUO6ZuIEkRe7PdnELxVQwJi2BEhCPr/l" +
  b"wiDguIIjAgSRJsM49Zbh87gPBCAE2WzIT83IpVjp7FjCBPMmyo/1GgW42YycCATzFLye/Yx/aV8BkIwE5x7GPI13T+HzxQNGBOcyts7wKWf0O/xi/gSRFLtJ" +
  b"6dXPdc0a4cQE8/DBuePrV6t0aKISBJEmv/zTWEbp8lmQdATZbKj+7B6v4avuh64E8wDHHP7dj2FwNS64BNnwkTn9Dc8GDrBwBgTzJsT/9crhoHDsnTYE8+Xn" +
  b"efUFwZ+DaUSsBPNsux71kzFdPFkK7ARU8EzO5cBgfpi2inwE8/Cz/5VwcQt5ZZ9IBOfwPf7FzxT9mK6N8ATn8MIflXiwVFBvNF4EVPBIfcVLAWXiR1CuBFTc" +
  b"Oz2F58HQB5JE6ATT+tTvnfox7a7ZeMoE83PTzs1yAdndBK3cBFTcRWjFc5DPEFbQ7ASPc0HavEuu6EaCfv4ElkJGfZ1zoCJ780VyBE5s6q/5Kg7s9BSGlgSP" +
  b"bB09zU8EsfvsO1AETmyvH8luUzSHGNqUBNYZEzzNzwXprsmUwAQAJyvv/SeVul1emAQElhnVr/2crOn9GGx6BCMz1rz9ibqwZpPn0gQjUS5P7sIFsiPKz7QE" +
  b"jibWb+38lD4TNfheBI436q39Ky0iCenQFgSRQunu/ZtUx4RKrrQE+Gy4PPOJljuQJ7nABJFCuT/Pax3B246LlgSOQlBsw8WWqiFYYgQEjhS9vs5D9bHgawwy" +
  b"BNkR6k/jjJdC1Tk7bASOQumvzlyF9TNdbkgEj0LpfuPOV7RyfFoMBI9s66/dtJSOB0XZdATZQuyp4+JnNxopVjQEPELrrc1ntNxcTmDmBI4X6M3t/SUWydIi" +
  b"BgSPbIMsw0WXh4eTyjAEPGh/P5XTJSgZoGYaBI5sr8/9hz8HTUqvnARObMQs7cmgF/JtLG4ETibrft3Dvr1S2x/IBJZC63/9xmQl8cME3AQAQpQe/YstR7sm" +
  b"IqwEPELKr9PvF3WXmgiSBKAKK5/xjmBDezR4OgSgQjA/84eWrRnJcggEPGzEz/2MpS4mv9i2BJYQ7w/tymBJTqifSgSgFMn/8Y5xYr30ZDQEPPDKn83PNJ1c" +
  b"PwuaBDwUyt70j7EH3SkTCAQ8EJKe7+8NjyE2U4AEj0LNPu8DnMeONxBIBDxCzA/9L5yEDvjCcAQ8QqA57eHkk7tul8AEj2ycTPWHEGQuHRmYBDwRza3t47ys" +
  b"xThXvAQe3Mtp/Y5kIUfgZgAEj3PLPI3ZjSNx7612BEJCzO+edgVKIxagWASPQs4+45IWcO3ux1YEjxDLnJ2bRLX2prsmBNkKys76jh8g+t3RWgSOc8s+hGvA" +
  b"X7seqYIEQgrpz+3eLZcmiEvIBI7mzqztgY9woA0a0ASPCusMzWd6wHcnWdQEjxPK/eTNURn/3LkCBK0KF57uSGVMc00MUgSOjcvPzS5BTDLWTcYEjibT/P01" +
  b"q82SyWZABDxri//8yidwPikaGAT4AZc/+WMuvxODx1QE+HPOnPSXN1cMzS7QBJZogw/4jlk+lHcCUgT4c6zP/CuvXA4Ao14EPGjJb+znH7tw2/tYBJYBxa/4" +
  b"7jig4FfowgSWX8Wv/NifyuiJcBIElmjGr/nWD2piotDcBDy9Rm/8xg/Qblq4AgSPMr6u/c+UyvZwAwIEoBhDX/NWJlGb4/FuBEKpum7ld2B/+1eMiAQ8UbXP" +
  b"zWeP2z7tmeoEkAo+fu3HlV8dU7RiBCVCtX/1KiHRzw8BigQlJrhc7aGVFVnkeFQERxFA7r1HlFw4hi0eBK1sPc3ti6UtTiy1CgQqQq3t7Y9NpTi9HaYEJUI5" +
  b"2dOn99BbOHq0BB4qNz7dWyWS3CGYoAQeQjXe6YZfNgU+E9AEkEI2rt3OLssApZTcBI4mr479IiG17lEzigTUFDfP6Y5ezJ0b9o4EHhSr3un+HoZHVk18BNPl" +
  b"Oy/8jJ+s7wgzqASPJ7Kv+YCOloXMslIE0/CxrpPyB+coCP4gBFRCsT+cnK8PvUhbHATzQpof6Ux/F5SQWNgE80K7P8Bct8e1q/KEBPPmrzyZ1062OGmIAATz" +
  b"5rVNxcqE7R1GGyoE82zAPe6MSGAOyleQBPMTwD2JaQ9gfTvpIAT4QsQ9yEPIedKADRgEUuZ1/M1JX7WOKTeEBJwm8s78Kg7YNRw40ATxCkc944smh64SF3YE" +
  b"TmwqzM3JsE/JB/9eBJwmO97NwwWfN9MQygSRSib5zc3dXZGIr0AEkRk7Ds1jFYrEyzMaBJFzo7nCYnsPIwg3LASRbKc92Yo+h8CKEq4E2UKueezBnt5pKR5w" +
  b"BFU6hzz9my3hxZYlOgTZM8c87X0halnHZWYE8wDJP/WCQUl5jBeoBI4KxT/5jg7jr2zwIgTT+jXP7U1BfTU4gsQEjxM5n+3qQT8Jtmo2BI/BOu/o5IEnU7Ti" +
  b"UgSPjT2r8acIzohsEBYEPHM6r92PWqRPTkEKBNkROa3hG6nVGkf4JASPCTpumdbXvI7jgNQE5zc63sFh+YE8A2qgBNkROcv9K7qwDGfbUgTzYjeuzZ58BomI" +
  b"8ZIE2Rc53s11/c0iwG+mBPNyrm3ohxCi0Isq/gROaDo//cSP46+C/MAEjwo53v2br2H5iTMGBDxfrq7tl77Iu/2AtAStbK6v3dcuqKJZD7QEoF+urf3Hvu80" +
  b"sQp8BFtsOd3dSo/h2Ikn+gQ88Dqt7evuJMSANRQEoF86rd2vnqR2RmkiBAMmOq7tz64E+nwHYATTc0Iv9YoR3hL2q4QEjl+q7vzf3oO4Z2tgBDzwra78zp+e" +
  b"lJEUYgSO8LKv/ZaxpCgO5EQEPF+yr/yaTrN1uuxCBNPwtqn901y16YdWFgS1FLdJ9ZQRGOmvEKwEtRCfzNX9IMhzjK/ABOcUoJjpcYNx/xKBtgS1KpXPxViB" +
  b"+e9CB8QE82yrj7n8DzL7xgdCBPM3rwzlz1WkfjCExATzaMAIuZfWV+x0NWgE+GyxzshF2k4SKme8BI/TO3yHObCHmioJ6gSRbFsMxUn1CdIsWrQE5wdQzbSM" +
  b"ZlemiGWWBNnwPy6Suzu7EG+HsARUB78P7eIBdoQ9MIoEQtzCTNzj3882QmAwBI/wPp7lj7JHnaEgwgRC3LGu46sHeNb2OQIEQvA9nuzXr/GkggKEBDxCP6nz" +
  b"U/ZJlkRXBASPEEK90wI3jkhBLxAEjx5K7tVXZIatekiGBPNC88+dmk14fu05XgTzbEl/nX5PKXNSZqYE82bHDPWPEeh3XTGqBJUenDz96T5p8RPEWgTnd6rM" +
  b"nLilMHh8KTg=",
])

///|
/// `4.75k`: the C decoder's first 16 frames, s16le.
let amrnb_4_75k_cref_head : Bytes = amrnb_cat([
  b"AQADAAIAAQD9//n//v///wAAAgABAAEAAAD//wEAAQAAAAEAAAD//wAA//8AAAEAAAABAAAAAAAAAAAAAAABAAAAAAAAAP//AQAAAAAAAQAgAAIA7v8GAPn/" +
  b"9f/+//7/AgAHAPb///8HAPL/CwD9//v/EQATAXEB5/9a/8X/gP9e/6j/EgBIAPL/vP/w/+3/7v8GAAoABv+Y/vD/kAAqAEkAvgCeAPL/oP/3/zMADgAIABgA" +
  b"4ABpDKMP/AN2/w8A/vsF96r3sP2TAG/+Mv1O/pD+2vzf/CH/gADDAIYAhgCdANn/FQqjDkoEmP8VAHj84PeM/4MJ9AeCBH0D9wAI+0H10PUm+m/8sfwY/gkA" +
  b"zf5z+xT6T/tp/Rj+4Pnz+Pj9tAZrCe4FuAe+CYn+G/Y4AQ8KXgQmAkIHeweB/rv2m/hu92rtLOpj+O8BYvsJ+1QFXwmlAJH4lgSpCmQAVPzQBtkQ9hHREJYT" +
  b"rBDDAW/77v0m/Ab7ZPqNAPgAkvh3+Rj4X+3u7J3wgvX4/RgBugLDAqUCKgDx+qr/5AUSBMoC/wVHCNYHSA2tDV0KaQZ9AD4BZf+9+6//Vf9E/hn/OPw2/IH4" +
  b"vOpD587v7fRx+48AngPFCfMH3AD+/ksD7QggC1cOsA2pCV0LCway/VP9WABuAZj/zf3VAWkAcvua+vD7qf6p+0f3uPnY/Hb/LvxE/RYE7wHqAGf9Cfah9cz0" +
  b"K/tDBVUFqgirCGL+F/V38MT4IwPwA40KmA0UCCEEHP+Q/b4AWALYBBMGBwNZ/0j/D/+x/aD/uQGVBH0KOwqyAEf6Kvtc/vH96/n/+/MAjPpK9Ev3RfstABMB" +
  b"UAJjBskFQwNFAcn9Gfut/N0ArwMFA2cDRgU9Azn9A/ml/dUAEAHAA08G5gYAAUT6Hvzd/d/+dwH8A7QF8AMcAToAkwCHAKcAmwJTAxwCs/+s/jsB+ATCB1wG" +
  b"qQLqAcQErQND/7oCgQixBvABoPzo+qv6iPSY9ET5JvqN+kX6EfuL/Jz5Cfty/p77pfq3/df+tf4RAPEAdgBeAiIAxfzH/7UAVgEOATb8pPvA9TXv2PI59x38" +
  b"kf7w/28CwwFZAScBCAU+CWoIcwmkCjIJ4QvaDj4TaheUEo4PwwypCGcKeASLBPsKWARhAq39TfJ29J3wgOu88H/x9fLE8azvU/Jy8bfzZvfc9dn1gvYu+AP8" +
  b"Y/0dAOsEQAm+DO0MCQ1RC60Jzgp9CxQKVAfIBdT++/cG+jX6RPjj+oj8/vlr+N750/lu+pz9mv8VAaEBbAJqBVgIkwkECvcHtgejCvcIgQUtBXkEbAJSA7YG" +
  b"VQWR/xX8Cvrx9w74e/nM+ub7sfoD+pT6Tvu1+w79zf+y/3D/aQE7AYUCNQQ3A9UBowJXA/cBev+d/tH/ZP0o+vn79vvw9wv5svxk/YL+5/53AEYCEwDKAFsE" +
  b"dQKPAQEEZQPIAJgCDwdoCbQL3AtgB34CFQH8/8T9WP9NAk0AYPqc94j3uvad9hT4efod/Kr84v7v/8D/sAA5AZQBRgFfAWgBGgE5AFUAnwH/AlQKABDeCdAE" +
  b"WwPG93/ubfQKAgMJSwRRAVz/fPZw9Tr6bPpA+7T99wAOARb/QQEaAs3/OAAfAagA8v9G/1gB7gEiBFcLFAlfAkICXPse6ePi3/WZCHoHgwUKCEcBXfq5/UYC" +
  b"igAC/p8BYgOu/5IArAt8EWcJiANVA7v/QPzS/jECCgKvBI4HyAJz/v/8Lu7c3ffpfAOSCscEXwO3CwUOCgY2+vDvEvG5+Ij+iQMdAv0FfBLsD34G9QOmAHD9" +
  b"+/y//9ECvAMxBhMRvRXcCTn+e+4b3hHqMAJM/p7qPOw/A2oQMgoq+PfoXuvx94gEAwq0A3MDIw4LDqwHoAVdAp//b/6+AdIEyQTpBr4N2g9cB9P+MvAs4J3r" +
  b"hAVLCaT/Rvda8fPwG/uXCqcI8vqY/aIHbQU3A8sF5wGJ/Wn/TgL7A3YCpQJRB2EHOQRHAUD67/J39/kHERQ6E0UFcPRG8Gz5xgfqEDwNpAbPAMv72ADpCL8G" +
  b"yf0b+Dr4mfqS8nXpkPGj+7z+kwS1BH3zaORy6r73/f+eB9ATMxTl/bHw6vvXBbkHAhGoFawIUP0T/y0GoQrPBgIB8ftQ+MX3Z/vz/lD/AgAPECUSx/P65ELv" +
  b"Q/nqA24PYBPFARPsffJr94fsNPo4ECwLb/+A+xP/UgUSBiMGcQJ++m74bfk7/psDOgPsDqkUAfcN5cbvAvkC/HD7HROhL+siGAZr9uL0pfAz6On63Q9/Bbz7" +
  b"T/xu/KoBHgWLA0LpndBH5d39EQNiA879fw2cGvgAmvCN9PX4vgCsAuYVHi0fIZcI/vlgAAMV2RBk/Ff29/sDCRYOkAgmBkj9TPQm9lr0y/GV8e/1Wf90/IP6" +
  b"1gN2AKP0E/aY/JX8KvviAfMMGgwLAi3/rwN2CKUDKPlj+aX+dQTPDX8L1P6g/BoD3wC/9UvvovAZ9h/9zf2P+TD4QPzyAacBrv46+xX0FfF++RsBLANqA1MB" +
  b"1wCuAzUGlATkADQBTgIpApwFcQaEA5MCqQQuCG4FQwMgBvT+c/kPAWMIhAzbCY0IVwvqByIH9Qm3B0sBL/qC9/L8SwL1ABL40/WF/q7+YfnJ8wzuEPFN+YD/" +
  b"vP3r+agAVAQk/nL6g/qQ+7/8M/+0/1L76PeX/DEP+xsMFGYF5fpbAMcKvAS3/YD8dvu8ALcIngqfAhH6P/2c+hPu3+2u88D4EgC7/6P/WwKL/6L91fsv/uYF" +
  b"uAbKB04MrQfYAaYD0AqNB3f5hPtKAfP7uwTrDnwGg/1pAXoF7fgk5lXiXuf88VwCAgTn+r36jv/lBEIExQHk/5nyivAQAxYGXwLVBokGYwP//9P8pfbu8bv9" +
  b"Cwl5CpkJWwbNCUELswLmAGwBiQdbEQQOEhDCEh8KIAZvC+0PswT09A7zdfJx9G3+vQN//gj4n/xhAOj1Ze9I9Pv31PsaALoCyAMwBIgH8AiGA+n+bPyL/qQB" +
  b"ZgBGCj4UfA48BM77zf7fAjn9tPxE/PH0dvV+AOIGkAHt+8X7C/ci7JTsUPWF+Pb7r/8jAb4BRP+N/sD94/sEBAYKrQe+CLEIDAZjAqD+tv5W/57+/P3Q+xH3" +
  b"OPfu/esDywEg9WnsVPCK9/H+0wVOA1v8Sf1iBs0ISQLdAJr/ZfyyAEYHTAbEATcC6gMxAzsBFP4o/hYAYfzo+msBVALPAQoGIQbaAloDOQgLDcMNhAsaB7UB" +
  b"WQJDB1IILgJY/ZcDmwR3/i7/q/0z9xT3xPfd8zjzWfqxAkwBs/rE+vP90v8/AOUAgAHmAYMEjwVNCDMJmAIq/Gn9RQXwA5H/8Ae0DNgFI/+f/ncCwACA/AT8" +
  b"nvXZ7LDyAwGTByMBYPnU+5D7CvZR+Ar8Cfxk/B7+BwQWBLn/dgVnCZYIsgf+BJYBuft0AXkN8Ao5BPADLQbPA5X7Bf3qAFT54/kx+2zyqfRz/QsAO/2e9Ffq" +
  b"gujC9XkBRwD6/Q386f5fBoUGjAQNAA38BwWiDv0PvQx9BHkBKQP8A6wD7fyo+R3+8f76/jj/Z/+SAFf+iPtJ+SL7UgT/DTsPpwZQAPcDswVXAv0BugA1/Tr8" +
  b"rQEABKX+DfsI/Av+Tvxl+AH6+PtF/GT+SgA7/YL8y/7JAIQA0v9VAa8CGgNZBeYGr/N24jbwV/xR/psBvAIICFoJWQvqDG4FlwJ+AwEBpQAY+Q/0zfthAf4C" +
  b"XgRFE9gf3A6GAU4SjxaYCFgJBAtFBgUEYQMYAF/2jvjzAOr8TfzZ/kD8vvm19wjth+NW6Uzyg/CA7qD0+/if+iL/IP0w8r3vUvgv/RD9xf6UACEAkgLKBoMG" +
  b"8QW5Cb4I4/7797b89QaUDjINHgUj/yECTQdbBIMAEwDt/h39FAEYAs78ofsNAnQHWQYaBN4DDgIVAl4DAAPfAP3+SQAhAIr/5gAX/3P9xP3a+/f78P0U/zv/" +
  b"R/6W/vf/Sf/yAMsBqv+lAVACNgGkBMsAXPWC8uv4P/84/vP37vKa7xzyIfwyAb0BZgK2AggGpweJBqcFfwUDB4EHXAifEscUfQgPDu4eVxrOEA0QXg6CCtwE" +
  b"LAIL/dz03/dF/CT5IPf89tb22vXn7TXkTeaE7+7zhfJ/8nX2sfmT/SYBVPv09K75EAD4ArUD+wEQAbwB8gTTBtgBtv8HBZcHYAeaBZkBNgHOArQD8wEw+zz4" +
  b"8f1CBT0IgwPP/G/+ygQUB2AEgQJxAqj/D/8xBKQEpf6m/YgAAwBi/3sAnP/j/cr+GgBI/7ACCwdbB4YIXwbpAXADWQkDDjULCQXVAOn/DAKyAHb1gOha6v/y" +
  b"DPNk8fDyfPIc9fT6w/mV8UnvtPfQAEECDgFzAV8DAQY7CLsJNQZdAxIINwxPCtMGYAXtA9YDyAS2BKr9vPS3/BAIUgQ0/2b/qv/YAfD/Zf3a/RX8bf7dATAA" +
  b"QPoi9hj85AD8/yMBHgAr/+4BSgXCBokEUgaOCvwKMQu3BaX/2wEJDSoRxAcfA28EGgNuBLwEbfpm7p7xUPmx9pvytPOF83f1Wvs09ZXrPPA4+Av7K/w8/Qf+" +
  b"lP5CBSsK0wVkA9wFGgnxCq0JywNn/sMAiQWhAmQAsf1W+0MCUQkhDDEMnArTCtQKPwjiB7AESABU/7z9ufyY98z2jPga+Gf4DPk6+lb6RfsH/8L+if71AGUC" +
  b"6wEaAtIBC//AAXsLugyKC/cPJw13CUADu/5qAPT6Tfjg98fy2vBk8HDzJPRt8gvxN/Ax9RH5BvoV/Fr82v9pA+EFjge9BHsEVwYXDKcR+Q9REq0RAQ0cC6gG" +
  b"HQVcArf9hAI3AkT7GfkY+cb4cvgT93nx++4Y89D0GPWe9dL2Gfm3+/D/igGJ/1IBmwRkCisOvA6bEdsPVhNrFPwMhAwiCqwEPAVrAlz81/aO+WL62fMx81j0" +
  b"EvL38bP0I/MQ8X72IPbm9dr6B/tO/Tr7gPbt9jv0j/cl/cD6YfsU/HH6F/hI+a4BkAIv/lwASgaOCDAINQr4DLEMsg66D2EMtAwMD0MSCxYKFJ8RXA5wDIwP" +
  b"sQtnBSkEiQH5/58Cgv92+fT13fRd95/2IPWw9CHtb+yX8bnwvfCx84XyovPE+Ub8AP1Q/8oBEgaUB6MIrQrHCloNxQy3Cr8LCQlQClQOcwyaC8YJQQasBfgD" +
  b"kAMhBAAECgTk/iv7QP17/Hr4UfeR9z/2SfN68Frvx+/D7jnwQvK38hf0fPK18tf2BPl6+5L+zf4H/Zb7If4hAXsCAQQdBD4EWAUgB70J8QrRCmkJYAjLCasI" +
  b"ewfvB0oGCgW2BdcFmgMXApgCxP8C/MP62vlR+YH4XfiY+fD45vnQ++L4uflJ/gD+w/2vAD4D8AEUAXIFwAbxAzcG6gc0B7QGUQb2B0wGNQRJBhwHpgdnBOH9" +
  b"Mvt6+L/4Hv0B/bP9Uv5l/Pv72PqV/1AHEQm8CYAKsQikBSEFYwdOBUMBiwKQAywD8QUSBj0Br/tv+YX7s/tA+lz8AP0V+nr8rQI5BAcBDv8yAPn+L/w//Xr/" +
  b"iv+k/Cb8zP1F/Cb5GfpV/Nb3lvTM9ODyEvYN+dT2zvUZ96T3M/eZ92H9tf8n/sP/sAGyAfMBLgbTCIsHCAp6CFMGvgjkBgYHwQS0+9H4WPdZ98z8Efwd+7L6" +
  b"/PKK7MbqyvB8+WL9UAGaA0MEAAP0BlMQVhCuEu4XCBSpEjUSSxK5F6YZNRxtIB4eXRsfFycPbgsyCPEDL/+r+7/7fvYw7hrtPuyw5hDmROnX6AXonenT6u/q" +
  b"9et27zHyOPIp8rXx1fER9Uz1iPS7+fv8vf7XAAYBOwW1A9P/1wM/Bo0HlQzvEYQUFRJaEK8SvhEJD14PRQ+ADlwLyQe6B8MH/wRVBGcGowXIA/YFwAfAA2wA" +
  b"oAA1/2f6L/fo+DT4mvOT87H15vHC77jxjfFe8SHy5vNh9dn1bvjc9/P06/Rp9Nrz7fTA9sH54PlG+9v+yP5rAfwC+v/w/u3+2AJnBnAIJA0FDhsNLA+9DgIQ" +
  b"TRGmEBESBhAiD9ARCRHGDkQQ5g9ODAcNGQ3iB2AF0ARwAKr7dvoX+Xf0APMT82Dwi+797Wzube4j7ubvM+9d70Dyv/VL9mv0/PcQ/L76R/tH/1cBpAHmA7MF" +
  b"kgb1B6cGugZOCLwH4QcRCm4Ltwk4CZAJDQcTBH4AJP+X/0H+wPxr+r33bvc59kf1D/oQ/Xv4PfUN94H2j/ec+0r8F/3N/ej77fks+sz/AwPT/4ABaQhrCB4G" +
  b"8gg0C8gJdwmACTwLmgrSCBgJuAhfCBEHrwYSBgICXwKbANj+wgLRAHr+DgGXAOD/PwAnAP0A8QEMAgwC/wKaAwwDzgOXBAQDtAKgA3ADkgN5AiABdACN/7D/" +
  b"Xf9M/ib+Of0V+yr7dvvv+W/4/vjN+bH3cfbp9zj4vfft9zb5vPkZ+uX6Hfyu/I/8vv3U/vL+aP+lAAgBAQHr/Fn7Ov/n/Qb8Qv0w/a75MveI+4D8MvoR/er+" +
  b"pf/dANQBkgQHBqUGigjSCXoKEguLC8sMmAy3C4MLlApKC3AO1Q06ChAKZQldBqgFJwSvAc3/iP3d+4X9hP3Y+Q35kPm59/L1xfR89Ub1RPQB9VD1v/V89hj3" +
  b"Hvif+KT5Rfu6+9H4W/h6+3H7KvoW+gL6/fX59Pv5O/lF+HL9u/8FAMsB3gRYB00IVAoADQcOFA/FD0IQLBG2ENAP2Q54DUoOQxCDD4QM7QoHCvsF4gHZ/zr8" +
  b"lPh899X0gfFG7tjqMerz6R3qT+uK65zuQfJw87L1yfgW+pv6yPyR/xgB5AITBoQInwj5CHAIvwjnCo4KeAnfC5QMkArvCsUKUgmaCSoIogY=",
])

///|
/// `4.75k`: the C decoder's last 16 frames, s16le.
let amrnb_4_75k_cref_tail : Bytes = amrnb_cat([
  b"WQAdAKIAHgAQAPcAYAAEACcABQC1AFIBcgFvAD0Aq/8X/7r/k/5f/hP/nf6w/p3+S/8VAEH/0ABWAgYCNALWAWcBGAK2AV8A2f+YAEQA6P4B/9b+if7W/v79" +
  b"TP6U/uD9UP3i+6L80v35/dD9T/2n/eD9yv0q/rH/CQDI//YAbARqBP4BfQNoA0QCrAIOAmABswHGAUcALgB6AeYAYAACAVwAegAAAeD/CgBRAEEAFQCa/xwA" +
  b"z/8ZAAEAnP5o/jP9W/wE/af9Wf1e/If8vPzE+y38WP5R/mv+DgCdAZ4BPQJbBPoD2wOZBJgEbQQ/BHMEggQ9A28DWAMYAsYBUgGAAV4CrAIiApQAdAANAcr/" +
  b"B/9B/m3+dv8E/QD8CP3//BT8FfuF+qb5yPmd+pf64/oD/DX9Av7Z/iX/wgCWAisCygLrA9wDlAShBYsGLAZZBZEFUwWjBHwDiwJeAp8BVwDwAU8CeQCb/13/" +
  b"Yv96/h79Df3h/Lf8fvzm+uT6/ftE++r6DvmL+HL6d/kr+Iv4A/rF+2T8vfwl/t3/jAFiAl8DvwTwBckG+wYzB+kHRgnJCUoI/wfmCdQJswchBk8FpwQeA70A" +
  b"9v4a/k79qvuW+dD4nfhD+KX3SvUL9ZH2mfbk9JX0YvaG9234NvnI+nf9mf/1AD0CHAQNBkgHDAi4CHcJPAoZCs4JKwvxDCAMxAqUC9oLLwo1CAkGuQRvA98A" +
  b"XP5Z/ET75vmo90X2dPWI9Rz1I/OX8nHy1PKG86HyRPOX9Zr3jvnh+uD89f9AAgYEYgUaBygJQwrICvsKagvgDFsOjg1PDOUM7QyZC2AJ/QbEBSUFLQMbAOz9" +
  b"z/y0+6X5bfdB9nX1yPNF8r7xtPCQ8O3zBPbT9p746fop/ioAOwHrAsUEzAacB7cHUwjeCGEK+QuMDdAN3A1EDvUMcAs+CdQGGgbzA8YADP68+yv6lfcQ9Vzz" +
  b"L/LY8eDwTO4I7TjuQe/o707wGvLQ9jz6Ifxt/nUBNgU0B0YIvQkvC54McQz1C4cLKgu9Cv4JqgnHCIsHRQaMBNgCFgFV/6AA7ACp/o79Fv3Z/Jv7vvmZ+Vv5" +
  b"TfaS83fzBfQr9Djz7fMF+DP7Wfyd/TQAbADo/3cBBQM5BMEEmQUIB4MH7wdxCJ4JlAv7DpYQgA9wDggOxwwXCn8Kygp5B9YDxwF1ABT9FvgU9e3yXPBc7Z/s" +
  b"GO3a7FDtIe+E8azzX/Zm+Rb84f2e/wMCNgQuBlIHhAgOClwKYgoZCg4K9QmtCe0JpggcB7AFYwOtAOH9t/uQ+h35xPc49w/3SPeh8hbvivG38yb0afTw9iv8" +
  b"I/+wAPMC+gX8B40EQAIOBfEGhwZeBUUGbghpCKwHRAcjCL8J1gmFCKMHjgcpB0YFqARsBCEDLgSqBJIG9AfoBb0EJwTiAgcANfyy+jr5c/fa9a/0K/gi+yj6" +
  b"Efpq+3f9H/6i/Ar8+vxL/jD+aP17/Xf+Av+i/i7+1v52/6AALQHsABT/zv6PAWQADP4d/s3/Rv9o/Yf4i/O99c33TvVh9FX2bfpc/H/9hwDmBXgLnAeuAxgG" +
  b"vAhLCqsGoQO6BfoHPggeCAALAA+tDdIKmgpXCicITQNTAYYDtwMFAcb8KPv3+6D6Bfgv8u3seOsy6lbrme+Y8afzVve+/EUA/QChBFgFtAG9/kkANQIaAsUA" +
  b"r/+0AYMFEgUVAnUE0Ai5BzwETQWQCNEJsgg5BVkD/QRMBWYCS//C/rv/EwAD+4n04PTX92H4nPYT9tf5hv7TACsAVQKTCXMJJwRgA0UF5AaaBdkEKga5BsgG" +
  b"ggm5DQgOkwx5Cy0JRwd3AwcEgwXqA3wEBANoALv+a/vc+J/0wPJo7w7kpuBd477m5Oyi6lbrCPTJ+gcAt/8lAqAFyP/f/e/+w/9nAuoBMAPQBd8H+glTCccJ" +
  b"UQqxCBMMoA7yDd4M3gg4B5gGVwMdBJgECgPuAr0A3Po79cHzFfTe87rzGfU1+c79nQDcAD4EBwmLBQUBJADzAAECiwECBCIH0wcMCeENrhJPEn8OGApdCHQH" +
  b"2gPmACX+Hfw7+0L4YvVH8s/x1++05dvhZuTi6QvzP/HY8JP5owAKB7kFAAVRB/8Aqv3o+3v6mv6d/88B7wkaEMITCBNQEX0R3w6ACiYFxwE5ApQD+QMCAssA" +
  b"AAFjADH9/vln+JrwqOnb6V/sUvS3+6b9DAMvCPQLaAwlCasHyP9v90H2qfUB/ZMDZQTnDHwWFxq0F1YRyw1TC64E3/2o+dz6Rv1T/A/6t/lR+yT7mfe19h71" +
  b"Qej03VHf3eXI7732F/wPB4cOshHZDyYONw3fBHL+HPwO/iYHrxArGNkdESEkH/wXpw8oByAC2wATARMDagbvCDQJ4gR2/Ef2cPPz7//pZOT54NngleD940rs" +
  b"9fD+9YH7HP/RAtAD5APSAngBkgDw/oIBWQVSCj0ORA1YDhkN0AeYA/b+/wHqB04GUgi4D9ERUQwcAxH/EP7K8n7nOeUB5DrhSt9l4y/vhvZr+KD86wMQCX0D" +
  b"OP2i/y4CbgCT/aMASwqpEIoQ8BCFFLsUvg7bB8sEHAdlDv8NWw2YF38cYBYoC/oCDAGm+anueurY5pvhrt4i34Tmr+6O8m730P17A3kFmwRdBQoFi/w09Wv1" +
  b"2PqsApsHtQzKE8sPTAY0AZj+p/3H/C37fwCzCJcLxAjgBQoHvQXZ/V334PWf9v31a/Qh9of8SAIZBrUKPA6PD0UKYwMRApv/bftc+aX6FQDABsAL5Q4/DrML" +
  b"PAkHBSj/jvsM/rEExwXUCOkS+xQqELQITgAv/Aj1Iu1o6XriCt/R4fTjh+qj8XH2av0HAhcEmgL3/U/+ovrJ7jbrde8Z+Pr/CgLHCrkSSQvbA/oA6/9YAn0B" +
  b"bwFQCcYRwRS1FXYVFBTaEGwHqv1l+a3x3eqr6s/s6/KO+YAB2AtmED0RPA6MCL8FmQG1/Pf7lfweAC4Jig+AEEcQyg0SCvIE8vyi+DL7vwCsA8wF5gwzE44V" +
  b"fxHzCEgCuPh178fmTdp11wrcJ+DZ5rnuMfyLCJsLSgcLABT+R/3K9xT13veb/eIF8w0dEr4TrxM0EHEKdgND/UX7Vf7pAfoDrAlSEBQT/RHEECwQ4gdW/Tn2" +
  b"Ket74/rgl+WP7/LzZfsnBY8IkQbF+x71MPVJ8bnuS/Dv9A3+GwYMCycOLw+YDhsLVgWQAAr+p/58AR4CrQXnDBgRFRF3CtAHwQTB+lz0MOzP5TXewNzb6pDy" +
  b"j/nEBYcNLRPSC+MBpQFC/a/4jvbj9lv+SAW1Cn8OXg+wEBcOdQjrA5z/Sv+sAeEBvQQkDd8T4w7FByIGEgDt+FHvSeTe2prUk96z6Pru9/3yCgIVmhQHDB4M" +
  b"PgkTAq79C/sL/3MD0wZSC8sMYQ5GDbAIgwVTAT7/zQAdAQcDTQnmDxAWVBJMCVYHlQBH98bwmOYc3fXUcNrQ6B7uk/iCBnIPPBKACRAGcgdZAU/9H/w//qgD" +
  b"QgaTCTQQWxNyEQwN5QhXBScAiP2vAlQGiwlyD60URhgfEUAFhAKc/LDy8+wH5s3fstqN3knqK+/q9QEAoQXhBhYBlv68AKz74Pez+ez7yv+TAmYF5AwhEAsN" +
  b"qQrPBwAF4QAp/v0D5gdkCEQMrw9YEi8MUwFZAfD+pvYr8zbugOjc4m/khe/J88v3zgAlBd0F8wA8/mgBzvxT94n5HPyW/2oC8ASdDAEQRwyYCo8I8gWwAlsA" +
  b"Iga8CeUIJAzZDj0QWw7NBE0AIwEZ+5v25fQ37I3jmeFX6UTya/RZ+6QEqwYzBHUAegE//oj0UvR2+YT77v7rAgYJYg8ADmQLXgu/CNMFAwMiBJgJcQnfCFcM" +
  b"Ww1qDcYJtQILAv0AIf11/QX5c+4+6OPoDe+u9Ir4FQB1BR4FPwK9AEkACfn/8mf2bvmw+lr+5wK+CH4LfgliCR0JWQYiBNsCjAVcCNsG+gckC+EKHgqxCTcG" +
  b"+wHt/2T+mfs6+A/zO+vO5znrj/Ck9nn8xQGwBdoEEv/u/AP8u/Xs8yf43/oi/ksBNAV2CgcLZAnZCeEI2Ab2BIoEqQdTCAMIMwtxDEEL1wr/CbYGHgMNAsAA" +
  b"5PvL94jzo+uc5z7qRe/l9AT6C/+FAxgDIP0q+2z7K/ak9P/4HvwZ/8QBNwUaCnkKzgigCQYJEwdiBSEFEQcTB/YFugcHCfYHuAZ5Bn0GXgMS/8D+c/6p+iL4" +
  b"dPZZ8vDvLfHF9Lr4sPv0/k4CYALG/pz9G/5z/I/8a/4mABECngLTAwgG/QUEBfgEkAS0A0kC8wE4A+0DGQQqBfEG4gc4BwQHmAcLCaoGtAHTAVcApfrC9+zz" +
  b"d+zm6QDti/C/87D3w/yLACb/JP3+/vD+9/3A/3IB6gL2A4wEdgZxBwcHnQYDBjYF9QN3AjECiQLMAiIDoQM0BfoFjgW+BUAGqwgmB2ACKwPpAW/8HPpJ9tDu" +
  b"Pexb78LxOPHv8y/6wfx++xH8Qv93/bb7rv9YAUwBFAN7BdsGywZECFgJjgfvBssGVAXNA2AFvwY6BVMFdgayBgsGbAWIBTwFsgZABfgAowFcAIz76/lD9pTv" +
  b"1+0q8YbynvD+9d38sPyF/LL+lQDz/ID85ABB/6r8E//TASwBUwERBaoFYASzBVcGIQVbBGYHkwjzBSQHUQhvCVgJWwe+BykHCwceBaAAOQFQ/4v6xvkh9qDw" +
  b"nu/D8jLzSfHX93D8r/ks/XwBEQGTARMEigXnBPIFMAdOBYIEqQQPA2YB6AAqAd0AgABAAV8CrwL2AlgDDQSEBjcF4wFEAzICyv1Y/Of4+PEj8KHr5Oik47/h" +
  b"2unX6L7pyfKq91D5m/xFAmECwQLSCR8LBQuuD6sRvxEEE7YUGRSEFxsZRhThEoQSyhEzEJYMbgusCYIHGgaJAyEHhwg7BssFiQIwAQ//YPlK9U729fNw7tHv" +
  b"Hu8B6lvsp+0R7J7u3/Lb853z0/MU8pPzG/ZU95D5U/oY/VIBAQLCAkEFWgPU/+UAXQSeAzQBwAPzBvcGHAdKB18JgwvqCnELDAwyC5UKJAneBq4DYQG/AI7+" +
  b"n/2r/0kAX/8E/y3/g/8g/zL/+/4W/2AAh//X/yYDmgRNA8sDfQTkAycE0gMKAmcCWwPpAEr//gDOAKT95fx1/Y78j/w5/Av7I/sD+wn62/jm74TqCu8K7pjp" +
  b"m+6i9QT1t/YZ/dH+JgD0/U78EgHWAnACBQRfCAUN1wxuDfEPHRBrEKUQjQ//Dq8OYA1/C8gKYwmDBqEEqwPxAYT/iP2I/EL6qPgf98LsSOYP64zpgOQG6czv" +
  b"1O/j8Sn40vZX9gL7gPv7/KYB8gSPBg0LKBGmETISKxbBFu8VnhYcFm8UTRO2Eq8QUg0pC+QIFAaxA1AAT/3f91nyifJu7Ejefdxo4QHdWNoU4mXoiOiV7jn0" +
  b"gfCM9Pz8l/3x/GYCcgk1C/UPCReqFw4ayB7oHj4e/B6XHyUdhRoNGZEVJxJtDgYLrgllB9ECcP/l/Nb5s/YM8tTtqO3q6yjlQ+NC58nmNeSp6F3t1u1u8VL1" +
  b"PPZY+fn9GwA7APYEfgtRDS4QbhOzE+QUtRW0FIgTchJNEZ4O/wuBCsgHWwR/AdT+g/we+lz3NfXq723r2uwT6J3dnd3U4S3f8d7n5FvpVeuW8Tn2m/Qd+ZgA" +
  b"LgPyA2IHzA1fEOARXRYLF3sYUBzCGywb/BvCGr4YUxcMFTgRJg8QDLAHWAVdAX7+bfw1+Vv4LvYs9R73M/d6+Ir6e/vm/Vn+7/xB/uT/pf9E/nL/XgEu/zb+" +
  b"nf9i/Qb75f3q/T/7Q/ta/er7dfmR/Pn7NfnS/PL7Hfrq/JP9hPyb+xb6MPdu9oX3ivdW9jL1xfeS+Ib1IfdO+bP1MPSY9jj56vkP+17+QP+QAowGTAeeCUYM" +
  b"Ig63D8sRMROzESAUNhT2EHUSOBBvD3gS0hAWEWcP9go8C8gI5gbtB4QHYgn/BTQCTAaWA7X9mP79+6f3HvWg87Dxp+5l7TrtsO3s7x7xDfEZ8sv0T/ZL9qP4" +
  b"ivrQ+uD5xvlc/O37nvnH/N78dPpI/AT8XvwlAKoApwCVAR8CHwMUA3MDIAJDAgYEIgCdAK4CrP/p/iUAZQFxAesCkAj9CCkHLAoHC1gJSghDCEEIDgaxBNYD" +
  b"vwHWAAT+NP2t/Ab5zviT+JP3FPq/+wL8avzH/h4BQQBjAfwBewGQAmEAZgARAZn+G/3S+0/7BPqP+C745ff4+on7vPn+/Nj+JP7T/20BswBk9jjy8Pic8RXt" +
  b"GPNh8frxZvUt+ioAuQKl/m7+uwXZBAYC0wZNB/gHFQqCDJsNeAy4D8cQFA4sD3sPcg28C+EKtAm6Bi8F/AS5BbwFwAOsBIcGjQXzBF8F8ASKA3MM8A9dCD8M" +
  b"gBDXCnMHSQeMBGH9ofnx+cL1D/uG/qz4BvyaAM3+9fuG/Ir///qr9tD4lPT/7i/uNe4h7P7k1eWl6mvmH+cB7ZzvIfF19T77Dv+KAfMBZQRaB0cFPwaXB5MF" +
  b"sQXpBc0FJAf4Bz4IlQgkCPUIWAn0Bj4HiAg0BEUD6QRLAhQAeQBQ/jz6zfnO+rf4Fvdl+Wr6hPwmAWkBwgQRCeMHewkfDMwJRwlWCVoHBgVfBtAI6QYZCCAL" +
  b"YQisBikIIgaRArkBdgFW/eb6BPvx9Nrwg/Lz7hLra+nZ6Ezp0edt6eHteO+Y8q73FvuC/usAzgCVAk0FEwTtAx0HoQf4BjQIJArGC4AKvAo5DmwM/QkhDLUL" +
  b"SQgGCN8IHwY5BMEE3gM6AYkAYAFG/1n+QwCt/+X+xgD+AaMBVgG/AhsDQgE8AfcBUQHwALsBgQKsAbQBqQHqADMA2/6c/hD+6fsX/Mj7BPk=",
])

///|
/// `4.75k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_4_75k_fate : Bytes = amrnb_cat([
  b"AQAAAAAAAgBe/0kA/vudAEH1tAZu99kQX+1HCIH4sA2p+1UFWAJc/sn95gZTA/ABpfrA9TIJTvIt+NT+awKR/3D/9vvIAIj3GgFRAagAgwVVA8cE9QNM/qwH" +
  b"hAWJ/UUFmfrl/cX3ffI7/uL0EQNgAO/1rwMZ9lMBQwOC96gA5fqu86YDXufVBmwBvQOGA/H0RP/Q+80IYfxDB0wBRQWTB5YI4/lfBh3+swVF/DbwzfsYAKD0" +
  b"8QXt/v3+Sf+a78cUIPf09JkBgQJI/3b1DgG2BDAAMQux9isKUQka+HsLJfQXDMb4mwSO+Tr7SgZwDCHtrQohBDnwAQS2BeL4UQZl/CwDDv/M9PMBEfyuEvED" +
  b"9eu1A1wLL/fc9+3+CRET8776twkQ/YABrwYMArD/vffr/NQB1Q2599H43gSDDx3qnwiECCf90/yWA8D8SwJBCYL6of5PAEQAsAFSBOn56P3AAckMAO2HBGAF" +
  b"4AEF93P/5P39BGYRQfWA/kz4pgf99i4UmPipAoj0DwyA7Vb/zQRvCZP44P+k+2n+LAklAnb/r/hiBG32xBWa+bf8uvefDgTzXf+RCz8ERPkOARr+JvmWDswB" +
  b"pv1z/aH9b/kJD/77TPo5+IgLf/pC/sT4Uwft/Pj/S/1mA8/7DgElAcEBXf4R+TYFQAJO/hH8lAVb/lUCWf2mAwj8GQE0/FYFh/x1ACwGJP5DBXX9rP8W/zj9" +
  b"xQO6BdL+XwPl+g3/xvip/0QEJQBk+7T+d/t5/nb4dgClA20Avf2zAK3+HP5sBKX9FAdy/XL5CALbAlkE2fpG/FoMjPy/++IBGQDGAwH9+vvIBOwF0ffaAKH9" +
  b"4wsS+W0ATwCFA8/76AH9/TYMKfou/zsARgD8+vIBnv0LAYYC0vnY/GL9TAMI/hn75gU/A5D7vACd+jIE+wE/+sUCn/5u/zn9GPkMBuUBI/r3+T8HcAdB+vv3" +
  b"OQZaCDoOPPAr/YUAnAIaAboHi/M3/zMCTA43+Mr6qPrGB9oJJ/Mw/HQGNAde+NECEwONAQb3+AcVD2nxRP89ABMJewJs9CMKPQHg/wr4zvzQC+L3qwboCYL7" +
  b"nPsE+1QGp/uM95AHqQKN9UwC+ASXBLH1gQZqBG8BXPpa/6oDKgWX+OoI6QNw+jP5NAM0BnL6/fiiB1sE2fcC+swEfgoc9H0F4wSc/iP/Nvx1BHL9ufpuCIkH" +
  b"HvsZ/Sb/PQY19hT6rA6mApb/6/alA6kEPvWbCHEFNfmq+7D/hgVnAUT6wAV4Bbr55fdQAmYGwfwA/cYEAwSR+Ev+BgQkAi4AxAIWAs7+Wv1iADT/BP9YAFz/" +
  b"bf9W/2IEpP+cAHABlQKJAkP+WP4aAN4BePjfAicJGP0Q+tIC7gOCBOj62fp3+NgDYgWOA4n7ZQA0/3YCaAaj+mgAJwbQ/UcIV/iK9UYKCvooCRb99/vPBXn8" +
  b"QgI0/4gBcAW7/0778gBR/iEFDQGJAw0C9f31CGL0tgKGAtf/BP7w/SgCwgay+JQEhwUj+yMGbwPU/fL6FwBYBon4svs7B53/G/1k/+0DtPtq/+YFm/kQAO4B" +
  b"vfeCBvP6NPpyDtj6Uv1MBT0BLgXE3v4eivoh8rYAkQEJDiQE2fkSA0IKPATXCisAdQKAB8z/XQUjC5DWDAElEgr8XvMoACgDKPzM+VkDQAiJ6OwmrACotJL8" +
  b"TiKc5L7zqvaKDzMMNfwnFYzmHhICAGQes/el9KEr2+fZ6sHvLgozC8oMeQOhAfwB7v84Al31oOqD8gLgrf3r8o//1wPmD7X+oPXhGMz3hRae8QYRQv+2CyT+" +
  b"a/orBFX1SQ4+/Nv3r/6VCVkHcvXk+yYCugZMAP/+jfr9/6cGbv5z+nz99gM2A0MCE/+3+PD6ewlBAgT6Mfi3AQsD3gVXAyf6S/kfCJgERfz2+m8AfQKsAYj+" +
  b"KwCDAvICDwE1/ar+Xf26AQwAWgC//rD+oAPb/soAWf9d/6cBJgKiAJH+9gPM/xwB8P7pAEwCOwRC9eT/awsd+CoAvvQRCHEKk/LN9hoMvP8e+a//YgGoBooB" +
  b"gPnnA9ISEwjr6acACesAIr/VzganCy0e8RG9+QQN3vTBEOzD5A/p36Et/vSx9xERu/fpHILUaxps4eId+dmbDdUAhBDjEMHiPhkC8aYXkso3Gerwdw0++psN" +
  b"nhKv8FwI3OzcEDnxJhDL51UUCu+5EVPzYQRLBQb6PQ035Q4TPemvGBboRxOu6BgYIPZ7A0P+Jv5LB63v1BmD/o/3HuQ3Jen43BLqzlsaBwH0CY30Gvo0+LQM" +
  b"/fPHGhveghLs37sbw+/Y+Ez4qBsz7IgCefEeDCn/aP5BDWwDTgIV+68Or/s//rT1yhQ9+IQEeup5E5zxYQBF9ugPpeetAzfw4hfb8tkDaPy8DHXpLwp881UG" +
  b"7fb5BHsBJfwF9OQC9wRXBZ3rUAnDBNECI//x/UEDLANa/HMLNwID9FgGnAFMEZjwJghA9LcVpf9G/XLqchcX8BwYkfv49V0BWgeDCD72v/WHCscHRgUG9ET6" +
  b"egaiBIYJxvWw9nT82QyNB1P4OfkhBW4ImAa29//+pv7zAq8CFPlfA24BPgcG/3X09hDJ+0n/ygkr/rf3RQZA9dYT/P0+7VcI0f5O+m4JtPh2+z0B0//QCt/8" +
  b"9fQtDLL4XganBAb1mv5jDK/39g0289gA2Q40+1sCZ/X4BOEPR+5LEAX1u+1zGHz18g1NAErkvhAcBjT8/wPx5bcTVALM+4IIReaFB38Ikv7hDonhswe6Cnf4" +
  b"tAbV6xEE/g7d88EDvPvR+AwQ+fPIBjn05vfuGDf9/Pml+535NA7/BrLyUgLq+3YJCAb0BOzyBPvUBucCSfjD+En7dgyY+a4COv3R/aYEAwMt+WkCbvK+CNoK" +
  b"ze9g7wERlRIK+2kEMe2mCuPnUhR68rYMlgO29Iz/mQFE8uMTtfeU8qYMDenhIIrsNv+4DBb6WvanAFH2GRC0AaT06gWz80AIqAPB9wUHvO3qCSQaT+NwFl/8" +
  b"I/KBFPvxXvTkB0b8LAdv95H6RQH2/nIFswIP9kgEjwTZ9g0BTQvn/1L3lwhq8Fr+vQyN+SMAUwQF+N0C1QF1/tUHH/KzDZrySvw9G5/xAwWL9gD8uf9TBPUA" +
  b"6PbQBUL70/Y7DBP0cQQJ+mz8/gbWAhUARv7W/eoE2vSDB1cLevUC9jMEpPfM/cYIbwaF9KP8rgGY9IoRmwc+8A0FkQGz+bsM2fesA8z7zQHNBzHz+gBuBw/+" +
  b"MAjD9/MBUAE7AJH/q/5uAcwBRPxK/8gFlwUoAZoBsvykAFQEKQW1+S3/IAAYBff9VvYcBO7uZgUp+lsBXfvaAikCPATO/CADaP+DDS0Bf/kcBZ0DCASjAGj6" +
  b"1wM3BG714gX3/cn/ZP46/fP68/6j/3YACwCCAkL9zQR1ANUIywqE+7QBugLZBIb4kgKL+WD95//HBJsCOPDfAen+9wQ4Az4Cde5YAqoAI/py/8z2a/8ABYEC" +
  b"xPrSAZX0cf8yAl7+X/w8AcT66gH4+34E6v60+oQAjftpCF31GgNo/+b6oPUvAMcCUwYYAG0RoQxY98z/Y/lmD0jwx/vCGLL7XPeP+mD4eRSU+HYATAGX+YgD" +
  b"0vpBD2X5ZvK7GPH+RvQY9537/Bmq8gr1DQk89uMAW/0t/KYBqfs8Bvv/kOwMBsj58Q7Z/Wj1YwmVArYBJvtb+lUClwMG+Q8IGPoFAvz/rAdm/mr1mgorAPz9" +
  b"UvO7As4I8ftC/TUKAgUJBtX3vgIsDJv60gcEAHD8Bf2x/oMA4Py18/4WbwKG+uL5HgP0E+70jP/6/6/+Tf6v83wBkgzB+g0PFwPk/5P9Zv9JAoEHdPl+CDcE" +
  b"Vfe5ATX6DwcR/An9sQUO/Q4C4PljBYoCXgsy+o4AcvhvCvD9gP7+/Pr95gQvAdf5X/tx+ZsIJwdH+esApwfXCE4DX/vJAZMLigdW+/n3dge2BrD7oP+2+jMM" +
  b"dARMCU35P/ujBN36DAbK9+UFcQJY87T5Q/iBBAkFnPT6A8EDwfuMBNj9TfV1B7r66wwm8xgG3Q5KAsMEpv3a8q8LqPkjBgz8bRfIDMECp/eIDZH8cgdsANbu" +
  b"8gHv9fkIVO5I+jD7z/1x/CoB9gMbHs39nAUxAJEQJP4pCML/gf3uAaH8BfZz588Q++60HBgAPg3RAqf0LwYYCRn62hXgAOkE/fwkCVgKW/u8/unvcfw65SAN" +
  b"rPd6/yX6Lw309g0GFfv5ClMCMQoYCUgRCPv3Aov5DAKmBdTrpALf8CcF9f4GBL4BH/Io/VEHTfJyA43vDv3bCr0HJvOZ/ZIFJQQYBPL+/Ph9AQ78VQIf/7bt" +
  b"rgVW9joNrgWaAZn9LAYuCSEH1v6EBmDzfgMO9N/yjQDECNr6YvkoAwoEfAiuCNQA4/sK/vwBIglN+Xj4ygUd/YX53Aaj87wBEQZu+1r8Zf4Q+ib7Nfd0BFwC" +
  b"afBhDq8AYwiaBM0I3v9WBqz/SAWx7HkCxgMQ/CX/TgDq+jv/3AIuAnT7mfRBCRf8XQPQAhf8awH9CdcAaP8I/WgHevleCWT8Dfz880kIpf39/M//O/hGAr8C" +
  b"/gDmAZP8cP7qCCX+fgKG9x8GjQJnCq3nmgQS/cQIh/sr/csKq/HWAsH/7/z1B8n7d/0FBTL/aQRF/x0H7fs0B3P9zArs9AYDavr9Auv9KQan/5X9tgBt+ygB" +
  b"PQVBB/L7cQOACHT5ofVeBd/4i/+TAML94PW6BRD4ov6R+Sj/2wLK+ogBl/96+nX9wAe9+x3/ggcCBTf9Fgm7++sCGP4MCOr4VwO//ZsB2/qIBtj/5/wMBDT8" +
  b"oQNNAGn53wBK9uD4BAFGD6DyC/61An78IQ/f65Ho4QdtFMP1PPqD9GYOgg5sF4fssvqW8jMINg8uCBDvbgexDGgC7/Zd8+wTW/iwAp7ypAGTAf4BpP/dASL4" +
  b"4/5x9/f+hgMXAmX+ZPTk8xH7WQD0EPcNdOxwCeQBTAiN/Ub51vc0C4sHJPaP+K4DM/tW/Cr87f3rGXsDlx5B9df/EgMSFXb9tvqcC2QFHgWA/Kf2wQdWAOD6" +
  b"M/LS/4D9FRAd7poMVgc3BhEG3MzA8d//Zh0/F6n2PPxE/WDt8gXAAgICMO3x+BP9/QPzEen87wIF+V7+SxEkBzELjAL7+/UC0waUDRD+Efi9+sIBaQ1TA7IA" +
  b"TfMy+WX+5wYD+x351f1N+/UPBgnH9DYJ/QI6ED7/3OjNEkUCjQIDDNzqLv9Q/Q4IDgvQ5wz2EwOgBsQEwPkv8sX4gQmuCR0Kh/G86YENWgR4Fmv+Ceic/yT+" +
  b"nA60A3/pcwTe9nUNdgXA9t4AD/gqBnMSrf5bAn3wFwGWBvAHGgKD67z+afykDvsJy/nT/eTx5Q6tEeYB6/lm5kMF6f+HB4cG8/FZAAjxCQy+Dvb9Wwaw5eEE" +
  b"tfXFByUIn+6MAWPwhRCOBdAE9Pco9g0BGAN8Bd39QvXmBMv2sATZ/13yBAh1++T8eABV8BQKQPkqAVUbadVwA40NWflDHSPheQs7+9nq9hIAA+0JLP1w4msC" +
  b"WhH6BboCW/4V7boUhhZy8j8F2uTvAWYEQAuAEQjaHvuxEOYA3AdL7VX+og0tChUIhPKpAyr0GP3w//f6bw2h+On2EgOP+tsRnv+e/t/3DAzPAx37bAUI6+QH" +
  b"CwZ9/fX5Z/sCCUsBQAArAWryIQ2VDvb77/wK9JYBSQqzBKvzYfoaBE4Mzfqe8SUEbf+/B4QA6+tuB0cIiADh/UvuEgpKC0YDawAZ7WYD0xHV+3P2tgH4/KkK" +
  b"lgDs9vD4xQMvCiEBxvE6A1gCTgK5BvjuggHbCiABpv9J+EEEbgOeAGv9of0JA7f8GwFH/J4EaP21/6cA5gHP/psESf1GBEH5QgMr+NcB2f7uBQIDsvdaAiIM" +
  b"6vDUEHX2t/mwC8z3QAUD+yUAuwEwAK8AdP0M/ob/9ANs/t77kAN7/E4E0AK6/ToHzfj5BbL46AFsAa4ApgJr/DACjPpvANgCBfQrDvn0SwEQBfv2iQiU+6sE" +
  b"EwAQ/+7+2fR2CGIA+P41+qP5ZgnL+dMG7Pbf/3YESv99BEv2WQNqBzf6pALA+UkGHAFjAR36tftbCIX89gAA91QFJgGG/1kAJAFx+skM+vrEAs4BjQZK+6QC" +
  b"EP6K90EHKvG0DNbucgf+BgoIMvnWDqrpohaVB/3tAQ5s7pH7zg+SBHb61vHH/foAYQICB/nwiAr08MQPDfL/CIsDuuNYCCoA9wCoEbzzAguI5g4EQQ/CATYU" +
  b"pN0+BaAHyP8Y+mb8nwfe6D4HBBBq/HEKitpSETULKf43DSTVlhCNBkz82QLe8vMDuQ8+BjoK/vaqBTXakwTSCOwFsQVL5Zocvf8oBUABd/RhBC3nChFlAzYH" +
  b"cg2b420Ox/g6Bvz8s/gUBYfkIB8g+q33/glV868N0wRC+7/9a+oOG57sigyf/UH9NgDx8okS0vHiC7H+Fu5gGJ3s5BDY9UD96Aor52UaYPM2CZAGqfN1DtPy" +
  b"BxBD95v5xg3Q7j4TLO9FCeYAXPKlF1fmQw+R/tD+KQjdBYQIn+4SCvr5NAptC67q0wcj/GwCKRQ48VQQpuP+ARQL+AXqBLLjWQeAEiv7EBG795T+2+HQ900U" +
  b"FQck7jHemwZiEIsGGvn79AIFJNwiAREPNwXdBT7UlQy8EI/9pAWG+JwI9QG2AC0FFQOIA4ngEAW5ECYHlwT83NoJXRjB+yj8yAAkCZjlwQo8BqcJkP9U49UF" +
  b"sxKbBI8K5+Vi/3sNi/7WCRkAv/ai/38KgQfL+2jz2AqT/BoE5P61CHr15gRe8r72RBZ58jkKk+Hq77IVkxbUDEzYg/kcFYEJ1PmzE+b0MNYZIKUPAPFx89br" +
  b"6yY5Bvrykvt48mgbAPY6/Pn+uvAEE0EV0PDqDZjrCArhELX2TRN89VEG0A4v8oca1P4I73z5XQR+C2AAbwOn+e34cQ1xALEBz+eODAH8bw2A//zlAQkqCgsJ" +
  b"4uY8A70H2gnFA9ry4Pon+AIayuem/9/29xYLBfz6PPXX75MXAADm/i/kSRLWAJEFfQHj7dMHvAWMBJb0bvciC7MATAJu+jzwTQ9nDqH2zvaN/VkDqQkABHbw" +
  b"y/rdCU4LMfs49CQBWQbnBhj8e/MmBv0GAv5G+mEAHQBeA7UBYvzlAb4ANgPj/bD9fQJZABf/ZwFQ/WoEXABb/FsEXgIV++sDTwIO+fAFvQBi9hkKRPuO+U8M" +
  b"dfXMBvMDTvAqC9n8NACAD1ztUge3+7AAvwknBKL8FP9t+h4IoPq0AZAIYfgqBmgABwBRCjv1AQId/AoHfRGo6QH9D/qyESgH2eBZBRwDfQMcByLfmwe9BREC" +
  b"sQSH6scKbAeZAawDue6vE1b9ue6uBcQFFg5J5Av/EBY8ElcFzd/K/1gS3QXyBTfshPtbDXUFHQmZ++zzAwhF7xoKfQZgArQDVwD3/cwC0O4UA7IGhvJTAb4H" +
  b"cPzoAFj8YQLKEUr1k/PAA78AJgPl/KL18Q+I/Vf2bxR93DULBgs15LMTW/eb9MIaHved/+r8s/UxE+0HOe2e+UMCWAkU+tL7OPLTBroGPwz1+wHtzQV5AB8M" +
  b"uQF478YLiQBRAQ==",
])

///|
test "amrnb 4.75k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_4_75k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_4_75k_cref_head),
    3,
    amrnb_ref(amrnb_4_75k_cref_tail),
    2,
    amrnb_ref(amrnb_4_75k_fate),
    16,
    2,
    "4.75k",
  )
}

///|
/// `5.15k`: 3982 bytes, 284 frames
let amrnb_5_15k_file : Bytes = amrnb_cat([
  b"IyFBTVIKDDynMuARJGUKWRhJxgIMaUIl2wGgqpzqem4g2gyJVH04C1zru+QKLzC8DGtnKsCHrDErHFwlLqYMqsgnBwj70corqm/4tAxpUCfA4pxxQzJsAaAS" +
  b"DGnM6MAXiarx/mSlyeYMaZTrGwl8wCYprNg3lgw8Z/TEZGsa2NGlzrXaDHLI6jjqrQEGOUwsPSAMcbmuBIsZU+2oygIVmgzPZy8glX+7/+bmpZjyDB9U09sA" +
  b"Noa7uXffFUIMzwh4xwWbqvTmhdJt0gyJAOEbeNRLMfjUyBCoDM8PdgWJq9u2xyEyG6gMcQjSxOImG7rZLgn+MAzPO3QYmc/5VONWRXPkDJuIyssF7Zs6+Rhs" +
  b"H0QMiVSB0JFT1OlMJhDCKgzPiM3Ep3+7WvAsQnJUDInOfcziE/THes7DnJIM54jN2xE16lfXVb+H0AyJQn9LHYeVvH5m6G+8DM9Cg9lhPntB/VahwfoMaTZ+" +
  b"OKrsi3jkFqRZugwfD2lY4C1zSwcHnzCIDAUDF0MdSUPgEpzgXswMPDb2KGYPA0cGkzginAw8NhfDBQ7C6Do3nJbSDDz69hDqGztDpT1sPNoMPPoWJWwdSsm8" +
  b"JIiuLAw8KPcnHR29oJXrAtmODDz6Xlji20oJpsQYQNIMcfqvSItM0+gQNmXUagzPNvZEkV6DQTVxCmf4DM/6rFsRvL8vH8W1ZGIMz/p+Gxnoe6a2mSPd0AyJ" +
  b"+mLBje1T5R9H+yKADIkPoRkYFuv5oRrM7cIMHwPqJxQOkuAmAiMZ0AyJD+VEbs36x+K/CEDADB8D6jjot4s7gOoS7qAMiQ/pJJdz0feDFxyBAAwf+uzEtM8q" +
  b"bLgG83HkDHGn6mRv79tCxpuRmAYMzzbpBey+nQe+Z6PKfgxx+vAkLw+b6Jr1Z4AmDEL65EstzsptvFCYUK4MaULSwSX/+8uZZQE/SgyJD+VYoMwrRT3V8xBe" +
  b"DGlmtSdsTqsMhKnkcJAMiQ+yw2RpOvJxWwYH4AxyD7wrFcb3No+lAyaMDOEP8UcpXzqKuye5rEAMCPqzB4k+a+eMCMe0TgwID1LHZApygjoneBNqDJv6RzsJ" +
  b"bKMqFK9qMR4M8UJR2wEwOrY0lIoS2gzPFuAo6KhRVLV4B0zkDB42xAMNTmA1ibheFwYMafrOIIGfQZeZSfKOZgwe+v8EC1vRWJZZHhiGDAUDrxgL1IBnjOlN" +
  b"u2IMgGtcAA+ryXqYKIV+wgy4Q97YAe4Dpg/nPS2MDMueGsRi8wvbLFcREAAMz0KHJ2z+c4Um9wA1RAwfQ4c7CX24fqYWQqwQDIk2pisVSvuLPqU8d+AMHwjD" +
  b"L2AicYa2tUUqRAwfvZMnbH5z7aY1RqhUDGn6zRoZjbOOlL0oCkQMPA+jJK//wqWcs7ICvAzPKEU5mBXbO8Mob1w0DIk26sQH69LnuCuALeYMKw+VOQlUG1Yn" +
  b"7VM/NAypX5slZkdIjnBcUMJqDK0Pm2SrbavFxUqVBNQM5zmfSIc/A2QGvcRKzAytp44vDX/r7j4VfpMmDOdUJiXk/6jCuC00QWgM5w+ZRR16t6TvwguLLgzP" +
  b"5C07AZSKNeaAd0GYDK3RlAhrTrvu+RtiQXQM5z4oGGLtK13ZiCCabgyp+nsjbD64krMIfCsQDM8IgyM8EuqU0SkCD2QMyw9/QOSvSfWpr2MhaAznKOrYg7GI" +
  b"b3Mlem1eDMsPh9hDY4pSzhoVN24MrUKKwxQqku8ckygCSAznCIoraH4LtdHuiZm0DM9UhBsZUpmhZzBEKCAMzwK2RI93qO4a2uGT/gyJ6LV7aNJ6O+FqQyPs" +
  b"DBJCPwjkToOoDyJWJUQMiWTFOJp/gwwsNDLNvAybNswoi03KYYheTY6cDM9kwxsJjOOhpFbeqhwMzyi8OBvdm/Hek55kMAzneMMhbr8Kv+onDEXaDOdMpjgi" +
  b"53FejHWylu4MiSi7eOIVahbvBxyxtAzPD8VYYtVncb3Wv7M2DIlkv8MVste7pnNQcFwMmzasJB9fufXMbQQj4gzPAMUkiN/t8NYnscmqDJsPj1sBSoqUw52N" +
  b"ZCAMz2TDOBO60sMqJtC/9AzPp+TbAciiLAtsUs98DM82wtiQSWLhLAxfyOoMKg9JxOZrMosDqEs3YgzPD7PbYLjyDRhCrGsuDOcPP9jgmEJDtQjVOagM5w/A" +
  b"2OKIY0I1CjzIVAwqDz0kbj/z7yY+TEa4DCo7PSMXWSPuIpFrSsQMy1/QxOar+qQf5UZKnAzPztUjHV6q7hZgtgxGDCo7UcdgD0PFE3hxLNAM8c4/aK6vyBj2" +
  b"FFB83gxpQkfHYAyarC1X3rdkDHI26QUNt1r7xq4RJoYM8TYdO2icOgm0576AWgxyNqwHHdb7uDSZCbSaDGuYFRhq3StHpsUCkMQMAOQwAw5PKsK1gpwsmAxp" +
  b"mNrAlTiqye6WPZpsDMTM09iB2fp4VJdm98IMxIosxOSpPAyFVUq1rgxxZNXAhava65U5vX5YDHHs6kAeX+vt39CS5hAMiULrKBV/um+rSHEhqgwfNrvbAaCW" +
  b"M5EgemFYDIlCvSMFHc/l0wMfM44McUJD2OAhZl619T2BFgxxKLoLaF5NDr5GyNosDJuI7McRcseTh9etxMoMcULuyJN7jEuGYxl7LAzxQuspFRT3vJxcRc9K" +
  b"DPE27cE2fCqIgewIVtoMm0LvxBdDhvK1ILVMJgw8Qu9DbE1agLu6tACgDHHo7gjsL0vCiXiuosIM8TZ9OOq1N1CR+cp0Lgw8FokjZEoSrZyTvmgWDHE2piRi" +
  b"/Otc+UnYl74McjbBBOwfKwMiT+dWqAxyZO0kHx779/EzVk1MDGlC7yQDHjqOjUZa3oAMAEKTOwiY+y7rKtxOoAw8Qs9AFgXm3KYIW5KIDAVQLccBUkKrCza9" +
  b"GjgMBUIwGIlh1nWl2W6ZAgw8NszAhkvKKo21TmpgDGkI6icRKpqvMpLLHGoMBSjPwGYRUkk7op1+jAw8D84E6i17yZzq1tuKDDwozgcAP+HpFYhoBwQMPAib" +
  b"GBuJj87wvcMF1gzxQs0naErurdHhxsHYDDxCywUDv6rs2Mq3gWIMPEKZIOTbK82x7I2hwgzxNpnAYh9T7w67AYquDDyIywMdvqug1JqZjaYMeDvND2xuS4mq" +
  b"14IAjgzxzszbIEjLKMVm+pdsDEJCy9iR64yhsqZtCQIM8ULJI2zWJ5emU+8jYgzxCM7DFU7qo6XfgiB6DJtQzscRIs2bwrcdw1IMcc7NO2AZwW0hLVXpwgxC" +
  b"UOrAtjp6AvEeFtjYDHFnz9iTnJsQxiQAdNwM8VDtQwVeqv988qY/UgzxyMzEJ3/AzzvHO7vQDLVQHBhq/13kim8YwkwMcbHOCwlv6+oAa1NN5AxxZNLDBS+b" +
  b"3EptMsBGDDzWjyQHfjhQioUU2BoMH4CVAI7Hm/XIWZt9JgwfzssAjz2B0Zyb0G6kDGkWhQdoVjiBXfjZEFgMH86vBAPc2fTOyaQ/xAw8FsogjVkoufR3c3we" +
  b"DGmAwwQcxUnMbPZhYegMafrDwITL6NbyFmbCUAxpFscYiYUrWscXw7zQDDy9RQSYr7ncwucloFoM8Uy/IQWPy86zx5FhIAwFGEcYiQXnMotl/G0QDEKVvyCk" +
  b"DgKMDF/bDHQMPIqzGIvtazTDZJzquAwJUD8k5J8ryJPIfWB0DKRCtcEULbLkGzcsytgMpGS5wJc4u+KycpW1cgziiELHFbqagLImN7PKDLU2OkSP2XrihKug" +
  b"K0AMVEKvKSuvy0b2IRRDHAykQjoNnGc207pz/fZ4DHhUNTgq/avAswKGYLwMeEI1TJfH277RvEuRegwJQjYJaO8b2ecwOnzsDHFkrNiD6zpPCo8tU5oMKyg8" +
  b"CBtgu3bxsP6iUAx4KKbYkWG6NvH5yN+6DMunNySTSSh6/Y3bR2YM8eS2IOwEK7rlmMs0UgzLD7PME1Cm8oMcpeC0DCpCtSdoHqix6dk8jzoMz0KfwLd067fZ" +
  b"mFNaugzPQrk4mxXAeaMRi6gGDM9np2Hm10sfzUik+tAMz2eyC2xuIyGH2NwBMgzPNsEnaB/MgWfBBiWeDM/Isgtqpds35pa948wMH0KnB2hwaO5mExYZDAxK" +
  b"Z4nbERm6NfKJotUWDDlk6ctg2jiU5uS5kHgMj1A3QxXn156P0e2X1gxyNi/ZARjKKxs4eH9MDDlkNiTub3rFiM2PS0AMiVInGOj+W8nqCT+gWgyJmDknbB46" +
  b"hJFCYsoCDInOq9sR0OWwew2mhb4MiTamYJ/zq9jZCgK8kAybQqt5aL3ZEs1XoQd+DKpclSQaXRps7KNhCyQMm8zFGJm9yygucj7HYAzPAMXEYptCjgRmlIG+" +
  b"DHFQwsNk4nqbxlTssnAMy18zI2juG6smjJmkwgzxyDcYG8nbQgV5awEuDPGDOwEdZenNBSe6NmYM8bE/JJ2FgydG6USOXAw8zj8BHQ/L2lWNSEl0DJuIPSjo" +
  b"J7KPaPhmZLgM8ZA9JQ8luryzueR4Kgzn7Dso4kNzRl6UflAiDJuIOyiPT/rwTlBMc5IMz0Y2Kx5eKgzceCyD2gyb6D4nDTuLpdpcJlS4DM9OrUSbE+jtMwPy" +
  b"xuYMchY9JwFcSxz3FHow3AzxUDogNl779+4CHqUQDDz6rwiYi6u67mSd/CgMtTavRRGPix7ahiJbjAwF+q8lA4mqWuuFE1lKDNo2PiQeGMvx5go/3+YMPA8/" +
  b"JCcNy9D2CXBuFAwF+j8ArgnK1Nn94CvqDMBkPyCNCcqw+dKhAwAMy84/2BPMk04yWbMh7gxx+qcAjeoI1snj8HZYDDwPrySQj+n08whRQHQMcQ+3BB8OKsYw" +
  b"anrMVgw8+rckFw5Yce+W4cjeDMsPtyIHi5qk8HaHSp4MrSi02Afq8mMDB4zAdAytCKQ4mq9jbRInLqPODOconTgbRvvQFAZ3H4AMrVSWxROr86UGZzwWpAzP" +
  b"Np7YofTrX+VnXgNGDM/srsFsjNKIpI6hCGQMzxa4xWGiSxub5IAtTgwfNrQkbmfpcEnZZow2DPHLNzspTWdsGQvUy+gMiTZjxReJg0SQg/UOQgzn4FIory+h" +
  b"+7p2xumQDJsPRjjoUBX7XeTA4ZYMKuC9BK5t66IlrIHAmAxCO7xhLL/ZPvFcck0iDPEPPSCXr9OfG4i+QsAMQju3OJEH51imt/kLuAxCDz8gtg/4+OYVRxAy" +
  b"DDxCPyWFgwa7vpEaAR4M8QhHRg8XpjaYamAiPgzxeE9Ik2+DAKWcWYYIDM9C9itg7FuAxue2z0gMzzZTyOIaGpXENzCC6gzPZsLARozy6CZmeNy0DKl4n9gi" +
  b"6DpQ3hR5GGYM5+6uQO8v6eaqJp+zIA==",
])

///|
/// `5.15k`: the C decoder's first 16 frames, s16le.
let amrnb_5_15k_cref_head : Bytes = amrnb_cat([
  b"AAABAAAAAAD///////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACQ/3b/CgA7ABwA" +
  b"LQA9ACUA9P/n/wYAFQALAAQABQADAPb/8/8AAAsACgAGAAUAlf94/wgAPAAgADEAPwAlAPX/5v/c/+P/EAAcABAAFAANAPn/8P/5/wkAEAARABEADgAFAPv/" +
  b"+v9JBVsHDALB/yAAaP4D/K/7R/4uAGj/uf5X/7L/6f6M/sL/0gCjADoASgBVANL/owTnBgwCxv/u/zj+KPyFAv0IZgblA4cDKAEw/Az4/fgR/PP83fwx/p7/" +
  b"WP7b+7f7Nv1W/o7+6PR/8DX4VwHxA9ED0AmCDe37Ye+//H4GwwAhAQgMPxAfBuX7L/2z8Sbm++4p+L/9OQNZBt0JkAdOAf3/zgPdAzQBNALHB/gKdBTzGSES" +
  b"aQubA/f7gPoW+ZL6vP+HAYn/3vy/+ij4w+y85rDxg/n9+WkApAbDCFAIpQFA/pMDmAXIAagAqAXxBy4EUgf0CNwG2AEM/Br/+f59+wP/Vf9m/wEAzvwo/cb6" +
  b"GO8+60vyRPf8/KsAtQKQCGMHswCY/sUCLAh9CdoLGg0zDYgO8gvABXgAF//y/1n9Pvv0/T7+yPx0+gn5aft/+EjykfZp/N/8wPxp/yoC0wAx/3H+gv+/AoAC" +
  b"kgMNBp4GqQgWBdn8rPkY+ID5QP3B/uED2wSE/4z+av4N/Nv45/Wn+woAK/5DAWQCUwGLAWP9sgHPCnALUg4hDaQFbAeSB2UC/Pm/9Yz82PiP8HnyBPZt+Ez8" +
  b"S/y0/aIBZ/2Z9l317/Uo95f6Kv9XBaEGtAOrBIYF3AUMB1IINw02D3cHqAFU/ib5nvcv+cb9nAMAA08B2AGkAWb9t/h0/dYB8gE+A00FGAaqAiUBxAErB6IP" +
  b"7w4LEPwRnQoWBzUHgwcFCSYFuACT/Tr5PPZm8YHvj/Pg82302/aC91j32fVD9qX4FPeC+OD8vf3c/8EAbADcAuABKwLcBCUE8wXXBT7/8/tV9PvvJvVJ97H6" +
  b"7P46/Wv5ovfY+cf8rv9PBVcIkQj3CCoHCw0eFsYWrBr/HKAWixL/EjQTERG4FKsTmQd7AYr8kvB56jPsUO3e7Ovsle0k7L3qUexM7rLwtfPJ9df3Ovhg+J/7" +
  b"Cf7+/6oDkg1iFCsJlQJZBrABHQLqB8sFewHz+HHzsPP68RT2EfsH+s/4pveu9xn5U/uSADIEiQXdB4oHwgjKDO0MQg1oDUgL6AqgCuYKTggWBFYE1ARcBXUG" +
  b"xQJW/+L9APsX+uv63ftV/XL8QfuV+1f8wvvg/AgAxP+a/0UB1gCKArsEGAQpAzgCHwO4APH6Svy3A5T+E/ZL+Rr6RPZY9yn8nv4K/QX/RgLM/1L/mQJbA9oC" +
  b"hgNrBLADEAKFAhcGPwciDYsSawzPBucBx/nP+D4AVwSOAAP9cvso9pHxvO5w7f/ww/QM+Sb+lP/0AFsC5QGxAq8DTwSvBBIEfAMwA8oBtAG/BP0G8Q80F68O" +
  b"VAbBAFz3BvZ/BWoP/gUO/t78+PVz727uXfAS8obyYPkV/2H+sf8ZAkoCZgFAAWAC/wGG/+QAlAMBBC8LVRDzCWACff3v64nfD/cVDMgEFwKPBR4ARPgK9fb5" +
  b"r/vR9wP/6gS7AIEBJhGIHCwRwgWdB4sCFvsr/ogCJwFh/0oGzQdP/nr74/Sf4zHsoAQCB4UAMwD7D9kbJQkJ7dLfNuT48QX8FAU0BEUEQRKQE+0IfQXrAaL+" +
  b"J/3//kMDiwIoBBwJUQTy/Y391fUi6WTxUPa86s/u2vx4EXMiVxH47YjZReVg/ooINAoPBmICBAyEESoNSwkiA/v/hgGFApQF/gWnBY0K0xWDHMkPW/j45+nu" +
  b"uwOQBNP6APrh84zswfXwA4cGCAFR/Y75mvNn+FQD4QJr/pf9RP4KAjkDjgK2Aer9Mv7SAA4BhADi/4wCigeIDuQQrgaz+Yv2r/56CZAJ+wFK+Dnx7vbO/MH5" +
  b"+PjV+Z/+OQYpAwj4KPFq9bH/NwS68gzg9uuxAiwL3AhAAdP6BvssA0MNcgwzBO0B0w1JHugcNgwIDngVpw12ESIVEgMG8gT1SwPLA8330fUI9nDzGvDN7Gny" +
  b"l/gD+Zz7qvpG+Mn6Jf0S/2T/J/1G/gEBXgM7BIoAvgGHBcoCPALLAtv+P/3oAGkFFgIB+0n7GP4Z/gH4t+418m790hrbMDUWGPfJ9Rv/xAh6CBAAwfji9Dn+" +
  b"6QeRAGb6FP3x/Xfmb9Gu5i3/EAIjAwH+sPZU+WgCDQuIAgfwHfJJAaMOHBSfCWb+H/5TAw4KoghzAQ0ARwJ8BhIKuwWSAX0CKwhAAeHcqdL39G4JXwmHBLn7" +
  b"RfBQ7SMBPBBVAB7ykProCbYWVBb5Cd0BAw4bIBIamgZV/6MCCggSDHgNbwsYCK8HjwEH/E0CvwP2/Gb3cvF78sb1PvrQAn/98/bL9K3nV+Vv8237I/7//Nz6" +
  b"fwAkClsILv5gBToP4AlSA8gB2AKVAu0Fjw8QEPULNgqxBBz/QPvp/JUEBgvGEigR3/4t95wA2whsCQ0D1PvO8+bz4v/tAGvzS/F2+2D7Ve3a58bxNva/+B3/" +
  b"0/o89j36W/28/yT8g/fT+aL8wwKLBw0CJP2O/qMMrRmWDU0AKv/Z/eABeQQnBE35+91X3i/3fgBvAtkBuvvH73rrOfxJBg78+/dB/HUDow2aEAIKvQFWDMUb" +
  b"8BP8BusOzBiWD+EI0Ag2/kX4zQHqBG/3l+6t+A4Azv5f/sv/AflK6crsivp1+rT94//1/HcAgQUhBjD/n/fg9Q74+v7rBgUHV//E/roMRhOhCWMBVfeE7Urw" +
  b"wfq9CRIOhAjMBaQAfAhQE8MK/gO6/2b8PAHaA8EFLgfQB8IHIvxT8Tj2Hf0i/+//m/++/jD84fs5+wL1cPGs938AnANCAsgBHQDS/vQLsRdMD40FQwFL/lj+" +
  b"awGpERAZ6QhAADv/Ifsi/Xn/PwCo9GvdsN/U8TD6kwDTARH6jOyX6Sj5hvTf5Bn4DgzACi0Ofg6qA4b9pwsFG4YNKQCrEAMaeg0CB7IDUfqy+PP+SQBW/Pz2" +
  b"M/o2AJ7+BgBG+e/nUOas7wj6bgNYAXz8v/kK9u/1G/Wd98X/pv+J/dgEcgh6BAIDFglPCpAEZwFB/5r8M/2KAc0Alf/NBgIMaQbaAogIIRH6FQsSHAfZ/E79" +
  b"oQXgBbIADgGmAyIC6f2U/t4AIfok+/wClf9e+y39DAEjBbIGTQZy/wf4U/zEAYoAW/tg+nQC6gn3DxoQmP/d95L/JQCf/In6owEpCdn/2PyOAeL5T/gy+370" +
  b"Xekf37bnPfxC/7z7Nvw9/Jf4afSQ/v/5w+bO9rYPDw53B6EEnwHq/8gCcAuRB2j8If+WCEQLPQVTBrEKrASkAU8EuAIz/3T+IQGv/Zr09vJm98n7ogNLA+n2" +
  b"CvXr/s0ElAPvACsC3ADq+uD+DgNWAEkHeBDhDWgGYwNJBC8EMQMLBIQClv+L/k787fso+wD5YPtW/8sAiP5z+xP8SP9cDGoU+ggQAWYCFQEBAaMCsAAE/vP9" +
  b"LQIiArP7+vvK/tH9W/9o/iz5yfXg/e4HlgOs/rn/bv+e/6gBTAEN/qgFjRBBEI8MtPmI6wz0bfqw+zr7r/9qB+cDcQSZB3b/oPw4/sL0q+h45KfrXfUC+XH+" +
  b"ngHKDI8USQrWBdQPmRRPDC4FngRv/kD7t/+pAEf8xfqs/Y4AawAaAOj/W/1P/Kzzq+oA8pT3SfUw94z6G/7J//cCIASz/7X/owMDA1cCAAOaAqUAFwAcAtMC" +
  b"wwk9EBML2QUJBU0EOQoND1QKsgMBANz+E/2MAckFd/28+ET8fP7a+mj29fhj+mcAMAqQBi8AWv+w/xIBjf/R/s3+Qv3t/dj9vPvQ+0/8x/z0/Xv+o/5//t79" +
  b"0f5j/2X/if7p/ngCBgQ7BRYEjvtH9+75nv2d/lH9GwAbAEL5lPQF8h7xsPb6+yH8I/lL+Gb9ZwIhBhgHWAZNC/cPQwtqCWsJHAwvG8sgUhizEYUJnQV0BUoC" +
  b"SQBl+oT06/Uz+IH5JvlM9rf2xfcs77voiu9d9vX18vRi+G773vx4AUgDJACCAJQDLAU4BT8ESgTNAbn/FwPbBRMD5gBYBLEGPQbLBAkC9gC7AIsDTgR5+zj2" +
  b"WfzZBJgHuQGp+mr7ngLQB9IEOwG+AJ/9iv1yAygEQP7J/Ff/tv7f/YX/Ev8K/Zv+dQBmAbUFYQaYAhgBGAHfAecC3AclCxEF2QDWAT0Aa/9Y/z341OxX7ev1" +
  b"v/ZU8wL0TfYD+Bj8E/p280f3Zf6CAYkDswIpAyAD8AMmCBQIRgUlBSEJVAyoCTQHcwaCA0cCFwfiB7H4vvCbAaUKFAEa/df9UPxYAVADhP09+bn50v7uAHL/" +
  b"Bvkf9DH63/8YAHb/Af5u/iMBoQUiCJ4IBQxNC2oIwwnxAZX8JwDHC2AT5Ac2AgoFYgI5BQ0GHv6c8t/wtfki+afzc/S88wv0MPrB+FzvvPF0+aT7//wO/hT/" +
  b"cf6dAe4G0AVsA1oEXwbsCLAI7AYw+lb0cwCuAhn5PPPS+ZICtAmyEMQJSwOOC5ALBgSCA24Civ0p/E0BivnI7SL2Tvuf9yj5L/x++0D8ZAPwBx4EpAisDHMI" +
  b"3gq3BtQAuwDlB/oOHhANETwLSAj1DQoJBv87/Vf73feV9lX3QvCA5izu2vNc74/peuht77np+eo++HD1qPm6AkIENghWBrYHBAtgDgsY9hxhG/kVcRTMF8IQ" +
  b"Jgn0BQsC/gCl/1wBcAAf+4j3kvoF+3b1d/Kg9jv4PewD7HP1fOv05hDzLfV48oP5SgAT/hT/UwXEB3EILQ8bF+MU8BGNEw4U0RL5EhkY6RORB98FQgbHAQH9" +
  b"fAKmBDP6O/ov/nL5BPZ89Oj0yPF58KPuZuk562noEubb6pjsDPBX86vt8e2V9Hb24fnJ/58EVQKtAmILQA3fDHkP8hflHfgZlxuEIzgkjSFwH24aoBWMF40X" +
  b"GxMNEFoKqAS/ATUDtwDs9Y3y1vFL7DjnC+Sg4trbCNmS3lHdSd4F46Td4Nwa5K7ogOsD8a74Y/dd+FwDTgeCB1oNEhBtDq4PExVtGHEXBRmKGRUW/RRDFFsW" +
  b"PRgYFcYSMA7qCjMJHAU9B4IGzf9+/rf8Dfqk97P0xvT28SrxYvKS8MfxMfCn7cXxa/P68zf35PiE+n76pvvc/vn+6wAXAzwEVAc+B+EGkgkwCkYJ3Aj7B+IG" +
  b"YAe+ByMH5QbsBPICngLOApoCDgBo/eP7evkM9x32qvWO9HT0mPW19Uf1kPal+aD6JviI+JT7UPss/KoA4gLWAGQAqAJvA18DOwX7BtkFBwWMBqgHmQh6CBQG" +
  b"fgQjA9cCCwb7BhMHqQcfBZsD6wJ6A78HgwkKCF8H7AiCCvkHSgYYBx0FIgFe/kwF6gqABf0DYwTL/oj4fPWj+Cj6S/aM9hz/JQJ0+yr58/rt+Pb2xvjP/bb/" +
  b"5fvK+qf8wfuT+qD7cPwO/Dn8IP3E/XL8O/ww/UP8S/qX+qn6qfpQ+wL8L/18/In7i/wK/IL8n/9gAI8AsQCnAagCKAFsAe4ChQFl+MTx0vh2+334ov0JAET9" +
  b"9vHa6Xjx7/M68/v83/8H/e/+tf6OAAoE6gXPDX0QeA2DEV8S6xEGF4carh6OInkinSLSHlAXgRR6EtsNEAjqBGMEbv719t32gPUl7p3sT+7C60frDe3r7HXs" +
  b"p+yd7AHsGu0M7ivtHe978sj0KPUn9fH40/s5/O/+pwErAcH/fwDAAxwFSwUYCAwKyQnOCZ4JYAoXDHgMvQtiDl4P6Qt2C/EKKQg3B1AF+gNZBfwG7wdXBegB" +
  b"KwLDAG78l/oR/aP9bfnq+Gj7Qfd186319/Pv8NDyB/VY9Drz7vVD90r2jfnv++b73vuT/CQAVgAeABMF5wa/BuMG3gQqBLgDwwNBBo4J8gw1DhcNzAwZDDkL" +
  b"vQqUCEQNWBCqCVoOqxKICyYItQf8Bz8G/gPcBfYBHPxV/LD57/RI81byk/GC7tPsa+/C7mXrRe638LDtkeqv6/ju3vGB8YvyMfgn+of5Bf3qAeICjQLqBdQH" +
  b"2gcnCqMKiAsaDJgLXAwAC3UKmQoHCvAIhQVuApL9mfrr+4D7MvmL9qfzLfPw8n3ySfcB+xn4NvYt+dH5W/sIAKMBIAJzA/wCSQFeARMG9AgSBtEGiAxmDEoJ" +
  b"dQopDoEN3gq3CycOxAuzCT0KQQjGBcwEYQSoAqICyQSgAJH/PwIi/9v9+P65/SH8mfpK++77UfwB/Tv87f5RAcv+of8nApYB1AOBBE0DXgRUAx8DEQMCAdgB" +
  b"wgFiACMAgv5Y/Vj9C/y2+vn51vjl98r2PPbK9qb2ovY39633cfg/+f75bfvW+zX7hvxl/nH+2v8HA78DpQOCAJn/6gKAAa0ATwEb/477yPlF/Nj9k/vw/O4A" +
  b"1QA1ADYCpAMxBc0HZAhwCHsJ3Al8CRoJsQhnCFUJTQnQBncKSQxmB50GqAZsBJkBLP5L/a/7vviu95P6bvvX98z3WPkx+LL3YffJ9jr3zffB99f4I/tJ/Dj8" +
  b"s/jK93f7CPtu+kj8sP2j/Gn7XP2H/HP3JfcF+2b8BfwK/rUCXwQyBKQGQAgUCmcN6A2dEFgTAhL1EawRYBDsDlYOsw1xCkEN7w4+CDIGngXAAbv9efmT94j1" +
  b"3PIJ8vruyuw86rzko+Q25nbmv+g+6rzuZvMx8rLzm/hQ+ZT4PPunASoD3wHmBtIJ2wcyCF8K4Q3ZDugO8xA7E1ATSxGKERQS3BDsEHYQmg8=",
])

///|
/// `5.15k`: the C decoder's last 16 frames, s16le.
let amrnb_5_15k_cref_tail : Bytes = amrnb_cat([
  b"1f5d/tL+//+S/5/+af9fAOL/pv/h/+T/agBuALX/3P+RAG4ATv8Z/1L/MP9k/4v+tv9EAf//7wDuAbcB7AKRAhsBlwCRAK4AwQBnAKD/TgCvAM3/6P+7/oH9" +
  b"nf3h/EL9H/6h/eH9Gv6G/cr8K/0B/4//8f5o/24BAwJnAZYBuAJDA+UCdgKDArYBxAEbAXIA1ABBARcCvACyAasD8gB0A88DGgCPAYIBeAC1AKYAPQCb/0IA" +
  b"Xv/Z/pP+ofs8/DP96/rf+sH7oPz5+wH6Z/sT/VT8evyz/Tv/WADxAFsBZgLcAxUE6QOjBG0ELAQXBHEDZwNSA6oDbgNEAoED5wLBAWMDawM5AoT/m/7b/93+" +
  b"aP6R/Xn9kP6C/Sf90Puu+rD8yfvm+R77ZvwC/a/7zvpM/Qf+rfyK/ST/dwA2AYEBTAJWA4MERQSRA5gE9waBB7YFPgYgB0QGHAbaBPUDagTABOQDWQI2AXcA" +
  b"7P/r/jz9svxs/Nv7Gfv/+Zj47fh5+dn31PcJ+ff5K/ot+ZX6e/xE/Kj8m/08/6IAIgG8ATQCqAO1BjwHjQabB5EIqQiFCVQJ3AcsCJ0IageOBqYEGAOBAsQA" +
  b"zf75/AD8Dfu/+UP4TvZb9or2O/X39KX1g/WE9dX1kfYn96X4NPrZ+l38jf5OAPEBTwOyBPIFkAUWB+4IZQj/CP4I7QjhCpsKCwneCPQI9wjhB6AFTAS4A6IC" +
  b"Bf8v/Nf7+Pq3+cf3+/Wx9k33Xfal9B70lfVm9j/2lvYo+FL6Efxw/dj+OwFwAyoF9wWSBXgHdwlQCWQJAgoHC1UM/AupCk4KkwofCo0IYQbEBAkEkwKh/zj9" +
  b"AfwT++f51Pc89oD1GPTr8hnyyPEm8vjyJPYK+B/5y/sz/iwB+gJbBP0F2QWJB04JtwguCYIKfws3DLYLeAwcDU0MYAvCCSkISAYEBLEB3f6N/Jz6dvi59tz0" +
  b"APSM8/bxBvAr7wHwrfBG8YLyXfVC+Jr62vy8/vIBigS+BegGAwhQCQIKDwrkCdYJMwpsCWUIIghrBzkGywRmA88BTgBa/+X+uv6P/Wr8w/s1+8D6vfnk+B35" +
  b"5Pdf9EjzdfQd9c/01/XW+X78p/13/8kBhwHaALUC2QO5A20E0QXOBnwHdghWCc4JawqIDsEQ9g4QDqYNNg08CoUHZgjGBmIFXARdAab/f/wO+ur3lvRe8mTw" +
  b"ye99763upe9O8fbyR/T29YT4Wvk1+pD8zf5iALEBtgOEBZQGjgdGCM4IIgmPCo8LOQoPCVUIJAfBArf+Uv7S/Gf6UPiY9334g/Ut8PrsGe3r77rwovCp9Kf5" +
  b"9v37/+kBugW4BSYE7AJTBOsG1Af8B1oIsgpbDaYMtQohDvES1BBwDUQOSw74Cy4IHAdlBi0G4QX9AvkD7wT4Ajb/5vgp9tz0IfJP7zbsFO4o86/2qfeu93P7" +
  b"DgCDAZgAw/9NAfYDJwMoAZgBugMCA5UBxgEzApQBZgFfAwEEcwOBAhIBMv4e/Rn9s/tT+sX5v/mD+lD4XPHK72jzuvTg8/fzTPgr/ST/OgH5BpEMNAvEBsEG" +
  b"mwmDCtYHkQU1BtsH+QfxCewLEQ1UDkQNqwthClAIOAmzCA8GNgPQAQMDNQFu/4j+hPxj++n0DO+T79ful+wW6s7q0/J9+Jr4ivlm/Uj/Wv8PAEf/L/9IAQoC" +
  b"EgHTAAoC7gLhAqYCsgIGA7UDWQXmBREFlgTIA+ABKwLkAjkB5v9r/xL/Nv/B/HX3wvWY92P4n/dU98/5e/1F/7j+3AHcBrcGYwM4AgYElQXDBJwCXwL2A1oF" +
  b"VQgHCh0KZwsuCzoK8QcQBdoHpgm7B6kEpwJ9BNEDwQHH/xP9avxq8WHmvuYB5zPnpeUO5/7yivh8+Jn7e/+lAc0ADAGCAUYCGQW4BYAFvgYaCBYJrAj9BxgI" +
  b"6gfvCLYJaAjgCqgM/whVB8cH2QaGBGUEqgREA/wARvpX9ILzAvMr8l3xt/I09wX7Cvsz/NMBdgTgAZf+Rf6tAN8BbgBP/90AYgN6BzEL1guRC5ILogkvCHsI" +
  b"cQdYBaACXQFqAcD/IP8g/Qf8hPjZ6q7jmuRw5YzoiejX70D9dgAKAl4ErAVnBsP/h/q8+Tn7Sf+W/9gARgmVEIwTLBKhD6UQoA8aCykGJwaiCWkJBAZlA20E" +
  b"MwXOA7MAX/7k/XL0oek46BfpTOy18W75ugQcCXMHeQjTCJsFz/xZ8xPyNvT++soAwgH5CeQTjRZwFLQOMAydCFMDpQBw/Rb/VgD0/iz+Xf2h/vr+if22/XH6" +
  b"zO+Q5Nbhv+T/6rzwBvhPBR8NjQ1VDDEMbg0SB+j9p/yz/SgFGA6yEs8Y7xuNGIET/AzTB8ICOwGeA2cDZAanCMEFvwKH/Qf6gveW8lrx4Oh822nZ4tz/4Lrl" +
  b"e+36+kwExgQ5BaIIbwquBtD/z/6vATIDpgkrEpgWHRgfFdoQeAxmBb79Uf3VAkUE9wRYCUkLoAiCAST8XfsU84PqROV/3ZDaNdzr35/opvFr+78D3wa1CEEG" +
  b"EAJ5AIv+OP6E/5MB4glCFBYYChiAFyEWEhI9CrsDpAENBkQK2QiWDUETghG6CqkCff/w/BL2nPFi6kPg1t0f3wTi7ed48IL7HANcBOgFwwg3CRMFevpC9K/2" +
  b"zflCAQgL4hEVGGkSjAjFBBwBofz493j6eAK3Bz4K0graC3ALoAZeAlD8IfeR9W3vROqz7Ebx2vfS/lcErQp7DBULNQi5AaL9evvn+SH7VP6LBbUOahFQEDIQ" +
  b"oA4/ClQD5P1n/O7/mgIbA3IJag2FCwkIuAFj/iz7ofVE8kDpTuHj48Hlg+gM74/2AwF6BqwF5QNaANL/c/uT7kjrVPAW+CABSQTlC/8TZw0hBtsCQwECAvwA" +
  b"KgWtDGARSBahGewZYxeiECsKwgHW90HyVusZ5kjoA+sr83/9pQJqCDgL1gqHCOkAIvzl+rr4wvk8/qYFDQ6REUgRNRD/DAYIRQUcAzn/jgAsA5MCnATrCGYL" +
  b"FQk8AzH/aPnJ8NLq991n1EvYrdw65tvyJvz/Am8EvgVWBX7/0/yx/Cj9xQABBpwNKRUvGJoXXRUHEfcKfglpCI4DGgTZBQIISw0BD2UM2gjgBK//f/cF7m3r" +
  b"cebf2+7dEuna9Jj+IgQxB9UHBgcKAjD5VfY++LL2wvbX+8UC3QdfCg0LhAsqCu0FgQQ6BdwCbAE9A9gJgxEwEd4PUw+6CqEErPsN8+zvGev13o3XLeCr7fX0" +
  b"mvosApgJ8guTCAAE1wG6+3r0K/MZ9fz5Ov8lA2cJBg08Dh8NsAqUC5cJGwZsBUUH3g2DD30NyQ0RC1MHJQHV+AL2V++A4K7ZieCn62zyTvg/A+sLrA4HDQwK" +
  b"4ghxAOL2i/VI9iP8YAG+BAwMfg8qEFQOeAqhCmIH2ALkAfMCvQiICv4HownsCNcEzAD5+kP4HPZQ6oncn9xA6Gnxv/VR/g4JQg06DPII3Ae4BBr5tPPD9Uj5" +
  b"gQHiBesO4BhtFzkVmBAZDLQJ7AAdAYIFYAZ0C1EKjAp0DYEFOP/6+2b1kPM07jnkReAR5CTtLvOw9sb+nQOfAxsDWQFKAXr9I/bp9mf5nvwkAl0F6w2zEa4N" +
  b"LwyxCFMG/wJf/iYDKQY8BhoM8QyIDPoLjARYAA39ZPaW9Ajvg+TE4H7lIO9L9d742wARBQQEfwMVAjgCev6W90n5Jfzh/gQEEQeADmQRTgzvCiwInwVGA3T/" +
  b"1QQPCA4H/g13DzsKMwgZBK//b/w695P2OfZi6X7e3+G46gby/PUD/SsGYwb6A/IEBAVe/rL0ovQW+m77Kf9cBbkLBhF2DtUL+wuMCFAGzgPOA9MI1gd4CGAO" +
  b"VA9wDXoKSQZgA+r+svly/LL6F+vh45Pp/e738ZL0uPydAz8BQQCXAzACL/kj8yz33PoY+3r/7AWpC0kNUwp1CgAKhgbdBGYDWwW8B6YFkgimDfsNWw6EDHEJ" +
  b"BgY+AP77a/c19rLyT+Zc5MDrme4+8jj3p/1QAgsAOf1Z/kD8dvVC9Ff5Wfwk/24DlAhEDacMrApLC6gJYQfkBfMEgwd8BxkFmAiuC4gLFwyrChsJJgdKA+H/" +
  b"Dfr999f0fOkx5/PsQu9W8rv2VvyqAOT+yPuP/J37S/ad9Y76of0TAGYCfAVgChoKHgjZCVgJ6wf6Bv0FLAeyB5AFiwU4B7MHvgdPBzEHlQYLBM4CmACO/PH7" +
  b"vPfX7avqI+628uP3gfvc/1UDvALz/9z9oP2d+zP6xPul/hwBEAFDASMF6AWoA0cEVQU+BVsEmwMrBa4FQgRABBoFGwb9BesFSQYiBX4D9QJ6Aar9BvzA+1Pz" +
  b"pOkc66nvbPHl85b5nf/0AET/0QC6AtP///0HAaECsAI0AxsEWgZEBuAHOQopCFoH1wcXBpgEqAPpA6gDdAFIAhoEYAOpA94DDwODApIBjACV/dL7JPxm83np" +
  b"8uvo7hnvTu8q8836uPsf+53/FAKDABoAdAOBBe8EcAeVCMUHgQjoCP4K/Ao1CJII7AeBBf4GbAclBbAE0gNIAwUDwQF/AogB5v8iAID/If7g+xL7q/sB9Bvt" +
  b"Q/AP8nbxI/Eu92f+cPyz/ZQCYAIfANQAfQM0Aj3+YgBCApL/rgBXA0gF9AUvBR4H+waYBTUJqAnVBlEHAwcgCeEIuQXrBpIFSgJzAbj/E/7C+rX5Tfq78jru" +
  b"JfE68sDxhvHC+Dv97Ppq/rgAdwDR/5v/6QEnAXEBAAMgAlgDowQ2B3IIfQZXBwkI/wXQBJIEaATsAqABhAKVAmkCrAKDAv4BKwG7/MT5uflB8xjwL+0E5TTn" +
  b"Y+sF68jwzfFI8+f6F/7L/oYBpAXjBSYFkgn/CtwKiw6/Dr0Nfg9xEzoWrhQTE4wTSRH7DWAQAxCUCpkJYAjhBIUGWQawAoQBoAB9/iT8Rfpa9yz3UPZU8t7y" +
  b"P/Pi7jPuqO6M7ifwPPHY8sj0HfTj8lP1tveq+EP6uPuT/ncAtQA9ApID0AHS/2MBZgSfA08CkgQmBgwH5QcRB40IqAn3CZ0M1AtDCgQLTgnCB0sFKwEN/6v9" +
  b"If6X/m7/aAGQ//f98P/W/pf8G/xv/If8yfpT/OUAJgOIApQELwZNBSkGBgYhA2wDywT8AIj+1QBL//H6TvxB/Hn4yfmK+Ur31Pgj+kf4lfZu9RPyDvEU8n/y" +
  b"9vJA8/r3DP3m/Gv+DQJ7AML9VP/CAsYCnAEdBHEGtwjHCnQJoQtvDsYM2gozDfAMygjKCAsKxQbnBJoG+wZzBqoFpQI5/h7+/v2f9D/ugfFG8JrrLeyM7s/x" +
  b"VvTV9dL4T/yj+T74r/19/+v+bAIzBQgHHwtmDkUOpw9SE5ISqxAIEsESQA+ZDTAOoQt4CSQH7wfVCg8IPgLl+rD3l/XB6ZHhvOP34OHcMt4F4ezjPOha7n/w" +
  b"5PG08oPyfve5/FX+EgJ9CCsOyRHcFfIayB2+Hm0gcSGoIWogyx4SHCcZERdfEfoNvA8lDpIHLwUfBc8AZ/uu9oTwbe2X62DkcOBl49nizt584RbmHufL6bjt" +
  b"7e9J8bP01vit+s0ALAmnDS8S8hV+F8UXQBffF3QWdxSNE2cQmw3QC+sHFQT4AQ7/ZPwl/O/63fUd8nvvROwf6T/lAOXd5X7l8OcO6cfqCO+u8bf1wfca97b6" +
  b"8v7mAasE0Af9DJoP4BHjFRsXdBhFGika4Rk3GfMXQRaQE54RtxPoEqENQA38DB0IJwSTAGn79/Ys8+T0wvTr79H2ufqg9QD5C/x5+tH6c/oG+af2Rvf392P1" +
  b"TfqC/3P8gf52Auf+zfxU/77+Jfzm/K79Zvv/+lX8Rfuh+mL7IfwR9FzwN/SV7pDqCu0x66rodurT7VXuf/Ak7b3pZu8b8t7zO/iX+Wb8DgFyBcQKDA8+FNQY" +
  b"7hskIM0ifSQxJqgmVCaUJdAnZie/JEslRiIbHacZWROhDKkGKwINAwr/E/mo/lP9YfZq+fH3afNt80Xx2e206ovq/ukc553pqOxE7WfwcfKv8+n2Xflh+pb8" +
  b"d/wg+2T85PtM+6T7cfkq+kz6n/io+Rf6jPiE+Hb7afxY+3j9tf65/Un/+//TAJoCiwGDAxwFUAT5BMoFjgd7CN8JEw37DOALrwwIDlENIAu0C3wKRAfCBdgC" +
  b"YAA4/q767Pzv+533w/u+/Kr6R/8tAqQBXQGJAgEDOAA2AH//0vwb/bX7Pfv1+mr53/hQ97D3t/eM9o735/du+Lr3EPY7+I/47/Z3+Ln5Cfly8/HxUfcX9MLw" +
  b"p/YR+bv4PPylAfMCGQPxAYQBQgScA/4CMAXpBJQGvQcRCZ4KzwpvEHQRAQ+dEvUTsBOIE4YTDhQMC0EHlwn5AEP7gvuh+rD6jvjG+zsCDgCLBBEQGA/PDXIT" +
  b"exNZDo0LTAt0BY/9ef3t+3b0MPIk+UP4SPIC+P77jvd2+L78jPoF9pf4Bfd88DzxbfI+7i/nYucU7OrmfOVY7fXv6u8n9h/9L/9ZAc4B8gK2BYsE2QQqBvkF" +
  b"vAa1BgsIGgsEDFgOohCCEKcRdBKJEiQRQhA1EuMLXQWHB0cDq/pL+S33BvIn8ArxGvMO8zL0NPzgAAkB2QUXDI4M2QojDmsQYAqOCVEMDwjYAssEGgl3BbgE" +
  b"kArJB94D3AaPBSQA//5y/R75ePVV8TLviOyD6STpU+UO5DDnC+aM5uLrw+8P8iH37fwu/sH/hwG7ATYD5AKRA+MFdQXvBo4IRAkUCrgKVQ2MDYUMxg6XDpYN" +
  b"5w3xDAsMegqbCI0H4wVJBD0DAALRAN3/T/8F/5b+6f4w/5T+wf5T/9/+Ov6t/u3+OP7a/bP+9/7V/i7///8FAJ//6P8DAFf/2f7Z/kz+Rv0=",
])

///|
/// `5.15k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_5_15k_fate : Bytes = amrnb_cat([
  b"AAAAAAAA9P94//n/aP5VAAz4VwGz8fgKw+zxB8b6Gg1/+J4G5/WSB131qAE+AyYFFPdV9CoHkvBg+HHzwghW/0UBRPaFApHxfAMO/mACFwKdB4UAfQW86ioN" +
  b"uwNr/uQQOQYsAwT1Jv3oABv/EAJTA24JAw72/Nz6NgrO8z36Kv9JBuEIivrE/sMKm/9MD2vdfg5W/O/1M/3gBbIGJQBC/8gCIQHq+k78FQHg/Qz0XfWpAIz6" +
  b"wwm8+M3+if4F8msJJvmCAAkCOwFmAT34swLiB3L/wwki+e4GtAmf9/oO2vNgDoj3SgCRB6PuVQKMF9rbTgcYFSrx6wDsBEf1OwUfBUwF8/rE/YL8ov3PDdsN" +
  b"p+wrAV4Pl/pD97gDqxKC7of5mQoB+9EGYQQA/dgBovaCADYCSQwx+Ej8QAg+CHbm2wf5DkTxjQMm/1H5lQiYB630ewJH+7sBIfoeCNX9Bf/B/UALs+xRBGAI" +
  b"3wGF94gCivpqAiYTNvU0/uL4IAQp/d0Nrfh7/Tf8EA6S73//vgi+Be77f/7w/O76Yw26/wT/z/sjBAP5NRGj/lH5z/ZaCqv6cfk8B+gBuPh6Aq4D2/vCBxsA" +
  b"lQM9+cQAovuFD/H+8fd5+SELofpt/Bj74gV5/jj/z/0cBD375QENAAcCtf1r+goGwACc/p76ZgXu/ZsC2Po/Bd78mwDG/AEC0/2fAMsI1P47CMH7Z/+n/kz6" +
  b"dAK4BScABAZH+gn9jvut/1oDCv8I/xICFv/C/yH8d/tUBOX9HwA1AswHUfzuAjv+PAq+/wD7bwFTAo8ETPru+5sOagPV+TsCK/9vApX8Tf0WBz0CQfr8AtD6" +
  b"cwg7ACv+RAPJAB777gIv/DIIBfyU/p8BTf0w/H0BBv5UAWEDCfwwAT3+JwR6/yb6vwNBBCD8QwIb+kIFUALV/GcDof1xABT+EPwYBsQBgPso+i8FiQu3+ZT6" +
  b"nQQDCwcMgPBi+c0A9QGcBY8APvz59dUILwml+R70of97BN0GavEt+S0IhQTc+Tj9wgjn/UH50gi5B3f1Kf4Z/EcLKf/n9NAN3QDdAErzCwEpDVLztwtzCQz6" +
  b"UfoO/1wC4PxO+1QJtwIx9XT5OgViBVb16gMoB47/Xvno/Y4G8gNz92gMqgWZ+aP78gFKA6/1VPw3Ck4FBftd+p4D/wbT9hsEegcvAbr5V/q3BbEAM/koBhAL" +
  b"BPm2/zb8DQhz+X39OwlcAzr+sfizAVYGFfUTA8YJtwD1+df83QhkADT1XAcSB/H4FPivBKsDtvezAXYFRwEL/Oj70wL8AEX+rwSSADP/C/5PAsH/SADFADT+" +
  b"SgFy/0EDbf2NAIYBCwIUBOb8Af+bAFgCKv1K/8oIu/os/1L7BQbgBvz7sPaC+EoBqgORBNEBh/5R+zwEoAQy+/79JgN3/nQHhfmf90EF2Pv3A7IDG/pQBEf7" +
  b"jwEnAzz+swJbBp/3qwW7/YUCd/0G/ycHZf/uBRj5bvmyAbIA7QFa+Bf+OAet+V4CsQYo+10DFANtAu71xPwtBFb7i/pTA7j5KADC+iIAiPyP/nAFXfto/w0B" +
  b"lfXwDPf+5PecFEX8hPt6An0BzwOw80cbxf6u7lf6hwcRC7wCyO5p+wULsQU0D/P2cwDoDo0AtwdNBJLgowGsFGwDc/mOBsEG0fni/LEXXgU8/hobo/zfvpL4" +
  b"OCFeCYDuffaIBO4VegFoCUrg8ROzAFkYCPcm/AwySv6/AGT4nh+CC4sWJgpkBDADqQTdAiUAGuXo9WXjaPr+85sA9vxuBgsLSP27BYr+YAdA9HcKQ//GCm38" +
  b"ufcgB7byOg8a+c/39wLKCL7/hPcx/QwBwgYk/+f+/vziACQGnvvQ+YP/XAJOBC0CLv1r+Zb+/wmAAh/6EPZjAjUCcQY1Asf74fi0BxwGY/uC+HgCzwRCAkP+" +
  b"NP7PASgFKACA/Y4AB/8eAKAAOf86/v//0QMpAlkAKP5g/xwDFgJ1AbP8owPv/o0AnP94ARoCmgQE9H7/QAwc92sAo/T9B38KNfWH9VsK6wIW9sAAsAAsEJwA" +
  b"9fKOAZMSiQWD46oHseHbHMbXlQNN+5AnsRjK+OcLF/GADSrN8AU25QIgwfqu/eIUl/giH/DMExYU6Wwd6dhtEEIAdg7SFEPblyST66AMAdb6HF3tohIB/fcB" +
  b"PBIh+IcN497/HUjgvBP45uwVEfF7Do35bAOfCXj4vQ//5JIWGeWQFuflpBOY6q0ZGfzW/Hj6IADUBf70kQ6WCqTrnef6GgQInBxbutEfOQEvBf75oAA76NYc" +
  b"OenDH0bRkhtQ6CMcA/LU9C4A2Rza5s4C1P0SCkL+7/jeETQFt/ij/CYTdf34Am3mNB1G99P+kOnwGFfxuANy8G4V+OfsBbjyBA926TADGAZ+CrHyhP0v/IYE" +
  b"/O9kCb8FMP7S77UECv+dC4rs/Ag3/foEt/7V+YwHpQMGAFgGvQWA+UoDeQJxFePpiQJtAsEP2PY9Dojltw0r81gTVQKy8nsCSQYzDf3xqPqoDJEFIgsh7cj9" +
  b"pAJTBzUGx/hK9PP80wqsB6T3ifjLAn8DmAYA96MAVP+VBKT/b/YPBloDqwJNBVDtAwmX++j4wQ0b/db2kwVK9tgTEQHE8okG3/sk+1IMj/rl9+MEi/4uDYD8" +
  b"we95D+b6tgb9BHHzuP9eDGH3zBSp6F8GgA6k8m0HZfqJ/CgXq+3bCyj/6ejLGUjuTA0P/XTmEheBAun5fgaB53QZV/Ye/W0KI+tdClH/o/9EDuDhOwuqCBj5" +
  b"Wwkp6LMPOgmr89sFZvYV/HIUJvJfB+j6cfZVEpwBRAB19Nn57Q+z/wv5bABLAN0DYggGBNf1uf0F/70Fgv/K9Rz+wQXr+9YCcwAd9B4JXP8lAVEALPAREGgK" +
  b"2uw59ZgSoBCF+3b+svMxFBfsJgUR6hEP0hMd9p/0jwec8doShAQR7S8FXPytEs7zSQHYB6j9uvjmBbjw1gUeDPT7rwB/+x32Uw3tB5T+cPIRAmcTnuPSEKYC" +
  b"I/pGCNL2RPFVBMEBngPH9Rz+m/4L/4oPSvqA/tT5mQRWAAv5dA46BL747wTo95n3QRCS9+z/KwaY/GEA/AcuAzT5WfiBFAX0ZQDsDwH2CArx8pD+qP5sBK0B" +
  b"HvK3CeL49PdFDFL4hgCp++QAMv+ZBwEAlv6/+xwH7/LdCPoLIfSH/mgFVfOfAJENqvmd+sf7Mv2F+ZoTmwJ+6ywK0wOn9L4OCfiFBCj5OAMDA7X2Sf4RB6/6" +
  b"bgbD9h0AQwJ4Ahn91v5uARQBIgN0/24FJwJKAAD/hP9v/2MG8QLd+g3/NQURAzD8Afn7BGT0tAj39icCtffxA5YEfQgh+ZEJG/19DbL/c/pXCaoDagTcAw76" +
  b"aATyA4vzwQiX/E4AagD5/Wb4KQBwBgn/LfmcBJX6HQjj/y0ClgbH/8ICdfuqAw//Wvyn+4f+Rf+3BjcFp/7K/wr+/gSeAv4AT+/I/4IBwvxRAWz41/3QBAQE" +
  b"Mfu2Afn1RwHCAoH/d/ufAWL93vv2/dEFwf+e9mf9V/7PELL3agF0++j8f+//AqQG6gHz+qMVaAnv8/j4t/1FEBH1xvd8FwwJDPMU+E4BeAeD+64BoP5j+yIC" +
  b"mPkdDnr5tfXpE9ENmvKh+Nn5chc4AYj1agMv9ygBTf/s/ZT5rvnaDyH6APAh/7D7ARIl+3LyqArAAn8FX/Mf/1cEsAZ09JkE3fsbBDr+oQa2/2Dyfwt5Asj+" +
  b"UvJoAFQKXvVr/N8Nz//jBSb0DAVuDLn5PQQ0AQL8g/0y/0UFRQIZ+X8UEgLb9B35Mv+xD7L5sfnpBXP7YP129hL9aQqo+AANpgOk/cj7sQEqANv8MPnBBzUC" +
  b"6/p3//QALwgJ/+35LgbI/eb8T/x0AxYCAQqR+9AA/vqQBx0GR/ws/uz9iAvEAAT4p/jE/R0JRwD9/s7/wwmqBOAC1/qZ/50Ppgga/gDzXAm1Dlb6qwVK+KMG" +
  b"HQEMCKb+8f7wA9D4AQfW9PAKJwXp+J8C1/g6/10HuvwcAZEI+/wHBW36wPbeA1j0vxB38pUMKx2j/ywOrPw591QHnOhOBZL7NxpzFG4BkQRMDJb1agz0+6j1" +
  b"Aw2dAxEGWf7iAWn8dgAu+jQEvwIsF0b57xMa71cOvASrDw34nPqi/fYEAADC7ur6yvRY/5f9YQn0BnD04fStFcT6WgM5ARsEiukgEHUN4wNMC3n8AgHw7vMM" +
  b"DfVZAjT73hAW/MsE9v36B6kFSAhQBgoILu+XDCz3rgFVAe3x1/+M5KkIsfj3A5/yu/njCLAF4wOe/B8EO/zRBLoDxPIMAjUF3wQ1BkwBUfmTAID8r/+i//by" +
  b"ZQOa+E8FPQneAMH9OQvNC9IGDvyfBC/rigRH8XP1yf+OC5D8zvMt/1kJe/5k+NEFtP3Y973+wwuI9yX8FQHH/v75twoq9fgDlwb8/dH/ZfgF+y339fS7BccH" +
  b"Fe04D68BtwSsCKP/5QA5BRcBkAPx8Ij/2AWLAKwBPftF9i3+KgDcApj7ZfzcAy3+Yv7uAhn5DQDnC5QDv/089wAGQv6mB6L7E/1X9C4HePuC/K/4Sv/t/wEG" +
  b"dv4GAn/8cgY0Cnj9MwLq92oAuwXpCiHmVwdt8gcOtP+s/8MCYfQbAy7/5/2ZAof9ZPvqA1X+GQL2+78RqvvZBgL+5gqk9VcBYvs3BCf/TgQr+bUCjf/r+2QD" +
  b"AgQLA6P6bQL/BlwAH/eKBI/5DwSkBXMDuPinCHH5AP7p+KwBzwDc/Nr+4QCR+Tf/dgjk+vj8dQgDBMP/JQru+lkDPvm2Cc/26gLt/c4B4PsJB5j9zPy2ALEA" +
  b"NwPI/m37UfbN/Ev4MgPUC9TxjASfBnT9IAlR8ozrbQQzFQj7ku1C8GcM2xgVF4nlhfguC2QPqxOh61cKTg7rGXP45OmJC2MObvIEDEX4BQZnCXD8WPkpAFAG" +
  b"lxjh9Yr9HADHDbkbidoa74H00/3SEYYSM90LCrYFWw+CArr1qOs2DcsSyehJ+OcDYffk+lvvVQQgFjj6BhrK6ywH3AOMC3/8cfzqDswDbgPB/eb7mgEDAjH7" +
  b"APjLCRr75AJk9+cJFwTMDLAEztH57sAAOBWiET0Affs9Bf3mJwfX/wcFuPCH8i77vgdSAfgARQv7/TIA3wxOBdIPogNV/Hb6PQI1GBkEaPiM9Uj8qBCUCSQB" +
  b"tuP+9/sMoAM1ARHwl/yZCHYTQAqL69kKKwj2Elb9JfIjCzz0LAENCCrx2vw0+B4EvQ4m82713wMdDa0HhP+R8bfzNg3nEhQMevJl964IgQpZDMj5gvHyBHv7" +
  b"mA0UBbPs3v1P8lkNSQYO+Rj+PvVCDVgMIf44AGvuvwEYD70HqQAh5lz/egLYDxALYvi8/Ur29gosERn7ovqD7NsFzAHhCLIEVvWZ/Pnuxg5nDLIG5gU86OsF" +
  b"RP6zC4sIZ+93AvrwqAwhA+QFfvnO+kYCAwbNAxv8NvhJA9v7HQMZADrxoQmO+Z0Bsv969D8ID/g+BzUMPdXIAhsTC/4nImjsz//j+ujyNRAc+OMJyv4D5ZAE" +
  b"mRixAyb33vWf4PIYqRAm764MDeL9CqAHFQ5PEbbi8QN9C9oDCAjJ7XEKuQkpBhgJ4e6yCBj6swD3+8r9Xwjg8xEBevaM/tcTzP3b//v1PQz6/aoDsgKO5pEJ" +
  b"AQPCBWr5e+5GCG8FlgfrADjv1Ao7Chb/G/i1+vkC7Q2KAA7xE/p8B3oNQvxB7+kE1/9BBzUC+uonB1IOQ/05AJDviAUdBu8BgQfW7SIF3g3e+Or2lf4FA5MI" +
  b"IQHI9dD4Tgv2A0YBwu8yBO0AHQZJA0/ztv6HD+gBi/wk97UDlwaz/j8Ahvy2A5X8Lv8k/uUEmPtfADQBRQQy/uUDCgFzA0L7yP+k+XgC//29/vMER/leBTwK" +
  b"ZPE7ESb4afaNFIXvNQ1m9D0DXADDAK8BZ/7Y/qMAqPvQBFz2Jwul9gYEHQcw/V4I1/lLA+P8zQH6AsEAPQC8/q4DnfiRAHAGBvBTDk7z/QLrBBT3+gfl+gkG" +
  b"zP/F/ib/wPf/Clj6ewB4+535dg57+hoG2PWE/yQGeP5WA2z2jQHmBTn+Gv/u+bADYwHYAmb5L/2lBVr9/QIp+cEEwf/gAHr9t/5D+T0PR/gi/8UEcwlN+4/9" +
  b"5PtG7zMIUvpiDzbsvwdqAlAGawb5CdHl/xNBF9DrwQ3e9zD/PwfhBIz4H+jsDfEAzgMHCLDxhAoD7aESwesGDU399uzVADkH4PS0E4T2IhNA3VQNFhRB9/EI" +
  b"DN9gA1sOnwGK9435JwkL8QUFHgPb/IgOBN5pBqgLawWaBeLWHxFQDlH9JgoJ9Vv/ufYNCcEFPAKXDJTYHQ5HAVsJGgAH6bgQLfpVCdkEx+6xEFDiHBLy/6YD" +
  b"bw5P54INJPXABOv6K/vVCZTx2BW59qD8rwww77gNmAaM/MP4Yu81F8nvGxCJAGD10QNW9JcPtfaTDw782vCQFMjsiREM/JT1LAsZ5SgY8PWPCcIABvSrC/Tv" +
  b"GRGo+0r5PAh76ysb/ONLEm/5GfSpFsDepxbj/Jf2wQrb/ssCa/p/CCb/wgSnCyfl7gjICn36bhpa8nQObettAxkLFvzNBSXXCg7xEB/6Tgdt8TYH5eVp9wcW" +
  b"mwyx84veHgE6DswBaP7z884NTt/PAdQLYAcwBSvR2wvUGIT8+xKz9N4EIAbWAZr9DAdWA/vcdweGEFgDeQbh3s0HWRG099sIWfo5CafpDQyhB+UJOPwQ3FsI" +
  b"PBQoBfsE5eTZBqcZ3P3+Bdz6wQCU/bsI/QDA/kz9SwUYCGv8Dv1+BpfwgA8T48/6bRLE+7MXo+Cs8YIcnhznA3DZG/ngHPYCrhGAFQPhwuUGFu0ECPLm86nq" +
  b"1B3G/ID2tfyL7SAZX/am+ewKou0FDMsNFPDRD/PsKQwPC0zvTBRR8EoFoQxE850Z0gCC9sP2vQXUCLoDTQCg9QH+gg4uBI78N+JQDwQLTgtB/+jnCAUfCD8I" +
  b"iuKqAVsNNAkp/vH4LPWrADgXRehW/Sz6DxIECTH22/m38rkP8ABd/7DjZhOrAbcFY//f6gwHyAb3Bd7wk/jnCwb+UQXE+xf1EgxmCar/BPNj/JsE/wQaBGPx" +
  b"E/inDOcKovvS9X4DvgI3BV3+mvUoBHUGtv3B+SsA4wB3BAoAKP0KAjgBuwIZ/o79lgHV/pEAGwEf/kMDzwPr+twDYwPJ+1YD5APU97UGxACR9v8I1/sR/KkK" +
  b"gPXZBQQEgvIzCjX7yQH2Dl7ysQFS/vv/8RLm+E0BEgFM+PEJiP5a/+YFY/hfAn0EmfvqB1f03wFdAQoCpRCh6f76LP6NDdMHadmmCYIBQQakAR/fCAugBrkB" +
  b"7v+D6OULKwoi/CwD2/JdFQXusvaDESwCHw1X70j2/gdCDRgMOeSe/IgMBASfBWLpbvtUD50DAApr90L0GQVC72AKMQe8Aj4Fqv3//ekDeelwB0gDdvGuAOsG" +
  b"O/19Brv8hgFJEVr3U/WSBA3/5QBO/EDzdAmlAqP5wRK843wI+g3O3n4X7/rB9zcZ5PRN+qH6vel9JA0Dnelx+dMAUQ1H/1D38fEwBQwLchOO91jtCwir+iMO" +
  b"JADD7xQKPQM4/g==",
])

///|
test "amrnb 5.15k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_5_15k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_5_15k_cref_head),
    2,
    amrnb_ref(amrnb_5_15k_cref_tail),
    2,
    amrnb_ref(amrnb_5_15k_fate),
    16,
    2,
    "5.15k",
  )
}

///|
/// `5.9k`: 4550 bytes, 284 frames
let amrnb_5_9k_file : Bytes = amrnb_cat([
  b"IyFBTVIKFDkk0CSEwwEaLPjYAI1UgBSclavBlaaIjlgsjT+M1lQUikzU2orEVRfCqiwQQr+cFNwM14w8LmgOfljCDV6CuBRaDOKYaH5fzmV35ADrvCAUnAzk" +
  b"6JDCHS5tHElZWqQIFJwM4niQwhxOcN7V5PEtzBScYuLbE0oRLnx5THslfIgUOQz6xpaSBM5jcI2V5Pf8FHQM75oCUjduZlrBgFV2vBS02u1oeGHS1DRnBGqT" +
  b"9KgUz7MX60sOMzPSiHkNSnogFOkHDuJaLxdv+svRhXPWbBTPCK9p6cOZ18Es209nJTQUiuDH+CHdG65aRGcPmfc0FM8IlZT0iIzXwcaSLsu2SBS0ORekdHLq" +
  b"7l5vCJNsh8QUz1CvaFAL3vPDBcGmjZBYFOqOh+4/lgdxNHi+CnD9uBSKRf5MTmzi6JNF2gSHjWwUz4kH/B6eD3E6OvJZie1QFIqV9sz+4sjImuZJ3Trw0BTX" +
  b"jof+GpZX88zCfSTBaGQUihJ+cmlrP/E/2c2ARzdkFM8SKyQF0q+gos1Zosy3tBScN6uUFLJNTl+FsHz2diQU6b+LOrK5RFPyuLkCaRM8FIGVGp2vnAAbXZGM" +
  b"WKtJYBQ53n+QCGL+8/GbBjkmFngUOZUYGQEeu7P7mAlAQ4CAFDnef5iC4U3bR7g8ggJ+3BQ5v7C4ZIi/YXtHSGShi4wUOVH1qLDl1dscuoF/otUcFDneZLg0" +
  b"iNrYaY9SdjaIDBS0v7C8JxxDFBrDceDM3OwUzyPr2ESBhbhsMdn7XvXUFM+/41remAXdgZZOzRpOJBTP3m3U1JbIgWyGDG96IxQUit5fpwd8IUaY86YN5ZFo" +
  b"FIo5ZdmzwBnUFCbF2tPmZBTpv+/BAQGqtcGlCLxC/xAUiiPj7Fz4D92f/s2iFvh4FOkwZ+LCp1HD9hiK2DOeiBSKV+fqw6UAwlKKUqKAfEwU6d43tlb+RG/6" +
  b"4+JZ6dRMFLRX5+FjkzO9mL0zgVHUVBTPlWfoiPfc+xOSP7cMjdwUtFf3DQ2AC7s5xBzsIWYgFEQt5b9nwCK7OgnXUTLv9BScUM6YL44Zm0jxdeRaNtwUigjj" +
  b"2lrxVEvZSxLpel9sFJxM8aKivlV7RTpgD7OgPBSKUOH54bETvcxOutQ3hKwUdDkk6DDNz//tTFWVSvlwFJZX96gQ5/X7Ks8Lh0GNVBQIV/nIoaFNQWjquL/C" +
  b"idQUCAiWYMiy3dPrnnL+27IUFOreA34+IkZz49Ni6UhlnBS2EjwqLjxXVVEDUWFZkrgUzy2iglIGcT4FKzKTjj1UFGk32dlRWhkvLDXbiiFkiBScV4fwcC6e" +
  b"ssT6XCVKubwUad5fWBAfhHUNY0Bfk0ykFIEwY1pKBBYASGuGDplVFBQCuhxZYTIaFCzNVddMGLwUOjIlZiYmInr+U3SxaoN0FM5y55D4zB3nG454AjnQOBTP" +
  b"I4uZ+fEJkVuMwEh5iAQU6SmDvl5eZ3rjk6AAQO2cFIreYfoieSd8c9dy7EsZTBTpg5uRyauZ1D+EmAovujQU6eCpubv7gZFBzrYPj+skFJzeB6JqRXf0WYwc" +
  b"fO6ArBQ5OXT4HQy6tDrFGssycUwUz1GoLi9UAis5O2ThF200FIoSJzwdOitX/k6k10NvLBTYet2UFqIMp8+Bh2C6bBQUmvEZ+AMHDrt1IzDEpZ5MFJt6mfgE" +
  b"gbf9gbtXUVM9RBTXCLlAOhFsVdmHPa+GwKgUm52hfHd+rsVl9T/ISwgAFNeO4HvytwF8HPSJ5xT8CBTXOTEI+v8cfYqTugmKwTgUz8NoenZAJHFBw8Dx8HIg" +
  b"FJvgiYDxlJGgvG04ZZWsbBTXnUDBWaoYiSx8gEVqTCAUmt5U8ZHbgZ4MddwiACCYFM8k1NoCZHdSrkXprS3pMBTOlQGIFOBPtC5tUqzJXzgU1wh241tOE60U" +
  b"mRUu7IqQFM4j1PJewnZrI5FkLEDQzBSbEgOkZXounetlZ+AhmiAU1wgBlX8MCqaU80q1Xuo8FM8IpcNHGjJ7ZIEoWVmoVBTPEEvaMnltYUdq3dDIeTgUisp8" +
  b"+v7uRZKwKtU2EboMFGAI8Pi4rtn4Z91yIMnMyBSKg1PefnJjRpE0HPANFnwU6jeHzW0CijtKEQdzkvRsFM/2p61VfIu0Mw31CZTwWBTPiCei4pNRwLPH7jdE" +
  b"mBwU1455yOn3WU5Xgofbi54wFNcLUxAUNO+vMg68fi1bKBSKiHnKruRFGeeZbVwBIQgUzzkHkKxej+8/RkyBNU4AFIo309x87sz6M5RGQtvrjBTqlWHs7NjJ" +
  b"izrRdeyBDJwUz1Gl6iszEThzGMNdS1RYFOojqRJmXg7GhLPtwyhwzBTPlQb6eig1+HtXPiAr+3AUzzkr+1s8EXPsu9Js/1OAFM/eQ9JWeGDGgr+I8FjWMBRY" +
  b"OS6fLywCpoOx0dkDxRAUzwjDzO3wSZtOVHdDmGgwFNcj7vwuVCyd6Tf7GJ+MUBTXV/n2F2RDXh7xCkHW6pgUWMb41VWiC6aV1CvERdXcFFh62tm9/hn95UNA" +
  b"gRX5dBTO4o6CkshQSJvvMJpxuJQUz1CfnXVQqqiJh9IJW8wQFFgbpuXN7IVd5HgNrSRYdBS2YKyuE0hnE93oSPZmoDQUnEWGDLa2BHpXH70nla6oFHQ35+oa" +
  b"eDVuW6dCpmqZdBS2iBqTM18zOzFIWS9f9gQUdFHh+GBRz+fRby/lQdFkFNxRmBoaf0MGi5vYELfK+BQA2tpoqNOFz9s+40D7M8wUnPa/POS4RMQTxC9sBxQQ" +
  b"FAezGp4uHAYv80M2+OWsJBQHWBuRKXubuxIxOX4kUCAUtPa9vUV4oo/qIdOWUysYFLTDclVNJgpbK+eUZ9tiaBSKEkXQAjyS+yTPBpiTOqgU6ZVbyCQbXw/p" +
  b"D7cTKbP0FIqVqbUFLqg93GHmPkXkjBS0laalbeQIr9+UruY0uMQUtIh7wJL7QFh2xpgHLQ2oFOpIbeU1eiqv1xzWjxfl5BS0DOfgMDd/+wSXg91fGrwUtog3" +
  b"qlJfdy/fca+pnXAUFLaVbc01Xqov5CVfYFFLqBTqlef/F5oAD8k58Y0FQQQUORJvc7uOEBs66iI/D8LkFLTKLIJibUd7LiP/lxrFrBS2lSmeXkRnb8wwHUgn" +
  b"VuwUORUVwKDtXUvIhpRheKswFLSVadCw9pW97H7PNhtzQBR0lXz8xKoMqJ4GZRm03OwUdINveQlbG7EjPSa4FUr8FJwSRWCQ7ZUGmpJBCbBTMBQA9rOo2ogV" +
  b"BBXm75Yzh6wUORIlcKDUXc/vCFp9WgI8FIEGMQoKKBZZNlu2whqnZBSB9vAqMlEHL8KzLSs4ATQUOYgG/U0+gLk4NXrj1Zd8FJyIJ/REaCzogscaKyAYVBSB" +
  b"Eg3UpJwM2SjyA+kJU3gUOQgN2SFVgz3ESRoowbkkFDmIDdkBPpo5LX3jAXfr9BQ5CB3AMAhf8BF9lKjI1BAUthIN8c3KCZAkRJxrj1EsFDkSDdERS6Ggti0Q" +
  b"mpvtfBQ59o2aytEFQK4K/Sg4/RAUtpUN4Ij20dKuy8BX2FssFDmgh/EhfDsgoO0Yxje5sBQ8G5381JrMx9bW8hdabtQUtpWH/i7UYFk3WL1829A8FESVk/iw" +
  b"tdnYUjuoi2hNABS2CIXeL74AL8mT+a33hCQUtgiF3Iz8xW/kAuqzZQOYFOqph+ExNbOL180L2zVnKBS0UI9Ly9MAETawq7pLkMgURAy7nz+8AD3IAebRS30w" +
  b"FLT2pdYGFmYxIZqMWGXSyBS2DMXZqe+ZEvvAU+IGaOgUtlaF1aX0CZk+Fh24I/IwFLNWmMqqsFn7FlpOSpdAxBS0AJOhYTab9cRLi4USeWAUtEwXs2MVMQE4" +
  b"iVKEvWxMFDlgifhwGJvZ6wpzY6BEsBTpqZmYWC1dayV93+oPxogU6WCH+nJSVGss+d4OHd80FJypg+pS1hRNDRoroTOVKBTpe7mQQAoPM81PhhIECugUOamG" +
  b"2iIeNBv+WkT/hvd8FJw3w8pySBcS0NrV6bhSdBScLYeMdHKO09ugsUCHJVwUnBVD0ionBg0TklQ3y+D8FDkth5BJLxsOUs3uLtt4KBS2C3n6Yj9DTlooiYc6" +
  b"/uAUgQwsuCBGvY5cD7Ev/9B4FERlLaBIIHrhYezLj/b2MBQ5WHjYYAy/oKJKx2eycTwUiAz40Oi5nY/ct+PA+WyAFBP2+TgYRl/Yf199/pTBuBQTlXlMLRQr" +
  b"59RG2e00emwUVkt4cCg3//syxhzaafxgFLMj+GFlfKE7Tr7UOsKCbBQllfGoOkf24KWExNEXNtwUE5Vy2CEFns5VR7I8dnb4FDwHeBp6bXNHzodhMmT1NBQ8" +
  b"ldJSBiB3rkOhuz2GZiAUiEX4eAEAveaOnMzsDJvUFLQ38vsrExMIkmX3piUTEBTYiFIQUtgWMqCjDaP3+lwUPIhhuHBEeesk/e6YXW0wFM5X+NgAU/Vzzupc" +
  b"a/Il1BS2y3mUjuIEqyUyTitpXCAUzvfw+anIkSalquRIyLiEFFgSe4k5t4HmpG/vJBO09BTPoLGUhJSFayx+gvxhxnQUz5U0+dmsmaiM7FdnweDMFM9F4fCZ" +
  b"jdEcBJP/gEIPEBTPw33b8/QQHe074gIV9VwUz/bx6MzoXUjRl69zotgQFM8M4an79RFUO4af1czqqBTpRdGB8ZmIe3GPKKxx6EwUTAze2bvLAckl9Osthe28" +
  b"FLjg/50XBqKzwgAKnGpyABTLEK05masI3/TkYeSDz8wUdPbI3m4ERnPNQ2R4VgncFLgt8pE1WCq0FsX4sx6aSBSK4PjSGsdQQKhr7ywgLAAUikxwm/viEUfK" +
  b"KlSOlqJ0FIpQ4blbJbuqjuWQIlt01BSK9umCj5FBSyZYABWCuuwU6hJh5IW0iZPW4wFmg1xsFFoPS2jgsFnZMxig4omCdBTqDMaOpqgECJGiCcEYK7wUz1GP" +
  b"TJyijLVzk/s1G+zEFLQGc9Hx8hGIka2ly/MFRBTO4tIA0LkV3GO/D4kjh5AUtsrpeAByt3ElfjODy/48FLZweHBoolvBEy8Xh+PHIBS2p/h4AB/3pIWJ66+B" +
  b"SCQUOaD4eAEzK5L+j0iaMiYkFOpEeGiS8UHICCrFZ/hLEBS2SHhwDmzHaI3JOwIQ3IgU1wj4cghtF/LqY4LG9VQgFOpIeHIODHx9zZnQfPwyTBTPE3h5A2OX" +
  b"AKxkhPJSO3QU6sp4eAMFbeCpaMjrycoAFM+C4fA9NeRBOnNA8+DHiBR0N/hYGDK23fPeFXgsWmwUtvbw+CCTTlfTpXvIhQrsFDneYfhgR+HXyI4XU6zozBSz" +
  b"I+lwTKzF98sA5HjSc0QUgd5h+GFnoHfHpzreVnpAFG4j6XhCGWTJIZKzfGPS0BQ5I/h4ABnk8SOzBji8qnAUgSP4eAGbDIk3N6xMI/EkFAY3+HiAmUiOVARg" +
  b"oVfmYBTOlZcGZmBCPgyx3Lc7VcwUtFfhqnIpA0suWhc8ToEQFDkj4fg4GW2TxEcquHpMKBS0V/mYABrL/Gz+jAqQytgUOXv5mAAbx+8zLttF6XxYFM5X+ZFo" +
  b"Y43dmhz43Z85xBSbw3m2dlIq0/OfaP6QQSgUmyThtkbeYVrzU4K92PesFNfDSa4+FCWHE8VEo7CyTBSbrDGWlp5FQzMCsi7yyZgUzy3J/i7iQTQ3K7mGOSjM" +
  b"FM/LL2wMbHvxUw3EOQFIjBTPLa9cPjZjnHofUTXz4BAU6YNzJITszM31LoGeooiMFLap0LtTPzMyXGu8PqEyNBSKN49ml4QB3flQigLL9EAU12CWXm8QRnxt" +
  b"d1UzCsgYFOoj01zOkkgvL4rcUfhfYBRYe/P4WbyZ89KMkBSgulAURLwtpDyEwiifbgF65ihMFLZQ+HDoN8VgCHGydkhf/BRE9/k4ALpeuiu+1gXfNGAURFD4" +
  b"eGDhys8rjDRcB6OsFDmIeHh0qMy/5URjRAyKOBS2CIYYqcGV+ix+BCpRtggUtmYGcCtnIP4Ud2l3nxKsFM8SDdkLbSOguw1iwtYOrBTPUZaMRgwmrlMAT0pL" +
  b"BQQUz9mlrGzeaIabnY2wWJYQFJqOadZ2mAVJOJBB/aLuEBTX8OH2to5FcVLzMzBKBTQ=",
])

///|
/// `5.9k`: the C decoder's first 16 frames, s16le.
let amrnb_5_9k_cref_head : Bytes = amrnb_cat([
  b"AAABAAEA//////////8AAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACT/3j/CgA0ABwA" +
  b"OQA4ABwA9v/r/wsADQAFAA0ABQD8//n/+P9zAJIA/f/V/+j/yP/I/+T/DQAYAPf/9f/7//P/+//a/9X/DAAQAAMADgALAFAAjQA9AAoACQDe/7z/uf/b//r/" +
  b"6v+xBLYGwAEbAPr/m/1y/Nb8+/4nAB7/j/8uAE7/2v4l/+3/TgD+/zAACgWBBnkEIgQCAcj9VvwZ+3j8Uv7E/rX/rv/u/hT+gv07/Xz0e+7W9nz5JPsSA40H" +
  b"KAtTB5MDVQU0Ao72efK6+hr+wfyDAewGzAe7Aor68fi9/DL9pQC+CLgM4wz1CP4FgASl/7X14fJ8+vz9UP4lAuQFbQbhAm8APwKPAs8CGQS8BRUWFh5uFZYT" +
  b"2Q18A1f7OfT29tD5Uvjs+l76wvh89ofzF/XC6IDhSO/n9AD6iwMuCYYOwQjLAm8BrvWx9bL9vP8oBU4HpAZ8Bgj/fva79qH6AP+d/LT74gNoBJ0A8QCdAm8C" +
  b"Nvin79HzRvoi/iwCFgimDBMLyQZCBfcEDgZ9BfUK8hD1DKEL4QmfA1sAEf6H/wwBIv+5AfcAG//nA9wEWwMeAl36IPhN+2L61/pk/r0CdQH4/QX+jf0r/Hj4" +
  b"SPcL/If+Zv9Q/hn6ePj092n2avpZAiwG7QXMAxkEbgLe/Vv7JvpH/kwDOQIuAyMEdAKbAEL+JgEVBpsJAgoqBoAJGgx4Bm0DQwCA/+r/4vca9FH36vll/Gz7" +
  b"xftG/ib+Ff059iTx/vKQ8gv2x/sFAa0ExwGiAVEAYvwWAAwDvgVcB0QBygLhABn2mfWv+Kz9WAX1BEgFUwcPBW//9ftPAkIGzQW8BzYJDgnNBM4BhAT3ByEK" +
  b"vAnhBwsJogaUAhUFvwnfDIYJRf7V88fxNPQm9tb2w/rE/8/8Xfhw9u33PPfQ9XP7kQA2AIwAOQEJAXX/L//0ALQCpwMXBFoCOgCDASP+gvmJ8+zvOPUB9RP0" +
  b"Afbq9W36V/v3+dH9OAA0BZgH5AbvCzIMkQxDEf4V4BltFtcRBhGwDX0MpQl+CCwRxxB5B5L7tPAW7tvslu5m8/P1UvZf88nxBfOs8Kb0jPpm+fH9EQCr/ssA" +
  b"0/+RBNkKTQ4NEqEMmwSTABb9Z/0S/zwAWwDf+XH2Mvbp8qzxH/Sh95f3Ifk0+1f5TPuC/s3/PgKVBT4HDwYPBsgHtQj3CuENXA7uDNgJcAi9Bt0DXwSrA8QC" +
  b"7QOyAg8Bf/uO9Tr3oveR+Jb9xADKADL+A/0+/df7BP3i/XP+AwFR/7f+9f+l/nn+AP/0/2D64vS39+b55fkX+g73++5T7az39Pme8fH1HwAkAZ4AaATmCIUI" +
  b"hAnoDh4OigyFDesPQhhRGj8XvBOCCwIHov+6+oz8z/4wCLUK5/6a70jocO5f8+Dsje109gf60PtXAIQD9wKgCF0Q/AyaCX8KHgeQAqkBywNrAfv9bwPPBVP/" +
  b"FvgU9Nn1H/feAo4TXhAfB1gE+f9e+ub3mPoX+hv3/PqqCMYNPQQH/4j9Aflp9wP6rPpg+H74P/I+6THtp/Z7+sb5VfZC7n/s8PpcAVT1P/X9ArAHEgXzBZ8J" +
  b"uAdmBjcMjwvOBmoT9SHXIsMcNhUUDWYBjfuL/g/1J+cq61L0tPYX9tv0/+xN5WXztQIc+BHx/P0ZG3MoYxYuC7fyWtuf7wMDHQPfDcQiOirYG+0RWRDgAQ/5" +
  b"vwAM/Q7r2eai8qz+lgjnCbP+2umU6a8BgP7A4Hfb0vQxD3oVpQ8TAT/jQeb4AwYD0AP+FN8WRRD9DsoPeAWJ/FEG/QZ3+0X1hPb4/t8GMA5CDc36ZukA8mAF" +
  b"1REtFCoJifyk+PH7TQCU/x8Gww3cA/DzLO7G8Rz4vPtF/Jv1XuqF7D/6Dv3w87Tzy/wkAOP/9wBzATIBBgxnGJwOaQPzDq4aGhilESwMGwVUBHMLPwyzAcH5" +
  b"vPnD+ejzne6C7yXnBOCz7Db16e0i6jzoJOYl61z1cACkFSIhzBHGAMTv9uif/kQRKxJLEAYU5xZZEGgMAA4wCfgF+AkWBtcBiwr7C2cBNQDRCfkI0voQ9TT6" +
  b"QP6GAKIEJQKb+9X7fgKvAmX5+vmaAE/5bfJ++UbzyuXp8V7+R/Yg8uXwoO3J8Jz4nwLDDUsSKgpkABH6e/sEBI4IyA0BFB4TOg58CV4GwAQCA3kEjQKbB9kP" +
  b"nAeg/QwBGgaJAmL9sefk1EvqbgQZBRX/y/tc/fL8yP+yBrQAffwZAiIQURp2BfPxxffuBLUMmggw/pzsSercAhUN9AKm/uIBFgT6Acvuvd0D6bL8agBe+6L1" +
  b"cel057P5uAKm+6f1r/FEBpIdnhLZClAXrBgXDyYFF/pT94n+XgtbFXkS6wx1CL0DdANCA1ECfALwAOcBLgAl+Cv1Hf2kBY0CUPy271PmsfRCAZoCpwLD//r/" +
  b"h/8a+733dvdB/l8FZg2gERAFOPuv/gADpAdACAwBxPkp+0wDo/0l9Db7vA10FnkMzv5z7+7q4vvgBiwDxv7C/S8BjP5I9Vv0Wvl7/XIDUQyLAGTqYe/AADoG" +
  b"fAXwAwQAYvrYACsIRvsr9c8BOA5lDFABagHEDQ4TUg+ABLP0tvHw/bEFlQMf/k/+OQCz/cX5jfbN+bj98gDd+pDjrN1C8pkAdQYfBnMC0P9B/vIGZgl0CosW" +
  b"DhTxDksOzAIcASH93vw4BV7/ywH6BBn83P4b/7/81fxm+lT+q/9j+arvQe3O/W8PvQ1cANn3mfojACABOAAB9jzp3O4QAhUI1fxB+skBgwUeAtHyp+zG920C" +
  b"BAn5CYgH2gTMAlYGlAphChkKqwu5DKAG7gP/BUgBPf//AwoFM/+e9X/wRfIC/OUGVANm/PX+7QUwAu70RvtnB1sErQK5Bp4G/geJEdMU6wV4BCoPJwcI+yz9" +
  b"qwb6CGEHEgzWBRbzM/O29zPwiO5++B8AfvgG9Zv/7P328qX1qfzq/Pr7MQFmAM35jQaaEBUCoPpDAYwFWwvwEKoNKQEX91n7c/85/28CcP6D+Sn78PhA8VLo" +
  b"zOs++W7/c/5++EfxyPCd9KX6CwMTAuT7FP4iBtsGIQK0BecGGQDmADkI0wpICIMGjARtAs0DVQQeBz0I3QM9AVUCiQTsAq4AqP+k/QQBVAcsC/8HRf99+nj4" +
  b"PfuTBLAHcwMJ/2b5gfuLAt7/ZfYy9i7/f/8o/N7/Zf8M/RUDDAbX/iz74/4w/wX+av7g/rIJMhGDB6L+qP3i+7v0lPOR+1r78fc4/W0AqP6+/c38O/vu+iv/" +
  b"DfLK457xbgLoCbAKRgPuAJYC9QdFGVkaagSp+7oFhwsKBu4FHhj5GDgHqgaDBj/8nfh2/FwHkAl0/6v9sfyy9wj7Mfzt9xTzuvMm+3z5Hu+Q71P25vlr/Qzy" +
  b"OORj7xX9jgHuBdUCVP5P/qsE0AmeAfD+DAsiDGgHhAeQBqcAw/0zCuoODwCt+0IBFv94/awAuf74+DD6PgHE/ib1eflmBLkGHgOn+PzyyfkM/wD/Rfue+Kn9" +
  b"tAJZBAYEigG2A8EI1ggNByUECgEtAkIFAQYrAy//of55ADAE/f/X/DYL3RK5CIz/dfgS8EvqHPBw+2v5yPTp+5YDFQNlAFACnP7N+zMBTvP639PpfwDJEdkW" +
  b"LxEADNsFCAv8HoEfdw89DdcP1AoMBxIENvtO9Fj4FAAJAZD7tfqB+sL5rv2a+lfvcunw7Cr2T/vK9tPzfPmDAHwCJ/xc95n7Zv53/kQF1wWw/ub/FwW7BwAL" +
  b"5g0/C98DVv5w+Zb15PszBy4KfAI++fr6DgNWBj0FwgJy/PT1v/lzA1j/FPTb+FMBfP9HANMDAQFkAEAISQpXA6ACOAQ8BK4FiQPOAiwAJPxP/oH9gfr8/bf/" +
  b"QQFYA7ACtP4z+MH3s/mZ+pL9gfx+/ZP/I/63AZACsf/N/p74x/G07RTyDf6z/lv8dv1H/cQC5gcDC5MNWQqEC2IRIg0+CdkK8wi9ENsa8BdfFDoQ+ge/BrAJ" +
  b"4gZwAiT99flN+630yu/98mvzmfNz82DtlOVK5ljxl/k+987vYe5S9oP+vP6Q/ev/c/8RAbQI7QPN+8kA9gQjBkwHawUJA0UCewUaBCMDTQcuA0j/+wKn+Djt" +
  b"L/4NEPoHsf3u/+L/6fz6A4AONgYd9zP8VwRz/9L7gP07/woCcgm9C+YC4/3SAzAJ4AWCAID+ov/y/lD/xv+0++/8NgbPDg0OdgQ5/aX5Cvmd+lb24O927Ynt" +
  b"h/Ja+eP6hfaI+Nn/bPdx6ynwDveS+lMBwAP1+xn8XQi+DFgMoBFSE8gRShFCEh0QPAxGE4kX7RVDESgEuwLmCPEGLAMGAMz+tPtC+QD7B/gK7mDq6vIH98rp" +
  b"U+Rt7rLy0fQW+t72bfMW+t4CjwTtANkC5wXMBYQIrQjvBn8GnwxMF74UJRSZFMMGAgXlC6EJlgM+/1kAoP05+ZD7vPnT9k30efTX+SLyiehX8NDzs/PH90H1" +
  b"HPN49uz8zgDv/Yb+NgK3AgwFNAeX+gf1Zf80AD7/XAcSDUMM6Q5UE5MMngjSDo0ObQgeB84HLgNuANkAAP91/6P70voc/sv1+fDD9Tr2s/Z299H1XvWX9nz8" +
  b"Xv5x+4H+TAt7EDAM8g1ADxwMewN9/l//6/pT/FD09uru9U/20e0a7eTz//h28i/vRPEs7gf1eQBK/k/7kQFACbEKHAo9Es8QmgyMFyMffhuWGAcZqhWtDWAQ" +
  b"WhJRCUIFwwWp/lz8Zv8V+Yby4+/r64bkzOQB6yrr5+gd7P/xUvfK+Zn8mQL0BgEH7ANiCIoJ6AeOC+QKBQ2+DdMLEg3XCBMMnBIyFEEU1gz8DCEOQAbZBiME" +
  b"vfz8+wf33PXR+jj4FfYL9vD2n/jb8ILpmujR6Cfqw+qQ6ejqSe4476bsterd8If2b/TH8tv4m/2gAOsEEgclCwwOnQ+sEsISYBQaFy4ZKx3fH8EiECLUIc4j" +
  b"Ox3rF4oX3BN3Du8KCQvQBvj8rPrF9+Dww+wn4PbYQNuq1ujV5NV014/at9ua5Ifqq+059l36tP12AVAGOw7BD7URwheHGWMa6xnoGPIdIx7EHL0d/xlfGTYV" +
  b"Wg6TDOwHEgOq/3v/KwB8+fb2zPn+9m30vPKw6s7m+edA5x3nSOYj6Jvp1ejz7XjyvfKz9Nv2ovhn+z7+8QFHA4wFswkkCcEI+gtQDnsNAg4PEAEOYwxxDKMJ" +
  b"aQgwB7EEjwQ6BN4CzgBdAIIBWv5v+VT1OvJX8tTzNvPG8jL10flB/cX+JP8ZAZoBOQB0AqsG3wR2AuACVP41+XP5t/xQ/aL7IP2+/n/8XfwVAOgBJgAu/Yv4" +
  b"P/YG+db9uP5Z/zUFgQfqBe4FYgmQD9YP7w8fFvYUiw5fDE4MFwwICu4JGQwUDg8RjhEGE4kSbwg/Bi0FkPpI+ID6LPtz/Xr+WP9K/Hnyo/L09iLzIPJT9XL1" +
  b"ofEc797xjfS182P12PdV9832IPnn/O376PVJ9iv2l/IG9W350/n0+ef+sgK7AFoB1ABY/xgBqAGIAxkEbALnAgD+D/nk+4/9Hf1n/TP7RfhT9sP1W/b89ID1" +
  b"nvQj8gvzUvRU+XwCMAeeCboLdg3vEDsTbxWSG0odxxuJG8wY/xdsGQIa3hp8GvkcBh2rGFIWHBCjCkMGYP0A+6n4vfOv9+f55vWx8c7rXOc25OTj3+ee6Lbo" +
  b"d+rb6Rfqm+ke6eLrHe2m787zoPOT9AP56vwe/QD9aQD8AHH/wgEOBEsGfwlYC/MMWg2PDa8OFg/2D9gQ3hAfEIwO2gxRCz4MvgxFC5wLsAwvDC4N0wvGCJMH" +
  b"FwWlARD+X/vS+Zj2oPQM9qD16vNF80vxle4G7gnv/O6/77Py2vPH9Nv1HfQE8+fyIfQP+Kr5+fr4/U0BggObATwB2AHj/7sAEQO6BP8H5AkSCzkLPQuTDScO" +
  b"qw6REJEQDBAkEcsQIw8qEcUS2g9UD5cS2BEUDqMMvwmqBJb/QfpG96/zM/Bm8/nzZfB8797sZOqB6T/pKOqG6pzstu9K7v3wTvRk8230evfH+Ur7s/x2/oEA" +
  b"/gTEBSYD9gZiCF8EgAY7CPwGjwg+CXgJywfUAjIB5AC8AIUCx//P+7r6+fmh+cj6G/5Y+s/2OvqX+Gz1dvdH+in9B/5PANgDGgCC/+cDcQUSB/YIBw0dEagP" +
  b"iBDUEigU3xWpFCMWMhbnEi8X4RTiD3IVGBS7DvIMQgzQCiYDMgFYAeb6EfZ88f7uHu2W57rrx/Bz7Ijr/+w17q3uie288B7zRfPT9dz5lP2K/Lf8RABB/5n/" +
  b"vQFgANb/dQFIA9cAjP2YAPT/a/s1/HH9XPxe/D/8kfxN/RL9xfxg/lj/k//Z/8/+ff+uAJkArQEoApUBh/8b/f38zvwK/on+yfuz/QL+QvwC/lb9TAH1BpQH" +
  b"9ghrCQEJzgpGC/4KsQpwDBkOJQqIC6kOKAoTCR4KDAlHB3UFWAVNAwoDnQM3AAACngPn/0AAX//f/70BoP68/R/9bPqL+F72//UA9Sb2T/th+lz46vm7+UD5" +
  b"TPie+Nr5D/mw+Sv46/bu9sXyFfC98AjxfPCU8DTzjPSx9aT8lf8iACIE2QVEB1cKrQvcDBQPLRFzEJ8SdRUSEn8RexJ4D1kOagyDCRUISwbEBIwA0fs0+fP1" +
  b"WvK+8P/uU+6/7jXscelS6Cvq4e0s71PxVvWo+fj9C/7X/F3/ygHHAjIFLAnrCKoINA1uDcQKwA29D68N+QzrEDQQbgwVDvYMCgrtCFoHywY=",
])

///|
/// `5.9k`: the C decoder's last 16 frames, s16le.
let amrnb_5_9k_cref_tail : Bytes = amrnb_cat([
  b"CgGxACgBXwDj/6z//v6a/6H/ZP+dAOIBZwFuAF0AgABMAKz/Sf7v/iUBHAAK/4H/hQGqAfr/DACwANgBKQH9/of+wf9nAGr+P/3X/X7+0f0f/CT8GP1k/Zz8" +
  b"Yfxr/aT95Pxj/LL9qv4Y/eD8k/2T/B/+Sf5O/vcBSQK4AZcCjwMlBHIDrQNuA3oDCwSIAh8CYAIuArkB+wBVAeMAkQCeAN3/JwB0AIAA4f/E/2kAWf+k/4IA" +
  b"ef/H/1T/L/7y/TX+p/36+3n8D/6A/bL7KPyg/Bv8SP1G/Rr/vgKWAZgA0AEUA+cDggMjA6UD+QQdBRIDXgJsA5QDXQJ+AdoASwGlAtkCywLrAcn/Df6G/tv+" +
  b"3P2g/Ff8tf2B/dH7MPsx/R7+Lv2s/A7+DP/K/gz/gv/+ALkC1QFOARwCLQMhAw4CvQKPAmoCUANjBJkG8QW5BAgEcwOOBDkCkP8sAHMA8f8pAIMBkAG//wAA" +
  b"kgD2/sL8tPs9/Mr88Pp2+dP5jPs5+s/4QfpG+qr7JPxG+q78W/73/d/9iv0TANEBuwD0/7kBDwPeApsCrgGoAooD9wKvA6kD2ARtBuMG1wYzBeAE6AS+A1QC" +
  b"bQD8AaYClP+0/tP9BPzx+Mv2QvdO99f2SfaH9rb4+/m3+bH6JPxY/s3/FgBTASAEdAbpBuoGIQdICKcIeQfOB84HdQekCB8I2gb/BmkGTAWCA/cATACYAPv+" +
  b"Vvx++5H7R/hh9aH0D/Q99Mnzj/MI9OLzf/St9R/3J/j5+Rv8kP7BANYBQgSTBnoGagUiBhQHoQf/BucFLgepCOIHYwcUCGUImggoCF4HAgZNBdsEpQOwAu8A" +
  b"7P9r//X85Ppn+JT2WfXL8rzxK/Iq8xr0mPSK9vz4iPve/er/mgKvBI0GlwgDCXYKNAwPDP0LewzMDGYNBg4hDeIKLAkECAwGggM3AOv9XP1q+rr27PQt9Gnz" +
  b"ZvGm8LrxEO/17Onum/Ax8o/zhPXm+Qr9q//AAQoEAgmSCX4IyQoRDKQM6As/C1MM3AvoCo4Kcwl8CPYHFQezBMwCgQHr/27/Av8P/tL9EP1Z/FP71voo+u/0" +
  b"CfF18uXyhPLQ8SHzDPcc+Vj6avsf/kIA9P7b/jkBSQO4BF0EvAVICXsKEApGC/oMnA3AEIMSZhA2DyMOhgzpCjUKJwlZBoQDxQB8/lb77fYn9fvzYu826zfr" +
  b"7ew67sDuwfDM8+z1PPg0+i38dv3L/Yj/LQGAApADhQSnBeEGrwcJB50HyQjHB3QJ7wpWCQAIIwaSAycBvf2y+/z6pflR+Fj2qPNM7pLrDe5s77TvYvBR9CD7" +
  b"BP1//Q4COQf3CN8FnAQQBgUHkAcsB1YH6AlbC9wKzgrxCscL4w5sD1YMpgwxDBkKTwm/BvoFGgfJBWYDAQGS/4b79vWR9PfzmPLb74Pt6e8Y8p73nvyt/BQA" +
  b"8gPLBdAGqAUOBikGSAV4BAoDfAL7Aa4AxP/T/vf9Ev6F/b78b/4uAF4A9v/3/9IAzgCu/7b+vf5b+2T1FPCE7vnvV/Ls8/P0vPg//Yv/rAA/AvgDmgQNBQkG" +
  b"FgcOCFYIgwhoCY0JtwgECcoI9gfsCf0KwAgwB/cFOwRCBSEEWf6m+2j8wP4//gn6G/po/Kr3mO8I7env1/EJ8Ijv4fOL+Vf8YPyD/m0D8gV9BCn/Kf4CA54D" +
  b"SgGzADEEsAjLB90GLghICqQOlg7tC1YMeg3hDCoJsQUNBIQDcgOEAer+vv0b+4/3JPQA8lzyGPSO9cj1avds++n9EP4z/5gAIAJPA9oCdAOoBBYF4wTcA8EE" +
  b"kgZdB/QGVgWaBS0GiwRfAKgAnwVvBYkBDf8KAt8HSwWR/0j+bfvq8oLqDefP587p7OrF7A/vQvOH+N/6Qv31//kBOwBi+8f8JwCSAeYCkwQHCbsMIw4DDx0O" +
  b"ehEhFTQSYg8PDisNjA9sDtIItAXJB6IIvQMa/fH2ffJ87kfuXvCj8v72evod/Xb/PQCwAF4ACv8R/s39Kf5f/oD+z/6e/14AYgDQA6gH7QbHBZEFKwMyAjkE" +
  b"cwQ9A9QBgQIwBpoGYwKo/zX82fPo6jTmeuWE59vqbO8h9oT8xAH6BNcGdgcHBzADtvuZ+Pf58fqK/IEBrwh2DQMQSRGaDwQNGwvOBqYCYQQ8CP8IGQfzBZoJ" +
  b"jgxxCOwCQ/81+Ebub+dP5TTn+e/E+Kn/PAYpCqUMMwyKCEgE+/4X9wbxtfU1/KH9sAJCC60QhREtD7YLPAiXBcQA//tX/qIDGAXFAiMB7/2D+oL24PLo8Qjt" +
  b"9+XS3R/aw98E7ZL6cQRyDR8V9BmgGaUUBA9iCQQA2Pfa/OcEBgYRCY0P9hPGEn0NhAjQBLIBmvyz+e/89AHLBzcM5QmHAuP8VPiR9ervqegd4g7bW9nX31js" +
  b"ivh+AVIJdg9vDZAGMwOHARv/xPji94UE+AxdDhkRLRZcGZoVlQ6rCh0J9ARsAM8A8QTgDMERuQ2GBez+7fqt9nXveOji4oLcsNn/3nHrVvZK/KcC3wjDBbb9" +
  b"fvpO/LP9wfaO9SIDBg4QEMAQWBY5HOUYNxFiDV8NjQtaBJQF6wywEBMT6BDPCy0FbPwp9rDx2+wv6Bzi/N3p31PnGvHY+On+6AXGCHQDWP6Q/XP+Ufy98njy" +
  b"pP2VA/oEZwcJDrcTFhFWDN0K0ArqCF4EXwNhBuwKpg1zCbMDswAh/rD68PQi8Entfenl577rLfRlAH8JLQ3VD4cMgwZ2AoH9WPp59ILy7/q6BfoMhw/KEUUU" +
  b"hhGVC6UE/AD8/ob7IwBEB7cLPA85C+wEBQBy+Uv0aO7R6BjmOeIZ4vLnUvBv/lwJhw2fENgMEwfQArX8BvjP8bzvVPh7BGQH/wReCLkMrguJBdr/lACgAbT/" +
  b"qAEnChESnxSeEvkMYwc+AW35kfJy7Vvqmeek5ODmXe1E8+z6EAL3BmMJPAYnA8kCqwCM/M73n/hgAr8JjAUSA0IIFQtNCBwC1gLdCWsJ+gVZDGwWAhvfGPAV" +
  b"0hM/DakCb/hp8Lbp9OES2tfYSeBw5qLsS/eh+yv9uvzT+eH74/zO+mb5IPqIBL8RWBBHCzUPfxJYEO4HpwXuDnEQjgqADEMUjBhmFMAOLA5hCscEBv+X9w3z" +
  b"kO3y5QHisuZe7mPx8/YB+z764Pks9r30hfbN9ZX1IfZ1++cGvAo5B60I+AvoC4UHNAPVB3ELsgf/BlIM5xGLETwOmwnaAg4AJf9J+j31dewk5X/iguW57k3z" +
  b"g/rlAzkEGgPe/3P8Tv3J+vf3pPcD+t8DlQoFCH4IOAw3DT8KGgVdB3YM5AlhB2cLqxH4ElUQvQvCAnj9O/3A+Zz1Ju1e42HgDOIn6zjybfisBLgIVAc0BZwA" +
  b"PwAz/nv59PdD+Hf/nwhUCywNmhD8EdsMaAS9Ag0GYASYANwD0gxmEcYQPQ/6B/n/Lfw490v06O3U4fzcFt+S6YL0E/l6BXkNpwlPBrsAwf7B/h35Y/eV+Kj9" +
  b"PgiADeAPjBOtFCUPggccBlgJFgivAk0Ebw1UEWIOvw3LDZMIYv/W+I72GfXX7VTkCuKO5RHtQ/Nj924BDwaPASb/Gv2S/BL8wvX08/P2a/odAd4F3QgvDYgN" +
  b"MQmRBoUHYwmtB74D2AVOC3ELbQg7CSIKwgV8//v8efy5+kTz0OVS4JTkXOxJ82H40wPtCWUDpQAzAHP/sf6x9nf4gADmAE4GhQwwDn4Q2ww3B7YGlAaKBxMH" +
  b"1AMPBzkMIgtZCeoJpAohB4P/rv0d/gb6MPeA76jiK+BW5tLvX/YY+zkGlQdS/57+Wf7t/uj4TfAE+w0CMfwsAp4K6QwNDDMG8wZ/Ch8H6wenCccHlwoWDP0K" +
  b"9ArkCJ4H/gRr/2z+EQAGALb85fLz6jDroO7I8lv23vxiBnEFcgC4ANcAuP4o9h3zxvwg/fv4b/+aBdMGpgQ/ApkF/QaUBF8Gawe6BlYIqggwCVIJIgcoB1gF" +
  b"8AAl/9D/5v3I+Kvy1+p95/vqs/Bh9u76FAQfCuwFGf/O+6f9Gfn38Aj4CgAR/mv/RwXoCc8JJQW6BccJxwjoB60IAwluCrEKuQpmC8cLwwt6CTsGaQUCBMkB" +
  b"Uv0C+GnzTutt5jPq2e+Y80r3N/9iBaECefsg+SL8x/jN8sz4YACR/+//ZgSxCFMIdgTqBDUIyQe7BkwHzQe5BnoErAUIBxQFkAU+BwoGtQMrAQ8AhP8V/Kz5" +
  b"o/fy8b/unPAd9Cb3pfno/o8DlAJf/+L9lP+u/gX7r/2UAhACiwHZAxEGlwUwA0kD7QTWBYsGZAcuB8IFfwQlBdUFXQReBFsGDAbTAzIFgQVRArEA3v2W+oLy" +
  b"oOcK6WbtZ+3V8BX3gP7jAF3+2f7UALMA//00/gwDsAMHAp4E8AY+BnIFugWtBTkEcgRCBkgG9wQzBP4DEQQFBJsDeQOdBBAF+gLnBAEHfwOmAj8BT/5W+JPt" +
  b"L+3E8A3vR+5/8fH40vtz+vD8a/8T/gD8B/0vAfgB8QA6BPQG4QYdB1IIgwjpBnQGhAeVB+0JBgooB3MHgQchBpMEKQNSBIsDggAdAwQEYQCRADT/8Py19zvv" +
  b"T/CL8n3wMO+k9Jz8DPw8/AwAQQBn/iT+MgA2AfL/UgG3AzED7wO+BNEEbQTRA8YEswROB04JNQYvBr0HEwbgCLgIdwXWB2AFKgOMAB37av3F+dD1PfZp7i3u" +
  b"2vED8ZPwMfSG/fv+KP2wAW0Cj/8P/pn+WwB7//z+WgFSAu4CpwN9CgIN0QdVC1oNWwruDb4MUgi9CGQHKwVQAlkAUAGu/jL83v5X/p/10PTH91bz1O2h6lvs" +
  b"Fe/R6m/pIfCB9774ivqX/zICpwIhA0oF3wcaCGYIKgoIC9wKzQrRCjoOPA5MC4gMDg6UDgAM3QiTCT4HYwjfCrMFAwaKBuYChP8v+Q35KviF8NjyAvZg8vHz" +
  b"q/Ur9YP4AfqL+p786P6V/6z+Vf3W+qz76Pzi+yf9EP2C+yL9Wf18+9v6rfYu87j0ffWQ8zT0Qvlb/Gz9GQC6AeIEUQeXB6MJ6AkcCXUKVAtJCvkJqAplCpMJ" +
  b"EQnSCMMLqgzdCY0KXgz8DBEL3Aj7CHwHSwgCCiwGjAWiCcgIQQOA/5z/I/2I++r7Bfp5+Qr5wfb69Vn1X/W09CzzCvRw8y/yLvOh89Tz1/Gw7/nvie/M8Nvy" +
  b"svJW9Yv4evpP/UwAUAQjBSkDWASiBzkHIgd3CGoIVgpoDCQKjwnqDc4NSQgXCLQKzgaiA0gHzgfBA5YD4gP8AJP/Rv6Z/B378vle+J7xSe7r8Y3vBO0u8Ifx" +
  b"6fJM9TD4qPmd+hD/+vxq+zAD0AO0Ah8Hewk0DIsO8g6oEWgUpBQdE2IR7RGzEJ0NigxjCjwHwATDAav+GPwi8gDsgu2S4gDbdOCh3pvcmuAl5ALptOxp83H8" +
  b"0/kA/K0BTQEoCOILjwzqEuEVRho3HqMd5yF9JREkyCLsIOEfah35GKgZ0BfjENgNVgq7BP7/MQBz/633uvRc9BPrm+UQ587jlOCm4L3h/uI948Hm3ef95/rt" +
  b"Ru0h7ab1Avi1+R//fAhaESMR2BQuHNkZFRgGGqsZlhmgFycWbRXrEH4MqgmaBqcBsPuu+Bb3zfBu6QXoHufw3xnebeGq3//fceRc5izq9+428wf5v/pO/d8C" +
  b"zQRgCNsM5w5/EQwUIhVHFgMZbBkOF/oWixaOE/8R6BFcDyMMRArsBloD4ACcAXwBw/vM+sL73PR58cXymvFK9JX5l/yu/bv99AB3AmkA8gBb/8/+qf8d/A38" +
  b"Y/0H/Kf7IP3HAQsBXP/kAnkC3AD1AbkAdwCr/vn9svwM9dL0ivQs7P3lFORA5JjiK+EJ5srn9eh48EXzGPN/+Kz7zvjj+g8CGASVBdsLBxC2ESkWeBtsHUke" +
  b"0CAbIhchRCHcIqEk6SLKH8QeiBqLFVcZ1RfVDsENbAqz/2b6mfcy8WTyWfnY9mLzsfZf9pXxGPGY8vftOOsT7p7sQeqC7HHuwe+N8eHzQ/aZ9wf6kPv7+gL8" +
  b"5PwF/Tz+BPz++hX99vqd9s/09fWC9XzzWfXW9y/3MPpD/5v/kAB7BHIChQDCBBcFGAPRBRYIwAa/B+oKLAu9Ck8MiQzbCwkMQAv4C1AM9ApWC60JGghOCGEI" +
  b"2ggtBfgBGAGz/Hv7af0t+2H8DgG0AIoA7QJHBIcCogFqA88AgP0O/xL+9fk9+lX7IPnH+D/8+Pzw+nL9mf8O/m7+1fz6+ov7LvrN+Hz2SPVK8GvrBOto5mXl" +
  b"cOgc6CjrXPCW9ID6uQIqCCoEswcJDWcGcgdCC6AHiwdkCVUK3AmYCk8OVA36DKYRExMcDWUL8Q9OCzAGTwx0DJUFWwOTBJwBVPzeAegD0f+hCPUM4wgVDZYQ" +
  b"tA3GCgQL1g2bCOoDMga4Acf8B/3a+iD4Q/hJ+S73APZX92X3/fUv9E31nvT48D3vAfDK7aDoGemF6YDmYulz7OXs1fFm9x76bP7+Bk4HQAQhC1kK/wRXCOgH" +
  b"TwRCBH4GRgfIBvUJMQv+CVkMpg7tDa4Oaw3CCi4LgQhoBL0F+wL0+3L5Q/jA84vxLvMK843zSPkY+4v7CAPZBG0Esgi6CuULAAy+DJ0NewpUC0wNBwvJCm8L" +
  b"MwguB1sGwAGm/wD+KvyU+b33KfdM8krwBfEs65joieoP50Lm1ekT6xXtHvES9qL5r/0yAVEBBgO0BIICWgP6BJsDnATkBW4HtgpZCzoNSRCCD/cPyhGeEPIO" +
  b"dQ8UDpYJCgitBg0CpQCzABn+3PxH/WP93vw9/X/+W/6+/aX+Kv8J/v79s/47/gb9cP4b/6P9Qv7C/3L+k/3Q/n/+gvyS/XD+RvyD/Iv9nfs=",
])

///|
/// `5.9k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_5_9k_fate : Bytes = amrnb_cat([
  b"AAAAAAAA9v/I/1AAm/2BBnz0wfyl/xUWF/UoBW8C8hAeAof+Jvp4BiTxygK8B4YJkQCJ8zIMtPCr/nH2DwayAnP+++6FDUjoHgcfBwP6P/UUDRHxWRDA4MoP" +
  b"1RFF/JwOne7GANcBfgLJ8F4GbgTuBLL8rBjwAPr/xPnC/QQAtvFC8iH9Qe1B+hkKVAN4BB8AoPpA8dsG3QOTBBUDlPPoCTgHuvNP/kIByfktAkvqfwBO9NPz" +
  b"5g1y/KACtP607dkKyu+Q/SMDNgaCAFb2wANDEcrprQg5+ez86g4c/jAM//iMF4by7AP8DILpm/3UIfbYOw6TDB3nswk6BMX+IP3qBQ8Ro/Ln/BgBW/aSG0MG" +
  b"d+r8AIwOX/vH9LsAIw9m8230jwhY+vYIGBRz7Jn/kfwb/QEJWAWL+Cr42QWDCSvqNA2iB/D1swGi/5H72QItCgj4fAGb/XgC1/uSC/D2fPx6+vgPGu2TAa0G" +
  b"Hfzz968CS/zD/5cUs/We/T/6AgVB+NcQSvh//3375w6P7lABJgogBZ/2qAQ9+Zb6VQ8fAXX8ZP20A732Zxeo+S/4nvkWCdjzI/72C1oEbv11/NL+4v12Dv8B" +
  b"hv13/hz9FPwKDmr+B/ov+t8J9Po3/JL5rgYs/qH++/05BAv94v9cARgBfv0M+XUHFv6J/hn80wQy/lwAnPb2CVf+WgBQ/Y0CvvsdAVsClwVuA/H3BQKD/Zz4" +
  b"Dv7NAo8ATg1m9w7/xffZAjkBb/5F+mYHz/oc/uL40gILA9r+6/xNAXn/2fv/Aa/7SwWMAAv9UgFkAO0F9fwL/UMK0gFC/dP/Yf+OBYAAO/1FAwUA3frUAin9" +
  b"BQYd++P+zQX3AVn6Rv/r/lQFLvsB/IQBvgJh+ED9R/xHAiP+vvwJ/3P/zPwQBUT/Ov+c+1/9cwHe/uoABQIT+5MDuv6k/eEAWfu9AiIDrvuw9asEsgf/8Mv6" +
  b"HwT+C0cK5+m2/RYGxwF08+4IlgVW8joHMAHl/U3+mesgClcIIPZa+coHAghY/Yr6XPyECBv4BgkUCaj1Yf4X/jUMAv7Q8SsQM/o1BfD6TP3EDPny3AY/CdD2" +
  b"UP+YAAgApQBN+pcLegQ+9hL4bQMPBPn0YQTHBSMEvPzJ+8EIDwM8938NBQVo+or6agCBAu73o/zgC1IFp/aU/JsDqgfJ8fsGuQFgALEAmPuWBbkBBfbcBwgH" +
  b"OPqz/Qj78AqI9rn8pwo5/nH9lPqXA04EdPSzCEUKuvn6/X37+QdIAPbzWwtoBl/6YPyxAggEQPrh/wAGoQMB/ZD70QEhAYn+ogQvAAoC1v4eALgCIP9r/3P/" +
  b"mgCo/wgE8/2k/d4AwgBHAXX96P4XAPP9AgAmA6EK6Pm1+ekB7gWYBSf6xvOl+8oAfwK0BUz95ADy+6QBVwbW+G8ApAXDAOAG7faG+FEGWPtYAOcBCvvBBd37" +
  b"Uv/XAqr9dgFgBEv2WQFQ/MIBWAJ8/NUFYP3qBK/1GfzEAa8D4wTn+UT+nwUo9csCLAW0+owCbgcJ/0z1bP8TCLn89vh8BJwAqPcUAEIBhPro/xYGYvjnBf4B" +
  b"J/W4Cb4A6PfcEBT+SfVA/T8DnAVs9rAZEALK6fb5Iw8CDWENE/R3AAcKd/ycDSrsuAcx/Tb1fQwEAa/ipQNfCcP5ovU+CawUGflI82cYhgX98nUl/QP0uAoH" +
  b"0Bw39nH7YO0z9YEZS+dVB0HliQ4y+bYTIvcAClYpZvm6+VDp6Ag6EyAJ3QEgD0wJZPdVBA71uuxL7sbaWOl08kIId/t8GdIJ5vpzDkX4+waL+KwKk/YeC20A" +
  b"a/b0B7T1eBS285P4OvpdDFkCbPOc/+j/zgWWBV3/CfNt/nwJCwDx+t/6bQHbAaMGUQA39if47Qql/xT1A/sTBOb+OwiaA1D4SP2TC/8B0vq2+uQCtgTVAnwA" +
  b"uv7lAeEDYwBW/g//w/viAm0B4QAz/SsAtgIT/lH+mf7EASn/4QDTAD/+YACGADT/bf8g/7UC2wHZ9VIAvgxP+dD+QvS3COgEwv/S8oEOhwTv7HsFn/txCLID" +
  b"u+9+DnAMYg0k4LIL3N/iFszTu/x6Aw4o8Bsd7FQQ6fNaDxnN8AhQ5LMsBvcV9LoRofwGFrjM0htF3ZUdCOCZFngBewfSDtLoryO97cQGVdojGS/vuxEHAVAA" +
  b"SBCm9EcJjOVxFtvhQBmw5aUYR/C7EFP7gAWdBsX5sQyN5i4YHuf9F0LvQhCZ6V0bUfFZB5D0mv9eFFTh+ChX+BH4JewpHGEG1grtxTMg4wGBBWL4BQKE4use" +
  b"P+d/G+Xf2guv6ZcgI+Wy/aPxWifE9FX5EuVEDaYHNvfyDbsMu/hY+UIRgAIw/YftPx8F8/wF++d+E0LvRAlq7ZES0OezBvT0gxbU7qUA0f72DsLshAZW9ogJ" +
  b"sOrzBF4K0wOw66UC+f2qDansKwhp+l8JsAPP8x4DlgSC/cISBwE/8uv/ZwGgErHy4/u//B8SDf29B+fo6wpc8xQfMvZV+A37JQboD/Xw3PjvCMcGvAW083j5" +
  b"VwB9A8oGmwTf9o337glICKH1OP6LATAIWAY49EwA1/3WBHUDq/QIBsT+ywAXD07u8QdQ957/9w8xARbxBwhP7lwUNP91844HUvxn+fIOtfkn+EQJR/5DB3r1" +
  b"xe7aDtT+JgH3AXnxUQvUAPH0AxXd8HUEeAdQ+ucFufNKA/8RoupTDQsANen1G2TxgwlcAoDjqheE/FsAzAgC38gbY/2p/ecKROc5Ce4AVfwgE/7jowrSBPf6" +
  b"6gAs6gkNcwU98RAHlPP9+lkO0u89B9331vQaE8MFF/n4/eb46gwKCcjwwwTR/EgFeAwFAm30FvyhA9YDC/3S97P75ApE/KwBa/oN+eQFRQYh/yQHAPCqExwI" +
  b"E/Ne9fkPsA7a9Un/B/sGDW/jThpo31cXmgST+r32UQuw8QgUPhgP3nr69gRUGt7tZ/maAT/+aAAB/1jg3RIvEJkDg/c47hkEKgNHDdb7XOm0CZYW8OjNCKoF" +
  b"rPd6B1b6S/OKBLwIXgWB9BH78gGrAF0MOgOd9FIAhv8MBmz1JwwACZzxywsQ7nX8OBXm/Pr6NwGk+n0CYv5wDF7y8/X4EXL0pQURDFXyMwpN8oz+FQAbBKcO" +
  b"EO+hCjn9MPStEsHzcwNa9s8FUPreBuUF+fw4/9AFfvKBBqoNn/f7+rP/L/1G/NsJsQPR+ID4hgJ49MoUjgb56oIGpgJe/E0KzvfZBTb5qADFAlH41/6RCFj5" +
  b"HwTF9h7/twad/7r9ZP5FAkMCtwBy/hkIzwGNACT+6/0jAMAFWgVe/G4Atv9cBHX7BAE6BUbu6gtE+DsEgvsL+tAJsAYR8XEDpAAsDQEFL/buABEG/wIIA3D5" +
  b"yQC1BsT1bATJ+XIDdgL9+rL1vQFS/38CdPWfAuH9Awp7BSQNufx7ABYBEAEu/zD7v/thAPcHsQDl/Ub/N/7T/Y0AzgGsAlL4Ie2jAHr9ev779iL4VwANEF4F" +
  b"5/OfCTUArwHMDOECm/5GAtz+S/+BBWcCqAE3/+n5g/8hBZD31AkT95r8r/x3/sIEbPzP/GUTyAEN/b/8/QC8EnXpNQQcDQgVGfYc9Ln0uxBP/IQAYwNx81kD" +
  b"sARhEIj25O7WFZsNdPGI9BLzlyE4/8vyQAhT+XgJc/Ep+n8Jh/qzEvT5TeseA7T+ERKu+qnyggp5ATz3k/uQ/nYJaPqG/ZoE0PiX/1T/hwJlBFzx5xAc/4j6" +
  b"c/niAaQJhPHD+RQLLAHUAHH5UwP5BTP6cQSWAYf3xAMk/ML/xwIQ9lsUOvvy+RUANvvPEArzKADCBXz72/1KAav9OAn4+eoJXQFD+jMBAQIQAHL+k/txBR4F" +
  b"lvvj/dgHXgAwAc78KAdUBBsEK/plBScJegPo+MH/hvr9Cfj/J/qv+p//owW2BYL51/XN/+oFoAEe++UAZweGCJsGqPmXAxIOqg62/8DtgAamCOv4kQI0+awF" +
  b"l/0y/n7+tf+yCyf1PwUT+A8JSwHO92cBAABFCFIFOPiIAqEA1/ut/3T6GvVXGr31RgBbBDEDUxGQ/HgKSPun/db9wOpp/ZX9FBUWBpIDCQbf/Pb8PRoUBKjx" +
  b"lQNvAyv6JfbT+UMG2f/I/YT8tf60FY37cxNP96EELfyrEqr/7wbW+hQNAPsU67r7/vaT+3/+2APE8WD+ZACIBiz+LwW/AJkR3PXiDA4AHgaqBqXyfP0k7v0C" +
  b"B/kU/YsAGQ16654A8QIvDn/13xtfBocXa/0r/vP2EgecAuny9vUC7GsK/Pjq+dP3PQplCOsD7AAF+if3uwnOB80Mv/WvB04BhwAhBXj04e/iBaf6/QBK9M37" +
  b"gwKr/v0I7wOH+lX/lwPkBawD/vzpAvz5JQWB///wzv3YDIMBdvVX/aAN2gN0+WwHfPST+pAExw0f8Wn2hgTBCHP3/RHM7534bAeB/yj7pfaY/MPzU/23+3D5" +
  b"8+4/DRoLOAUyBuf72gQ+BNH+LAH27S0GZQTA/kr9AP50/PMDCAbw/6r3lveYByj/lvyRBdD7BgOSB33/Nv7R/DIKFP5vCvP7nvoe8xkEiwHR/DX1G/pF/woH" +
  b"wP3S/nL9agSYCk/5iQTC9Ij+lwa1Bsbojwop9QkIKvLHAwMKr++N+Q8C2fjpAvH5VAIs/4EBiAAL/sUKsfq7BZ3+hQ0q99z/pvfwAKAA7QJn//MAdgM1/AIG" +
  b"9Qa0BC/6agDHEYP2p/gYCGLz9wRS/Qr/HfpbBzb66QQa+PwBTwN/+usDgwd19eP8yQeu+079ZgUC/6D8Kgtc+BYBlvqrBa34Uf0i/EUCWfslBjL/L/rxB9P9" +
  b"bP4+ASv9/PuH+NADkgIkDb/vq/Tm/9YDRBG37/Tn+wrHElT4//Ae9HkMtxkRE7nqJfAl9HEHRxO9/IfhgxRUEg4I5+0g+W8ZMfSlAdvpFghoDPkGCdzgDZgH" +
  b"vv/d+VL06P1WCGoZL9u1+T3t4P/ODtMYz+ZcBqQKwA8XB0L4iACx+gIUy/HE/VQDTg1p9E/4Svh0ESsELAr+9Pf+hgJeCccCt/XABSwO+vbuAWr+DwsOAsL2" +
  b"v/QPBTMGiQcRCOoBffdWAL8HROXj8F/sYxL1ChcDPv4x+zHw6AxZ/8kO8/Ob/Zn8igM1CND3sf1Y88kAy/p/CFsS+gtyAjXsKvgHGb0RoQEX9IgBtgmOCdEC" +
  b"6vmk+TUPOwm+/jr4IP4aCHQXTwjj7nP/wxQaD97+sfH2BVL5/Au1Awr0sv4+/MoOKQZ884z2/fzVDH0LTfnW+OH59AseCewH6fIx7IkMpAU6DMb5k+tlBcj8" +
  b"gg9eBQPt1vk77ScQqAUP+Nv/wPZGCVwR/P2iARHufwLwCkYLhQJa6a/7a/8QCQcMmvq1ARj5Mw1cDhL87f2Z6jIKwP87CZsE0veC/eHsrA/QCPcAxQEJ7UgE" +
  b"8PjTDBgIve4rA0zyfQrbBCwGHP5W9ScCrAGUC23/sfFoA5X/0wMVABP3xAkZ/E8BcPz+954C6gCe/B4R2cyiBq4ZSfYHH5Xu5gXD7174kh1KAkkP3vpE29IB" +
  b"ZRtYDm3zIAEz540UrAsH62kAgN7RB54HPAjbF/zayQIQC+oEfA6F70ADWvgUCqwL9fbLBJ73JAE+AHUB4wXc9owGr/3//XoPwwF79mv84wy4/W0DiQOz7pwH" +
  b"wQIdAUD74PdMCAEEngLVAgv5IwVwC5n1DvssAlr9TAplAw/2/PyvCAIGXPmX8aULN/4mCHf5lfVHCHsNJfTi/OH2uAJNCeD+LQR58DIHLw0e91D5UfztB9QF" +
  b"qP2l8wH/EQqfBvD6yvG0A8EAuQsCAuLwXQEgC8sDBwAL848FugHO/tsALwGjBGz6awWw/pwAQvy8/+D/1AKV/ZkGx/yaA2n8dgF7+p4Dk/2fAgQDhPrx/KkN" +
  b"u/DXDdH0L/oTD2DtAg2s89cH8/3YADT/FfzgAJwBsPwsBcT0sAsM9+4CBgBX/mwKsfddCe35NQLg/hD96AXA/48F3PdtBcIJ2PZnD3bx7QTyAnf33ggL9/kF" +
  b"EAGk/c39ifXuCC384gAC/HT4JQ8D/KkH6veW/9QEZf9zBGz3hAL/BMb6ngMj+S4HhP5Z/sL8e/wECSf8F/+M+EQBOQL/AHf/TgX5/X8Pd/rV/XgMmQMRAEQK" +
  b"T/nd8t0HafXqC6f0sgDEAKkMufwCEArqygvqDpDoqAib+2L8MheQ+xP1dPRqA4n6Af0sEUPrWA947xITJO50EHkHPuVTCXsCKfqdE0zovAmf2ekQ/BDp9WoR" +
  b"yN9cBcAV8QZ48bX6ywVo+B0MZRMx/60NiNeZAukHLQfjFU3TWgrtAVUDIArK8XX75/3qBsIFyQIhD3vUWwbcAPoFNgGH6VYRSfIBB+IFjPbODPHkMAmwBKUE" +
  b"rQx55kAJtvfLB8f8RPsNCwDlOBZd+jj20g9K6DYbB/78//r9pur3E4rvnhM3/WP5yAJM73sTvfJwCaUANewOF1fvGRG3+Yv3tweA5ckUhPcmCggFyvOTCkbu" +
  b"LBCg/bz7L/9a7ZUbqu7RC7j3TfMnHPHa8hElBFD19A6F7doJ/PGLEFcHvQvA//HoQf4aCnQHtgmt8JEGW+pe/y4TaPlrBHXdiPlPImAAdgtp+O/+FvAGAywJ" +
  b"wAQAADTcKwSvFOwL6/94/O8Kjti2BWQLDQdfCdPbZAp1F6D7fhU896kHnPygCFIJ9AA5CMPcqAbABUUDnQWi3dILkBdjByoCq/vsBqjiRw5DEGP9+QG36GoB" +
  b"zQjqD4wHEublCX0UOfgnCd8H3fd+BzULdf99+Tr3XQC5Cev4kf7WDE/vTw0R32sIgAzsCTkVods27nkdIyR8/J/T8++9DCYLBwVoE4btrtijGHMDQvII9RXx" +
  b"KR3fAhbx/fNU+rQlevkR714A7PtND+0KwO0ABfXwEw1fETXm5wtI8JkG7hND6ycOOwjy6vn8QgKbCWoDpf6m+WL69xSbA7n8LeJEDToDFw9xA73b9goxBeoI" +
  b"jeODBYUHqgrMAEn5xe+/BWMabujw/vT26hVlA8T9Gv0O8A4Plga4/1fpAgwi/rcK1QCl648JKgZqAgHyf/3eC2L8BAiyAFPuIwhRCWz+efBCAvoEyATVCFn2" +
  b"QO+8C18KePYx9isGiAOOA1EAsPdZAmUDu/4j+rwCywEZAlYBT/ru/wsDtQMf+938BwEKAUwAh/7k/CUE3f+n/RQD2QIu/Y8CgwFB+t4CVAL7+c4HkfuQ/hQI" +
  b"lPaXCDcAj/PcC1n8QgBmEDbrkAO9/X/9xwv29Q4GXgC8+AQJCfryBe0LXPLjBAoC3/p6EXzugP6BAvoEBA1v5zX8IwH0GdAEDtv4DIYFtv2NC+nf+gSzAHYC" +
  b"hvtS8F0IbfmrAFkMoux/Epf3lfXnEeUDPwom7UP4xhCnCRwGVORr+jsJZQOUBoDvDQL0CmIGmQXm/ffwsQrZ77EICgaUAtYFsQD//TMEk+3xACEGffDvA9YH" +
  b"+/7RB1f+MgIODoXwrPtC+WUKLAZf9VX1JApG/p36YhF04OoS2A3+4i4cFve/+o4TxfJj/Qz1rPtEITLxce72+sIEUAwOAcf4a+tyB04LlhAA9nPsfgb7AroK" +
  b"AP4e8VkLGf5w/g==",
])

///|
test "amrnb 5.9k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_5_9k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_5_9k_cref_head),
    2,
    amrnb_ref(amrnb_5_9k_cref_tail),
    2,
    amrnb_ref(amrnb_5_9k_fate),
    16,
    2,
    "5.9k",
  )
}

///|
/// `6.7k`: 5118 bytes, 284 frames
let amrnb_6_7k_file : Bytes = amrnb_cat([
  b"IyFBTVIKHDjEoGBMO+z43p6blZmFOUVUHJ4lR/awv6t5MKe21oZZBZWgHJEcqb0l/6cvH1iGbZZxLdiwHNwUj7vL//J58O7fGG9wKgZUHFkUxXtZ/9O5yb8g" +
  b"y5EmL/lcHJwUyXkd/rP54p0zkdP8hvUAHJwUxHkp/9v5yXpjMNbL3ORMHJxKxTnz/8P50JgT5pnXGS9MHDiU9bBAf6P5yma52+nvCPdUHGwU3zhFf+vZ9Q6A" +
  b"rFAaYfNMHK462vqxf/bgko582FhEArPUHNfjL8sif2XvKA1PDoY2lj14HPCHPUJh/4q/mn7mdI0Kk23UHNWQXu3Q9ebvHPQ7u7eHVEwwHJNIj/r1fqOZG14i" +
  b"Wnez69WsHNWQfnnhfYePGH6/HDtj/6+wHKxxL1Gl/oPZFg7GhAqfkAS0HNWoXuFQ+80vBKl8UAxeqayUHPMWD/8I362kyhrilvISQe28HJEN/K9o/aGSEcsx" +
  b"RXyQB8kMHNeRD9tI/e2ExgDw3iEEyLusHJMl7bDlfMmyD9Ne+Qm9yu5wHM+WD+Pw+l1vP43RnrURsmBAHJEi/N+QaY0k3jB7beRZC3OcHNWiVg/lc/Eii8rq" +
  b"EMSJlGg0HJxn/aFmaxv5GR3+V4RtIH88HPL3RqZ0e+wv/fEkY/xKIxREHIKlNRip/509VMMZyChH+hjIHDq+/wZgf90v2Xk9YHWhZzgUHDqlMBgr+7VP22dE" +
  b"SjWALjPAHDq+/xh4fYR9cYGzzsghOijQHDr3YXiPXzhlk3MND8fEEen0HDip63j4eo18Qd+YDveIBfk8HDq+yVjSPm1xu289IyQ2IuZYHK53YXiPeT+gE/8n" +
  b"Vdlt8ut4HNXD17N0P53x2mE+EBV3uvfYHNf3xrdAfx52fyWxOEcwsE0kHNe+y58o3/GlqbedD25byCqcHJM+v0Aj/tLqa8IqUHyhf7RMHJFxy9T434fAANTo" +
  b"ksZfidSAHPL336AQe4dnFSHtUqkPxNlkHJFDx+9j/2Z2f9XbXfpccfggHPDgz8Fk/5AP1t0E8Kjjg4yUHJEvz+sRfeDJJNVPRpGAIe9AHPK+b11nfhPfjlJj" +
  b"ayypXU8YHKwv37sMflZWVg3FhyikGE2AHNelz4qs/G28RDdVbVmezqVcHKwv7ihqdaTcim0mcYjMohVoHERVy23geTXco3wrATVxUusAHJwonXJe6YTdSroS" +
  b"9dwZRsQoHJEQx71HfmDfLWBvV00+UDt8HJwc8yJAf309WIS/ss2QJ2oMHJEo0+VBfza3NPpmVFmotB3AHGxxScrAf/8/vQKWfVgarnGIHI0v72YKf3xcj9aH" +
  b"H4C7gQSAHBAvw+qh/qHlrRCqodMCMdUQHBAQjHJg/4Uv0m6VSg5w7LoUHPM+Jk7if40P1h71X/FNYHGsHK0iLAqDe//FMaR1SVE9NdTkHNXVRaQEfo/4HYi8" +
  b"nwxKaFr4HHDns71if/v89riuqfoAKev8HJwvD/P8/9Vrd4+0kNEPnr2kHHK+vphR//7kFp6+pGMRmeUcHIDgltng/7nhPT6SnkCau1ckHANyOJm5f+/gjp8G" +
  b"iV1PIBq0HDliSoiGfz27w/p2f9tKUKHYHNVqzzfA/7PsA3B5asbRsYLMHNXDF7+h/7xlC2lNfuBQgemIHPDRB39B/v178VF3FMEFCeGEHJM+w8Kx//5R10dV" +
  b"D2BMox9YHPKDNzdQ+v9gt5lfSQ61x7rYHPLIU3TA/80FGUWPFMuvu0GkHJ4+p9IE7+8BPx3QLUTdookMHDjx6Z/c+X8gon8hbXYgYj5oHNWpUGvka6H8zzh3" +
  b"ssw9d+yYHJEiXgpOfW+vjpdywtoFSyNQHNh6u3Rmf8NPEOFIbDKSemjYHJtpM5ic+L3dtOO7Mv0Uh2RUHJn6M7iQ+2+2VSW4t1RqM1/IHM2Qcqw7v8+HLyFl" +
  b"X6ZI2JnYHJu1Yn2m74IF0YyPic84HCpEHM+WwP2R/R6QXmL7XWVbvKTwHM3xYk/Zeb52X3E0QrOIsodMHNeL0NmC85TlPRUlISvxLfVoHJvIE7TMfdGiorre" +
  b"spSMk4z8HM+1oQEw/+D00IqtoMAUto+4HJs+qZTxf874RqqO4EKBGxIAHNXEqa1zd5zKrt4gzLlC5cmMHNclAwxmfgfAssr+qUzcTJIsHM2QR0DDf5pUR7m4" +
  b"U/xDZG4AHNVDqb0w+WHc3XdZhnJOCOSYHJmivYVEf+cXn/C46dw4KLlQHM2QA4iI34PqeMHqiAE/OGo0HNWQG+ux+US9rb2bLkClgfqAHNWgtx2G18ilNjYv" +
  b"lbbPFC0UHJMa+cUVfPXqlVhJk1AiDCQcHGAQ4e+l9q1x/ecICyASj82oHJMDp53C/eKKaO2/WKxsTVhwHPFnD6sofYU9fDDrUD85XrJYHNfuT+Ah/e/ggmRv" +
  b"SRTjBJJIHNeQ58Wwf5hikRtQw3XLucAoHM+WWwuxe+q5CUB9UmyyCB/cHM2T8l7U+Zu8jHkqT1llAFsIHJMQ896k/v13ydGles+WwLFIHNXxDw4zc9O8v85R" +
  b"keuAFd3oHJFnpz7h//2YxU1cWGfd6/uYHPMl40qA/8F8+FpJXs2y4QesHNWpW39hf7xx9H1zWS7IR19UHPFDUrrT+8tqZJkFr9wAtOhgHNelDdHgf+2x4+h3" +
  b"cUii9fPsHNXxV9dj/9TP4JzF3DGD7gVYHNe+09Vz/drqWEWWQY6wpNR4HFhxXcfgfYPqdAvViymdSoOEHNWQp7Tkf5Wdek5iEXdSGEQMHM3D3f0E/qZ3651p" +
  b"C+xQU5BYHM2v87wl+964ZpPWCKXdHqSMHFoOWSSBe7NqZ1lP7JRA+/+AHFh6tfwxepeXkB4NIA2Y+akIHNdKtbFF/3EyJi7bIgoUcah4HNWoPz2Be/GSNSev" +
  b"+QlylFZgHFgzTW0KU6+X3Leo2Mh1IWh4HK1IWW4f6zxvATfBKYzk7pS0HJwNDDoZX4zZU/RZdZZK+axoHGxnz+Y9/LO5CR13TKLqJhnsHK8QNRTD/31cmUb2" +
  b"HVHmt/skHGwpw/mQ/9MvDmHqJc5xdOBcHNwpMD90/+tqWXcBJSDUklLQHAI6lP7I/8P/ZyTYfjboxxFoHJ5ufnsB/8vgMVt7FNbv0xZMHAfjNQ7D/9P/jTtA" +
  b"wzln7K04HAW4Nxam/7zcQWzNcxcvoL04HK5uezuB/+v/kLqxW18iPQokHK4LHEzK/+2cuUYTGDvcVOMcHJEi3sTBff38iju8oaHTkI5AHPKlt8Ag/5P/rp4J" +
  b"qZHkjXEwHJMl+elIf+93LpOkZTJqb9NMHK4lTWPCf8Lfe5nBekeuYDF8HK4Q95CdfL3xmk9RxJo+2Q3UHPEY29Dp/8rfZdphFEy5ssP0HKwUz/JB/qzcTx0d" +
  b"nijwAi8UHK8Qb09F79v/al7Xxvu5uXCEHK8l28xp/5OfiKqxsvVADXq0HPMlz+hj/1J/czSQx5QI0c1kHDii3tap/r28it9G+gslR2nEHK4aWQng/238pqT6" +
  b"m7PK1lWUHK8lUxYRe2v/VeS62dV0bkeYHDilfk2NfZm/MGgrGRNnEQUoHK4lw8tpf/933oaevPOTUnqEHG4l+dyFf5FSFOHrWsEnFYzYHG4D3toB/5RE9+3e" +
  b"HY9BwPvYHJwiitp8fbvqW1fIcLUcIlGEHAJuZ3ylf6PgIW3utUOvY4TUHDiiStBJ/7t/ow2+VT7gK1mUHICGYopi/wX04X4xoy5SwuPcHILuwO3Vf6v/Yxdo" +
  b"ztexlGkgHDqQDdsJ/7307cyqJc/VcfMkHJ4QT9QB/9nyNW8ad4EroDjAHICiG4bt//304qOiJj0Ig1coHDiQG5aJ/9+3D6Ls4aXPvfQkHDqQG55Af7X07qqs" +
  b"pnGLR6xIHDiQO4h1/4ygUngjTJJBmO4sHK0iG9T5f5xggrCYL0WV+GEgHDiiG5AI/8HirSLoxyqJ481IHDruGztx/7BCmPY+mcG7oN5YHK8lG4ns/6UKpDoL" +
  b"/QfLER8EHDrAD/Tg/4HCprlo/yD6U1VIHDwzO/fo/7NPR0JX9zFJx3VUHK8lD/ajfRWUzuh4yVfbufg8HEYlJ3zlb1TxbHx5egIcPE1UHK0QC7OAfwK/TW19" +
  b"d9sc28YQHK0QC/opfdLfu7TgAySckdBkHPNRD/CLfXH/CUR1f670gyLIHKwoHu/Q/+wk+FHuivhPI4LcHEQUdz/g/7eXFiL+CgVNFWmUHK5uS7AFftTk0TEx" +
  b"Jc6hDFDQHK0Ui67h/+yrjlZPTWO/ArCgHK0uC7HCe01U0v5FMCuu5jRgHKmuMSuxf+0cTUjS3JSt7urMHKwAJ2PBftfHL4RNsrwIYlicHKwcL1Wrf4BEvGHn" +
  b"GdfeJo8gHDjIQzVLfdV3vng78ueiMEBoHPLRM68tf/E85Z6vjfx5r878HPDID/yBf/n80rc+s8CnB1csHJ5RB3Y7//P0eoCW4LF9E5d0HPD7Uz9F/9XvA74u" +
  b"j0AlIgqAHDrRDbiH/+3f2rNkil+jx8fQHJxnh63L/+XLYzl02l38myLoHJxVDy3nf82vJtltT4fEQecwHJwlh4zWf+v0VFHhTIFAm3Q0HDjVDzkW+9r5EFVF" +
  b"csjYIbNIHK0T89mj/5vZOPZzcjoK0JoUHICUWVjDf4tZHfhem5v+H9AsHERN85i1/4jFhDH+xN18/PMoHDi48ZmE/7FCl+psKDP0rjVgHJAU8bPQ/5NfRI2a" +
  b"0isNnGt0HAvu8m8hf4Sx/ap78o7XpJX4HAul8orA+7vPLrRYkWs2E2x8HE0b8NIl//WckuVmD+qyAxI4HKnDpKU6N5z9TGet70PzICJIHCal07lZ+5ECoVU0" +
  b"iV8khnHwHAul5ZjceoO5C6hn5bIz7se4HDwH8B+z+xpPHNF2l0epc7EkHD4lpKRQ/YoZD7j4q2gDu6usHJAN8OkvfLtKRwiVQE6vwEp8HKxn5f9i/4hSPuXi" +
  b"rnFZQbsEHNoQpBXdfaTqvmGsgN5mO7jkHD4Q05wsf9D85KCBtpzEUIbAHNUv8TxPd6VvJZfO76E6VDXIHK8b41Ls//mcxa2UifEUlM6oHNdv4frIf1tKkcmt" +
  b"iAbMgPkoHFgi190IfbNKqPqounaTCzREHNfAMzcA/+k83oqapKkvoVt0HNelaV9ofOFyHsybpdXxlEHkHNWNw3/M7+awT8EUMdrkGRlIHNeL+5fx/sbX/6SS" +
  b"nyJF6ORUHNfu8zSJflAzZx0dkvOvGppcHNWU0/aZbc5AnXkJdb/uX4EYHPCNo+pYfvxdkUVdFapKZtpsHFQUvfgAfyB03CaPiq+gPaeMHLpI/ywrfR1vEHQr" +
  b"aKvZh2h0HNGg8v55/ba/n+aOtkubms94HG5usaCA/pzvLnabzsw7EgscHLhV5bwx/67AAQtsoYk+NrxgHJNI4fzCf1FCnC6HgpH4pA+0HJEc4Z7D/evPM7SC" +
  b"JUrST6JAHJEow+2TP3EaK7WK1ypTZ1ZEHJNuw/a1epgc/oj3QsMRELfMHPEiw94Ht92vC8fcUNaK0xy4HFkXltmsf7U00FxfagysW6LkHPEULamF/6HSFxRl" +
  b"9z3Y7TsAHNWpTi9pfb9l9W1ZX7cbV/tkHKwGT4jgf6lSHV+NFn7S3WBwHNdK8DOw+1/x/V9NqHb9EyxUHK8a0v0uf7SEwaiUn9167xM4HK1o8NgH/1mkPdSG" +
  b"ST9w943sHK9H8PkO/WpCOaMNKSLIcvFsHDrA8PIv76WLji1XuIqlDiZQHPEM8MxtfMjQFDafu3bkXJDwHK0Y8NhIX/iyO7o9o8cZIj7cHM2Q8PJ4+JVrm0M+" +
  b"b7VkT0XcHPEY8NgUeM9XZz6cRSQHeSk0HNWj8FxifmlCnZauExDdRv8wHPMa8NgyfuAikusbjQ0DbErwHNeCw/maeRik+uhkea22DvyEHGxn8KrR/8733b5N" +
  b"YU016JJ8HK9u4fiX/yePHQ6Ja6nQoHqAHDq+w9mefv4vAHMfYfZb0uEIHKnD0vk+fn5vGXYm9IN778rQHIK+w9mefP7PGb6PZT4Z0gBgHHVD0vla+5EU+XU0" +
  b"bEIxt5c8HDjD8Pha//QE6H2V7GCxuot4HIDD8PgX/knU3sxt8gi7d3CEHAVn8PgV/6LZGMbsAKjWY8+4HNclLiXgf+74fzySodp+tlXwHKwvw3a3//j81squ" +
  b"L/hw1qSgHDjDw/my//WPLor4wN3wyDSwHKwv8zwW/59R558oyoi0lAjsHDj78zgT/+q8ncleZWGM2xVcHNUv8zn2fsZ2S3xIzWscj54wHJuL8xeg/dXv6NTx" +
  b"RWOA8hXgHJnEw7QCPu3b2VR3ekn/tJWYHM+Lk1DXe/IMHchjdyjgdeCQHJvUYxRB+oHMqWR5e4I3ZGlIHNXVk3fHftbApcBYexKk5amQHNebXl/ke/yFN3rA" +
  b"QghR0sqYHNXVXuss/+ZR7lDA8zmaxQx4HPKD5kfkf4I3pIBKvBOAb7msHK9RofQheqSJPt6Ek4DH7TZQHJFnHusGb2Z33ilGq18NbpJIHM3ILOl1/lYRzrKj" +
  b"EXGCuPpUHPFDDi4dX3q8hP8beVTxKH4YHFh75/82/3SPAxlqwADJHSJwHEZ0890O+xEyEore1yxUaTLQHK0o8POv/UFAdVKOnyMH/Ec4HEZv8njmf1UY16vN" +
  b"FQRosxU4HEQo8PmWe2JcsWFtYadjC6yEHDqQ8Nn2fG7/tq44pHEO/u9wHK0QDDpI+q346oK20MMCQT8IHK1ODF2fW/a4cMjOiLeWvwCcHNWiGx85ffDCvyUL" +
  b"ErNJGj4MHNWpLSuEf7s5OXZY0NRh4QUQHNe5S3/nc9vqZm05evpzNNScHJsW40aje2H033d2hL0gzGbQHM/o07BBc0zFa3ROaFhibSF8",
])

///|
/// `6.7k`: the C decoder's first 16 frames, s16le.
let amrnb_6_7k_cref_head : Bytes = amrnb_cat([
  b"AAAAAAEAAAD/////AAAAAAAAAAABAAEA/////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEYAVwD6/9//7v/b/9z/7v8HAA0A+f/4//3/+P+3/6r/xP/O/xYAQQAyACQAYQCtAFEA+/8YAPf/w/+9/9v/" +
  b"3gL8A94DJAQrAXL+UP0v/Kv8y/3t/vH/lf92/+T/ff9l/+f/RgByACwA4QJMBuQDtgLzAlv/pPy/+w38O/7d/Zb+KgAT/3L+Qv5u/TL3qPFq+Dj7mvvrAhcG" +
  b"mAjVBisDOwRGAkP4kvW/+/f94/3VAEoFlAaMAfjyz+vu9I33VvljBooO1BC0DAsITgg1+gXywPuo/74C6AbgCPkKVQXTAOUBIgoPEcAMkQuDDY8McRIvEpkN" +
  b"pAwoBWf9bvdy8ovzkvMM9Nz2Tfe69kb3yfKw5gvnMfHg9KL72QQQCokKlwJGAAkCr/71/5EArgL8CtMMAgl6BOf/C/+p/I71ofMF+9T/H/yV/NsB1wIL/L7z" +
  b"Ou9p6hHsjPcz/zQDlgikC1kJ9wMuAtAF/ArPC+4MtRHdEjAOVQbaADMAzP4b/tn+u/8MAh3/MvybABYCn/sF+KD5vvzk/tL+cf/jAWQE5gMZA2gEjf6+9mj6" +
  b"i/2D/Ff+hP+oAh0BEfQi70T1+/kV/vQD+gYTB4MEPwGj+sPzSfip/hQBhQdkC84MnwsbBCz+RQK1Cm0KrAX1BX4HkwoRC3gEc/9d+sX3rPeK80vyp/V7+f39" +
  b"lvwS+ab8FP/49lrx9fFn9Pj5Cf62AikJZQmJAwD/Mv+EAJEBhgUDCGQG+gdTAvj3sPqr/Uf+XAKoAw0GrgTPAUT/uPln/eUDPQgaC0MK4gtCCBUEjwawB14M" +
  b"Bg7rCNUI3ALu/ZMETwjGBlYA4Pri+ov1de/v79/ycfZn9cb1sfel9mL2o/S19dz39/aj+w394PmS+1D7m/sDAKH/kwAqBMQEDgWvAdz+lf0w+Kv5Wf6u/FL8" +
  b"lfwp/HX9L/8bAoUBL/+qBUkNOAw+DZERdBP5EbEUKRzFGZ4VIhdAEOMIWAStBB0N4Qgq/u/3WvCe67Dp6ufL6Uvt9e717fXtW+/97i7ycfe09y370/7k/sb/" +
  b"JgEWBKUHEAwRDoALaAsqCo4HiQdYBngG5gLk+Tz2ZfQS9Dr0q/J39vn55vu0/dL7wfxn/l4ALgSoBgIJQQugC8IJYgmQDQ4PEg5aD3sM0wWq/xP88gCWBDYD" +
  b"3f+k+Tn4Q/bK8ObxefXn9yf7Rv2p/+L9Lvpc/Pr81fqd+9/+9AEh/+T/vgO6ALv9DQDAAln9e/jD/a7/CvvY9pf0JPO+8l36vP3H9af3EgBpAb0ClwdZCJQD" +
  b"PgXjDaMNFgxlEq0VCBd+GqQc7BiiEuIOMAhSAU7+MwLhCqsIs/lA76Lt1+h9483n5u5R8F73wgAo/Q76IQT+BjECXQbLB9YBovss/L8AJwBvApYJVglLBEIB" +
  b"Hvtq96z5Ofle/p0JRw1QCKP/7/ny+lH27PQH+jT6pghZFDkLxgNz/qj5yvYG9dz52vIB62H1wPp698zzO/GV80H0uvw+9p3gNuuh/5sDlwgaDbYL3QMjAugN" +
  b"BgwiB6gQyRPkE6QXayX3Ku4WBgoKB9z57+5a8yv5XvZ18DHxv/A57ez2ufWX4PjhD/i28M/imfeIGIIglBNMEfT//uOK9+IQ+w/aEKYffS7IHI4JLwyq/uLv" +
  b"sPbE/p/7bfSz9A0EgQ3+Bd3/cPIm4d/tY/np58bhcvkPGiMZjgj2A9boEuAT/7YPovqA6sgIYx4ZDKYJXg0K/uH36wJQDC0BJ/mEAfEKOBD2C4gCpO+V9hQa" +
  b"/RhaAhgE5wo0Ayn6IQU0D5sH/AV0BGH0Pe2r+CD/Avah84X2H+bZ3Pfs6vRg7S/v7/xdAOP8uwGmAPMA9w+cGnMSpgn3BFYD4wnTDDsPoBHqClUDRfxZ9fXq" +
  b"ZulW+kMEIv3b8K/lYOSQ7Ob5AwM494zt1/ZX+nTyFvfhEyoflwx2BRv+w+/z++8XRyNBHB0a4xkYCbIB9Q0zDGD9kv6tBu4Mag/WBOH86wb2DRkHWf1v7yPo" +
  b"DPR/BHEN/Adt+1D5IPTM5CTkrvHh+qn73/q981jd5NsG9rYCJfpL8Tf3Mvvz+6gJ3xCWEcYSbAyEBT72DvMoAxoObRz3H8AR7wvSBcMDYAaiAb8AAf/Z/9gR" +
  b"0xFT/oD9SgqOCbfwNN733vLmj/iRCw4Lef/V+AD9Sfmq6uHv2P65D/kdOx8OEK/vtOiuCaEWugn4AabunOmoAR0RUhGPBpj+qgEu+TPgwtaV53L6AAANAD/2" +
  b"497l3Sf4DQaS/LTz5vscAEgFCBUSFkoTAx1AIDoRuPdk9bYEGwx7G2Yi5Q34/TQEyAb6/Sf73QE3AHn2cvlU+hft0PNvC8gI6u774fTgCeAU7BYF8BGrAwH4" +
  b"lAZKBVj0+PgkCPYTtRS7DjAGxvAg8mEPTBNBBVwBCwe0B0r9cf8HBAX9HwjtFnYNSfxB9MT6wgdGDToLNgPW+S366AAP/0P5t/g3/zECtvr88SPtkuyv97YF" +
  b"AwMx+BL7+gEH/zn70v2TAUYFQghABG39DwXLED8TmhHfCBcA5/3E/l0AAf1O+dz7Qv0f/3v+CfDD5jTwCvyI857nAfIi/V39ugHtAVT8kfz/CD0TGQfe/cMC" +
  b"dg7tISgiFw+rAeT9rgFdAFj96/1j/TP/Yfxa/Qn/cfjF+Iv8J/Xm6H/iw+dJ91IDpgiUBrUA3gEXAjEDfAQTAWECcwXYAn0GbAWc/DL8rAFUBHn6SOy97JHy" +
  b"Pfr7BOMCFf9HBdkH2AkcCjcFkwNKCFgXXB5bDL8E8Q1QDl8KKwNU9f3thvS7ACoCQP38/R78vv3G/Gr0qe8O7Ij2WgSGBV4FGgE1AvUM5g+VDR8FfAAKEKQa" +
  b"eRONC/kI5gV+At0BqvKy4sDu9v2Y+VHvSuxn8lv1Efjw+Xfvd+kG9QT8VvXk95MBNAIVCioW8w1MAEsDKhLQGN4O/Qd6C8sMYgdvAjj/hPj69Cf6hP/K/6rz" +
  b"tPGt/uT9z/oM+WPsceju77X4Pv/d/pH9fvz8+/n5+/Yg/0EI5AdgBpAI6QhjBmoKOBX4FbEJLf46/T0BqgGmADP9K/zVA2UFFwDJ/o8C/QuCET0Vsw+QA6EA" +
  b"xgGaBJECr/ve/Vj/RPgg+KH+Uf7L813zdvt98rDs3fhT/175DPu4Ahn6sfMz+wj6FfgzAhEPChU4EM0J5QiF/3rzMvj/+Enu8u7c+dcDPvmS6/b1jgDW/kb5" +
  b"Eu6u5s/trvo//oP85vzyALcOlhg2EVgIQASsC1cZlhnGDJUEHg+xHMISuwY8BTb/cf0CCsUTiQU49Cb6tAKW/pL88vly9Rv3Lfw7AA/5ifJa98D6VP22+o7w" +
  b"s+008ub9SgdQ/pr46wAUBrMETgGzBHQM7A6oDncNtAnIBBf/gwLtCHMCYfuS+jr7Yf16/RT7L/hn+Wv9z/sG82rsvfO0ABsHLQZu+3rw3PU7/T74E/Up+rkA" +
  b"KQBJAs0IPgWrA0wOTBLxCR8CswJsAgwAiwTdA/70vfJs/yoBQv6tBI4Otg8nCfAKfATv87n2avvs87Hy0/gm/hv5DvRi/Jj+Sfta/zX29uU86UD0WPtiByMU" +
  b"XBGICAAQfhlBD4sKmReCGaISXRKXEhkKKf2G/WAHhQRu+3P51vph+Xf4sfyr9wbqGekF8ev0PPdE92D2DfnO/34C2fd78mv7jgBQ/rMA8QMwARkBiwbiCAEO" +
  b"thKlDM0FewI+/Lj2dvy8BiUGJf01+FL5cv2AAiMCmP/c/lP7Xfs3///9G/kO+7ABqwCG/1wCvwAeAvIGAwbTAgIDaAMGAHX5AvWH9yb59Pn9/tECoAMTBR4F" +
  b"xgcsCikHRgS5AZz/OP+R/QH9gf3B+xr9FP72+mn7Xf59AHn+bPdx8hvv0PFK/AoC8/0L+rEB1AyZCW8FIw5KEasLKgurESwNsgdtF8MibRhMEH4OMgY+/joH" +
  b"khCPAun6/Qb4/gLvqfN096Tyt/Bw7dvlF+HV6tH1v/CA7+bzDfVe+x39OvrG+x39Rv/fAJn+mfxq+Nf5CwOVA8D/TACQAHgBJQTPBIgFogPj/jr9Y/04+Vfx" +
  b"2PXBAYkE0gHD/DL99wM6B/YHcwdgAJ75SPzDA10FwAF1AacD1wSnBmIFzgSNBykI8gavCB4JhghsDDkKNwHe/9wFwQ3JDm0JKAQk/DT7dwDa+0z2+PbU91H4" +
  b"hPXI9Mf4NPhE+Wn7V/ap7Cjoq/HW/LX8tvkh+gkC3wgICM4LPw9SEdATdxMiEf4JdgnWEu0XVBPeCncBu/p6+/oClgNU/ED7d/0O+1b6hfrx8Wfu/PV88KTo" +
  b"Je817XjppvAV9hn6LPyR/jADfgHWA5YIjgZCBlgHqAmOCSYFBggMEMoUPxVrDocFvgHCAq0FKgIJ/Rz+n/vw+pP7kvox99v3PgI//Jzspe0v7yHv5fS482Dz" +
  b"ofkt/H/+bQBUA+AE9wOMBfwI1weXBUIBAwBrAbMDGAQP/yEG4A8wC0kJSxBEEk4OAAmvC0QKaQNDBQoBXvv1/dz38/ms/5H6Re0i7Dj2C/BA8TL32/C49+X6" +
  b"j/v5/nP9mgWmBwYI/Q5VCzoNIg/3AGD9FQDC9zz1E/fV79Dsy+/J7RvtdvDN9IHvMe3w+OT8L/04Ah0F3gclCjMO9xE4EJMP4hGPGhkhnBqeFzwURxhnHBAU" +
  b"pxC7CsQEWwXKAAQGAwRg9oT2BfLV57PnM+cZ6MjmGec17cvr+PAp98n3V/x7/hIDjv7J+7IDogFNBbkL+QuNEWASrw9OEuQXURaUDwcPAg0SC8YGNQBKABz8" +
  b"gvax9MjuvOrQ6tfqK+1M7PDoqOpe7RvoVORN7Kzuae888sf1Uvpe+lb6Q/c6+IcAVANTAqQFBgkXCyMOrxB0EyoV/xJkE/oThROLE5ERYxZvGxkYGhb+FFIb" +
  b"IR5bGP0XtRPUDuYMdQmVC5wJ6f7p+ub2M+su5Lzf/NwI3MraA94x3KjY9d3E43TnYus88Fry9fF5+Z0BfwOEBj4NeRK3EpMTDxdYF20Zjxq8GWIcHhvtF3QV" +
  b"5hFcFPcRfgv2CPsDSf9w/DH6dvut/I/4NfWs8WbrZ+mm5j7muus36kTqcOtZ6MDrY+/V8DP1/PTW8o/yD/SH+pH/oP/qAU4DAwVqCaIJ7QwjEaIO+A40D3kJ" +
  b"lQcGB30GGAhUBL8BqwLxARoDmQHa/q/84feh90f7qPiU+AD81fwu/RX8/P35ARsCIAPUBTQDaf9sAHIA/f12+7j8SwIRAxIBTgQZA3j+LgDIA8cEWgWKAhT+" +
  b"6fsC+239ZwEvA7gFNgVmBEIFEASwClkRyhFzFRwVTRHnEAQRtBFDEWEOfgzTB/oEIgmqDAgQtw2EA/L/wPkV8cfwNvKE+Az8IPne+e/zkOlY7Mbv0vCr96j5" +
  b"6vbw8s7uePL/9Yb1ofit+rD6A/go98T54fQe8uD0CfLz86z0xPNo+S75ovg6/Rb9xPxrALAF1wj7CWMLpAlyA1MB3AFX/8j9O/7v/tf9evvg+GT1XvFZ8+33" +
  b"vfcD9dP00fYS+DH6Zf8XBdYIZQoYCygQYhU9GcUdsSBUICQe9h3SHQwb8BrAG4IaQxd8FuIX8RWPEkEOsQdlALv6K/bS8Zzv0fC+8GvtM+l/5ALgEN7h3m/n" +
  b"Iu667mvw1u/d7c7tk+1c7mTy+vb7+M76FP6Y/j7+tgAQ/uv3iPhU+yMBIwhXC7oOwQ7YDBkNXAxqD3kUXxbZF00X8ROyEdYPpA2eCzIMnw4qDJMLhg0jC5sH" +
  b"MwS6AN/74vaL9KjxY+9n7qLtR+1w7G3p8eYc5znnnuol76LvdPAK8h/zJvTV9BD1rfZa+r/8yP7+A3kGegcBCjYHZwMiAw8EHAUfBvAJhwtUCjcLDAvrCkEO" +
  b"PRGjEi0TyRLBEY4TMhU1EkIQnhNhE6MNYA6XEbwOpgr0BxAEB/1e9x30ou/67FDuUu8k7f/px+dK5hTlf+KU5Zbqfuv+66Lv0PKv8xX1vvnk+xX+YwIaBF4G" +
  b"FwmGCrcLogogCoEJSgmkClsKOAwZD5gPSg4JCLICGQPcAngBg/3F+dX4LPVC8470kfRU8grxDvTg8ebuQPYJ+Bf37vt7+kf5efy9/n0BpAP3B7oLPgvJDV4N" +
  b"MgyIEskUkROaFfEUMxRGF9UXFRSyEcsU4hMPDJAMTQ2IBoEDxwAO/Jj6zfYG80bwjuw87tPtZOw78Fjx2fIi9FnyfvU098/2kvhM+gD9dP2v/OX+W/8P/5D/" +
  b"Bf+Q/xEAOP/U/qX/nv+R/pP+7v2m+877yvsg+VX4hvtN+7n56fha/OoAnf1cAOAIcwaCAWsDJgjxB8gCAgLs/iL7Qf33/aL7cfoi/DP9Qfqu9yL6M/9JAsQD" +
  b"qwi3B24CVggwC5AGHAj3CxgPMg9MDnINOgmDCvwMGQm6CCcJewYFBwoIxgWOAr0D5QXpAJT/7wE4/nj/+ACQ/LL7f/j79AT1VfHe8vD0G/Qq+GL4wvkm/NH5" +
  b"VPgt9w35yvnp9+/68fsc+6P6aPcf9n31uvTD+BX+OgBaAEsAnAHZAZkB7QLjBNcFSQiIDrQP4QqDC5YOjw0EC2oLzw5oDlcNJw4nCxsIlwgEA4b8k/2I+4n3" +
  b"CvlQ+0D4f/Xc9AjxI+vJ6EbqIOvm6wTwEvDu72b0Ufbu9Dr1g/nS/Gn9HgEVBYkGNQgUCN8GBQdqB+YI8QuMDqkOmw0wDU8PMBANDRsNeg0=",
])

///|
/// `6.7k`: the C decoder's last 16 frames, s16le.
let amrnb_6_7k_cref_tail : Bytes = amrnb_cat([
  b"sAB3ACgArAFDAScAjwDN/38ATQB//77/0/9ZAMX/xv/mAFYAJv+X/9H/GgBe/67/LQPwAbsAYQIaAyUDzAItAtsBkAFwAG7/TP+6/sX97vzK++/7qvyF+zj6" +
  b"WPoZ+hL66vpe+7r7f/sD/IL88fvu/N/+xv55/9EAawKDAqcC4wQXBfYE3gQrBUUFQwS0BJwDRAOLA5cBSQL6Au0CgwLPAIQABwEAAPj+yv5U/wP/U/4M/lL9" +
  b"FP5E/nf9Tv1W+yb80f2N/HP8c/3S/Yv8A/xc/PP7Bv1e/sn/PwGQAZ8BIwLxA3AESwSUBM0EuQWIBUME0QMzBDcEPwMuAvUBygF5AycDswD+AOIANgBZ/y/+" +
  b"Bf2j/Ej9Xfxc++P7PfyF/IT8afql+Or6mPyG+2H7Yv0xAKj/aP7+/f3+UgEYAQoCQwRnBYgEiAM6BSQIkQj3BjUGaAduB5IFogOwAjcDgAKPAgkCTwA6Ak0C" +
  b"Yf+H/u/9nf0A/WX7e/sK/Lz7Nvs++mf6HfsE++D6rfjd9gT5EvpJ+QD6N/uk/Nj9Af6C/sn/8gFtAwAD5gIyBSYG/wUuBvoF1gaXCLEIGgeKBkUGUwWoBPoC" +
  b"MAFEARUB/v7f/Nj6hfmD+AT48feo9u/1M/av9nT3yPYx96H5APvV/K39Fv9qAVkEsQa3BkEI2whICA0JfglFClgK8glsCWMI7wmxCfkGqQWCBH4DtwHB/zz+" +
  b"9fye/Ez7d/mD9rn0ZPWj9PTzMfTX8mTyBvTn9AP1wPUU+LL68fyv/X/+EQFXBAoG7AVbB9kICwlKCW4JoAp/C3YL5QrkCZ0KQgt5CaMHTgaPBVoEWgJqAN7+" +
  b"Sv5U/a/7Z/lj94z1XPOd8mfyrvHV8fX0CPhI+TL7Zf3B/0UDFgYSB9QI9QmKCYcJFApjCyELTgq3CUAKCwxtC94ILAcDBgEDtP4d/Gj6o/gN9wD1JvTf8t3w" +
  b"EfCv8Ozwo+4b7vLwSvNH9HT1Rvif/E//j//EADgEGAivCEcIFwpJC1YLwgrkClUMigxlCv4H0QjQCq8JxAYhBTwFzwRDArD/DwD/AO3/EP7l+yT7+vsG+hP1" +
  b"G/PU8Vzwgu/E7orwkPMe9Zj1Ifct+2T/Sf0l/KgAiQMfBFUENQeJDJIOYQztChsP7RMUFgYVdRPYFLoUyRBwDIYLkQskCFEFwgMrAVr+vfmv9uL0S/Gl7q7r" +
  b"9Om56vbsZe9R8Ajy/vRQ96H5hfsB/F/9UQCtAToCZQN6BYIHuAePBm0GyQe4CCwJzgj3B7gHjAYSAnT+NQCCAV/+ovqO+j788vYQ8DHuyu928rjw4O/M9Dj5" +
  b"qvrx+Rr8rgJaA2z/9AD4BDAHeAZXBjMK1A2mDHcJbQq3DvERCBKbD2kPqBAxDtAJeAfkBlEGVgRkA+EGcAddAu/6yvWi9kD0P+4v64nrou4R8hb1Avhy+kP9" +
  b"jf/V/30BVwKmARUDqAKCAdgBYgIfAT0AVgEc/zP+Z//A/e//cQB1/g0Ab/or+eb8G/un+mX56vpP/mr7bPXf8Gnzhvbz9sH4//qXAO8DhAN0BQ8I4QiICA4I" +
  b"QgnICYMJcwlkCVcJhgikC90Pdg5RDmwPxg2JDEwIlQRVBp4FmQHd+hr3LPyJ/J72ofLJ8GTyS+y24+DmPe1q8YLwtfBz+ar/IwAc/1gBbAmJCRcDrAP/BsMI" +
  b"cgZnA5IGvQkHCKsDAgPNB6ULdwsfCckIRwu3ByYCpAHnAAsAdP1T+vb86v4x+qPzVvLz9Kn2tPVh9dv4gP05/6v+lv8tAoQDYAPSAgwDzASFBZ0ESgTDA0EG" +
  b"VQo/CxkMJwyYCxgKpAaHAtn/6AJqBV4B+vq29/f8if/G+XL0DvBU7+jpBuC84oPo7uzN7TjtJPZx/uQAKgG6AqoHDge1AVcBVQMzBQcGEAZXCZUN0w0EC54K" +
  b"9w7UEXEPzwyADsEQ4hGgDtkIvAYOCsEMUgpZA4D7Lfj79RPxte2b7bzwlPnv/sT+1wBkA7IDpAEe/jn8qvx0/cj8MfxT/Mj+9wP8B5EKuQv3CmYJIQamAIz9" +
  b"LP/c/1T8nvZf9YL6CvzV+IXzG+8z7ijowuNu5hjqnO+L9G/6IQKDB2gHcgSXBDwCBvx5+KH4OfuV/u0EQAyZEZ4VLhUZEi4O0AqgB84D/wK3BlMJgAiLBOsC" +
  b"NgbuBRgCGP2A+NDxb+fd45Pnl/C7+vv/DAh8EBcURhA+CBcFlQEz+5n2T/vOAwsH6gt6ELUSvhMHDqcHiQMhAB7+jvrF+soAdARiAxr+kPz/AIz95PUI8YLu" +
  b"Kubi2CrW2d7560T2G/1xCE0UNhlSE0MLtwlrB9j/cfnaAZoOcRHOE+YaXSFuILsVEQvVBW0GEgZE/wr98wF/BG0FzACG/fj/Rfo68MLpZ+V83S/RCc8A2Vfl" +
  b"o+3W9DYANwyAEI4LwQb9B3UH1AAT/KkEZxGmEqASlBSfFiMV8AphAi4FiAr9B0UDYwQ8CTwN8AizANP+Cfsg82zr/uXM4MDYFtfm3pnpDPIt+DAB3wddCFcE" +
  b"lQHxA2EENgDH/ooIdRM4FGATkRMZFyEXzQ1rB1QLqRB8DQcJ2AvvEpcVHQ9UBesDzAOC/cL2/vMU8Zbmm9514P7m9Ogf6tnyifo8/sH9Zfy5/hf+APd17hrx" +
  b"cPx0AdgCMAXdCtUPRwuEBE4GSw3WDxoKUwiHDLQOJg7RBqoAJgCI/oX7P/ZK8WzsDOeQ52jrqvDt+dADjwkjCsUHcQWGAz4ARfwK+Xz7egQ8DJcQkhI9E4wV" +
  b"xxJECsUEZQasCCME1gOtCQsLrgqaCnoIVgRW/wr84feI8YnoB+F84D7k/OZI7Xb4zgE9BFICvgBEAIH+TfrM9c/x5PMU/aME9weJCmkOABNJD+kHYAdJCugI" +
  b"IAfZCp4N7wwGDgEOFwlLAyT/LvtQ9aXsNOK63Vrh+OT76HLypP2pBGADkf8WAOsAaf5t+vz3IfqyATwI3wqNDEwPmxJNEPYIGQZYCKwHOgVRCk4Q9g+QESwV" +
  b"rxJWC+AEYgBJ+jXw/eD51H/WDdyo3yfpqPeRBMwGQgDI/usASf9F+rvzS/OG/NcDPwZxCXgOkxK0EAcKbwdGC8AMownkDcwU+hSFFC4U1hBpDTsJAAN9/CD1" +
  b"YOq34KHhsuly72n1Of4mBgEHdwCc+6X6yPgs9X/vH+439Wz7xf38AMIFdgn1CG0FkwT2B1AJigcdCxYQfw7mDOIOzw3wBrMAtP5d/Fj3Ae+J4vjfY+oU8ub2" +
  b"f/+RCZ0P4QZk+1L61vmG9jXxzO0q9lv/9wEQBcgJlw48D4cKvwfZCTAL+ghECSQOAg9EEDwUtRLBCuwD7QCE/LL1yezP33/cYuYg7r70FP7/CPsPwAkwAdT/" +
  b"Hf6B+lX0c/A19vv8LAKUB7gLig+SD8ALeAhuByQHcwS6BAsJ8wh4CtQRfRNLDNADkwFV/3f3P+9y5GvZDt0z5qjsb/b3AB8Knwp9Az8CaAIu/yv7TfZ5+Ej+" +
  b"+QHQB98L1hGyFQURlgx+CuAIDwUXBccL9guFCbcPKhWGD1IEqP0f/Vj30u3h6TTkMN9T4dXl2O1x9gr8XQGJAcf/5gCk/XH6wfcp9Jv3wPuo/9QFiQmvD8wR" +
  b"Vw2GC6AK6QePBQQI7QtXCRMILg1tDuIGu/7H/Y3+FfgU8x7xHecx4VzlTet38//5LQA0CbwIyAUlBpIBrv0895v2V/93AUIEEAowDsISzg5jCagK6QhWBGgE" +
  b"cgq0DF8HbQjLD20RwgpUAj8AMwBq+EDyvPRg7UvcwtsF51PtBvL9+MIFwwykBIUATgED/YX1DvBq+oIBIv2iA3UMlhBiEAwKswvtDXcGtQM4BzALaAhZA0QL" +
  b"+xHXDFAHVQQ3A6sBN/2B/XL9tPDf5RDpMO2z7rP0yf2GBT0FdQBE//f8VviM86T0RvwI/CP8lwOmB+IJFQkHB3cJtgcQBFEEXQWlBtQDUgMGDN8PhQ1mDOEI" +
  b"KARIAWUA0P0T+KXwzefb5SnpNech7A34D/5RATIC4f0u+iv4y/Us9uj7bP+/AZEGzAnNDP0NfAtMC/UK7wihB5YGSgiLB34F0QkrDcYMAgwvCeMF9wPeAxcD" +
  b"fv2I+LnzeeyW66rsc+0F9cT6dv2PAd7/hvoV+Kr3Svf59xf86v8wAo0EkAYgCWMJUAc4B8MHcQbuBPYEowV8Br0HaQnhCX0HcASPA0ADcwE1/Tj9NgIeAYf7" +
  b"yfiN9YDuCesU7ZTyUPeh+cT+FwQ0Av/8mPxM/4n9n/thALwDigO7A+EEiwfWBjEEoQTQBFEDcQNSA+wDxgijCjkJCQf2BK0FrwMGAnED0AKrAcr+ePs2+hzx" +
  b"DepD7iPv8exG8Sj4tvyy/Zv+JAAHANb/EwCVAV0EQAQEBW0HbQfVB0oINAgMCOkFMgUhBR4DdgPiAloCtAUbBv8EQwPLAZYDRwKQAsEEYgMkAhn/qfwR+Zfu" +
  b"cuoP79rt0Oo38Mj3P/rl+2z/lgCBAO8BiADUAP8DqAPUBJIGSQe/CFgInwiwCKwGxwYABvcGiQgiBVIGnwjGBZkEJQJlBOMFmQFnBPkEyQG9AGH96PvG9YTt" +
  b"TO8a8S7t9u1b9JD6m/w8/q8BsAEtAqUD3f4SAG4DLQCjAdsCZgOaBNcHbgqtBrkHegk2BbkHKAhSA3MFhQUVB3cGsgD8BrAGNgANAP78cf3P+Uf1zvdg8aDs" +
  b"E/BU8FvvL/By9rX9Cvsh/RcD+v5o/+0DKgIDAwYFhQU2BisGWgdOCywLxgiHCdAM2QvYBmUILQkqBdICBwCLAsECSP72AN8ASf5F/Tj6FvlC8y/sBe6l6e7k" +
  b"iuoD6gPpP/Bw+AD8a/4VA9kEWgYNCbMFBwsMEesLHw14EM8NFQ38Ec4SnwyxDGoNogdWCKUNUwnwBQkJ8Ax3CeECVQfuB5kFBAJj++H8U/kf8hrzsfKx8L/u" +
  b"A+/v8QrwsPAZ85PuKO5o8WnxL/Vu9XDyL/bJ+En42PrG/Cv9uf22/wkB8/uI+2H9k/mN+lwBQgAP/3kFkwc0BC0HvgpFCeIHYgdWBoYIGwwQCHsDRQY6BhUD" +
  b"jgYuCBsF0gYpCZUHEQbdCHsInwRtBgwMugigBOwJlguXCHgI1gfOBVgEBAJcANP/R/0A+xz74fkL+P72APma+zn89v1F/az73P7g/9j6O/gp+Fj1q/L18QTy" +
  b"FvKT70zyd/fL9Uf21vqk+Gb28/n5/P78NP6PAZoEAQfXB+YIAw1DDqcNPQ0XD6oOyApYCQUKlwgTBYcI+QrpBPYEgAVm/rL6SPpj9jPwRu1W7o/t2eoO6+jt" +
  b"9fCS8xb0tvSv+SH6YfugAyYEWwMMCxYPlg6nD0MUTBasEywV4Bb1E48S3RQCFhoVWRKTDDUO6xAlCfUFPgI4+qb2ru9K6Ufh4dox3E/YYtT215/Yi9y143jm" +
  b"XOxJ9XLyhPRqAR8EMAXiDIQTxBeqGTsefCGnIukk4iHjIVQiqBxcG+MbgRuwFlcPjw0+C/sFRgV8A1T/1fxv9mDz1/N/7kroReig6nvl7+Ga56jn2+Sc6eXr" +
  b"8+vN7+Ly5fR3+En9cQRVCdkL8A80ExEU6xTTFY4VcRNVEZwPjwwoDFIKqQQHAKn+QP2R91X0YfMA7UXpHOmD5kfieuBr5GPkR+KS50jr2+108ifzj/S791T5" +
  b"Dv8yBYkGZAqmD20SqRPyFRgabRqoGX8c3Rs/GV0Z1xhXFRgS3RDyDI4IIgpmCK0CHAH2/3P8OPpy/Bb8ZPnB/C8AHQC1/2f/6//2/8D+bfxq+RT4SPZx87rz" +
  b"0PNa8kTy1vKq8sXzbvi3+7b6YfKh8zP71vS79LP6PfXg8533t/a+87Lr5ezi8C7rTO7t89TzIPkD+er2EvyU+4AAIAH7/IIGDwlzCMIP2RGCFdEYFhr9HoYf" +
  b"BiHQI+IhlSKoImYkSiX3Hzgf7Bx6FssXgBloDycJMQmtAQz7Cf2F+jrzsvZ0/Fb3E/U7+JD1ufFr8tTx/+lc5ibpVuVr4r7n4egK6Fbr+O5j8tz1sPWn8vv2" +
  b"efsg9+X5SP5G+lv7Yv53/YL60PXg+Kz4y/P6+PP7vPz2AvkCOAOxBokGdgjiBEsDbwiaBA4E7gb6BLkGogmsDCAOagwiDx0Rmw19D/IPmAxRDvQJPgfiCLsF" +
  b"pAQuAE36Ivht8zL0APji9U/3kvz+/ff/igGeA+oENgPcBXsFLP92AZ0CX/vZ++v+Q/w/+1f9Mf/q/fH+VAHC/wsACAGc/1v+KPxI/O76UPdH713p0ewP6THj" +
  b"m+nt7XDvEvbA+vj9cQKoBxUKkAcDC58JFgO9BssFKQCUA/MHtgaYBYoJmQzSCWULJgxeCMsIrQiXBcoDVAVUB2oDcvw9+7789/dm+8gD//7IAr0Ofg2HDMER" +
  b"LRNJD+cMmxJADeACaAdYBGj61Ps8ADf8tvcZ/vP/v/rw/dAAPP3q+839PPkF9GD1mPO57UbnfuW85orh7eBZ5x3phewh9ND4jvzBAaoHBgmlCA0NhwuzB+YJ" +
  b"QwhXBBEFPgdfBW4FZglLCG8HJAo/CkEJNArPCAQH9AbkBbwEsQKq/WP4wvSK8UjwwvF78d70u/pH/K7/xgY7CK4HiQhoCtQJsgY1CAwHGgOsA6wFlgXJAncH" +
  b"nwj+A1AHVgjdBQIG7gVGBVYCsP8YAN36gvTE9HLvOugV65LoqeRi6rrsreyh8hH50Pop/UoBegNcApEDlwczBZEEmAlHB1EDswWKBrAC+QPxBacEpQRJB4sI" +
  b"ZgcACbcKnggjCF4Jfwe2BQsGMAWBAzkDZwNzAo8BGwLrAaYA8gA0AZoAaAA1AOP/mf8n/2X+T/78/S/9yvz+/HP88vs3/FH8zfsM/H38QPw=",
])

///|
/// `6.7k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_6_7k_fate : Bytes = amrnb_cat([
  b"AAAAAAAAAADb/yQAUP1MBjL34/01+o8MyfL8Cr7ztREF+Ff+SfgRC1rx+gcaC1YA9/Yw+JERWvDk/jz2QQuk+d/+JPNlEqLtovtQCN35lwgKB8/iLwzp56YJ" +
  b"/Rih83MSIv12Be4MH/Tz+8MDj/iuCXL6Ax03AAH4CwfW+RL75/0i/eT9w+ec/DcFQP2UDVHv8w3K//n5qgGaBF75Mvg//sISLfwUBjr73PVsArn2WPuG/WD2" +
  b"thLc/gIDRgRx8iwNqfPG+4gFcwevCEz2tvneCqToqAnw+n/+4A+s/wYIdvCPGoT2jv4SCxvoBgn+FLzffwNcFD7moP9UBBX8TgRmBPoEkOko97AFXvE9GUEO" +
  b"Iu4Q/k0X4vYK8g8EMhX67BX1OAxU8roL4hM78JD/hvvs/m4Cewb79O/67QInC0XqNQj/ChT2hvwjBR3+SQSxDLP4eAA6/Kr/LQL9EYX0SvkM/hcR3+pXBAsL" +
  b"y/pu95v/rvkm/U4Y1fVZ/kT4hwaM+T4S5fjJ9yv8Zwz77w4AgwwTA8P2PQJyANT4NA/S/nL8R/yVBD73LRM+/Jz/OvWqCKfx6/7AChAHyPfb+97/mv1CDsUF" +
  b"Rfts+1QCD/eCEdT/HPlb90YMdft//Y74CwdD/VT/Zv0UBIH6SgClAR8De/4Z+LIGY//z/yT73wYp/osA2PhgBur8dv+R/FcFZvlGAK8AcgTSBv74oP5r/Wf6" +
  b"p/ykAX0BkAOw+OP7z/0QBYQGAPxx+poHc/o//+r9WP3MASH+7wCUAiD+pftfBFL52AfK/Pf72v/FAp0DwP+Y+sMH3wLS/B7/xwPHBJQBiPsQB0UChflpA976" +
  b"YQfLAOv+NgeDAfb2rgO6+5cGrPpXAFMF8fxV+sf9Qv+EAjEAL/oE/mf8n/swBHr/M//5/Dj9BwPq+5cBeADg+ekD0/0o/wj8R/t1BKsA0AEC9q/0fxfa8V34" +
  b"Pf5UCdcS/e/t/QkG8gFe8/kOWADV72MMrQfqBGL1OPSEBywLYvY3+DYMmgcW/OT39wSUCXf3iAecCbjxbPwyAt4GQfmP9msUEP0B/gP9Jfv2D4r01gN3D4D0" +
  b"h/omAKf+JAP99BkLzAXN9aH86P7nB23zIAQdCLwCEPpz+rYEGgPm8t0MzgbR+Db3igIiBGr62veoDFsIHvb6+6cEegr08UkE9APOAMT5R/3jAhb8UPSRCYEI" +
  b"uvnb+y/94ggn9pP4Xgw5Arb6v/f6BAgFkfbiBXYFpP4o+WT8dQldAYP3/QYXA1r6PffbAjcFN/lr/6YFvAL5/Nf7LQMBAeAAIATt/8ECGv0oAZMA1f32AJj+" +
  b"7gFh/XIEfP0f/hYB/f4gBGD+HP5o/uwAvP63/w0KKPnE+L3+oARMBGL6MvYG/Xn/OAmhBof+SwCA/eAAHgPZ/Gj/qQc++XYIXvMm+ZwEPPw2AkQApfrSBy76" +
  b"rP0sAQYA3gFrBL72lwJq+ccELgAC/+4GUf6pAa/3JgBoBYL+wgTB+Pr55AVX9JwCYwIB+z0HdAbI/YTzvv9YCLr80PmPA3wDXfsW/XcBIvqdAl4E9PNEBf4A" +
  b"q/XvBBj5B/ZhFE76DfJbAVr8hANq9C0c9QC95RX4gA7oDsYH2fM9BC0RmwZ3C7gACQOxCb/4bQk//X7V1gWeIowAduc1AEYf2Puq9WcNgwMS6TUkkgCPw/sE" +
  b"Pidc5oz0m/ffBHMVkeRzDiXtggHMBq8M8+sTAOcgl/53+XPoshEpCRgBNAM8EwULcALeBrv4iOuM9IrRM/CT9I4Ik/zwEuYIBvyODV/+3w3X7l8HEAPpChsA" +
  b"jvKnCkzzQRVJ9N/2ZfzBDVoEc/Xy+r8BuQgzBAgAiPXs+RYLhgLd90H7TgBFBggD+v1M9Tv+QQxu/CP40Pva/67/mgoZBNj4vvd0CUoFXfyl++j+9AV5Asf/" +
  b"MP/X/xgFVABo/IMCG/1qAYoC7P7G/ioAcATO/UX+SwA+AiQBRgH4/xr6NgI9BIX+s/+A//ICaASe9FYCTRAT9Vv+GfftBwoMJ/dQ8eIRQgh66DsAUQDfD+kE" +
  b"a+3bF4ALrRE32eAED+DoGszUBv8PBMspQx6I8VILLvM4E8PLxwNk6aomofM6/q4QOPxTHETO8hbX5zse6dkpEZP6JQwbE+fjXx7w778RPtJfGXntMhOk/YYC" +
  b"KA899GMPfOGpGe7dyxbE42MZAfKHECX3jQUzDrv2Xwky6T4UceLkGK7mDxZS6Z4b1fiZBiLy5f9GEFjo3Co18hP+2eCgIVAEMhQUvcclZPsq/271TwAl8PwY" +
  b"s++mGzzVdQdy5Tcpi+MQ8+XwaCZx9KAE2OY5EcQFYf1zDf3/tv+M/E0JywNq+yPqpCNh80z+ueqpEebyJAVS8TsYD+CCB1jvbBWb8uoBQv7aDwbulQAJ9UML" +
  b"xujjB98BpwRo7pv/IwhyC1zwaw7v79AIEwNNAZsArPkIA+IMOwUu6un/1wIvF37tuP2EA8wXcvpT/0LyLBKK7QoiJ/ZO7w3/wwjeDZLxC/SxCm4IGAgm8dP3" +
  b"5//uB68IWwOF9Cz2NQulB9X5IP0GBBQFugpS9Sj+Tf2yApQFce8gCbD9i/+YD2XogQs/+ab7xxGW/zvySwV68wsQ3wE28KUEhABg+6gLdvkH+IsFvPe3Dzb1" +
  b"kPDvEVf8aALp+cPzcgnkBqH8EQk+7H0CVhA59osLIfZc/SwQIudoDYb4nO0+GgnshhZt+GXidBPEBU38fQV24wIdNPpP+68JYufmCxABC/5wETXkwg5QClL5" +
  b"JwaW6DQKNAuX85sBYfiq/bESTe+iC1f3zfPWD3gBbPwf+o36Cg4qBRz2egPs+1AIIQYRA4TyoP+hARMFFgFd+Tv88gxn+RkDpv8I99IIyQCN/bEG7O5sEoQN" +
  b"Ee1w7AIXPhNk8OMBNvR5CcvrvxWK5CEYygdY+Db4kgoa7OYPlhOW45/77/bwHQj19fV0CS75v/vL/lzllBIjE1L46Pm9+tz6KgwRCZD/VejCAtkf7dttC34E" +
  b"9PpYCOvzM+z2Bx0F8AgO8q3/SwBgAK0Vs/+49+L7rAgNA9z1+wseCIjv3wKc8M4DPhXk/Qf4PwC+/nMADQWAAk37LfpJDP3xVwFHE4rz2AYn8kIAmAWmAusA" +
  b"4vLCDHb4rfi9D3b6lABv+ckAP/5FA84ER/ru+QILlfKpB1IMN+71AWcG0fop9iEOYAPs81X9I/os9aEVNQlg6uEG1gPY/ekMefkUAqj75gLbBmryEgERBsP7" +
  b"jQbM9nIA7gWC/LL7GAOMA6b9bgBI+44HnARcAWH/IP46+U0HxANc+9AAQgGaAZf/Cv1vBFHvOwo9+s0CKvkk+7wKrAj28W0EKQHwEBsA+/aiAT8EQQJtBrb6" +
  b"RAA5BJn0LwRn+AEAYgRY9SP/sv8uBt/+YPqwAXnyZBce+gcMqwWlAMcBxgB6AS32dvqR+koJZ/0NBwQBtPbS8zUAlALV/vT8VvHBAG4I9f7c9jvyEAPwDakA" +
  b"Mv6jDFYCLv1rAZUCI/B9AF8BjfzaAk79EhAHARMBLv0nD7v6HAQp9ykHMfvs/wYBd/Y0/hkMg/52+ND3eAH3E6XuAvoYENkEefrb8+D5QxX27ZQEGQMc9V39" +
  b"VwY7EAPp1fk9GVwIQfOU7tD63x6IAlv0Agno+ykJZPSy+Qr/m/VOD5/6ae3q/8P1xBIQAsDyVAYnCVf7R/uq9r8GcPpA+B8C9/pO/ggCVAQUB5/uwBBZAkYC" +
  b"/vZbAC4KUvVi/FQMvQCg/974fQRoA1/0rwnuAgL9Bf7L/50DZwJm+UkY2fwJ/xj+JPzqEgvzAv20A5r40QRA+Az8dA1C+dIKCgDc+qECmf4m/P/+zfb/A3D/" +
  b"rfzN/R0A4gZM/Jf9Sgbn/tsDVvWmAbQCMAcd+NkEUP7cCTYDF/tiACD4zwl3BGj+JfHaAfYGHgfF81v+0g3RCowCmvlC/rkJHwvA8w31eAP2Bmj/9QF8/GED" +
  b"wPsg/3f9K/vcBXYAiQFa/ckHown69fb+3fyKBCEEkvsjANcGJf0xBNsAbvSCFsb3MQuYBdYFkAquB9b7C/UV+8QFWvAiASf6DREoEw0CTgRTDPnzYRWvBOno" +
  b"xgNW++wCXPJEA+ALQf8X/2wHjvgXFlH+UxIa85v+e/WuCs3+9QIY8+f5UPr+8n310PgU/gL7NQVF/g786vchE5z8GQj7/d8EbvWvG3kHnARy/93uTv0N9dYE" +
  b"4exG933/Jw2PAd4PPQpcAXkFCBFi/J8d9fk69nIDhQQpA1/3pPaD/QsFZvkI/RnwNQxeDD8G9vVZ9Dj1gASbEHYJ1evwCRr9AATeAzH//fqWBo73vP/q8Y/1" +
  b"kwiU+vEIgQZd/PQB4AVzB4IB8PlSAi/sXgWn/qTurfl+E/8AB/Nl/R0P4wSN/QIIV/Kk/vr/oRNt7qv5MgTfAmf+hQtv9Bb9pgbG/TH8Gvim/Z7xvvnc/qz+" +
  b"9+VQEU8I7QWnAgsA9Qb2A4MBDgdX7QcJEgEX/On+3wHF+d3+GQRXAGz7bfuJBpUA1wL5AO34uAHeCfADLwSI9xsMIgGhAfbyp/v59zUCm/wd++L0G/4y/8kL" +
  b"Tvzr/7T+iQSXDHD8twIN9bf/igsyBkLlgP739LEUBf1E//sLo/YZ/KgBagEt/vX7jv3nBRz/+AI4/WYXTwB1BEv9MRK+9r0A7PcO/AUCDANA/Rv/2wBN9bkH" +
  b"RgW3AyABlwENCQr7OPn/AF/0uAFEBdH7UfwbClv3KgAk+bIC4APp+fYB5APy8i39ogmk/Z/4zgp2BcwBRwex+MgDqPflC3T5O/tf/dgBPv/FB0n9hf/wAMf8" +
  b"GP8pA+D5YfhF/iX+YgMnCnHkNv7v8zwKHA5R8QfZnQgCIG/1NvDD68/77CVMGVPsxPZW+qEUUBybDL3i0BT9D7T+J+CW+qEPhwloDDrp3wBmGscXmePhB7UR" +
  b"yRJa7gDwKvhHDawT4uyNBNH7+ApF+LUXWtcNH/cVHR34+ez5+/5HFEgPwfVP/loC6hFFBZPfVvFQG+n+WRKi8Bj4HwKkDVH0wP67AMgZofZW/YgEhgnKE0/w" +
  b"3+/XCBkEVRKJABjxHwQeBz4Hwd+N/MMALhQeD7X7gP4s91XkzQ+B+iQRKgSQ+LsCoQYA/1LyZP1O6wn5tAXUD+gasP7P+1z4mwqSHcEGL//K+0cBJxWpCR0A" +
  b"J/Ay+KAXVwDr+zD0bf18CdMQY/8r6aENkgWMCIoALfGiD5T5kQQPBLfwHAAm9y0Naw6y6+r4nADPBwQRQvmt9bT0qQjrCKsLePJp894KFAq3Cfn6AOZd/2sC" +
  b"Vw+6BSzsegNd8u8GGQVj+rf8pfVLAqcUPAPRAKrxIACUCFYIeAGx6RP/4/3ICUIHv/R4ADb4eQqaD6P+pfwT5ywL8wGRC2AEWPZW/wLu2w6PBkwBNAQu5bwJ" +
  b"5/XACUMI7esF/cTtYhBhBYEF7PoZ9ZIC3P3ZB1v/vu8jA9L8qgQOABX0YQYt/L3+e/63890CmALp/swa1NNv/MAXse0CH/zgDQAtDj37nxKaA5YLyftZ44wB" +
  b"DxcgBgDzuPxM7KUWywy/9VAGNNkkBK0MKhAsEajXbfyYEqcIYgVB6CwB0AFYEIAIX/ByBpD+ogR+/aL2eQ949GID8P7Y+Y0a0/wo+nH5JAz0+okEuQRI6iQG" +
  b"EAdCBGTzLvjWB/gCdQWTA7r0/wTVDr/6wPkUABb85wrqBBvy6v4IBOoImfii7koLov1YBSD+tfAiBsIOpPcm/JTxSgRvCzf8YQLg8OIGCRHW+0/04f53A4MJ" +
  b"zPx1+Cr5eQquDdr8pOxBBJYBPgm6BdruYgJaCmIFof5E9fAF5gUu/n4AvP6hA+/5kgF3/moBtvqX/zgAowFk/0wD5P7IA8X4qgEQ+wMG+/6fAKUFvPbJ/YIP" +
  b"UOtQEKX1svlGCuvxlAvX9qgDewB6Azj+evuaBSD+Wv9v/gn5wA+N9UsCbgQS/zUH+/IkCmj5WgFOAmn6ZAoBAMACHPY8AdAL0fMWDHvywgGPBcX6nQal9YIE" +
  b"RALvAQL9W/QfDWf4EAOA+gf5EhD2+gwFpvah/msH4QBJA0j3LQK+BW78KQF7+U8H7/9xAWf5BPzRCS/7uQFJ+Q4DHQQ5BrT/BAN6ALYIK/6j/L8JUgyu+XgG" +
  b"Mfr79CkJtfN3Azbu9gVhCQ8HeAEdEL/hsxM3DY3xQf9X9yj7XBQd/9TyWe7+Cmj9hgBxCjryIBPl9bsNieuHCTYRC+YSCoEAofhbFJT1JxIb3f8Hpw+z+58N" +
  b"mNuIBeUInAMf9473MAeV/nAF5QqxAYUPd9ckB+0AWwlhDW7bjAtBAhT68Qrx8OsEtgDAAxMDT/ptDoLWQwqYBmgOlQTM6FEPS/ynBJwD0vLoEaHfhAs6B/YE" +
  b"2A5m5/AMgPaxCYb6M/zUBfLoNxua+ef3KAsx7XUT+gAMB/n9POpKEyD02g7tAaT2UQCZ+UQPTvZiCRUCsejUGenq5RfN8wr80g164vUX4fZhBlUFyPR4BArz" +
  b"MBJt+Ej9UAFc7BYa/ezOEBT5QPKsFCndxxKgAO4BKxDeAtkAmvboBuT1UBf7AbzoTgUPCo4If/1R8B8PSuICAwEUk/nLDD/awP+nIfD4+g1a+LcB8+8f/aAO" +
  b"/P7D+qXdJA1BFTcDJvsK9jsLGdvsC78OhwEmAcTcTw1VGh/0sAnj9JYM6gSzCSMNcfp5AEDcCw25C54DawvR2WwLUxny/YYEaAFNCtHmfA7eCe/9jP0c5o8H" +
  b"0QcaCO8D++h6CWITbv4WBzUJbP/LAcYNrAFe9nL0eAHwFSH9j/yvBinvMQ3P5Nr4IQihBuod9d0DzRYgnjilAjLkfvS+HJH+xBfcBRbb4dtmGF0Jo+4z+Q7r" +
  b"8xv5//Lnx/W19T8otPr4+WEEzvUzE6kIr/YyCNfrEg0+BML1BxF07wAFnQ2267wbX/yY8JP4MwMoD7oEk/+3990AYxa3A6LzyeTHD8QKigXbCDPkrwNJBP4O" +
  b"+t2BAj4NIQwVAN77YO5p/kwZw+6m8yz6yhDyCzj8BfWB7dcRvwlQ+v7fFBFL/psQZAM25uwGowuLBNLtWvjGC5P+qwFsBaPwIQi4CzwBne5DA5IATQXPCpH2" +
  b"xvFoD3URvfFn9OsCbACABQ4Atvb+BJACeP6/+YUCvwFHA6cBk/s7//cDjgP7+fv8wAOwAOYA2wHq+hcFhADR/fEDJwNp+mcFCQId+20D+gLI9kUKTPvx/OQJ" +
  b"jPX1CR38dPWKDOX7ZP91E6XuOgI1APH58RHK9aYBDQD/+qQLnvZsCR8JqfZKBLb35AD3Dvv1yPye9oMHLg5v584DGv42GdUFL9FnEbMAVwSpEHXg2AImAIYD" +
  b"IwT75okKJP9p/lEKJ+mTEn38f+9/DpEJhwrJ7DX21BGfCn4KNOTA+20OvAjpCGDtggH7EYYFdwnQ/Sz2fgVz7SAJQAMXBNAEyv4TAOICl+6oA8YFLu1mA/wG" +
  b"tf3GCEX92QSiBx/ycPJCADoG7AkA+ZPv5giABa/5jxLh2uIMVw/v4TQTVfSP9D8ZFvzQ8+DzgACVIoX6vudi/uIE8g+S/D/7XekWA5cFwRG/+lnnEQWxAmgK" +
  b"Agat7IoGCwaZ/w==",
])

///|
test "amrnb 6.7k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_6_7k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_6_7k_cref_head),
    2,
    amrnb_ref(amrnb_6_7k_cref_tail),
    2,
    amrnb_ref(amrnb_6_7k_fate),
    16,
    2,
    "6.7k",
  )
}

///|
/// `7.4k`: 5686 bytes, 284 frames
let amrnb_7_4k_file : Bytes = amrnb_cat([
  b"IyFBTVIKJDyIhS7u5Yizhqm+NRh2fgQ2QmAklmzq0d5xwrwFyHkXYM/lTY4NECSRGbVNP3z47NQI+NEMEhWZXcuQJNYY/E7/+8XHtzoM+8AdeMHN6HAkVRiu" +
  b"cP/5wP8lZR8ayCVTXGHbUCSWGLYlv/nEf6RmLL5D4hnD5jCQJJYYjiC/+cR3X7+Q0TMQiA/pO7AkloOuEp/7xH+qAT6uWU2xQW7fECQ8GK/EP+XCX5avZpTG" +
  b"LpupLJ7QJE4Y/oD/+cA/CL4ytj9RhEEYbcAkjlfcUL/4SXqrlJvd0mBYEdWmQCTz5nlwvvq49DJWxfPWtcMqBlgwJPgqOaF+4/D+HLxZDsLuZupbRcAk8xDa" +
  b"8t04/PxRKTkNnqY6QEdrECSRhfxlO+fD9J+fqe3LfgvBonUwJPMQ26bfsv+kGBIsRmvP76J8rVAkjvB5If/Hx2yQuGu4BQxNOHVToCTzQdr4vyS+HNIewBg+" +
  b"O6dpjaiAJNke+GhfOB/Tgz1rA788FEEsTlAkkSnKiL9PIkhbdN0OIgGV/AZCcCTzNHhqXl4YY544smrgucBQuQQQJJFsv01/EySo8bofTlu76dUPbNAk5x74" +
  b"Y1y6ulxL9yTKP3aGYGfZ8CSRQh/tN6Yfg5SbLW4o7tRym1YAJPNCSqTtriRCm+gfJSOVT9BGNLAklurqh/y3wjxsV9l3AUCmkmx9UCT4/soV3vi8T3rSVeKS" +
  b"igjny7uAJKBsKYjfeZ1tJMF+Dsglw5kjFDAkPF9/nL94uE9ATJc01hIp4RMC8CQ8bAGKfzi4t+6bFchhCOxFVr3gJDxff5j3uZhVNyXvIWZfHYTDKSAkPP6j" +
  b"L514FS7z3kQEYGfe35cWUCQ8Yfc4XvmZSWQVaiRhD6hckUoQJDxfNj8PmQlWdcaOJfmDsfKq3AAkjv6jL544SVj42Z3Fe+hnccEy8CTzou7X79kOf4hAqkKi" +
  b"cPy8AXbwJPP+zkU/s3qJRUIGyhBYClNWv/Ak8192TJP6Fv5N7sbK6BGsB/WB4CSRX32iv7LgMdKy3xmthoyAUauAJJHwdjg/VE04KmhjZGRMtl2aGlAk+P7+" +
  b"wT/wekRudcc0pngqKmwA0CSRou5h/+9+Efhc99mOWazv8F0AJPjAfmDfaLQPP7KxdXqgoH68iWAkkWv+eX9IhBQwXBlyiYY2AhCssCT4X3siX5n0/p6Z3/26" +
  b"KIqZTD5wJI5r/sCey37JjiPncsL5tuqR4mAk82x+bVtJmvmTW1UXjoiV/EgrYCSOa92IP0uZus3eqUNVCnnVOEKwJEK49iCe051SxaZdOB6eHMwplFAklkG8" +
  b"o/7TmEWoO70neswDcgOk0CSREO9Kf9OwRBKW3ZPlSD31R3lAJJYZ54H/h5g9KzQiYlceMxhUwtAkkUHm4R/RfKS/i3GSQlhhJP6NQCRO8DI0H7n9HuqzcK0H" +
  b"7HXNkMKAJIdr/yLf25mK3LsQAS/mW5b3v2AkEGvnyf8qEj6KYy4MCeiGHuCnICQQEJlB/+i8x5PMnIdJj7MUqOsAJNlfSOJ/4L5XVeM54+QRT8VIAXAkj0IS" +
  b"4z+uW7xy1pCHyWP1RNHRUCTzuKikf6fP+C5Ipk1qI1wXrjBgJHjq5du//dNLi22iMJqHGGrxoLAklmv4bX/yre3p4uqaz0iaBtZWgCR4X13Z//haGEOu6unj" +
  b"BBYcTEzwJKDATON//AF0DirLzuuHzn20O2AkAdYRyZ/4TXqrSPqHI5moM9Y+gCQdwlJDX+mpZ2+d2UVe2Be4T2uwJNPD/kh/7NHg21wx2Xp9MAqop7Ak86Lo" +
  b"kJ/+H4zOfNzb8Ws3kbtNcCT4sOghf/+up2zFFORoRqUG9gHQJJFfZnE+2Ulf3ded+O4JFoWBMAAk+Cbpgd9yTEL3R1VefwMQV4OfACT4hegY1/wbLDB9jPeo" +
  b"64apst6gJJZfeCR/hkmM312hkhWTLGY31XAkPPA3R9+aSpIB1heorVOn6K1dYCTzYYKlP7uXI+tNg0UWc1J9VplAJJFCWi5/Kv9eoJ67Wmi42Rk2VQAk1NP1" +
  b"j1548mT9MNPz8m9OoEXQoCSV5WHcP1mZrmU5IlzbTt0wzTcQJLXT4el+uXhRDHbmQYUCCOxwacAk5xDD2zzsegxPX9Gm8QY0C4MocCS1fMMnu9hVH4NvbW48" +
  b"butIQKaAJOcehmF/WU8hi/uxzYp//OuXEMAk5/BDeF7te8ERTt0hnahNxnV3ICTzJwbjv+wbFMZnVe/mHvueuKMQJLWF4ITdtCX6vbg60lij40+RU+Ak53wk" +
  b"Wf/nFtMlqiYO9rLTfcASECSVXzVwnvXI8auq+gBECNgIWQIwJPOItVL/zK4KH6gbwcWJ3x3vxQAk02xgFD/sSoJeuSvDE1obKgImsCTnEGoiH+NWwXxhnv7i" +
  b"z5N9+IEwJNOitVD/WZerXlTOfCQGfuSaGNAktUJoZv+De25x6sgspAmp0hhHUCTnEB/gv5ri2TUvr/gp+6GmaLMQJPMQ8PC/QZ3mdoSExoOBNQsVm6Ak80Bt" +
  b"h/8YFWTxmisZj7TbN8V7cCSRF2K0ns6qyjhAZSRHQcstcOhQJEgQp+FdrQ7ff9POFaUBe6b4RIAkkSZtR79e5yk/GkX0wmF5mtCmQCTZ6vhJv2WZ/SadBZbi" +
  b"djKAAXwQJPPP+mA/5kz6cFdZeQLMM81Ym5Ak8xRvcB7mJ3JS2/ViqTCeUdC+8CTnHmfB3+/GjFuVncvo6PgOV9ogJOcyR6Pec9dq3JOYm/j4scKbFbAkkRRn" +
  b"9Xr9OTdbZY9uUOgpbTpKwCTz8HgBX+/SivyXua3DXjsJr00gJJHq7UIf/4uDX0WUXWtFwaGrkHAk2WxnLV4/kWuY13WkZhUYtkhCMCTzYfLG/7sJLxhXmZwS" +
  b"55J4irwgJNmiwpMe9OeZK2O0nbQBLm4lMOAk82w4YX/jD9/8VBwEPdZSsw0KECTz8GryH/K6N2m1Y+dPDl/srdoQJPNfcqef+OLJcloNyAzT88YN8IAkVPA6" +
  b"oL9u5DmuYqoyCZXptsYjwCTzEOxEXr+f5T6KzcD20fCVdFjwJOeivutff3nXxRTEB2Kr6/fkyDAk52vnxB6xyfmc82pJBCg0xxTb8CRUD7KhH/DhMRbFV9is" +
  b"C8SJH1KAJFTTrdGa/Xm2ryGGL6UyNGrFIRAk04etxXvbJFiXnZi5TDPAkSl6ACTzQfmjH/ciAG7Vd7cRWauH3UHAJFRyuiq8eXgvtyEsmGlOR1VEwxAkj4Gy" +
  b"votsuJxKVQ309gXiBfaTUCSWKZgI3nmIFXhX2GxF0qTS2DkQJE7q/nRfu8DcR3mFi8iHhKsl2rAkjxQpgX/zm7pYm5+Pa9guhL0G8CROYeZS3vr1ZKtaCWQ1" +
  b"qX7TjsGgJNZhgYR/9uT5+VYUL7E72AZ6SQAkAFeM6X/59/3BdhH5GyE34bIi8CSWz9ukv/hFeFZeDJfGxnyRsyMwJCPmKYJf+fFuzvXxy+KWij2dtjAkI1Fp" +
  b"gd/zm/lQEdaPT8hEgai7gCSOz/OAf+339qprw/6tiXPqlNjQJI4nGiqfx5oa3drMIGpXkn5Y9TAkkUJe8l95m3KPiaaZ0sgQE1nu0CT4bG3EH+3zrodvTtiF" +
  b"DtuGr3qwJJFs4qPf53jkgq1OL+gSuNxAJIAkjmy6ID/n9d3/ZQwxWOGNpr3/4CSOFG/Z3mUPTn/enXAedQx5hVcwJNkRfEC/8/J19TYwg3BIbqZZwHAkjhj+" +
  b"Y5+nmzEST8fi3Hmw+Y7sgCSPFHs0X7n0NbT+26u/oHbpOkjQJI9sduw/8/DGJLuiz/rkw2KLRWAk2Wz+YP978FXMZGpUYe0hmoy2wCQ8Ql7pP62bOrCei/WZ" +
  b"K4pMBLOQJI4XOAA/5Z3SvTuiUEfTy6eGT/Akj2xigd/38CWhpMvNvobMzXEzcCQ8aFv43++zRELBS4dB7BnzfBSwJI5sZt0++X/vbKiqJN4HzEuaGxAkTmw3" +
  b"5B/5JUg/O2+WZviRn4vqECROJl7h/vgZU+368JGLfyoFuruAJJZCVHyf5uLZF1B5uApwqO4KmMAkAM/rML/sRzgXWqYRfhCidCsMgCQ8QlJp/2f3/oNNeS4L" +
  b"MPET/uXAJKAKQwF/+xh7dxwNmomFu+qH98AkoM+HMH/j8d2HcxlnIwcFaE6LwCQ8FDkrn+cb2yJxijM0iic8Mx5wJJYUemHf8SH4Wsp080FUfrePrFAkoEJw" +
  b"yB/xGXveqsz2zNwH+AKggCQ8EHDJn/l53Lno2e6fvoeUhz+QJDwUcNg/+Rjbajk6yCMA98wo+qAkPBBx0F/sCjkFj6kqEyPjD0goMCSPQnDg3+YPeuA3iIU1" +
  b"gei1iBpwJDxCcMD/8CB6CNFrpI1cTKTUL+AkPM/w0N/uIsr2OPBDMT8gT4BkcCSPbHDMX6iq8lsqI98ztaJoezUAJDyE+GCf7CJ6zIbjrXKwJ+e1vQAkHnLx" +
  b"6F/y91VQSn23ccBHiefuUCSPbPhmvXMb691w8aIrDgKcqE1AJEJs6W1b+QlNU3DZ8XZxM4hYOgAkjxDwZ57R8MXeTFXBYFieaPn3QCSPEPBBvvvx3vwBk/mj" +
  b"OkMVhSWAJNm0+GpfcbMUHJ6hg1mLN8GNxCAkjkHaUb/MHitzcrIzu16YsZ4p8CRCGOuDn7t99IuZg3pAKZOdhjNQJI7P8OBf+BtzQcV0nSEYqRLwg9Akjxj0" +
  b"wB/4qC7On1lq5QmdHUbzYCSPS/BA3/EZwzuVSeDo7E3leZ7gJK1LoYFfv53xEFh322/pz1OBgQAkjgDpMp/MfkQjcR+9HEYxtQ/zsCSOGXk6P/IVEhxU7NCe" +
  b"abmwOBZAJDyB4et/7Tje8hrOIqgxSJbI2/Ak+LThgf/9kGvDw0rz+gg1+VZ7UCT4gfhj3/eX+6yOariJFgPlPB6AJJa06CH/91D5reoiytasSOsRiIAk+PPj" +
  b"2H/gvvzrgAtNYBOeSDiN8CQ8tLhnP/O49wztGqM+lVEFH34QJJbq7EN/7K99zNPlyqPN+dYbaVAklrj4B7/sv2y3FBW1YAZlH208ECSWaGxSf+1TcbWV1aU7" +
  b"PrYE0SWwJDy4+AX/+cRsGtzUaPThMhtzqzAkjzJn41/5xWw8DZnO0lxhqNkqUCSgGDKnv9nBXF95YaRFS5ht6fvwJEKpZ/c/zBIuDt2jcM4kl2DO4HAkPFEn" +
  b"wf/4JUp+dtpYDDvL8l/L4CSQGKfQf9P1XRZhK2/gfGUSLCyAJCXPx6p/7Q5Ha7Mt6lz0YnS9poAkJWxH4f7K8vwlwnFlG1iopSXd8CRHMw1Fv6eYYrKQ3vsn" +
  b"2J6Mo5OQJK2ih/qf850FEsTnG12bnclbzsAkKmzmwf+SJJrHR0baCCwmEcf+0CQlbC9dfq3DRJmoxTDi1CjKMH+wJB4qB4P/eve0bJIdZRPDYZYyLEAkHmyH" +
  b"sF55xGR3TeHVYqX8I71s8CSQKZKw/qji2W54ydQciZdQ6zKwJI7qr2NfeSd4Ed0icL6aHOJIyyAk1BQNGb/0rRqioIegCD8dcqKasCQeFGZlv/mWYyXkYmb5" +
  b"XjwWJyOQJNNrp8H/0rrs5r1hen+0TW4kn7AkjzdnjR9tknNdLWKlwDQfY8TxQCTT76dpn/jh0mFg+phAn6yNvFDAJFRCb4C/2uHaPyhqZXNBeMqRi+Ak84Th" +
  b"5J/zkZOloSo4wKrOkA03gCTzbDMsm38mWKMp7oMatj5b6sUQJPMp5mXa80kx5GZgUhvS2pK3UmAk8yd3Yd+/fncipmr6cTczGIzMkCTzz+eJPqUm5WNnhGOf" +
  b"fjCUa8qQJPMY47ie9k8C2hwFuYAk77w+c+Ak+CnlGZ6RmV5Z19Xq8WIvqCB/ICRSGL3s3x0SK62n4lD9ntMfBzTgJJyF/4L97LpMZ59BpvjbmOcHbEAk8UDH" +
  b"/f89+C68amrCMI6WL3gogCROz6XIP+i5NLiEqo3kc+4c/zQQJJy4r1gf/EgQjXnsX419w/ste9AkkYWnwj/WInKKin7O8wxLdWpe0CSRGSdiP9zz3IbjE43B" +
  b"JJdUoxdgJJFB5yA/baOg9qvuEMsMJi44AIAkkc/mY955lWMgCv0VUKqISP0HsCTZQmZl7bi4bDv43L/qtHkldDNQJFU6TPzfuRy7GdXJXLpPcbIJOIAk2Ri5" +
  b"RR/jJbhMdHCK+363d1phsCTzYdio/+5fX1KDFeuFd4FaVauAJI4Kegg//SdYbvYFoPXcOk4iUvAk04eHsZ7TST9eTN/TwUxQtHRZICSPF8bvn1gaax8taqZq" +
  b"ivj8ya3wJI/BB+Pf0hGgT2nj2mWUY+tE+dAkj66H71+YYFhDZ6XsNTj4GJxOMCQ8hIfvf5KozjLHNdvwTtkw3wrgJNkJB+3/OQBIAi8HhhvXVwHDuPAkjxEH" +
  b"7be5IGi2nwBydyQxSpDZcCTnEIf51vKo7tyIaCvchjecKuaQJNkRB/WebXoNzc6jtFqBcLjk9jAk82IH+5a4IDotrLg3IZIlaX8foCTZFwfrN9ggKqeP4yYI" +
  b"yU6c9D6AJPMG5nvechGLsIUJ6qEDU1KsqEAkTuqH6f/teh8610WyFMK9809McCSPz6d2n/j5ZMLVIHX6gIAkCNxgJDxfZn+feP00NRwlVgU20e029PAkraLG" +
  b"/4/y/MRenQpbIcCasoPSQCSgX2Z+nrj9VCyv3VUOjnOtQX8QJFuixvt/2RQLQg1DWLKzEPajG1AkPKKH+1/4GAOYx4eJTCfekC3QACSgoof7f5kQY5bg85wc" +
  b"D28qYc1QJAPqh/X/+cBktagDiZZaKSq48tAk02zZAH/nzznHK6ojH7pzepTtwCSOa+affveQ85gsaPKmvl/MgOVgJDyi5na/+L3kobbyuCJAuezZ4xAkjmvn" +
  b"lr/5SFeiQTN8jE8D2kbWECQ88+eWv/nQEh34V545ZFaaZHJwJNNr55afs32pchWxJ2uO1zwF/wAktSdnhB90vf8WsnUIDTORn2ceACS1iOYD7fOsb1OYlauM" +
  b"+Jjm/69AJOcnYeYf9NbAc3aRGfdSGqbHCmAktZxjAH+0krJVFrVdfcGgCTukkCTzuOTmX7ZKsnNx0DKrbgLYaRNgJPM3ZUTPyh7MW5b1T6Qiyk8YJAAk87ja" +
  b"7H+JSp8flBPYjuLa6uFAgCT4Jk8knzFz/iSyqnJXKwfKmm7wJI+0pUFesovkr7hoJkjHmbrdhrAkkerY5vpLfG+Owp8hd5taxBKXsCTngZlmW81MF6+WKrmL" +
  b"1iREaYeQJNmi2AxfLdCie9rcqjeTWPsemgAkVPPvZ3/avgRPUzfaWSDLg5Eg4CRC3GftvnMnoLyx+kDnVncHkYUQJI9Bh+ufUgX5R7qqpqlxKAlXlOAkQu/H" +
  b"tp9ZiDscRjV+no1VhiWVkCRCQYf3vLnVOh1WxSCQtnQPd7bQJDwUB/f+mf1W4IqoW78BWQ0t8wAkjxCNQf+Zj8ulq7LhReQTAMEEoCSPixh/PznLUTDZISBI" +
  b"efBIG37gJPNCcJnffiQq3tVBomJ045q2JMAk82G5DN8jx/xd1dFeDmi5RTj5QCTzdfImftjlkU2X3EdQz5BFLGAgJJUeZyY+xxfb15MeNxEKvsxCPEAk58Xm" +
  b"wRzQGGXVP5GgPwGLKd/RYA==",
])

///|
/// `7.4k`: the C decoder's first 16 frames, s16le.
let amrnb_7_4k_cref_head : Bytes = amrnb_cat([
  b"AAAAAAEAAQAAAP///////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAQD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALv/q/8GACAA" +
  b"EgAkACMAEQD6//P/BwAIAAMACAADAP7/+//7/0gAWwD+/+X/8f/d/93/7v8IAA8A+v/5//3/sv+n/wYA3f/B/ykAQAAgAAYAVwDEAFMA+v92/S78tP6X/20C" +
  b"/wSRBTUIewWS/wT+F/0t/Ev8n/3i/6L/a/7t/l3/Pf9S/+z97P3W//3/GwLHAwAECAb1A7L/Rv4+/cv80/yq/QYIqQx5BpYFtARD/2LvFefz8Yz1t/fJAQoK" +
  b"ww9XCgEDrQMHAFv0YfHo+f0EZQeUBaQJzAid//nwbOw/9Xf3lfvOBi0Okwlh/wH+If7q8c7uWvoGAQ0DsgReBzQI/wI0AGgCdgsFD+oJ7RKsGAYPBBGbFOsO" +
  b"2Adl/7r8Dvm28gfysPbaAgsEZPzy/DX8pvG432TfJO6P8qn4ggOcCxIOggZxAdcAyP3t/iQD5wPuA4gFOganAaH80/v/+3X3R/KK7zzw0fUF+tn9qwCM/p/4" +
  b"wO+Q6rzsh/Q//jQGgwxzDzANQAnDBpAFDAt+Es0Qvw6KDvgOmw4dA/T7nf8f/8D+9/51/zoHEgi4Aez/pv4E/iv3qPEu+ZH9ZP+qAvQC+wXBBBr/B/+p/qn6" +
  b"5/i1+1ED4QY4BAn/Avdj9KTxSe8y+Oj/+QHgAxUD3gDK+2T56P1yATsFnQjHDRgR8grpBJ8DyASYCjcNnQ05DREJpQfPA3P98/aI8n/2tPn/8wPyPfh8/TP9" +
  b"/frl+4H+WPzz91b4Nvcq90b8s/9NAnIDnQK0Aij/HwGrBvAGZQmYCYQE0f0y+H334/Yu+Tn/LgDg/7YFTAf5AM/9Yf+sAFUBDgIsBh0KuQdCBEsCIgdnDZUL" +
  b"Uw0UDQgI6wZIAhkFSAolBrUCIfZb7YvwMuwI6Wzth/RQ+VP2p/bj+ML2r/Ws9gz5lvjS+Z3/tP0X/Kn/5ABOARoC/AfcC/YJVQtGCqgEUQCZ+eb26Pn49/j2" +
  b"2Pke/B79ivqv++b+Gv9UAhcFnAjSDAkMERDPElwVvxo3GPwXZxSHDbAN+AiIC6MPIgluBC/21Ot67SnoduYF6tbuC/IL7oXv0PC47q7zV/Yk+HL7cPqr++/9" +
  b"n/0n/tAF2AwOC4AKpgjgBNkEMAawCLYHNgW2AKj3svbE9e7wiPSb96n9ogAF/fT/Lv+p/mECxgRAC04G0AaTD70JbQgNDY4Nawx5CZoKzQeeAkYEngR0A3IC" +
  b"6/9c+172FPen99v0JvFi9kD9dPoJ+83+0/0h/Bn9IgDz/qf+7ALPBu8HmgZoBhsFNwJBBC8BkvtY/iEAw/by7hjvdunX52PwFvEt8f/3vv3p/4T/FgX6CRsJ" +
  b"uAyXD2oR/RHXESwXGxfgF6kZhRN4D1YIAP3Q9+3+jgtCCZQCOP3t7FzkpesB8eHrrepL7rDyLvsSALYBVwWQCOEJuQh9BnkFMwT3Au4E6QUDA1YInAhd/lb7" +
  b"RPvl9ovu/PM6AmgHbAofAO3yefPF9Hr3a/n4+icAIgraED4JEAA6AYEFkARa9vjtXfN/+MP8Wvkw9j3+Wf7P8trvA/H44wjjKfVI+1T9vwe4D6gN5AhYDjMQ" +
  b"GgrKC7gPXQ+CDAUPwh5BJIccVhauAmzyE/bQ/Gf8h/Mm9Yf+G/aS687wrOxd3avlS/jp7y3qqv39EzAXUxDfB7bxiOnV/twNhQ5zDVMWeyV/IkgbgxJp+3T0" +
  b"iv6+AuL8ufRK+1MBmwlbElYFzPJF6IbtVPhE7wXspviJBYAORAlb+fXVN8fO6+cGCgojDEIPzBZ7Fc8UQxPbAM798wlXCtADQv3DEBUh6xfmEKoDh/AL92gK" +
  b"JAzo/m//+wZ6+8DzQPuQ/U0FaQfH+YPxVvKf+Nr3kfLgBGACf+Om5PrwqujQ5oT0vPsD9Y/30gOY/9D5UQ8nHaMNPgMLB2MHoQJsB9UVSBTQDYcQ2wpt/oP3" +
  b"c/pE/1L9EPua967mAt/I6ivzgfW08Pjc0tgk6dnyDvhmAaAOUxDZBBn79fOM+qwN1SQ9LDwXQw2XFtAWWxRvD2ATbBp6DxkSnxZTA4kB1Q8wDC3+pOzl6Jjx" +
  b"LvaMAlgHUv6H/R7+QPFO5A7rOvta/kr6r/n57sPhjOoE+dP6b/iD7djiSerq9dIGdxM+EDgMHQZe/gf67foiBGsZUi3+IqEJCQVHCkELSgrgCBQNHQqQBCAM" +
  b"KAj9+oD/ywU6AUHrddcH5LD0X/vgAncAdfpZ+zX9ufb67vr2mQJ/DhoWkRX7C0n69PanD5wcTg6b+Mrn++u5A0YVohE5AmD85ACl+Ejo795j4f7wBv3F/av1" +
  b"budI6K31xvui/pj3auqR+c8LzQ1HFK0Tlw15CYsE2QCl+qT7SQ+rJeQjLw5fAlsDDASf/JX1fvyhA+UCTwa5/CLsI/MtArEFlvpv6snjyudV93MG4QU7AS0C" +
  b"DAS5ACr8vP8TAy8JXBRkDboA3f7c/iQJ4BUWEgAEEPu5/jQEFgG+/Cj8ageMEjAKB/y682XysgNUEq4Akuwn8eT8Xv/F/Fr97foB+QEDPAYN8gHnP/TcAP4E" +
  b"HgYuAwP9qfu9A34GBP2k+jYHCQ4qBs/+TQotE/cQpiB+HU39B/XI/lcATPoi+fzuJt2N6psAVvSg5vPwv/wP8AHm4/ZH/n36xwRaCpT/jfqLCUsTLAZq/9cH" +
  b"ygfECxgbthEd+Yf3vRIoIc4PYQQ+ArT68fzRBCQCvve09kIC1fSN4FDek+Sy9T4E9gxtC/D8U/28BMwBVAHyAS79kPn//ksGNAFT+3cAVAM//Yj6jfCm5kfz" +
  b"Mg11GPcLBQIgB9kICg8cFugN5wOEB7ASbg1r/Nb7FAomEWgLAwT79GPo2/IsAHT/W/nm+dn+9/Tw6g7qcupR9gAEfwqSCFn/dv+mC5YQ4QmrAsgA5gToCmcV" +
  b"vBQRBK8EhA7nB2T+EPJ06T/wOPnY/5bvn9/X7+n1N/tFBKLtQ+Ik9AkH3wwkACf+cwy1D/UNiwrsAUECTAqHE6kPUQEjB08RNgnLAoL84fGm8nz7DANY99Xk" +
  b"MPDJ+vn7oghK/T3n+ON776ECvAKH/K4FuP5C9oECnv168uL74wy9E9MIcAh3E8ELRxHBG3AFvfVU/XEHXghCAhwFJAND+zYEZQrFAGP62QZxE/oIzP4sAYD7" +
  b"h/b+/YYLigsq/YcFaAcC8T/x5vsv+f71q/nxAO37Hff4ANsBC/uR/Mn+x/y7+pj+ZAPlACgCSw9xEP4BX/qR+4X8wPsM9l7xE/Mc+W0AnvPg5s3zyvnQ+a78" +
  b"b+0m3h3pWQM9DmMBYf3ICmgPlQ2hDs0IFwGwBeUUaRVWBR4Pxx7jD8wFlQwLCfT8yPqGCp0M1vvK+tL/0/pW+2v/Cvnt8LD1d/4M/Mn11vMI8pP8egtwCO31" +
  b"H+4W/IsF4AG4AKb+LPtyAHMK8gh5/24D0RH9EacJQAepAZH7nAGYDJ8IDvqf+Jn+bf33+ib6lP0j/7L84vhB8pXv5PVS/18CQfwP9t34cf/EARL7Y/S295f9" +
  b"BQJTBG0B1v/nBLsLsAv0BRwChv+V/j0C5wP8///8m/6VAQkCRANlBeoFYQxFEQYJCv2I8PrtNv4qAmT3pvX0+UP+a/YG8Jr42PUy8jL5t/B94RHnlPz+DgYP" +
  b"xgoEGZkgYBcAE2kYrR0UFO4KsQw1Bn3+lf6XAEoDBghtAuz0C/Mk+vv70/VE8mTtRef/7nf5C/a37uL27AdfCuoAkvuY/SYBzgN2/YjzwfVO/3gGGgctBEUH" +
  b"AAoNCVcJ6wZb+9jzBQQ9En4I0v0N/Vb9XwXgEHwOxAAX+pMA9gT1AHH8+fg++Hz8gAGDAUX9Pf2XAn0FiQQgAzwB4v7o/lL6U/TI9hn7nfxc/Rf+hf/xAHYD" +
  b"gQcuCq0IvwSQ/2H3jviOA5gCLPs9+zL+T/019xT4e/z68tzubPYG88Lt4vRxAeAEB/9zAOIKsw4HDboOUhNNFFUVRxinEqwISQzqFsQXZg/nDaIOCgTJ/BQC" +
  b"dwQE/KP1CPcs9U/wPvHT83r0H/kY8xHmWulV84323fTx8x73d/eT+Rj/QfyZ9+f8SAUzBuf/rfxH/z4BfQPIBd4AwfwKAKYDigMgARECKARMArMB2wJN+fjt" +
  b"kveBByYLeQcwAnX+FwESC0wP3Abo+rX3dP0NAVf/Tfxr+qX79f5GAbMAWf9PAc4EpAU0BUMEXwNsA8cD+QPZAzYDDg1HFjAOQAXcAGT5tvrBAhUAKPfH9Lj4" +
  b"Qfg1+i8CIv8y8Rf3CwTj8W3ite/b+gf5XfaC+PT8yAAGB5sLSgyiD1sUCxUiEaQNLxD0ErYRIw5xC08BHPfd+TgFUwgv/lf4RPmm+J/5c/p68BDr//MU82bs" +
  b"uPB37YTptfAu98r6j/oK/TUCGQE8A3IIRAlJCZsHPwj6/z76QA2iEskQqBQ6DdAMCw7yDDoNiwH0/Br/Gf7MAOP7rff1+E73Ovoc8IDmi+9b8zvzqPRj9Yv2" +
  b"zPbu/d4ChQAHA3gFAwZ2B38HeQgC/Sb40wtDDtL+Kv5eCMULYg3UEVYNrxHmF+oSxw88CeAEkQS/AVQB2PrF9Sv3O/Ul9WDuk+iV7l3w8fDN8vfyu/RE9l77" +
  b"0P7O/U0ADgK7DU8W0A7rDdMOEw2cDZ4JLwCc+a776fcn8S/yf+od5krse+4r7Cbl/Ojj8tzt4/CC+hP9hwGvBNoKxQWLAnASnxVnGVAf0hjaGlIa6xkBG4gP" +
  b"mgtaCWwE1Qb6BiEFlgCQ/Mf/mfzV7o3rpO9E75jtNe5U8EbvhfHi+Gn7YvyK/6oCpAWVBmUJtQ60CCEI2BLfFc4QJQ51EUARHA+KDjMNzQ4LDNEHUwbsARf/" +
  b"mfzm+Frzfu5h7nDtn+uE61rr/+tF69Xl9+Zp6kLrdu587lLwyvSI8JLwtfN69Tr6Mvkz+2oAIwJLB/sJxRJHFysTRBiwGh4Y1hcaGBcejx6YHmIgcRsJGloY" +
  b"fhnwGJEOVwkABp4AAgCu/rH69PT47xPxjevq39ve9N/T3YHcA93O37jfbOJz5bXm+eum8FT1fPoH/XkETwjrCzoSuhEFFBwWRRRXGBEaBxvuHCsbTxo2F6YT" +
  b"UBLjEKkOswj4AhMA/v7p/on9e/0O/BP4ZPfJ9MPuS+2F7YDsOuuz6qrrqess7CbsH+y77grx2vOV9nr4Mvsc/Xb/CwNKBVAHKAkCCrkK9gocC5sLawt4ClUJ" +
  b"CASgAAoCZwHfAAcBzP8b/879K/0F/uP5dveu9S3zgvXZ9tr7ZABf/ur/rgHd/YX/5gW0BG8CCQRcBQ0DXf1E/lMCzwADAcEDWQMqAgcCowC4/xABdwLWA4gA" +
  b"r/37AOwArQHsBawFFgZ9BnoFRglIDLkRmxc8FsEU0hLoDi8QnREyD5UNcQoGCSEJDAyZEaMPeQkaBgH/RvY79Nr6sf56+r/8t/3r9HTw/O5Z7YvzqPfb9jr2" +
  b"TfJL78ruMe8g89312PU/9u70WvO08rby7/NA+B/7gfYU81D08vOi+Bj/vP94AOX/mPnJ92L8FALPBdwG3wcGBAr7Nvl5/IP9mfjn9Xf4i/aT9Bv1jPUW+Kr5" +
  b"rvQx7jPuE/Mi9kH7RgJ4BRkHlwjwChMPOxTYHKgiXSMEJFUi+B/pH2UiuiNmIOkdABxSGMwYhBiUE0kPBgqLAgD3vfDq9LfyY+w87wXvmuUl4Hrf7eAW5uXq" +
  b"8ey47GPr/uql6fbqn+zA6+HvL/Q+9tj6x/0pAD4DMQLK/jX+IgGFA1YFUAmkDWUPFA83D+IPPRDJEsIVBBaBFSwU0xGIDz0PGhC8DUQLdArqB4IFAgYnB9AF" +
  b"wgPhAW7+ovbP7+TwM/Gn7c/u8fEp76Dq1enG6VXrje8I8sjyhvON9PzzVfO49Ab0/fQO+Vb73v6jApgEEAdGBtMCMgEBAg8EoQVzCpUP/A7bDsAPbw6cDS4O" +
  b"SxCvEuAScxL8ELERABIeDy4QIRCgC/AMcQ05CnoKWgmyBVQBf/3R+aTwEewX7xbvCOwu7ETt/+dr40jkJuUz5lbn/els7JXtvO9p8i70aPYk+rz9ewAGBC0H" +
  b"Dgk2CxkMcwsJDEUNHQjECeQPBg3oC5oMTgueBKf+LwIfASn98f6E/v73y/OZ9qD3I/Vg8h3z1fTv8UjyRfd/+Mb76f/h/jkBKgOlALsBpQXQCFwK9A6MFFUT" +
  b"KRMxFoMV3RQ+FRkWHBcdFfcSXRGyEUURJw9JEMENKgg3Bw8FaQGwAJn+Jvoy98vyE+5V7B7xC/LC67HtfPNF8Onsj+888+ryMPH386T5c/qm+Nv67vys/Db9" +
  b"IP6N/3kAFgCgAMoA0P+Z/j3/Dv5v+oP+a/0z+Lb7k/zZ+vf4X/qh/yn98vwgAX8ASP/2/iv+gf4t/4gAl/3R+fb8uP5n/WL+NP6l+z77ffxP/VL+LwAwAyUI" +
  b"Awk1CLoK0wp5ChcMzwzWDSoP9Q/nD40ODw56DVALMgonCR8IgQccCecIaQX/AukBkgKcAtD/nf5x/hf92vuU+3f7Bfrn+Nz0u/B48tr1T/bM9PX2cvt/+tP4" +
  b"IPu4+Wn4PvrI+nr7Efzh+qD2XfS/9dX07PTX9kj57P4KAE7/zAFTAaEBcgOXBAcHSwkKDFENpAzCDcANqAxXDBQOQw/6DSARpBJPDsEKgAjDBigC1P3j+tD2" +
  b"SPW39E7y+/AW8DTsK+hh6dTq4OrM7HbwevL78ij2b/lw+MD5d/7xAC4DjwaaBxYFoQSaBgAGcQY7CCIKGQ47EaQRnxDrDp0QDREoDg4O4A4=",
])

///|
/// `7.4k`: the C decoder's last 16 frames, s16le.
let amrnb_7_4k_cref_tail : Bytes = amrnb_cat([
  b"4/93ABYANgB5AHgAawBBAFoAUABLABwCfAKJAYUBVwFfAeoA8v+a/6X/h//f/lL/aQAqAIX/mf+jAZ0B1AECAgIAjwCCAND+Jf7H/er9lP0c/Nf7U/ys/Hz8" +
  b"oPpV+0r8EPyh/MT82v2v/aD9Yf2E/Df+l/3M/v0AfADoAYcCaASBBXQEIAUjBXQFRwUnBB4EpwNAA1ECNwGSAlcCzgBgAEX/Tv5N/sD9sf39/fn9D/6R/QP9" +
  b"rv39/Vz9gfzG++38Jf3b/KH9k/4u/1T+dv7o/Rf+5/6O/QUAvAFTAUQB8wBoBCgFuQNwBMQELgbkBX8EyAQjBYUFDASFAg0DbwI4Am0EsQPOAVsAVP7V/V39" +
  b"F/vl+vL70Ps6+wn6EfqR+2n7AfoO+Rz65/uA+6f7T/08/2z/jP75/vD+PgCCAVABrwN7Ba8E8wQWBr4IVQnIB7oHBQg9COUGrgQoBOUD5QL/AiQCQgCuAFwB" +
  b"o/+K/ST8YvtC+wz6YfqM+0z7cfs9+/36f/n9+B/6p/mT+Un6/Poc/Oj8RP3w/QD/4/9HAD8BSwJZAx4EHwR6BC0F1gXVBTAFEAX+BogHvwXNBIoERQQqA6gB" +
  b"qQD2/87/6f5Q/aj6Pfmo+eb46fcd+Bf3LfeW9tL1XfiO+VH6cPvj/BH/XwBNAXoDjgUcB44Gdwb5BzUI3wdVB8gIXgosCSUIVwk0CuYIzwYfBTYEZQPDAVr/" +
  b"nv0+/cz87vr79p70XvX99OTzTfOq8pnz/fNS8wP0TfWP93351/rw/DD/2QGoAwsF3wZEBw8IQAlRCXwJxwlvC6EMkwsQC8MKtwuSCwcJSgcbBj8F6QMoAfj+" +
  b"5/1o/d/7Jvis9dX0F/R78qfwmvGe8532ufg4+cP7yv7sALYC3gOZBdMGcQfrB64HzQfvBzMI/wn3CYsK8gsjC+8JNAhEBp4Cwv7p/Ir6Mfg59o308POD8h3x" +
  b"jfGr8bfvde7a7trxaPTv9Pn2afos/qMAwAHcA0MGxwilCY4IeQkVCz8LVgrSCboLVAy0CuwIDQh9CT4KIQjVBd0EyASGA3YApP8MAIj/YP3Q+U35IvrG9Qnw" +
  b"we0p7gLwze7t7Qbx/vS793H4SvoX/qsB6gE3ADMCMQbeB4EHBQiACs0MhwwFC/QKUA13EhYUOhEbEI8QHxAyDNcINwlICD0H0ASCAEz+S/y1+JXzie8z7gHt" +
  b"iesU7Y3v0/AE8mHz0vUk+HX59PrY+0H9bf/AAMUBAgNOBMMH9gkzCQsJbQnVCl8M1wrcCBwIRwebAk/9A/xe+/f48/Rd8/b0uPJS627nGelc7M7sYOyn8G33" +
  b"6fvH+hH7OgG6BpMDF/8PA7YJdQtKCecJqg7AETsQzA26DoESxxOZEZ8P3Q8wEL8NbgmTBi8G5wUHBpcFhQTUA9z+dvqL+Tz3zPSO8uLxZ/Pe99n+3gDHAIED" +
  b"CgbuBgIFWgPzA4gD+QG6/yz+M/7u/JH7T/uk+mX6s/k5+ZL6Y/s9+3H83Pgl+av9U/wS+3T7vPwf/eL5ovPE8A70nPhT+Un4pvs6AcIIcAtDCZILqQ0eDREL" +
  b"4QddCJoIQgacBs0GmQV6CZwKNAndCoQK+ghZBsACsQDe/Z/+rPuD9av1KfkV+rn1B/PK8qDv/+hD413nq+2k7QTu2fGV+cP+Dfvk+QEAXAUvAQT6rv35BGQG" +
  b"qQP4ApwITg0WDGAJLwpuDzsRAQ4rDOoMPw+7C1oEJQbKCJkGcwW0A3MDnQP7/XD35vVC+PH5r/ch90b6KgD2BFUDxgKVBQQHgwYfARz+mADKANv/A/+b/lsD" +
  b"LAfyB0UJ0QmyCpoJswWUAlT/rf3QAAX/e/lJ+VT/6QJX/jj68vW08NjpMuFI4SzkdeXA6Vjru/CT+O34IvlR/WcCrwFA/UD9wQAOBfcGGgcnCtMOyxE1EagP" +
  b"URDJEdwU0xQUEowS+RHjEi0RdQqqCdkMKQtnBev8dPYH9c/zPPSz9KX1gfkc/uIBowGEALkA2P9y/pT5S/U/9hn3SvjK+Wj6Rv9FBQsJsAviCycL3wknBr4A" +
  b"Dv/6/mL7Lfjz+cn9D/6F/2X+2PSJ7F7mWuNI4xziTeZN8Jb5YAFOBM0EQAgiC44HQQAE/PP7Qv6h/9j/wAWlDZcR6xHMD9IOMQ43C7gG6QJFBMIGnQS0ARAD" +
  b"sQbDBqoG+AQR/avwtuZJ5CXqDe/a8qv7tQVnDaAOXwrLCE4JHAZZ/wv6rP6bC9AReRBLEhgWTRYEEMQFnP+g/fX6zPbm8tP0CPqz+vH3j/NJ9GL3FPSY8Ubv" +
  b"6ecG3MDVQt/E7Yn2zP+PC48XcR07GRQUFxNTETcLzAJ9ApkPfRomGSob/yAYIXUZtgtrAjYG3AdPAQYCEwgnCs4LwQfiADf89fRv7e/m2uEz3qnZ5dn631bm" +
  b"w+vV8Or26vyg/1P40PG18/n2bPg8+IL9/AgCD2oPuhDPEjETtA6YCCYIrwldB34JWQ1bDqMR2xDcC3IGCf9a+e7zIu5l5c/c79zk4szoBO0B8737lgI7BJb9" +
  b"2vjJ+5D6RPcY9yH+5Q3RFWMWexknHN4bDhRVC9MN8RSMEjoQrxXfFyoYfhX/DI8Gmf7r9H3tpubG4SzcLtlb3oLlF+tK8HT2gP1RAkr9CfTU8xvzLfCq6kPq" +
  b"3Pc3A1wCzwKQCl0ODwodBIwF0QxiC4gGHwvCEfgUyxTIEWsRLRBzCiUE8f/I/M31P+/F7xb0pvpj/2gF/gwaEPsNNQZcAR4Au/nP9FT00fkVBB0KvA0lEdAR" +
  b"ExAoCkAEnQRbBdcDuwSmCdQOyg+3ClQEIQCh+gjz2eya6Pfj1Nzk2Xrfp+nb8tb7qAVkDaMKCwDR+4r77fY78j7yjvquBiMJJAjKC+YOPQ7dB64CjgboCXsI" +
  b"wAciDNQTIxX2EVMOAQpYBfr8Z/Sm77/qIuOk3FHeQ+fM7ArxMvpvBGIHh//U+rb+qf6O+uf4gv0UCUUNagsgD4sSlRLPDV4GeAaXC/4LIglcCz4UshieF2wV" +
  b"dxAMCzoCFPd/7zToXd6K1H3S6tt448vmI/F9/JMB2vsy9OL4a/y5+Db13PPP/roJQwpTEMwXeBioFdAOLgzRETcVKxNeE4MYShutF9MR1Av7BR8EYABE+Uj0" +
  b"uOlH3sjfkObY78j2HPx7BbQI7QKG+nL2sPZ086vuKOz079/4y/w5AHUHtwpfCnAIRwbMCEoM6AuVCxAPhBLkETkPKgyPB0wC+/63+vH2Z+/x4s3eNuTE7Svz" +
  b"O/WK/jEHDAcVARX9gv+u+7PzW/CL8dH4YP2+/ysIUw4WDwUO1AvhDEwPOA5vDMYN1hCKEmMRPQ7PCCsEDQEu/Gv2ceqW3Rnb1+Il7X/v/faiBuUNzQugBAgE" +
  b"sATo+iPz+u9z8pj8KwFNBvMPPxO/Er8PJwlyB4QIwgZEBj0JUQ4fEqISQBJOD6EHVQI3/pb57vEx4vzXV9sN54zuBvBj/pYNkA3yBRwAgAaPBYL4mPS99Gz6" +
  b"tgKxAtwMyBdnE0MP7QwgCJoGiQN7BJoKwgxdDtsPhhESEdUIY//W+8r3mvL862njSOAR4zjqK/Cl8j/8WwSxAqL+cfye/jf8efLL8GPz4Pa//KL/VAb2DJ0J" +
  b"4QeKCWoHOgbDBR4I4wxJDF0Lqgx/Dw0NUQPJ/T/+bfsK933y4eim4qDlze5k9TX3VgEpC+8HxwH3/0UCJ/4P8v/zj/sH/eIBYwaRDJYQuggJCvQQLgvYB9UJ" +
  b"LQ1vEJQLQAqcDtkMUwqZBDn9g/y09iTxP/R87qvhNOCn54LxqPNm9n0GmgtGAoT/4//R/y338Ozc9hv+dfwjBNoKVRCkDpIGPRB8FIUIBQk+Dt8PLQ6+B+8L" +
  b"1A/DCJwEMgEM/tX+7/ki/ef8UOtk5fHpJexq70LwI/uKCucG+wHyAwQCKv1o8pvxH/tg+jr8xgP3BxAKqgRNBu4OJwmxBKkJrgumC6IHvgZvC6sHqANUBu4D" +
  b"pP2X+0/9BPyz+GnxFuaJ4n7lL+l57nD00/t4A6UET/+T/JP+pvy+91P6tgCfBPAGvwg7Da0N9Qh3C0wOrgpcCVsKEQzhCzUKOQxmDOAKDAtYCdIF5gLdAUgB" +
  b"J/yh+DH1eurl5AXose358k71xPm0APwADfvN+AT8+vs7+Ev6bwCJAwQEHAXhCGYJnwXxBqMJmgcHBogGlQdPB8gGfglzCSIFlwQ2BtIEfwGo/bL9uP5v+kL4" +
  b"IvmK8tfr0Oxz8S72vfex+gUB2AKf/439O/97ANf9mv2mAbUDowP0A6wFxgZlBMEDCwYrBc0DBQXlBcQFuwZZClkKZgUXBaMHoAU1BssFHAJ5/uH8Sv3v+m/u" +
  b"M+Wa6ALr6+uT8Mb2oPy4/iT/GgCWAHMB9wASAZEDgARfBcAG6gZtB3MHiQgVCbwHWwcvBjIF8QR5A0IDRAU4BsIDZQGhA3oDZgKKBXQEmP/S/WL/lf+d+Lbt" +
  b"jOzi71XuxO2p8QD3tvlJ++j9Ef9T/qj+jv2o/S8A3QC+AocECAZJBcAFqAnqCMIHDwlICAIIKgcVBucGigcTBzYEoANdBSoD1QPQBSUCOf+u/3D+2vuZ9Unv" +
  b"5fCc8gzxovF49bj7O/7PAI0EdgONBl0GIADeAqYD9wCvASUCFgLcAfMEPQb8AxEG+wUnBP4EzwMuAykEGQXcBloEhQQ+BuUDfAVNAXv7Ov14+qz2WvWE7mfr" +
  b"Iu/X7zPvF/EM+IT/kP1K/vQA0QDdAgEDjv7C/1gDgP6ZA3kLVAc0Cc0M4QrHCiAKZAneCHYJRgleBFUEFQZTAkgDGAVTALn9nf7x+4n4K/MZ7Eztk+/M563m" +
  b"bu/V8DTv+/Nh+Oz6kAKPBWkDxgvFDpoGhA50FLANZg/wEfANrg3wECIPFQu9CyIKdQX1BCUIpQbtA4sHIwv/BksFRQdXBQAKbQVj+VL8yvoP8U/w8e//7Ifs" +
  b"W+1P7cntl/Fs9B7vr+8t98j2oPIS99n2rPJO91H5kvde+SD4aPfn++f66PZo9i/5ovoW+sn7HP68AlAHNwapCfoPxAwxD/gUMhFBDm4QZxD4DVgNFQ23CzEM" +
  b"AxEfEWMNzA4GD/kLdgwxDOgIeggzCe8FEgOwAvIA4wAdBGEBgv20/jH9qPl6+PH7lfy7+I75bvp1+En4jPdx+8/9+vl19of1+PV79O3xwPHn7FHqzO1e7Avr" +
  b"We528KnyW/ZX+e37Nv/K/cj9LANWBOED/gYhCbwJxAq8Cx8M3Qy8DbkMpwuLC1cKeAjlB1IGVQVBBIsC3QdmCkIEZ//h/Qr+Gfto97X2Y+8U6y7vkuwP6oHt" +
  b"rPNP+PX5UvqX/V8CTwJZAkcHnwkUCp4MaBIiFU4T/xTIFrMVPRUzE1kWOhhNEd4PaA8KC5EHPgNlAU3/s/j48GDrM+op5yPem9pJ17jSi9Vd1s7WWNxU4abn" +
  b"Su868ZbyBPof/MP8HAUtCr8McBIjF8QaZR3eH4wiyCLtIiAjUyF6HwokriQbHXsb7ho8Fd8ROA5eD+wMnAJrAav/QvjO9Mnuj+ob8DvvXOm16h7uJu/D7e/s" +
  b"j+/R8JrwSvLJ80j1v/3NAgkCbQZFCmoKzQjCBygMrg1WCtcJPQm+BmcEXQHi/tn7lPjv9ZHz9fDa7j/tvOkg54zlw+Ot5K7i1eFl5hjoTOqq79zwt/GL9ib5" +
  b"OftHAIAEAQjoC80PZhPMFWMY1BrAG4sZvBhFGfAX6hjLFzEUuhMaERgOdwwuCnQKIAfEAukC6/+N/Cb+ov4T/vACkwTQAZEDNAXaA3sCJgGDAKr+Cfxw+yv5" +
  b"f/Yi+rv9/fuw+5n9M/0T/AX3cvQP9qzyQ/BC8sXw4O/C8LbtPuyi6uvj5uP24m7f4eP95RPouO6r7gjvLPWf9tLzqfj0//UB1AC5Bf8MPA6zDQUTmxv2HSUf" +
  b"OCGgIToisCNPKCco8yTjJk0kVyBmH1UhyyK9FyMS8RO7Cd0CsgWhAuD+iAQZBUr+1v4HAIL7P/iV9kj0qfCR7R7t6One5nrorOv466Lrxe618Mvwj/G+8SHz" +
  b"GPQc9Pb12/Yg99j42fiy9UT1ovTb8bbxavFP9Mz2C/l2/lP/tv+rA4ME5gIrAykFTgWfAmEC4gOrAsoAtgaBCuQGgAg4C7EJUAmhC1EMUgmLCcAK1wQzAhwG" +
  b"UAa//TD66P7L+pf1VfoJ/ML5sP6PBCEDGAS/CUYKZwjpCY8KIwhxBoEGSgTeAFUDAgV2ADsAWAIZANQBUQKh/z0AuP+L/nb9hPu2+zH55/Mr7qTpa+jg5MTh" +
  b"eOYr6bzraPNV94v6tQA6AEf/EgNuBIf+nvvg/nP9Xfov/HYCtQULBRYJJQ6TDqsNkhDUEZYO8g5iDX4HaAjqDPUFaPzfAboDPPrD++YCcwCUBekQ4w+FDx4Y" +
  b"URo0FTMYnRoxEugNcA6LB6H+fP7b/9n7SvkR+xv65vkb+5r5P/kW+Qj4YPT38ejyXO+K6onnpuSf49Pey91s45/jf+Yd77ry7Pai/RT/0f83BBwGDgTYA9sF" +
  b"FQU5AzcEdwcLCMsJlAwFDSwO0Qz5EPwSzQ3wEMYRawsSC9ULsAcZ/SX75/zl8fTutfRu8Avw1/c++rr6IgCpAMH/NQRkBcMDuAWWB5YGxgWFB2kICw2VDywO" +
  b"2xFhE20Qfg93DggL0glwB8YDDQHE/aP65fPj76vtVucp5X/kY+Lf493ls+j07GPwefXw9r/4kP0U/j7/GgM2BBYFgwf4Be0FCwiUBhQHjAgiCG4IEQigCfsJ" +
  b"Xwj1CeIJpwfkB3cHQgZIBbMEkASnA8kC+wISAmwBbQGkAB8Auv8g/6/+E/5w/kP+6P3Q/r3+bP4I//X+lv6k/pj+cf40/jL+QP7k/d395f0=",
])

///|
/// `7.4k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_7_4k_fate : Bytes = amrnb_cat([
  b"AAAAAAAAEQDd/wYAF/3HA2LvZQfq8QYPpvHuA5/4vw4E/lED6P3PA1b40f0sBrUClviZ+QkM1Our+6j30AZc+6f+dunXEVzkMwQfAPjtvweuAi3qgxJE788U" +
  b"JAzgBKMNEPvZBBkSQPHq9UELX/unD/7wlw2hAy0CEPsn8QP9B/VH/of3k+RT++gNW/mrApbviwpY94ECXgj+/dsBwPs9DswFd/5yAJn+cf+V/vrtlPyXAOL2" +
  b"AAoX+jwBvwQG86wIPvGY9xEC3AY0BRUAXfZxC2bsPwjMAN4CYg0l9U8We+5nGcf/pAULDNXlIwIJGtveTwjjEIDsCwPfAOr/WQN9BiEJ/O618mL8jPXYHEkP" +
  b"8ezK/iwUovaN9A8EABIX7y70Bg1g8lwKJw/C6zb9k/zR+boKgQfn+Hr7cgNPDtTqoQS3Denz8fp1BxD7rwkvChT1EvzT/jcAtgJvDzjztfmC/CcRfeqqAMcJ" +
  b"SgED8zT7ivpvAjgXFfid+6v06gdo+G0SF/uj+OT7RgsW7XMBKwi1B033Q/7B/Qv9ig7X/2j9b/rwBKD0ihWvALf77vOtDjLzGvx1CuYGkfmP/DgDo/ocDuAE" +
  b"2v0f+Ff/MfsvEK0AFvly9ZIKLvw5/tT3CAgf/g4A4/3PA6X73QA/AR4E6fud9+UHeQH2/Vf6HwZM/3UCcPqfBsX+zf2P/KcEu/v4/1T/eAQpAz33s/9JAqn5" +
  b"S/2Y/RkBVwfR+WP9a/jHAyMDf/tr+3kFefxlApz7cv0oAi8C5QDuAUUBdvvMA6L5lglJBLz8HP31/tQFUwLt+xgOXwOz+5AAkv7pBXMCh/70C1MC0PmkAvj8" +
  b"QgcHADf9RQVRAvP0DgWv/w0H1fog/vADnv5B+hwBuv/DAlYA8voRAPj+RP1wBYL/rvxI/Wj6/AFe+6MD5AAH+i8Be/vMASn+O/bdAh0DXwGr98H+GhrX67jt" +
  b"kQUrEv4KSuxh/hMHBv3x9PIL/gMD8YEEHQvuAXj02/GcCuUOoPNv+lwKRQUX/ub7CAOVBu702QitBj/wU/51/ZcJSfhz96sSOvmz/f/5Zv11DYfucgccC/j3" +
  b"/v9x+jIA0f83+LQLpgGy+Lv5hQBFBhfyuwHPB1z/9/jv/BkFPAR890UJ6gbA/Mz8VQAzAK/0JPlcD5sFgfdf/Vz+2Qix9XkHXALB/nP8XPtlBMP8DPp+CvUI" +
  b"k/oF+s3/RgiL+b/6Egv3ASf8+PguAQQEvvPABxgGefpe+a37FwpkANP1ZgqxA8r5IvnCA4oIwfbL/lYGIQON+t3+TQB4ABD9DAV9AMAAJ/6E/1IAmQBC//f/" +
  b"HgLJ/ssDggCn/igBDwAVBtH/C/0LBcL/uvuA/48JmPgM9ywAWwdIBUz8VvPE+6/8SAiAB7H/Pf74/M8CmAQX+l3/Agk6/EwIRvTK960Gd/oHAkv/VfmgBdT9" +
  b"Xv1KAdD9vARYAyT0EAd2/VACdfw3AgQIaP72CmnzWfzWAc0BiwPj+AX/jwjy8HED9QJJ+5ML9wW7AVXz9/zDCXD/A/evBF7+zfsT/pf6DPy3/wgC1fnGBXEC" +
  b"AvgGCwb9YPQ/GiX+WO74Asz8OAle8DMit/xj4iUEdQhjGfEOIufA/UAPJwIuD43uaAg8C4/wQgAb+urVDwbOHx7+NdRn/eojHgbk/O8IbA7k5Wgg1fxgw8IC" +
  b"diit5cju3+9X9IoJCPl5C47VchR0BgIRs/cbBLYg1vVM9zjkhgoFDo4T1wZkE18btwLD/sv7Mecn+evQH/CS/J7/A/ou/4ELme9IDsf79BAg760JWQKjAKYB" +
  b"zfYZBCX2FxEd9xn2lv6NDA0EI/HV+WwAmwvyABwA+vcP+oYK0v8t+Mf66ADvAukH0gF181z47AzwAVD5tvleAoX/9wnzAhv4ifiYB68Ckfpr+tj/7AfCAlAA" +
  b"q//sANYCf/9T+ygBAPvZATABIP9L/HgBDgZH/2T+iP/FA1L+LgBQ/Vf9JQHxAoQCEv5N/zQEyAKP8pwEawxd+Uf8K/ZkBpILzflr81kPawV17TT8jPyfD2cL" +
  b"qeUYF3ERQw931bf+8d+1HLvV/gEU/6EqoxYs538MQfXGEmjO8gZI5Y4mL/R0/nAODfucINbGYRTH5tYir86xFbH9XgmCFP7ipxys6x8Ox8+HHJbtmha5/swI" +
  b"/Q249VoMH+IZGjvgRBhd4m4aSPKlD7b1/QM/DP70qw115OASVeX7G47lORJS6MsZHPQbAmv12wImDsnkDCwm9An0k+mfEr4JRyKCvsYVEAAXBcPuFgmK5hMa" +
  b"XutxIRTVcwbE6J4lXeif7c/1Zydl7jkKge9NC2ULl/x0CxAI+f7o/SUWyP5KAXLxHhzA8uH68+j+Furv2wg27B0cH+MFBCzxaBd76hkGUf7UDefregC28aYM" +
  b"w+tvCYMDCgKl8Wb/2AEdDtft8AQr/BUHGQK2AH/9A/8WAXoVygMP7eX8JAWiHrXmpQM8+HwW2fUnBirpSA9P8Owieffw8X37PQjID9Xznvb4CYcIVAOK8Qj6" +
  b"GwI8BLkLyQF08xL1xgqfB0r4Af5HAuEIlAmf8vD/NP43AY0Mku2BBUz/0wC9Djfqkgq//Oj31w4M/PP4SgQq9LcSJQJG7tAGOvp79woX0veW+uoDpP3+FiL5" +
  b"EfQqE6T6mwW5//P5RQFnBbn35xOU6KAFIArW++8Ebfmo+e8UmO39CxEENeY8Gp7viRIC+Tvqdxn//2v5SgVC4vwbMfqj+hkIi+qaCpICrfu5EincOQyhB4z7" +
  b"LwV+5noK+woa9awFT/Qv/H0MOPcUCTb1CfSIEOkCwPny+Vr7wRCLAr3zwP/fAawDkQeuAz3yEQLJAp8FpgJX81f6PxAL9gEELf4J+ZoHPgJvAfMAX+yLFOoO" +
  b"bufL668WVhGi9eb4U/1ZBxjsTQsW66sPQiFJ8P/6VAtM5YEWXxZH5RcAGPmhIzLv8e8iC/f7Vv4L/CXfFBMAE88JMfR38EQCWQm+DOcFOehF/OoiQ+CbBJ0F" +
  b"SPmBER3yJuoqCuEJNgiJ9s/4PgD2+xkX9fsm8xD6kAcuAFT1yQ+8BsjzcgzI6l76KRpk/Bf15AEh+xv/SAkxB1j4FPVqE43u//9bE7P5QwIw+vD46gLiBusC" +
  b"B/GiCGL4sfPVFl0B8PtU+OkAGv61BxYD4/qL+ukJm/XYB+MM6vKp+GgI0PV0/egKNADp+Ij5QfyM8y8X0QhB7cgGp//5/ikP9vXRAxr94/9VB7jzPwGdB3L8" +
  b"2QXI9rQAXQXj/Br9nAAsA9P97/2a/EgJQAT8/7r+kf/b+PQH8AIk/DADsADvAVQA5P8zBEX00gjQ/OgEK/O99uQI8wjy+G4AwfruDV0ChfgHA8sEMATRBRn3" +
  b"eAPaA9T0XwOB+dX92wHJ8rjxZAZOAZEKJwWTCvb4cAlQALQLYQ8q/A4Gx/4y/3D2oP36+XMIQP0LCdT7EP9t+oUBAQCbAKf4Eukx/60F/vxcDbLydQNoDRIB" +
  b"kPByCCkEfwV4A0AD7fVf+Pv72QJVBp8Civu8/6H6TwMhEV73MwJw9gj9L/i6A8wCefYKAMYO1wYU+aD1+PmVEFjoJe4NEokScfvF9AP1Cw9195gG5QHl8vUC" +
  b"GAlFF//savc1Fw4BIunq9KL0ayLzBGzwQgeX+GwNtPZY+tcB1PVBDUgEae2jA0nzYQg8AhPw5AkbCmn/lfs39mIHD/uv/s8Bm/zT/p8CYgQNAlT01RUsBUH8" +
  b"JveWAZcHD/v59gMR0AAKA0j4SgRmC375RQkHBOH/qfuI+usBhQW/8pMUv/11/7n3HfnMFHz0ivzkBzf1cAFr+OL6CAyE+WAHBwW2+9f9CgPLBcv/wvgUBp4D" +
  b"xfnB+08Btgad/Rz6zQk2/QgChPd4/XEHPQej+o36lAHiBnoD+/qw/g784AtdBFz4e/IGAW4JSgl/+CAA3waJC10CDPdSAxANmQ29+KzwlQfJCBIBRvzL/ZoD" +
  b"vf1XBSj73fehByj9aQHq/BMKyQT/9eP99v2BBZ//iP2d/AUHkPbB/1j+MfBiF6Xzhgm6+QQHIhYoASYPwP0T64QIM/CCAODyrhWGDI8BAwxCCogCQhBH5xH7" +
  b"qfOT90sFo/hdAJ0ATPIBBmcEA/ptIE77OQ8S9l8KQvt+C+j9gP8R8ZIFhPlB8ooC5wWfBwT0axKe84DkRP0tH1P5FwWc+kwBs+3kEJYP4f/B/VTyWwkV7V8K" +
  b"RuVH/+P3rhCg9okD9wNAAb/8ixte9UIX//GAAQ7/l/mQ/GD37gGk6yQUA/nm/OX34gz4AXEFhgEn8nsAGwMVA9kNaeoIBTgG8QVbBxb9hfHo9Wr2wAAM8Ef2" +
  b"cABi+jYF9wUHAb7/YwquCRkIyPwjCjn3wv47+wnmyPvlDugKNP1X/MwCSwIJBIcOKPGB9TMM+g816yL3hQTjBx4CCA8i8Of7IQjrA7L7QfXXAR74lfqa/mb9" +
  b"1uw5DkgICwdDAkIBSgg5BGAD/wfF7ZQFlQFEAED72/xd+cADqgSBCKD+7ffdApf+igCc/9v7pQB5DnkD6gMp+JwNaQCyBCbyT/369v0G+fvL+Wz1vfix/NgI" +
  b"ZviFBAEAwASaC7b8lQOr9KX9tQjVBx/pZQEb84kStviRBdYIUPSQ+tgBGP+nAAvxwQPOAXH+i/8H/4QV/wD1/vf6VxIw9y78uvcEAE8AYQB2/rH+YACA+TYE" +
  b"uwPHAxUAe/+EDBb8s/SrBVP3wQU6AP/8tvvUCgz8Yv5/994BtQKV+pv/xAFd85gDoQao/tD01waoA4sBNAxa+Y8AEfw+CTb2sf0N/70AofwQBkz9lv4PBYv9" +
  b"HgMYBenxUvm8AUr9FwE+BGnydunOAYUYQgm16RTn8AZCJwDxieu8/JgZOiA+FF/iae/vAa8NqxY/A8PcxyGMFyUJ4eGyAlofe/s6E0/ypAMoF4kWTeEPAvUT" +
  b"7R0z+z3mXf25D+YM3N0g/7cFaQEE/x4NE9e9AAYWJCOj+igQcPboFGAEW/pIAVP/lBRt96jrnv6hFVIDORii5kr7GQtnFTT4ZvP5A7QLO/MG/OIH8PWSC74C" +
  b"PfBgBsT6yhAe/EP/tgSTDTQLVOsy6Vn6MhRmD98LVwfy/Frn4hGS/HAPJfnF98//sgTEAHz1+REq8WH0vQOHB0gU9Ppu/2f77fnkGpUB9f+g9wMCWwzCCbwC" +
  b"nPQ6/JkPwwAO/mHxL/PTD4EMnQFc71sGigRJC2j9KvPDDtD3Vw09Bmvvsv5q+r0K2Acj8jf2jgCmEK0P0Psh/CP0FgdXCAAJF++Q8tgGnQbgDa7/6ObnBw4C" +
  b"FwyqAhTwvP+36SQQeANf9fn/UfQlBDgWsP3rBXDtSPndCb8HEQfo6Ff/5P5dDjQHPPEpAMXyvw5yD1f/yPkG5ycKSgH3CVQCavdI/gLxZRK0BWoCPwTc6l0E" +
  b"zf6GCpEKQ+6V/jjtJhDaBgkDL/nX9FUCsv1UCkv/be3zCZ36JAlcAJ31Agur9an/qQCb598LWfoyBRcbJdY0/eoTCO9QI7Ho+f1qBsP2QhC7A9b+DQUm3Q4H" +
  b"aRn4DwH5w/RT5eYSwRKH8KwKit4/Ah4SXgwND/nX0fX5GHcNYwOK7TwBcv5iDYcJwu3RCfzyhf5X/Av/dwi89V8BH/fJ/WMSWAAo9972OQv3/qgB0wLn78sE" +
  b"0Ab3BZ/3F/OOCNgETQt1/Fb09AYCDsL4dPm5/d39SwxGByHx5vlnCKYLvff67eIL/PsUCKIAi+qtCa4RMfgP/JH0OAT6B/kDUgH078cFFRAd/lf0gwBX/gcM" +
  b"cgAU+J75Mgr0CCL6IfJrBzEAGAafBNrudwMnDtgF2fiy9Q0IjwP8AFAAn/wjBQj8UwPK/ScGaPr//6b81ATY+34Ccfz1AmL6p/5E+CgFqP1KAz8GafWq/n8R" +
  b"iu1QETXsKf8HCc/wLAwU9gMHPf4s+dMGZfzhA4j+zQSxAzPzLwv8883+EAWu+ZkI3vYpCLb/MPxF/nH+mgRk/8kAHf0n/RgPiPLSC3D2Sv90BgL3mQY9+mUC" +
  b"qAPw/9f+2/ROCoj8iQKB+uH3TxC5+5MGwvXC/WMF4gDuBEb2z/xhByD9AwBj+YQC7AKKAdD6G/upCEL/mwPR9fUDpAMvBPADY/6g/B0Mzv74AF0OnAiiAe0F" +
  b"KfYy8dMOXfh5AmDsQgklCnoGyf09C1DnZxjIEW3s7PrXAoL7ABZNB7fvL+jnCxf/mv+PDzTwixPY6j0JEOn0DwQIReuuC6/3j/5WFWPshhBl1ygIXxO6/ZEM" +
  b"B9/rBoELpwrG9KT/1Q+/8TULMglF+JoNEN1wBSgLGAU+GWTQlAplA5r0TATC9qIGTAJdDFYFhP3WD0LYDQiUAn0R7wHb6s8NS/k5AvIK0vCxDu/fcgsVBQ8H" +
  b"gAos67UM+P2ICh/77Pj5BYzjDhnN+g77tQ2z55APTQRPBM4A0+zmEz3vuxGz/I/35gDe8y0Wb+9wCz3+IfCkFbvtgxL2+qn65xDT39sWuvU1B7wFtPYYB7T0" +
  b"ZxNx+vv+eAAW5wMbwu62DlL7LvOqFVDipRSZBmX/FhWn+VcHluYXEWYAMA5MAQPgBAZFCIT+PwhT9NQKoeSJ+ugXZv81CZXYAgN7H1D7Aw0m9CcI4es8+R8P" +
  b"nwoEApLeVwdFEbIBwwFW+uIU1dXMCt4SLAJDAiPa3BTSINb2RAul+lgNIP0KC4cG4///Arjf5wgTDqwGNQnr168Kaxrp+nf/c/7dEBXcSw72CyH9Gv425E0E" +
  b"ORbsBrQJbudOBJIWvfwrEKcGufFoAYIM5ABY9W7zd/yKFWMEdfVqA2zsjQuJ2Bz4NQTVEhsSaNRYzc8jbS0uAyPWkPJ1IHEBzwYJF2niM9q6JFP/TPA38634" +
  b"3hTa+arqYfkA89sgY/14824HOe83FsoMme5rCwrsjAw5Bsrzxw4495D9+QyS8+IXPgBJ87DzMQQ+DvYCWAMF+KD9JxZHB3n1/OItEgQI9AzvAQrePwj7B/QF" +
  b"EuF5BScKgw04BLH6xPE2+hkg9OsG9QX8yRGGDS38Pfbr8W4WpAG1+lngYxT3+woILArm6BL/0Aq1BnTxc/LKDe0C8gTmAS7suAziDREAsOzf/4oCkQk0B5X2" +
  b"3O8jDngOR/ZS9OkDPQKQBUYC0vQyAlkHs/2X9nED2//WBGwB0/wxAskD+AKp+lH8owLj/18BAgAQ/IEFRf8l/WgEbQQB+nsFJAJ/+VkDqAFd+FUHzPzX+hAL" +
  b"1fRxB+n8+fZUDND5qwE6ETPuxQED/Mf6gRJ2+vMDcfym+3oJufVcBSsM8fkD/0n57fhREAf1Gfct+E4E0g625psL8fdxHWsCqdn8CNwLlv3xFFveXAItEFwB" +
  b"1wOn6coL+vyp/lwLy+Z4GET5q+6EEor+BQ5x6nPyohKQDSAIaePg9n8P7wcuC3zuG/7UD4oK7g4E/L73NQqx7eEI0gTYAisF4fz3AHkDtu3dABMHDPEWAj4G" +
  b"hP/hCvH7aQN1BQ/x2fYc/rcL8gCM93fwHwxn/5f9WBab2i0Kextc6UUKkfO38UUZJv5/9sLw0vOwI6ECeujZ+CsDUQyw/nYApOme+2ENHhjm+WzjNwSwB2QF" +
  b"CAuz6JQGswTo/Q==",
])

///|
test "amrnb 7.4k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_7_4k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_7_4k_cref_head),
    2,
    amrnb_ref(amrnb_7_4k_cref_tail),
    2,
    amrnb_ref(amrnb_7_4k_fate),
    16,
    2,
    "7.4k",
  )
}

///|
/// `7.95k`: 5970 bytes, 284 frames
let amrnb_7_95k_file : Bytes = amrnb_cat([
  b"IyFBTVIKLGJJ0M74AUNMhhnsOpySC+gBTuBOLGkrc+BwGqQBUQzvCKEeKMyz31EOLE6Zv+BlTVdZCILgQHPkeOXEURa8LHAZc+DLP0n2dgbusEZFo+PHqZlq" +
  b"LJAZc/Chy44nF3Ivs07ybKcF1GpKLE4Zc+kEDYnnd//lnXAMFSDodNPMLKAZc/DAI5tKRifEgNL91dBIMVfSLE7Fc+Hji4czVuIUFa7GZCkMpOD0LE4Zc+QA" +
  b"a/FydneY1PFmhdKh+p7YLGgZc+CBP6WWFyRdxPt2NG9OjLssLE+1oeFx9b4+pUKJUYem5LSogSy6LEFmn+FBHlmrmDmn5VmljldOkX5MLEwOf+CAbjnHrE0z" +
  b"CFw86W7lbxoeLEARv+EAlrmtqVu7m8iDIpn9K1CALEXBc+GAXxiIkAAnTeGEsP1e4xgALEARv+AAVugbkcX8KniBh3G7HcxGLERyc+AAXknz0SiP7AjjIflF" +
  b"rvbqLEChn+AUNrtDEG7EoFolwDSLOKoiLEkdiWiAvh/75iVbXXuzA8aG4KLiLEKLRcIgp/N3yX4bapex93iPDzYMLCMSiWjA/h5QNuipjahYpUZRggX8LEkr" +
  b"RaRCz9aMILGUAXEWpeKaqzzQLCMdn2iDnhtZ0BjACfz43G5eQ9kILEgkiLVQ7VS1PhJ8Jt9Bp/VDPmo4LCAkBJdkx/vfdHQnaFwDOeQ9lLc4LJBvc+CH+qWk" +
  b"CHQK8vFI/DGkEvrYLE1/n+FRZ9bpDg+CmQrZnoqOUDn0LGkq2+CIymMWi/Sjs+GnSqKBgmZGLHG8n+AJf7T/JnNGRAekfhvKVIY2LHEqn+AoYGGYB/8DIWat" +
  b"6eWJpNf+LHG822mYf+YMAgdHGW6idlUJ5MgWLHF/C8Ip6MmupX4fIOmtXcCwQ6smLHSj2eAJfc4KgiGV8aCPLkGu8h+ILGO8w8Iy7N4HhXDSmppq358SQ+YU" +
  b"LE1/oaRNqMsWgXTfYbQN/eQ8unrALEBHw8L0W5ozxm3xLhF6WSals7gMLEV/7eEAM5WtMix50AfdGglhOX4OLEG8C2ng3eSgNA+PNShKHscEwZFKLEO8NeAg" +
  b"32SEsqTpKwK6sbb7I8HSLEJyoWiIHZ7eiCPevugvhVwwlsNuLEN/r+AQP7B+eB7D6Qhf3hb3LhpiLEJH7eAEu56XGuAlNs/vf1IOn8R6LEJgH+AAX5kef8XF" +
  b"s7r/yANMIKHMLEivE2iRH55dCFW8cl+57luARJaaLEO8f+CAfs4lNVQ741OsY+6JNs66LEyv7eABn5nP4yjIrL2rN2BE8plkLEEq2eABn58EUy7x4vb9WsX0" +
  b"qbRILEyv2cIhl8MOJDZ2JVWdruijzb64LGJb2eAAHYnB5D3occUrVSSbl34ALEyh2vED7yNUythfrN0MQ+03LZAkLEIRX+BCe35g6O/bNFIB9rLnO6wKLKCZ" +
  b"2+CBmcm0w7xkfHSqhBlMUr4gLEKh7+CBGb3JaATwuAtVZcBtXKnULFxy/+AQbIql1TL9XpE1kl7crE8oLE6v2eAD38vYbGyNwfHTauoLnU0CLFyvC6Xg+bJg" +
  b"lQUPt8v6G1BJkjTYLFwRn2nAxwjCdo2OIua3YfEHmMuQLEu8n+Aichy4j2lHsOlV6ralKYqYLEYkq+AjJkM60bjJY0Re/BEXJKvkLCxb8eCGaoJdcAPserZU" +
  b"BhBkIpc+LJBvefD6mXZTx1T2vBHKDTuaaQbiLEyvl/Dj/hynqtNKVP2aHbI4LBOMLKG8qeeRt3cISeDh718CAcqIAj8ALHJgA+WwE5JQMUTb6v22BTcb2wZI" +
  b"LGV0ofSghHHD9T2Q5JGeSWRYOeEsLDxk1+HCFJJExuVC6j489Py1uUQ6LCLlOeGAn4TnqNB5xSm9v118EdXaLEhHi+AYGib/gcx1wX6Ef360x8F0LIBT1+EQ" +
  b"mkyphmpnAivQX9wjSKNILEO84+EAGb1mVg/ko2FbD66dOqNiLE0HoeAAGmfVpF3rC/Q+tzxauPJWLE3Bi+AQWhGJyT+Wt/ku3Lb3NAMkLHG8o+AEvg6QkGjT" +
  b"DF1Mr1kyhkbqLHByoeABTdRt5GvlAod7ZpaczA+kLESjWeACQOp6hnFmzULkm91oYeDALEIkv6TmVos1VO6nHeh9Y+RTLSAgLBr1P2nOHWHuUcwyFkGL/BmV" +
  b"0pTKLCni2+CFmGtTRX+g3x9KgEsgV38eLBL17eCB+HNQ2rXkjRdGHJDkWNp+LCQRr+BaMPNSYEVZoB5s/oiGUp8WLBc7K+AC0M4Tj+Msjs6IPXyXdRkGLCUd" +
  b"4eAB4Zyl464Un5ZA4eTyCmpMLCZy7eBYcNtC8gR7EjDhYxdEN3UwLCGGi+BDAbS6seiYyM/svxPDdNHSLBXBBeFEmCVplVhbP+S6wcCbgb8yLCM6SeDZKUG4" +
  b"L37DfW2WBN7HJGHsLCm88cLwrVTzohFD3Z5mCeQNV0M6LERJleCTDVStJSL7z6dyo+EFtCNmLCUqoeBHmANIRCIXXtD7IPiB6VoELCIQaeACOoiO+mrXr/zU" +
  b"uQd5ZwRwLCJHWeCVjVXjrsQiIPAVJlVzBU4eLCAk72jGr0y/zfYB3J0NEPaetUoyLCIQNWiImAN/C1Fqf5DvBGXy/LD4LEAR28IwHDkBFcb3OEOmGoNc4Bxg" +
  b"LEQgC+EDWzTH8MuT10HLCzBtnGeYLEOUlPGBTf9zDcK1FNMXKhAplQK0LBwRw8MkTKnuViOKuJYQmtcBwhL0LEkGNeAFO1cf6qKguFwtxtPL77OALEZv26Xp" +
  b"nLpV0j6m4S3bZobu6FwCLEntoeAiHpiY5Xu5Ad61tKX+wNqwLEUQBeDQG9nxzVLwCs8F/scyY3PkLCEcc+CB3KPSkAS0YOMxtrcxLYKqLCAWeeAhU0Q8XV4x" +
  b"4uVy9Sy0PPpyLEkQz+AQWf4ex7jkdSqXHgC2nb12LEhyeeBB21YyxIRpEUx3+UaYXZgGLEhv0eAAG1Z/ruHgQ6QJ+hGtjGfwLEkqWeAA2Z5/5w1joyQNbKQs" +
  b"8CIWLECjw+Bm/JOs12ELZdevbCMjKcFwLEhHNeCwMJx2ok01nSAYRhjSnfF4LCEqw+EgDhmtljrgsFvNuiS10cA8LEByn8KyGr43F3FJyF6+R5us4lQgLCG8" +
  b"NeGWOfzkEtxPxMLJTTiWzepULERyNeBBLqNq8vjVyjhKDyLT/bG0LCIR26RkGftMUoO9Eg5vMPBe4T04LCBH7+AET74nToOeeappnQIHWlbSLCCv8eAAGfys" +
  b"Oul9eYbPpaCZNvaILCONNPGBqfNVc1jWAJhjXkHUk4YeLET176TRC2z1NdJmhQT2cxZidKB+LCPFReAEC3Y0GfuywT63y7lpfiCKLEChReABnmEr8JSvZlaU" +
  b"qplA5Iv2LCY37rTALo9aD5NUP/hvEyd078R4LGjBnnmtLKtYYYZOMEjMvtmQYNr0LHSL0vFIxgPwcvcJspZN/CzyU4G2LFxvc+Exv5qcOTxDKrOG+ofEmgIC" +
  b"LFMQ2eBCCmSaraHUICKX+XB8J5fwLGijP+EhGZYpEKXsk1RCqa6Xy7VkLHSjNeFlAGSbGqgskBZZ3po04IL0LKG1f+Ggwzsd0m4nilXubQjol1VuLE/tIeDA" +
  b"1uofkSO7IS7HnnL7W7cmLJNmf+FgSmMqldyV7+2wbY8IPGcYLJCw2eDh2mWw66wsQypn0jG/ElBALE3tf+HAPOjDBR2uHHSIDY2TvPJuLE2G2eCgI9ad5eqR" +
  b"4px9l7Vs0HXSLEIk2eFAd7yutXuRkKJLJ8oxNlqSLE8qf+CAe3IOxeGz6NUKiEMFbJmOLEkr7+GhuKmkKabsSuI2K+bKVkDWLEUrftPgLojyM7/+O4LRXqOg" +
  b"nh1aLE0Qw+E42/FM9VD9A8D/75FJfXaGLESQf+CAPbz2myuoPWEJ0w3jK44iLE4Z2eEAv54OA6X1ZLWudlP+tORSLEUQf+ClHsvRe9XkJpMna77aqgb0LEUq" +
  b"f+BIPbtQXUXNn2lahnK4ja1wLEUrf+BCH536e6/QCTq6WWXFoo+YLFok2eCAnRHybUEnUpxzte1C9HIKLE2U2eEAi1QuxE10PHOeSVDkyB9KLFMqf+AB+KT8" +
  b"EtIOl4j2tb67Jc7iLHAqX+GAlvnw4F/+6DoADPGSZdb+LEkq7+GJWbTPrm78vOjqUS5LxMEULE8qReFAWKsXaTKoy+4/o23tRCcWLGkGieCBd74GlwDNzhyf" +
  b"XYJNO0U8LGgkNeHp1RtKW595Z4PR+EEqGMZELHXtIeHhOsxlGYfcygEzCnPoY1CgLGgkf+PA9JlB7BYxjpECVWFVPFn4LHQMyeFgcMyspsWME9apoqayndkO" +
  b"LHXtf+HgYcIwIz8fxFogWQUqDf+KLGkQyeHoLklKzlGs+QGyULsYaWx0LHEQReHgHpyIMdO0Qm+5PPk5G4SGLHAkyeHg3DHQz1piqzgJg/MaM7EQLGgQ7+Hp" +
  b"HDToocugf9vYefKIZH8ELGMQyeHwnDYCD70wecWy0GWTlslCLGgQgeHhnFfAqvpBNXf8onQL1MiQLFIkgeFIXJRIDUkuNtnFkX0T22CKLGgkBeFgvDH4RXdo" +
  b"DAuS4ZJpW5+SLGPtBeFh/BtIpaVJmRi2wUwa7ItMLEUqleEIXB4/nGxPbcl3KEwykMCcLGNBBeDA3hiwzcWzNfDOM61Nlt0mLCw3P+EBHH5HGmTskbVq8uq8" +
  b"wcnsLFMryPFCPhy4r2favFvx2UTs+Zw+LFMrw6REGkwfQ/38wWDt0jz63UA0LFARf+EEvBnHahuJQORtfQxka9mQLEQRf+BJXBSqnchiEXVz0SZFZrUQLEVT" +
  b"X+AA3h4OkUU3sktZ7Iv0OrWULEShieERljtPfjtTv/9iiCLt2V4GLFIZ7+Cguvo1KFFEyeBzRcCU8MkqLEftieAAXDwNvjb7KBKQHxFCxm/OLFIZlvGBnTJW" +
  b"NPQ/0XC1Ze8AM66MLFKtyeBBnBSQL+QLUyPF5XyzeRpyLFit2eERCGtha1pvzXLP6006jyFWLEQBr+EAukmpmU8E0jgWKgK0bKsMLEyYCeEivkitlUlHo7UL" +
  b"jw4wte8QLEzBz+Sj+ITTDRy05guLh2fiRFu+LENTWeHhWGbiPxa6submGa6Ou2isLEzBWeGg/hofjyEN12+CFeWoQUB8LE1TafDhegypasOD8CouOdOakTRi" +
  b"LEz3n+HhGO6/SEjZYtZie1PZw2dgLE1T3+HjbhykLwiCSimQbmZcHPKULHBvl+Fi+xde08WbpN8J3Yb/9sKSLExbn+OC/gNNySVCAC/ppySIQ2dYLHIqaeDz" +
  b"+xdWknQ06t1A7RAb112kLHBbc+GnHgHncP/vYSbH7oaikI4+LEQWc+GheftH2fT58gqk2b8XWiMoLHIYc+FiTKy4sS+frfLxsHGu/F7QLFDKC+HWWfnqbF6R" +
  b"x6ZDjLPOS1q8LGqwBeGwafHl5N6s2srD1DGPrTz6LFAZf+BQyfS5gs4yPedqaINgNDNaLFXtw+Gg8e4kLtuNGw+RkkiTCoV6LFEqPvHB8fMa2KooNgcU6Iny" +
  b"Ln7CLDqW2eFB5KsBRLQIsPXd55fY6KsyLGxH2+CYo1H3I7ieRta3zFjUoAqYLCsrBeAA+bYXHHXQV98WHQGVI7gGLFUqc+E0q9YIiEGgyS25o+aekVdoLCoO" +
  b"P2jSwe4vGRYZ2xJQpjL8dKAiLDUrc2lB4eYI0CxfnpWJjZgt4w9kLFCLNaRFJKsOQ3i/2sSAuHgSt3fWLExvReBya9yimUyQDl6asP+5qSUILBsQleDZ40TX" +
  b"dbQUr6qCgYNDdzOiLC0QWeDAebT6PseSnzhKDI4iM3ZOLCyvn+HAKc4JwPDhPbD50O/eyzcOLC2WWeFIGbStPz/lXW4O1ANWhd3YLCPvNcOpCd4GnWJo/Ck3" +
  b"GCCS5dYgLCIkNeEKO+ssVDxZnXfjEG3qa50sLEFBWeAAWGb/tieonn5aybrJamoCLCMqRSzgzPYacPmsv70HB0fWTsPGLECL4LVwmaK5EglZ7a3NTodOwFxs" +
  b"LCOG72mAHf/t103C1ts8txOnJBJ4LEHtR+CRGcqhctVwlj+ynjwoWCWSLCIZoUromN56NBtyq8exXpHbP2bSLEKL2+AJmVl4PCX2A3Jp/kGob1RYLIoZScKh" +
  b"j3ZGxvhiv+waA54xZFWsLIHBn+AKP+YeGGhXqm0d5M+Wv1iuLIIh/+BJ1K56RZs7CsoTQliF+9UiLE/tn+GgCX2gaBnkDakmB3AC9nNcLIRboeGQK8Sj8U/W" +
  b"j/7NCvpnuXtaLEPBBeFCCc5JbUzFFrLDkPZsS5DULEiYP+EAKd+MYUfGErXGYYJ1RWUOLEihVUqiGZtfKXeif3lbQ4KMIkkwLEntWeABeZy4p4vDUa1w5WAW" +
  b"cBtyLEgknvEEWbI8AVO7M1Ydx7xNHYTsLIoeyehMs5SihlWzxibJbC2ppXRSLEYZReFELlBNkYGCRdYcvR1qPrSWLECjq+Dsliv1l/mSoc/jZpOmjh2+LEQM" +
  b"ReBAnoW7+TE2ye6FnJ4cJ8Z2LC3F4+DBAeD7t7vwJwVNPi2PURQsLFGVieHpMbyhLu1gVD5yDiCJ/5+4LETgCeCA4f4cmUGlUyMGPJfS28WSLEVPJeANYf4d" +
  b"GKC1iVoPWrrFJUIELGlBl+GHgfniZZ3LBizTOY5H5XVYLEaIQeANIfnycZjfmuUkIu85XlaCLEqQRaRp4f4SCGXaFToojd0fAUskLCIRl2iYQfy4PJn+pk+h" +
  b"GPcYV2BGLEiQ72m1gf4AAgU8xxWcTaJFmvWyLEQmBeAD4fNSxLaz2HSikbU6MNJ8LEWUBeASwf4SDCymrkaCIeAy8zG2LEUFCeAb+Znp7jwZcSJJZa8j1mlE" +
  b"LFpv7/DpgfYEDuJg0INCq5CyJaaeLFPtv+HUqdtB0DQ5KL5cltsOYNq0LGu8v+G+GZ4dkIUA8AvRHGi8JX7oLGpHv+F6UbypIMmvwsDV93f2CVAwLGu8v+C8" +
  b"uZ4TgGSnCS3rRdLYdMtuLGpHSeCbcb4XBsDAoY9QPkbTEGeSLGhHifCbQf4CDtBqwKWhvp2XgOQeLGJHSaXXofy0P45OI4tj7ZhkugLWLGpvc+HVIftaUZfA" +
  b"1kiCIPO8MFZQLCMr8eBgVkP94odynTxqEKZbnGMoLEyvWePLeYtRxi1zPE0xKbPu0zWqLGJHn+DnuctQwJ8VWIVqYwOupG5kLEyv4+Fy2eNaT7R4EJn7a0K1" +
  b"dnQELGL3eeDHmeYSBYE3D6v1bI8hhgUsLCyv7eClueH18nmN9/7z5BEZYOQOLBWGn2jgeeSJho94vzb5ZhTNFczMLCJJ1tNieYH7R/mb6kfJhttW5Gl6LCGG" +
  b"OeACWHvbaHHKQPyddl7hTB0kLCFYGaRI2HnubBfwcy9R7hzKyEcuLCBbocIgGS/aJdy2+QgrpEb4blS+LCGWi6RI1qqH4cca3dA1kZkeOALcLEBb4+AI1ryp" +
  b"tiNUrRLvQw6NKctKLEMGb2mIE8FqvfHp3PkqkDVOxhO8LGNTk6RAKUotAadT3ui9KcFYQb4QLEhv76RAdjMz5qXspDcPSbxZlXuSLCDB48IhhPoh3uZ7VPnS" +
  b"hatq1dLALERHeeAFU1YZzDO12FDl3P3dpLIwLFL3n+EW29ztoIzq59AAyC1lFRDwLGF4ReCJ/Ky0iCrE//cVibgxLpgyLFKhAcPqgfyjo8fxypaikudyEMCu" +
  b"LGHv0cNhsetaxxR2ZoVZvlrwo6JILGCheeAXgfy9rCE6ghkFvkrDQGpmLFMQ/+E3wf4BjMglvJLaESiIaJ24LGgR0aRJRgYOphB1NVQiQfEwZAWSLCzM8eA7" +
  b"Rh4I2iB3uaojidxn2VBSLEAkBeAZnCb/FR5NIMMdbolZJXpeLCCjc+Fl7hNp2DIQxw9J2pErRegULEWzNeDGfKYCM12pgt4QvSEk90RQLBkcSeDGGeHjH0s4" +
  b"qPc5u2mKWLSELCPhi8IBmb6oGkRcw5hN5V01pA6O",
])

///|
/// `7.95k`: the C decoder's first 16 frames, s16le.
let amrnb_7_95k_cref_head : Bytes = amrnb_cat([
  b"AAAAAAEAAQAAAP///////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAQD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACG/2f/jP+a/yEA" +
  b"cwBcAGEANwAKAP7/8f8NAB0AEgAYAIgAmgD5/0YAiQDJ/5b/0P/U/9v/2f8CABgA6//t//v/8v+X/37/n/+v/xAAUgBCAG8CvgF//48A/v/p/k//jf+w/4EA" +
  b"YggrFTMR1wMfAtv9bfUC7I3qwPlT/u/7YQOXBBcBQ/7H+0//pgCT/r8C/glhESoOvgoNDeEB//Z08c7su/Jc+l0DnwnECE4ISwSa+rryB/GR9PL3k/pAAboE" +
  b"FQMAAb/+Uf2G/Jn7FfiR+04EsgV7CFULmAIV+vvucuFU5Sv04vyhBCwNKxLbDlACCfpV+XPxSu75+FABwgWRCOgPvRSlDOgHmQ7vD+8KSQluEjAd9Rd2F7Yb" +
  b"tBHQBsD4QO9s87jwF/PJ+3/8ff3X+uH0RPCv5vblZO3s8DH3b/03AVMDPwC7/6//KvxIAGoIYwggCBYL6gowB/IAxPwY/Gj1QvB98nj15fha+iv9ygHj/9P2" +
  b"1O5e7wXwzPH2+kUCBAerCjINYw6PCbYH1QzFDU4L2Az5DsoP1g37CZUHoAbMBcAE0wRkBVsE1AK6/5n8+vpV+Sn4+vfg+TL8s/sP+238ngFHBY0BS/vO+S74" +
  b"TvcB+mb9ZwLcAwz6BfT58m/s1+7U8/z3NgGEApEDLAekAPb8uP/MAusImwovCoUOIg/rDUcNkAmZCA4NPwzyBNUCjAKe/3790fnj9Rb01PLD7fjo6+t58Pj0" +
  b"1PmA/Nv+CwF4AwYAWvyQAc8EygYvDZAOSgyvBqIA5QCGBfQKTQuoC6YJd/4L+IT0PfHV9QX7nv1WAFgFGQlaBc3+p/3//woD3AQaBbkGlgi9B/kEFgrzDPII" +
  b"RQecA5ABMwGa/k4D1gVKAxsCFveP8IDy9+9G8mX1ifja/QD70PoW+IzySfa98jDyLfrN+m79CQDm/pP+H/u7/lsC/gCCBokISAehBM4AwwNF/Rn2dPtt/K35" +
  b"ove2+JABrgPlAvYCCwIpBZsG1gelCq4K4w3iDu8NBhblFaEQOA7qB4YH1ANOAmkMTwlcBMUABfEh7Dzsnuti8eXtTPAI9+DzNfTG8xP38fwZ+e71bfgm+xL8" +
  b"4/2eBOYMwRP4E50LfgUiA/MByQL/BeAGdgNg/pP4hfPM8qf1DPfw96f5MP0T/qX66fodAE4E1gNzBUEK4ws7DOoMRwz2CfEM+w7cCJUHEAatAdL+t/3XA+wB" +
  b"Ufw8APL5+u/B8ij3D/fo9aX6+v8L/PD+wANU/379/vrM+hj9dQBsBwAFbwJUBrQCOQFMAlr9svo9+Uj54/Qr8CDt5uYg7HH10PGw8LL1o/31BW0FcQbWBywJ" +
  b"MQ7xDWAOUhCdEIUQMhKdGQ4YrRUBGUUPzgHG/FcAoggvBWEEeQQ88gPuvPHM5JPiIeub85H20fiJAFT/l/yWA+cCFQCSBmcHoQR2ASoD1QX4/iEB0gWQAfEA" +
  b"uf1g8Yjqke6791wH2RIVD+H7s/Fu+in6hPiUAvACQgNlDHsO/gZiBJEK1gqxAp74ZfRi96L3R/A07MPxN/rBAbD8jO8W7LrvtvtRC3ALfwPnAVIIxg2OCS0H" +
  b"LwunDnEM0w9RHV4cTh+AKmodHwPp8WnvtPKp9eX1he8G7RH4HwNV/Dbp6eQi7FnytQAN+B/icOqRCQkephQ1B+j5jehO9f8I8w9OElgXfScuHtgSBhifATjy" +
  b"0Px3/D3x3OtE+RkGHgriDWD8HOqm7sH6UP+36xbiEfY7DBsTOwoE+27aGc4o7wYF+vtp898F2BKNCDwTMxb//O/4ogcdBp74RvqzFTUfQhY/EGL+J/AM92cF" +
  b"UwtRBNkBdwTc/ML7JAIZAhUIuwkR/q/tauX/6bfvlPebAzoEyvUE6Ebr8/Tm8JD08/8n/db5PAGPB6UF6QqzGFcYOAmOCAMUBBX8F4UfqhOJB2QL1QtkAA72" +
  b"1Puz/XT0afkQ+kTfwNY38mUAlvJm6sLla+DI5y/2xfsM9sv+JRKVDv4Cpfgn9IUHDiCOKfQeNQ2+C1ENzBCzF/AcjxnUC/UPGxm4CCb+wQYFCbP/ueqB6M70" +
  b"nvQL/wEETfaE8hD1hO4Z45vi+vMe/U/3SPRs8IXpSu7o+RX9Jvy090Pvb/He/TMLmg/lCNwI1gqNA+8CawBoAIEfcTVvIBYH6gWuCR8DHvKf8Tb9Eft/AHEN" +
  b"cAT48KbzdAeHBwDytN6o3CTp5Pf8BSsIKfki9PL7Kf6L+CH2xwA7CYQW7SBXDur8k/+tD3QbaRWbA2jus+zRAvER7wtF/T79Iwhf+abjNOGs5ZTv+fr9AMH7" +
  b"L+r/6Yb9tAN4/qn8Kfk0ALYOfRQWF7caLB6jGAQNGQsqBWv6ow2CNB8zQw96/l4C/v228Tr22f/D9jjyVvWP7d3m5e/h+o/5G/GT6HLgZuSK8zH9MP0J+s39" +
  b"iv6q79Htmftk/u4CMhDzCAH1lPPEBuEUpA6MCK4FQ/5KC3ccbxKXA2UKiBmJFX0FdgDt9/nywQrIGa79YuNF7m7+RPzN89P4QPyT8xX+RQuR/q/wg/cACWwJ" +
  b"KP1oAP4EKPvu/h0OOAiU+MH+nQ4JB5P7GRDxFh0I7xhzHiz/nfCn+sEDXPji7pXwDuNm42f6H/9j9sfyZ/gj8ozmge8++3AApwMwBMgD1f6nAp0LOQVGAsII" +
  b"HAh6DWQWCw1N/pz/rgVWA4MBEwXLACr68/7GBGwAz/qmAPEB1u4V5nzn6OfG9RkIyxI2DJP8sAEmBbb/7gHj9PDoPeuH+Y4Mxgf3/qoD2gNZAyT/F++F64j3" +
  b"nwdQEOYJjQXvBnIKTBbuF+oOdAs/CtAQDhMkBKT+3AekD50P3gMG9XTuoPQXAOsEqQBB/N3+NPjB8I3uRek+9bcEXAlBDOwCZfy/CVMP7gebAbP+BgL6CSMV" +
  b"8RGBBd4HWwceAKX7y/It8MvxzPkgBNTsqt1f8C322vSQ8DziVufq8xb1IPfe97b/Xgw9D2YP5AlTAXcK0RLIEN8NoQz4EfoVjQ75CboOBw3HBU8FnwX69QXn" +
  b"Yu4C+4H6Ivt2+2rlBtpg8AkAMvsq8TTrwPOk+gL76fw288f6mBLgFccN6QQmBLAMMwzHD5cQSQeaCewKlQU6AGb9bAQOBdH+5AEqAp0B6wzwEigNhACN+lgC" +
  b"NwEu/qYMgg2eAnAKxAWu9IrydPmP/0D4FPRK/zP6avXN/mn+uPr29aD54gG7+pb2Cv6pAHID3hHNE50B0PT++Br81fZ+9Df2XvNc800A9/lr4/LrUf2c+nrz" +
  b"2OUE3SHxYv8n/GL7I/9TCcMNtw4sFHkIQwLaEJwXdhT/CocNNCC4HJIS0hTcCdH8+P0ED3IUdAh4CfUJhv1F/AMAk/ly763xw/pC+HDxC+wO8VgEUQrb/z3w" +
  b"vekt9dj/sgBi/g/34fe9AbkHygbK/VcAnQmqCAoIHAOo+U77GgVfCbIFQQKJ/3v7SPeQ9L719PxxAi8BR/xV8SDrCvnrBn0EPvvd86P4yf4D/I/6LvqX+jf/" +
  b"qwXNB6cCp//4B7wL9AWEBqMGGAB1AQwGpQKDAEQAQwJCAk7+UQPPBMYA/wo4FJYJbfeb8xz+M/4W9jb66Pxi+YP8Avvl8z/yp/iR/qH5rO5N45HmK/6oEd8U" +
  b"rRcoG2sUfw67Dn0OwBNWFBANQAgYBr0Bq/4FBicMtAnwA8v4PfR59zX2Afb/9tXvpOqP6ujreezO8zQEuAftAm4AsP3JANYDTgLyARQA9wGWBAYEVAUYBHQF" +
  b"XwexAncAavwG9e33NQJTB74Cvfya+PTw2/eCDpkS0wJF+Fv99QKR+5z5SP8D+3L7ugR1AEf2yfdZBOcJmQKGA94Gd/+Y/l4Dqv0w/EEDGgeTAx3/wgN/Awz+" +
  b"tQuxEzsHJAGAA5oFSgKt/24EBP709OX9mgJH+hv4yvz99mrspO/A8hfuqe/V+E//m/rI93H/dgMJB0oKAwrBC4IQoRXnEvYH4AllGkccGhbWFooNe/+i/74H" +
  b"FAa8+kv6C/8l97XxI+/H7HDw0PS38lfoNuVG8GL1dfZV+Qv0JvLg/csFXv+a/NEFnwkOBVwEEAenA+n+VwNaBU0BXgPxBcYCmv5e/OT7wfvi+zr8XfZ98ULz" +
  b"0/UE/vUJlwvPBJb/kAOQB2sBIwFjBIL9GPur/339Evo7/mQFgga8A/MGcgebAvUJqQ7lDqMS7g0OCjgG1/xaArYIKA0aEmkI3wESAuj/MASAAmL6z/AI6+nz" +
  b"Z/Zj8jD21PaB8oTx3fcc8PrjWvDT+2f4k/b798/7IAFGBtwM0Ay7Cf4RsxaMEKMKYwtjFlQZ4xQmE8QEXfzdAjcKPw3CAzX+AP9p+nX8+Paf6f7rYfJX8Arp" +
  b"uui/6ijpdO6w9aXzNfJm+3EA9P1vAlUHlwU7COkJ8QkCAC35qAq2F18TQBApEBQJcQKjBt4NkQTY+U//QAAj/Sb/Aft68pb4awbyAGj0qvaF9wHyVfau/BL4" +
  b"S/MT+7MBbP2K/moE3gMrA0IGzgdN+l36KxCwDmQBJP4rA88P1g0aDVsRig2gEAMOOw6aC/X7cwHsBXH9Tvm0+nf5mfMo/UcCNfYn8371ePU5+OH1EvSw9yv2" +
  b"WPkq+834//8cCOwQExPjDPEM+wz8Ae78g/sh8gvvlPQt7pnowOqW6CTobux48crnXuIQ8wz5KfWS/UMBIwOBBwoL1BCiBBP/3AsyGMcgNhmkFjMWLQ3EFG8Z" +
  b"WhKPCzMDaAgLDTgIXwMH/jD/Q/y08Qbz4/Xp8SzxrPT59zf3LPbi/NcBOwbjChEHcgPjCIoPfA64CcgOjxJ2ElISvQ1YEDwRRAz8EioQfgfHAycBOwLe+/z1" +
  b"1/dc8uvud+6W5bTiUuKa5bPrv+ng6BvkReMf6mLq6+347xruq/Ui9tvx4/PD9db63/tf/tMAwv3NAv4JrwgpCskV+xpbGIYWpBiBGbUc9iKfIQskRSKbHHQe" +
  b"ohsbGBsURwxaCsQLFgqWBMv8Jfkc9VnvX+tC4j7bDdw522TZU9ll2u/dFd484HrmvOfF6TfwN/ru/QL96QMbCTcNgxMdFbkUcBJRFikfjR4AG3odWB3CF+QT" +
  b"IhVHE6QLEwdTBkcHMgTe/mT+iQC2AZAAL/4S+dD09/Rd8dvtxu2b7P7sT+wy63/tdewh7C3vv/DM8lP2wPaO+G77Ev2Y/qT/AQJyA/UCzgPdBQ0LZQ45DDcH" +
  b"yAN/Ax4EOATfBAIE1wEeAQkCCQJk/If5f/ZO8+z02/ZR+S368/hl/NL/eP4Y/scD9AeWAkwAdgOnAXb/dP/G/cb7nPu4/uIArgFYAxsEfgV3BM4CZwQpBDwB" +
  b"2QH5A1AEjQP6A0QJIQyGCUkJegljC5gS+hUzFrYWwxH2DRMN+ghgCTUOxg1bDrIOVhCPEyARtQ2JCcoCc/5d+P70gPd/+tz8g/v09331HPLM71Tx3POg89/y" +
  b"OfTa83fx6/Ht84fwwuxW7rHx5PFY8nL7VQFt/UD+7/xl+Ij17fIP+eX6cPfi+1P+BfvH+MP6gvx3+xX8Wv5z/mn7mPpv/dr9+PnB+QP4PPP68yb2x/O/8nvz" +
  b"4O8L7XLwV/No9FL5m/8xAjACXAT7B/sNWRf7ILEnYihGJvclEiLgHe8g7CS8JKAkByc4KO4k9CCaHDgXvBHqCHz/8vp2+W/6VPW37u3sBOis3zDdBN6Q3t7g" +
  b"QeRM5xbmpeW16L7oj+nq7dvwS/OF+jwA2AF3AkgDagWjBLP/ff/YAOgA0gamCwcMjAviCSgJjQc7CmkQtg8dD60PmwyQCpMH3wbFBiEF0gRAAvsAtwFtA2kE" +
  b"5wGa/Xz4a/OD8O7wffIi8NvuIfCW7abpLOjt6FvqX+/h87r1Lvjp+A/5Y/l095P31vjP+6cBSwN5BPEGqwYkB2wG7QQuBxYIIQgZC7IPnxFyEWISCRQ7FEsT" +
  b"hRNaGawawxbwF+gXoRRFEW0QuBGtDV8KzQsZCYcDnADV/937e/an9XvxZOux7HLugO0g6ynp1upr6Wbo0ezI7Yvt5e5V8LHy9/Ly8pf09fiW/3UCCgQEBywH" +
  b"NAf9B9IHawlwB7oHkwp+BkoGuwYgBIYFOgI1+Qn4PfgS7Vnozeyi64XpVum45h/k1OJy41bnIuj16Drt9fBw87H2UPuS/sb/SgNICAcL9gz0E1IZgx0DI6cj" +
  b"1yFQIksjfCXgJSYkOyOuIjch9R3AG9sdJR66GQAX5RQ4EqIOUwkBBhAFJQEv+Sv07vQk88nxIPEU8BbyK/AC7n3wvu9s7yvvNPBw9UX3UPfL9XP1dvgT90r1" +
  b"EPcD+L73Bfdj+Bn59fe++ID5QPmL9vn1Dvmh9Z3yGfY/9871nPVB+PD56/iR+hn87PxTAkwC2v+JAwMDkADc/Qz8BgAp/n351fuh/az9Tvya/UoAVwJGCa0L" +
  b"EgvbDdcOqg/sDqwNKg80D2sP0w72C1gNMwzaChYMMQqACp8NMw2SCo4KaQrfBpoERQTQAOT8Rf1o/Wj7UPrC+Qb6yfh39gDz/vAT8jX0QvY397753fql+HT6" +
  b"gfoJ9WX00fa69tT1+PQt9TD2xvXQ8hvzavRP9ZX7+f9nAOkCpQSyBVoGgghTCzgLbw0kD9MN0g7ODo0NrA3dDikOOQ1mENIPLAzmC+YJ9ATAAWb+3/gK9mH1" +
  b"K/IB8pTybO8R7NbqqOmG5tjmjuni7BvwjfBj8zr2l/Wv9kr4s/pg/g8CQQUzBxsJOArTC4INdQtcCp0Msg1yD00RORKREu8QIxLlEd8OiRA=",
])

///|
/// `7.95k`: the C decoder's last 16 frames, s16le.
let amrnb_7_95k_cref_tail : Bytes = amrnb_cat([
  b"UgCSAJQA2wGeAHQA3f8U/y4AsAE+ApQCSwGMAU8C2wACAHr/9/6h/6z+x/4C/9/+LgHF/3X/agD4/9cAUQG3AEMA5wBBADr/Of/6/vT+Yv4Q/g/+gP2f/Y39" +
  b"Uvs/+xr83PlH+hj7PPvG+j36Ofwa/Jr7MP2h/Y//JgAGALMBHQMzBHUDnAQuBdEE9wXEBEsEHAUSBU0EXANaBUEGRQWDA9oB4AFjAcv/vv7Q/pD/Rf85/rX9" +
  b"DP6T/ln+ffyD+7r9nPyY+hD9dv43/TX8u/14/kX96v3F/lcAAgJ4AZIA1QGjA2ADsgL9As4DDwXhA5wCTQS/BDADqwIkA+EEWATZAq4EjgU/BKABs/9W/zz+" +
  b"UP0P/Fj7bPwd/Hf7zvq6+tH7Zfqy+G34F/qX+sP4qfqt/cr+n/6i/hoABwH+AAYBfwI3A70CpwO0BYQGBgbqBX0GawaOBeYEegTQA18DlAKhAl0DEwIkAt8C" +
  b"LAIDAlMAm/4o/h//Jv/x/Mf8j/0+/YX8bPmv+Jv5ofcR9kn2EPdW93L3s/eQ+LP6zP26/jD/xAEcBIsEpATlBdwGAwczB70GrgcwCt8JnglpCcMGeQayBSAC" +
  b"bwCkAOgATv++/Af7Q/oC+nT3BPVy9ZT1IfUA89/yq/Wf9pP3IPi8+jz+7v+AAZ0E3gd9CbQIVAiECV0KwwmrCN0ILgpGCuIKCwqdCQILWAkeB48FowQjBFsB" +
  b"hP42/Jj7g/oZ9wP2dvXo9Cf0nfKx8r/yP/Pr8pXy+vMY9i74vPkO+678jP8QAgUDxgNJBeoGPQi/CMsItwnoClsLRQvzChsLUgtVCscIbAe7BtkGyQVsA5QB" +
  b"DgEIALr8CPr5+NH2PfQJ84vynPIC8x31/fef+Sz7j/6jAksE/QJuAwMGDwdbBlMFBgcLCcUIhwm0CYEL7w1EDPoJPgnfCNoFhQG8/9b9R/yw+cj15fTR83jy" +
  b"dPHn7xfwfu6w7Qnw6/Fu8xr0MfbQ+T/8M/7H/z8BjQS2BvkG4wfGCDEK5grFCVAJNgoGCq8I/Qn/CusJ+giRB/8GBQYdA1kCwQMvAz4Buv/W/pT+tPxF+Gj1" +
  b"Z/Me8LzvzPC98FjxjvHq8+v2Fvi2+Qn7Y/xD/jj/vwDFAhYESgUNB2gIUQuIDVUNahCUFfUWBBabFA8UghNTEOULdQvpC7kH8AKd/3f92vpZ9bjwqO5F7J7q" +
  b"hutV7Arvg/FK8lP0pPbJ+HX6ivoR/Db+WP+MAJYAFgKkBSMHgAdgCCIJEgrwCnoKqQmyCL8H9QV/ASH+efz7+ln4xvXJ97735fEE7abryu568RrvW+9x9Cn5" +
  b"K/sE++X9oQJ9Aqb+wv1TAZoDvwJMAoMEjwjdCw8NdgwqELwUuROoEQIRURH8EC4NLgpmCg8JzgbiBRcGkwVsA+IACvww+A33R/Te8eTvKfCJ9S/7O/+6AHEC" +
  b"xgWmBmAFiwNbAjYCCgHM+3j3VvgF+Wr5Zvly+Uf9DvvS9+P6K/3G/dH7OPh4+SP8LP+AAeIAWAOEAq3/fvy296f3yvfx9OH1RPwXAl8FUAf3CMkLmwzCCgUJ" +
  b"NQcxBjgJrwkKBz4GuQZaCnYK/Qa8B/cHugcwCEEGagVbBM0FlwQX/m/8g/9cAHn5qPYR+cHz5Ow26DHpz++L7/ftavHJ9rL7h/qI+Q79ef6t+n31cvam+o/7" +
  b"0vrI++v/pwWTCAgHdwhDDZUNLAuiCpcLPAxaC4MJqQdEB9kINQmmBkYGFwR2/Z33cfNE8zD2D/eS9xv9+gI6BlAHYwZXB+IGuAUKBKIAKwCwAhQF8QP6AQED" +
  b"9ggEDNEHPwYhB4oHMQhrBcQB6wEvBs4FKf5S+q//nwOI/T/33vII7TPoJOFs3zLjgOYp6KPp+O+P98T63Pw5/tD/kf0b+Qr5Ovt4/SsAYALkBRoMVREUEd0Q" +
  b"JhExEFATCRWEEUYPKBADEHYMhwhyC3gPrA1RCRwBhPmL9mnxzu/e8mv1AvuBAXgE3waRB7cJKgvhAkr7QPpm+G345/kw+t39ugBiBF8JXgi1BaIFPgKe/c75" +
  b"R/n/+2f7j/mv/KkBPwPeACb7zfAb6OXjDOKk4tfljepj80j+jwRdByAJ1wnkCOICzPoE+Pv52vxe/2YC8wmzEpUXoRYVE7UQ7w+EC1wCwP7VAIUDXQM1AfgC" +
  b"sQdXCLUEtgGk/GDx3+h657fuMvfY+Tj/qQ2kFxYY3xKlDHoJgATf+5b1r/lKApoHpAevB4ILVg6ACv0B/PwV/Vb4le8n7EHvS/YX+i/5hvucARABMvqB9Ubz" +
  b"1Onv3A7ZkOO29Dz80P51DJMf8iQBHZUT5w+UDc0Dk/wEA3cQwhZRGS4cox4HHnkV3QlWBF0GYAPs/c8BGQjrCVkHIgHO/dH6pPPe7KvnDOel3rnSitKL2djk" +
  b"lesv7TzwbfYd/Nn58vWm+JX8+P0S/SsDgA0gEOMPdBGIFC8TiQxcB1MJAQo0BNEFuwzAEOgOHggqB0MFVvxX8xXw8fHm6D/btdof5XXw3vLT8/L7fwQWBrcB" +
  b"QADEA8oCJP19/KQERA2jDgsP7BPiF04WvQ96CwkQDRa2ETASuhyRIWQdoBKfCzwKYQLG9vzuH/A38B3lNtwe4HXpCu+a7SfvM/Vv+QT5C/aK9yv1Oe/d51Tl" +
  b"E+5O9ev4sgBzCEAK2QTwAMcCkwWJAjIAjAj0EAkTjxDVElgZZxVBCpcDDQP8AEPzpegP7UP2l/9fA64JeRYMG+0WMxBaCywJjACs9xT4LP7vBtkLaw2gEfES" +
  b"qA/DCEACZwMCBEcABwH4CYoRBw9ICqkJ4AaP/rrzZe5O7fTn5Ntj1BDafePd6PvtLfaN+Nr2x/be9Fr1C/Vt7OzpRu6R9nn/NQGnBbUNrBE2EFoKiglSDrIK" +
  b"hgUeDCkUThS2EZAQ+g9PDLME9P3b+hL3KupA37vh6eo78gj1a/uSAigDtAL9AD8AKgF7+xz4Qf2gBTINKg9pEFcUrBWmEfIKqQrXDSQL9QcmDrwYqBywGMEV" +
  b"mRSzDeYB7Pat8WbvkOClz7zRn9y25SPqEPIW/kX/2fmo9u/13fYi87/vtvEB+jAEpAdhCdkNhBEwEoMMFQv2EZQS1w7CEK4WbxvOGAoT0w8ODhMKFAHw+Vf3" +
  b"A+6t4fDhzupN8Qb1k/3uBj8GWP/6+P72xfWJ75/rMezG8h/7vf/0BXYLww01DpAJcggkC2oIwQTxBgsNrhCXDyQLWwflBQkBOvlz9MTzru9W41LbgOLN7b/y" +
  b"W/jwBQEP/AyxBXQAFwDO+0n0zfCM8iz6OgDGBeAM0BBwEmUQsgthCx4LIwYhBDAHjAwEEE8NkgtpC0oGs/74+MT0vOtq3gva/OLq7NHyZf1nCzARxw0VBzYD" +
  b"kgB0+d7yuvA49ET78wANCIsOTBHvEXQOzQitBiEE/f8iAIME4AmrDdoPKw2pCRsGlv5W+NP1m/D15CjaEd296cXsRu9h/8gMywyABjsDDwb0ArP5WPYJ+L78" +
  b"fwSzC2ATiheqFgsV3Q40B6YErwTcBEAHqgskEUMW5hi0Ez0MjAaW/nb2xPGC6inhztsN37DoOeu37U35KwB1/7z8Svy3/979hvYh9ef3mPpNAM8G3wxJEC0P" +
  b"TQ6HC9gFJgRcBRYGZgd6CXAM2A98EuMOyQjPBUwAN/pD92rvmOVx4CDjn+v07uvykf3KBOUEMAK9ARgECwFI+MD1Xvql/Y4BCwh1DhMRqQ7dDCANngktBksH" +
  b"kAj2CHIJGgpGDY8NZQpOBhwCHP8r+Qj2TfW96D7c6dwD5BHq7ux19UkDjAfWANb+LgPgAk77m/T0+Kv/o//MAf0JkQ/TDTwKrgyLD5UKRQgADYQOkAyEC3UN" +
  b"xg6qDPoJtAZ1AxECkP7g/J74L+zm5H/m+elD7TTzFf1dBEgDZ/4C/l//cfxM9xH2F/qs/YT+ZwPICpgL4wgTCE4JUgg2BLAETAiLBxQGGwevCIII8QPDA5YF" +
  b"xP84/fL/9fzX+P/xUuYU4tDkI+gl7+v4pwFNB0cFav6Q/EP9E/sN+Lf47f5zA3kEjwo/EOIOEwyXClALngmsBb8HQwrLCGgKEAyHC8MLRAjmBZUFlwEGAccB" +
  b"x/yC+e70QOoG5ZXniOut8C73hf7HA7cBAvtz+UT7Q/pM+PX57f9uA34D4wWVCB0I5QW0BJEGhwbDBIwGZQg9CLYJYwsgCXUFVQShA/MBGQD4/A786/xg+9r5" +
  b"Ffkd873tNO9M8vj0cflT//ICzALvAEX/4f5i/1L/5//wAaIDJQWbBWIEnwQVBXADEgNUBKcEmwUAB1EHRgnNDB4LygXLBc4GvQR6BeID9P+kAKX+j/qj+Zzx" +
  b"H+iV6Yzs7+0n8jX4rf5XAFr+if4+AX8CxQBcAN0C6wOAAw4E+AThBBAE7QXxBgkFHgWaBVoFtgUhBbwF7QiZCBAEtQNXBY4DlgQVBcYAnADsAKr8P/tq9hDt" +
  b"UezM7lXsR+t18Mb2rfiN+dz71P/2ACH/kQBEAlUC8gL8AxkFXgUvBQ4GzQcACMoGNgeEB60IZAnHBy8IwAoPCQIF5gSUBUYDmwPnAwkAbwDgACn9gvpM9gzx" +
  b"OfBD8fTuje+B9QT6mfwi/uX/KQPBBQcExwItBAoAM/7zA3MC1P80A3UEvwWOBSwFewZmBS8I5QiJBewH+AlZB6MD7QO3BA8BWQKL/gL5Rv1Z+1j2o/Vp8gLu" +
  b"1e3j737tZe/s9q75H/3TACICFwF6AUsEowLLAdsDKwNwA3kGxwbtBToHIgisCusL9wltC2EOaAzDB/8HPgXVALgDggGe+1n+RP9w+l73HPQt7hLtIus95q3p" +
  b"Zu8j7nXvGPZp+1f7U/0tAdoAoQRtCtAHGAzyD5YHHAu2E+QNIAtyEpMTNhBBEFoQcg1oDHoOjwvyB0MKmQplCUQHKwbMBcMENwOR+hb3bfro9YjvDe197Wft" +
  b"SeuF7JbvJvC08eDufe/a8lDv6e3Y8I/xVPET9B/4tve197j5Yfsp/Mr5vfe3+tv8MPrc+28ClgKgAOIERwmBBxgJYA2HDhgQCxFzEGcRWxKLEAkMPAuaDLcJ" +
  b"pAoODrwMLgsODPMNPAwcCUQLFQpLB2oH2AUuBu0IAQgeB8cIawdoBTYFQgSTBmoF9gEUA84B3/7v/NX63vlD/Ov97vsj9pj0tfXw8tjvve5d6JvjReWc44/i" +
  b"qOY06cLqtu0m8ff07vZK9Ij0n/lu+m75c/wRAYsF1AWTCHANigySDbsPzhCUE7URChFiEnUQnA6JDOYJOgwaDsAKsgYqAzcDYgHm98z0lvPG6aHnrul65ZPn" +
  b"Ve/F8WjzF/j4/MkA1wO1BEYLJxA1D5URaRMFFm0X/xNmFX8VNRHCEDgQcg15DRgNGgnqAQAFBgosAZb4D/co8lzs8+c15evcWNMW2EXYss5b0y3bztsp4Bbm" +
  b"T+4m9XjxIfZGAWMBywNDCrsPJhYIGCcc6SFNIY8i/SOcImgj5x5kHqolZCJKHB0dNR0uGJ0RBw/RD5QKpAQtA6r8APmf9hnuoOsz7X3oXuae597m0ejn6K7o" +
  b"W+x57RXwTvQa9Yr56gRzC7IKMA8kFRoRjQ7QEQES5A7qDn0QgwxiBsIG7QdSApb7gfqS+w71IvFC887ugOgs6C7mZOEx3zvhieP64kzl6umz7R3wWvDp9CL7" +
  b"Uvzb/kEDJQgTDIYNVg+HEkMURBTOE9QTiBW+Ev8PdxVjFV8PwxCxELkNQhH/D/AImQhWByEDHgBG/Wz9i/0C/V8FZwZAAk4H7Qf+BawEpQDLAroA7Pmf/Mf7" +
  b"afa/+U78Wfsb/TcBmQFu+rf3lvxy+WzwPPFD9obwpOz48b3wJukv6Wzlbd283vjfDuA55PjmueoS8HHzgPSf9xT5O/re/tP/Yv/vA3kGpQZ/CPcLEQ9LEjgW" +
  b"/hjmGHAavhtEGw8fHiRSIvohgSLUHiwksCNhFtgWQBd4C/IIsAfbAtADmwMjB68HtAGkBS4FeP7n/rj8fPWk8jjygfCI7s3uvO/+74rxJPOw9Qb2kfVM9sb1" +
  b"QPaQ9VH0CPYi9gT07/KU8g3wL/Cu7yfreuy/8uTzVPgP/oP/FgTeBV8FmAj+BUgEPwaBA4UCCwXSBaUE8QpWEHYMrQ7cEoQPjw6bDgcO2QthCMoI+wVXA+YD" +
  b"RwGb/b744PXY9IryIfbo+GH32vt7/vD+HgEBATEDXQGGAEYC/vzh/eL+9vng+yIBawEvAFoEEwiFBtcGCwkaCbwI2wcoBvQD3gE0AYL9Xfdo8KDsIuuq5GHe" +
  b"8eA95fflG+uS71PwmPgx/Tj8OwHHAmEBrf4l/Xj+Mf1D/TX/dQRsCm0Kgg62EGMPKhQAFCcQ2BCbD5MNbgyTCekHxQF5+0wBgf4J+0AFSwWeBEEQwBOSEbgU" +
  b"rhhkFsgQxhTtEsUHXQj6Bzn+Uv9BBIH+p/wlAsQCO/7X//QExf0g+QX9pvXR7uHvAuwf5d/fCeHa33rZxNz84Hjh2ucp7XbuYPSZ+uX7Zv6oAXMDpATWAmID" +
  b"QwR/A34DxwPZB+0LeAupDBcOOg5VDrwNBA0TDGoKugi8CIgGSgSf/7/4Ivjn9TvxZ/Y++ND28v9iBrAF3weLDJENMQlFDCoQeQg7CG0MrgV6BCEKpAo/CQoL" +
  b"GQ+xDGkJEA7gCV8D/wPzAVb7cvfu9/7y3elQ6zPr0eJN47jmRuRg5PrnpuzS7VbwrPah94318vlX/MP5WvxK/3n/TgL1AmkFQwgCCBILbQy1C20OdQ72C8QM" +
  b"LAwJCnQJPAlpCLkH4AfvBwcH1wblBvYFvwW4BeoEggRABHsD/ALnAp4C9AG6AakB7wByAAgAw/8W/4L+d/4U/rr9dP2G/ZL9K/1H/a39df0=",
])

///|
/// `7.95k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 4 and the port 1 LSB off; tolerance 5).
let amrnb_7_95k_fate : Bytes = amrnb_cat([
  b"AAAAAAAANwDU/28CbfVhEbrysgVV+TAdRPAgCNP22AxV+Wb9uP+e/wYAd/4aBRsCLfpF/a4KBfEm+5P44ws8ABj95uadEAPuoQQVD574fwPp8R/iBhi36zwT" +
  b"UwubA1cYafmVDvUPhO7e/R8D5PetD5TvLB7D9s39Q/5F7v4EnfA++5z/6Of3/uoOqQCbAdTs5An69QL7lQUu/mn+1fYn/JISw/q9AXv7yf51ARz+K/4FBjQE" +
  b"XwdF+N4GJAHA8vYHI++a/OT7IwHlDmL6k/YmEwrp8Qkj/bMB1g0o/ewQbuwyGDD/cgPHAxvkwv2aHD7b6QNHE9vtEv3fBNL/rgGGCbIOHPJY8sP6x/P7IDgX" +
  b"QeSjBK0Pa/Pp+BYIoRSx7Jf0uwZy41IZJR4U8Er1Gfbc/dcOMw139tT1ggjmC9jmOAqLErn36fvx9bf7IAklF3f5NfX++ZT7h/+hFf70DfO2//gQq+usA7cL" +
  b"zgAF9EL9H/6D/r0V0P3r+oLzxQAp+DMa+Pxm8Bz5UhH76Sb/UQ/nA8vyhgCj/ib8pRH1BP75IvdUBIP5WxTzAmf9IO4HC4XxSf6dC2cHRflY/LP90vyhDkkF" +
  b"ZP4p+kL+Vf56D18DGPhn9OYKRPvX/aX5EgZ3/LH+Rv8WBM76twBDAgICdvx996QFvgE8/sL4+QZ8/i4EufjTBSb9AQLw/IYC6PrKAkP/GwOJAFj37AI+A5X7" +
  b"NwBw/3kDowVZ+kP5gfqqAw4EmvsT+owB3/nQ/pL68/yUBa4BGv5n++QAev4EAtn8UgZi/tf8EQGLAcAEgf2d/9oJ2gGS+ocALwALB8D+OvzuCe8E1/kcBLL6" +
  b"YweB/MgC5QjpAsH15AEq/04FDvpA/voCpP5P+sH9D/+fAuEBLfle/X391v9SBPT9DQC9/QX7oAGk+qoEVQEE+ysCk/tMBMb9sPdnAdIGNwTM7Rr5eirk8t3b" +
  b"S/eUGpYWavuu+PQA2f5Y7wMNlgjA60YEfBdSArnvB/KPCYwOy/GT96gEyQ7R/o/3mP+qA038SAe6CHvz3PgfAeQD3PvP+GgQVgBD/cv0EvxeDqLzFQrbDwb6" +
  b"kfpA+LgGsP149zAOqAUH9Vj8zQPeA6fzKf1jDPsAMvUz+AEHJAsX+yAKDQqk+876UQAoBAH2qvhID8wGMfdh+Z8FhQnX88AEpwO+AGP7H/fxCEv/9/Q0DU4M" +
  b"mPaC+8P6Ogz89ib7Zg1h/xX8pPf4ABACvPWUCVULE/wN9xz92gdlAqX1mgexBGj5uPbfAaMJ2/pO/poC9QOh+YQAaQE6ADf9eAKm/xUAT/1eAbEAs/79ALv/" +
  b"BgJ//3YDbwFB/Ab/RgGJCBcBfvuDA+v8P/2pASMNjPrh8SwC/QXhBhX8JPVo+Xj8/AYdB+wAVv91/vn9FgjS/Yv6Uwv+/R8FU/hZ9iwFQfoVBVn9AfhyB13+" +
  b"avsgAXsASAX3CB/1LwXX/LAE9f0vA24GxfxEBGj3DQHf/20BPgLq+AAEegZ/8a4E9gF6+zYIfAR9/3H0Zv5oB07+4fo2Ai0Ajv1q/PYCOPNCBO8BtPl7B57+" +
  b"iviNCjr5Ufc/G7z1W+4VBO8F5QOs8KsmaP7J4aIGsw+ZE38Hze5j+sIL3wLQCpDyffRfBhv6jP4R/mTajBKLH48G2dcd9GEzKwsV9iADVgy06/AlDvf/p9cO" +
  b"7T0R6mHuvfuw6CAO9fLPBzna+BbzEFEGUPMg9D4V4vK+5i7w3xcfClMGtffbAG0KtAQv9W3/xuYr+kPU4fBz9tcK/P17C/8GP/JKD3/2+gqg9pkIPwBT/uYF" +
  b"PfDMCPP4xxKi+cDxwv1+DkcEy/PG+BX+Vgt2B6oDQvOg+o0NfgJu9Rz8OvuQAx4McwP78lb3PxATBVD4pPL8/+UAZwhfByD8yPrJBY8GzP18+ij8mwUaBZr+" +
  b"GP8zAMIEGgBY/S//m/q9AUQCOAAn/TwAAAWS/yX/HP/hAUUCkQM7/fP/swBcBKQBUv4dAecA0wNp8wECqRAx9mj4o/LqEBYLh/zq8O8OPgq26QX6WPvMFZwL" +
  b"C+lYDi8RJRcY1ZsGeNVnFtnL4PvBAyYoohsl5o4LUu6vE2XN7wg865UpZvLoAlIPCvqOGAvKNBUr6OcdKNjHE9kAZwmCF77ifSCd6NQO6sq/GH7vVRUJABIH" +
  b"iRI98dMLT+IsGIPeUhui4qwarfLdFPfzrQSqCvj4OxIE5wsO5OKgHQfkfxSk5ggeb/bQCWHnlQlZDHvnFSzK+ertP9x9HL8LLhZet+MZevxWDtTrbwNv6X4Z" +
  b"F+dqII/fJf8m41YiEeht78vm/Cra9IYGYunDDTADzPxWEQYEqfkJA0ER4ABxCFbfiSWm77QDN+1DE0Tz2gP98OkT2eSGCd3qtRuD6X0BhwAME4zqJQNN9doL" +
  b"Ge5PBuUEAwc66vL7eQegDuPoJgrf+EUEaQhM/LL7UvzzAqwWwQXn52UAVAZYGonsPQKC+owVk/q5Azbp/Axm9oofwP0k7yn23wa+D4LxjPSxDM8LSQUW78r4" +
  b"LwKyA14LiwL87xr0cw1ADqH40/1d/yMKiwbl73n+0f17ACMQ/ewTCpD6W/ogExHqFQ3H/Lj7aRCF+h/1ewVc9boQmf+G7toGSPs+/LMU8PZk9q8Cvf5KEQH1" +
  b"ZPNvDGH8LAfP/tH3rwAXCvP02RFi5IsF/REI/ZoEAPF39PEWseqnD+IExuTuFrbxAxAxAYDgKRQsA3H56QSs30giGvrh+0MOzOcfBYgGHQGsEYPefQnnDY78" +
  b"TAXG5MgLuAeW+rICn/dG+4YKqvMRCvD1JPgcEhID5Pgb98r9phCQBg302AUl/20H0whp/R31tP+AA18DtQPc8Kb4GhU1/LIDGf3F85oJvgSb/kD/UO84DqoZ" +
  b"7tri4sMfhhrE9gAFm/fLBV7nqBf83lARfyDO8Jr1/wtI5HEQWhhJ7cv5Mfb4H2LyKPeSBAX7hAA4A3HjtAiWEkEFFfuN7L395AM6EaQIFeG4/Gcj/OJWBuwF" +
  b"ZPg5Biv2l+1SBn4GaAqR9Mb3AwBg+OgZhAT083LzWQpcAZr33w1kBnvs8gO67gz7IxdA+YT2vwATA4T+oAWTDAn3U/GXFDDwLQBcFNf5OAIb9Ov2nwE4DNYH" +
  b"9e6ABWD3HetfHRoLS/Uw93P8o/+aCHAHF/3/9/sIP/GUBuMQ6fb1+cMCn/dD+/EPpAPN9Df5C/1H+iETcAZD7jsGrwKM+9cNO/nuA3L3ZAORBVn38f8LB+j6" +
  b"FQZT9z7/kQTh/ej8sgJDAw78hv2J+sgKcgWBAMX+Jft7+7EK7gVH/swCDwDYBMYBJPhMB3bxKQtj+QgFLfXj+mEFBQfN9bj/MP7ODLEDv/h0BWsF3AJOABL4" +
  b"WACLBFL2IgI6+rH6KQKf8d3vlgV5AS8Lz/6OC6/5BAwB/ygTEwTbBBgDdgDb/X3y0/ik/8EDu/e5Cp/89+10/CwCQgMRBUT7d+3IAI8EcgQu+s7wu/5MBgoR" +
  b"AvvuAiAFJQiiBlX+tPsM8/AATfv1/TMCaAgrAQv9pQaOETvuxQEe+Cn2mvMxAeYF8PiQ/NQWDAjI+c/wFwO3FxXtCvEnDyETP/nd8XP8OBjk9BUHDQYI9578" +
  b"6Q+xDkzvZfaMEdgPV+Ut9Aj48h6mBcnuYQm7AmcH4PUu9EUJR/HMFPoIpu1u+oj4HxNTBy/qTQfUC4z8lf2i+hUFkACGAMsEf/kt/UoD8Aj4BZLzjw/hB1v9" +
  b"9/OZ/7YGe/Ze+4cN8AEOATrzEwVyCTX6ogi9CZn+0Per93gDWgEz9Y0Wlv9Q/Fn6vfbWFJz2N/3OBPD5bADz9On2/Q79/tUI2QC+/BoEnAD6BJD+zfzYBqEB" +
  b"zPYL/qMCYgn3+i7+Dwsi/5MCN/j/AfEGWQvv95AC0/x9C5sBavv8/Ab6SwyQBG/4QPUm/s8IOAiY9i4A7wbUDs3+WvofBywPPBCv9BLyxwZVB7P8Vf/Y9iwF" +
  b"8veNAyIAD/YoCKv6hAKF+pAMZAaq+Wf+2v5aBln/zPfD/bsEvvbGAUX78e49GvnzCgUDAQwMexNe/ukJZexw+XIU7+JBA6D+sxIcEGoD5wk9Bc4EaxjM9L3j" +
  b"uwOL6Y0Oz+zL/10DF/R8B9ECoAS9G8D9vgng7foDl/Q7/5wCdwvK7mr5ifwx8WL7tP64DnX0FRZa9SbtTfsUH0D31gQp+XYGzud8BSoSCAsh/pL1yQsQ7OgI" +
  b"lvEj/qHxDgqu/dH2MASBCNjzehuPC54e6/Rk/Cf/JQFyBGj2e/zT9eoVxfloAhz2lQ6u/msDHfeK+y4B0wnnA6cGdfY2AXb/SAMB/iwCJvbR+xj+B/hW8yL0" +
  b"6AHw9gwIRgy5/1EAjg4oBuAGefnCChnx6wZ/9D3qIP0REAMJmPWu9WcJPQFLBbwPMvJo+mkHhxPd7yH33v+dCzn2zQLm9NsBrwYY/rP0FvJ8+Kf3KPklAY8A" +
  b"vOeFEfYDmgVxBvgDjwIfB5z/cgaJ7xMG7Ph4/N35z/4q/9v+IwHfBJH/pPWWAaUEygCj/0/6lAc5CeMEVP6i+GQIqgOfC8vxbf1N+M4F//6f+oHx0vy0BOoF" +
  b"0vwDAS//zQcZDD39Bf/E9DAGUA7bAYzlXwW+9qAQMf0E/8YLkeuy/Pf/IwVq/3j56QfjBVH6JAEe/zoRTwNAAR8ARhJr9n0Bd/TB/1v8EwBqAKb+8v+S9OkB" +
  b"gADuA/b6JwdSEEj7afgpBIr0dACoBOL9zPd4CeX68v80+PEBjf1X+6oDuwY89CkA3QjX/sb1lwlEBaD9aAew/cMENvk7Db72IP6c/64DoPb+Ay79dPgtAWID" +
  b"GwfsBrX1VfmO/ZvytQHQC3rvovtI5zcdjQdF7BnjsALJJYX81PNf9b4LHTX1Cw7kouIAC8IWHAsK/XjhHf6CFEzzl+FYBOwm9QoADA7dwgk6H7AWNszm/4EO" +
  b"Ihf2/Pbs5/ZLDSsV59YV/en/VwU5/BgZHttEBLIXZRhP/MIIFP5/EbsZ1vcQ+SsCJQUg90TnfP8YFSP8Vwpk34EBRQarBo/8pPUOCiIOtfBz8yL94gJqER3u" +
  b"4eozE9sB1go4+Gr8pgLnCjIOJ9wS8Hr1rRwLGDUBlv7YAQDmAxGE+cQDTf4n+m73NARG/JICpAib8AHvyv5eB3sZr/3S7mT5+//gGFYLgP+W8JMEBg5LCHD8" +
  b"9+6n/fAFZAN3/13x4PlTDXkKhAZo7dgKugnYBwYDYPNjDbX6UgVvCIPvWvkJ+2ELmxDE5SX2tQPJDnAPH/0183zy4Q9uCd4NG+6a74cNLgb+B97/SOu8BLL9" +
  b"pg4UCmbtcPkp6vgPDwJG+8gEzvI3CDUSdvxBBVPtuv6lBbYCQQMQ58IA2f8lEUYFh/eU/0v0Aw9AEnP60Psl5awKHwIVCtQBxvb3AHTwLwu/A34AJwR+6/EH" +
  b"yvtiDtsISvBP/rbvbg4kCPIBevl/9vABY/0tCVQAte0zCHD75gXJ/s32lA0N97YDzP9v6R8KzfqTAnYg0cd2/3cUoOz+J7rmsQBaCboCFwW0CJ0RG/7237X5" +
  b"1xGdCf4AxPXI3lQH5xo862cGk96n/OcKVQhGEqLYIPlbIY3+JgFA83EEMPhDFbwDfu+iDALy5wQF+KL6ggdE9wwDtfzI+UgavQmo9yf0hAYkAMYJkwg65u0C" +
  b"wAxuBrDxOO/pBgAKKwfEAZ3zMAzzDhP6vfXp9gEADQ31Bsbyifg4Cc4MOvmF8KoGsP67CScAzO1KBc8RNv6S9qrvAgbCCBsD/wBv8AEIfhV8+VbuCADs/p4N" +
  b"1f9l9LL5yQiLCnH8IfCoBMUCbQjcBgvvXgGyECUIL/rR86QCqgeXAXP+2/oLB0z6HwJr/cYEoPhl/Pf+CgQr/yYF2/uCBif2gAAF+wEIMPrpAKcF8vaCAzoY" +
  b"uunuDMnygPlMFGXtVAUg9KYErAXD+9oBYf5JAJz6mwokBQL3egu6+Er8twdK+oULv+6EBTYBsP8v/Ur86QZQA9X/Wvgu/fMOj/cjDRbv6wLLCtH5NgE7+RoI" +
  b"PANBAXkCIfXhCWz8cQEv+3D3Sw2T/RMG7/Ue/tMDdwbiAtb1ygGnBcv9UQHC92AGvv+iAEr72vb3CdP7rwW/9ZMEcgVyAAoE6Pj/+3MNc/gf+78KUAMr+VYF" +
  b"uvzp7ssOXfiRDJ/r2QH5CHH//wS7CmDerhe1FBjsIPgF+Iv9hRoHBc7xgtzMEIb+5gBWFHzuLw6r+HsSzOaMBNIXeOdCCOQCTfb1Goj1NgwI32gKVhz99MAQ" +
  b"b9aCCDwO3RE4+Hf00w949MoBhAm2/r8TRtqYCm392/4MFPzZYgn4Csv2IgpS+T0E5/vBCnsFm/OpFH7X4AfzA8MMkgRe6CEPfv6QAfsKme7lDc/gHAyjBdIH" +
  b"/QpX56kNRPmLChL9C/f1BvDqkRgY+aX93w8Z6oITVgBxCxH7Ge0JFOfvMxEq/iT3GwQx9sMQsu+eCHQB0e3hFGPuORXZ9xz+Uwi15Z4Ro/nwBlMGDfK0DB/y" +
  b"gxZi+Sn9HABX7LQevu55DoT4qfcUE9/gYxXzAKwCchF8/OX8AvEFCfL41BRUBGLmoQTgEsoCkQTI7B8JEOP7BpIVvfugBlTaQgMMGegAghH69nUH/+js+sQW" +
  b"hQjI+W/a3AhCEjH+1QGY+X4LdNxhC3EUDwR6A9vY7Q/DHzXv4whi+QEFTf6NCqgLNP7HBfrkdwccD+UBjQ7I2KEPTxeS+usCvvy7Efjf8g/aDkEAJPyF5V0F" +
  b"NhLSBrAJVOclBbMY7fryDrQGx/aCDJQNhwAV9W/5hfyhFmX9seZBBh71aBuZ6dTtUwgLD90eO+Vyx8sfVkIlA0PPtfKeHIcGng9kB4jcytsgKYYCoOaf+Sbw" +
  b"IyH0B2HnBvU6/x4fbPVC6zEB/PO3EX4GNe3kCrXtuBFLAVfzkRqf7lMEDQ9I8ModJwKy8PHziAVUEwwFsf8m83r9iRu8Asbzm986Emf/aBR9CKDfbAcFB+IK" +
  b"g988AwwIGRSuBpv4r+2l+lElDfH29KfxkRP2ERwEcfQp7t0QNAd//knlhQzk9sEOrgpd5ukDXxTECF3t+eyUCfUCRgggB7rrxQdHE9X8pu74/pQE0AStCGz3" +
  b"RPQbBygQofpZ7lsCyAUbBYb+kPjEAWgICv379YgCkQDbBJEBd/oDAGsCngPc+1P8BwNSAAIAQwDc+TME2gGc/KMDrgRl+jcDXQNs+RwEIAKr9asImPu8+fMK" +
  b"0fYPB7z/GvQ2Ctb+CfsEFkXslwB5/AT7vBQK/FsC0ftE/FoKefl5/qIKMPbxA1L6xPomEYv2bfiP+V0HtRDf6EoCL/nyJFYEudKADSoHtwENFh7g6/hnFVoL" +
  b"RwB946cFswQqASYOI+qEEfD5n+uuEPAFZRC86zj02g/LDDQHKeGY+nwS5QSeCb3oq//GDl0ETgn1/A34aAqI65UI8wHMAlQEpf7FACEFEO3yAg8J9O7U/7cE" +
  b"rvkiCHD62gByDej1j/GWApoM7Qje+TTpcA2yBvj8OBBY00MKHR1e5iQVDvVa8L4SbP1p9vjxFPm+G9sCze7v8v4FBw7a+y8AoOyt/psPuBQ7/vzgfgNKBEUM" +
  b"XwOm7AIIBwfvAA==",
])

///|
test "amrnb 7.95k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_7_95k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_7_95k_cref_head),
    2,
    amrnb_ref(amrnb_7_95k_cref_tail),
    2,
    amrnb_ref(amrnb_7_95k_fate),
    16,
    5,
    "7.95k",
  )
}

///|
/// `10.2k`: 7674 bytes, 284 frames
let amrnb_10_2k_file : Bytes = amrnb_cat([
  b"IyFBTVIKNDyImEqP2bvYwsnH88xuxTlLAqAAALtXAAAANGmbFEq02Ng5A/OX/rAZgpz5amkXt0jVhRQQNInMPwU33yzvA95KMgTSzsE5Q+sd075V2d2ANGuM" +
  b"Qlq/nGq56IQwvWgktzLOMsaCugp0acPgNKqMGVL23Zq520hsudNVEdatGPTZbXScnhBQNGmMY1U/2yQ53l3pu7XBUn5OD8jWAEV9VJHwNGmMYtM23Ge52hYl" +
  b"x9HEx1N8xOLYQe4zsHzwNGngk3223yQ50rivvUyfcMqYJNJdu3pUF02QNDyMHHU32os591Hw2WTgu1+qs0ldZwU7IpHwNHKME+U22qm5zeankIkBR1DGJTqd" +
  b"E7Vo6X5wNHH1En+32nDgtyyulg/SDJ5slltHBYiroqmANM8zlJe22dzPOi12zr2f1r6bdTiYTmQadPXgNB8qK7m239C/gygdU/sTQRT1sEOdRKLqoiawNM+E" +
  b"Zv128ABvPzGGY4BjU2a0WRKuD26kgfEANInQ9aS3sjS5A3Kl043xCMTu/hFR8TpAtfMQNM+EZvznkprvGxnOVEisGyQQLDuYyh2k4K5QNHEH55q3mtq5EsGq" +
  b"RDYtnVxtbYgDnFvHPECgNM/BZupq6cXPMnzOPP8Y73pGo/siR4o3ZqKANJu8Z5y0WFtEwdLnWZgTFCV4S8mwsBTCBlvQNInKZu/u6iwSFfwQ3CITDSnV185e" +
  b"PlWUo2QwNM8WZZWt7eBE/eGhnoOPBi73XTkGuNJM0rBgNImbP8qllOOSAcC8Ut6XN1rmTTF+l7aJy7/gNOe8Z5Nk29LPPD7JIMeJdLS25ODJQe4MKLwgNIkh" +
  b"Pv9kmgFExq8HbagyFiYbHthofiAK1anANM8hddIXkOMCqjwo4G5Z80SscB0KGRdPE9XgNGmrwQY23/85NikGS+VYghYeGgKwNeoy4gPQNB+/wsU23C3P/B6b" +
  b"RXGI1UI9EkfQZzFQ5CMgNAUbCiU82YJdV3wojAKMY9AzY67IQgxaMFvQNDx9MQU2mZTP/Cc2+q/Tk0ZaUB17naX5CsMwNDwbCCUs34DPwny/WLPRHoTupwz3" +
  b"KAf0GREwNDx9CCU2nw1da4njqbcJhU5S7ulFW0Oz60zANDy/iMU69gUFmCknhd1daldxYfXe4SuR1kYgNDzDCMV+XgncRtDBTJHd5LY39DoLzn5wlXFwNDx9" +
  b"CV10noPRq5bE5crB8jE+NnqkJkBsaYwgNHG/sV0tsKdgAbwMLVyacVl7V5fZTKJ53T6wNM+i1vVW669R00M1/Vs/ukDhDeHdI1LvPxPgNM+/1MS2n132el9U" +
  b"8DGIvgqqLARk0nPbfYIQNM99PRbutvyFmBaq5qod4GFwwvy/hfUgm+ywNIl9eMU2sKCqQElW/DXIakYyzv20reKgFAGANIkHy1pm0mTgPcLish4J1WleJd/C" +
  b"nFj6szTwNB+/9dV22HhnPMqTTWV2QL6EbKyiyJCZ/APANImivde3mLr2SugcwSFUXEJV44YSmxyvQkAgNB8B9dK03RcP/1wid1cvYFT3YuVId4S76NywNInr" +
  b"ddVk2FYJPDwUbOkd3IZHyVX61yEkP3CQNB99ddSn8wI/lz08ESDUnsGx8zopQPDJhotQNHHrdeK0nGN2fqjf6KNxAWN6mAkRj1iqvu2wNM8bddU8kBfcSfkR" +
  b"t4Nnb15Io6hLmj85wcPANHHrecqs0+XcknqtkC+VfmtaJIb4bSeea2MQNEKO8+SmkRJchHXZ/xelQNZp48TxzSfWEu6gNGnBebSm6SXdYyXKf58pSxrTM6V/" +
  b"JxsYnoQQNImEccHntnGfCnIbTSBOW4BVx+SwHBeAaInwNGnMV6sm3eRdfbSzyVED+VLeZt1/lPGVjOAwNInBa3Q81hJ3O/oWOVlJ8LBxKnkhCqhBibQANHIH" +
  b"19Vm0ID/m/W8V8PV29J3aaUoZSZz9PtwNOHredum2tbchbiqw+jSt1WYzaWwZOSZN/JwNAjrV9C2cQiFtcNntGzvQzHdREEo6Owq+GFQNAiEedS20S5P0Kuh" +
  b"vfkhgVzpE+3CbTxggGKQNJt9IJ62/TxPy+yVT4H2USDavmziJA5+DH0ANPEhJos2+NXlITARYeyTYF0BgPUDnHsmzX9ANM+Oo8I/tRF4PObU9khvnSslqlHH" +
  b"DFj3wi4ANB6r4SV+/e685Ybq1fM7j3dSWXLsJjcQXKyANGnrZ5z3+z9LYy/Mlp2laosGtlAFI6kvLeMwNB59U4U2+I7kGml896g2xaLgYBvb264Yg2TQNAUB" +
  b"45V23XmBIvNutmCQj49TsXWs8RPwbXcgNIA1ri0+3I9ggvt5vxOlZaCNTpFNRRHsj47QNLgh5Ek38wHbwjq1NaRv4ct+0oZ+tfo/A7CwNMvh8j2230MsAj02" +
  b"i7ACSYR2obrNHKvH2Y8QNM+iman2235FOW9Ip3SKlkAlISeicHsbW0PwNB+Gw57m9ntb7Ab8QinSgTSc1+TBRzPQUSPgNIl9UV720brx4D0Q1wibFx7GNtvO" +
  b"lw50IfqANB+yS6Xm3b5giRUQyagdpSuyvI0akoGJXQeQNB/QyYIsmo1FGLj9sOB2Iwu0MbUICW7k4spwNGl9YZsnWDBhEHl+ridnxWLFPJz1GnPeI1sgNDwH" +
  b"wV00yIPgoxleXcUBzHAwwK6K5kVPB8nANM/DZH03Wjqc2EVp1wFD4ZgfduzjZvvuwhKgNIkhYNu9uyHvhqhFayG4s5NIz0CIUMOoCwyANCvl1TQ3sDmvL0hL" +
  b"yWc7CHQ4nVTe5QevejkANKlTzTU70g7djWH2NpcEtumnAdxX8m/59iqwNK3lzS0u0RX2eDO5QTzP/FkgyRgsf/V4yOfQNOeETTVuswXnNjv4xnIL81sZjsBe" +
  b"fTCqqxrANK2fTTS0sZKlwDGf/+uadEICJxWsLsJubNDwNOe8Sy1Whw/wS28gvHd/DvAjfRXd4NXXcmWgNOcHyytttvB2fR1+dm+Q7nv9r5YGFDCu94wANM9y" +
  b"SxPvu3xFLWsj2RYx4TVdizdg1lDcsp9QNK3Qwy43nswCi8Wj1XJ6hj8C8aOdR4ZJi5dgNOcfaQq832OU2UPlikuvm90kqXHOb4a4rh3ANKl9Pw7800R4ZonL" +
  b"32ohtjclPSrD3fOnSpdQNM+Ivvtm98XKizJrN+VTFrs5hT81t0JAU0GgNMsbQQNn0Kjgp8CzF6cR6P7crfiHk10MgETQNOcERQE22gC0fBPjLfDxKML2y11m" +
  b"YufzKojgNMuivwVflL0c+iTJvzNsorX4lbwKR4iHyU/ANK0hRRq32BP3q5VIKMnDHfJipvxUKoLMgKMwNOcERPOuWUgqVUO77Q1A/BXfsBX3QQvWzI0QNM+E" +
  b"aUB00gvdjIebFLwYRfPi5DXc2+U6FmQwNM8BWa0172aFEluUG+Ili7ZeFKxItJfP9dkQNIl0Q3e0nMdKnKKN7uIUYIQszZduLdn3DFswNBKEHWM3lHBRxIzq" +
  b"eIjvgen7Z8sLJokS7UuwNIkyX48nsqaqWVs7F0EIFYqz9SHVJrZ618WgNJur5Ys88rtdZ2d6fbs/vhl/C8boZzNVYNLwNM/544w2+7Bgqvp2EzzFKtTJJQDn" +
  b"Q4gAlxCgNM8UWopm3HwCoJUTs40AMjw/Mt3YKVWuTp4wNOc8YWu3nL45KAoC24NMbykmH0isVhbcseOgNOcmWYZ08UA8mHIGfOiN7JlODmsG1HjNw/UgNIkU" +
  b"XX9lm6ZX3YYt7chVvCaiPwhZYQ+En0iANM8H4Y23nSQ8pOwVO+YvkwtrDXdEJMItXU+ANImr34u011rY3TgV23STT3DrXi3jYeBkQabQNJsbW189nJwc9iVk" +
  b"yYmVZ5vrcZD0eb+XEMswNM/DZXU32l7R1MwEW9UtrqYcVt+xC7P8NbYQNJuixb5m2xwqdlOs3hoBDUX8sL9uXnaqaAMwNM8bJ5i28SVR1TBovZq+wtdiHvq4" +
  b"9d1EsvWQNM8HzZI2+ATP8UPTgutLrkvHfmEiZYqwSNDgNM99YXzk/AeqVCZpZh7M0N5FUpr4lE4quHMANCoHpe20nZMqTAvVv9MfCdzjZpxpMA4MUBJANM+E" +
  b"XY2nmDXdU0Tp6VQpkMUDg/nswLgsRytgNOeitn212dt33PnVD/lto/JQKLvkEl/0IHYQNOfrXWU33mB4U+KST8M7nqkToCwKSLGpZKAQNCr4IPPm0/mqTDwT" +
  b"lzARA+5ZPvqTSlCRsUAwNCrlm682nX53mX7N5eqN/Ev7ByLaAWmwEQNQNMvw66on1H0SHDk5W01tu9SSw+D0xORfGN+wNM/BaaYm/f4SOS5kBqWn1gIhev44" +
  b"1LkpZjTANCqnJdM6uSJ368FHoAAvRVTYSm2ovyb/ZJQQNPHAoXMbW3fPJC1pLS4bVKiE7yyO53pCfJxANGnKXIVs1KlZVaIHmzHJ0JtJ378i77IFs5RwNHKr" +
  b"oEM28HO5Lir4hmUL7N5bHDUZfhSniHXwNPEUCa423fzcoXikTqbTBzueGy1lZD9eOmTgNHLDV1122qCvE8ILZc9edFBtRzOTSGZ6Hs6ANGvDCic32eQqUEvq" +
  b"vFmxwHB9s0qn7AXR4zTQNAD1Ur0+3Sg/eh173pEQ8IBGnbfG2p+pFe/ANGn56v0/3AAgKS21O816DeudbPylJSLrwcMwNMQzvXy23Uu/sGeuesvvGUAsAXfV" +
  b"D9Bqz2kQNMRFSa023Sfcb2kjkYVARcQ5Wnn00DKFHHAwNHH562023TC/t4P787nNbarnsBtaelwyHg8QNHFyIMo+/7hciLfVgUNxdItbBFRAfky46W4ANIkh" +
  b"dxI0+FdcovPr4cmQ0Pm7O0BXkZeqhjtwNB8bVoM23BI/rQv1XSNdORDHsXqQLAD1hmFgNImbP3S22Z73Ejrmb4uZIpUluAyl5SsccOpQNHGbI9q2+Di/SjtX" +
  b"YBO5MnHLRVfnH14NXeHgNHEUXdM+3qzRhLgY094vLolpdRAlVdUC34DQNJtEdYQ203q/dWy2loxxsLf1ibdjnfJ4vQ1gNHGMddq29k9cfTUUR11D/Jlu4K8u" +
  b"zYHkyWrANPEUddF3X4k/VSYG+uVfiCuGlJejmo9uQb1ANPEbdXU83GG/m6NfkOcn3AavKblGtioo69pgNJubddy20FC/SQnW33jCRsPr2AcWNBMtqE8ANDwh" +
  b"ddU+1yRcsfWRf4gTmvEXFTJjAE9s6l6gNHF0ddS3nY9ci9PgrdvxrJ+iTLuFEhzAmL6gNPEbeVy22pg/S4nlawuLeZdsVDd6Ej6lDXMgNDwLbPq+mH8fI6bq" +
  b"q2uPsqZh4zsGYblMUKUQNHEbV2O/m+93wVvyrM7C9TbEiK2q3Sa1FjNgNHIbY3k82umSK049xxj1uEV4MAa4UBQMo8QwNHIydXU23R5EzWmR+i9BC0WgSvSJ" +
  b"ljkPYFcQNGkhVhS/3wgqV3W8P9aj8YUoIw1paiYNBpvQNAD5y9N22XOgEMKjsYsORaQ5ZHOMfiwqpbpANDwhZF0+3i0/hEte3eQNxyabgQiOvqUATrmQNAUo" +
  b"SF023qHU6mZ32Yu00NfAQXXG+c/JelcQNAX5lls23uW/aw+ruxAzJZCPnJ3ONjgDkeWwNDwUKkO234rU0Ue1vvaZskstMXUNZ4VgU7wQNGkUIda22WqSFL2d" +
  b"52LSQ48o55UXX0XOjq9ANAUhZSw+3rFU4rH72Sn5yjhSmunPuwaF1CqQNDwEZS2+3ox3AJsrviboUx+8HMBexvpNqLFwNDwUZSU235bUwmNytkddgqX1YuMI" +
  b"GspDwHbANDwEJSc23wzAQfGl0S4YIeu62OXe5I4G10QwNPEhZzy22QZAh+eG6IHvxFaMNSMuq9Wj+tQwNDwhZzK22GqCiOOucWZRMcVRfKGRQpiv4nZgNDz5" +
  b"4yX23xOCs8DkV6KZ+huxhALTXUQJTYYwNPEbZSU33vpKu892C2GDm8QT2lozQTYtd72gNDyQ5ZM23xKCrcv2wO1GCiD3dE+OZt0haxAQNHinb5U23WIvQljZ" +
  b"2i93QVveZQ9vYcyopdFQNPGbZZSk95nU/ZIvi9RSODkX8Tyn09Y0Z+OQNEKbZ5M3We9RaNhEaQBxq1B54ZiKZFHZwCAgNPGEZQy376I/XHoydfEpr6W27+g+" +
  b"SZOzWS0ANPGEZRW93Eg/u8yaL+GXoPKZPxmh6xhPs4eQNJuW55o1+GofHXwXRSxGEJty41n/nMsCNjowNHHBZMTm3z5E3gHabS+0TE8PKKuMQqNY3v7ANEKM" +
  b"S5023kB3EeWfkCKzAnQY4XSobMWnzoRANHH55Zy23jlE/hrTTBjD1PLrV5S8AqPtTyCwNPGMdSym2l5LgTh2j/ESssZ94XT0SgflHbvwNPHpZ5022ABUyvwT" +
  b"R/cY8ilVmUuG1S2X0r2wNLXpD6A03AlcWy49CLzwKhkZrZ3BtidEEesANHGAZZz29spnL54BJIUqdkGYmu3gfnf0pKOQNHFMa5y2/gaEur+TamVO+r68zYNj" +
  b"+mcrIuhgNDzAxTe2+oNXoGf28kosMkUcJvH5jmqEb4qwNB+W42w22x+cwGNstWZgB6Sw4x7OxtzJqi+ANB/A351+2MGc4WLlO+YahWeClrFzSCYRMQ+ANGmW" +
  b"x5K231e0QdX9m17aS+5nI2rCqcydlX2gNB/nyWw23DfPDmNu3QInoQAXlcuYTGGuc43wNDyW05a3vF/f3HV1oGyd8kQ8MmYmaRH/5PHQNGmr14s2+UfLXHAt" +
  b"ypC7e513V7Vd4hpxrgSgNGmO44s3/ObPLDwdL0YGdL2L6OhSXtLzsCUQNGkLY400+oO0fyi96mlJTameOTsDKa61ByKANDyO44U3+wY5LVq0cAgKbcuejFlx" +
  b"nQeb0zTgNPEmX303/4S5F50nR1ZpEJ0hRTZw9Fm2UfWQNAUMX303/oY5Ak3hkI/TThoTfR8MP2B6QIWwNEJK3XU38gYFkwC0jJ7c4bNfHReJeKimycMANDxF" +
  b"W3o22/+CuZduU9jel8QBRJjZx94FU9ZwNAmMH2zm0zc/ScIunQ0wU2puVvcREP4ml72wNKT52WU3uCJR9Qx2M1rL0yESqz0JJplrqHBQNKQbXVknm82vP+Wn" +
  b"RsyZkyLobX+8JmESvu3ANOJmWWK89fxcivSh5vHlhTQ78/Huksuq8d/QNLWi2V1umYPdUbUj0zVTXafWpWnUAHoRDjzgNFSbWWVnmJKCr5hqDpkSX42WEmjl" +
  b"kzWkKYQgNKQbV2Xs8g05KqprGWlreE2bMDpGDl5QVXWQNHgqG1Vm3qmvAEi+K6327fCjnDJ1Dx3RQf+ANHibHWSk2w+5Dti4giGa/SkpyBOufh6180PgNAnK" +
  b"V2o3m1yqWlfiLq4JWd2N82gqqQeXH7yQNHGr19c0+c8SBRVZzkUonsXq/WIh4EiDYOmgNCsUGoT83uJKlcLf7g5LuA+DV56ScpaXoe9QNHgUU262216c+oOl" +
  b"bML4rUxrGdnsC1BZl6jQNMvrWWS++RlPHFKjgkaKlfI+pJ1z/M300TCANPF2V2U01occ3wEn7puQB+le5H3+BEtKI4HgNMv761s201Oqv8G1JLPd1B27d4F/" +
  b"mVKARjQANCohWYo+zlIqpMPRv5oLiDz3OjNdcQO6Z02ANM+QzSy61Msc0kPktMBFQVvZhZiYBptzznhgNM8bY1e2m/sSNhKeL8qUDZR8Z00O4GKV0SvANM/K" +
  b"VVTvVdNwegfI3Lun7DYHoDiZi1wChvogNM9yf2c3nnR31iPjauuUOSJ0TwZ8RCihyw/ANM/52WVsl4ITfDHO+r+0ea1UZaZsmh/GRMywNM+MS198lrJgtDRQ" +
  b"+g+d1IL+saitDzLunLiQNB/KW132kEpdrC5e9N8Rzb8x+MQVXuML2RWQNEqMZQw23VoU0NLUReCOj2xeUlMu5hMxPkowNDnQ+Vs+9XDPKTyQ1B6D+oz3WEqt" +
  b"44FTjk9QNI+BHYamm2f/nKP+rgW5jWhjY8LyM5m4hlWQNHL51W423zJPKzrxu4NlOR1jnxs4TbP5WIwwNDmOnWL23M5gA1mDPfg7tETo+2WLhJSXxMIwNInQ" +
  b"yx+23vkCoMmxq4srCiaW5gqYtPY0xvzQNIlMHVc0/DovJ5apr48VVwa9mfg7SAPrH/GANInBE1MWsdgaBnH816uRHXAMrGJyRoGNhV4wNIn5110n1QSc324r" +
  b"B3XQ4BPUERaGAsCfbiIwNJshVVknXgFPOPS+yF1awG7WZ4dbDVqOyitgNKouVrU+2+9U1ipGrdFZ3qt3U0KfoK890BsgNJuML4k230ESLqF11tV9udCk8XDJ" +
  b"FE7ets9gNM/DYru+3/pl/HwYu027aoWigxgy5Tgi5u2gNHEoY8623N4SOLhuWkVp3GWuT+nPvimmw+3ANMvwmHCm3pxx+At/6P8XCqsngdBCtS2MzczwNPH0" +
  b"VVU+3O3EzxOij8FkW4pEAUmCsE2CHiZwNPFB2H02sAEENZc3/O8ZIeSZxjs88EwBlB0gNPG62HU9saUiDMdVoYvbkQO78AzLmQZctxXwNDyQ1nK3f39LmXur" +
  b"owJm9KaIVMVwxuPHIadANJtIHHN9nOqQB7FGUoR0AbBydScGroU7GCHANPFEHHUqmqeSA+f7+4gihhTIwsaH+inIqibwNOeEHHVrkq5LgfTknghsU/lL7mos" +
  b"lotGGidgNJtEHHVlkif3QneWnqbd/RV8VLCBvfXiurpgNM8jHHUs6iyCo2P5f060DfzB1UibiwXc8F6wNJt0HHU6uC2CjsMzqLOC4wYcnXWczIT+AS0QNM+w" +
  b"HHVmuCsE0NEjrVfgH3W9aYgFRg6ZbF4ANHKrnGW+/6Z3/LEa7IyMzKyrTKoGs5y8dcUQNPH5nHT3nRrvFCmW+ewax5Kttf9lsSn6xX/QNDx9HHK9/X5vBt3c" +
  b"h4Mo2bkMJfu47imffFKQNLWinHN99WJvIGzEmkFOxQ2MY8ryh/Poe0MgNAV9HHN/vOrvFHIIp0hGBqlestaMaztV4j7ANNqinHN+7eGU+SLR1nOZm1K9RMTt" +
  b"yrsWHiGQNDyinHV+vQVE3aMK5UiYQy+FCIFpU4FUJ6GwNAWinHV3rweUzY0LNkhVGSsqw8Rau9Jy4SjANMCrnHV31Qe5C0bFF/Q6jy6o8JGQVTG4Q94wNMub" +
  b"aM023yD4c8Hu+daSIWtLlLjb/gqLipswNHHrV1t3+3ecx4qFICVtRbJS+cgT4EYFnyIgNDyi12U38ibPPcFzabOtSVO8wH+qBU9u5OEQNHHrWWV3+aLx+3Ax" +
  b"oyPI51me1DZZtLeKiwJwNDzn2WV2/4s8v3QBzFOS1+zjGJBPVS48fS7ANMvrW21nmCr2XfQ+FPyilA1po7i/kb/W9IYgNK1yW3Sn2JBP/qhxzkcfEcY1wXmt" +
  b"XX5ISoEQNK2I0zUXdBTb8Lgv8Q1NB9Val3KN2JIlX6MANOdyUzq36TCsPKQZeJawK3VwxR+vsh+azEogNK0czTo2mWmMtDTsMhL0etkWYnh88PjEAbUQNM+O" +
  b"1v+19flgrvAiG+x2a8ACKXQdvwK6TNYgNM92Yw+Xc39FM1Em+0DP4Yi1i+ASRgn0U9EwNM+O5TkXtVtx98B8x/ot7Ya7Hw9IwXGDE4bANB8yWto62jk3k0L0" +
  b"SYXdZun0Q+oiWRiSi68wNPGW5Qq8n+jJGqE0ZVJ5HBQf1IjV2P5sjLOgNImr5LMk8mP3yu50CwKyiNb3o06klKDKmpdQNOfAsIvWkBnxx9+qz7gJBlnOo5xE" +
  b"b1G8Zk2gNJuinId11XE8iIULGoUJUJDztwps8CKSuEawNCrn39X292lPLxPMa2+wM7vIGX8leNoEHEiQNEId33y73gqSOcIeSqp9lmTm1eUHLhG1IeXwNPHB" +
  b"H21vlgOAUn74H85REUJ4GlCOvRnUzsSgNEL72WV1twJY/CvWfVqvWleYOdYJxUo9NVSANELBWWLe9X08lhNcFwtLVwAeIAunFATtXolQNDwUWW1ts0z/ofQ8" +
  b"8mr0VPSIdUcofDhC014wNPGEXYU1ktZYy7wHv17KVoJEWzoYiUnn41cwNPFopZVruO94c9p1FaLtiXsRWS1ytCsnXcqgNM8hZSXq2FoCtDw3b0wHyxlu0LRX" +
  b"xoLB0dWwNM/DKXG3nNK5Ozy494/VR/VIF74GnXcs36pANM/XY1On77AqYJ03iq/oblq6+ZAIlg9UokmANKk8WVq2/nkU1nwzwVYD8AnVdx9Ml8tcXgOgNOfR" +
  b"1WQmhKRFQbwP5nPs4DRFGbYKDjw+QWKQ",
])

///|
/// `10.2k`: the C decoder's first 16 frames, s16le.
let amrnb_10_2k_cref_head : Bytes = amrnb_cat([
  b"AAABAAEAAQAAAP7//v///wAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC5/6v/vv/H/xcA" +
  b"QAA1ADcAHQBPAFgA+P/w//7/4//k/+v///9RAJQAUADm/9H/zv94/3v//f8sABQAEwASAAUA7/+p/7b/y//K/xgAOwAqABwAWACtAFIAAgDG/Gr7gv6K/8z/" +
  b"rQFwBosHRQIwAI8ASP55+VL5uP5aAFb/JgR+BmECZf/Z/vn+Rv5T/qoA0QQZCI8FvQR8BFACuP2E+W37Hv2A+6z+6AIiAr7/WP5f/sTz/uvx85j4fPlqADAI" +
  b"dArGBV4CVwNo+VLzw/Ix9Df/JQSEB5gOoA0VAh7wouUm8gL8lP5pBbYLLA6LBmj/kfvA93XxmfFt/XgFuwe7C5sNcRShFG8MqRPWFdMLtg6sEOwT6BvFFNQM" +
  b"XAYK+M/0i/N78nj4xPcN/k8CzfjQ9uv0gu/q7jvpweyJ9jf3SftM/3T9I/xt+zMAEQINAX8H5wS6A2AKAgbMAjkBTP1dAHX5J/Uy9g3z3Pp6/oD8AQKEANz4" +
  b"5O6d5NTq3vSe+mgETQxtEMcMfQL/AKwBoQMFC34OhhJHExMRDA9VALP9IAXK/8T/bgCc/14D8P1hAAkG2/+r/Tf5H/WZ+br5FfzIAGoBBQltCe4BDPyJ9kT6" +
  b"3P0S/p0FPwijCGkCffSJ91/2SPCV+Hv9ngJsBvECNAQnAfL8O/66/IMA3AT/CVIPqgmIBpEFTgWfBuwGQAoUCfsDCwKBAwgFPfkl7+f0CvCy5B7nNu+D+Ej9" +
  b"x/j/+Cj8y/t8+x38n/ya/noCigTYBtkLYAyjB54B4/8oCOQLgwpnDIkLPAlx/5HyGfN/+LP8UAC1AUEJIguRBOcB5/5D/okEmwfmBqsHlwomCLsB2ARUCZQN" +
  b"nxB8C4UIGAT2AFMFfAOcAqIBT/Q08vvzFOyo6svsgPQu+UH0CfWf9Ebu1u0T8Yz1LPhb+ub+Xfql97v8Qf2u/gMBDgTSCEsHpAYsB9IApf5j9+fv+PXp9vX3" +
  b"3feP+NkC1QKPAg8IUgYzBWgIRAxeDVwOCxQIEtcTuxvhGuMYuhRNELYNtAfLCjoOxAiNA534Yu4071vtZ+pB65bq1u1y7tDsm+4e717wJ/FB9I/5Pfq6/AIB" +
  b"OADs/8kHVw1pELoO8QsqCdgDwAQ7B+cEZwT//9nyBO6E84n1gfMZ+u8DpwFK/t0BRwK2/icBFQnLCWgEOQt+ENIJBgvMFLEVnA48DF8MoAUd/Jj8V/8aALMA" +
  b"7PxS+Af2nPTy88TzE/WN92T9jgBo/kX+K/7B/Jv4nfcg/ML8q/09BEsG/AQZBfEFKf9v9Vf26vqp+6j78/yP+S/r7+ha83/1RPek/c8AYACcAaIHIQkxBl4J" +
  b"SA4YDLsF9wqVF8gU7RF9G3YaJg/7DSMLef9g9QT7gwi0CW4GbAGr9/juyuXs5QToFOcP7yP36PeX+B78iADCAHsA7QMEBgUFmgHCBFYPcg+UBy0K2gt0BZUF" +
  b"NQCm9HjwE/g+CPsQOQ8eBIH3rvFc7a/uE/Uw94j4UgQRDsYI8QGNCZMNHgW7ADv+bfI38bD8G/2y+yYBPgRrAzf7l+yV3UXh6fupELQSlQl/AZ/99fkO/bIB" +
  b"zP/s/2sKRBEKFK4dxSKNIIIY2QluBX/4kehf+xsHgfSL7uz19vQS8i7sIutL8CXy0e1+4HTjxvytDSAd0B5MDL70MehFAZYVHQrbBpwZwCGJGdoc5SFlC3n3" +
  b"DvssAFH1g+vr+oMMuAY2CTEFkeKF1//pZ+9l5vvp1/uY/1MCGQ0x+Y/PPc6n9wgPnvy09GUK4hA5DW0Z+g8H9DH0+AbyDK4B8v25Cc4PkA/jFsgM0fn8/bwD" +
  b"LQqADoUG5wCB+l4EHBAxAdYD1Q30AFrtE+VY8mP7EvzSBIr/QehP4Zbynfe+7/739QTHBLgC9gd2CUkCIgKrEnMYlwsABJMD3QPTBH4RuRhIBuf4J/nk88vp" +
  b"+Owd/agEqwMb/Dnhos+f6IwLBgli6eHeJulv8nIIchPu/mn8mw9NFuMOcgZnC6UVUhiWJpEnZwsXCwQXuRJSEeIKIwQiBfgKkQtX+3vzeAMpEEcK+PEM4jDp" +
  b"Ju89/ZsIEfdz6ejsVuzW6jjxyPvg/e/5c/wy9Cve0+ET9Lj4svtS90XyuvdqAMcKKAmCArgMsRNcA5P2dfyeB4cTlCQqLtEajAJ2ABcCN/pB+loF0QftA/EE" +
  b"Yvl43yDd+/hBCsryt9ao2oDlgfPJEkwW6f7r+qIFJQzKAZ762hGAHzkc8SYUHYIHdQ+jIswnDhWX+fPw1vK9AqIaaRRhBMYAufrh8D7e+s7P17Xrbvv4/dju" +
  b"hdv429HsBvle/bT2f/G++vsRpyCMExARnh98Gn0DrQOgBbb3WwTOJN4lnwqP/LMIsQDK7G33LwCY7v3pnPnU+dLqd/dSDn4EtPFA8KDp/uAT8QwKUwig+rz9" +
  b"rgFv867r4vdBBZoJIQ2hEQoANPBBAXwQTQ5cCsgOzRGMC3IRVBNrC+oR5x6FHykOuPn49Ev23QbCGv0Hmuv16obzK/Tb7/7p7uV+6lT4K/977VLcLeay9Av6" +
  b"7P1h+/n1lvlxDHgXAwsNAqkIlwmlCaELyv/qA58Z7x5bEiQB1ffE9Jjw1/dDAI/4bfLg+G39FPhG+QX9xfdJ7OXorO5872X1Bg6BGTQMpAMkBbUAIviHBPsW" +
  b"DRLVEjAekxkjCcL7KgWrDIYCVgL1/wD2rPmgBjYMeQGo+AX29u6j7PLnHeJD9jsRNRUXC73/MPj/8zn1rf2P9wPsWPM9CaUSRQfPAHH+FfeG/Aj66+zx7Or4" +
  b"bQ6HFjwF+Prt/Or+1gAYDgAbAwwRBJoS4BTECRIHiBG+EDQDSgP4+0rm6ui+/rUGz//Y/Ir6lvF478Tvzusv9iAKGhAYCbAB/QSwDCIL2gX5BaUAc/zMBKEK" +
  b"TQXJCc0W1hLyAn796fok7ivqKfjO/93w0Olm9Pn1uP0kBzb8U+tl7VH2svXw9hwBWhM6GokOMAr5Bqr8rwo0G4MQuP3q+0oGBwQE/u0A0vna+1ELWwsV85ng" +
  b"oe15+zr84AEWAKHpAeIA9oQAV/rT+VD5LPdN8tb15wGa9Izu6A+RHg4OGAUiCIUHVQykGT0TQwHmAcgLWwIR/h8LJQnU/Bb/lwe3A6L80wPPENwM5wKmAsz+" +
  b"HPg8BPwPjwPU/bIGNASk8sftOfng9+PxG/GE7U7vDfjMAeMErf3b+2wAg/+x9gf0Vvus/4AOsRnACkf8fP69BNsD6f56/df6WvG59DsAwfrc9IX7zgCT9rLw" +
  b"cfG44MXe1Pi5BfABYv+VA1UGSQHJB4gM9/wX/aQPaRJcE44XihuhI/Qg7Ra1C8X4XPxiCzMOeAu/Aa77JfzU/aUBWPzv9Eb4n/mS+Hf4UPGa7cj7fQjx/CDo" +
  b"q+hV9178Gf4xCVEIwfy0ApkM6gDa9b7+aApGCuIGPwNy+i/31gFzDP0GCv1f/O/9Pvrw+EH83P+oAE7/R/8P+EjurPXGCesMRv9y9935m/7vAEIB2v1w9wz7" +
  b"DAclB7P99/w+BCcKVgyZCf7+E/lt/gUDkAdxClwFlv/Q/sYFLQXJ+uYIpRoQDXb/nPlw6t3k5PT5BUj9re3N82P+u/5o/Y765PMa8wr4yPqu7V/mN/m6E6Uf" +
  b"pBikEbcPJwyZFAIavwxvCFMUyhb0CzwFMgJM/F//VQaj/470bfH88hb0jfV18cniud4h7R3xFuzR8Nb+2AdUBVoExAJb+QX6owWKBKn7i/2JBqkH5AXtC5UU" +
  b"ZhOADagL3gEA8m/x4f9CBW3+bvyE/tP9uf93CfsLeQI7AOIEaAPL//f5KvV49igA8giZ/u/zD/qR/1cAnAHaAQgAe/7gAn0DgfpF+GEFOA3ABhICGwIrAGr/" +
  b"ggq6EWH/V/IK+z7/cvxQ+zD6ePec+KICz/xZ7f7ysv2t/vP3xvQ+7arkxfJ+Ak3/T/zL/CQAXAVbCTENjRClEsYTFhOhD2IKphAVH8Al5B3HEusMXwf3B30K" +
  b"tQJm/VkB4gC3+Sf1lPPP8Vz0ffg178/k9+Fh4mbppPCN9kL0hu4j/F0F4f2P9xX6agO/BDQCXgP8/J70Xv8QDE4GzP/xA9IGXARTAMcDaANI/H8AtQJ78mvp" +
  b"0faICvwNfwbpBFYDWAJfCw8MLQEm/+H+Cvyw/fL9Q/ub+Yr/OQm5BI/8AACgA4AKMBHVDaIHGwSBBpYHlgHA/1AHqBE5EacHzAK0AKD/+ABn/sj5bfAF65Lx" +
  b"8fQZ9Bj13vW0+KP7YveW7kLoW+7z+l//yP/8/036JPrKAfILxhD2EGkYrxjJEFURSxQbE/oT/BFaCoL8svauAXIJywnfAvL4Hfjf+Rr7PPSo667vF/Kj7xvv" +
  b"2u1j6pXrOPQl+rf4vviF/HAAXAV/Ce4KoAq3CdcJOAuAA48EQA2/EEMUghG5C8sEUP2DBAYMnwXE/n/5EfmR+kv6Xfz49bPy3Pfg9RTtQuqi697r4e/v9Sz3" +
  b"uPXp+J//QQReB04KxQujBegCjQNV+rQA5wmsAJf87gLoCQUPHRjnGhgQBhPlGCsWXxQVDPAFBwKb/uv+NPoK91H1aPK59ArxWere9M/3K/NA90j4q/lu+sQE" +
  b"mgsaA5r7FAbGCigKwxN5D/z/8gGO/+n8Gv3Z9g32QvJl8rb3yOyh4hzmnuuc8DXkXeO69dz14flO+cH2if/CBEMTYQ/Z/yIHhxEFHson6SS4HtUXbRyiHCUU" +
  b"SQ9OB/sGHwciCTUKn/+e/If9Rftt+CHwc+6R74ztpevu6QXubfBS+Oz87fgv/AT5WPq5BpUFQwP3BLwITxceGVgTRhKPDS0NchMdGf0TcgrxBwUHXAIv/ob6" +
  b"rvTx9t/y4u1l6i/k/+Z858Hm6Oi/5c/hFOMY6TTtuuzn8Nz1kvrG+j/0L/ht/Dv8fwLhBPj+N/5wBHwNBRFMD/MQLRhRG+sZaRpzGnUbjB5zJaIm2iAfHuIb" +
  b"fRxkGRwSuAvqCKAJyQcaAU/3xfH06j7l7eN539/WHtQU2GfZ79ff2iTbdt2I4mbkhehg7GTvqPZ//Z/+df93BMYKmA9oEiIUfRdCHlAk7ySMIvIhOCJZHiwb" +
  b"aR0UGxYTRg86DTIIywGo/in/DAGI/xH6x/Y+8xLvzOol6Nfm0eht7Fbsketu7RfyKvVI8UXxAPaI8YDv4fS09175Tfqr/AIA0gAvBMQH0gfZCNEOIRLSC0gE" +
  b"/QPSBL0DNwTDBOMCDAABANgCgwOa/c/6nfz89nbz0vY++AD+DwLAAeEDGwGy/3UDQQRhBJAGkwW0A4ICGv/v/D79sP7w/+H+c//UASgBNAErA3YCOALJ/wL6" +
  b"uvnu+6L8Mf97AQgBxf8wAOoC/wjeDD0QqhPeExkU4BJKEtMW7hVUES0Qsg0qCxsMRhAMFAgRugpOB5D/Ffgt+GL5rfq/AbEHSwNf+zr2kvEX8YTz3/Td92D4" +
  b"qPPS7yLuOu8y8cXuVu4E8KzuKu7F81f4kvbQ+I783fXZ8HrzXfXQ+0oCMAMqA6/+ofqX+7L75P/fBbcE8wFq/1b58fRX9bn4KPiO9fX3i/ZC8lT0UfTD8t/1" +
  b"kfKk7HrufPJE9gH7vQBOBS8GTwgGCLoIZw5dF+oeVCHdIqcinB8EI14loyJCJnEnNCKNHsUb6Ri3E40OGgzKBZ76QfiZ+CP0XPDU7+/uxub94MzibeM75Ffn" +
  b"wOn36urqdOvP7DHrAuzY7nPxrfXh93L+YAS3ApkElQaW/+T7J/8UAqoDCwrBEHoP0Q3BDTgOjwupDesVZxaNFCoVyRHEClkHFAeqBa4FegavBGkEFwVfBdgF" +
  b"PQS0//z5afNr8hf0JvP88mb0ufQF8d7ta+6p7rfv/vN39Yn1y/bu9pr2aPQZ9Fb1NfZN+QH7xv/kBEIDiASUBf7+LPtD/dL/5ADABTELlQoMCikMswyvDIUQ" +
  b"pxQlFO4TCRcPF34ZIxsrFxYX6xVCESMOKQvmCEgH4QY2BWT+Bvdz9Abyme1Y7eHu2uzL6vPprOis5/nnWeln6o3r9e137xnt+OyW8GHyE/SK98b6Ov3Z/3MC" +
  b"3AOjBXYHeAdKCEIGjATqBp0HPQc1C1MNjAvlBkMEJAYKAR79IwC3+wX4TPkb+U/1x+4j8FD2QfMX73/xFfb995/3z/t6AYH+FADoBQcF2AW0ChwRahTQE1gU" +
  b"2RRtFUkXVRePF+UZOhr8FgUVSRZCFc8VXxWfD6AODw3TBrkDRgGW/iL97fhH87/uZO9C7iLtuvHc8GXu+fCu8HXwvfHQ8tn09fQL+UIAQv3B9xf7yP2Z+136" +
  b"n/xc/kcAwQGl/0r/5v1m/S//afsO97r78/uG9pL5v/xF+Af26flK+/b4dPoO/YL8kf+wAlD/Gvxn/j0Byv5K+hX8bf+h/p393P7G/rr69/p7/pL9xv+zBmgL" +
  b"2gxiDBYMvwreCtgNUg5sDksRWRI6FAcS2Q4ZErETdxCsDUcOPg30C6YLQgjMBTUFeQEq+zL4Svj39Tj2zvfl9JHzo/Pn8cTwkuxd74b30Pbe9Ub6Mvqx9nr2" +
  b"BPVE8zj1ivae98/4Q/nw+c/2vPLQ8zH1ufTN9dP7lAKrARID0wdDBYYElwhdCn0LXw0eEZsStw7sDV0QIBFDD2oPnREgD3wP/RBdDAMKNwecAu79zvkv92/z" +
  b"w/HZ8DvuXO2x7P7nPuMX5E/nDehL6WzulfFb8uv1YPeV9i76A/1v/4gD2wZQCGsHuQegCSIK7wr6Cw8P1BKeEx8VXRbnEyQS5hGrEOcOxw0=",
])

///|
/// `10.2k`: the C decoder's last 16 frames, s16le.
let amrnb_10_2k_cref_tail : Bytes = amrnb_cat([
  b"JgBtAK4B4wAn/v79A/81/2D+H/8EAHwAfgBC/0L/UgFHAU//xv79//AAof6z/bX+mgA2AWb/6/8qAggD1AKwAEUAUAGOAEv/HP4Z/g4A7v7i/HP9JvyZ+5z7" +
  b"wfnT+vz7Jfv8+r77Cf1n/Oz78Px0/FL8pP3q/kgAjQBFAckB8QMXBg4EuQPoA+0EfQa5A5sCVQTABLIDmwGFAlQEBAQQAvj/n/8SAFH/Gv6X/eT++/5t/v7+" +
  b"8P7u/f/9mPyh+5b9efxk+yX+ev8a/zP+qP6Y/qj9P/7E/lMAcwHoAHQBSQJYBLoEigQkBVwEzgUEBqEDewN2BLsEHgOwAe0CIwTgA3QDiAP+AbL+If4m/iH9" +
  b"2fyA+9v7x/2R/Mr5i/nZ+mn6tviJ9j/3//tR/fL6evy3//j+Y/5H//z+YQEQA7MB9wGGA4sE4wMwBeUGEAhyCUMHlQeKCaQHhwVlBI4E/gO9Au8BNgGjAbwB" +
  b"RwCf/yL+b/wr/BT7dfsz+zT6hPuV+yD6OPmk+Vb6G/ki94f2JfkA/B77h/rH/F0A8gHsABIBEgMWBSgFoQNQBHYGPQeNBsoEogbNCKAIEAfqBJoDuAJuAVD/" +
  b"r/28/ZT9W/ww+576W/qC+Cz3NPYv9mP3G/YB9iH2jfez+un6bPvg/br/rQF7ArIEIwcsCFEJ4QcHCMkJqAk0CfsH+wicCigKDQkxCGwIhAcLBGIBjwGWAb7/" +
  b"DPzl+XH6wvl09qzzyPLa8170QvIu8Qjyw/NZ9KTzOfTj9Wj5bPwB/VH/vgJjBT0HggeqCTUMiQ2DDagLNg0TEPkPPA36ChULVgvRCeIGWgXIBbQE+AH2/7v/" +
  b"5f6U/HT5kPfC96D27fPn8cjxaPIE8pTykfVz+NT6KfyJ/b3/lwFiBXgHAQgnB50G9AkGDGUKtQlKCjgOBxDmDA8LdAvMCcwFvgEAADf/KvzQ9zf0afMc87zx" +
  b"M/B5757vwu7z7eTvUPIh9Gv0dfXG+fT9GACDAbgDRAdGCQ8KlwsGDbcNPgzWCnwLMQtcCKgFIwVVBocF6QNTA5ACGQH1/pv+WwAuAEn+1vz++tP6APoI9+nz" +
  b"d++i78XvhO2A7x7xR/T6+Bf7Kv5ZAeMB1QJQAkEEHAjHCB4ICAgAC98NgQtoC00OGhGbFHsULhSWFOsRAQ4jC24Lxgq9BZkCoAJLADz9evk69mb0YfAu7V/r" +
  b"S+p46yHtm+6f8LjyVvVo9zX4oPlM+2v92/8kAUwCsgNkBTsIBgk2CVQK7wrtCxINsww6CyAJ+Ab3Aer9CP9t/tn6GPZY9IP1v/AM6vTlBeq88PPsIuwz8sv4" +
  b"c/sC+YD87gOEBVoBp/1aAlYJxwigBZsGIg0HEfEMcgyIEeAVexW0EUsSnRTVEQIMtwixCFQHogUTAzUDjwSzARD7t/bh9m/2GvNd8ArxkfMf9AT2wfvF/xgB" +
  b"qQHQBQUHJAR+A4oDFwQ2AFX7rPv5++f6sfgw9xT5+vkG+YT4avnZ+zL9nfzJ+nj8fv/nAGEBFgE3Aqv+Qfcp9R/27Pc0+ZL5CQGpB0YIQwyyDrQP4A88DX0N" +
  b"ywxlCiwMOwyKCxcKJQd/CugKUgeuBkkFBAgzB1IAp/2t/dr/D/vO88H3Qfv5+BXzme668NztjuZL4aPiQO2a7dLoz+2p97/+bPtC+j4A9gM0Aur64/oiA38D" +
  b"Sf+a/UkC2gkZCJYFkAfvC84PQQwjCVsLUg0WDZQIwQcmCMQIoAnNBRcEqAQvAcL4hPI882r4cPri+F38BAO8BvwE3AFzA28GMwa/ABD9JwBGBC8EfAF3ARIF" +
  b"twjhChQKwQm9C5UNBwy2BicDwgTPB2sD//2zAOcD7gH5+q/0RPKw7dXmbN+f3b/ko+f55v/pnPEj+g389Pzd/gkB2gAi+0b6Wf+qADoAewD8BcwNHg/RDhIQ" +
  b"nRIwFFsRCRCjELgPzxBoEPsKLwmjDMUO3wvxCPcE3ft39NTvF+8v8Xn0UvrM/pABCgL3AuoD3wFN/7X6G/e49zb5Yvr0+kP8ogGRB68L1wxICRgGkQOh/+T9" +
  b"2vwO+kX7Pv9OAJH+QP4H/vn5s/D65LfduuH95wvp5utS9nsDGQoNCt8IhAgQCHIBF/iL9sL5jv5MAVcFiw5BFaQWzxTNEcEN6gryByADaQKoBbcFUwRfBawG" +
  b"cQXDA7QCYAKK/d7xyeNd4FbqDvNS9Wb6IgaZDzsQKAthBXMC//0D9RDwgfRfAOwIOgzFEmYY1hgQEbAG3P9t/u/5B/Ib8u74VP0g+a727/p2/jn7Wvcw9rb0" +
  b"we3l2/vU5eRh99D7Uf0KCnkY/xuUFdsNRQz5CSoB3f5IB98VFh6mHfwf4SFKIZoWZAYhA+QFZQIG/8//cAa/C7MJvgUhAbP9c/qK9hLyvuif2kTRcdea5Wzt" +
  b"evGW937/cgIz+4Lz9fH/8ZfuhOuX7k/8RApqD5kUfhcpF28QyAQ6/s//d/9e/Sb/BQX+CnkJyAVjA0oAcPqY9HLxgO+r6g3f/tqo5672kfoL+/wEGBGEEIgI" +
  b"qQU1CgUIFv4P/J0GgxT6F9wVUxqpH/MfdxbiCzYO0RELEGYPqRHEFx8aFhXeDsUH3gAP+s/z7u7h5S/YZM/v2KTmGu6686r4wP+0AFT3APAQ76zvhOle4wrn" +
  b"ePGJ+yL9+gBuCNQKKwicAQ8BmQWRBNcElwhODtcT+xIyECQN7AdxBMEAm/uZ9w3xROnb68r2o/2HAWYH8xHxFhIQ5AjiCMMICwAy9qv2rwFvCl4LBA1AEuUV" +
  b"SBNHCSQDegVfBlkGcAj6C48RRROmDx0KFgMW/fD36vCv6lTjs9at1C/gaOjs7ejy7Pgp/4v8svXv8kX0PPNS6wfpXPEN/G8BswDdBSENIw0zCLcCLwQKCKsG" +
  b"LAdsDZkUFBi/FwwWIhJAC1sFngBb/Dv2k+qm4Hbl8PFJ9xH79AL+DPsRrAttBfkHuAjcAFf4TfnXBCoLLglKC+IQwhRKEhUI8ALfBQsGHgVYBsAKiBI1FW4R" +
  b"AQy4BRYB8PpR8KPny9m2y7/R99w44ujp8vDb+ZD+bPmY9Qn22/di87rqEu57+iQD8APFBNMNWxNWD2EIjAbmC24PcA1/D5IWqxrNGtkacxiyFN8P0ggMAxX/" +
  b"+PFR4AjixPDg+Xr9fwHdCYQPIwk3/+D8M/5j+avwFO+d+KgBMALaAw8KRgwqClcEXP9OAW8CMwLxBb0Kcg/tEYcQCgttA/j8U/jc8intXOe72jHVvN7u6O3t" +
  b"nfSr/aoFtgbmAfv+Z/+Z/fT1ofBr92EBAgRqBUQLURH9EJ8KuAULBjkHvAgQCvgMKRF4EloUPxSzDX8IVwQj/wb6QPDN33rai+XZ8F34bP+6CB4PwQxhBiwD" +
  b"BQM//371cvCZ9bP/XQSUBaMLeg/CDZEJHAGY/VH+LP2F/+gD5AhZDsEQvg0SB4AB6v5F+P7vZOxc4bjVY9zn6gjzM/nIAr4LbA01B9cBjQRSBVf85PZG++wD" +
  b"BwnKCTsP3Bd1F0IP7QehCAYKBAjICJQLlA67EMgReBMbEjQJYAJH/aP1t++M6bnehtdM3P7m/O+c9Ln6JwGNAHX9lPpY+379lfW179r1+/xxARsDjwhBD0oM" +
  b"rwjVBdwBbQJmAZACkwjCCl4MzBGdFEoQTgc/AhkCSvq18/30Vuk236nmS/FD9zz6aQEGDBIL5AI+ASkEnwJk+Uf3Cv90A5EF7wg9D5IVQBTwDZEKBwkjBo8E" +
  b"wQbUCI8IQQr0DY8PGwuNAqf/hP7e9YXwO/HU59ja9NyA5o/unvEo9e0BVAQW/fv53PkM/qj3w+z19Xn/Cv/uAacIrxDuD+sMZxB2D1ALTwkaCSkM7wr6BnsM" +
  b"RhKVD3MJ9ANJAs4B0Pxw/Lz7+u3e5Y/r7PCS8gf3yAA6CmEIQQJgAOT+yvrJ9Dn1Pvto/Yb/PARTCJIItgZ6CDAJNgUVA0gFtQcKBroDHgcOC5IKFgh0BvkC" +
  b"i/1x+lL6FPfB86XuReLm3kTkG+i87u3zDvw1BDQCqP97/Cr82P3H+FP6pAJfBUgHrAdyCQsNcQ1xDqsMswoDDBgKLgkIC4MLfguDCr8MjhBWDVUHWAULBSkE" +
  b"bf9V/NX5Ke2M5QbrRe578L/2MP81BWMCpftP+UP5zvZz9P73Dv5r//f/OwSwB0cG8gWEB8MG5wRtBBoHCQmmBwMJ3golCYUFSAXeBggESf+F/WX9Yvz9+AP3" +
  b"fffG7/fn6OrW8A31BfkC/6UFcgUXAlQATf8mAbIA1P9nA+YEVAR4AygEkQYlBtwFwwXBBKIETAVWBpcGngczCVoIFwNXAfIG/QWHAgMDxgG3ACL94vqD+urv" +
  b"5eVF6EvsyuxO7zr3pP6E/l/+eQIqAiYAnQBNAfwC+wLKA2AFXAX7BuYIAwi/CKkIbAVxBHAEBQXIBBkEcgYkB94DrgCQAuYFLQM0AS8BMwDo/pn8KP0N923r" +
  b"telv7c/tpes78KP59/kU+XT/YQHY/vf9dv8EAucB2wIgBjkHCwdnBz8IQAmGCW0HvQg4CloJ5wmwBxQIkgmdBo4BsAHuBykFnwK6BZgB6f9X/zj8Y/kc8gvu" +
  b"a+7b7pPvq/Gj96796v4bASgFmgTPAtoDVAMXAogCCwP2B9QH/QCJBB0HvQfPA9MEawkDBDAErQZTA0YEgwQ6CEUGKAEWB7cFmwWuAOn5jf9I+pn28fds7ZPq" +
  b"Leze7P7sGetd9IX8hPs+/Sn/u/9u/7j/tAEWApQDiQVVBGYEggklCwQJmAibC80LxAlcCnoLNAeWBU0Gz/7P/eMA4vvl/F/+EPko9qf2TfbH8RjuSe196JPm" +
  b"o+sO7Zru6fVs+5j86/9nBjoIywYzCnkMLA4JEdAPmhI9GPMSXRH3FDsXpBOADnsTsw/5CP8N2AqSBR4GFQlcCSkBYQLHBLAG6AR298n5Sfy68qrvQ+7l7J7s" +
  b"v+uo7DztYfCJ8p3tieyV7xfwDu6f7oDwR/Ll9Jb15vbC97r4+Po1+/j6a/sL+mL4T/rv/aT/rABSAx8HrAlcChUMaQ6XECsRfhAoEdQOTQ4AEBQKqghoDHYJ" +
  b"UQuYD+cOqw28Dj0QAQ33CD4KfgkHBuAF0AfDBRoGEQiUBhMJRQohBQMEDwQiAEv/hf7D/Tf9nfri+Hj3NPVL+EX93fpp8wXznvVe8TPusu5L6CLmdulM5vnl" +
  b"3unK6yXvC/OA9rb5dP3oAdj+Yf5yAMb+v/vPAKcGfASQBngL8AvuDUoPXA4MDxcPTQ7+DLkL/QrwCCoKCw5gDgwJ5QUoBEn/m/wR+qTy7O+B7UDozehW6eno" +
  b"e+/V8+f0mPUo+br+1Pxf/JgDXwhBBzELURJKEhQTcxaZFucWKhOTDywTqBG8ELMWlROfCeIGKgcyAaz63ve377XpjOYr4PHbgNqJ2wXbd9f328LhnORK6qrr" +
  b"wu4D9WX3hPYC+28C+wQJCjER4xXOG8YfKyKqJeImaid8JwcmriQaIq8kkyRRHHYZIBnDFVQSIREcDnwLJAjBAsr3IPRN9Wjqa+LT43rmAObz41nnvek65hjo" +
  b"5Os56o/qVe8t9J30zPy7Bt8Egg29EwAMiwtdDRIMWAsWCLIIbgduAyMFHQLS/h//Qvu1+DH33vMg8SDrhOd+5wrksuJ75Ozj2eNv5tfpXu2C8MrwO/PB+IL+" +
  b"5gDWAksIDAzPDkET2xXWFxIaGRvNG34b9hoaGhAYKRjhFqoSeBCFDkcLvg1HDlgEfPxd/P/9PvjF87z7Ffs5+UIE4gaM/6sAAgXHAr3+a/8iAOD7nfm7+tv4" +
  b"M/eU+M74VPge+S76fPz+/Er3Cfel+XD21fUk9z31ifFO7r3ux+0u5Sflc+NC3GPgguPw4xjqPvF79cj4r/sGAb7+vv9kArABZghDBuoEKA56DgsQXhjhHPwf" +
  b"KCJ0JSUociaEKCkr+ifvJS0lTSEOIWsm2iF7FbYPFQ5RB9z80Pwv/mL1XPfy/vL5r/V/+Lv3DvON8bHwSe3D6r7qeepR6QTtzO+l7nvxg/SO9U738Pbz9Ib1" +
  b"k/ZC9lX28vbn9h32APfD90f1Y/WY9Zbw8fAn9zr3XPc4AE0EmwLVBSoJBQp0CqcJKgclBksEIQUpBpMDLwgcDCoJsA3eEPgNjQ4xD4IOBAxzCW8JwgJyACcG" +
  b"1QC5+Y/3T/bn9MLvePRR+U30jfqcAjT+MP8rBTkFHwMmAfAARv8m/Ln8pPti+bb+bwB7/aEEEwmCBfUEZQW8CEYH+wI3BZMCGP4c/sj7OPSA62Xr4ugo3yDi" +
  b"m+hf5QTq8PVn9dX1FAD9AN//OAJxAS4B4fxl/DsCUf9aAO4J8wqHDAYU4BadEwYU7BW7Ec8NqA6ZCZMD7AhkCfAANf6AAM0Affsj/iEKbQfpBt4XlxizEIkY" +
  b"lRtnE5oQExN8EDEH8wQLBVf7KPrMAXz67/dcAbX+efz4/UT/g/4s+b76oveY7VzuEu0I407ett9K3QnYRdwX49LhY+cJ83DzG/YlAA0B8QAWBvQGLwUEA84D" +
  b"LQVYA+AECAinCU0Lfw3iDrYM5Qu3ELsNiQkBDfQKYgXUBZ8GlgK9+qj1QPXh7+LqQu/N8c3v2PV2/gP/9AFZCiYIhgIXCNMJRAQ7BdoInwYXBL4InQ9xDMQN" +
  b"gRn4F1sPmxP8FKYJYAkmDPYDlf44/l/6QPGZ7SLtauYg43Hl2+SC52TpxuyL85j0M/i8/Dz6fvwYAEz+w/8MAg4CfwPbBaMFgAYzB3cHSAg6CCEI1QfpCJEJ" +
  b"wgi4CQAKjAhlCAYIlgZUBmcGdwXrBMME6AOBA7YCRQLIAVABDQFdAOL/dP9J/87+cP6O/rz+h/6Q/qP+KP7S/Uf+9f11/dP9p/31/OL8v/w=",
])

///|
/// `10.2k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_10_2k_fate : Bytes = amrnb_cat([
  b"AAAAAAAAHQB4/xwASP4ZCMTzJQTA9+wTgu+6A9z4hhKr/Z0FO/6BAx38PAnmBqIBLPhj91wOYu66/NnyOQtS+ML87+iVF/jumgEeBDv+lQluBXTj5SFm5m0Z" +
  b"LQrSBHMYqwNNFvgKVuxqABcCgfOjIrXrnh+Y7rz9zRH16vn11fd878L7HeLPAAAbz//5Bd3wMAoV89b1WwI8BOME6f65BfQgn/m0Au/9m/5t/t3kN/lM/Nb+" +
  b"ZhM7AAgAV/I+7WEKlPOP98cDLQHVDcj5yP9aChvvOAuR+p//HRi59CgKnusFHof9WPrxB8/hN/4fHt/Wdf8UG9fmTfrDBOEDc/8wABsMkvHF87L7UfRdF40O" +
  b"wOmW/yoVafPu9tL/IxtY7WHyPQcj8BwRXhXc8F36v/xK+hYMPg3n8c/4lwhdDE/nugecEPLyEwBf+v79iAZoEUb4jfoB/BT/NwAeEq3zPvaa/98PFegrB7cO" +
  b"0vqN+nf6LPcZA0oYT/fY+gX2TAV7+fAV7/va+Zb3IA9U71kAzA9NBvf3nf5U/yr8cRBkABf7KvdpB470txczAev7bPIhDT7zsvx4CZIHqfkh/H8D2figD0cF" +
  b"B/1l+Uv+wPlSD8gDpPde9o8ICfwe/2b3Ewdz/Gz/uf+wAt372v7IAFcDwv7N9oEGHgDt/ar6XAa+/pEDUPZlB4b7IAIa/isCXv6DA6sAWAEjAmr4fwJ0AXL6" +
  b"GfspAnX7ggk++Ur2a/dFBGwBR/oV/QX+8QKu/1/4xAHdAi4Ar/xW/0UE8PpsA3X5IwsB/kL9rAERAe0EVAIQ+b4IYAKa+Nr+kP5PBngBl/uXBVYFTvlUBHL9" +
  b"JAgBALIB+wPrABP4jQIBAxYG//vm/D4DS/9M+V8BG/8gBrwAkPrsAcj9fv/gA8H7XwGF/6/7AwBt+FEF3/9b92QAe/zGASb9cvhFA9IAsgF87lD98h566v/t" +
  b"mANFGR8OZetD/j8BRPzX9lIO2gCR7GwIMxiU/YPrgPuwDHoLY/Ml+PEP/wbf/qT5qf9rBen4IgigCAvxev/xALMCf/UY9hESfP6/AE/4MP3aDir0WwkYEGT3" +
  b"iPu7+9b/Ev4b9BQPtQQH97D/5P/9A0HynQKHCEL/0PWI+N8J6wXq9lwK1gms+7X4+gCS/8HxCP4oDgsHzPRq+YEC6Qpg9RUEzQY+AXD7gvowBpb/BPdsCo8J" +
  b"+Pov+MP7pArA+HD6yBBcAZX6v/cLA2QDU/ccCscIT/7Y9zz+2AYm/A34yQuHBPP5qfVmAyoJSPdUAD8DL/8v+f/7qACzAQL9XANmAG4C0/3PAjz/Yv7S/5YA" +
  b"nAEs/oADmf8j/7T/uf/0Bpb8Cf16ASH/YPxMATAOc/jx9lwDwAWqBbn8X/nB9k0A8AaXBrcA1P7k+Y4B2QYs/hn8jweW/GcKcPmV9csHo/nIAxsADfl5CHv7" +
  b"ePuvAmv+ugXYB9X0ywQ9/IgANwK2AT4IB/0uBbX48f1P/lQDvAXY+OUD3Qmo8iEEmv6w/twFzQU5Aevzp/qACAj8svqOAWMBCf5Z+y0Ae/wEBjkH9fjgCMD9" +
  b"APcVB1j7Y/bFF+j9JO/yAFYDMw1F7z0pAwBM2GcBehNhFYb8puqYAKggJ/+3A73zoPpiHE7ytQuv+tXL3gkeHG4CJdR7A38V3gPN7dH6hwTK7BwmkfWIukcH" +
  b"nUbe5lbiyOXw5YIZM/xgFaHQNxJcCOoUA+62D9cg8u356KLpQw7QAkEWSwi4DJYQchBIAU8Dl+yG/zfVc/P++BkHY/osAisLMugFDIj1WwuE6aUMdf45BSoC" +
  b"CvRuAxX6exCw9ITwcAJnDmkBVvK6++EBMAp/Bl7+x/Hr/YMMjgJR99f4TgEvBsEKcALB9NX5ZA9oAXT3avd7AjsB4gdBA1H6SfkTC0gGHPvK+FIACwciAxsA" +
  b"ev0SAEYFNADm+oT+Nf02AdIANADG/IYALwS9ADH/PACHAQkABgKH//767QF3Ax4E9f/q/FACUgSI9WMDzBBl+Of6wPfyCKYNmvjq8esQ/Qcp7V36mf8LENQK" +
  b"Kej4FIoXMxDy1NAJM9yMFKjMpgR1AE0ofB498JEPivWqEIfLnwbW5HMq4/Ga/bcPyfsVHXbKvRVC58EbvNjfE+QBHxB0E4HgFx/L7xwKjM/PGXvzyRSF92cK" +
  b"ew3A+PkIueLoGyDgYRXL4dIYD+/2EQ/3+webC+n4rwwe5YkUyeWlGtvkiRaK64cYF/f+BQjzCgcSDFPm/SfR/072NNJlJcoDqBzrscIfyv3+DWzslgjj6ycW" +
  b"2fDXGzDe0wB75Gom7Okf5uXviim9+Dn7qO1HDtIHqfjuGPgAr/sOAMEVkPxqA2zo1xyH708EwOn3E0PwCQgP8XwUR+T+B/7rSRcn8AsGyQDAD+jsDQHS+EQF" +
  b"TOtoB7QD3f/c8cYCgAeHC/nt+wYe/N8IMgRsAXP9WfnPC+0SMf7w7/sBdgaXG/rnXwQD/MAWKfmY/xbk3Qz3/G0hkvgH7hT6TAsDEYvvDPaDDFMJwQUU8GD5" +
  b"YQMZA/UL+/797+T33gwBB035gvw5AzYKLgjY9EcAp/zFAAkMbPHgBcP/bgG5Eybpzgp6+O39jhH+/Eb5QALO9GsUtQIJ8DgE9vvg+kIN9/oN9HcD7fyPFAL1" +
  b"we5IF9r4DwY0/ufzegZrDzb1WAuG5jj/VBLH9w8DO/VW/44X5OqXEHkACeX7G+zu6RKh/WPc7Bsj/zf7YQE06HIc5PRq+iQRvuQ/CY8Evf4bDD/e0Qm4Cnn7" +
  b"Mgqw5OMJNQuF9awHEfjm+rAJ+/VmC7DxwPbAFWIEwvwr9I39LxKzBlbwogAXAI4GHQaU/vbyHAFBAygHDwAe8qL6AhJ/+fcBxQDR9IALhgCk/foIYexZEyIJ" +
  b"X+4b7kMWURBz9ZP+l/85CIjnfhLc4t4c1w/O/TXroBZH2hcV4Bhi5IX7RvnyKBPyhPHDCfn4tQNBAozfXw/UEH0CivcG7x3+bQEoDpQFQuLnAiwdA+hiBakL" +
  b"gPRACmH14+qwB4QJUg4j8Sj3OwKc+lwazv3R9Cnzdw1PAH380wu3CD7twwzw9b7wfByH9131EAOm/5v/rwQsCLTzJfO4ER7wFQPaFO75NwVF+VP71gFWCQQH" +
  b"Uu1FByj2rfE8Ey4AL/yd97gA3f63BxMIB/2z9b8LpfB0DkgU/PW0+JwHFPaO/FMMogST9sP40/tU+FYThAQ37TsHkwOz/TAOlfikAjv5d//KCHHzkP+sCRn6" +
  b"cgaE9aUAhAe1/nf77P5VAhf9IQHC+jkJ1QOw/S39xP4S//8CwAUm9ZcG3P+9BGcBF/22BK3w6grk+fL/yfcG/VsNBAjx890BRfigEaz+J/dx/RAHmQMZA3D7" +
  b"Mv9eByjydQHy+EoItQPF9mL0ngXx+P8Dm/8HARD60QbWBPUThAnRBV/5pwPZ/FLznwqu+KgE1fm6CSwEP/3H/H0DTAfICdz7w+5wArYOcvvp/7Xy/wDTDc4A" +
  b"d/agAPsF1v9eBb0DLfHm/HsAjv9W+3wGKgYcAVz+5ADxEEj9rg648yL/0POHA+YCu/P9/5QUZQWi8XT0ewOcH7/lx+u6E1AWUfWo8kT+QxiB7cAGvwR79NsI" +
  b"XQIQE9fn1e/QFAoPSur270n1iCKtBzTxNgNA/GcBmfX4/CUIp/gUEYQK7+de/rv23BIKBXfyeAblDYv+xPVA+ckHNANu90cIZ/Yw/foMrgOPAkfuYhUyBob9" +
  b"3+6TBLIHNfWl+p8Ref/VBeT1ggQhCrT2fgYFB9r+pv2ZAHgBJgHj9KwXmv98/C37Kfi/ExH3xvh+A7D5+/+28/T4XxE6+kQHzQLQ+YcD7/+FA5L+RvvzBqj/" +
  b"ePKcAz78ZAhj+Qf62weaARwBzvrSAGQFIwfN+pQCOfyCBW0E4/e5/eT7PQniANj5kfRe/BsKUwqW+JMBDQVDE03/nPv6AOYMFBIC+CPrIgT0Dhf+r/40+aEE" +
  b"Hvj+BwH9ifGfCiH+PwaK+HEJuwQY8S73FgByAwMMsfn0/GkD8QK+/hD2qe8BF27xEQ/IAUINyRS183wD0fqR7NUIPOOa/7X2PBqqFcr+pAXUDqoDhxQY/h3o" +
  b"GgGR8AMLDPGG9CT+IfDrCc3/4PFTK0oJjBSD8woG5vPvAHUASfZ76i4H9/Fq7W0HdvxzCnz61Ah8+Nr3Cfs3E7rwUgICCv/6d+ZVES0YqwAOB0/qngIy7WEL" +
  b"ifDH96n2cgyu9OQG/gXaBTD0KR+W/sARxvlN+//7wQMe/8vsK/Lb5O0Z9/ZoAS3u4hUKC94BQgGX81H9Qw0LB8cGc+lZB5MH8gNHB+P16v5I+kP+cfo68zv3" +
  b"swVB+FQHFASW+9kBLAqjBc8HLP53CMvyLvzh85Du7vrmDXUKRvf9/G4EswuDAa4QVO/o+xMIyRMc78zvHAWbCE0AWQnk76L57QvM+7j+hfMw/VzyWPpKAsH/" +
  b"YeY+DwwHSgbKA5EC6gdTBtwCUghu66ECsv8I/SH+wv6C9x7+rARTAsb7PPifA28CnQJE/Cn8iQOMC0MEbgK4/OsMz/4/CEDz2v9F9CoAb/vI94z3O/61/DcJ" +
  b"H/sfBbj/iAiCDd375gBY99n77QpeAvrmPAWs8pQRfPUfBmILc+2N+VkCUgMu/KH8pQmuA4MD1f9f/rcUK/3xCCv8yxPW7o4C+fVTAF7+egWO/D/78ADK9Z0G" +
  b"rAMWBlv/iAImD7X8A/jYBkX0pAHLA1D/wfYtDb/2Nv0E+SgEQQL6+cz/6AB29tf+GQqV/1b4WAqUA1f++Qpm+X0CevnDCRD2ff0fAKEDCvmjByn/jvnAAlEA" +
  b"8QC1ARDyWfufAYD9aQDtAtzz+PiS/WcHEgYf+iPdff9tHHT48Pj49Sr84TKEDcDf791UFSUUBA0l8QvaXRuDGgP8WuIB96YaxANzBuzrlf6DHVEV4tJqBj0T" +
  b"uRdcBF/oifQ8CakWCekt6YQDaAg4CPYVdd3QCI8UtB2s8jIBb/mYGUYSaeyuAD/+cQ+m/Rzh2vSCHFIKTxQW4L74xBGXGhX1FeukBmgZKfTw8eX2qwR9EbHu" +
  b"vemVCQr6xBeD/Ej/A/fNEOEREtvJ58j9ABzGEUsHoAV/+uLs2Bby+8EPVv3M6ysEgAtH+Sr7UAnh7Oj4rAMREQAY9P2P+UH29f/nGykAXvvZ7TEH2xe2BNoD" +
  b"GemA9WMXawek+wLwS/nCCXoSdQk45tkLrAwVCEcA7vWGCz358gVsCXDrS/yS+e4NqA2r7JzyAP8bDfsOUP598ePvxQw9C1oKkvET9eMBQQLfENsAsuf/COX8" +
  b"pRK3BOzsPQVT76UQ9wSM9zf/7/fABZ8WOQD0ARHtT/yOCdILBwEw5uH+X/6gDzkJvfmO/a71ewtPEKr9u/4958kIigLABTwEVfIwA+LspA3oCWIHwwLc4pAH" +
  b"HPynDd0NZe9H+zjxWwpyB8IFU/vb+KADtAHSCJb6oPYnBb367wXA/S3znAnr98IILv7l67kGGQBfBJIX7NDC97cb2ulOJ0rhQwniAdj8uhGeBb8ApAUe2gr+" +
  b"iB28DeX9ePSM3G4RrBu0910Ks9kOA34MdRNJFcjTxPhuEVUJlgzh7X8IEfmSG0QQV/CCACzycASd9k376Q0/77AJrva5/EUc/QHn+BHvdg9QAWMJ/wIK6P4D" +
  b"qweTA4jvrfO2CM4DyQeMAE/08QiqDaj//vXW+fz/9woeBnXt+f4LBCILjPgT7EkLCf/+CKEE3eydA2ASB/8o91rwbQbCCAEB2AEE7+gH/Q6K+wn0dwAD/xwK" +
  b"wgG58l/7OQvpCHX8be9TBPsCkgYiCKzrwAKBD7QFv/re9Y0GLAWsAVj/hPoPBEr7FwfJ/GYD+fna/N38VgRE/W4EN/2xA972YgJD+FkGqwBM/mYENPVMAfUR" +
  b"X+xwESDvHfqxFV/nwg9M9tH+awPi+MYEYv3DBMT69AAlAMn5Eg6d7osIsgah+boEJvdDD836b/zj/ez7nAVZARUHU/tb/8EQQvUUDfPzZQBZCpDyLQa+9RoH" +
  b"bwHhBCn8ZPEuClv9Vf5L/Kf13BJy+kQIqvW8/oYC3/9PBCr4QP9uBqX82AHV9+UDHALYAzj7kfauDGr8iAP79MgEOwYqAMEAvQLc/ZEMhPpf+6sLiAP0/eUL" +
  b"ifJf6nARu/jJC2DpLQtLEJgAhgEMA/XiqxmiFQ/tnATn7nz8/RrVCZnqgN4TFaoAFf95E7jtkBIN+9UUlOtDBrcSTuYVBo/4B/30HZX4Ewd802wFrxfj9IcO" +
  b"ZusrAgEPChUj9/jw4AUk9Q8JDRPtAqMNONkQAtQAfAC6FxPZlQttBbn62QMz+LQE2ANrC5QI+fVxEfjY7gmSA+sQlgL36HIRkgB2ApQK2uxXFN3haArlBiQK" +
  b"Gw0s6PQNUvrjCuv6bPZjCMHnnRiR+4z9zw0b7DkTJADIBYj9M+pzExfw/hRj/mf4RP7N8OUWq+oEDqL9kPDpFMbsbxUn+Tr/VAq53fYUv/bxCZ4GefU9Csnx" +
  b"VxI+/DoBzgMQ6vcWP/AOEgr4d/nQFPHc+ROv/r7/2BTUAC/80OzSDxv/yQ4cBv/fRgSlC5n69hLE8Y0N+OPIBicW+PwuCE3d4fjKIVn9xAZy8ST/PeKy+ucT" +
  b"a/8S/jTXugoqETgEigDp9zgMet0AAuUN1gLM/6vaHhAmIof4wAzJ76kIIAM+CP0PdgLX/63h7gy+Cu4J1AlZ3GAQFxhg/Uj8fP/zDIvkWA0TCPsBCf/l62EH" +
  b"RxCiCDUIhuS6DDsWr/ABCtcJf/ha/iMPOgMC+UT0Hv2kDe8HLuZXBMv2qgtc5AP37AoZFJ0fm84tzCsvySVp+0Talvf0IHACHxCcE8nXQ94XKj0DNO8j+ert" +
  b"gxnOBGnglvHhAQwgZ/aL97cCh/YxD0IJke+hCCDy7AvzBoDu8BV78twIcgxa8MkdXgPO8Nj0EQQbDZkFwgS275X8JxnGBp/w1OPwEXMJ4xEOCF/iXwedBlII" +
  b"z+AjCdsHkws4Bsn61erw/3ogFu969cb4ghOOC1kEF/bN8AUVzQLb9tflnBBL+2wPiwhu5dIESQ4+CO7rOfM/DWIBbAgtAiXrTAvkEf/+R+kW/jIFigbXCWLx" +
  b"F/FcCwUN+vlG7cYAmQceAVsExfMvA70Gy/0d9jEELAFlAzcDPvuT/hsErQNV+7j7DAQmAEcBRQAl+xcG+P95/FgEdAO2+IYD7wE4+RYFUP+N9zQJcfps/PsK" +
  b"oPYBCAAAa/QxC/764wEuFC7tTAII/wL54BW39n4DMv0JAX8KFfP2AyMJavh8AbMADfydEnf0Nvk+/w4KwQ3J418Arvb/GyEDRNFECmMDiAjREe/YIv3sB+II" +
  b"WQZo6N0FWwW4CFgG6OlbEwwDq/ByD6v9nwpA8Jn1wRBsDaEIud77/J0UEgsHCdTnef9GEjoKMAkU98f4gwtF7rAHCARyBcEEIv2dAMgEbevbAp0Gk+/9ABYH" +
  b"hfyYCCj2OgizD7rygPCsAGgMGgY09crreAvlBSj5LBOA2gkKdhkA5rwTMfc78xoavPsz907uvv5yJi/+BO0A93QKgg6N+nv9Zevh/JkJiRh5/Bfj4ASWAhcI" +
  b"pgnG7DMHZwZw/g==",
])

///|
test "amrnb 10.2k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_10_2k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_10_2k_cref_head),
    2,
    amrnb_ref(amrnb_10_2k_cref_tail),
    2,
    amrnb_ref(amrnb_10_2k_fate),
    16,
    2,
    "10.2k",
  )
}

///|
/// `12.2k`: 9094 bytes, 284 frames
let amrnb_12_2k_file : Bytes = amrnb_cat([
  b"IyFBTVIKPFhEZxBQ+YGM7nJjxxV1cQAASly6SP6EAABRqXa2gmA8FlJkRq27Ed4HTsOVtUcNhpBTo/lnWUUvmdtUxQTmEDzgTDEWAZ5UvgLM464wP37uHumc" +
  b"CINb5HMak8h+hWzwPExffy/T3Ks+D49yu4aF+TL/0WulAhhIFC+qUsU/57A83m+hCGUxIJ4fpLMfwYmGlnlh6AvF1KXUErFrkApdIDxCX4EjZ74N/gzVcL9x" +
  b"n7zDnyGsU6uMWil776FIzFLwPN5zgxDnsAh/BYCj17ZaKZC0xkVb4sewzIYO4GzLjqA8RGVxIuxaEp4bpnArV/7g32wnZc+ZH30ZzCXGUJAUkDxEeXty/0ZB" +
  b"vhbU0xTRdFiM5eZA/llXT5IBWaV8ocCwPOBle3f6EBCeH4bQMDoGbcdYDp5V8lLzV+rYlkCyXEA8IH1sRdE0lj4XqbQOhcau0+b19Hc/bhQFMzoeKAMZ0DwC" +
  b"Wh8d58ATnhSHkzXSUKenqmfn66gMLdCE1KNpTdeQPNZLbVOz+gN+DBQySHkY4k3Ficccx+qSyP1KqdPOEqA8AE17J0ADIdwy1vNHzpe/+UfeTWl6rjBeEgeZ" +
  b"iYcwMDzeWoNH8Z0UPhk64HY8lXfTAmaNAwjg5F9J9+APeYQwPAI2JCdEdkG+AH4UbmYWMPHkI4STrakIJn+4rs9SYkA84EpfJ+AEBP4BKiOtYEWWkKQsWg9V" +
  b"Y/LSoRQ6BdqTYDwCRiQd6u88HgCXZGKODn+ILGBf9LRMdEdPl9YNbAiwPOBNgief9o06V4Ul5AFjRTj7+yTvSIxNKpuBm3sOxXA8AlQnFgUwGDaIxAJaZOIy" +
  b"X9B2g8dDp6Qo8LaxDrbT8DzgI6Mfm5is9o3w8oXyC/j8smoVd+YCxBb+1O5U5kpwPAJCJBv9IghvEa9SvBecJMMgbrZGyvd5iEn9O+kjpiA84COhJ7Q2pVpF" +
  b"OKLTiin+z+GLAyhiNs1Ifuwnmov0EDwGP18WAJsOS1UpA0tGE6OwWDWNFUhxSVBmpDV+cXqwPAhDeySrtNZNMuQi+jAP7MS3ckIm0ERzQ9TSRM6rCXA8IF5r" +
  b"fq4Gcf4JYSFrCyKNqG4UtED5rzMVQf57rmjisDzeS108pcgXngLXQ06uwru3Uo99qYgepIFKPH7ZYNKAPCZaYyq2LoeeAYABbkZ1TZtsMqngOBjNCBQERBG8" +
  b"asA83lVTN/4Alh4VgyGB/csIk3U3EggdHZqYzIWXNvDPwDwoPmMotJoLfgOAw64gAiKB11bL/OGrGy46wUxvr+nwPNhVUzf+AYe+AYGAC61KfOb0AjzeQVmB" +
  b"ZoxTCNA4IvA82EJjOLSwkt4I1dByooKC6B/hmBlc4Y0YGIAkz18XsDzYVHQt9IqxXgGBkOzSMbGHqmNleXTogC2AWKkpNmtwPNg+cTvrFUs+AYZQyqUpUd1i" +
  b"BQM6ndHec6kbFnwOChA84ExtMjwi6Z4BhSG1IrIiho578QTUUXZvSFLNzwtX0DwCMmM2+PJVfgmoBEr32VU/mf76tMQIpprBSyI6Ch1gPOBSbSzw5BZeEYTB" +
  b"iytds6kfsZriVibteQXRaEdyccA8AjVXR1LiCH4LcrHIAyQNPeRvRTibh8B44ac3Y+LZsDzgXHQt9LQqHgjA0aNQLw215TWnZWL3P6cgZFjV2XowPAJAZ0f7" +
  b"IB2+Axyiqk7MqV7zOMpegCdbhbEOI2zcxmA84Gh0H/sFG14BgHKOjzkoxIkk5Gu3YaZaz2n5RvhpMDwETVor/caHHhRmEREGSlI+EYzhZ1ZluP9T0uGHGYTA" +
  b"POBidz/5EhxeBGnVGU5OrXrtYYMffAqvNMil1FMiJAA8BFRsR/mBHX4Fh8Go6pK/ausOmrlg+FvL4CxoLAR5MDzgSnRH+N5j/gkPxIFw7nucJg2AgLb4/VWq" +
  b"r8T4SVzwPAhMbS/6VA0eAR4CVK3qh50zG8oehERkCLNWAMsN8TA8CEJtR/mCklaYpJF2jMszCHJR/p804G2pwCuqfzVpcDzgQm0t9I4Y/CLTEKcHU26Qlohb" +
  b"Vjhjur3KnzmfPG9gPN40bS9SagH8IyKRBR2/4gaF/oiNwnfiiu1XIfSaU/A8MlxnJ/YsNr4A1iCye3SFxo3vi9hTMGlOsW8hC2OdMDzgRYIe+QByvgXWPbWG" +
  b"ygol0FkYxA+KIMRxV9EPZVkAPN5jJD7zPgGeDMYA8I+Y3uBRGUMJWIO6o1fuZ3lme+A8BkofFeTYCN4BBMLdfHGShlKVDV0LqcEN5SNAW0cpQDwaU11JhugV" +
  b"vgEikLPsyPd1v2+D7TJD24EUsaj5CSvgPBZSaUf8poO+APNCOsfiHkwE/N4qzMsjNkNYkbqrxzA8KEtXKngmklpf+ZCSWI3Y9SE8/jPu6l421iozpzwZADwU" +
  b"UmQ10+4enhFvjUWnMswalOxtYR8agzL4Bj/bqyqAPBZMaymMJCP+E2pAlmME5vfgkTtOD+aWCVdiZ5HRpFA8DkJjOZI8M34C23NNCLplmECpf3eNWBECo1r+" +
  b"axh08DwIOGVCuBZk3guCNJy3scgpVnhs800Dvq36sC4V5/+gPFLac0cOH4t/KTzFilr5Whk3yi9tVhxU+Y4C+79LOzA83lxnT+Gpbh49LyR8Cw025KIWzkIf" +
  b"5AclFQpsFlkZADzQWnNEjeoFvyzRRpI1tZBE13Y9AA2UdPNS2GEySeKwPN5bLIy0mhBfD+4m5rULTVQ7MNvjtbDrLKBtvTUpxCA8bjSdQUsmkH9K/RUMQxF3" +
  b"AxJPxGXfxflJkUokUG6b4DwaIps9Zmg1vgyEI52Hkja9CNscHLKaeMdoBibgj0ywPBYzET/4bAh+HcxAsBJhOdlnHZVyblf+68TsNP5DYUA8BCJpLqcmEJ4F" +
  b"+kP9Go+w/+yIw75NXfl0q+OzCoJoQDwJQ9yWmz8PHgGTM50RqrO+hZCgVMBTZAWlJxbuy8xgPAg+bB6e1xH+EY5kg9tDEeV0rKJMdY+0yUAtWEkcEpA8CFaH" +
  b"lrZNC14Br0WuATKhMlOEECUuS5fo5IWzCemh4Dzgx1MmkJcIXgHhInGr4YXy6MlB/IVpcN2ndeo3wEzgPFJke4+L9kH+CYHG0fYXMH8tI3Ui9uASgDzDsKTK" +
  b"+GA8GkxpG3aCB74B2sMqFjIMq+b6CPB9xGPavV1XZHzsMDwYu2Q4hDhHfgHjFPkL8UXQbPM/sXIzISqxwNChMT7wPAJAakWoomLeAuFFXAR+Q4YrNQLM/l7l" +
  b"UcTG9roKfyA8Gi4kj1y0zn4VeMC2TT6ngCZybFou0Hjve48b8ydsMDwIE1NWH57SPgeKVaje1YGcjqOb0xQ3pX4jig9V15PwPAweJD4fnh9PEYIy/zXomZiu" +
  b"EbkSHB2a1HfdgeSHLjA8CBJdJD/PO34CceX+ugOKdFqFNwq0WtgdIqLeQDJesDwGH188PIY+XgOUYlCQcNLGJosLMcg5gFqN1P3G2YIwPAYffSBtLh9cI3qk" +
  b"etSQPsAaXfRrp5ewK3vtrEingmA8DD15QHh/Hl4Ue8Qw6B66EXWtwZT8G/DwVm/geTZf8DwGsGUwcL8LfguqUYs5Kfu/O8mLEuerGs63KXw7KWYgPASrJBtc" +
  b"+hTeE1wUstzFTa+HxQZDKdJ5RU25gA34DFA8DixxKvYRDj4cELHg11yMKzrgGokJk8RwHtf3AdFC8DwIJmU2As8YfhlLZhIZV2txdIoLQ9U3GX3+xtuIjbZw" +
  b"PA14cUYEwSP+BM3g++HHPOqbjg7keHYNgpqN/fhcV+A8DihkRgGfBv4E0CQERb1I9PGEgbOmp9G2czoOZhSJUDwMMSxEJ7QpfgIq4U05aJ+XMAh4LWlm5O6Z" +
  b"4FH8LC5gPAgoZFYCs1G+AW2SesdTgOHq6xdAct1K7cANrZ0CidA8BjJnPgyWat4EUMOJJMbU7ToLL4x2AmI4MPxgEo88MDwGHl0uDAQLHgEjEW7PJROXtvX3" +
  b"SYAX55mHADcv6MAgPAI9Y09kowl0rgCVTdlJ8q/x+jAqZdhE6hXLxUSxi5A84D5yfrZtU5abfsL0x+lNwfNVBsu+SsH2ZsXzjQt+UDwIYl4mKvkE3gGiJTXJ" +
  b"5NMAy7SWCMminiiAZq45Ck4APAwgLPssjlLeEJGSoOL0ZWX2EBfLwcNOTUBbayTBSFA8CGRjP4IcPV4DzzM8tBH4ab8NERYyXGtGvnP2x7O/UDwOyVgfwjCL" +
  b"3hKacd73N4QDTvJBXzOVos5yLtIPsTKwPA5aZEeUFCE+A71V/Cb58yRXLjlqiZT8Du+xggKl3SA8BMldJ6jaEd4ELfK9I4Cqa+OgrwiJBnlfAZkIwWzfUDwG" +
  b"MlpHK3ScHhG7I5fGQqGnjsJmKIwZmFC29ox6480gPAa7LhWABw++EFXiIyrWfuBFVZYKBPOB6yTmFEHf3LA8BD9fTtU/BL4AbsCuybYaxyH4XSVdKe1sno3p" +
  b"pz6NMDwITGdXhicEnhDWYlSyWHLrXVLGmG5yKBjpcXxjO/SQPAhsbU+IABpeEZMQZaR+a9tPHvT6XzyuAyxQPhdl17A8CEJnHtk0CW8Z7jIrgshv7h8Sguek" +
  b"NDIJFFbhZHfEoDwE2V2nPvJp/geoMvWryoRBD1vT2v68yKfrjUbnORpwPNhPYBwtTRNeF2WzxJWdO1cE31/AdS2iqraioVns88A8AKlaM7CaEH4ShuIOAA9D" +
  b"+Zzk0IREE6B1KZgVaEto8DzeR18uvsc0PhAbw8f0oIxWLCZU/Px7JSP4ZrheSvbwPAK6bDbVRXL+BcBjBZqzR4GsmUZSFFoYtCBAyPWJXhA84DpxG6rUEP4F" +
  b"jnJJnUOGy+M0LjSzIv0j7NpOZHUbUDwEPiQ2f/JQvgGhYQ/NJGCxm2psxUA3/L5ltWFneRqAPAgjYCva3g4cJ4ATo7DR+8nqTG+weYecZ245TtoerLA8CDVa" +
  b"Nn/mVB4BKgNPx23SuJzlWIznf6xMeh6XaoC+0DwJeCQ7AW4SfgDNUvYqmjroubhICrhyvxcA1Q/oGddQPAl4aTL2zwB6VUolgyOrqAxgnvVDlqaZigYALeWx" +
  b"m+A8CXgkJ+ZwVhwiz7IpFtqO0MAAlUWUVQbnWiR5+eKy0DwIPYUn5jco3gPUQgyMaw78ioK1folPQAc9VpGCe2mQPA94HSOsjCrrVSiiw13ssO8zPLiOHgnX" +
  b"Q5kk+/P2/5A8GseAIYHekk8Q1ON5ungeaV9hFUn4tLggYpKT1CGeoDxGVigRgfCMHgWB0rSMDuTgXuMr6x7KGazVgGmuRPLAPAhzWj1zuxveEyJTnrY5X5d9" +
  b"wwqUm0VsM0GIBxn+PJA8OkJjSuJuId4FO6AdMpp0oRFaMwN6rFqvTBOibMRIsDzgZWSmclIYfhOhIpQOtCXYduTp0aq7sssxxNpjRSqQPEbIZ0geGBE+F2vw" +
  b"LopWAas5nXDsdh409QBHWUrTqeA82GlsNOV6gH4fhIJoIDrHHZVui4/2gtSP8/jjQKI5kDxEemgfRHANPh+BcQToIjhmw2oDh1K/ojNGAJl/h17QPDpoLCfm" +
  b"eA0eF4pAFTLgrN/zSq+rn7wqoBhbP4wRW+A82GRgRrM8C14VkRCX7lx4pu3fOof6C7Oo+CQRlEeuQDzgWmQfbtADPhaKcRxTfN6OgTxpPe+cSXp9IypDGMIA" +
  b"PN5sX0X7BBoeC+zAmpbvc7xTRu47DMMu2qhTd+vhXWA8BE17L1FqNZ5QesFB9SNpOzgbOj+UN1yUedJsWgFoEDzgXHEl1JwYHgzwMT0Uy/EcLf2On7eVQNxo" +
  b"k87eGyqAPAhbex6BABr+Gy7gRmGH3HKUQ0FRhJAr+usoO8vPnpA84FxnS6naI94Ee4HNCMr2NhS9HIPL6meOK35WP+sMMDwOOXkm/d2AvhR+8KUqftKkt5/m" +
  b"0P5n7yAWQ+F6fhIgPOBVdUfRpAOvkTXgawSY60zYkXmGMtxRo896cpOqySA8GluBL/m2Hr4AX4CPirPYnuwAua9uPwOB/S2ySRWywDzgWmRP7NZUfhDfceZA" +
  b"cQ8N101s5lZxxq5i6PececCAPBo+Yy97vBqeGYUQIvcYHEdKBi92B5+vPIYo5I84IiA8IFuAT/nKB54SwfFGOSD1BifsBgKUVAvpe/jY9XSjMDzgQ3l/+ZqQ" +
  b"/gEqMM0Wf1mc4AetuITGlHq9iDw+anBgPBo+V0OAVgPeEHfBZl033CLK2iLxpxZQT1n8O3OqSBA8GlpdTi4gEt4DYQB+VS9Sfe2LuduOZzMoLXExsYNfkDze" +
  b"c1EfRF6Y/hkuNvPxlUS+/PysfXNlfQMDAzQjnq8QPAY/cT5F/JUeHShQEcH7UeIDecdb18wXynz0x9MMcrA8IF1TH8ReWD4FgjRM5fVeM1LzHMdprOBGJXe+" +
  b"4gVE4DwacmQf+ZgeHheBM+QhiAGQHXGbndcJehqhYCV+gB0wPDpdeUVTp8WeHzvSp1A6z3UEc5rSBsESzvDAMMmip6A8QlpoLryYEP4fhmKi6ZI52awCRgxI" +
  b"v4e4JYmVSKUBkDwgVXkVPHYNXjmB4NYxQMOmIkbZBlwaSVrg3M2McXLQPFZ6JCw8MgPeF4ERJs7XMRKzzYlgOTZo/vjC/lNbkiA8IFRkIHkKE98G1SAlOWDP" +
  b"RGam4FpU4gV70X/S8TdbUDxWbGMbyqCD/h6U8VXcf1UqAg1VBxo31fkVMpvN/hpgPOBBYUOphgH+HyhBAbNCI4JVGEeINkaPtl1b5L6PHgA8Tlpkdx8KDP4b" +
  b"K1CrxiHFu14Bt2nQSs9671IQctwQEDzgQ2NHH7qSnh+DQihgQC1zxEjcvCnPMBs5I6TuAEeQPERDYx8d4wg+F4MQtRDsEwodpb3DzSEAATyNt19dp3A8IEFj" +
  b"J08HAH4Y4LFj9bQdJUGliuriCIbn52OxE5kmkDzYP3gfNZIcnhUMkLfmhxQjIO3+uzirXKfkVIQPoVrQPCBDYx9bBgPeGxr8o3fFTPvuXLGPHkIEHWzuJLl/" +
  b"SUA84DmAHxkXFL4K7KGKXqzTDIovGjtySSFhHrZqqnCisDwgW1pHHbKMvwHK08OVZdbNC1+VKOzxcsMjkjepWqVwPN5Ndyee0Al+GMUQc3/I3Zd1IBsDGlxg" +
  b"myYoKE/8AoA8EiIdQzUqAX4BKZLOrrRSYR/f6hax49KPsHju7Pb4kDxEQiQnn9Qj/gEq8DYxuMyCidmXh97mQUW6L5v0UCNAPBo0ZDaflk3+AZShTczqqUbS" +
  b"wQocNaOW1ZiiVmP44HA84Dd7FxdqB/wrC+BZP3CPTjgJHI99clgJdSa1zG+1EDwaN3E/FtSQfgEl0f4u2OcDm0dAsymaRCne2SjgDkpQPOBfXhefzpQ+AtZl" +
  b"Fur27h8+B8Y2hQvWoG3zEONuA/A8DiIdHbV/Ef4A2BLNzLGVWnRPlfKcwwHcWHAXvCtvoDzYbYEevyweHhm9cFO3Ec/+BFjGeyWMZCo6bSh5cviwPB7Jexe1" +
  b"FAaeCSjCoz+PkeATSuAHcqkoOqdQcszD93A84EOAF1OMGL4BrMEd8XIHa6isWCBgbAYeeJSvuFm20DwyyXsfQi4Y/gRXEXRmnnSq5LjMZuYgJX8ohyi7SlzA" +
  b"PBLJiEIduxQ+AIUQSjKIxA0Rn/jMJaKHa6sUztfrthA8ID4THDRmgR4Q8PT0Tx6GCBijfxwLemX3eXGgvTHAADwabekdzNYr/hOIYKcuI/OZgNY9dl+9RXbn" +
  b"hyY6qLwwPN7Jk44HPit+S+ak2Z+ZU20wm6RAq81RV+/gkbcgOiA8CHN/Jki0EP49gDAwP4VV2mHLYxfUHS9FuSbSnzp+EDzeUm9XoX0ePhuBlm8DOVdK5zlY" +
  b"GTPCgpbMHUgFmxvgPN5saU6OHBeeH2ogXGOj4sMoa0zK36Dw/ssIiZhyd+A84GWHTj5GF55aXXQcW532wf5uCZLc9gI2NBoHJotA8DxSfGtWiTRy3h/FkwLD" +
  b"2meUcEeC9zITILyjr63Z1FGQPN5aaU6ThCP+Hpb0rbrWSMsMn4UOHhpXCo1W/9VXOgA85m9TT4ckLX6C1CWbnKsuNN8gM29t93AkkCmrpfrgcDxYiGdXhj42" +
  b"vjWAQc5z6+GrkwmMvg15H2kGQi6vDjkAPN5fMEeGTDX+LSrDjMKPN59dO4KJ3DF2jKhwRv6JPjA8IpJ6R4GOHj4fgMEyVVpnvTdi+qEWTJy1OLyQGLA7YDxO" +
  b"hydDgXYtfh8rwYLJ1Hig/ut6t7m44UWcNxz15+CwPBq5JymBhEteH4CR6lMFHK+uI+3o09nrTG+ZyT6QfOA8KMaBIypuF74fKqHBxwh1gqTzXWLBmDcOEHIu" +
  b"sUYnwDwONCcbKnsMPgkokQt0OUwbh1Nope29Ju7Aia9IvOOAPCbYZ5R76h6eGZfzR4wSeFjCm1OTWBmU9WezgG5GhRA8HDRnLHscC34I9kD78rfPmL7ZouaF" +
  b"oETG3T+11BdK4DweuidBhDIePC5owlHmlihM/Zh0NTae/ntD7QbfRKIQPCQ/fymAY4v+CH0QG+bBrotfQiB1dWjbgFja4tAbFnA8HjV4MYC/LH4SY4Ji+uuj" +
  b"+HK5gAq0TyDeav7h+Zu2cDwcNYFY1c0tHgB9AEvFdyvSvNrKqWu7HSfBMOGNjZpQPB4jdzB+13KeA7diWs4iQ1HshuIGXEj8FIzka5BwX/A8FjJkIH+8HhaJ" +
  b"KrC/QdON+tJ90PoQXMhj0rtUFaV0YDwiTiRBK3ksHgDKwg4tfnngEwQux/NPtQJumwoR8F8QPBSJhxuoiDS+E+9jp+MDVONUQIK8yvoD18SFVvOnO2A8CCVk" +
  b"ONZ1h54fTBDQPc/F15MKLt8yL1gME0CpB/6J8Dweu2NOeYIeXg04o32VmVxfhHu6AeJEXDIJCBfqlnGwPAgdLCDVfIe+DS2z3BWz9aa7ZpuN9OtHjrnqUPU+" +
  b"GFA8GjRdTnmcgXbZKsMEzGuEQ/qxvSuIEiay5oGRZn8FIDwIImwaeciSXhHQUapc9HaSO7S+SGxJZCzdlQfskWowPAgyJFb7cAseAPeSbZyVGNRcdDUMY9ie" +
  b"bplxMHJNdxA8CEN4TkpyhJ4FICPAUcYf2NxNCIDuDgqyoBZvW5FCQDwIM4F7PGKAelP80fNYZ40f3I+AQW3u60J2suBxtdWQPARaXVZsI4T+APM0rLEY9QkN" +
  b"+19aP/fV+0TrEU+hWPA8CDV5P39+QZ4BfgP4vakYi/Oc27APoJsdckJyeSAfEDwCbGReflcLHhCCFCChm48A2pi07ZmYY9q3bgHmQ7BQPAg0JEY9GJi8I+OD" +
  b"ZKjXqnb5rDqMeiq0BwGx/L6/AnA8CFQn7l1EmV4Q2sc8ohrrF6MhChJzuwkS00wVe7TQsDwgaXQrV2aYXgHY4DZ2XBX/l2nxthW+jqir2retvIKwPArqZU/+" +
  b"ErD+AtE0fCJiaMdV6scmm6GKuGx/t/RygXA8BmWAVS69UZ4S/hD2KRCfiGf5Hj1q/IGZkQt7ecIXIDzYcV4aX/oB/hYstJBtkbRigwCVfHjtX5Va4JsLAiVQ" +
  b"PARkZzjdeQLeE2kQVPJz42SqCellfb+u459FZPvnQjA8IHksGk/SBh4Q/XwnInwcJ3Zreo0H6RytwH+Ch7Ik4DwCbHlDqIQDnhVt0MA5N9RH8EWAWzg+pLEx" +
  b"zZyx+FSwPBpNgBY2rjIaR95Fbg1ENFGfARYMFBYLO0l8APrIzxA8BF9iTnorQ5aJGQAmSP6zwkNNBVjJlitZ+vLjQaIFADzgQ4EWPzRD3gBx5MKk2aukf9ZO" +
  b"aR0GKREJ8WgBE48wPNkGlTSzdpz+H9NAdr8CuJ4ZQD2PsnPge2jTC3TxcGA8CD2dE8asBH4GkeL9uIXy57yx3lK5HeHox2fX+XxiwDwEfSGVslKNHg7sAxyi" +
  b"D4imX/ARyBk4kx8N26cSFMdwPOC5ixetZgk+H3nioKAoP0GcXB9O+Xq6+rCmYPMlMdA8DkYkONQvA94NCtQEG+ip7GgZDvM3swPUFE546YKsEDzYP4kMxVS0" +
  b"HhcrUqwfWVBN3/O4uL/Ez/QwZm/pHOdwPBo5kSGALGGeDH3mhJ+DXGM9yi2ilsmrH6nKa1iG9TA8Gj4UEYASxz4VgDz0WTZR/DGhfKf8JQrUFEFjGECpEDwg" +
  b"QigZKq543gh/8rhy9Uf97RB7d0u7uOmljgRwkwygPA5CPnB//NPeENZcx98XVsAqn1X3BzoJvkWCa6KIWmA8FkF6UH/onXpPgTSjR6eXjnkjISplPYbbPQgK" +
  b"OWLIsDwGOCkQf+2WVo2DPaQnwxarLovqGTPjlmtN87uJXpxwPAxDehh/4xfUr4R0bTHfg533BfvQVlU885XVS9i1wkA8BjYvGSqOOHaa0RE0VUh3ZLp8gRML" +
  b"S9A+ueK6e1WrsDwOPlcYf58PngOE8lhLZNHH3i8so0AlaQUpl4RfPwOQPAy7oyZ4T7/PGSid6Qf+5A58cWkA66smUzpCbzfDVTA8IHJ1KnV7iX4e1yW+zFOq" +
  b"Oo2l9ZZG7JxSTMW1CJKYIDwayB0bKC9pXhLV857lYy5sPCdMlx0IjvhAAtfsQ3QAPChDLB54Y2ieG4A1hgs7MzCmm9FvSiUOHXrK9MzT6/A8IENaJHrvpZ4N" +
  b"KxNriKs9veOG1L2XojWRZYb0qWvjkDwoPm0eeGXoHgmAdYtc/okGN8Henxmvs/CPq5HLYa4wPChCZyR6+7YeGSvx8y/jnLFWgTvSeQej0eq4wqh1YHA8KENa" +
  b"GH//tJ4c1WN5awGM8ayoDQLP7hGjSK0/tgAQcDw0Qm0pKqt6nhkrgY0AD0i1XRFi8k69A8LDf8fWNVuQPCjIbCB//1peGNUjD323SKsuAkdhzoUbc3GwEHVS" +
  b"2LA8CDxnLe4UA54OEnIq8YWVRO6M/vUUGqB3g15VBXv/YDzePmlObd8+vlsvdbFMnJIFuGrFWrJvJkc9a9nYYwYwPN5CbSZ40j5eB4Qz/lzMzEYsk/GMYyu0" +
  b"EimJZGtx9CA84ExsJntGPV4ZL7Qryn5KynwQ5B+qymxCx8+So0GaQDxEPmsWe1ksfheF4uzMBuTbAojKCvwKeZzzK7b+DpNgPOA2bIZ+YFteG4ST8OR6brX9" +
  b"P1LwdhTJMITy8ZqM0lA8BDJjLn4uQz4FPNJJZjSOarlkkE0tow9l2w3YD7Vo8DzgI3E2Z0A2/gB8ZWf0oKoEv0jxQ+dGH6xuW/dC+CWQPAImcT4f3kB+CYMh" +
  b"6GyigzN2IxlXNuEIdUQkfjcDMiA8CBwyPjHchv4BNJOt70i6htbgA+CEG9/EeOXD/AkR4DwCM1ZHXfQEbTv0Qtttivz4NfrrqUurLCkbMCPB6GXAPAQxcz8H" +
  b"Ct3cIqsWPSR5T0AUMZSHmzQI2lAqL9Ss3aA8ArlWHxcu0Nwi7lJd5axu6YO3YsnFKg0u7eaMYQp4oDzgZ2fNvh4UHhCgi0SV9KVi70T8Y2XhtuqcfOmrSEgA" +
  b"POC5WCccTgLeAQokxUSPPdLgGQxYzrS2LdIZ5/NKM+A84HNgNZvgHm8Qf9Q7SxQB1CZON5Cvc5qH9NoM4MfYwDwCKY1JxKZS3gDPFLD8B1Xd4et7r08W85oL" +
  b"Cn9j38jQPBo3fSWE90X8I9wi6xD6WczAzkamfwbgO9brlLioodA8CDVYX6nNZN4A9hYOeL3IfJaAYA1lhdmtpkjsL5oLMDzYR5A/gRbPvgMjUu4ELtRnyCiW" +
  b"H8H2h0LXahyWaYOwPOAjWmGAeLB+CyolyITi8xVfPUGj51bSJhJ+BQELkmA8REAjTnyvwn4RKrGToWmpvDNQnNPr1m1gSJemVIn4MDzYImgRgB80/hGBU3eo" +
  b"K6peSfgwiwg0CFNOWOWQk2kwPBo4Y1GAOXp+BZIgOFRXlcmCwxpS4u8Ic6LNGRynSUA82EV5GYMw0h4BmTItVGVt4NpF5BJvvQFDAyTgtIFDIDwOqV1BjR+0" +
  b"HgeQEznWhdbXzJvlB8CmEkWX8J8SAZmgPAg+Yy8NpQy+Ae9CH6G7wsvvEZpcckKQIcZnX4pSY0A8BDJjQ5GGT/4MiMF46AtssZQsd5SpOsAE5HWluBVloDzg" +
  b"P20vL/By/hQ4Q3l+6+GoKHh7d8JRF9X+ByoM2VBwPA6ygz58OmWeDHrQASu+IMtdYbtOtEIoQR9pwyzekIA8CCMcPm3+FJwDAWQnZmJoQ+RpWW4HtILJSHJH" +
  b"RWmUIA==",
])

///|
/// `12.2k`: the C decoder's first 16 frames, s16le.
let amrnb_12_2k_cref_head : Bytes = amrnb_cat([
  b"AAAAAAEAAQABAAAA////////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAIAAgACAAEAAACw/5b/yv/k//X/" +
  b"YACjAMkAsACcAGkA8P+n/4z/lP+3/zIAhQBxAKAAiAAJAKL/0v6Y/gn/a/+M/+X/gACeAAEAnP9Q/yv/Tv+T/w4A0QAoAewAmgBHAN7/f/+T+Bn2zgEJAP0A" +
  b"6giID8oW1Alh/Rz9Dfmu9G/0QfuDA58FlgW4BEcCIf55+SP44fmC/BgGIhIlEn8LFw10Ccj8t/QK9LD27fiG+7YG2Ay6B4ICe/7s+cnurOkF8bb3hvU/96P/" +
  b"rAJz/8n8Ov3l/SX2z/Jw+RT+6f9CAowFRAdT/kfr7+FY78D64/wdBmISaQ+OBfAAuf6r9zz2u/58BoAFxgR/CFQOkxMREYwNphN/FEcRHxOsFmAfHBrSEREW" +
  b"Lw5lAXD7Pfcr8pHsV/OQABgAsfwW/IP6q/G/46vk2O517hHwYPpBABD+jPlb+B76g/qd+4r/ZAGuBp0JAQWlCHz/DPnCAGr8cvbG9Ib3kP4J/FT7NQA7/ir2" +
  b"Ge2z6C7rqu/+9pYFnQ0VDAoLywSiAnoFNQVRDNITchTQFX4WYRKZB8P/ygAlAQEBewV3CFsLrAmDBh0FQgJJABL74fft+Nv31/ynAKr+MgNpBJf/LvvJ95r5" +
  b"B/v6+hr+LwSbBhf8Re+U7JPwpPTx9n78JQTUBPkDuAI0AL8AKwBdAOMDrgbvDQYQ+AlRCPEFhgJ8BtEIxgkoBan+EAR+A9EApv4r9Pbx8e125NPo4e/O9PX5" +
  b"CPvR/HX7pfiq+p/4C/hB+Xz9lATqBBkIZQxNBXv/iP9HBYgKBwn8CgkQ+g1mA1f4cfbB+kb9r/4XAs4IjgmZBXAAtfxs/o0CiAVKBzEJoQlABu8F+gceCm8M" +
  b"vwsaCI0E6wMhA/0B7wY+ChwG3vjM8Q/1xe8w7MvxUvhd+u/0J/Sg9nTyVfHW87v0//ZW+Nv7yP4U/Mf73v22AM8DKQQoBp4IrQcMBZ/+AvzL9pzwm/Vt+GL3" +
  b"2PZQ+nwBcgKeAuEEGAbACsAK5wjJDMMPdxGTFH0XJRsGGyAXzBHwC68Lzg3WC7UN0AynBNH0kOqW7UDqPOfS7N7v8e+d68PqYu5T7nDxCfZ9+OT5o/h5+hb9" +
  b"bP6NAWwHSxCCE4wRpAsBBUwD2wJ4BC0KvAY5//DzX/Cs9Tn1offh/z4AkPz9+eL63vxl/RoCIQVR/0r8hAKEBmYGEQ3UEs4Rbw9BDWoKgAbbASgAxQCFAi8E" +
  b"cgLx/076IvYs9aD0+PaE+o78e/x8+6T/tAG7/3v/Hv5w/af9lv7BBHEGrQMOB48EoPul+VT2wvRO+MP7PvtE9KTxP/Bz7Tnzu/aa9cn1PvuWA8gGzQ2vEOcN" +
  b"GxHXDkgJngp2EmAXPxenGOMYAxadFSoNN/5J+JT+pwYWCucI9AAT8E3oJ+ww6CjhG+Tt6rHwbfVf+c37Rfwm/gwA1v9sAEAB3QAuB4MLtwjnBtwKxwtpBpoD" +
  b"fvs37p7tyvPrAwAVdRQbD14CU/dW+D/4rvrp/f799wdpDLQDWP4n+jT+uf4d9LL0ffE07lD5z/UR7zf3SfpZ+Ej4U/Ts6XzmsvYwCGIHHgh4E8wRMg2MEhUN" +
  b"FAPjBzwVlBrtGGEiNSw4JqofzQ7m+F7yP/Dh/iUH8POH8KH5sfcN9MDvi+8P6TDfuPDf8/fikvuoFDUduRlnBlLzM+YO9osQmAsVClAdLSMIHL4ZlA6b+Ybs" +
  b"dfjvBIL0QukS9HL6XgUUDpkChOUm1Kbo/+9C283ibe/A8Nb/zwqY9qDLd84iANUAheoH/DwRDhDEDvMabBNQ9vf7Gxc6ESL9yw3pIwggLR7rHcUMpwHHB8UN" +
  b"cxJXEx0OsffX86kNew9g/qoG8hJBBy/sXedR9j31dParDl8Gouah3Rbp2fWF9b358f+89Z/20QPMAv/5SgU/FukLz/uC/+MCr/yfCokbqwuSAPQNSwsC7iri" +
  b"lvkXDLoDMwTy9CHSMs+g6Vn1Reqw4tDgHuBr78IGqQeQ/I4LGx0ZEosFJAmECucHdCZwPlkg8wCEDpYaDwonBbIR3w96BAgQkBo5A1LzPAXLFSANLfIb5WPp" +
  b"W+9iBJwQkP5b7PDtUfCN5ijl4/WD/yME7gw0AG3mEeLf8Dv41POs8x3xYuwM93oNlRImBZ0FsQ2RAMTt+PErBAkWUixxMTkU4fuDBXoO+P2g8m7+o/9F91YG" +
  b"7Af17XvraAXKDvrvpdXZ2ifh6vHcEQsXrQCq9dz/mf3/7SP2zg8WGsIc0SSSFjT/fQAlF0YnYBp6Bmv+X/hUBVcbnBUJ/yrygfbr9MvmueFB3TXg7fuNBuzv" +
  b"kt7a5OjzIvZ195H7WO9I9kwTARxVEegOoxtNGS4KuwVIAKz2swM4IiYjIwyeB5IMzQLX9mf6Wvlg6pfvQv7u8qPnN/UyCxkLgfXy7LLl3N4U7xoAgAHY+/YD" +
  b"QRFS/FLprvKf/FUHqBHPDq//DfgNCHUWjxNvDpIIvgGcDNQakxHrCTkO9hdtG5IMKgBZ+FTyFgYkFOsFcu314TbyZPHt4zjvr/Of8tL8MAIE89nefOyIBDP3" +
  b"Uuwl+lTzTPS6DpMUhgOk+OoGoBLJBN4J4xCvBboP3yHOHEP+mOw4/pQBovkAAn//CfGz8S8Bzf0F6pLxyQI98kThrO0P89n1zAmGGGAQJgAiBqUQxwSkC3oe" +
  b"1Bi7E68ajBgb/w739w34DAj6ePry/tf2KPb7DyUWpvuh7ZXxTO1z32DeTeoT8Pz6CAzpCIj3dvOg/foAbPxv9WTw1/KwBakWbwrrAcEKqAo4An76FPG86QDz" +
  b"SwnZFOAI6/ud/2sFSgWlCXQNwQJe/rUM5xDaAeb8GQ31EVUFoQEy/OPpe+vJBW4Ohf8U90/6APnH8kT0LPYo9Bf98g+fEtUCNQLjEboXFBEtCiwCR/0HBXkU" +
  b"og+O/8YMBRd8BRX88vjk7W/tI/5c/izqn+il9qz1ZPZi/hrx29tZ5pUDZ/2E6vD5DBI2FI0N4wmV/nr32QcGHj0Vt/oqAQ4RdQYlAQ8ELfni+YUKXwrq7qfb" +
  b"0eqC93X2W/8t/VrkxeB2+7gEP/bN9/f9Pfq2+N/+XwIn9Pj7DRf5EvwEiAYVBCD/4AtyGSsLL/3FCAQOzgRuBToKmgq+CP4JXAo4AXr+thH4HiETAQahAgf+" +
  b"Bvqh/sQIVAX4+gIDfACF8NrzqPks9jDvyO8B9O7tF/KN/qv7iflQ/kH+evsp9b72If6F/UEJ7RXxDG8DK/mD9ij+F/4Q/xH6t/IW/j8Ayvaz+Ov59vk09kvu" +
  b"TO614ajelwKkDuj79/21BAEHegpwDuEOeQLfBAUavRqFC9QRGh/VHOgYvhY/DFT11fjKD24OBwabAg/65Pat+3kAAPse81j5GPtV8nHzwPM07VT1VgNZAFrw" +
  b"eeY49wMAk//YC+gFF/rnAY4LfwkR+r377BHCE14NiwYT+Tv7+P+FCIgL9/qH+bL+bvsJ+SP1N///BM37nf109e3r2/l+CuUMuQRT/S74C/Xj+fMByPq98838" +
  b"NgMRAhYAfP9aA7YHhwsHB3D7nv5lB0YH2gaVBNAAQ/91+/wBHwPe/xsQ/hUqC8EDvPYZ7ozyRfsb/2r0L/JO/pr8DPhc/EH8kfqa97fzOPH55RPjyP3kEfwP" +
  b"HhOpFyMaQhmEExoVyQ5pBTMSgBf2BysCRQED/v7/NALuAPLzx+5K/QgAfvVX8tHsO+Ns6B3wKO5q72L/cgrnAL/8qgFf+0D0u/uHAnv7HfUL/wMFNAcPE+AQ" +
  b"nwhRDCgO7woC+zTzXwJdBSABBQKQ/qj81P5GD7sWFwcJAkUHqgXQABX/v/wD+5UBQAciATb5Ifrm/6gCgAI7BZ8Clf1G+1f5jPVY8rj9ygWZAHsBKQLw/eMB" +
  b"kQnzCVcC2PwV/BD5wvPb+VIAVfP68lMB2vfS7F/1K/yr+Cn0ifLa7LrmDvPNAxv8XvDC+NYFagtMDAMNuAuADi4aux6JFH0O7hFvGB4hhSAzFtwM8AjcCxEL" +
  b"8QNMAWT/B/zO+yv0jOzt78jz4PTX7Bzmh+fn5/fto/Pa9dP4I/fM/ScFz/qD9+r+bAZcC5wGIAO4+s/zKgABBb79w/yQ/Y4FdwZA/8wBDvt69iYBIAKd99jx" +
  b"QPlZBwIO/Q4oC5IC/QMADf4NvghG/7/7EAGHAsD8X/bo98kDswlZBTEBev4CACMK8Q91EkANAQQWBxcKrwaaBDEDXwxZDxUHlQOe/AP41v6B/GD1NufB5GDz" +
  b"7O0x8hD/ZvZv9Sb4I/Qq8jDm8ehq9snyxvMD+YD0c/ZN/YYL6xIPDjgUmhaxEY0TJhNnFDwZyReRDuwAkP3sABYE7gooCgYEefup+BP4B/Mq8AXwaPEg7o/s" +
  b"U+/W6D3qBfMz81f24vkkATcHfgBGCFwPjge4CtYLZgoTA+39Fw9GGKQVKBgyEfUGzANKBsUJbf+t+3gB/fmO9vr5KPf688L5CQJh/RzuKfAo9Hbuq/Rl+Ar1" +
  b"5fUEA2wHpvvy/pQSshCqBz4M/wPG8ir3HAPpBqj86vRwAokNzBdQHQoSaA+gFQEWohQVC/0C/gLu/nj8I/o69ETxZPR3+8L6se6g8af4VvLX+gL6+u9/86IC" +
  b"aAv1+4L2dQgjEbMUuhgXEIEH6P1y+Sf6NfLw69vuIPAE69noHOt/5njmQe4a73DkquPq7Wby0/G0+qwCZ/8JA34Mfg/nCUgJpxLqH98kPSI9HuAcbBzRG5sb" +
  b"7xZaELYLKwr1CUYLiAV7+5X93f1D9AvsBurq6m7rVu3N68jn9+yB+sX9YQAoBGf/4/9yBQwL0w3ZDOAOqxAMFH0Uxg9NDzIQIg+bEdQPOgSJ/Vf+xPwb+Jnz" +
  b"hvK/8QXwKvBD6mbmU+mR6snrzusW7IjpxehV6/Dn1OdX7cLw9PKv8/nxE/QO+jH78vur/zr+y/thAMQGAg+eEQ0VNBrKGdwa/R2CISQjqyLTJdgjZyLaJFEi" +
  b"oB81H7QcbhOnDnIP/giaAQH9Zvne8tXouuUL3fPQmdHH1sbXV9lA28TZddoF45Dnp+f+7InzMPir+6f8HADsBW0LARChE+IV1hlJHwkiHyKeIfQhmx3zGKEZ" +
  b"HBgTFCoR/Q5NCikElwKwADb/qgHdA/EBcPvk89XvUO9D6xnpdOts647rEOu56ZXrNPBK8GDuXPDe7kztdvAQ+Hf+qP8HAnkFcQU/BUoHxwmECpIOHA8AC4kG" +
  b"YAN2A/sCcgIXBA0EEAPgApYCDALF/Dz4gfnj9ZDxB/R39hj71/58AhADhP84AcMD0QEXABYB1gLR/nL75P4+/1b8+vx0AFkApP7t/Xn+IQEJA8ACmgNVAZD5" +
  b"tPbf+T8AaAWTBssG3gWfBAoFXgbWCNkSbhqKGWcY0BXVEAUNtgsZDOoJdAtKDQoNABL2FJYSsg0XBS38+vfk9MT03Pg2/fYBtwHj+0f3U/Y59TXxG/SA+dH2" +
  b"a/S98/3z6PP68m/yVvKx8jbzQPTc+Yz9DvgQ98H6AvXy71fz+PUK+jL/1gOVA8n9a/73/9j8MP/aAgYHiwVs/xQAfP5B+Z350fhY9oPy4+5p7z3u4e4F8pHz" +
  b"iu+y58zqTvJC9Db5lQL+BjYH6glVDZQObBSjHQEhViIxJBcjgCBzH+8iWyNpIQwicB/cHN4bbxgPFGwO0QdQAsL2PvFT9nzy6u4d8SLt/+O332feltrV3jDo" +
  b"/+mz6JfqKusA6WvnyelZ7XPvQ/W1+iz+ewHcAmQE0wQzAET9lgCVA9wHjA0YEM4PwQ4wDj4N0Qp8D6oU7RM1FNIT7RCzCvwHoQkpCB8FOgSrA6wDPgSQBQAH" +
  b"8ATTAaL/D/j78xv5NvhL9Tj4Gfg187vw3++47DLvMPbV95H1MvZT9232t/Rg9cj1SPXS+PP9ZgHPA/0ExQWUBCX/tPvL/ZgA7QKUBXcKPQ5lDTIMbQ2nDcIP" +
  b"3hR9GHQY5RcKF+IWKxXhEqkV2RRuEcgOCgtfC9UKOQdvBd8AW/uY+fzvp+m572Hv3ewl74HtdOkZ59DkguRG5SbnQ+pT69HsoO6O73Dx2PIC+U/99Puo/0gH" +
  b"SAisBqYEmwWVB+8Dov46ANwCbADsAz4HfwQ4ALf+kgBc/tr4gPs1+pv2OvXr82fyDvHe663wRvb87g7zRfxj/Dz+uQDVARcC//7yA5EJ5gg4DZcRxBQFGKAW" +
  b"FxjtGZQYUxvhGtQZbht0GxwbVhoLGM0WLBYPE9kPbwznCUgKHwVuAPcAU/xu83jwb/As75HxKvOx8pLzpvSU9K7y1PFM8yfzZvMT9R74t/mZ9U348PvA+IP7" +
  b"hf3N+2f+0P9G/Ub7ZPq2+hz6/ffB9pr30vc09Yz2XfVK8j71QfVb9RT4lfjY+qj9S/8GA0QD5wK/BYMFegREArMAGgJwAD3/s/8e/HP5xvvx/P38JP8CB9kK" +
  b"XQhLCiUL6AjqBy4IPwrjDAUO3RDHEr8R3xDIEYgRxQ+ADmgNJQzYDfENNgumBSECBgOB/bf49vhT9+H5T/nE9Tv3Kfa58j/wpu2B7lTz3/XR9Wj1u/cL+k/4" +
  b"lfUS9kr4CPkG+Un5yPkR+rj2YvO28wLz7/Lg9b/8ogGeAfQDdwUVBq8G8wVeCPAJvAykEZgQqQ8uEdwRuBG0D5MR/hGBDzgSdRK0D9YKcgZTBdf+6/iY9X/y" +
  b"lfIY8JjukO226lbp2eSH457nwOhk7Lrvc+/48nH1jvUL90X5qvymAFYDNQUgBzQIBAj1ByAIcgqsCk0NoxGnEhYU0BNkE3YTGBGTEIMPlA4=",
])

///|
/// `12.2k`: the C decoder's last 16 frames, s16le.
let amrnb_12_2k_cref_tail : Bytes = amrnb_cat([
  b"GP2v/7j/PP93/pj+lP+5/67+Lv8tAc0BEgFVADgBAAMRAub//v8YASUC+gFT/9T/jAJsAd3/QQBFAWcClgJfANz+lAB0AE7+kP38/dL/aP9o/bv8hfzK/Cz7" +
  b"hPk++s/77/uA+jP73vtW+/L8GPyW+jT8T/2K/Sb/EgFNAYcBqwMCBUMEUgSxBPcEdgXmA2sCrQN0BG4DLQKUA+YEewMRA9YBxgABAu3/NP4RALn/g/4Z/gD+" +
  b"Av9p/k/9bfzl+tT7rfym+/T8af6X/RP8XP3T/SX8A/25/dT/ngJbAvUBsgIrBfwF7wMBBOEEngViBQwE+gPPBFsFtQOOAokEgwRhAxUG3AT1Ap0BrP7X/0n+" +
  b"a/uQ+5H7L/2Q/JD66PrU+5n7Bvnf9tT4w/uU+6b4evp8/in/Bf6J/AD/wwGqAa0A4/99A9MFHgSsBVQHAglxCfIGfQbsBj0HLgYpBFYEowT8A0MCXgH8AQMB" +
  b"3gCdAOL+MP5U/Tn9dP1w+7n6Nfyt/OT66Pe893P51Pdm9Uj1Y/bP+ID5Svoj/MP9T/86/27/rgCHA8AEzwJjA9AESwYTB7AF+gVuCEwJ2gfdBHMEcgV4BB0B" +
  b"sv5S//7//P6t/NL72Pvx+Sb44PYK9534PfgJ9g71Bfcr+aj6ZPsJ/HL+rAAVArgDuAb0CGkIegfUB3EINgmHCOcHygkKC/wJOAgeB7AIfwi3BFgCFwKjAqMB" +
  b"fP3t/P/8Sfok+Lb0UPT/9dD0/fL/8XPy0PJf8tnytvMQ9vX44fqJ+4z9qgHLA2YEWwTZBCQIWwneCD0JdQpYDasNDwyrCqAKxgyvCwsI1QYyB74HrAW1AZkB" +
  b"8QAU/9f8Mvir9xz3QvWl9JHzXfOx8/71BPnD+pP8Cv7X/wgBswItBlcITggdB+0G3ggTCUIJMAngCfULJAzbCu4IBAl6COQDKwAG/S/7ovpP9vrzk/Rr8+zx" +
  b"hvAW8ZTxZe+u7uvw2/Ok9Xz2vvhF/QAAkAAKAgYGPwnnCVkJownHClELRwq9CEMIewcPBo4EYwSJBMoErwSvAw0D+wH2/5r+2wCJAc/9Qvwc/Kf7RPsw9tnw" +
  b"FPCz8YvwZe5775vy3fbY+An5kPxeAMYA3gB5AewCuAQfBoUHxggNCk0KCQwfDnwP1RBPFOsWPxbsFMAQGAzFCUoIUQdoBKIASQBU/zb+ZPt19aHxXe++7Szs" +
  b"SOoD60HuQfFE8zDzuPRr+Wz71vso/dv+OwGvAnUDiwQyBw0JhAl7CjgLrAtuDLkM3gvPCtwI5AUTArf9iv33+6/3FvZB9T72j/Ma60zn9Opn7pLs1+ki72v3" +
  b"q/sk+nX6XwEVBYABH/9oAXoF5QZ1BiIIywvDDdENMA/xERsUtRMeEx8VURblEzYOlQppCNEHEwauAcACxAQHBIoBp/u2+UD3dPOu8f7vzPPt9lH5hf6HADwC" +
  b"gAPCAzkEwwJFAg8CUQEE/0r6ZflU+oH5b/j99zD6IPw+/GH8I/3I/r7/ufwn+oT8Ov90AGr+h/ru+eH3cfOY8BXwlfXo+gv9tv9jA1UIOA62DmAPxxFmEnsR" +
  b"Rw7DDJQMQgyTCrwH0AeRCpkKwAgHCPwHQwdEBbMBL/9p/4j/dPxr9133Zfut+UT1z/GA75bu9eaj4I3ltOx/7vrq4O3d+Kf+yfvF9wr9ZARQANr4Jvmh/8oC" +
  b"7/6y/Z4BkQeMCPYFgAjoDeYPyAx3CWkKsgsACvoH1QhNCX0IWQfEBSMGWAVI/5P50PfA9xj4tvgV+Cb8gAFyAhIEZgOJA9UFPwQ3AOj93/5HANL/l/+sAPcC" +
  b"bwV4CO4JbQoEC5cJXQmuCGYF4gSIBp8Eo//f/W8BPAIE/xf7ffNv7AnnHN+B3Nfg3uWO6SjrbPCm+HX8hPt6+zr/1QDo/Nr6sPxrAOEEkAevCaoNChL4E7oU" +
  b"chYEFx8W8xP6EqwSLhO0EhwQpA6TD/EOVgxnCE4AcvmC8xzwSPIW8xHzevhe/Nn+CgMiATz/QAAc/S34fvUv9f72c/nQ+ij8AQEOBaMHIQiEBWEFDAIk/E36" +
  b"s/qn+nT4evUi+Jn75P6pAo3+LfXs6yTkSeFN4j/lrumC8hX+zgYAChEIfAZAB+oA8PmZ+ML6hQBHBU8IgA9KFgQZgRdFFNMS+BBuChQH4QiDDkwRgQyiCGcJ" +
  b"DgkvBzsEdv6c+j7yD+VU4nXm2O3i8xD40wRDEBES5AzLBqIE7P0u9U7xOfXm/T8CrASNCvQPHxF3CfEAsP9s/tv4dfGd7YL0GPvs+MvyP/NQ+t35nvRA8Vvz" +
  b"LO263M7ZM+Sc8bj9AAK5D/AgdSM3HKMTJRH/C/oDrwHlBs0UgBy5HDIgDSNlJcwcvw2EBzQHsQi9A0AASQehD4YPzQUo/zr/4voP8fjkQOBP3InUzNNp2ZTk" +
  b"f+/L8xD7LgNPAmD89Pa/9THysu2g8hf9qgfHDMgOphMYFlYQvQWd/gcAOAW1BHEEagvkFSYaxxENCvIEd/2o9PzrA+bo3mjTY9Xa4DXr+PT0+tMFvBBIDT0E" +
  b"I/8L/37+efUh8Wr9aQ0cFP4SyBVPHr8gsBbnCvIJzQ/GECUOhRB5GPQdXBx2E14JBQIQ+pL0W+5c6d7gwNyr5EvqGu+o9Yf6wALMBGD9a/hR9xf3O+2Y4UHk" +
  b"W+5E96n6o/5tCnQOCwcZ/1v8pwGhAm4AkgbfD6IXPBfGEeIRswylBKcAoPyB+k/yZ+fU7Z732v3LBEgJJxOxFxYN/QaSBRYDlwBf9wz2ngJkDEQOxw7cEXYV" +
  b"7hHSBvn+/QE5BqUFEAZfCiQQFhIMDpEHfQA4+8v1OO175zPiq9bP1pDfoeXw6z/vj/Yq/sL64vSG8sH1MPZe7XvqS/Hl+pgBhAGrBpoOAg6kCAACbAUhDfMK" +
  b"DAq5DT0U9xgPFRETOBJtDFMF/P2N+nr3N+oG4tTo5/Cj9Wb49v9zDVcQfAYgAUEF+ga9/w32XPiYB9IQFg/zD/UVoRqsFYsKqgefCncKkgeoCOIOYRJ6EF4O" +
  b"TQtiBC36SvHJ7HbolNlqyyXRFN2a4cHlF+6k+iwCxPii8AH4sv349vrti/DT/pQJegcFCcEQBhWsEP0HyQhEDvYN7gy+ETYZixolGboYHxngFF0NZQf9Aez8" +
  b"cvBA4i3kl+4y9WX4MgBiCioNDAYK/J35lvk88gDrz+uJ8pj5Xv4lAz0IBwrIB0oDqADSAmADygESBAgJRAvYC2cMWAjgAn/8bfeO9Dby5uil3JLbpOPJ7Lnz" +
  b"LPo4BzMPrAy0BY8AaAHW/ZX1yvMZ+MX/kwZcCtAOrRHCEKcM/AYHBjgHewWFBRcJSQwzEp4Vug/OClgGSwIB/9H1kekR3GbXkOI37QX0Vf2nCnkUfRH5BvAB" +
  b"EQJK/QL03O+u9Pz9tQUUCuQNXBE7EfcLowTaAbcCfwErAbUEzAhhEHYUOQ6cCk4GQABL/Vb0s+uv4M/Uk9xU6LLs0fId/QMKNAz9A9EDLwnEBtX9aPjL+7kA" +
  b"YQTWCiYTTRhlF+ASbA5kC1UI/wSvAyoIYAuMDg4TWhPmDjEJXgKT+1/0hOyY5Xbda9YL2hDl0euh7z748gAxApf+gvym/Rj8sPag85P34fxZAI4EUgsZEQIP" +
  b"zwp3CsoJjQctBZYFSgroC8gLBA9iDxgLjwa/AVn+y/fT81Xy/ebm3v3lgPCE9LH3cgGpC1QLnQUmBEoEkgDS+B33rv1BAQ8DegfZDXIROg5eC4MLVQcuA5UE" +
  b"RgfGCQkKgwsSEJsPgwnzBA//xPn18u3sYfIE64fZA90t6U7v3fHM97wGNw0tBiQENQMM/lP3QPH89k7+kf2nAj0LXBBDEdsNtxBmEY0IpwZ+CiwMkQpYBwQM" +
  b"kA9ZC54ITAUxAy0Dwf63/679tuzC5IPoiuz+8Yv1p/+xCaAGzwN7Ahf92/jX8xf0N/oZ++r8mQQHCYkJkAdGBy8JqgRIAIACugR8BHUCJgPkBtoGQgUmBqsE" +
  b"Rv6s++T8aPoj94TvnORi44Dnx+o38Xz3Yf9iBIICu/8B/Z760/kA+mT+HwIrBX8IMAs+DSYMYgp7C98KDwiqB/0GugZtBggIDAuICwkMVgwcC2QK9QUkBFME" +
  b"kP5Z+sD1tOhW49rn9uxI89r3uP4wBaYC6/2B+gb42/Y39jP6uv6zAR8FXgeWCSwJzwapB7YHKwXdBCYG4wfxB10GXAr6ClkGkwZJCIAHtgOR/YH9O/7f+Cf3" +
  b"lfeE7wrqqO2k8iL3Ofpz/00FJgScAIf+q/xw/aj94f41AoEBLAHGAgcDKgXBBXgFBwd1Bd0D1wT7BfMGbQfCCNIJuwZrBXoHkAfTBnUE1gELAG772PkG+pzu" +
  b"3eRM6fjtku1170D2aP2b/uT9SAE9AiYCyQPsA9EECgPTArUFygRJBpUJOgmUCCoI7wbBBB0DtAXVBKcC2AQ+BRgDnwH5AqYEHQSJA0ICNwBm/aX7pPxr9fvp" +
  b"m+kp7l/tG+on79n3dPgr+HL9Xv/h/ar+vP6y/+z/rgEtBsIG+QcYB5sGNgubCqIK5gurCSELwQvQCGoIXQhNB1gCOALfBbsDFgOGA/4BtgCf/WH7DPo783Xt" +
  b"Z+7q8P3vf+++9ef8Gv1tAHkF9wMRB90HaAOO/y39UwDuBIoEXgAKArQHFwjmATUD8gq4BIIBBQZzBJkDDQQVB54FMgVcCWMHeQbeAUD9l/2U+Fz1D/Ts7eTq" +
  b"s+wW7/Xu0u+z96z8qvxAAkEF/AByAZwGqgZlBZ4GVwTgBWYJwAcQDeYOhQeDCW0LLge3BVoKJgm1/s4BPgEh+pz8F/t0+PT4S/eq9kf0zu/R7W7vEO0X5nXo" +
  b"je0z8PDxNvTO+1IA+QHBB84IsAsuDpMLbQ79EEgQmhOEF9QTXBBYF2YYPBTaEsYRQA9DDdEMawtYCfcHwgfcBWwC1gJwBLwCN/6j+Rv5jvbl8QPze/Hu6+Tr" +
  b"kO3860vrRe8h83vvwuxy8NbvVfCZ74juuPJn8Bjzwve49JL1F/ki+vP2iPay99v45/k0+b/8lAGDAr8FUgVACZIOcQ7nEDwSbg8fDuEO+g63Cb8FSQk9DMcL" +
  b"pwx2D8QUaxUkEgsSxRFUDTwLSgvaBwcGsQbhA5wBnAaHB7oCKgXfBbUBQQDj/xj+4P3o/EX6qfmN+f73sPhE+5f7CftG+cr4ifhy8sbvvu6z6FbmhuYG52np" +
  b"guuJ7gHw0fN7+Pr4Cvxt/xb9Hv8lA7L/3P8EBHcDPAR6CIoJcgwPEHwPfg+JEDkQQg+zDmcQQxFiEPsOEg9xD7UKVQRuAlD9yPip9gvvbe1y7G7oQele6OXs" +
  b"kfEl88H54veF9Wr9Lv2l/CkC6AJIBHkIDQ6REb8TVRfhF20X7BfmEtQPNQ8AC04O/w25BacFiwK+/CX+J/Z165/oVuE52vTTONIs1tbSwdOF2ezcyON06BLu" +
  b"4PWA9oP4ev+z/3UBtAttD+gRxBqhH1slDyjuJj0qdCr9J8wmciTlJFYmfyTkIsEgFB6aHOIXRBJLEB8N5wZJAf/3UvP/8BLoueSx4sLgoOMh403mGOhM47zm" +
  b"SewD7Abv9fJW9Tj4sv+oBkQI1AylEVsNbwsBDXcOEAyaBgwHjAREAsAFJgBv+1f8T/di9h72hfNx7Y3m6ubk4jPd4OEQ4gPgweQB42Xkheof8RfzwfFH9n35" +
  b"jf4NA8wFewgdDrATORc/GqIb2htCHAgaoxnOGQQXRhj4F9wUFBfsFUQTNRMKEJAMGgSp//7/3vhC94761vgK+uoBTQbAA+0CigWlBO8C+gOC/9b63/ul+dr3" +
  b"0vqX/Rj68PZg+xQATP0f/If3XfF49tH42/Jc81jwcuxI8KzxifG163jkjeZe40/hv+g56OnpK/MH85X4Kv9i/+X/0v5h/4IBawXPBXMEOQcICS4N5xBZFRIb" +
  b"xBk7GnUfSx5VHkMlbyRpIoMmrSSSIcok9CPMGRYPxQ2JCMn96v0R/8z2Uvj7AB7+fvu1/Vj9K/nV93D2nO0364rtV+kC6mzro+kK7jjxOvNd9oX5Aft09Wv3" +
  b"Bvxt9Yj1M/eE8of04PVJ8qLw9fGs85Lu9O3R9I71wfn4AO0A9QSfCXwIEghGB0IG5ARfBMUD/gABBAAGzQPVC38OKQruD68Rcw2GDw0QaAmOCgMNEAPMAYIH" +
  b"SABz+hP6gvjQ9fTyvPlR+83zOAB8BlD+xQWRCckEigV7BHQBY/0f/HL/pftY+oQBqgCSAOgGyQbkBwUKFgJ7AxwIkgKWAYEAc/yc/M76efMH6kLpFeuV4P7g" +
  b"KOuT5o3sXvcR9Zf4nv8sAT8A4v8aA/gA+fjm+q76AvhJ/ZX9EATiDQoNABCmFPERUxRpEoIN1xJ1DU0GsQykCbYDvQIS/+v/2/wUAKQJlwfwDMYX7xQsFjkZ" +
  b"WxiUFmkTFhUUD30GoQbbAVf7zPrZ/NL7rfmM/f/+dP22/LX9Ov+Y+gv5mfdp7iftVu0p44Hdhd8c3tDYidzx49vh+eYR8dPwe/Xg/RD/kACPA8kF5AS/AjgC" +
  b"hQLEAoUCUQUgCsQL+QxhEXkSfw/BEwEVqg4ZERwSvAp1B/0ETAMQ+2jyBfaG8BHq8vFW8xryG/nc/o4AlgKcBlkJlwUiCH4LBwaoBWIIhgh/BkYIjA8HDYIL" +
  b"UxK5EOwLUA3uDSEHGgVICQwBfPtl/HD18+5i7dro4+KX4nLj0eDl4wHpS+qL79P0JfgH+eD5QP4s/WwA9gRMA1QFygZiCNYJjgd6DCsNuwkGDgQPRwsRDE8P" +
  b"OA0zCsUMSQyiCP0ISQn0BpMF1wVeBXgDHAN2A7EBFwFwATwAyf+v/x3/CP+B/k7+LP52/Wb9jv0K/dj89vy9/G78Zfxu/Cn8B/w3/B78APw=",
])

///|
/// `12.2k`: FATE's PCM every 16th sample, s16le (on them the C decoder is 1 and the port 1 LSB off; tolerance 2).
let amrnb_12_2k_fate : Bytes = amrnb_cat([
  b"AAAAAAAAsACY/uwADfklEsnu6f+r92Afq/GuBir2chRJABr+KwB+A5/4+g1KBxwG//bL9sIPkOp5+vDzhALx/6f9P/B2Ek3o3QAaD7L0Hgjm+PfilA5C2/Ma" +
  b"cxKrDukLMwQZEggQUfAM93oO6vElFzXgoxtg6vYDvgH14VTzmOwP8w73TerrAXQNhf8tCizq4wnq7t/+zwSh/qr7F/6kDugYGPvnAbL+C/VlB4zyyP0D/mL/" +
  b"nwgJAp8C2Pza7H0OjOyD98wBvgh1EmD1xvORDo/sZgqO9mwHzBd3+7MUQe7qH5X94/+J/Yjpy/vaJPPQHAATFBnpqP8XBBADpP6fBAoNU/bc+dj84e6jHWwO" +
  b"/+kzANITD/hT95gAKxW573DxbADe65cRLBax8oP7XfVEAiULJQy58kn58wW0D57nBAhcD5f5Lfl3+AUAzgdSFAH3V/hH+Fn/K/4fEzD3l/Ms/RESWupdA/oK" +
  b"6wHu9Df63vzc/yEbYvuI+//xpAae914ZMvjM9CT5AhFj7NMB7BDRAg71fvxEAK37qxH3AVj6TfipBaX1YhesAm74mfDsCnPyQvyfC/4I/ffb/T0Bm/heDc0F" +
  b"3f9i+H3+MfvzEN8Cmfhv9cYJqfnC/p/4dAYT/dj+7/2YBKz8Nv/SAUwC9/7Q9gcIuAAy/3P5nAas/EICQfctBoD8jP9//NQEMP3LAk0BfAKNBAz2oAGzAd/6" +
  b"wPx0ADAA6wav91b79vfBAxcCFP0y+vX+2fpgArv3wv1/Ayj/zgDN+zMEoPxYAsj5XQr2/cj69P+8AbYDCgJe+NMM8AI4+h8B8wBNBgwBivxWBsYETvklBR78" +
  b"EwWU+9ACfAfoAaL3FgTqAJAH0vj9AAsDdf96+MYBswJRAfEBt/upAe/+uv0uBcj9gv9sAOf8wwHX+FQE7f/v+YIBs/4OA0r/mPZmAmX/TwFI7k8AGCRt7q7e" +
  b"lfteG8oPLPI7/LoA5f8W+B4MRgOb6lgGvhsEAXzoYPQYC2cQwu0e+ccKegnw/dn61f4xBRv8IwYhDaPzzfZw/6gHO/n+9BASHgAD+RfwBAACC/bzKQpkEO75" +
  b"8fuc+RH/0/+D9n4NJAZc9u3+mwAAAwHxlALwDkMBIPkt9vQHfgdI9pUNcwkd+yL6rgCrAZHwFvqWEWsHt/W19wIBoAkp97UEagR3AWL81fgbBWT/EPerDZoJ" +
  b"/veo+fL7FArF+Dv4tQ5DA0377fnCANwF+/JwCSwIbvwj9678Pgia/Bv2Xw3KBOj3q/XwARgJavhWAOQE5QJh+Z/7awRJAO/8wgMrATsCc/0sA+0A6P6u/23/" +
  b"BgSI/ysCPwGM/n3/zQC/CJX/Cv+tAPD+GvuC/6oLs/fG9j8D/wTZB/j+8vXI8kX+ugf4CIH/OgAa/Hb9Ygzb96T9rwoE/zcEvvSg9NMFoPlNBfoA2/WyCOj9" +
  b"Q/pnAQUASwPhCFDxRgac+DACngHiAssIcfnQB3H2vf+r/w7+2gTg9A4BZQ3u9JMEOQKp+7wHvggAA5zzgf3/Bev9PPqmA57/MP+4+gX+t/y0CCgDlvsJCN8A" +
  b"7u9wCiD92vS8GqACEu2YBD34Ogoj87QkfQey19EFgRPiDcf7e+gIBjofMfjUAorwhP/EJyjjLPae9lDVggDBIawEAcDm/KsmrQhV3Pj8rgXs3bQq6foWvEHy" +
  b"rCqg7+v1jeMO2gYlH+tqFITPQAzcFyIa+PB3/AUjxPd26yf10BrxAgMNcwm7CbkDIQ+t+wT+f+h4/TTSMPZQ9nP+mfOk/1MNDfR+FWz8fgvd8YoRgwNzBVEA" +
  b"9fcaBAz3PhWK91LxXwE0DPoEpfAW/JYArwuABRgAGvMY+1YMQATR9U33gwI0Az0I0AG59vz3xg+SBc/22vXWAAQDnwbLAR33m/fvB4kEgPtq9+T9Fgh9BMr+" +
  b"Pf5wAI0Eq/+X+4UAJfxSAN3/2gAN/DT/4QR4/RAAEABZA7n/5wI2/oT7MwPLA7cBf/8Q/AMCVwQv9MAD5A8b+NT6O/M+Cw4ONvo48Q0P1g/E7ZH10gFpCvkP" +
  b"DuTqE4AVwhHi0ZsLatkGEt/Q4wE0APonPRrJ6WQQnPHKE7vL1wZb48Mp/+98AZQQpf4yGpbLBxPu6sMfr9RIFGL8DQ5TFXPnliGw7NcNPc5jHcfqAhlK9+cP" +
  b"5QyP+8sJ9OJBHF/cFRoU4UAYUvLdELP0yQoSB+H6oAzU5oUQD+ciFgbkgxdk5TUcePaeBqr35AC2C3fgkzOf+kTt0daPI48MHxtft1kbi/kCBUbx3wOg7HAX" +
  b"dOyUH4vX9/oB4CAmUu515eryTiSA+QD8JvE+DLoHxfqZF9ADt/q7/HcVSP0Z/Knt6iAM9gYCIOhkDAn3ygjx6GIYjt9mBlPuZBuD7P4EnvzUDJTvrgAL9jsE" +
  b"ROutC1sF9wDZ7bkAZwUcDbDvFAkK/UcGfwZT/nP+bfjIBS0ayARV5voF8QRRGqPoWwPZ+RcY+fdNA2LnfQvs9rAgTPl772H62QkQENrxOPbGDPgMJf5R8mb5" +
  b"YgASBdsKaAIo8gH22woFDW76cPuuBIMK5Ab48uj9BPraAfwM4eyGBdH9xABmE0Xpdwk4/bX4SRDA/SP46AOu9XQSxf4i8ggGxvjP980Qsvoe9X4ADAK0FDL3" +
  b"3+91FuX5zQqgAZj4lAGbCFD8sQx26ysAbA2b/swBCvXQ/10XNO7JEV0A7uX4Fr/tjxSW+LzjHhfxAfz6sQRb4xcfbve7/yoJhOltCCoGcQGVDHzeIwnPDF/7" +
  b"fwST7P0IVgmP8uIC1fWS+qAICvczDe3zfffiELsG0fqo9pH+LhCSBnbyMgPt/yAGzwKz/53yhv9dA9QDzgCN8nH30xPT+LkDb/889JcJlwMLABYDO+uyFA0b" +
  b"nOFD4SwZMBK8+/H4OfrwCK/tmglK4GAWIie35nzsPQgh7BQXFhXU5Gr4KPpJKMn13OwQC637Lv53AvDdWQkGGUMF7PTi8NIAuv93DloH/ORL/sAfGuNmBwoG" +
  b"B/pjC8r2keh/Ax4QPw3v847y8gHW9wUapgCo7YH3Cw0mAgP7GwzlCSXxTwm28aD1MRh1/UT2JQBI/7j9zABXClT1mfKcEvDvDQJ8EoP6xwVH9Yj1hwHJCwAH" +
  b"I/BzBtr1j+3IGvAF4/Ud9k8BZgHNCIMHC/2o+X8KhfC/CBgVo/Xe9u8GM/Y4/rEOOgPb82n4mP1O9XISOgcr7TMFtQKJ/Z8QzPkjAU77EgJ/B0TzbgDUBsL7" +
  b"bgR59mgBjgYgAAP8zwAMA876DQHj/JIJegXN/Sv+/P9M/dELcQOD+hAFAv6PA/H+1/dhAof1gQQ4/57/L/cZ+2wGnQ788D8Cf/+dDOP/E/PnAXsGtQAcBHr+" +
  b"kwAPCH3wDAad+Mj/LwGJ9Tnxdwat9yoAOgf+Cav5DgfgA/ERygG//Y0FrAfS/Sn2BAuo/+z8Af5rB0QCM/1I9o4B9APrDJH1YuYwA3kIx/25BHD1UwO4BXID" +
  b"vPvFA98D+v61AToC6PB7/kIB1vix/c8I4wMPBOAAiPyFEsb2wwhV9nIDkvJz/iMKCPl8/FETjgvy9CTzEQFDGnjoofPEGQgRcPWm9wXxyhqy7pkINQdK73QF" +
  b"ugjuD7rvee4oEswQvebi7h71iRzRACX6kwQ5/qMCovfW+P0FLPC6FmQGOOZA/jH5BxkJAtXt9ALUCyMAUfcm+yoG8QIL+uoMz+/Z+v0LdAVLBSHvPRKZBskB" +
  b"YfNg/0AP/vge/tcQG/zXAg34/QE2BcH34g/HBMr7R/z4/in+1QJ09b4UhAWo+UL6h/yGF+/0pvrGAm/6bP+19C39+wna/LsFnwQn+2oCBgJ0AmsDj/liB6H/" +
  b"L/RPAtkA4gOA/Uv63Qvu/9n+Nfi7/nwEwgls+dH9RPyjBoEDdPrh/6T8fRLCBuH9+fnF/AAIQghr+04A/gdsDeMD6PZ1A98UJhPv7LPr3wSQCEj6Bfx3+IH/" +
  b"qf4oAekAv/jNBSb5AQec9ywHzwfq9/r8+/ho/aAIi/Y9B9ID5flz/Vr97/FtHVX6lhsJ+RQJEB71+hoN4PQ37ygT2+jAAVT38RCfFwkG5PxWBN0GqxmD+ITp" +
  b"r/w26sgHau8u+XEKT/vmCqcCsvJdIy8Jxxl59RD8Av7K+eD87PzI64AMbPGv8OkHvf/QFLT/2Ajo99vu+wLAFT/xUgebBGwH3u34EucaowXb/sjx7v8h6TAT" +
  b"rums+d74pRAf9TQCnAwUDnb4vyMVAe0ODvS4+L//gPzIAVjwS/dz6e8UGPkkB2nyjwAYC5IGRf7N7zT2jhB3DSwEB+xtAcAIbQSUCSL4SvQm/yr+Hfjs8xT1" +
  b"QwWS9lsG9Adu/sIDRwt8CUkL8gFGBXPslAId+RfuLfrPC3sJwPD28S8Iywa3CXIRW/Pc9OYL6xFt75TwjAedCb/5RQlL7Yv3iwqoBAT99/MF/ej0dPiB/+QC" +
  b"BOcoEVIGFQacA1ACJAfcBJMF9gUC7sADef2J/ej8RP/8+nD+vAYZBjr7wfZXAhMB/wL6/Nf8WwVHC6kFiAIi+cUOygG3B9PxaPwW9aMChf+j+2H2Wv4Y/zwG" +
  b"sfpzAnb99QdqDZAAjQBQ9JcBKwz5BVjkL/6/8pIW7vV4BIgOye26+gsFEANjAffzXQs3BccAsvwb+X8RqQFzB//80A5B9i4ClfnRAGH9iQbk/sz+FgIz8n8I" +
  b"dQMOBuT+7QWnDYj9sfiqAxn2tAFkAYD/nvkHCBn6kv019kkCSQOo+9oA9wJO9T0BfAp2/FD57AzxBiQAoQoz+6YCIPl1C1L4WvbYAHEEyvdiA7MAHvh8Cvr7" +
  b"4P+ZBzrvL/cc/5H5dAEtCk3t3vDT5yIdChXP6QXYA/iTKCr3LALQ4Z8H+zsLBYbkJeAVHbQE9A3Z7ZrlABuLFAv21Ou3+HEVqgPeAqTp0PnPKNsXV89oBC8P" +
  b"ahZA+nrwlu3DEicZWN28+AnxfQq7CTwKQdSUEhIQNxLK+Gv8WwAZGUAaNuqc9xUC2g/X7/XgwfygHJ8NlQmE4x3+ig8XELnt9+OGCZAUMfKT7HgCRPzPCpn7" +
  b"AuNsDrMHxxdt8Er7OPmbCRkbBdDR6p/+aBz5F6gA1wBc/lLmLBhk+msCKPti+Nv6bgZICG/1zAhA9PL7Wv9ZC9AThACpAEL3u/VaFh8CP/549KgC/BI9CK7/" +
  b"4vBQ+HYJMAY/AgjqbPm5CfUQwQni6GoJYgn3CBIErva8Df72NQJ2COXxKQKv+BQIng2H7GfxzP4CC3cQtvce9MX35AtBB4YNxO4U8SkIrAO+D4P9Pem7BaP/" +
  b"bg8eBWTvU/3e6dcRqAG/9GwA6PdzAk8WK/5V/h3qywEACRoKGgKQ4tD/+v0uEWMHtPn2+6D1Kw5DFTUAkfrj5YQLMf9EDCcAxPhhAlLozg7HCZ0FfgR15WkF" +
  b"nflmC0EOzu6T+5bvAwwcCaMDkfmN+O8Bav9PCwf9f/DWBrb2iQVH/u7zUAlD9PIF5v106BoGWf7M+H0mzcx78EElmuoUJIrlMQYACd/5mQomBv0LL/xx1dz9" +
  b"3x22D8b+FPwB1nsW5BVq6xQPE9+0/4AJbg4tFPDV8ff/GCcHnAU98Z7+6vq0G7gKLu0tCPH4tv7r+IT8kgl69X0GmvrY+rUbRAJg9Ur0ZAl0A9AH/gdl6IMA" +
  b"JAiCCLHxFe7ACcEEGQjr/4XzYQtyErT66/fi+On7Aw77A2XxwfzLCQcM0Paw7d8K+f5MBxUEKOtyBaIScvzv+O/tAgZCClj/igLD7okHORSt+hny5P0K//wN" +
  b"pgE48vT4HgunCEn91u6yA2cD2wbRCDnsnQJYEesFtviX8kIHhQhTAJ//ifs0BCn8UQPA/ToDEPgE/XX+KgVU/KgDf/ytAgb5aAGR92wH5v22AFgEKfOCBe0U" +
  b"oe3wDR7u0f4cDpLybgYU9k4DwgSz9/YHyPyEB1v6MwcrBozzGhEe9Q3/QwsO+hsOg/UfBgz6aABL/I/73QSvAsICJ/gqAWUNsvPyDFjxEwMJBz347gXM874H" +
  b"0QB5BIoB9PT1Ce370QDO+jX3MxCr++UIMvSC/V8DZgO6A4P2cwD2B6P6Qv8Q+4YDFgGuAWn6IfYhC0n+FQRF9KkG7v+1BaX/OQhv+jgLF/ib/+IJngg4+2ED" +
  b"uvWZ61sPRP+xBm7nngUnCwQE3ASdDDXbZBUWEWbyYAFO8tMD/A22DVvrfOKuEA78/gFpC4bzmBHi+EwLi++ZBaQMz+IFDyL8Uv5JGev1VQHW1+UI8hT/8lML" +
  b"IuA+AiwTWQ/97p/4WQ7h86QHXhAQAXwTqtvDCWj/HwPWGNXVOgY7BEf4WgPYAJEIvgIjA8gHW/gFFt7aAQx/AoQOqAPk6OkR3P3P/T8HrPIEEajhMgx0ApsJ" +
  b"kw025zoQ2fpzC0P5wfgcBsTlTBgq/oj82gvF6rASLgMIBGf+p+uuFZnvghHR/Cn9Af5K8zETiukvEEr+6O8YFxTtKBJ9/r76Lwlz2rMTkPmaCr8HzfNLBjDx" +
  b"wBWY+GP/Wf0t7UgbxO7fEPn5kfZUFDfehw7FAd8FZxOn/5cFp+rvDfn85xHZAGPlZglvByX/1Qgp8AwKDt1VCI4YNgMqBzTbbv6KJfX1TAqO8EgH/eP2+jQW" +
  b"6/2W97fWXw1YEFwCeAHP/ecQbNrgCNYOmgOHBMjbqRDIIWD2CAzW8i8FewDiCOcPG/8nAzXh+An5DDsPFAcV3KURUh2U+U//ff+WEljfFwy4EOb7TPhZ7HQF" +
  b"qw6yCT4Jd+qbCyAbOPM+EbMNofI1ADgRbwLm++b6FfmKFSYF0OnSBur5NRDh3RXz4AnJCyojY+CUw1IqyDC2+inRuwOMJ8AD5Bc4DFXR1N1ZNyT6Y+v38cXz" +
  b"Nh2BBNnhO/NXBJkYA/w08jcMuvGgEoILJ+qDDo/xXBFg+Xvs1RO98F//SArx6XUdiABf8fP05wiQDAQD6wLK8nQB1h1wAI/ygN7/D8MFkxbkAsXiwgQCB7UK" +
  b"sd/yBtwJEhCaA7L/T+sf/Hsj3O0F9IX0vRQqD/YLAPSa7FwVDAa4+PfiOxBx/c8MXQgK5zYDeA9jCAnwpfA0CxUFDgWEA6fpWwuqFBX9pOx8+2cFwQZpCnrz" +
  b"a+64D+IUJvaN7VsBQAajArEFBvarAtQE6v0l9QUENgDcBHf/ePsH/z4EIgQh+1z8bAMY/REC3P7v+wIF1gGt/CsFFQYG+X0DQwLo94cDHQEF94cI//zh+qsK" +
  b"HPdOCAb9fPZ7Bxz8xgA/Fr7tdQOK/ST6GxSn+0UCvv+2/5EKRPVkBHcJGPiX/9/9dfxyFoLz/vZ69QAK0xIP5eb9y/J1I4QHidSqBw0KPQTND6vkqfqzDJIF" +
  b"pQWh5asGUwX6BqgIweUGFf0BAOtECzgHpwyR6a70dhQ0DGQLdt3h/GIPVAtVBwTrTv6QD7EJLwlp+gD6CAj27JYJgAcmBHUFbvvJA9UE++muAU0H/e9eAFwJ" +
  b"rPyFB6r2zghAD+XxiO6UAT0MnAGw+InuiglVBIX11A840m0PwCCh46URHvbB8c4ZjvrS+kjw5f9LHhH/bOvg9UYHDRA4AJIAQun5+HUNORl0/fHjhQJMAyII" +
  b"IQdL6noMkwUs/g==",
])

///|
test "amrnb 12.2k: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_12_2k_file),
    "amr",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_12_2k_cref_head),
    2,
    amrnb_ref(amrnb_12_2k_cref_tail),
    2,
    amrnb_ref(amrnb_12_2k_fate),
    16,
    2,
    "12.2k",
  )
}

///|
/// 3GP with the `samr` entry: the 12.2k frames.
let amrnb_samr_3gp : Bytes = amrnb_cat([
  b"AAAAGGZ0eXAzZ3A0AAAAAGlzb20zZ3A0AAAGfm1vb3YAAAB4bXZoZAAAAAAAAAAAAAAAAAAAA+gAABYwAAEAAAEAAAAAAAAAQAAAAAABAAAAAQAAAAEAAAAB" +
  b"AAAAAQAAAAEAAAABAAAAAQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAX+dHJhawAAAEB0a2hkAAAAAwAAAAAAAAAA" +
  b"AAAAAQAAAAAAALGAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAEAAAAAAAAW2bWRpYQAAACRtZGhkAAAAAAAAAAAAAAAAAAAfQAAAsYBVxAAAAAAAAAAA" +
  b"AC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAABV1taW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAA" +
  b"AAAAAAEAAAAMdXJsIAAAAAEAAAUdc3RibAAAAElzdHNkAAAAAAAAAAEAAAA5c2FtcgAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAB9AAAAAAAAVZGFtcgAAAABk" +
  b"YW1yAQEBAAAAAAAYc3R0cwAAAAAAAAABAAABHAAAAKAAAAAcc3RzYwAAAAAAAAABAAAAAQAAARwAAAABAAAEhHN0c3oAAAAAAAAAAAAAARwAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAg" +
  b"AAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAA" +
  b"ACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAABRzdGNvAAAAAAAAAAEAAAaeAAAjiG1kYXQ8WERnEFD5gYzucmPHFXVx" +
  b"AABKXLpI/oQAAFGpdraCYDwWUmRGrbsR3gdOw5W1Rw2GkFOj+WdZRS+Z21TFBOYQPOBMMRYBnlS+AszjrjA/fu4e6ZwIg1vkcxqTyH6FbPA8TF9/L9Pcqz4P" +
  b"j3K7hoX5Mv/Ra6UCGEgUL6pSxT/nsDzeb6EIZTEgnh+ksx/BiYaWeWHoC8XUpdQSsWuQCl0gPEJfgSNnvg3+DNVwv3GfvMOfIaxTq4xaKXvvoUjMUvA83nOD" +
  b"EOewCH8FgKPXtlopkLTGRVvix7DMhg7gbMuOoDxEZXEi7FoSnhumcCtX/uDfbCdlz5kffRnMJcZQkBSQPER5e3L/RkG+FtTTFNF0WIzl5kD+WVdPkgFZpXyh" +
  b"wLA84GV7d/oQEJ4fhtAwOgZtx1gOnlXyUvNX6tiWQLJcQDwgfWxF0TSWPheptA6Fxq7T5vX0dz9uFAUzOh4oAxnQPAJaHx3nwBOeFIeTNdJQp6eqZ+frqAwt" +
  b"0ITUo2lN15A81kttU7P6A34MFDJIeRjiTcWJxxzH6pLI/Uqp084SoDwATXsnQAMh3DLW80fOl7/5R95NaXquMF4SB5mJhzAwPN5ag0fxnRQ+GTrgdjyVd9MC" +
  b"Zo0DCODkX0n34A95hDA8AjYkJ0R2Qb4AfhRuZhYw8eQjhJOtqQgmf7iuz1JiQDzgSl8n4AQE/gEqI61gRZaQpCxaD1Vj8tKhFDoF2pNgPAJGJB3q7zweAJdk" +
  b"Yo4Of4gsYF/0tEx0R0+X1g1sCLA84E2CJ5/2jTpXhSXkAWNFOPv7JO9IjE0qm4Gbew7FcDwCVCcWBTAYNojEAlpk4jJf0HaDx0OnpCjwtrEOttPwPOAjox+b" +
  b"mKz2jfDyhfIL+PyyahV35gLEFv7U7lTmSnA8AkIkG/0iCG8Rr1K8F5wkwyButkbK93mISf076SOmIDzgI6EntDalWkU4otOKKf7P4YsDKGI2zUh+7Ceai/QQ" +
  b"PAY/XxYAmw5LVSkDS0YTo7BYNY0VSHFJUGakNX5xerA8CEN7JKu01k0y5CL6MA/sxLdyQibQRHND1NJEzqsJcDwgXmt+rgZx/glhIWsLIo2obhS0QPmvMxVB" +
  b"/nuuaOKwPN5LXTylyBeeAtdDTq7Cu7dSj32piB6kgUo8ftlg0oA8JlpjKrYuh54BgAFuRnVNm2wyqeA4GM0IFAREEbxqwDzeVVM3/gCWHhWDIYH9ywiTdTcS" +
  b"CB0dmpjMhZc28M/APCg+Yyi0mgt+A4DDriACIoHXVsv84asbLjrBTG+v6fA82FVTN/4Bh74BgYALrUp85vQCPN5BWYFmjFMI0Dgi8DzYQmM4tLCS3gjV0HKi" +
  b"goLoH+GYGVzhjRgYgCTPXxewPNhUdC30irFeAYGQ7NIxsYeqY2V5dOiALYBYqSk2a3A82D5xO+sVSz4BhlDKpSlR3WIFAzqd0d5zqRsWfA4KEDzgTG0yPCLp" +
  b"ngGFIbUisiKGjnvxBNRRdm9IUs3PC1fQPAIyYzb48lV+CagESvfZVT+Z/vq0xAimmsFLIjoKHWA84FJtLPDkFl4RhMGLK12zqR+xmuJWJu15BdFoR3JxwDwC" +
  b"NVdHUuIIfgtyscgDJA095G9FOJuHwHjhpzdj4tmwPOBcdC30tCoeCMDRo1AvDbXlNadlYvc/pyBkWNXZejA8AkBnR/sgHb4DHKKqTsypXvM4yl6AJ1uFsQ4j" +
  b"bNzGYDzgaHQf+wUbXgGAco6POSjEiSTka7dhplrPaflG+GkwPARNWiv9xoceFGYREQZKUj4RjOFnVmW4/1PS4YcZhMA84GJ3P/kSHF4EadUZTk6teu1hgx98" +
  b"Cq80yKXUUyIkADwEVGxH+YEdfgWHwajqkr9q6w6auWD4W8vgLGgsBHkwPOBKdEf43mP+CQ/EgXDue5wmDYCAtvj9VaqvxPhJXPA8CExtL/pUDR4BHgJUreqH" +
  b"nTMbyh6ERGQIs1YAyw3xMDwIQm1H+YKSVpikkXaMyzMIclH+nzTgbanAK6p/NWlwPOBCbS30jhj8ItMQpwdTbpCWiFtWOGO6vcqfOZ88b2A83jRtL1JqAfwj" +
  b"IpEFHb/iBoX+iI3Cd+KK7Vch9JpT8DwyXGcn9iw2vgDWILJ7dIXGje+L2FMwaU6xbyELY50wPOBFgh75AHK+BdY9tYbKCiXQWRjED4ogxHFX0Q9lWQA83mMk" +
  b"PvM+AZ4MxgDwj5je4FEZQwlYg7qjV+5neWZ74DwGSh8V5NgI3gEEwt18cZKGUpUNXQupwQ3lI0BbRylAPBpTXUmG6BW+ASKQs+zI93W/b4PtMkPbgRSxqPkJ" +
  b"K+A8FlJpR/ymg74A80I6x+IeTAT83irMyyM2Q1iRuqvHMDwoS1cqeCaSWl/5kJJYjdj1ITz+M+7qXjbWKjOnPBkAPBRSZDXT7h6eEW+NRacyzBqU7G1hHxqD" +
  b"MvgGP9urKoA8FkxrKYwkI/4TakCWYwTm9+CRO04P5pYJV2JnkdGkUDwOQmM5kjwzfgLbc00IumWYQKl/d41YEQKjWv5rGHTwPAg4ZUK4FmTeC4I0nLexyClW" +
  b"eGzzTQO+rfqwLhXn/6A8UtpzRw4fi38pPMWKWvlaGTfKL21WHFT5jgL7v0s7MDzeXGdP4aluHj0vJHwLDTbkohbOQh/kByUVCmwWWRkAPNBac0SN6gW/LNFG" +
  b"kjW1kETXdj0ADZR081LYYTJJ4rA83lssjLSaEF8P7ibmtQtNVDsw2+O1sOssoG29NSnEIDxuNJ1BSyaQf0r9FQxDEXcDEk/EZd/F+UmRSiRQbpvgPBoimz1m" +
  b"aDW+DIQjnYeSNr0I2xwcspp4x2gGJuCPTLA8FjMRP/hsCH4dzECwEmE52WcdlXJuV/7rxOw0/kNhQDwEImkupyYQngX6Q/0aj7D/7IjDvk1d+XSr47MKgmhA" +
  b"PAlD3JabPw8eAZMznRGqs76FkKBUwFNkBaUnFu7LzGA8CD5sHp7XEf4RjmSD20MR5XSsokx1j7TJQC1YSRwSkDwIVoeWtk0LXgGvRa4BMqEyU4QQJS5Ll+jk" +
  b"hbMJ6aHgPODHUyaQlwheAeEicavhhfLoyUH8hWlw3ad16jfATOA8UmR7j4v2Qf4JgcbR9hcwfy0jdSL24BKAPMOwpMr4YDwaTGkbdoIHvgHawyoWMgyr5voI" +
  b"8H3EY9q9XVdkfOwwPBi7ZDiEOEd+AeMU+QvxRdBs8z+xcjMhKrHA0KExPvA8AkBqRaiiYt4C4UVcBH5Dhis1Asz+XuVRxMb2ugp/IDwaLiSPXLTOfhV4wLZN" +
  b"PqeAJnJsWi7QeO97jxvzJ2wwPAgTU1YfntI+B4pVqN7VgZyOo5vTFDelfiOKD1XXk/A8DB4kPh+eH08RgjL/NeiZmK4RuRIcHZrUd92B5IcuMDwIEl0kP887" +
  b"fgJx5f66A4p0WoU3CrRa2B0iot5AMl6wPAYfXzw8hj5eA5RiUJBw0sYmiwsxyDmAWo3U/cbZgjA8Bh99IG0uH1wjeqR61JA+wBpd9Gunl7Are+2sSKeCYDwM" +
  b"PXlAeH8eXhR7xDDoHroRda3BlPwb8PBWb+B5Nl/wPAawZTBwvwt+C6pRizkp+787yYsS56sazrcpfDspZiA8BKskG1z6FN4TXBSy3MVNr4fFBkMp0nlFTbmA" +
  b"DfgMUDwOLHEq9hEOPhwQseDXXIwrOuAaiQmTxHAe1/cB0ULwPAgmZTYCzxh+GUtmEhlXa3F0igtD1TcZff7G24iNtnA8DXhxRgTBI/4EzeD74cc86puODuR4" +
  b"dg2Cmo39+FxX4DwOKGRGAZ8G/gTQJARFvUj08YSBs6an0bZzOg5mFIlQPAwxLEQntCl+AirhTTlon5cwCHgtaWbk7pngUfwsLmA8CChkVgKzUb4BbZJ6x1OA" +
  b"4errF0By3UrtwA2tnQKJ0DwGMmc+DJZq3gRQw4kkxtTtOgsvjHYCYjgw/GASjzwwPAYeXS4MBAseASMRbs8lE5e29fdJgBfnmYcANy/owCA8Aj1jT2SjCXSu" +
  b"AJVN2Unyr/H6MCpl2ETqFcvFRLGLkDzgPnJ+tm1Tlpt+wvTH6U3B81UGy75KwfZmxfONC35QPAhiXiYq+QTeAaIlNcnk0wDLtJYIyaKeKIBmrjkKTgA8DCAs" +
  b"+yyOUt4QkZKg4vRlZfYQF8vBw05NQFtrJMFIUDwIZGM/ghw9XgPPMzy0Efhpvw0RFjJca0a+c/bHs79QPA7JWB/CMIveEppx3vc3hANO8kFfM5WiznIu0g+x" +
  b"MrA8DlpkR5QUIT4DvVX8JvnzJFcuOWqJlPwO77GCAqXdIDwEyV0nqNoR3gQt8r0jgKpr46CvCIkGeV8BmQjBbN9QPAYyWkcrdJweEbsjl8ZCoaeOwmYojBmY" +
  b"ULb2jHrjzSA8BrsuFYAHD74QVeIjKtZ+4EVVlgoE84HrJOYUQd/csDwEP19O1T8EvgBuwK7JthrHIfhdJV0p7WyejemnPo0wPAhMZ1eGJwSeENZiVLJYcutd" +
  b"UsaYbnIoGOlxfGM79JA8CGxtT4gAGl4RkxBlpH5r208e9PpfPK4DLFA+F2XXsDwIQmce2TQJbxnuMiuCyG/uHxKC56Q0MgkUVuFkd8SgPATZXac+8mn+B6gy" +
  b"9avKhEEPW9Pa/rzIp+uNRuc5GnA82E9gHC1NE14XZbPElZ07VwTfX8B1LaKqtqKhWezzwDwAqVozsJoQfhKG4g4AD0P5nOTQhEQToHUpmBVoS2jwPN5HXy6+" +
  b"xzQ+EBvDx/SgjFYsJlT8/HslI/hmuF5K9vA8ArpsNtVFcv4FwGMFmrNHgayZRlIUWhi0IEDI9YleEDzgOnEbqtQQ/gWOckmdQ4bL4zQuNLMi/SPs2k5kdRtQ" +
  b"PAQ+JDZ/8lC+AaFhD80kYLGbamzFQDf8vmW1YWd5GoA8CCNgK9reDhwngBOjsNH7yepMb7B5h5xnbjlO2h6ssDwINVo2f+ZUHgEqA0/HbdK4nOVYjOd/rEx6" +
  b"HpdqgL7QPAl4JDsBbhJ+AM1S9iqaOui5uEgKuHK/FwDVD+gZ11A8CXhpMvbPAHpVSiWDI6uoDGCe9UOWppmKBgAt5bGb4DwJeCQn5nBWHCLPsikW2o7QwACV" +
  b"RZRVBudaJHn54rLQPAg9hSfmNyjeA9RCDIxrDvyKgrV+iU9ABz1WkYJ7aZA8D3gdI6yMKutVKKLDXeyw7zM8uI4eCddDmST78/b/kDwax4Ahgd6STxDU43m6" +
  b"eB5pX2EVSfi0uCBikpPUIZ6gPEZWKBGB8IweBYHStIwO5OBe4yvrHsoZrNWAaa5E8sA8CHNaPXO7G94TIlOetjlfl33DCpSbRWwzQYgHGf48kDw6QmNK4m4h" +
  b"3gU7oB0ymnShEVozA3qsWq9ME6JsxEiwPOBlZKZyUhh+E6EilA60Jdh25OnRqruyyzHE2mNFKpA8RshnSB4YET4Xa/AuilYBqzmdcOx2HjT1AEdZStOp4DzY" +
  b"aWw05XqAfh+EgmggOscdlW6Lj/aC1I/z+ONAojmQPER6aB9EcA0+H4FxBOgiOGbDagOHUr+iM0YAmX+HXtA8OmgsJ+Z4DR4XikAVMuCs3/NKr6ufvCqgGFs/" +
  b"jBFb4DzYZGBGszwLXhWREJfuXHim7d86h/oLs6j4JBGUR65APOBaZB9u0AM+FopxHFN83o6BPGk975xJen0jKkMYwgA83mxfRfsEGh4L7MCalu9zvFNG7jsM" +
  b"wy7aqFN36+FdYDwETXsvUWo1nlB6wUH1I2k7OBs6P5Q3XJR50mxaAWgQPOBccSXUnBgeDPAxPRTL8Rwt/Y6ft5VA3GiTzt4bKoA8CFt7HoEAGv4bLuBGYYfc" +
  b"cpRDQVGEkCv66yg7y8+ekDzgXGdLqdoj3gR7gc0IyvY2FL0cg8vqZ44rflY/6wwwPA45eSb93YC+FH7wpSp+0qS3n+bQ/mfvIBZD4Xp+EiA84FV1R9GkA6+R" +
  b"NeBrBJjrTNiReYYy3FGjz3pyk6rJIDwaW4Ev+bYevgBfgI+Ks9ie7AC5r24/A4H9LbJJFbLAPOBaZE/s1lR+EN9x5kBxDw3XTWzmVnHGrmLo95x5wIA8Gj5j" +
  b"L3u8Gp4ZhRAi9xgcR0oGL3YHn688hijkjzgiIDwgW4BP+coHnhLB8UY5IPUGJ+wGApRUC+l7+Nj1dKMwPOBDeX/5mpD+ASowzRZ/WZzgB624hMaUer2IPD5q" +
  b"cGA8Gj5XQ4BWA94Qd8FmXTfcIsraIvGnFlBPWfw7c6pIEDwaWl1OLiAS3gNhAH5VL1J97Yu5245nMygtcTGxg1+QPN5zUR9EXpj+GS428/GVRL78/Kx9c2V9" +
  b"AwMDNCOerxA8Bj9xPkX8lR4dKFARwftR4gN5x1vXzBfKfPTH0wxysDwgXVMfxF5YPgWCNEzl9V4zUvMcx2ms4EYld77iBUTgPBpyZB/5mB4eF4Ez5CGIAZAd" +
  b"cZud1wl6GqFgJX6AHTA8Ol15RVOnxZ4fO9KnUDrPdQRzmtIGwRLO8MAwyaKnoDxCWmguvJgQ/h+GYqLpkjnZrAJGDEi/h7gliZVIpQGQPCBVeRU8dg1eOYHg" +
  b"1jFAw6YiRtkGXBpJWuDczYxxctA8VnokLDwyA94XgREmztcxErPNiWA5Nmj++ML+U1uSIDwgVGQgeQoT3wbVICU5YM9EZqbgWlTiBXvRf9LxN1tQPFZsYxvK" +
  b"oIP+HpTxVdx/VSoCDVUHGjfV+RUym83+GmA84EFhQ6mGAf4fKEEBs0IjglUYR4g2Ro+2XVvkvo8eADxOWmR3HwoM/hsrUKvGIcW7XgG3adBKz3rvUhBy3BAQ" +
  b"POBDY0cfupKeH4NCKGBALXPESNy8Kc8wGzkjpO4AR5A8RENjHx3jCD4XgxC1EOwTCh2lvcPNIQABPI23X12ncDwgQWMnTwcAfhjgsWP1tB0lQaWK6uIIhufn" +
  b"Y7ETmSaQPNg/eB81khyeFQyQt+aHFCMg7f67OKtcp+RUhA+hWtA8IENjH1sGA94bGvyjd8VM++5csY8eQgQdbO4kuX9JQDzgOYAfGRcUvgrsoYperNMMii8a" +
  b"O3JJIWEetmqqcKKwPCBbWkcdsoy/AcrTw5Vl1s0LX5Uo7PFywyOSN6lapXA83k13J57QCX4YxRBzf8jdl3UgGwMaXGCbJigoT/wCgDwSIh1DNSoBfgEpks6u" +
  b"tFJhH9/qFrHj0o+weO7s9viQPERCJCef1CP+ASrwNjG4zIKJ2ZeH3uZBRbovm/RQI0A8GjRkNp+WTf4BlKFNzOqpRtLBChw1o5bVmKJWY/jgcDzgN3sXF2oH" +
  b"/CsL4Fk/cI9OOAkcj31yWAl1JrXMb7UQPBo3cT8W1JB+ASXR/i7Y5wObR0CzKZpEKd7ZKOAOSlA84F9eF5/OlD4C1mUW6vbuHz4HxjaFC9agbfMQ424D8DwO" +
  b"Ih0dtX8R/gDYEs3MsZVadE+V8pzDAdxYcBe8K2+gPNhtgR6/LB4eGb1wU7cRz/4EWMZ7JYxkKjptKHly+LA8Hsl7F7UUBp4JKMKjP4+R4BNK4AdyqSg6p1By" +
  b"zMP3cDzgQ4AXU4wYvgGswR3xcgdrqKxYIGBsBh54lK+4WbbQPDLJex9CLhj+BFcRdGaedKrkuMxm5iAlfyiHKLtKXMA8EsmIQh27FD4AhRBKMojEDRGf+Mwl" +
  b"oodrqxTO1+u2EDwgPhMcNGaBHhDw9PRPHoYIGKN/HAt6Zfd5caC9McAAPBpt6R3M1iv+E4hgpy4j85mA1j12X71FdueHJjqovDA83smTjgc+K35L5qTZn5lT" +
  b"bTCbpECrzVFX7+CRtyA6IDwIc38mSLQQ/j2AMDA/hVXaYctjF9QdL0W5JtKfOn4QPN5Sb1ehfR4+G4GWbwM5V0rnOVgZM8KClswdSAWbG+A83mxpTo4cF54f" +
  b"aiBcY6PiwyhrTMrfoPD+ywiJmHJ34DzgZYdOPkYXnlpddBxbnfbB/m4Jktz2AjY0Ggcmi0DwPFJ8a1aJNHLeH8WTAsPaZ5RwR4L3MhMgvKOvrdnUUZA83lpp" +
  b"TpOEI/4elvStutZIywyfhQ4eGlcKjVb/1Vc6ADzmb1NPhyQtfoLUJZucqy403yAzb233cCSQKaul+uBwPFiIZ1eGPja+NYBBznPr4auTCYy+DXkfaQZCLq8O" +
  b"OQA83l8wR4ZMNf4tKsOMwo83n107goncMXaMqHBG/ok+MDwiknpHgY4ePh+AwTJVWme9N2L6oRZMnLU4vJAYsDtgPE6HJ0OBdi1+HyvBgsnUeKD+63q3ubjh" +
  b"RZw3HPXn4LA8GrknKYGES14fgJHqUwUcr64j7ejT2etMb5nJPpB84DwoxoEjKm4Xvh8qocHHCHWCpPNdYsGYNw4Qci6xRifAPA40Jxsqeww+CSiRC3Q5TBuH" +
  b"U2il7b0m7sCJr0i844A8JthnlHvqHp4Zl/NHjBJ4WMKbU5NYGZT1Z7OAbkaFEDwcNGcsexwLfgj2QPvyt8+Yvtmi5oWgRMbdP7XUF0rgPB66J0GEMh48LmjC" +
  b"UeaWKEz9mHQ1Np7+e0PtBt9EohA8JD9/KYBji/4IfRAb5sGui19CIHV1aNuAWNri0BsWcDweNXgxgL8sfhJjgmL666P4crmACrRPIN5q/uH5m7ZwPBw1gVjV" +
  b"zS0eAH0AS8V3K9K82sqpa7sdJ8Ew4Y2NmlA8HiN3MH7Xcp4Dt2JaziJDUeyG4gZcSPwUjORrkHBf8DwWMmQgf7weFokqsL9B04360n3Q+hBcyGPSu1QVpXRg" +
  b"PCJOJEEreSweAMrCDi1+eeATBC7H80+1Am6bChHwXxA8FImHG6iINL4T72On4wNU41RAgrzK+gPXxIVW86c7YDwIJWQ41nWHnh9MENA9z8XXkwou3zIvWAwT" +
  b"QKkH/onwPB67Y055gh5eDTijfZWZXF+Ee7oB4kRcMgkIF+qWcbA8CB0sINV8h74NLbPcFbP1prtmm43060eOuepQ9T4YUDwaNF1OeZyBdtkqwwTMa4RD+rG9" +
  b"K4gSJrLmgZFmfwUgPAgibBp5yJJeEdBRqlz0dpI7tL5IbElkLN2VB+yRajA8CDIkVvtwCx4A95JtnJUY1Fx0NQxj2J5umXEwck13EDwIQ3hOSnKEngUgI8BR" +
  b"xh/Y3E0IgO4OCrKgFm9bkUJAPAgzgXs8YoB6U/zR81hnjR/cj4BBbe7rQnay4HG11ZA8BFpdVmwjhP4A8zSssRj1CQ37X1o/99X7ROsRT6FY8DwINXk/f35B" +
  b"ngF+A/i9qRiL85zbsA+gmx1yQnJ5IB8QPAJsZF5+VwseEIIUIKGbjwDamLTtmZhj2rduAeZDsFA8CDQkRj0YmLwj44NkqNeqdvmsOox6KrQHAbH8vr8CcDwI" +
  b"VCfuXUSZXhDaxzyiGusXoyEKEnO7CRLTTBV7tNCwPCBpdCtXZpheAdjgNnZcFf+XafG2Fb6OqKvat628grA8CuplT/4SsP4C0TR8ImJox1XqxyaboYq4bH+3" +
  b"9HKBcDwGZYBVLr1RnhL+EPYpEJ+IZ/kePWr8gZmRC3t5whcgPNhxXhpf+gH+Fiy0kG2RtGKDAJV8eO1flVrgmwsCJVA8BGRnON15At4TaRBU8nPjZKoJ6WV9" +
  b"v67jn0Vk++dCMDwgeSwaT9IGHhD9fCcifBwndmt6jQfpHK3Af4KHsiTgPAJseUOohAOeFW3QwDk31EfwRYBbOD6ksTHNnLH4VLA8Gk2AFjauMhpH3kVuDUQ0" +
  b"UZ8BFgwUFgs7SXwA+sjPEDwEX2JOeitDlokZACZI/rPCQ00FWMmWK1n68uNBogUAPOBDgRY/NEPeAHHkwqTZq6R/1k5pHQYpEQnxaAETjzA82QaVNLN2nP4f" +
  b"00B2vwK4nhlAPY+yc+B7aNMLdPFwYDwIPZ0TxqwEfgaR4v24hfLnvLHeUrkd4ejHZ9f5fGLAPAR9IZWyUo0eDuwDHKIPiKZf8BHIGTiTHw3bpxIUx3A84LmL" +
  b"F61mCT4feeKgoCg/QZxcH075err6sKZg8yUx0DwORiQ41C8D3g0K1AQb6KnsaBkO8zezA9QUTnjpgqwQPNg/iQzFVLQeFytSrB9ZUE3f87i4v8TP9DBmb+kc" +
  b"53A8GjmRIYAsYZ4MfeaEn4NcYz3KLaKWyasfqcprWIb1MDwaPhQRgBLHPhWAPPRZNlH8MaF8p/wlCtQUQWMYQKkQPCBCKBkqrnjeCH/yuHL1R/3tEHt3S7u4" +
  b"6aWOBHCTDKA8DkI+cH/8094Q1lzH3xdWwCqfVfcHOgm+RYJroohaYDwWQXpQf+idek+BNKNHp5eOeSMhKmU9hts9CAo5YsiwPAY4KRB/7ZZWjYM9pCfDFqsu" +
  b"i+oZM+OWa03zu4lenHA8DEN6GH/jF9SvhHRtMd+DnfcF+9BWVTzzldVL2LXCQDwGNi8ZKo44dprRETRVSHdkunyBEwtL0D654rp7VauwPA4+Vxh/nw+eA4Ty" +
  b"WEtk0cfeLyyjQCVpBSmXhF8/A5A8DLujJnhPv88ZKJ3pB/7kDnxxaQDrqyZTOkJvN8NVMDwgcnUqdXuJfh7XJb7MU6o6jaX1lkbsnFJMxbUIkpggPBrIHRso" +
  b"L2leEtXznuVjLmw8J0yXHQiO+EAC1+xDdAA8KEMsHnhjaJ4bgDWGCzszMKab0W9KJQ4desr0zNPr8DwgQ1okeu+lng0rE2uIqz2944bUvZeiNZFlhvSpa+OQ" +
  b"PCg+bR54ZegeCYB1i1z+iQY3wd6fGa+z8I+rkcthrjA8KEJnJHr7th4ZK/HzL+OcsVaBO9J5B6PR6rjCqHVgcDwoQ1oYf/+0nhzVY3lrAYzxrKgNAs/uEaNI" +
  b"rT+2ABBwPDRCbSkqq3qeGSuBjQAPSLVdEWLyTr0DwsN/x9Y1W5A8KMhsIH//Wl4Y1SMPfbdIqy4CR2HOhRtzcbAQdVLYsDwIPGct7hQDng4ScirxhZVE7oz+" +
  b"9RQaoHeDXlUFe/9gPN4+aU5t3z6+Wy91sUyckgW4asVasm8mRz1r2dhjBjA83kJtJnjSPl4HhDP+XMzMRiyT8YxjK7QSKYlka3H0IDzgTGwme0Y9XhkvtCvK" +
  b"fkrKfBDkH6rKbELHz5KjQZpAPEQ+axZ7WSx+F4Xi7MwG5NsCiMoK/Ap5nPMrtv4Ok2A84DZshn5gW14bhJPw5Hputf0/UvB2FMkwhPLxmozSUDwEMmMufi5D" +
  b"PgU80klmNI5quWSQTS2jD2XbDdgPtWjwPOAjcTZnQDb+AHxlZ/SgqgS/SPFD50YfrG5b90L4JZA8AiZxPh/eQH4JgyHobKKDM3YjGVc24Qh1RCR+NwMyIDwI" +
  b"HDI+MdyG/gE0k63vSLqG1uAD4IQb38R45cP8CRHgPAIzVkdd9ARtO/RC222K/Pg1+uupS6ssKRswI8HoZcA8BDFzPwcK3dwiqxY9JHlPQBQxlIebNAjaUCov" +
  b"1KzdoDwCuVYfFy7Q3CLuUl3lrG7pg7diycUqDS7t5oxhCnigPOBnZ82+HhQeEKCLRJX0pWLvRPxjZeG26px86atISAA84LlYJxxOAt4BCiTFRI890uAZDFjO" +
  b"tLYt0hnn80oz4Dzgc2A1m+AebxB/1DtLFAHUJk43kK9zmof02gzgx9jAPAIpjUnEplLeAM8UsPwHVd3h63uvTxbzmgsKf2PfyNA8Gjd9JYT3Rfwj3CLrEPpZ" +
  b"zMDORqZ/BuA71uuUuKih0DwINVhfqc1k3gD2Fg54vch8loBgDWWF2a2mSOwvmgswPNhHkD+BFs++AyNS7gQu1GfIKJYfwfaHQtdqHJZpg7A84CNaYYB4sH4L" +
  b"KiXIhOLzFV89QaPnVtImEn4FAQuSYDxEQCNOfK/CfhEqsZOhaam8M1Cc0+vWbWBIl6ZUifgwPNgiaBGAHzT+EYFTd6grql5J+DCLCDQIU05Y5ZCTaTA8Gjhj" +
  b"UYA5en4FkiA4VFeVyYLDGlLi7whzos0ZHKdJQDzYRXkZgzDSHgGZMi1UZW3g2kXkEm+9AUMDJOC0gUMgPA6pXUGNH7QeB5ATOdaF1tfMm+UHwKYSRZfwnxIB" +
  b"maA8CD5jLw2lDL4B70IfobvCy+8RmlxyQpAhxmdfilJjQDwEMmNDkYZP/gyIwXjoC2yxlCx3lKk6wATkdaW4FWWgPOA/bS8v8HL+FDhDeX7r4agoeHt3wlEX" +
  b"1f4HKgzZUHA8DrKDPnw6ZZ4MetABK74gy11hu060QihBH2nDLN6QgDwIIxw+bf4UnAMBZCdmYmhD5GlZbge0gslIckdFaZQg",
])

///|
test "amrnb samr 3GP: decodes to the references" {
  amrnb_check(
    amrnb_load(amrnb_samr_3gp),
    "mov,mp4,m4a,3gp,3g2,mj2",
    "amrnb",
    8000,
    1,
    45440,
    amrnb_ref(amrnb_12_2k_cref_head),
    2,
    amrnb_ref(amrnb_12_2k_cref_tail),
    2,
    amrnb_ref(amrnb_12_2k_fate),
    16,
    2,
    "samr 3GP",
  )
}

