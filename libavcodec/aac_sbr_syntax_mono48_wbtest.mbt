///|
/// SBR syntax-layer bit-exactness against the instrumented FFmpeg 9.0.2
/// decoder dump (`_build/sbr_work`, `instrument_sbr.py`): every parsed
/// field of every frame of `sbr_mono48.aac` must match. Post-apply fields
/// (bw_array, f_indexnoise/sine, Ypos) are excluded. LGPL-2.1-or-later.
/// Stream: docker linuxserver/ffmpeg:9.0.2 + libfdk_aac -profile:a aac_he.
let sbr_mono48_adts_b64 : Bytes = b"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"

///|
let sbr_mono48_expected : Array[Array[String]] = [
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=32 kx1=24 m0=0 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=0",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=1 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=16",
    "TENV 0 5 7 11 17", "TQ 0 5 17", "FREQRES 1 0 0 1", "DFENV 0 0 0 1", "DFNOISE 0 0",
    "INVF 1 1", "ENVQ1 4 5 5 4 4 2 4 3 5 5 4 4 5 5", "ENVQ2 22 21 23 21 23 23 23",
    "ENVQ3 23 23 23 23 23 23 23", "ENVQ4 23 23 23 22 23 23 23 23 21 23 23 23 23 23",
    "NOISEQ1 8 8", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=17",
    "TENV 1 6 8 12 18", "TQ 1 6 18", "FREQRES 1 0 0 1", "DFENV 0 1 1 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 23 22 23 23 23 22 22 23 23 23 23 23 23 24", "ENVQ2 22 23 23 23 24 24 23",
    "ENVQ3 23 23 24 23 23 23 23", "ENVQ4 22 22 23 23 23 22 23 23 23 23 23 22 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=18",
    "TENV 2 7 9 13 19", "TQ 2 7 19", "FREQRES 1 0 0 1", "DFENV 0 1 0 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 23 23 23 23 23 22 23 23 23 23 23 23 23 23", "ENVQ2 22 23 22 22 23 23 23",
    "ENVQ3 23 23 23 23 23 23 23", "ENVQ4 22 23 22 23 23 23 22 23 23 23 23 22 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=19",
    "TENV 3 7 9 13 19", "TQ 3 7 19", "FREQRES 1 0 0 1", "DFENV 0 1 1 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 23 23 23 22 23 22 23 23 23 24 23 23 23 23", "ENVQ2 23 23 23 23 23 22 23",
    "ENVQ3 23 23 23 22 23 23 23", "ENVQ4 22 23 23 23 23 23 23 23 23 22 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=2 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=19",
    "TENV 3 9 16", "TQ 3 9 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 22 22 23 23 23 23 23 23 23 23 23 23 23 23", "ENVQ2 23 23 22 22 23 23 23 23 23 22 23 24 24 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 22 23 23 23 22 23 23 23 23 23 23 23 23", "ENVQ2 23 23 23 23 23 23 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 1 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 23 23 23 23 23 23 23 23 23 23 22 23", "ENVQ2 23 23 23 23 23 23 23 23 22 23 23 23 23 22",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 0", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 22 22 23 23 23 23 22 23 22 23 22 23 23 23", "ENVQ2 23 23 24 23 23 23 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 0 1", "INVF 1 1",
    "ENVQ1 23 24 23 23 23 23 22 24 23 23 23 23 23 23", "ENVQ2 23 23 23 23 23 23 23 23 23 23 22 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 24 23 23 23 22 23 23 23 23 23 24 23 23 23", "ENVQ2 23 23 23 23 23 23 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 1 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 22 23 23 23 23 22 23 23 23 23 23 22 23 23", "ENVQ2 23 24 23 23 23 23 23 23 22 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 23 23 23 23 23 23 23 23 23 22 23 23", "ENVQ2 22 23 23 23 23 23 23 24 22 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 23 22 23 23 23 23 23 23 23 23 23 23", "ENVQ2 23 23 22 23 23 23 22 24 22 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 22 23 22 23 23 23 23 23 23 23 23 23 23 23", "ENVQ2 23 22 23 23 23 23 23 23 23 22 22 22 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 24 23 23 23 23 23 23 23 23 23 23 23 23", "ENVQ2 23 23 23 23 23 23 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 1 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 22 23 23 23 23 24 23 22 23 24 23 23 23 23", "ENVQ2 23 22 23 23 22 23 22 22 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 23 23 23 23 23 23 23 23 23 23 23 22", "ENVQ2 22 23 23 23 23 23 23 23 23 22 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=1 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=2 told=16",
    "TENV 0 10 18", "TQ 0 10 18", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 23 23 23 23 23 24 23 23 23 23 23 23", "ENVQ2 23 22 23 24 23 23 23 24 23 23 23 22 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=3 nenv=3 amp=1 nnoise=2 ea0=0 ea1=3 told=18",
    "TENV 2 4 8 17", "TQ 2 8 17", "FREQRES 0 0 1", "DFENV 0 1 0", "DFNOISE 0 1",
    "INVF 1 1", "ENVQ1 22 23 23 24 23 23 23", "ENVQ2 22 23 23 22 23 23 23", "ENVQ3 23 23 23 23 23 23 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=2 nenv=3 amp=1 nnoise=2 ea0=0 ea1=-1 told=17",
    "TENV 1 3 7 16", "TQ 1 7 16", "FREQRES 0 0 1", "DFENV 1 1 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 24 23 23 24 23 24 23", "ENVQ2 23 23 23 23 23 23 23", "ENVQ3 23 23 23 23 23 24 23 23 23 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=1 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=2 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 23 23 24 23 23 23 23 23 23 23 23 23 22 23", "ENVQ2 22 23 23 23 22 23 23 23 22 23 23 23 23 23",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=13 stopf=11 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=24 k1=48 k2=54 kx0=24 kx1=24 m0=30 m1=30 nmaster=14 n0=7 n1=14 nq=2 nlim=3 npatch=2 sr=48000",
    "FMASTER 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTLOW 24 26 30 34 38 42 48 54",
    "FTHIGH 24 25 26 28 30 32 34 36 38 40 42 45 48 51 54", "FTNOISE 24 34 54", "FTLIM 24 30 45 54",
    "PATCHN 21 9", "PATCHS 2 15", "CH0 class=2 nenv=3 amp=1 nnoise=2 ea0=0 ea1=-1 told=16",
    "TENV 0 2 6 16", "TQ 0 6 16", "FREQRES 0 0 1", "DFENV 0 1 0", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 23 23 23 22 23 23 24", "ENVQ2 23 23 23 23 23 23 23", "ENVQ3 20 17 18 18 19 19 20 20 18 16 18 18 18 19",
    "NOISEQ1 7 7", "NOISEQ2 10 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
]

///|
fn sbr_mono48_serialize(sbr : AacSbr) -> Array[String] {
  let lines : Array[String] = []
  let nch = if sbr.id_aac == aac_id_cpe { 2 } else { 1 }
  lines.push(
    "BEGIN id_aac=\{sbr.id_aac} nch=\{nch} coupling=\{sbr.bs_coupling}",
  )
  lines.push(
    "HDR amp_res_hdr=\{sbr.bs_amp_res_header} startf=\{sbr.spectrum_params.bs_start_freq} stopf=\{sbr.spectrum_params.bs_stop_freq} xover=\{sbr.spectrum_params.bs_xover_band} fscale=\{sbr.spectrum_params.bs_freq_scale} alter=\{sbr.spectrum_params.bs_alter_scale} nzb=\{sbr.spectrum_params.bs_noise_bands} lim_b=\{sbr.bs_limiter_bands} lim_g=\{sbr.bs_limiter_gains} ifreq=\{sbr.bs_interpol_freq} smooth=\{sbr.bs_smoothing_mode}",
  )
  lines.push(
    "TBL k0=\{sbr.k[0]} k1=\{sbr.k[1]} k2=\{sbr.k[2]} kx0=\{sbr.kx[0]} kx1=\{sbr.kx[1]} m0=\{sbr.m[0]} m1=\{sbr.m[1]} nmaster=\{sbr.n_master} n0=\{sbr.n[0]} n1=\{sbr.n[1]} nq=\{sbr.n_q} nlim=\{sbr.n_lim} npatch=\{sbr.num_patches} sr=\{sbr.sample_rate}",
  )
  let mut fm = "FMASTER"
  for i in 0..<=sbr.n_master {
    fm = fm + " \{sbr.f_master[i]}"
  }
  lines.push(fm)
  let mut ftl = "FTLOW"
  for i in 0..<=sbr.n[0] {
    ftl = ftl + " \{sbr.f_tablelow[i]}"
  }
  lines.push(ftl)
  let mut fth = "FTHIGH"
  for i in 0..<=sbr.n[1] {
    fth = fth + " \{sbr.f_tablehigh[i]}"
  }
  lines.push(fth)
  let mut ftn = "FTNOISE"
  for i in 0..<=sbr.n_q {
    ftn = ftn + " \{sbr.f_tablenoise[i]}"
  }
  lines.push(ftn)
  let mut ftlim = "FTLIM"
  for i in 0..<=sbr.n_lim {
    ftlim = ftlim + " \{sbr.f_tablelim[i]}"
  }
  lines.push(ftlim)
  let mut pn = "PATCHN"
  for i in 0..<sbr.num_patches {
    pn = pn + " \{sbr.patch_num_subbands[i]}"
  }
  lines.push(pn)
  let mut ps = "PATCHS"
  for i in 0..<sbr.num_patches {
    ps = ps + " \{sbr.patch_start_subband[i]}"
  }
  lines.push(ps)
  for ch in 0..<nch {
    let d = sbr.data[ch]
    lines.push(
      "CH\{ch} class=\{d.bs_frame_class} nenv=\{d.bs_num_env} amp=\{d.bs_amp_res} nnoise=\{d.bs_num_noise} ea0=\{d.e_a[0]} ea1=\{d.e_a[1]} told=\{d.t_env_num_env_old}",
    )
    let mut te = "TENV"
    for i in 0..<=d.bs_num_env {
      te = te + " \{d.t_env[i]}"
    }
    lines.push(te)
    let mut tq = "TQ"
    for i in 0..<=d.bs_num_noise {
      tq = tq + " \{d.t_q[i]}"
    }
    lines.push(tq)
    let mut fr = "FREQRES"
    for i in 1..<=d.bs_num_env {
      fr = fr + " \{d.bs_freq_res[i]}"
    }
    lines.push(fr)
    let mut de = "DFENV"
    for i in 0..<d.bs_num_env {
      de = de + " \{d.bs_df_env[i]}"
    }
    lines.push(de)
    let mut dn = "DFNOISE"
    for i in 0..<d.bs_num_noise {
      dn = dn + " \{d.bs_df_noise[i]}"
    }
    lines.push(dn)
    let mut iv = "INVF"
    for i in 0..<sbr.n_q {
      iv = iv + " \{d.bs_invf_mode[0][i]}"
    }
    lines.push(iv)
    for e in 1..<=d.bs_num_env {
      let mut eq = "ENVQ\{e}"
      for i in 0..<sbr.n[d.bs_freq_res[e]] {
        eq = eq + " \{d.env_facs_q[e * 48 + i]}"
      }
      lines.push(eq)
    }
    for e in 1..<=d.bs_num_noise {
      let mut nq = "NOISEQ\{e}"
      for i in 0..<sbr.n_q {
        nq = nq + " \{d.noise_facs_q[e * 5 + i]}"
      }
      lines.push(nq)
    }
    let mut harm = "HARM flag=\{d.bs_add_harmonic_flag} bits"
    for i in 0..<sbr.n[1] {
      harm = harm + " \{d.bs_add_harmonic[i]}"
    }
    lines.push(harm)
  }
  lines
}

///|
test "sbr_mono48: SBR syntax matches the instrumented FFmpeg decoder" {
  let data = @libavutil.av_base64_decode(sbr_mono48_adts_b64, 16384).unwrap()
  let header = ff_adts_header_parse_buf(data).unwrap()
  let config = new_mpeg4_audio_config()
  config.object_type = 2
  config.sampling_index = header.sampling_index
  config.sample_rate = header.sample_rate
  config.chan_config = header.chan_config
  config.channels = header.chan_config
  config.frame_length = 1024
  config.sbr = -1
  config.ps = -1
  let ch = if header.chan_config == 3 { 3 } else { header.chan_config }
  let dec = new_aac_decoder(config, ch)
  let mut pos = 0
  let mut block = 0
  while pos < data.length() {
    let hdr = ff_adts_header_parse_buf(
      data.clamped_view(start=pos, end=pos + av_aac_adts_header_size).to_owned(),
    ).unwrap()
    let end = pos + hdr.frame_length
    let payload_start = pos +
      av_aac_adts_header_size +
      (if hdr.crc_absent == 0 { 2 } else { 0 })
    let payload = data.clamped_view(start=payload_start, end~).to_owned()
    ignore(dec.decode_frame(payload).unwrap())
    let got : Array[String] = []
    // serialize SBR states in element decode order (SCE before CPE)
    if header.chan_config == 3 {
      match dec.sbr_states.get(0 * 32 + 0 * 2) {
        Some(sbr) =>
          for line in sbr_mono48_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
      match dec.sbr_states.get(1 * 32 + 0 * 2) {
        Some(sbr) =>
          for line in sbr_mono48_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
    } else {
      match dec.sbr_states.get(0 * 32 + 0 * 2) {
        Some(sbr) =>
          for line in sbr_mono48_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
    }
    let want = sbr_mono48_expected[block]
    assert_eq(got.length(), want.length())
    for i in 0..<want.length() {
      if got[i] != want[i] {
        println(
          "frame \{block} line \{i}:\n  want: \{want[i]}\n  got : \{got[i]}",
        )
        fail("syntax mismatch")
      }
    }
    block = block + 1
    pos = end
  }
  assert_eq(block, sbr_mono48_expected.length())
}
