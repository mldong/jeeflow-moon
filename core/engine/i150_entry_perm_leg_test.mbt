// issues/150 的①判据：只读/隐藏的 f_ 字段在**办理入口**就被剔出流程变量
// （spec/09 §4.2 1.8.2；java `JeeflowEngineImpl.java:264 args = FlowUtil.filterFieldByPerm(args, model, taskName)`）。
// 三节点才照得出：两节点流里"当次过滤"和"入口过滤"同格，绕过腿恒真（121 §6 夹具纪律）。

///|
/// apply(申请人) → mid(可带字段权限声明) → last(不带任何声明) → end
fn i150_perm_flow(mid_field_decl : String) -> String {
  let mid_props = if mid_field_decl.is_empty() {
    "\"assignee\": \"applicant\""
  } else {
    "\"assignee\": \"applicant\", \"field\": {" + mid_field_decl + "}"
  }
  "{\"name\": \"i150\", \"displayName\": \"I150\", \"type\": \"approval\", \"nodes\": [" +
  "{\"id\": \"start\", \"type\": \"snaker:start\", \"text\": {\"value\": \"S\"}}, " +
  "{\"id\": \"apply\", \"type\": \"snaker:task\", \"text\": {\"value\": \"A\"}, \"properties\": {\"assignee\": \"applicant\"}}, " +
  "{\"id\": \"mid\", \"type\": \"snaker:task\", \"text\": {\"value\": \"M\"}, \"properties\": {" + mid_props + "}}, " +
  "{\"id\": \"last\", \"type\": \"snaker:task\", \"text\": {\"value\": \"L\"}, \"properties\": {\"assignee\": \"applicant\"}}, " +
  "{\"id\": \"end\", \"type\": \"snaker:end\", \"text\": {\"value\": \"E\"}}], \"edges\": [" +
  "{\"id\": \"e1\", \"sourceNodeId\": \"start\", \"targetNodeId\": \"apply\"}, " +
  "{\"id\": \"e2\", \"sourceNodeId\": \"apply\", \"targetNodeId\": \"mid\"}, " +
  "{\"id\": \"e3\", \"sourceNodeId\": \"mid\", \"targetNodeId\": \"last\"}, " +
  "{\"id\": \"e4\", \"sourceNodeId\": \"last\", \"targetNodeId\": \"end\"}]}"
}

///|
/// 在 mid 节点提交 f_amount=999，返回办结后的实例变量里有没有这个键
async fn i150_amount_in_vars_after_mid(decl : String) -> Bool raise {
  let (engine, repo) = make_test_engine()
  let did = save_flow_define(repo, "i150", i150_perm_flow(decl))
  let iid = start_and_apply(engine, repo, did)
  let mid = find_doing_for(repo, iid, "applicant")
  assert_eq(mid.task_name, "mid")
  let args = new_args()
  args.insert_i64("f_amount", 999L)
  let _ = engine.execute_task_async(mid.task_id, "applicant", args)
  match repo.find_instance_by_id(iid) {
    None => abort("i150: 实例读不到")
    Some(inst) => inst.variables.inner().get("f_amount") is Some(_)
  }
}

///|
/// 修复臂：mid 声明 `PERMISSION_f_amount=1`（只读）⇒ 值不入变量，
/// 于是下一个"没声明该字段权限"的 last 节点办理时也无从把它写进业务表（跨节点绕过的源头被掐掉）
async test "i150 readonly field is dropped at the engine entry" {
  let present = i150_amount_in_vars_after_mid("\"PERMISSION_f_amount\": 1")
  assert_true(!present)
  // 走到 last 节点后仍然没有（不是"当次没写、下一步又冒出来"）
  let (engine, repo) = make_test_engine()
  let did = save_flow_define(repo, "i150", i150_perm_flow("\"PERMISSION_f_amount\": 1"))
  let iid = start_and_apply(engine, repo, did)
  let mid = find_doing_for(repo, iid, "applicant")
  let args = new_args()
  args.insert_i64("f_amount", 999L)
  let _ = engine.execute_task_async(mid.task_id, "applicant", args)
  let last = find_doing_for(repo, iid, "applicant")
  assert_eq(last.task_name, "last")
  let _ = engine.execute_task_async(last.task_id, "applicant", new_args())
  match repo.find_instance_by_id(iid) {
    None => abort("i150: 实例读不到")
    Some(inst) => assert_true(inst.variables.inner().get("f_amount") is None)
  }
}

///|
/// 阳性对照：同一条流、mid **不声明**该字段权限 ⇒ 999 确实进变量。
/// 没有这一支，上面那条"没有"可能只是夹具根本没把值提交上去（恒真判据）。
async test "i150 positive control: undeclared field does enter variables" {
  let present = i150_amount_in_vars_after_mid("")
  assert_true(present)
}

///|
/// 隐藏档（权限值 3）在办理入口同样被剔除
async test "i150 hidden field is dropped at the engine entry too" {
  let (engine, repo) = make_test_engine()
  let did = save_flow_define(repo, "i150", i150_perm_flow("\"PERMISSION_f_secret\": 3"))
  let iid = start_and_apply(engine, repo, did)
  let mid = find_doing_for(repo, iid, "applicant")
  let args = new_args()
  args.insert_i64("f_secret", 7L)
  let _ = engine.execute_task_async(mid.task_id, "applicant", args)
  match repo.find_instance_by_id(iid) {
    None => abort("i150: 实例读不到")
    Some(inst) => {
      assert_true(inst.variables.inner().get("f_secret") is None)
      // 非 f_ 键的直通由 core/interceptor 的单元判据覆盖（filtered.contains_key("operator")）；
      // 引擎把提交参数并进实例变量时还有一层筛选，这里不重复断言那层行为。
    }
  }
}
