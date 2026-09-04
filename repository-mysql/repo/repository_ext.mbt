// MySQL 仓储 IProcessExtRepository（design/his/surrogate 14 方法）

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn find_design_by_id(self, design_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, name, display_name, type, icon, is_deployed, remark, create_time, create_user, update_time, update_user FROM wf_process_design WHERE id = ?",
    [@moondb.Int64(design_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  let r = rows[0]
  Some(map_design(r))
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn save_design(self, design) {
  if design.id == 0L {
    design.id = next_snowflake_id()
  }
  if design.create_time is None {
    design.create_time = Some(@model.current_time_str())
  }
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_design (id, name, display_name, type, icon, is_deployed, remark, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(design.id),
      @moondb.Text(design.name),
      @moondb.Text(design.display_name),
      @moondb.Text(design.design_type),
      opt_v(design.icon),
      @moondb.Int(design.is_deployed),
      opt_v(design.remark),
      opt_v(design.create_time),
      opt_v(design.create_user),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn update_design(self, design) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_design SET display_name=?, type=?, icon=?, is_deployed=?, remark=?, update_time=NOW(), update_user=? WHERE id=?",
    [
      @moondb.Text(design.display_name),
      @moondb.Text(design.design_type),
      opt_v(design.icon),
      @moondb.Int(design.is_deployed),
      opt_v(design.remark),
      opt_v(design.update_user),
      @moondb.Int64(design.id),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn remove_design(self, design_id) {
  let conn = self.open_or_tx()
  let _ = x(conn, "DELETE FROM wf_process_design WHERE id=?", [@moondb.Int64(design_id)])
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn page_designs(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let conn = self.open_or_tx()
  let count_rows = q(conn, "SELECT COUNT(*) AS cnt FROM wf_process_design", [])
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let rows = q(conn, 
    "SELECT id, name, display_name, type, icon, is_deployed, remark, create_time, create_user, update_time, update_user FROM wf_process_design ORDER BY id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string(),
    [],
  )
  close_conn(conn)
  let out : Array[@model.ProcessDesign] = []
  for r in rows {
    out.push(map_design(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn save_design_his(self, his) {
  if his.id == 0L {
    his.id = next_snowflake_id()
  }
  if his.create_time is None {
    his.create_time = Some(@model.current_time_str())
  }
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_design_his (id, process_design_id, content, create_time, create_user) VALUES (?, ?, ?, ?, ?)",
    [
      @moondb.Int64(his.id),
      @moondb.Int64(his.process_design_id),
      @moondb.Text(his.content),
      opt_v(his.create_time),
      opt_v(his.create_user),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn list_design_his(self, design_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, process_design_id, content, create_time, create_user FROM wf_process_design_his WHERE process_design_id = ? ORDER BY id DESC",
    [@moondb.Int64(design_id)],
  )
  close_conn(conn)
  let out : Array[@model.ProcessDesignHis] = []
  for r in rows {
    out.push({
      id: row_i64(r, "id"),
      process_design_id: row_i64(r, "process_design_id"),
      content: row_blob_text(r, "content"),
      create_time: row_opt_datetime(r, "create_time"),
      create_user: row_opt_text(r, "create_user"),
    })
  }
  out
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn find_surrogate_by_id(self, surrogate_id) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, process_name, operator, surrogate, start_time, end_time, enabled, create_time, create_user, update_time, update_user FROM wf_process_surrogate WHERE id = ?",
    [@moondb.Int64(surrogate_id)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  Some(map_surrogate(rows[0]))
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn save_surrogate(self, surrogate) {
  if surrogate.id == 0L {
    surrogate.id = next_snowflake_id()
  }
  if surrogate.create_time is None {
    surrogate.create_time = Some(@model.current_time_str())
  }
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "INSERT INTO wf_process_surrogate (id, process_name, operator, surrogate, start_time, end_time, enabled, create_time, create_user) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      @moondb.Int64(surrogate.id),
      @moondb.Text(surrogate.process_name),
      @moondb.Text(surrogate.operator),
      @moondb.Text(surrogate.surrogate),
      opt_v(surrogate.start_time),
      opt_v(surrogate.end_time),
      @moondb.Int(surrogate.enabled),
      opt_v(surrogate.create_time),
      opt_v(surrogate.create_user),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn update_surrogate(self, surrogate) {
  let conn = self.open_or_tx()
  let _ = x(conn, 
    "UPDATE wf_process_surrogate SET process_name=?, operator=?, surrogate=?, start_time=?, end_time=?, enabled=?, update_time=NOW(), update_user=? WHERE id=?",
    [
      @moondb.Text(surrogate.process_name),
      @moondb.Text(surrogate.operator),
      @moondb.Text(surrogate.surrogate),
      opt_v(surrogate.start_time),
      opt_v(surrogate.end_time),
      @moondb.Int(surrogate.enabled),
      opt_v(surrogate.update_user),
      @moondb.Int64(surrogate.id),
    ],
  )
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn remove_surrogate(self, surrogate_id) {
  let conn = self.open_or_tx()
  let _ = x(conn, "DELETE FROM wf_process_surrogate WHERE id=?", [@moondb.Int64(surrogate_id)])
  close_conn(conn)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn page_surrogates(self, query) {
  let (page_num, page_size, offset) = page_bounds(query)
  let conn = self.open_or_tx()
  let count_rows = q(conn, "SELECT COUNT(*) AS cnt FROM wf_process_surrogate", [])
  let total = if count_rows.is_empty() { 0L } else { row_i64(count_rows[0], "cnt") }
  let rows = q(conn, 
    "SELECT id, process_name, operator, surrogate, start_time, end_time, enabled, create_time, create_user, update_time, update_user FROM wf_process_surrogate ORDER BY id DESC LIMIT " + page_size.to_string() + " OFFSET " + offset.to_string(),
    [],
  )
  close_conn(conn)
  let out : Array[@model.ProcessSurrogate] = []
  for r in rows {
    out.push(map_surrogate(r))
  }
  @model.PageResult::new(page_num, page_size, total, out)
}

///|
pub impl @spi.ProcessExtRepository for MysqlRepository with fn get_surrogate(self, operator, process_name, _time) {
  let conn = self.open_or_tx()
  let rows = q(conn, 
    "SELECT id, process_name, operator, surrogate, start_time, end_time, enabled, create_time, create_user, update_time, update_user FROM wf_process_surrogate WHERE operator = ? AND process_name = ? AND enabled = 1 ORDER BY id DESC LIMIT 1",
    [@moondb.Text(operator), @moondb.Text(process_name)],
  )
  close_conn(conn)
  if rows.is_empty() {
    return None
  }
  Some(map_surrogate(rows[0]))
}
