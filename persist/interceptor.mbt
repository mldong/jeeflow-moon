// PersistPostInterceptor —— 移植自 rust lib.rs PersistPostInterceptor（spec/09）
// ARCHIVE（结束同意归档 INSERT，幂等键 process_instance_id）/
// SYNC（发起 INSERT → 任务 UPDATE 按字段权限 → 结束定稿）。
// 字段提取：实例变量 f_/tf_ 前缀键去前缀（L2-06/07：不是 exec.args）。

///|
pub(all) struct PersistPostInterceptor {
  meta : DynamicMetaProviderFns
  table_writer : &DynamicTableWriter
  /// 系统列配置（issues/150 X5，java `JdbcDynamicTableWriter:57-65` 那组可配置项的同位）。
  system_fields : SystemFields
  /// 列匹配档（issues/151 X3，java `setStrictColumnMatch` 同位）：`false`＝缺省宽松
  /// （驼峰↔下划线归一），`true`＝忽略大小写的逐字相等。它与 writer 自己的 `strict`
  /// 是同一枚判据的**两处消费点**（这里＝元数据白名单 `filter_editable`，那里＝表结构过滤），
  /// 装配时两边都要给，只给一边就是两把尺子。
  strict_columns : Bool
}

///|
pub fn PersistPostInterceptor::make(
  meta_provider : InMemoryMetaProvider,
  table_writer : &DynamicTableWriter
) -> PersistPostInterceptor {
  {
    meta: meta_provider.as_provider(),
    table_writer,
    system_fields: SystemFields::make_default(),
    strict_columns: false,
  }
}

///|
/// 端口档装配（issues/146 缺口二）：集成方自备元数据来源（dev_schema/库内省）走这一支
pub fn PersistPostInterceptor::make_from_provider(
  meta : DynamicMetaProviderFns,
  table_writer : &DynamicTableWriter
) -> PersistPostInterceptor {
  {
    meta,
    table_writer,
    system_fields: SystemFields::make_default(),
    strict_columns: false,
  }
}

///|
/// 系统列配置装配口（issues/150 X5）：业务表的系统列叫 `add_time`/`creator` 之类、
/// 或不想填 `is_deleted` 的集成方用它。缺省档见 `SystemFields::make_default`。
pub fn PersistPostInterceptor::with_system_fields(
  self : PersistPostInterceptor,
  system_fields : SystemFields
) -> PersistPostInterceptor {
  {
    meta: self.meta,
    table_writer: self.table_writer,
    system_fields,
    strict_columns: self.strict_columns,
  }
}

///|
/// 严格列匹配装配口（issues/151 X3）
pub fn PersistPostInterceptor::with_strict_columns(
  self : PersistPostInterceptor,
  strict_columns : Bool
) -> PersistPostInterceptor {
  {
    meta: self.meta,
    table_writer: self.table_writer,
    system_fields: self.system_fields,
    strict_columns,
  }
}

///|
/// 装配为引擎拦截器（order=100，后置）
pub fn PersistPostInterceptor::as_interceptor(
  self : PersistPostInterceptor
) -> @spi.InterceptorFn {
  let it = self
  { order: 100, run: async fn(exec) raise @error.JeeflowError { it.intercept(exec) } }
}

///|
///|
/// 本拦截器在流程定义里的声明名（与 java 类全名逐字一致——门禁夹具与 mldong 后台写的都是这个串）
let persist_class_name : String = "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor"

///|
/// 定义级 opt-in（java 的挂载方式＝"声明即挂载"：`NodeModel.execPostInterceptors` 先取节点级
/// `postInterceptors`、空则回落流程级，没声明就根本不实例化本拦截器）。moon 的通道是宿主全局注册
/// （`Ctx::register_interceptor`），所以把"声明"降级成挂载条件——不这么补，②那条缺省 ARCHIVE
/// 会把每一条"办结+同意"的流程都拖去写一张与流程同名的表，表不存在即硬失败
/// （`JdbcDynamicTableWriter.exists()` 抛 SQLException，且拦截器按 spec/12 §12.2 不隔离）。
/// 比对规则与 java 的 `Class.forName` 等价：逗号分段、逐段 trim、与类全名逐字相等。
fn persist_interceptor_declared(exec : @exec.Execution) -> Bool {
  let name = persist_class_name
  let node_decl = match exec.current_node {
    Some(n) =>
      match n.properties.get("postInterceptors") {
        Some(Json::String(s)) => s.trim(chars=" \t\r\n").to_owned()
        _ => ""
      }
    None => ""
  }
  let decl = if node_decl.is_empty() {
    exec.process_model.post_interceptors.unwrap_or("")
  } else {
    node_decl
  }
  if decl.is_empty() {
    return false
  }
  let mut hit = false
  for piece in decl.split(",") {
    if piece.trim(chars=" \t\r\n").to_owned() == name {
      hit = true
    }
  }
  hit
}

///|
pub async fn PersistPostInterceptor::intercept(
  self : PersistPostInterceptor,
  exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  // 未声明＝本流程不启用 persist（与 java 的挂载条件同语义，与 persistMode 是否配置无关）
  if !persist_interceptor_declared(exec) {
    return
  }
  // spec/09 §4.0：`SYNC` 才走同步档，**其余一律回落 ARCHIVE**（缺省、大小写变体、未知值都不报错）；
  // java `PersistPostInterceptor.java:92-96` 就是这个 if/else——issues/150 的②补的正是这条缺省语义。
  let mode = match exec.process_model.persist_mode {
    Some(pm) =>
      match PersistMode::from_str(pm) {
        Some(Sync) => Sync
        _ => Archive
      }
    None => Archive
  }
  let table = match self.resolve_table(exec.process_model) {
    Some(t) => t
    None => return // 未配置表名（relTableName 与流程 name 皆空）⇒ 静默跳过（spec/09 §4.6）
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

///|
async fn PersistPostInterceptor::intercept_archive(
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
  // 层①同链标记（issues/150 ③／X4）：位置与 java 一致——四道时机判据之后、查库之前
  if !self.mark_chain(exec) {
    return
  }
  // 幂等：process_instance_id 先查后插（C16）
  if (self.table_writer).exists_by_key(table, "process_instance_id", exec.process_instance.instance_id) {
    return
  }
  let data = self.extract_fields(exec.process_instance.variables, None, false, true)
  self.fill_context(data, exec)
  let meta = self.load_meta(table)
  let filtered = self.filter_editable(meta, data)
  if filtered.is_empty() {
    return
  }
  fill_system_fields_with(self.system_fields, filtered, exec.operator, true)
  let _ = (self.table_writer).insert(table, filtered)
}

///|
async fn PersistPostInterceptor::intercept_sync(
  self : PersistPostInterceptor,
  exec : @exec.Execution,
  table : String
) -> Unit raise @error.JeeflowError {
  let node = match exec.current_node {
    Some(n) => n
    None => return
  }
  let instance = exec.process_instance
  // 任务节点＝TaskModel 那一档（issues/150 X8）。java `PersistPostInterceptor.java:128` 判的是
  // `execution.getNodeModel() instanceof TaskModel`，而 spec/02 §6.1 把 custom 记录类明确划在
  // 「不解析参与者、不建待办」那一侧 ⇒ 记录类同样不是任务节点。从前它与 Task 合流，于是 SYNC 下
  // 记录类被当任务节点全量写 f_，还把状态列写成 DOING(10)——一个记录类节点不该有的状态。
  let is_task = node.node_type is @parser.Task
  // 层①同链标记（X4）：与 ARCHIVE 同位——先标记，再查库定 INSERT/UPDATE
  if !self.mark_chain(exec) {
    return
  }
  let exists = (self.table_writer).exists_by_key(table, "process_instance_id", instance.instance_id)
  // 任务节点按目标节点 field.PERMISSION_* 过滤；非任务节点不带 f_/tf_（首次 INSERT 例外全量）
  let field_perm = if is_task {
    self.resolve_field_permission(node)
  } else {
    None
  }
  // issues/150 X6：两枚 flag 与 java `:130-131` 同形，都由 `!exists || taskNode` 推。
  // 旧形状把 `tf_` 那一档硬编码成 `true` ⇒ 结束/判断/fork/join 也会把 tf_* 冗余列写回去，
  // 覆盖掉任务节点声明的只读/隐藏限制（spec/09 §4.2「定稿只写状态＋上下文」就这么废的）。
  // 权限档同理：首次 INSERT（`!exists`）不带权限过滤＝java 那条「发起全量」的例外。
  let include_fields = !exists || is_task
  let perm = if !exists {
    None
  } else {
    field_perm
  }
  let data = self.extract_fields(instance.variables, perm, include_fields, include_fields)
  // 状态字段：任务节点写 DOING(10)——execPost 在流转链之后触发，此刻实例 state 可能已是终态，
  // 不能拿 instance.state（java `:137` 同判据）；非任务节点写实例当前态，
  // 列不存在由 `put_state_field` 的列探测滤掉，不炸流程。
  let state_code = if is_task {
    10
  } else {
    instance.state
  }
  self.put_state_field(table, data, node.id, state_code)
  self.fill_context(data, exec)
  let meta = self.load_meta(table)
  let filtered = self.filter_editable(meta, data)
  if filtered.is_empty() {
    return
  }
  if exists {
    fill_system_fields_with(self.system_fields, filtered, exec.operator, false)
    (self.table_writer).update_by_key(table, filtered, "process_instance_id", instance.instance_id)
  } else {
    fill_system_fields_with(self.system_fields, filtered, exec.operator, true)
    let _ = (self.table_writer).insert(table, filtered)
  }
}

///|
/// 同链重复触发防护·层①（issues/150 ③／X4，java `markChain:166-173` 同位）：
/// 键＝`__persist_executed_{实例ID}_{节点ID}`，写进 `exec.args`。
/// 本栈的 args 是整条流转链共用的一份 Map（`Execution::make` 每请求一次，`execute_node` 递归时
/// 只换 `current_node`）⇒ 写它等效 java 那份 LinkedHashMap；跨请求的重复由层②数据库幂等兜。
/// 节点级而非流程级＝1.8.0 那次改动的原意：任务推进与结束定稿是两个节点，都必须放行一次，
/// 只有「同一节点在同一条链里被重复触发」（并行 fork/join 汇聚那种）才该被这一层挡住。
fn PersistPostInterceptor::mark_chain(
  self : PersistPostInterceptor,
  exec : @exec.Execution
) -> Bool {
  let _ = self
  let node_id = match exec.current_node {
    Some(n) => n.id
    None => ""
  }
  let chain_key = "__persist_executed_\{exec.process_instance.instance_id}_\{node_id}"
  // `Json::True` 在 core 之外不可构造（pub enum 未带 pub(all) => read-only type），
  // 布尔档一律走 @json 的构造/读取助手。
  let blocked = match exec.args.get(chain_key) {
    Some(v) => @json.as_bool(v) == Some(true)
    None => false
  }
  if blocked {
    false
  } else {
    exec.args.inner()[chain_key] = @json.bool_of(true)
    true
  }
}

///|
/// 表名：relTableName 缺省回落流程 name
fn PersistPostInterceptor::resolve_table(self : PersistPostInterceptor, model : @parser.ProcessModel) -> String? {
  let _ = self
  let name = match model.rel_table_name {
    Some(t) => t
    None => model.name
  }
  let trimmed = name.trim(chars=" \t\r\n").to_owned()
  if trimmed.is_empty() {
    None
  } else {
    Some(trimmed)
  }
}

///|
async fn PersistPostInterceptor::load_meta(
  self : PersistPostInterceptor,
  table : String
) -> TableMeta raise @error.JeeflowError {
  match (self.meta.load_table_meta)(table) {
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
  let _ = self
  let filtered : Map[String, Json] = Map([])
  for field in meta.fields {
    if field.is_editable() {
      // 键匹配与写侧同一枚尺子（issues/151 X3）：元数据里是下划线列名，表单变量去掉 `f_`
      // 之后常是驼峰 ⇒ 精确档在这里就静默丢列。输出键取**元数据列名**，
      // 保证落进 SQL 的永远是真列名。
      match find_data_key(data, field.column_name, strict=self.strict_columns) {
        Some(k) => filtered[field.column_name] = data[k]
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
  let data : Map[String, Json] = Map([])
  for key, value in variables.inner() {
    if key.has_prefix("f_") {
      let name = key[2:].to_owned()
      if !name.is_empty() && include_form_fields && self.is_editable(field_perm, name) {
        data[name] = value
      }
    } else if key.has_prefix("tf_") {
      let name = key[3:].to_owned()
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
        Json::Object(obj) => if obj.length() == 0 { None } else { Some(obj) }
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
    Some(p) => if p.length() == 0 { return true } else { p }
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
/// issues/149: writer 写侧已 async 化，本函数是全仓唯一在同步函数里调 writer 的位点 => 随本轮改 async（调用方 intercept_sync 本就是 async）。
async fn PersistPostInterceptor::put_state_field(
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
