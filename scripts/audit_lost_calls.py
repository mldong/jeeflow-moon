#!/usr/bin/env python
"""自查网：把 `git diff` 里被删掉、却在新增行里找不到的**调用/构造**列出来。

动机（本轮真实事故）：facade/facade.mbt 的 `flow` 改成 try/catch 时，
成功臂的 `ok_data(...)` 被顺手丢掉 ⇒ 出口没有 {code:0,msg} 信封 ⇒ T0 才抓到。
编译器对"少包一层"是完全无声的（类型照样是 Json），所以需要一个只认**符号是否消失**的粗网。

用法：python scripts/audit_lost_calls.py [<git diff 的 base，默认 master>]
输出按文件分组；`?` 档是人工判（多数是本来就合法的改名/换臂），但**必须逐条看完**。
"""
import io
import os
import re
import subprocess
import sys

base = sys.argv[1] if len(sys.argv) > 1 else "master"
CALL = re.compile(r"\b([a-z_][a-z0-9_]*)\s*\(")
KEEP = {"Some", "Ok", "Err", "if", "match", "for", "while", "try", "catch", "raise",
        "return", "fn", "let", "test", "is", "print", "format", "new"}
LOWER = re.compile(r"^[a-z][a-z0-9_]*$")


def diff_lines():
    out = subprocess.run(
        ["git", "diff", "--unified=0", base, "--", "*.mbt"],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    ).stdout
    cur, per = None, {}
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            cur = line[6:]
            per.setdefault(cur, {"-": [], "+": []})
            continue
        if cur is None:
            continue
        if line.startswith("-") and not line.startswith("---"):
            per[cur]["-"].append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            per[cur]["+"].append(line[1:])
    return per


def main():
    per = diff_lines()
    total = 0
    for path in sorted(per):
        minus, plus = per[path]["-"], per[path]["+"]
        if not minus or not plus:
            continue
        plus_blob = "\n".join(plus)
        minus_blob = "\n".join(minus)
        gone = []
        for m in set(CALL.findall("\n".join(minus))):
            if not LOWER.match(m) or m in KEEP:
                continue
            if not re.search(r"\b" + re.escape(m) + r"\s*\(", plus_blob):
                # 只在"确实有别的同名调用被删过"时报（避免把纯新增文件的噪声也算进来）
                if re.search(r"\b" + re.escape(m) + r"\s*\(", minus_blob):
                    gone.append(m)
        if gone:
            total += len(gone)
            print("%s  消失的调用: %s" % (path, " ".join(sorted(gone))))
    print("--- 合计 %d 个符号待人工判（0 = 本轮没有丢包装）" % total)


if __name__ == "__main__":
    main()
