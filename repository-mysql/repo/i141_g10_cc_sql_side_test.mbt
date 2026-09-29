// issues/141 G10 · 空抄送人不建 cc 行 —— **MySQL 仓写侧**兜底档（T0，不连真库）。
//
// 本栈真库档（T1）本机跑不了（native 编译要 cc、wasm 档无 socket，口径与同包
// i141_g1_g2_cc_sql_shape_test.mbt 一致），所以写侧这一层的行为面靠**本仓实际拿去 INSERT 的那一支**
// 来照：`create_cc_instance` 的循环与 `create_cc_instance_if_absent` 的返回子集都取自
// `@repo.cc_actor_ids_to_insert`（pub 纯函数，只做"归一 + 判重"两步组合，规则本身在 @model 那一处）。
// ⇒ 还原这一支的归一，下面几格当场红，不必等真库；同时它与内存腿读的是同一把尺子，
// "同一栈两个仓储两个答案"由构造堵死（issues/117 场景 27）。
//
// 判据（spec 06-facade §2.10 四点，基准＝java `5fbd5ac`）：
// ① 空串/纯空白/空元素一律丢弃，且**写侧这一层也要挡**（JdbcProcessRepository.createCcInstance 同款兜底）；
// ② 落库值取 trim 后的串 ⇒ " 123 " 与 "123" 同一人，命中 G2 写侧判重；
// ④ 反向哨兵 "0" 不得被当空值丢掉。

///|
fn g10s_j(items : Array[String]) -> String {
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
fn g10s_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i141-G10 MySQL 写侧] 红样：" + label)
    abort("[i141-G10 MySQL 写侧] 红样：" + label)
  }
}

///|
/// ① 写侧兜底：空串与纯空白 ⇒ 实际要插的序为空（直连仓储的第三方调用方同样建不出空行）
test "i141-G10 MySQL 写侧 cc_actor_ids_to_insert 空值档⇒零插（repoWritePathAlsoDropsBlankActors）" {
  let a = @repo.cc_actor_ids_to_insert([], [""])
  g10s_check(a == [], "空串档零插（实际 " + g10s_j(a) + "）")
  let b = @repo.cc_actor_ids_to_insert([], ["  "])
  g10s_check(b == [], "纯空白档零插（实际 " + g10s_j(b) + "）")
  let c = @repo.cc_actor_ids_to_insert([], ["", "  ", "\t\n"])
  g10s_check(c == [], "混空全丢（实际 " + g10s_j(c) + "）")
}

///|
/// ② 混给只丢空，正常值一个不少、顺序不变
test "i141-G10 MySQL 写侧 混给只丢空：[a,空,纯空白,b]⇒[a,b]" {
  let got = @repo.cc_actor_ids_to_insert([], ["a", "", "  ", "b"])
  g10s_check(got == ["a", "b"], "只丢空且保序（实际 " + g10s_j(got) + "）")
  // 正向对照（判据不误伤首次）
  let ok = @repo.cc_actor_ids_to_insert([], ["userB", "userC"])
  g10s_check(ok == ["userB", "userC"], "两个正常人全量保序（实际 " + g10s_j(ok) + "）")
}

///|
/// ③ 落库值取 trim 后的串 ⇒ 同人命中 G2 写侧判重（不 trim 就落两行，把 b4b6ade 那层判重打穿）
test "i141-G10 MySQL 写侧 trim 后同值命中判重（G2 咬合点）" {
  let dup = @repo.cc_actor_ids_to_insert(["123"], [" 123 "])
  g10s_check(dup == [], "已有 123 ⇒ 空白包裹值判为同人（实际 " + g10s_j(dup) + "）")
  let same_call = @repo.cc_actor_ids_to_insert([], [" 123 ", "123", "\t123\n"])
  g10s_check(same_call == ["123"], "同调用内空白化重复折叠成一行（实际 " + g10s_j(same_call) + "）")
  let stored = @repo.cc_actor_ids_to_insert([], [" userB "])
  g10s_check(stored == ["userB"], "插的是 trim 后的值而非原始包裹值（实际 " + g10s_j(stored) + "）")
}

///|
/// ④ 反向哨兵："0" / "false" 这类"看起来像空"的正常值不得被丢掉
test "i141-G10 MySQL 写侧 反向哨兵 \"0\" 不被当空值" {
  let zero = @repo.cc_actor_ids_to_insert([], ["0", "", "1"])
  g10s_check(zero == ["0", "1"], "\"0\" 照插（实际 " + g10s_j(zero) + "）")
  let padded_zero = @repo.cc_actor_ids_to_insert(["0"], [" 0 "])
  g10s_check(padded_zero == [], "\" 0 \" 与 \"0\" 同人 ⇒ 判重命中零插（实际 " + g10s_j(padded_zero) + "）")
}

///|
/// ⑤ 判据单点：MySQL 腿只做"归一 + 判重"两步组合，规则取自 @model 那一份（与内存腿逐字同答案）
test "i141-G10 判据单点：MySQL 写侧与 @model 那份同答案（两仓不许各抄规则）" {
  let cases : Array[(Array[String], Array[String])] = [
    ([], ["a", "", "  ", "b"]),
    (["x"], [" x ", "y", ""]),
    (["x", "y"], ["y", " x ", "  "]),
    ([], ["0", " 0 ", ""]),
    ([], []),
  ]
  for c in cases {
    let (existing, requested) = c
    let via_repo = @repo.cc_actor_ids_to_insert(existing, requested)
    let via_model = @model.cc_fresh_subset(existing, @model.normalize_cc_actors(requested))
    g10s_check(
      via_repo == via_model,
      "MySQL 腿＝@model 归一＋@model 判重（repo " + g10s_j(via_repo) + " / model " +
        g10s_j(via_model) + "）",
    )
  }
}

///|
/// ⑥ 读侧口径不破：已有行里若真躺着历史空值（本条不清理历史数据，owner 拍"查询侧不去重、
/// 历史重复行不清理"），归一只作用在**写入侧**，find 回来的原值不许被改写
test "i141-G10 归一只在写侧：existing 里的原值不被顺手 trim 改写" {
  let got = @repo.cc_actor_ids_to_insert([" padded "], ["padded"])
  g10s_check(
    got == ["padded"],
    "existing 是库里的原值（不 trim 比对目标），故新值仍算新人（实际 " + g10s_j(got) + "）",
  )
}
