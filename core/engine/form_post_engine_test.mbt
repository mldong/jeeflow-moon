// issues/259：两枚岗位 handler 经运行时注册表进入真实引擎取人链并落成待办。

///|
fn make_fp_engine(
  provider : @spi.PostUserProviderFns?,
) -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  @itl.register_post_assignment_handlers(ctx2, provider)
  (@engine.Engine::make(ctx2), repo)
}

///|
fn fp_flow_json(node_id : String, handler_fqn : String) -> String {
  let s =
    $|  {"name": "post-assignment", "displayName": "岗位分配", "type": "approval",
    $|   "nodes": [
    $|     {"id": "start", "type": "snaker:start", "text": {"value": "开始"}},
    $|     {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
    $|      "properties": {"assignee": "applicant"}},
    $|     {"id": "NODE_ID", "type": "snaker:task", "text": {"value": "岗位办理"},
    $|      "properties": {"assignmentHandler": "HANDLER_FQN"}},
    $|     {"id": "end", "type": "snaker:end", "text": {"value": "结束"}}
    $|   ],
    $|   "edges": [
    $|     {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
    $|     {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "NODE_ID"},
    $|     {"id": "e3", "sourceNodeId": "NODE_ID", "targetNodeId": "end"}
    $|   ]}
    $|
  s.replace_all(old="HANDLER_FQN", new=handler_fqn).replace_all(old="NODE_ID", new=node_id)
}

///|
async fn fp_start_to_assignment(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  define_id : Int64,
  args : @json.FlowData,
) -> Int64 raise {
  let inst = engine.start_async(define_id, "applicant", args)
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  for task in tasks {
    if task.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(task.task_id, "applicant", new_args())
      break
    }
  }
  inst.instance_id
}

///|
async test "fp-engine: TaskPost 注册后按节点编码生成岗位成员待办" {
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      if code == "archive_clerk" { ["archivist1", "archivist2"] } else { [] }
    },
  }
  let (engine, repo) = make_fp_engine(Some(provider.to_async()))
  let did = save_flow_define(
    repo,
    "post-assignment",
    fp_flow_json(
      "archive_clerk",
      "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskPostAssigneeHandler",
    ),
  )
  let iid = fp_start_to_assignment(engine, repo, did, new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].task_name, "archive_clerk")
  assert_true(tasks[0].actor_ids == ["archivist1", "archivist2"])
}

///|
async test "fp-engine: FormPost 注册后按表单多岗位生成合并去重待办" {
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      match code {
        "postA" => ["userA", "shared"]
        "postB" => ["userB", "shared"]
        _ => []
      }
    },
  }
  let (engine, repo) = make_fp_engine(Some(provider.to_async()))
  let did = save_flow_define(
    repo,
    "post-assignment",
    fp_flow_json(
      "approver",
      "com.mldong.jeeflow.interceptor.impl.FormPostAssignmentHandler",
    ),
  )
  let args = new_args()
  args.insert_str("f_approver", "postA,postB")
  let iid = fp_start_to_assignment(engine, repo, did, args)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_true(tasks[0].actor_ids == ["userA", "shared", "userB"])
}

///|
async test "fp-engine: 未注入 Provider 时注册表仍有实体，handler 折空且流程不抛" {
  let (engine, repo) = make_fp_engine(None)
  let did = save_flow_define(
    repo,
    "post-assignment",
    fp_flow_json(
      "archive_clerk",
      "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskPostAssigneeHandler",
    ),
  )
  let iid = fp_start_to_assignment(engine, repo, did, new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  // 本栈既有引擎契约：任务类零参与者仍建 DOING 行（issues/142 A），不兜底挂操作人。
  assert_eq(tasks.length(), 1)
  assert_eq(tasks[0].actor_ids.length(), 0)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
}
