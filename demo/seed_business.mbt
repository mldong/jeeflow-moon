// T003：业务数据种子 driver——引擎真实启动（startAndExecute + execute），不直插 repo。
// 矩阵 = 八语言共用 canonical（day-shift 已在 Rust demo 实测全绿，照 rust seed_business.rs 移植）：
// 16 进行中(state=10) + 9 已完成(advance 推到 state=20) + 8 委托。
// 8 用户 × 5 菜单（待办/已办/发起/抄送/委托）全覆盖。App::memory_only()/App::reset() 复跑。
// 表单种子：发起带 f_*（form_by_define）、办理带 tf_*（tf_by_form）——八栈同表同值同序，
// 前端「申请信息」「办理表单」开箱可回显。规则：f_* 先铺 extra 后铺；日期写死字面量；
// 字段名严禁裸 amount/finalAmount（决策表达式判定变量）。

///|
/// 种业务数据；失败逐条打日志不抛异常（demo 启动不被单条卡死）。
pub async fn seed_business(
  facade : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository]
) -> Unit raise {
  let mut ok_in = 0
  let mut ok_fin = 0
  let mut ok_surr = 0
  for row in in_progress_rows() {
    let resp = facade.flow("processDefine/startAndExecute", row_args(row.0, row.1, row.2))
    match sb_iid(resp) {
      Some(iid) => {
        // I14：发起后再办 leader、manager 两节点 → 停在 boss
        if row.0 == 2L && row.1 == "userA" {
          for actor in ["leader", "manager"] {
            match sb_todo_row(facade, actor, iid) {
              Some(t) => {
                let ex : Map[String, Json] = Map::new()
                ex["processTaskId"] = sb_field(t, "id")
                ex["operator"] = @json.string_of(actor)
                ex["submitType"] = @json.number_of(1L)
                with_task_form(ex, task_form_key(t))
                let _ = facade.flow("processTask/execute", ex)
              }
              None => println("[seed] I14 todoRow actor=\{actor} 未找到")
            }
          }
        }
        if row.3.length() > 0 {
          let cc : Map[String, Json] = Map::new()
          cc["processInstanceId"] = iid
          cc["operator"] = @json.string_of(row.1)
          cc["actorIds"] = str_array_json(row.3)
          let _ = facade.flow("processInstance/createCCInstance", cc)
        }
        ok_in = ok_in + 1
      }
      None => println("[seed] startAndExecute define=\{row.0} op=\{row.1} 失败")
    }
  }
  for row in finished_rows() {
    let resp = facade.flow("processDefine/startAndExecute", row_args(row.0, row.1, row.2))
    match sb_iid(resp) {
      Some(iid) => {
        let state = sb_advance(facade, iid)
        if state != 20L {
          println("[seed] FIN define=\{row.0} op=\{row.1} 终态=\{state}（期望 20）")
        }
        if row.3.length() > 0 {
          let cc : Map[String, Json] = Map::new()
          cc["processInstanceId"] = iid
          cc["operator"] = @json.string_of(row.1)
          cc["actorIds"] = str_array_json(row.3)
          let _ = facade.flow("processInstance/createCCInstance", cc)
        }
        ok_fin = ok_fin + 1
      }
      None => println("[seed] FIN startAndExecute define=\{row.0} op=\{row.1} 失败")
    }
  }
  for s in surrogates() {
    let args : Map[String, Json] = Map::new()
    args["operator"] = @json.string_of(s[0])
    args["surrogate"] = @json.string_of(s[1])
    args["processName"] = @json.string_of("")
    args["startTime"] = @json.string_of("2026-01-01 00:00:00")
    args["endTime"] = @json.string_of("2027-12-31 23:59:59")
    let resp = facade.flow("processSurrogate/save", args)
    if sb_code(resp) == 0L {
      ok_surr = ok_surr + 1
    } else {
      println("[seed] surrogate \{s[0]}->\{s[1]} 失败")
    }
  }
  println("[seedBusiness] done: in-progress \{ok_in}/16, finished \{ok_fin}/9, surrogates \{ok_surr}/8")
}

///|
/// 进行中 16 条：发起后停 state=10（I3/I15 冻结在决策/驳回前，I14 发起后再办两节点停 boss）
fn in_progress_rows()
  -> Array[(Int64, String, Map[String, Json], Array[String])] {
  let rows : Array[(Int64, String, Map[String, Json], Array[String])] = []
  rows.push((1L, "user1", Map::new(), ["userA", "userB"]))
  rows.push((2L, "user1", Map::new(), []))
  rows.push((3L, "userA", sb_extra([("amount", @json.number_of(500L))]), []))
  rows.push((4L, "manager", Map::new(), ["userC", "leader"]))
  rows.push((5L, "userB", Map::new(), []))
  rows.push((6L, "director", Map::new(), ["manager", "boss"]))
  rows.push((7L, "userC", Map::new(), ["user1"]))
  rows.push((1L, "boss", Map::new(), []))
  rows.push((12L, "user1", sb_extra([("deptLeader", @json.string_of("manager"))]), []))
  rows.push((12L, "userC", sb_extra([("deptLeader", @json.string_of("director"))]), []))
  rows.push((12L, "userB", sb_extra([("deptLeader", @json.string_of("user1"))]), []))
  rows.push((15L, "userA", Map::new(), ["boss"]))
  rows.push((14L, "leader", Map::new(), ["director", "userC"]))
  rows.push((2L, "userA", Map::new(), []))
  rows.push((10L, "userB", Map::new(), []))
  rows.push((8L, "user1", Map::new(), []))
  rows
}

///|
/// 已完成 9 条：advance 推到 state=20（分支无关）
fn finished_rows()
  -> Array[(Int64, String, Map[String, Json], Array[String])] {
  let rows : Array[(Int64, String, Map[String, Json], Array[String])] = []
  rows.push((1L, "userA", Map::new(), ["user1", "director"]))
  rows.push((8L, "userB", Map::new(), ["boss", "manager"]))
  rows.push((2L, "manager", Map::new(), ["boss"]))
  rows.push((10L, "director", Map::new(), []))
  rows.push((12L, "userC", sb_extra([("deptLeader", @json.string_of("leader"))]), []))
  rows.push((1L, "director", Map::new(), []))
  rows.push((5L, "manager", Map::new(), []))
  rows.push((12L, "userA", sb_extra([("deptLeader", @json.string_of("director"))]), []))
  rows.push((12L, "userB", sb_extra([("deptLeader", @json.string_of("user1"))]), []))
  rows
}

///|
/// 委托 8 条：processSurrogate/page 无 operator 过滤 → 8 用户委托菜单全非空
fn surrogates() -> Array[Array[String]] {
  [
    ["user1", "userA"], ["userA", "userB"], ["userB", "userC"], ["userC", "leader"],
    ["leader", "manager"], ["manager", "director"], ["director", "boss"], ["boss", "user1"],
  ]
}

///|
/// canonical FORM_BY_DEFINE：defineId → 发起表单字段（13 无 apply 节点故不列）。
/// 八栈同表同值同序；日期写死字面量不按当前时钟算；f_days / f_budget 是数字，其余字符串。
fn form_by_define() -> Map[Int64, Map[String, Json]] {
  let t : Map[Int64, Map[String, Json]] = Map::new()
  t[1L] = sb_extra([
    ("f_reason", @json.string_of("家中有事需请假")),
    ("f_days", @json.number_of(3L)),
    ("f_leaveType", @json.string_of("annual")),
    ("f_startDate", @json.string_of("2026-09-01")),
    ("f_endDate", @json.string_of("2026-09-03")),
  ])
  t[2L] = sb_extra([
    ("f_reason", @json.string_of("项目上线后调休")),
    ("f_days", @json.number_of(2L)),
    ("f_leaveType", @json.string_of("annual")),
    ("f_startDate", @json.string_of("2026-09-07")),
    ("f_endDate", @json.string_of("2026-09-08")),
  ])
  t[3L] = sb_extra([
    ("f_reason", @json.string_of("出差报销申请")),
    ("f_days", @json.number_of(1L)),
    ("f_leaveType", @json.string_of("personal")),
    ("f_startDate", @json.string_of("2026-09-10")),
    ("f_endDate", @json.string_of("2026-09-10")),
  ])
  t[4L] = sb_extra([
    ("f_reason", @json.string_of("培训进修请假")),
    ("f_days", @json.number_of(5L)),
    ("f_leaveType", @json.string_of("sick")),
    ("f_startDate", @json.string_of("2026-09-14")),
    ("f_endDate", @json.string_of("2026-09-18")),
  ])
  t[5L] = sb_extra([
    ("f_reason", @json.string_of("年假出行")),
    ("f_days", @json.number_of(4L)),
    ("f_leaveType", @json.string_of("annual")),
    ("f_startDate", @json.string_of("2026-09-21")),
    ("f_endDate", @json.string_of("2026-09-24")),
  ])
  t[6L] = sb_extra([
    ("f_reason", @json.string_of("婚假申请")),
    ("f_days", @json.number_of(10L)),
    ("f_leaveType", @json.string_of("personal")),
    ("f_startDate", @json.string_of("2026-09-28")),
    ("f_endDate", @json.string_of("2026-10-07")),
  ])
  t[7L] = sb_extra([
    ("f_reason", @json.string_of("病假休养")),
    ("f_days", @json.number_of(6L)),
    ("f_leaveType", @json.string_of("sick")),
    ("f_startDate", @json.string_of("2026-10-12")),
    ("f_endDate", @json.string_of("2026-10-17")),
  ])
  t[8L] = sb_extra([
    ("f_reason", @json.string_of("产检假")),
    ("f_days", @json.number_of(3L)),
    ("f_leaveType", @json.string_of("sick")),
    ("f_startDate", @json.string_of("2026-10-19")),
    ("f_endDate", @json.string_of("2026-10-21")),
  ])
  t[9L] = sb_extra([
    ("f_reason", @json.string_of("陪产假")),
    ("f_days", @json.number_of(5L)),
    ("f_leaveType", @json.string_of("personal")),
    ("f_startDate", @json.string_of("2026-10-26")),
    ("f_endDate", @json.string_of("2026-10-30")),
  ])
  t[10L] = sb_extra([
    ("f_reason", @json.string_of("事假处理家务")),
    ("f_days", @json.number_of(2L)),
    ("f_leaveType", @json.string_of("personal")),
    ("f_startDate", @json.string_of("2026-11-02")),
    ("f_endDate", @json.string_of("2026-11-03")),
  ])
  t[11L] = sb_extra([
    ("f_bizType", @json.string_of("purchase")),
    ("f_budget", @json.number_of(12000L)),
    ("f_urgency", @json.string_of("normal")),
    ("f_desc", @json.string_of("采购一批开发板与传感器")),
  ])
  t[12L] = sb_extra([
    ("f_reason", @json.string_of("部门例行调休")),
    ("f_days", @json.number_of(1L)),
    ("f_leaveType", @json.string_of("annual")),
    ("f_startDate", @json.string_of("2026-11-09")),
    ("f_endDate", @json.string_of("2026-11-09")),
  ])
  t[14L] = sb_extra([
    ("f_reason", @json.string_of("外派学习请假")),
    ("f_days", @json.number_of(7L)),
    ("f_leaveType", @json.string_of("annual")),
    ("f_startDate", @json.string_of("2026-11-16")),
    ("f_endDate", @json.string_of("2026-11-22")),
  ])
  t[15L] = sb_extra([
    ("f_reason", @json.string_of("丧假")),
    ("f_days", @json.number_of(3L)),
    ("f_leaveType", @json.string_of("personal")),
    ("f_startDate", @json.string_of("2026-11-23")),
    ("f_endDate", @json.string_of("2026-11-25")),
  ])
  t
}

///|
/// canonical TF_BY_FORM：审批节点 formKey → 任务表单字段。表里没有的 formKey
/// （如 apply-form / expense-form / mix-form）只落通用审批意见，不臆造字段。
fn tf_by_form() -> Map[String, Map[String, Json]] {
  let t : Map[String, Map[String, Json]] = Map::new()
  t["leave-form"] = sb_extra([
    ("tf_approvedDays", @json.number_of(3L)),
    ("tf_needExtra", @json.string_of("no")),
    ("tf_remark", @json.string_of("按项目排期核准，注意工作交接")),
  ])
  t["review-form"] = sb_extra([
    ("tf_riskLevel", @json.string_of("low")),
    ("tf_needLegalDoc", @json.string_of("no")),
    ("tf_reviewOpinion", @json.string_of("条款与预算均无风险")),
  ])
  t["boss-form"] = sb_extra([
    ("tf_finalDecision", @json.string_of("agree")),
    ("tf_finalAmount", @json.number_of(8000L)),
    ("tf_bossNote", @json.string_of("同意，走年度预算")),
  ])
  t["check-form"] = sb_extra([
    ("tf_invoiceOk", @json.string_of("yes")),
    ("tf_amountChecked", @json.number_of(8000L)),
    ("tf_checkNote", @json.string_of("票据齐全，计入差旅科目")),
  ])
  t["countersign-form"] = sb_extra([
    ("tf_signVote", @json.string_of("support")),
    ("tf_signAmount", @json.number_of(5000L)),
    ("tf_signOpinion", @json.string_of("本条线无异议")),
  ])
  t["seq-form"] = sb_extra([
    ("tf_seqStage", @json.string_of("first")),
    ("tf_seqVote", @json.string_of("pass")),
    ("tf_seqOpinion", @json.string_of("初审通过，转下一人")),
  ])
  t["approve-form"] = sb_extra([
    ("tf_approveResult", @json.string_of("ok")),
    ("tf_approveAmount", @json.number_of(8000L)),
    ("tf_approveNote", @json.string_of("审批通过")),
  ])
  t["ratio-form"] = sb_extra([
    ("tf_ratioVote", @json.string_of("agree")),
    ("tf_ratioOpinion", @json.string_of("达到比例即可通过")),
  ])
  t["veto-form"] = sb_extra([
    ("tf_vetoResult", @json.string_of("pass")),
    ("tf_vetoReason", @json.string_of("无异议")),
  ])
  t["form-a"] = sb_extra([
    ("tf_branchA", @json.string_of("a1")),
    ("tf_branchANote", @json.string_of("A 分支选方案 A1")),
  ])
  t["form-b"] = sb_extra([
    ("tf_branchB", @json.string_of("b1")),
    ("tf_branchBNote", @json.string_of("B 分支选方案 B1")),
  ])
  t["field-form"] = sb_extra([
    ("tf_ownerName", @json.string_of("张三")),
    ("tf_field", @json.string_of("tech")),
    ("tf_fieldNote", @json.string_of("技术域评估通过")),
  ])
  t["operator-form"] = sb_extra([
    ("tf_selfCheck", @json.string_of("done")),
    ("tf_operatorNote", @json.string_of("发起人自查无误")),
  ])
  t["dept-form"] = sb_extra([
    ("tf_deptAgree", @json.string_of("yes")),
    ("tf_deptQuota", @json.number_of(8000L)),
    ("tf_deptNote", @json.string_of("同意占用本部门额度")),
  ])
  t["role-form"] = sb_extra([
    ("tf_roleResult", @json.string_of("pass")),
    ("tf_roleNote", @json.string_of("角色审批通过")),
  ])
  t
}

///|
/// canonical 规则 5：每个 processTask/execute 调用点都走这里——通用审批意见必带，
/// 再按该任务行的 formKey 并任务表单字段（in-place 改 ex）。
fn with_task_form(ex : Map[String, Json], form_key : String) -> Unit {
  ex["tf_approvalComment"] = @json.string_of("同意，情况已核实")
  match tf_by_form().get(form_key) {
    Some(fields) => for k, v in fields {
      ex[k] = v
    }
    None => ()
  }
}

///|
/// 任务行的 formKey（facade 出口 to_camel 后统一是 camelCase 键；无/为 null → ""，
/// 只落通用意见）
fn task_form_key(t : Json) -> String {
  match t.value("formKey") {
    Some(v) => @json.as_str(v).unwrap_or("")
    None => ""
  }
}

///|
fn sb_extra(pairs : Array[(String, Json)]) -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  for p in pairs {
    m[p.0] = p.1
  }
  m
}

///|
fn row_args(
  define_id : Int64,
  op : String,
  extra : Map[String, Json]
) -> Map[String, Json] {
  let args : Map[String, Json] = Map::new()
  args["processDefineId"] = @json.number_of(define_id)
  args["operator"] = @json.string_of(op)
  // canonical 规则 4：f_* 先铺、extra 后铺（amount / deptLeader 等流程变量优先，不被表单值盖掉）
  match form_by_define().get(define_id) {
    Some(fields) => for k, v in fields {
      args[k] = v
    }
    None => ()
  }
  for k, v in extra {
    args[k] = v
  }
  args
}

///|
fn str_array_json(items : Array[String]) -> Json {
  let arr : Array[Json] = []
  for s in items {
    arr.push(@json.string_of(s))
  }
  @json.array_of(arr)
}

///|
fn sb_code(resp : Json) -> Int64 {
  sb_num_of(resp.value("code"), -1L)
}

///|
fn sb_iid(resp : Json) -> Json? {
  match resp.value("data") {
    Some(d) => d.value("processInstanceId")
    None => None
  }
}

///|
fn sb_num_of(j : Json?, fallback : Int64) -> Int64 {
  match j {
    Some(v) => match v.as_number() {
      Some(d) => d.to_int64()
      None => fallback
    }
    None => fallback
  }
}

///|
fn sb_state(data : Json) -> Int64 {
  sb_num_of(data.value("state"), 0L)
}

///|
fn sb_field(t : Json, key : String) -> Json {
  match t.value(key) {
    Some(v) => v
    None => @json.number_of(0L)
  }
}

///|
fn sb_actor(t : Json) -> String? {
  match t.value("operator") {
    Some(op) => match op.as_string() {
      Some(s) => if s != "" {
        return Some(s)
      } else {
        ()
      }
      None => ()
    }
    None => ()
  }
  match t.value("taskActorIdList") {
    Some(list) => match list.as_array() {
      Some(arr) => if arr.length() > 0 {
        arr[0].as_string()
      } else {
        None
      }
      None => None
    }
    None => None
  }
}

///|
/// advance 原语：循环读 detail，对每个 doing 任务以其自身 actor execute(submitType=1)。
/// doing 任务 operator 为 null，actor 取 taskActorIdList[0]。
async fn sb_advance(
  facade : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository],
  iid : Json
) -> Int64 raise {
  for _i in 0..<30 {
    let detail : Map[String, Json] = Map::new()
    detail["id"] = iid
    let resp = facade.flow("processInstance/detail", detail)
    let data = match resp.value("data") {
      Some(d) => d
      None => return -1L
    }
    let state = sb_state(data)
    if state != 10L {
      return state
    }
    let mut progress = false
    match data.value("tasks") {
      Some(tasks) => match tasks.as_array() {
        Some(list) => for t in list {
          if sb_num_of(t.value("taskState"), 0L) == 10L {
            match sb_actor(t) {
              Some(actor) => {
                let ex : Map[String, Json] = Map::new()
                ex["processTaskId"] = sb_field(t, "id")
                ex["operator"] = @json.string_of(actor)
                ex["submitType"] = @json.number_of(1L)
                with_task_form(ex, task_form_key(t))
                let r = facade.flow("processTask/execute", ex)
                if sb_code(r) == 0L {
                  progress = true
                }
              }
              None => ()
            }
          }
        }
        None => ()
      }
      None => ()
    }
    if not(progress) {
      return state
    }
  }
  -1L
}

///|
/// 仅 I14 用：在该实例里找 op 的 doing 任务行（iid 一致性用 stringify 比较，兼容 string/number 化 id）
async fn sb_todo_row(
  facade : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository],
  op : String,
  iid : Json
) -> Json? raise {
  let args : Map[String, Json] = Map::new()
  args["operator"] = @json.string_of(op)
  args["pageNum"] = @json.number_of(1L)
  args["pageSize"] = @json.number_of(200L)
  let resp = facade.flow("processTask/todoList", args)
  match resp.value("data") {
    Some(data) => match data.value("rows") {
      Some(rows) => match rows.as_array() {
        Some(list) => {
          let iid_key = iid.stringify()
          for r in list {
            let row_iid = sb_field(r, "processInstanceId").stringify()
            if row_iid == iid_key && sb_num_of(r.value("taskState"), 0L) == 10L {
              return Some(r)
            }
          }
          None
        }
        None => None
      }
      None => None
    }
    None => None
  }
}
