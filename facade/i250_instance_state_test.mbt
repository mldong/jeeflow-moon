// issues/250：任务列表行必须带「所属流程实例的状态」——前端据此把实例已结束的**已办行**
// 撤回按钮置灰。契约（八栈逐字一致）：出口键 `instanceState`，整数，值＝该行所属流程实例的
// state（10 进行中 / 20 已完成 / 30 撤回 / 40 终止 / 45 拒绝 / 50 挂起 / 99 废弃）；
// 来源＝列表查询本来就关联的 `wf_process_instance`（别名 pi）的 `pi.state`，SQL 别名 `instance_state`；
// **todoList 与 doneList 两支都要带**；不新增关联、不解析流程定义、不改任何撤回判据。
//
// 本仓的特殊之处：SQL 仓（repository-mysql/repo/repository_page.mbt 的
// `pi.state AS instance_state` + `row_opt_int`）与内存仓（core/memory/memory.mbt 的
// `row.instance_state = Some(i.state)`）在 HEAD 就已有该投影与行映射，本轮**只补门面出口键**
// （args.mbt 的 `instance_state` → to_camel → `instanceState`）。
// 所以本文件钉的正是本轮唯一新增的那一处：`task_row_to_json` 的键 + 出口层的驼峰转换。
//
// 两格判据：
//   ① 有值（Some 20）⇒ 原串键 `instance_state` 出 20，驼峰后 `instanceState` 出 20，
//      且必须是 JSON Number（出口把状态字符串化就当场红）；
//   ② 缺值（None）⇒ 键**仍在**、值不得是数字（不能造 0：0 不是合法状态，
//      前端「有值且非 10 才置灰」的判据会被 0 误导）。两条合起来挡「漏键 / 漏转驼峰 / 造 0」。

///|
/// 读行上的整数键：**必须是 JSON Number**。缺键 / null / 字符串一律折成哨兵 -999，
/// 让断言报红而不是静默通过。刻意不用 `@json.get_i64`——它连 `"10"` 这种字符串数字也收，
/// 照不出「出口把状态字符串化」这一档违约（契约要的是整数）。
fn i250_int(row : Json, key : String) -> Int {
  match @json.get(row, key) {
    Some(Json::Number(n, ..)) => n.to_int()
    _ => -999
  }
}

///|
test "i250 出口①：instance_state 有值 ⇒ 驼峰后 instanceState 是整数 20" {
  let r = @model.TaskRow::new_empty()
  r.instance_state = Some(20)
  let raw = @facade.task_row_to_json(r)
  assert_eq(i250_int(raw, "instance_state"), 20)
  let out = @facade.to_camel_json(raw)
  assert_eq(i250_int(out, "instanceState"), 20)
}

///|
test "i250 出口②：instance_state 缺值 ⇒ 键仍在但不得造 0" {
  let out = @facade.to_camel_json(@facade.task_row_to_json(@model.TaskRow::new_empty()))
  match @json.get(out, "instanceState") {
    Some(_) => ()
    None => abort("[i250] 出口缺 instanceState 键（两仓同答案要求键恒在，缺值出 null）")
  }
  assert_eq(i250_int(out, "instanceState"), -999)
}
