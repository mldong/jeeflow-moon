#!/usr/bin/env python
"""警告批次 W4a：三类"编译器把替代写法写在消息里"的小形状，共 6 处。

  - `@env.now().to_int64()`  → `@env.now().reinterpret_as_int64()`      （UInt64→Int64 的
    按位重解释本来就该用 reinterpret；`to_int64` 已弃办）
    ⚠ 这是**默认钟臂**上的那一行：换写法必须逐字节等价，收口时用 consistency/moon.json
      的逐字节比对兜（不注入 ⇒ 走的就是这条臂）。
  - `Char::from_int(expr)`   → `(expr).unsafe_to_char()`               （5 处，全在
    snake/camel 互转的 ASCII 位移里；表达式带二元运算 ⇒ 括号留着，不改语义）

用法：python scripts/moon_warn_w4a.py
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PAIRS = [
    ("core/model/clock.mbt", r"@env\.now\(\)\.to_int64\(\)", "@env.now().reinterpret_as_int64()"),
]
FROM_INT = [
    "core/model/util.mbt", "facade/facade.mbt", "facade/outbound.mbt",
    "repository-mysql/query/query.mbt",
]
CI = re.compile(r"Char::from_int\(([^()]*)\)")


def read(path):
    return io.open(path, encoding="utf-8", newline="").read()


def write(path, s):
    io.open(path, "w", encoding="utf-8", newline="").write(s)


def main():
    n = 0
    for path, pat, rep in PAIRS:
        s = read(path)
        hits = len(re.findall(pat, s))
        if hits != 1:
            sys.exit("!! %s 期望 1 处命中，实得 %d（先看现场再动）" % (path, hits))
        write(path, re.sub(pat, rep, s, count=1))
        print("%-34s 1 处 ⇒ %s" % (path, rep))
        n += 1
    for path in FROM_INT:
        s = read(path)
        hits = CI.findall(s)
        if not hits:
            sys.exit("!! %s 没有 Char::from_int" % path)
        s2 = CI.sub(lambda m: "(%s).unsafe_to_char()" % m.group(1), s)
        write(path, s2)
        print("%-34s %d 处 ⇒ unsafe_to_char：%s" % (path, len(hits), " / ".join(x.strip() for x in hits)))
        n += len(hits)
    print("合计改写", n, "处")


if __name__ == "__main__":
    main()
