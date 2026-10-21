///|
/// Tests for HEVC prefix/suffix SEI parsing.
///
/// Reference from `linuxserver/ffmpeg:9.0.2` + x265:
///   -x265-params "master-display=G(13250,34500)B(7500,3000)R(34000,16000)\
///   WP(15635,16450)L(10000000,1):max-cll=1000,400"
///
/// trace_headers reports SEI payloads 144 (CLL 1000/400), 137 (mastering
/// display G/B/R primaries, white point, max/min luminance) and 5 (x265 user
/// data). This also checks the 0xFF payload-type/size continuation walk.

///|
let hevc_sei_b64 : Bytes = bcat([
  b"AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoCCDFlurkyvAWgIAAAMAAgAAAwAKEAAAAAFE",
  b"AcFzwIkAAAFOAZAEA+gBkIAAAAFOAYkYM8KGxB1MC7iE0D6APRNAQgCYloAAAAMAAYAAAAFOAQX///////////9ULKLeCbUXR9u7",
  b"VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltMaW51eF1bR0NDIDE1LjIuMF1bNjQgYml0XSA4Yml0KzEw",
  b"Yml0KzEyYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIEluYyAt",
  b"IGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTExMTEwMzkgZnJhbWUtdGhyZWFkcz0xIG5vLXdwcCBuby1wbW9kZSBu",
  b"by1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0tMSBiaXRkZXB0aD04IGlucHV0LWNzcD0xIGZwcz01LzEgaW5wdXQtcmVz",
  b"PTY0eDQ4IGludGVybGFjZT0wIHRvdGFsLWZyYW1lcz0wIGxldmVsLWlkYz0wIGhpZ2gtdGllcj0xIHVoZC1iZD0wIHJlZj0xIG5v",
  b"LWFsbG93LW5vbi1jb25mb3JtYW5jZSByZXBlYXQtaGVhZGVycyBhbm5leGIgbm8tYXVkIG5vLWVvYiBuby1lb3Mgbm8taHJkIGlu",
  b"Zm8gaGFzaD0wIHRlbXBvcmFsLWxheWVycz0wIG5vLW9wZW4tZ29wIG1pbi1rZXlpbnQ9MSBrZXlpbnQ9MSBnb3AtbG9va2FoZWFk",
  b"PTAgYmZyYW1lcz0wIGItYWRhcHQ9MCBuby1iLXB5cmFtaWQgYmZyYW1lLWJpYXM9MCByYy1sb29rYWhlYWQ9MCBsb29rYWhlYWQt",
  b"c2xpY2VzPTAgc2NlbmVjdXQ9MCBuby1oaXN0LXNjZW5lY3V0IHJhZGw9MCBuby1zcGxpY2Ugbm8taW50cmEtcmVmcmVzaCBjdHU9",
  b"MzIgbWluLWN1LXNpemU9OCBuby1yZWN0IG5vLWFtcCBtYXgtdHUtc2l6ZT0zMiB0dS1pbnRlci1kZXB0aD0xIHR1LWludHJhLWRl",
  b"cHRoPTEgbGltaXQtdHU9MCByZG9xLWxldmVsPTAgZHluYW1pYy1yZD0wLjAwIG5vLXNzaW0tcmQgc2lnbmhpZGUgbm8tdHNraXAg",
  b"bnItaW50cmE9MCBuci1pbnRlcj0wIG5vLWNvbnN0cmFpbmVkLWludHJhIHN0cm9uZy1pbnRyYS1zbW9vdGhpbmcgbWF4LW1lcmdl",
  b"PTMgbGltaXQtcmVmcz0xIG5vLWxpbWl0LW1vZGVzIG1lPTEgc3VibWU9MiBtZXJhbmdlPTU3IHRlbXBvcmFsLW12cCBuby1mcmFt",
  b"ZS1kdXAgbm8taG1lIG5vLXdlaWdodHAgbm8td2VpZ2h0YiBuby1hbmFseXplLXNyYy1waWNzIGRlYmxvY2s9MDowIHNhbyBuby1z",
  b"YW8tbm9uLWRlYmxvY2sgcmQ9MyBzZWxlY3RpdmUtc2FvPTQgZWFybHktc2tpcCByc2tpcCBuby1mYXN0LWludHJhIG5vLXRza2lw",
  b"LWZhc3Qgbm8tY3UtbG9zc2xlc3MgYi1pbnRyYSBuby1zcGxpdHJkLXNraXAgcmRwZW5hbHR5PTAgcHN5LXJkPTIuMDAgcHN5LXJk",
  b"b3E9MC4wMCBuby1yZC1yZWZpbmUgbm8tbG9zc2xlc3MgY2JxcG9mZnM9MCBjcnFwb2Zmcz0wIHJjPWNyZiBjcmY9MjguMCBxY29t",
  b"cD0wLjYwIHFwc3RlcD00IHN0YXRzLXdyaXRlPTAgc3RhdHMtcmVhZD0wIGlwcmF0aW89MS40MCBhcS1tb2RlPTIgYXEtc3RyZW5n",
  b"dGg9MS4wMCBuby1jdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1yYy1ncmFpbiBxcG1heD02",
  b"OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9MCBjb2xvcnByaW09MiB0",
  b"cmFuc2Zlcj0yIGNvbG9ybWF0cml4PTIgY2hyb21hbG9jPTAgZGlzcGxheS13aW5kb3c9MCBtYXN0ZXItZGlzcGxheT1HKDEzMjUw",
  b"LDM0NTAwKUIoNzUwMCwzMDAwKVIoMzQwMDAsMTYwMDApV1AoMTU2MzUsMTY0NTApTCgxMDAwMDAwMCwxKSBjbGw9MTAwMCw0MDAg",
  b"bWluLWx1bWE9MCBtYXgtbHVtYT0yNTUgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5mbyB2dWktaHJkLWluZm8gc2xp",
  b"Y2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1wYXNzLW9wdC1ycHMgc2NlbmVj",
  b"dXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gaGRyMTAgbm8taGRyMTAtb3B0IG5vLWRoZHIxMC1v",
  b"cHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLXNhdmUtcmV1c2UtbGV2ZWw9MCBh",
  b"bmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVm",
  b"aW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVm",
  b"aW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJlZmluZSBuby1z",
  b"aW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFuZ2U9MS4wMCBzY2VuZWN1dC1hd2Fy",
  b"ZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNvZGVyLW1heC1yYXRlPTAgbm8tdmJ2",
  b"LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAASgBr3hV+UXnLs5zIb617I8lqV0ZBw/rG+Ic",
  b"FV0hinRz945Px6VyR/KBrz7GBNU7GP7PNeoKExgkhL5hdfYeliivAVq8lzH9lNt1x7MhighYP///FMyGCNWmE+OcQdxFhnI6YRtz",
  b"Pys8vBf6PWHLE3Hb6kQtoFEJwEO3o8MCqh82DGk/LU+3i6WV+hoOVvDMfByX2e/VhBgKLcAvjxTCwBXT0n0QccGOchldleLqQ/Yr",
  b"NlT6doBQCk2bVoUZsNMDXx8cOVM37tQfaKJES7jIeDHno42l222mMyHJrYYqiivGzUp0Q3g4iE1jVgaBjUbP8g9wCs0yCGDjxOpO",
  b"pxD8052YW/eTa2JHzDQfmFyHwJuo1pDjhkxkCH8WOxs6r3xYV0WkRhGz736dQroyckUk3PQbBLlr0Ho0ebbw2O7Kka7biaxqGXNH",
  b"6o844QeU9/K7QIfokFuzNz8IhKnFhMT4rTUGKiVE2n01Z1Qew1vWOO+IZRQ/XGJb9lpy4SJGD3JJBwSMWwBoNO+ECU/mUJQdFglH",
  b"jVVWmHsmgpyqYp+SsBphb3XCmen31rTg01AJEGqtSahq7s822x7D6TvObE+rjn696wwEQJAUgNswq5CnEVfSGfykL+OWB//dlQx8",
  b"D1vORIapprbw2RP5gfM1QUmYI1j6drNLgUPUJ1zOzsK4FWg+hDsrzgMeiQ4uNrI5EAFehHDKpyRow2lZjUBqo6Ff5weGYoUUa9Et",
  b"Io5B+uk1Ydft+lR0OXelDn2dXLvruQ5mR4L/ogdOz8VWdstbLrrJjMbk5I9xmz6h7FYkggbWhLckjJYhDyCLZBUXu46B7h1Rjoqr",
  b"B3LXKZxW+yNT4YeFyRhUYoMzLR6XWOFZapjq+WZ0YFh1b3FmnSbk9QkZPlPxmpbihHGpg/QT7LtoLZ6oFoXQKNlMDXeLIdMoQe2q",
  b"sapubxP20lMNBO5aN0DUKQAwx4NhkRiV/EfFIhChWixcRkLRZe81Cg6MwITIX7BZRX4WMQS89+R4jLddlYQfloNLYwn1dzzg9FXm",
  b"7PTfvWIIhi/B1cZ1b0iGat3UoSaQiyndXm3DtMQCwgWHb3nzBwibvKFZU/GQcc/aA5q6xg7cy8KB1d5v9zoayzk=",
])

///|
test "hevc sei: mastering display, content light and user data" {
  let bytes = @libavutil.av_base64_decode(hevc_sei_b64, 100000).unwrap()
  let sei = ff_hevc_parse_sei(bytes, false, 0).unwrap()
  assert_eq(sei.messages.length(), 3)
  assert_eq(sei.messages[0].payload_type, 144)
  assert_eq(sei.messages[0].max_content_light, 1000)
  assert_eq(sei.messages[0].max_pic_average_light, 400)
  assert_eq(sei.messages[1].payload_type, 137)
  let md = sei.messages[1].mastering_display.unwrap()
  assert_eq(md.display_primaries.length(), 3)
  assert_eq(md.display_primaries[0], (13250, 34500))
  assert_eq(md.display_primaries[1], (7500, 3000))
  assert_eq(md.display_primaries[2], (34000, 16000))
  assert_eq(md.white_point, (15635, 16450))
  assert_eq(md.max_luminance, 10000000)
  assert_eq(md.min_luminance, 1)
  assert_eq(sei.messages[2].payload_type, 5)
  assert_eq(sei.messages[2].unregistered_uuid.unwrap().length(), 16)
  let payload = sei.messages[2].unregistered_payload.unwrap()
  assert_true(payload.length() > 4)
  assert_eq(payload[0], b'x')
  assert_eq(payload[1], b'2')
  assert_eq(payload[2], b'6')
  assert_eq(payload[3], b'5')
}
