///|
/// Real FFmpeg 9.0.2 Matroska (Opus audio) carrying a three-chapter
/// `Chapters`/`EditionEntry`/`ChapterAtom` tree.

///|
fn mkvchap_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mkvchap_b64 : Bytes = mkvchap_concat([
  b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAARYhFNm3TPv4RqbFWrTbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB+027jFOrhBBDp3BTrIIOUk27jFOrhBJUw2dTrIIOzE27jFOrhBxTu2tTrIIR",
  b"RuwBAAAAAAAARAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZtW/hEaY30wq17GDD0JAe6mJQ2hhcHRlcmVkTYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEu",
  b"MTAyc6SQa6wKLxlIJKRXWm0qoPUuvUSJiEBewAAAAAAAFlSua01Rv4SGXjfnrgEAAAAAAA1C14EBc8WIRSZteAYus7ucgQAitZyDdW5kiIEAhohBX1ZPUkJJU1aqgyxJ3oOBAiPjg4MWJO/hkZ+BAbWIQOWIgAAAAABiZIEgVe6BAGOiTPIC",
  b"HlwBdm9yYmlzAAAAAAFErAAAAAAAAIA4AQAAAAAAuAEDdm9yYmlzNAAAAFhpcGguT3JnIGxpYlZvcmJpcyBJIDIwMjAwNzA0IChSZWR1Y2luZyBFbnZpcm9ubWVudCkBAAAAFAAAAGVuY29kZXI9TGF2YzYzLjEuMTAyAQV2b3JiaXMiQkNW",
  b"AQBAAAAkcxgqRqVzFoQQGkJQGeMcQs5r7BlCTBGCHDJMW8slc5AhpKBCiFsogdCQVQAAQAAAh0F4FISKQQghhCU9WJKDJz0IIYSIOXgUhGlBCCGEEEIIIYQQQgghhEU5aJKDJ0EIHYTjMDgMg+U4+ByERTlYEIMnQegghA9CuJqDrDkIIYQk",
  b"NUhQgwY56ByEwiwoioLEMLgWhAQ1KIyC5DDI1IMLQoiag0k1+BqEZ0F4FoRpQQghhCRBSJCDBkHIGIRGQViSgwY5uBSEy0GoGoQqOQgfhCA0ZBUAkAAAoKIoiqIoChAasgoAyAAAEEBRFMdxHMmRHMmxHAsIDVkFAAABAAgAAKBIiqRIjuRI",
  b"kiRZkiVZkiVZkuaJqizLsizLsizLMhAasgoASAAAUFEMRXEUBwgNWQUAZAAACKA4iqVYiqVoiueIjgiEhqwCAIAAAAQAABA0Q1M8R5REz1RV17Zt27Zt27Zt27Zt27ZtW5ZlGQgNWQUAQAAAENJpZqkGiDADGQZCQ1YBAAgAAIARijDEgNCQ",
  b"VQAAQAAAgBhKDqIJrTnfnOOgWQ6aSrE5HZxItXmSm4q5Oeecc87J5pwxzjnnnKKcWQyaCa0555zEoFkKmgmtOeecJ7F50JoqrTnnnHHO6WCcEcY555wmrXmQmo21OeecBa1pjppLsTnnnEi5eVKbS7U555xzzjnnnHPOOeec6sXpHJwTzjnn",
  b"nKi9uZab0MU555xPxunenBDOOeecc84555xzzjnnnCA0ZBUAAAQAQBCGjWHcKQjS52ggRhFiGjLpQffoMAkag5xC6tHoaKSUOggllXFSSicIDVkFAAACAEAIIYUUUkghhRRSSCGFFGKIIYYYcsopp6CCSiqpqKKMMssss8wyyyyzzDrsrLMO",
  b"OwwxxBBDK63EUlNtNdZYa+4555qDtFZaa621UkoppZRSCkJDVgEAIAAABEIGGWSQUUghhRRiiCmnnHIKKqiA0JBVAAAgAIAAAAAAT/Ic0REd0REd0REd0REd0fEczxElURIlURIt0zI101NFVXVl15Z1Wbd9W9iFXfd93fd93fh1YViWZVmW",
  b"ZVmWZVmWZVmWZVmWIDRkFQAAAgAAIIQQQkghhRRSSCnGGHPMOegklBAIDVkFAAACAAgAAABwFEdxHMmRHEmyJEvSJM3SLE/zNE8TPVEURdM0VdEVXVE3bVE2ZdM1XVM2XVVWbVeWbVu2dduXZdv3fd/3fd/3fd/3fd/3fV0HQkNWAQASAAA6",
  b"kiMpkiIpkuM4jiRJQGjIKgBABgBAAACK4iiO4ziSJEmSJWmSZ3mWqJma6ZmeKqpAaMgqAAAQAEAAAAAAAACKpniKqXiKqHiO6IiSaJmWqKmaK8qm7Lqu67qu67qu67qu67qu67qu67qu67qu67qu67qu67qu67quC4SGrAIAJAAAdCRHciRH",
  b"UiRFUiRHcoDQkFUAgAwAgAAAHMMxJEVyLMvSNE/zNE8TPdETPdNTRVd0gdCQVQAAIACAAAAAAAAADMmwFMvRHE0SJdVSLVVTLdVSRdVTVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTdM0TRMIDVkJAAABANBac8ytl45B6KyX",
  b"yCikoNdOOeak18wogpznEDFjmMdSMUMMxpZBhJQFQkNWBABRAACAMcgxxBxyzknqJEXOOSodpcY5R6mj1FFKsaZaO0qltlRr45yj1FHKKKVaS6sdpVRrqrEAAIAABwCAAAuh0JAVAUAUAACBDFIKKYWUYs4p55BSyjnmHGKKOaecY845KJ2U",
  b"yjknnZMSKaWcY84p55yUzknmnJPSSSgAACDAAQAgwEIoNGRFABAnAOBwHE2TNE0UJU0TRU8UXdcTRdWVNM00NVFUVU0UTdVUVVkWTVWWJU0zTU0UVVMTRVUVVVOWTVW1Zc80bdlUVd0WVdW2ZVv2fVeWdd0zTdkWVdW2TVW1dVeWdV22bd2X",
  b"NM00NVFUVU0UVddUVds2VdW2NVF0XVFVZVlUVVl2XVnXVVfWfU0UVdVTTdkVVVWWVdnVZVWWdV90Vd1WXdnXVVnWfdvWhV/WfcKoqrpuyq6uq7Ks+7Iu+7rt65RJ00xTE0VV1URRVU1XtW1TdW1bE0XXFVXVlkVTdWVVln1fdWXZ10TRdUVV",
  b"lWVRVWVZlWVdd2VXt0VV1W1Vdn3fdF1dl3VdWGZb94XTdXVdlWXfV2VZ92Vdx9Z13/dM07ZN19V101V139Z15Zlt2/hFVdV1VZaFX5Vl39eF4Xlu3ReeUVV13ZRdX1dlWRduXzfavm48r21j2z6yryMMR76wLF3bNrq+TZh13egbQ+E3hjTT",
  b"tG3TVXXddF1fl3XdaOu6UFRVXVdl2fdVV/Z9W/eF4fZ93xhV1/dVWRaG1ZadYfd9pe4LlVW2hd/WdeeYbV1YfuPo/L4ydHVbaOu6scy+rjy7cXSGPgIAAAYcAAACTCgDhYasCADiBAAYhJxDTEGIFIMQQkgphJBSxBiEzDkpGXNSQimphVJS",
  b"ixiDkDkmJXNOSiihpVBKS6GE1kIpsYVSWmyt1ZpaizWE0loopbVQSouppRpbazVGjEHInJOSOSellNJaKKW1zDkqnYOUOggppZRaLCnFWDknJYOOSgchpZJKTCWlGEMqsZWUYiwpxdhabLnFmHMopcWSSmwlpVhbTDm2GHOOGIOQOSclc05K",
  b"KKW1UlJrlXNSOggpZQ5KKinFWEpKMXNOSgchpQ5CSiWlGFNKsYVSYisp1VhKarHFmHNLMdZQUoslpRhLSjG2GHNuseXWQWgtpBJjKCXGFmOurbUaQymxlZRiLCnVFmOtvcWYcyglxpJKjSWlWFuNucYYc06x5ZparLnF2GttufWac9CptVpT",
  b"TLm2GHOOuQVZc+69g9BaKKXFUEqMrbVaW4w5h1JiKynVWEqKtcWYc2ux9lBKjCWlWEtKNbYYa4419ppaq7XFmGtqseaac+8x5thTazW3GGtOseVac+695tZjAQAAAw4AAAEmlIFCQ1YCAFEAAAQhSjEGoUGIMeekNAgx5pyUijHnIKRSMeYc",
  b"hFIy5yCUklLmHIRSUgqlpJJSa6GUUlJqrQAAgAIHAIAAGzQlFgcoNGQlAJAKAGBwHMvyPFE0Vdl2LMnzRNE0VdW2HcvyPFE0TVW1bcvzRNE0VdV1dd3yPFE0VVV1XV33RFE1VdV1ZVn3PVE0VVV1XVn2fdNUVdV1ZVm2hV80VVd1XVmWZd9Y",
  b"XdV1ZVm2dVsYVtV1XVmWbVs3hlvXdd33hWE5Ordu67rv+8LxO8cAAPAEBwCgAhtWRzgpGgssNGQlAJABAEAYg5BBSCGDEFJIIaUQUkoJAAAYcAAACDChDBQashIAiAIAAAiRUkopjZRSSimlkVJKKaWUEkIIIYQQQgghhBBCCCGEEEIIIYQQ",
  b"QgghhBBCCCGEEEIIBQD4TzgA+D/YoCmxOEChISsBgHAAAMAYpZhyDDoJKTWMOQahlJRSaq1hjDEIpaTUWkuVcxBKSam12GKsnINQUkqtxRpjByGl1lqssdaaOwgppRZrrDnYHEppLcZYc86995BSazHWWnPvvZfWYqw159yDEMK0FGOuufbg",
  b"e+8ptlprzT34IIRQsdVac/BBCCGEizH33IPwPQghXIw55x6E8MEHYQAAd4MDAESCjTOsJJ0VjgYXGrISAAgJACAQYoox55yDEEIIkVKMOecchBBCKCVSijHnnIMOQgglZIw55xyEEEIopZSMMeecgxBCCaWUkjnnHIQQQiillFIy56CDEEIJ",
  b"pZRSSucchBBCCKWUUkrpoIMQQgmllFJKKSGEEEIJpZRSSiklhBBCCaWUUkoppYQQSiillFJKKaWUEEIppZRSSimllBJCKKWUUkoppZSSQimllFJKKaWUUlIopZRSSimllFJKCaWUUkoppZSUUkkFAAAcOAAABBhBJxlVFmGjCRcegEJDVgIA",
  b"QAAAFMRWU4mdQcwxZ6khCDGoqUJKKYYxQ8ogpilTCiGFIXOKIQKhxVZLxQAAABAEAAgICQAwQFAwAwAMDhA+B0EnQHC0AQAIQmSGSDQsBIcHlQARMRUAJCYo5AJAhcVF2sUFdBnggi7uOhBCEIIQxOIACkjAwQk3PPGGJ9zgBJ2iUgcBAAAA",
  b"AHAAAA8AAMcFEBHRHEaGxgZHh8cHSEgAAAAAAMgAwAcAwCECREQ0h5GhscHR4fEBEhIAAAAAAAAAAAAEBAQAAAAAAAIAAAAEBBBDp3D1v4QNzDJBRbkBAAAAAAAAZUXbgQG2nHPEgQGRgQCShAJiWgCAjYWFSW50cm9DfIN1bmS2oHPEgQKR",
  b"hAJiWgCShATEtACAjoWGTWlkZGxlQ3yDdW5ktp9zxIEDkYQExLQAkoQHJw4AgI2FhU91dHJvQ3yDdW5kElTDZ0CDv4TAhVnqc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz2GPAi2PFiEUmbXgGLrO7Z8ijRaOHRU5DT0RF",
  b"UkSHlkxhdmM2My4xLjEwMiBsaWJ2b3JiaXNnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjEyMzAwMDAwMAAfQ7Z1Qeu/hKv8h0bngQCgqKGjgQAAAFzdqzqrurD/WgIEEADAjNottjfffPPNMAzDMAzDegCbgQOgxaHAgQADAJrYPQdv0p5H",
  b"XAVmIkAqAAAAAAAAAAAAAAD6/WCfzgHRtRdc8J+jDnv80gwX7NGtW7c/fMubb548blQAAJuBDaCwoauBABAA3ti9WFcp84gwMU78rWA6AAAAAGAAAAAAAAAAvs4GAACDh+d5AQATm4EXoK6hqYEAJwDe2L2oVyn9FmXAzv0NTAcAAAAAAAAA",
  b"AAAAADBnEQCABDNdSV0Am4EXoK6hqYEAPwDe2L2oVyn9iDIwdu5XMB0AAAAAAAAAAAAAAMCPbwAAYPKF8hgAm4EXoL2huIEAVgC+2N1mr5LOER83xgFICQAAABAMAAAAAAAAgGYJcZw9f56RWtL3zbWQwDQr7l4JgA5HQEsAm4EXoECdoUCQ",
  b"gQBtAH43PTa4W8CpHNjANkbaeY6b22MMYkYxgyEYAAB7tFXXPux71V6+f/y/h3R48y0nfX77dCsPxy775mwXtSDybzVLy/vDWU5+ViPV5LdbLKvxqqZSl8E/YV9k67LFSDW5/piX9SNhXt4fzlLy/mDZfBJY5t1pyXyIJfPvCCjZzMm8Bxh1",
  b"q+EBTs8PgAYAm4EOdaKEAIvJJhxTu2uXv4QC6nN7u4+zgQC3iveBAfGCD1XwgQk=",
])

///|
test "mkv chapters: reads ffmpeg ChapterAtoms" {
  let data = @libavutil.av_base64_decode(mkvchap_b64, 100000).unwrap()
  let mh = @libavformat.av_matroska_open(data).unwrap()
  assert_eq(mh.chapters.length(), 3)
  assert_eq(mh.chapters[0].title, "Intro")
  assert_eq(mh.chapters[0].start_ns, 0L)
  assert_eq(mh.chapters[0].end_ns, Some(40000000L))
  assert_eq(mh.chapters[1].title, "Middle")
  assert_eq(mh.chapters[1].start_ns, 40000000L)
  assert_eq(mh.chapters[1].end_ns, Some(80000000L))
  assert_eq(mh.chapters[2].title, "Outro")
  assert_eq(mh.chapters[2].start_ns, 80000000L)
  assert_eq(mh.chapters[2].end_ns, Some(120000000L))
}

///|
test "mkv chapters: writer replaces ChapterAtoms" {
  let data = @libavutil.av_base64_decode(mkvchap_b64, 100000).unwrap()
  let plain = @libavformat.av_matroska_open(data).unwrap()
  let out = @libavformat.mkv_add_chapters(data, [
    @libavformat.mkv_chapter_new(120000000L, Some(200000000L), "Bonus"),
    @libavformat.mkv_chapter_new(200000000L, None, "End"),
  ]).unwrap()
  let mh = @libavformat.av_matroska_open(out).unwrap()
  assert_eq(mh.packets.length(), plain.packets.length())
  // The existing Chapters element is replaced (FFmpeg warns about duplicate
  // Chapters elements, so editions are not appended).
  assert_eq(mh.chapters.length(), 2)
  assert_eq(mh.chapters[0].title, "Bonus")
  assert_eq(mh.chapters[0].start_ns, 120000000L)
  assert_eq(mh.chapters[0].end_ns, Some(200000000L))
  assert_eq(mh.chapters[1].title, "End")
  assert_eq(mh.chapters[1].end_ns, None)
  assert_eq(mh.title.unwrap(), "Chaptered")
}

///|
test "mkv chapters: writer rejects non-Matroska input" {
  let ch : Array[@libavformat.MkvChapter] = [
    @libavformat.mkv_chapter_new(0L, None, "x"),
  ]
  match @libavformat.mkv_add_chapters(b"not an ebml file at all", ch) {
    Ok(_) => fail("expected a non-EBML file to be rejected")
    Err(_) => ()
  }
}

///|
test "mkv chapters: writer inserts when none exist" {
  let data = @libavutil.av_base64_decode(mkvmeta_b64, 100000).unwrap()
  let plain = @libavformat.av_matroska_open(data).unwrap()
  assert_eq(plain.chapters.length(), 0)
  let out = @libavformat.mkv_add_chapters(data, [
    @libavformat.mkv_chapter_new(0L, Some(50000000L), "One"),
  ]).unwrap()
  let mh = @libavformat.av_matroska_open(out).unwrap()
  assert_eq(mh.chapters.length(), 1)
  assert_eq(mh.chapters[0].title, "One")
  assert_eq(mh.chapters[0].start_ns, 0L)
  assert_eq(mh.chapters[0].end_ns, Some(50000000L))
  assert_eq(mh.packets.length(), plain.packets.length())
  // Tags from the source are untouched by the chapter insertion.
  assert_eq(mh.metadata.length(), plain.metadata.length())
}
