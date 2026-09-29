// issues/141 G1/G2 · 门面出口档（T0，全走内存仓通道，不连 MySQL）。
//
// G1（spec 06-facade §2.5 归属条件必填）：门面 ccList 恒挂归属条件（operator_arg 已把空串/缺键
//   归一化成缺省 user1，issues/129 案 A）⇒ 新增的"缺有效归属条件 ⇒ 空页"短路在门面通道上**不触发**，
//   前端零改动。这里钉的是"补短路别把门面通道一起废掉"，行为档细节在 core/memory 的同名 G1 文件。
// G2（spec 06 §4 写侧判重＝幂等空操作）：手动腿 `processInstance/createCCInstance` 与两条引擎腿
//   共用 create_cc_instance_if_absent 的子集判据 ⇒ 重复抄送 ①不新增行 ②不重置未读 ③不刷原行时间
//   ④不 fire CC_CREATE（码 4）；混了新人的第二次请求 ⇒ 事件里只出现新人。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / rows_of / record_count_of（withdraw_transfer_test.mbt）、
// listening_setup / linear_flow_json、doing_task_for。

///|
fn g1f_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i141-G1/G2 门面] 红样：" + "\{label}")
    abort("[i141-G1/G2 门面] 红样：" + "\{label}")
  }
}


///|
/// 夹具：三实例（user1×2 / other×1）+ 三行 cc ⇒ ccList 出口 user1=2 行 / other=1 行
async fn g1f_setup() -> (
  @mem.MemoryRepository, @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository]
) raise {
  let repo = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx)
  let d : @model.ProcessDefine = {
    id: 1L,
    name: "i141-g1-facade",
    display_name: "i141 G1 门面夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(d)
  let owners : Array[String] = ["user1", "user1", "other"]
  let mut i = 0
  while i < owners.length() {
    let inst = @model.ProcessInstance::create(d, owners[i], @json.FlowData::new())
    repo.save_instance(inst)
    let actor = if owners[i] == "user1" { "user1" } else { "other" }
    repo.create_cc_instance(inst.instance_id, "boss", [actor])
    i = i + 1
  }
  (repo, facade)
}

///|
/// ccList 出口读数（信封 code 必须 0：否则是"报错当空页"假绿）
async fn g1f_cc(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  entries : Array[(String, String)]
) -> (Int64, Int) raise {
  let env = facade.flow("processInstance/ccList", targs(entries))
  let code = code_of(env)
  if code != 0L {
    abort("ccList 出口报错：code=\{code} msg=\{msg_of(env)}")
  }
  let data = data_of(env)
  (record_count_of(data), rows_of(data).length())
}

///|
/// ① G1 门面通道不受影响：显式档 / 空串档 / 缺键档都照常出行（案 A 归一化 ⇒ 短路不触发）
async test "i141-G1 门面 ccList 三档照常出行（归属短路只在直连仓储零条件时触发）" {
  let (_, facade) = g1f_setup()
  let (c_u1, r_u1) = g1f_cc(facade, [("operator", "user1")])
  g1f_check(c_u1 == 2L && r_u1 == 2, "显式 user1 档 2 行（实际 \{c_u1}/\{r_u1}）")
  let (c_blank, r_blank) = g1f_cc(facade, [("operator", "")])
  g1f_check(c_blank == 2L && r_blank == 2, "空串档归一到 user1 ⇒ 2 行（实际 \{c_blank}/\{r_blank}）")
  let (c_missing, r_missing) = g1f_cc(facade, [])
  g1f_check(c_missing == 2L && r_missing == 2, "缺键档归一到 user1 ⇒ 2 行（实际 \{c_missing}/\{r_missing}）")
  let (c_ws, _) = g1f_cc(facade, [("operator", "   ")])
  assert_eq(c_ws, 2L)
}

///|
/// ② G1 正向对照的另一半：他人档/查无此人档 ⇒ 空页（"空页"是新契约给缺条件的答案，
/// 这一档本来就有，不许被短路改成人人空页）
async test "i141-G1 门面 ccList 他人档/查无此人档仍按归属出行或空页" {
  let (_, facade) = g1f_setup()
  let (c_other, r_other) = g1f_cc(facade, [("operator", "other")])
  g1f_check(c_other == 1L && r_other == 1, "other 档 1 行（实际 \{c_other}/\{r_other}）")
  let (c_none, r_none) = g1f_cc(facade, [("operator", "nobody")])
  g1f_check(c_none == 0L && r_none == 0, "查无此人 ⇒ 空页（实际 \{c_none}/\{r_none}）")
}

///|
/// ③ G1 直连仓储（绕过门面归一化）零归属条件 ⇒ 空页 —— 门面档与仓储档的分工留档：
/// 短路防的就是"绕过门面直连仓储"的调用方（java 侧同一句话写在 SPI 注释上）。
async test "i141-G1 直连仓储零条件⇒空页（门面归一化不背这个锅）" {
  let (repo, _) = g1f_setup()
  let page = repo.page_cc_instances(@model.PageQuery::new(1L, 50L))
  assert_eq(page.record_count(), 0L)
  assert_eq(page.rows().length(), 0)
  let q = @model.PageQuery::new(1L, 50L)
  q.set_operator(Some("user1"))
  assert_eq(repo.page_cc_instances(q).record_count(), 2L)
}

///|
/// ④ G2 手动腿首轮正向对照：两个新人 ⇒ 两行 + 两个码 4（同人同序）
async test "i141-G2 手动腿 首轮正向对照：两新人两行两码4" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let env = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userB,userC")]),
  )
  assert_eq(msg_of(env), "成功")
  assert_eq(repo.cc_instances.length(), 2)
  let fired = cc_created_actors(events)
  g1f_check(fired == ["userB", "userC"], "首轮逐人 fire 码 4（实际 \{fired}）")
  for e in events {
    if e.event_type() is @event.CcCreate {
      assert_eq(e.source_id(), iid)
    }
  }
}

///|
/// ⑤ G2 手动腿重复抄 ⇒ ①不新增行 ②不重置未读 ④不 fire 码 4
async test "i141-G2 手动腿 重复抄同一人⇒不新增行不重置未读不fire" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let base = targs([("processInstanceId", iid.to_string())])
  let _ = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userB")]),
  )
  assert_eq(repo.cc_instances.length(), 1)
  assert_eq(cc_created_actors(events).length(), 1)
  // 先读掉 ⇒ state=1
  let _ = facade.flow(
    "processInstance/updateCCStatus",
    targs([("processInstanceId", iid.to_string()), ("operator", "userB")]),
  )
  assert_eq(repo.cc_instances[0].state, 1)
  let ct_before = repo.cc_instances[0].create_user
  // 再抄同一人 ⇒ 四档全不许变
  let env = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "other_op"), ("actorIds", "userB")]),
  )
  assert_eq(msg_of(env), "成功")
  assert_eq(repo.cc_instances.length(), 1)
  assert_eq(cc_created_actors(events).length(), 1)
  assert_eq(repo.cc_instances[0].state, 1)
  assert_eq(repo.cc_instances[0].create_user, ct_before)
}

///|
/// ⑥ G2 手动腿子集 fire：第二次请求混新老 ⇒ 事件里只出现新人
async test "i141-G2 手动腿 第二次混新老⇒事件只出现新人" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let _ = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userB,userC")]),
  )
  assert_eq(cc_created_actors(events), ["userB", "userC"])
  let env = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userC,userD")]),
  )
  assert_eq(msg_of(env), "成功")
  assert_eq(repo.cc_instances.length(), 3)
  // 改前此格红：第二支会把 C、D 全量再 fire 一遍 ⇒ [B,C,C,D]
  g1f_check(
    cc_created_actors(events) == ["userB", "userC", "userD"],
    "只 fire 实际新建子集（实际 \{cc_created_actors(events)}）",
  )
}

///|
/// ⑦ G2 手动腿同一次调用内重复折叠 ⇒ 一人一行一次 fire
async test "i141-G2 手动腿 同调用内重复折叠" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let env = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userB,userB,userC")]),
  )
  assert_eq(msg_of(env), "成功")
  assert_eq(repo.cc_instances.length(), 2)
  assert_true(cc_created_actors(events) == ["userB", "userC"])
}

///|
/// ⑧ G2 三条入口共用同一判据：手动腿先抄 userB，办理腿（processTask/execute 的 tf_ccActors）
/// 再抄 userB+userC ⇒ 只新增 userC 一行、只 fire userC 一次。
async test "i141-G2 手动腿×办理腿 共用判据（跨入口重复不发）" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let _ = facade.flow(
    "processInstance/createCCInstance",
    targs([("processInstanceId", iid.to_string()), ("operator", "applicant"), ("actorIds", "userB")]),
  )
  assert_eq(cc_created_actors(events), ["userB"])
  let tid = doing_task_for(repo, iid, "leader").task_id
  let env = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", tid.to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
      ("tf_ccActors", "userB,userC"),
    ]),
  )
  assert_eq(msg_of(env), "成功")
  assert_eq(repo.cc_instances.length(), 2)
  // 改前此格红：办理腿把 B、C 全量 fire ⇒ [B,B,C]
  g1f_check(
    cc_created_actors(events) == ["userB", "userC"],
    "跨入口判重：只 fire 新人（实际 \{cc_created_actors(events)}）",
  )
}

///|
/// 码 4（CC_CREATE）事件里的抄送人序（与 core/engine 的同名 helper 同口径，门面包各自一份）
fn cc_created_actors(events : Array[@event.ProcessEvent]) -> Array[String] {
  let out : Array[String] = []
  for e in events {
    if e.event_type() is @event.CcCreate {
      out.push(match e.cc_actor_id() {
        Some(a) => a
        None => ""
      })
    }
  }
  out
}
