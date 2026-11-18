#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check that every relative markdown link in the repo resolves on disk."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {
    "_build", ".git", "_ref", ".trash", ".scratch", ".worktrees",
    ".workbuddy", ".codebuddy", "target", ".mooncakes",
}
MD_LINK = re.compile(r"\]\(([^()\s]+\.md)(#[^()]*)?\)")
BARE_PATH = re.compile(r"`([^`\s]+\.md)`")

broken = []
checked = 0

for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
        with open(full, "r", encoding="utf-8") as fh:
            text = fh.read()
        file_dir = os.path.dirname(rel)
        for m in MD_LINK.finditer(text):
            target = m.group(1)
            if target.startswith(("http://", "https://", "/")):
                continue
            checked += 1
            probe = os.path.normpath(os.path.join(ROOT, file_dir, target))
            if not os.path.exists(probe):
                line = text[: m.start()].count("\n") + 1
                broken.append(f"{rel}:{line} -> {target}")
        for m in BARE_PATH.finditer(text):
            target = m.group(1)
            if target.startswith(("http://", "https://", "/")):
                continue
            if os.path.basename(target) != target:
                continue  # already repo-root relative
            checked += 1
            probe = os.path.normpath(os.path.join(ROOT, file_dir, target))
            if not os.path.exists(probe) and not os.path.exists(
                os.path.join(ROOT, target)
            ):
                line = text[: m.start()].count("\n") + 1
                broken.append(f"{rel}:{line} -> `{target}` (bare)")

print(f"checked {checked} references")
if broken:
    print(f"BROKEN: {len(broken)}")
    for b in broken[:60]:
        print("  " + b)
    sys.exit(1)
print("all references resolve")
