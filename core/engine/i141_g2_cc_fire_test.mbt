// issues/141 G2 · 抄送写侧判重 ⇒ **事件面（CC_CREATE／码 4）**—— 引擎腿行为档。
//
// spec §11.2 原则 1「码值表达发生了什么事实」⇒ 重复抄送没发生"创建"就不得 fire 码 4；
// 基准＝java 参考实现（3d1fc98）：三条入口一律拿 `create_cc_instance_if_absent` 返回的
// **实际新建子集**去 fire，子集为空 ⇒ 整支不发（不空转、也不照旧按原始请求全量 fire）。
// 本栈三处引擎调用点：发起腿 f_ccActors（start_async）、办理腿 tf_ccActors（execute_task_async）、
// 子流程发起腿（start_with_parent_async）—— 判据同一个，别改解析器 parse_cc_actors 的语义。
//
// 复用同包 helper：simple_flow_json / save_flow_define / new_args（compliance_test.mbt）、
// cc_fired_actors / cc_rows_of（cc_actors_shape_test.mbt）。

///|
fn g2e_setup() -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
  Array[@event.ProcessEvent],
) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener_sync(fn(ev) { events.push(ev) })
  (@engine.Engine::make(ctx2), repo, events)
}

///|
/// 办理腿发起一次抄送（逗号串与数组两形态由 issues/141 G6 钉住，这里只走数组形态）
async fn g2e_task_cc(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  iid : Int64,
  actors : Array[String]
) -> Unit raise {
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  let args = new_args()
  args.insert("tf_ccActors", @json.array_of(actors.map(fn(a) { @json.string_of(a) })))
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", args)
}

///|
/// ① 发起腿首轮正向对照：两个新人 ⇒ 建两行 + fire 两个码 4（同人同序）
/// 这一格改前也必须绿（判重不许误伤首次），是"假修＝一律不发"的照妖镜。
async test "i141-G2 发起腿 首轮正向对照：两新人建两行 fire 两码4" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-first", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("userB"), @json.string_of("userC")]))
  let inst = engine.start_async(did, "user1", args)
  assert_eq(cc_rows_of(repo), 2L)
  assert_true(cc_fired_actors(events) == ["userB", "userC"])
  for e in events {
    if e.event_type() is @event.CcCreate {
      assert_eq(e.source_id(), inst.instance_id)
    }
  }
}

///|
/// ② 不 fire 码 4：第二次抄同一批人（跨腿）⇒ 不新增行、整支不发
async test "i141-G2 重复抄同一人⇒不新增行且不 fire 码4" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-dup", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("userB")]))
  let inst = engine.start_async(did, "user1", args)
  assert_eq(cc_rows_of(repo), 1L)
  assert_true(cc_fired_actors(events) == ["userB"])
  // 办理腿再抄**同一个人** ⇒ 行数不变、码 4 总数不变（改前：多一行 + 多发一个）
  g2e_task_cc(engine, repo, inst.instance_id, ["userB"])
  assert_eq(cc_rows_of(repo), 1L)
  assert_eq(cc_fired_actors(events).length(), 1)
  assert_true(cc_fired_actors(events) == ["userB"])
}

///|
/// ③ 子集 fire：第二次请求里混了老熟人和新人 ⇒ 事件里只出现新人
async test "i141-G2 第二次只抄新人⇒事件里只出现新人（子集 fire）" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-subset", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("userB"), @json.string_of("userC")]))
  let inst = engine.start_async(did, "user1", args)
  assert_true(cc_fired_actors(events) == ["userB", "userC"])
  g2e_task_cc(engine, repo, inst.instance_id, ["userB", "userC", "userD"])
  assert_eq(cc_rows_of(repo), 3L)
  // 改前此格红：第二腿会把 B/C/D 全量再 fire 一遍 ⇒ [B,C,B,C,D]
  assert_true(cc_fired_actors(events) == ["userB", "userC", "userD"])
  // 仓储真相同步：userB/userC 各一行、userD 一行
  assert_eq(repo.find_cc_actors(inst.instance_id).length(), 3)
}

///|
/// ④ 同一次调用内的重复折叠 ⇒ 一行一人一次 fire（不许两行两事件）
async test "i141-G2 同一次调用内重复折叠⇒一行一次fire" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-inner-dup", simple_flow_json())
  let args = new_args()
  args.insert(
    "f_ccActors",
    @json.array_of([@json.string_of("userB"), @json.string_of("userB"), @json.string_of("userC")]),
  )
  let inst = engine.start_async(did, "user1", args)
  assert_eq(cc_rows_of(repo), 2L)
  assert_true(cc_fired_actors(events) == ["userB", "userC"])
  assert_eq(repo.find_cc_actors(inst.instance_id), ["userB", "userC"])
}

///|
/// ⑤ 两腿共用判据：同一批人不论"先发起后办理"还是"先办理后发起"，行数与事件序完全一致
async test "i141-G2 两腿共用判据（入口顺序无关，同一判据同一通道）" {
  // A 组：发起腿带 B、C，办理腿补 D
  let (engine_a, repo_a, events_a) = g2e_setup()
  let did_a = save_flow_define(repo_a, "g2e-legs-a", simple_flow_json())
  let args_a = new_args()
  args_a.insert("f_ccActors", @json.array_of([@json.string_of("userB"), @json.string_of("userC")]))
  let inst_a = engine_a.start_async(did_a, "user1", args_a)
  g2e_task_cc(engine_a, repo_a, inst_a.instance_id, ["userD"])
  // B 组：发起腿只带 B，办理腿带 B（重复）+ C + D
  let (engine_b, repo_b, events_b) = g2e_setup()
  let did_b = save_flow_define(repo_b, "g2e-legs-b", simple_flow_json())
  let args_b = new_args()
  args_b.insert("f_ccActors", @json.array_of([@json.string_of("userB")]))
  let inst_b = engine_b.start_async(did_b, "user1", args_b)
  g2e_task_cc(engine_b, repo_b, inst_b.instance_id, ["userB", "userC", "userD"])
  assert_eq(cc_rows_of(repo_a), 3L)
  assert_eq(cc_rows_of(repo_a), cc_rows_of(repo_b))
  let fired_a = cc_fired_actors(events_a)
  let fired_b = cc_fired_actors(events_b)
  assert_true(fired_a == ["userB", "userC", "userD"])
  assert_true(fired_a == fired_b)
  assert_eq(fired_a.length(), cc_rows_of(repo_a).to_int())
}

///|
/// ⑥ 子流程发起腿（第三处建行点）同一判据：同人重复 ⇒ 不新增行、不 fire
async test "i141-G2 子流程发起腿 同人重复不新增行不fire" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-sub-flow", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("userB")]))
  let first = engine.start_with_parent_async(did, "user1", args, 555L, "sub1")
  assert_eq(cc_rows_of(repo), 1L)
  assert_true(cc_fired_actors(events) == ["userB"])
  // 同一子实例？不是——换实例 ⇒ 判重键含实例，B 在新实例上仍算新人（回归：判重不许跨实例误判）
  let args2 = new_args()
  args2.insert("f_ccActors", @json.array_of([@json.string_of("userB")]))
  let _ = engine.start_with_parent_async(did, "user1", args2, first.instance_id, "sub1")
  assert_eq(cc_rows_of(repo), 2L)
  assert_true(cc_fired_actors(events) == ["userB", "userB"])
  // 第三腿的同一次调用内重复也必须折叠（判据与腿无关）
  let did2 = save_flow_define(repo, "g2e-sub-flow-dup", simple_flow_json())
  let args3 = new_args()
  args3.insert(
    "f_ccActors",
    @json.array_of([@json.string_of("userX"), @json.string_of("userX")]),
  )
  let _ = engine.start_with_parent_async(did2, "user1", args3, 556L, "sub2")
  assert_eq(cc_rows_of(repo), 3L)
  assert_eq(cc_fired_actors(events).length(), 3)
}

///|
/// ⑦ 办理腿首轮正向对照（判重不误伤首次；与 issues/141 G6 那格同形，这里作 G2 的回归钉）
async test "i141-G2 办理腿 首轮正向对照：两新人建两行 fire 两码4" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-task-first", simple_flow_json())
  let inst = engine.start_async(did, "user1", new_args())
  assert_eq(cc_fired_actors(events).length(), 0)
  g2e_task_cc(engine, repo, inst.instance_id, ["userB", "userC"])
  assert_eq(cc_rows_of(repo), 2L)
  assert_true(cc_fired_actors(events) == ["userB", "userC"])
}

///|
/// ⑧ 已读状态跨入口不重置（引擎腿 × 门面 updateCCStatus 的交叉档）：
/// 先把人读掉，再由办理腿重复抄同一人 ⇒ state 仍 1、行数仍 1、不 fire。
async test "i141-G2 已读后再被重复抄送⇒state 保持且不 fire" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g2e-read-state", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", @json.array_of([@json.string_of("userB")]))
  let inst = engine.start_async(did, "user1", args)
  repo.update_cc_status(inst.instance_id, "userB")
  assert_eq(repo.cc_instances[0].state, 1)
  g2e_task_cc(engine, repo, inst.instance_id, ["userB"])
  assert_eq(cc_rows_of(repo), 1L)
  assert_eq(cc_fired_actors(events).length(), 1)
  assert_eq(repo.cc_instances[0].state, 1)
}
