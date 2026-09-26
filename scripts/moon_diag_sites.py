#!/usr/bin/env python
"""按警告类别打印站点清单：路径 + 报告位置 + **真实源码行**（取自诊断的 context 中间行）。

为什么要 context：本仓 .mbt 的 blob 行尾是 `\r\r\n`（`.gitattributes` 里 `* -text` 不做转换），
moon 的行计数器对这种行尾会给出偏大的行号，但 context 里的源码文本是真的 ⇒
用文本定位、用列号对齐，比信行号可靠。

用法：python scripts/moon_diag_sites.py <diag.json> [类别关键字 ...]
不带类别则打印所有类别的计数。
"""
import io
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.getcwd()


def main():
    path = sys.argv[1]
    keys = sys.argv[2:]
    by = defaultdict(list)
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("level") == "error":
            continue
        m = d["message"]
        mm = re.match(r"Warning \((\w+)\)", m)
        cls = mm.group(1) if mm else "other"
        # context 形如 "143 |\n144 |\n145 |"；取带内容的那几行
        src = []
        for c in d.get("context", "").splitlines():
            t = re.sub(r"^\s*\d+\s*\|\s?", "", c).rstrip()
            if t:
                src.append(t)
        by[cls].append((os.path.relpath(d["path"], ROOT).replace(os.sep, "/"),
                        d.get("loc", ""), src, m))
    if not keys:
        for c in sorted(by, key=lambda k: -len(by[k])):
            print("%4d  %s" % (len(by[c]), c))
        return
    for c in keys:
        print("#### %s (%d)" % (c, len(by.get(c, []))))
        for p, loc, src, msg in by.get(c, []):
            first = msg.split("\n")[0]
            first = re.sub(r"^Warning \(\w+\):\s*", "", first)
            print("  %s:%s" % (p, loc))
            print("      msg : %s" % first[:150])
            for s in src[:3]:
                print("      src : %s" % s[:150])


if __name__ == "__main__":
    main()
