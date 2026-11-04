// issues/246 已办撤回 ＋ issues/247 动态会签（征询模式）—— **门面端到端腿**（内存仓）。
//
// 判据与落库都在引擎（`core/engine/recall.mbt`／`core/engine/collect.mbt`，逐格语义见
// `core/engine/recall_test.mbt`／`core/engine/collect_test.mbt`）；本文件只钉门面这一侧三件事：
//   ① `dispatch` 两 case 真在表上（`processTask/recall`、`processTask/revokeDynamicCountersign`）；
//   ② `processTask/execute` 的分流／闸门位序（＝java `execute` 三段：分流→闸门→submitType 分发），
//      被闸门挡下的那一次**报错即零写入三面**（行状态、任务行总数、实例状态）；
//   ③ `processTask/detail` 的投影落点：`vo.ext.dynamicCountersign` 与成员行状态一致，
//      **未拉人时不写这一格**（java `tExt` 是活 Map、本栈 `obj_json` 是快照 ⇒ 必须重发一次 ext）。
//
// ⚠️ 出口层 C1（`transform_output` 递归把 `*Id` 键字符串化）在本栈对**全部**响应生效：
// 投影里 `actors[].taskId` 出的是串（java 那侧 `buildProjection` 出 Long）——这是本栈既有的
// 出口层形状，不是本轮引入；信封里 `processTaskId` 出串则与 java `String.valueOf` 逐字一致。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / parse_iid / doing_task_for / i159_args。
//
// 读数来源：本文件全部断言读**内存仓**（`@mem.MemoryRepository`），无真桶／无真库成分；
// "成员行数"一侧现读＝`@engine.collect_member_rows` 打在内存仓的仓储真相上（见 `i247_member_counts`）。
// 同轮真库腿（`repository-mysql/smoke` T1-M4/M6/M7/M8/M10）打在 160 的 MySQL `jeeflow` 库，
// 读数另档：`G:/dev-tools/tmp/2026-11-04-246-247-release/moon/t1-mysql-smoke-final.txt`。

///|
fn i247_task_node(id : String, assignee : String, extra : Array[(String, Json)], text : String) -> Json {
  let all : Array[(String, Json)] = []
  for pair in [
    ("form", @json.string_of("form-" + id)),
    ("assignee", @json.string_of(assignee)),
    ("taskType", @json.number_of(0L)),
    ("performType", @json.number_of(0L)),
  ] {
    all.push(pair)
  }
  for pair in extra {
    all.push(pair)
  }
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of("snaker:task")),
    ("properties", @json.object_of(all)),
    ("text", @json.object_of([("value", @json.string_of(text))])),
  ])
}

///|
fn i247_plain_node(id : String, node_type : String, text : String) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of(node_type)),
    ("properties", @json.object_of([])),
    ("text", @json.object_of([("value", @json.string_of(text))])),
  ])
}

///|
fn i247_edge(id : String, from : String, to : String) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of("snaker:transition")),
    ("sourceNodeId", @json.string_of(from)),
    ("targetNodeId", @json.string_of(to)),
    ("properties", @json.object_of([])),
  ])
}

///|
/// 五节点链 start→apply→review→final→end，`review_extra` 控制 review 的 properties
///（＝引擎侧夹具 `rc_chain` 同形；门面侧自带一份，避免跨模块依赖测试助手）
fn i247_flow(name : String, review_extra : Array[(String, Json)]) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("246/247 门面夹具")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        i247_plain_node("start", "snaker:start", "开始"),
        i247_task_node("apply", "applicant", [], "发起申请"),
        i247_task_node("review", "userA", review_extra, "审批"),
        i247_task_node("final", "userF", [], "终审"),
        i247_plain_node("end", "snaker:end", "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        i247_edge("e1", "start", "apply"),
        i247_edge("e2", "apply", "review"),
        i247_edge("e3", "review", "final"),
        i247_edge("e4", "final", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 装配：存定义 → `processInstance/startAndExecute`（自动办结申请节点）⇒ 令牌停在 review
async fn i247_setup(
  name : String, review_extra : Array[(String, Json)]
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name,
    display_name: name,
    define_type: "approval",
    state: 1,
    content: i247_flow(name, review_extra),
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
  assert_eq(code_of(env), 0L, msg="发起 code=0（实得 msg=\{msg_of(env)}）")
  (facade, repo, parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0")))
}

///|
/// 走门面的办理腿（extra 是 tf_ 协议键档，Json 值形态）
async fn i247_exec(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  submit_type : String,
  extra : Array[(String, Json)]
) -> Json raise {
  let all : Array[(String, Json)] = []
  for pair in [
    ("processTaskId", @json.string_of(task_id.to_string())),
    ("operator", @json.string_of(operator)),
    ("submitType", @json.string_of(submit_type)),
  ] {
    all.push(pair)
  }
  for pair in extra {
    all.push(pair)
  }
  facade.flow("processTask/execute", i159_args(all))
}

///|
/// `processTask/recall` 的参数档（两枚主键，缺失/空白各归各文案）
async fn i247_recall(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : String,
  operator : String
) -> Json raise {
  let entries : Array[(String, Json)] = [
    ("processTaskId", @json.string_of(task_id)), ("operator", @json.string_of(operator)),
  ]
  facade.flow("processTask/recall", i159_args(entries))
}

///|
/// 该节点名有没有 DOING 行
async fn i247_has_doing(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Bool raise {
  let mut found = false
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      found = true
    }
  }
  found
}

///|
/// 任务行总数（三面之一：报错前后必须一模一样）
async fn i247_rows(repo : @mem.MemoryRepository, iid : Int64) -> Int raise {
  repo.find_history_tasks(iid).length()
}

///|
/// detail 的 ext.dynamicCountersign（缺格时显式红——"没写这一格"本身由哨兵格判）
async fn i247_projection(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], task_id : Int64
) -> Json raise {
  let det = facade.flow(
    "processTask/detail", targs([("processTaskId", task_id.to_string()), ("operator", "userA")]),
  )
  assert_eq(code_of(det), 0L, msg="detail code=0（实得 msg=\{msg_of(det)}）")
  let ext = @json.get(data_of(det), "ext").unwrap()
  match @json.get(ext, "dynamicCountersign") {
    Some(p) => p
    None => abort("detail.ext 缺 dynamicCountersign 一格（成员行在册 ⇒ 这一格必须写）")
  }
}

///|
/// 现读成员行（＝投影那把尺子的独立一遍：`collect_member_rows` 后跳过 99）
/// `(在册数, 已交数)`。这一枚是"投影 total 与成员行数相等"那条判据的现读侧，
/// 不写死数字——写死的话投影恒返回 2 也会绿。
async fn i247_member_counts(
  repo : @mem.MemoryRepository, iid : Int64, host_id : Int64
) -> (Int, Int) raise {
  let host = repo.find_task_by_id(host_id).unwrap()
  let rows = @engine.collect_member_rows(repo.find_instance_by_id(iid).unwrap().tasks, host)
  let mut total = 0
  let mut submitted = 0
  for t in rows {
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
/// 哨兵：detail.ext 里**没有** dynamicCountersign 这一格
async fn i247_no_projection(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], task_id : Int64
) -> Bool raise {
  let det = facade.flow(
    "processTask/detail", targs([("processTaskId", task_id.to_string()), ("operator", "userA")]),
  )
  assert_eq(code_of(det), 0L, msg="detail code=0（实得 msg=\{msg_of(det)}）")
  let ext = @json.get(data_of(det), "ext").unwrap()
  @json.get(ext, "dynamicCountersign") is None
}

// ── 247 门面端到端 ──────────────────────────────────────────────────────────

///|
/// 带人提交出 marker → 闸门挡 agree(1) 与驳回(2) 的逐字文案＋零写入三面 → detail 投影 →
/// 撤回 action → 收齐后拍板推进。整条链一次跑通，钉的是门面位序（分流→闸门→分发）。
async test "i247 facade 端到端：marker→闸门（含驳回）→投影→撤回→拍板推进" {
  let on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))
  let (facade, repo, iid) = i247_setup("i247-e2e", [on])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(host.task_name, "review")
  let rows0 = i247_rows(repo, iid)
  // ① 带人提交＝征询发起腿（marker 直接出信封，主办行不办结）
  let env = i247_exec(
    facade, host.task_id, "userA", "1",
    [
      ("tf_addSignOperators", @json.array_of([@json.string_of("userX"), @json.string_of("userY")])),
      ("tf_addSignReason", @json.string_of("涉及地规划需两部门意见")),
    ],
  )
  assert_eq(code_of(env), 0L, msg="带人提交 code=0（实得 msg=\{msg_of(env)}）")
  let dc = @json.get(data_of(env), "dynamicCountersign").unwrap()
  assert_eq(@json.get_i64(dc, "round"), Some(1L))
  assert_eq(@json.get_i64(dc, "total"), Some(2L))
  assert_eq(@json.get_i64(dc, "submitted"), Some(0L))
  assert_true(
    repo.find_task_by_id(host.task_id).unwrap().is_doing(), msg="带人提交那一次不得办结主办行"
  )
  assert_eq(i247_rows(repo, iid), rows0 + 2, msg="点名两人 ⇒ 新建两行成员行")
  assert_true(!i247_has_doing(repo, iid, "final"), msg="主办不办结 ⇒ 下游不出待办")
  // ② 闸门：挡全部 submitType（这里跑通 agree 与 reject 两档，逐字同句）
  let blocked = i247_exec(facade, host.task_id, "userA", "1", [])
  assert_eq(code_of(blocked), 99999999L, msg="闸门挡下要出失败信封")
  assert_eq(msg_of(blocked), "节点[review]动态会签意见未收齐（已提交 0/2），不能办理")
  let rejected = i247_exec(facade, host.task_id, "userA", "2", [])
  assert_eq(
    msg_of(rejected), "节点[review]动态会签意见未收齐（已提交 0/2），不能办理",
    msg="驳回(2) 同样被挡 ⇒ 唯一出口＝processTask/revokeDynamicCountersign",
  )
  // ── 报错即零写入三面 ──
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing(), msg="三面之一：主办行状态不变")
  assert_eq(i247_rows(repo, iid), rows0 + 2, msg="三面之一：任务行总数不变")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="三面之一：实例状态不变")
  // ③ 成员行各自行提交意见（走普通 execute，闸门对成员行不带拉人参数一律放行）
  let x = doing_task_for(repo, iid, "userX")
  let y = doing_task_for(repo, iid, "userY")
  let x_env = i247_exec(facade, x.task_id, "userX", "1", [("tf_approvalComment", @json.string_of("甲部门意见"))])
  assert_eq(code_of(x_env), 0L, msg="成员行自己提交要放行（实得 msg=\{msg_of(x_env)}）")
  // detail 投影（未收齐档）
  let p = i247_projection(facade, host.task_id)
  assert_eq(@json.as_bool(@json.get(p, "active").unwrap()), Some(true), msg="还有未答成员 ⇒ active=true")
  assert_eq(@json.get_i64(p, "total"), Some(2L))
  assert_eq(@json.get_i64(p, "submitted"), Some(1L))
  assert_eq(@json.get_i64(p, "round"), Some(1L), msg="round 与成员行轮次戳同读数")
  let actors = @json.as_array(@json.get(p, "actors").unwrap()).unwrap()
  assert_eq(actors.length(), 2, msg="actors 逐行对上成员行")
  // 现读对拍（不写死）：投影 total/submitted ＝成员行在册/已交读数（承重判据二：99 不入册）
  let alive = i247_member_counts(repo, iid, host.task_id)
  assert_true(alive.0 > 0, msg="现读侧必须非空（否则 total 恒 0 也能绿）")
  assert_eq(@json.get_i64(p, "total"), Some(alive.0.to_int64()), msg="投影 total＝成员行在册数（现读）")
  assert_eq(@json.get_i64(p, "submitted"), Some(alive.1.to_int64()), msg="投影 submitted＝成员行已交数（现读）")
  // 出口层 C1：`*Id` 键字符串化 ⇒ 这里读串（java 那侧出 Long，见文件头注）
  assert_eq(@json.get_str(actors[0], "taskId"), Some(x.task_id.to_string()))
  assert_eq(@json.get_str(actors[1], "taskId"), Some(y.task_id.to_string()))
  assert_eq(@json.get_str(actors[0], "actor"), Some("userX"))
  assert_eq(@json.get_str(actors[1], "actor"), Some("userY"))
  assert_eq(@json.get_i64(actors[0], "state"), Some(@model.TaskState::Finished.code().to_int64()), msg="已交成员行投影 state=20")
  assert_eq(@json.get_i64(actors[1], "state"), Some(@model.TaskState::Doing.code().to_int64()), msg="未答成员行投影 state=10")
  // ④ 撤回 action：非参与者先拦（承重判据三从门面出口再读一遍）＋零写入三面
  let rows_before_revoke = i247_rows(repo, iid)
  let denied = facade.flow(
    "processTask/revokeDynamicCountersign",
    targs([("processTaskId", host.task_id.to_string()), ("operator", "userZ")]),
  )
  assert_eq(code_of(denied), 99999999L, msg="非参与者撤回要出失败信封（实得 msg=\{msg_of(denied)}）")
  assert_eq(msg_of(denied), "无权限撤回该动态会签")
  assert_eq(i247_rows(repo, iid), rows_before_revoke, msg="三面之一：任务行总数不变")
  assert_true(
    repo.find_task_by_id(y.task_id).unwrap().is_doing(), msg="三面之一：未答成员行状态不变"
  )
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="三面之一：实例状态不变")
  //    合法撤回：撤未答、已交保留、99 行退出在册
  let rv = facade.flow(
    "processTask/revokeDynamicCountersign",
    targs([
      ("processTaskId", host.task_id.to_string()), ("operator", "userA"), ("reason", "部门选错重新拉"),
    ]),
  )
  assert_eq(code_of(rv), 0L, msg="撤回 code=0（实得 msg=\{msg_of(rv)}）")
  assert_eq(@json.get_i64(data_of(rv), "revoked"), Some(1L), msg="只撤未答那一条")
  let revoked_actors = @json.as_array(@json.get(data_of(rv), "actors").unwrap()).unwrap()
  assert_eq(revoked_actors.map(fn(v) { @json.as_str(v).unwrap_or("<非串>") }), ["userY"])
  assert_eq(repo.find_task_by_id(y.task_id).unwrap().task_state, @model.TaskState::Abandon.code())
  assert_true(repo.find_task_by_id(x.task_id).unwrap().is_finished(), msg="已交意见行原样保留")
  assert_eq(i247_rows(repo, iid), rows0 + 2, msg="撤回复用废弃腿 ⇒ 不新建任务行")
  // 撤回后的投影：99 行既不进在册也不进 actors（承重判据二，从门面出口再读一遍）
  let p2 = i247_projection(facade, host.task_id)
  let alive2 = i247_member_counts(repo, iid, host.task_id)
  assert_eq(@json.get_i64(p2, "total"), Some(alive2.0.to_int64()), msg="投影 total＝成员行在册数（现读，撤回清场那行不入册）")
  assert_eq(@json.get_i64(p2, "submitted"), Some(alive2.1.to_int64()), msg="投影 submitted＝成员行已交数（现读）")
  assert_eq(@json.get_i64(p2, "total"), Some(1L), msg="撤回清场那行不得算在册（现读数＝1）")
  assert_eq(@json.get_i64(p2, "submitted"), Some(1L))
  assert_eq(@json.as_bool(@json.get(p2, "active").unwrap()), Some(false))
  assert_eq(@json.as_array(@json.get(p2, "actors").unwrap()).unwrap().length(), 1)
  // ⑤ 拍板推进
  let go = i247_exec(facade, host.task_id, "userA", "1", [])
  assert_eq(code_of(go), 0L, msg="闸门恢复后主办拍板要放行（实得 msg=\{msg_of(go)}）")
  assert_true(i247_has_doing(repo, iid, "final"), msg="拍板后流出到 final")
  // 撤回参数档（operator 硬必填，严禁回落 demo 缺省 user1）
  let bad = facade.flow("processTask/revokeDynamicCountersign", targs([("processTaskId", host.task_id.to_string())]))
  assert_eq(msg_of(bad), "operator 必填")
  let bad2 = facade.flow("processTask/revokeDynamicCountersign", targs([("operator", "userA")]))
  assert_eq(msg_of(bad2), "processTaskId 缺失")
}

///|
/// 哨兵两档：征询节点**没拉过人**时 detail 不写 dynamicCountersign 一格（前端据此不置灰）；
/// 普通节点同样不得出现这一格（闸门/投影不得在非征询节点上留下任何痕迹）。
async test "i247 facade 哨兵：无成员行与非征询节点都不写 dynamicCountersign 一格" {
  let on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))
  let (facade, repo, iid) = i247_setup("i247-sentinel", [on])
  let host = doing_task_for(repo, iid, "userA")
  assert_true(i247_no_projection(facade, host.task_id), msg="主办行无成员行 ⇒ ext 不写这一格")
  // 反向：带人之后立刻出现（同一枚判据的两面）
  let _ = i247_exec(facade, host.task_id, "userA", "1", [("tf_addSignOperators", @json.array_of([@json.string_of("userX")]))])
  assert_true(!i247_no_projection(facade, host.task_id), msg="拉过人之后这一格必须写出来")
  // 非征询节点：普通办理腿走完，detail 也不得出现这一格
  let (facade2, repo2, iid2) = i247_setup("i247-plain", [])
  let host2 = doing_task_for(repo2, iid2, "userA")
  assert_true(i247_no_projection(facade2, host2.task_id), msg="非征询节点不得写这一格")
  let e = i247_exec(facade2, host2.task_id, "userA", "1", [])
  assert_eq(code_of(e), 0L, msg="非征询节点走普通流转（实得 msg=\{msg_of(e)}）")
  assert_true(i247_has_doing(repo2, iid2, "final"))
}

// ── 246 门面端到端 ──────────────────────────────────────────────────────────

///|
/// `processTask/recall` 信封形状（data={processTaskId 串, taskState=10}）＋参数档＋非参与者
/// 零写入三面＋重办可推进。判据细节在引擎侧 recall_test，本格只钉门面这一跳。
async test "i246 facade 端到端：recall 信封 data 形状＋参数档＋非参与者零写入三面" {
  let on : (String, Json) = ("allowRecall", @json.bool_of(true))
  let (facade, repo, iid) = i247_setup("i246-e2e", [on])
  let review = doing_task_for(repo, iid, "userA")
  let done = i247_exec(facade, review.task_id, "userA", "1", [])
  assert_eq(code_of(done), 0L, msg="办结 review（实得 msg=\{msg_of(done)}）")
  let old = repo.find_task_by_id(review.task_id).unwrap()
  assert_true(old.is_finished())
  let rows0 = i247_rows(repo, iid)
  let rid = review.task_id.to_string()
  // ── 参数档（主键档缺失响亮报错） ──
  let no_op = facade.flow("processTask/recall", targs([("processTaskId", rid)]))
  assert_eq(code_of(no_op), 99999999L)
  assert_eq(msg_of(no_op), "operator 必填")
  let no_id = facade.flow("processTask/recall", targs([("operator", "userA")]))
  assert_eq(msg_of(no_id), "processTaskId 缺失")
  // 纯空白 operator 也算"必填"（严禁回落 demo 缺省 user1）
  assert_eq(msg_of(i247_recall(facade, rid, "  ")), "operator 必填")
  // ── 非参与者：逐字文案＋零写入三面 ──
  let denied = i247_recall(facade, rid, "userZ")
  assert_eq(msg_of(denied), "无权限撤回该任务")
  assert_true(repo.find_task_by_id(review.task_id).unwrap().is_finished(), msg="三面之一：目标行状态不变")
  assert_eq(i247_rows(repo, iid), rows0, msg="三面之一：任务行总数不变")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="三面之一：实例状态不变")
  // ── 合法撤回：信封 data 形状 ──
  let ok = i247_recall(facade, rid, "userA")
  assert_eq(code_of(ok), 0L, msg="撤回 code=0（实得 msg=\{msg_of(ok)}）")
  let data = data_of(ok)
  let new_id_str = @json.get_str(data, "processTaskId").unwrap_or("<缺>")
  assert_eq(
    @json.get_i64(data, "taskState"), Some(@model.TaskState::Doing.code().to_int64()),
    msg="data.taskState=10（DOING）",
  )
  assert_true(
    new_id_str != "<缺>" && new_id_str != "", msg="data.processTaskId 须是字符串化的复活行 id，实得 \{new_id_str}"
  )
  assert_eq(i247_rows(repo, iid), rows0 + 1, msg="撤回＝新建一行（find_history_tasks 含 DOING ⇒ 合法读数 +1）")
  let revived = repo.find_task_by_id(parse_iid(new_id_str)).unwrap()
  assert_eq(revived.task_name, "review")
  assert_true(revived.is_doing(), msg="复活行是待办")
  assert_true(revived.actor_ids.contains("userA"), msg="名册照旧＝原行名册")
  assert_true(parse_iid(new_id_str) != review.task_id, msg="复活行是新行，不是原行改态")
  // 原行仍 FINISHED，账本落在原行上（从门面出口那一读：ext 里带 tf_recallHistory）
  let det = facade.flow(
    "processTask/detail", targs([("processTaskId", rid), ("operator", "userA")]),
  )
  assert_eq(code_of(det), 0L, msg="detail code=0（实得 msg=\{msg_of(det)}）")
  let ext = @json.get(data_of(det), "ext").unwrap()
  let ledger = @json.as_array(@json.get(ext, "tf_recallHistory").unwrap()).unwrap()
  assert_eq(ledger.length(), 1, msg="detail.ext 读回的账本一行")
  assert_eq(@json.get_str(ledger[0], "operator"), Some("userA"))
  // 出口层 C1：*Id 键字符串化 ⇒ recalledTaskId 出串，与 data.processTaskId 同形
  assert_eq(@json.get_str(ledger[0], "recalledTaskId"), Some(new_id_str))
  // 重办推进
  let redo = i247_exec(facade, revived.task_id, "userA", "1", [])
  assert_eq(code_of(redo), 0L, msg="复活行可正常办理（实得 msg=\{msg_of(redo)}）")
  assert_true(i247_has_doing(repo, iid, "final"), msg="重办后令牌回到 final")
  // 非已完成档（final 那行还 DOING）：逐字文案
  let fin = doing_task_for(repo, iid, "userF")
  let too_early = i247_recall(facade, fin.task_id.to_string(), "userF")
  assert_eq(msg_of(too_early), "任务非已完成状态，不可撤回")
  // 实例已办结之后再撤 review 原行 ⇒ 实例非进行中档
  let _ = i247_exec(facade, fin.task_id, "userF", "1", [])
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20, msg="实例应已办结")
  let late = i247_recall(facade, rid, "userA")
  assert_eq(msg_of(late), "流程实例非进行中状态，不可撤回")
}

///|
/// `dispatch` 表自证：两枚新 action 真在分派表上（未注册会回 "未知 action"），
/// 且未开开关／无待答／行不存在三档都报各自的逐字文案（不是未知档）。
async test "i246/247 dispatch 自证：两枚 action 在表上，未走未知档" {
  let (facade, repo, iid) = i247_setup("i246-dispatch", [])
  let review = doing_task_for(repo, iid, "userA")
  let rid = review.task_id.to_string()
  // 未知 action 的既有档（哨兵：确认下面几次不是打在未知档上"看起来报错"）
  let unknown = facade.flow("processTask/notAnAction", targs([("operator", "userA")]))
  assert_eq(code_of(unknown), 99999999L)
  assert_eq(msg_of(unknown), "未知 action: processTask/notAnAction")
  // recall：未开 allowRecall 的普通节点 ⇒ 报的是开关档（**节点 id 档**文案，非 display_name「审批」）
  let done = i247_exec(facade, review.task_id, "userA", "1", [])
  assert_eq(code_of(done), 0L, msg="办结普通节点（实得 msg=\{msg_of(done)}）")
  let off = i247_recall(facade, rid, "userA")
  assert_eq(msg_of(off), "节点[review]未开启 allowRecall，不能撤回")
  assert_true(!msg_of(off).contains("审批"), msg="文案取节点 id 档，实得 \{msg_of(off)}")
  // revokeDynamicCountersign：普通节点上报"没有进行中的动态会签"，同样不是未知档
  let none = facade.flow(
    "processTask/revokeDynamicCountersign", targs([("processTaskId", rid), ("operator", "userA")]),
  )
  assert_eq(msg_of(none), "节点[review]没有进行中的动态会签")
  let missing = facade.flow(
    "processTask/revokeDynamicCountersign", targs([("processTaskId", "987654"), ("operator", "userA")]),
  )
  assert_eq(msg_of(missing), "任务不存在")
  // 参数档与 recall 同一把尺子
  assert_eq(
    msg_of(facade.flow("processTask/revokeDynamicCountersign", targs([("operator", "userA")]))),
    "processTaskId 缺失",
  )
}
