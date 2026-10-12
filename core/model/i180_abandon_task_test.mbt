// issues/180 · abandonTask 摘副作用（owner 2026-10-13 拍板 A）——聚合根级。
// 契约：abandon_task 仅废任务（任务=99），实例 state 不动（≠99）——对齐 spec 04:329
// 「废弃单个任务」与 go/py/node 三栈形状；五栈原「连带置 99」为自创（boot2/boot3 零命中血统反证）。
// 判据：① 正向——任务 99、实例仍 10；② 负向——任务不在聚合内照旧 TaskNotFound；③ 回归——别行不动。

///|
test "i180 正向：abandon_task 只废任务，实例 state 仍 10（不连带置 99）" {
  let inst = wg_doing_instance()
  inst.tasks[0].task_id = 9527L
  inst.abandon_task(9527L)
  assert_eq(inst.tasks[0].task_state, @model.TaskState::Abandon.code())
  assert_eq(inst.state, @model.InstanceState::Doing.code())
}

///|
test "i180 负向：任务不在聚合内照旧 TaskNotFound（实例态不动）" {
  let inst = wg_doing_instance()
  let raised = try {
    inst.abandon_task(88888L)
    None
  } catch {
    e => Some(e)
  }
  assert_true(raised is Some(_))
  assert_eq(inst.state, @model.InstanceState::Doing.code())
}

///|
test "i180 回归：只废目标任务，其余行不动" {
  let inst = wg_doing_instance()
  let _ = inst.create_task(
    "t2", "审批2", ["leader"], "zhangsan", @model.Major, @model.Normal, None, None,
  )
  inst.tasks[0].task_id = 1L
  inst.tasks[1].task_id = 2L
  inst.abandon_task(1L)
  assert_eq(inst.tasks[0].task_state, @model.TaskState::Abandon.code())
  assert_eq(inst.tasks[1].task_state, @model.TaskState::Doing.code())
  assert_eq(inst.state, @model.InstanceState::Doing.code())
}
