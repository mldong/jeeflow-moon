// MySQL 仓储 IProcessRepository 全 24 方法 —— 移植自 rust repository-sqlx/lib.rs
// SQL 与 rust/java 编辑源同款；每操作独立连接（autocommit，方案 §2.3）。

///|
pub(all) struct MysqlRepository {
  config : MysqlConfig
}

///|
pub fn MysqlRepository::make(config : MysqlConfig) -> MysqlRepository {
  // 块里只有一个 `{ … }` 时"代码块 vs 结构体字面量"有歧义（编译器直接点名）⇒ 限定写法
  MysqlRepository::{ config }
}
///|
pub fn MysqlRepository::from_env() -> MysqlRepository raise {
  { config: MysqlConfig::from_env() }
}

///|
/// 测试/工具用裸连接（绕过事务环境，始终新开；调用方负责 close）
pub async fn MysqlRepository::open_raw(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  // 同上：`try { … } catch { e => raise e }` 是空壳，去掉包装不改任何行为
  self.config.open_conn()
}
///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_define_by_id(self, define_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, name, display_name, type, state, content, version, create_time, create_user, update_time, update_user FROM wf_process_define WHERE id = ?",
    [@moondb.Int64(define_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  let r = rows[0]
  Some({
    id: row_i64(r, "id"),
    name: row_text(r, "name", ""),
    display_name: row_text(r, "display_name", ""),
    define_type: row_text(r, "type", "approval"),
    state: row_int(r, "state", 0),
    content: row_blob_text(r, "content"),
    version: row_int(r, "version", 1),
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
  })
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn save_define(self, define_info) {
  if define_info.id == 0L {
    define_info.id = next_snowflake_id()
  }
  if define_info.create_time is None {
    define_info.create_time = Some(@model.current_time_str())
  }
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_define (id, name, display_name, type, state, content, version, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(define_info.id),
      @moondb.Text(define_info.name),
      @moondb.Text(define_info.display_name),
      @moondb.Text(define_info.define_type),
      @moondb.Int(define_info.state),
      @moondb.Text(define_info.content),
      @moondb.Int(define_info.version),
      opt_v(define_info.create_time),
      opt_v(define_info.create_user),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn update_define(self, define_info) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_define SET display_name=?, type=?, state=?, content=?, version=?, update_user=? WHERE id=?",
    [
      @moondb.Text(define_info.display_name),
      @moondb.Text(define_info.define_type),
      @moondb.Int(define_info.state),
      @moondb.Text(define_info.content),
      @moondb.Int(define_info.version),
      opt_v(define_info.update_user),
      @moondb.Int64(define_info.id),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn update_define_state(self, define_id, state) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_define SET state=? WHERE id=?",
    [@moondb.Int(state), @moondb.Int64(define_id)],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn remove_define(self, define_id) {
  let conn = self.open_or_tx()
  let _ = x(conn, "DELETE FROM wf_process_define WHERE id=?", [@moondb.Int64(define_id)])
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_instance_by_id(self, instance_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, parent_id, process_define_id, state, parent_node_name, business_no, operator, expire_time, variable, create_time, create_user, update_time, update_user FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(instance_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  let r = rows[0]
  Some({
    instance_id: row_i64(r, "id"),
    parent_id: row_opt_i64(r, "parent_id"),
    define_id: row_i64(r, "process_define_id"),
    state: row_int(r, "state", 0),
    parent_node_name: row_opt_text(r, "parent_node_name"),
    business_no: row_opt_text(r, "business_no"),
    operator: row_text(r, "operator", ""),
    expire_time: row_opt_datetime(r, "expire_time"),
    variables: parse_flow_data(row_opt_text(r, "variable")),
    // issues/110：聚合水合——二次查 wf_process_task 装任务副本（含 actor_ids），
    // 对齐 Java findTasksByInstanceId / PHP PdoProcessRepository / C# issues/89；
    // 否则门面 detail 的 tasks/activeTaskList 恒空。
    // 复用 find_history_tasks（ORDER BY id + 批查 actor，事务内经 open_or_tx 复用环境连接）
    tasks: self.find_history_tasks(instance_id),
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
    define_info: None,
  })
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn save_instance(self, instance) {
  if instance.instance_id == 0L {
    instance.instance_id = next_snowflake_id()
  }
  if instance.create_time is None {
    instance.create_time = Some(@model.current_time_str())
  }
  let var_json = flow_data_to_json(instance.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_instance (id, parent_id, process_define_id, state, parent_node_name, business_no, operator, expire_time, variable, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(instance.instance_id),
      @moondb.Int64(instance.parent_id.unwrap_or(0L)),
      @moondb.Int64(instance.define_id),
      @moondb.Int(instance.state),
      opt_v(instance.parent_node_name),
      opt_v(instance.business_no),
      @moondb.Text(instance.operator),
      opt_v(instance.expire_time),
      @moondb.Text(var_json),
      opt_v(instance.create_time),
      opt_v(instance.create_user),
    ],
  )
  close_conn(conn)
}

///|
/// 实例更新（issues/114：本语句历史上只写 state/variable/update_time，门面回写的撤回人
/// 在 SQL 仓里被静默丢弃 → update_user 永不落地（内存仓整行替换不受影响，双仓答案不一致
/// 即此，本栈独有坑）；补 update_user=? 后由真机 MySQL 断言钉住）
pub impl @spi.ProcessRepository for MysqlRepository with fn update_instance(self, instance) {
  let var_json = flow_data_to_json(instance.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_instance SET state=?, variable=?, update_user=?, update_time=? WHERE id=?",
    [
      @moondb.Int(instance.state),
      @moondb.Text(var_json),
      opt_v(instance.update_user),
      now_v(),
      @moondb.Int64(instance.instance_id),
    ],
  )
  close_conn(conn)
}

///|
fn map_mysql_task(r : @moondb.Row, actor_ids : Array[String]) -> @model.ProcessTask {
  {
    task_id: row_i64(r, "id"),
    process_instance_id: row_i64(r, "process_instance_id"),
    task_name: row_text(r, "task_name", ""),
    display_name: row_text(r, "display_name", ""),
    task_type: row_int(r, "task_type", 0),
    perform_type: row_int(r, "perform_type", 0),
    task_state: row_int(r, "task_state", 0),
    actor_id: row_opt_text(r, "operator"),
    actor_ids,
    finish_time: row_opt_datetime(r, "finish_time"),
    expire_time: row_opt_datetime(r, "expire_time"),
    form_key: row_opt_text(r, "form_key"),
    parent_task_id: row_opt_i64(r, "task_parent_id"),
    variables: parse_flow_data(row_opt_text(r, "variable")),
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
  }
}

///|
/// 任务行 → ProcessTask + 参与人批量水合（rust tasks_from_rows：is_allowed 依赖 actor_ids）
async fn MysqlRepository::hydrate_tasks(self : MysqlRepository, rows : Array[@moondb.Row]) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let conn = self.open_or_tx()
  let out : Array[@model.ProcessTask] = []
  for r in rows {
    let task_id = row_i64(r, "id")
    let actor_rows = q(conn, 
      "SELECT actor_id FROM wf_process_task_actor WHERE process_task_id = ?",
      [@moondb.Int64(task_id)],
    )
    let actor_ids : Array[String] = []
    for ar in actor_rows {
      actor_ids.push(row_text(ar, "actor_id", ""))
    }
    out.push(map_mysql_task(r, actor_ids))
  }
  close_conn(conn)
  out
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_task_by_id(self, task_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, process_instance_id, task_name, display_name, task_type, perform_type, task_state, operator, finish_time, expire_time, form_key, task_parent_id, variable, create_time, create_user, update_time, update_user FROM wf_process_task WHERE id = ?",
    [@moondb.Int64(task_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  let tasks = self.hydrate_tasks(rows)
  if tasks.is_empty() {
    None
  } else {
    Some(tasks[0])
  }
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn save_task(self, task) {
  if task.task_id == 0L {
    task.task_id = next_snowflake_id()
  }
  if task.create_time is None {
    task.create_time = Some(@model.current_time_str())
  }
  let var_json = flow_data_to_json(task.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    // ⚠️ `finish_time` 这一列 **2026-09-30 issues/142 A 批补进来**（spec/02 §6.2 第 1bis 条）：
    // 本语句原先不带它，finish_time 只由 update_task 写——可记录类（snaker:custom）那条 DONE 行
    // **只走 INSERT 不走 UPDATE**（生来已完成，没有"办理"那一次更新），于是聚合根赋的完成时间
    // 在 SQL 仓被静默丢掉、内存仓却全绿（两层冗余藏病灶；本轮补列后由
    // demo/cmd/t1_mysql 的 i142 格在真库复查）。列序照 java/rust/node 同位置：operator 之后。
    "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_type, perform_type, task_state, operator, finish_time, expire_time, form_key, task_parent_id, variable, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(task.task_id),
      @moondb.Int64(task.process_instance_id),
      @moondb.Text(task.task_name),
      @moondb.Text(task.display_name),
      @moondb.Int(task.task_type),
      @moondb.Int(task.perform_type),
      @moondb.Int(task.task_state),
      opt_v(task.actor_id),
      opt_v(task.finish_time),
      opt_v(task.expire_time),
      opt_v(task.form_key),
      @moondb.Int64(task.parent_task_id.unwrap_or(0L)),
      @moondb.Text(var_json),
      opt_v(task.create_time),
      opt_v(task.create_user),
    ],
  )
  close_conn(conn)
}

///|
/// 任务更新（issues/114/115：与 update_instance 同补 update_user 列——撤回人要落到被撤任务行、
/// 转办人要落到任务行，否则审计列在 SQL 仓恒 NULL；actor_id→operator 列按契约**不由转办写**，
/// 但本语句仍负责把副本里的值原样带过去（办结路径写真实办理人））
pub impl @spi.ProcessRepository for MysqlRepository with fn update_task(self, task) {
  let var_json = flow_data_to_json(task.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_task SET task_state=?, operator=?, finish_time=?, variable=?, update_user=?, update_time=? WHERE id=?",
    [
      @moondb.Int(task.task_state),
      opt_v(task.actor_id),
      opt_v(task.finish_time),
      @moondb.Text(var_json),
      opt_v(task.update_user),
      now_v(),
      @moondb.Int64(task.task_id),
    ],
  )
  close_conn(conn)
}

///|
let task_columns : String =
  "id, process_instance_id, task_name, display_name, task_type, perform_type, task_state, operator, finish_time, expire_time, form_key, task_parent_id, variable, create_time, create_user, update_time, update_user"

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_doing_tasks(self, instance_id, task_names) {
  let conn = self.open_or_tx()
  let mut sql = "SELECT " + task_columns + " FROM wf_process_task WHERE process_instance_id = ? AND task_state = 10"
  let params : Array[@moondb.Value] = [@moondb.Int64(instance_id)]
  if !task_names.is_empty() {
    let b = StringBuilder()
    for i, _ in task_names {
      b.write_string(if i > 0 { "," } else { " AND task_name IN (" })
      b.write_string("?")
      ()
    }
    b.write_string(")")
    sql = sql + b.to_string()
    for name in task_names {
      params.push(@moondb.Text(name))
    }
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  self.hydrate_tasks(rows)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_done_tasks(self, instance_id, task_names) {
  let conn = self.open_or_tx()
  let mut sql = "SELECT " + task_columns + " FROM wf_process_task WHERE process_instance_id = ? AND task_state = 20"
  let params : Array[@moondb.Value] = [@moondb.Int64(instance_id)]
  if !task_names.is_empty() {
    let b = StringBuilder()
    for i, _ in task_names {
      b.write_string(if i > 0 { "," } else { " AND task_name IN (" })
      b.write_string("?")
      ()
    }
    b.write_string(")")
    sql = sql + b.to_string()
    for name in task_names {
      params.push(@moondb.Text(name))
    }
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  self.hydrate_tasks(rows)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_history_tasks(self, instance_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT " + task_columns + " FROM wf_process_task WHERE process_instance_id = ? ORDER BY id",
    [@moondb.Int64(instance_id)],
  )
  close_conn(conn)
  self.hydrate_tasks(rows)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn find_task_actors(self, task_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT actor_id FROM wf_process_task_actor WHERE process_task_id = ?",
    [@moondb.Int64(task_id)],
  )
  close_conn(conn)
  let out : Array[String] = []
  for r in rows {
    out.push(row_text(r, "actor_id", ""))
  }
  out
}

///|
/// issues/142 B 批（spec 06-facade §2.11）：本仓 `add_task_actor` **实际会 INSERT 的 actor 序**
/// = `@model.normalize_actors(入参)` —— 逐元素 trim、空串/纯空白丢弃、同一次调用折叠，落库与
/// 判重取 trim 后的值（" 123 " 与 "123" 是同一个人，不 trim 就与 §2.11 的写侧判重错开、同一人落两行）。
///
/// 抽成 pub 纯函数的理由与同文件 `cc_actor_ids_to_insert` 一样：本栈 T0 档不连真库（真库档 T1
/// 需 JEFFLOW_DB_* 且 native 编译要 cc），写侧这一层否则只能靠"内存腿同判据"间接推定 ——
/// 有了这一支，`add_task_actor` 循环的实际入参就是它的返回值，还原归一该格当场红；
/// 判据本身仍只在 @model 那一处（本函数只组合，不另写规则）。
pub fn task_actor_ids_to_insert(actor_ids : Array[String]) -> Array[String] {
  @model.normalize_actors(actor_ids)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn add_task_actor(self, task_id, actors) {
  // issues/142 B 批（spec 06-facade §2.11「两仓 addTaskActor 写侧兜底」）：循环的序取自
  // task_actor_ids_to_insert —— 空串/纯空白一个都不插、trim 后的值才进 INSERT、同调用折叠；
  // 之后仍按既有 SELECT 判重跳过库里已有的行。只修门面腿则绕过门面直连仓储的调用方
  // 照样灌空归属值（issues/129 病根），所以这一层必须自己挡（§2.11 要求①「两层都挡」）。
  // 去重追加（C14：非全删全插）
  let conn = self.open_or_tx()
  for actor in task_actor_ids_to_insert(actors) {
    let exists = q(conn, 
      "SELECT id FROM wf_process_task_actor WHERE process_task_id = ? AND actor_id = ? LIMIT 1",
      [@moondb.Int64(task_id), @moondb.Text(actor)],
    )
    if exists.is_empty() {
      let _ = x(conn, 
        "INSERT INTO wf_process_task_actor (id, process_task_id, actor_id, create_time, create_user) VALUES (?, ?, ?, ?, 'system')",
        [
          @moondb.Int64(next_snowflake_id()),
          @moondb.Int64(task_id),
          @moondb.Text(actor),
          now_v(),
        ],
      )
    }
  }
  close_conn(conn)
}

///|
/// issues/137 §3-6（spec 06 §processTask/removeTaskActor 语义 6 · owner 2026-10-02 拍「两形并集」）：
/// 删除列表过 `@model.actor_delete_forms`（与内存仓同一枚）——**空值一律丢弃**，一条 DELETE 都不发；
/// **非空值同时以「原值」与「trim 值」两形绑进 WHERE**：只取 trim 形 ⇒ 门面按语义 6 交出的脏行原值
/// `" 9101 "` 被削成 `9101`，真库 NO PAD 排序规则下那一行删不掉而门面报成功（**本栈改前正是这个形状**）；
/// 只取原值形 ⇒ 绕过门面直连仓储传 `" 8601 "` 时删不掉写侧归一后的规范行（issues/142 §9.2 那一路）。
/// 展开后为空 ⇒ 早退。两仓必须同答案（issues/117 场景 27）。
pub impl @spi.ProcessRepository for MysqlRepository with fn remove_task_actor(self, task_id, actors) {
  let remove = @model.actor_delete_forms(actors)
  if remove.is_empty() {
    return
  }
  let conn = self.open_or_tx()
  for actor in remove {
    let _ = x(conn, 
      "DELETE FROM wf_process_task_actor WHERE process_task_id = ? AND actor_id = ?",
      [@moondb.Int64(task_id), @moondb.Text(actor)],
    )
  }
  close_conn(conn)
}

///|
/// issues/141 G10（spec 06-facade §2.10「空抄送人不建 cc 行」）+ G2（§4 写侧判重）合起来的那一支：
/// 本仓**实际会 INSERT 的 actor 序** = 先 `@model.normalize_cc_actors`（空串/纯空白丢弃、值取 trim
/// 后的串、同调用折叠），再 `@model.cc_fresh_subset`（已有 cc 行的人跳过）。
///
/// 抽成 pub 纯函数有两个理由：① 判据仍只在 `@model` 那一处（本函数只组合，不另写规则）；
/// ② 本仓 T0 档不连真库（真库档 T1 需 JEFFLOW_DB_* 且 native 编译要 cc），写侧这一层的行为面
/// 否则只能靠"内存腿同判据"间接推定 —— 有这一支，`create_cc_instance` 与
/// `create_cc_instance_if_absent` 循环/返回的实际就是它的返回值，测试能直接照到 MySQL 写侧
/// （还原这里 ⇒ 本格当场红，不必等真库）。
pub fn cc_actor_ids_to_insert(existing : Array[String], actor_ids : Array[String]) -> Array[String] {
  @model.cc_fresh_subset(existing, @model.normalize_cc_actors(actor_ids))
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn create_cc_instance(self, instance_id, creator, actor_ids) {
  let conn = self.open_or_tx()
  // issues/141 G2 写侧判重＝幂等空操作（spec 06 §4）：同一 (实例, 被抄送人) 已有 cc 行 ⇒ 整条跳过——
  // ①不新增行 ②不重置未读 state（保持原值）③不更新原行时间（不发 UPDATE，create_time/update_time 逐字不变）。
  // 判重在写侧，查询侧不引入去重、历史重复行也不清理（owner 2026-09-29 拍）。
  // 判据与内存仓共用 @model.cc_fresh_subset 这一份；同一次调用内的重复也一并折叠。
  let existing = cc_actor_ids_of_rows(cc_actor_ids_query(conn, instance_id))
  // issues/141 G10：写侧第二层兜底（绕过引擎漏斗/门面直连仓储的调用方也建不出 actor_id='' 的行，
  // 那正是 issues/129 那族"空归属值读全库"的病根）；trim 后的值才进 INSERT，与判重同一条尺子。
  for actor_id in cc_actor_ids_to_insert(existing, actor_ids) {
    let _ = x(conn, 
      cc_insert_sql(),
      [
        @moondb.Int64(next_snowflake_id()),
        @moondb.Int64(instance_id),
        @moondb.Text(actor_id),
        now_v(),
        @moondb.Text(creator),
      ],
    )
  }
  close_conn(conn)
}

///|
/// cc 读侧 SQL（issues/141 G2 写侧判重的读侧）：某实例已有 cc 行的 actor_id。
/// **不去重**（与查询侧同口径：DISTINCT 不许顺手加在这里，历史重复行不清理）。
pub fn cc_actor_ids_sql() -> String {
  "SELECT actor_id FROM wf_process_cc_instance WHERE process_instance_id = ?"
}

///|
/// cc 建行 SQL（issues/141 G2）：逐行 INSERT、state 恒 0（未读）；重复人不在这条语句的管辖内，
/// 由上层 @model.cc_fresh_subset 先过滤 ⇒ 本语句一旦执行就是"真的新建了一行"。
pub fn cc_insert_sql() -> String {
  "INSERT INTO wf_process_cc_instance (id, process_instance_id, actor_id, state, create_time, create_user) VALUES (?, ?, ?, 0, ?, ?)"
}

///|
/// 读某实例的 cc actor_id 行（事务态复用环境连接，非事务态新开；调用方负责 close）
async fn cc_actor_ids_query(
  conn : @client.MysqlConn,
  instance_id : Int64
) -> Array[@moondb.Row] raise @error.JeeflowError {
  q(conn, cc_actor_ids_sql(), [@moondb.Int64(instance_id)])
}

///|
fn cc_actor_ids_of_rows(rows : Array[@moondb.Row]) -> Array[String] {
  let out : Array[String] = []
  for r in rows {
    out.push(row_text(r, "actor_id", ""))
  }
  out
}

///|
/// issues/141 G2：某实例已有 cc 行的 actor id（写侧判重的读侧公开口）。
pub impl @spi.ProcessRepository for MysqlRepository with fn find_cc_actors(self, instance_id) {
  let conn = self.open_or_tx()
  let rows = cc_actor_ids_query(conn, instance_id)
  close_conn(conn)
  cc_actor_ids_of_rows(rows)
}

///|
/// issues/141 G2（spec 06 §4 · spec §11.2 原则 1）：幂等建 cc 行，返回**实际新建**的子集
/// （顺序与入参一致，同一次调用内的重复也折叠）。子集为空 ⇒ 调用方不得 fire CC_CREATE（码 4）。
pub impl @spi.ProcessRepository for MysqlRepository with fn create_cc_instance_if_absent(self, instance_id, creator, actor_ids) {
  // issues/141 G10：返回子集同样先归一（三条入口拿它去 fire 码 4，子集里不许留空值）。
  let fresh = cc_actor_ids_to_insert(self.find_cc_actors(instance_id), actor_ids)
  if !fresh.is_empty() {
    self.create_cc_instance(instance_id, creator, fresh)
  }
  fresh
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn update_cc_status(self, instance_id, actor_id) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_cc_instance SET state=1 WHERE process_instance_id=? AND actor_id=?",
    [@moondb.Int64(instance_id), @moondb.Text(actor_id)],
  )
  close_conn(conn)
}
