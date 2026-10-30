///|
/// Real FFmpeg 9.0.2 Wave64 fixtures with their WAV counterparts (same PCM)
/// so the GUID chunk walk can be checked byte-for-byte.

///|
fn w64fixture_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let w64_16_b64 : Bytes = w64fixture_concat([
  b"cmlmZi6RzxGl1ijbBMEAAIgDAAAAAAAAd2F2ZfOs0xGM0QDAT47bimZtdCDzrNMRjNEAwE+O24ooAAAAAAAAAAEAAQBAHwAAgD4AAAIAEABkYXRh86zTEYzRAMBPjtuKOAMAAAAAAAAAAGsFMgrFDbYPzQ8FDpQK",
  b"5AWBAA/7M/Z/8mTwIfC/8Qz1pvn//nYEZgk7DX4P7Q96DlAL0AaCAQb8A/cP86TwCfBR8Vf0vfj+/X0DkgikDDcP/Q/gDgAMtQeBAgH93Pet8/PwAfDz8Kzz2/cA/YACtAf/C98O/Q83D6QMkwh9A//9vfhX9FLx",
  b"CfCj8A/zAvcF/IEBzwZQC3kO7Q9/DzsNZwl3BP/+pvkN9b/xIfBj8H7yMvYO+4AA4wWUCgQOzQ+3D8UNMwpsBQAAlfrO9TvySvAz8PvxbPUc+n//8QTNCYENnA/fD0EO9ApaBgEBivua9sXygvAT8IbxsPQw+X7+",
  b"+gP9CPEMXA/3D68OqQtDBwICg/xu91zzyfAD8CDxAPRL+H/9/wIkCFMMDQ//Dw0PVAwlCAADgP1M+AH0IfED8MnwXPNt94P8AQJDB6kLrg73D10P8Qz+CPsDf/4x+bD0h/ET8IHwxfKZ9on7AQFaBvMKQQ7fD50P",
  b"gg3OCfIEgP8d+mz1/PEz8EnwO/LN9ZT6AABrBTIKxQ22D80PBQ6UCuQFgQAP+zP2f/Jk8CHwv/EM9ab5//52BGYJOw1+D+0Peg5QC9AGggEG/AP3D/Ok8AnwUfFX9L34/v19A5IIpAw3D/0P4A4ADLUHgQIB/dz3",
  b"rfPz8AHw8/Cs89v3AP2AArQH/wvfDv0PNw+kDJMIfQP//b34V/RS8Qnwo/AP8wL3BfyBAc8GUAt5Du0Pfw87DWcJdwT//qb5DfW/8SHwY/B+8jL2DvuAAOMFlAoEDs0Ptw/FDTMKbAUAAJX6zvU78krwM/D78Wz1",
  b"HPp///EEzQmBDZwP3w9BDvQKWgYBAYr7mvbF8oLwE/CG8bD0MPl+/voD/QjxDFwP9w+vDqkLQwcCAoP8bvdc88nwA/Ag8QD0S/h//f8CJAhTDA0P/w8ND1QMJQgAA4D9TPgB9CHxA/DJ8FzzbfeD/AECQwepC64O",
  b"9w9dD/EM/gj7A3/+Mfmw9IfxE/CB8MXymfaJ+wEBWgbzCkEO3w+dD4INzgnyBID/Hfps9fzxM/BJ8DvyzfWU+g==",
])

///|
let w64_16_wav_b64 : Bytes = w64fixture_concat([
  b"UklGRmYDAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAATElTVBoAAABJTkZPSVNGVA0AAABMYXZmNjMuMS4xMDIAAGRhdGEgAwAAAABrBTIKxQ22D80PBQ6UCuQFgQAP+zP2f/Jk8CHwv/EM9ab5//52BGYJ",
  b"Ow1+D+0Peg5QC9AGggEG/AP3D/Ok8AnwUfFX9L34/v19A5IIpAw3D/0P4A4ADLUHgQIB/dz3rfPz8AHw8/Cs89v3AP2AArQH/wvfDv0PNw+kDJMIfQP//b34V/RS8Qnwo/AP8wL3BfyBAc8GUAt5Du0Pfw87DWcJ",
  b"dwT//qb5DfW/8SHwY/B+8jL2DvuAAOMFlAoEDs0Ptw/FDTMKbAUAAJX6zvU78krwM/D78Wz1HPp///EEzQmBDZwP3w9BDvQKWgYBAYr7mvbF8oLwE/CG8bD0MPl+/voD/QjxDFwP9w+vDqkLQwcCAoP8bvdc88nw",
  b"A/Ag8QD0S/h//f8CJAhTDA0P/w8ND1QMJQgAA4D9TPgB9CHxA/DJ8FzzbfeD/AECQwepC64O9w9dD/EM/gj7A3/+Mfmw9IfxE/CB8MXymfaJ+wEBWgbzCkEO3w+dD4INzgnyBID/Hfps9fzxM/BJ8DvyzfWU+gAA",
  b"awUyCsUNtg/NDwUOlArkBYEAD/sz9n/yZPAh8L/xDPWm+f/+dgRmCTsNfg/tD3oOUAvQBoIBBvwD9w/zpPAJ8FHxV/S9+P79fQOSCKQMNw/9D+AOAAy1B4ECAf3c963z8/AB8PPwrPPb9wD9gAK0B/8L3w79DzcP",
  b"pAyTCH0D//29+Ff0UvEJ8KPwD/MC9wX8gQHPBlALeQ7tD38POw1nCXcE//6m+Q31v/Eh8GPwfvIy9g77gADjBZQKBA7ND7cPxQ0zCmwFAACV+s71O/JK8DPw+/Fs9Rz6f//xBM0JgQ2cD98PQQ70CloGAQGK+5r2",
  b"xfKC8BPwhvGw9DD5fv76A/0I8QxcD/cPrw6pC0MHAgKD/G73XPPJ8APwIPEA9Ev4f/3/AiQIUwwND/8PDQ9UDCUIAAOA/Uz4AfQh8QPwyfBc8233g/wBAkMHqQuuDvcPXQ/xDP4I+wN//jH5sPSH8RPwgfDF8pn2",
  b"ifsBAVoG8wpBDt8PnQ+CDc4J8gSA/x36bPX88TPwSfA78s31lPo=",
])

///|
let w64_24_b64 : Bytes = w64fixture_concat([
  b"cmlmZi6RzxGl1ijbBMEAAOAJAAAAAAAAd2F2ZfOs0xGM0QDAT47bimZtdCDzrNMRjNEAwE+O24pAAAAAAAAAAP7/AgBAHwAAgLsAAAYAGAAWABgAAwAAAAEAAAAAABAAgAAAqgA4m3FkYXRh86zTEYzRAMBPjtuK",
  b"eAkAAAAAAAAAAAAAAAC4mgW4mgWNvAmNvAmaTwuaTwvO6QnO6Qk16QU16QU3WwA3WwAutfoutfqIc/aIc/Y5s/Q5s/TE6/XE6/W3yfm3yflGSv9GSv9/+QR/+QT4Wgn4WgloRgtoRguJPAqJPAo8gQY8gQbxEAHx",
  b"EAGGWPuGWPta2fZa2fYTwvQTwvT8nfX8nfU5Nfk5NfmMlP6MlP4JVAQJVAQy8Agy8AicMgucMguphAqphArmEgfmEgdBxQFBxQHRAPzRAPwUSfcUSfeI2/SI2/SEW/WEW/UYp/gYp/jx4P3x4P2fqQOfqQOGewiG",
  b"ewh/Ewt/EwsuwgouwgrJnAfJnAdydwJydwKkrPykrPxJwfdJwfdNAPVNAPXyIvXyIvW+IPi+IPh1L/11L/2s+wKs+wLI/wfI/wcS6QoS6QoX9QoX9QqZHwiZHwg5KAM5KAO2XP22XP36Qfj6QfhiMPViMPWx9fSx",
  b"9fQsovcsovfNgPzNgPzmSgLmSgLYegfYegdUswpUswqwHAuwHAvumQjumQh21QN21QMyDv4yDv5zyvhzyvjHa/XHa/XA0/TA0/QWLPcWLPeu1fuu1fsAmAEAmAEh7gYh7gb8cgr8cgr5OAv5OAvGCwnGCwnBfQTB",
  b"fQSCwv6Cwv6zWvmzWvkTsfUTsfUgvfQgvfR8vvZ8vvbOLvvOLvv74gD74gANWwYNWwYIKAoIKArySQvySQttdAltdAmCIgWCIgU8eP88eP+b8Pmb8Pn7APb7APbPsfTPsfTIWvbIWvbgjPrgjPpBLQBBLQCcwQWc",
  b"wQUt0wkt0wmaTwuaTwst0wkt0wlRwgVRwgVBLQBBLQCVjfqVjfp9W/Z9W/bPsfTPsfT7APb7APbm7/nm7/mHd/+Hd/+CIgWCIgW4cwm4cwnySQvySQu9KAq9KArCWwbCWwaw4wCw4wCDL/uDL/sxv/Yxv/YgvfQg",
  b"vfResPVesPX+Wfn+WfnNwf7Nwf7BfQTBfQTGCwnGCwn5OAv5OAv8cgr8cgrW7gbW7ga1mAG1mAFj1vtj1vsWLPcWLPfA0/TA0/QSa/USa/W+yfi+yfh9Df59Df7B1APB1APumQjumQj7Gwv7GwtUswpUswrYegfY",
  b"egfmSgLmSgKCgfyCgfwsovcsovdm9vRm9vRiMPViMPVFQfhFQfgBXP0BXP2EJwOEJwPkHgjkHghi9Api9AoS6QoS6QrI/wfI/wdh/AJh/AIqMP0qMP2+IPi+IPioI/WoI/VNAPVNAPVJwfdJwffvq/zvq/xydwJy",
  b"dwLJnAfJnAcuwgouwgp/Ewt/Ews7fAg7fAhUqgNUqgOm4f2m4f3Np/jNp/iEW/WEW/WI2/SI2/RfSPdfSPccAPwcAPyMxAGMxAExEgcxEgf0gwr0gwqcMgucMgsy8Agy8AgJVAQJVARBlf5Blf7uNfnuNfmxnvWx",
  b"nvUTwvQTwvRa2fZa2faGWPuGWPs8EAE8EAGHgAaHgAbUOwrUOwodRwsdRwv4Wgn4Wgk0+gQ0+gRGSv9GSv9syvlsyvnE6/XE6/U5s/Q5s/TTcvbTcvYutfoutfqCWgCCWgCA6AWA6AUZ6QkZ6QmaTwuaTwuNvAmN",
  b"vAm4mgW4mgUAAAAAAABHZfpHZfpyQ/ZyQ/ZlsPRlsPQxFvYxFvbKFvrKFvrIpP/IpP/RSgXRSgV3jAl3jAnGTAvGTAs7FAo7FApINgZINga5tQC5tQCABvuABvsHpfYHpfaXufSXufR2w/V2w/XDfvnDfvkO7/4O",
  b"7/55pwR5pwSlJgmlJgnsPQvsPQsDYgoDYgrGygbGygZzawFzawH2q/v2q/vND/fND/djzfRjzfRWe/VWe/UZ7fgZ7fi+Ov6+Ov4u/wMu/wPstgjstgh4JAt4JAt7pAp7pArnWAfnWAcOHwIOHwJgVvxgVvx5hPd5",
  b"hPeA7PSA7PTRPfXRPfU2Y/g2Y/iNiP2NiP1bUwNbUwO2Pgi2Pgiz/wqz/woN3QoN3QpB3wdB3weK0AKK0AJTBP1TBP04APg4APjtFvXtFvXoCvXoCvVm4Pdm4PfG1/zG1/xJowJJowIFvgcFvgedzwqdzwpOCgtO",
  b"CgvTXQjTXQgyfwMyfwMZtf0Ztf0nhfgnhfirTPWrTPVP4/RP4/QRZvcRZveJKvyJKvzN8QHN8QGMNQeMNQc4lAo4lAo/LAs/LAvp0wjp0whRKgRRKgT/Z/7/Z/7eEfneEfkDjfUDjfUGx/QGx/Q59PY59PY+gvs+",
  b"gvt9PQF9PQFMpQZMpQbsTgrsTgrfQgvfQguDQQmDQQkx0QQx0QQEHf8EHf/ypPnypPn31/X31/UOtvQOtvSSi/aSi/Z93fp93frDhwDDhwBkDwZkDwYE/wkE/wkwTgswTgs3pQk3pQkfcwUfcwW+0v++0v9jPvpj",
  b"PvrSLPbSLPZlsPRlsPTSLPbSLPauPfquPfq+0v++0v9qcgVqcgWCpAmCpAkwTgswTgsE/wkE/wkZEAYZEAZ4iAB4iAB93fp93fpHjPZHjPYOtvQOtvRC1/VC1/U9pPk9pPlPHP9PHP980AR80ATOQAnOQAnfQgvf",
  b"QguhTwqhTwoBpgYBpgYyPgEyPgE+gvs+gvs59PY59PYGx/QGx/QDjfUDjfUpEfkpEflKZ/5KZ/6cKQScKQTp0wjp0wg/LAs/LAvtlArtlApBNgdBNgeC8gGC8gE+K/w+K/wRZvcRZvcE5PQE5PSrTPWrTPUnhfgn",
  b"hfgZtf0Ztf19fgN9fgPTXQjTXQiZCQuZCQudzwqdzwq6vge6vgf+owL+owJ72Px72Pwb4fcb4fedC/WdC/XtFvXtFvU4APg4APieA/2eA/3VzwLVzwJB3wdB3wdY3ApY3Aqz/wqz/wq2Pgi2PggQVAMQVAONiP2N",
  b"iP02Y/g2Y/jRPfXRPfWA7PSA7PTEg/fEg/erVfyrVfxZHgJZHgIyWAcyWAd7pAp7pAp4JAt4JAuhtwihtwjk/wPk/wNzO/5zO/7O7fjO7fgLfPULfPVjzfRjzfTND/fND/f2q/v2q/u+agG+agERygYRygZOYQpO",
  b"YQrsPQvsPQulJgmlJgl5pwR5pwTD7/7D7/54f/l4f/krxPUrxPXiuPTiuPQHpfYHpfbLBfvLBfu5tQC5tQCTNQaTNQY7FAo7FArGTAvGTAssjQksjQnRSgXRSgV9pf99pf9/F/p/F/rmFvbmFvZlsPRlsPRyQ/Zy",
  b"Q/ZHZfpHZfo=",
])

///|
let w64_24_wav_b64 : Bytes = w64fixture_concat([
  b"UklGRr4JAABXQVZFZm10ICgAAAD+/wIAQB8AAIC7AAAGABgAFgAYAAMAAAABAAAAAAAQAIAAAKoAOJtxTElTVBoAAABJTkZPSVNGVA0AAABMYXZmNjMuMS4xMDIAAGRhdGFgCQAAAAAAAAAAuJoFuJoFjbwJjbwJ",
  b"mk8Lmk8LzukJzukJNekFNekFN1sAN1sALrX6LrX6iHP2iHP2ObP0ObP0xOv1xOv1t8n5t8n5Rkr/Rkr/f/kEf/kE+FoJ+FoJaEYLaEYLiTwKiTwKPIEGPIEG8RAB8RABhlj7hlj7Wtn2Wtn2E8L0E8L0/J31/J31",
  b"OTX5OTX5jJT+jJT+CVQECVQEMvAIMvAInDILnDILqYQKqYQK5hIH5hIHQcUBQcUB0QD80QD8FEn3FEn3iNv0iNv0hFv1hFv1GKf4GKf48eD98eD9n6kDn6kDhnsIhnsIfxMLfxMLLsIKLsIKyZwHyZwHcncCcncC",
  b"pKz8pKz8ScH3ScH3TQD1TQD18iL18iL1viD4viD4dS/9dS/9rPsCrPsCyP8HyP8HEukKEukKF/UKF/UKmR8ImR8IOSgDOSgDtlz9tlz9+kH4+kH4YjD1YjD1sfX0sfX0LKL3LKL3zYD8zYD85koC5koC2HoH2HoH",
  b"VLMKVLMKsBwLsBwL7pkI7pkIdtUDdtUDMg7+Mg7+c8r4c8r4x2v1x2v1wNP0wNP0Fiz3Fiz3rtX7rtX7AJgBAJgBIe4GIe4G/HIK/HIK+TgL+TgLxgsJxgsJwX0EwX0EgsL+gsL+s1r5s1r5E7H1E7H1IL30IL30",
  b"fL72fL72zi77zi77++IA++IADVsGDVsGCCgKCCgK8kkL8kkLbXQJbXQJgiIFgiIFPHj/PHj/m/D5m/D5+wD2+wD2z7H0z7H0yFr2yFr24Iz64Iz6QS0AQS0AnMEFnMEFLdMJLdMJmk8Lmk8LLdMJLdMJUcIFUcIF",
  b"QS0AQS0AlY36lY36fVv2fVv2z7H0z7H0+wD2+wD25u/55u/5h3f/h3f/giIFgiIFuHMJuHMJ8kkL8kkLvSgKvSgKwlsGwlsGsOMAsOMAgy/7gy/7Mb/2Mb/2IL30IL30XrD1XrD1/ln5/ln5zcH+zcH+wX0EwX0E",
  b"xgsJxgsJ+TgL+TgL/HIK/HIK1u4G1u4GtZgBtZgBY9b7Y9b7Fiz3Fiz3wNP0wNP0Emv1Emv1vsn4vsn4fQ3+fQ3+wdQDwdQD7pkI7pkI+xsL+xsLVLMKVLMK2HoH2HoH5koC5koCgoH8goH8LKL3LKL3Zvb0Zvb0",
  b"YjD1YjD1RUH4RUH4AVz9AVz9hCcDhCcD5B4I5B4IYvQKYvQKEukKEukKyP8HyP8HYfwCYfwCKjD9KjD9viD4viD4qCP1qCP1TQD1TQD1ScH3ScH376v876v8cncCcncCyZwHyZwHLsIKLsIKfxMLfxMLO3wIO3wI",
  b"VKoDVKoDpuH9puH9zaf4zaf4hFv1hFv1iNv0iNv0X0j3X0j3HAD8HAD8jMQBjMQBMRIHMRIH9IMK9IMKnDILnDILMvAIMvAICVQECVQEQZX+QZX+7jX57jX5sZ71sZ71E8L0E8L0Wtn2Wtn2hlj7hlj7PBABPBAB",
  b"h4AGh4AG1DsK1DsKHUcLHUcL+FoJ+FoJNPoENPoERkr/Rkr/bMr5bMr5xOv1xOv1ObP0ObP003L203L2LrX6LrX6gloAgloAgOgFgOgFGekJGekJmk8Lmk8LjbwJjbwJuJoFuJoFAAAAAAAAR2X6R2X6ckP2ckP2",
  b"ZbD0ZbD0MRb2MRb2yhb6yhb6yKT/yKT/0UoF0UoFd4wJd4wJxkwLxkwLOxQKOxQKSDYGSDYGubUAubUAgAb7gAb7B6X2B6X2l7n0l7n0dsP1dsP1w375w375Du/+Du/+eacEeacEpSYJpSYJ7D0L7D0LA2IKA2IK",
  b"xsoGxsoGc2sBc2sB9qv79qv7zQ/3zQ/3Y830Y830Vnv1Vnv1Ge34Ge34vjr+vjr+Lv8DLv8D7LYI7LYIeCQLeCQLe6QKe6QK51gH51gHDh8CDh8CYFb8YFb8eYT3eYT3gOz0gOz00T310T31NmP4NmP4jYj9jYj9",
  b"W1MDW1MDtj4Itj4Is/8Ks/8KDd0KDd0KQd8HQd8HitACitACUwT9UwT9OAD4OAD47Rb17Rb16Ar16Ar1ZuD3ZuD3xtf8xtf8SaMCSaMCBb4HBb4Hnc8Knc8KTgoLTgoL010I010IMn8DMn8DGbX9GbX9J4X4J4X4",
  b"q0z1q0z1T+P0T+P0EWb3EWb3iSr8iSr8zfEBzfEBjDUHjDUHOJQKOJQKPywLPywL6dMI6dMIUSoEUSoE/2f+/2f+3hH53hH5A431A431Bsf0Bsf0OfT2OfT2PoL7PoL7fT0BfT0BTKUGTKUG7E4K7E4K30IL30IL",
  b"g0EJg0EJMdEEMdEEBB3/BB3/8qT58qT599f199f1Drb0Drb0kov2kov2fd36fd36w4cAw4cAZA8GZA8GBP8JBP8JME4LME4LN6UJN6UJH3MFH3MFvtL/vtL/Yz76Yz760iz20iz2ZbD0ZbD00iz20iz2rj36rj36",
  b"vtL/vtL/anIFanIFgqQJgqQJME4LME4LBP8JBP8JGRAGGRAGeIgAeIgAfd36fd36R4z2R4z2Drb0Drb0Qtf1Qtf1PaT5PaT5Txz/Txz/fNAEfNAEzkAJzkAJ30IL30ILoU8KoU8KAaYGAaYGMj4BMj4BPoL7PoL7",
  b"OfT2OfT2Bsf0Bsf0A431A431KRH5KRH5Smf+Smf+nCkEnCkE6dMI6dMIPywLPywL7ZQK7ZQKQTYHQTYHgvIBgvIBPiv8Piv8EWb3EWb3BOT0BOT0q0z1q0z1J4X4J4X4GbX9GbX9fX4DfX4D010I010ImQkLmQkL",
  b"nc8Knc8Kur4Hur4H/qMC/qMCe9j8e9j8G+H3G+H3nQv1nQv17Rb17Rb1OAD4OAD4ngP9ngP91c8C1c8CQd8HQd8HWNwKWNwKs/8Ks/8Ktj4Itj4IEFQDEFQDjYj9jYj9NmP4NmP40T310T31gOz0gOz0xIP3xIP3",
  b"q1X8q1X8WR4CWR4CMlgHMlgHe6QKe6QKeCQLeCQLobcIobcI5P8D5P8Dczv+czv+zu34zu34C3z1C3z1Y830Y830zQ/3zQ/39qv79qv7vmoBvmoBEcoGEcoGTmEKTmEK7D0L7D0LpSYJpSYJeacEeacEw+/+w+/+",
  b"eH/5eH/5K8T1K8T14rj04rj0B6X2B6X2ywX7ywX7ubUAubUAkzUGkzUGOxQKOxQKxkwLxkwLLI0JLI0J0UoF0UoFfaX/faX/fxf6fxf65hb25hb2ZbD0ZbD0ckP2ckP2R2X6R2X6",
])

///|
fn w64fixture_pcm(demux : @libavformat.WavDemux, data : Bytes) -> Bytes {
  let start = demux.data_offset.to_int()
  let end = start + demux.data_size.to_int()
  data[start:end].to_owned()
}

///|
test "w64: GUID chunks match the WAV payload" {
  let w64 = @libavutil.av_base64_decode(w64_16_b64, 100000).unwrap()
  let wav = @libavutil.av_base64_decode(w64_16_wav_b64, 100000).unwrap()
  let a = @libavformat.av_w64_open(w64).unwrap()
  let b = @libavformat.av_wav_open(wav).unwrap()
  assert_eq(a.format.codec, "pcm_s16le")
  assert_eq(a.format.channels, 1)
  assert_eq(a.format.sample_rate, 8000)
  assert_eq(a.format.bits_per_sample, 16)
  assert_eq(a.sample_count, 400L)
  assert_eq(a.data_size, b.data_size)
  assert_eq(w64fixture_pcm(a, w64), w64fixture_pcm(b, wav))
  let w6424 = @libavutil.av_base64_decode(w64_24_b64, 100000).unwrap()
  let wav24 = @libavutil.av_base64_decode(w64_24_wav_b64, 100000).unwrap()
  let c = @libavformat.av_w64_open(w6424).unwrap()
  let d = @libavformat.av_wav_open(wav24).unwrap()
  assert_eq(c.format.codec, "pcm_s24le")
  assert_eq(c.format.channels, 2)
  assert_eq(c.format.bits_per_sample, 24)
  assert_eq(c.sample_count, 400L)
  assert_eq(c.data_size, d.data_size)
  assert_eq(w64fixture_pcm(c, w6424), w64fixture_pcm(d, wav24))
}

///|
test "w64: writer round-trips PCM and float" {
  let mux = @libavformat.w64_muxer_new(8000, 1, 16).unwrap()
  let samples : Array[Int32] = []
  for i = 0; i < 400; i = i + 1 {
    samples.push(i % 200 * 50 - 5000)
  }
  mux.write_samples(samples)
  let bytes = mux.finish()
  let demux = @libavformat.av_w64_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_s16le")
  assert_eq(demux.format.channels, 1)
  assert_eq(demux.format.sample_rate, 8000)
  assert_eq(demux.sample_count, 400L)
  let pcm = w64fixture_pcm(demux, bytes)
  assert_eq(pcm.length(), 800)
  for i = 0; i < 400; i = i + 1 {
    let v = samples[i]
    let lo = pcm[i * 2].to_int()
    let hi = pcm[i * 2 + 1].to_int()
    let got = lo | (hi << 8)
    assert_eq(if got >= 32768 { got - 65536 } else { got }, v)
  }
  // IEEE float: WAVEFORMATEX tag 3, a fact chunk and 32-bit payload.
  let fmux = @libavformat.w64_muxer_new(8000, 1, 32, float=true).unwrap()
  let fdata : Array[Int32] = [0, 1, -1, 2, -2, 3, -3, 4]
  fmux.write_samples(fdata)
  let fbytes = fmux.finish()
  let fdemux = @libavformat.av_w64_open(fbytes).unwrap()
  assert_eq(fdemux.format.codec, "pcm_f32le")
  assert_eq(fdemux.format.bits_per_sample, 32)
  assert_eq(fdemux.sample_count, 8L)
  assert_eq(w64fixture_pcm(fdemux, fbytes).length(), 32)
}

///|
test "w64: summarylist tags round-trip" {
  let mux = @libavformat.w64_muxer_new(8000, 1, 16).unwrap()
  let samples : Array[Int32] = [1, -2, 3, -4]
  mux.write_samples(samples)
  mux.set_tags([
    ("title", "W64 标题"),
    ("artist", "Artist"),
    ("track", "7"),
    ("custom", "ignored"),
  ])
  let bytes = mux.finish()
  let tags = @libavformat.w64_read_tags(bytes).unwrap()
  assert_eq(tags.length(), 3)
  let mut title = ""
  let mut track = ""
  for pair in tags {
    if pair.0 == "title" {
      title = pair.1
    } else if pair.0 == "track" {
      track = pair.1
    }
  }
  assert_eq(title, "W64 标题")
  assert_eq(track, "7")
  // The audio payload is untouched by the summary list.
  let demux = @libavformat.av_w64_open(bytes).unwrap()
  assert_eq(demux.sample_count, 4L)
  assert_eq(w64fixture_pcm(demux, bytes).length(), 8)
  // A file without tags reads as an empty list.
  let plain = @libavformat.w64_muxer_new(8000, 1, 16).unwrap()
  plain.write_samples(samples)
  assert_eq(@libavformat.w64_read_tags(plain.finish()).unwrap().length(), 0)
}
