#!/usr/bin/env python3
"""生成并测量 wasm 体积探针（wasm_probe/main/）。

本模块是纯库（无 main 包），而 MoonBit 链接期做全程序死代码消除（DCE）：
- `let _ = @pkg.fn` 裸引用会被优化器删除（测出 2.6 KB 空壳）；
- 「函数引用数组 + .length()」也会被常量折叠掉（测出 14.6 KB 胶水）。
可靠做法：用发散表达式 abort("p") 作实参**调用**每个公开函数——调用点无法被
消除，函数体及其传递闭包必须链接进产物；再用库内错误字符串（wasm 目标下
String 为 UTF-16LE）做指纹验证，确认库代码真的在产物里。

用法（cwd 任意）：
    python scripts/generate_wasm_size_probe.py           # 生成 + 编译两目标 + 报告
    python scripts/generate_wasm_size_probe.py --gen-only # 只重新生成探针源码

公共 API 变化后探针会失配（moon check 报 unbound/参数不符），重跑本脚本即可。
wasm-gc 目标下 core/v128 等目标受限函数（*_v128、av_md5_sum_x4…）会被自动剔除。
"""

import argparse
import gzip
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE_DIR = ROOT / "wasm_probe" / "main"

# 探针覆盖的库包（alias → 接口文件），与 wasm_probe/main/moon.pkg 的 import 一致
PKGS = OrderedDict([
    ("@libavutil", ROOT / "libavutil" / "pkg.generated.mbti"),
    ("@libavformat", ROOT / "libavformat" / "pkg.generated.mbti"),
    ("@libavcodec", ROOT / "libavcodec" / "pkg.generated.mbti"),
    ("@av1_mc_core", ROOT / "libavcodec" / "av1_mc_core" / "pkg.generated.mbti"),
])

MOON_PKG = """\
import {
  "ffmpeg/moonbit/libavutil",
  "ffmpeg/moonbit/libavformat",
  "ffmpeg/moonbit/libavcodec",
  "ffmpeg/moonbit/libavcodec/av1_mc_core",
}

pkgtype(kind: "executable")

warnings = "-alert_experimental"
"""

HEADER = """\
// !! 本文件由 scripts/generate_wasm_size_probe.py 生成，勿手改 !!
// 用 abort("p") 发散实参调用每个公开函数：调用点无法被 DCE 消除，
// 函数体必须链接进 wasm；main 不会真的跑完（首个调用即发散），仅测体积。
"""


def parse_blocks(mbti_path: Path):
    """把 .mbti 按 declaration 拆块（多行签名合并为单行）。"""
    text = mbti_path.read_text(encoding="utf-8")
    return [b.strip().replace("\n", " ") for b in text.split("\n\n") if b.strip()]


def split_params(block: str):
    """返回最外层括号内按逗号拆开的参数列表（含前导 '(' 前缀的修正）。"""
    i = block.index("(")
    body, depth = "", 0
    for ch in block[i + 1:]:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            if depth == 0:
                break
            depth -= 1
        if ch == "," and depth == 0:
            body += "\x00"
        else:
            body += ch
    return [p for p in body.split("\x00") if p.strip()]


def call_args(block: str):
    """按调用点语法生成实参。

    .mbti 里标签参数显示为 `label~ : T`（必选）或 `label? : T`（可选）；
    调用点语法是 `label = expr`（不带 ~）；可选参数直接省略；
    位置参数一律传 abort("p")。注意首块含 '(' 时 split_params 已剥掉。
    """
    args = []
    for p in split_params(block):
        m = re.match(r"^\s*([a-z_][A-Za-z0-9_]*)\s*([?~]?)\s*:", p)
        if m:
            if m.group(2) != "?":  # 必选标签参数
                args.append(f'{m.group(1)} = abort("p")')
        else:
            args.append('abort("p")')
    return ", ".join(args)


def collect_calls():
    """从各包 .mbti 提取公开函数，生成探针调用行。"""
    calls = []
    for alias, path in PKGS.items():
        for b in parse_blocks(path):
            m = re.match(r"pub fn ([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)", b)
            if m and not re.match(r"pub fn [A-Za-z0-9_:]+\[", b):  # 跳过泛型函数
                calls.append(f"  let _ = {alias}.{m.group(1)}({call_args(b)})")
    # pub let 数值常量在使用点内联，不占独立体积，不进探针
    return calls


def write_probe(calls):
    PROBE_DIR.mkdir(parents=True, exist_ok=True)
    (PROBE_DIR / "moon.pkg").write_text(MOON_PKG, encoding="utf-8", newline="\n")
    body = HEADER + "\nfn main() -> Unit {\n" + "\n".join(calls) + '\n  abort("end")\n}\n'
    (PROBE_DIR / "main.mbt").write_text(body, encoding="utf-8", newline="\n")


def run_moon(*args):
    return subprocess.run(["moon", *args], cwd=ROOT, capture_output=True,
                          text=True, encoding="utf-8", errors="replace")


def build_and_measure(target: str):
    """编译并测量；wasm-gc 需迭代剔除目标受限函数。返回 (wasm路径, 输出)。"""
    for rnd in range(8):
        r = run_moon("build", "--release", "--target", target, "./wasm_probe/main")
        if r.returncode == 0:
            break
        missing = sorted(set(re.findall(r"Value (\w+) not found", r.stdout + r.stderr)))
        if not missing:
            print(f"[{target}] 编译失败（非目标受限函数问题）：", file=sys.stderr)
            print((r.stdout + r.stderr)[:2000], file=sys.stderr)
            sys.exit(1)
        lines = (PROBE_DIR / "main.mbt").read_text(encoding="utf-8").splitlines()
        kept = [l for l in lines
                if not any(re.search(rf"\.{re.escape(n)}\(", l) for n in missing)]
        (PROBE_DIR / "main.mbt").write_text("\n".join(kept) + "\n",
                                            encoding="utf-8", newline="\n")
        print(f"[{target}] 第 {rnd} 轮剔除目标受限函数 {len(missing)} 个：{missing}")
    else:
        print(f"[{target}] 剔除 8 轮仍未编译通过", file=sys.stderr)
        sys.exit(1)

    wasm = ROOT / "_build" / target / "release" / "build" / "wasm_probe" / "main" / "main.wasm"
    data = wasm.read_bytes()
    gz = len(gzip.compress(data, 9))
    # 指纹：wasm 目标下 String 按 UTF-16LE 存储，ASCII grep 验证会漏判
    fp = {w: data.count(w.encode("utf-16-le")) + data.count(w.encode())
          for w in ("keyframe", "scalefactor")}
    return wasm, data, gz, fp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen-only", action="store_true", help="只生成探针源码不编译")
    args = ap.parse_args()

    calls = collect_calls()
    print(f"探针调用公开函数 {len(calls)} 个")
    write_probe(calls)
    if args.gen_only:
        print(f"已生成 {PROBE_DIR}")
        return

    for target in ("wasm", "wasm-gc"):
        wasm, data, gz, fp = build_and_measure(target)
        assert any(fp.values()), f"[{target}] 库字符串指纹缺失，疑似被 DCE 裁掉：{fp}"
        print(f"[{target}] {wasm}")
        print(f"  原始 {len(data):,} B = {len(data)/1024:.1f} KiB | "
              f"gzip -9 {gz:,} B = {gz/1024:.1f} KiB | 指纹 {fp}")


if __name__ == "__main__":
    main()
