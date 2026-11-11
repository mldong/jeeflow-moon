// issues/251：办理时盖章「节点 allowRecall 快照」—— 引擎腿（黑盒 async test，纯内存仓）。
//
// 契约（spec 04「已办撤回」＋ java `RecallSupport.stampAllowRecall` / `JeeflowEngineImpl.prepareExecution`）：
//   · 执行任务的**唯一收敛点**（本仓 `load_exec_for_task`：守卫全过之后、`complete_task_in_aggregate`
//     之前）把当前节点的 allowRecall 开关值以键 `tf_allowRecall` 写进执行 args ⇒ 落任务行变量；
//   · 守卫＝「当前节点是 Task 才盖」，值＝开关 true/false，**默认 false 也盖键**（缺键与 false
//     在出口是两档：缺键＝不出字段，false＝出 allowRecall:false）；
//   · `tf_` 前缀 ⇒ 实例合并自动剥键（`complete_task_in_aggregate` 只收 `f_`）⇒ 实例变量零 tf_ 键；
//   · 盖章值恒为 **JSON 布尔**（不是串 "true"）；客户端伪造的同名键一律被本刀覆盖；
//   · 撤回校验本身不动（仍以现读定义为权威，快照只供前端预判）。
//
// 夹具复用同包 helper：`recall_test.mbt` 的 rc_chain / rc_start_to_review / rc_need / rc_finished /
// rc_agree / rc_submit，`compliance_test.mbt` 的 make_compliance_engine / new_args。
// 不连库、不读 flows 目录（wasm 运行器对 socket/fs 会挂死）。

///|
/// 协议键逐字钉子：常量与线上串必须一模一样（出口/前端读的是这枚串）
async fn i251_key_is_wire() -> Unit {
  assert_eq(@engine.allow_recall_key, "tf_allowRecall")
}

///|
/// 行上有没有这枚键（缺键与「值是 false」是两档，必须分开读）
async fn i251_has_stamp(repo : @mem.MemoryRepository, task_id : Int64) -> Bool raise {
  match repo.find_task_by_id(task_id) {
    Some(row) => row.variables.get("tf_allowRecall") is Some(_)
    None => abort("[i251] 任务行 \{task_id} 读不回来")
  }
}

///|
/// 行上盖章值（**严格 JSON 布尔**：串 "true" / 数字 1 一律折成 None ⇒ 断言报红）
async fn i251_stamp(repo : @mem.MemoryRepository, task_id : Int64) -> Bool? raise {
  match repo.find_task_by_id(task_id) {
    Some(row) =>
      match row.variables.get("tf_allowRecall") {
        Some(v) => @json.as_bool(v)
        None => None
      }
    None => abort("[i251] 任务行 \{task_id} 读不回来")
  }
}

///|
/// 实例变量里一枚 tf_ 键都不许有（红线同 add_sign_test.mbt 的 addsign-15）
async fn i251_no_instance_tf(repo : @mem.MemoryRepository, iid : Int64) -> Unit raise {
  let inst_vars = repo.find_instance_by_id(iid).unwrap().variables
  assert_eq(
    inst_vars.keys_with_prefix("tf_").length(), 0,
    msg="实例变量里不得有任何 tf_ 键（tf_allowRecall 只落任务行，不传播）",
  )
}

///|
/// 节点配 allowRecall=true 的追加档
fn i251_on() -> Array[(String, Json)] {
  [("allowRecall", @json.bool_of(true))]
}

// ── 盖章：普通办结腿 ────────────────────────────────────────────────────────

///|
async test "i251 stamp-01 节点配 allowRecall=true ⇒ 办结行 tf_allowRecall=true（JSON 布尔）＋实例零 tf_ 键" {
  i251_key_is_wire()
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-01", rc_chain("i251-stamp-01", i251_on()))
  let review = rc_need(repo, iid, "review")
  // 办结前：DOING 行上还没有这一手盖章（快照是「办理时」写的，不是建单时写的）
  assert_eq(i251_stamp(repo, review.task_id), None, msg="建单时不盖快照")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  assert_true(i251_has_stamp(repo, review.task_id), msg="办结必须盖键")
  assert_eq(i251_stamp(repo, review.task_id), Some(true), msg="开关 true ⇒ 快照 true（且是 JSON 布尔）")
  // 读回来的那一行确实是 FINISHED（不是把别的行读成它）
  assert_eq(rc_finished(repo, iid, "review").task_id, review.task_id)
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-02 节点不配（默认 false）⇒ 仍盖键 tf_allowRecall=false（承重：默认也盖）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-02", rc_chain("i251-stamp-02", []))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  assert_true(
    i251_has_stamp(repo, review.task_id),
    msg="默认 false 也必须盖键——缺键在出口是「不出字段」，与 allowRecall:false 两档",
  )
  assert_eq(i251_stamp(repo, review.task_id), Some(false))
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-03 发起腿（首任务节点 apply）同样盖章＝false，实例变量不传播" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-03", rc_chain("i251-stamp-03", i251_on()))
  // apply 是首任务节点：解析期禁配 allowRecall ⇒ 它的快照恒为 false（与 review 配了 true 无关）
  let apply = rc_finished(repo, iid, "apply")
  assert_true(i251_has_stamp(repo, apply.task_id), msg="发起腿也走同一收敛点")
  assert_eq(i251_stamp(repo, apply.task_id), Some(false))
  i251_no_instance_tf(repo, iid)
}

// ── 盖章：另外几条办结腿（同一收敛点，一处盖键全路径覆盖）────────────────────

///|
async test "i251 stamp-04 驳回腿（execute_and_jump_to_end）⇒ 来源行照样盖章 true" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-04", rc_chain("i251-stamp-04", i251_on()))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_and_jump_to_end_async(review.task_id, "userA", rc_agree())
  assert_eq(i251_stamp(repo, review.task_id), Some(true))
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-05 跳转腿（execute_and_jump → final）⇒ 来源行照样盖章 true" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-05", rc_chain("i251-stamp-05", i251_on()))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_and_jump_async(review.task_id, "userA", rc_agree(), Some("final"))
  assert_eq(i251_stamp(repo, review.task_id), Some(true))
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-06 退回发起人腿（execute_and_jump_to_first）⇒ 来源行照样盖章 true" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-06", rc_chain("i251-stamp-06", i251_on()))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_and_jump_to_first_async(review.task_id, "userA", rc_agree())
  assert_eq(i251_stamp(repo, review.task_id), Some(true))
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-07 撤回后重办：复活行办结时重新盖章，原行快照不改写" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-07", rc_chain("i251-stamp-07", i251_on()))
  let review = rc_need(repo, iid, "review")
  let _ = engine.execute_task_async(review.task_id, "userA", rc_agree())
  let old = rc_finished(repo, iid, "review")
  let resurrected = engine.recall_task_async(old.task_id, "userA")
  let _ = engine.execute_task_async(resurrected.task_id, "userA", rc_agree())
  assert_eq(i251_stamp(repo, resurrected.task_id), Some(true), msg="复活行这一手也盖章")
  assert_eq(i251_stamp(repo, old.task_id), Some(true), msg="原 FINISHED 行不改写（快照留着）")
  i251_no_instance_tf(repo, iid)
}

///|
async test "i251 stamp-08 客户端伪造 tf_allowRecall=true（节点不配）⇒ 落库仍是服务端快照 false" {
  let (engine, repo) = make_compliance_engine()
  let iid = rc_start_to_review(engine, repo, "i251-stamp-08", rc_chain("i251-stamp-08", []))
  let review = rc_need(repo, iid, "review")
  let forged = rc_agree()
  forged.insert("tf_allowRecall", @json.bool_of(true))
  let _ = engine.execute_task_async(review.task_id, "userA", forged)
  assert_eq(
    i251_stamp(repo, review.task_id), Some(false),
    msg="快照只认现读定义的开关值，客户端同名键一律被覆盖（args 优先级最高）",
  )
  i251_no_instance_tf(repo, iid)
}
