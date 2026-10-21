///|
/// Tests for the MPEG-TS demuxer slice.
///
/// Reference files from `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "testsrc2=size=32x32:rate=2:duration=1" \
///          -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
///          -c:v libx264 -preset ultrafast -g 2 -bf 0 -pix_fmt yuv420p \
///          -c:a aac -b:a 32k -f mpegts ts1.ts
///   ffmpeg -f lavfi -i "testsrc2=size=32x32:rate=3:duration=1" \
///          -c:v libx264 -preset ultrafast -g 3 -bf 2 -pix_fmt yuv420p \
///          -f mpegts ts_bf.ts
///
/// Expected PES rows are `ffprobe -fflags +noparse+nofillin -show_packets`
/// (the demuxer layer, before the H.264/ADTS parsers split frames). Note the
/// emission order: known-length audio PES packets are emitted as soon as they
/// complete, while unbounded video PES packets are flushed by the next start
/// or by EOF.

///|
let ts_bf_b64 : Bytes = bcat([
  b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgMAKMQALrSERAAfYYQAAAAEJ",
  b"8AAAAAFnTUAK7KS2AiAAAAMAIAAAAwDB4kSywAAAAAFozg/IAAABBgX//4rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1",
  b"IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gy",
  b"NjRHAQARLmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1l",
  b"PTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4",
  b"ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIEcBABJjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxv",
  b"b2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21w",
  b"YXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MiBiX3B5cmFtaWQ9MiBiX2FkYXB0PTAgYl9iaWFzPTAgZGlyZWN0PTEg",
  b"d2VpRwEAE2dodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9MyBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9y",
  b"ZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9y",
  b"YXRpbz0xLjQwIHBiX3JhdGlvPTEuMzAgYXE9MACAAAABZYiEAOgxgANHAQAUsQxR4UmWO1/oqCYGeAFabBmMbahAQIZEBAjAAcjL",
  b"wpqiDMJQEov/w4ABMAAhkcAA2AAIDRnRhaCkIaVbUjeP/2kL04/KdS+PW//DgICMU4JcKN4h0p6vDgICMAqAaDuei3gRLH/fUoNM",
  b"KM4j0r6vU4XxwdTljvV6QAAnxmMRTQb2/fJAAHHMducAZV++BAACAcAAgBQqEEAcYOAAbsZRolSi+GOLdjDm/QBSeLGJH/jAsSj/",
  b"/SAAx0cBABXGGqYN0gAzAK5oSZZy0iDOVyIFgSzgh9MyqARFSFf3sYDnNXCybtf/cF8AHD4pZZYHqlWQW55KWoNRwACwAAgHmQHa",
  b"AJhQGrm2rgzJgpxZJ2krOLIQAAEAGAzk5BAAgApkeAZkgAAQAQZ0sAJQvRST2EU3jktoiBs4UKQXcEfV6iMNA7vcWAQ76vYABqGI",
  b"cQrCQFrkET0AEdxnuDyDtVgXmEodyHFAEKer1OEpRRfECRL1egAR3GocRwEAFh5BSq2ADwrHN62gpchw8EEAAQBnAACAgEQB4fFG",
  b"INsR7HB0ZvXBG1vQCObQIiiLZGKCKQn9/+wGmOU6kA+TJX77qzE9ucIT1r48b4NrLJoOls5ga50e1wLMV/64EVTMSwoyYmODDhwA",
  b"BAGCgACBnQcBARh4BYHAQEYOAWP/HAQEYOAWBwEBGDgFjxAAQAJEAAKAACAPJhD3CwA6BUIe4OAHQICOKuCAAFywDhHFXBwAC5YB",
  b"dx4AB0hHAQA3dgD/////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////////////////////////////////////////////////////8AOAAICKZ7wCxEALH/xACxEALHiEAA",
  b"QKIhAAEBuIAAWAkBAACQWA4ABYCQHAAJBYEgBD3BAAEBIFABD3BwAEBIQEdAABEAALANAAHBAAAAAfAAKrEEsv//////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////R1AAEQACsBIAAcEAAOEA8AAb4QDwABW9TVb/////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////////////////////////////////////////9HQQA4NRAAALWkfgD/////////////////////////",
  b"////////////////////////////////////AAAB4AAAgMAKMQAPgeERAAnCwQAAAAEJ8AAAAAFBmiIGvGwoVAXTIMQk6tR3p+qQ",
  b"cJep/cfga1kYem9pxJnvMYe9BbZrCAAEAUAKGuhAUIMABIkhD1XmkNGqz3fd719Wplw/d6VSkVCdXgAXBsVEDkeqA72/Np73XfSu",
  b"ae58VRJ7iUdAEREAQvAlAAHBAAD/Af8AAfyAFEgSAQZGRm1wZWcJU2VydmljZTAxd3xDyv//////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////R0AAEgAAsA0AAcEAAAAB8AAqsQSy////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////9HUAASAAKwEgABwQAA4QDwABvhAPAAFb1NVv//////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/////////////////////////////////////////////////////////////0dBADldEAAA8Dx+AP//////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAA",
  b"gMAKMQANl4ERAAutIQAAAAEJ8AAAAAEBnkFCV43AaqdKiHrL3sLED6GkqU9fpLsewMB2FcAUM8O/PK1JqOpvipLak7jcAeaJlqw6",
  b"qajqtJ3dHuKJ",
])

///|
let ts1_b64 : Bytes = bcat([
  b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/0dQABAAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////R0EAMAdQAAB/IX4AAAAB4AAAgIAFIQAH6LUAAAABCfAAAAAB",
  b"Z0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAABBgX//z/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4y",
  b"NjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRt",
  b"bCBHAQARLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5",
  b"PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAg",
  b"Y3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYUcBABJfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVh",
  b"ZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBj",
  b"b25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTIga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50",
  b"cmFfRwEAE3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3Rl",
  b"cD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAABZYiEOgxgAOxDFHhSZY7X+ioJgZ4AVpsGYxtqEBAhkQECMAByMvCmqIMwlASi//Dg",
  b"AEwACGRwADYAAgNGdGFoKQhpVtSN4//aQvTj8p1L49b/8OAgIxTglwpHAQAUN4h0p6vDgICMAqAaDuei3gRLH/fUoNMKM4j0r6vU",
  b"4XxwdTljvV6QAAnxmMRTQb2/fJAAHHMducAZV++BAACAcAAgBQqEEAcYOAAbsZRolSi+GOLdjDm/QBSeLGJH/jAsSj//SAAx8Yap",
  b"g3SADMArmhJlnLSIM5XIgWBLOCH0zKoBEVIV/exgOc1cLJu1/9wXwAcPilllgeqVZBbnkpag1HAALAACAeZAdoAmFAaubauDMmCn",
  b"FknaSkcBABXOLIQAAEAGAzk5BAAgApkeAZkgAAQAQZ0sAJQvRST2EU3jktoiBs4UKQXcEfV6iMNA7vcWAQ76vYABqGIcQrCQFrkE",
  b"T0AEdxnuDyDtVgXmEodyHFAEKer1OEpRRfECRL1egAR3GocHkFKrYAPCsc3raClyHDwQQABAGcAAICARAHh8UYg2xHscHRm9cEbW",
  b"9AI5tAiKItkYoIpCf3/7AaY5TqQD5MlfvurMT25whPWvjxvg2ssmg6WzRwEANhAA////////////////////mBrnR7XAsxX/rgRV",
  b"MxLCjJiY4MOHAAEAYKAAIGdBwEBGHgFgcBARg4BY/8cBARg4BYHAQEYOAWPEABAAkQAAoAAIA8mEPcLADoFQh7g4AdAgI4q4IAAX",
  b"LAOEcVcHAALlgF3HgAHSAA4AAgIpnvALEQAsf/EALEQAseIQABAoiEAAQG4gABYCQEAAJBYDgAFgJAcAAkFgSAEPcEAAQEgUAEPc",
  b"HAAQEhBHQQEwAUAAAAHABjeAgAUhAAfYYf/xUEAT3/zcAExhdmM2My4xLjEwMgACYKVUkNpyMvPHp541XnLlquskR5SSL8wkG3cD",
  b"8F6r2LvuGy2paR/j0vN73q/J4G1MVWNs1prz6yUmmqpiuYqjJpSyUslppSaMlClGSjJRJrQ2htDAxs2DAyJEDGzZs2iRIpTZs3FF",
  b"FFFFFFFFFFFFFEiKKKKKKJERERIRFFERRRIiiiKKKKLg//FQQBU//AE4lEcBARHayV2UU6sp1ZLpz/Ptxps8av/61+/XGuNXr/+1",
  b"4/nzxrjV6//i9/588a61qw3+tjR9FBgLoEywhZ+p1m8pjbnAZzgMDO4TMDAzuEhIMDO4SEgwMDO7hISsGBgZ3cJCTkJsJd/hCrDd",
  b"T5y5XpSt6UJvZm5QkqSzBpQkJJXgaUJCSV5wY2bCQkqDZuDAxsJCSrHLxDUUUUGooooo3G10UcD/8VBACH/8ATryixrXjnv9n7+3",
  b"xbpppeqlRwEBEsjjkkkiJA7n986bs2Y2f3IZPgwz+4GT4MM/vCPj4Az+4HD4Az+4GT4A4P/xUEAIv/wBCDKJ4p1rK+f/7P8f+v/t",
  b"d8XeqvfXv9b8ffbty6lUXmtihdCMCKig1FFBqBQug1o2EsxLNMzrm/NT4O35nP/xUEAJH/wBCDKKIn1Ah0jK9f/37//X8XONcZPO",
  b"68fFePjbuFaykywnnUc6innVPPOedQnnPVlKpvpce6qfleAc8XiYpgoVcP9HAQET8VBACT/8AQoyigKNCIdWqvf/+1+f/X/yXxqX",
  b"J169fd8/jbs8Ml4q6mD5RRLfMaKKKKKKKKrigkRFSq9YlL+hTSmQvQ7ZgF+A//FQQAyf/AEGMpTjXRiHREHQiFVev/6b/1/2l8XN",
  b"Z1m+/v3v2ndw8JJTALq6MOfwcHp16/y1ym1zzzfSixlzD1VLPYdotXf2/0llgLWiN7cjDTreDXYybrcSccQiAySN2RrUcP/xUEAM",
  b"n/wBDDKLOkcBARQhDoiDoRFox6//pd/+3/ter1JajU/T98jrby7yolD6fT6SJuL6fT6fSj6fT6UDXBz+cDbcCx7hkDEPDeFANsMT",
  b"zcp0s6Q90WMUWgJWmO+c1LOBe+tNWsXA//FQQApf/AEAMpzogV6EQ6lmd//3e/+//W5xNXqt8fx+/OdN08tCpMvAiYmGk7D0MbAY",
  b"ePHlzLwzSCL4ZztGlttYmvqLNR1hKbB/BKAqDGQ2jv/xUEALf/wBCjKQljQ4RwEBFatEIdEIdEIdIN//Sf7/UdS5IevjX7fzt17q",
  b"pJVEAGBgbvGU7Ax+Jbj8AYleBiQNmOclX5vdCDmlApTTS+JMvCUL9cBiVoKzsD+bdBev//FQQAx//AEEMpCWMlCfQiHQiHQiPSt1",
  b"z/b9P/b2l610s8Z8O+seFTM85cmSgDSy+8t5DDLQXn9EIoooiiESIlcYYpERFLlOR8tzYUS/B3wJBSYqOjhS2JFJi5PhXzLwhbi4",
  b"//FQQA8f/AFHAQEWBjKQljJIo0Ih0Ik0Ij0JBVW/+O//aXetTWaPz+t/t++3covKTJYCbt326fXMuUBskhrzzzzyXnnk+a0pbeuM",
  b"0SSsZ41yEfhsn1qfS44ThHy2EsdGDDHPGcUO6TbNvS13sWnwThwr1RTlhKsIO9QQ7//xUEAJ3/wBCDKIljI4q0Ih1aq+fz+3/rxJ",
  b"xq+KTnn785xTt7VV5KlXg+lFCFn/TQgXjhAF0UUUUUUUN628LYnrJZiW6RZqOkcBARctJ3nKQLf/8VBADJ/8AQQyiHZRjoRFpRFo",
  b"m0/9O/+f13d8J7b3m/a/z+B4Peoqe1VBPPOYxQiTIhEAFmPQRoN+/fT8N9L3p381L3orS5RpZPImFOWLrhpK93G/5wyVYxUVa08/",
  b"OTDeUZJc//FQQA/f/AEKMpCWMlDPQqc/+N/8/F3q7tKv7fe++Knr2qTILdwBgYG8xF6lRZm370Plx4/Ljxqh+URfIbDvnYqxOYxZ",
  b"b+o5w50r0wuqRwEBODgA/////////////////////////////////////////////////////////////////////////5XLmBel",
  b"awuvFQjr28aXovSslqQSen3N1PbOco1gWt+MJ2daZE62HDvspfkVheU8fP/xUEAJ//wA+jKQdjJgm0Ih1but//t4+P/e7vXGTVV7",
  b"/fPf6PPMpdVKqBGLMmrKPz/ro8b9/vT+xyGLhJQlLhkEhMCtdLHiXIqLd9iSQvxHQBERAELwJQABwQAA/wH/AAH8gBRIEgEGRkZt",
  b"cGVnCVNlcnZpY2UwMXd8Q8r/////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"/////////////0dAABEAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////R1AAEQACsBcAAcEAAOEA8AAb4QDwAA/hAfAA",
  b"L0S5m///////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////9HQQA3QhAAANcFfgD/////////////////////////////////////////////////////////////////////",
  b"/////////wAAAeAAAICABSEAC0hFAAAAAQnwAAAAAUGaIa8bChUBdMgxCTq1Fcg8OAMX/Z/+34A61kYe+z3mMPf8IAAQAwDj2QgL",
  b"MYAD4KZyMcHILDVxM6v1OMA1bGuk8ZKLPgAW0QPMDkS6Ap99GffOeZbpsV0bFVniQEdBATkBQAAAAcAGXoCABSEACd2b//FQQA//",
  b"/AEKMpiWNEDXQjP/wz/f6uau7NbzzXfnczrm7yVKt3BnZ2cMlGUSXYJUjwAkJCQm6E0ysxVaVcpPgbbmvWi/k85rjSSMUklog1eb",
  b"R8P22KwVMl9yUTjimzdp+xR45T3fLxsLnKxHX/wjl7bb1xVXO8o69HKcpEo34P/xUEAMn/wBAjKIdkKOjEWjEOjILmq//D3/f/m5",
  b"rq+t5Nft/PPfxTwoRwEBGqjJe7CiigFYTdHAVy4KKKKDLoMv9T4LMDOwYeRgFqtCnw4ARmaHmowmcMfl4Fq5FPfOnBYX2JJ+AA/A",
  b"//FQQAq//AEIMoiWMkCnQiHQiHUqz1/2n/rV3ri9Kq/n44/P427fDqpkqJg+XNOdl9a93RxuZPPPOqeec+xBP0v7lMiBS97vyTKQ",
  b"vgT+KQJ2ise7gP/xUEALv/wBCDKIljJQp0Yh0Ih0qq+359//a7nHGnFbv3+++fLDuppHAQEbmSqgcYolq3i1Dtv/CjKiiKIuMUXy",
  b"4xTcyCKalKXMSqeJ7BCWrT5apQSVoE+0rUrdqnRRQ4D/8VBADj/8AQYyiHZBjoSDoRDoRJoRFoWJ/2+f+vtbi7u7qvz+H2/nbuKy",
  b"8SFDneeNYcjz/X+rJn0GvXr1z1pzmzz1zulwrElO51XOqUH1rKRRGUPreDejq6VvYTG27Ipe8snEeKf5RTqocptlQy3vwP/xUEAN",
  b"H/wBCjKQljJQp0Ik0EcBARyIdGIR4/45/0/WTWri7338V31THbawzVAJCQnz0NQhohbY0APpRRRRubNrgoStZnWOGXMfykXo8BGM",
  b"rKTlIksCyGawNKdyWlyxNKSt3hyl6Tql2otYcP/xUEAKX/wA/jKIdkQgt0Ih1Ah0Tmd/+nf/X73eprXPDfftXz/Pbx5bXhOFA8/q",
  b"CZQkwtYgVdsAMDAwMXda8b0I/17p0uUXJJnF3m5zoBcIluD/8VBADL/8AQwykJYyaJNCRwEBHSHQiHRmLSD1/x4/3/eXriI1P0/X",
  b"nPNOzbVXWaVKAMDA0ClJw/Fz81D5fL5fL5fKrmy1VVc2U8KKstRgJ9/Eo2Hyg/BRCQL8Yw9pSkiE6rw1O81tvBz/8VBACz/8AQIy",
  b"iHZCUJ9CIdCIdCIdO3Xf/b3/6/zV61fCm/H3z5/nbwPGe0qKgIiiA6j8n6iX6CHKKKKKIkBykoiJhKygSXJLkYRjxpuSpWB8hYK8",
  b"b4DvwP/xUEAOP/wBCDJHAQEekJYyUJ9CI9CItCYdCIdEOf/24/9pJxq5Kve/Zz1jt781WtrlMASEhPfs/rOdCpNQGvPPPPPc/O7z",
  b"sZe8ndeUuS4LS7NVnzjtk+2RIFZGy7uZzrrttlC3TiMu51rNL8c1b6lUkeMN3P/xUEAL//wBBjKIljGOlEOiEOhEOiZX29fp/7Xd",
  b"6vTStfn9/Hr96d1KJmXVQfSihDYoAlqtv3CDL2bNmzZsbNkY+uSMyvSJSWwkmQduV44K9EcBAR9Xpwuj3fhNBe0IZkTfwP/xUEAO",
  b"H/wBBDKIdkGOhEeiEehIWhZU/8eP/nd3q+EtPt7N9Y8O/bdS7K1Q+U85ilXkoUbpGl2iNv37997799733qVb4aflAouc3qJKcU8C",
  b"QJtWLVFQsQGWrq/lR1jSJaX6QvqkgHKhUctJ7iWdUfD/8VBADV/8AQoykJYySKNCItEItCIdEIdCqt/8eP/bhfVy5Mrn758/g7Mm",
  b"7lUmLAMil8xNaQJnQ27XRwEBEAFRRRRRRRRE/CgihgKXK4t68lyCkLX1UlLuJ54b5PEreuRCJDObVM95QWuq81pxv//xUEAKn/wB",
  b"AjKIljQgt0Ij1LK+f7d/9fi7vTi23z+u+frl489Um7q6lB5551vz+27hq2SgAwMDI5a5JseWdaTkSidHc2vOeWFJWnmSBYlwmkVM",
  b"XP/xUEAMn/wBCjKQljRIp0Qj0Qh0inr/Xv/y9pq9SS1ePjfPtDtnM1TKq6ASEhMajPpKwCpHAQExEQD/////////////////////",
  b"m7ACQkJCQkSEzUyuWEIS1Lh0t0zFrWTkxkZS3a5cJSklzqTsFbJTirVsJ04JFtPA//FQQA7f/AECMoh2RECvQiHRETREFmT/8PX7",
  b"/7y71d6rK8fWevxy8PDyqEqUFroMcTBWhaBIqvABh49NNMtec2ATN62FG1LlL+Y/ZM1x6+KfXhSUaNfEF95rMYtE6ps/ZgyEZ5JQ",
  b"AqIgo+JqEZWMYCrmsXzjgEdAABIAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////R1AAEgACsBcAAcEAAOEA8AAb4QDw",
  b"AA/hAfAAL0S5m///////////////////////////////////////////////////////////////////////////////////////",
  b"////////////////////////////////////////////////////////////////////////////////////////////////////",
  b"//////////////////////9HQQEyAUAAAAHABNeAgAUhAAvi1f/xUEAO//wBCjKQljJRrE2iEI3/+D/n2txrVqT7fje/Md8M0od0",
  b"AGBgbvHqdh53Atx+E/NPzTzz/KqI51P7Kn+BeJdJW7nFU76095dReHIBVG6O+vXR9vcVyK8TP41sTUk3ZH2YM+nsloD6XW1WpNHj",
  b"iaZMtSnA//FQQA1//AEEMpDlHQiHQiHRiLRCJvPn/6fx/6/9ZfGuEvOP2/fPz++O+qoq0qYAaUcBARNlwj9friiiiiiiiUWWKaZC",
  b"C/jJSAxpaAwCgKyxQr0jWaOoeeUWQ2a2qWWXJLxT1Ea7Fo7sU4IOy+pw//FQQAs//AEIMpTlHQiHSCHSiFj1//Yv/9dXetcVcq/H",
  b"tnftjt5VV9UVKGcVdWtz97sPPPPPPM83ng9fA6aAPeKgHcVjzkHIAid3XvKABVS26DjWNI+mo4D/8VBAC3/8AQoykJYyWJtCIdCI",
  b"dMIdEZv+/5/+9y9dSS6n5/GfRwEBFD++OvutVeyABM03npbpBLAXi1Cl0UUUUbqNeujnoZz3pS28mJxbDgmSSw276JATQVNBGkTH",
  b"wP/xUEAMH/wBBDKIljKOhEOhEWlIOibnv/0f7/Ua9s01ff2/fnfk7+60CSqE8876hKBSJQuGrQ/XVPOr1nUrUFYetk3QA6QGzqAq",
  b"QqgCsx+oPISATvDNtFqfIm1BB7VEfv/xUEAL3/wBCjKQljKWlEOhEOkHP/jx/t+9zV6TW85+79NHAQEV+dndMl1iVKAMDA3mKU/C",
  b"oMCvfw+Xy+Xy48YvlF8jllm2cThB1AWBZTShQEw5upyPgclMB2LM91jYrFO3//FQQA4//AD+MpCWMlirRELQkLRM33/47/z/N3fF",
  b"y8X+n7979ub8e23pfWVe5gxRy+apz+Kihq1/D9/vu/Zft65y4e10RyOdEETruFWo7wp1MJGlG8FkXwiRVC0FP1CLmbkBzJUMaBI2",
  b"9J44BdZqVDj/8VBADD/8AQoykEcBARaWMlCfSiLQiHQiHRKev+2//L4l6u7l5Xj4v9P3x11VJyuKgCQkTGznUHeByPA+j30+nP9H",
  b"udO5MDHXYGyUA4Ty5Uzoo79sNis64TuJFlN8+RXIbKRPH//xUEAMX/wBAjKIdkGOhEOhEOlEWic1z/x8/j/e5xqdVOPff1zv4x5e",
  b"L6y8Lq8GtdAL0npksheFwbNmzZHZsi2Rjsy22dylz7dByeo/e3b+jns4gXQZTwuq0J7VEuOzvGvARwEBF//xUEAKf/wBCDKIljJY",
  b"m0Ih0Ih1Kq9/+OP+9XeuI1cfn8V9vxTt7qquqXuQc0853rjhKjYprZk8886jzzzqmfR8kRqPOmIxWVyLlF4T45KgXFRw//FQQAxf",
  b"/AE6UpMaQQ6MQ6EQ6EQqqf8fn/fjXXlw4rS7tI4pHnSXcuAPDw9uxYeHh59YAAMOPD1uAACnHh63AABTh4efcAAFOHh63EACnHh8",
  b"Xz/ofKJ+4aFOdJpaEP34F+D/8VBHAQE4KAD///////////////////////////////////////////////////9AEN/8ATiVpssU",
  b"5ss0QyiXGoO2vqcX1q9f/2Z+LhOr/8v7BZsaEk4cd4QElYfcfBKSvbGE3pSt6UJvPKoJyvZg0oSE3rwMDBISSzcGBpQkJCR17MGR",
  b"ShISVY5eFlF+cR41UD8eiDlmv6Y7+MDHn1GqA/tr1j1bNnYuU87zzzz375RRcP/xUEABn/wBGIG0cA==",
])

///|
fn ts_test_packet(
  pid : Int32,
  pusi : Bool,
  cc : Int32,
  payload : Bytes,
) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(b'\x47')
  out.push(((if pusi { 0x40 } else { 0 }) | ((pid >> 8) & 0x1F)).to_byte())
  out.push((pid & 0xFF).to_byte())
  out.push((0x10 | (cc & 0x0F)).to_byte())
  for b in payload {
    out.push(b)
  }
  while out.length() < 188 {
    out.push(b'\xff')
  }
  out
}

///|
fn ts_test_concat(parts : Array[Array[Byte]]) -> Bytes {
  let out : Array[Byte] = []
  for p in parts {
    out.append(p)
  }
  Bytes::from_array(out)
}

///|
/// Build a PAT with one program. `crc` is left zero: this port does not
/// validate section CRCs (documented in `mpegts.mbt`).
fn ts_test_pat(pmt_pid : Int32) -> Array[Byte] {
  let section : Array[Byte] = [
    b'\x00',
    b'\xb0',
    b'\x0d',
    b'\x00',
    b'\x01',
    b'\xc1',
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x01',
    (0xE0 | ((pmt_pid >> 8) & 0x1F)).to_byte(),
    (pmt_pid & 0xFF).to_byte(),
  ]
  let out : Array[Byte] = [b'\x00']
  out.append(section)
  out.append([b'\x00', b'\x00', b'\x00', b'\x00'])
  ts_test_packet(0, true, 0, Bytes::from_array(out))
}

///|
/// Build a PMT with an HEVC stream (type 0x24) and an Opus stream
/// (type 0x06 + registration descriptor "Opus").
fn ts_test_pmt() -> Array[Byte] {
  let streams : Array[Byte] = [
    b'\x24', b'\x01', b'\x01', b'\xf0', b'\x00', b'\x06', b'\x01', b'\x02', b'\xf0',
    b'\x06', b'\x05', b'\x04', b'O', b'p', b'u', b's',
  ]
  let sec_len = 13 + streams.length()
  let out : Array[Byte] = [
    b'\x00',
    b'\x02',
    (0xB0 | ((sec_len >> 8) & 0x0F)).to_byte(),
    (sec_len & 0xFF).to_byte(),
    b'\x00',
    b'\x01',
    b'\xc1',
    b'\x00',
    b'\x00', // program 1
    b'\xe1',
    b'\x01', // PCR PID 0x101
    b'\xf0',
    b'\x00', // program_info_length 0
  ]
  out.append(streams)
  out.append([b'\x00', b'\x00', b'\x00', b'\x00'])
  ts_test_packet(0x1000, true, 0, Bytes::from_array(out))
}

///|
/// Build a PES packet with no PTS/DTS and a known length.
fn ts_test_pes(pid : Int32, stream_id : Int32, payload : Bytes) -> Array[Byte] {
  let pes_len = 3 + payload.length()
  let out : Array[Byte] = [
    b'\x00',
    b'\x00',
    b'\x01',
    stream_id.to_byte(),
    ((pes_len >> 8) & 0xFF).to_byte(),
    (pes_len & 0xFF).to_byte(),
    b'\x80',
    b'\x00',
    b'\x00',
  ]
  out.append(payload.to_array())
  ts_test_packet(pid, true, 0, Bytes::from_array(out))
}

///|
test "mpegts: real ffmpeg H.264+B-frames (PES fields match ffprobe)" {
  let bytes = @libavutil.av_base64_decode(ts_bf_b64, 100000).unwrap()
  let ts = av_mpegts_open(bytes).unwrap()
  assert_eq(ts.packet_size, 188)
  assert_eq(ts.sync_offset, 0)
  assert_eq(ts.programs.length(), 1)
  assert_eq(ts.programs[0].program_number, 1)
  assert_eq(ts.programs[0].pmt_pid, 4096)
  assert_eq(ts.programs[0].pcr_pid, 256)
  assert_eq(ts.streams.length(), 1)
  assert_eq(ts.streams[0].pid, 256)
  assert_eq(ts.streams[0].stream_type, 0x1B)
  assert_eq(ts.streams[0].codec, "h264")
  assert_eq(ts.streams[0].codec_type, "video")
  assert_eq(ts.packets.length(), 3)
  let expected : Array[(Int64, Int64, Int32, Int64)] = [
    (186000L, 126000L, 1326, 564L),
    (246000L, 156000L, 111, 2444L),
    (216000L, 186000L, 71, 3196L),
  ]
  for i in 0..<expected.length() {
    let (pts, dts, size, pos) = expected[i]
    assert_eq(ts.packets[i].stream_index, 0)
    assert_eq(ts.packets[i].pts, pts)
    assert_eq(ts.packets[i].dts, dts)
    assert_eq(ts.packets[i].payload.length(), size)
    assert_eq(ts.packets[i].pos, pos)
  }
  // Annex B start code at the beginning of the first PES payload.
  assert_eq(ts.packets[0].payload[1], b'\x00')
  assert_eq(ts.packets[0].payload[2], b'\x00')
  assert_eq(ts.packets[0].payload[3], b'\x01')
  assert_true(ts.pcrs.length() > 0)
  assert_eq(ts.pcrs[0].pid, 256)
}

///|
test "mpegts: real ffmpeg H.264+AAC (two programs streams and PES order)" {
  let bytes = @libavutil.av_base64_decode(ts1_b64, 200000).unwrap()
  let ts = av_mpegts_open(bytes).unwrap()
  assert_eq(ts.streams.length(), 2)
  assert_eq(ts.streams[0].codec, "h264")
  assert_eq(ts.streams[0].codec_type, "video")
  assert_eq(ts.streams[0].pid, 0x100)
  assert_eq(ts.streams[1].codec, "aac")
  assert_eq(ts.streams[1].codec_type, "audio")
  assert_eq(ts.streams[1].pid, 0x101)
  assert_eq(ts.packets.length(), 5)
  let expected : Array[(Int32, Int64, Int64, Int32, Int64)] = [
    (1, 126000L, 126000L, 1583, 1880L),
    (0, 128090L, 128090L, 1249, 564L),
    (1, 159437L, 159437L, 1622, 4324L),
    (1, 192874L, 192874L, 1231, 6392L),
    (0, 173090L, 173090L, 103, 4136L),
  ]
  for i in 0..<expected.length() {
    let (stream_index, pts, dts, size, pos) = expected[i]
    assert_eq(ts.packets[i].stream_index, stream_index)
    assert_eq(ts.packets[i].pts, pts)
    assert_eq(ts.packets[i].dts, dts)
    assert_eq(ts.packets[i].payload.length(), size)
    assert_eq(ts.packets[i].pos, pos)
  }
  // Audio PES payload is a run of ADTS frames.
  assert_eq(ts.packets[0].payload[0], b'\xff')
  assert_eq(ts.packets[0].payload[1], b'\xf1')
  // Video PES payload is Annex B.
  assert_eq(ts.packets[1].payload[0], b'\x00')
  assert_eq(ts.packets[1].payload[1], b'\x00')
  assert_eq(ts.packets[1].payload[2], b'\x00')
  assert_eq(ts.packets[1].payload[3], b'\x01')
}

///|
test "mpegts: synthetic HEVC + Opus registration descriptors" {
  let hevc_pes = ts_test_pes(0x101, 0xE0, b"\x00\x00\x00\x01\x26\x01")
  let opus_pes = ts_test_pes(0x102, 0xBD, b"\xfc\x00\x00")
  let bytes = ts_test_concat([
    ts_test_pat(0x1000),
    ts_test_pmt(),
    hevc_pes,
    opus_pes,
  ])
  let ts = av_mpegts_open(bytes).unwrap()
  assert_eq(ts.streams.length(), 2)
  assert_eq(ts.streams[0].pid, 0x101)
  assert_eq(ts.streams[0].codec, "hevc")
  assert_eq(ts.streams[0].codec_type, "video")
  assert_eq(ts.streams[1].pid, 0x102)
  assert_eq(ts.streams[1].codec, "opus")
  assert_eq(ts.streams[1].codec_type, "audio")
  assert_eq(ts.streams[1].registration, "Opus")
  assert_eq(ts.packets.length(), 2)
  assert_eq(ts.packets[0].payload.length(), 6)
  assert_eq(ts.packets[1].payload.length(), 3)
}

///|
test "mpegts: M2TS 192-byte packets are detected" {
  let base = @libavutil.av_base64_decode(ts_bf_b64, 100000).unwrap()
  let out : Array[Byte] = []
  let mut i = 0
  while i + 188 <= base.length() {
    out.append([b'\x00', b'\x00', b'\x00', b'\x00'])
    for j in i..<(i + 188) {
      out.push(base[j])
    }
    i = i + 188
  }
  let ts = av_mpegts_open(Bytes::from_array(out)).unwrap()
  assert_eq(ts.packet_size, 192)
  assert_eq(ts.sync_offset, 4)
  assert_eq(ts.packets.length(), 3)
  assert_eq(ts.packets[0].pos, 564L + 3L * 4L)
}

///|
test "mpegts: rejects non-TS input" {
  match av_mpegts_open(b"not a transport stream at all") {
    Ok(_) => fail("expected sync error")
    Err(e) => assert_true(e.contains("sync"))
  }
}
