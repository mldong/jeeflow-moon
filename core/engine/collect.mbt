// 动态会签（征询模式 dynamicCountersign，issues/247）—— 判据、账本、投影 ＋ 三条腿
//
// 基准（逐条对照，冲突以 java 为准）：
//   · java `core/CollectSupport.java`（memberRows/isMemberRow/countMembers/pendingMembers/
//     buildProjection/lastRound/appendCollectHistory/appendRevokeHistory ＋ 五档逐字 msg）
//   · java `facade/JeeflowFacade` 的 `tryDynamicCountersign`（发起分流）／`gateDynamicCountersign`
//     （闸门）／`taskRevokeCountersign`（撤回）三处，均排在聚合变更之前
//   · java `model/TaskModel.exec` 第三档（征询档复用后加签推进闸，落点在 `engine_ops.mbt` 10a）
//   · java `enums/FlowConst` 的 `tf_addSignReason`／`addSignRound_{node}`／`tf_addSignHistory`
//     （簿记一律写任务行 variable，**不加 DDL、不新增节点类型、不新增 submitType 档**）
//   · spec 02 §4.4／spec 04「动态会签（征询模式）」／spec 06 §2.7 ＋ §processTask/revokeDynamicCountersign
//
// 本栈落位与 java 的一处形状差异（照本仓 `add_sign.mbt` 的先例，语义逐字对齐）：
//   java 把三条腿放在门面（直调 `repository.saveTask`），本栈的门面不碰 id 生成与建单收口，
//   故落点在引擎包（`Engine` 上的三个 async 方法），门面只负责参数归一＋信封＋调用位序
//   （分流→闸门→submitType 分发，逐字照 java `execute` 的那三段）。建单走本栈唯一收口
//   `persist_tasks`：id 分配、`task_parent_id`/`isFirstTaskNode` 不变量、委托并入、
//   `save_task` + `add_task_actor`、码 3 事件一处全覆盖（python/rust 两条已落地腿同判据）。
//
// 三条承重判据（java 测试照出来的，本栈同形，改动前先读）：
//   1. **成员行识别＝parent 且同节点同名**（`collect_member_rows`）：主办办结推进后，下一节点行的
//      parent 同样是主办行 id（建单不变量），只认 parent 会把下游行误当成员——撤回腿会误废弃它们。
//   2. **闸门收齐＝无 DOING 成员行**（`collect_pending_members`），计数与投影一律**跳过 99（ABANDON）**
//      （`collect_count_members`／`collect_build_projection`）——撤回清场的行不再算在册人数。
//   3. **撤回的参与人判断按名册**（`actor_ids`），不走只认 DOING 行的 `ProcessTask::is_allowed`：
//      主办行办结后会把合法撤回判成无权（待答判据随后兜底）。

///|
/// 逐字判据文案（闸门·未收齐；spec 04／06 钉死，`{已提交}/{总数}` 两枚计数＝java `MSG_PENDING`
/// 的 `%d/%d` 次序：先 submitted 后 total）
pub fn collect_pending_msg(node : String, submitted : Int, total : Int) -> String {
  "节点[\{node}]动态会签意见未收齐（已提交 \{submitted}/\{total}），不能办理"
}

///|
/// 逐字：重复拉仍在待答的那位（＝java `MSG_DUPLICATE`，两枚占位：人、节点）
pub fn collect_duplicate_msg(actor : String, node : String) -> String {
  "操作人[\{actor}]已在节点[\{node}]的动态会签中"
}

///|
/// 逐字：成员行携带拉人参数（拉人只限主办行）
pub let collect_member_pull_msg : String = "动态会签成员任务不能发起加签"

///|
/// 逐字：无待答成员行（收齐后再撤＝java `MSG_NO_PENDING`；节点未开开关同档，基准也并成一条）
pub fn collect_no_pending_msg(node : String) -> String {
  "节点[\{node}]没有进行中的动态会签"
}

///|
/// 逐字：撤回动态会签的非参与人
pub let collect_no_permission_revoke_msg : String = "无权限撤回该动态会签"

///|
/// 逐字：主办行读不到＝java `taskRevokeCountersign` 那句 `error("任务不存在")`
/// （⚠️ 不借 `@error.TaskNotFound`——那支 message 带 id 尾巴，与基准文案不同形）
pub let collect_task_missing_msg : String = "任务不存在"

///|
/// 成员行＝`task_parent_id` 指向主办行**且同节点同名**的行（成员不能再拉人 ⇒ 无更深层级）。
/// 同名过滤不可省（承重判据一，理由见文件头）。纯读、不改任何行。
pub fn collect_member_rows(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Array[@model.ProcessTask] {
  let out : Array[@model.ProcessTask] = []
  for t in tasks {
    match t.parent_task_id {
      Some(p) =>
        if p == host.task_id && t.task_name == host.task_name {
          out.push(t)
        }
      None => ()
    }
  }
  out
}

///|
/// 成员行判定：parent 指向**同节点同名**的那一行（issues/247 §3.3；成员行禁带拉人参数的判据）。
/// parent 为空/0 ⇒ 一定不是成员行（java `parentTaskId == null || == 0L` 同判据）。
pub fn collect_is_member_row(
  tasks : Array[@model.ProcessTask], row : @model.ProcessTask
) -> Bool {
  let pid = match row.parent_task_id {
    None => return false
    Some(p) => p
  }
  if pid == 0L {
    return false
  }
  let mut found = false
  for t in tasks {
    if t.task_id == pid && t.task_name == row.task_name {
      found = true
    }
  }
  found
}

///|
/// 闸门原料 `(总数, 已提交)`：已废弃(99) 行（撤回腿清场的）不算在册；空集＝本行不是征询主办行。
/// ＝java `CollectSupport.countMembers` 那枚 `int[]{total, submitted}`。
pub fn collect_count_members(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> (Int, Int) {
  let mut total = 0
  let mut submitted = 0
  for t in collect_member_rows(tasks, host) {
    if t.task_state == @model.TaskState::Abandon.code() {
      continue
    }
    total = total + 1
    if t.is_finished() {
      submitted = submitted + 1
    }
  }
  (total, submitted)
}

///|
/// 未答成员行（DOING）＝闸门判据（还有 ⇒ 挡）与撤回接口的废弃集合（承重判据二）。
pub fn collect_pending_members(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Array[@model.ProcessTask] {
  let out : Array[@model.ProcessTask] = []
  for t in collect_member_rows(tasks, host) {
    if t.is_doing() {
      out.push(t)
    }
  }
  out
}

///|
/// 主办行当前轮次＝账本条数里最后一条的 `round`（每次拉人追加一条＝轮次推进；撤回也追加，
/// 但带 `revoked` 标记且**不消耗**轮次——java `lastRound` 只读最后一条的 round 值，
/// 撤回条沿用同一 round ⇒ 再拉一轮时 `+1` 照常）。读不到／非数字 ⇒ 0。
pub fn collect_last_round(host : @model.ProcessTask) -> Int64 {
  let history = add_sign_history_of(host)
  if history.is_empty() {
    return 0L
  }
  let last = history[history.length() - 1]
  match @json.get(last, "round") {
    Some(v) =>
      match @json.as_i64(v) {
        Some(n) => n
        None => 0L
      }
    None => 0L
  }
}

///|
/// 投影（spec 06 §2.7）：征询主办行 `ext.dynamicCountersign`＝
/// `{active, round, total, submitted, actors:[{actor, taskId, state}]}`——从 `task_parent_id`
/// 现算、不落新存储；无成员行 ⇒ None（不写这一格，前端据此不置灰）。
/// 99（撤回清场）行不进在册计数、也不进 actors 投影（＝java `buildProjection` 的 continue）。
pub fn collect_build_projection(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Json? {
  let members = collect_member_rows(tasks, host)
  if members.is_empty() {
    return None
  }
  let mut total = 0
  let mut submitted = 0
  let actor_rows : Array[Json] = []
  for m in members {
    if m.task_state == @model.TaskState::Abandon.code() {
      continue
    }
    total = total + 1
    if m.is_finished() {
      submitted = submitted + 1
    }
    let actor = if m.actor_ids.is_empty() {
      @json.null_json()
    } else {
      @json.string_of(m.actor_ids[0])
    }
    actor_rows.push(
      @json.object_of([
        ("actor", actor),
        ("taskId", @json.number_of(m.task_id)),
        ("state", @json.number_of(m.task_state.to_int64())),
      ]),
    )
  }
  Some(
    @json.object_of([
      ("active", @json.bool_of(submitted < total)),
      ("round", @json.number_of(collect_last_round(host))),
      ("total", @json.number_of(total.to_int64())),
      ("submitted", @json.number_of(submitted.to_int64())),
      ("actors", @json.array_of(actor_rows)),
    ]),
  )
}

///|
/// 账本条目公共四键（＝java `CollectSupport.baseEntry` 的插入序：round/fromActor/toActors/time/operator）
fn collect_base_entry(
  operator : String, to_actors : Array[String], round : Int64
) -> Json {
  @json.object_of([
    ("round", @json.number_of(round)),
    ("fromActor", @json.string_of(operator)),
    ("toActors", @json.array_of(to_actors.map(fn(a) { @json.string_of(a) }))),
    ("time", @json.string_of(@model.current_time_str())),
    ("operator", @json.string_of(operator)),
  ])
}

///|
/// 账本追加一条（**只追加不覆盖**），落**主办行**变量：键与纪律完全复用后加签那本账
/// （`tf_addSignHistory`，形状照 `tf_transferHistory` 族）。征询模式下主办行**不办结**，
/// 主办行变量里的这本账靠"办结时 `full_args → 任务变量` 的合并序"活到办结之后
/// （＝java `finish(operator, args)` 里 `variables.putAll(args)` 那条不变量）。
/// 键序＝`round, fromActor, toActors, time, operator[, reason]`（java `LinkedHashMap` 的插入序）。
pub fn append_collect_history_vars(
  host : @model.ProcessTask, operator : String, to_actors : Array[String], round : Int64, reason : String?
) -> Unit {
  let entry = collect_base_entry(operator, to_actors, round)
  // `obj_set` 是原地写（本仓 @json 的实测引用语义）；entry 由 collect_base_entry 现造，
  // 不与其他行共享 ⇒ 不存在"改一条盖一片"的串写。
  match reason {
    Some(r) =>
      if !r.is_empty() {
        @json.obj_set(entry, "reason", @json.string_of(r))
      }
    None => ()
  }
  append_to_add_sign_history(host, entry)
}

///|
/// 撤回会签账本追加：`revoked=true` 标记本条是撤回（未答废弃），`toActors`＝被撤的人。
/// round 沿用当前轮（撤回不消耗轮次）。键序 `…, revoked[, reason]` 同 java。
pub fn append_revoke_history_vars(
  host : @model.ProcessTask, operator : String, revoked_actors : Array[String], round : Int64, reason : String?
) -> Unit {
  let entry = collect_base_entry(operator, revoked_actors, round)
  @json.obj_set(entry, "revoked", @json.bool_of(true))
  match reason {
    Some(r) =>
      if !r.is_empty() {
        @json.obj_set(entry, "reason", @json.string_of(r))
      }
    None => ()
  }
  append_to_add_sign_history(host, entry)
}

///|
/// 把一条账本追加进 `tf_addSignHistory`（读旧→建新→盖回，避免在 Json 值上原地改）
fn append_to_add_sign_history(host : @model.ProcessTask, entry : Json) -> Unit {
  let arr = @json.empty_array()
  for it in add_sign_history_of(host) {
    @json.arr_push(arr, it)
  }
  @json.arr_push(arr, entry)
  host.variables.insert(add_sign_history_key, arr)
}

///|
/// 发起分流（spec 04 · 动态会签「提交分流」＝java `tryDynamicCountersign`）：
/// 征询节点带 `tf_addSignOperators` 的提交＝按人建成员行、**不办结主办行**，返回响应 marker
/// `{dynamicCountersign:{round,total,submitted}}`；**非征询提交返回 None** 走普通流转。
///
/// 返回 None 的六档（＝java 前六道 `return null`）：主办行读不到/不在 DOING、本次没点人、
/// 实例读不到、定义读不到、节点不是征询档、**当前行是成员行**（拉人只限主办行——放行给闸门腿
/// 报它自己的逐字文案 `collect_member_pull_msg`，不在这里发明第二种错）。
///
/// 判据位序逐字照 java，全排在任何状态变更之前，报错即零写入：
/// 互斥（与 `tf_nextNodeOperator` 同传＝死参数）→ 主办行参与人（`is_allowed`，此行本就 DOING）→
/// 轮次上限 → 逐人「加给自己」「重复拉待答中的人」。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::try_dynamic_countersign_async(
  self : Engine[R, E], task_id : Int64, operator : String, args : @json.FlowData
) -> Json? raise @error.JeeflowError {
  let host = match (self.repo()).find_task_by_id(task_id) {
    Some(t) =>
      if t.is_doing() {
        t
      } else {
        return None
      }
    None => return None
  }
  let ops = add_sign_operators_of(args)
  if ops.is_empty() {
    return None
  }
  let instance = match (self.repo()).find_instance_by_id(host.process_instance_id) {
    Some(i) => i
    None => return None
  }
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => return None
  }
  let model = @parser.parse_model(define_info.content)
  let node = match model.get_node(host.task_name) {
    Some(n) =>
      if n.node_type is @parser.Task && n.dynamic_countersign() {
        n
      } else {
        return None
      }
    None => return None
  }
  // 成员行不能冒充主办发起（拉人只限主办行）
  if collect_is_member_row(instance.tasks, host) {
    return None
  }
  // ── 以下全是判据：报错即零写入 ──
  if tf_arg_present(args, next_node_operator_key) {
    raise @error.Business(add_sign_mutex_msg)
  }
  if !host.is_allowed(operator) {
    raise @error.PermissionDenied("Operator \{operator} not allowed on task \{task_id}")
  }
  let round = collect_last_round(host) + 1L
  let max = node.add_sign_max_rounds()
  if max > 0L && round > max {
    raise @error.Business(add_sign_max_rounds_msg(node.id, max))
  }
  let reason = args.get_str(add_sign_reason_key)
  let existing = collect_member_rows(instance.tasks, host)
  // 「加给自己」两栈同判据：加签人已过 `normalize_actors`（trim＋折叠），操作人取归一后的单值档
  // ——与后加签写入口那一枚 `validate_add_sign_submission` 同一把尺子（" userA " 就是 userA）。
  let me = @model.normalize_actor(operator)
  for op in ops {
    match me {
      Some(m) =>
        if m == op {
          raise @error.Business(add_sign_self_msg)
        }
      None => ()
    }
    for m in existing {
      if m.is_doing() && m.actor_ids.contains(op) {
        raise @error.Business(collect_duplicate_msg(op, node.id))
      }
    }
  }
  // ── 判据全过：建成员行（同节点同名、parent＝主办行、轮次/原因两戳 ＋ 分支归属继承）──
  let new_tasks : Array[@model.ProcessTask] = []
  for op in ops {
    let crow = instance.create_task(
      node.id,
      node.display_name,
      [op],
      operator,
      @model.TaskType::from_code(node.task_type()),
      // 成员行是**普通任务**（照后加签建单腿，规范 04 建单规则 2）：票不共享、不进会签池，
      // 提交类型仅作记录、无表决语义（v1 边界）。征询节点禁配会签已由解析期拦下。
      @model.PerformType::Normal,
      node.form_key(),
      Some(host.task_id),
    )
    crow.variables.insert_i64(add_sign_round_key(node.id), round)
    match reason {
      Some(r) =>
        if !r.is_empty() {
          crow.variables.insert_str(add_sign_reason_key, r)
        }
      None => ()
    }
    new_tasks.push(crow)
  }
  let exec = @exec.Execution::make(instance, model, define_info, operator, @json.FlowData::new())
  // 分支归属的父任务＝主办行（＝java `buildScopes(host, model, node, member.taskId)`）
  exec.process_task = Some(host.clone())
  apply_node_expire_time(exec, node, new_tasks)
  attach_branch_scopes(exec, node, new_tasks)
  for t in new_tasks {
    exec.new_tasks.push(t)
  }
  // 落库：成员行走建单唯一收口（save_task ＋ 参与者 ＋ 委托并入 ＋ isFirstTaskNode ＋ 码 3）
  self.persist_tasks(exec)
  // 主办行：账本追加一条（含 reason）＋ 轮次盖戳，**状态一字不动**（征询档主办不办结）。
  // ⚠️ 写的是 `find_task_by_id` 那份副本再 `update_task` 落回（＝java `appendCollectHistory(host)`
  //   → `updateTask(host)`）；聚合里那一格是另一份拷贝，不跟着落库。
  append_collect_history_vars(host, operator, ops, round, reason)
  host.variables.insert_i64(add_sign_round_key(node.id), round)
  (self.repo()).update_task(host)
  let counts = collect_count_members(instance.tasks, host)
  Some(
    @json.object_of([
      (
        "dynamicCountersign",
        @json.object_of([
          ("round", @json.number_of(round)),
          ("total", @json.number_of(counts.0.to_int64())),
          ("submitted", @json.number_of(counts.1.to_int64())),
        ]),
      ),
    ]),
  )
}

///|
/// 闸门（spec 04 · 动态会签＝java `gateDynamicCountersign`）：征询节点上——
/// · **主办行未收齐成员意见 ⇒ 逐字文案报错**，挡**全部** submitType（含驳回），
///   唯一出口＝`processTask/revokeDynamicCountersign`（owner 拍「全部置灰＋撤回接口」）；
/// · 成员行携带拉人参数 ⇒ 逐字文案报错（拉人只限主办行）；成员行自己提交照常放行
///   （意见落各自行的 `tf_approvalComment`，物理隔离由"一行任务一条意见"既有不变量保证）；
/// · 非征询节点／读不到实例或定义 ⇒ 原样放行，不抢既有档、不发明第二种文案。
/// 纯读判据，**排在任何状态变更之前**：报错即零写入。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::gate_dynamic_countersign_async(
  self : Engine[R, E], task_id : Int64, args : @json.FlowData
) -> Unit raise @error.JeeflowError {
  let task = match (self.repo()).find_task_by_id(task_id) {
    Some(t) =>
      if t.is_doing() {
        t
      } else {
        return
      }
    None => return
  }
  let instance = match (self.repo()).find_instance_by_id(task.process_instance_id) {
    Some(i) => i
    None => return
  }
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => return
  }
  let model = @parser.parse_model(define_info.content)
  let enabled = match model.get_node(task.task_name) {
    Some(n) => n.node_type is @parser.Task && n.dynamic_countersign()
    None => false
  }
  if !enabled {
    return
  }
  if collect_is_member_row(instance.tasks, task) {
    if !add_sign_operators_of(args).is_empty() {
      raise @error.Business(collect_member_pull_msg)
    }
    return
  }
  // 收齐判据＝还有无 DOING 成员行（宽口径计数跳过撤回清场的 99 行）
  if !collect_pending_members(instance.tasks, task).is_empty() {
    let counts = collect_count_members(instance.tasks, task)
    raise @error.Business(collect_pending_msg(task.task_name, counts.1, counts.0))
  }
}

///|
/// 撤回动态会签（spec 06 §processTask/revokeDynamicCountersign＝java `taskRevokeCountersign`）：
/// 废弃主办行下**全部未答**成员行，账本追加撤回条目（round、被撤人、reason 选填、时间、操作人）；
/// **已交意见行原样保留**（审计凭证不动）；闸门自然恢复（判据＝还有无 DOING 成员行）；轮次不消耗。
/// 独立 action，不进 execute 参数空间（撤回不是办结动作）。
///
/// 判据位序逐字照 java：任务存在 → **参与人按名册**（承重判据三，不能用 `is_allowed`）→
/// 实例存在 → 节点是征询档 → 有待答成员行。全部排在写之前，报错即零写入。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::revoke_dynamic_countersign_async(
  self : Engine[R, E], task_id : Int64, operator : String, reason : String?
) -> Json raise @error.JeeflowError {
  let host = match (self.repo()).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.Business(collect_task_missing_msg)
  }
  let lower = operator.to_lower()
  let privileged = lower == "flow.auto" || lower == "flow.admin"
  if !privileged && !(host.actor_ids.contains(operator)) {
    raise @error.Business(collect_no_permission_revoke_msg)
  }
  let instance = match (self.repo()).find_instance_by_id(host.process_instance_id) {
    Some(i) => i
    None => raise @error.Business(recall_instance_missing_msg)
  }
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.DefineNotFound(instance.define_id)
  }
  let model = @parser.parse_model(define_info.content)
  let enabled = match model.get_node(host.task_name) {
    Some(n) => n.node_type is @parser.Task && n.dynamic_countersign()
    None => false
  }
  if !enabled {
    raise @error.Business(collect_no_pending_msg(host.task_name))
  }
  let pending = collect_pending_members(instance.tasks, host)
  if pending.is_empty() {
    raise @error.Business(collect_no_pending_msg(host.task_name))
  }
  // ── 判据全过，以下才允许写：逐行废弃（复用既有废弃腿 `ProcessTask::abandon`）＋逐条落库 ──
  // 聚合行与仓储行是两份拷贝，两处都要落（同 `recall_task_async` 写 1 那一刀）。
  let ids : Array[Int64] = []
  for m in pending {
    ids.push(m.task_id)
  }
  // 被撤的人：成员行一人一行（建单即 `[op]`）。账本那份收 String（空名册行在这一档留空串，
  // 与后加签账本的 `toActors` 同尺），响应那份收 Json ⇒ 空名册出 `null`
  // （＝java `m.getActorIds()==null||isEmpty ? null : get(0)` 那一臂，本栈 Array[String] 不装 null）。
  let revoked_actors : Array[String] = []
  let revoked_json : Array[Json] = []
  for t in instance.tasks {
    if ids.contains(t.task_id) {
      if t.is_doing() {
        try {
          t.abandon()
        } catch {
          _ => ()
        }
      }
      if t.actor_ids.is_empty() {
        revoked_actors.push("")
        revoked_json.push(@json.null_json())
      } else {
        revoked_actors.push(t.actor_ids[0])
        revoked_json.push(@json.string_of(t.actor_ids[0]))
      }
      (self.repo()).update_task(t)
    }
  }
  // 主办行：账本追加撤回条目（revoked=true）＋落库；状态一字不动
  append_revoke_history_vars(host, operator, revoked_actors, collect_last_round(host), reason)
  (self.repo()).update_task(host)
  @json.object_of([
    ("revoked", @json.number_of(revoked_json.length().to_int64())),
    ("actors", @json.array_of(revoked_json)),
  ])
}
