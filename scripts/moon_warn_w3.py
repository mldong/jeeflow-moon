#!/usr/bin/env python
"""警告批次 W3：unused_trait_bound 60 处 —— **让编译器当验收人**逐个约束摘。

为什么不"从诊断里读出是哪个声明"（试过两版，都不成立）：
  - 报告行号不可信：本仓 .mbt 的 blob 是 `\r\r\n` 行尾（.gitattributes `* -text` 不转换），
    moon 行计数器给出的行号偏大（实测 engine.mbt 报 145、实为 112； skew 还不恒定）；
  - 列号可信，但**诊断的 context 窗口也跟着那个偏大的行号走**，
    于是"锁不到 `fn[` 行"是它的正常表现（实测 core/engine/engine.mbt 37:12 的 context
    只给到函数体三行）⇒ 拿 context 当真值会把约束摘到错误的声明上。
  ⇒ 位置推不出来就别推：改成"编译器说这个文件里有 k 个约束没用 ⇒ 逐个试摘，
     每试一次跑一次 scoped check：**报错就回滚**（说明这个约束真的被用到），
     **unused_trait_bound 少一个就保留**，否则回滚"。
     验收人从"我配对配对了"换成编译器本身，摘多摘少都会当场显形。

用法：
  python scripts/moon_warn_w3.py                 # 真跑（逐文件逐约束）
  python scripts/moon_warn_w3.py --dry           # 只打印将要试摘的清单
  python scripts/moon_warn_w3.py --only facade/stats.mbt
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
BOUND = re.compile(r"(\w+)\s*:\s*(@?[\w.]+)")
CLASS = "unused_trait_bound"


def read(path):
    raw = io.open(path, encoding="utf-8", newline="").read()
    parts = raw.split("\n")
    lines, eols = [], []
    for seg in parts[:-1]:
        n_cr = len(seg) - len(seg.rstrip("\r"))
        lines.append(seg[: len(seg) - n_cr] if n_cr else seg)
        eols.append("\r" * n_cr + "\n")
    return lines, eols, parts[-1]


def write(path, lines, eols, tail):
    io.open(path, "w", encoding="utf-8", newline="").write(
        "".join(l + e for l, e in zip(lines, eols)) + tail)


def scoped_check(pkg):
    """跑包级 check，返回该包里 CLASS 警告总数与 error 总数。"""
    p = subprocess.run([MOON, "check", "--target", "wasm", pkg, "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    warns = errs = 0
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msg = d.get("message", "")
        if d.get("level") == "error":
            errs += 1
        elif CLASS in msg:
            warns += 1
    return warns, errs, p.returncode


def decl_lines(lines):
    """含泛型约束的声明行：(行索引, [(名字, trait, 串起点, 串长)])"""
    out = []
    for i, ln in enumerate(lines):
        m = DECL.search(ln)
        if not m or ":" not in m.group(1):
            continue
        slots = []
        for b in BOUND.finditer(m.group(1)):
            slots.append((b.group(1), b.group(2),
                          m.start(1) + b.start(), m.start(1) + b.end()))
        out.append((i, slots))
    return out


def main():
    dry = "--dry" in sys.argv
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    diag = sys.argv[1] if not sys.argv[1].startswith("--") else os.path.join(
        r"G:/dev-tools/tmp", "diagC.json")
    files = {}
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{") or CLASS not in json.loads(line).get("message", ""):
            continue
        d = json.loads(line)
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        files[p] = files.get(p, 0) + 1
    targets = [only] if only else sorted(files)
    kept = reverted = 0
    for path in targets:
        pkg = "/".join(path.split("/")[:2])
        lines, eols, tail = read(path)
        base_warns, base_errs, _ = scoped_check(pkg)
        print("### %s（该包 %s=%d，err=%d）" % (path, CLASS, base_warns, base_errs))
        for i, slots in decl_lines(lines):
            for name, trait, s, e in slots:
                seg = lines[i][s:e]
                if dry:
                    print("  试摘 %s:%d 的 %s" % (path, i + 1, seg))
                    continue
                trial = lines[i][:s] + name + lines[i][e:]
                if trial == lines[i]:
                    continue                     # 该槽本来就没约束
                lines[i] = trial
                write(path, lines, eols, tail)
                w, err, _ = scoped_check(pkg)
                if err > base_errs:
                    lines[i] = lines[i][:s] + seg + lines[i][s + len(name):]
                    write(path, lines, eols, tail)
                    reverted += 1
                    print("  回滚 %-46s %s（用到：scoped err %d→%d）"
                          % (path + ":" + str(i + 1), seg, base_errs, err))
                elif w < base_warns:
                    base_warns = w
                    kept += 1
                    print("  保留 %-46s 摘 %s（%s %d→%d）" % (path + ":" + str(i + 1), seg, CLASS, w + 1, w))
                else:
                    lines[i] = lines[i][:s] + seg + lines[i][s + len(name):]
                    write(path, lines, eols, tail)
                    reverted += 1
                    print("  回滚 %-46s %s（摘了警告数不动：%d ⇒ 这条不是编译器点的那一个）"
                          % (path + ":" + str(i + 1), seg, w))
        print("   余 %s=%d" % (CLASS, base_warns))
    print("保留 %d、回滚 %d" % (kept, reverted))


if __name__ == "__main__":
    main()
