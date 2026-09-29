// issues/142 A 批 · spec/02 §6.1 表 ＋ §6.2 三条硬要求 —— **记录类（custom）执行腿**与
// **任务类零参与者建单**。本栈改前的四个病灶（逐条对着普查表 moon 行）：
//   1. `parser.mbt` 兜底臂 `_ => Custom` ⇒ 未知类型被当记录类（另档见 i142_node_type_test.mbt）；
//   2. `engine.mbt` 把 Custom 与 Task 合流建 **DOING 待办行**，而 `create_history_task`
//      （`aggregate.mbt`，issues/137 B 拍板"不删"的那支）**引擎零调用者** ⇒ 本单接线；
//   3. 任务类"actors 为空 ⇒ 一行不建、令牌放行"＝§6.1 点名的死锁黑洞；
//   4. `clazz` 全仓根本不执行（代码零命中）。
// 现成对照＝python 本轮那条腿 `jeeflow-python/jeeflow/engine.py::_exec_custom_node`。
// helper 复用同包 compliance_test.mbt（save_flow_define / new_args / start_and_apply /
// compliance_user_provider），与 events_leg_test.mbt 同一惯例。

///|
const CLAZZ : String = "com.mldong.jeeflow.test.TestCustomHandler"

///|
/// start → apply(applicant) → custom1(记录类) → end（形状照共享夹具 flows/08-custom-node.json）
const CUSTOM_FLOW : String =
  $|{"name": "i142-custom", "displayName": "i142 记录类", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "custom1", "type": "snaker:custom", "text": {"value": "通知外部系统"},
  $|   "properties": {"clazz": "com.mldong.jeeflow.test.TestCustomHandler", "val": "customResult"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "custom1"},
  $|  {"id": "e3", "sourceNodeId": "custom1", "targetNodeId": "end"}
  $|]}

///|
/// 记录类 → 决策 → 两支：决策边表达式读「clazz 返回值写进流程变量的那把键」，
/// 为真走 taskVip，否则走默认边 taskOther ⇒ 返回值到底落没落，看令牌走到哪一支就能验。
/// `var_key` 传 "" ＝定义里不配 `val`（该走缺省键 custom_return_val）。
fn custom_route_flow(var_key : String) -> String {
  let key = var_key.trim(chars=" \t\r\n").to_owned()
  let val_prop =
    if key.is_empty() {
      ""
    } else {
      ", \"val\": \"" + var_key + "\""
    }
  // 表达式要的是字面 `${键} == vip`（本栈 simple_eval 的变量引用是 `${var}` / `#var` 两形）
  let ref_key = if key.is_empty() { "custom_return_val" } else { key }
  let expr = "$" + "{" + ref_key + "}" + " == vip"
  $|{"name": "i142-custom-route", "displayName": "i142 返回值路由", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "custom1", "type": "snaker:custom", "text": {"value": "算一下"},
  $|   "properties": {"clazz": "com.mldong.jeeflow.test.TestCustomHandler"\{val_prop}}},
  $|  {"id": "d1", "type": "snaker:decision", "text": {"value": "分支"}},
  $|  {"id": "taskVip", "type": "snaker:task", "text": {"value": "VIP 审批"},
  $|   "properties": {"assignee": "vip-user", "taskType": 0, "performType": 0}},
  $|  {"id": "taskOther", "type": "snaker:task", "text": {"value": "普通审批"},
  $|   "properties": {"assignee": "normal-user", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "custom1"},
  $|  {"id": "e3", "sourceNodeId": "custom1", "targetNodeId": "d1"},
  $|  {"id": "e4", "sourceNodeId": "d1", "targetNodeId": "taskVip",
  $|   "properties": {"expr": "\{expr}"}},
  $|  {"id": "e5", "sourceNodeId": "d1", "targetNodeId": "taskOther"},
  $|  {"id": "e6", "sourceNodeId": "taskVip", "targetNodeId": "end"},
  $|  {"id": "e7", "sourceNodeId": "taskOther", "targetNodeId": "end"}
  $|]}
}

///|
/// 指定 clazz 值的记录类流程（"clazz 空串/纯空白"两档用）
fn custom_flow_with_clazz(clazz : String) -> String {
  CUSTOM_FLOW.replace(old=CLAZZ, new=clazz)
}

///|
/// 探针夹具：start → apply → custom1(记录类，返回值写 route 键) → probe2(记录类，把 route 读回来) → end
/// ⚠️ 为什么观测点不放在"决策路由"上：本栈决策边只认带 `expr` 的边（`engine.mbt`
/// `evaluate_decision` 恒返回 None ⇒ 无 expr 的默认边永远不命中），"没写键 ⇒ 走默认分支"
/// 这种判据会把**决策边的缺档**当成返回值的病灶。故改由第二个记录腿当场读 `exec.args`，
/// 键在不在、值是什么，一眼可辨（缺档本身另见报告"扫到没动的同类形状"）。
const PROBE_CLAZZ : String = "i142.probe.read-args"
const PROBE_FLOW : String =
  $|{"name": "i142-custom-probe", "displayName": "i142 返回值探针", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "custom1", "type": "snaker:custom", "text": {"value": "算一下"},
  $|   "properties": {"clazz": "com.mldong.jeeflow.test.TestCustomHandler", "val": "route"}},
  $|  {"id": "probe2", "type": "snaker:custom", "text": {"value": "读回来"},
  $|   "properties": {"clazz": "i142.probe.read-args"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "custom1"},
  $|  {"id": "e3", "sourceNodeId": "custom1", "targetNodeId": "probe2"},
  $|  {"id": "e4", "sourceNodeId": "probe2", "targetNodeId": "end"}
  $|]}

///|
/// 任务类节点：参与者解析为空（无 assignee／无 assignmentHandler／无 candidate*）
/// 任务类节点：参与者解析为空（无 assignee／无 assignmentHandler／无 candidate*）
const NO_ACTOR_FLOW : String =
  $|{"name": "i142-no-actor", "displayName": "i142 零参与者", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "nobody", "type": "snaker:task", "text": {"value": "没人可派"},
  $|   "properties": {"taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "nobody"},
  $|  {"id": "e3", "sourceNodeId": "nobody", "targetNodeId": "end"}
  $|]}

///|
fn i142_engine(
  repo : @mem.MemoryRepository,
  listeners : Array[((@event.ProcessEvent) -> Unit raise)],
  handlers : Array[(String, (@exec.Execution) -> Json raise @error.JeeflowError)]
) -> @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository] {
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 =
    ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider(compliance_user_provider)
  for l in listeners {
    ctx2.register_event_listener(l)
  }
  for h in handlers {
    let (name, f) = h
    ctx2.register_custom_handler(name, f)
  }
  @engine.Engine::make(ctx2)
}

///|
/// 从**仓储**取某节点的行（读不到即"没真落库"，判据在 §6.2 第 1 条）
fn find_row(rows : Array[@model.ProcessTask], name : String) -> @model.ProcessTask raise {
  for r in rows {
    if r.task_name == name {
      return r
    }
  }
  fail("仓储里查不到 task_name=\{name} 的行")
}

// ── 记录类：落 DONE 历史行 ＋ 真落库 ＋ 令牌继续 ＋ 不产生待办 ──

///|
async test "i142: custom 记录腿落 task_state=20 历史行，且**真落库**（内存仓通道）" {
  let repo = @mem.MemoryRepository::new()
  let engine = i142_engine(repo, [], [(CLAZZ, fn(_e) { @json.string_of("ok") })])
  let did = save_flow_define(repo, "i142-custom", CUSTOM_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let inst = repo.find_instance_by_id(iid).unwrap()
  // 令牌沿出边继续流转 ⇒ 实例走到终点（旧形状：custom 建 DOING 行卡在原地 state=10）
  assert_eq(inst.state, 20)
  // 读的是**仓储**，不是聚合数组（§6.2 第 1 条的判据）
  let rows = repo.find_history_tasks(iid)
  let hist = find_row(rows, "custom1")
  assert_eq(hist.task_state, @model.TaskState::Finished.code())
  assert_eq(hist.task_state, 20)
  assert_true(hist.task_id > 0L)
  // save_task 那条 INSERT 腿：按主键也查得到这一行
  assert_true(repo.find_task_by_id(hist.task_id) is Some(_))
  // 参与者＝当前操作人（留痕主体，非待办主体），并随任务一起落参与者表
  assert_true(hist.actor_ids == ["applicant"])
  assert_eq(hist.actor_id, Some("applicant"))
  assert_true(repo.find_task_actors(hist.task_id) == ["applicant"])
  // §6.2 第 **1bis** 条：这条 DONE 行还必须带**完成时间**（owner 09-30 拍，
  // 上一行原为 `assert_eq(hist.finish_time, None)` 的旧期望已在 i137b 用例侧改判）。
  // ⚠️ 内存仓整行存，这一句只能证明聚合赋了值；**真库那一路要另看** 
  // `save_task` 的 INSERT 语句带不带 finish_time 列（本轮补列，实测在 demo/cmd/t1_mysql F118）。
  match hist.finish_time {
    Some(t) => assert_true(!t.is_empty())
    None => fail("§6.2 1bis：留痕行必须写 finish_time，实得 None")
  }
  // 反过来两列不写：update_* 是办理审计，expire_time 记录类无表达式可算（"两列写、两列不写"）
  assert_eq(hist.update_time, None)
  assert_eq(hist.update_user, None)
  assert_eq(hist.expire_time, None)
  // 建单不变量（与 persist_tasks 同判据）：parent＝刚办结的 apply 行；行级 isFirstTaskNode
  let apply_row = find_row(rows, "apply")
  assert_eq(hist.parent_task_id, Some(apply_row.task_id))
  assert_eq(@json.as_bool(hist.variables.get("isFirstTaskNode").unwrap()), Some(false))
  // 记录类节点没有 DOING 行、不进 new_tasks 出口（"本步新产生的待办"清单）
  assert_eq(repo.find_doing_tasks(iid, ["custom1"]).length(), 0)
  assert_eq(repo.find_done_tasks(iid, ["custom1"]).length(), 1)
}

///|
async test "i142: custom 记录腿不 fire 码 3，可见序仍是 [1,3,5,2]（spec/11 §11.2 原则 1「码=事实」）" {
  let repo = @mem.MemoryRepository::new()
  let events : Array[@event.ProcessEvent] = []
  let engine = i142_engine(
    repo,
    [fn(ev) { events.push(ev) }],
    [(CLAZZ, fn(_e) { @json.string_of("ok") })],
  )
  let did = save_flow_define(repo, "i142-custom-events", CUSTOM_FLOW)
  let iid = start_and_apply(engine, repo, did)
  // 与 events_leg_test.mbt 那条正常链路逐字同序列 ⇒ custom 一行都没多塞（尤其没塞码 3）
  assert_eq(
    events.map(fn(e) { e.event_type().name() }),
    ["PROCESS_INSTANCE_START", "PROCESS_TASK_START", "TASK_COMPLETE", "PROCESS_INSTANCE_END"],
  )
  assert_eq(events.map(fn(e) { e.event_type().code() }), [1, 3, 5, 2])
  assert_eq(events.filter(fn(e) { e.event_type().code() == 3 }).length(), 1)
  // 那条码 3 钉的是 apply 行，不是 custom 行
  assert_eq(events[1].source_id(), find_row(repo.find_history_tasks(iid), "apply").task_id)
}

// ── clazz 两档：未注册 / 空串，都记日志＋照常落行＋续流，严禁打断建单 ──

///|
async test "i142: clazz 未注册处理器 ⇒ 记日志＋落历史行＋续流，不打断建单（§6.2 第 2 条）" {
  let repo = @mem.MemoryRepository::new()
  // 什么都不注册：夹具里的 clazz 是 JVM 类名，本栈无从反射 ⇒ 必须"记完日志继续"而不是炸
  let engine = i142_engine(repo, [], [])
  let did = save_flow_define(repo, "i142-custom-unreg", CUSTOM_FLOW)
  let iid = start_and_apply(engine, repo, did)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
  assert_eq(find_row(repo.find_history_tasks(iid), "custom1").task_state, 20)
}

///|
async test "i142: clazz 空串／纯空白 ⇒ 另一档日志，同样落行续流不炸（c# 合成一条的形状不许照抄）" {
  let cases : Array[(String, String)] = [("", "blank"), ("   ", "ws")]
  for c in cases {
    let (clazz, tag) = c
    let repo = @mem.MemoryRepository::new()
    let engine = i142_engine(repo, [], [(CLAZZ, fn(_e) { @json.string_of("ok") })])
    let did = save_flow_define(repo, "i142-custom-\{tag}", custom_flow_with_clazz(clazz))
    let iid = start_and_apply(engine, repo, did)
    if repo.find_instance_by_id(iid).unwrap().state != 20 {
      fail("clazz=「\{clazz}」档实例没走到终点，实得=\{repo.find_instance_by_id(iid).unwrap().state}")
    }
    assert_eq(find_row(repo.find_history_tasks(iid), "custom1").task_state, 20)
  }
}

///|
test "i142: 两档日志文案各自可诊断（未注册带 clazz 原样串；空串档说 clazz 缺失）" {
  let unreg = @engine.custom_handler_unregistered_warning("custom1", CLAZZ)
  let blank = @engine.custom_clazz_missing_warning("custom1")
  assert_true(unreg.contains(CLAZZ))
  assert_true(unreg.contains("custom1"))
  assert_true(unreg.contains("register_custom_handler"))
  assert_true(blank.contains("clazz"))
  assert_true(blank.contains("custom1"))
  // 两档必须分得开：空串档不许把"未注册"那句的判据混进来
  if unreg == blank {
    fail("两档日志塌成同一条")
  }
}

// ── 返回值：val 命中 / 缺省 custom_return_val ──

///|
async test "i142: clazz 返回值写进 val 指定的键，下游决策边读得到" {
  let repo = @mem.MemoryRepository::new()
  let engine = i142_engine(repo, [], [(CLAZZ, fn(_e) { @json.string_of("vip") })])
  let did = save_flow_define(repo, "i142-custom-val", custom_route_flow("route"))
  let iid = start_and_apply(engine, repo, did)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 1)
  assert_eq(doing[0].task_name, "taskVip")
  // 历史行照样落库（返回值那一支不影响建单）
  assert_eq(find_row(repo.find_history_tasks(iid), "custom1").task_state, 20)
}

///|
async test "i142: 没配 val ⇒ 返回值写进缺省键 custom_return_val（逐字对齐 java FlowConst）" {
  let repo = @mem.MemoryRepository::new()
  let engine = i142_engine(repo, [], [(CLAZZ, fn(_e) { @json.string_of("vip") })])
  let did = save_flow_define(repo, "i142-custom-default-key", custom_route_flow(""))
  let iid = start_and_apply(engine, repo, did)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 1)
  assert_eq(doing[0].task_name, "taskVip")
  assert_eq(@engine.custom_return_val_key, "custom_return_val")
}

///|
test "i142: custom_return_key 三档（val 命中 trim／val 空串／val 缺失）" {
  let model = @parser.parse_model(custom_route_flow("  customResult  "))
  let node = model.get_node("custom1").unwrap()
  assert_eq(@engine.custom_return_key(node), "customResult")
  let model2 = @parser.parse_model(custom_route_flow(""))
  let node2 = model2.get_node("custom1").unwrap()
  assert_eq(@engine.custom_return_key(node2), "custom_return_val")
}

///|
async test "i142: 处理器返回非 null ⇒ 写进 val 指定的键，下游记录腿当场读得到（正向对照）" {
  let repo = @mem.MemoryRepository::new()
  let seen : Array[String] = []
  // 探针＝第二个记录腿（probe2）：把上游 custom1 该写进 route 键的值读回来
  let engine = i142_engine(
    repo,
    [],
    [
      (CLAZZ, fn(_e) { @json.string_of("ok") }),
      (
        PROBE_CLAZZ,
        fn(e) {
          seen.push(e.args.get_str("route").unwrap_or("<无此键>"))
          @json.null_json()
        },
      ),
    ],
  )
  let did = save_flow_define(repo, "i142-custom-probe-ok", PROBE_FLOW)
  let iid = start_and_apply(engine, repo, did)
  assert_true(seen == ["ok"])
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
  assert_eq(find_row(repo.find_history_tasks(iid), "custom1").task_state, 20)
  assert_eq(find_row(repo.find_history_tasks(iid), "probe2").task_state, 20)
}

///|
async test "i142: 处理器返回 Json::Null ⇒ 不写键（对齐 python「ret is not None 才写」）" {
  let repo = @mem.MemoryRepository::new()
  let seen : Array[String] = []
  let engine = i142_engine(
    repo,
    [],
    [
      (CLAZZ, fn(_e) { @json.null_json() }),
      (
        PROBE_CLAZZ,
        fn(e) {
          seen.push(e.args.get_str("route").unwrap_or("<无此键>"))
          @json.null_json()
        },
      ),
    ],
  )
  let did = save_flow_define(repo, "i142-custom-probe-null", PROBE_FLOW)
  let iid = start_and_apply(engine, repo, did)
  // 返回 null ⇒ 一个键都不写（写进去一个 null 也算病灶，与 python「ret is not None 才写」同判据）
  assert_true(seen == ["<无此键>"])
  // 但历史行照落、令牌照走 —— 返回值那一支不影响建单
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
  assert_eq(find_row(repo.find_history_tasks(iid), "custom1").task_state, 20)
}

// ── 处理器自身失败：不在豁免内，照旧外抛（负向对照）──

///|
async test "i142: 处理器自身执行失败 ⇒ 外抛原错，不被记日志那一支吞掉（负向）" {
  let repo = @mem.MemoryRepository::new()
  let engine = i142_engine(
    repo,
    [],
    [
      (
        CLAZZ,
        fn(_e) {
          raise @error.Business("外部系统调用失败")
        },
      ),
    ],
  )
  let did = save_flow_define(repo, "i142-custom-handler-fail", CUSTOM_FLOW)
  let inst = engine.start_async(did, "applicant", new_args())
  let apply_row = find_row(repo.find_doing_tasks(inst.instance_id, []), "apply")
  let raised = try {
    let _ = engine.execute_task_async(apply_row.task_id, "applicant", new_args())
    None
  } catch {
    e => Some(e)
  }
  match raised {
    None => fail("处理器自身失败必须外抛原错，不得被记日志那一支吞掉")
    Some(e) => assert_true(e.message().contains("外部系统调用失败"))
  }
  // 业务错误打断这一步 ⇒ 实例没被推到终点（与 java CustomModel 方法调用失败同形）
  assert_eq(repo.find_instance_by_id(inst.instance_id).unwrap().state, 10)
}

// ── 任务类零参与者：必须建一行 DOING（§6.1 表第一行 ＋ §6.2 第 3 条）──

///|
async test "i142: 任务类零参与者照样建一行 DOING（state=10／参与者空／发起人不在参与者里）" {
  let repo = @mem.MemoryRepository::new()
  let engine = i142_engine(repo, [], [])
  let did = save_flow_define(repo, "i142-no-actor", NO_ACTOR_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let doing = repo.find_doing_tasks(iid, [])
  // 旧形状：actors 解析为空 ⇒ 一行不建、令牌直接放行到 end ⇒ 实例 state=20 而库里零可办行
  assert_eq(doing.length(), 1)
  let row = doing[0]
  assert_eq(row.task_name, "nobody")
  assert_eq(row.task_state, @model.TaskState::Doing.code())
  assert_eq(row.task_state, 10)
  // 参与者为空数组，**不兜底挂当前操作人**（§6.1 硬结论 1）
  assert_true(row.actor_ids.is_empty())
  assert_true(!row.actor_ids.contains("applicant"))
  assert_eq(row.actor_id, None)
  assert_true(repo.find_task_actors(row.task_id).is_empty())
  // 令牌停在这一行（实例仍进行中）——这正是"该行存在"的可诊断后果，而不是黑洞里的空转
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  // 负向对照：发起人办不动它（他确实不是参与者）；flow.auto 能办 ⇒ 黑洞不封死收尾通道
  let denied = try {
    let _ = engine.execute_task_async(row.task_id, "applicant", new_args())
    false
  } catch {
    _ => true
  }
  assert_true(denied)
  let ok = try {
    let _ = engine.execute_task_async(row.task_id, "flow.auto", new_args())
    true
  } catch {
    _ => false
  }
  assert_true(ok)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20)
}

///|
async test "i142: 零参与者那一行也 fire 码 3（真待办行，与记录类的 20 行判据相反）" {
  let repo = @mem.MemoryRepository::new()
  let events : Array[@event.ProcessEvent] = []
  let engine = i142_engine(repo, [fn(ev) { events.push(ev) }], [])
  let did = save_flow_define(repo, "i142-no-actor-events", NO_ACTOR_FLOW)
  let iid = start_and_apply(engine, repo, did)
  let starts = events.filter(fn(e) { e.event_type().code() == 3 })
  assert_eq(starts.length(), 2)
  let row = repo.find_doing_tasks(iid, [])[0]
  assert_eq(starts[1].source_id(), row.task_id)
  // 载荷 actors 为空数组（键在、值为空）：码 3 表达"新待办产生"，行是真的，参与者才是空的
  assert_eq(starts[1].data.get_string_array("actors"), [])
}
