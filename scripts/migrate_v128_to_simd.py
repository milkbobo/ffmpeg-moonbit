"""MoonBit 1.0 migration helper: core/v128 -> core/simd.

Rewrites `@v128.` -> `@simd.` in .mbt sources and
"moonbitlang/core/v128" -> "moonbitlang/core/simd" in moon.pkg files.
Skips build dirs, .trash, .mooncakes, .worktrees and other agent scratch dirs.
"""

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

dry_run = "--apply" not in sys.argv

mbt_changes: list[tuple[Path, int]] = []
pkg_changes: list[tuple[Path, int]] = []


def iter_files(suffix: str):
    for p in ROOT.rglob(suffix):
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts[:-1]):
            continue
        yield p


for path in iter_files("*.mbt"):
    text = path.read_text(encoding="utf-8")
    if "@v128." not in text:
        continue
    count = text.count("@v128.")
    mbt_changes.append((path, count))
    if not dry_run:
        path.write_text(text.replace("@v128.", "@simd."), encoding="utf-8", newline="")

for path in iter_files("moon.pkg"):
    text = path.read_text(encoding="utf-8")
    if "moonbitlang/core/v128" not in text:
        continue
    count = text.count("moonbitlang/core/v128")
    pkg_changes.append((path, count))
    if not dry_run:
        path.write_text(
            text.replace("moonbitlang/core/v128", "moonbitlang/core/simd"),
            encoding="utf-8",
            newline="",
        )

print(f"{'[dry-run] ' if dry_run else ''}mbt files: {len(mbt_changes)}, "
      f"references: {sum(c for _, c in mbt_changes)}")
print(f"{'[dry-run] ' if dry_run else ''}moon.pkg files: {len(pkg_changes)}, "
      f"references: {sum(c for _, c in pkg_changes)}")
for path, count in mbt_changes + pkg_changes:
    print(f"  {path.relative_to(ROOT)} ({count})")
