// issues/127·132「事件代码腿」recorder 测试 —— 断言一条流从发起到办结**按顺序**收到的规范名序列。
// 权威：jeeflow-doc/docs/spec/11-events.md §11.3（规范名）＋ §11.8 L2-30（[1,3,5,2] ＋ 抄送支 [4]）。
// 本栈实际命名＝ProcessEventType 构造子；name() 透出 spec SCREAMING 规范名，逐字对齐 §11.3。
// 复用同包 compliance_test.mbt 的 helper（simple_flow_json / save_flow_define / new_args）。

///|
async test "i132-events: 发起→同意→办结 可见序 [1,3,5,2]（spec §11.8 L2-30）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "leg-happy", simple_flow_json()) // start→apply(applicant)→end
  let instance = engine.start_async(did, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  assert_eq(tasks.length(), 1)
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", new_args())
  // 规范名序列逐字对齐 spec §11.3（本栈构造子→name()）
  assert_eq(
    events.map(fn(e) { e.event_type().name() }),
    ["PROCESS_INSTANCE_START", "PROCESS_TASK_START", "TASK_COMPLETE", "PROCESS_INSTANCE_END"],
  )
  // 码值序列 [1,3,5,2]
  assert_eq(events.map(fn(e) { e.event_type().code() }), [1, 3, 5, 2])
  // TASK_COMPLETE sourceId=taskId，与同一条 TASK_START 的 taskId 一致；载荷 instanceId/taskId/operator（§11.3 code 5）
  let complete = events[2]
  assert_eq(complete.source_id(), events[1].source_id())
  assert_eq(complete.data.get_i64("instanceId"), Some(instance.instance_id))
  assert_eq(complete.data.get_i64("taskId"), Some(tasks[0].task_id))
  assert_eq(complete.data.get_str("operator"), Some("user1"))
}

///|
async test "i132-events: 拒绝到结束 fire TASK_REJECT(6) 且与 TASK_COMPLETE 互斥（spec §11.3 code 6）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "leg-rej", simple_flow_json())
  let instance = engine.start_async(did, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  let args = new_args()
  args.insert_i64("submitType", 2L) // 拒绝 → jump to end（facade execute submitType=2 同档）
  let _ = engine.execute_and_jump_to_end_async(tasks[0].task_id, "flow.auto", args)
  assert_eq(
    events.map(fn(e) { e.event_type().name() }),
    ["PROCESS_INSTANCE_START", "PROCESS_TASK_START", "TASK_REJECT", "PROCESS_INSTANCE_END"],
  )
  assert_eq(events.map(fn(e) { e.event_type().code() }), [1, 3, 6, 2])
  // 走 reject 不再 fire complete：全程无 TASK_COMPLETE
  assert_eq(events.filter(fn(e) { e.event_type().name() == "TASK_COMPLETE" }).length(), 0)
  assert_eq(events[2].data.get_i64("submitType"), Some(2L))
}

///|
async test "i132-events: 会签软拒绝(submitType=20) fire TASK_REJECT 非 COMPLETE（§11.3 code 6「软拒绝」）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "leg-soft-rej", simple_flow_json())
  let instance = engine.start_async(did, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", args)
  assert_true(events.filter(fn(e) { e.event_type().name() == "TASK_REJECT" }).length() >= 1)
  assert_eq(events.filter(fn(e) { e.event_type().name() == "TASK_COMPLETE" }).length(), 0)
}

///|
test "i132-events: notify 向全部监听器广播 + 逐监听器异常隔离（spec §11.5 订阅形状/异常隔离）" {
  let a : Array[String] = []
  let b : Array[String] = []
  let listeners : Array[((@event.ProcessEvent) -> Unit raise)] = [
    fn(ev) { a.push(ev.event_type().name()) },
    fn(_ev) raise { raise @error.Business("boom") }, // 中间监听器抛异常
    fn(ev) { b.push(ev.event_type().name()) }, // 后续监听器仍须收到（不回滚主流程、不中断）
  ]
  @event.notify(@event.ProcessEvent::make(@event.TaskTransfer, 7L), listeners)
  // 列表广播：两个正常监听器都拿到（后注册不覆盖前注册）
  assert_eq(a, ["TASK_TRANSFER"])
  assert_eq(b, ["TASK_TRANSFER"])
}

///|
/// 第二轮补的尾巴：既有三支码（1/2/3）的 §11.3 直传载荷键。
/// 集成层 L2-30 的事件流水 sink 靠**载荷里的 instanceId** 把一条流的流水归到
/// `jeeflow:gate:events:<instanceId>` 一个键下——码 3 的 sourceId 是 taskId，
/// 载荷缺 instanceId 就会拆成多键、顺序读不全（rust 栈同一个病）。
async test "i132-events: 码 1/2/3 直传载荷键齐备且值对（spec §11.3）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "key-1234", simple_flow_json()) // start→apply(applicant)→end
  let instance = engine.start_async(did, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  assert_eq(tasks.length(), 1)
  // ── 码 1 PROCESS_INSTANCE_START：sourceId=instanceId ＋ 载荷 instanceId ──
  let start = events[0]
  assert_eq(start.event_type().name(), "PROCESS_INSTANCE_START")
  assert_eq(start.source_id(), instance.instance_id)
  assert_true(start.data.contains_key("instanceId"))
  assert_eq(start.data.get_i64("instanceId"), Some(instance.instance_id))
  // ── 码 3 PROCESS_TASK_START：sourceId=taskId ＋ 载荷 instanceId/taskId/actors ──
  let ts = events[1]
  assert_eq(ts.event_type().name(), "PROCESS_TASK_START")
  assert_eq(ts.source_id(), tasks[0].task_id)
  assert_true(ts.data.contains_key("instanceId"))
  assert_eq(ts.data.get_i64("instanceId"), Some(instance.instance_id))
  assert_true(ts.data.contains_key("taskId"))
  assert_eq(ts.data.get_i64("taskId"), Some(tasks[0].task_id))
  assert_true(ts.data.contains_key("actors"))
  assert_eq(ts.data.get_string_array("actors"), ["user1"])
  // ── 码 2 PROCESS_INSTANCE_END：载荷 instanceId ＋ state（办结支＝20）──
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", new_args())
  let end = events[events.length() - 1]
  assert_eq(end.event_type().name(), "PROCESS_INSTANCE_END")
  assert_eq(end.source_id(), instance.instance_id)
  assert_true(end.data.contains_key("instanceId"))
  assert_eq(end.data.get_i64("instanceId"), Some(instance.instance_id))
  assert_true(end.data.contains_key("state"))
  assert_eq(end.data.get_i64("state"), Some(20L))
  // state 与**落库后的实例行**一致（§11.3「state＝落库后的实例状态整数」）
  let inst = repo.find_instance_by_id(instance.instance_id).unwrap()
  assert_eq(end.data.get_i64("state"), Some(inst.state.to_int64()))
}

///|
/// 码 2 的第二条触发路径（驳回 jump-to-end）：载荷 state＝45，同样取落库后的实例行值。
async test "i132-events: 码 2 驳回支载荷 instanceId + state=45（spec §11.3 code 2 两路同键）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "key-2-rej", simple_flow_json())
  let instance = engine.start_async(did, "user1", new_args())
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  let args = new_args()
  args.insert_i64("submitType", 2L)
  let _ = engine.execute_and_jump_to_end_async(tasks[0].task_id, "flow.auto", args)
  let end = events[events.length() - 1]
  assert_eq(end.event_type().name(), "PROCESS_INSTANCE_END")
  assert_true(end.data.contains_key("instanceId"))
  assert_eq(end.data.get_i64("instanceId"), Some(instance.instance_id))
  assert_true(end.data.contains_key("state"))
  assert_eq(end.data.get_i64("state"), Some(45L))
  let inst = repo.find_instance_by_id(instance.instance_id).unwrap()
  assert_eq(inst.state, 45)
  assert_eq(end.data.get_i64("state"), Some(inst.state.to_int64()))
}

///|
/// 码 1 的第二条触发路径（带父实例发起，engine_ops 的 start_with_parent_async）：
/// 该函数本栈零调用者、零测试覆盖，载荷键必须自己钉一枚，否则改了没人知道。
async test "i132-events: 码 1 子流程发起支同样带 instanceId（§11.3 code 1 两路同键）" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "key-1-parent", simple_flow_json())
  let child = engine.start_with_parent_async(did, "user1", new_args(), 777L, "sub")
  assert_eq(child.parent_id, Some(777L))
  let start = events[0]
  assert_eq(start.event_type().name(), "PROCESS_INSTANCE_START")
  assert_eq(start.source_id(), child.instance_id)
  assert_true(start.data.contains_key("instanceId"))
  assert_eq(start.data.get_i64("instanceId"), Some(child.instance_id))
}
