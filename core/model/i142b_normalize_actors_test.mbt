// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一 · actor_id 与 task id」，owner 2026-09-30
// 拍「八栈一起收：两形同判据＋写侧兜底＋trim＋哨兵」）—— **判据单点本身**的档位（T0，纯函数）。
//
// 这一枚是 issues/141 G10 为抄送腿落地的那一份，本批按 §2.11 尾注「归一判据请复用已落地的那一枚
// 单点……必要时改名成通用的 normalizeActors——不要再抄第二份」升格为通用单点：门面写侧腿
// （addCandidate/surrogate/transfer）、引擎漏斗（cc 三入口 + nextNodeOperator 消费腿）、两仓写侧
// （add_task_actor / create_cc_instance*）读的都是这里唯一的一份判据。
//
// 反向哨兵档位说明（§2.11 要求④）：`"0"` 与 `"00"` 是**两个人**、都必须保留；`" "` 是纯空白，
// 与空串同档丢弃（判空一律 trim()==""，不是 falsy，也不是"不 trim 就非空"）。

///|
test "i142-B normalize_actors 四档：空集／全空白／混给只丢空／trim 同值折叠＋顺序保持" {
  assert_eq(@model.normalize_actors([]), [])
  assert_eq(@model.normalize_actors(["", "  ", "\t\n"]), [])
  assert_eq(@model.normalize_actors(["a", "", "  ", "b"]), ["a", "b"])
  assert_eq(@model.normalize_actors([" a ", "a", " 123 "]), ["a", "123"])
  // 顺序保持（fire 序与入参序一一对应，写侧判重也按这个序落库）
  assert_eq(@model.normalize_actors(["c", "b", "a"]), ["c", "b", "a"])
}

///|
test "i142-B normalize_actors 反向哨兵：\"0\"/\"00\"/\"false\" 都是有效值，\"0\" 与 \"00\" 是两个人" {
  // 判据不许是 falsy：php `array_filter` 无回调、python `if not x`、js `filter(Boolean)`
  // 都会吃掉 '0'（§2.11 要求④点名的三处）
  assert_eq(@model.normalize_actors(["0"]), ["0"])
  assert_eq(@model.normalize_actors(["false", "true"]), ["false", "true"])
  // `" "` 是纯空白 ⇒ 丢弃；丢完剩下的 `"0"`、`"00"`、`"a"` 三个都是独立的人，
  // 严禁松散比较把 "0" 与 "00" 折叠成一个人（§2.11 尾注点名的 php 两把尺子形状）
  assert_eq(@model.normalize_actors(["0", "00", " ", "a"]), ["0", "00", "a"])
  // 空白包裹值与干净值同人
  assert_eq(@model.normalize_actors([" 0 ", "0"]), ["0"])
}

///|
test "i142-B normalize_actor 单值档（transfer 的 fromActor/toActor 用的那一枚）" {
  assert_eq(@model.normalize_actor(" a "), Some("a"))
  assert_eq(@model.normalize_actor("a"), Some("a"))
  assert_eq(@model.normalize_actor("0"), Some("0"))
  assert_eq(@model.normalize_actor(""), None)
  assert_eq(@model.normalize_actor("   "), None)
  assert_eq(@model.normalize_actor("\t\n"), None)
}

///|
test "i142-B normalize_comma_actors 逗号串档＝同一枚判据（本栈不再各写一份 trim/is_empty）" {
  assert_eq(@model.normalize_comma_actors(" a , a ,,  b "), ["a", "b"])
  assert_eq(@model.normalize_comma_actors(""), [])
  assert_eq(@model.normalize_comma_actors(" , ,, "), [])
  assert_eq(@model.normalize_comma_actors("0,00"), ["0", "00"])
  assert_eq(@model.normalize_comma_actors("\t\n"), [])
}

///|
/// 「判据只有一份」的结构钉：旧名 normalize_cc_actors 与通用名 normalize_actors 逐档同答案
/// —— 若有人把旧名改回独立实现（两把尺子迟早分叉的第一现场），这一格当场红。
test "i142-B 判据单点唯一性：normalize_cc_actors（旧名转发）与 normalize_actors 同答案" {
  let cases : Array[Array[String]] = [
    [],
    [""],
    ["", "  ", "\t\n"],
    ["a", "", "  ", "b"],
    [" a ", "a", " 123 "],
    ["0", "00", " ", "a"],
    ["c", "b", "a"],
  ]
  for c in cases {
    assert_eq(@model.normalize_cc_actors(c), @model.normalize_actors(c))
  }
}
