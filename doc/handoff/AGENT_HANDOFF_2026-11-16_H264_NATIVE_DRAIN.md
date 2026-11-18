# H.264 native encoder EOF backpressure

Continued with moonbit-c-binding and make-moonbit-c-bindings. Source of truth:
../libavcodec/encode.c avcodec_send_frame checks buffer_frame before accepting
NULL, returning EAGAIN when a frame is pending; subsequent NULL sends return
EOF once draining has begun.

## Fix

Previously send_eof silently treated EAGAIN as acceptance. flush then received
pending packets but never resent EOF, spinning on Again indefinitely. The
backpressure test reproduced the false acceptance before implementation.

- send_eof now raises SendFailed(1) if EOF is rejected by backpressure. Callers
  must receive pending packets and retry. Public signature remains Unit raise.
- flush collects pending packets while retrying EOF, then drains until Eof.
  Unexpected Again instead of progress raises ReceiveFailed(1), avoiding a spin.
- C maps AVERROR_EOF on repeated EOF sends to success. Repeated flush returns
  an empty array; closed handles still fail. No ownership or extern ABI change.
- README and API docs explain the retry contract.

## Tests

Native lifecycle 4/4: bounded no-receive fixture reaches backpressure; send_eof
reports rejection; flush collects exactly the accepted frames and produces
packets identical to encode_all; dual decoding agrees; repeat flush and EOF;
empty drain; frame submission after drain/close and packet/extradata reads
after close fail safely; repeated close succeeds.

Existing native 420 round trips 4/4 (including CABAC/B and ten-bit), README
example 1/1, native moon info passed without public signature changes, Wasm
check passed with the existing ABR Array Show deprecation warning. Full native
suite not rerun. Lifecycle tests also passed 4/4 under ASan plus leak detection,
without a sanitizer report. Same temporary libc allocator adaptation as
NATIVE_CHROMA; C stubs and generated code instrumented, upstream static archives
uninstrumented. Package flags and container allocator restored after validation.

Unrelated existing worktree changes preserved. No commit.
