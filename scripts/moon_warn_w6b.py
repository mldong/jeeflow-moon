#!/usr/bin/env python
"""警告批次 W6b：deprecated 改写 **一个站点一验**（W6 整批模式在 substring 上翻车后的修法）。

翻车实录（留在仓里，别再走一遍）：
  整批把 `\.substring\(...\)\.to_string\(\)` 换成 `.to_owned()`，命中 37 处、
  deprecated 107→28 看着很爽，但**9 个 error**：`Type String has no method to_owned`。
  原因是 `substring` 的返回类型跟着接收者走：
    StringView.substring(…) → StringView ⇒ 尾巴该换 to_owned()
    String.substring(…)     → String     ⇒ 尾巴的 to_string() 本就不是被点名的形状
  文本上分不出这两类（要的是接收者类型），所以"按形状整批改"在这里不够 ⇒
  逐站点改 + 每站一遍全工程 check；报 error 就只回滚那一站。

实现要点：同一个文件内**从后往前**处理，改尾巴不影响前面站点的字节偏移，
所以不需要任何"哨兵/占位"技巧（哨兵会把注释留在源码里，是坏主意）。

用法：python scripts/moon_warn_w6b.py [正则]      # 默认 substring 链
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
PAT = re.compile(sys.argv[1] if len(sys.argv) > 1
                 else r"(\.substring\((?:[^()]|\([^()]*\))*\))\.to_string\(\)")


def check():
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    errs = warns = dep = 0
    first_err = ""
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
            first_err = first_err or m.replace("\n", " / ")[:90]
        else:
            warns += 1
            if m.startswith("Warning (deprecated)"):
                dep += 1
    return errs, warns, dep, first_err


def rd(path):
    return io.open(os.path.join(ROOT, path), encoding="utf-8", newline="").read()


def wr(path, s):
    io.open(os.path.join(ROOT, path), "w", encoding="utf-8", newline="").write(s)


def main():
    e0, w0, d0, _ = check()
    print("基线 err=%d warn=%d deprecated=%d" % (e0, w0, d0))
    files = [f for f in subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True,
                                       text=True).stdout.split()
             if ".mooncakes" not in f and PAT.search(rd(f))]
    kept = skipped = 0
    for f in files:
        for m in reversed(list(PAT.finditer(rd(f)))):        # 从后往前：前面的偏移不动
            raw = rd(f)
            rep = PAT.sub(r"\1.to_owned()", m.group(0))
            wr(f, raw[:m.start()] + rep + raw[m.end():])
            e, w, d, why = check()
            if e > 0:
                wr(f, raw)
                skipped += 1
                print("  跳过 %-44s @%-6d err=%d %s" % (f, m.start(), e, why))
                check()
            else:
                kept += 1
                print("  保留 %-44s @%-6d deprecated %d→%d" % (f, m.start(), d0, d))
                d0, w0 = d, w
    e, w, d, _ = check()
    print("保留 %d、跳过 %d；收尾 err=%d warn=%d deprecated=%d" % (kept, skipped, e, w, d))


if __name__ == "__main__":
    main()
