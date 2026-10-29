///|
/// Real FFmpeg 9.0.2 WAV with a `LIST`/`INFO` chunk (IART/INAM/IPRD/IPRT/ISFT).

///|
fn wavtags_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let wavtags_b64 : Bytes = wavtags_concat([
  b"UklGRvwiAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAATElTVFwAAABJTkZPSUFSVAsAAABXYXYgQXJ0aXN0AABJTkFNCgAAAFdhdiBUaXRsZQBJUFJECgAAAFdhdiBBbGJ1bQBJUFJUAgAAADUASVNGVA0AAABMYXZmNjMuMS4xMDIA",
  b"AGRhdGF0IgAAAAAAAf8B/QL4A+4E4AXMBrAHjQhiCS0K7gqkC04M7Ax8Df8NdQ7bDjMPew+0D90P9g//D/gP4Q+6D4MPPA/mDoIODg6NDf0MYQy4CwQLRAp6CacIygfmBvwFCwUVBBoDHgIeAR4AHf8d/iD9Jfwt+zv6T/lp+Iv3tfbp9Sf1",
  b"cPTF8ybzk/IP8pjxMPHW8IzwUvAn8AzwAfAG8BzwQfB28LvwD/Fy8eTxZPLy8o3zNPTn9Kb1b/ZB9xz4//jq+dr6z/vI/MX9xf7F/8YAxgHEAr8DtwSqBZcGfQdcCDMJAArDCnsLKAzJDF0N4w1bDsUOIA9sD6kP1Q/yD/4P+w/nD8QPkQ9O",
  b"D/sOmg4qDqsNHw2GDOALLQtwCqkJ1wj9BxsHMgZCBU0EVANXAlgBWABX/1f+Wf1d/GX7cvqE+Z34vffm9hf2U/WZ9OvzSfOz8izysvFG8enwnPBd8C/wEfAC8ATwFfA38GnwqvD78FvxyfFG8tDyaPMN9L70evVA9hD36ffL+LP5ovqX+5D8",
  b"jP2L/ov/jACMAYsChwN/BHMFYQZJByoIAgnSCZcKUwsCDKYMPA3GDUEOrw4ND1wPnA/MD+0P/Q/9D+0PzQ+eD14PDw+xDkQOyQ1ADakMBgxYC50K1wkICTAITwdnBnkFhQSNA5ECkgGSAJH/kf6S/Zb8nvup+rr50fjv9xb3RfZ/9cL0EfRs",
  b"89TySfLM8V3x/fCs8GrwOPAW8ATwAvAQ8C7wXPCa8OfwQ/Gv8SjysPJE8+bzlPRO9RL24Pa395f4fvls+l/7V/xT/VH+Uf9SAFEBUAJNA0cEPAUrBhUH+AfSCKQJbAopC9sLggwbDagNJg6XDvkOTA+PD8MP5w/7D/8P8g/WD6oPbg8iD8gO",
  b"Xg7nDWENzQwtDIALyAoFCjgJYgiDB5wGsAW9BMUDygLNAc0AzP/M/sz90PzW++D67/kF+SL4Rvd09qr17PQ49JHz9vJo8ufxdfES8b3wePBC8B3wB/AB8AvwJvBQ8Ivw1PAt8ZXxC/KQ8iLzwPNs9CP15PWw9ob3ZPhJ+TX6J/se/Bn9Fv4W",
  b"/xcAFwEXAhQDDgQFBfYF4QbFB6EIdQk/Cv8KtAtdDPkMiQ0LDn8O5A46D4EPuA/gD/gP/w/3D94PtQ99DzUP3g54DgMOgA3wDFIMqAvzCjIKZwmTCLYH0QbmBfUE/gMEAwYCBwEGAAb/Bv4I/Q78F/sl+jr5VPh396P22PUX9WD0tvMY84fy",
  b"A/KO8Sfxz/CG8E3wJPAK8AHwCPAe8EXwfPDC8BjxfPHv8XHy//Kb80T0+PS49YH2VPcw+BT5//nv+uX74Pzd/dz+3f/dAN0B2wLWA80EwAWrBpEHcAhFCRIK1AqMCzcM1wxpDe8NZg7ODigPcg+tD9gP9A//D/oP5Q/AD4sPRw/zDpAOHw6f",
  b"DRENdwzQCx0LXwqWCcQI6QcGBxwGLAU3BD0DQAJBAUAAQP9A/kL9RvxP+1z6b/mI+Kn30vYF9kH1ifTb8zrzpvIg8qfxPfHh8JXwWfAs8A/wAvAF8BjwO/Bu8LHwA/Fk8dTxUvLe8nfzHPTO9Iv1UvYk9/734PjJ+bn6rfun/KP9ov6j/6MA",
  b"owGhAp0DlQSIBXYGXgc+CBYJ5AmpCmMLEgy0DEkN0g1MDrgOFQ9jD6EP0A/vD/4P/A/rD8oPmQ9YDwcPqA45Dr0NMw2bDPcLRwuLCsUJ9QgcCDoHUgZjBW8EdgN5AnsBewB7/3r+fP2A/If7k/qk+bz42/cC9zP2bfWx9AL0XvPH8j7ywvFU",
  b"8fXwpfBl8DXwFPAD8APwEvAy8GHwoPDv8EzxufE08r3yU/P286X0X/Uk9vP2y/es+JT5gvp2+238af1o/mj/aABpAWgCZANdBFIFQQYqBwwI5gi2CX0KOQvrC5AMKA20DTEOoA4BD1IPlA/HD+kP/A/+D/AP0w+lD2gPGw+/DlQO2w1UDb8M",
  b"HQxwC7YK8gkkCU0IbgeHBpoFpwSvA7QCtQG1ALX/tP61/bj8v/vK+tr58PgN+DP3YfaZ9dv0KfSC8+jyW/Lc8WvxCfG28HLwPvAa8AbwAfAN8CnwVfCQ8NzwNvGf8RfynPIw89DzfPQ09ff1xPaa93j4XvlL+j37Nfww/S7+Lv8uAC8BLgIr",
  b"AyUEGwULBvYG2Qe0CIcJUQoQC8QLbAwHDZUNFg6JDuwOQQ+HD70P4w/5D/8P9Q/bD7EPdw8uD9UObg73DXMN4gxDDJgL4QogClUJgAiiB70G0AXfBOgD7QLvAe8A7//u/u/98fz3+wH7EPol+UH4ZPeQ9sb1BfVQ9KfzCvN68vjxhPEe8cjw",
  b"gPBJ8CHwCfAB8AnwIfBK8ILwyfAg8Ybx+vF98g3zqvNT9An1yfWU9mj3Rfgp+RX6Bvv8+/f89P30/vT/9QD0AfEC7APjBNUFwQamB4MIWAkkCuUKnAtHDOUMdg36DXAO1w4vD3gPsg/bD/UP/w/5D+IPvA+FD0AP6g6GDhMOkw0EDWkMwAsM",
  b"C00KhAmwCNUH8QYGBhYFIAQmAykCKQEqACn/Kf4r/TD8OftG+lr5dPiV97/28/Uw9Xj0zPMs85ryFPKd8TTx2vCP8FTwKPAN8AHwBvAa8D/wdPC48AvxbfHf8V7y6/KF8yz03/Sd9WX2N/cS+PX43/nP+sT7vvy6/bn+uf+6ALoBuAK0A6wE",
  b"nwWMBnMHUggpCfcJuwp0CyAMwgxWDd0NVg7BDh0PaQ+mD9MP8Q/+D/wP6Q/GD5MPUQ//Dp4OLw6xDSYNjQzoCzYLeQqyCeEIBwglBzwGTQVZBGADYwJkAWQAY/9j/mT9afxw+336j/mn+Mf37/Yh9lz1ofTz81DzuvIy8rfxS/Ht8J/wYPAx",
  b"8BLwA/AD8BTwNfBm8Kfw9/BW8cTxQPLK8mHzBfS19HH1N/YH9+D3wPip+Zf6i/uE/ID9f/5//4AAgAF/AnsDdARoBVcGPwcgCPkIyAmPCkoL+gueDDYNwA08DqoOCQ9ZD5oPyw/sD/0P/g/uD88PoA9hDxMPtg5KDs8NRg2xDA4MXwulCuAJ",
  b"Egk6CFoHcgaEBZEEmAOcAp4BngCd/53+nv2h/Kj7s/rF+dz4+vcg90/2h/XL9Bn0dPPb8k/y0fFi8QHxr/Bt8DrwF/AF8ALwD/As8Frwl/Dj8D/xqvEi8qnyPvPf84z0RfUJ9tb2rfeN+HP5YfpU+0v8R/1F/kX/RgBGAUUCQQM7BDEFIQYK",
  b"B+0HyAiaCWMKIQvTC3oMFQ2iDSEOkg71DkgPjA/BD+UP+g//D/MP2A+sD3EPJg/MDmMO7A1nDdQMNAyIC9EKDgpBCWsIjQenBroFyATRA9YC2AHYANf/1/7Y/dv84fvr+vr5EPks+FD3ffaz9fT0QPSY8/zybvLt8XrxFvHB8HvwRPAe8Afw",
  b"AfAL8CTwTvCH8NHwKfGQ8QXyifIb87nzZPQa9dv1p/Z891n4Pvkq+hz7E/wO/Qv+Cv8LAAwBCwIJAwME+QTrBdYGuweXCGwJNgr3CqwLVQzyDIMNBQ56DuAONw9+D7YP3w/3D/8P9w/fD7cPgA85D+IOfQ4JDoYN9gxaDLAL+wo7CnEJnQjA",
  b"B9wG8QX/BAoEDwMSAhMBEgAR/xL+FP0Z/CL7MPpE+V/4gfes9uD1H/Vo9L3zH/ON8gnyk/Er8dPwifBP8CXwC/AB8AfwHfBD8HnwvvAT8Xfx6vFq8vnylPM89PD0r/V49kv3J/gJ+fT55Pra+9T80f3Q/tH/0QDRAc8CywPCBLUFoQaIB2YI",
  b"PAkJCssKgwswDNAMYw3pDWAOyg4kD28Pqw/XD/MP/w/6D+YPwg+OD0oP9w6VDiQOpQ0YDX4M2AslC2cKnwnOCPMHEQcnBjcFQgRIA0wCTQFMAEv/S/5N/VL8Wvtn+nr5k/iz99z2DvZK9ZH04/NC863yJvKs8UHx5fCY8FvwLfAQ8ALwBPAX",
  b"8Dnwa/Ct8P/wX/HO8Uzy1/Jw8xX0xvSC9Un2Gvfz99X4vvmt+qL7m/yY/Zb+l/+YAJgBlgKSA4oEfQVsBlMHNAgMCdsJoApbCwoMrQxDDcwNRw6zDhEPXw+fD84P7g/9D/0P7A/MD5sPWw8LD6wOPw7DDTkNowz/C08LlArOCf4IJghFB1wG",
  b"bgV6BIEDhQKGAYYAhf+G/of9i/yS+576r/nH+OX3DPc89nX1uvQJ9GXzzfJD8sfxWfH58KnwaPA28BXwBPAC8BHwMPBf8J3w6/BI8bTxLvK28kzz7vOc9Fb1G/bq9sH3ofiJ+Xf6avti/F79Xf5c/10AXQFcAlkDUgRHBTYGIAcCCNwIrQl1",
  b"CjEL4wuJDCINrg0sDpwO/Q5PD5IPxQ/oD/sP/g/xD9QPpw9rDx8PxA5ZDuENWg3GDCUMeAu/CvwJLglXCHgHkgalBbIEuwO/AsEBwQDA/8D+wf3E/Mr71frl+fr4GPg892r2ofXk9DH0ivPv8mLy4vFw8Q3xuvB18EDwG/AG8AHwDPAo8FLw",
  b"jfDY8DHxmvER8pbyKfPI83T0K/Xu9br2kPdu+FT5QPoy+yn8JP0i/iL/IwAjASICIAMaBBAFAQbrBs8Hqwh+CUgKBwu8C2QMAA2PDRAOhA7oDj4PhA+7D+EP+A//D/YP3A+zD3oPMQ/ZDnMO/Q16DekMSwygC+oKKQpeCYoIrAfHBtsF6gTz",
  b"A/gC+wH7APv/+v76/f38AvwM+xr6MPlL+G73mvbP9Q71WPSu8xHzgPL+8YnxIvHL8IPwS/Ai8ArwAfAI8CDwR/B/8MbwHPGB8fXxd/IG86PzTPQB9cD1ivZe9zr4H/kK+vv68fvr/Oj96P7o/+kA6QHmAuED2ATKBbYGnAd6CE8JGwrdCpQL",
  b"PwzeDHAN9A1rDtMOLA91D7AP2g/0D/8P+Q/kD74PiA9DD+8Oiw4ZDpkNCw1vDMgLFQtWCo0JugjfB/wGEQYhBSsEMQM0AjUBNQA0/zT+N/07/ET7Ufpk+X74n/fJ9vz1OfWA9NTzM/Og8hryovE58d7wkvBW8CrwDvAB8AXwGfA98HHwtPAH",
  b"8Wnx2fFY8uTyfvMk9Nb0lPVc9i33CPjq+NT5xPq5+7L8r/2u/q7/rgCuAa0CqAOgBJQFgQZoB0gIHwnuCbIKawsZDLsMUA3XDVEOvA4ZD2YPpA/SD/AP/g/8D+oPyA+WD1QPAw+jDjQOtw0sDZQM7ws+C4IKuwnrCBEIMAdHBlgFYwRqA28C",
  b"cAFwAG//b/5w/XT8fPuI+pn5sfjR9/n2KfZk9an0+vNX88HyN/K88U/x8fCi8GLwM/AT8APwA/AT8DTwZPCj8PPwUfG+8Tryw/Ja8/3zrfRo9S72/fbW97b4nvmM+oD7efx1/XP+c/90AHQBcwJwA2kEXQVMBjUHFgjvCL8JhgpCC/ILlwwv",
  b"DboNNw6lDgUPVg+XD8kP6g/8D/4P7w/RD6MPZQ8XD7oOTw7VDU0NuAwWDGgLrgrpCRsJQwhkB30GjwWcBKQDqAKqAaoAqf+o/qn9rfyz+7/6z/nl+AT4KfdY9pD10/Qh9Hvz4fJV8tfxZ/EF8bPwcPA88BnwBfAC8A7wK/BX8JTw3/A68aTx",
  b"HfKj8jfz1/OE9D31//XN9qP3gvhp+Vb6SPtA/Dv9Of45/zoAOwE6AjcDMQQlBRYGAAfjB74IkQlaChgLywtzDA4NnA0cDo0O8Q5FD4oPvw/kD/oP/w/0D9kPrw90DyoP0Q5oDvINbQ3bDDsMkQvZChcKSwl2CJcHsgbFBdME3APhAuMB5ADj",
  b"/+L+4/3n/Oz79voF+hr5Nvha94f2vfX99Ej0n/MD83Ty8vF/8RrxxPB+8EfwH/AI8AHwCvAj8EzwhfDN8CTxi/EA8oPyFPOx81z0EfXS9Z32cvdP+DT5IPoR+wj8Av0A/v/+AAAAAf8B/QL4A+4E4AXMBrAHjQhiCS0K7gqkC04M7Ax8Df8N",
  b"dQ7bDjMPew+0D90P9g//D/gP4Q+6D4MPPA/mDoIODg6NDf0MYQy4CwQLRAp6CacIygfmBvwFCwUVBBoDHgIeAR4AHf8d/iD9Jfwt+zv6T/lp+Iv3tfbp9Sf1cPTF8ybzk/IP8pjxMPHW8IzwUvAn8AzwAfAG8BzwQfB28LvwD/Fy8eTxZPLy",
  b"8o3zNPTn9Kb1b/ZB9xz4//jq+dr6z/vI/MX9xf7F/8YAxgHEAr8DtwSqBZcGfQdcCDMJAArDCnsLKAzJDF0N4w1bDsUOIA9sD6kP1Q/yD/4P+w/nD8QPkQ9OD/sOmg4qDqsNHw2GDOALLQtwCqkJ1wj9BxsHMgZCBU0EVANXAlgBWABX/1f+",
  b"Wf1d/GX7cvqE+Z34vffm9hf2U/WZ9OvzSfOz8izysvFG8enwnPBd8C/wEfAC8ATwFfA38GnwqvD78FvxyfFG8tDyaPMN9L70evVA9hD36ffL+LP5ovqX+5D8jP2L/ov/jACMAYsChwN/BHMFYQZJByoIAgnSCZcKUwsCDKYMPA3GDUEOrw4N",
  b"D1wPnA/MD+0P/Q/9D+0PzQ+eD14PDw+xDkQOyQ1ADakMBgxYC50K1wkICTAITwdnBnkFhQSNA5ECkgGSAJH/kf6S/Zb8nvup+rr50fjv9xb3RfZ/9cL0EfRs89TySfLM8V3x/fCs8GrwOPAW8ATwAvAQ8C7wXPCa8OfwQ/Gv8SjysPJE8+bz",
  b"lPRO9RL24Pa395f4fvls+l/7V/xT/VH+Uf9SAFEBUAJNA0cEPAUrBhUH+AfSCKQJbAopC9sLggwbDagNJg6XDvkOTA+PD8MP5w/7D/8P8g/WD6oPbg8iD8gOXg7nDWENzQwtDIALyAoFCjgJYgiDB5wGsAW9BMUDygLNAc0AzP/M/sz90PzW",
  b"++D67/kF+SL4Rvd09qr17PQ49JHz9vJo8ufxdfES8b3wePBC8B3wB/AB8AvwJvBQ8Ivw1PAt8ZXxC/KQ8iLzwPNs9CP15PWw9ob3ZPhJ+TX6J/se/Bn9Fv4W/xcAFwEXAhQDDgQFBfYF4QbFB6EIdQk/Cv8KtAtdDPkMiQ0LDn8O5A46D4EP",
  b"uA/gD/gP/w/3D94PtQ99DzUP3g54DgMOgA3wDFIMqAvzCjIKZwmTCLYH0QbmBfUE/gMEAwYCBwEGAAb/Bv4I/Q78F/sl+jr5VPh396P22PUX9WD0tvMY84fyA/KO8Sfxz/CG8E3wJPAK8AHwCPAe8EXwfPDC8BjxfPHv8XHy//Kb80T0+PS4",
  b"9YH2VPcw+BT5//nv+uX74Pzd/dz+3f/dAN0B2wLWA80EwAWrBpEHcAhFCRIK1AqMCzcM1wxpDe8NZg7ODigPcg+tD9gP9A//D/oP5Q/AD4sPRw/zDpAOHw6fDRENdwzQCx0LXwqWCcQI6QcGBxwGLAU3BD0DQAJBAUAAQP9A/kL9RvxP+1z6",
  b"b/mI+Kn30vYF9kH1ifTb8zrzpvIg8qfxPfHh8JXwWfAs8A/wAvAF8BjwO/Bu8LHwA/Fk8dTxUvLe8nfzHPTO9Iv1UvYk9/734PjJ+bn6rfun/KP9ov6j/6MAowGhAp0DlQSIBXYGXgc+CBYJ5AmpCmMLEgy0DEkN0g1MDrgOFQ9jD6EP0A/v",
  b"D/4P/A/rD8oPmQ9YDwcPqA45Dr0NMw2bDPcLRwuLCsUJ9QgcCDoHUgZjBW8EdgN5AnsBewB7/3r+fP2A/If7k/qk+bz42/cC9zP2bfWx9AL0XvPH8j7ywvFU8fXwpfBl8DXwFPAD8APwEvAy8GHwoPDv8EzxufE08r3yU/P286X0X/Uk9vP2",
  b"y/es+JT5gvp2+238af1o/mj/aABpAWgCZANdBFIFQQYqBwwI5gi2CX0KOQvrC5AMKA20DTEOoA4BD1IPlA/HD+kP/A/+D/AP0w+lD2gPGw+/DlQO2w1UDb8MHQxwC7YK8gkkCU0IbgeHBpoFpwSvA7QCtQG1ALX/tP61/bj8v/vK+tr58PgN",
  b"+DP3YfaZ9dv0KfSC8+jyW/Lc8WvxCfG28HLwPvAa8AbwAfAN8CnwVfCQ8NzwNvGf8RfynPIw89DzfPQ09ff1xPaa93j4XvlL+j37Nfww/S7+Lv8uAC8BLgIrAyUEGwULBvYG2Qe0CIcJUQoQC8QLbAwHDZUNFg6JDuwOQQ+HD70P4w/5D/8P",
  b"9Q/bD7EPdw8uD9UObg73DXMN4gxDDJgL4QogClUJgAiiB70G0AXfBOgD7QLvAe8A7//u/u/98fz3+wH7EPol+UH4ZPeQ9sb1BfVQ9KfzCvN68vjxhPEe8cjwgPBJ8CHwCfAB8AnwIfBK8ILwyfAg8Ybx+vF98g3zqvNT9An1yfWU9mj3Rfgp",
  b"+RX6Bvv8+/f89P30/vT/9QD0AfEC7APjBNUFwQamB4MIWAkkCuUKnAtHDOUMdg36DXAO1w4vD3gPsg/bD/UP/w/5D+IPvA+FD0AP6g6GDhMOkw0EDWkMwAsMC00KhAmwCNUH8QYGBhYFIAQmAykCKQEqACn/Kf4r/TD8OftG+lr5dPiV97/2",
  b"8/Uw9Xj0zPMs85ryFPKd8TTx2vCP8FTwKPAN8AHwBvAa8D/wdPC48AvxbfHf8V7y6/KF8yz03/Sd9WX2N/cS+PX43/nP+sT7vvy6/bn+uf+6ALoBuAK0A6wEnwWMBnMHUggpCfcJuwp0CyAMwgxWDd0NVg7BDh0PaQ+mD9MP8Q/+D/wP6Q/G",
  b"D5MPUQ//Dp4OLw6xDSYNjQzoCzYLeQqyCeEIBwglBzwGTQVZBGADYwJkAWQAY/9j/mT9afxw+336j/mn+Mf37/Yh9lz1ofTz81DzuvIy8rfxS/Ht8J/wYPAx8BLwA/AD8BTwNfBm8Kfw9/BW8cTxQPLK8mHzBfS19HH1N/YH9+D3wPip+Zf6",
  b"i/uE/ID9f/5//4AAgAF/AnsDdARoBVcGPwcgCPkIyAmPCkoL+gueDDYNwA08DqoOCQ9ZD5oPyw/sD/0P/g/uD88PoA9hDxMPtg5KDs8NRg2xDA4MXwulCuAJEgk6CFoHcgaEBZEEmAOcAp4BngCd/53+nv2h/Kj7s/rF+dz4+vcg90/2h/XL",
  b"9Bn0dPPb8k/y0fFi8QHxr/Bt8DrwF/AF8ALwD/As8Frwl/Dj8D/xqvEi8qnyPvPf84z0RfUJ9tb2rfeN+HP5YfpU+0v8R/1F/kX/RgBGAUUCQQM7BDEFIQYKB+0HyAiaCWMKIQvTC3oMFQ2iDSEOkg71DkgPjA/BD+UP+g//D/MP2A+sD3EP",
  b"Jg/MDmMO7A1nDdQMNAyIC9EKDgpBCWsIjQenBroFyATRA9YC2AHYANf/1/7Y/dv84fvr+vr5EPks+FD3ffaz9fT0QPSY8/zybvLt8XrxFvHB8HvwRPAe8AfwAfAL8CTwTvCH8NHwKfGQ8QXyifIb87nzZPQa9dv1p/Z891n4Pvkq+hz7E/wO",
  b"/Qv+Cv8LAAwBCwIJAwME+QTrBdYGuweXCGwJNgr3CqwLVQzyDIMNBQ56DuAONw9+D7YP3w/3D/8P9w/fD7cPgA85D+IOfQ4JDoYN9gxaDLAL+wo7CnEJnQjAB9wG8QX/BAoEDwMSAhMBEgAR/xL+FP0Z/CL7MPpE+V/4gfes9uD1H/Vo9L3z",
  b"H/ON8gnyk/Er8dPwifBP8CXwC/AB8AfwHfBD8HnwvvAT8Xfx6vFq8vnylPM89PD0r/V49kv3J/gJ+fT55Pra+9T80f3Q/tH/0QDRAc8CywPCBLUFoQaIB2YIPAkJCssKgwswDNAMYw3pDWAOyg4kD28Pqw/XD/MP/w/6D+YPwg+OD0oP9w6V",
  b"DiQOpQ0YDX4M2AslC2cKnwnOCPMHEQcnBjcFQgRIA0wCTQFMAEv/S/5N/VL8Wvtn+nr5k/iz99z2DvZK9ZH04/NC863yJvKs8UHx5fCY8FvwLfAQ8ALwBPAX8Dnwa/Ct8P/wX/HO8Uzy1/Jw8xX0xvSC9Un2Gvfz99X4vvmt+qL7m/yY/Zb+",
  b"l/+YAJgBlgKSA4oEfQVsBlMHNAgMCdsJoApbCwoMrQxDDcwNRw6zDhEPXw+fD84P7g/9D/0P7A/MD5sPWw8LD6wOPw7DDTkNowz/C08LlArOCf4IJghFB1wGbgV6BIEDhQKGAYYAhf+G/of9i/yS+576r/nH+OX3DPc89nX1uvQJ9GXzzfJD",
  b"8sfxWfH58KnwaPA28BXwBPAC8BHwMPBf8J3w6/BI8bTxLvK28kzz7vOc9Fb1G/bq9sH3ofiJ+Xf6avti/F79Xf5c/10AXQFcAlkDUgRHBTYGIAcCCNwIrQl1CjEL4wuJDCINrg0sDpwO/Q5PD5IPxQ/oD/sP/g/xD9QPpw9rDx8PxA5ZDuEN",
  b"Wg3GDCUMeAu/CvwJLglXCHgHkgalBbIEuwO/AsEBwQDA/8D+wf3E/Mr71frl+fr4GPg892r2ofXk9DH0ivPv8mLy4vFw8Q3xuvB18EDwG/AG8AHwDPAo8FLwjfDY8DHxmvER8pbyKfPI83T0K/Xu9br2kPdu+FT5QPoy+yn8JP0i/iL/IwAj",
  b"ASICIAMaBBAFAQbrBs8Hqwh+CUgKBwu8C2QMAA2PDRAOhA7oDj4PhA+7D+EP+A//D/YP3A+zD3oPMQ/ZDnMO/Q16DekMSwygC+oKKQpeCYoIrAfHBtsF6gTzA/gC+wH7APv/+v76/f38AvwM+xr6MPlL+G73mvbP9Q71WPSu8xHzgPL+8Ynx",
  b"IvHL8IPwS/Ai8ArwAfAI8CDwR/B/8MbwHPGB8fXxd/IG86PzTPQB9cD1ivZe9zr4H/kK+vv68fvr/Oj96P7o/+kA6QHmAuED2ATKBbYGnAd6CE8JGwrdCpQLPwzeDHAN9A1rDtMOLA91D7AP2g/0D/8P+Q/kD74PiA9DD+8Oiw4ZDpkNCw1v",
  b"DMgLFQtWCo0JugjfB/wGEQYhBSsEMQM0AjUBNQA0/zT+N/07/ET7Ufpk+X74n/fJ9vz1OfWA9NTzM/Og8hryovE58d7wkvBW8CrwDvAB8AXwGfA98HHwtPAH8Wnx2fFY8uTyfvMk9Nb0lPVc9i33CPjq+NT5xPq5+7L8r/2u/q7/rgCuAa0C",
  b"qAOgBJQFgQZoB0gIHwnuCbIKawsZDLsMUA3XDVEOvA4ZD2YPpA/SD/AP/g/8D+oPyA+WD1QPAw+jDjQOtw0sDZQM7ws+C4IKuwnrCBEIMAdHBlgFYwRqA28CcAFwAG//b/5w/XT8fPuI+pn5sfjR9/n2KfZk9an0+vNX88HyN/K88U/x8fCi",
  b"8GLwM/AT8APwA/AT8DTwZPCj8PPwUfG+8Tryw/Ja8/3zrfRo9S72/fbW97b4nvmM+oD7efx1/XP+c/90AHQBcwJwA2kEXQVMBjUHFgjvCL8JhgpCC/ILlwwvDboNNw6lDgUPVg+XD8kP6g/8D/4P7w/RD6MPZQ8XD7oOTw7VDU0NuAwWDGgL",
  b"rgrpCRsJQwhkB30GjwWcBKQDqAKqAaoAqf+o/qn9rfyz+7/6z/nl+AT4KfdY9pD10/Qh9Hvz4fJV8tfxZ/EF8bPwcPA88BnwBfAC8A7wK/BX8JTw3/A68aTxHfKj8jfz1/OE9D31//XN9qP3gvhp+Vb6SPtA/Dv9Of45/zoAOwE6AjcDMQQl",
  b"BRYGAAfjB74IkQlaChgLywtzDA4NnA0cDo0O8Q5FD4oPvw/kD/oP/w/0D9kPrw90DyoP0Q5oDvINbQ3bDDsMkQvZChcKSwl2CJcHsgbFBdME3APhAuMB5ADj/+L+4/3n/Oz79voF+hr5Nvha94f2vfX99Ej0n/MD83Ty8vF/8RrxxPB+8Efw",
  b"H/AI8AHwCvAj8EzwhfDN8CTxi/EA8oPyFPOx81z0EfXS9Z32cvdP+DT5IPoR+wj8Av0A/v/+",
])

///|
fn wavtags_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
fn wavtags_data(wav : @libavformat.WavDemux, bytes : Bytes) -> Bytes {
  let start = wav.data_offset.to_int()
  let end = start + wav.data_size.to_int()
  bytes[start:end].to_owned()
}

///|
test "wav tags: reads ffmpeg LIST/INFO" {
  let data = @libavutil.av_base64_decode(wavtags_b64, 100000).unwrap()
  let tags = @libavformat.wav_read_tags(data).unwrap()
  assert_eq(tags.length(), 5)
  assert_eq(wavtags_find(tags, "artist"), "Wav Artist")
  assert_eq(wavtags_find(tags, "title"), "Wav Title")
  assert_eq(wavtags_find(tags, "album"), "Wav Album")
  assert_eq(wavtags_find(tags, "track"), "5")
  assert_eq(wavtags_find(tags, "encoder"), "Lavf63.1.102")
}

///|
test "wav tags: writer replaces tags and keeps the data chunk" {
  let data = @libavutil.av_base64_decode(wavtags_b64, 100000).unwrap()
  let plain = @libavformat.av_wav_open(data).unwrap()
  let pcm = wavtags_data(plain, data)
  let out = @libavformat.wav_add_tags(data, [
    ("title", "New"),
    ("artist", "Up"),
    ("track", "7"),
    ("custom key", "ignored"),
  ]).unwrap()
  let tags = @libavformat.wav_read_tags(out).unwrap()
  assert_eq(tags.length(), 3)
  assert_eq(wavtags_find(tags, "title"), "New")
  assert_eq(wavtags_find(tags, "artist"), "Up")
  assert_eq(wavtags_find(tags, "track"), "7")
  assert_eq(wavtags_find(tags, "album"), "")
  let rew = @libavformat.av_wav_open(out).unwrap()
  assert_eq(wavtags_data(rew, out), pcm)
  // Removing tags drops the LIST chunk but keeps the audio intact.
  let bare = @libavformat.wav_add_tags(out, []).unwrap()
  assert_eq(@libavformat.wav_read_tags(bare).unwrap().length(), 0)
  let rew2 = @libavformat.av_wav_open(bare).unwrap()
  assert_eq(wavtags_data(rew2, bare), pcm)
  // Adding tags to a LIST-less file inserts the chunk after fmt.
  let again = @libavformat.wav_add_tags(bare, [("title", "Again")]).unwrap()
  assert_eq(
    wavtags_find(@libavformat.wav_read_tags(again).unwrap(), "title"),
    "Again",
  )
  assert_eq(wavtags_data(@libavformat.av_wav_open(again).unwrap(), again), pcm)
}

///|
test "wav tags: our writer output and RF64 accept tags" {
  let mux = @libavformat.wav_muxer_new(48000, 1, 16).unwrap()
  for i = 0; i < 100; i = i + 1 {
    let sample : Int32 = i * 7
    mux.write_samples([sample])
  }
  let plain = mux.finish()
  let tagged = @libavformat.wav_add_tags(plain, [("title", "Muxed")]).unwrap()
  assert_eq(
    wavtags_find(@libavformat.wav_read_tags(tagged).unwrap(), "title"),
    "Muxed",
  )
  let a = @libavformat.av_wav_open(plain).unwrap()
  let b = @libavformat.av_wav_open(tagged).unwrap()
  assert_eq(wavtags_data(b, tagged), wavtags_data(a, plain))
  let rf64 = @libavformat.wav_muxer_new(48000, 1, 16, rf64=true).unwrap()
  for i = 0; i < 100; i = i + 1 {
    let sample : Int32 = i * 7
    rf64.write_samples([sample])
  }
  let rf = rf64.finish()
  let rft = @libavformat.wav_add_tags(rf, [("artist", "RF64")]).unwrap()
  assert_eq(
    wavtags_find(@libavformat.wav_read_tags(rft).unwrap(), "artist"),
    "RF64",
  )
  let c = @libavformat.av_wav_open(rf).unwrap()
  let d = @libavformat.av_wav_open(rft).unwrap()
  assert_eq(wavtags_data(d, rft), wavtags_data(c, rf))
}

///|
test "wav tags: invalid input is rejected" {
  match @libavformat.wav_read_tags(b"not a wav file") {
    Ok(_) => fail("expected a non-RIFF file to be rejected")
    Err(_) => ()
  }
  match @libavformat.wav_add_tags(b"not a wav file", [("a", "b")]) {
    Ok(_) => fail("expected a non-RIFF file to be rejected")
    Err(_) => ()
  }
}
