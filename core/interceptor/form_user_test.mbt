// 「表单指定用户所属部门（分管）领导」单测 —— 八语言契约 §3.2 四档并集／§3.3 取人／§3.4 失败语义
// 判据面＝公开 handler 工厂（本栈测试包是黑盒，私有档不直接喂；口径对齐 rust
// interceptor.rs `form_user_tests` 与 python test_form_user_assignment_handlers.py）。
// 注册名（Java FQN 顶级类逐字一致）由 core/metadata 的 HandlerRegistry 钉子守着，见 metadata_test.mbt。

///|
/// 每枚用户钉一个专属部门，部门经理名＝该部门的唯一读数 ⇒ 命中哪一档一目了然。
/// u_f/u_b/u_h/u_m 供四档优先级；emp1→dept2（经理 mgr2/mgr2b、分管 main2）；
/// nodept→无部门；dept3user→dept3（有部门无经理）；"0"→dept2（零号也是合法 id）；
/// ghost 不在表里＝用户不存在。
let fixture_users : (String) -> @model.UserInfo? raise @error.JeeflowError = uid => {
  match uid {
    "u_f" =>
      Some(
        @model.UserInfo::make(user_id="u_f", real_name="f 档", dept_id="deptF"),
      )
    "u_b" =>
      Some(
        @model.UserInfo::make(
          user_id="u_b",
          real_name="裸名档",
          dept_id="deptB",
        ),
      )
    "u_h" =>
      Some(
        @model.UserInfo::make(
          user_id="u_h",
          real_name="hash 档",
          dept_id="deptH",
        ),
      )
    "u_m" =>
      Some(
        @model.UserInfo::make(
          user_id="u_m",
          real_name="后缀档",
          dept_id="deptM",
        ),
      )
    "emp1" =>
      Some(
        @model.UserInfo::make(
          user_id="emp1",
          real_name="员工一",
          dept_id="dept2",
        ),
      )
    "nodept" =>
      Some(
        @model.UserInfo::make(
          user_id="nodept",
          real_name="无部门",
          dept_id="",
        ),
      )
    "dept3user" =>
      Some(
        @model.UserInfo::make(
          user_id="dept3user",
          real_name="空部门员工",
          dept_id="dept3",
        ),
      )
    "0" =>
      Some(
        @model.UserInfo::make(user_id="0", real_name="零号", dept_id="dept2"),
      )
    _ => None
  }
}

///|
let fixture_org : @spi.OrgUserProviderFnsSync = {
  find_dept_leaders: d => {
    match d {
      "deptF" => ["LF"]
      "deptB" => ["LB"]
      "deptH" => ["LH"]
      "deptM" => ["LM"]
      "dept2" => ["mgr2", "mgr2b"]
      _ => []
    }
  },
  find_dept_main_leaders: d => {
    match d {
      "dept2" => ["main2"]
      _ => []
    }
  },
  find_by_role: _r => [],
}

///|
let full_base : @interceptor.OrgAssignBase = {
  user: Some(@spi.async_of_sync(fixture_users)),
  org: Some(fixture_org.to_async()),
}

///|
fn exec_of(node_id : String, args : @json.FlowData) -> @exec.Execution {
  let define_info : @model.ProcessDefine = {
    id: 1L,
    name: "form-user",
    display_name: "FormUser",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let instance = @model.ProcessInstance::create(define_info, "hr", args)
  let model : @parser.ProcessModel = {
    name: "form-user",
    display_name: "FormUser",
    model_type: "approval",
    expire_time: None,
    persist_mode: None,
    pre_interceptors: None,
    post_interceptors: None,
    rel_table_name: None,
    nodes: [],
    edges: [],
  }
  let exec = @exec.Execution::make(instance, model, define_info, "hr", args)
  if !node_id.is_empty() {
    let node : @parser.NodeModel = {
      id: node_id,
      node_type: @parser.Task,
      display_name: "N",
      properties: Map([]),
    }
    exec.current_node = Some(node)
  }
  exec
}

///|
/// 合成口：给定节点唯一编码＋变量表，走一遍新 handler 取人。main=true 取分管领导档。
async fn resolve(
  node_key : String,
  args : @json.FlowData,
  main~ : Bool = false,
) -> String raise @error.JeeflowError {
  let exec = exec_of(node_key, args)
  if main {
    @interceptor.form_user_dept_leader_handler(full_base, main=true)(exec)
  } else {
    @interceptor.form_user_dept_leader_handler(full_base)(exec)
  }
}

///|
async test "fu: tier1 f_ 前缀优先于裸名" {
  let args = @json.FlowData::new()
  args.insert_str("f_leader", "u_f")
  args.insert_str("leader", "u_b")
  let out = resolve("leader", args)
  assert_eq(out, "LF")
}

///|
async test "fu: tier2 裸名兜底 + 键全缺 ⇒ 空" {
  let bare = @json.FlowData::new()
  bare.insert_str("leader", "u_b")
  let bare_out = resolve("leader", bare)
  assert_eq(bare_out, "LB")

  let nothing = @json.FlowData::new()
  nothing.insert_str("other", "u_b")
  let miss_out = resolve("leader", nothing)
  assert_eq(miss_out, "")
}

///|
async test "fu: tier3 # 右半先裸名再 f_（参照实现只有裸名，f_ 是本栈增量）" {
  let bare_first = @json.FlowData::new()
  bare_first.insert_str("userId", "u_h")
  bare_first.insert_str("f_userId", "u_f")
  let first_out = resolve("manager#userId", bare_first)
  assert_eq(first_out, "LH")

  let only_prefixed = @json.FlowData::new()
  only_prefixed.insert_str("f_userId", "u_h")
  let prefixed_out = resolve("manager#userId", only_prefixed)
  assert_eq(prefixed_out, "LH")

  // 右半取**最后一个** # 之后的部分
  let two_hashes = @json.FlowData::new()
  two_hashes.insert_str("userId", "u_h")
  let nested_out = resolve("a#b#userId", two_hashes)
  assert_eq(nested_out, "LH")
}

///|
async test "fu: tier4 _NN 后缀 base 先 f_ 再裸名" {
  let prefixed = @json.FlowData::new()
  prefixed.insert_str("f_manager", "u_m")
  prefixed.insert_str("manager", "u_b")
  let out = resolve("manager_01", prefixed)
  assert_eq(out, "LM")

  let bare = @json.FlowData::new()
  bare.insert_str("manager", "u_m")
  let bare_out = resolve("manager_01", bare)
  assert_eq(bare_out, "LM")
}

///|
async test "fu: _NN 档判据对齐惰性正则（按第一个下划线切会读到另一档）" {
  // a_b_01 的 base＝"a_b"；若按**第一个**下划线切成 "a" 会读成 u_b⇒LB
  let earliest = @json.FlowData::new()
  earliest.insert_str("a_b", "u_m")
  earliest.insert_str("a", "u_b")
  let earliest_out = resolve("a_b_01", earliest)
  assert_eq(earliest_out, "LM")

  // "_01" 前缀为空 ⇒ 不切 base，退化成 f__01/__01 两档 ⇒ 全缺 ⇒ 空
  let empty_prefix = @json.FlowData::new()
  empty_prefix.insert_str("f_", "u_m")
  let guard_out = resolve("_01", empty_prefix)
  assert_eq(guard_out, "")

  // 尾部含非数字 ⇒ 不命中
  let not_digits = @json.FlowData::new()
  not_digits.insert_str("manager", "u_m")
  let tail_out = resolve("manager_01x", not_digits)
  assert_eq(tail_out, "")
}

///|
async test "fu: nodeKey 为空 ⇒ 不撞变量表" {
  let args = @json.FlowData::new()
  args.insert_str("f_", "u_m")
  let out = resolve("", args)
  assert_eq(out, "")
}

///|
async test "fu: 取第一个非空 id（逗号串／数组／零号 id）" {
  let csv = @json.FlowData::new()
  csv.insert_str("k", "u_f,u_b")
  let csv_out = resolve("k", csv)
  assert_eq(csv_out, "LF")

  let padded = @json.FlowData::new()
  padded.insert_str("k", " , u_f ")
  let padded_out = resolve("k", padded)
  assert_eq(padded_out, "LF")

  let arr = @json.FlowData::new()
  arr.insert(
    "k",
    @json.array_of([
      @json.string_of(""),
      @json.string_of("u_f"),
      @json.string_of("u_b"),
    ]),
  )
  let arr_out = resolve("k", arr)
  assert_eq(arr_out, "LF")

  // 数组元素不再二次拆逗号（与 Go/Node 同形）⇒ 整枚元素当一个 id，查不到人即空
  let arr_csv = @json.FlowData::new()
  arr_csv.insert("k", @json.array_of([@json.string_of("u_b,u_f")]))
  let arr_csv_out = resolve("k", arr_csv)
  assert_eq(arr_csv_out, "")

  // 零号 id 合法（不被真值判据吃掉）
  let zero = @json.FlowData::new()
  zero.insert_i64("f_leader", 0L)
  let zero_out = resolve("leader", zero)
  assert_eq(zero_out, "mgr2,mgr2b")
}

///|
async test "fu: handler 取部门经理／分管领导两档" {
  let args = @json.FlowData::new()
  args.insert_str("f_leader", "emp1")
  let leader = resolve("leader", args)
  assert_eq(leader, "mgr2,mgr2b")
  let main = resolve("leader", args, main=true)
  assert_eq(main, "main2")
  // 多人经理保持配置顺序（契约 §3.3 第 4 条）
  assert_eq(leader.split(",").count(), 2)
}

///|
async test "fu: 失败语义一律空串不抛（用户不存在／无部门／无领导／SPI 缺／值为空）" {
  let ghost = @json.FlowData::new()
  ghost.insert_str("f_leader", "ghost")
  let ghost_out = resolve("leader", ghost)
  assert_eq(ghost_out, "")

  let nodept = @json.FlowData::new()
  nodept.insert_str("f_leader", "nodept")
  let nodept_out = resolve("leader", nodept)
  assert_eq(nodept_out, "")

  let no_leaders = @json.FlowData::new()
  no_leaders.insert_str("f_leader", "dept3user")
  let no_leaders_out = resolve("leader", no_leaders)
  assert_eq(no_leaders_out, "")

  let empty_value = @json.FlowData::new()
  empty_value.insert_str("f_leader", "")
  let empty_out = resolve("leader", empty_value)
  assert_eq(empty_out, "")

  let nul = @json.FlowData::new()
  nul.insert("f_leader", @json.null_json())
  let null_out = resolve("leader", nul)
  assert_eq(null_out, "")

  let emp = @json.FlowData::new()
  emp.insert_str("f_leader", "emp1")
  // user SPI 未注册（org 在）⇒ 部门取不到 ⇒ 空
  let no_user_spi : @interceptor.OrgAssignBase = {
    user: None,
    org: Some(fixture_org.to_async()),
  }
  let no_user_out = @interceptor.form_user_dept_leader_handler(no_user_spi)(
    exec_of("leader", emp),
  )
  assert_eq(no_user_out, "")

  // org SPI 未注册 ⇒ 空
  let no_org_spi : @interceptor.OrgAssignBase = {
    user: Some(@spi.async_of_sync(fixture_users)),
    org: None,
  }
  let no_org_out = @interceptor.form_user_dept_leader_handler(no_org_spi)(
    exec_of("leader", emp),
  )
  assert_eq(no_org_out, "")
}

///|
async test "fu: 节点未设置 ⇒ 空串（回归：不炸流程）" {
  let args = @json.FlowData::new()
  args.insert_str("f_leader", "emp1")
  let out = @interceptor.form_user_dept_leader_handler(full_base)(
    exec_of("", args),
  )
  assert_eq(out, "")
}

///|
async test "fu: 现存 form_field handler 查找行为不变（回归钉子）" {
  let old = @interceptor.form_field_assignee_handler()
  let prefixed = @json.FlowData::new()
  prefixed.insert_str("f_node1", "user2")
  let prefixed_out = old(exec_of("node1", prefixed))
  assert_eq(prefixed_out, "user2")

  let bare = @json.FlowData::new()
  bare.insert_str("node1", "user3")
  let bare_out = old(exec_of("node1", bare))
  assert_eq(bare_out, "user3")

  // #／_NN 两档是新 handler 专属——旧 handler 不许跟着扩面
  let hash_only = @json.FlowData::new()
  hash_only.insert_str("userId", "u_h")
  let hash_out = old(exec_of("manager#userId", hash_only))
  assert_eq(hash_out, "")

  let suffix_only = @json.FlowData::new()
  suffix_only.insert_str("manager", "u_m")
  let suffix_out = old(exec_of("manager_01", suffix_only))
  assert_eq(suffix_out, "")
}
