// 引擎核心 —— 移植自 rust engine.rs（JeeflowEngineImpl，方案 §2.3 全 async）
// start → execute → jump → withdraw；spec/04-engine-ops.md
// 泛型 [R, E]：R : @spi.ProcessRepository, E : @spi.ProcessExtRepository

///|
pub(all) struct Engine[R, E] {
  ctx : @spi.Ctx[R, E]
}

///|
pub fn[R, E] Engine::make(ctx : @spi.Ctx[R, E]) -> Engine[R, E] {
  { ctx, }
}
///|
pub fn[R, E] Engine::context(self : Engine[R, E]) -> @spi.Ctx[R, E] {
  self.ctx
}

///|
fn[R, E : @spi.ProcessExtRepository] Engine::repo(
  self : Engine[R, E]
) -> R {
  self.ctx.repository()
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::next_id(self : Engine[R, E]) -> Int64 raise @error.JeeflowError {
  (self.ctx.id_generator_or_default())()
}

///|
/// 抄送知会事件（CC_CREATE / issues/102·104）：逐抄送人 fire，cc_actor_id 直传事件体。
/// 无监听器装配时零副作用。
///
/// **入参一律是"实际新建的 actor 子集"**（issues/141 G2 · spec 06 §4）：调用点先走
/// `ProcessRepository#create_cc_instance_if_absent` 拿到子集，子集为空整支不 fire——
/// spec §11.2 原则 1「码=事实」，重复抄送没发生"创建"就不该发码 4，严禁照旧按原始请求全量 fire。
/// 三条入口（发起 f_ccActors／办理 tf_ccActors／门面手动 createCCInstance）共用这一支（§11.7）。
pub fn[R, E] Engine::notify_cc_create(self : Engine[R, E], instance_id : Int64, cc_actors : Array[String]) -> Unit {
  for actor in cc_actors {
    let event = @event.ProcessEvent::make(CcCreate, instance_id).with_cc_actor_id(actor)
    @event.notify(event, self.ctx.event_listeners())
  }
}

///|
/// 注入用户信息变量（u_userId/u_realName/…；C25：仅 start 注入一次）
fn[R, E] Engine::add_user_info(self : Engine[R, E], args : @json.FlowData, operator : String) -> Unit {
  if operator == "flow.auto" || operator == "flow.admin" {
    return
  }
  match self.ctx.user_provider {
    Some(get_user) => {
      // provider 签名是 `(String) -> UserInfo? raise JeeflowError`：
      // 取用户失败按旧语义吞掉（catch 到 _ => ()），不炸发起路径。
      try {
        match (get_user)(operator) {
          Some(user) => {
            args.insert_str("u_userId", user.user_id())
            args.insert_str("u_realName", user.real_name())
            args.insert_str("u_deptId", user.dept_id())
            args.insert_str("u_deptName", user.dept_name())
            args.insert_str("u_postId", user.post_id())
            args.insert_str("u_postName", user.post_name())
          }
          None => ()
        }
      } catch {
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
fn[R, E] Engine::resolve_assignee(self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel) -> Array[String] {
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
          // handler 签名是 `-> String raise JeeflowError`：旧 `try?` 把 raise 折成 Result，
          // Err 臂就是"这一档跳过"；换成空串后下面的 !is_empty 判据走同一条落空路径。
          let result = try { (handler)(exec) } catch { _ => "" }
          if !result.is_empty() {
            return split_actors(result)
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
        let s = u.to_owned().trim(chars=" \t\r\n").to_owned()
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
    let t = part.to_owned().trim(chars=" \t\r\n").to_owned()
    if !t.is_empty() {
      out.push(t)
    }
  }
  out
}

///|
/// issues/131（案 A）：串行会签簿记三件写进成员任务的变量。
/// 判据基准逐字取 java：写 ProcessInstance.java:257-259；读与推进 CountersignHandler.java:71-84,154-157。
fn seed_countersign_bookkeeping(
  task : @model.ProcessTask, node : String, roster : Array[String], loop_counter : Int64
) -> Unit {
  task.variables.insert_string_array("operatorList_" + node, roster)
  task.variables.insert_i64("loopCounter_" + node, loop_counter)
  task.variables.insert_i64("nrOfInstances_" + node, roster.length().to_int64())
}

///|
/// issues/126 案 A · 建单路径共用的到期写点（普通建单 / 串行会签首位 / 并行会签全员 /
/// 串行会签**推进出的下一位成员**——§1.8 更正后的第五处）。
/// 表达式取自任务节点属性 `expireTime`（parser 已把 properties 逐键搬进 NodeModel）；
/// 变量源＝**实例变量**（java `ProcessInstance.applyExpireTime` 的 `this.variables`
/// ＝ boot2 的 `execution.getArgs()`）。
/// 刻意用 `prop_str` 取表达式：非字符串档（JSON null / 数字）一律当"没配"，不会把"没配"
/// 伪造成"配了个算不出的表达式"（两档终局同为 NULL，但后者会白走一遍求值档）。
fn apply_node_expire_time(
  exec : @exec.Execution, node : @parser.NodeModel, tasks : Array[@model.ProcessTask]
) -> Unit {
  let expr = node.prop_str(@model.expire_time_prop)
  for t in tasks {
    @model.apply_expire_time(t, expr, exec.process_instance.variables)
  }
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
  } else if node.node_type is @parser.Task {
    // 任务创建不触发**后置**节点拦截器（对齐 Java CreateTaskHandler / Go executeNode）——保持原样。
    // 前置侧 issues/116 批次 D 打通了独立通道（ctx.pre_interceptors），"建单那一刻"从此可挂。
    // ⚠️ 内置委托自动生效**不挂这里**：此刻参与者尚未进聚合、taskId 尚未分配，
    // 它落在唯一落库收口 `persist_tasks` 的 save_task 之前（见 surrogate.mbt 条款 2 ⚠️）。
    self.fire_pre_interceptors(exec)
    self.create_task_with_assignment(exec, node)
  } else if node.node_type is @parser.Custom {
    // issues/142 A 批 · spec/02 §6.1 表第二行：记录类独立一支。从前它与 Task 合流，于是被
    // 任务类那套「参与者解析」判据管着、建一条 DOING 待办 —— 而记录类节点本来就不该有
    // 参与者、也不该有待办：执行 clazz、落一条 DONE 历史行（真落库）、令牌继续沿出边走。
    self.execute_custom_node(exec, node)
  } else if node.node_type is @parser.Unknown {
    // 兜底守卫：parse_model 已把未知档拦在模型外（记日志＋跳过节点，spec/02 类型键义务 2），
    // 正常路径走不到这一臂。留着是为了「库里存过的旧定义／第三方直接喂进来的 ProcessModel」
    // 也不被当记录类落一条留痕行 —— 与解析期同判据：记日志、不静默、不动令牌。
    println(@parser.unknown_node_warning(node.id, node.node_type.as_str()))
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
    // fire 结束事件：载荷 instanceId + state（§11.3 code 2，「state＝落库后的实例状态整数」）。
    // 取的就是上面 update_instance 刚落库的那个值，不在这里二次推演。
    self.notify_instance_end(
      exec.process_instance.instance_id, exec.process_instance.state
    )
    self.fire_post_interceptors(exec)
  } else if node.node_type is @parser.SubProcess {
    // 子流程简化处理（rust 同款：不做完整子流程展开）
    ()
  } else {
    ()
  }
}

///|
/// 建任务（含参与人解析；任务类零参与者照样建单，issues/142 A 批）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::create_task_with_assignment(self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel) -> Unit raise @error.JeeflowError {
  let actor_ids = self.resolve_assignee(exec, node)
  // issues/142 A 批 · spec/02 §6.1 表第一行 + §6.2 第 3 条：任务类**零参与者照样建一行 DOING**
  // （java `CreateTaskHandler.handle` 无条件建单）。旧形状是「actors 解析为空 ⇒ 一行不建、
  // 令牌直接放行到下一节点」，那正是 §6.1 点名 python 曾犯的死锁黑洞：实例停在 state=10
  // 却一条可办行都没有（普查现读 go/node/rust/moon 四栈同病，本轮四栈跟改，这里即 moon 那一栈）。
  // 参与者为空就落一行 actor_ids=[] 的行 —— **不兜底挂当前操作人**（§6.1 硬结论 1：八栈一律不许有）。
  let perform_type = @model.PerformType::from_code(node.perform_type())
  let task_type = @model.TaskType::from_code(node.task_type())
  if perform_type is Countersign {
    let cs_type = node.countersign_type()
    let cs_upper = cs_type.to_upper()
    if cs_upper == "SEQUENTIAL" || cs_upper == "SERIAL" {
      // 串行：只建第一人任务（issues/94）；名册簿记搬到任务变量（issues/131，见下方 seed）
      if actor_ids.is_empty() {
        return
      }
      let tasks = exec.process_instance.create_countersign_tasks(
        node.id,
        node.display_name,
        [actor_ids[0]],
        exec.operator,
        task_type,
        node.form_key(),
        None,
      )
      // issues/131（案 A，以 java 为准）：簿记三件写在首位成员任务的变量上——
      // java ProcessInstance.java:257-259 就是往那一条任务塞 operatorList/loopCounter/nrOfInstances。
      // MoonBit 的 struct 是引用 ⇒ 改 tasks[0] 就是改聚合根里那一份（rust 的克隆要写两份，这里不用）。
      // 名单必须是 JSON 数组：门禁 L2-23 按 len(值) 数成员，逗号串会被数成字符串长度。
      if tasks.length() > 0 {
        seed_countersign_bookkeeping(tasks[0], node.id, actor_ids, 0L)
      }
      // issues/126 案 A 写点②：串行会签**首位成员**按节点表达式算到期时间
      apply_node_expire_time(exec, node, tasks)

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
      // issues/126 案 A 写点③：并行会签**全员**逐条按节点表达式算到期时间
      apply_node_expire_time(exec, node, tasks)
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
    // issues/126 案 A 写点①：普通建单按节点表达式算到期时间；
    // 节点没配 ⇒ 这一列保持 NULL（不写 now()、不写 ''、不写 0）
    apply_node_expire_time(exec, node, [task])
    exec.new_tasks.push(task)
  }
}

///|
/// 记录类返回值写入流程变量的**缺省**键（`properties.val` 没配 / 配空串时用这一档）。
/// 逐字对齐 java `FlowConst.CUSTOM_RETURN_VAL` 与 python `KEY_CUSTOM_RETURN_VAL`。
pub let custom_return_val_key : String = "custom_return_val"

///|
/// 记录类返回值写入的变量键：`val` 命中用之（trim 后非空），否则缺省 `custom_return_val`
/// （对齐 java `CustomParser.java:20-22` 解析 + `CustomModel.java:46-48` 写 `execution.getArgs()`）。
pub fn custom_return_key(node : @parser.NodeModel) -> String {
  let v = match node.prop_str("val") {
    Some(s) => s.trim(chars=" \t\r\n").to_owned()
    None => ""
  }
  if v.is_empty() { custom_return_val_key } else { v }
}

///|
/// 「未注册处理器」档的诊断日志文案（spec/02 §6.2 第 2 条末尾：两档日志要**分别**可诊断，
/// 不许像 c# 那样把「clazz 空串」与「未注册」合成同一条）。抽纯函数的理由同 parser：
/// println 的效果在测试里读不回来，判据留在纯函数、副作用留在调用点。
pub fn custom_handler_unregistered_warning(node_id : String, clazz : String) -> String {
  "[jeeflow] custom 节点 clazz=\{clazz} 未注册处理器，跳过执行、照常落历史行并继续流转" + "（本栈无反射，注册入口：@spi.Ctx::register_custom_handler）: nodeId=\{node_id}"
}

///|
/// 「clazz 空串/缺失」档的诊断日志文案（同一节点属性的另一格病灶：连按名解析的键都没有）。
pub fn custom_clazz_missing_warning(node_id : String) -> String {
  "[jeeflow] custom 节点未配置 clazz（缺失或空串），不执行处理器、照常落历史行并继续流转" + ": nodeId=\{node_id}"
}

///|
/// 记录类（`snaker:custom`）节点执行腿 —— issues/142 A 批，spec/02 §6.1 表第二行 + §6.2 三条硬要求。
/// 现成对照＝python 本轮那条腿（`jeeflow-python/jeeflow/engine.py::_exec_custom_node`）。
///
/// 四件事，缺任一件都算违反 §6.2（「落库不建行 / 建行不落库 / 记日志但停在原地」都是半截）：
/// 1. 执行 `clazz` —— MoonBit 没有反射，java 那句 `Class.forName(clazz)` 在本栈无从谈起，
///    故与 C#/Python 同策：`Ctx::register_custom_handler(<clazz 原样串>, handler)` 按名注册、引擎按名解析；
/// 2. 落一条**历史行**（task_state=20）—— 调 issues/137 B 拍板「不删」的那支
///    `ProcessInstance::create_history_task`，本单正是把它接线的那一单；
/// 3. **真落库**：走 `save_task` + `add_task_actor`，内存仓与 MySQL 仓两条建行通道各自真
///    INSERT（§6.2 第 1 条：只在聚合 `instance.tasks` 里 append 一条不算做到 —— java/c# 的
///    历史行至今没有 INSERT 腿，正是本条要补的洞）；
/// 4. 令牌沿出边继续流转（java `CustomModel` 收尾那句 `runOutTransition`）。
///
/// ⚠️ §6.1 表列的三条禁止形状，本腿逐条不犯：① 当任务类建 DOING 行；② 兜底把行挂给当前
///    操作人、伪造一条他不该收到的待办（历史行的 actor=operator 是**留痕主体**不是待办主体：
///    行状态 20 谁也办不动，todoList 按 task_state=10 取行，它进不去）；③ 直接跳过节点不建行。
/// ⚠️ **不 fire 码 3**（PROCESS_TASK_START）：spec/11 §11.2 原则 1「码=事实」，码 3 表达
///    「新待办产生」，而本腿建行即已完成态。同一理由本腿**不进** `exec.new_tasks` —— 那是
///    「本步新产生的待办」清单（门面出口与集成层按它推待办），落库走 `persist_history_task` 单独一支。
///
/// ⚠️ 返回值只写进**执行变量** `exec.args`（与 java 写 `execution.getArgs()`、python 写 `vars_`
///    同口径）：同一次令牌推进里下游决策边读得到；跨步骤的实例变量回写不在本条义务内。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_custom_node(
  self : Engine[R, E],
  exec : @exec.Execution,
  node : @parser.NodeModel
) -> Unit raise @error.JeeflowError {
  // 前置拦截器与原 Task|Custom 合流时同口径（「建单那一刻」可挂，issues/116 批次 D）；
  // 后置仍不 fire —— 与本栈建单腿一致（刻意不触发，见上面 CreateTaskHandler 对齐注释）。
  self.fire_pre_interceptors(exec)
  let clazz = match node.prop_str("clazz") {
    Some(s) => s.trim(chars=" \t\r\n").to_owned()
    None => ""
  }
  match self.ctx.find_custom_handler(clazz) {
    Some(handler) => {
      // 处理器**自身**执行失败 ⇒ 直接外抛：§6.2 第 2 条豁免的是「解析不了」（配置形状），
      // 不是「跑炸了」（业务错误）。这一支不加 try，外抛即与 java CustomModel 方法调用失败同形。
      let ret = (handler)(exec)
      match ret {
        Json::Null => ()
        _ => exec.args.insert(custom_return_key(node), ret)
      }
    }
    // 两档日志分别可诊断（§6.2 第 2 条末尾；c# 合成一条的形状不许照抄）：都记完日志照常
    // 落历史行 + 续流，严禁 abort/raise 打断建单 —— 与 spec/04「节点属性配错不该把流程炸掉」同哲学。
    None =>
      if clazz.is_empty() {
        println(custom_clazz_missing_warning(node.id))
      } else {
        println(custom_handler_unregistered_warning(node.id, clazz))
      }
  }
  let history = exec.process_instance.create_history_task(
    node.id, node.display_name, exec.operator, @model.TaskType::from_code(node.task_type())
  )
  self.persist_history_task(exec, history)
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

///|
/// 历史行落库通道（spec/02 §6.2 第 1 条「历史行必须真落库」的那条 INSERT 腿）。
/// 建单不变量与 `persist_tasks` 同判据：`task_parent_id` ＝产生这一步的那个刚办结任务
/// （发起 execution 没有当前任务 ⇒ 落 0L），行级 `isFirstTaskNode` 建单时落库（回退血缘要读它）。
/// 与 `persist_tasks` 的三处刻意差别：① 入参是单条已完成行、不进 `exec.new_tasks`；
/// ② **不 fire 码 3**；③ 不做委托并入（历史行不是待办，代理人无从「替办结」）。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::persist_history_task(
  self : Engine[R, E],
  exec : @exec.Execution,
  task : @model.ProcessTask
) -> Unit raise @error.JeeflowError {
  if task.task_id == 0L {
    task.task_id = self.next_id()
  }
  task.process_instance_id = exec.process_instance.instance_id
  match task.parent_task_id {
    None =>
      task.parent_task_id = Some(
        match exec.process_task {
          Some(t) => t.task_id
          None => 0L
        },
      )
    _ => ()
  }
  task.variables.insert(
    "isFirstTaskNode",
    @json.bool_of(exec.process_model.is_first_task_node(task.task_name)),
  )
  (self.repo()).save_task(task)
  if !task.actor_ids.is_empty() {
    (self.repo()).add_task_actor(task.task_id, task.actor_ids)
  }
}

///|
fn[R, E] Engine::evaluate_decision(self : Engine[R, E], _exec : @exec.Execution, _node : @parser.NodeModel) -> String? {
  // rust 同款：命名目标路由暂未启用，交由边表达式求值
  let _ = self
  None
}

///|
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::evaluate_expression(self : Engine[R, E], expr : String, exec : @exec.Execution) -> Bool raise @error.JeeflowError {
  match self.ctx.expression_evaluator {
    Some(eval) => {
      let vars : Map[String, Json] = Map([])
      for k, v in exec.args.inner() {
        vars[k] = v
      }
      // SPI 是 `-> Json raise JeeflowError`：值即 Json。求值失败按旧语义当 false
      try {
        let v = (eval)(expr, vars)
        match v {
          Json::True => true
          Json::False => false
          Json::Number(n, ..) => n != 0.0
          Json::String(s) => !s.is_empty() && s != "false" && s != "0"
          _ => false
        }
      } catch {
        _ => false
      }
    }
    None => self.simple_eval(expr, exec)
  }
}

///|
/// 简单表达式求值：比较运算 + ${var}/#var 引用 + 布尔字面量
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::simple_eval(self : Engine[R, E], expr : String, exec : @exec.Execution) -> Bool raise @error.JeeflowError {
  let e = expr.trim(chars=" \t\r\n").to_owned()
  let resolved = self.resolve_var_refs(e, exec)
  // 比较运算（先长后短避免误切）
  for op in [">=", "<=", "!=", "==", ">", "<"] {
    match resolved.find(op) {
      Some(pos) => {
        let left = resolved[0:pos].trim(chars=" \t\r\n").to_owned()
        let right = resolved[pos + op.length():].trim(chars=" \t\r\n").to_owned()
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
  // 两侧都能解析成数值才按数值比，任一失败 ⇒ 字符串兜底（旧语义）
  // parse_double 是 `-> Double raise`：`try` 两臂必须同类型，所以成功臂自己包 Some
  let l = try {
    Some(@string.parse_double(left))
  } catch {
    _ => None
  }
  let r = try {
    Some(@string.parse_double(right))
  } catch {
    _ => None
  }
  match (l, r) {
    (Some(lv), Some(rv)) =>
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
  let _ = self
  let mut result = expr
  // ${var}
  let mut cont = true
  while cont {
    match result.find("$" + "{") {
      Some(s) =>
        match result[s:].find("}") {
          Some(offset) => {
            let var_name = result[s + 2:s + offset].to_owned()
            let value = match exec.args.get_str(var_name) {
              Some(v) => v
              None => "0"
            }
            result = result[0:s].to_owned() + value + result[s + offset + 1:].to_owned()
          }
          None => cont = false
        }
      None => cont = false
    }
  }
  // #var（会签门控变量）
  let out = StringBuilder()
  let mut i = 0
  let chars = result.to_array()
  let len = chars.length()
  while i < len {
    let ch = chars[i]
    if ch == '#' && i + 1 < len && ((chars[i + 1].to_int() >= 97 && chars[i + 1].to_int() <= 122) || (chars[i + 1].to_int() >= 65 && chars[i + 1].to_int() <= 90) || chars[i + 1] == '_') {
      let start = i + 1
      let mut end = start
      while end < len {
        let c = chars[end].to_int()
        if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || chars[end] == '_' {
          end = end + 1
        } else {
          break
        }
      }
      let var_name = result[start:end].to_owned()
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
/// 前置拦截器派发（issues/116 批次 D 补的最小挂点）。
/// 历史：本函数是空实现 ⇒ `Ctx::register_interceptor` 注册的东西只在**后置**跑，
/// 建单期第三方无处可挂（issues/116 §3、issues/104 §P1）。
/// 现按 order 遍历 `ctx.pre_interceptors` —— 一条**与后置数组分开**的通道：
/// `InterceptorFn` 只有一个 `run`（无 before/after 之分），复用后置数组会让
/// persist 的 PersistPostInterceptor 双触发（归档/SYNC 写两遍），故另起 pre 通道。
/// 委托自动生效不经本函数（时机对不上，见 `surrogate.mbt` 头部 ①②）。
fn[R, E] Engine::fire_pre_interceptors(
  self : Engine[R, E],
  exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  for interceptor in self.ctx.pre_interceptors {
    (interceptor.run)(exec)
  }
}

///|
fn[R, E] Engine::fire_post_interceptors(self : Engine[R, E], exec : @exec.Execution) -> Unit raise @error.JeeflowError {
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
/// 新任务落库（原片赋 id 后 fire TASK_START，issues/13 时机闭环）。
/// ⚠️ 本函数是**全引擎新任务落库的唯一收口**：7 处建任务路径（发起 / 带父实例发起 /
/// 办理推进 / 串行会签每一步 / 会签未合并提前返回 / 表达式会签 / 跳转含回退与退回发起人）
/// 都走它 —— issues/116 批次 D 的委托自动生效因此只挂这一处即覆盖全部路径。
/// 入参改收 `exec`（而非 instance+new_tasks）即为了让收口拿得到**流程模型 name**
/// （spec 06 §4.5 条款 1.1：委托查询以模型 name 为准，未带时回落 define.name）。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::persist_tasks(
  self : Engine[R, E],
  exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  let instance = exec.process_instance
  let process_name = self.surrogate_process_name(exec)
  for task in exec.new_tasks {
    if task.task_id == 0L {
      task.task_id = self.next_id()
    }
    task.process_instance_id = instance.instance_id
    // issues/121 P1 建单不变量：parent 与行级 isFirstTaskNode 必写。挂在这里是因为本函数
    // 是全引擎新任务落库唯一收口（7 处建任务路径都汇入 exec.new_tasks）——与下面 116 的委托
    // 并入口同型，一处即全覆盖。parent＝产生这批新任务的那个刚办结任务；发起 execution 没有
    // 当前任务 ⇒ 落 0L（对齐 mldong-boot2 Convert.toLong(execution.getProcessTaskId(), 0L)）。
    match task.parent_task_id {
      None =>
        task.parent_task_id = Some(
          match exec.process_task {
            Some(t) => t.task_id
            None => 0L
          },
        )
      _ => ()
    }
    // 出口现算版带「仅进行中」判定，已办结的历史行上恒 false，而血缘版回退要读那条历史行
    // 决定参与者 ⇒ 判据必须建单时落库（沿用 parser 现成的 is_first_task_node，不新造算法）。
    task.variables.insert(
      "isFirstTaskNode",
      @json.bool_of(exec.process_model.is_first_task_node(task.task_name)),
    )
    // 落库前并入被委托人到**参与者集合本身**（条款 2 ⚠️）：下面 save_task + add_task_actor
    // 带的就是含代理人的集合，不存在"事后补写打在空 taskId 上"的静默无效。
    let _ = self.apply_surrogate(task, process_name)
    (self.repo()).save_task(task)
    if !task.actor_ids.is_empty() {
      (self.repo()).add_task_actor(task.task_id, task.actor_ids)
    }
    // 载荷 instanceId/taskId/actors（§11.3 code 3）。⚠️ instanceId 是硬要求：本支 sourceId 是 taskId，
    // 集成层 L2-30 的事件流水 sink 只能靠载荷里的 instanceId 把一条流的流水归到一个键下；
    // 缺它则被拆成多个 taskId 键、顺序读不全（rust 栈同一个病）。
    self.notify_task_start(instance.instance_id, task.task_id, task.actor_ids)
  }
}

///|
/// 解析抄送人（issues/56 E28）：JSON 数组 / 逗号串 / 空三形态 —— 发起 `f_ccActors`、办理
/// `tf_ccActors`（issues/141 G6 两腿同器）与子流程发起腿三条入口共用的**唯一漏斗**。
///
/// issues/141 G10（spec 06-facade §2.10「空抄送人不建 cc 行」）：两形态的产物一律过
/// `@model.normalize_cc_actors` 收口 —— 空串/纯空白/数组里的空元素丢弃、**值取 trim 后的串**、
/// 同一次调用内的重复折叠；丢完为空 ⇒ 调用方不建 cc 行也不 fire 码 4。归一不在这里各抄一份：
/// 逗号腿与数组腿只负责"切成元素"（此前数组腿只丢 `""`、不 trim ⇒ `["  "]` 原样进写侧、
/// `[" a "]` 落成与 `"a"` 不同的两个人），空值判据只在 `@model` 那一处。
pub fn parse_cc_actors(v : Json?) -> Array[String] {
  let out : Array[String] = []
  match v {
    None => ()
    Some(Json::Array(items)) =>
      for it in items {
        match it {
          Json::String(s) => out.push(s)
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
        out.push(part.to_owned())
      }
    }
    Some(_) => ()
  }
  // issues/141 G10 判据单点：空值丢弃 + trim + 同调用折叠只在 @model.normalize_cc_actors 写一次
  @model.normalize_cc_actors(out)
}
