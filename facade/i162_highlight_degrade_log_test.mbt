// issues/162（队列 R7 · 搭 issues/176 发版轮）· 判据形状照 §6.1 go 两枚：
// 本栈修点＝actions_ext.mbt `high_light` 内 `try { parse_model + build_node_progress + collect_path }
// catch { _ => () }`——旧形状三腿一锅端静默（162 §3 普查点名；go 上同族只有解码一腿）。
// 判据：
//   ① 坏定义 ⇒ code=0＋边集/进度留空＋任务行不受影响（只影响模型补全腿）；
//   ② 好定义 ⇒ 正常填充（失败支不误伤）。
// 「日志真拿到」：本栈日志口＝`println`（无注入 sink）⇒ 证据＝测试进程 stdout 里 grep
// `[jeeflow] WARN highLight` 三件齐（instanceId=/defineId=/err=）；全量跑应**恰 1 行**（坏定义枚），
// 好定义对照枚不得多出；变异（失败支回旧形）=该行 0 行 ⇒ 日志腿由读数判别（见 162 §6.5 记账）。
// 复用同包 helper：targs / code_of / msg_of / data_of / parse_iid / doing_task_for / i153_str_list。

///|
fn i162_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i162-highLight] 红样：" + "\{label}")
    abort("[i162-highLight] 红样：" + "\{label}")
  }
}

///|
fn i162_good_flow() -> String {
  let s = $|{"name": "i162-hl", "displayName": "162 降级日志夹具", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply", "properties": {}},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "task1", "properties": {}},
  $|   {"id": "e2", "sourceNodeId": "task1", "targetNodeId": "end", "properties": {}}
  $| ]}
$|
  s
}

///|
/// 夹具：好定义发起（startAndExecute 自动办结 apply）⇒ bad=true 时把 define 内容原地换成坏串
/// （save_define 按 id 覆盖，core/memory/memory.mbt:129-134）⇒ highLight 的模型补全腿必踩 catch。
async fn i162_setup(
  bad : Bool
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i162-hl",
    display_name: "162 降级日志夹具",
    define_type: "approval",
    state: 1,
    content: i162_good_flow(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  i162_check(code_of(env) == 0L, "发起 code=0（msg=\{msg_of(env)}）")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  if bad {
    let bad_def : @model.ProcessDefine = {
      id: define_info.id,
      name: "i162-hl",
      display_name: "162 降级日志夹具",
      define_type: "approval",
      state: 1,
      content: "%%% not a json model %%%",
      version: 1,
      create_time: None,
      create_user: None,
      update_time: None,
      update_user: None,
    }
    repo.save_define(bad_def)
  }
  (facade, repo, iid)
}

///|
/// ① 坏定义 ⇒ 降级面：code=0、边集空、进度空对象、任务行不受影响（活跃仍是 task1、历史仍含 apply）。
async test "i162-highLight 坏定义降级面（162 ①）" {
  let (facade, repo, iid) = i162_setup(true)
  let env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i162_check(code_of(env) == 0L, "坏定义 highLight code=0（msg=\{msg_of(env)}）")
  let data = data_of(env)
  let edges = i153_str_list(data, "historyEdgeNames")
  i162_check(edges.length() == 0, "边集留空（实际 \{edges.length()} 条）")
  let np_str = @json.stringify(@json.get(data, "nodeProgress").unwrap_or(@json.null_json()))
  i162_check(np_str == "{}", "进度留空对象（实际 " + np_str + "）")
  i162_check(
    i153_str_list(data, "activeNodeNames").contains("task1"),
    "活跃任务行仍是 task1（只影响模型补全腿）",
  )
  i162_check(
    i153_str_list(data, "historyNodeNames").contains("apply"),
    "历史任务行仍含 apply（任务行不受影响）",
  )
  let t1 = doing_task_for(repo, iid, "leader")
  i162_check(t1.task_id > 0L, "task1 仍进行中（任务行不受影响）")
}

///|
/// ② 好定义对照：失败支不误伤（边集正常填充）。
async test "i162-highLight 好定义对照（162 ②）" {
  let (facade, _repo, iid) = i162_setup(false)
  let env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i162_check(code_of(env) == 0L, "好定义 highLight code=0（msg=\{msg_of(env)}）")
  let data = data_of(env)
  let edges = i153_str_list(data, "historyEdgeNames")
  i162_check(edges.contains("e1"), "好定义边集正常填充（含 e1，实际 " + edges.length().to_string() + " 条）")
}
