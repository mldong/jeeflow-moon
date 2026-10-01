// facade actions：define(8) + instance(14) + task(10) —— 对齐 java JeeflowFacade 各私有方法

// ═══ 流程定义 ═══

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::define_page(
  self : Facade[R, E],
  args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let page = (self.repo).page_defines(@model.PageQuery::new(page_num, page_size))
  finalize_page(page, define_row_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::define_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let define_info = match (self.repo).find_define_by_id(id) {
    Some(d) => d
    None => raise @error.DefineNotFound(id)
  }
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(define_info.id))
  @json.obj_set(o, "name", @json.string_of(define_info.name))
  @json.obj_set(o, "display_name", @json.string_of(define_info.display_name))
  @json.obj_set(o, "type", @json.string_of(define_info.define_type))
  @json.obj_set(o, "state", num_json(define_info.state))
  @json.obj_set(o, "version", num_json(define_info.version))
  @json.obj_set(o, "jsonObject", parse_graph(define_info.content) |> opt_json_wrap)
  o
}

///|
fn opt_json_wrap(v : Json?) -> Json {
  match v {
    Some(x) => x
    None => @json.null_json()
  }
}

///|
/// 发起并自动完成申请节点（define/instance 共用）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::start_and_execute(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let define_id = match arg_i64(args, "processDefineId") {
    Some(v) => v
    None => raise @error.Business("缺少processDefineId参数")
  }
  let operator = operator_arg(args)
  let flow_args = args_to_flow_data(args, ["processDefineId", "operator"])
  let inst = (self.engine).start_async(define_id, operator, flow_args)
  // 自动完成申请节点（assignee=applicant → 发起人）
  let doing = (self.repo).find_doing_tasks(inst.instance_id, [])
  for task in doing {
    (self.repo).add_task_actor(task.task_id, [operator])
    flow_args.insert_i64("submitType", 0L)
    match args.get("f_nextNodeOperator") {
      Some(v) => flow_args.insert("tf_nextNodeOperator", v)
      None => ()
    }
    let _ = (self.engine).execute_task_async(task.task_id, operator, flow_args)
  }
  let o = @json.empty_object()
  @json.obj_set(o, "processInstanceId", i64_json(inst.instance_id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::deploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let content = match content_bytes(args) {
    Some(c) => c
    None => raise @error.Business("content 缺失")
  }
  let model = @parser.parse_model(content)
  // 按 name 查最新 version+1（含停用）
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", model.name))
  let page = (self.repo).page_defines(query)
  let version = if page.rows().is_empty() {
    0
  } else {
    page.rows()[0].version + 1
  }
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: model.name,
    display_name: model.display_name,
    define_type: model.model_type,
    state: 1,
    content,
    version,
    create_time: Some(@model.current_time_str()),
    create_user: arg_str_or(args, "operator", "system") |> Some,
    update_time: None,
    update_user: None,
  }
  (self.repo).save_define(define_info)
  let o = @json.empty_object()
  @json.obj_set(o, "processDefineId", i64_json(define_info.id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::redeploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let define_id = match arg_i64(args, "processDefineId") {
    Some(v) => v
    None => raise @error.Business("缺少processDefineId参数")
  }
  let content = match content_bytes(args) {
    Some(c) => c
    None => raise @error.Business("content 缺失")
  }
  let model = @parser.parse_model(content)
  let define_info = match (self.repo).find_define_by_id(define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(define_id)
  }
  let updated : @model.ProcessDefine = { ..define_info,
    name: model.name,
    display_name: model.display_name,
    define_type: model.model_type,
    content,
    update_user: Some(arg_str_or(args, "operator", "system")),
  }
  (self.repo).update_define(updated)
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::define_remove(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  for id in arg_ids(args) {
    (self.repo).remove_define(id)
  }
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::define_up_and_down(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  // opType 优先，state 兜底（C15）
  let state = match arg_i64(args, "opType") {
    Some(v) => v.to_int()
    None =>
      match arg_i64(args, "state") {
        Some(v) => v.to_int()
        None => raise @error.Business("缺少state参数")
      }
  }
  for id in arg_ids(args) {
    (self.repo).update_define_state(id, state)
  }
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::get_last_by_name(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let name = match arg_str(args, "processDefineName") {
    Some(s) => s
    None => raise @error.Business("缺少processDefineName参数")
  }
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", name))
  query.set_order_by("t.version desc")
  let page = (self.repo).page_defines(query)
  // 内存仓储无 SQL orderBy：facade 级按 version 取最大（rust 同款语义）
  let mut best : @model.DefineRow? = None
  for r in page.rows() {
    match best {
      Some(b) => if r.version > b.version { best = Some(r) }
      None => best = Some(r)
    }
  }
  match best {
    Some(def) => {
      let o = @json.empty_object()
      @json.obj_set(o, "id", i64_json(def.id))
      @json.obj_set(o, "name", @json.string_of(def.name))
      @json.obj_set(o, "display_name", @json.string_of(def.display_name))
      @json.obj_set(o, "type", @json.string_of(def.define_type))
      @json.obj_set(o, "state", num_json(def.state))
      @json.obj_set(o, "version", num_json(def.version))
      o
    }
    None => raise @error.Business("流程定义不存在: \{name}")
  }
}

// ═══ 流程实例 ═══

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::instance_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(operator_arg(args)))
  let page = (self.repo).page_instances(query)
  finalize_page(page, instance_row_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::instance_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_id(args, ["id"]) {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let inst = match (self.repo).find_instance_by_id(id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(id)
  }
  let define_info = (self.repo).find_define_by_id(inst.define_id)
  let json_object = match define_info {
    Some(d) => parse_graph(d.content)
    None => None
  }
  let first_task = first_task_node_id(json_object)
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(inst.instance_id))
  @json.obj_set(o, "parentId", opt_i64_json(inst.parent_id))
  @json.obj_set(o, "processDefineId", i64_json(inst.define_id))
  @json.obj_set(o, "state", num_json(inst.state))
  @json.obj_set(o, "parentNodeName", opt_json(inst.parent_node_name))
  @json.obj_set(o, "businessNo", opt_json(inst.business_no))
  @json.obj_set(o, "operator", @json.string_of(inst.operator))
  @json.obj_set(o, "ext", flow_data_to_object(inst.variables)) // issues/124：变量唯一对外出口（ext 豁免 camel，键保持下划线）
  @json.obj_set(o, "formData", form_data_of_flow(inst.variables, "f_"))
  @json.obj_set(o, "createTime", opt_json(inst.create_time))
  @json.obj_set(o, "createUser", opt_json(inst.create_user))
  match define_info {
    Some(d) => {
      @json.obj_set(o, "displayName", @json.string_of(d.display_name))
      @json.obj_set(o, "name", @json.string_of(d.name))
      @json.obj_set(o, "version", num_json(d.version))
    }
    None => ()
  }
  @json.obj_set(o, "jsonObject", opt_json_wrap(json_object))
  // 任务列表 + activeTaskList（issues/05-4）
  let tasks = @json.empty_array()
  let active = @json.empty_array()
  for t in inst.tasks {
    let vo = task_vo(t)
    let ext = parse_json_map(Some(@json.stringify(t.variables.to_object_json())))
    let doing = t.is_doing()
    // issues/121 P1：行上值优先（建单已把标记落库），只有存量行没这个键才回退现算。
    // 现算带"仅进行中"判定 ⇒ 拿它覆写历史行会把 true 洗成 false（P2 回退判参与者正是要避开那套口径）。
    if ext.get("isFirstTaskNode") == None {
      ext["isFirstTaskNode"] = bool_of_bool(doing && t.task_name == first_task.unwrap_or(""))
    }
    @json.obj_set(vo, "ext", obj_json(ext))
    @json.arr_push(tasks, vo)
    if doing {
      @json.arr_push(active, vo)
    }
  }
  @json.obj_set(o, "tasks", tasks)
  @json.obj_set(o, "activeTaskList", active)
  o
}

///|
fn bool_of_bool(b : Bool) -> Json {
  @json.bool_of(b)
}

///|
/// 必填字符串参数（issues/114 语义：缺失即报错、返回 trim 后的值）
///
/// issues/142 B 批（spec 06-facade §2.11「transfer 的 fromActor/toActor 归一后再用」）：判空判据
/// 不再本地另写一份 trim/is_empty，**复用** @model.normalize_actor（内部就是集合那一枚
/// normalize_actors）—— 于是 `processTask/transfer` 的 fromActor/toActor 与参与者表的比对、
/// 账本与便捷键落库的都是 trim 后的值（" leader " 与 "leader" 同一个人）。
/// 空白档沿用**调用方传入的既有"必填"文案**（§2.11 要求③：不新造错误码与文案）；
/// 反向哨兵："0" 是有效值，判据是 trim()=="" 而不是 falsy。
fn arg_required_str(
  args : Map[String, Json],
  key : String,
  msg : String
) -> String raise @error.JeeflowError {
  match @model.normalize_actor(arg_str(args, key).unwrap_or("")) {
    Some(v) => v
    None => raise @error.Business(msg)
  }
}

///|
/// flow.auto / flow.admin 放行约定（is_allowed 既有语义，撤回/转办共用；大小写不敏感，对齐 java）
fn is_privileged_operator(operator : String) -> Bool {
  let lower = operator.to_lower()
  lower == "flow.auto" || lower == "flow.admin"
}

///|
/// 撤回归属判据（issues/114，spec/06 §withdraw 三条，命中任一放行）：
/// 1. operator = 实例发起人（wf_process_instance.operator）
///    ⚠️ 不可复用 ProcessTask::is_allowed——各栈它都只判"任务 actorIds + auto/admin"，不查发起人；
/// 2. operator 是该实例任一**进行中**任务的参与者（以 wf_process_task_actor 参与者表为准，
///    不用聚合副本——加签/转办的增量只落参与者表）；
/// 3. operator ∈ {flow.auto, flow.admin}。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::can_withdraw(
  self : Facade[R, E],
  inst : @model.ProcessInstance,
  operator : String
) -> Bool raise @error.JeeflowError {
  if is_privileged_operator(operator) {
    return true
  }
  if operator == inst.operator {
    return true
  }
  for t in (self.repo).find_doing_tasks(inst.instance_id, []) {
    if ((self.repo).find_task_actors(t.task_id)).contains(operator) {
      return true
    }
  }
  false
}

///|
/// 撤回（issues/113/114）：operator 硬必填 + 三条归属判据 + 任务态 30 级联 + update_user 回写
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::withdraw(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  // 严禁缺省回落 user1 等固定账号：那会把撤回人静默记成别人，审计链失真且不报错
  let operator = arg_required_str(args, "operator", "operator 必填")
  let inst = match (self.repo).find_instance_by_id(id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(id)
  }
  if !(self.can_withdraw(inst, operator)) {
    raise @error.Business("无权限撤回该流程实例")
  }
  // C28：实例 30 + 进行中任务 30（级联持久化）；已完成(20)/已终止(40) 行不经聚合根下发，不被改写
  // issues/134 案 A：实例状态守卫（非进行中(10) ⇒ 内部码 20010009 + 固定文案）在聚合根 withdraw 内，
  // 排在任务行循环之前 ⇒ 被拒时这里一行都没改，下面的 update_task/update_instance 一次都不执行（不落库）。
  inst.withdraw(operator)
  for t in inst.tasks {
    if t.task_state == @model.TaskState::Withdraw.code() {
      (self.repo).update_task(t)
    }
  }
  (self.repo).update_instance(inst)
  // issues/132 code 8 TASK_WITHDRAW：实例 state→30（update_instance）与被撤任务行（update_task）
  // 均落库之后 fire；每轮撤回只 fire 一次（sourceId=instanceId，载荷 instanceId/operator）。
  (self.engine).notify_instance_withdraw(inst.instance_id, operator)
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::approval_record(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let history = (self.repo).find_history_tasks(id)
  let rows = @json.empty_array()
  for t in history {
    let vo = @json.empty_object()
    @json.obj_set(vo, "taskName", @json.string_of(t.task_name))
    @json.obj_set(vo, "displayName", @json.string_of(t.display_name))
    @json.obj_set(vo, "taskType", num_json(t.task_type))
    @json.obj_set(vo, "performType", num_json(t.perform_type))
    @json.obj_set(vo, "taskState", num_json(t.task_state))
    @json.obj_set(vo, "operator", opt_json(t.actor_id))
    @json.obj_set(vo, "finishTime", opt_json(t.finish_time))
    @json.obj_set(vo, "ext", t.variables.to_object_json()) // issues/124：variable 原串出口下线
    @json.arr_push(rows, vo)
  }
  rows
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::get_assignee_text_data(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let include_node_name = match args.get("includeNodeName") {
    Some(Json::False) => false
    _ => true
  }
  let doing = (self.repo).find_doing_tasks(id, [])
  let rows = @json.empty_array()
  for t in doing {
    let actors = (self.repo).find_task_actors(t.task_id)
    for actor in actors {
      let item = @json.empty_object()
      @json.obj_set(item, "value", @json.string_of(actor))
      @json.obj_set(item, "label", @json.string_of(if include_node_name {
        "\{t.display_name}:\{actor}"
      } else {
        actor
      }))
      @json.arr_push(rows, item)
    }
  }
  rows
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::create_cc_instance(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let operator = operator_arg(args)
  // issues/141 G10（spec 06 §2.10「空抄送人不建 cc 行」）＋ issues/142 B 批（§2.11 同一枚判据）：
  // 手动腿与两条引擎腿共用 @engine.parse_actors 的形状适配，判据只在 @model.normalize_actors
  // 那一处 —— 空串/纯空白/数组里的空元素一律丢弃，落库与比较取 trim 后的值，同调用折叠
  // （改前本行是"再归一一次"，因为 arg_actor_ids 的数组臂不 trim ⇒ [" a "] 与 "a" 判成两个人）。
  // 丢完为空 ⇒ 与下面这条既有的"空集合"档同判（沿用 `actorIds 缺失`，不新造错误码/文案）。
  let actors = arg_actor_ids(args)
  if actors.is_empty() {
    raise @error.Business("actorIds 缺失")
  }
  // issues/141 G2 写侧判重＝幂等空操作（spec 06 §4）：手动腿与引擎腿同一条判据
  // （spec §11.7「三条入口共用一支」）——已有 cc 行的 (实例, 人) 跳过，不新增行、不重置未读、
  // 不更新原行时间；只有**实际新建的子集**拿去 fire。
  let created = (self.repo).create_cc_instance_if_absent(instance_id, operator, actors)
  // issues/127·132 事件代码腿：手动 createCCInstance 也 fire CC_CREATE（spec §11.2 原则1
  // ——「新增一条抄送记录」这一事实成立；§4.5 原话：java 不 fire 是缺，本栈按基准补齐）。
  // cc 行已在上一行落库 ⇒ 逐抄送人 fire（与发起 f_ccActors／办理 tf_ccActors 同 notify_cc_create 通道）。
  // 入参＝实际新建子集（issues/141 G2）：重复抄送没发生"创建"⇒ 不发码 4，子集为空整支不发。
  if !created.is_empty() {
    (self.engine).notify_cc_create(instance_id, created)
  }
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::update_cc_status(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  // issues/142 §9.2 复核补（spec 06 §2.11 表第四行）：operator 归一后再交给仓储比——
  // operator_arg 已把空档回落 demo 缺省 user1（issues/129 案 A），这里补 trim 那半：
  // 不 trim 则「 9101 」打不中库里 trim 后的行（点了已读没反应）。与 java
  // normalizeActor(operatorArg(args)) 同构，其 error(「operator 必填」) 分支因回落
  // 恒非空而不可达，本栈 None ⇒ 同文案保形。
  let operator = match @model.normalize_actor(operator_arg(args)) {
    Some(op) => op
    None => raise @error.Business("operator 必填")
  }
  (self.repo).update_cc_status(instance_id, operator)
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::cc_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(operator_arg(args)))
  let page = (self.repo).page_cc_instances(query)
  finalize_page(page, instance_row_to_json, filters, page_num, page_size)
}

// ═══ 流程任务 ═══

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::todo_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(operator_arg(args)))
  let page = (self.repo).page_todo_tasks(query)
  finalize_page(page, task_row_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::done_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(operator_arg(args)))
  let page = (self.repo).page_done_tasks(query)
  finalize_page(page, task_row_to_json, filters, page_num, page_size)
}

///|
/// 提交任务（submitType 分发，java execute 同款）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::execute(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("缺少processTaskId参数")
  }
  let operator = operator_arg(args)
  let submit_type = arg_i64_or(args, "submitType", 1L)
  let flow_args = args_to_flow_data(args, ["processTaskId", "operator"])
  flow_args.insert_i64("submitType", submit_type)
  if submit_type == 2L {
    // REJECT → 跳转结束（办结语义合并派）
    let _ = (self.engine).execute_and_jump_to_end_async(task_id, operator, flow_args)
  } else if submit_type == 3L {
    // ROLLBACK → 沿首入边回退（首任务节点）
    let _ = (self.engine).execute_and_jump_async(task_id, operator, flow_args, None)
  } else if submit_type == 4L {
    // JUMP → 指定节点（非法名 → "无法找到节点模型"）
    let task_name = arg_str_or(args, "taskName", "")
    let _ = (self.engine).execute_and_jump_async(task_id, operator, flow_args, Some(task_name))
  } else if submit_type == 6L {
    // ROLLBACK_TO_OPERATOR → 首任务节点重执行给发起人
    let _ = (self.engine).execute_and_jump_to_first_async(task_id, operator, flow_args)
  } else if submit_type == 20L {
    // 会签不同意 → 注入 flag 普通执行（20 软拒绝，C8）
    flow_args.insert_str("countersignDisagreeFlag", "1")
    let _ = (self.engine).execute_task_async(task_id, operator, flow_args)
  } else {
    // 0 APPLY / 1 AGREE / 5 重新提交 → 普通执行
    let _ = (self.engine).execute_task_async(task_id, operator, flow_args)
  }
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::task_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_id(args, ["processTaskId", "id"]) {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let operator = operator_arg(args)
  let task = match (self.repo).find_task_by_id(id) {
    Some(t) => t
    None => raise @error.TaskNotFound(id)
  }
  let vo = task_vo(task)
  let actors = (self.repo).find_task_actors(id)
  let actor_list = @json.empty_array()
  for a in actors {
    @json.arr_push(actor_list, @json.string_of(a))
  }
  @json.obj_set(vo, "taskActorIdList", actor_list)
  @json.obj_set(vo, "executable", @json.bool_of(task.is_allowed(operator)))
  // issues/82-5：任务级 ext.isFirstTaskNode（java taskDetail 写 false 兜底 + define 匹配时修正）
  let t_ext = parse_json_map(Some(@json.stringify(task.variables.to_object_json())))
  // 行上值（P1 起建单必写）；只有存量行没这个键时才走 false 兜底 + define 匹配修正
  let row_first = t_ext.get("isFirstTaskNode")
  if row_first == None {
    t_ext["isFirstTaskNode"] = @json.bool_of(false)
  }
  let inst = (self.repo).find_task_by_id(id) |> ignore
  let _ = inst
  @json.obj_set(vo, "ext", obj_json(t_ext))
  // jsonObject + taskModel
  let doing_task = task
  let instance_opt = (self.repo).find_instance_by_id(doing_task.process_instance_id)
  match instance_opt {
    Some(instance) => {
      let define_info = (self.repo).find_define_by_id(instance.define_id)
      let json_object = match define_info {
        Some(d) => parse_graph(d.content)
        None => None
      }
      @json.obj_set(vo, "jsonObject", opt_json_wrap(json_object))
      match define_info {
        Some(d) => {
          if row_first == None {
            // 存量行才回退现算（仅进行中口径）；新行一律以落库值为准
            t_ext["isFirstTaskNode"] = @json.bool_of(
              doing_task.is_doing() && doing_task.task_name == first_task_node_id(json_object).unwrap_or(""),
            )
          }
          @json.obj_set(vo, "ext", obj_json(t_ext))
          let model = @parser.parse_model(d.content)
          for node in model.nodes {
            if node.id == doing_task.task_name {
              let tm = @json.empty_object()
              @json.obj_set(tm, "name", @json.string_of(node.id))
              @json.obj_set(tm, "displayName", @json.string_of(node.display_name))
              @json.obj_set(tm, "type", @json.string_of(node_type_name(node.node_type)))
              // issues/62：taskModel 补 form/ext（C14/C19）
              @json.obj_set(tm, "form", opt_json(node.form_key()))
              let ext_obj = @json.empty_object()
              match node.properties.get("ext") {
                Some(e) =>
                  match e {
                    Json::Object(m) =>
                      for k, v in m {
                        @json.obj_set(ext_obj, k, v)
                      }
                    _ => ()
                  }
                None => ()
              }
              @json.obj_set(tm, "ext", ext_obj)
              @json.obj_set(vo, "taskModel", tm)
              break
            }
          }
        }
        None => ()
      }
    }
    None => ()
  }
  vo
}

///|
fn node_type_name(t : @parser.NodeType) -> String {
  t.as_str()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::jump_able_task_name_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let done = (self.repo).find_done_tasks(instance_id, [])
  let rows = @json.empty_array()
  let seen : Map[String, Unit] = Map([])
  for t in done {
    if t.perform_type == 1 {
      continue
    }
    if seen.get(t.task_name) is Some(_) {
      continue
    }
    seen[t.task_name] = ()
    let item = @json.empty_object()
    @json.obj_set(item, "label", @json.string_of(t.display_name))
    @json.obj_set(item, "value", @json.string_of(t.task_name))
    @json.arr_push(rows, item)
  }
  rows
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::candidate_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let task_id = match arg_id(args, ["processTaskId", "id"]) {
    Some(v) => v
    None => raise @error.Business("processTaskId 缺失")
  }
  let task = match (self.repo).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.TaskNotFound(task_id)
  }
  let instance = match (self.repo).find_instance_by_id(task.process_instance_id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(task.process_instance_id)
  }
  let define_info = match (self.repo).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(instance.define_id)
  }
  // 模型候选：当前节点输出边指向的任务节点静态参与人
  let model = @parser.parse_model(define_info.content)
  let node = model.get_node(task.task_name)
  let candidates : Array[String] = []
  match node {
    Some(n) => {
      for e in model.get_output_edges(n.id) {
        match model.get_target_node(e) {
          Some(next) =>
            if next.node_type is @parser.Task {
              match next.assignee() {
                Some(a) => {
                  for actor in split_comma(a) {
                    candidates.push(actor)
                  }
                }
                None => ()
              }
            }
          None => ()
        }
      }
    }
    None => ()
  }
  let rows = @json.empty_array()
  if !candidates.is_empty() {
    for actor in candidates {
      // provider: `(String) -> UserInfo? raise JeeflowError`；取不到或报错 ⇒ 空串（旧语义）
      let info = match self.engine.context().user_provider {
        Some(get_user) =>
          try {
            match (get_user)(actor) {
              Some(u) => u.real_name()
              None => ""
            }
          } catch {
            _ => ""
          }
        None => ""
      }
      @json.arr_push(rows, candidate_row(actor, info, None))
    }
    // 分页信封（pageNum=1 pageSize=rows）
    let obj = @json.empty_object()
    @json.obj_set(obj, "pageNum", @json.number_of(1L))
    @json.obj_set(obj, "pageSize", @json.number_of(10L))
    @json.obj_set(obj, "recordCount", @json.number_of(candidates.length().to_int64()))
    @json.obj_set(obj, "totalPage", @json.number_of(1L))
    @json.obj_set(obj, "rows", rows)
    return obj
  }
  // 无模型候选 → 用户搜索分页
  match self.engine.context().user_search_provider {
    Some(usp) => {
      let page = (usp.page)(@model.PageQuery::new(1L, 10L))
      let out = @json.empty_object()
      @json.obj_set(out, "pageNum", @json.number_of(page.page_num()))
      @json.obj_set(out, "pageSize", @json.number_of(page.page_size()))
      @json.obj_set(out, "recordCount", @json.number_of(page.record_count()))
      @json.obj_set(out, "totalPage", @json.number_of(page.total_page()))
      let arr = @json.empty_array()
      for row in page.rows() {
        @json.arr_push(arr, obj_json(row))
      }
      @json.obj_set(out, "rows", arr)
      out
    }
    None => raise @error.Business("未配置 IUserSearchProvider（用户搜索钩子）")
  }
}

///|
/// 逗号串切元素（出口侧候选人名册用）：issues/142 B 批把判据并进 @model.normalize_actors
/// 那一枚单点，本函数只负责"切成元素"，不再本地各写一份 trim/is_empty（两把尺子迟早分叉）。
fn split_comma(s : String) -> Array[String] {
  @model.normalize_comma_actors(s)
}

///|
/// 加签（addTaskActor=去重追加非全删全插，C14）
pub async fn[R : @spi.ProcessRepository, E] Facade::task_surrogate(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId/actorIds 缺失")
  }
  // 主键另判一档（spec 06-facade §2.11 末段，issues/142 B 批）：`processTaskId` 缺失/空串/非正数
  // 都是调用方写错了，必须响亮报错，**不得拿 0 当 id 往下落参与者行**。空串档在 arg_i64 已落
  // 既有"非法id"信封；0/负数与缺键同判这一档 —— 沿用既有错误码与文案（§2.11 要求③），
  // 与"归属值为空 ⇒ 丢弃"是两件事：归属值可有可无，主键没有就是错，静默接受会把脏数据钉进表里。
  if task_id <= 0L {
    raise @error.Business("processTaskId/actorIds 缺失")
  }
  // issues/142 B 批（§2.11「两形同判据＋写侧兜底＋trim＋哨兵」）：arg_actor_ids 现在自带
  // @engine.parse_actors 的形状适配 + @model.normalize_actors 那一枚判据（逐元素 trim、
  // 空串/纯空白丢弃、同一次调用折叠、数字元素按 repr 原文收敛成串），与紧邻的
  // create_cc_instance 从此同一把尺子；绕过门面直连仓储的调用方由两仓 add_task_actor 再挡一次。
  let actors = arg_actor_ids(args)
  if actors.is_empty() {
    raise @error.Business("processTaskId/actorIds 缺失")
  }
  (self.repo).add_task_actor(task_id, actors)
  @json.null_json()
}

///|
/// 转办末跳可读文案：`A 转办给 B（原因…）`（无原因不带括号；前端审批意见既有读取位）
fn transfer_text(from_actor : String, to_actor : String, reason : String) -> String {
  let head = "\{from_actor} \{@model.SubmitType::Transfer.message()}给 \{to_actor}"
  if reason.is_empty() {
    head
  } else {
    "\{head}（\{reason}）"
  }
}

///|
/// 转办（issues/115，spec/06 §processTask/transfer 七条语义）：
/// 摘原人 → 加新人 → 同一 taskId 不新建 → 三件留痕（submitType=7 槽位 + tf_transferHistory
/// 追加式账本 + tf_transferTo/tf_transferReason 便捷键 + 末跳 tf_approvalComment）→
/// 去重/前置态四类明确报错。区别于 processTask/surrogate 加签的"只追加不动原人"。
pub async fn[R : @spi.ProcessRepository, E] Facade::task_transfer(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("缺少processTaskId参数")
  }
  let operator = arg_required_str(args, "operator", "operator 必填")
  let from_actor = arg_required_str(args, "fromActor", "fromActor 必填")
  let to_actor = arg_required_str(args, "toActor", "toActor 必填")
  let task = match (self.repo).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.TaskNotFound(task_id)
  }
  // 归属判据：只能转自己那一条待办（flow.auto/flow.admin 除外），与撤回同口径
  if !is_privileged_operator(operator) && operator != from_actor {
    raise @error.Business("无权限转办该任务")
  }
  // 前置态：仅进行中（DOING=10）任务可转办
  if task.task_state != @model.TaskState::Doing.code() {
    raise @error.Business("任务非进行中，不可转办")
  }
  // 以参与者表为判据（聚合副本会滞后于加签/转办的增量写入）
  let actors = (self.repo).find_task_actors(task_id)
  if !actors.contains(from_actor) {
    raise @error.Business("原办理人不是该任务参与人")
  }
  if actors.contains(to_actor) {
    raise @error.Business("目标人已是该任务参与人")
  }
  // 语义 1+2+3：只摘 fromActor 一行（会签其余成员不受影响）、toActor 追加、沿用同一 taskId
  (self.repo).remove_task_actor(task_id, [from_actor])
  (self.repo).add_task_actor(task_id, [to_actor])
  // 语义 4 留痕①：跨跳追加式账本 tf_transferHistory——每跳 append，只追加不覆盖
  let reason = arg_str(args, "reason").unwrap_or("").trim(chars=" \t\r\n").to_owned()
  let history = @json.empty_array()
  match task.variables.get("tf_transferHistory") {
    Some(Json::Array(items)) =>
      for it in items {
        @json.arr_push(history, it)
      }
    _ => ()
  }
  // 六键固定 camelCase；reason 无值写 ""；time 一律 yyyy-MM-dd HH:mm:ss（spec §2.4，
  // 不得用本地 ISO 方言——账本要跨栈同形）
  @json.arr_push(
    history,
    @json.object_of([
      ("submitType", @json.number_of(@model.SubmitType::Transfer.code())),
      ("fromActor", @json.string_of(from_actor)),
      ("toActor", @json.string_of(to_actor)),
      ("reason", @json.string_of(reason)),
      ("time", @json.string_of(@model.current_time_str())),
      ("operator", @json.string_of(operator)),
    ]),
  )
  task.variables.insert("tf_transferHistory", history)
  // 留痕①当前槽位 + ②单跳便捷键 + ③末跳可读文案（B 办结后槽位由 1/2/20 覆盖，属预期）
  task.variables.insert_i64("submitType", @model.SubmitType::Transfer.code())
  task.variables.insert_str("tf_transferTo", to_actor)
  task.variables.insert_str("tf_transferReason", reason)
  task.variables.insert_str("tf_approvalComment", transfer_text(from_actor, to_actor, reason))
  // ⚠️ 契约第 4 条禁写项：**绝不覆写 task.actor_id**（进行中任务该列恒无值是既有不变量；
  // 把被摘走的人写进去，该单一旦撤回/终止就会凭空出现在他从没办过的 doneList——Node 实测）。
  // "办理人记谁"由 update_user + tf_transferHistory[].operator 承载。
  task.update_user = Some(operator)
  task.update_time = Some(@model.current_time_str())
  // 参与者表是真相：同步副本后再落库（内存仓 page_todo_tasks 按 actor_ids 过滤，
  // 不同步则 A 的待办不消失、B 的待办不出现；SQL 仓 update_task 也会按副本覆写）
  task.actor_ids = (self.repo).find_task_actors(task_id)
  (self.repo).update_task(task)
  // issues/132 code 7 TASK_TRANSFER：摘原人+加新人（参与者表）与副本 update_task 均落库之后 fire。
  // sourceId=taskId，载荷 instanceId/taskId/fromActor/toActor/operator。
  (self.engine).notify_task_transfer(task.process_instance_id, task_id, from_actor, to_actor, operator)
  @json.null_json()
}

///|
/// 摘除参与人（issues/115 残留 · 门面第 **47** 个 action，spec 06 §processTask/removeTaskActor）。
/// SPI 的 `remove_task_actor` 从第一天起就是必选方法（两仓都实现），本 action 补的是"上到门面"
/// 这一段，逐字基准＝java `JeeflowFacade.taskRemoveActor`。三个兄弟 action 的分工：
/// · `processTask/surrogate`/`addCandidate` = **只加**（追加，原人保留可办）；
/// · `processTask/transfer` = **换人**（摘 A 加 B + submitType=7 留痕 + tf_transferHistory）；
/// · 本 action = **只摘不加、零留痕、不 fire 事件**：删掉 actorIds 在本任务的参与者行，不新建任务、
///   不写任何任务变量、不覆写任务 actor_id/operator 列，也**一次事件都不发**——issues/132 §11.3
///   定稿事件集里没有"摘人"这一码，码 7 TASK_TRANSFER 的语义是"参与者被替换"，只摘不加套它
///   等于凭空造出一条没发生的转办事实（要留痕请用 transfer）。
///
/// 守卫次序（spec 同节钉死、逐栈一致，门禁按 msg 断言，不接受本栈自行排序）：
/// operator 必填 → processTaskId/actorIds 缺失 → 任务不存在 → 无权限摘除该任务参与人 →
/// 任务非进行中，不可摘除参与人 → 至少需保留一名参与人 → 落库。
pub async fn[R : @spi.ProcessRepository, E] Facade::task_remove_actor(
  self : Facade[R, E],
  args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  // ① operator 硬必填，且排在"缺参数"档之前：参数全缺时若先报主键缺失，会把鉴权缺口
  //    藏进参数报错里。**严禁**用 operator_arg()——那支缺省回落 demo 的 user1，本 action 不接受。
  //    arg_required_str 内部走 @model.normalize_actor，返回值已是归一形（trim 后）。
  let operator = arg_required_str(args, "operator", "operator 必填")
  // ② 缺参数档（spec 语义 8）：`processTaskId` **缺键或空串/纯空白**、`actorIds` 归一后为空、
  //    主键为 0/负数 ⇒ 逐字 `processTaskId/actorIds 缺失`，与 surrogate 同族同文案、不另造。
  // ⚠️ 只统一"缺键/空值"这一档：`processTaskId` **给了但不是数字**（如 "abc"）是另一种事实，
  //    沿用本栈既有 `非法id: …` 信封原样透出——把它伪装成"参数没传"，调用方排障时就再也
  //    看不出是传错了类型。旧形状是空串也一起落进"非法id"（arg_i64 里 parse_int64 直接 raise），
  //    与本 action 的跨栈逐字文案冲突，故在调用 arg_i64 **之前**先把空值档截出来判。
  let pk_blank = match args.get("processTaskId") {
    Some(Json::String(s)) => @model.normalize_actor(s).is_none()
    _ => false
  }
  if pk_blank {
    raise @error.Business("processTaskId/actorIds 缺失")
  }
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId/actorIds 缺失")
  }
  let actors = arg_actor_ids(args)
  if task_id <= 0L || actors.is_empty() {
    raise @error.Business("processTaskId/actorIds 缺失")
  }
  // ③ 任务存在。逐字判据是 `任务不存在`（spec 同节：新增 action 一律用这句，八栈不得各写各的），
  //    所以这里走 Business 而不是 @error.TaskNotFound——后者消息带 id 尾巴（"任务不存在: \{id}"），
  //    是 transfer/execute 既有断言钉住的旧形状，本轮不回改它，也不借它凑本档的文案。
  let task = match (self.repo).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.Business("任务不存在")
  }
  // ④ 归属判据同 transfer：operator ∈ 被摘集合（两边都取归一值，比较才咬得上）或 auto/admin。
  //    transfer 能"摘 A 加 B"是因为 A 就是操作人本人；本 action 同理不得成为借道摘他人的口子。
  if !is_privileged_operator(operator) && !actors.contains(operator) {
    raise @error.Business("无权限摘除该任务参与人")
  }
  // ⑤ 仅进行中（DOING=10）可摘：已办结/撤回/废弃任务的参与人行是 approvalRecord 的取证依据
  //    （它读全状态任务行），摘它等于改写审批历史。
  if task.task_state != @model.TaskState::Doing.code() {
    raise @error.Business("任务非进行中，不可摘除参与人")
  }
  // 以参与者表为判据（聚合副本会滞后于加签/转办的增量写入，与 transfer 同源）
  let current = (self.repo).find_task_actors(task_id)
  // 语义 6「匹配取归一值、DELETE 取行上的原值」（§2.11 硬要求②的删除腿）：库里的行可能是修复前
  // 落下的未 trim 原值 " leader "，入参 "leader" 必须判成同一个人**并连同那一行的原值**交给仓储。
  // 喂归一值去删＝"判成同一人却一条没删"：门面报成功而被摘的人待办还在，是假成功（go 栈实测形状）。
  //
  // 语义 5「不得摘空」的下限判据同时落在这个循环里，两条都不可省：
  // · remaining 只数**归一后非空**的行——历史 actor_id=''／纯空白的脏行谁也办不了单，拿它撑住
  //   下限会让"摘空"伪装成成功，留下永远无人可办、也无法撤回重派的死单；
  // · 判据是集合差（当前参与者 − 归一后的 actorIds），不是入参条数——入参里混非参与者 id 也绕不过。
  let to_delete : Array[String] = []
  let mut remaining = 0
  for row in current {
    match @model.normalize_actor(row) {
      // 归一后为空的历史脏行：既不匹配任何入参，也不算"一个人"，更绝不能进 DELETE
      None => ()
      Some(n) =>
        if actors.contains(n) {
          to_delete.push(row)
        } else {
          remaining += 1
        }
    }
  }
  if !to_delete.is_empty() && remaining == 0 {
    raise @error.Business("至少需保留一名参与人")
  }
  // 语义 7「幂等（非参与者静默忽略）」：入参里不属于本任务参与者的人一条都不点名 ⇒ 空操作、
  // 照常成功信封（前端双点、集成层重放第二次不再报错）；to_delete 为空时仓储一次都不碰，
  // 于是"报错档零删除"与"没命中零删除"是同一条判据。要"人不在任务里就报错"请用 transfer。
  if !to_delete.is_empty() {
    (self.repo).remove_task_actor(task_id, to_delete)
  }
  @json.null_json()
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::task_latest(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let doing = (self.repo).find_doing_tasks(instance_id, [])
  if doing.is_empty() {
    @json.null_json()
  } else {
    task_vo(doing[0])
  }
}
