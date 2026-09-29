// issues/141 G10 · 空抄送人不建 cc 行 —— **门面手动腿**（processInstance/createCCInstance）档（T0）。
//
// 判据（spec 06-facade §2.10 四点，基准＝java `5fbd5ac`）：手动腿与两条引擎腿走同一支归一
// （@model.normalize_cc_actors）—— 空串/纯空白/数组里的空元素一律丢弃，落库与比较取 trim 后的值。
//
// 本栈普查改前实测（手动腿只靠 arg_actor_ids 的逗号串腿 trim）：
// `["  "]` ⇒ 建一行 actor_id="  " + fire 一个码 4；`[" a "]` ⇒ 落成与 "a" 不同的"两个人"；
// `[" userB ","userB"]` ⇒ 同一人落两行、fire 两次（把 issues/141 G2 的写侧判重打穿）。
// `""`／`"   "`／`[""]` 三档本来就走"空集合 ⇒ actorIds 缺失"，本轮把数组形态的空白档也并进同一档
// （**沿用既有文案与错误码，不新造错误语义**，spec §2.10 要求③）。
//
// 复用同包 helper：listening_setup / linear_flow_json（events_leg_test.mbt）、targs / code_of /
// msg_of（withdraw_transfer_test.mbt）、cc_created_actors（i141_g1_g2_cc_facade_test.mbt）。

///|
fn g10f_arr(items : Array[String]) -> Json {
  @json.array_of(items.map(fn(a) { @json.string_of(a) }))
}

///|
/// 手动腿跑一次（actorIds 形态由调用方给：逗号串或数组或缺键）
async fn g10f_manual(actor_ids : Json) -> (
  @mem.MemoryRepository,
  Json,
  Array[String],
  Array[String],
) raise {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let args : Map[String, Json] = Map([])
  args["processInstanceId"] = @json.string_of(iid.to_string())
  args["operator"] = @json.string_of("applicant")
  args["actorIds"] = actor_ids
  let env = facade.flow("processInstance/createCCInstance", args)
  (repo, env, repo.cc_instances.map(fn(c) { c.actor_id }), cc_created_actors(events))
}

///|
/// ① 全空白四档 ⇒ 与"空集合"同判（既有 `actorIds 缺失` 档：错误码/文案一字不改，零行零 fire）
async test "i141-G10 手动腿 全空白⇒与空集合同档（actorIds 缺失、零行零 fire）" {
  let cases : Array[(String, Json)] = [
    ("空串", @json.string_of("")),
    ("纯空白串", @json.string_of("   ")),
    ("数组含空元素", g10f_arr([""])),
    ("数组含纯空白元素", g10f_arr(["  "])),
    ("数组混合空与空白", g10f_arr(["", "  ", "\t\n"])),
    ("空数组", @json.empty_array()),
  ]
  // 基准档：actorIds 键整个缺失时的既有答案
  let (_, base_env, base_rows, base_fired) = g10f_manual(@json.null_json())
  assert_eq(msg_of(base_env), "actorIds 缺失")
  assert_eq(base_rows, [])
  assert_eq(base_fired, [])
  for c in cases {
    let (label, j) = c
    let (repo, env, rows, fired) = g10f_manual(j)
    assert_eq(msg_of(env), msg_of(base_env), msg="空白档与空集合同文案（档：" + label + "）")
    assert_eq(code_of(env), code_of(base_env))
    assert_eq(rows, [])
    assert_eq(fired, [])
    assert_eq(repo.cc_instances.length(), 0)
  }
}

///|
/// ② 混给只丢空（逗号串空元素档 + 数组含空元素档，两形态同判据）
async test "i141-G10 手动腿 混给只丢空：逗号串与数组两形态同判据" {
  let (_, env_a, rows_a, fired_a) = g10f_manual(@json.string_of("a,,b"))
  assert_eq(msg_of(env_a), "成功")
  assert_eq(rows_a, ["a", "b"])
  assert_eq(fired_a, ["a", "b"])
  let (_, env_b, rows_b, fired_b) = g10f_manual(g10f_arr(["a", "", "  ", "b"]))
  assert_eq(msg_of(env_b), "成功")
  assert_eq(rows_b, ["a", "b"])
  assert_eq(fired_b, ["a", "b"])
  // 尾随逗号
  let (_, _, rows_c, fired_c) = g10f_manual(@json.string_of("a,"))
  assert_eq(rows_c, ["a"])
  assert_eq(fired_c, ["a"])
}

///|
/// ③ 落库与比较取 trim 后的值：手动腿同人只许一行、fire 里也是 trim 后的串
async test "i141-G10 手动腿 trim 后同值⇒一行一 fire（G2 咬合点）" {
  let (_, env, rows, fired) = g10f_manual(g10f_arr([" userB ", "userB", "\tuserB\n"]))
  assert_eq(msg_of(env), "成功")
  assert_eq(rows, ["userB"])
  assert_eq(fired, ["userB"])
  // 跨请求：先干净值，再空白包裹值 ⇒ 第二次判重命中，不新增行、不 fire，仍是成功信封
  let (repo, _, _, _) = g10f_manual(@json.string_of("userB"))
  assert_eq(repo.cc_instances.map(fn(c) { c.actor_id }), ["userB"])
}

///|
/// 手动腿入参（④ 那格要连发两次请求，共用一份参数装配）
fn g10f_args(iid : Int64, actor_ids : Json) -> Map[String, Json] {
  let args : Map[String, Json] = Map([])
  args["processInstanceId"] = @json.string_of(iid.to_string())
  args["operator"] = @json.string_of("applicant")
  args["actorIds"] = actor_ids
  args
}

///|
/// ④ 跨请求命中 G2 写侧判重（手动腿两次）：第二次只许 fire 新人
async test "i141-G10 手动腿 第二次混新老⇒只 fire 新人（空白包裹值算同人）" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let first = facade.flow("processInstance/createCCInstance", g10f_args(iid, g10f_arr(["userB", ""])))
  assert_eq(msg_of(first), "成功")
  assert_eq(repo.cc_instances.map(fn(c) { c.actor_id }), ["userB"])
  let second = facade.flow("processInstance/createCCInstance", g10f_args(iid, g10f_arr([" userB ", "userC"])))
  assert_eq(msg_of(second), "成功")
  assert_eq(repo.cc_instances.map(fn(c) { c.actor_id }), ["userB", "userC"])
  assert_eq(cc_created_actors(events), ["userB", "userC"])
}

///|
/// ⑤ 反向哨兵："0" 是正常 id —— 逗号串与数组两形态都照建照 fire（不得并进"空集合"档）
async test "i141-G10 手动腿 反向哨兵 \"0\" 照建照 fire（两形态）" {
  let (_, env_a, rows_a, fired_a) = g10f_manual(@json.string_of("0"))
  assert_eq(msg_of(env_a), "成功")
  assert_eq(rows_a, ["0"])
  assert_eq(fired_a, ["0"])
  let (_, env_b, rows_b, fired_b) = g10f_manual(g10f_arr(["0", "", "1"]))
  assert_eq(msg_of(env_b), "成功")
  assert_eq(rows_b, ["0", "1"])
  assert_eq(fired_b, ["0", "1"])
}

///|
/// ⑥ 正向对照（判据不误伤首次）：两个正常人 ⇒ 两行两码 4，顺序与入参一致
async test "i141-G10 手动腿 正向对照：两正常人两行两码4" {
  let (_, env, rows, fired) = g10f_manual(g10f_arr(["userB", "userC"]))
  assert_eq(msg_of(env), "成功")
  assert_eq(rows, ["userB", "userC"])
  assert_eq(fired, ["userB", "userC"])
}
