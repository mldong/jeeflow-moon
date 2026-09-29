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
  mut define_info : ProcessDefine?
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
    define_info: match self.define_info {
      Some(d) => Some(d.clone())
      None => None
    },
  }
}

///|
fn clone_json_map(src : Map[String, Json]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for k, v in src {
    m[k] = v
  }
  m
}

///|
/// 工厂：新建实例（state=DOING=10）
pub fn ProcessInstance::create(
  define_info : ProcessDefine,
  operator : String,
  args : @json.FlowData
) -> ProcessInstance {
  let variables = @json.FlowData::new()
  variables.merge(args)
  {
    instance_id: 0L,
    parent_id: None,
    define_id: define_info.id,
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
    define_info: Some(define_info.clone()),
  }
}

///|
/// 工厂（子流程）：带父实例
pub fn ProcessInstance::create_with_parent(
  define_info : ProcessDefine,
  operator : String,
  args : @json.FlowData,
  parent_id : Int64,
  parent_node_name : String
) -> ProcessInstance {
  let inst = ProcessInstance::create(define_info, operator, args)
  inst.parent_id = Some(parent_id)
  inst.parent_node_name = Some(parent_node_name)
  inst
}

///|
/// 完成任务：finish 任务 + 合并 f_ 变量（rust complete_task）
/// issues/115 契约第 5 条（spec/06 §transfer-5）：`args` 是「实例变量 ← 任务既有变量 ←
/// 本次提交参数」的合并结果（由引擎 load_exec_for_task 组装），这里**逐键写入**任务变量
/// （合并语义、不整体替换），故转办账本 `tf_transferHistory` 能活到办结后，而本次提交的
/// submitType/表单值又能覆盖转办留下的槽位（反噬方向已被合并序挡住）。
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
    task.variables.insert(k, v)
    if k.has_prefix("f_") {
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
pub fn ProcessInstance::resume_from_interrupt(self : ProcessInstance) -> Unit {
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
/// issues/114（spec/06 §withdraw）：`operator` = 真实撤回人，聚合根负责把实例与**被撤的**
/// 进行中任务的 `update_user` 回写为它；已完成(20)/已终止(40) 任务行不经本方法，天然不被改写。
///
/// issues/134 案 A（owner 2026-09-28 拍板，八栈逐字同形）：撤回只允许**进行中(10)** 的实例。
/// 实例不是 10（已完成 20 / 已撤回 30 / 强行终止 40 / 已拒绝 45 / 挂起 50 / 已废弃 99）⇒ 抛内部码
/// **20010009**，本栈形状 = `@error.Business(固定文案)`（与 20010007/20010008 同款——引擎只发明
/// 99999999 一个失败码，细粒度原因由 msg 承载，spec/06 §2.2）。守卫排在下面的任务行循环**之前**
/// ⇒ 被拒时一行都不改、不落库；否则已办结实例会被静默改写成 30（已办列表与按状态聚合的统计凭空
/// 改历史，而调用方看不到任何报错）。文案逐字 `流程实例非进行中，无法撤回`，门面沿用 issues/121
/// 口径内部码不进 msg ⇒ 出口 `code=99999999` ＋ 这句原文，不拼码、不加前缀。任务行层面的既有保护
/// （spec/06「已完成(20)/已终止(40) 的任务行不得被撤回改写」）保持原样。
pub fn ProcessInstance::withdraw(
  self : ProcessInstance,
  operator : String
) -> Unit raise @error.JeeflowError {
  // issues/134 案 A 实例状态守卫：非进行中(10) 一律拒，且不改写任何行（八栈同形）
  if self.state != InstanceState::Doing.code() {
    raise @error.Business("流程实例非进行中，无法撤回")
  }
  for t in self.tasks {
    if t.task_state == TaskState::Doing.code() {
      t.withdraw(operator)
    }
  }
  self.state = InstanceState::Withdraw.code()
  self.update_user = Some(operator)
  self.update_time = Some(current_time_str())
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
/// ⚠️ issues/137 B 拍板"不删"时它**引擎侧零调用者**（grep 只命中本定义与 core/model 单测）；
/// **issues/142 A 批（2026-09-30）把它接线了** —— `Engine::execute_custom_node` 记录类腿调它，
/// 并经由 `Engine::persist_history_task` 走 save_task/add_task_actor **真落库**
/// （spec/02 §6.2 第 1 条：只在聚合 `instance.tasks` 里 append 一条不算做到）。
/// 行形状：state=FINISHED(20) + actor_id=处理人 + actor_ids=[处理人]，前两条与主路径
/// ProcessTask::finish 写的列同判据。
/// ⚠️ **2026-09-30 issues/142 A 批收口改了一列**（spec/02 §6.2 第 1bis 条，owner 拍）：
/// `finish_time` 从此**必写**。原先这里钉的是「办理审计三列都不写」，理由「自动节点没有办理
/// 这一步」；但这条 DONE 行在用户面上要经 `processTask/doneList`（`task_state<>10 AND
/// operator=?`）与 `processInstance/approvalRecord` 查得到，那两支都按 operator＋finish_time
/// 取数 ⇒ 缺完成时间的留痕等于没落过（与第 1 条「查不到的留痕＝没留痕」同一把尺子）。
/// `expire_time` **必须留 None**（spec/02 §6 的 custom 属性字典无 expireTime，
/// 写它就得臆造属性，也与 issues/126 owner 口径「节点没配就保持 NULL」同向）——
/// 条文里「两列写、一列不写」说的就是 expire_time 这一列，别顺手把时间列全补上。
/// 另：`update_time`/`update_user` 本栈建单（create_task）本就不写，与 java
/// `ProcessTask.create` 顺手写这两列不同形，属本栈既有形状、不在本条判据内。
/// 直调行为由
/// i137b_zero_caller_create_test.mbt 逐字段钉住（该用例跟着本裁定改判）。
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
  // spec/02 §6.2 第 1bis 条（issues/142 A 批收口，owner 09-30）：留痕行必须带完成时间。
  // MoonBit 的 struct 是引用语义 ⇒ 这里赋值即聚合里那一格，不存在 rust 那边
  // 「返回行与 tasks 里那格分叉」的问题；但 MySQL 仓的 INSERT 语句原先没有 finish_time 列，
  // 值到不了库（repository-mysql/repo/repository.mbt::save_task 本轮补列）。
  task.finish_time = Some(current_time_str())
  task
}

///|
/// 退回上一步：为新节点建待办任务
/// ⚠️ issues/137 B：**真·零调用者**（连单测都没有；grep reject_task 全仓只命中本定义）。
/// 引擎的"退回上一步"支在 core/engine/engine_ops.mbt 里用结构体字面量手搓复活行
/// （随行拷贝 history 各列 + parent_task_id=Some(carry) + 按当前节点表达式重算
/// expire_time），没走这里 ⇒ 本函数无人调。
/// 仍承担**契约形状义务**：它＝主路径建单 create_task(task_name, display_name,
/// actor_ids, operator, Major, Normal, None, Some(parent_task_id)) 的具名别名，
/// 逐字段同形（i137b_zero_caller_create_test.mbt 用 == 钉住）。
/// owner 2026-09-29 拍板**不删**。
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
  !(any_doing)
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
/// 任务变量的合并写入在调用方（complete_task / complete_task_in_aggregate），
/// 本方法只置状态与办理人列 + `update_user`/`update_time` 审计列（对齐 java finish）。
pub fn ProcessTask::finish(self : ProcessTask, operator : String) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state (current=\{self.task_state})")
  }
  if !self.is_allowed(operator) {
    raise @error.PermissionDenied("Operator \{operator} is not allowed on task \{self.task_id}")
  }
  self.task_state = TaskState::Finished.code()
  self.actor_id = Some(operator)
  self.finish_time = Some(current_time_str())
  self.update_user = Some(operator)
  self.update_time = Some(current_time_str())
}

///|
pub fn ProcessTask::abandon(self : ProcessTask) -> Unit raise @error.JeeflowError {
  if self.task_state != TaskState::Doing.code() {
    raise @error.InvalidState("Task \{self.task_id} is not in DOING state")
  }
  self.task_state = TaskState::Abandon.code()
}

///|
/// 随实例撤回：任务态 30 + `update_user` 回写真实撤回人（issues/114，spec/06 §withdraw）
pub fn ProcessTask::withdraw(self : ProcessTask, operator : String) -> Unit {
  self.task_state = TaskState::Withdraw.code()
  self.update_user = Some(operator)
  self.update_time = Some(current_time_str())
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
pub fn ProcessTask::resume_from_interrupt(self : ProcessTask) -> Unit {
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


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend ProcessDefine with Eq::{equal, not_equal}
