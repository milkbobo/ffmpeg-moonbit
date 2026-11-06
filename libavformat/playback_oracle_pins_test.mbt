///|
/// Pins of facade behaviour verified against the in-process FFmpeg oracle
/// (`ffref`, PORTING_HISTORY §328/§329), so the wasm suite guards it too:
/// the MPEG-TS packet walk (h264-parser access-unit hold-back, ADTS frames
/// with headers kept, `av_add_stable` frame timestamps, every AAC frame a
/// keyframe) and decode.c's sample trimming on MP4 (discarded packets
/// consume `skip_samples`, the last packet's discard padding trims the
/// tail) and fragmented MP4 (`skip_samples` only).

///|
let pins_av_ts_b64 : Bytes = b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/0dQABAAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////R0EAMAdQAAB/IX4AAAAB4AAAgIAFIQAH6LUAAAABCfAAAAAB" +
  b"Z0LACtolsBEAAAMAAQAAAwAUDxImoAAAAAFozg/IAAABBgX//z/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4y" +
  b"NjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRt" +
  b"bCBHAQARLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5" +
  b"PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAg" +
  b"Y3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYUcBABJfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVh" +
  b"ZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBj" +
  b"b25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTQga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50" +
  b"cmFfRwEAE3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3Rl" +
  b"cD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAABZYiEOgxgAIaAQDyw3rypgC0gyFtUJ8ACmyImN+hkdwAHQZRHMSaalwryquBM0Sfq" +
  b"C6ab+zAe/wbh78IAAEAAADAFSw9gAAoAHNMBRsDo+eAyAABALAAEAcBHAQAUD7n4RAAEAEAAQGQAEBAACAkBAHyACZM8yAKBf+f2" +
  b"sgA4uVwDg99QgQVgsIKwABZOHUREYUSB9xaF+0ULFcH8vw9F8g8IAAVAAEARgQAAqAAIAjAYwA4GEADyITQIyRIJim4EYD9f+DgA" +
  b"CACABwC5YCQFblD4hy/pxiYWnNIbu0GBGZkaG3Q6M+ABgpmu1KHgd8Ua/t4YIQAAgACBKamMkDJoN77vhQABAWAAEBkAAQ6wgABA" +
  b"IA4AkkcBABVa81AAo0SgGBDKtRlpsAUDTthAgrBYQVjcEDIDoN4egsYdxsDDPqkwhQCZjcwgABUAAQBGBAACoAAgCMBZwAcYMIHp" +
  b"8jqHQvThElwynH4APBEAC6keaIJPK+r3+QAAIAgAAgDAZcKgD7gB0QBOAEAKy8WDxcBMHuUgnXWij2X+JAA3Cx4lmhaagnK38JAA" +
  b"LWgGBkdgQAgACBQoABIQAAgolAAEDhCqWUaWAOXqDTGAcGL1yxGchUCARwEANg8A//////////////////8llfy2WqlgCmHMoegy" +
  b"ZyInv+xMCchnMJCgWXP+CzgAIACAqQZZIG4W70mDpKtm3V/AB7CDNQPVIGHzfq8DwABACYBgB1wcIDYgONt3gDHYGmsUBxNCcAG4" +
  b"edDcBQmOUAd+7QkAA3IAHA+GwIAAQAQABAlCAJBAJmKVuWpM8XiQqldAFACM9+y1N4bmUYDN8qebkfEYzMRSPkAOhoA/RBBZVyVj" +
  b"oWfCB61HQAARAACwDQABwQAAAAHwACqxBLL/////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////0dQABEAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////R0EAN40QAACQtX4A////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//8AAAHgAACAgAUhAAkvBQAAAAEJ8AAAAAFBmiBifBHF00qVeCOK22phMoBHQAASAACwDQABwQAAAAHwACqxBLL/////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////0dQABIAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////R0EAOGgQAACiSX4A////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////wAAAeAAAICABSEACXVVAAAAAQnwAAAAAUGaQMnwxFAweTIGaljDQbQYuk9KF3FWP8V64h0fx4YigwdNkDXcsnTzQbVL+AiA" +
  b"3UcUZc/ox0BHQAATAACwDQABwQAAAAHwACqxBLL/////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////////0dQABMAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9E" +
  b"uZv/////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////R0EAOWUQAACz3X4A////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////wAAAeAAAICABSEACbulAAAAAQnwAAAAAUGaYSfDEUDDCmAp" +
  b"UtoJP4myvl5RCpvDT8u1xDo/3hiKAMP0wF3lt0LOIWTDQJeYQ2um5inXLsCT0FBHQQEwAUAAAAHAC0+AgAUhAAfYYf/xUEAjv/zc" +
  b"AExhdmM2My4xLjEwMgACMKtc6QxCDq1Nzm+JrpuDRUXUpknb2SIAEoSCKYRJySK2EmQiMZJIMS7ZWdsqQ3Ayeb2Fn4bB5lFx7Tly" +
  b"3Hk11FMIhWSSIjIaSbGIyREiQ8exCQ2EWBJFJ/F/DfYfavsP071n4rsHuLrnjLiO4tu6O0bqrEdDcw9ddk83bN2NsnSWwcxapxbj" +
  b"O9cd3rad6xOOxkcBARHYrjZtBxVxsVhuU7ap21TtarM9Sz2g2K42Kw3Kw2qdtUa/PsdStqVs+v0bTRtWa00a/PsdCtoVVCqlK5Su" +
  b"UrlK7V4asdWOrRq0YaMNEk0k1U1U0k0lD0SUSTSTVTVTVTSUSUSUSUVTVTVTVTSUSURRRRRRRRf/8VBAI7/8AWaY2TbrNROLcJqS" +
  b"txUj/T/vri2Fxerrv19dBer1/XoTV2T+t8L41cqQYr0YePLcimsQ49gpMwRHXZMkRwEBEphk+bSeiqsQP2ZbjY54HuT7YY5I7x0a" +
  b"1VOnapT/xv1a7d/5OiQYGu5BISDAzuEhIMDAzu4SErBgYGd3CQk4DDmXdwk40DMg153fIJCcl5Bz5K/t6JdandiRdATwe3uuD5tQ" +
  b"OAlYpI8L9TmWOuKaq19TtzSzbbhZMlKaVSZrpdpJpJscMa62dpJpGxwprdnaSZ2xrZ3Z2dpGdnbHBnZ3Z2dnZ2dGdnZ50Kyoi+nO" +
  b"8QAIEHb71kzQiXRHAQET+dM8Tem79ArosaLXRYxM6KUSUSUT8p0SEhMyUJS3UuDTXP/xUEAWv/wBFvYs9JYpF1RGQT1vv8v188an" +
  b"FXmt3dXuRHnJJET7ytK42IDxjTukcR7hxHmF28i/CObvLFvqsquQdl2nqvGcTGrU1mxWKsUcqPFazrVqZJOGZNscZmB68MMMHBsc" +
  b"ccWQHrwwwcT/Hw2n394T/Hw2n39yHx8GT7+4Vj79s1LlbtjsORzMwK9FONvtw4tRokcBARSc3P0NNPHr+OpHpZj5VtuXjXSd5jV3" +
  b"Vi/hBWmqhNvA//FQQBR//ADoNi0syAsTQsHRMLWK9Z//Z+38/+X3XDv2y8uSJT9pUqrzW5mqmQT1IL+kFWVTN3HOLKFC8PAL10fv" +
  b"j6cPp7ePDjqoqmkpdHSpBQGlmVJDEAc2r8XSDA7VI2gkJckzdjfOTAuFlFrJoJsudWUYUF0lSShA0ac6CwFYtZber63WEBFTckIW" +
  b"vI1S5Ij6SZKnDOWTRwEBFS0E9MKdmNKzsR//8VBAG9/8AOY2LPBWTAWPoUPoSDpX6fHf/8Xr/9PPz+NcbpM6xLBUftTFMyKihTtz" +
  b"IUUcuZBmbwk6WKhGh4ii8e8tW/KscGGVpbKXdE1zQdt5XveTCzmUOVdL7f4IAkRxdgQjvR80SuBohBRCyVGtOA2CPXYgrBYQTBTF" +
  b"9k8WUEhgaTXaiugXnG2ZuV7tdFiW+CMBCAOGjlmx35Y31NXrh/4TarPh/p8H6HNP+/dHAQEWPytBE4Xs5dVh988nBQ+FWt9OJyJj" +
  b"jGt6YwonyqEPRQI9vvFrVFZXH2OKu8+VGfTw//FQQBzf/ADgNi0shVociaEiPzOf/7Pr/8/bXfxS08+tuN8GLwSlCBKB2r68srTp" +
  b"cRWcE35aV0zWh6io4XE/XFJN9vhq8KppJpJq5pJnoqh2eaRmsGea76cPDM1JVpzOVY4XHvmhMXEViW+HH401NzmdTDozpnCqra/X" +
  b"GKG6apM/LK77/HGMO0cBARc5VUoajG0Mc/OvU87Hweg/+O5eBLnQFtLvc8yws46P0xgzL4RKkRlu45YIHNe2yvYCPISYHZDCVlfX" +
  b"PFhMIU7KxZJmjLq61qVmFkDv0kuEozYAGZ6udjJ7ZwfrCjv8//FQQBY//ADcNizs9EaFBaFA6EQ6FA6V/Wb//te//z/N1xnVtVzW" +
  b"sVDJeQOVUYtUBT28WTNAjZ0635PXzUe6CK7O/s77Ls7rLTIyWLLqRXK8QWrBGQgkMAUaRwEBGPoYi5CzC0AhGEqxlwOCWkvGUeOA" +
  b"LYditQL9Awtt03JnkxaVXu5Gbslrph336+b65ilbetwhdHWkm4gt8lwWXYsosQ6jhPr89Gqn+yOfUUip09a9Sfq9j//xUEAS3/wA" +
  b"6DYs1GZMBQeiYOiYWsfbz7//2vn/5/fzd62qNMl71t+uMulKlSUUGYswpksWio8xqM+j4gu+wPNGY5rHNY5qqUyTVs1xwmkZ8ZGJ" +
  b"nZ2el2Ca1tTL3YMt7oRHAQEZYghubxAk/1TQGILWS1cj235D7ENUIe6GHnI6EnwxBx6lYGtJx5XEa13zQ1zBRU9tcqFgpvz/8VBA" +
  b"G//8AOY2LPRUNQYPoWEhNCwdCgdCwdK53n/97v/3/04r425uziqiZb/wxJGxUwD7gW1hbVGXJSCfBUSNVtUBcfGY+sK1GPsFbfFa" +
  b"he46Jq1IILhlDwPXxTDTFfy5CGCMoihehENwYHhRMAMTphfRUSmSF0uBkR6LeSyEQEbylkcBARolkPlnvnplACEo4qWD8YsE5YDo" +
  b"0AQO8ld79ShaNNsBIJ4N/uAwK+Hmr03nTK/ignIkrfPynFfHqoI+36ECmk35cLYR6qN85pZaE76wsBdLGSkjNYgCM0amMCvcuP/x" +
  b"UEAZf/wA5DYs7OUyL0hB0L+3tv/+9P+/83NXW+LM1O+G9d8YuqRSAUZBxrxsKMwsQk2Mp2Bj8S3qcO7r7uvux7scMe7GumukTdnZ" +
  b"6XSu+RpWhpKVUq+jAYGNRwEBG+TPMBlETVXnVwq2EXtzvd95OrMaVUzEV1ZZ0vfppkiFAPnpfkQYM+zsUYo4wWKXHJJg63Xeu9BH" +
  b"S/6jw4y2KmphceIMowrNvG8q4+cSaJdCtzsqPs8OPCZk1E0DvRbwLQVBpDNbNdBiNMX8QZZxwP/xUEAV//wA5DYs7TQehYJh0SB0" +
  b"aB0r85f/9n9v/x/mOt8ZOHK6kVMH/rdSVUqUqCmcKXL1y8Xeqf9XvpfwpSvT6/Ts4UenZw1HAQEcEqCj0Ogo8PDpLDzrM84oJjT3" +
  b"ELOiHCChGUDUx0aSZ4O9CC2DFa7cGY2KVgBhRmqCDM2cBp1vbPJVaH36Uvp2Os6MI0jgl3M7TA/BJkias6PlbVhDS1FNOV8mdH0y" +
  b"TotiHlXS4VC///FQQBof/ADgNizstysbQsXSEHSP4v1//Zn/8EviZF0kvK1l7vICkxQ2VB3F26iQqSE2cvfHSSgNl2Q9+7z+7dr3" +
  b"e7z9e7HdrrprvrOtazkOs0cBAR21nUkrZ74QvpYo1orexzmcdzWycn3fJzuUJvK5jWMu45gna0JDVTpWkasLmV1Eh65UqYEtCsiZ" +
  b"qVlaY7v7iShRiDgmoNSiQZiQFI0GU3grr3A5VaGjC96L6FRHustuGrVmDElXOc3R6TETlOh3BZjNLEKuYVMjCeX8k2pK9vD/8VBA" +
  b"G5/8AN42LSykMokKQ9Cg9CQ9C/Tmf/h+3/4/reSSuDGszisurVQQJUVkofUvqK0snjpeo3SRRwEBHgklg00tSIvf0axs/dGrRqmk" +
  b"mkmqmfF2dgxFHaRlpBnQ2BLfE0NA7cxdtqdBS/J8KP++7Dr9evdxo+0jbRWblVMZnGb8Tela3sc0kl/AzPooZrjUEO0iMgOzNznE" +
  b"7pBVmPggNEBCfcynSLsS1lOTSEr8Ui1bI0SQQL2en5NdwvPvogjQChttF681jlbr0Azx2Y6c6DzRsR5qACEg5g+15u/WLv/xUEAU" +
  b"v/wA4jYs7KVaB0KD0Kh1L9NHAQE/KAD////////////////////////////////////////////////////b5//i7/6/5ldTvzNb" +
  b"9dOOUqVdQFVLqAoJtpZmyjuEMpuhEmRCIALNWh8/l89t1m/bbflZbeRkFZpSRO731raxUiFfXmGSi4tc77Mb/Z2JQCoic4vNq3dr" +
  b"Gatq71IT1YnUrlmbzmFs5eG9Vve0KcLtTbU29hvlFJQ4zaOxRC6ROy1Jlhk+FSqy6kd/YXcr4EdBATABQAAAAcADMYCABSEACbzz" +
  b"//FQQBmf/ADqNizwZmQFB6Fh6FA6Eg6FA6V4nz//az/3/xpqOeCbvWQvY/NZVLrKvcqCmaaWWp0uoHQi3lQY1e1wFYuNrcapnYuN" +
  b"NnVJTLU0qa06OElLsUzmMw0iBTPHEgMkG+AdDYqSktPrlqETe92GxTNp7aXAHuURpKIeUTgIUioxUJWlKsNigPrb1ZdfWiOyndAL" +
  b"nKr4jMYG2Ds78LyfTJFluJmzRwEBEQ2oyTCxi8A8ClwiakpkJzEF5iVfq65vlLe9D946N0TzejZd4P/xUEAVv/wA6jYtLNQ+iQWh" +
  b"Qend17//2c/2/381xjhp263Wm6kPykrJUBQMToE6Q+a6Ufn9TEVtBBIngjXnl49+eVkLAkaVIlq0C5lfROgzqBMhdHAGA4aiJjA2" +
  b"OZ0+dRibJifaZHuS/5oQc3k7Rmrfd8OtpKvQNHWWgr5iHAGWNXTNDnG1eoUOy6IPLkLMNPjvSbtHAQEShjjxA8xxHq4mqmSIoNSD" +
  b"OlEooseOh71EnP/xUEAWn/wBCFYttGYqC15B0KBZzP/21/10vqM0kxSXs+lrSSLqT8ZoEFqIIL4J+bg4CZVk49AnbxLn5bx4SmCF" +
  b"+mQlxSE+SQhuIJLdgfSL96fncJMQiYgkxA/b7Pms2cadwdqdUyiMcSed9X6vxvK49ywsmcbRtGIjHA8nJz8+3Nnrn4+Pj0lGLsss" +
  b"soQ1zzzlUSjLLLKdDszzzlYjD0cBARMPbgAABUYfCOyPederlDxUol8NQ4D/8VBAHh/8ATKZstNRtmrCZGr2pjrD11+Jri8vU1//" +
  b"a4/XzrQH9O/rjq3RqakEAoEt9VmGv6yC/D8OOuMTTP/nbktSY4QopjhBigp4YY4QZGKCmOGLkYAfy/kD+X8v5Afy/l/ID+X8vWID" +
  b"+X8vV6wpWiEfmfneZJmLaSmCOIWVlVAO9r2vGx0El6d1SwxyZL/MxNhno1smSjC//fn+beeVM5lpRwEBNF4A////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////JEQdZy/3lstMlCCIOw1kOzdnZ2Z2Iw+Nn9cMvK7OzsYAABNnnXlP1XRt8P+B+L8cA/mH5/rP0GDC6rslSkJWp1wqGJX9" +
  b"y0yk7sBxmLj/8VBAAZ/8ARiBtHA="

///|
let pins_aac_m4a_b64 : Bytes = b"AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAK+21kYXTcAExhdmM2My4xLjEwMgACMKtc6QxCDq1Nzm+JrpuD" +
  b"RUXUpknb2SIAEoSCKYRJySK2EmQiMZJIMS7ZWdsqQ3Ayeb2Fn4bB5lFx7Tly3Hk11FMIhWSSIjIaSbGIyREiQ8exCQ2EWBJFJ/F/" +
  b"DfYfavsP071n4rsHuLrnjLiO4tu6O0bqrEdDcw9ddk83bN2NsnSWwcxapxbjO9cd3rad6xOOxtiuNm0HFXGxWG5TtqnbVO1qsz1L" +
  b"PaDYrjYrDcrDap21Rr8+x1K2pWz6/RtNG1ZrTRr8+x0K2hVUKqUrlK5SuUrtXhqx1Y6tGrRhow0STSTVTVTSTSUPRJRJNJNVNVNV" +
  b"NJRJRJRJRVNVNVNVNJRJRFFFFFFFFwFmmNk26zUTi3CakrcVI/0/764thcXq679fXQXq9f16E1dk/rfC+NXKkGK9GHjy3IprEOPY" +
  b"KTMER12TJJhk+bSeiqsQP2ZbjY54HuT7YY5I7x0a1VOnapT/xv1a7d/5OiQYGu5BISDAzuEhIMDAzu4SErBgYGd3CQk4DDmXdwk4" +
  b"0DMg153fIJCcl5Bz5K/t6JdandiRdATwe3uuD5tQOAlYpI8L9TmWOuKaq19TtzSzbbhZMlKaVSZrpdpJpJscMa62dpJpGxwprdna" +
  b"SZ2xrZ3Z2dpGdnbHBnZ3Z2dnZ2dGdnZ50Kyoi+nO8QAIEHb71kzQiXT50zxN6bv0CuixotdFjEzopRJRJRPynRISEzJQlLdS4NNc" +
  b"ARb2LPSWKRdURkE9b7/L9fPGpxV5rd3V7kR5ySRE+8rSuNiA8Y07pHEe4cR5hdvIvwjm7yxb6rKrkHZdp6rxnExq1NZsVirFHKjx" +
  b"Ws61amSThmTbHGZgevDDDBwbHHHFkB68MMHE/x8Np9/eE/x8Np9/ch8fBk+/uFY+/bNS5W7Y7DkczMCvRTjb7cOLUaKc3P0NNPHr" +
  b"+OpHpZj5VtuXjXSd5jV3Vi/hBWmqhNvAAOg2LSzICxNCwdEwtYr1n/9n7fz/5fdcO/bLy5IlP2lSqvNbmaqZBPUgv6QVZVM3cc4s" +
  b"oULw8AvXR++Ppw+nt48OOqiqaSl0dKkFAaWZUkMQBzavxdIMDtUjaCQlyTN2N85MC4WUWsmgmy51ZRhQXSVJKEDRpzoLAVi1lt6v" +
  b"rdYQEVNyQha8jVLkiPpJkqcM5ZMtBPTCnZjSs7EfAOY2LPBWTAWPoUPoSDpX6fHf/8Xr/9PPz+NcbpM6xLBUftTFMyKihTtzIUUc" +
  b"uZBmbwk6WKhGh4ii8e8tW/KscGGVpbKXdE1zQdt5XveTCzmUOVdL7f4IAkRxdgQjvR80SuBohBRCyVGtOA2CPXYgrBYQTBTF9k8W" +
  b"UEhgaTXaiugXnG2ZuV7tdFiW+CMBCAOGjlmx35Y31NXrh/4TarPh/p8H6HNP+/c/K0EThezl1WH3zycFD4Va304nImOMa3pjCifK" +
  b"oQ9FAj2+8WtUVlcfY4q7z5UZ9PAA4DYtLIVaHImhIj8zn/+z6//P2138UtPPrbjfBi8EpQgSgdq+vLK06XEVnBN+WldM1oeoqOFx" +
  b"P1xSTfb4avCqaSaSauaSZ6KodnmkZrBnmu+nDwzNSVaczlWOFx75oTFxFYlvhx+NNTc5nUw6M6Zwqq2v1xihumqTPyyu+/xxjDs5" +
  b"VUoajG0Mc/OvU87Hweg/+O5eBLnQFtLvc8yws46P0xgzL4RKkRlu45YIHNe2yvYCPISYHZDCVlfXPFhMIU7KxZJmjLq61qVmFkDv" +
  b"0kuEozYAGZ6udjJ7ZwfrCjv8ANw2LOz0RoUFoUDoRDoUDpX9Zv/+17//P83XGdW1XNaxUMl5A5VRi1QFPbxZM0CNnTrfk9fNR7oI" +
  b"rs7+zvsuzustMjJYsupFcrxBasEZCCQwBRr6GIuQswtAIRhKsZcDglpLxlHjgC2HYrUC/QMLbdNyZ5MWlV7uRm7Ja6Yd9+vm+uYp" +
  b"W3rcIXR1pJuILfJcFl2LKLEOo4T6/PRqp/sjn1FIqdPWvUn6vY8A6DYs1GZMBQeiYOiYWsfbz7//2vn/5/fzd62qNMl71t+uMulK" +
  b"lSUUGYswpksWio8xqM+j4gu+wPNGY5rHNY5qqUyTVs1xwmkZ8ZGJnZ2el2Ca1tTL3YMt7oRiCG5vECT/VNAYgtZLVyPbfkPsQ1Qh" +
  b"7oYecjoSfDEHHqVga0nHlcRrXfNDXMFFT21yoWCm/ADmNiz0VDUGD6FhITQsHQoHQsHSud5//e7/9/9OK+Nubs4qomW/8MSRsVMA" +
  b"+4FtYW1RlyUgnwVEjVbVAXHxmPrCtRj7BW3xWoXuOiatSCC4ZQ8D18Uw0xX8uQhgjKIoXoRDcGB4UTADE6YX0VEpkhdLgZEei3ks" +
  b"hEBG8pYlkPlnvnplACEo4qWD8YsE5YDo0AQO8ld79ShaNNsBIJ4N/uAwK+Hmr03nTK/ignIkrfPynFfHqoI+36ECmk35cLYR6qN8" +
  b"5pZaE76wsBdLGSkjNYgCM0amMCvcuADkNizs5TIvSEHQv7e2//70/7/zc1db4szU74b13xi6pFIBRkHGvGwozCxCTYynYGPxLepw" +
  b"7uvu6+7Huxwx7sa6a6RN2dnpdK75GlaGkpVSr6MBgY3kzzAZRE1V51cKthF7c73feTqzGlVMxFdWWdL36aZIhQD56X5EGDPs7FGK" +
  b"OMFilxySYOt13rvQR0v+o8OMtipqYXHiDKMKzbxvKuPnEmiXQrc7Kj7PDjwmZNRNA70W8C0FQaQzWzXQYjTF/EGWccAA5DYs7TQe" +
  b"hYJh0SB0aB0r85f/9n9v/x/mOt8ZOHK6kVMH/rdSVUqUqCmcKXL1y8Xeqf9XvpfwpSvT6/Ts4UenZw0SoKPQ6Cjw8OksPOszzigm" +
  b"NPcQs6IcIKEZQNTHRpJng70ILYMVrtwZjYpWAGFGaoIMzZwGnW9s8lVoffpS+nY6zowjSOCXcztMD8EmSJqzo+VtWENLUU05XyZ0" +
  b"fTJOi2IeVdLhUL8A4DYs7LcrG0LF0hB0j+L9f/2Z//BL4mRdJLytZe7yApMUNlQdxduokKkhNnL3x0koDZdkPfu8/u3a93u8/Xux" +
  b"3a66a76zrWs5DrO1nUkrZ74QvpYo1orexzmcdzWycn3fJzuUJvK5jWMu45gna0JDVTpWkasLmV1Eh65UqYEtCsiZqVlaY7v7iShR" +
  b"iDgmoNSiQZiQFI0GU3grr3A5VaGjC96L6FRHustuGrVmDElXOc3R6TETlOh3BZjNLEKuYVMjCeX8k2pK9vAA9DYtcFRREFxm//w/" +
  b"T/9epXWUyc+atlkolEq9yrqlD5W1g0QH/z+kef6y3Ws51FLBppLuDgHb+rMy4lIMb80bj1hhu66PP3GXYUZ0SfQlpEvkNoQpSkeQ" +
  b"/KNGeQDI+c+AGFgbsbqNJePoyN2Y9EDoyM2DZtTATNe8Iv3T+jqcIO0H4Q+HgssBpXGc3e8xRX6S8eyatFF1aZ4X93FGzRXP0i39" +
  b"ejN2c62IYCPzmxylJpidNbnS7PHOteiy9VLq5bislCt/HaNQKuABLDYtdGYhF1SIap/Tn/rczrnRV1km5JHlIkiT6giDjHXXu/pH" +
  b"uVSgzsK3UtyNoi2SRx4KKdBfX/LOotm5S756Q2/vXHWWie7Be7jiq7UG8JTRr1fsF61U1gmajj247rMqpnptWeSau+Foka1ejc9y" +
  b"yztbudyLmao5++Lmno+j0WUZMVFykr0wTdlRXjyW7VREqyUqLlJDJit2UlemS3cUV7CYrVREq0xW7KSvTFbsqK8eSlTKIlW4AAAD" +
  b"Mm1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAArEQAADOuAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAA" +
  b"AAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJddHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAA" +
  b"ADOuAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAc" +
  b"ZWxzdAAAAAAAAAABAAAzrgAABAAAAQAAAAAB1W1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAArEQAADeuVcQAAAAAAC1oZGxyAAAA" +
  b"AAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAYBtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYA" +
  b"AAAAAAAAAQAAAAx1cmwgAAAAAQAAAURzdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAA" +
  b"rEQAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAABDwAAAQ8ABYCAgAUSCFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIA" +
  b"AAANAAAEAAAAAAEAAAOuAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAOAAAAAQAAAExzdHN6AAAAAAAAAAAAAAAOAAABFgAAARYAAACu" +
  b"AAAAnAAAANcAAADfAAAAqgAAAI8AAADYAAAAxAAAAKgAAADJAAAAyQAAALgAAAAUc3RjbwAAAAAAAAABAAAALAAAABpzZ3BkAQAA" +
  b"AHJvbGwAAAACAAAAAf//AAAAHHNiZ3AAAAAAcm9sbAAAAAEAAAAOAAAAAQAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAA" +
  b"AAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI="

///|
let pins_fmp4_seg_b64 : Bytes = b"AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAuBtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAKxEAAAAAAABAAABAAAAAAAA" +
  b"AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAB43Ry" +
  b"YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA" +
  b"AAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAQAAAEAAAAAAVttZGlhAAAAIG1kaGQAAAAA" +
  b"AAAAAAAAAAAAAKxEAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAEGbWluZgAA" +
  b"ABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADKc3RibAAAAH5zdHNkAAAAAAAAAAEA" +
  b"AABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAKxEAAAAAAA2ZXNkcwAAAAADgICAJQABAASAgIAXQBUAAAAAAPoAAAD6AAWA" +
  b"gIAFEghW5QAGgICAAQIAAAAUYnRydAAAAAAAAPoAAAD6AAAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oA" +
  b"AAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAAAKG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAGF1ZHRh" +
  b"AAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAA" +
  b"AABMYXZmNjMuMS4xMDIAAAAYc3R5cG1zZGgAAAAAbXNkaG1zaXgAAAA0c2lkeAEAAAAAAAABAACsRAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAABAAAK2wAAMACAAAAAAAAAmG1vb2YAAAAQbWZoZAAAAAAAAAABAAAAgHRyYWYAAAAcdGZoZAACADgAAAABAAAEAAAAARYCAAAA" +
  b"AAAAFHRmZHQBAAAAAAAAAAAAAAAAAABIdHJ1bgAAAgEAAAANAAAAoAAAARYAAAEWAAAArgAAAJwAAADXAAAA3wAAAKoAAACPAAAA" +
  b"2AAAAMQAAACoAAAAyQAAAMkAAApDbWRhdNwATGF2YzYzLjEuMTAyAAIwq1zpDEIOrU3Ob4mum4NFRdSmSdvZIgAShIIphEnJIrYS" +
  b"ZCIxkkgxLtlZ2ypDcDJ5vYWfhsHmUXHtOXLceTXUUwiFZJIiMhpJsYjJESJDx7EJDYRYEkUn8X8N9h9q+w/TvWfiuwe4uueMuI7i" +
  b"27o7RuqsR0NzD112Tzds3Y2ydJbBzFqnFuM71x3etp3rE47G2K42bQcVcbFYblO2qdtU7WqzPUs9oNiuNisNysNqnbVGvz7HUral" +
  b"bPr9G00bVmtNGvz7HQraFVQqpSuUrlK5Su1eGrHVjq0atGGjDRJNJNVNVNJNJQ9ElEk0k1U1U1U0lElElElFU1U1U1U0lElEUUUU" +
  b"UUUXAWaY2TbrNROLcJqStxUj/T/vri2Fxerrv19dBer1/XoTV2T+t8L41cqQYr0YePLcimsQ49gpMwRHXZMkmGT5tJ6KqxA/ZluN" +
  b"jnge5PthjkjvHRrVU6dqlP/G/Vrt3/k6JBga7kEhIMDO4SEgwMDO7hISsGBgZ3cJCTgMOZd3CTjQMyDXnd8gkJyXkHPkr+3ol1qd" +
  b"2JF0BPB7e64Pm1A4CVikjwv1OZY64pqrX1O3NLNtuFkyUppVJmul2kmkmxwxrrZ2kmkbHCmt2dpJnbGtndnZ2kZ2dscGdndnZ2dn" +
  b"Z0Z2dnnQrKiL6c7xAAgQdvvWTNCJdPnTPE3pu/QK6LGi10WMTOilElElE/KdEhITMlCUt1Lg01wBFvYs9JYpF1RGQT1vv8v188an" +
  b"FXmt3dXuRHnJJET7ytK42IDxjTukcR7hxHmF28i/CObvLFvqsquQdl2nqvGcTGrU1mxWKsUcqPFazrVqZJOGZNscZmB68MMMHBsc" +
  b"ccWQHrwwwcT/Hw2n394T/Hw2n39yHx8GT7+4Vj79s1LlbtjsORzMwK9FONvtw4tRopzc/Q008ev46kelmPlW25eNdJ3mNXdWL+EF" +
  b"aaqE28AA6DYtLMgLE0LB0TC1ivWf/2ft/P/l91w79svLkiU/aVKq81uZqpkE9SC/pBVlUzdxziyhQvDwC9dH74+nD6e3jw46qKpp" +
  b"KXR0qQUBpZlSQxAHNq/F0gwO1SNoJCXJM3Y3zkwLhZRayaCbLnVlGFBdJUkoQNGnOgsBWLWW3q+t1hARU3JCFryNUuSI+kmSpwzl" +
  b"ky0E9MKdmNKzsR8A5jYs8FZMBY+hQ+hIOlfp8d//xev/08/P41xukzrEsFR+1MUzIqKFO3MhRRy5kGZvCTpYqEaHiKLx7y1b8qxw" +
  b"YZWlspd0TXNB23le95MLOZQ5V0vt/ggCRHF2BCO9HzRK4GiEFELJUa04DYI9diCsFhBMFMX2TxZQSGBpNdqK6BecbZm5Xu10WJb4" +
  b"IwEIA4aOWbHfljfU1euH/hNqs+H+nwfoc0/79z8rQROF7OXVYffPJwUPhVrfTiciY4xremMKJ8qhD0UCPb7xa1RWVx9jirvPlRn0" +
  b"8ADgNi0shVociaEiPzOf/7Pr/8/bXfxS08+tuN8GLwSlCBKB2r68srTpcRWcE35aV0zWh6io4XE/XFJN9vhq8KppJpJq5pJnoqh2" +
  b"eaRmsGea76cPDM1JVpzOVY4XHvmhMXEViW+HH401NzmdTDozpnCqra/XGKG6apM/LK77/HGMOzlVShqMbQxz869TzsfB6D/47l4E" +
  b"udAW0u9zzLCzjo/TGDMvhEqRGW7jlggc17bK9gI8hJgdkMJWV9c8WEwhTsrFkmaMurrWpWYWQO/SS4SjNgAZnq52MntnB+sKO/wA" +
  b"3DYs7PRGhQWhQOhEOhQOlf1m//7Xv/8/zdcZ1bVc1rFQyXkDlVGLVAU9vFkzQI2dOt+T181Hugiuzv7O+y7O6y0yMliy6kVyvEFq" +
  b"wRkIJDAFGvoYi5CzC0AhGEqxlwOCWkvGUeOALYditQL9Awtt03JnkxaVXu5Gbslrph336+b65ilbetwhdHWkm4gt8lwWXYsosQ6j" +
  b"hPr89Gqn+yOfUUip09a9Sfq9jwDoNizUZkwFB6Jg6Jhax9vPv//a+f/n9/N3rao0yXvW364y6UqVJRQZizCmSxaKjzGoz6PiC77A" +
  b"80Zjmsc1jmqpTJNWzXHCaRnxkYmdnZ6XYJrW1Mvdgy3uhGIIbm8QJP9U0BiC1ktXI9t+Q+xDVCHuhh5yOhJ8MQcepWBrSceVxGtd" +
  b"80NcwUVPbXKhYKb8AOY2LPRUNQYPoWEhNCwdCgdCwdK53n/97v/3/04r425uziqiZb/wxJGxUwD7gW1hbVGXJSCfBUSNVtUBcfGY" +
  b"+sK1GPsFbfFahe46Jq1IILhlDwPXxTDTFfy5CGCMoihehENwYHhRMAMTphfRUSmSF0uBkR6LeSyEQEbyliWQ+We+emUAISjipYPx" +
  b"iwTlgOjQBA7yV3v1KFo02wEgng3+4DAr4eavTedMr+KCciSt8/KcV8eqgj7foQKaTflwthHqo3zmlloTvrCwF0sZKSM1iAIzRqYw" +
  b"K9y4AOQ2LOzlMi9IQdC/t7b//vT/v/NzV1vizNTvhvXfGLqkUgFGQca8bCjMLEJNjKdgY/Et6nDu6+7r7se7HDHuxrprpE3Z2el0" +
  b"rvkaVoaSlVKvowGBjeTPMBlETVXnVwq2EXtzvd95OrMaVUzEV1ZZ0vfppkiFAPnpfkQYM+zsUYo4wWKXHJJg63Xeu9BHS/6jw4y2" +
  b"KmphceIMowrNvG8q4+cSaJdCtzsqPs8OPCZk1E0DvRbwLQVBpDNbNdBiNMX8QZZxwADkNiztNB6FgmHRIHRoHSvzl//2f2//H+Y6" +
  b"3xk4crqRUwf+t1JVSpSoKZwpcvXLxd6p/1e+l/ClK9Pr9OzhR6dnDRKgo9DoKPDw6Sw86zPOKCY09xCzohwgoRlA1MdGkmeDvQgt" +
  b"gxWu3BmNilYAYUZqggzNnAadb2zyVWh9+lL6djrOjCNI4JdzO0wPwSZImrOj5W1YQ0tRTTlfJnR9Mk6LYh5V0uFQvwDgNizstysb" +
  b"QsXSEHSP4v1//Zn/8EviZF0kvK1l7vICkxQ2VB3F26iQqSE2cvfHSSgNl2Q9+7z+7dr3e7z9e7HdrrprvrOtazkOs7WdSStnvhC+" +
  b"lijWit7HOZx3NbJyfd8nO5Qm8rmNYy7jmCdrQkNVOlaRqwuZXUSHrlSpgS0KyJmpWVpju/uJKFGIOCag1KJBmJAUjQZTeCuvcDlV" +
  b"oaML3ovoVEe6y24atWYMSVc5zdHpMROU6HcFmM0sQq5hUyMJ5fyTakr28AD0Ni1wVFEQXGb//D9P/16ldZTJz5q2WSiUSr3KuqUP" +
  b"lbWDRAf/P6R5/rLdaznUUsGmku4OAdv6szLiUgxvzRuPWGG7ro8/cZdhRnRJ9CWkS+Q2hClKR5D8o0Z5AMj5z4AYWBuxuo0l4+jI" +
  b"3Zj0QOjIzYNm1MBM17wi/dP6Opwg7QfhD4eCywGlcZzd7zFFfpLx7Jq0UXVpnhf3cUbNFc/SLf16M3ZzrYhgI/ObHKUmmJ01udLs" +
  b"8c616LL1UurluKyUK38do1Aq4A=="

///|
test "playback pins: MPEG-TS walk is FFmpeg's packet order" {
  let data = @libavutil.av_base64_decode(pins_av_ts_b64, 1 << 20).unwrap()
  let mf = @libavformat.MediaFile::open(data)
  let rows : Array[String] = []
  while true {
    let p = match mf.next_packet() {
      Some(v) => v
      None => break
    }
    rows.push("\{p.stream_index}:\{p.data.length()}@\{p.pts}\{if p.keyframe { "K" } else { "" }}")
  }
  inspect(rows.length(), content=(
    #|23
  ))
  inspect(rows.join(" "), content=(
    #|0:1250@128090K 0:28@137090 1:285@126000K 1:285@128090K 1:181@130179K 1:163@132269K 1:222@134359K 1:230@136449K 1:177@138539K 1:150@140628K 1:223@142718K 1:203@144808K 1:175@146898K 1:208@148988K 1:220@151077K 1:165@153167K 1:204@155257K 1:173@157347K 1:180@159436K 1:240@161526K 1:12@163616K 0:65@146090 0:68@155090
  ))
}

///|
test "playback pins: MP4 AAC decode trims like decode.c" {
  let data = @libavutil.av_base64_decode(pins_aac_m4a_b64, 1 << 20).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  // 0.3 s at 44.1 kHz: the 1024-sample priming packet is discarded (and
  // consumes skip_samples), the tail discard padding cuts the last frame.
  inspect(audio.samples()[0].length(), content="13230")
}

///|
test "playback pins: fMP4 AAC decode applies skip_samples" {
  let data = @libavutil.av_base64_decode(pins_fmp4_seg_b64, 1 << 20).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  inspect(audio.samples()[0].length(), content="12288")
}

///|
test "playback pins: MPEG-TS AAC decode length" {
  let data = @libavutil.av_base64_decode(pins_av_ts_b64, 1 << 20).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  inspect(audio.samples()[0].length(), content=(
    #|19456
  ))
}
