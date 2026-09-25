// issues/114/115/116/117 门面级真机对拍（T1-F）：withdraw / transfer / 委托自动生效 / 我已办判据
// 走 **JeeflowFacade + MysqlRepository** 全链路，断言一律读**库里的列**或仓储读回值，
// 不信聚合副本（issues/113 能活五个版本，就是因为全员断"doing 列表为空"这种间接信号）。
// 为什么单开一个可执行而不并进 repository-mysql/smoke：本栈发布拓扑序是
// core → persist → repository-mysql → facade，让 repository-mysql 反向依赖 facade 会打破它
// （publish.yml 按序发版），故门面级 SQL 用例落在**不发布**的 demo 模块（先例：demo/cmd/consistency）。
// 运行：moon run --target wasm demo/cmd/t1_mysql
// 数据纪律（R6）：9xxxxx 段 + 测前测后自清理 + 凭据只走 JEFFLOW_DB_* env；SKIP_MYSQL=1 跳过。

///|
fn skip_mysql() -> Bool {
  @env.get_env_var("SKIP_MYSQL") is Some("1")
}

///|
fn check(cond : Bool, label : String) -> Unit {
  if cond {
    println("  PASS \{label}")
  } else {
    println("  FAIL \{label}")
    abort("T1-F assertion failed: \{label}")
  }
}

///|
/// 值对比断言（失败必须把**实际值**打出来——真机对拍没有第二次机会靠猜定位）
fn check_eq(actual : String, expected : String, label : String) -> Unit {
  if actual == expected {
    println("  PASS \{label}")
  } else {
    println("  FAIL \{label}")
    println("       实际=<\{actual}> 期望=<\{expected}>")
    abort("T1-F assertion failed: \{label}")
  }
}

///|
/// 两节点线性流：apply(发起人) 自动办结 → task1(leader) DOING → end
const WT_FLOW : String =
  $|{"name": "t1-f-wt", "displayName": "T1F撤回转办", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "task1", "type": "snaker:task", "text": {"value": "审批"},
  $|   "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|  {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $|]}

///|
/// 9xxxxx 段自清理（只动 jeeflow 库 wf_* 表；先按外键清雪花 id 的子行）
async fn clean_9x(repo : @repo.MysqlRepository) -> Unit raise {
  let sub_conn = repo.open_raw()
  let _ = @repo.q(
    sub_conn,
    "DELETE FROM wf_process_task_actor WHERE process_task_id IN (SELECT id FROM wf_process_task WHERE id >= 990000 AND id < 1000000)",
    [],
  )
  let _ = @repo.q(
    sub_conn,
    "DELETE FROM wf_process_cc_instance WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE id >= 990000 AND id < 1000000)",
    [],
  )
  @repo.close_conn(sub_conn)
  let tables = [
    "wf_process_task_actor",
    "wf_process_task",
    "wf_process_cc_instance",
    "wf_process_instance",
    "wf_process_define",
  ]
  for t in tables {
    let conn = repo.open_raw()
    let _ = @repo.q(conn, "DELETE FROM \{t} WHERE id >= 990000 AND id < 1000000", [])
    @repo.close_conn(conn)
  }
}

///|
async fn save_define_9x(repo : @repo.MysqlRepository, id : Int64, name : String, content : String) -> Unit raise {
  let conn = repo.open_raw()
  let _ = @repo.x(
    conn,
    "INSERT INTO wf_process_define (id, name, display_name, type, state, content, version, create_time, create_user) VALUES (?, ?, ?, 'approval', 1, ?, 1, NOW(), 't1f')",
    [@moondb.Int64(id), @moondb.Text(name), @moondb.Text(name), @moondb.Text(content)],
  )
  @repo.close_conn(conn)
}

///|
/// 门面 + 真机 MySQL 仓储（id 计数器落 990xxx 段；SQL 仓走 NoExtRepository）
fn make_facade(
  repo : @repo.MysqlRepository,
  start : Int64
) -> @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository] {
  let counter : Ref[Int64] = Ref(start)
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  let ctx2 = ctx.with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  })
  @facade.Facade::make(ctx2)
}

// ── 库里读回助手 ──

///|
/// NULL 安全单元格（<NULL> 与 "" 必须可分辨：红线断言读的就是这一格）
fn cell(r : @moondb.Row, col : String) -> String {
  match r.by_name(col) {
    None => "<无此列>"
    Some(v) =>
      match v {
        @moondb.Null => "<NULL>"
        @moondb.Text(s) => s
        @moondb.Blob(b) => @utf8.decode_lossy(b[:])
        @moondb.Int64(n) => n.to_string()
        @moondb.Int(n) => n.to_string()
        @moondb.Double(d) => d.to_string()
        @moondb.Bool(b) => if b { "1" } else { "0" }
      }
  }
}

///|
async fn select_cell(
  repo : @repo.MysqlRepository,
  sql : String,
  params : Array[@moondb.Value],
  col : String
) -> String raise {
  let conn = repo.open_raw()
  let rows = @repo.q(conn, sql, params)
  @repo.close_conn(conn)
  if rows.is_empty() {
    return "<无行>"
  }
  cell(rows[0], col)
}

///|
async fn select_i64(
  repo : @repo.MysqlRepository,
  sql : String,
  params : Array[@moondb.Value],
  col : String
) -> Int64 raise {
  let conn = repo.open_raw()
  let rows = @repo.q(conn, sql, params)
  @repo.close_conn(conn)
  if rows.is_empty() {
    return -1L
  }
  @repo.row_i64(rows[0], col)
}

///|
/// 实例/任务行单列读回（列名只取本文件字面量，非外部输入）
async fn inst_cell(repo : @repo.MysqlRepository, iid : Int64, col : String) -> String raise {
  select_cell(repo, "SELECT \{col} FROM wf_process_instance WHERE id = ?", [@moondb.Int64(iid)], col)
}

///|
async fn task_cell(repo : @repo.MysqlRepository, tid : Int64, col : String) -> String raise {
  select_cell(repo, "SELECT \{col} FROM wf_process_task WHERE id = ?", [@moondb.Int64(tid)], col)
}

///|
async fn set_sql(repo : @repo.MysqlRepository, sql : String, params : Array[@moondb.Value]) -> Unit raise {
  let conn = repo.open_raw()
  let _ = @repo.x(conn, sql, params)
  @repo.close_conn(conn)
}

///|
async fn doing_task_id(repo : @repo.MysqlRepository, iid : Int64, name : String) -> Int64 raise {
  select_i64(
    repo,
    "SELECT id FROM wf_process_task WHERE process_instance_id = ? AND task_name = ?",
    [@moondb.Int64(iid), @moondb.Text(name)],
    "id",
  )
}

///|
/// 参与者集合等价断言（SQL 侧 find_task_actors 没有 ORDER BY，插入序不是契约，
/// 所以按集合比，失败时把两侧实际值都打出来）
fn check_actors(actual : Array[String], expected : Array[String], label : String) -> Unit {
  let mut ok = actual.length() == expected.length()
  for e in expected {
    if !actual.contains(e) {
      ok = false
    }
  }
  if ok {
    println("  PASS \{label}")
  } else {
    let pipe = "|"
    let got = actual.join(pipe)
    let want = expected.join(pipe)
    println("  FAIL \{label}")
    println("       实际=<\{got}> 期望集合=<\{want}>")
    abort("T1-F assertion failed: \{label}")
  }
}

// ── 信封 / 变量 / 分页助手 ──

///|
/// action 入参（一律字符串，与 demo HTTP 载荷同形）
fn fa(entries : Array[(String, String)]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for e in entries {
    let (k, v) = e
    m[k] = @json.string_of(v)
  }
  m
}

///|
fn env_code(env : Json) -> Int64 {
  @json.get_i64(env, "code").unwrap_or(-1L)
}

///|
fn env_msg(env : Json) -> String {
  @json.get_str(env, "msg").unwrap_or("<无 msg 键>")
}

///|
fn env_data(env : Json) -> Json {
  @json.get(env, "data").unwrap_or(@json.null_json())
}

///|
fn iid_of(env : Json) -> Int64 {
  let s = @json.get_str(env_data(env), "processInstanceId").unwrap_or("0")
  match (try? @string.parse_int64(s)) {
    Ok(v) => v
    Err(_) => abort("非法实例 id 出口值: \{s}")
  }
}

///|
fn rows_of(data : Json) -> Array[Json] {
  match data.value("rows") {
    Some(Json::Array(a)) => a
    _ => []
  }
}

///|
fn page_has(data : Json, iid : Int64) -> Bool {
  let mut hit = false
  for r in rows_of(data) {
    let rid = match r.value("processInstanceId") {
      Some(v) => @json.as_str(v).unwrap_or("")
      None => ""
    }
    if rid == iid.to_string() {
      hit = true
    }
  }
  hit
}

///|
async fn todo_of(
  facade : @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository],
  operator : String
) -> Json raise {
  env_data(
    facade.flow("processTask/todoList", fa([("operator", operator), ("pageNum", "1"), ("pageSize", "50")])),
  )
}

///|
async fn done_of(
  facade : @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository],
  operator : String
) -> Json raise {
  env_data(
    facade.flow("processTask/doneList", fa([("operator", operator), ("pageNum", "1"), ("pageSize", "50")])),
  )
}

///|
fn transfer_args(tid : Int64, operator : String, from : String, to : String, reason : String) -> Map[String, Json] {
  if reason == "<none>" {
    fa([
      ("processTaskId", tid.to_string()),
      ("operator", operator),
      ("fromActor", from),
      ("toActor", to),
    ])
  } else {
    fa([
      ("processTaskId", tid.to_string()),
      ("operator", operator),
      ("fromActor", from),
      ("toActor", to),
      ("reason", reason),
    ])
  }
}

///|
/// 任务变量读回（从仓储读回的任务上取，即库里 variable 列的水合结果）
fn var_field(task : @model.ProcessTask, key : String) -> String {
  match task.variables.get(key) {
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => s
        None => @json.stringify(v)
      }
    None => "<missing>"
  }
}

///|
fn history_of(task : @model.ProcessTask) -> Array[Json] {
  match task.variables.get("tf_transferHistory") {
    Some(Json::Array(items)) => items
    _ => []
  }
}

///|
fn hop_field(hop : Json, key : String) -> String {
  match hop.value(key) {
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => s
        None => @json.stringify(v)
      }
    None => "<missing>"
  }
}

///|
/// T1-F114：门面 withdraw 真机对拍——撤回人必须**落进库里的 update_user 列**。
/// 哨兵值先行：撤回没真写 SQL 就还是哨兵（本栈独有坑：UPDATE 语句历史上没有这一列）。
/// 三条归属判据、任务态 30 非 99、已完成(20) 行不改写、整单撤回，全部读库验。
async fn t1_f114_withdraw() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990601L, "t1-f114", WT_FLOW)
  let facade = make_facade(repo, 990610L)
  let started = facade.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990601"), ("operator", "f114-applicant")]),
  )
  check(env_code(started) == 0L, "F114 发起 code=0")
  let iid = iid_of(started)
  let tid = doing_task_id(repo, iid, "task1")
  check(tid >= 990000L && tid < 1000000L, "F114 进行中任务 id 落 9xxxxx 段")
  // 哨兵：撤回若没真写进 SQL，读回来还是这两个值
  set_sql(repo, "UPDATE wf_process_instance SET update_user='f114-sentinel' WHERE id = ?", [@moondb.Int64(iid)])
  set_sql(
    repo,
    "UPDATE wf_process_task SET update_user='f114-done-sentinel' WHERE process_instance_id = ? AND task_name = 'apply'",
    [@moondb.Int64(iid)],
  )
  // 负向 A：缺 operator → 99999999 + msg 逐字，且库里零变化
  let e_missing = facade.flow("processInstance/withdraw", fa([("id", iid.to_string())]))
  check(env_code(e_missing) == 99999999L, "F114 缺 operator → 99999999")
  check_eq(env_msg(e_missing), "operator 必填", "F114 缺 operator msg 逐字（严禁回落 user1）")
  // 负向 B：无关第三人（非发起人 / 不在 SQL 参与者表 / 非 auto+admin）
  let e_third = facade.flow("processInstance/withdraw", fa([("id", iid.to_string()), ("operator", "f114-intruder")]))
  check_eq(env_msg(e_third), "无权限撤回该流程实例", "F114 第三人 → msg 逐字")
  check(inst_cell(repo, iid, "state") == "10", "F114 鉴权失败后库里 state 仍 10（撤回未发生）")
  check(inst_cell(repo, iid, "update_user") == "f114-sentinel", "F114 鉴权失败后库里 update_user 未被改写")
  check(
    select_i64(
      repo,
      "SELECT COUNT(*) AS c FROM wf_process_task WHERE process_instance_id = ? AND task_state = 30",
      [@moondb.Int64(iid)],
      "c",
    ) == 0L,
    "F114 鉴权失败后没有任何任务被撤",
  )
  // 正向：判据 2——leader 不是发起人，但**在 SQL 参与者表里** → 撤的是整单
  let ok = facade.flow("processInstance/withdraw", fa([("id", iid.to_string()), ("operator", "leader")]))
  check(env_code(ok) == 0L, "F114 进行中任务参与者撤整单成功")
  check(env_data(ok) is Json::Null, "F114 data → null")
  check(inst_cell(repo, iid, "state") == "30", "F114 库里实例 state=30")
  check(
    inst_cell(repo, iid, "update_user") == "leader",
    "F114 库里 instance.update_user = 真实撤回人（哨兵被改写 = 该列真在 UPDATE 语句里）",
  )
  check(task_cell(repo, tid, "task_state") == "30", "F114 库里被撤任务 task_state=30（不是 99）")
  check(task_cell(repo, tid, "update_user") == "leader", "F114 库里被撤任务 update_user = 真实撤回人")
  // 已完成(20) 行不被撤回改写：state 与审计列都保持哨兵
  let done_tid = doing_task_id(repo, iid, "apply")
  check(task_cell(repo, done_tid, "task_state") == "20", "F114 已完成任务行 state 仍 20")
  check(
    task_cell(repo, done_tid, "update_user") == "f114-done-sentinel",
    "F114 已完成任务行 update_user 未被撤回覆写",
  )
  // 出口读回：发起人视角 processInstance/page 行的 updateUser = 真实撤回人（序列化层）
  let page = env_data(
    facade.flow("processInstance/page", fa([("operator", "f114-applicant"), ("pageNum", "1"), ("pageSize", "10")])),
  )
  let mut page_uu = "<none>"
  for r in rows_of(page) {
    if @json.get_str(r, "id").unwrap_or("") == iid.to_string() {
      page_uu = @json.get_str(r, "updateUser").unwrap_or("<null>")
    }
  }
  check(page_uu == "leader", "F114 出口 updateUser = 真实撤回人")
  // 判据 3：flow.admin / flow.auto 与发起人、参与者身份无关（另一单）
  save_define_9x(repo, 990602L, "t1-f114b", WT_FLOW)
  let facade2 = make_facade(repo, 990650L)
  let started2 = facade2.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990602"), ("operator", "f114b-applicant")]),
  )
  let iid2 = iid_of(started2)
  let adm = facade2.flow("processInstance/withdraw", fa([("id", iid2.to_string()), ("operator", "flow.admin")]))
  check(env_code(adm) == 0L, "F114 flow.admin 撤回归放行")
  check(inst_cell(repo, iid2, "update_user") == "flow.admin", "F114 flow.admin 撤回人落库")
  let started3 = facade2.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990602"), ("operator", "f114c-applicant")]),
  )
  let iid3 = iid_of(started3)
  let auto_ = facade2.flow("processInstance/withdraw", fa([("id", iid3.to_string()), ("operator", "FLOW.AUTO")]))
  check(env_code(auto_) == 0L, "F114 flow.auto 大小写不敏感放行（同 is_allowed 约定）")
  check(inst_cell(repo, iid3, "update_user") == "FLOW.AUTO", "F114 FLOW.AUTO 撤回人原样落库")
  clean_9x(repo)
}

///|
/// T1-F115：门面 transfer 真机对拍——摘/加参与者、三件留痕、账本 time 格式全以**库里的列**为准。
/// 红线单列钉住"转办不写 operator 列"，并用办结后的对照证伪"这列从来不写"的假绿；
/// 最后核 doneList：被摘走的人不得凭空多出他没办过的单（Node 实测踩点）。
async fn t1_f115_transfer() -> Unit raise {
  @model.set_clock(Some(fn() { "2026-09-21 08:20:54" }))
  defer { @model.set_clock(None) }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990701L, "t1-f115", WT_FLOW)
  let facade = make_facade(repo, 990710L)
  let started = facade.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990701"), ("operator", "f115-applicant")]),
  )
  check(env_code(started) == 0L, "F115 发起 code=0")
  let iid = iid_of(started)
  let tid = doing_task_id(repo, iid, "task1")
  // 转办前该列本就无值（既有不变量）——后面两次对照的基准
  check(task_cell(repo, tid, "operator") == "<NULL>", "F115 转办前 operator 列无值")
  // 负向（SQL 参与者表口径 + 必填三项 msg 逐字）
  let e_ghost = facade.flow(
    "processTask/transfer",
    transfer_args(tid, "flow.admin", "f115-ghost", "f115-lisi", "<none>"),
  )
  check_eq(env_msg(e_ghost), "原办理人不是该任务参与人", "F115 fromActor 非参与者 → msg 逐字")
  let e_no_op = facade.flow(
    "processTask/transfer",
    fa([("processTaskId", tid.to_string()), ("fromActor", "leader"), ("toActor", "f115-lisi")]),
  )
  check_eq(env_msg(e_no_op), "operator 必填", "F115 缺 operator → msg 逐字")
  let e_no_to = facade.flow(
    "processTask/transfer",
    fa([("processTaskId", tid.to_string()), ("operator", "leader"), ("fromActor", "leader")]),
  )
  check_eq(env_msg(e_no_to), "toActor 必填", "F115 缺 toActor → msg 逐字")
  let e_perm = facade.flow(
    "processTask/transfer",
    transfer_args(tid, "f115-x", "leader", "f115-lisi", "<none>"),
  )
  check_eq(env_msg(e_perm), "无权限转办该任务", "F115 operator != fromActor 且非 auto/admin → msg 逐字")
  // 先加签一人，把任务做成"多参与人"——既给下面的去重负向一个真实场景，
  // 也给契约语义 1（只摘 fromActor 一行、其余成员不动）一个 SQL 侧钉
  let sur = facade.flow(
    "processTask/addCandidate",
    fa([("processTaskId", tid.to_string()), ("actorIds", "f115-extra")]),
  )
  check(env_code(sur) == 0L, "F115 加签 code=0（构造多参与人场景）")
  check_actors(repo.find_task_actors(tid), ["f115-extra", "leader"], "F115 加签=去重追加，原人保留")
  // 首跳 leader → f115-lisi
  let tr1 = facade.flow("processTask/transfer", transfer_args(tid, "leader", "leader", "f115-lisi", "出差一周"))
  check(env_code(tr1) == 0L, "F115 首跳转办 code=0")
  check_actors(
    repo.find_task_actors(tid),
    ["f115-extra", "f115-lisi"],
    "F115 只摘 fromActor 一行、其余参与者不动（契约语义 1）",
  )
  check(task_cell(repo, tid, "operator") == "<NULL>", "F115 红线：转办未覆写任务 operator 列")
  check(task_cell(repo, tid, "task_state") == "10", "F115 沿用同一 taskId 且仍进行中（不新建任务）")
  // 三件留痕活过 SQL JSON 往返（读回的是库里的 variable 列）
  let back = repo.find_task_by_id(tid).unwrap()
  check(var_field(back, "submitType") == "7", "F115 读回 submitType=7 槽位")
  check(var_field(back, "tf_transferTo") == "f115-lisi", "F115 便捷键 tf_transferTo")
  check(var_field(back, "tf_transferReason") == "出差一周", "F115 便捷键 tf_transferReason")
  check(
    var_field(back, "tf_approvalComment") == "leader 转办给 f115-lisi（出差一周）",
    "F115 末跳可读文案 tf_approvalComment（前端既有读取位）",
  )
  let h1 = history_of(back)
  check(h1.length() == 1, "F115 读回账本 1 条")
  check(hop_field(h1[0], "submitType") == "7", "F115 账本六键 submitType")
  check(hop_field(h1[0], "fromActor") == "leader", "F115 账本六键 fromActor")
  check(hop_field(h1[0], "toActor") == "f115-lisi", "F115 账本六键 toActor")
  check(hop_field(h1[0], "reason") == "出差一周", "F115 账本六键 reason")
  check(hop_field(h1[0], "time") == "2026-09-21 08:20:54", "F115 账本 time=yyyy-MM-dd HH:mm:ss 跨栈同形")
  check(hop_field(h1[0], "operator") == "leader", "F115 账本六键 operator")
  check(task_cell(repo, tid, "update_user") == "leader", "F115 库里任务 update_user = 转办操作人")
  check(
    task_cell(repo, tid, "variable").contains("tf_transferHistory"),
    "F115 库里 variable 列文本即含账本（不靠副本）",
  )
  // 去重负向：toActor 已是参与者（刚落库的 f115-lisi）；且失败路径零副作用
  let e_dup = facade.flow("processTask/transfer", transfer_args(tid, "f115-extra", "f115-extra", "f115-lisi", "<none>"))
  check_eq(env_msg(e_dup), "目标人已是该任务参与人", "F115 去重 → msg 逐字（读的是 SQL 参与者表）")
  check_actors(repo.find_task_actors(tid), ["f115-extra", "f115-lisi"], "F115 去重失败后参与者表未被改写")
  // 第二跳 append：首跳必须仍在库里
  let tr2 = facade.flow("processTask/transfer", transfer_args(tid, "f115-lisi", "f115-lisi", "f115-wangwu", "<none>"))
  check(env_code(tr2) == 0L, "F115 第二跳转办 code=0")
  let after2 = repo.find_task_by_id(tid).unwrap()
  let h2 = history_of(after2)
  check(h2.length() == 2, "F115 第二跳后库里账本 2 条（只追加不覆盖）")
  check(hop_field(h2[0], "toActor") == "f115-lisi", "F115 首跳未被第二跳覆盖")
  check(hop_field(h2[1], "toActor") == "f115-wangwu", "F115 末跳为新跳")
  check(hop_field(h2[1], "reason") == "", "F115 reason 无值写 \"\" 不写 null")
  check(var_field(after2, "tf_approvalComment") == "f115-lisi 转办给 f115-wangwu", "F115 多跳时文案只留末跳")
  // 待办挪位走 SQL actor 表 JOIN：leader/lisi 都无，wangwu 有
  check(!page_has(todo_of(facade, "leader"), iid), "F115 被摘走者待办消失（SQL JOIN）")
  check(!page_has(todo_of(facade, "f115-lisi"), iid), "F115 中间人待办已挪走")
  check(page_has(todo_of(facade, "f115-wangwu"), iid), "F115 接手人拿到待办（SQL JOIN）")
  check(page_has(todo_of(facade, "f115-extra"), iid), "F115 两跳之后加签人待办原样还在（没被连带摘走）")
  // 前置态负向见本函数末尾（该行办结后 state=20 再转办）
  // 末跳人办结：本次提交压过转办槽位，账本仍在（合并序在 SQL 仓同样成立）
  let exe = facade.flow("processTask/execute", fa([("processTaskId", tid.to_string()), ("operator", "f115-wangwu"), ("submitType", "1")]))
  check(env_code(exe) == 0L, "F115 接手人办结 code=0")
  let done = repo.find_task_by_id(tid).unwrap()
  check(done.task_state == 20, "F115 库里任务 state=20")
  check(var_field(done, "submitType") == "1", "F115 办结后本次提交压过转办 7（反噬方向）")
  check(history_of(done).length() == 2, "F115 办结后库里账本仍在（变量合并而非整体替换）")
  check(
    task_cell(repo, tid, "operator") == "f115-wangwu",
    "F115 对照：办结路径确实写 operator 列（前面的 <NULL> 不是『这列从来不写』的假绿）",
  )
  check(page_has(done_of(facade, "f115-wangwu"), iid), "F115 真实办理人 doneList 有这一单")
  check(!page_has(done_of(facade, "leader"), iid), "F115 被摘走者 doneList 不凭空多单（Node 实测踩点）")
  check(inst_cell(repo, iid, "state") == "20", "F115 实例办结 state=20")
  // 办结后再转办 → 前置态负向（库里该行已 state=20）
  let e_state = facade.flow(
    "processTask/transfer",
    transfer_args(tid, "f115-wangwu", "f115-wangwu", "f115-zhangsan", "<none>"),
  )
  check_eq(env_msg(e_state), "任务非进行中，不可转办", "F115 非进行中 → msg 逐字")
  clean_9x(repo)
}

///|
/// 委托自动生效用流：发起（apply）→ task1(f116-leader) → task2(f116-zhang) → end
/// apply 由 startAndExecute 自动办结 ⇒ task1 是"发起路径产的单"、task2 是"推进路径产的单"
/// ⚠️ 节点 assignee 必须与台账 operator **同名**（f116- 前缀）：委托是按 actor 查台账，
/// 名字对不上就是零命中，条款 2 的参与者断言会退化成"只有原人"的假绿（本行踩过，已钉死）。
const SG_FLOW : String =
  $|{"name": "t1-f116", "displayName": "T1F委托", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "task1", "type": "snaker:task", "text": {"value": "一审"},
  $|   "properties": {"assignee": "f116-leader", "taskType": 0, "performType": 0}},
  $|  {"id": "task2", "type": "snaker:task", "text": {"value": "二审"},
  $|   "properties": {"assignee": "f116-zhang", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|  {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "task2"},
  $|  {"id": "e4", "sourceNodeId": "task2", "targetNodeId": "end"}
  $|]}

///|
/// issues/117 红线用例专用流（不复用 SG_FLOW：那条流的 assignee 带 f116- 前缀，
/// 而转办的 fromActor 判据读参与者表——非参与人直接 raise "原办理人不是该任务参与人"，
/// 名字对不上时这条红线压根跑不到断言（与另七栈同尺子的用例必须真转办成功）。
const F117_FLOW : String =
  $|{"name": "t1-f117", "displayName": "T1F已办", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "task1", "type": "snaker:task", "text": {"value": "审批"},
  $|   "properties": {"assignee": "f117b-leader", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|  {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $|]}

///|
/// ext 仓储也是真机 MySQL（委托台账真落 wf_process_surrogate）；auto_apply 即条款 3 开关
fn make_facade_ext(
  repo : @repo.MysqlRepository,
  start : Int64,
  auto_apply~ : Bool = true
) -> @facade.Facade[@repo.MysqlRepository, @repo.MysqlRepository] {
  let counter : Ref[Int64] = Ref(start)
  let ctx = @spi.Ctx::new(repo, repo)
  let ctx2 = ctx.with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  })
  @facade.Facade::make(ctx2.with_surrogate_auto_apply(auto_apply))
}

///|
async fn sg_todo(
  facade : @facade.Facade[@repo.MysqlRepository, @repo.MysqlRepository],
  operator : String
) -> Json raise {
  env_data(
    facade.flow("processTask/todoList", fa([("operator", operator), ("pageNum", "1"), ("pageSize", "50")])),
  )
}

///|
async fn sg_done(
  facade : @facade.Facade[@repo.MysqlRepository, @repo.MysqlRepository],
  operator : String
) -> Json raise {
  env_data(
    facade.flow("processTask/doneList", fa([("operator", operator), ("pageNum", "1"), ("pageSize", "50")])),
  )
}

///|
/// 委托台账写入走门面 action（连 processSurrogate/save 的参数口径一起验）
async fn sg_save(
  facade : @facade.Facade[@repo.MysqlRepository, @repo.MysqlRepository],
  operator : String,
  agent : String,
  process_name : String,
  extra : Array[(String, String)]
) -> Unit raise {
  let entries : Array[(String, String)] = [
    ("operator", operator),
    ("surrogate", agent),
    ("processName", process_name),
    ("enabled", "1"),
  ]
  for e in extra {
    let _ = entries.push(e)
  }
  let env = facade.flow("processSurrogate/save", fa(entries))
  check(env_code(env) == 0L, "\{operator}→\{agent} 委托台账保存 code=0")
}

///|
/// 委托台账自清理（R6 补漏）：`processSurrogate/save` 的 id 是**雪花**，不在 clean_9x 的
/// 9xxxxx 段里 ⇒ 崩一次就在共享库长出一批无人认领的委托行，下一轮（甚至别的栈的同名 actor）
/// 被反向污染。按 f116- 前缀单独扫，测前测后各一次，幂等。
async fn clean_sg_ledger(repo : @repo.MysqlRepository) -> Unit raise {
  set_sql(
    repo,
    "DELETE FROM wf_process_surrogate WHERE operator LIKE 'f116-%' OR surrogate LIKE 'f116-%'",
    [],
  )
}

///|
/// 参与者行直读库（不走仓储水合）——条款 2⚠️ 要钉的就是 wf_process_task_actor 里的行
async fn actor_rows(repo : @repo.MysqlRepository, tid : Int64) -> Array[String] raise {
  let conn = repo.open_raw()
  let rows = @repo.q(
    conn,
    "SELECT actor_id FROM wf_process_task_actor WHERE process_task_id = ? ORDER BY actor_id",
    [@moondb.Int64(tid)],
  )
  @repo.close_conn(conn)
  let out : Array[String] = []
  for r in rows {
    let _ = out.push(cell(r, "actor_id"))
  }
  out
}

///|
/// T1-F116：委托代理自动生效（门面 + 真机 MySQL）——条款 1/2⚠️/3/4/5①/条款 1.1
async fn t1_f116_surrogate_auto_apply() -> Unit raise {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  clean_sg_ledger(repo)
  save_define_9x(repo, 990801L, "t1-f116", SG_FLOW)
  let facade = make_facade_ext(repo, 990810L)
  // 授权人 f116-leader / f116-zhang 各自委托给不同人（与 SG_FLOW 的 assignee 同名）；
  // 流程名取**模型 name**（条款 1.1）
  let _ = sg_save(facade, "f116-leader", "f116-li", "t1-f116", [])
  let _ = sg_save(facade, "f116-zhang", "f116-li2", "t1-f116", [])
  let started = facade.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990801"), ("operator", "f116-applicant")]),
  )
  check(env_code(started) == 0L, "F116 发起 code=0")
  let iid = iid_of(started)
  // ① 发起路径产的 task1：参与者行真落库 = 授权人 + 代理人
  let t1 = doing_task_id(repo, iid, "task1")
  check_actors(actor_rows(repo, t1), ["f116-leader", "f116-li"], "F116 条款2⚠️：代理人真落 wf_process_task_actor（非事后补写）")
  check(page_has(sg_todo(facade, "f116-li"), iid), "F116 代理人 todoList 出现该单（用户视角闭环）")
  check(page_has(sg_todo(facade, "f116-leader"), iid), "F116 授权人 todoList 仍在（任一可办）")
  // ② 推进路径产的 task2（只挂发起一处的实现会在这里漏）
  let exe = facade.flow(
    "processTask/execute",
    fa([("processTaskId", t1.to_string()), ("operator", "f116-leader"), ("submitType", "1")]),
  )
  check(env_code(exe) == 0L, "F116 leader 办结 task1 code=0")
  let t2 = doing_task_id(repo, iid, "task2")
  check_actors(actor_rows(repo, t2), ["f116-li2", "f116-zhang"], "F116 条款1：推进出的新单同样并入代理人")
  check(task_cell(repo, t2, "task_state") == "10", "F116 推进新单仍在进行中")
  // ③ 跳转路径：task2 跳回 task1（重建的也是新单）
  let jm = facade.flow(
    "processTask/execute",
    fa([
      ("processTaskId", t2.to_string()),
      ("operator", "f116-zhang"),
      ("submitType", "4"),
      ("taskName", "task1"),
    ]),
  )
  check(env_code(jm) == 0L, "F116 跳转 code=0")
  let back_ids : Array[Int64] = []
  let conn = repo.open_raw()
  let rows = @repo.q(
    conn,
    "SELECT id FROM wf_process_task WHERE process_instance_id = ? AND task_name = 'task1' AND task_state = 10",
    [@moondb.Int64(iid)],
  )
  @repo.close_conn(conn)
  for r in rows {
    let _ = back_ids.push(@repo.row_i64(r, "id"))
  }
  check(back_ids.length() == 1, "F116 跳转后 task1 重建一行（实际=\{back_ids.length()}）")
  check_actors(
    actor_rows(repo, back_ids[0]),
    ["f116-leader", "f116-li"],
    "F116 条款1：跳转路径同样并入代理人",
  )
  // ④ 显式关闭：同一份台账，新单不再并入代理人（条款 3）
  let off = make_facade_ext(repo, 990890L, auto_apply=false)
  let started2 = off.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990801"), ("operator", "f116-applicant")]),
  )
  check(env_code(started2) == 0L, "F116 关闭后发起照常 code=0")
  let iid2 = iid_of(started2)
  let t1b = doing_task_id(repo, iid2, "task1")
  check_actors(actor_rows(repo, t1b), ["f116-leader"], "F116 条款3：关闭后回到仅台账（不并入代理人）")
  check(env_code(off.flow("processSurrogate/page", fa([("pageNum", "1"), ("pageSize", "50")]))) == 0L, "F116 关闭后台账 CRUD 不变")
  // ⑤ 未配置扩展仓储（NoExtRepository）→ 静默跳过、不打断建单（条款 4）
  let plain = make_facade(repo, 990860L)
  let started3 = plain.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990801"), ("operator", "f116-applicant")]),
  )
  check(env_code(started3) == 0L, "F116 条款4：无扩展仓储也能发起（不报错）")
  let iid3 = iid_of(started3)
  let conn3 = repo.open_raw()
  let rows3 = @repo.q(
    conn3,
    "SELECT actor_id FROM wf_process_task_actor WHERE process_task_id = ?",
    [@moondb.Int64(doing_task_id(repo, iid3, "task1"))],
  )
  @repo.close_conn(conn3)
  check(rows3.length() == 1, "F116 条款4：无扩展仓储时参与者原样（实际=\{rows3.length()}）")
  // ⑥ 窗外 / 停用不生效（SQL 侧判据，与内存仓同答案见 T1-I116）
  let _ = sg_save(facade, "f116-off", "f116-li3", "t1-f116", [("enabled", "0")])
  let _ = sg_save(facade, "f116-past", "f116-li4", "t1-f116", [("endTime", "2026-09-20 23:59:59")])
  check(
    repo.get_surrogate("f116-off", "t1-f116", "2026-09-21 10:00:00") is None,
    "F116 条款5④：enabled=0 查不到",
  )
  check(
    repo.get_surrogate("f116-past", "t1-f116", "2026-09-21 10:00:00") is None,
    "F116 条款5②：窗外查不到",
  )
  clean_sg_ledger(repo)
  clean_9x(repo)
}

///|
/// T1-F117：我已办状态集合 = task_state <> 10 + 空 operator 空页 + 转办→撤回不冒单（门面级真机）
async fn t1_f117_done_list() -> Unit raise {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990901L, "t1-f117", F117_FLOW)
  let conn = repo.open_raw()
  let _ = @repo.x(
    conn,
    "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (990900, 990901, 10, 'f117-applicant', '{}', NOW(), 'f117')",
    [],
  )
  // 四个"离开了待办办理"的态 + 一个 DOING；办理人列同一人
  let states : Array[Int] = [20, 30, 40, 99, 10]
  for i in 0..<states.length() {
    let st = states[i]
    let op = if st == 10 { None } else { Some("f117-leader") }
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_type, perform_type, task_state, operator, variable, create_time, create_user) VALUES (?, 990900, ?, ?, 0, 0, ?, ?, '{}', NOW(), 'f117-applicant')",
      [
        @moondb.Int64(990911L + i.to_int64()),
        @moondb.Text("n\{st}"),
        @moondb.Text("节点\{st}"),
        @moondb.Int(st),
        opt_v_param(op),
      ],
    )
  }
  @repo.close_conn(conn)
  let facade = make_facade_ext(repo, 990950L)
  // 正向：20/30/40/99 四条都在已办，DOING 不在
  let data = sg_done(facade, "f117-leader")
  check(rc_of(data) == 4L, "F117 已办返回 4 条（20/30/40/99，实际=\{rc_of(data)}）")
  for want in ["n20", "n30", "n40", "n99"] {
    let mut hit = false
    for r in rows_of(data) {
      if @json.get_str(r, "taskName").unwrap_or("") == want {
        hit = true
      }
    }
    check(hit, "F117 已办含状态行 \{want}")
  }
  let mut has_doing = false
  for r in rows_of(data) {
    if @json.get_str(r, "taskName").unwrap_or("") == "n10" {
      has_doing = true
    }
  }
  check(!has_doing, "F117 DOING(10) 不进已办")
  // 判据生效自证：裸 SQL 确实有 4 行落在 <>10 候选集里（不是"=20 蓙对"）
  check_eq(
    select_cell(
      repo,
      "SELECT COUNT(*) AS cnt FROM wf_process_task WHERE process_instance_id = 990900 AND task_state <> 10",
      [],
      "cnt",
    ),
    "4",
    "F117 裸 SQL 候选集=4（证 <>10 判据真在筛）",
  )
  // 负向：空 operator → 空页（不得返回全库）
  let blank = env_data(
    facade.flow("processTask/doneList", fa([("operator", ""), ("pageNum", "1"), ("pageSize", "50")])),
  )
  check(rc_of(blank) == 0L, "F117 operator='' → 空页（不得返回全库，实际=\{rc_of(blank)}）")
  // 负向：发起人（create_user）放行不得出现（契约 §2.5 点名禁止，Rust 那格违约）
  let creator = sg_done(facade, "f117-applicant")
  check(rc_of(creator) == 0L, "F117 create_user 不放行（实际=\{rc_of(creator)}）")
  // 回归红线（与另七栈同尺子，issues/114 §6.2）：转办→撤回后 fromActor 已办不冒单
  let started = facade.flow(
    "processInstance/startAndExecute",
    fa([("processDefineId", "990901"), ("operator", "f117b-applicant")]),
  )
  check(env_code(started) == 0L, "F117 红线用例发起 code=0")
  let iid = iid_of(started)
  let tid = doing_task_id(repo, iid, "task1")
  let tr = facade.flow(
    "processTask/transfer",
    fa([
      ("processTaskId", tid.to_string()),
      ("operator", "f117b-leader"),
      ("fromActor", "f117b-leader"),
      ("toActor", "f117b-lisi"),
    ]),
  )
  check(env_code(tr) == 0L, "F117 转办 code=0")
  let _ = facade.flow(
    "processInstance/withdraw",
    fa([("id", iid.to_string()), ("operator", "f117b-applicant")]),
  )
  check_eq(task_cell(repo, tid, "task_state"), "30", "F117 撤回后库里任务态 30")
  check_eq(task_cell(repo, tid, "operator"), "<NULL>", "F117 红线：转办未覆写办理人列")
  // 关键：这一行现在**确实落在 <>10 候选集里**，挡住它的是办理人列，不再是状态集合
  check_eq(
    select_cell(
      repo,
      "SELECT COUNT(*) AS cnt FROM wf_process_task WHERE id = ? AND task_state <> 10",
      [@moondb.Int64(tid)],
      "cnt",
    ),
    "1",
    "F117 该撤回行已进入 <>10 候选集（本用例真有牙，不是被 =20 掩掉）",
  )
  check(!page_has(sg_done(facade, "f117b-leader"), iid), "F117 被摘走者已办不冒单（转办→撤回）")
  check(!page_has(sg_done(facade, "f117b-lisi"), iid), "F117 接手未办者已办也不冒单")
  clean_9x(repo)
}

///|
/// 分页出口 recordCount（验收取数字形态，D-M3-3 出口 camel）
fn rc_of(data : Json) -> Int64 {
  @json.get_i64(data, "recordCount").unwrap_or(-1L)
}

///|
fn opt_v_param(v : String?) -> @moondb.Value {
  match v {
    Some(s) => @moondb.Text(s)
    None => @moondb.Null
  }
}

async fn run() -> Unit raise {
  if skip_mysql() {
    println("SKIP_MYSQL=1 → T1-F skipped (开发机口径；发版机连不上=fail)")
    return
  }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  println("T1-F114 facade withdraw → 库里 update_user/state 真机对拍...")
  t1_f114_withdraw()
  println("T1-F115 facade transfer → 参与者/三件留痕/红线列真机对拍...")
  t1_f115_transfer()
  println("T1-F116 facade 委托自动生效 → 参与者行真机对拍...")
  t1_f116_surrogate_auto_apply()
  println("T1-F117 facade 已办判据 <>10 + 空 operator 空页 + 转办撤回红线...")
  t1_f117_done_list()
  println("T1-F ALL PASS (wasm → 真机 MySQL)")
}

///|
fn main {
  @async.run_async_main(run)
}
