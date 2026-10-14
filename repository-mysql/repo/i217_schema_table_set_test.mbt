// issues/217 · audit8 队列 R49（C99 §3.3 层位 3 / C1-L3 §1d）——建表 SQL 表集合断言（T0，无 DB 依赖）。
//
// "谁盯着表集合"此前四栈四答案（php 无／rust test_schema_* 群／moon 零枚／csharp 静态形状）：
// 本件补上仓内牙，与 rust `test_schema_contains_8_tables`/`test_schema_table_names`
// 及 php/csharp 同轮新增件同形——剥 `--` 行首注释 → count(CREATE TABLE) == 8 → 8 名单逐字在场
// （canonical 前缀形式 `CREATE TABLE IF NOT EXISTS <name> (`，防子串误判：`wf_process_task`
// 是 `wf_process_task_actor` 的前缀）。
//
// 盯的对象＝本仓分发副本 repository-mysql/schema/schema-mysql.sql（T1 smoke 与使用者
// `mysql < schema-mysql.sql` 导入的同一份）；字节级"与编辑源全等"由 hub check-doc-schema.py
// 门禁在管（147 族），本件只补单语言下载即用的仓内表集合牙。
//
// fs 读法照 core/engine `load_flow` 先例（候选目录探测；c01 等既有用例在 T0 全量里走同款 @fs 读，
// 2026-10-15 本卡实测本件同款可用）。

///|
fn i217sql_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i217-表集合] 红样：\{label}")
    abort("[i217-表集合] 红样：\{label}")
  }
}

///|
async fn i217_load_mysql_schema() -> String {
  for dir in ["../schema", "schema", "repository-mysql/schema"] {
    let path = "\{dir}/schema-mysql.sql"
    if @fs.can_read(path) {
      let data = @fs.read_file(path)
      let text = data.text()
      let kept : Array[String] = []
      for line in text.split("\n") {
        if !line.trim_start().has_prefix("--") {
          kept.push(line.to_owned())
        }
      }
      return kept.join("\n")
    }
  }
  abort("[i217-表集合] 找不到 schema-mysql.sql（候选目录都没命中）")
}

///|
async test "i217-正向 恰 8 句 CREATE TABLE（表集合计数）" {
  let schema = i217_load_mysql_schema()
  let count = schema.split("CREATE TABLE").collect().length() - 1
  i217sql_check(count == 8, "count(CREATE TABLE) 期望 8 实得 \{count}")
}

///|
async test "i217-正向 8 表名单逐字在场（canonical 前缀形式）" {
  let schema = i217_load_mysql_schema()
  let expected : Array[String] = [
    "wf_process_define",
    "wf_process_instance",
    "wf_process_task",
    "wf_process_task_actor",
    "wf_process_cc_instance",
    "wf_process_design",
    "wf_process_design_his",
    "wf_process_surrogate",
  ]
  for table in expected {
    i217sql_check(
      schema.contains("CREATE TABLE IF NOT EXISTS \{table} ("),
      "缺表或缺 canonical 前缀形式：\{table}",
    )
  }
}
