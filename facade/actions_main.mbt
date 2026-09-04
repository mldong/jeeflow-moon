// facade actions：define(8) + instance(14) + task(9) —— 对齐 java JeeflowFacade 各私有方法

// ═══ 流程定义 ═══

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::define_page(
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::define_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let define = match (self.repo).find_define_by_id(id) {
    Some(d) => d
    None => raise @error.DefineNotFound(id)
  }
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(define.id))
  @json.obj_set(o, "name", @json.string_of(define.name))
  @json.obj_set(o, "display_name", @json.string_of(define.display_name))
  @json.obj_set(o, "type", @json.string_of(define.define_type))
  @json.obj_set(o, "state", num_json(define.state))
  @json.obj_set(o, "version", num_json(define.version))
  @json.obj_set(o, "jsonObject", parse_graph(define.content) |> opt_json_wrap)
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
  let operator = arg_str_or(args, "operator", "user1")
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::deploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
  let define : @model.ProcessDefine = {
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
  (self.repo).save_define(define)
  let o = @json.empty_object()
  @json.obj_set(o, "processDefineId", i64_json(define.id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::redeploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let define_id = match arg_i64(args, "processDefineId") {
    Some(v) => v
    None => raise @error.Business("缺少processDefineId参数")
  }
  let content = match content_bytes(args) {
    Some(c) => c
    None => raise @error.Business("content 缺失")
  }
  let model = @parser.parse_model(content)
  let define = match (self.repo).find_define_by_id(define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(define_id)
  }
  let updated : @model.ProcessDefine = { ..define,
    name: model.name,
    display_name: model.display_name,
    define_type: model.model_type,
    content,
    update_user: Some(arg_str_or(args, "operator", "system")),
  }
  (self.repo).update_define(updated)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::define_remove(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  for id in arg_ids(args) {
    (self.repo).remove_define(id)
  }
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::define_up_and_down(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::get_last_by_name(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::instance_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(arg_str_or(args, "operator", "user1")))
  let page = (self.repo).page_instances(query)
  finalize_page(page, instance_row_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::instance_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_id(args, ["id"]) {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let inst = match (self.repo).find_instance_by_id(id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(id)
  }
  let define = (self.repo).find_define_by_id(inst.define_id)
  let json_object = match define {
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
  @json.obj_set(o, "variables", flow_data_to_object(inst.variables))
  @json.obj_set(o, "formData", form_data_of_flow(inst.variables, "f_"))
  @json.obj_set(o, "createTime", opt_json(inst.create_time))
  @json.obj_set(o, "createUser", opt_json(inst.create_user))
  match define {
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
    ext["isFirstTaskNode"] = bool_of_bool(doing && t.task_name == first_task.unwrap_or(""))
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::withdraw(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let operator = arg_str_or(args, "operator", "user1")
  let inst = match (self.repo).find_instance_by_id(id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(id)
  }
  // C28：实例 30 + 任务 30（级联持久化）
  inst.withdraw()
  (self.repo).update_instance(inst)
  for t in inst.tasks {
    if t.task_state == @model.TaskState::Withdraw.code() {
      (self.repo).update_task(t)
    }
  }
  let _ = operator
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::approval_record(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
    @json.obj_set(vo, "variable", t.variables.to_object_json())
    @json.obj_set(vo, "ext", t.variables.to_object_json())
    @json.arr_push(rows, vo)
  }
  rows
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::get_assignee_text_data(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::create_cc_instance(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let operator = arg_str_or(args, "operator", "user1")
  let actors = arg_actor_ids(args)
  if actors.is_empty() {
    raise @error.Business("actorIds 缺失")
  }
  (self.repo).create_cc_instance(instance_id, operator, actors)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::update_cc_status(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let operator = arg_str_or(args, "operator", "user1")
  (self.repo).update_cc_status(instance_id, operator)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::cc_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(arg_str_or(args, "operator", "user1")))
  let page = (self.repo).page_cc_instances(query)
  finalize_page(page, instance_row_to_json, filters, page_num, page_size)
}

// ═══ 流程任务 ═══

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::todo_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(arg_str_or(args, "operator", "user1")))
  let page = (self.repo).page_todo_tasks(query)
  finalize_page(page, task_row_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::done_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let query = @model.PageQuery::new(page_num, page_size)
  query.set_operator(Some(arg_str_or(args, "operator", "user1")))
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
  let operator = arg_str_or(args, "operator", "user1")
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
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_id(args, ["processTaskId", "id"]) {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let operator = arg_str_or(args, "operator", "user1")
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
  t_ext["isFirstTaskNode"] = @json.bool_of(false)
  let inst = (self.repo).find_task_by_id(id) |> ignore
  let _ = inst
  @json.obj_set(vo, "ext", obj_json(t_ext))
  // jsonObject + taskModel
  let doing_task = task
  let instance_opt = (self.repo).find_instance_by_id(doing_task.process_instance_id)
  match instance_opt {
    Some(instance) => {
      let define = (self.repo).find_define_by_id(instance.define_id)
      let json_object = match define {
        Some(d) => parse_graph(d.content)
        None => None
      }
      @json.obj_set(vo, "jsonObject", opt_json_wrap(json_object))
      match define {
        Some(d) => {
          t_ext["isFirstTaskNode"] = @json.bool_of(
            doing_task.is_doing() && doing_task.task_name == first_task_node_id(json_object).unwrap_or(""),
          )
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::jump_able_task_name_list(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let done = (self.repo).find_done_tasks(instance_id, [])
  let rows = @json.empty_array()
  let seen : Map[String, Unit] = Map::new()
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::candidate_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
  let define = match (self.repo).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(instance.define_id)
  }
  // 模型候选：当前节点输出边指向的任务节点静态参与人
  let model = @parser.parse_model(define.content)
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
      let info = match self.engine.context().user_provider {
        Some(get_user) =>
          match (try? (get_user)(actor)) {
            Ok(Some(u)) => u.real_name()
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
fn split_comma(s : String) -> Array[String] {
  let out : Array[String] = []
  for part in s.split(",") {
    let t = part.to_string().trim(chars=" \t\r\n").to_string()
    if !t.is_empty() {
      out.push(t)
    }
  }
  out
}

///|
/// 加签（addTaskActor=去重追加非全删全插，C14）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_surrogate(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId/actorIds 缺失")
  }
  let actors = arg_actor_ids(args)
  if actors.is_empty() {
    raise @error.Business("processTaskId/actorIds 缺失")
  }
  (self.repo).add_task_actor(task_id, actors)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_latest(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_i64(args, "processInstanceId") {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let doing = (self.repo).find_doing_tasks(instance_id, [])
  if doing.is_empty() {
    ok(None)
  } else {
    ok_data(task_vo(doing[0]))
  }
}
