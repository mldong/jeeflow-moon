// issues/134 案 A · 撤回的实例状态守卫 —— **门面级**（出口 code/msg + 被拒不落库）。
// 聚合根级判据（20/30/40/45/50/99 全档 + 正向 10）见 core/model/withdraw_guard_test.mbt；
// 本文件钉的是跨栈门禁格 L2-28 的同判据：出口 `code=99999999` ＋ msg **逐字**＝
// 「流程实例非进行中，无法撤回」（内部码 20010009 不进 msg，issues/121 口径），
// 且**再读一次**实例状态仍是原值、任务行没被改写（本案病灶：改前会被静默改成 30 且不报错）。
//
// 夹具沿用 withdraw_transfer_test.mbt 的线性流（apply→task1→end）与 setup/助手；
// 撤回人用 `flow.admin` 哨兵（spec/06 归属判据③放行），确保报错来自本案守卫，
// 而不是被鉴权分支的「无权限撤回该流程实例」抢先命中。
//
// ⚠️ 只新增断言，没动任何既有断言的期望值。

///|
/// 出口文案逐字固定（八栈一致）；用精确等值断言，不用"包含 撤回"这种宽松判据
const WG_GUARD_MSG : String = "流程实例非进行中，无法撤回"

///|
/// 把实例自然办到 state=20（leader 同意 submitType=1 → 流程走到 end → 聚合根 finish）
async fn wg_finish(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  iid : Int64
) -> Unit raise {
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("submitType", "1")]),
      ),
    ),
    "成功",
  )
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, @model.InstanceState::Finished.code())
}

///|
/// 撤回落库的改写点（update_instance / update_task）都不该被执行到：读回值逐项复原位
async fn wg_assert_nothing_persisted(
  repo : @mem.MemoryRepository,
  iid : Int64,
  update_user_before : String?,
  expect_instance_state : Int,
  expect_row_state : Int
) -> Unit raise {
  let reread = repo.find_instance_by_id(iid).unwrap()
  assert_eq(reread.state, expect_instance_state)
  assert_eq(reread.update_user, update_user_before)
  for t in repo.find_history_tasks(iid) {
    assert_eq(t.task_state, expect_row_state)
  }
}

///|
async test "i134-f 负向①(L2-28 同判据)：真办结到 state=20 调撤回 ⇒ 99999999 + 逐字文案 + 再读仍 20" {
  let (facade, repo, iid) = setup(linear_flow_json())
  wg_finish(facade, repo, iid)
  let update_user_before = repo.find_instance_by_id(iid).unwrap().update_user
  let resp = facade.flow(
    "processInstance/withdraw",
    targs([("id", iid.to_string()), ("operator", "flow.admin")]),
  )
  assert_eq(code_of(resp), 99999999L)
  assert_eq(msg_of(resp), WG_GUARD_MSG)
  // 再读一次：状态仍是 20、撤回人没进 update_user、两条行(apply/task1)仍是 20
  wg_assert_nothing_persisted(repo, iid, update_user_before, 20, 20)
}

///|
async test "i134-f 负向②：强行终止(40) 档——门面没有终止 action，用聚合根 interrupt 自然推到 40" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let inst = repo.find_instance_by_id(iid).unwrap()
  inst.interrupt()
  repo.update_instance(inst)
  for t in inst.tasks {
    if t.task_state == @model.TaskState::Interrupt.code() {
      repo.update_task(t)
    }
  }
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, @model.InstanceState::Interrupt.code())
  let update_user_before = repo.find_instance_by_id(iid).unwrap().update_user
  let resp = facade.flow(
    "processInstance/withdraw",
    targs([("id", iid.to_string()), ("operator", "flow.admin")]),
  )
  assert_eq(code_of(resp), 99999999L)
  assert_eq(msg_of(resp), WG_GUARD_MSG)
  // 被拒后实例仍 40、update_user 未改写、没有任何一行被改成 30
  let reread = repo.find_instance_by_id(iid).unwrap()
  assert_eq(reread.state, @model.InstanceState::Interrupt.code())
  assert_eq(reread.update_user, update_user_before)
  for t in repo.find_history_tasks(iid) {
    assert_true(t.task_state != @model.TaskState::Withdraw.code())
  }
}

///|
async test "i134-f 正向对照：进行中(10) 实例撤回照旧 code=0，实例与进行中行落 30（防守卫写反）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let doing_id = doing_task_for(repo, iid, "leader").task_id
  let resp = facade.flow(
    "processInstance/withdraw",
    targs([("id", iid.to_string()), ("operator", "applicant")]),
  )
  assert_eq(code_of(resp), 0L)
  assert_eq(msg_of(resp), "成功")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, @model.InstanceState::Withdraw.code())
  assert_eq(
    repo.find_task_by_id(doing_id).unwrap().task_state,
    @model.TaskState::Withdraw.code(),
  )
}

///|
async test "i134-f 回归：必填/鉴权分支仍排在状态守卫之前（已办结实例上第三人仍是鉴权文案）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  wg_finish(facade, repo, iid)
  let update_user_before = repo.find_instance_by_id(iid).unwrap().update_user
  // 缺 operator：仍走必填分支（issues/114 的文案未被动）
  assert_eq(
    msg_of(facade.flow("processInstance/withdraw", targs([("id", iid.to_string())]))),
    "operator 必填",
  )
  // 无关第三人：三条归属判据全不命中 ⇒ 仍是鉴权文案，不是本案的实例态文案
  assert_eq(
    msg_of(
      facade.flow(
        "processInstance/withdraw",
        targs([("id", iid.to_string()), ("operator", "intruder")]),
      ),
    ),
    "无权限撤回该流程实例",
  )
  // 两条负向都不改状态（实例仍 20，守卫分支顺序未被本案挪动）
  wg_assert_nothing_persisted(repo, iid, update_user_before, 20, 20)
}
