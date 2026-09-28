// FlowData —— 流程/任务变量载体（对齐 java LinkedHashMap<String,Object>，rust FlowData）

///|
pub(all) struct FlowData {
  inner : Map[String, Json]
}

///|
pub fn FlowData::new() -> FlowData {
  { inner: Map([]) }
}

///|
pub fn FlowData::from_map(map : Map[String, Json]) -> FlowData {
  { inner: map }
}

///|
pub fn FlowData::get(self : FlowData, key : String) -> Json? {
  self.inner.get(key)
}

///|
pub fn FlowData::get_str(self : FlowData, key : String) -> String? {
  match self.inner.get(key) {
    Some(v) => as_str(v)
    None => None
  }
}

///|
pub fn FlowData::get_i64(self : FlowData, key : String) -> Int64? {
  match self.inner.get(key) {
    Some(v) => as_i64(v)
    None => None
  }
}

///|
///|
/// 数组形态的字符串列表读取（issues/131：会签名册 `operatorList_{node}` 是数组，
/// 与 java `ProcessInstance.java:257` 存的 List 同形）。缺键/非数组 ⇒ 空表；
/// 有意**不兜**旧的逗号串——存量兼容不做（owner 2026-09-28：demo 重启即重建、pro 是 goframe 版本）。
///|
/// 数组形态的字符串列表写入（issues/131：会签名册 operatorList_{node} 存数组，
/// 与 java `ProcessInstance.java:257` 的 List 同形；写侧收在 json 包里，
/// 引擎侧不必引用 Json 类型名）。
pub fn FlowData::insert_string_array(self : FlowData, key : String, items : Array[String]) -> Unit {
  let arr = empty_array()
  for s in items {
    arr_push(arr, string_of(s))
  }
  self.inner[key] = arr
}

pub fn FlowData::get_string_array(self : FlowData, key : String) -> Array[String] {
  let out : Array[String] = []
  match self.inner.get(key) {
    Some(v) =>
      match as_array(v) {
        Some(items) =>
          for it in items {
            match as_str(it) {
              Some(s) => if s != "" { out.push(s) }
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  out
}

pub fn FlowData::get_str_or(self : FlowData, key : String, default : String) -> String {
  match self.get_str(key) {
    Some(s) => s
    None => default
  }
}

///|
pub fn FlowData::get_i64_or(self : FlowData, key : String, default : Int64) -> Int64 {
  match self.get_i64(key) {
    Some(v) => v
    None => default
  }
}

///|
pub fn FlowData::insert(self : FlowData, key : String, value : Json) -> Unit {
  self.inner[key] = value
}

///|
pub fn FlowData::insert_str(self : FlowData, key : String, value : String) -> Unit {
  self.inner[key] = string_of(value)
}

///|
pub fn FlowData::insert_i64(self : FlowData, key : String, value : Int64) -> Unit {
  self.inner[key] = number_of(value)
}

///|
pub fn FlowData::contains_key(self : FlowData, key : String) -> Bool {
  self.inner.get(key) is Some(_)
}

///|
pub fn FlowData::remove(self : FlowData, key : String) -> Json? {
  let v = self.inner.get(key)
  self.inner.remove(key)
  v
}

///|
pub fn FlowData::len(self : FlowData) -> Int {
  self.inner.length()
}

///|
pub fn FlowData::is_empty(self : FlowData) -> Bool {
  self.inner.length() == 0
}

///|
pub fn FlowData::merge(self : FlowData, other : FlowData) -> Unit {
  for k, v in other.inner {
    self.inner[k] = v
  }
}

///|
pub fn FlowData::keys_with_prefix(self : FlowData, prefix : String) -> Array[String] {
  let out : Array[String] = []
  for k, _ in self.inner {
    if k.has_prefix(prefix) {
      out.push(k)
    }
  }
  out
}

///|
pub fn FlowData::inner(self : FlowData) -> Map[String, Json] {
  self.inner
}

///|
pub fn FlowData::to_object_json(self : FlowData) -> Json {
  let obj = empty_object()
  for k, v in self.inner {
    obj_set(obj, k, v)
  }
  obj
}

///|
/// 引用形态：返回底层 Map（读侧直查；写侧请经 insert 保持一致）
pub fn FlowData::iter_entries(self : FlowData) -> Array[(String, Json)] {
  let out : Array[(String, Json)] = []
  for k, v in self.inner {
    out.push((k, v))
  }
  out
}
