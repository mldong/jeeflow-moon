// memory 仓储单测 —— 移植自 rust memory.rs tests

///|
fn make_define_struct() -> @model.ProcessDefine {
  {
    id: 0L,
    name: "test",
    display_name: "Test",
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
async test "memory: define crud" {
  let repo = @memory.MemoryRepository::new()
  let define = make_define_struct()
  repo.save_define(define)
  assert_true(define.id > 0L)
  let found = repo.find_define_by_id(define.id)
  assert_true(found is Some(_))
  assert_eq(found.unwrap().name, "test")
  repo.update_define_state(define.id, 0)
  let found = repo.find_define_by_id(define.id).unwrap()
  assert_eq(found.state, 0)
  repo.remove_define(define.id)
  let found = repo.find_define_by_id(define.id)
  assert_true(found is None)
}

///|
async test "memory: instance and tasks" {
  let repo = @memory.MemoryRepository::new()
  let define = make_define_struct()
  repo.save_define(define)
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  repo.save_instance(inst)
  assert_true(inst.instance_id > 0L)
  let task = inst.create_task("apply", "Apply", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  repo.save_task(task)
  assert_true(task.task_id > 0L)
  let doing = repo.find_doing_tasks(inst.instance_id, [])
  assert_eq(doing.length(), 1)
  repo.add_task_actor(task.task_id, ["user2"])
  let actors = repo.find_task_actors(task.task_id)
  assert_true(actors.contains("user2"))
  let count = repo.count_todo_tasks("user1")
  assert_eq(count, 1L)
}

///|
async test "memory: cc instances" {
  let repo = @memory.MemoryRepository::new()
  repo.create_cc_instance(1L, "user1", ["user2", "user3"])
  repo.update_cc_status(1L, "user2")
  let page = repo.page_cc_instances(@model.PageQuery::new(1L, 10L))
  assert_eq(page.record_count(), 2L)
}

///|
async test "memory: design crud" {
  let repo = @memory.MemoryRepository::new()
  let design : @model.ProcessDesign = {
    id: 0L,
    name: "design1",
    display_name: "Design 1",
    design_type: "approval",
    icon: None,
    is_deployed: 0,
    remark: None,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_design(design)
  assert_true(design.id > 0L)
  let found = repo.find_design_by_id(design.id)
  assert_true(found is Some(_))
  repo.remove_design(design.id)
  let found = repo.find_design_by_id(design.id)
  assert_true(found is None)
}

///|
async test "memory: surrogate get" {
  let repo = @memory.MemoryRepository::new()
  let sg : @model.ProcessSurrogate = {
    id: 0L,
    process_name: "test",
    operator: "user1",
    surrogate: "user2",
    start_time: None,
    end_time: None,
    enabled: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_surrogate(sg)
  assert_true(sg.id > 0L)
  let found = repo.get_surrogate("user1", "test", "NOW")
  assert_true(found is Some(_))
  assert_eq(found.unwrap().surrogate, "user2")
}

///|
async test "memory: design his newest first" {
  let repo = @memory.MemoryRepository::new()
  for i in 0..<3 {
    let his : @model.ProcessDesignHis = {
      id: 0L,
      process_design_id: 1L,
      content: "v\{i}",
      create_time: None,
      create_user: None,
    }
    repo.save_design_his(his)
  }
  let list = repo.list_design_his(1L)
  assert_eq(list.length(), 3)
  assert_eq(list[0].content, "v2")
  assert_eq(list[2].content, "v0")
}
