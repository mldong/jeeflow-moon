// handler（会签门控纯函数）单测 —— 移植自 rust handler.rs tests

///|
fn make_cs_task(state : Int) -> @model.ProcessTask {
  {
    task_id: 0L,
    process_instance_id: 1L,
    task_name: "t",
    display_name: "T",
    task_type: 0,
    perform_type: 1,
    task_state: state,
    actor_id: None,
    actor_ids: ["u"],
    finish_time: None,
    expire_time: None,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
test "handler: countersign parallel all done" {
  let tasks = [@model.TaskState::Finished.code(), @model.TaskState::Finished.code(), @model.TaskState::Finished.code()].map(make_cs_task)
  assert_true(@handler.check_merge(tasks, None, None, "PARALLEL"))
}

///|
test "handler: countersign parallel not all done" {
  let tasks = [@model.TaskState::Finished.code(), @model.TaskState::Finished.code(), @model.TaskState::Doing.code()].map(make_cs_task)
  assert_true(!@handler.check_merge(tasks, None, None, "PARALLEL"))
}

///|
test "handler: countersign sequential gate" {
  let tasks = [@model.TaskState::Finished.code(), @model.TaskState::Doing.code()].map(make_cs_task)
  assert_true(!@handler.check_merge(tasks, None, None, "SEQUENTIAL"))
  let tasks = [@model.TaskState::Finished.code(), @model.TaskState::Finished.code()].map(make_cs_task)
  assert_true(@handler.check_merge(tasks, None, None, "SEQUENTIAL"))
}

///|
test "handler: one vote veto gate" {
  let tasks = [@model.TaskState::Finished.code(), @model.TaskState::Doing.code(), @model.TaskState::Doing.code()].map(make_cs_task)
  assert_true(@handler.check_merge(tasks, Some(20L), Some("ONE_VOTE_VETO"), "PARALLEL"))
  assert_true(!@handler.check_merge(tasks, Some(20L), None, "PARALLEL"))
  assert_true(!@handler.check_merge(tasks, Some(1L), Some("ONE_VOTE_VETO"), "PARALLEL"))
}
