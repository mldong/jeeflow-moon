// MySQL 仓储连接层 —— 每操作连接即取即用（方案 §2.3，autocommit，行为等同 rust 现状）
// vendored moon-mysql async MysqlConn（D-M0-2）；凭据只走 JEFFLOW_DB_* env（R6）。

///|
pub(all) struct MysqlConfig {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
pub fn MysqlConfig::from_env() -> MysqlConfig raise {
  let host = @env.get_env_var("JEFFLOW_DB_HOST").unwrap_or("192.168.1.160")
  let port = match @env.get_env_var("JEFFLOW_DB_PORT") {
    Some(s) =>
      match (try? @string.parse_int(s)) {
        Ok(p) => p
        Err(_) => 3306
      }
    None => 3306
  }
  let user = @env.get_env_var("JEFFLOW_DB_USER").unwrap_or("root")
  let password = @env.get_env_var("JEFFLOW_DB_PWD").unwrap_or("")
  let database = @env.get_env_var("JEFFLOW_DB_NAME").unwrap_or("jeeflow")
  { host, port, user, password, database }
}

///|
async fn open_conn(self : MysqlConfig) -> @client.MysqlConn raise @error.JeeflowError {
  let outcome = try? @client.MysqlConn::connect(self.host, self.port, self.user, self.password, self.database)
  match outcome {
    Ok(conn) => conn
    Err(e) => raise @error.Internal("mysql connect: \{e}")
  }
}

///|
/// 打开连接（错误归一；事务态复用环境连接且不 close，见 tx.mbt）
async fn open(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  let outcome = try? self.config.open_conn()
  match outcome {
    Ok(conn) => conn
    Err(e) => raise e
  }
}

///|
/// 事务感知 close：事务连接归还模板管理
pub fn close_conn(conn : @client.MysqlConn) -> Unit {
  match tx_conn.val {
    Some(_) => () // 事务连接由模板 close
    None => conn.close()
  }
}

///|
/// query 归一助手
pub async fn q(
  conn : @client.MysqlConn,
  sql : String,
  params : Array[@moondb.Value]
) -> Array[@moondb.Row] raise @error.JeeflowError {
  let outcome = try? conn.query(sql, params)
  match outcome {
    Ok(rows) => rows
    Err(e) => raise @error.Internal("mysql query: \{e}")
  }
}

///|
/// execute 归一助手
pub async fn x(
  conn : @client.MysqlConn,
  sql : String,
  params : Array[@moondb.Value]
) -> @moondb.ExecResult raise @error.JeeflowError {
  let outcome = try? conn.execute(sql, params)
  match outcome {
    Ok(r) => r
    Err(e) => raise @error.Internal("mysql execute: \{e}")
  }
}

///|
/// 进程内雪花 id（对齐 rust SqlxRepository default_id_gen：worker 1；规范表无 AUTO_INCREMENT）
pub fn next_snowflake_id() -> Int64 {
  (snowflake_singleton.val)()
}

///|
let snowflake_singleton : Ref[(() -> Int64)] = Ref::new(fn() -> Int64 {
  let gen = @id_gen.DefaultIdGenerator::new(1L)
  gen.next_id()
})

///|
/// 注入集成方 id 生成器（对齐 rust with_id_gen）
pub fn set_snowflake_id_gen(f : () -> Int64) -> Unit {
  snowflake_singleton.val = f
}

// ── Row NULL 安全读取器（C21：NULL→零值；DATETIME 走文本解析）──

///|
fn value_to_text(v : @moondb.Value) -> String? {
  match v {
    Null => None
    Text(s) => Some(s)
    Blob(b) => Some(@utf8.decode_lossy(b[:]))
    Int64(n) => Some(n.to_string())
    Int(n) => Some(n.to_string())
    Double(d) => Some(d.to_string())
    Bool(b) => Some(if b { "1" } else { "0" })
  }
}

///|
fn row_text(r : @moondb.Row, col : String, default : String) -> String {
  match r.by_name(col) {
    Some(v) =>
      match value_to_text(v) {
        Some(s) => s
        None => default
      }
    None => default
  }
}

///|
fn row_opt_text(r : @moondb.Row, col : String) -> String? {
  match r.by_name(col) {
    Some(v) => value_to_text(v)
    None => None
  }
}

///|
pub fn row_i64(r : @moondb.Row, col : String) -> Int64 {
  match r.by_name(col) {
    Some(v) =>
      match v {
        Int64(n) => n
        Int(n) => n.to_int64()
        Double(d) => d.to_int64()
        Text(s) =>
          match (try? @string.parse_int64(s)) {
            Ok(n) => n
            Err(_) => 0L
          }
        _ => 0L
      }
    None => 0L
  }
}

///|
fn row_opt_i64(r : @moondb.Row, col : String) -> Int64? {
  match r.by_name(col) {
    Some(Null) | None => None
    Some(v) => Some(match v {
      Int64(n) => n
      Int(n) => n.to_int64()
      Double(d) => d.to_int64()
      Text(s) =>
        match (try? @string.parse_int64(s)) {
          Ok(n) => n
          Err(_) => 0L
        }
      _ => 0L
    })
  }
}

///|
fn row_int(r : @moondb.Row, col : String, default : Int) -> Int {
  match row_opt_i64(r, col) {
    Some(n) => n.to_int()
    None => default
  }
}

///|
fn row_opt_int(r : @moondb.Row, col : String) -> Int? {
  match row_opt_i64(r, col) {
    Some(n) => Some(n.to_int())
    None => None
  }
}

///|
/// DATETIME 文本归一：text 协议回 "2026-09-05 12:34:56[.fff]" → 截 19 位（C7：yyyy-MM-dd HH:mm:ss）
fn norm_datetime(s : String) -> String {
  if s.length() > 19 {
    s.substring(start=0, end=19).to_string()
  } else {
    s
  }
}

///|
fn row_opt_datetime(r : @moondb.Row, col : String) -> String? {
  match row_opt_text(r, col) {
    Some(s) =>
      if s.is_empty() {
        None
      } else {
        Some(norm_datetime(s))
      }
    None => None
  }
}

///|
/// BLOB → 文本（流程 content 列）
fn row_blob_text(r : @moondb.Row, col : String) -> String {
  match r.by_name(col) {
    Some(v) =>
      match v {
        Blob(b) => @utf8.decode_lossy(b[:])
        Text(s) => s
        _ => ""
      }
    None => ""
  }
}

///|
/// FlowData JSON 文本 → FlowData（坏 JSON 静默回空，对齐 rust parse_flow_data）
fn parse_flow_data(s : String?) -> @json.FlowData {
  let fd = @json.FlowData::new()
  match s {
    Some(text) => {
      let outcome = try? @json.parse_json(text)
      match outcome {
        Ok(Json::Object(m)) =>
          for k, v in m {
            fd.insert(k, v)
          }
        _ => ()
      }
    }
    None => ()
  }
  fd
}

///|
/// FlowData → JSON 文本（空对象序列化 "{}"，对齐 rust flow_data_to_json）
fn flow_data_to_json(fd : @json.FlowData) -> String {
  @json.stringify(fd.to_object_json())
}

///|
/// Option[String] → 绑定值：None→NULL；空串仅对 datetime 非法，统一 None/空串→NULL（对齐 rust bind Option）
pub fn opt_v(s : String?) -> @moondb.Value {
  match s {
    Some(t) => if t.is_empty() { @moondb.Null } else { @moondb.Text(t) }
    None => @moondb.Null
  }
}

///|
/// 分页边界（C22）
fn page_bounds(query : @model.PageQuery) -> (Int64, Int64, Int64) {
  let page_num = if query.page_num() < 1L { 1L } else { query.page_num() }
  let page_size = if query.page_size() < 1L { 20L } else { query.page_size() }
  let offset = (page_num - 1L) * page_size
  (page_num, page_size, offset)
}

///|
/// LIMIT/OFFSET 内联非负整数（C21：占位符在 MySQL prepare 文本协议路径不可靠）
fn sql_escape_text(s : String) -> String {
  // 文本协议 + 绑定参数下仅防御性转义反斜杠/引号（id 列内联已保证为整数）
  let b = StringBuilder::new()
  for ch in s {
    if ch == '\\' || ch == '\'' || ch == '"' {
      b.write_char('\\')
    }
    b.write_char(ch)
  }
  b.to_string()
}

///|
fn map_design(r : @moondb.Row) -> @model.ProcessDesign {
  {
    id: row_i64(r, "id"),
    name: row_text(r, "name", ""),
    display_name: row_text(r, "display_name", ""),
    design_type: row_text(r, "type", "approval"),
    icon: row_opt_text(r, "icon"),
    is_deployed: row_int(r, "is_deployed", 0),
    remark: row_opt_text(r, "remark"),
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
  }
}

///|
fn map_surrogate(r : @moondb.Row) -> @model.ProcessSurrogate {
  {
    id: row_i64(r, "id"),
    process_name: row_text(r, "process_name", ""),
    operator: row_text(r, "operator", ""),
    surrogate: row_text(r, "surrogate", ""),
    start_time: row_opt_datetime(r, "start_time"),
    end_time: row_opt_datetime(r, "end_time"),
    enabled: row_int(r, "enabled", 1),
    create_time: row_opt_datetime(r, "create_time"),
    create_user: row_opt_text(r, "create_user"),
    update_time: row_opt_datetime(r, "update_time"),
    update_user: row_opt_text(r, "update_user"),
  }
}
