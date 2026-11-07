///|
/// S344 follow-up: odd source widths are legal C geometry
/// (AV_CEIL_RSHIFT chroma) - probed after the planar evenness
/// guard was lifted.  All byte-exact.

///|
let swso_422_in_b64 : Bytes = sws_vec_concat([
  b"JjZGVmZ2hpZOXm5+jp6uvnaGlqa2xtbmnq6+zt7u/g7G1ub2BhYmNu7+DiMzQ1NjGys7NC9WUXhzmpVkX4aBm5a9uIeCqaTLxu3ot6XMx+7pEAva1fz3Hhkz",
  b"Lv34Hx9GQWhjMi1UQlQ6TIqcdYdtf2V3tbqgspiqkJXT5cvdw9WuwP4Q9gjh89nrKTshJgweCRtZXkRWPE40UE1KR4+MiYaDc3BtwrKvrKmZlpPo5dXSz8y8",
  b"uQ4L+/j18u/fNDEuHhsdGgpfXFlWRkNAXnKGjUldcXiMoKe7d36Spq3B1emYrMDH2+/2CsbN4fUJECQ45/sPFipDSl4aLjVJXWR4bGuWiFtNeHeVlL+xhHah",
  b"oL6929qtn8rJ5+YEA9bI8+UQDy0s//EcDj49W1ogH0o8Z2aEepBtg212YGmrtJ6nkZqEjc/lwti1y6i+8wnm/Nnv2eIkLRcgChP9Bk1WQFYzSSY8cYdkiIl9",
  b"fnJzZ2i0tamdnpKTh+DU1cnKvr+z/wD09enq3t8rLCAhFQkKA1xQUUVGOjsviHxwPlZheYSPp7JlfYigq7bO2Zmkr8fS3fUAwMvW7vkRHCfn8v0VIDhIUxMe",
  b"NkFMZG96OkVdTE9xZ5aMrrF7cZOWuK7d052gwrjn3f/1zMLk5wn/LiTu8RMJKy5VSyIYOj1fVYR6RDppWnRVYpu1lqOEkX+MxdLAza67qbbv/N332OXG4Bkm",
  b"ByECD/D9Q1U2QzE+Hyxyf2BtTmhJaG1lXa2lnZWakoqC0srPx7+3r6f3/PTs5NzU2SkhGREJAQb+TktDO0A4MCh4cGhtZV1VdoWhsGd2hZSjssHQh5alwdDf",
  b"7v20w9Lh8P8OHeHw/w4dLDtKBhUkM0JebXwzQlFgb36NhH6knmxmjIaspszGlI60rtTO9O68ttzW/PYcFuTeBP4kHkRDEQsxK1FLcWs5M1lTeXOZkqOImX6P",
  b"dIXC07jJobKXqOX22+zR4sfYFRn+D/QF6vs4SS5EKToSI2BxVmdMXUJTkKGGoJyYlJCMe3fLx8O/u6qmovby7t3Z1dHNIR0MCAQA/Pg/Ozw4NDAsG29rZ2Nf",
  b"TkpGmpaSVml8j5Wou86Jj6K1yM7h9K+1yNvuAQca1ejuARQnLUD7DiYsP1JlayY5TFJleIueTF9yZGKMfaelz8CSkK2r1cbw7rOx29n29B4P4d/8+iQVPz0P",
  b"BS8tSkhyYzUzUE54dpORY1R+codweLnBqr+bsJmh4urT6MTZtcoLE/wR7QLe8zQ8JS0bMAwhYmpTW0RZNUp+k3yEbYJegIBzc8u+vrGxpKSX7+Li1dXVyMgT",
  b"EwYG+fns7Dc3NyovIiIVbWBgU1NGRkaRkYSEd3dqjqWvxniPmbC60dvlpK7Fz+bwBxHQ2vH7BRwmPe8GECw2TVduICpBS2Jsg41MVm13jpiinJ6/wYp/raLD",
  b"xebosabUyffsDQ/YzfvwHhM0Nv8BIhxKP2BiKy1OQ3FmlIlSVHVqmI27qsOjr5yoiKHZ5cXevsq3w/sU9ADt+dnlKjYWLw8bDRlRakpWNk8vO4CMbIVlcV5q",
  b"oq6buLyzqqGlnJPi2d3Uy8LGvQwDB/717OPnNi0kKB8bEhZlXFNKTkU8M4+GfXR4b2ZdrLCnbomXpbPBz92grrzK2OYBD8XT4e/9GCY06vgGIS9CUF4UIj1L",
  b"WWd1g0ZUYnB+jJq1a3mHfHWnoMW+49yposfA5d4DCdbP9O0SCzAp9u8UDUQ9YlsoIUY/ZF2Ce0hOc2yRiq+odW6Tipp+jsravs6ywqa28gLm9trqzt4aKg4e",
  b"AhL2BkdXO0svPyMzb39jc1dnS1uXp4ubf49zmJOOidzX0s3Iw765//r18Ovm4dwvKiUgGwkEBFdSTUhDPjk0h4Jwa2ZhXFeqpaCblpGMprjK3Jaorb/R4/UH",
  b"wcbY6vwOICXf8QMVJzlDVQ8hM0VKXG6AOkxeY3WHmatlanyOoLLEtLHa15uYwb7n1wD9zr7n5A39JiP08Q0KMzBRTh8cODVeW4R0RUJrW4SBqppraJGOqqfQ",
  b"TFxsfIycrLx0hJSktMTU5JysvMzc7PwMxNRaVXx3npnAu4qFrJrBvOPerajPyvHsEw7Qy2h6YHKwwputk6WLnc7gxti+0La7+QvxA+nudnNwbbWyr6ycmZaT",
  b"6NjV0s+/vLkO/vv49fKEmKyzb4OKnrLGzeGdpLjM0+f7Ar7S5u0BFZKRvK6Bc56du7rY16qcx8bk4wEA08Xw4g0MoLaTqYacho/R2sTNt8Cqs/X+6P7b8c7k",
  b"GS+ur6OkmJmNjtrOz8PEuLmtBvr77/Dk2NklJmR8h5Kqtc3Yi6OuxtHc9P+yytXt+AMbJubxcnWXjbyy1Mqhl7m83tQD+cPG6N4AAyUb8uiAmnuIwc68yaq3",
  b"pbLr+Obz1OHC3BUiAx3+C46Gi4PTy8O7wLiwqPjw6O3l3dXNHSIaEgoCnKu61o2cq7rJ2Of2rbzL2vYFFCPa6fgHFiWqpMrEkoyyrNLM8uy6tNrU+vQaFOLc",
  b"AvwiHLjJrr+ktZqr6Pne4sfYvc4LHAES9wjt/i4/xsK+urayoZ3x7enl1NDMyBwYFAP/+/fzRzZ8j6K1u87h9KK1yNvu9Aca1dvuARQaLUD7DoqIsqPNy+jm",
  b"uLbT0fvsFhTZ1wHyHBpENQcFmK2Wnt/n0OXB1rLHCBD5Dur/2/AxOSIqEy2mppmZ5OTk19fKyr0VCAj7++7u7jk5LCwkJLTL1eyetb/W4OoBC8rU6/UMFi03",
  b"9gAKITBHwsTl2rCl08jp6wwO18z67xASMzX+8yEbST7Q6cnVws6uuv8L6wTk8N3pIToaJgYf/xBVYd7i2dDHvsK5CP8D+vHo7OMyKSAkGxIOEmFYlKK9y9nn",
  b"9QPG1OLw/gwaNev5BxUjQ1FfFSOim8DG6+QJAs/I7eYLBCki/PUaEzg2W1QhGrDApLTwAOT02OjM3BgoDBwAEPQERVU5SS09vrm0rwL9+PPu6eTSJSAbFhEM",
  b"BwJaVVBLOTTM3vACvM7T5fcJGy3a7P4QIjRGUAocLkBSV9rXAP3BvufkAP0mI/TkDQozI1FOHw84NV5bcoKSorLC0uKaqrrK2ur6CsLS4vICEiIy6vqAe6Kd",
  b"xL/m4bCrxcDn4gkE08718BcSOSf28Y6ghpjW28HTucuxw/QG7P7k9s/hHzEXKQ8UnJmWk9vY1dLCv7y5Af77+PXl4t80JCEeGwuqvtLZlamwxNjf8wfDyt7y",
  b"+Q0hKOT4/xMnO7i31dSnmcTD4eD+/dDC7d8KCScm+esWCDM3xty5z6zCn7X3AOrz3ebQ2RskDhcBF/QKP1rU1cnKvr+zpwD09enq3t/TLCAhFQkK/v9QUYqi",
  b"rbjQ2/P+scnU3/cCGiXY8PsTHilBTAQcmJu9s9XY+vDHvd/iBPopH+nfDgQmKUtGHROms6Gu5/Ti79Ddy9gRHv8Z+gfoAjtILkgpNrSssan58enh2d7Wzh4W",
  b"DhMLA/vzQztFPTUtwtHg77PC0eDv/g0c0+LxAA8rOkkAFCMyQVDQyvDquLLY0vjyGBLg2gD6IBpAOggHLSdNR97v1OXK28DRDh/3CO3+4/QxQic4IjMYHFlq",
  b"7Ojk4NzLx8MXEw8L+vby7kI+LS4qJiIecmGitcjb4fQHGsjb7gEHGi1A+wEULD9FWGsmLLCu2Mnz8Q4M3s/59yESPDr//SwdR0ViYDIwvtOvxAUN9gvn/Njt",
  b"LjYfJxAlBhtcZE1VPlPMzL+/Cgr9/f3w8OM7Li4hIRkZDGRkV1dKStrx+xLE2+XvBhAnMfD6ERs3QVhiFCs1TFZt6OoLANbL+e4PETIn/fIgFTs9XmApHkxB",
  b"YmT2D+/72/TU4CUxESoKFgMUTFhFUTFKKjZ7hwT7//bt5OjfLiUpIBcOBQ5dVEtPRj00OId+usjj8f8NGynf+ggWJDJFYBYkMkBOXHeFO0nIwebfEQovKPXu",
  b"EwwxL1RNGiBFPmNcgXpHQNbmytoWJgoa/g7yAj5TN0crOx8va3tfb1Nj5N/a1SgjHhkUD/34UEtGQTw3Mi2Ae3ZkX1ryBBYo4uf5Cx0vQVMFFyk7TV9kdjBC",
  b"VGZ4fQD9JiPn5A0KJiNMThIPODVeTnd0RTVeW4R0",
])

///|
let swso_422_ref_b64 : Bytes = sws_vec_concat([
  b"KDxRZXqTYVtziJy2nnuWqr/V2aG4zeH/VKnd/DwOIa/0Eys/WEofOTFAVHB/nG9jhJCavqJ/orHJ5eOsvM37hADD5f9MFiS19R0yRWZTKkxHSUKGkX12eGed",
  b"u6amo5Gm4tPWzL3Itn5cw+3rVi4kFRgKOmFKTEY6UExGhY2HhHRpoLqurJ6RrOzZ0c/DrwB7//Xy7lkrKBsdEDNjWlFDQGF7jlNhdYefs5N5lqm62tCdvMnj",
  b"/Dy+1vQhESjJ1QciQFQ9IzdQYXRpfpFdWHiMnL6VeJ2uv9rOob7Q91gCzd3vIxUk19MKK0JfPhtCS2h+gYF6c29gm7KimpaCqePLzMCx0o2B/+Hl4DkjHAlM",
  b"nyJWSEVAKk2DbImEfXRvY6G3pJ2Viq/e08rEvM+Qhv/q5OA+JSAXCgE8V05GPjROh3JCWnGElbJ5eJCotdS8m7DK2OguyNL1wQki1f99DzpSKho4Rl50ZDtZ",
  b"Sl5sjZa0iHSTq7Tdupu7x+P38cTY0lSqFuWuACI3VTAZOE5agWk5X2FnWpitnY2Lf6/Sxr+1qsb75u7e084hFhcAVv9uRzs4OB5OgGdhXFFqal2ipZiYkoGy",
  b"0c3Euau+//br4djOKh0TCACYhUQ/PjkoT3hpa2BWd5GvcniNoLPMpY6qyNvy57fP4v9pF+L/VhEwSBYUKj1bdlg4UmV4i4COpHBwiaGuzqiOr7/S8eC00d7/",
  b"bRbvaadDJ0gbES5DUXNTMVNhdpGXl5KFhni0z8Cyq5jD9eLj2tS2AK5ao2P/Tzw6MjATS29dWlZEZ5+Mn5qVkYdztcvCva2fx/nt3NfWsRoSCAB2/1E5OjUw",
  b"H1BwZmJTRWOdk1lxiZasypyNqMHO6daux/JxADfj9ikRKj3NEyo7VW0+M01bc5GCUW9hdYSfs8yck6rEzfLUrdTj/0sq5vPwIChBEBIvQlJxRDNNY3mTg1V1",
  b"eH5ys7u1pqmXyOvb2NDGkAC8Wop78ToxKSEjElZnV01RN2ORgXt5Z4F6cL7Bt7Cmmcvq39TV0pIJAi3/8+E5Ny4sIxdZZVtTSEFrloZ/d22SqcGFj6W50eS+",
  b"qcbZ8xpF4PPSBCFNtQAkOE9oMipEWm2KbU5sf5WhmqzEjououcvsx6fN3vccSNz10RAlTb4EIEJKZjYySGBulW1QbnuTsbG2qaKdkM3gz8zFt+thq0f/58Qq",
  b"IicUFBNRYFA/Ri5oi3V2a198raC5ua2io5PN3trOxM9uAB//8OnKLScmHxYTXVtNTUQybox6dnJhd7Spc4+hssTasKzB1NoAX9vh/4MPUf9iDjNJXBwpRldp",
  b"f1xPZXeIoZxuhXeKpb7K5LWmw9fYAGTf+a0AIU3/ZwU/TmAqLENaZoRZTW9+jq2YbIuPjoXG0sa7u6fjO9/q492iGBcWAKg+RUpENjUnZHpqYmBMeKeSkIh6",
  b"l5GI0djPycO34//07ufpqSImIBQECVVQSUM9MnWCbmhhVYCsoJmTjai/2aGntc3zk2bR2/9bCVz/PQwuQE4TKUBMYXxKTGBuhqOJY3yUq8KxwtyhosDhrFfy",
  b"wPN1pkBe/0IIMUVOHSk3V2qATUljdIepgmWLmKjITmN4jaK5gIadssbgsqnC1vepYd1WZ3uXqMGPkKO2xuW6rMzl3QN32W5uarC0pJuckcbaz8fJs+ZQl3L8",
  b"dnJtrrKtnpiQ1dvU0MDGR9H/9vKHorJ4hJayx9utpMLS95Jm2/ltAY+mtoCCn7XE27Kkx+HDAITY+m4Ap6agj5OIytXJvbqp4/zy6ejjdh2vqaOalIvO0cnD",
  b"ub013vrv5eR4GmiCj6m+15iju9Dh/8nF3v0pC477cIWStMDRpKC73pht48n0UgAUj/iIjIHAyMSxsKjh9e3f2NhhEQCkToyIhsvJvb+2p+bx6ujd3V4XGA4D",
  b"nrHPlqC1yNzzvrvR8BwLlv6xACOmtsmTmrDK2PPDu9f01wOYylmVD728uKuqoePy4M/Pz0YMAKZL+44uxcC7t6yb5O7n18/UThEAoP//li5/l7C91fCwt9L0",
  b"wACf9JQAGyaxToecqsfX6r2+0vnAAKSzY3wSQxsCnqOa3N7cy8nEK0uLmv/veiomHSanoJje5tzVy8s4AHf/7/p9LSwoI7jP5qm3zuylAKHf/lENJbYvCilD",
  b"wNTgr7bO7qoAqt7/UAwntu8bNEPY28/IwbXWXXCl8+1dKSAPOLYnY9/f0sbAv0Khe//p8mYgIh8SCj1fla7I2v1ZnNzr8xYbvdwEHkBbNxueq8f0kwCu2PY4",
  b"BRvB4A4pPF04GLWzs7tO/uDe3EUZFAQ9nR1TQDo4vberNf/17uniSRkZEgwAOVtQQTTP9Uij0uHgDB22/5EMNU8kFjNLV+dmpM/N60G6Ds6+ACYtVDASNEte",
  b"dImes8jfpqzD2P2Ce9v5XAIblv98jaG9zue1ssLmtQCV3v9oCiaW/5SUkdTRy8HCuNpB/+7s4mkgHhwRnJiT1NjTxL7BMe779ubsdBwgHQ6tyNieqrzW9myK",
  b"1Oj5JBWd/7kPOLbF16aoxdvq/9jL9UcDGq3oDh45zczGtbSszkX94+DeVBYSBjCtGFjVz8nAu6ws8u/p3+NcGh0JHv+gRY6otc/k/b7K2+kQFKT/pAoqSiUS",
  b"lqu40Ob3ysbsRL0QsssCGC5NMBKqq6jm7urX1to1VpOkVZEWRjg4MbKurPHv5Nvc2UQOEAgo/4UzQzkuxNjsusbb+rcArPuCACtFHA0nOk7M3O+5wNb8swC7",
  b"onVwFkIaCCk8S+Pi3tHQziNqd63/9WwyListFTxq6+bh2snJMA4Bxv76dTQtLCYbTGqlvdbymgCw9W4AHCzGIRk5RmNGJq3C0PycALzh/00UMsrpHTZKZUct",
  b"xcK8CnJsvfXqWikjGBwJRWRRSE3Nxr8LY//88fFeKSggGg5CaFhQSd7/Vq3h8ygQJdDNCS9EYjEjPFJp94QAv+D8LhYk1c0PLkNjPSFGUma1av/k6N9EIR4U",
  b"Dwc9Vks9QSlbiTn/+ezm6EYiJRgLBEdXTUo9MGOFu9T12gof07YBIjRXLSE3SVyBXUHE0uUfFSfgswEnOVUoI0FUY4JePtvZ1CsYD75meiNNPzUzIFV5ZmBe",
  b"493XNh8bCVX/dEREPTcqYYFxYFu9ACPT/2UNNE8XFjFJXnBLPFlxfUWmFOKWACAwUh4WNlFXelY4WnJ6",
])

///|
let swso_420_in_b64 : Bytes = sws_vec_concat([
  b"JjZGVmZ2hpZOXm5+jp6uvnaGlqa2xtbmnq6+zt7u/g7G1ub2BhYmNu40L1ZReHOalWRfhoGblr24h4KppMvG7ei3pczH7ukQC9rV/PceGTMu/UJUOkyKnHWH",
  b"bX9ld7W6oLKYqpCV0+XL3cPVrsD+EPYI4fPZ6yk7ISYMUE1KR4+MiYaDc3BtwrKvrKmZlpPo5dXSz8y8uQ4L+/j18u/fNDEuHhtecoaNSV1xeIygp7t3fpKm",
  b"rcHV6ZiswMfb7/YKxs3h9QkQJDjn+w8WKmxrlohbTXh3lZS/sYR2oaC+vdvarZ/KyefmBAPWyPPlEA8tLP/xHA4+epBtg212YGmrtJ6nkZqEjc/lwti1y6i+",
  b"8wnm/Nnv2eIkLRcgChP9Bk2IiX1+cnNnaLS1qZ2ekpOH4NTVycq+v7P/APT16ere3yssICEVCQoDXD5WYXmEj6eyZX2IoKu2ztmZpK/H0t31AMDL1u75ERwn",
  b"5/L9FSA4SFMTTE9xZ5aMrrF7cZOWuK7d052gwrjn3f/1zMLk5wn/LiTu8RMJKy5VSyJadFVim7WWo4SRf4zF0sDNrruptu/83ffY5cbgGSYHIQIP8P1DVTZD",
  b"MWhtZV2tpZ2VmpKKgtLKz8e/t6+n9/z07OTc1NkpIRkRCQEG/k5LQztAdoWhsGd2hZSjssHQh5alwdDf7v20w9Lh8P8OHeHw/w4dLDtKBhUkM0KEfqSebGaM",
  b"hqymzMaUjrSu1M707ry23Nb89hwW5N4E/iQeREMRCzErUZKjiJl+j3SFwtO4yaGyl6jl9tvs0eLH2BUZ/g/0Ber7OEkuRCk6EiNgoJyYlJCMe3fLx8O/u6qm",
  b"ovby7t3Z1dHNIR0MCAQA/Pg/Ozw4NDAsG29WaXyPlai7zomPorXIzuH0r7XI2+4BBxrV6O4BFCctQPsOJiw/UmVrJmRijH2npc/AkpCtq9XG8O6zsdvZ9vQe",
  b"D+Hf/PokFT89DwUvLUpIcmM1codweLnBqr+bsJmh4urT6MTZtcoLE/wR7QLe8zQ8JS0bMAwhYmpTW0SAgHNzy76+sbGkpJfv4uLV1dXIyBMTBgb5+ezsNzc3",
  b"Ki8iIhVtYGBTU46lr8Z4j5mwutHb5aSuxc/m8AcR0Nrx+wUcJj3vBhAsNk1XbiAqQUtinJ6/wYp/raLDxebosabUyffsDQ/YzfvwHhM0Nv8BIhxKP2BiKy1O",
  b"Q3Gqw6OvnKiIodnlxd6+yrfD+xT0AO352eUqNhYvDxsNGVFqSlY2Ty87gLi8s6qhpZyT4tnd1MvCxr0MAwf+9ezj5zYtJCgfGxIWZVxTSk5FPDOPbomXpbPB",
  b"z92grrzK2OYBD8XT4e/9GCY06vgGIS9CUF4UIj1LWWd1g0Z8daegxb7j3Kmix8Dl3gMJ1s/07RILMCn27xQNRD1iWyghRj9kXYJ7SIqafo7K2r7OssKmtvIC",
  b"5vba6s7eGioOHgIS9gZHVztLLz8jM29/Y3NXmJOOidzX0s3Iw765//r18Ovm4dwvKiUgGwkEBFdSTUhDPjk0h4Jwa2amuMrclqitv9Hj9QfBxtjq/A4gJd/x",
  b"AxUnOUNVDyEzRUpcboA6TF5jdbSx2tebmMG+59cA/c6+5+QN/SYj9PENCjMwUU4fHDg1XluEdEVCa1uETFxsfIycrLx0hJSktMTU5JysvMzcWlV8d56ZwLuK",
  b"hayawbzj3q2oz8rxaHpgcrDCm62TpYudzuDG2L7Qtrv5dnNwbbWyr6ycmZaT6NjV0s+/vLkOhJiss2+Dip6yxs3hnaS4zNPn+wK+kpG8roFznp27utjXqpzH",
  b"xuTjAQDToLaTqYacho/R2sTNt8Cqs/X+6P7brq+jpJiZjY7azs/DxLi5rQb6++/wZHyHkqq1zdiLo67G0dz0/7LK1e34cnWXjbyy1Mqhl7m83tQD+cPG6N4A",
  b"gJp7iMHOvMmqt6Wy6/jm89ThwtwVjoaLg9PLw7vAuLCo+PDo7eXd1c0dnKu61o2cq7rJ2Of2rbzL2vYFFCPaqqTKxJKMsqzSzPLsurTa1Pr0GhTiuMmuv6S1",
  b"mqvo+d7ix9i9zgscARL3coKSorLC0uKaqrrK2ur6CsLS4vICgHuincS/5uGwq8XA5+IJBNPO9fAXjqCGmNbbwdO5y7HD9Abs/uT2z+EfnJmWk9vY1dLCv7y5",
  b"Af77+PXl4t80qr7S2ZWpsMTY3/MHw8re8vkNISjkuLfV1KeZxMPh4P790MLt3woJJyb5xty5z6zCn7X3AOrz3ebQ2RskDhcB1NXJyr6/s6cA9PXp6t7f0ywg",
  b"IRUJiqKtuNDb8/6xydTf9wIaJdjw+xMemJu9s9XY+vDHvd/iBPopH+nfDgQmprOhruf04u/Q3cvYER7/GfoH6AI7tKyxqfnx6eHZ3tbOHhYOEwsD+/NDwtHg",
  b"77PC0eDv/g0c0+LxAA8rOkkA0Mrw6riy2NL48hgS4NoA+iAaQDoI3u/U5crbwNEOH/cI7f7j9DFCJzgi",
])

///|
let swso_420_ref_b64 : Bytes = sws_vec_concat([
  b"JjdHWGh4i4tLYnKDk6S5pHWNna6+z+a6orjI2en/M5zX4/8cEiU06jQwVlR5d52NXmeHiJqiwaZ+k6e3yNvxzKW+x+P+QwC02Pf/MxcyLfhCUzpRj5h2hG96",
  b"ZYi9saWpn6CMsuPX1s3Qu7P/Psoxsffc8js5IiYNUE1JTJKMiIaAcWyExbCurKOXjrzu3NLQzsLIPwDD//bz8OpEMC4fG15zh4hIYHN7kaKvq3KEmqm0yubC",
  b"mrjE0uj/RITS2/81CCAt1v8cFSpsbZaEV1F6fJadwaV6gqOrvsrgxZ+1ytv8UQCa0en6NwgpIuz7KA09e49ugm10X3SysJ+ik5OBpeDWzMfAuK7zUIv/4ure",
  b"7kcoGiAMC/UQS4iJfX1ycmV0urOlnZuSiqjj1NDJxL+y9k6S/+zq4exMKCIhFwoKA1o+VmJ6hZKrpmSAjqSuvtfCl6i6zdf/WmLS0eb/TRAWw/T/Lxs2R1MU",
  b"TFBxapePsal0d5Wgtrzhvpevvc/j8P/dwNj7NMdpEMj/MgUoLVNMI1tzVWags5efhY5+m87NxcKys6nS/ers5eHP51IdDR0IANH/VFM4QzFobWRjsKSblZmQ",
  b"hJfWy83EvLOlzf/58Off1uZdHBsTCwIA6mJKRDtAdoajq2V4iJemtsi+hJuvyNbm+9q1y9rq/2AAqPP/QBIpOEwMEyMyQoR/pZppao2Mra7QuYyas7zS3vjW",
  b"ssvY7f9nAKn6I9NUFz9GFgovK1CSoomXf4x0j8rOu7+kqpe/8+vj39rT32QAxVK7Oqr/W0MxQis6FCJfoJyYlJCKeITQxsK+tqegwfzx5trX091mFRIJBQDB",
  b"/2E3PDk0MC0bbVZqfZCXq8DEhZOnu8rU7dyqvNH4dQADiuz/SgIiKy7qNx4rPFBkayhkZIyAqKrQuI6WrbbS0vbYqsPb5/+BAIzq8v9jDDVCGAMpLEdHcGQ2",
  b"coZwfb2+rLqdrZey6+La28zKym4ApnOaVIP/azQqLB0vEBtca1RbRYCAcnrNvrywr6OerfPi3tTWz9RwBgwAmP/w+2svOCwvJCMSZWJgU1OOpbHBd5Gds7/V",
  b"4dSgtsnY+40AbuLm/2YEIifRSgMmM0lVbycoQEtinJ/AvYaErqfFzOvap7TS2v+MAHLe5v9yBygm20kRG0JAW2UwK0xDcKvCo66dpYir4N7K18DEtueVcYZf",
  b"/+jtdCkfKBgYEBJFaU5WOE4xOn+4vLKpoaSZn+bZ3NHHw817AAB5//Dm9H4mJiciHBQPV2BVS05GPTONb4qYprXD09SessDO6J4AU9nZ6P+HDiCh/1cLKzxM",
  b"YSEcOUlXZnSDR3x3p6PFwuXUo6nHyfGYAFbi3/+DAB8dpP9fADQ+WmIyHkE/YV2AfEmKmX6Tzte/yrS9pdGnNP/s4N7hfxUbGA0AvlgoWEFJMz4mLml/ZHJY",
  b"mJONj9/W0czHwrrL//jz7unk64ggJyIeEAUAQFdOSUQ/OjB/hHFrZqa5zNeVqa/D1fC4JNHL3/+dARZ+/3AAHzM/ViIYLkFIWGuCQEldY3W0s9vSmJ3Cxe2g",
  b"LP/DyvaFaLYEiP91ACMxRlUtGDIzV1p/eUlBaVuDTV1uf5ChtqJzjJytvs/mqqe6y9taWHx9nqPEqYGYorC91+W3pcvK72l4YHy5uZ+kmpmOud/O1MPOubn2",
  b"dnNueLmxr6aamI3G49XT0cK8uxWFmq+oboWQprzJ3rqbscfR4/8TtJKUvad6faCou8jevpu5xt7wGwDKobOVpImYg6fc0MnAvbGr5//q/N2urqOimJaIqtvO",
  b"ycS8ub0Yzv/w8GV9iJatu9e8jqi7zdfs/8HD0+v4cniWlLy61ruXprrR6y6118Lk4gmBmHqRyMrAvq6vptP46/Ha4MXcHY6GiZDXycC9vrSl1/nq7Ofe1tAk",
  b"nay/y4ugsMDP3/bLscbV/ysNINKpp8y8jJaxutDe9s+wztTy/zMP2bnHsLunr5rB9u3g0dLF1zMVBA3uc4OUpbbH3MiZssLT5P86ktTg9AyAfqKjxMnqz6i3",
  b"wdf5TACp0/H0II+ehqPc1MbKwL+09UyX/+n00+InnJmUnt/X1czAvsk4l//59+ji4TurwNXOlKu2zNv7aGPS1+3/Mhol3Li5182go8bO4e7/5MHg9TUBJCTw",
  b"x9m7yrC6n9+FWf/m49fkQh4QFgLU1MnIvr24Wlf/7+ri3+NPHSEWCYujrrzT4f3itM/Z/1oEFrLx/yUcmJ68uNfh/OG9zPVMpXgIwPEmAiWnsqG37vDm5NTV",
  b"4WQAzU3TKNEWN7Ssr7b97+bd29vgZw4QEg0A3vlKw9Lj5rLG1ub/jACH5/89ASY4SQPPzfLisrzX4P+LAIr8LsFXEzw8Ct/t1uHN1c6LAJl3e//r/Vk7Kjcj",
])

///|
fn swso_case(
  in_b64 : Bytes,
  ref_b64 : Bytes,
  src_fmt~ : @swscale.SwsChromaFmt,
  sw~ : Int32,
  sh~ : Int32,
  dw~ : Int32,
  dh~ : Int32,
) -> Unit raise {
  let frame = match @libavutil.av_base64_decode(in_b64, 100000) {
    Ok(v) => v
    Err(e) => fail("base64: \{e}")
  }
  let ref_pcm = match @libavutil.av_base64_decode(ref_b64, 100000) {
    Ok(v) => v
    Err(e) => fail("base64: \{e}")
  }
  let (chs, cvs) = match src_fmt {
    Yuv420 => (1, 1)
    Yuv422 => (1, 0)
    Yuv444 => (0, 0)
  }
  let cw = (sw + (1 << chs) - 1) >> chs
  let ch = (sh + (1 << cvs) - 1) >> cvs
  let y = frame[0:sw * sh].to_owned()
  let u = frame[sw * sh:sw * sh + cw * ch].to_owned()
  let v = frame[sw * sh + cw * ch:].to_owned()
  let s = @swscale.SwsPlanarScaler::new(
    src_w=sw,
    src_h=sh,
    dst_w=dw,
    dst_h=dh,
    src_fmt~,
    dst_fmt=src_fmt,
  )
  let (dy, du, dv) = s.scale(y, u, v)
  let bytes : Array[Byte] = []
  for plane in [dy, du, dv] {
    for b in plane {
      bytes.push(b)
    }
  }
  let ours = Bytes::from_array(bytes)
  inspect(ours.length(), content=ref_pcm.length().to_string())
  let mismatches = {
    let mut m = 0
    for i in 0..<ours.length() {
      if ours[i] != ref_pcm[i] {
        m = m + 1
      }
    }
    m
  }
  inspect(mismatches, content="0")
}

///|
test "swscale odd realdata: 4:2:2 odd source width 51x30 -> 40x30" {
  swso_case(
    swso_422_in_b64,
    swso_422_ref_b64,
    src_fmt=Yuv422,
    sw=51,
    sh=30,
    dw=40,
    dh=30,
  )
}

///|
test "swscale odd realdata: 4:2:0 odd source width 41x30 -> 40x30" {
  swso_case(
    swso_420_in_b64,
    swso_420_ref_b64,
    src_fmt=Yuv420,
    sw=41,
    sh=30,
    dw=40,
    dh=30,
  )
}
