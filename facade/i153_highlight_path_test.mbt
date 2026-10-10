// issues/153 · spec 06 §4.6「三条义务」中义务 2（historyEdgeNames ＝求值为 true 的决策出边）
// 与义务 3（nodeProgress 成员 name 经 IUserProvider 解析，只有查不到才空串）的门面级判据。
//
// 基准（现读，语义未自创）：
// · go `jeeflow-go/facade/facade.go:1233-1270` `collectPath`＋`evalDecisionExpr`——带 expr 的
//   决策出边先求值，判 false 的**边名与目标节点都不收**；args＝实例变量 ∪ 决策节点前置任务变量。
// · java `JeeflowFacade.java:707-710`（同一判据）＋ `:735-746`（求值入参）。
// · 判据形状取 java `JeeflowFacadeTest.java:1207-1213`：走过的边在、未走分支的边不在。
// · 义务 3 的 name 判据取 java `JeeflowFacade.java:689-697` `resolveUserName`。
//
// 修前形状（本栈）：`collect_path` 收了 `instance_vars`/`history_tasks` 两参却一次没用 ⇒
// 决策节点的每条出边一律收；`build_node_progress` 的 name 硬编码空串（注释说"由调用方注入
// user provider 前先空串"，但不存在那个调用方）。两处各自都有本文件下方的用例钉住。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / parse_iid / doing_task_for。

///|
fn i153_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i153-highLight] 红样：" + "\{label}")
    abort("[i153-highLight] 红样：" + "\{label}")
  }
}

///|
/// 决策夹具：start →apply→ task1 →decision1，decision1 两条**带 expr** 的出边
///   e_vip  = `${level} == vip` → vip_task  → end
///   e_norm = `${level} != vip` → norm_task → end
/// 出边不带 `text` ⇒ 本栈边名回落 `id`（`collect_path` 的 label-or-id 口径），断言可以直接
/// 钉在 e_vip / e_norm 这两个字面上（java 那支钉的是 e4/e6/e3，同形）。
/// 表达式取 `${var} == 字面量` 形：`==`/`!=` 与 `>`/`<=` 都已在内置兜底里判对
/// （`>`/`<=` 曾恒假/恒真，0.1.36 由 issues/159 收口）；本夹具保留 ==/!= 形作为等式档的独立覆盖。
fn i153_decision_flow() -> String {
  let s = $|{"name": "i153-dec", "displayName": "决策高亮夹具", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "decision1", "type": "snaker:decision", "properties": {}},
  $|   {"id": "vip_task", "type": "snaker:task",
  $|    "properties": {"assignee": "boss", "taskType": 0, "performType": 0}},
  $|   {"id": "norm_task", "type": "snaker:task",
  $|    "properties": {"assignee": "hr", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply", "properties": {}},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "task1", "properties": {}},
  $|   {"id": "e2", "sourceNodeId": "task1", "targetNodeId": "decision1", "properties": {}},
  $|   {"id": "e_vip", "sourceNodeId": "decision1", "targetNodeId": "vip_task",
  $|    "properties": {"expr": "${level} == vip"}},
  $|   {"id": "e_norm", "sourceNodeId": "decision1", "targetNodeId": "norm_task",
  $|    "properties": {"expr": "${level} != vip"}},
  $|   {"id": "e_vip_end", "sourceNodeId": "vip_task", "targetNodeId": "end", "properties": {}},
  $|   {"id": "e_norm_end", "sourceNodeId": "norm_task", "targetNodeId": "end", "properties": {}}
  $| ]}
$|
  s
}

///|
/// highLight 出口的字符串数组（activeNodeNames / historyNodeNames / historyEdgeNames 共用）
fn i153_str_list(data : Json, key : String) -> Array[String] {
  match @json.get(data, key) {
    Some(Json::Array(a)) => a.map(fn(x) { @json.as_str(x).unwrap_or("<非字符串项>") })
    _ => []
  }
}

///|
/// IUserProvider 台账（形状照 core/engine/compliance_test.mbt:56-59 的 `let … : (String) -> UserInfo? raise JeeflowError = (uid) => …`）：
/// 只认 leader 一人 ⇒ task1 的成员是"命中档"，apply 的成员 applicant 是"查不到档"，两档同批对照。
let i153_user_provider : (String) -> @model.UserInfo? raise @error.JeeflowError =
  (uid) =>
    if uid == "leader" {
      Some(@model.UserInfo::make(user_id=uid, real_name="李队"))
    } else {
      None
    }

///|
/// 走到决策之后的实例：level 决定选哪条边（引擎与高亮共用同一个求值口 ⇒ 两处必须同臂）。
/// with_users=false ⇒ 不注册 IUserProvider（义务 3 的降级档对照组）。
async fn i153_run(
  level : String,
  with_users : Bool
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  if with_users {
    let _ = ctx2.with_user_provider_sync(i153_user_provider)
  }
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i153-dec",
    display_name: "决策高亮夹具",
    define_type: "approval",
    state: 1,
    content: i153_decision_flow(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([
      ("processDefineId", define_info.id.to_string()),
      ("operator", "applicant"),
      ("level", level),
    ]),
  )
  i153_check(code_of(env) == 0L, "发起 code=0（msg=\{msg_of(env)}）")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  // 办结 task1 ⇒ 令牌进 decision1 由引擎选边
  let t1 = doing_task_for(repo, iid, "leader")
  let e2 = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", t1.task_id.to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
    ]),
  )
  i153_check(code_of(e2) == 0L, "task1 办结 code=0（msg=\{msg_of(e2)}）")
  (facade, iid)
}

///|
async fn i153_highlight(facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], iid : Int64) -> Json raise {
  let env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i153_check(code_of(env) == 0L, "highLight code=0（msg=\{msg_of(env)}）")
  data_of(env)
}

///|
/// 义务 2 · vip 档：走过的决策边 e_vip 在，未走分支 e_norm 与 norm_task 都不在。
/// 修前形状（决策出边一律收）在这一格必红。
async test "i153义务2 vip 档 historyEdgeNames 恰为 true 边集合" {
  let (facade, iid) = i153_run("vip", false)
  let data = i153_highlight(facade, iid)
  let edges = i153_str_list(data, "historyEdgeNames")
  let nodes = i153_str_list(data, "historyNodeNames")
  let active = i153_str_list(data, "activeNodeNames")
  i153_check(
    active.contains("vip_task"),
    "夹具自证：vip 档引擎确实走去了 vip_task（activeNodeNames=\{i153_join(active)}）",
  )
  for k in ["e0", "e1", "e2", "e_vip"] {
    i153_check(edges.contains(k), "走过的边 \{k} 必须点亮（实际 historyEdgeNames=\{i153_join(edges)}）")
  }
  i153_check(
    !edges.contains("e_norm"),
    "未走分支的决策边 e_norm 不得点亮——修前形状＝决策出边一律收（实际 \{i153_join(edges)}）",
  )
  i153_check(
    !nodes.contains("norm_task"),
    "未走分支的目标节点 norm_task 不得点亮（false 边的边名与目标节点都不收）",
  )
  i153_check(
    nodes.contains("decision1"),
    "decision1 不产任务行，只可能由模型补全腿进来（义务 1 第二条腿在位）",
  )
  i153_check(
    !edges.contains("e_vip_end"),
    "遇活跃节点停止深入：vip_task 之后的 e_vip_end 不收（实际 \{i153_join(edges)}）",
  )
  i153_check(!nodes.contains("end"), "同理 end 节点不得越过活跃节点被点亮")
}

///|
/// 义务 2 · 反档（level≠vip）：两臂必须对称翻转。这一格钉的是"求值真的在起作用"，
/// 任何"恒 true / 恒 false / 固定取第一条边"的实现都会在这里红。
async test "i153义务2 反档 historyEdgeNames 随表达式取值翻转" {
  let (facade, iid) = i153_run("normal", false)
  let data = i153_highlight(facade, iid)
  let edges = i153_str_list(data, "historyEdgeNames")
  let nodes = i153_str_list(data, "historyNodeNames")
  let active = i153_str_list(data, "activeNodeNames")
  i153_check(
    active.contains("norm_task"),
    "夹具自证：非 vip 档引擎走去 norm_task（activeNodeNames=\{i153_join(active)}）",
  )
  i153_check(
    edges.contains("e_norm"),
    "反档走过的 e_norm 必须点亮（实际 \{i153_join(edges)}）",
  )
  i153_check(
    !edges.contains("e_vip"),
    "反档里 e_vip 成了未走分支，不得点亮（恒 true 的实现会在这里红）",
  )
  i153_check(!nodes.contains("vip_task"), "反档未走分支的目标节点 vip_task 不得点亮")
}

///|
/// 义务 3：nodeProgress 成员 name 经 IUserProvider 解析；provider 命中出姓名，查不到才空串。
/// 修前形状＝硬编码空串 ⇒ "命中出姓名"这一格必红。
async test "i153义务3 nodeProgress 成员 name 走 IUserProvider" {
  let (facade, iid) = i153_run("vip", true)
  let data = i153_highlight(facade, iid)
  let np = match @json.get(data, "nodeProgress") {
    Some(Json::Object(obj)) => obj
    _ => Map([])
  }
  // 命中档：task1 的办理人 leader 在 provider 台账里 ⇒ name＝李队
  let hit = i153_first_member(np, "task1")
  i153_check(hit != @json.null_json(), "task1 必须有成员进度（实际 nodeProgress=\{i153_join(i153_map_keys(np))}）")
  i153_check(
    @json.get(hit, "name") is Some(Json::String(_)),
    "命中的 name 键必须存在且是字符串",
  )
  i153_check(
    @json.get_str(hit, "name").unwrap_or("<缺>") == "李队",
    "provider 命中 ⇒ name＝李队（修前形状＝硬编码空串；实际 <\{@json.get_str(hit, "name").unwrap_or("<缺>")}>）",
  )
  // 查不到档：apply 的办理人 applicant 不在 provider 台账里 ⇒ 空串（义务 3 唯一允许的空串）
  let miss = i153_first_member(np, "apply")
  i153_check(miss != @json.null_json(), "apply 必须有成员进度")
  i153_check(@json.get(miss, "name") is Some(Json::String(_)), "查不到的 name 键仍在且是字符串")
  i153_check(
    @json.get_str(miss, "name").unwrap_or("<缺>") == "",
    "provider 查不到 ⇒ 空串（前端降级显示 id）",
  )
  i153_check(
    @json.get_str(miss, "id").unwrap_or("<缺>") == "applicant",
    "成员 id 仍是用户 id 本体（name 空不许把 id 也吞掉）",
  )
}

///|
/// 对照组：IUserProvider **未注册**（义务 3 的降级档）⇒ 全员空串，但键仍在、id 仍在。
async test "i153义务3 对照组 provider 未注册才允许全员空串" {
  let (facade, iid) = i153_run("vip", false)
  let data = i153_highlight(facade, iid)
  let np = match @json.get(data, "nodeProgress") {
    Some(Json::Object(obj)) => obj
    _ => Map([])
  }
  let m = i153_first_member(np, "task1")
  i153_check(m != @json.null_json(), "task1 必须有成员进度（成员进度缺位＝该节点没被登记）")
  i153_check(
    @json.get_str(m, "name").unwrap_or("<缺>") == "",
    "SPI 未注册 ⇒ 空串（这一档才是 spec 许可的降级档）",
  )
  i153_check(@json.get_str(m, "id").unwrap_or("<缺>") == "leader", "未注册不影响 id 出口")
}

///|
/// nodeProgress.{节点}.members[0]（没有则返回 Json::Null）
fn i153_first_member(np : Map[String, Json], node : String) -> Json {
  match np.get(node) {
    Some(item) =>
      match @json.get(item, "members") {
        Some(Json::Array(a)) => if a.length() > 0 { a[0] } else { @json.null_json() }
        _ => @json.null_json()
      }
    None => @json.null_json()
  }
}

///|
/// 数组渲染（消息用；本栈 core 的 inspect 不可用、to_string 走已废弃的 Show，故自带一枚）
fn i153_join(items : Array[String]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  for i in 0..<items.length() {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(items[i])
  }
  out.write_string("]")
  out.to_string()
}

///|
/// Map[String, Json] 的键清单（nodeProgress 调试用）
fn i153_map_keys(np : Map[String, Json]) -> Array[String] {
  let out : Array[String] = []
  for k, _ in np {
    out.push(k)
  }
  out
}
