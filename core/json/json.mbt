// jeeflow-core/json —— 薄壳（方案 §2.2）：builtin Json + @json.parse/stringify 承载，
// 语义对齐 rust json.rs（as_i64 双收 string、空输入→Null）；FlowData=Map[String,Json] 载体。

///|
pub fn parse_json(input : String) -> Json raise @error.JeeflowError {
  let trimmed = input.trim(chars=" \t\r\n")
  if trimmed.is_empty() {
    return null_json()
  }
  try {
    @cjson.parse(trimmed)
  } catch {
    e => raise @error.JeeflowError::ParseError("json: \{e}")
  }
}

///|
pub fn stringify(value : Json) -> String {
  value.stringify()
}

///|
pub fn get(value : Json, key : String) -> Json? {
  value.value(key)
}

///|
pub fn as_str(value : Json) -> String? {
  value.as_string()
}

///|
/// 对齐 rust as_i64：Number 截断 / Str 解析双收
pub fn as_i64(value : Json) -> Int64? {
  match value {
    Json::Number(n, ..) => Some(n.to_int64())
    Json::String(s) =>
      match (try? @string.parse_int64(s)) {
        Ok(v) => Some(v)
        Err(_) => None
      }
    _ => None
  }
}

///|
pub fn as_f64(value : Json) -> Double? {
  match value {
    Json::Number(n, ..) => Some(n)
    Json::String(s) =>
      match (try? @string.parse_double(s)) {
        Ok(v) => Some(v)
        Err(_) => None
      }
    _ => None
  }
}

///|
pub fn as_bool(value : Json) -> Bool? {
  match value {
    Json::True => Some(true)
    Json::False => Some(false)
    _ => None
  }
}

///|
pub fn get_str(value : Json, key : String) -> String? {
  match value.value(key) {
    Some(v) => as_str(v)
    None => None
  }
}

///|
pub fn get_i64(value : Json, key : String) -> Int64? {
  match value.value(key) {
    Some(v) => as_i64(v)
    None => None
  }
}

// ── Json 构建助手（builtin Json 为 pub 只读枚举，外部不能直呼构造器；
//    统一经 @cjson.parse 种子 + as_* 取底层容器原地写，实测引用语义）──

///|
pub fn null_json() -> Json {
  match (try? @cjson.parse("null")) {
    Ok(v) => v
    Err(_) => abort("unreachable: literal null parse")
  }
}

///|
pub fn number_of(n : Int64) -> Json {
  // Int64::to_json() 在 core 里输出字符串（大整数安全惯例）；本仓契约数字键走
  // parse 原文 → Number 且 repr 保留原文（>2^53 安全），信封 code/pageNum 等保持 number
  match (try? @cjson.parse(n.to_string())) {
    Ok(v) => v
    Err(_) => number_f_of(0.0)
  }
}

///|
pub fn number_f_of(n : Double) -> Json {
  n.to_json()
}

///|
pub fn string_of(s : String) -> Json {
  s.to_json()
}

///|
pub fn bool_of(b : Bool) -> Json {
  b.to_json()
}

///|
pub fn empty_object() -> Json {
  match (try? @cjson.parse("{}")) {
    Ok(v) => v
    Err(_) => abort("unreachable: literal {} parse")
  }
}

///|
pub fn empty_array() -> Json {
  match (try? @cjson.parse("[]")) {
    Ok(v) => v
    Err(_) => abort("unreachable: literal [] parse")
  }
}

///|
/// 向对象写键（obj 必须来自 empty_object()/解析出的 Object）
pub fn obj_set(obj : Json, key : String, value : Json) -> Unit {
  match obj {
    Json::Object(m) => m[key] = value
    _ => ()
  }
}

///|
/// 向数组追加
pub fn arr_push(arr : Json, value : Json) -> Unit {
  match arr {
    Json::Array(a) => a.push(value)
    _ => ()
  }
}

///|
pub fn array_of(items : Array[Json]) -> Json {
  let a = empty_array()
  for v in items {
    arr_push(a, v)
  }
  a
}

///|
pub fn object_of(entries : Array[(String, Json)]) -> Json {
  let obj = empty_object()
  for entry in entries {
    let (k, v) = entry
    obj_set(obj, k, v)
  }
  obj
}
