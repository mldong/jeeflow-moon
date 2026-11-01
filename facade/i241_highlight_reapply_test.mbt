// issues/241 · `highLight` 重放腿在决策节点必须按**任务行佐证**选边，不得按重提后的
// 实例变量重算（直返契约：来源节点之前的条件分支不重算）。
//
// 夹具：start → apply → fork →(taskA / taskB)→ join → decision1{f_amount>1000 → taskHigh(直返) |
// f_amount<=1000 → taskLow} → end。走单：6666 走 taskHigh → 退回发起人 → 改为 666 重提 →
// 新待办仍落 taskHigh。高亮必须只点亮实际走过的 e7 侧，不得把 taskLow/e8/e10 算进历史。
//
// 决策节点的入边来源刻意放成 join（网关不产任务行）：任务行快照实例变量的栈
// 在「任务行前置」夹具上会被旧的最老行合并偶然救活，join 入边让那条通道失效。
// 条件字段用 f_ 前缀：本栈 complete_task 只把 f_ 键并回实例变量（引擎既有口径）。
//
// 复用同包 helper：i153_check / i153_str_list / i153_join / i159_args / targs / code_of /
// msg_of / data_of / parse_iid / doing_task_for。

///|
fn i241_join_flow() -> String {
  let s = $|{"name": "i241-return-highlight-join", "displayName": "直返重提高亮（汇合后分支）",
  $| "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "fork1", "type": "snaker:fork", "properties": {}},
  $|   {"id": "taskA", "type": "snaker:task",
  $|    "properties": {"assignee": "userA", "taskType": 0, "performType": 0}},
  $|   {"id": "taskB", "type": "snaker:task",
  $|    "properties": {"assignee": "userB", "taskType": 0, "performType": 0}},
  $|   {"id": "join1", "type": "snaker:join", "properties": {}},
  $|   {"id": "decision1", "type": "snaker:decision", "properties": {"expr": "f_amount > 1000"}},
  $|   {"id": "taskHigh", "type": "snaker:task",
  $|    "properties": {"assignee": "director", "taskType": 0, "performType": 0,
  $|                   "reapplyMode": "RETURN_TO_SOURCE"}},
  $|   {"id": "taskLow", "type": "snaker:task",
  $|    "properties": {"assignee": "manager", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply", "properties": {}},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "fork1", "properties": {}},
  $|   {"id": "e2", "sourceNodeId": "fork1", "targetNodeId": "taskA", "properties": {}},
  $|   {"id": "e3", "sourceNodeId": "fork1", "targetNodeId": "taskB", "properties": {}},
  $|   {"id": "e4", "sourceNodeId": "taskA", "targetNodeId": "join1", "properties": {}},
  $|   {"id": "e5", "sourceNodeId": "taskB", "targetNodeId": "join1", "properties": {}},
  $|   {"id": "e6", "sourceNodeId": "join1", "targetNodeId": "decision1", "properties": {}},
  $|   {"id": "e7", "sourceNodeId": "decision1", "targetNodeId": "taskHigh",
  $|    "properties": {"expr": "f_amount > 1000"}},
  $|   {"id": "e8", "sourceNodeId": "decision1", "targetNodeId": "taskLow",
  $|    "properties": {"expr": "f_amount <= 1000"}},
  $|   {"id": "e9", "sourceNodeId": "taskHigh", "targetNodeId": "end", "properties": {}},
  $|   {"id": "e10", "sourceNodeId": "taskLow", "targetNodeId": "end", "properties": {}}
  $| ]}
$|
  s
}

///|
async fn i241_exec(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  task : @model.ProcessTask,
  operator : String,
  submit : String,
  extra? : Array[(String, Json)]
) -> Json raise {
  let entries : Array[(String, Json)] = [
    ("processTaskId", @json.string_of(task.task_id.to_string())),
    ("operator", @json.string_of(operator)),
    ("submitType", @json.string_of(submit)),
  ]
  for e in extra.unwrap_or([]) {
    entries.push(e)
  }
  facade.flow("processTask/execute", i159_args(entries))
}

///|
async test "i241 直返重提后 highLight 不得点亮未走分支" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i241-return-highlight-join",
    display_name: "直返重提高亮（汇合后分支）",
    define_type: "approval",
    state: 1,
    content: i241_join_flow(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env_start = facade.flow(
    "processInstance/startAndExecute",
    i159_args([
      ("processDefineId", @json.string_of(define_info.id.to_string())),
      ("operator", @json.string_of("zhangsan")),
      ("f_amount", @json.number_of(6666L)),
    ]),
  )
  i153_check(code_of(env_start) == 0L, "发起 code=0（msg=\{msg_of(env_start)}）")
  let iid = parse_iid(@json.get_str(data_of(env_start), "processInstanceId").unwrap_or("0"))

  let e_a = i241_exec(facade, doing_task_for(repo, iid, "userA"), "userA", "1")
  i153_check(code_of(e_a) == 0L, "并行分支 taskA 办结 code=0（msg=\{msg_of(e_a)}）")
  let e_b = i241_exec(facade, doing_task_for(repo, iid, "userB"), "userB", "1")
  i153_check(code_of(e_b) == 0L, "并行分支 taskB 办结 code=0（msg=\{msg_of(e_b)}）")

  let high = doing_task_for(repo, iid, "director")
  i153_check(high.task_name == "taskHigh", "夹具自证：汇合后 6666 应走 taskHigh")
  let e_ret = i241_exec(facade, high, "director", "6")
  i153_check(code_of(e_ret) == 0L, "退回发起人 code=0（msg=\{msg_of(e_ret)}）")

  let apply = doing_task_for(repo, iid, "zhangsan")
  let e_reapply = i241_exec(facade, apply, "zhangsan", "5", extra=[("f_amount", @json.number_of(666L))])
  i153_check(code_of(e_reapply) == 0L, "重提 code=0（msg=\{msg_of(e_reapply)}）")
  let again = doing_task_for(repo, iid, "director")
  i153_check(again.task_name == "taskHigh", "重提必须回原来源节点")

  let data = data_of(facade.flow("processInstance/highLight", targs([("id", iid.to_string())])))
  let edges = i153_str_list(data, "historyEdgeNames")
  let nodes = i153_str_list(data, "historyNodeNames")
  i153_check(
    edges.contains("e7"),
    "汇合后的实际分支 e7 必须点亮（实际 \{i153_join(edges)}）",
  )
  i153_check(!edges.contains("e8"), "未走分支 e8 不得点亮（实际 \{i153_join(edges)}）")
  i153_check(!edges.contains("e10"), "未走分支 e10 不得点亮（实际 \{i153_join(edges)}）")
  i153_check(!nodes.contains("taskLow"), "未走节点 taskLow 不得进历史（实际 \{i153_join(nodes)}）")
  i153_check(!nodes.contains("end"), "未走节点 end 不得进历史（实际 \{i153_join(nodes)}）")
}
