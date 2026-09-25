#!/usr/bin/env python
"""MoonBit 迁移批处理 W2：`Map::new()` → `Map([])`（唯一的 1:1 替换）。

`try?` **不在本脚本处理**：它有两类用途（纯传播 / 需要 Ok|Err 两态），
差别只在后续几行怎么用它——靠正则猜意图会改错，改成编译器驱动：
先按 @error.attempt 的形态逐站点看编译错误，人工定夺。
"""
import glob
import io
import os

ROOT = os.getcwd()


def files():
    for path in glob.glob(os.path.join(ROOT, "**", "*.mbt"), recursive=True):
        norm = path.replace("\\", "/")
        if "_build/" in norm or "/.mooncakes/" in norm:
            continue
        yield path


def main():
    per_file = {}
    for path in files():
        src = io.open(path, encoding="utf-8", newline="").read()
        if "Map::new()" not in src:
            continue
        crlf = "\r\n" in src
        n = src.count("Map::new()")
        out = src.replace("Map::new()", "Map([])")
        io.open(path, "w", encoding="utf-8", newline="").write(
            out.replace("\n", "\r\n") if crlf else out)
        per_file[os.path.relpath(path, ROOT)] = n
    print("W2 Map::new 替换站点:", sum(per_file.values()), "涉及文件:", len(per_file))
    for f, n in sorted(per_file.items(), key=lambda x: -x[1])[:16]:
        print("  %3d  %s" % (n, f))
    left = sum(
        1 for p in files() for l in io.open(p, encoding="utf-8", errors="replace")
        if "Map::new()" in l
    )
    print("残留 Map::new 行数:", left)


if __name__ == "__main__":
    main()
