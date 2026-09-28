// issues/126 案 A · 任务行 expire_time 的**引擎级写点**用例（内存仓通道，黑盒 async test）。
//
// 形状照 java 参考实现 `ExpireTimeOnCreateTest`（d9e9397）＋ `JeeflowFacadeTest` 那两格（cb541d4）：
//   T0 四格＝①配 "2h" ⇒ **同一行** expire − create ≈ 2h ②表达式是变量名 ⇒ 取该变量的值
//            ③未配（缺键 / null / 空串 / 纯空白 四态）⇒ NULL ④解析不出 ⇒ NULL 而不是 now
//   §1.8 两格＝串行会签**首成员 ∧ 推进出的第二成员**都带到期 ∧ 同夹具去掉表达式后两行都留空
//            （"行没读到"与"值为空"**分开断**，否则那条负向恒真）
// 再补三处写点各自的格子（并行全员 / 回退新建 / 回退的变量源），因为本栈五个写点是**五个不同
// 代码路径**（三个在 create_task_with_assignment、一个在 execute_task_async 的串行推进支、
// 一个在 rollback_to_parent 直建的那份行）——只测一处等于其余四处没牙。
//
// 判据一律落**仓储读回值**（find_history_tasks），不认引擎返回的聚合副本：issues/113 教训，
// 只有读回值能证明"这一列真进了库"。
//
// 夹具用内联 JSON（照 compliance_test.mbt `simple_flow_json` 的既有惯例），**不新增 flows/ 文件**：
// 每个格子自带完整 properties，不做"基础片段+覆盖"，免 JSON 同名键后者胜的隐式行为。
// ⚠️ 只新增断言，没动任何既有断言的期望值（含 surrogate_test.mbt 条款 1.3）。

///|
/// 线性流夹具：start → specs 逐个任务节点 → end。spec = (节点 id, **完整** properties 片段)。
fn exp_flow(name : String, specs : Array[(String, String)]) -> String {
  let b = StringBuilder()
  b.write_string(
    "{\"name\":\"" + name + "\",\"displayName\":\"到期时间建单\",\"type\":\"approval\",\"nodes\":[",
  )
  b.write_string(
    "{\"id\":\"start\",\"type\":\"snaker:start\",\"properties\":{},\"text\":{\"value\":\"开始\"}}",
  )
  for (id, props) in specs {
    b.write_string(
      ",{\"id\":\"" + id + "\",\"type\":\"snaker:task\",\"properties\":{" + props + "},\"text\":{\"value\":\"" + id + "\"}}",
    )
  }
  b.write_string(
    ",{\"id\":\"end\",\"type\":\"snaker:end\",\"properties\":{},\"text\":{\"value\":\"结束\"}}],\"edges\":[",
  )
  let ids : Array[String] = ["start"]
  for (id, _) in specs {
    ids.push(id)
  }
  ids.push("end")
  let edge_n = ids.length() - 1
  for i in 0..<edge_n {
    if i > 0 {
      b.write_string(",")
    }
    b.write_string(
      "{\"id\":\"e" + i.to_string() + "\",\"sourceNodeId\":\"" + ids[i] + "\",\"targetNodeId\":\"" + ids[i + 1] + "\",\"properties\":{}}",
    )
  }
  b.write_string("]}")
  b.to_string()
}

///|
fn exp_data(entries : Array[(String, String)]) -> @json.FlowData {
  let a = @json.FlowData::new()
  for (k, v) in entries {
    a.insert_str(k, v)
  }
  a
}

///|
/// 发起并办结 apply（两段提交参数可分别带），返回实例 id。
/// 不用 compliance_test.mbt 的 `start_and_apply`：那格的 args 恒空，本案"变量源两档"要能提交值。
async fn exp_start_apply(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  repo : @mem.MemoryRepository,
  did : Int64,
  start_args : @json.FlowData,
  apply_args : @json.FlowData
) -> Int64 raise {
  let inst = engine.start_async(did, "applicant", start_args)
  let apply = find_doing_for(repo, inst.instance_id, "applicant")
  let _ = engine.execute_task_async(apply.task_id, "applicant", apply_args)
  inst.instance_id
}

///|
/// 读回某节点、某参与者、**进行中**的那条行；没有 ⇒ None（调用方分开断"行没读到"与"值为空"）
async fn exp_doing_row(
  repo : @mem.MemoryRepository, iid : Int64, node : String, actor : String
) -> @model.ProcessTask? raise {
  let mut hit : @model.ProcessTask? = None
  for t in repo.find_history_tasks(iid) {
    if t.task_name == node && t.task_state == 10 && t.actor_ids.contains(actor) {
      hit = Some(t)
    }
  }
  hit
}

///|
fn exp_must(row : @model.ProcessTask?, label : String) -> @model.ProcessTask {
  match row {
    Some(r) => r
    // 这一句就是"行没读到"的独立判点：绝不能让它和"值为空"共用一个断言
    None => abort("\{label}：行没读到（是行本身不存在，不是这一列为空）")
  }
}

///|
/// 断"同一行 expire − create ≈ 表达式偏移"。**不许只判非空**：只判非空就会被占位 now()
/// 蒙过去（那正是本病灶的形状，java 真镜像实测差值 0s）。
/// 带宽 [-5s, +60s]：本栈这一列只到秒（format_unix_utc），落秒量纲在内、"根本没算"(≈0) 在外面；
/// 刻意不写 `>= 7200`——秒级 floor 会让它假红。
fn assert_expire_delta(row : @model.ProcessTask, want : Int64, label : String) -> Unit {
  let exp = match row.expire_time {
    Some(v) => v
    None => abort("\{label}：配了到期表达式，expire_time 却是空")
  }
  let ct = match row.create_time {
    Some(v) => v
    None => abort("\{label}：对照失败——该行 create_time 也空，差值无从判（说明根本没走到建单）")
  }
  let es = match @model.parse_time_secs(exp) {
    Some(v) => v
    None => abort("\{label}：expire_time 不是合法时刻串：\{exp}")
  }
  let cs = match @model.parse_time_secs(ct) {
    Some(v) => v
    None => abort("\{label}：create_time 不是合法时刻串：\{ct}")
  }
  let d = es - cs
  if d < want - 5L || d > want + 60L {
    abort("\{label}：expire − create = \{d}s，期望 \{want}s ∈[-5s,+60s]；算出≈0 就是占位 now()（新建即逾期）")
  }
}

///|
/// 断"这行真读到了、create_time 有值、而 expire_time 必须为空"——三件事分开断。
fn assert_expire_null(row : @model.ProcessTask, label : String) -> Unit {
  match row.create_time {
    None => abort("\{label}：对照失败——create_time 也空，说明这行根本没建出来")
    Some(_) => ()
  }
  match row.expire_time {
    None => ()
    Some(v) => abort("\{label}：节点没配（或配了算不出的）表达式，这一列却有值 \{v} ⇒ 造了默认值")
  }
}

///|
/// 断"这一列必须正好等于某个时刻串"（变量档用：值来自变量而不是偏移，没有量纲带宽可言）
fn assert_expire_eq(row : @model.ProcessTask, want : String, label : String) -> Unit raise {
  match row.expire_time {
    Some(v) => assert_eq(v, want)
    None => abort("\{label}：期望 \{want}，实得 NULL")
  }
}

// ─── T0 四格 ──────────────────────────────────────────────────────────────────

///|
async test "i126-t1 写点①普通建单：配 2h ⇒ 同一行 expire − create ≈ 2h" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(
    repo, "i126_t1", exp_flow("i126_t1", [
      ("apply", "\"assignee\":\"applicant\""),
      ("approve", "\"assignee\":\"boss\",\"expireTime\":\"2h\""),
    ]),
  )
  let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
  let row = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "T0① approve")
  assert_expire_delta(row, 7200L, "T0① 普通建单（2h）")
}

///|
async test "i126-t2 写点①变量名档：表达式是实例变量名 ⇒ 取该变量的值" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(
    repo, "i126_t2", exp_flow("i126_t2", [
      ("apply", "\"assignee\":\"applicant\""),
      ("approve", "\"assignee\":\"boss\",\"expireTime\":\"deadline\""),
    ]),
  )
  // 变量从**发起参数**进来 ⇒ ProcessInstance::create 已把它并入实例变量（建单三处的变量源档）
  let iid = exp_start_apply(
    engine, repo, did, exp_data([("deadline", "2030-05-06 07:08:09")]), @json.FlowData::new(),
  )
  let row = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "T0② approve")
  assert_expire_eq(row, "2030-05-06 07:08:09", "T0② 变量名档取变量值")
}

///|
async test "i126-t3 未配四态（缺键 / null / 空串 / 纯空白）⇒ 该行存在而这一列为空" {
  let (engine, repo) = make_compliance_engine()
  let mut n = 0
  for (props, why) in [
    ("\"assignee\":\"boss\"", "缺 expireTime 键"),
    ("\"assignee\":\"boss\",\"expireTime\":null", "配成 JSON null"),
    ("\"assignee\":\"boss\",\"expireTime\":\"\"", "配成空串"),
    ("\"assignee\":\"boss\",\"expireTime\":\"   \"", "配成纯空白"),
  ] {
    let name = "i126_t3_" + n.to_string()
    n = n + 1
    let did = save_flow_define(
      repo, name, exp_flow(name, [
        ("apply", "\"assignee\":\"applicant\""),
        ("approve", props),
      ]),
    )
    let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
    let row = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "T0③ " + why)
    assert_expire_null(row, "T0③ " + why)
  }
}

///|
async test "i126-t4 表达式解析不出 ⇒ 列为空，而不是退化成 now（含误配 xh 落穿档）" {
  let (engine, repo) = make_compliance_engine()
  let mut n = 0
  for expr in [
    "not-a-time", "xh", "2h30m", "2031-03-04", "2031-02-30 00:00:00",
  ] {
    let name = "i126_t4_" + n.to_string()
    n = n + 1
    let did = save_flow_define(
      repo, name, exp_flow(name, [
        ("apply", "\"assignee\":\"applicant\""),
        ("approve", "\"assignee\":\"boss\",\"expireTime\":\"" + expr + "\""),
      ]),
    )
    let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
    let row = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "T0④ " + expr)
    assert_expire_null(row, "T0④ expr=" + expr)
  }
}

// ─── §1.8 两格（第五处写点＝串行会签推进出的下一位成员）───────────────────────

///|
async test "i126-t5 §1.8 格1：串行会签首成员 ∧ 推进出的第二成员都带到期" {
  let (engine, repo) = make_compliance_engine()
  let cs = "\"assignee\":\"userA,userB\",\"performType\":1,\"countersignType\":\"SEQUENTIAL\",\"expireTime\":\"2h\""
  let did = save_flow_define(
    repo, "i126_t5", exp_flow("i126_t5", [
      ("apply", "\"assignee\":\"applicant\""),
      ("cs", cs),
    ]),
  )
  let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
  // 写点②：串行会签**首位成员**（create_countersign_tasks 只建第一人）
  let first = exp_must(exp_doing_row(repo, iid, "cs", "userA"), "§1.8 首成员")
  assert_expire_delta(first, 7200L, "§1.8 首成员（写点②）")

  let args = @json.FlowData::new()
  args.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(first.task_id, "userA", args)
  // 写点④＝§1.8 更正补的那一处：这一支绕过建单 helper 直建下一位成员 ⇒ 必须自己上尺子
  let second = exp_must(exp_doing_row(repo, iid, "cs", "userB"), "§1.8 推进出的第二成员")
  assert_expire_delta(second, 7200L, "§1.8 第二成员（写点④·串行推进位）")
}

///|
async test "i126-t6 §1.8 格2：同夹具去掉 expireTime ⇒ 两行都留空（行没读到 / 值为空 分开断）" {
  let (engine, repo) = make_compliance_engine()
  let cs = "\"assignee\":\"userA,userB\",\"performType\":1,\"countersignType\":\"SEQUENTIAL\""
  let did = save_flow_define(
    repo, "i126_t6", exp_flow("i126_t6", [
      ("apply", "\"assignee\":\"applicant\""),
      ("cs", cs),
    ]),
  )
  let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
  let first = exp_must(exp_doing_row(repo, iid, "cs", "userA"), "§1.8 未配·首成员")
  assert_expire_null(first, "§1.8 未配·首成员")
  let args = @json.FlowData::new()
  args.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(first.task_id, "userA", args)
  // 先断"第二成员这行真读到了"（否则"值为空"那条恒真，等于没测）
  let second = exp_must(exp_doing_row(repo, iid, "cs", "userB"), "§1.8 未配·第二成员")
  assert_expire_null(second, "§1.8 未配·第二成员")
}

// ─── 其余写点各钉一格（并行全员 / 回退新建 / 回退的变量源）───────────────────

///|
async test "i126-t7 写点③并行会签全员：两条成员行各按自己那行的 create 算 ≈2h" {
  let (engine, repo) = make_compliance_engine()
  let cs = "\"assignee\":\"userA,userB\",\"performType\":1,\"countersignType\":\"PARALLEL\",\"expireTime\":\"2h\""
  let did = save_flow_define(
    repo, "i126_t7", exp_flow("i126_t7", [
      ("apply", "\"assignee\":\"applicant\""),
      ("cs", cs),
    ]),
  )
  let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
  // 本栈 else 支同时承载 PARALLEL 与"未识别会签类型"（对齐 go 的 default 档），两条成员一次建齐
  for actor in ["userA", "userB"] {
    let row = exp_must(exp_doing_row(repo, iid, "cs", actor), "写点③ " + actor)
    assert_expire_delta(row, 7200L, "写点③ 并行会签全员（" + actor + "）")
  }
}

///|
async test "i126-t8 写点⑤回退新建：按被回退掉的节点的表达式**重算**（不是抄上一行）" {
  let (engine, repo) = make_compliance_engine()
  // 两个节点配**不同**偏移：复活行取哪个节点，差值就露馅（30m 是"抄上一行/取历史节点"的形状）
  let did = save_flow_define(
    repo, "i126_t8", exp_flow("i126_t8", [
      ("apply", "\"assignee\":\"applicant\",\"expireTime\":\"30m\""),
      ("approve", "\"assignee\":\"boss\",\"expireTime\":\"2h\""),
    ]),
  )
  let iid = exp_start_apply(engine, repo, did, @json.FlowData::new(), @json.FlowData::new())
  let boss = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "写点⑤ 前置·当前行")
  assert_expire_delta(boss, 7200L, "写点⑤ 前置·当前行（approve 2h）")

  let _ = engine.execute_and_jump_async(boss.task_id, "boss", @json.FlowData::new(), None)
  let revived = exp_must(exp_doing_row(repo, iid, "apply", "applicant"), "写点⑤ 复活行")
  assert_expire_delta(revived, 7200L, "写点⑤ 回退新建（取**当前节点** 2h，非上一行的 30m）")
}

///|
async test "i126-t9 变量源两档对撞：建单读实例变量、回退新建读随行拷贝那份" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(
    repo, "i126_t9", exp_flow("i126_t9", [
      ("apply", "\"assignee\":\"applicant\""),
      ("approve", "\"assignee\":\"boss\",\"expireTime\":\"dueAt\""),
    ]),
  )
  // dueAt 只在**办结 apply 时**提交：complete_task_in_aggregate 只把 f_ 前缀回写实例变量，
  // 所以它活在 apply 那行的任务变量里、不在实例变量里 ⇒ 两档给出不同答案，正是本案要的判点。
  let iid = exp_start_apply(
    engine, repo, did, @json.FlowData::new(), exp_data([("dueAt", "2031-07-08 09:10:11")]),
  )
  let boss = exp_must(exp_doing_row(repo, iid, "approve", "boss"), "写点① 建单档")
  assert_expire_null(boss, "建单档＝实例变量（dueAt 不在实例变量里 ⇒ 该列留空）")

  let _ = engine.execute_and_jump_async(boss.task_id, "boss", @json.FlowData::new(), None)
  let revived = exp_must(exp_doing_row(repo, iid, "apply", "applicant"), "写点⑤ 复活行")
  assert_expire_eq(revived, "2031-07-08 09:10:11", "回退档＝随行拷贝那份变量（boot2 hisVariable）")
}
