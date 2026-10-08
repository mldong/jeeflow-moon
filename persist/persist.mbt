// jeeflow-persist —— 移植自 rust jeeflow-persist/src/lib.rs
// DynamicTableWriter + PersistPostInterceptor（ARCHIVE/SYNC，spec/09）+ 元数据 + 表名安全。

///|
/// 存储类型（issues/151 X10／spec/10 §2.1）：**名称/数字双解析**，对齐 mldong
/// `dev_schema_field` 的 1-5 与 java `StorageType.fromValue`。
pub(all) enum StorageType {
  Normal
  Json
  Expand
  One2One
  One2Many
} derive(Eq, Debug)

///|
/// 双解析（spec/10 §2.1「string | number，缺省 NORMAL」）：
/// - 数字 1..5 → 五档；其它数字/非数字 → Normal（不报错，spec/09 §4.6 的"未知值不炸"同档）
/// - 字符串大小写不敏感，允许 `"JSON"`/`"json"`；数字写成字符串也认；未知名 → Normal
fn parse_i64_opt(s : String) -> Int64? {
  try {
    Some(@string.parse_int64(s))
  } catch {
    _ => None
  }
}

///|
fn storage_type_of_code(n : Int64) -> StorageType {
  match n {
    2L => Expand
    3L => Json
    4L => One2One
    5L => One2Many
    _ => Normal
  }
}

///|
pub fn storage_type_of(v : Json) -> StorageType {
  match v {
    Json::String(s) =>
      match s.to_upper() {
        "JSON" => Json
        "EXPAND" => Expand
        "ONE2ONE" => One2One
        "ONE2MANY" => One2Many
        "NORMAL" => Normal
        _ =>
          match parse_i64_opt(s) {
            Some(n) => storage_type_of_code(n)
            None => Normal
          }
      }
    _ =>
      match @json.as_i64(v) {
        Some(n) => storage_type_of_code(n)
        None => Normal
      }
  }
}

///|
/// 字段元数据（动态表列）
pub(all) struct FieldMeta {
  mut column_name : String
  mut column_type : String
  mut display_name : String
  mut nullable : Bool
  mut default_value : String?
  mut permission : Int // 1 只读 / 2 可编辑 / 3 隐藏
  /// 表单字段名（spec/10 §2.1：实例变量 `f_` 去前缀后的名字）。
  /// 缺省＝`column_name`——所以只登记列名的旧用法（149/150 那几轮的夹具）行为一字不变。
  mut name : String
  /// 存储类型（缺省 Normal＝直写列）
  mut storage_type : StorageType
  /// EXPAND 专用：子字段名 → 表列名
  mut expand_fields : Map[String, String]
  /// ONE2ONE/ONE2MANY 专用：子表表名
  mut target_table : String
  /// ONE2ONE/ONE2MANY 专用：子表外键列（空＝回落主表 `primary_key`）
  mut foreign_key : String
}

///|
pub fn FieldMeta::make(
  column_name : String,
  column_type : String,
  display_name : String,
  name? : String = "",
  storage_type? : StorageType = Normal,
  expand_fields? : Map[String, String] = Map([]),
  target_table? : String = "",
  foreign_key? : String = ""
) -> FieldMeta {
  {
    column_name,
    column_type,
    display_name,
    nullable: true,
    default_value: None,
    permission: 2,
    name: if name.is_empty() { column_name } else { name },
    storage_type,
    expand_fields,
    target_table,
    foreign_key,
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
  /// 主键列名（spec/10 §2.1 顶层 `primaryKey`，缺省 `id`）：
  /// ONE2ONE/ONE2MANY 的子表外键缺省回落它，读侧也按它取主表主键值。
  mut primary_key : String
}

///|
pub fn TableMeta::make(table_name : String, display_name : String, primary_key? : String = "id") -> TableMeta {
  { table_name, display_name, fields: [], primary_key }
}

///|
/// 按**表单字段名**找字段（宽松列名匹配，issues/151 X3 那枚尺子）。
/// 写侧用它判断"这个 data 键是不是已被某个字段消费"（java `findField:74`）。
pub fn TableMeta::find_field(self : TableMeta, key : String) -> FieldMeta? {
  for f in self.fields {
    if column_names_equal(key, f.name) || column_names_equal(key, f.column_name) {
      return Some(f)
    }
  }
  None
}

///|
/// 按**表列名**找字段（读侧判断某列是否已被消费，java `findFieldByColumn:74`）
pub fn TableMeta::find_field_by_column(self : TableMeta, column : String) -> FieldMeta? {
  for f in self.fields {
    if column_names_equal(column, f.column_name) {
      return Some(f)
    }
  }
  None
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
  { tables: Map([]) }
}

///|
pub fn InMemoryMetaProvider::register(self : InMemoryMetaProvider, meta : TableMeta) -> Unit {
  self.tables[meta.table_name] = meta
}

///|
pub fn InMemoryMetaProvider::get_table_meta(
  self : InMemoryMetaProvider,
  table_name : String
) -> TableMeta? {
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
    let alnum = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    if !(alnum || ch == '_') {
      return false
    }
  }
  let lower = name.to_lower()
  for prefix in reserved_prefixes {
    if lower.has_prefix(prefix) {
      return false
    }
  }
  true
}

///|
/// 列名归一（issues/151 X3）：转小写 + 去下划线 ⇒ `companyName` / `company_name` /
/// `COMPANY_NAME` 三档等价。逐字照 java `JdbcDynamicTableWriter.normalizeColumn:305-307`。
pub fn normalize_column(name : String) -> String {
  let b = StringBuilder()
  for ch in name.to_lower() {
    if ch != '_' {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
/// 列名等价判定（java `findColumn:293-302` / `findDataKey:310-320` 的同一枚尺子）：
/// - 严格档＝忽略大小写的逐字相等（java `setStrictColumnMatch(true)`）；
/// - 宽松档（默认）＝归一后相等。
/// 两键撞同一列时的确定性规则也在这里定：**遍历方**（`find_data_key` 走 data 插入序、
/// `match_column` 走表列序）里第一个命中者胜出，与 java 的 `data.keySet()` / `List<ColumnMeta>`
/// 遍历顺序同判据——不写这条，同一份 data 两次运行可能落到不同列（Map 保插入序是 MoonBit 保证，
/// 但"命中即停"必须显式，否则宽松档会静默多写一列）。
pub fn column_names_equal(a : String, b : String, strict~ : Bool=false) -> Bool {
  if strict {
    a.to_lower() == b.to_lower()
  } else {
    normalize_column(a) == normalize_column(b)
  }
}

///|
/// 在 data 中找匹配指定表列的 key（java `findDataKey`）。命中即停 ⇒ data 插入序里的第一个键胜出。
pub fn find_data_key(data : Map[String, Json], column : String, strict~ : Bool=false) -> String? {
  for k, _ in data {
    if column_names_equal(k, column, strict~) {
      return Some(k)
    }
  }
  None
}

///|
/// 候选列名 → 表里实际存在的**真列名**（java `findColumn`）。
/// 返回真列名而不是候选名，是因为写侧要把这个串直接拼进 SQL 的反引号位；
/// java 的 `filterColumns` 返回候选名（它之后只当 data 键用），本栈两处都按 java 各自的那档实现。
pub fn match_column(real_cols : Array[String], candidate : String, strict~ : Bool=false) -> String? {
  for c in real_cols {
    if column_names_equal(c, candidate, strict~) {
      return Some(c)
    }
  }
  None
}

///|
/// 持久化模式
pub enum PersistMode {
  Archive
  Sync
} derive(Eq, Debug)

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
///
/// issues/149：六法全部 async —— 本栈写真库只有 moonmysql 的 async 连接这一条路，同步形状
/// 发不出查询（145-6 记的机理）。async 由 **trait 声明**承载：`impl … with fn` 处不重复写
/// `async`（实测写了判 parse error），⇒ `InMemoryTableWriter` 六支 impl 与 `&DynamicTableWriter`
/// 的六处调用点都不用改；唯一要跟着改的是同步函数里调 writer 的 `put_state_field`。
/// 同形参照＝`core/spi/repository.mbt` 的 `ProcessRepository`（async trait ＋ repository-mysql 真库实现）。
/// ⚠ 列探测（`columns`）归属裁决＝**留在 writer**：参考实现 java
/// `persist/DynamicTableWriter.java:20` 的 `filterColumns` 就挂在 writer 上，而
/// `IDynamicMetaProvider` 管字段权限/显示元数据——两者在 java 本就并存，故不并入
/// `DynamicMetaProviderFns`（146 缺口二），也不留"同一件事两个端口"。
pub(open) trait DynamicTableWriter {
  async fn insert(Self, String, Map[String, Json]) -> Int64 raise @error.JeeflowError
  async fn update(Self, String, Int64, Map[String, Json]) -> Unit raise @error.JeeflowError
  async fn exists(Self, String, Int64) -> Bool raise @error.JeeflowError
  async fn exists_by_key(Self, String, String, Int64) -> Bool raise @error.JeeflowError
  async fn update_by_key(Self, String, Map[String, Json], String, Int64) -> Unit raise @error.JeeflowError
  // 探测实际存在的列（状态字段 {节点ID}_{状态码}/{节点ID} 过滤）；缺省全保留
  async fn columns(Self, String, Array[String]) -> Array[String] raise @error.JeeflowError
}

///|
/// 系统列配置（issues/150 X5，java `JdbcDynamicTableWriter:57-65,211-234` 同位）。
/// 列名可配置，`None` ＝ 不填该列（java 用 `null` 表达同一意思）；
/// `default_user_value` ＝ 取不到操作人时的回落值（java 缺省 `"system"`）。
pub(all) struct SystemFields {
  create_time_col : String?
  create_user_col : String?
  update_time_col : String?
  update_user_col : String?
  is_deleted_col : String?
  default_user_value : String
}

///|
pub fn SystemFields::make_default() -> SystemFields {
  {
    create_time_col: Some("create_time"),
    create_user_col: Some("create_user"),
    update_time_col: Some("update_time"),
    update_user_col: Some("update_user"),
    is_deleted_col: Some("is_deleted"),
    default_user_value: "system",
  }
}

///|
/// 用户列取值（java `resolveDefaultUser:231-234`）：**`apply_user_id` 优先**——拦截器已由
/// `fill_context` 把流程 operator 写进这个键，BIGINT 用户列因此开箱可用；
/// 该键缺失/为 null 才落 `default_user_value`。
/// moon 比 java 多一档 `operator`（夹在两者之间）：java 的 `fillSystemFields` 没有 operator 形参，
/// operator 只能经 `apply_user_id` 这条路进来，而本栈的 `fill_context` 会先过一道列权限过滤
/// （`apply_user_id` 不在业务表列清单里时会被丢掉），少这一档就会把真实操作人写成 `"system"`。
fn resolve_user_value(
  data : Map[String, Json],
  operator : String,
  cfg : SystemFields
) -> Json {
  match data.get("apply_user_id") {
    Some(v) =>
      match v {
        Json::Null =>
          if operator.is_empty() {
            @json.string_of(cfg.default_user_value)
          } else {
            @json.string_of(operator)
          }
        _ => v
      }
    None =>
      if operator.is_empty() {
        @json.string_of(cfg.default_user_value)
      } else {
        @json.string_of(operator)
      }
  }
}

///|
/// 系统字段填充（时间走 Clock 注入口，D-M0-3）。
/// 与 java `fillSystemFields:211-224` 逐条同判据：
/// - 插入＝create/update 四列 + `is_deleted` 全填，且**一律 putIfAbsent**（业务自带的时间/人不覆盖）；
/// - 更新＝`update_time` 覆写（java 用 `put`，定稿时刻必须以本次为准）、`update_user` putIfAbsent；
/// - 列名为 `None` ⇒ 该列不填。
pub fn fill_system_fields_with(
  cfg : SystemFields,
  data : Map[String, Json],
  operator : String,
  is_insert : Bool
) -> Unit {
  let now = @model.current_time_str()
  let user = resolve_user_value(data, operator, cfg)
  if is_insert {
    match cfg.create_time_col {
      Some(col) => if data.get(col) is None { data[col] = @json.string_of(now) }
      None => ()
    }
    match cfg.create_user_col {
      Some(col) => if data.get(col) is None { data[col] = user }
      None => ()
    }
    match cfg.update_time_col {
      Some(col) => if data.get(col) is None { data[col] = @json.string_of(now) }
      None => ()
    }
    match cfg.update_user_col {
      Some(col) => if data.get(col) is None { data[col] = user }
      None => ()
    }
    match cfg.is_deleted_col {
      Some(col) => if data.get(col) is None { data[col] = @json.number_of(0L) }
      None => ()
    }
  } else {
    match cfg.update_time_col {
      Some(col) => data[col] = @json.string_of(now)
      None => ()
    }
    match cfg.update_user_col {
      Some(col) => if data.get(col) is None { data[col] = user }
      None => ()
    }
  }
}

///|
/// 缺省列名档（`create_time`/`create_user`/`update_time`/`update_user`/`is_deleted`）——
/// 旧调用形状保持可用，列名不同的集成方走 `fill_system_fields_with`。
pub fn fill_system_fields(
  data : Map[String, Json],
  operator : String,
  is_insert : Bool
) -> Unit {
  fill_system_fields_with(SystemFields::make_default(), data, operator, is_insert)
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend PersistMode with Eq::{equal, not_equal}
pub extend PersistMode with Debug::{to_repr}
pub extend StorageType with Eq::{equal, not_equal}
pub extend StorageType with Debug::{to_repr}


///|
/// IDynamicMetaProvider 的 MoonBit 同位（issues/146 缺口二）。
/// java 侧这个端口就定义在 jeeflow-persist/meta（不在 core），消费点是 MetaTableWriter/Reader
/// ⇒ 本栈同位同样落在 persist：归档/SYNC 的写侧与回显读侧共用一份元数据（storageType 语义两侧一致）。
/// load_table_meta 是 async：集成方的元数据来源是库（mldong dev_schema / information_schema），
/// 同步形状就会重演缺口一——启动期快照、改表结构引擎看不见。
/// 未注入 ⇒ 引擎行为与既往一致（InMemory 档照常，缺省不启用外部元数据）。
pub(all) struct DynamicMetaProviderFns {
  load_table_meta : (async (String) -> TableMeta? raise @error.JeeflowError)
}

///|
/// 内存档 → 端口（纯内存读 ⇒ 经 @spi.async_of_sync 桥，注册点零警告）
pub fn InMemoryMetaProvider::as_provider(self : InMemoryMetaProvider) -> DynamicMetaProviderFns {
  let it = self
  let f : (String) -> TableMeta? raise @error.JeeflowError = name => it.get_table_meta(name)
  { load_table_meta: @spi.async_of_sync(f) }
}

