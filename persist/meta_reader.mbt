// MetaTableReader —— spec/10 §6 的元数据驱动读侧（java `persist/meta/MetaTableReader.java` 同位）。
//
// 与写侧共用同一份元数据 ⇒ storageType 语义两侧一致：EXPAND 反展开、JSON 反序列化、
// ONE2ONE/ONE2MANY 按外键=主表主键组装成对象/数组（子表若有自己的元数据则递归组装）。
// 无元数据 ⇒ 原样返回原始行（列名→值）。
//
// 数据来源是**端口**而不是引擎自己的 JDBC：本栈的读侧通路历来由宿主提供
// （`Ctx.biz_data_reader`，145/149 那几轮定的形状），这里给一对同签名闭包，
// 宿主用它包一层就能把 `as_biz_data_reader` 直接塞进 `with_biz_data_reader`
// ⇒ facade/core 的调用点与出口纪律一字不动（spec/12 §12.1「钉行为不钉机制」）。

///|
/// 一次「按列等值」的行查询请求（表 / 列 / 值）。
/// 三参数打平成**一个请求结构**，不是省字符：本栈的 `async` 闭包若体内不 await 就判
/// `unused_async`，而 `@spi` 的同步→异步桥只有 1/2 参两档（`async_of_sync` / `async_of_sync2`），
/// 单参数档才接得上 ⇒ 纯内存实现经桥注册、零新增告警（同 `InMemoryMetaProvider::as_provider` 那条）。
pub(all) struct TableKeyQuery {
  table : String
  column : String
  value : Int64
}

///|
/// 行读取端口：按「列等值」取单行 / 多行。列名与值都是引擎内部给的（外键列来自元数据），
/// 实现方（宿主/仓储）自己负责防注入。
pub(all) struct DynamicTableReaderFns {
  row_by_key : (async (TableKeyQuery) -> Map[String, Json]? raise @error.JeeflowError)
  rows_by_key : (async (TableKeyQuery) -> Array[Map[String, Json]] raise @error.JeeflowError)
}

///|
pub(all) struct MetaTableReader {
  meta : DynamicMetaProviderFns
  reader : DynamicTableReaderFns
}

///|
pub fn MetaTableReader::make(
  meta : DynamicMetaProviderFns,
  reader : DynamicTableReaderFns
) -> MetaTableReader {
  { meta, reader }
}

///|
/// JSON 列 → 值（java `fromJson:130-136`：解不回就原样带出，容错不炸回显）。
fn from_json_column(v : Json) -> Json {
  match v {
    Json::String(s) =>
      try {
        @json.parse_json(s)
      } catch {
        _ => @json.string_of(s)
      }
    _ => v
  }
}

///|
/// 该列是不是某个字段的 EXPAND 展开列（spec/10 §6「展开列不重复平铺」）
fn is_expand_column(meta : TableMeta, column : String) -> Bool {
  let mut hit = false
  for f in meta.fields {
    for _, col in f.expand_fields {
      if column_names_equal(col, column) {
        hit = true
      }
    }
  }
  hit
}

///|
/// 按元数据组装回显结果（键＝**表单字段名**；java `assemble:50-79` 同判据）
pub async fn MetaTableReader::assemble(
  self : MetaTableReader,
  meta : TableMeta,
  row : Map[String, Json]
) -> Map[String, Json] raise @error.JeeflowError {
  let result : Map[String, Json] = Map([])
  for f in meta.fields {
    let v = match find_data_key(row, f.column_name) {
      Some(k) => Some(row[k])
      None => None
    }
    match f.storage_type {
      Json => result[f.name] = match v {
        Some(pv) => from_json_column(pv)
        None => @json.null_json()
      }
      Expand => {
        let obj = @json.empty_object()
        let mut any = false
        for sub_name, col in f.expand_fields {
          match find_data_key(row, col) {
            Some(k) => {
              @json.obj_set(obj, sub_name, row[k])
              any = true
            }
            None => ()
          }
        }
        if any {
          result[f.name] = obj
        }
      }
      One2One =>
        match self.read_sub_table(meta, f, row) {
          Some(sub) => result[f.name] = sub
          None => ()
        }
      One2Many =>
        match self.read_sub_table(meta, f, row) {
          Some(sub) => result[f.name] = sub
          None => ()
        }
      Normal =>
        match v {
          Some(pv) => result[f.name] = pv
          None => ()
        }
    }
  }
  // 未在元数据里的列（process_instance_id / apply_user_id / 系统字段）原样带出，键统一小写
  // （跨方言一致，java `:73-77`）；EXPAND 展开列已消费 ⇒ 不再平铺
  for k, kv in row {
    if meta.find_field_by_column(k) is None && !is_expand_column(meta, k) {
      let low = k.to_lower()
      if result.get(low) is None {
        result[low] = kv
      }
    }
  }
  result
}

///|
/// 子表读取（java `readSubTable:102-119`）：外键＝主表主键；子表有元数据就递归组装，
/// 没有就原样带出行。主键取不到（列缺失/非整数）⇒ None（不猜、不插空对象）。
async fn MetaTableReader::read_sub_table(
  self : MetaTableReader,
  parent_meta : TableMeta,
  f : FieldMeta,
  row : Map[String, Json]
) -> Json? raise @error.JeeflowError {
  if f.target_table.is_empty() {
    return None
  }
  let pk_key = match find_data_key(row, parent_meta.primary_key) {
    Some(k) => k
    None => return None
  }
  let parent_pk = match @json.as_i64(row[pk_key]) {
    Some(n) => n
    None => return None
  }
  let fk = if f.foreign_key.is_empty() { parent_meta.primary_key } else { f.foreign_key }
  let sub_meta = (self.meta.load_table_meta)(f.target_table)
  match f.storage_type {
    One2One =>
      match (self.reader.row_by_key)(TableKeyQuery::{
        table: f.target_table, column: fk, value: parent_pk
      }) {
        Some(sub_row) =>
          match sub_meta {
            Some(m) => Some(@json.object_of(map_entries(self.assemble(m, sub_row))))
            None => Some(@json.object_of(map_entries(sub_row)))
          }
        None => None
      }
    _ => {
      let rows = (self.reader.rows_by_key)(TableKeyQuery::{
        table: f.target_table, column: fk, value: parent_pk
      })
      let items : Array[Json] = []
      for sub_row in rows {
        match sub_meta {
          Some(m) => items.push(@json.object_of(map_entries(self.assemble(m, sub_row))))
          None => items.push(@json.object_of(map_entries(sub_row)))
        }
      }
      Some(@json.array_of(items))
    }
  }
}

///|
/// Map → 有序键值对（`@json.object_of` 的入参形状）
fn map_entries(m : Map[String, Json]) -> Array[(String, Json)] {
  let out : Array[(String, Json)] = []
  for k, v in m {
    out.push((k, v))
  }
  out
}

///|
/// 按流程实例回显一条业务数据（定位键＝`process_instance_id`，与写入幂等键同款）。
/// 无记录 ⇒ None；无元数据 ⇒ 原始行（列名→值）。
pub async fn MetaTableReader::read_by_process_instance(
  self : MetaTableReader,
  table : String,
  instance_id : Int64
) -> Map[String, Json]? raise @error.JeeflowError {
  let row = match (self.reader.row_by_key)(TableKeyQuery::{
    table, column: "process_instance_id", value: instance_id
  }) {
    Some(r) => r
    None => return None
  }
  match (self.meta.load_table_meta)(table) {
    None => Some(row)   // 无元数据：原样返回
    Some(meta) => Some(self.assemble(meta, row))
  }
}

///|
/// 包成与 `Ctx.biz_data_reader` 同签名的闭包 ⇒ 宿主 `with_biz_data_reader(...)` 一行接好，
/// facade 的 bizData 出口与 issues/137 的泄漏纪律都不动。
pub fn MetaTableReader::as_biz_data_reader(
  self : MetaTableReader
) -> (async (String, Int64) -> Map[String, Json]? raise @error.JeeflowError) {
  let it = self
  async fn(table : String, instance_id : Int64) -> Map[String, Json]? raise @error.JeeflowError {
    it.read_by_process_instance(table, instance_id)
  }
}
