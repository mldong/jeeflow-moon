#!/usr/bin/env python
"""警告批次 W13：unused_value 13 + "只有测试在用的 import" 归位（unused_package 6）。

unused_value 的三种取舍（都不改语义）：
  · 方法体不用 self（engine.resolve_var_refs / engine_ops.rollback_to_parent /
    JeeflowError::code / interceptor 的 resolve_table 与 filter_editable /
    writer_mem 的 columns）⇒ 函数体首行插 `let _ = self`
    ——不改签名：`Type::name(self : T)` 的形参名与 impl-with 的形状都动不得，
    而本仓 engine.mbt 里本来就有 `let _ = self` 的先例。
  · 普通形参没用（App::handle 的 meth、design_list_by_type 的 args）⇒ 前缀 `_`。
  · 模式变量没用（repository_page 两处 `Some(op) => " AND …"`：值在别的臂里 push，
    这一臂只要"有没有"这个条件）⇒ `Some(_op)`；
    测试里的 `other => fail("前置条件…")` ⇒ `_ => fail(...)`，判据一字不变。
  · 测试里只为让字面量过类型检查的 `let base = {…}` ⇒ `_base`（构造本身要保留：
    它把 OrgAssignBase 的形状钉在用例里）。
  · conn.mbt 的死函数 `sql_escape_text` ⇒ 删（LIMIT 内联那一路改完后无人调用）。

unused_package 6 条 = 3 对（包 + 别名）：core/engine 的 @id_gen、core/handler 与
repository-mysql/query 的 @json。**不是没用，是只有测试在用**——W5 一条一验时删掉就
报 11/1/5 个 error。正解是把这条 import 从常规块挪到 `for "test"` 块：
常规编译单元看不见它（两条警告一起消失），测试单元照样拿得到。
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

# (文件, 老, 新)
PAIRS = [
    ("core/error/error.mbt",
     """pub fn JeeflowError::code(self : JeeflowError) -> Int64 {
  ERR_BUSINESS""",
     """pub fn JeeflowError::code(self : JeeflowError) -> Int64 {
  let _ = self
  ERR_BUSINESS"""),
    ("persist/writer_mem.mbt",
     """pub impl DynamicTableWriter for InMemoryTableWriter with fn columns(self, _table_name, candidates) {
  candidates.copy()""",
     """pub impl DynamicTableWriter for InMemoryTableWriter with fn columns(self, _table_name, candidates) {
  let _ = self
  candidates.copy()"""),
    ("persist/interceptor.mbt",
     """fn PersistPostInterceptor::resolve_table(self : PersistPostInterceptor, model : @parser.ProcessModel) -> String? {
  let name = match model.rel_table_name {""",
     """fn PersistPostInterceptor::resolve_table(self : PersistPostInterceptor, model : @parser.ProcessModel) -> String? {
  let _ = self
  let name = match model.rel_table_name {"""),
    ("persist/interceptor.mbt",
     """  data : Map[String, Json]
) -> Map[String, Json] {
  let filtered : Map[String, Json] = Map([])""",
     """  data : Map[String, Json]
) -> Map[String, Json] {
  let _ = self
  let filtered : Map[String, Json] = Map([])"""),
    ("demo/app.mbt",
     "pub async fn App::handle(self : App, meth : String,",
     "pub async fn App::handle(self : App, _meth : String,"),
    ("facade/actions_ext.mbt",
     "Facade::design_list_by_type(self : Facade[R, E], args : Map[String, Json])",
     "Facade::design_list_by_type(self : Facade[R, E], _args : Map[String, Json])"),
    ("repository-mysql/repo/repository_page.mbt",
     """      Some(op) => " AND ta.actor_id = ?\"""",
     """      Some(_op) => " AND ta.actor_id = ?\""""),
    ("repository-mysql/repo/repository_page.mbt",
     """      Some(op) => " AND pi.operator = ?\"""",
     """      Some(_op) => " AND pi.operator = ?\""""),
    ("core/engine/compliance2_test.mbt",
     """  let base : @itl.OrgAssignBase = { user: Some(compliance_user_provider), org: None }""",
     """  let _base : @itl.OrgAssignBase = { user: Some(compliance_user_provider), org: None }"""),
    ("core/engine/compliance2_test.mbt",
     """    other => fail("前置条件：发起那条 parent 应为 0L")""",
     """    _ => fail("前置条件：发起那条 parent 应为 0L")"""),
]

# 函数体首行插 `let _ = self`：按"签名起始行前缀"定位（需全文件唯一）
INSERT_SELF = [
    ("core/engine/engine.mbt", "fn[R, E] Engine::resolve_var_refs("),
    ("core/engine/engine_ops.mbt", "fn[R, E] Engine::rollback_to_parent("),
]

MOVE_TO_TEST = [
    ("core/engine/moon.pkg", "mldong/jeeflow-core/id_gen"),
    ("core/handler/moon.pkg", "mldong/jeeflow-core/json"),
    ("repository-mysql/query/moon.pkg", "mldong/jeeflow-core/json"),
]


def insert_self(path, sig_prefix):
    raw = io.open(path, encoding="utf-8", newline="").read()
    parts = raw.split("\n")
    hits = [i for i, s in enumerate(parts) if s.rstrip("\r").startswith(sig_prefix)]
    if len(hits) != 1:
        sys.exit("!! %s 前缀 %r 命中 %d 行（需 1）" % (path, sig_prefix[:36], len(hits)))
    j = hits[0]
    while "{" not in parts[j]:
        j += 1
    cr = "\r" if parts[j].endswith("\r") else ""
    parts.insert(j + 1, "  let _ = self" + cr)
    io.open(path, "w", encoding="utf-8", newline="").write("\n".join(parts))
    print("  插 `let _ = self`：%s（签名行 %d）" % (path, j + 1))


def drop_fn(path, name):
    raw = io.open(path, encoding="utf-8", newline="").read()
    parts = raw.split("\n")
    start = [i for i, s in enumerate(parts) if s.rstrip("\r").startswith("fn " + name)]
    if len(start) != 1:
        sys.exit("!! %s 的 fn %s 命中 %d" % (path, name, len(start)))
    i = start[0]
    end = None
    for k in range(i, len(parts)):
        if parts[k].rstrip("\r") == "}":
            end = k
            break
    if end is None:
        sys.exit("!! 找不到 fn %s 的收尾顶格 }" % name)
    a = i
    while a - 1 >= 0 and parts[a - 1].rstrip("\r").strip() == "///|":
        a -= 1
    b = end + 1
    while b < len(parts) and parts[b].strip() == "":
        b += 1
    io.open(path, "w", encoding="utf-8", newline="").write("\n".join(parts[:a] + parts[b:]))
    print("  删死函数 %s::%s（第 %d-%d 行）" % (path, name, a + 1, b))


def move_to_test(pkg_path, dep):
    raw = io.open(pkg_path, encoding="utf-8", newline="").read()
    lines = raw.split("\n")
    taken = None
    keep = []
    for s in lines:
        b = s.rstrip("\r")
        if taken is None and b.strip().startswith('"' + dep + '"'):
            taken = b.strip().rstrip(",")
            continue
        keep.append(s)
    if taken is None:
        sys.exit("!! %s 里没有 %s" % (pkg_path, dep))
    body = "\n".join(keep)
    marker = '} for "test"'
    if marker in body:
        body = body.replace(marker, "  %s,\n%s" % (taken, marker), 1)
    else:
        body = body.rstrip("\n") + "\n\nimport {\n  %s,\n} for \"test\"\n" % taken
    io.open(pkg_path, "w", encoding="utf-8", newline="").write(body)
    print("  挪 import 到 test 块：%s ← %s" % (pkg_path, taken))


if __name__ == "__main__":
    by_file = {}
    for path, old, new in PAIRS:
        by_file.setdefault(path, []).append((old, new))
    for path, pairs in by_file.items():
        patch(path, pairs)
    for path, prefix in INSERT_SELF:
        insert_self(path, prefix)
    drop_fn("repository-mysql/repo/conn.mbt", "sql_escape_text")
    for pkg, dep in MOVE_TO_TEST:
        move_to_test(pkg, dep)
