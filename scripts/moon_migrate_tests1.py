#!/usr/bin/env python
"""测试/冒烟件的 Result 壳清理（新效果系统下"调用不返回 Result"）。

三条实测出来的形状约束（证据在 scripts/moon_probe_neg_site*.py 的注释里）：
 1. 被调方声明闭集 `raise @error.JeeflowError` 时，`catch { e => … }` 的 e 就是 JeeflowError，
    `.message()` / `.code()` 可直接用；
 2. 但 **try 块里不能出现 `fail(...)`/`abort(...)`** —— 它们把 `Failure` 并进同一 raise 集，
    e 会被撑成 open 的 `Error`，于是 `.message()` 报 "Type Error has no method message"。
    ⇒ "没抛错就该红"这条判据一律挪到 try 外面（match 的 None/Some 两臂，或 try 后单独 assert）；
 3. 正向断言（旧 `assert_true(x is Ok(_))`）收敛成"抛错即用例红"，不再手搓 Result。

判据非恒真自证：负向站点若守卫消失 ⇒ 走 None 臂 fail / raised=false ⇒ 必红（与旧 Ok 臂 fail 同）。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

CT = "core/engine/compliance_test.mbt"
C2 = "core/engine/compliance2_test.mbt"
SG = "core/engine/surrogate_test.mbt"
SMOKE = "repository-mysql/smoke/smoke.mbt"
FT = "facade/facade_test.mbt"
WT = "facade/withdraw_transfer_test.mbt"

CT_PAIRS = [
    (
        """  let outcome = engine.start_async(99999L, "user1", new_args())
  assert_true(outcome is Err(_))
""",
        """  // 旧 `assert_true(outcome is Err(_))` ⇒ 物化成"到底抛没抛"
  let raised = try {
    let _ = engine.start_async(99999L, "user1", new_args())
    false
  } catch {
    _ => true
  }
  assert_true(raised)
""",
    ),
    (
        """  let outcome = engine.execute_task_async(99999L, "user1", new_args())
  assert_true(outcome is Err(_))
""",
        """  let raised = try {
    let _ = engine.execute_task_async(99999L, "user1", new_args())
    false
  } catch {
    _ => true
  }
  assert_true(raised)
""",
    ),
    (
        """  let outcome = engine.execute_task_async(tasks[0].task_id, "user999", new_args())
  assert_true(outcome is Err(_))
""",
        """  let raised = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "user999", new_args())
    false
  } catch {
    _ => true
  }
  assert_true(raised)
""",
    ),
    (
        """  let outcome = engine.context().ext_repository().find_design_by_id(1L)
  match outcome {
    Ok(r) => assert_true(r is None)
    Err(_) => assert_true(false)
  }
""",
        """  // 两臂逐字搬：拿到值 ⇒ 判它是 None；抛错 ⇒ 这条判据本就该红（旧 Err ⇒ assert_true(false)）
  let found = try {
    Some(engine.context().ext_repository().find_design_by_id(1L))
  } catch {
    _ => None
  }
  match found {
    Some(r) => assert_true(r is None)
    None => assert_true(false)
  }
""",
    ),
    (
        """    let outcome = engine.execute_task_async(tasks[0].task_id, "unauthorized_user", new_args())
    assert_true(outcome is Err(_))
""",
        """    let raised = try {
      let _ = engine.execute_task_async(tasks[0].task_id, "unauthorized_user", new_args())
      false
    } catch {
      _ => true
    }
    assert_true(raised)
""",
    ),
    (
        """  let outcome = engine.execute_task_async(tasks[0].task_id, "flow.auto", new_args())
  assert_true(outcome is Ok(_))
""",
        """  // 正向：旧 `is Ok(_)` ⇒ 没抛错才算通过（抛错走 catch 收成 false，判据不靠 test 框架兜）
  let ok = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "flow.auto", new_args())
    true
  } catch {
    _ => false
  }
  assert_true(ok)
""",
    ),
]

C2_PAIRS = [
    (
        """  let outcome = engine.execute_task_async(user_b_id, "userB", new_args())
  assert_true(outcome is Err(_))
""",
        """  let raised = try {
    let _ = engine.execute_task_async(user_b_id, "userB", new_args())
    false
  } catch {
    _ => true
  }
  assert_true(raised)
""",
    ),
    (
        """  let outcome = engine.execute_task_async(task.task_id, "intruder", new_args())
  match outcome {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e.code(), @error.ERR_BUSINESS)
  }
""",
        """  // 旧两臂 ⇒ Some(码) / None(没抛)。fail 在 try 外，否则 Failure 会撑开 catch 的 e 类型
  let raised_code = try {
    let _ = engine.execute_task_async(task.task_id, "intruder", new_args())
    None
  } catch {
    e => Some(e.code())
  }
  match raised_code {
    None => fail("非参与者办理必须被拒（旧 Ok 臂 assert_true(false)）")
    Some(c) => assert_eq(c, @error.ERR_BUSINESS)
  }
""",
    ),
]

SG_PAIRS = [
    (
        """  let jumped = engine.execute_and_jump_async(t2.task_id, "zhang", @json.FlowData::new(), Some("n3"))
  match jumped {
    Ok(tasks) => {
      sg_check(!tasks.is_empty(), "跳转应产出目标节点任务")
      sg_has(
        repo.find_task_actors(tasks[0].task_id),
        "li2",
        "跳转路径：目标节点任务参与者含代理人",
      )
    }
    Err(e) => abort("跳转失败: \\{e.message()}")
  }
""",
        """  // 旧 Err 臂是 abort(消息) ⇒ 与"让错误外抛、用例判红"同效，故两臂收敛成成功路径 +
  // 两条判据；抛错时错误自己冒到 test 框架（消息不丢）。
  let tasks = engine.execute_and_jump_async(t2.task_id, "zhang", @json.FlowData::new(), Some("n3"))
  sg_check(!tasks.is_empty(), "跳转应产出目标节点任务")
  sg_has(
    repo.find_task_actors(tasks[0].task_id),
    "li2",
    "跳转路径：目标节点任务参与者含代理人",
  )
""",
    ),
]

SMOKE_PAIRS = [
    (
        """  let outcome = tpl.execute_in_tx(fn() {
    let conn = @repo.current_tx_conn().unwrap()
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (990020, 990001, 10, 'user9x', '{}', NOW(), 't1')",
      [],
    )
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_state, create_time, create_user) VALUES (990021, 990020, 'apply', 'A', 10, NOW(), 't1')",
      [],
    )
    raise @error.Business("boom-in-tx")
  })
  check(outcome is Err(_), "回调抛错外传")
""",
        """  // 事务模板现在直接 raise：旧 `outcome is Err(_)` 物化成 Bool。
  // 判据不空转——若模板把回调异常吞了（回滚语义退化成"静默成功"），false ⇒ 这格红。
  let raised = try {
    tpl.execute_in_tx(fn() {
      let conn = @repo.current_tx_conn().unwrap()
      let _ = @repo.x(
        conn,
        "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (990020, 990001, 10, 'user9x', '{}', NOW(), 't1')",
        [],
      )
      let _ = @repo.x(
        conn,
        "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_state, create_time, create_user) VALUES (990021, 990020, 'apply', 'A', 10, NOW(), 't1')",
        [],
      )
      raise @error.Business("boom-in-tx")
    })
    false
  } catch {
    _ => true
  }
  check(raised, "回调抛错外传")
""",
    ),
    (
        """  let first = engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
  check(first is Ok(_), "第一次办理成功")
  let second = engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
  let mut code_ok = false
  match second {
    Ok(_) => code_ok = false
    Err(e) => code_ok = e.code() == @error.ERR_BUSINESS
  }
  check(code_ok, "第二次办理 99999999（任务已办理守卫）")
""",
        """  // 正向第一次：旧 `is Ok(_)`
  let first_ok = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
    true
  } catch {
    _ => false
  }
  check(first_ok, "第一次办理成功")
  // 负向第二次：守卫必须报 99999999；没抛错 ⇒ Some? 不，None 臂 ⇒ code_ok 恒 false
  let second_code = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
    None
  } catch {
    e => Some(e.code())
  }
  let code_ok = match second_code {
    Some(c) => c == @error.ERR_BUSINESS
    None => false
  }
  check(code_ok, "第二次办理 99999999（任务已办理守卫）")
""",
    ),
]

FT_PAIRS = [
    (
        """  let outcome : Result[Int64?, @error.JeeflowError] = @facade.arg_i64(args, "id")
  assert_true(outcome is Err(_))
""",
        """  // arg_i64 现签名 `-> Int64? raise JeeflowError`：非法串必须抛（旧 Err 臂）
  let raised = try {
    let _ = @facade.arg_i64(args, "id")
    false
  } catch {
    _ => true
  }
  assert_true(raised)
""",
    ),
    (
        """  let outcome : Result[Array[Int64], @error.JeeflowError] = @facade.arg_ids(empty)
  match outcome {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e.message(), "id 缺失或非法")
  }
""",
        """  // 两臂逐字搬：Some(文案) 判精确串；None(没抛) ⇒ fail
  let msg = try {
    let _ = @facade.arg_ids(empty)
    None
  } catch {
    e => Some(e.message())
  }
  match msg {
    Some(m) => assert_eq(m, "id 缺失或非法")
    None => fail("空 ids 必须显式报错（C15）")
  }
""",
    ),
]

WT_PAIRS = [
    (
        """  match (@string.parse_int64(s)) {
    Ok(v) => v
    Err(_) => abort("非法实例 id: \\{s}")
  }
""",
        """  // parse_int64 是 `-> Int64 raise`：坏数字仍旧 abort（abort 返回 Nothing，与成功臂同型）
  try { @string.parse_int64(s) } catch { _ => abort("非法实例 id: \\{s}") }
""",
    ),
]

JOBS = [(CT, CT_PAIRS), (C2, C2_PAIRS), (SG, SG_PAIRS), (SMOKE, SMOKE_PAIRS),
        (FT, FT_PAIRS), (WT, WT_PAIRS)]

if __name__ == "__main__":
    for path, pairs in JOBS:
        patch(path, pairs)
