#!/usr/bin/env python
"""警告批次 W14：**先全拆、再按编译器的错往回装**——处理"守恒型"警告
（unused_trait_bound / unused_error_type）。

为什么贪心（逐点摘、看总数）在这儿不收敛：这两类是**守恒**的。
实测 `Engine::repo` 的 `E : ProcessExtRepository` 摘掉后，21:11 那条确实没了，
但 engine.mbt:532 与 engine_ops.mbt:193 各冒出一条新的；同文件内守恒时
连"本文件计数下降"这条放宽判据也过不了（chain 脚本实跑：整轮 0 摘除即不动点）。

于是反过来做，两阶段：
 阶段 1「全拆」：把工程里所有目标标注（R/E 约束、或 ` raise`）一次去掉 → 编译器会炸。
 阶段 2「装回最小集」：逐个声明**加回**标注，每加一个跑一次全工程 check，
   只要让 error 数**下降**就保留，否则回滚这次加回；直到 error=0。
   ⇒ 得到的是"编译真正需要的那一集"，其余一律不带标注 ⇒ 警告自然消失。
 阶段 3（可选）：对加回来的再试一次"摘了也不炸、且警告不增"的收尾。

跑法：python scripts/moon_warn_w14.py <bound|raise>      （耗时 = 声明数 × 一次 check）
"""
import io
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

ROOT = os.getcwd()
MOON = r"G:/dev-tools/moon/bin/moon.exe"
ENV = dict(os.environ, MOON_HOME=r"G:/dev-tools/moon",
           PATH=r"G:/dev-tools/moon/bin;" + os.environ.get("PATH", ""))
TRAITS = {"R": "@spi.ProcessRepository", "E": "@spi.ProcessExtRepository"}


def mbts():
    out = subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True, text=True).stdout.split()
    return [f for f in out if ".mooncakes" not in f.replace("\\", "/")]


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


def check():
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    errs = 0
    warn = defaultdict(int)
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
            warn[k.group(1)] += 1
    return errs, dict(warn)


# ── 两种目标的"拆 / 装"实现 ────────────────────────────────────────────────
def decls_bound(lines):
    """返回 [(行索引, 原行, 全拆后的行, 装回后的行)]"""
    out = []
    for i, ln in enumerate(lines):
        m = re.search(r"\bfn\[([^\]]*)\]", ln)
        if not m or ":" not in m.group(1):
            continue
        stripped = re.sub(r"(\w+)\s*:\s*@spi\.\w+", r"\1", ln)
        out.append((i, ln, stripped, ln))
    return out


def decls_raise(lines):
    out = []
    for i, ln in enumerate(lines):
        m = re.search(r" raise(?: @error\.JeeflowError)?(?= \{)", ln)
        if not m:
            continue
        out.append((i, ln, ln[:m.start()] + ln[m.end():], ln))
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "bound"
    cls = "unused_trait_bound" if mode == "bound" else "unused_error_type"
    pick = decls_bound if mode == "bound" else decls_raise
    snap = {f: read(f) for f in mbts()}
    files = [f for f in sorted(snap) if pick(snap[f][0])]
    n_decl = sum(len(pick(snap[f][0])) for f in files)
    print("目标 %s：涉及 %d 个文件 / %d 个声明" % (cls, len(files), n_decl))

    # 阶段 1：全拆
    for f in files:
        lines, eols, tail = snap[f]
        for i, _orig, stripped, _ in pick(lines):
            lines[i] = stripped
        write(f, lines, eols, tail)
    e0, w0 = check()
    print("阶段1 全拆后：err=%d，%s=%d" % (e0, cls, w0.get(cls, 0)))
    if e0 == 0:
        print("全拆即通过 ⇒ 阶段2 无需装回。")
        return

    # 阶段 2：按声明装回，能降 error 才留
    base_errs = e0
    kept = 0
    for f in files:
        lines, eols, tail = read(f)
        for i, orig, _s, _ in pick(lines):
            if lines[i] == orig:
                continue
            trial = list(lines)
            trial[i] = orig
            write(f, trial, eols, tail)
            e1, _w1 = check()
            if e1 < base_errs:
                lines = trial
                base_errs = e1
                kept += 1
                print("  装回 %-40s 行%-5d err %d→%d" % (f, i + 1, e1 + (base_errs != e1), e1))
            else:
                write(f, lines, eols, tail)
                check()
    e2, w2 = check()
    print("阶段2：装回 %d 个声明 ⇒ err=%d，%s=%d，总 warn=%d"
          % (kept, e2, cls, w2.get(cls, 0), sum(w2.values())))
    if e2:
        print("!! 还有 %d 个 error：装回策略没覆盖到（可能 error 需要同时装回两个声明）" % e2)


if __name__ == "__main__":
    main()
