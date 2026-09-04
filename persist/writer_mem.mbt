// 内存 DynamicTableWriter / MetaTableReader（T0 测试与轻量 demo 用）

///|
pub(all) struct InMemoryTableWriter {
  mut id_counter : Int64
  tables : Map[String, Map[Int64, Map[String, Json]]]
}

///|
pub fn InMemoryTableWriter::new() -> InMemoryTableWriter {
  { id_counter: 1L, tables: Map::new() }
}

///|
pub fn InMemoryTableWriter::get_table_rows(self : InMemoryTableWriter, table_name : String) -> Array[Map[String, Json]] {
  match self.tables.get(table_name) {
    Some(t) => {
      let out : Array[Map[String, Json]] = []
      for _, row in t {
        out.push(row)
      }
      out
    }
    None => []
  }
}

///|
pub fn InMemoryTableWriter::get_row(self : InMemoryTableWriter, table_name : String, id : Int64) -> Map[String, Json]? {
  match self.tables.get(table_name) {
    Some(t) => t.get(id)
    None => None
  }
}

///|
pub fn InMemoryTableWriter::get_row_by_key(
  self : InMemoryTableWriter,
  table_name : String,
  key : String,
  value : Int64
) -> Map[String, Json]? {
  match self.tables.get(table_name) {
    Some(t) => {
      let mut found : Map[String, Json]? = None
      for _, row in t {
        match row.get(key) {
          Some(v) =>
            match @json.as_i64(v) {
              Some(n) => if n == value { found = Some(row) }
              None => ()
            }
          None => ()
        }
      }
      found
    }
    None => None
  }
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn insert(self, table_name, data) {
  if !is_table_name_safe(table_name) {
    raise @error.Business("非法表名: \{table_name}")
  }
  let id = self.id_counter
  self.id_counter = id + 1L
  let row : Map[String, Json] = Map::new()
  for k, v in data {
    row[k] = v
  }
  row["id"] = @json.number_of(id)
  match self.tables.get(table_name) {
    Some(t) => t[id] = row
    None => {
      let t : Map[Int64, Map[String, Json]] = Map::new()
      t[id] = row
      self.tables[table_name] = t
    }
  }
  id
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn update(self, table_name, id, data) {
  let table = self.tables.get(table_name)
  let row = match table {
    Some(t) => t.get(id)
    None => None
  }
  match row {
    Some(r) =>
      for k, v in data {
        r[k] = v
      }
    None => raise @error.Business("Row \{id} not found in \{table_name}")
  }
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn exists(self, table_name, id) {
  match self.tables.get(table_name) {
    Some(t) => t.get(id) is Some(_)
    None => false
  }
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn exists_by_key(self, table_name, key, value) {
  match self.tables.get(table_name) {
    Some(t) => {
      let mut any = false
      for _, row in t {
        match row.get(key) {
          Some(v) =>
            match @json.as_i64(v) {
              Some(n) => if n == value { any = true }
              None => ()
            }
          None => ()
        }
      }
      any
    }
    None => false
  }
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn update_by_key(self, table_name, data, key, value) {
  let row = self.get_row_by_key(table_name, key, value)
  match row {
    Some(r) =>
      for k, v in data {
        r[k] = v
      }
    None => raise @error.Business("Row with \{key}=\{value} not found in \{table_name}")
  }
}

///|
pub impl DynamicTableWriter for InMemoryTableWriter with fn columns(self, _table_name, candidates) {
  candidates.copy()
}
