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
fn dict_label(items : Array[@metadata.DictItem], value : String) -> String {
  for it in items {
    if it.value() == value {
      return it.label()
    }
  }
  "<missing>"
}

///|
fn dict_has(items : Array[@metadata.DictItem], value : String, label : String) -> Bool {
  let mut found = false
  for it in items {
    if it.value() == value && it.label() == label {
      found = true
    }
  }
  found
}

///|
test "metadata: submit type dict 9 items (issues/115 补 7 转办)" {
  let reg = @metadata.EnumDictRegistry::new()
  let items = reg.get_dict("wf_process_submit_type").unwrap()
  assert_eq(items.length(), 9)
  // spec/07 字典行：0 发起申请 / … / 6 退回发起人 / 7 转办 / 20 会签拒绝
  assert_eq(dict_label(items, "7"), "转办")
  assert_eq(dict_label(items, "20"), "会签拒绝")
  // 2 的 label 不动（旧 20 写成 "拒绝申请(会签)" 与 2 撞文案，前端下拉无法区分）
  assert_eq(dict_label(items, "2"), "拒绝申请")
  assert_eq(dict_label(items, "0"), "发起申请")
}

///|
test "metadata: submit type dict == SubmitType 枚举 (code/label 同源)" {
  let reg = @metadata.EnumDictRegistry::new()
  let items = reg.get_dict("wf_process_submit_type").unwrap()
  let cases : Array[(@model.SubmitType, String)] = [
    (@model.Apply, "发起申请"),
    (@model.Agree, "同意申请"),
    (@model.Reject, "拒绝申请"),
    (@model.Rollback, "退回上一步"),
    (@model.Jump, "跳转"),
    (@model.ReApply, "重新提交"),
    (@model.RollbackToOperator, "退回发起人"),
    (@model.Transfer, "转办"),
    (@model.CountersignDisagree, "会签拒绝"),
  ]
  for (variant, label) in cases {
    let code = variant.code().to_string()
    assert_true(@model.SubmitType::from_code(variant.code()).unwrap() == variant)
    assert_true(dict_has(items, code, label))
  }
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
