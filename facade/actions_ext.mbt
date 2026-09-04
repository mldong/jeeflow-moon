// facade actions：design(9) + surrogate(5) + stats(3) + highLight/bizData（视图）

// ═══ 流程设计（需扩展仓储）═══

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::ext(self : Facade[R, E]) -> E raise @error.JeeflowError {
  self.ext_repo
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let page = (self.ext()).page_designs(@model.PageQuery::new(page_num, page_size))
  finalize_page(page, design_to_json, filters, page_num, page_size)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let design = match (self.ext()).find_design_by_id(id) {
    Some(d) => d
    None => raise @error.Business("流程设计不存在")
  }
  let his = (self.ext()).list_design_his(id)
  let json_object : Json? = if his.is_empty() {
    None
  } else {
    parse_graph(his[0].content)
  }
  // issues/07：jsonObject 缺基本信息时从设计表补齐
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(design.id))
  @json.obj_set(o, "name", @json.string_of(design.name))
  @json.obj_set(o, "displayName", @json.string_of(design.display_name))
  @json.obj_set(o, "type", @json.string_of(design.design_type))
  @json.obj_set(o, "icon", opt_json(design.icon))
  @json.obj_set(o, "isDeployed", num_json(design.is_deployed))
  @json.obj_set(o, "remark", opt_json(design.remark))
  let job = match json_object {
    Some(j) => j
    None => @json.empty_object()
  }
  if @json.get_str(job, "name") is None {
    @json.obj_set(job, "name", @json.string_of(design.name))
  }
  if @json.get_str(job, "displayName") is None {
    @json.obj_set(job, "displayName", @json.string_of(design.display_name))
  }
  if @json.get_str(job, "type") is None {
    @json.obj_set(job, "type", @json.string_of(design.design_type))
  }
  if @json.get_i64(job, "processDesignId") is None {
    @json.obj_set(job, "processDesignId", i64_json(design.id))
  }
  @json.obj_set(o, "jsonObject", job)
  let his_arr = @json.empty_array()
  for h in his {
    @json.arr_push(his_arr, design_his_to_json(h))
  }
  @json.obj_set(o, "his", his_arr)
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_save(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let operator = arg_str_or(args, "operator", "user1")
  let id = arg_i64(args, "id")
  let design : @model.ProcessDesign = match id {
    None => {
      let d : @model.ProcessDesign = {
        id: 0L,
        name: arg_str(args, "name").unwrap_or(""),
        display_name: arg_str(args, "displayName").unwrap_or(""),
        design_type: arg_str_or(args, "type", "approval"),
        icon: arg_str(args, "icon"),
        is_deployed: 0,
        remark: arg_str(args, "remark"),
        create_time: Some(@model.current_time_str()),
        create_user: Some(operator),
        update_time: None,
        update_user: Some(operator),
      }
      d
    }
    Some(i) => {
      let d = match ext.find_design_by_id(i) {
        Some(x) => x
        None => raise @error.Business("流程设计不存在")
      }
      match arg_str(args, "displayName") {
        Some(v) => d.display_name = v
        None => ()
      }
      match arg_str(args, "type") {
        Some(v) => d.design_type = v
        None => ()
      }
      match arg_str(args, "icon") {
        Some(v) => d.icon = Some(v)
        None => ()
      }
      match arg_str(args, "remark") {
        Some(v) => d.remark = Some(v)
        None => ()
      }
      d.update_user = Some(operator)
      // 内容快照变更 → 置为未部署（issues/08）
      if content_bytes(args) is Some(_) {
        d.is_deployed = 0
      }
      d
    }
  }
  if id is None {
    ext.save_design(design)
  } else {
    ext.update_design(design)
  }
  // 内容快照存历史表
  match content_bytes(args) {
    Some(content) => {
      let his : @model.ProcessDesignHis = {
        id: 0L,
        process_design_id: design.id,
        content,
        create_time: Some(@model.current_time_str()),
        create_user: Some(operator),
      }
      ext.save_design_his(his)
    }
    None => ()
  }
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(design.id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_update(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let design = match ext.find_design_by_id(id) {
    Some(d) => d
    None => raise @error.Business("流程设计不存在")
  }
  match arg_str(args, "name") {
    Some(v) => design.name = v
    None => ()
  }
  match arg_str(args, "displayName") {
    Some(v) => design.display_name = v
    None => ()
  }
  match arg_str(args, "type") {
    Some(v) => design.design_type = v
    None => ()
  }
  match arg_str(args, "icon") {
    Some(v) => design.icon = Some(v)
    None => ()
  }
  match arg_str(args, "remark") {
    Some(v) => design.remark = Some(v)
    None => ()
  }
  design.update_user = Some(arg_str_or(args, "operator", "system"))
  ext.update_design(design)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_update_define(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let design_id = match arg_i64(args, "processDesignId") {
    Some(v) => v
    None => raise @error.Business("processDesignId 缺失")
  }
  let design = match ext.find_design_by_id(design_id) {
    Some(d) => d
    None => raise @error.Business("流程设计不存在")
  }
  let content = match content_bytes(args) {
    Some(c) => c
    None => raise @error.Business("content 缺失")
  }
  // 与最新快照相同则不重复入库（java 同款）
  let his = ext.list_design_his(design_id)
  let same = if his.is_empty() {
    false
  } else {
    his[0].content == content
  }
  if !same {
    let h : @model.ProcessDesignHis = {
      id: 0L,
      process_design_id: design_id,
      content,
      create_time: Some(@model.current_time_str()),
      create_user: Some(arg_str_or(args, "operator", "system")),
    }
    ext.save_design_his(h)
  }
  // 同步基本信息 + 置未部署
  let outcome = try? @parser.parse_model(content)
  match outcome {
    Ok(model) => {
      design.name = model.name
      design.display_name = model.display_name
      design.design_type = model.model_type
    }
    Err(_) => ()
  }
  design.is_deployed = 0
  design.update_user = Some(arg_str_or(args, "operator", "system"))
  ext.update_design(design)
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_remove(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  for id in arg_ids(args) {
    (self.ext()).remove_design(id)
  }
  ok(None)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_deploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let design_id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let design = match ext.find_design_by_id(design_id) {
    Some(d) => d
    None => raise @error.Business("流程设计不存在")
  }
  let his = ext.list_design_his(design_id)
  if his.is_empty() {
    raise @error.Business("流程设计没有内容，无法发布")
  }
  let content = his[0].content
  let model = @parser.parse_model(content)
  let define_id = self.save_deployed_define(model, content)
  design.is_deployed = 1
  design.update_user = Some(arg_str_or(args, "operator", "system"))
  ext.update_design(design)
  let o = @json.empty_object()
  @json.obj_set(o, "processDefineId", i64_json(define_id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_redeploy(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let design_id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let design = match ext.find_design_by_id(design_id) {
    Some(d) => d
    None => raise @error.Business("流程设计不存在")
  }
  let his = ext.list_design_his(design_id)
  if his.is_empty() {
    raise @error.Business("流程设计没有内容，无法发布")
  }
  let content = his[0].content
  let model = @parser.parse_model(content)
  // 按 name 最新 define：有则替换（继承原 version，C29/issues/59）无则新建
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", model.name))
  let page = (self.repo).page_defines(query)
  let define_id : Int64 = if page.rows().is_empty() {
    self.save_deployed_define(model, content)
  } else {
    let last = page.rows()[0]
    let define = (self.repo).find_define_by_id(last.id).unwrap()
    let updated : @model.ProcessDefine = { ..define,
      name: model.name,
      display_name: model.display_name,
      define_type: model.model_type,
      content,
      // 保留原 version（禁 null→1 漂移，C29/issues/59）
      version: last.version,
      update_user: Some(arg_str_or(args, "operator", "system")),
    }
    (self.repo).update_define(updated)
    last.id
  }
  design.is_deployed = 1
  design.update_user = Some(arg_str_or(args, "operator", "system"))
  ext.update_design(design)
  let o = @json.empty_object()
  @json.obj_set(o, "processDefineId", i64_json(define_id))
  o
}

///|
/// deploy 版本管理：按 name 最新 version+1 插入 state=1（java saveDeployedDefine）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::save_deployed_define(self : Facade[R, E], model : @parser.ProcessModel, content : String) -> Int64 raise @error.JeeflowError {
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
    create_user: Some("system"),
    update_time: None,
    update_user: None,
  }
  (self.repo).save_define(define)
  define.id
}

///|
/// listByType：发起页数据契约（issues/28；分组契约 C14）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::design_list_by_type(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let query = @model.PageQuery::new(1L, 2147483646L)
  let design_page = ext.page_designs(query)
  let def_query = @model.PageQuery::new(1L, 2147483646L)
  let def_page = (self.repo).page_defines(def_query)
  // 每 name 最新 define（version 最大）
  let latest : Map[String, @model.DefineRow] = Map::new()
  for row in def_page.rows() {
    match latest.get(row.name) {
      Some(prev) => if row.version > prev.version { latest[row.name] = row }
      None => latest[row.name] = row
    }
  }
  let groups : Map[String, Json] = Map::new()
  for d in design_page.rows() {
    let dtype = d.design_type
    let items = match groups.get(dtype) {
      Some(arr) => arr
      None => {
        let arr = @json.empty_array()
        groups[dtype] = arr
        arr
      }
    }
    let item = @json.empty_object()
    @json.obj_set(item, "processDesignId", i64_json(d.id))
    @json.obj_set(item, "name", @json.string_of(d.name))
    @json.obj_set(item, "displayName", @json.string_of(d.display_name))
    @json.obj_set(item, "icon", opt_json(d.icon))
    @json.obj_set(item, "remark", opt_json(d.remark))
    match latest.get(d.name) {
      Some(l) => {
        @json.obj_set(item, "processDefineId", i64_json(l.id))
        @json.obj_set(item, "processDefineState", num_json(l.state))
      }
      None => {
        @json.obj_set(item, "processDefineId", @json.null_json())
        @json.obj_set(item, "processDefineState", @json.null_json())
      }
    }
    let his = ext.list_design_his(d.id)
    if !his.is_empty() {
      @json.obj_set(item, "jsonObject", opt_json_wrap(parse_graph(his[0].content)))
    }
    @json.arr_push(items, item)
  }
  obj_json(groups)
}

// ═══ 委托代理 ═══

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::surrogate_page(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let page_num = arg_i64_or(args, "pageNum", 1L)
  let page_size = arg_i64_or(args, "pageSize", 20L)
  let filters = facade_parse_m_filters(args)
  let page = (self.ext()).page_surrogates(@model.PageQuery::new(page_num, page_size))
  finalize_page(page, surrogate_to_json, filters, page_num, page_size)
}

///|
/// 时间窗双格式解析（C26：空格 / ISO T）
fn parse_surrogate_time(s : String?) -> String? {
  match s {
    Some(raw) => {
      let t = raw.trim(chars=" \t\r\n").to_string()
      if t.is_empty() {
        return None
      }
      if t.length() >= 19 {
        let bytes = t.to_array()
        if bytes[10] == 'T' {
          return Some(t.substring(start=0, end=10).to_string() + " " + t.substring(start=11, end=19).to_string())
        }
        return Some(t.substring(start=0, end=19).to_string())
      }
      Some(t)
    }
    None => None
  }
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::surrogate_save(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let operator = arg_str_or(args, "operator", "user1")
  let id = arg_i64(args, "id")
  let surrogate : @model.ProcessSurrogate = match id {
    None => {
      let s : @model.ProcessSurrogate = {
        id: 0L,
        process_name: arg_str(args, "processName").unwrap_or(""),
        operator,
        surrogate: arg_str(args, "surrogate").unwrap_or(""),
        start_time: parse_surrogate_time(arg_str(args, "startTime")),
        end_time: parse_surrogate_time(arg_str(args, "endTime")),
        enabled: arg_i64_or(args, "enabled", 1L) |> _.to_int(),
        create_time: Some(@model.current_time_str()),
        create_user: Some(operator),
        update_time: None,
        update_user: Some(operator),
      }
      s
    }
    Some(i) => {
      let s = match ext.find_surrogate_by_id(i) {
        Some(x) => x
        None => raise @error.Business("委托记录不存在")
      }
      self.apply_surrogate_fields(s, args, operator)
      s
    }
  }
  if id is None {
    ext.save_surrogate(surrogate)
  } else {
    ext.update_surrogate(surrogate)
  }
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(surrogate.id))
  o
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::apply_surrogate_fields(self : Facade[R, E], s : @model.ProcessSurrogate, args : Map[String, Json], operator : String) -> Unit raise @error.JeeflowError {
  let _ = self
  match arg_str(args, "processName") {
    Some(v) => s.process_name = v
    None => ()
  }
  // 授权人仅显式传入时覆盖（issues/77 不清空原授权人）
  match arg_str(args, "operator") {
    Some(v) => s.operator = v
    None => ()
  }
  match arg_str(args, "surrogate") {
    Some(v) => s.surrogate = v
    None => ()
  }
  s.start_time = parse_surrogate_time(arg_str(args, "startTime"))
  s.end_time = parse_surrogate_time(arg_str(args, "endTime"))
  // C26：enabled=0 不得折叠成 1
  match arg_i64(args, "enabled") {
    Some(v) => s.enabled = v.to_int()
    None => s.enabled = 1
  }
  s.update_user = Some(operator)
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::surrogate_update(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let ext = self.ext()
  let operator = arg_str_or(args, "operator", "user1")
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("id 缺失")
  }
  let surrogate = match ext.find_surrogate_by_id(id) {
    Some(s) => s
    None => raise @error.Business("委托记录不存在")
  }
  self.apply_surrogate_fields(surrogate, args, operator)
  ext.update_surrogate(surrogate)
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(surrogate.id))
  o
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::surrogate_detail(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  match (self.ext()).find_surrogate_by_id(id) {
    Some(s) => surrogate_to_json(s)
    None => raise @error.Business("委托记录不存在")
  }
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::surrogate_remove(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  for id in arg_ids(args) {
    (self.ext()).remove_surrogate(id)
  }
  ok(None)
}

// ═══ 视图：bizData / highLight ═══

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::biz_data(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let instance_id = match arg_id(args, ["processInstanceId", "id"]) {
    Some(v) => v
    None => raise @error.Business("processInstanceId 缺失")
  }
  let inst = match (self.repo).find_instance_by_id(instance_id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(instance_id)
  }
  let define = match (self.repo).find_define_by_id(inst.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(inst.define_id)
  }
  // relTableName 从 content 顶层解析（回落 name）
  let table = match rel_table_name_of(define.content) {
    Some(t) => t
    None => raise @error.Business("流程定义未配置 relTableName")
  }
  // metaTableReader 未注册显式报错（issues/28）
  match self.engine.context().biz_data_reader {
    Some(reader) => {
      let outcome = try? (reader)(table, instance_id)
      match outcome {
        Ok(rows) => match rows {
          Some(row) => obj_json(row)
          None => ok(None)
        }
        Err(e) => raise @error.Business("业务数据读取失败: \{e.message()}")
      }
    }
    None => raise @error.Business("业务数据读取器未注册（ServiceContext.put(\"metaTableReader\", ...)，需引入 jeeflow-persist）")
  }
}

///|
fn rel_table_name_of(content : String) -> String? {
  match parse_graph(content) {
    Some(meta) => {
      let t = @json.get_str(meta, "relTableName")
      match t {
        Some(s) => if !s.trim(chars=" \t\r\n").is_empty() { Some(s.trim(chars=" \t\r\n").to_string()) } else { rel_fallback_name(meta) }
        None => rel_fallback_name(meta)
      }
    }
    None => None
  }
}

///|
fn rel_fallback_name(meta : Json) -> String? {
  match @json.get_str(meta, "name") {
    Some(s) => if !s.trim(chars=" \t\r\n").is_empty() { Some(s.trim(chars=" \t\r\n").to_string()) } else { None }
    None => None
  }
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::high_light(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let id = match arg_i64(args, "id") {
    Some(v) => v
    None => raise @error.Business("缺少id参数")
  }
  let inst = match (self.repo).find_instance_by_id(id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(id)
  }
  let active : Array[String] = []
  let doing = (self.repo).find_doing_tasks(id, [])
  for t in doing {
    if !active.contains(t.task_name) {
      active.push(t.task_name)
    }
  }
  let history = (self.repo).find_history_tasks(id)
  let history_nodes : Array[String] = []
  for t in history {
    if !active.contains(t.task_name) && !history_nodes.contains(t.task_name) {
      history_nodes.push(t.task_name)
    }
  }
  let define = (self.repo).find_define_by_id(inst.define_id)
  let node_progress = @json.empty_object()
  let edges : Array[String] = []
  match define {
    Some(d) => {
      let outcome = try? @parser.parse_model(d.content)
      match outcome {
        Ok(model) => {
          build_node_progress(model, history, node_progress)
          collect_path(model, model.get_start(), active, history_nodes, edges, inst.variables, history)
        }
        Err(_) => ()
      }
    }
    None => ()
  }
  let o = @json.empty_object()
  let active_arr = @json.empty_array()
  for n in active {
    @json.arr_push(active_arr, @json.string_of(n))
  }
  @json.obj_set(o, "activeNodeNames", active_arr)
  let hist_arr = @json.empty_array()
  for n in history_nodes {
    @json.arr_push(hist_arr, @json.string_of(n))
  }
  @json.obj_set(o, "historyNodeNames", hist_arr)
  let edge_arr = @json.empty_array()
  for n in edges {
    @json.arr_push(edge_arr, @json.string_of(n))
  }
  @json.obj_set(o, "historyEdgeNames", edge_arr)
  @json.obj_set(o, "nodeProgress", node_progress)
  o
}

///|
fn build_node_progress(
  model : @parser.ProcessModel,
  history : Array[@model.ProcessTask],
  out : Json
) -> Unit {
  // 节点顺序（history 首现序）
  let names : Array[String] = []
  let seen : Map[String, Unit] = Map::new()
  for t in history {
    if seen.get(t.task_name) is None {
      seen[t.task_name] = ()
      names.push(t.task_name)
    }
  }
  for name in names {
    let ts : Array[@model.ProcessTask] = []
    for t in history {
      if t.task_name == name {
        ts.push(t)
      }
    }
    if ts.is_empty() {
      continue
    }
    // 会签全量办理人：任务变量 operatorList_{node} 优先（C9/issues/93），否则 actorIds 并集
    let mut members : Array[String] = []
    let op_key = "csv_\{name}_operatorList"
    for t in ts {
      match t.variables.get_str(op_key) {
        Some(list) => {
          members = split_comma(list)
          break
        }
        None => ()
      }
    }
    if members.is_empty() {
      for t in ts {
        for a in t.actor_ids {
          if !members.contains(a) {
            members.push(a)
          }
        }
      }
    }
    if members.is_empty() {
      continue
    }
    // 会签判定 + 类型
    var is_cs = false
    var cs_type = ""
    match model.get_node(name) {
      Some(node) => {
        is_cs = node.is_countersign()
        cs_type = node.countersign_type()
      }
      None => ()
    }
    let member_list = @json.empty_array()
    for id in members {
      let m = @json.empty_object()
      @json.obj_set(m, "id", @json.string_of(id))
      // name 解析由调用方注入 user provider 前�先空串（前端降级显示 id）
      @json.obj_set(m, "name", @json.string_of(""))
      var done = false
      for t in ts {
        if t.task_state == 20 && t.actor_ids.contains(id) {
          done = true
        }
      }
      if done {
        @json.obj_set(m, "done", @json.bool_of(true))
      } else {
        for t in ts {
          if t.task_state == 10 && !t.actor_ids.is_empty() && t.actor_ids[0] == id {
            @json.obj_set(m, "active", @json.bool_of(true))
          }
        }
      }
      @json.arr_push(member_list, m)
    }
    let item = @json.empty_object()
    @json.obj_set(item, "members", member_list)
    if is_cs && !cs_type.is_empty() {
      @json.obj_set(item, "type", @json.string_of(cs_type))
    }
    @json.obj_set(out, name, item)
  }
}

///|
/// 路径补全：start 沿 outputs 递归，遇活跃节点停止；决策节点表达式求值只收 true 边（C14）
fn collect_path(
  model : @parser.ProcessModel,
  node : @parser.NodeModel?,
  active : Array[String],
  history : Array[String],
  edges : Array[String],
  instance_vars : @json.FlowData,
  history_tasks : Array[@model.ProcessTask]
) -> Unit {
  match node {
    Some(n) => {
      for tm in model.get_output_edges(n.id) {
        let edge_name = match tm.label {
          Some(l) => Some(l)
          None => Some(tm.id)
        }
        match edge_name {
          Some(en) => if !edges.contains(en) { edges.push(en) }
          None => ()
        }
        let next = model.get_target_node(tm)
        match next {
          Some(nx) => {
            if !active.contains(nx.id) && !history.contains(nx.id) {
              history.push(nx.id)
            }
            if !active.contains(nx.id) {
              collect_path(model, Some(nx), active, history, edges, instance_vars, history_tasks)
            }
          }
          None => ()
        }
      }
    }
    None => ()
  }
}
