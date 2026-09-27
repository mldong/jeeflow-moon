// m_ 三段式参数解析 + 分页 SQL 组装 —— 移植自 java JeeflowQueryParser（issues/85 rust 缺失件）

///|
/// camelCase → snake_case
pub fn to_underscore(camel : String) -> String {
  let b = StringBuilder()
  for ch in camel {
    let code = ch.to_int()
    if code >= 65 && code <= 90 {
      b.write_char('_')
      b.write_char((code + 32).unsafe_to_char())
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
/// 值为空（空串/null/空数组）跳过（Java isEmpty 同款）——
/// issues/129 案 A 唯一的例外：归属谓词列（见 is_ownership_column）的 EQ 空值不跳过，
/// 放行给 build_m_where 收成 AND 1=0（空页），绝不落到「这条条件不加」= 读全库
pub fn parse_m_params(args : Map[String, Json]) -> Array[@model.QueryFilter] {
  let filters : Array[@model.QueryFilter] = []
  for key, value in args {
    if !key.has_prefix("m_") {
      continue
    }
    let suffix = key[2:].to_owned()
    let parts = split_underscore(suffix)
    if parts.length() < 2 {
      continue
    }
    let (table_alias, op, column) = if parts.length() == 2 {
      ("t", parts[0], to_underscore(parts[1]))
    } else {
      (parts[0], parts[1], to_underscore(parts[2]))
    }
    match @model.FilterOp::from_str(op) {
      Some(parsed) => {
        if is_empty_value(value) {
          // issues/129 案 A：空值放行只留给**可选过滤**（m_LIKE_* 等，按「没填」忽略，
          // 行为与改前逐字一致）；归属谓词列的 EQ 空值放行给 build_m_where 收成
          // AND 1=0（空页）——那里的「这条条件不加」等于丢掉归属过滤 = 读全库。
          if parsed is Eq && is_ownership_column(table_alias, column) {
            filters.push(@model.QueryFilter::make(table_alias, parsed, column, ""))
          }
        } else {
          filters.push(@model.QueryFilter::make(table_alias, parsed, column, value_to_string(value)))
        }
      }
      None => continue
    }
  }
  filters
}

///|
fn split_underscore(s : String) -> Array[String] {
  let out : Array[String] = []
  let b = StringBuilder()
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
/// 归属谓词列（issues/129 案 A 第二层 · spec 06-facade §2.5 口径表）：本栈四条「我的」
/// 分页出口各自的过滤列，别名按本栈 SQL 实际写法（t=wf_process_task /
/// pi=wf_process_instance / ta=wf_process_task_actor / cc=wf_process_cc_instance），
/// 对齐 java 的 t.operator / pi.operator / pta.actor_id / cc.actor_id 四列，仅换别名拼写。
/// 只有这四列受下面的空值兜底约束。
fn is_ownership_column(table_alias : String, column : String) -> Bool {
  let qualified = table_alias + "." + column
  qualified == "t.operator" ||
  qualified == "pi.operator" ||
  qualified == "ta.actor_id" ||
  qualified == "cc.actor_id"
}

///|
/// 空白值判定（含全空白串，与门面 operator_arg 同档，issues/129 案 A）
fn blank_value_text(s : String) -> Bool {
  s.trim(chars=" \t\r\n").is_empty()
}

///|
fn value_to_string(v : Json) -> String {
  match v {
    Json::String(s) => s
    // 整数走 repr 原文优先（>2^53 防 double 取整，D-M5-3）；repr 仅出现在超限整数
    // 字面量（词法器保证纯数字文本，无注入面），小数值仍走 double 判定
    Json::Number(n, repr~) =>
      match repr {
        Some(s) => s
        None => {
          let i = n.to_int64().to_double()
          if n == i {
            n.to_int64().to_string()
          } else {
            n.to_string()
          }
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
  let b = StringBuilder()
  let params : Array[@moondb.Value] = []
  for f in filters {
    let col = f.table_alias() + "." + f.column()
    // issues/129 案 A 第二层（仓储兜底）：归属谓词列拿到空值 ⇒ 空页，绝不允许
    // 「这条条件不加」（那等于把「我是谁」丢了 ⇒ 读全库）。门面正常路径不会传空
    // （facade.operator_arg 已把空串归一化成缺省 user1），这一层防的是直连仓储 /
    // 自定义 SPI 与后续门面改动绕过归一化。非归属列（m_LIKE_* 等可选过滤）的空值
    // 仍按「没填」忽略——那是 PageQuery 的既有通用放行，不在收口范围内。
    if f.op() is Eq && blank_value_text(f.value()) && is_ownership_column(f.table_alias(), f.column()) {
      b.write_string(" AND 1=0")
      continue
    }
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
            params.push(@moondb.Text(items[i].to_owned()))
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
            params.push(@moondb.Text(items[i].to_owned()))
          }
          b.write_string(")")
        }
      }
      Bt => {
        let parts = f.value().split(",").collect()
        if parts.length() >= 2 {
          b.write_string(" AND " + col + " BETWEEN ? AND ?")
          params.push(@moondb.Text(parts[0].to_owned()))
          params.push(@moondb.Text(parts[1].to_owned()))
        }
      }
    }
  }
  (b.to_string(), params)
}
