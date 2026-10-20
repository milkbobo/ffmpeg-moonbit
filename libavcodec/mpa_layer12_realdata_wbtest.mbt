///|
/// Real MPEG-1/2 Layer II streams plus hand-built Layer I frames, with the
/// expected PCM MD5s taken from FFmpeg's **fixed** MPEG audio decoder.
///
/// Layer II generator (docker `linuxserver/ffmpeg:9.0.2`, FFmpeg's native `mp2`
/// encoder):
///
///   ffmpeg -f lavfi -i \
///     "aevalsrc=0.40*sin(2*PI*440*t)|0.30*sin(2*PI*660*t):s=44100:d=0.15" \
///     -ac 2 -c:a mp2 -b:a 192k -f mp2 st44_192.mp2
///   ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.15" \
///     -ac 1 -c:a mp2 -b:a 64k -f mp2 mono44_64.mp2
///   ffmpeg -f lavfi -i \
///     "aevalsrc=0.40*sin(2*PI*440*t)|0.30*sin(2*PI*660*t):s=32000:d=0.2" \
///     -ac 2 -c:a mp2 -b:a 64k -f mp2 js32_64.mp2
///   ffmpeg -f lavfi -i \
///     "aevalsrc=0.40*sin(2*PI*440*t)|0.30*sin(2*PI*660*t):s=24000:d=0.2" \
///     -ac 2 -c:a mp2 -b:a 64k -f mp2 lsf24_64.mp2
///
/// They cover all four usable Layer II allocation tables: 1 (stereo 192k),
/// 0 (mono 64k), 3 (joint stereo 32k) and 4 (MPEG-2 LSF), and the joint-stereo
/// `bound` region plus both grouped (3/5/9-step) and linear quantisers.
///
/// **Layer I has no encoder in FFmpeg**, so those two frames are built by hand in
/// the test generator (4-bit allocations, 6-bit scalefactors, `n+1`-bit
/// mantissas, three frames per stream so the mp2 demuxer probes them). The
/// expected PCM still comes from FFmpeg decoding them:
///
///   ffmpeg -c:a mp2 -i l1_mono_32k.mp1 -f s16le l1_mono_32k.pcm
///
/// `-c:a mp2` selects the fixed decoder on both sides; `mp2float` would produce
/// different samples, so these vectors pin the integer path.

///|
/// Layer II stereo 44.1 kHz 192 kbit/s: 3761 bytes, 6 frames of 1152 samples, 44100 Hz, 2 ch.
let mp2_stereo_44_192_b64 : Bytes = b"//2gBGZEQ0QzVUQzMzNDjbbkbJAAAAAAAAAACvDMw///////GJPaPKXq2Wp2YsXt" +
  b"wcvctxbzbz2gz2fyerdthshtg1f1kyj0ixhzlylyj1j2lzl1lsktltlufv379+/e" +
  b"973ve97u62LY2227u7uti2NttttttttrY21sbbbbbbba2LY2221r9++fv3z3Se+D" +
  b"3Qd3RtG2223eHeFjWxtttttttttY22tjbbbbbbbWxbG222tfNuDqDvN1abbR3qdy" +
  b"lKTSMQ2u3PWtbMNh1jMPN500FmYYmw2EymTzxwhUIhEIlnHeQc2vFpMowmHWxbG2" +
  b"03d4d11XVtttttNtttdW2tjbbbbbbbWxbG2m2tljbv0F720j4M9GHQ71s4IRE/W/" +
  b"SYqOwTCrEUlMxLho4FqqZCKUWZ7qmy4XCFgZRC9Ru4Coi7nvd3aM0VlFHipiDKfy" +
  b"CChZU1hJlddLJxjKKKrttP8tmWWYXxD4mszfzMJdDe97u6prIa3HTzEuX4/0OmHI" +
  b"xIKBsQrIFriSSNldrPIPCmVCGsq3T0G1ri4Lr3vd3VxazW25eoqEQj2lKMZxOJFl" +
  b"0bM/sqLKSyteP1BWCmc34HlUCOvnkYeiOmcpiFo2ZGpTzT8Pwb4ptCxpsplsO821" +
  b"lpZRWkmxfheyUlm3JSerIMj9l4PS0vOhMN/TIobab6y0fXIwwSqKIJpxrIrsdCiR" +
  b"zW1P5E4Si8x4NipPgKXw5boaufBhhhuZarUR16XyRVA0CamsqEuMpFmeRKRWrkiA" +
  b"A5ECja+uIP8A/iOqoyOQzLjMx7C6cbd4mUPRus4UOmlIFlfnGs+VCSR1UmbQtogg" +
  b"8wD//aIEZkREVDNVRDMzM0SRuSyQkgAAAAAAAAAKqqqqqqqqqq6GJaK2ztwwy120" +
  b"yrtsu1101yzzzz1z0stsutzx0RgH4ELxz2zaB+BTuCJAq4a6rqpD2rsIwK2GjTKh" +
  b"eYTgTUhkNgXQlWK0JwlteFi6N8Ct49SVYzwRNE0yL7E4U3cbmrCF8gopOGCiJldJ" +
  b"+b7/koJMExMOqDBOqNoQmZiJTGhFiuSbi18VOmyNBHU3qnMZD39lJiR1MbJZh+uz" +
  b"gTUlMt2Z0ljB0eC+teD7aZqsYoa4FwMTzXKT2ayM1R3cZ3IgQ7pabFcRRhcLL6nC" +
  b"8EIpRDEEKKMkCV1s2Y8UcFrRFHXQ8rMqopWzWKCuK7hKpaXsVTcYraMIhg+ETnX1" +
  b"AotkXPZzfI0S3u2CXivTYDA3cFskVvmqaYhE0ymz07eHoaCyUMEipRisCzkT62ow" +
  b"lRVFgOJbmiN1LaNbnmwb2MruD1e0qLnPFeyhjCNq+xCVaNdNoZpDSqg+JE2k9JFG" +
  b"IXRJSVBIlIvDJLRJC+wSD8VJ1ZlsW525IUvDPe3XFujJrFNLxxbadQQMdqbMJBL6" +
  b"7TOp/owErr2HXq30F6YTborWsZaIKpj7FHCdvds90YEmGxQwMkTbVgHOmBlBFxl4" +
  b"d0gxaUJdCwynhD8yDxZqfD4joeI1RD4nGtWXkrGzIlNORpoTTbf16x7wNFBQxOqq" +
  b"60tiOzr2HRtWg5bmGxdDe8qYsGLVzImJpzqoXgmEsUyBhLrUXhkIngBMlGIYzYnW" +
  b"pu0AdDRRxvVy3dgz4Hq2npFRNiNZiN5fTqGC9pWTegiaMEKT1nN0LtBIwbMKqpSN" +
  b"SZCG2AD//aIEZkREVDNVRDNDM0SRuSSQkgAAAAAAAAAKqKqqquqqqqqGJaK2z2zu" +
  b"wwy011ystsu121z0yzyzz1z0stttzOq+TuWryKAeCndMT1JNMmwNWZuI0VA3CyaD" +
  b"RuF1iLun9bxAkWlNK7IKPzZIQ52lCDjbOaNkZsmVzamYzPX9sBpmdrKRFrUdDQ8V" +
  b"KLMSPMTV0HlAoQfEBkN80CoRhdoW2EOYfh0muk8S1TZC0iJTTpisqzJMhDGgRKag" +
  b"62jiS1c6BZIMDMSsA2NCZMbuhEMnoF96o02wK3KsgYbkZ0nC6yc5ETBY1GJM0IMt" +
  b"pc6FPzEWURLFmoyDzQqRCDp420C9heNHBlB3TkF4Cg2eOGuOi7B9UYKcTtozLaSc" +
  b"QzISfKFAt9XbZIeqBjwu62Nm9huzURJuZcZhuugl9VkabesjERNGiU1PTS02kuzr" +
  b"0/LRRDLjwyq5knwqEIXykYBjAmxQOh8Oeaz+sINA1VW3ubYgn0oZiYXGtJMJ9T9P" +
  b"uekiSikItELiFDdC7tpdnRawa4ELoSrekr8FlkNiaxox7G4NsFG3VUdKhaXL8+zk" +
  b"BJEryv6ooOXKs5bHihTRmFWWh9FxL5oqjSRtBY4ei16UOfXExSHG1kQQvswwS6CS" +
  b"JTkOmVyIDQg+YR5LTaHIUdwo9FSWsy2xCIkyU23nL5DzPyJhm6GyBCL6u6vOMW0E" +
  b"j0RFch5cjbm8d7onvFeFdRhFIhufKMUZGEpwqqu2RdCcxTpbNEZabeOiuFYFMkNv" +
  b"NB/qyECFWhDTIHBPgE/Fri9IX1BfXENy9RsiJ6FPWKsCiXMMYGXPcSIYlhTRTpTS" +
  b"N5bDiN1rwAD//aIEZkREVDNVRDNDM0SRuSyQkgAAAAAAAAAKqqqqqqqqqqqGJaK2" +
  b"0uwwy011yrtst10z0xzyz01z0stttzwVBnwH4Lt7ZqeN6JkyRfUrDHJir5T0ZkGF" +
  b"qU0phJOc6JiTEiyikqcKKKyPKE2hCpgHCuBQeZ2PmKz4VCqEhyrTctm2m7ZuUGmn" +
  b"Ka4U1V8DmsnyMJQew0rOVwUIxZ0ZGknkQVhXsTYqnu6jowWsZxqq4qOUgJXTDJDM" +
  b"TiZcvsgk8DEJIshFbUgFDwhFmwdbzbCNADTPA9a8LXpfRWtixOqmJlD3seKcjuNi" +
  b"Itwa4BvJMSiiksxwrimQJkTbBbyTNqCYUNh4Ka21TNNI0mLFZx9m1GDdYpl9G4WW" +
  b"FNLHmo46KZKXRkpoYJol/e+UPFnfM7CM5smXrGTBj1H1hipmZiuK9UjnDWbUTjSc" +
  b"Cr+yMvsJMxgurqiFGg1V4ZMbYA3qFMnp7KusOCTLXIel0aafbg/zIOZxZyCppJt6" +
  b"5CbJoykG7C7S6pIkA2OvYjlm+wX1JuSc+bTgsAbiPqUMJuNuz+MA2YVAxiW01A66" +
  b"sNMUJRMZO+bMo6MqQ6GRtuyC9B2k3FdXxHYmAuQ2peGjXu4PdqxIMC8pqVaLfzC6" +
  b"6bMIkvDOoqYyK+Err2Gz8nMhpiLCMFfM6rLCbaTEjFdi6tCQlDtNHRUlIyNukjnT" +
  b"UyUlCzwnCgS2Ctug4hC2HLaqga6HxbT2asIw0cjFGvJuywesvGIIoom3FLLfw+vr" +
  b"RRLizmrQ2bUGRFzSzXhMdPLikLoa1S9FSbUSsCjm8xqHghyq2w0UZFSjkuND6yoh" +
  b"JS/C6KpcNSW8W3D//aIEZkREVDNVRDNDM0SRuSSQkgAAAAAAAAAKqKqqqrqqqqqG" +
  b"JaK2z2zuwwx100yrtsu1z1z1yzyzz1zzstttzQKOUpZa0N/RbLU6opI9auwKppyr" +
  b"dE3sKzUDxxFQsODBEzOQ0SVK8SF8N79LEhtlZ3edzkeFWPJhzXZGELSIlFNmcnMB" +
  b"80UcaA7prNBa8uTW6XJApQvCC1jw0BkRvdwU1chHnqEXTNsanqBSyPZSaVeam0kV" +
  b"pm0URBgRE0lDjy7UBaSLfzy2CkNCrUYOjD8IP6C6srIQLV9jUcbIh00227KowFig" +
  b"gwOTDMpJrtEcvpGUWVB9iNUDp7GRC7qYyt7C9uOGyiUtqDZYCn2eIpq8uZRoJ4Jj" +
  b"TtFKJaKXOxWLblEJNu8aIlMo6swhe8OlDNpfUhXNk651Tugk2VlTLi4yjJaOBmlP" +
  b"abATE6U2NqnwaQUJUMfyxoADcLx0EnmBLSvUI9iGF423wXa05qK3jJxGh/pcTY0x" +
  b"QpRsgw9LTEoQkts0qiYCAIRCEdxpe0hRKYF0PXrqWY9FG8NkaiMabIF9aUm3VijK" +
  b"VDssC10MBEots5DVNqWBbZjHikRsaiKOyC4Mqa0TPTRIxJFOa7i1yIjEuGbWoyYE" +
  b"xDDP+l4SJaOsArSNDQjObx4sTOMrvbw2i4eGaal1CfQSqm7i9xGlSyNNmQ0xAwsO" +
  b"v6zwiUySajxtmf40NDmEdr4iL7hFdSiqyhrUF9YSQMtN6FusWkyKyaJcpzYocPt8" +
  b"irHpxlI46Ssl+EAS5vrNLG/APw3GRe5I6monXCPS8cLtpm2yRuwUWpBg6U1DDDpP" +
  b"UCKBK6rcXC1DirdoaAD//aIEZkRDRDNVRDMzM0NttuRskAAAAAAAAAAKZFUFRQQB" +
  b"VVUYlpIrZbbRW5jFfBrJrbR7bR3V/J6t6616x+5/XSLbSHaPXSLPKLXOHTOPSLSX" +
  b"WTOXOWyW2S2S2S7YGA/Akm4SVaKW8dh4JBWwt819KvvnKBgTqNEEjadm0UgJQakl" +
  b"lHEt0yGbXo4x/EnlFmh8ki97cAeR6jRTM1lc04XSjGo4UqGK2Y8rBXgICbXLDCVl" +
  b"MsK2Ymsqgrrw2vsXMrBCAIiRI2Kdsd1Pg+jpMTOijhLFdZ3QnQhMp6RxEVfLCRvZ" +
  b"twPR37cU8h6HL1wdEmiLNTndVTx/Ba8W0xU2mKtXDctMrRRDtlzCAXlEkruVclU9" +
  b"PeG/fBbmkayZ2QLBDDExEyrTSqqGQVxFosV3nJS3QUiHZJTJRotIu8D3BsZ1jir4" +
  b"TJ6pXZsnocQSi10Z0n8aBrNNDppiidUtyZSlBFp2Swb0QMRZvcrridQ3s6O2VJ7w" +
  b"BhsJR9LNFZE5isq2a6NSzQGjBVccVUmZQIdbjG8Zi0y7wH46IL6CUXjXxus+HjqB" +
  b"/SsNO5W2UqEmwUYrDCJuQk5FmqUCgnXHURGQtFl1xli76DdHtiuqHve7uti2Nttu" +
  b"7u7rYtjbbbbbbbba2NttttttttttbFsbbba0bLzD9Jt7YYLp73u7rYtjbbbu7u62" +
  b"LY222222222tjbbbbbbbbbbWxbG222tIvt1xXKi149je1jsy2LY2227Q7Quq6ttt" +
  b"ttttttrG222222222211XVtttrT655KNwuURtUAFmBSpSlQKBAdgdHScCzWa0Wmq" +
  b"1T3gyBwOBQIGgw4DgOazhAA="

///|
/// Layer II mono 44.1 kHz 64 kbit/s: 1253 bytes, 6 frames of 1152 samples, 44100 Hz, 1 ch.
let mp2_mono_44_64_b64 : Bytes = b"//1AxEMiExEREkogAAAAs//8/zFH3L+HcYc4NZdo758Jdadp9s6s6NK86bnve7u2" +
  b"3zW21rWta1r5r3vdobb5rba1rWta1817PHynZqJZ1UWElIhkTAO5Z42+a22ta1rW" +
  b"tfNmDGsWbnGti1HZG42vVXBTXFttTx0ioMvALXIdAjkg22sLYRcGxmpzcPBMqxbb" +
  b"p8kYJ5NXS1mTxUzgpNC/WJW9t7EyMT5BX0kohe7SCwTLhtoh8wS6YgEPjYy1DpyY" +
  b"GgcgBOWZpYW0Baky5MUCgP/9QsRDMxQhERJKIAAAAKoqqqox/jHbXLXa/DXXPLbO" +
  b"7VAFrGJyFkvgkSTaKYhyXwAch3hstisYebctI0+SewjdI9tiq3izzHlzchyP6MKu" +
  b"jdwTX9AeY8kVo+NfjDGWYuFU5GoTJlzYvRn8oW2ndwriIM9QXQVkOMnXEvVDKl1l" +
  b"n3rY2AMsxh3JD2xQxCss89bXQDFIAGbKWszCwsDuXiZpo8m2ArlxxHQSFsYLUqYw" +
  b"VFuwEeSN7zBwtihqlbfINPWCb6xkXgKlmsLUqS5Bl6AA//1CxEMzEyERIkogAAAA" +
  b"quqqqjH98stdNb8NdtM9dbip9guLkDkWNxIqbtiNZpQX2kznKFK3Us0Ni5DCYBg+" +
  b"6aPDM0rlFTO1XceTYYB1ymEkxD6Nwo6YlmWegoC+sKs0MJJEkzqx3HeunAJ5Agrw" +
  b"M7lRqeHtceXodhfdAytA3xxKp6obkxcK6NdWLDNKe7XC8DwOY08HxjxgqbQqEcRi" +
  b"eqTobmQfKI+kCxEbV1GWqsFx5QB84S8lwMKrJUZaqwtC0MTkgHqkcVGtkSFqTE4D" +
  b"a4T//ULEQzMTIREiSiAAAACqqqqqMf3xz11vv200z1zuzYBa7KMZU5XJKjhuGVmS" +
  b"2QDkurRlV0ZksS5FMHJJcEN1Bu4Z2tmSbrGh3Pkd4gTjq7hnZG55srtYsgNXjjGs" +
  b"SulUslnU+41jnwTeWTbKyaVyRo9b7EAwrEH15pywxqVFXD1puNJBAMO5oerZGxdi" +
  b"cPWqvAejwwYuxaLqZF3Y+xZOWVZSDBTUDlyAcXJEFSvfWTqEAMOyFExh1dbe1Ky7" +
  b"AeUiRs9YyFqTCzULUqoGA2UpAP/9QsRDMxMhERJKIAAAAKqqsoox/jLPTXDDXjbP" +
  b"bXPXjTO4qPYLmLJUtdFyQmGB3fJSX2ko6iMc5EsyK1Yl0iWi5xoj2y2y0PM7c2Hd" +
  b"AqIM8pIxsxtlSTO2FwZSJqC2uIO8EhJXqoNbcGkCsglkC0PBIWU+qAISJc0HYXXQ" +
  b"QOwOElFLfSFgXSg6RU4JokChZDy3ja4dkAfHNGk9XSa2x6LAtNDE+Tyxtp0w0Gtc" +
  b"ClqPOgQaB68KciHeQrdHxWNtcd3BNzAes4tmJVN4Wo9NVZyM//1CxEMiFBEREkog" +
  b"AAAAlVFVVTH1+G8Xc39Y9tJL5MJdZ9aM5859qtarqsXAWu1CU58AWpLNURuSmgDk" +
  b"olVOhEksDBWQSDhwQVZEI2nMZ5kzEOUoGeKM5FFU3HI+aXQDoUNHkC+sNdRMBsUy" +
  b"zRwFjL5hLqahWYAL1vbBUXBBcgacWns3jU9b25BpIMGqKWqK0tz2vExsQRSjBfDt" +
  b"DbfNWxrWta1rXzQT27Q23zVsa1rWta18wL+wztJ81Y2ta1rWtfNKp20gMaqfhD4I" +
  b"kpUljwA="

///|
/// Layer II joint stereo 32 kHz 64 kbit/s: 1728 bytes, 6 frames of 1152 samples, 32000 Hz, 2 ch.
let mp2_jstereo_32_64_b64 : Bytes = b"//1IBFUzbSIaJAJJJJugwz///HOXLIVozTo2WuVu0btwazZx1ezdygsg2f2ezizi" +
  b"zgzg1e973vWxbFsWx8+atj5rWta1rWte973RWxbFsWx8+atj5rWta1rWtc7hvSX2" +
  b"p7StNq1Ex8itSlhCUlKFws3Qk6nF2XZ8+atj5rWta1rWto9WSREinFwXA62ZGWE9" +
  b"GDed13XyL2BzV2pFsWzO+PEL5UjEeWFrwDpFx0papFsWxQ+c576cqCYS7YajM9hV" +
  b"JmrFsWxK+au9wdbUmSzW32HtRXRSWyQifQ8NDXoMjQMSFrRHhcx4peZETbCDVW6H" +
  b"edVxGWzYWbYkh5JmZH9cMg8m4119ZtWW1o56DkCaMuHCaajRBM41clTVIWEL3AAA" +
  b"//1IBFUzbSJaJIJJJJqqqpqqqodcsjPW/XDXXbPLCyzTbPPXPUtHvLuj4cRyIHkJ" +
  b"zXO7LYx1zFdCFlZE02zhdST1zII6HnXANhqWmK0I58HSz7IJ1CaYTQ8M6tOxGUNR" +
  b"QoQvFEZqRykGMNRcXsFxYzvLexzSCdZsD7ClPEqYyPTHKFKOeGQx5qWou+W66PB1" +
  b"7IpPEhXuepM6dOo30M1Im2vpbbGZukE8NJfaRQgoPxUfYjTLc3OSdAV2lyOul2GK" +
  b"C6Lg/215qNau7IQ4WhH5EE7FyHBsLeWB7hjLeuSoQvB6sjjiPybNs0KRA6ozxKNM" +
  b"6h0bDMReCOd27JymDcKDKXZOGw5qTKq8IX0iI6WEkS3DOR2Ke6vXxiLfVqoQdoAA" +
  b"//1IBFUzbSJaJIJJJJqqq6qqrodcsjPW/TDTXXXLCyzTbPPPbPWZ9irV9xMDhK8x" +
  b"E6qyiKPM7DKg1uQ9GK84EENpQ8KDKNir4o5qWFN0IOwto8SEkRGzHhMRYpeMRiOY" +
  b"2c4NvCxOjzBphEIkys4w1F3iOJQzWThC+gcKTT5NDxplzKJqMS+HMhqZDO+oQo9R" +
  b"dtEgPIFN5Kms2u1YyEtBc2uvDIvG2tXQ0JIes4c1LNiKJQ2XyhG+g6QfaqWDRpgr" +
  b"WjKWeH3MhqPZK8YOjM6OJJkLH9HoYNtNgogyks2crRbfYep4dFB9JAZ9CI1psgEL" +
  b"Q0DVhG2h4WvZqXHRE0dgiF2dq7Mr1tHK0IRbYjNlJkdH9R0gcnJz7Dynm1dbFjEA" +
  b"//1IBFUzbSJaJIJJJJqqqqqqpodcsjPa/TDTXPLCyzTbPPXPPXoOO0Qyy8JpJ9CA" +
  b"1ogiELQ1iMg27i0e/I6PLxHBUeIHKc66sTHMNVzoXVkUcDOFBJPQog6padYo1moy" +
  b"b7OjfwdTuMgkEJpA9Bs2a0fkXQxlMg6+URnSwqQUw1CzetHNjOutTHHIxzmxPsNa" +
  b"iSpTI9lAo1ox4bDFmo2jLubro8XmMimcSE+Z7QzZ0ujXQ0EvbG7VttiQ6QZw0mjp" +
  b"NSVg+7RViNM9183J0GYEXJ7aXLApNoaD3zVGo1r73hHhaaeUQXsXKBm1J7YHsGUt" +
  b"8ZPg27nqztpo/j0231pOTtjOwpUzuGZrc3F4O1nbuPKYkQozoxk67FGogprthoAA" +
  b"//1IBFUzbSJaJIJJJJqqqrqqqodcsjPW/TDXXbPLGyzXbPPXPXSI7UgSaNcNmXc1" +
  b"8K9xmmt7mmg11pn3xKX3owOFRzZjvrLiqczkMaF25D0fDrgSlWlfEpRpCKq6pmo4" +
  b"R3OhrC27MwSaUbOBU0xh147mm5lpmg697E7srmmpQiZWztzGXe46dDNYeCr3Bwui" +
  b"Pk2nGmRso4pBL7E5GocJL2haj1ZHESKcgVn0tGw677DkSxVnba+ci9gc1dqQkoMz" +
  b"vTQs2wqtDEeWFrwDpFx0papGmlRa3pF4X05GothL2hqMz2FUmasf1+hlWxGCuDqS" +
  b"y5ktZt9h7UV0UlskIf0PDEmy4StDQMSFrRHhcx4peZETV+DVWR2rs6vXEZbXhYAA" +
  b"//1IBFUzbRISJAJJJJigAAUAQHYXNKIzkV3hTvlW1kVwub2qa3pZywewdsg20g2u" +
  b"fztezyizizvg1vgbYkgcOKZH9cIgyeHG9k2rLa0c9ByAeo5DhNM9oea51Iw1SFhC" +
  b"9y0e4XpGhxHJ5ePdg9rY65iubCysiYPyVOpJ69EB0+YBspSYrNjnwdLPs03UWxbH" +
  b"zTPnzWGo1sGtaiM1I5I7GLYtj5rXz5T3Na11mtPsKU8SpjFsWx82j58x9GtbdrW9" +
  b"Hg68kUngTg/rtYYMMYyiEzq9luu9t6YOuDm9StI+fWsQjW2s1pYOE1qQLUeZ5wHR" +
  b"ePFKhBjFrc573vc9bFsWta3zWvnzWta1rWta973veti2LYtj5rXz5rWta1rWtAAA"

///|
/// Layer II MPEG-2 LSF stereo 24 kHz 64 kbit/s: 1920 bytes, 5 frames of 1152 samples, 24000 Hz, 2 ch.
let mp2_lsf_24_64_b64 : Bytes = b"//WEBGZDMyIlokAkklVWlAAAAAAAAAIowAPzz///zEKcRyE5+TklbtE6+GbdWa92" +
  b"cNmMM3cXL38n89ncnc4cdIMn9ns48os4dYNY8Ys4r4r3ve971sbbbbb581q2Pmta" +
  b"1rWta1rWtfPmte6L3RWxtttuPnzWrY+a1rWta1rWta18+a0/Jm9ap2Wtns1aiEx8" +
  b"itSlhCUlKQg8MkyUqn1CEEy2sbjT581q2Pmta1rWta1rWtfPmtJdt/PEJkZsFtmz" +
  b"GMfHKWbLPc67mARUYbIBlyNa5pg627s+fNau1hbJtYG0EWSOOpzwasog5zqO2jbh" +
  b"Dl81rfvpxe0yWuhlIXWpJQMobTmuXogNsKPnzWt7cMEjV6g27TAjZ4AAAtHlQcSl" +
  b"MiNoUNUDDUkzKUmF1stCq+hjgY05IhRle1TLQAx7Ns4PlumVlaOtZI7qdJQBwtpR" +
  b"Fo8AyszTmZiWtdmB9jRs1zmJg6aFCqxdFOpw3sIdXSDHtGkRliaECGr2GOOkb5IA" +
  b"//WEBGZEMyIltEkkklVWlAAAAAAAAAKqqqqqquoqqNxHI3Sz3z21zwww0x2yz02z" +
  b"1zyy1y01xzvvLOalIEkfIiQVDhwHShcgVl3EoyLruIRwyCBIy8EUREVU2SO4Y5s2" +
  b"JHSQpMG9WFvXLlJbpKzAPDVGMqj7XEWhai2JmNyJ2SNbEwGxbdg2umviK0HZ0Cgs" +
  b"F1CAtb06YzgV4ShTQJmDXOGmDnoFIUPsYqBIfiszZSGcRkLFHpYpx1lg2zQjdoge" +
  b"AkfSHQozI2DcQFuKMeFbEMR2tGqXRu1SblQPgDrA5iipAA0kDHQdrZriGcFpKsNq" +
  b"zWxYB0HJpQ+ByUp5Uma1bWagMyLIjrMWN+iBblrRgzl68AFbMqUomWLMjIeHnCnR" +
  b"vikWQa6iYOvEbIrHpQJFwyCiIMUkUXSCWjHZitMAxaJrBymQCB2EwZiZUIQxo/su" +
  b"I7RA5aGIXQnWIy2jAveMEqzF0+CPorqOinTXDRAnNzBZBHKLlwfYlctvEYGwcBwk" +
  b"//WEBGZEMyIltEkkklVWlAAAAAAAAAKqqqqqqqoqqNxHI2Sz3020zwww0y2yz0z0" +
  b"zy1y111xzvvcnYjFOookypqCA7V2itQCoy2XGDYNAmGVJkYA7Sg6A6taFaIgemly" +
  b"VwGZM2mJgdnLQgvEW9Gp1xKMV7ghLYBQpbNrKF2pCOsp+bttkIXVahxp6SgilpZp" +
  b"zHNpyN6oYiuklaTZIW1stADNqLNQ5G4dSkyoaEVluacd2F3UZtUkVgjF2Rqch6+G" +
  b"AWWKQUQgNbQLIPaJXWciARwoGdnEbZoYzFnxhXkIiGaaXFFdkCRpGJhlsw6Z5YG0" +
  b"IWSOOpzwauHgZR6OeWIwicbMOG12pRXZ7jJs6GUhdaklAypOoEZegCbYUepWshic" +
  b"FAbKI5eoNs0wI2eAAAHZ5UHEqwGltFBqgW/ZIhUzKUmF1rNCG+hjgY0bChRleTFp" +
  b"oAY9s2Fm9dOPCZWVo61kjup0lAHSmlEWjyicZmnMzEiqc5oFhfY0bNc5gIOmhQqA" +
  b"//WEBGZEMyIltEkkklVWlAAAAAAAAAKqqqqqqqoqqNxHI4Sz3z21zwww0x2yz0z1" +
  b"zyy1y01xzvvwLhTqcOzBFq6QYlnjdGDaaiaECGr2GN2kb5ICzmpSBJHyIEFQ4cB0" +
  b"oXIFZdxKMi27iEcMggSMvBFERFVNkjuGObNiR0kKTBvVhb1y5SW6SswDw1RjKo+1" +
  b"xFoWotiZjcidkjWxMBsG3YNrpr4itB2dAoLBdQgLW9OmM4FeEoU0CZg1zhgg56BS" +
  b"FD7GKgSH4zM2UhnEZCxR6WKcdZYNs0I3aIHgJH0h0KMyNg3EBbijHhWxDEdrRql0" +
  b"btUm5UD4A6wOYoqQANJAx0Ha2a4hnBaSrDas1sWAdByaUPgclKeVJmtW1moDMiyI" +
  b"6zFjfogW5a0as5evABWzKlKJlixIyHh5wp0b4pFkGuomDrxGyKx6UCRcMgoiDFJF" +
  b"F0glox2YrTAMWiawcpkAgdhMGYmVCEMaP7LiO0QOWhiF0J1iMtowL3jBKsxdPgjA" +
  b"//WEBGZDMyIhIkAkklVWlAAAAAAAAAAIgAAAAAAANK+YQ+HK+IfT+QdV+cT+kZ+i" +
  b"Z+hY+nd+mc+of+of+nd+nd+qh+ph+pf+pe+rj+ri+rh+qg+sj+si+wj+ui+6K73v" +
  b"p3QttEvnzXz5rWta1rWta1rXz4JHJ297zqATbUr5818+a1rWta1rWta18+GAO0vf" +
  b"AOps27E+fNfPmta1rWta1rWtfPgAdgLLhe6oGAk69iiBCEFBITObWCEhO3vNthfg" +
  b"CGaDcAYEePhq0KWtVKQiEJSmowwQhr3uc5a22m22+fNfPmta1rWta1rWtfPmte97" +
  b"3vWxttttvnzXz5rWta1rWta1rXz5rXve971sbbbbb5818+a1rWta1rWta18+a173" +
  b"ve9bG2222+fNfPmta1rWta1rWtfPmte973vWxttttvnzXz5rWta1rWta1rXz5rXv" +
  b"e971sbbbbb5818+a1rWta1rWta18+a173ve9bG2222+fNfPmta1rWta1rWtfPmtA"

///|
/// Layer I mono 32 kHz 192 kbit/s (hand-built): 864 bytes, 3 frames of 384 samples, 32000 Hz, 1 ch.
let mp1_mono_32_192_b64 : Bytes = b"//9oxEMhAAAAAAAAAAAAAAAAAAAAc1ULMJOz4ZXxaXIKucWtYc8zg7+hhPEAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"//9oxEMhAAAAAAAAAAAAAAAAAAAAc1VGrWFnGGLMpO74bXx6XAKscWNYU8wAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"//9oxEMhAAAAAAAAAAAAAAAAAAAAc1V6Gk8a1zGr2FvGELMJOz4ZXxaXIKsAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

///|
/// Layer I joint stereo 44.1 kHz 256 kbit/s (hand-built): 828 bytes, 3 frames of 384 samples, 44100 Hz, 2 ch.
let mp1_jstereo_44_256_b64 : Bytes = b"//+ARDI0IRIAAAAAAAAAAAAAAAAAABSyQ0U2WxCL9FrMJ+tdUgw56yhZH3Vo6Qev" +
  b"xJodG7kskZP0eo4n403SDj2LKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//+ARDI0IRIAAAAA" +
  b"AAAAAAAAAAAAABSyQ0U2W8f2SwQm/RayCfrXFIMOasoWQ91aO0Hr8WaHRv5LJGD9" +
  b"HqKJ+NM0gwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//+ARDI0IRIAAAAAAAAAAAAAAAAAABSy" +
  b"Q0U2W31BofH5ksEIv0Wswn611SDDnrKFkfdWjpB6/Emh0buSyRk/R6jifgAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAA"
