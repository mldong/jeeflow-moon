// issues/113~115：门面级 withdraw / processTask/transfer 三档用例（内存仓通道）。
// 断言一律落在**持久值 / 读回值**上（仓储读回 + 门面 action 出口），不断"doing 列表为空"这类间接信号。
// SQL 仓同口径真机对拍另有两个可执行：
//   repository-mysql/smoke  → T1-I114（仓储级：update_user 列真在 UPDATE 语句里）
//   demo/cmd/t1_mysql       → T1-F114/F115（门面级 withdraw/transfer，逐条读库断言）

///|
/// 两节点线性流：apply(applicant) → task1(leader) → end（契约示例同形：leader 转办给 lisi）
fn linear_flow_json() -> String {
  $|{"name": "wt-linear", "displayName": "撤回转办流程", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "apply", "type": "snaker:task", "text": {"value": "申请"},
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task", "text": {"value": "审批"},
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|   {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $| ]}
$| 
}

///|
/// 单人多参与人的普通任务（performType=0）：一个任务行挂两个参与者，
/// 转办只摘 fromActor 一行、另一人必须不受影响
fn shared_task_flow_json() -> String {
  $|{"name": "wt-shared", "displayName": "共享待办流程", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "apply", "type": "snaker:task", "text": {"value": "申请"},
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task", "text": {"value": "会审"},
  $|    "properties": {"assignee": "userA,userB", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|   {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $| ]}
$| 
}

///|
/// 并行会签（performType=1）：每人一个独立任务，转的是"自己那一票"
fn countersign_flow_json() -> String {
  $|{"name": "wt-cs", "displayName": "并行会签流程", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "apply", "type": "snaker:task", "text": {"value": "申请"},
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task", "text": {"value": "并行会签"},
  $|    "properties": {"assignee": "userA,userB,userC", "taskType": 0, "performType": "1",
  $|                  "countersignType": "PARALLEL"}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|   {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $| ]}
$| 
}

// ── 参数 / 信封助手 ──

///|
fn targs(entries : Array[(String, String)]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for e in entries {
    let (k, v) = e
    m[k] = @json.string_of(v)
  }
  m
}

///|
fn code_of(env : Json) -> Int64 {
  @json.get_i64(env, "code").unwrap_or(-1L)
}

///|
fn msg_of(env : Json) -> String {
  @json.get_str(env, "msg").unwrap_or("<无 msg 键>")
}

///|
fn data_of(env : Json) -> Json {
  @json.get(env, "data").unwrap_or(@json.null_json())
}

///|
fn rows_of(data : Json) -> Array[Json] {
  match @json.get(data, "rows") {
    Some(Json::Array(a)) => a
    _ => []
  }
}

///|
fn record_count_of(data : Json) -> Int64 {
  @json.get_i64(data, "recordCount").unwrap_or(-1L)
}

///|
fn page_has_instance(data : Json, iid : Int64) -> Bool {
  let mut hit = false
  for r in rows_of(data) {
    let rid = match @json.get(r, "processInstanceId") {
      Some(v) => @json.as_str(v).unwrap_or("")
      None => ""
    }
    if rid == iid.to_string() {
      hit = true
    }
  }
  hit
}

///|
/// 任务变量取键（从仓储**读回**的任务上取，非构造期内存对象）
fn var_field(task : @model.ProcessTask, key : String) -> String {
  match task.variables.get(key) {
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => s
        None => @json.stringify(v)
      }
    None => "<missing>"
  }
}

///|
fn history_of(task : @model.ProcessTask) -> Array[Json] {
  match task.variables.get("tf_transferHistory") {
    Some(Json::Array(items)) => items
    _ => []
  }
}

///|
fn hop_field(hop : Json, key : String) -> String {
  match @json.get(hop, key) {
    Some(v) =>
      match @json.as_str(v) {
        Some(s) => s
        None => @json.stringify(v)
      }
    None => "<missing>"
  }
}

// ── 装配助手 ──

///|
async fn doing_task_for(repo : @mem.MemoryRepository, iid : Int64, actor : String) -> @model.ProcessTask raise {
  let out : Array[@model.ProcessTask] = []
  for t in repo.find_doing_tasks(iid, []) {
    if t.actor_ids.contains(actor) {
      out.push(t)
    }
  }
  if out.is_empty() {
    abort("no doing task for \{actor} in \{iid}")
  }
  out[0]
}

///|
async fn task_by_name(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask raise {
  for t in repo.find_history_tasks(iid) {
    if t.task_name == name {
      return t
    }
  }
  abort("no task \{name} in \{iid}")
}

///|
/// 门面 + 内存仓 + 真实发起通道（startAndExecute 自动办结申请节点 → leader 的 task1 DOING）
async fn setup(content : String) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "wt-flow",
    display_name: "撤回转办流程",
    define_type: "approval",
    state: 1,
    content,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  assert_eq(msg_of(env), "成功")
  let iid = @json.get_str(data_of(env), "processInstanceId").unwrap_or("0")
  (facade, repo, parse_iid(iid))
}

///|
async fn todo_page(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  operator : String
) -> Json raise {
  data_of(
    facade.flow(
      "processTask/todoList",
      targs([("operator", operator), ("pageNum", "1"), ("pageSize", "50")]),
    ),
  )
}

///|
async fn done_page(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  operator : String
) -> Json raise {
  data_of(
    facade.flow(
      "processTask/doneList",
      targs([("operator", operator), ("pageNum", "1"), ("pageSize", "50")]),
    ),
  )
}

///|
fn parse_iid(s : String) -> Int64 {
  // parse_int64 是 `-> Int64 raise`：坏数字仍旧 abort（abort 返回 Nothing，与成功臂同型）
  try { @string.parse_int64(s) } catch { _ => abort("非法实例 id: \{s}") }
}

// ══════════════════ 正向 ══════════════════

///|
async test "transfer 正向: 待办从 A 挪到 B + 三件留痕落持久值（spec/06 §transfer-1..4）" {
  @model.set_clock(Some(fn() { "2026-09-21 08:20:54" }))
  defer { @model.set_clock(None) }
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let env = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "leader"),
      ("fromActor", "leader"),
      ("toActor", "lisi"),
      ("reason", "出差一周"),
    ]),
  )
  assert_eq(msg_of(env), "成功")
  // ① 参与者表：只摘 leader、加 lisi（读回值）
  assert_true(repo.find_task_actors(tid).join("|") == "lisi")
  // ② 任务不新建：同一 taskId 仍 DOING
  let back = repo.find_task_by_id(tid).unwrap()
  assert_eq(back.task_id, tid)
  assert_eq(back.task_state, @model.TaskState::Doing.code())
  assert_true(back.actor_ids.join("|") == "lisi")
  // ③ 待办挪位（门面出口）
  assert_true(!page_has_instance(todo_page(facade, "leader"), iid))
  assert_true(page_has_instance(todo_page(facade, "lisi"), iid))
  // ④ 留痕三件（读回的任务变量上）
  assert_eq(var_field(back, "submitType"), "7")
  assert_eq(var_field(back, "tf_transferTo"), "lisi")
  assert_eq(var_field(back, "tf_transferReason"), "出差一周")
  assert_eq(var_field(back, "tf_approvalComment"), "leader 转办给 lisi（出差一周）")
  let history = history_of(back)
  assert_eq(history.length(), 1)
  // 六键固定 camelCase；time 为 yyyy-MM-dd HH:mm:ss（不得本地 ISO 方言）
  assert_eq(hop_field(history[0], "submitType"), "7")
  assert_eq(hop_field(history[0], "fromActor"), "leader")
  assert_eq(hop_field(history[0], "toActor"), "lisi")
  assert_eq(hop_field(history[0], "reason"), "出差一周")
  assert_eq(hop_field(history[0], "time"), "2026-09-21 08:20:54")
  assert_eq(hop_field(history[0], "operator"), "leader")
  // ⑤ 审批记录出口读得到（approvalRecord 的 variable/ext 透出）
  let rec = data_of(facade.flow("processInstance/approvalRecord", targs([("id", iid.to_string())])))
  let mut target : Json? = None
  match rec {
    Json::Array(items) =>
      for r in items {
        if @json.get_str(r, "displayName").unwrap_or("") == "审批" {
          target = Some(r)
        }
      }
    _ => ()
  }
  let row = target.unwrap()
  let ext = @json.get(row, "ext").unwrap_or(@json.null_json())
  assert_eq(@json.stringify(@json.get(ext, "submitType").unwrap()), "7")
  match @json.get(ext, "tf_transferHistory") {
    Some(Json::Array(h)) => {
      assert_eq(h.length(), 1)
      assert_eq(hop_field(h[0], "toActor"), "lisi")
    }
    _ => assert_true(false)
  }
  assert_eq(@json.get_str(ext, "tf_approvalComment").unwrap_or(""), "leader 转办给 lisi（出差一周）")
}

///|
async test "transfer 正向: 多跳只追加 + B 办结后账本仍在、槽位由本次提交覆盖（契约第 5 条）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "leader"),
          ("fromActor", "leader"),
          ("toActor", "lisi"),
          ("reason", "出差一周"),
        ]),
      ),
    ),
    "成功",
  )
  // 第二跳 lisi → wangwu：leader→lisi 那条必须在
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "lisi"),
          ("fromActor", "lisi"),
          ("toActor", "wangwu"),
          ("reason", "休假"),
        ]),
      ),
    ),
    "成功",
  )
  let after_two = repo.find_task_by_id(tid).unwrap()
  let h2 = history_of(after_two)
  assert_eq(h2.length(), 2)
  assert_eq(hop_field(h2[0], "fromActor"), "leader")
  assert_eq(hop_field(h2[0], "toActor"), "lisi")
  assert_eq(hop_field(h2[1], "fromActor"), "lisi")
  assert_eq(hop_field(h2[1], "toActor"), "wangwu")
  // 便捷键 / 可读文案只留末跳，全量以账本为准
  assert_eq(var_field(after_two, "tf_transferTo"), "wangwu")
  assert_eq(var_field(after_two, "tf_approvalComment"), "lisi 转办给 wangwu（休假）")
  // 末跳人办结（submitType=1）：账本不丢、槽位被本次提交覆盖（Go 曾反噬的那一格）
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "wangwu"),
          ("submitType", "1"),
          ("f_note", "同意"),
        ]),
      ),
    ),
    "成功",
  )
  let done = repo.find_task_by_id(tid).unwrap()
  assert_eq(done.task_state, @model.TaskState::Finished.code())
  let h3 = history_of(done)
  assert_eq(h3.length(), 2)
  assert_eq(hop_field(h3[0], "toActor"), "lisi")
  assert_eq(var_field(done, "submitType"), "1")
  // 本次提交的表单字段进任务变量（合并写入，不整体替换）
  assert_eq(var_field(done, "f_note"), "同意")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, @model.InstanceState::Finished.code())
}

///|
async test "withdraw 正向: 发起人撤回 → 整单 30 + update_user 回写 + 已完成行不改（用例 23/24）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let doing_id = doing_task_for(repo, iid, "leader").task_id
  let env = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))
  assert_eq(msg_of(env), "成功")
  assert_true(@json.get(env, "data") is Some(Json::Null))
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 30)
  // update_user 回写真实撤回人（不是缺省 user1）
  assert_eq(inst.update_user.unwrap_or("<null>"), "applicant")
  // 进行中任务 → 30（不是 99）+ 任务 update_user 同回写
  let back = repo.find_task_by_id(doing_id).unwrap()
  assert_eq(back.task_state, 30)
  assert_eq(back.update_user.unwrap_or("<null>"), "applicant")
  // 已完成(20) 行不被撤回改写：状态保持 20，update_user 仍是办结人
  let apply = task_by_name(repo, iid, "apply")
  assert_eq(apply.task_state, 20)
  assert_eq(apply.update_user.unwrap_or("<null>"), "applicant")
  // 出口读回（detail 的 state + tasks 行状态；update_user 的出口读回见 processInstance/page 行）
  let detail = data_of(facade.flow("processInstance/detail", targs([("id", iid.to_string())])))
  assert_eq(@json.get_i64(detail, "state").unwrap_or(-1L), 30L)
  match @json.get(detail, "activeTaskList") {
    Some(Json::Array(a)) => assert_eq(a.length(), 0)
    _ => assert_true(false)
  }
  let mut withdrawn_rows = 0
  let mut finished_rows = 0
  match @json.get(detail, "tasks") {
    Some(Json::Array(a)) =>
      for r in a {
        match @json.get_i64(r, "taskState") {
          Some(30L) => withdrawn_rows += 1
          Some(20L) => finished_rows += 1
          _ => ()
        }
      }
    _ => ()
  }
  assert_eq(withdrawn_rows, 1)
  assert_eq(finished_rows, 1)
}

///|
async test "withdraw 正向: 进行中任务参与者可撤整单（判据 2）/ flow.admin、flow.auto 放行（判据 3）" {
  // 判据 2：leader 不是发起人，但是进行中任务的参与者 → 撤的是整单
  let (facade, repo, iid) = setup(linear_flow_json())
  assert_eq(
    msg_of(facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "leader")]))),
    "成功",
  )
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 30)
  assert_eq(inst.update_user.unwrap_or("<null>"), "leader")
  // 出口读回：发起人视角的 processInstance/page 行里 updateUser = 真实撤回人（非 user1）
  let page = data_of(
    facade.flow("processInstance/page", targs([("operator", "applicant"), ("pageNum", "1"), ("pageSize", "10")])),
  )
  let mut row_update_user = "<none>"
  for r in rows_of(page) {
    if @json.as_str(@json.get(r, "id").unwrap_or(@json.null_json())).unwrap_or("") == iid.to_string() {
      row_update_user = @json.get_str(r, "updateUser").unwrap_or("<null>")
    }
  }
  assert_eq(row_update_user, "leader")
  assert_eq(record_count_of(page), 1L)
  // 判据 3：flow.admin / flow.auto 与发起人、参与者身份无关（大小写不敏感，同 is_allowed 约定）
  let (facade2, repo2, iid2) = setup(linear_flow_json())
  assert_eq(
    msg_of(facade2.flow("processInstance/withdraw", targs([("id", iid2.to_string()), ("operator", "flow.admin")]))),
    "成功",
  )
  assert_eq(repo2.find_instance_by_id(iid2).unwrap().state, 30)
  let (facade3, repo3, iid3) = setup(linear_flow_json())
  assert_eq(
    msg_of(facade3.flow("processInstance/withdraw", targs([("id", iid3.to_string()), ("operator", "FLOW.AUTO")]))),
    "成功",
  )
  assert_eq(repo3.find_instance_by_id(iid3).unwrap().state, 30)
  assert_eq(repo3.find_instance_by_id(iid3).unwrap().update_user.unwrap_or("<null>"), "FLOW.AUTO")
}

// ══════════════════ 负向（八种 msg 逐字） ══════════════════

///|
async test "负向: withdraw 缺 operator 明确报错且不回落 user1；无关第三人拒绝" {
  let (facade, repo, iid) = setup(linear_flow_json())
  // 缺 operator：严禁回落成 user1 之类固定账号（撤回人静默记错、审计链失真且不报错）
  let missing = facade.flow("processInstance/withdraw", targs([("id", iid.to_string())]))
  assert_eq(code_of(missing), 99999999L)
  assert_eq(msg_of(missing), "operator 必填")
  // 空串/纯空白同判
  assert_eq(
    msg_of(facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "   ")]))),
    "operator 必填",
  )
  // 撤回未发生：实例仍 10、update_user 没被记成 user1
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  assert_true(inst.update_user.unwrap_or("") != "user1")
  // 无关第三人：三条判据全不命中 → 99999999 + 统一 msg
  let third = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "intruder")]))
  assert_eq(code_of(third), 99999999L)
  assert_eq(msg_of(third), "无权限撤回该流程实例")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  assert_eq(doing_task_for(repo, iid, "leader").task_state, 10)
}

///|
async test "负向: transfer 八种 msg 逐字（必填三项 + 权限 + 参与者 + 去重 + 前置态）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  // 1. 缺 operator
  let e1 = facade.flow(
    "processTask/transfer",
    targs([("processTaskId", tid.to_string()), ("fromActor", "leader"), ("toActor", "lisi")]),
  )
  assert_eq(code_of(e1), 99999999L)
  assert_eq(msg_of(e1), "operator 必填")
  // 2. 缺 fromActor
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("toActor", "lisi")]),
      ),
    ),
    "fromActor 必填",
  )
  // 3. 缺 toActor
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("fromActor", "leader")]),
      ),
    ),
    "toActor 必填",
  )
  // 4. 操作人非 fromActor 且非 auto/admin
  let e4 = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "someoneelse"),
      ("fromActor", "leader"),
      ("toActor", "lisi"),
    ]),
  )
  assert_eq(code_of(e4), 99999999L)
  assert_eq(msg_of(e4), "无权限转办该任务")
  // 5. fromActor 不在参与者里
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "flow.admin"),
          ("fromActor", "not_a_member"),
          ("toActor", "lisi"),
        ]),
      ),
    ),
    "原办理人不是该任务参与人",
  )
  // 6. toActor 已是参与者（先加签再转给同一人）
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/addCandidate",
        targs([("processTaskId", tid.to_string()), ("actorIds", "lisi")]),
      ),
    ),
    "成功",
  )
  let e6 = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "leader"),
      ("fromActor", "leader"),
      ("toActor", "lisi"),
    ]),
  )
  assert_eq(code_of(e6), 99999999L)
  assert_eq(msg_of(e6), "目标人已是该任务参与人")
  // 失败路径零副作用：参与者表没被动过
  assert_true(repo.find_task_actors(tid).join("|") == "leader|lisi")
  // 7. 任务非进行中：原人先办结（lisi 只是加签人，内存仓待办/可办仍按任务副本判定），再转办同一任务
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("submitType", "1")]),
      ),
    ),
    "成功",
  )
  let e7 = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "flow.admin"),
      ("fromActor", "leader"),
      ("toActor", "wangwu"),
    ]),
  )
  assert_eq(code_of(e7), 99999999L)
  assert_eq(msg_of(e7), "任务非进行中，不可转办")
  // 8. 缺 processTaskId（沿用既有 msg，不新增失败码）
  let e8 = facade.flow(
    "processTask/transfer",
    targs([("operator", "leader"), ("fromActor", "leader"), ("toActor", "lisi")]),
  )
  assert_eq(code_of(e8), 99999999L)
  assert_eq(msg_of(e8), "缺少processTaskId参数")
}

// ══════════════════ 回归 ══════════════════

///|
async test "回归: 加签 surrogate/addCandidate 仍只追加（原人保留可办、taskId 不变）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/surrogate",
        targs([("processTaskId", tid.to_string()), ("actorIds", "extra1")]),
      ),
    ),
    "成功",
  )
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/addCandidate",
        targs([("processTaskId", tid.to_string()), ("actorIds", "extra2")]),
      ),
    ),
    "成功",
  )
  let actors = repo.find_task_actors(tid)
  assert_eq(actors.length(), 3)
  assert_true(actors.contains("leader")) // 加签绝不摘原人
  let back = repo.find_task_by_id(tid).unwrap()
  assert_eq(back.task_id, tid)
  assert_eq(back.task_state, 10)
  assert_true(page_has_instance(todo_page(facade, "leader"), iid))
  // 加签后原人保留可办；把加签人再转给第三人 → 只摘 extra1，leader/extra2 原样
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "extra1"),
          ("fromActor", "extra1"),
          ("toActor", "extra3"),
        ]),
      ),
    ),
    "成功",
  )
  assert_true(repo.find_task_actors(tid).join("|") == "leader|extra2|extra3")
  assert_true(page_has_instance(todo_page(facade, "leader"), iid))
  // 接手人拿到待办（走的是"参与者表 → 副本同步 → update_task"这条持久路）
  assert_true(page_has_instance(todo_page(facade, "extra3"), iid))
  // 转给已在参与者里的人 → 去重报错（加签的痕迹不能被"追加"吞掉）
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "leader"),
          ("fromActor", "leader"),
          ("toActor", "extra2"),
        ]),
      ),
    ),
    "目标人已是该任务参与人",
  )
}

///|
async test "回归: 共享待办只摘 fromActor 一行，其余参与者不受影响（契约语义 1）" {
  let (facade, repo, iid) = setup(shared_task_flow_json())
  let tid = doing_task_for(repo, iid, "userA").task_id
  assert_true(repo.find_task_actors(tid).join("|") == "userA|userB")
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "userA"),
          ("fromActor", "userA"),
          ("toActor", "userC"),
        ]),
      ),
    ),
    "成功",
  )
  assert_true(repo.find_task_actors(tid).join("|") == "userB|userC")
  let back = repo.find_task_by_id(tid).unwrap()
  assert_true(back.actor_ids.join("|") == "userB|userC")
  // 三人待办视图：A 摘走、B 仍在、C 接手
  assert_true(!page_has_instance(todo_page(facade, "userA"), iid))
  assert_true(page_has_instance(todo_page(facade, "userB"), iid))
  assert_true(page_has_instance(todo_page(facade, "userC"), iid))
  // reason 无值写 ""（不写 null）；末跳文案不带括号
  assert_eq(var_field(back, "tf_transferReason"), "")
  assert_eq(hop_field(history_of(back)[0], "reason"), "")
  assert_eq(var_field(back, "tf_approvalComment"), "userA 转办给 userC")
}

///|
async test "回归: 会签簿记——转办自己那一票后其余成员照旧办结，20 压过转办的 7" {
  let (facade, repo, iid) = setup(countersign_flow_json())
  let task_a = doing_task_for(repo, iid, "userA")
  let task_b = doing_task_for(repo, iid, "userB")
  let task_c = doing_task_for(repo, iid, "userC")
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", task_a.task_id.to_string()),
          ("operator", "userA"),
          ("fromActor", "userA"),
          ("toActor", "userD"),
        ]),
      ),
    ),
    "成功",
  )
  // 只动 A 那一票，B/C 的参与者行原样
  assert_true(repo.find_task_actors(task_a.task_id).join("|") == "userD")
  assert_true(repo.find_task_actors(task_b.task_id).join("|") == "userB")
  assert_true(repo.find_task_actors(task_c.task_id).join("|") == "userC")
  // D 会签拒绝（20）：本次提交压过转办留下的 submitType=7，簿记 flag 正常写入
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([
          ("processTaskId", task_a.task_id.to_string()),
          ("operator", "userD"),
          ("submitType", "20"),
        ]),
      ),
    ),
    "成功",
  )
  let after_d = repo.find_task_by_id(task_a.task_id).unwrap()
  assert_eq(var_field(after_d, "submitType"), "20")
  assert_eq(var_field(after_d, "countersignDisagreeFlag"), "1")
  assert_eq(history_of(after_d).length(), 1)
  for t in [task_b, task_c] {
    assert_eq(
      msg_of(
        facade.flow(
          "processTask/execute",
          targs([("processTaskId", t.task_id.to_string()), ("operator", t.actor_ids[0]), ("submitType", "1")]),
        ),
      ),
      "成功",
    )
  }
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, @model.InstanceState::Finished.code())
  assert_eq(inst.variables.get_str("countersignDisagreeFlag").unwrap_or(""), "1")
}

///|
async test "回归红线: 转办绝不覆写任务 actor_id/operator 列" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "leader"),
          ("fromActor", "leader"),
          ("toActor", "lisi"),
          ("reason", "出差一周"),
        ]),
      ),
    ),
    "成功",
  )
  // 进行中任务该列恒无值（既有不变量）——被摘走的人不能被写成办理人
  let back = repo.find_task_by_id(tid).unwrap()
  assert_true(back.actor_id is None)
  // 出口读回同样是 null
  let latest = data_of(facade.flow("processTask/latest", targs([("processInstanceId", iid.to_string())])))
  assert_true(@json.get(latest, "operator") is Some(Json::Null))
  // "办理人记谁"由 update_user + 账本 operator 承载
  assert_eq(back.update_user.unwrap_or("<null>"), "leader")
  assert_eq(hop_field(history_of(back)[0], "operator"), "leader")
}

///|
async test "回归红线: 转办后撤单，被摘走的人 doneList 不凭空多单（用例 25）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "leader"),
          ("fromActor", "leader"),
          ("toActor", "lisi"),
        ]),
      ),
    ),
    "成功",
  )
  // 发起人撤回：任务离开 DOING（30）但保留办理人列——Node 实测踩到的正是这一格
  assert_eq(
    msg_of(facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))),
    "成功",
  )
  let withdrawn = repo.find_task_by_id(tid).unwrap()
  assert_eq(withdrawn.task_state, 30)
  assert_true(withdrawn.actor_id is None)
  // 被摘走的 leader 与接手却未办的 lisi，「我已办」都不该出现这条
  for who in ["leader", "lisi"] {
    let done = done_page(facade, who)
    assert_true(!page_has_instance(done, iid))
    assert_eq(record_count_of(done), 0L)
  }
  // 真正办过申请节点的 applicant 仍读得到自己那一行（不被撤回清空）
  let mine = done_page(facade, "applicant")
  assert_true(page_has_instance(mine, iid))
}
