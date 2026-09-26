// 引擎操作入口 —— 移植自 rust engine.rs impl JeeflowEngineImpl（async ops）

///|
/// 发起流程（async）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::start_async(
  self : Engine[R, E],
  define_id : Int64,
  operator : String,
  args : @json.FlowData
) -> @model.ProcessInstance raise @error.JeeflowError {
  // 1. 加载定义
  let define_info = match (self.repo()).find_define_by_id(define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(define_id)
  }
  // 2. 解析模型
  let model = @parser.parse_model(define_info.content)
  // 3. 构建 args（合并 + 用户信息 + autoGenTitle）
  let full_args = @json.FlowData::new()
  full_args.merge(args)
  self.add_user_info(full_args, operator)
  let title = gen_auto_title(full_args, define_info.display_name)
  full_args.insert_str("autoGenTitle", title)
  // 4. 创建实例
  let instance = @model.ProcessInstance::create(define_info, operator, full_args)
  // 5. expireTime
  match model.expire_time {
    Some(et) => instance.expire_time = Some(et)
    None => ()
  }
  // 6. 分配 ID
  self.assign_ids(instance)
  // 7. 落库
  (self.repo()).save_instance(instance)
  // 8. 抄送人（发起路径 f_ccActors，issues/56 E28 数组/逗号串双收）
  let cc_actors = parse_cc_actors(full_args.inner().get("f_ccActors"))
  if !cc_actors.is_empty() {
    (self.repo()).create_cc_instance(instance.instance_id, operator, cc_actors)
    self.notify_cc_create(instance.instance_id, cc_actors)
  }
  // 9. 从 start 节点执行
  let exec = @exec.Execution::make(instance.clone(), model, define_info, operator, full_args)
  match exec.process_model.get_start() {
    Some(start) => self.execute_node(exec, start)
    None => ()
  }
  // 10. 新任务落库（原片赋 id）
  self.persist_tasks(exec)
  // 11. 回写实例
  (self.repo()).update_instance(exec.process_instance)
  // 12. fire 发起事件
  let event = @event.ProcessEvent::make(@event.ProcessInstanceStart, instance.instance_id)
  @event.notify(event, self.ctx.event_listeners())
  exec.process_instance
}

///|
/// 提交任务前公共加载：任务 + 聚合水合（Rust 89：tasks 从仓储回填）+ define/model + args 合并 + submitType 注入
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::load_exec_for_task(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> (@model.ProcessTask, @model.ProcessInstance, @model.ProcessDefine, @parser.ProcessModel, @exec.Execution, Int64?) raise @error.JeeflowError {
  let task = match (self.repo()).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.TaskNotFound(task_id)
  }
  if task.task_state != @model.TaskState::Doing.code() {
    raise @error.InvalidState("Task \{task_id} is not DOING")
  }
  let instance = match (self.repo()).find_instance_by_id(task.process_instance_id) {
    Some(i) => i
    None => raise @error.InstanceNotFound(task.process_instance_id)
  }
  // 聚合水合：任务在独立仓储集合，读侧回填（issues/89）
  instance.tasks = (self.repo()).find_history_tasks(instance.instance_id)
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(instance.define_id)
  }
  let model = @parser.parse_model(define_info.content)
  // issues/115 契约第 5 条（spec/06 §transfer-5，八栈同构）：办理提交的变量合并序
  // 「实例变量为底 ← 任务既有变量 ← 本次提交参数（最高）」。
  // 缺中间层则转办写在任务变量上的留痕（tf_transferHistory / submitType=7 槽位）
  // 读不到；把任务变量置于 args 之下，则 B 办结的 1/2/20 能覆盖转办槽位，
  // 而任务既有变量也不会反噬本次提交（Go 上轮正是把它放在了 args 之上）。
  let full_args = @json.FlowData::from_map(clone_map(instance.variables.inner()))
  full_args.merge(task.variables)
  full_args.merge(args)
  self.add_user_info(full_args, operator)
  // 权限守卫
  if !task.is_allowed(operator) {
    raise @error.PermissionDenied("Operator \{operator} not allowed on task \{task_id}")
  }
  // submitType 双收（数字/字符串，C3 同源）
  let submit_type = match full_args.get_i64("submitType") {
    Some(v) => Some(v)
    None =>
      match full_args.get_str("submitType") {
        Some(s) =>
          // parse_int64 是 `-> Int64 raise`：解析失败 ⇒ "没有数字档"（旧 Err ⇒ None）
          try {
            Some(@string.parse_int64(s))
          } catch {
            _ => None
          }
        None => None
      }
  }
  if submit_type == Some(20L) {
    instance.variables.insert_str("countersignDisagreeFlag", "1")
    full_args.insert_str("countersignDisagreeFlag", "1")
  }
  // 完成聚合内任务 + 合并 f_ 变量
  self.complete_task_in_aggregate(instance, task_id, operator, full_args)
  if submit_type == Some(20L) {
    for t in instance.tasks {
      if t.task_id == task_id {
        t.variables.insert_str("countersignDisagreeFlag", "1")
      }
    }
  }
  self.update_task_by_id(task_id, instance)
  let node = model.get_node(task.task_name)
  let exec = @exec.Execution::make(instance, model, define_info, operator, full_args)
  exec.process_task = Some(task.clone())
  // 9.5 完成节点自身的后置拦截器（1.8.0 SYNC 演进）
  match node {
    Some(cur) => {
      exec.current_node = Some(cur)
      self.fire_post_interceptors(exec)
    }
    None => ()
  }
  (task, instance, define_info, model, exec, submit_type)
}

///|
fn clone_map(src : Map[String, Json]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for k, v in src {
    m[k] = v
  }
  m
}

///|
/// complete_task：rust 里聚合方法返回 Result 映射 Business；这里保持同语义
fn[R, E] Engine::complete_task_in_aggregate(
  self : Engine[R, E],
  instance : @model.ProcessInstance,
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Unit raise @error.JeeflowError {
  let _ = self
  let mut found : @model.ProcessTask? = None
  for t in instance.tasks {
    if t.task_id == task_id {
      found = Some(t)
    }
  }
  match found {
    Some(task) => {
      for k, v in args.inner() {
        // issues/115 契约第 5 条：args 已是「实例 ← 任务 ← 本次」的合并结果，
        // 逐键**合并写入**任务变量（等价于 Go/Node 的 task.Variables = vars，
        // 但取并集而非替换，多一重保险），转办留痕才活得过办结。
        task.variables.insert(k, v)
        if k.has_prefix("f_") {
          instance.variables.insert(k, v)
        }
      }
      try {
        task.finish(operator)
      } catch {
        e => match e {
          @error.PermissionDenied(msg) => raise @error.Business(msg)
          @error.InvalidState(msg) => raise @error.Business(msg)
          other => raise other
        }
      }
    }
    None => raise @error.Business("Task \{task_id} not found in instance \{instance.instance_id}")
  }
}

///|
/// 按任务 id 从聚合内取并 update（rust: tasks.iter().find + repo.update_task）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::update_task_by_id(
  self : Engine[R, E],
  task_id : Int64,
  instance : @model.ProcessInstance
) -> Unit raise @error.JeeflowError {
  for t in instance.tasks {
    if t.task_id == task_id {
      (self.repo()).update_task(t)
      return
    }
  }
}

///|
/// 提交任务（async；含会签门控 issues/94 全逻辑）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_task_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let (_task, _instance, _define, _model, exec, submit_type) = self.load_exec_for_task(task_id, operator, args)
  let node = exec.current_node
  // 10. 会签门控
  let is_countersign = match node {
    Some(n) => n.is_countersign()
    None => false
  }
  if is_countersign {
    let node_ref = node.unwrap()
    let node_id = node_ref.id
    // 同节点任务计数（预计算）
    let node_task_counts : Array[(Bool, Int)] = []
    for t in exec.process_instance.tasks {
      if t.task_name == node_id {
        node_task_counts.push((t.is_finished(), t.task_state))
      }
    }
    let total = node_task_counts.length()
    let mut finished_count = 0
    let mut doing_count = 0
    let mut all_finished = true
    for pair in node_task_counts {
      let (f, s) = pair
      if f {
        finished_count = finished_count + 1
      }
      if s == @model.TaskState::Doing.code() {
        doing_count = doing_count + 1
      }
      if !f {
        all_finished = false
      }
    }
    let cs_type = node_ref.countersign_type()
    let cond = node_ref.countersign_completion_condition()
    let cs_upper = cs_type.to_upper()
    let is_sequential = cs_upper == "SEQUENTIAL" || cs_upper == "SERIAL"
    // 一票否决门
    let veto_matched = match cond {
      Some(c) => c.trim(chars=" \t\r\n").to_lower() == "one_vote_veto"
      None => false
    }
    let veto_hit = submit_type == Some(20L) && veto_matched
    if veto_hit {
      self.abandon_countersign_remaining(exec, node_id)
      exec.is_merged = true
    } else if is_sequential {
      let op_list_key = "csv_\{node_id}_operatorList"
      let lc_key = "csv_\{node_id}_loopCounter"
      let op_list_str = exec.process_instance.variables.get_str_or(op_list_key, "")
      let operator_list = split_actors(op_list_str)
      let lc = exec.process_instance.variables.get_i64_or(lc_key, 0L)
      if lc + 1L < operator_list.length().to_int64() {
        // 未到最后一任：建下一串行任务，不下钻边
        let next_lc = lc + 1L
        exec.process_instance.variables.insert_i64(lc_key, next_lc)
        let new_tasks = exec.process_instance.create_countersign_tasks(
          node_id,
          node_ref.display_name,
          [operator_list[next_lc.to_int()]],
          exec.operator,
          @model.TaskType::from_code(node_ref.task_type()),
          node_ref.form_key(),
          None,
        )
        for t in new_tasks {
          exec.new_tasks.push(t)
        }
        self.persist_tasks(exec)
        (self.repo()).update_instance(exec.process_instance)
        return exec.new_tasks
      } else {
        self.abandon_countersign_remaining(exec, node_id)
        exec.is_merged = true
      }
    } else {
      let has_expr_cond = match cond {
        Some(c) => {
          let cc = c.trim(chars=" \t\r\n").to_owned()
          !cc.is_empty() && cc.to_lower() != "one_vote_veto"
        }
        None => false
      }
      if has_expr_cond {
        // 表达式条件：注入门控变量后求值
        exec.gate_vars.insert_i64("nrOfInstances", total.to_int64())
        exec.gate_vars.insert_i64("nrOfActivateInstances", doing_count.to_int64())
        exec.gate_vars.insert_i64("nrOfCompletedInstances", finished_count.to_int64())
        exec.process_instance.variables.insert_i64("nrOfInstances", total.to_int64())
        exec.process_instance.variables.insert_i64("nrOfActivateInstances", doing_count.to_int64())
        exec.process_instance.variables.insert_i64("nrOfCompletedInstances", finished_count.to_int64())
        let cond_str = cond.unwrap().trim(chars=" \t\r\n").to_owned()
        let merged = self.simple_eval(cond_str, exec)
        if merged {
          self.abandon_countersign_remaining(exec, node_id)
          exec.is_merged = true
        } else {
          self.persist_tasks(exec)
          (self.repo()).update_instance(exec.process_instance)
          return exec.new_tasks
        }
      } else {
        // 无条件（或 ONE_VOTE_VETO 未触发）→ 全员完成才 merged（C8 软拒绝语义）
        if all_finished {
          self.abandon_countersign_remaining(exec, node_id)
          exec.is_merged = true
        } else {
          self.persist_tasks(exec)
          (self.repo()).update_instance(exec.process_instance)
          return exec.new_tasks
        }
      }
    }
  }
  // 10b. 下钻：普通任务恒走；会签 merged 后走（issues/94 fall-through）
  match node {
    Some(n) => {
      let next_nodes : Array[@parser.NodeModel] = []
      for e in exec.process_model.get_output_edges(n.id) {
        match exec.process_model.get_target_node(e) {
          Some(next) => next_nodes.push(next)
          None => ()
        }
      }
      for next in next_nodes {
        self.execute_node(exec, next)
      }
    }
    None => ()
  }
  // 11. 任务级抄送（tf_ccActors）
  match exec.args.get_str("tf_ccActors") {
    Some(cc_actors) => {
      let actors = split_actors(cc_actors)
      if !actors.is_empty() {
        (self.repo()).create_cc_instance(exec.process_instance.instance_id, operator, actors)
        self.notify_cc_create(exec.process_instance.instance_id, actors)
      }
    }
    None => ()
  }
  // 12. 落库
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  exec.new_tasks
}

///|
/// 跳转执行（jump / rollback / 退回发起人共用）
/// 跳转落点的三种语义（issues/121 P2：3「退回上一步」与 6「退回发起人」必须分开）
priv enum JumpMode {
  Named(String)
  FirstNode
  Rollback
}

///|
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_and_jump_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData,
  target_name : String?
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  match target_name {
    Some(n) => self.execute_jump_mode_async(task_id, operator, args, Named(n))
    // issues/121 P2：target 为空＝血缘版"退回上一步"（submitType=3）。
    // 此前这条与"退回发起人"（6）共用 get_first_task_node()，两语义塌成同值（issues/119）。
    None => self.execute_jump_mode_async(task_id, operator, args, Rollback)
  }
}

///|
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_jump_mode_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData,
  mode : JumpMode
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let (_task, _instance, _define, _model, exec, submit_type) = self.load_exec_for_task(task_id, operator, args)
  // 目标节点：命名跳转 / 6 退回发起人（首任务节点）/ 3 退回上一步（血缘版）
  let model = exec.process_model
  match mode {
    Named(name) =>
      match model.get_node(name) {
        Some(node) => self.execute_node(exec, node)
        None => ()
      }
    FirstNode =>
      match model.get_first_task_node() {
        Some(node) => self.execute_node(exec, node)
        None => ()
      }
    Rollback => self.rollback_to_parent(exec)
  }
  // 20 注入在 jump 路径同样落任务变量
  if submit_type == Some(20L) {
    for t in exec.process_instance.tasks {
      if t.task_id == task_id {
        t.variables.insert_str("countersignDisagreeFlag", "1")
      }
    }
  }
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  exec.new_tasks
}

///|
/// 驳回（jump to end）：办结语义合并派——同样 fire ProcessInstanceEnd（issues/104 §2.3）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_and_jump_to_end_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let (_task, instance, _define, _model, _exec, submit_type) = self.load_exec_for_task(task_id, operator, args)
  // 驳回：实例 REJECT(45) + 废弃全部 DOING 任务（任务 99）
  instance.reject()
  instance.abandon_all_doing()
  (self.repo()).update_instance(instance)
  for t in instance.tasks {
    if t.task_state == @model.TaskState::Doing.code() {
      (self.repo()).update_task(t)
    }
  }
  // 20 注入驳回路径同样落任务变量（c29）
  if submit_type == Some(20L) {
    for t in instance.tasks {
      if t.task_id == task_id {
        t.variables.insert_str("countersignDisagreeFlag", "1")
      }
    }
    (self.repo()).update_instance(instance)
  }
  // fire 结束事件（办结+拒绝两路都 fire，C12/C13）
  let event = @event.ProcessEvent::make(@event.ProcessInstanceEnd, instance.instance_id)
  @event.notify(event, self.ctx.event_listeners())
  []
}

///|
/// 退回发起人（submitType=6）：首任务节点重执行给发起人
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_and_jump_to_first_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  // issues/121 P2：不再借道 execute_and_jump_async(None)——那条现在是血缘回退（3）
  self.execute_jump_mode_async(task_id, operator, args, FirstNode)
}

/// 复活行该不该带这个键——控制类残留：上次提交的表单值（tf_）、会签计数簿记（csv_ /
/// loopCounter / nrOfInstances / operatorList）、当次操作的 submitType 与 taskName。
/// 留着会让新待办显示"我没提交这个怎么显示了"，或让复活的会签节点从错位的序号继续推进。
fn is_control_var_key(k : String) -> Bool {
  if k == "submitType" { true }
  else if k == "taskName" { true }
  else if k.has_prefix("tf_") { true }
  else if k.has_prefix("csv_") { true }
  else if k.has_prefix("loopCounter") { true }
  else if k.has_prefix("nrOfInstances") { true }
  else if k.has_prefix("operatorList") { true }
  else { false }
}

/// 退回上一步（血缘版，规范 04 · 退回上一步）：上一步来源＝当前行的 parent_task_id，
/// 复活那条历史行；不按模型入边拓扑推。本栈 JeeflowError::code() 恒 99999999，
/// 对外 msg 用固定中文文案、不含引擎内部码（两格语义由文案区分，HTTP 出口仍 99999999）。
fn[R, E] Engine::rollback_to_parent(
  self : Engine[R, E], exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  let current = match exec.process_task {
    None => raise @error.Business("上一步任务ID为空，无法驳回至上一步处理")
    Some(t) => t
  }
  let parent_id = match current.parent_task_id {
    None => raise @error.Business("上一步任务ID为空，无法驳回至上一步处理")
    Some(p) => p
  }
  if parent_id == 0L {
    raise @error.Business("上一步任务ID为空，无法驳回至上一步处理")
  }
  let instance = exec.process_instance
  // 本版本 Array 没有 find：显式扫聚合根里的行（含已办结的历史行）
  let mut hist : @model.ProcessTask? = None
  for t in instance.tasks {
    if t.task_id == parent_id {
      hist = Some(t)
    }
  }
  let history = match hist {
    None => raise @error.Business("上一步任务ID为空，无法驳回至上一步处理")
    Some(t) => t
  }
  if !exec.process_model.can_rejected(current.task_name, history.task_name) {
    raise @error.Business("无法驳回至上一步处理，请确认上一步骤并非fork、join、suprocess以及会签任务")
  }
  let src = history.variables
  let mut is_first = false
  match src.get("isFirstTaskNode") {
    Some(v) => is_first = @json.as_bool(v) == Some(true)
    None => ()
  }
  // 首任务节点那条由发起人提交 ⇒ 参与者取该行 u_userId；其余取该行办结人。
  // 老行没这个键 ⇒ 按 false 处理（宁可派给该行 actor_id，也不用带"仅进行中"判定的现算值）。
  let mut actor = ""
  if is_first {
    match src.get("u_userId") {
      Some(v) => actor = @json.as_str(v).unwrap_or("")
      None => ()
    }
    if actor == "" { actor = instance.operator }
  } else {
    actor = history.actor_id.unwrap_or("")
  }
  if actor == "" {
    raise @error.Business("上一步任务ID为空，无法驳回至上一步处理")
  }
  // 复活行只带数据类键：tf_*（上次表单提交）与 csv_*/会签簿记都是"上次提交"的残留
  let vars = @json.FlowData::new()
  for k, v in src.inner {
    if is_control_var_key(k) {
      continue
    }
    vars.insert(k, v)
  }
  vars.insert("isFirstTaskNode", @json.bool_of(is_first))
  let carry = match history.parent_task_id {
    None => 0L
    Some(p) => p
  }
  // 显式构造复活行（不改动历史行本身）：进行中、actor_id 清空、actor_ids＝算出的参与者、
  // parent 随行拷贝＝"上一步的上一步"（与 mldong-boot2 一致）、变量走净化后的那一份。
  let nt : @model.ProcessTask = {
    task_id: 0L,                        // persist_tasks 里统一分配真实 id
    process_instance_id: instance.instance_id,
    task_name: history.task_name,
    display_name: history.display_name,
    task_type: history.task_type,
    perform_type: history.perform_type,
    task_state: @model.TaskState::Doing.code(),
    actor_id: None,                     // 进行中任务该列恒无值
    actor_ids: [actor],
    finish_time: None,
    expire_time: history.expire_time,
    form_key: history.form_key,
    parent_task_id: Some(carry),
    variables: vars,
    create_time: history.create_time,
    create_user: history.create_user,
    update_time: None,
    update_user: None,
  }
  exec.new_tasks.push(nt)
}

///|
/// 发起（带父实例，子流程）
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::start_with_parent_async(
  self : Engine[R, E],
  define_id : Int64,
  operator : String,
  args : @json.FlowData,
  parent_id : Int64,
  parent_node_name : String
) -> @model.ProcessInstance raise @error.JeeflowError {
  let define_info = match (self.repo()).find_define_by_id(define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(define_id)
  }
  let model = @parser.parse_model(define_info.content)
  let full_args = @json.FlowData::new()
  full_args.merge(args)
  self.add_user_info(full_args, operator)
  let title = gen_auto_title(full_args, define_info.display_name)
  full_args.insert_str("autoGenTitle", title)
  let instance = @model.ProcessInstance::create_with_parent(define_info, operator, full_args, parent_id, parent_node_name)
  match model.expire_time {
    Some(et) => instance.expire_time = Some(et)
    None => ()
  }
  self.assign_ids(instance)
  (self.repo()).save_instance(instance)
  let cc_actors = parse_cc_actors(full_args.inner().get("f_ccActors"))
  if !cc_actors.is_empty() {
    (self.repo()).create_cc_instance(instance.instance_id, operator, cc_actors)
    self.notify_cc_create(instance.instance_id, cc_actors)
  }
  let exec = @exec.Execution::make(instance.clone(), model, define_info, operator, full_args)
  match exec.process_model.get_start() {
    Some(start) => self.execute_node(exec, start)
    None => ()
  }
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  let event = @event.ProcessEvent::make(@event.ProcessInstanceStart, instance.instance_id)
  @event.notify(event, self.ctx.event_listeners())
  exec.process_instance
}
