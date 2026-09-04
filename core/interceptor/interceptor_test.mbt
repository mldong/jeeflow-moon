// interceptor 单测 —— 移植自 rust interceptor.rs tests

///|
test "itl: operator assignment handler" {
  let define : @model.ProcessDefine = {
    id: 1L,
    name: "test",
    display_name: "Test",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let instance = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let model : @parser.ProcessModel = {
    name: "test",
    display_name: "Test",
    model_type: "approval",
    expire_time: None,
    persist_mode: None,
    rel_table_name: None,
    nodes: [],
    edges: [],
  }
  let exec = @exec.Execution::make(instance, model, define, "user1", @json.FlowData::new())
  let result = @interceptor.operator_assignment_handler()(exec)
  assert_eq(result, "user1")
}

///|
test "itl: form field assignee f_ prefix then bare name" {
  let define : @model.ProcessDefine = {
    id: 1L,
    name: "test",
    display_name: "Test",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let instance = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  let model : @parser.ProcessModel = {
    name: "test",
    display_name: "Test",
    model_type: "approval",
    expire_time: None,
    persist_mode: None,
    rel_table_name: None,
    nodes: [],
    edges: [],
  }
  let args = @json.FlowData::new()
  args.insert_str("node1", "user2,user3")
  let exec = @exec.Execution::make(instance, model, define, "user1", args)
  let node : @parser.NodeModel = {
    id: "node1",
    node_type: @parser.Task,
    display_name: "Node 1",
    properties: Map::new(),
  }
  exec.current_node = Some(node)
  let result = @interceptor.form_field_assignee_handler()(exec)
  assert_eq(result, "user2,user3")
}

///|
test "itl: field permission filter (C19 双格式)" {
  let args = @json.FlowData::new()
  args.insert_str("f_name", "张三")
  args.insert_str("f_amount", "1000")
  args.insert_str("f_status", "pending")
  args.insert_str("operator", "user1")
  let perms : Map[String, Int] = Map::new()
  perms["PERMISSION_f_name"] = 2
  perms["PERMISSION_amount"] = 1
  perms["PERMISSION_f_status"] = 3
  let filtered = @interceptor.filter_fields_by_permission(args, perms)
  assert_true(filtered.contains_key("f_name"))
  assert_true(!filtered.contains_key("f_amount"))
  assert_true(!filtered.contains_key("f_status"))
  assert_true(filtered.contains_key("operator"))
}

///|
test "itl: default permission code provider (wf:{action /→:})" {
  let codes = @spi.default_action_permission_provider("processDefine/page")
  assert_true(codes == ["wf:processDefine:page"])
}
