// 引擎合规测试 —— 移植自 rust engine.rs tests（c01–c31 + 事件时机 + submitType 矩阵）
// 黑盒 async test：for "test" 引 moonbitlang/async（D-M0-1）。
// flows 读取（async fs）：候选目录探测 flows/<name>.json（fs 只进测试代码，core 主代码零依赖不破）。

///|
fn make_test_engine() -> (@engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  (@engine.Engine::make(ctx2), repo)
}

///|
fn simple_flow_json() -> String {
  $|  {"name": "test-flow", "displayName": "Test Flow", "type": "approval",
$|   "nodes": [
$|     {"id": "start", "type": "snaker:start", "text": {"value": "Start"}},
$|     {"id": "apply", "type": "snaker:task", "text": {"value": "Apply"},
$|      "properties": {"assignee": "applicant"}},
$|     {"id": "end", "type": "snaker:end", "text": {"value": "End"}}
$|   ],
$|   "edges": [
$|     {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
$|     {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "end"}
$|   ]}
$|  
}

///|
async fn save_flow_define(repo : @mem.MemoryRepository, name : String, content : String) -> Int64 raise {
  let define : @model.ProcessDefine = {
    id: 0L,
    name,
    display_name: name,
    define_type: "approval",
    state: 1,
    content,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define)
  define.id
}

///|
async fn make_define(repo : @mem.MemoryRepository) -> Int64 raise {
  save_flow_define(repo, "test-flow", simple_flow_json())
}

///|
/// 用户信息 provider（合规测试同款：realName=userId）
fn compliance_user_provider(uid : String) -> @model.UserInfo? raise @error.JeeflowError {
  Some(@model.UserInfo::make(user_id=uid, real_name=uid, dept_id="dept1", dept_name="TestDept", post_id="post1", post_name="TestPost"))
}

///|
fn make_compliance_engine() -> (@engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider(compliance_user_provider)
  (@engine.Engine::make(ctx2), repo)
}

///|
async fn load_flow(name : String) -> String raise {
  for dir in ["../../flows", "../flows", "flows", "../../../../flows", "../../../flows"] {
    let path = "\{dir}/\{name}.json"
    if @fs.can_read(path) {
      let data = @fs.read_file(path)
      return data.text()
    }
  }
  abort("flows dir not found for \{name}")
}

///|
/// 发起并自动完成申请节点（operator=applicant）
async fn start_and_apply(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  define_id : Int64
) -> Int64 raise {
  let inst = engine.start_async(define_id, "applicant", @json.FlowData::new())
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  for t in tasks {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", @json.FlowData::new())
      break
    }
  }
  inst.instance_id
}

///|
async fn find_doing_for(
  repo : @mem.MemoryRepository,
  iid : Int64,
  actor : String
) -> @model.ProcessTask raise {
  let tasks = repo.find_doing_tasks(iid, [])
  for t in tasks {
    if t.actor_ids.contains(actor) {
      return t
    }
  }
  abort("no doing task for \{actor} in \{iid}")
}

///|
fn new_args() -> @json.FlowData {
  @json.FlowData::new()
}

// ── 基础引擎行为 ──

///|
async test "engine: start_async creates instance" {
  let (engine, repo) = make_test_engine()
  let define_id = make_define(repo)
  let instance = engine.start_async(define_id, "user1", new_args())
  assert_eq(instance.operator, "user1")
  assert_true(instance.instance_id > 0L)
}

///|
async test "engine: start_async define not found" {
  let (engine, _repo) = make_test_engine()
  let outcome = try? engine.start_async(99999L, "user1", new_args())
  assert_true(outcome is Err(_))
}

///|
async test "engine: execute task not found" {
  let (engine, _repo) = make_test_engine()
  let outcome = try? engine.execute_task_async(99999L, "user1", new_args())
  assert_true(outcome is Err(_))
}

///|
async test "engine: execute task permission denied" {
  let (engine, repo) = make_test_engine()
  let define_id = make_define(repo)
  let instance = engine.start_async(define_id, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  assert_true(!tasks.is_empty())
  let outcome = try? engine.execute_task_async(tasks[0].task_id, "user999", new_args())
  assert_true(outcome is Err(_))
}

///|
async test "engine: execution context new" {
  let define : @model.ProcessDefine = {
    id: 1L,
    name: "test",
    display_name: "Test",
    define_type: "approval",
    state: 1,
    content: simple_flow_json(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let model = @parser.parse_model(define.content)
  let instance = @model.ProcessInstance::create(define, "user1", new_args())
  let exec = @exec.Execution::make(instance, model, define, "user1", new_args())
  assert_eq(exec.operator, "user1")
  assert_true(!exec.instance_finished)
  assert_true(exec.new_tasks.is_empty())
}

///|
async test "engine: no ext repository design path errors" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  let engine = @engine.Engine::make(ctx)
  let outcome = try? engine.context().ext_repository().find_design_by_id(1L)
  match outcome {
    Ok(r) => assert_true(r is None)
    Err(_) => assert_true(false)
  }
}

// ── 事件时机（issues/13 / 102·104）──

///|
async test "events: TASK_START fires after persist with real id" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let fired : Array[Int64] = []
  ctx2.register_event_listener(fn(ev) {
    if ev.event_type() is @event.ProcessTaskStart {
      fired.push(ev.source_id())
    }
  })
  let engine = @engine.Engine::make(ctx2)
  let define_id = make_define(repo)
  let instance = engine.start_async(define_id, "user1", new_args())
  assert_true(instance.instance_id > 0L)
  assert_eq(fired.length(), 1)
  let task_id = fired[0]
  assert_true(task_id > 0L)
  let t = repo.find_task_by_id(task_id)
  assert_true(t is Some(_))
}

///|
async test "events: CC_CREATE fired per actor with cc rows" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let fired : Array[(Int64, String?)] = []
  ctx2.register_event_listener(fn(ev) {
    if ev.event_type() is @event.CcCreate {
      fired.push((ev.source_id(), ev.cc_actor_id()))
    }
  })
  let engine = @engine.Engine::make(ctx2)
  let define_id = make_define(repo)
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("u1"), @json.string_of("u2")]))
  let instance = engine.start_async(define_id, "user1", args)
  assert_eq(fired.length(), 2)
  for pair in fired {
    let (sid, _) = pair
    assert_eq(sid, instance.instance_id)
  }
  assert_eq(fired[0].1.unwrap(), "u1")
  assert_eq(fired[1].1.unwrap(), "u2")
  let q = @model.PageQuery::new(1L, 10L)
  let page = repo.page_cc_instances(q)
  assert_eq(page.record_count(), 2L)
}

///|
async test "events: CC_CREATE zero side effect without listener" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let engine = @engine.Engine::make(ctx2)
  let define_id = make_define(repo)
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("u9")]))
  let instance = engine.start_async(define_id, "user1", args)
  let q = @model.PageQuery::new(1L, 10L)
  let page = repo.page_cc_instances(q)
  assert_eq(page.record_count(), 1L)
  assert_true(instance.instance_id > 0L)
}

///|
async test "events: reject path fires INSTANCE_END (issues/104)" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let fired : Array[Int64] = []
  ctx2.register_event_listener(fn(ev) {
    if ev.event_type() is @event.ProcessInstanceEnd {
      fired.push(ev.source_id())
    }
  })
  let engine = @engine.Engine::make(ctx2)
  let define_id = make_define(repo)
  let instance = engine.start_async(define_id, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  assert_true(!tasks.is_empty())
  let _ = engine.execute_and_jump_to_end_async(tasks[0].task_id, "flow.auto", new_args())
  let inst = repo.find_instance_by_id(instance.instance_id).unwrap()
  assert_eq(inst.state, 45)
  assert_eq(fired.length(), 1)
  assert_eq(fired[0], instance.instance_id)
}

///|
test "events: publisher per-listener isolation" {
  let fired : Array[Int64] = []
  let listeners : Array[((@event.ProcessEvent) -> Unit raise)] = [
    fn(_ev) raise { raise @error.Business("boom") },
    fn(ev) { if ev.event_type() is @event.ProcessInstanceStart { fired.push(ev.source_id()) } },
  ]
  @event.notify(@event.ProcessEvent::make(@event.ProcessInstanceStart, 42L), listeners)
  assert_eq(fired.length(), 1)
  assert_eq(fired[0], 42L)
}

// ── 合规场景 c01–c18 / c19–c22（15 flows 驱动）──

///|
async test "c01: execute returns non-zero task ids (#91)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-nonzero", load_flow("01-simple"))
  let inst = engine.start_async(did, "applicant", new_args())
  let apply_task = find_doing_for(repo, inst.instance_id, "applicant")
  let new_tasks = engine.execute_task_async(apply_task.task_id, "applicant", new_args())
  assert_true(!new_tasks.is_empty())
  for t in new_tasks {
    assert_true(t.task_id > 0L)
  }
  let repo_tasks = repo.find_doing_tasks(inst.instance_id, [])
  for nt in new_tasks {
    let mut ok = false
    for rt in repo_tasks {
      if rt.task_id == nt.task_id {
        ok = true
      }
    }
    assert_true(ok)
  }
}

///|
async test "c01: simple linear flow completes" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(!tasks.is_empty())
  assert_eq(tasks[0].actor_ids[0], "leader")
  let _ = engine.execute_task_async(tasks[0].task_id, "leader", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
}

///|
async test "c02: multi task chain" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "multi-task", load_flow("02-multi-task"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks[0].actor_ids[0], "leader")
  let _ = engine.execute_task_async(tasks[0].task_id, "leader", new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks[0].actor_ids[0], "manager")
  let _ = engine.execute_task_async(tasks[0].task_id, "manager", new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks[0].actor_ids[0], "boss")
  let _ = engine.execute_task_async(tasks[0].task_id, "boss", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
}

///|
async test "c03: decision branch starts" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "decision-expr", load_flow("03-decision-expr"))
  let inst = engine.start_async(did, "applicant", new_args())
  assert_true(inst.instance_id > 0L)
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  assert_true(!tasks.is_empty())
}

///|
async test "c04: fork join creates parallel tasks" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "fork-join", load_flow("04-fork-join"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(tasks.length() >= 2)
}

///|
async test "c05: parallel countersign creates 3 tasks" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "countersign-parallel", load_flow("05-countersign-parallel"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 3)
}

///|
async test "c06: sequential countersign one at a time (#94)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "countersign-sequential", load_flow("06-countersign-sequential"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].actor_ids[0], "userA")
  let args = new_args()
  args.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(tasks[0].task_id, "userA", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].actor_ids[0], "userB")
  let _ = engine.execute_task_async(tasks[0].task_id, "userB", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 0)
}

///|
async test "c07: ratio countersign creates 4 tasks" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "countersign-ratio", load_flow("07-countersign-ratio"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 4)
}

///|
async test "c08: sequential approve flow runs" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-seq-approve", load_flow("08-countersign-sequential-approve"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(!tasks.is_empty())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
}

///|
async test "c09: non-actor permission denied" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "with-reject", load_flow("09-with-reject"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  if !(tasks.is_empty()) {
    let outcome = try? engine.execute_task_async(tasks[0].task_id, "unauthorized_user", new_args())
    assert_true(outcome is Err(_))
  }
}

///|
async test "c10: mixed mode flow starts" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "mixed-mode", load_flow("10-mixed-mode"))
  let inst = engine.start_async(did, "applicant", new_args())
  assert_true(inst.instance_id > 0L)
}

///|
async test "c11: assignee variable flow starts" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "assignee-vars", load_flow("11-assignee-vars"))
  let inst = engine.start_async(did, "applicant", new_args())
  assert_true(inst.instance_id > 0L)
}

///|
async test "c12: flow.auto can execute any task" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-auto", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(!tasks.is_empty())
  let outcome = try? engine.execute_task_async(tasks[0].task_id, "flow.auto", new_args())
  assert_true(outcome is Ok(_))
}

///|
async test "c13: define write ops" {
  let (_engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "c13-test", "{}")
  assert_true(did > 0L)
  repo.update_define_state(did, 1)
  let d = repo.find_define_by_id(did).unwrap()
  assert_eq(d.state, 1)
  repo.remove_define(did)
  let d = repo.find_define_by_id(did)
  assert_true(d is None)
}

///|
async test "c14: instance update cascade persists" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-cascade", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let inst = repo.find_instance_by_id(iid).unwrap()
  inst.business_no = Some("BIZ-001")
  repo.update_instance(inst)
  let updated = repo.find_instance_by_id(iid).unwrap()
  assert_eq(updated.business_no.unwrap(), "BIZ-001")
}

///|
async test "c15: define findable after save" {
  let (_engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-routing", load_flow("01-simple"))
  let d = repo.find_define_by_id(did)
  assert_true(d is Some(_))
}

///|
async test "c16: history tasks for approval record" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-views", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let history = repo.find_history_tasks(iid)
  assert_true(!history.is_empty())
}

///|
async test "c17: highlight has history" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-highlight", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let history = repo.find_history_tasks(iid)
  assert_true(!history.is_empty())
}

///|
async test "c18: candidate page flow starts" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "candidate-page", load_flow("12-candidate-page"))
  let inst = engine.start_async(did, "applicant", new_args())
  assert_true(inst.instance_id > 0L)
}

///|
async test "c19: cc paging" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-cc", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  repo.create_cc_instance(iid, "user1", ["cc_user1", "cc_user2"])
  let page = repo.page_cc_instances(@model.PageQuery::new(1L, 10L))
  assert_true(page.record_count() > 0L)
}

///|
async test "c20: add task actor dedups" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "simple-actor", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(!tasks.is_empty())
  repo.add_task_actor(tasks[0].task_id, ["extra_actor"])
  repo.add_task_actor(tasks[0].task_id, ["extra_actor"])
  let actors = repo.find_task_actors(tasks[0].task_id)
  let mut count = 0
  for a in actors {
    if a == "extra_actor" {
      count = count + 1
    }
  }
  assert_eq(count, 1)
}

///|
test "c21: enum dict 7 keys" {
  let registry = @metadata.EnumDictRegistry::new()
  let keys = [
    "wf_process_define_state",
    "wf_process_instance_state",
    "wf_process_submit_type",
    "wf_process_task_state",
    "wf_process_task_type",
    "wf_process_task_perform_type",
    "wf_countersign_type",
  ]
  for key in keys {
    let dict = registry.get_dict(key)
    assert_true(dict is Some(_))
    assert_true(!(dict.unwrap().is_empty()))
  }
}

///|
test "c22: handler registry built-ins + custom" {
  let registry = @metadata.HandlerRegistry::new()
  let built_in_count = registry.all_handlers().length()
  registry.register(
    @metadata.HandlerMeta::make("assignment", "handler1", "Handler 1", 1, "test"),
  )
  registry.register(
    @metadata.HandlerMeta::make("assignment", "handler2", "Handler 2", 2, "test"),
  )
  let by_type = registry.list_handlers("assignment")
  assert_true(by_type.length() >= 2)
  assert_eq(registry.all_handlers().length(), built_in_count + 2)
}
