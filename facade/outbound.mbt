// facade 出口层 —— 移植自 rust jeeflow-facade/src/lib.rs L20-402（C1/C5/C7/C22 强制层）
// ⚠️ builtin Json Number 是 Double：>2^53 的雪花 id 在构造期就丢精度，
//    故行 VO 构造时 id 即以十进制串落键（stringify_ids 留作递归安全网，覆盖嵌套/复数数组）。

///|
pub const CODE_SUCCESS : Int64 = 0L

///|
pub const CODE_ERROR : Int64 = 99999999L

///|
pub fn ok(data : Json?) -> Json {
  let obj = @json.empty_object()
  @json.obj_set(obj, "code", @json.number_of(CODE_SUCCESS))
  @json.obj_set(obj, "msg", @json.string_of("成功"))
  @json.obj_set(obj, "data", match data {
    Some(d) => d
    None => @json.null_json()
  })
  obj
}

///|
pub fn ok_data(data : Json) -> Json {
  ok(Some(data))
}

///|
pub fn err(msg : String) -> Json {
  let obj = @json.empty_object()
  @json.obj_set(obj, "code", @json.number_of(CODE_ERROR))
  @json.obj_set(obj, "msg", @json.string_of(msg))
  obj
}

///|
pub fn is_ok(env : Json) -> Bool {
  match @json.get_i64(env, "code") {
    Some(c) => c == 0L
    None => false
  }
}

///|
pub fn envelope_data(env : Json) -> Json? {
  @json.get(env, "data")
}

///|
fn to_camel(s : String) -> String {
  let b = StringBuilder::new()
  let mut upper_next = false
  for ch in s {
    if ch == '_' {
      upper_next = true
    } else if upper_next {
      let code = ch.to_int()
      if code >= 97 && code <= 122 {
        b.write_char(Char::from_int(code - 32))
      } else {
        b.write_char(ch)
      }
      upper_next = false
    } else {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
/// 自由形态嵌套 map 键（VO 顶层 camelCase，内部保留原键）
fn is_opaque_value_key(k : String) -> Bool {
  k == "jsonObject" ||
  k == "json_object" ||
  k == "ext" ||
  k == "instanceExt" ||
  k == "instance_ext" ||
  k == "variable" ||
  k == "taskFormData" ||
  k == "task_form_data" ||
  k == "formData" ||
  k == "form_data" ||
  k == "nodeProgress" ||
  k == "node_progress"
}

///|
fn to_camel_json_inner(val : Json, convert_keys : Bool) -> Json {
  match val {
    Json::Object(map) => {
      let out = @json.empty_object()
      for k, v in map {
        let new_key = if convert_keys { to_camel(k) } else { k }
        let child_convert = convert_keys && !is_opaque_value_key(k) && !is_opaque_value_key(new_key)
        @json.obj_set(out, new_key, to_camel_json_inner(v, child_convert))
      }
      out
    }
    Json::Array(arr) => {
      let out = @json.empty_array()
      for v in arr {
        @json.arr_push(out, to_camel_json_inner(v, convert_keys))
      }
      out
    }
    other => other
  }
}

///|
pub fn to_camel_json(val : Json) -> Json {
  to_camel_json_inner(val, true)
}

///|
/// C1：id/*Id/*_id 单数键值字符串化（递归）；ids/*Ids/*_ids 复数键逐元素
pub fn stringify_ids(val : Json) -> Json {
  match val {
    Json::Object(map) => {
      let out = @json.empty_object()
      for k, v in map {
        if k == "id" || k.ends_with("Id") || k.ends_with("_id") {
          @json.obj_set(out, k, stringify_id_value(v))
        } else if k == "ids" || k.ends_with("Ids") || k.ends_with("_ids") {
          @json.obj_set(out, k, stringify_id_array(v))
        } else {
          @json.obj_set(out, k, stringify_ids(v))
        }
      }
      out
    }
    Json::Array(arr) => {
      let out = @json.empty_array()
      for v in arr {
        @json.arr_push(out, stringify_ids(v))
      }
      out
    }
    other => other
  }
}

///|
fn stringify_id_value(v : Json) -> Json {
  match v {
    // id 字符串化走 repr 原文优先（>2^53 防 double 取整，D-M5-3）
    Json::Number(n, repr~) =>
      match repr {
        Some(s) => @json.string_of(s)
        None => @json.string_of(n.to_int64().to_string())
      }
    other => other
  }
}

///|
fn stringify_id_array(v : Json) -> Json {
  match v {
    Json::Array(arr) => {
      let out = @json.empty_array()
      for item in arr {
        @json.arr_push(out, stringify_id_value(item))
      }
      out
    }
    other => stringify_id_value(other)
  }
}

///|
/// C7：时间键格式化（NOW() 占位 / ISO T → 空格）
pub fn format_time_fields(val : Json) -> Json {
  match val {
    Json::Object(map) => {
      let out = @json.empty_object()
      for k, v in map {
        if k.ends_with("Time") || k.ends_with("_time") {
          @json.obj_set(out, k, format_time_value(v))
        } else {
          @json.obj_set(out, k, format_time_fields(v))
        }
      }
      out
    }
    Json::Array(arr) => {
      let out = @json.empty_array()
      for v in arr {
        @json.arr_push(out, format_time_fields(v))
      }
      out
    }
    other => other
  }
}

///|
fn format_time_value(v : Json) -> Json {
  match v {
    Json::String(s) => {
      if s == "NOW()" || s == "NOW" {
        return @json.string_of(@model.current_time_str())
      }
      // ISO 'T' → 空格（19 位近似可直接换）
      if s.length() >= 19 {
        let bytes = s.to_array()
        if bytes[10] == 'T' {
          let approx = s.substring(start=0, end=10).to_string() + " " + s.substring(start=11, end=19).to_string()
          return @json.string_of(approx)
        }
        // 毫秒尾巴 ".fff" 截断
        if s.length() > 19 && s.to_array()[10] == ' ' {
          return @json.string_of(s.substring(start=0, end=19).to_string())
        }
      }
      @json.string_of(s)
    }
    other => other
  }
}

///|
/// 出口统一变换：camelCase → id 字符串化 → 时间格式化
pub fn transform_output(val : Json) -> Json {
  format_time_fields(stringify_ids(to_camel_json(val)))
}

///|
/// 分页五键（C22）
pub fn page_to_json[T](page : @model.PageResult[T], row_json : (T) -> Json) -> Json {
  let obj = @json.empty_object()
  @json.obj_set(obj, "pageNum", @json.number_of(page.page_num()))
  @json.obj_set(obj, "pageSize", @json.number_of(page.page_size()))
  @json.obj_set(obj, "recordCount", @json.number_of(page.record_count()))
  @json.obj_set(obj, "totalPage", @json.number_of(page.total_page()))
  let rows = @json.empty_array()
  for r in page.rows() {
    @json.arr_push(rows, row_json(r))
  }
  @json.obj_set(obj, "rows", rows)
  obj
}

///|
pub fn parse_graph(content : String) -> Json? {
  let t = content.trim(chars=" \t\r\n").to_string()
  if t.is_empty() {
    return None
  }
  match (try? @json.parse_json(t)) {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
pub fn parse_json_map(s : String?) -> Map[String, Json] {
  let out : Map[String, Json] = Map::new()
  match s {
    Some(raw) => {
      let t = raw.trim(chars=" \t\r\n").to_string()
      if !t.is_empty() {
        match (try? @json.parse_json(t)) {
          Ok(Json::Object(m)) =>
            for k, v in m {
              out[k] = v
            }
          _ => ()
        }
      }
    }
    None => ()
  }
  out
}

///|
/// 表单数据派生（issues/15）：prefix 键带前缀 + 去前缀双份
pub fn form_data_of_map(vars : Map[String, Json], prefix : String) -> Json {
  let out = @json.empty_object()
  for k, v in vars {
    if k.starts_with(prefix) {
      @json.obj_set(out, k, v)
      @json.obj_set(out, k.substring(start=prefix.length()).to_string(), v)
    }
  }
  out
}

///|
pub fn form_data_of_flow(vars : @json.FlowData, prefix : String) -> Json {
  form_data_of_map(vars.inner(), prefix)
}

///|
pub fn flow_data_to_object(vars : @json.FlowData) -> Json {
  vars.to_object_json()
}

///|
pub fn first_task_node_id(json_object : Json?) -> String? {
  match json_object {
    Some(obj) =>
      match obj.value("nodes") {
        Some(Json::Array(nodes)) => {
          for n in nodes {
            match n.value("type") {
              Some(Json::String(t)) =>
                if t == "snaker:task" {
                  return @json.as_str(n.value("id").unwrap_or(@json.null_json()))
                }
              _ => ()
            }
          }
          None
        }
        _ => None
      }
    None => None
  }
}

///|
fn opt_json(s : String?) -> Json {
  match s {
    Some(v) => @json.string_of(v)
    None => @json.null_json()
  }
}

///|
fn num_json(n : Int) -> Json {
  @json.number_of(n.to_int64())
}

///|
fn opt_num_json(n : Int?) -> Json {
  match n {
    Some(v) => num_json(v)
    None => @json.null_json()
  }
}

///|
fn i64_json(n : Int64) -> Json {
  @json.string_of(n.to_string())
}

///|
fn opt_i64_json(n : Int64?) -> Json {
  match n {
    Some(v) => i64_json(v)
    None => @json.null_json()
  }
}
