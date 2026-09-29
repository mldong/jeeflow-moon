// 事件 fire 助手 —— issues/132「事件代码腿」九支码的构造与广播集中于此，便于逐键审计。
// 与 notify_cc_create（engine.mbt）同型：组装 spec §11.3 直传载荷键（camelCase），
// 走 @event.notify（逐监听器兜底 + 列表广播）。**只在落库之后由调用方触发**。
// 码 1/2/3 是既有支（issues/132 第二轮补的直传键——sourceId 不足以让集成层按实例归堆事件流水）；
// 码 5/6/7/8/9 为第一轮新增。
// 说明：MoonBit 的方法可定义在同包任意文件，这里独立成文件便于审计。

///|
/// 实例发起事件（spec §11.3 code 1 PROCESS_INSTANCE_START）。
/// sourceId=instanceId，载荷 instanceId。
/// 调用方义务：实例行 insert（save_instance）之后、建单/抄送两支之前 fire，
/// 使单条流从发起到办结的可见序为 [1,3,5,2]（§11.8 L2-30）。
pub fn[R, E] Engine::notify_instance_start(
  self : Engine[R, E], instance_id : Int64
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  let event = @event.ProcessEvent::make(@event.ProcessInstanceStart, instance_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 实例结束事件（spec §11.3 code 2 PROCESS_INSTANCE_END）。
/// sourceId=instanceId，载荷 instanceId + state（§11.3「state＝落库后的实例状态整数」）。
/// 调用方义务：实例 `state` 写 20/45 落库（update_instance）之后 fire。
/// ⚠️ 30(撤回)/40(终止) 不由本支表达——各有专属码 8/9；一场撤回同时发 8＋2
///    会让下游收到"流程已办结"的错通知（§11.3 code 2 行）。
pub fn[R, E] Engine::notify_instance_end(
  self : Engine[R, E], instance_id : Int64, state : Int
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_i64("state", state.to_int64())
  let event = @event.ProcessEvent::make(@event.ProcessInstanceEnd, instance_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 新待办生成事件（spec §11.3 code 3 PROCESS_TASK_START）。
/// sourceId=taskId，载荷 instanceId + taskId + actors（该待办的参与者列表，字符串数组；
/// 含 apply_surrogate 并入的被委托人，与落库的 actor 集合同口径）。
/// ⚠️ `instanceId` 是硬要求而非"方便字段"（§11.3 注）：本支 sourceId 是 taskId，
///    集成层 L2-30 的事件流水 sink 只能靠载荷里的 instanceId 把一条流的流水归到
///    `jeeflow:gate:events:<instanceId>` 一个键下；缺它 ⇒ 一条流被拆成多个 taskId 键、顺序读不全。
/// 调用方义务：**每个**任务行落库（save_task 分到 taskId）之后逐任务 fire。
pub fn[R, E] Engine::notify_task_start(
  self : Engine[R, E], instance_id : Int64, task_id : Int64, actors : Array[String]
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_i64("taskId", task_id)
  data.insert_string_array("actors", actors)
  let event = @event.ProcessEvent::make(@event.ProcessTaskStart, task_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 任务办结/退回事件（spec §11.3 code 5 TASK_COMPLETE / code 6 TASK_REJECT）。
/// sourceId=taskId，载荷 instanceId/taskId/operator/submitType。
/// 调用方义务：任务行 state 落库之后 fire（load_exec_for_task 的 update_task_by_id 之后）。
/// 5/6 互斥：由调用方按 submitType 选 event_type——退回动作只 fire 6，不再 fire 5。
pub fn[R, E] Engine::notify_task_result(
  self : Engine[R, E],
  event_type : @event.ProcessEventType,
  instance_id : Int64,
  task_id : Int64,
  operator : String,
  submit_type : Int64?
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_i64("taskId", task_id)
  data.insert_str("operator", operator)
  match submit_type {
    Some(st) => data.insert_i64("submitType", st)
    None => ()
  }
  let event = @event.ProcessEvent::make(event_type, task_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 转办事件（spec §11.3 code 7 TASK_TRANSFER）。
/// sourceId=taskId，载荷 instanceId/taskId/fromActor/toActor/operator。
/// 调用方在参与者被替换并落库（update_task）之后 fire。
pub fn[R, E] Engine::notify_task_transfer(
  self : Engine[R, E],
  instance_id : Int64,
  task_id : Int64,
  from_actor : String,
  to_actor : String,
  operator : String
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_i64("taskId", task_id)
  data.insert_str("fromActor", from_actor)
  data.insert_str("toActor", to_actor)
  data.insert_str("operator", operator)
  let event = @event.ProcessEvent::make(@event.TaskTransfer, task_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 撤回事件（spec §11.3 code 8 TASK_WITHDRAW）。
/// sourceId=instanceId，载荷 instanceId/operator。每轮撤回只 fire 一次（不逐任务）；
/// 调用方在实例 state→30 落库（update_instance）之后 fire。
pub fn[R, E] Engine::notify_instance_withdraw(
  self : Engine[R, E], instance_id : Int64, operator : String
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_str("operator", operator)
  let event = @event.ProcessEvent::make(@event.TaskWithdraw, instance_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}

///|
/// 实例终止事件（spec §11.3 code 9 INSTANCE_TERMINATED）。
/// sourceId=instanceId，载荷 instanceId/operator/reason。调用方在实例 state→40 落库之后 fire。
/// ⚠️ 本栈门面/引擎暂无"终止"action（ProcessInstance::interrupt 只在测试里被调、从不落库），
///    故 code 9 有号无触发点：本轮仅占号，补齐终止 action 时在落库处调本函数即接通。
pub fn[R, E] Engine::notify_instance_terminated(
  self : Engine[R, E], instance_id : Int64, operator : String, reason : String
) -> Unit {
  let data = @json.FlowData::new()
  data.insert_i64("instanceId", instance_id)
  data.insert_str("operator", operator)
  data.insert_str("reason", reason)
  let event = @event.ProcessEvent::make(@event.InstanceTerminated, instance_id).with_data(data)
  @event.notify(event, self.ctx.event_listeners())
}
