// MySQL 仓储 IProcessRepository 全 24 方法 —— 移植自 rust repository-sqlx/lib.rs
// SQL 与 rust/java 编辑源同款；每操作独立连接（autocommit，方案 §2.3）。

///|
pub(all) struct MysqlRepository {
  config : MysqlConfig
}

///|
pub fn MysqlRepository::make(config : MysqlConfig) -> MysqlRepository {
  { config }
}

///|
pub fn MysqlRepository::from_env() -> MysqlRepository raise {
  { config: MysqlConfig::from_env() }
}

///|
/// 测试/工具用裸连接（绕过事务环境，始终新开；调用方负责 close）
pub async fn MysqlRepository::open_raw(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  let outcome = try? self.config.open_conn()
  match outcome {
    Ok(conn) => conn
    Err(e) => raise e
  }
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
pub impl @spi.ProcessRepository for MysqlRepository with fn save_define(self, define) {
  if define.id == 0L {
    define.id = next_snowflake_id()
  }
  if define.create_time is None {
    define.create_time = Some(@model.current_time_str())
  }
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_define (id, name, display_name, type, state, content, version, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(define.id),
      @moondb.Text(define.name),
      @moondb.Text(define.display_name),
      @moondb.Text(define.define_type),
      @moondb.Int(define.state),
      @moondb.Text(define.content),
      @moondb.Int(define.version),
      opt_v(define.create_time),
      opt_v(define.create_user),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn update_define(self, define) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_define SET display_name=?, type=?, state=?, content=?, version=?, update_user=? WHERE id=?",
    [
      @moondb.Text(define.display_name),
      @moondb.Text(define.define_type),
      @moondb.Int(define.state),
      @moondb.Text(define.content),
      @moondb.Int(define.version),
      opt_v(define.update_user),
      @moondb.Int64(define.id),
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
    tasks: [],
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
    define: None,
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
pub impl @spi.ProcessRepository for MysqlRepository with fn update_instance(self, instance) {
  let var_json = flow_data_to_json(instance.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_instance SET state=?, variable=?, update_time=NOW() WHERE id=?",
    [
      @moondb.Int(instance.state),
      @moondb.Text(var_json),
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
async fn hydrate_tasks(self : MysqlRepository, rows : Array[@moondb.Row]) -> Array[@model.ProcessTask] raise @error.JeeflowError {
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
    "INSERT INTO wf_process_task (id, process_instance_id, task_name, display_name, task_type, perform_type, task_state, operator, expire_time, form_key, task_parent_id, variable, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(task.task_id),
      @moondb.Int64(task.process_instance_id),
      @moondb.Text(task.task_name),
      @moondb.Text(task.display_name),
      @moondb.Int(task.task_type),
      @moondb.Int(task.perform_type),
      @moondb.Int(task.task_state),
      opt_v(task.actor_id),
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
pub impl @spi.ProcessRepository for MysqlRepository with fn update_task(self, task) {
  let var_json = flow_data_to_json(task.variables)
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_task SET task_state=?, operator=?, finish_time=?, variable=?, update_time=NOW() WHERE id=?",
    [
      @moondb.Int(task.task_state),
      opt_v(task.actor_id),
      opt_v(task.finish_time),
      @moondb.Text(var_json),
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
    let b = StringBuilder::new()
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
    let b = StringBuilder::new()
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
pub impl @spi.ProcessRepository for MysqlRepository with fn add_task_actor(self, task_id, actors) {
  // 去重追加（C14：非全删全插）
  let conn = self.open_or_tx()
  for actor in actors {
    let exists = q(conn, 
      "SELECT id FROM wf_process_task_actor WHERE process_task_id = ? AND actor_id = ? LIMIT 1",
      [@moondb.Int64(task_id), @moondb.Text(actor)],
    )
    if exists.is_empty() {
      let _ = x(conn, 
        "INSERT INTO wf_process_task_actor (id, process_task_id, actor_id, create_time, create_user) VALUES (?, ?, ?, NOW(), 'system')",
        [@moondb.Int64(next_snowflake_id()), @moondb.Int64(task_id), @moondb.Text(actor)],
      )
    }
  }
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn remove_task_actor(self, task_id, actors) {
  let conn = self.open_or_tx()
  for actor in actors {
    let _ = x(conn, 
      "DELETE FROM wf_process_task_actor WHERE process_task_id = ? AND actor_id = ?",
      [@moondb.Int64(task_id), @moondb.Text(actor)],
    )
  }
  close_conn(conn)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn create_cc_instance(self, instance_id, creator, actor_ids) {
  let conn = self.open_or_tx()
  for actor_id in actor_ids {
    let _ = x(conn, 
      "INSERT INTO wf_process_cc_instance (id, process_instance_id, actor_id, state, create_time, create_user) VALUES (?, ?, ?, 0, NOW(), ?)",
      [
        @moondb.Int64(next_snowflake_id()),
        @moondb.Int64(instance_id),
        @moondb.Text(actor_id),
        @moondb.Text(creator),
      ],
    )
  }
  close_conn(conn)
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
