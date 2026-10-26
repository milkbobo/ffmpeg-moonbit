///|
/// Real-file regression for the High-profile 8x8 transform
/// (`transform_8x8_mode`): CABAC residual category 5, `dequant8_coeff`,
/// `ff_h264_idct8_add`/`idct8_dc_add`, `pred8x8l_*` intra prediction with the
/// DC-edge remaps, `neighbor_transform_size` flag contexts and the deblocking
/// filter skipping odd internal luma edges of 8x8DCT macroblocks.
///
/// Streams from `linuxserver/ffmpeg:9.0.2` (libx264, High profile,
/// `8x8dct=1`, CABAC):
///   - h8i: -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.6"
///     -preset medium -x264-params "cabac=1:8x8dct=1:bframes=0:keyint=7"
///   - h8p: same with `ref=2` (multi-reference P frames)
///   - h8s: -f lavfi -i "testsrc2=size=32x24:rate=10:duration=0.8"
///     -vf noise=alls=40:allf=t+u -preset veryfast
///     -x264-params "cabac=1:8x8dct=1:bframes=0:keyint=5:deblock=-1:-1"
///   - h8x: -f lavfi -i "testsrc2=size=32x24:rate=10" -vf
///     "noise=alls=60:allf=t" -t 0.2 -preset slow -tune film -crf 36
///     -x264-params "cabac=1:8x8dct=1:bframes=0" (intra 8x8DCT macroblocks)
///
/// Expected hashes are `ffmpeg -f framemd5` with and without
/// `-skip_loop_filter all`.

///|
/// `h8i.264` (I + P + P frames, 64x48).
let h8i_b64 : Bytes = bcat([
  b"AAAAAWdkAAqstCPYCIAAAAMAgAAACgeJE1AAAAABaO8PLIsAAAEGBf//W9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUg",
  b"LSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2",
  b"NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJt",
  b"ZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4",
  b"OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29r",
  b"YWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0",
  b"PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0yIGtleWludD03IGtleWludF9taW49NCBzY2VuZWN1dD00",
  b"MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTcgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49",
  b"MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAABZYiEFf/p160JDO/IZudaboamAEVe/xCCTAb9",
  b"VNn5rGHrf6NUGnBGpUp8WpXa5+CXfZjkRGR5yrEet2pV3s3bWmnveERXkrY6N9OiKG6eUm5jCZFxwvko1Ug4dfMP/GrRhC4QWYHN",
  b"PzWjx1JkU/MsEuv3ZSy7S3CtCe8/ktEi7SIWpD8FtnTk4swlQlr0tR0ypxd8RVl8HU8HuAf1bs4qUZ8lqNHpzjW41BDAbxlj4QFs",
  b"+EwshT2vayIGgdg8sRECK1IKiShlmMt5Xnpm6CG4ILf02vPpdB8Noy68/eU08/R9eqj32qiN/zpMRa8xke/qNA+pnwhAXNJMyxtp",
  b"MZ2CmVETg6tD75+m/e11zbXKDDYK+8ny2E2Z9pWaL1Jmbdzojd9nZ/SEjl7D4M11UxDhZMZC8tIqEBeweT6z8rRBmNSsvY7z5mxg",
  b"67UJzC+OyGQgrFGpEfv27zypYaL+4QEKbyx6nDm+qadcUDzcwtbd6pYqvJyuZhv6EJRRuFyXnnUhjrAKgliC2D73jo467f8D27Nx",
  b"ReSvlh4+gY9h/3PcDQ23LRtuEr7sTZRt9Ho+4I9G9idTiCdpv3JxklIeSdlOO90LEEil51M3ojdlOYnVJaAIPIDuVfSTiXahRZaT",
  b"H1+exYVEB15DnSjgeutBMKd2izLaV7oUsKgo4hBb820PLB6Jb8iQPZd0DAdjcqKtCQz7mdMtLmB/kqIWqGmcZcngWYCwsORva2FC",
  b"3WtBQT/h63RhYvmHcvGqXitzUwNedOf3PMNwgBvyPBFf4rNdFSYY9UnXWNbhJb4s4+ZjZjdn6MOChSie6d1su2VAI6p1Svj9jdbk",
  b"y0e3WBmqqLsT/9V4dPagCTucRsNv5uxjxpG5fG6xe9fdrt/2A+7HVQFXdwepqNeT3pV2qd5CmFLwmD0mYAT2kq7L8cnKcxsKdlvI",
  b"704HcUOt0vOK1U2MpLinwN9IHCJ3Y4t1TkoAF9lDxktlhOdkCKGjdwIbpAMXnJnhNmoeHxncn6Z1akBTGthCmLlIooBoKC4eOfXr",
  b"wxxc6TAMq5oeVNAmaW/BjETAE629hDt4iBKRmoOAbj8+ARkWOO2VNy6OTLUQ+oDEa6w/v+4tfTWqGwC1Gd+WKZf4V+q85eIR2QSI",
  b"PAtCVS10YtgNYQS1RagE3MR48eeKi/OqoQvkK7Cl/4ymB2UDkLDxAAAAAUGaJiM/wpe+7AfDg9V/ibSOpfkWJYBP6og75k1Cqrgv",
  b"MJhFqXSTKRCP5bwgAAAAAUGaRiEPzNR4lJUVPQ2eP4iy29tCID0Vu3N5kyF5nfLIZeN9aPF9kGMWQmbqYQ==",
])

///|
/// `h8p.264` (I + 6 P frames with 8x8DCT, 64x48).
let h8p_b64 : Bytes = bcat([
  b"AAAAAWdkAAqstiPYCIAAAAMAgAAACgeJE3AAAAABaOrDyyLAAAABBgX//1vcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1",
  b"IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gy",
  b"NjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTIgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3Vi",
  b"bWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4",
  b"eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9v",
  b"a2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBh",
  b"dD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MiBrZXlpbnQ9NyBrZXlpbnRfbWluPTQgc2NlbmVjdXQ9",
  b"NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD03IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWlu",
  b"PTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhCfZZ0xH13egtNybB1mdgQ52Bmym27xM",
  b"vl96qa2de8bATj6TzsM3v1Sg3pASldbuqnKc6lHaTUAfeQMeYXHp7voSfXT3OHmOteokkuM7rcXQoQZ/qUd5fPrRZFR7TZ+MHVHo",
  b"cPFbETN2Accd3/eQOf1xXdH+coz4pVCiGjmZVSk8UEC//ZpOZm7lDOJYhxDZHN2khHGwBXq7eiEWPUO1Z3c2vEBoL9KnucfST+aA",
  b"wIbb4gV8jPOBWCYj3W1c0jUARpJAsKkBGV1DsfxMAJxfSkkrkXWc0aFg6rrdObX8ro3PtPKFVo88FOuFSoC6gvDkNI3YTRMHHjPa",
  b"o+ohFsUzvkKHGV1oJtHWoDhFqX429OU9yt2FlWDG0r15nZWAlJs935ccA7IgZ7m08kyZIAKJTkk7dyeN9biphQO4Zfn4bY+iC6f9",
  b"QD2FLH76wu/SYaIXiQdLEBETZ7w8AG1Z6I3PoQiEELW5weHras/hLHFeYmE52YgiDyN6ZLey2VFt5FLqbzjhgKm8EUAksMPnP8xD",
  b"Xn05e3OjvMinkpUw6QbZX8VJzhE8xmbIkpNg+ch0C5lIqOSX3ksGRZcZKQijzqMCxMSCekpQurEtVauL/VBWMSFhGwvEO1WIg3AG",
  b"aQhCEemCUE3fE1e0VCUYIANPFUYHFzUlv1Oie65kzzG/y03mFvVaBWO4XAON2kPWSw69D6/o0fpBb7U0AhYACakj8CSs9POSLP4K",
  b"MYMTVU1XeYAdYSj8F+Vw44M0YSR5ZqOzXnP8RxMV3IBQHw+kZ1q+ri3H5+f4PX12Ryn7uVQt86ptoltH+p9R1LFjoY9tqZzecDvb",
  b"3flPeGiD0pdumh5xNNFYx2UO1KgmwG3Md7gmGlWHe58jUFycFj2mrB/32PPtUIwVcyKJTc1vIyNKv/LfolqUDePNoAxJ8QBRqzOO",
  b"RmrrJa3PZ8bAdPIDPfhdfHE1P3hcgjwu7744CcaoEz4GVufCOGM8PQtco1Ucam1I7Tx9hZf3+xhUAxOcw4p1HAWVHerZWEJgC5tI",
  b"HKCjDu4sZWVVGvC+1eW3A043SWeDJWco8S9CSfJdYmbRkJpkTK6zc5JsrYpkeeq7CqxBymxlJuNqDKakNtvAzU7+7b/R545YJE9u",
  b"ztEhq2NT3PPioUXYi07DSyx72fhwgJDbbzeiRcrzQnCslE25SFblchWsYwJYjvU2IYf9WnpljdNGAFK3xbV7ZbCrkcC9Uo6j6EBW",
  b"mgb+YBeHa2iGYiLib5Z7Q2l8eUMshlpTRtbTea3yiRSZg0PPbCam0fcBagfedkgQ8bXPnQAAAAFBmjsTf8YafLoW/4LAb+KK6ICL",
  b"P+vm0UocZlT5DhZA/EfakAygvnZLUPlOtG6wGTpVu7NtBGuAAAAAAUGaV+EMmUwm/+2YL7rTN51ehZRvQ2K69v2Ui81pyuszm29S",
  b"vDqhJC1z4ucagWqE5Qkt3xJtec41JH8Hro2sweJknC0AAAABQZp34QyZTCI/s4EFK0hMNb6zjP+xS8gBVwAVbnP+zWCWZ+nAAAAA",
  b"AUGal+EMmUwiv7smrLAOKRvWU+dxKL+ID4IuQNMbe6EAAAABQZq34QyZTCM/vyivwbUSll5lwVFQ0wAAAAFBmtfhDJlMIQ/IErTo",
  b"YeaoalFagjAKYQ==",
])

///|
/// `h8s.264` (noisy I + P frames with deblocking, 32x24).
let h8s_b64 : Bytes = bcat([
  b"AAAAAWdkAAqstEvy4CIAAAMAAgAAAwAoHiRNQAAAAAFo7w/LAAABBgX//1vcRem95tlIt5Ys2CDZI+7veDI2NCAt",
  b"IGNvcmUgMTY1IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93",
  b"d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTEgZGVibG9jaz0xOi0xOi0x",
  b"IGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT0yIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVm",
  b"PTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDEx",
  b"IGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xp",
  b"Y2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJh",
  b"aW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTEga2V5aW50PTUga2V5aW50X21pbj0xIHNjZW5lY3V0PTAg",
  b"aW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD01IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYw",
  b"IHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhBFv2tvyjPaj",
  b"XZ4rIwvN6i58uAS4wPjlkaIpwB64iTZqW9iJ1w8sMVOSie7fIqcfa6zHL8b3+P4ihmpZjk+p+7R0JMtS5tqTKVNf",
  b"qu7DPfGY4630NID6K3Ilj1xYj3pc66VK1G8vw3YWHOwhsMGK14Fb9K5CbbsuKfTET4mG9Okd40Cmf5Vy2gqjdN3n",
  b"yb97GNU8Oq1+hQgo6HwH/rPofJ01kVNKfpaqppmYzS7jgf7mTT5jRAYZjPudgvwOh3+wp1YDYrJn+Klxuz6pfevg",
  b"yCl6I2yy26hJ4oNdahFV52LBrTuZIqeSOC5wlYrRaj7bZaHJXmIrVs1zJI3g55ng4KKiNtjCO/2rnxe/HtP87MWa",
  b"Mb2qbdJllVtudnOk1Xp+xzk4sSt97oZZl64jmBlnLp6EZRvWB6rTghnMIZUccJvryqQjrHB8AlXvLyoU+rqp22t5",
  b"n82hEllnXR/B9n+Mu5sBMoRPpqHPyE5RUmVPnYrBOMNIZmGXjhMJPeOTLYzU66ZK3NBcesmY7e/uj5+XR76RJVfX",
  b"wYeY1P+Dqbz7I28BpC2IJ3KEN4pXTyuflD90NNxsu/LTyHWnpdaXUMsPkDgLcysYD5g/BBs8Xo/845X7aW/P1g7C",
  b"ooiWmLZkI8v9fFnafDrGaISTQR6+A1Rive0VWjQmi4A2Mj0WzuEBjQn4gdDZ8XstrvxITQAAAAFBmiYirf+35u5d",
  b"1wlpaVe2f8Z/m/w1JCV/1sgcY44Ys+qqJ3x0+J3uHrlvPeYR7NS5Y6c6+/COHFYkCWsToG9WWpdCPzAbn74P38ei",
  b"h+U4+JFszyX1shqPjamYWYzFd7V0Y8Tp1r7cUV9v9PvW6uz71mI/5Z/dhh+dSzieABtFTs0V04kb12bzz//1d4ys",
  b"EM15+pHmb3dxBlxRgkcefFWNFFoOgKQjPxh3Ar8mwsd8UNTNKBC5RpdNTSIrxt6aHSbFosUxg+hIqS89Oe8TlYF1",
  b"kiskelPl+/liA812IHnsywsgPLA8zvDA9FF99Y1l2XR+653ZMPwd+ROEMJ+8JyQ0c/5xYpQVOuVLuM/ifndB8Sh5",
  b"ru4f0rQ3wBSuHCaz4LJ47sIYnGEGUxJoNNH2jLh8ZTB48uRwZ4EMLykZ3y6SBSGiM7wS//N/Ouiiing99eHCCxw0",
  b"ZRBmA/B7aRmuv4nQIJq1kAm3xEUW7hvVCg6dHBuNVsKGkAtNFovEzz4Dfouv8AAAAAFBmkYirf+36bIcPI2Vkp3r",
  b"/7TrXbNoeNW9+XFFENNY/86g8cwK6EayHht3ND7A0Gf/5z/nLQpbKcCv8iUflzEaji6iSBVRHAtKu20wh3htpKzf",
  b"yARVXm6Ix2RgaJjX5fyTkqW3bWhRzUG/AIfxwTfor1ZunjcZkGueWBswX3zome2SZ9Gj60xAUfwSCvFp/oipw2Zs",
  b"5U2iiuB0275CXWxYi8QaJ9eW+ru11HI8tG0nEu9T7gSgYkL2d8T7pOOFeCAanQvNctmblSNFkgeKc8yKwE2CHzQx",
  b"mixtOM12TAeKD5Bs21Iv8wKllOkzBK1ds0t1UXxLvAUVKH1vaZcjhwklf8cOTBGzS8uGoSdv5D9gtOMJ5LmzNbPn",
  b"hnt6obaAyhMd8ZIVIndVStBK54aZq/duC9pf2WZ7VC8GGui8xuREHuZI/TJ1chjvo8SPgX2k2IvSvQgPp3uc1/F9",
  b"Jt9oBnKkFD32eJ9AVYEAAAABQZpmIi3/sfKuP/3OjMgj/77dXmET3K1MuX6oSyisvLJYWCI46lnP5wBECwQmE+76",
  b"fYx/igNEc77zwdzrF6CeYpDTviQ1b1mlImFT3fLenUtESpBuXeVf8CghV1ghgCH5VtV3cXbMg1BSev4na03Dzn0u",
  b"WbHwlBuLZXTF8iof9AhL/JL1+3p0nT83bULTqEqNweiONh8Dw1Cm/E4jMcGC+EI9BIX8n+WslJB7mOoR5/EX+E/1",
  b"yyqs6/Hrh2mycJT5ityhXCiUNfsZRhLyyN9R8bAQ1FZs1bkySqLTSLeiQ2I9y4RxU/bSQgtjyLwST2yzdrKKA1mO",
  b"E6dQPMzLKEyCRoCqr8H03KBZ0pA0nDkBt4p1vH/jUzfJdhOqiw/1HTVi4ClPzc4qBGqd/M4Fq7dYw6/YXjccy/u2",
  b"OrVtuExrRe7+2ZGvVr/PX9bo9sRaeg5RqOhrwlz99Wtr1z+bRzfC9VN24kuITbM5LVGHHlHXNb4qeM92wXaa/XRP",
  b"UmI+Zj/g+vceIGsLoucyMQpmKVyeWrmmd/Y0WsWmUfY5CJmIgbDP4AAAAAFBmoYirf+37I4VHnuVLwfg6l/6Y8V/",
  b"p3M154lDmuzaOC5xkTfHfKCKQ9Urq+u9/7PKj3v8T/S7wbKsvmJeQK1Pl/T7D03Pr7sedNw+RHxRLons88mP9sNN",
  b"tbxvmaIZMy+y/AT/jN5ZgvkmRPY5uqeWxkun9y6ngwpyDXuNwPBBM9SUYJ/YJDdWUZ3DCR2nkCmmQXinW5ExjgL/",
  b"txhX6gfnU/UibVX1gg3KwPXG4qvDpF0BBEhclhxI3n7d6aaqZzuazGy6TozpeubU/VVlhRw/SqYN8xe6Pf+Z34pT",
  b"/vGCuLYhEq7aQ5pa1Lf3yHa76GD/CrbVKlt86fudMb1rz4HnTk0nwVwYoioRI5SuYjD0BtOSLODI5tcka8s5obH6",
  b"3UXFeoZVrwCXv7SBts3VMy9nH6xXHix/VwbkOkomuBtML6wMH7EVanpw8w2gq0Ntjr18CYH5Yp4OtaSc9QAAAAFn",
  b"ZAAKrLRL8uAiAAADAAIAAAMAKB4kTUAAAAABaO8PywAAAWWIgg1v1MC4aDD6kvUNAAmRU6vW1T1u9qv4e/ADT6iL",
  b"CndZYwJl6eGehBGzp9Mcl7XML2t+L7igtrBgNMTxiYqI6ebf7h/9Wz2W9kn27wkynC7UeWQtL7w6pTdPgntXrMOH",
  b"VeGEmlQF8EEbKVNul/fa5yhk/4IMVlMoGHy0isA3a2KIDvVy0e2ypppjKptiOnPozGfGbGsBpK2VyePNMlSklPwO",
  b"0bnjfetmPFOsZichtKBO+axNTaozqguv+qTNCd7zH6+aTuzOtby5dFUP2tgDpPTmHdn1wymYht0v2o0SrchXTfi4",
  b"VzyZIdC/OfqUhL0azC7MU7GNXRTU8c58NBS+N9wNyp/SsyDDTHs3obaV5dlhSO1oddcOa5lr2j/uRmjX/Ue/tooV",
  b"yk+GOvcmbrpzQLGGwfp/iM7PChoY3uTjVb6YprBVlH1QCP9b53aLbBjGa3s3hP0myfivF8F6AYIu1wKU0fBORIhD",
  b"UkHIhyoiylieEUc4FYpayVDlrpfai1hLslOSUBKo53UtCRhevfktCXQMtc3GgXzeqZ09yPiHUx+pVvmGluc0QCjq",
  b"94kdCC+p6RwDvS1vYDYLrpE26frcCJNrS7fWN3JrGaj+OWuVtoQ0pENG7QVbj1gWXiIQEvPLCWJEqzkgZ5Lvyfux",
  b"A2noq79eHYDyRp26vDLka/pdR9symgGpdTRAKRsabiN5GmOI6aej/RvycaaRgBE8ItcHBYMffg20mfj4B6AbCiG8",
  b"9Ebqw4z8Xfn9Bh0AAAABQZomIy3/vKfC91tXKDItCh3/Tk+xTZ53gdSYUDDuoXxlFgZDS5P5rNZJuXome/ND9eJ2",
  b"+O+vYa3XYJGW8Lz7Vn2dO71Vu2nri34usHZ7FeSqtf8/Ddr881MF9W+LZp98pMo7IUApinH7/2p2Rsp2swSkuy2H",
  b"lT3VXyadd7x2oiXhTHe5nPJRYuT//PoeRdKPIdWCAng6Luw6xqOFgH+PuNSVBSm+FhPaMAFbwamrvYCHTeB+B9Qn",
  b"Vgbz2j0/D3yOkrOOOLwMW4luOqVvcqXYxOvt3LiYj1lGz436b4/nwDAeVO42xIz3+CBcbOEtsCT5k6ZllyrMfZ66",
  b"vDDE/txh+EVa5adY0Hrd2y4TdEkGLXwq6y8mI54NW1/uOajix62G/+cxf3yTH3WEDtTwShZ9+Em8eywEGdztfkK4",
  b"HPtgQP3PjT0JgUKzhCce5jrHhm36tkLD/wAAAAFBmkYhC3/FKXKiO8kRD87LG2/1j1zDlbHtLXu4mePVKGxK08Ej",
  b"2KYN5ME3PhVzOgpdHbrc3FyPwgR2Rl4AG3iSraL4cEsxUtstiJZwdHoFrBRczdgmTUZIZMr0v8PCjhQN2uQWAHJa",
  b"YraecmOLrWp0RnsChl8d5hjnb12KbBYij/XlYz/1R3PYhyXn9/lG9WQAKbf+CFQj8szUwRRH3p9ZaNh02+2+Jq0Q",
  b"99bcPVFEIy4HWde9/tHvAPLa/vC+W3o3F3+rHs6i8pO/LUISyzQXGV+zEoJgV97XRZvTQ/5S++nt+523vZnJGtBn",
  b"h+sPw4OD3Xhxgqk0xIdiM//9RWTw56ABAUAXKR/5PBCfm9H5toVAV/VPEQ==",
])

///|
/// `h8x.264` (all-intra CRF36 frames with intra 8x8DCT macroblocks, 32x24).
let h8x_b64 : Bytes = bcat([
  b"AAAAAWdkEAqsuS/LgIgAAAMACAAAAwCgIAAAAAFo7gKTyPAAAAEGBf//TtxF6b3m2Ui3lizYINkj7u94MjY0IC0g",
  b"Y29yZSAxNjUgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3",
  b"dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6LTE6LTEg",
  b"YW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTggcHN5PTEgcHN5X3JkPTEuMDA6MC4xNSBtaXhlZF9yZWY9",
  b"MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTIgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEg",
  b"ZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTMgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xp",
  b"Y2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJh",
  b"aW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNjZW5lY3V0PTQw",
  b"IGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTM2LjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4",
  b"PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAFliIQ1v9ZtrF3XBwztfc6esYy/dEcX6clv",
  b"sz9Mh1RRkAAwyUOsaM5dJQ7QH4vxTneL+/cryYeahcYETLgOqq/YklO5qCThpXi9lgNuaig9FGZAx8fOup4MhCSJ",
  b"R8r/TbvXwjhIf4/5PqtwbGxpgG56mlsJ//5F0Ybqpv5Orqg9cLWrX/9VlzAgO0CNP8awjyaKJk8qGAmdli3P1Gja",
  b"Uyj9QeGwmvCb8bEI/jmM4sIoPeAkmcdZPaxg/FgvCbD+e9qlVvhMc/4SbeknCGyGntqI05kluLq1VfqVcsgH/7Cd",
  b"Q//n1rdQ+mtgYdtK/i0yP2XFC6gIkjb88Qmaq9i3sGaCsOR826NSiEj44rAlby/mgQfgAp3eepouZbeGbkbNMatJ",
  b"8P9A/T1Dwk2/UWQfyJJWEw6n3w9pltwICirI92eQ4fIhxrhadGZa90iYKeWwVMR9zN0wywJrPedyL+TpGvkHQP1n",
  b"sluZs8lr1ekZ6Ws8F3r0qoMMkjMwNRLYZ5x6nuRf8CdFnpJ9ITBqkSMbMKDMFODfri8y0HNnTT/BAAAAAWdkEAqs",
  b"uS/LgIgAAAMACAAAAwCgIAAAAAFo7gKTyPAAAAFliIIDlv96VmvhMkfzrsln5im9B7uw4ut+/b5wTZf3//symvff",
  b"/+qaoPx9qpt3vQYOSCHCrKdV//un4TapxM/+3VMJgNqIDddplD6LmndZLezFN79rCkesYnzuKRZs4Olv5I/4mbv5",
  b"+APUD8+M5q5y30pjCRUTE3oYVDm++voTmv+Yq6qvHqIXHUVzE0qhJwBxxiflmJpv85OSjWw6b6uxjxL+JbjAifPx",
  b"8riLvGv5eQ4L6A==",
])

///|
test "h264: 8x8DCT inter residual with deblocking matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8i_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 3)
  assert_eq(h264_yuv_md5(frames[0]), "1a0f8a34e1c31f998b3c1deaf4dda4bd")
  assert_eq(h264_yuv_md5(frames[1]), "b5d678283be96162f713a903257cbeb4")
  assert_eq(h264_yuv_md5(frames[2]), "1d4967f60e69b6214419e7f8d7e93211")
}

///|
test "h264: 8x8DCT inter residual without loop filter matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8i_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 3)
  assert_eq(h264_yuv_md5(frames[0]), "dd063196f797d6653165e9451868b258")
  assert_eq(h264_yuv_md5(frames[1]), "7fecc93f796819d101b5782f515b62eb")
  assert_eq(h264_yuv_md5(frames[2]), "a33a26fee849c4a7d4025975e00bb5f4")
}

///|
test "h264: 8x8DCT multi-reference P frames with deblocking matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8p_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 7)
  let hashes = [
    "f4c1772d2141cf970746ad4f7f1bcd7a", "410b47f9081cb15a862fb96c52fd0769", "50372189804dd6967a8da90f40b01c2a",
    "c4158b8ebcffba5bfcd8306116c98826", "8440fe0deff4ec24412e5694e795bc24", "c4b9f7242c50338e22c0614559aa9dfe",
    "336aeb645b02f3c01805af64a8ac31cc",
  ]
  for k = 0; k < 7; k = k + 1 {
    assert_eq(h264_yuv_md5(frames[k]), hashes[k])
  }
}

///|
test "h264: 8x8DCT multi-reference P frames without loop filter matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8p_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 7)
  let hashes = [
    "dc69823d55c375d200cbe1edc9589380", "7ee2b4c41fc8a39ec57030b0620e74b0", "4d624c2981946ba99412cb6bfd4481b3",
    "2096c3dcb697c538d0d316fa84f750f3", "50af408400ad76fded05f999707c489a", "78e34703858155df27d623383f051276",
    "195c227b051b6b6ee4f11d481b5cc6a8",
  ]
  for k = 0; k < 7; k = k + 1 {
    assert_eq(h264_yuv_md5(frames[k]), hashes[k])
  }
}

///|
test "h264: 8x8DCT noisy stream with deblocking matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8s_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 8)
  let hashes = [
    "e2b0cffc8a2dd1b319b3a1283b07c840", "e859e3da7655b4912b14b920e450109a", "471743d1ac7c9ed4dacd05ec8e6eaea2",
    "2aacb53b75ca0ee6cee2c2268ebfa902", "7f6aeb811fb7f69ef6c671697bbb342d", "586191be235a9bbc9d22eb265d424f37",
    "29fdbb864dcc77c60ebf82ca23658bcc", "b2d4c03180aba1b2ea12f074ad04fe26",
  ]
  for k = 0; k < 8; k = k + 1 {
    assert_eq(h264_yuv_md5(frames[k]), hashes[k])
  }
}

///|
test "h264: 8x8DCT noisy stream without loop filter matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8s_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 8)
  let hashes = [
    "d69ce3223a3aeca9cf1fdbdab218c421", "66d6d827b36f47782b449845ed3346af", "efe7f68baa65824b89f4632d93e644fb",
    "9243d1f38ed7710d4f50dc552f90ab68", "5fe921be49f86580fc233a95482483d9", "3bd6b677896f75949c26b4b15c2ca0a5",
    "5b3a0317c86551caf304582d369a5e3b", "38236ddece280316784e9d642e5a07e3",
  ]
  for k = 0; k < 8; k = k + 1 {
    assert_eq(h264_yuv_md5(frames[k]), hashes[k])
  }
}

///|
test "h264: intra 8x8DCT prediction with deblocking matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8x_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "9e6645f4cdfe4ed94b5ed23e59151aa1")
  assert_eq(h264_yuv_md5(frames[1]), "d917b79c5d55b8101242c940e29b9464")
}

///|
test "h264: intra 8x8DCT prediction without loop filter matches ffmpeg" {
  let data = @libavutil.av_base64_decode(h8x_b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "314e24e43ea48ef70a4bbdc4f06a4d69")
  assert_eq(h264_yuv_md5(frames[1]), "a728cc12e401eceb284d7dde3950c5ce")
}
