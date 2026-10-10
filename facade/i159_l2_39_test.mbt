// issues/159 · L2-39 的门面级判据（跨栈门禁 runner.py `decision_flow` 同形夹具，端到端）：
// start → apply → task1 → decision1(expr amount>1000 / amount<=1000) →(yes)task2 /(no)task3 → end。
// amount=5000 发起 ⇒ 办掉 task1 ⇒ **活跃节点必须是 task2**（159 §4.1 点名的"停在分支上"档：
// 线性流与"分支已办完"的流都恒真，测不到这一跳）。
//
// 同时钉边名出口（159 读数 3）：决策出边带 `text.value` 标签，参考实现 java
// `AbstractNodeParser` `tm.setName(edge.getId())` ⇒ 出口必须是**边 id**，label 不得优先——
// 修前 `collect_path` 的 `match tm.label { Some(l)…; None => Some(tm.id) }` 会把
// `大于1000`/`不大于1000` 顶到 historyEdgeNames 里（157 轮探针实测读数）。
//
// 复用同包 helper：i153_check / i153_str_list / i153_join / targs / code_of / msg_of /
// data_of / parse_iid / doing_task_for（i153 与 withdraw_transfer 文件里定义，同包可见）。

///|
/// runner.py decision_flow 同形：裸名 expr（spec 06 §4.6 义务 2 的代入档）＋带 text 标签的边
fn i159_decision_flow() -> String {
  let s = $|{"name": "i159-dec", "displayName": "决策落支夹具", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "decision1", "type": "snaker:decision", "properties": {}},
  $|   {"id": "task2", "type": "snaker:task",
  $|    "properties": {"assignee": "boss", "taskType": 0, "performType": 0}},
  $|   {"id": "task3", "type": "snaker:task",
  $|    "properties": {"assignee": "hr", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply", "properties": {}},
  $|   {"id": "e_apply_1", "sourceNodeId": "apply", "targetNodeId": "task1", "properties": {}},
  $|   {"id": "e_to_dec", "sourceNodeId": "task1", "targetNodeId": "decision1", "properties": {}},
  $|   {"id": "e_dec_yes", "sourceNodeId": "decision1", "targetNodeId": "task2",
  $|    "properties": {"expr": "amount > 1000"}, "text": {"value": "大于1000"}},
  $|   {"id": "e_dec_no", "sourceNodeId": "decision1", "targetNodeId": "task3",
  $|    "properties": {"expr": "amount <= 1000"}, "text": {"value": "不大于1000"}},
  $|   {"id": "e2_end", "sourceNodeId": "task2", "targetNodeId": "end", "properties": {}},
  $|   {"id": "e3_end", "sourceNodeId": "task3", "targetNodeId": "end", "properties": {}}
  $| ]}
$|
  s
}

///|
/// args 构造（Json 值形态——runner 发起用数字 5000，不是字符串档）
fn i159_args(entries : Array[(String, Json)]) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for e in entries {
    let (k, v) = e
    m[k] = v
  }
  m
}

///|
/// 发起＋办掉 task1。amount=None ⇒ 缺失变量档（issues/164 领地的入口形状）。
async fn i159_run_branch(
  amount : Json?
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64, Json) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i159-dec",
    display_name: "决策落支夹具",
    define_type: "approval",
    state: 1,
    content: i159_decision_flow(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let entries : Array[(String, Json)] = [
    ("processDefineId", @json.string_of(define_info.id.to_string())),
    ("operator", @json.string_of("applicant")),
  ]
  match amount {
    Some(v) => entries.push(("amount", v))
    None => ()
  }
  let env_start = facade.flow("processInstance/startAndExecute", i159_args(entries))
  i153_check(code_of(env_start) == 0L, "发起 code=0（msg=\{msg_of(env_start)}）")
  let iid = parse_iid(@json.get_str(data_of(env_start), "processInstanceId").unwrap_or("0"))
  let t1 = doing_task_for(repo, iid, "leader")
  let e2 = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", t1.task_id.to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
    ]),
  )
  (facade, repo, iid, e2)
}

///|
async fn i159_highlight(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  iid : Int64,
) -> Json raise {
  let env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i153_check(code_of(env) == 0L, "highLight code=0（msg=\{msg_of(env)}）")
  data_of(env)
}

///|
/// 主档：amount=5000 ⇒ 走 task2（停在分支上），边名出口是 id，label 与未走分支都不亮。
/// 修前此格三处必红：active=task3（死臂蒙方向）、edges 带 label、e_dec_no 未过滤。
async test "i159 停在分支上 amount=5000 走 task2 且边名出口取 id" {
  let (facade, _repo, iid, e2) = i159_run_branch(Some(@json.number_of(5000L)))
  i153_check(code_of(e2) == 0L, "task1 办结 code=0（msg=\{msg_of(e2)}）")
  let data = i159_highlight(facade, iid)
  let active = i153_str_list(data, "activeNodeNames")
  let edges = i153_str_list(data, "historyEdgeNames")
  let nodes = i153_str_list(data, "historyNodeNames")
  i153_check(
    active.contains("task2"),
    "活跃节点必须是 task2（实际 \{i153_join(active)}）——159 读数 1 落错支档",
  )
  i153_check(!active.contains("task3"), "task3 是未走分支，不得活跃")
  for k in ["e0", "e_apply_1", "e_to_dec", "e_dec_yes"] {
    i153_check(edges.contains(k), "边 \{k} 必须以 id 点亮（实际 \{i153_join(edges)}）")
  }
  i153_check(!edges.contains("e_dec_no"), "未走分支 e_dec_no 不得点亮（实际 \{i153_join(edges)}）")
  i153_check(
    !edges.contains("大于1000") && !edges.contains("不大于1000"),
    "边名出口取 id，text 标签不得顶替（159 读数 3；实际 \{i153_join(edges)}）",
  )
  i153_check(
    !nodes.contains("task3") && !nodes.contains("end"),
    "未走分支节点与 end 不得被点亮（实际 \{i153_join(nodes)}）",
  )
  i153_check(nodes.contains("decision1"), "decision1 不产任务行，由模型补全腿点亮")
}

///|
/// 反档 amount=500 ⇒ 走 task3：两臂对称翻转，"固定走某一边"的实现在这里红。
async test "i159 反档 amount=500 走 task3" {
  let (facade, _repo, iid, e2) = i159_run_branch(Some(@json.number_of(500L)))
  i153_check(code_of(e2) == 0L, "task1 办结 code=0（msg=\{msg_of(e2)}）")
  let data = i159_highlight(facade, iid)
  let active = i153_str_list(data, "activeNodeNames")
  let edges = i153_str_list(data, "historyEdgeNames")
  i153_check(active.contains("task3"), "amount=500 ⇒ 活跃 task3（实际 \{i153_join(active)}）")
  i153_check(edges.contains("e_dec_no"), "反档走过的 e_dec_no 以 id 点亮（实际 \{i153_join(edges)}）")
  i153_check(!edges.contains("e_dec_yes"), "未走分支 e_dec_yes 不得点亮")
  i153_check(
    !edges.contains("大于1000") && !edges.contains("不大于1000"),
    "label 不得顶替 id（实际 \{i153_join(edges)}）",
  )
}

///|
/// 缺失变量档：两支都不亮（spec：非数字操作数判 false ⇒ 无命中）。
/// 无命中后的行为（停住 vs 报错）是 issues/164 的领地，本格只钉"不蒙方向"——
/// 修前 `<=` 死臂会把 no 边蒙真 ⇒ task3 活跃，此格必红。
async test "i159 缺失变量不蒙方向" {
  let (facade, _repo, iid, _e2) = i159_run_branch(None)
  let data = i159_highlight(facade, iid)
  let active = i153_str_list(data, "activeNodeNames")
  let edges = i153_str_list(data, "historyEdgeNames")
  i153_check(
    !active.contains("task2") && !active.contains("task3"),
    "缺失变量时任何分支都不得被蒙亮（实际 active=\{i153_join(active)}）",
  )
  i153_check(
    !edges.contains("e_dec_yes") && !edges.contains("e_dec_no"),
    "无命中档决策出边都不收（实际 \{i153_join(edges)}）",
  )
}
