// 「动态会签（征询模式 dynamicCountersign）」验收（黑盒 async test，内存仓）——移植 java
// `DynamicCountersignTest` 的 8 格 ＋ 本卡要求的两格跨轮计数 ＋ 一格非征询回归哨兵。
//
// 契约面（spec 02 §4.4 ＋ spec 04「动态会签（征询模式）」＋ spec 06 §2.7／§processTask/revokeDynamicCountersign）：
//   · 节点开关 `dynamicCountersign`（缺省关）；**三条解析期禁配**（与 allowAddSign 双开／会签节点／
//     申请节点），位序＝java `ModelParser` 尾段三轮 for（allowAddSign → allowRecall → dynamicCountersign）；
//   · 发起分流：带 `tf_addSignOperators` 的征询提交＝按人建成员行、**不办结主办行**、返回 marker
//     `{dynamicCountersign:{round,total,submitted}}`；成员行三戳＝parent(主办行)／轮次
//     `addSignRound_{node}`／原因 `tf_addSignReason`；账本 `tf_addSignHistory` 追加一条含 reason；
//   · 闸门：主办行未收齐 ⇒ **挡全部 submitType**（含驳回 2），逐字文案带 `已提交 已交/在册` 两枚计数；
//     成员行携带拉人参数＝另一档逐字文案，成员行自己提交照常放行；
//   · 撤回：废弃**未答**成员行、**已交意见行原样保留**、账本追加 `revoked=true` 条目、
//     轮次不消耗、闸门自然恢复；非参与者与"无待答"各归各文案；
//   · 投影（spec 06 §2.7）：`ext.dynamicCountersign`＝{active,round,total,submitted,actors[{actor,taskId,state}]}
//     从成员行现算、不落新存储。
//
// 三条承重判据（本文件逐格照出来，改引擎前先读）：
//   1. 成员行＝parent **且同节点同名**（`cl-01`/`cl-04`：主办办结后的下游行 parent 也是主办行，
//      只认 parent 会被撤回腿误废弃）；
//   2. 闸门收齐＝无 DOING 成员行，**计数与投影跳过 99**（`cl-07`：撤回清场那行既不算在册也不进投影，
//      读数错一位就是 1/3 而不是 1/2）；
//   3. 撤回参与人**按名册**判、不走只认 DOING 的 `is_allowed`（`cl-05`：主办已办结后再撤一发，
//      报的是「没有进行中的动态会签」而不是「无权限」——名册判据在 FINISHED 行上仍然放行）。
//
// 夹具：内联 JSON（复用 `recall_test.mbt` 的 `rc_chain`／`rc_start_to_review` 等同包助手）——
// 共享 flows 目录那条腿另有归属（八仓镜像与漂移门禁），本轮不碰 `flows/`。
// 本栈三条腿落在**引擎包**（java 落在门面），故本文件直接调引擎方法；门面位序与信封由
// `facade/i246_247_recall_collect_test.mbt` 端到端钉。
//
// 读数来源：本文件全部断言读**内存仓**（`@mem.MemoryRepository`），无真桶／无真库成分。
// 同轮真库腿（`repository-mysql/smoke` 的 T1-M4/M6/M7/M8/M10）打在 160 的 MySQL `jeeflow` 库，
// 读数另档：`G:/dev-tools/tmp/2026-11-04-246-247-release/moon/t1-mysql-smoke-final.txt`。

///|
/// 征询节点开关档
let cl_on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))

///|
/// 后加签开关档（双开那一格与回归哨兵用）
let cl_allow_add_sign_on : (String, Json) = ("allowAddSign", @json.bool_of(true))

///|
/// 提交意见（agree ＋ `tf_approvalComment`，意见落**各自行**变量）
fn cl_comment(comment : String) -> @json.FlowData {
  let a = rc_submit(1L)
  a.insert("tf_approvalComment", @json.string_of(comment))
  a
}

///|
/// 征询发起参数（submitType＋点名人（数组档）＋选填原因）
fn cl_args(ops : Array[String], reason : String?) -> @json.FlowData {
  let a = rc_submit(1L)
  a.insert(@engine.add_sign_operators_key, @json.array_of(ops.map(fn(s) { @json.string_of(s) })))
  match reason {
    Some(r) => a.insert(@engine.add_sign_reason_key, @json.string_of(r))
    None => ()
  }
  a
}

///|
/// 发起腿并取 marker（返回 None＝分流没认这次征询 ⇒ 显式红，不许被读成"另一件事"）
async fn cl_collect(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Json raise @error.JeeflowError {
  let dc = match engine.try_dynamic_countersign_async(task_id, operator, args) {
    Some(m) => @json.get(m, "dynamicCountersign")
    None => abort("期望发起腿返回 marker，实得 None（分流判据读岔）")
  }
  match dc {
    Some(v) => v
    None => abort("marker 里缺 dynamicCountersign 一格")
  }
}

///|
/// 发起腿的报错文案（没报错返回哨兵串）
async fn cl_collect_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> String {
  try {
    let _ = engine.try_dynamic_countersign_async(task_id, operator, args)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 闸门的报错文案（没报错返回哨兵串）
async fn cl_gate_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  args : @json.FlowData
) -> String {
  try {
    engine.gate_dynamic_countersign_async(task_id, args)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 撤回腿的报错文案（没报错返回哨兵串）
async fn cl_revoke_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  reason : String?
) -> String {
  try {
    let _ = engine.revoke_dynamic_countersign_async(task_id, operator, reason)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// 主办行（一律按 id 从仓储读回，不看引擎返回的那个聚合对象）
async fn cl_host(repo : @mem.MemoryRepository, task_id : Int64) -> @model.ProcessTask raise {
  match repo.find_task_by_id(task_id) {
    Some(t) => t
    None => abort("主办行 \{task_id} 读不回来")
  }
}

///|
/// 主办行的成员行（＝闸门/投影/撤回同一把尺子的取数口：聚合里的仓储真相）
async fn cl_members(
  repo : @mem.MemoryRepository, iid : Int64, host : @model.ProcessTask
) -> Array[@model.ProcessTask] raise {
  @engine.collect_member_rows(repo.find_instance_by_id(iid).unwrap().tasks, host)
}

///|
/// 成员行按名册取那一行（名册一人一行是建单不变量）
fn cl_pick(rows : Array[@model.ProcessTask], actor : String) -> @model.ProcessTask {
  let hit = rows.filter(fn(t) { t.actor_ids.contains(actor) })
  if hit.is_empty() {
    abort("成员行里没有 \{actor}（实得 \{rows.length()} 行）")
  } else {
    hit[0]
  }
}

///|
/// 主办行账本（从仓储读回的那一行上取，键＝`tf_addSignHistory`）
async fn cl_ledger(repo : @mem.MemoryRepository, task_id : Int64) -> Array[Json] raise {
  @engine.add_sign_history_of(cl_host(repo, task_id))
}

///|
/// 投影（引擎侧那一刀；门面侧的形状由 facade 文件钉）
async fn cl_projection(
  repo : @mem.MemoryRepository, iid : Int64, host : @model.ProcessTask
) -> Json? raise {
  @engine.collect_build_projection(repo.find_instance_by_id(iid).unwrap().tasks, host)
}

///|
/// 解析期报错文案
fn cl_parse_err(flow_json : String) -> String {
  try {
    let _ = @parser.parse_model(flow_json)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

// ── 正向 ────────────────────────────────────────────────────────────────────

///|
/// 01 ＝java `collectSubmitKeepsHostDoingAndStampsMemberRows`：带人提交**不办结主办行**、
/// 成员行三戳齐、账本含 reason、响应 marker `{round,total,submitted}`。
async test "collect-01 发起腿：主办行仍 DOING＋成员行三戳＋账本含 reason＋marker 计数" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-01", rc_chain("collect-01", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let marker = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], Some("涉及地规划需两部门意见")))
  assert_eq(@json.get_i64(marker, "round"), Some(1L))
  assert_eq(@json.get_i64(marker, "total"), Some(2L), msg="marker.total＝在册成员行数")
  assert_eq(@json.get_i64(marker, "submitted"), Some(0L))
  // 主办行不办结，下游一律不建
  let host_row = cl_host(repo, host.task_id)
  assert_true(host_row.is_doing(), msg="征询档主办行不得办结")
  assert_eq(rc_doing_count(repo, iid, "final"), 0, msg="主办不办结 ⇒ 不得放出下游待办")
  assert_eq(rc_rows(repo, iid, "final"), 0, msg="主办不办结 ⇒ 下游连历史行都不该有")
  // 成员行三戳：parent＝主办行、同节点同名、轮次＋原因
  let members = cl_members(repo, iid, host_row)
  assert_eq(members.length(), 2, msg="点名两人 ⇒ 两行成员行")
  for m in members {
    assert_true(m.is_doing(), msg="成员行建单即 DOING")
    assert_eq(m.task_name, "review", msg="成员行与主办行同节点（承重判据一）")
    assert_eq(m.parent_task_id, Some(host.task_id), msg="成员行 parent＝主办行")
    assert_eq(m.display_name, host_row.display_name, msg="成员行显示名照节点")
    assert_eq(
      m.variables.get_i64(@engine.add_sign_round_key("review")), Some(1L),
      msg="轮次戳 addSignRound_review 落成员行",
    )
    assert_eq(
      m.variables.get_str(@engine.add_sign_reason_key), Some("涉及地规划需两部门意见"),
      msg="原因戳落成员行（单行出证自足，不回查主办行）",
    )
    // 名册一人一行，且参与者表同步（家族不变量：取人要走参与者表）
    assert_eq(m.actor_ids.length(), 1)
    assert_eq(repo.find_task_actors(m.task_id), m.actor_ids)
  }
  assert_true(cl_pick(members, "userX").task_id != cl_pick(members, "userY").task_id)
  // 主办行：账本一条（含 reason）＋本轮轮次戳
  let lg = cl_ledger(repo, host.task_id)
  assert_eq(lg.length(), 1, msg="征询复用 tf_addSignHistory，一次拉人一条")
  assert_eq(@json.get_i64(lg[0], "round"), Some(1L))
  assert_eq(@json.get_str(lg[0], "fromActor"), Some("userA"))
  assert_eq(@json.get_str(lg[0], "operator"), Some("userA"))
  assert_eq(@json.get_str(lg[0], "reason"), Some("涉及地规划需两部门意见"))
  let to_actors = @json.as_array(@json.get(lg[0], "toActors").unwrap()).unwrap()
  assert_eq(to_actors.map(fn(v) { @json.as_str(v).unwrap_or("") }), ["userX", "userY"])
  assert_true(rc_is_eco_time(@json.get_str(lg[0], "time").unwrap()), msg="账本时间须是全生态格式")
  assert_eq(@json.get(lg[0], "revoked"), None, msg="发起那条不得带 revoked 标记")
  assert_eq(cl_host(repo, host.task_id).variables.get_i64(@engine.add_sign_round_key("review")), Some(1L))
  // 根因守卫（与后加签同一把尺子）：tf_ 控制键不得进实例变量
  let inst_vars = repo.find_instance_by_id(iid).unwrap().variables
  assert_eq(inst_vars.keys_with_prefix("tf_").length(), 0, msg="实例变量里不得有任何 tf_ 键")
}

///|
/// 02 ＝java `gateBlocksAllSubmitTypesUntilCollected`：未收齐时主办按**任意** submitType 办结
/// ⇒ 同一句逐字文案挡下，且报错零写入三面；收齐后闸门自然放行。
async test "collect-02 闸门：挡全部 submitType（逐字文案＋零写入三面），收齐后放行" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-02", rc_chain("collect-02", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  let rows_before = rc_all_rows(repo, iid)
  let expect = "节点[review]动态会签意见未收齐（已提交 0/2），不能办理"
  // 全枚举 submitType：0/1/2/3/4/5/6/20 —— 闸门在分发之前，与 submitType 无关 ⇒ 逐一同一句
  for st in [0L, 1L, 2L, 3L, 4L, 5L, 6L, 20L] {
    let msg = cl_gate_err(engine, host.task_id, rc_submit(st))
    assert_eq(msg, expect, msg="submitType=\{st} 必须被同一句逐字文案挡下（含驳回 2）")
  }
  // ── 报错即零写入三面 ──
  assert_true(cl_host(repo, host.task_id).is_doing(), msg="报错即零写入：主办行状态不变（仍 DOING）")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="报错即零写入：实例状态不变")
  assert_eq(rc_doing_count(repo, iid, "review"), 3, msg="主办＋两成员都还在待办（＝java doingCount==3）")
  // 收齐 ⇒ 闸门自然放行（无 DOING 成员行这一判据，不数意见内容）
  for m in cl_members(repo, iid, cl_host(repo, host.task_id)) {
    let _ = engine.execute_task_async(m.task_id, as_first_actor(m), rc_agree())
  }
  assert_eq(cl_gate_err(engine, host.task_id, rc_agree()), "<未报错>")
}

///|
/// 03 ＝java `hostProceedsAfterAllSubmittedWithProjection`：成员办结**不替主办推进**、
/// 意见落各自行；收齐后投影 active=false／total=submitted=2，主办拍板才流出下游。
async test "collect-03 成员办结不流转＋意见各行隔离；收齐后投影 active=false、主办拍板推进" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-03", rc_chain("collect-03", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  let members = cl_members(repo, iid, cl_host(repo, host.task_id))
  assert_eq(members.length(), 2)
  let x = cl_pick(members, "userX")
  let y = cl_pick(members, "userY")
  let _ = engine.execute_task_async(x.task_id, "userX", cl_comment("甲部门意见"))
  let _ = engine.execute_task_async(y.task_id, "userY", cl_comment("乙部门意见"))
  // 成员办结 ⇒ 主办仍 DOING、下游不建（征询档复用后加签推进闸：本节点还有 DOING 待办就停留）
  assert_true(cl_host(repo, host.task_id).is_doing(), msg="成员办结不得替主办推进")
  assert_eq(rc_doing_count(repo, iid, "final"), 0, msg="成员办结不放行出边")
  // 意见物理隔离：一行任务一条意见，互不覆盖
  assert_eq(repo.find_task_by_id(x.task_id).unwrap().variables.get_str("tf_approvalComment"), Some("甲部门意见"))
  assert_eq(repo.find_task_by_id(y.task_id).unwrap().variables.get_str("tf_approvalComment"), Some("乙部门意见"))
  assert_eq(cl_host(repo, host.task_id).variables.get_str("tf_approvalComment"), None, msg="成员意见不得回灌主办行")
  // 投影（spec 06 §2.7 形状）
  let p = match cl_projection(repo, iid, cl_host(repo, host.task_id)) {
    Some(j) => j
    None => abort("主办行有成员行 ⇒ 投影必须存在")
  }
  assert_eq(@json.as_bool(@json.get(p, "active").unwrap()), Some(false), msg="收齐后 active=false")
  assert_eq(@json.get_i64(p, "total"), Some(2L))
  assert_eq(@json.get_i64(p, "submitted"), Some(2L))
  assert_eq(@json.get_i64(p, "round"), Some(1L), msg="投影 round 取账本最后一条（＝java lastRound）")
  let actors = @json.as_array(@json.get(p, "actors").unwrap()).unwrap()
  assert_eq(actors.length(), 2)
  let rows : Array[@model.ProcessTask] = [x, y]
  for i in 0..<2 {
    let row = actors[i]
    let src = rows[i]
    assert_eq(@json.get_i64(row, "taskId"), Some(src.task_id), msg="投影 actors[].taskId 逐行对上")
    assert_eq(@json.get_str(row, "actor"), Some(as_first_actor(src)), msg="投影 actors[].actor＝该行名册")
    assert_eq(
      @json.get_i64(row, "state"), Some(@model.TaskState::Finished.code().to_int64()),
      msg="投影 state＝办结后的持久态",
    )
  }
  // 主办拍板 → 推进
  assert_eq(cl_gate_err(engine, host.task_id, rc_agree()), "<未报错>")
  let _ = engine.execute_task_async(host.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
  assert_eq(rc_doing_count(repo, iid, "review"), 0, msg="主办办结后本节点不留待办")
}

///|
/// 04 ＝java `memberPullDuplicateAndSelfGuards`：成员行禁拉人（另一档逐字文案，成员自己提交
/// 照常放行）／重复拉仍在待答的那位／加给自己——三拦全排在写之前，报错零写入。
async test "collect-04 三拦：成员行禁拉人＋重复拉待答中的人＋加给自己（报错零写入）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-04", rc_chain("collect-04", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX"], None))
  let rows_before = rc_all_rows(repo, iid)
  let mrow = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userX")
  // ① 成员行携带拉人参数 ⇒ 报成员行那一档（不是未收齐那一档）
  assert_eq(cl_gate_err(engine, mrow.task_id, cl_args(["userZ"], None)), "动态会签成员任务不能发起加签")
  // 承重判据一自证：成员行的 parent 指向**同节点同名**的主办行
  assert_eq(mrow.parent_task_id, Some(host.task_id))
  assert_eq(mrow.task_name, "review")
  // 反向哨兵：成员行不带拉人参数 ⇒ 闸门放行（意见自证走自己的行）
  assert_eq(cl_gate_err(engine, mrow.task_id, cl_comment("甲部门意见")), "<未报错>")
  // ② 重复拉仍在待答的那位（成员行仍 DOING）
  assert_eq(
    cl_collect_err(engine, host.task_id, "userA", cl_args(["userX"], None)),
    "操作人[userX]已在节点[review]的动态会签中",
  )
  // ③ 加给自己（死循环入口）
  assert_eq(
    cl_collect_err(engine, host.task_id, "userA", cl_args(["userA"], None)),
    "不能把任务加签给自己",
  )
  // ── 报错即零写入三面 ＋ 账本不追加 ──
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变")
  assert_eq(cl_members(repo, iid, cl_host(repo, host.task_id)).length(), 1, msg="被拦的两次都不得建成员行")
  assert_eq(cl_ledger(repo, host.task_id).length(), 1, msg="被拦的两次都不得记账")
  assert_true(cl_host(repo, host.task_id).is_doing(), msg="报错即零写入：主办行状态不变")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="报错即零写入：实例状态不变")
  // 已答的那位不再算"待答" ⇒ 同名重拉放行（重复判据只认 DOING 成员行）
  let _ = engine.execute_task_async(mrow.task_id, "userX", cl_comment("甲部门意见"))
  assert_eq(cl_collect_err(engine, host.task_id, "userA", cl_args(["userX"], None)), "<未报错>")
  assert_eq(cl_members(repo, iid, cl_host(repo, host.task_id)).length(), 2, msg="第二轮重拉应新建一行")
}

///|
/// 05 ＝java `revokeRestoresGateAndKeepsSubmittedOpinions`：撤未答、**已交意见保留**、账本记撤回、
/// 闸门恢复、轮次不消耗；非参与者与"无待答"各归各文案（后者顺带照出承重判据三）。
async test "collect-05 撤回腿：撤未答＋已交意见保留＋闸门恢复；重复撤与非参与者各归各文案" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-05", rc_chain("collect-05", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  let members = cl_members(repo, iid, cl_host(repo, host.task_id))
  let x = cl_pick(members, "userX")
  let y = cl_pick(members, "userY")
  let _ = engine.execute_task_async(x.task_id, "userX", cl_comment("甲部门意见"))
  let rows_before = rc_all_rows(repo, iid)
  // 非参与者先拦（按名册：userZ 不在主办行名册）
  assert_eq(cl_revoke_err(engine, host.task_id, "userZ", None), "无权限撤回该动态会签")
  assert_true(repo.find_task_by_id(y.task_id).unwrap().is_doing(), msg="报错即零写入：未答行不得被撤")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="报错即零写入：任务行总数不变")

  let resp = engine.revoke_dynamic_countersign_async(host.task_id, "userA", Some("部门选错重新拉"))
  assert_eq(@json.get_i64(resp, "revoked"), Some(1L), msg="只撤未答那一条")
  let acts = @json.as_array(@json.get(resp, "actors").unwrap()).unwrap()
  assert_eq(acts.map(fn(v) { @json.as_str(v).unwrap_or("<非串>") }), ["userY"])
  // 已交保留（20）、未答废弃（99）、意见不动
  assert_true(repo.find_task_by_id(x.task_id).unwrap().is_finished(), msg="已交意见行原样保留（审计凭证不动）")
  assert_eq(repo.find_task_by_id(y.task_id).unwrap().task_state, @model.TaskState::Abandon.code())
  assert_eq(repo.find_task_by_id(x.task_id).unwrap().variables.get_str("tf_approvalComment"), Some("甲部门意见"))
  // 主办行：状态一字不动、只改状态不建行（三面口径写死：成员行数不变＋实例状态不变）
  assert_true(cl_host(repo, host.task_id).is_doing(), msg="撤回不改主办行状态")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="撤回复用废弃腿 ⇒ 不新建任务行")
  assert_eq(cl_members(repo, iid, cl_host(repo, host.task_id)).length(), 2, msg="在册成员行数不变（撤回不增不减行）")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="撤回不动实例状态")
  // 账本两条：第二条带 revoked，round 沿用当前轮（撤回不消耗轮次）
  let lg = cl_ledger(repo, host.task_id)
  assert_eq(lg.length(), 2)
  assert_eq(@json.as_bool(@json.get(lg[1], "revoked").unwrap()), Some(true))
  assert_eq(@json.get_i64(lg[1], "round"), Some(1L), msg="撤回不消耗轮次")
  assert_eq(@json.get_str(lg[1], "reason"), Some("部门选错重新拉"))
  assert_eq(@json.get_str(lg[1], "operator"), Some("userA"))
  assert_eq(@json.as_array(@json.get(lg[1], "toActors").unwrap()).unwrap().length(), 1)
  // 闸门自然恢复（判据＝还有无 DOING 成员行）
  assert_eq(cl_gate_err(engine, host.task_id, rc_agree()), "<未报错>")
  let _ = engine.execute_task_async(host.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
  // 主办已办结后再撤一发：名册仍含 userA ⇒ 报「没有进行中的动态会签」而不是「无权限」
  // （承重判据三自证：若按只认 DOING 行的 is_allowed 判，这一发会错报无权限）
  let again = cl_revoke_err(engine, host.task_id, "userA", None)
  assert_eq(again, "节点[review]没有进行中的动态会签", msg="名册判据须在 FINISHED 行上仍然放行")
  let rows_after = rc_all_rows(repo, iid)
  assert_eq(cl_revoke_err(engine, host.task_id, "userZ", None), "无权限撤回该动态会签", msg="参与人判据排在待答判据之前")
  assert_eq(rc_all_rows(repo, iid), rows_after, msg="两次报错零写入：任务行总数不变")
}

///|
/// 06 ＝java `multiRoundCollectCountsAcrossRounds` ＋ 本轮点名要的读数格：
/// 第 2 轮响应 `{round:2,total:2,submitted:1}`（**在册跨轮累加**，不是只数本轮新行），
/// 闸门读数 `1/2`，两轮意见互不覆盖、轮次戳按轮隔离。
async test "collect-06 多轮征询：第 2 轮 marker 为 round=2/total=2/submitted=1，收齐才放行" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-06", rc_chain("collect-06", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let r1 = cl_collect(engine, host.task_id, "userA", cl_args(["userX"], None))
  assert_eq(@json.get_i64(r1, "round"), Some(1L))
  assert_eq(@json.get_i64(r1, "total"), Some(1L))
  assert_eq(@json.get_i64(r1, "submitted"), Some(0L))
  let x = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userX")
  let _ = engine.execute_task_async(x.task_id, "userX", cl_comment("第一轮意见"))
  // 闸门已开时仍可再拉：第二轮在册跨轮累加（x 已交＋y 未交＝1/2）
  let r2 = cl_collect(engine, host.task_id, "userA", cl_args(["userY"], None))
  assert_eq(@json.get_i64(r2, "round"), Some(2L), msg="轮次＝账本最后一条 round＋1")
  assert_eq(@json.get_i64(r2, "total"), Some(2L), msg="在册总数跨轮累加（＝java countMembers 现读全成员行）")
  assert_eq(@json.get_i64(r2, "submitted"), Some(1L), msg="已提交数跨轮累加")
  assert_eq(
    cl_gate_err(engine, host.task_id, rc_agree()),
    "节点[review]动态会签意见未收齐（已提交 1/2），不能办理",
  )
  // 轮次戳按轮隔离
  let all = cl_members(repo, iid, cl_host(repo, host.task_id))
  assert_eq(all.length(), 2)
  assert_eq(
    cl_pick(all, "userX").variables.get_i64(@engine.add_sign_round_key("review")), Some(1L),
    msg="第 1 轮那行仍写 1",
  )
  assert_eq(
    cl_pick(all, "userY").variables.get_i64(@engine.add_sign_round_key("review")), Some(2L),
    msg="第 2 轮那行写 2",
  )
  // 跨轮意见互不覆盖
  assert_eq(cl_host(repo, host.task_id).variables.get_str("tf_approvalComment"), None)
  // 收齐 → 主办拍板推进
  let y = cl_pick(all, "userY")
  let _ = engine.execute_task_async(y.task_id, "userY", cl_comment("第二轮意见"))
  assert_eq(
    repo.find_task_by_id(x.task_id).unwrap().variables.get_str("tf_approvalComment"),
    Some("第一轮意见"),
    msg="第二轮提交不得覆盖第一轮意见",
  )
  let lg = cl_ledger(repo, host.task_id)
  assert_eq(lg.length(), 2, msg="两轮各记一条")
  assert_eq(@json.get_i64(lg[0], "round"), Some(1L))
  assert_eq(@json.get_i64(lg[1], "round"), Some(2L))
  let _ = engine.execute_task_async(host.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
}

///|
/// 07 撤回清场后再拉：**在册计数与投影跳过 99**（承重判据二）。
/// ⚠️ 口径按基准＝java `CollectSupport.countMembers`：跨轮累加、只把 99 行剔掉——
/// 所以 x（已交、第 1 轮）仍在册，读数应是 `1/2`；把 y（撤回清场）也算进来会错成 `1/3`，
/// 只数本轮新行则会错成 `0/1`。两档错读都在这一格里照出来，故不额外发明第三种口径。
async test "collect-07 撤回清场后再拉：在册计数与投影跳过 99 行（java countMembers 口径）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-07", rc_chain("collect-07", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  let x = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userX")
  let y = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userY")
  let _ = engine.execute_task_async(x.task_id, "userX", rc_agree())
  let _ = engine.revoke_dynamic_countersign_async(host.task_id, "userA", None)
  assert_eq(repo.find_task_by_id(y.task_id).unwrap().task_state, @model.TaskState::Abandon.code())
  // 再拉一轮：在册＝x(20)＋z(10)，99 的 y 不算
  let r2 = cl_collect(engine, host.task_id, "userA", cl_args(["userZ"], None))
  assert_eq(@json.get_i64(r2, "round"), Some(2L))
  assert_eq(@json.get_i64(r2, "total"), Some(2L), msg="撤回清场那行不得算在册（否则读成 3）")
  assert_eq(@json.get_i64(r2, "submitted"), Some(1L), msg="已交的 x 行仍算（跨轮累加，不是只数本轮）")
  assert_eq(
    cl_gate_err(engine, host.task_id, rc_agree()),
    "节点[review]动态会签意见未收齐（已提交 1/2），不能办理",
    msg="闸门读数须跳过 99（错成 1/3 就是把撤回行算进在册）",
  )
  // 投影同样跳过 99
  let p = cl_projection(repo, iid, cl_host(repo, host.task_id)).unwrap()
  assert_eq(@json.get_i64(p, "total"), Some(2L))
  assert_eq(@json.get_i64(p, "submitted"), Some(1L))
  let actors = @json.as_array(@json.get(p, "actors").unwrap()).unwrap()
  assert_eq(actors.length(), 2, msg="撤回清场那行不进投影")
  let ids = actors.map(fn(a) { @json.get_i64(a, "taskId").unwrap_or(-1L) })
  assert_true(!ids.contains(y.task_id), msg="投影里不得出现被撤回的行")
  // 收齐后推进
  let z = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userZ")
  let _ = engine.execute_task_async(z.task_id, "userZ", rc_agree())
  assert_eq(cl_gate_err(engine, host.task_id, rc_agree()), "<未报错>")
  let _ = engine.execute_task_async(host.task_id, "userA", rc_agree())
  let _ = rc_need(repo, iid, "final")
  // 撤回清场的行推进后仍是 99，不被"复活"成待办
  assert_eq(repo.find_task_by_id(y.task_id).unwrap().task_state, @model.TaskState::Abandon.code())
}

///|
/// 08 ＝java `parseBansMutexCountersignAndApplyNodes`：三条解析期禁配 ＋ 轮次次序哨兵
/// ＋ 反向哨兵（普通节点配＝通过、不配＝假、非法值＝配置非法）。
async test "collect-08 解析期禁配：双开／会签节点／申请节点，并钉住三轮 for 的次序" {
  // ① 双开（同节点 allowAddSign＋dynamicCountersign，非会签非首节点）⇒ 互斥那一档
  let m1 = cl_parse_err(rc_chain("collect-08a", [cl_on, cl_allow_add_sign_on]))
  assert_true(
    m1.contains("不允许同时配置 allowAddSign 与 dynamicCountersign"), msg="双开禁配: \{m1}",
  )
  // 逐字**全等**（本栈这一档取节点 id `[review]`，夹具 display_name＝「审批」⇒ 文案不存在两读）
  assert_eq(
    m1,
    "节点[review]不允许同时配置 allowAddSign 与 dynamicCountersign：两档共用 tf_addSignOperators，行为靠节点属性分流，双开＝行为歧义",
  )
  assert_true(!m1.contains("审批"), msg="文案不得用 display_name 档: \{m1}")
  // ② 会签节点禁配
  let m2 = cl_parse_err(
    rc_chain("collect-08b", [cl_on, ("performType", @json.number_of(1L)), ("countersignType", @json.string_of("PARALLEL"))])
  )
  assert_true(m2.contains("会签节点[review]不允许配置 dynamicCountersign"), msg="会签节点禁配: \{m2}")
  assert_eq(m2, "会签节点[review]不允许配置 dynamicCountersign：会签池推进语义与征询挂起语义打架")
  // ③ 申请节点禁配（文案用「申请节点」，与 allowRecall 那档的「首任务节点」在基准里就不对称）
  let m3 = cl_parse_err(rc_chain_with_apply("collect-08c", [cl_on], []))
  assert_true(
    m3.contains("申请节点[apply]不允许配置 dynamicCountersign"), msg="申请节点禁配: \{m3}",
  )
  assert_eq(m3, "申请节点[apply]不允许配置 dynamicCountersign：申请节点那手走实例撤回＋重新发起，不需要征询挂起")
  // ④ 次序哨兵：双开＋会签同节点 ⇒ allowAddSign 那一轮先跑，报的是加签禁配档
  let m4 = cl_parse_err(
    rc_chain(
      "collect-08d",
      [
        cl_on, cl_allow_add_sign_on, ("performType", @json.number_of(1L)),
        ("countersignType", @json.string_of("PARALLEL")),
      ],
    )
  )
  assert_true(
    m4.contains("会签节点[review]不允许配置 allowAddSign"), msg="三轮 for 次序反了: \{m4}",
  )
  // ⑤ 反向哨兵：普通节点配＝解析通过且为真；不配＝假
  let ok = @parser.parse_model(rc_chain("collect-08e", [cl_on]))
  assert_true(ok.get_node("review").unwrap().dynamic_countersign())
  assert_eq(ok.get_node("final").unwrap().dynamic_countersign(), false)
  let off = @parser.parse_model(rc_chain("collect-08f", []))
  assert_eq(off.get_node("review").unwrap().dynamic_countersign(), false)
  // ⑥ 非法值档：三枚开关共用一把解析尺子
  let m6 = cl_parse_err(rc_chain("collect-08g", [("dynamicCountersign", @json.string_of("yes"))]))
  assert_true(
    m6.contains("节点[review]的 dynamicCountersign 配置非法: yes"), msg="非法值须响亮报错: \{m6}",
  )
}

///|
/// 09 ＝java `pinnedMessagesMatchSpec`：五档文案＋任务缺失档与簿记键名逐字自证
/// （防常量被改后测试仍绿；键名与 java `FlowConst` 逐字同）。
async test "collect-09 逐字文案与簿记键名自证：五档＋tf_addSignReason＋addSignRound_{node}" {
  assert_eq(
    @engine.collect_pending_msg("review", 0, 2), "节点[review]动态会签意见未收齐（已提交 0/2），不能办理"
  )
  assert_eq(
    @engine.collect_duplicate_msg("userX", "review"), "操作人[userX]已在节点[review]的动态会签中"
  )
  assert_eq(@engine.collect_member_pull_msg, "动态会签成员任务不能发起加签")
  assert_eq(@engine.collect_no_pending_msg("review"), "节点[review]没有进行中的动态会签")
  assert_eq(@engine.collect_no_permission_revoke_msg, "无权限撤回该动态会签")
  assert_eq(@engine.collect_task_missing_msg, "任务不存在")
  // 簿记键名逐字＝java FlowConst（复用时不改名：tf_addSignReason／addSignRound_{node}）
  assert_eq(@engine.add_sign_reason_key, "tf_addSignReason")
  assert_eq(@engine.add_sign_history_key, "tf_addSignHistory")
  assert_eq(@engine.add_sign_operators_key, "tf_addSignOperators")
  assert_eq(@engine.add_sign_round_key("review"), "addSignRound_review")
  assert_eq(@parser.dynamic_countersign_prop, "dynamicCountersign")
  // 计数次序哨兵：MSG_PENDING 两枚占位＝先 submitted 后 total（＝java `%d/%d` 对 count[1]/count[0]）
  assert_eq(
    @engine.collect_pending_msg("review", 1, 2), "节点[review]动态会签意见未收齐（已提交 1/2），不能办理"
  )
}

///|
/// 10 回归哨兵：非征询节点上两刀一律原样放行，后加签既有档不被抢（分流返回 None ⇒ 普通流转）。
async test "collect-10 回归哨兵：非征询节点闸门放行，带人提交仍走后加签腿" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-10", rc_chain("collect-10", [cl_allow_add_sign_on]))
  let host = rc_need(repo, iid, "review")
  let args = cl_args(["userB"], None)
  // 分流这一刀必须返回 None（节点没开 dynamicCountersign）
  assert_eq(engine.try_dynamic_countersign_async(host.task_id, "userA", args), None)
  assert_eq(cl_gate_err(engine, host.task_id, args), "<未报错>")
  // 闸门放行 ⇒ 交给普通 execute：后加签腿办结主办＋同节点续建一行
  let _ = engine.execute_task_async(host.task_id, "userA", args)
  assert_true(cl_host(repo, host.task_id).is_finished(), msg="后加签档主办行照旧办结")
  assert_eq(rc_doing_count(repo, iid, "review"), 1, msg="加签续建一行 userB")
  let b = rc_need(repo, iid, "review")
  assert_true(b.actor_ids.contains("userB"))
  // 未开任何开关的节点：带人提交报的是加签那一档的既有文案（闸门不抢、不发明第二种）
  let (engine2, repo2) = make_compliance_engine()
  let iid2 = rc_start_to_review(engine2, repo2, "collect-10b", rc_chain("collect-10b", []))
  let plain = rc_need(repo2, iid2, "review")
  assert_eq(engine2.try_dynamic_countersign_async(plain.task_id, "userA", args), None)
  assert_eq(cl_gate_err(engine2, plain.task_id, args), "<未报错>")
  assert_eq(
    as_exec_err(engine2, plain.task_id, "userA", args),
    "节点[review]未开启 allowAddSign，不接受 tf_addSignOperators",
  )
}

///|
/// 11 撤回腿负向档：主办行读不到＝逐字「任务不存在」；非征询节点撤＝「没有进行中的动态会签」
/// （未开开关与无待答在基准里并成一档，不发明第二种文案）。
async test "collect-11 撤回负向档：任务不存在与非征询节点并档" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-11", rc_chain("collect-11", []))
  let host = rc_need(repo, iid, "review")
  let rows_before = rc_all_rows(repo, iid)
  // ① 行读不到
  assert_eq(cl_revoke_err(engine, 987654L, "userA", None), "任务不存在")
  // ② 普通节点（没开征询）上有名册里的操作人 ⇒ 报「没有进行中的动态会签」
  assert_eq(cl_revoke_err(engine, host.task_id, "userA", None), "节点[review]没有进行中的动态会签")
  // ③ 闸门在非征询节点上完全不拦
  assert_eq(cl_gate_err(engine, host.task_id, rc_agree()), "<未报错>")
  assert_eq(rc_all_rows(repo, iid), rows_before, msg="三次调用零写入：任务行总数不变")
  assert_true(cl_host(repo, host.task_id).is_doing(), msg="报错即零写入：行状态不变")
}

///|
/// 12 拒绝(2) 清场：征询成员行同属本节点 DOING，随拒绝一并废弃、不留孤儿待办。
/// 这一格钉的是 `add_sign.mbt::abandon_add_sign_remaining` 那处**扩双开关**的守卫
/// （`allow_add_sign() || dynamic_countersign()` ＝java `AddSignSupport.abandonDoingOnNode`
/// 的新守卫）——只测闸门/撤回测不到它：写没测着的改动不算落地。
async test "collect-12 拒绝清场：征询主办行与未答成员行一并废弃，不留孤儿待办" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-12", rc_chain("collect-12", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  // 非空哨兵：拒绝前本节点确有三支活待办（主办＋两未答成员）
  assert_eq(rc_doing_count(repo, iid, "review"), 3, msg="拒绝前哨兵：主办＋两成员都在待办")
  let x = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userX")
  let _ = engine.execute_and_jump_to_end_async(x.task_id, "userX", rc_submit(2L))
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 45, msg="拒绝即实例结束（45）")
  assert_eq(rc_doing_count(repo, iid, "review"), 0, msg="未答成员行与主办行都不得留待办")
  assert_eq(
    as_rows_with_state(repo, iid, "review", @model.TaskState::Abandon.code()),
    2,
    msg="主办行＋另一位未答成员共两条废弃态（扩双开关那一刀真落了库）",
  )
  assert_true(
    cl_host(repo, host.task_id).task_state != @model.TaskState::Doing.code(),
    msg="主办行不得停在 DOING（守卫没扩到 dynamicCountersign 时这一格会红）",
  )
}

///|
/// 13 退回发起人(6) 清场：同 12 的守卫，走 `execute_and_jump_to_first_async` 那一刀。
async test "collect-13 退回发起人清场：征询成员行一并废弃并生成申请待办" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "collect-13", rc_chain("collect-13", [cl_on]))
  let host = rc_need(repo, iid, "review")
  let _ = cl_collect(engine, host.task_id, "userA", cl_args(["userX", "userY"], None))
  assert_eq(rc_doing_count(repo, iid, "review"), 3, msg="退回前哨兵：主办＋两成员都在待办")
  let y = cl_pick(cl_members(repo, iid, cl_host(repo, host.task_id)), "userY")
  let _ = engine.execute_and_jump_to_first_async(y.task_id, "userY", rc_submit(6L))
  let _ = rc_need(repo, iid, "apply")
  assert_eq(rc_doing_count(repo, iid, "review"), 0, msg="本节点未完成的征询行应全部废弃")
  assert_true(!rc_has_doing(repo, iid, "final"), msg="退回不放出下游待办")
  assert_eq(
    as_rows_with_state(repo, iid, "review", @model.TaskState::Abandon.code()),
    2,
    msg="主办行＋另一位未答成员共两条废弃态",
  )
}
