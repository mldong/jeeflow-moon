// 后加签（可重复）—— 写入口四判据 / 推进闸裁决 / 同节点续建 / 轮次与追加式账本
//
// 基准（逐条对照）：
//   · java `core/AddSignSupport.java`（validateSubmission 四判据、hasDoingOnNode、
//     abandonDoingOnNode、roundOf、appendHistory/historyOf、四档逐字 msg）
//   · java `handler/impl/AddSignHandler.java`（建单腿 + merged 判据顺序）
//   · java `model/TaskModel.java:34-53`（推进闸三档）
//   · spec 04-engine-ops「后加签（可重复）」、spec 06-facade §2.7（协议键 + 文末失败 msg 表）
//
// 本栈落位与 java 的三处形状差异（形状照本仓 `reapply.mbt` 的先例，语义逐字对齐）：
//   ① 本栈没有 `NodeModel::exec` 虚方法，三档闸挂在 `engine_ops.mbt::execute_task_async`
//      的「会签门之后、下钻之前」（10a 档）；停留时**只跳下钻**，抄送腿与落库腿照常走
//      —— java 那侧 `executeProcessTask` 正是这个次序（runOutTransition 被跳过，
//      handleCcActors / persistTasks 不受影响）。
//   ② 四判据的前置点＝`load_exec_for_task` 里 `complete_task_in_aggregate` 之前
//      （＝java `prepareExecution` 的同一位置）。本栈仓储同样是"读侧克隆、写侧覆盖、
//      无事务模板可回滚" ⇒ 判据若在写之后，报错时就留下"任务已办结、无人能改回"的
//      半截事实（"报错且零写入"是这条链的硬要求）。
//   ③ 加签人由 `Execution#add_sign_operators` 字段承载（＝java `Execution#addSignOperators`），
//      只认当次请求：`full_args` 是"实例变量 ← 任务变量 ← 本次参数"的合并结果，
//      上一轮的 `tf_addSignOperators` 从那里读就会跨请求复活、凭空多建一条本节点待办。

///|
/// 协议键：本次提交指定的**本节点**后继办理人（逗号串与数组两形同判据，spec 06 §2.7）
pub let add_sign_operators_key : String = "tf_addSignOperators"

///|
/// 协议键：追加式加签账本（只落已完成任务行变量，只追加不覆盖）
pub let add_sign_history_key : String = "tf_addSignHistory"

///|
/// 协议键：发起该轮征询的原因说明（选填，字符串；issues/247）——随账本条目落库并盖到每条成员行
/// （单行出证自足，不回查主办行）。键名与 java `FlowConst.ADD_SIGN_REASON` 逐字同。
/// 与上面两枚 `tf_addSign*` 同族：动态会签（征询模式）复用后加签的协议键族，行为由节点属性分流。
pub let add_sign_reason_key : String = "tf_addSignReason"

///|
/// 轮次键前缀（拼 `_{节点名}`）。刻意**不**复用会签簿记 `loopCounter`：后者是血缘复活血
/// 要剔掉的会签计数，加签轮次要跨"已办过的人"继续计数（java `FlowConst.ADD_SIGN_ROUND` 同决定）
pub let add_sign_round_prefix : String = "addSignRound"

///|
/// 互斥对手键：下一节点指定办理人（同传 ⇒ 报错，理由见 `validate_add_sign_submission`）
pub let next_node_operator_key : String = "tf_nextNodeOperator"

///|
/// 逐字判据文案（跨栈统一，spec 06 文末失败 msg 表同源）。本栈 JeeflowError 只有
/// `Business` 档的 message 原样对外 ⇒ 四档都走 Business，出口 code=99999999 + 这句原文。
pub let add_sign_mutex_msg : String =
  "tf_addSignOperators 与 tf_nextNodeOperator 互斥，不能同时提交"

///|
/// 逐字：加给自己（死循环入口）
pub let add_sign_self_msg : String = "不能把任务加签给自己"

///|
/// 逐字：节点未开开关却传键（静默忽略＝客户排障地狱）
pub fn add_sign_switch_off_msg(node : String) -> String {
  "节点[\{node}]未开启 allowAddSign，不接受 tf_addSignOperators"
}

///|
/// 逐字：超 `addSignMaxRounds`（放行＝伪造"审批完成"，故只报错不强制推进）
pub fn add_sign_max_rounds_msg(node : String, max : Int64) -> String {
  "节点[\{node}]的加签轮次已达上限 \{max}，本次提交被拒绝"
}

///|
/// 轮次键全名（`addSignRound_{节点名}`；本栈节点名＝节点 id）
pub fn add_sign_round_key(node : String) -> String {
  add_sign_round_prefix + "_" + node
}

///|
/// 本次提交点名的加签人：逗号串与数组两形都过 `parse_actors` 这一枚形状适配器，
/// 判据单点仍在 `@model.normalize_actors`（逐元素 trim、空值丢弃、同调用折叠）；
/// 没点人 ⇒ 空表（与"传了空串/全空白"同一答案）。
pub fn add_sign_operators_of(args : @json.FlowData) -> Array[String] {
  parse_actors(args.get(add_sign_operators_key))
}

///|
/// 「这一枚 `tf_` 键本次请求到底给没给值」——判据逐字对齐 java
/// `AddSignSupport.validateSubmission` 的 `nextOp != null && !String.valueOf(nextOp).trim().isEmpty()`：
/// 键缺失 / JSON null ⇒ 没给；字符串档裁空白后为空 ⇒ 没给；其余标量（含空数组 `[]`、`false`）
/// ⇒ 按"给了"算（java 那侧 `String.valueOf` 给出 `[]`/`false`，非空白，同样拦）。
fn tf_arg_present(args : @json.FlowData, key : String) -> Bool {
  match args.get(key) {
    None => false
    Some(Json::Null) => false
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => !s.trim(chars="\t\r\n").is_empty()
        None => true
      }
  }
}

///|
/// 写入口四判据（互斥／开关未开／加给自己／超上限），**必须排在任何状态变更之前**。
///
/// 互斥这条的理由不是语义矛盾（一个管本节点再来一轮、一个管流出后交给谁，逻辑可共存），
/// 而是**参数生命周期**：`tf_*` 只活在当次请求与已完成任务行变量里，加签使令牌停留本节点、
/// 流出发生在后续请求，届时先传的 `tf_nextNodeOperator` 已不可读 ⇒ 同传时它是死参数，
/// 静默择一＝用户选的"下一节点处理人"无声消失，报错是把它变响话。
pub fn validate_add_sign_submission(
  model : @parser.ProcessModel,
  task : @model.ProcessTask,
  args : @json.FlowData,
  operator : String
) -> Unit raise @error.JeeflowError {
  let ops = add_sign_operators_of(args)
  if !ops.is_empty() && tf_arg_present(args, next_node_operator_key) {
    raise @error.Business(add_sign_mutex_msg)
  }
  if ops.is_empty() {
    // 没点人＝正常流转档，其余判据不涉及（也不要求节点开开关）
    return
  }
  let node_opt : @parser.NodeModel? = match model.get_node(task.task_name) {
    Some(n) =>
      if n.node_type is @parser.Task {
        Some(n)
      } else {
        None
      }
    None => None
  }
  let allow = match node_opt {
    Some(n) => n.allow_add_sign()
    None => false
  }
  if !allow {
    raise @error.Business(add_sign_switch_off_msg(task.task_name))
  }
  let node = match node_opt {
    Some(n) => n
    None => raise @error.Business(add_sign_switch_off_msg(task.task_name))
  }
  // 加给自己：操作人取归一后的单值档（`@model.normalize_actor`，与参与者写侧同一枚尺子），
  // 逐个比对归一后的加签人——" userA " 与 "userA" 是同一个人。
  let me = @model.normalize_actor(operator)
  for a in ops {
    match me {
      Some(m) =>
        if m == a {
          raise @error.Business(add_sign_self_msg)
        }
      None => ()
    }
  }
  let max = node.add_sign_max_rounds()
  if max > 0L && add_sign_round_of(task, node.id) + 1L > max {
    raise @error.Business(add_sign_max_rounds_msg(node.id, max))
  }
}

///|
/// 本节点是否还有未完成待办（刚办结那一条此刻已是 FINISHED ⇒ 不计入）。
/// 读聚合根里的行：`load_exec_for_task` 已把仓储真相回填进 `instance.tasks`。
pub fn has_doing_on_node(instance : @model.ProcessInstance, node : String) -> Bool {
  let mut found = false
  for t in instance.tasks {
    if t.task_name == node && t.is_doing() {
      found = true
    }
  }
  found
}

///|
/// 读轮次号：首圈（普通建单产生的那条）没有该键 ⇒ 0。
pub fn add_sign_round_of(task : @model.ProcessTask, node : String) -> Int64 {
  task.variables.get_i64_or(add_sign_round_key(node), 0L)
}

///|
/// 读账本（测试、审批记录投影与集成层都用这一枚，不各自 `get` 一份）
pub fn add_sign_history_of(task : @model.ProcessTask) -> Array[Json] {
  let out : Array[Json] = []
  match task.variables.get(add_sign_history_key) {
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
/// 账本追加一条（**只追加不覆盖**）：五键固定 camelCase、`time` 一律
/// `yyyy-MM-dd HH:mm:ss`（`@model.current_time_str()`，spec §2.4 全生态格式，账本跨栈同形）。
/// 形状照 `tf_transferHistory` 那一族（门面 `processTask/transfer` 腿）。
pub fn append_add_sign_history_vars(
  task : @model.ProcessTask, operator : String, to_actors : Array[String], round : Int64
) -> Unit {
  let arr = @json.empty_array()
  for it in add_sign_history_of(task) {
    @json.arr_push(arr, it)
  }
  @json.arr_push(
    arr,
    @json.object_of([
      ("round", @json.number_of(round)),
      ("fromActor", @json.string_of(operator)),
      ("toActors", @json.array_of(to_actors.map(fn(a) { @json.string_of(a) }))),
      ("time", @json.string_of(@model.current_time_str())),
      ("operator", @json.string_of(operator)),
    ]),
  )
  task.variables.insert(add_sign_history_key, arr)
}

///|
/// 加签腿建单：一个加签人一行任务（多选＝同圈多行），全部走 `ProcessInstance::create_task`
/// —— 那条腿内部已按节点 `expireTime` 表达式同尺写 `expire_time`（`apply_node_expire_time`
/// 与既有四处写点同一把尺子），故本特性**不新增**到期时间写点。
/// ⚠️ 建行一律进 `exec.new_tasks`：id 分配、`task_parent_id`/`isFirstTaskNode` 建单不变量、
///   委托并入、`save_task` + `add_task_actor` 落库、`PROCESS_TASK_START`（码 3）事件
///   全在 `persist_tasks` 那一处收口（规范 04 建单规则 6/7：走既有腿，不新造时序）。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::create_add_sign_tasks(
  self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel
) -> Unit raise @error.JeeflowError {
  let instance = exec.process_instance
  let node_name = node.id
  // 血缘 parent＝刚办结那一条（加签链串成链）。加签腿只在"办掉一条既有任务"时进入，
  // 此刻聚合里必有那一条；读不到＝调用路径接错，显式报错，不建一条无血缘的孤儿待办。
  let completed = match exec.process_task {
    Some(t) => t
    None => raise @error.Internal("后加签缺少当前任务，无法建立血缘")
  }
  let round = add_sign_round_of(completed, node_name) + 1L
  let new_tasks : Array[@model.ProcessTask] = []
  for actor in exec.add_sign_operators {
    let next = instance.create_task(
      node_name,
      node.display_name,
      [actor],
      exec.operator,
      @model.TaskType::from_code(node.task_type()),
      // 加签任务是**普通任务**，不是会签（规范 04 建单规则 2）：票不共享、不进会签池
      @model.PerformType::Normal,
      node.form_key(),
      Some(completed.task_id),
    )
    next.variables.insert_i64(add_sign_round_key(node_name), round)
    new_tasks.push(next)
  }
  apply_node_expire_time(exec, node, new_tasks)
  // 分支归属与每一次普通建单同一条腿：并行范围内的加签任务必须继承父任务归属，
  // 否则汇合判据读不到这一支（父任务＝刚办结那条，与 attach_branch_scopes 的取数一致）。
  attach_branch_scopes(exec, node, new_tasks)
  for t in new_tasks {
    exec.new_tasks.push(t)
  }
  self.append_add_sign_history(exec, completed.task_id, exec.add_sign_operators, round)
}

///|
/// 账本落回**刚办结那一条**任务行并写库。
/// ⚠️ 不能往 `exec.process_task` 上写：那是 `load_exec_for_task` 里办结**之前**的克隆，
///   写它既改不到聚合根、也到不了仓储（本栈仓储读侧克隆、写侧覆盖）。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::append_add_sign_history(
  self : Engine[R, E],
  exec : @exec.Execution,
  task_id : Int64,
  to_actors : Array[String],
  round : Int64
) -> Unit raise @error.JeeflowError {
  let operator = exec.operator
  for t in exec.process_instance.tasks {
    if t.task_id == task_id {
      append_add_sign_history_vars(t, operator, to_actors, round)
      (self.repo()).update_task(t)
    }
  }
}

///|
/// 推进闸裁决（merged 判据，**顺序不可反**，规范 04）：
/// · 本次点了人 ⇒ 同节点建单 + 令牌停留；
/// · 没点但本节点还有未完成待办（多选时同圈的兄弟待办）⇒ 停留；
/// · 两者皆否 ⇒ 放行出边。
/// 返回 true＝停留本节点（调用方跳过下钻）。停止条件即本判据本身，**不设第二判据源**：
/// 被加签人觉得够了、直接同意不点人，令牌即流出本节点。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::add_sign_gate(
  self : Engine[R, E], exec : @exec.Execution, node : @parser.NodeModel
) -> Bool raise @error.JeeflowError {
  if exec.add_sign_operators.is_empty() {
    has_doing_on_node(exec.process_instance, node.id)
  } else {
    self.create_add_sign_tasks(exec, node)
    true
  }
}

///|
/// 拒绝／退回发起人：废弃本节点未完成的加签任务，不留孤儿待办（规范 04 · 语义边界）。
/// 开关守卫＝`allowAddSign` **或** `dynamicCountersign`（issues/247 扩面，逐字照 java
/// `AddSignSupport.abandonDoingOnNode` 的新守卫——征询成员行同属本节点 DOING，
/// 实例撤回/退回路径一并清场）。会签节点的兄弟任务由既有会签腿管，不在此扩面。
/// 返回实际废弃的行数。
/// ⚠️ 与 `abandon_countersign_remaining` 同形：改聚合行之后必须逐条 `update_task` 落库。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::abandon_add_sign_remaining(
  self : Engine[R, E], exec : @exec.Execution, node_id : String
) -> Int raise @error.JeeflowError {
  if node_id.is_empty() {
    return 0
  }
  let allow = match exec.process_model.get_node(node_id) {
    Some(n) =>
      if n.node_type is @parser.Task {
        n.allow_add_sign() || n.dynamic_countersign()
      } else {
        false
      }
    None => false
  }
  if !allow {
    return 0
  }
  let mut abandoned = 0
  for t in exec.process_instance.tasks {
    if t.task_name == node_id && t.task_state == @model.TaskState::Doing.code() {
      try {
        t.abandon()
      } catch {
        _ => ()
      }
      (self.repo()).update_task(t)
      abandoned = abandoned + 1
    }
  }
  abandoned
}
