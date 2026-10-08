// issues/150 的②判据：`persistMode` 缺省/未知值一律回落 ARCHIVE（spec/09 §4.0，
// java `PersistPostInterceptor.java:92-96` 的 if/else），以及"定义级声明才挂载"的 opt-in 守卫
// （java 是声明即挂载：`NodeModel.execPostInterceptors` 先取节点级、空则回落流程级；
//  本栈的通道是宿主全局注册，不补这条守卫，②会把每一条"办结+同意"的流程都拖去写一张与流程同名的表）。

///|
/// 夹具流模板：apply(任务) → end(结束)，表 expense（在 make_persist_fixture 的内存元数据里）
/// mode_part 空＝不写 persistMode；declared=false＝不写 postInterceptors（＝流程没挂本拦截器）
fn i150_flow(mode_part : String, declared : Bool) -> String {
  let mode = if mode_part.is_empty() {
    ""
  } else {
    "\"persistMode\": \"" + mode_part + "\", "
  }
  let decl = if declared {
    "\"postInterceptors\": \"com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor\", "
  } else {
    ""
  }
  "{\"name\": \"p\", \"displayName\": \"P\", \"type\": \"approval\", " + mode + decl +
  "\"relTableName\": \"expense\", \"nodes\": [" +
  "{\"id\": \"apply\", \"type\": \"snaker:task\", \"text\": {\"value\": \"A\"}}, " +
  "{\"id\": \"end\", \"type\": \"snaker:end\", \"text\": {\"value\": \"E\"}}], \"edges\": []}"
}

///|
fn i150_vars() -> Map[String, Json] {
  let vars : Map[String, Json] = Map([])
  vars["f_note"] = @json.string_of("差旅")
  vars["f_amount"] = @json.number_of(100L)
  vars
}

///|
fn i150_row(writer : @persist.InMemoryTableWriter, exec : @exec.Execution) -> Bool {
  writer.get_row_by_key("expense", "process_instance_id", exec.process_instance.instance_id) is Some(_)
}

///|
/// ②-1 缺省档：没写 persistMode 但声明了拦截器 ⇒ 按 ARCHIVE 走（办结+同意落一行）
async test "i150 archive is the default when persistMode is absent" {
  let (_provider, writer, itc) = make_persist_fixture()
  let exec = make_persist_exec(i150_flow("", true), i150_vars(), state=20, node_id="end")
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  assert_true(i150_row(writer, exec))
}

///|
/// ②-2 未知值档：认不出的模式 ⇒ 回落 ARCHIVE 且**不报错**（spec 明写"未知值不报错，保持向后兼容"）
async test "i150 unknown persistMode falls back to archive without raising" {
  let (_provider, writer, itc) = make_persist_fixture()
  let exec = make_persist_exec(i150_flow("BOGUS", true), i150_vars(), state=20, node_id="end")
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  assert_true(i150_row(writer, exec))
}

///|
/// ②-3 大小写档：`sync` 小写仍进 SYNC 臂（发起态就落库；java 用 equalsIgnoreCase）
async test "i150 lowercase sync still takes the sync arm" {
  let (_provider, writer, itc) = make_persist_fixture()
  let exec = make_persist_exec(i150_flow("sync", true), i150_vars(), state=10, node_id="apply")
  itc.intercept(exec)
  assert_true(i150_row(writer, exec))
}

///|
/// opt-in 守卫 ＋ 阳性对照：同一条流（连 persistMode 都写着 ARCHIVE），没声明 postInterceptors ⇒
/// 一行都不写。这一档同时证明②-1 不是"恒写"造出来的假绿——把声明摘掉，写与不写立刻分家。
async test "i150 undeclared flow never persists (positive control)" {
  let (_provider, writer, itc) = make_persist_fixture()
  let exec = make_persist_exec(i150_flow("ARCHIVE", false), i150_vars(), state=20, node_id="end")
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  assert_true(!i150_row(writer, exec))
  assert_eq(writer.get_table_rows("expense").length(), 0)
  // SYNC 档也一样不写（守卫排在模式分派之前）
  let (_p2, w2, itc2) = make_persist_fixture()
  let exec2 = make_persist_exec(i150_flow("SYNC", false), i150_vars(), state=10, node_id="apply")
  itc2.intercept(exec2)
  assert_eq(w2.get_table_rows("expense").length(), 0)
}

///|
/// 节点级声明同样算 opt-in（java `NodeModel.java:56-62` 的先节点级、空回落流程级）
async test "i150 node level declaration opts in too" {
  let (_provider, writer, itc) = make_persist_fixture()
  let flow =
    "{\"name\": \"p\", \"displayName\": \"P\", \"type\": \"approval\", \"relTableName\": \"expense\", \"nodes\": [" +
    "{\"id\": \"apply\", \"type\": \"snaker:task\", \"text\": {\"value\": \"A\"}}, " +
    "{\"id\": \"end\", \"type\": \"snaker:end\", \"text\": {\"value\": \"E\"}, " +
    "\"properties\": {\"postInterceptors\": \"com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor\"}}" +
    "], \"edges\": []}"
  let exec = make_persist_exec(flow, i150_vars(), state=20, node_id="end")
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  assert_true(i150_row(writer, exec))
}
