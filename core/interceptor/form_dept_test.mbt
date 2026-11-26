// 「表单指定部门（分管）领导」专属单测 —— issues/258 四档查找、1–N 部门解析、稳定去重与失败语义。
// 注册名（Java FQN 顶级类逐字一致）由 core/metadata 的 HandlerRegistry 钉子守着，见 metadata_test.mbt。

///|
let fd_org : @spi.OrgUserProviderFnsSync = {
  find_dept_leaders: d => {
    match d {
      "deptA" => ["leaderA", "shared"]
      "deptB" => ["leaderB", "shared"]
      "deptC" => ["leaderC1", "leaderC2"]
      "0" => ["zeroLeader"]
      _ => []
    }
  },
  find_dept_main_leaders: d => {
    match d {
      "deptA" => ["mainA"]
      "deptB" => ["mainB"]
      "deptC" => ["mainC"]
      "0" => ["zeroMain"]
      _ => []
    }
  },
  find_by_role: _r => [],
}

///|
let fd_base : @interceptor.OrgAssignBase = {
  user: None,
  org: Some(fd_org.to_async()),
}

///|
fn fd_exec_of(node_id : String, args : @json.FlowData) -> @exec.Execution {
  let define_info : @model.ProcessDefine = {
    id: 1L,
    name: "form-dept",
    display_name: "FormDept",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let instance = @model.ProcessInstance::create(define_info, "clerk", args)
  let model : @parser.ProcessModel = {
    name: "form-dept",
    display_name: "FormDept",
    model_type: "approval",
    expire_time: None,
    persist_mode: None,
    pre_interceptors: None,
    post_interceptors: None,
    rel_table_name: None,
    nodes: [],
    edges: [],
  }
  let exec = @exec.Execution::make(instance, model, define_info, "clerk", args)
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
async fn fd_resolve(
  node_key : String,
  args : @json.FlowData,
  main~ : Bool = false,
) -> String raise @error.JeeflowError {
  let exec = fd_exec_of(node_key, args)
  if main {
    @interceptor.form_dept_leader_handler(fd_base, main=true)(exec)
  } else {
    @interceptor.form_dept_leader_handler(fd_base)(exec)
  }
}

///|
async test "fd: tier1 f_ 前缀优先于 tier2 裸名，键全缺为空" {
  let both = @json.FlowData::new()
  both.insert_str("f_depts", "deptA")
  both.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts", both), "leaderA,shared")

  let bare = @json.FlowData::new()
  bare.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts", bare), "leaderB,shared")

  let missing = @json.FlowData::new()
  missing.insert_str("other", "deptB")
  assert_eq(fd_resolve("depts", missing), "")
}

///|
async test "fd: tier3 # 取最后一个右半字段，先裸名再 f_" {
  let bare_first = @json.FlowData::new()
  bare_first.insert_str("deptIds", "deptA")
  bare_first.insert_str("f_deptIds", "deptB")
  assert_eq(fd_resolve("manager#deptIds", bare_first), "leaderA,shared")

  let only_prefixed = @json.FlowData::new()
  only_prefixed.insert_str("f_deptIds", "deptB")
  assert_eq(fd_resolve("manager#deptIds", only_prefixed), "leaderB,shared")

  let two_hashes = @json.FlowData::new()
  two_hashes.insert_str("deptIds", "deptA")
  assert_eq(fd_resolve("a#b#deptIds", two_hashes), "leaderA,shared")

  let empty_right = @json.FlowData::new()
  empty_right.insert_str("deptIds", "deptB")
  assert_eq(fd_resolve("manager#", empty_right), "")
}

///|
async test "fd: tier4 _NN 后缀 base 先 f_ 再裸名，且符合惰性正则" {
  let prefixed = @json.FlowData::new()
  prefixed.insert_str("f_depts", "deptA")
  prefixed.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts_01", prefixed), "leaderA,shared")

  let bare = @json.FlowData::new()
  bare.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts_01", bare), "leaderB,shared")

  let earliest = @json.FlowData::new()
  earliest.insert_str("a_b", "deptA")
  earliest.insert_str("a", "deptB")
  assert_eq(fd_resolve("a_b_01", earliest), "leaderA,shared")

  let empty_prefix = @json.FlowData::new()
  empty_prefix.insert_str("f_", "deptA")
  assert_eq(fd_resolve("_01", empty_prefix), "")

  let not_digits = @json.FlowData::new()
  not_digits.insert_str("depts", "deptA")
  assert_eq(fd_resolve("depts_01x", not_digits), "")
}

///|
async test "fd: 键存在即命中，null/空串不回退；无节点不抛" {
  let nul = @json.FlowData::new()
  nul.insert("f_depts", @json.null_json())
  nul.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts", nul), "")

  let empty = @json.FlowData::new()
  empty.insert_str("f_depts", "")
  empty.insert_str("depts", "deptB")
  assert_eq(fd_resolve("depts", empty), "")

  let no_node = @json.FlowData::new()
  no_node.insert_str("f_", "deptA")
  assert_eq(fd_resolve("", no_node), "")
}

///|
async test "fd: 多部门逗号串按输入/SPI 顺序合并，trim 丢空并跳过非法部门" {
  let args = @json.FlowData::new()
  args.insert_str("depts", " ghost, deptC, ,deptA,deptB ")
  assert_eq(fd_resolve("depts", args), "leaderC1,leaderC2,leaderA,shared,leaderB")
}

///|
async test "fd: 数组逐元素读取且不二次拆逗号，支持数字/ null/空值" {
  let args = @json.FlowData::new()
  args.insert(
    "depts",
    @json.array_of([
      @json.string_of(" deptB "),
      @json.string_of(""),
      @json.null_json(),
      @json.string_of("deptA"),
      @json.number_of(0L),
    ]),
  )
  assert_eq(fd_resolve("depts", args), "leaderB,shared,leaderA,zeroLeader")

  let unsplit = @json.FlowData::new()
  unsplit.insert("depts", @json.array_of([@json.string_of("deptA,deptB")]))
  assert_eq(fd_resolve("depts", unsplit), "")

  let non_scalar = @json.FlowData::new()
  non_scalar.insert("depts", @json.array_of([@json.empty_object()]))
  assert_eq(fd_resolve("depts", non_scalar), "")
}

///|
async test "fd: 重复部门只查一次，重复/空白 userId 最终稳定去重" {
  let calls : Array[String] = []
  let org : @spi.OrgUserProviderFnsSync = {
    find_dept_leaders: d => {
      calls.push(d)
      match d {
        "deptA" => ["leaderA", "shared", " leaderA "]
        "deptB" => ["shared", "leaderB", "leaderB", ""]
        _ => []
      }
    },
    find_dept_main_leaders: _d => [],
    find_by_role: _r => [],
  }
  let base : @interceptor.OrgAssignBase = {
    user: None,
    org: Some(org.to_async()),
  }
  let args = @json.FlowData::new()
  args.insert_str("depts", " deptA,deptB,deptA, deptB ")
  let out = @interceptor.form_dept_leader_handler(base)(fd_exec_of("depts", args))
  assert_eq(out, "leaderA,shared,leaderB")
  assert_eq(calls.join(","), "deptA,deptB")
}

///|
async test "fd: 字符串/数字 0 都是合法部门 id 且相互去重" {
  let numeric = @json.FlowData::new()
  numeric.insert_i64("depts", 0L)
  assert_eq(fd_resolve("depts", numeric), "zeroLeader")

  let padded = @json.FlowData::new()
  padded.insert_str("depts", " 0,0 ")
  assert_eq(fd_resolve("depts", padded), "zeroLeader")

  let mixed = @json.FlowData::new()
  mixed.insert(
    "depts",
    @json.array_of([@json.number_of(0L), @json.string_of("0")]),
  )
  assert_eq(fd_resolve("depts", mixed), "zeroLeader")
  assert_eq(fd_resolve("depts", numeric, main=true), "zeroMain")
}

///|
async test "fd: 负责人/分管领导两档各自按多部门与 SPI 顺序返回" {
  let args = @json.FlowData::new()
  args.insert_str("depts", "deptC,deptA,deptB")
  assert_eq(fd_resolve("depts", args), "leaderC1,leaderC2,leaderA,shared,leaderB")
  assert_eq(fd_resolve("depts", args, main=true), "mainC,mainA,mainB")
}

///|
async test "fd: 空值/空数组/对象/全非法/全无领导/缺 SPI 一律空且不抛" {
  let empty_string = @json.FlowData::new()
  empty_string.insert_str("depts", "")
  assert_eq(fd_resolve("depts", empty_string), "")

  let blank = @json.FlowData::new()
  blank.insert_str("depts", " , \t, ")
  assert_eq(fd_resolve("depts", blank), "")

  let empty_array = @json.FlowData::new()
  empty_array.insert("depts", @json.empty_array())
  assert_eq(fd_resolve("depts", empty_array), "")

  let object = @json.FlowData::new()
  object.insert("depts", @json.empty_object())
  assert_eq(fd_resolve("depts", object), "")

  let invalid = @json.FlowData::new()
  invalid.insert_str("depts", "ghost,missing")
  assert_eq(fd_resolve("depts", invalid), "")

  let no_org : @interceptor.OrgAssignBase = {
    user: None,
    org: None,
  }
  let valid = @json.FlowData::new()
  valid.insert_str("depts", "deptA,deptB")
  assert_eq(
    @interceptor.form_dept_leader_handler(no_org)(fd_exec_of("depts", valid)),
    "",
  )
  assert_eq(
    @interceptor.form_dept_leader_handler(no_org, main=true)(fd_exec_of("depts", valid)),
    "",
  )
}

///|
async test "fd: 单部门 SPI 抛错只跳过该部门，后续部门照常取人" {
  let calls : Array[String] = []
  let org : @spi.OrgUserProviderFnsSync = {
    find_dept_leaders: d => {
      calls.push("leader:\{d}")
      if d == "deptA" {
        raise @error.JeeflowError::Business("leader lookup failed")
      } else if d == "deptB" {
        ["leaderB"]
      } else {
        []
      }
    },
    find_dept_main_leaders: d => {
      calls.push("main:\{d}")
      if d == "deptA" {
        raise @error.JeeflowError::Business("main leader lookup failed")
      } else if d == "deptB" {
        ["mainB"]
      } else {
        []
      }
    },
    find_by_role: _r => [],
  }
  let base : @interceptor.OrgAssignBase = {
    user: None,
    org: Some(org.to_async()),
  }
  let args = @json.FlowData::new()
  args.insert_str("depts", "deptA,deptB")
  let exec = fd_exec_of("depts", args)
  assert_eq(@interceptor.form_dept_leader_handler(base)(exec), "leaderB")
  assert_eq(
    @interceptor.form_dept_leader_handler(base, main=true)(exec),
    "mainB",
  )
  assert_eq(calls.join(","), "leader:deptA,leader:deptB,main:deptA,main:deptB")
}

///|
async test "fd: 旧 form_user 仍只取首个用户，旧 form_field 不扩 # 档（回归）" {
  let user : (String) -> @model.UserInfo? raise @error.JeeflowError = uid => {
    if uid == "emp" {
      Some(@model.UserInfo::make(user_id="emp", real_name="员工", dept_id="deptA"))
    } else {
      None
    }
  }
  let old_base : @interceptor.OrgAssignBase = {
    user: Some(@spi.async_of_sync(user)),
    org: Some(fd_org.to_async()),
  }
  let args = @json.FlowData::new()
  args.insert_str("f_leader", "emp,other")
  assert_eq(
    @interceptor.form_user_dept_leader_handler(old_base)(fd_exec_of("leader", args)),
    "leaderA,shared",
  )

  let hash_only = @json.FlowData::new()
  hash_only.insert_str("deptIds", "deptA")
  assert_eq(
    @interceptor.form_field_assignee_handler()(fd_exec_of("manager#deptIds", hash_only)),
    "",
  )
}
