///|
/// Two-program MPEG-TS (two independent H.264 videos). The demuxer must
/// expose both programs/streams and decode each program's frames like
/// FFmpeg 9.0.2.

///|
let ts_multiprogram_src_b64 : Bytes = b"R0AREABC8DAAAcEAAP8B/wAB/IANSAsBBkZGbXBlZwJwMQAC/IANSAsBBkZGbXBlZwJwMudU5In/////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////9HQAAQAACwEQABwQAAAAHwAAAC8AEggnpN////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R1ABEAACsBIAAsEAAOEB8AAb4QHwAHLp" +
  b"2qP/////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQAw" +
  b"B1AAAHsMfgAAAAHgAACAgAUhAAfYYQAAAAEJ8AAAAAFnQsAK2hHsBEAAAAMAQAAAAwKDxImoAAAAAWjOD8gAAAEGBf//P9xF6b3m2Ui3lizYINkj" +
  b"7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xh" +
  b"bi5vcmcveDI2NC5odG1sIEcBABEtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9" +
  b"MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09" +
  b"MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hRwEAEl9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBz" +
  b"bGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZy" +
  b"YW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9NCBrZXlpbnRfbWluPTMgc2NlbmVjdXQ9MCBpbnRyYV9HAQATcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9" +
  b"MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6DGABbEIR5QUb" +
  b"jiYytAf7wArTYMxjbUICBDIgIEYADkZeFNUQZhKAlF/+HAQEMjgAEwACGdGCTBTFPM0lIT5/+0QXopKGFU1A3r/8OAgIxRkEqDhKCkcBABR856vD" +
  b"gICMA8AAqgUh6tJAz1++URBog4Qgr876vU4JcKN4h0p6vSAAFVCEOVhIG/v3yQAAnh2NRbQZy/fAgABAGAAMBxkJAAEAUEACAAN2Mo0SpRfDHFux" +
  b"uLZAB9ixiR+sYFie//0cAAlQYiphGkAGYBXNCTLOPG+CWRpNBWsiFk9VsACDSZ//tYQD6EyjwTcO/uC+AD4auDrcsPqIXuMEP2AK0xCsPNtQCsLQ" +
  b"UgX1KfctX4gAAIAsRwEAFQMUnIICAhkcEBDJAAAgCgYqWAEwvTjjdeluzU90oNDijOImCvq9Sx4Oq1PAKZ9XsAD4zCmIpoNbKdPQBOGdag8ozVYH" +
  b"cXDq5TgCver1OFznB1OBT3q9ACcM/lB5T1VsAPHMGX1rDmymjwVBHCABYDh1xoOxyA5cX02ADpeAouQPYImJWiBIif/fYNRmegPWt++07MIoteQX" +
  b"4vb+ip8QlL67Abodi3lAeY7/1gS9kbKEuIX++DGADhlHAQAWgUepuSr3vvrgvcBCOgjI6CM6GZMFOUSdpKwtB/+0Iy8Keog7CVBaL/8OgjI4AIAx" +
  b"nQzJgpyiTtJWFoP/wdEQNkChSC6Ij6vUZAnQKFoLIiHq9IAAXUMQQrCQFo375IAAXQOQSrSQFIX75REDZAoUguiI+rwLjDRRkuLcb6vSAAF1DEEK" +
  b"wkBaN++MARzEueag6ggCAAIDCQABASCABDphiMCI9AGDamDXEEurtzAxv/YAAMDoEPWmNkcBABenoERRFsjFDLQn1/+YSDVEDjamA7KBxeSA7KNY" +
  b"AASKFLuhtTwNc6Pa4vzH/6F1ADkN2olwPPw6PELwwBWmIVh5tqgaglHJ5hWP4Wr3+EBAQyOCAhnRi0FI5pFt8Xx/+0QvRSeYRTeF9f/gXmEozkOK" +
  b"Bqnq9ThKBGi+IBtF6vMAI5qHA5RB1YwDQVzUW8HD0VHylDQCNFcRDaP1epwlAjRfEA2i9XqAHxGM6mgsetX79QA8KxvW0FD1RwEAGIv34JgAQAFC" +
  b"AAEAAAMAocP0vQWdXQQvMTQlD4NqegbIcpxNQLpHyT/+UAAJHBChCg0VcINDOInjXGjJqtMJAACASVAHAHjanoT1EMdwzaucfzAABUR54vcBtTDD" +
  b"g4EACIAAEE9MHAQEY8cBARj/44CAjEcBARj4gABMAAkQAA0ABZCEC3GQACmuB0IFuFQACmuCIKBIAAqNcHQUCgABUa4GMeAlAUame8AsRACx/8QA" +
  b"sRACx4YAVNBHAQAZoANDlO4GS7mQIi3Aw4iLcwySJAAQABADKHgdF9Y+PfHiR5498e+PPHnjxI88eJHnjzx5488eePDAgGAAiGACDj7weKADxAec" +
  b"AHlvyCwDoDvw5YB0C6jwEoCgcme8AsRACx/8QAsRACx4MEWIAAIBgAAgHz0VnGS7mQBHKueHAjlXMLOADi5ACWgJxkXwQIRH3M3AFFpAQrTbUWBA" +
  b"Uzg4EBTIOAASAAKZEAgKxjgQFY+EAgI4HhAAGUcBABoBwUJACL1dMxQjoHc41XeEERLhaAmAAhMjIG7dSBj/kjIKZ42EVm6RAACBR9wsAA+AAIED" +
  b"AXwAEkgsQOhAtsgmLmoWRACxAFFoQjTzbVlhAUyDhAUzLAIArEHAIArHwgAC4MGDoQABIABTwEAUXBSb8OdgQABAoRLICcS5gQ2REE7lEQ8oknOW" +
  b"QAAVAIC7mFnAAQnYE/ieNDSiiIynEGDwZkHgzODwZkHACAOZ/whAAECcwAAgaBAARwEAOzAA////////////////////////////////////////" +
  b"//////////////////////8SUArA4ACBAmWAygAOqgguX2ssQEwUSlgFYxKfDcte7WWABAArAXwAEkgsQKhAtt5EXMwwiAFiAKLQhGnm2rLCApkH" +
  b"CApmWAQBWIOAQBWPhgB9hAACAiAAIFABABcCi4ck/ELwIER5ZBDEuYC4mKcqjOIFp42SIAAgUIlkAACAMAAIAYARc4BHQAARAACwEQABwQAAAAHw" +
  b"AAAC8AEggnpN////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////0dQABEAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////R1ABEQACsBIAAsEAAOEB8AAb4QHwAHLp2qP/////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQQEwB1AAAHsMfgAAAAHgAACAgAUhAAfYYQAAAAEJ8AAAAAFnQsAK" +
  b"2jf58BEAAAMAAQAAAwAKDxImoAAAAAFozg/IAAABBgX//z/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4yNjQvTVBFRy00IEFW" +
  b"QyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbEcBAREgLSBvcHRpb25zOiBjYWJh" +
  b"Yz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9" +
  b"MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9t" +
  b"RwEBEmFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50" +
  b"ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTQga2V5aW50X21p" +
  b"bj0zIHNjZW5lY3V0PTAgaW50cmFHAQETX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4" +
  b"PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAABZYiEOgxgAWICIeKywqrGR0JgKwAVpsGYxtqEBAhkQECMAByMvCmqIMwlASi//DgA" +
  b"EwACGRwACYABDOjC0FIQ0q2pG8f/tEF6KShhVNQN6//DgICMUZBKg0cBARSEoKfOerw4CAjAPAAKoFIerSQM9fvlKDTCjOI9K+r1OCXCjeIdKer0" +
  b"gABPjMYimg3t++SAAE8OxqLaDOX74EAAIBQABAGHQgAgAOBggABuxlGiVKL4Y4mSZMADKNqdjEj9YwLE9//owAF0EIqRtTADMArmhJljCQAbo4AK" +
  b"Nqdk9VsACDSZ//tMAAFRPNE1kNqYXwAYeYHDumi/Qo06zHHUcEBDI4ICGeMWhxhu/T3dqeiAABAFAxUsRwEBFXAAgApkcACACmQ4AAgCgYqWAEkZ" +
  b"eFPEoLUR019GlDxzgyngp/1eBzHg6vU8Ar/q9gB8xgyupYe2U2egCcM71B5T9VgXmCcFIUQcAKW9XqMgTlChaCxQQ9XoABClHqIB5Raq2AAaByCi" +
  b"VaSApsogeCAAEAMBgB4sEQEYABg2AB8uAUXMHtyJgBNpzhAVYwSyMpAWlf99gGyCrbqh9ozS/fCpLjEhfXTUzcI6z7YGudH6hbmFfvsCXkZHAQEW" +
  b"bOCbEL/fBjAB9BhUFgptB58ukRuAKDgAgDGRwAQBjOjCTDlIeZr0j/P/2iCXjlocZj0D/v/w4ABUAAQCDI4ABUAAQCDOjFoKRzSLb4vj/8HREGiD" +
  b"jvJ/M+r1GQSoOP8l8x6vSAAFVGc5GPAv9++SAAFUHc9GvAr1++UoaYUVxHpP1eBzGnE9hLCfV6QAAjxGM6mgvt++MBFI9jSUHUEAElADhAAGhwAi" +
  b"jEwBEWADDamEsE+pIG9PmEcBARcAAoLxwqkxtTwE3MU2IBMiX/vmoD4BihtTBvMANvihQTZfmAFOU9g2p4BuhyHUoH2aI/fBZwcAAQIgABAGAgAG" +
  b"0zLAAKgACAIxBwACoAAgCMFgAEgACsFgAEwACMDgAEgACsDgAEwACMQcAAqAAIAjEHAAKgACAIwOAASAAKwOAATAAIwOAASAAKwOAATAAIwIAAgA" +
  b"NEAAEAgAAQB5CEC3DwAJB0IFuFgASEQUDwADZDoKBYABsj4gRwEBOH4A////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////////////////////////////////////8A" +
  b"CCMD8IAwAHDAwADIDVGElgACAOAXhgAFgGqGAAhCpZLiEuDkuOS7KDoTQdCqDoVQdE7meyZ47YBHQAASAACwEQABwQAAAAHwAAAC8AEggnpN////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////////////////////////////////////////////////0dQABIAArAS" +
  b"AAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////R1ABEgACsBIAAsEAAOEB8AAb4QHwAHLp2qP/////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////9HQQA8RBAAAJ40fgD/////////////////////////////////////////////////////" +
  b"////////////////////////////AAAB4AAAgIAFIQAJZQEAAAABCfAAAAABQZogWvBhA2hcyZkyUgyjGsIAAQEQAUGkwgADAMISAAeIRCEB3OPD" +
  b"Uip0+7FxHhUtImPVejVtrFKlSSlAAK7M2CdzAiThTClfHHVUVyvt2m+/oJy6xX1wk5dauEdBATkHEAAAnjR+AAAAAeAAAICABSEACWUBAAAAAQnw" +
  b"AAAAAUGaIHrxsBdSCqmSTJkpAoNgTxM5a1BghNJzewzj9uGdeVVZJEaGUr1u0Z1EmiQQAAgPgAFAWdCAAPACGBQADwiGEUPSSfPsHxt7IIZahK9E" +
  b"4wYy2p3nYlv3KklEUhbIAA+ZjfjJS4V1okQgXjqEclXqoVym7drMZKiiR94MLBnINAMOxGEmiUUYCBghhNIh7Yf/ggmILiCQRwEBOoUA////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////F5RhMMMAqBY+JBBqgSGnGjVy/eoBauJTpBpUKy854JtjMjMjMjLPqmH1" +
  b"ix7ur3+utsBHQAATAACwEQABwQAAAAHwAAAC8AEggnpN////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////0dQABMAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////R1ABEwACsBIAAsEAAOEB8AAb4QHwAHLp2qP/////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////////////////9HQQA9BxAAAMFcfgAAAAHg" +
  b"AACAgAUhAAnxoQAAAAEJ8AAAAAFBmkAivGzlXYf6g2c2YB2vDOjS1VI1G4bWAAlXGqhrCAQV7QgjIQAC8+A1IbAkZdZJYUc/NyrYIJOs2NXU5/qV" +
  b"mUPIpP39QAcMzYHfl356UcvSjPrZqJf9U8F2c7v6vDvGxWJMLMQXEFY1YAAoUAO4iixjW9XysEDKEDgmHJgwIyrEQ2Dfjfaa2nQmIok0SQrRJzpY" +
  b"E1EArUcBAD5VAP//////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////4CBokBLwQxrw/8fD2lLZiC4gqQtqAtwA0AkRsRxVxe9YyCSc4wauJeJcCBvnp2RmMjMf64Z4VUHKwEH6vo/8F93IQWEGVTKpOCu" +
  b"CC8/8/KRjIwv+HaoStZCCQgveUUjbX/gR0EBOwcQAADBXH4AAAAB4AAAgIAFIQAJ8aEAAAABCfAAAAABQZpAKrxuLi5wACANOGUhq1BgJk+9N0wA" +
  b"gc/IsxGxIXAgypjZInUcHrkHdygmxAmCABOHWERMIABjAHlCbpDlOmdcQRBGZhJa6Jf/+CEknJGd+99rcz2krRMAAVIcjuryCyFiE2Haumj/+RfG" +
  b"0om1X16VyV43uJGI441Nc5QpJlgxgEWmscPBuMrggTU8r3OQJg2GA7dbju9HAQE8cAD/////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////////////////////////////+3ZdJ7Tw8b" +
  b"4+H6SSwDtQB3ShMFGChQABtDAYrD/+cEAvkjTcvnqMQlhlRCVEJ/Dbh4Ux71dXe9XV3veSDJkKSHvPsLRXd3gEdAEREAQvAwAAHBAAD/Af8AAfyA" +
  b"DUgLAQZGRm1wZWcCcDEAAvyADUgLAQZGRm1wZWcCcDLnVOSJ////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"R0AAFAAAsBEAAcEAAAAB8AAAAvABIIJ6Tf//////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////9HUAAUAAKwEgABwQAA4QDwABvhAPAAFb1NVv//////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////0dQARQAArASAALBAADhAfAAG+EB8ABy6dqj////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EAPwcQAADkhH4AAAAB4AAAgIAFIQAL" +
  b"fkEAAAABCfAAAAABQZpgLrxs+zWE9A6jrgm+OsHlx8NKEC6aGdCOEL1eXhBAWeVn3cE4b/fAwACw4lhEPhAAKbKyW0zCTrmq9RGT0R5QlvYXtIf/" +
  b"uGAo5zyDez0JEgBle0n7dXWtrR3qNekYri+r2g0ILN5PSyoFv/3h+oYlhQmodunIyCAMHUcLlWjUE3m0kTZlGq6lzsBoGvECCASoVCWw0ExHAQAQ" +
  b"mHdQyNZ4Lxt3Dq5BKuQdJKuQ9GGMUBUBMYDSc+gIh/HPhuH5OtJLK3GkSdYtgO6Dw/Swi4L0CJ+LVXAoM7Y58XkugasQjPELUMB3DAV/7iLY9AdY" +
  b"yUvC1973kljcAZPhSBRiCsh6i6c+NnUUR1D1B1HRURlB1FEdQ9QdRRURlBiq06rTv/G/glIo6rQlIo1XKyuin/wrWEzluU3Vc0yb7tBB9kCN83J2" +
  b"4X/rCF4W0JQ+lhZqvoH6hEcBADGVAP//////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"///Yfjb0Uyh6KTqnonYnonYnPoIJeNhb8M9ofFgUhDiE9F/wR0EBPQcQAADkhH4AAAAB4AAAgIAFIQALfkEAAAABCfAAAAABQZpgNrxsMQXA7EHZ" +
  b"QbSuMpBCwAgMFAfIBVHMb7cmMO3/nf384YDQZdNwB9FEAxyX18tjISAA1cMAAhoAAV8Fhnr9eNU4jSQDcOL5jlUGoLnGCTKdiesj8/CBLyjIXuI1" +
  b"OqAAJsbJt0UpS0kD45quR7DIeaQ/8389SI/7RCVzELUbvzO8b42JFw+PxtFr5YqcUUjO4SVmTklHAQE+UgD/////////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////+YzBDOGSwXjQwEt4UBiGQgCZYbm+N8jfHe" +
  b"YIb47zGhRdXfg7luDuKwT5QT6AsbA7cEfKiiJ2YSjRw8vPecW8bf9/69/L39/v8vfy9/R2AwxXGIAyZCkuevzmLzE5i8xY956iovwA=="

///|
fn ts_multiprogram_md5(yuv : Bytes) -> String {
  let digest = FixedArray::make(16, b' ')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "ts demux: two programs decode independently" {
  let ts = @libavutil.av_base64_decode(ts_multiprogram_src_b64, 100000).unwrap()
  let demux = av_mpegts_open(ts).unwrap()
  assert_eq(demux.programs.length(), 2)
  assert_eq(demux.streams.length(), 2)
  assert_eq(demux.programs[0].program_number, 1)
  assert_eq(demux.programs[1].program_number, 2)
  assert_eq(demux.programs[0].stream_indices.length(), 1)
  assert_eq(demux.programs[1].stream_indices.length(), 1)
  let counts : Array[Int32] = [0, 0]
  let pids : Array[Int32] = [0, 0]
  for packet in demux.packets {
    counts[packet.stream_index] = counts[packet.stream_index] + 1
    pids[packet.stream_index] = packet.pid
  }
  assert_eq(counts[0], 4)
  assert_eq(counts[1], 4)
  assert_eq(pids[0], 0x100)
  assert_eq(pids[1], 0x101)
  assert_true(demux.pcrs.length() > 0)
  let refs : Array[Array[String]] = [
    [
      "f3936bd3d203e94846a56dd090f73e14", "377fc6113202bd20801d6f732b03888a", "599d33ec31fa4d6c7bcf62c485821594",
      "6f8bcbfb32be20b2ca2bc6f611b0245a",
    ],
    [
      "9ea69968f09a644cfb948af5cad0e88b", "cb6f3534b1379d99c4aced89cb3e03ae", "a3a3742b87cdf658dd6df6a60b7c88ec",
      "69186ca1edd89f9d91df2007be66ff90",
    ],
  ]
  for stream_index in 0..<2 {
    let payload : Array[Byte] = []
    for packet in demux.packets {
      if packet.stream_index == stream_index {
        for b in packet.payload {
          payload.push(b)
        }
      }
    }
    let dec = @libavcodec.new_h264_decoder()
    let frames = match dec.decode_annexb(Bytes::from_array(payload), false) {
      Ok(v) => @libavcodec.h264_display_order(v)
      Err(e) => fail("program \{stream_index + 1}: \{e}")
    }
    assert_eq(frames.length(), 4)
    for i in 0..<4 {
      assert_eq(
        ts_multiprogram_md5(frames[i].yuvp()),
        refs[stream_index][i],
        msg="program \{stream_index + 1} frame \{i}",
      )
    }
  }
}
