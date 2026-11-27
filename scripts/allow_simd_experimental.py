"""Add the MoonBit 1.0 `allow-experimental-packages` acknowledgement for
`moonbitlang/core/simd` to every moon.pkg that imports it."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {
    "_build",
    ".trash",
    ".mooncakes",
    ".worktrees",
    ".git",
    ".scratch",
    ".zwork",
    ".zcode",
    ".openseek",
    ".workbuddy",
    ".codebuddy",
    "scratch",
    "_ref",
    "ffref",
}

LINE = '  "allow-experimental-packages": [ "moonbitlang/core/simd" ],'
dry_run = "--apply" not in sys.argv

changed = []
for path in ROOT.rglob("moon.pkg"):
    if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts[:-1]):
        continue
    text = path.read_text(encoding="utf-8")
    if "moonbitlang/core/simd" not in text or "allow-experimental-packages" in text:
        continue
    lines = text.splitlines()
    try:
        idx = next(i for i, line in enumerate(lines) if line.strip() == "options(")
    except StopIteration:
        new = text.rstrip("\n") + "\n\noptions(\n" + LINE + "\n)\n"
    else:
        new_lines = lines[: idx + 1] + [LINE] + lines[idx + 1 :]
        new = "\n".join(new_lines) + "\n"
    changed.append(path)
    if not dry_run:
        path.write_text(new, encoding="utf-8", newline="")

print(f"{'[dry-run] ' if dry_run else ''}{len(changed)} moon.pkg updated")
for p in changed:
    print("  " + str(p.relative_to(ROOT)))
