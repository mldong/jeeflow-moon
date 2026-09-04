// jeeflow-core/error —— 移植自 rust jeeflow-core/src/error.rs
// 引擎错误码：业务失败恒 99999999（spec/06 §2.1，方案 §3.3 只发明 99999999）

///|
pub const ERR_BUSINESS : Int64 = 99999999L

///|
pub(all) suberror JeeflowError {
  Business(String)
  UnknownAction(String)
  DefineNotFound(Int64)
  InstanceNotFound(Int64)
  TaskNotFound(Int64)
  PermissionDenied(String)
  InvalidState(String)
  InvalidSubmitType(Int64)
  ParseError(String)
  Internal(String)
} derive(Eq)

///|
pub fn JeeflowError::code(self : JeeflowError) -> Int64 {
  ERR_BUSINESS
}

///|
pub fn JeeflowError::message(self : JeeflowError) -> String {
  match self {
    Business(msg) => msg
    UnknownAction(a) => "未知 action: \{a}"
    DefineNotFound(id) => "流程定义不存在: \{id}"
    InstanceNotFound(id) => "流程实例不存在: \{id}"
    TaskNotFound(id) => "任务不存在: \{id}"
    PermissionDenied(msg) => "权限不足: \{msg}"
    InvalidState(msg) => "非法状态转换: \{msg}"
    InvalidSubmitType(st) => "非法 submitType: \{st}"
    ParseError(msg) => "解析错误: \{msg}"
    Internal(msg) => "内部错误: \{msg}"
  }
}

///|
impl Show for JeeflowError with fn output(self, logger) {
  logger.write_string(self.message())
}
