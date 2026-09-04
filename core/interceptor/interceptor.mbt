// 内置 AssignmentHandler（7 个，注册名=Java 全限定名）+ 字段权限过滤
// 移植自 rust interceptor.rs。MoonBit 形态：handler = (Execution) -> String raise JeeflowError 闭包，
// 由 register_builtin_assignment_handlers 工厂构造并捕获 user/org provider。
// AssignFn 类型 = (@exec.Execution) -> String raise @error.JeeflowError（MoonBit 0.10 无可靠 typealias，内联书写）

///|
/// 组织维度公共依赖（对齐 Go orgBase / Java OrgUserAssignmentHandlers）
pub(all) struct OrgAssignBase {
  user : ((String) -> @model.UserInfo? raise @error.JeeflowError)?
  org : @spi.OrgUserProviderFns?
}

///|
fn OrgAssignBase::dept_id_of(self : OrgAssignBase, user_id : String) -> String {
  if user_id.is_empty() {
    return ""
  }
  match self.user {
    Some(get_user) =>
      match (try? (get_user)(user_id)) {
        Ok(u) =>
          match u {
            Some(info) => info.dept_id()
            None => ""
          }
        Err(_) => ""
      }
    None => ""
  }
}

///|
fn OrgAssignBase::by_dept(self : OrgAssignBase, dept_id : String, main : Bool) -> String {
  if dept_id.is_empty() {
    return ""
  }
  match self.org {
    Some(org) => {
      let outcome = try? (if main {
        (org.find_dept_main_leaders)(dept_id)
      } else {
        (org.find_dept_leaders)(dept_id)
      })
      match outcome {
        Ok(ids) => if ids.length() > 0 { ids.join(",") } else { "" }
        Err(_) => ""
      }
    }
    None => ""
  }
}

///|
/// 1. OperatorAssignmentHandler —— 发起人
pub fn operator_assignment_handler() -> (@exec.Execution) -> String raise @error.JeeflowError {
  exec => exec.process_instance.operator
}

///|
/// 2/3. 发起人部门（分管）领导
pub fn applicant_dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (@exec.Execution) -> String raise @error.JeeflowError {
  exec => {
    let dept_id = base.dept_id_of(exec.process_instance.operator)
    base.by_dept(dept_id, main)
  }
}

///|
/// 4/5. 当前操作人部门（分管）领导
pub fn dept_leader_handler(
  base : OrgAssignBase,
  main~ : Bool = false
) -> (@exec.Execution) -> String raise @error.JeeflowError {
  exec => {
    let dept_id = base.dept_id_of(exec.operator)
    base.by_dept(dept_id, main)
  }
}

///|
/// 6. FormFieldAssigneeHandler —— 表单字段值分配（f_ 前缀优先、裸名兜底，issues/71）
pub fn form_field_assignee_handler() -> (@exec.Execution) -> String raise @error.JeeflowError {
  exec => {
    match exec.current_node {
      Some(node) => {
        let f_key = "f_\{node.id}"
        match exec.args.get_str(f_key) {
          Some(v) => return v
          None => ()
        }
        match exec.args.get_str(node.id) {
          Some(v) => return v
          None => ()
        }
        ""
      }
      None => ""
    }
  }
}

///|
/// 7. TaskRoleAssigneeHandler —— 节点 id 作角色码取人
pub fn task_role_assignee_handler(
  org : @spi.OrgUserProviderFns?
) -> (@exec.Execution) -> String raise @error.JeeflowError {
  exec => {
    match exec.current_node {
      None => ""
      Some(node) =>
        match org {
          None => ""
          Some(o) => {
            let outcome = try? (o.find_by_role)(node.id)
            match outcome {
              Ok(v) => if v.length() > 0 { v.join(",") } else { "" }
              Err(_) => ""
            }
          }
        }
    }
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
    if key.starts_with("f_") {
      let perm_key = "PERMISSION_\{key}"
      let perm_key_no_prefix = "PERMISSION_\{key.substring(start=2)}"
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
    } else if key.starts_with("tf_") {
      filtered.insert(key, value)
    } else {
      filtered.insert(key, value)
    }
  }
  filtered
}
