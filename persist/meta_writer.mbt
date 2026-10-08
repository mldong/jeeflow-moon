// MetaTableWriter —— spec/10 §5 的元数据驱动写侧（java `persist/meta/MetaTableWriter.java` 同位）。
//
// 形状＝**装饰器**：握着基础 writer ＋ 元数据端口，实现同一个 `DynamicTableWriter` trait
// ⇒ 拦截器与 facade 的调用点一个字不用改，装配时把真库 writer 包一层就行
// （java 也是这个形状：`new MetaTableWriter(base, provider)`）。
// 无元数据（provider 返回 None）⇒ 整批委托基础 writer，行为与 1.6.x 一致（spec/10 §3「零破坏」）。

///|
pub(all) struct MetaTableWriter {
  base : &DynamicTableWriter
  meta : DynamicMetaProviderFns
}

///|
pub fn MetaTableWriter::make(
  base : &DynamicTableWriter,
  meta : DynamicMetaProviderFns
) -> MetaTableWriter {
  { base, meta }
}

///|
/// 取元数据；`None`＝这张表没配元数据 ⇒ 调用点回落到基础 writer（spec/10 §3）。
async fn MetaTableWriter::load_meta(self : MetaTableWriter, table : String) -> TableMeta? raise @error.JeeflowError {
  (self.meta.load_table_meta)(table)
}

///|
/// 值 → JSON 串（JSON 档写列用）。已是字符串就原样落（java `toJson` 对 String 会多套一层引号，
/// 本栈选择原样——业务把 JSON 文本直接贴进输入框是最常见的形状，多套一层会让读侧解不回对象）。
fn json_column_value(v : Json) -> Json {
  match v {
    Json::String(s) => @json.string_of(s)
    _ => @json.string_of(@json.stringify(v))
  }
}

///|
/// EXPAND：对象字段展开为多列（`expand_fields` 的子字段名 → 表列名）。
/// 非对象值/缺子字段 ⇒ 跳过该列（java `expandInto` 的 `if (!(v instanceof Map)) return`）。
fn expand_into(f : FieldMeta, v : Json, row : Map[String, Json]) -> Unit {
  for sub_name, col in f.expand_fields {
    match @json.get(v, sub_name) {
      Some(fv) => row[col] = fv
      None => ()
    }
  }
}

///|
/// 按元数据把「表单字段为键」的 data 拆成「主表列」＋「子表待插清单」。
/// java `insert:52-77`／`update:148-171` 的同一形状：
/// - 遍历**元数据字段**（不是 data），每个字段按 `name` → 回落 `column_name` 找 data 键
///   （本栈拦截器交给 writer 的 data 已经是**列名键**，只按 name 找会在 name≠column_name 时漏）。
/// - NORMAL/JSON/EXPAND 进主表行；ONE2ONE/ONE2MANY 收进子表清单（`sub_in_update=false` 时
///   更新档整档跳过——spec/10 §5「子表不参与中途更新」）。
/// - data 里没被任何字段消费的键（流程上下文 process_instance_id/apply_user_id、状态列、系统列）
///   **直通**，putIfAbsent 语义（java `row.putIfAbsent:75,169`）。
fn MetaTableWriter::split(
  self : MetaTableWriter,
  meta : TableMeta,
  data : Map[String, Json],
  sub_in_update~ : Bool
) -> (Map[String, Json], Array[(FieldMeta, Json)]) {
  let _ = self
  let row : Map[String, Json] = Map([])
  let subs : Array[(FieldMeta, Json)] = []
  for f in meta.fields {
    let key = match find_data_key(data, f.name) {
      Some(k) => Some(k)
      None => find_data_key(data, f.column_name)
    }
    match key {
      None => ()
      Some(k) =>
        match f.storage_type {
          Json => row[f.column_name] = json_column_value(data[k])
          Expand => expand_into(f, data[k], row)
          One2One =>
            if sub_in_update {
              ()
            } else {
              subs.push((f, data[k]))
            }
          One2Many =>
            if sub_in_update {
              ()
            } else {
              subs.push((f, data[k]))
            }
          Normal => row[f.column_name] = data[k]
        }
    }
  }
  for k, v in data {
    if meta.find_field(k) is None && row.get(k) is None {
      row[k] = v
    }
  }
  (row, subs)
}

///|
/// 子表递归插入（java `insertSubTable:101-131`）：外键＝主表主键，
/// 继承主表 `apply_user_id`（子表显式同名字段优先 ⇒ putIfAbsent），
/// 插自身走**递归**（子表自己的元数据再展开一轮 ⇒ 嵌套 EXPAND/JSON/孙表都能接）。
async fn MetaTableWriter::insert_subs(
  self : MetaTableWriter,
  meta : TableMeta,
  subs : Array[(FieldMeta, Json)],
  parent_pk : Int64,
  parent_data : Map[String, Json]
) -> Unit raise @error.JeeflowError {
  if subs.is_empty() {
    return
  }
  if parent_pk == 0L {
    // java `:103-105`：主表主键缺失就没法定外键，硬失败（不许静默丢子表数据）
    raise @error.Business("主表主键缺失，无法插入子表: \{meta.table_name}")
  }
  let operator_ctx = parent_data.get("apply_user_id")
  // ⚠ 数组的 `for` 给的是「下标, 元素」两值（`for _, pair in`），不是把元组拆开——
  // 直接写 `for f, v in subs` 会让 f 绑成 Int 下标（本轮编译器抓到）。
  for _, pair in subs {
    let (f, v) = pair
    if f.target_table.is_empty() {
      raise @error.Business("字段 \{f.name} 声明 ONE2ONE/ONE2MANY 但未配 targetTable")
    }
    let fk = if f.foreign_key.is_empty() { meta.primary_key } else { f.foreign_key }
    let items : Array[Json] = match f.storage_type {
      One2Many =>
        match @json.as_array(v) {
          Some(arr) => arr
          None => []   // 值不是数组 ⇒ 一条都不插（java `instanceof List` 同判据）
        }
      _ => [v]   // ONE2ONE：单条
    }
    for item in items {
      let row : Map[String, Json] = Map([])
      // 子表行的键＝子对象键名原样（java `insertSubRow:123-125`），列名对不上由基础 writer 滤掉
      for _, pair2 in json_obj_entries(item) {
        let (k, kv) = pair2
        row[k] = kv
      }
      row[fk] = @json.number_of(parent_pk)
      match operator_ctx {
        Some(ov) => if row.get("apply_user_id") is None { row["apply_user_id"] = ov }
        None => ()
      }
      let _ = self.insert(f.target_table, row)
    }
  }
}

///|
/// Json 对象的键值对（非对象 ⇒ 空表）。`Json::Object` 在本包**可模式匹配、不可构造**
/// （core 的 `pub enum` 未带 `pub(all)` ⇒ 构造判 read-only type），所以读侧一律走解构。
fn json_obj_entries(v : Json) -> Array[(String, Json)] {
  let out : Array[(String, Json)] = []
  match v {
    Json::Object(obj) =>
      for k, kv in obj {
        out.push((k, kv))
      }
    _ => ()
  }
  out
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn insert(self, table, data) {
  match self.load_meta(table) {
    None => (self.base).insert(table, data)   // 无元数据：回落现状（spec/10 §3 零破坏）
    Some(meta) => {
      let (row, subs) = self.split(meta, data, sub_in_update=false)
      let pk = (self.base).insert(table, row)
      self.insert_subs(meta, subs, pk, data)
      pk
    }
  }
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn update(self, table, id, data) {
  match self.load_meta(table) {
    None => (self.base).update(table, id, data)
    Some(meta) => {
      let (row, _) = self.split(meta, data, sub_in_update=true)
      (self.base).update(table, id, row)
    }
  }
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn update_by_key(self, table, data, key, value) {
  match self.load_meta(table) {
    None => (self.base).update_by_key(table, data, key, value)
    Some(meta) => {
      // spec/10 §5「中途更新」：NORMAL/JSON/EXPAND 参与，ONE2ONE/ONE2MANY 不参与；
      // 上下文/状态列直通（java `update:166-172`）
      let (row, _) = self.split(meta, data, sub_in_update=true)
      (self.base).update_by_key(table, row, key, value)
    }
  }
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn exists(self, table, id) {
  (self.base).exists(table, id)
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn exists_by_key(self, table, key, value) {
  (self.base).exists_by_key(table, key, value)
}

///|
pub impl DynamicTableWriter for MetaTableWriter with fn columns(self, table, candidates) {
  (self.base).columns(table, candidates)
}

///|
pub extend MetaTableWriter with DynamicTableWriter::{
  columns, exists, exists_by_key, insert, update, update_by_key
}
