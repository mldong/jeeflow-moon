#!/usr/bin/env python
"""探针第二轮：把 `fail(...)` 挪出 try ⇒ catch 绑定才可能是 JeeflowError。

第一轮（scripts/moon_probe_neg_site.py）实测到的关键事实：
  try 块里写 `fail("…")` 会把 `Failure` 并进该块的 raise 集，
  于是 `catch { e => e }` 的 e 被推成 open 的 `Error` ⇒ `.message()` 报
  "Type Error has no method message"。被调方声明的是闭集 `raise @error.JeeflowError`，
  是**块内多出来的 Failure** 把它撑开的。
  ⇒ 成功路径不能在被判的 try 里 fail，改成"try 给 None / catch 给 Some(e)"，
    match 两臂分别落旧代码的 Ok⇒fail / Err⇒判文案，判据一样非恒真。

本轮同时把 compliance2_test.mbt 剩下的 4 处同形站点（r07b/r07c/r08/outcome）一起改。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

F = "core/engine/compliance2_test.mbt"

PAIRS = [
    # ── r07（第一轮的形状换成 None/Some）──
    (
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
        """  // 新效果系统下调用不再返回 Result：抛错与否用 None/Some 物化，
  // 两臂逐字对应旧 `Ok(_) => fail / Err(e) => 判文案`。
  // ⚠ 成功路径的 fail 必须在 try 外面，否则块内多出的 Failure 会把 catch 的 e 撑成 open Error。
  let raised07 = try {
    let _ = engine.execute_and_jump_async(apply.task_id, "applicant", @json.FlowData::new(), None)
    None
  } catch {
    e => Some(e)
  }
  match raised07 {
    None => fail("无血缘（parent=0L）必须报错，不得静默不建单")
    Some(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
    ),
    # ── r07b ──
    (
        """  let r07b = engine.execute_and_jump_async(apply_b.task_id, "applicant", @json.FlowData::new(), None)
  match r07b {
    Ok(_) => fail("parent=None 的老行必须报错，不得静默不建单")
    Err(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
        """  let raised07b = try {
    let _ = engine.execute_and_jump_async(apply_b.task_id, "applicant", @json.FlowData::new(), None)
    None
  } catch {
    e => Some(e)
  }
  match raised07b {
    None => fail("parent=None 的老行必须报错，不得静默不建单")
    Some(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
    ),
    # ── r07c ──
    (
        """  let r07c = engine.execute_and_jump_async(apply_c.task_id, "applicant", @json.FlowData::new(), None)
  match r07c {
    Ok(_) => fail("parent 指不到真实行时必须报错，不得静默不建单")
    Err(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
        """  let raised07c = try {
    let _ = engine.execute_and_jump_async(apply_c.task_id, "applicant", @json.FlowData::new(), None)
    None
  } catch {
    e => Some(e)
  }
  match raised07c {
    None => fail("parent 指不到真实行时必须报错，不得静默不建单")
    Some(e) => assert_true(e.message() == "上一步任务ID为空，无法驳回至上一步处理")
  }
""",
    ),
    # ── r08（fork 守卫，文案不同）──
    (
        """  let r08 = engine2.execute_and_jump_async(br.task_id, who2, @json.FlowData::new(), None)
  match r08 {
    Ok(_) => fail("血缘前驱跨不过 fork 时必须被守卫拦下")
    Err(e) => assert_true(e.message() == "无法驳回至上一步处理，请确认上一步骤并非fork、join、suprocess以及会签任务")
  }
""",
        """  let raised08 = try {
    let _ = engine2.execute_and_jump_async(br.task_id, who2, @json.FlowData::new(), None)
    None
  } catch {
    e => Some(e)
  }
  match raised08 {
    None => fail("血缘前驱跨不过 fork 时必须被守卫拦下")
    Some(e) => assert_true(e.message() == "无法驳回至上一步处理，请确认上一步骤并非fork、join、suprocess以及会签任务")
  }
""",
    ),
]

if __name__ == "__main__":
    patch(F, PAIRS)
