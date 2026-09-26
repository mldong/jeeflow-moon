#!/usr/bin/env python
"""警告批次 W2：implicit_impl_as_method 48 处 ⇒ 生成显式 `pub extend`。

新工具链不再把 `impl Trait for T` 的方法**隐式提升**为 T 的常规方法（弃办，将来移除）。
编译器把修法原话写在消息里：
    Add a `pub extend JeeflowError with Eq::{not_equal, equal}` declaration
所以这一类不需要人判断形状，只需要把 48 条消息**机器读出来**、按文件落成声明。

三条落地约定：
 1. 就地追加到诊断报的那个文件（该类警告都落在"类型定义 + impl 所在包"，
    extend 只能在定义包的包里写，位置不是自由选择）；
 2. vendored 目录特殊：`repository-mysql/vendored/moon_mysql_client/` 的上游两文件
    纪律是逐字节原样拷贝（MAINTAINING D-M6-1），所以那条 extend 落在**本仓自有的新文件**
    `extend_driver.mbt` 里，上游文件零改动；
 3.  trait 名按"该文件里能写通的形式"映射（@mldong/jeeflow-core/spi.X → @spi.X、
    @moonbitlang/core/debug.Debug → Debug 由 derive 已在作用域、@moonbitstack/moondb.Driver
    → @moondb.Driver），错了编译器会直接说，不猜第二遍。

用法：python scripts/moon_warn_w2.py <moon check --output-json 落盘文件> [--dry]
"""
import io
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

ROOT = os.getcwd()
PAT = re.compile(
    r"The methods ([\w, ]+) from `([^`]+)` are implicit promoted as regular method for `([^`]+)`"
)
TRAIT_MAP = [
    ("@mldong/jeeflow-core/spi.", "@spi."),
    ("@moonbitlang/core/debug.", ""),          # Debug 已在作用域（derive 过来的）
    ("@moonbitstack/moondb.", "@moondb."),
]
VENDORED_DIR = "repository-mysql/vendored/moon_mysql_client"
VENDORED_FILES = [VENDORED_DIR + "/" + f for f in ("conn.mbt", "driver.mbt")]
HDR = (
    "\n// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──\n"
    "// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。\n"
)


def trait_of(impl_str, path):
    m = re.match(r"impl (.+) for .+", impl_str)
    if not m:
        raise SystemExit("认不出的 impl 形状: " + impl_str)
    trait = m.group(1)
    for pre, rep in TRAIT_MAP:
        if trait.startswith(pre):
            return rep + trait[len(pre):] if rep else trait.split(".")[-1]
    return trait


def load(path):
    recs = []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            recs.append(json.loads(line))
        except ValueError:
            pass
    return recs


def main():
    diag = sys.argv[1]
    dry = "--dry" in sys.argv
    per_file = defaultdict(OrderedDict)   # file -> {(type, trait): methods}
    for d in load(diag):
        msg = d.get("message", "")
        if "implicit_impl_as_method" not in msg:
            continue
        m = PAT.search(msg)
        if not m:
            raise SystemExit("消息形状变了，脚本要跟着改: " + msg[:120])
        methods, impl, typ = m.group(1), m.group(2), m.group(3)
        p = os.path.relpath(d["path"], ROOT).replace(os.sep, "/")
        trait = trait_of(impl, p)
        key = (typ, trait)
        norm = ", ".join(sorted(x.strip() for x in methods.split(",")))
        if key in per_file[p] and per_file[p][key] != norm:
            raise SystemExit("同 (类型,trait) 方法集不一致，得人工看: %s %s" % (p, key))
        per_file[p][key] = norm
    n = 0
    for p in sorted(per_file):
        items = per_file[p]
        target = p
        extra = ""
        if p in VENDORED_FILES:
            # 上游文件不动：extend 落到本仓自有新文件
            target = VENDORED_DIR + "/extend_driver.mbt"
            extra = (
                "// 本仓自有文件（不是上游拷贝）：vendored 的 conn.mbt/driver.mbt 保持逐字节原样，\n"
                "// 显式 extend 声明只能落在同包，故另立此文件。见 MAINTAINING D-M6-1 的 vendored 纪律。\n"
            )
        lines = [extra or "", HDR.rstrip("\n")]
        for (typ, trait), methods in items.items():
            lines.append("pub extend %s with %s::{%s}" % (typ, trait, methods))
            n += 1
        body = "\n".join(lines) + "\n"
        if dry:
            print("### %s (%d 条)" % (target, len(items)))
            print(body)
            continue
        if os.path.exists(target):
            with io.open(target, encoding="utf-8", newline="") as f:
                cur = f.read()
            if "显式 extend（implicit_impl_as_method" in cur:
                print("跳过（已生成过）:", target)
                continue
            eol = "\r\n" if cur.endswith("\r\n") else "\n"
            with io.open(target, "a", encoding="utf-8", newline="") as f:
                f.write(body.replace("\n", eol))
        else:
            with io.open(target, "w", encoding="utf-8", newline="\n") as f:
                f.write(body)
        print("写入", target, len(items), "条")
    print("合计 extend:", n)


if __name__ == "__main__":
    main()
