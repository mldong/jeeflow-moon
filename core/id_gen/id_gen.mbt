// jeeflow-core/id_gen —— M1 移植自 rust id_gen.rs（138 行）
// AtomicIdGenerator：单线程计数器（事件循环无抢占，无锁，方案 §3.4.2），雪花兼容位序 EPOCH
// 可被 IIdGenerator 闭包字段替换；测试注入固定序保证确定性
