// m_ 三段式参数解析 + 分页 SQL 组装 —— 移植自 java JeeflowQueryParser（issues/85 rust 缺失件）

///|
/// camelCase → snake_case
pub fn to_underscore(camel : String) -> String {
  let b = StringBuilder::new()
  for ch in camel {
    let code = ch.to_int()
    if code >= 65 && code <= 90 {
      b.write_char('_')
      b.write_char(Char::from_int(code + 32))
    } else {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
/// 解析请求参数里的 m_* 键：
/// - m_EQ_taskName  → (t, EQ, task_name)
/// - m_t_EQ_taskName → (t, EQ, task_name)（pd 等别名直达 join 表，如 m_pd_state_EQ）
/// 值为空（空串/null/空数组）跳过（Java isEmpty 同款）
pub fn parse_m_params(args : Map[String, Json]) -> Array[@model.QueryFilter] {
  let filters : Array[@model.QueryFilter] = []
  for key, value in args {
    if !key.starts_with("m_") {
      continue
    }
    if is_empty_value(value) {
      continue
    }
    let suffix = key.substring(start=2).to_string()
    let parts = split_underscore(suffix)
    if parts.length() < 2 {
      continue
    }
    let (alias, op, column) = if parts.length() == 2 {
      ("t", parts[0], to_underscore(parts[1]))
    } else {
      (parts[0], parts[1], to_underscore(parts[2]))
    }
    match @model.FilterOp::from_str(op) {
      Some(parsed) => filters.push(@model.QueryFilter::make(alias, parsed, column, value_to_string(value)))
      None => continue
    }
  }
  filters
}

///|
fn split_underscore(s : String) -> Array[String] {
  let out : Array[String] = []
  let b = StringBuilder::new()
  for ch in s {
    if ch == '_' {
      out.push(b.to_string())
      b.reset()
    } else {
      b.write_char(ch)
    }
  }
  out.push(b.to_string())
  out
}

///|
fn is_empty_value(v : Json) -> Bool {
  match v {
    Json::Null => true
    Json::String(s) => s.is_empty()
    Json::Array(items) => items.is_empty()
    _ => false
  }
}

///|
fn value_to_string(v : Json) -> String {
  match v {
    Json::String(s) => s
    Json::Number(n, ..) => {
      let i = n.to_int64().to_double()
      if n == i {
        n.to_int64().to_string()
      } else {
        n.to_string()
      }
    }
    Json::True => "true"
    Json::False => "false"
    _ => ""
  }
}

///|
/// WHERE 条件片段 + 绑定值组装（LIMIT/OFFSET 内联非负整数，C21）
/// 返回 (where_sql_fragment, params)
pub fn build_m_where(filters : Array[@model.QueryFilter]) -> (String, Array[@moondb.Value]) {
  let b = StringBuilder::new()
  let params : Array[@moondb.Value] = []
  for f in filters {
    let col = f.alias() + "." + f.column()
    match f.op() {
      Eq => {
        b.write_string(" AND " + col + " = ?")
        params.push(@moondb.Text(f.value()))
      }
      Ne => {
        b.write_string(" AND " + col + " <> ?")
        params.push(@moondb.Text(f.value()))
      }
      Like => {
        b.write_string(" AND " + col + " LIKE ?")
        params.push(@moondb.Text("%" + f.value() + "%"))
      }
      Gt => {
        b.write_string(" AND " + col + " > ?")
        params.push(@moondb.Text(f.value()))
      }
      Lt => {
        b.write_string(" AND " + col + " < ?")
        params.push(@moondb.Text(f.value()))
      }
      Ge => {
        b.write_string(" AND " + col + " >= ?")
        params.push(@moondb.Text(f.value()))
      }
      Le => {
        b.write_string(" AND " + col + " <= ?")
        params.push(@moondb.Text(f.value()))
      }
      In => {
        let items = f.value().split(",").collect()
        if items.length() > 0 {
          b.write_string(" AND " + col + " IN (")
          for i, _ in items {
            if i > 0 {
              b.write_string(",")
            }
            b.write_string("?")
            params.push(@moondb.Text(items[i].to_string()))
          }
          b.write_string(")")
        }
      }
      Nin => {
        let items = f.value().split(",").collect()
        if items.length() > 0 {
          b.write_string(" AND " + col + " NOT IN (")
          for i, _ in items {
            if i > 0 {
              b.write_string(",")
            }
            b.write_string("?")
            params.push(@moondb.Text(items[i].to_string()))
          }
          b.write_string(")")
        }
      }
      Bt => {
        let parts = f.value().split(",").collect()
        if parts.length() >= 2 {
          b.write_string(" AND " + col + " BETWEEN ? AND ?")
          params.push(@moondb.Text(parts[0].to_string()))
          params.push(@moondb.Text(parts[1].to_string()))
        }
      }
    }
  }
  (b.to_string(), params)
}
