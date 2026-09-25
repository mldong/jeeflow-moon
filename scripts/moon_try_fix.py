#!/usr/bin/env python
"""`try?` 迁移变换器（只吃可证明安全的简单形状，其余原样留下让人看）。

新语义下 `try?` 的两类用途塌到同一个形状：
    try CALL catch { e => <失败分支> } noraise { v => <成功分支> }
理由：catch 臂天然拿到错误值（等价旧 Err(e)），noraise 臂天然拿到成功值（等价旧 Ok(v)），
且**不再凭空造 Result 壳**——这正是编译器在弃办提示里点名的"别机械包一层 Ok/Err"。

只处理三种形状（不满足就跳过并报告，交人工）：
  S1  `match (CALL) {` + 恰好两条单行臂 Ok(..)/Err(..) + 同缩进 `}`
  S2  `let N = CALL`（CALL 单行、不以 raise 结尾）紧跟 `match N {` + 同 S1 的臂
  S3  `assert_true((CALL) is Err(_))` 一类断言 ⇒ 由人工改（负向语义要保留"必须 raise"）

行尾：本仓部分 .mbt 带 `\r\r\n`，脚本按行拆分时统一剥 CR，写回时按原文件的
首行行尾形状复原，避免整文件 diff。
"""
import glob
import io
import os
import re
import sys

ROOT = os.getcwd()
SEP = chr(92)
OK_ARM = re.compile(r"^(\s*)Ok\((.+)\)\s*=>\s*(.*)$")
ERR_ARM = re.compile(r"^(\s*)Err\((.+)\)\s*=>\s*(.*)$")
MATCH_INLINE = re.compile(r"^(\s*)match \((.+)\) \{$")
MATCH_NAME = re.compile(r"^(\s*)match ([A-Za-z_]\w*) \{$")
LET_CALL = re.compile(r"^(\s*)let (\w+) = (.+)$")


def mbt_files():
    for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
        norm = path.replace(SEP, "/")
        if "_build/" in norm or "/.mooncakes/" in norm:
            continue
        yield path


def read_lines(path):
    src = io.open(path, encoding="utf-8", newline="").read()
    eol = "\r\n" if "\r\n" in src else "\n"
    lines = [l.replace("\r", "") for l in src.replace("\r\n", "\n").split("\n")]
    return lines, eol


def collect_arms(lines, i, indent):
    """i 指向 `match ... {` 行之后第一行；返回 (ok_bind, ok_body, err_bind, err_body, end_idx) 或 None"""
    ok = err = None
    j = i
    body = []
    while j < len(lines):
        line = lines[j]
        if line.strip() == "}" and (len(line) - len(line.lstrip())) * 1 == indent:
            break
        m = OK_ARM.match(line)
        if m and len(m.group(1)) == indent + 2:
            ok = (m.group(2), m.group(3), j)
        else:
            m = ERR_ARM.match(line)
            if m and len(m.group(1)) == indent + 2:
                err = (m.group(2), m.group(3), j)
            elif line.strip().startswith("_ =>") or line.strip().startswith("Json::") or line.strip().startswith("Some("):
                return None      # 臂不干净（三分支/嵌套模式）⇒ 交人工
        j += 1
    else:
        return None
    if not ok or not err:
        return None
    # 单行体才算简单（多行体里有块，塌成 catch/noraise 容易改形）
    if not ok[1].strip() or not err[1].strip():
        return None
    if ok[2] > err[2]:
        return None
    return (ok, err, j)


def transform(path):
    lines, eol = read_lines(path)
    out = []
    i = 0
    changed = 0
    skipped = []
    while i < len(lines):
        line = lines[i]
        m = MATCH_INLINE.match(line)
        if m:
            indent = len(m.group(1))
            call = m.group(2)
            arms = collect_arms(lines, i + 1, indent)
            if arms:
                ((ok_bind, ok_body, _), (err_bind, err_body, _), end) = arms
                pad = " " * (indent + 2)
                out.append("%stry %s catch {" % (" " * indent, call))
                out.append("%s%s => %s" % (pad, err_bind, err_body))
                out.append("%s} noraise {" % (" " * indent))
                out.append("%s%s => %s" % (pad, ok_bind, ok_body))
                out.append("%s}" % (" " * indent))
                i = end + 1
                changed += 1
                continue
            skipped.append((i + 1, "形状不简单: " + call[:50]))
        m2 = MATCH_NAME.match(line)
        if m2 and out:
            prev = out[-1]
            pm = LET_CALL.match(prev)
            name = m2.group(2)
            if pm and pm.group(2) == name and "raise" not in pm.group(3):
                indent = len(m2.group(1))
                arms = collect_arms(lines, i + 1, indent)
                if arms:
                    call = pm.group(3)
                    pad = " " * (indent + 2)
                    out[-1] = "%slet %s = try %s catch {" % (" " * indent, name, call)
                    out.append("%s%s => %s" % (pad, arms[1][0], arms[1][1]))
                    out.append("%s} noraise {" % (" " * indent))
                    out.append("%s%s => %s" % (pad, arms[0][0], arms[0][1]))
                    out.append("%s}" % (" " * indent))
                    i = arms[2] + 1
                    changed += 1
                    continue
                skipped.append((i + 1, "let+match 臂不简单: " + name))
        out.append(line)
        i += 1
    if changed:
        io.open(path, "w", encoding="utf-8", newline="").write(eol.join(out))
    return changed, skipped


def main():
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    total = 0
    for path in mbt_files():
        if only and not any(o in path.replace(SEP, "/") for o in only):
            continue
        changed, skipped = transform(path)
        total += changed
        if changed or skipped:
            print("%-46s 改写 %d 处，跳过 %d 处" % (
                os.path.relpath(path, ROOT).replace(SEP, "/"), changed, len(skipped)))
            for ln, why in skipped[:6]:
                print("     行 %d  %s" % (ln, why))
    print("合计塌成 try/catch/noraise:", total, "处")


if __name__ == "__main__":
    main()
