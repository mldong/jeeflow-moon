// issues/141 G10 · 空抄送人不建 cc 行 —— **引擎腿 + 漏斗**行为档（T0，内存仓通道）。
//
// 裁定（owner 2026-09-29 · spec 06-facade §2.10）：三条入口（发起 f_ccActors／办理 tf_ccActors／
// 门面手动 createCCInstance）解析抄送人集合时，**空串、纯空白、数组里的空元素一律丢弃**；
// 丢完为空 ⇒ 不建任何 cc 行、也不 fire CC_CREATE（码 4）。基准＝java `5fbd5ac`。
//
// 本栈病灶（普查实测，改前读数）：漏斗的**数组腿只丢 `""`、不 trim** ⇒ `["  "]` 原样进写侧、
// 真落一条 actor_id="  " 的行并 fire 一个码 4；`[" a "]` 落成与 "a" 不同的"两个人"，把 issues/141 G2
// 的写侧判重（b4b6ade 的 create_cc_instance_if_absent / cc_fresh_subset）直接打穿。逗号串腿本来
// 就 trim+丢空段，两形态不同判据正是本条要收口的地方。
//
// 判据单点：@model.normalize_cc_actors（core/model/rows.mbt）——漏斗、门面手动腿、两仓储写侧都调它。
// 本格还钉反向哨兵："0" 这类"看起来像空"的正常 id 不得被丢掉（判据是 trim 后 is_empty，不是 falsy）。
//
// 复用同包 helper：simple_flow_json / save_flow_define / new_args（compliance_test.mbt）、
// cc_fired_actors / cc_rows_of（cc_actors_shape_test.mbt）、g2e_setup（i141_g2_cc_fire_test.mbt）。

///|
/// 仓储里 cc 行的 actor_id 序（落库真相，含空白化差异这类"判成两个人"的形状问题）
fn g10e_ccvals(repo : @mem.MemoryRepository) -> Array[String] {
  repo.cc_instances.map(fn(c) { c.actor_id })
}

///|
fn g10e_arr(items : Array[String]) -> Json {
  @json.array_of(items.map(fn(a) { @json.string_of(a) }))
}

///|
/// 发起腿跑一次抄送（cc 形态由调用方给：逗号串或数组）
async fn g10e_start_leg(
  cc : Json
) -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
  Int64,
  Array[@event.ProcessEvent],
) raise {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g10e-start", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", cc)
  let inst = engine.start_async(did, "user1", args)
  (engine, repo, inst.instance_id, events)
}

///|
/// 办理腿跑一次抄送（tf_ccActors）
async fn g10e_task_leg(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  iid : Int64,
  cc : Json
) -> Unit raise {
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  let args = new_args()
  args.insert("tf_ccActors", cc)
  let _ = engine.execute_task_async(tasks[0].task_id, "user1", args)
}

///|
/// ① 漏斗逐档（直调 parse_cc_actors ⇒ 这一层单独可观测：只还原漏斗时这几格必红，
/// 不会被写侧兜底掩盖成"行面看不出问题"）：空串/纯空白/空元素全丢，值取 trim 后的串，
/// 逗号串与数组两形态同判据。
test "i141-G10 漏斗 逐档：空串/纯空白/数组空元素丢弃 + 两形态同判据 + trim" {
  // 逗号串腿（改前就合规，留作正向钉）
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of(""))), [])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("   "))), [])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("a,,b"))), ["a", "b"])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("a,"))), ["a"])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of(" a "))), ["a"])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("\t\n"))), [])
  // 数组腿（改前病灶：只丢 ""、不 trim ⇒ ["  "] 原样过、[" a "] 与 "a" 判成两个人）
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr(["a", "", "  "]))), ["a"])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr([""]))), [])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr(["  "]))), [])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr([" a "]))), ["a"])
  // 两形态同判据：同一批人不论哪形态，归一结果逐字相同
  assert_eq(
    @engine.parse_cc_actors(Some(@json.string_of("a,,  "))),
    @engine.parse_cc_actors(Some(g10e_arr(["a", "", "  "]))),
  )
  // 同一次调用内的重复折叠（trim 后同值即同人）
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("a, a"))), ["a"])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr([" a ", "a"]))), ["a"])
  // 缺值/非串非数组档仍为空（回归：既有 c30 口径不动）
  assert_eq(@engine.parse_cc_actors(None), [])
  assert_eq(@engine.parse_cc_actors(Some(@json.empty_array())), [])
  assert_eq(@engine.parse_cc_actors(Some(@json.null_json())), [])
}

///|
/// ② 漏斗反向哨兵："0"／数字 0／"false" 这类"看起来像空"的正常值**不得**被当空值丢掉。
test "i141-G10 漏斗 反向哨兵：\"0\" 与数字 0 不被判成空值" {
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("0"))), ["0"])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr(["0"]))), ["0"])
  assert_eq(@engine.parse_cc_actors(Some(@json.array_of([@json.number_of(0L)]))), ["0"])
  assert_eq(@engine.parse_cc_actors(Some(@json.string_of("0,0"))), ["0"])
  assert_eq(@engine.parse_cc_actors(Some(g10e_arr(["0", "", "1"]))), ["0", "1"])
}

///|
/// ③ 发起腿：全空白四档 ⇒ 零行 + 零 fire（逗号串与数组同判据；spec §11.2 原则 1「码=事实」）
async test "i141-G10 发起腿 全空白⇒零行零 fire（两形态同判据）" {
  let cases : Array[Json] = [
    @json.string_of(""),
    @json.string_of("   "),
    g10e_arr([""]),
    g10e_arr(["  "]),
    g10e_arr(["", "  "]),
    @json.empty_array(),
  ]
  for cc in cases {
    let (_, repo, _, events) = g10e_start_leg(cc)
    assert_eq(cc_rows_of(repo), 0L)
    assert_eq(g10e_ccvals(repo), [])
    assert_eq(cc_fired_actors(events).length(), 0)
  }
}

///|
/// ④ 发起腿：混给只丢空 —— 逗号串空元素档与数组含空元素档
async test "i141-G10 发起腿 混给只丢空：逗号串空元素 + 数组含空元素" {
  let (_, repo_a, iid_a, events_a) = g10e_start_leg(@json.string_of("a,,b"))
  assert_eq(cc_rows_of(repo_a), 2L)
  assert_eq(g10e_ccvals(repo_a), ["a", "b"])
  assert_eq(cc_fired_actors(events_a), ["a", "b"])
  assert_eq(repo_a.find_cc_actors(iid_a), ["a", "b"])
  // 数组形态同一批人（含一个空元素 + 一个纯空白元素）⇒ 与逗号串档逐字同判
  let (_, repo_b, _, events_b) = g10e_start_leg(g10e_arr(["a", "", "b", "  "]))
  assert_eq(cc_rows_of(repo_b), 2L)
  assert_eq(g10e_ccvals(repo_b), ["a", "b"])
  assert_eq(cc_fired_actors(events_b), ["a", "b"])
}

///|
/// ⑤ 办理腿（tf_ccActors，issues/141 G6 与发起腿同器）：纯空白⇒零行零 fire；混给只丢空；尾随逗号
/// 每档一份新实例——simple_flow 办理一次即办结，同一实例不能连跑两条腿。
async test "i141-G10 办理腿 纯空白零行零 fire + 混给只丢空 + 尾随逗号" {
  // a) 逗号串纯空白
  let (e_a, r_a, iid_a, ev_a) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_a, r_a, iid_a, @json.string_of("   "))
  assert_eq(cc_rows_of(r_a), 0L)
  assert_eq(cc_fired_actors(ev_a).length(), 0)
  // b) 数组纯空白 + 只含空元素（改前 ["  "] 会真落一行 actor_id="  " 并 fire 一个码 4）
  let (e_b, r_b, iid_b, ev_b) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_b, r_b, iid_b, g10e_arr(["  "]))
  assert_eq(cc_rows_of(r_b), 0L)
  assert_eq(cc_fired_actors(ev_b).length(), 0)
  let (e_b2, r_b2, iid_b2, ev_b2) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_b2, r_b2, iid_b2, g10e_arr([""]))
  assert_eq(cc_rows_of(r_b2), 0L)
  assert_eq(cc_fired_actors(ev_b2).length(), 0)
  // c) 只有一个逗号 ⇒ 两形态都归一到零元素
  let (e_c, r_c, iid_c, ev_c) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_c, r_c, iid_c, @json.string_of(","))
  assert_eq(cc_rows_of(r_c), 0L)
  assert_eq(cc_fired_actors(ev_c).length(), 0)
  // d) 混给只丢空（数组含空元素 + 纯空白元素）
  let (e_d, r_d, iid_d, ev_d) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_d, r_d, iid_d, g10e_arr(["userB", "", "  ", "userC"]))
  assert_eq(cc_rows_of(r_d), 2L)
  assert_eq(g10e_ccvals(r_d), ["userB", "userC"])
  assert_eq(cc_fired_actors(ev_d), ["userB", "userC"])
  // e) 尾随逗号（逗号串腿）
  let (e_f, r_f, iid_f, ev_f) = g10e_start_leg(@json.empty_array())
  let _ = g10e_task_leg(e_f, r_f, iid_f, @json.string_of("userD,"))
  assert_eq(cc_rows_of(r_f), 1L)
  assert_eq(g10e_ccvals(r_f), ["userD"])
  assert_eq(cc_fired_actors(ev_f), ["userD"])
  // f) 发起腿尾随逗号 + 空段混给（与办理腿同判据）
  let (_, r_g, _, ev_g) = g10e_start_leg(@json.string_of("userE,,  "))
  assert_eq(cc_rows_of(r_g), 1L)
  assert_eq(g10e_ccvals(r_g), ["userE"])
  assert_eq(cc_fired_actors(ev_g), ["userE"])
}

///|
/// ⑥ 子流程发起腿（第三处建行点，start_with_parent_async）：空值同样零行零 fire
async test "i141-G10 子流程发起腿 空值⇒零行零 fire（三处建行点同判据）" {
  let (engine, repo, events) = g2e_setup()
  let did = save_flow_define(repo, "g10e-sub", simple_flow_json())
  let args = new_args()
  args.insert("f_ccActors", g10e_arr(["", "  "]))
  let _ = engine.start_with_parent_async(did, "user1", args, 555L, "sub1")
  assert_eq(cc_rows_of(repo), 0L)
  assert_eq(cc_fired_actors(events).length(), 0)
  // 同一条腿给正常值必须照常建行（哨兵：不许把这一支做成"一律不建"）
  let (engine2, repo2, events2) = g2e_setup()
  let did2 = save_flow_define(repo2, "g10e-sub-ok", simple_flow_json())
  let args2 = new_args()
  args2.insert("f_ccActors", g10e_arr(["  userE  ", "0"]))
  let _ = engine2.start_with_parent_async(did2, "user1", args2, 556L, "sub2")
  assert_eq(cc_rows_of(repo2), 2L)
  assert_eq(g10e_ccvals(repo2), ["userE", "0"])
  assert_eq(cc_fired_actors(events2), ["userE", "0"])
}

///|
/// ⑦ trim 后的同值命中 G2 写侧判重（G2 与 G10 的咬合点，不 trim 就把判重打穿）：
/// 发起腿给 [" a "]、办理腿给 "a" ⇒ 同一人，只许一行、只许 fire 一次。
async test "i141-G10 trim 后同值命中写侧判重（跨入口不许因空白化落两行）" {
  let (engine, repo, iid, events) = g10e_start_leg(g10e_arr([" a "]))
  assert_eq(cc_rows_of(repo), 1L)
  assert_eq(g10e_ccvals(repo), ["a"])
  assert_eq(cc_fired_actors(events), ["a"])
  let _ = g10e_task_leg(engine, repo, iid, @json.string_of("a"))
  assert_eq(cc_rows_of(repo), 1L)
  assert_eq(cc_fired_actors(events).length(), 1)
  assert_eq(repo.find_cc_actors(iid), ["a"])
  // 反过来的顺序同样只一行（先 "a" 后 [" a "]）
  let (engine2, repo2, iid2, events2) = g10e_start_leg(@json.string_of("a"))
  let _ = g10e_task_leg(engine2, repo2, iid2, g10e_arr([" a ", "  a  "]))
  assert_eq(cc_rows_of(repo2), 1L)
  assert_eq(cc_fired_actors(events2).length(), 1)
  assert_eq(repo2.find_cc_actors(iid2), ["a"])
}

///|
/// ⑧ 落库值与 fire 事件的 cc_actor_id 都取 trim 后的串（不是原始空白包裹值）
async test "i141-G10 落库与 fire 的值都是 trim 后的串" {
  let (_, repo, iid, events) = g10e_start_leg(g10e_arr(["  userB  ", "\tuserC\n"]))
  assert_eq(g10e_ccvals(repo), ["userB", "userC"])
  assert_eq(repo.find_cc_actors(iid), ["userB", "userC"])
  assert_eq(cc_fired_actors(events), ["userB", "userC"])
}

///|
/// ⑨ 正向对照（判据不许误伤首次）＋ 反向哨兵端到端："0" 是正常 id，照建照 fire
async test "i141-G10 正向对照两正常人 + 哨兵 \"0\" 端到端照建照 fire" {
  let (_, repo, _, events) = g10e_start_leg(g10e_arr(["userB", "userC"]))
  assert_eq(cc_rows_of(repo), 2L)
  assert_eq(cc_fired_actors(events), ["userB", "userC"])
  let (engine2, repo2, iid2, events2) = g10e_start_leg(@json.string_of("0, 0 "))
  assert_eq(cc_rows_of(repo2), 1L)
  assert_eq(repo2.find_cc_actors(iid2), ["0"])
  assert_eq(cc_fired_actors(events2), ["0"])
  // 哨兵与真人混给：只丢空，不丢 "0"
  let _ = g10e_task_leg(engine2, repo2, iid2, g10e_arr(["", "0", "userD"]))
  assert_eq(cc_rows_of(repo2), 2L)
  assert_eq(cc_fired_actors(events2), ["0", "userD"])
}
