// 流程模型 —— LogicFlow JSON → ProcessModel（8 节点类型）
// 移植自 rust parser.rs；spec/01、spec/02

///|
#derive(Eq)
pub(all) struct ProcessModel {
  name : String
  display_name : String
  model_type : String
  expire_time : String?
  persist_mode : String? // ARCHIVE / SYNC
  pre_interceptors : String? // 定义级前置拦截器声明（audit8 R91 补齐：逗号分隔类全名，java ProcessModel.preInterceptors 同位）
  post_interceptors : String? // 定义级后置拦截器声明（逗号分隔类全名；java NodeModel.execPostInterceptors 同位）
  rel_table_name : String?
  nodes : Array[NodeModel]
  edges : Array[EdgeModel]
}

///|
pub fn ProcessModel::get_start(self : ProcessModel) -> NodeModel? {
  let mut found : NodeModel? = None
  for n in self.nodes {
    if n.node_type is Start {
      found = Some(n)
    }
  }
  found
}

///|
pub fn ProcessModel::get_node(self : ProcessModel, id : String) -> NodeModel? {
  let mut found : NodeModel? = None
  for n in self.nodes {
    if n.id == id {
      found = Some(n)
    }
  }
  found
}

///|
pub fn ProcessModel::get_nodes_by_type(self : ProcessModel, t : NodeType) -> Array[NodeModel] {
  let out : Array[NodeModel] = []
  for n in self.nodes {
    if n.node_type == t {
      out.push(n)
    }
  }
  out
}

///|
pub fn ProcessModel::get_output_edges(self : ProcessModel, node_id : String) -> Array[EdgeModel] {
  let out : Array[EdgeModel] = []
  for e in self.edges {
    if e.source_node_id == node_id {
      out.push(e)
    }
  }
  out
}

///|
pub fn ProcessModel::get_input_edges(self : ProcessModel, node_id : String) -> Array[EdgeModel] {
  let out : Array[EdgeModel] = []
  for e in self.edges {
    if e.target_node_id == node_id {
      out.push(e)
    }
  }
  out
}

///|
pub fn ProcessModel::get_target_node(self : ProcessModel, edge : EdgeModel) -> NodeModel? {
  self.get_node(edge.target_node_id)
}

///|
/// start 后第一个任务节点
pub fn ProcessModel::get_first_task_node(self : ProcessModel) -> NodeModel? {
  // spec/06:710：首个 `snaker:task` 节点按 nodes 序取，不跟 start 首条出边
  // （首边到 fork/decision 时旧实现会把非任务节点当首任务）。对齐 java/csharp。
  for n in self.nodes {
    if n.node_type is Task {
      return Some(n)
    }
  }
  None
}

///|
pub fn ProcessModel::is_first_task_node(self : ProcessModel, node_id : String) -> Bool {
  match self.get_first_task_node() {
    Some(first) => first.id == node_id
    None => false
  }
}

/// 能否退回到 parent_id 所在节点——照 mldong-boot2 NodeModel.canRejected 的形状：
/// 自 current 的入边回溯，命中 parent 放行；入边来源是 fork/join/start 时**跳过该条入边、
/// 不再深入**（boot2 是 continue，不是穿越），其余来源递归。subprocess 在 boot2 里被注释掉，
/// 等同普通节点。
pub fn ProcessModel::can_rejected(
  self : ProcessModel, current_id : String, parent_id : String
) -> Bool {
  for e in self.get_input_edges(current_id) {
    let source = e.source_node_id
    if source == parent_id {
      return true
    }
    let skip = match self.get_node(source) {
      None => true
      Some(n) =>
        n.node_type == Fork || n.node_type == Join || n.node_type == Start
    }
    if !skip && self.can_rejected(source, parent_id) {
      return true
    }
  }
  false
}

///|
pub fn ProcessModel::get_end_nodes(self : ProcessModel) -> Array[NodeModel] {
  self.get_nodes_by_type(End)
}

///|
/// 声明串归一：缺失／非串／纯空白（含 `"postInterceptors": ""` 这把共享夹具里常见的空声明）
/// 一律 ⇒ `None`＝「没声明」。审计要点：不能把空串当声明——那会让「声明档」命中而把
/// 引擎级注册列表整条绕过去（`flows/10-mixed-mode.json` 就是两把键都写成空串的形状）。
fn normalize_interceptor_decl(s : String?) -> String? {
  match s {
    Some(v) => {
      let t = v.trim(chars=" \t\r\n").to_owned()
      if t.is_empty() {
        None
      } else {
        Some(t)
      }
    }
    None => None
  }
}

///|
/// 按档取「本次动作生效的拦截器声明」（audit8 R91，issues/234 §4.2／spec02 §3 三条）。
/// 基准＝java `NodeModel.java:49-59`：节点 `properties` 声明优先，串空才回落流程根同名键，
/// **两档不叠加**（节点声明了就不再执行根声明里的那些）。两档都没声明 ⇒ `None`，回落动作归
/// 调用方：引擎侧回落「引擎级注册列表」＝R91 之前的现状语义；persist 侧把 `None` 当「没声明
/// ＝不挂载」。`prop` 用 java 属性名原串（`"preInterceptors"`／`"postInterceptors"`），
/// 它同时是错误文案里的档位名。本栈模型已在 `exec.process_model` 里 ⇒ 无 DB 回查，
/// 不存在 go/py/node 那条「根声明每定义只回查一行」的读放大问题。
pub fn ProcessModel::interceptor_decl(
  self : ProcessModel, node : NodeModel?, prop : String
) -> String? {
  let node_decl = match node {
    Some(n) => n.prop_str(prop)
    None => None
  }
  let root_decl = if prop == "preInterceptors" {
    self.pre_interceptors
  } else {
    self.post_interceptors
  }
  match normalize_interceptor_decl(node_decl) {
    Some(v) => Some(v)
    None => normalize_interceptor_decl(root_decl)
  }
}

///|
/// 8 节点类型 ＋ 未知档（issues/142 A 批）
/// ⚠️ `Unknown` **不是第 9 种节点**，它是「类型表里没查到」那一档。旧形状是 `_ => Custom` 兜底
/// ⇒ 任何未知类型（拼错大小写的 `snaker:subProcess`、设计器写坏的串）都被当**记录类**执行。
/// 记录类与任务类从此分叉（spec/02 §6.1）之后，「未知一律按记录类」等于把没认出来的节点
/// 静默变成一条留痕行；反过来「未知一律报错」又违反 spec/04「节点属性配错不该把流程炸掉」。
/// ⇒ 本档只做两件事：**先记一条可诊断日志（带节点 id 与实得类型串），再跳过该节点**，
///   逐字照 java `ModelParser.java:79-90`（WARNING 后 continue）＋ spec/02 类型键义务 2。
/// 注：大小写归一与 `subProcess`/无前缀别名是 issues/141 G4 的 C 方案（先立法后补实现），
/// 本档**不做归一化** ⇒ 照 spec 写无前缀 `task` 的定义会落进这里，那是义务 1 未落地的已知后果。
#derive(Eq, Debug)
pub(all) enum NodeType {
  Start
  Task
  Decision
  Fork
  Join
  End
  Custom
  SubProcess
  Unknown
}

///|
pub fn NodeType::from_snaker_type(t : String) -> NodeType {
  match t {
    "snaker:start" => Start
    "snaker:task" => Task
    "snaker:decision" => Decision
    "snaker:fork" => Fork
    "snaker:join" => Join
    "snaker:end" => End
    "snaker:subprocess" => SubProcess
    // issues/142 A 批：custom 从此是**显式档**，不再由兜底臂代答——旧兜底臂把「没认出来的
    // 类型」和「记录类节点」塌成同一档，拼错的定义会被当记录类照常执行并落一条留痕行。
    "snaker:custom" => Custom
    _ => Unknown
  }
}

///|
pub fn NodeType::as_str(self : NodeType) -> String {
  match self {
    Start => "start"
    Task => "task"
    Decision => "decision"
    Fork => "fork"
    Join => "join"
    End => "end"
    Custom => "custom"
    SubProcess => "subprocess"
    Unknown => "unknown"
  }
}

///|
/// 未知类型档的诊断日志文案（spec/02 类型键义务 2「带节点 id 与实得类型串」）。
/// 抽成纯函数有两个理由：① 这句文案是跨栈对得上的契约面（java/php 都是「该节点及其出边将被跳过:
/// nodeId=.., type=..」那一形），钉住文案才谈得上「可诊断」；② `println` 的效果在测试里读不回来，
/// 判据留在纯函数、副作用留在调用点，两件事各自可测。
pub fn unknown_node_warning(node_id : String, raw_type : String) -> String {
  "[jeeflow] 流程定义里的节点类型不在类型表里，该节点及其出边将被跳过: nodeId=\{node_id}, type=\{raw_type}"
}

///|
#derive(Eq)
pub(all) struct NodeModel {
  id : String
  node_type : NodeType
  display_name : String
  properties : Map[String, Json]
}

///|
pub fn NodeModel::prop_str(self : NodeModel, key : String) -> String? {
  match self.properties.get(key) {
    Some(v) => @json.as_str(v)
    None => None
  }
}

///|
pub fn NodeModel::prop_i64(self : NodeModel, key : String) -> Int64? {
  match self.properties.get(key) {
    Some(v) => @json.as_i64(v)
    None => None
  }
}

///|
/// 节点属性键：退回发起人后的重提方式（「退回修改、重提直返」；java `ReapplySupport.PROP_REAPPLY_MODE` 同位）
pub let reapply_mode_prop : String = "reapplyMode"

///|
/// `reapplyMode` 的缺省档：退回发起人后按申请节点的正常出边重提（既有行为）
pub let reapply_mode_normal : String = "NORMAL"

///|
/// `reapplyMode` 的直返档：退回发起人后，重提直接回到本来源节点建待办
pub let reapply_mode_return_to_source : String = "RETURN_TO_SOURCE"

///|
/// 解析并校验 `reapplyMode`（逐字对齐 java `ReapplyModeEnum.parse` / python `reapply.parse_mode`）：
/// 缺键 / JSON null / 空串 / 纯空白 ⇒ `NORMAL`；两档合法值原样收；**其余一律报配置错误**，
/// 不静默当缺省（配错档比"没配"危险：静默落回 NORMAL 会让直返定义按普通退回跑，
/// 申请人以为能直返、实际重新走完整流程）。非字符串标量按 `stringify` 原文进错误文案
/// （java `String.valueOf` 同形：`true` / `1` 这类值也属非法）。
pub fn parse_reapply_mode(raw : Json?, node_id : String) -> String raise @error.JeeflowError {
  let v = match raw {
    None => ""
    Some(Json::Null) => ""
    Some(Json::String(s)) => s
    Some(other) => other.stringify()
  }
  let t = v.trim(chars=" \t\r\n").to_owned()
  if t.is_empty() || t == reapply_mode_normal {
    reapply_mode_normal
  } else if t == reapply_mode_return_to_source {
    reapply_mode_return_to_source
  } else {
    raise @error.Business("节点[\{node_id}]的 reapplyMode 配置非法: \{t}")
  }
}

///|
/// 节点自己的 `reapplyMode`（解析期已由 `parse_model` 校验过；本方法重复校验是为了
/// 手搓的 `NodeModel`（测试／第三方直喂）也走同一枚判据，不出现第二份 trim/比较）
pub fn NodeModel::reapply_mode(self : NodeModel) -> String raise @error.JeeflowError {
  parse_reapply_mode(self.properties.get(reapply_mode_prop), self.id)
}

///|
/// 本节点配了 `RETURN_TO_SOURCE` 吗（缺省 NORMAL ⇒ false；非法值照旧抛配置错误）
pub fn NodeModel::is_return_to_source(self : NodeModel) -> Bool raise @error.JeeflowError {
  self.reapply_mode() == reapply_mode_return_to_source
}

///|
/// 节点属性键：后加签开关（规范 02 §4.3；缺省 false＝该节点行为与既有普通任务逐字一致）
pub let allow_add_sign_prop : String = "allowAddSign"

///|
/// 节点属性键：已办撤回开关（规范 02 §4.4，issues/246；缺省 false）
pub let allow_recall_prop : String = "allowRecall"

///|
/// 节点属性键：动态会签（征询模式）开关（规范 02 §4.4，issues/247；缺省 false，与 allowAddSign 互斥）
pub let dynamic_countersign_prop : String = "dynamicCountersign"

///|
/// 节点属性键：后加签轮次上限（整数 >=0，0＝不限；缺省 0）
pub let add_sign_max_rounds_prop : String = "addSignMaxRounds"

///|
/// 布尔开关的**唯一**解析尺子（issues/246/247 后三枚键 allowAddSign/allowRecall/dynamicCountersign
/// 共用，＝java `AddSignSupport.parseAllow(value, nodeName, keyName)` 的参数化形状）：
/// 缺键 / JSON null / 空串 / 纯空白 ⇒ false；`true`/`false` 两档（字符串档大小写不敏感）原样收；
/// **其余一律报配置错误**，不静默当缺省——静默落回 false 会让设计器里"勾了开关"的节点永远不认
/// 对应协议键，用户侧读起来像"功能没生效"（配错档比"没配"危险）。非字符串标量按 `stringify`
/// 原文进文案（java `String.valueOf` 同形：`1` 这类值也属非法）。
pub fn parse_allow(raw : Json?, node_id : String, key_name : String) -> Bool raise @error.JeeflowError {
  let v = match raw {
    None => ""
    Some(Json::Null) => ""
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    Some(Json::String(s)) => s
    Some(other) => other.stringify()
  }
  let t = v.trim(chars=" \t\r\n").to_owned()
  let lower = t.to_lower()
  if lower == "true" {
    true
  } else if t.is_empty() || lower == "false" {
    false
  } else {
    raise @error.Business("节点[\{node_id}]的 \{key_name} 配置非法: \{t}")
  }
}

///|
/// 解析并校验 `allowAddSign`（逐字对齐 java `AddSignSupport.parseAllow`，与上面
/// `parse_reapply_mode` 同一形状：缺省合法、非法 raise）。三枚布尔开关里**只有这一枚**
/// 有既有测试钉着原函数名与文案（`addsign-10`），故保留薄封装、判据本体在 `parse_allow`。
pub fn parse_allow_add_sign(raw : Json?, node_id : String) -> Bool raise @error.JeeflowError {
  parse_allow(raw, node_id, allow_add_sign_prop)
}

///|
/// 整数档判定（`addSignMaxRounds` 的两档文案单点）：`from_number` 为真时走 java 数字档尾注
/// 「（必须是整数）」，否则走字符串档「（必须是整数，0 表示不限）」；负数两档同为
/// 「（不得为负，0 表示不限）」。两条尾注分开是刻意的——跨栈逐字对齐要连档位名一起对。
fn rounds_int(
  text : String, node_id : String, from_number : Bool
) -> Int64 raise @error.JeeflowError {
  let parsed = try {
    Some(@string.parse_int64(text))
  } catch {
    _ => None
  } noraise {
    v => v
  }
  match parsed {
    Some(n) =>
      if n < 0L {
        raise @error.Business(
          "节点[\{node_id}]的 \{add_sign_max_rounds_prop} 配置非法: \{n}（不得为负，0 表示不限）",
        )
      } else {
        n
      }
    None =>
      if from_number {
        raise @error.Business(
          "节点[\{node_id}]的 \{add_sign_max_rounds_prop} 配置非法: \{text}（必须是整数）",
        )
      } else {
        raise @error.Business(
          "节点[\{node_id}]的 \{add_sign_max_rounds_prop} 配置非法: \{text}（必须是整数，0 表示不限）",
        )
      }
  }
}

///|
/// 解析并校验 `addSignMaxRounds`（逐字对齐 java `AddSignSupport.parseMaxRounds`）：
/// 缺键 / JSON null / 空串 / 纯空白 ⇒ 0＝不限；整数 >=0 原样收；非整数与负数各报一档。
/// 数字档取词法器留在 `repr` 里的字面原文（`1.5` / `1e30` 由此判死，>2^53 的整数也不被
/// double 取整——D-M5-3 同源）；本仓 `@json.number_of` 造的整数同样带 repr（它走 parse 原文）。
pub fn parse_add_sign_max_rounds(raw : Json?, node_id : String) -> Int64 raise @error.JeeflowError {
  match raw {
    None => 0L
    Some(Json::Null) => 0L
    Some(v) =>
      match v {
        // 数字档：词法器只在**超过 2^53** 时才把字面原文留在 `repr` 里（现读实测：
        // 1 / -1 / 1.5 的 repr 都是 None，2086772715431137280 才有原文）⇒ 有原文按原文判，
        // 没有就按 `stringify` 的规范化文本判（1 ⇒ "1"、1.5 ⇒ "1.5"、1e30 ⇒ "1e30"），
        // 整数判定与负数判定都收在 `rounds_int` 那一枚，尾注走 java 的数字档。
        Json::Number(_, repr~) =>
          match repr {
            Some(s) => rounds_int(s.trim(chars=" \t\r\n").to_owned(), node_id, true)
            None =>
              rounds_int(v.stringify().trim(chars=" \t\r\n").to_owned(), node_id, true)
          }
        Json::String(s) => rounds_text(s, node_id, false)
        // 布尔/对象/数组等标量：java 走 `String.valueOf(value)` 再 parseInt ⇒ 同字符串档
        other => rounds_text(other.stringify(), node_id, false)
      }
  }
}

///|
/// 字符串/其它标量档：裁空白后空 ⇒ 0＝不限，否则交整数判定（尾注走字符串档）
fn rounds_text(s : String, node_id : String, from_number : Bool) -> Int64 raise @error.JeeflowError {
  let t = s.trim(chars=" \t\r\n").to_owned()
  if t.is_empty() {
    0L
  } else {
    rounds_int(t, node_id, from_number)
  }
}

///|
/// 节点自己的 `allowAddSign`（解析期已由 `parse_model` 校验过；本方法重复校验是为了
/// 手搓的 `NodeModel`（测试／第三方直喂）也走同一枚判据，不出现第二份 trim/比较）
pub fn NodeModel::allow_add_sign(self : NodeModel) -> Bool raise @error.JeeflowError {
  parse_allow_add_sign(self.properties.get(allow_add_sign_prop), self.id)
}

///|
/// 节点自己的 `addSignMaxRounds`（判据同上，缺省 0＝不限）
pub fn NodeModel::add_sign_max_rounds(self : NodeModel) -> Int64 raise @error.JeeflowError {
  parse_add_sign_max_rounds(self.properties.get(add_sign_max_rounds_prop), self.id)
}

///|
/// 节点自己的 `allowRecall`（issues/246；解析期已由 `parse_model` 校验过，本方法重复校验是为了
/// 手搓的 `NodeModel`（测试／第三方直喂）也走同一枚判据）
pub fn NodeModel::allow_recall(self : NodeModel) -> Bool raise @error.JeeflowError {
  parse_allow(self.properties.get(allow_recall_prop), self.id, allow_recall_prop)
}

///|
/// 节点自己的 `dynamicCountersign`（issues/247；判据同上）
pub fn NodeModel::dynamic_countersign(self : NodeModel) -> Bool raise @error.JeeflowError {
  parse_allow(self.properties.get(dynamic_countersign_prop), self.id, dynamic_countersign_prop)
}

///|
/// 后加签两条解析期硬校验（规范 02 §4.3，基准＝java `ModelParser` 引用构造之后那一轮 for）：
/// 会签节点与首任务节点配了 `allowAddSign` 一律解析期报错，不做运行时降级——静默跑下去
/// 会让配置者以为开关生效，实际两档推进闸各裁各的。
/// ⚠️ 本栈「是不是首任务节点」取 `is_first_task_node`（nodes 序里第一个 `snaker:task`，
/// 与建单腿写 `isFirstTaskNode` 同一枚判据）；java 那侧沿 start 出边看
/// （`FlowUtil.isFirstTaskName`），两者只在"首任务节点不是 nodes 序第一个任务"的畸形图上
/// 分叉——本栈刻意选与自己建单判据同源的那一枚。
pub fn validate_add_sign_nodes(model : ProcessModel) -> Unit raise @error.JeeflowError {
  for n in model.nodes {
    if !(n.node_type is Task) {
      continue
    }
    if !parse_allow_add_sign(n.properties.get(allow_add_sign_prop), n.id) {
      continue
    }
    if n.is_countersign() {
      raise @error.Business(
        "会签节点[\{n.id}]不允许配置 allowAddSign：会签池内加人与会签之后加人是两种语义，推进闸会打架",
      )
    }
    if model.is_first_task_node(n.id) {
      raise @error.Business(
        "首任务节点[\{n.id}]不允许配置 allowAddSign：申请节点的办理是发起/重提语义，与加签路由打架",
      )
    }
  }
}

///|
/// 已办撤回两条解析期硬校验（规范 02 §4.4，issues/246；基准＝java `ModelParser` 引用构造之后的
/// 那一轮 for）：会签节点撤"谁的一票"语义不清；申请节点那手走实例撤回＋重新发起（既有通道），
/// 不需要同实例复活。配了就直接报错，不做运行时降级——静默跑下去会让配置者以为开关生效。
/// ⚠️ 首任务节点那档的档位名逐字取 java 的 `首任务节点[...]`（与上面 allowAddSign 那一档同源），
///   而 dynamicCountersign 的对应档写的是 `申请节点[...]`——两枚开关的文案在基准里就不对称，
///   本栈照抄不"顺手统一"（跨栈逐字对齐优先于文案美观）。
pub fn validate_recall_nodes(model : ProcessModel) -> Unit raise @error.JeeflowError {
  for n in model.nodes {
    if !(n.node_type is Task) {
      continue
    }
    if !parse_allow(n.properties.get(allow_recall_prop), n.id, allow_recall_prop) {
      continue
    }
    if n.is_countersign() {
      raise @error.Business(
        "会签节点[\{n.id}]不允许配置 allowRecall：撤\"谁的一票\"语义不清",
      )
    }
    if model.is_first_task_node(n.id) {
      raise @error.Business(
        "首任务节点[\{n.id}]不允许配置 allowRecall：申请节点走实例撤回＋重新发起，不需要同实例复活",
      )
    }
  }
}

///|
/// 动态会签（征询模式）三条解析期硬校验（规范 02 §4.4，issues/247；基准＝java `ModelParser`
/// 尾段那一轮 for）：与 `allowAddSign` 双开＝两档共用协议键 `tf_addSignOperators`、行为靠节点属性
/// 分流，双开即行为歧义；会签节点的池推进语义与征询的挂起语义打架；申请节点不需要征询。
pub fn validate_dynamic_countersign_nodes(model : ProcessModel) -> Unit raise @error.JeeflowError {
  for n in model.nodes {
    if !(n.node_type is Task) {
      continue
    }
    if !parse_allow(n.properties.get(dynamic_countersign_prop), n.id, dynamic_countersign_prop) {
      continue
    }
    if parse_allow(n.properties.get(allow_add_sign_prop), n.id, allow_add_sign_prop) {
      raise @error.Business(
        "节点[\{n.id}]不允许同时配置 allowAddSign 与 dynamicCountersign：两档共用 tf_addSignOperators，行为靠节点属性分流，双开＝行为歧义",
      )
    }
    if n.is_countersign() {
      raise @error.Business(
        "会签节点[\{n.id}]不允许配置 dynamicCountersign：会签池推进语义与征询挂起语义打架",
      )
    }
    if model.is_first_task_node(n.id) {
      raise @error.Business(
        "申请节点[\{n.id}]不允许配置 dynamicCountersign：申请节点那手走实例撤回＋重新发起，不需要征询挂起",
      )
    }
  }
}

/// 固定参与人
pub fn NodeModel::assignee(self : NodeModel) -> String? {
  self.prop_str("assignee")
}

///|
/// 动态参与人 handler 名
pub fn NodeModel::assignment_handler(self : NodeModel) -> String? {
  self.prop_str("assignmentHandler")
}

///|
/// 会签类型（C4 容错：数字 1/'1'/'ALL'/'COUNTERSIGN' 均认会签，其余 0）
pub fn NodeModel::perform_type(self : NodeModel) -> Int {
  match self.prop_i64("performType") {
    Some(n) => if n == 1L { 1 } else { 0 }
    None =>
      match self.prop_str("performType") {
        Some(s) => {
          let upper = s.to_upper()
          if upper == "1" || upper == "ALL" || upper == "COUNTERSIGN" {
            1
          } else {
            try @string.parse_int(s) catch {
              _ => 0
            } noraise {
              n => if n == 1 { 1 } else { 0 }
            }
          }
        }
        None => 0
      }
  }
}

///|
pub fn NodeModel::task_type(self : NodeModel) -> Int {
  match self.prop_i64("taskType") {
    Some(n) => n.to_int()
    None => 0
  }
}

///|
pub fn NodeModel::countersign_type(self : NodeModel) -> String {
  match self.prop_str("countersignType") {
    Some(s) => s
    None => "PARALLEL"
  }
}

///|
/// 会签完成条件（顶层属性优先，field 子对象兜底）
pub fn NodeModel::countersign_completion_condition(self : NodeModel) -> String? {
  match self.prop_str("countersignCompletionCondition") {
    Some(c) => return Some(c)
    None => ()
  }
  match self.properties.get("field") {
    Some(field_val) =>
      match field_val {
        Json::Object(field_obj) =>
          for k, v in field_obj {
            if k == "countersignCompletionCondition" {
              return @json.as_str(v)
            }
          }
        _ => ()
      }
    None => ()
  }
  None
}

///|
pub fn NodeModel::expr(self : NodeModel) -> String? {
  self.prop_str("expr")
}

///|
pub fn NodeModel::form_key(self : NodeModel) -> String? {
  self.prop_str("form")
}

///|
/// 顶层优先、`field` 子对象兜底取串（issues/177 R11：候选人双源，形状同会签条件腿）
fn NodeModel::prop_str_dual(self : NodeModel, key : String) -> String? {
  match self.prop_str(key) {
    Some(s) => return Some(s)
    None => ()
  }
  match self.properties.get("field") {
    Some(field_val) =>
      match field_val {
        Json::Object(field_obj) =>
          for k, v in field_obj {
            if k == key {
              return @json.as_str(v)
            }
          }
        _ => ()
      }
    None => ()
  }
  None
}

///|
pub fn NodeModel::candidate_users(self : NodeModel) -> String? {
  self.prop_str_dual("candidateUsers")
}

///|
pub fn NodeModel::candidate_groups(self : NodeModel) -> String? {
  self.prop_str_dual("candidateGroups")
}

///|
/// 字段权限（PERMISSION_* → 1 只读/2 可编辑/3 隐藏，C19）
pub fn NodeModel::field_permissions(self : NodeModel) -> Map[String, Int] {
  let perms : Map[String, Int] = Map([])
  for k, v in self.properties {
    if k.has_prefix("PERMISSION_") {
      match @json.as_i64(v) {
        Some(n) => perms[k] = n.to_int()
        None => ()
      }
    }
  }
  perms
}

///|
pub fn NodeModel::sub_process_name(self : NodeModel) -> String? {
  self.prop_str("subProcessName")
}

///|
pub fn NodeModel::is_countersign(self : NodeModel) -> Bool {
  self.perform_type() == 1
}

///|
#derive(Eq)
pub(all) struct EdgeModel {
  id : String
  source_node_id : String
  target_node_id : String
  label : String?
  properties : Map[String, Json]
}

///|
pub fn EdgeModel::expr(self : EdgeModel) -> String? {
  match self.properties.get("expr") {
    Some(v) => @json.as_str(v)
    None => None
  }
}

///|
pub fn EdgeModel::source_node_id(self : EdgeModel) -> String {
  self.source_node_id
}

///|
pub fn EdgeModel::target_node_id(self : EdgeModel) -> String {
  self.target_node_id
}

///|
/// LogicFlow JSON → ProcessModel
pub fn parse_model(json_str : String) -> ProcessModel raise @error.JeeflowError {
  let root = @json.parse_json(json_str)
  let name = match @json.get_str(root, "name") {
    Some(s) => s
    None => "unknown"
  }
  let display_name = @json.get_str(root, "displayName").unwrap_or(name)
  let model_type = @json.get_str(root, "type").unwrap_or("approval")
  let expire_time = @json.get_str(root, "expireTime")
  let persist_mode = @json.get_str(root, "persistMode")
  // 定义级后置拦截器声明（issues/150 的②要它才安全：java 是"声明即挂载"，节点级缺省回落流程级）
  // 定义级前置拦截器声明（audit8 R91：节点未声明时的回落档；键形＝java 类全名串，与 post 同形）
  let pre_interceptors = @json.get_str(root, "preInterceptors")
  let post_interceptors = @json.get_str(root, "postInterceptors")
  let rel_table_name = match @json.get_str(root, "relTableName") {
    Some(s) => Some(s)
    None => @json.get_str(root, "name")
  }
  // nodes
  let nodes : Array[NodeModel] = []
  match @json.get(root, "nodes") {
    Some(nodes_val) =>
      match nodes_val {
        Json::Array(items) =>
          for node_val in items {
            let id = @json.get_str(node_val, "id").unwrap_or("")
            let raw_type = @json.get_str(node_val, "type").unwrap_or("snaker:task")
            let node_type = NodeType::from_snaker_type(raw_type)
            // issues/142 A 批 · spec/02 类型键义务 2：**先留可诊断日志，再跳过**该节点。
            // 节点不入模型 ⇒ 它的出边随后取不到目标，与 java ModelParser 的 WARNING+continue 同形；
            // 旧形状是 `_ => Custom` 把未知档当记录类照常执行（本轮把两件事分开）。
            if node_type is Unknown {
              println(unknown_node_warning(id, raw_type))
              continue
            }
            let display_name = match @json.get_str(node_val, "displayName") {
              Some(s) => Some(s)
              None =>
                match @json.get(node_val, "text") {
                  Some(t) => @json.get_str(t, "value")
                  None => None
                }
            }
            let properties : Map[String, Json] = Map([])
            match @json.get(node_val, "properties") {
              Some(props) =>
                match props {
                  Json::Object(m) =>
                    for k, v in m {
                      properties[k] = v
                    }
                  _ => ()
                }
              None => ()
            }
            // 「退回修改、重提直返」：审批任务节点的 `reapplyMode` 在**解析期**校验（配错档
            // 不得静默当缺省）。基准＝java `TaskParser.parseNode` 尾段对 `ReapplyModeEnum.parse`
            // 的调用；记录类/网关节点没有这一属性，不校验（写了也不读）。
            if node_type is Task {
              let _ = parse_reapply_mode(properties.get(reapply_mode_prop), id)
              // 后加签两开关（规范 02 §4.3）：同一形状挂在解析期——缺省合法、非法值不得
              // 静默当缺省（基准＝java `TaskParser.parseNode` 尾段的 parseAllow/parseMaxRounds）。
              let _ = parse_allow_add_sign(properties.get(allow_add_sign_prop), id)
              let _ = parse_add_sign_max_rounds(properties.get(add_sign_max_rounds_prop), id)
              // 已办撤回／动态会签两开关（规范 02 §4.4，issues/246/247）：同一把尺子挂在解析期
              // （基准＝java `TaskParser.parseNode` 里紧挨 parseAllow(allowAddSign) 的另两刀）。
              let _ = parse_allow(properties.get(allow_recall_prop), id, allow_recall_prop)
              let _ = parse_allow(properties.get(dynamic_countersign_prop), id, dynamic_countersign_prop)
            }
            nodes.push({ id, node_type, display_name: display_name.unwrap_or(""), properties })
          }
        _ => ()
      }
    None => ()
  }
  // edges
  let edges : Array[EdgeModel] = []
  match @json.get(root, "edges") {
    Some(edges_val) =>
      match edges_val {
        Json::Array(items) =>
          for edge_val in items {
            let id = @json.get_str(edge_val, "id").unwrap_or("")
            let source_node_id = @json.get_str(edge_val, "sourceNodeId").unwrap_or("")
            let target_node_id = @json.get_str(edge_val, "targetNodeId").unwrap_or("")
            let label = match @json.get(edge_val, "text") {
              Some(t) => @json.get_str(t, "value")
              None => None
            }
            let properties : Map[String, Json] = Map([])
            match @json.get(edge_val, "properties") {
              Some(props) =>
                match props {
                  Json::Object(m) =>
                    for k, v in m {
                      properties[k] = v
                    }
                  _ => ()
                }
              None => ()
            }
            edges.push({ id, source_node_id, target_node_id, label, properties })
          }
        _ => ()
      }
    None => ()
  }
  let model : ProcessModel = { name, display_name, model_type, expire_time, persist_mode, pre_interceptors, post_interceptors, rel_table_name, nodes, edges }
  // 后加签两条解析期硬校验（会签节点／首任务节点配 allowAddSign）排在模型建好之后：
  // "是不是首任务节点"要拿整张 nodes 才能判（基准＝java ModelParser 尾段那一轮 for）。
  validate_add_sign_nodes(model)
  // 已办撤回（issues/246）与动态会签（issues/247）的解析期硬校验：次序照 java `ModelParser`
  // 尾段三轮 for（allowAddSign → allowRecall → dynamicCountersign），双开那格报的是第三轮的
  // "同时配置" 文案而不是前两轮的任一档，次序反了就报岔。
  validate_recall_nodes(model)
  validate_dynamic_countersign_nodes(model)
  model
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend ProcessModel with Eq::{equal, not_equal}
pub extend NodeType with Eq::{equal, not_equal}
pub extend NodeType with Debug::{to_repr}
pub extend NodeModel with Eq::{equal, not_equal}
pub extend EdgeModel with Eq::{equal, not_equal}
