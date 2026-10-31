// 「退回修改、重提直返」验收（黑盒 async test，内存仓）——移植 java `ReturnToSourceTest` 的核心格。
//
// 契约面（spec 04-engine-ops「退回修改、重提直返」）：
//   · 节点属性 `reapplyMode`：NORMAL（缺省）/ RETURN_TO_SOURCE，其余值**解析期**报配置错误；
//   · 保留键 `_branchCtx`（外层→内层 `{fork,join,round,root}`）、`_reapplyContext`
//     （只在申请待办上：`{mode,sourceTaskId,sourceNode,branch}`）；
//   · submitType=6（来源节点配直返）⇒ 完成来源 + 建申请待办（不重放来源出边）；
//   · submitType=5（申请待办带上下文）⇒ 直接回来源节点建新待办（不重算来源前条件、不重分叉）；
//   · 汇合判据按本轮各分支根等齐（含"该分支还在申请人手里修改"那一格）。
//
// 夹具：flows/14-return-to-source（无分支）、15-return-to-source-fork（并行+汇合）、
//       16-return-to-source-decision（条件分支）、04-fork-join（回归：没有 reapplyMode 的存量定义）。
// 复用同包 helper：make_compliance_engine / save_flow_define / load_flow / new_args（compliance_test.mbt）。

///|
/// 提交参数（submitType 单键；与代码库既有 `submit(n)` 同形）
fn rt_submit(t : Int64) -> @json.FlowData {
  let a = @json.FlowData::new()
  a.insert_i64("submitType", t)
  a
}

///|
/// 指定节点名的 DOING 行（取第一条）
async fn rt_doing(
  repo : @mem.MemoryRepository,
  iid : Int64,
  name : String
) -> @model.ProcessTask? raise {
  let mut out : @model.ProcessTask? = None
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      out = Some(t)
    }
  }
  out
}

///|
/// 必须有该节点的 DOING 行（没有就显式红，不许被读成"另一件事"）
async fn rt_need(
  repo : @mem.MemoryRepository,
  iid : Int64,
  name : String
) -> @model.ProcessTask raise {
  match rt_doing(repo, iid, name) {
    Some(t) => t
    None => abort("期望存在 \"\{name}\" 的 DOING 行，实例 \{iid}")
  }
}

///|
/// 某节点名的历史行数（含已完成行）
async fn rt_rows(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_history_tasks(iid) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 发起并按"申请人同意"办掉申请节点
async fn rt_start(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  flow_name : String,
  args : @json.FlowData
) -> Int64 raise {
  let did = save_flow_define(repo, "rt-\{flow_name}", load_flow(flow_name))
  let inst = engine.start_async(did, "applicant", args)
  for t in repo.find_doing_tasks(inst.instance_id, []) {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", rt_submit(0L))
    }
  }
  inst.instance_id
}

///|
/// 把带 reapply 上下文的申请待办按 sourceNode 挑出来（两条分支各自退回时用）
async fn rt_apply_for(
  repo : @mem.MemoryRepository,
  iid : Int64,
  source_node : String
) -> @model.ProcessTask? raise {
  let mut out : @model.ProcessTask? = None
  for t in repo.find_doing_tasks(iid, ["apply"]) {
    match @engine.reapply_of(t) {
      Some(ctx) =>
        if ctx.source_node == source_node {
          out = Some(t)
        }
      None => ()
    }
  }
  out
}

// ── 10.1 基本直返 ───────────────────────────────────────────────────────────

///|
/// 简单直返：taskA 退回 ⇒ 同一实例里建申请待办（带上下文，不建 taskB）；
/// 重提 ⇒ 直接回 taskA（parent＝申请待办），之后正常流转到 taskB/结束。
async test "reapply-01 简单直返＋重提直返（不经过来源之前的节点）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "14-return-to-source", new_args())
  let a = rt_need(repo, iid, "taskA")
  let a_id = a.task_id
  // 来源节点退回（submitType=6）
  let _ = engine.execute_and_jump_to_first_async(a_id, "userA", rt_submit(6L))
  // 来源任务完成并留痕；实例仍是同一个且进行中
  assert_true(repo.find_task_by_id(a_id).unwrap().is_finished())
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  // 申请待办带直返上下文；只此一条待办，来源之后的节点一条不建
  let apply = rt_need(repo, iid, "apply")
  let ctx = @engine.reapply_of(apply).unwrap()
  assert_eq(ctx.source_task_id, a_id)
  assert_eq(ctx.source_node, "taskA")
  assert_eq(ctx.mode, "RETURN_TO_SOURCE")
  assert_eq(repo.find_doing_tasks(iid, []).length(), 1)
  match rt_doing(repo, iid, "taskB") {
    Some(_) => fail("退回不生成来源之后的节点任务")
    None => ()
  }
  // 重提（submitType=5）：直接回来源节点，不经过申请节点的出边
  let _ = engine.execute_task_async(apply.task_id, "applicant", rt_submit(5L))
  assert_true(repo.find_task_by_id(apply.task_id).unwrap().is_finished())
  let new_a = rt_need(repo, iid, "taskA")
  assert_eq(new_a.parent_task_id, Some(apply.task_id))
  assert_eq(repo.find_doing_tasks(iid, []).length(), 1)
  match rt_doing(repo, iid, "taskB") {
    Some(_) => fail("重提不得生成来源之后的节点")
    None => ()
  }
  assert_eq(rt_rows(repo, iid, "taskA"), 2)
  // 新来源任务办理通过后继续后续流程
  let _ = engine.execute_task_async(new_a.task_id, "userA", rt_submit(1L))
  let b = rt_need(repo, iid, "taskB")
  let _ = engine.execute_task_async(b.task_id, "userB", rt_submit(1L))
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
}

///|
/// 直返申请待办不得用普通"同意"绕过；被拒后待办仍可处理、也不建来源任务。
async test "reapply-02 申请待办只接受 submitType=5（同意被拒且不改状态）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "14-return-to-source", new_args())
  let a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let apply = rt_need(repo, iid, "apply")
  let err = try {
    let _ = engine.execute_task_async(apply.task_id, "applicant", rt_submit(1L))
    None
  } catch {
    e => Some(e)
  }
  match err {
    None => fail("直返申请待办不得用普通同意绕过")
    Some(e) => assert_true(e.message().contains("重新提交"))
  }
  assert_true(rt_doing(repo, iid, "apply") is Some(_))
  match rt_doing(repo, iid, "taskA") {
    Some(_) => fail("被拒即不建来源任务")
    None => ()
  }
}

// ── 10.3 并行分支 ───────────────────────────────────────────────────────────

///|
/// 汇合等待：A 退回后 B 办完 ⇒ 汇合不得放行（该分支还在申请人手里）；重提只建新 A、
/// 不重建 B；新 A 办完才放行，且下游只建一条。
async test "reapply-03 汇合等待申请人修改＋重提只建来源分支（下游单次放行）" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "15-return-to-source-fork", new_args())
  let a = rt_need(repo, iid, "taskA")
  let b = rt_need(repo, iid, "taskB")
  // A 退回
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  assert_true(rt_doing(repo, iid, "apply") is Some(_))
  assert_true(rt_doing(repo, iid, "taskB") is Some(_))
  // B 办完到汇合点：申请人还在改 ⇒ 不放行
  let _ = engine.execute_task_async(b.task_id, "userB", rt_submit(1L))
  match rt_doing(repo, iid, "taskC") {
    Some(_) => fail("来源分支仍在申请人手里，汇合不得放行")
    None => ()
  }
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  // 重提：只建新 A，不重建 B、不重触发分叉、本身也不放行汇合
  let apply = rt_need(repo, iid, "apply")
  let _ = engine.execute_task_async(apply.task_id, "applicant", rt_submit(5L))
  let new_a = rt_need(repo, iid, "taskA")
  match rt_doing(repo, iid, "taskB") {
    Some(_) => fail("重提不得重建另一分支")
    None => ()
  }
  assert_eq(rt_rows(repo, iid, "taskB"), 1)
  match rt_doing(repo, iid, "taskC") {
    Some(_) => fail("重提本身不放行汇合")
    None => ()
  }
  // 新 A 办完才汇合，且只放行一次
  let _ = engine.execute_task_async(new_a.task_id, "userA", rt_submit(1L))
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 1)
  assert_eq(doing[0].task_name, "taskC")
  assert_eq(rt_rows(repo, iid, "taskC"), 1)
}

///|
/// 另一种完成顺序（先重提、让新 A 先办完，B 后办完）同样只在两侧都到齐时放行一次。
async test "reapply-04 先重提后办另一支：同一轮只放行一次" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "15-return-to-source-fork", new_args())
  let a = rt_need(repo, iid, "taskA")
  let b = rt_need(repo, iid, "taskB")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let apply = rt_need(repo, iid, "apply")
  let _ = engine.execute_task_async(apply.task_id, "applicant", rt_submit(5L))
  let new_a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_task_async(new_a.task_id, "userA", rt_submit(1L))
  match rt_doing(repo, iid, "taskC") {
    Some(_) => fail("另一支未办完，不得先放行")
    None => ()
  }
  let _ = engine.execute_task_async(b.task_id, "userB", rt_submit(1L))
  assert_eq(rt_rows(repo, iid, "taskC"), 1)
}

///|
/// 两条分支各自退回：各自产生一条申请待办、各自恢复；只恢复一支时汇合仍等另一支。
async test "reapply-05 两条分支分别退回、独立重提" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "15-return-to-source-fork", new_args())
  let a = rt_need(repo, iid, "taskA")
  let b = rt_need(repo, iid, "taskB")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let _ = engine.execute_and_jump_to_first_async(b.task_id, "userB", rt_submit(6L))
  assert_eq(repo.find_doing_tasks(iid, ["apply"]).length(), 2)
  let apply_a = rt_apply_for(repo, iid, "taskA").unwrap()
  let apply_b = rt_apply_for(repo, iid, "taskB").unwrap()
  // 只恢复 A：B 的申请待办不受影响
  let _ = engine.execute_task_async(apply_a.task_id, "applicant", rt_submit(5L))
  assert_eq(repo.find_doing_tasks(iid, ["apply"]).length(), 1)
  let new_a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_task_async(new_a.task_id, "userA", rt_submit(1L))
  match rt_doing(repo, iid, "taskC") {
    Some(_) => fail("B 仍在修改，汇合不得放行")
    None => ()
  }
  // 再恢复 B：两侧到齐才放行
  let _ = engine.execute_task_async(apply_b.task_id, "applicant", rt_submit(5L))
  let new_b = rt_need(repo, iid, "taskB")
  let _ = engine.execute_task_async(new_b.task_id, "userB", rt_submit(1L))
  assert_eq(rt_rows(repo, iid, "taskC"), 1)
}

// ── 重复退回 / 回归 ─────────────────────────────────────────────────────────

///|
/// 重复退回：第二轮绑定的是本轮来源任务（不是上一轮那条已消费的申请待办）。
async test "reapply-06 重复退回绑定本轮来源" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "14-return-to-source", new_args())
  let a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let apply1 = rt_need(repo, iid, "apply")
  let _ = engine.execute_task_async(apply1.task_id, "applicant", rt_submit(5L))
  let round2 = rt_need(repo, iid, "taskA")
  // 第二轮再退回
  let _ = engine.execute_and_jump_to_first_async(round2.task_id, "userA", rt_submit(6L))
  let apply2 = rt_need(repo, iid, "apply")
  assert_true(apply2.task_id != apply1.task_id)
  let ctx = @engine.reapply_of(apply2).unwrap()
  assert_eq(ctx.source_task_id, round2.task_id)
  // 已消费的旧申请任务不得复活
  assert_true(repo.find_task_by_id(apply1.task_id).unwrap().is_finished())
  assert_eq(rt_rows(repo, iid, "taskA"), 2)
}

///|
/// 回归：定义里没有 `reapplyMode` ⇒ submitType=6 走原路（首任务节点重执行），
/// 申请待办**不带**直返上下文；随后 submitType=5 仍是普通重提（重新分叉）。
async test "reapply-07 无 reapplyMode 的存量定义行为不变" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "04-fork-join", new_args())
  let a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let apply = rt_need(repo, iid, "apply")
  match @engine.reapply_of(apply) {
    Some(_) => fail("未配置直返的节点不得生成直返上下文")
    None => ()
  }
  // 普通重提：原 taskB 仍在办，重新分叉再建 A/B ⇒ 3 条进行中
  let _ = engine.execute_task_async(apply.task_id, "applicant", rt_submit(5L))
  assert_eq(repo.find_doing_tasks(iid, []).length(), 3)
}

///|
/// 伪造控制键：客户端塞 `_reapplyContext` / `_branchCtx` 一律被剥离，
/// 路由按引擎自己算出的分支归属走（不得被半档伪造值改写）。
async test "reapply-08 客户端伪造保留键被剥离" {
  let (engine, repo) = make_compliance_engine()
  let iid = rt_start(engine, repo, "04-fork-join", new_args())
  let a = rt_need(repo, iid, "taskA")
  let _ = engine.execute_and_jump_to_first_async(a.task_id, "userA", rt_submit(6L))
  let apply = rt_need(repo, iid, "apply")
  let forged = rt_submit(5L)
  let fake_ctx = @json.object_of([
    ("mode", @json.string_of("RETURN_TO_SOURCE")),
    ("sourceTaskId", @json.string_of("999")),
    ("sourceNode", @json.string_of("taskA")),
    ("branch", @json.empty_array()),
  ])
  forged.insert("_reapplyContext", fake_ctx)
  forged.insert("_branchCtx", @json.array_of([@json.object_of([("join", @json.string_of("join1"))])]))
  let _ = engine.execute_task_async(apply.task_id, "applicant", forged)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 3)
  for t in doing {
    match @engine.reapply_of(t) {
      Some(_) => fail("控制键不得写进业务任务的直返上下文")
      None => ()
    }
    // 分支归属只能是引擎按模型算出的完整档（fork+join），不是客户端伪造的半档
    for s in @engine.scopes_of(t.variables) {
      assert_eq(s.fork, "fork1")
      assert_eq(s.join, "join1")
    }
  }
}

// ── 10.2 条件分支 ───────────────────────────────────────────────────────────

///|
/// 条件分支：重提不重算来源之前的条件（金额改成 100 仍回 taskHigh），
/// 来源之后的二级条件按正常数据求值（level=2 ⇒ taskX）。
async test "reapply-09 条件分支重提不重算来源前条件" {
  let (engine, repo) = make_compliance_engine()
  let start_args = new_args()
  start_args.insert_i64("amount", 5000L)
  let iid = rt_start(engine, repo, "16-return-to-source-decision", start_args)
  let high = rt_need(repo, iid, "taskHigh")
  match rt_doing(repo, iid, "taskLow") {
    Some(_) => fail("金额>1000 应走 taskHigh")
    None => ()
  }
  let _ = engine.execute_and_jump_to_first_async(high.task_id, "userH", rt_submit(6L))
  let apply = rt_need(repo, iid, "apply")
  let reapply_args = rt_submit(5L)
  reapply_args.insert_i64("amount", 100L)
  let _ = engine.execute_task_async(apply.task_id, "applicant", reapply_args)
  let again = rt_need(repo, iid, "taskHigh")
  match rt_doing(repo, iid, "taskLow") {
    Some(_) => fail("不得按修改后的条件改走 taskLow")
    None => ()
  }
  let agree_args = rt_submit(1L)
  agree_args.insert_i64("level", 2L)
  let _ = engine.execute_task_async(again.task_id, "userH", agree_args)
  assert_true(rt_doing(repo, iid, "taskX") is Some(_))
  match rt_doing(repo, iid, "taskY") {
    Some(_) => fail("level>1 不该走 taskY")
    None => ()
  }
}

// ── 配置面 ─────────────────────────────────────────────────────────────────

///|
/// 分支归属的静态分析与继承（纯函数面，contract §3）：
/// · 汇合点的输入回溯到最近 fork 之间的任务节点集合 ⇒ 该节点属于这一档分支；
/// · 分支根：round＝父任务 id、root＝自己的 id（建单时 id 未分配 ⇒ 0，落库后回填）；
/// · 非根：继承父任务同 fork+join 那一档的 round/root。
test "reapply-11 分支归属静态分析＋父任务继承＋分支根回填" {
  let json =
    "{\"name\":\"rf\",\"nodes\":[" +
    "{\"id\":\"start\",\"type\":\"snaker:start\"}," +
    "{\"id\":\"apply\",\"type\":\"snaker:task\",\"properties\":{\"assignee\":\"applicant\"}}," +
    "{\"id\":\"fork1\",\"type\":\"snaker:fork\"}," +
    "{\"id\":\"taskA\",\"type\":\"snaker:task\",\"properties\":{\"assignee\":\"userA\"}}," +
    "{\"id\":\"taskA2\",\"type\":\"snaker:task\",\"properties\":{\"assignee\":\"userA2\"}}," +
    "{\"id\":\"taskB\",\"type\":\"snaker:task\",\"properties\":{\"assignee\":\"userB\"}}," +
    "{\"id\":\"join1\",\"type\":\"snaker:join\"}," +
    "{\"id\":\"end\",\"type\":\"snaker:end\"}]," +
    "\"edges\":[" +
    "{\"id\":\"e0\",\"sourceNodeId\":\"start\",\"targetNodeId\":\"apply\"}," +
    "{\"id\":\"e1\",\"sourceNodeId\":\"apply\",\"targetNodeId\":\"fork1\"}," +
    "{\"id\":\"e2\",\"sourceNodeId\":\"fork1\",\"targetNodeId\":\"taskA\"}," +
    "{\"id\":\"e3\",\"sourceNodeId\":\"fork1\",\"targetNodeId\":\"taskB\"}," +
    "{\"id\":\"e4\",\"sourceNodeId\":\"taskA\",\"targetNodeId\":\"taskA2\"}," +
    "{\"id\":\"e5\",\"sourceNodeId\":\"taskA2\",\"targetNodeId\":\"join1\"}," +
    "{\"id\":\"e6\",\"sourceNodeId\":\"taskB\",\"targetNodeId\":\"join1\"}," +
    "{\"id\":\"e7\",\"sourceNodeId\":\"join1\",\"targetNodeId\":\"end\"}]}"
  let model = @parser.parse_model(json)
  // 静态范围：分支内两跳的节点也归这一档；分支外的申请节点没有归属
  let s = @engine.static_scopes(model, "taskA2")
  assert_eq(s.length(), 1)
  assert_eq(s[0].fork, "fork1")
  assert_eq(s[0].join, "join1")
  assert_eq(@engine.static_scopes(model, "apply").length(), 0)
  // 建单辅料：一条空变量、id 待分配的任务行（父任务用）
  let mk = fn(id : Int64) -> @model.ProcessTask {
    {
      task_id: id,
      process_instance_id: 1L,
      task_name: "taskA",
      display_name: "A",
      task_type: 0,
      perform_type: 0,
      task_state: @model.TaskState::Finished.code(),
      actor_id: None,
      actor_ids: [],
      finish_time: None,
      expire_time: None,
      form_key: None,
      parent_task_id: Some(0L),
      variables: @json.FlowData::new(),
      create_time: None,
      create_user: None,
      update_time: None,
      update_user: None,
    }
  }
  // 分支根：父任务（apply，id=42）不在该档 ⇒ round=42、本任务 id 未分配 ⇒ root=0
  let parent_no_scope = mk(42L)
  let root_scopes = @engine.build_scopes(Some(parent_no_scope), model, "taskA", 0L)
  assert_eq(root_scopes.length(), 1)
  assert_eq(root_scopes[0].round, 42L)
  assert_eq(root_scopes[0].root, 0L)
  // 分支根落库拿到 id 后回填 root=self
  let new_task = mk(99L)
  @engine.put_scopes(new_task, root_scopes)
  assert_eq(@engine.fill_root_self(new_task), true)
  assert_eq(@engine.scopes_of(new_task.variables)[0].root, 99L)
  // 非根：继承父任务同（fork,join）那一档的 round/root
  let parent_in_branch = mk(42L)
  @engine.put_scopes(
    parent_in_branch,
    [{ fork: "fork1", join: "join1", round: 7L, root: 8L }],
  )
  let inherited = @engine.build_scopes(Some(parent_in_branch), model, "taskA2", 0L)
  assert_eq(inherited.length(), 1)
  assert_eq(inherited[0].round, 7L)
  assert_eq(inherited[0].root, 8L)
}

///|
/// `reapplyMode` 两档解析：缺省 NORMAL、RETURN_TO_SOURCE 原样收；非法值在**解析期**报错。
test "reapply-10 reapplyMode 解析与非法值报错" {
  // 合法档（14 号夹具：taskA 直返、taskB 缺省）
  let model = @parser.parse_model(
    "{\"name\":\"m\",\"nodes\":[{\"id\":\"taskA\",\"type\":\"snaker:task\",\"properties\":{\"reapplyMode\":\"RETURN_TO_SOURCE\"}},{\"id\":\"taskB\",\"type\":\"snaker:task\"}],\"edges\":[]}",
  )
  assert_eq(model.get_node("taskA").unwrap().reapply_mode(), "RETURN_TO_SOURCE")
  assert_eq(model.get_node("taskA").unwrap().is_return_to_source(), true)
  assert_eq(model.get_node("taskB").unwrap().reapply_mode(), "NORMAL")
  assert_eq(model.get_node("taskB").unwrap().is_return_to_source(), false)
  // 非法档：解析期即失败（不静默当缺省）
  let err = try {
    let _ = @parser.parse_model(
      "{\"name\":\"bad\",\"nodes\":[{\"id\":\"a1\",\"type\":\"snaker:task\",\"properties\":{\"reapplyMode\":\"RETURN_HOME\"}}],\"edges\":[]}",
    )
    None
  } catch {
    e => Some(e)
  }
  match err {
    None => fail("非法 reapplyMode 必须在解析期报错")
    Some(e) => {
      assert_true(e.message().contains("reapplyMode"))
      assert_true(e.message().contains("a1"))
    }
  }
}
