// jeeflow-core/event —— M1 移植自 rust event.rs（112 行）
// ProcessEvent(TASK_CREATE/INSTANCE_END/CC_CREATE) + publisher：per-listener 兜底（C12/C13）
// 事件只带 id 不带业务上下文；引擎只 fire，副作用归集成层
