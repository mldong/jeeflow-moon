// 动态协办（aidant，issues/253）—— 判据、账本、投影 ＋ 派生/推进闸/等待闸/清场四条腿
//
// 基准（逐条对照，冲突以 java 为准）：
//   · java `core/AidantSupport.java`（isAidantRow/aidantRows/countAidant/pendingAidant/waitOf/
//     gateWait/abandonPendingOnNode/buildProjection/lastRound/appendAidantHistory/
//     appendAbandonHistory ＋ 协办六行逐字 msg）
//   · java `core/JeeflowEngineImpl.aidantTask / completeAidantWithoutDrive`（派生判据位序、
//     四入口推进闸、等待闸排在 completeTask 之前、离开节点清场）
//   · java `model/TaskModel.exec` 的 abandonAidantOnLeave（只在真要离开本节点时清场）
//   · java `handler/impl/CountersignHandler`（合并判据显式排除 task_type=1；清场先协办腿后会签腿）
//   · spec 04「动态协办（aidant）」／spec 06 §2.7（tf_aidantHistory／tf_aidantReason／
//     tf_aidantWait ＋ 投影 ext.aidant）＋ §processTask/aidant（协办六行逐字失败文案）
//
// 本栈落位与 java 的形状差异（照本仓 `collect.mbt`／`recall.mbt` 的先例，语义逐字对齐）：
//   ① java 把清场放在 domain（TaskModel/CountersignHandler 直改聚合），本栈聚合根不碰仓储，
//      清场落引擎 async 方法（改聚合行＋逐条 update_task＋主办行账本），调用点与 java 同位。
//   ② 派生建单走本栈唯一收口 `persist_tasks`：id 分配、task_parent_id/isFirstTaskNode 不变量、
//      委托并入、save_task + add_task_actor、码 3 事件一处全覆盖（不新增事件码、不新增 submitType 档）。
//   ③ 账本/开关写 `find_task_by_id` 那份副本再 `update_task` 落回（＝collect.mbt 同一形状；
//      本腿不调 update_instance，不存在聚合旧副本级联抹账本的问题）。
//
// **与征询（collect.mbt）的分辨判据＝task_type**：两族子行都是 parent 指向主办行＋同节点同名，
// 协办行 task_type=1（Assistant）、征询成员行 task_type=0。等待闸只数协办行、征询收齐闸只数
// 成员行，各数各的（spec 04「与征询允许同节点并存」）。
//
// **无节点开关**：协办档只由运行期 `processTask/aidant` 派生，节点级 taskType=1 解析期禁配
// （issues/252，见 @parser）。

///|
/// 协议键：协办追加式账本（落**主办行**变量，只追加不覆盖）＝java `FlowConst.AIDANT_HISTORY`
pub let aidant_history_key : String = "tf_aidantHistory"

///|
/// 协议键：派生原因（选填）盖每条协办行（单行出证自足）；**不占 tf_approvalComment**
/// ＝java `FlowConst.AIDANT_REASON`
pub let aidant_reason_key : String = "tf_aidantReason"

///|
/// 协议键：等待闸开关——派生时盖在**主办行**变量上，缺省 false＝不等。
/// `tf_` 前缀使实例合并自动剥键（不传播）；投影 ext.aidant.wait 同源。＝java `FlowConst.AIDANT_WAIT`
pub let aidant_wait_key : String = "tf_aidantWait"

///|
/// 逐字判据文案（跨栈统一；spec 06 失败文案表「协办六行」）。本栈 JeeflowError 只有
/// Business 档的 message 原样对外 ⇒ 六档全走 Business，出口 code=99999999 ＋ 这句原文。
pub let aidant_no_actors_msg : String = "actorIds 必填"

///|
pub let aidant_no_permission_msg : String = "无权限派生协办任务"

///|
pub let aidant_not_doing_msg : String = "任务非进行中，不可派生协办"

///|
pub let aidant_duplicate_msg : String = "该人已有未办结的协办任务"

///|
pub let aidant_no_recursion_msg : String = "协办任务不能再派生协办"

///|
/// 逐字：主办行读不到（＝java `MSG_TASK_NOT_FOUND`；⚠️ 不借 @error.TaskNotFound——那支带 id 尾巴）
pub let aidant_task_missing_msg : String = "任务不存在"

///|
/// 等待闸未齐逐字文案（`{已办结}/{总数}` 两枚计数＝java `MSG_WAIT_PENDING` 的 `%d/%d` 次序：
/// 先 submitted 后 total；计数跳过 99 行）
pub fn aidant_wait_pending_msg(node : String, submitted : Int, total : Int) -> String {
  "节点[\{node}]协办未办结（已办结 \{submitted}/\{total}），不能办理"
}

///|
/// 协办行判定＝task_type=1（Assistant）。这是两族子行唯一的分辨判据（＝java `isAidantRow`）。
pub fn aidant_is_row(t : @model.ProcessTask) -> Bool {
  t.task_type == @model.TaskType::Assistant.code()
}

///|
/// 协办行＝parent 指向主办行**且同节点同名且 task_type=1** 的行（＝java `aidantRows`）。
/// 同名过滤不可省（照 collect_member_rows 的理由）：主办办结推进后，下一节点行的 parent
/// 同样是主办行 id（建单不变量），只认 parent 会把下游行误当协办行。task_type 过滤同样不可省：
/// 征询成员行也满足 parent＋同名，混进来会让等待闸把"意见未收齐"误报成"协办未办结"。
pub fn aidant_rows(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Array[@model.ProcessTask] {
  let out : Array[@model.ProcessTask] = []
  for t in tasks {
    if aidant_is_row(t) {
      match t.parent_task_id {
        Some(p) =>
          if p == host.task_id && t.task_name == host.task_name {
            out.push(t)
          }
        None => ()
      }
    }
  }
  out
}

///|
/// 等待闸原料 `(在册总数, 已办结数)`：已废弃(99) 行（离开节点清场的）不算在册
/// （＝java `countAidant` 那枚 `int[]{total, submitted}`）。
pub fn aidant_count(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> (Int, Int) {
  let mut total = 0
  let mut submitted = 0
  for t in aidant_rows(tasks, host) {
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
/// 未办结协办行（DOING）——等待闸的判据集合，也是离开节点时的清场集合（＝java `pendingAidant`）。
pub fn aidant_pending(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Array[@model.ProcessTask] {
  let out : Array[@model.ProcessTask] = []
  for t in aidant_rows(tasks, host) {
    if t.is_doing() {
      out.push(t)
    }
  }
  out
}

///|
/// 等待闸开关（waitCompletion）：派生时盖在主办行变量上，缺省 false＝不等。
/// 多轮派生时后一次的值生效（投影 ext.aidant.wait 同源）。非法值按缺省 false
/// （＝java `Boolean.parseBoolean(String.valueOf(v))`：bool 与 "true" 字符串两形都认，其余 false）。
pub fn aidant_wait_of(host : @model.ProcessTask) -> Bool {
  match host.variables.get(aidant_wait_key) {
    Some(v) =>
      match @json.as_bool(v) {
        Some(b) => b
        None =>
          match @json.as_str(v) {
            Some(s) => s.trim(chars=" \t\r\n").to_lower() == "true"
            None => false
          }
      }
    None => false
  }
}

///|
/// 等待闸（spec 04「推进闸与等待闸」＝java `gateWait`）：waitCompletion=true 时主办行办结前判
/// "不存在 DOING 协办行"，未齐 ⇒ 逐字文案报错、零写入。协办行自身不受本闸约束（它办结本来就
/// 不驱动流程）；waitCompletion=false（缺省）原样放行。**必须排在 complete_task 之前**
/// （本栈内存仓储无回滚，判据后置时"报错"那一次调用结束后主办待办已经消失）。
pub fn aidant_gate_wait(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Unit raise @error.JeeflowError {
  if aidant_is_row(host) || !aidant_wait_of(host) {
    return
  }
  if aidant_pending(tasks, host).is_empty() {
    return
  }
  let counts = aidant_count(tasks, host)
  raise @error.Business(aidant_wait_pending_msg(host.task_name, counts.1, counts.0))
}

///|
/// 投影（spec 06 §2.7＝java `buildProjection`）：主办行 ext.aidant＝
/// `{active, round, total, submitted, actors:[{actor, taskId, state}], wait}`；无协办行 ⇒ None。
/// 99（清场）行不进在册计数、也不进 actors 投影（与征询投影同口径）。
pub fn aidant_build_projection(
  tasks : Array[@model.ProcessTask], host : @model.ProcessTask
) -> Json? {
  let rows = aidant_rows(tasks, host)
  if rows.is_empty() {
    return None
  }
  let mut total = 0
  let mut submitted = 0
  let actor_rows : Array[Json] = []
  for t in rows {
    if t.task_state == @model.TaskState::Abandon.code() {
      continue
    }
    total = total + 1
    if t.is_finished() {
      submitted = submitted + 1
    }
    let actor = if t.actor_ids.is_empty() {
      @json.null_json()
    } else {
      @json.string_of(t.actor_ids[0])
    }
    actor_rows.push(
      @json.object_of([
        ("actor", actor),
        ("taskId", @json.number_of(t.task_id)),
        ("state", @json.number_of(t.task_state.to_int64())),
      ]),
    )
  }
  Some(
    @json.object_of([
      ("active", @json.bool_of(submitted < total)),
      ("round", @json.number_of(aidant_last_round(host))),
      ("total", @json.number_of(total.to_int64())),
      ("submitted", @json.number_of(submitted.to_int64())),
      ("actors", @json.array_of(actor_rows)),
      ("wait", @json.bool_of(aidant_wait_of(host))),
    ]),
  )
}

///|
/// 主办行当前轮次＝账本最后一条的 round（每次派生追加一条＝轮次推进；清场记账不消耗轮次）。
/// 读不到／非数字 ⇒ 0（＝java `lastRound`）。
pub fn aidant_last_round(host : @model.ProcessTask) -> Int64 {
  let history = aidant_history_of(host)
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
/// 读账本（测试与投影用）——形状照 `add_sign_history_of`／`recall_history_of`
pub fn aidant_history_of(task : @model.ProcessTask) -> Array[Json] {
  let out : Array[Json] = []
  match task.variables.get(aidant_history_key) {
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
/// 账本条目公共六键（＝java `AidantSupport.baseEntry` 的插入序：
/// round/fromActor/toActors/reason/time/operator；reason 空串兜底、time 一律 §2.4 字符串）。
/// 与征询五键条目的差别＝reason 进公共键序（java 两族 baseEntry 本就不同形）。
fn aidant_base_entry(
  operator : String, to_actors : Array[String], round : Int64, reason : String
) -> Json {
  @json.object_of([
    ("round", @json.number_of(round)),
    ("fromActor", @json.string_of(operator)),
    ("toActors", @json.array_of(to_actors.map(fn(a) { @json.string_of(a) }))),
    ("reason", @json.string_of(reason)),
    ("time", @json.string_of(@model.current_time_str())),
    ("operator", @json.string_of(operator)),
  ])
}

///|
/// 派生账本追加（只追加不覆盖），落**主办行**变量（＝java `appendAidantHistory`）。
/// 主办行在派生时不办结，complete_task 的逐键合并序保证账本活到主办办结之后
/// （与转办/征询账本同一条存活理由）。
pub fn append_aidant_history_vars(
  host : @model.ProcessTask, operator : String, to_actors : Array[String], round : Int64, reason : String?
) -> Unit {
  let r = match reason {
    Some(s) => s
    None => ""
  }
  append_aidant_entry(host, aidant_base_entry(operator, to_actors, round, r))
}

///|
/// 清场账本追加：abandoned=true 标记本条是"离开节点废弃"（形状照征询撤回条目的 revoked=true），
/// 六键原序不动，toActors＝被废弃的人（＝java `appendAbandonHistory`）。
pub fn append_abandon_history_vars(
  host : @model.ProcessTask, operator : String, abandoned_actors : Array[String], round : Int64
) -> Unit {
  let entry = aidant_base_entry(operator, abandoned_actors, round, "")
  @json.obj_set(entry, "abandoned", @json.bool_of(true))
  append_aidant_entry(host, entry)
}

///|
/// 把一条账本追加进 tf_aidantHistory（读旧→建新→盖回，避免在 Json 值上原地改）
fn append_aidant_entry(host : @model.ProcessTask, entry : Json) -> Unit {
  let arr = @json.empty_array()
  for it in aidant_history_of(host) {
    @json.arr_push(arr, it)
  }
  @json.arr_push(arr, entry)
  host.variables.insert(aidant_history_key, arr)
}

///|
/// 离开节点时清场未办结协办行（spec 04＝java `abandonPendingOnNode`）：waitCompletion=false 时
/// 主办可随时推进，未办结协办行随废弃腿清场、账本记废弃，不留孤儿待办。**只对协办行
/// （task_type=1）动手，且不要求节点开任何开关**——协办无节点开关，普通节点上的协办行同样要清。
/// 按 parent 分组（首见序＝java LinkedHashMap 的行序），废弃事实追加到各自主办行的账本上。
/// 幂等：已废弃(99)/已办结(20) 的行不再命中，重复调用不重复记账。
/// ⚠️ 与 abandon_add_sign_remaining 同形：改聚合行之后必须逐条 update_task 落库。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::abandon_aidant_on_node(
  self : Engine[R, E], instance : @model.ProcessInstance, node_name : String, operator : String
) -> Int raise @error.JeeflowError {
  let rows : Array[@model.ProcessTask] = []
  for t in instance.tasks {
    if t.task_name == node_name && t.is_doing() && aidant_is_row(t) {
      rows.push(t)
    }
  }
  if rows.is_empty() {
    return 0
  }
  // parent 首见序（＝java LinkedHashMap 锁定记账顺序＝行序）
  let parents : Array[Int64] = []
  for t in rows {
    let p = t.parent_task_id.unwrap_or(0L)
    if !parents.contains(p) {
      parents.push(p)
    }
  }
  let mut abandoned = 0
  for p in parents {
    let actors : Array[String] = []
    for t in rows {
      if t.parent_task_id.unwrap_or(0L) == p {
        try {
          t.abandon()
        } catch {
          _ => ()
        }
        (self.repo()).update_task(t)
        // 空名册行留空串（与征询撤回账本 toActors 同尺；java 那臂是 null，本栈 Array[String] 不装 null）
        actors.push(if t.actor_ids.is_empty() { "" } else { t.actor_ids[0] })
        abandoned = abandoned + 1
      }
    }
    for h in instance.tasks {
      if h.task_id == p {
        append_abandon_history_vars(h, operator, actors, aidant_last_round(h))
        (self.repo()).update_task(h)
      }
    }
  }
  abandoned
}

///|
/// 协办行办结的**推进闸**（spec 04＝java `completeAidantWithoutDrive`）：只完成任务行
/// （load_exec_for_task 内含 complete_task／update_task／fire 码 5/6），**不跑节点执行、
/// 不跑输出变迁**，返回空的新任务表。四条办理入口（execute／jump／reject／rollbackToOperator）
/// 同闸——协办行任何 submitType 都不得驱动流程。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::complete_aidant_without_drive(
  self : Engine[R, E], task_id : Int64, operator : String, args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let (_task, _instance, _define, _model, exec, _st) = self.load_exec_for_task(task_id, operator, args)
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  exec.new_tasks
}

///|
/// 动态协办派生（spec 04 · 动态协办＝java `JeeflowEngineImpl.aidantTask`）：主办把"这活"交给
/// 别人干——按人派生 task_type=1 协办子行，**主办行原样保留 DOING**，节点推进仍由主办行办结触发。
///
/// 判据全部排在任何状态变更之前（报错即零写入——与后加签/征询/撤回同一规矩），位序逐字照 java：
/// 任务存在 → 禁递归（协办行不能再派生）→ 主办行 DOING → actorIds 归一后非空 →
/// 名册鉴权（auto/admin 例外，以参与者表为判据）→ 实例存在 → 定义存在 → 节点是任务节点 →
/// 逐人去重（该人已有本主办行下未办结协办行）。
///
/// 落库顺序：协办行 persist_tasks（委托并入 → save_task 分配 id → add_task_actor → fire 码 3）
/// → 主办行盖 wait 开关＋账本＋审计列 update_task。建单形状照征询成员行腿（instance.create_task：
/// 同节点同名、parent＝主办行、expire_time 按节点表达式同尺重算），另落 task_type=1／
/// performType=NORMAL——节点上配的 performType 可能是会签，协办行一律普通参与（spec 04 派生规则 1）。
/// ⚠️ 严禁覆写任务 actor_id/operator 列（转办那条 ⚠️ 同尺）：进行中任务该列恒无值是家族不变量，
/// 派生协办不改主办行的办理人归属，审计由 update_user＋账本 operator 承载。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::aidant_task_async(
  self : Engine[R, E],
  task_id : Int64,
  actor_ids : Array[String],
  reason : String?,
  wait_completion : Bool,
  operator : String
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let host = match (self.repo()).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.Business(aidant_task_missing_msg)
  }
  // 禁递归：协办行携带派生参数 ⇒ 报错（spec 04 派生规则 4）
  if aidant_is_row(host) {
    raise @error.Business(aidant_no_recursion_msg)
  }
  if !host.is_doing() {
    raise @error.Business(aidant_not_doing_msg)
  }
  let actors = @model.normalize_actors(actor_ids)
  if actors.is_empty() {
    raise @error.Business(aidant_no_actors_msg)
  }
  let lower = operator.to_lower()
  let privileged = lower == "flow.auto" || lower == "flow.admin"
  // 以参与者表为判据（聚合副本可能滞后于加签/转办的增量写入，与 transfer 同源）
  let roster = (self.repo()).find_task_actors(task_id)
  if !privileged && !roster.contains(operator) {
    raise @error.Business(aidant_no_permission_msg)
  }
  let instance = match (self.repo()).find_instance_by_id(host.process_instance_id) {
    Some(i) => i
    None => raise @error.Business(recall_instance_missing_msg)
  }
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.Business("流程定义不存在")
  }
  let model = @parser.parse_model(define_info.content)
  let node = match model.get_node(host.task_name) {
    Some(n) =>
      if n.node_type is @parser.Task {
        n
      } else {
        raise @error.Business(aidant_not_doing_msg)
      }
    None => raise @error.Business(aidant_not_doing_msg)
  }
  // 去重：该人已有本主办行下**未办结**协办行 ⇒ 报错（spec 04 派生规则 5）
  let existing = aidant_rows(instance.tasks, host)
  for actor in actors {
    for t in existing {
      if t.is_doing() && t.actor_ids.contains(actor) {
        raise @error.Business(aidant_duplicate_msg)
      }
    }
  }
  // ── 判据全过，以下才允许写 ──
  let round = aidant_last_round(host) + 1L
  let created : Array[@model.ProcessTask] = []
  for actor in actors {
    let child = instance.create_task(
      node.id,
      node.display_name,
      [actor],
      operator,
      @model.TaskType::Assistant,
      // 协办行一律普通参与（节点上配的 performType 可能是会签；spec 04 派生规则 1）
      @model.PerformType::Normal,
      node.form_key(),
      Some(host.task_id),
    )
    match reason {
      Some(r) =>
        if !r.is_empty() {
          child.variables.insert_str(aidant_reason_key, r)
        }
      None => ()
    }
    created.push(child)
  }
  let exec = @exec.Execution::make(instance, model, define_info, operator, @json.FlowData::new())
  // 分支归属与每一次普通建单同一条腿（照征询成员行）：并行范围内的协办行继承父任务归属
  exec.process_task = Some(host.clone())
  apply_node_expire_time(exec, node, created)
  attach_branch_scopes(exec, node, created)
  for t in created {
    exec.new_tasks.push(t)
  }
  // 等待闸开关＋账本落主办行（主办不办结，variables 合并序保证账本活到办结后）。
  // ⚠️ 写的是 find_task_by_id 那份副本再 update_task 落回（＝collect.mbt 同一形状）；
  //   本腿不调 update_instance，聚合里那一格不跟着落库、也不会级联抹掉账本。
  host.variables.insert(aidant_wait_key, @json.bool_of(wait_completion))
  append_aidant_history_vars(host, operator, actors, round, reason)
  host.update_user = Some(operator)
  host.update_time = Some(@model.current_time_str())
  // 建单落库唯一收口：save_task ＋ 参与者 ＋ 委托并入 ＋ isFirstTaskNode ＋ fire 码 3
  self.persist_tasks(exec)
  (self.repo()).update_task(host)
  created
}