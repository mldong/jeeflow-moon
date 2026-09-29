// ServiceContext（MoonBit 形态）—— 移植自 rust context.rs + spi.rs 小 SPI
// 大 SPI 走泛型参数 [R, E]；小 SPI 全闭包字段（方案 §3.2/§3.4.3）。
// ITransactionTemplate 口径（D-M1-1）：Unit 形态——回调内写外部可变单元带回结果。
// MoonBit 0.10 无可靠 typealias，函数类型全部内联书写。

///|
/// IOrgUserProvider 闭包组（spec/05 v1.6.0）
pub(all) struct OrgUserProviderFns {
  find_dept_leaders : (String) -> Array[String] raise @error.JeeflowError
  find_dept_main_leaders : (String) -> Array[String] raise @error.JeeflowError
  find_by_role : (String) -> Array[String] raise @error.JeeflowError
}

///|
/// IUserSearchProvider 闭包组（spec/06 §4.3/§6）
pub(all) struct UserSearchProviderFns {
  page : (@model.PageQuery) -> @model.PageResult[Map[String, Json]] raise @error.JeeflowError
  find_by_id : (String) -> Map[String, Json]? raise @error.JeeflowError
}

///|
/// IJsonProvider 闭包组（spec/05）
pub(all) struct JsonProviderFns {
  to_json : (Json) -> String
  from_json : (String) -> Json raise @error.JeeflowError
  is_json : (String) -> Bool
}

///|
/// 默认 JsonProvider（core stdlib @cjson 承载）
pub fn default_json_provider() -> JsonProviderFns {
  {
    to_json: fn(v) { v.stringify() },
    from_json: (s) => @json.parse_json(s),
    is_json: fn(s) { @cjson.valid(s) },
  }
}

///|
/// IActionPermissionProvider 默认实现：wf:{action /→:}（spec/06 §2.6）
pub fn default_action_permission_provider(action : String) -> Array[String] {
  ["wf:\{action.replace(old="/", new=":")}"]
}

///|
/// FlowInterceptor 闭包形态（带 order）
pub(all) struct InterceptorFn {
  order : Int
  run : (@exec.Execution) -> Unit raise @error.JeeflowError
}

///|
/// ServiceContext —— 启动期构建、运行期只读的 SPI 注册表
pub(all) struct Ctx[R, E] {
  repository : R
  ext_repository : E
  // ── 小 SPI（闭包字段）──
  mut user_provider : ((String) -> @model.UserInfo? raise @error.JeeflowError)?
  mut org_user_provider : OrgUserProviderFns?
  mut user_search_provider : UserSearchProviderFns?
  mut json_provider : JsonProviderFns?
  mut expression_evaluator : ((String, Map[String, Json]) -> Json raise @error.JeeflowError)?
  mut id_generator : (() -> Int64 raise @error.JeeflowError)?
  mut action_permission_provider : ((String) -> Array[String])?
  mut biz_data_reader : ((String, Int64) -> Map[String, Json]? raise @error.JeeflowError)?
  // ── 按名注册表 ──
  assignment_handlers : Map[String, (@exec.Execution) -> String raise @error.JeeflowError]
  decision_handlers : Map[String, (@exec.Execution) -> String raise @error.JeeflowError]
  /// 记录类（`snaker:custom`）节点处理器（issues/142 A 批 · spec/02 §6.1/§6.2）。
  /// 键＝流程定义 `properties.clazz` 的**原样字符串**：MoonBit 没有反射，java 那句
  /// `Class.forName(clazz)` 在本栈无从谈起 ⇒ 与 C#/Python 栈同策「按名注册、按名解析」，
  /// 由集成方把 JVM 类名/任意自定义串映射到闭包（共享夹具 `flows/08-custom-node.json`
  /// 里就是 `com.mldong.jeeflow.test.TestCustomHandler`）。
  /// 返回值取 `Json`：本栈流程变量的载体就是 Json（`@json.FlowData`），处理器无返回值时
  /// 返回 `@json.null_json()` ⇒ 引擎不写键（对齐 python「ret is not None 才写」）。
  custom_handlers : Map[String, (@exec.Execution) -> Json raise @error.JeeflowError]
  // ── 有序集合 ──
  interceptors : Array[InterceptorFn]
  /// 前置扩展位（issues/116 批次 D）：与 `interceptors` **分开注册、分开触发**。
  /// 本栈 `InterceptorFn` 只有一个 `run`（无 before/after 之分），若在 `fire_pre_interceptors`
  /// 里复用同一数组，只在后置注册的既有实现（persist 的 PersistPostInterceptor）会被
  /// 双触发（归档/SYNC 写两遍）。故 pre 另起一条通道，pre 体系的整体 canonical 形态
  /// （含第三方自写拦截器的 pre 语义）仍归 issues/104 §P1。
  pre_interceptors : Array[InterceptorFn]
  event_listeners : Array[((@event.ProcessEvent) -> Unit raise)]
  /// 委托自动生效开关（issues/116 批次 D / spec 06 §4.5 条款 3）：**默认开启**
  /// （`Ctx::new` 里给 true，全栈唯一构造入口，不存在"零值即关闭"的旁路）。
  mut surrogate_auto_apply : Bool
}

///|
pub fn[R, E] Ctx::new(repository : R, ext_repository : E) -> Ctx[R, E] {
  {
    repository,
    ext_repository,
    user_provider: None,
    org_user_provider: None,
    user_search_provider: None,
    json_provider: Some(default_json_provider()),
    expression_evaluator: None,
    id_generator: None,
    action_permission_provider: None,
    biz_data_reader: None,
    assignment_handlers: Map([]),
    decision_handlers: Map([]),
    custom_handlers: Map([]),
    interceptors: [],
    pre_interceptors: [],
    event_listeners: [],
    surrogate_auto_apply: true,
  }
}

///|
pub fn[R, E] Ctx::repository(self : Ctx[R, E]) -> R {
  self.repository
}

///|
pub fn[R, E] Ctx::ext_repository(self : Ctx[R, E]) -> E {
  self.ext_repository
}

///|
pub fn[R, E] Ctx::with_user_provider(
  self : Ctx[R, E],
  p : (String) -> @model.UserInfo? raise @error.JeeflowError
) -> Ctx[R, E] {
  self.user_provider = Some(p)
  self
}

///|
pub fn[R, E] Ctx::with_org_user_provider(self : Ctx[R, E], p : OrgUserProviderFns) -> Ctx[R, E] {
  self.org_user_provider = Some(p)
  self
}

///|
pub fn[R, E] Ctx::with_user_search_provider(self : Ctx[R, E], p : UserSearchProviderFns) -> Ctx[R, E] {
  self.user_search_provider = Some(p)
  self
}

///|
pub fn[R, E] Ctx::with_expression_evaluator(
  self : Ctx[R, E],
  f : (String, Map[String, Json]) -> Json raise @error.JeeflowError
) -> Ctx[R, E] {
  self.expression_evaluator = Some(f)
  self
}

///|
pub fn[R, E] Ctx::with_id_generator(
  self : Ctx[R, E],
  f : () -> Int64 raise @error.JeeflowError
) -> Ctx[R, E] {
  self.id_generator = Some(f)
  self
}

///|
pub fn[R, E] Ctx::with_action_permission_provider(
  self : Ctx[R, E],
  f : (String) -> Array[String]
) -> Ctx[R, E] {
  self.action_permission_provider = Some(f)
  self
}

///|
pub fn[R, E] Ctx::with_biz_data_reader(
  self : Ctx[R, E],
  f : (String, Int64) -> Map[String, Json]? raise @error.JeeflowError
) -> Ctx[R, E] {
  self.biz_data_reader = Some(f)
  self
}

///|
/// 委托自动生效开关（issues/116 批次 D / spec 06 §4.5 条款 3）：**默认开启**
/// （`Ctx::new` 里置 true，本栈 `Ctx` 仅此一个构造函数，无"零值即关闭"旁路）。
/// 传 `false` 即显式关闭，行为回到"只有 `processSurrogate/*` 台账 CRUD、建单不并入代理人"。
/// 引擎侧消费点见 `engine/surrogate.mbt` 的 `apply_surrogate`。
pub fn[R, E] Ctx::with_surrogate_auto_apply(self : Ctx[R, E], on : Bool) -> Ctx[R, E] {
  self.surrogate_auto_apply = on
  self
}

///|
/// 前置拦截器注册（issues/116 批次 D 补的最小挂点）：与 `register_interceptor`（后置）
/// 分开的通道，避免把既有只在后置注册的实现变成双触发。
/// ⚠️ pre 体系的整体 canonical 形态归 issues/104 §P1，本轮只打通"有地方挂"这一步。
pub fn[R, E] Ctx::register_pre_interceptor(self : Ctx[R, E], i : InterceptorFn) -> Unit {
  self.pre_interceptors.push(i)
  self.pre_interceptors.sort_by(fn(a, b) { a.order.compare(b.order) })
}

///|
pub fn[R, E] Ctx::json_provider_or_default(self : Ctx[R, E]) -> JsonProviderFns {
  match self.json_provider {
    Some(p) => p
    None => default_json_provider()
  }
}

///|
/// IIdGenerator：未注入时回退默认雪花（worker 0）
pub fn[R, E] Ctx::id_generator_or_default(
  self : Ctx[R, E]
) -> () -> Int64 raise @error.JeeflowError {
  match self.id_generator {
    Some(f) => f
    None => {
      let gen = @id_gen.DefaultIdGenerator::new(0L)
      fn() { gen.next_id() }
    }
  }
}

///|
/// IActionPermissionProvider：未注入用默认 wf:{action /→:}
pub fn[R, E] Ctx::permission_codes(self : Ctx[R, E], action : String) -> Array[String] {
  match self.action_permission_provider {
    Some(f) => (f)(action)
    None => default_action_permission_provider(action)
  }
}

///|
pub fn[R, E] Ctx::register_assignment_handler(
  self : Ctx[R, E],
  name : String,
  handler : (@exec.Execution) -> String raise @error.JeeflowError
) -> Unit {
  self.assignment_handlers[name] = handler
}

///|
pub fn[R, E] Ctx::register_decision_handler(
  self : Ctx[R, E],
  name : String,
  handler : (@exec.Execution) -> String raise @error.JeeflowError
) -> Unit {
  self.decision_handlers[name] = handler
}

///|
pub fn[R, E] Ctx::register_interceptor(self : Ctx[R, E], i : InterceptorFn) -> Unit {
  self.interceptors.push(i)
  self.interceptors.sort_by(fn(a, b) { a.order.compare(b.order) })
}

///|
pub fn[R, E] Ctx::register_event_listener(self : Ctx[R, E], l : (@event.ProcessEvent) -> Unit raise) -> Unit {
  self.event_listeners.push(l)
}

///|
pub fn[R, E] Ctx::event_listeners(self : Ctx[R, E]) -> Array[((@event.ProcessEvent) -> Unit raise)] {
  self.event_listeners
}

///|
pub fn[R, E] Ctx::find_assignment_handler(
  self : Ctx[R, E],
  name : String
) -> ((@exec.Execution) -> String raise @error.JeeflowError)? {
  self.assignment_handlers.get(name)
}

///|
pub fn[R, E] Ctx::find_decision_handler(
  self : Ctx[R, E],
  name : String
) -> ((@exec.Execution) -> String raise @error.JeeflowError)? {
  self.decision_handlers.get(name)
}

///|
/// 注册记录类节点处理器（issues/142 A 批）。键＝定义里的 `clazz` 原样串，不做归一化
/// （大小写/前缀归一是 issues/141 G4 义务 1 的 C 方案，立法在前、实现另批，这里不抢跑）。
pub fn[R, E] Ctx::register_custom_handler(
  self : Ctx[R, E],
  clazz : String,
  handler : (@exec.Execution) -> Json raise @error.JeeflowError
) -> Unit {
  self.custom_handlers[clazz] = handler
}

///|
/// 按 `clazz` 解析记录类节点处理器；未注册 ⇒ `None`（**引擎侧记日志后照常落历史行并续流，
/// 不打断建单**，spec/02 §6.2 第 2 条；处理器**自身**执行失败不在豁免内，照旧外抛）。
pub fn[R, E] Ctx::find_custom_handler(
  self : Ctx[R, E],
  clazz : String
) -> ((@exec.Execution) -> Json raise @error.JeeflowError)? {
  if clazz.is_empty() {
    None
  } else {
    self.custom_handlers.get(clazz)
  }
}
