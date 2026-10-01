// issues/137 A · 批二 §3-4 moon 腿 —— **实例级** expire_time ＝定义级表达式的**求值结果**（裁定 A）。
//
// 被测两处写点（issues/137 §A 原文写「两处同形」，本栈复锚后落在同一文件的**两个发起路径**上，
// 都是实例级、都是原串搬运；案文里那句「`:644` 是任务级回退写点」不成立——任务级回退写在
// `engine_ops.mbt:629-634`（本轮改后行号，改前 613-618），那一处早就走 @model.apply_expire_time 求值，不在本案整改面内）：
//   · 主发起 `start_async`：修前 engine_ops.mbt:27-30 ⇒ 改后落点 :43-46
//   · 带父实例发起 `start_with_parent_async`（子流程腿）：修前 :643-646 ⇒ 改后落点 :663-666
// 修前形状＝**原串搬运** `Some(et) => instance.expire_time = Some(et)`：把 `"2h"` 这类**表达式原文**
// 写进 wf_process_instance.expire_time（datetime 列）。落库绑定点在
// repository-mysql/repo/repository.mbt:168 `opt_v(instance.expire_time)`——原串直进 datetime 参数，
// 160 那台 `@@sql_mode` 含 STRICT_TRANS_TABLES ⇒ 服务端给的是 **1292 / SQLSTATE 22007
// `Incorrect datetime value: '2h' for column 'expire_time'`**（兄弟栈 rust/php 本轮实测；案文原写的
// 1366 已被实测更正），比"留 NULL"更糟：整条发起 INSERT 直接失败。
//
// 基准＝java `JeeflowEngineImpl.java:93-96`（取定义顶层 `model.getExpireTime()`，**非空才**
// `instance.setExpireTime(FlowUtil.processTime(expireTime, args))`）＋ boot2
// `ProcessInstanceServiceImpl.java:157-160` 同形状（先判非空再写）。定义级表达式的解析点是
// `core/parser/parser.mbt:370` `@json.get_str(root, "expireTime")`（spec/02「流程期望完成时间」）。
// **尺子复用本栈既有那一枚** `@model.process_time`（issues/126 案 A 移植、任务级四处写点已在用），
// 不新造第二把。
//
// 五格判据（全部打在**值**上：具体时刻串 / None，不做"非空"空判）：
//   判据1 写进去的是求值结果不是原串：配 "2h" ⇒ 钉钟后**正好等于** base+2h 那一刻，且 ≠ 原串、
//          且能被 parse_time_secs 解析（＝有进 datetime 列的资格）
//   判据2 求值的 args＝**发起参数**那份：①表达式是发起时提交的变量名 ⇒ 取该变量的值
//          ②表达式是 `u_realName`——raw args 里**没有**这个键，只有 `add_user_info` 注入之后那份才有
//          ⇒ 传错那份（raw args）就红，这一格是有牙的
//   判据3 定义**没配**顶层 expireTime（缺键 / JSON null / 空串 / 纯空白 四态）⇒ 该列 NULL，
//          不赋 now()、不赋空串（"行读回来 / create_time 有值 / 该列为空"三件事分开断）
//   判据4 配了但**算不出**（误配 / 负数档 §3-2 / 裁空白边界 §3-3）⇒ NULL，沿用已定的落穿语义，
//          不许兜底 now
//   判据5 **复用同一把尺子**：实例列逐档 == `@model.process_time(同一表达式, 同一份变量)` 的输出
//
// 真库腿（把值真塞进 datetime 列再读回来）本机跑不了：native 编译要 cc、wasm 档无 socket，
// 且 `JEFFLOW_DB_*` 凭据不入本仓（见 MAINTAINING.md「公开 clone 的读者到这儿没有现成凭据可抄」）
// ⇒ 留给 §4 门禁轮。**本文件的格子守的是"列上的值本身是不是合法时刻串/是否为空"**，
// 那正是原串搬运在真库上炸掉的那个量。
//
// 夹具用内联 JSON（照同包 expire_time_test.mbt `exp_flow` 的既有惯例，**不新增 flows/ 文件**），
// 但根上多一个 `expireTime` 槽——这一列挂在**流程定义顶层**，不在节点 properties 里。
// ⚠️ 只新增文件与格子，没有动任何既有断言的期望值。

///|
/// 实例级夹具：root_extra 传**自带逗号**的根上片段（`,"expireTime":"2h"`），传 `""` ＝根上没这个键。
/// 节点片段与 exp_flow 同形（properties 里**不带** expireTime：任务级那一列由 issues/126 的
/// 另一组格子守，这里读的是**实例行**，两条写点必须分开钉）。
fn iexp_flow(name : String, root_extra : String, specs : Array[(String, String)]) -> String {
  let b = StringBuilder()
  b.write_string(
    "{\"name\":\"" + name + "\",\"displayName\":\"实例级到期\"" + root_extra + ",\"type\":\"approval\",\"nodes\":[",
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
/// 发起，返回实例 id。判据一律落**仓储读回值**（`find_instance_by_id`），不认引擎返回的聚合副本：
/// issues/113 教训，只有读回值能证明"这一列真进了库"。
async fn iexp_start(
  engine : @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  did : Int64,
  operator : String,
  args : @json.FlowData
) -> Int64 raise {
  let inst = engine.start_async(did, operator, args)
  inst.instance_id
}

///|
/// 实例行读回。**行没读到**与**这一列为空**分开断（后者是恒真陷阱）。
/// `find_instance_by_id` 在 SPI 里是 `async fn ... raise`（core/spi/repository.mbt:30）⇒ 本函数同档。
async fn iexp_must_row(
  repo : @mem.MemoryRepository, iid : Int64, label : String
) -> @model.ProcessInstance raise {
  match repo.find_instance_by_id(iid) {
    Some(i) => i
    None => fail("\{label}：实例行没读回来（是行本身不存在，不是这一列为空）")
  }
}

///|
/// "值档"断言（判据1/2/5/6 共用）：这一列必须是**求出来的时刻串**且正好等于 want。
/// 四件事逐条断：①不是 None ②不是表达式原串（原串出现在列上＝修前形状）③是合法时刻串
/// （＝有进 datetime 列的资格，真库 STRICT_TRANS_TABLES 的判点）④等于 want（钉钟下精确等号，
/// 不留带宽——带宽会被"根本没算/兜底 now"两种红样同时躲过去）。
/// ②只在 want ≠ 原串时才是**有信息量**的判点：绝对档（`"2030-12-31 23:59:59"`）求值结果与表达式
/// 同一串，此时"搬原串"与"求值"不可区分，刻意不判——不是放水，是那格本来就抓不到东西。
fn iexp_expire_eq(
  row : @model.ProcessInstance, want : String, raw_expr : String, label : String
) -> Unit raise {
  match row.expire_time {
    None => fail("\{label}：期望 \{want}，实得 NULL")
    Some(v) => {
      if v == raw_expr && want != raw_expr {
        fail(
          "\{label}：列上是**表达式原串** \{v}，不是求值结果 ⇒ 真库 datetime 列上这条 INSERT 是 1292/22007 Incorrect datetime value",
        )
      }
      match @model.parse_time_secs(v) {
        None => fail("\{label}：列上值 \{v} 不是「yyyy-MM-dd HH:mm:ss」合法时刻串，进不了 datetime 列")
        Some(_) => ()
      }
      assert_eq(v, want)
    }
  }
}

///|
/// "空档"断言（判据3/4/6 共用）：三件事**分开断**——①create_time 有值（否则说明根本没走到建单，
/// "该列为空"那条恒真）②这一列必须正好是 None。实得值抄进失败信息：兜底 now() 的红样要一眼看出
/// 算出来的是哪一刻。
fn iexp_expire_null(row : @model.ProcessInstance, label : String) -> Unit raise {
  match row.create_time {
    None => fail("\{label}：对照失败——create_time 也空，说明这一行根本没建出来")
    Some(_) => ()
  }
  match row.expire_time {
    None => ()
    Some(v) =>
      fail("\{label}：定义没配（或配了算不出）的表达式，实例这一列却有值 \{v} ⇒ 造了默认值/搬了原串")
  }
}

// ─── 判据 1：写进去的是求值结果，不是原串 ─────────────────────────────────────

///|
async test "i137a-1 判据1 主发起：定义顶层配相对档 2h ⇒ 实例列是 base+2h 那一刻，不是原串 2h" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "i137a_c1", iexp_flow("i137a_c1", ",\"expireTime\":\"2h\"", [
    ("apply", "\"assignee\":\"applicant\""),
  ]))
  let iid = iexp_start(engine, did, "applicant", @json.FlowData::new())
  let row = iexp_must_row(repo, iid, "i137a-1")
  // 精确到秒：钉钟 ⇒ create=10:00:00、expire=12:00:00，没有带宽可躲
  iexp_expire_eq(row, "2026-10-01 12:00:00", "2h", "判据1 相对档 2h")
  // 再钉"同一行 expire − create 恰好 2h"：占位 now()（差 0）与"根本没算"（NULL）都在这格外
  let es = match row.expire_time {
    Some(v) => @model.parse_time_secs(v).unwrap_or(-1L)
    None => -1L
  }
  let cs = match row.create_time {
    Some(v) => @model.parse_time_secs(v).unwrap_or(-1L)
    None => -1L
  }
  assert_eq(es - cs, 7200L)
}

// ─── 判据 2：求值的 args ＝ 发起参数（已注入用户信息的那份）──────────────────

///|
async test "i137a-2 判据2 求值的 args＝发起参数那份：提交的变量名 ∧ add_user_info 注入的键名都取得到" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  // ① 表达式是**发起时提交的变量名** ⇒ 取该变量的值（不是 now+偏移、更不是原串）
  let due_at = "2030-05-06 07:08:09"
  let did1 = save_flow_define(repo, "i137a_c2a", iexp_flow("i137a_c2a", ",\"expireTime\":\"dueAt\"", [
    ("apply", "\"assignee\":\"applicant\""),
  ]))
  let a1 = exp_data([("dueAt", due_at)])
  let iid1 = iexp_start(engine, did1, "applicant", a1)
  iexp_expire_eq(
    iexp_must_row(repo, iid1, "判据2①"), due_at, "dueAt", "判据2① 发起提交的变量名 dueAt",
  )
  // ② 表达式是 `u_realName`：这个键**只存在于 add_user_info 注入之后的那份 args**里
  //    （`engine.mbt:59-64` 注 u_userId/u_realName/…；raw 发起参数里没有）。
  //    operator 本身取成一个合法时刻串 ⇒ 注入值即它 ⇒ 实现若误传"未经注入的原始 args"，
  //    这一档落穿到相对/绝对档 ⇒ NULL ⇒ 本格红。这就是"args 是哪一份"的牙。
  let did2 = save_flow_define(
    repo, "i137a_c2b", iexp_flow("i137a_c2b", ",\"expireTime\":\"u_realName\"", [
      ("apply", "\"assignee\":\"applicant\""),
    ]),
  )
  let iid2 = iexp_start(engine, did2, due_at, @json.FlowData::new())
  iexp_expire_eq(
    iexp_must_row(repo, iid2, "判据2②"), due_at, "u_realName", "判据2② 已注入用户信息的那份 args",
  )
}

// ─── 判据 3：定义没配 ⇒ 该列保持 NULL（四态）─────────────────────────────────

///|
async test "i137a-3 判据3 定义没配顶层 expireTime（缺键/JSON null/空串/纯空白）⇒ 该列 NULL，不赋 now 不赋空串" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  let mut n = 0
  for (root_extra, why) in [
    ("", "根上缺 expireTime 键"),
    (",\"expireTime\":null", "配成 JSON null"),
    (",\"expireTime\":\"\"", "配成空串"),
    (",\"expireTime\":\"   \"", "配成纯空白"),
  ] {
    let name = "i137a_c3_" + n.to_string()
    n = n + 1
    let did = save_flow_define(repo, name, iexp_flow(name, root_extra, [
      ("apply", "\"assignee\":\"applicant\""),
    ]))
    let iid = iexp_start(engine, did, "applicant", @json.FlowData::new())
    let row = iexp_must_row(repo, iid, "i137a-3 " + why)
    iexp_expire_null(row, "判据3 " + why)
    // 单独钉"不是空串"这一形状（有的栈把缺配写成 ''，同样是错，且 NULL 断言放宽后抓不到）
    match row.expire_time {
      Some(v) => assert_eq(v == "", false)
      None => ()
    }
    // 也钉"没被赋成发起那一刻"：create_time 有值而 expire_time 必须与它不同判（None）
    assert_eq(row.create_time, Some("2026-10-01 10:00:00"))
  }
}

// ─── 判据 4：配了但算不出 ⇒ NULL（含 §3-2 判非负 / §3-3 裁空白边界）──────────

///|
async test "i137a-4 判据4 定义配了但算不出 ⇒ 该列 NULL，沿用落穿语义，不许兜底 now" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  let mut n = 0
  for expr in [
    "not-a-time",             // 三档全不命中
    "xh",                     // 相对档前缀非整数 ⇒ 落穿绝对档 ⇒ 失败（java 在此抛，本栈按 C# 落穿）
    "2h30m",                  // 复合档不认识
    "2031-03-04",             // 长度不够 19
    "2031-02-30 00:00:00",    // 严格日历校验不过（SimpleDateFormat 宽松档会滚到 3 月）
    "-5h",                    // §3-2 判非负：负前缀算解析不出来 ⇒ 落穿 ⇒ NULL
    "-5d",                    // 同上，d 档同一处判负
    " -5h",                   // §3-3 裁空白后再判负 ⇒ 仍 NULL
    "2h ",                    // §3-3 分界②：单位符判定用未 trim 的原串末位 ⇒ 落穿 ⇒ NULL
  ] {
    let name = "i137a_c4_" + n.to_string()
    n = n + 1
    let did = save_flow_define(repo, name, iexp_flow(name, ",\"expireTime\":\"" + expr + "\"", [
      ("apply", "\"assignee\":\"applicant\""),
    ]))
    let iid = iexp_start(engine, did, "applicant", @json.FlowData::new())
    let row = iexp_must_row(repo, iid, "i137a-4 " + expr)
    iexp_expire_null(row, "判据4 算不出 expr=" + expr)
  }
  // 正向对照（证明上面九格不是"任何表达式都留 NULL"的恒真）：同夹具配 2h 仍算出那一刻
  let plus_did = save_flow_define(
    repo, "i137a_c4_plus", iexp_flow("i137a_c4_plus", ",\"expireTime\":\"2h\"", [
      ("apply", "\"assignee\":\"applicant\""),
    ]),
  )
  let plus_iid = iexp_start(engine, plus_did, "applicant", @json.FlowData::new())
  iexp_expire_eq(
    iexp_must_row(repo, plus_iid, "i137a-4 对照"), "2026-10-01 12:00:00", "2h", "判据4 正向对照 2h",
  )
}

// ─── 判据 5：复用本栈既有那一枚求值器（不新造第二把尺子）─────────────────────

///|
async test "i137a-5 判据5 实例列逐档 == @model.process_time 的输出（s/m/h/d＋绝对档，同一把尺子）" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  let mut n = 0
  for (expr, want) in [
    ("45m", "2026-10-01 10:45:00"),
    ("90s", "2026-10-01 10:01:30"),
    ("2h", "2026-10-01 12:00:00"),
    // d 档走**日历加天**（不乘 86400 秒）：10-01 10:00 + 3 天 ⇒ 10-04 10:00
    ("3d", "2026-10-04 10:00:00"),
    // 绝对档：定义级表达式直接给"期望完成时刻"，规范化后回同一串（此档原串判点无信息量，
    // 见 iexp_expire_eq 的说明；仍钉字面期望 + 与求值器逐字相同）
    ("2030-12-31 23:59:59", "2030-12-31 23:59:59"),
  ] {
    let name = "i137a_c5_" + n.to_string()
    n = n + 1
    let did = save_flow_define(repo, name, iexp_flow(name, ",\"expireTime\":\"" + expr + "\"", [
      ("apply", "\"assignee\":\"applicant\""),
    ]))
    let iid = iexp_start(engine, did, "applicant", @json.FlowData::new())
    let row = iexp_must_row(repo, iid, "i137a-5 " + expr)
    // 先钉字面期望（打在值上，精确等号）
    iexp_expire_eq(row, want, expr, "判据5 档 \{expr}")
    // 再钉"与既有求值器逐字相同"：变量源用**实例自己那份变量**（＝发起时合并进 full_args 的那份，
    // ProcessInstance::create 的 variables 就是它）⇒ 实现若另造一把尺子，这里就分叉
    assert_eq(row.expire_time, @model.process_time(Some(expr), row.variables))
  }
}

// ─── 第二处写点：带父实例发起（子流程腿）──────────────────────────────────────

///|
async test "i137a-6 第二处写点（start_with_parent_async 子流程腿）同形整改：配了求值、没配留 NULL" {
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  defer {
    @model.set_clock(None)
  }
  let (engine, repo) = make_compliance_engine()
  // ①配 "2h" ⇒ 求值结果（与主发起腿同一把尺子、同一个值）
  let did = save_flow_define(repo, "i137a_c6a", iexp_flow("i137a_c6a", ",\"expireTime\":\"2h\"", [
    ("apply", "\"assignee\":\"applicant\""),
  ]))
  let child = engine.start_with_parent_async(did, "user1", @json.FlowData::new(), 555L, "sub")
  iexp_expire_eq(
    iexp_must_row(repo, child.instance_id, "i137a-6①"),
    "2026-10-01 12:00:00",
    "2h",
    "判据6① 子流程发起（写点二）配 2h",
  )
  // ②没配 ⇒ NULL（两处写点都得守判据3，别只修主发起那一处）
  let did2 = save_flow_define(repo, "i137a_c6b", iexp_flow("i137a_c6b", "", [
    ("apply", "\"assignee\":\"applicant\""),
  ]))
  let child2 = engine.start_with_parent_async(did2, "user1", @json.FlowData::new(), 556L, "sub")
  iexp_expire_null(
    iexp_must_row(repo, child2.instance_id, "i137a-6②"), "判据6② 子流程发起·未配 ⇒ NULL",
  )
  // ③配了算不出 ⇒ NULL（同判据4 在该写点上的一份）
  let did3 = save_flow_define(
    repo, "i137a_c6c", iexp_flow("i137a_c6c", ",\"expireTime\":\"-5h\"", [
      ("apply", "\"assignee\":\"applicant\""),
    ]),
  )
  let child3 = engine.start_with_parent_async(did3, "user1", @json.FlowData::new(), 557L, "sub")
  iexp_expire_null(
    iexp_must_row(repo, child3.instance_id, "i137a-6③"), "判据6③ 子流程发起·负档落穿 ⇒ NULL",
  )
}
