// DDD 聚合根 ProcessInstance + 子实体 ProcessTask —— 移植自 rust model.rs L168-L542
// ⚠️ MoonBit 记录为引用语义：mut 字段原地共享可变；显式 clone 点用 clone_* 函数。
// content 用 String（JSON 文本）承载（rust 为 Vec<u8>，DB BLOB 边界在仓储层处理）。

///|
pub(all) struct ProcessDefine {
  mut id : Int64
  name : String
  display_name : String
  define_type : String
  mut state : Int
  mut content : String
  mut version : Int
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
} derive(Eq)

///|
pub fn ProcessDefine::clone(self : ProcessDefine) -> ProcessDefine {
  { ..self }
}

///|
/// ProcessInstance —— DDD 聚合根
pub(all) struct ProcessInstance {
  mut instance_id : Int64
  mut parent_id : Int64?
  mut define_id : Int64
  mut state : Int
  mut parent_node_name : String?
  mut business_no : String?
  mut operator : String
  mut expire_time : String?
  mut variables : @json.FlowData
  mut tasks : Array[ProcessTask]
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
  // 瞬态：define 信息（不落实例表）
  mut define : ProcessDefine?
}

///|
pub fn ProcessInstance::clone(self : ProcessInstance) -> ProcessInstance {
  {
    instance_id: self.instance_id,
    parent_id: self.parent_id,
    define_id: self.define_id,
    state: self.state,
    parent_node_name: self.parent_node_name,
    business_no: self.business_no,
    operator: self.operator,
    expire_time: self.expire_time,
    variables: @json.FlowData::from_map(clone_json_map(self.variables.inner())),
    tasks: self.tasks.map(fn(t) { t.clone() }),
    create_time: self.create_time,
    create_user: self.create_user,
    update_time: self.update_time,
    update_user: self.update_user,
    define: match self.define {
      Some(d) => Some(d.clone())
      None => None
    },
  }
}

///|
fn clone_json_map(src : Map[String, Json]) -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  for k, v in src {
    m[k] = v
  }
  m
}

///|
/// 工厂：新建实例（state=DOING=10）
pub fn ProcessInstance::create(
  define : ProcessDefine,
  operator : String,
  args : @json.FlowData
) -> ProcessInstance {
  let variables = @json.FlowData::new()
  variables.merge(args)
  {
    instance_id: 0L,
    parent_id: None,
    define_id: define.id,
    state: InstanceState::Doing.code(),
    parent_node_name: None,
    business_no: args.get_str("BUSINESS_NO"),
    operator,
    expire_time: None,
    variables,
    tasks: [],
    create_time: Some(current_time_str()),
    create_user: Some(operator),
    update_time: None,
    update_user: None,
    define: Some(define.clone()),
  }
}

///|
/// 工厂（子流程）：带父实例
pub fn ProcessInstance::create_with_parent(
  define : ProcessDefine,
  operator : String,
  args : @json.FlowData,
  parent_id : Int64,
  parent_node_name : String
) -> ProcessInstance {
  let inst = ProcessInstance::create(define, operator, args)
  inst.parent_id = Some(parent_id)
  inst.parent_node_name = Some(parent_node_name)
  inst
}

///|
/// 完成任务：finish 任务 + 合并 f_ 变量（rust complete_task）
pub fn ProcessInstance::complete_task(
  self : ProcessInstance,
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Unit raise @error.JeeflowError {
  let mut found : ProcessTask? = None
  for t in self.tasks {
    if t.task_id == task_id {
      found = Some(t)
    }
  }
  let task = match found {
    Some(t) => t
    None =>
      raise @error.InstanceNotFound(
        task_id,
      ) // rust 语义：任务不在聚合内报错；消息对齐 "任务不存在"
  }
  for k, v in args.inner() {
    if k.starts_with("f_") {
      self.variables.insert(k, v)
    }
  }
  task.finish(operator)
}

///|
pub fn ProcessInstance::abandon_task(
  self : ProcessInstance,
  task_id : Int64
) -> Unit raise @error.JeeflowError {
  let mut found : ProcessTask? = None
  for t in self.tasks {
    if t.task_id == task_id {
      found = Some(t)
    }
  }
  match found {
    Some(t) => {
      t.abandon()
      self.state = InstanceState::Abandon.code()
    }
    None => raise @error.TaskNotFound(task_id)
  }
}

///|
pub fn ProcessInstance::abandon_all_doing(self : ProcessInstance) -> Unit {
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      try {
        t.abandon()
      } catch {
        _ => ()
      }
    }
  }
}

///|
pub fn ProcessInstance::finish(self : ProcessInstance) -> Unit {
  self.state = InstanceState::Finished.code()
}

///|
pub fn ProcessInstance::reject(self : ProcessInstance) -> Unit {
  self.state = InstanceState::Reject.code()
}

///|
pub fn ProcessInstance::interrupt(self : ProcessInstance) -> Unit {
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      try {
        t.interrupt()
      } catch {
        _ => ()
      }
    }
  }
  self.state = InstanceState::Interrupt.code()
}

///|
pub fn ProcessInstance::resume(self : ProcessInstance) -> Unit {
  for t in self.tasks {
    if t.task_state == TaskState::Interrupt.code() {
      t.task_state = TaskState::Doing.code()
    }
  }
  self.state = InstanceState::Doing.code()
}

///|
pub fn ProcessInstance::pending(self : ProcessInstance) -> Unit {
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      try {
        t.pending()
      } catch {
        _ => ()
      }
    }
  }
  self.state = InstanceState::Pending.code()
}

///|
/// 撤回：实例 30 WITHDRAW + 全部 DOING 任务 30（C28：任务 30 非 45）
pub fn ProcessInstance::withdraw(self : ProcessInstance) -> Unit {
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      t.withdraw()
    }
  }
  self.state = InstanceState::Withdraw.code()
}

///|
pub fn ProcessInstance::add_variable(self : ProcessInstance, args : @json.FlowData) -> Unit {
  self.variables.merge(args)
}

///|
pub fn ProcessInstance::remove_variables(self : ProcessInstance, keys : Array[String]) -> Unit {
  for k in keys {
    self.variables.remove(k) |> ignore
  }
}

///|
/// 建任务（子实体工厂；task_id=0 由 ID 生成器赋值——rust 91b：原片赋 id 再克隆返回）
pub fn ProcessInstance::create_task(
  self : ProcessInstance,
  task_name : String,
  display_name : String,
  actor_ids : Array[String],
  operator : String,
  task_type : TaskType,
  perform_type : PerformType,
  form_key : String?,
  parent_task_id : Int64?
) -> ProcessTask {
  let task : ProcessTask = {
    task_id: 0L,
    process_instance_id: self.instance_id,
    task_name,
    display_name,
    task_type: task_type.code(),
    perform_type: perform_type.code(),
    task_state: TaskState::Doing.code(),
    actor_id: None,
    actor_ids: actor_ids.copy(),
    finish_time: None,
    expire_time: None,
    form_key,
    parent_task_id,
    variables: @json.FlowData::new(),
    create_time: Some(current_time_str()),
    create_user: Some(operator),
    update_time: None,
    update_user: None,
  }
  self.tasks.push(task)
  task
}

///|
/// 会签任务：每人一个独立任务（C9：串行一次只建一个由引擎控制；此处为并行建全入口）
pub fn ProcessInstance::create_countersign_tasks(
  self : ProcessInstance,
  task_name : String,
  display_name : String,
  actor_ids : Array[String],
  operator : String,
  task_type : TaskType,
  form_key : String?,
  parent_task_id : Int64?
) -> Array[ProcessTask] {
  let out : Array[ProcessTask] = []
  for actor in actor_ids {
    out.push(
      self.create_task(
        task_name,
        display_name,
        [actor],
        operator,
        task_type,
        Countersign,
        form_key,
        parent_task_id,
      ),
    )
  }
  out
}

///|
/// 历史任务（custom 节点用，直接 FINISHED）
pub fn ProcessInstance::create_history_task(
  self : ProcessInstance,
  task_name : String,
  display_name : String,
  operator : String,
  task_type : TaskType
) -> ProcessTask {
  let task = self.create_task(
    task_name,
    display_name,
    [operator],
    operator,
    task_type,
    Normal,
    None,
    None,
  )
  task.task_state = TaskState::Finished.code()
  task.actor_id = Some(operator)
  task
}

///|
/// 退回上一步：为新节点建待办任务
pub fn ProcessInstance::reject_task(
  self : ProcessInstance,
  task_name : String,
  display_name : String,
  actor_ids : Array[String],
  operator : String,
  parent_task_id : Int64
) -> ProcessTask {
  self.create_task(
    task_name,
    display_name,
    actor_ids,
    operator,
    Major,
    Normal,
    None,
    Some(parent_task_id),
  )
}

///|
pub fn ProcessInstance::get_doing_tasks(self : ProcessInstance) -> Array[ProcessTask] {
  let out : Array[ProcessTask] = []
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      out.push(t)
    }
  }
  out
}

///|
pub fn ProcessInstance::get_doing_tasks_by_names(
  self : ProcessInstance,
  names : Array[String]
) -> Array[ProcessTask] {
  let out : Array[ProcessTask] = []
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() && names.contains(t.task_name) {
      out.push(t)
    }
  }
  out
}

///|
pub fn ProcessInstance::get_finished_tasks(self : ProcessInstance) -> Array[ProcessTask] {
  let out : Array[ProcessTask] = []
  for t in self.tasks {
    if t.task_state == TaskState::Finished.code() {
      out.push(t)
    }
  }
  out
}

///|
pub fn ProcessInstance::get_done_tasks_by_names(
  self : ProcessInstance,
  names : Array[String]
) -> Array[ProcessTask] {
  let out : Array[ProcessTask] = []
  for t in self.tasks {
    if t.task_state == TaskState::Finished.code() && names.contains(t.task_name) {
      out.push(t)
    }
  }
  out
}

///|
pub fn ProcessInstance::get_history_tasks(self : ProcessInstance) -> Array[ProcessTask] {
  self.tasks.copy()
}

///|
pub fn ProcessInstance::is_all_tasks_finished(self : ProcessInstance) -> Bool {
  let mut any_doing = false
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      any_doing = true
    }
  }
  not(any_doing)
}

///|
pub fn ProcessInstance::is_doing(self : ProcessInstance) -> Bool {
  self.state == InstanceState::Doing.code()
}

///|
pub fn ProcessInstance::is_finished(self : ProcessInstance) -> Bool {
  self.state == InstanceState::Finished.code()
}

///|
/// ProcessTask —— 子实体
pub(all) struct ProcessTask {
  mut task_id : Int64
  mut process_instance_id : Int64
  mut task_name : String
  mut display_name : String
  mut task_type : Int
  mut perform_type : Int
  mut task_state : Int
  mut actor_id : String?
  mut actor_ids : Array[String]
  mut finish_time : String?
  mut expire_time : String?
  mut form_key : String?
  mut parent_task_id : Int64?
  mut variables : @json.FlowData
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
}

///|
pub fn ProcessTask::clone(self : ProcessTask) -> ProcessTask {
  {
    task_id: self.task_id,
    process_instance_id: self.process_instance_id,
    task_name: self.task_name,
    display_name: self.display_name,
    task_type: self.task_type,
    perform_type: self.perform_type,
    task_state: self.task_state,
    actor_id: self.actor_id,
    actor_ids: self.actor_ids.copy(),
    finish_time: self.finish_time,
    expire_time: self.expire_time,
    form_key: self.form_key,
    parent_task_id: self.parent_task_id,
    variables: @json.FlowData::from_map(clone_json_map(self.variables.inner())),
    create_time: self.create_time,
    create_user: self.create_user,
    update_time: self.update_time,
    update_user: self.update_user,
  }
}

///|
/// 完成（state→FINISHED=20）；守卫：仅 DOING + 处理人可办（并发语义 §6.2）
pub fn ProcessTask::finish(self : ProcessTask, operator : String) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state (current=\{self.task_state})")
  }
  if not(self.is_allowed(operator)) {
    raise @error.PermissionDenied("Operator \{operator} is not allowed on task \{self.task_id}")
  }
  self.task_state = TaskState::Finished.code()
  self.actor_id = Some(operator)
  self.finish_time = Some(current_time_str())
}

///|
pub fn ProcessTask::abandon(self : ProcessTask) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state")
  }
  self.task_state = TaskState::Abandon.code()
}

///|
pub fn ProcessTask::withdraw(self : ProcessTask) -> Unit {
  self.task_state = TaskState::Withdraw.code()
}

///|
pub fn ProcessTask::interrupt(self : ProcessTask) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state")
  }
  self.task_state = TaskState::Interrupt.code()
}

///|
pub fn ProcessTask::pending(self : ProcessTask) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state")
  }
  self.task_state = TaskState::Pending.code()
}

///|
pub fn ProcessTask::resume(self : ProcessTask) -> Unit {
  if self.task_state == TaskState::Interrupt.code() {
    self.task_state = TaskState::Doing.code()
  }
}

///|
/// 处理人校验："flow.auto"/"flow.admin" 直通
pub fn ProcessTask::is_allowed(self : ProcessTask, operator : String) -> Bool {
  if operator == "flow.auto" || operator == "flow.admin" {
    return true
  }
  self.is_doing() && self.actor_ids.contains(operator)
}

///|
pub fn ProcessTask::is_doing(self : ProcessTask) -> Bool {
  self.task_state == TaskState::Doing.code()
}

///|
pub fn ProcessTask::is_finished(self : ProcessTask) -> Bool {
  self.task_state == TaskState::Finished.code()
}
