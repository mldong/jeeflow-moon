// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一」）—— **MySQL 仓写侧** add_task_actor 兜底档
// （T0，不连真库）。
//
// 真库那一路挂在 `demo/cmd/t1_mysql`（T1-F119，读的是 `wf_process_task_actor` 里的列）；本档沿用
// 同文件 `cc_actor_ids_to_insert` 的既有做法：把"本仓实际拿去 INSERT 的那一支"抽成 pub 纯函数，
// 于是写侧这层的行为面在 T0 就照得到 —— 还原归一，下面几格当场红，不必等真库（本栈 native 档
// 编译要 cc、`moonbitlang/async` 的 C 运行时只认 MSVC，见 MAINTAINING.md）。
//
// §2.11 要求①「两层都挡」：只修门面腿 ⇒ 绕过门面直连仓储的调用方（集成层、第三方仓储消费者）
// 照样能往归属列 actor_id 灌空值 —— 那正是 issues/129 那族"空归属值读全库"的进水口。
// 两仓（内存 / MySQL）读的是同一份 @model.normalize_actors ⇒ "同一栈两个仓储两个答案"由构造堵死
// （issues/117 场景 27 那把尺子）。

///|
fn i142s_j(items : Array[String]) -> String {
  let b = StringBuilder()
  for i, s in items {
    if i > 0 {
      b.write_string("|")
    }
    b.write_string("[" + s + "]")
  }
  b.to_string()
}

///|
/// ① 写侧兜底：空串与纯空白 ⇒ 实际要插的序为空
test "i142-B MySQL 写侧 task_actor_ids_to_insert 空值档⇒零插" {
  let a = @repo.task_actor_ids_to_insert([""])
  assert_true(a == [], msg="空串档零插（实际 " + i142s_j(a) + "）")
  let b = @repo.task_actor_ids_to_insert(["  "])
  assert_true(b == [], msg="纯空白档零插（实际 " + i142s_j(b) + "）")
  let c = @repo.task_actor_ids_to_insert(["", "  ", "\t\n"])
  assert_true(c == [], msg="混空全丢（实际 " + i142s_j(c) + "）")
}

///|
/// ② 混给只丢空、保序；落库值取 trim 后的串（同人折叠成一行，与写侧判重同一把尺子）
test "i142-B MySQL 写侧 只丢空＋trim 后的值才插＋同调用折叠" {
  let got = @repo.task_actor_ids_to_insert(["a", "", "  ", "b"])
  assert_true(got == ["a", "b"], msg="只丢空且保序（实际 " + i142s_j(got) + "）")
  let dup = @repo.task_actor_ids_to_insert([" 123 ", "123", "\t123\n"])
  assert_true(dup == ["123"], msg="空白化重复折叠成一行（实际 " + i142s_j(dup) + "）")
  let stored = @repo.task_actor_ids_to_insert([" userB "])
  assert_true(stored == ["userB"], msg="插的是 trim 后的值（实际 " + i142s_j(stored) + "）")
  let ok = @repo.task_actor_ids_to_insert(["userB", "userC"])
  assert_true(ok == ["userB", "userC"], msg="正向对照不误伤（实际 " + i142s_j(ok) + "）")
}

///|
/// ③ 反向哨兵："0" 与 "00" 是两个人、都得插；" " 按纯空白丢弃
test "i142-B MySQL 写侧 反向哨兵 \"0\"/\"00\" 照插（判空是 trim()==\"\" 不是 falsy）" {
  let zero = @repo.task_actor_ids_to_insert(["0", "", "1"])
  assert_true(zero == ["0", "1"], msg="\"0\" 照插（实际 " + i142s_j(zero) + "）")
  let two = @repo.task_actor_ids_to_insert(["0", "00", " ", "a"])
  assert_true(two == ["0", "00", "a"], msg="0/00 两个人不被折叠（实际 " + i142s_j(two) + "）")
}

///|
/// ④ 判据单点：MySQL 腿＝@model 那一份，不许本仓另写规则（两仓不许两个答案）
test "i142-B 判据单点：MySQL 写侧与 @model.normalize_actors 逐档同答案" {
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
    let via_repo = @repo.task_actor_ids_to_insert(c)
    let via_model = @model.normalize_actors(c)
    assert_true(
      via_repo == via_model,
      msg="MySQL 腿＝@model 那一枚（repo " + i142s_j(via_repo) + " / model " +
        i142s_j(via_model) + "）",
    )
  }
}
