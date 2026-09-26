#!/usr/bin/env python
"""警告批次 W12：剩余"编译器给了明确替代写法"的 13 站点，逐个精确改。

分组与判据：
 A. 多行字符串直接当函数体（4 处：compliance_test.simple_flow_json、
    withdraw_transfer_test 的 linear/shared/countersign）——
    工具链说"除 let 绑定、FFI、括号之外不要裸用多行串"。这里走 **let 绑定**形：
    首行 `$|{"name"…` 前挂 `let s = `，函数体收尾前补一行 `s`。
    ⚠ 中间的 `$|` 行**一个字节都不动**：多行串的缩进参与内容，动了就是改数据。
    定位函数结束靠"第一个顶格的 `}`"——串里的 `{`/`}` 都在 `$|` 行上，不会误撞。
 B. `x.value(k)` / `x.as_string()` 剩下 4 处：菜谱的正则只吃"标识符接收者"，
    这 4 处的接收者是 `arr[0]` / `row`（实参带括号）/ `data_of(env)` / 调用结果切片，
    所以手写：一律走本仓 @json 的助手（get/as_str/as_array），不散写判形。
 C. `x |> _.f()` 偏应用 1 处 ⇒ 直接 `.to_int()`。
 D. 闭包缺 `raise`/`async` 效应标注 4 处 ⇒ 按建议换箭头形或补 `async`。
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402


def wrap_multiline(path, fnsign):
    """把 `fn 名字(...) -> String { $|…$| }` 改成 let 绑定形（$| 行原样不动）。"""
    raw = io.open(path, encoding="utf-8", newline="").read()
    parts = raw.split("\n")
    start = None
    for i, s in enumerate(parts):
        if s.rstrip("\r") == fnsign.rstrip("\r"):
            start = i
            break
    if start is None:
        sys.exit("!! 找不到函数行：%s :: %s" % (path, fnsign[:50]))
    # 第一个 $| 行：挂 let s =
    body = None
    for j in range(start + 1, len(parts)):
        if parts[j].lstrip("\r").lstrip().startswith("$|"):
            body = j
            break
    if body is None:
        sys.exit("!! %s 里没找到 $| 起始行" % path)
    crs = parts[body][len(parts[body].rstrip("\r")):]
    b = parts[body].rstrip("\r")
    indent = b[: len(b) - len(b.lstrip())]
    parts[body] = indent + "let s = " + b.lstrip() + crs
    # 第一个顶格 `}`：它前面插一行 `  s`
    end = None
    for k in range(body + 1, len(parts)):
        if parts[k].rstrip("\r") == "}":
            end = k
            break
    if end is None:
        sys.exit("!! 找不到函数收尾的顶格 }：%s" % path)
    parts.insert(end, "  s")
    io.open(path, "w", encoding="utf-8", newline="").write("\n".join(parts))
    print("多行串改 let 绑定：%-42s %s（$| 行 %d 行原样未动）"
          % (path, fnsign.strip()[:44], end - body))


CT = "core/engine/compliance_test.mbt"
WT = "facade/withdraw_transfer_test.mbt"

B_PAIRS = [
    ("facade/facade.mbt",
     """    None => row.value(f.column())""",
     """    None => @json.get(row, f.column())"""),
    ("demo/seed_business.mbt",
     """        arr[0].as_string()""",
     """        @json.as_str(arr[0])"""),
    ("facade/surrogate_autoapply_test.mbt",
     """  let rows = match data_of(env).value("tasks") {""",
     """  let rows = match @json.get(data_of(env), "tasks") {"""),
    ("facade/stats.mbt",
     """  let today_prefix = @model.current_time_str().substring(start=0, end=10).to_string()""",
     """  let today_prefix = @model.current_time_str()[0:10].to_owned()"""),
]

C_PAIRS = [
    ("facade/actions_ext.mbt",
     """        enabled: arg_i64_or(args, "enabled", 1L) |> _.to_int(),""",
     """        enabled: arg_i64_or(args, "enabled", 1L).to_int(),"""),
]

D_PAIRS = [
    ("core/spi/context.mbt",
     """    from_json: fn(s) { @json.parse_json(s) },""",
     """    from_json: (s) => @json.parse_json(s),"""),
    ("persist/interceptor.mbt",
     """  { order: 100, run: fn(exec) { it.intercept(exec) } }""",
     """  { order: 100, run: (exec) => it.intercept(exec) }"""),
    ("demo/cmd/main/main.mbt",
     """  server.run_forever() <| fn(req, body, conn) {""",
     """  server.run_forever() <| async fn(req, body, conn) {"""),
    ("repository-mysql/smoke/smoke.mbt",
     """    tpl.execute_in_tx(fn() {""",
     """    tpl.execute_in_tx(async fn() {"""),
]

if __name__ == "__main__":
    wrap_multiline(CT, "fn simple_flow_json() -> String {")
    wrap_multiline(WT, "fn linear_flow_json() -> String {")
    wrap_multiline(WT, "fn shared_task_flow_json() -> String {")
    wrap_multiline(WT, "fn countersign_flow_json() -> String {")
    for path, old, new in B_PAIRS + C_PAIRS + D_PAIRS:
        patch(path, [(old, new)])
