// model 单测 —— 移植自 rust model.rs tests

///|
fn make_define(id : Int64, name : String) -> @model.ProcessDefine {
  {
    id,
    name,
    display_name: name + " Display",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
test "model: instance create" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  assert_eq(inst.state, @model.InstanceState::Doing.code())
  assert_eq(inst.operator, "user1")
  assert_eq(inst.define_id, 1L)
}

///|
test "model: task lifecycle and permission" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let task = inst.create_task("task1", "Task 1", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  task.task_id = 100L
  assert_true(task.is_doing())
  assert_true(task.is_allowed("user1"))
  assert_true(!task.is_allowed("user2"))
  try {
    task.finish("user1")
  } catch {
    e => raise e
  }
  assert_true(task.is_finished())
  assert_eq(task.actor_id.unwrap(), "user1")
}

///|
test "model: finish wrong actor and double finish (负向)" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let task = inst.create_task("task1", "Task 1", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  assert_true((try? task.finish("user2")) is Err(_))
  let _ = task.finish("user1")
  assert_true((try? task.finish("user1")) is Err(_))
}

///|
test "model: flow.auto bypass" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let task = inst.create_task("t", "T", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  assert_true(task.is_allowed("flow.auto"))
  assert_true(task.is_allowed("flow.admin"))
}

///|
test "model: instance withdraw → 实例 30 + 任务 30 (C28)" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let _ = inst.create_task("t", "T", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  inst.withdraw()
  assert_eq(inst.state, 30)
  assert_eq(inst.tasks[0].task_state, 30)
}

///|
test "model: page result total page" {
  let pr = @model.PageResult::new(1L, 10L, 25L, [])
  assert_eq(pr.total_page(), 3L)
  let pr = @model.PageResult::new(1L, 10L, 0L, [])
  assert_eq(pr.total_page(), 0L)
  let pr = @model.PageResult::new(1L, 10L, 20L, [])
  assert_eq(pr.total_page(), 2L)
  let pr = @model.PageResult::new(1L, 10L, 1L, [])
  assert_eq(pr.total_page(), 1L)
}

///|
test "model: state codes" {
  assert_eq(@model.DefineState::Enable.code(), 1)
  assert_true(@model.DefineState::from_code(99) is Enable)
  assert_eq(@model.InstanceState::Doing.code(), 10)
  assert_eq(@model.InstanceState::Reject.code(), 45)
  assert_eq(@model.InstanceState::from_code(99).unwrap() is Abandon, true)
  assert_true(@model.InstanceState::from_code(999) is None)
  assert_eq(@model.TaskState::Doing.code(), 10)
  assert_eq(@model.TaskState::from_code(99).unwrap() is Abandon, true)
  assert_eq(@model.TaskType::Record.code(), 2)
  assert_eq(@model.PerformType::Countersign.code(), 1)
}

///|
test "model: submit type codes" {
  assert_eq(@model.SubmitType::from_code(0L).unwrap() is Apply, true)
  assert_eq(@model.SubmitType::from_code(20L).unwrap() is CountersignDisagree, true)
  assert_true(@model.SubmitType::from_code(99L) is None)
  assert_eq(@model.SubmitType::Reject.code(), 2L)
}

///|
test "model: camel case" {
  assert_eq(@model.to_camel_case("process_instance_id"), "processInstanceId")
  assert_eq(@model.to_camel_case("a_b_c"), "aBC")
  assert_eq(@model.to_camel_case("_leading"), "Leading")
  assert_eq(@model.to_camel_case("trailing_"), "trailing")
  assert_eq(@model.to_camel_case("camelCase"), "camelCase")
}

///|
test "model: time format (Clock 注入固定钟 D-M0-3)" {
  assert_eq(@model.format_unix_utc(0L), "1970-01-01 00:00:00")
  assert_eq(@model.format_unix_utc(1704067200L), "2024-01-01 00:00:00")
  let old_clock = @model.current_time_str()
  @model.set_clock(Some(fn() { "2026-08-01 12:00:00" }))
  assert_eq(@model.current_time_str(), "2026-08-01 12:00:00")
  @model.set_clock(None)
  let t = @model.current_time_str()
  assert_eq(t.length(), 19)
  let _ = old_clock
}

///|
test "model: create_history_task" {
  let define = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let task = inst.create_history_task("auto", "自动节点", "flow.auto", @model.Major)
  assert_eq(task.task_state, 20)
  assert_eq(task.actor_id.unwrap(), "flow.auto")
}
