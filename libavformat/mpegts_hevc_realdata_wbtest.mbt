///|
/// Real HEVC + AAC transport stream from `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.6" \
///          -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.6" \
///          -c:v libx265 -x265-params "log-level=none:keyint=5:bframes=0" \
///          -pix_fmt yuv420p -c:a aac -b:a 32k -f mpegts hevc.ts
///
/// Expected rows come from
/// `ffprobe -fflags +noparse+nofillin -show_packets`.

///|
let hevc_ts_b64 : Bytes = bcat([
  b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/0dQABAAArAdAAHBAADhAPAAJOEA8AYFBEhFVkMP4QHwAGw3z4r/////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////R0EAMAdQAAB/IX4AAAAB4AAAgIAFIQAH6LUAAAABRgFQAAAA",
  b"AUABDAH//wFgAAADAJAAAAMAAAMAHpKAkAAAAAFCAQEBYAAAAwCQAAADAAADAB6gIIMWWSrkyvAWgIAAAAMAgAAAAwKEAAAAAUQB",
  b"wXPQiQAAAU4BBf//////////9iyi3gm1F0fbu1Wk/n/C/E54MjY1IChidWlsZCAyMTYpIC0gNC4yKzEtZTQ0NDc0NDpbTGludXhd",
  b"W0dHAQARQ0MgMTUuMi4wXVs2NCBiaXRdIDhiaXQrMTBiaXQrMTJiaXQgLSBILjI2NS9IRVZDIGNvZGVjIC0gQ29weXJpZ2h0IDIw",
  b"MTMtMjAxOCAoYykgTXVsdGljb3Jld2FyZSwgSW5jIC0gaHR0cDovL3gyNjUub3JnIC0gb3B0aW9uczogY3B1aWQ9MTExMTAzOSBm",
  b"cmFtZS10aHJlYWRzPTEgbm8td3BwIG5vLXBtb2RlIG5vLXBtZSBub0cBABItcHNuciBuby1zc2ltIGxvZy1sZXZlbD0tMSBiaXRk",
  b"ZXB0aD04IGlucHV0LWNzcD0xIGZwcz01LzEgaW5wdXQtcmVzPTY0eDQ4IGludGVybGFjZT0wIHRvdGFsLWZyYW1lcz0wIGxldmVs",
  b"LWlkYz0wIGhpZ2gtdGllcj0xIHVoZC1iZD0wIHJlZj0zIG5vLWFsbG93LW5vbi1jb25mb3JtYW5jZSByZXBlYXQtaGVhZGVycyBh",
  b"bm5lRwEAE3hiIG5vLWF1ZCBuby1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1sYXllcnM9MCBvcGVuLWdv",
  b"cCBtaW4ta2V5aW50PTEga2V5aW50PTUgZ29wLWxvb2thaGVhZD0wIGJmcmFtZXM9MCBiLWFkYXB0PTIgbm8tYi1weXJhbWlkIGJm",
  b"cmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTIwIGxvb2thaGVhZC1zbGlHAQAUY2VzPTAgc2NlbmVjdXQ9NDAgbm8taGlzdC1zY2Vu",
  b"ZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMyIG1pbi1jdS1zaXplPTggbm8tcmVjdCBuby1hbXAg",
  b"bWF4LXR1LXNpemU9MzIgdHUtaW50ZXItZGVwdGg9MSB0dS1pbnRyYS1kZXB0aD0xIGxpbWl0LXR1PTAgcmRvcS1sZXZlbD0wIGR5",
  b"bmFtaUcBABVjLXJkPTAuMDAgbm8tc3NpbS1yZCBzaWduaGlkZSBuby10c2tpcCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29u",
  b"c3RyYWluZWQtaW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVyZ2U9MyBsaW1pdC1yZWZzPTEgbm8tbGltaXQtbW9k",
  b"ZXMgbWU9MSBzdWJtZT0yIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vRwEAFi1mcmFtZS1kdXAgbm8taG1lIHdlaWdodHAgbm8t",
  b"d2VpZ2h0YiBuby1hbmFseXplLXNyYy1waWNzIGRlYmxvY2s9MDowIHNhbyBuby1zYW8tbm9uLWRlYmxvY2sgcmQ9MyBzZWxlY3Rp",
  b"dmUtc2FvPTQgZWFybHktc2tpcCByc2tpcCBuby1mYXN0LWludHJhIG5vLXRza2lwLWZhc3Qgbm8tY3UtbG9zc2xlc3MgYi1pbnRy",
  b"YSBuby1HAQAXc3BsaXRyZC1za2lwIHJkcGVuYWx0eT0wIHBzeS1yZD0yLjAwIHBzeS1yZG9xPTAuMDAgbm8tcmQtcmVmaW5lIG5v",
  b"LWxvc3NsZXNzIGNicXBvZmZzPTAgY3JxcG9mZnM9MCByYz1jcmYgY3JmPTI4LjAgcWNvbXA9MC42MCBxcHN0ZXA9NCBzdGF0cy13",
  b"cml0ZT0wIHN0YXRzLXJlYWQ9MCBpcHJhdGlvPTEuNDAgYXEtbW9kZT0yIEcBABhhcS1zdHJlbmd0aD0xLjAwIGN1dHJlZSB6b25l",
  b"LWNvdW50PTAgbm8tc3RyaWN0LWNiciBxZy1zaXplPTMyIG5vLXJjLWdyYWluIHFwbWF4PTY5IHFwbWluPTAgbm8tY29uc3QtdmJ2",
  b"IHNhcj0xIG92ZXJzY2FuPTAgdmlkZW9mb3JtYXQ9NSByYW5nZT0wIGNvbG9ycHJpbT0yIHRyYW5zZmVyPTIgY29sb3JtYXRyaXg9",
  b"MiBjaHJvRwEAGW1hbG9jPTAgZGlzcGxheS13aW5kb3c9MCBjbGw9MCwwIG1pbi1sdW1hPTAgbWF4LWx1bWE9MjU1IGxvZzItbWF4",
  b"LXBvYy1sc2I9OCB2dWktdGltaW5nLWluZm8gdnVpLWhyZC1pbmZvIHNsaWNlcz0xIG5vLW9wdC1xcC1wcHMgbm8tb3B0LXJlZi1s",
  b"aXN0LWxlbmd0aC1wcHMgbm8tbXVsdGktcGFzcy1vcHQtcnBzIHNjZW5lY3VHAQAadC1iaWFzPTAuMDUgbm8tb3B0LWN1LWRlbHRh",
  b"LXFwIG5vLWFxLW1vdGlvbiBuby1oZHIxMCBuby1oZHIxMC1vcHQgbm8tZGhkcjEwLW9wdCBuby1pZHItcmVjb3Zlcnktc2VpIGFu",
  b"YWx5c2lzLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtc2F2ZS1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLWxvYWQtcmV1c2UtbGV2ZWw9",
  b"MCBzY2FsZUcBABstZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1k",
  b"aXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBj",
  b"b3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJlRwEAHGZpbmUgbm8tc2luZ2xlLXNlaSBuby1oZXZj",
  b"LWFxIG5vLXN2dCBuby1maWVsZCBxcC1hZGFwdGF0aW9uLXJhbmdlPTEuMDAgc2NlbmVjdXQtYXdhcmUtcXA9MGNvbmZvcm1hbmNl",
  b"LXdpbmRvdy1vZmZzZXRzIHJpZ2h0PTAgYm90dG9tPTAgZGVjb2Rlci1tYXgtcmF0ZT0wIG5vLXZidi1saXZlLW11bHRpLXBhc3Mg",
  b"bm8tbWNzdGZHAQAdIG5vLXNicmMgbm8tZnJhbWUtcmOAAAABKAGvJhZ+jbeemj5XURZB94dRcdRkirZZmgKFBhBKU30c87skGkhl",
  b"3ic6SNVvle0JH28Mzn1AVJzPsMR7JaajNFG6UDUaDjoScvFbhm0xPhaE++7slbp//+2l3HR5gSt3t7jv6QQxc0QJCCg3SNtHDFVn",
  b"nJOC+JhL/mbA4+dp9lRwhwIifhNO5ky+XF+J0ZckVUmRFjRyPTiehc/+C2LKiEcBAB4y8FuS5/jUxLwjiCzsqNL0dfvwgK/tXVhi",
  b"rmj1t2uoYdjLQCeZqqpjAkhCXEbIjWf37+7CtEp1MCp1IUcoyeOUeS1ztPYZ+3+exnazVy71kwxLV2qW1kRonz8ZVplLdKHODxPi",
  b"kB8eGgwrnBYlHK0XC8cuTeq3TWu9+a8AHtpEnAhbZZNWIZ76fICE5X0Zp2A5qlZ3Y3LBpTyN+wUC8+Sq//q5r6WHjEsZD0+gDzTq",
  b"VutFTeFg7cmdRwEAH5EO/wMR5Bl+fLu+5pqbZK+E18LswtKQzzSSOxpnWKNdAWLqFBaHw8lH+BGNP7CBlkZPnqKdOztRz5eBs0dZ",
  b"8g4egZrtfscYoI53XdkRW4WriUjphi1zRPqXkN2IWnTaOI0Ntn+mVTsw2JGs8yPzec2c0EqIniqoKJJVl+tOkHEU9NH48dk2mbr2",
  b"qWx3T8MR+MGjHQdoAMXuck+LnsD5mqCkzBEqPc/WazaKpoFgoozc+NRJWynmwmNHAQAQ3mzyywPRU48DXMtUlupT7fuKGPQfPj2W",
  b"wS+LjWpYJgnIg8vJifocM/WwBhpcWguvqR1ujvRYV3tqpbysm7x80y1rSwOozhyD06yT6wxoj+mAUB6JPpYCK4sx1wN5B/MaERvG",
  b"rj3g7Ln7aV1w9r166caOvM//3DhRt+CxHTSRxtIANwfcoIfUv4SzKA/qR4HQpO2hZ6OX9ouq1ueWo26HGoOYPLbPcCYt7XTrBP2s",
  b"4CvPAQSySrTo6kcBADEoAP///////////////////////////////////////////////////83tFl9MfBUh5ktP3f9CkP03EoNM",
  b"i+8zUXQluLULYoWo/4TCp2C2Q589Mbm3XE16V9NDEj8uJr2eTus6/8RMGj2kRcGtW8BshVQakrGWcSbPr39JZZremk/EoAFn28uw",
  b"6SuQ7nZT6YlJeDXSFib5dJ8XEXA4ZbbZKWpRefJ8HWmbvcgyqjZJT/nHevYqI0yVR0AAEQAAsA0AAcEAAAAB8AAqsQSy////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////9HUAARAAKwHQABwQAA4QDwACThAPAGBQRIRVZDD+EB8ABsN8+K////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/////////////////////////////////////////////////////////////////0dBADJXEAAAokl+AP//////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAF",
  b"IQAJdVUAAAABRgFQAAAAAQIB0Al+EMZMP+yqP+Hn/jXqM8q/v1X///SQbLOv5/bLnkuB/n8YgXceaN340I5akT3n26robDRG6ik+",
  b"F5zjIrSiDUyjNBFkR0EBMAFAAAABwAY3gIAFIQAH2GH/8VBAE9/83ABMYXZjNjMuMS4xMDIAAmClVJDacjLzx6eeNV5y5arrJEeU",
  b"ki/MJBt3A/Beq9i77hstqWkf49Lze96vyeBtTFVjbNaa8+slJpqqYrmKoyaUslLJaaUmjJQpRkoyUSa0NobQwMbNgwMiRAxs2bNo",
  b"kSKU2bNxRRRRRRRRRRRRRRRIiiiiiiiRERESERRREUUSIooiiiii4P/xUEAVP/wBOJRHAQER2sldlFOrKdWS6c/z7cabPGr/+tfv",
  b"1xrjV6//teP588a41ev/4vf+fPGutasN/rY0fRQYC6BMsIWfqdZvKY25wGc4DAzuEzAwM7hISDAzuEhIMDAzu4SErBgYGd3CQk5C",
  b"bCXf4Qqw3U+cuV6UrelCb2ZuUJKkswaUJCSV4GlCQklecGNmwkJKg2bgwMbCQkqxy8Q1FFFBqKKKKNxtdFHA//FQQAh//AE68osa",
  b"1457/Z+/t8W6aaXqpUcBARLI45JJIiQO5/fOm7NmNn9yGT4MM/uBk+DDP7wj4+AM/uBw+AM/uBk+AOD/8VBACL/8AQgyieKdayvn",
  b"/+z/H/r/7XfF3qr317/W/H327cupVF5rYoXQjAiooNRRQagULoNaNhLMSzTM65vzU+Dt+Zz/8VBACR/8AQgyiiJ9QIdIyvX/9+//",
  b"1/FzjXGTzuvHxXj427hWspMsJ51HOop51TzznnUJ5z1ZSqb6XHuqn5XgHPF4mKYKFXD/RwEBE/FQQAk//AEKMooCjQiHVqr3//tf",
  b"n/1/8l8alydevX3fP427PDJeKupg+UUS3zGiiiiiiiiq4oJERUqvWJS/oU0pkL0O2YBfgP/xUEAMn/wBBjKU410Yh0RB0IhVXr/+",
  b"m/9f9pfFzWdZvv7979p3cPCSUwC6ujDn8HB6dev8tcptc8830osZcw9VSz2HaLV39v9JZYC1oje3Iw063g12Mm63EnHEIgMkjdka",
  b"1HD/8VBADJ/8AQwyizpHAQEUIQ6Ig6ERaMev/6Xf/t/7Xq9SWo1P0/fI628u8qJQ+n0+kibi+n0+n0o+n0+lA1wc/nA23Ase4ZAx",
  b"Dw3hQDbDE83KdLOkPdFjFFoCVpjvnNSzgXvrTVrFwP/xUEAKX/wBADKc6IFehEOpZnf/93v/v/1ucTV6rfH8fvznTdPLQqTLwImJ",
  b"hpOw9DGwGHjx5cy8M0gi+Gc7RpbbWJr6izUdYSmwfwSgKgxkNo7/8VBAC3/8AQoykJY0OEcBARWrRCHRCHRCHSDf/0n+/1HUuSHr",
  b"41+387de6qSVRABgYG7xlOwMfiW4/AGJXgYkDZjnJV+b3Qg5pQKU00viTLwlC/XAYlaCs7A/m3QXr//xUEAMf/wBBDKQljJQn0Ih",
  b"0Ih0Ij0rdc/2/T/29petdLPGfDvrHhUzPOXJkoA0svvLeQwy0F5/RCKKKIohEiJXGGKRERS5TkfLc2FEvwd8CQUmKjo4UtiRSYuT",
  b"4V8y8IW4uP/xUEAPH/wBRwEBFgYykJYySKNCIdCJNCI9CQVVv/jv/2l3rU1mj8/rf7fvt3KLykyWAm7d9un1zLlAbJIa88888l55",
  b"5PmtKW3rjNEkrGeNchH4bJ9an0uOE4R8thLHRgwxzxnFDuk2zb0td7Fp8E4cK9UU5YSrCDvUEO//8VBACd/8AQgyiJYyOKtCIdWq",
  b"vn8/t/68Scavik55+/OcU7e1VeSpV4PpRQhZ/00IF44QBdFFFFFFFDetvC2J6yWYlukWajpHAQEXLSd5ykC3//FQQAyf/AEEMoh2",
  b"UY6ERaURaJtP/Tv/n9d3fCe295v2v8/geD3qKntVQTzzmMUIkyIRABZj0EaDfv30/DfS96d/NS96K0uUaWTyJhTli64aSvdxv+cM",
  b"lWMVFWtPPzkw3lGSXP/xUEAP3/wBCjKQljJQz0KnP/jf/Pxd6u7Sr+33vvip69qkyC3cAYGBvMRepUWZt+9D5cePy48aoflEXyGw",
  b"752KsTmMWW/qOcOdK9MLqkcBATg4AP//////////////////////////////////////////////////////////////////////",
  b"//+Vy5gXpWsLrxUI69vGl6L0rJakEnp9zdT2znKNYFrfjCdnWmROthw77KX5FYXlPHz/8VBACf/8APoykHYyYJtCIdW7rf/7ePj/",
  b"3u71xk1Ve/3z3+jzzKXVSqgRizJqyj8/66PG/f70/schi4SUJS4ZBITArXSx4lyKi3fYkkL8R0AAEgAAsA0AAcEAAAAB8AAqsQSy",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////9HUAASAAKwHQABwQAA4QDwACThAPAGBQRIRVZDD+EB8ABsN8+K////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/////////////////////////////////////////////////////////////////////////0dBADN7EAAAxXF+AP//////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////AAAB4AAAgIAFIQALAfUAAAABRgFQAAAAAQIB0BH/1EMGRJRkjhnR//+I",
  b"+aH/K80WsWYSW2lJ3hqBn2XlR0EBOQFAAAABwARRgIAFIQAJ3Zv/8VBAD//8AQoymJY0QNdCM//DP9/q5q7s1vPNd+dzOubvJUq3",
  b"cGdnZwyUZRJdglSPACQkJCboTTKzFVpVyk+Btua9aL+TzmuNJIxSSWiDV5tHw/bYrBUyX3JROOKbN2n7FHjlPd8vGwucrEdf/COX",
  b"ttvXFVc7yjr0cpykSjfg//FQQAyf/AECMoh2Qo6MRaMQ6Mguar/8Pf9/+bmur63k1+3889/FPChHAQEaqMl7sKKKAVhN0cBXLgoo",
  b"ooMugy/1PgswM7Bh5GAWq0KfDgBGZoeajCZwx+XgWrkU986cFhfYkn4AD8D/8VBACr/8AQgyiJYyQKdCIdCIdSrPX/af+tXeuL0q",
  b"r+fjj8/jbt8OqmSomD5c052X1r3dHG5k8886p55z7EE/S/uUyIFL3u/JMpC+BP4pAnaKx7uA//FQQAu//AEIMoiWMlCnRiHQiHSq",
  b"r7fn3/9ruccacVu/f7758sO6mkcBARuZKqBxiiWreLUO2/8KMqKIoi4xRfLjFNzIIpqUpcxKp4nsEJatPlqlBJWgT7StSt2qdFFD",
  b"gP/xUEAOP/wBBjKIdkGOhIOhEOhEmhEWhYn/b5/6+1uLu7uq/P4fb+du4rLxIUOd541hyPP9f6smfQa9evXPWnObPPXO6XCsSU7n",
  b"Vc6pQfWspFEZQ+t4N6OrpW9hMbbsil7yycR4p/lFOqhym2VDLe/A//FQQA0f/AEKMpCWMlCnQiTQRwEBHIh0YhHj/jn/T9ZNauLv",
  b"ffxXfVMdtrDNUAkJCfPQ1CGiFtjQA+lFFFG5s2uChK1mdY4Zcx/KRejwEYyspOUiSwLIZrA0p3JaXLE0pK3eHKXpOqXai1hw//FQ",
  b"QApf/AD+Moh2RCC3QiHUCHROZ3/6d/9fvd6mtc8N9+1fP89vHlteE4UDz+oJlCTC1iBV2wAwMDAxd1rxvQj/XunS5RckmcXebnOg",
  b"FwiW4P/xUEAMv/wBDDKQljJok0JHAQEdIdCIdGYtIPX/Hj/f95euIjU/T9ec807NtVdZpUoAwMDQKUnD8XPzUPl8vl8vl8qubLVV",
  b"VzZTwoqy1GAn38SjYfKD8FEJAvxjD2lKSITqvDU7zW28HP/xUEALP/wBAjKIdkJQn0Ih0Ih0Ih07dd/9vf/r/NXrV8Kb8ffPn+dv",
  b"A8Z7SoqAiKIDqPyfqJfoIcoooooiQHKSiImErKBJckuRhGPGm5KlYHyFgrxvgO/A//FQQA7//AEwMkcBAR6YliRBK0ZB0RC0Ih0J",
  b"CeXP9e/++/NXJctckuHHbq0kqXQGLJMux6GfRM2CcUr6DOFkdQsjqFpWV1aemrT01Y0KxWrG/q7mdXdf1IerRj0q6KtJqtK50soJ",
  b"IQXSAaNjHapWUVnivnBjlibuBkJ4//FQQAqf/AFQMos6Mg6hVZ+a/XjU1NSWuS5JHDJxJJEDm3OcyYefK1z5VQI5tznNuc5qGTLe",
  b"ytc+Vrnia50c25zm3Oc25zmWyZrnRwEBP64A////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"///////////////////////////////////////////////////////////////////K1z5WufK1zxc=",
])

///|
test "mpegts: real ffmpeg HEVC+AAC (PES fields match ffprobe)" {
  let bytes = @libavutil.av_base64_decode(hevc_ts_b64, 100000).unwrap()
  let ts = av_mpegts_open(bytes).unwrap()
  assert_eq(ts.packet_size, 188)
  assert_eq(ts.programs.length(), 1)
  assert_eq(ts.programs[0].program_number, 1)
  assert_eq(ts.programs[0].pmt_pid, 0x1000)
  assert_eq(ts.programs[0].pcr_pid, 0x100)
  assert_eq(ts.streams.length(), 2)
  assert_eq(ts.streams[0].pid, 0x100)
  assert_eq(ts.streams[0].stream_type, 0x24)
  assert_eq(ts.streams[0].codec, "hevc")
  assert_eq(ts.streams[0].codec_type, "video")
  assert_eq(ts.streams[1].pid, 0x101)
  assert_eq(ts.streams[1].stream_type, 0x0F)
  assert_eq(ts.streams[1].codec, "aac")
  assert_eq(ts.streams[1].codec_type, "audio")
  assert_eq(ts.packets.length(), 5)
  let expected : Array[(Int32, Int64, Int64, Int32, Int64)] = [
    (0, 128090L, 128090L, 3249, 564L),
    (1, 126000L, 126000L, 1583, 4512L),
    (0, 146090L, 146090L, 82, 4324L),
    (1, 159437L, 159437L, 1097, 6768L),
    (0, 164090L, 164090L, 46, 6580L),
  ]
  for i in 0..<expected.length() {
    let (stream_index, pts, dts, size, pos) = expected[i]
    assert_eq(ts.packets[i].stream_index, stream_index)
    assert_eq(ts.packets[i].pts, pts)
    assert_eq(ts.packets[i].dts, dts)
    assert_eq(ts.packets[i].payload.length(), size)
    assert_eq(ts.packets[i].pos, pos)
  }
  // Video PES payload is Annex B with a 4-byte start code.
  assert_eq(ts.packets[0].payload[0], b'\x00')
  assert_eq(ts.packets[0].payload[1], b'\x00')
  assert_eq(ts.packets[0].payload[2], b'\x00')
  assert_eq(ts.packets[0].payload[3], b'\x01')
  // x265 opens with an HEVC access unit delimiter (NAL type 35); audio PES
  // starts with ADTS sync.
  assert_eq(ts.packets[0].payload[4] >> 1, 35)
  assert_eq(ts.packets[1].payload[0], b'\xff')
  assert_eq(ts.packets[1].payload[1], b'\xf1')
  assert_true(ts.pcrs.length() > 0)
  assert_eq(ts.pcrs[0].pid, 0x100)
}
