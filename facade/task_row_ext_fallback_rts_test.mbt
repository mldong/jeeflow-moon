// spec 04 保留键 × issues/82-3 回退（**内容级**判据，门面出口视角）。
//
// 建单现在往每条任务变量写 `_branchCtx`（空分支也写 []），两枚直返保留键必须算进「引擎控制键」，
// 否则 ① 每条任务行从此不再回退实例变量（前端在任务行上拿不到 f_*/u_*/autoGenTitle），
// ② 内部键直接从公开出口透出。本轮八栈齐漏——只有 php 的 PDO 仓有内容级断言才报红，其余七栈
// 的既有 82-3 用例只断"容器是对象"，照不出回退有没有真发生。
// 但 `_reapplyContext` 是前端「重新提交后返回：X」的唯一取数口（jeeflow-ui helpers.ts 读
// ext._reapplyContext）⇒ 回退后原样合回，且不得污染同一响应的 instanceExt 出口。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / rows_of / parse_iid / task_by_name。

///|
/// Json 对象 → Map（非对象给空 Map，让断言去报红而不是这里崩）
fn rte_obj(v : Json?) -> Map[String, Json] {
  match v {
    Some(Json::Object(m)) => m
    _ => Map([])
  }
}

///|
fn rte_dump(m : Map[String, Json]) -> String {
  let o = @json.empty_object()
  for k, v in m {
    @json.obj_set(o, k, v)
  }
  @json.stringify(o)
}

///|
/// a 的每个键都在 b 里且值逐字相等（Json 比较走 stringify，避开派生 Eq 的形状差异）
fn rte_same(a : Map[String, Json], b : Map[String, Json]) -> Bool {
  let mut ok = a.length() == b.length()
  for k, v in a {
    match b.get(k) {
      Some(w) =>
        if @json.stringify(v) != @json.stringify(w) {
          ok = false
        }
      None => ok = false
    }
  }
  ok
}

///|
/// 取指定 action 的首行（空集合即 abort，防"节点名写错→空行→假绿"）
async fn rte_first_row(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  action : String,
  entries : Array[(String, String)]
) -> Json raise {
  let env = facade.flow(action, targs(entries))
  if code_of(env) != 0L {
    abort("[rts-ext-fallback] " + action + " code≠0（msg=" + msg_of(env) + "）")
  }
  let rows = rows_of(data_of(env))
  if rows.is_empty() {
    abort("[rts-ext-fallback] " + action + " 应出行，实得空")
  }
  rows[0]
}

///|
async test "rts-ext 任务行 ext 回退实例变量、内部键不透出；直返申请待办合回 _reapplyContext" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let content = $|{"name":"rts-ext","displayName":"RTSExt","type":"approval",
$| "nodes":[{"id":"start","type":"snaker:start","text":{"value":"Start"}},
$| {"id":"apply","type":"snaker:task","text":{"value":"Apply"},"properties":{"assignee":"applicant"}},
$| {"id":"taskA","type":"snaker:task","text":{"value":"A"},"properties":{"assignee":"userA","reapplyMode":"RETURN_TO_SOURCE"}},
$| {"id":"taskB","type":"snaker:task","text":{"value":"B"},"properties":{"assignee":"userB"}},
$| {"id":"end","type":"snaker:end","text":{"value":"End"}}],
$| "edges":[{"id":"e1","sourceNodeId":"start","targetNodeId":"apply"},
$| {"id":"e2","sourceNodeId":"apply","targetNodeId":"taskA"},
$| {"id":"e3","sourceNodeId":"taskA","targetNodeId":"taskB"},
$| {"id":"e4","sourceNodeId":"taskB","targetNodeId":"end"}]}
  let define_info : @model.ProcessDefine = {
    id: 0L, name: "rts-ext", display_name: "RTSExt", define_type: "approval",
    state: 1, content, version: 1, create_time: None, create_user: None,
    update_time: None, update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([
      ("processDefineId", define_info.id.to_string()),
      ("operator", "applicant"),
      ("f_reason", "unit-test"),
    ]),
  )
  if code_of(env) != 0L {
    abort("[rts-ext-fallback] startAndExecute 失败（msg=" + msg_of(env) + "）")
  }
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))

  // ── ① 普通任务行：变量只剩 isFirstTaskNode + _branchCtx ⇒ ext 回退实例变量 ──
  let row = rte_first_row(facade, "processTask/todoList", [("operator", "userA")])
  let ext = rte_obj(@json.get(row, "ext"))
  let i_ext = rte_obj(@json.get(row, "instanceExt"))
  if i_ext.is_empty() {
    abort("[rts-ext-fallback] 前置：instanceExt 必须非空，否则回退断言恒真空 → " + rte_dump(i_ext))
  }
  if ext.get(@engine.var_branch_ctx) is Some(_) {
    abort("[rts-ext-fallback] 内部键 _branchCtx 不得从任务行 ext 透出（spec 04）: " + rte_dump(ext))
  }
  if !rte_same(ext, i_ext) {
    abort("[rts-ext-fallback] ext 应恰为实例变量（82-3 / 121 P1）: " + rte_dump(ext) + " vs " + rte_dump(i_ext))
  }

  // ── ② 直返申请待办：ext = 实例变量 + _reapplyContext，仍不带 _branchCtx ──
  let task_a = task_by_name(repo, iid, "taskA")
  let env_ret = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", task_a.task_id.to_string()),
      ("operator", "userA"),
      ("submitType", "6"),
    ]),
  )
  if code_of(env_ret) != 0L {
    abort("[rts-ext-fallback] 退回发起人应成功（msg=" + msg_of(env_ret) + "）")
  }
  let env_todo = facade.flow(
    "processTask/todoList",
    targs([("operator", "applicant"), ("pageSize", "100")]),
  )
  if code_of(env_todo) != 0L {
    abort("[rts-ext-fallback] 退回后 applicant todoList code≠0（msg=" + msg_of(env_todo) + "）")
  }
  let rows = rows_of(data_of(env_todo))
  let marked = rows.filter(fn(r) { rte_obj(@json.get(r, "ext")).get(@engine.var_reapply_ctx) is Some(_) })
  if marked.length() != 1 {
    abort("[rts-ext-fallback] 应恰有一条带 _reapplyContext 的申请待办，实得 " + @json.stringify(@json.array_of(rows)))
  }
  let app = marked[0]
  let a_ext = rte_obj(@json.get(app, "ext"))
  let a_i = rte_obj(@json.get(app, "instanceExt"))
  for k, _ in a_i {
    if a_ext.get(k) is None {
      abort("[rts-ext-fallback] 回退仍要发生：实例变量键 " + k + " 应在 ext 上 → " + rte_dump(a_ext))
    }
  }
  if a_ext.get(@engine.var_branch_ctx) is Some(_) {
    abort("[rts-ext-fallback] 内部键 _branchCtx 不得从 ext 透出: " + rte_dump(a_ext))
  }
  let rc = match a_ext.get(@engine.var_reapply_ctx) {
    Some(v) => v
    None => @json.null_json()
  }
  if @json.get_str(rc, "sourceNode").unwrap_or("") != "taskA" {
    abort("[rts-ext-fallback] 来源节点应可读（前端提示就取这一格）: " + @json.stringify(rc))
  }
  if a_i.get(@engine.var_reapply_ctx) is Some(_) {
    abort("[rts-ext-fallback] 合回不得污染同一响应里的 instanceExt 出口: " + rte_dump(a_i))
  }
}
