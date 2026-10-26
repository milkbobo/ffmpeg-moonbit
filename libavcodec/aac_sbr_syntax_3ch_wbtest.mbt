///|
/// SBR syntax-layer bit-exactness against the instrumented FFmpeg 9.0.2
/// decoder dump (`_build/sbr_work`, `instrument_sbr.py`): every parsed
/// field of every frame of `sbr_3ch.aac` must match. Post-apply fields
/// (bw_array, f_indexnoise/sine, Ypos) are excluded. LGPL-2.1-or-later.
/// Stream: docker linuxserver/ffmpeg:9.0.2 + libfdk_aac -profile:a aac_he.
let sbr_3ch_adts_b64 : Bytes = b"//FgwGACAAFAQoCjVv2gnAgAAAAABwEIiigAooAKN2/aCehAAAAAAAODAABgb/8QpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpd/+IUtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0u+kEKWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpcH//FgwGACAADin5g/N/m/zf5PRPbvSw//tRX8sWljsAZ0y0Usq4Cf2Y+jpP4Xd9IYHUE4fACeX42T7F2klwTVkOr9YIcg2BDR6IhpcyQyOBI5DeEOBYT4HrMgGDarZnJgAZ8AQaqdSVkEhEjkRIsd5AQbcBapSaykBwbdh1nHIOf1TlRvCKx+PXHyHeuBhyAiWB9DTIHiedAyeP5rfPG0yAolhOHMJzZpOU4AAAAg9mBGoaDZxSKyfHd3bxqF3K9qkyPmrBSXBdgu5+ODJTCN+pL3hpOVA1XbiZTN2YRoLoQpMULKlIjKKTYLJi6jpUS58khC0Z0kTAutS81EWhJRk2kfrn0q0E0WLKiLFR4zgiuKMqCmRBCKiiU2KKhlZS67lmDL4uEDdZqhBgLNcESA0eSSD5/B4XrVZgwM8h/9uXcmr+PncPM1AF7koAlaFlwU+hIQJf3ciNOBSf3XykvIyEPuPJxvPSZJRFQKa/09h48D1X3XnUzploempPPdCLfK6olySt4+DlYPaXUXqH9f+3w5tT6Dcf7v0/6nbovku2a1DZwKEDU4bMfJg5mDkwlTi/KUUSi00KOxFf5J8FLioJKwddw/J58mD0T+VvDtz+gAAABkj7fY4yIAgAAAfokFllYf10AAAAl4O2BDK5QgvAEdIUjWLKOgIZnphEJ/MbcXUIvqPlu9pRbo+0xETBokN3grQnAfvW0s90KSyv33Fcxk1B4xwudjx7RJH30/7H3DKC9LkCg2XWAJWF+St0WiHys7V7y2hQQfat4qYAAAGfQKAAAAAAAIRFFABRQAUatIXAAAAAAAAAADfDCFLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0v//FgwGACAAE29S/rFuBKJZdWuguq0okiVBJoOB09KhiJEYbbprWJeGFYTgBqAK/8oyqDzzjTAg4XO7/qX6fxlvOToTKoK1V8R4vlvEftfUNUb47c5lWdr2ODmrY32ZV2TxdDPlpMwJHexSLxVqDnHEdH/xas/31Fev++G2KOQvO9hcxY53lyhxf2Doz2j6lsrsPhQ/hO5KU0V644/KNFc61/G2I3zLYNz938actffdK7o5w+v9Y9QK/zOdiaIvvpPrrqBFI1ij/J9CYICP6a8H3NH0qh5vkDtegBTZ/o4dpuCXcCv+L6DB05fpPHmbVEa5Y+V5ekaigwXWtP6ytIE/h+X9Y8S6aiqh+rnHi1JdZ8Var+4bm8Q7y4UGw98dWdiRl1/IYNh7WwmMeCdG/V/hcMr76zsj/Db8M2dTsx9IuHOBIAvu1KtWaOM7oFB8ozdqS5e5c25Jx1xTrTLfRuRM4fqOA7H408E7r6r4jTlw8WT8ORKtaMW/PNz6R4rmLcf5k+iugXa/3C85UH68zWH9I3GO+PruwO9Ji2fZF588Zo/3+01gH721Ur0lBdd3op5Z5u60vHdvLmffW/FN1Z42Ur3MLCIx2/oDXr322BaJ++zHMOMsQOiIFmfruR9PzF8Hz6usQGOLm4Z8Fl+hARw2JSHjjih36Ir7nHp3yLtLznbviWquaPLL57f3LEc1fnuU8soJQD4J9RfvZHE+1YzvH/JivJHfixkuFeX6qtANmA0N9SsvuGju3Zg0ft7VuacU4BYPqfzFOxTWHh8ZT353YW0mnMN7fxOfXJTHFd3gkHqdG231zrv2Yr/vvT/xWUui9iHp4591z/36W3NpGkPy9zaacNK1sFT2dHPfvnGAAjBj+xaDBNYtcddDUr2V5HlrnT4LqnKfjHu+IUvM4QAAAAAAAAAA3gWi8kk1QAACMLEsrNtEo+YAQiKKACigAo16QiAAAAAAGhgAABvExClpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpcH//FgwGACAAE4NS/rSOA6dr4XQXvVS8tKuohAt0BAxM6BOVIOdR5HaJtnUWjLUJnP2n2hB2xd4cgjnQE7D7gqILgYrvDy37zp/SWq/z/wnzv+rS/pddioMd2g9AqYHqGkPgI6bFtaoro+dsgTiV75xXjXFaZkmv4JwaC/TZUBtXe38fQn1D5LBBZUF0VBduVGB1fba1H6xUAuJ/85x+Hq2lOb5OJaAd99Jee4EPN/lfPWYug63JhvJnPGlfy2vvFsvfjOn9tLY823J4PggKzDv/vq2eI0ESNpnHs3HXc/InF2O9Qvm6h3rszxH5qZQfIev2zUiWuvegbZpegw4coXvypz1P4eaNq9W/nmiiQ/I/kYwx4HtT+7sHifa+eqwJQpIo4Yr7F0TGcwb6mPyOdzYvgAJBj6XwWX2jVHK9VTsD0npq8toeWc36b6rrsXoe2c6+dcBxfk2dSd3dFVRO4dU5Rn0faah0xrb421g2aHVPorFvCC7o3j2JuvyJL0BLYpRB8zLBLavr4ay9m/Wvx94fzWiHzL56fQ+54ZVv2Zwz6HmzJF0A+SIiBmPki+rSD+p6u+hoIN+m76HWHpnbV5795JuoFkdV7+tIOw3R2Wdtqr/JM4yX45sGsQc3+gL/FrSB5N3rr63gai6boyB6o+8ch599jIFB5ZvDKXzHsvFir10rTsPsaVRf9/8LWDxbxtTmAAqctwVOD87tuqMJjVwZbjTtHF+SbBzeLStng/70If1Hw+qO8qiHxm6TjxMfyWe5GT6Y/f0vMcd1GLl3FyARSXxfMbafD4/Aw/ekdepUADWTT2HBcggj/Y+0/sMB5e46G7R/TPqHfmka0BawZeLq7kP5G0RfvetFe7w865y0bIcP//PTeh8v/M4RFqTmUNlYGTq2nad2ywZtiOUsM9roojRhm4PUtIXySCHsIr/HD9aZDBVWTBxuAAAAAAAAAAG7TQp69T/QmJvTJW0DMACERRQAUUAFGrSFwAAAAAAAAAA2iFLS0tLS0tLS0tLS0v//FgwGACAAFANS/rTg4JVqvQdbqXz0JVlXSEGIcz2oTQ/ffSUXyjKp59F5iRAT/HkrkvVvFmqe8+sN1VKPim0QZCJ/tzH+h+r1llLF/NcVyzHH6ya7oiPvPo6jDIU5lkEieH7FpjmInvx0UDX7r5ky7uibYF8jcH0ZzOMaVdyVv6mX3KI8EB+n11WQKWlBG0Ih+LlsWAk59zXlKyKf0r7tKxOmf6/3bkr7F8npd3SD+N2hxvzdiesJXB61yzvWxRUe2nzmncek/ffbeHfqOX+182extrmuS63F7GjdeovFcycUw7dEief9VuSvsy9xfr844IP9Jw3sun/TKEB1TyTeemtzZbxTTW+Of3fWAf2sqD+m4v1bmLpDLGlPs9s/A7j+A39B7EByb/vtbWe8I6/C8u+e7huVokPjX5i87Cj/ZmvMS8i+C0X6H1RQw7B1dzVAb7/09TViHpTlLt7vFqzd1vMMYi+yZK0fxf9x5LrUGWuL7vDm/szWDl8z7x+uY7m3iiY/CcotfRmh/Etm9+yF2TlqDLVKZxoMuo8u7QqQPaX7nNc9/dZQBE5SFl6eMsZFpjSFzwLonuVx5/6o4vlEHjOH3F2/JdVSFv+1wMXouIb0kWjaZ/ifq+KvTu1083d9+BPfGLr3HGXTHXuRPqehefdI5khdyTnuJz7/5Q036/pTsDimnf5Nwc+78vTm7Xu9uZsuSM3JbDSeh/afWMT+w9ldVfy5/Y8v+wcs3DI/1DRnLvgWkvw3TU2ueyNaeD899LWFraeeZ75z3zlDuqtcfX/7b+yl0jUxOS9oRjSslqGK5uxPpjLvssLis2fkrwsqdg9RWAd1z6Bn12/Nu48PSmEWXlGwMxcZJKILzd87v3zmF55kbd/pnVMK2RRrFv2YlbL3HvxCH0f8SAAAAAAAAAAG8C0wOSTGq8VQiAhE7JGAsgACERRQAUUAFGvSFQAAAAAADAAAAN4uIUtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS8//FgwGACAAE8NS/rOjgtQ4qFil3QSBqlC0QZn+35roYXWcDvmoyWOTYtiju0Nk4p3l/Y9wqqnJcHPhs6ErE9bo6X26TEj8HbX1Ls5wXDt+F8WcWXjk8f+9DAa+MvXm/WQGqSf5CYtCSzGLrZPm8k4ZmvoLNv5HmNhj2QqZ8z+z8t7EE4ukaXgWF1nx7V/hO+mH4G88c9ptruee59BRIcnCkHQPTlv80kAPbHb1GfBOX5jlOtQ1EGQPgPLfMONbx4+lkfHtz9PfE7A/WXWKJ7o+0ZI+o1CDt3TH0GRcKugWXpJubLukrx+/bdyoPKWOfE956gbNBjjLMfYHI/0qlJ8J+jruwfseUKAHSP3aQPI8Rx8Cna9YfmGOfA9N/dlC1Qw3m+Q5WP9h4ua+ftmY/TzBreb4ZP4f1Ow9csPF3LHGuYpTBmj5Pl7QdVQ7vrvn6/4JlC1Q9+7c+i/U4TJWc9GNi9MpZomYeN8O584L27zrb4e8enIVTHfnpGCA6h58z/ytPoPwv+35mkuSrn/CRrWA7ikPU+j4Bn371o9wZDD2JX0sIoUWx/z3Z/bfROyqmDIvpzgp2oA0ECe/eWxxOeO8I76fyl1lsn67onEdq8N7pzRorn3f20crA2H+Uu8PG/6+Jdld89SdY1TGHBeoObK4D3RZeyu39WZYkTvLCedeSpCgmWq3D2xBB8zaY5P4uQ7Osr2P2iVA8k6Swn5nqzTM36Q8Xx149woIzjzrWR8VqAGdx2kHa2I+u7N1v9/zBzht67huRHrv/plrvH0ua5qlAGFd4b89Y7Rb3pErA25yPa4up93ewsXmGcoFAHC3pCpXwTD9qfd6mBAqFDyO5K4B1V3R2vRQukOIQJag/KvGzb6ssQfgihJgMzcayH1xmjkN817IPiEdCWoCLTxo+H4b3BxPaXNkF7NkCmQAAAAAAAAAA3gOmBySX1RtAQ6LMBsUZUABCIooAKKACjVpC4AAAAAAAAAAbwkQpaWlpaWlpaWlpaWlpaWlpaWlpaWlpe//FgwGACAAE8NS/rXZqEmNXSwi80b6yC5loCQjRd743qUnHnt/Q9SCqMnBMmlrgXWXVOFdw4ToX8Lp3yv1/ivnSogMFDj7X/W6pnQXO+68NlEvLx3cGmOW9J1mLKfRzpxekeZbfFlW+Q0cnnGK0e+qq+H6a3jZPSWM1XGnWG5c7klkvrmmeXE3XPQ/JW69dj+T0ECTxZg4f72KkAC9A7801mrHNfcm9d8oasuK3Af3O2OUvEd/tnkORekYBcTZlImo64NuV+rO7vG9m21doOs+yKKB5y59yfTtnf6Z0BZP5918S90p6N+A/ntxR91/a2ubB874vvToPmCzw0dqDcH270Bb1TboIJkj/eZyYnrX8TeuqPQL67B/Pc/cibw56mP+Frn7/e/yckpMP9nO8Snn+b/t4jr7ZUf7E+od1/Ea5/K9vWMPJwOZNH9h/bPnObeGsDq+HufI1GZ4/x+t6h1qNyz0I8cB7m3r5z+d2rjvMfk278HEemDTu39K4n6NpSdw3CLVXNi1zRsBajWQSIAejetZ+3fMotictdP/AxvmfOeEeAdy/f+POLJB0OiznyTPVP6rlUlN3PojUdvh+kbN9IjLJbX8B6NVctA7Wjb4ensydA8C8szJ/QrcGxPLLx4JUQN1Xnltq1DmT4jzaaeN8sn/xT6/3mUXYMXyPSmx/zKelAPjH3H//fkXd/4fpubu5oP5HfHVMk/yeY+F9Kt4U+B+L07V74zLMOrNeepxsmcfZXcUZZ75I5Be6z2kw6PjKtRbEy7YEZert7uDul1bf8CpOjuPchD2p+vc/ivnGe/2mpvqmrYbzv3JYgPxNg694o3phnUGK9HfC9DdYyJ6FnzZlMzm4t+XSR/7d15YfGWMzHxPwSQaHDnQGf+aO1PSM51/4j7FhNs+1Z88F5h1aAAAAAAAAAAG8B0wOSS/KKEaaW2VoAorGAIRFFABRQAUa9IVAAAAAAAMAAAA3iQhS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS8//FgwGACAAEyNS/rQWiGacFWKriscJkXS6AQYWEUAGtA+x9uf18mg3NP5bXCQCHiuQPgNcXuiqcr4osmCA3N41+oICV9v5I7l5d3ZvL+huLav9C8IPbwPo/unZ3K2ZuzpMBeeSqfubBJpHZQaBLHPIsi4h2HrOkNcVubxjvjp75TFmKiB7S+p7hpp+/uc7Atdf/gQAh8VgHS/3biNVZ/IgD5wSEL3XW2pbFHvL4T2TOoN67K550f0H67z7dYeAeW9yyiP8vnu7QeVN0zeukPwMuCpTrS98vdoyFv3y3KoOf+KfDp8Kc/N1P4bbFe5R1/puG9ylbcwcSp2FWo+PnX7BlQWxad/dc45ADw/oHi+w809ZyPxb2R+doy2aiBNecO44ZEN2V2CSY4/5ctO5jp/hQbQ9YP/VfBeNtT/P/WsQbUvg3hsXePDuXfynScZqlw7bWIsyRHSMZ9O/Rfx4/l8VM4vJoH7/G5s+Cb9ec09J/HXLyOq9E9zSRiGld5a8bsuD4rfTi/F9V1X3blCc9UQfXGjLDvt2RjXv7X7qLkSOtV7A/J3WK++jZ0BTGVQZ/+5T6DDdIL2rkecdx8t+n+6dTcC9b+yPjKXhO8NbzKD4zozN+6f6llaDiH0vmfjC2fjPJsdfu9/7A8y31dQNFTFKBLmpmVQ8MtvF+iZKzT3l2f4xtSfAQHgFZg2a7KYsLabqg+oesPLe/MHBEuXOfvt76jOkrh9F0XPbHSn6eA5Gp23gcZfas9+Tek5g0ZtnT8a7QpGH90yeShT705+6qvdU2JzvN5yhAdU5Q7v7XWLInn7LMg9Ux9mTOFHS+H3XjPhB636A4blnRvG2YawBWAu8W91Cd4Z0nsiYIw5+h/a9hdXoKgBy7+ZPEV1s45UDteO9pXPqK7AfoRDzxW8brQGR9nOa8PBrY+XAAAAAAAAAADXpDG8oNag1mkMSABCIooAKKACjVpC4AAAAAAAAAAbxAQpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaXg//FgwGACAAE4NS/raRboysvVSuKTGhdJV1rLIFakJtH/m1Tz9wezS0pYoJkHeNuC/R85uP0mZgVgCUhcbc45n7K+tYp2V3TXKqhX5yy5WJsD/cJNJfdh/vbJzVv6oA5Z6g9Kx36zggNdT8KfsYTiXvF+fJw61HGeNcfXh3T2/xtYcop4t6r5ff9EBxC3w6J//0fdXXqQ9d48bdP9kbQ9X/X/Ax7q2WgXD7DpN+b20xQYdxZWJ7h8LkI+odmsO7czzz8lQJeTpg5p7W6UiVAAyJyz8HxK54hbN8jEBApXWPKbh1XfVVeqdg6rm7O4Njfknepdh+7kQh2DeGjfpvNfNt42THmneKVET9t7TR8nC0V0tiv02Xw8edA8veI81/acN27cfptVkRD6r41jNW+W5odHjip961Jur3Tb/6eO6tS3lcWPg51FXneHPbmnQPRnm0mCbkfxHVnef3XjyI5q/1b+3DKA+zFTlrsHxPXnHmUOAcZU/y9LoujGK+0W/vTegdF1oCG/i3N1txG4dE7Mwjyi+kGvMfh+l1ODCtGExkoIOY93ZXDjjtLE6t+Cwc6XVltuNwvvbjV1O3cbVHWXNnxPIvc3NUwf1PquhO4bKscn57Lc01TZhM1Zo/I9D+geM9YKXyqxncV5c0OXKfeT54b96m6MfALTC5MO7ymvyWUPeaxnUc+g7y3j6NbgJH9g67zbyRlHX02df8Xzb6noVs7JxK5u+N3zA/ZaBB4TMoPWug9pZKogytWROXft/+f6h1GtcbU7nnyt1bL2/riQLZ4HmTKEwWV0329STPy2dQcH7uy765H2w+8c8SeDKgrJ5vn8Gz9B/zcw2T0z3HvnXnnHVdxc6R38zmDazlrUmTkPusg644p9lfHa0K5JyCPOe/Rd8dudY8Zej7y1zeOK2YDM+G+AdIcbS6TI3xQAAAAAAAAAAaNB/IDMGg0AAIRFFABRQAUa9IVAAAAAAAMAAAA3hwhS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLw//FgwGACAAE0NS/rE1A0pUlapLo1KIJMkgZ0gRCszyqmoy4ErHgKAT6Z2329j4VnJbG8rY796x+70/11991Z9TnQ9EkugGCl+G+uVkDmPnz6trTJ4sADsbqHuqgSdgab1r+/+x6rs4GkNvY+ET5+Ki22mSbaR0m0+i/5fEeG/a4p07bHPO79i1XI173WC+Prufc550HR02/1VO2dnNjHWvsodW+x6y1tm6bKHBrXZ8ygueqr5+pzTrSv/WP2Md9ybjwnYXal5/E/EYYl/I/lmvcdSgR9+eoKXgDtPad51tK2eaPa8M6NzfUAONp45z6B560ZeeAhkaSf1MZfuuI0CHsiXgSHwbX+1vwWuuhmOTxXxBJ0DmaDdB1bTH3/kju3Ml2A0Xov7HQYmvgf17uz6mXwzUGQQOG2YxxfjbrOK/ntmfNa++r5blYXmOeowgkU5ExTcbdsK3BfR7S0rYP4Y62fSoH++lkGwfmd9n/yvh/Wefqf6XjbHwebNfxjfrfL1rx52rrfpmUwYtcWqNqfqPiux9V+BS6IiEH4f+en5Eoo9RB9q2zDXvdnFWU79+bxK9scduQW8tXub5HSfGufrVDRmx25awPoPyW3yYxdb9V8Ufd97tz1p8YKLd+tfTe6OC+uyBrP6nvzmCRuIScX0XEaJHyTnDTWIaK3XnvTCxSG8DvdnxX9N8+S/G4bXyJzY407/vqXtXHam1uj2B1d4+GwJ04j9SjOAQXMNBApSw+/3zfG890rUXkH3TFPp7l7W8Djq+0HVkKxznUPGnGO/8i/j/i/C58jeWgq+mulJt6T8Y139Tez9UzwJNL1jG0yRW24JIfeXZdtecaE5dvLp+iS4TlnkeA5++34ri1AD9AxTiXluIWILy717t6btkcY7L2nnnNvd7Vx4rcZcVXhXBAAAAAAAAAAA1aDOUbVoNEYCAABCIooAKKACjVpC4AAAAAAAAAAbxkQpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaXg//FgwGACAAE2NS/rJostKNbjQhSxJEy0oY8Vr37xboSI0XSDHpp9DzBQRPmfwva1ik57766a+o/d/jFmoS2H+qwQex9IT4GjrFN1+Xh6rqInG7guesh6N8R4UduCt4ON1/zFY4/PnRXIK31ZLT5LqL+vvLt+TR8YPvTOf8pO/5PoSnuOh7Avaw81/i5nK+MEB0PVtP6vatQ9J8vzH1Tseiw/l5xq7HEK9A0O6ftnmerbeFYwO0/o/uP4GRcrg4w+6T+PXNGd4bo/PH+N+xaIB/fuCwrZifxkNzy/OEBjwOjsLzRQAub8dc7SwPSeQx4hmDLGO+q9gVwLVni23ovOOe/pGZ886nkHlWe5Ipda7txkY0SPota/Po7n7g7Oy39yxzmTq/p/v5/e/+g3ZGUOrku0fROuvXJu1vcbYjuG7B7D10r6N42/O1/yjzjzRhXGeY9LR+tcKLsvZH1/LTfcHa1JK9TCwYWRPwPUFEA433TnPDlnyrb2O+qapzP3Vm38DqfrW0QdUcaaY41qAPVOfLg5V+M2F1n2tfWr/Jdl3QDQvrEpAcEsi2lvTBwWVxgt9kTHPPHn+fliXTaEsQW0Okdn9kcu611ZWYM3d+/A9rSsG0A8vXMu8CsC+fqN2iqUVy6z9imQP+GYdossp/z+D/Dcn+6eKUnI1iAkR2/re4Oy/CzKGL6fl6AWiDeizMfoU2c5CHtU3Li9laU03liacxr+6exPRc1fEViB3wX8Jo3rqqu/eHff/83TfNkZ5v716m0LHfllhvnplUxzhO9XXz/9x7e+46fPMrhwrP9lwvrckEHRkiO/bX+3d8hxvzXrPX8bSM+ee57nQHuXcG1Mx9l/SuuH9dgVP0Tcir9zvZw9o4rZ4JWFo3RNx5w1zy92nR3SvJz48m7A+CprQ985Qj+wfE6XcXNQAAAAAAAAAAbd+0E4NZRgI0NEbQcAAhEUUAFFABRu37QT0IAAAAAABoYAAMDeFiFLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0vA//FgwGACAAE0NS/rFl2MRwEkpaCrXUJWh9OJpLUKf6tAvIIISCKfhxxiVZi9T1aSGPjDiy6RVkDq4Vq/sdram2JeGcCAAEymd/y9iEttp2taBO6Pvvr12BqMneXtmgecNj57qP1rpG6cAQ0MyhQP/eu9nZlmVQ5PB6VZJ3lbomleB0/F7FDtSM+VP55aDRYPpUsgbvGc+E3P0b2XVeX5SFnDoboryHMdaCzZRY+mNp5n+c9+2uFDV2atIdgZABXAu1/snE/QuZs9MfhlSi/ZfPdELPVTR/XepLa888Myxr/cek5Kz2x0UXNXrsw61zPLA4duv2Ouxf7UZcmXLCzL51L4vi3/uPEdGSDckeQ/5COOuseGyThn2rMX2rvzs3vGF/MW1bfYUh8dFLIv2Js2HrFwZ1F4BlQPKOWOTFqoAPOtv43P6jpnzvpfoSphxhM4uH+m83/M8uWoL/bZexcRnncWZswx1hUixbtH7Z4nm6Op664+H927k9/v3Wvm+ZuntvuybramzCs36Bqxrz1c2muS76jn4Ol6a7r/28qoouDEpNx/7cV9P9Hbm+O6cS3h0HbgJmBaIohlmn/2/PN40AA82n70N4tq/OF3hxz6Ih+imUNZA7XxkhdHd+a78i1TdgPXMxfkoDqL4OhA9XWkGfA3Ht2yrg8+8b78+s8B996/WosU17dYItzfsLtL2HBict7M4s7f+Z7xfmYIFXYnBrdv9k8a8U/ycmesYMD2CzA603Shdna08+wV5LgOh6dnqYtnzOCpiU9z/zFmjJX9+4cWzV8vTGeroHrrom6gJY7UO53R/Pbevup+C8Q+I60+pdAdVZh9Z5Xp35aO+rPBlOrplF7D3/xfxTmmMJJ4i+N2Z7TbKvmjar6ow7QuZXHydof67AJE4Z1nlLvqVSaGcrc9hnYU44lWIIIAAAAAAAAAAGrQbyhoTCyBqpAAIRFFABRQAUatIXAAAAAAAAAADeICFLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS8//FgwGACAAE2NS/rI1oUumi2JolJUhKsuglkNcjycaZQ5BPKhulfYNExhlYHOUdd15o4o3tPgLBrcPZXRnRmQB9pVKN81kGpmWKDAB6vheptXcKDx/PnNX53t6ZQMEHzhs7nqVQ/kc15UskeLS+ET0pEKTTdV92WB5dN353cVEBx6PcXN33P1DTP3TTffvZvZdCkp367j0cmB484b591Hv2iydqYzs/gf1zkhQ/xt0CloTrvVf0dt/7N7UWy898S4xUp71fHX2uXg/kHDxp4apbr+ItYv36oSc2tiXjetbz5r3j+n40n41UTf4ZKoKkLnvUUx26HIQvaOW9m2w/sy+0eO8kLdt8rfnPyGEuTcFpg/Ff8pZB83jvkO/OadyNvR+9cHIqNMO5L7h/CyTggJ54HoVJiFaAnmlLOBsCNOKsN8Z2c5dSUnLR7h5n0xc8h8edDdOQ6/qHI/LfNfDfsdlb30RVtU7zz15NxHoy3BeNTFyn+KSeR+A9U605K0v3X3jJG/aBBT/O2r8gi63r+tQ4n6XcHgmsmx7o2NX76UMp8T7J75k4mDh+E3h6RvX5r8vl/KNIVKDVFV8y6Kw7DdudUbF6X6Tsnj2cauyVD57VpfBqn9O5vFn18z0X5FyrrfhvyMAVcUvvev7bp3U+XrzrgWlOmLglsfTfa+qfXpE8BmDymnMOxxQQOlPgfsv1AiENcA6/5dcfpm5eUf+jY3tz5sImQPTeZagDJej45n0HMO763BkMPCFbWqYpwWaObRmrWLqH3SHjfvdGcQ7/65nrMN96TjwkINSA7Knm5Ot1XzLt371ohuaP19/hR8NetueDfuLXDUZOAfB0dA9DSFYfsmy3Fs/qqfg26HVOx/tWaJv+W2q6/m70kLoXNPZGScwpb1pXTH3HRlweGdN6xynyCb9y5fPcx+H/fAAAAAAAAAAA06DeUAC1oAaoAEIiigAooAKNekKgAAAAAAGAAAAbw8QpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpe//FgwGACAAE0NS/rLL4UCxxy0VEjJJdLpIPL7AmcF3qwNMzJ3xm/6lWw+u/qP6+6A/iahTlU1MczWiGTh0QL5DLv/1//kvJLRDQqPE6xRzP3f8Dt+e90WsSsC3exp7FxCoQdZVkDPNVVAO3NwTpZqiw/ite1ADpmINm2t5Q2LUQLridAdb8aXj1x4zZwZCywJMfiGtqhD0bx9kMEmhzU63B6pyxU4bpH+lsjCJaBANpsM7g0Nyj0XPHZPEPF7dC36JHbpNdbIzk//ZtxTIjcMmCqANgcVeOdqatKlMOI8ndg3AsOP5/RNKfYeYNqbRV+7IjyzyGA+Afqzu7P7vWebN/yHu7BR613r0mJlrwzMNbC526EqQNlU5K4POryyAT7D61qZijzmDMfIMxUWDrazjUl9k/O8+bLqjnbF+0M244ht5ZjceotR8Ozn0D9199e0cwL9rUIKAHvSGbMkHmLFd6tWzNvz4X7p2lt7yv/04/JoR3Vb4OjNFRz6DEF3jFy5d5/rAOhVejP1WiKZUcfikLb2XPcOB/iN+7phVcl7yyL1p61oSqfr+ULmVe0eY+g/zsw2aDRcnji39Dprxiq6kBPGyN66Z+GswDF5x8p9rwrcWr9vzoD/rofHoqUy/sZ0VuDCrrHSnJf333l9Q2XRappP2eePAfD5mBZXInhtXVR0X8xsLMBMQvAeTK1BsHcfjPCh7juovg3IHFzB0fUIOiYt+f82/F6j8j6GxSigb57fxXMD72L9/hfsOeuKJ2A/e/abjP95WoPhu6lLbY1+4dek0PG1NbZwwiEG3e7NIdM1CB+c8Ub5X3D3hTtWZr650f1naQtSaiocOOdwdDc38U/WKezbqHojh+Dg7Of/S8l0x0/590zbfLvgj+wzNsiZb7SlwFeT6W4t2a+/E0WLwsW424yddsR9h214dMwcuXQH/4AAAAAAAAAAGrQZyjaEMkNCwgAIRFFABRQAUatIXAAAAAAAAAADeDiFLS0tLS0tLS0tLS0tLS0tLS0tLS8//FgwGACAAEyNS/rBF0uHnFVxzqIVaUmipKoEiQiaj1CDO6iYkEgH+b7PzfYwIjb4SQwck0KPp7EpSDSlRA9G6ypkzuPnrtLW1hW6DfTg19mb/Pu1iqi/+Kco95UzuiZA5z5p9F+3Qgkwdn8gqaJ3b1h0NIVoA85nQVhyuD7Thv3WwezPrWqpfHCyBh+kyPz7SEP8x1rJo+evGIvwb+7w7mKHdGd5eR9x+P/d9FqXyHTHUvQVH3Mp5a/+5euguzqVgmxfINz6ajLRGze6LFN+W1hqL68oRjmWQKjFLYbSH5Bz99o8Bb/i/5aiiUlZL4l4UAV9S6dv3//uwPR1JZc+CgnyvCi801Uo7e1j1s67RBxvs7kaCwRqbfgv/n3cL1L6/zNAeyPHPi+lIZsK6BZsqQXp2/fu/6qw8sz3JoutdB/K48FmSbLoFsqWB82zZmzv+8rivnLEScfql0jyz0587PHVPj20vCe9/m8T1FsSoSx1IyxmCuhYatQaB4XBGz4zxpl5zfa5WLGsyBjLojf2h768h+Qw+2v43D7LmHjbYXOf0/wb8NcCslkPin9zOw+PHR5v+8oEtPf1/gJbEQAFZqYv6izAprSJc2i72/F234r9s8a+ckYHRUIY69K14wWzo70zS3lujP1XNPcXLxIAdyOHRtXYTzzZNajyaXhBd/tGSePdm+ZfVJSFxP+5jj2qLf2N5d+5e2m79V92ToL5z9LbPz3Xfj0rC0C0RTD+23NkiY3w4dYVOLFv0eX+j9yaM9AznyvsbPmh+W+so37t7Ut8ORt+8rZBFonrvCrTK/ObvUej/v3/TY9O+sYVhdOfEdx96y8LR3s3gu0KgDQwuR8ybi78/UZ7yhZGWaLR9ZavxGiK6DsDofa3iM5xzF8O7Hh3w+vexc3bjyzHGbIPuTm/pXg2CBSbXdVKdw/AAAAAAAAAAABp0G8oAQGCZgAAIRFFABRQAUa9IVAAAAAAAMAAAA3hYhS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLw//FgwGACAAE0NSy0axUyIWFFSziqHFcAvAuUXWsujhqa1ttH8AqFU0iIiTxwlRhrQP+v9xwPCSIEyoP47t3orw7t7lv+5KgnzpHqvjUwyWvV3269NjKpZtTnpWl1zLs2f9+k5KeYtSnR/NGQxcI0lBdZfdWGtkaZxqBOdVPcPHosln2g7dGy3Ft2i57TaPvoMibouNE9a4lZsOU+q1ip6pY1n0PWf7rTI1KOqKiu5l4nkuJxuUuNiz5l2mq8DWc5znjsZH2Tw7TVlKn13fX9I1AAfrLwbSuQnbKM0jZU6z2llVKQk3tLmnJqqOAZ6k9TdX4tUCNW4xMutHUxX0MaxzaqjsdBT0n16zRYBtUo8izmI7IvDMr4kalRykaVKfi4qXBekdtwSJxtsildVyC8pNLJe2WntLOYNq644qU/N4/4hoZdpZzJz4LPvRibLv5tttV4qsqMDKjbbU1PFx96r2lv623uCm/Bw5tjazfmPwo/BsC6ra8JLOilsFTouui669HtaNDk6ET5F+LVRlF1OTWy9blPhqSV8GtWuLwkyZFcS5qTqq+pqcncvUo2xvNRsmKCcexrSmXmmrGIXBhqYpdrh4salP2qGG9Y8ScS2ZyvHi3sZlYId6z1HHAel4+bjUUWG7C7qG4AlQJ38gsOlH+dSPuIUk2TyZy07kMxNI9FfjaPv4AAAAAAadB/JgDYSxigACERRQAUUAFGrSFwAAAAAAAAAA35IhS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS8//FgwGACAADmNSy0tkKEIiqQzBxeQVQ1NgLAXeIeAeoQFQV8L2l+z2h634J4/LoPw38XIQLdFKQJPB+U/B/rOaH5oNpuVhs2FwWDrk/SVeljpF6g2CuVDKWzGCv3hu0f7qGfY6ReoG+ZsFayXSx0i9X6Ru+Qz62Y6+VmUtEk2FJHAs5wqOz32rPVRJjXTbZdLRVM7EcCgsRwqC313JUSadBmp+TWgAAAACERRQAUUAFGvSFQAAAAAADAAAAN/+IUtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0u//EKWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaXeKiFLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLw"

///|
let sbr_3ch_expected : Array[Array[String]] = [
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=32 kx1=29 m0=0 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=0",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "BEGIN id_aac=1 nch=2 coupling=1",
    "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=32 kx1=29 m0=0 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=0",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=0",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "BEGIN id_aac=1 nch=2 coupling=1",
    "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 14 14 14", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=1 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=16",
    "TENV 0 5 7 11 17", "TQ 0 5 17", "FREQRES 1 0 0 1", "DFENV 0 0 1 1", "DFNOISE 0 1",
    "INVF 1 1", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "ENVQ2 17 16 16 16 16 15 16",
    "ENVQ3 17 16 15 16 15 16 16", "ENVQ4 16 16 17 16 16 16 17 15 15 15 15 16 15 15",
    "NOISEQ1 7 8", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=3 nenv=3 amp=1 nnoise=2 ea0=-1 ea1=1 told=17",
    "TENV 1 6 10 16", "TQ 1 6 16", "FREQRES 1 0 1", "DFENV 0 1 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 15 17 16 16 16 16 15 15 16 16 16 15 15 16", "ENVQ2 17 15 16 16 16 15 15",
    "ENVQ3 16 16 16 16 15 16 16 16 16 16 16 15 16 15", "NOISEQ1 7 7", "NOISEQ2 7 7",
    "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "BEGIN id_aac=1 nch=2 coupling=1",
    "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=16",
    "TENV 0 4 6 10 16", "TQ 0 4 16", "FREQRES 1 0 0 1", "DFENV 1 0 0 0", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 16 15 18 16 15 15 15 15 15 16 16 15 15 15", "ENVQ2 16 16 16 16 15 15 15",
    "ENVQ3 17 17 17 15 16 16 15", "ENVQ4 17 16 16 16 16 16 16 16 15 16 16 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=16",
    "TENV 0 4 6 10 16", "TQ 0 4 16", "FREQRES 1 0 0 1", "DFENV 0 1 1 1", "DFNOISE 1 1",
    "INVF 1 1", "ENVQ1 17 16 17 16 16 16 16 16 16 16 15 15 15 15", "ENVQ2 15 16 16 16 15 16 15",
    "ENVQ3 16 16 16 16 15 16 15", "ENVQ4 17 17 16 16 15 15 16 16 16 15 15 15 14 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=3 nenv=4 amp=1 nnoise=2 ea0=-1 ea1=1 told=16",
    "TENV 0 4 6 10 16", "TQ 0 4 16", "FREQRES 1 0 0 1", "DFENV 0 1 1 1", "DFNOISE 1 1",
    "INVF 2 1", "ENVQ1 17 17 16 16 16 16 15 15 15 16 15 15 16 15", "ENVQ2 17 15 17 16 16 15 15",
    "ENVQ3 16 16 16 16 16 15 15", "ENVQ4 16 16 16 16 15 15 16 16 15 15 16 15 15 16",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=2 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 6 16", "TQ 0 6 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 16 16 17 16 17 16 15 15 15 15 15 16 15 16", "ENVQ2 16 17 16 16 16 16 15 15 16 15 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 1 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 16 17 16 16 16 16 15 16 16 16 15 15 15 15", "ENVQ2 17 16 16 16 16 16 16 15 16 16 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 0", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 17 16 17 16 15 16 15 15 15 15 15 16 15 15", "ENVQ2 17 16 16 16 16 16 16 16 15 15 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 0 1", "INVF 2 1",
    "ENVQ1 17 16 16 16 16 16 16 16 15 15 15 16 15 15", "ENVQ2 17 16 17 15 16 16 15 16 15 16 16 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 0", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 16 17 16 16 16 16 15 15 16 16 16 16 15 16", "ENVQ2 16 16 16 16 16 16 15 16 15 15 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 16 16 16 16 16 16 16 16 16 15 16 15 16 15", "ENVQ2 16 16 16 16 16 16 16 16 16 16 15 14 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 0", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 17 16 17 16 16 16 16 15 15 15 15 16 16 15", "ENVQ2 16 17 16 16 16 16 15 16 16 16 16 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 16 16 16 16 16 16 16 15 15 15 15 15 15 15", "ENVQ2 17 16 16 16 16 15 16 16 15 16 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 1 1", "DFNOISE 1 1", "INVF 2 1",
    "ENVQ1 17 16 17 16 16 15 16 16 15 16 15 16 16 15", "ENVQ2 17 16 16 16 15 16 16 16 16 16 15 15 15 15",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 1", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
  [
    "BEGIN id_aac=0 nch=1 coupling=0", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=2 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=2 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 40 64", "FTLIM 29 36 45 57 64",
    "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=2 amp=1 nnoise=2 ea0=-1 ea1=-1 told=16",
    "TENV 0 8 16", "TQ 0 8 16", "FREQRES 1 1", "DFENV 0 0", "DFNOISE 1 1", "INVF 1 1",
    "ENVQ1 15 16 16 15 15 16 15 16 15 15 15 15 15 15", "ENVQ2 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 7 7", "NOISEQ2 7 7", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "BEGIN id_aac=1 nch=2 coupling=1", "HDR amp_res_hdr=1 startf=14 stopf=13 xover=0 fscale=1 alter=1 nzb=3 lim_b=2 lim_g=2 ifreq=1 smooth=1",
    "TBL k0=29 k1=64 k2=64 kx0=29 kx1=29 m0=35 m1=35 nmaster=14 n0=7 n1=14 nq=3 nlim=4 npatch=2 sr=32000",
    "FMASTER 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTLOW 29 32 36 40 45 51 57 64",
    "FTHIGH 29 30 32 34 36 38 40 42 45 48 51 54 57 60 64", "FTNOISE 29 36 45 64",
    "FTLIM 29 36 45 57 64", "PATCHN 28 7", "PATCHS 1 21", "CH0 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
    "NOISEQ1 13 13 13", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0", "CH1 class=0 nenv=1 amp=0 nnoise=1 ea0=-1 ea1=-1 told=16",
    "TENV 0 16", "TQ 0 16", "FREQRES 1", "DFENV 0", "DFNOISE 1", "INVF 0 0 0", "ENVQ1 24 24 24 24 24 24 24 24 24 24 24 24 24 24",
    "NOISEQ1 12 12 12", "HARM flag=0 bits 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
  ],
]

///|
fn sbr_3ch_serialize(sbr : AacSbr) -> Array[String] {
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
test "sbr_3ch: SBR syntax matches the instrumented FFmpeg decoder" {
  let data = @libavutil.av_base64_decode(sbr_3ch_adts_b64, 16384).unwrap()
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
          for line in sbr_3ch_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
      match dec.sbr_states.get(1 * 32 + 0 * 2) {
        Some(sbr) =>
          for line in sbr_3ch_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
    } else {
      match dec.sbr_states.get(0 * 32 + 0 * 2) {
        Some(sbr) =>
          for line in sbr_3ch_serialize(sbr) {
            got.push(line)
          }
        None => ()
      }
    }
    let want = sbr_3ch_expected[block]
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
  assert_eq(block, sbr_3ch_expected.length())
}
