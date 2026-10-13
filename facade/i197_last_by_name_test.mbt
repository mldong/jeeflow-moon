// issues/197 · 门面 `processDefine/getLastByName` 在内存仓上拿到的是不是「那条流程的最新版本」。
//
// 病灶三处合起来（SQL 腿硬编码 id 倒序／内存腿连条件都不滤还升序／门面补偿只在 LIMIT 1 的单行上
// 再 max 一次）⇒ 这一条 action 在内存档**能返回异名定义且 code=0**，「流程定义不存在」那一支
// 反而永远不触发。出处卡：C7-L3 N-4（本卡最重乙档）＋ C5-L3 §8-3；卡面对本 action 的判据记账是
// 「runner 命中 2 处但都是夹具取 defineId 用 ⇒ 六键／最新版本／负向文案零判据」，现读本仓 `get_last_by_name`
// 在全部 *_test.mbt 里 **零命中** ⇒ 这组格子是首例，不是重复。
//
// 夹具与 core/memory/i197_define_filter_order_test.mbt 同形：i197-a 有两行，**版本最大的那条 id 最小**，
// 另有一行异名夹在中间 ⇒ 「按 id 取首行」和「按版本取最新」两个答案互不相同。

///|
fn i197a_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i197-getLastByName] 红样：" + "\{label}")
    abort("[i197-getLastByName] 红样：" + "\{label}")
  }
}

///|
fn i197_facade(
  repo : @mem.MemoryRepository
) -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx)
}

///|
fn i197_define(id : Int64, name : String, version : Int) -> @model.ProcessDefine {
  {
    id: id,
    name: name,
    display_name: "i197 门面夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: version,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
/// 三行：id=1 v=2 / id=2 v=5（异名诱饵）/ id=3 v=10 —— 请求 "i197-a" 的正确答案只有 id=3
fn i197_setup() -> (
  @mem.MemoryRepository, @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository]
) {
  let repo = @mem.MemoryRepository::new()
  repo.put_define_direct(i197_define(1L, "i197-a", 2))
  repo.put_define_direct(i197_define(2L, "i197-b", 5))
  repo.put_define_direct(i197_define(3L, "i197-a", 10))
  (repo, i197_facade(repo))
}

///|
async test "i197-正向 getLastByName 返回该名的最新版本行（不是最后插入那条）" {
  let (_, facade) = i197_setup()
  let env = facade.flow("processDefine/getLastByName", targs([("processDefineName", "i197-a")]))
  i197a_check(code_of(env) == 0L, "信封 code=0（msg=\{msg_of(env)}）")
  let data = data_of(env)
  i197a_check(
    ob_cell(data, "id") == "3",
    "id＝版本最大那条 3（实际 <\{ob_cell(data, "id")}>；旧内存腿不滤条件还升序 ⇒ 给 id=1 那条 v=2）",
  )
  i197a_check(ob_cell(data, "name") == "i197-a", "name＝请求名（异名＝拿错行）")
  i197a_check(ob_cell(data, "version") == "10", "version＝10（实际 <\{ob_cell(data, "version")}>）")
  // 六键齐（spec 06 §4.5 getLastByName 出口）
  // 出口六键（spec 06 §4.5 getLastByName 行形状；本栈出口已过 camel 化 ⇒ 键名是 displayName）
  for k in ["id", "name", "displayName", "type", "state", "version"] {
    i197a_check(ob_cell(data, k) != "<missing>", "出口含键 \{k}")
  }
}

///|
async test "i197-负向 名查无 ⇒ 报错而非返回别人的定义" {
  let (_, facade) = i197_setup()
  let env = facade.flow("processDefine/getLastByName", targs([("processDefineName", "i197-none")]))
  i197a_check(code_of(env) != 0L, "查无此名必须报错（修前这里 code=0 且返回 i197-a／i197-b 的行）")
  i197a_check(
    msg_of(env).contains("流程定义不存在: i197-none"),
    "文案点名请求名（实际 <\{msg_of(env)}>）",
  )
}

///|
async test "i197-负向 缺 processDefineName 入参 ⇒ 报缺参不是拿全表首行" {
  let (_, facade) = i197_setup()
  let env = facade.flow("processDefine/getLastByName", targs([]))
  i197a_check(code_of(env) != 0L, "缺参必须报错")
  i197a_check(msg_of(env).contains("缺少processDefineName参数"), "文案＝缺参（实际 <\{msg_of(env)}>）")
}

///|
async test "i197-回归 processDefine/page 的 m_ 后过滤与总数不受影响" {
  let (_, facade) = i197_setup()
  let env = facade.flow("processDefine/page", targs([("pageNum", "1"), ("pageSize", "10")]))
  i197a_check(code_of(env) == 0L, "processDefine/page code=0（msg=\{msg_of(env)}）")
  let rows = rows_of(data_of(env))
  i197a_check(rows.length() == 3, "无过滤 ⇒ 三行全出（实际 \{rows.length()}）")
  let filtered = facade.flow(
    "processDefine/page",
    targs([("pageNum", "1"), ("pageSize", "10"), ("m_EQ_name", "i197-a")]),
  )
  let frows = rows_of(data_of(filtered))
  i197a_check(
    code_of(filtered) == 0L && frows.length() == 2,
    "m_EQ_name=i197-a ⇒ 两行（实际 \{frows.length()}，msg=\{msg_of(filtered)}）",
  )
}
