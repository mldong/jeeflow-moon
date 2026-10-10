// issues/164 · moon 决策节点「零命中 ⇒ 显式报错（NOT_FOUND_NEXT_NODE 同档）」——对齐 java。
//
// 改前形状：选边 chosen_edge=None 后 `None => ()` 静默落出 Decision 分支——令牌不前进也不报错，
// 办理人看到 code=0"成功"、实例停在 state=10 且没有任何人的待办（僵尸实例；issues/159/164
// 边界轮实测"缺失变量档在 moon 可达、停住不报错"就是这条臂）。本案 A（2026-10-11 拍，
// python issues/161 已走同一条路）＝零命中 raise `Business`，文案逐字取 java
// `WfErrEnum.NOT_FOUND_NEXT_NODE`（20010001）。Business 档 message() 逐字透出 ⇒ 门面出口
// 99999999+msg 与 java 同文。
//
// 夹具＝**内联**决策流程（start → apply → task1 → decision 两 expr 边 → task2/task3 → end；
// 两条边可同时为 false——共享夹具 03 是 `>1000`/`<=1000` 恒有一条真，照不到这一档）；
// helper 复用同包 compliance_test.mbt（make_compliance_engine / save_flow_define /
// start_and_apply），不新增共享 flows/ 夹具。

///|
const I164_NOT_FOUND_NEXT_NODE_MSG : String = "decision节点无法确定下一步执行路线"

///|
const I164_FLOW : String =
  $|{"name": "i164-decision-nomatch", "displayName": "决策无命中(164夹具)", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "task1", "type": "snaker:task", "text": {"value": "填写报销单"},
  $|   "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|  {"id": "decision1", "type": "snaker:decision", "text": {"value": "金额判断"},
  $|   "properties": {"expr": "", "handleClass": ""}},
  $|  {"id": "task2", "type": "snaker:task", "text": {"value": "经理审批"},
  $|   "properties": {"assignee": "manager", "taskType": 0, "performType": 0}},
  $|  {"id": "task3", "type": "snaker:task", "text": {"value": "总监审批"},
  $|   "properties": {"assignee": "director", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|  {"id": "e2", "sourceNodeId": "task1", "targetNodeId": "decision1"},
  $|  {"id": "e3", "sourceNodeId": "decision1", "targetNodeId": "task2",
  $|   "properties": {"expr": "amount > 1000"}},
  $|  {"id": "e4", "sourceNodeId": "decision1", "targetNodeId": "task3",
  $|   "properties": {"expr": "amount < 0"}},
  $|  {"id": "e5", "sourceNodeId": "task2", "targetNodeId": "end"},
  $|  {"id": "e6", "sourceNodeId": "task3", "targetNodeId": "end"}
  $|]}

///|
async test "i164①: 两 expr 边全 false ⇒ 显式报错且文案与 java 同文、零后续待办（改前此格红：静默停住）" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "i164-nomatch", I164_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].task_name, "task1")
  let args = @json.FlowData::new()
  args.insert_i64("amount", 500L)
  let msg = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "leader", args)
    ""
  } catch {
    e => e.message()
  }
  assert_true(msg.contains(I164_NOT_FOUND_NEXT_NODE_MSG))
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let doing = repo.find_doing_tasks(iid, [])
  assert_true(doing.is_empty())
}

///|
async test "i164②: 对照档 amount=5000 ⇒ e3 为真照常走 task2（抛错只在零命中档）" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "i164-match", I164_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  let args = @json.FlowData::new()
  args.insert_i64("amount", 5000L)
  let raised = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "leader", args)
    false
  } catch {
    _ => true
  }
  assert_false(raised)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 1)
  assert_eq(doing[0].task_name, "task2")
}

///|
async test "i164③: 缺 amount（变量没填，两 expr 同样全 false）⇒ 同档报错" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "i164-missing", I164_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  let msg = try {
    let _ = engine.execute_task_async(tasks[0].task_id, "leader", @json.FlowData::new())
    ""
  } catch {
    e => e.message()
  }
  assert_true(msg.contains(I164_NOT_FOUND_NEXT_NODE_MSG))
}
