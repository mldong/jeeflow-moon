#!/usr/bin/env python
"""批量改警告之前先量一句：**报告行号到底准不准**。

本仓 .mbt 的 blob 行尾是 `\r\r\n`（.gitattributes `* -text` 不转换），moon 的行计数器对这种
文件给出的行号会偏（W3 实测：core/engine/engine.mbt 报 145、实为 112）。所以拿诊断做批量
改写前，必须先测"按报告行号去取源码，能不能取到被点名的那段文本"——
命中率决定这一类能不能用「行+列」配对；命中不了的就得换招（context / 编译器当验收人）。

用法：python scripts/moon_diag_line_accuracy.py <diag.json> [文本片段 ...]
不带片段时按 error_code/message 首行分组统计。
"""
import io
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.getcwd()


def read(path):
    raw = io.open(path, encoding="utf-8", newline="").read()
    return [s.rstrip("\r") for s in raw.split("\n")]


def main():
    diag = sys.argv[1]
    needles = sys.argv[2:]
    stat = defaultdict(lambda: [0, 0, []])
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msg = d.get("message", "")
        m = re.match(r"(\d+):(\d+)-(\d+):(\d+)", d.get("loc", ""))
        if not m:
            continue
        rl, c1 = int(m.group(1)), int(m.group(2))
        needle = next((n for n in needles if n in msg), None)
        if needles and needle is None:
            continue
        key = needle or re.sub(r"^Warning \(\w+\):\s*", "", msg.split("\n")[0])[:60]
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        if not os.path.exists(p):
            continue
        lines = read(p)
        ok = bool(needle) and rl - 1 < len(lines) and needle in lines[rl - 1]
        s = stat[key]
        s[0] += 1
        if ok or not needles:
            s[1] += 1
        elif len(s[2]) < 4:
            s[2].append("%s:%d ⇒ %s" % (p, rl, (lines[rl - 1] if rl - 1 < len(lines) else "<EOF>")[:80]))
    for k in sorted(stat, key=lambda x: -stat[x][0]):
        n, hit, miss = stat[k]
        print("%4d 条  行内含点名文本 %s  | %s" % (n, ("%d/%d" % (hit, n)) if needles else "-", k))
        for x in miss:
            print("        非命中样例:", x)


if __name__ == "__main__":
    main()
