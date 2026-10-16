// audit8 R86（issues/209 §3.2＝C3-L2 `L2-乙-3` ＋ C3-L3 `L3-乙-4`）——jump 负向静默 no-op 的补牙判据。
//
// 案面：`submitType=4` ＋ 模型里不存在的节点名 ⇒ 六栈（java/go/py/node/php/csharp）给
// 99999999 ＋ 逐字「根据节点名称[x]无法找到节点模型」；本栈改前是 `engine_ops.mbt` 里
// 那句 `None => ()`——对外 code=0、当前任务已被办掉、又没有后继＝实例原地失联（静默半截事实）。
// 修复形状＝**前置校验**（放在任何写之前）＋ 空串档与"没带"同档（＝血缘回退）。
// 两条为什么都必须在本栈这样：六栈的报错点在 prepare 之后、靠外层事务回滚兜住"任务未被动"，
// 而本栈的门面/仓储没有事务模板这一层 ⇒ 报错点若在写之后就真的留下半截事实。
//
// ⚠ 判据一律打**公开入口** `Engine::execute_and_jump_async`：本栈 `*_test.mbt` 是包外测试，
//   私有 `require_jump_node`／`execute_jump_mode_async` 够不着（R91 轮实测过），也不该够得着
//   ——契约是对外面给的，钉内部口等于给自己发免检。
// ⚠ 断言一律给**整串期望**（`assert_eq` 失败时把两侧都打出来），不用"带 msg 的 assert_true"：
//   本工具链的 `assert_true/assert_eq` 第二参是 `msg? : StringView` 的可选形参，按位置喂两个
//   实参会直接编译失败（本轮实测），而那正好说明"只判包含关系"是可替代的更弱形状。
// ⚠ 夹具复用同包 r91 那份（start→apply→approval→end 线性两节点）：本轮判据钉的是"写没写"，
//   节点少一个就多一格"走错支"的余地，不必另起炉灶。

///|
/// 取错误的对外文案（未报错时返回哨兵串，让"没报错"读成一条独立的红，
/// 而不是靠 try 块外的 assert 悄悄跳过）
async fn r86_jump_err(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id : Int64,
  operator : String,
  target : String?
) -> String {
  let args = @json.FlowData::new()
  args.insert_i64("submitType", 4L)
  try {
    let _ = engine.execute_and_jump_async(task_id, operator, args, target)
    "<未报错>"
  } catch {
    e => e.message()
  }
}

///|
async test "r86 ① 跳转目标节点不存在要显式报错，且不落半截事实" {
  let (engine, repo) = r91_engine([], [], [])
  let did = save_flow_define(repo, "r86-missing", r91_flow("", "", "", "", ""))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let ta = r91_task_of(repo, inst.instance_id, "apply")

  // 摘掉前置校验 ⇒ 这里拿到的是 Internal 兜底档「内部错误: 跳转目标节点在入口校验后消失…」，
  // 整串不等 ⇒ 本断言照红（判据有牙，不是"报了个错就算过"）
  assert_eq(
    r86_jump_err(engine, ta.task_id, "applicant", Some("nope")),
    "根据节点名称[nope]无法找到节点模型",
  )

  // 「任务未被动」三条读数：任务行仍 DOING、实例仍 10、待办行数没变
  let row = repo.find_task_by_id(ta.task_id).unwrap()
  assert_eq(row.task_state, @model.TaskState::Doing.code())
  let inst_row = repo.find_instance_by_id(inst.instance_id).unwrap()
  assert_eq(inst_row.state, 10)
  assert_eq(repo.find_doing_tasks(inst.instance_id, []).length(), 1)
}

///|
/// 空串档：`""` 与"没带"同档＝血缘回退（基准＝java `JeeflowEngineImpl.java:184
/// StringUtils.isEmpty(nodeName)`，六栈都在引擎内分这一档）。
/// 本夹具里 apply 是首任务节点、无血缘 ⇒ 回退档给的是「上一步任务ID为空…」，
/// 与「无法找到节点模型」两条文案彼此分得开 ⇒ 才算真走了回退那一支，而不是把空串当节点名去查。
async test "r86 ② 空串目标名走血缘回退档，不落\"节点名不存在\"那一档" {
  let (engine, repo) = r91_engine([], [], [])
  let did = save_flow_define(repo, "r86-blank", r91_flow("", "", "", "", ""))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let ta = r91_task_of(repo, inst.instance_id, "apply")

  let msg = r86_jump_err(engine, ta.task_id, "applicant", Some(""))
  assert_eq(msg, "上一步任务ID为空，无法驳回至上一步处理")
  assert_true(!msg.contains("无法找到节点模型"))
  // 同档对照：`None`（没带）必须与空串给出**同一条**文案，否则两档又塌成两样。
  // ⚠ 另起一套 engine/实例——回退那一支走 `load_exec_for_task`，它会先把任务办结再判血缘，
  //   在同一行上连打两次第二次拿到的是「非法状态转换: Task N is not DOING」（本用例第一发就
  //   撞在这，读起来像"两档文案不同"，其实是状态被上一次调用改掉了）。该形状属 R86 之外：
  //   六栈的回退档同样排在 prepare 之后、靠事务回滚兜住，本栈无事务模板 ⇒ 已另记台账待裁。
  let (engine2, repo2) = r91_engine([], [], [])
  let did2 = save_flow_define(repo2, "r86-blank-b", r91_flow("", "", "", "", ""))
  let inst2 = engine2.start_async(did2, "applicant", @json.FlowData::new())
  let ta2 = r91_task_of(repo2, inst2.instance_id, "apply")
  assert_eq(r86_jump_err(engine2, ta2.task_id, "applicant", None), msg)
}

///|
/// 正向对照：真存在的节点名照旧跳转成功（防把前置校验写成"逢 jump 必报错"那一形——
/// 那种实现下①②都绿，本档会红）。
async test "r86 ③ 正向对照：合法目标名仍能跳转" {
  let (engine, repo) = r91_engine([], [], [])
  let did = save_flow_define(repo, "r86-ok", r91_flow("", "", "", "", ""))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let args = @json.FlowData::new()
  args.insert_i64("submitType", 4L)
  let created = engine.execute_and_jump_async(ta.task_id, "applicant", args, Some("approval"))
  assert_eq(created.length(), 1)
  let tb = r91_task_of(repo, inst.instance_id, "approval")
  assert_eq(tb.task_name, "approval")
}
