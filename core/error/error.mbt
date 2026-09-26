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
  let _ = self
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
///|
/// 把"会 raise 的调用"物化成 `Result`（旧 `` 中**需要拿 Ok|Err 分支/断言**的那一类用这个）。
///
/// 迁移口径（moon 0.1.20260920 起 `` 已 deprecated）：
/// - 只想传播错误 ⇒ 直接调用（外层函数标 `raise` 即可），**不要**套本函数；
/// - 需要看成功值与失败值两态（断言、回退、转成本域错误）⇒ `attempt(fn() { ... })`。
/// 本函数存在的意义：让"我要一个 Result"这件事在代码里显式出现，而不是靠 `?` 猜。
pub fn [A, E : Error] attempt(f : () -> A raise E) -> Result[A, E] {
  try f() catch { e => Err(e) } noraise { v => Ok(v) }
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend JeeflowError with Eq::{equal, not_equal}
