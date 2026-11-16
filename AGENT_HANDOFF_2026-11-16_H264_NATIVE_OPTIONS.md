# H.264 native encoder option transport

Continued using moonbit-c-binding / make-moonbit-c-bindings and the previously
read MoonBit skills. This round fixes a functional option-transport bug rather
than adding another format.

## Behavior

`X264Encoder::open(options=[("x264-params", "keyint=2:bframes=0")])`
previously serialized the value into the outer FFmpeg dictionary without
escaping. The second nested parameter became a separate outer entry and was
not applied to x264. A new regression failed on packet equality before the fix.

The private MoonBit serializer now escapes colons, equals signs, backslashes,
single quotes and ASCII whitespace for the outer `av_get_token` layer.
Nested values reach avcodec unchanged; callers supply literal values without
outer escaping. Empty key/value and embedded NUL are rejected before FFI.
Public API signatures and borrowed-buffer ownership remain unchanged.

Source of truth: ../libavutil/dict.c parse_key_value_pair / av_dict_parse_string,
../libavutil/avstring.c av_get_token, ../libavcodec/libx264.c x264-params option.

The C parse-failure path also now frees the partially populated dictionary.
Previously a valid prefix followed by a malformed token leaked its entries.

## Verification

- Native options tests 3/3: nested parameter transport (plain, quoted,
  backslash-escaped and whitespace variants all byte-identical to explicit
  GOP/B-frame options); empty/NUL rejection; repeated malformed raw dictionary
  failure and cleanup.
- Existing native 420 round trips 4/4; updated README public example 1/1.
- Native moon info passed with no new public declarations.
- Wasm check passed with the pre-existing ABR Array Show warning.
- ASan plus leak detection: options tests 3/3, no sanitizer report. Uses the
  libc-forwarding allocator adaptation recorded in NATIVE_CHROMA. C wrapper and
  generated test code instrumented; upstream static archives uninstrumented.
  Temporary moon.pkg flags and container allocator restored afterward.

Full native suite not rerun. Existing worktree changes preserved; no commit.
