// issues/103 §8 一致性驱动（MoonBit 侧）
// 固定数据集：2 流程（leave/expense）/ 6 实例（含 1 个 state=99）/ 5 任务，全部落 2026-08-01/02，
// 无当日实例（todayNew=0 不依赖时钟）。数据集语义以 java.json 快照反推 + JeeflowStatsTest.seed() 为基准：
//   实例 100 leave/10/u1 08-01 10:00（进行中，T200/T201 在办）
//   实例 101 leave/20/u1 08-01 12:00（完成，T202 12:10→18:00 及时 → 实例时长 21600s）
//   实例 102 expense/20/u2 08-02 09:00（完成，T203 09:10→18:00 超时 → 实例时长 32400s）
//   实例 103 expense/30/u2 08-02 11:00（撤销）
//   实例 104 leave/45/u1 08-02 15:00（驳回）
//   实例 105 leave/99/u3 08-02 16:00（废弃，T204 16:10→17:00 及时）
// 驱动 15 个 stats action，输出 {label: {code,msg,data}} 单行 JSON（对齐 jeeflow-hub/consistency/*.json 格式）。
// 运行：moon run --target wasm demo/cmd/consistency

///|
fn stats_user_provider(uid : String) -> @model.UserInfo? raise @error.JeeflowError {
  Some({
    user_id: uid,
    real_name: "用户\{uid}",
    dept_id: "",
    dept_name: "",
    post_id: "",
    post_name: "",
  })
}

///|
fn stats_make_ctx(
  repo : @memory.MemoryRepository
) -> @spi.Ctx[@memory.MemoryRepository, @memory.MemoryRepository] {
  let ctx = @spi.Ctx::new(repo, repo)
  ctx.with_user_provider(stats_user_provider)
}

///|
fn stats_inst(
  id : Int64,
  define_id : Int64,
  state : Int,
  op : String,
  create : String
) -> @model.ProcessInstance {
  {
    instance_id: id,
    parent_id: None,
    define_id,
    state,
    parent_node_name: None,
    business_no: None,
    operator: op,
    expire_time: None,
    variables: @json.FlowData::new(),
    tasks: [],
    create_time: Some(create),
    create_user: Some(op),
    update_time: None,
    update_user: None,
    define: None,
  }
}

///|
fn stats_task(
  id : Int64,
  inst_id : Int64,
  state : Int,
  display : String,
  actor : String,
  create : String,
  finish : String?,
  expire : String?,
  perform : Int
) -> @model.ProcessTask {
  {
    task_id: id,
    process_instance_id: inst_id,
    task_name: display,
    display_name: display,
    task_type: 0,
    perform_type: perform,
    task_state: state,
    actor_id: Some(actor),
    actor_ids: [actor],
    finish_time: finish,
    expire_time: expire,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some(create),
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
async fn stats_seed(repo : @memory.MemoryRepository) -> Unit raise {
  let d1 : @model.ProcessDefine = {
    id: 1L,
    name: "leave",
    display_name: "请假流程",
    define_type: "approval",
    state: 1,
    content: "",
    version: 1,
    create_time: Some("2026-08-01 09:00:00"),
    create_user: Some("system"),
    update_time: None,
    update_user: None,
  }
  let d2 : @model.ProcessDefine = {
    id: 2L,
    name: "expense",
    display_name: "报销流程",
    define_type: "finance",
    state: 1,
    content: "",
    version: 1,
    create_time: Some("2026-08-01 09:00:00"),
    create_user: Some("system"),
    update_time: None,
    update_user: None,
  }
  repo.put_define_direct(d1)
  repo.put_define_direct(d2)
  let i100 = stats_inst(100L, 1L, 10, "u1", "2026-08-01 10:00:00")
  let i101 = stats_inst(101L, 1L, 20, "u1", "2026-08-01 12:00:00")
  let i102 = stats_inst(102L, 2L, 20, "u2", "2026-08-02 09:00:00")
  let i103 = stats_inst(103L, 2L, 30, "u2", "2026-08-02 11:00:00")
  let i104 = stats_inst(104L, 1L, 45, "u1", "2026-08-02 15:00:00")
  let i105 = stats_inst(105L, 1L, 99, "u3", "2026-08-02 16:00:00")
  let t200 = stats_task(
    200L, 100L, 10, "部门经理审批", "u9", "2026-08-01 10:05:00", None, None, 0,
  )
  let t201 = stats_task(
    201L, 100L, 10, "人事确认", "u9", "2026-08-01 10:06:00", None, None, 1,
  )
  t201.actor_ids = ["u9", "u10"]
  let t202 = stats_task(
    202L, 101L, 20, "部门经理审批", "u5", "2026-08-01 12:10:00",
    Some("2026-08-01 18:00:00"), Some("2026-08-02 12:00:00"), 0,
  )
  let t203 = stats_task(
    203L, 102L, 20, "财务审批", "u6", "2026-08-02 09:10:00",
    Some("2026-08-02 18:00:00"), Some("2026-08-02 12:00:00"), 0,
  )
  let t204 = stats_task(
    204L, 105L, 20, "部门经理审批", "u5", "2026-08-02 16:10:00",
    Some("2026-08-02 17:00:00"), Some("2026-08-02 17:30:00"), 0,
  )
  // get_all_instances 不回填 tasks（读侧仅 find_instance_by_id 回填），
  // 实例时长 = MAX(task.finish_time) - create_time，必须在保存前把任务挂进聚合
  i100.tasks = [t200, t201]
  i101.tasks = [t202]
  i102.tasks = [t203]
  i105.tasks = [t204]
  repo.save_instance(i100)
  repo.save_instance(i101)
  repo.save_instance(i102)
  repo.save_instance(i103)
  repo.save_instance(i104)
  repo.save_instance(i105)
  repo.save_task(t200)
  repo.save_task(t201)
  repo.save_task(t202)
  repo.save_task(t203)
  repo.save_task(t204)
  repo.add_task_actor(201L, ["u9", "u10"])
}

///|
fn stats_args0() -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  m
}

///|
fn stats_args_state_in_10() -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  m["stateIn"] = @json.array_of([@json.number_of(10L)])
  m
}

///|
fn stats_args_trend(
  start : String,
  end : String,
  granularity : String
) -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  m["start"] = @json.string_of(start)
  m["end"] = @json.string_of(end)
  m["granularity"] = @json.string_of(granularity)
  m
}

///|
fn stats_args_group(dimension : String) -> Map[String, Json] {
  let m : Map[String, Json] = Map::new()
  m["dimension"] = @json.string_of(dimension)
  m
}

///|
async fn stats_call(
  f : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository],
  out : Array[(String, Json)],
  label : String,
  action : String,
  args : Map[String, Json]
) -> Unit raise {
  let outcome = try? f.flow(action, args)
  match outcome {
    Ok(v) => out.push((label, v))
    Err(e) => {
      let o = @json.empty_object()
      @json.obj_set(o, "code", @json.number_of(99999999L))
      @json.obj_set(o, "msg", @json.string_of(e.to_string()))
      @json.obj_set(o, "data", @json.null_json())
      out.push((label, o))
    }
  }
}

///|
async fn main raise {
  let repo = @memory.MemoryRepository::new()
  stats_seed(repo)
  let ctx = stats_make_ctx(repo)
  let facade : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository] = @facade.Facade::make(
    ctx,
  )
  let out : Array[(String, Json)] = []
  // overview ×2
  stats_call(facade, out, "overview", "processInstance/stats/overview", stats_args0())
  stats_call(
    facade, out, "overview_stateIn10", "processInstance/stats/overview",
    stats_args_state_in_10(),
  )
  // trend ×4（桶枚举 end 含端，窗口对齐 java.json 快照桶位）
  stats_call(
    facade, out, "trend_day", "processInstance/stats/trend",
    stats_args_trend("2026-08-01 00:00:00", "2026-08-02 23:59:59", "day"),
  )
  stats_call(
    facade, out, "trend_hour", "processInstance/stats/trend",
    stats_args_trend("2026-08-01 10:00:00", "2026-08-01 12:00:00", "hour"),
  )
  stats_call(
    facade, out, "trend_week", "processInstance/stats/trend",
    stats_args_trend("2026-08-01 00:00:00", "2026-08-02 23:59:59", "week"),
  )
  stats_call(
    facade, out, "trend_month", "processInstance/stats/trend",
    stats_args_trend("2026-07-01 00:00:00", "2026-08-02 23:59:59", "month"),
  )
  // group ×9
  stats_call(
    facade, out, "group_state", "processInstance/stats/group", stats_args_group("state"),
  )
  stats_call(
    facade, out, "group_define", "processInstance/stats/group", stats_args_group("define"),
  )
  stats_call(
    facade, out, "group_category", "processInstance/stats/group",
    stats_args_group("category"),
  )
  stats_call(
    facade, out, "group_approver", "processInstance/stats/group",
    stats_args_group("approver"),
  )
  stats_call(
    facade, out, "group_applicant", "processInstance/stats/group",
    stats_args_group("applicant"),
  )
  stats_call(
    facade, out, "group_node", "processInstance/stats/group", stats_args_group("node"),
  )
  stats_call(
    facade, out, "group_stuckNode", "processInstance/stats/group",
    stats_args_group("stuckNode"),
  )
  stats_call(
    facade, out, "group_stuckApprover", "processInstance/stats/group",
    stats_args_group("stuckApprover"),
  )
  stats_call(
    facade, out, "group_durationBucket", "processInstance/stats/group",
    stats_args_group("durationBucket"),
  )
  println(@json.stringify(@json.object_of(out)))
}
