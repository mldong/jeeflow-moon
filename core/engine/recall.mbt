// 已办撤回（recall，issues/246）—— 判据与账本 ＋ 复活三件套
//
// 基准（逐条对照，冲突以 java 为准）：
//   · java `core/RecallSupport.java`（validateWindow 宽口径、collectDescendants 血缘 BFS、
//     appendRecallHistory 三键账本、五档逐字 msg）
//   · java `core/JeeflowEngineImpl.recallTask`（判据位序 1..5 全排前 → 废弃行 updateTask →
//     复活行 saveTask＋码 3 → 原行盖 tf_recallHistory updateTask → 实例 updateTime → 码 10）
//   · java `domain/ProcessInstance.recallTask`（聚合内废弃下游 + 同节点建复活行）
//   · java `model/TaskModel.allowRecall` ＋ `parser/ModelParser` 两条解析期禁配（落在 @parser）
//   · spec 02 §4.4／spec 04「已办撤回」／spec 06 §processTask/recall／spec 11 码 10
//
// 本栈落位与 java 的三处形状差异（照本仓 `add_sign.mbt` 的先例，语义逐字对齐）：
//   ① 本栈聚合根 `@model.ProcessInstance` 不收 `@parser`（core/model 不 import core/parser，
//      建单入参一律是原语），故 java `instance.recallTask(node, …)` 那一刀的"节点信息"由引擎
//      在这里现取原语后调 `create_task`——与 `add_sign.mbt::create_add_sign_tasks` 同一形状。
//   ② 复活行走本栈建单唯一收口 `persist_tasks`：id 分配、`task_parent_id`/`isFirstTaskNode`
//      建单不变量、委托并入、`save_task` + `add_task_actor`、码 3 `PROCESS_TASK_START` 全在
//      那一处（规范 04 建单规则 6/7「走既有腿，不新造时序」；python `engine.py:713-723`、
//      rust `engine.rs::recall_task_locked` 两条已落地腿同判据）。
//      ⚠️ 与 java 字面的一处出入：java `recallTask` 直调 `repository.saveTask`，那条腿不并委托；
//      本栈（与 python/rust 一致）走收口 ⇒ 配了生效委托时复活行的名册会被并入被委托人。
//      spec 04「成员行建单规则」明文「委托照既有腿并入」，取收口这一读法。
//   ③ 判据位序与 java 逐字一致，且**全部排在任何状态变更之前**——本栈门面/仓储没有事务模板可
//      回滚（内存仓读侧克隆、写侧覆盖），判据后置就留下"下游行停在 99 而无人能改回来"的半截事实。
//      报错即零写入三面：目标行状态不变、任务行总数不变、实例状态不变。

///|
/// 协议键：已办撤回追加式账本（落**被撤回的旧行**变量，只追加不覆盖）＝java `FlowConst.RECALL_HISTORY`
pub let recall_history_key : String = "tf_recallHistory"

///|
/// 协议键：办理时盖章的节点 allowRecall 快照（issues/251）＝java `FlowConst.ALLOW_RECALL`。
/// 落**执行 args**（⇒ 任务行变量）；`tf_` 前缀使实例合并自动剥键（不传播）。
/// 已办行置灰的「节点开关」预判从行上读，查询出口只搬运不解析定义；撤回校验仍以现读定义为权威。
pub let allow_recall_key : String = "tf_allowRecall"

///|
/// 逐字判据文案（跨栈统一，spec 04／spec 06 §processTask/recall 失败文案表同源）。
/// 本栈 `JeeflowError` 只有 `Business` 档的 message 原样对外 ⇒ 五档全走 Business，
/// 出口 code=99999999 ＋ 这句原文（不拼内部码、不加前缀）。
pub fn recall_window_msg(node : String) -> String {
  "任务[\{node}]的后续节点已办理，不能撤回"
}

///|
/// 逐字：节点未开开关（＝java `MSG_SWITCH_OFF`）
pub fn recall_switch_off_msg(node : String) -> String {
  "节点[\{node}]未开启 allowRecall，不能撤回"
}

///|
/// 逐字：目标行不是已完成态（行不存在也归这一档＝java 把两者并成一档，不发明第二种文案）
pub let recall_not_finished_msg : String = "任务非已完成状态，不可撤回"

///|
/// 逐字：非参与者（**按名册**判定，见 `recall_task_async` 里的承重判据注）
pub let recall_no_permission_msg : String = "无权限撤回该任务"

///|
/// 逐字：实例非进行中
pub let recall_instance_not_doing_msg : String = "流程实例非进行中状态，不可撤回"

///|
/// 逐字：实例读不到（＝java `recallTask` 里那句裸 `"流程实例不存在"`，
/// ⚠️ 不借 `@error.InstanceNotFound`——那支 message 带 id 尾巴，与基准文案不同形）
pub let recall_instance_missing_msg : String = "流程实例不存在"

///|
/// 按 `task_parent_id` 血缘收集 target 的全部后代行（BFS 用栈，逐字照 java
/// `RecallSupport.collectDescendants`；血缘在建单不变量里必写，0＝无父）。
/// 读的是**该实例全部任务行**（含已办结/已废弃/已撤回行）——窗口判据要看得到下游。
fn recall_descendants(tasks : Array[@model.ProcessTask], ancestor_id : Int64) -> Array[@model.ProcessTask] {
  let result : Array[@model.ProcessTask] = []
  let frontier : Array[Int64] = [ancestor_id]
  while !frontier.is_empty() {
    let parent = frontier[frontier.length() - 1]
    let _ = frontier.pop()
    for t in tasks {
      match t.parent_task_id {
        Some(p) =>
          if p == parent {
            result.push(t)
            frontier.push(t.task_id)
          }
        None => ()
      }
    }
  }
  result
}

///|
/// 窗口判据（owner 2026-11-03 拍宽口径，逐字＝java `RecallSupport.validateWindow`）：
/// 从 target 沿 `task_parent_id` 链产出的全部下游行中**存在任何 FINISHED** ⇒ 报错；
/// 否则返回其中仍 DOING 的行（供废弃——后加签续建行、征询成员行、并行分支多支都自然覆盖；
/// 已废弃(99)／已撤回(30) 行既不拦也不重复废弃）。
/// **纯读**：不改任何行、不落库、不 fire 事件。
pub fn validate_recall_window(
  tasks : Array[@model.ProcessTask], target : @model.ProcessTask
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let doing : Array[@model.ProcessTask] = []
  for t in recall_descendants(tasks, target.task_id) {
    if t.is_finished() {
      // ⚠️ 文案里那枚节点名是**被撤回的 target**（＝java `String.format(MSG_WINDOW, target.getTaskName())`），
      // 不是撞见 FINISHED 的那条下游行——用户看的是"我这单为什么撤不回"。
      raise @error.Business(recall_window_msg(target.task_name))
    }
    if t.is_doing() {
      doing.push(t)
    }
  }
  doing
}

///|
/// 读撤回账本（测试、审批记录与集成层都用这一枚，不各自 `get` 一份）——形状照 `add_sign_history_of`
pub fn recall_history_of(task : @model.ProcessTask) -> Array[Json] {
  let out : Array[Json] = []
  match task.variables.get(recall_history_key) {
    Some(v) =>
      match @json.as_array(v) {
        Some(items) =>
          for it in items {
            out.push(it)
          }
        None => ()
      }
    None => ()
  }
  out
}

///|
/// 账本追加一条（**只追加不覆盖**），落**被撤回的旧行**变量；三键固定 camelCase
/// `{operator, time, recalledTaskId}`（＝java `RecallSupport.appendRecallHistory` 的插入序），
/// `recalledTaskId` 指向复活的新行 ⇒ 从历史记录可一步跳到唯一活待办。
/// `time` 一律 `yyyy-MM-dd HH:mm:ss`（`@model.current_time_str()`，spec §2.4 全生态格式，账本跨栈同形）。
/// `tf_` 前缀使「退回上一步」的复活血缘腿天然剔掉它（`is_control_var_key` 那一判据）。
pub fn append_recall_history_vars(
  task : @model.ProcessTask, operator : String, resurrected_task_id : Int64
) -> Unit {
  let arr = @json.empty_array()
  for it in recall_history_of(task) {
    @json.arr_push(arr, it)
  }
  @json.arr_push(
    arr,
    @json.object_of([
      ("operator", @json.string_of(operator)),
      ("time", @json.string_of(@model.current_time_str())),
      ("recalledTaskId", @json.number_of(resurrected_task_id)),
    ]),
  )
  task.variables.insert(recall_history_key, arr)
}

///|
/// 已办撤回（spec 04 · 已办撤回 ＋ spec 06 §processTask/recall）：办理人收回**自己刚办结的那一手**，
/// 同实例内复活重办。
///
/// 判据位序逐字照 java `JeeflowEngineImpl.recallTask`，五道全排在任何状态变更之前：
/// 1. 目标行存在且已办结（FINISHED=20）⇒ 否则 `recall_not_finished_msg`（行不存在同档，基准就是一条）；
/// 2. **参与人按名册判断**（`actor_ids` 含 operator）——⚠️ 不走 `ProcessTask::is_allowed`：那条只认
///    DOING 行，而目标行正是 FINISHED，用它会把每一次合法撤回都判成无权（承重判据三）；
///    `flow.auto`／`flow.admin` 特权放行（转办/摘人同口径，大小写不敏感）；
/// 3. 实例存在且 DOING(10)；
/// 4. 节点是任务节点且开了 `allowRecall`；
/// 5. 窗口（宽口径）：下游行中存在任何 FINISHED ⇒ 报错，否则得到待废弃的 DOING 集合。
///
/// 判据全过之后的写序（＝java 落库顺序）：废弃行 update → 复活行走建单收口（save ＋ 参与者 ＋ 码 3）
/// → 原行盖 `tf_recallHistory` update → 实例 updateTime update → fire 码 10 `TASK_RECALL`
/// （sourceId＝被撤回的旧行；**只发 10 不补发 5/6**）。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::recall_task_async(
  self : Engine[R, E], task_id : Int64, operator : String
) -> @model.ProcessTask raise @error.JeeflowError {
  // ── 判据 1：行存在且已办结 ──
  let target = match (self.repo()).find_task_by_id(task_id) {
    Some(t) =>
      if t.is_finished() {
        t
      } else {
        raise @error.Business(recall_not_finished_msg)
      }
    None => raise @error.Business(recall_not_finished_msg)
  }
  // ── 判据 2：参与人（按名册）／特权 ──
  let lower = operator.to_lower()
  let privileged = lower == "flow.auto" || lower == "flow.admin"
  if !privileged && !(target.actor_ids.contains(operator)) {
    raise @error.Business(recall_no_permission_msg)
  }
  // ── 判据 3：实例存在且 DOING ──
  let instance = match (self.repo()).find_instance_by_id(target.process_instance_id) {
    Some(i) => i
    None => raise @error.Business(recall_instance_missing_msg)
  }
  if instance.state != @model.InstanceState::Doing.code() {
    raise @error.Business(recall_instance_not_doing_msg)
  }
  // ── 判据 4：节点开关 ──
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(instance.define_id)
  }
  let model = @parser.parse_model(define_info.content)
  let node = match model.get_node(target.task_name) {
    Some(n) =>
      if n.node_type is @parser.Task && n.allow_recall() {
        n
      } else {
        raise @error.Business(recall_switch_off_msg(target.task_name))
      }
    None => raise @error.Business(recall_switch_off_msg(target.task_name))
  }
  // ── 判据 5：窗口（读聚合里的行——find_instance_by_id 已按仓储真相回填 tasks，与 java 同一把尺子）──
  let doing_descendants = validate_recall_window(instance.tasks, target)
  // ══ 判据全过，以下才允许写 ══
  // 写 1：下游全部 DOING 行废弃（复用既有废弃腿 `ProcessTask::abandon`；聚合行与仓储行是两份
  // 拷贝，两处都要落，否则下面 update_instance 写回的副本仍是 DOING）。
  let abandoning : Array[Int64] = []
  for t in doing_descendants {
    abandoning.push(t.task_id)
  }
  for t in instance.tasks {
    if abandoning.contains(t.task_id) && t.is_doing() {
      try {
        t.abandon()
      } catch {
        _ => ()
      }
    }
  }
  for t in instance.tasks {
    if abandoning.contains(t.task_id) {
      (self.repo()).update_task(t)
    }
  }
  // 写 2：同节点新建一行 DOING——参与者＝**原行名册**、display_name＝原行、
  // `task_parent_id`＝**原行的 parent**（不是原行 id：撤回不是"往下走一步"，血缘位置必须原地顶替；
  // 留 None 会被 persist_tasks 的建单不变量补成原行 id，于是原行 parent=复活行、复活行 parent=原行
  // ⇒ 血缘成二元环，同 `rollback_to_parent` 里那条"老行 NULL 必须落 0"的纪律）。
  let carry = match target.parent_task_id {
    None => 0L
    Some(p) => p
  }
  let resurrected : @model.ProcessTask = instance.create_task(
    node.id,
    target.display_name,
    target.actor_ids.copy(),
    operator,
    @model.TaskType::from_code(node.task_type()),
    // performType 照节点配置取（java `createTask(TaskModel,…)` 用的就是 `taskModel.getPerformType()`）；
    // 会签节点禁配 allowRecall 由解析期拦下，正常配置下这里恒等 Normal。
    @model.PerformType::from_code(node.perform_type()),
    node.form_key(),
    Some(carry),
  )
  let args = @json.FlowData::new()
  let exec = @exec.Execution::make(instance, model, define_info, operator, args)
  exec.process_task = Some(target.clone())
  // 到期时间同尺重算（与三条建单腿同一把尺子，spec 04「expire_time 同尺重算」）
  apply_node_expire_time(exec, node, [resurrected])
  exec.new_tasks.push(resurrected)
  // 建单落库唯一收口：save_task ＋ 参与者 ＋ 委托并入 ＋ isFirstTaskNode ＋ fire 码 3
  self.persist_tasks(exec)
  // 写 3：原 FINISHED 行**一律不改写**，只在行变量上追加 tf_recallHistory
  // （recalledTaskId 要等复活行拿到 taskId，故排在 persist_tasks 之后）。
  append_recall_history_vars(target, operator, resurrected.task_id)
  (self.repo()).update_task(target)
  // 写 4：实例 updateTime/updateUser（＝java `ProcessInstance.recallTask` 尾两行 ＋ updateInstance）
  let inst = exec.process_instance
  inst.update_time = Some(@model.current_time_str())
  inst.update_user = Some(operator)
  (self.repo()).update_instance(inst)
  // 码 10 `TASK_RECALL`：撤回事实落库之后 fire 一次；只发 10 不补发 5/6（spec §11.2 原则 1）。
  self.notify_task_recall(inst.instance_id, target.task_id, operator)
  resurrected
}
