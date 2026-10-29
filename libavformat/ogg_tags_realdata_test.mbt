///|
/// Real FFmpeg 9.0.2 Ogg files with Vorbis comments: a libvorbis stream and an
/// Ogg FLAC stream, both carrying stream-level title/artist tags.

///|
fn oggtags_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let oggtags_vorbis_b64 : Bytes = oggtags_concat([
  b"T2dnUwACAAAAAAAAAADjFpGDAAAAABnekzQBHgF2b3JiaXMAAAAAAUSsAAAAAAAAgDgBAAAAAAC4AU9nZ1MAAAAAAAAAAAAA4xaRgwEAAABgIQOCDmz///////////////+BA3ZvcmJpcwwAAABMYXZmNjMuMS4xMDIDAAAAHgAAAGVuY29k",
  b"ZXI9TGF2YzYzLjEuMTAyIGxpYnZvcmJpcxIAAAB0aXRsZT1Wb3JiaXMgVGl0bGUUAAAAYXJ0aXN0PVZvcmJpcyBBcnRpc3QBBXZvcmJpcyJCQ1YBAEAAACRzGCpGpXMWhBAaQlAZ4xxCzmvsGUJMEYIcMkxbyyVzkCGkoEKIWyiB0JBVAABA",
  b"AACHQXgUhIpBCCGEJT1YkoMnPQghhIg5eBSEaUEIIYQQQgghhBBCCCGERTlokoMnQQgdhOMwOAyD5Tj4HIRFOVgQgydB6CCED0K4moOsOQghhCQ1SFCDBjnoHITCLCiKgsQwuBaEBDUojILkMMjUgwtCiJqDSTX4GoRnQXgWhGlBCCGEJEFI",
  b"kIMGQcgYhEZBWJKDBjm4FITLQagahCo5CB+EIDRkFQCQAACgoiiKoigKEBqyCgDIAAAQQFEUx3EcyZEcybEcCwgNWQUAAAEACAAAoEiKpEiO5EiSJFmSJVmSJVmS5omqLMuyLMuyLMsyEBqyCgBIAABQUQxFcRQHCA1ZBQBkAAAIoDiKpViK",
  b"pWiK54iOCISGrAIAgAAABAAAEDRDUzxHlETPVFXXtm3btm3btm3btm3btm1blmUZCA1ZBQBAAAAQ0mlmqQaIMAMZBkJDVgEACAAAgBGKMMSA0JBVAABAAACAGEoOogmtOd+c46BZDppKsTkdnEi1eZKbirk555xzzsnmnDHOOeecopxZDJoJ",
  b"rTnnnMSgWQqaCa0555wnsXnQmiqtOeeccc7pYJwRxjnnnCateZCajbU555wFrWmOmkuxOeecSLl5UptLtTnnnHPOOeecc84555zqxekcnBPOOeecqL25lpvQxTnnnE/G6d6cEM4555xzzjnnnHPOOeecIDRkFQAABABAEIaNYdwpCNLnaCBG",
  b"EWIaMulB9+gwCRqDnELq0ehopJQ6CCWVcVJKJwgNWQUAAAIAQAghhRRSSCGFFFJIIYUUYoghhhhyyimnoIJKKqmooowyyyyzzDLLLLPMOuyssw47DDHEEEMrrcRSU2011lhr7jnnmoO0VlprrbVSSimllFIKQkNWAQAgAAAEQgYZZJBRSCGF",
  b"FGKIKaeccgoqqIDQkFUAACAAgAAAAABP8hzRER3RER3RER3RER3R8RzPESVREiVREi3TMjXTU0VVdWXXlnVZt31b2IVd933d933d+HVhWJZlWZZlWZZlWZZlWZZlWZYgNGQVAAACAAAghBBCSCGFFFJIKcYYc8w56CSUEAgNWQUAAAIACAAA",
  b"AHAUR3EcyZEcSbIkS9IkzdIsT/M0TxM9URRF0zRV0RVdUTdtUTZl0zVdUzZdVVZtV5ZtW7Z125dl2/d93/d93/d93/d93/d9XQdCQ1YBABIAADqSIymSIimS4ziOJElAaMgqAEAGAEAAAIriKI7jOJIkSZIlaZJneZaomZrpmZ4qqkBoyCoA",
  b"ABAAQAAAAAAAAIqmeIqpeIqoeI7oiJJomZaoqZoryqbsuq7ruq7ruq7ruq7ruq7ruq7ruq7ruq7ruq7ruq7ruq7ruq4LhIasAgAkAAB0JEdyJEdSJEVSJEdygNCQVQCADACAAAAcwzEkRXIsy9I0T/M0TxM90RM901NFV3SB0JBVAAAgAIAA",
  b"AAAAAAAMybAUy9EcTRIl1VItVVMt1VJF1VNVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVN0zRNEwgNWQkAAAEA0FpzzK2XjkHorJfIKKSg10455qTXzCiCnOcQMWOYx1IxQwzGlkGElAVCQ1YEAFEAAIAxyDHEHHLOSeokRc45",
  b"Kh2lxjlHqaPUUUqxplo7SqW2VGvjnKPUUcoopVpLqx2lVGuqsQAAgAAHAIAAC6HQkBUBQBQAAIEMUgophZRizinnkFLKOeYcYoo5p5xjzjkonZTKOSedkxIppZxjzinnnJTOSeack9JJKAAAIMABACDAQig0ZEUAECcA4HAcTZM0TRQlTRNF",
  b"TxRd1xNF1ZU0zTQ1UVRVTRRN1VRVWRZNVZYlTTNNTRRVUxNFVRVVU5ZNVbVlzzRt2VRV3RZV1bZlW/Z9V5Z13TNN2RZV1bZNVbV1V5Z1XbZt3Zc0zTQ1UVRVTRRV11RV2zZV1bY1UXRdUVVlWVRVWXZdWddVV9Z9TRRV1VNN2RVVVZZV2dVl",
  b"VZZ1X3RV3VZd2ddVWdZ929aFX9Z9wqiqum7Krq6rsqz7si77uu3rlEnTTFMTRVXVRFFVTVe1bVN1bVsTRdcVVdWWRVN1ZVWWfV91ZdnXRNF1RVWVZVFVZVmVZV13ZVe3RVXVbVV2fd90XV2XdV1YZlv3hdN1dV2VZd9XZVn3ZV3H1nXf90zT",
  b"tk3X1XXTVXXf1nXlmW3b+EVV1XVVloVflWXf14XheW7dF55RVXXdlF1fV2VZF25fN9q+bjyvbWPbPrKvIwxHvrAsXds2ur5NmHXd6BtD4TeGNNO0bdNVdd10XV+Xdd1o67pQVFVdV2XZ91VX9n1b94Xh9n3fGFXX91VZFobVlp1h932l7guV",
  b"VbaF39Z155htXVh+4+j8vjJ0dVto67qxzL6uPLtxdIY+AgAABhwAAAJMKAOFhqwIAOIEABiEnENMQYgUgxBCSCmEkFLEGITMOSkZc1JCKamFUlKLGIOQOSYlc05KKKGlUEpLoYTWQimxhVJabK3VmlqLNYTSWiiltVBKi6mlGltrNUaMQcic",
  b"k5I5J6WU0loopbXMOSqdg5Q6CCmllFosKcVYOSclg45KByGlkkpMJaUYQyqxlZRiLCnF2FpsucWYcyilxZJKbCWlWFtMObYYc44Yg5A5JyVzTkoopbVSUmuVc1I6CCllDkoqKcVYSkoxc05KByGlDkJKJaUYU0qxhVJiKynVWEpqscWYc0sx",
  b"1lBSiyWlGEtKMbYYc26x5dZBaC2kEmMoJcYWY66ttRpDKbGVlGIsKdUWY629xZhzKCXGkkqNJaVYW425xhhzTrHlmlqsucXYa2259Zpz0Km1WlNMubYYc465BVlz7r2D0FoopcVQSoyttVpbjDmHUmIrKdVYSoq1xZhza7H2UEqMJaVYS0o1",
  b"thhrjjX2mlqrtcWYa2qx5ppz7zHm2FNrNbcYa06x5Vpz7r3m1mMBAAADDgAAASaUgUJDVgIAUQAABCFKMQahQYgx56Q0CDHmnJSKMecgpFIx5hyEUjLnIJSSUuYchFJSCqWkklJroZRSUmqtAACAAgcAgAAbNCUWByg0ZCUAkAoAYHAcy/I8",
  b"UTRV2XYsyfNE0TRV1bYdy/I8UTRNVbVty/NE0TRV1XV13fI8UTRVVXVdXfdEUTVV1XVlWfc9UTRVVXVdWfZ901RV1XVlWbaFXzRVV3VdWZZl31hd1XVlWbZ1WxhW1XVdWZZtWzeGW9d13feFYTk6t27ruu/7wvE7xwAA8AQHAKACG1ZHOCka",
  b"Cyw0ZCUAkAEAQBiDkEFIIYMQUkghpRBSSgkAABhwAAAIMKEMFBqyEgCIAgAACJFSSimNlFJKKaWRUkoppZQSQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQggFAPhPOAD4P9igKbE4QKEhKwGAcAAAwBilmHIMOgkpNYw5BqGUlFJq",
  b"rWGMMQilpNRaS5VzEEpJqbXYYqycg1BSSq3FGmMHIaXWWqyx1po7CCmlFmusOdgcSmktxlhzzr33kFJrMdZac++9l9ZirDXn3IMQwrQUY6659uB77ym2WmvNPfgghFCx1Vpz8EEIIYSLMffcg/A9CCFcjDnnHoTwwQdhAAB3gwMARIKNM6wk",
  b"nRWOBhcashIACAkAIBBiijHnnIMQQgiRUow55xyEEEIoJVKKMeecgw5CCCVkjDnnHIQQQiillIwx55yDEEIJpZSSOecchBBCKKWUUjLnoIMQQgmllFJK5xyEEEIIpZRSSumggxBCCaWUUkopIYQQQgmllFJKKSWEEEIJpZRSSimlhBBKKKWU",
  b"UkoppZQQQimllFJKKaWUEkIopZRSSimllJJCKaWUUkoppZRSUiillFJKKaWUUkoJpZRSSimllJRSSQUAABw4AAAEGEEnGVUWYaMJFx6AQkNWAgBAAAAUxFZTiZ1BzDFnqSEIMaipQkophjFDyiCmKVMKIYUhc4ohAqHFVkvFAAAAEAQACAgJ",
  b"ADBAUDADAAwOED4HQSdAcLQBAAhCZIZINCwEhweVABExFQAkJijkAkCFxUXaxQV0GeCCLu46EEIQghDE4gAKSMDBCTc88YYn3OAEnaJSBwEAAAAAcAAADwAAxwUQEdEcRobGBkeHxwdISAAAAAAAyADABwDAIQJERDSHkaGxwdHh8QESEgAA",
  b"AAAAAAAAAAQEBAAAAAAAAgAAAAQET2dnUwAEOhEAAAAAAADjFpGDAgAAAATU/PwGHzwnJS5/XN2rOqu6sP9aAgQQAMCM2i22N998880wDMMwDMN6AJrYPQdv0p5HXAVmIkAqAAAAAAAAAAAAAAD6/WCfzgHRtRdc8J+jDnv80gwX7NGtW7c/",
  b"fMubb548blQAAN7YvVhXKfOIMDFO/K1gOgAAAABgAAAAAAAAAL7OBgAAg4fneQEAE97YvahXKf0WZcDO/Q1MBwAAAAAAAAAAAAAAMGcRAIAEM11JXQC+2N0GV6nziM+JsRMAUgIAAAAQAAAAAAAAAIAf3wA2s9JgzdCRFQkzSHuRAAoAHmi9",
  b"bOTmG2/1esIODW7sjO1ffrpytTna6gSIGYUAgAAAAHNskkOXT9dkNb+19rerOZM3dr7D8xmVdWWuaK7oZeGltta31jeaOJpo19i1d6W9q82bPaOFZ9P0GU2f8cINRXMLLwtn7WXhrJ19a47pmI7pJFuZUA6NgokzQIcAAA==",
])

///|
let oggtags_flac_b64 : Bytes = oggtags_concat([
  b"T2dnUwACAAAAAAAAAAAModxOAAAAANyJEsYBM39GTEFDAQAAAWZMYUMAAAAiBAAEAAAAAAAIFQrEQPAAAAAAAAAAAAAAAAAAAAAAAAAAAE9nZ1MAAAAAAAAAAAAADKHcTgEAAAAfFeW/AWWEAABhDAAAAExhdmY2My4xLjEwMgMAAAAZAAAA",
  b"ZW5jb2Rlcj1MYXZjNjMuMS4xMDIgZmxhYxMAAAB0aXRsZT1PZ2dGbGFjIFRpdGxlFQAAAGFydGlzdD1PZ2dGbGFjIEFydGlzdE9nZ1MABDoRAAAAAAAADKHcTgIAAAACtGTcCf9i/3b/S/93o//4qQgAUEwAAAEAAf8C/QP4BO4F4OYkmNb9",
  b"8MQfSA6fj0CawAoTJmQoZkkkyFChhkoQpgRDIVDTOaFMl5ZzOTklklPDyZJOTJQww8OE4ShOTJkyZlDOFkiGlNNMnmUnMzmTChQoUKTMkhSZMIUhyZzMlOUKZmc/nClDKZmTJQnhKHIUMMwyYThQ4ZJOBYSkKFkNChTzTLlCnNCoSyZhocLM",
  b"ycMyYTDIZMmQpOGhmFIWEQlw8uaaEpSRJSk6EsKThECUMoUOGSFJJDIcOZMkyYZhTMoUkpSX858OFkoUlJOTMMyFJMJMJ4UJkycM4ZQ5nLCyzJZSkoecmcoSw5MkoYWFIZChkKZJMhQkmcpKZ8plMznTwsoWTyYcwyShSEyZCUJkkkkwoSkk",
  b"4UCySlPKShOcKF8s08KZQsKZSHOTDkJklCTChQwoUJKBYcwIknDkpMp5SlNkKZ5+UznmSaBSTqWC//ipCAFXTg+mD9MP8Q/+D/wP6Q/GD5PmJtjHAhSsFj+hYL2+88DwgAcpSkv2cwiFhhYFJQoZOEkyZJJkwKEwwzMyUCJnMn0OdhElKUkQ",
  b"85hEnChyZMhSQ4TCZJhKBYFCYYThzhLJSUNCJfcp8/PykwzDJmFDgUCkhKGQySSZDhSFCgULJQuSnllSRPmgQQ0lOcykocKEkyTCTAoTJKAUJkoZQoFJQ5KFJTQ/nKZSkoWZpOZMKGTDCkKEmQwySYZDCgcnCIFJMzlCJSlOWRNlhZShEzKG",
  b"gRDJw4cMwkkhkkwmSSgZMMKSUOZz/LQp5SeUOXNAiGFM5KEkkIgSgZChhhmSSTIUmHKFOEQpTpyRC5yIZZQpChQIkpkoWGGGQoGSTDMJgUkkKGhknPOFwsoRmnQqU0KcpIhSUMwoZCkkwyYTDDIZChyckoShMKTwpTn5z9KFMhEpksmhTKGT",
  b"ApJCkChMMMwwyZJk5MzhnDlDQvL7KEA1ev/4qQgCXkgGfQWPBJwDpAKo5iBz73vTB+qQW8AA8lDhTPJpwzMKSUyUMmhyTJQJw5D4eQ5CkwygRJKGeWEIkmTkmnNCcnDmFJMmZnCUlIczIUzyeQpTKSkLgUyGhLnNDyck5zOQ0kLIQpOE5OSc",
  b"kkphnhKTQhSSk5zmZTOGkKSmTJmTyQpDkmcyZhTDCyTklmchUJZnMyUmZSTzk8k4UoSWQzJkoQlhKTIUw8nhOGcznDSFhh4SlDPCUw5DKTNCUhpJwlOHJMnCcmSnPzJzkpmcOFJ4Th5KSkzIUhlJNIWGThEIUyhhzMsmc4fPJkzw8ylJKZOT",
  b"JOZwmHhQyUk5PCTh5k0J4ZKTJofDoczmhzkksMyZOTJnKENCUmSUkLDnKcMzPCknOUhZPIeZmcmk0OYcnkzmHJhwhzISkOSTmUlwlmHkpk5kpIBdzf/4qQgDWU7zCvJ68fjxhPEe8MjwgPBJ5ic/xFYcJAIf1rB2vwrA/gAPlnLhTKFJQoUh",
  b"mZMOSZJQkwoFAwoUJKBSFOBEJlCyUmRC9KU3CJnn5Qzh5kkoBQkmGGGSZDDDJkknJmEQsoWESUpenvMymgRCZTMzJgRCTJkyTDISZCkwpkoTnMInhELJZSUyzQ2aShYU5h4c4TJDCUOFDJJklJOGcn5SZmWeFNChEzSks+k4UhQoFCkJQzCF",
  b"JJDhwhQzhwIgaSmTmUlORP9MoU8xAiHJQyhQKEoTJgUJkwySZkoSUKTCyTk58pTlCymUlKZocygXOEQKSZJMMChhhhkMhSZDhZmETMoaEQp5YadPlnQnJKBSZhSSgczJkkkhmBQkwyThQ4eaBBChcskT5ENCkoUKZkzMhSYZMKEwoGGEmHIU",
  b"MwklDCkKFIUKBElMlCMpQsoX0pSUKclDQzOSZMMwKQoFITCcDhhwpJKQiFJToRCyzoenKVRj//h5CAQBOXBM9CT01vWU9lz3LfgI+OrmLMSjCHB7bWjPjwbAr0EAKGGSEwJhJChJwoFApnzmU5EIhExCIRKzUIhSIEQpCIZKQocKBQoEQKBk",
  b"hMJJCYSGQwyHCgWGZKeyhFq5dqYjJGIyay7LixMTCMLLFioJhShZIlEoExQpIopCYsllEy4mTCDCZGIxNaakYmtXVUtVFKSkWlCYWLKhYWBsLg==",
])

///|
fn oggtags_find(tags : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for pair in tags {
    if pair.0 == key {
      out = pair.1
    }
  }
  out
}

///|
test "ogg tags: Vorbis comment header" {
  let data = @libavutil.av_base64_decode(oggtags_vorbis_b64, 100000).unwrap()
  let ogg = @libavformat.av_ogg_vorbis_open(data).unwrap()
  assert_eq(oggtags_find(ogg.tags, "title"), "Vorbis Title")
  assert_eq(oggtags_find(ogg.tags, "artist"), "Vorbis Artist")
  assert_eq(oggtags_find(ogg.tags, "encoder"), "Lavc63.1.102 libvorbis")
}

///|
test "ogg tags: Ogg FLAC metadata blocks" {
  let data = @libavutil.av_base64_decode(oggtags_flac_b64, 100000).unwrap()
  let ogg = @libavformat.av_ogg_flac_open(data).unwrap()
  assert_eq(oggtags_find(ogg.tags, "title"), "OggFlac Title")
  assert_eq(oggtags_find(ogg.tags, "artist"), "OggFlac Artist")
  assert_eq(oggtags_find(ogg.tags, "encoder"), "Lavc63.1.102 flac")
}

///|
test "ogg tags: Opus muxer writes OpusTags comments" {
  let mux = @libavformat.ogg_opus_muxer_new(channels=1, pre_skip=312, tags=[
    ("title", "Opus Title"),
    ("artist", "Opus Artist"),
    ("TRACKNUMBER", "4"),
  ]).unwrap()
  // A 20 ms CELT mono packet.
  mux.write_packet(b"@").unwrap()
  let ogg = @libavformat.av_ogg_opus_open(mux.finish()).unwrap()
  assert_eq(oggtags_find(ogg.tags, "title"), "Opus Title")
  assert_eq(oggtags_find(ogg.tags, "artist"), "Opus Artist")
  // TRACKNUMBER maps to the generic key.
  assert_eq(oggtags_find(ogg.tags, "track"), "4")
  // The untagged constructor keeps an empty comment list.
  let plain = @libavformat.ogg_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  plain.write_packet(b"@").unwrap()
  assert_eq(
    @libavformat.av_ogg_opus_open(plain.finish()).unwrap().tags.length(),
    0,
  )
}
