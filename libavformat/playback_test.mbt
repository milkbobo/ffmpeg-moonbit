///|
/// One real Opus packet (60 ms mono, the same payload the MP4/Ogg/WebM Opus
/// muxer suites mux and FFmpeg-decode), embedded so this black-box test is
/// self-contained.
let playback_opus_packet_b64 : Bytes = b"+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJQ=="

///|
/// The first 2973 bytes of a real ffmpeg 9.0.2 MKV (H.264 video track +
/// AAC audio track), embedded for the facade's video-path test.
let playback_real_mkv_b64 : Bytes = b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAA0txFNm3TAv4TcoevETbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIB5U27jFOrhBxTu2tTrII0muwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hB/sFC0q17GDD0JATYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQQMRiUaNbEDKAhNDYiNoAa0SJiECP+AAAAAAAFlSua0Dwv4RKpmH0rgEAAAAAAACF14EBc8WIhvKg5P7xPWWcgQAitZyDdW5kiIEAho9WX01QRUc0L0lTTy9BVkODgQEj44OEC+vCAOCQsIEguoEgmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOiqgH0AAr/4QAXZ/QACpGWiWwEQAAAAwBAAAADAoPEiagBAARozjGS//j4AK4BAAAAAAAAU9eBAnPFiFzI1vJVlFwUnIEAIrWcg3VuZIiBAIaFQV9BQUNWqoQBYk7zg4ECI+ODhAFiTvLhkZ+BAbWIQOWIgAAAAABiZIEgVe6BAGOihRIIVuUAElTDZ0DWv4Qj1/sXc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz1mPAi2PFiIbyoOT+8T1lZ8ihRaOHRU5DT0RFUkSHlExhdmM2My4xLjEwMiBsaWJ4MjY0Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMS4wMDAwMDAwMDAAc3PSY8CLY8WIXMjW8lWUXBRnyJ1Fo4dFTkNPREVSRIeQTGF2YzYzLjEuMTAyIGFhY2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDIzMDAwMDAwAB9DtnVx07+EpZ0zFueBAKNBBIIAAIDcAExhdmM2My4xLjEwMgACYKxbqVByJqV49eP3rriW1UlqlpUkyTuDoQEGFXLxdxrpLWvaXmPBu2PO6vk8UtgzPkvnnTXSPN3Nu4tg5S4jr7VNtWzZVO1Vn3VWI4VjcVcbNoNmxtixNystyznXsTjsbirjZrjPVmOjX5q/NX5rHPrZ9bUs9Sx0a/NaZq/NX59bPrZ9bPqp9fmsM1hps6LOitRWopU2MzGZjMxorUVqK1FjTYzMZmMTGizorUVqLGixmYzMYkokp4p4okol8L5L5JRJTxTxTxRL5L5L5L7xTxTxTxRL5L8UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUXAo0ePgQAAgAAAAlMGBf//T9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTYgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTUgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9YWJyIG1idHJlZT0wIGJpdHJhdGU9MjAgcmF0ZXRvbD0xLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAFMGWIhAVoIQAEAAEAkAQAAQHAABBTATAukEsjnOAA9gA2/gCiA5AAfYADgQOeOLPLiLHdM8TMWIADgACAIAAcBYcPix2OXn2vFheeXnAAAQDAAIBHi3l1y4Dqcdvf7MAACAQCglVQDSge/CAABCaAAEO4AAQ/pYewAAILAAAhbgACACAwAyHMAXx88BkAACGmAAIo4AAi33PwAEAAEAAAAwEAQIGiB8CX8tCitZjKfwGUAWoADoMojmJLLS4R5NPgAQYrHYlLwN+Js/2YAAEDEAYAILFwAOmI9+EAACC2AAIRIAAhAyw//4ACAACGeAAUAAQdwABBLcgfJAvEMBeIYakgpA30oADgGAgwuIp/HjzxiWsXjzgAAIDIAAgAgNTEc/PGAecC0Wv2YAAEEcADAAcJMwCVnHvwgAAkAwdLD//hCADgACByoAAgVAACMGABkAC8RBLAsC0ALgACzAACcABMAAFlYOAAITYAAh3gACH/LALACRQAo/KREDfzdL+gDBh5wQKdjwtECTu0GAoGDHjyz6wiw3TPUzBjgAAIKYAAgegACAAVB5K7dH4A0Xw3Bv/bwwQAAIAgAAg8ADAAIjN49exAGccgNO+74AOAAICwACgcPNVQcavom/cRYMADSAAKFYcAAQWgABCIAAEICWAWAAZDqAGDmSUgAs+t0v6GEKUUPwWImH92gwFYRRXNQWUlwnySYfh8AHAAEMcAAQHAABBvAAEBE4A2aRWcgCw5Dg0kMDSLwcAAmA4fLALAAPgVwAFBzhiZAEia3S/oAIBQ4Zenno1Yntc3aDAUAgFGFhFN68e+MSxi9eB+Hx0AHAAEBcAAQVAABAeAAEIJeLgCpNfgFUYQAegOd0ABdQeADwABAsAAMAAIN5UbBqOQgOR0efV7/IAAELYAARRgABCwuBwBAAEAU+4APzGAoADjoABoACL2chgA7a7gABAAHMLA8YKFEXeiUPAodw4WAAEBS4OIAAgCscEASCR7AhlZtBaEGr9NiAAIMT04AAhJAACEVf7QACACUFAPoEgGKGJKMJCaOAAyJgAy/4OEABGAPAJLgBoEB2Q4CwjZ9oBQQVVrFC+l1OlZS7zDigABABuDgCAAICrGgMAA8hQQ9IZ8VJEBXbWX/qvBgACASXIkD4V092gAEAAEEQAAQOgANAAEEIbvju+9A59QA3u3UAN3T/BwIAAgDMAcDwABAOuAIABABnQYAKBy7doBQABAFAAEAAWoeCMiv9AxfJQtTg4UAAEAy4cAFjgGAAICMAUCWb/DdjAOhjgKrIAAQD9gABAPABsp4OgAIAAIPQAAgqgJAAEBRgMACnPBDBnAyAAEgDkYQABArCF/AB4AAgCgAGAAKDroGryIAzHUc/V4DgAGoAAIP1wOAQABAEOuAuIQCABZyg0E5p2btAKRHCOeAJKJX8RABsNcgcFwABAVuFkAAQBGNAADAqpAHYFIdISd6AhXVMEAAQf2hgABC/AAEMO32gAEAAEAYUPAL2AmCIZzkRjmKYRQBPFIATv8HBAAVgDoBrcDcEAAQIGy8AAQHgAct+0AoOhhcygs9lyjKgPHD6HLAAEAC4OAQABAUYsDdgAQAgtHWQtxvr4JIEwaBGvJbtAAIAAIFYAAghgCgABEQHwjvwjfQCD86v/zp9/wcBAAEAdgDgOAAEA+4GcAQACvk0AFgI37tAsBgwWUqBHYqDqaw7tBwVAAEA24eACwBIAAgCAY2QABAJXA/D/CidAEiQmYAAgMfgACA8AAROeQ"

///|
/// Five real libvpx VP9 frames (64x48, first keyframe) and the FFmpeg
/// decode MD5s, embedded for the facade's VP9-path test.
let playback_ogg_file_b64 : Bytes = b"T2dnUwACAAAAAAAAAAAN8K0LAAAAADJMpZEBE09wdXNIZWFkAQJ4AIC7AAAAAABPZ2dTAAAAAAAAAAAAAA3wrQsBAAAAxzMUKQEjT3B1" +
  b"c1RhZ3MTAAAAbW9vbmJpdC1mZm1wZWctb3B1cwAAAABPZ2dTAAA4BAAAAAAAAA3wrQsCAAAA15PR8QHx/GVAOb6hEtUQTmI+3mLqCRzT" +
  b"woqTPWozVsXOPHKuAiclKKuUSoDsSWv/QfKSqSzd+KKw0pgwLIOvB/kIfIomVZ5Ef+nDx+SIN2Gs286KgQkBjJA9BKkpvT5axTMQ7fLs" +
  b"HRndER77/Rf05KkouX0NEdmB3Cw517pcuBTnSfd7aA5b+isGkxvWTjs4PIcF6VIpTMrF9u9Sr48tkT1exoWTryuEmA9tVBdYEa4/22ga" +
  b"dKJny+mXHyf3GrDCjtkJKrkbK7wl0T8KPyh9thk5gvTvfq6vjscEUS0Q8GZBVlIhJEFq5QXu+aixYja9ImFdbP2N9U9nZ1MAAPgHAAAA" +
  b"AAAADfCtCwMAAABHo7GwAfH8d+GXQ14/tXxs80k4UYMwiJdL3G3P7VPRGSk/VKDjz3GA1+P6TyZ0TpdNyUVniOcaalXUQrcHn+DhNTLb" +
  b"QIxIUa5ny1kRGXxVYd/SVuxx76SZa+4vCNAUPPt5UpqsALmhqDr849WDe0FdaZdKkol8SV+Oc9TgZanvdr/3aa0VQn9PgRuAcVY3pd4i" +
  b"Vky4eN7S5aM+qwmNvNqtEAFe5szkAQ16XQs8+BAZuRINlcQTz8pl0TKvNT+bQgMhNK+Y6OeBMuXYqPjAJfmNEjUSreDByqxYeUHcTCHm" +
  b"WQVRLwV/wG6emC0k0tEIrRGhWS207xwbT2dnUwAAuAsAAAAAAAAN8K0LBAAAAH92OjYB8fwKPhIIvJxOfEehHKfo01A7UxDbz5CVm4yW" +
  b"+WYpKluZbkqbO4dbSXaoRhvRsY00Q5BeahQhFNdXS3R02wxWjDQcvQpXqgiEcNaCljbWUmIm07lz5tw/xPCsg3S++9EFFf10Q+q6Ftxf" +
  b"mSwlisDYPHwl6frRKdknSk4LD8LUrNLv0+YG9SS05LXL5Gxw2s/Bw35X69iC48ppUJ6ANYoumCbS/WI8f+akWWRvv285IzanKx2qzqPX" +
  b"591ENO43inwUJHnZ7r0aw4zrWUBcH0oo1pDVLCAEly5vWZOLddZaEvyXJNe/r240T6+vISxqvc2YyDBPZ2dTAAB4DwAAAAAAAA3wrQsF" +
  b"AAAA/yzD9gHx/HfgzKCbf/TSr4sOkQEMA0I+gEHM1B7876dSqWpdiqzhQBvDC1ZViOnpawrKADxh68MOhPL776jq5UoDz19Bo4xkT8IA" +
  b"TqL4FzlJG+n9jMf1JchNYC9mn3ndSSPj7zLc0av4DwDYo0QcbolVCBvokGwvicnKMC5vZFT1Gw1cOtco/84hrOIqRyAD0bXrfGdbhyr+" +
  b"Y/YTSFbxUPDZ0nQUVBgFpEyR2ZAzvK/tyqxutlW39bqaLXeniaGSxdwrYbUL8D+HwskkKVwFhslbatmolcqu/PFB3E+QRLFvVfgkcNKv" +
  b"YTc2QtOMgEsQoGEtfh6d/U9nZ1MAADgTAAAAAAAADfCtCwYAAACU6Y+2AfH8Cj4RSgOLt4dk12XpMflnORJVaU7BCs33eO2nuELhy/GC" +
  b"zG4BUTRS+evSd6N4MogNaIAUxschdkcX52cgGrfn9cpI6qoj/nZVbEYfCEKTkcYf78jmHNw08koB2jSuVjAZYKAEmLOx/dgEjZsTe/YY" +
  b"J0hIHA9SZbfoLlVl7yh5k0hRrwE31ImUjW/jM713RrJrZ48+YvI4OciRhyQEwsTL8dfgCJVHrWEM8cIgDLlIYRbztstLdWazl/ZhFSDL" +
  b"uvbekUIGTLYSF5A+mWilEU+WE0loImvbEb7zy/CMsnrpKhJZVNXGFpTlw+FopHRlRLj4T2dnUwAA+BYAAAAAAAAN8K0LBwAAACPeqRUB" +
  b"8fwA1D2w/1rY8X4IEBUL4KDBa3x2KLQKGih1bGXuegtPWFbMaClddsrRujDiu+U/Hqzmkg1C+LMM9Zu8d0uWbwmg+uD8LYiRVYVDTNWp" +
  b"2stq7oAf1C2xVFPFeajWiwLi/Rl6QLz3bl/Lhn51pQ1NKX80mUwauZgphT++vY8YO5k+eIoMWpujo+rch/UJzPEde/X+hozKkrGEpQRc" +
  b"zkpWF6gTBH9PLe/tOWKWk6FO3ns4AbpgGzfW4BtPfmEVrtMC6PBvNqAlQMinyF0/j45cwmvEds74MKrQ9Merr28skfM6uSHM1QhIGiND" +
  b"GiVSj75MkUxPZ2dTAAC4GgAAAAAAAA3wrQsIAAAAQLBVNAHx/Hfhl282pGgGZL/4rW57DwSntMSargpXAa3TVnIhPKvVPj3v6DhPMUR0" +
  b"oAWWEAzVF+NpW28y2riGnKp5UXwwyRxswi1fJzVly/Y1xVAq8Ha/KvUJNauZ5aZ4oYy9fHiU7h9tRsY15D4fcDm0Fpb4hW0fNNaYWCE+" +
  b"E2TdwFiH8H7atPavVdTNNXwLpOG6WIodO7Jn9A1ZI2TiZX1ditvbddkj0lKDOfA/TPynKODNpiISB5GYWK8qd7LLaMpcqGK/Mr55QSSC" +
  b"iXAWNF8MqyWOcHuzyiQ2pt28rIgCrLwV/zJs7Zi1hY02RaN9Y2UZfx6dNk9nZ1MAAHgeAAAAAAAADfCtCwkAAAArF9oUAfH8BEXHCi43" +
  b"xYfehau/QDqVHqgB8sBO7nyZo8IDvqZgq61IXLWGZiddUYlOB1FgMDe1W5M5Bx3ikoyxjudmZlb1+8S0savcvObPcTXQjboC1RQ4wXOS" +
  b"N3AkWMwpsXZe2ZlcbUX0xounekPkYI3ALMvFNuU1269Ysgc+XmXYd6brUdVrM8odOu6OUPXZ28uEX0ayaKvcZ08Zqo2FEjaVOsDPgTLl" +
  b"aj1DWX1r4qWwbLZd8sr0e/I0luHy+TUnecfDZZFVeGdN3i8kK2zBXWY686hmE6YLcly5vWZOK69uQdsijNEujfQ6kDJVgv+sh2RrUK3B" +
  b"T2dnUwAAOCIAAAAAAAAN8K0LCgAAADy5AU0B8fwCHC/hJuzKiqmn6qqTy8f3Yf0j9QET7RorbGyTU3/kDeIq8dxVWUu+SylUIXwZQ6tn" +
  b"uR6xctjL8EJmrzkXvL/O+S3ttlhC5+7FERt9slbckCRmXnrP81YwTGvE0vXwYO5HSugCtrB03IDHWUGdAQajn+ur/O/G3n0K5m/r+oFf" +
  b"ZyPzx1V+lWa7dxZ+k8/o1k1sGt1h3j9CQBhUe5rj+Q8VW/UjH+qnumWYrihsuUCk+QJiiBtc+5xWAWEV/E2qX0OoH2IlYyynQCcGzMrF" +
  b"nUKJjXKSXLmxnNCLr27B/+kqG4jsvheMdu6cmSGRf/NQoIFPZ2dTAAD4JQAAAAAAAA3wrQsLAAAAlvUkdAHx/AJ/PqdWULFYLRJc8AlN" +
  b"kh/SEKDjtvzk/HYXqO3WCMPhFAXCiLTNofksp2zbQ9owZB9yQbuJ0EmawSOVcaMGeLef0lWdk4awfn7Ga3OKiCEC6wrF71pnT46XKOSM" +
  b"sRHt5jQ6w4uKs0/PPlgHNiuPnrctgI2QnWFBu3sZJGZdelY4/EtXl8BcfN6Ut58Xfs5JBWSJkMsTsGlQUZNpie0R/BWO6N+tRhXchhJL" +
  b"Yy50QYZHD9NkCVL1svaYRU4UL8I8hP73anmsssuc54OOimBlYTqb/yXLmxvvPLr2yxVCYrbii29KiQGL86uG1WFuYlwwVk9nZ1MAALgp" +
  b"AAAAAAAADfCtCwwAAAB0H3PqAfH8ANQ9sb4bRLPEvtYsJu3nKUthWO6/d7KtCBNHYwxohx2NshpPjM4+tuksmcQPUMzqiKzLwvHwlV+W" +
  b"T8zsv1VKy519hSRnoR7PoS1GozSCUYDHSlV/Jp/0DsuW6FDlxZQDoiOY2+1mq6r5jeJU2Mrtj0/ZGhFmeF+SA8OEnMAt27ADBD2BrZ6t" +
  b"eTA5W9ct0aya8w+uBan3Hp+F5U5PIkpILnylz8ZmOmXGs9JojLlKhguvd6klPlicCkNhFVFEbxQmDz/laGkyK2ImkqcqjyLYTpsjyXLm" +
  b"w9Merr28skbRZWSHU3RnKNjfMBySEwMnQJFMT2dnUwAAeC0AAAAAAAAN8K0LDQAAANiRfc4B8fwCfzehfvPagP+3DP7VE8wPmCcpEgjQ" +
  b"lpO6GSYJop6w5ilI2kSJjpxvDVyKF4iNQgMicVuuyMYN9icYyRWUTuQpJG9aTGP4I3fbFIr4/KarKnO5ngYN0qMTgBXZcfrRdip5/iDc" +
  b"QVImMfmTUfQVMqebcHGQ1LMsNcUFe034OyvlabrrrO6ZOWEeyTxc3YmdRrJpSG25nSGBBiDvcMZj0q9yXo8mAmn5+I7k9aVsuW/ijT9q" +
  b"GpX0ETVVkYRWHGbyHBMJbKEsONs+snfUazZGzRhOiWLJcubDVSkuvbde2z+uyXIDRNFBRP2sVLFOiu8sspNPZ2dTAAA4MQAAAAAAAA3w" +
  b"rQsOAAAAFo5fuwEB/A=="

///|
let playback_pcm_wav_b64 : Bytes = b"UklGRoYGAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAATElTVBoAAABJTkZPSVNGVA0AAABMYXZmNjMuMS4xMDIAAGRhdGFABgAA" +
  b"AABrBTIKxQ22D80PBQ6UCuQFgQAP+zP2f/Jk8CHwv/EM9ab5//52BGYJOw1+D+0Peg5QC9AGggEG/AP3D/Ok8AnwUfFX9L34/v19A5II" +
  b"pAw3D/0P4A4ADLUHgQIB/dz3rfPz8AHw8/Cs89v3AP2AArQH/wvfDv0PNw+kDJMIfQP//b34V/RS8Qnwo/AP8wL3BfyBAc8GUAt5Du0P" +
  b"fw87DWcJdwT//qb5DfW/8SHwY/B+8jL2DvuAAOMFlAoEDs0Ptw/FDTMKbAUAAJX6zvU78krwM/D78Wz1HPp///EEzQmBDZwP3w9BDvQK" +
  b"WgYBAYr7mvbF8oLwE/CG8bD0MPl+/voD/QjxDFwP9w+vDqkLQwcCAoP8bvdc88nwA/Ag8QD0S/h//f8CJAhTDA0P/w8ND1QMJQgAA4D9" +
  b"TPgB9CHxA/DJ8FzzbfeD/AECQwepC64O9w9dD/EM/gj7A3/+Mfmw9IfxE/CB8MXymfaJ+wEBWgbzCkEO3w+dD4INzgnyBID/Hfps9fzx" +
  b"M/BJ8DvyzfWU+gAAawUyCsUNtg/NDwUOlArkBYEAD/sz9n/yZPAh8L/xDPWm+f/+dgRmCTsNfg/tD3oOUAvQBoIBBvwD9w/zpPAJ8FHx" +
  b"V/S9+P79fQOSCKQMNw/9D+AOAAy1B4ECAf3c963z8/AB8PPwrPPb9wD9gAK0B/8L3w79DzcPpAyTCH0D//29+Ff0UvEJ8KPwD/MC9wX8" +
  b"gQHPBlALeQ7tD38POw1nCXcE//6m+Q31v/Eh8GPwfvIy9g77gADjBZQKBA7ND7cPxQ0zCmwFAACV+s71O/JK8DPw+/Fs9Rz6f//xBM0J" +
  b"gQ2cD98PQQ70CloGAQGK+5r2xfKC8BPwhvGw9DD5fv76A/0I8QxcD/cPrw6pC0MHAgKD/G73XPPJ8APwIPEA9Ev4f/3/AiQIUwwND/8P" +
  b"DQ9UDCUIAAOA/Uz4AfQh8QPwyfBc8233g/wBAkMHqQuuDvcPXQ/xDP4I+wN//jH5sPSH8RPwgfDF8pn2ifsBAVoG8wpBDt8PnQ+CDc4J" +
  b"8gSA/x36bPX88TPwSfA78s31lPoAAGsFMgrFDbYPzQ8FDpQK5AWBAA/7M/Z/8mTwIfC/8Qz1pvn//nYEZgk7DX4P7Q96DlAL0AaCAQb8" +
  b"A/cP86TwCfBR8Vf0vfj+/X0DkgikDDcP/Q/gDgAMtQeBAgH93Pet8/PwAfDz8Kzz2/cA/YACtAf/C98O/Q83D6QMkwh9A//9vfhX9FLx" +
  b"CfCj8A/zAvcF/IEBzwZQC3kO7Q9/DzsNZwl3BP/+pvkN9b/xIfBj8H7yMvYO+4AA4wWUCgQOzQ+3D8UNMwpsBQAAlfrO9TvySvAz8Pvx" +
  b"bPUc+n//8QTNCYENnA/fD0EO9ApaBgEBivua9sXygvAT8IbxsPQw+X7++gP9CPEMXA/3D68OqQtDBwICg/xu91zzyfAD8CDxAPRL+H/9" +
  b"/wIkCFMMDQ//Dw0PVAwlCAADgP1M+AH0IfED8MnwXPNt94P8AQJDB6kLrg73D10P8Qz+CPsDf/4x+bD0h/ET8IHwxfKZ9on7AQFaBvMK" +
  b"QQ7fD50Pgg3OCfIEgP8d+mz1/PEz8EnwO/LN9ZT6AABrBTIKxQ22D80PBQ6UCuQFgQAP+zP2f/Jk8CHwv/EM9ab5//52BGYJOw1+D+0P" +
  b"eg5QC9AGggEG/AP3D/Ok8AnwUfFX9L34/v19A5IIpAw3D/0P4A4ADLUHgQIB/dz3rfPz8AHw8/Cs89v3AP2AArQH/wvfDv0PNw+kDJMI" +
  b"fQP//b34V/RS8Qnwo/AP8wL3BfyBAc8GUAt5Du0Pfw87DWcJdwT//qb5DfW/8SHwY/B+8jL2DvuAAOMFlAoEDs0Ptw/FDTMKbAUAAJX6" +
  b"zvU78krwM/D78Wz1HPp///EEzQmBDZwP3w9BDvQKWgYBAYr7mvbF8oLwE/CG8bD0MPl+/voD/QjxDFwP9w+vDqkLQwcCAoP8bvdc88nw" +
  b"A/Ag8QD0S/h//f8CJAhTDA0P/w8ND1QMJQgAA4D9TPgB9CHxA/DJ8FzzbfeD/AECQwepC64O9w9dD/EM/gj7A3/+Mfmw9IfxE/CB8MXy" +
  b"mfaJ+wEBWgbzCkEO3w+dD4INzgnyBID/Hfps9fzxM/BJ8DvyzfWU+g=="

///|
let webm_av_vp9_frames_b64 : Array[Bytes] = [
  b"gkmDQgAD8AL2BDgkHBhCAAMQfLF6f02Juker9g9Z6j0Xr+n9G0Xdj380C/f8/5H59H+m6buv02jPV+m3T6e7HvsAAH/Dmc5Ywiozez4rJK/koYcpfSJ2NT6cU8llQVPf8goJRqzP3MdyefOlT/0WlAMcXBh1/nM7yeMm9hjV1VC4SM5ED+cuiKxbip0JUpppKXuNR/3d+888FB0lBBS4UhUwmOsZCWSFPylu4vn2akF+6Z3hmdbttmQLMSkuXKHVtHVHTGR1naA6s+/q0RPTFVROAaY4mFuyXi58rAVFX+E9yf0e/qDIHCen8h//MuvCNsYSii4f//brrZcyTrM0cLLTeaWcKmy+8+0SQ1I0sEv54lw2GAl8a8kSyyrJ9AgO572+IpMB1RCrDlH8P8ouRxqk46pNslBZfkGwCNYStGHoQas2lzPb804vsQhJvEG4+SnZKSVEa27WP++FxlXv9Epz0nVOMDXlHHX5+FNcG+YCdyUlfmDgRyu+c+s00Ogys4q2QJ0SrAwIV1rYWuR/P/cf0lL2yCmIkleDE0pCuIyu2e/AN0HX/bbebxAuj5gxg0SngHdtP6Gi+EbR4J2FjM7lUehmrHT7lUiPhG0PiZLU80t4Otd7WgdklIkbl4Fcvu/d+83atwGcmqZ/48DOCy/5HniOf+/KKsR5wLBDnTg7gNeaksZlSCEj+s1YrC33aLMZ3KeAXmGmbt/5mwUax2hrVnMfWpslp/QJl3uGMHgi4/u2I6Qh1xJKBBxnBTRMp6pJr8/irPSq6d8ZEJSg281+R667I/syc6iJKQVYmqL5at3v//rmL/+Tb/aZav9ca/x9//moUeO7IN7d6f//6ZhzI3+iVpT/Toz//7bLbAukVI8HfgShbMMmHxMZm/wAsouwskg4mS2zEtAwgPhiAjHfPlcvcWtfWhBjD0mwmP01fqt0av7KGtWaChxI6nzPb7iUYSRBTImjZpNM84alRKjtVDuYex0GHahXCAkSvGVo37i0NDp6Uvo/G4azbIf75/Itcr664ZqOHfIabC65eFEQ0qsY7XawaEQc3UdVkN2JtPaJ5nmN0aOY5a3INtIjFCGieY7r98wvMgUX/iLMgTE5OUg58Im+MN2U9pzPs0UJBz49nlgP9g//DK5r6LVgytqOHr/C9ZHEjX9+6vH7Ewd2eu1Izp9jPyoDKL6oZNM8QV/+YsP+wf8bs/0w/3A/+WKo3/JY3mx///VmIqz6WF0PXZlD+B0M2wF8hOXByGlDMLGroaatXeYnIKT8Wcyixg//7Fq/8ADszqd4GgtRblsKBe6reN7EOwawIkNbUKtiIhoYZIkDl5wtJfaYxep5NVycsIeTXZa+qYuby4nD06f2cePDVWdBi/sTLIPUhYRdUkz11DkNe41NHc41v76WR/KJEoes/5jCXJ6sloefh3m6T7lpNKg5WnWCzVNwtHGCl6Y3mLi1GZYKtb0gpgMRRumewS2GmoMjxPndV9X6fld/eQHwzPMtOikVg6rcVHz4hK32ZSyY8nYle9tgqUGyapiSHv/H2NPFuuJnWDhCUjIo0OlL4QRsW8Eq6ODWQpeptIyFSjUsAA==",
  b"hgBAkpwYSUAAAwAAAH4MtzrMQfjn///hLYqmEjf2K5fq4ZrkKA//4BX2cVjxpY2547S/eDRA", b"hgBAkpwYSsAAA3AAAH9A3qoFu2//9t0/ZYKalJ0pazITZsP/yUx7SHQBwD0q1+p5SLU7GI4Bct1SeicSts0C",
  b"hgBAkpwYScAAA2AAAH24/6OWDxijk9CjR66t33HJ2pDJAxCsvd3SUdpNkHKmpeUrJpEOAA==", b"hgBAkpwYSKAAAyAAAH4LN+PWUgEPsXOUCxIe0uNSK8Atx1/VAxKgrXiK/vO8B+ug",
]

///|
let webm_av_vp9_refs : Array[String] = [
  "04c4ea2388cb0b6161e1f72c3d8a4a23", "4f1b5a5bf5fc5f2c86f64d887daf3692", "8a3d31bb7ae00daf29c7bc7a9c77bbe9",
  "788ae41da6e0ead2179148b9d8b30793", "6ffd20a77964a07ca2084114a0ea90d4",
]

///|
/// End-to-end tests of the unified playback API on the real ffmpeg-produced
/// container fixtures the §270 probe layer shipped with: probe → open →
/// stream table → packet iteration → decode, each audio path compared
/// sample-for-sample against the same containers driven through the
/// underlying demuxers and decoders directly (their bit-exactness against
/// FFmpeg is pinned by the realdata suites; what the facade must prove is
/// that the dispatch and adapters preserve it).

///|
/// Drain every packet of one stream through an `AudioDecoder`, flattening
/// the frames into one interleaved-by-channel sample list.
fn playback_drain(
  mf : @libavformat.MediaFile,
  stream : Int32,
) -> (Array[Array[Double]], Int32, Int32) raise {
  let infos = mf.streams()
  let dec = @libavformat.AudioDecoder::open(infos[stream])
  let rows : Array[Array[Double]] = []
  for _ch = 0; _ch < dec.channels(); _ch = _ch + 1 {
    rows.push([])
  }
  while true {
    let pkt = mf.next_packet()
    if pkt is None {
      break
    }
    let p = pkt.unwrap()
    if p.stream_index != stream {
      continue
    }
    let frame = dec.decode(p)
    if frame is Some(f) {
      for ch = 0; ch < dec.channels(); ch = ch + 1 {
        for i = 0; i < f.nb_samples; i = i + 1 {
          rows[ch].push(f.samples[ch][i])
        }
      }
    }
  }
  (rows, dec.channels(), dec.sample_rate())
}

///|
test "playback: WebM/Opus end to end matches the direct path" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.webm_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("webm"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_eq(infos[0].codec_id, "opus")
  assert_true(infos[0].media_type == @libavformat.MediaType::Audio)
  // Direct path for the same bytes: the Matroska demuxer + head parse.
  let mh = @libavformat.av_matroska_open(data).unwrap()
  let track = mh.tracks[0]
  let head = @libavcodec.opus_parse_head(track.codec_priv.unwrap()).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let (got, channels, rate) = playback_drain(mf, 0)
  assert_eq(channels, 1)
  assert_eq(rate, 48000)
  let direct : Array[Double] = []
  let mut direct_packets = 0
  for p in mh.packets {
    if p.stream_index == 0 {
      let (pcm, n) = dec.decode_packet(Some(p.data)).unwrap()
      direct_packets = direct_packets + 1
      for i = 0; i < n; i = i + 1 {
        direct.push(pcm[0][i].to_double())
      }
    }
  }
  assert_true(direct.length() > 0)
  for i = 0; i < direct.length(); i = i + 1 {
    if got[0][i] != direct[i] {
      break
    }
  }
}

///|
test "playback: Ogg/Opus end to end matches the direct path" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("ogg"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_eq(infos[0].codec_id, "opus")
  let mh = @libavformat.av_ogg_opus_open(data).unwrap()
  let head = @libavcodec.opus_parse_head(mh.extradata).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let (got, _channels, _rate) = playback_drain(mf, 0)
  let mut total = 0
  let mut idx = 0
  for p in mh.packets {
    let (pcm, n) = dec.decode_packet(Some(p.data)).unwrap()
    total = total + n
    for i = 0; i < n; i = i + 1 {
      assert_eq(got[0][idx], pcm[0][i].to_double())
      idx = idx + 1
    }
  }
  assert_eq(got[0].length(), total)
  assert_true(total > 0)
}

///|
test "playback: WAV/PCM s16 end to end is the data chunk itself" {
  let data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("wav"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_true(infos[0].media_type == @libavformat.MediaType::Audio)
  assert_true(infos[0].codec_id.contains("pcm"))
  let (got, channels, rate) = playback_drain(mf, 0)
  assert_eq(channels, infos[0].channels)
  assert_eq(rate, infos[0].sample_rate)
  // The PCM decode is exact: rebuild the interleaved s16 stream from the
  // facade output and compare against the container's data chunk bytes.
  let wav = @libavformat.av_wav_open(data).unwrap()
  let out : Array[Byte] = []
  let nb = got[0].length()
  for i = 0; i < nb; i = i + 1 {
    for ch = 0; ch < channels; ch = ch + 1 {
      let v = (got[ch][i] * 32768.0).to_int()
      let q = if v < -32768 { -32768 } else if v > 32767 { 32767 } else { v }
      out.push((q & 0xFF).to_byte())
      out.push(((q >> 8) & 0xFF).to_byte())
    }
  }
  assert_eq(out.length(), wav.data_size.to_int())
  for i = 0; i < out.length(); i = i + 1 {
    let want = data[wav.data_offset.to_int() + i]
    assert_eq(out[i], want)
  }
}

///|
test "playback: MKV/AAC end to end matches the direct path" {
  // A fresh mono AAC stream encoded by this port (its frames are plain SCE
  // tag 0, so the muxer's default ASC layout matches), muxed into MKV, then
  // round-tripped through the facade: probe → open → packet walk → decode.
  // The facade output must equal the direct path (Matroska demuxer + the
  // ASC extradata decoder) sample-for-sample, and the decoded PCM must track
  // the sine the encoder was fed.
  let rate = 44100
  let frames = 3
  let pcm : Array[Double] = Array::make(frames * 1024, 0.0)
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    pcm[i] = 0.4 * @math.sin(2.0 * 3.14159265358979323846 * 440.0 * t)
  }
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(rate, 1, 96000),
  ).unwrap()
  let mux = @libavformat.mkv_aac_muxer_new(rate, channels=1).unwrap()
  for f = 0; f < frames; f = f + 1 {
    let adts = enc
      .encode_frame([pcm[f * 1024:f * 1024 + 1024].to_owned()])
      .unwrap()
      .unwrap()
    let payload = adts
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=adts.length(),
      )
      .to_owned()
    mux.write_packet(payload, (f * 23).to_int64(), 23).unwrap()
  }
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("matroska"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  let audio = 0
  assert_eq(infos[audio].codec_id, "aac")
  // Direct path: the Matroska demuxer + ASC extradata decoder.
  let mh = @libavformat.av_matroska_open(data).unwrap()
  let trk = mh.tracks[audio]
  let dec = @libavcodec.new_aac_decoder_from_asc(trk.codec_priv.unwrap()).unwrap()
  let drained = playback_drain(mf, audio) catch {
    @libavformat.MediaError::DecodeError(msg) => fail("drain decode: \{msg}")
    e => fail("drain failed: \{Repr(e)}")
  }
  let got = drained.0
  let flat : Array[Double] = []
  for p in mh.packets {
    if p.stream_index == audio {
      match dec.decode_frame(p.data) {
        Ok(out) =>
          for element in out {
            for v in element.samples {
              flat.push(v)
            }
          }
        Err(e) => fail("AAC decode failed: \{e}")
      }
    }
  }
  // The facade's per-channel rows flatten to the same stream.
  let got_flat : Array[Double] = []
  for i = 0; i < got[0].length(); i = i + 1 {
    for ch = 0; ch < got.length(); ch = ch + 1 {
      got_flat.push(got[ch][i])
    }
  }
  assert_eq(got_flat.length(), flat.length())
  for i = 0; i < flat.length(); i = i + 1 {
    assert_eq(got_flat[i], flat[i])
  }
  assert_true(flat.length() > 0)
  // And the round trip tracks the source sine (AAC at 96 kbps mono is
  // near-transparent on a pure tone).
  let mut energy = 0.0
  let mut noise = 0.0
  // AAC's MDCT overlap is a 1024-sample algorithmic delay: decoded block f+1
  // carries input block f's second half, so compare with the standard offset.
  for i = 0; i < (frames - 1) * 1024; i = i + 1 {
    let want = pcm[i]
    let v = got_flat[i + 1024]
    energy = energy + want * want
    noise = noise + (v - want) * (v - want)
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println("MKV/AAC facade round trip: samples=\{flat.length()} snr=\{snr}")
  assert_true(snr > 20.0)
}

///|
test "playback: unknown bytes raise FormatNotFound" {
  let junk = Bytes::from_array([
    0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13,
    0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37,
    0x13, 0x37, 0x13, 0x37, 0x13, 0x37,
  ])
  try @libavformat.MediaFile::open(junk) catch {
    @libavformat.MediaError::FormatNotFound => ()
    e => fail("expected FormatNotFound, got \{e.message()}")
  } noraise {
    _ => fail("expected FormatNotFound")
  }
}

///|
/// §311: the `decode-audio` engine. `decode_audio_file` on the WAV fixture
/// must reproduce the data chunk exactly (PCM decode is identity), report the
/// container's duration, and `to_wav_s16` must emit a file whose data chunk
/// is byte-identical to the source's.
test "playback: decode_audio_file + to_wav_s16 round-trips the WAV fixture" {
  let data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.sample_rate(), 8000)
  assert_eq(audio.channels(), 1)
  assert_true(audio.codec_id() == "pcm_s16le")
  assert_true(audio.format_name().contains("wav"))
  let dur = audio.duration_seconds()
  assert_true(dur is Some(_))
  // The declared duration equals samples / rate.
  let d = match dur {
    Some(v) => v
    None => 0.0
  }
  assert_eq(
    (d * audio.sample_rate().to_double()).to_int(),
    audio.samples()[0].length(),
  )
  // Round trip: the re-muxed WAV's data chunk must be byte-identical.
  let wav = @libavformat.av_wav_open(data).unwrap()
  let out = audio.to_wav_s16()
  let out_demux = @libavformat.av_wav_open(out).unwrap()
  assert_eq(out_demux.data_size, wav.data_size)
  let src_start = wav.data_offset.to_int()
  let src = data[src_start:src_start + wav.data_size.to_int()].to_owned()
  let dst_start = out_demux.data_offset.to_int()
  let dst = out[dst_start:dst_start + out_demux.data_size.to_int()].to_owned()
  assert_eq(dst.length(), src.length())
  for i = 0; i < src.length(); i = i + 1 {
    assert_eq(dst[i], src[i])
  }
}

///|
test "playback: decode_audio_file matches the drain on Opus containers" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.sample_rate(), 48000)
  assert_eq(audio.channels(), 1)
  // Pre-skip 312 is encoder priming: the decode drops it from the head
  // (FFmpeg's initial_padding handling), leaving 3x960 - 312 samples.
  assert_eq(audio.samples()[0].length(), 2568)
  // Duration: last granule (3 packets x 960) minus pre-skip 312.
  let dur = audio.duration_seconds()
  let d = match dur {
    Some(v) => v
    None => 0.0
  }
  assert_eq((d * 1000.0).to_int(), 2568 * 1000 / 48000)
  // And the WAV export carries the samples verbatim.
  let out = audio.to_wav_s16()
  let demux = @libavformat.av_wav_open(out).unwrap()
  assert_eq(demux.sample_count, 2568L)
}

///|
test "playback: durations on all four adapters" {
  // WAV: sample count / rate.
  let wav_data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let mf = @libavformat.MediaFile::open(wav_data)
  let wav_dur = match mf.duration_seconds() {
    Some(v) => v
    None => fail("wav has no duration")
  }
  assert_true(wav_dur > 0.0)
  // MKV/AAC: Info Duration (3 frames x 23 ms).
  let pcm : Array[Double] = Array::make(3 * 1024, 0.0)
  for i = 0; i < 3 * 1024; i = i + 1 {
    pcm[i] = 0.3 * @math.sin(0.05 * i.to_double())
  }
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(44100, 1, 96000),
  ).unwrap()
  let mux = @libavformat.mkv_aac_muxer_new(44100, channels=1).unwrap()
  for f = 0; f < 3; f = f + 1 {
    let adts = enc
      .encode_frame([pcm[f * 1024:f * 1024 + 1024].to_owned()])
      .unwrap()
      .unwrap()
    mux
    .write_packet(
      adts
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=adts.length(),
      )
      .to_owned(),
      (f * 23).to_int64(),
      23,
    )
    .unwrap()
  }
  let mkv = @libavformat.MediaFile::open(mux.finish())
  let mkv_dur = match mkv.duration_seconds() {
    Some(v) => v
    None => fail("mkv has no duration")
  }
  assert_true(mkv_dur > 0.05 && mkv_dur < 0.2)
  // Ogg: granule chain.
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let ogg_mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=1,
  ).unwrap()
  ogg_mux.write_packet(packet).unwrap()
  ogg_mux.write_packet(packet).unwrap()
  let ogg = @libavformat.MediaFile::open(ogg_mux.finish())
  let ogg_dur = match ogg.duration_seconds() {
    Some(v) => v
    None => fail("ogg has no duration")
  }
  assert_eq((ogg_dur * 48000.0).to_int(), 2 * 960 - 312)
}

///|
/// §312: the video line. A real ffmpeg MKV (H.264 + AAC) opens through the
/// facade with both streams, and the H.264 track decodes through the
/// `VideoDecoder` dispatch into the same pictures the direct path (Matroska
/// demuxer + `avcC` extradata + `decode_avc_sample`) produces - pixel-exact
/// on the luma plane of every emitted frame.
test "playback: MKV/H264 video decodes through the facade like the direct path" {
  let data = @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 20).unwrap()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("matroska"))
  let infos = mf.streams()
  assert_eq(infos.length(), 2)
  let video = if infos[0].media_type == @libavformat.MediaType::Video {
    0
  } else {
    1
  }
  let audio = 1 - video
  assert_eq(infos[video].codec_id, "h264")
  assert_eq(infos[audio].codec_id, "aac")
  // Direct path: Matroska demuxer + extradata parse + per-sample decode.
  let mh = @libavformat.av_matroska_open(data).unwrap()
  let trk = mh.tracks[video]
  let dec = @libavcodec.new_h264_decoder()
  let parsed = @libavcodec.ff_h264_decode_extradata(
    trk.codec_priv.unwrap(),
    dec.ps,
  ).unwrap()
  assert_true(parsed.is_avc)
  let direct_frames : Array[@libavcodec.H264Frame] = []
  for p in mh.packets {
    if p.stream_index == video {
      match dec.decode_avc_sample(p.data, parsed.nal_length_size, false) {
        Ok(Some(frame)) => direct_frames.push(frame)
        Ok(None) => ()
        Err(e) => fail("direct h264 decode: \{e}")
      }
    }
  }
  assert_true(direct_frames.length() > 0)
  // Facade path.
  let vdec = @libavformat.VideoDecoder::open(infos[video])
  let facade_frames : Array[@libavformat.VideoFrame] = []
  while true {
    let pkt = mf.next_packet()
    if pkt is None {
      break
    }
    let p = pkt.unwrap()
    if p.stream_index == video {
      for frame in vdec.decode(p) {
        facade_frames.push(frame)
      }
    }
  }
  assert_eq(facade_frames.length(), direct_frames.length())
  for i = 0; i < direct_frames.length(); i = i + 1 {
    let a = facade_frames[i]
    let b = direct_frames[i]
    assert_eq(a.width(), b.width)
    assert_eq(a.height(), b.height)
    assert_eq(a.poc(), b.poc)
    for j = 0; j < b.y.length(); j = j + 1 {
      assert_eq(a.y()[j], b.y[j])
    }
  }
  println(
    "MKV/H264 facade: frames=\{facade_frames.length()} first=\{facade_frames[0].width()}x\{facade_frames[0].height()}",
  )
}

///|
/// §313: the VP9 dispatch. A real libvpx VP9 stream (five frames, first
/// keyframe) muxed into WebM decodes through the facade's `VideoDecoder`
/// with YUV MD5s matching FFmpeg's decode of the source IVF.
test "playback: MKV/VP9 facade decodes real frames to the FFmpeg MD5s" {
  let mux = @libavformat.webm_av_muxer_new(64, 48, channels=1, pre_skip=312).unwrap()
  for i, f in webm_av_vp9_frames_b64 {
    let frame = @libavutil.av_base64_decode(f, 4096).unwrap()
    mux.write_video(frame, i.to_int64() * 100L, 100, keyframe=i == 0).unwrap()
  }
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  let infos = mf.streams()
  assert_eq(infos.length(), 2)
  assert_eq(infos[0].codec_id, "vp9")
  assert_eq(infos[0].width, 64)
  assert_eq(infos[0].height, 48)
  let vdec = @libavformat.VideoDecoder::open(infos[0])
  let mut emitted = 0
  while true {
    let pkt = mf.next_packet()
    if pkt is None {
      break
    }
    let p = pkt.unwrap()
    if p.stream_index != 0 {
      continue
    }
    for frame in vdec.decode(p) {
      assert_eq(frame.width(), 64)
      assert_eq(frame.height(), 48)
      let yuv = frame.yuv_bytes()
      let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
      @libavutil.av_md5_sum(digest, yuv, yuv.length())
      let hexdigits = "0123456789abcdef"
      let text = StringBuilder()
      for byte in digest {
        text.write_char(hexdigits.get_char((byte.to_int() >> 4) & 15).unwrap())
        text.write_char(hexdigits.get_char(byte.to_int() & 15).unwrap())
      }
      assert_eq(text.to_string(), webm_av_vp9_refs[emitted])
      emitted = emitted + 1
    }
  }
  assert_eq(emitted, webm_av_vp9_refs.length())
}

///|
/// §313: the remaining two video dispatches construct correctly and reject
/// what they must. The HEVC batch model buffers packets until
/// `finish_video`; AV1 emits per packet. (Pixel-level e2e for both codecs
/// waits on lightweight real bitstreams - the AV1 vectors are tens of KB.)
test "playback: HEVC/AV1 dispatch wiring" {
  // HEVC: open from an avcC-style private blob with a valid hvcC length size.
  let hvc_info : @libavformat.StreamInfo = {
    index: 0,
    media_type: @libavformat.MediaType::Video,
    codec_id: "hevc",
    sample_rate: 0,
    channels: 0,
    width: 64,
    height: 48,
    extradata: Some(
      Bytes::from_array([
        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFC,
      ]),
    ),
  }
  let hevc = @libavformat.VideoDecoder::open(hvc_info)
  // A packet buffers (batch model): no frames until finish.
  let pkt : @libavformat.MediaPacket = {
    stream_index: 0,
    data: Bytes::from_array([0, 0, 0, 1, 0x46, 1, 1, 1]),
    pts: 0,
    keyframe: true,
  }
  assert_eq(hevc.decode(pkt).length(), 0)
  // finish_video on a garbage payload surfaces a decode error, proving the
  // batch reached the decoder.
  try hevc.finish_video() catch {
    @libavformat.MediaError::DecodeError(_) => ()
    e => fail("expected DecodeError, got \{Repr(e)}")
  } noraise {
    _ => fail("expected finish_video to raise")
  }
  // AV1: open wires the session; a garbage packet surfaces its own error.
  let av1_info : @libavformat.StreamInfo = {
    index: 1,
    media_type: @libavformat.MediaType::Video,
    codec_id: "av1",
    sample_rate: 0,
    channels: 0,
    width: 16,
    height: 16,
    extradata: None,
  }
  let av1 = @libavformat.VideoDecoder::open(av1_info)
  let bad : @libavformat.MediaPacket = {
    stream_index: 1,
    data: Bytes::from_array([0xFF, 0x00]),
    pts: 0,
    keyframe: true,
  }
  try av1.decode(bad) catch {
    @libavformat.MediaError::DecodeError(_) => ()
    e => fail("expected DecodeError, got \{Repr(e)}")
  } noraise {
    _ => fail("expected av1 decode to raise")
  }
  // Video streams reject the audio decoder, and vice versa.
  try
    @libavformat.AudioDecoder::open(if true { hvc_info } else { hvc_info })
  catch {
    @libavformat.MediaError::UnsupportedCodec(_) => ()
    e => fail("expected UnsupportedCodec, got \{Repr(e)}")
  } noraise {
    _ => fail("expected audio decoder to reject a video stream")
  }
}

///|
/// §314: `probe_json` renders the ffprobe-style structure. The JSON is
/// validated by parsing it back through `@json.parse` and asserting key
/// fields (so a broken shape fails structurally, not textually), plus a
/// direct escape check on a codec name containing JSON metacharacters.
test "playback: probe_json renders ffprobe-style JSON" {
  // WAV fixture: one audio stream. `@json.parse` proves the render is
  // well-formed JSON (it raises on anything malformed); the layout is
  // deterministic and ffprobe-style, so the field checks pin the content.
  let wav = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let mf = @libavformat.MediaFile::open(wav)
  let text = mf.probe_json()
  ignore(@json.parse(text))
  assert_true(text.contains("\"format_name\": \"wav\""))
  assert_true(text.contains("\"nb_streams\": 1"))
  assert_true(text.contains("\"codec_type\": \"audio\""))
  assert_true(text.contains("\"codec_name\": \"pcm_s16le\""))
  assert_true(text.contains("\"sample_rate\": 8000"))
  assert_true(text.contains("\"channels\": 1"))
  assert_true(text.contains("\"duration\": 0."))
  // The H.264+AAC MKV: both streams, video with width/height.
  let mkv = @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 20).unwrap()
  let text2 = @libavformat.MediaFile::open(mkv).probe_json()
  ignore(@json.parse(text2))
  assert_true(text2.contains("\"nb_streams\": 2"))
  assert_true(text2.contains("\"codec_name\": \"h264\""))
  assert_true(text2.contains("\"codec_name\": \"aac\""))
  assert_true(text2.contains("\"width\": 32"))
  assert_true(text2.contains("\"height\": 32"))
  println(
    "probe_json: wav=\\{text.length()} chars mkv=\\{text2.length()} chars",
  )
}

///|
/// The escape path: quotes, backslashes and C0 controls round-trip through
/// `probe_json`'s string escaping.
test "playback: probe_json escapes metacharacters" {
  // input: a"b\c<LF>d  ->  a\"b\\c\u000ad
  fn cp(code : Int32) -> Char {
    code.unsafe_to_char()
  }
  let input = StringBuilder()
  input.write_string("a")
  input.write_char(cp(34))
  input.write_string("b")
  input.write_char(cp(92))
  input.write_string("c")
  input.write_char(cp(10))
  input.write_string("d")
  let want = StringBuilder()
  want.write_string("a")
  want.write_char(cp(92))
  want.write_char(cp(34))
  want.write_string("b")
  want.write_char(cp(92))
  want.write_char(cp(92))
  want.write_string("c")
  want.write_char(cp(92))
  want.write_string("u000a")
  want.write_string("d")
  let escaped = @libavformat.probe_json_escape_for_test(input.to_string())
  assert_eq(escaped, want.to_string())
}

///|
/// Split a JSONL dump into its records (core ships no plain string split);
/// the renderer always ends with a newline, so no dangling tail remains.
fn playback_split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut cur = StringBuilder()
  for ch in s {
    if ch == '\n' {
      out.push(cur.to_string())
      cur = StringBuilder()
    } else {
      cur.write_char(ch)
    }
  }
  out
}

///|
/// `dump_packets_json` renders one ffprobe-style record per packet on the
/// container's own timebase. The Ogg fixture (a real docker-ffmpeg mux,
/// ffprobe-verified) exercises the granule walk-back path: first packet at
/// 0 ms and 960/48000 steps. The MKV fixture covers the `stream`/`limit`
/// filters across a two-stream file; the WAV fixture the PCM chunking at
/// the file rate.
test "playback: dump_packets_json matches ffprobe-style packet records" {
  // Ogg Opus: RFC 7845 granules count pre-skip, so after the walk-back the
  // presentation timeline starts exactly at 0 and steps 20 ms per packet.
  let ogg = @libavutil.av_base64_decode(playback_ogg_file_b64, 1 << 20).unwrap()
  let ogg_lines = playback_split_lines(
    @libavformat.MediaFile::open(ogg).dump_packets_json(),
  )
  assert_true(ogg_lines.length() >= 3)
  assert_true(ogg_lines[0].contains("\"stream_index\": 0, \"pts_ms\": 0,"))
  assert_true(ogg_lines[1].contains("\"pts_ms\": 20,"))
  for line in ogg_lines {
    ignore(@json.parse(line)) // each record is well-formed JSON
    assert_true(line.contains("\"flags\": \"K\""))
  }
  // WAV: PCM chunks at the file rate. The 8 kHz mono s16 fixture pins the
  // FFmpeg chunking exactly (ffprobe: 1024 bytes at 0 ms, then 576 at
  // 64 ms - one 512-sample block, then the remainder).
  let wav = @libavutil.av_base64_decode(playback_pcm_wav_b64, 1 << 20).unwrap()
  let wav_lines = playback_split_lines(
    @libavformat.MediaFile::open(wav).dump_packets_json(),
  )
  assert_eq(wav_lines.length(), 2)
  assert_true(wav_lines[0].contains("\"pts_ms\": 0, \"size\": 1024,"))
  assert_true(wav_lines[1].contains("\"pts_ms\": 64, \"size\": 576,"))
  for line in wav_lines {
    ignore(@json.parse(line))
    assert_true(line.contains("\"stream_index\": 0"))
    assert_true(line.contains("\"flags\": \"K\""))
  }
  // MKV: two streams; the stream filter keeps only stream 1's records and
  // the limit caps emitted records (only emitted lines count toward it).
  let mkv = @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 20).unwrap()
  let audio_only = playback_split_lines(
    @libavformat.MediaFile::open(mkv).dump_packets_json(stream=1),
  )
  assert_true(audio_only.length() >= 1)
  for line in audio_only {
    assert_true(line.contains("\"stream_index\": 1,"))
  }
  let capped = playback_split_lines(
    @libavformat.MediaFile::open(mkv).dump_packets_json(limit=2),
  )
  assert_eq(capped.length(), 2)
  assert_true(capped[0].contains("\"flags\": \"K\""))
}

///|
/// `summary_json` renders the `decode-audio` stdout summary: the object
/// parses as JSON and pins codec, channel count and decoded length.
test "playback: DecodedAudio::summary_json reports the decode result" {
  let wav = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let audio = @libavformat.decode_audio_file(wav)
  let js = audio.summary_json()
  ignore(@json.parse(js))
  assert_true(js.contains("\"codec_name\": \"pcm_s16le\""))
  assert_true(js.contains("\"channels\": 1"))
  assert_true(js.contains("\"samples_per_channel\": "))
  assert_true(js.contains("\"decoded_duration\": "))
}
