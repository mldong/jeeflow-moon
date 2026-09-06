// MySQL 仓储分页方法（五键 + operator 过滤 + m_ 条件）+ stats 批量查询

///|
fn task_row_of_mysql(r : @moondb.Row) -> @model.TaskRow {
  let row = @model.TaskRow::new_empty()
  row.id = row_i64(r, "id")
  row.process_instance_id = row_i64(r, "process_instance_id")
  row.task_name = row_text(r, "task_name", "")
  row.display_name = row_text(r, "display_name", "")
  row.task_type = row_int(r, "task_type", 0)
  row.perform_type = row_int(r, "perform_type", 0)
  row.task_state = row_int(r, "task_state", 0)
  row.operator = row_opt_text(r, "operator")
  row.actor_id = row_opt_text(r, "actor_id")
  row.finish_time = row_opt_datetime(r, "finish_time")
  row.expire_time = row_opt_datetime(r, "expire_time")
  row.form_key = row_opt_text(r, "form_key")
  row.task_parent_id = row_opt_i64(r, "task_parent_id")
  row.variable = row_opt_text(r, "variable")
  row.create_time = row_opt_datetime(r, "create_time")
  row.create_user = row_opt_text(r, "create_user")
  row.update_time = row_opt_datetime(r, "update_time")
  row.update_user = row_opt_text(r, "update_user")
  row.process_define_id = row_opt_i64(r, "process_define_id")
  row.instance_state = row_opt_int(r, "instance_state")
  row.instance_operator = row_opt_text(r, "instance_operator")
  row.business_no = row_opt_text(r, "business_no")
  row.instance_variable = row_opt_text(r, "instance_variable")
  row.instance_create_time = row_opt_datetime(r, "instance_create_time")
  row.define_name = row_opt_text(r, "define_name")
  row.define_display_name = row_opt_text(r, "define_display_name")
  row.define_version = row_opt_int(r, "define_version")
  row
}

///|
fn instance_row_of_mysql(r : @moondb.Row) -> @model.InstanceRow {
  let row = @model.InstanceRow::new_empty()
  row.id = row_i64(r, "id")
  row.parent_id = row_opt_i64(r, "parent_id")
  row.process_define_id = row_i64(r, "process_define_id")
  row.state = row_int(r, "state", 0)
  row.parent_node_name = row_opt_text(r, "parent_node_name")
  row.business_no = row_opt_text(r, "business_no")
  row.operator = row_text(r, "operator", "")
  row.expire_time = row_opt_datetime(r, "expire_time")
  row.variable = row_opt_text(r, "variable")
  row.create_time = row_opt_datetime(r, "create_time")
  row.create_user = row_opt_text(r, "create_user")
  row.update_time = row_opt_datetime(r, "update_time")
  row.update_user = row_opt_text(r, "update_user")
  row.define_name = row_opt_text(r, "define_name")
  row.define_display_name = row_opt_text(r, "define_display_name")
  row.define_version = row_opt_int(r, "define_version")
  row
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn page_todo_tasks(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let (m_where, m_params) = @query.build_m_where(query.filters())
  let operator = query.operator()
  let conn = self.open_or_tx()
  let count_sql = "SELECT COUNT(DISTINCT t.id) AS cnt FROM wf_process_task t LEFT JOIN wf_process_task_actor ta ON ta.process_task_id = t.id WHERE t.task_state = 10" + m_where + (match operator {
    Some(_) => " AND ta.actor_id = ?"
    None => ""
  })
  let count_params : Array[@moondb.Value] = []
  for p in m_params {
    count_params.push(p)
  }
  match operator {
    Some(op) => count_params.push(@moondb.Text(op))
    None => ()
  }
  let count_rows = q(conn, count_sql, count_params)
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let sql = "SELECT DISTINCT t.id, t.process_instance_id, t.task_name, t.display_name, t.task_type, t.perform_type, t.task_state, t.operator AS actor_id, t.finish_time, t.expire_time, t.form_key, t.task_parent_id, t.variable, t.create_time, t.create_user, t.update_time, t.update_user, pi.process_define_id, pi.state AS instance_state, pi.operator AS instance_operator, pi.business_no, pi.variable AS instance_variable, pi.create_time AS instance_create_time, pd.name AS define_name, pd.display_name AS define_display_name, pd.version AS define_version FROM wf_process_task t LEFT JOIN wf_process_task_actor ta ON ta.process_task_id = t.id LEFT JOIN wf_process_instance pi ON pi.id = t.process_instance_id LEFT JOIN wf_process_define pd ON pd.id = pi.process_define_id WHERE t.task_state = 10" + m_where + (match operator {
      Some(op) => " AND ta.actor_id = ?"
      None => ""
    }) + " ORDER BY t.id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string()
  let params : Array[@moondb.Value] = []
  for p in m_params {
    params.push(p)
  }
  match operator {
    Some(op) => params.push(@moondb.Text(op))
    None => ()
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  let out : Array[@model.TaskRow] = []
  for r in rows {
    out.push(task_row_of_mysql(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn page_done_tasks(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let (m_where, m_params) = @query.build_m_where(query.filters())
  let operator = query.operator()
  let conn = self.open_or_tx()
  // doneList「我的」口径对齐 java t.operator EQ（issues/107：不含发起人 create_user）
  let count_sql = "SELECT COUNT(*) AS cnt FROM wf_process_task t WHERE t.task_state = 20" + m_where + (match operator {
    Some(_) => " AND t.operator = ?"
    None => ""
  })
  let count_params : Array[@moondb.Value] = []
  for p in m_params {
    count_params.push(p)
  }
  match operator {
    Some(op) => {
      count_params.push(@moondb.Text(op))
    }
    None => ()
  }
  let count_rows = q(conn, count_sql, count_params)
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let sql = "SELECT t.id, t.process_instance_id, t.task_name, t.display_name, t.task_type, t.perform_type, t.task_state, t.operator, t.finish_time, t.expire_time, t.form_key, t.task_parent_id, t.variable, t.create_time, t.create_user, t.update_time, t.update_user, pi.process_define_id, pi.state AS instance_state, pi.operator AS instance_operator, pi.business_no, pi.variable AS instance_variable, pi.create_time AS instance_create_time, pd.name AS define_name, pd.display_name AS define_display_name, pd.version AS define_version FROM wf_process_task t LEFT JOIN wf_process_instance pi ON pi.id = t.process_instance_id LEFT JOIN wf_process_define pd ON pd.id = pi.process_define_id WHERE t.task_state = 20" + m_where + (match operator {
      Some(op) => " AND t.operator = ?"
      None => ""
    }) + " ORDER BY t.id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string()
  let params : Array[@moondb.Value] = []
  for p in m_params {
    params.push(p)
  }
  match operator {
    Some(op) => {
      params.push(@moondb.Text(op))
    }
    None => ()
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  let out : Array[@model.TaskRow] = []
  for r in rows {
    out.push(task_row_of_mysql(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn page_instances(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let (m_where, m_params) = @query.build_m_where(query.filters())
  let operator = query.operator()
  let conn = self.open_or_tx()
  let count_sql = "SELECT COUNT(*) AS cnt FROM wf_process_instance pi WHERE 1=1" + m_where + (match operator {
    Some(_) => " AND pi.operator = ?"
    None => ""
  })
  let count_params : Array[@moondb.Value] = []
  for p in m_params {
    count_params.push(p)
  }
  match operator {
    Some(op) => count_params.push(@moondb.Text(op))
    None => ()
  }
  let count_rows = q(conn, count_sql, count_params)
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let sql = "SELECT pi.id, pi.parent_id, pi.process_define_id, pi.state, pi.parent_node_name, pi.business_no, pi.operator, pi.expire_time, pi.variable, pi.create_time, pi.create_user, pi.update_time, pi.update_user, pd.name AS define_name, pd.display_name AS define_display_name, pd.version AS define_version FROM wf_process_instance pi LEFT JOIN wf_process_define pd ON pd.id = pi.process_define_id WHERE 1=1" + m_where + (match operator {
      Some(op) => " AND pi.operator = ?"
      None => ""
    }) + " ORDER BY pi.id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string()
  let params : Array[@moondb.Value] = []
  for p in m_params {
    params.push(p)
  }
  match operator {
    Some(op) => params.push(@moondb.Text(op))
    None => ()
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  let out : Array[@model.InstanceRow] = []
  for r in rows {
    out.push(instance_row_of_mysql(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn page_cc_instances(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let operator = query.operator()
  let conn = self.open_or_tx()
  let count_sql = "SELECT COUNT(DISTINCT pi.id) AS cnt FROM wf_process_cc_instance cc JOIN wf_process_instance pi ON pi.id = cc.process_instance_id WHERE 1=1" + (match operator {
      Some(_) => " AND cc.actor_id = ?"
      None => ""
    })
  let count_params : Array[@moondb.Value] = []
  match operator {
    Some(op) => count_params.push(@moondb.Text(op))
    None => ()
  }
  let count_rows = q(conn, count_sql, count_params)
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let sql = "SELECT DISTINCT pi.id, pi.parent_id, pi.process_define_id, pi.state, pi.parent_node_name, pi.business_no, cc.actor_id AS operator, pi.expire_time, NULL AS variable, cc.create_time, cc.create_user, cc.update_time, cc.update_user, pd.name AS define_name, pd.display_name AS define_display_name, pd.version AS define_version FROM wf_process_cc_instance cc JOIN wf_process_instance pi ON pi.id = cc.process_instance_id LEFT JOIN wf_process_define pd ON pd.id = pi.process_define_id WHERE 1=1" + (match operator {
      Some(_) => " AND cc.actor_id = ?"
      None => ""
    }) + " ORDER BY pi.id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string()
  let params : Array[@moondb.Value] = []
  match operator {
    Some(op) => params.push(@moondb.Text(op))
    None => ()
  }
  let rows = q(conn, sql, params)
  close_conn(conn)
  let out : Array[@model.InstanceRow] = []
  for r in rows {
    out.push(instance_row_of_mysql(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn page_defines(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let (m_where_raw, m_params) = @query.build_m_where(query.filters())
  // 主表别名解析：m_ 默认别名 t → page_defines 主表实际是 pd（java t-白名单同义）
  let m_where = m_where_raw.replace(old=" AND t.", new=" AND pd.")
  let conn = self.open_or_tx()
  let count_sql = "SELECT COUNT(*) AS cnt FROM wf_process_define pd WHERE 1=1" + m_where
  let count_params : Array[@moondb.Value] = []
  for p in m_params {
    count_params.push(p)
  }
  let count_rows = q(conn, count_sql, count_params)
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let sql = "SELECT pd.id, pd.name, pd.display_name, pd.type, pd.state, pd.version, pd.create_time, pd.create_user, pd.update_time, pd.update_user FROM wf_process_define pd WHERE 1=1" + m_where + " ORDER BY pd.id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string()
  let rows = q(conn, sql, m_params)
  close_conn(conn)
  let out : Array[@model.DefineRow] = []
  for r in rows {
    let row = @model.DefineRow::new_empty()
    row.id = row_i64(r, "id")
    row.name = row_text(r, "name", "")
    row.display_name = row_text(r, "display_name", "")
    row.define_type = row_text(r, "type", "approval")
    row.state = row_int(r, "state", 0)
    row.version = row_int(r, "version", 1)
    row.create_time = row_opt_datetime(r, "create_time")
    row.create_user = row_opt_text(r, "create_user")
    row.update_time = row_opt_datetime(r, "update_time")
    row.update_user = row_opt_text(r, "update_user")
    out.push(row)
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn count_todo_tasks(self, user_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT COUNT(DISTINCT t.id) AS cnt FROM wf_process_task t JOIN wf_process_task_actor ta ON ta.process_task_id = t.id WHERE t.task_state = 10 AND ta.actor_id = ?",
    [@moondb.Text(user_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    0L
  } else {
    row_i64(rows[0], "cnt")
  }
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn get_all_instances(self) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, parent_id, process_define_id, state, parent_node_name, business_no, operator, expire_time, variable, create_time, create_user, update_time, update_user FROM wf_process_instance",
    [],
  )
  close_conn(conn)
  let out : Array[@model.ProcessInstance] = []
  for r in rows {
    out.push({
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
  out
}

///|
pub impl @spi.ProcessRepository for MysqlRepository with fn get_all_tasks(self) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT " + task_columns + " FROM wf_process_task",
    [],
  )
  close_conn(conn)
  self.hydrate_tasks(rows)
}
