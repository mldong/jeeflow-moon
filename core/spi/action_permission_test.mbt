// action → 权限码映射（引擎内置默认件）测试 —— 语义权威＝java DefaultActionPermissionProvider。
// 两张表逐条钉死：放行 11 条（含统计三条）／OR 7 条（含 issues/246／247 两枚新 action）／
// 默认派生 wf:{action /→:} ＋ 反向哨兵（transfer／removeTaskActor 不许被顺手收进表）。
// 纯同步代码 ⇒ 全部用普通 test（本栈 async 用例在 wasm-gc 档会被静默丢弃）。

///|
test "spi-ap: 默认派生——单斜杠与多段斜杠各一枚" {
  // 未进任何表的 action：wf:{action 的 / 全部换成 :}
  assert_eq(@spi.default_action_permission_provider("processDefine/page"), [
    "wf:processDefine:page",
  ])
  assert_eq(
    @spi.default_action_permission_provider("processInstance/stats/custom"),
    ["wf:processInstance:stats:custom"],
  )
}

///|
test "spi-ap: OR 语义——两码与三码各一枚" {
  assert_eq(@spi.default_action_permission_provider("processDefine/detail"), [
    "wf:processDefine:detail", "wf:processDesign:listByType",
  ])
  assert_eq(
    @spi.default_action_permission_provider("processDefine/getLastByName"),
    [
      "wf:processDefine:detail", "wf:processDesign:listByType", "wf:processDefine:getLastByName",
    ],
  )
}

///|
test "spi-ap: OR 表其余四条逐条对齐 java" {
  assert_eq(
    @spi.default_action_permission_provider("processDefine/startAndExecute"),
    ["wf:processDefine:startAndExecute", "wf:processDesign:listByType"],
  )
  assert_eq(
    @spi.default_action_permission_provider("processTask/candidatePage"),
    ["wf:processTask:execute", "wf:processTask:candidatePage"],
  )
  assert_eq(
    @spi.default_action_permission_provider("processTask/jumpAbleTaskNameList"),
    ["wf:processTask:execute"],
  )
}

///|
test "spi-ap: 放行族交出空数组——含统计三条" {
  assert_eq(@spi.default_action_permission_provider("processInstance/detail"), [])
  assert_eq(
    @spi.default_action_permission_provider("processInstance/highLight"),
    [],
  )
  assert_eq(
    @spi.default_action_permission_provider("processInstance/approvalRecord"),
    [],
  )
  assert_eq(
    @spi.default_action_permission_provider(
      "processInstance/getAssigneeTextData",
    ),
    [],
  )
  assert_eq(
    @spi.default_action_permission_provider("processInstance/bizData"),
    [],
  )
  assert_eq(@spi.default_action_permission_provider("processTask/detail"), [])
  assert_eq(
    @spi.default_action_permission_provider("processTask/addCandidate"),
    [],
  )
  assert_eq(@spi.default_action_permission_provider("processTask/latest"), [])
  // 统计三条（issues/103 收口：普通用户分析页曾被默认规则 wf:processInstance:stats:* 拦下）
  assert_eq(
    @spi.default_action_permission_provider("processInstance/stats/overview"),
    [],
  )
  assert_eq(
    @spi.default_action_permission_provider("processInstance/stats/trend"),
    [],
  )
  assert_eq(
    @spi.default_action_permission_provider("processInstance/stats/group"),
    [],
  )
}

///|
test "spi-ap: 两枚新 action 恰一枚 wf:processTask:execute（issues/246／247 · B 案）" {
  assert_eq(@spi.default_action_permission_provider("processTask/recall"), [
    "wf:processTask:execute",
  ])
  assert_eq(
    @spi.default_action_permission_provider(
      "processTask/revokeDynamicCountersign",
    ),
    ["wf:processTask:execute"],
  )
}

///|
test "spi-ap: 反向哨兵——transfer／removeTaskActor 仍走默认派生（不收进 OR 表）" {
  assert_eq(@spi.default_action_permission_provider("processTask/transfer"), [
    "wf:processTask:transfer",
  ])
  assert_eq(
    @spi.default_action_permission_provider("processTask/removeTaskActor"),
    ["wf:processTask:removeTaskActor"],
  )
}

///|
test "spi-ap: 两张表条目数钉死 7 与 11（含名册逐条）" {
  let or_actions = @spi.action_permission_or_actions()
  assert_eq(or_actions.length(), 7)
  assert_eq(or_actions.contains("processDefine/detail"), true)
  assert_eq(or_actions.contains("processDefine/startAndExecute"), true)
  assert_eq(or_actions.contains("processDefine/getLastByName"), true)
  assert_eq(or_actions.contains("processTask/candidatePage"), true)
  assert_eq(or_actions.contains("processTask/jumpAbleTaskNameList"), true)
  assert_eq(or_actions.contains("processTask/recall"), true)
  assert_eq(or_actions.contains("processTask/revokeDynamicCountersign"), true)

  let no_perm = @spi.action_permission_no_perm_actions()
  assert_eq(no_perm.length(), 11)
  assert_eq(no_perm.contains("processInstance/detail"), true)
  assert_eq(no_perm.contains("processInstance/highLight"), true)
  assert_eq(no_perm.contains("processInstance/approvalRecord"), true)
  assert_eq(no_perm.contains("processInstance/getAssigneeTextData"), true)
  assert_eq(no_perm.contains("processInstance/bizData"), true)
  assert_eq(no_perm.contains("processTask/detail"), true)
  assert_eq(no_perm.contains("processTask/addCandidate"), true)
  assert_eq(no_perm.contains("processTask/latest"), true)
  assert_eq(no_perm.contains("processInstance/stats/overview"), true)
  assert_eq(no_perm.contains("processInstance/stats/trend"), true)
  assert_eq(no_perm.contains("processInstance/stats/group"), true)

  // 两张表不得重名（同一条 action 既放行又 OR ＝读哪档看运气）
  assert_eq(
    or_actions.filter(fn(a : String) -> Bool { no_perm.contains(a) }).length(),
    0,
  )
}

///|
test "spi-ap: 提供者抽象的 trait 形状 + 元数据清单条目" {
  let provider = @spi.DefaultActionPermissionProvider::new()
  assert_eq(provider.permission_codes("processTask/recall"), [
    "wf:processTask:execute",
  ])
  assert_eq(provider.permission_codes("processInstance/detail"), [])
  assert_eq(provider.permission_codes("processDefine/page"), [
    "wf:processDefine:page",
  ])
  // 泛型入口（java ServiceContext.find 直调场景的同位）
  assert_eq(@spi.permission_codes_of(provider, "processDefine/detail"), [
    "wf:processDefine:detail", "wf:processDesign:listByType",
  ])
  let (handler_type, class_name) = @spi.action_permission_provider_meta()
  assert_eq(handler_type, "ActionPermissionProvider")
  assert_eq(
    class_name, "com.mldong.jeeflow.spi.DefaultActionPermissionProvider",
  )
}

///|
test "spi-ap: 内置表交出的是副本——调用方改写不回灌引擎表" {
  let first = @spi.default_action_permission_provider("processDefine/detail")
  assert_eq(first.length(), 2)
  first[0] = "wf:tampered"
  assert_eq(
    @spi.default_action_permission_provider("processDefine/detail")[0],
    "wf:processDefine:detail",
  )
  let perms = @spi.action_permission_no_perm_actions()
  assert_eq(perms.length(), 11)
  perms[0] = "wf:tampered"
  assert_eq(
    @spi.action_permission_no_perm_actions().contains("processInstance/detail"),
    true,
  )
}

///|
test "spi-ap: Ctx 未注入兜底内置默认件；注入后按覆盖方走（集成方可换自家码表）" {
  let base : @spi.Ctx[Int32, Int32] = @spi.Ctx::new(1, 101)
  assert_eq(base.permission_codes("processTask/recall"), [
    "wf:processTask:execute",
  ])
  assert_eq(base.permission_codes("processInstance/stats/trend"), [])
  assert_eq(base.permission_codes("processDefine/page"), [
    "wf:processDefine:page",
  ])
  // 另一套权限码体系的特殊集成方覆盖注册 ⇒ 内置表让位
  let _ = base.with_action_permission_provider(fn(
    _a : String,
  ) -> Array[String] {
    ["custom:code"]
  })
  assert_eq(base.permission_codes("processTask/recall"), ["custom:code"])
}
