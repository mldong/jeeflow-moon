// issues/149：`DynamicTableWriter` 的真库落点（persist 业务表写）。
//
// 为什么必须 async：本栈写真库只有 moonmysql 的 async 连接这一条路，同步形状发不出查询
// （145-6 记的机理、149 §1 的病灶）。⇒ 形状改动＝trait 六法加 async；`impl … with fn` 不重复
// 写 async（实测写了判 parse error），所以 `InMemoryTableWriter` 与六处 `&DynamicTableWriter`
// 调用点都不用改。
//
// 为什么事务能包住业务表：本 writer **不自建事务机制**，而是握着调用方的 `MysqlRepository`
// 实例，走它的 `open_or_tx()/close_conn()`（spec/05 连接级 + issues/144「句柄随实例走」那条判据）。
// 于是 `execute_in_tx` 回调里 writer 写的业务表行与四张 `wf_*` 表在同一条连接、同一事务，
// 中途抛错一起回滚——`spec/12` §12.2 覆盖面那条从此在本栈可执行。
// `detached` 另起一个空事务槽 ⇒ 每句自取连接、autocommit，它是案 §5-3 阳性对照的夹具形状
// （"业务表写挪到事务外 ⇒ 原子档必须红"），不是给集成方的装配口。

///|
pub(all) struct MysqlTableWriter {
  repo : MysqlRepository
  /// 列匹配档（issues/151 X3，java `setStrictColumnMatch` 同位）：`false`＝缺省宽松
  /// （驼峰↔下划线归一），`true`＝忽略大小写的逐字相等。
  strict : Bool
}

///|
/// 同事务装配口：一个请求＝一个仓储实例，writer 从它派生即共享该实例的事务槽
pub fn MysqlTableWriter::from_repo(repo : MysqlRepository) -> MysqlTableWriter {
  MysqlTableWriter::{ repo, strict: false }
}

///|
/// 严格列匹配档（java `setStrictColumnMatch(true)` 的同位）：集成方要"列名必须逐字对上才写"
/// 时用它，宽松档下撞名的表（同一张表里 `a_b` 与 `ab` 并存）才需要。
pub fn MysqlTableWriter::with_strict(
  self : MysqlTableWriter,
  strict : Bool
) -> MysqlTableWriter {
  MysqlTableWriter::{ repo: self.repo, strict }
}

///|
/// 独立连接档（autocommit）：只给阳性对照夹具用。
/// ⚠ 集成方拿它装配 persist 就等于放弃"业务表写与 wf_* 同事务"，别当默认口用。
pub fn MysqlTableWriter::detached(repo : MysqlRepository) -> MysqlTableWriter {
  MysqlTableWriter::{
    repo: MysqlRepository::{ config: repo.config, tx: Ref(None) }, strict: false
  }
}

///|
/// 表名闸：与内存实现同一枚判据（`sys_`/`wf_` 等保留前缀一律拒绝，issues/60 配置错误显性暴露）
fn check_table(table : String) -> Unit raise @error.JeeflowError {
  if !@persist.is_table_name_safe(table) {
    raise @error.Business("非法业务表名: \{table}")
  }
}

///|
/// 表实际存在的列。列名走占位符、结果集用**小写别名** `cname`
/// （MySQL 8 的 `information_schema` 列标签是大写，直取 `COLUMN_NAME` 会读空——moon 侧既有坑）。
async fn MysqlTableWriter::real_columns(
  self : MysqlTableWriter,
  conn : @client.MysqlConn,
  table : String
) -> Array[String] raise @error.JeeflowError {
  let _ = self
  let rows = q(
    conn,
    "SELECT COLUMN_NAME AS cname FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
    [@moondb.Text(table)],
  )
  let out : Array[String] = []
  for r in rows {
    let c = row_text(r, "cname", "")
    if !c.is_empty() {
      out.push(c)
    }
  }
  out
}

///|
/// Json → 绑定值。整数走 Int64（>2^53 不经过 double 取整，D-M5-3 同款判据），
/// 字符串/时间原样进占位符——值一律参数化，不做任何串拼接。
fn json_to_value(v : Json) -> @moondb.Value {
  match v {
    Json::Null => @moondb.Null
    Json::String(s) => @moondb.Text(s)
    Json::True => @moondb.Int(1)
    Json::False => @moondb.Int(0)
    // 整数优先看词法原文（repr 只出现在整数字面量上，纯数字由词法器保证 ⇒ 无注入面），
    // 与 query.mbt `value_to_string` 同一把尺子：>2^53 不经过 double 取整
    Json::Number(n, repr~) =>
      match repr {
        Some(t) =>
          try {
            @moondb.Int64(@string.parse_int64(t))
          } catch {
            _ => @moondb.Double(n)
          }
        None => {
          let i = n.to_int64()
          if n == i.to_double() { @moondb.Int64(i) } else { @moondb.Double(n) }
        }
      }
    _ => @moondb.Text(v.stringify())
  }
}

///|
/// 「列 ∩ 表结构」的落串：反引号只围**已从 information_schema 取回的真列名**，
/// 且表名过了 `check_table`（只允许字母数字下划线）⇒ 拼出来的标识符无注入面；
/// 值全部走占位符。
fn qualified(cols : Array[String]) -> String {
  let b = StringBuilder()
  for i, c in cols {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string("`")
    b.write_string(c)
    b.write_string("`")
  }
  b.to_string()
}

fn set_clause(cols : Array[String]) -> String {
  let b = StringBuilder()
  for i, c in cols {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string("`")
    b.write_string(c)
    b.write_string("`=?")
  }
  b.to_string()
}

///|
/// `?, ?, ?` 占位符组（个数由已过滤的真列数决定，不接外部输入）
fn marks(n : Int) -> String {
  let b = StringBuilder()
  for i in 0..<n {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string("?")
  }
  b.to_string()
}

///|
/// 「data ∩ 表列」成对取列（issues/151 X3 的落点）。
/// **遍历表列**而不是遍历 data（java `JdbcDynamicTableWriter.insert:109-116` 就是这个方向），
/// 于是：① 落进 SQL 反引号位的永远是真列名 ⇒ 宽松档下驼峰 data 键能写进下划线列；
/// ② 列序＝表结构序，与 java 同；③ 两个 data 键归一到同一列时，`find_data_key` 命中即停
/// ＝ data 插入序里的第一个键胜出（确定性规则，见 `persist.column_names_equal` 注释）。
/// `skip`＝条件列（java `update:169` 用忽略大小写的逐字相等排除，不参与 SET）。
fn MysqlTableWriter::collect(
  self : MysqlTableWriter,
  real : Array[String],
  data : Map[String, Json],
  skip~ : String?
) -> (Array[String], Array[@moondb.Value]) {
  let cols : Array[String] = []
  let vals : Array[@moondb.Value] = []
  let skip_lower = match skip {
    Some(s) => s.to_lower()
    None => ""
  }
  for col in real {
    if skip is Some(_) && skip_lower == col.to_lower() {
      ()
    } else {
      match @persist.find_data_key(data, col, strict=self.strict) {
        Some(k) => {
          cols.push(col)
          vals.push(json_to_value(data[k]))
        }
        None => ()
      }
    }
  }
  (cols, vals)
}

///|
/// INSERT：data 里不在表结构内的字段自动剔除（java `DynamicTableWriter.insert` 的同一义务）。
/// 返回主键：表有 `id` 列且 data 未给出 ⇒ 走本栈雪花（与仓储一致，规范表无 AUTO_INCREMENT）；
/// 表无 `id` 列 ⇒ 0L（内存实现在这一档给的是它自己的计数，两支都只被 `let _ =` 消费，
/// 不充当任何判据）。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn insert(self, table, data) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  let (cols, vals) = self.collect(real, data, skip=None)
  let mut new_id : Int64 = 0L
  // 主键列（issues/151 X3 之后按列匹配档探测，不再只认字面 `id`）：
  // data 已给值就用它，缺值走本栈雪花（规范表无 AUTO_INCREMENT，见 X9 那条留档）。
  match @persist.match_column(real, "id", strict=self.strict) {
    Some(id_col) =>
      match @persist.find_data_key(data, id_col, strict=self.strict) {
        Some(k) => new_id = json_as_i64_or(data[k], 0L)
        None => {
          new_id = next_snowflake_id()
          cols.push(id_col)
          vals.push(@moondb.Int64(new_id))
        }
      }
    None => ()
  }
  if cols.is_empty() {
    self.repo.close_conn(conn)
    raise @error.Business("persist 写侧无可写入列: \{table}")
  }
  let ph = marks(cols.length())
  let _ = x(
    conn,
    "INSERT INTO `\{table}` (\{qualified(cols)}) VALUES (\{ph})",
    vals,
  )
  self.repo.close_conn(conn)
  new_id
}

///|
/// 按主键 `id` 更新；行不存在 ⇒ 报错（文案与内存实现逐字同判据，两支不许各说各话）。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn update(self, table, id, data) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  let id_col = @persist.match_column(real, "id", strict=self.strict)
  match id_col {
    None => {
      self.repo.close_conn(conn)
      // 本栈 `update` 只有"按主键 id"这一条腿（trait 签名如此）⇒ 没有 id 列就没法定位行。
      // 旧形状在这里不做判断、直接把 `id` 拼进 SQL 撞出 1054 驱动错误；换成显性文案
      // （spec/09 §4.6「配置错误显性暴露」，与上面 `exists_by_key` 的"配错列不炸流程"同一档判据）。
      raise @error.Business("表 \{table} 无主键 id 列，无法按主键更新")
    }
    Some(col) => {
      let cnt = q(
        conn,
        "SELECT COUNT(*) AS c FROM `\{table}` WHERE `\{col}` = ?",
        [@moondb.Int64(id)],
      )
      if cnt.is_empty() || row_i64(cnt[0], "c") == 0L {
        self.repo.close_conn(conn)
        raise @error.Business("Row \{id} not found in \{table}")
      }
      let (cols, vals) = self.collect(real, data, skip=Some(col))
      match cols.length() {
        0 => ()
        _ => {
          vals.push(@moondb.Int64(id))
          let _ = x(
            conn,
            "UPDATE `\{table}` SET \{set_clause(cols)} WHERE `\{col}` = ?",
            vals,
          )
        }
      }
      self.repo.close_conn(conn)
    }
  }
}

///|
/// 主键存在性（表无主键 `id` 列 ⇒ 恒 false，与内存实现"取不到行"同档）。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn exists(self, table, id) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  let id_col = @persist.match_column(real, "id", strict=self.strict)
  match id_col {
    None => {
      self.repo.close_conn(conn)
      false
    }
    Some(col) => {
      let cnt = q(
        conn,
        "SELECT COUNT(*) AS c FROM `\{table}` WHERE `\{col}` = ?",
        [@moondb.Int64(id)],
      )
      self.repo.close_conn(conn)
      !cnt.is_empty() && row_i64(cnt[0], "c") > 0L
    }
  }
}

///|
/// 幂等检查（归档腿的 `process_instance_id` 先查后插）。列不存在 ⇒ false（内存实现取不到键
/// 也是 false），不许让"配错列名"退化成 SQL 报错把整次动作打掉。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn exists_by_key(self, table, key, value) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  match @persist.match_column(real, key, strict=self.strict) {
    None => {
      self.repo.close_conn(conn)
      false
    }
    Some(col) => {
      let cnt = q(
        conn,
        "SELECT COUNT(*) AS c FROM `\{table}` WHERE `\{col}` = ?",
        [@moondb.Int64(value)],
      )
      self.repo.close_conn(conn)
      !cnt.is_empty() && row_i64(cnt[0], "c") > 0L
    }
  }
}

///|
/// 按业务列更新（SYNC 腿的定稿/推进）。行不存在 ⇒ 报错，文案与内存实现逐字一致。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn update_by_key(self, table, data, key, value) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  let biz_col = @persist.match_column(real, key, strict=self.strict)
  match biz_col {
    None => {
      self.repo.close_conn(conn)
      raise @error.Business("Row with \{key}=\{value} not found in \{table}")
    }
    Some(col) => {
      let cnt = q(
        conn,
        "SELECT COUNT(*) AS c FROM `\{table}` WHERE `\{col}` = ?",
        [@moondb.Int64(value)],
      )
      if cnt.is_empty() || row_i64(cnt[0], "c") == 0L {
        self.repo.close_conn(conn)
        raise @error.Business("Row with \{key}=\{value} not found in \{table}")
      }
      let (cols, vals) = self.collect(real, data, skip=Some(col))
      match cols.length() {
        0 => ()
        _ => {
          vals.push(@moondb.Int64(value))
          let _ = x(
            conn,
            "UPDATE `\{table}` SET \{set_clause(cols)} WHERE `\{col}` = ?",
            vals,
          )
        }
      }
    }
  }
  self.repo.close_conn(conn)
}

///|
/// 列探测：候选 ∩ 表实际列，**保序去重**（java `filterColumns:90-99` 的同一判据——
/// 命中的是表列，**返回的仍是候选串**，因为调用方拿它当 data 的键用；状态字段
/// `{节点ID}_{状态码}` / `{节点ID}` 的择优就靠它——列不存在则不写，不炸流程）。
pub impl @persist.DynamicTableWriter for MysqlTableWriter with fn columns(self, table, candidates) {
  check_table(table)
  let conn = self.repo.open_or_tx()
  let real = self.real_columns(conn, table)
  self.repo.close_conn(conn)
  let out : Array[String] = []
  for c in candidates {
    let t = c.trim(chars=" \t\r\n").to_owned()
    if t.is_empty() {
      ()
    } else {
      match @persist.match_column(real, t, strict=self.strict) {
        Some(_) => if !out.contains(t) { out.push(t) }
        None => ()
      }
    }
  }
  out
}

///|
/// Json 里取整数（`id` 列已给出时用它，避免雪花覆盖集成方显式指定的主键）。
fn json_as_i64_or(v : Json, default : Int64) -> Int64 {
  match @json.as_i64(v) {
    Some(n) => n
    None => default
  }
}

// ── 显式 extend（implicit_impl_as_method 弃办）──
pub extend MysqlTableWriter with @persist.DynamicTableWriter::{
  columns, exists, exists_by_key, insert, update, update_by_key
}
