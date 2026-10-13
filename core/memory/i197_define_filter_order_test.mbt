// issues/197 · 内存腿 `page_defines` 的条件过滤与排序消费（audit8 R31）。
//
// 病灶：这一腿原先 `filters`／`order_by` 两者都不读，还按 id **升序**出页 ⇒ 门面 4 个带条件的
// 内部调用（deploy／processDesign redeploy／saveDeployedDefine／getLastByName）拿到的是
// 「全表 id 最小的任意名定义」——不是"序不一样"，是**拿错行**。参照实现 java 的内存仓
// `MemoryProcessRepository.pageDefines:571-597` 逐字注明「通用条件过滤（含 t.name EQ / t.state GT，
// JeeflowFacade deploy 版本查询依赖）」⇒ 缺的正是这一档。
//
// 夹具刻意做成 **version 与 id 反向**（v=10 的行 id 最小）：任何"按 id 取首行"的实现都会被抓出。
// 门面出口那一侧的回归格在 facade/i197_last_by_name_test.mbt（core/memory 不能反向依赖 facade）。

///|
fn i197_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i197-内存腿分页] 红样：" + "\{label}")
    abort("[i197-内存腿分页] 红样：" + "\{label}")
  }
}

///|
fn i197_define(id : Int64, name : String, version : Int) -> @model.ProcessDefine {
  {
    id: id,
    name: name,
    display_name: "i197 夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: version,
    create_time: Some("2026-10-1\{version.to_string()} 00:00:00"),
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
/// 三行同名／异名混排：i197-a 有 id=1(v=2) 与 id=3(v=10)，诱饵行 id=2(v=5) 异名。
/// 「最新版本」＝id 3＝「最后插入」，而旧内存腿「不滤条件＋升序」的首行＝id 1 ⇒ 新旧两个答案互不相同。
fn i197_setup() -> @memory.MemoryRepository {
  let repo = @memory.MemoryRepository::new()
  repo.put_define_direct(i197_define(1L, "i197-a", 2))
  repo.put_define_direct(i197_define(2L, "i197-b", 5))
  repo.put_define_direct(i197_define(3L, "i197-a", 10))
  repo
}

///|
fn i197_ids_text(ids : Array[Int64]) -> String {
  let mut out = "["
  for i, v in ids {
    if i > 0 {
      out = out + ","
    }
    out = out + v.to_string()
  }
  out + "]"
}

///|
fn i197_ids(rows : Array[@model.DefineRow]) -> Array[Int64] {
  let out : Array[Int64] = []
  for r in rows {
    out.push(r.id)
  }
  out
}

///|
async test "i197-正向 同名两行：条件命中两条、order_by 取到最新版本行" {
  let repo = i197_setup()
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", "i197-a"))
  query.set_order_by("t.version desc")
  let page = repo.page_defines(query)
  i197_check(page.record_count() == 2L, "record_count＝该名的行数 2（实际 \{page.record_count()}）")
  i197_check(page.rows().length() == 1, "page(1,1) 只出一行")
  i197_check(page.rows()[0].id == 3L, "首行＝版本最大那条 id=3（实际 \{page.rows()[0].id}；旧内存腿不滤条件还升序 ⇒ 给 id=1）")
  i197_check(
    page.rows()[0].version == 10, "首行 version=10（实际 \{page.rows()[0].version}）",
  )
  i197_check(page.rows()[0].name == "i197-a", "首行名＝请求名（异名即拿错行）")
}

///|
async test "i197-负向 查不到的名 ⇒ 空页（修前返回全表首行且异名）" {
  let repo = i197_setup()
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", "i197-missing"))
  query.set_order_by("t.version desc")
  let page = repo.page_defines(query)
  i197_check(page.record_count() == 0L, "record_count=0（实际 \{page.record_count()}）")
  i197_check(page.rows().is_empty(), "rows 为空（修前这里会出 id=1 那条 i197-a）")
  // 空串条件同样不得退化成"这条没填"⇒ 全表
  let blank = @model.PageQuery::new(1L, 10L)
  blank.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", ""))
  i197_check(repo.page_defines(blank).record_count() == 0L, "name='' ⇒ 空页，不放行全表")
}

///|
async test "i197-回归 无 order_by ⇒ 缺省 id 倒序（与 SQL 腿缺省序、java/go/py/node 内存腿同档）" {
  let repo = i197_setup()
  let page = repo.page_defines(@model.PageQuery::new(1L, 10L))
  i197_check(page.record_count() == 3L, "无条件 ⇒ 三行全出")
  let ids = i197_ids(page.rows())
  i197_check(
    ids.length() == 3 && ids[0] == 3L && ids[1] == 2L && ids[2] == 1L,
    "id 倒序 [3,2,1]（实际 <\{i197_ids_text(ids)}>",
  )
}

///|
async test "i197-排序档 order_by 列在白名单外 ⇒ 整条跳过并回落 id 倒序（不抛错、不拿别列凑）" {
  let repo = i197_setup()
  let query = @model.PageQuery::new(1L, 10L)
  query.set_order_by("t.password desc")
  let ids = i197_ids(repo.page_defines(query).rows())
  i197_check(
    ids.length() == 3 && ids[0] == 3L && ids[2] == 1L,
    "未知列被跳过 ⇒ 缺省 id 倒序（实际 <\{i197_ids_text(ids)}>",
  )
}

///|
async test "i197-数值档 版本比较走整数档（串比会把 v=10 判成小于 v=5）" {
  let repo = i197_setup()
  let query = @model.PageQuery::new(1L, 10L)
  query.add_filter(@model.QueryFilter::make("t", @model.Gt, "version", "9"))
  let page = repo.page_defines(query)
  i197_check(
    page.record_count() == 1L && page.rows()[0].id == 3L,
    "version>9 只命中 v=10 那条 id=3（实际 count=\{page.record_count()}）",
  )
  // In 档：逗号清单，不 trim，逐字对齐 SQL 腿
  let in_q = @model.PageQuery::new(1L, 10L)
  in_q.add_filter(@model.QueryFilter::make("t", @model.In, "id", "3,2"))
  let in_ids = i197_ids(repo.page_defines(in_q).rows())
  i197_check(
    in_ids.length() == 2 && in_ids[0] == 3L && in_ids[1] == 2L,
    "id IN (3,2) ⇒ 两行且缺省倒序（实际 <\{i197_ids_text(in_ids)}>",
  )
  // NULL 档：时间列为 NULL 的行参与比较是 unknown ⇒ 不出
  let repo2 = @memory.MemoryRepository::new()
  let dnull : @model.ProcessDefine = {
    id: 7L,
    name: "i197-null",
    display_name: "i197 夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo2.put_define_direct(dnull)
  let nt = @model.PageQuery::new(1L, 10L)
  nt.add_filter(@model.QueryFilter::make("t", @model.Like, "create_time", "2026"))
  i197_check(repo2.page_defines(nt).record_count() == 0L, "create_time 为 NULL ⇒ 该行不出（SQL NULL 语义）")
}

///|
async test "i197-形状 两腿同答案的内存侧：LIKE 命中一条时值也对得上" {
  let repo = i197_setup()
  let query = @model.PageQuery::new(1L, 10L)
  query.add_filter(@model.QueryFilter::make("pd", @model.Like, "name", "i197-b"))
  let page = repo.page_defines(query)
  i197_check(page.record_count() == 1L, "别名 pd 同样认（本腿只看裸列名）")
  i197_check(!page.rows().is_empty() && page.rows()[0].id == 2L, "命中 id=2 那条 i197-b")
}
