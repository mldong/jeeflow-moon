// metadata 单测 —— 移植自 rust metadata.rs tests

///|
test "metadata: enum dict registry 7 keys" {
  let reg = @metadata.EnumDictRegistry::new()
  let keys = reg.list_dict_keys()
  assert_eq(keys.length(), 7)
  assert_true(keys.contains("wf_process_define_state"))
  assert_true(keys.contains("wf_process_instance_state"))
  assert_true(keys.contains("wf_process_submit_type"))
  assert_true(keys.contains("wf_process_task_state"))
  assert_true(keys.contains("wf_process_task_type"))
  assert_true(keys.contains("wf_process_task_perform_type"))
  assert_true(keys.contains("wf_countersign_type"))
}

///|
test "metadata: instance state dict content" {
  let reg = @metadata.EnumDictRegistry::new()
  let items = reg.get_dict("wf_process_instance_state").unwrap()
  assert_eq(items.length(), 7)
  assert_eq(items[0].value(), "10")
  assert_eq(items[0].label(), "进行中")
}

///|
test "metadata: submit type dict 8 items" {
  let reg = @metadata.EnumDictRegistry::new()
  let items = reg.get_dict("wf_process_submit_type").unwrap()
  assert_eq(items.length(), 8)
}

///|
test "metadata: unknown dict" {
  let reg = @metadata.EnumDictRegistry::new()
  assert_true(reg.get_dict("unknown_key") is None)
}

///|
test "metadata: handler registry built-ins ordered" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("AssignmentHandler")
  assert_eq(handlers.length(), 7)
  assert_eq(handlers[0].order(), -9999)
  assert_true(handlers[0].class_name().contains("OperatorAssignmentHandler"))
}

///|
test "metadata: handler types and custom register" {
  let reg = @metadata.HandlerRegistry::new()
  let types = reg.list_handler_types()
  assert_true(types.contains("AssignmentHandler"))
  assert_true(types.contains("ActionPermissionProvider"))
  reg.register(
    @metadata.HandlerMeta::make("AssignmentHandler", "com.custom.MyHandler", "自定义处理器", 100, "custom"),
  )
  assert_eq(reg.list_handlers("AssignmentHandler").length(), 8)
}
