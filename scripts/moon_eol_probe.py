#!/usr/bin/env python
"""看 .mbt 的真实行尾形状（决定 moon 报的行号能不能直接用）。"""
import io
import sys

path = sys.argv[1]
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 1
hi = int(sys.argv[3]) if len(sys.argv) > 3 else 20
raw = io.open(path, encoding="utf-8", newline="").read()
# 用 \n 切段，段尾的 \r 个数就是该行行尾的 CR 数
segs = raw.split("\n")
kinds = {}
for i, seg in enumerate(segs[:-1], 1):
    n_cr = len(seg) - len(seg.rstrip("\r"))
    kinds[n_cr] = kinds.get(n_cr, 0) + 1
    if lo <= i <= hi:
        print("%4d  cr=%d  %s" % (i, n_cr, seg.rstrip("\r")[:70]))
print("行尾 CR 数分布:", kinds, " 总段数=", len(segs))
