// T1 MySQL 冒烟可执行（方案 §5 M2 / §6.1 T1）——`moon run --target wasm repository-mysql/smoke`
// 说明：moon test 的 Windows socket 读路径挂死（2026-09-05 实测，见 docs/decisions-log.md D-M2-2），
// T1 走 moon run 可执行通道；断言失败 abort → 非零退出（R6：连不上=fail，不是 skip）。
// SKIP_MYSQL=1 开发机跳过。红线 R6：9xxxxx 段 + 测前测后自清理 + 凭据只走 JEFFLOW_DB_* env。

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
    abort("T1 assertion failed: \{label}")
  }
}

///|
/// 9xxxxx 段自清理（只动 jeeflow 库 wf_* 表）
async fn clean_9x(repo : @repo.MysqlRepository) -> Unit raise {
  // 先按外键清子行：add_task_actor/抄送行的 id 是雪花（不在 9xxxxx 段），
  // 只有按 process_task_id/process_instance_id 反查才扫得到（issues/115 转办会新增这类行）。
  // 必须在下面按 id 段删主行**之前**做，否则子查询已经扫不到。
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
    "wf_process_design_his",
    "wf_process_design",
    "wf_process_surrogate",
  ]
  for t in tables {
    let conn = repo.open_raw()
    let _ = @repo.q(conn, "DELETE FROM \{t} WHERE id >= 990000 AND id < 1000000", [])
    @repo.close_conn(conn)
  }
  // 兜底：清理 operator/user9x 标记的历史残留（早前崩溃运行可能落雪花 id）
  let conn = repo.open_raw()
  let _ = @repo.q(
    conn,
    "DELETE FROM wf_process_task_actor WHERE process_task_id IN (SELECT id FROM wf_process_task WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE operator = 'user9x'))",
    [],
  )
  let _ = @repo.q(conn, "DELETE FROM wf_process_task WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE operator = 'user9x')", [])
  let _ = @repo.q(conn, "DELETE FROM wf_process_cc_instance WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE operator = 'user9x')", [])
  let _ = @repo.q(conn, "DELETE FROM wf_process_instance WHERE operator = 'user9x'", [])
  @repo.close_conn(conn)
}

///|
async fn save_define_9x(repo : @repo.MysqlRepository, id : Int64, name : String, content : String) -> Unit raise {
  let conn = repo.open_raw()
  let _ = @repo.x(
    conn,
    "INSERT INTO wf_process_define (id, name, display_name, type, state, content, version, create_time, create_user) VALUES (?, ?, ?, 'approval', 1, ?, 1, NOW(), 't1')",
    [@moondb.Int64(id), @moondb.Text(name), @moondb.Text(name), @moondb.Text(content)],
  )
  @repo.close_conn(conn)
}

///|
const SIMPLE_FLOW : String =
  $|{"name": "t1-simple", "displayName": "T1Simple", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"},
  $|   "properties": {"assignee": "applicant"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "end"}
  $|]}

///|
fn make_mysql_engine(repo : @repo.MysqlRepository) -> @engine.Engine[@repo.MysqlRepository, @spi.NoExtRepository] {
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  // 9xxxxx 段计数器：实例/任务 id 全落测试段（R6 可清理）
  let counter : Ref[Int64] = Ref(990100L)
  let ctx2 = ctx.with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  })
  @engine.Engine::make(ctx2)
}

///|
/// T1-M1：分页五键（C22）+ id DESC + operator 过滤
async fn t1_m1_page() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990001L, "t1-page", SIMPLE_FLOW)
  let conn = repo.open_raw()
  for i in 1..<3 {
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (?, 990001, 10, 'user9x', '{}', NOW(), 't1')",
      [@moondb.Int64(990010L + i.to_int64())],
    )
  }
  @repo.close_conn(conn)
  let query = @model.PageQuery::new(1L, 1L)
  query.set_operator(Some("user9x"))
  let page = repo.page_instances(query)
  check(page.page_num() == 1L, "pageNum=1")
  check(page.page_size() == 1L, "pageSize=1")
  check(page.record_count() == 2L, "recordCount=2")
  check(page.total_page() == 2L, "totalPage=2（五键数学）")
  check(page.rows().length() == 1, "rows 截断为 pageSize")
  check(page.rows()[0].id == 990012L, "ORDER BY id DESC 首行=最新")
  clean_9x(repo)
}

///|
/// T1-M2：hydrate 参与人/变量/DATETIME 归一 + 引擎全链落库
async fn t1_m2_hydrate() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990001L, "t1-hydrate", SIMPLE_FLOW)
  let engine = make_mysql_engine(repo)
  let args = @json.FlowData::new()
  args.insert_str("f_note", "你好-数据")
  let inst = engine.start_async(990001L, "user9x", args)
  check(inst.instance_id >= 990000L, "9xxxxx 段实例 id")
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  check(tasks.length() == 1, "发起后 1 个 DOING 任务")
  let task = tasks[0]
  check(task.actor_ids.contains("user9x"), "参与人水合（is_allowed 依赖）")
  check(task.is_allowed("user9x"), "处理人判定通过")
  match task.create_time {
    Some(t) => check(t.length() <= 19, "DATETIME 归一无毫秒尾巴（C7）")
    None => check(false, "create_time 应有值")
  }
  let _ = engine.execute_task_async(task.task_id, "user9x", @json.FlowData::new())
  let inst2 = repo.find_instance_by_id(inst.instance_id).unwrap()
  check(inst2.state == 20, "全链完成后实例 state=20")
  check(inst2.variables.get_str("autoGenTitle") is Some(_), "实例变量 JSON hydrate 回读")
  let done = repo.find_history_tasks(inst.instance_id)
  let mut all_finished = true
  for t in done {
    if t.task_state != 20 {
      all_finished = false
    }
  }
  check(all_finished, "任务落库 state=20 且 hydrate 正确")
  clean_9x(repo)
}

///|
/// T1-M3：m_ 三段式过滤真实走 SQL
async fn t1_m3_mparams() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990001L, "t1-like-target-xyz", SIMPLE_FLOW)
  save_define_9x(repo, 990002L, "unrelated", SIMPLE_FLOW)
  let query = @model.PageQuery::new(1L, 10L)
  let args : Map[String, Json] = Map([])
  args["m_LIKE_name"] = @json.string_of("t1-like-target")
  let filters = @query.parse_m_params(args)
  for f in filters {
    query.add_filter(f)
  }
  let page = repo.page_defines(query)
  check(page.record_count() == 1L, "m_LIKE_name 命中 1 条")
  check(page.rows()[0].name == "t1-like-target-xyz", "过滤值正确")
  clean_9x(repo)
}

///|
/// T1-M4：事务回滚无半完成实例（§6.2 语义级）
async fn t1_m4_tx_rollback() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  let tpl = @repo.MysqlTxTemplate::from_env()
  let outcome = try? tpl.execute_in_tx(fn() {
    let conn = @repo.current_tx_conn().unwrap()
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (990020, 990001, 10, 'user9x', '{}', NOW(), 't1')",
      [],
    )
    let _ = @repo.x(
      conn,
      "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_state, create_time, create_user) VALUES (990021, 990020, 'apply', 'A', 10, NOW(), 't1')",
      [],
    )
    raise @error.Business("boom-in-tx")
  })
  check(outcome is Err(_), "回调抛错外传")
  let conn = repo.open_raw()
  let inst_rows = @repo.q(conn, "SELECT COUNT(*) AS c FROM wf_process_instance WHERE id = 990020", [])
  let task_rows = @repo.q(conn, "SELECT COUNT(*) AS c FROM wf_process_task WHERE id = 990021", [])
  @repo.close_conn(conn)
  check(@repo.row_i64(inst_rows[0], "c") == 0L, "实例行回滚净")
  check(@repo.row_i64(task_rows[0], "c") == 0L, "任务行回滚净")
  clean_9x(repo)
}

///|
/// T1-M5：并发办理只一次成功（引擎读-改-写守卫，§6.2）
async fn t1_m5_idempotent() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990001L, "t1-idem", SIMPLE_FLOW)
  let engine = make_mysql_engine(repo)
  let inst = engine.start_async(990001L, "user9x", @json.FlowData::new())
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  check(tasks.length() == 1, "办理前 1 个 DOING")
  let first = try? engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
  check(first is Ok(_), "第一次办理成功")
  let second = try? engine.execute_task_async(tasks[0].task_id, "user9x", @json.FlowData::new())
  let mut code_ok = false
  match second {
    Ok(_) => code_ok = false
    Err(e) => code_ok = e.code() == @error.ERR_BUSINESS
  }
  check(code_ok, "第二次办理 99999999（任务已办理守卫）")
  clean_9x(repo)
}

///|
///|
/// T1-I110：SQL 仓 find_instance_by_id 水合任务 → detail 任务列表非空（issues/110）
/// 修复前：find_instance_by_id 只查 wf_process_instance 单表，tasks 硬编码 []，
/// 门面 processInstance/detail 的 tasks/activeTaskList 恒空（L2-12 门禁真根因）。
/// 对齐 Java findTasksByInstanceId / PHP PdoProcessRepository / C# issues/89 聚合水合。
/// 真实 MySQL：引擎发起 doing 实例（落 9903xx 段）→ 断言 find_instance_by_id 水合任务
/// 非空 + 带 actor_ids，且门面 detail 消费（遍历 inst.tasks 组 tasks/activeTaskList）非空。
async fn t1_i110_hydrate() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990301L, "t1-i110", SIMPLE_FLOW)
  // 独立 id 段 9903xx：实例/任务 id 落测试段（R6 可清理）
  let counter : Ref[Int64] = Ref(990301L)
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  let ctx2 = ctx.with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  })
  let engine = @engine.Engine::make(ctx2)
  let inst = engine.start_async(990301L, "user9x", @json.FlowData::new())
  check(inst.instance_id >= 990300L, "9xxxxx 段实例 id")

  // ① 仓储层：find_instance_by_id 水合任务 + actor_ids（修复前恒空）
  let loaded = repo.find_instance_by_id(inst.instance_id).unwrap()
  check(!loaded.tasks.is_empty(), "find_instance_by_id 水合任务非空")
  let mut actors_ok = true
  for t in loaded.tasks {
    if t.actor_ids.is_empty() {
      actors_ok = false
    }
  }
  check(actors_ok, "水合任务带参与者 actor_ids")

  // ② 门面 detail 消费口径：遍历 inst.tasks 组 tasks/activeTaskList
  let mut active_count = 0
  for t in loaded.tasks {
    if t.is_doing() {
      active_count += 1
    }
  }
  check(loaded.tasks.length() > 0, "detail tasks 非空")
  check(active_count > 0, "detail activeTaskList 非空")
  clean_9x(repo)
}

///|
/// NULL 安全单元格读取（<NULL> 与 "" 必须可分辨：审计列断言读的就是这一格）
fn cell(r : @moondb.Row, col : String) -> String {
  match r.by_name(col) {
    None => "<无此列>"
    Some(v) =>
      match v {
        @moondb.Null => "<NULL>"
        @moondb.Text(s) => s
        @moondb.Blob(_) => "<BLOB>"
        @moondb.Int64(n) => n.to_string()
        @moondb.Int(n) => n.to_string()
        @moondb.Double(d) => d.to_string()
        @moondb.Bool(b) => if b { "1" } else { "0" }
      }
  }
}

///|
/// 库里单列读回（不走仓储水合，直接 SELECT 列名——要钉的就是这一格）
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
/// T1-I114（仓储级）：update_instance / update_task 必须把 update_user **真写进 SQL**。
/// 缺陷本体（本栈独有）：两条 UPDATE 语句历史上只有 state/variable/update_time(+operator/
/// finish_time)，内存仓是整行替换所以门面级测试全绿也照不出来，SQL 仓审计列静默丢失
/// → 双仓答案不一致。末跳 `update_user=None → 库里 <NULL>` 是对照组，专门证伪
/// "这列从来没被写过"式的假绿。门面级（鉴权 + 三件留痕 + 出口）真机用例见
/// demo/cmd/t1_mysql。
async fn t1_i114_update_user_lands() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990401L, "t1-i114", SIMPLE_FLOW)
  let engine = make_mysql_engine(repo)
  let inst = engine.start_async(990401L, "user9x", @json.FlowData::new())
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  check(tasks.length() == 1, "I114 发起后 1 个进行中任务")
  let task = tasks[0]
  let iid_sql = "SELECT update_user FROM wf_process_instance WHERE id = ?"
  let tid_sql = "SELECT update_user FROM wf_process_task WHERE id = ?"
  // 只动审计列，走的就是被修的那两条 UPDATE 语句
  inst.update_user = Some("i114-revoker")
  repo.update_instance(inst)
  check(
    select_cell(repo, iid_sql, [@moondb.Int64(inst.instance_id)], "update_user") == "i114-revoker",
    "I114 库里 wf_process_instance.update_user 真被写入（列确在 UPDATE 语句里）",
  )
  task.update_user = Some("i114-revoker")
  repo.update_task(task)
  check(
    select_cell(repo, tid_sql, [@moondb.Int64(task.task_id)], "update_user") == "i114-revoker",
    "I114 库里 wf_process_task.update_user 真被写入",
  )
  // 对照组：None 必须落 NULL（否则前面的命中可能是"这列从没被写过 + 哨兵恰好同值"）
  inst.update_user = None
  repo.update_instance(inst)
  check(
    select_cell(repo, iid_sql, [@moondb.Int64(inst.instance_id)], "update_user") == "<NULL>",
    "I114 update_user=None 落库 NULL（对照，证伪假绿）",
  )
  clean_9x(repo)
}

///|
/// 库里单列读回（时间列版）。老 `cell()` 对 `@moondb.Blob` 回 "<BLOB>"——
/// MySQL 结果集把 `DATETIME(3)` 投成 Blob，而 I120 要比的正是那一串时间，
/// 故按库内 `value_to_text` 的同规则解码（旁挂新函数，不动既有 `cell()` 的三档标记语义）。
async fn select_cell_dt(
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
  match rows[0].by_name(col) {
    None => "<无此列>"
    Some(v) =>
      match v {
        @moondb.Null => "<NULL>"
        @moondb.Text(s) => s
        @moondb.Blob(b) => @utf8.decode_lossy(b[:])
        _ => "<非文本值>"
      }
  }
}

///|
/// DATETIME(3) 文本比较取前 19 位（列带 `.000` 尾巴时不影响判据；C7 同口径）
fn head19(s : String) -> String {
  if s.length() >= 19 { s.substring(start=0, end=19).to_string() } else { s }
}

///|
/// T1-I120（仓储级）：本栈六条写路径的时间列必须由**引擎钟**供给，SQL 侧不许有 `NOW()`。
///
/// 缺陷本体：`update_instance`/`update_task`/`add_task_actor`/`create_cc_instance`/
/// `update_design`/`update_surrogate` 历史上写 `update_time=NOW()` / `create_time=NOW()`，
/// 取的是**数据库会话时区**的墙钟；开发服务器 160 实测 `@@session.time_zone=+08:00`
/// （`NOW()` 比 `UTC_TIMESTAMP()` 晚 8 小时），而引擎写出的 `create_time`/`finish_time`
/// 走它自己那把钟（未注入时 UTC）⇒ 同一行两个基准差 8 小时。外溢到读侧的不是只有审计列：
/// `wf_process_cc_instance.create_time` 会被 `page_cc_instances` SELECT 回并投影给前端，
/// 「抄送我的」列表那一格用的就是 DB 那把钟。
///
/// 夹具设计：注入钟 = 真实 UTC − 12h ⇒ 「引擎钟(注入)」「真实 UTC」「DB +08:00」三方互不相同，
/// 库里读到哪一把当场可分辨；末跳摘掉注入再写一次作**对照组**，读回值必须换成真实 UTC
/// （≠ 注入串），用以证伪"这列根本没被写 / 被写成了常量"式的假绿。
async fn t1_i120_engine_clock_lands() -> Unit raise {
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990501L, "t1-i120", SIMPLE_FLOW)
  let injected = @model.format_unix_utc(@model.epoch_secs() - 43200L)
  @model.set_clock(Some(fn() { injected }))

  let engine = make_mysql_engine(repo)
  let inst = engine.start_async(990501L, "user9x", @json.FlowData::new())
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  check(tasks.length() == 1, "I120 发起后 1 个进行中任务")
  let task = tasks[0]

  inst.update_user = Some("i120")
  repo.update_instance(inst)
  let inst_upd = head19(select_cell_dt(repo, "SELECT update_time FROM wf_process_instance WHERE id = ?", [
    @moondb.Int64(inst.instance_id)
  ], "update_time"))
  check(
    inst_upd == injected,
    "I120 库里 wf_process_instance.update_time = 注入的引擎钟（实际=\{inst_upd}，注入串=\{injected}）",
  )
  task.update_user = Some("i120")
  repo.update_task(task)
  let task_upd = head19(select_cell_dt(repo, "SELECT update_time FROM wf_process_task WHERE id = ?", [
    @moondb.Int64(task.task_id)
  ], "update_time"))
  check(
    task_upd == injected,
    "I120 库里 wf_process_task.update_time = 注入的引擎钟（实际=\{task_upd}，同行 finish_time 同基准）",
  )
  repo.add_task_actor(task.task_id, ["i120-extra"])
  let actor_ct = head19(select_cell_dt(repo, "SELECT create_time FROM wf_process_task_actor WHERE process_task_id = ? AND actor_id = ?", [
    @moondb.Int64(task.task_id), @moondb.Text("i120-extra")
  ], "create_time"))
  check(
    actor_ct == injected,
    "I120 库里 wf_process_task_actor.create_time = 注入的引擎钟（实际=\{actor_ct}）",
  )
  repo.create_cc_instance(inst.instance_id, "user9x", ["i120-cc"])
  let cc_ct = head19(select_cell_dt(repo, "SELECT create_time FROM wf_process_cc_instance WHERE process_instance_id = ? AND actor_id = ?", [
    @moondb.Int64(inst.instance_id), @moondb.Text("i120-cc")
  ], "create_time"))
  check(
    cc_ct == injected,
    "I120 抄送行 create_time = 注入的引擎钟（实际=\{cc_ct}；该列会被 page_cc_instances 回读投影给前端）",
  )
  let design : @model.ProcessDesign = {
    id: 990502L,
    name: "t1-i120-design",
    display_name: "I120 设计",
    design_type: "approval",
    icon: None,
    is_deployed: 0,
    remark: None,
    create_time: None,
    create_user: Some("user9x"),
    update_time: None,
    update_user: None,
  }
  repo.save_design(design)
  repo.update_design(design)
  let design_upd = head19(select_cell_dt(repo, "SELECT update_time FROM wf_process_design WHERE id = ?", [
    @moondb.Int64(990502L)
  ], "update_time"))
  check(
    design_upd == injected,
    "I120 库里 wf_process_design.update_time = 注入的引擎钟（实际=\{design_upd}）",
  )
  let sg : @model.ProcessSurrogate = {
    id: 990503L,
    process_name: "t1-i120",
    operator: "user9x",
    surrogate: "userB",
    start_time: None,
    end_time: None,
    enabled: 1,
    create_time: None,
    create_user: Some("user9x"),
    update_time: None,
    update_user: None,
  }
  repo.save_surrogate(sg)
  repo.update_surrogate(sg)
  let sg_upd = head19(select_cell_dt(repo, "SELECT update_time FROM wf_process_surrogate WHERE id = ?", [
    @moondb.Int64(990503L)
  ], "update_time"))
  check(
    sg_upd == injected,
    "I120 库里 wf_process_surrogate.update_time = 注入的引擎钟（实际=\{sg_upd}）",
  )

  // 对照组：摘掉注入 ⇒ 同一列必须换成真实 UTC（不再等于注入串），
  // 否则上面的命中可能只是"常量/从没被写过"。
  @model.set_clock(None)
  repo.update_instance(inst)
  let after_default = head19(select_cell_dt(repo, "SELECT update_time FROM wf_process_instance WHERE id = ?", [
    @moondb.Int64(inst.instance_id)
  ], "update_time"))
  check(
    after_default != injected && after_default.length() >= 19,
    "I120 摘掉注入后 update_time 跟随默认臂真实 UTC（实际=\{after_default}，注入串=\{injected}）",
  )
  clean_9x(repo)
}

///|
/// ── issues/116 批次 D：委托查询四判据 + 双仓同答案（SQL 仓真机）──
/// 同一份委托台账同时灌进 SQL 仓与内存仓，逐探针比**两侧答案是否相同**（spec 06 §4.5 条款 6）。
/// 四判据（条款 5）：① 空 processName 全流程兜底（且精确名优先于兜底）、
/// ② 时间窗 start<=now<=end（NULL=该侧不限，边界含等号）、③ 自委托过滤、④ enabled 只认 1。
/// 条款 1.4：多条命中取 id 最大 —— SQL 侧 ORDER BY id DESC。
const I116_NOW : String = "2026-09-21 10:00:00"

///|
fn sg_row(
  id : Int64,
  operator : String,
  agent : String,
  process_name : String,
  start_time : String?,
  end_time : String?,
  enabled : Int
) -> @model.ProcessSurrogate {
  {
    id: id,
    process_name: process_name,
    operator: operator,
    surrogate: agent,
    start_time: start_time,
    end_time: end_time,
    enabled: enabled,
    create_time: None,
    create_user: Some("i116"),
    update_time: None,
    update_user: None,
  }
}

///|
async fn t1_i116_surrogate_query() -> Unit raise {
  @model.set_clock(Some(fn() { I116_NOW }))
  defer { @model.set_clock(None) }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  let mem = @mem.MemoryRepository::new()
  let rows = [
    sg_row(990501L, "i116-zhang", "i116-li", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    sg_row(990502L, "i116-future", "i116-li", "i116-flow", Some("2026-09-25 00:00:00"), None, 1),
    sg_row(990503L, "i116-past", "i116-li", "i116-flow", None, Some("2026-09-20 23:59:59"), 1),
    sg_row(990504L, "i116-off", "i116-li", "i116-flow", None, None, 0),
    sg_row(990505L, "i116-self", "i116-self", "i116-flow", None, None, 1),
    sg_row(990506L, "i116-blank", "i116-li", "", None, None, 1),
    sg_row(990507L, "i116-multi", "i116-old", "i116-flow", None, None, 1),
    sg_row(990508L, "i116-multi", "i116-new", "i116-flow", None, None, 1),
    sg_row(990509L, "i116-edge", "i116-li", "i116-flow", Some(I116_NOW), Some(I116_NOW), 1),
    // 精确名行 id 比兜底行**小**：证明两阶段查询，而不是"一次 ORDER BY id DESC 扫全表"
    sg_row(990510L, "i116-prio", "i116-exact", "i116-flow", None, None, 1),
    sg_row(990511L, "i116-prio", "i116-blank-hit", "", None, None, 1),
    // ── issues/123 条款 1.4：同作用域「旧记录有效 + 新记录不生效」四格 ──
    // 新记录 id 必须更大（ORDER BY id DESC 才落到它）。四格期望 **<none>**：
    // "先滤生效、剩下的才取最新"的旧形状会跳过新的那条、复活旧的那条 ⇒ 这四格是杀手。
    sg_row(990512L, "i123-out", "i123-old-valid", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    sg_row(990513L, "i123-out", "i123-new-agent", "i116-flow", Some("2026-09-25 00:00:00"), None, 1),
    sg_row(990514L, "i123-off", "i123-old-valid", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    sg_row(990515L, "i123-off", "i123-new-agent", "i116-flow", None, None, 0),
    sg_row(990516L, "i123-dirty", "i123-old-valid", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    // 脏值经 sg_row **直落仓储**（不经门面，门面对非 0/1 是判错口径，见 facade 用例）
    sg_row(990517L, "i123-dirty", "i123-new-agent", "i116-flow", None, None, 2),
    sg_row(990518L, "i123-self", "i123-old-valid", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    sg_row(990519L, "i123-self", "i123-self", "i116-flow", None, None, 1),
    // 最新一条有效 ⇒ 照常取它（证明四格的红不是"委托整体失效"）
    sg_row(990520L, "i123-ok", "i123-old-off", "i116-flow", None, None, 0),
    sg_row(990521L, "i123-ok", "i123-new-valid", "i116-flow", Some("2026-09-01 00:00:00"), Some("2026-09-30 23:59:59"), 1),
    // 精确作用域最新一条已过期 ⇒ 判否后**仍**回落全流程作用域那条（Java testSurrogateCrudAndGet 同形）
    sg_row(990522L, "i123-fb", "i123-global", "", None, None, 1),
    sg_row(990523L, "i123-fb", "i123-exact-expired", "i116-flow", None, Some("2026-09-20 23:59:59"), 1),
  ]
  for r in rows {
    repo.save_surrogate(r)
    mem.save_surrogate(r)
  }
  let probes : Array[(String, String, String)] = [
    ("i116-zhang", "i116-flow", "i116-li"),
    ("i116-future", "i116-flow", "<none>"),
    ("i116-past", "i116-flow", "<none>"),
    ("i116-off", "i116-flow", "<none>"),
    ("i116-self", "i116-flow", "<none>"),
    ("i116-blank", "any-unlisted-flow", "i116-li"),
    ("i116-multi", "i116-flow", "i116-new"),
    ("i116-edge", "i116-flow", "i116-li"),
    ("i116-nobody", "i116-flow", "<none>"),
    ("i116-prio", "i116-flow", "i116-exact"),
    // 负向：带名字的委托**不得跨流程命中**（兜底只属于 process_name 为空的那条台账；
    // 引擎侧同判据见 core/engine/surrogate_test.mbt "有名字的委托不跨流程命中"）
    ("i116-zhang", "other-flow", "<none>"),
    // ── issues/123 条款 1.4：各作用域先取**最新一条**再由四判据裁决；旧记录不得复活 ──
    ("i123-out", "i116-flow", "<none>"), // 最新一条窗外
    ("i123-off", "i116-flow", "<none>"), // 最新一条 enabled=0
    ("i123-dirty", "i116-flow", "<none>"), // 最新一条 enabled=2 脏值（只认 1）
    ("i123-self", "i116-flow", "<none>"), // 最新一条自委托
    ("i123-ok", "i116-flow", "i123-new-valid"), // 正向：最新一条有效 ⇒ 取它，旧的停用那条不算
    ("i123-fb", "i116-flow", "i123-global"), // 精确作用域判否后仍回落全流程作用域
  ]
  for p in probes {
    let (op, name, want) = p
    let sql_hit = repo.get_surrogate(op, name, I116_NOW)
    let mem_hit = mem.get_surrogate(op, name, I116_NOW)
    let sql_v = match sql_hit {
      Some(s) => s.surrogate
      None => "<none>"
    }
    let mem_v = match mem_hit {
      Some(s) => s.surrogate
      None => "<none>"
    }
    check(sql_v == want, "I116 SQL 仓 \{op}@\{name} → \{want}（实际=\{sql_v}）")
    check(mem_v == want, "I116 内存仓 \{op}@\{name} → \{want}（实际=\{mem_v}）")
    check(
      sql_v == mem_v,
      "I116 条款6 双仓同答案 \{op}@\{name}：SQL=\{sql_v} 内存=\{mem_v}",
    )
  }
  // 兜底不得跨授权人
  check(repo.get_surrogate("i116-nobody", "any-unlisted-flow", I116_NOW) is None, "I116 兜底仅按授权人")
  clean_9x(repo)
}

///|
/// ── issues/117：我已办状态集合 = task_state <> 10，且空 operator 不得返回全库 ──
/// 造 20/30/40/99/10 五条行，SQL 仓与内存仓必须给出**同一 id 集合**（条款 6 通则）。
async fn t1_i117_done_state_set() -> Unit raise {
  @model.set_clock(Some(fn() { I116_NOW }))
  defer { @model.set_clock(None) }
  let repo = @repo.MysqlRepository::from_env()
  clean_9x(repo)
  save_define_9x(repo, 990601L, "t1-i117", SIMPLE_FLOW)
  let conn = repo.open_raw()
  let _ = @repo.x(
    conn,
    "INSERT INTO wf_process_instance (id, process_define_id, state, operator, variable, create_time, create_user) VALUES (990600, 990601, 10, 'i117-applicant', '{}', NOW(), 'i117')",
    [],
  )
  @repo.close_conn(conn)
  let specs : Array[(Int64, Int, String?)] = [
    (990611L, 20, Some("i117-leader")),
    (990612L, 30, Some("i117-leader")),
    (990613L, 40, Some("i117-leader")),
    (990614L, 99, Some("i117-leader")),
    (990615L, 10, None),
  ]
  let mem = @mem.MemoryRepository::new()
  let mem_define : @model.ProcessDefine = {
    id: 990601L,
    name: "t1-i117",
    display_name: "T1I117",
    define_type: "approval",
    state: 1,
    content: SIMPLE_FLOW,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  mem.save_define(mem_define)
  for sp in specs {
    let (tid, state, actor) = sp
    let t : @model.ProcessTask = {
      task_id: tid,
      process_instance_id: 990600L,
      task_name: "n\{state}",
      display_name: "节点\{state}",
      task_type: 0,
      perform_type: 0,
      task_state: state,
      actor_id: actor,
      actor_ids: ["i117-leader"],
      finish_time: if state == 20 { Some(I116_NOW) } else { None },
      expire_time: None,
      form_key: None,
      parent_task_id: None,
      variables: @json.FlowData::new(),
      create_time: Some(I116_NOW),
      // create_user 是发起人：已办绝不按它放行（issues/107 / Rust 那格违约点）
      create_user: Some("i117-applicant"),
      update_time: None,
      update_user: None,
    }
    repo.save_task(t)
    mem.save_task(t)
  }
  let done_ids = ["990611", "990612", "990613", "990614"]
  // SQL 仓正向
  let q = @model.PageQuery::new(1L, 20L)
  q.set_operator(Some("i117-leader"))
  let page = repo.page_done_tasks(q)
  check(page.record_count() == 4L, "I117 SQL 仓已办 4 条（实际=\{page.record_count()}）")
  for want in done_ids {
    check(page.rows().exists(r => r.id.to_string() == want), "I117 SQL 仓含任务行 \{want}")
  }
  check(!page.rows().exists(r => r.id.to_string() == "990615"), "I117 SQL 仓 DOING(10) 不进已办")
  // 内存仓同答案
  let mpage = mem.page_done_tasks(q)
  check(mpage.record_count() == page.record_count(), "I117 条款6 双仓条数一致")
  for want in done_ids {
    check(mpage.rows().exists(r => r.id.to_string() == want), "I117 内存仓含任务行 \{want}")
  }
  check(!mpage.rows().exists(r => r.id.to_string() == "990615"), "I117 内存仓 DOING(10) 不进已办")
  // 判据生效自证：库里 task_state <> 10 确实筛出这 4 行（不是"=20 蓙对"）
  let cand = select_cell(
    repo,
    "SELECT COUNT(*) AS cnt FROM wf_process_task WHERE process_instance_id = 990600 AND task_state <> 10",
    [],
    "cnt",
  )
  check(cand == "4", "I117 裸 SQL 候选集 = 4（证 <>10 判据真在筛，实际=\{cand}）")
  // 负向：空 operator 不得返回全库
  let q_none = @model.PageQuery::new(1L, 20L)
  check(repo.page_done_tasks(q_none).record_count() == 0L, "I117 SQL 仓无 operator → 空页（不得全库）")
  check(mem.page_done_tasks(q_none).record_count() == 0L, "I117 内存仓无 operator → 空页（不得全库）")
  let q_blank = @model.PageQuery::new(1L, 20L)
  q_blank.set_operator(Some(""))
  check(repo.page_done_tasks(q_blank).record_count() == 0L, "I117 SQL 仓 operator='' → 空页")
  check(mem.page_done_tasks(q_blank).record_count() == 0L, "I117 内存仓 operator='' → 空页")
  // 负向：发起人（create_user）看不到
  let q_creator = @model.PageQuery::new(1L, 20L)
  q_creator.set_operator(Some("i117-applicant"))
  check(repo.page_done_tasks(q_creator).record_count() == 0L, "I117 SQL 仓 create_user 不放行")
  check(mem.page_done_tasks(q_creator).record_count() == 0L, "I117 内存仓 create_user 不放行")
  // 回归：分页五键在判据收紧后仍成立
  let q_page = @model.PageQuery::new(1L, 2L)
  q_page.set_operator(Some("i117-leader"))
  let pp = repo.page_done_tasks(q_page)
  check(
    pp.record_count() == 4L && pp.total_page() == 2L && pp.rows().length() == 2,
    "I117 分页五键回归（recordCount=4/totalPage=2/rows=2）",
  )
  clean_9x(repo)
}

///|
async fn t1_all() -> Unit raise {
  println("T1-M1 page five keys...")
  t1_m1_page()
  println("T1-M2 hydrate + engine flow...")
  t1_m2_hydrate()
  println("T1-M3 m_ params...")
  t1_m3_mparams()
  println("T1-M4 tx rollback...")
  t1_m4_tx_rollback()
  println("T1-M5 idempotent execute...")
  t1_m5_idempotent()
  println("T1-I110 find_instance_by_id hydrate tasks...")
  t1_i110_hydrate()
  println("T1-I114 update_user 真写进 UPDATE 语句（仓储级）...")
  t1_i114_update_user_lands()
  println("T1-I120 六条写路径时间列 = 引擎钟，SQL 侧无 NOW()（仓储级）...")
  t1_i120_engine_clock_lands()
  println("T1-I116 委托查询四判据 + 双仓同答案...")
  t1_i116_surrogate_query()
  println("T1-I117 我已办状态集合 <>10 + 空 operator 空页...")
  t1_i117_done_state_set()
  println("T1 ALL PASS (wasm → 160)")
  println("门面级 withdraw/transfer 真机对拍另跑：moon run --target wasm demo/cmd/t1_mysql")
}

///|
async fn smoke() -> Unit raise {
  if skip_mysql() {
    println("SKIP_MYSQL=1 → T1 skipped (开发机口径；发版机连不上=fail)")
    return
  }
  t1_all()
}

///|
fn main {
  @async.run_async_main(smoke)
}
