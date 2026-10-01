// jeeflow-core/error —— 移植自 rust jeeflow-core/src/error.rs
// 引擎错误码：业务失败恒 99999999（spec/06 §2.1，方案 §3.3 只发明 99999999）

///|
pub const ERR_BUSINESS : Int64 = 99999999L

///|
/// 内部异常对外只说这一句（issues/137 §3-1 · spec 06 §2.12；逐字＝java
/// `JeeflowFacade.INTERNAL_FAILURE_MSG`，八栈同一串、不许改措辞）。
pub const INTERNAL_FAILURE_MSG : String = "流程处理失败"

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
  /// issues/137-G／139：对外只给固定文案（逐字＝java 基准），底层原文另放一档供日志用。
  ///
  /// 走**新增变体**而不是改上面那条 `ParseError`：`error_test.mbt:21` 钉着
  /// `ParseError("bad json").message().contains("bad json")`——那是"调用方自己写的文案要能看见"
  /// 的通用档，动它就是改既有测试期望值。rust 同一条决定（`ParseErrorWithCause(msg, Box<..>)`）。
  ParseErrorWithCause(String, String)
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
    ParseErrorWithCause(msg, _) => msg
    Internal(msg) => "内部错误: \{msg}"
  }
}

///|
/// 「这条错误的 message 能不能原样进对外 msg」判别式（issues/137 §3-1 · spec 06 §2.12；
/// 对应 java `JeeflowFacade.isForeignDetail(type,message,cause,trace)`：true ⇒ 属内部信息 ⇒
/// 出口只给 INTERNAL_FAILURE_MSG，原文只进日志与 detail()，不得拼进 msg 或任何其它对外字段）。
///
/// java 要五条启发式（message null／契约族／裸包装／运行时类型族／抛出点），是因为它的契约文案
/// 散落在 JeeflowException 与约十处裸 RuntimeException/ISE/IAE 上，只能逐条判「谁写的文案」。
/// 本栈**变体即档位**（批三 §1.5）：`Internal` 是唯一内部档——mysql 驱动五条腿
/// （conn/tx 的 `Internal("mysql …: 驱动原文")`）与一切内部自诊断都走它；其余变体的 message
/// 全部是引擎自己写的契约文案（八栈＋十三壳＋前端 toast 逐字对齐）⇒ 照旧透出。所以判别式
/// 收敛成「变体是不是 Internal」一条，**不移植 java 的类型族启发式**（把简单问题复杂化）。
/// 纯函数、零副作用：文案判据（本函数）与副作用（日志，门面出口经 detail()）各自可测。
pub fn JeeflowError::is_foreign_detail(self : JeeflowError) -> Bool {
  match self {
    Internal(_) => true
    _ => false
  }
}

///|
/// cause 分离里"进日志"的那一半：只有带底层详情的变体返回 Some。
/// 出口 msg 走 `message()`（只给固定文案），日志走这里（原文照抄，不裁剪不转义）。
pub fn JeeflowError::detail(self : JeeflowError) -> String? {
  match self {
    ParseErrorWithCause(_, d) => Some(d)
    // issues/137 §3-1：Internal 档的原文同样只进日志——出口 msg 由 is_foreign_detail 换成
    // INTERNAL_FAILURE_MSG 后，驱动原文（"mysql query: <原文>" 那五条腿）从这里取回。
    // 复用批二同一枚 detail() 机制，不另起一套（spec §2.11 尾注「不要再抄第二份」同理）。
    Internal(d) => Some(d)
    _ => None
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
