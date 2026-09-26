#!/usr/bin/env python
"""警告批次 W11：一批"编译器给了明确替代写法"的确定性改写。

 1. `fn meth(self : T, ...)` 这种"用第一个参数当 self 的方法定义法"已弃办，
    新写法把类型写到名字前面：`fn T::meth(self, ...)`。4 处
    （conn.mbt 的 open_conn/open、repository.mbt 的 hydrate_tasks、tx.mbt 的 open_or_tx）。
    调用方本来就写 `self.config.open_conn()` 方法形式 ⇒ 零调用点改动。
 2. `demo/*/moon.pkg` 里 `"moonbitlang/async" @async,` 的**别名**没人用（包本身要留着跑异步运行时）
    ⇒ 去掉别名 token，保留 import（facade/moon.pkg 的 test 块就是这个写法）。
 3. conn.mbt 的 `sql_escape_text` 是死函数（LIMIT 内联那一路改完后没人调用）⇒ 删，
    连同它上面的注释块；真要回来 git 里有。

用法：python scripts/moon_warn_w11.py
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

CONN = "repository-mysql/repo/conn.mbt"

CONN_PAIRS = [
    ("""async fn open_conn(self : MysqlConfig) -> @client.MysqlConn raise @error.JeeflowError {""",
     """async fn MysqlConfig::open_conn(self) -> @client.MysqlConn raise @error.JeeflowError {"""),
    ("""async fn open(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {""",
     """async fn MysqlRepository::open(self) -> @client.MysqlConn raise @error.JeeflowError {"""),
]

REPO_PAIRS = [
    ("""async fn hydrate_tasks(self : MysqlRepository, rows : Array[@moondb.Row]) -> Array[@model.ProcessTask] raise @error.JeeflowError {""",
     """async fn MysqlRepository::hydrate_tasks(self, rows : Array[@moondb.Row]) -> Array[@model.ProcessTask] raise @error.JeeflowError {"""),
]

TX_PAIRS = [
    ("""async fn open_or_tx(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {""",
     """async fn MysqlRepository::open_or_tx(self) -> @client.MysqlConn raise @error.JeeflowError {"""),
]

ASYNC_ALIAS = [
    ("""  "moonbitlang/async" @async,\n""", """  "moonbitlang/async",\n"""),
]


def drop_dead_fn(path, name):
    """删掉整个 `fn name(...) { ... }`（含紧邻其上的 ///| 文档块），按缩进 0 的 `}` 收尾。"""
    raw = io.open(path, encoding="utf-8", newline="").read()
    m = re.search(r"(?:///\|\r?\n)?\r?\n?fn " + name + r"\b", raw)
    if not m:
        sys.exit("!! %s 里找不到 fn %s" % (path, name))
    start = m.start()
    brace = raw.index("{", m.end())
    i = brace
    depth = 0
    while True:
        c = raw[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = i + 1
    while end < len(raw) and raw[end] in "\r\n":
        end += 1
    body = raw[start:end]
    if name not in body.split("\n")[0]:
        sys.exit("!! 截取错位：%r" % body[:80])
    io.open(path, "w", encoding="utf-8", newline="").write(raw[:start] + raw[end:])
    print("删除死函数 %s::%s（%d 行）" % (path, name, body.count("\n")))


if __name__ == "__main__":
    patch(CONN, CONN_PAIRS)
    patch("repository-mysql/repo/repository.mbt", REPO_PAIRS)
    patch("repository-mysql/repo/tx.mbt", TX_PAIRS)
    for p in ("demo/cmd/main/moon.pkg", "demo/cmd/consistency/moon.pkg"):
        patch(p, ASYNC_ALIAS)
    drop_dead_fn(CONN, "sql_escape_text")
