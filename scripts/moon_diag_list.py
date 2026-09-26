#!/usr/bin/env python
"""小工具：把 `moon check --output-json` 的诊断流按 level 打印（默认只看 error）。

用法：python scripts/moon_diag_list.py <diag.json> [error|warning|all]
"""
import io
import json
import os
import sys

ROOT = os.getcwd()


def load(path):
    recs = []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            recs.append(json.loads(line))
        except ValueError:
            pass
    return recs


def main():
    path = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else "error"
    recs = load(path)
    errs = [d for d in recs if d.get("level") == "error"]
    warns = [d for d in recs if d.get("level") != "error"]
    print("errors=%d warnings=%d total=%d" % (len(errs), len(warns), len(recs)))
    sel = {"error": errs, "warning": warns, "all": recs}[want]
    for d in sel:
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        msg = d["message"].replace("\n", " / ")
        print("%s:%s | %s" % (p, d.get("loc", ""), msg[:170]))


if __name__ == "__main__":
    main()
