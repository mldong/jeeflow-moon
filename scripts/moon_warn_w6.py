#!/usr/bin/env python
"""警告批次 W6：deprecated 大类的**按形状改写 + 一条一验**驱动器。

为什么按形状而不是按位置：本仓 .mbt 的 blob 是 `\r\r\n` 行尾，moon 诊断给的行号偏大
（实测报 145 实为 112），列号虽然真但没有行就没法定位到行 ⇒ 位置这条路已在 W3 证伪。
剩下的可靠依据是**改写模式本身**：编译器消息里写了替代写法（StringView 的 `.to_string()`
→ `to_owned()`），所以按"链上前一个调用是谁家"整批改，然后：
  · 每改一批跑一遍全工程 check；
  · error>0 ⇒ 整批回滚（说明这批里混进了不该改的，比如 Show 用途的 `n.to_string()`）；
  · deprecated 数不降 ⇒ 回滚（改到的是没被点名的形状，白改还可能改坏语义）。

用法：python scripts/moon_warn_w6.py [模式序号 ...]      # 不给序号=全跑一遍
"""
import io
import json
import os
import re
import subprocess
import sys

ROOT = os.getcwd()
MOON = r"G:/dev-tools/moon/bin/moon.exe"
ENV = dict(os.environ, MOON_HOME=r"G:/dev-tools/moon",
           PATH=r"G:/dev-tools/moon/bin;" + os.environ.get("PATH", ""))

# 一维数组的正则/替换；group(1) 是"链上前缀"，替换只把尾巴换成 to_owned()
PATTERNS = [
    ("P1 trim 链 .to_string() → .to_owned()",
     re.compile(r"(\.trim\([^()]*\))\.to_string\(\)"), r"\1.to_owned()"),
    ("P2 substring 链（含一层嵌套括号）",
     re.compile(r"(\.substring\((?:[^()]|\([^()]*\))*\))\.to_string\(\)"), r"\1.to_owned()"),
    ("P3 数字字面量结尾的 substring 简写（start= 后带算式）",
     re.compile(r"(\.substring\((?:[^()]|\([^()]*\))*\))\.to_string\(\)"), r"\1.to_owned()"),
]


def files():
    return [f for f in subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True,
                                      text=True).stdout.split() if ".mooncakes" not in f]


def check():
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    errs = warns = dep = 0
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message", "")
        if d.get("level") == "error":
            errs += 1
        else:
            warns += 1
            if m.startswith("Warning (deprecated)"):
                dep += 1
    return errs, warns, dep




def main():
    picks = [int(x) for x in sys.argv[1:] if x.isdigit()]
    e0, w0, d0 = check()
    print("基线 err=%d warn=%d deprecated=%d" % (e0, w0, d0))
    for idx, (label, pat, rep) in enumerate(PATTERNS, 1):
        if picks and idx not in picks:
            continue
        snapshot = {}
        total = 0
        for f in files():
            raw = io.open(os.path.join(ROOT, f), encoding="utf-8", newline="").read()
            new, n = pat.subn(rep, raw)
            if n:
                snapshot[f] = raw
                io.open(os.path.join(ROOT, f), "w", encoding="utf-8", newline="").write(new)
                total += n
        if not total:
            print("%-56s 命中 0 ⇒ 跳过" % label)
            continue
        e, w, d = check()
        if e > 0 or d >= d0:
            for f, raw in snapshot.items():
                io.open(os.path.join(ROOT, f), "w", encoding="utf-8", newline="").write(raw)
            check()
            print("%-56s 命中 %-3d ⇒ 回滚（err=%d deprecated %d→%d）" % (label, total, e, d0, d))
        else:
            print("%-56s 命中 %-3d ⇒ 保留（deprecated %d→%d，warn %d→%d）"
                  % (label, total, d0, d, w0, w))
            d0, w0 = d, w
    print("收尾 err=%d warn=%d deprecated=%d" % (e0, w0, d0))


if __name__ == "__main__":
    main()
