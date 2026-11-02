// 「后加签（可重复）」验收（黑盒 async test，内存仓）——移植 java `AddSignAfterTest` 的 16 格。
//
// 契约面（spec 04-engine-ops「后加签（可重复）」＋ spec 06-facade §2.7）：
//   · 节点开关 `allowAddSign`（缺省 false）／`addSignMaxRounds`（整数 >=0，0＝不限，缺省 0）；
//     非法值与「会签节点／首任务节点配 allowAddSign」都在**解析期**报错（三格）；
//   · 协议键 `tf_addSignOperators`（逗号串与数组两形同判据）；与 `tf_nextNodeOperator` 互斥；
//     节点未开开关却传键 ⇒ 报错；加给自己 ⇒ 报错；超上限 ⇒ 报错不强制放行；
//     四判据一律排在状态变更之前，报错时零写入；
//   · 推进闸 merged 判据（顺序不可反）：点了人→同节点建单+停留；没点但本节点还有未完成
//     待办→停留；两者皆否→放行出边；
//   · 新任务 `task_parent_id`＝刚办结那条；轮次记任务变量 `addSignRound_{节点名}`；
//     账本 `tf_addSignHistory` 只追加不覆盖、`time` 为 `yyyy-MM-dd HH:mm:ss`；
//   · 拒绝(2)／退回发起人(6)废弃本节点未完成的加签任务；加签链上「退回上一步」(3) 禁；
//   · 根因守卫：`tf_*` 控制键不得进实例变量（跨请求复活的病根），但任务行留痕必须完整。
//
// 夹具：本文件用**内联 JSON**（`as_flow_json`）——共享 flows 目录那条腿另有归属（十仓镜像
// 与漂移门禁），在这里加文件会把它提前拖进同步；唯一真消费共享夹具
// `flows/19-add-sign-after.json` 的是 addsign-16 那一格（七语言仓 flows/ 是它的入库副本，
// 各语言移植后加签读的就是这一份）。
// 复用同包 helper：make_compliance_engine / save_flow_define / load_flow / new_args。
//
// ⚠️ 本栈没有线程（MoonBit async 单事件循环），java `test14` 的"两个同圈加签任务并发办结"
// 在本栈落为"相继办结只放行一次 + 重复提交第二发报错"：同实例串行化由事件循环给出，
// 跨进程锁是 spec 04 如实声明的已知边界（继承 reapply 轮同一条），本栈不宣称支持。

///|
/// 节点开关档（属性键值对，测试与夹具用同一枚字面）
let allow_on : (String, Json) = ("allowAddSign", @json.bool_of(true))

///|
/// 提交参数（只带 submitType）
fn as_submit(t : Int64) -> @json.FlowData {
  let a = @json.FlowData::new()
  a.insert("submitType", @json.number_of(t))
  a
}

///|
/// 同意并点名加签人（逗号串档）
fn as_agree(ops : String) -> @json.FlowData {
  let a = as_submit(1L)
  a.insert(@engine.add_sign_operators_key, @json.string_of(ops))
  a
}

///|
/// 同意并点名加签人（数组档，两形同判据）
fn as_agree_arr(ops : Array[String]) -> @json.FlowData {
  let a = as_submit(1L)
  a.insert(@engine.add_sign_operators_key, @json.array_of(ops.map(fn(s) { @json.string_of(s) })))
  a
}

///|
/// 同意 + 同时指定下一节点办理人（互斥档）
fn as_agree_with_next(ops : String, next_ops : String) -> @json.FlowData {
  let a = as_agree(ops)
  a.insert(@engine.next_node_operator_key, @json.string_of(next_ops))
  a
}

///|
/// 同意 + 审批意见（根因守卫格用）
fn as_agree_with_comment(ops : String, comment : String) -> @json.FlowData {
  let a = as_agree(ops)
  a.insert("tf_approvalComment", @json.string_of(comment))
  a
}

///|
/// 任务节点 properties：四枚固定键 + 调用方追加档（追加档同键覆盖固定档——
/// `@json.object_of` 按后写生效 ⇒ 不会写出 JSON 重复键那种歧义形状）
fn task_props(
  assignee : String, perform : Int64, extra : Array[(String, Json)]
) -> Array[(String, Json)] {
  let out : Array[(String, Json)] = []
  for pair in [
    ("form", @json.string_of("form")),
    ("assignee", @json.string_of(assignee)),
    ("taskType", @json.number_of(0L)),
    ("performType", @json.number_of(perform)),
  ] {
    out.push(pair)
  }
  for pair in extra {
    out.push(pair)
  }
  out
}

///|
/// 一个节点（properties 直接收键值对数组）
fn as_node(
  id : String, node_type : String, props : Array[(String, Json)], text : String
) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of(node_type)),
    ("properties", @json.object_of(props)),
    ("text", @json.object_of([("value", @json.string_of(text))])),
  ])
}

///|
fn as_edge(id : String, from : String, to : String) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of("snaker:transition")),
    ("sourceNodeId", @json.string_of(from)),
    ("targetNodeId", @json.string_of(to)),
    ("properties", @json.object_of([])),
  ])
}

///|
/// 夹具：start → apply → review → final → end。
/// `apply_extra`／`review_extra` 是两节点各自的追加档（首任务节点配开关那一格用前者）。
fn as_flow_json(
  name : String,
  apply_extra : Array[(String, Json)],
  review_extra : Array[(String, Json)]
) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("后加签夹具")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        as_node("start", "snaker:start", [], "开始"),
        as_node("apply", "snaker:task", task_props("applicant", 0L, apply_extra), "发起申请"),
        as_node("review", "snaker:task", task_props("userA", 0L, review_extra), "审批"),
        as_node("final", "snaker:task", task_props("userF", 0L, []), "终审"),
        as_node("end", "snaker:end", [], "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        as_edge("e1", "start", "apply"),
        as_edge("e2", "apply", "review"),
        as_edge("e3", "review", "final"),
        as_edge("e4", "final", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 发起并办掉申请节点 ⇒ 令牌停在 review
async fn as_start_to_review(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  name : String,
  review_extra : Array[(String, Json)]
) -> Int64 raise {
  let did = save_flow_define(repo, name, as_flow_json(name, [], review_extra))
  let inst = engine.start_async(did, "applicant", new_args())
  for t in repo.find_doing_tasks(inst.instance_id, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", as_submit(0L))
    }
  }
  inst.instance_id
}

///|
/// 同上，但申请节点也带追加档（首任务节点配 allowAddSign 那一格）
async fn as_start_to_review_with_apply(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  name : String,
  apply_extra : Array[(String, Json)],
  review_extra : Array[(String, Json)]
) -> Int64 raise {
  let did = save_flow_define(repo, name, as_flow_json(name, apply_extra, review_extra))
  let inst = engine.start_async(did, "applicant", new_args())
  for t in repo.find_doing_tasks(inst.instance_id, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", as_submit(0L))
    }
  }
  inst.instance_id
}

///|
/// 该节点名有没有 DOING 行（进行中行的读回一律走仓储，不看引擎返回的那个聚合对象）
async fn as_has_doing(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Bool raise {
  let mut found = false
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      found = true
    }
  }
  found
}

///|
/// 该节点名的第一条 DOING 行
async fn as_doing(
  repo : @mem.MemoryRepository, iid : Int64, name : String
) -> @model.ProcessTask? raise {
  let mut out : @model.ProcessTask? = None
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      out = Some(t)
    }
  }
  out
}

///|
/// 必须有该节点的 DOING 行（没有就显式红，不许被读成"另一件事"）
async fn as_need(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask raise {
  match as_doing(repo, iid, name) {
    Some(t) => t
    None => abort("期望存在 \"\{name}\" 的 DOING 行，实例 \{iid}")
  }
}

///|
/// 该节点名的 DOING 行数
async fn as_doing_count(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 该节点名的历史行数（含已完成/废弃行）
async fn as_rows(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_history_tasks(iid) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 某节点名、某状态的行数（废弃态那一格要用）
async fn as_rows_with_state(
  repo : @mem.MemoryRepository, iid : Int64, name : String, state : Int
) -> Int raise {
  let mut n = 0
  for t in repo.find_history_tasks(iid) {
    if t.task_name == name && t.task_state == state {
      n = n + 1
    }
  }
  n
}

///|
/// 进行中行的第一个参与者（家族不变量：DOING 行的 `actor_id` 列恒空，取人要走参与者表）
fn as_first_actor(t : @model.ProcessTask) -> String {
  if t.actor_ids.is_empty() {
    abort("任务 \{t.task_id} 没有参与者")
  } else {
    t.actor_ids[0]
  }
}

///|
/// 办理入口的报错文案（没报错返回哨兵串 ⇒ 读成一条独立的红，不靠 try 块外的断言蒙过去）
async fn as_exec_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> String {
  try {
    let _ = engine.execute_task_async(task_id, operator, args)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 解析期报错文案
fn as_parse_err(flow_json : String) -> String {
  try {
    let _ = @parser.parse_model(flow_json)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 全生态时间格式 `yyyy-MM-dd HH:mm:ss` 的形状判据（19 位，数字与分隔符各就各位）。
/// 刻意不注入时钟：注入槽是全局可变的，用例之间会互盖（本仓既有口径），而这一格判的是格式。
fn is_eco_time(s : String) -> Bool {
  let cs = s.to_array()
  if cs.length() != 19 {
    return false
  }
  let digit = (i : Int) => {
    let c = cs[i].to_int()
    c >= 48 && c <= 57
  }
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
    if !digit(i) {
      return false
    }
  }
  let seps : Array[(Int, Char)] = [(4, '-'), (7, '-'), (10, ' '), (13, ':'), (16, ':')]
  for pair in seps {
    if cs[pair.0] != pair.1 {
      return false
    }
  }
  true
}

// ── 正向 ────────────────────────────────────────────────────────────────────

///|
/// 01 链式续办：A→B→C→不点人即流出；血缘串成链、轮次递增、账本落在已完成行。
async test "addsign-01 链式续办：点了人就同节点续建，不点人才流出本节点" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-01", [allow_on])
  let a = as_need(repo, iid, "review")

  let _ = engine.execute_task_async(a.task_id, "userA", as_agree("userB"))
  let b = as_need(repo, iid, "review")
  assert_eq(b.parent_task_id, Some(a.task_id))
  assert_eq(@engine.add_sign_round_of(b, "review"), 1L)
  assert_true(!as_has_doing(repo, iid, "final"), msg="令牌不得流出本节点")
  assert_eq(as_doing_count(repo, iid, "review"), 1, msg="本节点只应有 1 条待办")

  let a_row = repo.find_task_by_id(a.task_id).unwrap()
  let hist = @engine.add_sign_history_of(a_row)
  assert_eq(hist.length(), 1, msg="账本一行")
  let e0 = hist[0]
  assert_eq(@json.as_str(@json.get(e0, "fromActor").unwrap()), Some("userA"))
  assert_eq(@json.as_str(@json.get(e0, "operator").unwrap()), Some("userA"))
  assert_eq(@json.as_i64(@json.get(e0, "round").unwrap()), Some(1L))
  let to0 = @json.as_array(@json.get(e0, "toActors").unwrap()).unwrap()
  assert_eq(to0.length(), 1)
  assert_eq(@json.as_str(to0[0]), Some("userB"))
  let time0 = @json.as_str(@json.get(e0, "time").unwrap()).unwrap()
  assert_true(is_eco_time(time0), msg="时间须是全生态格式串 yyyy-MM-dd HH:mm:ss")

  let _ = engine.execute_task_async(b.task_id, "userB", as_agree("userC"))
  let c = as_need(repo, iid, "review")
  assert_eq(@engine.add_sign_round_of(c, "review"), 2L, msg="轮次递增")
  assert_eq(c.parent_task_id, Some(b.task_id))

  // C 不再点人 ⇒ 停止条件成立，流出本节点
  let _ = engine.execute_task_async(c.task_id, "userC", as_submit(1L))
  assert_true(!as_has_doing(repo, iid, "review"), msg="不点人后不得再有本节点待办")
  let fin = as_need(repo, iid, "final")
  assert_eq(as_rows(repo, iid, "review"), 3, msg="review 共三行")
  let _ = engine.execute_task_async(fin.task_id, "userF", as_submit(1L))
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20, msg="实例办结")
}

///|
/// 02 数组两形同判据：一次点两人 ⇒ 同圈两行；最后一位办结且没点人才放行。
async test "addsign-02 一轮多选：同圈建多行，兄弟待办未完成不得放行" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-02", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree_arr(["userB", "userC"]))
  assert_eq(as_doing_count(repo, iid, "review"), 2, msg="同圈应建两行待办")
  assert_true(!as_has_doing(repo, iid, "final"))

  let b = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(b.task_id, as_first_actor(b), as_submit(1L))
  assert_true(!as_has_doing(repo, iid, "final"), msg="兄弟待办未完成时不得放行")
  assert_eq(as_doing_count(repo, iid, "review"), 1)

  let c = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(c.task_id, as_first_actor(c), as_submit(1L))
  let _ = as_need(repo, iid, "final")
  assert_eq(as_doing_count(repo, iid, "final"), 1, msg="放行只能发生一次")
}

///|
/// 03 加给已办过的人合法（A→B→A 乒乓），轮次继续计数。
async test "addsign-03 加给已办过的人合法，计入轮次" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-03", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree("userB"))
  let b = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(b.task_id, "userB", as_agree("userA"))
  let back = as_need(repo, iid, "review")
  assert_true(back.actor_ids.contains("userA"), msg="加给已办过的人应合法")
  assert_eq(@engine.add_sign_round_of(back, "review"), 2L)
}

// ── 负向：写入口报错且零写入 ────────────────────────────────────────────────

///|
/// 04 与 `tf_nextNodeOperator` 同传 ⇒ 报错（逐字文案），任务行/实例零改动。
async test "addsign-04 与 tf_nextNodeOperator 同传报错且零写入" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-04", [allow_on])
  let a = as_need(repo, iid, "review")
  let before = as_rows(repo, iid, "review")
  let msg = as_exec_err(engine, a.task_id, "userA", as_agree_with_next("userB", "userF"))
  assert_eq(msg, @engine.add_sign_mutex_msg)
  assert_true(repo.find_task_by_id(a.task_id).unwrap().is_doing(), msg="报错时任务行不得被办结")
  assert_eq(as_rows(repo, iid, "review"), before, msg="不得新增行")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
}

///|
/// 05 节点未开开关却传键 ⇒ 报错（不得静默忽略），零写入。
async test "addsign-05 开关没开却传 tf_addSignOperators 报错且零写入" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-05", [])
  let a = as_need(repo, iid, "review")
  let msg = as_exec_err(engine, a.task_id, "userA", as_agree("userB"))
  assert_eq(msg, @engine.add_sign_switch_off_msg("review"))
  assert_true(repo.find_task_by_id(a.task_id).unwrap().is_doing())
  assert_true(!as_has_doing(repo, iid, "final"), msg="报错那次不得把令牌推到下一节点")
}

///|
/// 06 加给自己 ⇒ 报错（死循环入口），零写入。加签人按归一后的值比：" userA " 就是 userA。
async test "addsign-06 加签给自己报错且零写入" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-06", [allow_on])
  let a = as_need(repo, iid, "review")
  let msg = as_exec_err(engine, a.task_id, "userA", as_agree(" userA "))
  assert_eq(msg, @engine.add_sign_self_msg)
  assert_true(repo.find_task_by_id(a.task_id).unwrap().is_doing())
  assert_eq(as_doing_count(repo, iid, "review"), 1)
}

///|
/// 07 超 `addSignMaxRounds` ⇒ 报错不强制放行（放行＝伪造"审批完成"），零写入；
/// 但已建的那一位不点人可以正常流出。
async test "addsign-07 超轮次上限报错、不强制放行" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [allow_on, ("addSignMaxRounds", @json.number_of(1L))]
  let iid = as_start_to_review(engine, repo, "addsign-07", extra)
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree("userB"))
  let b = as_need(repo, iid, "review")
  let msg = as_exec_err(engine, b.task_id, "userB", as_agree("userC"))
  assert_eq(msg, @engine.add_sign_max_rounds_msg("review", 1L))
  assert_true(repo.find_task_by_id(b.task_id).unwrap().is_doing(), msg="越界那次不得办结任务行")
  assert_true(!as_has_doing(repo, iid, "final"), msg="越界那次不得强制放行")
  let _ = engine.execute_task_async(b.task_id, "userB", as_submit(1L))
  let _ = as_need(repo, iid, "final")
}

// ── 解析期硬校验（三格） ────────────────────────────────────────────────────

///|
/// 08 会签节点配 `allowAddSign` ⇒ 解析期报错。
async test "addsign-08 会签节点配 allowAddSign 解析期报错" {
  let cs_extra : Array[(String, Json)] = [
    allow_on,
    ("performType", @json.number_of(1L)),
    ("countersignType", @json.string_of("PARALLEL")),
  ]
  let msg = as_parse_err(as_flow_json("addsign-08", [], cs_extra))
  assert_true(
    msg.contains("会签节点[review]不允许配置 allowAddSign"), msg="会签节点配开关要解析期报错: \{msg}"
  )
}

///|
/// 09 首任务节点配 `allowAddSign` ⇒ 解析期报错。
async test "addsign-09 首任务节点配 allowAddSign 解析期报错" {
  let msg = as_parse_err(as_flow_json("addsign-09", [allow_on], [allow_on]))
  assert_true(
    msg.contains("首任务节点[apply]不允许配置 allowAddSign"),
    msg="首任务节点配开关要解析期报错: \{msg}",
  )
}

///|
/// 10 两枚开关的非法值 ⇒ 解析期报错，不得静默落回缺省。
async test "addsign-10 非法配置值解析期报错（三档各有文案）" {
  let bad_bool : Array[(String, Json)] = [("allowAddSign", @json.string_of("yes"))]
  let m1 = as_parse_err(as_flow_json("addsign-10a", [], bad_bool))
  assert_true(m1.contains("节点[review]的 allowAddSign 配置非法: yes"), msg="非法档: \{m1}")

  let neg : Array[(String, Json)] = [allow_on, ("addSignMaxRounds", @json.number_of(-1L))]
  let m2 = as_parse_err(as_flow_json("addsign-10b", [], neg))
  assert_true(m2.contains("（不得为负，0 表示不限）"), msg="负上限: \{m2}")

  let frac : Array[(String, Json)] = [allow_on, ("addSignMaxRounds", @json.string_of("1.5"))]
  let m3 = as_parse_err(as_flow_json("addsign-10c", [], frac))
  assert_true(m3.contains("（必须是整数，0 表示不限）"), msg="非整数上限: \{m3}")

  // 反向哨兵：两枚键都不配 ⇒ 解析通过、开关为关、上限 0＝不限
  let ok = @parser.parse_model(as_flow_json("addsign-10d", [], []))
  let node = ok.get_node("review").unwrap()
  assert_eq(node.allow_add_sign(), false)
  assert_eq(node.add_sign_max_rounds(), 0L)
}

// ── 拒绝／退回发起人：废弃未完成加签任务 ────────────────────────────────────

///|
/// 11 不同意(2)：实例结束（45），本节点未完成的兄弟加签任务废弃（99），不留孤儿待办。
async test "addsign-11 拒绝结束实例并废弃本节点未完成的加签待办" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-11", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree_arr(["userB", "userC"]))
  assert_eq(as_doing_count(repo, iid, "review"), 2)

  let b = as_need(repo, iid, "review")
  let _ = engine.execute_and_jump_to_end_async(b.task_id, as_first_actor(b), as_submit(2L))
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 45, msg="实例应已结束")
  assert_eq(as_doing_count(repo, iid, "review"), 0, msg="未完成的加签兄弟不得留待办")
  assert_eq(
    as_rows_with_state(repo, iid, "review", @model.TaskState::Abandon.code()),
    1,
    msg="被废弃的那条应留废弃态",
  )
}

///|
/// 12 退回发起人(6)：生成申请待办，本节点未完成加签任务废弃。
async test "addsign-12 退回发起人废弃本节点未完成的加签待办" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-12", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree_arr(["userB", "userC"]))
  let b = as_need(repo, iid, "review")
  let _ = engine.execute_and_jump_to_first_async(b.task_id, as_first_actor(b), as_submit(6L))
  let _ = as_need(repo, iid, "apply")
  assert_eq(as_doing_count(repo, iid, "review"), 0, msg="本节点未完成加签任务应被废弃")
  assert_true(!as_has_doing(repo, iid, "final"))
}

// ── 回归、并发与根因守卫 ────────────────────────────────────────────────────

///|
/// 13 不开开关的节点行为逐字不变：同意即流出，账本一行不记。
async test "addsign-13 回归：不配两枚开关的节点行为逐字不变" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-13", [])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_submit(1L))
  let _ = as_need(repo, iid, "final")
  assert_eq(as_rows(repo, iid, "review"), 1)
  let a_row = repo.find_task_by_id(a.task_id).unwrap()
  assert_eq(@engine.add_sign_history_of(a_row).length(), 0)
  assert_eq(@engine.add_sign_round_of(a_row, "review"), 0L)
}

///|
/// 14 同圈两条加签任务相继办结：只放行一次（后续节点恰好一条待办）；
/// 重复提交第二发报错（＝"重复提交至多一个成功"）。
async test "addsign-14 同圈兄弟相继办结只放行一次，重复提交报错" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-14", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree_arr(["userB", "userC"]))
  let ids : Array[(Int64, String)] = []
  for t in repo.find_doing_tasks(iid, []) {
    ids.push((t.task_id, as_first_actor(t)))
  }
  assert_eq(ids.length(), 2)
  for pair in ids {
    let _ = engine.execute_task_async(pair.0, pair.1, as_submit(1L))
  }
  assert_eq(as_doing_count(repo, iid, "final"), 1, msg="后续节点只应有一条待办")
  assert_eq(as_doing_count(repo, iid, "review"), 0)
  // 重复提交：第二发打在已办结的行上必须报错，且不得再放出一条后续待办
  let msg = as_exec_err(engine, ids[0].0, ids[0].1, as_submit(1L))
  assert_true(msg != "<未报错>", msg="重复提交第二发要报错，实得文案: \{msg}")
  assert_eq(as_doing_count(repo, iid, "final"), 1)
}

///|
/// 15 根因守卫：控制类 `tf_*` 参数不得进实例变量（跨请求复活的病根），
/// 但任务行留痕必须完整——两者是同一枚判据的两面。
/// 另加复活判据：B 办结不带参数时，不得因上一轮 A 点过人而再多建一条本节点待办。
async test "addsign-15 根因守卫：tf_ 键不进实例变量，且不跨请求复活" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-15", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree_with_comment("userB", "请 B 复核"))

  let inst_vars = repo.find_instance_by_id(iid).unwrap().variables
  assert_eq(inst_vars.keys_with_prefix("tf_").length(), 0, msg="实例变量里不得有任何 tf_ 键")
  assert_eq(inst_vars.get(@engine.add_sign_operators_key), None)
  assert_eq(inst_vars.get("tf_approvalComment"), None)

  // 留痕仍在任务行上（修根因不得把审计信息一起改掉）
  let a_row = repo.find_task_by_id(a.task_id).unwrap()
  assert_eq(a_row.variables.get_str("tf_approvalComment"), Some("请 B 复核"))
  assert_eq(a_row.variables.get_str(@engine.add_sign_operators_key), Some("userB"))
  assert_eq(@engine.add_sign_history_of(a_row).length(), 1)

  // 复活档：B 这次没点人 ⇒ 直接流出本节点，不得凭空多建一条 review 待办
  let b = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(b.task_id, "userB", as_submit(1L))
  assert_eq(as_doing_count(repo, iid, "review"), 0, msg="上一轮的加签人不得复活")
  let _ = as_need(repo, iid, "final")
}

///|
/// 16 共享夹具 `flows/19-add-sign-after.json` 必须真被本栈消费——七语言仓 flows/ 是它的
/// 入库副本，各语言移植后加签读的就是这一份；没有生产者核对过的夹具会在传播轮里各改各的。
async test "addsign-16 共享夹具 19-add-sign-after 真跑通（逗号串两形）" {
  let (engine, repo) = make_compliance_engine()
  let content = load_flow("19-add-sign-after")
  let did = save_flow_define(repo, "addsign-19", content)
  let inst = engine.start_async(did, "applicant", new_args())
  let iid = inst.instance_id
  for t in repo.find_doing_tasks(iid, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", as_submit(0L))
    }
  }
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree("userB,userC"))
  assert_eq(as_doing_count(repo, iid, "review"), 2, msg="逗号串两形应建两行")
  assert_true(!as_has_doing(repo, iid, "final"))

  // 先取快照再逐条办结：办结会改写仓储里的进行中集合，边遍历边办是并发修改
  let ids : Array[(Int64, String)] = []
  for sib in repo.find_doing_tasks(iid, []) {
    ids.push((sib.task_id, as_first_actor(sib)))
  }
  for pair in ids {
    let _ = engine.execute_task_async(pair.0, pair.1, as_submit(1L))
  }
  let fin = as_need(repo, iid, "final")
  assert_eq(as_rows(repo, iid, "final"), 1, msg="同圈兄弟全部办结后应放行")
  let _ = engine.execute_task_async(fin.task_id, "userF", as_submit(1L))
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
}

// ── 本栈额外两格：语义边界与参数归一 ────────────────────────────────────────

///|
/// 17 加签链上「退回上一步」(3) **禁**（规范 04 · 语义边界，照会签先例）：
/// 当前行与其血缘 parent 同节点 ⇒ 既有 `can_rejected` 守卫不过 ⇒ 报固定文案。
/// ⚠️ 本栈这条腿的报错点排在办结之后（无事务模板可回滚，与 R86 记的同一条已知形状），
/// 故这一格只钉"报的是哪一条"＋"没把令牌推到下一节点"，不钉零写入。
async test "addsign-17 加签链上退回上一步被禁（同节点血缘，canRejected 守卫不过）" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-17", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree("userB"))
  let b = as_need(repo, iid, "review")
  let msg = try {
    let _ = engine.execute_and_jump_async(b.task_id, "userB", as_submit(3L), None)
    "<未报错>"
  } catch {
    e => e.message()
  }
  assert_eq(msg, "无法驳回至上一步处理，请确认上一步骤并非fork、join、suprocess以及会签任务")
  assert_true(!as_has_doing(repo, iid, "final"), msg="被禁的那次不得把令牌推到下一节点")
}

///|
/// 18 参数归一档（spec 06 §2.7 + §2.11 同一枚判据）：逗号串与数组两形等价；逐元素 trim、
/// 空元素丢弃、同一次调用内的重复折叠；**丢完为空＝没传**（不报错，按正常流转档放行出边）。
async test "addsign-18 加签人两形同判据：trim、空元素丢弃、丢完为空＝没传" {
  let (engine, repo) = make_compliance_engine()
  let iid = as_start_to_review(engine, repo, "addsign-18a", [allow_on])
  let a = as_need(repo, iid, "review")
  let _ = engine.execute_task_async(a.task_id, "userA", as_agree(" userB , , userC "))
  assert_eq(as_doing_count(repo, iid, "review"), 2, msg="空元素丢弃、trim 后同名折叠 ⇒ 同圈两行")
  let actors : Array[String] = []
  for t in repo.find_doing_tasks(iid, ["review"]) {
    for x in t.actor_ids {
      actors.push(x)
    }
  }
  assert_eq(actors, ["userB", "userC"])

  // 全空白＝没点人：走正常流转档，不报错也不要求节点开开关
  let (engine2, repo2) = make_compliance_engine()
  let iid2 = as_start_to_review_with_apply(engine2, repo2, "addsign-18b", [], [])
  let a2 = as_need(repo2, iid2, "review")
  let msg = as_exec_err(engine2, a2.task_id, "userA", as_agree(" , ,, "))
  assert_eq(msg, "<未报错>", msg="丢完为空＝没传，不该拦下正常办理")
  let _ = as_need(repo2, iid2, "final")
}
