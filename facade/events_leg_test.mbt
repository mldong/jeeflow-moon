// issues/127·132「事件代码腿」门面级 recorder 测试。
// 覆盖仅经门面 action 才触达的三支 fire：手动 createCCInstance→CC_CREATE(4)（§4.5 原话）、
// withdraw→TASK_WITHDRAW(8)、transfer→TASK_TRANSFER(7)。全部断"落库之后 fire"＋规范名＋载荷键。
// 复用同包 withdraw_transfer_test.mbt 的 helper（linear_flow_json / targs / msg_of / data_of / parse_iid / doing_task_for）。

///|
/// 带事件录制监听器的门面装配：startAndExecute 自动办结申请节点 → leader 的 task1 DOING。
async fn listening_setup(
  content : String
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64, Array[@event.ProcessEvent]) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let events : Array[@event.ProcessEvent] = []
  ctx2.register_event_listener_sync(fn(ev) { events.push(ev) })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "leg-flow",
    display_name: "事件代码腿流程",
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
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  assert_eq(msg_of(env), "成功")
  let iid = @json.get_str(data_of(env), "processInstanceId").unwrap_or("0")
  (facade, repo, parse_iid(iid), events)
}

///|
async test "i132-events: 手动 createCCInstance 逐人 fire CC_CREATE（§4.5·§11.2 原则1，落库之后）" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  // 起点无抄送（startAndExecute 未带 f_ccActors）⇒ CC_CREATE 只可能来自手动 action
  let env = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "cc1,cc2")]),
  )
  assert_eq(msg_of(env), "成功")
  let cc = events.filter(fn(e) { e.event_type().name() == "CC_CREATE" })
  assert_eq(cc.length(), 2)
  // 逐抄送人 fire：cc_actor_id 直传、sourceId=instanceId（§11.3 code 4）
  assert_eq(cc[0].cc_actor_id(), Some("cc1"))
  assert_eq(cc[1].cc_actor_id(), Some("cc2"))
  assert_eq(cc[0].source_id(), iid)
  assert_eq(cc[1].source_id(), iid)
  // fire 在落库之后：cc 行确实已写入。issues/141 G1 归属条件必填 ⇒ 零条件分页已改判空页，
  // 这里换成仓储真相读法，断言值 2L 一字未动（java JeeflowFullTest:507 同处理方式）。
  assert_eq(repo.cc_instances.length().to_int64(), 2L)
}

///|
async test "i132-events: withdraw fire TASK_WITHDRAW 一次 sourceId=instanceId（§11.3 code 8）" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let env = facade.flow("processInstance/withdraw", targs([("id", iid.to_string()), ("operator", "applicant")]))
  assert_eq(msg_of(env), "成功")
  let wd = events.filter(fn(e) { e.event_type().name() == "TASK_WITHDRAW" })
  assert_eq(wd.length(), 1) // 每轮撤回只 fire 一次（不逐任务）
  assert_eq(wd[0].source_id(), iid) // sourceId=instanceId
  assert_eq(wd[0].data.get_i64("instanceId"), Some(iid))
  assert_eq(wd[0].data.get_str("operator"), Some("applicant"))
  // fire 在落库之后：实例已 30
  assert_eq(repo.find_instance_by_id(iid).unwrap().state, 30)
}

///|
async test "i132-events: transfer fire TASK_TRANSFER sourceId=taskId + 载荷键（§11.3 code 7）" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let env = facade.flow(
    "processTask/transfer",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "leader"),
      ("fromActor", "leader"),
      ("toActor", "lisi"),
    ]),
  )
  assert_eq(msg_of(env), "成功")
  let tr = events.filter(fn(e) { e.event_type().name() == "TASK_TRANSFER" })
  assert_eq(tr.length(), 1)
  assert_eq(tr[0].source_id(), tid) // sourceId=taskId
  assert_eq(tr[0].data.get_i64("instanceId"), Some(iid))
  assert_eq(tr[0].data.get_i64("taskId"), Some(tid))
  assert_eq(tr[0].data.get_str("fromActor"), Some("leader"))
  assert_eq(tr[0].data.get_str("toActor"), Some("lisi"))
  assert_eq(tr[0].data.get_str("operator"), Some("leader"))
  // fire 在落库之后：参与者表已换人
  assert_true(repo.find_task_actors(tid).join("|") == "lisi")
}
