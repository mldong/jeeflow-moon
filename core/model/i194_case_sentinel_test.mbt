// issues/194：spec 04:55-56「忽略大小写」——混合大小写哨兵同样放行（java ProcessTask.isAllowed 的 equalsIgnoreCase 同口径）

///|
test "i194 is_allowed 对混合大小写哨兵放行" {
  let define_info = make_define(1L, "test")
  let inst = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  let task = inst.create_task("t", "T", ["user1"], "user1", @model.Major, @model.Normal, None, None)
  assert_true(task.is_allowed("FLOW.AUTO"), msg="FLOW.AUTO 应放行")
  assert_true(task.is_allowed("Flow.Admin"), msg="Flow.Admin 应放行")
  assert_true(task.is_allowed("user1"), msg="参与者本人照放行（回归）")
  assert_true(!task.is_allowed("flow.autox"), msg="前缀相似串不是哨兵")
  assert_true(!task.is_allowed("user2"), msg="非参与者仍拒（回归）")
}
