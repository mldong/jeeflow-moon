#!/usr/bin/env python
"""MoonBit 迁移批处理 W1：纯 1:1 改名（字符串字面量内不动）。

安全前提：只在"引号外"的区段做替换；改完必须 `moon check` + `moon test` 复验。
"""
import glob
import io
import os
import re
import sys

ROOT = os.getcwd()

# 引号外的区段才动：按 " 与 \\" 切分，偶数段是代码、奇数段是字符串字面量
def transform_line(line, rules):
    if '"' not in line:
        out = line
        for pat, rep in rules:
            out = pat.sub(rep, out)
        return out, out != line
    parts = re.split(r'("(?:[^"\\]|\\.)*")', line)
    changed = False
    for i in range(0, len(parts), 2):   # 偶数段 = 代码
        seg = parts[i]
        for pat, rep in rules:
            new = pat.sub(rep, seg)
            if new != seg:
                seg = new
                changed = True
        parts[i] = seg
    return "".join(parts), changed


def build_rules():
    rules = [
        # var x = e  →  let mut x = e
        (re.compile(r"^(\s*)var\s+([A-Za-z_][\w]*)\s*="), r"\1let mut \2 ="),
        # StringBuilder::new() → StringBuilder()
        (re.compile(r"StringBuilder::new\(\)"), "StringBuilder()"),
        # Ref::new(x) → Ref(x)
        (re.compile(r"\bRef::new\("), "Ref("),
        # starts_with / ends_with → has_prefix / has_suffix
        (re.compile(r"\.starts_with\("), ".has_prefix("),
        (re.compile(r"\.ends_with\("), ".has_suffix("),
        # .size() → .length()（本轮 6 站点全是 Map/对象图大小）
        (re.compile(r"\.size\(\)"), ".length()"),
        # not(x) → !(x)  —— 仅简单形参（脚本不解析嵌套括号，剩余人工看）
        (re.compile(r"\bnot\(([^()]*)\)"), r"!(!\1)" ),  # 占位：下面立刻被真实规则覆盖
    ]
    # 上面的 not() 规则故意保守：只处理无嵌套括号的实参，且保留语义取反一次
    rules[-1] = (re.compile(r"\bnot\(([^()]*)\)"), r"!(\1)")
    return rules


def main():
    rules = build_rules()
    touched = {}
    for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
        if "_build" in path or "/.mooncakes/" in path or os.sep + ".mooncakes" + os.sep in path:
            continue
        src = io.open(path, encoding="utf-8", newline="").read()
        out_lines = []
        n = 0
        for line in src.split("\n"):
            new, ch = transform_line(line, rules)
            out_lines.append(new)
            if ch:
                n += 1
        if n:
            io.open(path, "w", encoding="utf-8", newline="").write("\n".join(out_lines))
            touched[os.path.relpath(path, ROOT)] = n
    total = sum(touched.values())
    print("W1 改写行数:", total, "涉及文件:", len(touched))
    for f, n in sorted(touched.items(), key=lambda x: -x[1])[:20]:
        print("  %3d  %s" % (n, f))
    # 残留自查：还有没有 var 声明 / 老 API 名字（防漏）
    print("\n== 残留自查 ==")
    for name, pat in [
        ("var 声明", r"^\s*var\s+\w+\s*="),
        ("StringBuilder::new", r"StringBuilder::new\("),
        ("Ref::new", r"Ref::new\("),
        ("starts_with", r"\.starts_with\("),
        ("ends_with", r"\.ends_with\("),
        (".size()", r"\.size\(\)"),
        ("not(", r"\bnot\("),
    ]:
        hits = []
        for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
            if "_build" in path or ".mooncakes" in path:
                continue
            for i, line in enumerate(io.open(path, encoding="utf-8", errors="replace")):
                if re.search(pat, line):
                    hits.append("%s:%d" % (os.path.relpath(path, ROOT), i + 1))
        print("  %-18s 残留 %d %s" % (name, len(hits), hits[:3]))


if __name__ == "__main__":
    main()
