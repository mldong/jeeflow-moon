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

///|
pub fn ProcessModel::get_end_nodes(self : ProcessModel) -> Array[NodeModel] {
  self.get_nodes_by_type(End)
}

///|
/// 8 节点类型
pub(all) enum NodeType {
  Start
  Task
  Decision
  Fork
  Join
  End
  Custom
  SubProcess
} derive(Eq, Show)

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
    _ => Custom
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
  }
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
            match (try? @string.parse_int(s)) {
              Ok(n) => if n == 1 { 1 } else { 0 }
              Err(_) => 0
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
  let perms : Map[String, Int] = Map::new()
  for k, v in self.properties {
    if k.starts_with("PERMISSION_") {
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
  match root.value("nodes") {
    Some(nodes_val) =>
      match nodes_val {
        Json::Array(items) =>
          for node_val in items {
            let id = @json.get_str(node_val, "id").unwrap_or("")
            let raw_type = @json.get_str(node_val, "type").unwrap_or("snaker:task")
            let node_type = NodeType::from_snaker_type(raw_type)
            let display_name = match @json.get_str(node_val, "displayName") {
              Some(s) => Some(s)
              None =>
                match node_val.value("text") {
                  Some(t) => @json.get_str(t, "value")
                  None => None
                }
            }
            let properties : Map[String, Json] = Map::new()
            match node_val.value("properties") {
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
  match root.value("edges") {
    Some(edges_val) =>
      match edges_val {
        Json::Array(items) =>
          for edge_val in items {
            let id = @json.get_str(edge_val, "id").unwrap_or("")
            let source_node_id = @json.get_str(edge_val, "sourceNodeId").unwrap_or("")
            let target_node_id = @json.get_str(edge_val, "targetNodeId").unwrap_or("")
            let label = match edge_val.value("text") {
              Some(t) => @json.get_str(t, "value")
              None => None
            }
            let properties : Map[String, Json] = Map::new()
            match edge_val.value("properties") {
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
