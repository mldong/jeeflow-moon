// issues/197 · MySQL 腿分页 ORDER BY 组装（audit8 R31）。
//
// 本腿曾把 `ORDER BY pd.id DESC` 硬编码进串里、`PageQuery.order_by` 全栈零消费者。
// 这里守 `@repo.define_page_order_sql` 那张单子：白名单＝java `DEFINE_WHITELIST` 八列，
// 别名一律重写到本腿主表 `pd`，白名单外／未给 ⇒ 回落 `pd.id DESC`；
// **方向词只由解析器产出的布尔量决定 ⇒ `order_by` 原文永不进 SQL 串**（java 那边是把
// `kv[1].toUpperCase()` 原样拼进去的，列名有白名单而方向词没有——本栈不留那个口）。
//
// 真库那一头的接线（impl 到底有没有调这个函数）由 T1 smoke 的 `t1_m9_define_order_by` 守，
// 纯文本格守的是"给了串之后串长成什么样"。内存腿的行为档在 core/memory/i197_..._test.mbt。

///|
fn i197sql_eq(got : String, want : String, label : String) -> Unit {
  if got != want {
    println("[i197-分页 ORDER BY] 红样：\{label} 期望 <\{want}> 实得 <\{got}>")
    abort("[i197-分页 ORDER BY] 红样：\{label}")
  }
}

///|
test "i197-正向 消费 order_by：版本倒序落进 SQL 且别名改写到 pd" {
  i197sql_eq(
    @repo.define_page_order_sql(Some("t.version desc")),
    " ORDER BY pd.version DESC",
    "门面 getLastByName 那条串的实际形状",
  )
  i197sql_eq(
    @repo.define_page_order_sql(Some("pd.state asc, t.create_time DESC")),
    " ORDER BY pd.state ASC, pd.create_time DESC",
    "多子句＋大小写混排",
  )
  i197sql_eq(
    @repo.define_page_order_sql(Some("version")),
    " ORDER BY pd.version ASC",
    "裸列名（无别名前缀）认，方向缺省升序＝java buildOrder 同档",
  )
}

///|
test "i197-负向 白名单外与空值都回落 pd.id DESC（不给拼串机会）" {
  i197sql_eq(
    @repo.define_page_order_sql(None),
    " ORDER BY pd.id DESC",
    "未给 order_by ⇒ 缺省倒序",
  )
  i197sql_eq(@repo.define_page_order_sql(Some("")), " ORDER BY pd.id DESC", "空串")
  i197sql_eq(@repo.define_page_order_sql(Some("   ")), " ORDER BY pd.id DESC", "全空白")
  i197sql_eq(
    @repo.define_page_order_sql(Some("t.password desc")),
    " ORDER BY pd.id DESC",
    "白名单外的列被整条跳过，不退化成按别的列排",
  )
  // java 的方向词是直接拼进 SQL 的；本栈必须把它折成布尔 ⇒ 攻击串只能在白名单那一关被撞掉
  i197sql_eq(
    @repo.define_page_order_sql(Some("t.version desc; DROP TABLE wf_process_define")),
    " ORDER BY pd.version ASC",
    "注入形状：分号后的词不进串，方向词非法按升序",
  )
  i197sql_eq(
    @repo.define_page_order_sql(Some("pd.id DESC,; -- x")),
    " ORDER BY pd.id DESC",
    "带尾缀攻击：非法列子句整条跳过，串里不出现分号/注释符",
  )
}

///|
test "i197-回归 白名单八列逐条都认（照 java DEFINE_WHITELIST，不多不少）" {
  for col in ["id", "name", "display_name", "type", "state", "version", "create_time", "update_time"] {
    i197sql_eq(
      @repo.define_page_order_sql(Some("t." + col + " desc")),
      " ORDER BY pd." + col + " DESC",
      "白名单列 " + col,
    )
  }
  // java 白名单里没有 create_user/update_user ⇒ 本栈也不收（少收一列不是漏，是照抄参照）
  i197sql_eq(
    @repo.define_page_order_sql(Some("t.create_user desc")),
    " ORDER BY pd.id DESC",
    "create_user 不在 java 白名单 ⇒ 跳过",
  )
}

///|
test "i197-解析器 parse_order_by 的形状（两腿共用的那把尺子）" {
  let t = @model.parse_order_by("t.version desc, name")
  if t.length() != 2 {
    abort("i197: 解析出 \{t.length()} 项，期望 2")
  }
  if t[0].column != "t.version" || !t[0].desc {
    abort("i197: 第一项应＝t.version 降序")
  }
  if t[1].column != "name" || t[1].desc {
    abort("i197: 第二项缺方向词⇒升序")
  }
  let bad = @model.parse_order_by("   ,  ")
  if bad.length() != 0 {
    abort("i197: 全空白子句应产出 0 项")
  }
  if @model.order_column_bare("t.version") != "version" || @model.order_column_bare("version") != "version" {
    abort("i197: 别名剥离")
  }
}
