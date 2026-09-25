// issues/120 附证：stats 的时间语义必须只有**一把钟**（引擎钟 `current_time_str()`）。
//
// 缺陷形状：`facade/stats.mbt` 里 `todayNew` 走 `@model.current_time_str()`（可注入），而
// `overdueTaskCount` 走裸 `@model.epoch_secs()`（= `@env.now()`，注入不了）⇒ 同一段统计代码
// 两把钟。宿主一旦注入时钟（Rust 侧 120 §9/§10 已按此形状收口），moon 的逾期数不跟着走。
//
// 用例设计要点（避开 rust 120 §10.6 记过的两种假绿）：
//   1) **不铺宽窗**：到期时间以注入钟为基准 ±1h，且注入钟与真实墙钟故意差 12 小时，
//      使「读注入钟」与「读裸墙钟」两种实现给出**不同答案**（1 vs 2），当场可分辨；
//   2) **必带阳性对照**：同一夹具里既有一条已到期、一条未到期，
//      否则 `overdue == 0` 这种"整块恒 0"的退化实现也能自证通过。

///|
fn sc_args(entries : Array[(String, String)]) -> Map[String, Json] {
  let args : Map[String, Json] = Map([])
  for (k, v) in entries {
    args[k] = @json.string_of(v)
  }
  args
}

///|
fn sc_data(env : Json) -> Json {
  @json.get(env, "data").unwrap_or(@json.null_json())
}

///|
fn sc_i64(data : Json, key : String) -> Int64 {
  @json.get_i64(data, key).unwrap_or(-999999L)
}

///|
/// 门面 + 给定内存仓（stats 只读 get_all_instances / get_all_tasks，不需要 define）
fn sc_facade_with(
  repo : @mem.MemoryRepository
) -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  @facade.Facade::make(ctx.with_id_generator(fn() { gen.next_id() }))
}

///|
/// 一条待办任务；`expire_time = None` ⇒ 该任务不参与逾期判定
fn sc_pending_task(
  task_id : Int64,
  iid : Int64,
  actor : String,
  expire_time : String?,
  create_time : String
) -> @model.ProcessTask {
  {
    task_id: task_id,
    process_instance_id: iid,
    task_name: "task1",
    display_name: "审批",
    task_type: 0,
    perform_type: 0,
    task_state: 10,
    actor_id: Some(actor),
    actor_ids: [actor],
    finish_time: None,
    expire_time: expire_time,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some(create_time),
    create_user: Some(actor),
    update_time: None,
    update_user: None,
  }
}

///|
/// 一条进行中实例
fn sc_instance(iid : Int64, create_time : String) -> @model.ProcessInstance {
  {
    instance_id: iid,
    parent_id: None,
    define_id: 1L,
    state: 10,
    parent_node_name: None,
    business_no: None,
    operator: "user1",
    expire_time: None,
    variables: @json.FlowData::new(),
    tasks: [],
    create_time: Some(create_time),
    create_user: Some("user1"),
    update_time: None,
    update_user: None,
    define_info: None,
  }
}

///|
async fn sc_overview(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository]
) -> Json raise {
  let env = facade.flow("processInstance/stats/overview", sc_args([]))
  // 先把信封钉住：action 名/装配错了要在这里红，不要让下面的 -999999 冒领
  assert_eq(@json.get_str(env, "msg").unwrap_or("<无 msg 键>"), "成功")
  sc_data(env)
}

///|
/// 核心格（修复前应红）：注入钟下逾期数以**注入钟**为准 ⇒ 1，而非裸墙钟的 2。
async test "stats 单钟: overdueTaskCount 跟随注入钟" {
  // 注入钟 = 真实 UTC 往前 12 小时 ⇒ 读注入钟得 1、读裸墙钟得 2，实现选了哪把当场可分辨
  let injected_secs = @model.epoch_secs() - 43200L
  let injected = @model.format_unix_utc(injected_secs)
  @model.set_clock(Some(fn() { injected }))
  defer { @model.set_clock(None) }
  // 注入确实生效的自检（否则下面的绿可能只是"没注入也没坏"）
  assert_eq(@model.current_time_str(), injected)

  let repo = @mem.MemoryRepository::new()
  let facade = sc_facade_with(repo)
  facade.repo.save_instance(sc_instance(9001L, injected))
  facade.repo.save_task(
    sc_pending_task(9101L, 9001L, "userA", Some(@model.format_unix_utc(injected_secs - 3600L)), injected),
  )
  facade.repo.save_task(
    sc_pending_task(9102L, 9001L, "userB", Some(@model.format_unix_utc(injected_secs + 3600L)), injected),
  )

  let data = sc_overview(facade)
  assert_eq(sc_i64(data, "pendingTaskCount"), 2L) // 阳性对照：两条待办都进了统计
  assert_eq(sc_i64(data, "overdueTaskCount"), 1L) // 核心断言：只有注入钟之前那条算逾期
  assert_eq(sc_i64(data, "todayNew"), 1L) // 控制组：todayNew 本就走注入钟
}

///|
/// 默认臂（修复前后都应为绿）：未注入时按真实 UTC 墙钟判逾期，同样 ±1h 真窗。
async test "stats 单钟: 未注入时按真实墙钟判逾期（默认臂）" {
  @model.set_clock(None) // 防御：上一条的 defer 若未跑到，这里强制复原默认臂
  let real_secs = @model.epoch_secs()
  let now_str = @model.current_time_str()
  let repo = @mem.MemoryRepository::new()
  let facade = sc_facade_with(repo)
  facade.repo.save_instance(sc_instance(9002L, now_str))
  facade.repo.save_task(
    sc_pending_task(9201L, 9002L, "userA", Some(@model.format_unix_utc(real_secs - 3600L)), now_str),
  )
  facade.repo.save_task(
    sc_pending_task(9202L, 9002L, "userB", Some(@model.format_unix_utc(real_secs + 3600L)), now_str),
  )

  let data = sc_overview(facade)
  assert_eq(sc_i64(data, "pendingTaskCount"), 2L)
  assert_eq(sc_i64(data, "overdueTaskCount"), 1L)
  assert_eq(sc_i64(data, "todayNew"), 1L)
}

///|
/// 同基准格：逾期判据与委托生效窗必须认同一把钟（120 §7.3 与 §3.2 是同一个洞的两面）。
async test "stats 单钟: 逾期基准与委托判窗基准同一把钟" {
  let injected_secs = @model.epoch_secs() - 43200L
  let injected = @model.format_unix_utc(injected_secs)
  let later = @model.format_unix_utc(injected_secs + 3600L) // 注入钟 +1h
  @model.set_clock(Some(fn() { injected }))
  defer { @model.set_clock(None) }

  let repo = @mem.MemoryRepository::new()
  let facade = sc_facade_with(repo)
  facade.repo.save_instance(sc_instance(9003L, injected))
  facade.repo.save_task(sc_pending_task(9301L, 9003L, "userA", Some(later), injected))

  // 唯一一条待办的到期时刻在注入钟之后 ⇒ 以注入钟判 0 逾期（以裸墙钟判会得 1）
  let data = sc_overview(facade)
  assert_eq(sc_i64(data, "overdueTaskCount"), 0L)

  // 同一个串拿去问委托窗判据（rows.mbt 走文本序）：注入钟在窗内、裸墙钟已越窗
  let s : @model.ProcessSurrogate = {
    id: 1L,
    process_name: "",
    operator: "userA",
    surrogate: "userB",
    start_time: None,
    end_time: Some(later),
    enabled: 1,
    create_time: Some(injected),
    create_user: Some("userA"),
    update_time: None,
    update_user: None,
  }
  assert_true(s.is_effective("userA", injected))
  assert_true(!s.is_effective("userA", @model.format_unix_utc(@model.epoch_secs())))
}
