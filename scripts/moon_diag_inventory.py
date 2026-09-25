#!/usr/bin/env python
"""MoonBit 迁移工作台账：读 `moon check --output-json` 的诊断流，按类别/消息出站点清单。

为什么走 JSON：moon 0.1.20260920 的人类可读渲染在部分诊断上会 panic
（`thread panicked ... ariadne ... Label start is after its end`），
`--output-json` 不受影响，且位置是结构化的，批处理脚本可以直接消费。

用法：
  moon check --target wasm --output-json > /tmp/diag.json
  python scripts/moon_diag_inventory.py /tmp/diag.json [--cat try_question]
"""
import io
import json
import os
import sys
from collections import Counter

ROOT = os.getcwd()

# 消息首行 → 稳定的类别键（便于 --cat 过滤）
ALIASES = {
    "`try?` is deprecated.": "try_question",
    "Use `Map([], capacity=...)` instead": "map_new",
    "The word `define` is reserved for possible future use. Please consider": "kw_define",
    "The word `alias` is reserved for possible future use. Please consider": "kw_alias",
    "The word `method` is reserved for possible future use. Please consider": "kw_method",
    "This trait bound is unused.": "unused_trait_bound",
    "Unused package": "unused_package",
}


def load(path):
    recs = []
    with io.open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("$message_type") != "diagnostic":
                continue
            msg = (d.get("message") or "").split("\n")[0].strip()
            for k, v in ALIASES.items():
                if msg.startswith(k):
                    msg = v
                    break
            recs.append({
                "level": d.get("level"),
                "code": d.get("error_code"),
                "path": (d.get("path") or "").replace("\\", "/"),
                "loc": d.get("loc") or "",
                "msg": msg,
                "full": (d.get("message") or "").replace("\n", " ")[:400],
            })
    return recs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/diag.json"
    want_cat = None
    if "--cat" in sys.argv:
        want_cat = sys.argv[sys.argv.index("--cat") + 1]
    recs = load(path)
    errors = [r for r in recs if r["level"] == "error"]
    print("诊断总数:", len(recs), "| error:", len(errors))
    if errors:
        print("\n== error 站点（必须先清零）==")
        for r in errors[:40]:
            print("  %s:%s  [%s] %s" % (
                os.path.relpath(r["path"], ROOT), r["loc"], r["code"], r["msg"][:90]))
    print("\n== 按 (code, 消息) ==")
    for (code, msg), n in Counter((r["code"], r["msg"][:64]) for r in recs).most_common():
        print("  %-5s %3d  %s" % (code, n, msg))
    if want_cat:
        print("\n== 类别 %s 的站点 ==" % want_cat)
        for r in recs:
            if want_cat in r["msg"]:
                print("  %s:%s" % (os.path.relpath(r["path"], ROOT), r["loc"]))
    out = os.path.join(ROOT, "moon_diag_sites.tsv")
    with io.open(out, "w", encoding="utf-8", newline="") as f:
        f.write("level\tcode\tfile\tloc\tmsg\n")
        for r in recs:
            f.write("%s\t%s\t%s\t%s\t%s\n" % (
                r["level"], r["code"], os.path.relpath(r["path"], ROOT),
                r["loc"], r["msg"].replace("\t", " ")))
    print("\n站点清单已写:", out)


if __name__ == "__main__":
    main()
