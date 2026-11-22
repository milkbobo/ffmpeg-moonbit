///|
/// First seven frames of FFmpeg FATE musepack/inside-mp7.mpc. The
/// stream's declared frame count has been shortened to match the fixture.
let mpc7_test_parts : ReadOnlyArray[Bytes] = [
  b"TVArBwcAAAAAAKBcAAAAAAAAAAAAAFCHAAQAc////w/w/////wBAAP////8EAP////8PAP////8AQADw/////wX///9dy26g///7vvW2",
  b"ff8/6HrQtm0b+9u2bdO2aRtj2LZt22eaf978c/zZf44/3775Z5s1/0x++p/Jz/45/gw/x59v0/zzzdzzzT/zzT/Ltvlnz9nmn33nm3/+",
  b"n8nP/uDPLvvgz6DP5p/Jz+4Z/LkZ5p9py9wz+fyzzD59jj7TzT+Tn+gAHeABOkAHdIAO0AAdoAM6QAfogA7QAR8gBHS+9RcBllTw3V/9",
  b"WqFvx8wk8RgGOpU1gHmGASVmADoCkwABCECAAAQgQAACECAAAQgQgAAE2L8AArsh/AzqD46ReyKwVW5KK8VBkX5vfyN8lP1//x/f//f/",
  b"//1////f//f3//1/f//f/wIIAP4KgQsg4WuoBAoajjxiJxrbheGRvIAYHlP2xHpXIA0WFV9w+Ov//X///9//9/f//X9//9////f//f1/",
  b"/9/g//f/Cp5/EA7jyHcoiA5/dx8dJaYdHpJIQpLusbmFThkKmY7/X8KU9//9f3//3///9//9/X//39//9////X//AKD+97cC5n5vot99",
  b"D+jPpVZpPqtOCbiij5uKlGDrRyOYFrhDf//f6P/3//39f//f3//3///9f///3//35//9f3/z3//ZN/7tLJiF3qR2K+CcVlXSdjzXNNOm",
  b"IjSnAqRdMd573P1//5/f//f///1////f//f3//1/f//f/wDI//0qgOmfHsvXAfEtriunn/3CxSqKmaABoRdOmGKgMNAo6R/S1SD//X//",
  b"/9//9/f//X9//9////f//f1//98fAOj/9FGA7HmbUdg1u9GYpbzbYs2Hnu5FM/0kPYlouyvpjeD/X1el9//9f3//3///9//9/X//39//",
  b"9////X///N8A+Cj9iYCE/l5RwltafQlqA52lhYeTup67znOV56kQlTZSf/+fP//3//39f//f3//3///9f///3//3+P/9f4D6nwAKGP4p",
  b"sXmmniO5K6nHOY674RLTGwcztjyG0dFyCuHLev1//x/f//f///1////f//f3//1/f//f//8HAP7CfwegotyHAn/Ve0rY5QZQJD51XDMs",
  b"VGZ4xh+BtRFK7p8FjzT//X///9//9/f//X9//9////f//f1//99g//f/BiaABubiM0hz1+VpOfygrM9Up+gYJaycoInkNT5SI67/X1TO",
  b"9//9f3//3///9//9/X//39//9////X//9p/+99j8pX9e0uAj6njz4veL495cdqosVZ3iumCeDoY2IX7rf/+fhP/3//39f//f3//3///9",
  b"f///3//3+P/9f4DxHwHzR/5xEZlfIZ7ObMVfWosEd2JJKGiDLq2c5uUQOq/leP1//1/f//f///1////f//f3//1/f//f/wEoAP56gSFg",
  b"5cXoCfD6n1g/m9IvXMcYeBZ5JyNSbLfjwHJXNJ92Ws3//X///9//9/f//X9//9////f//f5//99gAjgAD0qBI3fpRrh5xCCoZD2nIqd5",
  b"hWESRi1j2s48I7L/Q3P/n0eJ9//9f3//3///9//9/X//39//9////X//3h/+x5fxsX5pc1hsdjJQOTV0r9rxN9bz9vR/kbWDlAhTE4hI",
  b"f/8fPf/3//39f//f3//3///9f///3//31//9f3/XH//+d+ytmKFtF5jvj519AZPsJJV3KztYEcLIx8ivGm9bLP1//9/f//f///1////f",
  b"//f3//1/f//f//7n//0Rf/jfnajH/NLxcKEQZjgI6VOKNIy3KDZhWCJnStOBwl+n5xT//X///9//9/f//X9//9////f//f1//98g//f/",
  b"ByZ/CLpii9dQBGdYIpRtr7phMqPTHHT8NSIClhAbKfL/n9tE9//9f3//3///9//9/X//39//9////X//CyAB+MgGnoCajyEyOwOxUr6a",
  b"3psiJhYymkmugiFtLeVQfjysf/8fm//3//39f//f3//3///9f///3//3+P/9f4ABYAA5WABuIoeQ39tsmk8mjnlxMmfNlwpX5opgMCTd",
  b"GnF30v1//9/f//f///1////f//f3//1/f//f//7n//35fu0fHKqn+DgVa1DypRD4923JX13xJHsh2m35kCdF8J81wkb//X///9//9/f/",
  b"/X9//9////f//f1//9+g/vf//4F/AFTf1cdW961nTAojIrfGcXLi446PatO1xDlQaFj/31S59//9f3//3///9//9/X//39//9/8A/n//",
  b"ISAAKGgMVoB/TWVQPEhuUn2bO2krNgckAJ5UqdXriP/WZVI7f/+f2f/3//39f//f3//3///9f///3//3+P/9f4H0XwBamerxRqWqF9rl",
  b"ixyGnndK4SCacyuMjnbkqASxlCAlLv1//5/f//f///1////f//f3//1/f//f/wH4//2hgP0fnUT4+VR2gTbBXGrzMxBysfeUJKQTwgIu",
  b"Bftvvd9S3Lv//X///9//9/f//X9//9////f//f5//99g/gcABh5/Eahi57eVrdM/n81dlTv6TMG3T0Ug5dlzMpiooG3/nxgf9//9f3//",
  b"3///9//9/X//39//9////X//AqD+50cGun+EnGDiXEN0dhWshlhlCVsp9vGreLz80mSGfaEmf/8fZ//3//39f//f3//3///9f///3//3",
  b"9//9f38GoP+UJwNCln5U4R+4n+N+dofdMlZ3jbwfZ4kvSaI6glXoA/1//x/f//f///1////f//f3//1/f//f/wDo//2NgPff3ilI/XRh",
  b"lD/dp3EWYzP5kD1Wo//ANUjsKaOieN9H+xz//X///9//9/f//X9//9////f//f1//9+g//f/BhqAB+2hOihaW1p8kvDjahdKNeaqoTrj",
  b"O97pAEkPnbb/33R19//9f3//3///9//9/X//39//9////X///h//5xcGDn9LSqCboWCQSnnG/Fomfm75Br0VcNqMa6Oqi2n3f/+fbP/3",
  b"//39f//f3//3///9f///3//3+P/9f4AHYAD+pwMaDpMdoaRgTYyj3ZBWaM1CyOqipfwzoZJnVKd8TP1//1/f//f///1////f//f3//1/",
  b"f//f//3X//0xf93fmcdH8ecdkO6A5EZPehiyieiZE1uFng/9YGUSnV9Kmg7//X///9//9/f//X9//9////f//f1//99f//f/9El/8IWb",
  b"lbfW6UxcbhYj7pqcYDKsrCBbo14IE7D5WGz/34r49//9f3//3///9//9/X//39//9/8A/n//OyACSDgXuoB1NmsJEGMbycFoQaNnkMAQ",
  b"gEwnHgabXEuGDhIXf//fuP/3//39f//f3//3///9f///3//36P/9f4H1nwGDuP2pgqpf4Jp1v4Wk/k5Q/GLZhgLrrl7zF9MqK1o4lv1/",
  b"/x/f//f///1////f//f3//1/f//f/wIIAP6xgf3fIp64/pJ9zvLR2Awg45jWcdiLLY1NDi/FsF8Y4R9zwHT//X///9//9/f//X9//9//",
  b"//f//f5//9+g/icAD2Z/GeJp0FeNy0BKqedcSuwYzjXlig6gtXUUjOsfVsH/HzoG9//9f3//3///9//9/X//39//9////X//8h/+99f6",
  b"1X5p2N+3MDEa+m2O7N6iSZvclSNxqrW8bFiyaESpf/+fBf/3//39f//f3//3///9f///3//3BwD+f38EIP+gV/05NYRQoGFSt8Cui9MO",
  b"oOkRy/VMTVu01c2gmtkGh/1//5/f//f///1////f//f3//1/f//f/wD4//3CgAXgnlxoAIFajIeIETXtc+PdkC4AVsktC8PNO9MMxR/t",
  b"GLD//X///9//9/f//X9//9////f//f1//9/f/9f//r1/9OnduLe5Ye5tkoAaE7PZ83ZebDhqGytgFbLlzV02gYtHtbPiBv5/66143vmt",
  b"QkjMZB/QlYu6JW3vNoambds0bdNtmyRNafYis+645JXlr7FYTD4ecPGAK4f2IUe8MWiyMv4df39cNg4jajwTbxbZYxyRQ4tTf5FH42Ky",
  b"yBfkkDEeySHGBbIxyqCxyrHkZlnkz4X4kjurrDLIBk922ZZFBlNyy/HkyyXXrNnkr/JeeVqejzycbUIQ8VMLc7ywJJQxP9nQulsFQTV5",
  b"GtdicFKXlM2B5ss4/jQwGx7Brgw0Hi+k1mwOZwfc24wcNRP3kXGPo5Q3zKFWIJ2iXA3rXAWEL4TC+UPAUsC6lJCstt0ThlfcVirDGIhE",
  b"/oGmcNIVNlQ+bGhp2z506XIHAtH3BuACkUVX3g3cQ0xctAQFDDPmzKx6FDthEFNr9mRjyxjSOM1WD0xV6tkcrbvJ9x8DlMDfBwEK0Phl",
  b"YdILgNusz9o4aP2sIA8gD6PKz8ETWV2fJzOmV7gLxH8p2jk1n+bvVWRgI7s3wTbm1b4r0/zGyFffZ1pZpl9envQh1DaIgD7ESEUq2Jah",
  b"9o7zRpHgHJZ/UoXR6Rjz/VbAu83Q8IxzEsVrSuwx4JJDKiDAQs5fxVPlTWKAX92GaOfhgs+AmSGy8gXMmwmKWGRITIz6Pj35HuhDY0JZ",
  b"5wGfd5CN/7z7g+UxzOmoYGRTQLyrA9o5ZVXUpZVtz0QauMkl2DjYLrL8hufgKxXJ+E8DrAT+Qr6+C3EZ97oHtUOJ5hSmYfcPwTmvh99J",
  b"iZNbPXvJU0FMTUkLRqkN2DdGbzLKVNbq0t9CFESj1N32vwgb3wFaSMn3cwELCjx61Fv6jZAttahLyYvo5rjGPwvAJYTs8P26yoKTVI/l",
  b"rBE+/bNz4xbC3iLFyT85+I8FBAECnb/OuDBiPHYxtc7iNi54M3hr++A7Eq/RKoza90ZxjYkOXT3zQtcsOyVQ6ZTt4HwBubiQgQk8YxLW",
  b"vnm8mF7v91AnS4zc1MVhWJkw2gQG5qIGHvq5DkdGaQtUZ/5H9ObRHlYeiZxoSgbl9JUI0j3OzI9+L7/4LwMKXABRwsPkTwDYVNBVvxDm",
  b"mEKQ1Zq3zZhT0QjTwMk6ke7Mo1Le47NpL6ZOLQdZ4+tKXECmM9fygfkrO1MI+yhgji2+EISdOlLxXM8rzegg+GXyZs/RWy1eswA4LLJ9",
  b"0lCBZkmUK8XU7fH14iyOtrIbhqEGWv8IwNz3TwLkewAHwDoJUOB0QTedVL9ZqlCQID80IclJpBE0hOMquciKmvhs8UBCdmaWmYXUUXJw",
  b"0cy8w2hAF4Rw9U2/uMN2UijZyp/ZZboy4gwfbkFLTHvut7j4itRKRpmal7r//Kkw4Oe1xXoWNYHyxPXYDB3KLv9rrPbkP9ovMDSM+v6s",
  b"xmjQmMytqryq/VfI1XaLQ1KQy8brDid9JCgROqEof9BqmEMW10FWVDfehitWZc0+Aung9yMtgMj9VLAx/sLPs4qDDBkDp066/UO0XB8P",
  b"FmFnT86qt+Z82tPYgkZJn54zohieipFdImQxe8xSBanjAMM/wNgv//BTA191tXkv5lRffQyRzOm/qVaPc+jEy8Gwz1ViBCQrpzFWbm9R",
  b"V2dfktrTKa+kXPhs48zBbcI87SyM74JFTMuvImx0S2U0ZCNBAfQ8Z9IWJr5KRpJRVFxSmcAhZ2TonG1x4+skAAlAP/rvAeLzAce9soVw",
  b"AuRclsuYsXYzz7bOvKHeL8RBkl8J5dX+1Za8czLRXIiHAApji3JO3t4QU61ASDYJH/7qh4qFO8T9VMVx+kPiKB1bvLujlyyOKXvSThl6",
  b"nYsg6YKgcNAksMAO4qzl7hAnFDD/E3sDK0BF58/7zaXsOkBZlK8cPAwuGmj3a7pG9j7Ld9BdtOJv2idDPNlkNWat72WErdfENt3lWHBT",
  b"o/bLt9EvgPs1dzn+kJZZJmxaL4EVt0DUp3XbSrU03zArxypIExStxQW5xq3L0U0Z6LKAEP01wK7jf/DP/Srg+zU41ufIBGvF/gOM68/h",
  b"GaAkz0P2F+Mknto2NM22YTTn+84WBvKxAL2aMRz0/C54Q8awfCMnCDAyMfz5CfmmYF+h7knJpGhTmbrAGU/7GjfICQiWOxpKsBGSn/c6",
  b"/hltxwACQB1EgfyvB/fgBV5NaugKljWyRXjy2zv2lyhc0Tl2EuD6dca1U3/y+qcnEPtMxJOpe+39MtllI02uMzD8v8c6heQ4m0P7exYE",
  b"UXd0ousFJOLxkszELfHlvOZE/7xfiuBa05DEi4lKZklFE3GBvMJf/3Ne+8f/9K/3ub+BK3grGdLmz7/cffwLwU+sAjupc+OfSRqBGbcK",
  b"iTYX8DgqJSL5s0KSFNVzkDXTPSHrWvi/e7yDZbt6hs2ZJmYssAnWTrkzFXcVlAXJtqg0gCNQN6TCuVK3qVXT2CRh+jbfAOw29ucA+7AE",
  b"Yr9vhINLeRzC58BimN4Tv8LS+5JbMJo5P5OQQtMVumuHH6/rN5Z6EFvWHegjdS6s9hgSyRfBZDa8XkWaMdGBcKtIK/qLM9ix/LG0rhDL",
  b"atOWQw9QWBfkiZ6cDrKkpjmPNWfAAaznpL8DfO/jPQUicLw7RIX5sipO2YlIXZw77FQZHGvlSJugqyej/Ciq5elzutJAbVPMfED/jDC/",
  b"AxfABMkb6jZMUFp54rXMrRh/DbssZyvoMFPt4MyvrWzfPNRs54nNoDDzk0D8QwpMQP/JDcRBWvwkJONSMeQjnteY2zrFLG56RtvItqy4",
  b"FZDo/KvvHZ+61EQvilwVNPrjPM1NXQ072wY0IRAXVTujP97CtA4i65ZiVXdSM+j0362+qegNh7NAl9u2X/8KWI59+EsDH7Q92QTBaWk8",
  b"vRbjKCyv5SKcK9dp8o/5vkyHfJohsDzme+7bB2Ay896FjK8cuXpgCjVnvTERi1UE1XTQeArxDvlLEaSPqS+051K1VPsdi0zQO7NOwtqu",
  b"tiUpZCcmlsx+cBVkPJBERUk1HweAHM/bCyHktQvDy8RFxtsn5U1m07XdaE2R+m2LCzytKKJlK/Cnbx/Dyk5KpNd7vnJr6gIo0Rl4OOVD",
  b"+s1BhgjnO9jM4wClUCegL3lbA3dR5I0brHGblKk4X8U1vKJJcLFAfuQGx+sFgbDRma1UH4R0vqDMquxxKWx4jv3gxiRT7Ournao75MPz",
  b"aow7lNi9uNmzgxOVSmR8u+JL5jAykFs2qZp8fYuMFJFyglXgdkZtPJ/SqYFOEX8ptcul/vsBOS4/4bH3HUa3hDgDMap1lryFe3DLag50",
  b"xYaLfYwDdsDx0yghlelcYmDxZlgFBreTUkQnH6iMu9hl/WpG8pXdUKhuNz5PEWtZ+dfyngGeodYvtfz2K1n4j/fnz7z5X3FcMf6mcdM0",
  b"XWkbmlt8nA2/zPiYDsqYn+OMsvfTPheNlLcQX3PUcyg8HfX87GOm+DCDpaCE2yEpbZqxLmNDzp23cFSwf9Qmnw/gc3hcdKySuR5oxIF1",
  b"Wm18Gr0FZqnwRnH1hudrz4pFl9GY70S4j/b1KZYYqx9e9OIhcb1vJ5zl4Q+jpjef0xyqZbujhTVaJPxUbTfg5KX+lpunQ1mW51mW5VHO",
  b"dZzHWSLYXNc/zmN59Mp6rGJmxvmj1Wq10uSaMyq2HQqpjYA7lHtcLiEh3ids3DRAzPFEoJSinZSPHm3IgyTf1zxOUcOqC+eRM7dGtEFF",
  b"LKyIf05AZWoCzsf8AYuTxy7mbtYJc+/y1J2TATj+HIwzZ3zqp3iXn/6J2hFe2zoT8b4F/DmyLQK+8iKrWqytHf6o11cRkKJPinXZ6D/p",
  b"09WFhG7uxWj/+N00f1Ik0vTT3CuQEdXoOt82OEMuO4voJ9+Vaa3PPNxkm1OPNGBUONf/2xyrSq3bBEVff4x8dX7v6p51SuMj8b1QSijA",
  b"bTs=",
]

///|
fn mpc7_test_file() -> Bytes {
  let encoded : Array[Byte] = []
  for part in mpc7_test_parts {
    for byte in part {
      encoded.push(byte)
    }
  }
  @libavutil.av_base64_decode(Bytes::from_array(encoded), encoded.length()).unwrap()
}

///|
test "musepack: SV7 file reaches the unified decoder" {
  let data = mpc7_test_file()
  let audio = decode_audio_file(data)
  assert_eq(audio.format_name, "mpc")
  assert_eq(audio.codec_id, "musepack7")
  assert_eq(audio.sample_rate, 44100)
  assert_eq(audio.channels, 2)
  assert_eq(audio.samples[0].length(), 7 * 1152)
  assert_eq(audio.samples[1].length(), 7 * 1152)
  let reference = [
    (6175, 113, -60),
    (6176, 69, -29),
    (6208, -97, 40),
    (6239, 126, -19),
    (6303, 220, -192),
    (6432, -1750, -1459),
    (6575, 249, 475),
    (6774, -2397, -2449),
    (6915, -392, -265),
    (7075, -2, 135),
    (7175, 647, 586),
    (7275, -425, -671),
  ]
  for (i, l, r) in reference {
    assert_true((audio.samples[0][i] * 32768.0 - l.to_double()).abs() <= 1.0)
    assert_true((audio.samples[1][i] * 32768.0 - r.to_double()).abs() <= 1.0)
  }
  assert_true(av_mpc7_open(data[:data.length() - 1].to_owned()) is Err(_))
}

///|
test "musepack: rejected packet leaves decoder state intact" {
  let demux = av_mpc7_open(mpc7_test_file()).unwrap()
  let decoder = @libavcodec.Mpc7Decoder::new(demux.extradata).unwrap()
  let clean = @libavcodec.Mpc7Decoder::new(demux.extradata).unwrap()
  for i in 0..<6 {
    let packet = demux.packet(i).unwrap()
    let _ = decoder.decode_packet(packet).unwrap()
    let _ = clean.decode_packet(packet).unwrap()
  }
  let packet = demux.packet(6).unwrap()
  let truncated = packet[:packet.length() / 2].to_owned()
  assert_true(decoder.decode_packet(truncated) is Err(_))
  assert_eq(
    decoder.decode_packet(packet).unwrap(),
    clean.decode_packet(packet).unwrap(),
  )
}
