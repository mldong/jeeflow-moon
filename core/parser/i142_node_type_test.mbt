// issues/142 A 批 · spec/02「类型键的三条义务」第 2 条 + §6.1 —— **custom 显式档 / 未知另立一档**。
// 钉的病灶（`core/parser/parser.mbt` 原 `from_snaker_type`）：
//   match t { ... "snaker:end" => End, "snaker:subprocess" => SubProcess, _ => Custom }
// ⇒ 任何未知类型（含拼错大小写、含 `snaker:custom` 本身）都落进 Custom 兜底臂。记录类与任务类
// 分叉之后，「未知一律按记录类」就是把没认出来的节点静默执行掉。本轮把两件事分开：
// ① 加显式 `"snaker:custom"` 臂；② 未知另立 `Unknown` 档，行为照 java
// （`ModelParser.java:79-90`：WARNING 带 nodeId ＋ 实得类型串 → continue 跳过节点）。
// ⚠️ 大小写归一/无前缀别名是 issues/141 G4 的 C 方案（先立法后补实现），**本单不做归一化**，
//    所以下面 `subProcess`（大写 P）与无前缀 `task` 按「未知档」钉 —— 那是已知且刻意的。

///|
const TYPE_PROBE_FLOW : String =
  $|{"name": "i142-type-probe", "displayName": "i142 类型档", "type": "approval",
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "custom1", "type": "snaker:custom", "text": {"value": "记录"},
  $|   "properties": {"clazz": "com.mldong.jeeflow.test.TestCustomHandler", "val": "customResult"}},
  $|  {"id": "typo", "type": "snaker:subProcess", "text": {"value": "大小写拼错"},
  $|   "properties": {"form": "sub-form"}},
  $|  {"id": "bare", "type": "task", "text": {"value": "无前缀"}, "properties": {"assignee": "user1"}},
  $|  {"id": "nonsense", "type": "snaker:not-a-node", "text": {"value": "表里根本没有"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "custom1"},
  $|  {"id": "e2", "sourceNodeId": "custom1", "targetNodeId": "end"}
  $|]}

// ── ① 显式 custom 档 ──

///|
test "i142: snaker:custom 是显式档，不再由兜底臂代答" {
  assert_true(@parser.NodeType::from_snaker_type("snaker:custom") is @parser.Custom)
  // 其余七档原样不动（回归：显式臂加进来不许把别的档顶掉）
  for pair in [
    ("snaker:start", @parser.Start),
    ("snaker:task", @parser.Task),
    ("snaker:decision", @parser.Decision),
    ("snaker:fork", @parser.Fork),
    ("snaker:join", @parser.Join),
    ("snaker:end", @parser.End),
    ("snaker:subprocess", @parser.SubProcess),
  ] {
    let (t, want) = pair
    if @parser.NodeType::from_snaker_type(t) != want {
      fail("既有档回归破坏：\{t} → \{@parser.NodeType::from_snaker_type(t).as_str()}")
    }
  }
}

///|
test "i142: custom 节点进模型、按类型取得到，clazz/val 属性读得到" {
  let model = @parser.parse_model(TYPE_PROBE_FLOW)
  let node = match model.get_node("custom1") {
    Some(n) => n
    None => fail("显式 snaker:custom 档必须进模型")
  }
  assert_true(node.node_type is @parser.Custom)
  assert_eq(model.get_nodes_by_type(@parser.Custom).length(), 1)
  assert_eq(node.prop_str("clazz").unwrap(), "com.mldong.jeeflow.test.TestCustomHandler")
  assert_eq(node.prop_str("val").unwrap(), "customResult")
}

// ── ② 未知另立一档 ──

///|
test "i142: 未知类型落 Unknown 档，不再被当 Custom" {
  // 逐档都是旧兜底臂会答成 Custom 的串：大小写拼错 / 无前缀 / 表里根本没有 / 缺省空串
  for t in ["snaker:subProcess", "task", "snaker:not-a-node", "snaker:custom1", ""] {
    let got = @parser.NodeType::from_snaker_type(t)
    if got is @parser.Unknown {
      ()
    } else {
      fail("未知档应命中 Unknown，实得=\{got.as_str()}（输入 \{t}）")
    }
  }
}

///|
test "i142: 未知档在解析期被跳过（不入模型），显式 custom 档照常入模型" {
  let model = @parser.parse_model(TYPE_PROBE_FLOW)
  // 三条未知档都不在模型里：拼错大小写的 subProcess、无前缀 task、表里根本没有的类型
  assert_true(model.get_node("typo") is None)
  assert_true(model.get_node("bare") is None)
  assert_true(model.get_node("nonsense") is None)
  // 只剩 start + custom1 + end 三档在册（旧形状下这三条未知档会被当 Custom 一并入册 ⇒ 本格必红）
  assert_eq(model.nodes.length(), 3)
  assert_eq(model.get_nodes_by_type(@parser.Custom).length(), 1)
  // 出边不炸：未知节点取不到边也取不到目标，流程不因它误执行
  assert_eq(model.get_output_edges("typo").length(), 0)
  let end_node = model.get_target_node(model.get_output_edges("custom1")[0])
  assert_eq(end_node.unwrap().id, "end")
}

///|
test "i142: 未知档日志文案带节点 id 与实得类型串（可诊断，非静默）" {
  let w = @parser.unknown_node_warning("nonsense", "snaker:not-a-node")
  for need in ["nonsense", "snaker:not-a-node", "该节点及其出边将被跳过", "[jeeflow]"] {
    if !w.contains(need) {
      fail("未知档日志缺 \{need}，实得=\{w}")
    }
  }
}

///|
test "i142: as_str 覆盖 Unknown（门面 taskModel.type 出口不塌成 custom）" {
  assert_eq(@parser.Unknown.as_str(), "unknown")
  assert_eq(@parser.Custom.as_str(), "custom")
}
