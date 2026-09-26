#!/usr/bin/env python
"""零警告收尾：约束/效应标注的**链式摘除**（集合级不动点），取代"总数必须降"的贪心。

为什么单纯贪心不够（本轮实测，两条都卡在这）：
  · `unused_trait_bound`：摘掉 `Engine::repo` 的 `E : ProcessExtRepository` 后，
    21:11 那条确实消失了，但 engine.mbt:532 与 engine_ops.mbt:193 各冒出一条新的
    —— 约束沿调用链**守恒**，全局总数不降反升 1，于是贪心判"这条不该摘"并回滚。
  · `unused_error_type`：同一形状的守恒（函数不再声明 raise ⇒ 某个调用方的 raise 变成未用）。
 ⇒ 正确的判据是"**本文件这一条消失了没**"，允许别处长出新的，然后**再跑一轮**处理长出来的；
   同一 (文件,行,槽位) 只处理一次，避免来回震荡。跑到"没有任何一条能摘"就是不动点。

判据仍全部交给编译器：每一试都跑**全工程** check（包级 scoped check 会少报这一类，实测）。

用法：python scripts/moon_warn_chain.py <class>      # unused_trait_bound | unused_error_type
"""
import io
import json
import os
import re
import subprocess
import sys
from collections import defaultdict, Counter

ROOT = os.getcwd()
MOON = r"G:/dev-tools/moon/bin/moon.exe"
ENV = dict(os.environ, MOON_HOME=r"G:/dev-tools/moon",
           PATH=r"G:/dev-tools/moon/bin;" + os.environ.get("PATH", ""))
KNOWN_TRAITS = ("@spi.ProcessRepository", "@spi.ProcessExtRepository")
BOUND_SLOT = re.compile(r"(\w+)\s*:\s*(@?[\w.]+)")
FN_RAISE = re.compile(r" raise(?: @error\.JeeflowError)?(?= \{)")


def check():
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    per_file = defaultdict(Counter)
    errs = 0
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message", "")
        rel = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        if d.get("level") == "error":
            errs += 1
            continue
        key = re.match(r"Warning \((\w+)\)", m)
        per_file[rel][key.group(1) if key else "other"] += 1
    return per_file, errs


def total(per_file, cls):
    return sum(c[cls] for c in per_file.values())


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


def slots(path, cls):
    """列出该文件里所有"可试摘"的槽位：(行索引, 名字起点, 串长, 名字, 串)。"""
    lines, _e, _t = read(path)
    out = []
    for i, ln in enumerate(lines):
        if cls == "unused_trait_bound":
            m = re.search(r"\bfn\[([^\]]*)\]", ln)
            if not m or ":" not in m.group(1):
                continue
            for b in BOUND_SLOT.finditer(m.group(1)):
                trait = b.group(2)
                if trait not in KNOWN_TRAITS:
                    continue
                out.append((i, m.start(1) + b.start(), m.start(1) + b.end(),
                            b.group(1), b.group(0)))
        else:
            for b in FN_RAISE.finditer(ln):
                out.append((i, b.start(), b.end(), "", b.group(0)))
    return out


def main():
    cls = sys.argv[1]
    if cls not in ("unused_trait_bound", "unused_error_type"):
        sys.exit("class 只支持 unused_trait_bound / unused_error_type")
    tried = set()
    for rnd in range(1, 9):
        per, errs = check()
        n = total(per, cls)
        print("── 第 %d 轮：%s 共 %d 条（err=%d）" % (rnd, cls, n, errs))
        if n == 0:
            print("清零。")
            return
        moved = 0
        for path in sorted(per):
            if per[path][cls] == 0:
                continue
            lines, eols, tail = read(path)
            for i, s, e, name, seg in slots(path, cls):
                key = (path, i, seg)
                if key in tried:
                    continue
                tried.add(key)
                lines, eols, tail = read(path)
                raw = lines[i]
                trial = raw[:s] + name + raw[e:]
                if trial == raw:
                    continue
                lines[i] = trial
                write(path, lines, eols, tail)
                per2, errs2 = check()
                if errs2 == 0 and per2[path][cls] < per[path][cls]:
                    print("  摘 %-42s 行%-5d %-34s %s %d→%d（本文件）"
                          % (path, i + 1, seg.strip(), cls, per[path][cls], per2[path][cls]))
                    per = per2
                    moved += 1
                else:
                    lines[i] = raw
                    write(path, lines, eols, tail)
                    check()
                    tried.add(key)
        if moved == 0:
            print("不动点：本轮没有任何一条能摘（剩下的需要人工定口径）。")
            return


if __name__ == "__main__":
    main()
