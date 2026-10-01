// issues/137 §3-6（spec 06-facade §processTask/removeTaskActor 语义 6 ＋ §2.11 写点表末行，
// owner 2026-10-02 拍「两形并集」）—— **删除腿单点本身**的档位（T0，纯函数）。
//
// 与 i142b_normalize_actors_test.mbt（写侧单点）是姊妹档：写侧单点只产出 trim 形，删除腿单点
// 额外保住原值形。两者共用同一枚 trim/判空判据——`actor_delete_forms` 的实现就是把单个元素喂给
// `normalize_actors`（返回空 ⇒ 空值丢弃；返回 [t] ⇒ t 就是 trim 形），§2.11 尾注「不要再抄第二份」
// 在这里是**实现层面真做到了**，不是注释里说说。
//
// 为什么必须两形（1.8.36 之前八栈正好分成相反的两派，没有一处两全）：
// · 只取 **trim 形**（本栈与 php/csharp/rust 的旧形状）⇒ 门面按语义 6 交出的历史脏行原值 " 9101 "
//   被削成 9101，真库 NO PAD 排序规则下那一行删不掉而门面报成功 —— 被摘的人待办还在；
// · 只取 **原值形**（go/node/python/java 的旧形状）⇒ 绕过门面直连仓储的调用方传 " 8601 " 时
//   删不掉写侧归一后落库的规范行（issues/142 §9.2 那一路）；且空值照喂 DELETE，
//   把历史 actor_id='' 脏行批量误删。
// 下面各档分别钉住这两头，任一头被摘掉都当场红。

///|
test "i137-§3-6 actor_delete_forms 空值档：空集／全空白 ⇒ 空数组（调用方据此早退，一条 DELETE 都不发）" {
  assert_eq(@model.actor_delete_forms([]), [])
  assert_eq(@model.actor_delete_forms(["", "  ", "\t\n"]), [])
}

///|
test "i137-§3-6 actor_delete_forms 两形档：带空格值产出「原值 ∪ trim 值」，原值在前、已 trim 值只一份" {
  // 原值形在前、trim 形在后（保序，便于各栈 IN 列表与日志逐字对照）
  assert_eq(@model.actor_delete_forms([" 9101 "]), [" 9101 ", "9101"])
  // 已经 trim 过的值两形相同 ⇒ 只一份，不让 IN 列表白白翻倍
  assert_eq(@model.actor_delete_forms(["9101"]), ["9101"])
  // 跨元素去重：" 9101 " 与 "9101" 是同一个人的两种写法（§2.11 归一口径）⇒ 并集里各一次，不得四份
  assert_eq(@model.actor_delete_forms([" 9101 ", "9101", "9101", " 9101 "]), [" 9101 ", "9101"])
  // ⚠️ 去重按**字面**做，不按"trim 后相同"折叠原值形：一个空格与两个空格是两种不同的原值形，
  //    都得保留（库里可能正是其中任一种脏法，少带一种就删不掉那一行）；trim 形仍只一份
  assert_eq(
    @model.actor_delete_forms([" 9101 ", "  9101  "]),
    [" 9101 ", "9101", "  9101  "],
  )
}

///|
test "i137-§3-6 actor_delete_forms 混给档：空值丢弃、非空值两形、保序" {
  assert_eq(
    @model.actor_delete_forms(["a", "", " b ", "  ", "c"]),
    ["a", " b ", "b", "c"],
  )
}

///|
test "i137-§3-6 actor_delete_forms 反向哨兵：\"0\" 是合法 id，且 \"0\" 与 \"00\" 是两个人" {
  // 判据不许是 falsy（§2.11 要求④）：删 "0" 不得连带删 "00"
  assert_eq(@model.actor_delete_forms(["0"]), ["0"])
  assert_eq(@model.actor_delete_forms(["0", "00", " 0 "]), ["0", "00", " 0 "])
}

///|
test "i137-§3-6 actor_delete_forms 与写侧单点共用尺子：空值判据两枚必须同答案" {
  // 若删除腿自己抄了第二份 trim/判空（§2.11 尾注明令禁止），这一格会照出分叉：
  // 同一份入参，"写侧认为该丢的" 与 "删除腿认为该丢的" 必须是同一批
  let inputs = [[""], ["  "], ["\t\n"], ["", "  ", "x"], ["0"], [" 0 "]]
  for input in inputs {
    let dropped_by_write = @model.normalize_actors(input).is_empty()
    let dropped_by_delete = @model.actor_delete_forms(input).is_empty()
    assert_eq(dropped_by_write, dropped_by_delete)
  }
}
