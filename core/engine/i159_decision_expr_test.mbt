// issues/159 · spec 06 §4.6 义务 2 第三条 ⚠（issues/158 立法）的引擎级判据：
// 「内置求值器不得靠不代入变量蒙方向」——`amount > 1000` 若不代入 amount，字符串字典序
// 对 `>` 与 `<=` 会同时判真；「关系运算（> >= < <=）要求两侧都是数字，非数字操作数判 false」。
//
// 修前三处违反（全部现读 engine.mbt）：
// · resolve_var_refs 只认 ${var}/#var，裸名原样进比较（§5.2.1-a）；
// · compare_values 非数字走字符串字典序兜底，漏进排序运算（§5.2.1-b）；
// · `>` 臂判 Some(2)、`<=` 臂"非 Some(2) 即 true"，而 compare_values 只产 Some(-1/0/1)
//   ⇒ `>` 恒 false、`<=` 恒 true（§5.2.1-c；0.1.35 的 i153 夹具只用 ==/!= 恰好绕开，故漏网）。
//
// 判据网格（value 形态覆盖 runner 夹具的数字发起档与字符串档两形）。

///|
/// 空 flow 的 Execution 载体（求值口只需要 model/define/instance 存在＋args 可查）
fn i159_exec(args : Array[(String, Json)]) -> @exec.Execution raise {
  let define_info : @model.ProcessDefine = {
    id: 1L,
    name: "i159",
    display_name: "i159",
    define_type: "approval",
    state: 1,
    content: simple_flow_json(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let model = @parser.parse_model(define_info.content)
  let fd = @json.FlowData::new()
  for e in args {
    let (k, v) = e
    fd.insert(k, v)
  }
  let instance = @model.ProcessInstance::create(define_info, "user1", fd)
  @exec.Execution::make(instance, model, define_info, "user1", fd)
}

///|
fn i159_eval(expr : String, args : Array[(String, Json)]) -> Bool raise {
  let (engine, _repo) = make_test_engine()
  engine.evaluate_expression(expr, i159_exec(args))
}

///|
/// 四格主体：数字发起档（runner 同形 amount=5000/500，Json::Number）
async test "i159 裸名排序运算代入数字变量" {
  let amount5000 : Array[(String, Json)] = [("amount", @json.number_of(5000L))]
  let amount500 : Array[(String, Json)] = [("amount", @json.number_of(500L))]
  // 正档 amount=5000
  assert_true(i159_eval("amount > 1000", amount5000)) // 修前：Some(2) 死臂 ⇒ 恒 false
  assert_true(i159_eval("amount >= 1000", amount5000))
  assert_false(i159_eval("amount < 1000", amount5000))
  assert_false(i159_eval("amount <= 1000", amount5000)) // 修前：非 Some(2) 即 true ⇒ 恒 true 蒙方向
  assert_true(i159_eval("amount == 5000", amount5000))
  assert_false(i159_eval("amount != 5000", amount5000))
  // 反档 amount=500：两臂必须对称翻转
  assert_false(i159_eval("amount > 1000", amount500))
  assert_true(i159_eval("amount <= 1000", amount500))
  assert_true(i159_eval("amount < 1000", amount500))
  assert_false(i159_eval("amount >= 1000", amount500))
}

///|
/// 字符串发起档（amount 以字符串进 args）：parse_double 能吃 ⇒ 仍按数字比，不得退化字典序
async test "i159 字符串形态的数字变量仍按数值比较" {
  let s5000 : Array[(String, Json)] = [("amount", @json.string_of("5000"))]
  assert_true(i159_eval("amount > 1000", s5000))
  assert_false(i159_eval("amount <= 1000", s5000))
  // 真非数字字符串：排序运算判 false（spec 明文），不得拿字典序蒙方向
  let word : Array[(String, Json)] = [("name", @json.string_of("zeta"))]
  assert_false(i159_eval("name > 1000", word))
  assert_false(i159_eval("name <= 1000", word))
}

///|
/// 缺失变量档：两边全 false（不蒙方向、不蒙 "0"——蒙 0 会让 `<=` 边判真重演 159 的落错支）。
/// 无命中档的后续行为（停住 vs 报错）是 issues/164 的领地，本格只钉"不选任何一支"。
async test "i159 缺失变量排序运算判 false 不蒙方向" {
  let none : Array[(String, Json)] = []
  assert_false(i159_eval("amount > 1000", none))
  assert_false(i159_eval("amount <= 1000", none))
  assert_false(i159_eval("amount >= 1000", none))
  assert_false(i159_eval("amount < 1000", none))
}

///|
/// ${} 形死臂回归：变量代入成功也必须判对——修前 `${amount} > 1000` 同样恒 false（Some(2) 死臂），
/// 与裸名无关，坐实两处独立。
async test "i159 ${} 形排序运算回归" {
  let amount5000 : Array[(String, Json)] = [("amount", @json.number_of(5000L))]
  assert_true(i159_eval("${amount} > 1000", amount5000))
  assert_false(i159_eval("${amount} <= 1000", amount5000))
  assert_true(i159_eval("${amount} >= 1000", amount5000))
  assert_true(i159_eval("${amount} < 99999", amount5000))
}

///|
/// 裸名等式档（i153 已钉 ${} 形的 ==/!=；这里钉裸名形的等式不破）：
/// 等式允许字符串兜底（spec 只约束排序运算），但数字优先不变。
async test "i159 裸名等式与字符串等式" {
  assert_true(i159_eval("level == vip", [("level", @json.string_of("vip"))]))
  assert_false(i159_eval("level != vip", [("level", @json.string_of("vip"))]))
  assert_false(i159_eval("level == vip", [("level", @json.string_of("normal"))]))
  assert_true(i159_eval("amount == 5000", [("amount", @json.number_of(5000L))]))
}

///|
/// 布尔字面量回归（simple_eval 尾段的 !empty/!=0/!=null 档不许被本轮顺手改坏）
async test "i159 布尔字面量与裸布尔变量回归" {
  assert_true(i159_eval("true", []))
  assert_false(i159_eval("false", []))
  assert_true(i159_eval("flag", [("flag", @json.string_of("1"))]))
  assert_false(i159_eval("flag", [("flag", @json.string_of("0"))]))
}
