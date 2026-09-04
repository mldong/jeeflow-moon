// FlowData —— 流程/任务变量载体（对齐 java LinkedHashMap<String,Object>，rust FlowData）

///|
pub(all) struct FlowData {
  inner : Map[String, Json]
}

///|
pub fn FlowData::new() -> FlowData {
  { inner: Map::new() }
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
  self.inner.size()
}

///|
pub fn FlowData::is_empty(self : FlowData) -> Bool {
  self.inner.size() == 0
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
    if k.starts_with(prefix) {
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
