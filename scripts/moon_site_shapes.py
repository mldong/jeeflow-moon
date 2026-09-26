#!/usr/bin/env python
"""给"批量改写型"警告批次列**候选改写形状**。

把每个匹配站点（默认 `.to_string()`）的左邻居截出来：先砍到上一个语句边界，
再把长标识符归一成 X，按出现次数排序。人一眼能看出哪些是 StringView 链
（`substring(..).to_string()` / `trim(..).to_string()` / split 循环项）、
哪些是 Show 用途（数字/枚举 `.to_string()`，那些**不能**跟着一起改）。

用法：python scripts/moon_site_shapes.py [正则]     # 默认 `\.to_string\(\)`
"""
import io
import os
import re
import subprocess
import sys
from collections import Counter

ROOT = os.getcwd()
PAT = re.compile(sys.argv[1] if len(sys.argv) > 1 else r"\.to_string\(\)")
BOUND = re.compile(r"[\n;{}=]")

files = [f for f in subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True,
                                   text=True).stdout.split() if ".mooncakes" not in f]
shapes = Counter()
for f in files:
    try:
        raw = io.open(os.path.join(ROOT, f), encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for m in PAT.finditer(raw):
        left = raw[max(0, m.start() - 40):m.start()]
        cut = BOUND.search("")
        last = -1
        for bm in BOUND.finditer(left):
            last = bm.end()
        frag = left[last:].strip()
        frag = re.sub(r"[A-Za-z_]\w{2,}", "X", frag)
        shapes[frag + PAT.pattern.replace("\\", "")] += 1
for k, v in shapes.most_common(40):
    print("%4d  %s" % (v, k))
