// parser 单测 —— 移植自 rust parser.rs tests

///|
const F1 : String =
  $|{"name": "test-flow", "displayName": "Test Flow", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "申请"},
  $|   "properties": {"assignee": "applicant"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "end"}
  $|]}

///|
test "parser: simple flow" {
  let model = @parser.parse_model(F1)
  assert_eq(model.name, "test-flow")
  assert_eq(model.display_name, "Test Flow")
  assert_eq(model.nodes.length(), 3)
  assert_eq(model.edges.length(), 2)
  let start = model.get_start().unwrap()
  assert_eq(start.id, "start")
  assert_true(start.node_type is @parser.Start)
  let first_task = model.get_first_task_node().unwrap()
  assert_eq(first_task.id, "apply")
  assert_eq(first_task.assignee().unwrap(), "applicant")
}

///|
test "parser: decision flow with expr edge" {
  let json =
    $|{"name": "decision-flow", "displayName": "Decision", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "d1", "type": "snaker:decision", "text": {"value": "判断"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "d1"},
    $|  {"id": "e2", "sourceNodeId": "d1", "targetNodeId": "end",
    $|   "properties": {"expr": "amount > 1000"}}
    $|]}
  let model = @parser.parse_model(json)
  let decision = model.get_node("d1").unwrap()
  assert_true(decision.node_type is @parser.Decision)
  let edges = model.get_output_edges("d1")
  assert_eq(edges.length(), 1)
  assert_eq(edges[0].expr().unwrap(), "amount > 1000")
}

///|
test "parser: countersign node tolerant performType (C4)" {
  let json =
    $|{"name": "cs-flow", "displayName": "Countersign", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "cs", "type": "snaker:task", "text": {"value": "会签"},
    $|   "properties": {"performType": "1", "countersignType": "PARALLEL"}},
    $|  {"id": "cs2", "type": "snaker:task", "text": {"value": "会签2"},
    $|   "properties": {"performType": "ALL"}},
    $|  {"id": "cs3", "type": "snaker:task", "text": {"value": "会签3"},
    $|   "properties": {"performType": 1}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "cs"},
    $|  {"id": "e2", "sourceNodeId": "cs", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  assert_eq(model.get_node("cs").unwrap().countersign_type(), "PARALLEL")
  assert_true(model.get_node("cs").unwrap().is_countersign())
  assert_true(model.get_node("cs2").unwrap().is_countersign())
  assert_true(model.get_node("cs3").unwrap().is_countersign())
}

///|
test "parser: empty nodes" {
  let model = @parser.parse_model(
    "{\"name\": \"empty\", \"displayName\": \"Empty\", \"type\": \"approval\", \"nodes\": [], \"edges\": []}",
  )
  assert_eq(model.nodes.length(), 0)
  assert_true(model.get_start() is None)
}

///|
test "parser: fork join structure" {
  let json =
    $|{"name": "fork-flow", "displayName": "Fork", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "Start"}},
    $|  {"id": "fork1", "type": "snaker:fork", "text": {"value": "Fork"}},
    $|  {"id": "t1", "type": "snaker:task", "text": {"value": "Task1"}, "properties": {"assignee": "user1"}},
    $|  {"id": "t2", "type": "snaker:task", "text": {"value": "Task2"}, "properties": {"assignee": "user2"}},
    $|  {"id": "join1", "type": "snaker:join", "text": {"value": "Join"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "End"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "fork1"},
    $|  {"id": "e2", "sourceNodeId": "fork1", "targetNodeId": "t1"},
    $|  {"id": "e3", "sourceNodeId": "fork1", "targetNodeId": "t2"},
    $|  {"id": "e4", "sourceNodeId": "t1", "targetNodeId": "join1"},
    $|  {"id": "e5", "sourceNodeId": "t2", "targetNodeId": "join1"},
    $|  {"id": "e6", "sourceNodeId": "join1", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  assert_eq(model.nodes.length(), 6)
  assert_true(model.get_node("fork1").unwrap().node_type is @parser.Fork)
  assert_true(model.get_node("join1").unwrap().node_type is @parser.Join)
  assert_eq(model.get_output_edges("fork1").length(), 2)
}

///|
test "parser: node properties" {
  let json =
    $|{"name": "prop-flow", "displayName": "Props", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
    $|  {"id": "t1", "type": "snaker:task", "text": {"value": "T"},
    $|   "properties": {"assignee": "user1", "form": "form1", "expireTime": "2d"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "t1"},
    $|  {"id": "e2", "sourceNodeId": "t1", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  let t1 = model.get_node("t1").unwrap()
  assert_eq(t1.assignee().unwrap(), "user1")
  assert_eq(t1.form_key().unwrap(), "form1")
}

///|
test "parser: invalid json raises" {
  let raised = try {
    let _ = @parser.parse_model("not json")
    false
  } catch {
    _ => true
  }
  assert_true(raised) // 非法流程 JSON ⇒ 必须 raise（旧写法是物化 Result 判 Err）
}

///|
test "parser: end nodes and task count" {
  let json =
    $|{"name": "test", "displayName": "T", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
    $|  {"id": "end1", "type": "snaker:end", "text": {"value": "E1"}},
    $|  {"id": "end2", "type": "snaker:end", "text": {"value": "E2"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "end1"},
    $|  {"id": "e2", "sourceNodeId": "start", "targetNodeId": "end2"}
    $|]}
  let model = @parser.parse_model(json)
  assert_eq(model.get_end_nodes().length(), 2)
  assert_eq(model.get_nodes_by_type(@parser.Task).length(), 0)
}

///|
test "parser: first task node guard" {
  let model = @parser.parse_model(
    "{\"name\": \"n\", \"displayName\": \"N\", \"type\": \"approval\", \"nodes\": [], \"edges\": []}",
  )
  assert_true(model.get_first_task_node() is None)
  assert_true(model.is_first_task_node("x") == false)
}

///|
test "parser: candidate keys dual source (issues/177 R11)" {
  let json =
    $|{"name": "i177-flow", "displayName": "I177", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
    $|  {"id": "pick", "type": "snaker:task", "text": {"value": "P"},
    $|   "properties": {"field": {"candidateUsers": "u1,u2", "candidateGroups": "g1"}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "pick"},
    $|  {"id": "e2", "sourceNodeId": "pick", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  let pick = model.get_node("pick").unwrap()
  assert_eq(pick.candidate_users().unwrap(), "u1,u2")
  assert_eq(pick.candidate_groups().unwrap(), "g1")
}

///|
test "parser: candidate keys top-level wins over field (issues/177 R11)" {
  let json =
    $|{"name": "i177-flow2", "displayName": "I177b", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
    $|  {"id": "pick", "type": "snaker:task", "text": {"value": "P"},
    $|   "properties": {"candidateUsers": "top1", "field": {"candidateUsers": "nested1"}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "pick"},
    $|  {"id": "e2", "sourceNodeId": "pick", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  let pick = model.get_node("pick").unwrap()
  assert_eq(pick.candidate_users().unwrap(), "top1")
}

///
/// R119：首任务节点按 nodes 序取第一个 `snaker:task`，不跟 start 首条出边
/// （首边到 decision 时旧实现返回 decision，导致 isFirstTaskNode 全假）。
test "parser: first task by node order, not start edge" {
  let json =
    $|{"name": "first-task", "displayName": "First", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "d1", "type": "snaker:decision", "text": {"value": "判断"}},
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "申请"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "d1"},
    $|  {"id": "e2", "sourceNodeId": "d1", "targetNodeId": "apply"},
    $|  {"id": "e3", "sourceNodeId": "apply", "targetNodeId": "end"}
    $|]}
  let model = @parser.parse_model(json)
  assert_eq(model.get_first_task_node().unwrap().id, "apply")
  assert_true(model.is_first_task_node("apply"))
  assert_false(model.is_first_task_node("d1"))
}

// ── issues/252：节点级 taskType=1（协办）解析期禁配（规范 02 §4.4）──────────────
//
// 协办档只由运行期 processTask/aidant 派生（issues/253，本轮不做）；节点上配协办在 snaker
// 原义下办结不驱动且跳转同闸＝"流程悬挂"陷阱 ⇒ 解析期就拦，不是运行时降级。
//
// ⚠️ 本栈容错集合现读：`NodeModel::task_type()` 走 `prop_i64` → `@json.as_i64`
// （Number 取整 / String 按 parse_int64），**没有 codeOf 别名表**（`@model.TaskType` 只有
// from_code）⇒ 能折成协办(1) 的是数字档（1 / "1"）；"Aidant"/"SECONDARY"/"协办" 解不出整数
// ⇒ 仍静默回落主办(0)，按 issues/252 §5-3 边界不得扩成 fail-fast（issues/245 口径）。
//
// 夹具全部内联 JSON，不碰共享 flows/（该目录有镜像与漂移门禁，唯一编辑源在 jeeflow-java）。

///|
/// 逐字契约文案：八栈同尺；改字面量要走 issue，不要顺手改。
const TT252_VERBATIM : String = "节点[review]不允许配置协办任务类型（taskType=1）"

///|
/// 取解析错误文案（形状照 recall_test.mbt 的 rc_parse_err）；没报错时返回哨兵串，
/// 让"该拦没拦"那一格红得明确，而不是静默绿。
fn tt252_parse_err(flow_json : String) -> String {
  try {
    let _ = @parser.parse_model(flow_json)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
/// start→apply→review→end；review 的 taskType 用**原文片段**注入（数字/串/null 各形）。
fn tt252_chain(task_type_raw : String) -> String {
  let s =
    $|{"name": "tt252", "displayName": "协办禁配夹具", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
    $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
    $|  {"id": "review", "type": "snaker:task", "text": {"value": "审批"},
    $|   "properties": {"assignee": "userA", "performType": 0, "taskType": \{task_type_raw}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
    $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "review"},
    $|  {"id": "e3", "sourceNodeId": "review", "targetNodeId": "end"}
    $|]}
  s
}

///|
/// review 节点**真正不写** taskType 键（缺省档）。
fn tt252_chain_absent() -> String {
  let s =
    $|{"name": "tt252-absent", "displayName": "协办禁配夹具", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
    $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
    $|  {"id": "review", "type": "snaker:task", "text": {"value": "审批"},
    $|   "properties": {"assignee": "userA", "performType": 0}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
    $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "review"},
    $|  {"id": "e3", "sourceNodeId": "review", "targetNodeId": "end"}
    $|]}
  s
}

///|
/// start→apply→rec(custom)→end：记录类节点上写 taskType=1，供"custom 不受影响"那格。
fn tt252_chain_custom(task_type_raw : String) -> String {
  let s =
    $|{"name": "tt252-custom", "displayName": "协办禁配夹具", "type": "approval",
    $|"nodes": [
    $|  {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
    $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
    $|  {"id": "rec", "type": "snaker:custom", "text": {"value": "记录"},
    $|   "properties": {"clazz": "noopHandler", "taskType": \{task_type_raw}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|],
    $|"edges": [
    $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
    $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "rec"},
    $|  {"id": "e3", "sourceNodeId": "rec", "targetNodeId": "end"}
    $|]}
  s
}

///|
/// 正向：本栈能折成协办(1) 的输入形（数字 1 / 串 "1"）一律解析期报错，文案逐字。
test "parser: i252 节点级协办禁配（1 与 \"1\" 解析期报错）" {
  let m1 = tt252_parse_err(tt252_chain("1"))
  assert_eq(m1, TT252_VERBATIM)
  let m2 = tt252_parse_err(tt252_chain("\"1\""))
  assert_eq(m2, TT252_VERBATIM)
  // 文案取节点 id，不取 display_name（夹具 review 的 display_name＝「审批」）
  assert_true(!m1.contains("审批"), msg="不得用 display_name 档: \{m1}")
  assert_true(!m1.contains("2001"), msg="内部码不得外泄: \{m1}")
}

///|
/// 正向：报错发生在解析阶段 ⇒ 拿不到模型，后续建单/落库无从发生（零副作用）。
test "parser: i252 协办禁配是解析期而不是运行期" {
  let raised = try {
    let _ = @parser.parse_model(tt252_chain("1"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// 正向：申请节点（首任务节点）配协办同样拦——禁配不看节点位置，只看折值。
test "parser: i252 申请节点配协办也拦" {
  let json = tt252_chain("0").replace(
    old="\"assignee\": \"applicant\", \"taskType\": 0",
    new="\"assignee\": \"applicant\", \"taskType\": 1",
  )
  assert_eq(
    tt252_parse_err(json),
    "节点[apply]不允许配置协办任务类型（taskType=1）",
  )
}

///|
/// 回归：不可识别值（含设计器现状写的 Aidant）与主办档 ⇒ 解析成功且折值仍为 0，
/// 不得被本轮顺手扩成 fail-fast（issues/252 §5-3 / issues/245 口径）。
test "parser: i252 其余 taskType 值维持静默回落主办" {
  let forms : Array[String] = [
    "0", "\"0\"", "\"Major\"", "\"Aidant\"", "\"SECONDARY\"", "\"协办\"", "\"主办\"", "\"\"", "null",
  ]
  for raw in forms {
    let model = @parser.parse_model(tt252_chain(raw))
    assert_eq(
      model.get_node("review").unwrap().task_type(),
      0,
      msg="既有回落口径不得被改动: \{raw}",
    )
  }
}

///|
/// 回归：缺省不写键 ⇒ task_type() 回落 0（本栈无 null 档，与改前逐字同形）。
test "parser: i252 缺键仍回落主办" {
  let model = @parser.parse_model(tt252_chain_absent())
  assert_eq(model.get_node("review").unwrap().task_type(), 0)
}

///|
/// 回归：RECORD(2) 档不受影响（数字与数字串都原样落 2）。
test "parser: i252 RECORD(2) 不受影响" {
  for raw in ["2", "\"2\""] {
    let model = @parser.parse_model(tt252_chain(raw))
    assert_eq(model.get_node("review").unwrap().task_type(), 2)
  }
}

///|
/// 回归：custom（记录类）节点不受影响——禁配只看 Task 节点，custom 上写 1 也放行。
test "parser: i252 custom 记录节点不被任务节点那把刀拦" {
  let model = @parser.parse_model(tt252_chain_custom("1"))
  assert_true(model.get_node("rec").unwrap().node_type is @parser.Custom)
}
