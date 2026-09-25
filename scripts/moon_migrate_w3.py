#!/usr/bin/env python
"""MoonBit 迁移批处理 W3：保留词改名 + derive(Show)→Debug + 测试限定名 + 删未用 import。

改名半径控制（这三条是"不能瞎替换"的边界，脚本必须守住）：
 1. 字符串字面量内不动 —— stats 的 dimension 取值就是 `"define"` 这样的契约字符串，
    改了直接改变对外行为；
 2. `#|` / `$|` 原始多行串（流程 JSON）内不动；
 3. 注释行不动（注释里的 "define 表" 是叙述，不是标识符）。
`\bdefine\b` 天然不匹配 `define_id` / `save_define(` / `ProcessDefine`（前后都是词字符）。

未用 import 由 `moon check --output-json` 的 unused_package 站点直接驱动删除，
按 (文件, 行号) 去重——同一条 import 会出两条诊断（包名 + 别名）。
"""
import glob
import io
import json
import os
import re
import sys

ROOT = os.getcwd()

RENAMES = [
    (re.compile(r"\bdefine\b"), "define_info"),
    (re.compile(r"\balias\b"), "table_alias"),
]

RAW_PREFIX = re.compile(r"^\s*(#|\$)?\|")          # 原始多行串续行
COMMENT = re.compile(r"^\s*//")                    # 注释行
CODE_SEG_SPLIT = re.compile(r'("(?:[^"\\]|\\.)*")')  # 引号段


def transform_line(line):
    if COMMENT.match(line) or RAW_PREFIX.match(line):
        return line
    if '"' not in line:
        for pat, rep in RENAMES:
            line = pat.sub(rep, line)
        return line
    parts = CODE_SEG_SPLIT.split(line)
    # split 带捕获组：偶数段=代码，奇数段=字符串字面量
    for i in range(0, len(parts), 2):
        for pat, rep in RENAMES:
            parts[i] = pat.sub(rep, parts[i])
    return "".join(parts)


def mbt_files():
    for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
        norm = path.replace("\\", "/")
        if "_build/" in norm or "/.mooncakes/" in norm:
            continue
        yield path


def step_renames():
    per_file = {}
    for path in mbt_files():
        src = io.open(path, encoding="utf-8", newline="").read()
        crlf = "\r\n" in src
        lines = src.replace("\r\n", "\n").split("\n")
        out = [transform_line(l) for l in lines]
        n = sum(1 for a, b in zip(lines, out) if a != b)
        if n:
            io.open(path, "w", encoding="utf-8", newline="").write(
                "\r\n".join(out) if crlf else "\n".join(out))
            per_file[os.path.relpath(path, ROOT)] = n
    print("① 保留词改名行数:", sum(per_file.values()), "文件:", len(per_file))
    for f, n in sorted(per_file.items(), key=lambda x: -x[1])[:8]:
        print("   %3d  %s" % (n, f))


def step_derive_debug():
    n = 0
    for path in mbt_files():
        src = io.open(path, encoding="utf-8", newline="").read()
        if "derive(Eq, Show)" in src:
            c = src.count("derive(Eq, Show)")
            io.open(path, "w", encoding="utf-8", newline="").write(
                src.replace("derive(Eq, Show)", "derive(Eq, Debug)"))
            n += c
    print("② derive(Eq, Show) → derive(Eq, Debug):", n, "处")


def step_test_qualify():
    # 新工具链把 *_test.mbt 当外部测试包编译：私有名不可见，必须限定包名
    n = 0
    for path in mbt_files():
        if not path.endswith("_test.mbt"):
            continue
        src = io.open(path, encoding="utf-8", newline="").read()
        if "parse_tz_offset_seconds(" in src and "@jeeflow-demo." not in src:
            c = src.count("parse_tz_offset_seconds(")
            io.open(path, "w", encoding="utf-8", newline="").write(
                src.replace("parse_tz_offset_seconds(", "@jeeflow-demo.parse_tz_offset_seconds("))
            n += c
    print("③ 测试限定名站点:", n)


def step_unused_imports(diag):
    if not os.path.exists(diag):
        print("④ 跳过（无 diag.json）")
        return
    targets = set()
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        if d.get("$message_type") != "diagnostic":
            continue
        if "Unused package" not in (d.get("message") or ""):
            continue
        p = (d.get("path") or "").replace("\\", "/")
        loc = (d.get("loc") or "").split("-")[0].split(":")
        if len(loc) < 2:
            continue
        targets.add((p, int(loc[0])))
    removed = {}
    for p, lineno in sorted(targets):
        if not os.path.exists(p):
            continue
        lines = io.open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n").split("\n")
        i = lineno - 1
        if i < 0 or i >= len(lines):
            continue
        text = lines[i]
        # 只删 import 块里的单行条目，其它形状（多行/带注释）留人工
        if not re.match(r'^\s*"[^"]+"(\s+@\w+)?,\s*$', text):
            print("   跳过（形状不典型）:", p, lineno, text.strip())
            continue
        rel = os.path.relpath(p, ROOT)
        removed.setdefault(rel, [])
        if lineno not in removed[rel]:
            removed[rel].append(lineno)
    total = 0
    for rel, lns in removed.items():
        path = os.path.join(ROOT, rel)
        crlf = "\r\n" in io.open(path, encoding="utf-8", newline="").read()
        lines = io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n").split("\n")
        for ln in sorted(lns, reverse=True):
            del lines[ln - 1]
            total += 1
        io.open(path, "w", encoding="utf-8", newline="").write(
            "\r\n".join(lines) if crlf else "\n".join(lines))
    print("④ 删除未用 import 行:", total, "涉及文件:", len(removed))


def main():
    step_renames()
    step_derive_debug()
    step_test_qualify()
    step_unused_imports(sys.argv[1] if len(sys.argv) > 1 else "/tmp/diag.json")


if __name__ == "__main__":
    main()
