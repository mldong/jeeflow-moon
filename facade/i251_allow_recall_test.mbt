// issues/251：已办撤回 allowRecall 快照投影 —— 门面出口腿（内存仓，无真库/无 fs 成分）。
//
// 契约（spec 06 §processTask/doneList · todoList · processInstance/detail ＋ java
// `JeeflowFacade.taskRowToMap` / `instanceDetail`）：
//   · 已办行（**非 DOING**）且行变量里有引擎盖的 `tf_allowRecall` ⇒ 顶层出布尔 `allowRecall`；
//   · 缺键＝**不出字段**（存量行不猜、不补 false）；DOING 行**永不投**（待办那一侧的撤回判据
//     走实例级，不看节点开关）；
//   · 值只认 JSON 布尔（`@json.as_bool`）：串 "true" / 数字 1 一律不出字段；
//   · 本仓 VO 写 snake_case `allow_recall`，出口 `transform_output` 的 to_camel 落契约键
//     `allowRecall`（issues/250 `instance_state` → `instanceState` 同款先例）；
//   · `processInstance/detail` 的 tasks 列表同形；**task_vo 不动**（java taskVo 不投该键，
//     它被 processTask/detail · latest 共用）。
//
// 盖章本身在引擎（`core/engine/engine_ops.mbt` 的收敛点，逐格见 `core/engine/i251_stamp_test.mbt`）；
// 本文件钉出口这一侧：单元四格（真/假/DOING/缺键）＋端到端三格（doneList · todoList · detail）。
// 复用同包 helper：targs / code_of / msg_of / data_of / rows_of / doing_task_for /
// i247_setup / i247_exec（后者＝start→apply→review→final→end 五节点链）。

///|
/// 严格读 JSON 布尔：缺键 / null / 串 "true" / 数字一律 None（不许把非布尔读成 true）
fn i251_bool(row : Json, key : String) -> Bool? {
  match @json.get(row, key) {
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    _ => None
  }
}

///|
/// 键在不在（「不出字段」与「出 false」是两档，必须分开断言）
fn i251_has(row : Json, key : String) -> Bool {
  @json.get(row, key) is Some(_)
}

///|
/// 造一行任务行：state ＋ 盖章值（None＝行变量里没这枚键；stamp 直接塞 Json 以覆盖非布尔档）
fn i251_row(state : Int, stamp : Json?) -> @model.TaskRow {
  let r = @model.TaskRow::new_empty()
  r.task_state = state
  match stamp {
    Some(v) => {
      let vars = @json.empty_object()
      @json.obj_set(vars, "tf_allowRecall", v)
      r.variable = Some(@json.stringify(vars))
    }
    None => ()
  }
  r
}

///|
/// 列表里按节点名取行（取不到就显式红，不许被读成「投影没出」）
fn i251_row_named(rows : Array[Json], name : String) -> Json {
  for r in rows {
    if @json.get_str(r, "taskName") == Some(name) {
      return r
    }
  }
  abort("[i251] 列表里没有 \{name} 行")
}

///|
fn i251_tasks(data : Json) -> Array[Json] {
  match @json.get(data, "tasks") {
    Some(Json::Array(a)) => a
    _ => []
  }
}

// ── 单元：task_row_to_json ＋ to_camel 出口 ──────────────────────────────────

///|
test "i251 出口①：非 DOING ＋ 盖章 true ⇒ 原串键 allow_recall / 驼峰键 allowRecall 都是布尔 true" {
  let raw = @facade.task_row_to_json(i251_row(@model.TaskState::Finished.code(), Some(@json.bool_of(true))))
  assert_eq(i251_bool(raw, "allow_recall"), Some(true))
  let out = @facade.to_camel_json(raw)
  assert_eq(i251_bool(out, "allowRecall"), Some(true), msg="出口必须落驼峰契约键 allowRecall")
  assert_true(!i251_has(out, "allow_recall"), msg="驼峰后不得再留 snake 键")
}

///|
test "i251 出口②：非 DOING ＋ 盖章 false ⇒ allowRecall=false（承重：默认关也出字段，不是缺键）" {
  let raw = @facade.task_row_to_json(i251_row(@model.TaskState::Finished.code(), Some(@json.bool_of(false))))
  assert_eq(i251_bool(raw, "allow_recall"), Some(false))
  let out = @facade.to_camel_json(raw)
  assert_true(i251_has(out, "allowRecall"), msg="false 也要出键（前端据此置灰）")
  assert_eq(i251_bool(out, "allowRecall"), Some(false))
}

///|
test "i251 出口③：DOING ＋ 有键 ⇒ 一律不出 allowRecall（待办永不投）" {
  let raw = @facade.task_row_to_json(i251_row(@model.TaskState::Doing.code(), Some(@json.bool_of(true))))
  assert_true(!i251_has(raw, "allow_recall"), msg="DOING 行不得投节点开关快照")
  let out = @facade.to_camel_json(raw)
  assert_true(!i251_has(out, "allowRecall"))
}

///|
test "i251 出口④：非 DOING ＋ 缺键 ⇒ 不出 allowRecall（存量行不猜、不补 false）" {
  let out = @facade.to_camel_json(@facade.task_row_to_json(i251_row(@model.TaskState::Finished.code(), None)))
  assert_true(!i251_has(out, "allowRecall"), msg="没盖章的存量行不得凭空造字段")
  // 行变量非空但没这枚键，同样不出（不是「有变量就补 false」）
  let r = @model.TaskRow::new_empty()
  r.task_state = @model.TaskState::Finished.code()
  r.variable = Some("{\"f_amount\":100}")
  assert_true(!i251_has(@facade.to_camel_json(@facade.task_row_to_json(r)), "allowRecall"))
}

///|
test "i251 出口⑤：非 DOING ＋ 非布尔值（串 \"true\" / 数字 1）⇒ 不出字段（as_bool 严格）" {
  for bad in [@json.string_of("true"), @json.number_of(1L)] {
    let out = @facade.to_camel_json(@facade.task_row_to_json(i251_row(@model.TaskState::Finished.code(), Some(bad))))
    assert_true(!i251_has(out, "allowRecall"), msg="只认 JSON 布尔，不许把串/数字读成开关")
  }
}

///|
test "i251 出口⑥：判据是「非 DOING」不是「等于 FINISHED」⇒ 撤回(30)/废弃(99) 行同样投" {
  for state in [@model.TaskState::Withdraw.code(), @model.TaskState::Abandon.code()] {
    let out = @facade.to_camel_json(@facade.task_row_to_json(i251_row(state, Some(@json.bool_of(true)))))
    assert_eq(i251_bool(out, "allowRecall"), Some(true), msg="已办家族（<>10）同投影")
  }
}

// ── 端到端：doneList / todoList / instance detail ────────────────────────────

///|
async test "i251 端到端①：节点配 allowRecall=true ⇒ doneList 已办行顶层 allowRecall=true，todoList 待办行不出该键" {
  let on : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let (facade, repo, iid) = i247_setup("i251-e2e-on", on)
  let review = doing_task_for(repo, iid, "userA")
  let env = i247_exec(facade, review.task_id, "userA", "1", [])
  assert_eq(code_of(env), 0L, msg="办结 code=0（实得 msg=\{msg_of(env)}）")
  // 已办：review 行顶层带 allowRecall=true（不是塞在 ext 里）
  let done = facade.flow("processTask/doneList", targs([("operator", "userA")]))
  assert_eq(code_of(done), 0L, msg="doneList code=0（实得 msg=\{msg_of(done)}）")
  let done_row = i251_row_named(rows_of(data_of(done)), "review")
  assert_eq(i251_bool(done_row, "allowRecall"), Some(true))
  // 待办：final 行是 DOING ⇒ 永不投
  let todo = facade.flow("processTask/todoList", targs([("operator", "userF")]))
  assert_eq(code_of(todo), 0L, msg="todoList code=0（实得 msg=\{msg_of(todo)}）")
  let todo_row = i251_row_named(rows_of(data_of(todo)), "final")
  assert_true(!i251_has(todo_row, "allowRecall"), msg="DOING 行不得出 allowRecall")
}

///|
async test "i251 端到端②：节点不配（默认 false）⇒ doneList 已办行顶层 allowRecall=false" {
  let (facade, repo, iid) = i247_setup("i251-e2e-off", [])
  let review = doing_task_for(repo, iid, "userA")
  let env = i247_exec(facade, review.task_id, "userA", "1", [])
  assert_eq(code_of(env), 0L, msg="办结 code=0（实得 msg=\{msg_of(env)}）")
  let done = facade.flow("processTask/doneList", targs([("operator", "userA")]))
  assert_eq(code_of(done), 0L)
  let done_row = i251_row_named(rows_of(data_of(done)), "review")
  assert_true(i251_has(done_row, "allowRecall"), msg="默认 false 也出键（缺键与 false 两档）")
  assert_eq(i251_bool(done_row, "allowRecall"), Some(false))
}

///|
async test "i251 端到端③：processInstance/detail 的 tasks 同形（已办行带 allowRecall、DOING 行不带）" {
  let on : Array[(String, Json)] = [("allowRecall", @json.bool_of(true))]
  let (facade, repo, iid) = i247_setup("i251-e2e-detail", on)
  let review = doing_task_for(repo, iid, "userA")
  let env = i247_exec(facade, review.task_id, "userA", "1", [])
  assert_eq(code_of(env), 0L, msg="办结 code=0（实得 msg=\{msg_of(env)}）")
  let detail = facade.flow("processInstance/detail", targs([("id", iid.to_string())]))
  assert_eq(code_of(detail), 0L, msg="detail code=0（实得 msg=\{msg_of(detail)}）")
  let tasks = i251_tasks(data_of(detail))
  assert_eq(i251_bool(i251_row_named(tasks, "review"), "allowRecall"), Some(true))
  // 发起腿也盖章：apply 是首任务节点（解析期禁配 allowRecall）⇒ 快照恒 false
  assert_eq(i251_bool(i251_row_named(tasks, "apply"), "allowRecall"), Some(false))
  // DOING 的 final 行不投
  assert_true(!i251_has(i251_row_named(tasks, "final"), "allowRecall"))
}
