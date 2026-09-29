// issues/138 · MySQL 腿的 ccList 行形状守门格。
//
// 本栈无集成壳 ⇒ 引擎侧格子就是 ccList 唯一的守门件；真库档（T1，需 JEFFLOW_DB_* 指向的
// MySQL 实例）本机跑不了，所以这里守**投影 SQL 的文本形状**：三要件全部落在那份列清单上
// （清单由 @repo.instance_select_columns() 单点承载，pageInstances 与 pageCcInstances 共用）。
// 行为面的守门格（内存腿）在 facade/i138_cc_row_shape_test.mbt。
//
// 守的三件事：
//   要件 1  主键列是 `pi.id`（经 instance_row_of_mysql 读成行上的 `id`，值＝实例 id）
//   要件 2+3 operator 列是 `pi.operator`＝流程发起人，cc 表的列**一个都不进投影**
//            （`cc.actor_id AS operator`＝错法 ①，`cc.create_user`＝错法 ②）
//   共用    cc 支的投影清单 == 实例支清单 ⇒「rows 同 processInstance/page 行结构」由构造保证

///|
fn i138sql_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i138-ccList SQL 形状] 红样：" + "\{label}")
    abort("[i138-ccList SQL 形状] 红样：" + "\{label}")
  }
}

///|
test "i138-mysql-要件1 cc 支主键列取实例 pi.id" {
  let cols = @repo.cc_instance_select_columns()
  i138sql_check(cols.contains("pi.id,"), "投影含实例主键列 pi.id（行读回来才是 id＝实例 id）")
  i138sql_check(!cols.contains("cc.id"), "投影不含 cc.id（把 cc 表原样投出来＝错法 ③）")
  i138sql_check(!cols.contains("process_instance_id AS id"), "没有用 cc.process_instance_id 顶替主键")
}

///|
test "i138-mysql-要件2+3 operator 取 pi.operator，cc 列一律不进投影" {
  let cols = @repo.cc_instance_select_columns()
  i138sql_check(cols.contains("pi.operator"), "投影含 pi.operator（实例 operator＝流程发起人）")
  i138sql_check(!cols.contains("cc.actor_id"), "投影不含 cc.actor_id（错法 ①：被抄送人＝查询者本人）")
  i138sql_check(!cols.contains("cc.create_user"), "投影不含 cc.create_user（错法 ②：发起抄送的人）")
  i138sql_check(!cols.contains("cc."), "投影里没有任何 cc. 列（cc 表只当归属过滤/关联）")
  i138sql_check(!cols.contains("NULL AS variable"), "variable 不被置空：取实例的 pi.variable")
  // 逐列点名：清单必须整体等于实例清单，而不是只把 operator 一列换掉
  for c in [
    "pi.parent_id",
    "pi.process_define_id",
    "pi.state",
    "pi.parent_node_name",
    "pi.business_no",
    "pi.expire_time",
    "pi.variable",
    "pi.create_time",
    "pi.create_user",
    "pi.update_time",
    "pi.update_user",
    "pd.name AS define_name",
    "pd.display_name AS define_display_name",
    "pd.version AS define_version",
  ] {
    i138sql_check(cols.contains(c), "清单含实例/定义侧列 \{c}")
  }
}

///|
test "i138-mysql-两支共用同一投影（形状由构造保证）" {
  let inst_cols = @repo.instance_select_columns()
  i138sql_check(
    @repo.cc_instance_select_columns() == inst_cols,
    "ccList 的投影清单与 processInstance/page 完全一致",
  )
  i138sql_check(inst_cols.contains("pi.id,") && inst_cols.contains("pi.operator"), "实例清单自身仍带 pi.id/pi.operator")
}
