// jeeflow-persist —— 移植自 rust jeeflow-persist/src/lib.rs
// DynamicTableWriter + PersistPostInterceptor（ARCHIVE/SYNC，spec/09）+ 元数据 + 表名安全。

///|
/// 字段元数据（动态表列）
pub(all) struct FieldMeta {
  mut column_name : String
  mut column_type : String
  mut display_name : String
  mut nullable : Bool
  mut default_value : String?
  mut permission : Int // 1 只读 / 2 可编辑 / 3 隐藏
}

///|
pub fn FieldMeta::make(column_name : String, column_type : String, display_name : String) -> FieldMeta {
  {
    column_name,
    column_type,
    display_name,
    nullable: true,
    default_value: None,
    permission: 2,
  }
}

///|
pub fn FieldMeta::is_editable(self : FieldMeta) -> Bool {
  self.permission == 2
}

///|
pub fn FieldMeta::is_visible(self : FieldMeta) -> Bool {
  self.permission != 3
}

///|
pub(all) struct TableMeta {
  mut table_name : String
  mut display_name : String
  mut fields : Array[FieldMeta]
}

///|
pub fn TableMeta::make(table_name : String, display_name : String) -> TableMeta {
  { table_name, display_name, fields: [] }
}

///|
pub fn TableMeta::add_field(self : TableMeta, field : FieldMeta) -> Unit {
  self.fields.push(field)
}

///|
pub fn TableMeta::get_field(self : TableMeta, column_name : String) -> FieldMeta? {
  let mut found : FieldMeta? = None
  for f in self.fields {
    if f.column_name == column_name {
      found = Some(f)
    }
  }
  found
}

///|
/// IDynamicMetaProvider 内存实现
pub(all) struct InMemoryMetaProvider {
  tables : Map[String, TableMeta]
}

///|
pub fn InMemoryMetaProvider::new() -> InMemoryMetaProvider {
  { tables: Map::new() }
}

///|
pub fn InMemoryMetaProvider::register(self : InMemoryMetaProvider, meta : TableMeta) -> Unit {
  self.tables[meta.table_name] = meta
}

///|
pub fn InMemoryMetaProvider::get_table_meta(
  self : InMemoryMetaProvider,
  table_name : String
) -> TableMeta? raise @error.JeeflowError {
  self.tables.get(table_name)
}

///|
pub fn InMemoryMetaProvider::list_table_names(self : InMemoryMetaProvider) -> Array[String] {
  let out : Array[String] = []
  for k, _ in self.tables {
    out.push(k)
  }
  out
}

///|
let reserved_prefixes : Array[String] = [
  "sys_", "wf_", "mysql.", "information_schema.", "pg_", "sqlite_",
]

///|
/// 动态表名安全检查：仅字母数字下划线 + 保留前缀拒绝
pub fn is_table_name_safe(name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  for ch in name {
    let c = ch.to_int()
    let alnum = c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122
    if !(alnum || ch == '_') {
      return false
    }
  }
  let lower = name.to_lower()
  for prefix in reserved_prefixes {
    if lower.starts_with(prefix) {
      return false
    }
  }
  true
}

///|
/// 持久化模式
pub enum PersistMode {
  Archive
  Sync
} derive(Eq, Show)

///|
pub fn PersistMode::from_str(s : String) -> PersistMode? {
  match s.to_upper() {
    "ARCHIVE" => Some(Archive)
    "SYNC" => Some(Sync)
    _ => None
  }
}

///|
/// DynamicTableWriter trait（MoonBit：大接口 trait 形态）
pub(open) trait DynamicTableWriter {
  fn insert(Self, String, Map[String, Json]) -> Int64 raise @error.JeeflowError
  fn update(Self, String, Int64, Map[String, Json]) -> Unit raise @error.JeeflowError
  fn exists(Self, String, Int64) -> Bool raise @error.JeeflowError
  fn exists_by_key(Self, String, String, Int64) -> Bool raise @error.JeeflowError
  fn update_by_key(Self, String, Map[String, Json], String, Int64) -> Unit raise @error.JeeflowError
  // 探测实际存在的列（状态字段 {节点ID}_{状态码}/{节点ID} 过滤）；缺省全保留
  fn columns(Self, String, Array[String]) -> Array[String] raise @error.JeeflowError
}

///|
/// 系统字段填充（时间走 Clock 注入口，D-M0-3）
pub fn fill_system_fields(
  data : Map[String, Json],
  operator : String,
  is_insert : Bool
) -> Unit {
  let now = @model.current_time_str()
  if is_insert {
    data["create_time"] = @json.string_of(now)
    data["create_user"] = @json.string_of(operator)
  }
  data["update_time"] = @json.string_of(now)
  data["update_user"] = @json.string_of(operator)
}
