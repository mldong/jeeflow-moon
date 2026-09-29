// issues/137 B —— **零调用者建单函数**的直调用例（owner 2026-09-29 拍板：不删，补用例钉住）。
// 被测两支：ProcessInstance::reject_task（真·零调用者，连单测都没有）、
// ProcessInstance::create_history_task（引擎零调用者，旧用例只钉了 task_state/actor_id 两列）。
// 钉的是"直调它 ⇒ 行形状与主路径一致"，防这两支在无人调的情况下悄悄漂移。
// 复用同包 model_test.mbt 的 make_define helper；时钟经 @model.set_clock 钉住（同 surrogate_test 口径）。
// ⚠️ ProcessTask 没有 derive(Eq)（aggregate.mbt 里 clone 是手写的），== 用不了
// ⇒ "全字段等价"显式写成逐列断言：assert_row_shape_same 覆盖 15 列，
//    余下 3 列（finish_time/update_time/update_user＝办理审计列）由各用例自己钉。

///|
/// 除办理审计三列外的逐列等价（建单行形状本体）
fn assert_row_shape_same(a : @model.ProcessTask, b : @model.ProcessTask) -> Unit raise {
  assert_eq(a.task_id, b.task_id)
  assert_eq(a.process_instance_id, b.process_instance_id)
  assert_eq(a.task_name, b.task_name)
  assert_eq(a.display_name, b.display_name)
  assert_eq(a.task_type, b.task_type)
  assert_eq(a.perform_type, b.perform_type)
  assert_eq(a.task_state, b.task_state)
  assert_eq(a.actor_id, b.actor_id)
  assert_true(a.actor_ids == b.actor_ids)
  assert_eq(a.expire_time, b.expire_time)
  assert_eq(a.form_key, b.form_key)
  assert_eq(a.parent_task_id, b.parent_task_id)
  assert_eq(a.variables.len(), b.variables.len())
  assert_eq(a.create_time, b.create_time)
  assert_eq(a.create_user, b.create_user)
}

///|
test "i137b: reject_task 直调逐列等于主路径建单（create_task/Major/Normal/None/Some(parent)）" {
  @model.set_clock(Some(fn() {
    "2026-09-29 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let define_info = make_define(1L, "i137b")
  // A 组：直调被测函数
  let inst_a = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let via_fn = inst_a.reject_task("approve", "审批", ["user2", "user3"], "user1", 900L)
  // B 组：主路径那一手建单（引擎各建单点调的就是这八个入参的 create_task）
  let inst_b = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let via_main = inst_b.create_task(
    "approve", "审批", ["user2", "user3"], "user1", @model.Major, @model.Normal, None, Some(900L)
  )
  assert_row_shape_same(via_fn, via_main)
  // 建单行的办理审计三列必须都还没写（与主路径同为"未办"）
  assert_eq(via_fn.finish_time, None)
  assert_eq(via_fn.update_time, None)
  assert_eq(via_fn.update_user, None)
  assert_eq(via_main.finish_time, None)
  // 再钉一遍契约本体（万一将来新增列绕过上面的比较，这组硬判据仍照得住）
  assert_eq(via_fn.task_state, @model.TaskState::Doing.code())
  assert_eq(via_fn.task_type, @model.Major.code())
  assert_eq(via_fn.perform_type, @model.Normal.code())
  assert_eq(via_fn.parent_task_id, Some(900L))
  assert_true(via_fn.actor_ids == ["user2", "user3"])
  assert_eq(via_fn.actor_id, None)
  assert_eq(via_fn.form_key, None)
  assert_eq(via_fn.expire_time, None)
  assert_eq(via_fn.create_user, Some("user1"))
  assert_eq(via_fn.create_time, Some("2026-09-29 10:00:00"))
  assert_eq(via_fn.task_id, 0L)
  assert_true(via_fn.variables.is_empty())
  // 行同样落进聚合的 tasks 集合（主路径靠它做 assign_ids / save_task）
  assert_eq(inst_a.tasks.length(), 1)
  assert_eq(inst_a.tasks[0].task_name, "approve")
  assert_true(inst_a.tasks[0].is_doing())
}

///|
test "i137b: create_history_task 直调等于主路径建单后 finish（只差办理审计三列，且有据）" {
  @model.set_clock(Some(fn() {
    "2026-09-29 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let define_info = make_define(1L, "i137b-hist")
  // A 组：直调被测函数（自动节点：一落地就是 FINISHED）
  let inst_a = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let hist = inst_a.create_history_task("auto", "自动节点", "flow.auto", @model.Major)
  // B 组：主路径那一手——先建 DOING 行，再经 ProcessTask::finish 办结
  let inst_b = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let main = inst_b.create_task(
    "auto", "自动节点", ["flow.auto"], "flow.auto", @model.Major, @model.Normal, None, None
  )
  main.finish("flow.auto")
  assert_row_shape_same(hist, main)
  // 一致的核心两列：办结行的 state 与处理人列（与 finish 写的同判据）
  assert_eq(hist.task_state, main.task_state)
  assert_eq(hist.task_state, @model.TaskState::Finished.code())
  assert_eq(hist.actor_id, main.actor_id)
  assert_eq(hist.actor_id, Some("flow.auto"))
  assert_true(hist.actor_ids == main.actor_ids)
  assert_true(hist.actor_ids == ["flow.auto"])
  // 办理审计三列里 **finish_time 现在也写**（spec/02 §6.2 第 1bis 条，2026-09-30 裁定，
  // 本用例跟着改判）：留痕行要能在 doneList/approvalRecord 里按 operator＋finish_time 查到。
  // 另两列 update_time/update_user 的差异仍「有据」——记录类没有办理那一次更新。
  // ⚠️ 上一行原为 `assert_eq(hist.finish_time, None)`（issues/137 B 当时的判据），
  // 本轮改动是把已被规范作废的旧期望换成新期望，不是把断言改松。
  assert_eq(hist.finish_time, main.finish_time)
  assert_eq(hist.finish_time, Some("2026-09-29 10:00:00"))
  assert_eq(hist.update_time, None)
  assert_eq(hist.update_user, None)
  assert_eq(main.finish_time, Some("2026-09-29 10:00:00"))
  assert_eq(main.update_time, Some("2026-09-29 10:00:00"))
  assert_eq(main.update_user, Some("flow.auto"))
  // 下游读路径认它（已办/历史按 task_state==FINISHED 取行）
  assert_eq(inst_a.get_finished_tasks().length(), 1)
  assert_true(hist.is_finished())
  assert_eq(inst_a.tasks.length(), 1)
}
