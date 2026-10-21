///|
/// Real kvazaar stream with scaling lists enabled and FFmpeg 9.0.2 per-frame
/// MD5 references.
///
/// Generation (docker `linuxserver/ffmpeg:9.0.2`, cwd = this directory):
///
/// ```
/// docker run --rm -v "$PWD:/w" -w /w linuxserver/ffmpeg:9.0.2 -v error \
///   -f lavfi -i "testsrc2=duration=0.3:size=64x48:rate=10" -frames:v 3 \
///   -pix_fmt yuv420p -c:v libkvazaar \
///   -kvazaar-params "scaling-list=default" -f hevc -y kvsl.265
/// # filtered references:
/// docker run --rm -v "$PWD:/w" -w /w linuxserver/ffmpeg:9.0.2 \
///   -v error -i /w/kvsl.265 -f framemd5 -
/// # unfiltered (`-skip_loop_filter all`) references likewise.
/// ```
///
/// The resulting SPS sets `scaling_list_enabled_flag = 1` but does not signal
/// `sps_scaling_list_data_present_flag`, so the decoder must fall back to the
/// default scaling matrices (`set_default_scaling_list_data`). kvazaar also
/// enables WPP by default, so this stream is I/P/B with row entry points.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_scaling_b64 : Bytes = bcat([
  b"AAAAAUABDAL//wFgAAADAIAAAAMAAAMAugAABAIQJAAAAAFCAQIBYAAAAwCAAAADAAADALoAAKAggxbBAIZJOVYCAgAAAwACAAAD",
  b"ABQQAAAAAUQBwGJGCmSAAAABTgEFozL+RmyYQUJprjVqkVSe8/FLdmF6YWFyIEhFVkMgRW5jb2RlciB2LiAyLjMuMiAtIENvcHls",
  b"ZWZ0IDIwMTItMjAxNSAtIGh0dHA6Ly91bHRyYXZpZGVvLmNzLnR1dC5maS8gLSBvcHRpb25zOiA2NHg0OCBkZWJsb2NrPTE6MDow",
  b"IHNhbz0zIGludHJhX3BlcmlvZD02NCBxcD0yMiByZWY9NACAAAABJgGvPnwYTfvRovOuHljk+TfEb4kMMojsBJuoqUy3uJnCKCs0",
  b"Paf/8r1c+Pl9TVjhOAeas+557mBRiBJEBhK0FYDmPY4q12jtroqn7ht56cMRBbYR82aXKSwxc5dn2cFv27V+CcdCFSSCtIeh642m",
  b"GYq7uvv968eNyB5lW4hjSaYP/orIkcGJ7g+B7h1szTmI/Eiip2rRdDNgVgAPPY0MG3J7K1OJzBWdYQjskYM5wMp+h8f5Mxg8OA+a",
  b"qow24/cu03I3N6NobGWhQBpGe82WkYpLXlwJDPjSdB32SIiZfetijQQlPKIUb2mH8pAXiFyu6DlGQ4oGyZ5qDo2qlOmzKnaaNU+B",
  b"HU/XIqCYtKUrF3DXanjR6MTR8sf1gTQccagNRqApyaRkLJYDQAnOV4Zl1p7AV1IFVttO3w4zCqE63VS0nM6DiQm7o02LCjGYR+/O",
  b"KUlOzgLhTjIA2jRG8WD3aAnyTTyUu40BCAkiwI0UsUai7KEEBPph0yDLE6mInfQN76Uk6F3CNsiQOSxsQOROlr7s4bdv542cwsGi",
  b"VuaWxYyKEJtjGcqwJtoN/ombuwz+M5Pn9r/TgO9UTMFUGBZlfTxHCVF+gHmjQsml7F8XmlOCLvKY27yAa4wKkCLXQng4FhpSOpH7",
  b"JxBTnKQcCGuXwo3ol9os95EbUpmV0QaZrZC+0cJGkM41IZ9A+qm2qC5miMPH7GP8Y7FB23f+uFXBGGlNoDs0pbp0Qk6z2b8Z14Xr",
  b"Y4S/muW25M4AOB82tIUtOGrA//E8hwVGWNJCkUDOtUlD06LGakMK2UWAgmWMkLYq6w5XvuKUrOpUHpySsb+6VgHkSpz6abxEou6S",
  b"LgKev9inTtJaoAzRLOkQiXseJ+aKlEOGwCsjuPwbXWenX1gZmHMTpaqxXDKFDeszatnG//f7M7OhcVZhjxXScLBEScvOIzzYEBu/",
  b"bEEZl1CmtAbgiqwzZc6nFRS8akQGPTuXbH4hoh23TvqltT8EDYGKjy7UUCTtwCDpAEAZuO+4cAUACAd4hCXd2uPoV3TK1InlJ04x",
  b"j3fZUa7YMeEmq3AMlWBcPU+mU0FKZa6+hUTcskvLqYPbiyFIeVM+5yYCMwabk2cVPU9XmIsRkjWcvHUklutb5GRaL6IHbFyyvKDN",
  b"qbCk+ak7QHd6Z3BdAmg8M0n+SFGWzm4NQzL+1oYN/yumzsXcTC2brtDNnpx+SBhI4qVvy4eS8DPJMl9M1l7eli6IN3wBei1EJPhh",
  b"Cqm2b/HMfub3ty1oSI8vqMj4OIMIe1xZupI6AZ+mxQf8nuJvlr40cvmLe8CXM+KGCG0sOIjyfSXIzlscpa8qoM+l8KOlDMHnhXMb",
  b"LVuJ8NW4F/JeG8cgqo0zPlIDyci98QhkNDmRbj7PjUuR/VH07yWcVWHW+e1EYKvdxaPQY7WszWzmhoUmZpK5CssPTZULiwJ6gr8S",
  b"3dJKGE0eSIQ4fkB8AAABUAGEDQIAA4CcAAFp2gABlwKAAAAAAQIB0EVfxWD927qD9p///0OHv3jyoflKj9B/SYf0ofGDwbe93aT9",
  b"E6s+dIOyFaS8AAABUAGEDQIAA4DwAAFnCQABmRaAAAAAAQIB4JL/2Ozu9+15BuRma4TC10g8jvHop/uzCAKa1c3zIcynCwAAAVAB",
  b"hA0CAAOBXQABaJcAAZfegA==",
])

