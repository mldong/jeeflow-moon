#!/usr/bin/env python
"""按"链上前一个调用"给 `.to_string()` 站点分类，决定哪些能整批改写。

StringView 的 `.to_string()` 才需要改 `to_owned()`；Show 用途的 `.to_string()`（数字、
枚举、Json）不能碰。区分办法就一条：`.to_string()` 左边那个调用是谁家的。
"""
import io
import os
import re
import subprocess
from collections import Counter

ROOT = os.getcwd()
CLS = [
    ("trim 链", re.compile(r"\.trim\([^()]*\)\.to_string\(\)")),
    ("substring 链", re.compile(r"\.substring\([^()]*\)\.to_string\(\)")),
    ("嵌套 substring+trim", re.compile(r"\.substring\([^()]*(?:\([^()]*\)[^()]*)*\)\.trim\([^()]*\)\.to_string\(\)")),
    ("to_owned 已有", re.compile(r"\.to_owned\(\)")),
]
files = [f for f in subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True,
                                   text=True).stdout.split() if ".mooncakes" not in f]
cnt = Counter()
other = []
for f in files:
    raw = io.open(os.path.join(ROOT, f), encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"\.to_string\(\)", raw):
        left = raw[max(0, m.start() - 90):m.start()]
        line_start = max(left.rfind("\n"), 0)
        frag = left[line_start:]
        named = None
        for name, pat in CLS:
            if pat.search(frag + ".to_string()"):
                named = name
                break
        if named:
            cnt[named] += 1
        else:
            cnt["未归类"] += 1
            if len(other) < 26:
                other.append("%s | %s" % (f, (frag + ".to_string()").strip()[:104]))
print(dict(cnt))
print("=== 未归类样例 ===")
for o in other:
    print("  ", o)
