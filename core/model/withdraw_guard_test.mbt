// issues/134 案 A · 撤回的**实例状态守卫**（owner 2026-09-28 拍板）。
// model 包＝聚合根级；门面级（出口 code/msg + 不落库）用例见 facade/withdraw_instance_guard_test.mbt。
//
// 缺陷：issues/113 只落了**任务行**层面的保护（已完成 20 / 已终止 40 的行不被撤回改写），
// **实例**层面谁都没判状态——对已办结(20)/已终止(40) 的实例调撤回，会把实例静默改写成 30，
// 已办列表与按状态聚合的统计凭空改历史，而调用方看不到任何报错。
//
// 判据（八栈逐字统一，权威＝Java 参考实现 WithdrawInstanceStateGuardTest ＋ spec/06 §withdraw）：
// 聚合根 withdraw 时实例 state != 10(进行中) ⇒ 抛内部码 **20010009**（本栈形状 = @error.Business
// 带固定文案，与 20010007/20010008 同形），文案逐字「流程实例非进行中，无法撤回」，
// **一行都不改、不落库**；守卫排在任务行循环之前。
// 跨栈门禁格 L2-28 只钉得住 20 档与正向 10 档（壳侧造不出 state=40 的行），
// 40 / 30 / 45 / 50 / 99 各档由本文件在栈内钉住。
//
// ⚠️ 只新增断言，没动任何既有断言的期望值。

///|
/// 出口文案逐字固定（八栈一致）；断言用**精确等值**，不用"包含 撤回"这种宽松判据
const GUARD_MSG : String = "流程实例非进行中，无法撤回"

///|
/// 负向档的撤回人：与夹具里的原始 update_user 不同，才照得出"一行都不改"
const LATE_WITHDRAWER : String = "lateWithdrawer"

///|
/// 一个进行中(10) 的实例：一条进行中任务 t1（参与者 leader），发起人 zhangsan
fn wg_doing_instance() -> @model.ProcessInstance {
  let define_info = make_define(9527L, "134-guard")
  let inst = @model.ProcessInstance::create(define_info, "zhangsan", @json.FlowData::new())
  inst.instance_id = 9001L
  let _ = inst.create_task(
    "t1", "审批", ["leader"], "zhangsan", @model.Major, @model.Normal, None, None,
  )
  inst
}

///|
/// 把实例**自然**办到 state=20（行真办结 + 聚合根 finish），不用 setState 造假形状
fn wg_finished_instance() -> @model.ProcessInstance raise {
  let inst = wg_doing_instance()
  inst.tasks[0].finish("leader")
  inst.finish()
  assert_eq(inst.state, @model.InstanceState::Finished.code())
  inst
}

///|
/// 断负向抛出：必须抛 ＋ 文案逐字相等 ＋ 实例状态/撤回人/任务行**一行未改**
fn wg_assert_rejected(
  inst : @model.ProcessInstance,
  original_state : Int,
  label : String
) -> Unit raise {
  let update_user_before = inst.update_user
  let row_states = inst.tasks.map(fn(t) { t.task_state })
  // 新效果系统下调用不再返回 Result：抛错与否用 None/Some 物化，两臂对应旧 `Ok=>fail / Err=>判文案`。
  // ⚠ 成功路径的 fail 必须在 try 外面，否则块内多出的 Failure 会把 catch 的 e 撑成 open Error。
  let raised = try {
    let _ = inst.withdraw(LATE_WITHDRAWER)
    None
  } catch {
    e => Some(e)
  }
  match raised {
    None => fail("\{label}：非进行中实例撤回必须抛，不得静默改写为 30")
    Some(e) => assert_true(e.message() == GUARD_MSG)
  }
  assert_eq(inst.state, original_state)
  // 病灶专用判据：非 30 档被拒后严禁被静默改写成 30；30 档本身由上一行的等值断言钉住
  if original_state != @model.InstanceState::Withdraw.code() {
    assert_true(inst.state != @model.InstanceState::Withdraw.code())
  }
  assert_eq(inst.update_user, update_user_before)
  for i in 0..<inst.tasks.length() {
    assert_eq(inst.tasks[i].task_state, row_states[i])
  }
}

///|
test "i134-m 负向①：已完成(20) 实例撤回 ⇒ 逐字文案 + 实例仍 20 + 行仍 20" {
  let inst = wg_finished_instance()
  assert_eq(inst.tasks[0].task_state, @model.TaskState::Finished.code())
  wg_assert_rejected(inst, @model.InstanceState::Finished.code(), "state=20")
}

///|
test "i134-m 负向②：强行终止(40) 实例撤回 ⇒ 同样拒绝 + 实例仍 40 + 行仍 40" {
  let inst = wg_doing_instance()
  inst.interrupt()
  assert_eq(inst.state, @model.InstanceState::Interrupt.code())
  wg_assert_rejected(inst, @model.InstanceState::Interrupt.code(), "state=40")
}

///|
test "i134-m 负向③：已撤回(30) 二次撤回被拒 ⇒ 状态与 update_user 仍是首次撤回的结果" {
  let inst = wg_doing_instance()
  inst.withdraw("zhangsan")
  assert_eq(inst.state, @model.InstanceState::Withdraw.code())
  assert_eq(inst.update_user.unwrap(), "zhangsan")
  wg_assert_rejected(inst, @model.InstanceState::Withdraw.code(), "state=30")
  assert_eq(inst.update_user.unwrap(), "zhangsan")
}

///|
test "i134-m 负向④：非 10 全档 sweep（20/30/40/45/50/99）一律拒且不改写" {
  // 20 已完成
  let i20 = wg_finished_instance()
  wg_assert_rejected(i20, 20, "state=20")
  // 30 已撤回
  let i30 = wg_doing_instance()
  i30.withdraw("zhangsan")
  wg_assert_rejected(i30, 30, "state=30")
  // 40 强行终止
  let i40 = wg_doing_instance()
  i40.interrupt()
  wg_assert_rejected(i40, 40, "state=40")
  // 45 已拒绝
  let i45 = wg_doing_instance()
  i45.reject()
  wg_assert_rejected(i45, 45, "state=45")
  // 50 挂起
  let i50 = wg_doing_instance()
  i50.pending()
  wg_assert_rejected(i50, 50, "state=50")
  // 99 已废弃（abandon_task 顺带把实例推到 99）
  let i99 = wg_doing_instance()
  i99.abandon_task(i99.tasks[0].task_id)
  wg_assert_rejected(i99, 99, "state=99")
}

///|
test "i134-m 正向对照：进行中(10) 实例撤回照旧成功 ⇒ 实例 30 + 进行中行 30 + 已完成行不改" {
  let inst = wg_doing_instance()
  // 先自然办结一条，撤回后它必须仍是 20（issues/113 的任务行保护保持原样）
  let done = inst.create_task(
    "t0", "申请", ["zhangsan"], "zhangsan", @model.Major, @model.Normal, None, None,
  )
  done.finish("zhangsan")
  inst.withdraw("zhangsan")
  assert_eq(inst.state, @model.InstanceState::Withdraw.code())
  assert_eq(inst.tasks[0].task_state, @model.TaskState::Withdraw.code())
  assert_eq(inst.update_user.unwrap(), "zhangsan")
  assert_eq(done.task_state, @model.TaskState::Finished.code())
}
