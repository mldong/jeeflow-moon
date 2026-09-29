// issues/141 G2 · 抄送写侧判重＝幂等空操作（spec 06 §4 / spec §11.2 原则 1）—— **内存腿**行为档。
//
// 病灶：同一 (instance_id, actor_id) 重复抄送会再插一行，并把 state 抹回未读、时间刷成最新，
// 引擎还照旧按"原始请求全量"fire CC_CREATE（码 4）⇒ 数据面凭空多行、通知面重复提醒。
// 基准＝java 参考实现（3d1fc98）新增的两件能力：`find_cc_actors`（读已有 cc 行的人）＋
// `create_cc_instance_if_absent`（只插新人、返回**实际新建子集**）。判重在**写侧**：
// 查询侧不引入去重、历史重复行也不清理（owner 2026-09-29 拍）。
// 本栈内存仓的 cc 本来就存成带 state/create_time/update_time 的 CcInstance 行 ⇒ ②③两档照得出来
// （时间档用哨兵值注入，内存仓建行时 create_time/update_time 恒 None，不注入就照不出"被刷没刷"）。
//
// 边界说明（本轮不动）：`""`／`[""]` 这一档 moon 现状是"空段丢弃"、java 是"建一条 actor_id='' 的行"，
// 属已知历史分叉（issues/141 G10 待 owner 拍），见 cc_actors_shape_test.mbt 的两形态等价断言。

///|
fn g2_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i141-G2 内存写侧] 红样：" + "\{label}")
    abort("[i141-G2 内存写侧] 红样：" + "\{label}")
  }
}



///|
/// 读数串（红样消息里带集合现值；直接用 \{arr} 会撞上 Show 的 deprecated 警告）
fn g2_arr(items : Array[String]) -> String {
  let b = StringBuilder()
  for i, s in items {
    if i > 0 {
      b.write_string(",")
    }
    b.write_string(s)
  }
  b.to_string()
}

///|
/// 夹具：一个实例（写侧判重只看 cc 行本身，不需要引擎参与）
async fn g2_setup() -> (@memory.MemoryRepository, Int64) raise {
  let repo = @memory.MemoryRepository::new()
  let d : @model.ProcessDefine = {
    id: 1L,
    name: "i141-g2-cc",
    display_name: "i141 G2 写侧判重夹具",
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
  let inst = @model.ProcessInstance::create(d, "boss", @json.FlowData::new())
  repo.save_instance(inst)
  (repo, inst.instance_id)
}

///|
/// 在同一仓里再加一个实例（判重键是 (instance_id, actor_id)，跨实例不许互相判掉）
async fn g2_add_instance(repo : @memory.MemoryRepository, operator : String) -> Int64 raise {
  let inst = @model.ProcessInstance::create(repo.defines[1L], operator, @json.FlowData::new())
  repo.save_instance(inst)
  inst.instance_id
}

///|
/// 按 actor 取第一行 cc（仓储真相）
fn g2_row(repo : @memory.MemoryRepository, actor : String) -> @model.CcInstance? {
  let mut hit : @model.CcInstance? = None
  for cc in repo.cc_instances {
    if cc.actor_id == actor {
      hit = Some(cc)
      break
    }
  }
  hit
}

///|
fn g2_row_count(repo : @memory.MemoryRepository, actor : String) -> Int {
  let mut n = 0
  for cc in repo.cc_instances {
    if cc.actor_id == actor {
      n = n + 1
    }
  }
  n
}

///|
/// ① 首轮正向对照：全新的人 ⇒ 一人一行，子集＝全量请求且同序；新行必须是未读（否则②那格恒真）
async test "i141-G2 内存仓 首轮正向对照：全新两人建两行、子集=全量同序" {
  let (repo, iid) = g2_setup()
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC"])
  g2_check(created == ["userB", "userC"], "子集＝全量且与入参同序（实际 \{g2_arr(created)}）")
  assert_eq(repo.cc_instances.length(), 2)
  assert_eq(repo.find_cc_actors(iid), ["userB", "userC"])
  match g2_row(repo, "userB") {
    Some(r) => {
      assert_eq(r.state, 0)
      assert_eq(r.process_instance_id, iid)
    }
    None => g2_check(false, "userB 的 cc 行存在")
  }
}

///|
/// ② 不新增行：旧入口 create_cc_instance 也判重（两层同判据 ⇒ 直连旧方法的调用方不会重复建行）
async test "i141-G2 内存仓 ①重复抄同一人不新增行（旧入口同判据）" {
  let (repo, iid) = g2_setup()
  repo.create_cc_instance(iid, "boss", ["userB"])
  assert_eq(g2_row_count(repo, "userB"), 1)
  repo.create_cc_instance(iid, "boss", ["userB"])
  repo.create_cc_instance(iid, "boss", ["userB", "userB"])
  assert_eq(g2_row_count(repo, "userB"), 1)
  assert_eq(repo.cc_instances.length(), 1)
  // 新入口第二轮：只抄老熟人 ⇒ 子集为空、行数纹丝不动
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["userB"])
  assert_eq(created.length(), 0)
  assert_eq(repo.cc_instances.length(), 1)
}

///|
/// ③ 不重置未读：已读（state=1）的人被再次抄送 ⇒ state 保持 1（重复抄送**不是**"再提醒一次"）
async test "i141-G2 内存仓 ②重复抄送不重置未读状态" {
  let (repo, iid) = g2_setup()
  let _ = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC"])
  repo.update_cc_status(iid, "userB")
  match g2_row(repo, "userB") {
    Some(r) => assert_eq(r.state, 1)
    None => g2_check(false, "userB 已读前置态已落")
  }
  // 重复抄 userB（混在新人 userC/userD 的请求里）⇒ 老熟人那一行不许被抹回未读
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC", "userD"])
  g2_check(created == ["userD"], "只有新人进子集（实际 \{g2_arr(created)}）")
  match g2_row(repo, "userB") {
    Some(r) => assert_eq(r.state, 1)
    None => g2_check(false, "userB 行仍在")
  }
  // 旧入口同样不许重置
  repo.create_cc_instance(iid, "boss", ["userB"])
  match g2_row(repo, "userB") {
    Some(r) => assert_eq(r.state, 1)
    None => g2_check(false, "userB 行仍在（旧入口）")
  }
}

///|
/// ④ 不更新原行时间：原行 create_time/update_time/id/create_user 逐字不变（判重＝整条跳过，不发 UPDATE）
async test "i141-G2 内存仓 ③重复抄送不更新原行时间与主键" {
  let (repo, iid) = g2_setup()
  let _ = repo.create_cc_instance_if_absent(iid, "boss", ["userB"])
  let ct = "2026-01-01 08:00:00"
  let ut = "2026-01-02 09:00:00"
  repo.cc_instances[0].create_time = Some(ct)
  repo.cc_instances[0].update_time = Some(ut)
  repo.cc_instances[0].create_user = Some("hr")
  let id_before = repo.cc_instances[0].id
  let _ = repo.create_cc_instance_if_absent(iid, "other_boss", ["userB"])
  repo.create_cc_instance(iid, "other_boss", ["userB", "userB"])
  assert_eq(repo.cc_instances.length(), 1)
  let r = repo.cc_instances[0]
  assert_eq(r.create_time, Some(ct))
  assert_eq(r.update_time, Some(ut))
  assert_eq(r.id, id_before)
  assert_eq(r.create_user, Some("hr"))
  g2_check(
    r.create_user != Some("other_boss"),
    "重复抄送不得把 create_user 覆写成第二次调用的操作人（实际 g2_opt(r.create_user)）",
  )
  // 同实例换新人 ⇒ 只追加一行，老行仍逐字不动
  let _ = repo.create_cc_instance_if_absent(iid, "boss2", ["userC"])
  assert_eq(repo.cc_instances.length(), 2)
  assert_eq(repo.cc_instances[0].create_time, Some(ct))
  assert_eq(repo.cc_instances[0].update_time, Some(ut))
}

///|
/// ⑤ 子集：第二次只抄新人 ⇒ 返回只含新人（事件面见 core/engine 与 facade 的格子）
async test "i141-G2 内存仓 第二次只抄新人⇒子集只含新人" {
  let (repo, iid) = g2_setup()
  let first = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC"])
  g2_check(first == ["userB", "userC"], "首轮全量进子集（实际 \{g2_arr(first)}）")
  let second = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC"])
  assert_eq(second.length(), 0)
  let third = repo.create_cc_instance_if_absent(iid, "boss", ["userC", "userD", "userE"])
  g2_check(third == ["userD", "userE"], "第二三轮只出新人且保序（实际 \{g2_arr(third)}）")
  assert_eq(repo.cc_instances.length(), 4)
  assert_eq(repo.find_cc_actors(iid).length(), 4)
}

///|
/// ⑥ 同一次调用内的重复也折叠：["userB","userB","userC"] ⇒ 两行、子集 ["userB","userC"]
async test "i141-G2 内存仓 同一次调用内重复折叠" {
  let (repo, iid) = g2_setup()
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userB", "userC", "userB"])
  g2_check(created == ["userB", "userC"], "同调用内重复折叠（实际 \{g2_arr(created)}）")
  assert_eq(repo.cc_instances.length(), 2)
  assert_eq(g2_row_count(repo, "userB"), 1)
  // 旧入口同样折叠
  let (repo2, iid2) = g2_setup()
  repo2.create_cc_instance(iid2, "boss", ["userB", "userB"])
  assert_eq(repo2.cc_instances.length(), 1)
}

///|
/// ⑦ 读侧不去重 / 历史重复行不清理：find_cc_actors 原样返回（含重复），
/// 且已有重复行时再来一次抄送既不"顺手清历史"也不因重复漏掉新人。
async test "i141-G2 内存仓 历史重复行不去重也不清理" {
  let (repo, iid) = g2_setup()
  // 直接造两行同人（模拟 G2 之前落下的历史重复行）
  repo.cc_instances.push({
    id: 9001L,
    process_instance_id: iid,
    actor_id: "userB",
    state: 0,
    create_time: None,
    create_user: Some("legacy"),
    update_time: None,
    update_user: None,
  })
  repo.cc_instances.push({
    id: 9002L,
    process_instance_id: iid,
    actor_id: "userB",
    state: 1,
    create_time: None,
    create_user: Some("legacy"),
    update_time: None,
    update_user: None,
  })
  let existing = repo.find_cc_actors(iid)
  g2_check(
    existing == ["userB", "userB"],
    "读侧原样返回不去重（查询侧不许加 DISTINCT；实际 \{g2_arr(existing)}）",
  )
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["userB", "userC"])
  g2_check(created == ["userC"], "已有行的人不再新建（实际 \{g2_arr(created)}）")
  assert_eq(g2_row_count(repo, "userB"), 2)
  assert_eq(g2_row_count(repo, "userC"), 1)
  // 历史重复行不清理：总行数 = 2（旧）+ 1（新）
  assert_eq(repo.cc_instances.length(), 3)
}

///|
/// ⑧ 判据单点：cc_fresh_subset 是两仓储共用的唯一一份（保序、已有跳过、同调用折叠、不改读侧集合）
test "i141-G2 判据单点 cc_fresh_subset 四档" {
  assert_eq(@model.cc_fresh_subset([], ["a", "b"]), ["a", "b"])
  assert_eq(@model.cc_fresh_subset(["a"], ["a", "b", "a"]), ["b"])
  assert_eq(@model.cc_fresh_subset(["a", "b"], ["b", "a"]), [])
  assert_eq(@model.cc_fresh_subset(["a"], ["a", "a", "a"]), [])
  assert_eq(@model.cc_fresh_subset([], []), [])
  let existing = ["a", "b"]
  let _ = @model.cc_fresh_subset(existing, ["b", "c"])
  assert_eq(existing, ["a", "b"])
}

///|
/// ⑨ 空请求 ⇒ 空子集零建行（三条入口"子集为空整支不发"的数据面前提）；
/// 判重键含实例：同一个人换实例仍算新建。
async test "i141-G2 内存仓 空请求⇒空子集零建行，判重键含实例" {
  let (repo, iid) = g2_setup()
  let created = repo.create_cc_instance_if_absent(iid, "boss", [])
  assert_eq(created.length(), 0)
  assert_eq(repo.cc_instances.length(), 0)
  assert_eq(repo.find_cc_actors(iid).length(), 0)
  let iid2 = g2_add_instance(repo, "boss")
  let _ = repo.create_cc_instance_if_absent(iid, "boss", ["userB"])
  let c2 = repo.create_cc_instance_if_absent(iid2, "boss", ["userB"])
  g2_check(c2 == ["userB"], "同一个人换实例仍算新建（判重键含实例；实际 \{g2_arr(c2)}）")
  assert_eq(repo.find_cc_actors(iid2), ["userB"])
  assert_eq(repo.find_cc_actors(iid), ["userB"])
}
