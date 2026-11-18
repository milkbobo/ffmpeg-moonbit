#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""One-shot: rewrite cross-references after the doc/ reorganisation.

Moves happened already; this only fixes *references* to the moved files:
  * markdown links  [text](target.md)      -> relative to the referring file
  * bare paths      `target.md`            -> repo-root relative

Legal files (LICENSE.md / LEGAL.md) stayed at the repo root, so they are
not in the map and are left untouched.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF = os.path.abspath(__file__)
SKIP_DIRS = {
    "_build", ".git", "_ref", ".trash", ".scratch", ".worktrees",
    ".workbuddy", ".codebuddy", "target", ".mooncakes",
}
TEXT_EXT = {".md", ".mbt", ".mbtx", ".py", ".sh", ".json", ".toml"}

HANDOFF_DIR = "doc/handoff"

# old basename -> new repo-root-relative path
MAPPING = {
    "PORTING_HISTORY.md": "doc/PORTING_HISTORY.md",
    "agent.md": "doc/agent.md",
    "项目申报书.md": "doc/项目申报书.md",
    "HEREDOC_ISSUE_REPORT.md": "doc/reports/HEREDOC_ISSUE_REPORT.md",
    # files that stayed at the repo root — still need relpath fixes for
    # documents that now live one or two levels deeper
    "README.md": "README.md",
    "LICENSE.md": "LICENSE.md",
    "LEGAL.md": "LEGAL.md",
}

# handoff-style basenames -> doc/handoff/<name>
for name in sorted(os.listdir(os.path.join(ROOT, HANDOFF_DIR))):
    if name.endswith(".md"):
        MAPPING[name] = HANDOFF_DIR + "/" + name

MD_LINK = re.compile(r"\]\(([^()\s]+\.md)(#[^()]*)?\)")
BARE_PATH = re.compile(r"`([^`\s]+\.md)`")


def to_repo_root(target: str, file_dir: str) -> str | None:
    """Normalise a link target to a repo-root-relative path if it moved.

    A target that already resolves on disk is left alone — that keeps
    same-named files such as cmd/encode-h264/README.md intact.
    """
    if target.startswith(("http://", "https://", "/", "#")):
        return None
    # already resolves relative to the referring file -> nothing to do
    probe = os.path.normpath(os.path.join(ROOT, file_dir, target))
    if os.path.exists(probe):
        return None
    base = os.path.basename(target)
    if base not in MAPPING:
        return None
    return MAPPING[base]


def rel_to(file_dir: str, repo_path: str) -> str:
    rel = os.path.relpath(os.path.join(ROOT, repo_path), os.path.join(ROOT, file_dir))
    return rel.replace(os.sep, "/")


def process(path: str, is_md: bool) -> int:
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    original = text
    file_dir = os.path.dirname(os.path.relpath(path, ROOT)).replace(os.sep, "/")
    if file_dir == ".":
        file_dir = ""

    def md_sub(m):
        target, anchor = m.group(1), m.group(2) or ""
        new = to_repo_root(target, file_dir)
        if new is None:
            return m.group(0)
        return "](" + rel_to(file_dir, new) + anchor + ")"

    def bare_sub(m):
        target = m.group(1)
        new = to_repo_root(target, file_dir)
        if new is None:
            return m.group(0)
        # bare mentions are read as repo-root paths
        return "`" + new + "`"

    text = MD_LINK.sub(md_sub, text)
    text = BARE_PATH.sub(bare_sub, text)
    if text != original:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        return 1
    return 0


def main() -> int:
    changed = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            ext = os.path.splitext(fn)[1]
            if ext not in TEXT_EXT:
                continue
            full = os.path.join(dirpath, fn)
            if os.path.abspath(full) == SELF:
                continue
            if process(full, ext == ".md"):
                changed.append(os.path.relpath(full, ROOT).replace(os.sep, "/"))
    print(f"rewritten {len(changed)} files")
    for c in sorted(changed)[:400]:
        print("  " + c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
