// issues/116 批次 D（门面出口视角）+ issues/117（我已办判据）的内存仓用例补充。
// 引擎级条款明细见 core/engine/surrogate_test.mbt；本文件只管两件事：
//   ① 用户在「我的委托」配一条委托后，**门面出口**（processTask/todoList）真的能看到该单
//      —— 这正是 issues/116 §1 描述的用户视角缺陷（台账存得进、单子不来）；
//   ② 台账五个 action（save/page/detail/remove）与既有加签/撤回主流程零回归。
// 断言一律落读回值（参与者表 + 分页出口 recordCount），不断内存聚合副本。

///|
/// 门面 + 内存仓（ext 与主仓同一个实例 = 台账与查询同源），auto_apply 即条款 3 的开关
fn sg_facade(
  repo : @mem.MemoryRepository,
  auto_apply~ : Bool = true
) -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx.with_surrogate_auto_apply(auto_apply))
}

///|
async fn sg_define_id(repo : @mem.MemoryRepository, content : String) -> Int64 raise {
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "decoy-define",
    display_name: "诱饵定义名",
    define_type: "approval",
    state: 1,
    content,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  define_info.id
}

///|
/// 台账写入走门面 action（连 processSurrogate/save 的参数口径一起验）
async fn sg_save_ledger(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  operator : String,
  agent : String,
  process_name : String,
  enabled~ : String? = None,
  start_time~ : String? = None,
  end_time~ : String? = None
) -> Json raise {
  let entries : Array[(String, String)] = [
    ("operator", operator),
    ("surrogate", agent),
    ("processName", process_name),
  ]
  match enabled {
    Some(v) => {
      let _ = entries.push(("enabled", v))
    }
    None => ()
  }
  match start_time {
    Some(v) => {
      let _ = entries.push(("startTime", v))
    }
    None => ()
  }
  match end_time {
    Some(v) => {
      let _ = entries.push(("endTime", v))
    }
    None => ()
  }
  facade.flow("processSurrogate/save", targs(entries))
}

///|
fn sg_ok(cond : Bool, label : String) -> Unit {
  if !cond {
    println("FAIL 断言失败：" + label)
    abort(label)
  }
}

///|
async fn sg_started(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  did : Int64
) -> Int64 raise {
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", did.to_string()), ("operator", "applicant")]),
  )
  sg_ok(code_of(env) == 0L, "发起应成功（实际 msg=\{msg_of(env)}）")
  parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
}

// ══════════════════ 批次 D 门面出口 ══════════════════

///|
async test "批次D 用户视角: 配好委托后代理人真的拿到待办（issues/116 §1 的反例）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  let saved = sg_save_ledger(facade, "leader", "li", "wt-linear")
  sg_ok(code_of(saved) == 0L, "委托台账保存成功（msg=\{msg_of(saved)}）")
  let iid = sg_started(facade, did)
  // ① 参与者表读回：task1 的参与者 = 授权人 + 代理人
  let actors = repo.find_task_actors(doing_task_for(repo, iid, "leader").task_id)
  sg_ok(actors.contains("leader"), "授权人保留（实际=\{actors.join("|")}）")
  sg_ok(actors.contains("li"), "代理人随任务落进参与者表（实际=\{actors.join("|")}）")
  // ② 出口读回：代理人与授权人都看得到这一单
  sg_ok(page_has_instance(todo_page(facade, "li"), iid), "代理人 todoList 出现该单")
  sg_ok(page_has_instance(todo_page(facade, "leader"), iid), "授权人 todoList 仍在（任一可办）")
  // ③ 台账可查（关闭运行期应用≠关闭 CRUD，这里证台账本身没被动过）
  // issues/152 ② 归属不变式生效后 page 只看自己授出的行：这条夹具行 operator=leader，
  // 必须带 operator=leader 才命中（不带 ⇒ 归一到缺省 user1 ⇒ 0 行，旧断言的"1 条"意图不变更正）
  let page = facade.flow("processSurrogate/page", targs([("operator", "leader"), ("pageNum", "1"), ("pageSize", "10")]))
  sg_ok(record_count_of(data_of(page)) == 1L, "台账 page 仍读到 1 条")
}

///|
async test "批次D 负向: 停用 / 窗外 / 自委托 / 脏 enabled 四类代理人都不许拿到待办" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  // enabled=0
  let repo1 = @mem.MemoryRepository::new()
  let f1 = sg_facade(repo1)
  let d1 = sg_define_id(repo1, linear_flow_json())
  let _ = sg_save_ledger(f1, "leader", "li", "wt-linear", enabled=Some("0"))
  let i1 = sg_started(f1, d1)
  sg_ok(!page_has_instance(todo_page(f1, "li"), i1), "enabled=0 不得拿到待办")
  // 窗外（结束时间已过）
  let repo2 = @mem.MemoryRepository::new()
  let f2 = sg_facade(repo2)
  let d2 = sg_define_id(repo2, linear_flow_json())
  let _ = sg_save_ledger(f2, "leader", "li", "wt-linear", end_time=Some("2026-09-20 23:59:59"))
  let i2 = sg_started(f2, d2)
  sg_ok(!page_has_instance(todo_page(f2, "li"), i2), "窗外不得拿到待办")
  // 自委托
  let repo3 = @mem.MemoryRepository::new()
  let f3 = sg_facade(repo3)
  let d3 = sg_define_id(repo3, linear_flow_json())
  let _ = sg_save_ledger(f3, "leader", "leader", "wt-linear")
  let i3 = sg_started(f3, d3)
  sg_ok(
    repo3.find_task_actors(doing_task_for(repo3, i3, "leader").task_id) == ["leader"],
    "自己委托给自己不追加、也不重复",
  )
  // 脏 enabled：spec 06 §4.5 条款 4 **写侧**＝落 0 且**不得抛错**（条款点名的反例正是"toInt 直接抛"
  // 那种形状，即 Node 首版）。本行旧断言写的是"门面必须拒绝建单"，把"不得静默启用"实现成了
  // "不许建" —— 与条款相反，且与 Java `JeeflowFacade.java:1560` 的参考实现、门禁 L2-18 都冲突（issues/148）。
  // 防护意图原样保留在下一行：脏值那一行一律不得产生待办。
  let dirty = sg_save_ledger(f3, "leader", "li_dirty", "wt-linear", enabled=Some("abc"))
  sg_ok(
    code_of(dirty) == 0L,
    "enabled=abc 应建单成功并落 0，不得抛（实际 msg=\{msg_of(dirty)}）",
  )
  sg_ok(!page_has_instance(todo_page(f3, "li_dirty"), i3), "脏值委托不产生任何待办")
}

///|
async test "批次D 负向: 显式关闭后回到仅台账（条款 3 的门面形状）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo, auto_apply=false)
  let did = sg_define_id(repo, linear_flow_json())
  let saved = sg_save_ledger(facade, "leader", "li", "wt-linear")
  let sg_id = parse_iid(@json.get_str(data_of(saved), "id").unwrap_or("0"))
  let iid = sg_started(facade, did)
  let actors = repo.find_task_actors(doing_task_for(repo, iid, "leader").task_id)
  sg_ok(actors == ["leader"], "关闭后参与者原样（实际=\{actors.join("|")}）")
  sg_ok(record_count_of(todo_page(facade, "li")) == 0L, "关闭后代理人无待办")
  // 台账五条 action 全部照常（关的是运行期应用，不是 CRUD）
  let detail = facade.flow("processSurrogate/detail", targs([("id", sg_id.to_string())]))
  sg_ok(code_of(detail) == 0L, "detail 仍可读（msg=\{msg_of(detail)}）")
  let rm = facade.flow("processSurrogate/remove", targs([("id", sg_id.to_string())]))
  sg_ok(code_of(rm) == 0L, "remove 仍可用")
  sg_ok(record_count_of(facade.flow("processSurrogate/page", targs([])) |> data_of) == 0L, "remove 后台账为空")
}

///|
async test "批次D 回归: 委托与加签并存、撤回主流程不受影响" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  let _ = sg_save_ledger(facade, "leader", "li", "wt-linear")
  let iid = sg_started(facade, did)
  let tid = doing_task_for(repo, iid, "leader").task_id
  let add = facade.flow("processTask/addCandidate", targs([("processTaskId", tid.to_string()), ("actorIds", "extra")]))
  sg_ok(msg_of(add) == "成功", "既有加签 action 不被委托逻辑影响")
  let actors = repo.find_task_actors(tid)
  sg_ok(actors.length() == 3, "加签 + 委托 + 原人 = 3 个参与者（实际=\{actors.join("|")}）")
  for who in ["leader", "li", "extra"] {
    sg_ok(actors.contains(who), "参与者齐（缺 \{who}）")
  }
  let wd = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))
  sg_ok(msg_of(wd) == "成功", "撤回主流程回归")
  sg_ok(repo.find_instance_by_id(iid).unwrap().state == 30, "撤回后实例 state=30")
}

// ══════════════════ issues/117 门面出口 ══════════════════

///|
async test "批次117: 转办→撤回后 fromActor 的已办不含该单（<>10 才有的复现面，与另七栈同尺子）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  let iid = sg_started(facade, did)
  let tid = doing_task_for(repo, iid, "leader").task_id
  // 转办 leader → lisi（本栈契约第 4 条禁写 actor_id）
  let tr = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "leader"),
      ("fromActor", "leader"),
      ("toActor", "lisi"),
    ]),
  )
  sg_ok(msg_of(tr) == "成功", "转办成功（msg=\{msg_of(tr)}）")
  // 撤回：任务离开 DOING（state=30）——在 `<> 10` 判据下这行**进了已办候选集**，
  // 唯一挡住它的是"办理人列没被转办写过"，所以本用例真有牙（=20 时代压根不候选）。
  let wd = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))
  sg_ok(msg_of(wd) == "成功", "撤回成功")
  let withdrawn = repo.find_task_by_id(tid).unwrap()
  sg_ok(withdrawn.task_state == 30, "库里任务态 30")
  sg_ok(withdrawn.actor_id is None, "办理人列仍无值（转办不得覆写）")
  for who in ["leader", "lisi"] {
    sg_ok(!page_has_instance(done_page(facade, who), iid), "\{who} 的已办不得冒入这单")
    sg_ok(record_count_of(done_page(facade, who)) == 0L, "\{who} 的已办 recordCount=0")
  }
  // 同一份数据在两个仓储给出同一答案：SQL 仓真机对拍见 demo/cmd/t1_mysql（T1-F117）
}

// ══════════════════ issues/121 P1 门面出口 ══════════════════

///|
/// 门面读标记的优先级：行上值 > 现算。现算带"仅进行中"判定，拿它覆写会把已办结的
/// apply 行洗成 false —— 那正是 P2 血缘回退要避免的口径，也是本用例要钉住的东西。
async test "批次121: detail 出口的 ext.isFirstTaskNode 以落库值为准（历史行不被现算覆写）" {
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  let iid = sg_started(facade, did)
  let env = facade.flow("processInstance/detail", targs([("id", iid.to_string())]))
  sg_ok(code_of(env) == 0L, "detail 应成功（msg=\{msg_of(env)}）")
  let rows = match @json.get(data_of(env), "tasks") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let mut saw_apply = false
  for row in rows {
    if @json.get_str(row, "taskName") == Some("apply") {
      saw_apply = true
      let row_state = @json.get_i64(row, "taskState").unwrap_or(-1L)
      sg_ok(row_state != 10L, "前置条件：apply 行应已办结（实得 state=\{row_state}）")
      let flag = match @json.get(row, "ext") {
        Some(ext) => match @json.get(ext, "isFirstTaskNode") {
          Some(v) => @json.as_bool(v).unwrap_or(false)
          None => false
        }
        None => false
      }
      sg_ok(flag, "已办结的首任务节点行仍应报 true（被「仅进行中」现算覆写就会变 false）")
    }
  }
  sg_ok(saw_apply, "detail 应回历史行 apply（实得 \{rows.length()} 行）")
}

// ══════════════════ issues/152 档4 / 档5 ══════════════════

///|
/// 档4（问题③在 moon 的落点——写侧 operator 三档归一，spec 06 §2.5/§4.5）：
/// save **缺键／空串／全空白** 三档 ⇒ 行一律落归一缺省 user1，绝不允许写出 operator='' 的死行
/// （get_surrogate 的 WHERE operator = ? 永不命中——台账看得见、待办永不并人，比报错更难查）。
/// 正面判据（同 java facadeSaveWithoutOperatorKeyLandsOnNormalizedOperator 的"能被本人待办命中"）：
/// 以归一后的授权人 user1 建单 ⇒ 委托代理人真进参与者表 + 代理人 todoList 出现该单。
/// 坏形状（把空白档原样落库）判红由 detail 读回的 operator 逐字核对保证。
async test "批次152 档4: save 缺键/空串/全空白 三档 operator 一律落 user1 且能被本人待办命中" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  // 夹具流程：task1 办理人改成 user1，让「归一后的授权人」真有单子可被代理人并进
  let did = sg_define_id(
    repo,
    linear_flow_json().replace(old="\"assignee\": \"leader\"", new="\"assignee\": \"user1\""),
  )
  let base : Array[(String, String)] = [
    ("surrogate", "li152"),
    ("processName", "wt-linear"),
    ("startTime", "2000-01-01 00:00:00"),
    ("endTime", "2099-12-31 23:59:59"),
  ]
  for op in [None, Some(""), Some("   ")] {
    let entries : Array[(String, String)] = match op {
      None => base
      Some(v) => {
        let e : Array[(String, String)] = [("operator", v)]
        for b in base {
          e.push(b)
        }
        e
      }
    }
    let env = facade.flow("processSurrogate/save", targs(entries))
    sg_ok(code_of(env) == 0L, "save 应成功（msg=\{msg_of(env)}）")
    let sg_id = parse_iid(@json.get_str(data_of(env), "id").unwrap_or("0"))
    let detail = facade.flow("processSurrogate/detail", targs([("id", sg_id.to_string())]))
    let got_op = @json.get_str(data_of(detail), "operator").unwrap_or("<missing>")
    sg_ok(
      @json.get_str(data_of(detail), "operator") == Some("user1"),
      "operator 三档（缺键/空串/全空白）必须都落归一缺省 user1，不得落空串（实得=\{got_op}）",
    )

  }
  // 正面判据：以归一后的授权人（user1）建单 ⇒ 代理人进参与者表、进其待办
  let iid = sg_started(facade, did)
  let actors = repo.find_task_actors(doing_task_for(repo, iid, "user1").task_id)
  sg_ok(actors.contains("user1"), "授权人保留（委托不是转办；实际=\{actors.join("|")}）")
  sg_ok(actors.contains("li152"), "该行必须能被本人后续待办命中：代理人进参与者表（实际=\{actors.join("|")}）")
  sg_ok(page_has_instance(todo_page(facade, "li152"), iid), "代理人 todoList 出现该单")
}

///|
/// 档5（问题②A 案·processSurrogate/page 归属不变式，内存通道两层）：
/// · 门面层：带 operator ⇒ 只见自己授出的行；不带／全空白 ⇒ 归一到缺省 user1，**不得全库**；
/// · 仓储层第二道：绕过门面直调 page_surrogates，归属列缺键/空串/全空白 ⇒ **空页**。
/// 夹具刻意非对称（user1=1 / op-mine=1 / op-others=2 ⇒ 全库 4）：空仓上 0==0 自等假绿照不出来。
/// SQL 仓同判据真机对拍在 repository-mysql/smoke T1-I152（条款 6 双仓同答案）。
async test "批次152 档5: processSurrogate/page 归属不变式（门面注入 + 仓储空归属=空页）" {
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let _ = sg_save_ledger(facade, "user1", "ag152a", "f152")
  let _ = sg_save_ledger(facade, "op-mine", "ag152b", "f152")
  let _ = sg_save_ledger(facade, "op-others", "ag152c", "f152")
  let _ = sg_save_ledger(facade, "op-others", "ag152d", "f152")
  // ① 带 operator：只见自己（阳性对照：真实归属值必须出行，见③的 q_ok）
  let mine = facade.flow("processSurrogate/page", targs([("operator", "op-mine"), ("pageNum", "1"), ("pageSize", "10")]))
  sg_ok(code_of(mine) == 0L, "page 应成功（msg=\{msg_of(mine)}）")
  sg_ok(
    record_count_of(data_of(mine)) == 1L,
    "带 operator 只见自己授出的行（实得 recordCount=\{record_count_of(data_of(mine))}）",
  )
  let mine_rows = rows_of(data_of(mine))
  sg_ok(
    mine_rows.length() == 1 && @json.get_str(mine_rows[0], "operator") == Some("op-mine"),
    "读回行的归属列逐字核对（不是恰好条数对）",
  )
  // ② 不带 operator：归一缺省 ⇒ 只出 user1 的行，绝不退化成全库 4 条
  let none_env = facade.flow("processSurrogate/page", targs([("pageNum", "1"), ("pageSize", "10")]))
  sg_ok(
    record_count_of(data_of(none_env)) == 1L,
    "缺 operator 不是全库，是归一到缺省 user1（实得=\{record_count_of(data_of(none_env))}）",
  )
  let none_rows = rows_of(data_of(none_env))
  sg_ok(none_rows.length() == 1 && @json.get_str(none_rows[0], "operator") == Some("user1"), "缺省档读回的全是 user1 的行")
  // ②b 全空白档与缺键同档（与 operator_blank_test 四出口同一把尺子）
  let blank_env = facade.flow("processSurrogate/page", targs([("operator", "   "), ("pageNum", "1"), ("pageSize", "10")]))
  sg_ok(record_count_of(data_of(blank_env)) == 1L, "全空白 operator ⇒ 归一只出 user1")
  // ③ 仓储第二道：绕过门面直调——缺键/空串/全空白 ⇒ 空页；有效档照常出行（阳性对照，防"一律空页"假修）
  let q_ok = @model.PageQuery::new(1L, 10L)
  q_ok.set_operator(Some("op-others"))
  sg_ok(repo.page_surrogates(q_ok).record_count() == 2L, "阳性对照：有效归属条件必须照常出行（实得=\{repo.page_surrogates(q_ok).record_count()}）")
  let q_none = @model.PageQuery::new(1L, 10L)
  sg_ok(repo.page_surrogates(q_none).record_count() == 0L, "直调仓储缺归属键 ⇒ 空页（不得全库 4 条）")
  sg_ok(repo.page_surrogates(q_none).rows().length() == 0, "空页档 rows 也必须为空")
  let q_blank = @model.PageQuery::new(1L, 10L)
  q_blank.set_operator(Some(""))
  sg_ok(repo.page_surrogates(q_blank).record_count() == 0L, "直调仓储空串归属 ⇒ 空页")
  let q_ws = @model.PageQuery::new(1L, 10L)
  q_ws.set_operator(Some("  \t\r\n "))
  sg_ok(repo.page_surrogates(q_ws).record_count() == 0L, "直调仓储全空白归属 ⇒ 空页")
}
