#!/usr/bin/env python
"""警告批次 W9：按**列号锚定**清掉剩余 StringView `.to_string()`。

到这一类时不再需要"整批试/逐站试"：编译器已经说了接收者是 StringView
（消息就是 Use `to_owned` to allocate an owned String from a StringView），
要变的只有方法名。剩下的问题只有"是哪一行"——
行号在本仓不可信（`\r\r\n`），但**列号可信**，而被点名的 token 是 `to_string`（9 字符）。
于是配对条件收紧成三件同时成立：
  1) 该行第 col 列起正好是 `to_string`；
  2) 该处文本正好是 `.to_string()`（前面有 `.`）；
  3) 全文件满足 1+2 的行**恰好一条**（多于一条就 ambiguity，不猜，交人工）。

用法：python scripts/moon_warn_w9.py <diag.json> [--dry]
"""
import io
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.getcwd()
TOKEN = "to_string"


def warns(diag):
    out = defaultdict(list)
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message", "")
        if not m.startswith("Warning (deprecated)") or "from a StringView" not in m:
            continue
        lm = re.match(r"(\d+):(\d+)-(\d+):(\d+)", d["loc"])
        rl, col = int(lm.group(1)), int(lm.group(2))
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        out[p].append((rl, col))
    return out


def main():
    diag = sys.argv[1]
    dry = "--dry" in sys.argv
    n = amb = 0
    for path, items in sorted(warns(diag).items()):
        raw = io.open(os.path.join(ROOT, path), encoding="utf-8", newline="").read()
        parts = raw.split("\n")
        used = set()
        for rl, col in sorted(items):
            idx = [i for i, s in enumerate(parts)
                   if s.rstrip("\r")[col - 1: col - 1 + len(TOKEN)] == TOKEN
                   and s.rstrip("\r")[col - 2: col - 1] == "."]
            if not idx:
                amb += 1
                print("  落空 %-38s 第 %d 列 0 命中 ⇒ 交人工" % (path, col))
                continue
            # 先按"报告行 + 列"整对：本轮实测 facade/facade.mbt 与 query.mbt 里
            # 被 W1/W6 重写过的区段行尾已回到 CRLF/LF，那几处报告行号就是真行号。
            pick = rl - 1 if (rl - 1) in idx else None
            if pick is None:
                free = [i for i in idx if i not in used]
                if len(free) != 1:
                    amb += 1
                    print("  歧义 %-38s 第 %d 列命中 %d 行（报告行 %d 不在其中）⇒ 交人工"
                          % (path, col, len(idx), rl))
                    continue
                pick = free[0]
            used.add(pick)
            i = pick
            crs = parts[i][len(parts[i].rstrip("\r")):]
            body = parts[i].rstrip("\r")
            new = body[: col - 1] + "to_owned" + body[col - 1 + len(TOKEN):]
            parts[i] = new + crs
            n += 1
            print("  %-40s L%-4d col%-4d %s" % (path, i + 1, col, new.strip()[:92]))
        if not dry:
            io.open(os.path.join(ROOT, path), "w", encoding="utf-8", newline="").write(
                "\n".join(parts))
    print("改写 %d 处、歧义 %d 处%s" % (n, amb, "（--dry 未落盘）" if dry else ""))


if __name__ == "__main__":
    main()
