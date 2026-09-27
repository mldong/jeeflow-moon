// issues/129 案 A（spec 06-facade §2.5）：operator **空串与缺键同档**的门面归一化（第一层）
// + 归属谓词列空值兜底（第二层哨兵），全部走内存仓通道（T0，不连 MySQL）。
//
// 160 三档并排探针里 moon 的洞在第一层：门面把 `{"operator":""}` 当真实值往下传，
// 仓储拿空串比对归属列 ⇒「我的列表」悄悄变 0 行（java/go/python/node/csharp 是丢掉条件
// ⇒ 读全库，同案另一种形状）。修法按拍板：空串/全空白/缺键三档一律回落 demo 缺省 user1。
//
// ⚠️ 夹具刻意做成**非对称**：四个出口都是 user1=2 行 / other=1 行 / 全库=3 行。
//    空仓上"空串档 == 缺省档"恒真（0==0 自等假绿），那种夹具等于没测。

///|
fn ob_facade(
  repo : @mem.MemoryRepository
) -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx)
}

///|
/// 任务夹具：state=10 进行中（归属看 actor_ids，actor_id 恒无值）；state=20 办结（归属看 actor_id）
fn ob_task(iid : Int64, name : String, state : Int, actor : String) -> @model.ProcessTask {
  {
    task_id: 0L,
    process_instance_id: iid,
    task_name: name,
    display_name: name,
    task_type: 0,
    perform_type: 0,
    task_state: state,
    actor_id: if state == 10 { None } else { Some(actor) },
    actor_ids: [actor],
    finish_time: if state == 10 { None } else { Some("2026-09-28 10:00:00") },
    expire_time: None,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some("2026-09-28 09:00:00"),
    create_user: Some(actor),
    update_time: None,
    update_user: None,
  }
}

///|
/// 夹具：3 实例（user1×2 / other×1）+ 3 已办 + 3 待办 + 3 抄送 ⇒ 四出口均 user1=2/other=1/全库=3
async fn ob_setup() -> (
  @mem.MemoryRepository, @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository]
) raise {
  let repo = @mem.MemoryRepository::new()
  let facade = ob_facade(repo)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i129-flow",
    display_name: "i129 归属分页夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let inst_a = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let inst_b = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let inst_c = @model.ProcessInstance::create(define_info, "other", @json.FlowData::new())
  repo.save_instance(inst_a)
  repo.save_instance(inst_b)
  repo.save_instance(inst_c)
  let specs : Array[(Int64, String)] = [
    (inst_a.instance_id, "user1"),
    (inst_b.instance_id, "user1"),
    (inst_c.instance_id, "other"),
  ]
  for spec in specs {
    let (iid, actor) = spec
    repo.save_task(ob_task(iid, "i129-done", 20, actor))
    repo.save_task(ob_task(iid, "i129-todo", 10, actor))
  }
  repo.create_cc_instance(inst_a.instance_id, "user1", ["user1"])
  repo.create_cc_instance(inst_b.instance_id, "user1", ["user1"])
  repo.create_cc_instance(inst_c.instance_id, "other", ["other"])
  (repo, facade)
}

// ── 出口读数（信封 code 必须 0：flow 会把 raise 转成错误信封，不看 code 就是"报错当空页"假绿）──

///|
async fn ob_rows(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  action : String,
  entries : Array[(String, String)]
) -> Array[Json] raise {
  let env = facade.flow(action, targs(entries))
  let code = code_of(env)
  if code != 0L {
    abort("\{action} 出口报错：code=\{code} msg=\{msg_of(env)}")
  }
  rows_of(data_of(env))
}

///|
async fn ob_count(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  action : String,
  entries : Array[(String, String)]
) -> Int64 raise {
  let env = facade.flow(action, targs(entries))
  let code = code_of(env)
  if code != 0L {
    abort("\{action} 出口报错：code=\{code} msg=\{msg_of(env)}")
  }
  record_count_of(data_of(env))
}

///|
/// 出口行的 id 集合（比较"同不同档"不能只比条数）
async fn ob_ids(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  action : String,
  entries : Array[(String, String)]
) -> Array[String] raise {
  let rows = ob_rows(facade, action, entries)
  let out : Array[String] = []
  for row in rows {
    out.push(ob_cell(row, "id"))
  }
  out
}

///|
/// 行上某键（数字/字符串都收成串；id 出口已过 stringify_ids，这里两种都兜住）
fn ob_cell(row : Json, key : String) -> String {
  match @json.get(row, key) {
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => s
        None => @json.stringify(v)
      }
    None => "<missing>"
  }
}

///|
/// 四档共用断言组（案 A 核心）：正/空/空白三档同数**且同集合**、user1 档非空；
/// 负向两档（他人档、全库）都不得与空串档同数。
async fn ob_four_exits(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  action : String
) -> Unit raise {
  let c_u1 = ob_count(facade, action, [("operator", "user1")])
  let c_missing = ob_count(facade, action, [])
  let c_blank = ob_count(facade, action, [("operator", "")])
  let c_ws = ob_count(facade, action, [("operator", "   ")])
  let c_other = ob_count(facade, action, [("operator", "other")])
  // 正向：user1 档非空（0 行时下面三条全是 0==0 自等假绿）
  assert_eq(c_u1, 2L)
  // 案 A：空串 / 全空白 / 缺键三档与显式 user1 同数
  assert_eq(c_missing, c_u1)
  assert_eq(c_blank, c_u1)
  assert_eq(c_ws, c_u1)
  // 同数还要同集合：防"恰好都是 2 行，但不是那 2 行"
  let ids_u1 = ob_ids(facade, action, [("operator", "user1")])
  let ids_blank = ob_ids(facade, action, [("operator", "")])
  assert_eq(ids_u1.length(), 2)
  assert_true(ids_u1.sort() == ids_blank.sort())
  // 负向 1：空串档不是"别人的档"
  assert_eq(c_other, 1L)
  assert_true(c_blank != c_other)
  // 负向 2：空串档不是全库（本夹具全库 = user1 的 2 + other 的 1 = 3）
  assert_true(c_blank != c_u1 + c_other)
}

///|
async test "i129-L1 processInstance/page: 空串＝缺键同档，回落 user1" {
  let (_, facade) = ob_setup()
  ob_four_exits(facade, "processInstance/page")
  // 空串档读回的归属列确实全是 user1（不是"恰好条数对"）
  let rows = ob_rows(facade, "processInstance/page", [("operator", "")])
  assert_eq(rows.length(), 2)
  for row in rows {
    assert_eq(ob_cell(row, "operator"), "user1")
  }
}

///|
async test "i129-L1 processTask/todoList: 空串＝缺键同档" {
  let (_, facade) = ob_setup()
  ob_four_exits(facade, "processTask/todoList")
}

///|
async test "i129-L1 processTask/doneList: 空串＝缺键同档" {
  let (_, facade) = ob_setup()
  ob_four_exits(facade, "processTask/doneList")
}

///|
async test "i129-L1 processInstance/ccList: 空串＝缺键同档" {
  let (_, facade) = ob_setup()
  ob_four_exits(facade, "processInstance/ccList")
  let rows = ob_rows(facade, "processInstance/ccList", [("operator", " \t ")])
  assert_eq(rows.length(), 2)
  for row in rows {
    assert_eq(ob_cell(row, "operator"), "user1")
  }
}

///|
/// 第一层的单元面：operator_arg 四条判据（缺键/空串/全空白 ⇒ 缺省；非空白 ⇒ 原值）
test "i129-L1 operator_arg 归一化本身" {
  let missing : Map[String, Json] = Map([])
  assert_eq(@facade.operator_arg(missing), "user1")
  let empty : Map[String, Json] = Map([])
  empty["operator"] = @json.string_of("")
  assert_eq(@facade.operator_arg(empty), "user1")
  let ws : Map[String, Json] = Map([])
  ws["operator"] = @json.string_of(" \t\r\n ")
  assert_eq(@facade.operator_arg(ws), "user1")
  let given : Map[String, Json] = Map([])
  given["operator"] = @json.string_of("someone")
  assert_eq(@facade.operator_arg(given), "someone")
  // 缺省值不吞非 operator 的 key：通用取值函数 arg_str_or 未被改（其它 key 仍拿空串原值）
  let other : Map[String, Json] = Map([])
  other["taskName"] = @json.string_of("")
  assert_eq(@facade.arg_str_or(other, "taskName", "fallback"), "")
}

///|
/// 第二层（内存通道哨兵）：归属列空值 ⇒ 空页；**非归属列**空值仍按"没填"忽略。
/// 内存通道的 m_ 过滤本就没有"空值丢条件"的形态（facade_parse_m_filters 无 isEmpty 跳过，
/// 见 facade/facade.mbt:110），这条防后续照搬 SQL 侧通用放行时把归属列一起吞掉。
async test "i129-L2 内存通道: 归属列空值=空页，可选过滤空值仍忽略" {
  let (_, facade) = ob_setup()
  assert_eq(
    ob_count(facade, "processInstance/page", [("operator", "user1"), ("m_EQ_operator", "")]),
    0L,
  )
  assert_eq(
    ob_count(facade, "processInstance/page", [("operator", "user1"), ("m_LIKE_displayName", "")]),
    2L,
  )
}

///|
/// 边界留档（不是本案改动，防后续把两档混为一谈）：
/// ① 直连仓储、operator 真缺失（None）时 doneList 是空页 = issues/117 §3.2 既有判据；
/// ② page/todo/cc 的 None 档仍是"无过滤=全量"（本栈既有判据，案 A 未收这一档）；
/// ③ 直连仓储给空串 ⇒ 0 行（本栈从不"丢掉条件"，只把空串当真实值比对）。
async test "i129 边界留档: 直连仓储 None/空串 两档形状" {
  let (repo, _) = ob_setup()
  assert_eq(repo.page_done_tasks(@model.PageQuery::new(1L, 50L)).record_count(), 0L)
  assert_eq(repo.page_instances(@model.PageQuery::new(1L, 50L)).record_count(), 3L)
  assert_eq(repo.page_todo_tasks(@model.PageQuery::new(1L, 50L)).record_count(), 3L)
  assert_eq(repo.page_cc_instances(@model.PageQuery::new(1L, 50L)).record_count(), 3L)
  let q_blank = @model.PageQuery::new(1L, 50L)
  q_blank.set_operator(Some(""))
  assert_eq(repo.page_instances(q_blank).record_count(), 0L)
  let q_blank2 = @model.PageQuery::new(1L, 50L)
  q_blank2.set_operator(Some(""))
  assert_eq(repo.page_todo_tasks(q_blank2).record_count(), 0L)
  let q_blank3 = @model.PageQuery::new(1L, 50L)
  q_blank3.set_operator(Some(""))
  assert_eq(repo.page_cc_instances(q_blank3).record_count(), 0L)
}
