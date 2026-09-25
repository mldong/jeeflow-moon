#!/usr/bin/env python
"""MoonBit 迁移批处理 W4：`try?` 编译器驱动分类。

新语义下 `try?` 的两类用途必须分开：
  - 纯传播 ⇒ 直接调用（外层函数已标 raise）；
  - 需要 Ok|Err 两态（断言/回退/转成本域错误）⇒ @error.attempt(fn() { ... })。
分不清就别用正则猜：本脚本先**全摘**，让编译器把"这里真的要 Result"的站点
以 error 形式点出来，第二步再定点包 attempt。
"""
import glob
import io
import json
import os
import re
import sys

ROOT = os.getcwd()
SEP = chr(92)  # 反斜杠：避开 heredoc/转义链对字面量的破坏


def mbt_files():
    for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
        norm = path.replace(SEP, "/")
        if "_build/" in norm or "/.mooncakes/" in norm:
            continue
        yield path


def read(path):
    src = io.open(path, encoding="utf-8", newline="").read()
    return src.replace(SEP + "\r\n", "\n").replace("\r\n", "\n"), ("\r\n" in src)


def write(path, lines, crlf):
    io.open(path, "w", encoding="utf-8", newline="").write(
        "\r\n".join(lines) if crlf else "\n".join(lines))


def step_strip():
    n = 0
    per_file = {}
    for path in mbt_files():
        src, crlf = read(path)
        if "try?" not in src:
            continue
        lines = src.split("\n")
        c = 0
        for i, l in enumerate(lines):
            if "try?" in l:
                lines[i] = re.sub(r"try\?\s*", "", l)
                c += 1
        if c:
            write(path, lines, crlf)
            per_file[os.path.relpath(path, ROOT)] = c
            n += c
    print("W4① 摘除 try? 行数:", n, "文件:", len(per_file))
    for f, c in sorted(per_file.items(), key=lambda x: -x[1])[:10]:
        print("   %3d  %s" % (c, f))
    return n


def step_report_errors(diag):
    if not os.path.exists(diag):
        print("W4② 跳过（缺诊断文件）")
        return
    errs = []
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        if d.get("$message_type") != "diagnostic" or d.get("level") != "error":
            continue
        p = (d.get("path") or "").replace(SEP, "/")
        loc = (d.get("loc") or "").split("-")[0]
        errs.append((os.path.relpath(p, ROOT), loc, (d.get("message") or "").split("\n")[0][:110]))
    print("W4② 摘除后 error 站点（= 真正需要 attempt 的地方）:", len(errs))
    for f, loc, msg in errs:
        print("   %s:%s  %s" % (f, loc, msg))
    out = os.path.join(ROOT, "w4_need_attempt.tsv")
    with io.open(out, "w", encoding="utf-8", newline="") as f:
        for e in errs:
            f.write("%s\t%s\t%s\n" % e)
    print("   清单已写:", out)


def main():
    if "report" in sys.argv:
        idx = sys.argv.index("report")
        diag = sys.argv[idx + 1] if len(sys.argv) > idx + 1 else ".tmp/diag.json"
        step_report_errors(diag)
    else:
        step_strip()


if __name__ == "__main__":
    main()
