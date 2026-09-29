// 流程模型 —— LogicFlow JSON → ProcessModel（8 节点类型）
// 移植自 rust parser.rs；spec/01、spec/02

///|
pub(all) struct ProcessModel {
  name : String
  display_name : String
  model_type : String
  expire_time : String?
  persist_mode : String? // ARCHIVE / SYNC
  rel_table_name : String?
  nodes : Array[NodeModel]
  edges : Array[EdgeModel]
} derive(Eq)

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
  match self.get_start() {
    Some(start) =>
      match self.get_output_edges(start.id).get(0) {
        Some(edge) => self.get_node(edge.target_node_id)
        None => None
      }
    None => None
  }
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
/// 8 节点类型 ＋ 未知档（issues/142 A 批）
/// ⚠️ `Unknown` **不是第 9 种节点**，它是「类型表里没查到」那一档。旧形状是 `_ => Custom` 兜底
/// ⇒ 任何未知类型（拼错大小写的 `snaker:subProcess`、设计器写坏的串）都被当**记录类**执行。
/// 记录类与任务类从此分叉（spec/02 §6.1）之后，「未知一律按记录类」等于把没认出来的节点
/// 静默变成一条留痕行；反过来「未知一律报错」又违反 spec/04「节点属性配错不该把流程炸掉」。
/// ⇒ 本档只做两件事：**先记一条可诊断日志（带节点 id 与实得类型串），再跳过该节点**，
///   逐字照 java `ModelParser.java:79-90`（WARNING 后 continue）＋ spec/02 类型键义务 2。
/// 注：大小写归一与 `subProcess`/无前缀别名是 issues/141 G4 的 C 方案（先立法后补实现），
/// 本档**不做归一化** ⇒ 照 spec 写无前缀 `task` 的定义会落进这里，那是义务 1 未落地的已知后果。
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
} derive(Eq, Debug)

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
pub(all) struct NodeModel {
  id : String
  node_type : NodeType
  display_name : String
  properties : Map[String, Json]
} derive(Eq)

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
pub fn NodeModel::candidate_users(self : NodeModel) -> String? {
  self.prop_str("candidateUsers")
}

///|
pub fn NodeModel::candidate_groups(self : NodeModel) -> String? {
  self.prop_str("candidateGroups")
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
pub(all) struct EdgeModel {
  id : String
  source_node_id : String
  target_node_id : String
  label : String?
  properties : Map[String, Json]
} derive(Eq)

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
  { name, display_name, model_type, expire_time, persist_mode, rel_table_name, nodes, edges }
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend ProcessModel with Eq::{equal, not_equal}
pub extend NodeType with Eq::{equal, not_equal}
pub extend NodeType with Debug::{to_repr}
pub extend NodeModel with Eq::{equal, not_equal}
pub extend EdgeModel with Eq::{equal, not_equal}
