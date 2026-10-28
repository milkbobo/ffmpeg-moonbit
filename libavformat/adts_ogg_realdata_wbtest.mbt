///|
/// Real-data tests for the ADTS AAC and Ogg Opus writers. The AAC fixture is
/// the first five access units of the real MKV stream; the reference PCM is
/// FFmpeg 9.0.2's decode of this port's ADTS output. Opus reuses the MP4 Opus
/// reference PCM (three real packets, 312-sample pre-skip).

///|
let adts_ref_pcm_b64 : Bytes = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//////////////////////////////////" +
  b"8AAP//////////////////AAAAAAAAAAAAAAAAAAAAAP///////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAEAAQAB" +
  b"AAEAAQABAAEAAQABAAEAAQACAAIAAQABAAIAAgACAAIAAgACAAIAAgACAAEAAgABAAEAAgABAAAAAQABAAEAAQABAA" +
  b"EA/////wAAAAD///////8AAP7//v////7//v////7//v/////////+//7//////////v/+///////+////////////" +
  b"/////wEAAQAAAAAAAAABAAAAAAABAAAA//8BAAEAAAABAAEAAQABAAAAAQACAAIAAwADAAEAAQADAAIAAQABAAIAAw" +
  b"ABAAAAAQABAAIAAgAAAAEAAgABAAEAAQABAAIAAQABAAEAAQACAAIAAQABAAEAAQABAAAAAAACAAIAAQAAAAIAAgAB" +
  b"AAAAAgACAAIAAwACAAIAAwADAAMAAwADAAMAAwADAAMAAwACAAIAAwADAAIAAgACAAIAAgABAAEAAQABAAAAAAD//w" +
  b"AAAAD////////////////+//7//v/+//3//P/+/////P/8//3//f/9//3//f/+/wAAAAAAAAEAAAABAAIAAQACAAMA" +
  b"AQABAAMAAgACAAQABAAEAAQABQAGAAcABQADAAUABgAEAAMABAAGAAUABAAEAAUABAADAAIAAgAEAAMAAQABAAEAAQ" +
  b"ABAAAA/////////v/9/wAAAQD/////AAD//////f/9////AAD//////////////v/+//7//v8BAP///v///wAA/v/+" +
  b"/wAAAQABAAAAAAABAAEAAQABAP////8CAAAA/v8AAP7//P///////f8AAAMAAgD//wAAAwACAAAAAAABAAIAAQAAAA" +
  b"IAAgABAAIAAAD//wIAAAD9/wAAAAD9/wEAAQD//wAAAAD+/wEAAQAAAAIAAQD+/wAAAQAAAAEAAQABAAEAAQACAAMA" +
  b"AgABAAMAAwABAAIAAQD//wAAAAD8//3///8AAAAA//8AAAMAAAD//wEAAQABAAMABAACAAEAAwADAAMAAwADAAQAAw" +
  b"ABAAQABAABAAEAAwAFAAYABQAFAAIAAQAEAAQA///+//3/+//9//z//P/8//v/+//8//n/+P/6//r/+P/5//v//P/5" +
  b"//j/+v/8//r/+//9//v/+f/6//n/+P/4//v//f/7//r//f/9//3//f/8//7//v/7//z//f/9/wAA///7//3/AQD///" +
  b"r//v8DAAAA/f/+/wIAAwAAAP3/AgAGAAEA//8DAAUAAQAAAAMABAAEAAUAAgACAAQABAADAAMAAwAGAAYAAwAFAAkA" +
  b"CQAIAAcABwAGAAQABgAHAAUABgAJAAgABQAFAAgACQAHAAcACQAIAAUABgAGAAUABQAEAAQABQAEAAIAAQD7//v///" +
  b"/9//r/+f/5//r//f//////+//7//7//P/7//3//f/9//z//P////3/+//9/////////wEA///8/wAAAgAAAAAAAgAE" +
  b"AAUAAQD//wIA///+/////P/8//7//f/8//3//v///////v///wAA//8AAAIA///9/wAA///+/wIAAQAAAAIA/////w" +
  b"QAAAAAAAUAAQD9/wEAAAD9/////f/9/wAA///+//7///8AAP3/+////wEA/f/7/wAABQACAAEABgADAAAABAAAAP3/" +
  b"AQABAP7//v/+//7/AAAAAP///v8BAAMAAwABAAIABAABAP//AwAEAAMAAwADAAIAAgACAAIAAQABAAYABQADAAEA//" +
  b"8BAAIA/v8AAAUABAACAAIAAgABAP7//v/+//7//v/6//j//P/7//r/9//2//j/+P/1//T/9//6//j/8//2//r/9f/x" +
  b"//P/9v/3//f/9v/4//z/+//5//3//v/5//v////8//7/AAD//wAAAAAAAAQABgAGAAgABwAGAAoACQAEAAYACgAIAA" +
  b"YABgAGAAYAAwACAAIAAgADAAMAAAABAAMAAAAAAP///P/+//3/+//8//r/+v/7//j/+P/6//r/+f/3//f/+P/2//b/" +
  b"+P/5//f/9//5//n/9//6//v/+v/+//7/+f/7/////P/4//r/AAD///v//f/8//3//v/6//r//f/8//z/+//7//z/+/" +
  b"/9//7/+P/8////+v/6//r/+/////v/9v/4//v/+//4//X/+//7//T/9f/4//f/+//+//7//f/9//7////+//7/AgAA" +
  b"APv/AAACAP3///8BAP///f/9/wMABgADAAQABgAGAAgABgAGAAkACAAHAAQABAAKAAkABgAHAAYACwALAAYACgAKAA" +
  b"YADQAJAAEABgAGAAQAAQD//wYABgD6//j//P/8//n/+f/9//r/9f/4//X/9P/5//T/8P/0//L/8P/0//T/8f/y//T/" +
  b"9P/z//P/9//3//P/9P/2//X/9//5//n/+v/6//r//P/8//3//v/7/wAAAwABAAQABQAFAAcABwAHAAYAAQAGAAcAAQ" +
  b"AEAAcABgAJAAoACAAKAAsADgALAAgADAAQABEADwAMABEAFgASAA4AEAAUABMADwAOAAwADQARAAwABQAJAA0ACwAH" +
  b"AAIABAAKAAoAAQD7/wIADgALAPT/7P83AOwA6gH+Av8D5ATJBbgGpQeECFAJFArXCpQLPgzVDGYN6w1gDscOHQ9iD5" +
  b"4PyQ/iD+wP4A/ID6cPcg8qD9QObQ7+DYEN7QxNDKwL/Ao6Cm4Jmgi/B90G8wUDBQ0EFQMdAiABIAAi/yT+KP0v/DT7" +
  b"Qfpe+Xn4lvfB9vj1OfWE9NXzMvOk8iPyqfE88ebwofBl8DbwHPAR8BfwLvBQ8IXwzvAh8YLx9PFz8gDzm/M/9O/0r/" +
  b"V59kf3HPgB+e752frM+8j8yf3K/sf/xwDKAccCwAO0BKgFmQZ7B1QILwn7CbgKdAskDMEMUQ3YDVEOuA4TD2MPnw/L" +
  b"D+cP8A/vD94PuA+DD0IP8Q6PDh8OpA0ZDX8M3AsqC2oKownSCPkHGgcvBj8FTwRWA1YCVwFaAFv/WP5Z/WD8avt0+o" +
  b"j5ovjB9+n2G/ZU9Zv08PNO87byMfK58Uzx7/Ci8GbwO/Ab8AzwDvAd8D7wcfCx8APxYvHN8Uny0/Jp8xH0wfR79UP2" +
  b"Effq9874s/mg+pX7jfyI/Yb+h/+MAIwBhQKAA3oEbAVYBkAHHwj2CMUJigpCC/cLnQwsDbUNNQ6dDvcOSQ+KD7YP1g" +
  b"/pD+oP2g+7D4gPSQ8AD6MOMw65DTQNngz4C0gLkgrOCfoIIghGB2EGdAWDBIwDkQKSAZMAkf+O/pP9mfyd+6r6wPnZ" +
  b"+Pf3HPdO9or1y/Qa9Hjz4fJV8tTxZvEK8bnwdfBF8CfwFfAS8CDwPfBr8Krw8/BN8bzxNfK38kvz7POY9FD1Ffbj9r" +
  b"j3l/h8+Wf6WftQ/Ez9S/5K/0gARwFFAkEDOgQuBRwGCAfqB8MIlwlgChkLygtwDAkNlA0UDoQO4w41D3sPrg/SD+YP" +
  b"6Q/hD8UPlg9fDxYPtg5QDtsNVA3BDCIMeAvCCv8JNAldCH8HnAatBb8EzAPMAtEB1wDS/9H+0v3V/OL76vrz+Q75MP" +
  b"hR93z2tfX59Eb0mvP78nDy8vF+8RrxxPCA8FHwKPAM8A3wG/Av8FfwkPDc8DfxmPEL8pTyJ/PE82/0KPXp9bL2iPdo" +
  b"+Ez5O/ov+yP8Hv0c/hj/GQAbARcCFwMUBAYF9gXnBssHpAh4CUIKBQu3C10M/QyODQ8Ohg7pDj8Phw+9D+UP/g8EEP" +
  b"sP4g+2D34POA/hDnoOBQ6EDfMMVAysC/YKMwpqCZcItwfRBu0FAQX/AwUDEQILAf3/5/7S/b/8p/uM+nL5XvhS90b2" +
  b"P/VG9FfzcvKY8crwCvBX77PuIu6e7Svty+x77D7sEez06+/r+esT7ETsh+zc7ELttu1A7tvugu888Abx2fG88qvzov" +
  b"Sn9bf20ff0+B76TfuE/MP9Bf9KAJEB2AIfBGEFngbaBxMJQwpmC4MMmg2iDp0PjhBzEUgSDhPCE2QU9RRxFdoVLxZy" +
  b"FqUWyBbUFs0WtxaOFlUWEBa3FUwV0xRHFKsTAhNMEowRvhDkDwIPFQ4fDR8MFgsGCvEI1AexBokFXQQtA/oBxACJ/0" +
  b"r+Cf3G+4D6O/n397f2fPVH9Bvz9/Hc8Mnvvu6+7dLs9ust63bq0+lH6c/ob+go6Prn6Ofw5xboV+iz6Cnpu+ln6i7r" +
  b"DOwD7RDuNO9t8LfxE/N/9Pf1evcH+Zz6N/zW/Xb/FwG5AlgE8QWEBw0Jiwr+C2MNtQ73DyYRPhI/EyYU9BSlFTgWsB" +
  b"YHFz8XWhdVFzEX7xaNFgsWbBWyFNoT5xLbEbYQfQ8yDtIMZAvrCWUI2AZGBawDEgJ5AOL+UP3F+0X6z/hk9wn2wPSG" +
  b"82LyUfFR8Gnvmu7e7Tntruw57Nzrm+tz62PrbOuL68DrD+xz7O3se+0b7tLumu9w8FPxQPI68z/0SvVh9n33m/i9+d" +
  b"76/vsg/UD+Yf9wAHcBegJ6A3IEXgVIBi8HEgjsCLsJgQo7C+0LkwwuDb0NPQ6sDgwPWw+bD80P8Q8EEAYQ+A/bD6sP" +
  b"ag8aD7sOTQ7UDU8NuwwbDG8LswrrCRoJPwhcB3MGhQWSBJoDngKeAZsAmP+W/pX9lfyZ+6L6rvnC+N/3A/cy9mz1sf" +
  b"QD9GDzyvJB8sTxVfH18KTwY/A18BXwB/AH8BfwNfBi8KDw7vBK8bbxMPK28krz6vOW9E71EPbc9rH3jfhx+Vz6S/tA" +
  b"/Dj9Mf4s/ygAJQEhAhoDEAQABesF0gazB40IYgkuCvAKpQtNDOkMeA37DXIO2g4xD3gPrQ/UD+wP9g/yD9wPsQ9yDy" +
  b"wP2w52Dv8New3rDE4MowvqCiMKUwl4CJgHsgbEBdEE1wPZAtkB2ADY/9r+3v3k/Oz79/oK+iL5Qvho95f20PUT9WD0" +
  b"ufMf85PyFPKi8Tzx5fCe8GbwPvAm8B7wJfA68GDwlPDY8C3xjfH88XryBvOg80j0+/S79Yb2XPc4+B35DfoB+/n7+P" +
  b"z6/fz+AAADAQUCBgMBBPYE5AXNBq8HhwhYCSAK3QqSCzwM1QxlDekNXA6/DhUPXQ+VD7oP0g/dD9gPxQ+gD2sPKw/e" +
  b"DoEOFQ6YDQ4NeAzSCx0LYAqYCcUI6gcFBxkGKAUtBCsDJwIkASIAIP8a/hf9GPwY+yb6O/lU+HL3mvbY9R31avTB8y" +
  b"HzjvIK8pnxN/He8JLwWfAv8BTwB/AL8CTwTPCA8MHwFPF38ebxYfLt8ofzL/Tm9KP1afY79xb49/jd+cn6v/u6/Lf9" +
  b"uP67/78AwQG+ArgDrwShBY8GdwdVCC0J/gnBCngLIgzCDFYN3A1TDr0OGQ9lD6IPzw/qD/YP9Q/jD74PjA9ND/sOmg" +
  b"4qDq0NIQ2JDOMLMQt1CrAJ4QgICCgHPwZPBVsEYANgAmEBYwBh/2H+Y/1o/G77efqL+aP4w/ft9h/2WfWg9PLzTvO1" +
  b"8ivysfFE8efwmfBb8CvwDfD/7//vD/Ax8GPwovDv8FLxx/FF8tXya/MM9L30d/U+9hH36vfK+LL5oPqU+478iv2J/o" +
  b"r/igCKAYgCgwN6BGwFWQZAByAI+AjJCZEKTgv+C6MMOg3CDT0Oqw4HD1QPlA/DD+AP7w/tD9kPuA+LD00PAA+mDjoO" +
  b"vg00DZ0M+QtJC5AKzAn+CCcISQdhBnQFgwSMA5EClQGVAJT/lP6V/Zn8oPur+r751fjz9xz3TPaF9cr0GvR189zyUv" +
  b"LW8WnxCvG78HrwSPAm8BfwF/Al8ELwb/Cq8PXwUfG+8TfyvvJW8/jzpPRf9SH27PbB9574gflt+l/7VfxR/VD+Tv9N" +
  b"AE0BSQJCAzgEKwUbBgYH6wfICJ4JZwopC9kLewwWDZ4NHg6TDvQOQw+GD7sP3w/zD/gP7Q/RD6UPaA8bD8EOVw7eDV" +
  b"sNyQwrDIMLzgoLCj4JaQiMB6cGuwXIBNED1gLaAd0A3f/c/tv93Pzj++/6AfoZ+TX4WfeH9r31/vRM9KXzCfN88vvx" +
  b"iPEk8c/wifBU8C/wGPAS8BzwNPBf8Jnw4fA68Z/xFPKY8irzx/Ny9Cj16fWz9of3Y/hF+TH6I/sY/BP9Ef4P/xEAEg" +
  b"EPAgsDAwT4BOsF1wa6B5MIZAktCu0KogtLDOgMfA0CDnwO5g49D4MPvA/lD/sPAhD4D90PtQ+ADzoP4g59DggOgg3u" +
  b"DFEMqgvzCjQKaAmTCLgH1AbrBfgEBAQKAwoCCgEHAAX/CP4K/Q78F/sl+jn5U/h195/20/UR9Vv0rvMQ84Hy//GL8S" +
  b"Txy/CA8EbwHvAF8PvvAvAY8D3wc/C48A3xc/Ho8Wry+vKU8zn07PSr9XL2R/ci+AT58fni+tf70/zO/cz+zv/NAM0B" +
  b"0ALLA8QEuAWlBo0HbghGCRYK2gqTC0EM4gx1DfsNcQ7ZDjEPew+2D+IP/g8KEAMQ7A/GD5APSw/4DpQOIg6hDRMNdw" +
  b"zRCx8LYQqZCckI7gcLByEGMgU+BEUDSAJLAUsAS/9M/k79U/xc+2n6f/mZ+Lj34fYT9k/1lPTl80TzrPIj8qfxO/Hg" +
  b"8JTwV/Ao8Arw/O//7xPwN/Bq8K3w/vBe8czxSPLR8mjzC/S49HH1OPYH99/3wPiq+Zj6ivuC/H39ev54/3gAdgFzAm" +
  b"0DYwRVBUMGKQcICOAIsAl1CjAL3guADBgNog0eDo4O7w5AD4IPsw/VD+YP5w/aD74PkQ9UDwcPqw5BDscNQQ2uDA4M" +
  b"YQuqCucJGQlECGYHgAaUBaIEqwOwArMBtQC1/7b+uv2//Mf70fri+fj4Fvg892v2o/Xm9DP0i/Pw8mLy4/Fx8Q7xuv" +
  b"B28EDwGvAD8P3vB/Ai8E7wifDS8CrxkfEI8ovyHPO682f0H/Xj9bD2hPdd+EP5N/oz+yr8HP0V/hf/IQAlASYCJQMe" +
  b"BBIFBAbzBtsHugiRCV4KHgvSC3sMGg2tDTMOqw4SD2kPsA/nDxAQKRAzECwQFBDqD7EPaQ8SD6wOOA61DSQNhQzaCy" +
  b"MLYAqTCbwI3gf3BggGEwUaBBwDGwIZARUAEv8P/g79EPwW+yD6L/lG+Gb3j/bA9fz0QvSU8/LyXvLX8V/x9/Ce8FLw" +
  b"FvDr79Hvx+/N7+TvCfA/8Ifw3PBA8bPxNvLJ8mjzEPTE9IT1UPYn9wj47/jb+c36xvvC/ML9xf7K/80AzwHPAs0DyA" +
  b"S9BasGkwdzCEoJGArcCpULQwzkDHgN/g12Dt8OOA+DD74P6Q8DEA0QBhDvD8kPkw9MD/cOlA4iDqANEQ10DMoLFgtX" +
  b"Co0JugjeB/gGCwYZBSIEJwMpAisBLAAr/yn+Kf0u/Dj7Rvpa+XP4lPe/9vL1MPV79NHzM/Oh8h3ypvE/8ejwofBo8D" +
  b"/wJPAa8CHwOvBh8Jjw3vA08ZjxC/KM8hrztfNd9BD1zvWX9mn3Q/gm+RD6/vrz++v85v3k/uL/4QDfAdkC0QPFBLUF" +
  b"ngaBB10ILwn4CbYKawsTDK4MPQ2/DTMOmQ7wDjgPcQ+YD7APug+0D50Pdg8+D/gOow5ADs8NUA3DDCgMggvRChYKUA" +
  b"mACKgHyAbhBfQEAwQQAxoCIgEpADD/Nv48/UT8Uvtm+n/5ofjL9/z2NfZ59cn0I/SH8/nyefIH8qTxUPEK8dHwp/CN" +
  b"8ITwjPCi8Mnw/fBB8ZPx9fFm8ubycfMI9Kz0W/UW9tr2p/d8+Fn5Pfon+xX8CP39/fX+7f/lANwB0wLFA7MEnQWBBl" +
  b"8HNQgBCcYJgQowC9ULbwz7DHoN6w1PDqQO6g4hD0kPYQ9pD2IPSw8kD+0OqQ5XDvUNhA0HDX0M5gtCC5MK2QkWCUoI" +
  b"dQeYBrQFygTcA+oC9gH/AAgAEf8a/ib9NfxI+1/6e/me+Mj3+vY29n71z/Qp9JDzA/OE8hPyr/FX8Q/x1fCt8JPwiv" +
  b"CR8Kbwy/D+8EHxk/Hz8WLy3/Jp8wD0o/RR9Qr2zPaY92z4Rfkn+g77+/vt/OH92P7Q/8gAvgGyAqQDkgR7BV8GPAcS" +
  b"CN8IpAlgChILuAtSDN4MXw3TDTkOkg7bDhYPQQ9cD2kPaA9XDzgPCA/IDnkOHQ6zDTsNtgwlDIYL3QopCmsJpAjVB/" +
  b"4GIAY7BVEEYgNuAnkBgwCN/5f+ov2u/L370vrr+Qr5M/hi95n22fUi9Xf01/NE877yRvLb8XzxLfHt8LvwmfCG8IPw" +
  b"jvCp8NPwDfFW8a/xFvKK8gzzm/M29N70kvVP9hf35ve9+J35g/pt+178Uv1I/kD/OQAzASsCIQMUBAIF6wXOBqoHgA" +
  b"hOCRIKzAp7Cx8MtwxCDcENMQ6UDucOKg9hD4cPnA+jD5kPgg9bDyQP3w6JDiIOrg0vDaIMCQxiC64K8QksCV0IhQek" +
  b"Br0F0QTiA+4C9gH7AAAABP8I/hD9Gvwo+zz6U/lx+Jb3xPb89T71i/Tj80bztvI08sDxW/EE8bvwgvBY8D/wNfA78F" +
  b"HwdvCr8O/wRPGn8Rbyk/Ie87fzXfQM9cb1i/ZZ9zH4D/n1+eP61/vN/Mb9wf6//70AuAGyAqsDnwSPBXgGWgc3CAwJ" +
  b"1wmaClEL/AucDC8Ntg0uDpYO8Q4+D3sPqg/JD9cP1A/CD6IPcw8yD+EOgQ4SDpYNDQ11DNMLJQtqCqQJ1Qj9Bx8HOQ" +
  b"ZNBVsEZQNrAm0BcABy/3L+dP15/ID7j/qk+b343vcG9zj2dPW79A70bPPW8k3y0/Fn8QvxvPB98E/wMPAh8CLwNPBU" +
  b"8IPwxPAU8XPx4fFc8uXyfPMg9ND0ivVQ9h/39/fY+L75rPqf+5b8kP2O/o7/jgCNAYsChgN/BHIFXwZGBycIAAnPCZ" +
  b"QKTQv7C5wMMg27DTcOow7/Dk0PjQ+9D9wP7A/sD9sPuw+LD0sP+w6dDi8Osw0pDZEM7Qs8C4EKuwnrCBMIMwdJBlkF" +
  b"ZQRsA3ACcgF0AHT/c/51/Xj8f/uM+p75tfjT9/r2K/Zm9av0+/NY88HyOfK+8VHx8fCg8GDwMfAS8ALwA/AU8DTwYv" +
  b"Cg8PDwUPG98TjywfJY8/zzrPRo9S/2//bY97n4ofmQ+oT7ffx7/Xr+fP99AH0BfAJ5A3MEagVbBkQHJggACdIJmQpW" +
  b"CwgMrQxFDdANTQ68DhoPaQ+pD9oP+g8KEAkQ+Q/YD6gPaA8YD7kOSw7ODUYNrgwKDFoLnwrZCQgJLwhOB2YGdgWCBI" +
  b"gDjAKMAYsAif+I/oj9i/yR+5z6rPnD+OH3CPc59nL1tvQG9GHzyfI+8sPxV/H38KbwZvA28BTwBfAG8BfwOPBo8Kjw" +
  b"9vBV8cLxPvLI8l/zAvSx9Gz1MvYC99v3vPil+ZT6h/t+/Hv9ef55/3oAeQF3AnMDbARgBU4GNgcYCPAIwAmFCj8L8A" +
  b"uTDCkNsw0vDpwO+w5JD4cPtg/WD+YP5w/XD7YPhg9GD/cOmQ4uDrQNKw2VDPMLRAuJCsUJ+AghCEAHWgZvBX0EhgOM" +
  b"Ao8BkgCU/5b+mv2h/Kr7uPrL+eT4Bvgv92D2nPXj9DX0kfP78nPy+PGK8Szx3fCd8GvwSvA58DfwRfBj8JDwzvAa8X" +
  b"bx4PFX8tzycPMQ9Lz0c/U09v/20vet+JH5evpo+1z8U/1N/kj/RABAATsCMwMnBBkFBQbqBsgHnwhtCTIK7QqdC0EM" +
  b"2AxjDeANTg6vDgIPRQ95D54Psg+3D6wPkg9oDy4P5g6ODicOsg0wDaEMBQxdC6oK7AkkCVIIeQeYBrEFxATSA9wC4w" +
  b"HoAO3/8v73/f/8C/wa+y36R/ln+I/3wfb69T31jPTm80vzv/I/8szxaPET8c3wlvBv8FfwT/BX8G/wlvDN8BPxaPHL" +
  b"8T3yvfJK8+TzivQ89fj1vvaN92X4RPkq+hb7CPz9/PX97/7r/+YA4QHZAs8DwQSvBZcGeAdSCCQJ7AmrCl4LBwyjDD" +
  b"MNtg0qDo8O5w4wD2kPkw+uD7kPsw+eD3oPRg8CD7AOTg7eDWAN1Aw7DJcL5wosCmcJmAjAB+AG+gUOBR0EJgMsAjIB" +
  b"NgA5/z3+Q/1M/Fn7avqA+Z34wffu9iT2ZPWu9AT0ZvPU8lDy2vFx8RjxzfCT8GfwS/A/8ELwVfB48Kvw7fA+8Z7xDf" +
  b"KJ8hPzqvNO9P30uPV+9kz3I/gC+en51frH+738tv2x/q7/qwCnAaICmgOOBH4FaQZNByoI/gjKCYsKQwvvC44MIQ2n" +
  b"DR8OiQ7kDjAPbQ+aD7gPxg/ED7IPkA9fDx8Pzg5vDgEOhQ38DGYMwwsUC1oKlgnICPEHEwctBkEFTwRZA2ACZAFoAG" +
  b"v/bv5y/Xr8hfuV+qr5xfjn9xL3RfaD9cv0H/R+8+ryY/Lq8X/xI/HV8JjwafBK8DzwPPBN8G/wnvDe8C3xi/H48XPy" +
  b"+/KR8zL04fSa9V32K/cB+OD4xfmx+qL7mPyQ/Yv+iP+GAIIBfgJ3A2wEXQVIBi0HCwjgCK0JcAooC9ULdwwLDZINDA" +
  b"54DtUOIw9iD5EPsQ/BD8APsA+RD2IPIw/UDncOCw6SDQoNdgzUCycLbgqrCd8ICQgsB0gGXQVtBHgDfwKFAYgAi/+P" +
  b"/pT9nPyn+7b6y/nm+Aj4M/dm9qP16vQ99JvzBvN+8gPylvE58erwqvB68FrwSPBH8FbwdfCj8ODwLfGJ8fPxbPLy8o" +
  b"XzJfTR9If1SvYV9+n3xfio+ZH6gft1/Gz9Zv5i/14AWQFUAkwDQAQwBRsGAAfdB7MIgAlECv0KqwtODOQMbA3nDVUO" +
  b"tA4ED0UPdg+ZD6sPrQ+gD4QPVw8cD9AOdg4ODpcNEg2BDOQLOQuECsUJ+wgpCE8HbQaEBZYEowOtArQBugC+/8P+yf" +
  b"3S/N777voE+h/5Qfhr95322fUg9XH0zfM3863yMfLC8WLxEPHN8JrwdvBi8F7wafCD8K7w6PAx8Ynx7vFj8ubydPMQ" +
  b"9Lj0a/Up9vH2wveb+Hv5YvpP+0D8Nf0t/ib/IQAbARQCCgP+A+8E2QW+Bp0HcwhBCQYKwApwCxUMrQw4DbYNJw6JDt" +
  b"wOIQ9WD3wPkg+ZD5APeA9QDxkP0g58DhgOpg0nDZoMAAxaC6kK7QkoCVkIgQeiBr0F0gTiA+4C9wH+AAUADP8T/hz9" +
  b"KPw4+036aPmJ+LL34/Yd9mH1sPQK9HDz4/Jj8vHxjfE38fDwuPCQ8HfwbvB08IrwsPDl8Cnxe/Hd8U3yyvJV8+zzj/" +
  b"Q+9fj1vPaJ91/4PPkg+gr7+fvr/OH92P7S/8sAxAG7Aq8DnwSLBXEGUAcpCPkIwAl9Ci8L1wtyDAINhA34DV4Otw4A" +
  b"DzoPZA+AD40PiQ91D1IPIA/fDo8OMA7DDUkNwAwsDIoL3QomCmQJmAjEB+kGBgYeBTEEPwNKAlIBWQBg/2j+cf18/I" +
  b"z7oPq5+dj4//cu92X2p/Xy9En0q/Ma85XyHvK28VvxD/HS8KXwh/B38HjwiPCp8NjwF/Fk8cDxK/Kj8ijzu/Na9AX1" +
  b"u/V79kT3F/jw+NH5ufql+5f8i/2C/nr/dABsAWMCWQNKBDcFHwYAB9sHrQh4CTgK7gqaCzoMzQxUDc0NOA6WDuUOJA" +
  b"9VD3YPhw+JD3sPXg8xD/YOqw5RDukNcw3wDF8MwwsaC2YKqAngCA8INwdWBnAFhASTA58CqAGwALb/vv7G/dH83vvw" +
  b"+gj6JflJ+HX3qfbn9S71gfTe80nzwPJE8tbxdvEm8ePwsPCN8HnwdPB/8JrwxPD+8EbxnfED8nfy+PKH8yL0yPR79T" +
  b"j2/vbO96b4hflr+lf7R/w7/TH+Kv8kAB0BFAILA/4D7QTXBbsGmAdvCD0JAQq7CmoLDgymDDINrw0fDoEO1A4YD04P" +
  b"dA+KD5EPiA9wD0cPEA/KDnQOEA6eDR8Nkgz4C1ILogrlCR8JUAh5B5oGtQXKBNoD5gLvAfYA/P8C/wr+E/0f/C/7Q/" +
  b"pe+X/4qPfY9hL2V/Wm9AD0ZvPa8lry6PGE8S/x6PCx8InwcfBp8G/whvCs8OLwJ/F78d3xTvLM8ljz8fOW9Eb1AfbG" +
  b"9pX3bPhK+S/6GvsL/P/89v3v/un/5ADdAdUCygO7BKgFjwZuB0cIFwnfCZwKTwv1C5EMIA2hDRQOeg7SDhkPUg98D5" +
  b"UPnw+aD4QPXw8sD+gOlQ40DsQNRw28DCQMgAvQChYKUgmDCK0HzgbpBf4EDgQaAyMCKQEuADP/Of5B/Uv8WPtr+oT5" +
  b"o/jJ9/f2L/Zx9bz0E/R38+fyZPLv8YjxL/Hm8KvwgPBl8FnwXfBx8JXwx/AK8Vvxu/Eq8qbyMPPH82r0GfXT9Zb2ZP" +
  b"c6+Bf5/Pnn+tf7zPzD/bz+uP+zAK4BqAKeA5EEfwVoBkoHJQj3CMEJgQo2C+ELfwwRDZUNDA51Ds8OGg9XD4MPoQ+u" +
  b"D6sPmQ94D0cPBQ+2DlgO6g1vDecMUQyvCwILSQqGCbkI5AcHByIGNwVIBFMDXAJiAWYAav9v/nX9fvyL+5z6s/nP+P" +
  b"L3HvdT9pH12vQu9I/z+/J08vvxkPE08efwqPB58FrwS/BL8FvwevCq8OnwNvGT8f7xd/L/8pPzM/Tg9Jf1WfYl9/n3" +
  b"1vi6+aP6lPuI/H/9ef51/3IAbgFoAmADVAREBTAGFAfyB8gIlQlZChILwAtiDPgMgQ38DWkOxw4YD1gPig+sD70PwA" +
  b"+yD5UPaA8rD98OhQ4bDqQNHw2NDO4LQwuNCswJAQkuCFEHbgaEBZQEoAOoAq4BsQC1/7n+vv3E/M/73frw+Qr5KvhS" +
  b"94T2vvUC9VL0rvMV84ryDfKd8Tzx6vCm8HLwTvA68DTwQPBb8IbwwPAJ8WLxyfE+8sLyU/Pw85r0T/UP9tn2rPeH+G" +
  b"r5VfpD+zf8MP0r/if/JQAiAR4CGQMQBAMF8QXaBrsHlQhmCS4K6wqdC0QM3wxsDe0NXg7CDhcPXQ+TD7oP0A/XD84P" +
  b"tQ+ND1UPDg+3DlEO3Q1bDcwMLwyHC9IKEwpKCXcInAe5BtAF4QTsA/QC+QH7APz//v4B/gX9DfwY+yj6P/lb+ID3rf" +
  b"bj9ST1cfTH8yvzm/IZ8qTxPvHn8J/wZ/A+8CXwHPAk8DvwYvCY8N7wM/GY8QryjPIa87XzXfQR9c/1mfZr90b4KPkS" +
  b"+gH79vvu/Or96f7o/+cA5gHjAt0D0gTDBa4GkgdvCEQJDwrQCocLMQzQDGEN5Q1bDsMOHA9mD6APyQ/kD+8P6Q/TD6" +
  b"4PeQ8zD+AOfQ4LDosN/QxjDLsLCAtKCoIJsAjVB/EGCAYYBSMEKQMtAi8BLgAu/y/+Mf03/D/7Tfph+Xz4nvfI9vv1" +
  b"OPWA9NTzNPOh8hzypPE78eHwlvBb8C/wE/AI8AvwIPBF8HnwvfAQ8XLx5PFj8vDyivMx9OP0ofVp9jv3F/j6+OT51P" +
  b"rJ+8P8wP2//r//wADAAb8CugOxBKUFkgZ5B1kIMAn9CcEKegsnDMgMXA3iDVwOxg4hD20Pqg/WD/MPABD8D+oPxg+S" +
  b"D08P/Q6bDisOrA0gDYYM3wsuC3AKqAnWCPsHGAcuBj4FSQRPA1ECUgFRAFD/UP5R/VX8XPto+nr5k/iz99v2DfZI9Y" +
  b"704PM+86nyIfKn8Tzx4PCS8FXwJ/AJ8Pvv/u8Q8DPwZvCo8PnwWvHK8Ufy0/Js8w=="

///|
test "adts muxer: real AAC frames decode against FFmpeg PCM" {
  let data = @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap()
  let src = av_matroska_open(data).unwrap()
  let mux = adts_muxer_new(44100, 1).unwrap()
  let mut count = 0
  for packet in src.packets {
    if packet.stream_index == 1 && count < 5 {
      mux.write_frame(packet.data).unwrap()
      count = count + 1
    }
  }
  assert_eq(count, 5)
  let bytes = mux.finish()
  let track = av_adts_open(bytes).unwrap()
  assert_eq(track.codec, "aac")
  assert_eq(track.sample_rate, 44100)
  assert_eq(track.channels, 1)
  assert_eq(track.frames.length(), 5)
  let dec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  let out : Array[Double] = []
  for frame in track.frames {
    let start = frame.pos.to_int() + @libavcodec.av_aac_adts_header_size
    let end = frame.pos.to_int() + frame.size
    let pcm = match dec.decode_frame(bytes[start:end].to_owned()) {
      Ok(v) => v
      Err(e) => fail("AAC decode failed: \{e}")
    }
    for element in pcm {
      for v in element.samples {
        out.push(v)
      }
    }
  }
  assert_eq(out.length(), 5120)
  let reference = @libavutil.av_base64_decode(adts_ref_pcm_b64, 16384).unwrap()
  assert_eq(reference.length(), 10240)
  let mut max_diff = 0
  for i = 0; i < 5120; i = i + 1 {
    let v = out[i] * 32768.0
    let q = if v >= 32767.5 {
      32767
    } else if v <= -32768.5 {
      -32768
    } else {
      v.round().to_int()
    }
    let start = 2 * i
    let want = reference[start].to_int() | (reference[start + 1].to_int() << 8)
    let want = if want >= 32768 { want - 65536 } else { want }
    let diff = if q > want { q - want } else { want - q }
    if diff > max_diff {
      max_diff = diff
    }
  }
  assert_true(max_diff <= 1, msg="ADTS AAC max diff \{max_diff}")
}

///|
test "ogg muxer: real Opus packets decode against FFmpeg PCM" {
  let packet = @libavutil.av_base64_decode(ogg_mux_packet_b64, 10000).unwrap()
  let mux = ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let bytes = mux.finish()
  let demux = av_ogg_opus_open(bytes).unwrap()
  assert_eq(demux.packets.length(), 3)
  let head = @libavcodec.opus_parse_head(demux.extradata).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let out : Array[Float] = []
  for p in demux.packets {
    let (pcm, n) = dec.decode_packet(Some(p.data)).unwrap()
    for i = 0; i < n; i = i + 1 {
      out.push(pcm[0][i])
    }
  }
  assert_eq(out.length(), 2880)
  let reference = @libavutil.av_base64_decode(mp4_opus_ref_pcm_b64, 16384).unwrap()
  let mut max_diff = 0
  for i = 0; i < 2568; i = i + 1 {
    let v = out[i + 312].to_double() * 32768.0
    let q = if v >= 32767.5 {
      32767
    } else if v <= -32768.5 {
      -32768
    } else {
      v.round().to_int()
    }
    let start = 2 * i
    let want = reference[start].to_int() | (reference[start + 1].to_int() << 8)
    let want = if want >= 32768 { want - 65536 } else { want }
    let diff = if q > want { q - want } else { want - q }
    if diff > max_diff {
      max_diff = diff
    }
  }
  assert_true(max_diff <= 1, msg="Ogg Opus max diff \{max_diff}")
}
