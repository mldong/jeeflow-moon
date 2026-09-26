#!/usr/bin/env python
"""打印诊断流里指定 error_code / 关键字的完整记录（含 context 上下文行）。

用法：python scripts/moon_diag_show.py <diag.json> <path 子串> [<loc 行号下限>]
"""
import io
import json
import os
import sys

ROOT = os.getcwd()


def main():
    path, needle = sys.argv[1], sys.argv[2]
    lo = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        p = os.path.relpath(d.get("path", ""), ROOT).replace(os.sep, "/")
        if needle not in p:
            continue
        ln = int(d.get("loc", "0").split(":")[0].split("-")[0] or 0)
        if ln < lo:
            continue
        print("=" * 70)
        print("%s:%s [%s] code=%s" % (p, d.get("loc"), d.get("level"), d.get("error_code")))
        print(d.get("message", ""))
        ctx = d.get("context", "")
        if ctx:
            print("--- context ---")
            print(ctx)


if __name__ == "__main__":
    main()
