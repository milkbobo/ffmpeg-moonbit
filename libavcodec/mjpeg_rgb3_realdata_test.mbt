///|
/// JPEG 3-component Adobe transform paths: `cjpeg -rgb` writes a real
/// 17x13 RGB JPEG (APP14 transform 0, component IDs R/G/B), decoded as
/// GBRP. Variants isolate the transform-0 and RGB-ID conditions; all must
/// match `ffmpeg -f rawvideo -pix_fmt gbrp` byte for byte.

///|
let jpeg_rgb3_t0_b64 : Bytes = b"/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAEQgADQARA1IRAEcRAEIRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAAwDUgBHAEIAAD8A9L8B6D4cm/Y7j+OA8U/aviBc502X4m/2fIk8tqmrNYrObPO0SC2/d7tvmY53Z5rzA21r/wAIYfEH2z/iZj/iWjxD5R882ouvJE5H3vM8r+L/AFmPl3V+X76ix1PZ9sRoB/owvfsyhzFvzv6bt2O+d2Plzjivl74raVo2v2n7Lfj2VZPidr/iW58RWWqaukcthceJbexultrPfGOY5PJwm4L5h43FiBXzT8T7Wy1LSvhhrrxSeMb6/ub2zuLpEeCfW4La7WK3DAZYSPHhdxBk5AJYqK9k0a7m/wCEu16zCEQWVxZWtskEHmTXMXmttB2gu7yhsAtudQ6jPyAD0T+xfD3/AEap4g/8Hupf/G6uf2XpH/Rumv8A/gx1D/43XpX2Wb/oRPEH/gvvf/jVfK/wh/aP+Iuq+NNa8V3XiLzda+yQWAf7FbLALYRvH5ItxGIvL2j7mzGfmxnmu9bxVqn28Xf2r5xafYBF5a+QLbGPJEOPL8vvs24zzjPNfJDazeswJuXIEXkBM/II87tm3ptzzjGM89a8/wBH+MXjH4ifGXQvEuu63Jca1ZxiG0uLeGO1W1SKArGsMcKqkQUKMBFAzk9SSfmHWvGut+INZtNVvNQkN9ZxxRWkluFgFqkf+rWFYwqxheoCAcknqSa+kFsIohF5bzxeSsSweXcSL5Ajcugiw37sB2ZhtxySepr33/hd3xC/6HfxB/4Mpf8A4qr3/C1vG3/Q46//AODOf/4qtH+29a/6GPxB/wCDm6/+OV//2Q=="

///|
let jpeg_rgb3_ids_b64 : Bytes = b"/9j/7gAOQWRvYmUAZAAAAAAB/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAEQgADQARA1IRAEcRAEIRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAAwDUgBHAEIAAD8A9L8B6D4cm/Y7j+OA8U/aviBc502X4m/2fIk8tqmrNYrObPO0SC2/d7tvmY53Z5rzA21r/wAIYfEH2z/iZj/iWjxD5R882ouvJE5H3vM8r+L/AFmPl3V+X76ix1PZ9sRoB/owvfsyhzFvzv6bt2O+d2Plzjivl74raVo2v2n7Lfj2VZPidr/iW58RWWqaukcthceJbexultrPfGOY5PJwm4L5h43FiBXzT8T7Wy1LSvhhrrxSeMb6/ub2zuLpEeCfW4La7WK3DAZYSPHhdxBk5AJYqK9k0a7m/wCEu16zCEQWVxZWtskEHmTXMXmttB2gu7yhsAtudQ6jPyAD0T+xfD3/AEap4g/8Hupf/G6uf2XpH/Rumv8A/gx1D/43XpX2Wb/oRPEH/gvvf/jVfK/wh/aP+Iuq+NNa8V3XiLzda+yQWAf7FbLALYRvH5ItxGIvL2j7mzGfmxnmu9bxVqn28Xf2r5xafYBF5a+QLbGPJEOPL8vvs24zzjPNfJDazeswJuXIEXkBM/II87tm3ptzzjGM89a8/wBH+MXjH4ifGXQvEuu63Jca1ZxiG0uLeGO1W1SKArGsMcKqkQUKMBFAzk9SSfmHWvGut+INZtNVvNQkN9ZxxRWkluFgFqkf+rWFYwqxheoCAcknqSa+kFsIohF5bzxeSsSweXcSL5Ajcugiw37sB2ZhtxySepr33/hd3xC/6HfxB/4Mpf8A4qr3/C1vG3/Q46//AODOf/4qtH+29a/6GPxB/wCDm6/+OV//2Q=="

///|
let jpeg_rgb3_t0_ids123_b64 : Bytes = b"/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAEQgADQARAwERAAIRAAMRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAAwDAQACAAMAAD8A9L8B6D4cm/Y7j+OA8U/aviBc502X4m/2fIk8tqmrNYrObPO0SC2/d7tvmY53Z5rzA21r/wAIYfEH2z/iZj/iWjxD5R882ouvJE5H3vM8r+L/AFmPl3V+X76ix1PZ9sRoB/owvfsyhzFvzv6bt2O+d2Plzjivl74raVo2v2n7Lfj2VZPidr/iW58RWWqaukcthceJbexultrPfGOY5PJwm4L5h43FiBXzT8T7Wy1LSvhhrrxSeMb6/ub2zuLpEeCfW4La7WK3DAZYSPHhdxBk5AJYqK9k0a7m/wCEu16zCEQWVxZWtskEHmTXMXmttB2gu7yhsAtudQ6jPyAD0T+xfD3/AEap4g/8Hupf/G6uf2XpH/Rumv8A/gx1D/43XpX2Wb/oRPEH/gvvf/jVfK/wh/aP+Iuq+NNa8V3XiLzda+yQWAf7FbLALYRvH5ItxGIvL2j7mzGfmxnmu9bxVqn28Xf2r5xafYBF5a+QLbGPJEOPL8vvs24zzjPNfJDazeswJuXIEXkBM/II87tm3ptzzjGM89a8/wBH+MXjH4ifGXQvEuu63Jca1ZxiG0uLeGO1W1SKArGsMcKqkQUKMBFAzk9SSfmHWvGut+INZtNVvNQkN9ZxxRWkluFgFqkf+rWFYwqxheoCAcknqSa+kFsIohF5bzxeSsSweXcSL5Ajcugiw37sB2ZhtxySepr33/hd3xC/6HfxB/4Mpf8A4qr3/C1vG3/Q46//AODOf/4qtH+29a/6GPxB/wCDm6/+OV//2Q=="

///|
fn mjpeg_rgb3_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "mjpeg: 3-component Adobe transform/RGB IDs output gbrp" {
  for encoded in [jpeg_rgb3_t0_b64, jpeg_rgb3_ids_b64, jpeg_rgb3_t0_ids123_b64] {
    let bytes = @libavutil.av_base64_decode(encoded, 10000).unwrap()
    let img = @libavcodec.av_mjpeg_decode(bytes).unwrap()
    assert_eq(img.width, 17)
    assert_eq(img.height, 13)
    assert_eq(img.pix_fmt, "gbrp")
    assert_eq(img.planes.length(), 3)
    let planes : Array[Byte] = []
    for p in img.planes {
      assert_eq(p.length(), 17 * 13)
      for b in p {
        planes.push(b)
      }
    }
    assert_eq(
      mjpeg_rgb3_md5(Bytes::from_array(planes)),
      "f8cd74e1679d3f062dd8572d02c4e1a2",
    )
  }
}
