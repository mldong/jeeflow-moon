// issues/194：spec 04:55-56「忽略大小写」——混合大小写哨兵同样跳过 u_* 注入（java FlowUtil.addUserInfoToArgs 的 equalsIgnoreCase 同口径）
// add_user_info 是本包私有法（`_test.mbt` 取不到），判据走公开入口 start_async 观察实例变量那份 full_args

///|
async test "i194 start_async 对混合大小写哨兵跳过 u_* 注入" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "test-flow", simple_flow_json())
  let inst = engine.start_async(did, "FLOW.AUTO", new_args())
  assert_true(!inst.variables.contains_key("u_userId"), msg="FLOW.AUTO 不得注入 u_*")
  let inst2 = engine.start_async(did, "Flow.Admin", new_args())
  assert_true(!inst2.variables.contains_key("u_userId"), msg="Flow.Admin 不得注入 u_*")
  // 正向对照：前缀相似的真实用户照注入（判据不许靠前缀匹配过度宽松）
  let inst3 = engine.start_async(did, "flow.autox", new_args())
  assert_eq(inst3.variables.get_str("u_userId"), Some("flow.autox"))
}
