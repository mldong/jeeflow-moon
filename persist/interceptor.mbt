// PersistPostInterceptor —— 移植自 rust lib.rs PersistPostInterceptor（spec/09）
// ARCHIVE（结束同意归档 INSERT，幂等键 process_instance_id）/
// SYNC（发起 INSERT → 任务 UPDATE 按字段权限 → 结束定稿）。
// 字段提取：实例变量 f_/tf_ 前缀键去前缀（L2-06/07：不是 exec.args）。

///|
pub(all) struct PersistPostInterceptor {
  meta_provider : InMemoryMetaProvider
  table_writer : &DynamicTableWriter
}

///|
pub fn PersistPostInterceptor::make(
  meta_provider : InMemoryMetaProvider,
  table_writer : &DynamicTableWriter
) -> PersistPostInterceptor {
  { meta_provider, table_writer }
}

///|
/// 装配为引擎拦截器（order=100，后置）
pub fn PersistPostInterceptor::as_interceptor(
  self : PersistPostInterceptor
) -> @spi.InterceptorFn {
  let it = self
  { order: 100, run: fn(exec) { it.intercept(exec) } }
}

///|
pub fn PersistPostInterceptor::intercept(
  self : PersistPostInterceptor,
  exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  let persist_mode = exec.process_model.persist_mode
  match persist_mode {
    None => return // 未配置持久化
    Some(pm) =>
      match PersistMode::from_str(pm) {
        None => return // 未知模式：静默跳过
        Some(mode) => {
          let table = match self.resolve_table(exec.process_model) {
            Some(t) => t
            None => return
          }
          if !is_table_name_safe(table) {
            // 配置错误显性暴露（对齐 Java/Go，issues/60 原则）
            raise @error.Business("非法业务表名: \{table}")
          }
          match mode {
            Archive => self.intercept_archive(exec, table)
            Sync => self.intercept_sync(exec, table)
          }
        }
      }
  }
}

///|
fn PersistPostInterceptor::intercept_archive(
  self : PersistPostInterceptor,
  exec : @exec.Execution,
  table : String
) -> Unit raise @error.JeeflowError {
  // 时机：仅结束节点 + FINISHED(20) + submitType=1
  let is_end = match exec.current_node {
    Some(n) => n.node_type is @parser.End
    None => false
  }
  if !is_end {
    return
  }
  if exec.process_instance.state != 20 {
    return
  }
  if exec.args.get_i64("submitType") != Some(1L) {
    return
  }
  // 幂等：process_instance_id 先查后插（C16）
  if (self.table_writer).exists_by_key(table, "process_instance_id", exec.process_instance.instance_id) {
    return
  }
  let data = self.extract_fields(exec.process_instance.variables, None, false, true)
  self.fill_context(data, exec)
  let meta = self.meta(table)
  let filtered = self.filter_editable(meta, data)
  if filtered.is_empty() {
    return
  }
  fill_system_fields(filtered, exec.operator, true)
  let _ = (self.table_writer).insert(table, filtered)
}

///|
fn PersistPostInterceptor::intercept_sync(
  self : PersistPostInterceptor,
  exec : @exec.Execution,
  table : String
) -> Unit raise @error.JeeflowError {
  let node = match exec.current_node {
    Some(n) => n
    None => return
  }
  let instance = exec.process_instance
  let is_task = node.node_type is @parser.Task || node.node_type is @parser.Custom
  let exists = (self.table_writer).exists_by_key(table, "process_instance_id", instance.instance_id)
  // 任务节点按目标节点 field.PERMISSION_* 过滤；start/结束不带 f_（start 首次 INSERT 例外全量）
  let field_perm = if is_task {
    self.resolve_field_permission(node)
  } else {
    None
  }
  let include_fields = !exists || is_task
  let data = self.extract_fields(instance.variables, field_perm, true, include_fields)
  // 状态字段：任务节点写 DOING(10)；结束节点写实例终态；start 无状态列跳过
  let state_code : Int? = if is_task {
    Some(10)
  } else if node.node_type is @parser.End {
    Some(instance.state)
  } else {
    None
  }
  match state_code {
    Some(code) => self.put_state_field(table, data, node.id, code)
    None => ()
  }
  self.fill_context(data, exec)
  let meta = self.meta(table)
  let filtered = self.filter_editable(meta, data)
  if filtered.is_empty() {
    return
  }
  if exists {
    fill_system_fields(filtered, exec.operator, false)
    (self.table_writer).update_by_key(table, filtered, "process_instance_id", instance.instance_id)
  } else {
    fill_system_fields(filtered, exec.operator, true)
    let _ = (self.table_writer).insert(table, filtered)
  }
}

///|
/// 表名：relTableName 缺省回落流程 name
fn PersistPostInterceptor::resolve_table(self : PersistPostInterceptor, model : @parser.ProcessModel) -> String? {
  let name = match model.rel_table_name {
    Some(t) => t
    None => model.name
  }
  let trimmed = name.trim(chars=" \t\r\n").to_string()
  if trimmed.is_empty() {
    None
  } else {
    Some(trimmed)
  }
}

///|
fn PersistPostInterceptor::meta(self : PersistPostInterceptor, table : String) -> TableMeta raise @error.JeeflowError {
  match (self.meta_provider).get_table_meta(table) {
    Some(m) => m
    None => raise @error.Business("表元数据不存在: \{table}")
  }
}

///|
/// 按列权限过滤可写字段
fn PersistPostInterceptor::filter_editable(
  self : PersistPostInterceptor,
  meta : TableMeta,
  data : Map[String, Json]
) -> Map[String, Json] {
  let filtered : Map[String, Json] = Map::new()
  for field in meta.fields {
    if field.is_editable() {
      match data.get(field.column_name) {
        Some(v) => filtered[field.column_name] = v
        None => ()
      }
    }
  }
  filtered
}

///|
/// 提取字段：f_/tf_ 去前缀（SYNC 任务节点按字段权限过滤 f_）
fn PersistPostInterceptor::extract_fields(
  self : PersistPostInterceptor,
  variables : @json.FlowData,
  field_perm : Map[String, Json]?,
  include_task_fields : Bool,
  include_form_fields : Bool
) -> Map[String, Json] {
  let data : Map[String, Json] = Map::new()
  for key, value in variables.inner() {
    if key.starts_with("f_") {
      let name = key.substring(start=2).to_string()
      if !name.is_empty() && include_form_fields && self.is_editable(field_perm, name) {
        data[name] = value
      }
    } else if key.starts_with("tf_") {
      let name = key.substring(start=3).to_string()
      if !name.is_empty() && include_task_fields {
        data[name] = value
      }
    }
  }
  data
}

///|
/// 节点字段权限（properties.field 的 PERMISSION_x）
fn PersistPostInterceptor::resolve_field_permission(
  self : PersistPostInterceptor,
  node : @parser.NodeModel
) -> Map[String, Json]? {
  let _ = self
  match node.properties.get("field") {
    Some(f) =>
      match f {
        Json::Object(obj) => if obj.size() == 0 { None } else { Some(obj) }
        _ => None
      }
    None => None
  }
}

///|
/// 字段可编辑判定（issues/25 双格式键：PERMISSION_f_{全名} 优先 / PERMISSION_{去前缀}）
fn PersistPostInterceptor::is_editable(
  self : PersistPostInterceptor,
  field_perm : Map[String, Json]?,
  field_name : String
) -> Bool {
  let _ = self
  let perm = match field_perm {
    Some(p) => if p.size() == 0 { return true } else { p }
    None => return true
  }
  let val = match perm.get("PERMISSION_f_\{field_name}") {
    Some(v) => Some(v)
    None => perm.get("PERMISSION_\{field_name}")
  }
  match val {
    None => true
    Some(v) =>
      match @json.as_i64(v) {
        Some(n) => n == 2L
        None => false
      }
  }
}

///|
/// 状态字段：优先 {节点ID}_{状态码} 列，无则 {节点ID} 列（列探测过滤）
fn PersistPostInterceptor::put_state_field(
  self : PersistPostInterceptor,
  table : String,
  data : Map[String, Json],
  node_id : String,
  state_code : Int
) -> Unit raise @error.JeeflowError {
  if node_id.is_empty() {
    return
  }
  let candidates = ["\{node_id}_\{state_code}", node_id]
  let kept = (self.table_writer).columns(table, candidates)
  match kept.get(0) {
    Some(col) => data[col] = @json.number_of(state_code.to_int64())
    None => ()
  }
}

///|
/// 流程上下文字段（putIfAbsent 语义，C17：create_user 回落 apply_user_id）
fn PersistPostInterceptor::fill_context(self : PersistPostInterceptor, data : Map[String, Json], exec : @exec.Execution) -> Unit {
  let _ = self
  let instance = exec.process_instance
  if data.get("process_instance_id") is None {
    data["process_instance_id"] = @json.number_of(instance.instance_id)
  }
  if data.get("apply_user_id") is None {
    data["apply_user_id"] = @json.string_of(instance.operator)
  }
  match instance.variables.get_str("u_deptId") {
    Some(dept) =>
      if data.get("apply_dept_id") is None {
        data["apply_dept_id"] = @json.string_of(dept)
      }
    None => ()
  }
}
