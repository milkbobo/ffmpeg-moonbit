///|
/// Kernel-level comparison of `mc_scaled_kernel` against a standalone C
/// build of `do_scaled_8tap_c`/`do_scaled_bilin_c` (vp9dsp_template.c):
/// deterministic LCG source, per-case FNV-1a over the output block.
/// The C harness lives in `.scratch/av1/scaled_vp9_harness.c`.
test "vp9 scaled mc kernel matches C" {
  let dec = @libavcodec.vp9_decoder_new()
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      64,
      64,
      0,
      0,
      20,
      26,
      0,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<64 {
      for x in 0..<64 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="3851632006974652590")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      32,
      32,
      7,
      11,
      20,
      26,
      0,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<32 {
      for x in 0..<32 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="14549929168352982557")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      16,
      16,
      3,
      5,
      20,
      26,
      2,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<16 {
      for x in 0..<16 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="1957108793136409161")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      8,
      8,
      13,
      9,
      20,
      26,
      1,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<8 {
      for x in 0..<8 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="16891596868901077912")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      8,
      4,
      5,
      7,
      20,
      26,
      3,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<4 {
      for x in 0..<8 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="10012998300162984631")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      4,
      4,
      9,
      13,
      20,
      26,
      0,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<4 {
      for x in 0..<4 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="5225681748144786612")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      64,
      16,
      1,
      2,
      20,
      26,
      0,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<16 {
      for x in 0..<64 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="15512444668007850866")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      8,
      64,
      15,
      15,
      20,
      26,
      0,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<64 {
      for x in 0..<8 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="6535537274487249959")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      64,
      64,
      15,
      15,
      20,
      26,
      2,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<64 {
      for x in 0..<64 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="17623235417021995358")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      32,
      16,
      9,
      1,
      20,
      26,
      3,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<16 {
      for x in 0..<32 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="16098304436238608047")
  }
  {
    let dst = FixedArray::make(64 * 64, 128)
    let src = FixedArray::make(64 * 140, 0)
    let mut st = 12345
    for i in 0..<(64 * 140) {
      st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
      src[i] = (st >> 16) & 0xFF
    }
    dec.mc_scaled_kernel(
      dst,
      0,
      64,
      src,
      3 * 64 + 8,
      64,
      32,
      32,
      7,
      11,
      26,
      20,
      1,
      false,
    )
    let mut fnv : UInt64 = 1469598103934665603UL
    for y in 0..<32 {
      for x in 0..<32 {
        fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
      }
    }
    inspect(fnv, content="1942003389377653564")
  }
  let dst = FixedArray::make(64 * 64, 128)
  let src = FixedArray::make(64 * 140, 0)
  let mut st = 12345
  for i in 0..<(64 * 140) {
    st = (st * 1664525 + 1013904223) & 0xFFFFFFFF
    src[i] = (st >> 16) & 0xFF
  }
  dec.mc_scaled_kernel(
    dst,
    0,
    64,
    src,
    3 * 64 + 8,
    64,
    16,
    32,
    5,
    3,
    26,
    20,
    0,
    false,
  )
  let mut fnv : UInt64 = 1469598103934665603UL
  for y in 0..<32 {
    for x in 0..<16 {
      fnv = (fnv ^ (dst[y * 64 + x] & 0xFF).to_uint64()) * 1099511628211UL
    }
  }
  inspect(fnv, content="13423523679301914372")
}
