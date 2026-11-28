// 内置 AssignmentHandler（13 个，注册名=Java 全限定名）+ 字段权限过滤
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
/// TaskPostAssigneeHandler —— 节点唯一编码即岗位编码，按 Provider 顺序返回岗位成员。
/// 节点为空、SPI 未注册、岗位不存在/无成员或查询异常 ⇒ 空串且不抛。
pub fn task_post_assignee_handler(
  post : @spi.PostUserProviderFns?
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  (async fn(exec) raise @error.JeeflowError {
    match exec.current_node {
      None => ""
      Some(node) =>
        if node.id.is_empty() {
          ""
        } else {
          match post {
            None => ""
            Some(provider) =>
              try {
                let ids = (provider.find_by_post)(node.id)
                if ids.length() > 0 { ids.join(",") } else { "" }
              } catch {
                _ => ""
              }
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
/// 10/11. FormDept{Main}LeaderAssignmentHandler —— 表单指定 1–N 个部门的（分管）领导。
/// 与 issues/254 的「表单指定用户」不同：这里直接把表单值当部门 id 列表，不经过用户部门查询。
/// 字段四档沿用 `find_form_user_field_value`；部门先按首次出现顺序去重，再逐部门查 SPI，
/// 最后按「部门输入顺序 → SPI 返回顺序」合并并去重 userId。任一部门查询失败只跳过该部门。
pub fn form_dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  let need_main = main
  (async fn(exec) raise @error.JeeflowError {
    let node_key = match exec.current_node {
      Some(node) => node.id
      None => ""
    }
    let dept_ids = form_dept_ids(find_form_user_field_value(exec.args, node_key))
    match base.org {
      None => ""
      Some(org) => {
        let out : Array[String] = []
        let seen_users : Map[String, Unit] = Map([])
        for dept_id in dept_ids {
          let leaders = try {
            if need_main {
              (org.find_dept_main_leaders)(dept_id)
            } else {
              (org.find_dept_leaders)(dept_id)
            }
          } catch {
            _ => []
          }
          for raw_id in leaders {
            append_unique_trimmed_id(out, seen_users, raw_id)
          }
        }
        out.join(",")
      }
    }
  })
}

///|
/// FormPostAssignmentHandler —— 表单指定 1–N 个岗位，按岗位成员分配参与者。
/// 字段四档沿用 `find_form_user_field_value`；岗位编码保序去重后逐个查询，
/// 单岗位异常只跳过该岗位；userId trim 后保序去重。SPI 缺失或最终无人 ⇒ 空串。
pub fn form_post_assignment_handler(
  post : @spi.PostUserProviderFns?
) -> (async (@exec.Execution) -> String raise @error.JeeflowError) {
  (async fn(exec) raise @error.JeeflowError {
    let node_key = match exec.current_node {
      Some(node) => node.id
      None => ""
    }
    let post_codes = form_post_codes(find_form_user_field_value(exec.args, node_key))
    match post {
      None => ""
      Some(provider) => {
        let out : Array[String] = []
        let seen_users : Map[String, Unit] = Map([])
        for post_code in post_codes {
          let user_ids = try {
            (provider.find_by_post)(post_code)
          } catch {
            _ => []
          }
          for raw_id in user_ids {
            append_unique_trimmed_id(out, seen_users, raw_id)
          }
        }
        out.join(",")
      }
    }
  })
}

///|
/// 显式注册两枚岗位 handler（MoonBit 无反射，运行时按 Java FQCN 分发）。
/// 即使 Provider 未注入也登记实体，由 handler 返回空参与者，避免"元数据有、运行时无"。
pub fn[R, E] register_post_assignment_handlers(
  ctx : @spi.Ctx[R, E],
  post : @spi.PostUserProviderFns?
) -> Unit {
  ctx.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskPostAssigneeHandler",
    task_post_assignee_handler(post),
  )
  ctx.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.FormPostAssignmentHandler",
    form_post_assignment_handler(post),
  )
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
/// 表单部门列表：标量按英文逗号拆；数组逐元素读取且**不二次拆逗号**。
/// trim 后丢空，`"0"`／数字 0 保留，部门 id 去重并保持首次出现顺序。
fn form_dept_ids(value : Json?) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  match value {
    None => ()
    Some(v) =>
      match @json.as_array(v) {
        Some(items) =>
          for item in items {
            append_unique_trimmed_id(out, seen, json_scalar_to_string(item))
          }
        None =>
          for part in comma_tokens(json_scalar_to_string(v)) {
            append_unique_trimmed_id(out, seen, part)
          }
      }
  }
  out
}

///|
/// 表单岗位列表：标量按英文逗号拆；数组逐元素读取且**不二次拆逗号**。
/// trim 后丢空，`"0"`／数字 0 保留，岗位编码去重并保持首次出现顺序。
fn form_post_codes(value : Json?) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  match value {
    None => ()
    Some(v) =>
      match @json.as_array(v) {
        Some(items) =>
          for item in items {
            append_unique_trimmed_id(out, seen, json_scalar_to_string(item))
          }
        None =>
          for part in comma_tokens(json_scalar_to_string(v)) {
            append_unique_trimmed_id(out, seen, part)
          }
      }
  }
  out
}

///|
/// 部门 id／岗位编码／SPI userId 共用的稳定去重：先 trim，空值丢弃，首次出现者保留。
fn append_unique_trimmed_id(
  out : Array[String],
  seen : Map[String, Unit],
  raw_id : String
) -> Unit {
  let id = raw_id.trim(chars=" \t\r\n").to_owned()
  if !id.is_empty() && seen.get(id) is None {
    seen[id] = ()
    out.push(id)
  }
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
