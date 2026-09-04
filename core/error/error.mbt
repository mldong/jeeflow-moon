// jeeflow-core/error —— M1 移植自 rust jeeflow-core/src/error.rs（110 行）
// JeeflowError 枚举 + 契约错误消息（"缺少id参数"/"非法 id"/"任务不存在"…）
// 纪律：错误码只发明 99999999（方案 §3.3），消息与 Java 参考实现对齐
