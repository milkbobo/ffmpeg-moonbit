#!/usr/bin/env python3
"""按函数体大小排名 wasm 产物（解析 code + name section，无外部依赖）。

用法：
    python scripts/wasm_func_size_rank.py [path/to/main.wasm] [topN]
默认探针 release wasm（wasm 目标），topN=30。
函数名来自 name section（MoonBit 产物带完整限定名，可按包聚合）。
"""

import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_uleb(buf: bytes, pos: int) -> tuple[int, int]:
    """读无符号 LEB128，返回 (值, 新位置)。"""
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def parse(wasm: Path):
    data = wasm.read_bytes()
    assert data[:4] == b"\0asm", "非 wasm 文件"
    pos = 8
    funcs: list[int] = []          # code section: 各函数体字节数（按索引）
    names: dict[int, str] = {}     # name section: 索引→名称
    while pos < len(data):
        sec_id = data[pos]
        pos += 1
        size, pos = read_uleb(data, pos)
        end = pos + size
        body = data[pos:end]
        if sec_id == 10:  # code
            p = 0
            count, p = read_uleb(body, p)
            for i in range(count):
                bsize, p = read_uleb(body, p)
                funcs.append(bsize)
                p += bsize
        elif sec_id == 0:  # custom：找 name section
            p = 0
            nlen, p = read_uleb(body, p)
            if body[p:p + nlen] == b"name":
                p += nlen
                while p < len(body):
                    sub_id = body[p]
                    p += 1
                    sub_size, p = read_uleb(body, p)
                    sub = body[p:p + sub_size]
                    if sub_id == 1:  # function names
                        q = 0
                        cnt, q = read_uleb(sub, q)
                        for _ in range(cnt):
                            idx, q = read_uleb(sub, q)
                            nlen2, q = read_uleb(sub, q)
                            names[idx] = sub[q:q + nlen2].decode("utf-8", "replace")
                            q += nlen2
                    p += sub_size
        pos = end
    return funcs, names


def main():
    top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    default = ROOT / "_build/wasm/release/build/wasm_probe/main/main.wasm"
    wasm = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    funcs, names = parse(wasm)
    total = sum(funcs)
    named = [(sz, names.get(i, f"<fn#{i}>")) for i, sz in enumerate(funcs)]

    print(f"{wasm}  代码段 {len(funcs)} 函数 / {total:,} B")
    print("\n== 单函数 Top ==")
    for sz, name in sorted(named, reverse=True)[:top_n]:
        print(f"{sz:>8,}  {name}")

    print("\n== 按包聚合 ==")
    pkg_size: dict[str, int] = defaultdict(int)
    for sz, name in named:
        pkg = name.rsplit("/", 1)[0] if "/" in name else "(无名)"
        pkg_size[pkg] += sz
    for pkg, sz in sorted(pkg_size.items(), key=lambda kv: -kv[1]):
        print(f"{sz:>9,}  {pkg}")


if __name__ == "__main__":
    main()
