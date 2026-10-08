// issues/149 · persist 业务表写的真库落点与同事务覆盖面（T1-F 四档）
//
// 案 §5 的四档，各自钉死一件事：
// · F149A ARCHIVE 真库一次：办结腿把归档行写进**真实 MySQL 业务表**，逐语句反查列值（不信内存副本）。
// · F149B SYNC 真库一次：发起 INSERT、任务/办结腿 UPDATE 同一行（行数恒 1 ⇒ 走的是 update_by_key
//   而不是再插一遍），且列探测让状态列 `{节点ID}_{状态码}` 真落库。
// · F149C 覆盖面档：persist 写包进 `execute_in_tx`，动作中途抛错 ⇒ 业务表行与四张 `wf_*` 一起消失
//   （`spec/12` §12.2 那句"业务表的写也在同一事务内"在本栈从此可执行，且比 F120 多反查业务表这一格）。
// · F149D 阳性对照（案 §5-3 不许省）：同一套动作，只把 writer 换成 `detached`（独立连接、autocommit），
//   业务表行必须**活过回滚** ⇒ 证明 F149C 的判据在坏形状下真的会红，而不是测空气。
//
// 夹具表本四支自建自删；表名过 persist 现成的安全校验（非 sys_/wf_ 前缀）；值一律 ASCII，
// 免得驱动编码问题混进判据。id 段沿用 R6 的 9909xx。

///|
/// 业务表列集合（ARCHIVE/SYNC 共用形状；状态列两支各自命名，便于逐列反查）
fn biz_table_ddl(table : String, state_col : String) -> String {
  "CREATE TABLE \{table} (id BIGINT NOT NULL, process_instance_id BIGINT, apply_user_id VARCHAR(64), note VARCHAR(64), amount VARCHAR(64), \{state_col} INT, create_time DATETIME, create_user VARCHAR(64), update_time DATETIME, update_user VARCHAR(64), PRIMARY KEY (id))"
}

///|
/// 元数据：ARCHIVE/SYNC 的写侧只把 permission=2 的列放行（`filter_editable` 的既有判据），
/// 系统四列由 `fill_system_fields` 在过滤之后补上，不经元数据。
fn biz_meta(table : String, state_col : String) -> @persist.TableMeta {
  let meta = @persist.TableMeta::make(table, "T149 业务台账")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
  meta.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
  meta.add_field(@persist.FieldMeta::make("note", "VARCHAR(64)", "备注"))
  meta.add_field(@persist.FieldMeta::make("amount", "VARCHAR(64)", "金额"))
  meta.add_field(@persist.FieldMeta::make(state_col, "INT", "节点状态"))
  meta.add_field(@persist.FieldMeta::make("ghost_col", "VARCHAR(64)", "表里没有的列"))
  meta
}

///|
/// 两节点线性流 + persist 配置（persistMode/relTableName 由 parser 从 content 顶层读，
/// 见 core/parser/parser.mbt 的 get_str("persistMode")）
fn persist_flow(name : String, mode : String, table : String) -> String {
  // 多行串先绑定再用（裸用在表达式位会判 deprecated_syntax，本仓零新增告警基线）
  let raw =
    $|{"name": "NAME", "displayName": "T149", "type": "approval", "persistMode": "MODE", "relTableName": "TABLE", "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
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
  raw
    .replace(old="NAME", new=name)
    .replace(old="MODE", new=mode)
    .replace(old="TABLE", new=table)
}

///|
/// 门面 + **真库 writer** 的 persist 拦截器（写侧与仓储同一个实例 ⇒ 同一个事务槽）
fn make_facade_persist(
  repo : @repo.MysqlRepository,
  table : String,
  state_col : String,
  start : Int64
) -> @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository] {
  make_facade_persist_with(repo, @repo.MysqlTableWriter::from_repo(repo), table, state_col, start)
}

///|
/// writer 由调用方给定的一档：阳性对照要塞 `detached` 那支（案 §5-3）
fn make_facade_persist_with(
  repo : @repo.MysqlRepository,
  writer : @repo.MysqlTableWriter,
  table : String,
  state_col : String,
  start : Int64
) -> @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository] {
  let counter : Ref[Int64] = Ref(start)
  let provider = @persist.InMemoryMetaProvider::new()
  provider.register(biz_meta(table, state_col))
  let itc = @persist.PersistPostInterceptor::make(provider, writer)
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new()).with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  })
  let _ = ctx.register_interceptor(itc.as_interceptor())
  @facade.Facade::make(ctx)
}

///|
/// 办结到 end：task1 由 leader 同意（submitType=1）⇒ 实例 FINISHED(20)，ARCHIVE 的触发点才成立
async fn finish_to_end(
  f : @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository],
  repo : @repo.MysqlRepository,
  iid : Int64
) -> Unit raise {
  let exe = f.flow(
    "processTask/execute",
    fa([
      ("processTaskId", doing_task_id(repo, iid, "task1").to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
    ]),
  )
  check(env_code(exe) == 0L, "办结 task1（submitType=1）code=0")
}

// ── F149A ARCHIVE ──

///|
async fn t1_f149_archive_real_db() -> Unit raise {
  println("T1-F149A persist ARCHIVE 写真库业务表，办结腿一行、逐列反查（真库档）...")
  let repo = @repo.MysqlRepository::from_env()
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_archive", [])
  set_sql(repo, biz_table_ddl("t149_biz_archive", "end_20"), [])
  clean_9x(repo)
  save_define_9x(repo, 990951L, "t1-f149a", persist_flow("t1-f149a", "ARCHIVE", "t149_biz_archive"))
  let f = make_facade_persist(repo, "t149_biz_archive", "end_20", 990952L)
  let s = f.flow(
    "processInstance/startAndExecute",
    fa([
      ("processDefineId", "990951"),
      ("operator", "t149a-user"),
      ("f_note", "travel"),
      ("f_amount", "120"),
    ]),
  )
  check(env_code(s) == 0L, "F149A 发起 code=0")
  let iid = iid_of(s)
  // 未办结 ⇒ ARCHIVE 不该提前写（spec/09：只在结束+FINISHED+submitType=1）
  check(
    select_i64(repo, "SELECT COUNT(*) AS c FROM t149_biz_archive", [], "c") == 0L,
    "F149A 办结前业务表零行（ARCHIVE 时机判据）",
  )
  finish_to_end(f, repo, iid)
  check_eq(
    select_cell(repo, "SELECT COUNT(*) AS c FROM t149_biz_archive", [], "c"),
    "1",
    "F149A 办结后业务表恰好一行（真库 INSERT 落地）",
  )
  check_eq(
    select_cell(
      repo,
      "SELECT note AS v FROM t149_biz_archive WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "travel",
    "F149A f_note 去前缀后落 note 列",
  )
  check_eq(
    select_cell(
      repo,
      "SELECT amount AS v FROM t149_biz_archive WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "120",
    "F149A f_amount 落 amount 列",
  )
  check_eq(
    select_cell(
      repo,
      "SELECT apply_user_id AS v FROM t149_biz_archive WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "t149a-user",
    "F149A 上下文列 apply_user_id 取发起人（fill_context 的 C17 回落）",
  )
  // 归档行的 create_user 是**办结人**而不是发起人：ARCHIVE 的触发点就是办结那一次动作，
  // 引擎把当次 exec.operator 交给 fill_system_fields（java 侧 fillSystemFields 不带 user 形参、
  // 取环境当前用户，同档）。这一格是"真库写出来的值来自哪"的读数，不是给实现找齐。
  check_eq(
    select_cell(
      repo,
      "SELECT create_user AS v FROM t149_biz_archive WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "leader",
    "F149A 系统字段 create_user 由引擎补齐并落库（归档腿＝办结人）",
  )
  // ghost_col 只在元数据里、表里没有 ⇒ writer 内部按真列过滤后必须被剔除（java 同义务），
  // 这一格证明列探测走的是库而不是内存白名单
  check(
    select_i64(
      repo,
      "SELECT COUNT(*) AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't149_biz_archive' AND COLUMN_NAME = 'ghost_col'",
      [],
      "c",
    ) == 0L,
    "F149A 表里确实没有 ghost_col（剔除判据的前提）",
  )
  set_sql(repo, "DROP TABLE t149_biz_archive", [])
  clean_9x(repo)
  println("PASS F149A persist ARCHIVE 真库落点成立")
}

// ── F149B SYNC ──

///|
async fn t1_f149_sync_real_db() -> Unit raise {
  println("T1-F149B persist SYNC 写真库：发起 INSERT、办结 UPDATE 同一行 + 状态列落库...")
  let repo = @repo.MysqlRepository::from_env()
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_sync", [])
  set_sql(repo, biz_table_ddl("t149_biz_sync", "task1_10"), [])
  clean_9x(repo)
  save_define_9x(repo, 990961L, "t1-f149b", persist_flow("t1-f149b", "SYNC", "t149_biz_sync"))
  let f = make_facade_persist(repo, "t149_biz_sync", "task1_10", 990962L)
  let s = f.flow(
    "processInstance/startAndExecute",
    fa([
      ("processDefineId", "990961"),
      ("operator", "t149b-user"),
      ("f_note", "sick"),
      ("f_amount", "55"),
    ]),
  )
  check(env_code(s) == 0L, "F149B 发起 code=0")
  let iid = iid_of(s)
  check_eq(
    select_cell(repo, "SELECT COUNT(*) AS c FROM t149_biz_sync", [], "c"),
    "1",
    "F149B 发起即建行（SYNC 首次 INSERT）",
  )
  finish_to_end(f, repo, iid)
  check_eq(
    select_cell(repo, "SELECT COUNT(*) AS c FROM t149_biz_sync", [], "c"),
    "1",
    "F149B 办结后仍是一行（走 update_by_key 而非重复插入）",
  )
  check_eq(
    select_cell(
      repo,
      "SELECT update_user AS v FROM t149_biz_sync WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "leader",
    "F149B 办结腿把 update_user 改成经办人（同事务外的独立 UPDATE 落库）",
  )
  check_eq(
    select_cell(
      repo,
      "SELECT task1_10 AS v FROM t149_biz_sync WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "10",
    "F149B 状态列 {节点ID}_{状态码} 经列探测后落库",
  )
  set_sql(repo, "DROP TABLE t149_biz_sync", [])
  clean_9x(repo)
  println("PASS F149B persist SYNC 真库落点成立")
}

// ── F149C 同事务 + F149D 阳性对照 ──

///|
/// 事务内读回：必须走**事务那条连接**（`current_tx_conn`）。
/// ⚠ 这里不能用 select_i64/select_cell —— 它们经 `open_raw()` 新开连接，而事务里的写还没提交，
///   别的连接按 F121 实测就是读不到（那格当时正是"读不到＝未提交"的判据本身）。
///   拿新连接读会把"写没落到事务连接上"和"写落在事务里但还没提交"两件事混成同一个 0，
///   覆盖面档的"非空转"那一半就此失效。
async fn tx_cell(
  rr : @repo.MysqlRepository,
  sql : String,
  params : Array[@moondb.Value],
  col : String
) -> String raise {
  match rr.current_tx_conn() {
    None => raise @error.Business("inner-assert:回调里事务句柄不存在（没进 execute_in_tx？）")
    Some(c) =>
      match @repo.q(c, sql, params) {
        [] => "<无行>"
        rows => cell(rows[0], col)
      }
  }
}

///|
/// 事务内跑一次真实发起（SYNC ⇒ 业务表 INSERT 发生在事务里），随后按预期抛错。
/// ⚠ 回调体内不用 check()：它走 abort 抛开放 Error，与模板 op 的闭集不匹配（F120 同款纪律），
///   内部断言失败改成抛专属文案，外层比对文案来分辨"断言失败"与"预期的那一次抛错"。
async fn f149_start_then_boom(rr : @repo.MysqlRepository, iid_want : Int64) -> Unit raise {
  let f = make_facade_persist(rr, "t149_biz_tx", "task1_10", iid_want)
  let started = f.flow(
    "processInstance/startAndExecute",
    fa([
      ("processDefineId", "990971"),
      ("operator", "t149c-user"),
      ("f_note", "atomic"),
      ("f_amount", "7"),
    ]),
  )
  if env_code(started) != 0L {
    raise @error.Business("inner-assert:发起 code 非 0（实际=\{env_code(started)}）")
  }
  let iid = iid_of(started)
  // 空转证明：事务内**沿事务连接**读自己刚写的业务行必须读得到 ⇒ 写确实汇进了这条连接
  let live = tx_cell(
    rr,
    "SELECT COUNT(*) AS c FROM t149_biz_tx WHERE process_instance_id = ?",
    [@moondb.Int64(iid)],
    "c",
  )
  if live != "1" {
    raise @error.Business("inner-assert:事务内业务表读不到刚写的行（实际=\{live}）")
  }
  raise @error.Business("f149-post-action-boom")
}

///|
/// 事务里回滚掉的只剩 wf_* 的那一档（阳性对照用）：业务表写走独立连接 ⇒ 行活下来
async fn f149_start_then_boom_detached(rr : @repo.MysqlRepository, iid_want : Int64) -> Unit raise {
  let f = make_facade_persist_with(
    rr,
    @repo.MysqlTableWriter::detached(rr),
    "t149_biz_tx",
    "task1_10",
    iid_want,
  )
  let started = f.flow(
    "processInstance/startAndExecute",
    fa([
      ("processDefineId", "990971"),
      ("operator", "t149d-user"),
      ("f_note", "detached"),
      ("f_amount", "8"),
    ]),
  )
  if env_code(started) != 0L {
    raise @error.Business("inner-assert:发起 code 非 0（实际=\{env_code(started)}）")
  }
  raise @error.Business("f149-post-action-boom")
}

///|
async fn f149_prepare(repo : @repo.MysqlRepository) -> Unit raise {
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_tx", [])
  set_sql(repo, biz_table_ddl("t149_biz_tx", "task1_10"), [])
  clean_9x(repo)
  save_define_9x(repo, 990971L, "t1-f149", persist_flow("t1-f149", "SYNC", "t149_biz_tx"))
}

///|
/// 覆盖面档（案 §5-2）：persist 写与 wf_* 同事务 ⇒ 中途抛错，业务表行与四张表一起消失
async fn t1_f149_persist_in_tx_rollback() -> Unit raise {
  println("T1-F149C 事务包住真实发起，中途抛错 ⇒ 业务表行与 wf_* 一起回滚（覆盖面档）...")
  let base = @repo.MysqlRepository::from_env()
  f149_prepare(base)
  let r = base.new_request()
  let outcome = try {
    r.execute_in_tx(async fn(rr) { f149_start_then_boom(rr, 990972L) })
    "clean"
  } catch {
    e => "\{e}"
  }
  check_raised(outcome, "f149-post-action-boom", "F149C 动作后抛错按预期外传（模板已 ROLLBACK）")
  check(
    select_i64(base, "SELECT COUNT(*) AS c FROM wf_process_instance WHERE id >= 990000 AND id < 1000000", [], "c") == 0L,
    "F149C 原子档 wf_* 零残留",
  )
  check_eq(
    select_cell(base, "SELECT COUNT(*) AS c FROM t149_biz_tx", [], "c"),
    "0",
    "F149C 原子档**业务表**同样零残留（比 F120 多出来的那一格：spec/12 §12.2 覆盖面）",
  )
  set_sql(base, "DROP TABLE t149_biz_tx", [])
  clean_9x(base)
  println("PASS F149C 业务表写与 wf_* 同事务成立")
}

///|
/// 阳性对照（案 §5-3）：只换 writer 的连接形状，动作与判据一个字不改 ⇒ 原子档**必须红**。
/// 这里"红"的读数＝回滚后业务表行还在（wf_* 照旧零残留，说明事务本身没问题）。
async fn t1_f149_detached_positive_control() -> Unit raise {
  println("T1-F149D 业务表写挪到事务外（detached writer）⇒ 原子档必须红（阳性对照）...")
  let base = @repo.MysqlRepository::from_env()
  f149_prepare(base)
  let r = base.new_request()
  let outcome = try {
    r.execute_in_tx(async fn(rr) { f149_start_then_boom_detached(rr, 990982L) })
    "clean"
  } catch {
    e => "\{e}"
  }
  check_raised(outcome, "f149-post-action-boom", "F149D 抛错按预期外传")
  check(
    select_i64(base, "SELECT COUNT(*) AS c FROM wf_process_instance WHERE id >= 990000 AND id < 1000000", [], "c") == 0L,
    "F149D wf_* 仍零残留（回滚确实发生了，坏的不是事务本身）",
  )
  check_eq(
    select_cell(base, "SELECT COUNT(*) AS c FROM t149_biz_tx", [], "c"),
    "1",
    "F149D 业务表行活过了回滚 ⇒ 原子判据在坏形状下真的报红（F149C 不是测空气）",
  )
  check_eq(
    select_cell(base, "SELECT note AS v FROM t149_biz_tx", [], "v"),
    "detached",
    "F149D 残留的正是事务外那条写（note 对得上，不是历史脏行）",
  )
  set_sql(base, "DROP TABLE t149_biz_tx", [])
  clean_9x(base)
  println("PASS F149D 阳性对照成立（判据有牙）")
}
