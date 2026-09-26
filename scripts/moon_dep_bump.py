#!/usr/bin/env python3
"""moon.mod 依赖版本 bump（字节级替换，不动行尾）。

用法: python moon_dep_bump.py <old-substr> <new-substr>
只在 5 个 */moon.mod 里替换，逐文件断言命中数，替换后打印 diff 摘要。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ["core", "persist", "repository-mysql", "facade", "demo"]


def main() -> int:
    old, new = sys.argv[1], sys.argv[2]
    total = 0
    for m in FILES:
        p = ROOT / m / "moon.mod"
        raw = p.read_bytes()
        n = raw.count(old.encode())
        if n == 0:
            print(f"  {m}/moon.mod: 0 命中（跳过）")
            continue
        p.write_bytes(raw.replace(old.encode(), new.encode()))
        total += n
        print(f"  {m}/moon.mod: {n} 处 {old} -> {new}")
    print(f"TOTAL {total}")
    return 0 if total > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
