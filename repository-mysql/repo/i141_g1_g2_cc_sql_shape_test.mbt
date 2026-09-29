// issues/141 G1/G2 · MySQL 腿守门格（T0 档，不连真库）。
//
// 本栈真库档（T1，需 JEFFLOW_DB_* 指向的 MySQL）本机跑不了（native 编译要 cc，wasm 档无 socket），
// 所以这里守两件事：
//   ① 判据单点 —— G1 的"有效归属条件"与 G2 的"实际新建子集"都取自 core 的同一个纯函数
//      （@model.cc_ownership_operator / @model.cc_fresh_subset），内存腿的行为格（core/memory 的
//      i141_g1_g2 两支）与本格读的是同一把尺子 ⇒「同一栈两个仓储两个答案」由构造堵死；
//   ② SQL 文本形状 —— 归属谓词**恒拼**（旧形状是"有 operator 才拼、没有整条丢掉"= 放出全部实例，
//      正是 issues/141 G1 关掉的退路），写侧判重靠"读已有 → 只插新人"，
//      既不在查询侧加去重、也不把 INSERT 改成 ON DUPLICATE/REPLACE（那会重置未读、刷时间）。
// 行为面的等价断言（内存腿）在 core/memory/i141_g1_cc_ownership_test.mbt 与 i141_g2_cc_idempotent_test.mbt。

///|
fn cc_sql_join(items : Array[String]) -> String {
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
fn sql_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i141-cc SQL 形状] 红样：" + label)
    abort("[i141-cc SQL 形状] 红样：" + label)
  }
}


///|
/// 子串出现次数（守"恒拼一次、不多不少"）
fn occurrences(hay : String, needle : String) -> Int {
  hay.split(needle).length() - 1
}

///|
/// ① G1 判据单点四档（缺键/空串/全空白 ⇒ 无有效条件；非空白 ⇒ 原值）—— 内存仓与 SQL 仓共用
test "i141-G1 判据单点四档（两仓共用的那一份）" {
  let q0 = @model.PageQuery::new(1L, 10L)
  sql_check(@model.cc_ownership_operator(q0) is None, "缺键档判为无有效条件")
  let q1 = @model.PageQuery::new(1L, 10L)
  q1.set_operator(Some(""))
  sql_check(@model.cc_ownership_operator(q1) is None, "空串档判为无有效条件")
  let q2 = @model.PageQuery::new(1L, 10L)
  q2.set_operator(Some("   "))
  sql_check(@model.cc_ownership_operator(q2) is None, "全空白档判为无有效条件")
  let q3 = @model.PageQuery::new(1L, 10L)
  q3.set_operator(Some("user1"))
  match @model.cc_ownership_operator(q3) {
    Some(op) => sql_check(op == "user1", "有效档取原值（实际 " + op + "）")
    None => sql_check(false, "有效档必须给 Some(原值)")
  }
}

///|
/// ② G1 count 支：归属谓词恒拼（旧形状在此处是 match operator { None => "" } ⇒ 整条丢掉）
test "i141-G1 count SQL 恒带 cc.actor_id 谓词，且只带一次" {
  let sql = @repo.cc_page_count_sql()
  sql_check(
    occurrences(sql, " AND cc.actor_id = ?") == 1,
    "count 支含且仅含一条归属谓词（实际 " + sql + "）",
  )
  sql_check(
    sql.contains("FROM wf_process_cc_instance cc JOIN wf_process_instance pi ON pi.id = cc.process_instance_id"),
    "cc 表与实例表内连：行源仍是实例侧（issues/138 行形状不破）",
  )
  // 计数口径维持既有 DISTINCT（G2 的判重在写侧，查询侧既不增也不减去重）
  sql_check(sql.contains("COUNT(DISTINCT pi.id)"), "计数仍是 COUNT(DISTINCT pi.id)")
  sql_check(occurrences(sql, "DISTINCT") == 1, "没有为 G2 顺手再加一层去重")
}

///|
/// ③ G1 data 支：谓词恒拼 + 分页内联；归属列没被顺手挪到 pi.operator
test "i141-G1 data SQL 恒带 cc.actor_id 谓词且不动 issues/138 的投影清单" {
  let sql = @repo.cc_page_data_sql(20L, 0L)
  sql_check(
    occurrences(sql, " AND cc.actor_id = ?") == 1,
    "data 支含且仅含一条归属谓词（实际 " + sql + "）",
  )
  sql_check(occurrences(sql, "cc.actor_id") == 1, "cc.actor_id 只出现在谓词里，不进投影（issues/138）")
  sql_check(sql.contains("pi.id, pi.parent_id"), "投影清单仍是实例侧列（与 pageInstances 同份）")
  sql_check(sql.contains("ORDER BY pi.id DESC LIMIT 20 OFFSET 0"), "排序与分页内联不变（C21）")
  sql_check(!sql.contains("pi.operator = ?"), "归属列没被挪到发起人那一列（那是 doneList/instancePage 的尺子）")
}

///|
/// ④ G2 读侧 SQL 形状：按实例取已有 cc 行的 actor_id，**不去重**（历史重复行原样返回 ⇒ 不清理）
test "i141-G2 读侧 SQL 按实例过滤且不加 DISTINCT" {
  let sql = @repo.cc_actor_ids_sql()
  sql_check(
    sql == "SELECT actor_id FROM wf_process_cc_instance WHERE process_instance_id = ?",
    "读侧逐字＝按实例取 actor_id（实际 " + sql + "）",
  )
  sql_check(!sql.contains("DISTINCT"), "读侧不加去重（判重在写侧，查询侧维持原状）")
  sql_check(sql.contains("process_instance_id = ?"), "判重键含实例（不是全局 actor 唯一）")
}

///|
/// ⑤ G2 建行 SQL 形状：逐行 INSERT、state 恒 0 ⇒ 重复人被上层子集挡在门外，
/// 而不是靠 UPSERT 覆盖（覆盖会把未读重置、把时间刷成最新，正是②③两条不许）。
test "i141-G2 建行 SQL 是逐行 INSERT 且无 UPSERT/UPDATE 形状" {
  let sql = @repo.cc_insert_sql()
  sql_check(sql.contains("INSERT INTO wf_process_cc_instance"), "建行语句仍是 INSERT")
  sql_check(sql.contains("state, create_time, create_user) VALUES (?, ?, ?, 0, ?, ?)"), "state 恒 0（新行必未读）")
  sql_check(!sql.contains("ON DUPLICATE"), "不许用 ON DUPLICATE KEY UPDATE（那会重置未读/刷时间）")
  sql_check(!sql.contains("REPLACE INTO"), "不许用 REPLACE（删旧插新同样重置未读与时间）")
  sql_check(!sql.contains("UPDATE"), "建行路径里不含 UPDATE 语义")
  sql_check(!sql.contains("DISTINCT"), "建行 SQL 与去重无关：判重在 @model.cc_fresh_subset 那一层")
}

///|
/// ⑥ G2 子集判据单点：两仓共用 core 的那一份（SQL 仓在这里读一遍，与内存腿逐字同一判据）
test "i141-G2 子集判据单点 cc_fresh_subset（两仓共用）" {
  let a = @model.cc_fresh_subset([], ["x", "y"])
  sql_check(a == ["x", "y"], "首轮全量且保序（实际 " + cc_sql_join(a) + "）")
  let b = @model.cc_fresh_subset(["x"], ["x", "y", "x"])
  sql_check(b == ["y"], "已有跳过 + 同调用内折叠（实际 " + cc_sql_join(b) + "）")
  let c = @model.cc_fresh_subset(["x", "y"], ["y", "x"])
  sql_check(c == [], "全重复 ⇒ 空子集（调用方整支不发码 4）")
}

///|
/// ⑦ G1 非归属列的空值放行**不变**（SQL 通道那把尺子，issues/129 案 A 第二层）：
/// 归属列 cc.actor_id 的空值塌成 AND 1=0；cc/pd 侧的**可选过滤**空值仍按"没填"整条忽略。
test "i141-G1 非归属列空值仍放行，归属列空值仍塌 1=0（SQL 通道）" {
  let args : Map[String, Json] = Map([])
  args["m_cc_EQ_actorId"] = @json.string_of("")
  args["m_cc_LIKE_actorId"] = @json.string_of("")
  args["m_pd_EQ_name"] = @json.string_of("")
  let filters = @query.parse_m_params(args)
  let (where_sql, params) = @query.build_m_where(filters)
  sql_check(
    occurrences(where_sql, " AND 1=0") == 1,
    "只有归属列 cc.actor_id 的空值塌成 1=0（实际 " + where_sql + "）",
  )
  sql_check(!where_sql.contains("cc.actor_id LIKE"), "cc.actor_id 的 LIKE（非归属用法）空值仍被忽略")
  sql_check(!where_sql.contains("pd.name"), "非归属列 pd.name 的空值仍按没填忽略")
  assert_eq(params.length(), 0)
}

