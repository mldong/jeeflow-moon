// 「SYNC 的 `tf_` 去前缀冗余写业务列」这条腿的**引擎级**用例（spec/04「实例变量只收数据类键」
// 末注的连带条款；＝java `jeeflow-persist` 的 `testSyncModeFullCycle` 同位）。
//
// 为什么单开一个引擎级文件、而不靠 persist_test.mbt／i152 那批拦截器直调用例：
//   后加签根因收口（java `31f43b0`，本栈随 `296872d` 落）之后，`complete_task` 只把 `f_`
//   并进实例变量（`core/model/aggregate.mbt::complete_task`），`tf_*` 从此不再进实例变量。
//   而这条腿原先的读源正是实例变量 ⇒ **静默断了**：业务表那一列落空，不写断言就不响。
//   拦截器直调的夹具是自己往 `instance.variables` 塞 `tf_` 喂出来的绿——真流程根本不长那样。
//   这里改成走引擎：办理提交带 `tf_`，断言业务表列值＝本次提交的那份，并顺手钉住
//   「实例变量里压根没有这枚 `tf_` 键」，让断言没有第二条通路可走。
//
// 读源判据（与 java 同形，不是随手挑的）：本栈 `exec.args`＝「实例变量 ← 任务行变量 ←
// 本次提交参数」（`core/engine/engine_ops.mbt::load_exec_for_task`），与 java
// `JeeflowEngineImpl.prepareExecution` 里 `exec.setArgs(mergedArgs)` 那份是同一枚合并序。

///|
/// 三节点 SYNC 流程：start → apply(applicant) → approval(approver) → end，
/// 根级声明 persist 后置拦截器（节点级不声明 ⇒ 回落根档，r91 那条判据）。
let tf_engine_flow : String =
  $|{"name": "tf-engine", "displayName": "TFE", "type": "approval",
  $| "persistMode": "SYNC", "relTableName": "sync_engine",
  $| "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
  $| "nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|  {"id": "approval", "type": "snaker:task", "text": {"value": "审批"},
  $|   "properties": {"assignee": "approver", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "approval"},
  $|  {"id": "e3", "sourceNodeId": "approval", "targetNodeId": "end"}
  $| ]}

///|
/// 业务表：`audit_note` 这一列只有 `tf_` 那一档写得到（没有对应的 `f_` 键），
/// 所以它就是这条腿的哨兵列。
fn tf_engine_meta() -> @persist.InMemoryMetaProvider {
  let provider = @persist.InMemoryMetaProvider::new()
  let meta = @persist.TableMeta::make("sync_engine", "引擎级 SYNC 夹具")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
  meta.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
  meta.add_field(@persist.FieldMeta::make("amount", "DECIMAL", "金额"))
  meta.add_field(@persist.FieldMeta::make("remark", "VARCHAR(200)", "备注"))
  meta.add_field(@persist.FieldMeta::make("audit_note", "VARCHAR(200)", "任务档哨兵列"))
  meta.add_field(@persist.FieldMeta::make("apply_10", "INT", "申请节点状态"))
  meta.add_field(@persist.FieldMeta::make("approval_10", "INT", "审批节点状态"))
  meta.add_field(@persist.FieldMeta::make("end_20", "INT", "结束定稿状态"))
  provider.register(meta)
  provider
}

///|
/// 装配：内存仓 + ID 发生器 + 按名注册 persist 后置拦截器（声明档存在时引擎只查命名表，
/// 装配方两头都要给——见 `persist/interceptor.mbt::persist_interceptor_declared` 注释）。
async fn tf_engine_setup() -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
  @persist.InMemoryTableWriter,
  Int64
) raise {
  let repo = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  let provider = tf_engine_meta()
  let writer = @persist.InMemoryTableWriter::new()
  let itc = @persist.PersistPostInterceptor::make(provider, writer)
  ctx.register_named_interceptor(@persist.PERSIST_CLASS_NAME, itc.as_interceptor())
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "tf-engine",
    display_name: "引擎级 SYNC 夹具",
    define_type: "approval",
    state: 1,
    content: tf_engine_flow,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  (@engine.Engine::make(ctx), repo, writer, define_info.id)
}

///|
/// 提交参数：submitType + 若干枚本次提交的键
fn tf_submit(submit_type : Int64, pairs : Array[(String, String)]) -> @json.FlowData {
  let args = @json.FlowData::new()
  args.insert_i64("submitType", submit_type)
  for _, kv in pairs {
    let (k, v) = kv
    args.insert_str(k, v)
  }
  args
}

///|
async fn tf_doing_task(
  repo : @mem.MemoryRepository,
  iid : Int64,
  node_name : String
) -> @model.ProcessTask raise @error.JeeflowError {
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == node_name {
      return t
    }
  }
  raise @error.Business("前置条件：待办里没有节点 " + node_name)
}

///|
/// 取业务表那一行；行不存在给空表 ⇒ 下面每一枚断言自然报红并自带归因文案
/// （不用 `abort`：它整进程退出，会把同包其它用例的结果一起带走）
fn tf_row(writer : @persist.InMemoryTableWriter, iid : Int64) -> Map[String, Json] {
  match writer.get_row_by_key("sync_engine", "process_instance_id", iid) {
    Some(r) => r
    None => Map([])
  }
}

///|
/// 断言带归因文案（`abort` 会整进程退出、把同包其它用例的结果一起带走，这里用
/// `assert_true` 让 runner 出干净的 FAILED 一行，文案走 println）
fn tf_check(cond : Bool, label : String) -> Unit raise {
  if !cond {
    println("[tf_ 冗余腿引擎级] 红样：" + label)
    assert_true(false)
  }
}

///|
/// ① 主判据（这条腿断过的那一格）：办理提交带 `tf_audit_note` ⇒ 业务表 `audit_note`
///    落的必须是**本次提交**的值；同时钉死实例变量里没有这枚 `tf_` 键 ⇒ 断言只有
///    "读当次提交那一趟"这一条通路可满足（读实例变量必然拿不到值）。
/// ② 第二趟换节点再提交一个不同值 ⇒ 列跟着换（不是上一轮的值留在原地）。
/// ③ 定稿腿（非任务节点）只写状态列，不拿任何东西覆盖 `audit_note`。
async test "tf_ 冗余腿：SYNC 办理提交的 tf_ 落业务表列（引擎级，读源＝当次提交）" {
  let (engine, repo, writer, define_id) = tf_engine_setup()
  // 发起：只给表单数据（f_ 档），不给 tf_
  let start_args = @json.FlowData::new()
  start_args.insert_str("f_amount", "88")
  start_args.insert_str("f_remark", "发起备注")
  let inst = engine.start_async(define_id, "applicant", start_args)
  let iid = inst.instance_id
  // ① 办结 apply：本次提交带 tf_audit_note
  let ta = tf_doing_task(repo, iid, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", tf_submit(0L, [
    ("tf_audit_note", "申请人本次提交"),
  ]))
  let inst1 = repo.find_instance_by_id(iid).unwrap()
  tf_check(
    inst1.variables.get_str("tf_audit_note") is None,
    "根因守卫：tf_audit_note 不该进实例变量（进了下面这条断言就有第二条通路）"
  )
  let r1 = tf_row(writer, iid)
  tf_check(cell_of(r1.get("audit_note")) == "申请人本次提交", "audit_note＝本次提交的值（实际 \{cell_of(r1.get("audit_note"))}）")
  // f_ 档照旧从实例变量取到（发起那趟的表单数据在办结 apply 时落列）
  tf_check(cell_of(r1.get("remark")) == "发起备注", "f_ 档仍读实例变量（remark 落发起值）")
  tf_check(writer.get_table_rows("sync_engine").length() == 1, "SYNC 全程一条行（先插后更）")
  // ② 办结 approval：换一个值 ⇒ 列跟着换
  let tp = tf_doing_task(repo, iid, "approval")
  let _ = engine.execute_task_async(tp.task_id, "approver", tf_submit(1L, [
    ("tf_audit_note", "审批人本次提交"),
  ]))
  let inst2 = repo.find_instance_by_id(iid).unwrap()
  tf_check(
    inst2.variables.get_str("tf_audit_note") is None,
    "根因守卫：第二趟之后实例变量依旧没有 tf_audit_note"
  )
  let r2 = tf_row(writer, iid)
  tf_check(
    cell_of(r2.get("audit_note")) == "审批人本次提交",
    "audit_note＝第二趟本次提交的值，不是上一轮留下的（实际 \{cell_of(r2.get("audit_note"))}）"
  )
  // ③ 流转到结束：定稿腿写 end_20，不覆盖 audit_note
  let r3 = tf_row(writer, iid)
  tf_check(@json.as_i64(r3.get("end_20").unwrap()) == Some(20L), "定稿写 end_20=20")
  tf_check(cell_of(r3.get("audit_note")) == "审批人本次提交", "定稿腿不覆盖 tf_ 那一档写的列")
  tf_check(writer.get_table_rows("sync_engine").length() == 1, "定稿后仍是一条行")
}
