///|
/// Real x264 streams with explicit weighted P prediction and reference-list
/// reordering, plus FFmpeg 9.0.2 per-frame MD5 references.
///
/// Generation (docker `linuxserver/ffmpeg:9.0.2`, cwd = this directory):
///
/// ```
/// docker run --rm -v "$PWD:/w" -w /w linuxserver/ffmpeg:9.0.2 -v error \
///   -f lavfi -i "testsrc2=duration=0.7:size=64x48:rate=10" -frames:v 7 \
///   -vf "fade=in:0:7" -pix_fmt yuv420p -c:v libx264 \
///   -x264-params "keyint=7:min-keyint=7:bframes=0:weightp=2:8x8dct=0" \
///   -f h264 -y wp.264
/// docker run --rm -v "$PWD:/w" -w /w linuxserver/ffmpeg:9.0.2 -v error \
///   -f lavfi -i "testsrc2=duration=0.7:size=64x48:rate=10" -frames:v 7 \
///   -vf "fade=in:0:7" -pix_fmt yuv420p -c:v libx264 \
///   -x264-params "keyint=7:min-keyint=7:bframes=0:weightp=0:ref=4:8x8dct=0" \
///   -f h264 -y r4.264
/// # filtered references:
/// docker run --rm -v "$PWD:/w" -w /w linuxserver/ffmpeg:9.0.2 \
///   -v error -i /w/wp.264 -f framemd5 -
/// # unfiltered (`-skip_loop_filter all`) references likewise.
/// ```
///
/// `wp.264` signals `weighted_pred_flag = 1` with non-default luma/chroma
/// weights and offsets, and uses reference-list reordering (with duplicated
/// pictures). `r4.264` has four active references without weights, so it
/// exercises reordering, missing-reference substitution and the `ref2frm`
/// picture identity in deblocking boundary strengths.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let h264_wp_b64 : Bytes = bcat([
  b"AAAAAWdNQArZBHsBEAAAAwAQAAADAUDxImSAAAAAAWjrw8sgAAABBgX//1vcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1",
  b"IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gy",
  b"NjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3Vi",
  b"bWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4",
  b"eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9v",
  b"a2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBh",
  b"dD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MiBrZXlpbnQ9NyBrZXlpbnRfbWluPTQgc2NlbmVjdXQ9",
  b"NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD03IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWlu",
  b"PTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhA3//vbw/gU2VgRQlxHN6H4gHKRIU1nB",
  b"SWoKHBkAAAABQZo7EX+fQwhbG0rY7zUIv4gwgFlb58w/gLNfitUW+sO1C3wXlSjJUQu0uI7B3ha9JKiWfi4GeX2pcetK1qBlKdLP",
  b"LIRU5OwWg21M4lRnYX1pm2WRRYqaVXiyVSzzLN5DngRi9kHaTsed/oTq7KtnF/787Uwq2DXML/xU7/Ha8Nw2ndcm4km/3KcBvm9m",
  b"UghWN0ASNOP1M3zShwVuG5c6UtAFR/wvvC4a2wnP36QfMcPJ+m/8iQ/VxsiZ7msabm15llZVx2Zss5NmcDupe92Hm4/qlvZZqUwk",
  b"BHolALa+ZB6Bpt5I3Zw0HpitgoU+oo18Y1CFYT+ZhxlbbFFYZdMiq4hUC5aGTU1Wr+JNc+lzZD2Af+6gDmmbbM8vXSC3TuPh/jd+",
  b"lsV3cCISNtQCyuVGu7uPIJMzqW6ttlE3Oz97AX/OebxHHajEbZ5sNSoJqBaOJ/OHwynqRCTMq5xCpLDIj7KZhYbj+I52O0RnHCwG",
  b"lWY+mgVwZK6h8Qnpm4DLsldlzh1jIDvg9PD43Z2YEj04QdnX3uH9Lz1HUunUmrcZcleg0+dwTtTeeXAKvcIz5QU6hjasAm5Kho4E",
  b"W9aCFft5tTE/XtowZ+rbY0kRm9soA1pOPClgQVaOvrQ6nbYHrWjFrmoUB18Elh8kYZCGnvA42J5H9ns8e3xjRfm0Kp/b9jO7493y",
  b"exF9Ep37df45X2m9rJYOiAEUdX8nyRIC9jhPy07N9sLMU9URIEy+1hmSdg050JvcIBXB9sa9dxTuwCJi/BygQ/WhYCAJ0MfmVpm3",
  b"G+l3dMQ/34pwi6oJFMKSqjQIgRa3VWwU4Hd3wAAAAAFBmlJ4QhDIc0B9B+B+AfICAAIDAfQIQJf/SgGLTyJFQXBjWSeTKAi+PBCi",
  b"gmbaV5L9V+K32n/RBsu814dvMRnLV6272+yChib+e8gBE9Zdl3KJp2bx9Drh0C2AvsVqKrQrsFWiYhU5JJMo2XJHGKj51w0mmYef",
  b"6gNwCPHWzTJzBf4AGJdtAAAAAUGacvhCEPIjzBGAwgEKAwAEDMEwCv+uP4ffz0RyuGon0L01kx32tx6tb6J/mG2HLxuFl5fN0Akp",
  b"zgIVlZ1jv7JZa33vAAAAAUGakvhCEPIY8CsNgKoCqArALMCsPAJvvIzhR8mtVIdIu0Drv6v3VzX73Ta3p0H2xawJVNZccfAvqCpW",
  b"s7goyGthY4e7x0Y5ngPamLLm8BZ9NjGtAAAAAUGasvhCEPIzxQmAoAIICiAixQsAiv+7PdgfdtDY1EDOSDg8SSk86kOwVSWBSNoi",
  b"a9VtaykRcQAAAAFBmtL4QhDyFPBMWAmgagJwHMExwCO/xn/Gxx0xOX6WdLBRxH4jVssRz2+P7OmxEQvM40QVsSClDpc=",
])

///|
let h264_r4_b64 : Bytes = bcat([
  b"AAAAAWdNQArZRHsBEAAAAwAQAAADAUDxImWAAAAAAWjpIPLIAAABBgX//1vcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1",
  b"IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gy",
  b"NjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTQgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3Vi",
  b"bWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4",
  b"eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9v",
  b"a2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBh",
  b"dD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9NyBrZXlpbnRfbWluPTQgc2NlbmVjdXQ9",
  b"NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD03IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWlu",
  b"PTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhA3//vbw/gU2VgRQlxHN6H4gHKRIU1nB",
  b"SWoKHBkAAAABQZo5F/+fQwhbG0rY7zUIv4gwgFlb58w/gLNfitUW+sO1C3wXlSjJUQu0uI7B3ha9JKiWfi4GeX2pcetK1qBlKdLP",
  b"LIRU5OwWg21M4lRnYX1pm2WRRYqaVXiyVSzzLN5DngRi9kHaTsed/oTq7KtnF/787Uwq2DXML/xU7/Ha8Nw2ndcm4km/3KcBvm9m",
  b"UghWN0ASNOP1M3zShwVuG5c6UtAFR/wvvC4a2wnP36QfMcPJ+m/8iQ/VxsiZ7msabm15llZVx2Zss5NmcDupe92Hm4/qlvZZqUwk",
  b"BHolALa+ZB6Bpt5I3Zw0HpitgoU+oo18Y1CFYT+ZhxlbbFFYZdMiq4hUC5aGTU1Wr+JNc+lzZD2Af+6gDmmbbM8vXSC3TuPh/jd+",
  b"lsV3cCISNtQCyuVGu7uPIJMzqW6ttlE3Oz97AX/OebxHHajEbZ5sNSoJqBaOJ/OHwynqRCTMq5xCpLDIj7KZhYbj+I52O0RnHCwG",
  b"lWY+mgVwZK6h8Qnpm4DLsldlzh1jIDvg9PD43Z2YEj04QdnX3uH9Lz1HUunUmrcZcleg0+dwTtTeeXAKvcIz5QU6hjasAm5Kho4E",
  b"W9aCFft5tTE/XtowZ+rbY0kRm9soA1pOPClgQVaOvrQ6nbYHrWjFrmoUB18Elh8kYZCGnvA42J5H9ns8e3xjRfm0Kp/b9jO7493y",
  b"exF9Ep37df45X2m9rJYOiAEUdX8nyRIC9jhPy07N9sLMU9URIEy+1hmSdg050JvcIBXB9sa9dxTuwCJi/BygQ/WhYCAJ0MfmVpm3",
  b"G+l3dMQ/34pwi6oJFMKSqjQIgRa3VWwU4Hd3wAAAAAFBmlRP/1bm4jS6KGztnSnpJx5g+pANXVJ79xr441L/Bq9WpULLh+ClB5tK",
  b"Scgs26Z84fDcqzx38aJMKxEqJWLDUGllycAAoVfA1O0Pr9rpsee735QfSASA1TILzmHFcBoOWqn8iIxAzwMJp8cng3WyfMwBvF4H",
  b"VZttqKk2Ih9728szN+cdqiIUD+8FqEChZ9N4tPRLD5tvtgYhnoDXgqhOMuTZn8BpN3OgRO8h4TMSsGZlEzFiZgQ+SAaXYfeZi153",
  b"vVb1E62VWLJd5Hl5mgrnF9nOZnoTGeZ/CPVunQ0LNlWIRjYcR4p4mqQh2fCBGHsZ22aacx5hIN9V2k9ULhv99+qFul9TB2qot8JS",
  b"QNwJz79Ra300NTf1ezygVCE5vPn3cKMD8/g/PASp0Z1iZafmoVeQYnafmce8PTEapJoI58hVaSvx/S9zb+KAGqW7gW5mOL7BwrY1",
  b"x+bXxwz15PCsAWCMz1Kao3E4qo3I2C1hhYI1tcZT83sEudvhINf6vyy3mx/U1jOX+ZZmiHW8HEPsgskvMSsA1/uw8fFlb+DIZcIb",
  b"SjnLU0ll4ZMzUjFFHjDtt1Ruyeu1Vpq/F2LxperluFUoi8GzWx+4lkBGt2rG9EtyWQPSfWJLB5R3behoYJ+gJxHjew/NJS9qX3U4",
  b"dZHmbsPxvsmDp4J0mWb8TJE+Dh+QA/41v/vxdAclkiRLH/TQLVJH19AEo0+pOEW5SnZoHvyXT2x1O1lOoNww1N2U0fkEmB0+6Uvz",
  b"sSee6XqI9S5E2LnIvKlOfsF6RmRLs4d3aiaQdeMUuc8gVpf1kNYcFoZM0sRQhMkdVGZ6O2TL0oZWL6aIq3bSFolbHvGHbDORNUfB",
  b"AAAAAUGadl/IP7VvNrqxMBRgCXKH3CmgIZfShgFrrQnEkZOttwiDeGQ2ugoNalpRKuTIwovdcBWBvTQX12GpXgvu4vnc9Fxgeuke",
  b"qcRc6l8peylsXM54ZTb8m67/pd0JeSlqJNg1hDrF4WrxveSLTVEmp7XbGi39ck64n3FZC3frNPvrj+ea0KcVKwdZwC2RYn7Hnj+w",
  b"LR2uqWWBSDZG5tSX8i3x+M0yK4YrXNESMlmjqqJWs0WNhPEWZ0SeymWN9WxqIomOba27XcfTwYp35LbViosWQUyzhU7YT9Jg4i6q",
  b"As3dcvi3HAOnj2V7MEKyJFIW+ftDX5I4o0RrMCshb/gZ6kRYMCOG98sPlJTkWitayxEiwFdjbllEwl9tMatoDkoHpC+wPfmZru/n",
  b"qweAM7TAP/JUiUpjjP+uL0kvNu0pvAtqWvOq+kh0lYzUSsfcXTigAolY9mrSuygpZr6x1wSvhx4rCdrn2N5Gbt8uRpO7rwALg6OH",
  b"FpVr2cJae/qpc3logwLedv975GKoadpYblnyVU+7GPF0gwkzUHM32YKK3zE+iF/KjsWj/sQf4VUwAEtLprxy19BycKqjRAfJuHpR",
  b"Ejjf+fSG/tslwh6GQX00fREmOYeXMRo0R/Em9czqeYYQlq9wn5XOBxOBngYQKeRhBn96Tq7ybOt90RGEgDmLc//6pGj6+cBKGUPA",
  b"rP+VO23po5f7QFWwQlaDqntDMykZ1ux3+Peyrn26+/dQnoVrlB9fBQNOMUbnZdv3b+ehgIc2ArFgAy2RW7vfYXjlcGydvjXaHODo",
  b"jHxfYb0Tbq7TSJzXNETt3Dk5x2WCsjIr/BKkI8oWE7dO6BhEr4AAAAABQZqCv6pGRA38ixN9r3M5sYPPM0Qej65J8CiwdbwIU/ho",
  b"vTpj7e5m8sUQBWiRxFEvulYeKJxlio7vHYqFyYf6G7E0olff3FS+Wp/AaG0GCevPn3b6cDNOu1VxnFmA+EoTtuEWpJoJwYDXFtVd",
  b"HkQ5B36SxMo6V0vneZN3uDjbkDL8fyJ0pZLKKKghbHvtlDVY66/HJyc/cd2PLUFse+zcULIjz4DrPxkZBOP+H4U89wfRgtNESZIa",
  b"XWAghhYzNcVxN3/wXfvrG19veYj984W8UxNVnItFMOEuGXcKiMSf+GdAA4uCJOiHI0+OHyQVpPN1861IwfBf0eyumLkPICE778ab",
  b"U/T4tKEtQE3is9Zm8rNt5AKlZBPW6qruZMVCI0PCyUsg1KCOPE4Hr4VbAvpVRop+mk/CxcqHHMFzGm87BrOTPRJ04n8U6uwVhSF/",
  b"Zo2h5T0JjWczWLG1Fx6Fsv7XFmCafiiK6IUgfWGukBWvuJFd6NmhoVsMhkfY+1zfmJS/xb/ugio1nZEq3gdyXRbdDEhdEBGGksVx",
  b"2J/SSs8kEZkG4AxyEuT+KZzH3abBKotl7WPHBeutxMtLskPBmvpC1ggZh6TDc/GRW6oR4cnUSngfzAJ9ypQSxHEAAAABQZqib7jR",
  b"1Dmyey/fK/1l1b2tP5xZ6y2FJs2qANkvMHznmuSrBnnt30DOoYzUkKV7/C6j1ig89oR2JkO6J7qQ2eDZnjdZ6b5XPkOnw8q7a/kM",
  b"tBh7eJNdaXFO478aLx/TYira8Y5xUiWhbnsFGcA9f81j3+p1B694eWfXIYR8Tf0FX+XVyXgd46Wn7NpHle3+XW+u6r9TVLdjCPYQ",
  b"0v7SjowKBBlMGsw+liZhdQ+PZICDp60lTzx7/lWUiV9JzvAmpPsEHeO5oW+KRph5OoRNYmZCowKNIWLGpiRmd1JRiYoquLDuFvGO",
  b"8t7kEUure8D6cnp02qBU6Ig4/QR5E/AekQhxgN+IckiGapEKfiJpHKVH9kTsVWnmqYYQa++CbC+CqZja2FuLk59TKC8hntwCKY8C",
  b"46nfRUwAnuVJxTZb/JF9CzzD9LQQZhX5AcFcuDd+EfyMTj3TIeEj5VcNgeB58T6waJcQjvuFYK3dB9qkRZ1k3eAuvUsYKRDvZHEB",
  b"iMt/3VGZQRXS3hahbA3PLv2Fe4TtpG0+LdfRkfIJpmRO2DSrq8kexr69VxmejdlUJTrz3QAAAAFBmsIr/7bsYWKitR/p1q4KJbFI",
  b"319eLaFI5ffrZsIaMuSPcjfliVHF2Y2mFBaHhu0o3XlVfXfa7THEPO6hsTK8lVSWV+MS+pBGLFUAW6uH9PhjC/Q4j4+Ry406eyBh",
  b"RpmsOxr/eAXjDyAZKT6nmfQjrq7HhpiETT2QZwm7Sdi2ydGtUDZ2EllngFg9yqcQReEr7JyNkv5uZFofczfZODRWQQukO6wasyML",
  b"9JX3bbOpLOlf5rDkK6KgW0w0VD4eBKF4wNwy71Nqsvrg8fqGmgRnBw731GwrOkXQlAiQzJD/8Kq9118Rlkjjkp9iQckyK+9snnoK",
  b"w7fSnANadIM5PN1zCC57NYFYAbGTxrLYwPzQUmQP/kN9tj7GhKMns+3nH8/Iqo2XNm/TntmwYMuHxnfTBa0/EkZepiVIu0cq4PHI",
  b"L3QS5VBdP9nUbt64bBeGwr1Mwqejzd80hRtt5JxLKiPr",
])

