#!/usr/bin/env python
"""警告批次 W4b：ambiguous_precedence —— 给 `&&` 组补显式括号。

`A && B || C && D` 在语言里是 `A && (B || C) && D` 还是 `(A&&B) || (C&&D)`？
按 && 优先于 || 是后者，所以补括号**一字不改语义**；但工具链仍要人写明，
理由很实在：这类形状在本仓全在 snake_case ↔ camelCase 的 ASCII 区间判断里，
少一个括号就是"下划线归谁"的判据差一格（issues/121 那类"看着生效其实没生效"）。

用法：python scripts/moon_warn_w4b.py
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

ENG = "core/engine/engine.mbt"
PER = "persist/persist.mbt"

ENG_PAIRS = [
    (
        """    if ch == '#' && i + 1 < len && (chars[i + 1].to_int() >= 97 && chars[i + 1].to_int() <= 122 || chars[i + 1].to_int() >= 65 && chars[i + 1].to_int() <= 90 || chars[i + 1] == '_') {""",
        """    if ch == '#' && i + 1 < len && ((chars[i + 1].to_int() >= 97 && chars[i + 1].to_int() <= 122) || (chars[i + 1].to_int() >= 65 && chars[i + 1].to_int() <= 90) || chars[i + 1] == '_') {""",
    ),
    (
        """        if c >= 97 && c <= 122 || c >= 65 && c <= 90 || c >= 48 && c <= 57 || chars[end] == '_' {""",
        """        if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || chars[end] == '_' {""",
    ),
]

PER_PAIRS = [
    (
        """    let alnum = c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122""",
        """    let alnum = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)""",
    ),
]

if __name__ == "__main__":
    patch(ENG, ENG_PAIRS)
    patch(PER, PER_PAIRS)
