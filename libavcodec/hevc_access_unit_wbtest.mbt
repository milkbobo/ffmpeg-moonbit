///|
/// Tests for HEVC access-unit assembly and POC tracking.
///
/// Reference stream from `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.8" \
///          -c:v libx265 -pix_fmt yuv420p \
///          -x265-params "log-level=none:keyint=5:min-keyint=5:bframes=2:open-gop=0:scenecut=0" \
///          -f hevc gop.hevc
///
/// `trace_headers` reports decode-order slice types I, P, B, B with POC LSB
/// 0/3/2/1; the assembled POCs are 0, 3, 2, 1 and only the first unit is IRAP.

///|
let hevc_gop_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpWQCQAAAAFCAQEBYAAAAwCQAAADAAADAB6gIIMWWVkuTK8BaAgAAAMACAAAAwAoQAAA",
  b"AAFEAcFz0IkAAAFOAQX///////////8DLKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltM",
  b"aW51eF1bR0NDIDE1LjIuMF1bNjQgYml0XSA4Yml0KzEwYml0KzEyYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAy",
  b"MDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIEluYyAtIGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTExMTEwMzkg",
  b"ZnJhbWUtdGhyZWFkcz0xIG5vLXdwcCBuby1wbW9kZSBuby1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0tMSBiaXRkZXB0",
  b"aD04IGlucHV0LWNzcD0xIGZwcz01LzEgaW5wdXQtcmVzPTY0eDQ4IGludGVybGFjZT0wIHRvdGFsLWZyYW1lcz0wIGxldmVsLWlk",
  b"Yz0wIGhpZ2gtdGllcj0xIHVoZC1iZD0wIHJlZj0zIG5vLWFsbG93LW5vbi1jb25mb3JtYW5jZSByZXBlYXQtaGVhZGVycyBhbm5l",
  b"eGIgbm8tYXVkIG5vLWVvYiBuby1lb3Mgbm8taHJkIGluZm8gaGFzaD0wIHRlbXBvcmFsLWxheWVycz0wIG5vLW9wZW4tZ29wIG1p",
  b"bi1rZXlpbnQ9NSBrZXlpbnQ9NSBnb3AtbG9va2FoZWFkPTAgYmZyYW1lcz0yIGItYWRhcHQ9MiBiLXB5cmFtaWQgYmZyYW1lLWJp",
  b"YXM9MCByYy1sb29rYWhlYWQ9MjAgbG9va2FoZWFkLXNsaWNlcz0wIHNjZW5lY3V0PTAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAg",
  b"bm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMyIG1pbi1jdS1zaXplPTggbm8tcmVjdCBuby1hbXAgbWF4LXR1LXNpemU9",
  b"MzIgdHUtaW50ZXItZGVwdGg9MSB0dS1pbnRyYS1kZXB0aD0xIGxpbWl0LXR1PTAgcmRvcS1sZXZlbD0wIGR5bmFtaWMtcmQ9MC4w",
  b"MCBuby1zc2ltLXJkIHNpZ25oaWRlIG5vLXRza2lwIG5yLWludHJhPTAgbnItaW50ZXI9MCBuby1jb25zdHJhaW5lZC1pbnRyYSBz",
  b"dHJvbmctaW50cmEtc21vb3RoaW5nIG1heC1tZXJnZT0zIGxpbWl0LXJlZnM9MSBuby1saW1pdC1tb2RlcyBtZT0xIHN1Ym1lPTIg",
  b"bWVyYW5nZT01NyB0ZW1wb3JhbC1tdnAgbm8tZnJhbWUtZHVwIG5vLWhtZSB3ZWlnaHRwIG5vLXdlaWdodGIgbm8tYW5hbHl6ZS1z",
  b"cmMtcGljcyBkZWJsb2NrPTA6MCBzYW8gbm8tc2FvLW5vbi1kZWJsb2NrIHJkPTMgc2VsZWN0aXZlLXNhbz00IGVhcmx5LXNraXAg",
  b"cnNraXAgbm8tZmFzdC1pbnRyYSBuby10c2tpcC1mYXN0IG5vLWN1LWxvc3NsZXNzIGItaW50cmEgbm8tc3BsaXRyZC1za2lwIHJk",
  b"cGVuYWx0eT0wIHBzeS1yZD0yLjAwIHBzeS1yZG9xPTAuMDAgbm8tcmQtcmVmaW5lIG5vLWxvc3NsZXNzIGNicXBvZmZzPTAgY3Jx",
  b"cG9mZnM9MCByYz1jcmYgY3JmPTI4LjAgcWNvbXA9MC42MCBxcHN0ZXA9NCBzdGF0cy13cml0ZT0wIHN0YXRzLXJlYWQ9MCBpcHJh",
  b"dGlvPTEuNDAgcGJyYXRpbz0xLjMwIGFxLW1vZGU9MiBhcS1zdHJlbmd0aD0xLjAwIGN1dHJlZSB6b25lLWNvdW50PTAgbm8tc3Ry",
  b"aWN0LWNiciBxZy1zaXplPTMyIG5vLXJjLWdyYWluIHFwbWF4PTY5IHFwbWluPTAgbm8tY29uc3QtdmJ2IHNhcj0xIG92ZXJzY2Fu",
  b"PTAgdmlkZW9mb3JtYXQ9NSByYW5nZT0wIGNvbG9ycHJpbT0yIHRyYW5zZmVyPTIgY29sb3JtYXRyaXg9MiBjaHJvbWFsb2M9MCBk",
  b"aXNwbGF5LXdpbmRvdz0wIGNsbD0wLDAgbWluLWx1bWE9MCBtYXgtbHVtYT0yNTUgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1p",
  b"bmctaW5mbyB2dWktaHJkLWluZm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1t",
  b"dWx0aS1wYXNzLW9wdC1ycHMgc2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRy",
  b"MTAgbm8taGRyMTAtb3B0IG5vLWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFu",
  b"YWx5c2lzLXNhdmUtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5l",
  b"LWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0",
  b"dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9y",
  b"PTEuMCBuby1keW5hbWljLXJlZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRp",
  b"b24tcmFuZ2U9MS4wMCBzY2VuZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209",
  b"MCBkZWNvZGVyLW1heC1yYXRlPTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAA",
  b"ASgBryYWfo23npo+V1EWQfeHUXHUZIq2WZoChQYQSlN9HPO7JBpIZd4nOkjVb5XtCR9vDM59QFScz7DEeyWmozRRulA1Gg46EnLx",
  b"W4ZtMT4WhPvu7JW6f//tpdx0eYErd7e47+kEMXNECQgoN0jbRwxVZ5yTgviYS/5mwOPnafZUcIcCIn4TTuZMvlxfidGXJFVJkRY0",
  b"cj04noXP/gtiyogy8FuS5/jUxLwjiCzsqNL0dfvwgK/tXVhirmj1t2uoYdjLQCeZqqpjAkhCXEbIjWf37+7CtEp1MCp1IUcoyeOU",
  b"eS1ztPYZ+3+exnazVy71kwxLV2qW1kRonz8ZVplLdKHODxPikB8eGgwrnBYlHK0XC8cuTeq3TWu9+a8AHtpEnAhbZZNWIZ76fICE",
  b"5X0Zp2A5qlZ3Y3LBpTyN+wUC8+Sq//q5r6WHjEsZD0+gDzTqVutFTeFg7cmdkQ7/AxHkGX58u77mmptkozbafSjo5nMv1IeY0E+T",
  b"SiaY7UMBEVOoqWoV1beF3DyUf4s1A4f6BZZGT58CgTYA+1MEXvf3DHt5nAlgn9hq4OkHBFleRPeHaVYcyKq12JZU4cnEJmK00M2j",
  b"305LYhOTKTmz7RrMMBb83exd6QS6ifCzibcWFWX7Ly/naUWVyoRGXh3/XR9PX7yiysZVPM0AGlrHXZ1ngL0XbNmg0WyghAey+baI",
  b"L8Wh7rY6tID5Q43qGkamwqgGQz7aYJ42Zbr+Tzy2o28QDsSgZTDc1ndXsiMYrx3rh6F1QtVvtU3eCUxkVOlS/SyElRphQaprfHis",
  b"P7XJSv6of6uJ7dtl4GAZIq9KOCjp12GxNH0wbAiNcCAPFVpuawiNt6gygvRsqLiXX1sJXBO5zHThTX+aVfYyhWCGuplPv814H144",
  b"+lO6XU9Wqyzxm8Y3afmllgH+fWuc/n8yyDUbFB8zRtcfW6W0VJSX4q9InKiozMm0HEk2eS1oVZb0MA4AcrFSqd/Y+2R7OC3dVCzu",
  b"6PQVFpPB2nRrW9OJmN3I6MO0meITmzB1Waj/ya4qE52detUIEjDFzjHAFAtF8paxi2QBIM6aYqIlFVhL/7pZgxzUt0EOndLU208L",
  b"s4SjSWUJHbCYAPAu1LJhpN3fpEKMBD40X/l7rc5t3TlKGW35vwnWrkPBIvqPo4uMN+X6SJruP05/8AAAAAECAdAZX4QxkT/sr0+K",
  b"UyPv//x/8u3lfPbaQf8plLugGGNTGrYq6fdTjjXwiCspJ4DSssAAAAABAgHgRJfhmf38A/q3hQDNgm/Y4/UD3hgAAAABAAHgJP/6",
  b"LEbvbfvA8dR0RH1zdsIqkVrwxaGI24A=",
])

///|
test "hevc au: B-frame GOP POC and keyframes" {
  let bytes = @libavutil.av_base64_decode(hevc_gop_b64, 100000).unwrap()
  let aus = ff_hevc_split_access_units(bytes, false, 0).unwrap()
  assert_eq(aus.length(), 4)
  let pocs = [0, 3, 2, 1]
  let types = [hevc_slice_i, hevc_slice_p, hevc_slice_b, hevc_slice_b]
  for i in 0..<4 {
    assert_eq(aus[i].poc, pocs[i])
    assert_eq(aus[i].slice_type, types[i])
    assert_eq(aus[i].is_keyframe, i == 0)
    assert_eq(aus[i].is_idr, i == 0)
    assert_eq(aus[i].is_irap, i == 0)
    assert_true(aus[i].nal_count >= 1)
  }
}

///|
test "hevc au: single IDR stream" {
  let bytes = @libavutil.av_base64_decode(hevc_one_b64, 100000).unwrap()
  let aus = ff_hevc_split_access_units(bytes, false, 0).unwrap()
  assert_eq(aus.length(), 1)
  assert_eq(aus[0].poc, 0)
  assert_eq(aus[0].slice_type, hevc_slice_i)
  assert_true(aus[0].is_keyframe)
  assert_true(aus[0].first_nal == 0)
}
