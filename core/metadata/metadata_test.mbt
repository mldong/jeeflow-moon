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
test "metadata: handler registry built-ins ordered (13 handlers)" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("AssignmentHandler")
  assert_eq(handlers.length(), 13)
  assert_eq(reg.list_handlers_group("AssignmentHandler", "built-in").length(), 13)
  let expected_orders : Array[Int] = [-9999, 10, 20, 30, 40, 50, 60, 65, 70, 80, 90, 100, 110]
  assert_eq(handlers.length(), expected_orders.length())
  for i, order in expected_orders {
    assert_eq(handlers[i].order(), order)
  }
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
  assert_eq(reg.list_handlers("AssignmentHandler").length(), 14)
}

///|
test "metadata: ActionPermissionProvider entry matches reference (issues/184)" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("ActionPermissionProvider")
  assert_eq(handlers.length(), 1)
  assert_eq(handlers[0].class_name(), "com.mldong.jeeflow.spi.DefaultActionPermissionProvider")
  assert_false(handlers[0].class_name().contains(".impl."))
  assert_eq(handlers[0].display_name(), "action 权限码默认映射（boot3 注解语义归纳）")
  assert_eq(handlers[0].order(), 0)
}

///|
test "metadata: form-user dept handlers registered (order 70/80)" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("AssignmentHandler")
  let leader = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.FormUserDeptLeaderAssignmentHandler"
  )
  let main = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.FormUserDeptMainLeaderAssignmentHandler"
  )
  assert_eq(leader.length(), 1)
  assert_eq(main.length(), 1)
  assert_eq(leader[0].display_name(), "表单指定用户所属部门经理")
  assert_eq(main[0].display_name(), "表单指定用户所属部门分管领导")
  assert_eq(leader[0].order(), 70)
  assert_eq(main[0].order(), 80)
  assert_eq(leader[0].group(), "built-in")
  // 两支都是**顶级类**（不进 OrgUserAssignmentHandlers 内部类）⇒ 注册名不含内部类分隔符
  assert_false(leader[0].class_name().contains("$"))
  assert_false(main[0].class_name().contains("$"))
}

///|
test "metadata: form-dept handlers registered as top-level classes (order 90/100)" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("AssignmentHandler")
  let leader = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.FormDeptLeaderAssignmentHandler"
  )
  let main = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.FormDeptMainLeaderAssignmentHandler"
  )
  assert_eq(leader.length(), 1)
  assert_eq(main.length(), 1)
  assert_eq(handlers[10].class_name(), leader[0].class_name())
  assert_eq(handlers[11].class_name(), main[0].class_name())
  assert_eq(leader[0].display_name(), "表单指定部门负责人")
  assert_eq(main[0].display_name(), "表单指定部门分管领导")
  assert_eq(leader[0].order(), 90)
  assert_eq(main[0].order(), 100)
  assert_eq(leader[0].group(), "built-in")
  assert_eq(main[0].group(), "built-in")
  assert_false(leader[0].class_name().contains("$"))
  assert_false(main[0].class_name().contains("$"))
}

///|
test "metadata: post handlers registered with exact names/order (issues/259)" {
  let reg = @metadata.HandlerRegistry::new()
  let handlers = reg.list_handlers("AssignmentHandler")
  let task = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskPostAssigneeHandler"
  )
  let form = handlers.filter(h =>
    h.class_name() == "com.mldong.jeeflow.interceptor.impl.FormPostAssignmentHandler"
  )
  assert_eq(task.length(), 1)
  assert_eq(form.length(), 1)
  assert_eq(task[0].display_name(), "根据任务节点唯一编码关联岗位分配参与者")
  assert_eq(form[0].display_name(), "表单指定岗位分配参与者")
  assert_eq(task[0].order(), 65)
  assert_eq(form[0].order(), 110)
  assert_eq(task[0].group(), "built-in")
  assert_eq(form[0].group(), "built-in")
  assert_true(task[0].class_name().contains("$"))
  assert_false(form[0].class_name().contains("$"))
  assert_eq(handlers[7].class_name(), task[0].class_name())
  assert_eq(handlers[12].class_name(), form[0].class_name())
}
