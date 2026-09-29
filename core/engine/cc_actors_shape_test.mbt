// issues/141 G6 —— 抄送人两形态解析（办理路径 tf_ccActors）。
// 基准＝java JeeflowEngineImpl.handleCcActors：String 按逗号切 / Collection 逐元素转串，
// 两形态结果等价（建几行 cc 就 fire 几个码 4，逐人一一对应）。
// 复用同包 compliance_test.mbt 的 helper（simple_flow_json / save_flow_define / new_args）。

///|
/// 码 4（CC_CREATE）事件里看到的抄送人序；spec §11.3 码 4：sourceId=instanceId，ccActorId 直传事件体。
fn cc_fired_actors(events : Array[@event.ProcessEvent]) -> Array[String] {
  let out : Array[String] = []
  for e in events {
    if e.event_type() is @event.CcCreate {
      out.push(match e.cc_actor_id() {
        Some(a) => a
        None => ""
      })
    }
  }
  out
}

///|
/// cc 行数（PageQuery 不设 operator ⇒ memory 侧 operator_eq 恒真 ⇒ 全量 cc 行；
/// 与 compliance_test.mbt 的 record_count 计数口径一致）
async fn cc_rows_of(repo : @mem.MemoryRepository) -> Int64 raise {
  (repo.page_cc_instances(@model.PageQuery::new(1L, 100L))).record_count()
}

///|
async test "i141-G6: 办理 tf_ccActors 数组形态建 cc 行并逐人 fire 码 4" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let did = save_flow_define(repo, "g6-task-array", simple_flow_json())
  // 发起不带 f_ccActors ⇒ 之后出现的码 4 只可能来自办理路径（与 events_leg_test 同法）
  let instance = engine.start_async(did, "user1", new_args())
  assert_eq(cc_fired_actors(events).length(), 0)
  let tasks = repo.find_doing_tasks(instance.instance_id, [])
  assert_eq(tasks.length(), 1)
  let args = new_args()
  args.insert("tf_ccActors", @json.array_of([@json.string_of("userB"), @json.string_of("userC")]))
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", args)
  // 改前此格红：办理路径只走 get_str，数组取不到值 ⇒ 0 行 0 事件
  assert_eq(cc_rows_of(repo), 2L)
  let fired = cc_fired_actors(events)
  assert_eq(fired.length(), 2)
  assert_true(fired == ["userB", "userC"])
}

///|
async test "i141-G6: 办理路径 逗号串与数组两形态等价（cc 行数 == 码 4 事件数 == 同人同序）" {
  // A 组：逗号串（改前唯一能用的形态）
  let repo_a = @mem.MemoryRepository::new()
  let ctx_a = @spi.Ctx::new(repo_a, repo_a)
  let gen_a = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_a2 = ctx_a.with_id_generator(fn() { gen_a.next_id() })
  let events_a : Array[@event.ProcessEvent] = []
  ctx_a2.register_event_listener(fn(ev) { events_a.push(ev) })
  let engine_a = @engine.Engine::make(ctx_a2)
  let did_a = save_flow_define(repo_a, "g6-equiv-a", simple_flow_json())
  let inst_a = engine_a.start_async(did_a, "user1", new_args())
  let tasks_a = repo_a.find_doing_tasks(inst_a.instance_id, [])
  let args_a = new_args()
  args_a.insert_str("tf_ccActors", "userB,userC")
  let _ = engine_a.execute_task_async(tasks_a[0].task_id, "user1", args_a)
  // B 组：数组（同一批人，同一份定义）
  let repo_b = @mem.MemoryRepository::new()
  let ctx_b = @spi.Ctx::new(repo_b, repo_b)
  let gen_b = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_b2 = ctx_b.with_id_generator(fn() { gen_b.next_id() })
  let events_b : Array[@event.ProcessEvent] = []
  ctx_b2.register_event_listener(fn(ev) { events_b.push(ev) })
  let engine_b = @engine.Engine::make(ctx_b2)
  let did_b = save_flow_define(repo_b, "g6-equiv-b", simple_flow_json())
  let inst_b = engine_b.start_async(did_b, "user1", new_args())
  let tasks_b = repo_b.find_doing_tasks(inst_b.instance_id, [])
  let args_b = new_args()
  args_b.insert("tf_ccActors", @json.array_of([@json.string_of("userB"), @json.string_of("userC")]))
  let _ = engine_b.execute_task_async(tasks_b[0].task_id, "user1", args_b)
  // 两形态等价三要件：落库行数相同、码 4 事件数相同、事件里的人同人同序
  let rows_a = cc_rows_of(repo_a)
  let rows_b = cc_rows_of(repo_b)
  let fired_a = cc_fired_actors(events_a)
  let fired_b = cc_fired_actors(events_b)
  assert_eq(rows_a, 2L)
  assert_eq(rows_a, rows_b)
  assert_eq(fired_a.length(), fired_b.length())
  assert_eq(rows_a.to_int(), fired_a.length())
  assert_true(fired_a == ["userB", "userC"])
  assert_true(fired_b == ["userB", "userC"])
}

///|
async test "i141-G6: 办理路径 单元素两形态等价（userB vs [userB]）" {
  let repo_a = @mem.MemoryRepository::new()
  let ctx_a = @spi.Ctx::new(repo_a, repo_a)
  let gen_a = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_a2 = ctx_a.with_id_generator(fn() { gen_a.next_id() })
  let events_a : Array[@event.ProcessEvent] = []
  ctx_a2.register_event_listener(fn(ev) { events_a.push(ev) })
  let engine_a = @engine.Engine::make(ctx_a2)
  let did_a = save_flow_define(repo_a, "g6-one-a", simple_flow_json())
  let inst_a = engine_a.start_async(did_a, "user1", new_args())
  let tasks_a = repo_a.find_doing_tasks(inst_a.instance_id, [])
  let args_a = new_args()
  args_a.insert_str("tf_ccActors", "userB")
  let _ = engine_a.execute_task_async(tasks_a[0].task_id, "user1", args_a)
  let repo_b = @mem.MemoryRepository::new()
  let ctx_b = @spi.Ctx::new(repo_b, repo_b)
  let gen_b = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_b2 = ctx_b.with_id_generator(fn() { gen_b.next_id() })
  let events_b : Array[@event.ProcessEvent] = []
  ctx_b2.register_event_listener(fn(ev) { events_b.push(ev) })
  let engine_b = @engine.Engine::make(ctx_b2)
  let did_b = save_flow_define(repo_b, "g6-one-b", simple_flow_json())
  let inst_b = engine_b.start_async(did_b, "user1", new_args())
  let tasks_b = repo_b.find_doing_tasks(inst_b.instance_id, [])
  let args_b = new_args()
  args_b.insert("tf_ccActors", @json.array_of([@json.string_of("userB")]))
  let _ = engine_b.execute_task_async(tasks_b[0].task_id, "user1", args_b)
  // 单元素边界：两形态都必须恰好一行一人（改前 B 组 0 行 ⇒ 此格红）
  assert_eq(cc_rows_of(repo_a), 1L)
  assert_eq(cc_rows_of(repo_b), 1L)
  assert_true(cc_fired_actors(events_a) == ["userB"])
  assert_true(cc_fired_actors(events_b) == ["userB"])
}

///|
async test "i141-G6: 办理路径 空串与空数组两形态互相等价（不擅断 java 的空段口径，待 issues/141 拍）" {
  // ⚠️ 本格**只**钉"两形态在 moon 内部一致"，不钉"空 ⇒ 建不建行"：
  // java handleCcActors 对 "" 会 split 出一个空元素并建一行 ""（Collection 侧 [""] 同理），
  // 本仓 parse_cc_actors 走的是"空段丢弃"（既有 c30 格已按此钉住 f_ccActors 一侧）。
  // 办理路径统一到同一个解析器后继承该口径 ⇒ 与 java 在 ""/[""] 这一格上仍有偏差，
  // 是否改判"空也建一行"由 owner 在 issues/141 拍，此处不替 owner 立规。
  let repo_a = @mem.MemoryRepository::new()
  let ctx_a = @spi.Ctx::new(repo_a, repo_a)
  let gen_a = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_a2 = ctx_a.with_id_generator(fn() { gen_a.next_id() })
  let events_a : Array[@event.ProcessEvent] = []
  ctx_a2.register_event_listener(fn(ev) { events_a.push(ev) })
  let engine_a = @engine.Engine::make(ctx_a2)
  let did_a = save_flow_define(repo_a, "g6-empty-a", simple_flow_json())
  let inst_a = engine_a.start_async(did_a, "user1", new_args())
  let tasks_a = repo_a.find_doing_tasks(inst_a.instance_id, [])
  let args_a = new_args()
  args_a.insert_str("tf_ccActors", "")
  let _ = engine_a.execute_task_async(tasks_a[0].task_id, "user1", args_a)
  let repo_b = @mem.MemoryRepository::new()
  let ctx_b = @spi.Ctx::new(repo_b, repo_b)
  let gen_b = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_b2 = ctx_b.with_id_generator(fn() { gen_b.next_id() })
  let events_b : Array[@event.ProcessEvent] = []
  ctx_b2.register_event_listener(fn(ev) { events_b.push(ev) })
  let engine_b = @engine.Engine::make(ctx_b2)
  let did_b = save_flow_define(repo_b, "g6-empty-b", simple_flow_json())
  let inst_b = engine_b.start_async(did_b, "user1", new_args())
  let tasks_b = repo_b.find_doing_tasks(inst_b.instance_id, [])
  let args_b = new_args()
  args_b.insert("tf_ccActors", @json.array_of([@json.string_of("")]))
  let _ = engine_b.execute_task_async(tasks_b[0].task_id, "user1", args_b)
  assert_eq(cc_rows_of(repo_a), cc_rows_of(repo_b))
  assert_eq(cc_fired_actors(events_a).length(), cc_fired_actors(events_b).length())
}

///|
async test "i141-G6: 发起路径 f_ccActors 两形态等价（回归钉，与办理路径共用解析器）" {
  // A 组：逗号串
  let repo_a = @mem.MemoryRepository::new()
  let ctx_a = @spi.Ctx::new(repo_a, repo_a)
  let gen_a = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_a2 = ctx_a.with_id_generator(fn() { gen_a.next_id() })
  let events_a : Array[@event.ProcessEvent] = []
  ctx_a2.register_event_listener(fn(ev) { events_a.push(ev) })
  let engine_a = @engine.Engine::make(ctx_a2)
  let did_a = save_flow_define(repo_a, "g6-start-a", simple_flow_json())
  let args_a = new_args()
  args_a.insert_str("f_ccActors", "userD,userE")
  let inst_a = engine_a.start_async(did_a, "user1", args_a)
  // B 组：数组
  let repo_b = @mem.MemoryRepository::new()
  let ctx_b = @spi.Ctx::new(repo_b, repo_b)
  let gen_b = @id_gen.AtomicIdGenerator::new(1L)
  let ctx_b2 = ctx_b.with_id_generator(fn() { gen_b.next_id() })
  let events_b : Array[@event.ProcessEvent] = []
  ctx_b2.register_event_listener(fn(ev) { events_b.push(ev) })
  let engine_b = @engine.Engine::make(ctx_b2)
  let did_b = save_flow_define(repo_b, "g6-start-b", simple_flow_json())
  let args_b = new_args()
  args_b.insert("f_ccActors", @json.array_of([@json.string_of("userD"), @json.string_of("userE")]))
  let inst_b = engine_b.start_async(did_b, "user1", args_b)
  assert_eq(cc_rows_of(repo_a), 2L)
  assert_eq(cc_rows_of(repo_a), cc_rows_of(repo_b))
  assert_true(cc_fired_actors(events_a) == ["userD", "userE"])
  assert_true(cc_fired_actors(events_b) == ["userD", "userE"])
  // 码 4 的 sourceId 必须是实例 id（spec §11.3），两形态同判据
  for pair in [(inst_a.instance_id, events_a), (inst_b.instance_id, events_b)] {
    let (iid, evs) = pair
    for e in evs {
      if e.event_type() is @event.CcCreate {
        assert_eq(e.source_id(), iid)
      }
    }
  }
}
