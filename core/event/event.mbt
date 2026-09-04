// 事件系统 —— 移植自 rust event.rs（4 事件类型，spec/concepts/04 §4.1）
// 4 号位复用：原 ProcessTaskEnd 引擎从不 fire（全联邦死码），复用于 CcCreate（issues/102·104）

///|
pub(all) enum ProcessEventType {
  ProcessInstanceStart
  ProcessInstanceEnd
  ProcessTaskStart
  CcCreate
} derive(Eq, Show)

///|
pub fn ProcessEventType::code(self : ProcessEventType) -> Int {
  match self {
    ProcessInstanceStart => 1
    ProcessInstanceEnd => 2
    ProcessTaskStart => 3
    CcCreate => 4
  }
}

///|
pub fn ProcessEventType::from_code(code : Int) -> ProcessEventType? {
  match code {
    1 => Some(ProcessInstanceStart)
    2 => Some(ProcessInstanceEnd)
    3 => Some(ProcessTaskStart)
    4 => Some(CcCreate)
    _ => None
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
