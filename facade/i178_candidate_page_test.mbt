// issues/178 R12（audit8 队列 R12；spec 06:722-730）· moon 切片判据：
// candidatePage 模型候选映射链（findById→getUser→兜底）／行键 id 三级回落／搜索腿吃入参。
// 判据形状照 java JeeflowFacade.java:945-1012（参考实现）＋ issues/178 §4.1 三档＋搜索腿两档：
//   档① 仅 findById（命中）：行 id/realName/userId/deptName 取 findById 值，且**压过第二级**；
//       档①b findById 无 id 键（有 userId）：id 走 src.userId 回落（三级回落被消费）；
//   档② 无 findById 有 getUser：realName/deptName 取 getUser，id 走 src.userId 回落；
//   档③ 双无：兜底 id==actor、realName==id（回归档，改前行为）；
//   搜索腿：查询对象 pageNum/pageSize/m_* 与请求一致＋信封吃 provider 回显；
//       缺省档：不给分页参数 ⇒ 1/10（java QueryParser 同位默认）。
// 修前红样（变异对照见 §6.5 记账）：①候选腿只查第二级、id 恒 actor、搜索腿写死 1/10。
// 复用同包 helper：targs / code_of / msg_of / data_of / rows_of / parse_iid / doing_task_for。

///|
fn i178_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i178-cand] 红样：" + "\{label}")
    abort("[i178-cand] 红样：" + "\{label}")
  }
}

///|
/// 映射链夹具：start → apply(applicant) → review(leader) → approve(u100) → end。
/// startAndExecute 自动办结 apply ⇒ review 是 leader 的待办；candidatePage(review) 查后继
/// approve 节点的静态参与人（assignee）。
fn i178_map_flow() -> String {
  let s = $|{"name": "i178-map", "displayName": "178 映射链", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "review", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "approve", "type": "snaker:task",
  $|    "properties": {"assignee": "u100", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "review"},
  $|   {"id": "e2", "sourceNodeId": "review", "targetNodeId": "approve"},
  $|   {"id": "e3", "sourceNodeId": "approve", "targetNodeId": "end"}
  $| ]}
$|
  s
}

///|
/// 搜索腿夹具：同形但 approve 无 assignee ⇒ 模型候选为空 ⇒ 走用户分页搜索。
fn i178_search_flow() -> String {
  let s = $|{"name": "i178-search", "displayName": "178 搜索腿", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "review", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "approve", "type": "snaker:task",
  $|    "properties": {"taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "review"},
  $|   {"id": "e2", "sourceNodeId": "review", "targetNodeId": "approve"},
  $|   {"id": "e3", "sourceNodeId": "approve", "targetNodeId": "end"}
  $| ]}
$|
  s
}

///|
/// 字符串值 map（provider 桩供数）。
fn i178_m(pairs : Array[(String, String)]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for (k, v) in pairs {
    m[k] = @json.string_of(v)
  }
  m
}

///|
/// 搜索 provider 桩：page 捕获查询对象（回出与查询同页码页长，同 demo/provider 语义），
/// find_by_id 回固定档（None＝该档不命中）。
fn i178_search_with(
  captured : Array[@model.PageQuery],
  by_id : Map[String, Json]?
) -> @spi.UserSearchProviderFns {
  let none_rows : Array[Map[String, Json]] = []
  {
    page: fn(q) {
      captured.push(q)
      @model.PageResult::new(q.page_num(), q.page_size(), none_rows.length().to_int64(), none_rows)
    },
    find_by_id: fn(_uid) { by_id },
  }
}

///|
/// 装配：按需注入两级 provider 后建门面；发起 auto 流程至 review 待办。
async fn i178_setup(
  content : String,
  search : @spi.UserSearchProviderFns?,
  user : ((String) -> @model.UserInfo? raise @error.JeeflowError)?
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let mut ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  match search {
    Some(s) => ctx2 = ctx2.with_user_search_provider(s)
    None => ()
  }
  match user {
    Some(u) => ctx2 = ctx2.with_user_provider_sync(u)
    None => ()
  }
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i178-flow",
    display_name: "178 候选格",
    define_type: "approval",
    state: 1,
    content,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  i178_check(code_of(env) == 0L, "发起 code=0（msg=\{msg_of(env)}）")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  (facade, repo, iid)
}

///|
fn i178_row_str(row : Json, key : String) -> String {
  @json.get_str(row, key).unwrap_or("<无键>")
}

///|
async test "i178 档① 仅 findById 命中：行取 provider 真值且压过 getUser" {
  let cap : Array[@model.PageQuery] = []
  let search = i178_search_with(
    cap,
    Some(i178_m([("id", "U100"), ("userId", "U100"), ("realName", "张三"), ("deptName", "研发部")])),
  )
  let (facade, repo, iid) = i178_setup(
    i178_map_flow(),
    Some(search),
    Some(fn(_uid) { Some(@model.UserInfo::make(user_id="U999", real_name="第二级不该出现")) }),
  )
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow("processTask/candidatePage", targs([("processTaskId", tid.to_string())]))
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  let rows = rows_of(data_of(env))
  i178_check(rows.length() == 1, "行数=1（实 \{rows.length()}）")
  let r = rows[0]
  i178_check(i178_row_str(r, "id") == "U100", "row.id=U100（实 \{i178_row_str(r, "id")}）")
  i178_check(i178_row_str(r, "realName") == "张三", "realName 取 findById＝张三（实 \{i178_row_str(r, "realName")}）")
  i178_check(i178_row_str(r, "userId") == "U100", "userId=U100（实 \{i178_row_str(r, "userId")}）")
  i178_check(i178_row_str(r, "deptName") == "研发部", "deptName=研发部（实 \{i178_row_str(r, "deptName")}）")
}

///|
async test "i178 档①b findById 无 id 键：id 走 src.userId 回落" {
  let cap : Array[@model.PageQuery] = []
  let search = i178_search_with(cap, Some(i178_m([("userId", "U200"), ("realName", "李四")])))
  let (facade, repo, iid) = i178_setup(i178_map_flow(), Some(search), None)
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow("processTask/candidatePage", targs([("processTaskId", tid.to_string())]))
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  let rows = rows_of(data_of(env))
  i178_check(rows.length() == 1, "行数=1（实 \{rows.length()}）")
  let r = rows[0]
  i178_check(i178_row_str(r, "id") == "U200", "row.id 回落 src.userId=U200（实 \{i178_row_str(r, "id")}）")
  i178_check(i178_row_str(r, "realName") == "李四", "realName=李四（实 \{i178_row_str(r, "realName")}）")
  i178_check(i178_row_str(r, "userId") == "U200", "userId=U200（实 \{i178_row_str(r, "userId")}）")
}

///|
async test "i178 档② 无 findById 有 getUser：realName/deptName 取 getUser" {
  // 发起期引擎也会经 getUser 水合参与人（apply 的 applicant）⇒ 桩只认 u100，
  // 并在 candidatePage 后复核 u100 确被查询（防"水合命中"冒充映射腿命中）。
  let hits : Array[String] = []
  let (facade, repo, iid) = i178_setup(
    i178_map_flow(),
    None,
    Some(fn(uid) {
      hits.push(uid)
      if uid == "u100" {
        Some(@model.UserInfo::make(user_id="U300", real_name="王五", dept_name="测试部"))
      } else {
        None
      }
    }),
  )
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow("processTask/candidatePage", targs([("processTaskId", tid.to_string())]))
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  i178_check(hits.contains("u100"), "getUser 收到映射 actor=u100（实 \{hits.join(",")}）")
  let rows = rows_of(data_of(env))
  i178_check(rows.length() == 1, "行数=1（实 \{rows.length()}）")
  let r = rows[0]
  i178_check(i178_row_str(r, "id") == "U300", "row.id 回落 src.userId=U300（实 \{i178_row_str(r, "id")}）")
  i178_check(i178_row_str(r, "realName") == "王五", "realName 取 getUser＝王五（实 \{i178_row_str(r, "realName")}）")
  i178_check(i178_row_str(r, "userId") == "U300", "userId=U300（实 \{i178_row_str(r, "userId")}）")
  i178_check(i178_row_str(r, "deptName") == "测试部", "deptName=测试部（实 \{i178_row_str(r, "deptName")}）")
}

///|
async test "i178 档③ 双无：兜底 id==actor、realName==id（回归档）" {
  let (facade, repo, iid) = i178_setup(i178_map_flow(), None, None)
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow("processTask/candidatePage", targs([("processTaskId", tid.to_string())]))
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  let rows = rows_of(data_of(env))
  i178_check(rows.length() == 1, "行数=1（实 \{rows.length()}）")
  let r = rows[0]
  i178_check(i178_row_str(r, "id") == "u100", "兜底 row.id=actor=u100（实 \{i178_row_str(r, "id")}）")
  i178_check(i178_row_str(r, "realName") == "u100", "兜底 realName==id（实 \{i178_row_str(r, "realName")}）")
}

///|
async test "i178 搜索腿：pageNum/pageSize/m_* 与请求一致＋信封吃回显" {
  let cap : Array[@model.PageQuery] = []
  let search = i178_search_with(cap, None)
  let (facade, repo, iid) = i178_setup(i178_search_flow(), Some(search), None)
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow(
    "processTask/candidatePage",
    targs([
      ("processTaskId", tid.to_string()),
      ("pageNum", "2"),
      ("pageSize", "5"),
      ("m_EQ_status", "1"),
    ]),
  )
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  i178_check(cap.length() == 1, "provider.page 被调 1 次（实 \{cap.length()}）")
  if cap.length() == 1 {
    let q = cap[0]
    i178_check(q.page_num() == 2L, "查询 pageNum=2（实 \{q.page_num()}）")
    i178_check(q.page_size() == 5L, "查询 pageSize=5（实 \{q.page_size()}）")
    let fs = q.filters()
    i178_check(fs.length() == 1, "查询 filters=1 条（实 \{fs.length()}）")
    if fs.length() == 1 {
      let f = fs[0]
      i178_check(f.table_alias() == "t", "filter 主表别名 t（实 \{f.table_alias()}）")
      i178_check(f.op() == @model.Eq, "filter 操作符 Eq")
      i178_check(f.column() == "status", "filter 列 status（实 \{f.column()}）")
      i178_check(f.value() == "1", "filter 值 1（实 \{f.value()}）")
    }
  }
  let data = data_of(env)
  i178_check(
    @json.get_i64(data, "pageNum").unwrap_or(-1L) == 2L,
    "信封 pageNum=2（实 \{@json.get_i64(data, "pageNum").unwrap_or(-1L)}）",
  )
  i178_check(
    @json.get_i64(data, "pageSize").unwrap_or(-1L) == 5L,
    "信封 pageSize=5（实 \{@json.get_i64(data, "pageSize").unwrap_or(-1L)}）",
  )
}

///|
async test "i178 搜索腿缺省档：不给分页参数 ⇒ 1/10（java QueryParser 同位默认）" {
  let cap : Array[@model.PageQuery] = []
  let search = i178_search_with(cap, None)
  let (facade, repo, iid) = i178_setup(i178_search_flow(), Some(search), None)
  let tid = (doing_task_for(repo, iid, "leader")).task_id
  let env = facade.flow("processTask/candidatePage", targs([("processTaskId", tid.to_string())]))
  i178_check(code_of(env) == 0L, "candidatePage code=0（msg=\{msg_of(env)}）")
  i178_check(cap.length() == 1, "provider.page 被调 1 次（实 \{cap.length()}）")
  if cap.length() == 1 {
    let q = cap[0]
    i178_check(q.page_num() == 1L, "缺省 pageNum=1（实 \{q.page_num()}）")
    i178_check(q.page_size() == 10L, "缺省 pageSize=10（实 \{q.page_size()}）")
  }
  let data = data_of(env)
  i178_check(
    @json.get_i64(data, "pageSize").unwrap_or(-1L) == 10L,
    "信封 pageSize=10（实 \{@json.get_i64(data, "pageSize").unwrap_or(-1L)}）",
  )
}
