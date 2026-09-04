// jeeflow-core/engine —— M1 移植自 rust engine.rs（2041 行，全 async，方案 §2.3）
// JeeflowEngineImpl[R, E]：start/execute_task/jump/reject/withdraw/countersign 全 async fn
// Execution 运行时载体；泛型约束 [R : ProcessRepository, E : ProcessExtRepository]（无 dyn，§3.4.3）
// C8–C13 会签/抄送/事件全路径规则第一天写对
