// 门面腿：动态协办（issues/253，spec 06 §processTask/aidant）
//
// 基准＝java `facade/JeeflowFacade.taskAidant`（判据/建单/账本全在引擎
// `core/engine/aidant.mbt::aidant_task_async`，门面只做参数归一＋信封包装，与 recall 同分工）。
// 成功 data → null（spec 06）；失败 msg 见跨栈统一文案表协办六行。
// 权限码复用 wf:processTask:execute（OR 规则，照 246/247 B 案惯例，见 core/spi/action_permission.mbt）。

///|
/// waitCompletion 入参解析（＝java `parseWaitCompletion`）：缺省 false（spec 06「选填 bool，
/// 缺省 false」）。布尔与 "true"/"false" 字符串两形都认（前端 JSON 与表单串两种来源）；
/// 其余值按缺省 false 处理——契约只定义了 bool 档，不为非法值新造文案
/// （跨栈统一文案表协办六行之外不加第七行）。
fn parse_wait_completion(value : Json?) -> Bool {
  match value {
    None => false
    Some(Json::True) => true
    Some(Json::False) => false
    Some(Json::String(s)) => s.trim(chars=" \t\r\n").to_lower() == "true"
    Some(_) => false
  }
}

///|
/// 动态协办（issues/253）：主办把"这活"交给别人干——按人派生 task_type=1 协办子行，
/// 主办行原样保留 DOING，节点推进仍由主办行办结触发。
///
/// 参数位序照 java：operator 硬必填在前（空/纯空白 ⇒ `operator 必填`，
/// ⚠️ 严禁用 operator_arg——那支空档回落 demo 缺省 user1，本 action 不接受），
/// 再取 processTaskId（缺失 ⇒ `processTaskId 缺失`），actorIds 逗号串与数组两形共用
/// §2.11 那枚归一单点（arg_actor_ids），空 ⇒ 逐字「actorIds 必填」。
/// reason 选填（缺失/JSON null ⇒ None，其余标量按原文串收，＝java toStr）；
/// waitCompletion 选填 bool，缺省 false＝主办不等协办办结即可推进。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::task_aidant(
  self : Facade[R, E], args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  let operator = arg_required_str(args, "operator", "operator 必填")
  let task_id = match arg_i64(args, "processTaskId") {
    Some(v) => v
    None => raise @error.Business("processTaskId 缺失")
  }
  let actors = arg_actor_ids(args)
  if actors.is_empty() {
    raise @error.Business(@engine.aidant_no_actors_msg)
  }
  let reason = arg_reason(args)
  let wait = parse_wait_completion(args.get("waitCompletion"))
  let _ = (self.engine).aidant_task_async(task_id, actors, reason, wait, operator)
  @json.null_json()
}