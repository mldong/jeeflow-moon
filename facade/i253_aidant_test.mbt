// issues/253 动态协办（aidant）—— **门面端到端腿**（内存仓）。
//
// 判据与落库都在引擎（`core/engine/aidant.mbt`，逐格语义对齐 java `AidantTest`）；本文件钉门面这一侧：
//   ① dispatch 真在表上（`processTask/aidant`）；② 派生形状（task_type=1／parent／同节点同名／
//   performType=NORMAL／主办保留 DOING／账本六键／码 3 既有腿）；③ 推进闸四入口（协办办结不驱动）；
//   ④ 等待闸两档（true 逐字文案＋零写入／缺省 false 随时推进＋离开节点清场记账）；⑤ 两跳账本存活；
//   ⑥ detail 投影 ext.aidant；⑦ 负向六文案＋越权＋非 DOING；⑧ 回归（会签票齐即推进／与征询并存
//   两闸各数／撤回清场／transfer·surrogate·addCandidate 不变）。
//
// 夹具内联 JSON（不碰共享 flows 目录，照 i246_247 纪律）；复用同包 helper：
// targs / i159_args / code_of / msg_of / data_of / parse_iid / doing_task_for / i247_flow / i247_task_node /
// i247_plain_node / i247_edge。读数全部来自内存仓（@mem.MemoryRepository），无真桶／无真库成分。
//
// ⚠️ 出口层 C1（transform_output 递归把 *Id 键字符串化）对全部响应生效：投影 actors[].taskId 出串
// （java 出 Long）——本栈既有出口形状，不是本轮引入。

///|
/// 装配（带事件捕获）：存定义 → startAndExecute（自动办结申请节点）⇒ 令牌停在 review。
/// events 收事件码（码 3/5 既有腿取证；不新增事件码）。
async fn i253_setup(
  name : String, review_extra : Array[(String, Json)]
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64, Array[Int]) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[Int] = []
  ctx2.register_event_listener_sync(fn(e) { events.push(e.event_type().code()) })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name,
    display_name: name,
    define_type: "approval",
    state: 1,
    content: i247_flow(name, review_extra),
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
  assert_eq(code_of(env), 0L, msg="发起 code=0（实得 msg=\{msg_of(env)}）")
  (facade, repo, parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0")), events)
}

///|
/// 并行会签链 start→apply→cs(userA,userB)→end（＝java countersignChain）
fn i253_cs_flow(name : String) -> String {
  let cs_node = @json.object_of([
    ("id", @json.string_of("cs")),
    ("type", @json.string_of("snaker:task")),
    (
      "properties",
      @json.object_of([
        ("form", @json.string_of("form-c")),
        ("assignee", @json.string_of("userA,userB")),
        ("taskType", @json.number_of(0L)),
        ("performType", @json.number_of(1L)),
        ("countersignType", @json.string_of("PARALLEL")),
      ]),
    ),
    ("text", @json.object_of([("value", @json.string_of("会签审批"))])),
  ])
  @json.object_of([
    ("name", @json.string_of(name)),
    ("displayName", @json.string_of("协办×会签夹具")),
    ("type", @json.string_of("approval")),
    (
      "nodes",
      @json.array_of([
        i247_plain_node("start", "snaker:start", "开始"),
        i247_task_node("apply", "applicant", [], "发起申请"),
        cs_node,
        i247_plain_node("end", "snaker:end", "结束"),
      ]),
    ),
    (
      "edges",
      @json.array_of([
        i247_edge("e1", "start", "apply"),
        i247_edge("e2", "apply", "cs"),
        i247_edge("e3", "cs", "end"),
      ]),
    ),
  ]).stringify()
}

///|
/// 会签链装配（带事件捕获）
async fn i253_cs_setup(
  name : String
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64, Array[Int]) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[Int] = []
  ctx2.register_event_listener_sync(fn(e) { events.push(e.event_type().code()) })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name,
    display_name: name,
    define_type: "approval",
    state: 1,
    content: i253_cs_flow(name),
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
  assert_eq(code_of(env), 0L, msg="发起 code=0（实得 msg=\{msg_of(env)}）")
  (facade, repo, parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0")), events)
}

///|
/// 派生协办（actorIds/wait 收 Json 形态：数组/逗号串/null；operator/reason 收 String?）
async fn i253_aidant(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  host_id : Int64, operator : String?, actor_ids : Json?, reason : String?, wait : Json?
) -> Json raise {
  let entries : Array[(String, Json)] = [("processTaskId", @json.string_of(host_id.to_string()))]
  match operator {
    Some(o) => entries.push(("operator", @json.string_of(o)))
    None => ()
  }
  match actor_ids {
    Some(a) => entries.push(("actorIds", a))
    None => ()
  }
  match reason {
    Some(r) => entries.push(("reason", @json.string_of(r)))
    None => ()
  }
  match wait {
    Some(w) => entries.push(("waitCompletion", w))
    None => ()
  }
  facade.flow("processTask/aidant", i159_args(entries))
}

///|
/// 办理腿（submitType 串档，extra 是 tf_ 协议键）
async fn i253_exec(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64, operator : String, submit_type : String, extra : Array[(String, Json)]
) -> Json raise {
  let all : Array[(String, Json)] = [
    ("processTaskId", @json.string_of(task_id.to_string())),
    ("operator", @json.string_of(operator)),
    ("submitType", @json.string_of(submit_type)),
  ]
  for p in extra {
    all.push(p)
  }
  facade.flow("processTask/execute", i159_args(all))
}

///|
/// 现读协办行（仓储真相）
async fn i253_rows(
  repo : @mem.MemoryRepository, iid : Int64, host_id : Int64
) -> Array[@model.ProcessTask] raise {
  let host = repo.find_task_by_id(host_id).unwrap()
  @engine.aidant_rows(repo.find_instance_by_id(iid).unwrap().tasks, host)
}

///|
/// 主办行账本
async fn i253_ledger(repo : @mem.MemoryRepository, host_id : Int64) -> Array[Json] raise {
  @engine.aidant_history_of(repo.find_task_by_id(host_id).unwrap())
}

///|
/// 该节点名的 DOING 行（无则 None）
async fn i253_doing(
  repo : @mem.MemoryRepository, iid : Int64, name : String
) -> @model.ProcessTask? raise {
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      return Some(t)
    }
  }
  None
}

///|
/// 该节点名 DOING 行数
async fn i253_doing_count(repo : @mem.MemoryRepository, iid : Int64, name : String) -> Int raise {
  let mut n = 0
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == name {
      n = n + 1
    }
  }
  n
}

///|
/// 逐字文案断言（code=99999999 ＋ msg）
fn i253_assert_msg(env : Json, msg : String) -> Unit raise {
  assert_eq(code_of(env), 99999999L, msg="期望失败码（实得 msg=\{msg_of(env)}）")
  assert_eq(msg_of(env), msg)
}

///|
/// detail 的 ext（code=0 前置）
async fn i253_ext(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], task_id : Int64
) -> Json raise {
  let det = facade.flow(
    "processTask/detail", targs([("processTaskId", task_id.to_string()), ("operator", "userA")]),
  )
  assert_eq(code_of(det), 0L, msg="detail code=0（实得 msg=\{msg_of(det)}）")
  @json.get(data_of(det), "ext").unwrap()
}

// ══════════════════ 正向：派生形状 ══════════════════

///|
async test "i253 派生：每人一行 task_type=1／parent／同名／NORMAL／主办保留 DOING／账本六键／码 3" {
  let (facade, repo, iid, events) = i253_setup("i253-derive", [])
  let host = doing_task_for(repo, iid, "userA")
  events.clear()
  let env = i253_aidant(
    facade, host.task_id, Some("userA"),
    Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])),
    Some("需两部门协办"), None,
  )
  assert_eq(code_of(env), 0L, msg="派生 code=0（实得 msg=\{msg_of(env)}）")
  assert_true(data_of(env) is Json::Null, msg="成功 data → null")
  // 主办行原样保留 DOING，名册不动，actor_id 列恒无值
  let host_row = repo.find_task_by_id(host.task_id).unwrap()
  assert_true(host_row.is_doing(), msg="主办行保留 DOING")
  assert_eq(host_row.actor_ids, ["userA"])
  assert_true(host_row.actor_id is None, msg="严禁覆写任务 actor_id 列")
  let rows = i253_rows(repo, iid, host.task_id)
  assert_eq(rows.length(), 2, msg="多人每人一行")
  let actors : Array[String] = []
  for r in rows {
    assert_true(r.is_doing())
    assert_eq(r.task_type, 1, msg="task_type=1")
    assert_eq(r.parent_task_id, Some(host.task_id))
    assert_eq(r.task_name, host.task_name, msg="同节点")
    assert_eq(r.display_name, host.display_name, msg="同名")
    assert_eq(r.perform_type, 0, msg="performType=NORMAL")
    assert_eq(r.variables.get_str("tf_aidantReason"), Some("需两部门协办"))
    assert_true(r.variables.get("tf_approvalComment") is None, msg="协办行不占 tf_approvalComment")
    assert_true(r.actor_id is None, msg="进行中任务 actor_id 列恒无值")
    actors.push(r.actor_ids[0])
    assert_eq(repo.find_task_actors(r.task_id).length(), 1, msg="参与者表真落库")
  }
  assert_eq(actors, ["userX", "userY"])
  // 账本：一条、六键锁定键序、time 为 §2.4 字符串
  let lg = i253_ledger(repo, host.task_id)
  assert_eq(lg.length(), 1)
  let e0 = lg[0]
  assert_eq(@json.get_i64(e0, "round"), Some(1L))
  assert_eq(@json.get_str(e0, "fromActor"), Some("userA"))
  assert_eq(@json.get_str(e0, "reason"), Some("需两部门协办"))
  assert_eq(@json.get_str(e0, "operator"), Some("userA"))
  let to_actors = @json.as_array(@json.get(e0, "toActors").unwrap()).unwrap()
  assert_eq(to_actors.length(), 2)
  assert_eq(@json.as_str(to_actors[0]), Some("userX"))
  let time = @json.get_str(e0, "time").unwrap_or("")
  assert_eq(time.length(), 19, msg="time 一律 yyyy-MM-dd HH:mm:ss（19 字符）")
  // 事件：只走既有码 3（逐协办行一次），不新增事件码
  assert_eq(events, [3, 3])
}

///|
async test "i253 reason 选填：空串兜底进账本，协办行不盖空戳" {
  let (facade, repo, iid, _ev) = i253_setup("i253-reason", [])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None)), 0L)
  assert_eq(@json.get_str(i253_ledger(repo, host.task_id)[0], "reason"), Some(""))
  let rows = i253_rows(repo, iid, host.task_id)
  assert_true(rows[0].variables.get("tf_aidantReason") is None)
  assert_true(repo.find_task_by_id(host.task_id).unwrap().variables.get("tf_approvalComment") is None)
}

///|
async test "i253 actorIds 逗号串与数组两形同归一，空白元素丢弃" {
  let (facade, repo, iid, _ev) = i253_setup("i253-actorforms", [])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of(" userX , userY ,")), None, None)), 0L)
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 2)
}

///|
async test "i253 expire_time 同尺重算＋委托照既有腿并入协办行名册" {
  @model.set_clock(Some(fn() { "2026-11-13 10:00:00" }))
  defer { @model.set_clock(None) }
  let (facade, repo, iid, _ev) = i253_setup("i253-expire", [("expireTime", @json.string_of("2d"))])
  let host = doing_task_for(repo, iid, "userA")
  // 生效委托：userX → userS（全流程兜底，窗口覆盖固定钟）
  let s : @model.ProcessSurrogate = {
    id: 1L,
    process_name: "",
    operator: "userX",
    surrogate: "userS",
    start_time: Some("2020-01-01 00:00:00"),
    end_time: Some("2099-12-31 23:59:59"),
    enabled: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_surrogate(s)
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None)), 0L)
  let child = i253_rows(repo, iid, host.task_id)[0]
  assert_eq(child.expire_time, Some("2026-11-15 10:00:00"), msg="expire_time 按节点表达式同尺重算")
  assert_true(child.actor_ids.contains("userX"), msg="委托并入不摘原人")
  assert_true(child.actor_ids.contains("userS"), msg="委托照既有腿并入")
  assert_eq(repo.find_task_actors(child.task_id).length(), 2, msg="落库参与者表也真带上")
}

// ══════════════════ 正向：推进闸 ══════════════════

///|
async test "i253 协办办结不驱动：无新任务／主办仍 DOING／下游无待办／只走码 5" {
  let (facade, repo, iid, events) = i253_setup("i253-nodrive", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, host.task_id)[0]
  events.clear()
  let created = (facade.engine()).execute_task_async(child.task_id, "userX", @json.FlowData::new())
  assert_true(created.is_empty(), msg="协办办结不产生执行对象（无新任务）")
  assert_true(repo.find_task_by_id(child.task_id).unwrap().is_finished())
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing(), msg="主办行保留 DOING")
  assert_true(i253_doing(repo, iid, "final") is None, msg="不跑输出变迁：下游节点无待办")
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  assert_eq(events, [5], msg="只走既有码 5，不新增事件码")
}

///|
async test "i253 两路同闸：跳转(4)与血缘退回(3)对协办行同样不驱动" {
  let (facade, repo, iid, _ev) = i253_setup("i253-jumpgate", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])), None, None) |> ignore
  let rows = i253_rows(repo, iid, host.task_id)
  // JUMP 路（门面 submitType=4）
  let env = i253_exec(facade, rows[0].task_id, "userX", "4", [("taskName", @json.string_of("final"))])
  assert_eq(code_of(env), 0L, msg="跳转路 code=0（实得 msg=\{msg_of(env)}）")
  assert_true(repo.find_task_by_id(rows[0].task_id).unwrap().is_finished())
  assert_true(i253_doing(repo, iid, "final") is None, msg="跳转路同闸：不得凭空建出 final 待办")
  // ROLLBACK 路（submitType=3，引擎直调 nodeName=None）
  let created = (facade.engine()).execute_and_jump_async(rows[1].task_id, "userY", @json.FlowData::new(), None)
  assert_true(created.is_empty())
  assert_true(repo.find_task_by_id(rows[1].task_id).unwrap().is_finished())
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing(), msg="主办行仍在")
  assert_eq(i253_doing_count(repo, iid, "review"), 1)
}

///|
async test "i253 协办行拒绝(2)／退回发起人(6)同样不驱动" {
  let (facade, repo, iid, _ev) = i253_setup("i253-rejectgate", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])), None, None) |> ignore
  let rows = i253_rows(repo, iid, host.task_id)
  assert_eq(code_of(i253_exec(facade, rows[0].task_id, "userX", "2", [])), 0L)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="拒绝不得结束整单")
  assert_eq(code_of(i253_exec(facade, rows[1].task_id, "userY", "6", [])), 0L)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing())
  assert_true(i253_doing(repo, iid, "apply") is None)
}

///|
async test "i253 主办再办结照常驱动（协办已办结）" {
  let (facade, repo, iid, _ev) = i253_setup("i253-hostdrive", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, host.task_id)[0]
  i253_exec(facade, child.task_id, "userX", "1", []) |> ignore
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L)
  assert_true(i253_doing(repo, iid, "final") is Some(_), msg="主办办结才推进")
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_finished())
}

// ══════════════════ 正向／负向：等待闸两档 ══════════════════

///|
async test "i253 waitCompletion=true：未齐逐字文案＋零写入；齐了放行推进" {
  let (facade, repo, iid, _ev) = i253_setup("i253-wait", [])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])), None, Some(@json.bool_of(true)))), 0L)
  let rows = i253_rows(repo, iid, host.task_id)
  let ledger_before = i253_ledger(repo, host.task_id).length()
  i253_assert_msg(i253_exec(facade, host.task_id, "userA", "1", []), "节点[review]协办未办结（已办结 0/2），不能办理")
  // 零写入：主办仍 DOING、无下游待办、账本不增、协办行不动
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing())
  assert_true(i253_doing(repo, iid, "final") is None)
  assert_eq(i253_ledger(repo, host.task_id).length(), ledger_before)
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 2)
  for r in i253_rows(repo, iid, host.task_id) {
    assert_true(r.is_doing())
  }
  // 办结一条 ⇒ 计数 1/2，仍拦
  i253_exec(facade, rows[0].task_id, "userX", "1", []) |> ignore
  i253_assert_msg(i253_exec(facade, host.task_id, "userA", "1", []), "节点[review]协办未办结（已办结 1/2），不能办理")
  // 全办结 ⇒ 放行
  i253_exec(facade, rows[1].task_id, "userY", "1", []) |> ignore
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L)
  assert_true(i253_doing(repo, iid, "final") is Some(_))
}

///|
async test "i253 等待闸挡全部 submitType（含拒绝／退回），不只挡同意" {
  let (facade, repo, iid, _ev) = i253_setup("i253-waitall", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, Some(@json.bool_of(true))) |> ignore
  for st in ["1", "2", "6"] {
    i253_assert_msg(i253_exec(facade, host.task_id, "userA", st, []), "节点[review]协办未办结（已办结 0/1），不能办理")
    assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing())
  }
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10)
}

///|
async test "i253 waitCompletion 缺省 false：主办可随时推进，未办结协办行清场＋账本记废弃" {
  let (facade, repo, iid, _ev) = i253_setup("i253-waitfalse", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])), None, None) |> ignore
  let rows = i253_rows(repo, iid, host.task_id)
  i253_exec(facade, rows[0].task_id, "userX", "1", []) |> ignore
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L, msg="缺省 false 主办可随时推进")
  assert_true(i253_doing(repo, iid, "final") is Some(_))
  assert_eq(repo.find_task_by_id(rows[1].task_id).unwrap().task_state, 99, msg="未办结协办行清场为废弃(99)")
  assert_eq(repo.find_task_by_id(rows[0].task_id).unwrap().task_state, 20, msg="已办结那条不改写")
  let lg = i253_ledger(repo, host.task_id)
  assert_eq(lg.length(), 2)
  let last = lg[1]
  assert_eq(@json.as_bool(@json.get(last, "abandoned").unwrap()), Some(true))
  let to_actors = @json.as_array(@json.get(last, "toActors").unwrap()).unwrap()
  assert_eq(to_actors.length(), 1)
  assert_eq(@json.as_str(to_actors[0]), Some("userY"))
  assert_eq(@json.get_i64(last, "round"), Some(1L), msg="清场不消耗轮次")
  assert_eq(i253_doing_count(repo, iid, "review"), 0, msg="不留孤儿待办")
}

///|
async test "i253 waitCompletion 字符串 true 两形也认" {
  let (facade, repo, iid, _ev) = i253_setup("i253-waitstr", [])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, Some(@json.string_of("true")))), 0L)
  i253_assert_msg(i253_exec(facade, host.task_id, "userA", "1", []), "节点[review]协办未办结（已办结 0/1），不能办理")
}

///|
async test "i253 拒绝／退回发起人离开节点：协办行同样清场" {
  let (facade, repo, iid, _ev) = i253_setup("i253-rejectclean", [])
  let h1 = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, h1.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let c1 = i253_rows(repo, iid, h1.task_id)[0]
  assert_eq(code_of(i253_exec(facade, h1.task_id, "userA", "2", [])), 0L)
  assert_eq(repo.find_task_by_id(c1.task_id).unwrap().task_state, 99)
  assert_eq(@json.as_bool(@json.get(i253_ledger(repo, h1.task_id)[1], "abandoned").unwrap()), Some(true))

  let (facade2, repo2, iid2, _ev2) = i253_setup("i253-returnclean", [])
  let h2 = doing_task_for(repo2, iid2, "userA")
  i253_aidant(facade2, h2.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let c2 = i253_rows(repo2, iid2, h2.task_id)[0]
  assert_eq(code_of(i253_exec(facade2, h2.task_id, "userA", "6", [])), 0L)
  assert_eq(repo2.find_task_by_id(c2.task_id).unwrap().task_state, 99)
  assert_true(i253_doing(repo2, iid2, "apply") is Some(_), msg="退回发起人后申请节点复活")
}

// ══════════════════ 正向：账本与投影 ══════════════════

///|
async test "i253 两跳账本＝2，且主办办结后仍在" {
  let (facade, repo, iid, _ev) = i253_setup("i253-tworounds", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), Some("第一轮"), Some(@json.bool_of(false))) |> ignore
  let first = i253_rows(repo, iid, host.task_id)[0]
  i253_exec(facade, first.task_id, "userX", "1", []) |> ignore
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userY")), Some("第二轮"), Some(@json.bool_of(false))) |> ignore
  let lg = i253_ledger(repo, host.task_id)
  assert_eq(lg.length(), 2, msg="两跳账本＝2")
  assert_eq(@json.get_i64(lg[0], "round"), Some(1L))
  assert_eq(@json.get_i64(lg[1], "round"), Some(2L))
  assert_eq(@json.get_str(lg[0], "reason"), Some("第一轮"))
  assert_eq(@json.get_str(lg[1], "reason"), Some("第二轮"))
  let second = i253_rows(repo, iid, host.task_id)[1]
  i253_exec(facade, second.task_id, "userY", "1", []) |> ignore
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L)
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_finished())
  assert_eq(i253_ledger(repo, host.task_id).length(), 2, msg="办结后账本仍在")
}

///|
async test "i253 投影 ext.aidant＝{active,round,total,submitted,actors,wait}，现算" {
  let (facade, repo, iid, _ev) = i253_setup("i253-proj", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([@json.string_of("userX"), @json.string_of("userY")])), Some("协办原因"), Some(@json.bool_of(true))) |> ignore
  let rows = i253_rows(repo, iid, host.task_id)
  let ext = i253_ext(facade, host.task_id)
  let p = @json.get(ext, "aidant").unwrap()
  assert_eq(@json.as_bool(@json.get(p, "active").unwrap()), Some(true))
  assert_eq(@json.get_i64(p, "round"), Some(1L))
  assert_eq(@json.get_i64(p, "total"), Some(2L))
  assert_eq(@json.get_i64(p, "submitted"), Some(0L))
  assert_eq(@json.as_bool(@json.get(p, "wait").unwrap()), Some(true))
  let actors = @json.as_array(@json.get(p, "actors").unwrap()).unwrap()
  assert_eq(actors.length(), 2)
  assert_eq(@json.get_str(actors[0], "actor"), Some("userX"))
  assert_eq(@json.get_i64(actors[0], "state"), Some(10L))
  // 办结一条 ⇒ submitted 现算推进
  i253_exec(facade, rows[0].task_id, "userX", "1", []) |> ignore
  let p2 = @json.get(i253_ext(facade, host.task_id), "aidant").unwrap()
  assert_eq(@json.get_i64(p2, "submitted"), Some(1L))
  assert_eq(@json.as_bool(@json.get(p2, "active").unwrap()), Some(true))
  // 无协办行的普通任务不输出该投影
  let (facade3, repo3, iid3, _ev3) = i253_setup("i253-projplain", [])
  let plain = doing_task_for(repo3, iid3, "userA")
  assert_true(@json.get(i253_ext(facade3, plain.task_id), "aidant") is None)
}

// ══════════════════ 负向：六文案＋越权＋非 DOING ══════════════════

///|
async test "i253 负向：actorIds 必填（缺失／空数组／全空白）＋零写入" {
  let (facade, repo, iid, _ev) = i253_setup("i253-noactors", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userA"), None, None, None), "actorIds 必填")
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.array_of([])), None, None), "actorIds 必填")
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("  ,  ")), None, None), "actorIds 必填")
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 0, msg="零写入")
}

///|
async test "i253 负向：operator 必填（缺失／纯空白）" {
  let (facade, repo, iid, _ev) = i253_setup("i253-noop", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_assert_msg(i253_aidant(facade, host.task_id, None, Some(@json.string_of("userX")), None, None), "operator 必填")
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("   "), Some(@json.string_of("userX")), None, None), "operator 必填")
}

///|
async test "i253 负向：任务不存在" {
  let (facade, _repo, _iid, _ev) = i253_setup("i253-notfound", [])
  i253_assert_msg(i253_aidant(facade, 999999L, Some("userA"), Some(@json.string_of("userX")), None, None), "任务不存在")
}

///|
async test "i253 负向：越权（非名册且非 auto/admin）＋零写入" {
  let (facade, repo, iid, _ev) = i253_setup("i253-unauth", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userZ"), Some(@json.string_of("userX")), None, None), "无权限派生协办任务")
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 0, msg="零写入")
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing())
}

///|
async test "i253 名册内参与人（含加签进来的）可派生；flow.auto／flow.admin 例外放行" {
  let (facade, repo, iid, _ev) = i253_setup("i253-roster", [])
  let host = doing_task_for(repo, iid, "userA")
  facade.flow(
    "processTask/addCandidate",
    i159_args([
      ("processTaskId", @json.string_of(host.task_id.to_string())),
      ("actorIds", @json.array_of([@json.string_of("userB")])),
    ]),
  ) |> ignore
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userB"), Some(@json.string_of("userX")), None, None)), 0L)
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("flow.auto"), Some(@json.string_of("userY")), None, None)), 0L)
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("flow.admin"), Some(@json.string_of("userZ")), None, None)), 0L)
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 3)
}

///|
async test "i253 负向：主办行非进行中" {
  let (facade, repo, iid, _ev) = i253_setup("i253-notdoing", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_exec(facade, host.task_id, "userA", "1", []) |> ignore
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_finished())
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None), "任务非进行中，不可派生协办")
}

///|
async test "i253 负向：该人已有未办结协办行（去重只认未办结）" {
  let (facade, repo, iid, _ev) = i253_setup("i253-dup", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  i253_assert_msg(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None), "该人已有未办结的协办任务")
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 1, msg="零写入：不重复建行")
  assert_eq(i253_ledger(repo, host.task_id).length(), 1)
  // 已办结的那位可以再派生
  let child = i253_rows(repo, iid, host.task_id)[0]
  i253_exec(facade, child.task_id, "userX", "1", []) |> ignore
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None)), 0L)
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 2)
}

///|
async test "i253 负向：协办任务不能再派生协办（禁递归）＋零写入" {
  let (facade, repo, iid, _ev) = i253_setup("i253-recursion", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, host.task_id)[0]
  i253_assert_msg(i253_aidant(facade, child.task_id, Some("userX"), Some(@json.string_of("userY")), None, None), "协办任务不能再派生协办")
  assert_eq(i253_rows(repo, iid, host.task_id).length(), 1, msg="零写入")
  assert_eq(i253_rows(repo, iid, child.task_id).length(), 0)
}

// ══════════════════ 协办行能力边界 ══════════════════

///|
async test "i253 协办行可加/摘参与人、可被转办（走既有腿，不造特例）" {
  let (facade, repo, iid, _ev) = i253_setup("i253-actorwrites", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, host.task_id)[0]
  let cid = child.task_id
  // 加参与人（surrogate / addCandidate 同一腿）
  assert_eq(code_of(facade.flow("processTask/surrogate", i159_args([("processTaskId", @json.string_of(cid.to_string())), ("actorIds", @json.array_of([@json.string_of("userK")]))]))), 0L)
  assert_true(repo.find_task_actors(cid).contains("userK"))
  assert_eq(code_of(facade.flow("processTask/addCandidate", i159_args([("processTaskId", @json.string_of(cid.to_string())), ("actorIds", @json.array_of([@json.string_of("userL")]))]))), 0L)
  assert_true(repo.find_task_actors(cid).contains("userL"))
  // 摘参与人（只能摘自己那一票）
  assert_eq(code_of(facade.flow("processTask/removeTaskActor", i159_args([("processTaskId", @json.string_of(cid.to_string())), ("operator", @json.string_of("userK")), ("actorIds", @json.array_of([@json.string_of("userK")]))]))), 0L)
  assert_true(!repo.find_task_actors(cid).contains("userK"))
  // 转办（摘原人＋换新参与人，同一行不新建）
  let t = i159_args([
    ("processTaskId", @json.string_of(cid.to_string())),
    ("operator", @json.string_of("userX")),
    ("fromActor", @json.string_of("userX")),
    ("toActor", @json.string_of("userT")),
    ("reason", @json.string_of("协办转办")),
  ])
  assert_eq(code_of(facade.flow("processTask/transfer", t)), 0L)
  assert_true(!repo.find_task_actors(cid).contains("userX"))
  assert_true(repo.find_task_actors(cid).contains("userT"))
  assert_eq(repo.find_task_by_id(cid).unwrap().task_id, cid, msg="转办不新建任务行")
  assert_true(repo.find_task_by_id(cid).unwrap().is_doing())
  assert_eq(repo.find_task_by_id(cid).unwrap().task_type, 1)
  // 转办后新办理人可办结，且仍不驱动流程
  assert_eq(code_of(i253_exec(facade, cid, "userT", "1", [])), 0L)
  assert_true(repo.find_task_by_id(host.task_id).unwrap().is_doing())
  assert_true(i253_doing(repo, iid, "final") is None)
}

// ══════════════════ 回归：会签合并 ══════════════════

///|
async test "i253 会签票齐即推进，不被协办行挡（合并判据排除 task_type=1）" {
  let (facade, repo, iid, _ev) = i253_cs_setup("i253-csmerge")
  let members = repo.find_doing_tasks(iid, [])
  assert_eq(members.length(), 2)
  let mut rowA : @model.ProcessTask? = None
  let mut rowB : @model.ProcessTask? = None
  for t in members {
    if t.actor_ids.contains("userA") {
      rowA = Some(t)
    }
    if t.actor_ids.contains("userB") {
      rowB = Some(t)
    }
  }
  let a = rowA.unwrap()
  let b = rowB.unwrap()
  assert_eq(code_of(i253_aidant(facade, a.task_id, Some("userA"), Some(@json.string_of("userX")), None, None)), 0L)
  let child = i253_rows(repo, iid, a.task_id)[0]
  assert_true(child.is_doing())
  assert_eq(child.task_name, "cs")
  // 两票齐 ⇒ 推进
  assert_eq(code_of(i253_exec(facade, a.task_id, "userA", "1", [])), 0L)
  assert_eq(code_of(i253_exec(facade, b.task_id, "userB", "1", [])), 0L)
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 20, msg="票齐即推进：实例办结")
  assert_eq(repo.find_task_by_id(child.task_id).unwrap().task_state, 99, msg="协办行随离开节点清场")
  assert_eq(repo.find_doing_tasks(iid, []).length(), 0)
}

///|
async test "i253 会签未齐时协办行办结也不得推进" {
  let (facade, repo, iid, _ev) = i253_cs_setup("i253-csearly")
  let members = repo.find_doing_tasks(iid, [])
  let a = if members[0].actor_ids.contains("userA") { members[0] } else { members[1] }
  i253_aidant(facade, a.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, a.task_id)[0]
  i253_exec(facade, child.task_id, "userX", "1", []) |> ignore
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 10, msg="协办办结不推进")
  assert_eq(i253_doing_count(repo, iid, "cs"), 2)
}

// ══════════════════ 回归：与征询并存 ══════════════════

///|
async test "i253 与征询同节点并存：两族子行靠 task_type 分辨，两闸各数各的行" {
  let on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))
  let (facade, repo, iid, _ev) = i253_setup("i253-coexist", [on])
  let host = doing_task_for(repo, iid, "userA")
  // 征询拉一人（成员行 task_type=0）
  let c = i253_exec(facade, host.task_id, "userA", "1", [("tf_addSignOperators", @json.array_of([@json.string_of("userC")]))])
  assert_eq(code_of(c), 0L, msg="征询发起 code=0（实得 msg=\{msg_of(c)}）")
  // 协办派生一人（协办行 task_type=1），等待闸开
  assert_eq(code_of(i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, Some(@json.bool_of(true)))), 0L)
  let host_row = repo.find_task_by_id(host.task_id).unwrap()
  let all = repo.find_instance_by_id(iid).unwrap().tasks
  assert_eq(@engine.collect_count_members(all, host_row).0, 1, msg="征询收齐闸只数成员行")
  assert_eq(@engine.aidant_count(all, host_row).0, 1, msg="协办等待闸只数协办行")
  assert_eq(@engine.collect_member_rows(all, host_row).length(), 1)
  assert_eq(@engine.aidant_rows(all, host_row).length(), 1)
  assert_true(!@engine.collect_is_member_row(all, @engine.aidant_rows(all, host_row)[0]), msg="协办行不是征询成员行")
  // 协办先办结 ⇒ 征询闸仍拦（各数各的行），文案是征询那一族
  let aidant_row = @engine.aidant_rows(all, host_row)[0]
  i253_exec(facade, aidant_row.task_id, "userX", "1", []) |> ignore
  i253_assert_msg(i253_exec(facade, host.task_id, "userA", "1", []), "节点[review]动态会签意见未收齐（已提交 0/1），不能办理")
  // 征询成员交意见 ⇒ 两闸齐过，主办推进
  let mrow = @engine.collect_member_rows(repo.find_instance_by_id(iid).unwrap().tasks, repo.find_task_by_id(host.task_id).unwrap())[0]
  assert_eq(code_of(i253_exec(facade, mrow.task_id, "userC", "1", [])), 0L)
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L)
  assert_true(i253_doing(repo, iid, "final") is Some(_))
}

///|
async test "i253 反向：征询已收齐、协办未办结 ⇒ 报协办那一族文案（两闸不串味）" {
  let on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))
  let (facade, repo, iid, _ev) = i253_setup("i253-coexist2", [on])
  let host = doing_task_for(repo, iid, "userA")
  i253_exec(facade, host.task_id, "userA", "1", [("tf_addSignOperators", @json.array_of([@json.string_of("userC")]))]) |> ignore
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, Some(@json.bool_of(true))) |> ignore
  let mrow = @engine.collect_member_rows(repo.find_instance_by_id(iid).unwrap().tasks, repo.find_task_by_id(host.task_id).unwrap())[0]
  i253_exec(facade, mrow.task_id, "userC", "1", []) |> ignore
  i253_assert_msg(i253_exec(facade, host.task_id, "userA", "1", []), "节点[review]协办未办结（已办结 0/1），不能办理")
}

///|
async test "i253 征询节点 waitCompletion=false：收齐即推进，未办结协办行清场（加签闸不被协办挡）" {
  let on : (String, Json) = ("dynamicCountersign", @json.bool_of(true))
  let (facade, repo, iid, _ev) = i253_setup("i253-coexist3", [on])
  let host = doing_task_for(repo, iid, "userA")
  i253_exec(facade, host.task_id, "userA", "1", [("tf_addSignOperators", @json.array_of([@json.string_of("userC")]))]) |> ignore
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, Some(@json.bool_of(false))) |> ignore
  let mrow = @engine.collect_member_rows(repo.find_instance_by_id(iid).unwrap().tasks, repo.find_task_by_id(host.task_id).unwrap())[0]
  i253_exec(facade, mrow.task_id, "userC", "1", []) |> ignore
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L, msg="缺省不等协办：收齐即推进")
  assert_true(i253_doing(repo, iid, "final") is Some(_))
  let aidant_row = @engine.aidant_rows(repo.find_instance_by_id(iid).unwrap().tasks, repo.find_task_by_id(host.task_id).unwrap())[0]
  assert_eq(repo.find_task_by_id(aidant_row.task_id).unwrap().task_state, 99)
}

// ══════════════════ 回归：撤回清场 ══════════════════

///|
async test "i253 已办撤回：下游 DOING 协办行一并废弃（血缘自然覆盖），复活行是唯一活待办" {
  let (facade, repo, iid, _ev) = i253_setup("i253-recall", [("allowRecall", @json.bool_of(true))])
  let host = doing_task_for(repo, iid, "userA")
  assert_eq(code_of(i253_exec(facade, host.task_id, "userA", "1", [])), 0L)
  let final_row = i253_doing(repo, iid, "final").unwrap()
  // 在下游 final 行上派生协办 ⇒ 它是 review 行的血缘后代
  assert_eq(code_of(i253_aidant(facade, final_row.task_id, Some("userF"), Some(@json.string_of("userX")), None, None)), 0L)
  let child = i253_rows(repo, iid, final_row.task_id)[0]
  assert_true(child.is_doing())
  let recall_env = facade.flow("processTask/recall", targs([("processTaskId", host.task_id.to_string()), ("operator", "userA")]))
  assert_eq(code_of(recall_env), 0L, msg="撤回 code=0（实得 msg=\{msg_of(recall_env)}）")
  assert_eq(repo.find_task_by_id(child.task_id).unwrap().task_state, 99, msg="下游协办行废弃")
  assert_eq(repo.find_task_by_id(final_row.task_id).unwrap().task_state, 99, msg="下游主办行废弃")
  assert_eq(repo.find_doing_tasks(iid, []).length(), 1, msg="唯一活待办")
}

///|
async test "i253 实例撤回：DOING 协办行随整单置 WITHDRAW(30)，不留孤儿待办" {
  let (facade, repo, iid, _ev) = i253_setup("i253-withdraw", [])
  let host = doing_task_for(repo, iid, "userA")
  i253_aidant(facade, host.task_id, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  let child = i253_rows(repo, iid, host.task_id)[0]
  let w = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))
  assert_eq(code_of(w), 0L, msg="撤回 code=0（实得 msg=\{msg_of(w)}）")
  assert_eq(repo.find_task_by_id(child.task_id).unwrap().task_state, 30)
  assert_eq(repo.find_doing_tasks(iid, []).length(), 0)
}

// ══════════════════ 回归：既有 actor 写腿不变 ══════════════════

///|
async test "i253 transfer／surrogate／addCandidate 在主办行上行为不变（协办存在也不影响）" {
  let (facade, repo, iid, _ev) = i253_setup("i253-unchanged", [])
  let host = doing_task_for(repo, iid, "userA")
  let hid = host.task_id
  i253_aidant(facade, hid, Some("userA"), Some(@json.string_of("userX")), None, None) |> ignore
  // surrogate：只追加，原人保留
  assert_eq(code_of(facade.flow("processTask/surrogate", i159_args([("processTaskId", @json.string_of(hid.to_string())), ("actorIds", @json.array_of([@json.string_of("userB")]))]))), 0L)
  assert_eq(repo.find_task_actors(hid), ["userA", "userB"])
  // addCandidate：同一腿
  assert_eq(code_of(facade.flow("processTask/addCandidate", i159_args([("processTaskId", @json.string_of(hid.to_string())), ("actorIds", @json.array_of([@json.string_of("userC")]))]))), 0L)
  assert_eq(repo.find_task_actors(hid), ["userA", "userB", "userC"])
  // transfer：摘原人换新参与人，同一行不新建，留痕三件照旧
  let t = i159_args([
    ("processTaskId", @json.string_of(hid.to_string())),
    ("operator", @json.string_of("userA")),
    ("fromActor", @json.string_of("userA")),
    ("toActor", @json.string_of("userD")),
    ("reason", @json.string_of("转办原因")),
  ])
  assert_eq(code_of(facade.flow("processTask/transfer", t)), 0L)
  assert_true(!repo.find_task_actors(hid).contains("userA"))
  assert_true(repo.find_task_actors(hid).contains("userD"))
  let after = repo.find_task_by_id(hid).unwrap()
  assert_eq(after.task_id, hid)
  assert_eq(after.variables.get_i64("submitType"), Some(7L))
  assert_true(after.variables.get("tf_transferHistory") is Some(_))
  assert_true(after.actor_id is None, msg="转办不写 actor_id 列")
  // 协办行不受主办转办影响，仍 DOING 且不驱动
  assert_eq(i253_rows(repo, iid, hid).length(), 1)
  assert_true(i253_rows(repo, iid, hid)[0].is_doing())
  // 新办理人办结照常推进
  assert_eq(code_of(i253_exec(facade, hid, "userD", "1", [])), 0L)
  assert_true(i253_doing(repo, iid, "final") is Some(_))
}