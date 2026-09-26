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
    "UPDATE wf_process_design SET display_name=?, type=?, icon=?, is_deployed=?, remark=?, update_time=?, update_user=? WHERE id=?",
    [
      @moondb.Text(design.display_name),
      @moondb.Text(design.design_type),
      opt_v(design.icon),
      @moondb.Int(design.is_deployed),
      opt_v(design.remark),
      now_v(),
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
    "UPDATE wf_process_surrogate SET process_name=?, operator=?, surrogate=?, start_time=?, end_time=?, enabled=?, update_time=?, update_user=? WHERE id=?",
    [
      @moondb.Text(surrogate.process_name),
      @moondb.Text(surrogate.operator),
      @moondb.Text(surrogate.surrogate),
      opt_v(surrogate.start_time),
      opt_v(surrogate.end_time),
      @moondb.Int(surrogate.enabled),
      now_v(),
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
/// 生效委托查询（issues/116 批次 D / spec 06 §4.5 条款 5 四判据 + 条款 6 双仓同答案）：
/// ① 空 processName 全流程兜底（先按名精确，未命中再查 process_name IS NULL OR = ''）；
/// ② 时间窗 start_time <= now <= end_time，NULL 视为该侧不限；
/// ③ 自委托过滤 surrogate <> operator；
/// ④ enabled = 1 才生效（0 / NULL / 其它脏值都不算启用）。
///
/// ⚠️ **条款 1.4 的取数顺序（issues/123）**：SQL **不带**任何生效判据（既没有
/// `enabled = 1`、也没有 `surrogate <> operator`、也没有窗口谓词），只有
/// `WHERE operator = ? [AND 作用域] ORDER BY id DESC LIMIT 1` —— 取该作用域**最新一条**，
/// 再交 `@model.ProcessSurrogate::is_effective` 裁决；精确作用域判否后**仍要看**全流程作用域
/// 的最新一条。反过来"先滤生效、剩下的才取最新"= "上一条窗内委托把用户后续改停用 /
/// 改到未来 / 改自委托永久盖掉"，正是 issues/123 里 13 栈 `L2-17`/`L2-18` 恒并入的成因。
/// 原实现更早的版本只有 `operator = ? AND process_name = ? AND enabled = 1`，
/// 连窗口/自委托/空名兜底都没有，与内存仓对同一份数据结论不同。
/// ⚠️ 四判据与 `core/memory/memory_ext.mbt` 的 get_surrogate **逐条同构**，改一处必改两处。
pub impl @spi.ProcessExtRepository for MysqlRepository with fn get_surrogate(self, operator, process_name, time) {
  let exact = self.newest_surrogate(operator, process_name, false)
  if @model.surrogate_scope_hit(exact, operator, time) {
    exact
  } else {
    // 精确作用域没有 / 有但判否，都仍要看全流程作用域自己那条最新的
    let global = self.newest_surrogate(operator, process_name, true)
    if @model.surrogate_scope_hit(global, operator, time) { global } else { None }
  }
}

///|
/// 取该授权人指定流程作用域内 **最新的一条**（`ORDER BY id DESC LIMIT 1`）；
/// scope_global=true ⇒ 全流程作用域（process_name IS NULL OR = ''）。
/// 不带生效判据，见上面 get_surrogate 的 ⚠️ 条款。
async fn MysqlRepository::newest_surrogate(
  self : MysqlRepository,
  operator : String,
  process_name : String,
  scope_global : Bool
) -> @model.ProcessSurrogate? raise @error.JeeflowError {
  // 空 processName 时"精确作用域"无定义（能匹配的只有 process_name 为空的行，
  // 那正是全流程作用域）——直接判无命中，交给调用方的第二轮兜底，少一次往返。
  if !scope_global && process_name.is_empty() {
    return None
  }
  let name_cond =
    if scope_global {
      " AND (process_name IS NULL OR process_name = '')"
    } else {
      " AND process_name = ?"
    }
  let sql = "SELECT id, process_name, operator, surrogate, start_time, end_time, enabled, create_time, create_user, update_time, update_user FROM wf_process_surrogate WHERE operator = ?" + name_cond + " ORDER BY id DESC LIMIT 1"
  let params : Array[@moondb.Value] = [@moondb.Text(operator)]
  if !scope_global {
    params.push(@moondb.Text(process_name))
  }
  let conn = self.open_or_tx()
  let rows = q(conn, sql, params)
  close_conn(conn)
  if rows.is_empty() {
    None
  } else {
    Some(map_surrogate(rows[0]))
  }
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend MysqlRepository with @spi.ProcessExtRepository::{find_design_by_id, find_surrogate_by_id, get_surrogate, list_design_his, page_designs, page_surrogates, remove_design, remove_surrogate, save_design, save_design_his, save_surrogate, update_design, update_surrogate}
