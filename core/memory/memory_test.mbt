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

///|
async test "memory: doneList 解析流程显示名 + operator『我的』过滤 (issues/107 A/B)" {
  let repo = @memory.MemoryRepository::new()
  let define = make_define_struct()
  repo.save_define(define)
  let inst = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  repo.save_instance(inst)
  // 同实例两个已完成任务：leader 办一个、user1 办一个（create_user 都是发起人 user1）
  let tA : @model.ProcessTask = {
    task_id: 0L,
    process_instance_id: inst.instance_id,
    task_name: "审批",
    display_name: "审批",
    task_type: 0,
    perform_type: 0,
    task_state: 20,
    actor_id: Some("leader"),
    actor_ids: ["leader"],
    finish_time: Some("2026-09-01 10:00:00"),
    expire_time: None,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some("2026-09-01 09:00:00"),
    create_user: Some("user1"),
    update_time: None,
    update_user: None,
  }
  let tB : @model.ProcessTask = {
    task_id: 0L,
    process_instance_id: inst.instance_id,
    task_name: "发起申请",
    display_name: "发起申请",
    task_type: 0,
    perform_type: 0,
    task_state: 20,
    actor_id: Some("user1"),
    actor_ids: ["user1"],
    finish_time: Some("2026-09-01 09:30:00"),
    expire_time: None,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some("2026-09-01 09:00:00"),
    create_user: Some("user1"),
    update_time: None,
    update_user: None,
  }
  repo.save_task(tA)
  repo.save_task(tB)
  // A 正向：operator=leader → 只见 tA，且行显示名非 null（= 流程显示名 "Test"）
  let q = @model.PageQuery::new(1L, 10L)
  q.set_operator(Some("leader"))
  let page = repo.page_done_tasks(q)
  assert_eq(page.record_count(), 1L)
  assert_eq(page.rows().length(), 1)
  assert_eq(page.rows()[0].task_name, "审批")
  assert_eq(page.rows()[0].define_display_name, Some("Test"))
  // B 负向：operator=user1 → 只见 tB（排除 leader 的 tA）
  let q2 = @model.PageQuery::new(1L, 10L)
  q2.set_operator(Some("user1"))
  let page2 = repo.page_done_tasks(q2)
  assert_eq(page2.record_count(), 1L)
  assert_eq(page2.rows()[0].task_name, "发起申请")
  // issues/117 §3.2（owner 拍板）：不带 operator（None）→ **空页**，不再是"无过滤即全库"。
  // 契约 spec/06 §2.5 写死 doneList 必须按 operator 过滤，"空即全量"是旁路型缺口。
  let q3 = @model.PageQuery::new(1L, 10L)
  let page3 = repo.page_done_tasks(q3)
  assert_eq(page3.record_count(), 0L)
  assert_eq(page3.rows().length(), 0)
  // 空串同罪（不能靠"列值不可能为空串"侥幸，得判据本身封死）
  let q4 = @model.PageQuery::new(1L, 10L)
  q4.set_operator(Some(""))
  assert_eq(repo.page_done_tasks(q4).record_count(), 0L)
  // 回归：分页五键在判据收紧后仍成立
  let q5 = @model.PageQuery::new(1L, 1L)
  q5.set_operator(Some("leader"))
  let page5 = repo.page_done_tasks(q5)
  assert_eq(page5.record_count(), 1L)
  assert_eq(page5.total_page(), 1L)
}

///|
/// issues/117 §3.3（owner 拍板取 `<> 10` 家族）：已办 = 「我经手过且不再是我待办」，
/// 状态集合含 20 办结 / 30 撤回 / 40 终止 / 99 废弃，仅 10 进行中排除。
/// 原 `== 20` 让撤回单从待办与已办两头消失（issues/113 刚把撤回态统一成 30）。
/// SQL 仓同判据真机对拍见 repository-mysql/smoke 的 T1-I117（同数据同答案 = 条款 6 通则）。
async test "memory: doneList 状态集合 = task_state <> 10（20/30/40/99 四条全进，10 不进）" {
  let repo = @memory.MemoryRepository::new()
  let define = make_define_struct()
  repo.save_define(define)
  let inst = @model.ProcessInstance::create(define, "boss", @json.FlowData::new())
  repo.save_instance(inst)
  let states : Array[Int] = [20, 30, 40, 99, 10]
  for s in states {
    let t : @model.ProcessTask = {
      task_id: 0L,
      process_instance_id: inst.instance_id,
      task_name: "n\{s}",
      display_name: "节点\{s}",
      task_type: 0,
      perform_type: 0,
      task_state: s,
      actor_id: if s == 10 { None } else { Some("leader") },
      actor_ids: ["leader"],
      finish_time: None,
      expire_time: None,
      form_key: None,
      parent_task_id: None,
      variables: @json.FlowData::new(),
      create_time: Some("2026-09-01 09:00:00"),
      // create_user 是发起人：已办不得按它放行（issues/107/Rust 那格违约点）
      create_user: Some("boss"),
      update_time: None,
      update_user: None,
    }
    repo.save_task(t)
  }
  let q = @model.PageQuery::new(1L, 10L)
  q.set_operator(Some("leader"))
  let page = repo.page_done_tasks(q)
  // 正向：20/30/40/99 四条都在
  assert_eq(page.record_count(), 4L)
  // 每个态一行，行名即态：n20 / n30 / n40 / n99 必须都在
  for want in ["n20", "n30", "n40", "n99"] {
    assert_true(page.rows().exists(r => r.task_name == want))
  }
  // 负向：DOING(10) 不进（它是待办，不是已办）
  assert_true(!page.rows().exists(r => r.task_name == "n10"))
  // 归属列仍是办理人：boss（发起人 / create_user）看不到任何一行
  let q2 = @model.PageQuery::new(1L, 10L)
  q2.set_operator(Some("boss"))
  assert_eq(repo.page_done_tasks(q2).record_count(), 0L)
  // 分页截断仍按 pageSize
  let q3 = @model.PageQuery::new(1L, 2L)
  q3.set_operator(Some("leader"))
  let page3 = repo.page_done_tasks(q3)
  assert_eq(page3.record_count(), 4L)
  assert_eq(page3.rows().length(), 2)
  assert_eq(page3.total_page(), 2L)
}

///|
async test "memory: instancePage/ccList operator『我的』过滤 (issues/108)" {
  let repo = @memory.MemoryRepository::new()
  let define = make_define_struct()
  repo.save_define(define)
  // 两个实例：user1 发起一个、leader 发起一个（实例 operator 即发起人）
  let instA = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  repo.save_instance(instA)
  let instB = @model.ProcessInstance::create(define, "leader", @json.FlowData::new())
  repo.save_instance(instB)
  // 抄送：instA 抄给 leader/user2，instB 抄给 user1（共 3 行）
  repo.create_cc_instance(instA.instance_id, "user1", ["leader", "user2"])
  repo.create_cc_instance(instB.instance_id, "leader", ["user1"])

  // instancePage 正向：operator=user1 → 只见 user1 发起的实例
  let q = @model.PageQuery::new(1L, 10L)
  q.set_operator(Some("user1"))
  let page = repo.page_instances(q)
  assert_eq(page.record_count(), 1L)
  assert_eq(page.rows().length(), 1)
  assert_eq(page.rows()[0].operator, "user1")
  // instancePage 负向：operator=leader → 只见 leader 发起的实例（排除 user1 的）
  let q2 = @model.PageQuery::new(1L, 10L)
  q2.set_operator(Some("leader"))
  let page2 = repo.page_instances(q2)
  assert_eq(page2.record_count(), 1L)
  assert_eq(page2.rows()[0].operator, "leader")
  // 回归：不带 operator（None）→ 全量 2
  let q3 = @model.PageQuery::new(1L, 10L)
  let page3 = repo.page_instances(q3)
  assert_eq(page3.record_count(), 2L)

  // ccList 正向：operator=leader → 只见抄给 leader 的行
  let qc = @model.PageQuery::new(1L, 10L)
  qc.set_operator(Some("leader"))
  let pagec = repo.page_cc_instances(qc)
  assert_eq(pagec.record_count(), 1L)
  assert_eq(pagec.rows().length(), 1)
  assert_eq(pagec.rows()[0].operator, "leader")
  // ccList 负向：operator=user1 → 只见抄给 user1 的行（排除 leader/user2 的）
  let qc2 = @model.PageQuery::new(1L, 10L)
  qc2.set_operator(Some("user1"))
  let pagec2 = repo.page_cc_instances(qc2)
  assert_eq(pagec2.record_count(), 1L)
  assert_eq(pagec2.rows()[0].operator, "user1")
  // 回归：不带 operator（None）→ 全量 3 行 cc
  let qc3 = @model.PageQuery::new(1L, 10L)
  let pagec3 = repo.page_cc_instances(qc3)
  assert_eq(pagec3.record_count(), 3L)
}
