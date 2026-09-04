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
  let outcome = try? @parser.parse_model("not json")
  assert_true(outcome is Err(_))
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
