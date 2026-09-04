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
  let counter : Ref[Int64] = Ref::new(990100L)
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
  var all_finished = true
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
  let args : Map[String, Json] = Map::new()
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
  var code_ok = false
  match second {
    Ok(_) => code_ok = false
    Err(e) => code_ok = e.code() == @error.ERR_BUSINESS
  }
  check(code_ok, "第二次办理 99999999（任务已办理守卫）")
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
  println("T1 ALL PASS (wasm → 160)")
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
