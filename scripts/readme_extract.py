#!/usr/bin/env python3
"""README 围栏块抽取器（readme-check.sh 的解析腿，只做解析，不跑命令）。

用法：python scripts/readme_extract.py <module>/README.md <outdir>

从页面里取四样东西，取不到程序块就 exit 1（＝这一页没教怎么跑）：
  install.txt            页面自己给的 `moon add` 依赖名，一行一个
  files/moon.pkg         语言标为 moonbit、首行注释是 `// cmd/main/moon.pkg` 的那一块
  files/main.mbt         同上，`// cmd/main/main.mbt`
  expected.txt           程序块之后第一段无语言围栏＝期望 stdout（可以没有）
  needs_env              `// @readme-check: needs-env VAR` 里的 VAR（可以没有）
"""
import json
import os
import re
import sys

FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$")
ADD = re.compile(r"^\s*moon\s+add\s+(\S+)")
NEEDS_ENV = re.compile(r"@readme-check:\s*needs-env\s+([A-Z0-9_]+)")


def blocks(text):
    """[(lang, body_lines)]，按出现顺序。"""
    out = []
    lang = None
    fence = None
    body = []
    for line in text.splitlines():
        m = FENCE.match(line)
        if lang is None:
            if m:
                lang, fence, body = m.group(2), m.group(1), []
            continue
        if m and not m.group(2) and m.group(1)[0] == fence[0]:
            out.append((lang, body))
            lang, fence, body = None, None, []
            continue
        body.append(line)
    if lang is not None:
        out.append((lang, body))
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    readme, outdir = sys.argv[1], sys.argv[2]
    with open(readme, encoding="utf-8") as fh:
        text = fh.read()
    bs = blocks(text)

    install = []
    for lang, body in bs:
        if lang != "bash":
            continue
        for line in body:
            m = ADD.match(line)
            if m:
                install.append(m.group(1))
    if not install:
        die("%s: 页面没有 `moon add` 安装清单" % readme)

    files = {}
    program_at = None
    for idx, (lang, body) in enumerate(bs):
        if lang != "moonbit" or not body:
            continue
        head = body[0].strip()
        m = re.match(r"^//+\s*cmd/main/([A-Za-z0-9._-]+)(\s|$|\s—.*)$", head)
        if not m:
            continue
        files[m.group(1)] = body[1:]
        program_at = idx
    if "main.mbt" not in files or "moon.pkg" not in files:
        die("%s: 找不到成对的 // cmd/main/{moon.pkg,main.mbt} 程序块" % readme)

    # 程序块之后的第一段围栏：无语言＝期望 stdout
    expected = None
    for lang, body in bs[program_at + 1:]:
        if lang == "":
            expected = body
            break
        if lang in ("moonbit", "bash"):
            break

    needs_env = ""
    for line in files["main.mbt"]:
        m = NEEDS_ENV.search(line)
        if m:
            needs_env = m.group(1)
            break

    os.makedirs(os.path.join(outdir, "files"), exist_ok=True)
    write(os.path.join(outdir, "install.txt"), dedupe(install))
    for name, body in files.items():
        # 程序块里的 needs-env 标记是闸的指令，喂给编译器前剥掉
        write(
            os.path.join(outdir, "files", name),
            [l for l in body if "@readme-check:" not in l],
        )
    if expected is not None:
        write(os.path.join(outdir, "expected.txt"), trim_blank(expected))
    if needs_env:
        write(os.path.join(outdir, "needs_env"), [needs_env])
    print(
        json.dumps(
            {
                "install": dedupe(install),
                "files": sorted(files),
                "expected_lines": len(trim_blank(expected)) if expected is not None else 0,
                "needs_env": needs_env,
            },
            ensure_ascii=False,
        )
    )
    return 0


def dedupe(items):
    out = []
    for i in items:
        if i not in out:
            out.append(i)
    return out


def trim_blank(lines):
    lines = list(lines)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def write(path, lines):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for line in lines:
            fh.write(line.rstrip("\r\n") + "\n")


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
