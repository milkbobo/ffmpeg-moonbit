///|
/// VP9 scaled-reference decoder vector: libvpx's official
/// `vp90-2-05-resize.ivf` (the stream FFmpeg FATE uses for
/// `fate-vp9-05-resize`).  10 frames alternating 352x288 and 282x173,
/// with inter frames whose reference buffers have the other size --
/// both the downscale and the upscale scaled-MC paths are exercised.
/// Expected values are libvpx's (vpxdec) per-frame I420 MD5s at the
/// decoder's native output size.  The fixture lives in a blackbox test
/// file: the whitebox package is near the wasm init local-count limit.

///|
let vp9_resize_ivf_b64 : Bytes = b"REtJRgAAIABWUDkwQAHwAB4AAAABAAAACgAAAAAAAAB8DwAAAAAAAAAAAACCSYNCABXwEfRYOCQcGYAABBB/zZ0/j92fi+o/L8b8XyPU/F/X4b4n" +
  b"5fkeq6j8X6n436dIPYRX07Zw++YT2XcvSes2L8L8nxBn8Dxzx+MYAhZAAH3oezDzwtQmCwWcTROe3VY2R2l3z8QaZpsbMLXIoGOSmFixzOuJH0bo" +
  b"IWTQjqoEJ4iS1v9lO0tDLHmv8z8HbpX177Lyy0Ql6MyZqpAXKwdkvCVIYyDeRfhe790RJZzp2OjB1aSV4jauB89wuBZ5JN5NAO4T8ZB5nsaMvv5O" +
  b"BRoWlYU3pZU6dvTq6CBqTzIboe1vH+BW2iV5iMVyuMTnqME4oEawgYgJnjGcvce1sG1GGx9TX8cm5hDqVL9BwTvuL/NRSB+sfj8SmZ96IWxP0IYO" +
  b"UtM45imy5QcFu+xvMFx6FM8dxzkUbiCI9SyST2aYk9tPgFZeWX7fvq6a9E15X1vAy2MUYmD47qkwINT/ivPWFnm+h4KyEpfOyyUtBvcNYhaxHRbS" +
  b"Bc3H6zkEB2QfPemk3ElHhorl+Ruoh9N679QJMlBwJOY2vhYG6LFQPMLDwrFIw1KrM2xpP2IxhhOhC7BovhMtsvxkmAmSn1ltBPrO8aMLAaT5sD3D" +
  b"iouOVD6s2Rydy+NvKIjlqng+bP/xLPsuQ3wkZNJ4C0ovAR2YgbmKKUapaNLNAy854E2SYUTMiIShGym5TjRpb5sAvZJA7ir838Omo4snGbltyk0q" +
  b"1FSZ7vc4sDRFKH1HbD3BoaCcldbOC8GvsXek21AhQ4G8xJgKup/8z3VRLALlLvQMO0aRXYv4CnENPP+CC/kIdIjNmN6aAJVRnNptbg9ncwAkNKfm" +
  b"XvVSfKlDBC5wbA33xLvcqzkzvfYaYQZ5HBlC6O+QfG8P/09MrMXht8h7f8f3bIPU9TJNcwldpGacbEAtLiaku6yH3ta/yHVnt7KUsqTQytqinQQd" +
  b"FEV+Qd6/vuLGayi/CyvSiUTlPS6j75APUCRc+5tFOaG7SsO80gR/4jsuCf/AsfCrWCNpt9Y5CE5NoOqzglru2ImYylb0LOG6XElHWL2gyu8PhLk5" +
  b"s7yBBpi5eaR7bj09qxk6nmx2y5qavtQMXU60oGn3uJPGJlcheiwiAGarzHwJNr7e8tTLliy5nYxHnFK2BnAM3aXXOu9E1Cv4dFQQ1wnbVmugU5Aa" +
  b"mHYbBrX9xK9HXIloCzlwYTAh/9aKOATF9TOLDLfFKLufGx/dn1ISCR2C3N6b9QQQCNBzlvgQiONli83dQ2SdWiEdzYPAQXX36dCLNUn5qfskpaPL" +
  b"ncoXC5s7fyDE5jUgbCYDd0QSHh2fg6F5vQEXvPaBJCunBhZqTfcwrnP+bZlCuFssToQQQ+oChU1NSXSchBZ6neCcTpg7EpGq1sC6FRI60FZeyxG6" +
  b"qGAWxif3Ia17iYHXqIRM5l0bNhZaaas7+4K1NfY8+jlLgM/1+nJwFgUotzrImAVjMazFjgIY4BrfZFviHrpKQEHQIP6pBq+yh7QgGHRVgHyjp36+" +
  b"w0rTzyZjx5md/SZAlBwohje9K90p0GJ2aPlip0+1usKDoKC5XPvPmvAQ/Ma3/L69WNAm6nycLkcMVXrU/J8IlQYidZFK7xQ2yYoztk4dYUu7yeiw" +
  b"55f6BT9rAT2yp3f1JXLvmAOLpEN1ZO4VB5KeSfkwrR6kdwuoLV/WyxKrc72//IUuFZOCfETSP76wR8FpqPYzZd9Ylt48pIqJnS123kVixpvWOCHY" +
  b"0/LhLPwPod/XMPg0CbZrzLX+V3yaDH3Tz/g4UaYM2rLnu77v7TMX7S1vdLI9aWHzHZgu9Z3K7SNnIZ8IVWkZfxoe6Txra7PHc1Rd5Zoc8I1aQcM7" +
  b"cmZ3GEWS6jt5i9b2K3PJJFtgIz6vWOCODx8ux1OHufIz0thjHBr9sp8iSpnpMiE9KZya3nKyrSrCaE7P6FjeZTUzkXiMiaC0ZjSA+4FKW+rXykL0" +
  b"7J4C1Vx0IpEVmlTu9Wb5BnJjJR8oNiijk7B8XoZN5sRu7daS4IbGP+xcKajo8qiBkBkaFUoj6fRNl13EBWujsDDzJvbLASrDKyjDQhRXGufGEAiD" +
  b"gw07UcxINsE9GQ0w1gPlshG5IEgtbtnLjrz09iUvVO+yHrh2GtgpdU6gsiUpeigYqNXwiW9yfUgPtCXEtyG39wyx+uQkKe0jAlUykiL2uzI7eYl5" +
  b"Fgh9yMMV2X6gCdeT18PP26ZSJ55Dh8hyI/cGChV2FqhnvonqWl5KfxJU9a0zLVBThi68RFCsgJf9hVkMqSIcWBloewnT90VKBGYmMjKMl5VBDPVX" +
  b"rOhGjbsM6AaPzKh1Y/cMPrV9XvpqFSFppwrv4qJg8oKWRodIhiAKkBKlBQYCI97amh6NCNr51sbblmAX1UJuFaABRN4Nj3XlW9NU5blVYtADaaO0" +
  b"UxKgjTK+dyehZ7fJ2oD6uNH0ujkpUKDPQVIXIxmSotlw5lUcozVs2sJ4CEwo8OQADweMmLITF7VcZxi4xWdfURzf7Bu3z7x0rd3gpBQbKSNAakW+" +
  b"OZdKQh+KprxQ68/LeJsvYLazFgfVL4XKUX56McYvroRUoc5cpj0CkYSgIFsJvzx/RN3bePNXMo8ZkQnnWdVpfypQXfKOtYisISlaG84DOpspbznP" +
  b"cCpd48v01yiM4jjR11t2ytimPU91Hahr7Qo8VosJaKDMNiZbVCasHNevoegXLQplqLWJTJh+SKdiHWSv41eO8WhHWU1WQhlRB56YpwPUSSQhYYq/" +
  b"cW+qb3dR4jmQsAX9ru1KOlDKAbjUERir7ShoopjOYnVqwHCLI5DHekWNbg9phK5GaO/PY6dsTlhq2udZAXSuRXtbHM/18PXSV3fQUZe1t8xwsxad" +
  b"7gAUgTB1UEGD91VrPTmofJ/vFVonN/9ofuk5HNNCxwJQq63Gk7pOhaZEjay9qVgr4Z5w8lvTrUH+ECiKoKWp8vcl0LiBsW6jmdO5+UYoFQrzLC57" +
  b"1EFZpUp7E1ClPQgwZ2HBAzn/OxoVXMQB5/2bYLZW+gQBtcJ/Wo8oihuHTUr2HbWUuAZ710HGNo7BO1jxlmL/1QIsocQIPgSrYDn86DOtzIIfXAUD" +
  b"2paSba6zQxPxB5lGL83shXqWjcbFffTm51RLOK64zt9sGlGzle5GggKEkWD3QDNxmzFA21BlpbmZ6YHJqQyYFe7Xg+BymWkERvoE/kTWl96qnqS7" +
  b"og73WxtjEOi8cP9h0oKqOnUeprKQgY3sxvGnS7CS/xWVfqtP3HVkzUsUdAhrpRBRiUOOvO3aYhM+Me+5+1Lrf7vCB4TA22Lm0l+1g955v3XTQ+MR" +
  b"UMmqZeY9r6UQy4fsXfVII9asg+LslUck04e8oSTO5t2pjVT/tHoly7p3kEaVDFdf5Mls+DiSBP72Y8i7tPi7+QL3HVLtuQCXfsyrY2RGRhFraSp1" +
  b"Q4bNbVTahF4+/gcPM6g1AGin11Ol0BAiwdzoc4CaOjpdImsPU3Fprg8TDTNQTLdB6XnOHo9tV4t7zecCQ9Oa281cUx54cqhgMAQy2wAkpnVs4zMI" +
  b"vsp5eJ9jYaVTVUyT9sz2/vUYCyxkq8B9MeXoS2au58qaxXrGsclSfa7RVgV14EmKmx8ctXtLwthxdhVUt7gNZXvNSfzWD7m5ktO9KwD5mXTZic7a" +
  b"bJ1e8qdzC7ZcM/f1orua3WAGUnezvKjzIPXB+46tImkJe5JYECdCJAjia/TgRs1DEV0iZj+bCA5LPcsRGoRR5Fuv3JCsWjiO82PWnNrDEASqaiVE" +
  b"BmXxyASw+FTSm+/csxz4YsIv6jIXIqYjc0mcIVQ+AU4Lgb8+IuLgngqapjJAq690YH+KXeaAK8pHqArhCKDg3XVNig2QQMakcvj41niVNUSGrBUW" +
  b"iT3J93wpZVw4Q52YxQgyWnYI7rQdOqaC5A0H3daNVkRHYeEMH5DNDxJapm/AYfeXJUSou9cWU5c2yZ6aFs8Yk/FvYL3O8/8ev9ExG6Gsj2SvGHTs" +
  b"czb2yWBBDVuzcd/3YBN0ZTDsHw5sc6Cfk4lHqK99ABoqa46GFDrgY4DwvCryAXMPfUGW5FEJCHMmbSwq4xWk36j4ru8vdYtrwtWAtd7ZgbCwrD/9" +
  b"a8cNIbdem9ZJ2FypgrbDS9fo4ZIh3Ma3RhOeLbz7wjRCLT23E2rpxRcF/loxSEGuHCh7UKi5hFuopTGfzCC9++GhXfdE0cEGd+J5l/B/wMKd+kl6" +
  b"xr+b69M6nGhAjYJLwGNM4VB1GkvXnJm92xN0SAE9+7F0NWkvHUyflTda0ifzKt7aBZQwL9q0c0Ho3B2TCQQGY0vjbmNNThi6tBTN8p/pUv3aRIhB" +
  b"j7LSfM2K4V57baLyQc0HUFfKYzzwxsowdzoOu9rq/ZpApr2dQkYUT2whwcHETT6uDXs81y/MOEv2VlicwfjO72NB+czdTkZw9ZlxKLZbcZz8/Nlm" +
  b"AhD4hk0bMpcP682TbNnJsuuc4SY1IcOndlR4+TITbjzvzjQaZoCVEh1vqq6mYrx1rzJ1T/rN8ZsEIOfRd8zyLpm8tAwJTNN99Wu8Cc/8Nwo0GQf6" +
  b"FZbDvtNyNfMtxyIjl4ofaG28EVIrAumLIYd1PO9MXsdthslKe1R5GO+FhN6AAnjHr3/CeJTViwUKzswkSXwQuvtMlJT+thZKpaxbowTH7ctEoUHB" +
  b"3+6MvdrCyLMEIuqOy1mS97785FgbRaHcBow9n/9Q+gexLwta8+CZnrgtdjsxJLzdRnLZHBDuSM5OjE8suk3pkewGUtxLD1Er7EtfPKZkURFapxLw" +
  b"gDosWIoRpWZQaLu2iuA9XEw79HCGGQjAnArinMbq8rd0YfE1LzfF2w5aoqbk5czW/toO9/D+51OMNdURuMWs2HAoLRAdYusGlJWvmXFmni/iSn52" +
  b"JkOa6VGKUoG8aVk0RELfpTyh66fDvhKFehKUU/S5fwytEUM4WlF544v/N5D7RPaMdWf+xC+zAJD8vH7F2NbHip/peltvl526idJQVKbz72ZYHQxv" +
  b"iFmOn+RroON42hn0XJn4jmMK0Xg5Zo+lPqeueFaBW8ipX0Lrl4s5wOn74Z2oYU/a4lihPrVaMYB336ffCNFMt3Q8nEED4baoOe0YmLwocw2VeQin" +
  b"fdp4flyXNS0Q9lpKuT2ikLiW+Doge/+14c2PnbEca+MSIVvbxHeW1D4YOalngrtshQIZZP5jMFu7/tHSywDzgWbr5U/IoHamm99Tkg6ZP5nDIUQ1" +
  b"Q/wmw+vLf4Z4EMSR606b5uhn8FsSLSmpKGzqNL4SeHFnOgwhB/5glEzpFWWCFoCMQuH8DW3YEVhx6kuAdQEAAAEAAAAAAAAAhgBAkuFBYAAATHDJ" +
  b"X5NEbCtDvw1gUnyTzC0nZAB7on9tHradV0heaVirWvGAWBh61ONJG/LviwdD/ZnZKSsFSvLbdU2wDLO++v7WKldnrFjA0nph55cQB9bua98RI9dT" +
  b"2yqCJm0avaGuj0UxUbT0Ux55oDUM/3br7O35pWex//e2RyRjyXVs8s1gH11fBKTZUta0/R3Bs2meDTc+x4+LA5ZangeyttikFKG6AUJcAdxwUcKL" +
  b"eP7XYa5IB47xaI6v5us8XE4Am4vYN4zkz4wpOd2/Al6748yS7qN+f26CsFSbkHsLdDKCJaKZlJoNL7OMUbxsVC6x7Kx9xJV2jhEH+Wj4Ksba1lwE" +
  b"sNkykAwP5kofAUkUEP7DUDY0Okv+ZBSDRzz2xYQR3oYdBv3d13+w0ZsbkZFRBEhZUBNghLH87eWCnjtrfbNQy3h6OrnChjjAzXcAQcgTKTmR2l0F" +
  b"VfohjllXUM81Gy8MBmsN2XlnY99QNqeJ4HcBAAACAAAAAAAAAIYAQJKYgFgAAAZwyQE5cAB7INwqBgPTGz97yrpAah/GVpjp1QaC1aUonFwZ0/td" +
  b"5KzXL/P0aKiF2bOSpRUU7gLtc+dwDsv3+JcZ8aq2wh1eUX8V8XMfZEVjp50Fo9l6ZSH0+1ylc5DJcn0INoRz1fw6XyskndbLtLlKo0cuB5aOJ4ku" +
  b"Rp54OaHWP/6b4IR8VF+YgLugWK1+rxAN8SdgwmHAck1l6Y+tE4iyUVZgJEQXEPi7yavjqYZxSZz/F8kWAT/DZet6abYDgdysuZfi5mkP4HqxCgn1" +
  b"Jv272Zq/pgfG26FzH5UqiMi4dZmL+nHJhZrGTxYwr3k34z9PBL4FtSrxLDpvxqe3uOPyFUySTdC8uUXFCHHpLbx0XHQNTwD9RwOzkV6zqV2AGHm4" +
  b"qAQztUHHJVv/tYJjddXebFbpdQFSfLAVv5gHuaRQqJ3YyH6n7XxTBbpBs0pjjITuzTS8lc0NSPRu0I6ZYb81fOqoNjq/yb/yfdIoAAUBAAADAAAA" +
  b"AAAAAIYAQJAAjIBWQFfAR+YUFgAAAMBwAAB+H5shv+KiXBVcRgeLeMm3yP6Uxk4B9H7e2AbiBrMCDDjx0ZZlXbhWUaxD2QAJ8VcmCXPlSW2nbAnj" +
  b"ZrzQKsSgOyguw8LbiAbTo/j4f4EdJ+EUi20E9pnqi8rDMQHuF64r7lY3H7NbYyFf7rgntQZdSRwIa/Q4XB0PT6tC5C5Qjb0QKzjd+kspqQ7y5Qbo" +
  b"cFGlRExQwDDf2L5DMBJ9u5u3Xfwz0qujDJhmlxmo9c2tvZe0irikWQ+wf3oOrXv0pxBJF98Lv4Q+QCj+87f7dKb9rg58VkMinFuZPj7DZmNYeYjZ" +
  b"oYnSgDRvFCrZmen8AA8CAAAEAAAAAAAAAIYAQJMBXwEf4UFgAAAod29fK8MAA10AAHrdJzCMpJuojfAJ+MAJc3wI00zpazOy2gT/NGn/fK9/HLOp" +
  b"wV/UOZR3A/larVo4RAQrgkVjWnYRVfr1JyJRR6xyvs4VG4PJwk0QuabHsPCD7GkBwxYwEetBGQ4jjmMl1Y8ExgsdpqmWRz5T/jbHQ6iQQdllb78g" +
  b"WF2lIkP8/Yyjcpdw844ancnPDMFojSNCoWpAJyciKJF1TzaCmhWwRh4Y4qwZYJ8dmogN2tO10SwTQA47XUsno5zCwXT4urrpmfSsBXbMv0gKR0i4" +
  b"Pg7PXpVHrJUthLgJYPp/ndpCyds5O1R74GdMriCkPJ94r1LmST6vlA5egrs7yjzFGmhR2oLCMcy66a9Er6kuTZBH/COg314I8n0t1KrY0Nk3fCGT" +
  b"QtUwiHLztfbKcfF3JUP1i4GhPSpMRmPG1pSoehWYTtR3zDsT8OOO6WVdpAmbqV7Bm+Oq16yjlUN05hCZVojc4vqs0T3Hy2i6JC454Z6AWJoNwrEA" +
  b"fyR8/oa+F6oBu+i6U1oJPL1xch+kpHdzU/45oQ4eUaG/0uix7ZUAJIitlxVxdidwyVHbuVbE/eJkZgSm15tFsUqjBtpWRgy6WYGe0X63oKV96r0I" +
  b"zoUsIBG7mMhuFuXn49NYFPcrvd4etVANF9xLekBqN1ofyFq/D4N4sYKtQ6fWjB1EYAIAAAUAAAAAAAAAhgBAkwFfAR/g8WAAACBzZ1BjUAAAAHmy" +
  b"ErUZltSj8+nwv3i/nn53Bz6y8s8B5wYlZzAcBR8mfOscIv4TT1/YbpINBzp+Cn0KoTRBsFAbBdwIIzIINlGNUFWkRFBBuw0sfZjKimGxKuhmzwdU" +
  b"fPKikOrXzZ6vWuS5W1JhzgvKzt4XRIhcWP6LZnzGjoYtzYFpda4Cxrt07JmTPjsI5rJQww1s+M8giVi0wwqRQFzzoQloYBacqy4y9gF+036Zk+3e" +
  b"gGbAADwmG+CR2Cw46cgMjNj9LG23ZURGzxCqUPXj7+eEhJSgLUcWUCqm+ppCItppDeeY/mlwcdZeDnt9xhaopM5NPQmTdxTFPAJlL3gPib03UwBA" +
  b"uiESyASWLhVv9Ro9o1BD1VqGIoy4Fn2xXt5L8Mu5eqNcPSaSZwHKk9a9nlBo2GbAEqWQNjaRyow2k6543gXiofpIJuFBRTKvUrTt0nd4FtTCDWhM" +
  b"r/SqGU7UpcMdaGjNj3FTek3T3N0pykc2UdYVvrvTdrLET9LKww3KY1J7KufJTs9aNjSFhD6VrtiT2aT7uXwsSvSFLzDRzpKDQPKp6d3QvBv8Jsqj" +
  b"Ac4dk8BMgpl40+A2Yi0AHFquHmzsg0Toa5+fK6iNwzvITTPACCqBEsWEjAkYKC4qkjh6/hjqRLOUSEZjC9GNZLkMUHBfz9joSJjGewND5V346Ch7" +
  b"joapJfzz+UnfWpoWPSqMuIp0qgMPKnuexKvpFfQGNRIr05fH0qsCey12nmBKRqiEApCKzkTomOFUVVtLISEWK/P4hiN3MhVez5NGk2K9hvgPBgAA" +
  b"BgAAAAAAAACGAECRcTCwAAA0d36zgRd9X1FOgVJqENv20Cho/ffZKlZqQAB9bItWbdG+cQeFbT6ui7IgNuFQiGrWhZKzWUt/TRTpGbaaF5S9/LX+" +
  b"lGub9B5Vai8AVe7pFdaMC2DkbyrmY6LQzTlL1uAjW0iSNlNCWv6NCApc9vwj/M0Myx5V3ItOxsWL462eSZwvRjgfi7hQ2hUkwerqjtoncSxIPHKV" +
  b"cN/iPVCmliAkfa/OSdKtFAhq4JWMllJhjgCD03pJsyEeoYpGO1cRDl33EZ2Qgs5v966Pa1M2fAT16N7oDRNGayFQtRjQApjgctWGgiI3iZ9KnlPW" +
  b"J4cJ4fmNxdnJRdIDKvxROzMfjM6GHhdD49TmoYNHnHF9SY3cPlBXotQfdrQStRBPvhfMyct4rYi6WTl6OmHftDlnLjFLSLiYOAZQK/IQZkegVtpu" +
  b"BEwVkAa81i6vLvmfV1i/aM8TDI1r6KkUmUxg+Ryqz3lpWOTIFH4mazvTQvkEb8+EaWjaMa7zPMKQWiYzIqbvcstC1rT9JRjNsxgxw6tK3R3isMM4" +
  b"ruCnxk212kGBoshTybrYojhSnJnYT2I3+ts9tooPE3HnVjoWwjM/yWl0vI6MJDdH5vvOCdFx+vUPlM9a+9Ft6w28hEQZt05XrjQ0S8QzPoeifSnH" +
  b"5KgXzzj9SX5coCAI2VVgHS3ynNUWYOxDq7kK5w7uQ1NuV+nsUIfvYWnDbA1Y27icMESp08G8GkMl6ulWbX37gP5asyYiUBfkr/mX6VadGssiPnXH" +
  b"59RtiqPzmLphXgJUiwtx9z1B2S3LtmZ6pWn5LTAWYWq5WEa9hxsHP77Q++MnyE6iWZGqgsQuCikWa4lG5iXa8U2UkO7U2nafjMnRIm+yityJVe9k" +
  b"29cqgBN6Beu1ek6xWcEtms3g4DtD7YiFkDUN5ofoUNHML8msfPQapToxYkKxafA7L07R25wUT1VwetRQERh2ympqN4QfBNKmgmp/Ww0/0NKUEHh9" +
  b"YpdxmvzN6aezdOChLlt4hpuLfaaJro06cn6SoRFWnxfZ52b0jdU6LJvqoblFqwwILcIElTM2CUW+wRTG7mTLAUu9tzh+CfaEM4GazeOmgUeTXPOR" +
  b"jz8OenFgXzO5Dbs/uR6gnv1FnTSWCM2/huAVyWduiqmOuP+nniucs6Ay0Rs0Uw5UXomTl6HuhdcoXBFJBEfEzxtAg37StKE8awkVKY3R5epTFh71" +
  b"chT4iUQBo0K6H2yfX9NNhGe7lESWtOAod21n/lud9xI/hBlARMx9PMowDgqvlFpRwWlLFwBf61oPUUB3FNOUNy1Uh7qBe0c/qq5YPeguub1rMKRw" +
  b"OQN8cZlDUpENWgzoXykrQGG7Dx73GDK8ZQnIv4EB9Ih4QGJ5Hb3EViCrqdpIzDcBTt43rSuKSMY72uMvgSHka436bpTEUgpoklQaBz1Bqo8Kzzmf" +
  b"IgK8226Dpx28LaNaRo2MGSgVtt85MgSAPJZ4kOGhCWWRyJr4ZecOd3l4w0dI/fCM/VLeiSmr50aGAy6vz2Ed2nEs2qcxiFh6X1fi3bdsZaUiiqzO" +
  b"0YCXv9FHs5mBQbhKQ7hkpu2mwi7OCACoeElPxXHjKDomL5dmNwjCJ1RcWIh7qTrkdNOBfMr8FocSCV56Qnkt34VdDXIpmAbSJlE6jqsv20Rr0n5T" +
  b"UiSUj8nbcQuAZHW8NC/jawLBFGqJEsjKw1+rexq0UJtWwO3SLV1B3Pprg4BhQROK/AcHSWA21L+xh62bCG5A7KVl6IAaOfiWv+aaSTpDmXgr8Ku1" +
  b"TyJN+HDZ5jjJAbu4LTOkETWK5G1viMxG1Jl9Rcq2HGupnGe9Bne3ATZx9xSoGDzedD6hiazlBYaIccSKdnmH24bOw5jzDBPi6tyvTp9DC4vyZ9fu" +
  b"KMGiLN39SOSaYOdWkkZHr/UnduaZIzocGU/okhGVsYi4B92FF1lFmCSzz4N0G3A2nLvscQlKp41tOXFLRiEv5PAv2bZBqErPbZhTNYkLkeXatIg8" +
  b"6+REeqE0+8nxEhnEv17azaaDEKXcPAafJNcxVeGHrru7VfwRwPFZISZtcp2p4AAIAgAABwAAAAAAAACGAUCS4WFgAAAMcAAAdST2jWEt8GB3szUa" +
  b"7XeyW0J6t7iW1+cev2/Nu6nR4MXl8uUE8lX7kgsd+CTNOKcNMQp2mtUfSa0eMf3qluhECG+Azm+pQKHy7A0dFNQvxMHZsVHrEpwnVCl/nnx8qHf5" +
  b"CYCeoKIFXtZts0G4EuvoZPu4DLA5Jkoc/0HEnq1hlAaHmrQr7v3o4o/9awkjQ0TKZ7L/mHAubIWrhNPm88OSvmN1aoCTT9WCMfbO2wET1NI7gv6N" +
  b"4ik/WvwXJEF5AewhBJvagXgYY0KavOhUE+H2Big2DfuGlj5W1Xj/5nQF6ytDw8VxVdJmySw741Ebsbk5/iGsRROvMCx8iNtqxkdnMZ/SF8j2oCSu" +
  b"xHhA8JnEpnhckmZVTrNlTXa6HYyqxHo3TyaPFVmRL8I4eFcAva8tMN16cof6P4iqd6oMQfk0BNczYqp6go4eUtsdfD78OuLILCzfHNBRjDK1I5Bl" +
  b"FRPMR7XmZA5jE6e/4HhhBGFoUWD9w46gv1bkuvjKCoxwmJ30MExPfQZukr2qFAytQurU1gPksgdIEyTo3/vL9hvC2NzMDUpUi9NbEYNtTjOLAOnx" +
  b"UrA2gVTW4k5MlDnXJJEJMKIfNVfotWK2Z1tC6s/8iGfvNPczY1PVXQMEH0bWPrihhennJIgDdfyrnoNdW+hfW575mWuklsACFyOAqgEAAAgAAAAA" +
  b"AAAAhgBBCuFBYAAAHHCpBwzfwAB3gI+IOn1+4m1gi5WGByLu90AQi4g0v6G5z7Gs+xA9Wp8u/bM9JW7+/4EO6olj4gKt5M15apNaY1ys24jw9Ulb" +
  b"VZeRXtEoUkkHQGoG+k32Hut8nRsuvszt//k89fPw/5QOM+JPAk2r8PB/dPIy31MYy3FBMrm4bBJBEGrPHuPg2kyD90OSBoHaRgBkH9yhxFpyT8Xd" +
  b"ui86h4L4/jn3NNt14pokKqQWRrt1I54I7vOiKtUQabVTOG7xuUFJ6nE5rbq9Lm1uSeUlgEngQMFyFPwRdy8cLCr4Me/AG7zjw0+BsfwN91p1ObAN" +
  b"t/eRuLPj7G9BS5ojw53RoR8kuNQpKMchk+9CvCjRU75/BIJDsmAc/ISBzup/3qHfw5a9zCtK4YrJLDxkCQUJk+JJxlO+OZL6CrNWmcmTDa0slsZd" +
  b"DDOUJ1Rd1mSOWiFIARqd2rj1bfObGDuYnCrF0KmrvkyoJZx1MGUfuFRcIZ6KMZNaSSnba0pNNcRpxWBXAHxwgwZVw3a0n+xOt2+budGVQNJdQVx5" +
  b"4WpikDcoHdkAgAEAAAkAAAAAAAAAhgBBCuFBYAAADHAAAH7DfpA16DqolgGq3cM58gUBy2cWVMKqnRJZV9iJ/I9r9VnDUlK5zAGiRCYmiWIuE57Z" +
  b"Ac+GW+q2z+nadRPP0LtTXhKmtEG/PUcjnh31PXC2bI0NBf8y/oCIptlKBFTvAxu2mXXvBm1VcvkJKb3FKoK8LJqbh5OzpETaNI5qqh9KBWbvDZoq" +
  b"NbGH7PatvotLHMZRiQcgwVaM6lWGD0DN7AXcWHbMOVlS/UsjnZCsxzqGVCAVVcjCKF63xZjUMzTSTPuVf6oJtLUNgKEvqUnlPIo4QwHeEPzqLhqu" +
  b"veX4YNpb6KnSVC2WzLQSZWGGIr4B5hDsjWdOQcl1Y4WzBVVqEPMdaeU8KYYoOOLcIv/VqsE8OFTND372VnQe0gt9pI9uw7jUm0ZO9B4fmvXjgy5Q" +
  b"KjrWIwfnHQ5jD0hbIJDKypDzBtlRKr8pDy3Z+j4c9Fzu71u87UDn4oLzm+ONc5kkWZr1LLTk12Np57Npf9KETQYVsh0o"

///|
let vp9_resize_md5 : Array[String] = [
  "539e9964364c1db09ad18f2e01713799", "fb76e673ba2a5342bfed8a1523e0a425", "b0e6881ac6c1e0d839f80f292cb1afd4",
  "f0dbe138413e55c3ee9aa94717fc9f2a", "ff1ff9a16be47910e17f5d0aa857e6d1", "79ccc2a656c80c8d4f2bc3c154ebc408",
  "2c6f7b8c72a0103cd1fa37270f6d9962", "9f837ba58bf07d1e1a8b6a30a9a588e8", "81ecfd1810b25395af999e557ed4b938",
  "cee53e71d6347333fd76d421ece1740f",
]

///|
/// Decode the resize stream and compare every frame's YUV MD5 with
/// libvpx (vpxdec).  Keyframes, inter frames with a differently-sized
/// reference buffer in both directions, and per-size state resets are
/// exercised.
test "vp9 resize: scaled reference frames match libvpx" {
  let dec = @libavcodec.vp9_decoder_new()
  let ivf = @libavutil.av_base64_decode(vp9_resize_ivf_b64, 1000000).unwrap()
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos < ivf.length() {
    let size = ivf[pos].to_int() |
      (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }
  assert_eq(frames.length(), vp9_resize_md5.length())
  for i, frame in frames {
    match dec.decode_packet(frame) {
      Ok(fs) => assert_eq(fs.length(), 1)
      Err(e) => fail("frame \{i}: \{e}")
    }
    let yuv = dec.frame_bytes()
    let digest = FixedArray::make(16, b' ')
    @libavutil.av_md5_sum(digest, yuv, yuv.length())
    let hex = "0123456789abcdef"
    let text = StringBuilder()
    for byte in digest {
      text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
      text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
    }
    inspect(text.to_string(), content=vp9_resize_md5[i])
  }
}
