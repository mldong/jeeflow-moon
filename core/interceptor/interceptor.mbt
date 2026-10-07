// 内置 AssignmentHandler（7 个，注册名=Java 全限定名）+ 字段权限过滤
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
/// 6. FormFieldAssigneeHandler —— 表单字段值分配（f_ 前缀优先、裸名兜底，issues/71）
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
            None => ""
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
