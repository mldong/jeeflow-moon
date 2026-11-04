// 门面两腿：已办撤回（issues/246）与撤回动态会签（issues/247）
//
// 基准＝java `facade/JeeflowFacade.taskRecall` / `taskRevokeCountersign`（判据与落库全在引擎，
// 门面只做参数归一＋信封）＋ spec 06 §processTask/recall · §processTask/revokeDynamicCountersign。
// 两腿的判据位序、逐字文案与「报错即零写入」承诺见 `core/engine/recall.mbt`／`core/engine/collect.mbt`。

///|
/// `reason` 取值（逐字＝java `toStr(args.get("reason"))`：缺失/JSON null ⇒ None，
/// 其余标量按原文串收——不这样处理的话"传了个数字当原因"在门面就静默变成"没传"）。
fn arg_reason(args : Map[String, Json]) -> String? {
  match args.get("reason") {
    None => None
    Some(Json::Null) => None
    Some(Json::String(s)) => Some(s)
    Some(v) => Some(@json.stringify(v))
  }
}

///|
/// 已办撤回（issues/246，spec 06 §processTask/recall）：办理人撤回**自己刚办结的那一手**，
/// 同实例内复活重办。判据与落库全在引擎（`Engine::recall_task_async`），门面只做参数归一
/// （主键档缺失响亮报错，绝不拿 ''/0 当 id 落库）与信封包装。
///
/// 参数位序照 java：`operator` 硬必填在前（空/纯空白 ⇒ `operator 必填`，
/// ⚠️ 严禁用 `operator_arg`——那支空档回落 demo 缺省 user1，本 action 不接受），
/// 再取 `processTaskId`（缺失 ⇒ `processTaskId 缺失`）。
///
/// 出参 `data={processTaskId, taskState}`：`processTaskId`＝**复活的新行** id（出口层 C1 把
/// `*Id` 键字符串化 ⇒ 与 java `String.valueOf(taskId)` 同形），`taskState`＝10（DOING）。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_recall(
  self : Facade[R, E], args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  let operator = arg_required_str(args, "operator", "operator 必填")
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId 缺失")
  }
  let resurrected = (self.engine).recall_task_async(task_id, operator)
  @json.object_of([
    ("processTaskId", @json.number_of(resurrected.task_id)),
    ("taskState", @json.number_of(resurrected.task_state.to_int64())),
  ])
}

///|
/// 撤回动态会签（issues/247，spec 06 §processTask/revokeDynamicCountersign）：废弃主办行下全部
/// 未答成员行、账本追加撤回条目（`revoked=true`）、已交意见行原样保留、闸门自然恢复、轮次不消耗。
/// 独立 action，**不进 execute 参数空间**（撤回不是办结动作；任务操作族先例＝transfer/removeTaskActor）。
/// 判据与废弃全在引擎（`Engine::revoke_dynamic_countersign_async`）。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_revoke_countersign(
  self : Facade[R, E], args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  let operator = arg_required_str(args, "operator", "operator 必填")
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId 缺失")
  }
  (self.engine).revoke_dynamic_countersign_async(task_id, operator, arg_reason(args))
}
