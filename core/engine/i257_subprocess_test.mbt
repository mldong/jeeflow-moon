// issues/257 · jeeflow-moon 子流程定向 T0（内存仓；不起服务、不连 DB）。
// 覆盖：三别名/键回落、选版、真父子闭环、自办、零写入预检、回父时机、结束闸与驳回。

///|
fn i257_make_engine() -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
  Array[@event.ProcessEvent],
) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let events : Array[@event.ProcessEvent] = []
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  ctx2.register_event_listener_sync(fn(ev) { events.push(ev) })
  (@engine.Engine::make(ctx2), repo, events)
}

///|
async fn i257_add_define(
  repo : @mem.MemoryRepository,
  id : Int64,
  name : String,
  version : Int,
  state : Int,
  content : String,
) -> @model.ProcessDefine raise {
  let define_info : @model.ProcessDefine = {
    id,
    name,
    display_name: name,
    define_type: "approval",
    state,
    content,
    version,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  define_info
}

///|
fn i257_flow(name : String, nodes : Array[(String, String, String)]) -> String {
  let node_parts = StringBuilder()
  let edge_parts = StringBuilder()
  let mut previous = ""
  for i, node in nodes {
    let (id, node_type, properties) = node
    if i > 0 {
      node_parts.write_string(",")
    }
    if i > 1 {
      edge_parts.write_string(",")
    }
    if i > 0 {
      edge_parts.write_string(
        "{\"id\":\"e\{i}\",\"sourceNodeId\":\"\{previous}\",\"targetNodeId\":\"\{id}\",\"properties\":{}}",
      )
    }
    node_parts.write_string(
      "{\"id\":\"\{id}\",\"type\":\"\{node_type}\",\"properties\":{\{properties}},\"text\":{\"value\":\"\{id}\"}}",
    )
    previous = id
  }
  let result =
    $|{"name":"\{name}","displayName":"\{name}","type":"approval",
    $| "nodes":[\{node_parts.to_string()}],"edges":[\{edge_parts.to_string()}]}
  result
}

///|
fn i257_child_flow(name : String, review : String) -> String {
  i257_flow(
    name,
    [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\",\"performType\":0"),
      (review, "snaker:task", "\"assignee\":\"leader\",\"performType\":0"),
      ("end", "snaker:end", ""),
    ],
  )
}

///|
fn i257_parent_flow(
  name : String,
  child_name : String,
  properties : String,
) -> String {
  let _ = child_name
  i257_flow(
    name,
    [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\",\"performType\":0"),
      ("sub", "snaker:subProcess", properties),
      ("parentAfter", "snaker:task", "\"assignee\":\"manager\",\"form\":\"parent-form\",\"performType\":0"),
      ("end", "snaker:end", ""),
    ],
  )
}

///|
async fn i257_only_doing(
  repo : @mem.MemoryRepository,
  instance_id : Int64,
  task_name : String,
) -> @model.ProcessTask raise {
  for task in repo.find_doing_tasks(instance_id, [task_name]) {
    return task
  }
  fail("缺少 DOING 任务 \{task_name}，instance=\{instance_id}")
}

///|
async fn i257_only_child(
  repo : @mem.MemoryRepository,
  parent_id : Int64,
) -> @model.ProcessInstance raise {
  let mut found : @model.ProcessInstance? = None
  for instance in repo.get_all_instances() {
    if instance.parent_id == Some(parent_id) {
      if found is Some(_) {
        fail("父实例 \{parent_id} 出现多个子实例")
      }
      found = Some(instance)
    }
  }
  match found {
    Some(child) => child
    None => fail("父实例 \{parent_id} 没有子实例")
  }
}

///|
fn i257_count_event(
  events : Array[@event.ProcessEvent],
  event_name : String,
  instance_id : Int64,
) -> Int {
  let mut count = 0
  for event in events {
    if event.event_type().name() == event_name &&
      (event.source_id() == instance_id || event.data.get_i64("instanceId") == Some(instance_id)) {
      count = count + 1
    }
  }
  count
}

///|
fn i257_new_args() -> @json.FlowData {
  @json.FlowData::new()
}

// ── 解析与纯函数 ──────────────────────────────────────────────────────────

///|
test "i257 parser: subProcess/subprocess/wfSubProcess 三别名同值" {
  for raw in [
    "snaker:subProcess", "snaker:subprocess", "snaker:wfSubProcess",
    "subProcess", "subprocess", "wfSubProcess",
  ] {
    assert_true(@parser.NodeType::from_snaker_type(raw) is @parser.SubProcess)
  }
}

///|
test "i257 parser: processName→name→id，form/version 保留且 subProcessName 不参与" {
  let by_process = @parser.parse_model(
    i257_flow("p1", [
      ("start", "snaker:start", ""),
      ("sub", "snaker:subProcess", "\"processName\":\"target\",\"name\":\"wrong\",\"form\":\"wrong-form\",\"version\":1"),
      ("end", "snaker:end", ""),
    ]),
  )
  let node = by_process.get_node("sub").unwrap()
  assert_eq(node.process_name(), "target")
  assert_eq(node.sub_process_form(), Some("wrong-form"))
  assert_eq(node.sub_process_version(), Some(1L))

  let by_name = @parser.parse_model(
    i257_flow("p2", [
      ("start", "snaker:start", ""),
      ("sub", "snaker:subprocess", "\"processName\":\"  \",\"name\":\"target\",\"form\":\"wrong-form\""),
      ("end", "snaker:end", ""),
    ]),
  )
  assert_eq(by_name.get_node("sub").unwrap().process_name(), "target")

  let by_id = @parser.parse_model(
    i257_flow("p3", [
      ("start", "snaker:start", ""),
      ("target", "snaker:wfSubProcess", "\"subProcessName\":\"not-contract\""),
      ("end", "snaker:end", ""),
    ]),
  )
  assert_eq(by_id.get_node("target").unwrap().process_name(), "target")
}

///|
test "i257 childArgs: 复制业务参数并剥除父控制键，不改父 args" {
  let parent = @json.FlowData::new()
  parent.insert_str("f_business", "keep")
  parent.insert_str("submitType", "1")
  parent.insert_str("f_nextNodeOperator", "bad-f")
  parent.insert_str("tf_nextNodeOperator", "bad-tf")
  parent.insert_str("tf_ccActors", "bad-cc")
  parent.insert_str("_branchCtx", "bad-branch")
  parent.insert_str("_reapplyContext", "bad-reapply")
  let child = @engine.child_args(parent)
  assert_eq(child.get_str("f_business"), Some("keep"))
  for key in [
    "submitType", "f_nextNodeOperator", "tf_nextNodeOperator",
    "tf_ccActors", "_branchCtx", "_reapplyContext",
  ] {
    assert_true(!child.contains_key(key))
    assert_true(parent.contains_key(key))
  }
}

///|
test "i257 canRejected: 跳过 SubProcess 且会签父节点不可退" {
  let sub_model = @parser.parse_model(
    i257_flow("guard-sub", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("sub", "snaker:subProcess", "\"processName\":\"child\""),
      ("after", "snaker:task", "\"assignee\":\"manager\""),
      ("end", "snaker:end", ""),
    ]),
  )
  assert_true(!sub_model.can_rejected("after", "apply"))

  let cs_model = @parser.parse_model(
    i257_flow("guard-cs", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("cs", "snaker:task", "\"assignee\":\"leader\",\"performType\":1"),
      ("after", "snaker:task", "\"assignee\":\"manager\""),
      ("end", "snaker:end", ""),
    ]),
  )
  assert_true(!cs_model.can_rejected("after", "cs"))
  assert_true(cs_model.can_rejected("after", "apply"))
}

///|
async test "i257 operator: flow.auto/admin 回退父 operator，普通办理人原样保留" {
  let (_engine, repo, _events) = i257_make_engine()
  let define_info = i257_add_define(repo, 0L, "operator257", 1, 1, i257_child_flow("operator257", "review"))
  let parent = @model.ProcessInstance::create(define_info, "applicant", i257_new_args())
  assert_eq(@engine.real_operator("FLOW.AUTO", parent), "applicant")
  assert_eq(@engine.real_operator("flow.admin", parent), "applicant")
  assert_eq(@engine.real_operator("leader", parent), "leader")
}

// ── 定义定位与零写入预检 ──────────────────────────────────────────────────

///|
async test "i257 define: null 取 version desc,id desc 最新，显式版本精确且不额外过滤 state" {
  let (engine, repo, _events) = i257_make_engine()
  let v1 = i257_add_define(repo, 5001L, "versioned257", 1, 1, i257_child_flow("versioned257", "reviewV1"))
  let _v2 = i257_add_define(repo, 5002L, "versioned257", 2, 1, i257_child_flow("versioned257", "reviewV2"))
  let v2_disabled = i257_add_define(repo, 5003L, "versioned257", 2, 0, i257_child_flow("versioned257", "reviewV2Disabled"))
  let latest_parent = i257_add_define(
    repo, 0L, "parentLatest257", 1, 1,
    i257_parent_flow("parentLatest257", "versioned257", "\"processName\":\"versioned257\",\"form\":\"__wrong__\""),
  )
  let parent = engine.start_and_execute_async(latest_parent.id, "applicant", i257_new_args())
  let latest_child = i257_only_child(repo, parent.instance_id)
  assert_eq(latest_child.define_id, v2_disabled.id)
  assert_eq(repo.find_define_by_id(latest_child.define_id).unwrap().state, 0)
  let _ = i257_only_doing(repo, latest_child.instance_id, "reviewV2Disabled")

  let exact_parent = i257_add_define(
    repo, 0L, "parentExact257", 1, 1,
    i257_parent_flow("parentExact257", "versioned257", "\"processName\":\"versioned257\",\"version\":1,\"form\":\"__wrong__\""),
  )
  let exact = engine.start_and_execute_async(exact_parent.id, "applicant", i257_new_args())
  let exact_child = i257_only_child(repo, exact.instance_id)
  assert_eq(exact_child.define_id, v1.id)
  let _ = i257_only_doing(repo, exact_child.instance_id, "reviewV1")
}

///|
async test "i257 missing: 直接出边预检 20010002，当前任务/实例/参与者/事件零写入" {
  let (engine, repo, events) = i257_make_engine()
  let parent_define = i257_add_define(
    repo, 0L, "parentMissing257", 1, 1,
    i257_parent_flow("parentMissing257", "missing257", "\"processName\":\"missing257\",\"version\":1"),
  )
  let parent = engine.start_async(parent_define.id, "applicant", i257_new_args())
  let apply = i257_only_doing(repo, parent.instance_id, "apply")
  let task_count = repo.get_all_tasks().length()
  let instance_count = repo.get_all_instances().length()
  let event_count = events.length()
  let actors_before = repo.find_task_actors(apply.task_id)

  let mut caught : @error.JeeflowError? = None
  try {
    let _ = engine.apply_initial_tasks(parent.instance_id, "applicant", i257_new_args())
  } catch {
    error => caught = Some(error)
  }
  let error = caught.unwrap()
  assert_eq(error.code(), 20010002L)
  assert_eq(error.message(), "子流程missing257定义不存在")
  assert_eq(repo.get_all_tasks().length(), task_count)
  assert_eq(repo.get_all_instances().length(), instance_count)
  assert_eq(events.length(), event_count)
  assert_eq(repo.find_task_actors(apply.task_id), actors_before)
  assert_eq(repo.find_task_by_id(apply.task_id).unwrap().task_state, 10)
  assert_eq(repo.find_instance_by_id(parent.instance_id).unwrap().state, 10)
}

// ── 父子主链 ──────────────────────────────────────────────────────────────

///|
async test "i257 happy: 子申请自办、子任务只落一次、子终态后回父且父子事件各一次" {
  let (engine, repo, events) = i257_make_engine()
  let child_define = i257_add_define(repo, 0L, "child257", 1, 1, i257_child_flow("child257", "childReview"))
  let parent_define = i257_add_define(
    repo, 0L, "parent257", 1, 1,
    i257_parent_flow("parent257", "child257", "\"processName\":\"child257\",\"version\":1,\"form\":\"__wrong__\""),
  )
  let args = i257_new_args()
  args.insert_str("f_parentOnly", "parent-value")
  args.insert_str("submitType", "1")
  args.insert_str("f_nextNodeOperator", "bad-parent-next")
  args.insert_str("tf_nextNodeOperator", "bad-parent-next")
  args.insert_str("_branchCtx", "bad-parent-branch")
  args.insert_str("_reapplyContext", "bad-parent-reapply")
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", args)
  let child = i257_only_child(repo, parent.instance_id)
  assert_eq(child.parent_id, Some(parent.instance_id))
  assert_eq(child.parent_node_name, Some("sub"))
  assert_eq(child.define_id, child_define.id)
  assert_eq(child.operator, "applicant")
  assert_eq(child.state, 10)
  assert_eq(child.variables.get_str("f_parentOnly"), Some("parent-value"))
  for key in [
    "submitType", "f_nextNodeOperator", "tf_nextNodeOperator",
    "_branchCtx", "_reapplyContext",
  ] {
    assert_true(!child.variables.contains_key(key))
  }
  let child_apply = repo.find_done_tasks(child.instance_id, ["apply"])[0]
  assert_eq(child_apply.task_state, 20)
  assert_eq(child_apply.actor_id, Some("flow.auto"))
  assert_true(repo.find_task_actors(child_apply.task_id).contains("applicant"))
  let review = i257_only_doing(repo, child.instance_id, "childReview")
  assert_eq(repo.get_all_tasks().length(), 3)
  assert_eq(i257_count_event(events, "PROCESS_TASK_START", child.instance_id), 2)
  assert_eq(i257_count_event(events, "PROCESS_TASK_START", parent.instance_id), 1)

  let finish_child = i257_new_args()
  finish_child.insert_i64("submitType", 1L)
  finish_child.insert_str("f_childOnly", "child-value")
  let _ = engine.execute_task_async(review.task_id, "leader", finish_child)
  let child_done = repo.find_instance_by_id(child.instance_id).unwrap()
  let parent_running = repo.find_instance_by_id(parent.instance_id).unwrap()
  assert_eq(child_done.state, 20)
  assert_eq(parent_running.state, 10)
  assert_true(parent_running.variables.get_str("f_parentOnly") == Some("parent-value"))
  assert_true(parent_running.variables.get_str("f_childOnly") is None)
  let parent_after = i257_only_doing(repo, parent.instance_id, "parentAfter")
  assert_eq(parent_after.form_key, Some("parent-form"))
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", parent.instance_id), 0)
  assert_eq(i257_count_event(events, "PROCESS_TASK_START", parent.instance_id), 2)

  let finish_parent = i257_new_args()
  finish_parent.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(parent_after.task_id, "manager", finish_parent)
  assert_eq(repo.find_instance_by_id(parent.instance_id).unwrap().state, 20)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_START", child.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_START", parent.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", parent.instance_id), 1)
  assert_eq(repo.get_all_tasks().length(), 4)
}

///|
async test "i257 noApply: 无申请节点也自办首任务并保留真实子审批" {
  let (engine, repo, _events) = i257_make_engine()
  let child_define = i257_add_define(
    repo, 0L, "childNoApply257", 1, 1,
    i257_flow("childNoApply257", [
      ("start", "snaker:start", ""),
      ("first", "snaker:task", "\"assignee\":\"leader\""),
      ("second", "snaker:task", "\"assignee\":\"manager\""),
      ("end", "snaker:end", ""),
    ]),
  )
  let parent_define = i257_add_define(
    repo, 0L, "parentNoApply257", 1, 1,
    i257_parent_flow("parentNoApply257", "childNoApply257", "\"processName\":\"childNoApply257\",\"version\":1"),
  )
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", i257_new_args())
  let child = i257_only_child(repo, parent.instance_id)
  assert_eq(child.define_id, child_define.id)
  let first = repo.find_done_tasks(child.instance_id, ["first"])[0]
  assert_eq(first.actor_id, Some("flow.auto"))
  assert_true(repo.find_task_actors(first.task_id).contains("applicant"))
  let second = i257_only_doing(repo, child.instance_id, "second")
  assert_eq(second.actor_ids, ["manager"])
}

///|
async test "i257 immediateEnd: 子瞬间办结不把父旧聚合写回 DOING" {
  let (engine, repo, events) = i257_make_engine()
  let _child_define = i257_add_define(
    repo, 0L, "childInstant257", 1, 1,
    i257_flow("childInstant257", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("end", "snaker:end", ""),
    ]),
  )
  let parent_define = i257_add_define(
    repo, 0L, "parentInstant257", 1, 1,
    i257_flow("parentInstant257", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("sub", "snaker:subProcess", "\"processName\":\"childInstant257\",\"version\":1"),
      ("end", "snaker:end", ""),
    ]),
  )
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", i257_new_args())
  let child = i257_only_child(repo, parent.instance_id)
  assert_eq(repo.find_instance_by_id(child.instance_id).unwrap().state, 20)
  assert_eq(repo.find_instance_by_id(parent.instance_id).unwrap().state, 20)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", parent.instance_id), 1)
  assert_eq(repo.get_all_tasks().length(), 2)
}

///|
async test "i257 immediateParentTask: 子申请即办结时父新任务进入本次动作返回" {
  let (engine, repo, _events) = i257_make_engine()
  let _child_define = i257_add_define(
    repo, 0L, "childInstantTask257", 1, 1,
    i257_flow("childInstantTask257", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("end", "snaker:end", ""),
    ]),
  )
  let parent_define = i257_add_define(
    repo, 0L, "parentInstantTask257", 1, 1,
    i257_flow("parentInstantTask257", [
      ("start", "snaker:start", ""),
      ("apply", "snaker:task", "\"assignee\":\"applicant\""),
      ("sub", "snaker:subProcess", "\"processName\":\"childInstantTask257\",\"version\":1"),
      ("parentAfter", "snaker:task", "\"assignee\":\"manager\""),
      ("end", "snaker:end", ""),
    ]),
  )
  let parent = engine.start_async(parent_define.id, "applicant", i257_new_args())
  let created = engine.apply_initial_tasks(parent.instance_id, "applicant", i257_new_args())
  assert_eq(created.length(), 1)
  assert_eq(created[0].task_name, "parentAfter")
  assert_eq(created[0].process_instance_id, parent.instance_id)
  let _ = i257_only_doing(repo, parent.instance_id, "parentAfter")
}

///|
async test "i257 lowLevel: start_with_parent_async 保留只发起不自动办理的低阶语义" {
  let (engine, repo, _events) = i257_make_engine()
  let child_define = i257_add_define(repo, 0L, "childLowLevel257", 1, 1, i257_child_flow("childLowLevel257", "review"))
  let child = engine.start_with_parent_async(
    child_define.id, "applicant", i257_new_args(), 777L, "sub",
  )
  let apply = i257_only_doing(repo, child.instance_id, "apply")
  assert_eq(apply.task_state, 10)
  assert_eq(repo.find_done_tasks(child.instance_id, ["apply"]).length(), 0)
}

// ── 子结束闸、协办与拒绝 ──────────────────────────────────────────────────

///|
fn i257_fork_child_flow() -> String {
  let result =
    $|{"name":"childFork257","displayName":"childFork257","type":"approval",
    $| "nodes":[
    $|  {"id":"start","type":"snaker:start","properties":{}},
    $|  {"id":"apply","type":"snaker:task","properties":{"assignee":"applicant"}},
    $|  {"id":"fork","type":"snaker:fork","properties":{}},
    $|  {"id":"reviewA","type":"snaker:task","properties":{"assignee":"leaderA"}},
    $|  {"id":"reviewB","type":"snaker:task","properties":{"assignee":"leaderB"}},
    $|  {"id":"end","type":"snaker:end","properties":{}}
    $| ],"edges":[
    $|  {"id":"e1","sourceNodeId":"start","targetNodeId":"apply"},
    $|  {"id":"e2","sourceNodeId":"apply","targetNodeId":"fork"},
    $|  {"id":"e3","sourceNodeId":"fork","targetNodeId":"reviewA"},
    $|  {"id":"e4","sourceNodeId":"fork","targetNodeId":"reviewB"},
    $|  {"id":"e5","sourceNodeId":"reviewA","targetNodeId":"end"},
    $|  {"id":"e6","sourceNodeId":"reviewB","targetNodeId":"end"}
    $| ]}
  result
}

///|
async test "i257 endGate: 未完成主办任务拒绝结束，协办自动完成且不驱动出边" {
  let (engine, repo, events) = i257_make_engine()
  let _child_define = i257_add_define(repo, 0L, "childFork257", 1, 1, i257_fork_child_flow())
  let parent_define = i257_add_define(
    repo, 0L, "parentFork257", 1, 1,
    i257_parent_flow("parentFork257", "childFork257", "\"processName\":\"childFork257\",\"version\":1"),
  )
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", i257_new_args())
  let child = i257_only_child(repo, parent.instance_id)
  let review_a = i257_only_doing(repo, child.instance_id, "reviewA")
  let review_b = i257_only_doing(repo, child.instance_id, "reviewB")
  let mut caught : @error.JeeflowError? = None
  try {
    let finish = i257_new_args()
    finish.insert_i64("submitType", 1L)
    let _ = engine.execute_task_async(review_a.task_id, "leaderA", finish)
  } catch {
    error => caught = Some(error)
  }
  assert_eq(caught.unwrap().message(), "存在未完成的主办任务,请确认.")
  assert_eq(repo.find_instance_by_id(child.instance_id).unwrap().state, 10)
  assert_eq(repo.find_task_by_id(review_b.task_id).unwrap().task_state, 10)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 0)

  let finish_b = i257_new_args()
  finish_b.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(review_b.task_id, "leaderB", finish_b)
  assert_eq(repo.find_instance_by_id(child.instance_id).unwrap().state, 20)
  let _ = i257_only_doing(repo, parent.instance_id, "parentAfter")
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
}

///|
async test "i257 aidant: 子结束自动办结协办，父子续跑仍各一次" {
  let (engine, repo, events) = i257_make_engine()
  let _child_define = i257_add_define(repo, 0L, "childAidant257", 1, 1, i257_child_flow("childAidant257", "review"))
  let parent_define = i257_add_define(
    repo, 0L, "parentAidant257", 1, 1,
    i257_parent_flow("parentAidant257", "childAidant257", "\"processName\":\"childAidant257\",\"version\":1"),
  )
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", i257_new_args())
  let child = i257_only_child(repo, parent.instance_id)
  let review = i257_only_doing(repo, child.instance_id, "review")
  let aidants = engine.aidant_task_async(review.task_id, ["helper"], None, false, "leader")
  assert_eq(aidants.length(), 1)
  let finish = i257_new_args()
  finish.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(review.task_id, "leader", finish)
  let aidant_done = repo.find_task_by_id(aidants[0].task_id).unwrap()
  assert_eq(aidant_done.task_state, 20)
  assert_eq(aidant_done.actor_id, Some("flow.auto"))
  assert_eq(repo.find_instance_by_id(child.instance_id).unwrap().state, 20)
  let _ = i257_only_doing(repo, parent.instance_id, "parentAfter")
  assert_eq(i257_count_event(events, "PROCESS_TASK_START", child.instance_id), 3)
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
}

///|
async test "i257 reject: 子拒绝终态落库播报后同样回父推进一次" {
  let (engine, repo, events) = i257_make_engine()
  let _child_define = i257_add_define(repo, 0L, "childReject257", 1, 1, i257_child_flow("childReject257", "review"))
  let parent_define = i257_add_define(
    repo, 0L, "parentReject257", 1, 1,
    i257_parent_flow("parentReject257", "childReject257", "\"processName\":\"childReject257\",\"version\":1"),
  )
  let parent = engine.start_and_execute_async(parent_define.id, "applicant", i257_new_args())
  let child = i257_only_child(repo, parent.instance_id)
  let review = i257_only_doing(repo, child.instance_id, "review")
  let reject = i257_new_args()
  reject.insert_i64("submitType", 2L)
  let _ = engine.execute_and_jump_to_end_async(review.task_id, "leader", reject)
  assert_eq(repo.find_instance_by_id(child.instance_id).unwrap().state, 45)
  assert_eq(repo.find_instance_by_id(parent.instance_id).unwrap().state, 10)
  let _ = i257_only_doing(repo, parent.instance_id, "parentAfter")
  assert_eq(i257_count_event(events, "PROCESS_INSTANCE_END", child.instance_id), 1)
  assert_eq(i257_count_event(events, "PROCESS_TASK_START", parent.instance_id), 2)
}
