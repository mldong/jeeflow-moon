// issues/259：任务节点关联岗位 / 表单指定岗位专属单测。
// 判据面＝公开 handler 工厂与运行时注册口；旧 11 枚 handler 只做回归，不扩字段语义。

///|
let fp_members : (String) -> Array[String] raise @error.JeeflowError = code => {
  match code {
    "postA" => ["userA", "shared"]
    "postB" => ["userB", "shared"]
    "postC" => ["userC1", "userC2"]
    "0" => ["zeroUser"]
    _ => []
  }
}

///|
let fp_provider_sync : @spi.PostUserProviderFnsSync = {
  find_by_post: fp_members,
}

///|
let fp_provider : @spi.PostUserProviderFns = fp_provider_sync.to_async()

///|
fn fp_exec_of(node_id : String, args : @json.FlowData) -> @exec.Execution {
  let define_info : @model.ProcessDefine = {
    id: 1L,
    name: "form-post",
    display_name: "FormPost",
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
    name: "form-post",
    display_name: "FormPost",
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
async fn fp_form(
  node_key : String,
  args : @json.FlowData,
  provider~ : @spi.PostUserProviderFns? = Some(fp_provider),
) -> String raise @error.JeeflowError {
  @interceptor.form_post_assignment_handler(provider)(fp_exec_of(node_key, args))
}

///|
async fn fp_task(
  node_key : String,
  provider~ : @spi.PostUserProviderFns? = Some(fp_provider),
) -> String raise @error.JeeflowError {
  @interceptor.task_post_assignee_handler(provider)(fp_exec_of(node_key, @json.FlowData::new()))
}

///|
async test "fp: TaskPost 以节点编码查岗位并保留 Provider 顺序" {
  assert_eq(fp_task("postA"), "userA,shared")
  assert_eq(fp_task("postC"), "userC1,userC2")
  assert_eq(fp_task("0"), "zeroUser")
  assert_eq(fp_task("ghost"), "")

  let ordered : @spi.PostUserProviderFnsSync = {
    find_by_post: _code => ["userB", "userA"],
  }
  assert_eq(fp_task("postA", provider=Some(ordered.to_async())), "userB,userA")
}

///|
async test "fp: TaskPost 空节点/缺 SPI/异常一律空且不抛" {
  assert_eq(fp_task(""), "")
  assert_eq(fp_task("postA", provider=None), "")

  let calls : Array[String] = []
  let broken : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      calls.push(code)
      raise @error.JeeflowError::Business("post lookup failed")
    },
  }
  assert_eq(fp_task("postA", provider=Some(broken.to_async())), "")
  assert_eq(fp_task("", provider=Some(broken.to_async())), "")
  assert_true(calls == ["postA"])
}

///|
async test "fp: 字段四档优先级 f_<nodeKey> → 裸名，键全缺为空" {
  let both = @json.FlowData::new()
  both.insert_str("f_posts", "postA")
  both.insert_str("posts", "postB")
  assert_eq(fp_form("posts", both), "userA,shared")

  let bare = @json.FlowData::new()
  bare.insert_str("posts", "postB")
  assert_eq(fp_form("posts", bare), "userB,shared")

  let missing = @json.FlowData::new()
  missing.insert_str("other", "postB")
  assert_eq(fp_form("posts", missing), "")
}

///|
async test "fp: # 档取最后一个右半字段，先裸名再 f_" {
  let bare_first = @json.FlowData::new()
  bare_first.insert_str("postCodes", "postA")
  bare_first.insert_str("f_postCodes", "postB")
  assert_eq(fp_form("manager#postCodes", bare_first), "userA,shared")

  let only_prefixed = @json.FlowData::new()
  only_prefixed.insert_str("f_postCodes", "postB")
  assert_eq(fp_form("manager#postCodes", only_prefixed), "userB,shared")

  let two_hashes = @json.FlowData::new()
  two_hashes.insert_str("postCodes", "postA")
  assert_eq(fp_form("a#b#postCodes", two_hashes), "userA,shared")

  let empty_right = @json.FlowData::new()
  empty_right.insert_str("postCodes", "postB")
  assert_eq(fp_form("manager#", empty_right), "")
}

///|
async test "fp: _NN 档惰性 base 先 f_ 再裸名，非法后缀不命中" {
  let prefixed = @json.FlowData::new()
  prefixed.insert_str("f_posts", "postA")
  prefixed.insert_str("posts", "postB")
  assert_eq(fp_form("posts_01", prefixed), "userA,shared")

  let bare = @json.FlowData::new()
  bare.insert_str("posts", "postA")
  assert_eq(fp_form("posts_01", bare), "userA,shared")

  let earliest = @json.FlowData::new()
  earliest.insert_str("a_b", "postA")
  earliest.insert_str("a", "postB")
  assert_eq(fp_form("a_b_01", earliest), "userA,shared")

  let empty_prefix = @json.FlowData::new()
  empty_prefix.insert_str("f_", "postA")
  assert_eq(fp_form("_01", empty_prefix), "")

  let not_digits = @json.FlowData::new()
  not_digits.insert_str("posts", "postA")
  assert_eq(fp_form("posts_01x", not_digits), "")
}

///|
async test "fp: 键存在即命中，null/空串不回退；无节点不抛" {
  let nul = @json.FlowData::new()
  nul.insert("f_posts", @json.null_json())
  nul.insert_str("posts", "postB")
  assert_eq(fp_form("posts", nul), "")

  let empty = @json.FlowData::new()
  empty.insert_str("f_posts", "")
  empty.insert_str("posts", "postB")
  assert_eq(fp_form("posts", empty), "")

  let no_node = @json.FlowData::new()
  no_node.insert_str("f_", "postA")
  assert_eq(fp_form("", no_node), "")
}

///|
async test "fp: 逗号串拆多岗位，trim 丢空且按输入/SPI 顺序合并" {
  let args = @json.FlowData::new()
  args.insert_str("posts", " ghost, postC, ,postA,postB ")
  assert_eq(fp_form("posts", args), "userC1,userC2,userA,shared,userB")
}

///|
async test "fp: 数组逐元素不二次拆逗号，支持数字/null/非标量" {
  let args = @json.FlowData::new()
  args.insert(
    "posts",
    @json.array_of([
      @json.string_of(" postB "),
      @json.string_of(""),
      @json.null_json(),
      @json.string_of("postA"),
      @json.number_of(0L),
    ]),
  )
  assert_eq(fp_form("posts", args), "userB,shared,userA,zeroUser")

  let unsplit = @json.FlowData::new()
  unsplit.insert("posts", @json.array_of([@json.string_of("postA,postB")]))
  assert_eq(fp_form("posts", unsplit), "")

  let non_scalar = @json.FlowData::new()
  non_scalar.insert("posts", @json.array_of([@json.empty_object()]))
  assert_eq(fp_form("posts", non_scalar), "")
}

///|
async test "fp: 岗位编码保序去重，重复岗位只查一次" {
  let calls : Array[String] = []
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      calls.push(code)
      fp_members(code)
    },
  }
  let args = @json.FlowData::new()
  args.insert_str("posts", " postA,postB,postA, postB ")
  assert_eq(fp_form("posts", args, provider=Some(provider.to_async())), "userA,shared,userB")
  assert_true(calls == ["postA", "postB"])
}

///|
async test "fp: 字符串/数字 0 都是合法岗位编码且相互去重" {
  let numeric = @json.FlowData::new()
  numeric.insert_i64("posts", 0L)
  assert_eq(fp_form("posts", numeric), "zeroUser")

  let padded = @json.FlowData::new()
  padded.insert_str("posts", " 0,0 ")
  assert_eq(fp_form("posts", padded), "zeroUser")

  let mixed = @json.FlowData::new()
  mixed.insert(
    "posts",
    @json.array_of([@json.number_of(0L), @json.string_of("0")]),
  )
  assert_eq(fp_form("posts", mixed), "zeroUser")
}

///|
async test "fp: userId trim 后保序去重并丢弃空值" {
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      match code {
        "postA" => [" userA ", "", "shared", "userA"]
        "postB" => ["shared", " userB ", "userB", ""]
        _ => []
      }
    },
  }
  let args = @json.FlowData::new()
  args.insert_str("posts", "postA,postB")
  assert_eq(fp_form("posts", args, provider=Some(provider.to_async())), "userA,shared,userB")
}

///|
async test "fp: 单岗位 SPI 异常跳过，后续岗位照常取人" {
  let calls : Array[String] = []
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      calls.push(code)
      if code == "postA" {
        raise @error.JeeflowError::Business("post lookup failed")
      } else {
        fp_members(code)
      }
    },
  }
  let args = @json.FlowData::new()
  args.insert_str("posts", "postA,postB")
  assert_eq(fp_form("posts", args, provider=Some(provider.to_async())), "userB,shared")
  assert_true(calls == ["postA", "postB"])
}

///|
async test "fp: 缺 SPI/空值/空数组/全无成员一律空且不抛" {
  let valid = @json.FlowData::new()
  valid.insert_str("posts", "postA,postB")
  assert_eq(fp_form("posts", valid, provider=None), "")

  let empty_string = @json.FlowData::new()
  empty_string.insert_str("posts", "")
  assert_eq(fp_form("posts", empty_string), "")

  let blank = @json.FlowData::new()
  blank.insert_str("posts", " , \t, ")
  assert_eq(fp_form("posts", blank), "")

  let empty_array = @json.FlowData::new()
  empty_array.insert("posts", @json.empty_array())
  assert_eq(fp_form("posts", empty_array), "")

  let object = @json.FlowData::new()
  object.insert("posts", @json.empty_object())
  assert_eq(fp_form("posts", object), "")

  let no_members = @json.FlowData::new()
  no_members.insert_str("posts", "ghost,missing")
  assert_eq(fp_form("posts", no_members), "")
}

///|
async test "fp: 运行时按两个 Java FQCN 注册并解析到实体" {
  let ctx : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 2)
  let task_name = "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskPostAssigneeHandler"
  let form_name = "com.mldong.jeeflow.interceptor.impl.FormPostAssignmentHandler"
  assert_true(ctx.find_assignment_handler(task_name) is None)
  assert_true(ctx.find_assignment_handler(form_name) is None)

  @interceptor.register_post_assignment_handlers(ctx, Some(fp_provider))
  let task_handler = ctx.find_assignment_handler(task_name).unwrap()
  let form_handler = ctx.find_assignment_handler(form_name).unwrap()
  assert_eq(task_handler(fp_exec_of("postA", @json.FlowData::new())), "userA,shared")
  let args = @json.FlowData::new()
  args.insert_str("f_posts", "postB")
  assert_eq(form_handler(fp_exec_of("posts", args)), "userB,shared")

  let no_provider_ctx : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 2)
  @interceptor.register_post_assignment_handlers(no_provider_ctx, None)
  let no_provider_task = no_provider_ctx.find_assignment_handler(task_name).unwrap()
  let no_provider_form = no_provider_ctx.find_assignment_handler(form_name).unwrap()
  assert_eq(no_provider_task(fp_exec_of("postA", @json.FlowData::new())), "")
  assert_eq(no_provider_form(fp_exec_of("posts", args)), "")
}

///|
async test "fp: 旧 TaskRole/FormField/FormUser/FormDept 语义回归" {
  let org : @spi.OrgUserProviderFnsSync = {
    find_dept_leaders: d => {
      if d == "deptA" { ["leaderA"] } else { [] }
    },
    find_dept_main_leaders: _d => [],
    find_by_role: r => {
      if r == "roleNode" { ["roleUser"] } else { [] }
    },
  }
  assert_eq(
    @interceptor.task_role_assignee_handler(Some(org.to_async()))(
      fp_exec_of("roleNode", @json.FlowData::new()),
    ),
    "roleUser",
  )

  let hash_only = @json.FlowData::new()
  hash_only.insert_str("postCodes", "postA")
  assert_eq(
    @interceptor.form_field_assignee_handler()(fp_exec_of("manager#postCodes", hash_only)),
    "",
  )

  let user : (String) -> @model.UserInfo? raise @error.JeeflowError = uid => {
    if uid == "emp" {
      Some(@model.UserInfo::make(user_id="emp", real_name="员工", dept_id="deptA"))
    } else {
      None
    }
  }
  let base : @interceptor.OrgAssignBase = {
    user: Some(@spi.async_of_sync(user)),
    org: Some(org.to_async()),
  }
  let user_args = @json.FlowData::new()
  user_args.insert_str("f_leader", "emp,other")
  assert_eq(
    @interceptor.form_user_dept_leader_handler(base)(fp_exec_of("leader", user_args)),
    "leaderA",
  )

  let dept_args = @json.FlowData::new()
  dept_args.insert("depts", @json.array_of([@json.string_of("deptA,deptB")]))
  assert_eq(
    @interceptor.form_dept_leader_handler(base)(fp_exec_of("depts", dept_args)),
    "",
  )
}
