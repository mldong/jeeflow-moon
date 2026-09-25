#!/usr/bin/env python
"""容忍式补丁：本仓部分 .mbt 的 blob 带 `\r\r\n`（历史行尾分叉），普通字符串匹配会因
残留 `\r` 落空。这里把搜索串换行编译成 `\r*` + 换行，命中数必须恰好 1 才动手。

用法：脚本里写 PAIRS，或 `python scripts/moon_patch.py`（自测驱动）。
"""
import io
import re
import sys


def tolerant(old):
    parts = [re.escape(seg) for seg in old.split("\n")]
    body = r"(?:\r*\n)+".join(parts)      # 行间允许任意个 CR 与换行
    return re.compile(body)


def patch(path, pairs, verbose=True):
    raw = io.open(path, encoding="utf-8", newline="").read()
    out = raw
    done = 0
    for old, new in pairs:
        pat = tolerant(old)
        hits = pat.findall(out)
        if len(hits) != 1:
            print("!! 命中 %d 次（需恰好 1）: %s :: %s" % (
                len(hits), path, old.split("\n")[0][:70]))
            sys.exit(1)
        # 匹配到的原文里换行形状是什么，就按同样形状缩进对齐：直接把 new 的行间用命中首行的行尾拼回
        eol = "\r\n" if hits[0].endswith("\r\n") else "\n"
        repl = new.replace("\n", eol)
        out = pat.sub(lambda _m: repl, out, count=1)
        done += 1
    if out != raw:
        io.open(path, "w", encoding="utf-8", newline="").write(out)
    if verbose:
        print("patched", path, done, "处")
    return out
