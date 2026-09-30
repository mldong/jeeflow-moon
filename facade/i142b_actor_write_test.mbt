// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一 · actor_id 与 task id」）——
// **门面写侧腿**（processTask/addCandidate + processTask/surrogate + processTask/transfer
// + 发起腿 f_nextNodeOperator 透传）的内存仓通道用例（T0）。
//
// 本栈普查改前实测（issues/142 §2 B 表 moon 行）：
// · `facade/args.mbt` 的 `arg_actor_ids` 数组臂是 `if !s.is_empty()` ⇒ **不 trim**：
//   `[" a "]` 与 `["a"]` 判成两个人、`["  "]` 原样进写侧建一行 actor_id="  "；只有逗号串臂才 trim
//   —— 同一枚参数两形两样，正是 §2.11「逗号串与数组两形没有一栈同判」的 moon 形状；
// · 同一把尺子在门面里长两副面孔：`create_cc_instance` 过 @model 归一，
//   `task_surrogate`（addCandidate/surrogate 同体）**不过**（§2.11 尾注「不要再抄第二份」）；
// · 主键档：`processTaskId` 传 `0` 时旧实现照落参与者行（§2.11 末段「不得拿 ''/0 当 id 落库」）。
//
// 判据（§2.11 四条，与 §2.10 同构）：① 两层都挡（门面腿 + 两仓写侧）② 落库与比较取 trim 后的值
// ③ 空入参档沿用既有错误信封与文案（`processTaskId/actorIds 缺失` / `非法id` / `fromActor 必填`），
// 不新造错误码或文案 ④ 反向哨兵 "0" 不得被丢掉，判空一律 trim()==""，严禁 falsy 判据。
//
// 复用同包 helper：setup / doing_task_for / targs / code_of / msg_of / data_of / parse_iid /
// linear_flow_json（withdraw_transfer_test.mbt）。

///|
fn i142f_arr(items : Array[String]) -> Json {
  @json.array_of(items.map(fn(a) { @json.string_of(a) }))
}

///|
/// addCandidate 跑一次（actorIds 形态由调用方给：数组 / 逗号串 / 缺键），返回信封 + 参与者读回值
async fn add_candidate(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  tid : Int64,
  actor_ids : Json
) -> (Json, Array[String]) raise {
  let args : Map[String, Json] = Map([])
  args["processTaskId"] = @json.string_of(tid.to_string())
  args["actorIds"] = actor_ids
  let env = facade.flow("processTask/addCandidate", args)
  (env, facade.repo.find_task_actors(tid))
}

///|
/// 任意主键形态的 addCandidate（⑦ 主键档用）
async fn add_candidate_raw(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  task_id_json : Json?,
  actor_ids : Json
) -> Json raise {
  let args : Map[String, Json] = Map([])
  match task_id_json {
    Some(v) => args["processTaskId"] = v
    None => ()
  }
  args["actorIds"] = actor_ids
  facade.flow("processTask/addCandidate", args)
}

///|
/// ① 数组臂必须与串臂同判据：trim + 丢空 + 同调用折叠
///    改前红：[" a ","a"] 判成两个人、["  "] 原样落一行 actor_id="  "
async test "i142-B addCandidate 数组形态 trim＋丢空＋折叠（与逗号串同判据）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let base = repo.find_task_actors(tid)
  assert_true(base == ["leader"])
  // 空白包裹值与干净值是同一个人 ⇒ 只多一行 "a"（改前判成两个人 ⇒ 两行）
  let (env_a, after_a) = add_candidate(facade, tid, i142f_arr([" a ", "a"]))
  assert_eq(msg_of(env_a), "成功")
  assert_true(after_a == ["leader", "a"])
  // 纯空白元素一个都不留（改前：["  "] 原样进写侧）
  let (_, after_b) = add_candidate(facade, tid, i142f_arr(["  ", "\t\n"]))
  assert_true(after_b == ["leader", "a"])
  // 混给只丢空、保序
  let (_, after_c) = add_candidate(facade, tid, i142f_arr(["b", "", "  ", " c "]))
  assert_true(after_c == ["leader", "a", "b", "c"])
}

///|
/// ② 两形同判据（§2.11 反面＝串腿 trim、数组腿照落）：同一批人两形必须同一读数
async test "i142-B addCandidate 逗号串与数组两形同判据（同输入同答案）" {
  let (facade_a, repo_a, iid_a) = setup(linear_flow_json())
  let tid_a = doing_task_for(repo_a, iid_a, "leader").task_id
  let (_, by_string) = add_candidate(facade_a, tid_a, @json.string_of("a,,  "))
  let (facade_b, repo_b, iid_b) = setup(linear_flow_json())
  let tid_b = doing_task_for(repo_b, iid_b, "leader").task_id
  let (_, by_array) = add_candidate(facade_b, tid_b, i142f_arr(["a", "", "  "]))
  assert_true(by_string == ["leader", "a"])
  assert_true(by_string == by_array)
}

///|
/// ③ 数组里的数字元素收敛成字符串（>2^53 走 repr 原文，不被 double 取整；D-M5-3 同一枚）；
///    Json null 元素丢弃（不许串化成 "null"——§2.11 点名的五栈病灶）
async test "i142-B addCandidate 数字元素收敛成字符串＋null 元素丢弃" {
  let (facade_a, repo_a, iid_a) = setup(linear_flow_json())
  let tid_a = doing_task_for(repo_a, iid_a, "leader").task_id
  let (_, by_num) = add_candidate(
    facade_a,
    tid_a,
    @json.array_of([@json.number_of(2L), @json.number_of(2086772715431137280L)]),
  )
  assert_true(by_num == ["leader", "2", "2086772715431137280"])
  let (facade_b, repo_b, iid_b) = setup(linear_flow_json())
  let tid_b = doing_task_for(repo_b, iid_b, "leader").task_id
  let (_, with_null) = add_candidate(
    facade_b,
    tid_b,
    @json.array_of([@json.string_of("x"), @json.null_json()]),
  )
  assert_true(with_null == ["leader", "x"])
}

///|
/// ④ 全空白六档 ⇒ 与既有"空集合"档同判（`processTaskId/actorIds 缺失` 文案与错误码一字不改、零副作用）
async test "i142-B addCandidate 全空白⇒与空集合同档（既有文案，零行）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let base = repo.find_task_actors(tid)
  let cases : Array[Json] = [
    @json.empty_array(),
    @json.string_of(""),
    @json.string_of("   "),
    i142f_arr([""]),
    i142f_arr(["  "]),
    @json.null_json(),
  ]
  for j in cases {
    let (env, after) = add_candidate(facade, tid, j)
    assert_eq(code_of(env), 99999999L)
    assert_eq(msg_of(env), "processTaskId/actorIds 缺失")
    assert_true(after == base)
  }
}

///|
/// ⑤ 反向哨兵："0" / "00" 是两个人 —— 数组与逗号串两形都照落，不得并进"空集合"档
async test "i142-B addCandidate 反向哨兵 \"0\"/\"00\" 照落（两个人，不得折叠）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let (env, after) = add_candidate(facade, tid, i142f_arr(["0", "", "00", "a"]))
  assert_eq(msg_of(env), "成功")
  assert_true(after == ["leader", "0", "00", "a"])
  // 空白包裹的 "0" 与 "0" 同人 ⇒ 写侧判重命中，不新增行
  let (_, after2) = add_candidate(facade, tid, i142f_arr([" 0 "]))
  assert_true(after2 == ["leader", "0", "00", "a"])
  let (facade3, repo3, iid3) = setup(linear_flow_json())
  let tid3 = doing_task_for(repo3, iid3, "leader").task_id
  let (_, after3) = add_candidate(facade3, tid3, @json.string_of("0,00"))
  assert_true(after3 == ["leader", "0", "00"])
}

///|
/// ⑥ processTask/surrogate 与 addCandidate 同体（同一支 task_surrogate）⇒ 判据必须同答案
async test "i142-B surrogate 与 addCandidate 同体同判据" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let args : Map[String, Json] = Map([])
  args["processTaskId"] = @json.string_of(tid.to_string())
  args["actorIds"] = i142f_arr([" a ", "a", "  "])
  let env = facade.flow("processTask/surrogate", args)
  assert_eq(msg_of(env), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader", "a"])
}

///|
/// ⑦ 主键另判一档（§2.11 末段）：processTaskId 缺失/空串/非正数一律响亮报错，
///    且不得拿 0 当 id 落参与者行；空串沿用既有"非法id"档，缺键沿用既有"缺失"档
async test "i142-B 主键档 缺失/空串/0 都响亮报错且零落库" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let (ok_env, ok_after) = add_candidate(facade, tid, i142f_arr(["pk"]))
  assert_eq(msg_of(ok_env), "成功")
  assert_true(ok_after == ["leader", "pk"])
  // 缺键
  let e_miss = add_candidate_raw(facade, None, i142f_arr(["pk2"]))
  assert_eq(code_of(e_miss), 99999999L)
  assert_eq(msg_of(e_miss), "processTaskId/actorIds 缺失")
  // 空串
  let e_blank = add_candidate_raw(facade, Some(@json.string_of("")), i142f_arr(["pk2"]))
  assert_eq(code_of(e_blank), 99999999L)
  assert_true(msg_of(e_blank).contains("非法id"))
  // 0 / 负数 ⇒ 不得当 id 落库
  let e_zero = add_candidate_raw(facade, Some(@json.string_of("0")), i142f_arr(["pk3"]))
  assert_eq(code_of(e_zero), 99999999L)
  let e_neg = add_candidate_raw(facade, Some(@json.string_of("-1")), i142f_arr(["pk3"]))
  assert_eq(code_of(e_neg), 99999999L)
  assert_true(repo.find_task_actors(0L).is_empty())
  assert_true(repo.find_task_actors(-1L).is_empty())
  // 正常路径不被顶坏（回归）
  assert_true(repo.find_task_actors(tid) == ["leader", "pk"])
}

///|
/// ⑧ transfer 的 fromActor/toActor 归一后再用：空白包裹值与干净值同判、账本与便捷键存 trim 后的值
async test "i142-B transfer from/to 归一后再用（trim 同判据＋账本落 trim 值）" {
  @model.set_clock(Some(fn() { "2026-09-30 08:20:54" }))
  defer { @model.set_clock(None) }
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let args : Map[String, Json] = Map([])
  args["processTaskId"] = @json.string_of(tid.to_string())
  args["operator"] = @json.string_of(" leader ")
  args["fromActor"] = @json.string_of(" leader ")
  args["toActor"] = @json.string_of(" lisi ")
  args["reason"] = @json.string_of(" 出差 ")
  let env = facade.flow("processTask/transfer", args)
  assert_eq(msg_of(env), "成功")
  // 参与者表：摘的是 trim 后的 leader、加的是 trim 后的 lisi
  assert_true(repo.find_task_actors(tid) == ["lisi"])
  let back = repo.find_task_by_id(tid).unwrap()
  assert_eq(var_field(back, "tf_transferTo"), "lisi")
  let h = history_of(back)
  assert_eq(h.length(), 1)
  assert_eq(hop_field(h[0], "fromActor"), "leader")
  assert_eq(hop_field(h[0], "toActor"), "lisi")
  assert_eq(hop_field(h[0], "operator"), "leader")
}

///|
/// ⑨ transfer 反向哨兵：toActor="0" 是正常人；纯空白 from/to 沿用既有"必填"档文案且零副作用
async test "i142-B transfer 反向哨兵 \"0\" 照转＋空白档沿用既有必填文案" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let ok_args : Map[String, Json] = Map([])
  ok_args["processTaskId"] = @json.string_of(tid.to_string())
  ok_args["operator"] = @json.string_of("leader")
  ok_args["fromActor"] = @json.string_of("leader")
  ok_args["toActor"] = @json.string_of("0")
  let ok = facade.flow("processTask/transfer", ok_args)
  assert_eq(msg_of(ok), "成功")
  assert_true(repo.find_task_actors(tid) == ["0"])
  let blank_to : Map[String, Json] = Map([])
  blank_to["processTaskId"] = @json.string_of(tid.to_string())
  blank_to["operator"] = @json.string_of("0")
  blank_to["fromActor"] = @json.string_of("0")
  blank_to["toActor"] = @json.string_of("   ")
  let e_to = facade.flow("processTask/transfer", blank_to)
  assert_eq(code_of(e_to), 99999999L)
  assert_eq(msg_of(e_to), "toActor 必填")
  let blank_from : Map[String, Json] = Map([])
  blank_from["processTaskId"] = @json.string_of(tid.to_string())
  blank_from["operator"] = @json.string_of("0")
  blank_from["fromActor"] = @json.string_of("\t")
  blank_from["toActor"] = @json.string_of("lisi")
  let e_from = facade.flow("processTask/transfer", blank_from)
  assert_eq(msg_of(e_from), "fromActor 必填")
  assert_true(repo.find_task_actors(tid) == ["0"])
}

///|
/// ⑩ 门面发起腿 f_nextNodeOperator 数组形态经 startAndExecute 透传后必须生效
///    （改前红：消费腿只认逗号串 ⇒ 数组整条失效，task1 参与者落回节点自己的 leader）
async test "i142-B 门面发起腿 f_nextNodeOperator 数组形态生效" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let facade = @facade.Facade::make(ctx.with_id_generator(fn() { gen.next_id() }))
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i142b-start",
    display_name: "i142b 发起腿",
    define_type: "approval",
    state: 1,
    content: linear_flow_json(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let args : Map[String, Json] = Map([])
  args["processDefineId"] = @json.string_of(define_info.id.to_string())
  args["operator"] = @json.string_of("applicant")
  args["f_nextNodeOperator"] = i142f_arr([" zhang ", "lisi", ""])
  let env = facade.flow("processInstance/startAndExecute", args)
  assert_eq(msg_of(env), "成功")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  let mut got : Array[String] = []
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == "task1" {
      got = repo.find_task_actors(t.task_id)
    }
  }
  assert_true(got == ["zhang", "lisi"])
}
