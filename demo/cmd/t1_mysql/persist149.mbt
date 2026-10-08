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
  // issues/150 X5 的 putIfAbsent 腿要能观察到：业务把 `f_create_time` 提交上来时，
  // 这一列必须先过元数据白名单才谈得上"系统字段不覆写已有值"（`fill_system_fields` 在过滤之后跑）。
  meta.add_field(@persist.FieldMeta::make("create_time", "DATETIME", "创建时间"))
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
  // ⚠⚠ 本轮（issues/150 X5）改掉的一条既有期望值，逐字交代：
  //   旧＝create_user 读 "leader"（办结人）；新＝读 "t149a-user"（发起人）。
  //   依据不是"实现顺手"，是规范与参考实现两边：
  //   · spec/09 §3:98 原文「`create_user`/`update_user` **优先取 `apply_user_id`（= 流程 operator）**
  //     ……无 operator 的场景回落可配置默认值（`setDefaultUserValue`，缺省 `"system"`）」；
  //   · java `JdbcDynamicTableWriter.resolveDefaultUser:231-234` 读的就是 data 里 `fillContext`
  //     写进去的 apply_user_id，而 `ProcessInstance.getOperator()` 在 java 全仓没有第二次赋值
  //     （`setOperator` 只命中 Execution/ProcessSurrogate 两处），归档腿拿到的就是发起人；
  //   · 旧形状拿当次 exec.operator 无条件覆写，等于把这条优先级整条抹掉。
  //   rust 至今仍是 operator 覆写档（`jeeflow-persist/src/lib.rs:227`）⇒ 那是 rust 的欠账，
  //   不反过来当 moon 的基准（本轮只对齐 spec+java，不改判据文件、不动别的语言仓）。
  check_eq(
    select_cell(
      repo,
      "SELECT create_user AS v FROM t149_biz_archive WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "t149a-user",
    "F149A 系统字段 create_user 取 apply_user_id＝发起人（spec/09 §3:98 的优先级）",
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
      // X5 的 putIfAbsent 腿：业务自己把创建时间当表单字段提交上来，系统字段这一档不许覆写
      ("f_create_time", "2020-03-04 05:06:07"),
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
  // ⚠⚠ 同 F149A：本轮（issues/150 X5）把这条既有期望值从 "leader"（经办人）改成发起人，
  //   依据＝spec/09 §3:98「create_user/update_user 优先取 apply_user_id」＋ java
  //   `resolveDefaultUser:231-234`（`fillSystemFields` 根本没有 user 形参）。
  //   办结腿的"这次是谁办的"在 java/spec 里由 `update_time` 覆写 + 任务历史表承担，不由用户列承担。
  check_eq(
    select_cell(
      repo,
      "SELECT update_user AS v FROM t149_biz_sync WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "t149b-user",
    "F149B 更新腿 update_user 仍是 apply_user_id＝发起人（spec/09 §3:98）",
  )
  // X5 putIfAbsent：业务自己提交的 f_create_time 必须原值留在库里（系统字段不覆写已有值）。
  // 旧形状是 `data["create_time"] = now` 无条件覆写——业务侧自己带的建档时间会被引擎改掉。
  check_eq(
    select_cell(
      repo,
      "SELECT create_time AS v FROM t149_biz_sync WHERE process_instance_id = ?",
      [@moondb.Int64(iid)],
      "v",
    ),
    "2020-03-04 05:06:07",
    "F149B 业务自带的 create_time 不被系统字段覆写（putIfAbsent）",
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

// ── F149E 宽松列匹配的 writer 腿（issues/151 X3）──

///|
/// 只给列匹配用的表：列全下划线，值全 ASCII。
fn loose_ddl(table : String) -> String {
  "CREATE TABLE \{table} (id BIGINT NOT NULL, process_instance_id BIGINT, merchant_name VARCHAR(64), audit_note VARCHAR(64), create_time DATETIME, create_user VARCHAR(64), update_time DATETIME, update_user VARCHAR(64), is_deleted TINYINT, PRIMARY KEY (id))"
}

///|
/// 这一支绕开拦截器与元数据，**只打 writer**：data 给驼峰键，表列是下划线，
/// 必须落得进真列（java `normalizeColumn` 宽松档）；条件列（where）与列探测同一枚尺子；
/// 严格档（`with_strict(true)`）必须落不进 ⇒ F149E 第一半的阳性对照。
async fn t1_f149_loose_column_match() -> Unit raise {
  println("T1-F149E writer 腿列匹配真库档：驼峰落下划线列／条件列同尺／严格档不落...")
  let repo = @repo.MysqlRepository::from_env()
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_loose", [])
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_loose_strict", [])
  set_sql(repo, loose_ddl("t149_biz_loose"), [])
  set_sql(repo, loose_ddl("t149_biz_loose_strict"), [])
  clean_9x(repo)
  let w = @repo.MysqlTableWriter::from_repo(repo)
  // ① INSERT：三个驼峰键 ⇒ 三张下划线真列
  let d : Map[String, Json] = Map([])
  d["processInstanceId"] = @json.number_of(990991L)
  d["merchantName"] = @json.string_of("宽松命中")
  d["auditNote"] = @json.string_of("驼峰落库")
  let pk = w.insert("t149_biz_loose", d)
  check(pk != 0L, "F149E data 无主键时由雪花补齐（返回的 pk 非 0）")
  check_eq(
    select_cell(
      repo,
      "SELECT merchant_name AS v FROM t149_biz_loose WHERE process_instance_id = 990991",
      [],
      "v",
    ),
    "宽松命中",
    "F149E merchantName → merchant_name（宽松档真列落库，SQL 里用的是真列名）",
  )
  // ② 条件列也走同一枚尺子：exists_by_key / update_by_key 的键写成驼峰
  check(
    w.exists_by_key("t149_biz_loose", "processInstanceId", 990991L),
    "F149E exists_by_key 的驼峰条件列命中下划线真列",
  )
  let u : Map[String, Json] = Map([])
  u["merchantName"] = @json.string_of("宽松更新")
  w.update_by_key("t149_biz_loose", u, "processInstanceId", 990991L)
  check_eq(
    select_cell(
      repo,
      "SELECT merchant_name AS v FROM t149_biz_loose WHERE process_instance_id = 990991",
      [],
      "v",
    ),
    "宽松更新",
    "F149E update_by_key 同尺命中（SET 与 WHERE 都认下划线真列）",
  )
  // ③ 列探测（java filterColumns）：命中的是表列，返回的仍是候选串（调用方拿它当 data 键用）
  let kept = w.columns("t149_biz_loose", ["merchantName", "nope_col", "merchantName"])
  check_eq(kept.length().to_string(), "1", "F149E columns 只放行命中的候选，且保序去重")
  check_eq(kept[0], "merchantName", "F149E columns 返回候选名（与 java 同档）")
  // ④ 系统列（X5）真库：插入档把 create/update 四列 + is_deleted 补齐
  check(
    select_i64(
      repo,
      "SELECT COUNT(*) AS c FROM t149_biz_loose WHERE process_instance_id = 990991 AND create_user IS NULL",
      [],
      "c",
    ) == 1L,
    "F149E 直接调 writer（不经拦截器）时不补用户列——补齐是 fill_system_fields 的活，这一格钉住边界",
  )
  // ⑤ 阳性对照：同一份驼峰 data 在严格档下必须**不**落下划线列（X3 之前的默认行为）
  let ws = w.with_strict(true)
  let d2 : Map[String, Json] = Map([])
  d2["processInstanceId"] = @json.number_of(990992L)
  d2["merchantName"] = @json.string_of("严格档不落")
  let _ = ws.insert("t149_biz_loose_strict", d2)
  check_eq(
    select_cell(
      repo,
      "SELECT COUNT(*) AS c FROM t149_biz_loose_strict WHERE merchant_name IS NOT NULL",
      [],
      "c",
    ),
    "0",
    "F149E 严格档同一份 data 不落 merchant_name ⇒ 宽松档那一格不是测空气",
  )
  set_sql(repo, "DROP TABLE t149_biz_loose", [])
  set_sql(repo, "DROP TABLE t149_biz_loose_strict", [])
  clean_9x(repo)
  println("PASS F149E writer 腿列匹配（宽松/严格两档 + 条件列 + 列探测）真库成立")
}

// ── F149F 元数据五档与自增主键（issues/151 X10 ＋ issues/150 X9）──

///|
/// 这一支绕开拦截器，直接把 `MetaTableWriter` 接在真库 writer 上：
/// EXPAND 展成两张真列、JSON 档落串、ONE2MANY 递归插子表（外键＝主表主键、apply_user_id 继承），
/// 并验 AUTO_INCREMENT 主键交库自增（X9：旧形状给每张有 `id` 列的表都塞雪花）。
async fn t1_f149_meta_storage_types() -> Unit raise {
  println("T1-F149F 元数据五档真库落点（EXPAND/JSON/ONE2MANY）+ AUTO_INCREMENT 交库自增...")
  let repo = @repo.MysqlRepository::from_env()
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_meta", [])
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_meta_item", [])
  set_sql(repo, "DROP TABLE IF EXISTS t149_biz_auto", [])
  set_sql(
    repo,
    "CREATE TABLE t149_biz_meta (id BIGINT NOT NULL, process_instance_id BIGINT, apply_user_id VARCHAR(64), merchant_name VARCHAR(64), province VARCHAR(64), detail_addr VARCHAR(64), extra TEXT, PRIMARY KEY (id))",
    [],
  )
  set_sql(
    repo,
    "CREATE TABLE t149_biz_meta_item (id BIGINT NOT NULL, order_id BIGINT, apply_user_id VARCHAR(64), item_name VARCHAR(64), PRIMARY KEY (id))",
    [],
  )
  set_sql(
    repo,
    "CREATE TABLE t149_biz_auto (id BIGINT NOT NULL AUTO_INCREMENT, note VARCHAR(64), PRIMARY KEY (id))",
    [],
  )
  clean_9x(repo)
  let provider = @persist.InMemoryMetaProvider::new()
  let meta = @persist.TableMeta::make("t149_biz_meta", "T149F 主表")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "实例ID"))
  meta.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
  meta.add_field(@persist.FieldMeta::make("merchant_name", "VARCHAR(64)", "商户"))
  meta.add_field(@persist.FieldMeta::make(
    "address", "VARCHAR(64)", "地址",
    storage_type=@persist.Expand,
    expand_fields=Map([("province", "province"), ("detail", "detail_addr")]),
  ))
  meta.add_field(@persist.FieldMeta::make("extra", "TEXT", "附加", storage_type=@persist.Json))
  meta.add_field(@persist.FieldMeta::make(
    "items", "VARCHAR(64)", "明细",
    storage_type=@persist.One2Many,
    target_table="t149_biz_meta_item",
    foreign_key="order_id",
  ))
  provider.register(meta)
  let base = @repo.MysqlTableWriter::from_repo(repo)
  let mw = @persist.MetaTableWriter::make(base, provider.as_provider())
  let d : Map[String, Json] = Map([])
  d["processInstanceId"] = @json.number_of(990995L)   // 幂等键也走宽松列匹配（X3 那一枚尺子）
  d["merchantName"] = @json.string_of("甲公司")
  d["address"] = @json.object_of([
    ("province", @json.string_of("浙")),
    ("detail", @json.string_of("A 路 1 号")),
  ])
  d["extra"] = @json.object_of([("tag", @json.string_of("urgent"))])
  d["items"] = @json.array_of([
    @json.object_of([("itemName", @json.string_of("行一"))]),
    @json.object_of([("itemName", @json.string_of("行二"))]),
  ])
  let pk = mw.insert("t149_biz_meta", d)
  check(pk != 0L, "F149F 主表插入返回主键")
  check_eq(
    select_cell(
      repo,
      "SELECT CONCAT(province, '/', detail_addr) AS v FROM t149_biz_meta WHERE process_instance_id = 990995",
      [],
      "v",
    ),
    "浙/A 路 1 号",
    "F149F EXPAND：address 对象落成两张真列（spec/10 §5）",
  )
  check(
    select_cell(
      repo,
      "SELECT extra AS v FROM t149_biz_meta WHERE process_instance_id = 990995",
      [],
      "v",
    ).contains("urgent"),
    "F149F JSON：对象序列化成串写进 TEXT 列",
  )
  check_eq(
    select_cell(repo, "SELECT COUNT(*) AS c FROM t149_biz_meta_item WHERE order_id = ?", [@moondb.Int64(pk)], "c"),
    "2",
    "F149F ONE2MANY：两条子表行，外键＝主表主键",
  )
  check_eq(
    select_cell(repo, "SELECT COUNT(*) AS c FROM t149_biz_meta_item WHERE apply_user_id IS NOT NULL", [], "c"),
    "0",
    "F149F 边界：本次 data 里没有 apply_user_id ⇒ 子表也不该凭空有（继承只继承主表**已有**的那个键）",
  )
  // X9：AUTO_INCREMENT 主键交库自增——旧形状给有 `id` 列的表一律塞雪花（~1.9e18），
  // 这里必须拿到库自己的小号；同时"表里没有任何可写列"以外的路径都还照常报清晰错。
  let ad : Map[String, Json] = Map([])
  ad["note"] = @json.string_of("auto-inc")
  let auto_id = base.insert("t149_biz_auto", ad)
  check(auto_id > 0L && auto_id < 1000000L, "F149F AUTO_INCREMENT 主键交库（返回的是库给的连续号，不是雪花）：\{auto_id}")
  // 阳性对照：同一张自增表，data 显式给了 id ⇒ 用 data 的，不抢自增值
  let gd : Map[String, Json] = Map([])
  gd["id"] = @json.number_of(424242L)
  gd["note"] = @json.string_of("given")
  check(base.insert("t149_biz_auto", gd) == 424242L, "F149F data 已给主键 ⇒ 原样用（不注入不自增）")
  set_sql(repo, "DROP TABLE t149_biz_meta", [])
  set_sql(repo, "DROP TABLE t149_biz_meta_item", [])
  set_sql(repo, "DROP TABLE t149_biz_auto", [])
  clean_9x(repo)
  println("PASS F149F 元数据五档写侧 + 自增主键判定真库成立")
}
