#!/usr/bin/env python
"""警告批次 W14b：unused_trait_bound 的"全拆 → 按编译器的错往回装最小集"。

W14 第一版有个自己的 bug：阶段 2 又拿"当前文本"去找"带 `: 约束` 的声明"——
可是阶段 1 已经把约束拆光了，于是 0 个候选、27 个 error 留在那儿。
这版把**候选清单从 HEAD 版本取**（拆之前长什么样，git 里有），
并加了两条纪律：
  · 每个候选：把该行还原成 HEAD 的那一版 → 跑全工程 check →
    **error 数下降才保留**，否则回滚到"拆光"状态；
  · 装到 error=0 之后，再反向跑一遍"能拆就拆"（拆了不炸、且
    unused_trait_bound 不增 ⇒ 保留）——这才是真正的最小集。
任何一步崩了都用 `git checkout -- <本次动过的文件>` 兜还原（脚本自己打清单）。

前置：工作树里约束已被 W14 阶段 1 拆光（err=27、该警告=0）。
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
DECL = re.compile(r"\bfn\[([^\]]*)\]")


def check():
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    errs, warn = 0, {}
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
            continue
        k = re.match(r"Warning \((\w+)\)", m)
        if k:
            warn[k.group(1)] = warn.get(k.group(1), 0) + 1
    return errs, warn


def head_lines(path):
    """⚠ 不能用 text=True：Python 的通用换行会把 `\r\r\n` 当两个换行 ⇒ HEAD 的行数翻倍，
    候选行号全部越界（本次 IndexError 的根因）。按字节取回、只按 `\n` 切。"""
    raw = subprocess.run(["git", "show", "HEAD:" + path], capture_output=True).stdout
    raw = raw.decode("utf-8", errors="replace")
    return [s.rstrip("\r") for s in raw.split("\n")]


def read(path):
    raw = io.open(path, encoding="utf-8", newline="").read()
    parts = raw.split("\n")
    lines, eols = [], []
    for seg in parts[:-1]:
        n = len(seg) - len(seg.rstrip("\r"))
        lines.append(seg[: len(seg) - n] if n else seg)
        eols.append("\r" * n + "\n")
    return lines, eols, parts[-1]


def write(path, lines, eols, tail):
    io.open(path, "w", encoding="utf-8", newline="").write(
        "".join(l + e for l, e in zip(lines, eols)) + tail)


def main():
    files = subprocess.run(["git", "diff", "--name-only", "HEAD", "--", "*.mbt"],
                           capture_output=True, text=True).stdout.split()
    cands = []
    for f in files:
        hl = head_lines(f)
        for i, ln in enumerate(hl):
            m = DECL.search(ln)
            if m and ":" in m.group(1):
                cands.append((f, i, ln))
    print("候选（来自 HEAD）：%d 个声明，覆盖 %d 个文件" % (len(cands), len(files)))
    e0, w0 = check()
    print("开局：err=%d unused_trait_bound=%d 总 warn=%d" % (e0, w0.get("unused_trait_bound", 0), sum(w0.values())))
    restored = []
    errs = e0
    for f, i, ln in cands:
        lines, eols, tail = read(f)
        cur = lines[i]
        if cur == ln:
            continue
        lines[i] = ln
        write(f, lines, eols, tail)
        e1, _w1 = check()
        if e1 < errs:
            errs = e1
            restored.append((f, i))
            print("  装回 %-40s 行%-5d err %d→%d" % (f, i + 1, e1 + (errs != e1), e1))
        else:
            lines[i] = cur
            write(f, lines, eols, tail)
            check()
    e2, w2 = check()
    print("阶段2 结束：err=%d，装回 %d 个，unused_trait_bound=%d，总 warn=%d"
          % (e2, len(restored), w2.get("unused_trait_bound", 0), sum(w2.values())))
    if e2:
        print("!! 仍 %d 个 error ⇒ 需要成对装回，脚本停在这里交人工" % e2)
        return
    # 阶段 3：能拆则拆（拆了不炸、且该警告不增 ⇒ 保留）
    changed = True
    rounds = 0
    while changed and rounds < 6:
        changed = False
        rounds += 1
        for f, i in list(restored):
            lines, eols, tail = read(f)
            keep = lines[i]
            stripped = re.sub(r"(\w+)\s*:\s*@spi\.\w+", r"\1", keep)
            if stripped == keep:
                continue
            lines[i] = stripped
            write(f, lines, eols, tail)
            e3, w3 = check()
            if e3 == 0 and w3.get("unused_trait_bound", 0) <= w2.get("unused_trait_bound", 0):
                w2 = w3
                restored.remove((f, i))
                changed = True
                print("  阶段3 又拆掉 %-40s 行%-5d（该警告=%d）" % (f, i + 1, w3.get("unused_trait_bound", 0)))
            else:
                lines[i] = keep
                write(f, lines, eols, tail)
                check()
    e4, w4 = check()
    print("收尾：err=%d unused_trait_bound=%d 总 warn=%d（%s）"
          % (e4, w4.get("unused_trait_bound", 0), sum(w4.values()), json.dumps(w4, ensure_ascii=False)))


if __name__ == "__main__":
    main()
