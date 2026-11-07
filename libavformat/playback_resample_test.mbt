///|
/// Byte-level vectors for the resample facade (S338).  Source: a
/// deterministic 48 kHz mono two-tone WAV (4800 samples).  Reference:
/// data chunk of docker FFmpeg 9.0.2
/// `ffmpeg -i in48.wav -ar 8000 -c:a pcm_s16le ref8k.wav` (aresample
/// defaults: 32 taps, kaiser 9, exact rational, FLTP).

///|
let rate_in48_wav_b64 : Bytes = b"UklGRqQlAABXQVZFZm10IBAAAAABAAEAgLsAAAB3AQACABAAZGF0YYAlAADo6i4PYQS+JBQUgy3nFWwpzw3VH3EFMBtxBir1xhQY" +
  b"CV4s0CF3Q8I0UlB4OuFO6jIjQ4ElFQm7HNEFBSCpD2AvmSJhQ/E0ilH/PHRSyDZ1GFkmbAZ1FTb53A1L+KMTvAPVIiwUzDEoHzAJ" +
  b"Vh13AMUOBO76+p7bhOwM0+bqZtgx9rjnVNlc90Plrf3s5LH2XNh95gvHztaHu2TRRL2XrErMzr8u4aTTcPFj3qH1Bty/7Y3QNOGq" +
  b"xcisCcVJs6jS+MZ26lvgrwLk9JQRFP0ME934XN2b743VwOuP16b0Vuc8CskAAyUiGmQ6mikuFRkrthCVIqgGsxl2ARsagAjGJ7wb" +
  b"oj6wMz0n00VCM65K8zA/QlEk7zMQF0Iq5RKnLNobbQ3tLZUgcT/xLbhGGi7HPx4hsS53DjgdtgBu51n/zexuCq/7mxpvCm8lbA+N" +
  b"I7IGCRVY9LDTJeJ7xeHZN8Sh3/PPb+9S4ab/3u2bBjbupdJk4jbD4dFatDTHza/SyZa5vdm0zYjvceL70hXuD9iW7AjR9OFPxdzX" +
  b"W7/515HGRObj2vjQ1vS36dcJCvlqEtn6fQ4Z82sFbOumAXft1Nws/UzychbYDIUv5yGdPvkppj8AJZU2Whpg/34UFf/NGvwLQC0I" +
  b"Il9EfTejVaFCm1lsP5Ai4zFaE7wjyQixHlEKzSb3FxE4VyrTSPg2tSF6NiYa6CiFCMIVmPaXByTu6QU/88cQ9gEk86cQ9f2vFSz8" +
  b"Gg3b7QD7gdol6bDMUeHoy+S5NthOyjnqM9t89+jimvhx3Zvt2s7z3d3AdaY0vfmp5cfLuurce9GJ8oLjCP9s6Vv+MePKxjbYaL3w" +
  b"0im+wNoFzZnv6OX6CQv/Ux+nDnH6pxCo9v4IoO1OAcrpOwOA8rcSsgetK+AhohZ6NjklAD6rJWc48RsPLbURcSahEPErtBzWD+Mx" +
  b"FCZ0RnM2sVCDOZVMRy8oPjAfJC/FE5H7fhTjAmIhbRMQM4YjET+FKQc+dSEAMGoPyO4s/Vjgf/R/3nz5TOkwCGb5+BZaBDEczwIz" +
  b"5tb0fNTr4RzDodTZu3PUxMJv4eTTMPSO5YvUFe5/1nnpYMzE2529rs66tO3LJLmC19nKsr9k4inWPvV04+77huNq9lfaE+yR0V/n" +
  b"2dL3wSXiNNdg++LxwhRtB4QkVxCPJosM1h5mA0npWf/y6r4HEfqHHJESNjavKjpKqDgZUWk4ER3tLfEQ4iJ/CfUgIg4oLNcecUAv" +
  b"NBtUpkO+L9NFwSq4OnobzCmmC5gdAwWWHaML0CmNGzINGSuyGKIwPBcyKOMI4RUl9XUDlua3+rjkCdKb7+Dg5f/l7yMLdfX7CZjt" +
  b"e/xm3CDqoMvFrwnFTLCyzAy+nd6f0R7xieCD+mDjzPYm2kq8SswbsEzEPK6Xya66I9xl0Xz0oegTCKX2v+Fc99jcwO4J03bmxs4k" +
  b"6GzXvvfq7CsRvQf0/FYdtAwwJqQOPCK1BtQYjP5qFM3/XRxtDugCWSb5G9A9TC8PS2o1CUpJLrk+UCHRMv0YTQK7HJkMiSz7H/pA" +
  b"wTKQTzo74lBnNfhEViWUBcYUrvh5DQn4gRO1A+ciVBQHMnMfPDe2Hd0ALg9t7l77+9vW7FDTGeuF2Dj2pefWBgv30OQT/SvkxvVE" +
  b"1zbllMUl1aq5Us/8usvXksndvAPeP9DR7Yvaj/G71zzp08tD3IPAItV9v4ytvMzfwDPk8Nkf/C/uvwoi9gAMuPHWA1DoNM5c5CTQ" +
  b"Nu3l384CYfmiHc4SIDNoIsY7FiTPCcwbAAAwExr75xN4AushEBYnOWku3k/1QJwuQEa9LEI+jiBmMMATLCcJEAMqbhntOO8rzB7a" +
  b"PYwsg0UTLew+bCAmLhEO9ByQABgVaf/07KcK+fvxGs8K1CXVD/YjFgdnFav0qAFa4pzF6tkmxHPfps//7rzg6f727IgF9Ozm/sDg" +
  b"XsHUzxeyucQarebGcbZd1hvKtetk3mr8l+lZ06rn58uf3Me/I9JzueTRUsDd31bU+/cF7sjizQLn8TMLkPMlB7brAf794zX6COYe" +
  b"A8r19+osD6QFZyjhGrM3LSP7OHkeNTAiFAYnng5l+U4VrwYoKCYdsz8KM2hRnz7SVd4770zILngQEyFZBnccTQj+JFwWqDYdKchH" +
  b"GTazTus1vBmhKFwIthWm9rwHW+4xBpTzJhFbAkAhEBFa/g0WgfxgDRHuIvuM2hfphcwH4XvLBud812vJKun12Q72SOHH9mjbXOtk" +
  b"zEXb970J0du5ZaYYxMS2qdgCzdjtm97r+Rvk1/h93ZvuJdItt4zMn7cS1DbGrOjf3tkC1fcMGFAHwiA9CTnvjQEx5uX5aOLl+znr" +
  b"gQuRAKQk8xqHPcwvrx6cN3AfVjIOFlsnMQwgIYQLCicDGBE5oi0NIqdC3zJYTWM2r0mZLLI78RwbLfIRpCcQE6UBUyCKElYy9CKk" +
  b"Pjsp3D1nIQswjA+xHHL9reDd9OTe5fm16ZUIxflNF6IEaBz0AvQTyvRT1KThssIS1CO7lNO5wTXge9KV8r/jOgDb6w/U0OZ+yanY" +
  b"SLogy/Gw68fptA/TLcaE6Ezd3NC/78TdDvZ53TLw99OM5ebKk+Dvy6XoB9sA0Br0jepgDQQAFR3lCCAfIAVzFw/8sw8i+M/jtAAi" +
  b"87YV4AupL0gk+0OTMjFLsDI9RZgo0Av2HckEdxzdCRsoBBvYPM8w9lC6QL9aWEN+KKs4ohkoKDMKVhzwA64c5go6KR0bmTrrKqEY" +
  b"qzBdF2coKAk0FoP12QP/5iD7HeUcAPHvKuEdAAzwMwtr9dUJVO0V/NvbbunFynLc1MPnrhvLQ7yf3GvPsu7l3af3SuB8853WO+ZN" +
  b"yOWr3r+WqbnEm7Xc1urL0O7G4gsCcfAVCdnwMNb35yLMc9+qx/LgKNBq8InlwglPADYj5hVJBcweSwfxGn3/rxGA93gN+fioFdwH" +
  b"MSoWIOAV5DePKYNFEDDiRFgp/znNHIYu6xQpLBwZNAleKQodQj5BMEhNKDkFT74zgUMPJDAy2xPt998MlvcwE4QD1CJbFCYyph+A" +
  b"Nwge7i6SD9Xux/th3DbtqNNk68DYYPa3588G6fZBErD8o+MX9WzWM+RjxMTTGLiNzQK5m9Urx/PnLNsvzYfqB9fR7cPTC+Vpx6LX" +
  b"q7sU0Dq6ytUVxwi7Lt7A08b1r+caBFzvGgW36r38IOGl9AndxMjO5XfYXvvw8TYWaQvGKxwbizTvHHQw1xQq+XkMhfR5DTL8zhsg" +
  b"EGYz2Ch/Sso7WleAQTUo8jl3HIksHRDDI9kMDSexFmg2oSlpSvk73ioHRMgr0D19H2EtdA19HD0A5BRT/6saxAoq/DQbIAswJjgQ" +
  b"XiR/B80VDPUBAqbijPMU2jrEbt+Fz8DuXOBk/kvstAT067n9ZN+F7RPOIrCPwriqTMSfs1LT1sY26KzaePhr5an8DuMTx5XXiLqy" +
  b"zNCzEcxRurDZAM5+8WPntwns++nqGwRh7OX/ZOSj9pXcyPKX3q77Xu5EEdEHWP4qIbgTojA2HCEyvhedKbANuyB+CCMhiA8aAcQi" +
  b"9he4OkUu20xKOrZR+zdHSVkr9zoYHpYD7Rn7BeIidRT1NJ0neUb5NMBNIjXPRiYoBQh/FY32vgd27mAG1fN2EbYCoyF3EXcsdBbi" +
  b"/LoNXu5g+7jaLemDzOngP8up5vvWd/Za6PrY5vTw3z71rdls6T7K6dhiuzzO1bba0J7AEbO81NzIeekD2h31F9+e8xDY/OhXzOTe" +
  b"Y8ZNsZnNmL/r4QDY3vu/8N8QEQByGeABhRUh+sDedPL72n/03OMzBFT5eh3gE4027yilRQEx+hgILOkPYiFnBoYbHAbVIQQTSDQQ" +
  b"KWdLhT73LqlJ7zJ0Rpgp6zhiGsQq0Q+5JVkR1S3/HmURXzEnIgA+vSiCPS4h8C+ND8ocoP2fDiz1Pt9H+hzq/ggs+q8X/AS3HDMD" +
  b"IhTj9AcCieF5wrjTpbrw0uzAPt9W0UHxO+KE/vDpov955O/G4tVHt+XHfa08xAGx7c7TwfLjg9iR+YrqXNh08K/XOerSzT7fcMT4" +
  b"2THFyOEN1KH28OxP4xIGqPivFXgBrxew/QYQqPRWCNLwQwqI+Qzsug4BBegoqh2CPUEsCEWzLG8/+SIXNL0Yxv+pF0UFvCPeFus4" +
  b"HC18TXs9uVeLQJ1TTzZ8FzgmeAjNGpgChhvrCWoodRoYOo4qGUaNMFsXfShUCXIW0PUzBGDnh/uH5YMAVPA4D20ATfBiC4b11wk7" +
  b"7d77hNvz6CTKqdvhwnvbzMnDuuzahM2W7JPbHfWH3YHwaNPM4qXEttXCu0GlLMDWsOHRusZs6THdRvx86vUCjupy/V/hZ8WZ2LPA" +
  b"4dn/yC3pPN5nAur4yht1DowrXxfk/5MTK/huClHwYAb68cYOGAGPI5kZPj23MY4jsD9tKnE/GST1NPkX6imHEP0nKhUwM98lxRk3" +
  b"O28trkrGNttMyTHAQYIi1DCuEqAkCwzr9qsSJAOVIjoUITK6H6o3RB46L+sP6Rwt/Mrcnu0L1MDrEdmj9ujn7Abt9isSffwDEaD0" +
  b"z9Vu43TDqNLNthHMVLe60xTFpeWn2Cb4kefX02jqINAu4VLDUtMjt1TLRLWf0LbBK+Nt2NDNqe9o4a39x+hk/uDjyPUR2n7tztUs" +
  b"73TeEtHy84DqxQ77A14kvBM4LawVRCm9DdwfkwW/7dQGsvV1FfAJYS0BI9hEVDYXUnI8EVFRNQ0YWCglDAUgVQnDI6ETkTMDJwJI" +
  b"yTmYVkJCNipvPEweXiycDM4btv+BFBH/iRq9Cu8pXBtbC3smkBC+JOUHNhZ19WUCA+Pe81jaIfKN34zPre4r4BP+2OsaBDPrzvxM" +
  b"3j7snMwt3LLApqgEwh+xmtDlwwvlR9fZ9JPhl/jD3kTw29KXtYvHdq6FxpS0xNPnxzvr+OAmAzf1xxEq/VXlwPgr3VjvPNVk6yzX" +
  b"PvTt5tYJaACqJNYZdAxwKRoVHivXENQiCAc4GiEC7xqACfMoGB17EnE1Min9R6Q1SE3FM0pFliduN8gaNC4RF1cDdiBBEvcy1CXi" +
  b"RJQzi0wbNPRFdCcuNRkVSfaYB2zucAb8868RAAP5IdcR3CzdFv4qHg687rP7/dpi6aTM8uAuy3vmrtYH9sTn8AX+893e/PM62Mjn" +
  b"Zsjc1h+5wcsitO7Neb1l3SPRCcVs5b7Vn/Bh2rLu79Kn48/GK9l7wOzYWscxuV7bT9EN9dDp1Qnv+DsSmPotDr7yCAUF64nTEO1z" +
  b"3NL8//E0FqwMby/pIbs+NSoDQIEliQkqG1oAphVsAFYctw0wLy4ku0YSOnBYp0UmL+ZCQybQNYAXGyhhDX8jVQ8GLGQdsD0lMBwh" +
  b"IT0HKPM8xCCpL2QPvhyu/cQOY/U5DZz6e+pjCZX6GBhhBRUdiANoFBn1KQKU4R/wjdNbuoPSWsCE3nPQMvD94Bb9UOjP/XDiZPJs" +
  b"05m0/8RdquPAba0gy8y9sd8K1OD0o+XyACPrK9KF5O/HLdk1vpTTp74a2z7NtO/n5eEJ3f5h8VgOF/pFEEH2lQg57ewAcOnsAkHy" +
  b"iRKZB/n9+yHbFtQ2tyWkPngmXjkWHWMuORMoKIwSXgALH2USqjQVKa9J5zlgVGs9t1ChM7pC+SNvBvoY+AAYGq0IWyeSGV45/Cms" +
  b"RUMw5ERvKF8JlBYG9nkEtefl++zl7AC98J0PzABVHqoLvfX8CUnt0vtb26zouska2yvCnNrByD3ng9npy8fqj9nj8hfb2O2G0LHf" +
  b"UMEo0vm3887xu2OsNc3YwVTk5NfH9szkFv2B5Dr3/9qU7O7R57n30vnBD+II1yL7lfFoFAwHHSTtDygmKAzI8BYDCOkq/9fqvAcq" +
  b"+r4c6BKxNlArA0ubOYUkuDmRHqAv2BL+JNELfyPlECMvDCLgQ9c3SirCRxM0YEqGL7M/qiAwLzsRXiP4CrYj7hGOAiUi7RPzMakf" +
  b"szdlHm8vMBA8HYv84QoH7nTUJexx2fn2MuglBxT3OxJz/N0QXPQcA+PiwsLN0ca13MrvtSPSS8On43PWuvXt5K/+UufQzKXdj79V" +
  b"z+2y5saesMHLo7zk3fLS2PXO6WDbefdq4uH3ON3/7irTe+ayzvrnMNdy95HsF+NXB4v87hxRDNQlUw75IYQGtxiI/oAUAAD97uQO" +
  b"hQMeJ+gc7D6XMItMGDfqS2AwB0HVI9oH8xt9BSQgPBBmMBIkSkVJN1BUMEANVsY61RwXK4QL4xr1/ucTnv44GowK3CljGy45ribU" +
  b"EBAlQgiaFt31zgJp4z70sNps8sjfaP2/7iTg8f2W67cDq+of/HTdO+try8zaIL+V1ArA764zzkfBNOI31I/xD97Z9MvaE+xxzqre" +
  b"s8JoqULBHq8dzhDCNuXI2s78t+4iC2T2Igy/8RHWKOj5zRHkzM/W7H/fZQL4+D4dcRLOMiQi3w33I8gJ3xsxAIETjfuBFDkD1iIo" +
  b"F2464C/TI9JCrjCISD0v+kB/I5EzJRfLKuETFS65HbwPqTC9IwFD5jEPS9Ay2ESFJmk0fBSFI0UHOe5aBgD0zBExAzwiKBI4LUAX" +
  b"ZiuHDtUcFPxW267p4Mwc4ULLduaN1sj1ZOdrBVPzvAv88g3XbObZxhvVKreXycCxVMunulra3s0+77ThzNFz7P3VFuobzp3ekMG6" +
  b"09i6GdNZwbjgCNXSymvuDOPzAvDxIwtp8+wGbOur/Z3j0Pmf5QLVZvWZ6tkOXwUyKMAaqjc+Iyk5xh6lMLgUEPqGD3j6kBYiCMwp" +
  b"/h7AQU0141NSQb5YAz+bImEySxQgJZ4K9SADDeopfRv9O6UugU0BPBQnKjwjIC4vDQ+HHJX9xg5+9WgN3fp+GL4J+Pp/GMsFfB3p" +
  b"A8IUZvVnAsDhNfCL0/HnR9L9vwPey89i7wLg7vv45kb8teB08EbR8d9qwpCn3b0uqqbHGbrE2+TPgfAL4SX8H+am+hjfUMJf0zi4" +
  b"a81VuKHUoMbz6Ajf5QLH9+cXGQfH8ugI2u4oAcjlfPkD4of75Oo7C1sAgiToGuEP9y/5Hgk4AiAQM/EWaihvDY4iJA3dKAwanA0Y" +
  b"MLskjUX/NbFQ9zl8TaAw8z9qIcwx2RYO/2EYKQcHJm0YZzgvKQhFxS+KRDYo+DaVFh/2pwT05zT8RuZOASTxBhAzAbceBAy/IzsK" +
  b"d+3r+1zbkeiBycDarcH42fTHRuZe2En4Q+nY1/jw9tiB6/fN6txPvu3OhbREywm49dXbyEa9i9/l0pLxZN9897feQfHa1EbmeMsA" +
  b"4TnMHLsV2/XP+PNX6hoNsP+3HIAItx63BA4XsPur4dr3mOOPABTzwhUJDPAvsiSKREkzEEy7M8MYASprDcUfzQaxHk0MxCrmHfM/" +
  b"JDSEVINEDTGTR/EsVz2EHkAtgA/VIaAJjiLzEHIvfSFsE5YxbR+VN2MehS9cEHod2Pw7C2jujgKP7NjZXPeN6HUHVfdqEo783xBD" +
  b"9OUCjOL77yzR/bTpyc+01NDLwfThjNSe85viJfyP5In3cNogvK3LCq/KwkmsNMfet+nYws108DnkTQOE8UrclvHG1mfob8yh37vH" +
  b"6eAH0DXwROVvCfL/H/V9FeAEZx7rBpsaM/92EVn3aA0C+c4VIAjk/KEgkha/OJYquEZ1MXlGISv9OwEf8jCPF1EBMhyEDOcszSA/" +
  b"Qnc0tlHOPeNT0TjISIopKAq2GfX9ExPz/bMZLAqdKUIbKTnCJrI+TCWOCPMWPvY0A9LjpvQT28jyGeCr/fDu9A31/YDrhANY6qj7" +
  b"19x26nzKsNnVvRnTXL7C2hzM+b6v33rRme7f2nDxKNc26FrKWtorvlzSTLzzqb7If7x139jUsfZw6LQEz+9rBejq0PwZ4dLG1tyA" +
  b"yHzlGtj6+ojxzRUDC2YrxBpANLQcmALFFDH5mwzH9NwNuvx9HPgQaTQJKuBLXD1rK3pDZSpZPBUfYC8tEw0nXRDLKqkamToLLlYh" +
  b"0UDsL0pJPjF3Q1QlZjOkE9YivQaJGxgG3vPFEUMDZCJjEoMtmBfGK+0OPh19/G0JC+oyzWDhdcuV5pTWtfUz5xoF4PIiCzvy1QNU" +
  b"5ZLFpNOBtbrHrq8MySe4otftyhPsT97h+5vo69HL5ZjJ49mfvJPOfrWNzZy7zNrvzkPyAOh73D/8HOsxBF3syP8z5GD2RNxs8jTe" +
  b"Rvv17SvjcAf//d4gfBN4MCIcJjLfF9wpEA5AISkJRPSIEEcCICSDGXk8OjAFT6w8UFTNOlJMni7CENAhiAcZHl8KfidJGf853Czq" +
  b"S5w6k1MjO0gffC6CDiEcUf2gDnT1eA0E+7cYCAoBKd8YMAblHVIEJhXE9boCBeJq8KzT+uc20oPttt1bz8zuRd8G++XlBPtC39Du" +
  b"bs/k3SfAydIqu0KngcS5tivYEcx07Mbcp/dp4br199mv6tfNf7KDx0CyYs45wGbiV9gV/Njw3RD3/0MZnwGC58b5Xd4N8pHaGPR7" +
  b"49kDB/k8HbQTdzbxKA8YPTFXGYkskRAyImIHrhx0B14jvxQ4NjYrDyAaQcQxr0wuNu5JSy3YPIgeIy9pFIcqXRZaBWwkBBctNyQo" +
  b"KUQPL/tDzCexNmwWxiO1BBnoa/yO5qMBg/FrEJwBIB9pDB0kkApwGyH8ftuc6HPJldpjwYvZYseM5XvXOvcF6B0EWO8j13jpuMt0" +
  b"2qG7B8xlsevHdbQo0tTEueYS2zTOq+xH2ivyM9mN6/fONeA9xZzar8Ui4kbUCMnv7Dbj5AVp+GAVHgFNF0n9nQ9B9PQHePBB3En5" +
  b"3uuhDgAFAynjHdw9vyysRYAtZkAeJLcHQRp8AZQZZgcTJm0ZsjsdMLdQ70BoW3NECyqpOg4cASt3DQIgAAggIbUPYy6aIGZABDEA" +
  b"H0s3OB53L2cQnB0O/YELve7sAvTs9AfF9/Lo1Aeq97ISxfwEEVH02QJj4rTvwtAi4jPJ8LPJz5HAi+Dx0s/xl+Dr+R/i4PSO17nm" +
  b"WMh8qwG/R6j5wmuzPdTgyFzr7N7P/dTrHQSJ647QB+LoxfbY78D/2QHJF+kQ3ikCnfhwGxQOcv31Fn3/MBPQ9x4KEPAxBt/xxA4x" +
  b"AcYj8BkFEFgyVySjQI0rwECZJag24BkGLNkShyrtF3cIFCk0Hd8+UjHKThs7aFGONrtGsic4NkMYs/wAEgv99hiWCS0p9Rr7OLEm" +
  b"uz5tJXc2OBeR9pIDNuQP9XzbLfN54AH+Ou8tDhz+Qxl6AzLqZPtx3OvpysnV2M685NH3vCvZU8qv6nvdDs/16wPYWu7Y063kl8Zd" +
  b"1vW57s2mt8nSq8M4t/rZLM/W8Gjigf5y6en+QOQH9jLag+261U7BON7G0JnzH+pfDpID9iNZE9wsWxUBKYwNDPKPBdXtBwcF9uwV" +
  b"jQomLvAj9EWfN5NTID4+JWg3WxrdKuIO+yKFDCwnRBduNxorUkxRPqQtOEdhL85B3SMfMowS6yH8Be8apQVAIZQRMANrIoISti3c" +
  b"FxgsSg+iHeX81glx6kb7uOHAy9DmvNbH9Szn+ASe8r8Ks/EmA3zkQ/Jz0iC0KMbprRLH97U71U/IPOk/25f4F+Xh+9PhZ8V51f63" +
  b"u8lwsErIJrYl1RjJPuzQ4dUDv/V35Gz9d+XH+BndMO8B1Rnr1Nbe84fmbQkAAJP2eRkiDCwp5xT/KtAQ5yI5B4kalAKJG0EKK/ww" +
  b"HsIT6DbbKtpJtjeQT0U2AkiHKpk6LR4fBOkaaQfBJMQWsTfFKglK7jgXUtg54EuNLb0NhBva/E0OQfViDQj71Bg5CkQpMBlANEge" +
  b"ugSPFSr2GwNe4rbw6NMk6ErSfu2V3dD8bO7A3lv6EeUE+hXedO3hzSPcMr6f0Mi4XNKvwa6z5tSSyLzo1Nh78wXdHvEj1aXlmMjC" +
  b"2uDBbaxhyAy6ENza0XP1FOr7Cfn4KxJx+vQNdPL/1qXqJNOn7Arcbvyh8eEVZww6L8ghsj5GKn0SziX5CcAbFwGOFn8BmB0qD9Qw" +
  b"BibISFU8Ny1aSBIyC0ajKWk5UxsoLKYR/ScLFPIwhSJRFa011SYJQxwuMkMrJzY2FRaPI5wEzhWG/L3m5AHT8cYQ/wGHH9MMhCTx" +
  b"CsobbvxvCcjoicmT2kXBT9kFxwvl09Zq9grn9QIA7k0DvefIyU7YRblyyZiu5cQ2sa7OIcHM4uzWifcT6HnVJ+360yDmWMln2kC/" +
  b"c9Rdv6nbqM377xDmOtzP/jzxIQ7P+fAP4vUwCNDsgwAL6Y4C7PGQ5GMH1/3wIekW/zYBJhE/CicYOvkdci93FOP7LBQxAhQhpBQg" +
  b"N8MrlUwHPblX/0CEVKg3RxlyKCAL4R0VBmkfMQ4PLXUfbz83MBBMzTbeHT4vTBCdHSf9rwv87jsDTu1WCCz4Dhc7CAz4DBMU/UMR" +
  b"f/TyAmTime+J0MjhtcgA4fzOmr9m353RS/Dg3gD4/t+J8v/U8uNXxfXVjbuYpBG/Sa/jz07Ek+bt2Zr4bOaE/r/lSfji25q/gNJU" +
  b"ukHTJMId4v3WAPtf8SIUtwa/I4gPDPi/C2PwtwKz6OL+oOqXBxz6yhwRE/g2uiveHVE6ZCXDOssfCTFzFM0m1Q25JVUTzDHuJEcZ" +
  b"LDvYLYtLFTibTvkzX0SMJUg0iBbdKKgQ4/v7F8YIhSh0Gp44dSadPmsljTZkF4Ik3wOQ5HD149uX8+DgZP6V730OXf5yGZUD5xdL" +
  b"+zrclOlPyTTYBbzx0Ne73NfTyPzolNum+qPpedWX693QeOEow7XSErbSyVGzPM7mvvHfytTIyUHrotyM+FLjnvjO3W/vd9Op5sPO" +
  b"8ecP14nJTOzE4vkGJ/yFHOgLbyXzDaMhOgZ+GGH+veYJACPvKA/rA6knmh3HP54xwE19OIFNKTJRFQkmRgqXHlkIOiOME+8z1SdH" +
  b"SX87vljWRDct2T8cIpIwMBG+IPwEGxr6BLsgNBGlMEoifRLKLQYYVCyWD/sdRv08Ctrqrvsb4tD5Ief/1vj1Sef8BIjyiwpg8a8C" +
  b"3+N+8YTRuODdxG2sZMUWtCTTAca35oLYofXn4Xj4MN4+72LRrrMzxbCrVMP7sMbPh8N95uDbuf1477wL1/bA3vDxJNYh6NrN3uOI" +
  b"z4TsIt8BApD41RwLEroEzCGUDbwjoAnNGzgAoxPP++QUwQOFIwAYvQ0RMTQlZERzMoJKbTFhQx0maDY1GhUuZRcfBLEh7RMTNV4o" +
  b"2Uf0NlJQRjh/SlwsbjqsGiv8xQ3e9CAN5vrNGEsKbClrGYs0oB7OMvUVk/aEA8LiE/E61GjofdKd7Zzdvfw77iIM6Pl35EP5Kt1c" +
  b"7JrMrNqJvMLOtrYU0C+/qt710WfFV+U11aPv89jT7KDQ6+Cnw5vVhryV1KTCILT31ZfLCO+D40YDJPI5C2XzzwY762j9TOPAyzzl" +
  b"mtT99DPqeA4GBeYnhBqANyojLjnnHjADGBWV+jEQTPuQF08JKCuLIIFDQjcNVrRDpC3VQaYlpjXKF9gokA4hJWcRhi5RIAdB5DM+" +
  b"JaRB5ywrQlAmhDWKFSkjWASoFXz8gBQLAgzyEBFVAucfOA3tJFoLLhzM/MIJDely97TaTsE+2dfGvuRj1tT1TeYNAu3sCwJK5tj1" +
  b"dtY4ty/HHawywkquicvBvTPfGdN8887jr/5x6A7P/+ADxN/Uh7mLzki5atVBx27pX98cA+D3Mur+BpjypwiK7s0AZeUV+ZnhIPuD" +
  b"6uEKDgCR9rwayw/5LxcfRThfIJEzmRc6KWoOtiN8DrP8xxuMDz4yFyciSMw4t1M2PfZQUzTgQ5AldwhxG9sDZR1iDHQrDB41Piwv" +
  b"MUsXNgNL1C4FEHQdG/29CyHvcgOW7asIi/hzF6QIKCZxE3L9mBHF9CgDhuKk73vQneFryJPgas6U7IPejtAN73LdYPYr3oDwwNJ8" +
  b"4anCD9NtuPPOfbt8q9zLDcAa4jzVs/NP4TP5O+CV8v/VPedFzPCzt8x2u07bEND38z7q7Axx/2gcJghVHlAE8uhJ+0nhgPdJ41AA" +
  b"5vKpFQgMCzDrJORExzMAH4g0uhkmK78OSSGECJwgbg4bLXUgukIlNwsq90e8NHtLEzGxQRYjCTJ/FAonCA8oKL0WtweiJ7oZDDgI" +
  b"JlM+QCV/Nm8XpCQVBIkSxfVB3PzzSeHN/vrv3A6y/roZzAMMGFn74Qlr6QjJytd2uzvQ+LrR1pnHk+f52df4n+fyACfpNM6W3g3A" +
  b"YM+EsgnGT68BynO6Rdvoz2Ty9OUj19zyct2R8pbXD+nwzP7f98cH4QnQH/AY5X7bpf/F9BwVeQT9HYQGOBrY/iYRGPc5Def4Geg5" +
  b"CBv9+CANF2A5XyurR5UyyEehLLA96CBaBeEZ2wP1Hn8PHDA8JOdFWjjSVSNCcFiWPQ8gui6MD0sfugMIGRIE/h+eEDUw/SEDQLkt" +
  b"Dxh1LMsPQB6Z/ZoKPusX/ITiNfqB5wgFQvaC5yMFmPKCCjrxawJ54/Pw0tDd39bD7Nj/w3+yW9EDxIPkFtb98gvfYvXg2rXrn81l" +
  b"3f3AQqeuvh2ss8pAvgLhNNbe93DpiAV68PAFSOtbzzrh18bC3FbIQOXO16H6J/FnFZoK/iphGjAGYxxVApQUFPmXDN30Dw4N/fQc" +
  b"lREuNfgqSB+nPucsKEVGLHA+YyHlMeoVAyqNEzQuTB7CECIypiVZRaw0QE5pNtZI5SonOZQZ8ygEDUT0rQyV+pwYOApzKYoZvjTk" +
  b"HiAzUhaqJOwDK+N58ZrUwOjI0tjtxN3P/DTuAAym+ccRu/h73ITrl8t72Si7MM3xtBrO/7xD3FfPRPBH4uvRH+w11dvob8yB3Aa/" +
  b"w9B4t1LPLr0t3CDQksXY6Crdx/x/63MEf+zP/yHkOPYJ3CHy3N0yzY/twuI="

///|
let rate_ref8k_payload_b64 : Bytes = b"lgenIPYGDTdEMVMZ1EWBCHIX7QvK39vubdzkvl/qqcV73rwAqeGRIvYVIBzoPq4jfiWuNb75ahZY9KfTS/R0viPW+N9UzFz1t/+8" +
  b"9IQ0sBECLmw/txKCNp4SrvsRCYDd89UP6sW0b+gb2f/Ypw5V9VwZxS8QGdY5gzKIDiQ2vfQX/oT408eO5crPMcWO7QDawe7qGpf2" +
  b"Tjd+JQ4iD0KgF40bOBxm6P/51eQTwN7uwLsD3u3uC95ED68SbQ4VP4AgFSrWPdsAYiYR+iPlpPQMyy7PteN9vyXwhvH+6dcqkgaC" +
  b"LWI4pxxrNQ0kRP/PG1riBeOV7DO30+YA0DjUjP2b8L0G4i61CwQ/yC4EGWI8vwDLCsIAYdWa5QLZqbvR737J2eo9CevvNSsnIHIg" +
  b"uUB2IS8eBS5u7DQNpOazzdvrJr8z1pPnXtTCAM4Lx/4yP4cVvjLPOuoP6yo6CsvthP800wDQ1+c7tWTviN9Q5poXeQMWIOg42Blb" +
  b"On8skgbbKwboVfSo7HPDgN9j0xXHIfhU4gn8XiXbANo+HChQI5g7YxJ6DnkTFNpq8jTbuL3a7RPA2OUG+DbruxiDH2sTREYYHvso" +
  b"fjSP+OcZwe4E25brAchNzIXpnsO5/CD6OfhUM4AQfzHWORQazC0rHNjxnRLK1FDdeeRCuEDn7Nd93BEJsfymEFI5Og9jQ80p5RWN" +
  b"MDn45/xU91DL+N8n13y8G/cq0E74NRLz/bcx+yjfIOBAHRv2FZUjsN+LA//aoMko5h3Dbdhq8tvcFQ4sFtcIckbLF6EzADRoCqwd" +
  b"bgGN3yH43Mn+zTLn5rmC99Doi/MBIR4QzCS/PxEX6DjdIhT+TB/E3GLq3+PAwP3cjdmCy+kEBOs6CrIthQqBQjEpYSCsM0wK9QBP" +
  b"CqzM9+xs0ya/ou5OyFbupwNH94AitCmcFkZKwBiMJW8o6+8EDHXlMNFE5oPGfc0g8YjKTwoZAyQGmzkEGY8xnzlnE1UllxEW5REJ" +
  b"XsmN2SHfmLzO6QXjIeVqFvYGgBpFQCIR6EOoIh8QJSNj77/uJfBEwlDe4NZ/wX7/ntmWBYgbZwokNnkvuR0VPzQRSw32Fn7Ux/l+" +
  b"0kXHBOSgySPdY/+f5TgcVB47EsFJgRhYMMgrHAIQEE74TtLy8mrCys9V6G7CNgCK9Jb/nioNGqknY0NeESk1lRZV9W4Rm9PN4OLe" +
  b"n7+K3nnhptKdEvzzAxi7M7cSM0KeKGIZ9yqW/zL04QB6wYXpcc7Zw4Txp9Mf9wURcAEhLFgwKRhtSkcRgx/fGg3n9f183nHI+eSa" +
  b"xtbSxvkm1KIXVgxkErw9Jx8LLn03OAl9HOsE99l9/ybBi9dc3XPDzO4t8PXtfiTvDp0jPEN6EUVAKBqhB3YVUOas4TzrKrt64F7Y" +
  b"UspmCG7llxH8JBIUqji+MqsXCTu1BHIEIAl8y3Tw1c2Dxuzl29GA5DQNku7dKR4kGRoXSZEXCSnYIkj3TwMB71rH0e/NvdrUiesF" +
  b"ziAJ6QGgCQU0YSDZKCxDkQniLuEIc+x7A9vMXtjy3RXAOORi6mvc9x8g/Q0kjzd/GFE+JSbvDvUh4PIo6YL3jrnd5wrNC8vI9vvg" +
  b"AAAFHzgJ9TT2MiMYckZ+CNgWIA0L3hHx29mvwYHnccjz2+ACCeCVI54VyBvrPw4ioiclM4X8jRMf9x7Rb/bUvCfXn9/7y2D2F/7g" +
  b"9vsxdxQmKzNCLxCmOP8Qsfy4CCjd99Zv6Om25+Xi2yPWbhHM8oAbJS4UGn05KzKMD4Q04PaO+0v798RV6ELNVsfu6wTbae6SGpr3" +
  b"rjWiJ4Yf1kTEFFQesBmK6l742OW7v4buxLxj3BHxgtsLEtMPNBGNPKQidSjaPoMACSYV+4TjyPaDyPXR2eBEwpztqvNe6NorOgYq" +
  b"LWY5BxuPN4QhCwLzGCHlfeC57pO11+eoz9/TkP777uEIWSx8Dic8jzF7FoY+H//OC2oACdWe5mLXzb1J7UXM/ecEDGPtWi2HHnYh" +
  b"YUAeITMfZSyS7qsKa+nXyqLunbxX2PPlYtVqAHYLyv+SPasXNjCWPQ4Nsi2yB/Dv5P041KjPf+c/tsXtrOHI42EanQDdImA2+xu+" +
  b"OHotTAZeK0npUPJm7wzAf+PXzjfMHvKW6g=="

///|
/// Equal rate is the identity fast path: the stream comes back unchanged.
test "resample_to: equal rate returns the stream unchanged" {
  let data = @libavutil.av_base64_decode(rate_in48_wav_b64, 1 << 17).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  let same = audio.resample_to(48000)
  assert_eq(same.sample_rate(), 48000)
  assert_eq(same.channels(), 1)
  assert_eq(same.samples()[0].length(), 4800)
}

///|
/// 48k -> 8k through the facade must reproduce docker aresample: exactly
/// 800 output samples (0.1 s), byte-exact except a single 1-LSB rounding
/// flip (x86 SIMD vs our C-scalar port, cf. the S333 dual-path doctrine).
test "resample_to: 48k->8k matches docker aresample within 1 pinned LSB" {
  let data = @libavutil.av_base64_decode(rate_in48_wav_b64, 1 << 17).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  let out = audio.resample_to(8000)
  assert_eq(out.sample_rate(), 8000)
  assert_eq(out.channels(), 1)
  assert_eq(out.samples()[0].length(), 800)
  let wav = out.to_wav_s16()
  let demux = @libavformat.av_wav_open(wav).unwrap()
  let start = demux.data_offset.to_int()
  let payload = wav[start:start + demux.data_size.to_int()].to_owned()
  let ref_pcm = @libavutil.av_base64_decode(rate_ref8k_payload_b64, 1 << 14).unwrap()
  assert_eq(payload.length(), ref_pcm.length())
  let n = ref_pcm.length() / 2
  let mut mismatches = 0
  let mut max_delta = 0
  for i in 0..<n {
    let raw_ours = payload[2 * i].to_int() | (payload[2 * i + 1].to_int() << 8)
    let ours = if raw_ours >= 0x8000 { raw_ours - 0x10000 } else { raw_ours }
    let raw_theirs = ref_pcm[2 * i].to_int() |
      (ref_pcm[2 * i + 1].to_int() << 8)
    let theirs = if raw_theirs >= 0x8000 {
      raw_theirs - 0x10000
    } else {
      raw_theirs
    }
    let delta = ours - theirs
    if delta < 0 {
      if -delta > max_delta {
        max_delta = -delta
      }
    } else if delta > max_delta {
      max_delta = delta
    }
    if ours != theirs {
      mismatches = mismatches + 1
    }
  }
  inspect(mismatches, content="1")
  inspect(max_delta, content="1")
}

///|
/// Rates outside 8000..=192000 are rejected with a DemuxError before any
/// resampler is built.
test "resample_to: out-of-range rate raises DemuxError" {
  let data = @libavutil.av_base64_decode(rate_in48_wav_b64, 1 << 17).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  try audio.resample_to(7999) catch {
    @libavformat.DemuxError(_) => ()
    other => fail("unexpected error: \{other.message()}")
  } noraise {
    _ => fail("expected DemuxError for rate 7999")
  }
  try audio.resample_to(192001) catch {
    @libavformat.DemuxError(_) => ()
    other => fail("unexpected error: \{other.message()}")
  } noraise {
    _ => fail("expected DemuxError for rate 192001")
  }
}
