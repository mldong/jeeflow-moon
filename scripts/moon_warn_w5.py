#!/usr/bin/env python
"""警告批次 W5v2：删 moon.pkg 里未用的 import —— **一条一验**。

踩过的两级坑（写在这里，别再往下退）：
 1. 只按 `moon check` 的 unused_package 建议删 ⇒ 一次造出 38 个 error
    （`*_test.mbt` / `for "test"` 块用的包，普通编译单元看不见）。
    ⇒ 改成"check 与 test 两个通道都报 unused 才删"。
 2. 本轮实测：**两通道也不够**。v1 按该规则删 18 条，编译器当场报 17 个 error：
      - core/engine 的 @id_gen：测试站点要用，两个通道却都报它 unused；
      - core/handler 的 @json、repository-mysql/query 的 @json：同样是测试文件在用；
      - 还冒出 5 条 `core_package_not_imported`：删掉 core 包的显式 import 后编译器
        退回"隐式可用"老路并另发一类警告 ⇒ 警告结构反而变差。
    成因不深究（moon 对 test 变体的诊断归属 + 本仓 `\r\r\n` 行尾，行为不好预测），
    落成规则：**每条删除单独过一遍全工程 check**，报错或警告不降就立刻回滚这一条。

用法：python scripts/moon_warn_w5.py [diag.json]
输出"删成的"与"编译器说没用但实际不能删的"两张清单——后者要回写 MAINTAINING，
不然下一轮又有人照诊断删它。
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
LINE = re.compile(r"^(\s*)\"([^\"]+)\"[^\n]*$")


def grab_unused(diag):
    out = defaultdict(set)
    for line in io.open(diag, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msg = d.get("message", "")
        if "Unused package alias" in msg or "Unused package" not in msg:
            continue
        m = re.search(r"Unused package '([^']+)'", msg)
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        if m and p.endswith("moon.pkg"):
            out[p].add(m.group(1))
    return {k: sorted(v) for k, v in out.items()}


def check():
    """全工程 check → (error 数, warning 数, core_package_not_imported 数)"""
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    errs = warns = coreimp = 0
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("level") == "error":
            errs += 1
        else:
            warns += 1
            if "core_package_not_imported" in d.get("message", ""):
                coreimp += 1
    return errs, warns, coreimp


def main():
    diag = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else r"G:/dev-tools/tmp/base.json"
    cands = grab_unused(diag)
    base_errs, base_warns, base_core = check()
    print("基线：err=%d warn=%d core_not_imported=%d" % (base_errs, base_warns, base_core))
    done, refused = [], []
    for pkg_file in sorted(cands):
        for name in cands[pkg_file]:
            raw = io.open(pkg_file, encoding="utf-8", newline="").read()
            keep, out, hit = None, [], False
            for ln in raw.split("\n"):
                s = ln.rstrip("\r")
                m = LINE.match(s)
                if not hit and m and m.group(2) == name:
                    keep, hit = ln, True
                    continue
                out.append(ln)
            if not hit:
                print("  ? %s 里没有 %s（可能已删）" % (pkg_file, name))
                continue
            io.open(pkg_file, "w", encoding="utf-8", newline="").write("\n".join(out))
            e, w, ci = check()
            if e > 0 or ci > base_core or w >= base_warns:
                io.open(pkg_file, "w", encoding="utf-8", newline="").write(raw)
                refused.append((pkg_file, name,
                                "err=%d warn %d→%d core %d→%d" % (e, base_warns, w, base_core, ci)))
                check()                      # 回滚后把构建状态拉回来，别把脏树留给下一条
            else:
                done.append((pkg_file, name))
                base_warns = w
                print("  删 %-46s %-34s warn %d→%d" % (pkg_file, name, w + 1, w))
    print("删成 %d 条；不可删 %d 条" % (len(done), len(refused)))
    for p, n, why in refused:
        print("   不可删 %-52s %-32s %s" % (p, n, why))


if __name__ == "__main__":
    main()
