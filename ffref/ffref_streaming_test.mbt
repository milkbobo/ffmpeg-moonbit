///|
/// Adaptive-streaming differential against the path-based FFmpeg oracle:
/// HLS and DASH presentations, staged to /tmp inside the image and demuxed
/// by the real libavformat (which follows the playlists and opens every
/// segment itself), then compared packet-for-packet with our StreamingMedia
/// fed the same bytes through `media_fetch_from_map`.
///
/// The fixtures are deterministic ffmpeg outputs (sine/testsrc2 sources;
/// audio `aac 48k mono`, video `libx264 yuv420p keyint=5`):
///   hls  -hls_time 0.32|0.3 -hls_list_size 0 (video: independent_segments)
///   dash -seg_duration 0.32|0.3 -adaptation_sets id=0,streams=a|v
/// (isoff-live profile: SegmentTemplate + SegmentTimeline.)

///|
let ffref_fix_hls_a_list_m3u8_b64 : Bytes = b"I0VYVE0zVQojRVhULVgtVkVSU0lPTjozCiNFWFQtWC1UQVJHRVREVVJBVElPTjowCiNFWFQtWC1NRURJQS1TRVFVRU5DRTow" +
  b"CiNFWFRJTkY6MC4zMjAwMDAsCnNlZzAwLnRzCiNFWFRJTkY6MC4zMjAwMDAsCnNlZzAxLnRzCiNFWFRJTkY6MC4zMjAwMDAs" +
  b"CnNlZzAyLnRzCiNFWFRJTkY6MC4wMjEzMzMsCnNlZzAzLnRzCiNFWFQtWC1FTkRMSVNUCg=="

///|
let ffref_fix_hls_a_seg00_ts_b64 : Bytes = b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABAAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4A" +
  b"AAABwAfYgIAFIQAH2GH/8UxAE//83ABMYXZjNjMuMS4xMDIAAmioWamMdBa114r7fe16viQXV1Yo7ZJJEgE3TD6d8TT1s210" +
  b"i6u4JZJmb+TVvGqV5erjPYmtV2m2HQrLYrDZrjXrjZqzPTsdIv0i/NVSlspZPrZ9VKVWGjDRhj246sdWMmOE2E2GjDGTGTGT" +
  b"GSaSbCZ5pJpJpGkaRpJnoeZ2BkSJEbNmzaJEil7/8UxHAQARQBnf/AE0mNrJXdZLyyXllPG/389W2tS7f/Hj9/OtcavV3//c" +
  b"9fv51rjV6uf/2+/x51rWtXqxtTs265555mstlnuFF7/ZQMG6B9KFfSgfT6azAfT6fSgD6fT6awPp9PproMAPp9PprM2APp9O" +
  b"f6UMAH08+duhJgABrnrRYtUn823SIQxM+UTPlEz5fKImD5fLjEwfL5cSYPl8vlFEQA+Xy+XGKIAfL5ZYiAAniUoCKIAN668v" +
  b"WcCQkEcBABKQkJCQkJCQkJCQk4EhJwJuiUvA//FMQAu//AE69Ar6oR6EQ6EQs1/H9Prz5488TqcJLvSN25LVaeyrbNMN08AG" +
  b"Gxzzx/htL7G/jM277+4P8fBk+/uQyfAGf3A+MzYz+4B/FgBInDqY0uYRGQAPFUHA//FMQA+//AD+NCzooj6FQ6I0aRK/v/2/" +
  b"5/zcdJkk1u8vdu9ub0yVUKoClrnlUbYR4sS6DsHr2S1y5ZeplNyo0csssssoHLVERwEAE/oqq06e1CBFJilYeI60Kbu906gw" +
  b"XoQL+hlm4JUrwRyaNXFIQnt30XAnYJWY4wWonC5FM92v//FMQAz//AEENCzpDRKHUGHSvbf7f/T9f/P43WtVMjNaqR21uk3d" +
  b"KqarAGFWnS1RUbxZ3VmGw3nNp7eQkJCQkJ0Tok4E05ppks+TuvCs8wLxATnkctQL0z3W5bxm5OtJS9qOP92zgP/xTEAQf/wA" +
  b"8jQs6R0Kh0Zh0Zj0jdf+P7/r/89HAQAUEq5eU4rd3S3tWRulZqrmwaXcwuaAyMawyT7ZwQq2ktz6N9G+jfsudA30bkw4GvUL" +
  b"176IBWXm8cMaDeINeszJokFQ3+0vIQ73ynT9t8rfJJovzH7cqWMl2prS2NHQcPwOvO0re72NeP/xTEAO3/wA+jQs6Q0Sh0ah" +
  b"0ph0ir/b/6/j/140vnjI1V0lPXi+brKlUaYAzNkpwCl3r7pHH0nWJUXQF/of0P6H+xu3dxYFi7tuV3SOo7bt2kcBABWch1Hd" +
  b"u+Thhbl7fJF3WGer6HjL7a1SYSjmXGI04Jpy+Pv2frKc//FMQBC//AD2NCzsVF6ZRaJR6RVf1/+v/P+/67TjZKtdXT1c3dKq" +
  b"VUjIC1x9YccMN5LT9dejaDeh/SsSzyzyzy98s8oYeDKU00wY0csPJFnTgw1/gX6VY9r39IWaOfjemQjcRefTG7rXKkXwpVcq" +
  b"QrjSCUpw5Vq021JDkm0U7m7bgdXK3P/xTEARf/wA+DQs7FRmRwEAFoVDo2DpDFoRDoRCm/0//tf+3+faZ5yqiuCJTzmQpTdX" +
  b"VUEqZZcThfwvmJ3aH5D3mpl1DSUDNq0apqpnY31MsssssuOVWWKh6OQEPRUGDZn2+nIZrf1faUHnYmbnbx7cz6Q7xMFFIiS6" +
  b"xgqiHbtpIfu5ivDmPZ0XuYilcaY4//FMQA6//AEGNCzsVF6Jg6JQ6ZQ6R7c/x/6f9f+YT2yorraXTt1O7zclC2AMKxO1idpm" +
  b"JQL6nabY/2RHAQAXrQkzs7Oz9eFL65KlSpVKEnHODdc89u5zWlfbDdyp8p/epxY/7ZvM18Ee8BAbDk4VAcrSddatzSTwt//x" +
  b"TEARv/wA8DQs5EZuhYWmQOhUOkPn7f/t9//0m3XEqq1TiKPeVVbuVmThgMLmhNfPc4Z9j6fy14QKMezzzzz77Lb7juW28mIw" +
  b"MjIClJRMgICMlJROoHlnpCYDEyefbF4TK2F+AxIjklwTHLznIvkYkE4paDxTbLaE4sqivUcBABiGpvxe/W6rzbcRdfsji4D/" +
  b"8UxADv/8APw0LOkNEodGwdGgdM1n9v/j/b/v57XJIzi6kx6am7KplNKAB0jW7IzMxSIfva1I+eJrGjwMDAwNGBgdUiBgaMyx" +
  b"de6LY4npEHyB9ZAPo5R2/KwH3/c2zp7rgz62jGgQ6NYCdVaKVBItUOD9z2fL+P/xTEAS//wA8DQoyMYuiYWhUOkQehEOib9f" +
  b"x/9P/bz/vzXtrdcUvRePrTKrm5VJrNgqRwEAGX1ddOZUWlue7exeH6uomm/zfdPuny1Jvsy5tkmmnPVpoEspkuAh4ulwRDQJ" +
  b"jNLx7p0uonq1F6jmD6Xl8kSApUiEwmORUoEcLiEOCKoP7Lrhu0wz3vffyN5nfHfCfttz+zZWugxH//FMQBJ//AEGNCzpHQqH" +
  b"RsHRKTRiFxr+n/1/6/88Y+OeMlVwqSrdmbtdObIzwBRkqaC00bzaw9UWgKPM5HaQMDf8b+jIgb6trYGRIgY3QHZgRuVHAQA6" +
  b"AQBXvyuqjevZ50PKsr1+zud4JNnuk5XwieqxYBNMEE05gpyPQk3U0tNKQHNBjPO53Ep3BHHlttFO2ItMQe6LSrYH//FMQA7f" +
  b"/AD2NCzpDRKHRqHRqHTLr/X/t5//Rxz1lXKzq8rrb2070vIrJaqCZhgUc0trlllrWVvlyOXTqlb9Ju/tf2oTdyu3bt0rdu4P" +
  b"TukTvv8jeiIu4Oxc02A5y9j0muebdaTatVHmVwzyitIpB1qOLsvfHg=="

///|
let ffref_fix_hls_a_seg01_ts_b64 : Bytes = b"R0AREQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAARAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABEAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EAOwdQAACzTH4A" +
  b"AAABwAgdgIAFIQAJuWH/8UxAEn/8APw0LOkdCa9EIms/p/6fX/2u5e2k59stuU8NZk12qXmKA0xTcjnkQ3P8d/bqOLwhPQDA" +
  b"z6YGXi14YGWXrAwMwzvXhk165Z044l5li6UKxmXZM4Xs3y97b9uzrK8GTT2qxkWI3qQb7R9Wf/37Hr6JC96JTGOcFlIgTs50" +
  b"IbCj9jhkYYTPcqRVtBSs0Rz/8UxAD5/8APY0KOj2DolHAQAcg6NA6NA6MQ6Ir+3/1/5/8uua9r5hLq5I9rrdt5Ks175QBcrI" +
  b"ekuaHbDHsPlOi+HWbPLL8j+R/qfyNHLKZllxxAzZmWWWTK0X5NEwwj4l5EjiY6aYiS2Uw5mhg8YVdzt8ue9VKvBdz3Pp/9oK" +
  b"HP/xTEAR3/wA7DQppFUuiUOjYOkMmid1/b/6/8/+XUee+uUq9czjH5w3F5FdmILFYVUbWsah2417H5Xo/fVzgEokol+Uqlpo" +
  b"lyCuMkcBAB1SmjXu10UWm6KEu3PtjkThuIpE9k11upjXLqn0PC+HPpqvK4pxG96diJadXGoOF4RrtPeSzWr7seI8tWGYrXim" +
  b"qgmc//FMQBH//AD8NCzQVFMPQqHRqHRqPSOu/2/9P3/9r4rzzeRWpjUx4t3W6lTW7YCVFGM3OWJM+3b5yYGTAKn7mTqRSRSo" +
  b"0qLXjAwNxYkiJMjga9KDEmR1XklmfKkGObm98jwwVVppiYgsJiR0qDbxY81GiKjMRwEAHq54opSEk3Rqe2lRq51ytPnrMzQ2" +
  b"pGkHlFOA//FMQBI//AD2NCzpHQqHRsHRqPRkFWf1/6fr/5Xk825tosHpW5LpXcq2AiUVKctyS2WWOCXSidSHYzQW3bv7H8nr" +
  b"PteY67u3bpW7d4HUfi5ZCeDvx7brMD4O3IV/AqcDuP8faej+hX9zs7rldeSTcAd8ciApaanOi8ZCEmI4UzKsXJHGLQg0kwkn" +
  b"hZEuwNkF8P/xTEAPX/wA/DQs7ERHAQAfZomDp1HpGt/x/9f+f+vtt8eJCaisjz1e5VSpVIwAETtDXBDeb2PqqtgPrOB+pYWF" +
  b"6s+rNIkDAwtSPYYUpst2SFl6u5sck4UsHZ50qL1DhDYpr5BjmYgLDqh2rOL41rUmuYzx1MSim6tHEV5xTv/xTEARP/wA9DQo" +
  b"zR0Si0Kh0qh0qu/6f/T/2+P89+eHfnlOF5xt8aTN71RK4yoDKpbDLYaLSXHdPYPC4jQgpVNq0atEs0kwsKSTS0cBABBAo6Cg" +
  b"gNCpKgsEVA5jQTSRVrUnZUsSWf8SRTYRBle5+Pniq8mjvYzy5vCvDunKThcyX00qNuHOCfPhxrVxwP/xTEARX/wBBjQs7GRe" +
  b"hUOjYOjQOhQOkfD/X/4/5/34x7GSS92vduxkSlbppkAwrVBZ6xEzFol+/utVX7BVhdnZ8cJq5sMXmc5AkJCTlRpeqdEnNc0/" +
  b"eyy7OOWtUre3+AJu3+Ydl5fCZ3eu6OOqedQcQNfG90MsKGOQRwEAEarNcN5wfpuqwJsJcH+zMcD/8UxAE1/8APg0LOxUZoVF" +
  b"olPoxCv3+f/w+//rrHm6pEsmHle8XkAzAlROWBIVJn2LkWUA7UCBMwMjI7abW3U1neBr1l4lezGQZ3i17C4txowY9l8Hr1Yu" +
  b"b9lBDncZrj0an3XVtFTTV1ajdMQqOuMVq5lNQYvdCKmgM0cMlxbKaWmopAUk4uVxxUmYM1wtabZqSkHlGksXBMrw//FMQBD/" +
  b"/AD8NCzpExZHAQASjMWiQekXv+v/H4/84XqpMlpSTxw85VUrjJqsgMNQMbA7zMQ1YRKXz142WsUxYsDA9RgYGRAwMDF24gOR" +
  b"kjVFi8ldiACxL22yPV8XmLHQ+h532i9EP3/CIKe4/HcF60RzWolRf23cQz/7hVHCq9D10sM+tbxkw/yscP/xTEAQX/wA+DQs" +
  b"6Q0Sh0aB0aj0YhZP2//D/P+669kwW4yY9b1hVFKtmwMdXqjbjQfzOHzMj17r+9FdU03+b0cBABOWfdJku+TTTYTTLmmmXBPM" +
  b"EaN76A5nU732YYzdf6uF+FR7kmaxy+3Wz7yM92EnWgxrutzbqOIuvDLAcUUwHnGlK1TH//FMQBC//AEENCzsVF6Jg6NQ6NRa" +
  b"V7c/t/6f7f7e231tSRZKeGpuzJW7rTAFGaXUsuo3kmC1gS6A1Zm47Qzs7dvw7fCtnbYzcsqI3Ei0tWNyxo9LVq8/K6NWXPnf" +
  b"fm/D939htctszBrNAS0lcXzi7j1zTl3xRwEAFCk1dHGu25xGkcZMvDU5qOD/8UxAEH/8APQ0LOkGDoVDo1Do1FpWV+3/1/2/" +
  b"761WpkqZwEt65u6yoXmlUGphYnLApFZeNQr0+TzK9MpqP0n6T9J+k9ryESEldU3SrQnDDxboS1gNukRM4vLL2zTV8fG28ORz" +
  b"kDPYV88xv3IpsmnEt3xdXcA2k04XO4q6zypN+FpRwP/xTEASP/wA9jQs6R0Ji0Jo0jnj+3/4fv/78TNVxu6q7icx6TFHAQAV" +
  b"ReSUrIEKJmoR3fDPdcl+3ctL54T0OfDNWassLfTC16y8SvXsMy2dlbhPGDPd9mA6kWDf3z3ssvXBezzz/bn6dJHinmujHJQg" +
  b"U2nUcV71nG9apcIx/tSvZCE14lzs8HBO1mv+9t1Y+Kd3u4OA//FMQBH//AD8NCzpHQsHRqHRKTQiHRJn6f/T/f/nzvUkwXUr" +
  b"SPCtxmJRfeAUWcW1h1ieKOysQ3SKrdpqmjwP5H8j0HqPQfGdBsAZmEcBADZ0AP//////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"///////////////////////R0QNmVHLKRllTo5cXRkeX418vo93o/QWQP3KrZSPcAmDwineJ4rukVMxwSUlFiCUHGsJiarFy" +
  b"RfDMyE3VNhPDQFTg"

///|
let ffref_fix_hls_a_seg02_ts_b64 : Bytes = b"R0AREgBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAASAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABIAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EANwdQAADrjH4A" +
  b"AAABwAfegIAFIQALmmH/8UxAET/8APg0LOhSfoROYdEImeP2/8f9/9PMb6yQtGXWQ9avLoXVbCZKeVTx0I+Vur/i/e5JXyTJ" +
  b"ZpvuyWgUa6L1mtj1uurbH0Y7Q0DDpW10c+3dA0yEBax1yvgMmOhSm1ZqROHgp6OdscZK2KUGjn1cHMVmVNH26l0ukrIwue5g" +
  b"UVtOaVbA4P/xTEAQn/wBCDQszGJmhFekee/n/6f6f7dHAQAY1jV1KvJJbduvd0IopkAoyViQpmfGsB/IeePHwdDdnZ2c62du" +
  b"MPyPOrmE9SgT6HFQzBqHmn4RNK5pn31KNPnlL05fvkvdWq6jbjIk/VSXW07yhtnNTVAhz51mjG1azgy2YOaNbu/ShgSPU4D/" +
  b"8UxAD3/8API0LOkdCwdGwdOIdEr19v/2+v/t57e1Sk1UrVQ9puKqVUrjnAYnK3oS9Tll4Bp3RPIQhbIvdu/6fyPi3ec5Xbt3" +
  b"LLLgUUcBABmRusCa/i5U6rAkDaKeXj7wH/9C3t96sT6SQ+BD1mgAsAl78iQ45IZz3hWs4Mpw//FMQBC//AD6NCzo9haFA6NA" +
  b"6NA6Ew6RH6f/2v9P/fVJ52kSVrnVvLe7qqiZvTANETsDvpxH/5ufvLn554gt0AwMDAz+mfXDx4MSBgwMPTRJBl69wiQ8vt/C" +
  b"OQZ2JJglNcD2GWbPdKZ5B/uJ/4b2c1lQzZNv47JSu9xfRvNP3zXpmPZ4+P/xTEARRwEAGl/8API0LOxEQwUHomDolFpTFo2d" +
  b"/0/7f8/7Lr67vju7avKj4ubupVFbrVUEqsqzV4moVY2JZH1z7zoN4QBQU4Ty0G5ZZfRMy44y6T4yblRq4xJVGmKl9MDyy8j3" +
  b"5aj/jTufMiTzCIpWkr6a4UPEtPGfftfZ5xu98Zp6CH7Mn/twJmzwNjj/8UxAEN/8AQY0LOkNEYdGgdGo9I+s/4/6f5/69be2" +
  b"9ZFSayR3arm1UEjAGFdUFg1MmTFHAQAbRKxx2mGP9oq28hIT/yf+SlCdk0TMEhIlLTnyyeFYk8EBvaYVZn9ne0uB7r+HtPvv" +
  b"3vzNlMqm7W66R4VKoc0nGui45qqOMEc0xFjqrSdxhv9kacD/8UxAEB/8APY0KWi2DomDqFDohDoRCrP7f+n6//p1nf1lUkuS" +
  b"Zb2tkqopVcc7AyyYvUDbkcxqPxnUDurMQhhRkUEqYUbW2pu2JXrL2d68MuFrxIZ7/jbn6wc3w3jWeVyjAxdNC0cBAByopr9j" +
  b"F5jQEgYt2cV3PlXFyua45xZSu7emk4D/8UxAEv/8APo0LOkdCa9GIXHr9P/j+f/LiTfW7TfUmJt43SkZMlZVAZm3IGoOdlvy" +
  b"4Mqik0SrhaQuB6jI3fF4mBmSN27duixOSPIyB+ej8X8TrFeONtxHLyP3OwJ244ZK7n9f/obtlG9a4mbgcufCtciaHuT/Zve0" +
  b"OwhLV03FwDD+3Jdj417jPdh7ORoJrkUznRlXIuV4//FMQA9fRwEAHfwA/jQo6Q0Si0yh0Ki0QhW/r/9f9/+t3xbKkrVXUp56" +
  b"jGWVk51kB5xax/rCPrZv5r2rR8gXqSfLPln5z9cSTYLmmwSJFnKiRcBZww13kwx3sQhmU3ZdPq+Fx8AyhFJvlbCQ2o4uy2bY" +
  b"SmYtflEhQAG3bZMc//FMQBA//ADwNCztDRKHRsHRmHTMf6//h/v/z7E0yq81Uu8fN1u14nOS2A0upww6QcdG7BWZUB5xtm9l" +
  b"WhpJpJpJqptHAQAet0STSTyYuwgKEgoKPoUCQWCAh1VBaIGiqZ1VCZ24c1JaLR4RMlc8nzuTnZwdXdQR1baJxqtGK9nO/A/s" +
  b"8P/xTEAR3/wBBDQs6RUWjYOjUekcX/H/1/3/761z53dQuVrabt3xrJWbmqwBhUzDErBZfDQL1uoztvVKaj9JCf+T9J1SE651" +
  b"yEhISJu1MAm1o4c4HxSpXvei8CJypo8atf/fklC8GGwQgxzqnwqTYGOrahmPMRN7Q2k5VkcBAB+t356r5d8Wi5JuaUimLgtJ" +
  b"5xLg//FMQBNf/AD4NCzk8yEczs38//h9//PjE6lVZcq93kzQwMpAhRIXp7bjPj/S9RD8CLciOaeeef9T9X6n9Z51K9fU56wM" +
  b"J4cLVqjg9/1pofueFrW2sBrXdvD7CRNWlDGdUEgUo5kqFcKVroPbEio05n13mOgAKNAGlT1rRUyrNd7nadRxXq4/3Z3Uhbbe" +
  b"UikVAJCa9tKq1tFUcP/xTEARP/wA/jQsRwEAEOkdCgtEodGY9CIdCIUz5//s/7/+fOlyGu9ayuvHTwyUrJSsveAA4idI1oPv" +
  b"Dk9hrUD59ncCwMDAwNGBmRcpEDqgbF13eOXg6mVqJWTgfK/4AvHJavJkwzvkex87F1EU1D38L4nvEdUzcXFGWrnfguCddNP+" +
  b"puVhI50ASKVqDv/xTEAOH/wA9DQo6Q0Sh0Rh0yh0jdf3//s//P1949typJJZb31XMzLqYmmAaUlLYaqxeOfyfnfhyj1HAQAR" +
  b"U03+bqppkk0002Ey5zzzJUp88G6J9sLTzdvG+78e/+G3W8cPp0O7bJpOL96Nz11q2pu374hw//FMQBDf/AEENCzsVEqPQqHS" +
  b"CHRKLSvZ/T/6f5/381PN8xK1OfPN47ZiZtNVWqqgKM0waebaZ94xH95WgXxVR1DdnbDHDGrGTEGBgYkDDhxIdXuG7B3MuZKV" +
  b"J8+6EildpTzrvj5PCJjGU0wzXLcfdM2tFG1b37Qg72jjfXxvmtM8DUcBADKzAP//////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////9fKkJ4"

///|
let ffref_fix_hls_a_seg03_ts_b64 : Bytes = b"R0AREwBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAATAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABMAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EAMwxQAAEjzH4A" +
  b"//////8AAAHAAKWAgAUhAA17Yf/xTEATv/wBTDQT4tIgtCmc/M++ruXLjJEiRBB1kgAkJCZiqpZZZZZTMoGBgYGBgYGBmZQM" +
  b"DAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM" +
  b"DAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD4A="

///|
let ffref_fix_hls_v_list_m3u8_b64 : Bytes = b"I0VYVE0zVQojRVhULVgtVkVSU0lPTjo2CiNFWFQtWC1UQVJHRVREVVJBVElPTjowCiNFWFQtWC1NRURJQS1TRVFVRU5DRTow" +
  b"CiNFWFQtWC1JTkRFUEVOREVOVC1TRUdNRU5UUwojRVhUSU5GOjAuNTAwMDAwLApzZWcwMC50cwojRVhUSU5GOjAuNDAwMDAw" +
  b"LApzZWcwMS50cwojRVhULVgtRU5ETElTVAo="

///|
let ffref_fix_hls_v_seg00_ts_b64 : Bytes = b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4A" +
  b"AAAB4AAAgIAFIQAH2GEAAAABCfAAAAABZ2QACqy0ITYCIAAAAwAgAAADAoHiRNQAAAABaO8PywAAAQYF//9Z3EXpvebZSLeW" +
  b"LNgg2SPu73gyNjQgLSBjb3JlIDE2NSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBo" +
  b"dHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWxHAQARIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6" +
  b"MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT0yIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAg" +
  b"bWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNr" +
  b"aXA9MUcBABIgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRz" +
  b"PTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJh" +
  b"bWVzPTAgd2VpZ2h0cD0xIGtleWludD01IGtleWludF9taW49MyBzY2VuZWN1dD0wRwEAEyBpbnRyYV9yZWZyZXNoPTAgcmNf" +
  b"bG9va2FoZWFkPTUgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9" +
  b"NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAAWWIhDfU1EYz11eQURikqiYHQA2gSFWEk2FeJguBglWxVurB6EvBMp2T" +
  b"5wuwgL0wh3SblwbIMtHvrSkufAFHAQAU+2T1ZQkBEawSZAS8I7vhHQsqpsK1CPU6esE3Ls2ysBEUpprOG1piurw8KXuE8WGd" +
  b"IST2ul0eO7WT/y/hTZT+qfEUSEYmWPg4ElO3xDmDSGGPJpKsUA9WdtnCniCeBEgumbgJl+LLd5fbkJ+S6Tnq59rxqKiHGzad" +
  b"zy7DMfxgodQ8xjBbaBnSdkHyopOTO4vVWIT2T2DvTVQZZKRvmWfEApIy6bBxrcpC3o+C6tNv6AhJw9v4Up6XEUcBABUMn32q" +
  b"qoDR0VbC3HVhJ7IT1tFyQ57i/A4IDkOf97uNusgjTvn7hsQyWvhQBCMV1VudBnC4FCBLjAqyBfuLExmFJzCqiQny8XiJsm6n" +
  b"MlWAp0wUIB1ZIdmgFHTqp5xnHB47pfGOGnsJ+FA515axeAo7nAUlPA/3ou+ZSMBllNOhEqTRx0/c/tKLTZowlsS63H5H2VZX" +
  b"maqZquFKpdrNJ2FWD73ntyWPY/8nP3cAt7UUHuAHsw0TrGcnRwEAFsFjEDOlw12yuGssIQt7fm/mmJYkZb7UaUXxtNqIp1p/" +
  b"Edfnu8J4AAnFfNzQV+rLYzjr8scNQDb+PZjeidC/DFMEc3daoOb8MT2wD7V7sg8gAqHgpxjw3GHjkG0Z2diHjwD0Najxai8r" +
  b"2lNRP/VP5UEiDEtNJWdEpRErS9xqRFVF7wb56klYSQRr507NqYZyW/xBHlUhuaLkGZjoYyJMJCvXLBlYyk3TJYxEoqpSR6m5" +
  b"p5Lsod3WhfZHAQAXnb8DDdGdiN25kSwP8M24aQ6RgQ/4np0KUQzIty5/4G1JBS92s/uHmMGxXOXm+Kfhj8EP6MlBYUUJ0/5o" +
  b"N4Bzaqk5Qh/5SJI5Z2PzDuy8r3q9rQrKxJl4iOgJTCoSmsLEuEJ8j9q7bw4s16wFVttK7cSMpU7lF1KXIT9ttft3OD7lZNTN" +
  b"VQnkC6pUUYUGU6TjMTqGsAgTEPunWatvSI3826Vs57MEns3ZeGGEfvv734ut1uElGeMJIUcBABhKEEWeqWxBzsaYc4wqlpAA" +
  b"0BEwOYWzrJaRXA/JFos8mgjS6uYX3rneSo4KB5OctYj6MVt5FXXjcYEilJTCQQraIg4Yt5J8VMX/kRgMHz/cFmud2TCh25Bi" +
  b"lKudsXTtV6VyLtpyRXYkoQ9rn+GZ5sbwRk/9Z34A9J9PzNAFSUiJukDMb/WKuFxVUnuiEsQ54/GvvPcgOa1ee7h7iwu7yh9G" +
  b"X969a7ORlJl5QD4P3lBajB41h0vHM/jdRwEAGQVSff8zbWTI+rxMTjgnZnHgfDJGojWTD+nTwkzliu2PxA2ypTJNIEdR2E0k" +
  b"P/30blY3en044qBqWghZqEkxIemY00SObLxyFmFUksa3YEvjQtMjQ2WTX42Ey99hhgCVDWCRdP+6ldOG+3iI9/C4ogDc62fv" +
  b"gAA9T/6QSUGyZ4NKN53zF70w2xPsB8N3GDz46KEjCDi2PK//BFDdnN8NHPtPeZ05gkAj14S6tslpjwflQLVIJY/42eRHAQA6" +
  b"swD/////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////tXmrmUdBADsHEAAAjKB+AAAAAeAAAICABSEACR6xAAAAAQnw" +
  b"AAAAAUGaJiI/sfXo3e2EZhzOOUK9rfbyDqvN1s/mfzphf9pOMr4UvLzXeFTJMs0muCRoGXdLa3/rH+3xa6Yv2PBftuLGwIeI" +
  b"ThRaLeBFC7c4xLJV3wmiI4NMfXdo2xjxqVWgnezvg+Lm/yLjzE03NixXnA0ev5xkNng5JJrgTmEgBELbtD6MsDCXPVMbaKG+" +
  b"DcUUi8gWe0ddW/qDRwEAHBBtxd7L0cjsSOck6q6L1X32O8ozv7Za+LinDPt3O9SP4HNoLsMjMIbf4WgQWvT6XPZEthZppVp9" +
  b"iWoJOh1+Su4OD9rZ87Hab2pEAowInQFdnOOwVYJMLfsQWbvDo7tGnfMZVMn1TCn0QjwIa4Dduxb8r8r8AKZmCa304eZLaF6w" +
  b"7YGwfxcB15sSHnzRiCGwBaoNcm47vMMsXBzg3bTfrQ3XRbXfp8Sl0anX3PlYIlIGOm+ayas71UxHAQA9tAD/////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////6LHgEdBAD4HEAAAnjR+AAAAAeAAAICABSEACWUBAAAAAQnwAAAAAUGaRiI/sgi4" +
  b"iS8AM6P32qjNVbQPDElQDrDdpFDqWXsDm/+/HNxUhK7h5Z46fHh8ccTEmyqFyftlFHmGCC/OQPHaRFUoNfzju4Z2iC+Om8zJ" +
  b"fPvrZLpMPydT8WjGujjnZVC2w0L50OOamSTgrgRuSrjI758gRs/pli8OHQyfHX5J+O+puuD/FTGmXmv0EpTBNmj72l8fs1hj" +
  b"RwEAH5aogO2THmIN0keliiBH+NvNbr6BUWKZASGcGvSUYWrYix8aCLOVg2lDA1CJC2pJRiU+RIbnjkMXVMT16xz5WzpcR588" +
  b"z8vunUjMW9iY/m3Li05Ro9Jp0/vBrEtTRmy7IB0de2gjju/bOaecpxOWX6xRqVZTsGXW5DLUjV3Cs3C9lU7pDJBN0UDcqR54" +
  b"ALOX1ClIyosl12UoraF1F/6wrb7rgrig52KoQQ2/Gqb9yTZXDAzsXlVG7cBHAQAwjQD/////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////////9Qy0F3Cj1DoaPoRKsnqDkwkSIydq+o3s9aD" +
  b"QZwHy3w8AZYE9TvXDhW2e0dBADEHEAAAr8h+AAAAAeAAAICABSEACatRAAAAAQnwAAAAAUGaZib/xZ/0cjdjdCU6pe+fTjG+" +
  b"e0BfQsiD1midE0M1nLJGv4FEiGRYhLA+uzAs6T4t4JWaif7lLLkmwkqRsVF+GFZXyussqFtMKXz5u8OdkA++FVoqEwHj0cmC" +
  b"p5uITYODR8LNXKBop5ufLqHJC2hVtRzFpug6YQEphyrWq8DKDkYOTVizJq5+jAcWzAEoQmQ3bXZlw7A+RwEAMgD+4/QpoDEv" +
  b"3iwEs2n94lg46IWOfKJf86+VKtpy1OtcmopC/EqPFiDUikWRO//PQF1dhJRYVni9n/tEXznP84DwWgk4DDN3cSuj3S9rxFLz" +
  b"ifJmXVjFXu3McWFc8XvjsEOLDPEXWViNtO00ux0l3uwlWEFlSBeqHeo4jVmae2tLFUN1P8bjdu9X+FlOCf1FXv+fV2i6OtVD" +
  b"62E4+9ONhgCvKr7ysbXEhfzLsAPiLfBRAS8C69GzWe9HQQAzBxAAAMFcfgAAAAHgAACAgAUhAAnxoQAAAAEJ8AAAAAFBmoYm" +
  b"/8fmetIvBYBUm2K2f0xosIV1EPVpS2gljPcDZ54T5ldzkJNCn4/lwI375CtXh4Pk+FDwmWbygeGt/LRtJmpydqki2yVatgvp" +
  b"nPB31bHCXkvMKeR+S753XKB4ySB2bIolo0bDDrxl4oBYLqDK5Vqx7angUiiiBCGepQlCSK+xSfot6Jc6hK3mScfuJ14ZGf/f" +
  b"dGiLD0cBABT0DqP/JPHBIzjL/Z5Yf+oGxirhelgNfcDR8zaiwZmQF26eJw+W88mw4xJviDJjbb9Gk4XZgf+xMdoNHitFfxxh" +
  b"+LLnhl8uu+a3ysY4kW//j5Glff3H96uJQp5DpIXgFNOVm3SsErATtO9YkUT1RdloR0EL1cZH+LDequJAtpk0Fk39Gwa9gLBL" +
  b"urwHC2mPV5HLfJUbczOi9or9nzYrWaDaZU4zCYq1wt0tOICxnCDdmKg7hr4Hb2LFRwEANU4A////////////////////////" +
  b"//////////////////////////////////////////////////////////////////////////////+AAcBM+6gOTHqPHK9b" +
  b"ONHOn8yTi/PZOSUfUWuhjb1zqOQ6GjHAg3Bbh3FvdZF4LAMc1ZR2qp3GxJrTXfDEfSy9NNYvVV2SfdwlDAp9CHj7asNil9Mn" +
  b"HwbVh3XSIh/V1eSCJfQ2abujXA8="

///|
let ffref_fix_hls_v_seg01_ts_b64 : Bytes = b"R0AREQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////////////9HQAARAACwDQABwQAAAAHwACqxBLL/////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////0dQABEAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////R0EANgdQAADS8H4A" +
  b"AAAB4AAAgIAFIQALN/EAAAABCfAAAAABZ2QACqy0ITYCIAAAAwAgAAADAoHiRNQAAAABaO8PywAAAAFliIIJ/9lnTEfXd6C0" +
  b"3J7pQtrpgmAg6WNgIf9f4up3W6EYKJldG9TxOMkBsHAxKwBMn8jBXXOSSAsIclwwkMmntWkPaSJfmQKEsXaDu2FuzAbvueCh" +
  b"qTt9ZqUN5ACxui2RHq4iShAvdOPUlZ6q/jZsMuAytmdHAQAXSshEx9mIUhJg9BdQSbxfU9yJX6tHzOP9xw5Pb+xpnuqp6sys" +
  b"QkjLvXJtjDJhIM2rvb03+L8KylWdGfAzeg/jMLxre62rmYKvvPHnSbL31ARq5+I1BKtj/sP3rcmlNzkaLsDShzPE645V0HR9" +
  b"5PFitDDOy5K9/aZdbbaHd4Ylo/ybJ6Qm3iYP5iA4eDJ0cka9O+/y1O01W/lHCi/tbN4UDLyHzAGbxQ72UWjb4cwrUbYVPYQ1" +
  b"6lpi/kcBABgi7N73DCXWGb+g9uZ5VLDapFSePKEAmiQ2joBwUSDpYHtwoDmrWo0hq2J4ukrpJt63ODedFE/4SxxXmI9uLpAx" +
  b"6OK+dX9WeUahgg4apivfevZFQF9w5s59q/RcDiZGBh6l17KbN78CIZ8mmJ3grnGf243dGRMZEI3PQt3jVxdgRFLD0YNSuAWb" +
  b"pUDA2S69bJKrMhqPfaz4hHhbsi2Hhuu+GbYyi7n/DMHO0dqNZPwRU+aHUCHjwEbmRwEAGSaNX1Kxt/kteznPF59Vk9HgaNIC" +
  b"qN0zY8NMXwD1JawIHugode4aJWc3OcWptw1j1dDCQJ6lvkKWSTnvJLt3EzeXYwENKeVFLPXR6yDfWiE87UsRcUonw+J0Vf7+" +
  b"Fz4hwKdC9DZiRtRcxzp1PDYSGmGlcNfumus9a45WJgHfJ1pu1rsIjPpqJWXt6CyH4viJAKkoGLjiVyeB3dDkFn+e0t2D2GMU" +
  b"mjbIUO7vr15hlJCcJs2qN97xXSNHAQAaq3rcEYoMjNA1tJvLyMVTqd76/iytA1Q8MB0UwQcghpsPXKcoL9VvhSkBEEKDjwpL" +
  b"rzEVnsnZC5QitM9cWQbLfOa0WuP5dIa4dI9S/7XLloG9nVs8UrbFM8gwUpAbSJGXnHty+u2xs901KFh77YzXbIuDXXYGOHuQ" +
  b"GK8KsDOa64s2CmFR2HXnMnWj4TeOW9mT1+mo6SE+xJ3zaFx+Wsoku0Dkj4qLYknTgcn9VNmessv+Tgrb1zKIC0cBABv1kSQn" +
  b"oud/jzUPLTTarU/nIlyHyNFyZtklT38pld7vWSJ9CulSdSuT4TK8zq8ZfsMHrpMNhJOCLH2FKTd/VK9F4PVZ+IagrVY2aQYp" +
  b"mQVUuhU8AClJ623Rt9Q/lxsoN1rmIK/TIqchNseC6o8IwyNLu57hczfohbWvDt7b6gz7CizJlo7IqfkTml3edNZt5shk8fTz" +
  b"viHk0gb/3Z9pQ1u4+ZhU62fU6qGVMQhozQlfCjO2PYx9QSG/RwEAHFaxuDTVO89GQ6S4GfIrVKpE4gYXVw8Y4Sc2bKvUrsb5" +
  b"VMT0gVZUOkIXxWdH9b3207iW6OGpy0+3eDsoKK2XHK4hNProZd/pE4k4A7bIm6f0QPHmp8oX1VtqpvLJAXmgHd3SKfITczRK" +
  b"+XxhXlkuviMV8ifkoWjfcAdxCVEAkRzhZ4RyO1Y5Di/S3uYPxiWz40XgIrP56WUxKt5AxaPtbrwiYc1EBVplHXj7pI/umTYq" +
  b"W8ExO0+n7ChHAQA9IQD//////////////////////////////////////////zNMZJ+vPHhcwTgS6SKvELrDZ++xBZlg9eBM" +
  b"TJVRk7iTwOkNSmieOK0w9yKHdltinJOgqa5Rit7CofA9ZgV8v3//4eIkt2l1MReOmpEJJA60aslU8Xwy1lb+FPDxNjMykaSQ" +
  b"5d3M+fD3vH54bdXfPdqoLUqq2PJhL5qmT2pVbgEifTLNhGhXMmw5RE088oMr1W8R2Qz3L0dBAD4HEAAA5IR+AAAAAeAAAICA" +
  b"BSEAC35BAAAAAQnwAAAAAUGaJiK/voSX28KPV3G5tVV6Cn/AW2F9Lex7Va7VGK7s3dAnA4RTpkrMmxe0LTqFJnVtDltT71JK" +
  b"ZtFM8bMhbzmC3P7mer/PdOHOzCwSLTu3ufZyuwtBDOh3DkUrfzLgTlpOEktY+Z4zJpaJAx3TqdBqsWHKjvZf/gqdlXlkl+vz" +
  b"iGFUZisoOxkFy13S5L8fZ531sWpaAEawRwEAPw0A////////////////pw3uzo9bx5qBGjx2vL454xfXZZXWRLL3D8upH23t" +
  b"pr7Xpf5VS6V/rhSz5RSB/It7J5jy9M9sfU37eZE7vvb7rakyQfS/hrj2kZxbI3N8kDBscIolxv1ME1Ji2C9/I7WXjKuX0vvc" +
  b"2uxo3qwL8rUaLQnu70GW3MYd2J+y29wKI01jww2mqrspr9yLmZy52HsuZN2Sv+DxgkM3oN/wqDYf8FUfnp0tlt5/fX1HQQAw" +
  b"BxAAAPYYfgAAAAHgAACAgAUhAAvEkQAAAAEJ8AAAAAFBmkYjP8TiRv7i2kGprk7eG06LW57JGnSD8tI5Sibtl/qp3AgVJY6Z" +
  b"Y9z2hoz87Q6+Cc1Ug9S2PsEUnsS5V5r+wWaLFiRuJO/jtW3WR3Eb5ibMalgKU5w8dQvyfGJB4inBU3N394nnsV8YEnO208LS" +
  b"U58p0HA2muE42g2v68CIz70xqR3UTYuAFJmkKcu95XMQnb6v+Sfn/0cBABH//q9hEYVD9MaD8cxtLDYpPOOQP6+xnBsmg6sR" +
  b"ynvjYUmmPkgQhlxTA6KmwGaw4BNbKgVVuiDZ/DJzRQYx33t2x6gAVYSWpqkpQycxwvn/zUWJxiUaD819/YTZU9PmiHA1ehD3" +
  b"1p7hPpoChYO+WKwjjk9SsRuacYIgALvoDu216Dv01MbWx2XJKPXELXQEoMWJcbSXmTYBGqw8nJ9ue7fi1RGMWzDHA5WF+yvO" +
  b"pTWSb/uc1IHQIUhuRwEAMpMA////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////+1uwO6KI8hNCpCPt70Cu4PukpZE9sV6Rvf+57YeCCG91quzrtHQQAzBxAAAQesfgAAAAHg" +
  b"AACAgAUhAA0K4QAAAAEJ8AAAAAFBmmYhD8zUVpe4P/MkyyfHwEXdvYmFJEf0VnpmTHTW9L66Hmr6VhN+eNFNqy8/I/USBshE" +
  b"I45i9hr1cs2//SU3XgR7ib9WWwtvgu1a6P9TrMWN5x74X9LrT5iEUG1XkrP1BTPkglV1YUKqVRDI4R7nJitmia6lE4rIpjL4" +
  b"wAvrak8pQZtDaV0PpPJ8+NLV2ns92FA77ZUQdUcBABSKzgUwad0u2spJwyuMnufURmkNhmUGqFmhqpxsyR7QSPyXUl/NffBT" +
  b"QUTcfIN6/uqTduU/Q2C20a83zD+MIgDc6uG01Lb7R+EFuefi4rPihTt2YscZbt7dC0iQBcff+0JT7IAWOThMvAT31bstZv8T" +
  b"hAix3wzRE8nBAl8UDwo9n1JvPp2JYG9ssRPJH2HhI8+0M3WvkbsHNrVJJHlNerrCAPAoWL2PeGbh/rnSwmIVkQqj9OYvF+qu" +
  b"RwEANZkA////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////9/Cg/LgU1bbKJitXI3Wg5sOiBpnKYnsA74U2bkAxg="

///|
let ffref_fix_dash_a_init_stream0_m4s_b64 : Bytes = b"AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAuBtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAALuAAAAAAAABAAABAAAA" +
  b"AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC" +
  b"AAAB43RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAA" +
  b"AAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAQAAAEAAAAAAVttZGlh" +
  b"AAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFu" +
  b"ZGxlcgAAAAEGbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADKc3Ri" +
  b"bAAAAH5zdHNkAAAAAAAAAAEAAABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAALuAAAAAAAA2ZXNkcwAAAAADgICAJQAB" +
  b"AASAgIAXQBUAAAAAALuAAAC7gAWAgIAFEYhW5QAGgICAAQIAAAAUYnRydAAAAAAAALuAAAC7gAAAABBzdHRzAAAAAAAAAAAA" +
  b"AAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAAAKG12ZXgAAAAgdHJleAAAAAAA" +
  b"AAABAAAAAQAAAAAAAAAAAAAAAAAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAA" +
  b"AAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI="

///|
let ffref_fix_dash_a_chunk_stream0_00001_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAu4AAAAAAAAAAAAAAAAAAAAAAAAAAAQAACA8AADgA" +
  b"gAAAAAAAAKBtb29mAAAAEG1maGQAAAAAAAAAAQAAAIh0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAACYAgAAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAAAAAAAAAUHRydW4AAAIBAAAADwAAAKgAAACYAAAAxwAAAFYAAAB2AAAAYAAAAHwAAABvAAAAfgAAAIQAAABu" +
  b"AAAAhgAAAHAAAACQAAAAjAAAAG8AAAdvbWRhdNwATGF2YzYzLjEuMTAyAAJoqFmpjHQWtdeK+33ter4kF1dWKO2SSRIBN0w+" +
  b"nfE09bNtdIuruCWSZm/k1bxqleXq4z2JrVdpth0Ky2Kw2a41642asz07HSL9IvzVUpbKWT62fVSlVhow0YY9uOrHVjJjhNhN" +
  b"howxkxkxkxkmkmwmeaSaSaRpGkaSZ6HmdgZEiRGzZs2iRIpeATSY2sld1kvLJeWU8b/fz1ba1Lt/8eP3861xq9Xf/9z1+/nW" +
  b"uNXq5//b7/HnWta1erG1Ozbrnnnmay2We4UXv9lAwboH0oV9KB9PprMB9Pp9KAPp9PprA+n0+mugwA+n0+mszYA+n05/pQwA" +
  b"fTz526EmAAGuetFi1SfzbdIhDEz5RM+UTPl8oiYPl8uMTB8vlxJg+Xy+UURAD5fL5cYogB8vlliIACeJSgIogA3rry9ZwJCQ" +
  b"kJCQkJCQkJCQkJOBIScCbolLwAE69Ar6oR6EQ6EQs1/H9Prz5488TqcJLvSN25LVaeyrbNMN08AGGxzzx/htL7G/jM277+4P" +
  b"8fBk+/uQyfAGf3A+MzYz+4B/FgBInDqY0uYRGQAPFUHAAP40LOiiPoVDojRpEr+//b/n/Nx0mSTW7y92725vTJVQqgKWueVR" +
  b"thHixLoOwevZLXLll6mU3KjRyyyyyygctUT6KqtOntQgRSYpWHiOtCm7vdOoMF6EC/oZZuCVK8EcmjVxSEJ7d9FwJ2CVmOMF" +
  b"qJwuRTPdrwEENCzpDRKHUGHSvbf7f/T9f/P43WtVMjNaqR21uk3dKqarAGFWnS1RUbxZ3VmGw3nNp7eQkJCQkJ0Tok4E05pp" +
  b"ks+TuvCs8wLxATnkctQL0z3W5bxm5OtJS9qOP92zgADyNCzpHQqHRmHRmPSN1/4/v+v/zxKuXlOK3d0t7VkbpWaq5sGl3MLm" +
  b"gMjGsMk+2cEKtpLc+jfRvo37LnQN9G5MOBr1C9e+iAVl5vHDGg3iDXrMyaJBUN/tLyEO98p0/bfK3ySaL8x+3KljJdqa0tjR" +
  b"0HD8DrztK3u9jXgA+jQs6Q0Sh0ah0ph0ir/b/6/j/140vnjI1V0lPXi+brKlUaYAzNkpwCl3r7pHH0nWJUXQF/of0P6H+xu3" +
  b"dxYFi7tuV3SOo7bt2pyHUd275OGFuXt8kXdYZ6voeMvtrVJhKOZcYjTgmnL4+/Z+spwA9jQs7FRemUWiUekVX9f/r/z/v+u0" +
  b"42SrXV09XN3SqlVIyAtcfWHHDDeS0/XXo2g3of0rEs8s8s8vfLPKGHgylNNMGNHLDyRZ04MNf4F+lWPa9/SFmjn43pkI3EXn" +
  b"0xu61ypF8KVXKkK40glKcOVatNtSQ5JtFO5u24HVytwA+DQs7FRmhUOjYOkMWhEOhEKb/T/+1/7f59pnnKqK4IlPOZClN1dV" +
  b"QSpllxOF/C+YndofkPeamXUNJQM2rRqmqmdjfUyyyyyy45VZYqHo5AQ9FQYNmfb6chmt/V9pQediZudvHtzPpDvEwUUiJLrG" +
  b"CqIdu2kh+7mK8OY9nRe5iKVxpjgBBjQs7FReiYOiUOmUOke3P8f+n/X/mE9sqK62l07dTu83JQtgDCsTtYnaZiUC+p2m2P9k" +
  b"rQkzs7Oz9eFL65KlSpVKEnHODdc89u5zWlfbDdyp8p/epxY/7ZvM18Ee8BAbDk4VAcrSddatzSTwtwDwNCzkRm6FhaZA6FQ6" +
  b"Q+ft/+33//SbdcSqrVOIo95VVu5WZOGAwuaE189zhn2Pp/LXhAox7PPPPPvstvuO5bbyYjAyMgKUlEyAgIyUlE6geWekJgMT" +
  b"J59sXhMrYX4DEiOSXBMcvOci+RiQTiloPFNstoTiyqK9hqb8Xv1uq823EXX7I4uAAPw0LOkNEodGwdGgdM1n9v/j/b/v57XJ" +
  b"Izi6kx6am7KplNKAB0jW7IzMxSIfva1I+eJrGjwMDAwNGBgdUiBgaMyxde6LY4npEHyB9ZAPo5R2/KwH3/c2zp7rgz62jGgQ" +
  b"6NYCdVaKVBItUOD9z2fL+ADwNCjIxi6JhaFQ6RB6EQ6Jv1/H/0/9vP+/Ne2t1xS9F4+tMqublUms2Cp9XXTmVFpbnu3sXh+r" +
  b"qJpv833T7p8tSb7MubZJppz1aaBLKZLgIeLpcEQ0CYzS8e6dLqJ6tReo5g+l5fJEgKVIhMJjkVKBHC4hDgiqD+y64btMM973" +
  b"38jeZ3x3wn7bc/s2VroMRwEGNCzpHQqHRsHRKTRiFxr+n/1/6/88Y+OeMlVwqSrdmbtdObIzwBRkqaC00bzaw9UWgKPM5HaQ" +
  b"MDf8b+jIgb6trYGRIgY3QHZgRuVXvyuqjevZ50PKsr1+zud4JNnuk5XwieqxYBNMEE05gpyPQk3U0tNKQHNBjPO53Ep3BHHl" +
  b"ttFO2ItMQe6LSrYHAPY0LOkNEodGodGodMuv9f+3n/9HHPWVcrOryutvbTvS8islqoJmGBRzS2uWWWtZW+XI5dOqVv0m7+1/" +
  b"ahN3K7du3St27g9O6RO+/yN6Ii7g7FzTYDnL2PSa55t1pNq1UeZXDPKK0ikHWo4uy98e"

///|
let ffref_fix_dash_a_chunk_stream0_00002_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAu4AAAAAAAAA4AAAAAAAAAAAAAAAAAQAACFQAADwA" +
  b"gAAAAAAAAKBtb29mAAAAEG1maGQAAAAAAAAAAgAAAIh0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAACMAgAAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAADwAAAAAUHRydW4AAAIBAAAADwAAAKgAAACMAAAAdQAAAIcAAACIAAAAigAAAHMAAACCAAAAgwAAAJMAAACA" +
  b"AAAAewAAAH4AAAB8AAAAigAAAIgAAAe0bWRhdAD8NCzpHQmvRCJrP6f+n1/9ruXtpOfbLblPDWZNdql5igNMU3I55ENz/Hf2" +
  b"6ji8IT0AwM+mBl4teGBll6wMDMM714ZNeuWdOOJeZYulCsZl2TOF7N8ve2/bs6yvBk09qsZFiN6kG+0fVn/9+x6+iQveiUxj" +
  b"nBZSIE7OdCGwo/Y4ZGGEz3KkVbQUrNEcAPY0KOj2DomDo0Do0DoxDoiv7f/X/n/y65r2vmEurkj2ut23kqzXvlAFysh6S5od" +
  b"sMew+U6L4dZs8svyP5H+p/I0cspmWXHEDNmZZZZMrRfk0TDCPiXkSOJjppiJLZTDmaGDxhV3O3y571Uq8F3Pc+n/2gocAOw0" +
  b"KaRVLolDo2DpDJondf2/+v/P/l1HnvrlKvXM4x+cNxeRXZiCxWFVG1rGoduNex+V6P31c4BKJKJflKpaaJcgrjJSmjXu10UW" +
  b"m6KEu3PtjkThuIpE9k11upjXLqn0PC+HPpqvK4pxG96diJadXGoOF4RrtPeSzWr7seI8tWGYrXimqgmcAPw0LNBUUw9CodGo" +
  b"dGo9I67/b/0/f/2vivPN5FamNTHi3dbqVNbtgJUUYzc5Ykz7dvnJgZMAqfuZOpFJFKjSoteMDA3FiSIkyOBr0oMSZHVeSWZ8" +
  b"qQY5ub3yPDBVWmmJiCwmJHSoNvFjzUaIqMyueKKUhJN0antpUaudcrT56zM0NqRpB5RTgAD2NCzpHQqHRsHRqPRkFWf1/6fr" +
  b"/5Xk825tosHpW5LpXcq2AiUVKctyS2WWOCXSidSHYzQW3bv7H8nrPteY67u3bpW7d4HUfi5ZCeDvx7brMD4O3IV/AqcDuP8f" +
  b"aej+hX9zs7rldeSTcAd8ciApaanOi8ZCEmI4UzKsXJHGLQg0kwknhZEuwNkF8AD8NCzsRGaJg6dR6Rrf8f/X/n/r7bfHiQmo" +
  b"rI89XuVUqVSMABE7Q1wQ3m9j6qrYD6zgfqWFherPqzSJAwMLUj2GFKbLdkhZerubHJOFLB2edKi9Q4Q2Ka+QY5mICw6odqzi" +
  b"+Na1JrmM8dTEopurRxFecU4A9DQozR0Si0Kh0qh0qu/6f/T/2+P89+eHfnlOF5xt8aTN71RK4yoDKpbDLYaLSXHdPYPC4jQg" +
  b"pVNq0atEs0kwsKSTS0CjoKCA0KkqCwRUDmNBNJFWtSdlSxJZ/xJFNhEGV7n4+eKryaO9jPLm8K8O6cpOFzJfTSo24c4J8+HG" +
  b"tXHAAQY0LOxkXoVDo2Do0DoUDpHw/1/+P+f9+Mexkkvdr3bsZEpW6aZAMK1QWesRMxaJfv7rVV+wVYXZ2fHCaubDF5nOQJCQ" +
  b"k5UaXqnRJzXNP3ssuzjlrVK3t/gCbt/mHZeXwmd3rujjqnnUHEDXxvdDLChjkKrNcN5wfpuqwJsJcH+zMcAA+DQs7FRmhUWi" +
  b"U+jEK/f5//D7/+usebqkSyYeV7xeQDMCVE5YEhUmfYuRZQDtQIEzAyMjtptbdTWd4GvWXiV7MZBneLXsLi3GjBj2XwevVi5v" +
  b"2UEOdxmuPRqfddW0VNNXVqN0xCo64xWrmU1Bi90IqaAzRwyXFsppaaikBSTi5XHFSZgzXC1ptmpKQeUaSxcEyvAA/DQs6RMW" +
  b"jMWiQekXv+v/H4/84XqpMlpSTxw85VUrjJqsgMNQMbA7zMQ1YRKXz142WsUxYsDA9RgYGRAwMDF24gORkjVFi8ldiACxL22y" +
  b"PV8XmLHQ+h532i9EP3/CIKe4/HcF60RzWolRf23cQz/7hVHCq9D10sM+tbxkw/yscAD4NCzpDRKHRoHRqPRiFk/b/8P8/7rr" +
  b"2TBbjJj1vWFUUq2bAx1eqNuNB/M4fMyPXuv70V1TTf5vln3SZLvk002E0y5pplwTzBGje+gOZ1O99mGM3X+rhfhUe5Jmscvt" +
  b"1s+8jPdhJ1oMa7rc26jiLrwywHFFMB5xpStUxwEENCzsVF6Jg6NQ6NRaV7c/t/6f7f7e231tSRZKeGpuzJW7rTAFGaXUsuo3" +
  b"kmC1gS6A1Zm47Qzs7dvw7fCtnbYzcsqI3Ei0tWNyxo9LVq8/K6NWXPnffm/D939htctszBrNAS0lcXzi7j1zTl3xKTV0ca7b" +
  b"nEaRxky8NTmo4AD0NCzpBg6FQ6NQ6NRaVlft/9f9v++tVqZKmcBLeubusqF5pVBqYWJywKRWXjUK9Pk8yvTKaj9J+k/SfpPa" +
  b"8hEhJXVN0q0Jww8W6EtYDbpETOLyy9s01fHxtvDkc5Az2FfPMb9yKbJpxLd8XV3ANpNOFzuKus8qTfhaUcAA9jQs6R0Ji0Jo" +
  b"0jnj+3/4fv/78TNVxu6q7icx6TFF5JSsgQomahHd8M91yX7dy0vnhPQ58M1Zqywt9MLXrLxK9ewzLZ2VuE8YM932YDqRYN/f" +
  b"Peyy9cF7PPP9ufp0keKea6MclCBTadRxXvWcb1qlwjH+1K9kITXiXOzwcE7Wa/723Vj4p3e7g4AA/DQs6R0LB0ah0Sk0Ih0S" +
  b"Z+n/0/3/5871JMF1K0jwrcZiUX3gFFnFtYdYnijsrEN0iq3aapo8D+R/I9B6j0HxnQbAGZjR0QNmVHLKRllTo5cXRkeX418v" +
  b"o93o/QWQP3KrZSPcAmDwineJ4rukVMxwSUlFiCUHGsJiarFyRfDMyE3VNhPDQFTg"

///|
let ffref_fix_dash_a_chunk_stream0_00003_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAu4AAAAAAAAB0AAAAAAAAAAAAAAAAAQAACBUAADwA" +
  b"gAAAAAAAAKBtb29mAAAAEG1maGQAAAAAAAAAAwAAAIh0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAACCAgAAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAAHgAAAAAUHRydW4AAAIBAAAADwAAAKgAAACCAAAAfQAAAHQAAAB+AAAAgwAAAH8AAAB5AAAAkAAAAHMAAAB6" +
  b"AAAAhwAAAJMAAACCAAAAaQAAAH8AAAd1bWRhdAD4NCzoUn6ETmHRCJnj9v/H/f/TzG+skLRl1kPWry6F1WwmSnlU8dCPlbq/" +
  b"4v3uSV8kyWab7sloFGui9ZrY9brq2x9GO0NAw6VtdHPt3QNMhAWsdcr4DJjoUptWakTh4KejnbHGStilBo59XBzFZlTR9upd" +
  b"LpKyMLnuYFFbTmlWwOABCDQszGJmhFekee/n/6f6f7fWNXUq8klt2693QiimQCjJWJCmZ8awH8h548fB0N2dnZzrZ24w/I86" +
  b"uYT1KBPocVDMGoeafhE0rmmffUo0+eUvTl++S91arqNuMiT9VJdbTvKG2c1NUCHPnWaMbVrODLZg5o1u79KGBI9TgADyNCzp" +
  b"HQsHRsHTiHRK9fb/9vr/7ee3tUpNVK1UPabiqlVK45wGJyt6EvU5ZeAad0TyEIWyL3bv+n8j4t3nOV27dyyy4FGRusCa/i5U" +
  b"6rAkDaKeXj7wH/9C3t96sT6SQ+BD1mgAsAl78iQ45IZz3hWs4MpwAPo0LOj2FoUDo0Do0DoTDpEfp//a/0/99UnnaRJWudW8" +
  b"t7uqqJm9MA0ROwO+nEf/m5+8ufnniC3QDAwMDP6Z9cPHgxIGDAw9NEkGXr3CJDy+38I5BnYkmCU1wPYZZs90pnkH+4n/hvZz" +
  b"WVDNk2/jslK73F9G80/fNemY9nj4API0LOxEQwUHomDolFpTFo2d/0/7f8/7Lr67vju7avKj4ubupVFbrVUEqsqzV4moVY2J" +
  b"ZH1z7zoN4QBQU4Ty0G5ZZfRMy44y6T4yblRq4xJVGmKl9MDyy8j35aj/jTufMiTzCIpWkr6a4UPEtPGfftfZ5xu98Zp6CH7M" +
  b"n/twJmzwNjgBBjQs6Q0Rh0aB0aj0j6z/j/p/n/r1t7b1kVJrJHdqubVQSMAYV1QWDUyZMUSscdphj/aKtvISE/8n/kpQnZNE" +
  b"zBISJS058snhWJPBAb2mFWZ/Z3tLge6/h7T77978zZTKpu1uukeFSqHNJxrouOaqjjBHNMRY6q0ncYb/ZGnAAPY0KWi2DomD" +
  b"qFDohDoRCrP7f+n6//p1nf1lUkuSZb2tkqopVcc7AyyYvUDbkcxqPxnUDurMQhhRkUEqYUbW2pu2JXrL2d68MuFrxIZ7/jbn" +
  b"6wc3w3jWeVyjAxdNC6imv2MXmNASBi3ZxXc+VcXK5rjnFlK7t6aTgAD6NCzpHQmvRiFx6/T/4/n/y4k31u031JibeN0pGTJW" +
  b"VQGZtyBqDnZb8uDKopNEq4WkLgeoyN3xeJgZkjdu3bosTkjyMgfno/F/E6xXjjbcRy8j9zsCduOGSu5/X/6G7ZRvWuJm4HLn" +
  b"wrXImh7k/2b3tDsIS1dNxcAw/tyXY+Ne4z3YezkaCa5FM50ZVyLleAD+NCjpDRKLTKHQqLRCFb+v/1/3/63fFsqStVdSnnqM" +
  b"ZZWTnWQHnFrH+sI+tm/mvatHyBepJ8s+WfnP1xJNguabBIkWcqJFwFnDDXeTDHexCGZTdl0+r4XHwDKEUm+VsJDaji7LZthK" +
  b"Zi1+USFAAbdtkxwA8DQs7Q0Sh0bB0Zh0zH+v/4f7/8+xNMqvNVLvHzdbteJzktgNLqcMOkHHRuwVmVAecbZvZVoaSaSaSaqb" +
  b"t0STSTyYuwgKEgoKPoUCQWCAh1VBaIGiqZ1VCZ24c1JaLR4RMlc8nzuTnZwdXdQR1baJxqtGK9nO/A/s8AEENCzpFRaNg6NR" +
  b"6Rxf8f/X/f/vrXPnd1C5Wtpu3fGslZuarAGFTMMSsFl8NAvW6jO29UpqP0kJ/5P0nVITrnXISEhIm7UwCbWjhzgfFKle96Lw" +
  b"InKmjxq1/9+SULwYbBCDHOqfCpNgY6tqGY8xE3tDaTlWrd+eq+XfFouSbmlIpi4LSecS4AD4NCzk8yEczs38//h9//PjE6lV" +
  b"Zcq93kzQwMpAhRIXp7bjPj/S9RD8CLciOaeeef9T9X6n9Z51K9fU56wMJ4cLVqjg9/1pofueFrW2sBrXdvD7CRNWlDGdUEgU" +
  b"o5kqFcKVroPbEio05n13mOgAKNAGlT1rRUyrNd7nadRxXq4/3Z3UhbbeUikVAJCa9tKq1tFUcAD+NCzpHQoLRKHRmPQiHQiF" +
  b"M+f/7P+//nzpchrvWsrrx08MlKyUrL3gAOInSNaD7w5PYa1A+fZ3AsDAwMDRgZkXKRA6oGxdd3jl4OplaiVk4Hyv+ALxyWry" +
  b"ZMM75HsfOxdRFNQ9/C+J7xHVM3FxRlq534LgnXTT/qblYSOdAEilag4A9DQo6Q0Sh0Rh0yh0jdf3//s//P1949typJJZb31X" +
  b"MzLqYmmAaUlLYaqxeOfyfnfhyj1TTf5uqmmSTTTTYTLnPPMlSnzwbon2wtPN28b7vx7/4bdbxw+nQ7tsmk4v3o3PXWram7fv" +
  b"iHABBDQs7FRKj0Kh0gh0Si0r2f0/+n+f9/NTzfMStTnzzeO2YmbTVVqqoCjNMGnm2mfeMR/eVoF8VUdQ3Z2wxwxqxkxBgYGJ" +
  b"Aw4cSHV7huwdzLmSlSfPuhIpXaU8674+TwiYxlNMM1y3H3TNrRRtW9+0IO9o4318b5rTPA1fKkJ4"

///|
let ffref_fix_dash_a_chunk_stream0_00004_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAu4AAAAAAAACwAAAAAAAAAAAAAAAAAQAAAQIAAAQA" +
  b"gAAAAAAAAGRtb29mAAAAEG1maGQAAAAAAAAABAAAAEx0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAACWAgAAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAALQAAAAAFHRydW4AAAABAAAAAQAAAGwAAACebWRhdAFMNBPi0iC0KZz8z76u5cuMkSJEEHWSACQkJmKqllll" +
  b"llMygYGBgYGBgYGZlAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM" +
  b"DAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwPgA=="

///|
let ffref_fix_dash_a_manifest_mpd_b64 : Bytes = b"PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0idXRmLTgiPz4KPE1QRCB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3Jn" +
  b"LzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIgoJeG1sbnM9InVybjptcGVnOmRhc2g6c2NoZW1hOm1wZDoyMDExIgoJeG1sbnM6" +
  b"eGxpbms9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiCgl4c2k6c2NoZW1hTG9jYXRpb249InVybjptcGVnOkRBU0g6" +
  b"c2NoZW1hOk1QRDoyMDExIGh0dHA6Ly9zdGFuZGFyZHMuaXNvLm9yZy9pdHRmL1B1YmxpY2x5QXZhaWxhYmxlU3RhbmRhcmRz" +
  b"L01QRUctREFTSF9zY2hlbWFfZmlsZXMvREFTSC1NUEQueHNkIgoJcHJvZmlsZXM9InVybjptcGVnOmRhc2g6cHJvZmlsZTpp" +
  b"c29mZi1saXZlOjIwMTEiCgl0eXBlPSJzdGF0aWMiCgltZWRpYVByZXNlbnRhdGlvbkR1cmF0aW9uPSJQVDAuOVMiCgltYXhT" +
  b"ZWdtZW50RHVyYXRpb249IlBUMC4zUyIKCW1pbkJ1ZmZlclRpbWU9IlBUMC42UyI+Cgk8UHJvZ3JhbUluZm9ybWF0aW9uPgoJ" +
  b"PC9Qcm9ncmFtSW5mb3JtYXRpb24+Cgk8U2VydmljZURlc2NyaXB0aW9uIGlkPSIwIj4KCTwvU2VydmljZURlc2NyaXB0aW9u" +
  b"PgoJPFBlcmlvZCBpZD0iMCIgc3RhcnQ9IlBUMC4wUyI+CgkJPEFkYXB0YXRpb25TZXQgaWQ9IjAiIGNvbnRlbnRUeXBlPSJh" +
  b"dWRpbyIgc3RhcnRXaXRoU0FQPSIxIiBzZWdtZW50QWxpZ25tZW50PSJ0cnVlIiBiaXRzdHJlYW1Td2l0Y2hpbmc9InRydWUi" +
  b"PgoJCQk8UmVwcmVzZW50YXRpb24gaWQ9IjAiIG1pbWVUeXBlPSJhdWRpby9tcDQiIGNvZGVjcz0ibXA0YS40MC4yIiBiYW5k" +
  b"d2lkdGg9IjQ4MDAwIiBhdWRpb1NhbXBsaW5nUmF0ZT0iNDgwMDAiPgoJCQkJPEF1ZGlvQ2hhbm5lbENvbmZpZ3VyYXRpb24g" +
  b"c2NoZW1lSWRVcmk9InVybjptcGVnOmRhc2g6MjMwMDM6MzphdWRpb19jaGFubmVsX2NvbmZpZ3VyYXRpb246MjAxMSIgdmFs" +
  b"dWU9IjEiIC8+CgkJCQk8U2VnbWVudFRlbXBsYXRlIHRpbWVzY2FsZT0iNDgwMDAiIGluaXRpYWxpemF0aW9uPSJpbml0LXN0" +
  b"cmVhbSRSZXByZXNlbnRhdGlvbklEJC5tNHMiIG1lZGlhPSJjaHVuay1zdHJlYW0kUmVwcmVzZW50YXRpb25JRCQtJE51bWJl" +
  b"ciUwNWQkLm00cyIgc3RhcnROdW1iZXI9IjEiPgoJCQkJCTxTZWdtZW50VGltZWxpbmU+CgkJCQkJCTxTIHQ9IjAiIGQ9IjE0" +
  b"MzM2IiAvPgoJCQkJCQk8UyBkPSIxNTM2MCIgcj0iMSIgLz4KCQkJCQkJPFMgZD0iMTAyNCIgLz4KCQkJCQk8L1NlZ21lbnRU" +
  b"aW1lbGluZT4KCQkJCTwvU2VnbWVudFRlbXBsYXRlPgoJCQk8L1JlcHJlc2VudGF0aW9uPgoJCTwvQWRhcHRhdGlvblNldD4K" +
  b"CTwvUGVyaW9kPgo8L01QRD4K"

///|
let ffref_fix_dash_v_init_stream0_m4s_b64 : Bytes = b"AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAw5tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAA" +
  b"AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC" +
  b"AAACEXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA" +
  b"AAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAAAAAEAAAAAAYltZGlh" +
  b"AAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFu" +
  b"ZGxlcgAAAAE0bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA" +
  b"9HN0YmwAAACoc3RzZAAAAAAAAAABAAAAmGF2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAAAyYXZjQwFkAAr/4QAXZ2QACqy0ITYCIAAAAwAgAAADAoHi" +
  b"RNQBAARo7w/L/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6AAAA" +
  b"AAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAChtdmV4AAAAIHRyZXgAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAAAAABhdWR0" +
  b"YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAA" +
  b"AAEAAAAATGF2ZjYzLjEuMTAy"

///|
let ffref_fix_dash_v_chunk_stream0_00001_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAADV8AABQA" +
  b"gAAAAAAAAHxtb29mAAAAEG1maGQAAAAAAAAAAQAAAGR0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAAb2AQEAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAAAAAAAAALHRydW4AAAIFAAAABQAAAIQCAAAAAAAG9gAAAVcAAAF+AAABUwAAAb0AAAzjbWRhdAAAAl0GBf//" +
  b"WdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAw" +
  b"My0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MSBkZWJs" +
  b"b2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT0yIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRf" +
  b"cmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZh" +
  b"c3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVh" +
  b"ZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJm" +
  b"cmFtZXM9MCB3ZWlnaHRwPTEga2V5aW50PTUga2V5aW50X21pbj0zIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjX2xv" +
  b"b2thaGVhZD01IHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQg" +
  b"aXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAABJFliIQ31NRGM9dXkFEYpKomB0ANoEhVhJNhXiYLgYJVsVbqwehLwTKdk+cL" +
  b"sIC9MId0m5cGyDLR760pLnwB+2T1ZQkBEawSZAS8I7vhHQsqpsK1CPU6esE3Ls2ysBEUpprOG1piurw8KXuE8WGdIST2ul0e" +
  b"O7WT/y/hTZT+qfEUSEYmWPg4ElO3xDmDSGGPJpKsUA9WdtnCniCeBEgumbgJl+LLd5fbkJ+S6Tnq59rxqKiHGzadzy7DMfxg" +
  b"odQ8xjBbaBnSdkHyopOTO4vVWIT2T2DvTVQZZKRvmWfEApIy6bBxrcpC3o+C6tNv6AhJw9v4Up6XEQyffaqqgNHRVsLcdWEn" +
  b"shPW0XJDnuL8DggOQ5/3u426yCNO+fuGxDJa+FAEIxXVW50GcLgUIEuMCrIF+4sTGYUnMKqJCfLxeImybqcyVYCnTBQgHVkh" +
  b"2aAUdOqnnGccHjul8Y4aewn4UDnXlrF4CjucBSU8D/ei75lIwGWU06ESpNHHT9z+0otNmjCWxLrcfkfZVleZqpmq4Uql2s0n" +
  b"YVYPvee3JY9j/yc/dwC3tRQe4AezDROsZyfBYxAzpcNdsrhrLCELe35v5piWJGW+1GlF8bTaiKdafxHX57vCeAAJxXzc0Ffq" +
  b"y2M46/LHDUA2/j2Y3onQvwxTBHN3WqDm/DE9sA+1e7IPIAKh4KcY8Nxh45BtGdnYh48A9DWo8WovK9pTUT/1T+VBIgxLTSVn" +
  b"RKURK0vcakRVRe8G+epJWEkEa+dOzamGclv8QR5VIbmi5BmY6GMiTCQr1ywZWMpN0yWMRKKqUkepuaeS7KHd1oX2nb8DDdGd" +
  b"iN25kSwP8M24aQ6RgQ/4np0KUQzIty5/4G1JBS92s/uHmMGxXOXm+Kfhj8EP6MlBYUUJ0/5oN4Bzaqk5Qh/5SJI5Z2PzDuy8" +
  b"r3q9rQrKxJl4iOgJTCoSmsLEuEJ8j9q7bw4s16wFVttK7cSMpU7lF1KXIT9ttft3OD7lZNTNVQnkC6pUUYUGU6TjMTqGsAgT" +
  b"EPunWatvSI3826Vs57MEns3ZeGGEfvv734ut1uElGeMJIUoQRZ6pbEHOxphzjCqWkADQETA5hbOslpFcD8kWizyaCNLq5hfe" +
  b"ud5KjgoHk5y1iPoxW3kVdeNxgSKUlMJBCtoiDhi3knxUxf+RGAwfP9wWa53ZMKHbkGKUq52xdO1XpXIu2nJFdiShD2uf4Znm" +
  b"xvBGT/1nfgD0n0/M0AVJSIm6QMxv9Yq4XFVSe6ISxDnj8a+89yA5rV57uHuLC7vKH0Zf3r1rs5GUmXlAPg/eUFqMHjWHS8cz" +
  b"+N0FUn3/M21kyPq8TE44J2Zx4HwyRqI1kw/p08JM5Yrtj8QNsqUyTSBHUdhNJD/99G5WN3p9OOKgaloIWahJMSHpmNNEjmy8" +
  b"chZhVJLGt2BL40LTI0Nlk1+NhMvfYYYAlQ1gkXT/upXThvt4iPfwuKIA3Otn74AAPU/+kElBsmeDSjed8xe9MNsT7AfDdxg8" +
  b"+OihIwg4tjyv/wRQ3ZzfDRz7T3mdOYJAI9eEurbJaY8H5UC1SCWP+NnktXmrmQAAAVNBmiYiP7H16N3thGYczjlCva328g6r" +
  b"zdbP5n86YX/aTjK+FLy813hUyTLNJrgkaBl3S2t/6x/t8WumL9jwX7bixsCHiE4UWi3gRQu3OMSyVd8JoiODTH13aNsY8alV" +
  b"oJ3s74Pi5v8i48xNNzYsV5wNHr+cZDZ4OSSa4E5hIARC27Q+jLAwlz1TG2ihvg3FFIvIFntHXVv6gxBtxd7L0cjsSOck6q6L" +
  b"1X32O8ozv7Za+LinDPt3O9SP4HNoLsMjMIbf4WgQWvT6XPZEthZppVp9iWoJOh1+Su4OD9rZ87Hab2pEAowInQFdnOOwVYJM" +
  b"LfsQWbvDo7tGnfMZVMn1TCn0QjwIa4Dduxb8r8r8AKZmCa304eZLaF6w7YGwfxcB15sSHnzRiCGwBaoNcm47vMMsXBzg3bTf" +
  b"rQ3XRbXfp8Sl0anX3PlYIlIGOm+ayas71Uyix4AAAAF6QZpGIj+yCLiJLwAzo/faqM1VtA8MSVAOsN2kUOpZewOb/78c3FSE" +
  b"ruHlnjp8eHxxxMSbKoXJ+2UUeYYIL85A8dpEVSg1/OO7hnaIL46bzMl8++tkukw/J1PxaMa6OOdlULbDQvnQ45qZJOCuBG5K" +
  b"uMjvnyBGz+mWLw4dDJ8dfkn476m64P8VMaZea/QSlME2aPvaXx+zWGOWqIDtkx5iDdJHpYogR/jbzW6+gVFimQEhnBr0lGFq" +
  b"2IsfGgizlYNpQwNQiQtqSUYlPkSG545DF1TE9esc+Vs6XEefPM/L7p1IzFvYmP5ty4tOUaPSadP7waxLU0ZsuyAdHXtoI47v" +
  b"2zmnnKcTll+sUalWU7Bl1uQy1I1dwrNwvZVO6QyQTdFA3KkeeACzl9QpSMqLJddlKK2hdRf+sK2+64K4oOdiqEENvxqm/ck2" +
  b"VwwM7F5VRu3A1DLQXcKPUOho+hEqyeoOTCRIjJ2r6jez1oNBnAfLfDwBlgT1O9cOFbZ7AAABT0GaZib/xZ/0cjdjdCU6pe+f" +
  b"TjG+e0BfQsiD1midE0M1nLJGv4FEiGRYhLA+uzAs6T4t4JWaif7lLLkmwkqRsVF+GFZXyussqFtMKXz5u8OdkA++FVoqEwHj" +
  b"0cmCp5uITYODR8LNXKBop5ufLqHJC2hVtRzFpug6YQEphyrWq8DKDkYOTVizJq5+jAcWzAEoQmQ3bXZlw7A+/uP0KaAxL94s" +
  b"BLNp/eJYOOiFjnyiX/OvlSractTrXJqKQvxKjxYg1IpFkTv/z0BdXYSUWFZ4vZ/7RF85z/OA8FoJOAwzd3Ero90va8RS84ny" +
  b"Zl1YxV7tzHFhXPF747BDiwzxF1lYjbTtNLsdJd7sJVhBZUgXqh3qOI1ZmntrSxVDdT/G43bvV/hZTgn9RV7/n1doujrVQ+th" +
  b"OPvTjYYAryq+8rG1xIX8y7AD4i3wUQEvAuvRs1nvAAABuUGahib/x+Z60i8FgFSbYrZ/TGiwhXUQ9WlLaCWM9wNnnhPmV3OQ" +
  b"k0Kfj+XAjfvkK1eHg+T4UPCZZvKB4a38tG0manJ2qSLbJVq2C+mc8HfVscJeS8wp5H5LvndcoHjJIHZsiiWjRsMOvGXigFgu" +
  b"oMrlWrHtqeBSKKIEIZ6lCUJIr7FJ+i3olzqEreZJx+4nXhkZ/990aIsP9A6j/yTxwSM4y/2eWH/qBsYq4XpYDX3A0fM2osGZ" +
  b"kBdunicPlvPJsOMSb4gyY22/RpOF2YH/sTHaDR4rRX8cYfiy54ZfLrvmt8rGOJFv/4+RpX39x/eriUKeQ6SF4BTTlZt0rBKw" +
  b"E7TvWJFE9UXZaEdBC9XGR/iw3qriQLaZNBZN/RsGvYCwS7q8Bwtpj1eRy3yVG3MzovaK/Z82K1mg2mVOMwmKtcLdLTiAsZwg" +
  b"3ZioO4a+B29ixYABwEz7qA5Meo8cr1s40c6fzJOL89k5JR9Ra6GNvXOo5DoaMcCDcFuHcW91kXgsAxzVlHaqncbEmtNd8MR9" +
  b"LL001i9VXZJ93CUMCn0IePtqw2KX0ycfBtWHddIiH9XV5IIl9DZpu6NcDw=="

///|
let ffref_fix_dash_v_chunk_stream0_00002_m4s_b64 : Bytes = b"AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAKAAAAAAAAAAUAAAAAAAAAAAAAAAAAQAACg8AABAA" +
  b"gAAAAAAAAHhtb29mAAAAEG1maGQAAAAAAAAAAgAAAGB0cmFmAAAAHHRmaGQAAgA4AAAAAQAABAAAAAVfAQEAAAAAABR0ZmR0" +
  b"AQAAAAAAAAAAABQAAAAAKHRydW4AAAIFAAAABAAAAIACAAAAAAAFXwAAAUYAAAF4AAABcgAACZdtZGF0AAAFW2WIggn/2WdM" +
  b"R9d3oLTcnulC2umCYCDpY2Ah/1/i6ndboRgomV0b1PE4yQGwcDErAEyfyMFdc5JICwhyXDCQyae1aQ9pIl+ZAoSxdoO7YW7M" +
  b"Bu+54KGpO31mpQ3kALG6LZEeriJKEC9049SVnqr+Nmwy4DK2Z0rIRMfZiFISYPQXUEm8X1PciV+rR8zj/ccOT2/saZ7qqerM" +
  b"rEJIy71ybYwyYSDNq729N/i/CspVnRnwM3oP4zC8a3utq5mCr7zx50my99QEaufiNQSrY/7D963JpTc5Gi7A0oczxOuOVdB0" +
  b"feTxYrQwzsuSvf2mXW22h3eGJaP8myekJt4mD+YgOHgydHJGvTvv8tTtNVv5Rwov7WzeFAy8h8wBm8UO9lFo2+HMK1G2FT2E" +
  b"NepaYv4i7N73DCXWGb+g9uZ5VLDapFSePKEAmiQ2joBwUSDpYHtwoDmrWo0hq2J4ukrpJt63ODedFE/4SxxXmI9uLpAx6OK+" +
  b"dX9WeUahgg4apivfevZFQF9w5s59q/RcDiZGBh6l17KbN78CIZ8mmJ3grnGf243dGRMZEI3PQt3jVxdgRFLD0YNSuAWbpUDA" +
  b"2S69bJKrMhqPfaz4hHhbsi2Hhuu+GbYyi7n/DMHO0dqNZPwRU+aHUCHjwEbmJo1fUrG3+S17Oc8Xn1WT0eBo0gKo3TNjw0xf" +
  b"APUlrAge6Ch17holZzc5xam3DWPV0MJAnqW+QpZJOe8ku3cTN5djAQ0p5UUs9dHrIN9aITztSxFxSifD4nRV/v4XPiHAp0L0" +
  b"NmJG1FzHOnU8NhIaYaVw1+6a6z1rjlYmAd8nWm7WuwiM+molZe3oLIfi+IkAqSgYuOJXJ4Hd0OQWf57S3YPYYxSaNshQ7u+v" +
  b"XmGUkJwmzao33vFdI6t63BGKDIzQNbSby8jFU6ne+v4srQNUPDAdFMEHIIabD1ynKC/Vb4UpARBCg48KS68xFZ7J2QuUIrTP" +
  b"XFkGy3zmtFrj+XSGuHSPUv+1y5aBvZ1bPFK2xTPIMFKQG0iRl5x7cvrtsbPdNShYe+2M12yLg112Bjh7kBivCrAzmuuLNgph" +
  b"Udh15zJ1o+E3jlvZk9fpqOkhPsSd82hcflrKJLtA5I+Ki2JJ04HJ/VTZnrLL/k4K29cyiAv1kSQnoud/jzUPLTTarU/nIlyH" +
  b"yNFyZtklT38pld7vWSJ9CulSdSuT4TK8zq8ZfsMHrpMNhJOCLH2FKTd/VK9F4PVZ+IagrVY2aQYpmQVUuhU8AClJ623Rt9Q/" +
  b"lxsoN1rmIK/TIqchNseC6o8IwyNLu57hczfohbWvDt7b6gz7CizJlo7IqfkTml3edNZt5shk8fTzviHk0gb/3Z9pQ1u4+ZhU" +
  b"62fU6qGVMQhozQlfCjO2PYx9QSG/VrG4NNU7z0ZDpLgZ8itUqkTiBhdXDxjhJzZsq9SuxvlUxPSBVlQ6QhfFZ0f1vfbTuJbo" +
  b"4anLT7d4OygorZccriE0+uhl3+kTiTgDtsibp/RA8eanyhfVW2qm8skBeaAd3dIp8hNzNEr5fGFeWS6+IxXyJ+ShaN9wB3EJ" +
  b"UQCRHOFnhHI7VjkOL9Le5g/GJbPjReAis/npZTEq3kDFo+1uvCJhzUQFWmUdePukj+6ZNipbwTE7T6fsKDNMZJ+vPHhcwTgS" +
  b"6SKvELrDZ++xBZlg9eBMTJVRk7iTwOkNSmieOK0w9yKHdltinJOgqa5Rit7CofA9ZgV8v3//4eIkt2l1MReOmpEJJA60aslU" +
  b"8Xwy1lb+FPDxNjMykaSQ5d3M+fD3vH54bdXfPdqoLUqq2PJhL5qmT2pVbgEifTLNhGhXMmw5RE088oMr1W8R2Qz3LwAAAUJB" +
  b"miYiv76El9vCj1dxubVVegp/wFthfS3se1Wu1Riu7N3QJwOEU6ZKzJsXtC06hSZ1bQ5bU+9SSmbRTPGzIW85gtz+5nq/z3Th" +
  b"zswsEi07t7n2crsLQQzodw5FK38y4E5aThJLWPmeMyaWiQMd06nQarFhyo72X/4KnZV5ZJfr84hhVGYrKDsZBctd0uS/H2ed" +
  b"9bFqWgBGsKcN7s6PW8eagRo8dry+OeMX12WV1kSy9w/LqR9t7aa+16X+VUulf64Us+UUgfyLeyeY8vTPbH1N+3mRO772+62p" +
  b"MkH0v4a49pGcWyNzfJAwbHCKJcb9TBNSYtgvfyO1l4yrl9L73NrsaN6sC/K1Gi0J7u9BltzGHdifstvcCiNNY8MNpqq7Ka/c" +
  b"i5mcudh7LmTdkr/g8YJDN6Df8Kg2H/BVH56dLZbef319AAABdEGaRiM/xOJG/uLaQamuTt4bTotbnskadIPy0jlKJu2X+qnc" +
  b"CBUljplj3PaGjPztDr4JzVSD1LY+wRSexLlXmv7BZosWJG4k7+O1bdZHcRvmJsxqWApTnDx1C/J8YkHiKcFTc3f3ieexXxgS" +
  b"c7bTwtJTnynQcDaa4TjaDa/rwIjPvTGpHdRNi4AUmaQpy73lcxCdvq/5J+f///6vYRGFQ/TGg/HMbSw2KTzjkD+vsZwbJoOr" +
  b"Ecp742FJpj5IEIZcUwOipsBmsOATWyoFVbog2fwyc0UGMd97dseoAFWElqapKUMnMcL5/81FicYlGg/Nff2E2VPT5ohwNXoQ" +
  b"99ae4T6aAoWDvlisI45PUrEbmnGCIAC76A7tteg79NTG1sdlySj1xC10BKDFiXG0l5k2ARqsPJyfbnu34tURjFswxwOVhfsr" +
  b"zqU1km/7nNSB0CFIbrW7A7oojyE0KkI+3vQK7g+6SlkT2xXpG9/7nth4IIb3Wq7OuwAAAW5BmmYhD8zUVpe4P/MkyyfHwEXd" +
  b"vYmFJEf0VnpmTHTW9L66Hmr6VhN+eNFNqy8/I/USBshEI45i9hr1cs2//SU3XgR7ib9WWwtvgu1a6P9TrMWN5x74X9LrT5iE" +
  b"UG1XkrP1BTPkglV1YUKqVRDI4R7nJitmia6lE4rIpjL4wAvrak8pQZtDaV0PpPJ8+NLV2ns92FA77ZUQdYrOBTBp3S7ayknD" +
  b"K4ye59RGaQ2GZQaoWaGqnGzJHtBI/JdSX8198FNBRNx8g3r+6pN25T9DYLbRrzfMP4wiANzq4bTUtvtH4QW55+Lis+KFO3Zi" +
  b"xxlu3t0LSJAFx9/7QlPsgBY5OEy8BPfVuy1m/xOECLHfDNETycECXxQPCj2fUm8+nYlgb2yxE8kfYeEjz7Qzda+Ruwc2tUkk" +
  b"eU16usIA8ChYvY94ZuH+udLCYhWRCqP05i8X6q5/Cg/LgU1bbKJitXI3Wg5sOiBpnKYnsA74U2bkAxg="

///|
let ffref_fix_dash_v_manifest_mpd_b64 : Bytes = b"PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0idXRmLTgiPz4KPE1QRCB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3Jn" +
  b"LzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIgoJeG1sbnM9InVybjptcGVnOmRhc2g6c2NoZW1hOm1wZDoyMDExIgoJeG1sbnM6" +
  b"eGxpbms9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiCgl4c2k6c2NoZW1hTG9jYXRpb249InVybjptcGVnOkRBU0g6" +
  b"c2NoZW1hOk1QRDoyMDExIGh0dHA6Ly9zdGFuZGFyZHMuaXNvLm9yZy9pdHRmL1B1YmxpY2x5QXZhaWxhYmxlU3RhbmRhcmRz" +
  b"L01QRUctREFTSF9zY2hlbWFfZmlsZXMvREFTSC1NUEQueHNkIgoJcHJvZmlsZXM9InVybjptcGVnOmRhc2g6cHJvZmlsZTpp" +
  b"c29mZi1saXZlOjIwMTEiCgl0eXBlPSJzdGF0aWMiCgltZWRpYVByZXNlbnRhdGlvbkR1cmF0aW9uPSJQVDAuOVMiCgltYXhT" +
  b"ZWdtZW50RHVyYXRpb249IlBUMC4zUyIKCW1pbkJ1ZmZlclRpbWU9IlBUMS4wUyI+Cgk8UHJvZ3JhbUluZm9ybWF0aW9uPgoJ" +
  b"PC9Qcm9ncmFtSW5mb3JtYXRpb24+Cgk8U2VydmljZURlc2NyaXB0aW9uIGlkPSIwIj4KCTwvU2VydmljZURlc2NyaXB0aW9u" +
  b"PgoJPFBlcmlvZCBpZD0iMCIgc3RhcnQ9IlBUMC4wUyI+CgkJPEFkYXB0YXRpb25TZXQgaWQ9IjAiIGNvbnRlbnRUeXBlPSJ2" +
  b"aWRlbyIgc3RhcnRXaXRoU0FQPSIxIiBzZWdtZW50QWxpZ25tZW50PSJ0cnVlIiBiaXRzdHJlYW1Td2l0Y2hpbmc9InRydWUi" +
  b"IGZyYW1lUmF0ZT0iMTAvMSIgbWF4V2lkdGg9IjY0IiBtYXhIZWlnaHQ9IjY0IiBwYXI9IjE6MSI+CgkJCTxSZXByZXNlbnRh" +
  b"dGlvbiBpZD0iMCIgbWltZVR5cGU9InZpZGVvL21wNCIgY29kZWNzPSJhdmMxLjY0MDAwYSIgYmFuZHdpZHRoPSI2MTg2NiIg" +
  b"d2lkdGg9IjY0IiBoZWlnaHQ9IjY0IiBzYXI9IjE6MSI+CgkJCQk8U2VnbWVudFRlbXBsYXRlIHRpbWVzY2FsZT0iMTAyNDAi" +
  b"IGluaXRpYWxpemF0aW9uPSJpbml0LXN0cmVhbSRSZXByZXNlbnRhdGlvbklEJC5tNHMiIG1lZGlhPSJjaHVuay1zdHJlYW0k" +
  b"UmVwcmVzZW50YXRpb25JRCQtJE51bWJlciUwNWQkLm00cyIgc3RhcnROdW1iZXI9IjEiPgoJCQkJCTxTZWdtZW50VGltZWxp" +
  b"bmU+CgkJCQkJCTxTIHQ9IjAiIGQ9IjUxMjAiIC8+CgkJCQkJCTxTIGQ9IjQwOTYiIC8+CgkJCQkJPC9TZWdtZW50VGltZWxp" +
  b"bmU+CgkJCQk8L1NlZ21lbnRUZW1wbGF0ZT4KCQkJPC9SZXByZXNlbnRhdGlvbj4KCQk8L0FkYXB0YXRpb25TZXQ+Cgk8L1Bl" +
  b"cmlvZD4KPC9NUEQ+Cg=="

///|
/// Decode one embedded fixture blob.
fn ffref_fix(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 1 << 20).unwrap()
}

///|
/// "/tmp/<tag>/<name>" as ASCII bytes (the path the oracle opens).
fn ffref_path_bytes(tag : String, name : String) -> Bytes {
  let out : Array[Byte] = []
  for c in "/tmp/\{tag}/\{name}" {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Run one adaptive-streaming differential: stage `files` under
/// /tmp/<tag>/, have the real FFmpeg demux the manifest by path (hls/dash
/// follow their own segment files), then diff the oracle's packet view
/// against our StreamingMedia walk over the same bytes. `open` parses the
/// manifest text (HLS or DASH) and opens our session on the shared fetch.
///
/// `pts_from_segment` skips the pts assert for packets from segments below
/// it (stream/size/keyframe are still compared). FFmpeg's hls demuxer
/// reads the first segment twice during header parsing and re-emits its
/// packets with a one-frame-stale pts (verified with ffprobe 9.0.2); our
/// port emits the per-PES pts the raw TS carries. Both sides agree from
/// the next segment on, so audio fixtures pass `pts_from_segment=1`.
fn ffref_check_streaming(
  tag~ : String,
  manifest~ : String,
  files~ : Array[(String, Bytes)],
  open~ : (String, @avf.MediaFetch) -> @avf.StreamingMedia raise @avf.MediaError,
  pts_from_segment~ : Int64 = 0,
) -> Unit raise {
  for _, (name, bytes) in files {
    @ffref.ffref_write_file(ffref_path_bytes(tag, name), bytes)
  }
  let oracle = @ffref.ffref_probe_path(ffref_path_bytes(tag, manifest))
  let resources : Map[String, Bytes] = Map([])
  let mut manifest_bytes : Bytes? = None
  for _, (name, bytes) in files {
    resources[name] = bytes
    if name == manifest {
      manifest_bytes = Some(bytes)
    }
  }
  let text = @utf8.decode_lossy(manifest_bytes.unwrap())
  let sm = open(text, @avf.media_fetch_from_map(resources))

  let ours : Array[@avf.StreamingPacket] = []
  for ;; {
    match sm.next_packet() {
      Some(p) => ours.push(p)
      None => break
    }
  }
  assert_true(
    sm.streams().length() <= oracle.timebases.length(),
    msg="\{tag}: stream count (ours \{sm.streams().length()}, oracle \{oracle.timebases.length()})",
  )
  if ours.length() != oracle.packets.length() {
    println(
      "\{tag}: ours \{ours.length()} vs oracle \{oracle.packets.length()}",
    )
    for i = 0
        i < ours.length() && i < oracle.packets.length() && i < 12
        i = i + 1 {
      let p = ours[i]
      let o = oracle.packets[i]
      println(
        "  [\{i}] ours s=\{p.stream_index} sz=\{p.data.length()} pts=\{p.pts} kf=\{p.keyframe} | orac s=\{o.stream_index} sz=\{o.size} pts_us=\{Repr(o.pts_us)} kf=\{o.keyframe}",
      )
    }
  }
  assert_eq(ours.length(), oracle.packets.length(), msg="\{tag}: packet count")
  // Per-stream anchors: our normalized timeline and the oracle's may start
  // at different raw offsets (each side re-anchors the first segment its
  // own way), so pts is compared as per-stream deltas.
  let first_tick : Map[Int32, Int64] = Map([])
  let first_us : Map[Int32, Int64] = Map([])
  for idx, p in ours {
    let o = oracle.packets[idx]
    assert_eq(p.stream_index, o.stream_index, msg="\{tag}: stream at \{idx}")
    assert_eq(p.data.length(), o.size, msg="\{tag}: size at \{idx}")
    assert_eq(p.keyframe, o.keyframe, msg="\{tag}: keyframe at \{idx}")
    let us = match o.pts_us {
      Some(v) => v
      None => fail("\{tag}: oracle pts missing at \{idx}")
    }
    if !first_tick.contains(p.stream_index) {
      first_tick[p.stream_index] = p.pts
    }
    if !first_us.contains(o.stream_index) {
      first_us[o.stream_index] = us
    }
    let (num, den) = oracle.timebases[o.stream_index]
    if p.segment_sequence >= pts_from_segment {
      // Deltas compared in the stream's own tick domain with one tick of
      // rescale rounding: |Δtick·num·1e6 − Δus·den| ≤ num·1e6.
      let dt = p.pts - first_tick[p.stream_index]
      let du = us - first_us[o.stream_index]
      let lhs = dt * num.to_int64() * 1000000L
      let rhs = du * den.to_int64()
      assert_true(
        (lhs - rhs).abs() <= num.to_int64() * 1000000L,
        msg="\{tag}: pts at \{idx}: Δtick \{dt} vs Δus \{du} (tb \{num}/\{den})",
      )
    }
  }
}

///|
test "ffref: HLS AAC-TS packet oracle matches StreamingMedia" {
  ffref_check_streaming(
    tag="ffref_hls_a",
    manifest="list.m3u8",
    files=[
      ("list.m3u8", ffref_fix(ffref_fix_hls_a_list_m3u8_b64)),
      ("seg00.ts", ffref_fix(ffref_fix_hls_a_seg00_ts_b64)),
      ("seg01.ts", ffref_fix(ffref_fix_hls_a_seg01_ts_b64)),
      ("seg02.ts", ffref_fix(ffref_fix_hls_a_seg02_ts_b64)),
      ("seg03.ts", ffref_fix(ffref_fix_hls_a_seg03_ts_b64)),
    ],
    open=(text, fetch) => {
      let playlist = @avf.av_hls_parse(
        text,
        base_uri="/tmp/ffref_hls_a/list.m3u8",
      ).unwrap()
      @avf.StreamingMedia::open_hls(playlist, fetch)
    },
    pts_from_segment=1L,
  )
}

///|
test "ffref: HLS H264-TS packet oracle matches StreamingMedia" {
  ffref_check_streaming(
    tag="ffref_hls_v",
    manifest="list.m3u8",
    files=[
      ("list.m3u8", ffref_fix(ffref_fix_hls_v_list_m3u8_b64)),
      ("seg00.ts", ffref_fix(ffref_fix_hls_v_seg00_ts_b64)),
      ("seg01.ts", ffref_fix(ffref_fix_hls_v_seg01_ts_b64)),
    ],
    open=(text, fetch) => {
      let playlist = @avf.av_hls_parse(
        text,
        base_uri="/tmp/ffref_hls_v/list.m3u8",
      ).unwrap()
      @avf.StreamingMedia::open_hls(playlist, fetch)
    },
  )
}

///|
test "ffref: DASH AAC-fMP4 packet oracle matches StreamingMedia" {
  ffref_check_streaming(
    tag="ffref_dash_a",
    manifest="manifest.mpd",
    files=[
      ("manifest.mpd", ffref_fix(ffref_fix_dash_a_manifest_mpd_b64)),
      ("init-stream0.m4s", ffref_fix(ffref_fix_dash_a_init_stream0_m4s_b64)),
      (
        "chunk-stream0-00001.m4s",
        ffref_fix(ffref_fix_dash_a_chunk_stream0_00001_m4s_b64),
      ),
      (
        "chunk-stream0-00002.m4s",
        ffref_fix(ffref_fix_dash_a_chunk_stream0_00002_m4s_b64),
      ),
      (
        "chunk-stream0-00003.m4s",
        ffref_fix(ffref_fix_dash_a_chunk_stream0_00003_m4s_b64),
      ),
      (
        "chunk-stream0-00004.m4s",
        ffref_fix(ffref_fix_dash_a_chunk_stream0_00004_m4s_b64),
      ),
    ],
    open=(text, fetch) => {
      let mpd = @avf.av_dash_parse(
        text,
        base_uri="/tmp/ffref_dash_a/manifest.mpd",
      ).unwrap()
      @avf.StreamingMedia::open_dash(mpd, fetch)
    },
  )
}

///|
test "ffref: DASH H264-fMP4 packet oracle matches StreamingMedia" {
  ffref_check_streaming(
    tag="ffref_dash_v",
    manifest="manifest.mpd",
    files=[
      ("manifest.mpd", ffref_fix(ffref_fix_dash_v_manifest_mpd_b64)),
      ("init-stream0.m4s", ffref_fix(ffref_fix_dash_v_init_stream0_m4s_b64)),
      (
        "chunk-stream0-00001.m4s",
        ffref_fix(ffref_fix_dash_v_chunk_stream0_00001_m4s_b64),
      ),
      (
        "chunk-stream0-00002.m4s",
        ffref_fix(ffref_fix_dash_v_chunk_stream0_00002_m4s_b64),
      ),
    ],
    open=(text, fetch) => {
      let mpd = @avf.av_dash_parse(
        text,
        base_uri="/tmp/ffref_dash_v/manifest.mpd",
      ).unwrap()
      @avf.StreamingMedia::open_dash(mpd, fetch)
    },
  )
}
