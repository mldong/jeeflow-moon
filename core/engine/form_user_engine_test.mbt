// 「HR 代员工提交」引擎级验收 —— 两支新 handler 在真实取人链上被解析并落成待办。
// 注册姿势＝卡片 §T3-moon：引擎不自建注册表，宿主按 Java FQN 逐字注册（同 mldong-moon
// plugins/jeeflow/forward.mbt 的装配位），故这里也按注册表路径验，而不是直接调工厂。

///|
let fu_users : (String) -> @model.UserInfo? raise @error.JeeflowError = uid => {
  match uid {
    "emp7" =>
      Some(
        @model.UserInfo::make(
          user_id="emp7",
          real_name="被代理员工",
          dept_id="d7",
        ),
      )
    "hr" =>
      Some(
        @model.UserInfo::make(user_id="hr", real_name="人事", dept_id="dHR"),
      )
    _ => None
  }
}

///|
let fu_org : @spi.OrgUserProviderFnsSync = {
  // d7 的经理/分管＝被代理人所属；dHR 的值刻意不同，用来证「与操作人无关」
  find_dept_leaders: d => {
    match d {
      "d7" => ["boss7"]
      "dHR" => ["bossHR"]
      _ => []
    }
  },
  find_dept_main_leaders: d => {
    match d {
      "d7" => ["main7"]
      "dHR" => ["mainHR"]
      _ => []
    }
  },
  find_by_role: _r => [],
}

///|
fn make_fu_engine() -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx
    .with_id_generator(fn() { gen.next_id() })
    .with_user_provider_sync(fu_users)
    .with_org_user_provider_sync(fu_org)
  let base : @itl.OrgAssignBase = {
    user: Some(@spi.async_of_sync(fu_users)),
    org: Some(fu_org.to_async()),
  }
  ctx2.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.OperatorAssignmentHandler",
    @itl.operator_assignment_handler(),
  )
  ctx2.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.FormUserDeptLeaderAssignmentHandler",
    @itl.form_user_dept_leader_handler(base, main=false),
  )
  ctx2.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.FormUserDeptMainLeaderAssignmentHandler",
    @itl.form_user_dept_leader_handler(base, main=true),
  )
  (@engine.Engine::make(ctx2), repo)
}

///|
fn fu_flow_json(handler_fqn : String) -> String {
  let s =
    $|  {"name": "hr-proxy", "displayName": "HR 代员工提交", "type": "approval",
    $|   "nodes": [
    $|     {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|     {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
    $|      "properties": {"assignee": "applicant"}},
    $|     {"id": "approver", "type": "snaker:task", "text": {"value": "审批"},
    $|      "properties": {"assignmentHandler": "HANDLER_FQN"}},
    $|     {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|   ],
    $|   "edges": [
    $|     {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
    $|     {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "approver"},
    $|     {"id": "e3", "sourceNodeId": "approver", "targetNodeId": "end"}
    $|   ]}
    $|  
  s.replace(old="HANDLER_FQN", new=handler_fqn)
}

///|
/// HR 用操作人身份发起，表单里给出被代理人 id（`f_approver`＝节点唯一编码的 f_ 档）。
async fn start_hr_proxy(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  handler_fqn : String,
) -> Int64 {
  let did = save_flow_define(repo, "hr-proxy", fu_flow_json(handler_fqn))
  let args = new_args()
  args.insert_str("f_approver", "emp7")
  let inst = engine.start_async(did, "hr", args)
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  for t in tasks {
    if t.actor_ids.contains("hr") {
      let _ = engine.execute_task_async(t.task_id, "hr", new_args())
      break
    }
  }
  inst.instance_id
}

///|
async test "fu-engine: HR 代员工提交 ⇒ 被代理人部门的经理收到待办（非操作人部门）" {
  let (engine, repo) = make_fu_engine()
  let iid = start_hr_proxy(
    engine, repo, "com.mldong.jeeflow.interceptor.impl.FormUserDeptLeaderAssignmentHandler",
  )
  let tasks = repo.find_doing_tasks(iid, [])
  let mut seen = ""
  for t in tasks {
    if t.actor_ids.contains("boss7") {
      seen = "boss7"
    }
  }
  assert_eq(seen, "boss7")
  // 操作人 hr 所在 dHR 的经理不得收到
  let mut hit_hr_dept = false
  for t in tasks {
    if t.actor_ids.contains("bossHR") {
      hit_hr_dept = true
    }
  }
  assert_false(hit_hr_dept)
}

///|
async test "fu-engine: 同一条流换成分管领导档 ⇒ main7 收到" {
  let (engine, repo) = make_fu_engine()
  let iid = start_hr_proxy(
    engine, repo, "com.mldong.jeeflow.interceptor.impl.FormUserDeptMainLeaderAssignmentHandler",
  )
  let tasks = repo.find_doing_tasks(iid, [])
  let mut seen = false
  for t in tasks {
    if t.actor_ids.contains("main7") {
      seen = true
    }
  }
  assert_true(seen)
}

///|
async test "fu-engine: 表单没给被代理人 ⇒ 新 handler 一支人不出来（负向：不抛异常）" {
  let (engine, repo) = make_fu_engine()
  let did = save_flow_define(
    repo,
    "hr-proxy",
    fu_flow_json(
      "com.mldong.jeeflow.interceptor.impl.FormUserDeptLeaderAssignmentHandler",
    ),
  )
  let inst = engine.start_async(did, "hr", new_args())
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  for t in tasks {
    assert_false(t.actor_ids.contains("boss7"))
    assert_false(t.actor_ids.contains("bossHR"))
  }
}
