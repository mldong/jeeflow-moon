// 引擎核心 —— 移植自 rust engine.rs（JeeflowEngineImpl，方案 §2.3 全 async）
// start → execute → jump → withdraw；spec/04-engine-ops.md
// 泛型 [R, E]：R : @spi.ProcessRepository, E : @spi.ProcessExtRepository

///|
pub(all) struct Engine[R, E] {
  ctx : @spi.Ctx[R, E]
}

///|
pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::make(ctx : @spi.Ctx[R, E]) -> Engine[R, E] {
  { ctx }
}

///|
pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::context(self : Engine[R, E]) -> @spi.Ctx[R, E] {
  self.ctx
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::repo(
  self : Engine[R, E]
) -> R raise @error.JeeflowError {
  self.ctx.repository()
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::next_id(self : Engine[R, E]) -> Int64 raise @error.JeeflowError {
  (self.ctx.id_generator_or_default())()
}

///|
/// 抄送知会事件（CC_CREATE / issues/102·104）：逐抄送人 fire，cc_actor_id 直传事件体。
/// 无监听器装配时零副作用。
pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::notify_cc_create(self : Engine[R, E], instance_id : Int64, cc_actors : Array[String]) -> Unit {
  for actor in cc_actors {
    let event = @event.ProcessEvent::make(CcCreate, instance_id).with_cc_actor_id(actor)
    @event.notify(event, self.ctx.event_listeners())
  }
}

///|
/// 注入用户信息变量（u_userId/u_realName/…；C25：仅 start 注入一次）
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::add_user_info(self : Engine[R, E], args : @json.FlowData, operator : String) -> Unit raise @error.JeeflowError {
  if operator == "flow.auto" || operator == "flow.admin" {
    return
  }
  match self.ctx.user_provider {
    Some(get_user) => {
      let outcome : Result[@model.UserInfo?, @error.JeeflowError] = try? (get_user)(operator)
      match outcome {
        Ok(Some(user)) => {
          args.insert_str("u_userId", user.user_id())
          args.insert_str("u_realName", user.real_name())
          args.insert_str("u_deptId", user.dept_id())
          args.insert_str("u_deptName", user.dept_name())
          args.insert_str("u_postId", user.post_id())
          args.insert_str("u_postName", user.post_name())
        }
        _ => ()
      }
    }
    None => ()
  }
}

///|
/// autoGenTitle："{realName}的{displayName}-{time}"（C25）
fn gen_auto_title(args : @json.FlowData, display_name : String) -> String {
  let real_name = args.get_str_or("u_realName", "未知")
  "\{real_name}的\{display_name}-\{@model.current_time_str()}"
}

///|
/// 参与人解析（优先级：tf_nextNodeOperator → assignee 字面量/变量 → assignmentHandler → candidateUsers）
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::resolve_assignee(self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel) -> Array[String] raise @error.JeeflowError {
  // 1. tf_nextNodeOperator
  match exec.args.get_str("tf_nextNodeOperator") {
    Some(next_op) =>
      if !next_op.is_empty() {
        return split_actors(next_op)
      }
    None => ()
  }
  // 2. assignee 字面量 / 变量引用
  match node.assignee() {
    Some(assignee) =>
      if !assignee.is_empty() {
        if assignee == "applicant" {
          return [exec.process_instance.operator]
        }
        match exec.args.get_str(assignee) {
          Some(v) => if !v.is_empty() { return split_actors(v) }
          None => ()
        }
        return split_actors(assignee)
      }
    None => ()
  }
  // 3. assignmentHandler
  match node.assignment_handler() {
    Some(handler_name) =>
      match self.ctx.find_assignment_handler(handler_name) {
        Some(handler) => {
          let outcome = try? (handler)(exec)
          match outcome {
            Ok(result) => if !result.is_empty() { return split_actors(result) }
            Err(_) => ()
          }
        }
        None => ()
      }
    None => ()
  }
  // 4. candidateUsers（candidateGroups 由 OrgUserProvider 在上层装配处理）
  let actors : Array[String] = []
  match node.candidate_users() {
    Some(users) => {
      for u in users.split(",") {
        let s = u.to_string().trim(chars=" \t\r\n").to_string()
        if !s.is_empty() {
          actors.push(s)
        }
      }
    }
    None => ()
  }
  actors
}

///|
fn split_actors(s : String) -> Array[String] {
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
/// 执行节点（async 递归：start 沿边驱动全图）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_node(self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel) -> Unit raise @error.JeeflowError {
  exec.current_node = Some(node)
  if node.node_type is @parser.Start {
    // 克隆后继节点避免遍历中修改
    let next_nodes : Array[@parser.NodeModel] = []
    for e in exec.process_model.get_output_edges(node.id) {
      match exec.process_model.get_target_node(e) {
        Some(next) => next_nodes.push(next)
        None => ()
      }
    }
    for next in next_nodes {
      self.execute_node(exec, next)
    }
  } else if node.node_type is @parser.Task || node.node_type is @parser.Custom {
    // 任务创建不触发节点拦截器（对齐 Java CreateTaskHandler / Go executeNode）
    self.create_task_with_assignment(exec, node)
  } else if node.node_type is @parser.Decision {
    self.fire_pre_interceptors(exec)
    let target_node_name = self.evaluate_decision(exec, node)
    self.fire_post_interceptors(exec)
    // 选边：命名目标按 target id 匹配，否则表达式求值（C14：只收 true 边）
    let mut chosen_edge : @parser.EdgeModel? = None
    for edge in exec.process_model.get_output_edges(node.id) {
      let edge_expr = edge.expr()
      let matches = match target_node_name {
        Some(target) => edge.target_node_id == target
        None =>
          match edge_expr {
            Some(expr) => self.evaluate_expression(expr, exec)
            None => false
          }
      }
      if matches {
        chosen_edge = Some(edge)
        break
      }
    }
    match chosen_edge {
      Some(edge) =>
        match exec.process_model.get_target_node(edge) {
          Some(next) => self.execute_node(exec, next)
          None => ()
        }
      None => ()
    }
  } else if node.node_type is @parser.Fork {
    self.fire_pre_interceptors(exec)
    let next_nodes : Array[@parser.NodeModel] = []
    for e in exec.process_model.get_output_edges(node.id) {
      match exec.process_model.get_target_node(e) {
        Some(next) => next_nodes.push(next)
        None => ()
      }
    }
    for next in next_nodes {
      self.execute_node(exec, next)
    }
    self.fire_post_interceptors(exec)
  } else if node.node_type is @parser.Join {
    self.fire_pre_interceptors(exec)
    let doing_tasks = exec.process_instance.get_doing_tasks()
    if doing_tasks.is_empty() || exec.is_merged {
      exec.is_merged = true
      let next_nodes : Array[@parser.NodeModel] = []
      for e in exec.process_model.get_output_edges(node.id) {
        match exec.process_model.get_target_node(e) {
          Some(next) => next_nodes.push(next)
          None => ()
        }
      }
      for next in next_nodes {
        self.execute_node(exec, next)
      }
    }
    self.fire_post_interceptors(exec)
  } else if node.node_type is @parser.End {
    self.fire_pre_interceptors(exec)
    // 驳回语义：args.reject=="true" → REJECT(45)，否则 FINISHED(20)
    let has_reject_var = match exec.args.get_str("reject") {
      Some(v) => v == "true"
      None => false
    }
    if has_reject_var {
      exec.process_instance.reject()
    } else {
      exec.process_instance.finish()
    }
    exec.instance_finished = true
    // 持久化
    (self.repo()).update_instance(exec.process_instance)
    // fire 结束事件
    let event = @event.ProcessEvent::make(@event.ProcessInstanceEnd, exec.process_instance.instance_id)
    @event.notify(event, self.ctx.event_listeners())
    self.fire_post_interceptors(exec)
  } else if node.node_type is @parser.SubProcess {
    // 子流程简化处理（rust 同款：不做完整子流程展开）
    ()
  } else {
    ()
  }
}

///|
/// 建任务（含参与人解析与 0 参与人跳过）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::create_task_with_assignment(self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel) -> Unit raise @error.JeeflowError {
  let actor_ids = self.resolve_assignee(exec, node)
  if actor_ids.is_empty() && (node.candidate_users() is None) && (node.candidate_groups() is None) {
    // 无参与人 → 跳过任务创建（继续下钻）
    let next_nodes : Array[@parser.NodeModel] = []
    for e in exec.process_model.get_output_edges(node.id) {
      match exec.process_model.get_target_node(e) {
        Some(next) => next_nodes.push(next)
        None => ()
      }
    }
    for next in next_nodes {
      self.execute_node(exec, next)
    }
    return
  }
  let perform_type = @model.PerformType::from_code(node.perform_type())
  let task_type = @model.TaskType::from_code(node.task_type())
  if perform_type is Countersign {
    let cs_type = node.countersign_type()
    let cs_upper = cs_type.to_upper()
    if cs_upper == "SEQUENTIAL" || cs_upper == "SERIAL" {
      // 串行：只建第一人任务（issues/94），全量名单存实例变量
      if actor_ids.is_empty() {
        return
      }
      let op_list_key = "csv_\{node.id}_operatorList"
      exec.process_instance.variables.insert_str(op_list_key, actor_ids.join(","))
      let lc_key = "csv_\{node.id}_loopCounter"
      exec.process_instance.variables.insert_i64(lc_key, 0L)
      let tasks = exec.process_instance.create_countersign_tasks(
        node.id,
        node.display_name,
        [actor_ids[0]],
        exec.operator,
        task_type,
        node.form_key(),
        None,
      )
      // TASK_START 不在此 fire（id 尚为 0，issues/13）——统一在 persist_tasks 落库后 fire
      for t in tasks {
        exec.new_tasks.push(t)
      }
    } else {
      // 并行：一次建全
      let tasks = exec.process_instance.create_countersign_tasks(
        node.id,
        node.display_name,
        actor_ids,
        exec.operator,
        task_type,
        node.form_key(),
        None,
      )
      for t in tasks {
        exec.new_tasks.push(t)
      }
    }
  } else {
    let task = exec.process_instance.create_task(
      node.id,
      node.display_name,
      actor_ids,
      exec.operator,
      task_type,
      perform_type,
      node.form_key(),
      None,
    )
    exec.new_tasks.push(task)
  }
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::evaluate_decision(self : Engine[R, E], _exec : @exec.Execution, _node : @parser.NodeModel) -> String? raise @error.JeeflowError {
  // rust 同款：命名目标路由暂未启用，交由边表达式求值
  let _ = self
  None
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::evaluate_expression(self : Engine[R, E], expr : String, exec : @exec.Execution) -> Bool raise @error.JeeflowError {
  match self.ctx.expression_evaluator {
    Some(eval) => {
      let vars : Map[String, Json] = Map::new()
      for k, v in exec.args.inner() {
        vars[k] = v
      }
      let outcome = try? (eval)(expr, vars)
      match outcome {
        Ok(v) =>
          match v {
            Json::True => true
            Json::False => false
            Json::Number(n, ..) => n != 0.0
            Json::String(s) => !s.is_empty() && s != "false" && s != "0"
            _ => false
          }
        Err(_) => false
      }
    }
    None => self.simple_eval(expr, exec)
  }
}

///|
/// 简单表达式求值：比较运算 + ${var}/#var 引用 + 布尔字面量
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::simple_eval(self : Engine[R, E], expr : String, exec : @exec.Execution) -> Bool raise @error.JeeflowError {
  let e = expr.trim(chars=" \t\r\n").to_string()
  let resolved = self.resolve_var_refs(e, exec)
  // 比较运算（先长后短避免误切）
  for op in [">=", "<=", "!=", "==", ">", "<"] {
    match resolved.find(op) {
      Some(pos) => {
        let left = resolved.substring(start=0, end=pos).to_string().trim(chars=" \t\r\n").to_string()
        let right = resolved.substring(start=pos + op.length()).to_string().trim(chars=" \t\r\n").to_string()
        let ordering = compare_values(left, right)
        if op == ">" {
          return match ordering { Some(2) => true; _ => false }
        } else if op == "<" {
          return match ordering { Some(-1) => true; _ => false }
        } else if op == ">=" {
          return match ordering { Some(-1) => false; _ => true }
        } else if op == "<=" {
          return match ordering { Some(2) => false; _ => true }
        } else if op == "==" {
          return match ordering { Some(0) => true; _ => false }
        } else {
          return match ordering { Some(0) => false; _ => true }
        }
      }
      None => ()
    }
  }
  // 布尔字面量
  let lower = resolved.to_lower()
  if lower == "true" {
    true
  } else if lower == "false" {
    false
  } else {
    !resolved.is_empty() && resolved != "0" && resolved != "null"
  }
}

///|
/// 比较：数值优先，字符串兜底 → Some(-1/0/1) / None（不可解析）
fn compare_values(left : String, right : String) -> Int? {
  let l = (try? @string.parse_double(left))
  let r = (try? @string.parse_double(right))
  match (l, r) {
    (Ok(lv), Ok(rv)) =>
      if lv < rv {
        Some(-1)
      } else if lv > rv {
        Some(1)
      } else {
        Some(0)
      }
    _ => Some(left.compare(right))
  }
}

///|
/// ${var} 与 #var 引用替换（# 会签门控变量优先 gate_vars）
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::resolve_var_refs(self : Engine[R, E], expr : String, exec : @exec.Execution) -> String raise @error.JeeflowError {
  let mut result = expr
  // ${var}
  let mut cont = true
  while cont {
    match result.find("$" + "{") {
      Some(s) =>
        match result.substring(start=s).find("}") {
          Some(offset) => {
            let var_name = result.substring(start=s + 2, end=s + offset).to_string()
            let value = match exec.args.get_str(var_name) {
              Some(v) => v
              None => "0"
            }
            result = result.substring(start=0, end=s).to_string() + value + result.substring(start=s + offset + 1).to_string()
          }
          None => cont = false
        }
      None => cont = false
    }
  }
  // #var（会签门控变量）
  let out = StringBuilder::new()
  let mut i = 0
  let chars = result.to_array()
  let len = chars.length()
  while i < len {
    let ch = chars[i]
    if ch == '#' && i + 1 < len && (chars[i + 1].to_int() >= 97 && chars[i + 1].to_int() <= 122 || chars[i + 1].to_int() >= 65 && chars[i + 1].to_int() <= 90 || chars[i + 1] == '_') {
      let start = i + 1
      let mut end = start
      while end < len {
        let c = chars[end].to_int()
        if c >= 97 && c <= 122 || c >= 65 && c <= 90 || c >= 48 && c <= 57 || chars[end] == '_' {
          end = end + 1
        } else {
          break
        }
      }
      let var_name = result.substring(start=start, end=end).to_string()
      let value = match exec.gate_vars.get_str(var_name) {
        Some(v) => Some(v)
        None => exec.args.get_str(var_name)
      }
      let value = match value {
        Some(v) => Some(v)
        None =>
          match exec.gate_vars.get_i64(var_name) {
            Some(n) => Some(n.to_string())
            None =>
              match exec.args.get_i64(var_name) {
                Some(n) => Some(n.to_string())
                None => None
              }
          }
      }
      out.write_string(match value {
        Some(v) => v
        None => "0"
      })
      i = end
    } else {
      out.write_char(ch)
      i = i + 1
    }
  }
  out.to_string()
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::fire_pre_interceptors(self : Engine[R, E], _exec : @exec.Execution) -> Unit raise @error.JeeflowError {
  // 预置拦截器保留；persist 后置拦截器只挂 post（rust 同款）
  let _ = self
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::fire_post_interceptors(self : Engine[R, E], exec : @exec.Execution) -> Unit raise @error.JeeflowError {
  for interceptor in self.ctx.interceptors {
    (interceptor.run)(exec)
  }
}

///|
/// 废弃同节点残留 DOING 会签任务（issues/94：merged 后不残留）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::abandon_countersign_remaining(self : Engine[R, E], exec : @exec.Execution, node_id : String) -> Unit raise @error.JeeflowError {
  let abandoned : Array[@model.ProcessTask] = []
  for task in exec.process_instance.tasks {
    if task.task_name == node_id && task.task_state == @model.TaskState::Doing.code() {
      task.task_state = @model.TaskState::Abandon.code()
      abandoned.push(task.clone())
    }
  }
  for t in abandoned {
    (self.repo()).update_task(t)
  }
}

///|
/// 聚合分配 ID（实例 + id=0 任务）
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::assign_ids(self : Engine[R, E], instance : @model.ProcessInstance) -> Unit raise @error.JeeflowError {
  instance.instance_id = self.next_id()
  for task in instance.tasks {
    if task.task_id == 0L {
      task.task_id = self.next_id()
      task.process_instance_id = instance.instance_id
    }
  }
}

///|
/// 新任务落库（原片赋 id 后 fire TASK_START，issues/13 时机闭环）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::persist_tasks(self : Engine[R, E], instance : @model.ProcessInstance, new_tasks : Array[@model.ProcessTask]) -> Unit raise @error.JeeflowError {
  for task in new_tasks {
    if task.task_id == 0L {
      task.task_id = self.next_id()
    }
    task.process_instance_id = instance.instance_id
    (self.repo()).save_task(task)
    if !task.actor_ids.is_empty() {
      (self.repo()).add_task_actor(task.task_id, task.actor_ids)
    }
    let event = @event.ProcessEvent::make(@event.ProcessTaskStart, task.task_id)
    @event.notify(event, self.ctx.event_listeners())
  }
}

///|
/// 解析发起时抄送人（issues/56 E28）：JSON 数组 / 逗号串 / 空三形态
pub fn parse_cc_actors(v : Json?) -> Array[String] {
  let out : Array[String] = []
  match v {
    None => ()
    Some(Json::Array(items)) =>
      for it in items {
        match it {
          Json::String(s) => if !s.is_empty() { out.push(s) }
          // id 字符串化走 repr 原文优先（>2^53 防 double 取整，D-M5-3）
          Json::Number(n, repr~) =>
            match repr {
              Some(s) => out.push(s)
              None => out.push(n.to_int64().to_string())
            }
          Json::True => out.push("true")
          Json::False => out.push("false")
          _ => ()
        }
      }
    Some(Json::String(s)) => {
      for part in s.split(",") {
        let t = part.to_string().trim(chars=" \t\r\n").to_string()
        if !t.is_empty() {
          out.push(t)
        }
      }
    }
    Some(_) => ()
  }
  out
}
