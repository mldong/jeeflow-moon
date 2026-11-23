// 内置 AssignmentHandler（9 个，注册名=Java 全限定名）+ 字段权限过滤
// 移植自 rust interceptor.rs。MoonBit 形态：handler = (Execution) -> String raise JeeflowError 闭包，
// 由 register_builtin_assignment_handlers 工厂构造并捕获 user/org provider。
// AssignFn 类型 = (@exec.Execution) -> String raise @error.JeeflowError（MoonBit 0.10 无可靠 typealias，内联书写）

///|
/// 组织维度公共依赖（对齐 Go orgBase / Java OrgUserAssignmentHandlers）
/// issues/146：`user` 与 org 三方法是宿主查库入口 ⇒ async 形状。
pub(all) struct OrgAssignBase {
  user : ((async (String) -> @model.UserInfo? raise @error.JeeflowError))?
  org : @spi.OrgUserProviderFns?
}

///|
async fn OrgAssignBase::dept_id_of(
  self : OrgAssignBase,
  user_id : String
) -> String raise @error.JeeflowError {
  if user_id.is_empty() {
    return ""
  }
  match self.user {
    Some(get_user) =>
      // SPI 是 `async (String) -> UserInfo? raise JeeflowError`：值即 UserInfo?；
      // 取人失败**吞成空串**（参与人解析不许炸掉流程），故落 catch 臂而不是往外抛
      try {
        match (get_user)(user_id) {
          Some(info) => info.dept_id()
          None => ""
        }
      } catch {
        _ => ""
      }
    None => ""
  }
}

///|
async fn OrgAssignBase::by_dept(
  self : OrgAssignBase,
  dept_id : String,
  main : Bool
) -> String raise @error.JeeflowError {
  if dept_id.is_empty() {
    return ""
  }
  match self.org {
    Some(org) => {
      try {
        let ids =
          if main {
            (org.find_dept_main_leaders)(dept_id)
          } else {
            (org.find_dept_leaders)(dept_id)
          }
        if ids.length() > 0 { ids.join(",") } else { "" }
      } catch {
        _ => ""
      }
    }
    None => ""
  }
}

///|
/// 1. OperatorAssignmentHandler —— 发起人（纯同步取值 ⇒ 走 @spi.async_of_sync 桥，零警告）
pub fn operator_assignment_handler()
  -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  @spi.async_of_sync((exec) => exec.process_instance.operator)
}

///|
/// 2/3. 发起人部门（分管）领导
pub fn applicant_dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  let need_main = main
  (async fn(exec) raise @error.JeeflowError {
    let dept_id = base.dept_id_of(exec.process_instance.operator)
    base.by_dept(dept_id, need_main)
  })
}

///|
/// 4/5. 当前操作人部门（分管）领导
pub fn dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  let need_main = main
  (async fn(exec) raise @error.JeeflowError {
    let dept_id = base.dept_id_of(exec.operator)
    base.by_dept(dept_id, need_main)
  })
}

///|
/// 6. FormFieldAssigneeHandler —— 表单字段值分配（issues/71 顺序 ＋ issues/48 第三档）
/// 三档＝`f_<id>` → 裸名 → `_NN` 去后缀后查**裸名 base**（`task_01` 读 `task`）。
/// 第三档历史上只有 moon／rust 两语言缺，issues/255 补齐成八语言同形；
/// `f_<base>` 是 issues/254 两枚新 handler 的扩面，本老类不跟。
/// 纯同步取值 ⇒ 走 @spi.async_of_sync 桥（零警告）；语义与旧闭包里的两处 return 等价。
pub fn form_field_assignee_handler()
  -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  @spi.async_of_sync(exec => match exec.current_node {
    Some(node) =>
      match exec.args.get_str("f_\{node.id}") {
        Some(v) => v
        None =>
          match exec.args.get_str(node.id) {
            Some(v) => v
            None => match number_suffix_base(node.id) {
              Some(base) =>
                match exec.args.get_str(base) {
                  Some(v) => v
                  None => ""
                }
              None => ""
            }
          }
      }
    None => ""
  })
}

///|
/// 7. TaskRoleAssigneeHandler —— 节点 id 作角色码取人
pub fn task_role_assignee_handler(
  org : @spi.OrgUserProviderFns?
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  (async fn(exec) raise @error.JeeflowError {
    match exec.current_node {
      None => ""
      Some(node) =>
        match org {
          None => ""
          Some(o) =>
            try {
              let v = (o.find_by_role)(node.id)
              if v.length() > 0 { v.join(",") } else { "" }
            } catch {
              _ => ""
            }
        }
    }
  })
}

///|
/// 8/9. FormUserDept{Main}LeaderAssignmentHandler —— 表单指定用户所属部门（分管）领导。
/// 场景＝HR 代员工提交／代理申请：表单里给出被代理人的用户 id，取**该员工**部门的
/// 经理／分管领导，与当前操作人无关（八语言契约 §3.3：字段 → user → dept → leader）。
/// 取不到（字段缺失／值为空／用户不存在／无部门／部门无领导／SPI 未注册）⇒ 空串且不抛，
/// 与 `dept_id_of`／`by_dept` 的吞错形状同族（参与人解析不许炸掉流程）。
pub fn form_user_dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  let need_main = main
  (async fn(exec) raise @error.JeeflowError {
    let node_key = match exec.current_node {
      Some(node) => node.id
      None => ""
    }
    let user_id = first_form_user_id(find_form_user_field_value(exec.args, node_key))
    if user_id.is_empty() {
      ""
    } else {
      let dept_id = base.dept_id_of(user_id)
      base.by_dept(dept_id, need_main)
    }
  })
}

///|
/// 「表单指定用户」两档 handler 专用的候选键表（八语言契约 §3.2，顺序即优先级）：
/// 1. `f_<nodeKey>`（jeeflow 引擎变量带 `f_` 前缀）2. `<nodeKey>` 裸名
/// 3. nodeKey 含 `#` ⇒ 最后一个 `#` 之后的 field：先裸名、再 `f_<field>`
/// 4. nodeKey 匹配 `^(.+?)_(\d+)$` ⇒ base：先 `f_<base>`、再 `<base>`
/// 3、4 两档各补 `f_` 变体是相对参照实现（mldong-fastapi-wf fe9233d）的唯一增量；
/// 现存 handler 走自己的查找：`#` 档始终是新 handler 专属，`_NN` 档 issues/255 起老类
/// `form_field_assignee_handler` 也认——但老类只查 base 裸名，不带 `f_<base>`。
fn form_user_field_candidates(node_key : String) -> Array[String] {
  let out : Array[String] = ["f_\{node_key}", node_key]
  match last_hash_segment(node_key) {
    Some(field) => {
      out.push(field)
      out.push("f_\{field}")
    }
    None => ()
  }
  match number_suffix_base(node_key) {
    Some(base) => {
      out.push("f_\{base}")
      out.push(base)
    }
    None => ()
  }
  out
}

///|
/// 四档并集查找：按 `form_user_field_candidates` 的顺序取**第一个存在的键**的值。
/// nodeKey 为空 ⇒ None（不拿空前缀去撞变量表）。键存在即命中，值为 null 也算命中
/// （后续 `first_form_user_id` 把 null 折成空串），与 rust/python 的 map-get 判据一致。
fn find_form_user_field_value(args : @json.FlowData, node_key : String) -> Json? {
  if node_key.is_empty() {
    return None
  }
  for key in form_user_field_candidates(node_key) {
    if args.contains_key(key) {
      return args.get(key)
    }
  }
  None
}

///|
/// 最后一个 `#` 之后的部分；不含 `#` 或右半为空 ⇒ None（rust `rfind('#')` + 非空判据同形）。
fn last_hash_segment(node_key : String) -> String? {
  let chars = node_key.to_array()
  let n = chars.length()
  let mut at = -1
  for j in 0..<n {
    if chars[j] == '#' {
      at = j
    }
  }
  if at < 0 {
    return None
  }
  let b = StringBuilder()
  for j in (at + 1)..<n {
    b.write_char(chars[j])
  }
  let field = b.to_string()
  if field.is_empty() {
    None
  } else {
    Some(field)
  }
}

///|
/// `^(.+?)_(\d+)$` 的等价实现（本引擎不引 regex 依赖）：从左往右第一个「后面是非空纯数字」的
/// 下划线处切分——惰性量词要的就是这个最早命中点。前缀至少一字符 ⇒ `_01` 不命中（同 rust）。
fn number_suffix_base(node_key : String) -> String? {
  let chars = node_key.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    if chars[i] == '_' && i > 0 && only_digits_after(chars, i) {
      let b = StringBuilder()
      for j in 0..<i {
        b.write_char(chars[j])
      }
      return Some(b.to_string())
    }
    i += 1
  }
  None
}

///|
/// 下划线 `at` 之后是否**非空且全是 ASCII 数字**（rust `suffix.chars().all(is_ascii_digit)` 同判据）。
fn only_digits_after(chars : Array[Char], at : Int) -> Bool {
  let n = chars.length()
  if at + 1 >= n {
    return false
  }
  let mut i = at + 1
  while i < n {
    let code = chars[i].to_int()
    if code < 48 || code > 57 {
      return false
    }
    i += 1
  }
  true
}

///|
/// 标量 → 字符串（对象/数组/空值没有 id 形状 ⇒ 空串）。rust `json_scalar_to_string` 同序：
/// str → i64（本栈 `as_i64` 对 Number 按 repr 原文精确解析，雪花 id 不取整）→ bool。
fn json_scalar_to_string(v : Json) -> String {
  match @json.as_str(v) {
    Some(s) => s
    None =>
      match @json.as_i64(v) {
        Some(i) => i.to_string()
        None =>
          match @json.as_bool(v) {
            Some(b) => b.to_string()
            None => ""
          }
      }
  }
}

///|
/// 逗号串切元素（数组元素不再二次拆逗号，见 `first_form_user_id`）。
fn comma_tokens(s : String) -> Array[String] {
  let out : Array[String] = []
  for part in s.split(",") {
    out.push(part.to_owned())
  }
  out
}

///|
/// 取**第一个**非空用户 id（逗号串／数组同样只取第一个，多值语义不在本轮承诺）。
/// 判空只比空串 ⇒ `"0"` 是合法 id（不被真值判据吃掉，与 python `== ""`／rust `is_empty` 同形）。
fn first_form_user_id(value : Json?) -> String {
  let tokens : Array[String] = match value {
    None => []
    Some(v) =>
      match @json.as_array(v) {
        Some(items) => items.map(json_scalar_to_string)
        None => comma_tokens(json_scalar_to_string(v))
      }
  }
  for token in tokens {
    let id = token.trim(chars=" \t\r\n").to_owned()
    if !id.is_empty() {
      return id
    }
  }
  ""
}

///|
/// 字段权限过滤（spec/09 §4.2，C19）：PERMISSION_f_{field} 优先 / PERMISSION_{stripped} 兜底；
/// 1 只读丢弃 / 2 可编辑通过 / 3 隐藏丢弃 / 其他默认通过
pub fn filter_fields_by_permission(
  args : @json.FlowData,
  permissions : Map[String, Int]
) -> @json.FlowData {
  let filtered = @json.FlowData::new()
  for key, value in args.inner() {
    if key.has_prefix("f_") {
      let perm_key = "PERMISSION_\{key}"
      let perm_key_no_prefix = "PERMISSION_\{key[2:]}"
      let perm = match permissions.get(perm_key) {
        Some(p) => p
        None =>
          match permissions.get(perm_key_no_prefix) {
            Some(p) => p
            None => 2 // 默认可编辑
          }
      }
      match perm {
        1 => () // 只读——丢弃
        3 => () // 隐藏——丢弃
        _ => filtered.insert(key, value)
      }
    } else if key.has_prefix("tf_") {
      filtered.insert(key, value)
    } else {
      filtered.insert(key, value)
    }
  }
  filtered
}

///|
/// 节点声明的字段权限表（`properties.field` 里的 `PERMISSION_*`）。
/// 与 persist 拦截器读同一处；java 侧 `TaskModel.ext` 也是从 `properties.field` 灌的
/// （`parser/impl/TaskParser.java:53-56`），所以两边的权限来源是同一个 JSON 位置，不是两套。
/// 值语义按 java `FlowUtil.toInt`：数字/数字串取整，解析不出来＝-1（＝"其他"，放行）。
pub fn node_field_permissions(node : @parser.NodeModel) -> Map[String, Int] {
  let perms : Map[String, Int] = Map([])
  match node.properties.get("field") {
    Some(f) =>
      match f {
        Json::Object(obj) =>
          for k, v in obj {
            if k.has_prefix("PERMISSION_") {
              let n = match @json.as_i64(v) {
                Some(i) => i.to_int()
                None => -1
              }
              perms[k] = n
            }
          }
        _ => ()
      }
    None => ()
  }
  perms
}

///|
/// 办理**入口**的字段权限过滤（spec/09 §4.2 1.8.2；java `FlowUtil.filterFieldByPerm(args, model, taskName)`
/// 同位，调用点在 `JeeflowEngineImpl.java:264`——入变量之前）。
/// issues/150 病灶一：这层在 moon 里"函数写了但零调用"，只读/隐藏字段的提交值于是**进了实例变量**，
/// 下一个没声明该字段权限的节点办理时就被写进业务表（跨节点绕过）；写侧 `filter_editable` 只挡当次。
/// 与 java 同形的三处放行：节点找不到 / 不是任务节点（记录类 custom 不算，java `instanceof TaskModel`）/
/// 无权限声明 ⇒ 原样返回 args。
pub fn filter_args_by_node_permission(
  args : @json.FlowData,
  model : @parser.ProcessModel,
  task_name : String
) -> @json.FlowData {
  let node = match model.get_node(task_name) {
    Some(n) => n
    None => return args
  }
  if !(node.node_type is @parser.Task) {
    return args
  }
  let perms = node_field_permissions(node)
  if perms.is_empty() {
    return args
  }
  filter_fields_by_permission(args, perms)
}
