// 「已办撤回（recall）」验收（黑盒 async test，内存仓）——移植 java `RecallTest` 的 9 格。
//
// 契约面（spec 02 §4.4 ＋ spec 04「已办撤回」＋ spec 06 §processTask/recall ＋ spec 11 码 10）：
//   · 节点开关 `allowRecall`（缺省关）；会签节点／首任务节点配它＝**解析期**报错（逐字两档文案）；
//   · 五道判据位序逐字照 java，全部排在状态变更之前 ⇒ **报错即零写入三面**：
//     目标行状态不变、任务行总数不变、实例状态不变（每格负向都真断言这三面）；
//   · 窗口宽口径＝沿 `task_parent_id` 链的全部下游行中**不存在任何 FINISHED**；
//   · 动作三件：下游 DOING 全废弃（后加签续建行／并行分支多支天然覆盖）＋原 FINISHED 行**不改写**
//     只追加 `tf_recallHistory{operator,time,recalledTaskId}`＋同节点新行 DOING
//     （名册＝原行名册、parent＝**原行的 parent**、fire 码 3）；
//   · 事件：`TASK_RECALL`(10)，sourceId＝被撤回的旧行，**只发 10 不补发 5/6**。
//
// 夹具：本文件用**内联 JSON**（`rc_flow_json`）——共享 flows 目录那条腿另有归属（十仓镜像与漂移
// 门禁），本轮不碰 `flows/`。同包 helper 复用 `compliance_test.mbt` 的
// make_compliance_engine / save_flow_define / new_args；`add_sign_test.mbt` 里那批 `as_*` 助手
// 与 `task_props`／`as_node`／`as_edge` 在本包已被占用，故本文件的夹具助手一律 `rc_` 前缀。

///|
/// 提交参数（只带 submitType）
fn rc_submit(t : Int64) -> @json.FlowData {
  let a = @json.FlowData::new()
  a.insert("submitType", @json.number_of(t))
  a
}

///|
/// 同意（1）
fn rc_agree() -> @json.FlowData {
  rc_submit(1L)
}

///|
/// 同意并点名加签人（交叉格用：后加签续建行属下游 DOING）
fn rc_agree_add_sign(ops : String) -> @json.FlowData {
  let a = rc_agree()
  a.insert(@engine.add_sign_operators_key, @json.string_of(ops))
  a
}

///|
/// 节点 properties：四枚固定键 + 追加档（同键后写覆盖前写）
fn rc_props(assignee : String, perform : Int64, extra : Array[(String, Json)]) -> Array[(String, Json)] {
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
fn rc_node(id : String, node_type : String, props : Array[(String, Json)], text : String) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of(node_type)),
    ("properties", @json.object_of(props)),
    ("text", @json.object_of([("value", @json.string_of(text))])),
  ])
}

///|
fn rc_task(id : String, assignee : String, extra : Array[(String, Json)], text : String) -> Json {
  rc_node(id, "snaker:task", rc_props(assignee, 0L, extra), text)
}

///|
fn rc_edge(id : String, from : String, to : String) -> Json {
  @json.object_of([
    ("id", @json.string_of(id)),
    ("type", @json.string_of("snaker:transition")),
    ("sourceNodeId", @json.string_of(from)),
    ("targetNodeId", @json.string_of(to)),
    ("properties", @json.object_of([])),
  ])
}

///|
/// 通用五节点链：start→apply→review→final→end（`review_extra` 控制 review 的 properties）。
/// ＝java `RecallTest#chain` 同形。
fn rc_chain(name : String, review_extra : Array[(String, Json)]) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("已办撤回夹具")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        rc_node("start", "snaker:start", [], "开始"),
        rc_task("apply", "applicant", [], "发起申请"),
        rc_task("review", "userA", review_extra, "审批"),
        rc_task("final", "userF", [], "终审"),
        rc_node("end", "snaker:end", [], "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        rc_edge("e1", "start", "apply"),
        rc_edge("e2", "apply", "review"),
        rc_edge("e3", "review", "final"),
        rc_edge("e4", "final", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 同上，但申请节点也带追加档（首任务节点配 allowRecall 那一格）
fn rc_chain_with_apply(name : String, apply_extra : Array[(String, Json)], review_extra : Array[(String, Json)]) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("已办撤回夹具")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        rc_node("start", "snaker:start", [], "开始"),
        rc_task("apply", "applicant", apply_extra, "发起申请"),
        rc_task("review", "userA", review_extra, "审批"),
        rc_task("final", "userF", [], "终审"),
        rc_node("end", "snaker:end", [], "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        rc_edge("e1", "start", "apply"),
        rc_edge("e2", "apply", "review"),
        rc_edge("e3", "review", "final"),
        rc_edge("e4", "final", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 六节点链：start→apply→review→final→pay→end，供"下游已办结"窗口档（＝java `chainDeep`）
fn rc_chain_deep(name : String, review_extra : Array[(String, Json)]) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("已办撤回深链")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        rc_node("start", "snaker:start", [], "开始"),
        rc_task("apply", "applicant", [], "发起申请"),
        rc_task("review", "userA", review_extra, "审批"),
        rc_task("final", "userF", [], "终审"),
        rc_task("pay", "userP", [], "支付"),
        rc_node("end", "snaker:end", [], "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        rc_edge("e1", "start", "apply"),
        rc_edge("e2", "apply", "review"),
        rc_edge("e3", "review", "final"),
        rc_edge("e4", "final", "pay"),
        rc_edge("e5", "pay", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 并行双支：review 出两条边到 payA/payB，各自汇入 end（＝java `chainFork`）
fn rc_chain_fork(name : String, review_extra : Array[(String, Json)]) -> String {
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("已办撤回并行")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        rc_node("start", "snaker:start", [], "开始"),
        rc_task("apply", "applicant", [], "发起申请"),
        rc_task("review", "userA", review_extra, "审批"),
        rc_task("payA", "userPA", [], "支付甲"),
        rc_task("payB", "userPB", [], "支付乙"),
        rc_node("end", "snaker:end", [], "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        rc_edge("e1", "start", "apply"),
        rc_edge("e2", "apply", "review"),
        rc_edge("e3", "review", "payA"),
        rc_edge("e4", "review", "payB"),
        rc_edge("e5", "payA", "end"),
        rc_edge("e6", "payB", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 发起并办结申请节点 ⇒ 令牌停在 review，返回实例 id
async fn rc_start_to_review(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  name : String,
  flow_json : String
) -> Int64 raise {
  let did = save_flow_define(repo, name, flow_json)
  let inst = engine.start_async(did, "applicant", new_args())
  for t in repo.find_doing_tasks(inst.instance_id, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", rc_submit(0L))
    }
  }
  inst.instance_id
}

///|
/// 该节点名的第一条 DOING 行
async fn rc_doing(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask? raise {
  // 取**第一条**匹配行（＝java `RecallTest#doing` 的 return-in-loop 语义）：
  // 撤回后本节点同时留着旧行与复活行，取最后一条会把"复活行"读成"旧行"。
  let rows = repo.find_doing_tasks(iid, []).filter(fn(t) { t.task_name == name })
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
/// 必须有该节点的 DOING 行（没有就显式红，不许被读成"另一件事"）
async fn rc_need(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask raise {
  match rc_doing(repo, iid, name) {
    Some(t) => t
    None => abort("期望存在 \"\{name}\" 的 DOING 行，实例 \{iid}")
  }
}

///|
async fn rc_has_doing(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Bool raise {
  match rc_doing(repo, iid, name) {
    Some(_) => true
    None => false
  }
}

///|
/// 该节点名的 DOING 行数
async fn rc_doing_count(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 该节点名的任务行总数（含已完成/废弃/撤回行——零写入三面之一）
async fn rc_rows(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_history_tasks(iid) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 实例的全部任务行总数（零写入三面：报错前后必须一模一样）
async fn rc_all_rows(repo : @mem.MemoryRepository, iid : Int64) -> Int raise {
  repo.find_history_tasks(iid).length()
}

///|
/// 该节点名的第一条 FINISHED 行
async fn rc_finished(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask raise {
  let rows = repo.find_history_tasks(iid).filter(fn(t) { t.task_name == name && t.is_finished() })
  if rows.is_empty() {
    abort("期望存在 \"\{name}\" 的 FINISHED 行，实例 \{iid}")
  } else {
    rows[0]
  }
}

///|
/// 该节点名的第一条行（不按状态滤——撤回后的下游行是 ABANDON(99)，不走 FINISHED）
async fn rc_any_row(repo : @mem.MemoryRepository, iid : Int64, name : String) -> @model.ProcessTask raise {
  let rows = repo.find_history_tasks(iid).filter(fn(t) { t.task_name == name })
  if rows.is_empty() {
    abort("期望存在 \"\{name}\" 的任务行，实例 \{iid}")
  } else {
    rows[0]
  }
}

///|
/// 撤回账本（读回的是**仓储里那一行**，不是引擎返回的那个聚合对象）
async fn rc_ledger(
  repo : @mem.MemoryRepository, task_id : Int64
) -> Array[Json] raise {
  match repo.find_task_by_id(task_id) {
    Some(row) => @engine.recall_history_of(row)
    None => abort("任务行 \{task_id} 读不回来")
  }
}

///|
/// recall 入口的报错文案（没报错返回哨兵串 ⇒ 读成一条独立的红）
async fn rc_recall_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String
) -> String {
  try {
    let _ = engine.recall_task_async(task_id, operator)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 解析期报错文案
fn rc_parse_err(flow_json : String) -> String {
  try {
    let _ = @parser.parse_model(flow_json)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 全生态时间格式 `yyyy-MM-dd HH:mm:ss` 的形状判据（与 `add_sign_test.mbt` 同一把尺子；
/// 刻意不注入时钟——注入槽是进程级全局可变的，用例之间会互盖）
fn rc_is_eco_time(s : String) -> Bool {
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
/// 01 ＝java `recallRevivesAbandonsDownstreamAndAllowsRedo`：办结→撤回→原行留账本、
/// 复活行名册照旧、下游废弃、重办后再推进。
async test "recall-01 复活三件套：原行留账本＋下游废弃＋复活行名册照旧，重办可推进" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let iid = rc_start_to_review(engine, repo, "recall-01", rc_chain("recall-01", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let old_review = rc_finished(repo, iid, "review")
  assert_true(rc_has_doing(repo, iid, "final"), msg="同意应把令牌推到 final")
  // 三面口径写死（iter3 恢复，根因见下方 419 行注）：`rc_all_rows`＝`find_history_tasks`，
  // **含仍 DOING 的行**（本仓 memory.mbt:244 不按状态滤）。合法撤回的读数是 **＋1**
  // ——复活行**另起一行**、不覆盖原行；`rows_before` 只用于"报错即零写入"的负向三面，
  // 在这一格用 +1 是这一不变量本身，不是把期望改成 1。
  let rows_before = rc_all_rows(repo, iid)
  let resurrected = engine.recall_task_async(old_review.task_id, "userA")

  assert_eq(resurrected.task_name, "review")
  assert_true(resurrected.is_doing(), msg="复活行必须是 DOING")
  assert_true(resurrected.actor_ids.contains("userA"), msg="名册照旧＝原行名册")
  assert_eq(
    rc_all_rows(repo, iid), rows_before + 1,
    msg="撤回＝新建一行（find_history_tasks 含 DOING ⇒ 合法读数是 +1，不是不变也不是 +2）",
  )
  // parent＝**原行的 parent**（不是原行 id：原地顶替，不成二元环）
  assert_eq(resurrected.parent_task_id, old_review.parent_task_id)
  assert_true(resurrected.parent_task_id != Some(old_review.task_id), msg="复活行不得挂在原行下面")
  // 下游废弃
  let final_row = rc_any_row(repo, iid, "final")
  assert_eq(final_row.task_state, @model.TaskState::Abandon.code())
  assert_eq(rc_doing_count(repo, iid, "final"), 0)
  // 原行不改写＋账本指向复活行
  let old_row = rc_any_row(repo, iid, "review")
  let old_again = repo.find_task_by_id(old_review.task_id).unwrap()
  assert_true(old_again.is_finished(), msg="原 FINISHED 行一律不改写（任务行即审批历史）")
  let ledger = rc_ledger(repo, old_review.task_id)
  assert_eq(ledger.length(), 1, msg="账本一行")
  assert_eq(@json.as_str(@json.get(ledger[0], "operator").unwrap()), Some("userA"))
  assert_eq(
    @json.as_i64(@json.get(ledger[0], "recalledTaskId").unwrap()), Some(resurrected.task_id)
  )
  let time0 = @json.as_str(@json.get(ledger[0], "time").unwrap()).unwrap()
  assert_true(rc_is_eco_time(time0), msg="时间须是全生态格式串 yyyy-MM-dd HH:mm:ss")
  // 复活行是全实例唯一活待办
  assert_eq(rc_doing_count(repo, iid, "review"), 1)
  // ── 本轮 iter2 那枚红（`10 != 20`）的根因钉子：两条候选口径**都**在这里钉死，不留"改期望变绿"的缝 ──
  // 读数是 DOING(10) vs FINISHED(20) ⇒ 报的是"原行仍 FINISHED"那一格读到了**复活行**：
  // `rc_any_row` 走 `find_history_tasks`（按 task_id 升序）取**第一条**＝原行；取末位就把复活行
  // 读成原行。引擎那一侧本来没错——原行不改写另有上一段 `find_task_by_id(old_review.task_id)`
  // 那一格直接钉着（不依赖任何取行次序）。另一半口径（任务行总数）在同一格读成 **+1**
  // （见本文件上方 rows_before 那一格），两半都不许被读成"顶替原行、总数不变"。
  assert_true(
    old_review.task_id < resurrected.task_id,
    msg="建单 id 单调 ⇒ 升序第一条必是原行；读岔成末位就是把复活行当原行（iter2 那枚红的根因）",
  )
  assert_eq(old_row.task_state, @model.TaskState::Finished.code(), msg="升序第一条＝原行，须仍 FINISHED")
  assert_eq(rc_finished(repo, iid, "review").task_id, old_review.task_id, msg="按状态滤也得指向同一行")
  // 正向断言：撤回是"同节点新建一行"，不是把原行改回 DOING ⇒ 账上两行都留着
  assert_eq(rc_rows(repo, iid, "review"), 2, msg="原行(20)＋复活行(10) 两行都在账上（撤回＝新建，非改写）")
  assert_eq(
    as_rows_with_state(repo, iid, "review", @model.TaskState::Finished.code()), 1,
    msg="FINISHED 的 review 行只有一条＝原行",
  )
  assert_eq(
    as_rows_with_state(repo, iid, "review", @model.TaskState::Doing.code()), 1,
    msg="DOING 的 review 行只有一条＝复活行",
  )
  // 实例仍进行中，重办后再推进
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  let _ = engine.execute_task_async(resurrected.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
  assert_eq(rc_rows(repo, iid, "final"), 2, msg="重办后 final 再建一行，废弃那行仍留史")
  assert_eq(
    rc_rows(repo, iid, "review"), 2,
    msg="重办走的是复活行那一手，不再多建 review 行（撤回腿新建的那一行就是它办的）",
  )
}

///|
/// 02 ＝java `recallBlockedWhenDownstreamFinishedWithZeroWrite`：窗口宽口径的另一面——
/// 下游 final 已办结 ⇒ 逐字文案报错**且零写入三面**（原行状态、任务行总数、实例状态）。
async test "recall-02 下游已办结拦：逐字文案＋报错零写入三面" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let iid = rc_start_to_review(engine, repo, "recall-02", rc_chain_deep("recall-02", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let fin = rc_need(repo, iid, "final")
  let _ = engine.execute_task_async(fin.task_id, "userF", rc_agree())
  let old_review = rc_finished(repo, iid, "review")
  assert_true(rc_has_doing(repo, iid, "pay"), msg="窗口判据要看得到 pay 那条 DOING 下游")

  let rows_before = rc_all_rows(repo, iid)
  let msg = rc_recall_err(engine, old_review.task_id, "userA")
  assert_eq(msg, "任务[review]的后续节点已办理，不能撤回")
  // ── 零写入三面 ──
  assert_true(
    repo.find_task_by_id(old_review.task_id).unwrap().is_finished(),
    msg="报错即零写入：目标行状态不变（仍 FINISHED）",
  )
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变（没复活行）")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="报错即零写入：实例状态不变")
  assert_eq(rc_ledger(repo, old_review.task_id).length(), 0, msg="报错那次不得记账本")
  // 下游原样：final 仍 FINISHED、pay 仍 DOING、review 无待办
  assert_true(rc_finished(repo, iid, "final").is_finished())
  assert_true(rc_has_doing(repo, iid, "pay"))
  assert_eq(rc_doing_count(repo, iid, "review"), 0)
  // 窗口档报的是**被撤回那行的节点名**，不是撞见 FINISHED 的下游行名
  assert_true(!msg.contains("final"), msg="文案里不得出现下游节点名: \{msg}")
}

///|
/// 03 ＝java `recallAbandonsAddSignRowsToo`：后加签续建行属下游 DOING ⇒ 连带废弃，不留孤儿待办；
/// 复活后照常推进（无兄弟待办 ⇒ merged 出边）。
async test "recall-03 后加签续建行属下游 DOING：连带废弃且复活行可正常推进" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [
    ("allowRecall", @json.bool_of(true)),
    ("allowAddSign", @json.bool_of(true)),
  ]
  let iid = rc_start_to_review(engine, repo, "recall-03", rc_chain("recall-03", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree_add_sign("userX"))
  let add_sign_row = rc_need(repo, iid, "review")
  assert_true(add_sign_row.actor_ids.contains("userX"), msg="加签行应在 review 节点续办")
  let old_review = rc_finished(repo, iid, "review")

  let _ = engine.recall_task_async(old_review.task_id, "userA")

  assert_eq(
    repo.find_task_by_id(add_sign_row.task_id).unwrap().task_state,
    @model.TaskState::Abandon.code(),
    msg="加签行属下游 DOING，须连带废弃",
  )
  assert_eq(rc_doing_count(repo, iid, "review"), 1, msg="复活行是节点上唯一 DOING")
  let revived = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(revived.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
}

///|
/// 04 ＝java `recallAbandonsBothForkBranches`：并行分支两支全部废弃。
async test "recall-04 并行分支：撤回后两支下游全部废弃" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let iid = rc_start_to_review(engine, repo, "recall-04", rc_chain_fork("recall-04", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  assert_true(rc_has_doing(repo, iid, "payA"), msg="两支并行待办都在")
  assert_true(rc_has_doing(repo, iid, "payB"))
  let old_review = rc_finished(repo, iid, "review")

  let _ = engine.recall_task_async(old_review.task_id, "userA")

  assert_eq(
    rc_any_row(repo, iid, "payA").task_state, @model.TaskState::Abandon.code(), msg="甲支废弃"
  )
  assert_eq(
    rc_any_row(repo, iid, "payB").task_state, @model.TaskState::Abandon.code(), msg="乙支废弃"
  )
  assert_eq(rc_doing_count(repo, iid, "review"), 1)
  assert_eq(rc_doing_count(repo, iid, "payA"), 0)
  assert_eq(rc_doing_count(repo, iid, "payB"), 0)
}

///|
/// 05 ＝java `recallPermissionAndNotFinishedGuards`：非参与者拦（逐字）、`flow.admin` 特权放行、
/// 未办结行拦（逐字）。
async test "recall-05 参与人按名册判＋特权放行＋进行中行拦（报错零写入）" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let iid = rc_start_to_review(engine, repo, "recall-05", rc_chain("recall-05", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let old_review = rc_finished(repo, iid, "review")
  let rows_before = rc_all_rows(repo, iid)

  // 非参与者：⚠️ 判据按**名册**（actor_ids），不能借只认 DOING 行的 is_allowed——
  // 目标行正是 FINISHED，用 is_allowed 会把每一次合法撤回都判成无权。
  let msg = rc_recall_err(engine, old_review.task_id, "userZ")
  assert_eq(msg, "无权限撤回该任务")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变")
  assert_eq(rc_ledger(repo, old_review.task_id).length(), 0)

  // flow.admin 特权放行（大小写不敏感，与转办/摘人同口径）
  let resurrected = engine.recall_task_async(old_review.task_id, "flow.admin")
  assert_true(resurrected.is_doing())

  // 未办结行拦（复活行还没办结）
  let msg2 = rc_recall_err(engine, resurrected.task_id, "userA")
  assert_eq(msg2, "任务非已完成状态，不可撤回")
  assert_true(
    repo.find_task_by_id(resurrected.task_id).unwrap().is_doing(),
    msg="报错即零写入：DOING 行状态不变"
  )
}

///|
/// 06 ＝java `recallBlockedWhenSwitchOff`：开关未开 ⇒ 逐字文案（读回原行仍 FINISHED、零复活行）。
async test "recall-06 节点未开 allowRecall 拦：逐字文案＋零写入" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "recall-06", rc_chain("recall-06", []))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let old_review = rc_finished(repo, iid, "review")
  let rows_before = rc_all_rows(repo, iid)

  let msg = rc_recall_err(engine, old_review.task_id, "userA")
  assert_eq(msg, "节点[review]未开启 allowRecall，不能撤回")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变")
  assert_eq(rc_doing_count(repo, iid, "review"), 0, msg="报错即零写入：不得凭空复活一行")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  assert_eq(rc_ledger(repo, old_review.task_id).length(), 0)
}

///|
/// 07 ＝java `recallBlockedWhenInstanceFinished`：实例已走完 ⇒ 实例非进行中档。
async test "recall-07 实例已结束拦：流程实例非进行中状态，不可撤回" {
  let (engine, repo) = make_compliance_engine()
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let iid = rc_start_to_review(engine, repo, "recall-07", rc_chain("recall-07", extra))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let fin = rc_need(repo, iid, "final")
  let _ = engine.execute_task_async(fin.task_id, "userF", rc_agree())
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20, msg="实例应已办结")
  let old_review = rc_finished(repo, iid, "review")

  let msg = rc_recall_err(engine, old_review.task_id, "userA")
  assert_eq(msg, "流程实例非进行中状态，不可撤回")
  assert_eq(rc_ledger(repo, old_review.task_id).length(), 0)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20, msg="报错即零写入：实例状态不变")
}

// ── 解析期硬校验（规范 02 §4.4） ────────────────────────────────────────────

///|
/// 08 ＝java `parseBansAllowRecallOnCountersignAndApplyNodes`：会签节点／首任务节点配
/// `allowRecall` 一律解析期报错（不做运行时降级）。
async test "recall-08 解析期禁配：会签节点与首任务节点配 allowRecall 报错" {
  let cs_extra : Array[(String, Json)] = [
    ("allowRecall", @json.bool_of(true)),
    ("performType", @json.number_of(1L)),
    ("countersignType", @json.string_of("PARALLEL")),
  ]
  let m1 = rc_parse_err(rc_chain("recall-08a", cs_extra))
  assert_true(m1.contains("会签节点[review]不允许配置 allowRecall"), msg="会签节点禁配: \{m1}")
  // 逐字**全等**（issues/246 §4.4）：本栈这一档取节点 **id**（`n.id`），不取 display_name
  // （夹具 review 节点 display_name＝「审批」）⇒ 文案里只有 `[review]` 一种形状，不存在
  // "id 档还是 display_name 档"的两读；整串钉死是为了连尾注「撤"谁的一票"语义不清」一起钉。
  assert_eq(m1, "会签节点[review]不允许配置 allowRecall：撤\"谁的一票\"语义不清")
  assert_true(!m1.contains("审批"), msg="文案不得用 display_name 档: \{m1}")

  let m2 = rc_parse_err(rc_chain_with_apply("recall-08b", [("allowRecall", @json.bool_of(true))], []))
  assert_true(m2.contains("首任务节点[apply]不允许配置 allowRecall"), msg="申请节点禁配: \{m2}")
  assert_eq(m2, "首任务节点[apply]不允许配置 allowRecall：申请节点走实例撤回＋重新发起，不需要同实例复活")

  // 反向哨兵：普通节点配 allowRecall 解析通过、开关为真；不配则为假
  let ok = @parser.parse_model(rc_chain("recall-08c", [("allowRecall", @json.bool_of(true))]))
  assert_true(ok.get_node("review").unwrap().allow_recall())
  let off = @parser.parse_model(rc_chain("recall-08d", []))
  assert_eq(off.get_node("review").unwrap().allow_recall(), false)
}

// ── 逐字文案与码表自证 ──────────────────────────────────────────────────────

///|
/// 09 ＝java `pinnedMessagesMatchSpec`：五档文案与 spec 04／06 逐字一致性自证
/// （防常量被改后测试仍绿）。
async test "recall-09 逐字文案自证：五档与 spec 06 §processTask/recall 失败表同源" {
  assert_eq(@engine.recall_window_msg("review"), "任务[review]的后续节点已办理，不能撤回")
  assert_eq(@engine.recall_switch_off_msg("review"), "节点[review]未开启 allowRecall，不能撤回")
  assert_eq(@engine.recall_not_finished_msg, "任务非已完成状态，不可撤回")
  assert_eq(@engine.recall_no_permission_msg, "无权限撤回该任务")
  assert_eq(@engine.recall_instance_not_doing_msg, "流程实例非进行中状态，不可撤回")
  assert_eq(@engine.recall_instance_missing_msg, "流程实例不存在")
  // 协议键逐字＝java FlowConst.RECALL_HISTORY
  assert_eq(@engine.recall_history_key, "tf_recallHistory")
}

///|
/// 10 事件码表自证（spec §11.3 权威码表 1..10）：规范名、码值、反查三者闭环。
/// issues/246 只在**表尾追加** 10 TASK_RECALL，1..9 逐字未动、码值不重排（"一个号一旦发出去
/// 不许改语义、不许复用"）。本栈此前没有码表全量断言，这一格是新加的（不是改既有期望值）。
async test "recall-10 事件码表 1..10 自证：新增码只追加表尾，1..9 一字未动" {
  let names : Array[String] = [
    "PROCESS_INSTANCE_START", "PROCESS_INSTANCE_END", "PROCESS_TASK_START", "CC_CREATE",
    "TASK_COMPLETE", "TASK_REJECT", "TASK_TRANSFER", "TASK_WITHDRAW", "INSTANCE_TERMINATED",
    "TASK_RECALL",
  ]
  let types : Array[@event.ProcessEventType] = [
    @event.ProcessInstanceStart, @event.ProcessInstanceEnd, @event.ProcessTaskStart, @event.CcCreate,
    @event.TaskComplete, @event.TaskReject, @event.TaskTransfer, @event.TaskWithdraw,
    @event.InstanceTerminated, @event.TaskRecall,
  ]
  for i in 0..<10 {
    assert_eq(types[i].code(), i + 1, msg="码值须连续 1..10，第 \{i + 1} 支错")
    assert_eq(types[i].name(), names[i], msg="规范名须逐字对齐 spec §11.3")
    assert_eq(@event.ProcessEventType::from_code(i + 1).unwrap(), types[i], msg="反查闭环")
  }
  // 越界档仍拒（11+ 是占号预留，不得被读成已发）
  assert_eq(@event.ProcessEventType::from_code(11), None)
  assert_eq(@event.ProcessEventType::from_code(0), None)
}

///|
/// 11 事件时序（spec §11.3 码 10 ＋ §11.2 原则 1）：撤回只 fire 一次码 10，
/// 复活行的待办另走码 3；**不补发 5/6**（撤回不是办结也不是拒绝）。
async test "recall-11 事件腿：撤回 fire 码 10 一次＋复活行走码 3，不补发 5/6" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider_sync(compliance_user_provider)
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener_sync(fn(ev) { events.push(ev) })
  let engine = @engine.Engine::make(ctx2)
  let extra : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let did = save_flow_define(repo, "recall-11", rc_chain("recall-11", extra))
  let inst = engine.start_async(did, "applicant", new_args())
  let iid = inst.instance_id
  for t in repo.find_doing_tasks(iid, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", rc_submit(0L))
    }
  }
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let old_review = rc_finished(repo, iid, "review")
  // 前面各腿的事件先记账，只看撤回这一次新增的部分
  let seen_before = events.length()

  let resurrected = engine.recall_task_async(old_review.task_id, "userA")
  let delta : Array[String] = []
  for i in seen_before..<events.length() {
    delta.push(events[i].event_type().name())
  }
  // [码 3 复活行待办, 码 10 撤回]：两者都在，且没有 5/6
  assert_true(delta.contains("PROCESS_TASK_START"), msg="复活行的待办须走码 3")
  assert_true(delta.contains("TASK_RECALL"), msg="撤回须 fire 码 10")
  assert_eq(
    delta.filter(fn(s) { s == "TASK_RECALL" }).length(), 1, msg="每轮撤回只 fire 一次码 10"
  )
  assert_true(!delta.contains("TASK_COMPLETE"), msg="撤回不得补发码 5")
  assert_true(!delta.contains("TASK_REJECT"), msg="撤回不得补发码 6")
  // 码 10 的 sourceId＝被撤回的旧行；载荷三键齐（spec §11.3 码 10）
  let recall_ev = events.filter(fn(e) { e.event_type().name() == "TASK_RECALL" })[0]
  assert_eq(recall_ev.source_id(), old_review.task_id)
  let d = recall_ev.data
  assert_eq(d.get_i64("instanceId"), Some(iid))
  assert_eq(d.get_i64("taskId"), Some(old_review.task_id))
  assert_eq(d.get_str("operator"), Some("userA"))
  // 码 3 的 sourceId＝复活行
  let start_ev = events.filter(fn(e) { e.event_type().name() == "PROCESS_TASK_START" })
  assert_eq(start_ev[start_ev.length() - 1].source_id(), resurrected.task_id)
}
