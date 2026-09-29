// 事件系统 —— 移植自 rust event.rs + 补齐 issues/127·132「事件代码腿」
// 权威码表：jeeflow-doc/docs/spec/11-events.md §11.3（A 套整型 1..9，规范名逐字对齐）
// 4 号位复用：原 ProcessTaskEnd 引擎从不 fire（全联邦死码），复用于 CcCreate（issues/102·104）
// 5..9 为 issues/132 §5.2 定稿新增；10+ 预留（超时催办/自动通过，本轮不发，仅占号防分叉）

///|
/// 规范名 ↔ 构造子映射（构造子为本栈实际命名，name() 透出 spec §11.3 权威 SCREAMING 名）：
/// 1 PROCESS_INSTANCE_START / 2 PROCESS_INSTANCE_END / 3 PROCESS_TASK_START / 4 CC_CREATE
/// 5 TASK_COMPLETE / 6 TASK_REJECT / 7 TASK_TRANSFER / 8 TASK_WITHDRAW / 9 INSTANCE_TERMINATED
pub(all) enum ProcessEventType {
  ProcessInstanceStart
  ProcessInstanceEnd
  ProcessTaskStart
  CcCreate
  TaskComplete
  TaskReject
  TaskTransfer
  TaskWithdraw
  InstanceTerminated
  // 10+ 预留：超时催办 / 超时自动通过 …（spec §11.4「明确不发」——八栈无时钟扫描器，发了无触发源）
} derive(Eq, Debug)

///|
pub fn ProcessEventType::code(self : ProcessEventType) -> Int {
  match self {
    ProcessInstanceStart => 1
    ProcessInstanceEnd => 2
    ProcessTaskStart => 3
    CcCreate => 4
    TaskComplete => 5
    TaskReject => 6
    TaskTransfer => 7
    TaskWithdraw => 8
    InstanceTerminated => 9
  }
}

///|
pub fn ProcessEventType::from_code(code : Int) -> ProcessEventType? {
  match code {
    1 => Some(ProcessInstanceStart)
    2 => Some(ProcessInstanceEnd)
    3 => Some(ProcessTaskStart)
    4 => Some(CcCreate)
    5 => Some(TaskComplete)
    6 => Some(TaskReject)
    7 => Some(TaskTransfer)
    8 => Some(TaskWithdraw)
    9 => Some(InstanceTerminated)
    _ => None
  }
}

///|
/// spec §11.3 规范名（集成层跨语言判据一律用规范名，不得拿数字码当判据）
pub fn ProcessEventType::name(self : ProcessEventType) -> String {
  match self {
    ProcessInstanceStart => "PROCESS_INSTANCE_START"
    ProcessInstanceEnd => "PROCESS_INSTANCE_END"
    ProcessTaskStart => "PROCESS_TASK_START"
    CcCreate => "CC_CREATE"
    TaskComplete => "TASK_COMPLETE"
    TaskReject => "TASK_REJECT"
    TaskTransfer => "TASK_TRANSFER"
    TaskWithdraw => "TASK_WITHDRAW"
    InstanceTerminated => "INSTANCE_TERMINATED"
  }
}

///|
pub(all) struct ProcessEvent {
  event_type : ProcessEventType
  source_id : Int64
  data : @json.FlowData
  /// 抄送人 id（仅 CcCreate；直传事件体，集成层监听器免反查 cc 表）
  cc_actor_id : String?
}

///|
pub fn ProcessEvent::event_type(self : ProcessEvent) -> ProcessEventType {
  self.event_type
}

///|
pub fn ProcessEvent::source_id(self : ProcessEvent) -> Int64 {
  self.source_id
}

///|
pub fn ProcessEvent::cc_actor_id(self : ProcessEvent) -> String? {
  self.cc_actor_id
}

///|
pub fn ProcessEvent::make(event_type : ProcessEventType, source_id : Int64) -> ProcessEvent {
  { event_type, source_id, data: @json.FlowData::new(), cc_actor_id: None }
}

///|
pub fn ProcessEvent::with_data(self : ProcessEvent, data : @json.FlowData) -> ProcessEvent {
  { ..self, data }
}

///|
pub fn ProcessEvent::with_cc_actor_id(self : ProcessEvent, cc_actor_id : String) -> ProcessEvent {
  { ..self, cc_actor_id: Some(cc_actor_id) }
}

///|
/// 事件发布：逐监听器兜底（issues/104 P2）——单监听器异常只捕获不传播，
/// 不影响引擎主流程、不中断后续监听器。监听器形态为闭包数组（Ctx 装配）。
pub fn notify(event : ProcessEvent, listeners : Array[(ProcessEvent) -> Unit raise]) -> Unit {
  for listener in listeners {
    try {
      (listener)(event)
    } catch {
      _ => () // 单监听器异常隔离（对齐 PHP per-listener catch / Rust catch_unwind）
    }
  }
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend ProcessEventType with Eq::{equal, not_equal}
pub extend ProcessEventType with Debug::{to_repr}
