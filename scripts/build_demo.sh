#!/usr/bin/env bash
# 构建浏览器演示的 wasm 模块（申报书⑤）：
#   demo/api → wasm-gc release（foreign_library + #export_name +
#   use-js-builtin-string），产物拷到 demo/api.wasm 供 demo/index.html 加载。
# 本地预览：在 demo/ 下 `python -m http.server 8000` → 访问 /demo/
set -euo pipefail
cd "$(dirname "$0")/.."

moon build --target wasm-gc --release ./demo/api
src="_build/wasm-gc/release/build/demo/api/api.wasm"
dst="demo/api.wasm"
cp "$src" "$dst"
sz=$(wc -c < "$dst")
gz=$(gzip -9 -c "$dst" | wc -c)
echo "demo/api.wasm: ${sz} B ($((sz / 1024)) KiB) | gzip -9: ${gz} B ($((gz / 1024)) KiB)"
echo "预览: (cd demo && python -m http.server 8000) → http://localhost:8000/demo/"
