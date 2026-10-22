///|
/// FFmpeg 9.0.2 libaom-av1: testsrc2=size=256x128:rate=1, one frame,
/// -cpu-used 8 -tiles 2x2 -crf 30 -g 1 -f ivf av1_tiles4.ivf.
/// trace_headers: frame payload header 104 bits; tile group starts at byte 13,
/// group flag/alignment add one byte. Golden tile offsets/sizes/MD5s come
/// from scripts/av1_tiles_reference.c (args: input.ivf 14 4 2).
/// Regenerate: moon run scripts/emit_av1_tiles_vectors.mbtx
/// LGPL-2.1-or-later.
let av1_tiles4_obu_b64 : Bytes =
  b"EgAKCgAAAAO3//Nr5AEytgoUADReABxyCxKEFddAABkC21x8/0d7focYMYz1lod/o+Sz9/JBWx4xkwqfcNk6bC+EJIz6+cvlVjOyfSPXauI8VW34" +
  b"mkwp8zbzrlJO5tw0FZ4gvQTH8uECJlC9TyYhHflfJevl7/GmFISckCy1/mNWDthCg6U+LnPO96rkaeB99SSxg76Ln+9POAN9YODTbJOuZexlYnfu" +
  b"yqr5kBEjXM2sA9L8TwWoueqUVF1zIOFFJLkj8YeHibktQFfrx3zFp2P0bI85uVy7z+zqlNx5GYqJNqquwrngy6jDargJc0eCn5mAlgjwF993Y6+t" +
  b"Qud/ZgZ7m069eMxoC2+Fi3Bdz4o7tqs5wueJ2l5hC9OenaH9Wh1YaLguIJOR1N6/yf83kTaRZQJsD+GyuSKJPHBrAAkMbV9K195/KjB5t8J4KQSM" +
  b"wUP86DrgdjtD6LOOTtGos/F8z+o74PexI0+/7kDSe6zes57OaLv0/6cFgP72SPH0Tsw8Dv6+Ra8TlNSUvwM5ohPG7NvLqDPtBjBDU+oI1XQYx6ZK" +
  b"Tqdtlf2jxeGWQrpWDIoWr6ihYk6vN+tuKBQLNz5TqrhizNjRMNJen3vloB6b7zq47I+HA0bseNRi1USZ5OgRUPUpjRme91cLgZq8FNTJX4Y/TP7Z" +
  b"yEkiX3Zh+cyMiOuspTXNhQAfOcPgbASCz8R13xFu8AE/HljsTK60nB5syoSURMGDz3XZfTF1afNffL40nZb8Kqa76O4AwiD2V+Twh9JS74pc05VF" +
  b"Bc4XMAZ4SknVfT3Iz8RAnGyLRA1oCZi6QdTzaccUlJ+dpuzwwz9Otd+W4stebuNGYegoaLJMV6ngtMhp/6Sss3oC5TuTSzxvfNEaoOkm8YUhO85X" +
  b"GHs7lj2FHLWdMjGhOAgEG8kZElZ/1Xn/yZSUzL6BFvjlDcg4xA0ATsvYeUgGEEjh/KUbKdxDXReRFApWRB59vXCBHNt4Km2eo0HiWJyHN+clRZlO" +
  b"CebYYpD9i3/p8QkLa2QP1y6TeWQZdcgNau8QdJnhcA74dFjmvXo7b1IHyAuiUZCrINb5csaIWeA7AMIg9n/0Isr9DcElSomQwlW95I/xhotEbgAK" +
  b"GZh56L8Y370b1O6GZd0S9iPD6p/PbkquiSValjLIoMP18LRT7Ffk8IfSUu/LPXLWd66jfqSW3kOpRT5fJv8W8m9BeeZ4xe4m2N0AyyrNZuAJJQf4" +
  b"1lUOXMDzAkoLC05WVvJ5YduYtO9H5zM0giz8LPUybrLxtrDwkafjZhCwa9oWJsCQlry/txKXCrsGJin0HR3i9XLBJ22BHxfM+T8h8tN1HAd1d/Nu" +
  b"7TlW0QIGa4rHMU73b7AXE0jkba+DPoDwTtgAx4wcBw8L0nPBlJvIypSof+tpq9bIWe1+qaHopm+GzIhLfyI5B7EUvpdt4Jz4O7OBfxgPVYLB33kR" +
  b"A/QhlpkBfcDEmsJfJjgAsMv+HggiySVUjSODUmsnC/JR+dzd2Ahbjuo5dGvuT6wbRkCSspQlAl1TAEOfd4MqRuWyjpWKtEDGQjXzgiHk2xw9s/u1" +
  b"jdEzL+C3cCB2Ap3qzbw1VeQhDmSHCcy2ezsRTboGG+u6lbWTsJaOIp98D1Qb/7NwmvermnlaafUla1HNOlXDbn/96F3mqH6FYEOwU25yBI0yfqfQ" +
  b"632iWxDrUWWn8RXX3QFkW9FxyQCQrmZY5UV9sSzWPN+aKENqCWV52Kgk1lGmm2O3bZhw/7meled5jmepk9vvYOAedwBhHMHY54IQGvREHSUMsgaF" +
  b"xM5ZY/W/wA=="

///|
let av1_tiles4_reference : Array[(Int32, Int32, String)] = [
  (16, 538, "a277b8a9c960f469d1ef505ed7ab0f18"),
  (556, 239, "d03d4df03dd03fd880ab4b1882ce48e1"),
  (797, 60, "028e8246f3cf71b22e9c542221d47c81"),
  (857, 477, "b0eced23e0adece5fbaa9d7e93782f62"),
]
