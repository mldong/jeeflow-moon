#!/usr/bin/env python
"""探针：负向用例的**逐点** try/catch 形状（不引异步闭包助手）。

上一支探针（core/engine/probe_async_closure_test.mbt）的实测结论，供后续判断：
  - `Future` 在本包不可直呼（The type Future is undefined）；
  - 前缀 `await` 在本工具链已不是合法表达式（The value identifier await is unbound），
    仓库里能过的是**隐式 await**（`let x = f_async(...)`）与后缀 `.await()`；
  - 普通 `fn() { ... }` 闭包里不能调 async 函数（cannot call async function in non-async function），
    而泛型声明的新写法是 `fn [A] name(...)`，不是 `fn name[A](...)`。
  ⇒ "异步闭包助手"这条路要先把闭包类型语法再探一轮；本轮先用**最不悬空的形状**：
    每处 try/catch 就地写，成功路径 fail(...)（Nothing，能和 catch 臂的 JeeflowError 合一型）。

本脚本只改 compliance2_test.mbt 的 r07 一处，用来验形状；形状确认后再批量。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

PAIRS = [
    (
        """  let r07 = engine.execute_and_jump_async(apply.task_id, "applicant", @json.FlowData::new(), None)
  match r07 {
    Ok(_) => fail("无血缘（parent=0L）必须报错，不得静默不建单")
    Err(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
        """  // 新效果系统下调用不再返回 Result：判"必须抛错"就地 try/catch，
  // 成功路径 fail(...)（旧 Ok 臂 fail 同一条红），抛出的错误继续逐字判文案。
  let e07 = try {
    let _ = engine.execute_and_jump_async(apply.task_id, "applicant", @json.FlowData::new(), None)
    fail("无血缘（parent=0L）必须报错，不得静默不建单")
  } catch {
    e => e
  }
  assert_true(e07.message() == "上一步任务ID为空，无法驳回至上一步处理")
""",
    ),
]

if __name__ == "__main__":
    patch("core/engine/compliance2_test.mbt", PAIRS)
