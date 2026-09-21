// issues/121 P1 建单不变量的引擎级用例（内存仓通道，黑盒 async test）。
// 夹具是 02-multi-task：apply → task1 → task2 → task3 四级链——两步流里「上一节点」与
// 「首任务节点」同格，断言恒真、抓不到缺陷，所以必须 ≥3 个任务节点。
// 断言一律落仓储读回值（find_instance_by_id 里的行），不认内存聚合副本。

///|
fn flag_key(t : @model.ProcessTask) -> Bool {
  match t.variables.get("isFirstTaskNode") {
    Some(_) => true
    None => false
  }
}

///|
fn flag_true(t : @model.ProcessTask) -> Bool {
  match t.variables.get("isFirstTaskNode") {
    Some(v) => @json.as_bool(v) == Some(true)
    None => false
  }
}

///|
fn flag_false(t : @model.ProcessTask) -> Bool {
  match t.variables.get("isFirstTaskNode") {
    Some(v) => @json.as_bool(v) == Some(false)
    None => false
  }
}

///|
fn task_named(inst : @model.ProcessInstance, name : String) -> @model.ProcessTask {
  let mut hit : @model.ProcessTask? = None
  for t in inst.tasks {
    if t.task_name == name {
      hit = Some(t)
    }
  }
  hit.unwrap()
}

///|
async test "i121-P1: create writes parent_task_id and isFirstTaskNode" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "multi-task", load_flow("02-multi-task"))
  let iid = start_and_apply(engine, repo, did)

  // apply 已由 start_and_apply 办结，task1 此刻进行中
  let mut inst = repo.find_instance_by_id(iid).unwrap()
  let apply = task_named(inst, "apply")
  // 发起 execution 没有当前任务 ⇒ parent 落 0L；apply 是 start 直接后继 ⇒ true
  assert_eq(apply.parent_task_id.unwrap_or(-1L), 0L)
  assert_true(flag_key(apply))
  assert_true(flag_true(apply))

  let task1 = task_named(inst, "task1")
  assert_eq(task1.parent_task_id.unwrap_or(-1L), apply.task_id)
  assert_true(flag_key(task1))
  assert_true(flag_false(task1))

  let _ = engine.execute_task_async(task1.task_id, "leader", new_args())
  inst = repo.find_instance_by_id(iid).unwrap()
  let task2 = task_named(inst, "task2")
  assert_eq(task2.parent_task_id.unwrap_or(-1L), task1.task_id)
  assert_true(flag_false(task2))

  let _ = engine.execute_task_async(task2.task_id, "manager", new_args())
  inst = repo.find_instance_by_id(iid).unwrap()
  let task3 = task_named(inst, "task3")
  assert_eq(task3.parent_task_id.unwrap_or(-1L), task2.task_id)

  // 本案真正要的那格：血缘版回退读的是**已办结的历史行**，标记必须随行存活
  // （出口现算版带「仅进行中」判定，历史行上恒 false ⇒ 首节点回退会被派错人）
  let _ = engine.execute_task_async(task3.task_id, "boss", new_args())
  inst = repo.find_instance_by_id(iid).unwrap()
  let his_apply = task_named(inst, "apply")
  assert_true(his_apply.task_state != 10)
  assert_true(flag_true(his_apply))
  assert_eq(his_apply.parent_task_id.unwrap_or(-1L), 0L)
}
