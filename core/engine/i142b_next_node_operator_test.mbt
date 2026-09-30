// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一 · actor_id 与 task id」）——
// **消费腿** `tf_nextNodeOperator` 的数组形态档（内存仓通道，黑盒 async test）。
//
// 普查实读（issues/142 §2 B 表 moon 行）：`core/engine/engine.mbt` 的 `resolve_assignee` 第一腿
// 用 `exec.args.get_str("tf_nextNodeOperator")` ⇒ **只认逗号串，数组形态整条失效**：发起人用数组
// 指派下一节点参与者时，本栈一条都不认，静默落回节点自己的 assignee。别栈（java `toStringList`、
// py `_to_str_list`、node `toStringList2`、go `toStringSlice2`、rs `arg_actor_ids`）数组都是收的，
// 只是各自不 trim／不丢空／把 null 串化成 "null"/"None"/"<nil>"。
//
// 本批按 §2.11 收口：两形同判据 + 复用已落地的那一枚单点——形状适配走 `@engine.parse_cc_actors`
// 的同源支（issues/141 G10 已落地的漏斗），判据走 `@model.normalize_cc_actors`（不抄第二份）。
// 数字元素按别栈形状收敛成字符串（repr 原文优先，>2^53 不取整，见 D-M5-3），不得静默丢弃。
//
// 夹具是 flows/02-multi-task（apply→task1→task2→task3）：task1 的节点 assignee 是 "leader"，
// 所以"nextNodeOperator 没被认"这一族缺陷在读数上就是"参与者变成 leader"，不会与"零参与者"混淆。
// 断言一律落仓储读回值（find_task_actors），不认聚合副本。
//
// 复用同包 helper：make_compliance_engine / save_flow_define / load_flow / new_args（compliance_test.mbt）。

///|
/// task1 的参与者读回值（找不到 task1 的 DOING 行 ⇒ None，让调用方把"没建行"与"参与者为空"分开红）
async fn task1_actors_of(repo : @mem.MemoryRepository, iid : Int64) -> Array[String]? raise {
  let mut out : Array[String]? = None
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == "task1" {
      out = Some(repo.find_task_actors(t.task_id))
    }
  }
  out
}

///|
/// 发起 → 办 apply 时带上一个形态的 tf_nextNodeOperator → 读回下一节点 task1 的参与者
async fn apply_with_next_op(label : String, next_op : Json) -> Array[String] raise {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "i142b-\{label}", load_flow("02-multi-task"))
  let inst = engine.start_async(did, "applicant", new_args())
  let apply = find_doing_for(repo, inst.instance_id, "applicant")
  let args = new_args()
  args.insert("tf_nextNodeOperator", next_op)
  let _ = engine.execute_task_async(apply.task_id, "applicant", args)
  match task1_actors_of(repo, inst.instance_id) {
    Some(a) => a
    // task1 没建出来 = 另一件事，必须显式红，不许被读成"参与者数组为空"
    None => fail("task1 未建出 DOING 行（\{label}）")
  }
}

///|
fn i142b_arr(items : Array[String]) -> Json {
  @json.array_of(items.map(fn(a) { @json.string_of(a) }))
}

///|
/// ① 数组两元素（含包裹空白与空元素）⇒ 必须认（改前红：整条失效 ⇒ ["leader"]）
async test "i142-B 消费腿 数组形态照认：[zhang,空,  lisi ]⇒[zhang,lisi]" {
  let got = apply_with_next_op("arr-two", i142b_arr(["zhang", "", "  lisi "]))
  assert_true(got == ["zhang", "lisi"])
}

///|
/// ② 两形同判据：同一批人，逗号串与数组必须同一个答案（改前红：数组档失效 ⇒ 两形不同）
async test "i142-B 消费腿 逗号串与数组两形等价（同判据）" {
  let by_string = apply_with_next_op("eq-string", @json.string_of(" zhang , lisi "))
  let by_array = apply_with_next_op("eq-array", i142b_arr(["zhang", "lisi"]))
  assert_true(by_string == ["zhang", "lisi"])
  assert_true(by_string == by_array)
}

///|
/// ③ 同次调用折叠 + trim 后的值才进参与者表（"a" 与 " a " 是同一个人）
async test "i142-B 消费腿 同人空白化折叠成一行" {
  let got = apply_with_next_op("fold", i142b_arr([" a ", "a", "\ta\n"]))
  assert_true(got == ["a"])
}

///|
/// ④ 数字元素收敛成字符串（别栈同形状；repr 原文优先 ⇒ 雪花 id 不被 double 取整）
///    改前红：数组形态整条失效 ⇒ ["leader"]；rust 的另一条腿是"数字元素静默丢弃"，也不许照抄
async test "i142-B 消费腿 数字元素收敛成字符串（含 >2^53 精度）" {
  let got = apply_with_next_op(
    "num",
    @json.array_of([
      @json.number_of(2L),
      @json.number_of(2086772715431137280L),
      @json.number_of(0L),
    ]),
  )
  assert_true(got == ["2", "2086772715431137280", "0"])
}

///|
/// ⑤ 反向哨兵："0" 是正常人 —— 数组形态下不得被当空值丢掉（改前红：整条失效 ⇒ ["leader"]）
async test "i142-B 消费腿 反向哨兵 \"0\" 照认（数组形态）" {
  let got = apply_with_next_op("zero", i142b_arr(["0", "", "1"]))
  assert_true(got == ["0", "1"])
}

///|
/// ⑥ 空档回落不改判：数组全空 ⇒ 与逗号串全空同档，落回节点自己的 assignee（不是零参与者行，
///    也不是"空值进 actor_id"）。spec/02 §6.1 分型判据：任务类零参与者照样建单，但这一格
///    的"零"来自 nextNodeOperator 未指派，assignee 腿本来就有 leader。
async test "i142-B 消费腿 全空数组⇒回落 assignee（既不放空值也不建零参与者行）" {
  let by_array = apply_with_next_op("blank-array", i142b_arr(["", "  ", "\t\n"]))
  let by_string = apply_with_next_op("blank-string", @json.string_of(" , ,, "))
  let absent = apply_with_next_op("absent", @json.null_json())
  assert_true(by_array == ["leader"])
  assert_true(by_string == ["leader"])
  assert_true(absent == ["leader"])
}

///|
/// ⑦ 形状适配器档位（`parse_actors`＝issues/141 G10 为抄送腿落地的那一枚漏斗，§2.11 升格为通用名）：
/// 逗号串与数组两形必须同判据，数字元素按别栈形状收敛成字符串（不静默丢弃、不串化成类型名）。
test "i142-B parse_actors 两形同判据＋数字/布尔收敛＋null 丢弃" {
  assert_eq(@engine.parse_actors(None), [])
  assert_eq(@engine.parse_actors(Some(@json.null_json())), [])
  assert_eq(@engine.parse_actors(Some(@json.empty_array())), [])
  assert_eq(@engine.parse_actors(Some(@json.string_of(""))), [])
  assert_eq(@engine.parse_actors(Some(@json.string_of("  "))), [])
  assert_eq(@engine.parse_actors(Some(@json.string_of(" , ,, "))), [])
  assert_eq(@engine.parse_actors(Some(@json.string_of("a,,  "))), ["a"])
  assert_eq(@engine.parse_actors(Some(@json.string_of(" a , a "))), ["a"])
  assert_eq(@engine.parse_actors(Some(i142b_arr(["", "  ", "\t\n"]))), [])
  assert_eq(@engine.parse_actors(Some(i142b_arr([" a ", "a", ""]))), ["a"])
  // 数字元素：repr 原文优先（>2^53 不取整，D-M5-3），与 rust 那腿"数字静默丢弃"分道
  let nums = @json.array_of([@json.number_of(2086772715431137280L), @json.number_of(2L)])
  assert_eq(@engine.parse_actors(Some(nums)), ["2086772715431137280", "2"])
  // 布尔元素收敛成 "true"/"false"（不静默丢弃）
  let bools = @json.array_of([@json.bool_of(true), @json.bool_of(false)])
  assert_eq(@engine.parse_actors(Some(bools)), ["true", "false"])
  // null 元素丢弃（本栈 Json 无 undefined 档）—— 不许串化成 "null"
  let with_null =
    @json.array_of([@json.string_of("0"), @json.null_json(), @json.string_of("00")])
  assert_eq(@engine.parse_actors(Some(with_null)), ["0", "00"])
  // 两形等价：同一批人，逗号串与数组必须同一个答案
  assert_eq(
    @engine.parse_actors(Some(@json.string_of("a,,  "))),
    @engine.parse_actors(Some(i142b_arr(["a", "", "  "]))),
  )
  // 反向哨兵 "0"：两形都不得被当空值丢掉
  assert_eq(@engine.parse_actors(Some(@json.string_of("0"))), ["0"])
  assert_eq(@engine.parse_actors(Some(i142b_arr(["0"]))), ["0"])
  // 旧名 parse_cc_actors＝转发：抄送腿与本腿读的是同一枚，不存在第二份判据
  assert_eq(
    @engine.parse_cc_actors(Some(i142b_arr([" a ", "a", ""]))),
    @engine.parse_actors(Some(i142b_arr([" a ", "a", ""]))),
  )
}
